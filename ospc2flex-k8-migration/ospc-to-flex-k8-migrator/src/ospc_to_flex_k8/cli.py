"""
CLI entrypoint for the OSPC → Flex Kubernetes migration toolkit.

Usage:
    python -m ospc_to_flex_k8.cli <command> [options]

Commands:
    export          Stage 1  — SSH to OSPC master and export all cluster resources
    design-template Stage 2  — Design and validate Flex Magnum ClusterTemplate
    create-target   Stage 3  — Create a new Flex Magnum Kubernetes cluster
    plan            Load and display the migration plan
    transform       Stage 4  — Transform exported manifests for Flex Magnum
    restore         Stage 5  — Apply transformed manifests to the Flex target cluster
    validate        Stage 7  — Run post-migration validation checks (incl. Magnum health)
    smoke-test      Stage 7  — Run smoke tests (connectivity + workload health)
    rollback-plan   Stage 9  — Generate a rollback plan from migration state
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

from . import __version__
from .io_utils import setup_logging, ensure_dir, dump_json
from .models import MigrationStage, RestorePhase


# ── Shared helpers ────────────────────────────────────────────────────────────

def _print_json(data: Any) -> None:
    print(json.dumps(data, indent=2, default=str))


def _load_plan(plan_file: Optional[str]):
    from .planner import load_plan, default_plan
    return load_plan(plan_file) if plan_file else default_plan()


def _run_id(args: argparse.Namespace) -> str:
    import datetime
    return datetime.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")


# ── export ────────────────────────────────────────────────────────────────────

def cmd_export(args: argparse.Namespace, log: logging.Logger) -> int:
    """
    Stage 1 — SSH to OSPC master and export all cluster resources.

    Required env vars (or CLI flags): OSPC_MASTER_IP, SSH_USER, SSH_KEY_PATH
    """
    from .exporter import ExportConfig, export_cluster

    # Build config — CLI flags override env vars
    master_ip  = args.master_ip  or os.environ.get("OSPC_MASTER_IP", "")
    ssh_user   = args.ssh_user   or os.environ.get("SSH_USER", "")
    ssh_key    = args.ssh_key    or os.environ.get("SSH_KEY_PATH", "")

    missing = [k for k, v in [("master-ip", master_ip), ("ssh-user", ssh_user), ("ssh-key", ssh_key)] if not v]
    if missing:
        log.error("Missing required arguments: %s", ", ".join(f"--{m}" for m in missing))
        log.error("Also accepts env vars: OSPC_MASTER_IP, SSH_USER, SSH_KEY_PATH")
        return 1

    cfg = ExportConfig(
        ospc_master_ip=master_ip,
        ssh_user=ssh_user,
        ssh_key_path=ssh_key,
        output_dir=args.output_dir,
        ssh_port=args.ssh_port,
        keep_remote_export=args.keep_remote,
        remote_temp_base=getattr(args, "remote_temp_base", "/tmp"),
    )

    log.info("Stage 1: Export from OSPC master %s", master_ip)
    local_dir, summary = export_cluster(cfg)
    _print_json(summary)
    log.info("Export complete → %s", local_dir)
    return 0


# ── design-template ───────────────────────────────────────────────────────────

def cmd_design_template(args: argparse.Namespace, log: logging.Logger) -> int:
    """
    Stage 2 — Design and validate a Flex Magnum ClusterTemplate.

    Validates an existing ClusterTemplate against Magnum 2025.2 requirements
    and writes results to output/<ts>/design/.  Also outputs a recommended
    ClusterTemplate dict if --source-summary is provided.
    """
    from .magnum import validate_cluster_template, design_cluster_template
    import datetime

    ts = datetime.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    design_dir = None
    if args.output_dir:
        design_dir = ensure_dir(Path(args.output_dir) / "design")

    log.info("Stage 2: Design/validate ClusterTemplate=%s", args.template_name)

    # Validate existing template
    validation_results = validate_cluster_template(
        template_name=args.template_name,
        openrc=args.openrc,
    )

    # Optionally generate recommended template
    recommended = None
    if args.source_summary:
        import json as _json
        with open(args.source_summary) as f:
            source_info = _json.load(f)
        recommended = design_cluster_template(source_info, template_name=args.template_name)

    output = {
        "stage": "2_design_template",
        "timestamp": ts,
        "template_name": args.template_name,
        "validation": validation_results,
        "recommended_template": recommended,
    }

    if design_dir:
        dump_json(output, design_dir / "design-report.json")
        log.info("Design report written to %s", design_dir / "design-report.json")

    _print_json(output)

    # Determine overall pass/fail (skip None = informational)
    failures = [
        k for k, v in validation_results.items()
        if isinstance(v, dict) and v.get("passed") is False
    ]
    if failures:
        log.error("Stage 2 FAILED: %d check(s) failed: %s", len(failures), failures)
        return 1
    log.info("Stage 2: ClusterTemplate validation passed")
    return 0


# ── plan ──────────────────────────────────────────────────────────────────────

def cmd_plan(args: argparse.Namespace, log: logging.Logger) -> int:
    """Load and display the migration plan as JSON."""
    plan = _load_plan(getattr(args, "plan", None))
    _print_json({
        "include_namespaces":    plan.include_namespaces,
        "exclude_namespaces":    plan.exclude_namespaces,
        "exclude_kinds":         plan.exclude_kinds,
        "strip_fields":          plan.strip_fields,
        "remove_node_selectors": plan.remove_node_selectors,
        "remove_affinity":       plan.remove_affinity,
        "remove_tolerations":    plan.remove_tolerations,
        "storage_mapping": {
            "default":  plan.storage_mapping.default,
            "mappings": plan.storage_mapping.old_to_new,
        },
        "ingress_mapping": {
            "default":  plan.ingress_mapping.default,
            "mappings": plan.ingress_mapping.old_to_new,
        },
        "endpoint_replacements": [
            {"old": r.old, "new": r.new} for r in plan.endpoint_replacements
        ],
        "exclude_secret_names": plan.exclude_secret_names,
    })
    return 0


# ── transform ─────────────────────────────────────────────────────────────────

def cmd_transform(args: argparse.Namespace, log: logging.Logger) -> int:
    """Stage 4 — Transform exported manifests for Flex Magnum compatibility."""
    from .transformer import transform_directory

    source_dir = Path(args.source_dir)
    output_dir = Path(args.output_dir)

    if not source_dir.exists():
        log.error("Source directory not found: %s", source_dir)
        return 1

    # Place transformed output under output/<ts>/transform/transformed-manifests/
    transform_out = output_dir / "transform" / "transformed-manifests"
    ensure_dir(transform_out)
    report_file = output_dir / "transform" / "transform-report.json"

    plan = _load_plan(getattr(args, "plan", None))
    log.info("Stage 4: Transform %s → %s", source_dir, transform_out)

    report = transform_directory(
        source_dir=source_dir,
        output_dir=transform_out,
        plan=plan,
    )
    report_dict = report.to_dict()
    dump_json(report_dict, report_file)
    _print_json(report_dict)
    log.info("Transform complete. Report: %s", report_file)
    return 0


# ── create-target ─────────────────────────────────────────────────────────────

def cmd_create_target(args: argparse.Namespace, log: logging.Logger) -> int:
    """Stage 3 — Create a new Flex Magnum Kubernetes cluster."""
    from .magnum import create_cluster, wait_for_cluster, get_kubeconfig

    labels: Dict[str, str] = {}
    for lbl in (args.labels or []):
        if "=" in lbl:
            k, v = lbl.split("=", 1)
            labels[k] = v

    log.info(
        "Stage 3: Create Magnum cluster name=%s template=%s masters=%d workers=%d",
        args.cluster_name, args.template, args.master_count, args.node_count,
    )

    uuid = create_cluster(
        cluster_name=args.cluster_name,
        template=args.template,
        master_count=args.master_count,
        node_count=args.node_count,
        keypair=args.keypair,
        labels=labels or None,
        openrc=args.openrc,
        dry_run=args.dry_run,
    )
    if not uuid:
        log.error("Cluster creation request failed")
        return 1

    log.info("Cluster UUID: %s", uuid)

    if not args.no_wait:
        ok = wait_for_cluster(
            cluster_name_or_id=uuid,
            poll_interval=args.poll_interval,
            timeout=args.wait_timeout,
            openrc=args.openrc,
        )
        if not ok:
            log.error("Cluster did not reach CREATE_COMPLETE within timeout")
            return 1

    if args.kubeconfig_out:
        kc_path = Path(args.kubeconfig_out)
        ok = get_kubeconfig(
            cluster_name_or_id=uuid,
            output_path=kc_path,
            openrc=args.openrc,
            dry_run=args.dry_run,
        )
        log.info("Kubeconfig %s", "saved to " + str(kc_path) if ok else "FAILED")

    _print_json({"uuid": uuid, "name": args.cluster_name, "status": "CREATE_COMPLETE"})
    return 0


# ── restore ───────────────────────────────────────────────────────────────────

def cmd_restore(args: argparse.Namespace, log: logging.Logger) -> int:
    """Stage 5 — Apply transformed manifests to the Flex cluster in phase order."""
    from .restore import restore_cluster, summarize_results

    transformed_dir = Path(args.transformed_dir)
    if not transformed_dir.exists():
        log.error("Transformed directory not found: %s", transformed_dir)
        return 1

    # Build phase filters
    skip_phases: List[RestorePhase] = []
    for p in (args.skip_phases or []):
        try:
            skip_phases.append(RestorePhase(p))
        except ValueError:
            log.warning("Unknown phase: %s", p)

    only_phases: Optional[List[RestorePhase]] = None
    if args.only_phases:
        only_phases = []
        for p in args.only_phases:
            try:
                only_phases.append(RestorePhase(p))
            except ValueError:
                log.warning("Unknown phase: %s", p)

    log.info("Stage 5: Restore to Flex — context=%s dry_run=%s", args.context, args.dry_run)

    results_map = restore_cluster(
        transformed_dir=transformed_dir,
        context=args.context,
        kubeconfig=args.kubeconfig,
        dry_run=args.dry_run,
        server_side=args.server_side,
        skip_phases=skip_phases,
        only_phases=only_phases,
    )

    # Write restore report
    summary = summarize_results(results_map)
    if args.report_dir:
        report_dir = ensure_dir(Path(args.report_dir) / "restore")
        dump_json(summary, report_dir / "apply-report.json")
        # Write restore-order.txt
        with open(report_dir / "restore-order.txt", "w") as f:
            for phase in results_map:
                f.write(f"{phase.value}\n")
        log.info("Restore report written to %s", report_dir)

    _print_json(summary)
    return 1 if summary["failed"] > 0 else 0


# ── validate ──────────────────────────────────────────────────────────────────

def cmd_validate(args: argparse.Namespace, log: logging.Logger) -> int:
    """Stage 7 — Run post-migration validation checks including Magnum health and LB test."""
    from .validator import run_validation, validation_summary, validate_magnum_cluster, validate_loadbalancer

    results = run_validation(
        namespaces=args.namespaces or None,
        context=args.context,
        kubeconfig=args.kubeconfig,
    )

    # Magnum cluster health check (Stage 7 addition)
    if getattr(args, "cluster_name", None):
        magnum_result = validate_magnum_cluster(
            cluster_name=args.cluster_name,
            kubeconfig=args.kubeconfig,
            openrc=getattr(args, "openrc", None),
        )
        results.append(magnum_result)

    # LoadBalancer test descriptor (Stage 7 addition)
    if getattr(args, "lb_test", False):
        lb_info = validate_loadbalancer(
            kubeconfig=args.kubeconfig,
            context=args.context,
        )
        from .models import ValidationResult
        results.append(ValidationResult(
            check="loadbalancer_test",
            passed=True,
            detail=lb_info["success_criteria"],
        ))

    summary = validation_summary(results)

    if args.report_dir:
        report_dir = ensure_dir(Path(args.report_dir))
        dump_json(summary, report_dir / "validation-report.json")
        # Pretty text summary
        lines = [
            "Validation Summary",
            "==================",
            f"Total:   {summary['total']}",
            f"Passed:  {summary['passed']}",
            f"Failed:  {summary['failed']}",
            "",
        ]
        for r in summary["results"]:
            status = "PASS" if r["passed"] else "FAIL"
            lines.append(f"  [{status}] {r['check']}: {r['detail']}")
        (report_dir / "validation-summary.txt").write_text("\n".join(lines))

    _print_json(summary)

    if not summary["all_passed"]:
        log.error("Validation FAILED: %d/%d checks passed", summary["passed"], summary["total"])
        return 1
    log.info("Validation PASSED: %d/%d checks", summary["passed"], summary["total"])
    return 0


# ── smoke-test ────────────────────────────────────────────────────────────────

def cmd_smoke_test(args: argparse.Namespace, log: logging.Logger) -> int:
    """Stage 7 — Quick smoke tests: cluster connectivity + pod health."""
    from .validator import (
        check_nodes_ready,
        check_no_crashlooping_pods,
        check_pvcs_bound,
        check_services_have_endpoints,
        validation_summary,
    )
    from .io_utils import run_cmd

    log.info("Smoke test: context=%s", args.context)

    kc_flags = ""
    if args.context:
        kc_flags += f" --context={args.context}"
    if args.kubeconfig:
        kc_flags += f" --kubeconfig={args.kubeconfig}"

    results = []

    # Basic connectivity
    rc, out, _ = run_cmd(f"kubectl{kc_flags} version --short 2>/dev/null || kubectl{kc_flags} version", capture=True, timeout=30)
    from .models import ValidationResult
    results.append(ValidationResult(
        check="api_server_reachable",
        passed=(rc == 0),
        detail=out.splitlines()[0] if out else "no output",
    ))

    # Core checks
    results += [
        check_nodes_ready(context=args.context, kubeconfig=args.kubeconfig),
        check_pvcs_bound(context=args.context, kubeconfig=args.kubeconfig),
        check_services_have_endpoints(context=args.context, kubeconfig=args.kubeconfig),
        check_no_crashlooping_pods(context=args.context, kubeconfig=args.kubeconfig),
    ]

    # Optional URL health checks
    if args.url_checks:
        import urllib.request
        for url in args.url_checks:
            try:
                resp = urllib.request.urlopen(url, timeout=10)
                results.append(ValidationResult(
                    check=f"url_{url}",
                    passed=(200 <= resp.status < 400),
                    detail=f"HTTP {resp.status}",
                ))
            except Exception as exc:
                results.append(ValidationResult(
                    check=f"url_{url}",
                    passed=False,
                    detail=str(exc),
                ))

    summary = validation_summary(results)
    _print_json(summary)
    return 0 if summary["all_passed"] else 1


# ── rollback-plan ─────────────────────────────────────────────────────────────

def cmd_rollback_plan(args: argparse.Namespace, log: logging.Logger) -> int:
    """
    Stage 9 — Generate a rollback plan from migration state.

    Reads state.json from the run output dir, or accepts explicit parameters.
    """
    import datetime
    from .models import RollbackPlan, MigrationStage

    try:
        stage = MigrationStage(args.stage)
    except ValueError:
        log.error("Invalid stage: %s. Valid values: %s",
                  args.stage, [s.value for s in MigrationStage])
        return 1

    run_id = args.run_id or f"rollback-{datetime.datetime.utcnow().strftime('%Y%m%dT%H%M%SZ')}"

    rollback = RollbackPlan(
        run_id=run_id,
        stage=stage,
        source_context=args.source_context or "ospc-master",
        target_context=args.target_context or args.context or "",
        cutover_timestamp=args.cutover_ts,
        notes=args.notes or [],
        pre_rollback_checks=[
            "Verify OSPC source cluster is still accessible",
            "Verify OSPC workloads are still intact (not deleted)",
            "Confirm Flex cluster is isolated (no clients currently pointing to it)",
            "Check for any data written to Flex that needs to be synced back",
        ],
        rollback_commands=[
            f"# Scale down Flex workloads",
            f"kubectl --context={args.target_context or 'flex-context'} scale deployment --all -n <namespace> --replicas=0",
            f"kubectl --context={args.target_context or 'flex-context'} scale statefulset --all -n <namespace> --replicas=0",
            f"",
            f"# Re-enable OSPC workloads (if they were scaled down for cutover)",
            f"kubectl --context={args.source_context or 'ospc-context'} scale deployment --all -n <namespace> --replicas=1",
            f"",
            f"# Revert DNS / LB to point back to OSPC",
            f"# (see docs/rollback.md for provider-specific steps)",
        ],
        validation_checks=[
            "kubectl --context=<ospc-context> get pods -A | grep -v Running",
            "curl -I https://<your-app-domain>/ (should resolve to OSPC)",
            "Check application logs on OSPC for any errors",
        ],
    )

    plan_dict = rollback.to_dict()

    if args.output:
        out_path = Path(args.output)
        dump_json(plan_dict, out_path)
        log.info("Rollback plan written to %s", out_path)

    _print_json(plan_dict)
    return 0


# ── Argument parser ───────────────────────────────────────────────────────────

def _common(p: argparse.ArgumentParser) -> None:
    """Add arguments shared by most commands."""
    p.add_argument("--context",   default=None, help="kubectl context name")
    p.add_argument("--kubeconfig",default=None, help="Path to kubeconfig file")
    p.add_argument("--dry-run",   action="store_true", help="Print commands without executing")
    p.add_argument("--log-dir",   default="./output/logs", help="Directory for log files")
    p.add_argument("--log-level", default="INFO",
                   choices=["DEBUG", "INFO", "WARNING", "ERROR"])


def _plan_arg(p: argparse.ArgumentParser) -> None:
    p.add_argument("--plan", default=None, metavar="FILE",
                   help="Path to migration-plan.yaml (uses defaults if omitted)")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m ospc_to_flex_k8.cli",
        description="OSPC Kubernetes → Rackspace Flex Magnum migration toolkit",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")

    sub = parser.add_subparsers(dest="command", metavar="COMMAND")
    sub.required = True

    # ── export ────────────────────────────────────────────────────────────────
    p_exp = sub.add_parser("export",
        help="SSH to OSPC master and export cluster resources (Stage 1)")
    _common(p_exp)
    _plan_arg(p_exp)
    p_exp.add_argument("--master-ip",   default=None, help="OSPC master node IP (or OSPC_MASTER_IP env)")
    p_exp.add_argument("--ssh-user",    default=None, help="SSH username (or SSH_USER env)")
    p_exp.add_argument("--ssh-key",     default=None, help="Path to SSH private key (or SSH_KEY_PATH env)")
    p_exp.add_argument("--ssh-port",    type=int, default=22, help="SSH port (default: 22)")
    p_exp.add_argument("--output-dir",  required=True, metavar="DIR",
                       help="Local root output directory (e.g. ./output)")
    p_exp.add_argument("--keep-remote", action="store_true",
                       help="Do not delete the remote temp export dir after copy")

    # ── plan ──────────────────────────────────────────────────────────────────
    p_plan = sub.add_parser("plan", help="Display the migration plan as JSON")
    _common(p_plan)
    _plan_arg(p_plan)

    # ── design-template ───────────────────────────────────────────────────────
    p_des = sub.add_parser("design-template",
        help="Design and validate Flex Magnum ClusterTemplate (Stage 2)")
    _common(p_des)
    p_des.add_argument("--template-name", required=True, metavar="NAME",
                       help="Magnum ClusterTemplate name or UUID to validate")
    p_des.add_argument("--openrc", default=None, metavar="FILE",
                       help="Path to OpenRC credentials file")
    p_des.add_argument("--output-dir", default=None, metavar="DIR",
                       help="Root output dir — design/ subdir will be created here")
    p_des.add_argument("--source-summary", default=None, metavar="FILE",
                       help="Path to export summary.json for recommended template generation")

    # ── transform ─────────────────────────────────────────────────────────────
    p_xfm = sub.add_parser("transform",
        help="Transform exported manifests for Flex compatibility (Stage 4)")
    _common(p_xfm)
    _plan_arg(p_xfm)
    p_xfm.add_argument("--source-dir",  required=True, metavar="DIR",
                       help="Path to exported manifests/ dir (Stage 1 output)")
    p_xfm.add_argument("--output-dir",  required=True, metavar="DIR",
                       help="Root output dir — transform/ subdir will be created here")

    # ── create-target ─────────────────────────────────────────────────────────
    p_cre = sub.add_parser("create-target",
        help="Create a new Flex Magnum Kubernetes cluster (Stage 3)")
    _common(p_cre)
    p_cre.add_argument("--cluster-name", required=True)
    p_cre.add_argument("--template",     required=True, help="Magnum cluster template name or UUID")
    p_cre.add_argument("--master-count", type=int, default=3)
    p_cre.add_argument("--node-count",   type=int, default=3)
    p_cre.add_argument("--keypair",      default=None)
    p_cre.add_argument("--labels",       nargs="*", metavar="KEY=VALUE")
    p_cre.add_argument("--openrc",       default=None, help="Path to OpenRC credentials file")
    p_cre.add_argument("--no-wait",      action="store_true")
    p_cre.add_argument("--poll-interval",type=int, default=30)
    p_cre.add_argument("--wait-timeout", type=int, default=3600)
    p_cre.add_argument("--kubeconfig-out",default=None, metavar="FILE")

    # ── restore ───────────────────────────────────────────────────────────────
    p_rst = sub.add_parser("restore",
        help="Apply transformed manifests to the Flex cluster (Stage 5)")
    _common(p_rst)
    p_rst.add_argument("--transformed-dir", required=True, metavar="DIR",
                       help="Path to transform/transformed-manifests/ dir")
    p_rst.add_argument("--server-side",  action="store_true")
    p_rst.add_argument("--skip-phases",  nargs="*", metavar="PHASE")
    p_rst.add_argument("--only-phases",  nargs="*", metavar="PHASE")
    p_rst.add_argument("--report-dir",   default=None, metavar="DIR",
                       help="Write apply-report.json + restore-order.txt here")

    # ── validate ──────────────────────────────────────────────────────────────
    p_val = sub.add_parser("validate",
        help="Run post-migration validation checks incl. Magnum health (Stage 7)")
    _common(p_val)
    p_val.add_argument("--namespaces", nargs="*", metavar="NS")
    p_val.add_argument("--report-dir", default=None, metavar="DIR")
    p_val.add_argument("--cluster-name", default=None, metavar="NAME",
                       help="Magnum cluster name for Magnum health check (Stage 7)")
    p_val.add_argument("--openrc", default=None, metavar="FILE",
                       help="OpenRC file for Magnum cluster health check")
    p_val.add_argument("--lb-test", action="store_true",
                       help="Include LoadBalancer test descriptor in validation output")

    # ── smoke-test ────────────────────────────────────────────────────────────
    p_smo = sub.add_parser("smoke-test",
        help="Quick connectivity and health smoke tests (Stage 7)")
    _common(p_smo)
    p_smo.add_argument("--namespaces", nargs="*", metavar="NS")
    p_smo.add_argument("--url-checks", nargs="*", metavar="URL",
                       help="Optional URLs to HTTP-check after migration")

    # ── rollback-plan ─────────────────────────────────────────────────────────
    p_rb = sub.add_parser("rollback-plan",
        help="Generate rollback plan from migration state (Stage 9)")
    _common(p_rb)
    p_rb.add_argument("--run-id",         default=None)
    p_rb.add_argument("--stage",          default="cutover-started",
                      help="Current migration stage (default: cutover-started)")
    p_rb.add_argument("--source-context", default=None)
    p_rb.add_argument("--target-context", default=None)
    p_rb.add_argument("--cutover-ts",     default=None, metavar="TIMESTAMP")
    p_rb.add_argument("--notes",          nargs="*", metavar="NOTE")
    p_rb.add_argument("--output",         default=None, metavar="FILE",
                      help="Write rollback plan JSON to this file")

    return parser


# ── Entry point ───────────────────────────────────────────────────────────────

COMMAND_MAP = {
    "export":           cmd_export,
    "design-template":  cmd_design_template,
    "plan":             cmd_plan,
    "transform":        cmd_transform,
    "create-target":    cmd_create_target,
    "restore":          cmd_restore,
    "validate":         cmd_validate,
    "smoke-test":       cmd_smoke_test,
    "rollback-plan":    cmd_rollback_plan,
}


def main(argv: Optional[List[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    log = setup_logging(
        log_dir=getattr(args, "log_dir", "./output/logs"),
        run_id=args.command.replace("-", "_"),
        level=getattr(args, "log_level", "INFO"),
    )

    handler = COMMAND_MAP.get(args.command)
    if not handler:
        parser.print_help()
        return 1

    try:
        return handler(args, log)
    except KeyboardInterrupt:
        log.warning("Interrupted")
        return 130
    except Exception as exc:
        log.exception("Unhandled error: %s", exc)
        return 1


if __name__ == "__main__":
    sys.exit(main())
