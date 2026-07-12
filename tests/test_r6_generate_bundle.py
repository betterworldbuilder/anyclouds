"""Regression fixtures + determinism checks for R6's /api/r6/generate-bundle.

Exercises the real running dashboard (matches how this endpoint has been verified
throughout the R6 Stage 10/11 rework) rather than importing app.py directly, since
r6_generate_bundle is a Flask view with module-level app state, not a pure function.

Run with the osflex-dashboard service already running (systemctl --user start
osflex-dashboard) and:

    pytest tests/test_r6_generate_bundle.py -v

Uses org="r6-dryrun-test" throughout so import_to_gitops never touches a real
GitOps directory - these are safe, isolated fixture runs.
"""
import re
import shutil
from pathlib import Path

import pytest
import requests
import yaml

BASE_URL = "http://127.0.0.1:5001"
ENDPOINT = BASE_URL + "/api/r6/generate-bundle"


def _generate(workloads, **overrides):
    payload = {
        "org": "r6-dryrun-test",
        "cluster": "r6-dryrun-cluster",
        "import_to_gitops": False,
        "registry": {"type": "harbor", "project": "flex-apps"},
        "source_vm": {"host": "10.0.0.10", "user": "root"},
        "bundle": {
            "id": "fixture-" + overrides.pop("id_suffix", "generic"),
            "businessSystemName": overrides.pop("name", "Fixture Test"),
            "workloads": workloads,
        },
    }
    payload["bundle"].update(overrides)
    try:
        resp = requests.post(ENDPOINT, json=payload, timeout=30)
    except requests.exceptions.ConnectionError:
        pytest.skip("osflex-dashboard is not running on %s - start it before running these fixtures" % BASE_URL)
    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert data.get("ok") is True, data.get("error")
    return data


def _cleanup(bundle_dir):
    p = Path(bundle_dir)
    if p.is_dir() and "/bundles/r6/" in str(p):
        shutil.rmtree(p, ignore_errors=True)


def _load_kind(bundle_dir, filename, kind):
    docs = list(yaml.safe_load_all((Path(bundle_dir) / "kustomize_bundle" / filename).read_text()))
    matches = [d for d in docs if d and d.get("kind") == kind]
    assert matches, "expected a %s document in %s, found kinds: %s" % (kind, filename, [d.get("kind") for d in docs if d])
    return matches[0]


def test_deployment_generated_for_containerized_component():
    data = _generate(
        [{"component": "api-server", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node server.js", "healthPath": "/health", "dependencies": []}],
        id_suffix="deployment",
    )
    dep = _load_kind(data["bundle_dir"], "api-server.yaml", "Deployment")
    assert dep["spec"]["template"]["spec"]["containers"][0]["image"].endswith(":" + data["generated_at"])
    assert dep["spec"]["template"]["spec"]["securityContext"]["runAsNonRoot"] is True
    _cleanup(data["bundle_dir"])


def test_cronjob_generated_for_scheduler_named_component():
    data = _generate(
        [{"component": "nightly-scheduler", "readiness": "READY", "image": "python:3.12-slim",
          "startCommand": "python cron.py", "healthPath": "/health", "dependencies": []}],
        id_suffix="cronjob",
    )
    cron = _load_kind(data["bundle_dir"], "nightly-scheduler.yaml", "CronJob")
    pod_spec = cron["spec"]["jobTemplate"]["spec"]["template"]["spec"]
    assert "containers" in pod_spec and "securityContext" in pod_spec and "restartPolicy" in pod_spec
    _cleanup(data["bundle_dir"])


def test_job_generated_for_batch_named_component():
    data = _generate(
        [{"component": "batch-worker", "readiness": "READY", "image": "python:3.12-slim",
          "startCommand": "python worker.py", "healthPath": "/health", "dependencies": []}],
        id_suffix="job",
    )
    job = _load_kind(data["bundle_dir"], "batch-worker.yaml", "Job")
    assert job["spec"]["backoffLimit"] == 3
    _cleanup(data["bundle_dir"])


def test_service_account_generated_per_component():
    data = _generate(
        [{"component": "api-server", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node server.js", "healthPath": "/health", "dependencies": []}],
        id_suffix="sa",
    )
    sa = _load_kind(data["bundle_dir"], "api-server.yaml", "ServiceAccount")
    assert sa["metadata"]["name"] == "api-server-sa"
    _cleanup(data["bundle_dir"])


def test_security_context_defaults_are_non_root_and_locked_down():
    data = _generate(
        [{"component": "api-server", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node server.js", "healthPath": "/health", "dependencies": []}],
        id_suffix="secctx",
    )
    dep = _load_kind(data["bundle_dir"], "api-server.yaml", "Deployment")
    container = dep["spec"]["template"]["spec"]["containers"][0]
    assert container["securityContext"]["allowPrivilegeEscalation"] is False
    assert container["securityContext"]["readOnlyRootFilesystem"] is True
    assert container["securityContext"]["capabilities"]["drop"] == ["ALL"]
    _cleanup(data["bundle_dir"])


def test_configmap_generated_from_dependencies():
    data = _generate(
        [{"component": "api-server", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node server.js", "healthPath": "/health", "dependencies": ["mysql-database"]}],
        id_suffix="configmap",
    )
    cm = _load_kind(data["bundle_dir"], "api-server.yaml", "ConfigMap")
    assert "MYSQL_DATABASE_HOST" in cm["data"]
    _cleanup(data["bundle_dir"])


def test_secret_contract_generated_for_credentialed_dependency():
    data = _generate(
        [{"component": "api-server", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node server.js", "healthPath": "/health", "dependencies": ["mysql-database"]}],
        id_suffix="secretcontract",
    )
    contract_path = Path(data["bundle_dir"]) / "secrets" / "secret-contracts.yaml"
    assert contract_path.is_file()
    doc = yaml.safe_load(contract_path.read_text())
    assert doc["kind"] == "SecretContract"
    assert "MYSQL_DATABASE_USERNAME" in doc["spec"]["requiredKeys"]
    _cleanup(data["bundle_dir"])


def test_vm_service_and_endpointslice_for_resolved_retained_vm():
    data = _generate(
        [{"component": "oracle-database", "readiness": "KEEP_ON_VM_FOR_NOW",
          "targetIp": "10.20.30.10", "targetPort": 1521}],
        id_suffix="vmresolved",
    )
    docs = list(yaml.safe_load_all(
        (Path(data["bundle_dir"]) / "kustomize_bundle" / "vm-oracle-database.yaml").read_text()))
    kinds = {d.get("kind") for d in docs if d}
    assert kinds == {"Service", "EndpointSlice"}
    svc = next(d for d in docs if d.get("kind") == "Service")
    assert "selector" not in svc["spec"]
    eps = next(d for d in docs if d.get("kind") == "EndpointSlice")
    assert eps["endpoints"][0]["addresses"] == ["10.20.30.10"]
    _cleanup(data["bundle_dir"])


def test_vm_binding_for_unresolved_vm_never_fakes_an_ip():
    data = _generate(
        [{"component": "oracle-database", "readiness": "KEEP_ON_VM_FOR_NOW",
          "targetIp": "", "targetPort": 1521}],
        id_suffix="vmunresolved",
    )
    docs = list(yaml.safe_load_all(
        (Path(data["bundle_dir"]) / "kustomize_bundle" / "vm-oracle-database.yaml").read_text()))
    kinds = [d.get("kind") for d in docs if d]
    assert kinds == ["Service"], "must not emit a fabricated EndpointSlice IP: %s" % kinds
    binding_path = Path(data["bundle_dir"]) / "virtual-machines" / "service-bindings.yaml"
    assert binding_path.is_file()
    binding = yaml.safe_load(binding_path.read_text())
    assert binding["kind"] == "VMServiceBinding"
    assert binding["spec"]["resolutionPolicy"] == "AFTER_VM_PROVISION"
    _cleanup(data["bundle_dir"])


def test_staging_and_production_overlays_are_generated_and_distinct():
    data = _generate(
        [{"component": "api-server", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node server.js", "healthPath": "/health", "dependencies": []}],
        id_suffix="overlays",
    )
    staging = yaml.safe_load((Path(data["bundle_dir"]) / "overlays" / "staging" / "kustomization.yaml").read_text())
    prod = yaml.safe_load((Path(data["bundle_dir"]) / "overlays" / "production" / "kustomization.yaml").read_text())
    assert staging["namespace"] != prod["namespace"]
    assert staging["namespace"].endswith("-staging")
    _cleanup(data["bundle_dir"])


def test_statefulset_with_headless_service_for_explicit_workload_kind():
    data = _generate(
        [{"component": "session-store", "readiness": "READY", "image": "custom/session-store:1.0",
          "startCommand": "/app/run.sh", "healthPath": "/health", "dependencies": [],
          "workloadKind": "StatefulSet", "replicas": 3}],
        id_suffix="statefulset",
    )
    docs = list(yaml.safe_load_all((Path(data["bundle_dir"]) / "kustomize_bundle" / "session-store.yaml").read_text()))
    sts = next(d for d in docs if d.get("kind") == "StatefulSet")
    assert sts["spec"]["serviceName"] == "session-store"
    assert sts["spec"]["replicas"] == 3
    svc = next(d for d in docs if d.get("kind") == "Service")
    # Kubernetes' headless-Service sentinel is the literal string "None" (ClusterIP is a
    # Go string field) - not YAML null, which would mean "unset" and get auto-assigned.
    assert svc["spec"]["clusterIP"] == "None"
    assert svc["spec"]["selector"] == {"app": "session-store"}
    _cleanup(data["bundle_dir"])


def test_daemonset_for_explicit_workload_kind_has_no_service():
    data = _generate(
        [{"component": "node-agent", "readiness": "READY", "image": "custom/node-agent:1.0",
          "startCommand": "/app/agent", "healthPath": "/health", "dependencies": [],
          "workloadKind": "DaemonSet"}],
        id_suffix="daemonset",
    )
    docs = list(yaml.safe_load_all((Path(data["bundle_dir"]) / "kustomize_bundle" / "node-agent.yaml").read_text()))
    kinds = [d.get("kind") for d in docs if d]
    assert "DaemonSet" in kinds
    assert "Service" not in kinds
    ds = next(d for d in docs if d.get("kind") == "DaemonSet")
    assert ds["spec"]["template"]["spec"]["containers"][0]["name"] == "node-agent"
    _cleanup(data["bundle_dir"])


def test_role_and_rolebinding_scoped_to_component_own_resources():
    data = _generate(
        [{"component": "api-server", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node server.js", "healthPath": "/health", "dependencies": ["mysql-database"]}],
        id_suffix="rbac",
    )
    docs = list(yaml.safe_load_all((Path(data["bundle_dir"]) / "kustomize_bundle" / "api-server.yaml").read_text()))
    role = next(d for d in docs if d.get("kind") == "Role")
    binding = next(d for d in docs if d.get("kind") == "RoleBinding")
    assert role["metadata"]["name"] == "api-server-role"
    resource_names = {rn for rule in role["rules"] for rn in rule.get("resourceNames", [])}
    assert "api-server-deps" in resource_names
    assert "api-server-secrets" in resource_names
    assert all(rule["verbs"] == ["get", "list", "watch"] for rule in role["rules"])
    assert binding["subjects"] == [{"kind": "ServiceAccount", "name": "api-server-sa", "namespace": binding["metadata"]["namespace"]}]
    assert binding["roleRef"]["name"] == "api-server-role"
    _cleanup(data["bundle_dir"])


def test_no_rbac_generated_when_component_has_no_dependencies():
    data = _generate(
        [{"component": "standalone-worker", "readiness": "READY", "image": "python:3.12-slim",
          "startCommand": "python worker.py", "healthPath": "/health", "dependencies": []}],
        id_suffix="norbac",
    )
    docs = list(yaml.safe_load_all((Path(data["bundle_dir"]) / "kustomize_bundle" / "standalone-worker.yaml").read_text()))
    kinds = [d.get("kind") for d in docs if d]
    assert "Role" not in kinds and "RoleBinding" not in kinds
    _cleanup(data["bundle_dir"])


def test_legacy_pre_increment_payload_shape_still_generates_safely():
    """Older saved R6 projects (generated by the pre-Stage-10 "Ship to OpenCenter"
    panel, r6BuildOpenCenterBundle() in _panel_s2_opencenter.html) send workloads
    with only the original field set - component/layer/kubernetesKind/image/
    replicas/service/ingressGateway/configMap/secret/pvc/readiness/actionRequired.
    They never send startCommand, healthPath, dependencies, targetIp or targetPort,
    which increments 1-4 added. This must not crash, and must not silently run a
    no-op container - the generator is expected to fail loudly on missing start
    command by design (Stage 9 entrypoint fix), not paper over it."""
    legacy_workloads = [{
        "component": "legacy-api", "layer": "API", "kubernetesKind": "Deployment",
        "image": "node:18-slim", "replicas": 2, "service": True, "ingressGateway": True,
        "configMap": True, "secret": "Placeholder", "pvc": False,
        "readiness": "READY", "actionRequired": "none", "manifestName": "legacy-api",
    }, {
        "component": "legacy-oracle-db", "layer": "Database", "kubernetesKind": "External DB / StatefulSet option",
        "image": "", "replicas": 1, "service": False, "ingressGateway": False,
        "configMap": True, "secret": "Placeholder", "pvc": True,
        "readiness": "KEEP_ON_VM_FOR_NOW", "actionRequired": "connect to existing VM", "manifestName": "legacy-oracle-db",
    }]
    data = _generate(legacy_workloads, id_suffix="legacypayload")

    dep = _load_kind(data["bundle_dir"], "legacy-api.yaml", "Deployment")
    assert dep["spec"]["template"]["spec"]["securityContext"]["runAsNonRoot"] is True

    dockerfile = (Path(data["bundle_dir"]) / "dockerfiles" / "legacy-api" / "Dockerfile").read_text()
    assert "No start command detected for legacy-api" in dockerfile, (
        "legacy payloads with no startCommand must fail loudly at container "
        "startup, not silently run the base image's default process"
    )

    vm_docs = list(yaml.safe_load_all(
        (Path(data["bundle_dir"]) / "kustomize_bundle" / "vm-legacy-oracle-db.yaml").read_text()))
    kinds = [d.get("kind") for d in vm_docs if d]
    assert kinds == ["Service"], "missing targetIp on a legacy VM-retained component must never fabricate an EndpointSlice IP"

    _cleanup(data["bundle_dir"])


def test_generation_is_structurally_deterministic():
    """Two generations of the same input must produce identical resource structure -
    ignoring the timestamp-derived tag/digest fields, which are expected to differ."""
    workloads = [{"component": "api-server", "readiness": "READY", "image": "node:20-slim",
                  "startCommand": "node server.js", "healthPath": "/health", "dependencies": ["mysql-database"]}]
    data1 = _generate(workloads, id_suffix="det1")
    data2 = _generate(workloads, id_suffix="det2")

    def _normalize(bundle_dir):
        doc = _load_kind(bundle_dir, "api-server.yaml", "Deployment")
        container = doc["spec"]["template"]["spec"]["containers"][0]
        container["image"] = re.sub(r":[0-9_]+$", ":TAG", container["image"])
        return doc

    n1, n2 = _normalize(data1["bundle_dir"]), _normalize(data2["bundle_dir"])
    assert n1 == n2, "generation is not deterministic - same input produced different structure"
    _cleanup(data1["bundle_dir"])
    _cleanup(data2["bundle_dir"])
