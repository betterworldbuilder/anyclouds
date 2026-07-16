"""Builds DeploymentSnapshot objects for the Deployment Live Dashboard."""
from __future__ import annotations

import datetime as _dt
from typing import Any, Dict

from .cache import CACHE
from .command_runner import run_command, run_json_command
from .log_stream import latest_bootstrap_log
from .models import DeploymentSnapshot, MonitoringContext
from .parsers import (
    PIPELINE_STAGES,
    parse_bootstrap_log,
    parse_deploy_processes,
    parse_git_status,
    parse_servers,
)

_LOG_PARSE_TTL = 2
_PROCESS_TTL = 2
_GIT_TTL = 5
_VM_TTL = 5


def _utcnow() -> str:
    return _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds")


def _parsed_log(ctx: MonitoringContext) -> Dict[str, Any]:
    """Incrementally parsed newest bootstrap log.

    The first pass reads the whole file; afterwards only appended bytes are
    parsed, so stage markers early in multi-megabyte logs are never lost to
    tail truncation and refreshes stay cheap.
    """
    key = ("bootstrap_parse", ctx.org, ctx.cluster)

    def produce():
        previous = CACHE.peek(key, max_age=3600) or {}
        path = latest_bootstrap_log(ctx)
        if not path:
            return {"log_name": "", "log_mtime": 0, "offset": 0,
                    "parsed": parse_bootstrap_log("")}
        try:
            size = path.stat().st_size
        except OSError:
            size = 0
        same_log = previous.get("log_name") == path.name and previous.get("offset", 0) <= size
        state = previous.get("parsed") if same_log else None
        offset = previous.get("offset", 0) if same_log else 0
        try:
            with path.open("r", encoding="utf-8", errors="replace") as handle:
                handle.seek(offset)
                chunk = handle.read()
                new_offset = handle.tell()
        except OSError:
            chunk, new_offset = "", offset
        parsed = parse_bootstrap_log(chunk, state=state)
        return {"log_name": path.name, "log_mtime": path.stat().st_mtime if path.exists() else 0,
                "offset": new_offset, "parsed": parsed}

    return CACHE.get(key, _LOG_PARSE_TTL, produce)


def _processes(ctx: MonitoringContext):
    def produce():
        result = run_command(ctx, "deploy_processes")
        if not result.get("ok"):
            return []
        return parse_deploy_processes(result.get("stdout", ""), ctx.org, ctx.cluster)

    return CACHE.get(("deploy_procs", ctx.org, ctx.cluster), _PROCESS_TTL, produce)


def gitops_state(ctx: MonitoringContext) -> Dict[str, Any]:
    def produce():
        status = run_command(ctx, "git_status")
        commit = run_command(ctx, "git_last_commit")
        info: Dict[str, Any] = {"available": bool(status.get("ok"))}
        if status.get("ok"):
            info.update(parse_git_status(status.get("stdout", "")))
        else:
            info["error"] = status.get("error", "")
        if commit.get("ok"):
            parts = (commit.get("stdout", "").strip()).split("\x1f")
            if len(parts) == 4:
                info["last_commit"] = {
                    "sha": parts[0][:12],
                    "timestamp": int(parts[1]) if parts[1].isdigit() else 0,
                    "author": parts[2],
                    "subject": parts[3][:200],
                }
        return info

    return CACHE.get(("gitops_state", ctx.org, ctx.cluster), _GIT_TTL, produce)


def infrastructure_state(ctx: MonitoringContext) -> Dict[str, Any]:
    def produce():
        result = run_json_command(ctx, "os_server_list")
        if not result.get("ok"):
            return {"available": False, "reason": result.get("error", "")}
        return {"available": True, "servers": parse_servers(result.get("data") or [], ctx.cluster)}

    return CACHE.get(("infra_servers", ctx.org, ctx.cluster), _VM_TTL, produce)


def kubernetes_state(ctx: MonitoringContext) -> Dict[str, Any]:
    from .parsers import parse_nodes, parse_pods

    def produce():
        if not ctx.kubeconfig_available():
            return {"available": False, "reason": "kubeconfig not generated yet"}
        nodes = run_json_command(ctx, "k8s_nodes")
        if not nodes.get("ok"):
            return {"available": False, "reason": nodes.get("error", "API unreachable")}
        node_rows = parse_nodes(nodes.get("data") or {})
        pods = run_json_command(ctx, "k8s_pods")
        pod_summary = parse_pods(pods.get("data") or {}) if pods.get("ok") else {}
        return {
            "available": True,
            "nodes_total": len(node_rows),
            "nodes_ready": sum(1 for n in node_rows if n["ready"]),
            "nodes": node_rows,
            "pods": pod_summary,
        }

    return CACHE.get(("deploy_k8s", ctx.org, ctx.cluster), _VM_TTL, produce)


def flux_state(ctx: MonitoringContext) -> Dict[str, Any]:
    from .parsers import parse_flux_objects

    def produce():
        if not ctx.kubeconfig_available():
            return {"available": False, "reason": "kubeconfig not generated yet"}
        rows = []
        for cmd in ("flux_sources", "flux_kustomizations", "flux_helmreleases"):
            result = run_json_command(ctx, cmd)
            if result.get("ok"):
                rows.extend(parse_flux_objects(result.get("data") or {}))
        return {
            "available": bool(rows),
            "total": len(rows),
            "ready": sum(1 for r in rows if r["ready"]),
            "objects": rows,
        }

    return CACHE.get(("deploy_flux", ctx.org, ctx.cluster), _VM_TTL, produce)


def _derive_git_stages(stages: Dict[str, Dict[str, Any]], git: Dict[str, Any], started: bool) -> None:
    """Fill the git-side pipeline stages from live repository state."""
    if not git.get("available"):
        return
    clean = git.get("clean", True)
    ahead = git.get("ahead", 0)
    if started:
        # The deploy wrapper performs auth/fetch/generate/secrets before
        # bootstrap; a started bootstrap implies those already succeeded.
        for sid in ("git_auth", "git_sync", "generate", "secrets"):
            if stages[sid]["status"] == "pending":
                stages[sid]["status"] = "passed"
    stages["git_commit"]["status"] = "passed" if clean else "warning"
    if not clean:
        stages["git_commit"]["message"] = "%d uncommitted file(s) in the GitOps tree" % len(git.get("dirty_files", []))
    stages["git_push"]["status"] = "passed" if (clean and ahead == 0) else "warning"
    if ahead:
        stages["git_push"]["message"] = "%d unpushed commit(s)" % ahead


def build_snapshot(ctx: MonitoringContext) -> DeploymentSnapshot:
    log_info = _parsed_log(ctx)
    parsed = log_info["parsed"]
    processes = _processes(ctx)
    git = gitops_state(ctx)

    stages = parsed["stages"]
    _derive_git_stages(stages, git, parsed.get("started", False))

    snapshot = DeploymentSnapshot(org=ctx.org, cluster=ctx.cluster,
                                  provider=ctx.provider, region=ctx.region)
    snapshot.latest_log = log_info["log_name"]
    snapshot.stages = [stages[sid] for sid, _ in PIPELINE_STAGES]
    snapshot.completed_steps = [s["id"] for s in snapshot.stages if s["status"] == "passed"]
    snapshot.active_step = parsed.get("active_step", "")
    snapshot.failed_step = parsed.get("failed_step", "")
    snapshot.warnings = parsed.get("warnings", [])
    snapshot.errors = parsed.get("errors", [])
    snapshot.gitops_status = git
    snapshot.cloud_init_status = parsed.get("cloud_init", {})
    snapshot.kubespray_status = parsed.get("ansible", {})
    snapshot.infrastructure_status = parsed.get("tofu", {})
    snapshot.generated_at = _utcnow()

    running = [p for p in processes if p.get("pid")]
    if running:
        primary = min(running, key=lambda p: p["elapsed_seconds"] * -1)
        snapshot.deployment_pid = primary["pid"]
        snapshot.start_time = primary["started"]
        snapshot.elapsed_seconds = primary["elapsed_seconds"]
        snapshot.deployment_status = "RUNNING"
        # While a process is active, never surface break-lock style advice.
        for err in snapshot.errors:
            err["next_command"] = err.get("next_command", "").replace("--break-lock", "").strip()
        if len(running) > 1:
            snapshot.duplicate_pids = [p["pid"] for p in running]
            snapshot.deployment_status = "BLOCKED"
    elif parsed.get("finished"):
        snapshot.deployment_status = "SUCCEEDED" if parsed.get("success") else "FAILED"
    elif parsed.get("failed_step"):
        snapshot.deployment_status = "FAILED"
    elif parsed.get("started"):
        snapshot.deployment_status = "WAITING"
    else:
        snapshot.deployment_status = "IDLE"

    active = [s for s in snapshot.stages if s["status"] == "running"]
    failed = [s for s in snapshot.stages if s["status"] == "failed"]
    snapshot.current_stage = (failed or active or [{"id": ""}])[0].get("id", "")
    return snapshot
