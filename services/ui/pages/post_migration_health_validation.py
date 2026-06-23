#!/usr/bin/env python3
"""Post-migration health validation helpers.

All checks are dry-run/report-oriented by default. The module reads existing
Stage 1/2 artifacts, generates validation targets, writes evidence reports, and
does not change any cloud, VM, DNS, firewall, service, or database state.
"""

from __future__ import annotations

import csv
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List


def repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def ensure_output_dirs() -> Dict[str, Path]:
    root = repo_root()
    dirs = {
        "tmp": root / ".tmp_runs",
        "uat": root / "outputs" / "uat",
    }
    for path in dirs.values():
        path.mkdir(parents=True, exist_ok=True)
    return dirs


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _safe_str(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, (list, dict)):
        return json.dumps(value, sort_keys=True)
    return str(value)


def _read_json(path: Path) -> Any:
    try:
        if path.exists():
            return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    return {}


def _read_csv(path: Path) -> List[Dict[str, Any]]:
    try:
        if path.exists():
            with path.open("r", encoding="utf-8-sig", newline="") as handle:
                return list(csv.DictReader(handle))
    except Exception:
        return []
    return []


def _first(data: Dict[str, Any], *keys: str, default: Any = "") -> Any:
    for key in keys:
        value = data.get(key)
        if value not in (None, ""):
            return value
    return default


def _latest_matching_files(root: Path, patterns: List[str], limit_per_pattern: int = 5) -> List[Path]:
    files: List[Path] = []
    for pattern in patterns:
        matches = [p for p in root.glob(pattern) if p.is_file()]
        matches.sort(key=lambda p: p.stat().st_mtime, reverse=True)
        files.extend(matches[:limit_per_pattern])
    seen = set()
    ordered: List[Path] = []
    for path in files:
        key = str(path.resolve())
        if key in seen:
            continue
        seen.add(key)
        ordered.append(path)
    return ordered


def _as_items(payload: Any) -> List[Dict[str, Any]]:
    if isinstance(payload, list):
        return [x for x in payload if isinstance(x, dict)]
    if isinstance(payload, dict):
        for key in ("items", "results", "vms", "servers", "checks", "candidates", "links", "targets"):
            value = payload.get(key)
            if isinstance(value, list):
                return [x for x in value if isinstance(x, dict)]
    return []


def load_stage2_migration_outputs() -> dict:
    root = repo_root()
    paths = [
        root / ".tmp_runs" / "stage2_migration_output.json",
        root / ".tmp_runs" / "stage2_migration_queue.json",
        root / ".tmp_runs" / "stage2_preflight_handoff.json",
        root / ".tmp_runs" / "stage2_readiness_handoff.json",
        root / ".tmp_runs" / "selected_snapshot_plan.json",
        root / ".tmp_runs" / "app_dependency_report.json",
        root / "outputs" / "migration" / "stage2_migration_output.json",
        root / "outputs" / "stage2" / "stage2_migration_output.json",
        root / "outputs" / "uat" / "uat-input-manifest.json",
    ]
    csv_paths = [
        root / ".tmp_runs" / "stage2_migration_output.csv",
        root / ".tmp_runs" / "stage2_preflight_handoff.csv",
        root / ".tmp_runs" / "selected_app_dependencies.csv",
    ]
    csv_paths.extend(_latest_matching_files(root, [
        "*_tenant_deploy_resource_map.csv",
        "*_tenant_deploy_results.csv",
        "stage2_full_migration_link_map_*.csv",
        "*_app_dependencies.csv",
        "*_flavormap.csv",
        "*_blockmap.csv",
        "*_lbmap.csv",
    ]))
    upload_dir = root / "uploads"
    if upload_dir.exists():
        csv_paths.extend(_latest_matching_files(upload_dir, [
            "stage2_full_migration_link_map_*.csv",
            "*_app_dependencies.csv",
            "*_flavormap.csv",
            "*_blockmap.csv",
            "*_lbmap.csv",
        ]))
    loaded: Dict[str, Any] = {"source_artifacts": [], "missing_artifacts": []}
    for path in paths:
        data = _read_json(path)
        if data:
            loaded[str(path.relative_to(root))] = data
            loaded["source_artifacts"].append(str(path))
        else:
            loaded["missing_artifacts"].append(str(path))
    for path in csv_paths:
        rows = _read_csv(path)
        if rows:
            loaded[str(path.relative_to(root))] = rows
            loaded["source_artifacts"].append(str(path))
        else:
            loaded["missing_artifacts"].append(str(path))
    return loaded


def _infer_workload_type(row: Dict[str, Any]) -> str:
    explicit = _first(row, "workload_type", "resource_type", "source_type", "source_resource_type", "system_type", "Dependency Type", default="")
    text = " ".join(_safe_str(_first(row, key, default="")) for key in (
        "vm_name", "target_server_name", "target_flex_vm", "flex_name", "target_vm_name",
        "resource_name", "server_name", "source_vm", "source_name", "Source Hostname",
        "Target Hostname", "Source Stack", "Target Stack", "service_type", "datastore_type",
    )).lower()
    explicit_text = _safe_str(explicit).lower()
    db_markers = ("database", " db", "db-", "-db", "_db", "mysql", "mariadb", "postgres", "pgsql", "mongodb", "mongo", "mssql", "oracle", "percona", "redis")
    app_markers = ("app", "api", "web", "nginx", "apache", "httpd", "tomcat", "node", "java", "frontend", "backend")
    if "database" in explicit_text or explicit_text in {"db", "database_instance", "ha_database_group"} or any(marker in text for marker in db_markers):
        return "database_server"
    if "app" in explicit_text or "web" in explicit_text or any(marker in text for marker in app_markers):
        return "app_server"
    if explicit_text in {"server", "cloud_server", "compute"}:
        return "app_server"
    return _safe_str(explicit or "app_server")


def _is_validation_candidate(row: Dict[str, Any]) -> bool:
    resource_type = _safe_str(_first(row, "resource_type", "source_resource_type", "service_type", default="")).lower()
    if resource_type in {
        "floating_ip", "volume", "block_storage", "network", "subnet", "router",
        "security_group", "keypair", "load_balancer", "listener", "pool", "pool_member",
    }:
        return False
    if resource_type in {"server", "cloud_server", "database_instance", "ha_database_group", "compute"}:
        return True
    target_keys = {
        "target_server_name", "target_flex_vm", "flex_name", "target_vm_name", "Target Hostname",
        "flex_id", "target_instance_id", "target_server_id", "flex_private_ip", "target_ip",
        "target_region", "target_flavor_name", "recommended_target_image_name",
    }
    if any(_first(row, key, default="") for key in target_keys):
        return True
    dependency_keys = {"Source Hostname", "Target Hostname", "Source Stack", "Target Stack"}
    if any(_first(row, key, default="") for key in dependency_keys):
        return True
    return False


def _target_from_row(row: Dict[str, Any]) -> Dict[str, Any]:
    vm_name = _first(
        row,
        "target_server_name", "target_flex_vm", "flex_name", "target_vm_name", "Target Hostname",
        "vm_name", "resource_name", "server_name", "source_vm", "source_name", "source_resource", "name",
        default="",
    )
    instance_id = _first(
        row,
        "flex_id", "target_instance_id", "instance_id", "target_server_id", "resource_id",
        "server_id", "source_server_id", "source_resource_id", "id",
        default="",
    )
    target_ip = _first(row, "flex_private_ip", "target_ip", "private_ip", "fixed_ip", "flex_floating_ip", "public_ip", "ip", default="")
    workload_type = _infer_workload_type(row)
    return {
        "selected": False,
        "vm_name": _safe_str(vm_name or instance_id or "unknown-vm"),
        "instance_id": _safe_str(instance_id),
        "target_cloud": _safe_str(_first(row, "target_cloud", "cloud", default="FLEX") or "FLEX"),
        "target_region": _safe_str(_first(row, "target_region", "region", default="")),
        "target_ip": _safe_str(target_ip),
        "workload_type": workload_type,
        "source_vm_name": _safe_str(_first(row, "source_vm_name", "source_vm", "source_name", "Source Hostname", "resource_name", "server_name", "source_resource", "name", default="")),
        "source_instance_id": _safe_str(_first(row, "source_instance_id", "source_server_id", "server_id", "source_resource_id", "resource_id", default="")),
        "source_ip": _safe_str(_first(row, "source_ip", "rollback_value", default="")),
        "expected_mounts": row.get("expected_mounts") or row.get("mounts") or [],
        "expected_services": row.get("expected_services") or row.get("services") or [],
        "endpoint": _safe_str(_first(row, "endpoint", "app_endpoint", "target_endpoint", "url", "health_url", default="")),
        "db_test_command": _safe_str(_first(row, "db_test_command", "database_validation_command", default="")),
        "security_groups": row.get("security_groups") or [],
        "raw": row,
    }


def build_health_validation_targets(stage2_data: dict) -> list[dict]:
    stage2_data = stage2_data or {}
    targets: List[Dict[str, Any]] = []
    for key, payload in stage2_data.items():
        if key in {"source_artifacts", "missing_artifacts"}:
            continue
        rows = _as_items(payload)
        for row in rows:
            if not _is_validation_candidate(row):
                continue
            target = _target_from_row(row)
            if target["instance_id"] or target["target_ip"] or target["vm_name"]:
                targets.append(target)
    seen = set()
    deduped = []
    for target in targets:
        key = (target.get("instance_id"), target.get("target_ip"), target.get("vm_name"))
        if key in seen:
            continue
        seen.add(key)
        deduped.append(target)
    return deduped


def _check(status: str, details: Any = "") -> Dict[str, Any]:
    return {"status": status, "details": details}


def evaluate_cloud_status(target: dict) -> dict:
    return _check("PASS" if target.get("instance_id") else "NEEDS INPUT", "Target FLEX instance ID present." if target.get("instance_id") else "Target instance ID missing.")


def evaluate_boot_status(target: dict) -> dict:
    raw = target.get("raw") or {}
    status = str(_first(raw, "cloud_status", "boot_status", "status", "vm_status", default="")).upper()
    if status in {"ACTIVE", "PASS", "SUCCESS"}:
        return _check("PASS", "VM status is active/pass in imported artifact.")
    if status:
        return _check("WARNING", f"Imported VM status is {status}; verify target boot state.")
    return _check("NEEDS INPUT", "No target VM boot status found in imported artifacts.")


def evaluate_network_status(target: dict) -> dict:
    return _check("PASS" if target.get("target_ip") else "NEEDS INPUT", "Target IP present." if target.get("target_ip") else "Target IP missing.")


def evaluate_access_status(target: dict) -> dict:
    if target.get("target_ip"):
        return _check("WARNING", "Dry run generated SSH/RDP reachability commands; execute read-only checks to prove access.")
    return _check("NEEDS INPUT", "Target IP required for SSH/RDP reachability.")


def evaluate_volume_status(target: dict) -> dict:
    raw = target.get("raw") or {}
    value = _first(raw, "volume_status", "volume_id", "volume_count", "volumes", default="")
    return _check("PASS" if value else "SKIPPED", value or "No attached volume evidence found.")


def evaluate_mount_status(target: dict) -> dict:
    mounts = target.get("expected_mounts") or []
    return _check("WARNING" if mounts else "SKIPPED", mounts or "No expected mount path supplied.")


def evaluate_service_status(target: dict) -> dict:
    services = target.get("expected_services") or []
    return _check("WARNING", services or "Generated common nginx/apache/postgres/mysql/mongo/redis read-only service checks.")


def evaluate_app_status(target: dict) -> dict:
    endpoint = target.get("endpoint")
    workload = str(target.get("workload_type") or "").lower()
    if "db" in workload or "database" in workload:
        return _check("SKIPPED", "Database workload; application endpoint check not required unless supplied.")
    return _check("WARNING" if endpoint else "NEEDS INPUT", endpoint or "Application/server target imported; supply health endpoint or execute generated service checks.")


def evaluate_db_status(target: dict) -> dict:
    workload = str(target.get("workload_type") or "").lower()
    if "db" in workload or "database" in workload:
        command = target.get("db_test_command")
        if command:
            return _check("WARNING", "Read-only DB validation command supplied; execute it and attach evidence.")
        return _check("NEEDS INPUT", "Database target imported; provide explicit read-only DB command/evidence before UAT sign-off.")
    return _check("SKIPPED", "No database workload hint found.")


def evaluate_security_status(target: dict) -> dict:
    return _check("WARNING", "Dry run generated port inventory commands; compare open ports to expected list.")


def _latest_db_migration_evidence() -> Dict[str, Any]:
    root = repo_root()
    candidates = []
    for base, patterns in (
        (Path("/tmp/db_mig_v2"), ["db_report_*.html", "cmp_*.tsv"]),
        (root / "outputs" / "migration", ["db_migration_log.txt", "migration_summary.json", "*db*report*", "*db*comparison*"]),
        (root / ".tmp_runs", ["*db*report*", "*db*comparison*", "*db*migration*"]),
    ):
        if not base.exists():
            continue
        for pattern in patterns:
            candidates.extend([p for p in base.glob(pattern) if p.is_file()])
    candidates.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    evidence = {"artifacts": [str(p) for p in candidates[:5]], "status": "NEEDS INPUT", "notes": "No Stage 2 DB migration comparison evidence found."}
    for path in candidates[:5]:
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")[:250000].upper()
        except Exception:
            text = ""
        if "FAIL" in text or "DIFFERENCES FOUND" in text:
            return {"artifacts": evidence["artifacts"], "status": "WARNING", "notes": f"Stage 2 DB evidence found with failures/differences: {path}"}
        if "PASS" in text or "COMPARISON REPORT" in text or "MIGRATION" in text:
            evidence["status"] = "PASS"
            evidence["notes"] = f"Stage 2 DB migration evidence found: {path}"
            break
    return evidence


def _checkpoint(checkpoint_id: str, tier: str, name: str, objective: str, command: str, expected: str, status: str, evidence: str, owner: str, notes: str = "") -> Dict[str, Any]:
    return {
        "checkpoint_id": checkpoint_id,
        "tier": tier,
        "checkpoint_name": name,
        "objective": objective,
        "command_or_method": command,
        "expected_result": expected,
        "status": status,
        "evidence_source": evidence,
        "owner": owner,
        "notes": notes,
    }


def build_uat_checkpoints(target: dict) -> List[Dict[str, Any]]:
    ip = target.get("target_ip") or "<target_ip>"
    endpoint = target.get("endpoint") or f"https://{ip}"
    workload = str(target.get("workload_type") or "").lower()
    is_db = "db" in workload or "database" in workload
    db_evidence = _latest_db_migration_evidence() if is_db else {"artifacts": [], "status": "SKIPPED", "notes": ""}
    db_evidence_ref = "; ".join(db_evidence.get("artifacts") or []) or "Stage 2 DB migration comparison report required."
    checkpoints: List[Dict[str, Any]] = []

    if not is_db:
        checkpoints.extend([
            _checkpoint("frontend-port-80-443", "frontend", "HTTP/HTTPS port reachability", "Confirm the migrated app listener is reachable on expected frontend ports.", f"nc -zv {ip} 80; nc -zv {ip} 443; nc -zv {ip} 8080", "Expected frontend ports are open; unused ports are documented.", "NEEDS INPUT" if ip == "<target_ip>" else "WARNING", "Generated post-migration health commands.", "Application/SRE Team"),
            _checkpoint("frontend-homepage", "frontend", "Homepage or health URL", "Validate the primary UI or health route loads from FLEX.", f"curl -k -I --max-time 10 {endpoint!r}; curl -k -sS --max-time 10 {endpoint!r} | head", "HTTP 200/2xx/3xx, no maintenance page, response served by FLEX.", "WARNING", "UAT operator/browser evidence.", "Application Owner"),
            _checkpoint("frontend-tls-cert", "frontend", "TLS certificate and hostname", "Confirm HTTPS certificate/SNI/hostname are valid after migration.", f"echo | openssl s_client -servername <fqdn> -connect {ip}:443 2>/dev/null | openssl x509 -noout -subject -issuer -dates", "Certificate chain is valid, hostname matches, expiry acceptable.", "NEEDS INPUT", "Certificate or browser security evidence.", "Application/SRE Team"),
            _checkpoint("frontend-static-assets", "frontend", "Static asset loading", "Confirm CSS/JS/images load from FLEX without mixed-content or 404 errors.", "Browser devtools network export or curl key static asset URLs.", "No broken critical assets; no mixed-content blocking.", "NEEDS INPUT", "Browser HAR/screenshot.", "Application Owner"),
            _checkpoint("frontend-login-session", "frontend", "Login/session smoke test", "Validate login page, auth redirect, session cookie, logout, and role landing page.", "Manual UAT login with test user; capture timestamp and user/role.", "Login succeeds and role-based landing page is correct.", "NEEDS INPUT", "UAT sign-off screenshot or test transcript.", "Application Owner"),
            _checkpoint("frontend-critical-journey", "frontend", "Critical user journey", "Run the top business transaction for this app on FLEX.", "Manual/scripted UAT journey, for example search/create/read/export with test data.", "Business flow completes and generated output is correct.", "NEEDS INPUT", "UAT evidence from application owner.", "Application Owner"),
            _checkpoint("frontend-performance", "frontend", "Frontend latency smoke", "Compare page load and response latency to baseline.", f"curl -k -w 'time_total=%{{time_total}} status=%{{http_code}}\\n' -o /dev/null -sS {endpoint!r}", "Latency is within accepted threshold or variance is approved.", "WARNING", "curl/browser timing evidence.", "Application/SRE Team"),
        ])
        checkpoints.extend([
            _checkpoint("api-health", "api", "API health endpoint", "Validate backend/API health route on FLEX.", f"curl -k -sS --max-time 10 {endpoint.rstrip('/')}/api/health || curl -k -sS --max-time 10 {endpoint.rstrip('/')}/health", "2xx response with healthy dependencies or documented warnings.", "WARNING", "Generated post-migration health commands.", "Application/SRE Team"),
            _checkpoint("api-auth", "api", "API authentication", "Confirm token/login/API key flow works after migration.", "curl auth endpoint with UAT credentials or run API collection.", "Token/session returned; unauthorized calls fail correctly.", "NEEDS INPUT", "API test collection output.", "Application Owner"),
            _checkpoint("api-read-only-crud", "api", "Read-only CRUD/API smoke", "Run safe API calls covering list/read/search and one approved test-data write if allowed.", "Postman/Newman/k6/pytest API collection against FLEX base URL.", "Expected status codes and payload schemas match pre-migration behavior.", "NEEDS INPUT", "API test report.", "Application Owner"),
            _checkpoint("api-dependencies", "api", "Upstream/downstream dependency checks", "Validate API can reach required DB, cache, queue, identity, third-party services.", f"ssh ubuntu@{ip!r} 'ss -tulpn; systemctl --no-pager --type=service --state=running; journalctl -p err -n 50 --no-pager'", "No dependency connection errors in app logs.", "WARNING", "Service/log evidence.", "Application/SRE Team"),
            _checkpoint("api-headers-cors", "api", "Headers, CORS, and security behavior", "Check CORS, redirects, security headers, cookies, and error responses.", f"curl -k -I --max-time 10 {endpoint!r}", "Headers match application requirements; no unexpected insecure behavior.", "NEEDS INPUT", "curl/Postman evidence.", "Security/App Team"),
            _checkpoint("api-logs-errors", "api", "Backend logs and error rate", "Review recent backend logs during UAT traffic.", f"ssh ubuntu@{ip!r} 'journalctl -p err -n 100 --no-pager; tail -n 100 /var/log/nginx/error.log 2>/dev/null || true'", "No new critical errors, stack traces, failed DB auth, or integration failures.", "WARNING", "Log excerpt.", "Application/SRE Team"),
        ])

    if is_db:
        checkpoints.extend([
            _checkpoint("db-stage2-migration-result", "database", "Stage 2 DB migration result", "Reuse the final DB migration comparison result from Stage 2.", "Review latest /tmp/db_mig_v2/db_report_*.html or migration DB report.", "All required DB comparison checks PASS, or differences are approved.", db_evidence.get("status", "NEEDS INPUT"), db_evidence_ref, "DBA Team", db_evidence.get("notes", "")),
            _checkpoint("db-connectivity", "database", "DB connectivity smoke", "Confirm FLEX DB accepts read-only connection.", f"psql -h {ip} -U <db_user> -d <db_name> -c 'SELECT now();' || mysql -h {ip} -u <db_user> -e 'SELECT NOW();' || mongosh --host {ip} --eval 'db.adminCommand({{ ping: 1 }})'", "Connection succeeds with approved UAT credentials.", "NEEDS INPUT" if ip == "<target_ip>" else "WARNING", "DBA command output.", "DBA Team"),
            _checkpoint("db-row-counts", "database", "Row count/table parity", "Validate source and FLEX table row counts from migration output.", "Use Stage 2 DB comparison report row-count/table-status sections.", "No unexplained row-count differences.", db_evidence.get("status", "NEEDS INPUT"), db_evidence_ref, "DBA Team"),
            _checkpoint("db-schema-objects", "database", "Schema/object parity", "Validate databases, tables, columns, indexes, views, triggers, routines, events.", "Use Stage 2 DB comparison report schema/object sections.", "Schema and object inventory match or exceptions are approved.", db_evidence.get("status", "NEEDS INPUT"), db_evidence_ref, "DBA Team"),
            _checkpoint("db-users-grants", "database", "Users and grants", "Confirm DB users, grants, roles, and app credentials are valid on FLEX.", "Review Stage 2 grants comparison and run read-only permission check.", "Application service account has expected least-privilege access.", "NEEDS INPUT", "DBA evidence.", "DBA/Security Team"),
            _checkpoint("db-jobs-replication", "database", "Jobs/replication/lag", "Validate scheduled jobs, replication state, and lag before cutover.", "SHOW SLAVE/REPLICA STATUS, pg_stat_replication, SQL Agent/jobs, cron/app scheduler checks as applicable.", "Lag is zero or accepted; jobs are enabled in the correct environment.", "NEEDS INPUT", "DBA evidence.", "DBA Team"),
            _checkpoint("db-backup-rollback", "database", "Backup and rollback point", "Confirm backup/snapshot and rollback point before UAT sign-off.", "Review backup job, snapshot ID, restore point, and rollback plan.", "Recoverable rollback point exists and is documented.", "NEEDS INPUT", "Backup/snapshot evidence.", "DBA/Cloud Admin Team"),
        ])
    return checkpoints


def calculate_overall_health_status(checks: dict) -> str:
    statuses = [str((v or {}).get("status", "")).upper() for v in (checks or {}).values()]
    if any(s == "FAIL" for s in statuses):
        return "FAILED"
    if any(s in {"NEEDS INPUT"} for s in statuses):
        return "NOT READY"
    if any(s in {"WARNING", "PARTIAL"} for s in statuses):
        return "PARTIAL SUCCESS"
    return "SUCCESS"


def _risk(overall: str) -> str:
    if overall == "SUCCESS":
        return "Low"
    if overall == "PARTIAL SUCCESS":
        return "Medium"
    return "High"


def run_health_validation_dry_run(targets: list[dict]) -> list[dict]:
    results: List[Dict[str, Any]] = []
    for target in targets or []:
        checks = {
            "cloud": evaluate_cloud_status(target),
            "boot": evaluate_boot_status(target),
            "network": evaluate_network_status(target),
            "access": evaluate_access_status(target),
            "root_disk": _check("WARNING", "Dry run generated root disk validation commands."),
            "volumes": evaluate_volume_status(target),
            "mounts": evaluate_mount_status(target),
            "services": evaluate_service_status(target),
            "application": evaluate_app_status(target),
            "database": evaluate_db_status(target),
            "security": evaluate_security_status(target),
        }
        overall = calculate_overall_health_status(checks)
        results.append({
            "selected": False,
            "vm_name": target.get("vm_name", ""),
            "instance_id": target.get("instance_id", ""),
            "target_cloud": target.get("target_cloud", "FLEX"),
            "target_region": target.get("target_region", ""),
            "target_ip": target.get("target_ip", ""),
            "workload_type": target.get("workload_type", ""),
            "checks": checks,
            "overall_status": overall,
            "risk_level": _risk(overall),
            "recommended_action": "Execute read-only validation commands and resolve failed checks." if overall != "SUCCESS" else "Ready for UAT evidence export.",
            "notes": ["Dry-run/report-only health validation. No changes executed."],
            "source_vm_name": target.get("source_vm_name", ""),
            "source_instance_id": target.get("source_instance_id", ""),
            "source_ip": target.get("source_ip", ""),
            "uat_checkpoints": build_uat_checkpoints(target),
        })
    return results


def generate_health_check_commands(targets: list[dict]) -> str:
    lines = ["#!/usr/bin/env bash", "set -o pipefail", "", "# Dry-run generated read-only post-migration health checks.", ""]
    for target in targets or []:
        name = target.get("vm_name") or target.get("instance_id") or target.get("target_ip") or "target"
        instance_id = target.get("instance_id", "")
        ip = target.get("target_ip", "")
        lines.extend([f"echo '===== {name} ====='"])
        if instance_id:
            lines.append(f"openstack server show {instance_id!r} -f json || true")
            lines.append(f"openstack volume list --server {instance_id!r} -f json || true")
        lines.append("openstack server list --long -f json || true")
        lines.append("openstack floating ip list -f json || true")
        if ip:
            lines.extend([
                f"ssh -o BatchMode=yes -o ConnectTimeout=10 ubuntu@{ip!r} 'hostname; hostname -I; ip route; df -h; lsblk; cat /etc/fstab; systemctl --no-pager --type=service --state=running; ss -tulpn; ps aux' || true",
                f"ssh -o BatchMode=yes -o ConnectTimeout=10 ubuntu@{ip!r} 'systemctl is-active nginx || true; systemctl is-active apache2 || true; systemctl is-active httpd || true; systemctl is-active postgresql || true; systemctl is-active mysql || true; systemctl is-active mongod || true; systemctl is-active redis || true' || true",
            ])
        endpoint = target.get("endpoint") or (f"https://{ip}/health" if ip else "")
        if endpoint:
            lines.append(f"curl -k -I --max-time 10 {endpoint!r} || true")
            lines.append(f"curl -k -sS --max-time 10 {endpoint!r} || true")
        workload = str(target.get("workload_type") or "").lower()
        if "db" in workload or "database" in workload:
            db_command = target.get("db_test_command")
            if db_command:
                lines.append(f"{db_command} || true")
            elif ip:
                lines.extend([
                    "# Add credentials before running one of these read-only DB smoke checks:",
                    f"# psql -h {ip} -U <db_user> -d <db_name> -c 'SELECT now();' || true",
                    f"# mysql -h {ip} -u <db_user> -e 'SELECT NOW();' || true",
                    f"# mongosh --host {ip} --eval 'db.adminCommand({{ ping: 1 }})' || true",
                ])
            else:
                lines.append("# Database target has no IP yet; add target_ip/flex_private_ip before DB smoke validation.")
        lines.append("")
    return "\n".join(lines) + "\n"


def _summary(results: List[Dict[str, Any]]) -> Dict[str, int]:
    return {
        "total_vms": len(results or []),
        "success": sum(1 for r in results if r.get("overall_status") == "SUCCESS"),
        "partial_success": sum(1 for r in results if r.get("overall_status") == "PARTIAL SUCCESS"),
        "failed": sum(1 for r in results if r.get("overall_status") == "FAILED"),
        "not_ready": sum(1 for r in results if r.get("overall_status") == "NOT READY"),
    }


def _table_row(result: Dict[str, Any]) -> Dict[str, Any]:
    checks = result.get("checks") or {}
    return {
        "selected": result.get("selected", False),
        "vm_name": result.get("vm_name", ""),
        "instance_id": result.get("instance_id", ""),
        "target_cloud": result.get("target_cloud", "FLEX"),
        "target_region": result.get("target_region", ""),
        "target_ip": result.get("target_ip", ""),
        "workload_type": result.get("workload_type", ""),
        "cloud_status": (checks.get("cloud") or {}).get("status", ""),
        "boot_status": (checks.get("boot") or {}).get("status", ""),
        "network_status": (checks.get("network") or {}).get("status", ""),
        "access_status": (checks.get("access") or {}).get("status", ""),
        "root_disk_status": (checks.get("root_disk") or {}).get("status", ""),
        "volume_status": (checks.get("volumes") or {}).get("status", ""),
        "mount_status": (checks.get("mounts") or {}).get("status", ""),
        "service_status": (checks.get("services") or {}).get("status", ""),
        "app_status": (checks.get("application") or {}).get("status", ""),
        "db_status": (checks.get("database") or {}).get("status", ""),
        "security_status": (checks.get("security") or {}).get("status", ""),
        "overall_status": result.get("overall_status", ""),
        "risk_level": result.get("risk_level", ""),
        "recommended_action": result.get("recommended_action", ""),
        "uat_checkpoint_count": len(result.get("uat_checkpoints") or []),
        "notes": " | ".join(result.get("notes") or []),
    }


def _checkpoint_rows(results: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    for result in results or []:
        for checkpoint in result.get("uat_checkpoints") or []:
            rows.append({
                "vm_name": result.get("vm_name", ""),
                "instance_id": result.get("instance_id", ""),
                "target_ip": result.get("target_ip", ""),
                "workload_type": result.get("workload_type", ""),
                "overall_status": result.get("overall_status", ""),
                **checkpoint,
            })
    return rows


def _markdown(payload: Dict[str, Any]) -> str:
    lines = ["# Post-Migration Health Validation Report", "", f"Created: {payload.get('created_at', '')}", ""]
    summary = payload.get("summary") or {}
    for key, value in summary.items():
        lines.append(f"- {key}: {value}")
    lines.append("")
    for result in payload.get("results", []):
        lines.extend([f"## {result.get('vm_name') or result.get('instance_id') or 'Target VM'}", "", f"- Overall: {result.get('overall_status', '')}", f"- Risk: {result.get('risk_level', '')}", f"- Target: {result.get('target_region', '')} / {result.get('target_ip', '')}", ""])
        checkpoints = result.get("uat_checkpoints") or []
        if checkpoints:
            lines.append("### UAT Checkpoints")
            for checkpoint in checkpoints:
                lines.append(f"- [{checkpoint.get('tier')}] {checkpoint.get('checkpoint_name')}: {checkpoint.get('status')}")
            lines.append("")
    return "\n".join(lines)


def write_health_validation_artifacts(results: list[dict]) -> dict:
    dirs = ensure_output_dirs()
    results = results or []
    payload = {
        "stage": "stage_3_validation_uat",
        "feature": "post_migration_health_validation",
        "created_at": _now(),
        "source_artifacts": [],
        "summary": _summary(results),
        "results": results,
    }
    commands = generate_health_check_commands(results)
    md = _markdown(payload)
    artifacts: Dict[str, str] = {}
    for base in (dirs["uat"], dirs["tmp"]):
        json_path = base / "post_migration_health_report.json"
        csv_path = base / "post_migration_health_report.csv"
        md_path = base / "post_migration_health_report.md"
        sh_path = base / "post_migration_health_commands.sh"
        checkpoint_json_path = base / "uat_checkpoint_matrix.json"
        checkpoint_csv_path = base / "uat_checkpoint_matrix.csv"
        checkpoint_md_path = base / "uat_checkpoint_matrix.md"
        json_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        with csv_path.open("w", encoding="utf-8", newline="") as handle:
            fieldnames = list(_table_row({}).keys())
            writer = csv.DictWriter(handle, fieldnames=fieldnames)
            writer.writeheader()
            for result in results:
                writer.writerow(_table_row(result))
        checkpoint_rows = _checkpoint_rows(results)
        checkpoint_json_path.write_text(json.dumps({"created_at": payload["created_at"], "checkpoints": checkpoint_rows}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        with checkpoint_csv_path.open("w", encoding="utf-8", newline="") as handle:
            fieldnames = [
                "vm_name", "instance_id", "target_ip", "workload_type", "overall_status",
                "checkpoint_id", "tier", "checkpoint_name", "objective", "command_or_method",
                "expected_result", "status", "evidence_source", "owner", "notes",
            ]
            writer = csv.DictWriter(handle, fieldnames=fieldnames)
            writer.writeheader()
            for row in checkpoint_rows:
                writer.writerow({key: row.get(key, "") for key in fieldnames})
        checkpoint_md = ["# UAT Checkpoint Matrix", "", f"Created: {payload['created_at']}", ""]
        for row in checkpoint_rows:
            checkpoint_md.append(f"- {row.get('vm_name')} [{row.get('tier')}] {row.get('checkpoint_name')}: {row.get('status')}")
        checkpoint_md_path.write_text("\n".join(checkpoint_md) + "\n", encoding="utf-8")
        md_path.write_text(md, encoding="utf-8")
        sh_path.write_text(commands, encoding="utf-8")
        try:
            sh_path.chmod(0o700)
        except OSError:
            pass
        artifacts[str(json_path.relative_to(repo_root()))] = str(json_path)
        artifacts[str(csv_path.relative_to(repo_root()))] = str(csv_path)
        artifacts[str(md_path.relative_to(repo_root()))] = str(md_path)
        artifacts[str(sh_path.relative_to(repo_root()))] = str(sh_path)
        artifacts[str(checkpoint_json_path.relative_to(repo_root()))] = str(checkpoint_json_path)
        artifacts[str(checkpoint_csv_path.relative_to(repo_root()))] = str(checkpoint_csv_path)
        artifacts[str(checkpoint_md_path.relative_to(repo_root()))] = str(checkpoint_md_path)
    return artifacts


def render_post_migration_health_validation() -> None:
    try:
        import streamlit as st  # type: ignore
    except Exception:
        return
    ss = st.session_state
    ss.setdefault("post_migration_health_results", [])
    ss.setdefault("post_migration_health_report_path", "")
    st.subheader("🩺 Post-Migration Health Validation")
    st.caption("Prove that migrated VMs, apps, databases, volumes, and network access are working correctly on target FLEX.")
    if st.button("📥 Import Stage 2 Migration Output"):
        ss["post_migration_health_targets"] = build_health_validation_targets(load_stage2_migration_outputs())
    if st.button("🩺 Run Health Validation"):
        ss["post_migration_health_results"] = run_health_validation_dry_run(ss.get("post_migration_health_targets") or [])
        write_health_validation_artifacts(ss["post_migration_health_results"])
    st.dataframe(ss.get("post_migration_health_results") or [], use_container_width=True)
