"""
Kubernetes manifest manipulation helpers.

All functions operate on plain dicts (as loaded by load_yaml / load_yaml_multidoc).
No external Kubernetes client library is required.
"""
from __future__ import annotations

import re
from typing import Any, Dict, List, Optional

# ── Restore priority order for resource kinds ─────────────────────────────────
# Lower index = restored first.
_KIND_ORDER: List[str] = [
    "CustomResourceDefinition",
    "Namespace",
    "ClusterRole",
    "ClusterRoleBinding",
    "Role",
    "RoleBinding",
    "ServiceAccount",
    "ConfigMap",
    "Secret",
    "PersistentVolume",
    "PersistentVolumeClaim",
    "StorageClass",
    "Service",
    "Endpoints",
    "Ingress",
    "NetworkPolicy",
    "PodDisruptionBudget",
    "HorizontalPodAutoscaler",
    "Deployment",
    "StatefulSet",
    "DaemonSet",
    "Job",
    "CronJob",
]

_KIND_PRIORITY: Dict[str, int] = {k: i for i, k in enumerate(_KIND_ORDER)}
_DEFAULT_PRIORITY = len(_KIND_ORDER)


# ── Field-path helpers ────────────────────────────────────────────────────────

def _del_nested(obj: Dict[str, Any], dotted_path: str) -> None:
    """Delete a dot-separated key path from a nested dict (no-op if missing)."""
    parts = dotted_path.split(".", 1)
    if len(parts) == 1:
        obj.pop(parts[0], None)
        return
    child = obj.get(parts[0])
    if isinstance(child, dict):
        _del_nested(child, parts[1])


# ── Core accessors ────────────────────────────────────────────────────────────

def get_kind(manifest: Dict[str, Any]) -> str:
    """Return the resource kind string, or '' if absent."""
    return str(manifest.get("kind", ""))


def get_api_version(manifest: Dict[str, Any]) -> str:
    """Return the apiVersion string, or '' if absent."""
    return str(manifest.get("apiVersion", ""))


def get_name(manifest: Dict[str, Any]) -> str:
    """Return metadata.name, or '' if absent."""
    return str((manifest.get("metadata") or {}).get("name", ""))


def get_namespace(manifest: Dict[str, Any]) -> Optional[str]:
    """Return metadata.namespace, or None for cluster-scoped resources."""
    ns = (manifest.get("metadata") or {}).get("namespace")
    return str(ns) if ns else None


# ── Runtime-field stripping ───────────────────────────────────────────────────

def strip_runtime_fields(
    manifest: Dict[str, Any],
    extra_fields: Optional[List[str]] = None,
) -> Dict[str, Any]:
    """
    Remove runtime/server-managed fields that must not be applied to a new cluster.

    Default fields removed:
        metadata.uid, metadata.resourceVersion, metadata.generation,
        metadata.creationTimestamp, metadata.managedFields, status

    Args:
        manifest:     A mutable manifest dict (modified in-place AND returned).
        extra_fields: Additional dot-separated field paths to remove.

    Returns:
        The same dict (mutated in-place) for chaining convenience.
    """
    defaults = [
        "metadata.uid",
        "metadata.resourceVersion",
        "metadata.generation",
        "metadata.creationTimestamp",
        "metadata.managedFields",
        "status",
    ]
    for path in defaults + (extra_fields or []):
        _del_nested(manifest, path)

    # Normalise creationTimestamp: pyyaml sometimes leaves it as None
    meta = manifest.get("metadata")
    if isinstance(meta, dict) and "creationTimestamp" in meta:
        del meta["creationTimestamp"]

    return manifest


# ── StorageClass helpers ──────────────────────────────────────────────────────

def get_storage_class(manifest: Dict[str, Any]) -> Optional[str]:
    """
    Return the storageClassName for a PVC or PV manifest, or None.

    Checks:
        spec.storageClassName  (PVC and PV)
        spec.storageClass      (some legacy formats)
    """
    spec = manifest.get("spec") or {}
    sc = spec.get("storageClassName") or spec.get("storageClass")
    return str(sc) if sc else None


def set_storage_class(manifest: Dict[str, Any], new_class: str) -> None:
    """
    Set storageClassName on a PVC or PV manifest.

    Ensures spec dict exists before writing.
    """
    if "spec" not in manifest or not isinstance(manifest["spec"], dict):
        manifest["spec"] = {}
    manifest["spec"]["storageClassName"] = new_class


# ── Ingress class helpers ─────────────────────────────────────────────────────

_INGRESS_CLASS_ANNOTATION = "kubernetes.io/ingress.class"
_INGRESS_CLASS_FIELD = "ingressClassName"  # networking.k8s.io/v1 Ingress


def get_ingress_class(manifest: Dict[str, Any]) -> Optional[str]:
    """
    Return the ingress class for an Ingress manifest, or None.

    Checks (in order):
        spec.ingressClassName
        metadata.annotations["kubernetes.io/ingress.class"]
    """
    spec = manifest.get("spec") or {}
    cls = spec.get(_INGRESS_CLASS_FIELD)
    if cls:
        return str(cls)
    annotations = (manifest.get("metadata") or {}).get("annotations") or {}
    cls = annotations.get(_INGRESS_CLASS_ANNOTATION)
    return str(cls) if cls else None


def set_ingress_class(manifest: Dict[str, Any], new_class: str) -> None:
    """
    Set the ingress class on an Ingress manifest.

    Writes to both spec.ingressClassName and the legacy annotation for maximum
    compatibility across Kubernetes versions.
    """
    if "spec" not in manifest or not isinstance(manifest["spec"], dict):
        manifest["spec"] = {}
    manifest["spec"][_INGRESS_CLASS_FIELD] = new_class

    meta = manifest.setdefault("metadata", {})
    if not isinstance(meta, dict):
        manifest["metadata"] = {}
        meta = manifest["metadata"]
    annotations = meta.setdefault("annotations", {})
    if not isinstance(annotations, dict):
        meta["annotations"] = {}
        annotations = meta["annotations"]
    annotations[_INGRESS_CLASS_ANNOTATION] = new_class


# ── Scheduling-field removers ─────────────────────────────────────────────────

def _get_pod_spec(manifest: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """Return the podSpec dict for Deployment/StatefulSet/DaemonSet/Pod, or None."""
    kind = get_kind(manifest)
    spec = manifest.get("spec") or {}

    if kind == "Pod":
        return spec if isinstance(spec, dict) else None

    # Deployment, StatefulSet, DaemonSet, Job, CronJob
    template = spec.get("template") or {}
    pod_spec = template.get("spec") or {}
    if pod_spec and isinstance(pod_spec, dict):
        return pod_spec

    # CronJob has an extra nesting level
    job_template = spec.get("jobTemplate") or {}
    job_spec = job_template.get("spec") or {}
    template2 = job_spec.get("template") or {}
    pod_spec2 = template2.get("spec") or {}
    return pod_spec2 if isinstance(pod_spec2, dict) else None


def remove_node_selectors(manifest: Dict[str, Any]) -> bool:
    """
    Remove spec.nodeSelector from a workload manifest.

    Returns True if a nodeSelector was removed, False otherwise.
    """
    pod_spec = _get_pod_spec(manifest)
    if pod_spec and "nodeSelector" in pod_spec:
        del pod_spec["nodeSelector"]
        return True
    return False


def remove_affinity(manifest: Dict[str, Any]) -> bool:
    """
    Remove spec.affinity from a workload manifest.

    Returns True if affinity was removed, False otherwise.
    """
    pod_spec = _get_pod_spec(manifest)
    if pod_spec and "affinity" in pod_spec:
        del pod_spec["affinity"]
        return True
    return False


def remove_tolerations(manifest: Dict[str, Any]) -> bool:
    """
    Remove spec.tolerations from a workload manifest.

    Returns True if tolerations were removed, False otherwise.
    """
    pod_spec = _get_pod_spec(manifest)
    if pod_spec and "tolerations" in pod_spec:
        del pod_spec["tolerations"]
        return True
    return False


# ── Endpoint replacement ──────────────────────────────────────────────────────

def _replace_in_value(value: Any, old: str, new: str) -> Tuple_[Any, int]:
    """Recursively replace ``old`` with ``new`` in strings within a nested structure.

    Returns (mutated_value, replacement_count).
    """
    # Import here to avoid circular import at module load
    count = 0
    if isinstance(value, str):
        if old in value:
            count = value.count(old)
            value = value.replace(old, new)
    elif isinstance(value, dict):
        for k in list(value.keys()):
            value[k], c = _replace_in_value(value[k], old, new)
            count += c
    elif isinstance(value, list):
        for i, item in enumerate(value):
            value[i], c = _replace_in_value(item, old, new)
            count += c
    return value, count


# Python 3.9+ Tuple syntax, but we keep compat via __future__ annotations
from typing import Tuple as Tuple_  # noqa: E402 (late import for clarity)


def replace_endpoints(
    manifest: Dict[str, Any],
    replacements: List[tuple],  # List[Tuple[str, str]]
) -> int:
    """
    Apply a list of (old, new) string replacements throughout a manifest.

    Replacement is recursive: hits strings inside dicts, lists, and nested
    structures (ConfigMap data, env var values, ingress host rules, etc.).

    Args:
        manifest:     Manifest dict (mutated in-place).
        replacements: List of (old_str, new_str) tuples.

    Returns:
        Total number of substitutions made across all (old, new) pairs.
    """
    total = 0
    for old, new in replacements:
        _, count = _replace_in_value(manifest, old, new)
        total += count
    return total


# ── Kind categorisation ───────────────────────────────────────────────────────

_WORKLOAD_KINDS = frozenset({
    "Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob", "Pod",
    "ReplicaSet", "ReplicationController",
})
_STORAGE_KINDS = frozenset({
    "PersistentVolume", "PersistentVolumeClaim", "StorageClass",
    "VolumeSnapshot", "VolumeSnapshotClass",
})
_NETWORK_KINDS = frozenset({
    "Service", "Endpoints", "Ingress", "IngressClass", "NetworkPolicy",
    "EndpointSlice",
})
_RBAC_KINDS = frozenset({
    "ServiceAccount", "Role", "ClusterRole", "RoleBinding", "ClusterRoleBinding",
})
_CONFIG_KINDS = frozenset({"ConfigMap", "Secret"})
_NAMESPACE_KINDS = frozenset({"Namespace"})
_CRD_KINDS = frozenset({"CustomResourceDefinition"})
_POLICY_KINDS = frozenset({"PodDisruptionBudget", "HorizontalPodAutoscaler",
                            "PodSecurityPolicy", "LimitRange", "ResourceQuota"})


def categorize_kind(kind: str) -> str:
    """
    Return a broad category string for a Kubernetes resource kind.

    Categories: 'workload', 'storage', 'network', 'rbac', 'config',
                'namespace', 'crd', 'policy', 'other'
    """
    if kind in _WORKLOAD_KINDS:
        return "workload"
    if kind in _STORAGE_KINDS:
        return "storage"
    if kind in _NETWORK_KINDS:
        return "network"
    if kind in _RBAC_KINDS:
        return "rbac"
    if kind in _CONFIG_KINDS:
        return "config"
    if kind in _NAMESPACE_KINDS:
        return "namespace"
    if kind in _CRD_KINDS:
        return "crd"
    if kind in _POLICY_KINDS:
        return "policy"
    return "other"


def restore_priority(kind: str) -> int:
    """
    Return an integer restore priority for a resource kind.

    Lower value = restored first (Namespaces < CRDs < RBAC < … < Workloads).
    Unknown kinds get the highest (last) priority.
    """
    return _KIND_PRIORITY.get(kind, _DEFAULT_PRIORITY)


def sort_manifests_for_restore(
    manifests: List[Dict[str, Any]],
) -> List[Dict[str, Any]]:
    """
    Return a new list of manifests sorted into the correct restore order.

    Sort is stable: manifests of the same kind preserve their original order.
    """
    return sorted(manifests, key=lambda m: restore_priority(get_kind(m)))
