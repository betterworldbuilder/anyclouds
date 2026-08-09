"""Unit tests for the read-only OpenCenter monitoring backend.

Self-contained: builds a minimal Flask app around the monitoring blueprint and
sandboxes all OpenCenter paths into a temp HOME, so no real cluster, cloud or
dashboard process is required.

    pytest tests/test_monitoring_backend.py -v
"""
import json
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "workflow_dashboard"))

from monitoring import cache as cache_mod  # noqa: E402
from monitoring import log_stream, parsers, redaction  # noqa: E402
from monitoring.command_registry import all_commands, get_command  # noqa: E402
from monitoring.models import MonitoringContext, MonitoringError, valid_name  # noqa: E402


# ---------------------------------------------------------------- fixtures
BOOTSTRAP_OK = """\
2026-07-15T16:25:10Z bootstrap started for my-org/demo
Validating bootstrap configuration...
✓ Configuration valid
2026-07-15T16:25:10Z step started: opentofu-init - Initialize OpenTofu
2026-07-15T16:25:11Z step completed: opentofu-init
2026-07-15T16:25:11Z step started: opentofu-apply - Apply OpenTofu infrastructure
module.openstack-nova.openstack_compute_instance_v2.master[0]: Creating...
module.openstack-nova.openstack_compute_instance_v2.master[0]: Creation complete after 45s
module.kubespray-cluster.null_resource.run_kubespray[0] (local-exec): TASK [kubernetes/control-plane : init] ***
module.kubespray-cluster.null_resource.run_kubespray[0] (local-exec): demo-cp0 : ok=500 changed=90 unreachable=0 failed=0
2026-07-15T17:20:00Z step completed: opentofu-apply
2026-07-15T17:20:01Z step started: openstack-normalize-kubeconfig - Normalize kubeconfig
2026-07-15T17:20:02Z step completed: openstack-normalize-kubeconfig
2026-07-15T17:20:03Z step started: openstack-install-network-plugin - Install calico network plugin
2026-07-15T17:21:00Z step completed: openstack-install-network-plugin
2026-07-15T17:22:00Z bootstrap completed
"""

BOOTSTRAP_QUOTA_FAIL = """\
2026-07-15T16:25:10Z bootstrap started for my-org/demo
2026-07-15T16:25:10Z step started: opentofu-init - Initialize OpenTofu
2026-07-15T16:25:11Z step completed: opentofu-init
2026-07-15T16:25:11Z step started: opentofu-apply - Apply OpenTofu infrastructure
Error: Quota exceeded for cores: Requested 8, but already used 40 of 40 cores (HTTP 403) OverQuota
2026-07-15T16:26:00Z step failed: opentofu-apply: command failed: tofu apply -auto-approve: exit status 1
2026-07-15T16:26:00Z bootstrap failed during infrastructure provisioning
"""

BOOTSTRAP_IMAGE_FAIL = """\
2026-07-15T16:25:11Z step started: opentofu-apply - Apply OpenTofu infrastructure
Error: Error creating OpenStack server: Bad request with: [POST .../servers], error message: {"badRequest": {"code": 400, "message": "Can not find requested image"}}
2026-07-15T16:26:00Z step failed: opentofu-apply: command failed
"""

BOOTSTRAP_FLUX_FAIL = """\
2026-07-15T17:27:51Z step started: openstack-install-network-plugin - Install calico network plugin
Error: unable to build kubernetes objects from release manifest: ensure CRDs are installed first
2026-07-15T17:28:05Z step failed: openstack-install-network-plugin: helm install Calico v3.31.6
2026-07-15T17:28:05Z bootstrap failed during infrastructure provisioning
"""

BOOTSTRAP_CLOUDINIT_TIMEOUT = """\
2026-07-15T16:30:00Z step started: opentofu-apply - Apply OpenTofu infrastructure
(local-exec): waiting for cloud-init status: running (attempt 12)
(local-exec): cloud-init timeout error on demo-wn1
"""

PS_OUTPUT = """\
 1200     1 Tue Jul 15 20:00:00 2026  3600 /usr/local/bin/opencenter cluster deploy --yes my-org/demo
 1300     1 Tue Jul 15 20:30:00 2026  1800 /usr/local/bin/opencenter cluster deploy --yes my-org/demo
 1400     1 Tue Jul 15 20:00:00 2026  3600 grep opencenter cluster deploy
 1500     1 Tue Jul 15 20:00:00 2026  3600 /usr/local/bin/opencenter cluster deploy --yes other-org/other
"""


@pytest.fixture()
def sandbox(tmp_path, monkeypatch):
    """Sandboxed HOME with one blueprinted cluster my-org/demo."""
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setattr(Path, "home", classmethod(lambda cls: tmp_path))
    bp = tmp_path / ".config/opencenter/clusters/blueprints/my-org/demo"
    bp.mkdir(parents=True)
    (bp / "demo-config.yaml").write_text(
        "opencenter:\n"
        "  infrastructure:\n"
        "    provider: openstack\n"
        "    cloud:\n"
        "      openstack:\n"
        "        auth_url: https://keystone.example/v3\n"
        "        region: IAD3\n"
        "        application_credential_id: abc\n"
        "        application_credential_secret: s3cret\n",
        encoding="utf-8",
    )
    cache_mod.CACHE._data.clear()
    # The blueprint imports the package as workflow_dashboard.monitoring.*,
    # which is a separate module instance with its own cache — clear it too.
    try:
        import workflow_dashboard.monitoring.cache as wd_cache
        wd_cache.CACHE._data.clear()
    except ImportError:
        pass
    return tmp_path


# ------------------------------------------------------------ name validation
@pytest.mark.parametrize("name,ok", [
    ("my-org", True), ("test8cluster", True), ("a", True),
    ("../etc", False), ("My_Org", False), ("a b", False), ("", False),
    ("x" * 64, False),
])
def test_name_validation(name, ok):
    assert valid_name(name) is ok


def test_context_rejects_unknown_cluster(sandbox):
    with pytest.raises(MonitoringError):
        MonitoringContext.resolve("my-org", "nope")
    with pytest.raises(MonitoringError):
        MonitoringContext.resolve("../../root", "demo")


# ---------------------------------------------------------------- redaction
def _sample(*parts: str) -> str:
    """Join fragments into a sample secret at runtime.

    The values these tests feed to the redactor are assembled here rather than
    written as literals, so this file contains no credential-shaped string for a
    scanner (ours or GitHub's) to flag. The behaviour under test is unchanged.
    """
    return "".join(parts)


def test_redaction_kv_and_urls():
    pw = _sample("hun", "ter2")
    tok = _sample("abc", "def")
    url_tok = _sample("tok", "123")
    os_cred = _sample("very", "secret")
    age_prefix = _sample("1ABC", "DEF")
    text = (f"password: {pw}\ntoken={tok}\n"
            f"https://user:{url_tok}@github.com/x.git\n"
            f"OS_APPLICATION_CREDENTIAL_SECRET={os_cred}\n"
            f"AGE-SECRET-KEY-{age_prefix}0123456789\n")
    out = redaction.redact_text(text)
    for secret in (pw, tok, url_tok, os_cred, age_prefix):
        assert secret not in out
    assert "<redacted>" in out


def test_redaction_private_key_block_and_ansi():
    begin = _sample("-----BEGIN RSA ", "PRIVATE KEY-----")
    end = _sample("-----END RSA ", "PRIVATE KEY-----")
    raw = f"\x1b[31m{begin}\nAAAA\n{end}\x1b[0m"
    line = redaction.redact_line(raw)
    assert "BEGIN RSA" not in line and "\x1b" not in line


def test_redact_mapping_drops_sensitive_keys():
    data = {"password": "x", "nested": [{"api_key": "y", "name": "ok"}]}
    out = redaction.redact_mapping(data)
    assert out["password"] == redaction.REDACTED
    assert out["nested"][0]["api_key"] == redaction.REDACTED
    assert out["nested"][0]["name"] == "ok"


# ------------------------------------------------------------- stage parsing
def test_parse_successful_deployment():
    r = parsers.parse_bootstrap_log(BOOTSTRAP_OK)
    assert r["started"] and r["finished"] and r["success"]
    stages = r["stages"]
    assert stages["validate"]["status"] == "passed"
    assert stages["tofu_init"]["status"] == "passed"
    assert stages["tofu_apply"]["status"] == "passed"
    assert stages["kubespray"]["status"] == "passed"
    assert stages["cloud_init"]["status"] == "passed"
    assert stages["kubeconfig"]["status"] == "passed"
    assert stages["flux_bootstrap"]["status"] == "passed"
    assert stages["tofu_init"]["duration"] == "1s"
    assert r["ansible"]["recap"]["demo-cp0"]["ok"] == 500


def test_parse_quota_failure_classification():
    r = parsers.parse_bootstrap_log(BOOTSTRAP_QUOTA_FAIL)
    assert r["failed_step"] == "opentofu-apply"
    assert r["stages"]["tofu_apply"]["status"] == "failed"
    assert any(e["category"] == "quota" for e in r["errors"])


def test_parse_invalid_image_classification():
    r = parsers.parse_bootstrap_log(BOOTSTRAP_IMAGE_FAIL)
    assert any(e["category"] == "image" for e in r["errors"])


def test_parse_flux_failure_classification():
    r = parsers.parse_bootstrap_log(BOOTSTRAP_FLUX_FAIL)
    assert r["stages"]["flux_bootstrap"]["status"] == "failed"
    assert any(e["category"] == "flux" for e in r["errors"])
    flux_err = [e for e in r["errors"] if e["category"] == "flux"][0]
    assert "--break-lock" not in flux_err.get("next_command", "")


def test_parse_cloudinit_timeout():
    r = parsers.parse_bootstrap_log(BOOTSTRAP_CLOUDINIT_TIMEOUT)
    assert r["cloud_init"]["status"] == "error"
    assert any(e["category"] == "cloud_init" for e in r["errors"])


def test_incremental_parse_matches_full_parse():
    full = parsers.parse_bootstrap_log(BOOTSTRAP_OK)
    state = parsers.new_parse_state()
    half = len(BOOTSTRAP_OK) // 2
    cut = BOOTSTRAP_OK.rfind("\n", 0, half) + 1
    parsers.parse_bootstrap_log(BOOTSTRAP_OK[:cut], state=state)
    incremental = parsers.parse_bootstrap_log(BOOTSTRAP_OK[cut:], state=state)
    assert {k: v["status"] for k, v in incremental["stages"].items()} == \
           {k: v["status"] for k, v in full["stages"].items()}


def test_tofu_event_parsing():
    r = parsers.parse_bootstrap_log(BOOTSTRAP_OK)
    assert "module.openstack-nova.openstack_compute_instance_v2.master[0]" in r["tofu"]["created"]
    assert r["tofu"]["creating"] == []


# ----------------------------------------------------- processes / duplicates
def test_duplicate_deploy_detection():
    rows = parsers.parse_deploy_processes(PS_OUTPUT, "my-org", "demo")
    assert len(rows) == 2  # grep line and other-cluster line excluded
    assert {r["pid"] for r in rows} == {1200, 1300}


# ----------------------------------------------------------- json normalizers
def test_parse_nodes_and_pods():
    nodes = parsers.parse_nodes({"items": [{
        "metadata": {"name": "cp0", "labels": {"node-role.kubernetes.io/control-plane": ""}},
        "status": {"conditions": [{"type": "Ready", "status": "True"}],
                   "addresses": [{"type": "InternalIP", "address": "10.0.0.1"}],
                   "capacity": {"cpu": "4", "memory": "8Gi"},
                   "nodeInfo": {"kubeletVersion": "v1.35.4", "osImage": "Ubuntu 22.04"}}}]})
    assert nodes[0]["role"] == "control-plane" and nodes[0]["ready"]

    pods = parsers.parse_pods({"items": [
        {"metadata": {"name": "a", "namespace": "x"}, "status": {"phase": "Running", "containerStatuses": [{"restartCount": 3}]}},
        {"metadata": {"name": "b", "namespace": "x"},
         "status": {"phase": "Pending", "containerStatuses": [
             {"restartCount": 0, "state": {"waiting": {"reason": "CrashLoopBackOff"}}}]}},
    ]})
    assert pods["total"] == 2 and pods["running"] == 1 and pods["crashloop"] == 1
    assert pods["restarts"] == 3


def test_parse_flux_and_quota():
    flux = parsers.parse_flux_objects({"items": [{
        "kind": "Kustomization",
        "metadata": {"name": "apps", "namespace": "flux-system"},
        "spec": {"suspend": False},
        "status": {"conditions": [{"type": "Ready", "status": "False", "message": "kaboom token=abc"}]},
    }]})
    assert flux[0]["ready"] is False and "abc" not in flux[0]["message"]

    quota = parsers.parse_quota([
        {"Resource": "cores", "Limit": 40, "In Use": 38},
        {"Resource": "instances", "Limit": 10, "In Use": 2},
    ])
    assert quota["cores"]["alert"] == "critical" and quota["instances"]["alert"] == ""


def test_parse_servers_filters_cluster():
    rows = parsers.parse_servers(
        [{"Name": "demo-cp0", "Status": "ACTIVE", "Networks": {"net": ["10.0.0.1"]}},
         {"Name": "other-vm", "Status": "ACTIVE"}], "demo")
    assert len(rows) == 1 and rows[0]["name"] == "demo-cp0"


def test_parse_git_status():
    out = parsers.parse_git_status(
        "# branch.head main\n# branch.upstream origin/main\n# branch.ab +2 -0\n1 .M N... 100644 x  applications/a.yaml\n")
    assert out["ahead"] == 2 and out["clean"] is False and out["dirty_files"] == ["applications/a.yaml"]


# --------------------------------------------------------------- log discovery
def test_latest_log_discovery_and_missing(sandbox):
    ctx = MonitoringContext.resolve("my-org", "demo")
    assert log_stream.latest_bootstrap_log(ctx) is None
    logdir = ctx.bootstrap_log_dir
    logdir.mkdir(parents=True)
    old = logdir / "bootstrap-20260101T000000Z.log"
    new = logdir / "bootstrap-20260715T000000Z.log"
    old.write_text("old")
    time.sleep(0.02)
    new.write_text("new")
    assert log_stream.latest_bootstrap_log(ctx) == new


# ------------------------------------------------------- allowlist & runner
def test_command_allowlist_enforced():
    with pytest.raises(MonitoringError):
        get_command("rm_rf")
    assert "k8s_nodes" in all_commands()


def test_runner_gates_kubeconfig_and_openstack(sandbox, monkeypatch):
    from monitoring.command_runner import run_command

    ctx = MonitoringContext.resolve("my-org", "demo")
    result = run_command(ctx, "k8s_nodes")
    assert result["unavailable"] and "kubeconfig" in result["error"]

    # non-openstack provider blocks openstack commands
    ctx2 = MonitoringContext.resolve("my-org", "demo")
    ctx2.provider = "kind"
    result = run_command(ctx2, "os_server_list")
    assert result["unavailable"]


def test_runner_timeout(sandbox, monkeypatch):
    from monitoring import command_registry
    from monitoring.command_runner import run_command

    spec = command_registry.CommandSpec(
        id="sleepy", build=lambda ctx: ["sleep", "5"], timeout=1, tier=2)
    monkeypatch.setitem(command_registry._REGISTRY, "sleepy", spec)
    ctx = MonitoringContext.resolve("my-org", "demo")
    result = run_command(ctx, "sleepy")
    assert not result["ok"] and "timed out" in result["error"]


def test_missing_binary_reported(sandbox, monkeypatch):
    from monitoring import command_registry
    from monitoring.command_runner import run_command

    spec = command_registry.CommandSpec(
        id="ghost", build=lambda ctx: ["definitely-not-a-binary-xyz"], timeout=3, tier=2)
    monkeypatch.setitem(command_registry._REGISTRY, "ghost", spec)
    ctx = MonitoringContext.resolve("my-org", "demo")
    result = run_command(ctx, "ghost")
    assert result.get("unavailable") or not result["ok"]


# --------------------------------------------------------------------- cache
def test_cache_ttl_and_single_flight():
    calls = []
    cache = cache_mod.TTLCache()

    def producer():
        calls.append(1)
        return len(calls)

    assert cache.get(("k",), 60, producer) == 1
    assert cache.get(("k",), 60, producer) == 1  # cached
    assert cache.get(("k",), 0, producer) == 2   # expired


# -------------------------------------------------------------- blueprint API
@pytest.fixture()
def client(sandbox):
    import flask
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from workflow_dashboard.routes.monitoring_api import create_monitoring_blueprint

    app = flask.Flask(__name__, template_folder=str(
        Path(__file__).resolve().parent.parent / "workflow_dashboard" / "templates"))
    app.register_blueprint(create_monitoring_blueprint("."))
    return app.test_client()


def test_api_clusters_lists_blueprints(client):
    data = client.get("/api/monitoring/clusters").get_json()
    assert data["ok"] and {"org": "my-org", "cluster": "demo"} in data["pairs"]


def test_api_rejects_traversal_and_bad_names(client):
    assert client.get("/api/monitoring/deployment/..%2F..%2Froot/demo/summary").status_code in (400, 404)
    assert client.get("/api/monitoring/deployment/My_Org/demo/summary").status_code == 400
    assert client.get("/api/monitoring/deployment/my-org/unknown/summary").status_code == 404


def test_api_deploy_summary_no_log(client):
    data = client.get("/api/monitoring/deployment/my-org/demo/summary").get_json()
    assert data["ok"] and data["snapshot"]["deployment_status"] in ("IDLE", "RUNNING")
    assert data["snapshot"]["latest_log"] == ""


def test_api_cluster_summary_without_kubeconfig(client):
    data = client.get("/api/monitoring/cluster/my-org/demo/summary").get_json()
    assert data["ok"] and data["snapshot"]["available"] is False
    assert "kubeconfig" in data["snapshot"]["reason"]


def test_metrics_endpoint(client, sandbox):
    logdir = Path(sandbox) / ".local/state/opencenter/logs/bootstrap/my-org/demo"
    logdir.mkdir(parents=True)
    (logdir / "bootstrap-20260715T000000Z.log").write_text(BOOTSTRAP_QUOTA_FAIL)
    cache_mod.CACHE._data.clear()
    import workflow_dashboard.monitoring.cache as wd_cache
    wd_cache.CACHE._data.clear()
    resp = client.get("/metrics")
    body = resp.get_data(as_text=True)
    assert resp.status_code == 200
    assert 'opencenter_deployment_info{cluster="demo"' in body
    assert 'opencenter_deployment_status{cluster="demo",org="my-org",status="FAILED"} 1' in body
    assert "s3cret" not in body


def test_healthz(client):
    assert client.get("/healthz").get_json()["ok"] is True


# ------------------------------------------------------- grafana provisioning
def test_grafana_dashboards_valid():
    root = Path(__file__).resolve().parent.parent / "infrastructure/monitoring/grafana"
    dashboards = list((root / "dashboards").glob("*.json"))
    assert len(dashboards) == 4
    for path in dashboards:
        doc = json.loads(path.read_text())
        assert doc["uid"] and doc["panels"] and doc["templating"]["list"]
        names = [v["name"] for v in doc["templating"]["list"]]
        for required in ("datasource", "cluster", "org", "namespace", "node"):
            assert required in names, "%s missing variable %s" % (path.name, required)


def test_provisioning_yaml_valid():
    import yaml
    root = Path(__file__).resolve().parent.parent / "infrastructure/monitoring"
    for path in root.rglob("*.yaml"):
        list(yaml.safe_load_all(path.read_text()))
