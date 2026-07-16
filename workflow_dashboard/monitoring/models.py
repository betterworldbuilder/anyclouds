"""Typed context and snapshot models for OpenCenter monitoring."""
from __future__ import annotations

import re
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Any, Dict, List, Optional

NAME_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")


def valid_name(value: str) -> bool:
    """Same org/cluster naming rule the rest of the dashboard enforces."""
    return bool(NAME_RE.fullmatch(str(value or "")))


class MonitoringError(Exception):
    """Structured monitoring failure that maps to an HTTP error response."""

    def __init__(self, message: str, status: int = 400):
        super().__init__(message)
        self.status = status


@dataclass
class MonitoringContext:
    """Resolved, validated paths and metadata for one org/cluster pair.

    All filesystem paths are derived server-side from validated names; nothing
    from the request is used as a raw path component.
    """

    org: str
    cluster: str
    provider: str = ""
    region: str = ""
    config_root: Path = field(default_factory=lambda: Path.home() / ".config" / "opencenter")
    state_root: Path = field(default_factory=lambda: Path.home() / ".local" / "state" / "opencenter")

    @classmethod
    def resolve(cls, org: str, cluster: str) -> "MonitoringContext":
        org = str(org or "").strip().lower()
        cluster = str(cluster or "").strip().lower()
        if not valid_name(org) or not valid_name(cluster):
            raise MonitoringError("Invalid organization or cluster name", 400)
        ctx = cls(org=org, cluster=cluster)
        if not ctx.blueprint_path.is_file():
            raise MonitoringError(
                "Unknown cluster %s/%s (no blueprint found)" % (org, cluster), 404
            )
        cloud = ctx.blueprint_cloud()
        ctx.provider = str(ctx.blueprint().get("opencenter", {}).get("infrastructure", {}).get("provider") or "")
        ctx.region = str(cloud.get("region") or "")
        return ctx

    # --- paths -----------------------------------------------------------
    @property
    def blueprint_path(self) -> Path:
        return (
            self.config_root / "clusters" / "blueprints" / self.org / self.cluster
            / ("%s-config.yaml" % self.cluster)
        )

    @property
    def gitops_dir(self) -> Path:
        return self.config_root / "clusters" / "gitops" / self.org

    @property
    def infra_dir(self) -> Path:
        return self.gitops_dir / "infrastructure" / "clusters" / self.cluster

    @property
    def kubeconfig_path(self) -> Path:
        return self.infra_dir / "kubeconfig.yaml"

    @property
    def bootstrap_log_dir(self) -> Path:
        return self.state_root / "logs" / "bootstrap" / self.org / self.cluster

    def kubeconfig_available(self) -> bool:
        try:
            return self.kubeconfig_path.is_file() and self.kubeconfig_path.stat().st_size > 0
        except OSError:
            return False

    # --- blueprint access --------------------------------------------------
    _blueprint_cache: Optional[Dict[str, Any]] = None

    def blueprint(self) -> Dict[str, Any]:
        if self._blueprint_cache is None:
            import yaml

            try:
                self._blueprint_cache = yaml.safe_load(self.blueprint_path.read_text(encoding="utf-8")) or {}
            except Exception:
                self._blueprint_cache = {}
        return self._blueprint_cache

    def blueprint_cloud(self) -> Dict[str, Any]:
        return (
            ((self.blueprint().get("opencenter") or {}).get("infrastructure") or {})
            .get("cloud", {})
            .get("openstack", {})
            or {}
        )

    def is_openstack(self) -> bool:
        return (self.provider or "").lower() == "openstack"


@dataclass
class StageStatus:
    id: str
    title: str
    status: str = "pending"  # pending|running|passed|warning|failed
    started_at: Optional[str] = None
    duration_seconds: Optional[float] = None
    message: str = ""
    evidence: List[str] = field(default_factory=list)
    recommendation: str = ""


@dataclass
class DeploymentSnapshot:
    org: str = ""
    cluster: str = ""
    provider: str = ""
    region: str = ""
    deployment_status: str = "IDLE"  # IDLE|RUNNING|WAITING|SUCCEEDED|FAILED|BLOCKED
    current_stage: str = ""
    current_substage: str = ""
    start_time: str = ""
    elapsed_seconds: float = 0.0
    deployment_pid: Optional[int] = None
    duplicate_pids: List[int] = field(default_factory=list)
    lock_owner: str = ""
    latest_log: str = ""
    completed_steps: List[str] = field(default_factory=list)
    active_step: str = ""
    failed_step: str = ""
    warnings: List[str] = field(default_factory=list)
    errors: List[Dict[str, Any]] = field(default_factory=list)
    stages: List[Dict[str, Any]] = field(default_factory=list)
    gitops_status: Dict[str, Any] = field(default_factory=dict)
    infrastructure_status: Dict[str, Any] = field(default_factory=dict)
    cloud_init_status: Dict[str, Any] = field(default_factory=dict)
    kubespray_status: Dict[str, Any] = field(default_factory=dict)
    kubernetes_status: Dict[str, Any] = field(default_factory=dict)
    flux_status: Dict[str, Any] = field(default_factory=dict)
    generated_at: str = ""

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


@dataclass
class ClusterHealthSnapshot:
    org: str = ""
    cluster: str = ""
    provider: str = ""
    region: str = ""
    available: bool = False
    reason: str = ""
    nodes: List[Dict[str, Any]] = field(default_factory=list)
    control_plane: Dict[str, Any] = field(default_factory=dict)
    workers: Dict[str, Any] = field(default_factory=dict)
    pods: Dict[str, Any] = field(default_factory=dict)
    namespaces: List[str] = field(default_factory=list)
    services: List[Dict[str, Any]] = field(default_factory=list)
    gateways: List[Dict[str, Any]] = field(default_factory=list)
    certificates: List[Dict[str, Any]] = field(default_factory=list)
    pvcs: List[Dict[str, Any]] = field(default_factory=list)
    storage_classes: List[Dict[str, Any]] = field(default_factory=list)
    flux_sources: List[Dict[str, Any]] = field(default_factory=list)
    flux_kustomizations: List[Dict[str, Any]] = field(default_factory=list)
    helm_releases: List[Dict[str, Any]] = field(default_factory=list)
    platform_services: List[Dict[str, Any]] = field(default_factory=list)
    recent_events: List[Dict[str, Any]] = field(default_factory=list)
    infrastructure: Dict[str, Any] = field(default_factory=dict)
    quotas: Dict[str, Any] = field(default_factory=dict)
    security_groups: List[Dict[str, Any]] = field(default_factory=list)
    floating_ips: List[Dict[str, Any]] = field(default_factory=list)
    health_score: int = 0
    active_alerts: List[Dict[str, Any]] = field(default_factory=list)
    generated_at: str = ""

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)
