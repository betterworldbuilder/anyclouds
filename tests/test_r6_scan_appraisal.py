import json
import pathlib
import base64
import hashlib
import os
import subprocess
import sys
import tempfile
import threading
import time

import pytest
from flask import Flask

sys.path.insert(0, str(pathlib.Path(__file__).parent.parent))

from workflow_dashboard.r6_scan_appraisal import (
    PROBE_REGISTRY,
    appraisal,
    appraisal_csv,
    approve_host_key,
    create_r6_scan_blueprint,
    classify_ssh_failure,
    filter_application_paths,
    failed_checks_csv,
    final_appraisal,
    get_trust_status,
    normalize_component_mapping,
    run_probe,
    scan_host_key,
)

# A real, readable, 0600 private-key-shaped file so the SSH key preflight
# (SSH_KEY_NOT_FOUND / SSH_KEY_UNREADABLE / SSH_KEY_INVALID / SSH_KEY_PERMISSIONS_INVALID)
# does not reject every test that exercises run_probe with a fake SSH target.
_DUMMY_KEY_PATH = pathlib.Path(tempfile.gettempdir()) / "r6_test_dummy_id_rsa"
_DUMMY_KEY_PATH.write_text("-----BEGIN OPENSSH PRIVATE KEY-----\ntest-key-material\n-----END OPENSSH PRIVATE KEY-----\n", encoding="utf-8")
if os.name != "nt":
    _DUMMY_KEY_PATH.chmod(0o600)
DUMMY_KEY = str(_DUMMY_KEY_PATH)


def result(probe_id, status="PASS", stdout="", stderr="", exit_code=0, truncated=False):
    title = next(row[1] for row in PROBE_REGISTRY if row[0] == probe_id)
    return {"probeId": probe_id, "probeName": title, "status": status, "stdout": stdout,
            "stderr": stderr, "exitCode": exit_code, "timeout": False, "truncated": truncated,
            "durationMs": 1, "evidenceCount": len(stdout.splitlines()), "remediation": "",
            "startedAt": "now", "completedAt": "now", "commandIdentifier": probe_id}


def complete_probes(overrides=None):
    overrides = overrides or {}
    defaults = {
        "SCAN-003": "Python 3.12.1",
        "SCAN-004": "101 1 app python python /opt/app/main.py",
        "SCAN-005": "app.service loaded active running",
        "SCAN-006": "tcp LISTEN 0 128 0.0.0.0:8080",
        "SCAN-007": "/opt/app/main.py",
        "SCAN-013": "0.0.0.0:8080",
    }
    return [overrides.get(row[0], result(row[0], stdout=defaults.get(row[0], "evidence"))) for row in PROBE_REGISTRY]


@pytest.mark.parametrize("stderr,code", [
    ("REMOTE HOST IDENTIFICATION HAS CHANGED! SHA256:old", "SSH_HOST_KEY_CHANGED"),
    ("ssh: connect to host 10.0.0.2 port 22: Connection timed out", "SSH_NETWORK_TIMEOUT"),
    ("ssh: connect to host 10.0.0.2 port 22: Connection refused", "SSH_CONNECTION_REFUSED"),
    ("Permission denied (publickey).", "SSH_AUTHENTICATION_FAILED"),
])
def test_structured_ssh_failure_classification(stderr, code):
    assert classify_ssh_failure(stderr, 255, False) == code


def test_remote_command_timeout_has_stable_code_and_partial_output():
    def runner(*args, **kwargs):
        raise subprocess.TimeoutExpired(args[0], 2, output="partial", stderr="still running")
    value = run_probe({"host": "10.0.0.2", "user": "scanner", "keyPath": DUMMY_KEY}, "SCAN-002", runner)
    assert value["errorCode"] == "SSH_COMMAND_TIMEOUT"
    assert value["rawExitCode"] == 124
    assert value["stdout"] == "partial"
    assert value["durationMs"] >= 0


def test_exit_124_is_recorded_as_command_timeout():
    def runner(*args, **kwargs):
        return subprocess.CompletedProcess(args[0], 124, "partial output", "")
    value = run_probe({"host": "10.0.0.2", "user": "scanner", "keyPath": DUMMY_KEY, "commandTimeout": 2}, "SCAN-002", runner)
    assert value["errorCode"] == "SSH_COMMAND_TIMEOUT"
    assert value["timedOut"] is True
    assert "2 seconds" in value["summary"]


def test_runtime_evidence_wins_over_optional_detector_exit():
    def runner(*args, **kwargs):
        return subprocess.CompletedProcess(args[0], 1, "Python 3.12.3\n", "node: not found")
    value = run_probe({"host": "10.0.0.2", "user": "scanner", "keyPath": DUMMY_KEY}, "SCAN-003", runner)
    assert value["status"] == "PASS"


def test_application_paths_found_with_permission_warning_are_successful():
    def runner(*args, **kwargs):
        return subprocess.CompletedProcess(args[0], 1, "/opt/banking-poc/services/api.py\n/opt/banking-poc/__pycache__/api.pyc\n", "find: permission denied")
    value = run_probe({"host": "10.0.0.2", "user": "scanner", "keyPath": DUMMY_KEY}, "SCAN-007", runner)
    assert value["status"] == "PASS_WITH_WARNING"
    assert filter_application_paths(value["stdout"].splitlines()) == ["/opt/banking-poc/services/api.py"]


def test_no_writable_application_path_is_not_a_failure():
    def runner(*args, **kwargs):
        return subprocess.CompletedProcess(args[0], 1, "", "")
    value = run_probe({"host": "10.0.0.2", "user": "scanner", "keyPath": DUMMY_KEY}, "SCAN-009", runner)
    assert value["status"] == "NOT_DETECTED"


def test_component_mapping_normalizes_openstack_server_uuid_and_access_fields():
    value = normalize_component_mapping({"name": "API", "openstackServerId": "server-uuid", "vmName": "api-01", "targetIp": "10.0.0.2", "cloud_region": "DFW3"}, "ubuntu")
    assert value["sourceVmId"] == "server-uuid"
    assert value["sourceVmName"] == "api-01"
    assert value["sourceIp"] == "10.0.0.2"
    assert value["sshUser"] == "ubuntu"
    assert value["scanTargetId"] == "server-uuid"


def test_scan_does_not_mark_component_pass_when_only_ssh_passes():
    probes = [result(row[0], "PASS" if row[0] == "SCAN-001" else "NOT_TESTED") for row in PROBE_REGISTRY]
    value = appraisal({"name": "API", "vmId": "vm-1"}, probes, "run-1")
    assert value["componentVerdict"] in {"NEEDS_MORE_EVIDENCE", "BLOCKED"}
    assert value["componentVerdict"] != "READY_FOR_STAGE_8"


def test_appraisal_csv_blocks_formula_injection_and_omits_raw_output():
    component = appraisal({"name": "=unsafe", "vmId": "vm-1"}, complete_probes(), "run-1")
    csv_text = appraisal_csv({"runId": "run-1", "businessSystem": {"name": "System"}}, [component])
    assert "'=unsafe" in csv_text
    assert "stdout" not in csv_text.lower()
    assert "stderr" not in csv_text.lower()


def test_each_probe_preserves_exit_code_stdout_and_stderr():
    def runner(*args, **kwargs):
        return subprocess.CompletedProcess(args[0], 7, "out-value", "err-value")
    value = run_probe({"host": "10.0.0.2", "user": "scanner", "keyPath": DUMMY_KEY}, "SCAN-002", runner)
    assert value["exitCode"] == 7
    assert value["stdout"] == "out-value"
    assert value["stderr"] == "err-value"
    assert value["status"] == "FAIL"


def test_failed_probe_is_not_hidden_by_true_fallback():
    def runner(*args, **kwargs):
        return subprocess.CompletedProcess(args[0], 9, "", "permission denied")
    value = run_probe({"host": "10.0.0.2", "user": "scanner", "keyPath": DUMMY_KEY}, "SCAN-005", runner)
    assert value["status"] == "FAIL"
    assert "permission denied" in value["stderr"]


def test_truncated_output_is_marked_explicitly():
    def runner(*args, **kwargs):
        return subprocess.CompletedProcess(args[0], 0, "x" * 70000, "")
    value = run_probe({"host": "10.0.0.2", "user": "scanner", "keyPath": DUMMY_KEY}, "SCAN-004", runner)
    assert value["truncated"] is True
    assert len(value["stdout"]) == 65536


def test_database_detection_returns_db_native_required():
    probes = complete_probes({"SCAN-019": result("SCAN-019", stdout="postgres /usr/lib/postgresql\n127.0.0.1:5432")})
    value = appraisal({"name": "Database", "vmId": "db-1"}, probes, "run-1")
    assert value["componentVerdict"] == "DB_NATIVE_REQUIRED"
    assert value["captureRecommendation"] == "DB_NATIVE"


def test_private_key_detection_blocks_container_readiness():
    # A confirmed private key in the capture path is a BLOCKER_SECURITY: the migrated
    # artifact would carry a credential, so it blocks packaging, not just "readiness".
    probes = complete_probes({"SCAN-018": result("SCAN-018", stdout="/opt/app/id_rsa")})
    value = appraisal({"name": "API", "vmId": "vm-1"}, probes, "run-1")
    assert value["componentVerdict"] == "BLOCKED_SECURITY"
    assert any(x["code"] == "PRIVATE_KEY_CAPTURE_PATH" and x["kind"] == "BLOCKER_SECURITY" for x in value["blockers"])


def test_plaintext_secret_in_config_is_review_required_not_a_hard_block():
    # A confirmed secret in a config/.env file (not source code) is REVIEW_REQUIRED:
    # normal for local config, but must not be baked into the image unchanged.
    probes = complete_probes({"SCAN-011": result("SCAN-011", stdout="/opt/app/config.env\npassword=hunter2")})
    value = appraisal({"name": "API", "vmId": "vm-1"}, probes, "run-1")
    assert value["componentVerdict"] == "REVIEW_REQUIRED"
    assert any(x["code"] == "PLAINTEXT_SECRET_ENV_FILE" for x in value["reviewRequired"])


def test_plaintext_secret_hardcoded_in_source_is_a_warning_not_a_blocker():
    # Explicit operator override: hardcoded-in-source secrets are surfaced as a warning
    # for review, not a hard block on the component/business system.
    probes = complete_probes({"SCAN-018": result("SCAN-018", stdout="PLAINTEXT_SECRET_FILE:/opt/app/settings.py")})
    value = appraisal({"name": "API", "vmId": "vm-1"}, probes, "run-1")
    assert value["componentVerdict"] != "BLOCKED_SECURITY"
    assert not any(x["code"] == "PLAINTEXT_SECRET_HARDCODED" for x in value["blockers"])
    assert any(x["code"] == "PLAINTEXT_SECRET_HARDCODED" for x in value["warnings"])


def test_plaintext_secret_file_marker_in_env_file_is_review_required():
    probes = complete_probes({"SCAN-018": result("SCAN-018", stdout="PLAINTEXT_SECRET_FILE:/opt/app/.env")})
    value = appraisal({"name": "API", "vmId": "vm-1"}, probes, "run-1")
    assert value["componentVerdict"] == "REVIEW_REQUIRED"
    assert any(x["code"] == "PLAINTEXT_SECRET_ENV_FILE" for x in value["reviewRequired"])


def test_public_certificate_is_never_treated_as_a_security_blocker():
    probes = complete_probes({"SCAN-018": result("SCAN-018", stdout="PUBLIC_CERT_FILE:/etc/ssl/certs/ca-bundle.pem")})
    value = appraisal({"name": "API", "vmId": "vm-1"}, probes, "run-1")
    assert not value["blockers"]
    assert "/etc/ssl/certs/ca-bundle.pem" in value["certificatesFound"]


def test_secret_match_confidence_is_scored_from_the_value_not_just_the_filename():
    def runner(*args, **kwargs):
        return subprocess.CompletedProcess(args[0], 0,
            "PLAINTEXT_SECRET_MATCH:/opt/app/config.yml:password=changeme\n"
            "PLAINTEXT_SECRET_MATCH:/opt/app/prod.yml:password=Tr0ub4dor&3xyz", "")
    value = run_probe({"host": "10.0.0.2", "user": "scanner", "keyPath": DUMMY_KEY}, "SCAN-018", runner)
    lines = value["stdout"].splitlines()
    assert any(l.startswith("PLAINTEXT_SECRET_LOW_CONFIDENCE_FILE:") and "config.yml" in l for l in lines)
    assert any(l.startswith("PLAINTEXT_SECRET_FILE:") and "prod.yml" in l for l in lines)
    # The raw secret value must never survive into stored/redacted stdout.
    assert "changeme" not in value["stdout"]
    assert "Tr0ub4dor" not in value["stdout"]


def test_low_confidence_secret_match_is_a_warning_not_a_blocker():
    probes = complete_probes({"SCAN-018": result("SCAN-018", stdout="PLAINTEXT_SECRET_LOW_CONFIDENCE_FILE:/opt/app/config.yml")})
    value = appraisal({"name": "API", "vmId": "vm-1"}, probes, "run-1")
    assert not value["blockers"]
    assert not value["reviewRequired"]
    assert any(w["code"] == "PLAINTEXT_SECRET_LOW_CONFIDENCE" for w in value["warnings"])


def test_unresolved_persistent_path_is_review_required_not_a_hard_block():
    # Discovery can continue; only Stage 8 deployment approval should be gated on this.
    probes = complete_probes({"SCAN-010": result("SCAN-010", status="PARTIAL")})
    value = appraisal({"name": "API", "vmId": "vm-1"}, probes, "run-1")
    assert not any(x["code"] == "PERSISTENCE_UNKNOWN" for x in value["blockers"])
    assert any(x["code"] == "PERSISTENCE_UNKNOWN" for x in value["reviewRequired"])
    assert value["componentVerdict"] == "REVIEW_REQUIRED"


def test_health_not_tested_produces_warning():
    probes = complete_probes({"SCAN-013": result("SCAN-013", status="NOT_TESTED")})
    value = appraisal({"name": "API", "vmId": "vm-1"}, probes, "run-1")
    assert any(x["code"] == "HEALTH_NOT_VALIDATED" for x in value["warnings"])
    assert value["containerReadinessScore"] <= 90


def test_unresolved_dependency_reduces_readiness_score():
    normal = appraisal({"name": "API"}, complete_probes(), "run-1")
    partial = appraisal({"name": "API"}, complete_probes({"SCAN-012": result("SCAN-012", status="PARTIAL")}), "run-1")
    assert partial["containerReadinessScore"] < normal["containerReadinessScore"]


def test_application_path_filter_excludes_ssh_files_and_host_agents():
    paths = filter_application_paths(["/opt/app/main.py", "/opt/app/agent.deb", "/home/ubuntu/.ssh/authorized_keys", "/var/www/site/index.html"])
    assert paths == ["/opt/app/main.py", "/var/www/site/index.html"]


def test_duplicate_services_generate_mapping_warning():
    base = appraisal({"name": "API A", "vmId": "vm-a"}, complete_probes(), "run-1")
    other = appraisal({"name": "API B", "vmId": "vm-b"}, complete_probes(), "run-1")
    value = final_appraisal("run-1", {"id": "sys"}, [base, other])
    assert value["mappingWarnings"]
    assert value["finalVerdict"] == "REVIEW_REQUIRED"


def test_final_verdict_allows_explicit_db_native_component():
    db = appraisal({"name": "DB", "vmId": "db"}, complete_probes({"SCAN-019": result("SCAN-019", stdout="mysqld")}), "run-1")
    value = final_appraisal("run-1", {"id": "sys"}, [db])
    assert value["finalVerdict"] == "READY"
    assert value["summary"]["databaseNative"] == 1


def test_final_verdict_blocked_security_when_required_component_has_security_blocker():
    # A private key on a required (critical-path) component is a confirmed security
    # issue that would be carried into the migrated artifact -> BLOCKED_SECURITY.
    blocked = appraisal({"name": "API"}, complete_probes({"SCAN-018": result("SCAN-018", stdout="/opt/app/id_rsa")}), "run-1")
    value = final_appraisal("run-1", {"id": "sys"}, [blocked])
    assert value["finalVerdict"] == "BLOCKED_SECURITY"
    assert value["summary"]["blocked"] == 1


def test_final_verdict_ignores_security_blocker_on_optional_component():
    # Critical-path rule: a non-required component (e.g. reporting/monitoring) with a
    # BLOCKED_SECURITY verdict must not block the whole Business System.
    blocked = appraisal({"name": "Reporting", "critical": False}, complete_probes({"SCAN-018": result("SCAN-018", stdout="/opt/app/id_rsa")}), "run-1")
    value = final_appraisal("run-1", {"id": "sys"}, [blocked])
    assert value["finalVerdict"] != "BLOCKED_SECURITY"


def test_final_verdict_ready_with_warnings_when_no_blockers_exist():
    warning = appraisal({"name": "API"}, complete_probes({"SCAN-013": result("SCAN-013", status="WARNING")}), "run-1")
    value = final_appraisal("run-1", {"id": "sys"}, [warning])
    assert value["finalVerdict"] == "READY_WITH_WARNINGS"
    assert value["summary"]["readyWithWarnings"] == 1


def test_single_component_scan_cannot_approve_full_business_system():
    component = appraisal({"name": "API"}, complete_probes(), "run-1")
    value = final_appraisal("run-1", {"id": "sys", "totalComponentCount": 6, "scanScope": "SINGLE_COMPONENT"}, [component])
    assert value["finalVerdict"] == "REVIEW_REQUIRED"
    assert value["summary"]["components"] == 1
    assert value["summary"]["totalComponents"] == 6
    assert "remaining components" in value["nextAction"]


def test_export_and_persisted_appraisal_api(monkeypatch, tmp_path):
    monkeypatch.setenv("R6_SCAN_STATE_DIR", str(tmp_path))
    def runner(argv, **kwargs):
        command = argv[-1]
        if "find /opt /srv /var/www" in command:
            output = "/opt/app/main.py"
        elif "ss -H -lntup" in command:
            output = "tcp LISTEN 0 128 0.0.0.0:8080"
        elif "python3 java node" in command:
            output = "Python 3.12.1"
        else:
            output = "evidence"
        return subprocess.CompletedProcess(argv, 0, output, "")
    app = Flask(__name__)
    app.register_blueprint(create_r6_scan_blueprint(pathlib.Path.cwd(), runner))
    client = app.test_client()
    response = client.post("/api/r6/scans/business-system/run", json={"businessSystem": {"id": "sys", "name": "System", "components": [{"name": "API", "vmId": "vm-1", "sshHost": "10.0.0.2"}]}, "ssh": {"user": "scanner", "keyPath": DUMMY_KEY}})
    assert response.status_code == 202
    run_id = response.get_json()["runId"]
    for _ in range(100):
        data = client.get("/api/r6/scans/runs/" + run_id).get_json()
        if data["status"] != "RUNNING": break
        time.sleep(.005)
    assert data["status"] == "COMPLETE"
    assert data["components"][0]["probes"]
    assert client.get("/api/r6/scans/runs/%s/appraisal" % run_id).status_code == 200
    exported = client.get("/api/r6/scans/runs/%s/export" % run_id)
    assert exported.status_code == 200
    all_csv = client.get("/api/r6/scans/runs/%s/appraisals.csv" % run_id)
    component_csv = client.get("/api/r6/scans/runs/%s/components/api/appraisal.csv" % run_id)
    failed_csv = client.get("/api/r6/scans/runs/%s/failed-checks.csv" % run_id)
    assert all_csv.status_code == 200
    assert component_csv.status_code == 200
    assert failed_csv.status_code == 200
    assert all_csv.mimetype == "text/csv"
    assert "all-appraisal-results.csv" in all_csv.headers["Content-Disposition"]
    assert "api-appraisal-result.csv" in component_csv.headers["Content-Disposition"]
    csv_text = component_csv.get_data(as_text=True)
    assert "scan_run_id,business_system,component_id,component_name" in csv_text
    assert "probe_id,probe_name,probe_status" in csv_text
    assert "stdout" not in csv_text.lower()
    assert "stderr" not in csv_text.lower()
    assert data["liveLog"]
    started_events = [event for event in data["liveLog"] if event.get("message") == "Probe started"]
    probe_events = [event for event in data["liveLog"] if event.get("message") == "Probe completed"]
    assert len(started_events) == len(PROBE_REGISTRY) - 1  # cloud-side snapshot check does not SSH
    assert len(probe_events) == len(PROBE_REGISTRY)
    assert {"status", "exitCode", "durationMs", "stdout", "stderr", "timeout",
            "truncated", "evidenceCount", "commandIdentifier", "remediation"}.issubset(probe_events[0])
    assert {"targetHost", "targetPort", "sourceVmId", "phase"}.issubset(probe_events[0])
    poll_response = client.get("/api/r6/scans/runs/" + run_id)
    assert "no-store" in poll_response.headers["Cache-Control"]
    assert (tmp_path / run_id / "evidence-checksums.json").is_file()
    assert (tmp_path / run_id / "scan-report.md").is_file()


def test_multiple_components_on_one_vm_reuse_one_probe_set(monkeypatch, tmp_path):
    monkeypatch.setenv("R6_SCAN_STATE_DIR", str(tmp_path))
    calls = []
    def runner(argv, **kwargs):
        calls.append(argv[-1])
        output = "/opt/app/main.py" if "find /opt /srv /var/www" in argv[-1] else "evidence"
        return subprocess.CompletedProcess(argv, 0, output, "")
    app = Flask(__name__)
    app.register_blueprint(create_r6_scan_blueprint(pathlib.Path.cwd(), runner))
    client = app.test_client()
    response = client.post("/api/r6/scans/business-system/run", json={"businessSystem": {"id": "sys", "components": [{"name": "Auth", "vmId": "vm-1", "sshHost": "10.0.0.2"}, {"name": "Core", "vmId": "vm-1", "sshHost": "10.0.0.2"}]}, "ssh": {"user": "scanner", "keyPath": DUMMY_KEY}})
    run_id = response.get_json()["runId"]
    for _ in range(100):
        data = client.get("/api/r6/scans/runs/" + run_id).get_json()
        if data["status"] != "RUNNING": break
        time.sleep(.005)
    assert len(data["components"]) == 2
    assert len(calls) == 19


def test_component_card_uses_structured_probe_results():
    script = (pathlib.Path(__file__).parent.parent / "workflow_dashboard" / "static" / "r6ace.js").read_text()
    assert "Business System Final Verdict" in script
    assert "View Appraisal" in script
    assert "containerReadinessScore" in script
    assert "captureRecommendation" in script
    assert "p.stderr" in script
    assert "r6pAppraisalAllowsStage8" in script
    assert "Export All Appraisal Results CSV" in script
    assert "Export Result CSV" in script
    assert "Failed Checks by Component" in script
    assert "r6pFormatProductionScanLog" in script
    assert "r6pExportFailedChecksCsv" in script
    assert "STDOUT:" in script
    assert "STDERR:" in script
    assert "evidence-lines=" in script
    assert "R6 VERBOSE COMPONENT SCAN" in script
    assert "Diagnostic events:" in script
    assert "target:" in script
    assert "cache:'no-store'" in script


def test_retry_component_reruns_only_failed_and_partial_probes(monkeypatch, tmp_path):
    monkeypatch.setenv("R6_SCAN_STATE_DIR", str(tmp_path))
    calls = []
    fail_health = {"value": True}
    health_command = next(row[2] for row in PROBE_REGISTRY if row[0] == "SCAN-013")
    def runner(argv, **kwargs):
        calls.append(argv[-1])
        if argv[-1] == health_command and fail_health["value"]:
            return subprocess.CompletedProcess(argv, 3, "", "health probe failed")
        output = "/opt/app/main.py" if "find /opt /srv /var/www" in argv[-1] else "evidence"
        return subprocess.CompletedProcess(argv, 0, output, "")
    app = Flask(__name__)
    app.register_blueprint(create_r6_scan_blueprint(pathlib.Path.cwd(), runner))
    client = app.test_client()
    start = client.post("/api/r6/scans/business-system/run", json={"businessSystem": {"id": "sys", "components": [{"name": "API", "vmId": "vm", "sshHost": "10.0.0.2"}]}, "ssh": {"user": "scanner", "keyPath": DUMMY_KEY}})
    run_id = start.get_json()["runId"]
    for _ in range(100):
        run = client.get("/api/r6/scans/runs/" + run_id).get_json()
        if run["status"] != "RUNNING": break
        time.sleep(.005)
    before = len(calls)
    fail_health["value"] = False
    retried = client.post("/api/r6/scans/runs/%s/components/api/retry" % run_id, json={"ssh": {"user": "scanner", "keyPath": DUMMY_KEY}})
    assert retried.status_code == 200
    assert retried.get_json()["retried"] == ["SCAN-001", "SCAN-013"]
    assert len(calls) == before + 2


def _wait_for_run(client, run_id):
    for _ in range(200):
        data = client.get("/api/r6/scans/runs/" + run_id).get_json()
        if data["status"] != "RUNNING":
            return data
        time.sleep(.005)
    raise AssertionError("scan did not complete")


def test_one_ssh_failure_has_one_root_and_eighteen_skips(monkeypatch, tmp_path):
    monkeypatch.setenv("R6_SCAN_STATE_DIR", str(tmp_path))
    def runner(argv, **kwargs):
        return subprocess.CompletedProcess(argv, 255, "", "ssh: connect to host 10.0.0.2 port 22: Connection timed out")
    app = Flask(__name__); app.register_blueprint(create_r6_scan_blueprint(pathlib.Path.cwd(), runner)); client = app.test_client()
    started = client.post("/api/r6/scans/business-system/run", json={"businessSystem": {"id": "sys", "components": [{"name": "API", "vmId": "vm-1", "sshHost": "10.0.0.2"}]}, "ssh": {"user": "ubuntu", "keyPath": DUMMY_KEY}})
    run = _wait_for_run(client, started.get_json()["runId"]); component = run["components"][0]
    assert sum(p["status"] in {"FAIL", "BLOCKED"} for p in component["probes"]) == 1
    assert sum(p["status"] == "SKIPPED_PREREQUISITE" for p in component["probes"]) == 18
    assert component["probes"][0]["errorCode"] == "SSH_NETWORK_TIMEOUT"
    assert run["appraisal"]["finalVerdict"] == "BLOCKED_INFRASTRUCTURE"
    assert run["appraisal"]["snapshotReadiness"] in {"PARTIAL", "READY"}


def test_no_vm_mapping_and_no_endpoint_is_explicit_root_blocker(monkeypatch, tmp_path):
    # Neither an OpenStack UUID nor a host/IP: there is genuinely nothing to scan.
    monkeypatch.setenv("R6_SCAN_STATE_DIR", str(tmp_path)); calls = []
    def runner(argv, **kwargs): calls.append(argv); return subprocess.CompletedProcess(argv, 0, "", "")
    app = Flask(__name__); app.register_blueprint(create_r6_scan_blueprint(pathlib.Path.cwd(), runner)); client = app.test_client()
    started = client.post("/api/r6/scans/business-system/run", json={"businessSystem": {"id": "sys", "components": [{"name": "API"}]}, "ssh": {"user": "ubuntu", "keyPath": DUMMY_KEY}})
    run = _wait_for_run(client, started.get_json()["runId"]); probe = run["components"][0]["probes"][0]
    assert probe["errorCode"] == "COMPONENT_VM_MAPPING_MISSING"
    assert run["components"][0]["sourceVmId"] is None
    assert not calls


def test_vm_mapping_missing_but_host_present_allows_guest_discovery(monkeypatch, tmp_path):
    # Has an IP but no OpenStack UUID: guest discovery over SSH must still proceed;
    # only snapshot/cloud-based capture (SCAN-020) is affected.
    monkeypatch.setenv("R6_SCAN_STATE_DIR", str(tmp_path)); calls = []
    def runner(argv, **kwargs): calls.append(argv); return subprocess.CompletedProcess(argv, 0, "evidence", "")
    app = Flask(__name__); app.register_blueprint(create_r6_scan_blueprint(pathlib.Path.cwd(), runner)); client = app.test_client()
    started = client.post("/api/r6/scans/business-system/run", json={"businessSystem": {"id": "sys", "components": [{"name": "API", "sshHost": "10.0.0.2"}]}, "ssh": {"user": "ubuntu", "keyPath": DUMMY_KEY}})
    run = _wait_for_run(client, started.get_json()["runId"])
    component = run["components"][0]
    assert calls
    assert component["sourceVmId"] is None
    snapshot_probe = next(p for p in component["probes"] if p["probeId"] == "SCAN-020")
    assert snapshot_probe["status"] == "NOT_TESTED"
    assert snapshot_probe["errorCode"] == "VM_UUID_UNMAPPED"
    assert any(w["code"] == "VM_UUID_UNMAPPED" for w in component["warnings"])
    assert component["componentVerdict"] != "BLOCKED"


def test_managed_database_runs_without_ssh(monkeypatch, tmp_path):
    monkeypatch.setenv("R6_SCAN_STATE_DIR", str(tmp_path)); calls = []
    def runner(argv, **kwargs): calls.append(argv); return subprocess.CompletedProcess(argv, 0, "", "")
    app = Flask(__name__); app.register_blueprint(create_r6_scan_blueprint(pathlib.Path.cwd(), runner)); client = app.test_client()
    started = client.post("/api/r6/scans/business-system/run", json={"businessSystem": {"id": "sys", "components": [{"name": "Orders DB", "type": "Database", "databaseAccessMode": "MANAGED_DATABASE", "databaseEndpoint": "postgresql://db.internal:5432/orders", "databaseReachability": "REACHABLE"}]}})
    assert started.status_code == 202
    run = _wait_for_run(client, started.get_json()["runId"]); probes = {p["probeId"]: p for p in run["components"][0]["probes"]}
    assert probes["SCAN-001"]["status"] == "NOT_APPLICABLE"
    assert probes["SCAN-019"]["status"] == "PASS"
    assert run["appraisal"]["databaseReadiness"] == "READY"
    assert not calls


def test_secret_values_are_redacted_from_probe_evidence():
    def runner(*args, **kwargs):
        return subprocess.CompletedProcess(args[0], 0, "API_TOKEN=super-secret\npostgresql://user:password@db/app", "")
    value = run_probe({"host": "10.0.0.2", "user": "scanner", "keyPath": DUMMY_KEY}, "SCAN-018", runner)
    assert "super-secret" not in value["stdout"]
    assert "user:password" not in value["stdout"]
    assert "[REDACTED]" in value["stdout"]


def test_all_checks_pass_has_ready_multidimensional_verdict():
    component = appraisal({"name": "API", "vmId": "vm-1"}, complete_probes(), "run-1")
    value = final_appraisal("run-1", {"id": "sys"}, [component])
    assert value["finalVerdict"] == "READY"
    assert value["infrastructureAccessStatus"] == "READY"
    assert value["applicationReadiness"] == "READY"


def test_failed_csv_defaults_to_root_causes_and_tracks_skipped_dependents():
    root = {"rootCauseId": "api:ssh", "componentId": "api", "componentName": "API", "sourceVmId": "vm-1", "probeId": "SCAN-001", "errorCode": "SSH_NETWORK_TIMEOUT", "summary": "Port 22 timed out", "recommendedActions": ["Check security group"], "skippedChecks": 18}
    csv_text = failed_checks_csv({"runId": "run-1", "appraisal": {"rootCauses": [root]}, "components": []})
    assert csv_text.count("SSH_NETWORK_TIMEOUT") == 1
    assert "derived_from" in csv_text.splitlines()[0]
    assert ",18," in csv_text


def test_host_key_replacement_requires_approval_and_matching_fingerprint(tmp_path):
    key_blob = base64.b64encode(b"verified-public-key").decode()
    fingerprint = "SHA256:" + base64.b64encode(hashlib.sha256(b"verified-public-key").digest()).decode().rstrip("=")
    line = "10.0.0.2 ssh-ed25519 " + key_blob
    def runner(argv, **kwargs):
        return subprocess.CompletedProcess(argv, 0, line + "\n" if argv[0] == "ssh-keyscan" else "old key removed", "")
    app = Flask(__name__); app.register_blueprint(create_r6_scan_blueprint(pathlib.Path.cwd(), runner)); client = app.test_client()
    denied = client.post("/api/r6/scans/known-hosts/verify-and-replace", json={"host": "10.0.0.2", "expectedFingerprint": fingerprint})
    assert denied.status_code == 409
    known_hosts = tmp_path / "known_hosts"
    approved = client.post("/api/r6/scans/known-hosts/verify-and-replace", json={"approved": True, "host": "10.0.0.2", "expectedFingerprint": fingerprint, "knownHostsFile": str(known_hosts)})
    assert approved.status_code == 200
    assert line in known_hosts.read_text()


# ---------------------------------------------------------------------------
# Approve Fingerprint workflow -- 13-case matrix from the design spec.
# ---------------------------------------------------------------------------

def _keyscan_line(host, key_material=b"key-material-a", key_type="ssh-ed25519"):
    return "%s %s %s" % (host, key_type, base64.b64encode(key_material).decode())


def _fingerprint_of(key_material=b"key-material-a"):
    return "SHA256:" + base64.b64encode(hashlib.sha256(key_material).digest()).decode().rstrip("=")


def _keyscan_runner(line):
    def runner(argv, **kwargs):
        if argv[0] == "ssh-keyscan":
            return subprocess.CompletedProcess(argv, 0, line + "\n", "")
        return subprocess.CompletedProcess(argv, 0, "", "")
    return runner


def test_1_unknown_host_is_scanned_and_displayed(tmp_path):
    runner = _keyscan_runner(_keyscan_line("10.1.1.1"))
    status = get_trust_status("10.1.1.1", 22, tmp_path / "known_hosts", runner)
    assert status["status"] == "UNKNOWN"
    assert status["fingerprint"] == _fingerprint_of()
    assert status["keyType"] == "ssh-ed25519"


def test_2_approving_a_fingerprint_adds_exactly_one_entry(tmp_path):
    known_hosts = tmp_path / "known_hosts"
    runner = _keyscan_runner(_keyscan_line("10.1.1.2"))
    result, code = approve_host_key("10.1.1.2", 22, _fingerprint_of(), known_hosts, runner)
    assert code == 200 and result["ok"] is True
    lines = [l for l in known_hosts.read_text().splitlines() if l.strip()]
    assert len(lines) == 1
    assert lines[0].startswith("10.1.1.2 ")


def test_3_reapproving_the_same_fingerprint_does_not_duplicate(tmp_path):
    known_hosts = tmp_path / "known_hosts"
    runner = _keyscan_runner(_keyscan_line("10.1.1.3"))
    approve_host_key("10.1.1.3", 22, _fingerprint_of(), known_hosts, runner)
    approve_host_key("10.1.1.3", 22, _fingerprint_of(), known_hosts, runner)
    lines = [l for l in known_hosts.read_text().splitlines() if l.strip()]
    assert len(lines) == 1


def test_4_non_default_port_uses_bracket_port_syntax(tmp_path):
    known_hosts = tmp_path / "known_hosts"
    # Real ssh-keyscan itself emits the [host]:port token as the line's host field for
    # non-default ports; the fake runner mirrors that so the assertion reflects reality.
    runner = _keyscan_runner(_keyscan_line("[10.1.1.4]:2222"))
    result, code = approve_host_key("10.1.1.4", 2222, _fingerprint_of(), known_hosts, runner)
    assert code == 200
    assert known_hosts.read_text().startswith("[10.1.1.4]:2222 ")


def test_5_existing_trusted_fingerprint_is_recognized(tmp_path):
    known_hosts = tmp_path / "known_hosts"
    runner = _keyscan_runner(_keyscan_line("10.1.1.5"))
    approve_host_key("10.1.1.5", 22, _fingerprint_of(), known_hosts, runner)
    status = get_trust_status("10.1.1.5", 22, known_hosts, runner)
    assert status["status"] == "TRUSTED"


def test_6_changed_fingerprint_returns_changed_and_is_not_overwritten(tmp_path):
    known_hosts = tmp_path / "known_hosts"
    runner_a = _keyscan_runner(_keyscan_line("10.1.1.6", b"key-a"))
    approve_host_key("10.1.1.6", 22, _fingerprint_of(b"key-a"), known_hosts, runner_a)
    original = known_hosts.read_text()
    runner_b = _keyscan_runner(_keyscan_line("10.1.1.6", b"key-b"))
    status = get_trust_status("10.1.1.6", 22, known_hosts, runner_b)
    assert status["status"] == "CHANGED"
    assert status["trustedFingerprint"] == _fingerprint_of(b"key-a")
    assert status["fingerprint"] == _fingerprint_of(b"key-b")
    assert known_hosts.read_text() == original  # a read-only status check must never write


def test_7_explicit_replacement_removes_only_the_matching_host_port_entry(tmp_path):
    known_hosts = tmp_path / "known_hosts"
    approve_host_key("10.1.1.7", 22, _fingerprint_of(b"key-a"), known_hosts, _keyscan_runner(_keyscan_line("10.1.1.7", b"key-a")))
    approve_host_key("10.1.1.8", 22, _fingerprint_of(b"key-x"), known_hosts, _keyscan_runner(_keyscan_line("10.1.1.8", b"key-x")))
    approve_host_key("10.1.1.7", 22, _fingerprint_of(b"key-b"), known_hosts, _keyscan_runner(_keyscan_line("10.1.1.7", b"key-b")))
    lines = [l for l in known_hosts.read_text().splitlines() if l.strip()]
    assert len(lines) == 2
    assert any(l.startswith("10.1.1.8 ") for l in lines)
    host7 = [l for l in lines if l.startswith("10.1.1.7 ")]
    assert len(host7) == 1
    assert _known_host_fp(host7[0]) == _fingerprint_of(b"key-b")


def _known_host_fp(line):
    fields = line.split()
    return "SHA256:" + base64.b64encode(hashlib.sha256(base64.b64decode(fields[2])).digest()).decode().rstrip("=")


def test_8_concurrent_approvals_do_not_corrupt_known_hosts(tmp_path):
    known_hosts = tmp_path / "known_hosts"
    hosts = ["10.2.0.%d" % i for i in range(1, 9)]
    def worker(host):
        approve_host_key(host, 22, _fingerprint_of(host.encode()), known_hosts, _keyscan_runner(_keyscan_line(host, host.encode())))
    threads = [threading.Thread(target=worker, args=(h,)) for h in hosts]
    for t in threads: t.start()
    for t in threads: t.join()
    text = known_hosts.read_text()
    lines = [l for l in text.splitlines() if l.strip()]
    assert len(lines) == len(hosts)  # no torn writes, no lost/duplicated entries
    for h in hosts:
        assert sum(1 for l in lines if l.startswith(h + " ")) == 1


def test_9_file_permissions_are_0600(tmp_path):
    if os.name == "nt":
        pytest.skip("POSIX permission bits are not meaningful on Windows")
    known_hosts = tmp_path / "sub" / "known_hosts"
    approve_host_key("10.1.1.9", 22, _fingerprint_of(), known_hosts, _keyscan_runner(_keyscan_line("10.1.1.9")))
    assert oct(known_hosts.stat().st_mode)[-3:] == "600"
    assert oct(known_hosts.parent.stat().st_mode)[-3:] == "700"


def test_10_ssh_retry_uses_strict_host_key_checking_yes():
    captured = {}
    def runner(argv, **kwargs):
        captured["argv"] = argv
        return subprocess.CompletedProcess(argv, 0, "", "")
    run_probe({"host": "10.1.1.10", "user": "scanner", "keyPath": DUMMY_KEY}, "SCAN-001", runner)
    assert "-o" in captured["argv"] and "StrictHostKeyChecking=yes" in captured["argv"]
    assert "UserKnownHostsFile=/dev/null" not in " ".join(captured["argv"])


def test_11_ui_never_disables_host_key_checking_or_uses_dev_null():
    script = (pathlib.Path(__file__).parent.parent / "workflow_dashboard" / "static" / "r6ace.js").read_text()
    start = script.index("=== SSH HOST IDENTITY / APPROVE FINGERPRINT WORKFLOW ===")
    end = script.index("=== END SSH HOST IDENTITY WORKFLOW ===")
    section = script[start:end]
    assert "StrictHostKeyChecking=no" not in section
    assert "UserKnownHostsFile=/dev/null" not in section
    assert "r6pApproveFingerprint" in section
    assert "r6pCopyHostIdentityLog" in section


def test_12_audit_log_never_contains_credentials(tmp_path):
    known_hosts = tmp_path / "known_hosts"
    approve_host_key("10.1.1.12", 22, _fingerprint_of(), known_hosts, _keyscan_runner(_keyscan_line("10.1.1.12")),
                      actor="alice", action="APPROVE", vm_id="vm-42")
    audit_path = known_hosts.parent / "known_hosts_audit.jsonl"
    entries = [json.loads(l) for l in audit_path.read_text().splitlines() if l.strip()]
    assert len(entries) == 1
    entry = entries[0]
    assert set(entry) == {"timestamp", "actor", "action", "vmId", "host", "port", "fingerprint", "result"}
    assert entry["actor"] == "alice" and entry["vmId"] == "vm-42" and entry["result"] == "TRUSTED"
    assert "keyPath" not in entry and "password" not in json.dumps(entry).lower()


def test_13_invalid_host_cannot_trigger_command_injection(tmp_path):
    calls = []
    def runner(argv, **kwargs):
        calls.append(argv)
        return subprocess.CompletedProcess(argv, 0, "", "")
    known_hosts = tmp_path / "known_hosts"
    result, code = approve_host_key("10.0.0.2; rm -rf /", 22, _fingerprint_of(), known_hosts, runner)
    assert code == 400 and result["ok"] is False
    assert not calls  # the malicious host string must never reach a subprocess argv
    status = get_trust_status("$(whoami)", 22, known_hosts, runner)
    assert status["status"] == "UNREACHABLE"
    assert not calls
