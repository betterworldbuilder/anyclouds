"""
Data models for the OSPC → Flex Kubernetes migration tool.
All models use Python dataclasses for zero external dependency in this module.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Dict, List, Optional


# ── Stage / phase enums ───────────────────────────────────────────────────────

class MigrationStage(str, Enum):
    """Tracks the overall migration lifecycle state."""
    REHEARSAL           = "rehearsal"
    PRE_CUTOVER         = "pre-cutover"
    CUTOVER_STARTED     = "cutover-started"
    CUTOVER_COMPLETE    = "cutover-complete"
    ROLLBACK_TRIGGERED  = "rollback-triggered"
    ROLLBACK_COMPLETE   = "rollback-complete"


class RestorePhase(str, Enum):
    """Ordered restore phases — used by restore.py and planner.py."""
    CRDS         = "crds"
    NAMESPACES   = "namespaces"
    RBAC         = "rbac"
    CONFIGMAPS   = "configmaps"
    SECRETS      = "secrets"
    STORAGE      = "storage"
    SERVICES     = "services"
    DEPLOYMENTS  = "deployments"
    STATEFULSETS = "statefulsets"
    DAEMONSETS   = "daemonsets"
    INGRESSES    = "ingresses"
    POLICY       = "policy"
    HELM         = "helm"
    DATA         = "data"
    VALIDATION   = "validation"


# ── Mapping models ────────────────────────────────────────────────────────────

@dataclass
class StorageMapping:
    """Maps source StorageClass names to target StorageClass names."""
    old_to_new: Dict[str, str] = field(default_factory=dict)
    default: str = "cinder-standard"

    def translate(self, name: Optional[str]) -> str:
        if not name:
            return self.default
        return self.old_to_new.get(name, self.default)


@dataclass
class IngressMapping:
    """Maps source ingress class annotations to target."""
    old_to_new: Dict[str, str] = field(default_factory=dict)
    default: str = "nginx"

    def translate(self, name: Optional[str]) -> str:
        if not name:
            return self.default
        return self.old_to_new.get(name, self.default)


@dataclass
class EndpointReplacement:
    """A single old→new hostname/endpoint substitution."""
    old: str
    new: str


# ── Migration plan ────────────────────────────────────────────────────────────

@dataclass
class MigrationPlan:
    """
    Parsed representation of migration-plan.yaml.
    Controls which namespaces, resource kinds, and fields are included/excluded.
    """
    include_namespaces: List[str] = field(default_factory=list)
    exclude_namespaces: List[str] = field(default_factory=lambda: [
        "kube-system", "kube-public", "kube-node-lease"
    ])
    exclude_kinds: List[str] = field(default_factory=lambda: ["Event", "Lease"])
    strip_fields: List[str] = field(default_factory=lambda: [
        "metadata.uid",
        "metadata.resourceVersion",
        "metadata.generation",
        "metadata.creationTimestamp",
        "metadata.managedFields",
        "status",
    ])
    remove_node_selectors: bool = True
    remove_affinity: bool = False
    remove_tolerations: bool = False
    storage_mapping: StorageMapping = field(default_factory=StorageMapping)
    ingress_mapping: IngressMapping = field(default_factory=IngressMapping)
    endpoint_replacements: List[EndpointReplacement] = field(default_factory=list)
    exclude_secret_names: List[str] = field(default_factory=list)


# ── Export models ─────────────────────────────────────────────────────────────

@dataclass
class ExportConfig:
    """Configuration for Stage 1 remote-master export."""
    ospc_master_ip: str
    ssh_user: str
    ssh_key_path: str
    output_dir: str
    keep_remote_export: bool = False
    remote_temp_base: str = "/tmp"
    ssh_port: int = 22
    ssh_timeout: int = 30
    kubectl_timeout: int = 300


@dataclass
class HelmRelease:
    """Metadata for a single Helm release discovered on the source cluster."""
    name: str
    namespace: str
    chart: str
    chart_version: str
    app_version: str
    status: str
    values_yaml: str = ""
    manifest_yaml: str = ""


@dataclass
class ResourceItem:
    """A single exported Kubernetes resource."""
    kind: str
    name: str
    namespace: Optional[str]
    api_version: str
    raw_yaml: str
    warnings: List[str] = field(default_factory=list)


@dataclass
class ClusterInventory:
    """High-level inventory of what was discovered on the source cluster."""
    context: str
    server: str
    kubernetes_version: str
    node_count: int
    namespace_count: int
    resource_counts: Dict[str, int] = field(default_factory=dict)
    helm_release_count: int = 0
    image_list: List[str] = field(default_factory=list)
    warnings: List[str] = field(default_factory=list)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "context": self.context,
            "server": self.server,
            "kubernetes_version": self.kubernetes_version,
            "node_count": self.node_count,
            "namespace_count": self.namespace_count,
            "resource_counts": self.resource_counts,
            "helm_release_count": self.helm_release_count,
            "image_count": len(self.image_list),
            "warnings": self.warnings,
        }


# ── Transform models ──────────────────────────────────────────────────────────

@dataclass
class TransformReport:
    """Summary produced by the transformer."""
    total_input: int = 0
    total_output: int = 0
    skipped: int = 0
    warnings: List[str] = field(default_factory=list)
    storage_remaps: List[str] = field(default_factory=list)
    ingress_remaps: List[str] = field(default_factory=list)
    endpoint_replacements: List[str] = field(default_factory=list)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "total_input": self.total_input,
            "total_output": self.total_output,
            "skipped": self.skipped,
            "warnings": self.warnings,
            "storage_remaps": self.storage_remaps,
            "ingress_remaps": self.ingress_remaps,
            "endpoint_replacements": self.endpoint_replacements,
        }


# ── Restore models ────────────────────────────────────────────────────────────

@dataclass
class ApplyResult:
    """Result of applying a single manifest file."""
    file: str
    success: bool
    output: str
    error: str = ""
    dry_run: bool = False


# ── Validation models ─────────────────────────────────────────────────────────

@dataclass
class ValidationResult:
    """Outcome of a single validation check."""
    check: str
    passed: bool
    detail: str = ""

    def to_dict(self) -> Dict[str, Any]:
        return {"check": self.check, "passed": self.passed, "detail": self.detail}


# ── Cutover / rollback models ─────────────────────────────────────────────────

@dataclass
class CutoverChecklist:
    """Generated cutover checklist for a migration run."""
    run_id: str
    stage: MigrationStage
    source_cluster: str
    target_cluster: str
    generated_at: str
    pre_cutover_checks: List[str] = field(default_factory=list)
    dns_switch_steps: List[str] = field(default_factory=list)
    maintenance_mode_steps: List[str] = field(default_factory=list)
    final_sync_commands: List[str] = field(default_factory=list)
    post_cutover_checks: List[str] = field(default_factory=list)
    notes: List[str] = field(default_factory=list)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "run_id": self.run_id,
            "stage": self.stage.value,
            "source_cluster": self.source_cluster,
            "target_cluster": self.target_cluster,
            "generated_at": self.generated_at,
            "pre_cutover_checks": self.pre_cutover_checks,
            "dns_switch_steps": self.dns_switch_steps,
            "maintenance_mode_steps": self.maintenance_mode_steps,
            "final_sync_commands": self.final_sync_commands,
            "post_cutover_checks": self.post_cutover_checks,
            "notes": self.notes,
        }


@dataclass
class RollbackPlan:
    """Generated rollback plan for a migration run."""
    run_id: str
    stage: MigrationStage
    source_context: str
    target_context: str
    cutover_timestamp: Optional[str]
    notes: List[str] = field(default_factory=list)
    pre_rollback_checks: List[str] = field(default_factory=list)
    rollback_commands: List[str] = field(default_factory=list)
    validation_checks: List[str] = field(default_factory=list)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "run_id": self.run_id,
            "stage": self.stage.value,
            "source_context": self.source_context,
            "target_context": self.target_context,
            "cutover_timestamp": self.cutover_timestamp,
            "notes": self.notes,
            "pre_rollback_checks": self.pre_rollback_checks,
            "rollback_commands": self.rollback_commands,
            "validation_checks": self.validation_checks,
        }


@dataclass
class MigrationState:
    """Persisted migration state file — written to output/<run_id>/state.json."""
    run_id: str
    stage: MigrationStage
    source_master_ip: str
    target_cluster_name: str
    export_dir: str
    transform_dir: str
    restore_dir: str
    cutover_timestamp: Optional[str] = None
    rollback_timestamp: Optional[str] = None
    notes: List[str] = field(default_factory=list)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "run_id": self.run_id,
            "stage": self.stage.value,
            "source_master_ip": self.source_master_ip,
            "target_cluster_name": self.target_cluster_name,
            "export_dir": self.export_dir,
            "transform_dir": self.transform_dir,
            "restore_dir": self.restore_dir,
            "cutover_timestamp": self.cutover_timestamp,
            "rollback_timestamp": self.rollback_timestamp,
            "notes": self.notes,
        }
