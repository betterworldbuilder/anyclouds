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


def test_missing_operator_kustomization_for_operator_managed_component_is_blocker():
    """Stage 10.10: An OPERATOR_MANAGED component whose required operator Kustomization
    is absent from the GitOps repo must produce a BLOCKER (not a warning). The bundle
    must not be imported or written to the GitOps repo — a blocked bundle leaves the
    cluster in a consistent state rather than applying CRs against missing CRDs."""
    org, cluster = "r6-dryrun-flux-missing-op-org", "r6-dryrun-flux-cluster"
    _make_fake_gitops(org, cluster, wire_managed_services_fluxcd=True, stub_operators=[])
    try:
        data = _generate(
            [{"component": "redis-cache", "readiness": "KEEP_ON_VM_FOR_NOW",
              "targetForm": "OPERATOR_MANAGED", "targetIp": "", "targetPort": 6379}],
            id_suffix="fluxmissingop", name="Flux Missing Op", org=org, cluster=cluster,
            import_to_gitops=True, auto_commit=False,
        )
        assert data["bundle_validation"]["status"] == "BLOCKED", \
            "missing OPERATOR_MANAGED operator must BLOCK the bundle, not just warn"
        assert any("redis-operator" in b and "OPERATOR_MANAGED" in b
                   for b in data["bundle_validation"]["blockers"]), \
            "blocker must name both the operator and the OPERATOR_MANAGED component"
        # Blocked bundle must not write Flux Kustomization or manifests to the GitOps repo
        fluxcd_dir = GITOPS_ROOT / org / "applications" / "overlays" / cluster / "managed-services" / "fluxcd"
        assert not (fluxcd_dir / "flux-missing-op.yaml").exists(), \
            "a blocked bundle must never write its Flux Kustomization to the GitOps repo"
        assert data["imported_to"] is None, \
            "a blocked bundle must not import manifests to the GitOps working tree"
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


def test_gateway_certificate_httproute_for_exposed_component():
    data = _generate(
        [{"component": "web-frontend", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node server.js", "healthPath": "/health", "dependencies": [],
          "ingressGateway": True}],
        id_suffix="gw", name="Gw App", externalHostname="app.realdomain.example",
    )
    docs = list(yaml.safe_load_all((Path(data["bundle_dir"]) / "kustomize_bundle" / "gateway.yaml").read_text()))
    gw = next(d for d in docs if d["kind"] == "Gateway")
    assert gw["spec"]["gatewayClassName"] == "envoy"
    https_listener = next(l for l in gw["spec"]["listeners"] if l["name"] == "https")
    assert https_listener["hostname"] == "app.realdomain.example"
    assert https_listener["tls"]["certificateRefs"] == [{"name": "gw-app-tls"}]
    cert = next(d for d in docs if d["kind"] == "Certificate")
    assert cert["spec"]["issuerRef"] == {"name": "letsencrypt-prod", "kind": "ClusterIssuer"}
    assert cert["spec"]["dnsNames"] == ["app.realdomain.example"]
    route = next(d for d in docs if d["kind"] == "HTTPRoute")
    assert route["spec"]["rules"][0]["backendRefs"] == [{"name": "web-frontend", "port": 80}]
    dns_intent = yaml.safe_load((Path(data["bundle_dir"]) / "virtual-machines" / "dns-lb-intent.yaml").read_text())
    assert dns_intent["spec"]["hostname"] == "app.realdomain.example"
    assert not any("externalHostname" in w for w in data["bundle_validation"]["warnings"])
    _cleanup(data["bundle_dir"])


def test_gateway_placeholder_hostname_warns_when_not_provided():
    data = _generate(
        [{"component": "web-frontend", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node server.js", "healthPath": "/health", "dependencies": [],
          "ingressGateway": True}],
        id_suffix="gwnohost", name="Gw No Host",
    )
    docs = list(yaml.safe_load_all((Path(data["bundle_dir"]) / "kustomize_bundle" / "gateway.yaml").read_text()))
    gw = next(d for d in docs if d["kind"] == "Gateway")
    https_listener = next(l for l in gw["spec"]["listeners"] if l["name"] == "https")
    assert https_listener["hostname"] == "gw-no-host.example.com"
    assert any("externalHostname" in w and "Remediation:" in w for w in data["bundle_validation"]["warnings"])
    _cleanup(data["bundle_dir"])


def test_no_gateway_generated_without_any_exposed_component():
    data = _generate(
        [{"component": "backend-worker", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node worker.js", "healthPath": "/health", "dependencies": []}],
        id_suffix="nogw",
    )
    assert not (Path(data["bundle_dir"]) / "kustomize_bundle" / "gateway.yaml").exists()
    assert not (Path(data["bundle_dir"]) / "virtual-machines" / "dns-lb-intent.yaml").exists()
    _cleanup(data["bundle_dir"])


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


# ---------------------------------------------------------------------------
# Increment 12 — close PARTIAL gaps: PSS, storageClass, cert renewBefore, drift
# ---------------------------------------------------------------------------

def test_pss_namespace_labels_enforce_restricted():
    """Stage 10.3: Namespace must carry all three Pod Security Standards labels at
    'restricted' level so the cluster admission controller enforces (not merely audits)
    the restricted policy on every pod in this namespace."""
    data = _generate(
        [{"component": "api-server", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node server.js", "healthPath": "/health", "dependencies": []}],
        id_suffix="pss",
    )
    ns = yaml.safe_load((Path(data["bundle_dir"]) / "kustomize_bundle" / "namespace.yaml").read_text())
    labels = ns["metadata"]["labels"]
    assert labels.get("pod-security.kubernetes.io/enforce") == "restricted", \
        "namespace must enforce restricted PSS - pods violating it are rejected at admission"
    assert labels.get("pod-security.kubernetes.io/audit") == "restricted", \
        "namespace must audit restricted PSS to surface violations in the audit log"
    assert labels.get("pod-security.kubernetes.io/warn") == "restricted", \
        "namespace must warn restricted PSS so kubectl shows inline warnings"
    _cleanup(data["bundle_dir"])


def test_storageclass_propagated_to_pvc_and_blueprint():
    """Stage 10.6: When a component declares an explicit storageClass it must appear in
    the PVC spec and in the blueprint's platformRequirements.storageClasses list.
    No 'cluster default StorageClass' warning should fire for this component."""
    data = _generate(
        [{"component": "db-service", "readiness": "READY", "image": "postgres:16-alpine",
          "startCommand": "postgres", "healthPath": "/health", "dependencies": [],
          "persistentPath": "/var/lib/postgresql", "storageClass": "fast-ssd"}],
        id_suffix="storageclass",
    )
    docs = list(yaml.safe_load_all(
        (Path(data["bundle_dir"]) / "kustomize_bundle" / "db-service.yaml").read_text()))
    pvc = next(d for d in docs if d.get("kind") == "PersistentVolumeClaim")
    assert pvc["spec"].get("storageClassName") == "fast-ssd", \
        "explicit storageClass must be written into PVC spec"
    blueprint = yaml.safe_load((Path(data["bundle_dir"]) / "business-system.yaml").read_text())
    assert "fast-ssd" in blueprint["spec"]["platformRequirements"]["storageClasses"], \
        "storageClass must be registered in blueprint platformRequirements"
    # Explicit storageClass - no 'cluster default' warning for this component
    assert not any("cluster default StorageClass" in w and "db-service" in w
                   for w in data["bundle_validation"]["warnings"])
    _cleanup(data["bundle_dir"])


def test_storageclass_default_warning_fires_when_storageclass_omitted():
    """Stage 10.6: A component with persistentPath but no explicit storageClass must
    trigger a bundle_validation warning about defaulting to the cluster StorageClass."""
    data = _generate(
        [{"component": "uploads-service", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node server.js", "healthPath": "/health", "dependencies": [],
          "persistentPath": "/srv/uploads"}],  # no storageClass field
        id_suffix="scdefault",
    )
    docs = list(yaml.safe_load_all(
        (Path(data["bundle_dir"]) / "kustomize_bundle" / "uploads-service.yaml").read_text()))
    pvc = next(d for d in docs if d.get("kind") == "PersistentVolumeClaim")
    assert "storageClassName" not in pvc["spec"], \
        "no storageClass specified - PVC must omit storageClassName and use cluster default"
    assert any("cluster default StorageClass" in w for w in data["bundle_validation"]["warnings"]), \
        "must warn that cluster default StorageClass is being assumed"
    _cleanup(data["bundle_dir"])


def test_certificate_has_renew_before():
    """Stage 10.8 / Stage 14: TLS Certificate must declare renewBefore so cert-manager
    begins renewal 30 days before expiry rather than at the last possible moment."""
    data = _generate(
        [{"component": "web-frontend", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node server.js", "healthPath": "/health", "dependencies": [],
          "ingressGateway": True}],
        id_suffix="certrenewal", name="Cert Renewal App",
        externalHostname="app.example.com",
    )
    docs = list(yaml.safe_load_all(
        (Path(data["bundle_dir"]) / "kustomize_bundle" / "gateway.yaml").read_text()))
    cert = next(d for d in docs if d.get("kind") == "Certificate")
    assert cert["spec"].get("renewBefore") == "720h", \
        "Certificate must declare renewBefore:720h for automatic 30-day pre-expiry renewal"
    _cleanup(data["bundle_dir"])


def test_flux_kustomization_has_prune_true_and_drift_warning():
    """Stage 10.14 / Stage 14: Flux Kustomization must have prune:true so orphaned
    resources are deleted (drift correction). bundle_validation must include a reminder
    to configure a PrometheusRule alert for reconciliation failures."""
    data = _generate(
        [{"component": "api-server", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node server.js", "healthPath": "/health", "dependencies": []}],
        id_suffix="driftgate",
    )
    flux_doc = yaml.safe_load(data["flux_yaml"])
    assert flux_doc["spec"].get("prune") is True, \
        "Flux Kustomization must have prune:true to delete orphaned resources and prevent drift"
    assert any("gotk_reconcile_condition" in w and "drift" in w
               for w in data["bundle_validation"]["warnings"]), \
        "bundle_validation must remind operators to configure a drift-detection PrometheusRule alert"
    _cleanup(data["bundle_dir"])


# ---------------------------------------------------------------------------
# Increment 13 — HPA and PDB with applicability gates
# ---------------------------------------------------------------------------

def test_hpa_generated_for_deployment_with_hpa_config():
    """Stage 10.9: When a Deployment component includes an hpa block, an autoscaling/v2
    HorizontalPodAutoscaler must be generated in a separate -scaling.yaml file with the
    declared min/max replicas and CPU target. The HPA scaleTargetRef must point to the
    Deployment by name."""
    data = _generate(
        [{"component": "api-server", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node server.js", "healthPath": "/health", "dependencies": [],
          "hpa": {"minReplicas": 2, "maxReplicas": 10, "targetCPUUtilizationPercentage": 70}}],
        id_suffix="hpa",
    )
    scaling_path = Path(data["bundle_dir"]) / "kustomize_bundle" / "api-server-scaling.yaml"
    assert scaling_path.exists(), "HPA config must generate api-server-scaling.yaml"
    docs = list(yaml.safe_load_all(scaling_path.read_text()))
    hpa = next(d for d in docs if d.get("kind") == "HorizontalPodAutoscaler")
    assert hpa["apiVersion"] == "autoscaling/v2"
    assert hpa["spec"]["scaleTargetRef"] == {"apiVersion": "apps/v1", "kind": "Deployment", "name": "api-server"}
    assert hpa["spec"]["minReplicas"] == 2
    assert hpa["spec"]["maxReplicas"] == 10
    cpu_metric = next(m for m in hpa["spec"]["metrics"] if m["resource"]["name"] == "cpu")
    assert cpu_metric["resource"]["target"]["averageUtilization"] == 70
    # Scaling manifest must be listed in kustomization.yaml resources
    kust = yaml.safe_load((Path(data["bundle_dir"]) / "kustomize_bundle" / "kustomization.yaml").read_text())
    assert "api-server-scaling.yaml" in kust["resources"]
    _cleanup(data["bundle_dir"])


def test_hpa_includes_memory_metric_when_configured():
    """Stage 10.9: When targetMemoryUtilizationPercentage is set, a second memory Resource
    metric must appear alongside the CPU metric in the HPA spec."""
    data = _generate(
        [{"component": "api-server", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node server.js", "healthPath": "/health", "dependencies": [],
          "hpa": {"minReplicas": 2, "maxReplicas": 8,
                  "targetCPUUtilizationPercentage": 70,
                  "targetMemoryUtilizationPercentage": 80}}],
        id_suffix="hpamem",
    )
    docs = list(yaml.safe_load_all(
        (Path(data["bundle_dir"]) / "kustomize_bundle" / "api-server-scaling.yaml").read_text()))
    hpa = next(d for d in docs if d.get("kind") == "HorizontalPodAutoscaler")
    metric_names = {m["resource"]["name"] for m in hpa["spec"]["metrics"]}
    assert "cpu" in metric_names and "memory" in metric_names
    _cleanup(data["bundle_dir"])


def test_no_hpa_generated_when_hpa_field_absent():
    """Stage 10.9: NOT_APPLICABLE — no HPA block in the workload means autoscaling was
    not requested. No -scaling.yaml file should be created for an HPA-only absence."""
    data = _generate(
        [{"component": "backend-worker", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node worker.js", "healthPath": "/health", "dependencies": []}],
        id_suffix="nohpa",
    )
    # HPA not requested - no scaling file created for HPA
    scaling_path = Path(data["bundle_dir"]) / "kustomize_bundle" / "backend-worker-scaling.yaml"
    assert not scaling_path.exists(), "no HPA config means no scaling manifest should be generated"
    _cleanup(data["bundle_dir"])


def test_hpa_not_generated_for_daemonset_or_job():
    """Stage 10.9: DaemonSet, CronJob and Job must not get an HPA even when hpa config is
    present — DaemonSet is node-scoped, CronJob/Job are finite-run workloads."""
    for kind, suffix_comp in [("DaemonSet", "node-agent"), ("CronJob", "nightly-scheduler")]:
        workload_kind_field = kind.upper()
        data = _generate(
            [{"component": suffix_comp, "readiness": "READY", "image": "node:20-slim",
              "startCommand": "node run.js", "healthPath": "/health", "dependencies": [],
              "workloadKind": workload_kind_field,
              "hpa": {"minReplicas": 2, "maxReplicas": 5, "targetCPUUtilizationPercentage": 70}}],
            id_suffix="nohpa-%s" % kind.lower(),
        )
        scaling_path = Path(data["bundle_dir"]) / "kustomize_bundle" / ("%s-scaling.yaml" % suffix_comp)
        assert not scaling_path.exists(), "%s must not receive an HPA" % kind
        _cleanup(data["bundle_dir"])


def test_pdb_generated_for_multi_replica_deployment():
    """Stage 10.9: A Deployment with replicas >= 2 must produce a policy/v1
    PodDisruptionBudget with minAvailable:1 in the -scaling.yaml file so that at least
    one replica remains running during node drain or rolling update."""
    data = _generate(
        [{"component": "api-server", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node server.js", "healthPath": "/health", "dependencies": [],
          "replicas": 2}],
        id_suffix="pdb2",
    )
    scaling_path = Path(data["bundle_dir"]) / "kustomize_bundle" / "api-server-scaling.yaml"
    assert scaling_path.exists()
    docs = list(yaml.safe_load_all(scaling_path.read_text()))
    pdb = next(d for d in docs if d.get("kind") == "PodDisruptionBudget")
    assert pdb["apiVersion"] == "policy/v1"
    assert pdb["spec"]["minAvailable"] == 1
    assert pdb["spec"]["selector"] == {"matchLabels": {"app": "api-server"}}
    _cleanup(data["bundle_dir"])


def test_pdb_min_available_2_for_three_or_more_replicas():
    """Stage 10.9: A Deployment with replicas >= 3 must use minAvailable:2 so that at
    least 50% of replicas remain available during disruption."""
    data = _generate(
        [{"component": "api-server", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node server.js", "healthPath": "/health", "dependencies": [],
          "replicas": 3}],
        id_suffix="pdb3",
    )
    docs = list(yaml.safe_load_all(
        (Path(data["bundle_dir"]) / "kustomize_bundle" / "api-server-scaling.yaml").read_text()))
    pdb = next(d for d in docs if d.get("kind") == "PodDisruptionBudget")
    assert pdb["spec"]["minAvailable"] == 2
    _cleanup(data["bundle_dir"])


def test_no_pdb_for_single_replica_non_critical_deployment():
    """Stage 10.9: NOT_APPLICABLE — a single-replica, non-critical Deployment does not
    receive a PDB (a PDB with minAvailable:1 on 1 replica would block all node drains)."""
    data = _generate(
        [{"component": "backend-worker", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node worker.js", "healthPath": "/health", "dependencies": [],
          "replicas": 1}],
        id_suffix="nopdb1",
    )
    scaling_path = Path(data["bundle_dir"]) / "kustomize_bundle" / "backend-worker-scaling.yaml"
    assert not scaling_path.exists(), \
        "single-replica non-critical Deployment must not receive a PDB"
    _cleanup(data["bundle_dir"])


def test_pdb_omitted_and_warning_issued_for_single_replica_critical_deployment():
    """Stage 10.9: A component flagged critical=true but with replicas=1 must NOT get a
    PDB (it would permanently block node drains) but must produce a bundle_validation
    warning explaining that HA is unavailable."""
    data = _generate(
        [{"component": "auth-service", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node auth.js", "healthPath": "/health", "dependencies": [],
          "replicas": 1, "critical": True}],
        id_suffix="criticalpdb",
    )
    scaling_path = Path(data["bundle_dir"]) / "kustomize_bundle" / "auth-service-scaling.yaml"
    if scaling_path.exists():
        docs = list(yaml.safe_load_all(scaling_path.read_text()))
        kinds = [d.get("kind") for d in docs if d]
        assert "PodDisruptionBudget" not in kinds, \
            "must not generate a PDB for single-replica critical component"
    assert any("critical=true" in w and "auth-service" in w and "replicas=1" in w
               for w in data["bundle_validation"]["warnings"]), \
        "must warn that HA is unavailable when critical=true but replicas=1"
    _cleanup(data["bundle_dir"])


# ---------------------------------------------------------------------------
# Increment 14 — Operator Custom Resources (PostgreSQL, Redis, RabbitMQ, Kafka)
# ---------------------------------------------------------------------------

def test_postgres_operator_cr_generated_for_operator_managed_component():
    """Stage 10.10: A component with targetForm=OPERATOR_MANAGED and 'postgres' in the
    name must produce a postgresql.cnpg.io/v1 Cluster CR (not a Deployment) in
    {comp}-operator-cr.yaml. The CR must be listed in kustomization.yaml resources."""
    data = _generate(
        [{"component": "postgres-primary", "readiness": "KEEP_ON_VM_FOR_NOW",
          "targetForm": "OPERATOR_MANAGED", "targetIp": "", "targetPort": 5432,
          "replicas": 2, "storageClass": "fast-ssd", "storageSize": "50Gi"}],
        id_suffix="pgcr",
    )
    cr_path = Path(data["bundle_dir"]) / "kustomize_bundle" / "postgres-primary-operator-cr.yaml"
    assert cr_path.exists(), "PostgreSQL operator CR must be generated"
    cr = yaml.safe_load(cr_path.read_text())
    assert cr["apiVersion"] == "postgresql.cnpg.io/v1"
    assert cr["kind"] == "Cluster"
    assert cr["spec"]["instances"] == 2
    assert cr["spec"]["storage"]["size"] == "50Gi"
    assert cr["spec"]["storage"]["storageClass"] == "fast-ssd"
    kust = yaml.safe_load(
        (Path(data["bundle_dir"]) / "kustomize_bundle" / "kustomization.yaml").read_text())
    assert "postgres-primary-operator-cr.yaml" in kust["resources"]
    _cleanup(data["bundle_dir"])


def test_redis_operator_cr_generated_for_operator_managed_component():
    """Stage 10.10: A component with targetForm=OPERATOR_MANAGED and 'redis' in the name
    must produce a redis.redis.opstreelabs.in/v1beta2 Redis CR."""
    data = _generate(
        [{"component": "redis-cache", "readiness": "KEEP_ON_VM_FOR_NOW",
          "targetForm": "OPERATOR_MANAGED", "targetIp": "", "targetPort": 6379,
          "replicas": 3, "storageSize": "20Gi"}],
        id_suffix="rediscr",
    )
    cr_path = Path(data["bundle_dir"]) / "kustomize_bundle" / "redis-cache-operator-cr.yaml"
    assert cr_path.exists()
    cr = yaml.safe_load(cr_path.read_text())
    assert cr["apiVersion"] == "redis.redis.opstreelabs.in/v1beta2"
    assert cr["kind"] == "Redis"
    assert cr["spec"]["clusterSize"] == 3
    assert cr["spec"]["persistenceEnabled"] is True
    assert cr["spec"]["storage"]["volumeClaimTemplate"]["spec"]["resources"]["requests"]["storage"] == "20Gi"
    _cleanup(data["bundle_dir"])


def test_rabbitmq_operator_cr_generated_for_operator_managed_component():
    """Stage 10.10: A component with targetForm=OPERATOR_MANAGED and 'rabbitmq' in the
    name must produce a rabbitmq.com/v1beta1 RabbitmqCluster CR."""
    data = _generate(
        [{"component": "rabbitmq-broker", "readiness": "KEEP_ON_VM_FOR_NOW",
          "targetForm": "OPERATOR_MANAGED", "targetIp": "", "targetPort": 5672,
          "replicas": 3}],
        id_suffix="rmqcr",
    )
    cr_path = Path(data["bundle_dir"]) / "kustomize_bundle" / "rabbitmq-broker-operator-cr.yaml"
    assert cr_path.exists()
    cr = yaml.safe_load(cr_path.read_text())
    assert cr["apiVersion"] == "rabbitmq.com/v1beta1"
    assert cr["kind"] == "RabbitmqCluster"
    assert cr["spec"]["replicas"] == 3
    _cleanup(data["bundle_dir"])


def test_kafka_operator_cr_generated_for_operator_managed_component():
    """Stage 10.10: A component with targetForm=OPERATOR_MANAGED and 'kafka' in the name
    must produce a kafka.strimzi.io/v1beta2 Kafka CR with kafka, zookeeper and
    entityOperator sections."""
    data = _generate(
        [{"component": "kafka-cluster", "readiness": "KEEP_ON_VM_FOR_NOW",
          "targetForm": "OPERATOR_MANAGED", "targetIp": "", "targetPort": 9092,
          "replicas": 1}],
        id_suffix="kafkacr",
    )
    cr_path = Path(data["bundle_dir"]) / "kustomize_bundle" / "kafka-cluster-operator-cr.yaml"
    assert cr_path.exists()
    cr = yaml.safe_load(cr_path.read_text())
    assert cr["apiVersion"] == "kafka.strimzi.io/v1beta2"
    assert cr["kind"] == "Kafka"
    assert "kafka" in cr["spec"] and "zookeeper" in cr["spec"]
    assert "entityOperator" in cr["spec"]
    assert cr["spec"]["kafka"]["replicas"] == 1
    _cleanup(data["bundle_dir"])


def test_missing_operator_for_operator_managed_component_is_a_blocker():
    """Stage 10.10: When a component is OPERATOR_MANAGED but its required operator
    FluxCD Kustomization is absent from the GitOps repo, bundle_validation.status must
    be BLOCKED (not PASSED_WITH_WARNINGS) because the generated CR would be applied
    against a cluster with no CRD to accept it."""
    org, cluster = "r6-dryrun-op-blocker-org", "r6-dryrun-op-blocker-cluster"
    _make_fake_gitops(org, cluster, wire_managed_services_fluxcd=True, stub_operators=[])
    try:
        data = _generate(
            [{"component": "postgres-primary", "readiness": "KEEP_ON_VM_FOR_NOW",
              "targetForm": "OPERATOR_MANAGED", "targetIp": "", "targetPort": 5432}],
            id_suffix="opblocker", name="Op Blocker", org=org, cluster=cluster,
            import_to_gitops=True, auto_commit=False,
        )
        assert data["bundle_validation"]["status"] == "BLOCKED", \
            "missing required operator must be a blocker, not just a warning"
        assert any("postgres-operator" in b and "OPERATOR_MANAGED" in b
                   for b in data["bundle_validation"]["blockers"]), \
            "blocker must name the missing operator and the OPERATOR_MANAGED component"
        _cleanup(data["bundle_dir"])
    finally:
        _cleanup_fake_gitops(org)


def test_operator_cr_not_generated_for_non_operator_managed_component():
    """Stage 10.10: NOT_APPLICABLE — a component with a postgres/redis name but
    targetForm != OPERATOR_MANAGED must not receive an operator CR."""
    data = _generate(
        [{"component": "postgres-sidecar", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node run.js", "healthPath": "/health", "dependencies": [],
          "targetForm": "CONTAINERIZED"}],
        id_suffix="noopcr",
    )
    cr_path = Path(data["bundle_dir"]) / "kustomize_bundle" / "postgres-sidecar-operator-cr.yaml"
    assert not cr_path.exists(), \
        "operator CR must not be generated for a non-OPERATOR_MANAGED component"
    _cleanup(data["bundle_dir"])


# ---------------------------------------------------------------------------
# Increment 15: Stage 10.11 — ServiceMonitor, PrometheusRule, Velero Schedule
# ---------------------------------------------------------------------------

def test_service_monitor_and_prometheus_rule_generated_when_prometheus_operator_available():
    """Stage 10.11: ServiceMonitor per HTTP component + namespace-wide PrometheusRule are
    generated when prometheus-operator is present in the cluster's services/fluxcd directory.
    The Service port must be named 'http' so the ServiceMonitor selector resolves."""
    org, cluster = "r6-dryrun-obs-avail-org", "r6-dryrun-obs-cluster"
    _make_fake_gitops(org, cluster, wire_managed_services_fluxcd=True,
                      stub_operators=["prometheus-operator"])
    try:
        data = _generate(
            [{"component": "api-server", "readiness": "READY", "image": "node:20-slim",
              "startCommand": "node server.js", "healthPath": "/health", "dependencies": [],
              "targetForm": "CONTAINERIZED"},
             {"component": "worker", "readiness": "READY", "image": "python:3.12-slim",
              "startCommand": "python worker.py", "healthPath": "/health", "dependencies": [],
              "targetForm": "CONTAINERIZED"}],
            id_suffix="obsavail", name="Obs Available", org=org, cluster=cluster,
            import_to_gitops=True, auto_commit=False,
        )
        obs_path = Path(data["bundle_dir"]) / "kustomize_bundle" / "observability.yaml"
        assert obs_path.exists(), "observability.yaml must be generated when prometheus-operator is present"
        obs_docs = list(yaml.safe_load_all(obs_path.read_text()))
        obs_docs = [d for d in obs_docs if d]

        sms = [d for d in obs_docs if d.get("kind") == "ServiceMonitor"]
        assert len(sms) == 2, "one ServiceMonitor per HTTP component expected, got %d" % len(sms)
        sm_names = {sm["metadata"]["name"] for sm in sms}
        assert sm_names == {"api-server", "worker"}
        for sm in sms:
            ep = sm["spec"]["endpoints"][0]
            assert ep["port"] == "http", "ServiceMonitor endpoint must reference named port 'http'"
            assert ep["path"] == "/metrics"
            assert ep["interval"] == "30s"

        rules = [d for d in obs_docs if d.get("kind") == "PrometheusRule"]
        assert len(rules) == 1, "one PrometheusRule per namespace expected"
        alert_names = {r["alert"] for r in rules[0]["spec"]["groups"][0]["rules"]}
        assert "HighErrorRate" in alert_names
        assert "PodCrashLooping" in alert_names
        assert "FluxReconciliationFailed" in alert_names

        # Service port must be named 'http' so the ServiceMonitor selector resolves
        svc_doc = _load_kind(data["bundle_dir"], "api-server.yaml", "Service")
        port = svc_doc["spec"]["ports"][0]
        assert port.get("name") == "http", "Service port must be named 'http' for ServiceMonitor"

        assert "kustomize_bundle/observability.yaml" in data["files"]
        _cleanup(data["bundle_dir"])
    finally:
        _cleanup_fake_gitops(org)


def test_service_monitor_not_generated_when_prometheus_operator_absent():
    """Stage 10.11: NOT_APPLICABLE — when the cluster has no Prometheus Operator in
    services/fluxcd, observability.yaml is not generated and a warning is issued instead."""
    org, cluster = "r6-dryrun-obs-absent-org", "r6-dryrun-obs-abs-cluster"
    _make_fake_gitops(org, cluster, wire_managed_services_fluxcd=True, stub_operators=[])
    try:
        data = _generate(
            [{"component": "api-server", "readiness": "READY", "image": "node:20-slim",
              "startCommand": "node server.js", "healthPath": "/health", "dependencies": [],
              "targetForm": "CONTAINERIZED"}],
            id_suffix="obsabsent", name="Obs Absent", org=org, cluster=cluster,
            import_to_gitops=True, auto_commit=False,
        )
        obs_path = Path(data["bundle_dir"]) / "kustomize_bundle" / "observability.yaml"
        assert not obs_path.exists(), \
            "observability.yaml must not be generated when Prometheus Operator is absent"
        assert data["bundle_validation"]["status"] != "BLOCKED", \
            "missing prometheus operator must not block the bundle (NOT_APPLICABLE, not BLOCKED)"
        assert any("prometheus" in w.lower() and "not generated" in w.lower()
                   for w in data["bundle_validation"]["warnings"]), \
            "a warning must explain that ServiceMonitor was not generated"
        _cleanup(data["bundle_dir"])
    finally:
        _cleanup_fake_gitops(org)


def test_service_monitor_not_generated_for_operator_managed_components():
    """Stage 10.11: NOT_APPLICABLE — OPERATOR_MANAGED components have their own Service
    managed by the operator; no ServiceMonitor from the standard template should be generated."""
    data = _generate(
        [{"component": "redis-cache", "readiness": "READY",
          "targetForm": "OPERATOR_MANAGED", "targetIp": "", "targetPort": 6379}],
        id_suffix="obsopmgd",
    )
    obs_path = Path(data["bundle_dir"]) / "kustomize_bundle" / "observability.yaml"
    # No prometheus operator available (preview mode, no gitops) and OPERATOR_MANAGED →
    # no ServiceMonitor should appear
    if obs_path.exists():
        obs_docs = [d for d in yaml.safe_load_all(obs_path.read_text()) if d]
        sms = [d for d in obs_docs if d.get("kind") == "ServiceMonitor"]
        assert all(sm["metadata"]["name"] != "redis-cache" for sm in sms), \
            "OPERATOR_MANAGED component must not receive a standard ServiceMonitor"
    _cleanup(data["bundle_dir"])


def test_velero_schedule_generated_for_namespace_with_pvcs():
    """Stage 10.11: Velero Schedule generated for namespace with persistent storage when
    velero is present in the cluster's services/fluxcd directory."""
    org, cluster = "r6-dryrun-velero-avail-org", "r6-dryrun-velero-cluster"
    _make_fake_gitops(org, cluster, wire_managed_services_fluxcd=True,
                      stub_operators=["velero"])
    try:
        data = _generate(
            [{"component": "db-primary", "readiness": "READY", "image": "postgres:15-alpine",
              "startCommand": "postgres", "healthPath": "/health", "dependencies": [],
              "persistentPath": "/var/lib/postgresql/data", "storageClass": "fast-ssd",
              "targetForm": "CONTAINERIZED"}],
            id_suffix="veleroa", name="Velero Available", org=org, cluster=cluster,
            import_to_gitops=True, auto_commit=False,
        )
        velero_path = Path(data["bundle_dir"]) / "kustomize_bundle" / "velero-schedule.yaml"
        assert velero_path.exists(), "velero-schedule.yaml must be generated for namespaces with PVCs"
        sched = yaml.safe_load(velero_path.read_text())
        assert sched["apiVersion"] == "velero.io/v1"
        assert sched["kind"] == "Schedule"
        included_ns = sched["spec"]["template"]["includedNamespaces"]
        assert len(included_ns) == 1 and included_ns[0], \
            "Schedule must target exactly one namespace"
        assert sched["spec"]["schedule"] == "0 2 * * *"
        assert "events" in sched["spec"]["template"]["excludedResources"]
        assert "kustomize_bundle/velero-schedule.yaml" in data["files"]
        _cleanup(data["bundle_dir"])
    finally:
        _cleanup_fake_gitops(org)


def test_velero_schedule_not_generated_when_velero_absent():
    """Stage 10.11: NOT_APPLICABLE — when the cluster has no Velero in services/fluxcd,
    no Velero Schedule is generated and a warning is issued instead."""
    org, cluster = "r6-dryrun-velero-absent-org", "r6-dryrun-velero-abs-cluster"
    _make_fake_gitops(org, cluster, wire_managed_services_fluxcd=True, stub_operators=[])
    try:
        data = _generate(
            [{"component": "db-primary", "readiness": "READY", "image": "postgres:15-alpine",
              "startCommand": "postgres", "healthPath": "/health", "dependencies": [],
              "persistentPath": "/var/lib/postgresql/data", "targetForm": "CONTAINERIZED"}],
            id_suffix="velerob", name="Velero Absent", org=org, cluster=cluster,
            import_to_gitops=True, auto_commit=False,
        )
        velero_path = Path(data["bundle_dir"]) / "kustomize_bundle" / "velero-schedule.yaml"
        assert not velero_path.exists(), \
            "velero-schedule.yaml must not be generated when Velero is absent from the cluster"
        assert data["bundle_validation"]["status"] != "BLOCKED", \
            "missing velero must not block the bundle (NOT_APPLICABLE, not BLOCKED)"
        assert any("velero" in w.lower() and "not generated" in w.lower()
                   for w in data["bundle_validation"]["warnings"]), \
            "a warning must explain that Velero Schedule was not generated"
        _cleanup(data["bundle_dir"])
    finally:
        _cleanup_fake_gitops(org)


def test_velero_not_generated_for_stateless_namespace():
    """Stage 10.11: NOT_APPLICABLE — a namespace with no PVCs and no stateful operator
    components must not generate a Velero Schedule."""
    data = _generate(
        [{"component": "api-server", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node server.js", "healthPath": "/health", "dependencies": [],
          "targetForm": "CONTAINERIZED"}],
        id_suffix="veleroNA",
    )
    velero_path = Path(data["bundle_dir"]) / "kustomize_bundle" / "velero-schedule.yaml"
    assert not velero_path.exists(), \
        "Velero Schedule must not be generated for a stateless namespace"
    _cleanup(data["bundle_dir"])


# ---------------------------------------------------------------------------
# Increment 16: Stage 10.12 — HTTP, DNS, Database Validation Jobs
# ---------------------------------------------------------------------------

_BUSYBOX_DIGEST = "sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662"
_POSTGRES_DIGEST = "sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777"


def test_http_validation_jobs_generated_for_http_components():
    """Stage 10.12: One HTTP validation Job per Deployment/StatefulSet component, using
    a digest-pinned busybox image to wget the /health endpoint via in-cluster DNS."""
    data = _generate(
        [{"component": "api-server", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node server.js", "healthPath": "/health", "dependencies": [],
          "targetForm": "CONTAINERIZED"},
         {"component": "worker", "readiness": "READY", "image": "python:3.12-slim",
          "startCommand": "python worker.py", "healthPath": "/health", "dependencies": [],
          "targetForm": "CONTAINERIZED"}],
        id_suffix="httpvalidjob",
    )
    jobs_path = Path(data["bundle_dir"]) / "kustomize_bundle" / "validation-jobs.yaml"
    assert jobs_path.exists(), "validation-jobs.yaml must be generated for HTTP components"
    jobs = [d for d in yaml.safe_load_all(jobs_path.read_text()) if d and d.get("kind") == "Job"]
    http_jobs = [j for j in jobs if j.get("metadata", {}).get("labels", {}).get("r6-validation") == "http"]
    assert len(http_jobs) == 2, "one HTTP Job per HTTP component expected, got %d" % len(http_jobs)
    http_job_names = {j["metadata"]["name"] for j in http_jobs}
    assert "validate-http-api-server" in http_job_names
    assert "validate-http-worker" in http_job_names
    for j in http_jobs:
        img = j["spec"]["template"]["spec"]["containers"][0]["image"]
        assert "@" + _BUSYBOX_DIGEST in img, \
            "HTTP validation Job image must be digest-pinned, got: %s" % img
        cmd = j["spec"]["template"]["spec"]["containers"][0]["command"]
        assert "wget" in cmd, "HTTP validation Job must use wget"
        assert j["spec"]["template"]["spec"]["restartPolicy"] == "Never"
    _cleanup(data["bundle_dir"])


def test_dns_validation_job_generated_for_service_names():
    """Stage 10.12: A single DNS validation Job is generated that resolves every
    in-cluster Service name (and VM aliases) using nslookup via in-cluster DNS."""
    data = _generate(
        [{"component": "api-server", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node server.js", "healthPath": "/health", "dependencies": [],
          "targetForm": "CONTAINERIZED"},
         {"component": "legacy-db", "readiness": "KEEP_ON_VM_FOR_NOW",
          "targetIp": "10.0.0.5", "targetPort": 5432}],
        id_suffix="dnsvalidjob",
    )
    jobs_path = Path(data["bundle_dir"]) / "kustomize_bundle" / "validation-jobs.yaml"
    assert jobs_path.exists()
    jobs = [d for d in yaml.safe_load_all(jobs_path.read_text()) if d and d.get("kind") == "Job"]
    dns_jobs = [j for j in jobs if j.get("metadata", {}).get("labels", {}).get("r6-validation") == "dns"]
    assert len(dns_jobs) == 1, "exactly one DNS validation Job expected"
    dns_cmd = " ".join(str(x) for x in dns_jobs[0]["spec"]["template"]["spec"]["containers"][0]["command"])
    assert "nslookup" in dns_cmd
    assert "api-server" in dns_cmd
    assert "legacy-db" in dns_cmd
    img = dns_jobs[0]["spec"]["template"]["spec"]["containers"][0]["image"]
    assert "@" + _BUSYBOX_DIGEST in img, "DNS validation Job image must be digest-pinned"
    _cleanup(data["bundle_dir"])


def test_database_validation_job_uses_secret_references_not_inline_credentials():
    """Stage 10.12: Database validation Job must reference DB credentials via secretKeyRef
    (from the component's SecretContract) and the DB host via configMapKeyRef — never inline.
    Inline credentials in env vars would be a plaintext secret in the bundle."""
    data = _generate(
        [{"component": "api-server", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node server.js", "healthPath": "/health",
          "dependencies": ["postgres-primary"],
          "targetForm": "CONTAINERIZED"}],
        id_suffix="dbvalidjob",
    )
    jobs_path = Path(data["bundle_dir"]) / "kustomize_bundle" / "validation-jobs.yaml"
    assert jobs_path.exists()
    jobs = [d for d in yaml.safe_load_all(jobs_path.read_text()) if d and d.get("kind") == "Job"]
    db_jobs = [j for j in jobs if j.get("metadata", {}).get("labels", {}).get("r6-validation") == "database"]
    assert len(db_jobs) >= 1, "at least one database validation Job expected for DB dependency"
    db_job = db_jobs[0]
    env = db_job["spec"]["template"]["spec"]["containers"][0]["env"]
    for ev in env:
        assert "value" not in ev, \
            "inline credential detected in env var '%s' — must use valueFrom" % ev.get("name")
    host_var = next(e for e in env if e["name"] == "DB_HOST")
    assert "configMapKeyRef" in host_var.get("valueFrom", {}), \
        "DB_HOST must come from configMapKeyRef (non-secret config)"
    user_var = next(e for e in env if e["name"] == "DB_USER")
    pass_var = next(e for e in env if e["name"] == "DB_PASS")
    assert "secretKeyRef" in user_var.get("valueFrom", {}), "DB_USER must use secretKeyRef"
    assert "secretKeyRef" in pass_var.get("valueFrom", {}), "DB_PASS must use secretKeyRef"
    img = db_job["spec"]["template"]["spec"]["containers"][0]["image"]
    assert "@sha256:" in img, "database validation Job image must be digest-pinned"
    _cleanup(data["bundle_dir"])


def test_validation_jobs_not_generated_for_daemonset_or_job_components():
    """Stage 10.12: NOT_APPLICABLE — DaemonSet and Job/CronJob components are not
    HTTP-serving (no ClusterIP Service), so no HTTP validation Job is generated for them."""
    data = _generate(
        [{"component": "log-collector", "readiness": "READY", "image": "fluent/fluent-bit:latest",
          "startCommand": "fluentbit", "healthPath": "/health", "dependencies": [],
          "targetForm": "CONTAINERIZED", "workloadKind": "DAEMONSET"}],
        id_suffix="novalidjobds",
    )
    jobs_path = Path(data["bundle_dir"]) / "kustomize_bundle" / "validation-jobs.yaml"
    if jobs_path.exists():
        jobs = [d for d in yaml.safe_load_all(jobs_path.read_text()) if d and d.get("kind") == "Job"]
        http_jobs = [j for j in jobs
                     if j.get("metadata", {}).get("labels", {}).get("r6-validation") == "http"]
        assert not any("log-collector" in j["metadata"]["name"] for j in http_jobs), \
            "DaemonSet must not receive an HTTP validation Job"
    _cleanup(data["bundle_dir"])


# ---------------------------------------------------------------------------
# Increment 17: Stage 13 — /api/r6/run-validation endpoint and evidence
# ---------------------------------------------------------------------------

VALIDATION_ENDPOINT = BASE_URL + "/api/r6/run-validation"


def test_run_validation_rejects_missing_bundle_dir():
    """Stage 13: run-validation must return a clear error when bundle_dir is absent."""
    try:
        resp = requests.post(VALIDATION_ENDPOINT, json={}, timeout=10)
    except requests.exceptions.ConnectionError:
        pytest.skip("osflex-dashboard is not running")
    assert resp.status_code == 400
    body = resp.json()
    assert body.get("ok") is False
    assert "bundle_dir" in body.get("error", "")


def test_run_validation_rejects_nonexistent_bundle_dir():
    """Stage 13: run-validation must return a clear error when bundle_dir does not exist."""
    try:
        resp = requests.post(VALIDATION_ENDPOINT,
                             json={"bundle_dir": "/tmp/r6-nonexistent-bundle-12345"},
                             timeout=10)
    except requests.exceptions.ConnectionError:
        pytest.skip("osflex-dashboard is not running")
    assert resp.status_code == 400
    body = resp.json()
    assert body.get("ok") is False
    assert "does not exist" in body.get("error", "")


def test_run_validation_rejects_bundle_without_validation_jobs():
    """Stage 13: run-validation must return a clear error when the bundle has no
    validation-jobs.yaml — this happens when Stage 10.12 was skipped or the bundle
    had no HTTP-serving or VM-alias components."""
    # Generate a bundle with only VM workloads (no deployable HTTP components)
    # so validation-jobs.yaml is not generated
    data = _generate(
        [{"component": "legacy-only", "readiness": "KEEP_ON_VM_FOR_NOW",
          "targetIp": "10.0.0.5", "targetPort": 8080}],
        id_suffix="novalidjobs17",
    )
    bundle_dir = data["bundle_dir"]
    jobs_path = Path(bundle_dir) / "kustomize_bundle" / "validation-jobs.yaml"
    # This bundle has VM-only workload → DNS job IS generated (legacy-only is in vm_workloads).
    # Remove the file manually to test the "no validation-jobs.yaml" error path.
    if jobs_path.exists():
        jobs_path.unlink()
    try:
        resp = requests.post(VALIDATION_ENDPOINT, json={"bundle_dir": bundle_dir}, timeout=10)
    except requests.exceptions.ConnectionError:
        pytest.skip("osflex-dashboard is not running")
    assert resp.status_code == 400
    body = resp.json()
    assert body.get("ok") is False
    assert "validation-jobs.yaml" in body.get("error", "")
    _cleanup(bundle_dir)


def test_run_validation_response_structure_when_no_cluster_available():
    """Stage 13: When kubectl is not configured or fails to apply, run-validation must
    return a structured error response (not a 500 crash). The evidence schema must be
    consistent regardless of kubectl availability — this tests the response contract."""
    data = _generate(
        [{"component": "api-server", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node server.js", "healthPath": "/health", "dependencies": [],
          "targetForm": "CONTAINERIZED"}],
        id_suffix="runvalidstruct",
    )
    bundle_dir = data["bundle_dir"]
    try:
        resp = requests.post(VALIDATION_ENDPOINT,
                             json={"bundle_dir": bundle_dir,
                                   "kubeconfig": "/tmp/r6-no-such-kubeconfig.yaml"},
                             timeout=30)
    except requests.exceptions.ConnectionError:
        pytest.skip("osflex-dashboard is not running")
    # Either 500 (kubectl apply failed) or 200 (if kubectl returns quickly)
    # In both cases: response must be JSON with an 'ok' field
    body = resp.json()
    assert "ok" in body, "response must always include 'ok' field"
    if resp.status_code == 500:
        assert body["ok"] is False
        assert "error" in body
    elif resp.status_code == 200:
        assert "results" in body
        assert "all_passed" in body
        assert "evidence_path" in body
    _cleanup(bundle_dir)


# ---------------------------------------------------------------------------
# Increment 18: Stage 14 — Rollback runbook
# ---------------------------------------------------------------------------

def test_rollback_runbook_generated_unconditionally():
    """Stage 14: A rollback runbook must be generated for every bundle, regardless of
    workload type or cluster configuration. It is always required before production cutover."""
    data = _generate(
        [{"component": "api-server", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node server.js", "healthPath": "/health", "dependencies": [],
          "targetForm": "CONTAINERIZED"}],
        id_suffix="rollback1",
    )
    runbook_path = Path(data["bundle_dir"]) / "operations" / "rollback-runbook.yaml"
    assert runbook_path.exists(), "operations/rollback-runbook.yaml must always be generated"
    runbook = yaml.safe_load(runbook_path.read_text())
    assert runbook["kind"] == "RollbackRunbook"
    assert runbook["apiVersion"] == "r6.opencenter.io/v1alpha1"
    _cleanup(data["bundle_dir"])


def test_rollback_runbook_contains_required_sections():
    """Stage 14: Rollback runbook must include git revision instructions, image list,
    traffic/DNS rollback steps, VM workload handling, and data limitations."""
    data = _generate(
        [{"component": "api-server", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node server.js", "healthPath": "/health", "dependencies": [],
          "targetForm": "CONTAINERIZED"},
         {"component": "legacy-db", "readiness": "KEEP_ON_VM_FOR_NOW",
          "targetIp": "10.0.0.5", "targetPort": 5432}],
        id_suffix="rollback2",
    )
    runbook_path = Path(data["bundle_dir"]) / "operations" / "rollback-runbook.yaml"
    runbook = yaml.safe_load(runbook_path.read_text())
    spec = runbook["spec"]

    assert "gitRevision" in spec, "rollback runbook must include git revision section"
    assert "rollbackCommand" in spec["gitRevision"]
    assert "flux" in spec["gitRevision"]["rollbackCommand"].lower()

    assert "images" in spec, "rollback runbook must list component images"
    assert len(spec["images"]) >= 1
    for img in spec["images"]:
        assert "component" in img
        assert "generated_image" in img
        assert "previous_image" in img

    assert "traffic" in spec, "rollback runbook must include traffic/DNS rollback section"
    assert "lbRollback" in spec["traffic"]
    assert "dnsFlushCommand" in spec["traffic"]

    assert "vmWorkloads" in spec, "rollback runbook must list VM workloads"
    vm_names = [v["component"] for v in spec["vmWorkloads"]]
    assert "legacy-db" in vm_names, "VM-backed components must appear in vmWorkloads"

    assert "vmNote" in spec, "rollback runbook must include a VM rollback limitation note"
    assert "legacy-db" in spec["vmNote"]

    assert "dataLimitations" in spec, "rollback runbook must document data rollback limitations"
    assert len(spec["dataLimitations"]) >= 2
    assert any("database" in lim.lower() or "schema" in lim.lower()
               for lim in spec["dataLimitations"])
    assert any("PVC" in lim or "data" in lim.lower() for lim in spec["dataLimitations"])

    assert "verificationSteps" in spec
    assert len(spec["verificationSteps"]) >= 3

    _cleanup(data["bundle_dir"])


def test_rollback_runbook_image_list_covers_all_deployable_components():
    """Stage 14: Every deployable component must have an entry in the rollback runbook's
    image list so operators know exactly what to revert on rollback."""
    data = _generate(
        [{"component": "api-server", "readiness": "READY", "image": "node:20-slim",
          "startCommand": "node server.js", "healthPath": "/health", "dependencies": [],
          "targetForm": "CONTAINERIZED"},
         {"component": "worker", "readiness": "READY", "image": "python:3.12-slim",
          "startCommand": "python worker.py", "healthPath": "/health", "dependencies": [],
          "targetForm": "CONTAINERIZED"}],
        id_suffix="rollback3",
    )
    runbook_path = Path(data["bundle_dir"]) / "operations" / "rollback-runbook.yaml"
    runbook = yaml.safe_load(runbook_path.read_text())
    image_comps = {img["component"] for img in runbook["spec"]["images"]}
    assert "api-server" in image_comps
    assert "worker" in image_comps
    _cleanup(data["bundle_dir"])
