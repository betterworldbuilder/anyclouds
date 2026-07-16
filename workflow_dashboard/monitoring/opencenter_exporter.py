"""Prometheus exporter for OpenCenter deployment and cluster state.

Design rules:
- A scrape never triggers expensive kubectl/OpenStack commands. Deployment
  metrics come from cheap local sources (log files, git, process table) via
  the shared TTL cache. Cluster metrics are exported from cache only; set
  OPENCENTER_EXPORTER_ACTIVE=1 to run a background refresher that keeps the
  cache warm for clusters whose kubeconfig exists.
- No secrets, tokens, log lines or high-cardinality values in labels.
"""
from __future__ import annotations

import os
import re
import threading
import time
from pathlib import Path
from typing import Dict, List, Tuple

from .cache import CACHE
from .models import MonitoringContext, valid_name

_LABEL_SAFE = re.compile(r"[^a-zA-Z0-9_.:/-]")
_BG_STARTED = False
_BG_LOCK = threading.Lock()


def _esc(value: str) -> str:
    return _LABEL_SAFE.sub("_", str(value or ""))[:80]


def _line(name: str, labels: Dict[str, str], value) -> str:
    label_str = ",".join('%s="%s"' % (k, _esc(v)) for k, v in sorted(labels.items()))
    return "%s{%s} %s" % (name, label_str, value)


def known_pairs() -> List[Tuple[str, str]]:
    root = Path.home() / ".config" / "opencenter" / "clusters" / "blueprints"
    pairs = []
    if root.is_dir():
        for org_dir in sorted(root.iterdir()):
            if not org_dir.is_dir() or not valid_name(org_dir.name):
                continue
            for cluster_dir in sorted(org_dir.iterdir()):
                if cluster_dir.is_dir() and valid_name(cluster_dir.name) and \
                        (cluster_dir / ("%s-config.yaml" % cluster_dir.name)).is_file():
                    pairs.append((org_dir.name, cluster_dir.name))
    return pairs


_STATUS_VALUES = ("IDLE", "RUNNING", "WAITING", "SUCCEEDED", "FAILED", "BLOCKED")


def _deployment_metrics(lines: List[str], ctx: MonitoringContext) -> None:
    from . import deployment_monitor

    snap = deployment_monitor.build_snapshot(ctx)
    base = {"org": ctx.org, "cluster": ctx.cluster}
    lines.append(_line("opencenter_deployment_info",
                       dict(base, provider=ctx.provider, region=ctx.region), 1))
    for status in _STATUS_VALUES:
        lines.append(_line("opencenter_deployment_status",
                           dict(base, status=status),
                           1 if snap.deployment_status == status else 0))
    stage_value = {"pending": 0, "running": 1, "passed": 2, "warning": 3, "failed": 4}
    for stage in snap.stages:
        lines.append(_line("opencenter_deployment_stage_status",
                           dict(base, stage=stage["id"], status=stage["status"]), 1))
        lines.append(_line("opencenter_deployment_stage_state",
                           dict(base, stage=stage["id"]),
                           stage_value.get(stage["status"], 0)))
    lines.append(_line("opencenter_deployment_total_duration_seconds", base,
                       snap.elapsed_seconds or 0))
    lines.append(_line("opencenter_deployment_lock_conflicts_total", base,
                       1 if snap.duplicate_pids else 0))
    git = snap.gitops_status or {}
    lines.append(_line("opencenter_gitops_clean", base, 1 if git.get("clean", True) else 0))
    lines.append(_line("opencenter_gitops_unpushed_commits", base, git.get("ahead", 0) or 0))
    commit = git.get("last_commit") or {}
    if commit.get("timestamp"):
        lines.append(_line("opencenter_gitops_last_commit_timestamp_seconds", base,
                           commit["timestamp"]))
    for err in snap.errors[-5:]:
        lines.append(_line("opencenter_deployment_failures_total",
                           dict(base, stage=snap.failed_step or "unknown",
                                reason=err.get("category", "unknown")), 1))


def _cluster_metrics(lines: List[str], ctx: MonitoringContext) -> None:
    snap = CACHE.peek(("cluster_snapshot", ctx.org, ctx.cluster))
    if snap is None:
        return
    base = {"org": ctx.org, "cluster": ctx.cluster}
    for node in snap.nodes:
        lines.append(_line("opencenter_cluster_node_ready",
                           dict(base, node=node.get("name", ""), role=node.get("role", "")),
                           1 if node.get("ready") else 0))
    pods = snap.pods or {}
    for phase in ("running", "pending", "failed", "succeeded", "unknown"):
        lines.append(_line("opencenter_cluster_pods", dict(base, phase=phase),
                           pods.get(phase, 0)))
    for row in snap.flux_sources + snap.flux_kustomizations + snap.helm_releases:
        lines.append(_line("opencenter_flux_resource_ready",
                           dict(base, kind=row.get("kind", ""), name=row.get("name", ""),
                                namespace=row.get("namespace", "")),
                           1 if row.get("ready") else 0))
    for service in snap.platform_services:
        if not service.get("installed"):
            continue
        lines.append(_line("opencenter_platform_service_ready",
                           dict(base, service=service.get("id", ""),
                                namespace=service.get("namespace", "")),
                           1 if service.get("healthy") else 0))
    for server in (snap.infrastructure or {}).get("servers", []):
        lines.append(_line("opencenter_openstack_vm_status",
                           dict(base, node=server.get("name", ""),
                                status=server.get("status", "")), 1))
    for resource, usage in (snap.quotas or {}).items():
        lines.append(_line("opencenter_openstack_quota_usage_ratio",
                           dict(base, resource=resource), usage.get("ratio", 0)))


def _background_refresher():
    from . import cluster_monitor

    while True:
        for org, cluster in known_pairs():
            try:
                ctx = MonitoringContext.resolve(org, cluster)
                if not ctx.kubeconfig_available():
                    continue
                cluster_monitor.build_snapshot(ctx)  # stores itself in the cache
            except Exception:
                continue
        time.sleep(60)


def _maybe_start_background():
    global _BG_STARTED
    if _BG_STARTED or os.environ.get("OPENCENTER_EXPORTER_ACTIVE") != "1":
        return
    with _BG_LOCK:
        if _BG_STARTED:
            return
        thread = threading.Thread(target=_background_refresher, daemon=True,
                                  name="opencenter-exporter-refresh")
        thread.start()
        _BG_STARTED = True


def render_metrics() -> str:
    """Prometheus text exposition for all known clusters."""
    _maybe_start_background()
    lines: List[str] = [
        "# HELP opencenter_deployment_status Deployment state (one series per status, value 1 = active state)",
        "# TYPE opencenter_deployment_status gauge",
        "# HELP opencenter_deployment_stage_state Pipeline stage state (0 pending,1 running,2 passed,3 warning,4 failed)",
        "# TYPE opencenter_deployment_stage_state gauge",
        "# HELP opencenter_cluster_node_ready Node readiness by role",
        "# TYPE opencenter_cluster_node_ready gauge",
    ]
    for org, cluster in known_pairs():
        try:
            ctx = MonitoringContext.resolve(org, cluster)
        except Exception:
            continue
        try:
            _deployment_metrics(lines, ctx)
        except Exception:
            lines.append(_line("opencenter_exporter_collect_errors_total",
                               {"org": org, "cluster": cluster, "collector": "deployment"}, 1))
        try:
            _cluster_metrics(lines, ctx)
        except Exception:
            lines.append(_line("opencenter_exporter_collect_errors_total",
                               {"org": org, "cluster": cluster, "collector": "cluster"}, 1))
    return "\n".join(lines) + "\n"
