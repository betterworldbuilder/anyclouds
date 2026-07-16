"""Builds ClusterHealthSnapshot objects for the Cluster Operations Dashboard."""
from __future__ import annotations

import datetime as _dt
from typing import Any, Dict, List

from .cache import CACHE
from .command_runner import run_json_command
from .models import ClusterHealthSnapshot, MonitoringContext
from .parsers import (
    parse_events,
    parse_flux_objects,
    parse_nodes,
    parse_pods,
    parse_quota,
    parse_servers,
)

# service id, display name, namespace, workload-name prefixes
PLATFORM_SERVICES = [
    ("calico", "Calico", "calico-system", ("calico", "tigera")),
    ("tigera-operator", "Tigera Operator", "tigera-operator", ("tigera-operator",)),
    ("cert-manager", "cert-manager", "cert-manager", ("cert-manager",)),
    ("envoy-gateway", "Envoy Gateway", "envoy-gateway-system", ("envoy",)),
    ("gateway-api", "Gateway API", "gateway-system", ("gateway",)),
    ("headlamp", "Headlamp", "headlamp", ("headlamp",)),
    ("kyverno", "Kyverno", "kyverno", ("kyverno",)),
    ("olm", "OLM", "olm", ("olm-operator", "catalog-operator")),
    ("openstack-ccm", "OpenStack CCM", "kube-system", ("openstack-cloud-controller",)),
    ("openstack-csi", "Cinder CSI", "kube-system", ("csi-cinder", "openstack-cinder")),
    ("snapshotter", "External Snapshotter", "kube-system", ("snapshot-controller",)),
    ("postgres-operator", "PostgreSQL Operator", "postgres-operator", ("postgres-operator",)),
    ("grafana", "Grafana", "observability", ("grafana",)),
    ("loki", "Loki", "observability", ("loki",)),
    ("tempo", "Tempo", "observability", ("tempo",)),
    ("prometheus", "kube-prometheus-stack", "observability", ("prometheus", "kube-prometheus")),
    ("keycloak", "Keycloak", "keycloak", ("keycloak",)),
    ("weave-gitops", "Weave GitOps", "flux-system", ("weave-gitops", "ww-gitops")),
    ("rbac-manager", "RBAC Manager", "rbac-manager", ("rbac-manager",)),
    ("etcd-backup", "etcd backup", "kube-system", ("etcd-backup",)),
    ("metrics-server", "metrics-server", "kube-system", ("metrics-server",)),
    ("flux", "Flux controllers", "flux-system", ("source-controller", "kustomize-controller",
                                                  "helm-controller", "notification-controller")),
]


def _utcnow() -> str:
    return _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds")


def _cached_json(ctx: MonitoringContext, command_id: str, ttl: int):
    return CACHE.get((command_id, ctx.org, ctx.cluster), ttl,
                     lambda: run_json_command(ctx, command_id))


def _workload_matrix(ctx: MonitoringContext) -> List[Dict[str, Any]]:
    result = _cached_json(ctx, "k8s_deployments", 5)
    items = (result.get("data") or {}).get("items", []) if result.get("ok") else []
    rows = []
    for sid, title, namespace, prefixes in PLATFORM_SERVICES:
        matched = []
        for item in items:
            meta = item.get("metadata", {})
            if not str(meta.get("name", "")).startswith(tuple(prefixes)):
                continue
            status = item.get("status", {}) or {}
            desired = status.get("replicas", status.get("desiredNumberScheduled", 0)) or 0
            ready = status.get("readyReplicas", status.get("numberReady", 0)) or 0
            matched.append({
                "kind": item.get("kind", ""),
                "name": meta.get("name", ""),
                "namespace": meta.get("namespace", ""),
                "desired": desired,
                "ready": ready,
            })
        installed = bool(matched)
        healthy = installed and all(w["ready"] >= w["desired"] and w["desired"] > 0 for w in matched)
        rows.append({
            "id": sid, "title": title, "namespace": namespace,
            "installed": installed,
            "healthy": healthy if installed else None,
            "workloads": matched,
        })
    return rows


def _health_score(snapshot: ClusterHealthSnapshot) -> int:
    """0-100 weighted health score across the major subsystems."""
    score = 0.0
    nodes_total = len(snapshot.nodes)
    nodes_ready = sum(1 for n in snapshot.nodes if n.get("ready"))
    if nodes_total:
        score += 30 * nodes_ready / nodes_total
    pods = snapshot.pods or {}
    if pods.get("total"):
        good = pods.get("running", 0) + pods.get("succeeded", 0)
        score += 30 * good / pods["total"]
    flux_total = len(snapshot.flux_kustomizations) + len(snapshot.helm_releases) + len(snapshot.flux_sources)
    flux_ready = sum(1 for r in snapshot.flux_kustomizations + snapshot.helm_releases + snapshot.flux_sources
                     if r.get("ready"))
    if flux_total:
        score += 25 * flux_ready / flux_total
    installed = [s for s in snapshot.platform_services if s.get("installed")]
    if installed:
        score += 15 * sum(1 for s in installed if s.get("healthy")) / len(installed)
    return int(round(score))


def build_snapshot(ctx: MonitoringContext, include_openstack: bool = True) -> ClusterHealthSnapshot:
    snapshot = ClusterHealthSnapshot(org=ctx.org, cluster=ctx.cluster,
                                     provider=ctx.provider, region=ctx.region)
    snapshot.generated_at = _utcnow()

    if not ctx.kubeconfig_available():
        snapshot.available = False
        snapshot.reason = "not available yet: kubeconfig does not exist"
        return snapshot

    nodes = _cached_json(ctx, "k8s_nodes", 5)
    if not nodes.get("ok"):
        snapshot.available = False
        snapshot.reason = nodes.get("error", "Kubernetes API unreachable")
        return snapshot
    snapshot.available = True
    snapshot.nodes = parse_nodes(nodes.get("data") or {})
    cp = [n for n in snapshot.nodes if n["role"] == "control-plane"]
    wk = [n for n in snapshot.nodes if n["role"] == "worker"]
    snapshot.control_plane = {"total": len(cp), "ready": sum(1 for n in cp if n["ready"])}
    snapshot.workers = {"total": len(wk), "ready": sum(1 for n in wk if n["ready"])}

    pods = _cached_json(ctx, "k8s_pods", 5)
    snapshot.pods = parse_pods(pods.get("data") or {}) if pods.get("ok") else {}

    ns = _cached_json(ctx, "k8s_namespaces", 30)
    if ns.get("ok"):
        snapshot.namespaces = [i.get("metadata", {}).get("name", "")
                               for i in (ns.get("data") or {}).get("items", [])]

    events = _cached_json(ctx, "k8s_events", 5)
    if events.get("ok"):
        snapshot.recent_events = parse_events(events.get("data") or {})

    services = _cached_json(ctx, "k8s_services", 15)
    if services.get("ok"):
        rows = []
        for item in (services.get("data") or {}).get("items", []):
            spec = item.get("spec", {}) or {}
            if spec.get("type") != "LoadBalancer":
                continue
            ingress = ((item.get("status", {}) or {}).get("loadBalancer", {}) or {}).get("ingress", []) or []
            rows.append({
                "name": item.get("metadata", {}).get("name", ""),
                "namespace": item.get("metadata", {}).get("namespace", ""),
                "type": spec.get("type", ""),
                "external_ips": [i.get("ip") or i.get("hostname") for i in ingress],
                "ports": ["%s/%s" % (p.get("port"), p.get("protocol")) for p in spec.get("ports", [])],
            })
        snapshot.services = rows

    for command_id, attr in (("k8s_gateways", "gateways"), ("k8s_certificates", "certificates"),
                             ("k8s_pvcs", "pvcs"), ("k8s_storageclasses", "storage_classes")):
        result = _cached_json(ctx, command_id, 15)
        if result.get("ok"):
            items = (result.get("data") or {}).get("items", [])
            if attr == "certificates":
                rows = []
                for item in items:
                    ready = any(c.get("type") == "Ready" and c.get("status") == "True"
                                for c in (item.get("status", {}) or {}).get("conditions", []) or [])
                    rows.append({
                        "name": item.get("metadata", {}).get("name", ""),
                        "namespace": item.get("metadata", {}).get("namespace", ""),
                        "ready": ready,
                        "not_after": (item.get("status", {}) or {}).get("notAfter", ""),
                    })
                snapshot.certificates = rows
            elif attr == "pvcs":
                snapshot.pvcs = [{
                    "name": i.get("metadata", {}).get("name", ""),
                    "namespace": i.get("metadata", {}).get("namespace", ""),
                    "phase": (i.get("status", {}) or {}).get("phase", ""),
                    "capacity": ((i.get("status", {}) or {}).get("capacity", {}) or {}).get("storage", ""),
                    "storage_class": (i.get("spec", {}) or {}).get("storageClassName", ""),
                } for i in items]
            elif attr == "storage_classes":
                snapshot.storage_classes = [{
                    "name": i.get("metadata", {}).get("name", ""),
                    "provisioner": i.get("provisioner", ""),
                    "default": i.get("metadata", {}).get("annotations", {}).get(
                        "storageclass.kubernetes.io/is-default-class") == "true",
                } for i in items]
            else:
                snapshot.gateways = [{
                    "name": i.get("metadata", {}).get("name", ""),
                    "namespace": i.get("metadata", {}).get("namespace", ""),
                    "class": (i.get("spec", {}) or {}).get("gatewayClassName", ""),
                    "listeners": len((i.get("spec", {}) or {}).get("listeners", []) or []),
                    "addresses": [a.get("value") for a in (i.get("status", {}) or {}).get("addresses", []) or []],
                } for i in items]

    for command_id, attr in (("flux_sources", "flux_sources"),
                             ("flux_kustomizations", "flux_kustomizations"),
                             ("flux_helmreleases", "helm_releases")):
        result = _cached_json(ctx, command_id, 5)
        if result.get("ok"):
            setattr(snapshot, attr, parse_flux_objects(result.get("data") or {}))

    snapshot.platform_services = _workload_matrix(ctx)

    if include_openstack and ctx.is_openstack():
        servers = _cached_json(ctx, "os_server_list", 5)
        if servers.get("ok"):
            snapshot.infrastructure = {"servers": parse_servers(servers.get("data") or [], ctx.cluster)}
        quota = _cached_json(ctx, "os_quota_show", 15)
        if quota.get("ok"):
            snapshot.quotas = parse_quota(quota.get("data"))
        secgroups = _cached_json(ctx, "os_secgroup_list", 15)
        if secgroups.get("ok"):
            snapshot.security_groups = [
                {"id": g.get("ID", ""), "name": g.get("Name", "")}
                for g in (secgroups.get("data") or [])
                if ctx.cluster in str(g.get("Name", ""))
            ]
        fips = _cached_json(ctx, "os_fip_list", 15)
        if fips.get("ok"):
            snapshot.floating_ips = [
                {"ip": f.get("Floating IP Address", ""), "fixed": f.get("Fixed IP Address") or "",
                 "port": f.get("Port") or ""}
                for f in (fips.get("data") or [])
            ]

    # Alerts
    alerts: List[Dict[str, Any]] = []
    if snapshot.control_plane.get("total") and snapshot.control_plane["ready"] < snapshot.control_plane["total"]:
        alerts.append({"severity": "critical", "message": "Control-plane node(s) not Ready"})
    if snapshot.pods.get("crashloop"):
        alerts.append({"severity": "critical",
                       "message": "%d pod(s) in CrashLoopBackOff" % snapshot.pods["crashloop"]})
    if snapshot.pods.get("imagepull"):
        alerts.append({"severity": "warning",
                       "message": "%d pod(s) with image pull failures" % snapshot.pods["imagepull"]})
    flux_bad = [r for r in snapshot.flux_kustomizations + snapshot.helm_releases
                if not r.get("ready") and not r.get("suspended")]
    if flux_bad:
        alerts.append({"severity": "warning",
                       "message": "%d Flux resource(s) not Ready" % len(flux_bad)})
    for name, usage in (snapshot.quotas or {}).items():
        if usage.get("alert") in ("warning", "critical"):
            alerts.append({"severity": usage["alert"],
                           "message": "Quota %s at %d%% (%s/%s)" % (
                               name, int(usage["ratio"] * 100), usage["used"], usage["limit"])})
    snapshot.active_alerts = alerts
    snapshot.health_score = _health_score(snapshot)
    # Latest full snapshot is shared with the Prometheus exporter, which must
    # never trigger expensive commands during a scrape.
    CACHE.put(("cluster_snapshot", ctx.org, ctx.cluster), snapshot)
    return snapshot
