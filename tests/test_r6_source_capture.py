"""Regression tests for R6 Stage 9 source capture gating."""
import copy
import pathlib
import sys

import pytest

sys.path.insert(0, str(pathlib.Path(__file__).parent.parent))

import workflow_dashboard.app as dashboard

app = dashboard.app


@pytest.fixture(autouse=True)
def fake_openstack(monkeypatch, tmp_path):
    calls = []
    counter = {"value": 0}

    def run(args):
        calls.append(list(args))
        if "create" in args:
            counter["value"] += 1
            return {"id": "snapshot-%s" % counter["value"]}
        return {"status": "available"}

    monkeypatch.setenv("R6_CAPTURE_STATE_DIR", str(tmp_path / "captures"))
    monkeypatch.setattr(dashboard, "_r6_openstack_json", run)
    return calls


def _payload():
    return {
        "stage8Approved": True,
        "org": "rackspace-flex",
        "cluster": "flex-prod-k8s",
        "region": "iad3",
        "registry": {"type": "harbor", "project": "flex-apps"},
        "source_vm": {"host": "10.0.0.10", "user": "root"},
        "auto_commit": False,
        "import_to_gitops": False,
        "businessSystem": {
            "name": "Capture Regression",
            "components": [
                {"name": "api", "tgt": "10.0.0.10", "path": "/opt/api", "volumes": ["vol-api"]},
                {"name": "db", "tgt": "10.0.0.11", "path": "/var/lib/postgresql"},
            ],
        },
        "bundle": {
            "id": "capture-regression",
            "businessSystemName": "Capture Regression",
            "workloads": [
                {
                    "component": "api",
                    "targetForm": "CONTAINERIZED",
                    "targetIp": "10.0.0.10",
                    "sourcePath": "/opt/api",
                    "readiness": "READY",
                    "image": "debian:stable-slim",
                    "startCommand": "python3 -m http.server 8080",
                    "persistentPath": "None - stateless",
                },
                {
                    "component": "db",
                    "targetForm": "OPERATOR_MANAGED",
                    "targetIp": "10.0.0.11",
                    "sourcePath": "/var/lib/postgresql",
                    "readiness": "KEEP_ON_VM_FOR_NOW",
                    "image": "postgres:16",
                },
            ],
        },
    }


def test_capture_requires_stage8_approval(fake_openstack):
    client = app.test_client()
    payload = _payload()
    payload["stage8Approved"] = False
    response = client.post("/api/r6/capture-sources-build", json=payload)
    assert response.status_code == 400
    assert "Stage 8 approval" in response.get_json()["error"]
    assert fake_openstack == []


def test_capture_only_snapshots_container_targets_and_records_lineage(fake_openstack):
    client = app.test_client()
    response = client.post("/api/r6/capture-sources-build", json=_payload())
    data = response.get_json()
    assert response.status_code == 200
    assert data["ok"] is True
    assert data["capture"]["approvedCount"] == 1
    api = next(row for row in data["capture"]["components"] if row["component"] == "api")
    db = next(row for row in data["capture"]["components"] if row["component"] == "db")
    assert api["containerizationApproved"] is True
    assert api["snapshotIds"]
    assert api["lineage"]["sourceChecksum"]
    assert db["containerizationApproved"] is False
    assert db["snapshotStatus"] == "NOT_APPLICABLE"
    assert "source-capture-manifest.json" in data["files"]
    assert "source-lineage.json" in data["files"]
    creates = [call for call in fake_openstack if "create" in call]
    assert len(creates) == 1
    assert "vol-api" in creates[0]
    assert "10.0.0.11" not in str(creates)


def test_capture_blocks_database_paths_for_container_images():
    client = app.test_client()
    payload = _payload()
    payload["bundle"]["workloads"][0]["sourcePath"] = "/var/lib/mysql"
    response = client.post("/api/r6/capture-sources-build", json=payload)
    assert response.status_code == 400
    assert "blocked path" in response.get_json()["error"]


def test_capture_blocks_secret_like_metadata():
    client = app.test_client()
    payload = _payload()
    payload["bundle"]["workloads"][0]["env"] = {"R6_TEST": "password=supersecret"}
    response = client.post("/api/r6/capture-sources-build", json=payload)
    assert response.status_code == 400
    assert "secret-like material" in response.get_json()["error"]


def test_capture_reuses_existing_snapshot_lineage(fake_openstack):
    client = app.test_client()
    first = client.post("/api/r6/capture-sources-build", json=_payload())
    assert first.status_code == 200
    second = client.post("/api/r6/capture-sources-build", json=copy.deepcopy(_payload()))
    data = second.get_json()
    assert second.status_code == 200
    assert data["capture"]["reusedSnapshots"] >= 1
    assert len([call for call in fake_openstack if "create" in call]) == 1


def test_vm_snapshot_and_image_lineage_is_recorded(fake_openstack):
    payload = _payload()
    payload["businessSystem"]["components"][0]["volumes"] = []
    payload["businessSystem"]["components"][0]["vmId"] = "vm-api-id"
    response = app.test_client().post("/api/r6/capture-sources-build", json=payload)
    assert response.status_code == 200
    row = response.get_json()["capture"]["components"][0]
    assert row["lineage"]["sourceVm"] == "vm-api-id"
    assert row["lineage"]["volumeIds"] == []
    assert row["lineage"]["snapshotIds"] == ["snapshot-1"]
    assert row["lineage"]["sourceChecksum"]
    assert any(call[:3] == ["server", "image", "create"] for call in fake_openstack)
    data = response.get_json()
    build_script = (pathlib.Path(data["bundle_dir"]) / "build_and_push.sh").read_text()
    assert "sourceChecksum" in build_script
    assert '"snapshotIds":["snapshot-1"]' in build_script
    assert '"digest":"%s"' in build_script


def test_all_component_scan_freezes_operator_credentials_for_batch():
    script = (pathlib.Path(__file__).parent.parent / "workflow_dashboard" / "static" / "r6ace.js").read_text()
    assert "var batchCredentials=" in script
    assert "r6pRunLiveScan(function(ok){if(ok)passed++;else failed++;next();},true,batchCredentials)" in script
    assert "credentials&&credentials.user" in script
    assert "credentials&&credentials.key" in script


def test_live_scan_does_not_use_stale_operator_known_hosts():
    script = (pathlib.Path(__file__).parent.parent / "workflow_dashboard" / "static" / "r6ace.js").read_text()
    assert "-o UserKnownHostsFile=/dev/null" in script
    assert "-o GlobalKnownHostsFile=/dev/null" in script


def test_stage9_button_filters_capture_payload_after_stage8_only():
    script = (pathlib.Path(__file__).parent.parent / "workflow_dashboard" / "static" / "r6ace.js").read_text()
    func = script.split("window.r6pGenRealDockerfiles=function(){", 1)[1].split("fetch('/api/r6/capture-sources-build'", 1)[0]
    assert "r6pStage8ApprovedForCapture()" in func
    assert "Stage 8 approval required before source capture" in func
    assert "r6pStage9ApprovedContainerTargets().filter(function(c){return c.tgt;})" in func
    assert "var comps=R6P.components.filter(function(c){return c.tgt;});" not in func
    assert "sourceVmId:c.vmId||c.serverId||c.instanceId||''" in func
    assert "volumeIds:c.volumes||c.volumeIds||[]" in func


def test_stage9_ui_excludes_database_like_components_from_capture_targets():
    script = (pathlib.Path(__file__).parent.parent / "workflow_dashboard" / "static" / "r6ace.js").read_text()
    assert "r6pStage9IsDatabaseLike" in script
    assert "form==='DATA_MIGRATION_REQUIRED'" in script
    assert "txt.indexOf('database')>=0" in script
    assert "!r6pStage9IsDatabaseLike(c)" in script
    assert "Retained VMs, operators, databases, external services, blocked and excluded components are skipped" in script
