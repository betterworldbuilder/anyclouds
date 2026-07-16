"""Allowlisted command registry for OpenCenter monitoring.

Every command the monitoring backend can run is declared here as an argv list
builder. The browser never supplies command text; endpoints reference commands
by id and the registry builds argv from a validated MonitoringContext. All
commands are read-only.
"""
from __future__ import annotations

import shutil
from dataclasses import dataclass
from typing import Callable, Dict, List, Optional

from .models import MonitoringContext, MonitoringError

# Cache tiers → refresh interval in seconds (shared polling cache).
TIER_PROCESS = 2
TIER_VM = 5
TIER_K8S = 5
TIER_QUOTA = 15
TIER_STATIC = 30


@dataclass(frozen=True)
class CommandSpec:
    id: str
    build: Callable[[MonitoringContext], List[str]]
    timeout: int
    tier: int
    needs_kubeconfig: bool = False
    needs_openstack: bool = False


def _openstack_bin() -> str:
    for candidate in ("/usr/local/bin/openstack", "/usr/bin/openstack"):
        if shutil.which(candidate) or candidate:
            found = shutil.which("openstack")
            return found or candidate
    return "openstack"


def _kubectl(ctx: MonitoringContext, *args: str) -> List[str]:
    return ["kubectl", "--kubeconfig", str(ctx.kubeconfig_path), "--request-timeout=10s", *args]


def _os(ctx: MonitoringContext, *args: str) -> List[str]:
    return [_openstack_bin(), *args]


_REGISTRY: Dict[str, CommandSpec] = {}


def _register(spec: CommandSpec) -> None:
    _REGISTRY[spec.id] = spec


# --- process / lock ---------------------------------------------------------
_register(CommandSpec(
    id="deploy_processes",
    build=lambda ctx: ["ps", "-eo", "pid,ppid,lstart,etimes,args", "--no-headers"],
    timeout=5, tier=TIER_PROCESS,
))

# --- git (GitOps working tree) ----------------------------------------------
_register(CommandSpec(
    id="git_status",
    build=lambda ctx: ["git", "-C", str(ctx.gitops_dir), "status", "--porcelain=v2", "--branch"],
    timeout=10, tier=TIER_K8S,
))
_register(CommandSpec(
    id="git_last_commit",
    build=lambda ctx: ["git", "-C", str(ctx.gitops_dir), "log", "-1",
                       "--format=%H%x1f%ct%x1f%an%x1f%s"],
    timeout=10, tier=TIER_K8S,
))

# --- OpenStack (only when provider == openstack) ------------------------------
_register(CommandSpec(
    id="os_server_list",
    build=lambda ctx: _os(ctx, "server", "list", "--name", ctx.cluster, "--long", "-f", "json"),
    timeout=45, tier=TIER_VM, needs_openstack=True,
))
_register(CommandSpec(
    id="os_port_list",
    build=lambda ctx: _os(ctx, "port", "list", "-f", "json"),
    timeout=45, tier=TIER_QUOTA, needs_openstack=True,
))
_register(CommandSpec(
    id="os_fip_list",
    build=lambda ctx: _os(ctx, "floating", "ip", "list", "-f", "json"),
    timeout=45, tier=TIER_QUOTA, needs_openstack=True,
))
_register(CommandSpec(
    id="os_secgroup_list",
    build=lambda ctx: _os(ctx, "security", "group", "list", "-f", "json"),
    timeout=45, tier=TIER_QUOTA, needs_openstack=True,
))
_register(CommandSpec(
    id="os_quota_show",
    build=lambda ctx: _os(ctx, "quota", "show", "--usage", "-f", "json"),
    timeout=60, tier=TIER_QUOTA, needs_openstack=True,
))
_register(CommandSpec(
    id="os_network_list",
    build=lambda ctx: _os(ctx, "network", "list", "-f", "json"),
    timeout=45, tier=TIER_QUOTA, needs_openstack=True,
))
_register(CommandSpec(
    id="os_router_list",
    build=lambda ctx: _os(ctx, "router", "list", "-f", "json"),
    timeout=45, tier=TIER_QUOTA, needs_openstack=True,
))

# --- Kubernetes (only when kubeconfig exists) ---------------------------------
_register(CommandSpec(
    id="k8s_nodes",
    build=lambda ctx: _kubectl(ctx, "get", "nodes", "-o", "json"),
    timeout=20, tier=TIER_K8S, needs_kubeconfig=True,
))
_register(CommandSpec(
    id="k8s_pods",
    build=lambda ctx: _kubectl(ctx, "get", "pods", "-A", "-o", "json"),
    timeout=30, tier=TIER_K8S, needs_kubeconfig=True,
))
_register(CommandSpec(
    id="k8s_namespaces",
    build=lambda ctx: _kubectl(ctx, "get", "namespaces", "-o", "json"),
    timeout=20, tier=TIER_STATIC, needs_kubeconfig=True,
))
_register(CommandSpec(
    id="k8s_events",
    build=lambda ctx: _kubectl(ctx, "get", "events", "-A",
                               "--field-selector", "type=Warning", "-o", "json"),
    timeout=30, tier=TIER_K8S, needs_kubeconfig=True,
))
_register(CommandSpec(
    id="k8s_services",
    build=lambda ctx: _kubectl(ctx, "get", "services", "-A", "-o", "json"),
    timeout=30, tier=TIER_QUOTA, needs_kubeconfig=True,
))
_register(CommandSpec(
    id="k8s_gateways",
    build=lambda ctx: _kubectl(ctx, "get", "gateways.gateway.networking.k8s.io", "-A", "-o", "json"),
    timeout=20, tier=TIER_QUOTA, needs_kubeconfig=True,
))
_register(CommandSpec(
    id="k8s_httproutes",
    build=lambda ctx: _kubectl(ctx, "get", "httproutes.gateway.networking.k8s.io", "-A", "-o", "json"),
    timeout=20, tier=TIER_QUOTA, needs_kubeconfig=True,
))
_register(CommandSpec(
    id="k8s_certificates",
    build=lambda ctx: _kubectl(ctx, "get", "certificates.cert-manager.io", "-A", "-o", "json"),
    timeout=20, tier=TIER_QUOTA, needs_kubeconfig=True,
))
_register(CommandSpec(
    id="k8s_pvcs",
    build=lambda ctx: _kubectl(ctx, "get", "pvc", "-A", "-o", "json"),
    timeout=20, tier=TIER_QUOTA, needs_kubeconfig=True,
))
_register(CommandSpec(
    id="k8s_storageclasses",
    build=lambda ctx: _kubectl(ctx, "get", "storageclasses", "-o", "json"),
    timeout=20, tier=TIER_STATIC, needs_kubeconfig=True,
))
_register(CommandSpec(
    id="k8s_deployments",
    build=lambda ctx: _kubectl(ctx, "get", "deployments,daemonsets,statefulsets", "-A", "-o", "json"),
    timeout=30, tier=TIER_K8S, needs_kubeconfig=True,
))
_register(CommandSpec(
    id="k8s_networkpolicies",
    build=lambda ctx: _kubectl(ctx, "get", "networkpolicies", "-A", "-o", "json"),
    timeout=20, tier=TIER_QUOTA, needs_kubeconfig=True,
))
_register(CommandSpec(
    id="flux_sources",
    build=lambda ctx: _kubectl(ctx, "get", "gitrepositories.source.toolkit.fluxcd.io,ocirepositories.source.toolkit.fluxcd.io",
                               "-A", "-o", "json"),
    timeout=20, tier=TIER_K8S, needs_kubeconfig=True,
))
_register(CommandSpec(
    id="flux_kustomizations",
    build=lambda ctx: _kubectl(ctx, "get", "kustomizations.kustomize.toolkit.fluxcd.io", "-A", "-o", "json"),
    timeout=20, tier=TIER_K8S, needs_kubeconfig=True,
))
_register(CommandSpec(
    id="flux_helmreleases",
    build=lambda ctx: _kubectl(ctx, "get", "helmreleases.helm.toolkit.fluxcd.io", "-A", "-o", "json"),
    timeout=20, tier=TIER_K8S, needs_kubeconfig=True,
))
_register(CommandSpec(
    id="kyverno_policies",
    build=lambda ctx: _kubectl(ctx, "get", "clusterpolicies.kyverno.io", "-o", "json"),
    timeout=20, tier=TIER_QUOTA, needs_kubeconfig=True,
))


def get_command(command_id: str) -> CommandSpec:
    spec = _REGISTRY.get(command_id)
    if spec is None:
        raise MonitoringError("Command %r is not allowlisted" % command_id, 400)
    return spec


def all_commands() -> Dict[str, CommandSpec]:
    return dict(_REGISTRY)
