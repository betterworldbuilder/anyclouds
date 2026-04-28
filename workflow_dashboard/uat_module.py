from __future__ import annotations

import csv
import json
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

from flask import Blueprint, jsonify, request, send_from_directory

try:
    from services.ui.components.uat_autorun import autorun_summary, safe_result_for_issue
    from services.ui.lib.uat_log_parser import save_or_scan_findings, write_findings_csv
    from services.ui.lib.uat_runner import CSV_FIELDS as RUN_FIELDS
    from services.ui.lib.uat_runner import read_command_runs, run_uat_command
except Exception:
    # Keep UAT API available even when optional services.ui package is absent.
    RUN_FIELDS = [
        "id",
        "system_id",
        "system_name",
        "test_id",
        "test_name",
        "command",
        "status",
        "exit_code",
        "started_at",
        "completed_at",
        "duration_seconds",
        "timeout_seconds",
        "run_mode",
        "stdout",
        "stderr",
    ]

    def autorun_summary(_outputs: Path) -> Dict[str, Any]:
        return {"available": False, "reason": "services.ui unavailable", "runs": 0}

    def safe_result_for_issue(payload: Dict[str, Any]) -> Dict[str, Any]:
        return payload

    def save_or_scan_findings(_base_dir: Path, force: bool = False) -> List[Dict[str, Any]]:
        _ = force
        return []

    def write_findings_csv(path: Path, findings: List[Dict[str, Any]]) -> None:
        write_csv_rows(path, findings or [], ["severity", "code", "message", "source", "suggested_uat_test"])

    def read_command_runs(_outputs: Path, limit: int = 10000) -> List[Dict[str, Any]]:
        _ = limit
        return []

    def run_uat_command(*args, **kwargs) -> Dict[str, Any]:
        _ = (args, kwargs)
        now = datetime.now(timezone.utc).isoformat()
        return {
            "id": f"stub-{int(datetime.now(timezone.utc).timestamp())}",
            "status": "error",
            "exit_code": 127,
            "started_at": now,
            "completed_at": now,
            "duration_seconds": 0,
            "stdout": "",
            "stderr": "UAT runner unavailable: services.ui package is missing",
        }


DISCOVERY_FILES = {
    "apps_inventory.csv": "csv",
    "db_inventory.csv": "csv",
    "infra_topology.json": "json",
    "dependencies_map.json": "json",
    "performance_baseline.csv": "csv",
    "discovery_summary.json": "json",
}

MIGRATION_FILES = {
    "migrated_vm_list.csv": "csv",
    "image_conversion_log.txt": "txt",
    "boot_validation_results.csv": "csv",
    "network_mapping.json": "json",
    "db_migration_log.txt": "txt",
    "migration_summary.json": "json",
}

SCOPE_FIELDS = [
    "system_id",
    "system_type",
    "business_system_name",
    "tier",
    "source_host",
    "target_host",
    "target_ip",
    "owner",
    "dependencies",
    "criticality",
    "uat_status",
    "execution_mode",
    "ssh_user",
    "ssh_host",
    "ssh_key_path",
    "ssh_port",
    "notes",
]

ISSUE_FIELDS = [
    "issue_id",
    "linked_system",
    "linked_test",
    "severity",
    "owner",
    "status",
    "description",
    "evidence",
    "created_at",
    "updated_at",
]

CHECKLIST_CATEGORIES = [
    {
        "id": "access_login",
        "category": "Access & Login",
        "task_name": "Access and login validation",
        "description": "Confirm operators and users can reach and authenticate to the migrated target.",
        "command": "ssh ubuntu@<target_ip>\ncurl -I http://<target_ip>/",
    },
    {
        "id": "vm_boot_health",
        "category": "VM Boot Health",
        "task_name": "Boot, kernel, uptime, and system error check",
        "description": "Validate the target VM booted cleanly and has no active failed systemd units.",
        "command": "hostnamectl\nuname -a\nuptime\nsystemctl --failed\njournalctl -p err -n 50 --no-pager",
    },
    {
        "id": "network_connectivity",
        "category": "Network Connectivity",
        "task_name": "IP, route, SSH, and HTTP connectivity",
        "description": "Verify routes, interfaces, SSH reachability, and app port reachability.",
        "command": "ping -c 5 <target_ip>\nnc -zv <target_ip> 22\ncurl -v http://<target_ip>/\nip a\nip route",
    },
    {
        "id": "application_health",
        "category": "Application Health",
        "task_name": "Application health endpoint and service logs",
        "description": "Check app health endpoints, service status, and recent service logs.",
        "command": "curl http://<target_ip>/health\ncurl http://<target_ip>/api/health\nsystemctl status <service_name> --no-pager\njournalctl -u <service_name> -n 100 --no-pager",
    },
    {
        "id": "api_integration",
        "category": "API / Integration",
        "task_name": "API and integration reachability",
        "description": "Validate upstream/downstream APIs and integration ports.",
        "command": "curl -v http://<api_ip>:<port>/api/health\nnc -zv <api_ip> <port>",
    },
    {
        "id": "database_validation",
        "category": "Database Validation",
        "task_name": "Database connect and row-count smoke test",
        "description": "Confirm database connectivity and basic table counts on FLEX.",
        "command": "psql -h <db_ip> -U <db_user> -d <db_name> -c \"SELECT now();\"\npsql -h <db_ip> -U <db_user> -d <db_name> -c \"SELECT COUNT(*) FROM <table_name>;\"\nmysql -h <db_ip> -u <db_user> -p -e \"SHOW DATABASES;\"\nmysql -h <db_ip> -u <db_user> -p <db_name> -e \"SELECT COUNT(*) FROM <table_name>;\"",
    },
    {
        "id": "data_comparison",
        "category": "Data Comparison OSPC vs FLEX",
        "task_name": "Source and target data comparison",
        "description": "Compare exported source counts with FLEX migrated counts.",
        "command": "diff ./outputs/discovery/source_counts.csv ./outputs/migration/flex_counts.csv\npython scripts/compare_row_counts.py --source ./outputs/discovery/source_counts.csv --target ./outputs/migration/flex_counts.csv",
    },
    {
        "id": "reports_outputs",
        "category": "Reports / Emails / Outputs",
        "task_name": "Reports, scheduled jobs, and output checks",
        "description": "Validate reports, cron/mail jobs, generated output folders, and error logs.",
        "command": "ls -lah /var/reports/\njournalctl -u cron -n 100 --no-pager\ngrep -i \"error\\|failed\" /var/log/syslog | tail -50",
    },
    {
        "id": "permissions_roles",
        "category": "Permissions / Roles",
        "task_name": "User and filesystem permission review",
        "description": "Validate Linux users, groups, sudo rights, and application path ownership.",
        "command": "id <user>\ngroups <user>\nls -lah <app_path>\nsudo -l",
    },
    {
        "id": "performance_load_mobile_lag",
        "category": "Performance / Load / Mobile Lag",
        "task_name": "Performance, load, and mobile latency validation",
        "description": "Run synthetic load and record mobile app launch, login, page load, tap-to-response, and failed API calls.",
        "command": "curl -w \"@scripts/curl-format.txt\" -o /dev/null -s http://<target_ip>/\nab -n 1000 -c 50 http://<target_ip>/\nk6 run scripts/uat_load_test.js\nping -c 20 <target_ip>\niperf3 -c <target_ip>\n\nManual mobile lag instruction:\nOpen mobile app on Wi-Fi and 4G/5G.\nMeasure app launch time, login time, page load time, tap-to-response delay, and failed API calls.\nRecord result in ms/sec.",
    },
    {
        "id": "soak_stability",
        "category": "Soak / Stability",
        "task_name": "Soak and stability monitoring",
        "description": "Run a longer soak test while watching system load, memory, disk, and live errors.",
        "command": "k6 run scripts/uat_soak_test.js\nwatch -n 5 \"uptime && free -m && df -h\"\njournalctl -f",
    },
    {
        "id": "cutover_readiness",
        "category": "Cutover Readiness",
        "task_name": "Final rollback and cutover readiness check",
        "description": "Confirm rollback, DNS/LB change plan, sign-off, and no unresolved critical blockers.",
        "command": "# Manual instruction:\n# Confirm rollback plan, DNS/LB update window, monitoring owner, customer sign-off, and war-room contacts.\n# Mark this test Passed only when cutover can proceed safely.",
    },
]

PERFORMANCE_FIELDS = [
    "ospc_avg_response_ms",
    "flex_avg_response_ms",
    "ospc_p95_ms",
    "flex_p95_ms",
    "target_concurrent_users",
    "peak_concurrent_users_tested",
    "active_sessions_tested",
    "api_error_rate_percent",
    "db_avg_query_ms",
    "report_generation_seconds",
    "mobile_app_load_seconds",
    "mobile_tap_response_ms",
    "network_latency_ms",
    "upload_mbps",
    "download_mbps",
    "mobile_lag_status",
    "overall_performance_status",
]


@dataclass(frozen=True)
class UATPaths:
    base_dir: Path

    @property
    def outputs(self) -> Path:
        return self.base_dir / "outputs"

    @property
    def discovery(self) -> Path:
        return self.outputs / "discovery"

    @property
    def migration(self) -> Path:
        return self.outputs / "migration"

    @property
    def uat(self) -> Path:
        return self.outputs / "uat"

    def ensure(self) -> None:
        for path in (self.discovery, self.migration, self.uat):
            path.mkdir(parents=True, exist_ok=True)


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def read_csv_rows(path: Path) -> Tuple[List[Dict[str, str]], Optional[str]]:
    try:
        with path.open(newline="", encoding="utf-8-sig") as f:
            return [dict(row) for row in csv.DictReader(f)], None
    except Exception as exc:
        return [], str(exc)


def write_csv_rows(path: Path, rows: Iterable[Dict[str, Any]], fieldnames: List[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow({field: row.get(field, "") for field in fieldnames})


def read_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def artifact_preview(path: Path, kind: str) -> Any:
    if not path.exists():
        return ""
    if kind == "json":
        payload = json.loads(path.read_text(encoding="utf-8"))
        return payload
    if kind == "csv":
        rows, error = read_csv_rows(path)
        if error:
            raise ValueError(error)
        return rows[:20]
    return path.read_text(encoding="utf-8", errors="replace")[:5000]


def validate_artifact(path: Path, kind: str) -> Tuple[str, str, Any]:
    if not path.exists():
        return "Missing", f"{path.name} was not found. Run the producing stage or upload the file.", ""
    if not path.is_file():
        return "Invalid", f"{path.name} is not a regular file.", ""
    try:
        preview = artifact_preview(path, kind)
        if kind == "csv":
            rows, error = read_csv_rows(path)
            if error:
                return "Invalid", error, ""
            if not rows and path.stat().st_size <= 2:
                return "Invalid", "CSV has no usable header or data.", preview
        return "Loaded", "", preview
    except Exception as exc:
        return "Invalid", str(exc), ""


def scan_artifacts(paths: UATPaths) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    for stage, folder, required in (
        ("discovery", paths.discovery, DISCOVERY_FILES),
        ("migration", paths.migration, MIGRATION_FILES),
    ):
        for filename, kind in required.items():
            path = folder / filename
            status, warning, preview = validate_artifact(path, kind)
            rows.append({
                "stage": stage,
                "filename": filename,
                "kind": kind,
                "status": status,
                "warning": warning,
                "size_bytes": path.stat().st_size if path.exists() and path.is_file() else 0,
                "download_url": f"/api/uat/artifact/{stage}/{filename}" if path.exists() and path.is_file() else "",
                "preview": preview,
            })
    return rows


def normalize_scope_row(row: Dict[str, Any], idx: int) -> Dict[str, str]:
    system_id = str(row.get("system_id") or row.get("id") or f"scope-{idx:03d}")
    return {
        "system_id": system_id,
        "system_type": str(row.get("system_type") or row.get("type") or "App"),
        "business_system_name": str(row.get("business_system_name") or row.get("name") or row.get("app_name") or row.get("db_name") or ""),
        "tier": str(row.get("tier") or "Backend"),
        "source_host": str(row.get("source_host") or row.get("host") or row.get("hostname") or ""),
        "target_host": str(row.get("target_host") or ""),
        "target_ip": str(row.get("target_ip") or row.get("ip") or ""),
        "owner": str(row.get("owner") or ""),
        "dependencies": str(row.get("dependencies") or row.get("depends_on") or ""),
        "criticality": str(row.get("criticality") or "Secondary"),
        "uat_status": str(row.get("uat_status") or "Not Started"),
        "execution_mode": str(row.get("execution_mode") or "local"),
        "ssh_user": str(row.get("ssh_user") or "ubuntu"),
        "ssh_host": str(row.get("ssh_host") or row.get("target_ip") or ""),
        "ssh_key_path": str(row.get("ssh_key_path") or ""),
        "ssh_port": str(row.get("ssh_port") or "22"),
        "notes": str(row.get("notes") or ""),
    }


def prefill_scope(paths: UATPaths) -> List[Dict[str, str]]:
    rows: List[Dict[str, str]] = []
    app_rows, _ = read_csv_rows(paths.discovery / "apps_inventory.csv")
    for idx, row in enumerate(app_rows, 1):
        normalized = normalize_scope_row(row, idx)
        normalized["system_type"] = "App"
        normalized["tier"] = normalized["tier"] or "Backend"
        rows.append(normalized)
    db_rows, _ = read_csv_rows(paths.discovery / "db_inventory.csv")
    base = len(rows)
    for idx, row in enumerate(db_rows, 1):
        normalized = normalize_scope_row(row, base + idx)
        normalized["system_type"] = "DB"
        normalized["tier"] = "Database"
        rows.append(normalized)
    return rows


def load_scope(paths: UATPaths) -> List[Dict[str, str]]:
    path = paths.uat / "uat_scope.csv"
    rows, error = read_csv_rows(path)
    if error or not rows:
        rows = prefill_scope(paths)
        if rows:
            write_csv_rows(path, rows, SCOPE_FIELDS)
    return [normalize_scope_row(row, idx + 1) for idx, row in enumerate(rows)]


def default_checklist() -> List[Dict[str, Any]]:
    return [
        {
            **item,
            "status": "Not Started",
            "checked": False,
            "actual_result": "",
            "owner": "",
            "severity_if_failed": "Medium",
            "evidence": "",
        }
        for item in CHECKLIST_CATEGORIES
    ]


def load_checklist(paths: UATPaths) -> List[Dict[str, Any]]:
    current = read_json(paths.uat / "uat_checklist.json", [])
    by_id = {str(row.get("id")): row for row in current if isinstance(row, dict)}
    merged = []
    for template in default_checklist():
        saved = by_id.get(template["id"], {})
        merged.append({**template, **saved})
    return merged


def load_performance_baseline(paths: UATPaths) -> Dict[str, str]:
    rows, _ = read_csv_rows(paths.discovery / "performance_baseline.csv")
    if not rows:
        return {}
    return {str(k): str(v) for k, v in rows[0].items() if k}


def load_performance(paths: UATPaths) -> Dict[str, Any]:
    saved = read_json(paths.uat / "uat_performance.json", {})
    baseline = load_performance_baseline(paths)
    data = {field: "" for field in PERFORMANCE_FIELDS}
    for key in ("ospc_avg_response_ms", "ospc_p95_ms"):
        if baseline.get(key):
            data[key] = baseline[key]
    data.update(saved if isinstance(saved, dict) else {})
    return calculate_performance(data)


def as_float(value: Any) -> Optional[float]:
    try:
        if value is None or str(value).strip() == "":
            return None
        return float(str(value).strip())
    except Exception:
        return None


def pct_delta(source: Any, target: Any) -> Optional[float]:
    source_f = as_float(source)
    target_f = as_float(target)
    if source_f in (None, 0) or target_f is None:
        return None
    return ((target_f - source_f) / source_f) * 100


def calculate_performance(data: Dict[str, Any]) -> Dict[str, Any]:
    result = {field: data.get(field, "") for field in PERFORMANCE_FIELDS}
    result["delta_avg_response_percent"] = pct_delta(result.get("ospc_avg_response_ms"), result.get("flex_avg_response_ms"))
    result["delta_p95_percent"] = pct_delta(result.get("ospc_p95_ms"), result.get("flex_p95_ms"))

    ospc_p95 = as_float(result.get("ospc_p95_ms"))
    flex_p95 = as_float(result.get("flex_p95_ms"))
    error_rate = as_float(result.get("api_error_rate_percent")) or 0.0
    mobile_status = str(result.get("mobile_lag_status") or "").lower()

    status = "Review"
    if ospc_p95 is not None and flex_p95 is not None:
        status = "Pass" if flex_p95 <= ospc_p95 * 1.15 else "Fail"
    if error_rate > 1:
        status = "Fail"
    if mobile_status == "failed":
        status = "Fail"
    result["overall_performance_status"] = status
    return result


def load_issues(paths: UATPaths) -> List[Dict[str, str]]:
    rows, error = read_csv_rows(paths.uat / "uat_issues.csv")
    if error:
        return []
    return [{field: str(row.get(field, "")) for field in ISSUE_FIELDS} for row in rows]


def open_critical_issues(issues: List[Dict[str, str]]) -> List[Dict[str, str]]:
    closed = {"Fixed", "Accepted Risk"}
    return [i for i in issues if i.get("severity") == "Critical" and i.get("status") not in closed]


def test_passed(checklist: List[Dict[str, Any]], test_id: str) -> bool:
    for row in checklist:
        if row.get("id") == test_id:
            return row.get("status") == "Passed" or row.get("checked") is True
    return False


def calculate_readiness(scope: List[Dict[str, str]], checklist: List[Dict[str, Any]], performance: Dict[str, Any], issues: List[Dict[str, str]]) -> Dict[str, Any]:
    critical_scope = [row for row in scope if row.get("criticality") == "Critical"]
    critical_tested = all(row.get("uat_status") == "Passed" for row in critical_scope) if critical_scope else False
    critical_open = open_critical_issues(issues)
    accepted_risks = [i for i in issues if i.get("status") == "Accepted Risk"]
    required_tests = {
        "data_validation": test_passed(checklist, "data_comparison"),
        "app_health": test_passed(checklist, "application_health"),
        "database_validation": test_passed(checklist, "database_validation"),
        "reports_outputs": test_passed(checklist, "reports_outputs"),
    }
    perf_status = performance.get("overall_performance_status") or "Review"
    blockers: List[str] = []
    if not critical_tested:
        blockers.append("Not all critical systems are marked Passed.")
    if critical_open:
        blockers.append(f"{len(critical_open)} Critical issue(s) still open.")
    for label, ok in required_tests.items():
        if not ok:
            blockers.append(f"{label.replace('_', ' ').title()} is not passed.")
    if perf_status == "Fail":
        blockers.append("Performance status is Fail.")
    critical_failed_perf = [
        row for row in checklist
        if row.get("id") == "performance_load_mobile_lag"
        and row.get("status") == "Failed"
        and row.get("severity_if_failed") == "Critical"
    ]
    if critical_failed_perf:
        blockers.append("A critical performance / mobile lag checklist item failed.")

    if blockers:
        status = "Not Ready"
    elif accepted_risks or perf_status == "Review":
        status = "Ready with Accepted Risk"
    else:
        status = "Ready for Cutover"
    return {
        "status": status,
        "critical_systems": len(critical_scope),
        "critical_systems_tested": critical_tested,
        "critical_open_issues": len(critical_open),
        "accepted_risks": len(accepted_risks),
        "performance_status": perf_status,
        "required_tests": required_tests,
        "blockers": blockers,
        "generated_at": utc_now(),
    }


def write_reports(
    paths: UATPaths,
    readiness: Dict[str, Any],
    scope: List[Dict[str, str]],
    checklist: List[Dict[str, Any]],
    performance: Dict[str, Any],
    issues: List[Dict[str, str]],
    command_runs: Optional[List[Dict[str, Any]]] = None,
    log_findings: Optional[List[Dict[str, str]]] = None,
    artifacts: Optional[List[Dict[str, Any]]] = None,
) -> Dict[str, str]:
    command_runs = command_runs or []
    log_findings = log_findings or []
    artifacts = artifacts or []
    failed_commands = [run for run in command_runs if run.get("status") in {"Failed", "Timeout", "Blocked"}]
    summary = {
        "readiness": readiness,
        "scope_count": len(scope),
        "checklist_count": len(checklist),
        "issues_count": len(issues),
        "command_run_count": len(command_runs),
        "failed_command_count": len(failed_commands),
        "log_finding_count": len(log_findings),
        "performance": performance,
    }
    write_json(paths.uat / "uat_summary.json", summary)
    report_rows = []
    for row in checklist:
        report_rows.append({
            "section": "checklist",
            "name": row.get("category", ""),
            "status": row.get("status", ""),
            "owner": row.get("owner", ""),
            "severity": row.get("severity_if_failed", ""),
            "notes": row.get("actual_result", ""),
        })
    for issue in issues:
        report_rows.append({
            "section": "issue",
            "name": issue.get("issue_id", ""),
            "status": issue.get("status", ""),
            "owner": issue.get("owner", ""),
            "severity": issue.get("severity", ""),
            "notes": issue.get("description", ""),
        })
    write_csv_rows(paths.uat / "uat_report.csv", report_rows, ["section", "name", "status", "owner", "severity", "notes"])
    write_csv_rows(paths.uat / "uat_autorun_results.csv", command_runs, RUN_FIELDS)
    final_payload = {
        "artifacts": artifacts,
        "scope": scope,
        "command_runs": command_runs,
        "failed_commands": failed_commands,
        "log_findings": log_findings,
        "issues": issues,
        "performance": performance,
        "readiness": readiness,
        "recommended_next_actions": readiness.get("blockers", []) or ["Proceed with normal cutover controls and monitoring."],
    }
    write_json(paths.uat / "uat_final_report.json", final_payload)
    md = [
        "# UAT Readiness Report",
        "",
        f"Generated: {readiness['generated_at']}",
        f"Status: **{readiness['status']}**",
        "",
        "## Blockers",
        *(f"- {item}" for item in readiness.get("blockers", [])),
        "",
        "## Performance",
        f"- Overall: {performance.get('overall_performance_status', 'Review')}",
        f"- OSPC p95 ms: {performance.get('ospc_p95_ms', '')}",
        f"- FLEX p95 ms: {performance.get('flex_p95_ms', '')}",
        f"- API error rate %: {performance.get('api_error_rate_percent', '')}",
        "",
        "## Required Tests",
        *(f"- {key}: {'PASS' if val else 'NOT PASS'}" for key, val in readiness.get("required_tests", {}).items()),
        "",
    ]
    (paths.uat / "uat_readiness_report.md").write_text("\n".join(md) + "\n", encoding="utf-8")
    final_md = [
        "# Cloud Jumper UAT Final Report",
        "",
        f"Generated: {readiness['generated_at']}",
        f"Decision: **{readiness['status']}**",
        "",
        "## Loaded Artifacts",
        *(f"- {a.get('stage')}/{a.get('filename')}: {a.get('status')}" for a in artifacts),
        "",
        "## Systems Under Test",
        *(f"- {s.get('business_system_name')} ({s.get('system_type')}) -> {s.get('target_ip')} [{s.get('uat_status')}]" for s in scope),
        "",
        "## Command Execution History",
        *(f"- {r.get('started_at')} {r.get('linked_test')} {r.get('status')} rc={r.get('exit_code')} cmd={r.get('command')}" for r in command_runs[-50:]),
        "",
        "## Failed Commands",
        *(f"- {r.get('linked_test')} {r.get('status')}: {r.get('error') or r.get('stderr')}" for r in failed_commands),
        "",
        "## Migration Log Findings",
        *(f"- [{f.get('severity')}] {f.get('source_file')}: {f.get('message')}" for f in log_findings[:100]),
        "",
        "## Issues",
        *(f"- [{i.get('severity')}] {i.get('issue_id')} {i.get('status')}: {i.get('description')}" for i in issues),
        "",
        "## Performance",
        f"- Overall: {performance.get('overall_performance_status', 'Review')}",
        f"- OSPC p95 ms: {performance.get('ospc_p95_ms', '')}",
        f"- FLEX p95 ms: {performance.get('flex_p95_ms', '')}",
        f"- API error rate %: {performance.get('api_error_rate_percent', '')}",
        "",
        "## Recommended Next Actions",
        *(f"- {item}" for item in final_payload["recommended_next_actions"]),
        "",
    ]
    (paths.uat / "uat_final_report.md").write_text("\n".join(final_md) + "\n", encoding="utf-8")
    return {
        "summary": "/api/uat/artifact/uat/uat_summary.json",
        "csv": "/api/uat/artifact/uat/uat_report.csv",
        "markdown": "/api/uat/artifact/uat/uat_readiness_report.md",
        "autorun_csv": "/api/uat/artifact/uat/uat_autorun_results.csv",
        "log_findings_csv": "/api/uat/artifact/uat/uat_log_findings.csv",
        "final_markdown": "/api/uat/artifact/uat/uat_final_report.md",
        "final_json": "/api/uat/artifact/uat/uat_final_report.json",
    }


def ensure_sample_files(paths: UATPaths) -> None:
    paths.ensure()
    samples: Dict[Path, str] = {
        paths.discovery / "apps_inventory.csv": "app_name,tier,source_host,owner,dependencies,criticality\ncustomer-portal,Frontend,ospc-web-01,app-owner,orders-db;auth-api,Critical\nbilling-api,Backend,ospc-api-01,api-owner,billing-db,Secondary\n",
        paths.discovery / "db_inventory.csv": "db_name,engine,source_host,owner,dependencies,criticality\norders-db,postgres,ospc-db-01,dba-owner,customer-portal,Critical\nbilling-db,mysql,ospc-db-02,dba-owner,billing-api,Secondary\n",
        paths.discovery / "infra_topology.json": json.dumps({"nodes": [], "edges": [], "note": "sample topology"}, indent=2) + "\n",
        paths.discovery / "dependencies_map.json": json.dumps({"dependencies": [{"from": "customer-portal", "to": "orders-db"}]}, indent=2) + "\n",
        paths.discovery / "performance_baseline.csv": "ospc_avg_response_ms,ospc_p95_ms,target_concurrent_users,network_latency_ms\n180,420,250,28\n",
        paths.discovery / "discovery_summary.json": json.dumps({"status": "sample", "apps": 2, "databases": 2}, indent=2) + "\n",
        paths.migration / "migrated_vm_list.csv": "name,source_host,target_host,target_ip,status\ncustomer-portal,ospc-web-01,flex-web-01,10.50.0.10,booted\norders-db,ospc-db-01,flex-db-01,10.50.0.20,booted\n",
        paths.migration / "image_conversion_log.txt": "Sample image conversion log: no failures recorded.\n",
        paths.migration / "boot_validation_results.csv": "target_host,target_ip,boot_status,ssh_status,notes\nflex-web-01,10.50.0.10,Passed,Passed,sample\nflex-db-01,10.50.0.20,Passed,Passed,sample\n",
        paths.migration / "network_mapping.json": json.dumps({"networks": [{"source": "ospc-private", "target": "flex-private"}]}, indent=2) + "\n",
        paths.migration / "db_migration_log.txt": "Sample DB migration log: row-count validation pending.\n",
        paths.migration / "migration_summary.json": json.dumps({"status": "sample", "migrated_vms": 2}, indent=2) + "\n",
    }
    for path, content in samples.items():
        if not path.exists():
            path.write_text(content, encoding="utf-8")


def create_uat_blueprint(base_dir: Path) -> Blueprint:
    paths = UATPaths(base_dir=base_dir)
    ensure_sample_files(paths)
    bp = Blueprint("uat", __name__)

    @bp.get("/api/uat/state")
    def uat_state():
        paths.ensure()
        artifacts = scan_artifacts(paths)
        scope = load_scope(paths)
        checklist = load_checklist(paths)
        performance = load_performance(paths)
        issues = load_issues(paths)
        readiness = calculate_readiness(scope, checklist, performance, issues)
        command_runs = read_command_runs(paths.outputs)
        log_findings = save_or_scan_findings(base_dir)
        return jsonify({
            "ok": True,
            "artifacts": artifacts,
            "scope": scope,
            "checklist": checklist,
            "performance": performance,
            "issues": issues,
            "readiness": readiness,
            "command_runs": command_runs,
            "autorun": autorun_summary(paths.outputs),
            "log_findings": log_findings,
            "paths": {
                "discovery": "./outputs/discovery",
                "migration": "./outputs/migration",
                "uat": "./outputs/uat",
            },
        })

    @bp.post("/api/uat/scope")
    def save_scope():
        rows = (request.get_json(silent=True) or {}).get("rows", [])
        normalized = [normalize_scope_row(row, idx + 1) for idx, row in enumerate(rows if isinstance(rows, list) else [])]
        write_csv_rows(paths.uat / "uat_scope.csv", normalized, SCOPE_FIELDS)
        return jsonify({"ok": True, "rows": normalized})

    @bp.post("/api/uat/checklist")
    def save_checklist():
        rows = (request.get_json(silent=True) or {}).get("rows", [])
        if not isinstance(rows, list):
            rows = []
        write_json(paths.uat / "uat_checklist.json", rows)
        return jsonify({"ok": True, "rows": rows})

    @bp.post("/api/uat/performance")
    def save_performance():
        payload = request.get_json(silent=True) or {}
        performance = calculate_performance(payload.get("performance", payload))
        write_json(paths.uat / "uat_performance.json", performance)
        return jsonify({"ok": True, "performance": performance})

    @bp.post("/api/uat/issues")
    def save_issues():
        rows = (request.get_json(silent=True) or {}).get("rows", [])
        if not isinstance(rows, list):
            rows = []
        now = utc_now()
        normalized = []
        for idx, row in enumerate(rows, 1):
            item = {field: str(row.get(field, "")) for field in ISSUE_FIELDS}
            item["issue_id"] = item["issue_id"] or f"UAT-{idx:03d}"
            item["created_at"] = item["created_at"] or now
            item["updated_at"] = now
            normalized.append(item)
        write_csv_rows(paths.uat / "uat_issues.csv", normalized, ISSUE_FIELDS)
        return jsonify({"ok": True, "rows": normalized})

    @bp.post("/api/uat/export")
    def export_uat():
        payload = request.get_json(silent=True) or {}
        if isinstance(payload.get("scope"), list):
            write_csv_rows(paths.uat / "uat_scope.csv", [normalize_scope_row(row, idx + 1) for idx, row in enumerate(payload["scope"])], SCOPE_FIELDS)
        if isinstance(payload.get("checklist"), list):
            write_json(paths.uat / "uat_checklist.json", payload["checklist"])
        if isinstance(payload.get("performance"), dict):
            write_json(paths.uat / "uat_performance.json", calculate_performance(payload["performance"]))
        if isinstance(payload.get("issues"), list):
            write_csv_rows(paths.uat / "uat_issues.csv", payload["issues"], ISSUE_FIELDS)
        scope = load_scope(paths)
        checklist = load_checklist(paths)
        performance = load_performance(paths)
        issues = load_issues(paths)
        readiness = calculate_readiness(scope, checklist, performance, issues)
        artifacts = scan_artifacts(paths)
        command_runs = read_command_runs(paths.outputs, limit=10000)
        log_findings = save_or_scan_findings(base_dir)
        reports = write_reports(paths, readiness, scope, checklist, performance, issues, command_runs, log_findings, artifacts)
        return jsonify({"ok": True, "readiness": readiness, "reports": reports})

    @bp.post("/api/uat/run-command")
    def run_command():
        payload = request.get_json(silent=True) or {}
        row = run_uat_command(
            paths.outputs,
            payload.get("command", ""),
            linked_system=payload.get("linked_system", ""),
            linked_test=payload.get("linked_test", ""),
            execution_mode=payload.get("execution_mode", "local"),
            ssh_user=payload.get("ssh_user", ""),
            ssh_host=payload.get("ssh_host", ""),
            ssh_key_path=payload.get("ssh_key_path", ""),
            ssh_port=payload.get("ssh_port", 22),
            timeout=payload.get("timeout", 30),
            confirmed=bool(payload.get("confirmed")),
        )
        return jsonify({"ok": True, "run": row})

    @bp.post("/api/uat/run-batch")
    def run_batch():
        payload = request.get_json(silent=True) or {}
        commands = payload.get("commands", [])
        if not isinstance(commands, list):
            commands = []
        stop_on_critical = bool(payload.get("stop_on_critical_failure"))
        results = []
        for item in commands:
            if not isinstance(item, dict):
                continue
            row = run_uat_command(
                paths.outputs,
                item.get("command", ""),
                linked_system=item.get("linked_system", payload.get("linked_system", "")),
                linked_test=item.get("linked_test", item.get("id", "")),
                execution_mode=item.get("execution_mode", payload.get("execution_mode", "local")),
                ssh_user=item.get("ssh_user", payload.get("ssh_user", "")),
                ssh_host=item.get("ssh_host", payload.get("ssh_host", "")),
                ssh_key_path=item.get("ssh_key_path", payload.get("ssh_key_path", "")),
                ssh_port=item.get("ssh_port", payload.get("ssh_port", 22)),
                timeout=item.get("timeout", payload.get("timeout", 30)),
                confirmed=bool(payload.get("confirmed")),
            )
            results.append(row)
            if stop_on_critical and row.get("status") in {"Failed", "Timeout", "Blocked"} and item.get("severity_if_failed") == "Critical":
                break
        return jsonify({"ok": True, "runs": results})

    @bp.get("/api/uat/log-findings")
    def get_log_findings():
        force = request.args.get("force") in {"1", "true", "yes"}
        findings = save_or_scan_findings(base_dir, force=force)
        return jsonify({"ok": True, "findings": findings})

    @bp.post("/api/uat/log-findings/action")
    def log_finding_action():
        payload = request.get_json(silent=True) or {}
        finding_id = str(payload.get("finding_id", ""))
        action = str(payload.get("action", ""))
        findings = save_or_scan_findings(base_dir)
        for finding in findings:
            if finding.get("finding_id") == finding_id:
                if action in {"Accepted", "False Positive"}:
                    finding["status"] = action
                if action == "Create Issue":
                    issues = load_issues(paths)
                    issue = {
                        **safe_result_for_issue({
                            "linked_system": finding.get("linked_system", ""),
                            "linked_test": finding.get("suggested_uat_test", ""),
                            "status": "Failed",
                            "command": finding.get("suggested_command", ""),
                            "stdout": "",
                            "stderr": finding.get("message", ""),
                            "error": "",
                        }),
                        "issue_id": f"UAT-{len(issues) + 1:03d}",
                        "severity": finding.get("severity", "Medium"),
                        "created_at": utc_now(),
                        "updated_at": utc_now(),
                    }
                    issues.append(issue)
                    write_csv_rows(paths.uat / "uat_issues.csv", issues, ISSUE_FIELDS)
                    finding["status"] = "Issue Created"
                break
        write_findings_csv(paths.uat / "uat_log_findings.csv", findings)
        return jsonify({"ok": True, "findings": findings, "issues": load_issues(paths)})

    @bp.get("/api/uat/artifact/<stage>/<path:filename>")
    def download_uat_artifact(stage: str, filename: str):
        safe_name = Path(filename).name
        folders = {"discovery": paths.discovery, "migration": paths.migration, "uat": paths.uat}
        folder = folders.get(stage)
        if not folder:
            return jsonify({"ok": False, "error": "invalid artifact stage"}), 400
        target = (folder / safe_name).resolve()
        try:
            if not target.is_relative_to(folder.resolve()) or not target.exists() or not target.is_file():
                return jsonify({"ok": False, "error": "file not found"}), 404
        except Exception:
            return jsonify({"ok": False, "error": "invalid path"}), 400
        return send_from_directory(str(target.parent), target.name, as_attachment=True)

    return bp
