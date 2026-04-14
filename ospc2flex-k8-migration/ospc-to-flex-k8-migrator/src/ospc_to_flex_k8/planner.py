"""
Planner: migration plan loading and restore phase ordering.

Loads migration-plan.yaml and constructs a MigrationPlan dataclass.
Also provides restore phase ordering utilities.
"""
from __future__ import annotations

import logging
from pathlib import Path
from typing import Any, Dict, List, Optional, Union

from .io_utils import load_yaml
from .models import (
    EndpointReplacement,
    IngressMapping,
    MigrationPlan,
    RestorePhase,
    StorageMapping,
)

log = logging.getLogger(__name__)


# ── Stage checkpoint constants ────────────────────────────────────────────────

# Stage 2: Design and validate Flex Magnum ClusterTemplate
STAGE_2_DESIGN_CHECKPOINTS: List[str] = [
    "cluster_template_exists",
    "coe_is_kubernetes",
    "image_validated",
    "image_os_distro_compatible",
    "external_network_present",
    "network_driver_selected",
    "volume_driver_selected",
    "keypair_present",
    "master_lb_decision_recorded",
    "flavor_decision_recorded",
]

# Stage 7: Test and validate
STAGE_7_VALIDATION_CHECKPOINTS: List[str] = [
    "magnum_cluster_status_collected",
    "loadbalancer_test_deployed",
    "loadbalancer_result_recorded",
    "node_group_awareness_recorded",
]

# Canonical 9-stage migration model
MIGRATION_STAGES: List[str] = [
    "stage1_export",
    "stage2_design_template",
    "stage3_create_cluster",
    "stage4_transform",
    "stage5_restore_apps",
    "stage6_restore_data",
    "stage7_test_validate",
    "stage8_cutover",
    "stage9_rollback",
]


# ── Plan file loader ──────────────────────────────────────────────────────────

def load_plan(plan_file: Union[str, Path]) -> MigrationPlan:
    """
    Parse a migration-plan.yaml file and return a MigrationPlan.

    The YAML structure mirrors the MigrationPlan dataclass fields.
    Missing keys use dataclass defaults; unknown keys are ignored with a warning.

    Example migration-plan.yaml::

        include_namespaces: []
        exclude_namespaces:
          - kube-system
          - kube-public
          - kube-node-lease
        exclude_kinds:
          - Event
          - Lease
        strip_fields:
          - metadata.uid
          - metadata.resourceVersion
          - metadata.generation
          - metadata.creationTimestamp
          - metadata.managedFields
          - status
        remove_node_selectors: true
        remove_affinity: false
        remove_tolerations: false
        storage_mapping:
          default: cinder-standard
          mappings:
            local-path: cinder-standard
            nfs-client: cinder-nfs
        ingress_mapping:
          default: nginx
          mappings:
            traefik: nginx
        endpoint_replacements:
          - old: old-cluster.internal
            new: new-cluster.internal
        exclude_secret_names:
          - my-tls-cert

    Args:
        plan_file: Path to the migration-plan.yaml file.

    Returns:
        Populated MigrationPlan instance.

    Raises:
        FileNotFoundError: If plan_file does not exist.
        ValueError: If required fields have invalid types.
    """
    path = Path(plan_file)
    if not path.exists():
        raise FileNotFoundError(f"Migration plan not found: {path}")

    raw: Dict[str, Any] = load_yaml(path)
    if not isinstance(raw, dict):
        raise ValueError(f"Migration plan must be a YAML mapping, got: {type(raw)}")

    plan = MigrationPlan()

    # Namespace filters
    if "include_namespaces" in raw:
        plan.include_namespaces = list(raw["include_namespaces"] or [])
    if "exclude_namespaces" in raw:
        plan.exclude_namespaces = list(raw["exclude_namespaces"] or [])

    # Kind and field filters
    if "exclude_kinds" in raw:
        plan.exclude_kinds = list(raw["exclude_kinds"] or [])
    if "strip_fields" in raw:
        plan.strip_fields = list(raw["strip_fields"] or [])

    # Scheduling flags
    if "remove_node_selectors" in raw:
        plan.remove_node_selectors = bool(raw["remove_node_selectors"])
    if "remove_affinity" in raw:
        plan.remove_affinity = bool(raw["remove_affinity"])
    if "remove_tolerations" in raw:
        plan.remove_tolerations = bool(raw["remove_tolerations"])

    # Storage mapping
    sm_raw = raw.get("storage_mapping") or {}
    if isinstance(sm_raw, dict):
        plan.storage_mapping = StorageMapping(
            old_to_new=dict(sm_raw.get("mappings") or {}),
            default=str(sm_raw.get("default", "cinder-standard")),
        )
    elif sm_raw:
        log.warning("storage_mapping must be a dict; using defaults")

    # Ingress mapping
    im_raw = raw.get("ingress_mapping") or {}
    if isinstance(im_raw, dict):
        plan.ingress_mapping = IngressMapping(
            old_to_new=dict(im_raw.get("mappings") or {}),
            default=str(im_raw.get("default", "nginx")),
        )
    elif im_raw:
        log.warning("ingress_mapping must be a dict; using defaults")

    # Endpoint replacements
    ep_raw = raw.get("endpoint_replacements") or []
    replacements: List[EndpointReplacement] = []
    for item in ep_raw:
        if isinstance(item, dict) and "old" in item and "new" in item:
            replacements.append(EndpointReplacement(old=str(item["old"]), new=str(item["new"])))
        else:
            log.warning("Ignoring invalid endpoint_replacement entry: %s", item)
    plan.endpoint_replacements = replacements

    # Secret exclusions
    if "exclude_secret_names" in raw:
        plan.exclude_secret_names = list(raw["exclude_secret_names"] or [])

    log.info(
        "Plan loaded from %s: %d namespaces included, %d excluded, "
        "%d exclude_kinds, %d storage maps, %d endpoint replacements",
        path,
        len(plan.include_namespaces),
        len(plan.exclude_namespaces),
        len(plan.exclude_kinds),
        len(plan.storage_mapping.old_to_new),
        len(plan.endpoint_replacements),
    )
    return plan


# ── Default plan factory ──────────────────────────────────────────────────────

def default_plan() -> MigrationPlan:
    """Return a MigrationPlan populated with sensible defaults only."""
    return MigrationPlan()


# ── Restore phase ordering ────────────────────────────────────────────────────

# Restore phase order (Stage 5): crd → namespace → rbac → configmap → secret →
# storage → service → deployment → statefulset → daemonset → ingress → policy →
# helm → data → validation

# Maps RestorePhase to a set of Kubernetes resource kinds that belong to it.
_PHASE_KINDS: Dict[RestorePhase, List[str]] = {
    RestorePhase.CRDS:         ["CustomResourceDefinition"],
    RestorePhase.NAMESPACES:   ["Namespace"],
    RestorePhase.RBAC:         ["ServiceAccount", "Role", "ClusterRole",
                                 "RoleBinding", "ClusterRoleBinding"],
    RestorePhase.CONFIGMAPS:   ["ConfigMap"],
    RestorePhase.SECRETS:      ["Secret"],
    RestorePhase.STORAGE:      ["StorageClass", "PersistentVolume",
                                 "PersistentVolumeClaim"],
    RestorePhase.SERVICES:     ["Service", "Endpoints", "EndpointSlice"],
    RestorePhase.DEPLOYMENTS:  ["Deployment", "ReplicaSet"],
    RestorePhase.STATEFULSETS: ["StatefulSet"],
    RestorePhase.DAEMONSETS:   ["DaemonSet"],
    RestorePhase.INGRESSES:    ["Ingress", "IngressClass", "NetworkPolicy"],
    RestorePhase.POLICY:       ["PodDisruptionBudget", "HorizontalPodAutoscaler",
                                 "ResourceQuota", "LimitRange"],
    RestorePhase.HELM:         [],   # handled separately by restore.py
    RestorePhase.DATA:         [],   # handled separately (PV data sync)
    RestorePhase.VALIDATION:   [],   # no manifests; run checks
}

# Reverse lookup: kind → phase
_KIND_TO_PHASE: Dict[str, RestorePhase] = {
    kind: phase
    for phase, kinds in _PHASE_KINDS.items()
    for kind in kinds
}


def phase_for_kind(kind: str) -> RestorePhase:
    """
    Return the RestorePhase for a Kubernetes resource kind.

    Kinds not mapped explicitly are assigned RestorePhase.DEPLOYMENTS
    (a reasonable default for custom resources).
    """
    return _KIND_TO_PHASE.get(kind, RestorePhase.DEPLOYMENTS)


def ordered_restore_phases() -> List[RestorePhase]:
    """Return the list of RestorePhase values in the order they should be executed."""
    return list(RestorePhase)


def group_manifests_by_phase(
    manifests: List[Dict[str, Any]],
) -> Dict[RestorePhase, List[Dict[str, Any]]]:
    """
    Group a flat list of manifest dicts into a dict keyed by RestorePhase.

    Keys are present only for phases that have at least one manifest.
    The dict is ordered by phase execution order.
    """
    from .manifests import get_kind as _get_kind

    grouped: Dict[RestorePhase, List[Dict[str, Any]]] = {}
    for m in manifests:
        phase = phase_for_kind(_get_kind(m))
        grouped.setdefault(phase, []).append(m)

    # Return in execution order, skipping empty phases
    return {
        phase: grouped[phase]
        for phase in ordered_restore_phases()
        if phase in grouped
    }
