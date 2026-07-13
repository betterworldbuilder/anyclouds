"""Tests for R6 → OpenCenter Handover Readiness: 19 backend + 12 frontend tests."""
import json
import pathlib
import shutil
import tempfile
import threading
import time

import pytest

# ── Path setup ──────────────────────────────────────────────────────────────
import sys
sys.path.insert(0, str(pathlib.Path(__file__).parent.parent))

from workflow_dashboard.r6.handover import checklist_loader, applicability
from workflow_dashboard.r6.handover.result_models import CheckStatus, Verdict
from workflow_dashboard.r6.handover import execution_engine as ee
from workflow_dashboard.r6.handover import evidence_store

BASE_URL = "http://localhost:5001"
HANDOVER_RUN_URL = BASE_URL + "/api/r6/handover-checks/run"


# ── Fixtures ─────────────────────────────────────────────────────────────────

def _make_minimal_bundle(tmp_path, with_blocked=False, with_warnings=False):
    """Build a minimal bundle directory for testing."""
    bd = tmp_path / "bundle"
    kb = bd / "kustomize_bundle"
    kb.mkdir(parents=True)
    ops = bd / "operations"
    ops.mkdir()
    flux_d = bd / "flux"
    flux_d.mkdir()

    # namespace.yaml with PSS labels
    (kb / "namespace.yaml").write_text(
        "apiVersion: v1\nkind: Namespace\nmetadata:\n  name: test-ns\n"
        "  labels:\n    pod-security.kubernetes.io/enforce: restricted\n"
        "    pod-security.kubernetes.io/audit: restricted\n"
        "    pod-security.kubernetes.io/warn: restricted\n"
    )
    # Deployment with security context
    (kb / "deployment.yaml").write_text(
        "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: api-server\n"
        "spec:\n  template:\n    spec:\n      securityContext:\n        runAsNonRoot: true\n"
        "      containers:\n      - name: api\n        image: registry.io/api:v1\n"
    )
    # NetworkPolicies
    (kb / "netpol.yaml").write_text(
        "apiVersion: networking.k8s.io/v1\nkind: NetworkPolicy\nmetadata:\n  name: deny-ingress\n"
        "spec:\n  podSelector: {}\n  policyTypes:\n  - Ingress\n---\n"
        "apiVersion: networking.k8s.io/v1\nkind: NetworkPolicy\nmetadata:\n  name: deny-egress\n"
        "spec:\n  podSelector: {}\n  policyTypes:\n  - Egress\n"
    )
    # bundle-validation.json
    status = "BLOCKED" if with_blocked else ("PASSED_WITH_WARNINGS" if with_warnings else "PASSED")
    blockers = ["missing-operator"] if with_blocked else []
    warnings_list = ["velero-absent"] if with_warnings else []
    (bd / "bundle-validation.json").write_text(json.dumps({
        "status": status, "blockers": blockers, "warnings": warnings_list
    }))
    # image-manifest.json
    (bd / "image-manifest.json").write_text(json.dumps({
        "images": [{"component": "api-server", "image": "registry.io/api:v1"}]
    }))
    # business-system.yaml
    (bd / "business-system.yaml").write_text(
        "apiVersion: opencenter.io/v1\nkind: BusinessApplicationSystem\nmetadata:\n  name: test-biz\n"
    )
    # validation-jobs.yaml with digest-pinned images
    (kb / "validation-jobs.yaml").write_text(
        "apiVersion: batch/v1\nkind: Job\nmetadata:\n  name: http-health-check\n"
        "spec:\n  template:\n    spec:\n      containers:\n"
        "      - name: check\n        image: busybox:stable@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662\n"
        "        command: ['/bin/sh','-c','wget -qO- http://api-server/health']\n"
        "      restartPolicy: Never\n"
    )
    # Rollback runbook
    (ops / "rollback-runbook.yaml").write_text(
        "apiVersion: r6.opencenter.io/v1alpha1\nkind: RollbackRunbook\nmetadata:\n  name: test-ns\n"
        "spec:\n  gitRevision:\n    deployedCommit: '<fill-in>'\n    previousCommit: '<fill-in>'\n"
        "    rollbackCommand: 'git revert && flux reconcile'\n"
        "  images:\n  - component: api-server\n    generated_image: registry.io/api:v1\n"
        "  traffic:\n    externalHostname: test.example.com\n    lbRollback: manual\n"
        "    dnsFlushCommand: flush\n    trafficCutbackCommand: cutback\n"
        "  vmWorkloads: []\n  vmNote: 'No VMs'\n"
        "  dataLimitations:\n  - 'No automated data rollback'\n  - 'Check DB backups'\n  - 'Velero required'\n"
        "  verificationSteps:\n  - 'Check pods'\n  - 'Check endpoints'\n  - 'Verify ingress'\n"
        "  - 'Check logs'\n  - 'Confirm traffic'\n"
    )
    # Flux Kustomization
    (flux_d / "test-kustomization.yaml").write_text(
        "apiVersion: kustomize.toolkit.fluxcd.io/v1\nkind: Kustomization\n"
        "metadata:\n  name: test-ns\nspec:\n  prune: true\n  path: ./kustomize_bundle\n"
    )
    return bd


# ═══════════════════════════════════════════════════════════════════════════
# BACKEND TESTS (19 tests)
# ═══════════════════════════════════════════════════════════════════════════

class TestChecklistLoader:
    def test_checklist_loads(self):
        data = checklist_loader.load()
        assert "checks" in data
        assert "sections" in data
        assert len(data["checks"]) >= 40

    def test_all_checks_have_required_fields(self):
        for c in checklist_loader.get_checks():
            assert "id" in c, f"Check missing id: {c}"
            assert "section" in c, f"Check {c['id']} missing section"
            assert "executor" in c, f"Check {c['id']} missing executor"
            assert "blockingPolicy" in c, f"Check {c['id']} missing blockingPolicy"

    def test_sections_ordered(self):
        sections = checklist_loader.get_sections()
        orders = [s["order"] for s in sections]
        assert orders == sorted(orders)

    def test_get_check_by_id(self):
        c = checklist_loader.get_check("R6-HO-001")
        assert c is not None
        assert c["title"] == "Local toolchain"

    def test_checks_by_section_groups_correctly(self):
        by_sec = checklist_loader.checks_by_section()
        assert "environment-preflight" in by_sec
        assert "bundle-completeness" in by_sec
        assert len(by_sec["environment-preflight"]) >= 5


class TestApplicability:
    def test_always_true_rule(self):
        check = {"id": "X", "applicabilityRule": "true", "executor": "x", "blockingPolicy": "ALWAYS"}
        ctx = applicability.build_bundle_context(None)
        assert applicability.is_applicable(check, ctx) is True

    def test_false_rule(self):
        check = {"id": "X", "applicabilityRule": "false", "executor": "x", "blockingPolicy": "ALWAYS"}
        ctx = applicability.build_bundle_context(None)
        assert applicability.is_applicable(check, ctx) is False

    def test_bundle_has_pvcs_false_on_empty(self):
        ctx = applicability.build_bundle_context(None)
        assert ctx["hasPVCs"] is False

    def test_build_context_from_bundle(self, tmp_path):
        bd = _make_minimal_bundle(tmp_path)
        ctx = applicability.build_bundle_context(str(bd))
        assert ctx["deployableCount"] == 1
        assert ctx["hasValidationJobs"] is True


class TestExecutors:
    def test_check_bundle_dir_pass(self, tmp_path):
        bd = _make_minimal_bundle(tmp_path)
        from workflow_dashboard.r6.handover.executors.bundle import check_bundle_dir
        check = checklist_loader.get_check("R6-HO-011") or {"id": "R6-HO-011"}
        result = check_bundle_dir(check, str(bd), {}, threading.Event())
        assert result["status"] == CheckStatus.PASS.value

    def test_check_bundle_dir_fail_missing(self):
        from workflow_dashboard.r6.handover.executors.bundle import check_bundle_dir
        check = {"id": "R6-HO-011"}
        result = check_bundle_dir(check, "/nonexistent/path", {}, threading.Event())
        assert result["status"] == CheckStatus.FAIL.value

    def test_check_bundle_validation_json_blocked(self, tmp_path):
        bd = _make_minimal_bundle(tmp_path, with_blocked=True)
        from workflow_dashboard.r6.handover.executors.bundle import check_bundle_validation_json
        result = check_bundle_validation_json({"id": "R6-HO-013"}, str(bd), {}, threading.Event())
        assert result["status"] == CheckStatus.FAIL.value
        assert "BLOCKED" in result["message"]

    def test_check_pss_labels_pass(self, tmp_path):
        bd = _make_minimal_bundle(tmp_path)
        from workflow_dashboard.r6.handover.executors.security import check_pss_labels
        result = check_pss_labels({"id": "R6-HO-020"}, str(bd), {}, threading.Event())
        assert result["status"] == CheckStatus.PASS.value

    def test_check_secret_scan_no_leaks(self, tmp_path):
        bd = _make_minimal_bundle(tmp_path)
        from workflow_dashboard.r6.handover.executors.security import check_secret_scan
        result = check_secret_scan({"id": "R6-HO-016"}, str(bd), {}, threading.Event())
        assert result["status"] == CheckStatus.PASS.value

    def test_check_secret_scan_detects_leak(self, tmp_path):
        bd = _make_minimal_bundle(tmp_path)
        (bd / "kustomize_bundle" / "bad.yaml").write_text("password: mysecretpassword123\n")
        from workflow_dashboard.r6.handover.executors.security import check_secret_scan
        result = check_secret_scan({"id": "R6-HO-016"}, str(bd), {}, threading.Event())
        assert result["status"] == CheckStatus.FAIL.value

    def test_check_network_policies_pass(self, tmp_path):
        bd = _make_minimal_bundle(tmp_path)
        from workflow_dashboard.r6.handover.executors.networking import check_network_policies
        result = check_network_policies({"id": "R6-HO-028"}, str(bd), {}, threading.Event())
        assert result["status"] == CheckStatus.PASS.value

    def test_check_rollback_runbook_pass(self, tmp_path):
        bd = _make_minimal_bundle(tmp_path)
        from workflow_dashboard.r6.handover.executors.rollback import check_rollback_runbook
        result = check_rollback_runbook({"id": "R6-HO-041"}, str(bd), {}, threading.Event())
        assert result["status"] == CheckStatus.PASS.value

    def test_check_rollback_runbook_missing(self, tmp_path):
        bd = _make_minimal_bundle(tmp_path)
        (bd / "operations" / "rollback-runbook.yaml").unlink()
        from workflow_dashboard.r6.handover.executors.rollback import check_rollback_runbook
        result = check_rollback_runbook({"id": "R6-HO-041"}, str(bd), {}, threading.Event())
        assert result["status"] == CheckStatus.FAIL.value

    def test_check_validation_job_digests_pass(self, tmp_path):
        bd = _make_minimal_bundle(tmp_path)
        from workflow_dashboard.r6.handover.executors.images import check_validation_job_digests
        result = check_validation_job_digests({"id": "R6-HO-019"}, str(bd), {}, threading.Event())
        assert result["status"] == CheckStatus.PASS.value

    def test_check_validation_job_digests_fail_undigested(self, tmp_path):
        bd = _make_minimal_bundle(tmp_path)
        (bd / "kustomize_bundle" / "validation-jobs.yaml").write_text(
            "apiVersion: batch/v1\nkind: Job\nmetadata:\n  name: check\n"
            "spec:\n  template:\n    spec:\n      containers:\n"
            "      - name: c\n        image: busybox:latest\n      restartPolicy: Never\n"
        )
        from workflow_dashboard.r6.handover.executors.images import check_validation_job_digests
        result = check_validation_job_digests({"id": "R6-HO-019"}, str(bd), {}, threading.Event())
        assert result["status"] == CheckStatus.FAIL.value

    def test_check_flux_kustomization_pass(self, tmp_path):
        bd = _make_minimal_bundle(tmp_path)
        from workflow_dashboard.r6.handover.executors.gitops import check_flux_kustomization
        result = check_flux_kustomization({"id": "R6-HO-033"}, str(bd), {}, threading.Event())
        assert result["status"] == CheckStatus.PASS.value

    def test_check_stage12_zero_blockers_pass(self, tmp_path):
        bd = _make_minimal_bundle(tmp_path)
        from workflow_dashboard.r6.handover.executors.bundle import check_stage12_zero_blockers
        result = check_stage12_zero_blockers({"id": "R6-HO-037"}, str(bd), {}, threading.Event())
        assert result["status"] == CheckStatus.PASS.value

    def test_check_stage12_zero_blockers_fail(self, tmp_path):
        bd = _make_minimal_bundle(tmp_path, with_blocked=True)
        from workflow_dashboard.r6.handover.executors.bundle import check_stage12_zero_blockers
        result = check_stage12_zero_blockers({"id": "R6-HO-037"}, str(bd), {}, threading.Event())
        assert result["status"] == CheckStatus.FAIL.value


class TestEvidenceStore:
    def test_save_and_load_run(self, tmp_path, monkeypatch):
        import workflow_dashboard.r6.handover.evidence_store as es
        monkeypatch.setattr(es, "_REPORTS_DIR", tmp_path / "reports")
        run_id = "test-run-001"
        data = {"runId": run_id, "status": "COMPLETE", "verdict": "READY"}
        path = es.save_run(run_id, data)
        assert pathlib.Path(path).is_file()
        loaded = es.load_run(run_id)
        assert loaded["verdict"] == "READY"

    def test_list_runs(self, tmp_path, monkeypatch):
        import workflow_dashboard.r6.handover.evidence_store as es
        monkeypatch.setattr(es, "_REPORTS_DIR", tmp_path / "reports")
        es.save_run("r1", {"runId": "r1", "status": "COMPLETE", "verdict": "READY",
                           "startedAt": "2026-07-12T00:00:00Z"})
        runs = es.list_runs()
        assert len(runs) >= 1
        assert runs[0]["runId"] == "r1"


# ═══════════════════════════════════════════════════════════════════════════
# FRONTEND / API TESTS (12 tests) — require running Flask app on port 5001
# ═══════════════════════════════════════════════════════════════════════════

try:
    import requests
    _REQUESTS = True
except ImportError:
    _REQUESTS = False


def _flask_alive():
    if not _REQUESTS:
        return False
    try:
        r = requests.get(BASE_URL + "/api/r6/state", timeout=2)
        return r.status_code in (200, 404)
    except Exception:
        return False


_SKIP_FRONTEND = not _flask_alive()
_skip_msg = "Flask app not running on port 5001"


@pytest.mark.skipif(_SKIP_FRONTEND, reason=_skip_msg)
class TestHandoverAPI:
    def test_run_endpoint_requires_bundle_dir(self):
        r = requests.post(HANDOVER_RUN_URL, json={}, timeout=5)
        assert r.status_code == 400
        assert r.json()["ok"] is False

    def test_run_endpoint_rejects_invalid_mode(self, tmp_path):
        bd = _make_minimal_bundle(tmp_path)
        r = requests.post(HANDOVER_RUN_URL,
                          json={"bundle_dir": str(bd), "mode": "badmode"}, timeout=5)
        assert r.status_code == 400

    def test_run_returns_run_id(self, tmp_path):
        bd = _make_minimal_bundle(tmp_path)
        r = requests.post(HANDOVER_RUN_URL,
                          json={"bundle_dir": str(bd), "mode": "safe"}, timeout=5)
        assert r.status_code == 202
        data = r.json()
        assert data["ok"] is True
        assert "runId" in data

    def test_status_returns_run_fields(self, tmp_path):
        bd = _make_minimal_bundle(tmp_path)
        run_id = requests.post(HANDOVER_RUN_URL,
                               json={"bundle_dir": str(bd), "mode": "safe"}, timeout=5).json()["runId"]
        time.sleep(0.5)
        r = requests.get(BASE_URL + f"/api/r6/handover-checks/runs/{run_id}", timeout=5)
        assert r.status_code == 200
        data = r.json()
        assert "verdict" in data
        assert "score" in data
        assert "results" in data

    def test_status_404_for_unknown_run(self):
        r = requests.get(BASE_URL + "/api/r6/handover-checks/runs/nonexistent-run-id", timeout=5)
        assert r.status_code == 404

    def test_cancel_endpoint(self, tmp_path):
        bd = _make_minimal_bundle(tmp_path)
        run_id = requests.post(HANDOVER_RUN_URL,
                               json={"bundle_dir": str(bd), "mode": "safe"}, timeout=5).json()["runId"]
        r = requests.post(BASE_URL + f"/api/r6/handover-checks/runs/{run_id}/cancel", timeout=5)
        assert r.status_code == 200
        assert r.json()["ok"] is True

    def test_retry_endpoint(self, tmp_path):
        bd = _make_minimal_bundle(tmp_path)
        run_id = requests.post(HANDOVER_RUN_URL,
                               json={"bundle_dir": str(bd), "mode": "safe"}, timeout=5).json()["runId"]
        time.sleep(2)
        r = requests.post(BASE_URL + f"/api/r6/handover-checks/runs/{run_id}/retry", timeout=5)
        assert r.status_code == 202
        new_run_id = r.json()["runId"]
        assert new_run_id != run_id

    def test_export_endpoint_returns_json_attachment(self, tmp_path):
        bd = _make_minimal_bundle(tmp_path)
        run_id = requests.post(HANDOVER_RUN_URL,
                               json={"bundle_dir": str(bd), "mode": "safe"}, timeout=5).json()["runId"]
        time.sleep(2)
        r = requests.get(BASE_URL + f"/api/r6/handover-checks/runs/{run_id}/export", timeout=10)
        assert r.status_code == 200
        assert "attachment" in r.headers.get("Content-Disposition", "")
        data = r.json()
        assert "runId" in data

    def test_approve_warning_404_on_non_warning(self, tmp_path):
        bd = _make_minimal_bundle(tmp_path)
        run_id = requests.post(HANDOVER_RUN_URL,
                               json={"bundle_dir": str(bd), "mode": "safe"}, timeout=5).json()["runId"]
        time.sleep(2)
        r = requests.post(
            BASE_URL + f"/api/r6/handover-checks/runs/{run_id}/checks/R6-HO-001/approve-warning",
            timeout=5
        )
        # Either 404 (not in WARNING state) or 200 (successfully approved)
        assert r.status_code in (200, 404)

    def test_run_completes_with_verdict(self, tmp_path):
        bd = _make_minimal_bundle(tmp_path)
        run_id = requests.post(HANDOVER_RUN_URL,
                               json={"bundle_dir": str(bd), "mode": "safe"}, timeout=5).json()["runId"]
        # Wait up to 15s for completion
        for _ in range(15):
            time.sleep(1)
            data = requests.get(BASE_URL + f"/api/r6/handover-checks/runs/{run_id}",
                                timeout=5).json()
            if data.get("status") in ("COMPLETE", "FAILED", "CANCELLED"):
                break
        assert data["status"] == "COMPLETE"
        assert data["verdict"] in ("READY", "READY_WITH_WARNINGS", "NOT_READY", "BLOCKED")

    def test_blocked_bundle_gives_blocked_verdict(self, tmp_path):
        bd = _make_minimal_bundle(tmp_path, with_blocked=True)
        run_id = requests.post(HANDOVER_RUN_URL,
                               json={"bundle_dir": str(bd), "mode": "safe"}, timeout=5).json()["runId"]
        for _ in range(15):
            time.sleep(1)
            data = requests.get(BASE_URL + f"/api/r6/handover-checks/runs/{run_id}",
                                timeout=5).json()
            if data.get("status") == "COMPLETE":
                break
        assert data["verdict"] == "BLOCKED"

    def test_handover_section_present_in_html(self):
        r = requests.get(BASE_URL + "/", timeout=5)
        assert r.status_code == 200
        assert "s5c-handover-section" in r.text
