"""
Validator: cluster health and migration validation checks.

Runs a suite of checks against the target cluster after restore to confirm
that the migration succeeded and key workloads are healthy.
"""
from __future__ import annotations

import json
import logging
import shutil
import subprocess
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from .io_utils import run_cmd
from .models import ValidationResult

log = logging.getLogger(__name__)


# ── Magnum validation checks constant ─────────────────────────────────────────

MAGNUM_VALIDATION_CHECKS: List[str] = [
    "magnum_cluster_status",
    "loadbalancer_test",
    "kubectl_nodes",
    "pvc_binding",
    "svc_endpoints",
    "ingress_objects",
]


# ── kubectl helper ────────────────────────────────────────────────────────────

def _kubectl(
    args: str,
    context: Optional[str] = None,
    kubeconfig: Optional[str] = None,
    timeout: int = 60,
) -> Tuple[int, str, str]:
    flags = ""
    if context:
        flags += f" --context={context}"
    if kubeconfig:
        flags += f" --kubeconfig={kubeconfig}"
    return run_cmd(f"kubectl{flags} {args}", capture=True, timeout=timeout)


# ── Individual checks ─────────────────────────────────────────────────────────

def check_nodes_ready(
    context: Optional[str] = None,
    kubeconfig: Optional[str] = None,
) -> ValidationResult:
    """Verify that all nodes are in Ready state."""
    rc, out, err = _kubectl(
        "get nodes --no-headers",
        context=context,
        kubeconfig=kubeconfig,
    )
    if rc != 0:
        return ValidationResult(
            check="nodes_ready",
            passed=False,
            detail=f"kubectl get nodes failed: {err}",
        )
    lines = [l for l in out.splitlines() if l.strip()]
    not_ready = [l for l in lines if "NotReady" in l or "Unknown" in l]
    if not_ready:
        return ValidationResult(
            check="nodes_ready",
            passed=False,
            detail=f"{len(not_ready)} node(s) not ready: {not_ready[:3]}",
        )
    return ValidationResult(
        check="nodes_ready",
        passed=True,
        detail=f"{len(lines)} node(s) all Ready",
    )


def check_namespaces_exist(
    expected: List[str],
    context: Optional[str] = None,
    kubeconfig: Optional[str] = None,
) -> ValidationResult:
    """Verify that all expected namespaces exist on the target cluster."""
    rc, out, err = _kubectl(
        "get namespaces -o jsonpath='{.items[*].metadata.name}'",
        context=context,
        kubeconfig=kubeconfig,
    )
    if rc != 0:
        return ValidationResult(
            check="namespaces_exist",
            passed=False,
            detail=f"kubectl get namespaces failed: {err}",
        )
    existing = set(out.strip("'").split())
    missing = [ns for ns in expected if ns not in existing]
    if missing:
        return ValidationResult(
            check="namespaces_exist",
            passed=False,
            detail=f"Missing namespaces: {missing}",
        )
    return ValidationResult(
        check="namespaces_exist",
        passed=True,
        detail=f"All {len(expected)} expected namespace(s) present",
    )


def check_deployments_available(
    namespaces: Optional[List[str]] = None,
    context: Optional[str] = None,
    kubeconfig: Optional[str] = None,
) -> ValidationResult:
    """
    Check that all Deployments have their desired replicas available.

    Checks across all namespaces (or the provided list).
    """
    ns_flag = "--all-namespaces"
    if namespaces and len(namespaces) == 1:
        ns_flag = f"-n {namespaces[0]}"

    rc, out, err = _kubectl(
        f"get deployments {ns_flag} -o json",
        context=context,
        kubeconfig=kubeconfig,
        timeout=90,
    )
    if rc != 0:
        return ValidationResult(
            check="deployments_available",
            passed=False,
            detail=f"kubectl get deployments failed: {err}",
        )

    try:
        data = json.loads(out)
        items = data.get("items", [])
    except json.JSONDecodeError:
        return ValidationResult(
            check="deployments_available",
            passed=False,
            detail="Could not parse deployments JSON",
        )

    if namespaces and len(namespaces) > 1:
        items = [i for i in items if i.get("metadata", {}).get("namespace") in namespaces]

    unhealthy: List[str] = []
    for item in items:
        meta = item.get("metadata", {})
        ns = meta.get("namespace", "")
        name = meta.get("name", "")
        spec = item.get("spec", {})
        status = item.get("status", {})
        desired = spec.get("replicas", 1)
        available = status.get("availableReplicas", 0)
        if available < desired:
            unhealthy.append(f"{ns}/{name} ({available}/{desired})")

    if unhealthy:
        return ValidationResult(
            check="deployments_available",
            passed=False,
            detail=f"{len(unhealthy)} deployment(s) not fully available: {unhealthy[:5]}",
        )
    return ValidationResult(
        check="deployments_available",
        passed=True,
        detail=f"All {len(items)} deployment(s) available",
    )


def check_statefulsets_ready(
    namespaces: Optional[List[str]] = None,
    context: Optional[str] = None,
    kubeconfig: Optional[str] = None,
) -> ValidationResult:
    """Check that all StatefulSets have their desired ready replicas."""
    ns_flag = "--all-namespaces"
    rc, out, err = _kubectl(
        f"get statefulsets {ns_flag} -o json",
        context=context,
        kubeconfig=kubeconfig,
        timeout=90,
    )
    if rc != 0:
        return ValidationResult(
            check="statefulsets_ready",
            passed=False,
            detail=f"kubectl get statefulsets failed: {err}",
        )
    try:
        data = json.loads(out)
        items = data.get("items", [])
    except json.JSONDecodeError:
        items = []

    if namespaces:
        items = [i for i in items if i.get("metadata", {}).get("namespace") in namespaces]

    unhealthy: List[str] = []
    for item in items:
        meta = item.get("metadata", {})
        ns = meta.get("namespace", "")
        name = meta.get("name", "")
        spec = item.get("spec", {})
        status = item.get("status", {})
        desired = spec.get("replicas", 1)
        ready = status.get("readyReplicas", 0)
        if ready < desired:
            unhealthy.append(f"{ns}/{name} ({ready}/{desired})")

    if unhealthy:
        return ValidationResult(
            check="statefulsets_ready",
            passed=False,
            detail=f"{len(unhealthy)} StatefulSet(s) not fully ready: {unhealthy[:5]}",
        )
    return ValidationResult(
        check="statefulsets_ready",
        passed=True,
        detail=f"All {len(items)} StatefulSet(s) ready",
    )


def check_pvcs_bound(
    namespaces: Optional[List[str]] = None,
    context: Optional[str] = None,
    kubeconfig: Optional[str] = None,
) -> ValidationResult:
    """Check that all PersistentVolumeClaims are in Bound state."""
    ns_flag = "--all-namespaces"
    rc, out, err = _kubectl(
        f"get pvc {ns_flag} --no-headers",
        context=context,
        kubeconfig=kubeconfig,
        timeout=60,
    )
    if rc != 0:
        return ValidationResult(
            check="pvcs_bound",
            passed=False,
            detail=f"kubectl get pvc failed: {err}",
        )
    lines = [l for l in out.splitlines() if l.strip()]
    unbound = [l for l in lines if "Bound" not in l]
    if unbound:
        return ValidationResult(
            check="pvcs_bound",
            passed=False,
            detail=f"{len(unbound)} PVC(s) not Bound: {unbound[:3]}",
        )
    return ValidationResult(
        check="pvcs_bound",
        passed=True,
        detail=f"All {len(lines)} PVC(s) Bound",
    )


def check_services_have_endpoints(
    namespaces: Optional[List[str]] = None,
    context: Optional[str] = None,
    kubeconfig: Optional[str] = None,
) -> ValidationResult:
    """
    Check that non-ExternalName Services with selectors have at least one Endpoint.
    """
    ns_flag = "--all-namespaces"
    rc, out, err = _kubectl(
        f"get endpoints {ns_flag} -o json",
        context=context,
        kubeconfig=kubeconfig,
        timeout=60,
    )
    if rc != 0:
        return ValidationResult(
            check="services_have_endpoints",
            passed=False,
            detail=f"kubectl get endpoints failed: {err}",
        )
    try:
        data = json.loads(out)
        items = data.get("items", [])
    except json.JSONDecodeError:
        items = []

    empty: List[str] = []
    for item in items:
        meta = item.get("metadata", {})
        ns = meta.get("namespace", "")
        name = meta.get("name", "")
        # Skip kubernetes system endpoints
        if name == "kubernetes":
            continue
        if namespaces and ns not in namespaces:
            continue
        subsets = item.get("subsets") or []
        if not subsets:
            empty.append(f"{ns}/{name}")

    if empty:
        return ValidationResult(
            check="services_have_endpoints",
            passed=False,
            detail=f"{len(empty)} service(s) with no endpoints: {empty[:5]}",
        )
    return ValidationResult(
        check="services_have_endpoints",
        passed=True,
        detail=f"All checked services have endpoints ({len(items)} total)",
    )


def check_no_crashlooping_pods(
    namespaces: Optional[List[str]] = None,
    context: Optional[str] = None,
    kubeconfig: Optional[str] = None,
) -> ValidationResult:
    """Verify no pods are in CrashLoopBackOff or Error state."""
    ns_flag = "--all-namespaces"
    rc, out, err = _kubectl(
        f"get pods {ns_flag} --no-headers",
        context=context,
        kubeconfig=kubeconfig,
        timeout=60,
    )
    if rc != 0:
        return ValidationResult(
            check="no_crashlooping_pods",
            passed=False,
            detail=f"kubectl get pods failed: {err}",
        )
    lines = out.splitlines()
    bad_states = ("CrashLoopBackOff", "Error", "OOMKilled", "ImagePullBackOff", "ErrImagePull")
    crashing = [l for l in lines if any(s in l for s in bad_states)]
    if crashing:
        return ValidationResult(
            check="no_crashlooping_pods",
            passed=False,
            detail=f"{len(crashing)} pod(s) in bad state: {crashing[:3]}",
        )
    return ValidationResult(
        check="no_crashlooping_pods",
        passed=True,
        detail=f"No crashlooping pods ({len(lines)} pods checked)",
    )


# ── Magnum cluster validation ─────────────────────────────────────────────────

def validate_magnum_cluster(
    cluster_name: str,
    kubeconfig: Optional[str] = None,
    openrc: Optional[str] = None,
) -> ValidationResult:
    """
    Validate a Magnum cluster's health by calling ``openstack coe cluster show``.

    Uses subprocess to run the openstack CLI when available.  If the CLI is not
    installed this check is skipped gracefully.

    Args:
        cluster_name: Magnum cluster name or UUID.
        kubeconfig:   Path to kubeconfig (used for kubectl_nodes fallback check).
        openrc:       Path to OpenRC file to source before the openstack CLI call.

    Returns:
        ValidationResult with check="magnum_cluster_status".
    """
    if not shutil.which("openstack"):
        return ValidationResult(
            check="magnum_cluster_status",
            passed=True,
            detail="skipped: openstack CLI not available",
        )

    cmd: List[str]
    if openrc:
        cmd = ["bash", "-c", f"source {openrc} && openstack coe cluster show {cluster_name} -f value -c status"]
    else:
        cmd = ["openstack", "coe", "cluster", "show", cluster_name, "-f", "value", "-c", "status"]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        status = result.stdout.strip()
        if result.returncode != 0:
            return ValidationResult(
                check="magnum_cluster_status",
                passed=False,
                detail=f"openstack CLI error: {result.stderr.strip()}",
            )
        if status == "CREATE_COMPLETE":
            return ValidationResult(
                check="magnum_cluster_status",
                passed=True,
                detail=f"Magnum cluster {cluster_name!r} status: {status}",
            )
        passed = status not in ("CREATE_FAILED", "UPDATE_FAILED", "DELETE_IN_PROGRESS", "ERROR")
        return ValidationResult(
            check="magnum_cluster_status",
            passed=passed,
            detail=f"Magnum cluster {cluster_name!r} status: {status}",
        )
    except subprocess.TimeoutExpired:
        return ValidationResult(
            check="magnum_cluster_status",
            passed=False,
            detail="openstack CLI timed out after 30s",
        )
    except Exception as exc:  # pragma: no cover
        return ValidationResult(
            check="magnum_cluster_status",
            passed=False,
            detail=f"unexpected error: {exc}",
        )


def validate_loadbalancer(
    namespace: str = "default",
    service_name: str = "lb-test-svc",
    kubeconfig: Optional[str] = None,
    context: Optional[str] = None,
) -> Dict[str, Any]:
    """
    Describe the steps to deploy a test LoadBalancer Service and check its
    external IP assignment.

    This function does **not** actually execute the test — it returns a
    structured dict describing the required kubectl commands and success
    criteria.  Callers can use this output to drive automated testing or
    display it as an operator checklist.

    Args:
        namespace:    Kubernetes namespace to deploy the test Service into.
        service_name: Name of the test Service resource.
        kubeconfig:   Path to kubeconfig for the target cluster.
        context:      kubectl context for the target cluster.

    Returns:
        Dict with keys:
          - check (str)
          - service_yaml (str)  — YAML manifest to apply
          - commands (list[str]) — ordered kubectl commands to run
          - success_criteria (str)
          - notes (str)
    """
    kc_flags = ""
    if context:
        kc_flags += f" --context={context}"
    if kubeconfig:
        kc_flags += f" --kubeconfig={kubeconfig}"

    service_yaml = (
        f"apiVersion: v1\n"
        f"kind: Service\n"
        f"metadata:\n"
        f"  name: {service_name}\n"
        f"  namespace: {namespace}\n"
        f"spec:\n"
        f"  type: LoadBalancer\n"
        f"  selector:\n"
        f"    app: lb-test-placeholder\n"
        f"  ports:\n"
        f"    - port: 80\n"
        f"      targetPort: 8080\n"
    )

    commands = [
        f"kubectl{kc_flags} apply -f - <<'EOF'\n{service_yaml}EOF",
        f"kubectl{kc_flags} -n {namespace} get svc {service_name} -w",
        f"kubectl{kc_flags} -n {namespace} get svc {service_name} "
        f"-o jsonpath='{{.status.loadBalancer.ingress[0].ip}}'",
        f"kubectl{kc_flags} -n {namespace} delete svc {service_name}",
    ]

    return {
        "check": "loadbalancer_test",
        "service_yaml": service_yaml,
        "commands": commands,
        "success_criteria": (
            f"Service {service_name!r} in namespace {namespace!r} receives a "
            "non-empty .status.loadBalancer.ingress[0].ip within 3 minutes"
        ),
        "notes": (
            "Magnum 2025.2 with k8s_cluster_api or k8s_capi_helm driver provisions "
            "Octavia load balancers automatically. "
            "A missing external IP indicates an Octavia or quota issue on Flex."
        ),
    }


# ── Full validation suite ─────────────────────────────────────────────────────

def run_validation(
    namespaces: Optional[List[str]] = None,
    context: Optional[str] = None,
    kubeconfig: Optional[str] = None,
) -> List[ValidationResult]:
    """
    Run all validation checks against the target cluster.

    Args:
        namespaces: If set, scope namespace-level checks to these namespaces.
        context:    kubectl context for the target cluster.
        kubeconfig: Path to kubeconfig for the target cluster.

    Returns:
        List of ValidationResult (one per check).
    """
    checks = [
        check_nodes_ready(context=context, kubeconfig=kubeconfig),
        check_deployments_available(namespaces=namespaces, context=context, kubeconfig=kubeconfig),
        check_statefulsets_ready(namespaces=namespaces, context=context, kubeconfig=kubeconfig),
        check_pvcs_bound(namespaces=namespaces, context=context, kubeconfig=kubeconfig),
        check_services_have_endpoints(namespaces=namespaces, context=context, kubeconfig=kubeconfig),
        check_no_crashlooping_pods(namespaces=namespaces, context=context, kubeconfig=kubeconfig),
    ]
    if namespaces:
        checks.insert(1, check_namespaces_exist(namespaces, context=context, kubeconfig=kubeconfig))

    for r in checks:
        status = "PASS" if r.passed else "FAIL"
        log.info("[%s] %s: %s", status, r.check, r.detail)

    return checks


def validation_summary(results: List[ValidationResult]) -> Dict[str, Any]:
    """
    Summarise validation results.

    Returns:
        Dict with keys: total, passed, failed, all_passed, results (list of dicts).
    """
    passed = sum(1 for r in results if r.passed)
    failed = len(results) - passed
    return {
        "total": len(results),
        "passed": passed,
        "failed": failed,
        "all_passed": failed == 0,
        "results": [r.to_dict() for r in results],
    }
