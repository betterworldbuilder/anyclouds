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
import os
import re
import shutil
from pathlib import Path

import pytest
import requests
import yaml

BASE_URL = "http://127.0.0.1:5001"
ENDPOINT = BASE_URL + "/api/r6/generate-bundle"
GITOPS_ROOT = Path(os.path.expanduser("~")) / ".config" / "opencenter" / "clusters" / "gitops"


_TOP_LEVEL_KEYS = ("org", "cluster", "import_to_gitops", "auto_commit")


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
    for key in _TOP_LEVEL_KEYS:
        if key in overrides:
            payload[key] = overrides.pop(key)
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


def _make_fake_gitops(org, cluster, wire_managed_services_fluxcd, stub_operators=()):
    """Builds a minimal but real GitOps directory tree so the Flux reachability-graph walk
    and dependsOn resolution can be exercised against real files on disk, without touching
    the actual production GitOps repo. Returns the cluster overlay root Path."""
    root = GITOPS_ROOT / org / "applications" / "overlays" / cluster
    (root / "managed-services").mkdir(parents=True, exist_ok=True)
    root_resources = ["./managed-services/fluxcd"] if wire_managed_services_fluxcd else ["./flux-system"]
    (root / "kustomization.yaml").write_text(
        "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n"
        + "".join("  - %s\n" % r for r in root_resources), encoding="utf-8")
    if not wire_managed_services_fluxcd:
        (root / "flux-system").mkdir(parents=True, exist_ok=True)
        (root / "flux-system" / "kustomization.yaml").write_text(
            "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources: []\n", encoding="utf-8")
    services_fluxcd = root / "services" / "fluxcd"
    services_fluxcd.mkdir(parents=True, exist_ok=True)
    for op in stub_operators:
        (services_fluxcd / ("%s.yaml" % op)).write_text("# stub for test\n", encoding="utf-8")
    return root


def _cleanup_fake_gitops(org):
    shutil.rmtree(GITOPS_ROOT / org, ignore_errors=True)


def test_flux_kustomization_generated_and_reachable_with_resolved_dependson():
    org, cluster = "r6-dryrun-flux-org", "r6-dryrun-flux-cluster"
    _make_fake_gitops(org, cluster, wire_managed_services_fluxcd=True, stub_operators=["postgres-operator"])
    try:
        data = _generate(
            [{"component": "api-server", "readiness": "READY", "image": "node:20-slim",
              "startCommand": "node server.js", "healthPath": "/health", "dependencies": [],
              "targetForm": "CONTAINERIZED"},
             {"component": "postgres-primary", "readiness": "KEEP_ON_VM_FOR_NOW",
              "targetForm": "OPERATOR_MANAGED", "targetIp": "", "targetPort": 5432}],
            id_suffix="fluxreach", name="Flux Reach", org=org, cluster=cluster,
            import_to_gitops=True, auto_commit=False,
        )
        assert "reachable" in data["flux_status"]
        assert "postgres-operator-base" in data["flux_status"]

        fluxcd_dir = GITOPS_ROOT / org / "applications" / "overlays" / cluster / "managed-services" / "fluxcd"
        flux_doc = yaml.safe_load((fluxcd_dir / "flux-reach.yaml").read_text())
        assert flux_doc["kind"] == "Kustomization"
        assert flux_doc["apiVersion"] == "kustomize.toolkit.fluxcd.io/v1"
        assert flux_doc["spec"]["dependsOn"] == [{"name": "postgres-operator-base", "namespace": "flux-system"}]
        assert flux_doc["spec"]["path"] == (
            "./applications/overlays/%s/managed-services/flux-reach/overlays/production" % cluster)

        agg = (fluxcd_dir / "kustomization.yaml").read_text()
        assert "./flux-reach.yaml" in agg

        overlay_root = GITOPS_ROOT / org / "applications" / "overlays" / cluster / "managed-services" / "flux-reach"
        assert (overlay_root / "kustomize_bundle" / "kustomization.yaml").is_file()
        assert (overlay_root / "overlays" / "staging" / "kustomization.yaml").is_file()
        assert (overlay_root / "overlays" / "production" / "kustomization.yaml").is_file()

        assert not any("not reachable" in w for w in data["bundle_validation"]["warnings"])
        _cleanup(data["bundle_dir"])
    finally:
        _cleanup_fake_gitops(org)


def test_flux_dependson_skipped_with_warning_when_operator_kustomization_missing():
    org, cluster = "r6-dryrun-flux-missing-op-org", "r6-dryrun-flux-cluster"
    _make_fake_gitops(org, cluster, wire_managed_services_fluxcd=True, stub_operators=[])
    try:
        data = _generate(
            [{"component": "redis-cache", "readiness": "KEEP_ON_VM_FOR_NOW",
              "targetForm": "OPERATOR_MANAGED", "targetIp": "", "targetPort": 6379}],
            id_suffix="fluxmissingop", name="Flux Missing Op", org=org, cluster=cluster,
            import_to_gitops=True, auto_commit=False,
        )
        fluxcd_dir = GITOPS_ROOT / org / "applications" / "overlays" / cluster / "managed-services" / "fluxcd"
        flux_doc = yaml.safe_load((fluxcd_dir / "flux-missing-op.yaml").read_text())
        assert "dependsOn" not in flux_doc["spec"]
        assert any("redis-operator" in w and "no FluxCD Kustomization was found" in w
                   for w in data["bundle_validation"]["warnings"])
        _cleanup(data["bundle_dir"])
    finally:
        _cleanup_fake_gitops(org)


def test_flux_unreachable_graph_surfaces_honest_warning():
    org, cluster = "r6-dryrun-flux-unreachable-org", "r6-dryrun-flux-cluster"
    _make_fake_gitops(org, cluster, wire_managed_services_fluxcd=False)
    try:
        data = _generate(
            [{"component": "api-server", "readiness": "READY", "image": "node:20-slim",
              "startCommand": "node server.js", "healthPath": "/health", "dependencies": []}],
            id_suffix="fluxunreachable", org=org, cluster=cluster, import_to_gitops=True, auto_commit=False,
        )
        assert "not reachable" in data["flux_status"]
        assert any("not referenced anywhere" in w for w in data["bundle_validation"]["warnings"])
        _cleanup(data["bundle_dir"])
    finally:
        _cleanup_fake_gitops(org)


def test_stage12_gate_blocks_import_commit_and_push_on_blocker():
    """Stage 12: a bundle with a real blocker (no startCommand) must never touch the real
    GitOps repo - no working-tree copy, no commit, no push - even with import_to_gitops and
    auto_commit both on. This is the core deployment-safety gate."""
    org, cluster = "r6-dryrun-gate-org", "r6-dryrun-flux-cluster"
    _make_fake_gitops(org, cluster, wire_managed_services_fluxcd=True)
    try:
        data = _generate(
            [{"component": "api-server", "readiness": "READY", "image": "node:20-slim",
              "healthPath": "/health", "dependencies": []}],  # no startCommand - a real blocker
            id_suffix="gateblock", name="Gate Block", org=org, cluster=cluster,
            import_to_gitops=True, auto_commit=True,
        )
        assert data["bundle_validation"]["status"] == "BLOCKED"
        assert any("startCommand" in b and "Remediation:" in b for b in data["bundle_validation"]["blockers"])
        assert data["imported_to"] is None
        assert "BLOCKED" in data["gitops_commit"]
        assert "BLOCKED" in data["flux_status"]

        overlay_root = GITOPS_ROOT / org / "applications" / "overlays" / cluster / "managed-services" / "gate-block"
        assert not overlay_root.exists(), "a blocked bundle must never write into the real GitOps working tree"
        fluxcd_dir = GITOPS_ROOT / org / "applications" / "overlays" / cluster / "managed-services" / "fluxcd" / "gate-block.yaml"
        assert not fluxcd_dir.exists(), "a blocked bundle must never write its Flux Kustomization into the real repo"
        _cleanup(data["bundle_dir"])
    finally:
        _cleanup_fake_gitops(org)


def test_stage12_gate_allows_import_when_only_warnings_present():
    """Warnings must never block - only real blockers do."""
    org, cluster = "r6-dryrun-gate-warn-org", "r6-dryrun-flux-cluster"
    _make_fake_gitops(org, cluster, wire_managed_services_fluxcd=True)
    try:
        data = _generate(
            [{"component": "api-server", "readiness": "READY", "image": "node:20-slim",
              "startCommand": "node server.js", "healthPath": "/health",
              "dependencies": ["nonexistent-component"]}],  # dependency mismatch -> warning only
            id_suffix="gatewarn", name="Gate Warn", org=org, cluster=cluster,
            import_to_gitops=True, auto_commit=False,
        )
        assert data["bundle_validation"]["status"] == "PASSED_WITH_WARNINGS"
        assert data["imported_to"] is not None
        assert "reachable" in data["flux_status"]
        _cleanup(data["bundle_dir"])
    finally:
        _cleanup_fake_gitops(org)


def test_network_policies_default_deny_dns_and_dependency_ingress():
    data = _generate(
        [{"component": "api-server", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node server.js", "healthPath": "/health", "dependencies": ["worker-service"]},
         {"component": "worker-service", "readiness": "READY", "image": "python:3.12-slim",
          "startCommand": "python worker.py", "healthPath": "/health", "dependencies": []}],
        id_suffix="netpol",
    )
    docs = list(yaml.safe_load_all((Path(data["bundle_dir"]) / "kustomize_bundle" / "network-policies.yaml").read_text()))
    names = {d["metadata"]["name"] for d in docs if d}
    assert "default-deny-all" in names
    deny = next(d for d in docs if d["metadata"]["name"] == "default-deny-all")
    assert deny["spec"]["podSelector"] == {} and set(deny["spec"]["policyTypes"]) == {"Ingress", "Egress"}
    assert "allow-dns-egress" in names
    dep_policy = next(d for d in docs if d["metadata"]["name"] == "worker-service-allow-dependents")
    assert dep_policy["spec"]["podSelector"] == {"matchLabels": {"app": "worker-service"}}
    consumers = dep_policy["spec"]["ingress"][0]["from"]
    assert {"podSelector": {"matchLabels": {"app": "api-server"}}} in consumers
    _cleanup(data["bundle_dir"])


def test_egress_netpol_and_openstack_intent_for_resolved_vm_dependency():
    data = _generate(
        [{"component": "api-server", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node server.js", "healthPath": "/health", "dependencies": ["oracle-database"]},
         {"component": "oracle-database", "readiness": "KEEP_ON_VM_FOR_NOW",
          "targetIp": "10.20.30.10", "targetPort": 1521}],
        id_suffix="netpolvm",
    )
    docs = list(yaml.safe_load_all((Path(data["bundle_dir"]) / "kustomize_bundle" / "network-policies.yaml").read_text()))
    egress = next(d for d in docs if d["metadata"]["name"] == "api-server-allow-egress-to-oracle-database")
    assert egress["spec"]["egress"][0]["to"] == [{"ipBlock": {"cidr": "10.20.30.10/32"}}]
    assert egress["spec"]["egress"][0]["ports"] == [{"protocol": "TCP", "port": 1521}]

    intent_path = Path(data["bundle_dir"]) / "virtual-machines" / "openstack-security-group-intent.yaml"
    assert intent_path.is_file()
    intent = yaml.safe_load(intent_path.read_text())
    assert intent["kind"] == "OpenStackSecurityGroupIntent"
    rule = intent["spec"]["rules"][0]
    assert rule["toAddress"] == "10.20.30.10/32" and rule["port"] == 1521
    _cleanup(data["bundle_dir"])


def test_no_egress_netpol_for_unresolved_vm_dependency():
    data = _generate(
        [{"component": "api-server", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node server.js", "healthPath": "/health", "dependencies": ["oracle-database"]},
         {"component": "oracle-database", "readiness": "KEEP_ON_VM_FOR_NOW", "targetIp": "", "targetPort": 1521}],
        id_suffix="netpolunresolved",
    )
    docs = list(yaml.safe_load_all((Path(data["bundle_dir"]) / "kustomize_bundle" / "network-policies.yaml").read_text()))
    names = {d["metadata"]["name"] for d in docs if d}
    assert "api-server-allow-egress-to-oracle-database" not in names, "must never allow egress to an unresolved (fabricated) VM address"
    assert not (Path(data["bundle_dir"]) / "virtual-machines" / "openstack-security-group-intent.yaml").exists()
    _cleanup(data["bundle_dir"])


def test_deployment_gets_standalone_pvc_and_volume_mount():
    data = _generate(
        [{"component": "uploads-service", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node server.js", "healthPath": "/health", "dependencies": [],
          "persistentPath": "/srv/uploads"}],
        id_suffix="pvcdeploy",
    )
    docs = list(yaml.safe_load_all((Path(data["bundle_dir"]) / "kustomize_bundle" / "uploads-service.yaml").read_text()))
    pvc = next(d for d in docs if d.get("kind") == "PersistentVolumeClaim")
    assert pvc["metadata"]["name"] == "uploads-service-data"
    assert pvc["spec"]["accessModes"] == ["ReadWriteOnce"]
    assert pvc["spec"]["resources"]["requests"]["storage"] == "10Gi"
    dep = next(d for d in docs if d.get("kind") == "Deployment")
    pod_spec = dep["spec"]["template"]["spec"]
    assert pod_spec["volumes"] == [{"name": "data", "persistentVolumeClaim": {"claimName": "uploads-service-data"}}]
    assert pod_spec["containers"][0]["volumeMounts"] == [{"name": "data", "mountPath": "/srv/uploads"}]
    assert any("cluster default StorageClass" in w for w in data["bundle_validation"]["warnings"])
    _cleanup(data["bundle_dir"])


def test_statefulset_gets_volume_claim_template_not_standalone_pvc():
    data = _generate(
        [{"component": "session-store", "readiness": "READY", "image": "custom/session-store:1.0",
          "startCommand": "/app/run.sh", "healthPath": "/health", "dependencies": [],
          "workloadKind": "StatefulSet", "persistentPath": "/var/lib/sessions"}],
        id_suffix="pvcsts",
    )
    docs = list(yaml.safe_load_all((Path(data["bundle_dir"]) / "kustomize_bundle" / "session-store.yaml").read_text()))
    kinds = [d.get("kind") for d in docs if d]
    assert "PersistentVolumeClaim" not in kinds, "StatefulSet must use volumeClaimTemplates, not a standalone PVC"
    sts = next(d for d in docs if d.get("kind") == "StatefulSet")
    vct = sts["spec"]["volumeClaimTemplates"]
    assert vct == [{"metadata": {"name": "data"}, "spec": {"accessModes": ["ReadWriteOnce"], "resources": {"requests": {"storage": "10Gi"}}}}]
    mount = sts["spec"]["template"]["spec"]["containers"][0]["volumeMounts"]
    assert mount == [{"name": "data", "mountPath": "/var/lib/sessions"}]
    _cleanup(data["bundle_dir"])


def test_no_pvc_generated_for_stateless_or_missing_persistent_path():
    data = _generate(
        [{"component": "stateless-api", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node server.js", "healthPath": "/health", "dependencies": [],
          "persistentPath": "None - stateless"},
         {"component": "unknown-api", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node server.js", "healthPath": "/health", "dependencies": []}],
        id_suffix="nopvc",
    )
    for comp in ("stateless-api", "unknown-api"):
        docs = list(yaml.safe_load_all((Path(data["bundle_dir"]) / "kustomize_bundle" / ("%s.yaml" % comp)).read_text()))
        kinds = [d.get("kind") for d in docs if d]
        assert "PersistentVolumeClaim" not in kinds
        dep = next(d for d in docs if d.get("kind") == "Deployment")
        assert "volumes" not in dep["spec"]["template"]["spec"]
    assert any("unknown-api" in w and "persistentPath" in w for w in data["bundle_validation"]["warnings"])
    assert not any("stateless-api" in w and "persistentPath" in w for w in data["bundle_validation"]["warnings"])
    _cleanup(data["bundle_dir"])


def test_flux_preview_generated_without_any_gitops_repo():
    """The Step 10 UI button calls generate-bundle with import_to_gitops off for a safe
    preview. It must still get back a real Flux Kustomization manifest (not an empty
    result) - with dependsOn best-effort and explicitly flagged as unverified, since there
    is no real GitOps repo on disk to check operator Kustomizations against."""
    data = _generate(
        [{"component": "redis-cache", "readiness": "KEEP_ON_VM_FOR_NOW",
          "targetForm": "OPERATOR_MANAGED", "targetIp": "", "targetPort": 6379}],
        id_suffix="fluxpreview",
    )
    assert "preview only" in data["flux_status"]
    flux_doc = yaml.safe_load(data["flux_yaml"])
    assert flux_doc["kind"] == "Kustomization"
    assert flux_doc["spec"]["dependsOn"] == [{"name": "redis-operator-base", "namespace": "flux-system"}]
    assert any("not verified against a real GitOps repo" in w for w in data["bundle_validation"]["warnings"])
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
