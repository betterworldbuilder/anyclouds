"""Read-only monitoring API blueprint.

Every endpoint validates org/cluster names, uses only allowlisted commands
with timeouts, redacts secrets and returns structured errors. Nothing here
mutates state.
"""
from __future__ import annotations

import functools
import logging
from pathlib import Path

from flask import Blueprint, Response, jsonify, render_template, stream_with_context

logger = logging.getLogger("opencenter.monitoring")


def create_monitoring_blueprint(base_dir: str) -> Blueprint:
    try:
        from workflow_dashboard.monitoring import cluster_monitor, deployment_monitor, log_stream
        from workflow_dashboard.monitoring.models import MonitoringContext, MonitoringError, valid_name
        from workflow_dashboard.monitoring import opencenter_exporter
    except ImportError:
        from monitoring import cluster_monitor, deployment_monitor, log_stream  # type: ignore
        from monitoring.models import MonitoringContext, MonitoringError, valid_name  # type: ignore
        from monitoring import opencenter_exporter  # type: ignore

    bp = Blueprint("monitoring", __name__)

    def with_context(fn):
        @functools.wraps(fn)
        def wrapper(org: str, cluster: str, *args, **kwargs):
            try:
                ctx = MonitoringContext.resolve(org, cluster)
            except MonitoringError as exc:
                return jsonify({"ok": False, "error": str(exc)}), exc.status
            try:
                return fn(ctx, *args, **kwargs)
            except MonitoringError as exc:
                return jsonify({"ok": False, "error": str(exc)}), exc.status
            except Exception:
                logger.exception("monitoring endpoint failed for %s/%s", org, cluster)
                return jsonify({"ok": False, "error": "internal monitoring error"}), 500

        return wrapper

    # ------------------------------------------------------------------ pages
    @bp.get("/opencenter/monitor/deployment/<org>/<cluster>")
    def page_deployment(org, cluster):
        if not (valid_name(org) and valid_name(cluster)):
            return "invalid cluster reference", 400
        return render_template("monitoring/deployment_dashboard.html", org=org, cluster=cluster)

    @bp.get("/opencenter/monitor/cluster/<org>/<cluster>")
    def page_cluster(org, cluster):
        if not (valid_name(org) and valid_name(cluster)):
            return "invalid cluster reference", 400
        return render_template("monitoring/cluster_dashboard.html", org=org, cluster=cluster)

    # ---------------------------------------------------------------- listing
    @bp.get("/api/monitoring/clusters")
    def api_clusters():
        root = Path.home() / ".config" / "opencenter" / "clusters" / "blueprints"
        pairs = []
        if root.is_dir():
            for org_dir in sorted(root.iterdir()):
                if not org_dir.is_dir() or not valid_name(org_dir.name):
                    continue
                for cluster_dir in sorted(org_dir.iterdir()):
                    if not cluster_dir.is_dir() or not valid_name(cluster_dir.name):
                        continue
                    if (cluster_dir / ("%s-config.yaml" % cluster_dir.name)).is_file():
                        pairs.append({"org": org_dir.name, "cluster": cluster_dir.name})
        return jsonify({"ok": True, "pairs": pairs})

    # ------------------------------------------------------------- deployment
    @bp.get("/api/monitoring/deployment/<org>/<cluster>/summary")
    @with_context
    def api_deploy_summary(ctx):
        return jsonify({"ok": True, "snapshot": deployment_monitor.build_snapshot(ctx).to_dict()})

    @bp.get("/api/monitoring/deployment/<org>/<cluster>/stages")
    @with_context
    def api_deploy_stages(ctx):
        snap = deployment_monitor.build_snapshot(ctx)
        return jsonify({"ok": True, "stages": snap.stages,
                        "active_step": snap.active_step, "failed_step": snap.failed_step})

    @bp.get("/api/monitoring/deployment/<org>/<cluster>/processes")
    @with_context
    def api_deploy_processes(ctx):
        snap = deployment_monitor.build_snapshot(ctx)
        procs = deployment_monitor._processes(ctx)  # cached
        return jsonify({"ok": True, "processes": procs,
                        "duplicates": snap.duplicate_pids,
                        "critical": len(procs) > 1})

    @bp.get("/api/monitoring/deployment/<org>/<cluster>/infrastructure")
    @with_context
    def api_deploy_infra(ctx):
        return jsonify({"ok": True, "infrastructure": deployment_monitor.infrastructure_state(ctx)})

    @bp.get("/api/monitoring/deployment/<org>/<cluster>/events")
    @with_context
    def api_deploy_events(ctx):
        snap = deployment_monitor.build_snapshot(ctx)
        return jsonify({"ok": True, "errors": snap.errors, "warnings": snap.warnings})

    @bp.get("/api/monitoring/deployment/<org>/<cluster>/stream")
    @with_context
    def api_deploy_stream(ctx):
        producer = lambda: deployment_monitor.build_snapshot(ctx).to_dict()
        return Response(stream_with_context(log_stream.stream_deployment(ctx, producer)),
                        mimetype="text/event-stream",
                        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})

    # ---------------------------------------------------------------- cluster
    @bp.get("/api/monitoring/cluster/<org>/<cluster>/summary")
    @with_context
    def api_cluster_summary(ctx):
        return jsonify({"ok": True, "snapshot": cluster_monitor.build_snapshot(ctx).to_dict()})

    def _section(attr):
        def handler(ctx):
            snap = cluster_monitor.build_snapshot(ctx)
            return jsonify({"ok": True, "available": snap.available, "reason": snap.reason,
                            attr: getattr(snap, attr)})
        return handler

    for route_name, attr in (
        ("nodes", "nodes"), ("pods", "pods"), ("services", "platform_services"),
        ("storage", "pvcs"), ("events", "recent_events"),
    ):
        bp.add_url_rule(
            "/api/monitoring/cluster/<org>/<cluster>/%s" % route_name,
            "api_cluster_%s" % route_name,
            with_context(_section(attr)),
        )

    @bp.get("/api/monitoring/cluster/<org>/<cluster>/flux")
    @with_context
    def api_cluster_flux(ctx):
        snap = cluster_monitor.build_snapshot(ctx)
        return jsonify({"ok": True, "available": snap.available,
                        "sources": snap.flux_sources,
                        "kustomizations": snap.flux_kustomizations,
                        "helm_releases": snap.helm_releases})

    @bp.get("/api/monitoring/cluster/<org>/<cluster>/network")
    @with_context
    def api_cluster_network(ctx):
        snap = cluster_monitor.build_snapshot(ctx)
        return jsonify({"ok": True, "available": snap.available,
                        "services": snap.services, "gateways": snap.gateways,
                        "floating_ips": snap.floating_ips})

    @bp.get("/api/monitoring/cluster/<org>/<cluster>/security")
    @with_context
    def api_cluster_security(ctx):
        snap = cluster_monitor.build_snapshot(ctx)
        return jsonify({"ok": True, "available": snap.available,
                        "certificates": snap.certificates,
                        "security_groups": snap.security_groups,
                        "quotas": snap.quotas})

    @bp.get("/api/monitoring/cluster/<org>/<cluster>/stream")
    @with_context
    def api_cluster_stream(ctx):
        producer = lambda: cluster_monitor.build_snapshot(ctx).to_dict()
        return Response(stream_with_context(log_stream.stream_cluster(producer)),
                        mimetype="text/event-stream",
                        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})

    # ---------------------------------------------------------------- metrics
    @bp.get("/metrics")
    def api_metrics():
        return Response(opencenter_exporter.render_metrics(),
                        mimetype="text/plain; version=0.0.4; charset=utf-8")

    @bp.get("/healthz")
    def api_healthz():
        return jsonify({"ok": True, "service": "opencenter-monitoring"})

    return bp
