#!/usr/bin/env python3
"""Cutover plan helpers for Stage 4.

The plan is generated from the same migrated target inventory used by
post-migration health validation, so every app/server and database target gets
an explicit cutover row before production traffic moves.
"""

from __future__ import annotations

import csv
import ipaddress
import json
import shlex
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List

from services.ui.pages.post_migration_health_validation import (
    build_health_validation_targets,
    load_stage2_migration_outputs,
)

TRAFFIC_SWITCH_STEPS = tuple(range(10, 101, 10))


def repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def ensure_output_dirs() -> Dict[str, Path]:
    root = repo_root()
    dirs = {"tmp": root / ".tmp_runs", "cutover": root / "outputs" / "cutover"}
    for path in dirs.values():
        path.mkdir(parents=True, exist_ok=True)
    return dirs


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _safe_str(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, (dict, list)):
        return json.dumps(value, sort_keys=True)
    return str(value)


def _safe_int(value: Any, default: int = 10) -> int:
    try:
        parsed = int(str(value).strip())
    except Exception:
        return default
    return max(0, min(100, parsed))


def _traffic_target_weight(value: Any, default: int = 10) -> int:
    parsed = _safe_int(value, default)
    if parsed in TRAFFIC_SWITCH_STEPS:
        return parsed
    return default if default in TRAFFIC_SWITCH_STEPS else 10


def _traffic_source_weight(value: Any, default: int = 10) -> int:
    return 100 - _traffic_target_weight(value, default)


def _sh(value: Any) -> str:
    return shlex.quote(_safe_str(value))


def _clean_endpoint_ip(value: Any) -> str:
    text = _safe_str(value).strip().strip('"\'')
    if not text or text.startswith('<') or text.endswith('>'):
        return ""
    token = text.replace(';', ',').split(',')[0].strip()
    token = token.split()[0] if token.split() else token
    try:
        ipaddress.ip_address(token)
    except ValueError:
        return ""
    return token


def _skip_cutover_reason(area: str, source_ip: str, target_ip: str) -> str:
    if not source_ip and not target_ip:
        return "source and target IPs are missing"
    if not source_ip:
        return "source IP is missing"
    if not target_ip:
        return "target FLEX IP is missing"
    return ""


def _haproxy_global_lines() -> list[str]:
    return [
        "global",
        "  daemon",
        "  maxconn 2048",
        "  stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners",
    ]


def _source_haproxy_install_cmd(remote_cfg: str) -> str:
    return (
        "sudo apt-get update -qq >/dev/null 2>&1 || true; "
        "sudo apt-get install -y haproxy socat >/dev/null 2>&1 || true; "
        f"sudo haproxy -c -f {remote_cfg}; "
        "sudo mkdir -p /etc/haproxy; "
        "sudo cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.pre-cutover.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true; "
        f"sudo install -m 0644 {remote_cfg} /etc/haproxy/haproxy.cfg; "
        "sudo systemctl enable haproxy; "
        "sudo systemctl reload haproxy || sudo systemctl restart haproxy"
    )


def _first_list_value(value: Any) -> str:
    text = _safe_str(value).strip()
    if not text:
        return ""
    return text.split(",")[0].strip()


def _lb_traffic_step_lines(pool_name: str) -> list[str]:
    lines = ["# Traffic switch steps after validation:"]
    for green in TRAFFIC_SWITCH_STEPS:
        blue = 100 - green
        lines.extend([
            f"# FLEX {green}% / source {blue}%:",
            f"# openstack loadbalancer member set --weight {green} {_sh(pool_name)} <green_flex_member_id>",
            f"# openstack loadbalancer member set --weight {blue} {_sh(pool_name)} <blue_source_member_id>",
        ])
    return lines


def _haproxy_traffic_step_lines() -> list[str]:
    lines = ["# Traffic switch steps after validation:"]
    for green in TRAFFIC_SWITCH_STEPS:
        blue = 100 - green
        lines.extend([
            f"# FLEX {green}% / source {blue}%:",
            f"# echo 'set server app_blue_green/green_flex weight {green}' | sudo socat stdio /run/haproxy/admin.sock",
            f"# echo 'set server app_blue_green/blue_source weight {blue}' | sudo socat stdio /run/haproxy/admin.sock",
        ])
    return lines


def _is_db(target: dict) -> bool:
    workload = str(target.get("workload_type") or "").lower()
    name = str(target.get("vm_name") or target.get("source_vm_name") or "").lower()
    return "database" in workload or "db" in workload or any(x in name for x in ("db", "mysql", "postgres", "pgsql", "mongo", "mssql", "oracle"))


def _default_db_port(name: Any) -> int:
    text = _safe_str(name).lower()
    if any(token in text for token in ("postgres", "pgsql")):
        return 5432
    if any(token in text for token in ("mysql", "mariadb", "percona")):
        return 3306
    if any(token in text for token in ("mongo", "mongodb")):
        return 27017
    if "mssql" in text or "sqlserver" in text:
        return 1433
    if "oracle" in text:
        return 1521
    if "redis" in text:
        return 6379
    return 5432


def _raw_hint(target: dict, *keys: str, default: str = "") -> str:
    raw = target.get("raw") or {}
    for key in keys:
        value = target.get(key)
        if value not in (None, ""):
            return _safe_str(value)
        if isinstance(raw, dict):
            value = raw.get(key)
            if value not in (None, ""):
                return _safe_str(value)
    return default


def _as_rows(payload: Any) -> List[Dict[str, Any]]:
    if isinstance(payload, list):
        return [row for row in payload if isinstance(row, dict)]
    if isinstance(payload, dict):
        for key in ("items", "results", "vms", "servers", "checks", "candidates", "links", "targets"):
            value = payload.get(key)
            if isinstance(value, list):
                return [row for row in value if isinstance(row, dict)]
    return []


def _first(row: Dict[str, Any], *keys: str, default: str = "") -> Any:
    for key in keys:
        value = row.get(key)
        if value not in (None, ""):
            return value
    return default


def _norm_key(value: Any) -> str:
    return _safe_str(value).strip().lower()


def _add_index_value(index: Dict[str, list], key: str, field: str, value: Any) -> None:
    norm = _norm_key(key)
    text = _safe_str(value).strip()
    if not norm or not text:
        return
    bucket = index.setdefault(norm, [])
    if text not in bucket:
        bucket.append(text)


def _row_keys(row: Dict[str, Any]) -> list[str]:
    keys = []
    for key in (
        "source_vm_name", "source_vm", "source_name", "source_server_name", "source_server_id",
        "source_instance_id", "Source Hostname", "source_resource", "server_name", "server_id",
        "target_server_name", "target_flex_vm", "target_vm_name", "target_server_id",
        "target_instance_id", "Target Hostname", "flex_name", "flex_id", "resource_name",
        "resource_id", "instance_id", "name", "id",
    ):
        value = row.get(key)
        if value not in (None, ""):
            keys.append(_safe_str(value))
    return keys


def _summarize(values: list[str], empty: str = "") -> str:
    unique = []
    for value in values or []:
        text = _safe_str(value).strip()
        if text and text not in unique:
            unique.append(text)
    if not unique:
        return empty
    if len(unique) <= 4:
        return ", ".join(unique)
    return ", ".join(unique[:4]) + f" (+{len(unique) - 4} more)"


def _scanner_kind(path_key: str) -> str:
    key = path_key.lower()
    if "blockmap" in key:
        return "blockmap"
    if "flavormap" in key or "deploy_resource_map" in key or "deploy_results" in key or "link_map" in key or "linux" in key or "windows" in key or "server" in key:
        return "servermap"
    if "lbmap" in key:
        return "lbmap"
    if "app_depend" in key or "selected_app_dependencies" in key or "db" in key:
        return "app_dependencies"
    return ""


def _region_value(row: Dict[str, Any], side: str) -> str:
    if side == "source":
        return _safe_str(_first(
            row,
            "source_region", "ospc_region", "source_flex_region", "src_region",
            "region", "Region", "Source Region",
            default="",
        )).strip()
    return _safe_str(_first(
        row,
        "target_region", "flex_region", "target_flex_region", "dst_region",
        "Target Region",
        default="",
    )).strip()


def _region_matches(value: Any, wanted: str = "") -> bool:
    wanted_norm = _norm_key(wanted)
    if not wanted_norm:
        return True
    value_norm = _norm_key(value)
    if not value_norm:
        return True
    if wanted_norm in value_norm or value_norm in wanted_norm:
        return True
    # Rackspace source scanner outputs often use legacy region names (DFW/IAD),
    # while FLEX credential dropdowns use v3 names (DFW3/IAD3). Treat those as
    # the same cutover region so valid Stage 2 rows are not filtered out.
    wanted_base = wanted_norm[:-1] if wanted_norm.endswith("3") else wanted_norm
    value_base = value_norm[:-1] if value_norm.endswith("3") else value_norm
    return wanted_base == value_base


def build_stage2_scanner_indexes(stage2_data: dict) -> dict:
    """Index already-produced Stage 2 scanner tables for Stage 4 cutover."""
    indexes: Dict[str, Any] = {
        "volume_by_key": {},
        "source_volume_by_key": {},
        "target_volume_by_key": {},
        "lb_by_key": {},
        "db_by_key": {},
        "os_by_key": {},
        "source_ip_by_key": {},
        "target_ip_by_key": {},
        "source_region_by_key": {},
        "target_region_by_key": {},
        "scanner_tables": [],
    }
    for path_key, payload in (stage2_data or {}).items():
        if path_key in {"source_artifacts", "missing_artifacts"}:
            continue
        kind = _scanner_kind(path_key)
        if not kind:
            continue
        rows = _as_rows(payload)
        if not rows:
            continue
        source_regions: list[str] = []
        target_regions: list[str] = []
        for table_row in rows:
            src_region = _region_value(table_row, "source")
            tgt_region = _region_value(table_row, "target")
            if src_region and src_region not in source_regions:
                source_regions.append(src_region)
            if tgt_region and tgt_region not in target_regions:
                target_regions.append(tgt_region)
        indexes["scanner_tables"].append({
            "path": path_key,
            "kind": kind,
            "rows": len(rows),
            "source_regions": source_regions,
            "target_regions": target_regions,
        })
        for row in rows:
            keys = _row_keys(row)
            if not keys:
                continue
            source_region = _region_value(row, "source")
            target_region = _region_value(row, "target")
            if kind == "blockmap":
                volume = _first(
                    row,
                    "volume_name", "volume_id", "source_volume_name", "source_volume_id",
                    "target_volume_name", "target_volume_id", "block_device", "device",
                    "mountpoint", "mount_point", "resource_name", "name",
                    default="",
                )
                source_volume = _first(row, "source_volume_name", "source_volume_id", "source_device", "source_mountpoint", default=volume)
                target_volume = _first(row, "target_volume_name", "target_volume_id", "target_device", "target_mountpoint", default=volume)
                for key in keys:
                    _add_index_value(indexes["volume_by_key"], key, "volumes", volume)
                    _add_index_value(indexes["source_volume_by_key"], key, "source_volumes", source_volume)
                    _add_index_value(indexes["target_volume_by_key"], key, "target_volumes", target_volume)
                    _add_index_value(indexes["source_region_by_key"], key, "source_regions", source_region)
                    _add_index_value(indexes["target_region_by_key"], key, "target_regions", target_region)
            elif kind == "lbmap":
                lb = _first(
                    row,
                    "load_balancer_name", "lb_name", "listener_name", "pool_name",
                    "member_name", "vip_address", "vip_ip", "protocol_port", "port",
                    default="",
                )
                for key in keys:
                    _add_index_value(indexes["lb_by_key"], key, "lbs", lb)
                    _add_index_value(indexes["source_region_by_key"], key, "source_regions", source_region)
                    _add_index_value(indexes["target_region_by_key"], key, "target_regions", target_region)
            elif kind == "app_dependencies":
                db = _first(
                    row,
                    "db_name", "database_name", "database_host", "Database Hostname",
                    "DB Hostname", "db_host", "dependency_target", "Target DB",
                    "service_name", "database_service", "Dependency Target",
                    default="",
                )
                if not db:
                    source_stack = _safe_str(_first(row, "Source Stack", "source_stack", default="")).lower()
                    target_stack = _safe_str(_first(row, "Target Stack", "target_stack", default="")).lower()
                    dep_type = _safe_str(_first(row, "Dependency Type", "dependency_type", default="")).lower()
                    if "db" in target_stack or "database" in target_stack:
                        db = _first(row, "Target Hostname", "target_vm_name", "target_server_name", default="")
                    elif "db" in source_stack or "database" in source_stack:
                        db = _first(row, "Source Hostname", "source_vm_name", "source_server_name", "server_name", "name", default="")
                    elif "db" in dep_type or "database" in dep_type:
                        db = _first(row, "Target Hostname", "target_vm_name", "target_server_name", "Source Hostname", default="")
                for key in keys:
                    _add_index_value(indexes["db_by_key"], key, "dbs", db)
                    _add_index_value(indexes["source_region_by_key"], key, "source_regions", source_region)
                    _add_index_value(indexes["target_region_by_key"], key, "target_regions", target_region)
            else:
                os_hint = _first(
                    row,
                    "source_image_os_distro", "source_image_os_version", "os_type",
                    "operating_system", "platform", "image_os", "source_image_name",
                    "recommended_target_image_name",
                    default="",
                )
                source_ip = _first(row, "source_ip", "source_member_ip", "private_ip", "fixed_ip", default="")
                target_ip = _first(row, "target_ip", "flex_private_ip", "target_private_ip", "vip_private_ips", default="")
                db = _first(row, "attached_db", "database_name", "db_name", "database_services", default="")
                for key in keys:
                    _add_index_value(indexes["os_by_key"], key, "os", os_hint)
                    _add_index_value(indexes["source_ip_by_key"], key, "source_ips", source_ip)
                    _add_index_value(indexes["target_ip_by_key"], key, "target_ips", target_ip)
                    _add_index_value(indexes["source_region_by_key"], key, "source_regions", source_region)
                    _add_index_value(indexes["target_region_by_key"], key, "target_regions", target_region)
                    if db:
                        _add_index_value(indexes["db_by_key"], key, "dbs", db)
    return indexes


def _lookup_index(index: Dict[str, list], *values: Any) -> list[str]:
    found: list[str] = []
    for value in values:
        norm = _norm_key(value)
        if not norm:
            continue
        for item in index.get(norm, []):
            if item not in found:
                found.append(item)
    return found


def _scanner_info(scanner_indexes: dict | None, item: dict) -> dict:
    indexes = scanner_indexes or {}
    keys = [
        item.get("source_vm_name"), item.get("source_instance_id"), item.get("source_ip"),
        item.get("target_vm_name"), item.get("target_instance_id"), item.get("target_ip"),
        item.get("system_name"),
    ]
    return {
        "volumes": _lookup_index(indexes.get("volume_by_key", {}), *keys),
        "source_volumes": _lookup_index(indexes.get("source_volume_by_key", {}), *keys[:3]),
        "target_volumes": _lookup_index(indexes.get("target_volume_by_key", {}), *keys[3:6]),
        "lbs": _lookup_index(indexes.get("lb_by_key", {}), *keys),
        "dbs": _lookup_index(indexes.get("db_by_key", {}), *keys),
        "os": _lookup_index(indexes.get("os_by_key", {}), *keys),
        "source_ips": _lookup_index(indexes.get("source_ip_by_key", {}), *keys),
        "target_ips": _lookup_index(indexes.get("target_ip_by_key", {}), *keys),
        "source_regions": _lookup_index(indexes.get("source_region_by_key", {}), *keys),
        "target_regions": _lookup_index(indexes.get("target_region_by_key", {}), *keys),
    }


def load_cutover_targets() -> dict:
    artifacts = load_stage2_migration_outputs()
    targets = build_health_validation_targets(artifacts)
    return {
        "targets": targets,
        "source_artifacts": artifacts.get("source_artifacts", []),
        "missing_artifacts": artifacts.get("missing_artifacts", []),
        "scanner_indexes": build_stage2_scanner_indexes(artifacts),
    }


def build_cutover_items(targets: list[dict]) -> list[dict]:
    items: List[Dict[str, Any]] = []
    for target in targets or []:
        is_db = _is_db(target)
        target_ip = _safe_str(target.get("target_ip"))
        source_ip = _safe_str(target.get("source_ip"))
        target_name = _safe_str(target.get("vm_name"))
        source_name = _safe_str(target.get("source_vm_name"))
        if is_db:
            cutover_area = "DB"
            method = "database_switchover"
            action = "Freeze source writes, verify replication/data consistency, promote FLEX DB, then repoint dependent apps."
            precheck = "DB health, replication lag, backup/snapshot, read-only validation command, app dependency approval."
            rollback = "Repoint apps back to source DB or restore from last clean backup before writes diverge."
            risk = "High"
        else:
            cutover_area = "APP"
            method = "blue_green_source_haproxy"
            action = "Deploy source-side HAProxy with source as blue and FLEX as green; start 90/10, validate, then increase green traffic."
            precheck = "Source app IP, FLEX target IP, app port, health URL, security group ingress, and rollback weight command."
            rollback = "Set green/FLEX weight to 0 and blue/source weight to 100; keep source app and DB write path available until sign-off."
            risk = "Medium" if source_ip and target_ip else "High"
        items.append({
            "selected": False,
            "system_name": target_name or source_name or _safe_str(target.get("instance_id")) or "migration-target",
            "workload_type": "database_server" if is_db else _safe_str(target.get("workload_type") or "app_server"),
            "source_vm_name": source_name,
            "source_instance_id": _safe_str(target.get("source_instance_id")),
            "source_ip": source_ip,
            "source_region": _raw_hint(target, "source_region", "ospc_region", "source_flex_region", "region"),
            "target_vm_name": target_name,
            "target_instance_id": _safe_str(target.get("instance_id")),
            "target_ip": target_ip,
            "target_region": _safe_str(target.get("target_region") or _raw_hint(target, "target_region", "flex_region", "target_flex_region")),
            "cutover_area": cutover_area,
            "cutover_method": method,
            "cutover_action": action,
            "current_source_value": source_ip or source_name or _safe_str(target.get("source_instance_id")),
            "target_cutover_value": target_ip or target_name or _safe_str(target.get("instance_id")),
            "precheck_required": precheck,
            "rollback_action": rollback,
            "owner": "DBA Team" if is_db else "Application/SRE Team",
            "estimated_time_minutes": 30 if is_db else 15,
            "risk_level": risk,
            "blue_weight": 90 if not is_db else "",
            "green_weight": 10 if not is_db else "",
            "app_port": 80 if not is_db else "",
            "health_path": "/health" if not is_db else "",
            "lb_option": "source_haproxy" if not is_db else "",
            "lb_name": f"{(target_name or source_name or 'app').replace(' ', '-')}-cutover-lb" if not is_db else "",
            "status": "NEEDS INPUT" if (not target_ip or (not is_db and not source_ip)) else "READY WITH WARNING",
            "notes": [
                "Generated from migrated Stage 2/3 target inventory.",
                "Blue-green cutover is the default app strategy. Commands are generated only, not executed.",
            ],
        })
    return items


def build_blue_green_scan_rows(
    targets: list[dict],
    lb_option: str = "source_haproxy",
    green_weight: int = 10,
    scanner_indexes: dict | None = None,
    source_region: str = "",
    target_region: str = "",
) -> list[dict]:
    green = _traffic_target_weight(green_weight, 10)
    blue = _traffic_source_weight(green, 10)
    items = apply_app_lb_option(build_cutover_items(targets or []), lb_option)
    rows: List[Dict[str, Any]] = []
    for item in items:
        info = _scanner_info(scanner_indexes, item)
        row_source_region = item.get("source_region") or _summarize(info.get("source_regions") or [])
        row_target_region = item.get("target_region") or _summarize(info.get("target_regions") or [])
        if not (_region_matches(row_source_region, source_region) and _region_matches(row_target_region, target_region)):
            continue
        if item.get("cutover_area") == "DB":
            rows.append({
                "selected": False,
                "pair_key": item.get("source_vm_name") or item.get("target_vm_name") or item.get("system_name"),
                "tier": "DB",
                "server_os": _summarize(info.get("os") or []),
                "source_region": row_source_region,
                "source_server_name": item.get("source_vm_name", ""),
                "source_server_ip": item.get("source_ip", "") or _summarize(info.get("source_ips") or []),
                "target_region": row_target_region,
                "target_server_name": item.get("target_vm_name", ""),
                "target_server_ip": item.get("target_ip", "") or _summarize(info.get("target_ips") or []),
                "source_volume_hint": _summarize(info.get("source_volumes") or info.get("volumes") or []),
                "target_volume_hint": _summarize(info.get("target_volumes") or info.get("volumes") or []),
                "attached_db": item.get("target_vm_name") or item.get("system_name", ""),
                "existing_lb_hint": _summarize(info.get("lbs") or []),
                "lb_method": "db_switchover",
                "source_weight": 100,
                "target_weight": 0,
                "app_port": _default_db_port(item.get("system_name") or item.get("target_vm_name")),
                "health_path": "",
                "status": item.get("status", ""),
                "notes": "DB target paired for HAProxy TCP endpoint switch. Keep FLEX weight 0 until DBA cutover approval.",
            })
            continue
        rows.append({
            "selected": False,
            "pair_key": item.get("source_vm_name") or item.get("target_vm_name") or item.get("system_name"),
            "tier": "APP",
            "server_os": _summarize(info.get("os") or []),
            "source_region": row_source_region,
            "source_server_name": item.get("source_vm_name", ""),
            "source_server_ip": item.get("source_ip", "") or _summarize(info.get("source_ips") or []),
            "target_region": row_target_region,
            "target_server_name": item.get("target_vm_name", ""),
            "target_server_ip": item.get("target_ip", "") or _summarize(info.get("target_ips") or []),
            "source_volume_hint": _summarize(info.get("source_volumes") or info.get("volumes") or []),
            "target_volume_hint": _summarize(info.get("target_volumes") or info.get("volumes") or []),
            "attached_db": _summarize(info.get("dbs") or [], "Needs app dependency mapping"),
            "existing_lb_hint": _summarize(info.get("lbs") or []),
            "lb_method": item.get("lb_option") or "source_haproxy",
            "source_weight": blue,
            "target_weight": green,
            "app_port": item.get("app_port") or 80,
            "health_path": item.get("health_path") or "/health",
            "status": item.get("status", ""),
            "notes": "Source and FLEX target paired from Stage 2 scanner tables." + (f" Existing LB: {_summarize(info.get('lbs') or [])}." if info.get("lbs") else ""),
        })
    return rows


def apply_traffic_split_to_rows(rows: list[dict], green_weight: int = 10, lb_option: str = "") -> list[dict]:
    green = _traffic_target_weight(green_weight, 10)
    blue = _traffic_source_weight(green, 10)
    option = str(lb_option or "").strip().lower()
    if option not in {"source_haproxy", "source_lb"}:
        option = ""
    updated: List[Dict[str, Any]] = []
    for row in rows or []:
        next_row = dict(row)
        if str(next_row.get("tier") or "").upper() == "APP":
            next_row["source_weight"] = blue
            next_row["target_weight"] = green
            if option:
                next_row["lb_method"] = option
        updated.append(next_row)
    return updated


def scan_rows_to_cutover_items(rows: list[dict]) -> list[dict]:
    items: List[Dict[str, Any]] = []
    for row in rows or []:
        is_db = str(row.get("tier") or "").upper() == "DB"
        item = {
            "selected": bool(row.get("selected", False)),
            "system_name": row.get("target_server_name") or row.get("source_server_name") or row.get("pair_key") or "migration-target",
            "workload_type": "database_server" if is_db else "app_server",
            "source_region": row.get("source_region", ""),
            "source_vm_name": row.get("source_server_name", ""),
            "source_ip": row.get("source_server_ip", ""),
            "target_region": row.get("target_region", ""),
            "target_vm_name": row.get("target_server_name", ""),
            "target_ip": row.get("target_server_ip", ""),
            "cutover_area": "DB" if is_db else "APP",
            "cutover_method": "database_switchover" if is_db else ("blue_green_source_load_balancer" if row.get("lb_method") == "source_lb" else "blue_green_source_haproxy"),
            "current_source_value": row.get("source_server_ip") or row.get("source_server_name", ""),
            "target_cutover_value": row.get("target_server_ip") or row.get("target_server_name", ""),
            "owner": "DBA Team" if is_db else "Application/SRE Team",
            "estimated_time_minutes": 30 if is_db else 15,
            "risk_level": "High" if is_db else "Medium",
            "blue_weight": row.get("source_weight", ""),
            "green_weight": row.get("target_weight", ""),
            "app_port": row.get("app_port") or ("" if is_db else 80),
            "health_path": row.get("health_path") or ("" if is_db else "/health"),
            "lb_option": row.get("lb_method") or "",
            "lb_name": _first_list_value(row.get("existing_lb_hint")) or (f"{(row.get('target_server_name') or row.get('source_server_name') or 'app').replace(' ', '-')}-cutover-lb" if not is_db else ""),
            "status": row.get("status") or "NEEDS INPUT",
            "notes": [row.get("notes", ""), f"Stage 2 scanner OS: {row.get('server_os') or 'unknown'}", f"Volumes: source={row.get('source_volume_hint') or 'n/a'} target={row.get('target_volume_hint') or 'n/a'}", f"Attached DB: {row.get('attached_db') or 'n/a'}"],
        }
        if is_db:
            item["cutover_action"] = "Freeze source writes, verify replication/data consistency, promote FLEX DB, then repoint dependent apps."
            item["precheck_required"] = "DB health, replication lag, backup/snapshot, read-only validation command, app dependency approval."
            item["rollback_action"] = "Repoint apps back to source DB or restore from last clean backup before writes diverge."
        elif item["lb_option"] == "source_lb":
            item["cutover_action"] = "Create or reuse a source-side load balancer with source as blue and FLEX as green; validate partial traffic before 100% switch."
            item["precheck_required"] = "Source LB subnet/VIP, source app IP, FLEX target IP, app port, health monitor, security group ingress."
            item["rollback_action"] = "Set FLEX green member weight to 0 and source blue member weight to 100 on the source load balancer."
        else:
            item["cutover_action"] = "Deploy source-side HAProxy with source as blue and FLEX as green; validate partial traffic before 100% switch."
            item["precheck_required"] = "Source cutover host, source app IP, FLEX target IP, app port, health URL, security group ingress."
            item["rollback_action"] = "Set green/FLEX weight to 0 and blue/source weight to 100."
        items.append(item)
    return items


def apply_app_lb_option(items: list[dict], lb_option: str = "source_haproxy") -> list[dict]:
    option = str(lb_option or "source_haproxy").strip().lower()
    if option not in {"source_haproxy", "haproxy", "source_lb", "flex_lb", "octavia"}:
        option = "source_haproxy"
    normalized = "source_lb" if option in {"source_lb", "flex_lb", "octavia"} else "source_haproxy"
    updated: List[Dict[str, Any]] = []
    for item in items or []:
        next_item = dict(item)
        if next_item.get("cutover_area") == "APP":
            next_item["lb_option"] = normalized
            if normalized == "source_lb":
                next_item["cutover_method"] = "blue_green_source_load_balancer"
                next_item["cutover_action"] = "Create or reuse a source-side load balancer with source as blue and FLEX as green; start 90/10, validate, then increase green traffic."
                next_item["precheck_required"] = "Source LB subnet/VIP, source app IP routeability, FLEX target IP reachability, app port, health monitor, security group ingress, rollback member weights."
                next_item["rollback_action"] = "Set FLEX green member weight to 0 and source blue member weight to 100 on the source load balancer."
            else:
                next_item["cutover_method"] = "blue_green_source_haproxy"
                next_item["cutover_action"] = "Deploy source-side HAProxy with source as blue and FLEX as green; start 90/10, validate, then increase green traffic."
                next_item["precheck_required"] = "Source cutover host, source app IP, FLEX target IP, app port, health URL, security group ingress, and rollback weight command."
                next_item["rollback_action"] = "Set green/FLEX weight to 0 and blue/source weight to 100; keep source app and DB write path available until sign-off."
        updated.append(next_item)
    return updated


def evaluate_cutover_readiness(items: list[dict]) -> list[dict]:
    evaluated: List[Dict[str, Any]] = []
    for item in items or []:
        next_item = dict(item)
        notes = list(next_item.get("notes") or [])
        if not next_item.get("target_cutover_value"):
            next_item["status"] = "NEEDS INPUT"
            notes.append("Target cutover value missing.")
        elif next_item.get("cutover_area") == "DB":
            next_item["status"] = "READY WITH WARNING"
            notes.append("DB cutover requires explicit DBA approval and read-only evidence before execution.")
        elif next_item.get("cutover_area") == "APP" and not next_item.get("source_ip"):
            next_item["status"] = "NEEDS INPUT"
            notes.append("Source IP missing for blue-green source backend.")
        elif not next_item.get("target_ip"):
            next_item["status"] = "NEEDS INPUT"
            notes.append("Target IP missing for app traffic switch.")
        else:
            next_item["status"] = "READY WITH WARNING"
        next_item["notes"] = notes
        evaluated.append(next_item)
    return evaluated


def generate_cutover_commands(items: list[dict]) -> str:
    lines = [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        "",
        "# Source-side blue-green cutover script.",
        "# Set CUTOVER_APPLY=1 only after change approval. Default is dry-run/print.",
        'CUTOVER_APPLY="${CUTOVER_APPLY:-0}"',
        'SOURCE_CUTOVER_HOST="${SOURCE_CUTOVER_HOST:-}"     # source-side HAProxy/cutover host for source_haproxy option',
        'SOURCE_SSH_USER="${SOURCE_SSH_USER:-ubuntu}"',
        'SOURCE_SSH_KEY="${SOURCE_SSH_KEY:-}"',
        'SOURCE_OPENRC="${SOURCE_OPENRC:-}"                 # source cloud OpenRC for source_lb option',
        'SOURCE_LB_VIP_SUBNET_ID="${SOURCE_LB_VIP_SUBNET_ID:-}"',
        'SOURCE_SSH_CONNECT_TIMEOUT="${SOURCE_SSH_CONNECT_TIMEOUT:-20}"',
        'SOURCE_SSH_COMMAND_TIMEOUT="${SOURCE_SSH_COMMAND_TIMEOUT:-90}"',
        'SOURCE_SSH_RETRIES="${SOURCE_SSH_RETRIES:-3}"',
        "",
        'run_or_print() { printf "+ "; printf "%q " "$@"; printf "\n"; if [ "$CUTOVER_APPLY" = "1" ]; then "$@"; fi; }',
        'ssh_source() { local cmd="$1" rc=255 attempt=1; if [ -z "$SOURCE_CUTOVER_HOST" ]; then echo "[ERROR] SOURCE_CUTOVER_HOST required"; return 2; fi; echo "[INFO] SSH $SOURCE_SSH_USER@$SOURCE_CUTOVER_HOST using key ${SOURCE_SSH_KEY:-default-agent}: ${cmd:0:120}"; while [ "$attempt" -le "$SOURCE_SSH_RETRIES" ]; do if [ -n "$SOURCE_SSH_KEY" ]; then timeout "$SOURCE_SSH_COMMAND_TIMEOUT" ssh -i "$SOURCE_SSH_KEY" -o BatchMode=yes -o PasswordAuthentication=no -o ConnectTimeout="$SOURCE_SSH_CONNECT_TIMEOUT" -o ConnectionAttempts=1 -o ServerAliveInterval=5 -o ServerAliveCountMax=1 -o StrictHostKeyChecking=no "$SOURCE_SSH_USER@$SOURCE_CUTOVER_HOST" "$cmd"; else timeout "$SOURCE_SSH_COMMAND_TIMEOUT" ssh -o BatchMode=yes -o PasswordAuthentication=no -o ConnectTimeout="$SOURCE_SSH_CONNECT_TIMEOUT" -o ConnectionAttempts=1 -o ServerAliveInterval=5 -o ServerAliveCountMax=1 -o StrictHostKeyChecking=no "$SOURCE_SSH_USER@$SOURCE_CUTOVER_HOST" "$cmd"; fi; rc=$?; if [ $rc -eq 0 ]; then echo "[OK] SSH command completed on $SOURCE_CUTOVER_HOST"; return 0; fi; echo "[WARN] SSH attempt $attempt/$SOURCE_SSH_RETRIES failed on $SOURCE_CUTOVER_HOST with rc=$rc"; attempt=$((attempt+1)); sleep 2; done; echo "[ERROR] SSH command failed on $SOURCE_CUTOVER_HOST after $SOURCE_SSH_RETRIES attempt(s) with rc=$rc"; return $rc; }',
        'scp_to_source() { local src="$1" dst="$2" rc=255 attempt=1; if [ -z "$SOURCE_CUTOVER_HOST" ]; then echo "[ERROR] SOURCE_CUTOVER_HOST required"; return 2; fi; echo "[INFO] Copying $src to $SOURCE_SSH_USER@$SOURCE_CUTOVER_HOST:$dst using key ${SOURCE_SSH_KEY:-default-agent}"; while [ "$attempt" -le "$SOURCE_SSH_RETRIES" ]; do if [ -n "$SOURCE_SSH_KEY" ]; then timeout "$SOURCE_SSH_COMMAND_TIMEOUT" scp -i "$SOURCE_SSH_KEY" -o BatchMode=yes -o PasswordAuthentication=no -o ConnectTimeout="$SOURCE_SSH_CONNECT_TIMEOUT" -o ConnectionAttempts=1 -o ServerAliveInterval=5 -o ServerAliveCountMax=1 -o StrictHostKeyChecking=no "$src" "$SOURCE_SSH_USER@$SOURCE_CUTOVER_HOST:$dst"; else timeout "$SOURCE_SSH_COMMAND_TIMEOUT" scp -o BatchMode=yes -o PasswordAuthentication=no -o ConnectTimeout="$SOURCE_SSH_CONNECT_TIMEOUT" -o ConnectionAttempts=1 -o ServerAliveInterval=5 -o ServerAliveCountMax=1 -o StrictHostKeyChecking=no "$src" "$SOURCE_SSH_USER@$SOURCE_CUTOVER_HOST:$dst"; fi; rc=$?; if [ $rc -eq 0 ]; then echo "[OK] Copied $src to $SOURCE_CUTOVER_HOST:$dst"; return 0; fi; echo "[WARN] SCP attempt $attempt/$SOURCE_SSH_RETRIES failed to $SOURCE_CUTOVER_HOST with rc=$rc"; attempt=$((attempt+1)); sleep 2; done; echo "[ERROR] SCP failed to $SOURCE_CUTOVER_HOST after $SOURCE_SSH_RETRIES attempt(s) with rc=$rc"; return $rc; }',
        "",
    ]
    skipped = 0
    generated = 0
    for item in items or []:
        name = item.get("system_name") or "migration-target"
        area = item.get("cutover_area")
        target_ip = _clean_endpoint_ip(item.get("target_ip"))
        source_ip = _clean_endpoint_ip(item.get("source_ip"))
        lines.append(f"echo '===== CUTOVER {name} / {area} ====='")
        skip_reason = _skip_cutover_reason(area, source_ip, target_ip)
        if skip_reason:
            skipped += 1
            lines.extend([
                f"echo '[SKIP] {name}: {skip_reason}. Complete source/target selected IPs in the cutover matrix before applying HAProxy.'",
                "",
            ])
            continue
        generated += 1
        if area == "DB":
            db_port = item.get("app_port") or _default_db_port(name)
            db_frontend = f"db_cutover_{str(name).replace(' ', '_').replace('-', '_')}_{db_port}"
            db_backend = f"{db_frontend}_blue_green"
            lines.extend([
                "# Dedicated HAProxy DB TCP option. Initial DB posture is source 100 / FLEX 0.",
                "# Keep FLEX DB weight at 0 until DBA approval, write freeze, replication/data validation, and promotion are complete.",
                f"# Promote FLEX DB target {target_ip} only after DBA approval.",
                f"nc -zv {source_ip} {db_port} || true",
                f"nc -zv {target_ip} {db_port} || true",
                f"cat > /tmp/haproxy-db-{db_port}.cfg <<'EOF_HAPROXY_DB'",
                *_haproxy_global_lines(),
                "defaults",
                "  mode tcp",
                "  timeout connect 5s",
                "  timeout client 2h",
                "  timeout server 2h",
                f"frontend {db_frontend}",
                f"  bind *:{db_port}",
                f"  default_backend {db_backend}",
                f"backend {db_backend}",
                "  balance roundrobin",
                f"  server blue_source {source_ip}:{db_port} check weight {item.get('blue_weight') or 100}",
                f"  server green_flex {target_ip}:{db_port} check weight {item.get('green_weight') or 0}",
                "EOF_HAPROXY_DB",
                f"run_or_print scp_to_source /tmp/haproxy-db-{db_port}.cfg /tmp/haproxy-db-{db_port}.cfg",
                f"run_or_print ssh_source {_sh(_source_haproxy_install_cmd(f'/tmp/haproxy-db-{db_port}.cfg'))}",
                "# DBA-approved final DB switch:",
                f"# echo 'set server {db_backend}/green_flex weight 100' | sudo socat stdio /run/haproxy/admin.sock",
                f"# echo 'set server {db_backend}/blue_source weight 0' | sudo socat stdio /run/haproxy/admin.sock",
                "# DB rollback before writes diverge:",
                f"# echo 'set server {db_backend}/green_flex weight 0' | sudo socat stdio /run/haproxy/admin.sock",
                f"# echo 'set server {db_backend}/blue_source weight 100' | sudo socat stdio /run/haproxy/admin.sock",
            ])
        else:
            app_port = item.get("app_port") or 80
            health_path = item.get("health_path") or "/health"
            if item.get("lb_option") == "source_lb" or item.get("cutover_method") == "blue_green_source_load_balancer":
                lb_name = item.get("lb_name") or f"{name}-cutover-lb"
                pool_name = f"{lb_name}-pool"
                monitor_name = f"{lb_name}-hm"
                listener_name = f"{lb_name}-http"
                lines.extend([
                    "# Source Load Balancer blue-green option: reuse existing source-side LB when present, otherwise create it.",
                    f"curl -k -fsS -I --connect-timeout 3 --max-time 5 -o /dev/null http://{source_ip}:{app_port}{health_path} || true",
                    f"curl -k -fsS -I --connect-timeout 3 --max-time 5 -o /dev/null http://{target_ip}:{app_port}{health_path} || true",
                    'if [ -n "$SOURCE_OPENRC" ]; then source "$SOURCE_OPENRC"; fi',
                    'if [ -z "$SOURCE_LB_VIP_SUBNET_ID" ]; then echo "[ERROR] SOURCE_LB_VIP_SUBNET_ID required for source_lb"; exit 2; fi',
                    f"run_or_print bash -lc {_sh(f'openstack loadbalancer show {_sh(lb_name)} >/dev/null 2>&1 || openstack loadbalancer create --name {_sh(lb_name)} --vip-subnet-id \"$SOURCE_LB_VIP_SUBNET_ID\"')}",
                    f"run_or_print bash -lc {_sh(f'openstack loadbalancer listener show {_sh(listener_name)} >/dev/null 2>&1 || openstack loadbalancer listener create --name {_sh(listener_name)} --protocol HTTP --protocol-port {app_port} {_sh(lb_name)}')}",
                    f"run_or_print bash -lc {_sh(f'openstack loadbalancer pool show {_sh(pool_name)} >/dev/null 2>&1 || openstack loadbalancer pool create --name {_sh(pool_name)} --lb-algorithm ROUND_ROBIN --listener {_sh(listener_name)} --protocol HTTP')}",
                    f"run_or_print bash -lc {_sh(f'openstack loadbalancer healthmonitor show {_sh(monitor_name)} >/dev/null 2>&1 || openstack loadbalancer healthmonitor create --name {_sh(monitor_name)} --delay 5 --timeout 3 --max-retries 3 --type HTTP --url-path {_sh(health_path)} {_sh(pool_name)}')}",
                    f"run_or_print bash -lc {_sh(f'openstack loadbalancer member list {_sh(pool_name)} -f value -c address 2>/dev/null | grep -Fxq {_sh(source_ip)} || openstack loadbalancer member create --name blue_source --address {_sh(source_ip)} --protocol-port {app_port} --weight {item.get("blue_weight") or 90} {_sh(pool_name)}')}",
                    f"run_or_print bash -lc {_sh(f'openstack loadbalancer member list {_sh(pool_name)} -f value -c address 2>/dev/null | grep -Fxq {_sh(target_ip)} || openstack loadbalancer member create --name green_flex --address {_sh(target_ip)} --protocol-port {app_port} --weight {item.get("green_weight") or 10} {_sh(pool_name)}')}",
                    f"# Initial generated split: FLEX {item.get('green_weight') or 10}% / source {item.get('blue_weight') or 90}%.",
                    *_lb_traffic_step_lines(pool_name),
                    "# Rollback:",
                    f"# openstack loadbalancer member set --weight 0 {_sh(pool_name)} <green_flex_member_id>",
                    f"# openstack loadbalancer member set --weight 100 {_sh(pool_name)} <blue_source_member_id>",
                ])
            else:
                lines.extend([
                    "# Source-side HAProxy blue-green option: deploy HAProxy on source cutover host.",
                    f"curl -k -fsS -I --connect-timeout 3 --max-time 5 -o /dev/null http://{source_ip}:{app_port}{health_path} || true",
                    f"curl -k -fsS -I --connect-timeout 3 --max-time 5 -o /dev/null http://{target_ip}:{app_port}{health_path} || true",
                    "cat > /tmp/haproxy-blue-green.cfg <<'EOF_HAPROXY'",
                    *_haproxy_global_lines(),
                    "defaults",
                    "  mode http",
                    "  timeout connect 5s",
                    "  timeout client 60s",
                    "  timeout server 60s",
                    "frontend app_cutover",
                    f"  bind *:{app_port}",
                    "  default_backend app_blue_green",
                    "backend app_blue_green",
                    "  balance roundrobin",
                    f"  option httpchk GET {health_path}",
                    f"  server blue_source {source_ip}:{app_port} check weight {item.get('blue_weight') or 90}",
                    f"  server green_flex {target_ip}:{app_port} check weight {item.get('green_weight') or 10}",
                    "EOF_HAPROXY",
                    "run_or_print scp_to_source /tmp/haproxy-blue-green.cfg /tmp/haproxy-blue-green.cfg",
                    f"run_or_print ssh_source {_sh(_source_haproxy_install_cmd('/tmp/haproxy-blue-green.cfg'))}",
                    f"# Initial generated split: FLEX {item.get('green_weight') or 10}% / source {item.get('blue_weight') or 90}%.",
                    *_haproxy_traffic_step_lines(),
                    "# Rollback:",
                    "# echo 'set server app_blue_green/green_flex weight 0' | sudo socat stdio /run/haproxy/admin.sock",
                    "# echo 'set server app_blue_green/blue_source weight 100' | sudo socat stdio /run/haproxy/admin.sock",
                ])
        lines.append("")
    lines.extend([
        f"echo '[SUMMARY] Generated applyable HAProxy/LB block(s): {generated}; skipped incomplete row(s): {skipped}.'",
        "",
    ])
    return "\n".join(lines) + "\n"


def _summary(items: List[Dict[str, Any]]) -> Dict[str, int]:
    return {
        "total_items": len(items or []),
        "app_targets": sum(1 for i in items if i.get("cutover_area") == "APP"),
        "database_targets": sum(1 for i in items if i.get("cutover_area") == "DB"),
        "ready_with_warning": sum(1 for i in items if i.get("status") == "READY WITH WARNING"),
        "needs_input": sum(1 for i in items if i.get("status") == "NEEDS INPUT"),
    }


def build_cutover_plan(items: list[dict], source_artifacts: list[str] | None = None) -> dict:
    evaluated = evaluate_cutover_readiness(items or [])
    return {
        "stage": "stage_4_cutover_traffic_transition",
        "feature": "per_target_cutover_plan",
        "created_at": _now(),
        "source_artifacts": source_artifacts or [],
        "summary": _summary(evaluated),
        "cutover_items": evaluated,
        "commands_path": "./outputs/cutover/cutover_commands.sh",
    }


def build_cutover_markdown(plan: dict) -> str:
    lines = ["# Per-Target Cutover Plan", "", f"Created: {plan.get('created_at', '')}", ""]
    for key, value in (plan.get("summary") or {}).items():
        lines.append(f"- {key}: {value}")
    lines.append("")
    for item in plan.get("cutover_items", []):
        lines.extend([
            f"## {item.get('system_name')} - {item.get('cutover_area')}",
            "",
            f"- Method: {item.get('cutover_method')}",
            f"- Action: {item.get('cutover_action')}",
            f"- Source: {item.get('current_source_value')}",
            f"- Target: {item.get('target_cutover_value')}",
            f"- Status: {item.get('status')}",
            "",
        ])
    return "\n".join(lines)


def write_cutover_artifacts(plan: dict, markdown: str, commands: str) -> dict:
    dirs = ensure_output_dirs()
    items = plan.get("cutover_items") or []
    fieldnames = [
        "selected", "system_name", "workload_type", "source_vm_name", "source_instance_id", "source_ip",
        "target_vm_name", "target_instance_id", "target_ip", "cutover_area", "cutover_method",
        "cutover_action", "current_source_value", "target_cutover_value", "precheck_required",
        "rollback_action", "owner", "estimated_time_minutes", "risk_level", "blue_weight",
        "green_weight", "app_port", "health_path", "lb_option", "lb_name", "status", "notes",
    ]
    artifacts: Dict[str, str] = {}
    for base in (dirs["cutover"], dirs["tmp"]):
        json_path = base / "cutover_plan.json"
        md_path = base / "cutover_plan.md"
        sh_path = base / "cutover_commands.sh"
        csv_path = base / "cutover_readiness.csv"
        json_path.write_text(json.dumps(plan, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        md_path.write_text(markdown, encoding="utf-8")
        sh_path.write_text(commands, encoding="utf-8")
        try:
            sh_path.chmod(0o700)
        except OSError:
            pass
        with csv_path.open("w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=fieldnames)
            writer.writeheader()
            for item in items:
                row = {key: item.get(key, "") for key in fieldnames}
                row["notes"] = " | ".join(item.get("notes") or []) if isinstance(item.get("notes"), list) else item.get("notes", "")
                writer.writerow(row)
        for path in (json_path, md_path, sh_path, csv_path):
            artifacts[str(path.relative_to(repo_root()))] = str(path)
    return artifacts


def write_blue_green_scan_artifacts(rows: list[dict], source_artifacts: list[str] | None = None) -> dict:
    dirs = ensure_output_dirs()
    payload = {
        "stage": "stage_4_cutover_traffic_transition",
        "feature": "blue_green_stage2_scanner_matrix",
        "created_at": _now(),
        "source_artifacts": source_artifacts or [],
        "summary": {
            "total_rows": len(rows or []),
            "app_rows": sum(1 for row in rows or [] if row.get("tier") == "APP"),
            "db_rows": sum(1 for row in rows or [] if row.get("tier") == "DB"),
        },
        "rows": rows or [],
    }
    fieldnames = [
        "selected", "pair_key", "tier", "server_os", "source_server_name", "source_server_ip",
        "target_server_name", "target_server_ip", "source_volume_hint", "target_volume_hint",
        "attached_db", "existing_lb_hint", "lb_method", "source_weight", "target_weight", "app_port",
        "health_path", "status", "notes",
    ]
    artifacts: Dict[str, str] = {}
    for base in (dirs["cutover"], dirs["tmp"]):
        json_path = base / "blue_green_cutover_matrix.json"
        csv_path = base / "blue_green_cutover_matrix.csv"
        json_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        with csv_path.open("w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=fieldnames)
            writer.writeheader()
            for row in rows or []:
                writer.writerow({key: row.get(key, "") for key in fieldnames})
        artifacts[str(json_path.relative_to(repo_root()))] = str(json_path)
        artifacts[str(csv_path.relative_to(repo_root()))] = str(csv_path)
    return artifacts
