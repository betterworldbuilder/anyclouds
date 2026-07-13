"""DAG-based execution engine for R6 handover checks.

Runs independent checks concurrently. Respects prerequisites.
Cancellable via threading.Event. All subprocess calls use argument arrays.
"""
import concurrent.futures
import threading
import time
import uuid
import datetime

from . import checklist_loader, applicability, evidence_store
from .result_models import CheckStatus, RunStatus, Verdict, make_check_result

# executor name → callable
_REGISTRY = {}


def register(name):
    def _d(fn):
        _REGISTRY[name] = fn
        return fn
    return _d


# Import all executors so they register themselves
def _load_executors():
    from . import executors  # noqa: F401
    try:
        from .executors import (  # noqa: F401
            toolchain, bundle, gitops, kubernetes_checks,
            images, security, storage, networking, flux, hybrid,
            validation, rollback,
        )
    except ImportError:
        pass


class HandoverRun:
    def __init__(self, run_id, bundle_dir, mode, params):
        self.run_id = run_id
        self.bundle_dir = bundle_dir
        self.mode = mode  # "safe" | "full"
        self.params = params
        self.status = RunStatus.RUNNING
        self.results = {}  # check_id → result dict
        self.cancel_event = threading.Event()
        self.started_at = datetime.datetime.utcnow().isoformat() + "Z"
        self.finished_at = None
        self._lock = threading.Lock()

    def cancel(self):
        self.cancel_event.set()

    def to_dict(self):
        bundle_ctx = applicability.build_bundle_context(self.bundle_dir)
        checks = checklist_loader.get_checks()
        total = 0
        passed = 0
        failed = 0
        warnings = 0
        not_applicable = 0
        blockers = []
        for c in checks:
            cid = c["id"]
            if not applicability.is_applicable(c, bundle_ctx):
                continue
            total += 1
            r = self.results.get(cid)
            if r is None:
                continue
            st = r["status"]
            if st == CheckStatus.PASS.value:
                passed += 1
            elif st in (CheckStatus.FAIL.value, CheckStatus.CANCELLED.value):
                failed += 1
                if c.get("blockingPolicy", "ALWAYS") not in ("NON_BLOCKING",):
                    blockers.append(cid)
            elif st == CheckStatus.WARNING.value:
                warnings += 1
            elif st == CheckStatus.NOT_APPLICABLE.value:
                not_applicable += 1

        score = int(100 * passed / total) if total > 0 else 0
        verdict = _compute_verdict(blockers, warnings, score, total, passed)
        return {
            "runId": self.run_id,
            "status": self.status.value,
            "mode": self.mode,
            "startedAt": self.started_at,
            "finishedAt": self.finished_at,
            "bundleDir": self.bundle_dir,
            "score": score,
            "total": total,
            "passed": passed,
            "failed": failed,
            "warnings": warnings,
            "notApplicable": not_applicable,
            "blockers": blockers,
            "verdict": verdict.value,
            "results": self.results,
        }


def _compute_verdict(blockers, warnings, score, total, passed):
    if blockers:
        return Verdict.BLOCKED
    if total == 0:
        return Verdict.NOT_READY
    if score == 100:
        return Verdict.READY
    if warnings > 0 and passed + warnings == total:
        return Verdict.READY_WITH_WARNINGS
    if score >= 80:
        return Verdict.READY_WITH_WARNINGS
    return Verdict.NOT_READY


# Global registry of active runs
_RUNS = {}
_RUNS_LOCK = threading.Lock()


def start_run(bundle_dir, mode="safe", params=None):
    _load_executors()
    run_id = str(uuid.uuid4())
    run = HandoverRun(run_id, bundle_dir, mode, params or {})
    with _RUNS_LOCK:
        _RUNS[run_id] = run
    t = threading.Thread(target=_execute_run, args=(run,), daemon=True)
    t.start()
    return run_id


def get_run(run_id):
    with _RUNS_LOCK:
        return _RUNS.get(run_id)


def cancel_run(run_id):
    run = get_run(run_id)
    if run:
        run.cancel()
        run.status = RunStatus.CANCELLED
        run.finished_at = datetime.datetime.utcnow().isoformat() + "Z"
        evidence_store.save_run(run_id, run.to_dict())
    return run is not None


def approve_warning(run_id, check_id):
    run = get_run(run_id)
    if not run:
        return False
    with run._lock:
        r = run.results.get(check_id)
        if r and r["status"] == CheckStatus.WARNING.value:
            r["status"] = CheckStatus.WARNING_APPROVED.value
            r["message"] += " [manually approved]"
    return True


def _execute_run(run):
    bundle_ctx = applicability.build_bundle_context(run.bundle_dir)
    checks = checklist_loader.get_checks()

    # Build prerequisite map: check_id → list of prerequisite check_ids
    prereq_map = {c["id"]: c.get("prerequisites", []) for c in checks}

    # Group checks with no prerequisites first, then those with prereqs
    completed = set()
    pending = {c["id"]: c for c in checks}
    max_workers = 4

    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as pool:
        in_flight = {}
        while pending or in_flight:
            if run.cancel_event.is_set():
                for cid in list(pending):
                    with run._lock:
                        run.results[cid] = make_check_result(
                            cid, CheckStatus.CANCELLED, "Run was cancelled"
                        )
                run.status = RunStatus.CANCELLED
                break

            # Submit ready checks (all prereqs completed)
            for cid, check in list(pending.items()):
                if cid in in_flight:
                    continue
                prereqs = prereq_map.get(cid, [])
                if not all(p in completed for p in prereqs):
                    continue
                if not applicability.is_applicable(check, bundle_ctx):
                    with run._lock:
                        run.results[cid] = make_check_result(
                            cid, CheckStatus.NOT_APPLICABLE, "Not applicable for this bundle"
                        )
                    completed.add(cid)
                    del pending[cid]
                    continue
                # Skip non-safe checks in safe mode
                if run.mode == "safe" and check.get("blockingPolicy") == "PRODUCTION":
                    with run._lock:
                        run.results[cid] = make_check_result(
                            cid, CheckStatus.NOT_APPLICABLE, "Skipped in safe mode"
                        )
                    completed.add(cid)
                    del pending[cid]
                    continue

                executor_name = check.get("executor", "")
                executor_fn = _REGISTRY.get(executor_name)
                if executor_fn is None:
                    with run._lock:
                        run.results[cid] = make_check_result(
                            cid, CheckStatus.WARNING,
                            f"No executor registered for '{executor_name}'"
                        )
                    completed.add(cid)
                    del pending[cid]
                    continue

                future = pool.submit(_run_check, check, executor_fn, run)
                in_flight[cid] = future
                del pending[cid]

            # Collect finished futures
            done_now = []
            for cid, future in list(in_flight.items()):
                if future.done():
                    done_now.append(cid)
                    result = future.result()
                    with run._lock:
                        run.results[cid] = result
                    completed.add(cid)
            for cid in done_now:
                del in_flight[cid]

            if not done_now and (pending or in_flight):
                time.sleep(0.05)

    if run.status == RunStatus.RUNNING:
        run.status = RunStatus.COMPLETE
    run.finished_at = datetime.datetime.utcnow().isoformat() + "Z"
    evidence_store.save_run(run.run_id, run.to_dict())


def _run_check(check, executor_fn, run):
    cid = check["id"]
    timeout = check.get("timeoutSeconds", 30)
    try:
        result = executor_fn(check, run.bundle_dir, run.params, run.cancel_event)
        return result
    except TimeoutError:
        return make_check_result(cid, CheckStatus.FAIL, f"Timed out after {timeout}s")
    except Exception as exc:
        return make_check_result(cid, CheckStatus.FAIL, f"Executor error: {exc}")
