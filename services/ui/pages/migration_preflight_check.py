#!/usr/bin/env python3
"""Read-only Migration Pre-Flight Compatibility Check helpers."""

from __future__ import annotations

import csv
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List


PREFLIGHT_STATUSES = ("PASS", "PASS WITH WARNING", "FAIL", "NEEDS INPUT", "SKIPPED")


def ensure_tmp_runs() -> Path:
    repo_root = Path(__file__).resolve().parents[3]
    tmp_runs = repo_root / ".tmp_runs"
    tmp_runs.mkdir(parents=True, exist_ok=True)
    return tmp_runs


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
    if not path.exists():
        return []
    try:
        with path.open("r", encoding="utf-8-sig", newline="") as handle:
            return list(csv.DictReader(handle))
    except Exception:
        return []


def _first(data: Dict[str, Any], *keys: str, default: Any = "") -> Any:
    for key in keys:
        value = data.get(key)
        if value not in (None, ""):
            return value
    return default


def load_readiness_handoff() -> list[dict]:
    tmp_runs = ensure_tmp_runs()
    payload = _read_json(tmp_runs / "stage2_readiness_handoff.json")
    if isinstance(payload, dict) and isinstance(payload.get("items"), list):
        return [row for row in payload["items"] if isinstance(row, dict)]
    rows = _read_csv(tmp_runs / "stage2_readiness_handoff.csv")
    return rows


def load_target_flex_inventory() -> dict:
    tmp_runs = ensure_tmp_runs()
    for name in ("target_flex_inventory.json", "target_inventory.json", "flex_target_inventory.json"):
        payload = _read_json(tmp_runs / name)
        if isinstance(payload, dict) and payload:
            return payload
    return {}


def _check_base(item: dict, target: dict, check_name: str, requirement: str) -> dict:
    return {
        "selected": False,
        "source_resource": _safe_str(_first(item, "resource_name", "source_resource", "name")),
        "source_resource_id": _safe_str(_first(item, "resource_id", "source_resource_id", "id")),
        "source_type": _safe_str(_first(item, "resource_type", "source_type", "type")),
        "target_region": _safe_str(_first(target, "region", "target_region")),
        "check_name": check_name,
        "source_value": "",
        "target_requirement": requirement,
        "target_value": "",
        "status": "SKIPPED",
        "impact": "",
        "recommended_fix": "",
        "blocks_migration": False,
        "notes": [],
    }


def _number(value: Any) -> float | None:
    try:
        text = _safe_str(value).strip()
        if not text:
            return None
        return float(text.split()[0])
    except Exception:
        return None


def check_flavor_mapping(item: dict, target: dict) -> dict:
    check = _check_base(item, target, "Flavor mapping", "Matching FLEX flavor exists")
    source = _first(item, "flavor", "source_flavor", "instance_flavor")
    target_flavor = _first(target, "flavor", "target_flavor", "flavor_mapping")
    check["source_value"] = _safe_str(source)
    check["target_value"] = _safe_str(target_flavor)
    if target_flavor:
        check["status"] = "PASS"
        check["recommended_fix"] = "None"
    else:
        check["status"] = "NEEDS INPUT"
        check["impact"] = "VM boot cannot be planned without a target flavor."
        check["recommended_fix"] = "Select or map a FLEX flavor for this workload."
        check["blocks_migration"] = True
    return check


def check_glance_quota(item: dict, target: dict) -> dict:
    check = _check_base(item, target, "Glance quota", "Target Glance quota available")
    size = _number(_first(item, "disk_size_gb", "image_size_gb", "size_gb"))
    free = _number(_first(target, "glance_free_gb", "image_quota_free_gb", "target_glance_free_gb"))
    check["source_value"] = f"{size:g} GB image/disk" if size is not None else "Unknown image size"
    check["target_value"] = f"{free:g} GB free" if free is not None else "Quota not loaded"
    if size is None:
        check["status"] = "PASS WITH WARNING"
        check["recommended_fix"] = "Confirm source image size before starting migration."
    elif free is None:
        check["status"] = "PASS WITH WARNING"
        check["recommended_fix"] = "Load target FLEX quota or confirm Glance capacity manually."
    elif free >= size:
        check["status"] = "PASS"
        check["recommended_fix"] = "None"
    else:
        check["status"] = "FAIL"
        check["impact"] = "Target region does not have enough image quota."
        check["recommended_fix"] = "Increase target Glance quota or free space."
        check["blocks_migration"] = True
    return check


def check_cinder_quota(item: dict, target: dict) -> dict:
    check = _check_base(item, target, "Cinder quota", "Target Cinder quota available")
    source_type = _safe_str(_first(item, "resource_type", "source_type")).lower()
    size = _number(_first(item, "disk_size_gb", "volume_size_gb", "size_gb"))
    free = _number(_first(target, "cinder_free_gb", "volume_quota_free_gb", "target_cinder_free_gb"))
    check["source_value"] = f"{size:g} GB" if size is not None else "Unknown volume/disk size"
    check["target_value"] = f"{free:g} GB free" if free is not None else "Quota not loaded"
    if source_type not in ("volume", "vm", "snapshot"):
        check["status"] = "SKIPPED"
        check["recommended_fix"] = "Not a volume-backed migration check."
    elif free is None:
        check["status"] = "PASS WITH WARNING"
        check["recommended_fix"] = "Load target Cinder quota or confirm volume capacity manually."
    elif size is None or free >= size:
        check["status"] = "PASS"
        check["recommended_fix"] = "None"
    else:
        check["status"] = "FAIL"
        check["impact"] = "Target region does not have enough volume quota."
        check["recommended_fix"] = "Increase target Cinder quota or reduce selected volume size."
        check["blocks_migration"] = True
    return check


def check_api_reachability(source: dict, target: dict) -> list[dict]:
    item = {"resource_name": "API reachability", "resource_id": "api", "resource_type": "environment"}
    source_check = _check_base(item, target, "Source API reachable", "Source cloud API reachable")
    source_check["source_value"] = _safe_str(_first(source, "source_cloud", "cloud")) + " " + _safe_str(_first(source, "source_region", "region"))
    target_check = _check_base(item, target, "Target API reachable", "Target FLEX API reachable")
    target_check["target_value"] = _safe_str(_first(target, "cloud", "target_flex_cloud", default="FLEX")) + " " + _safe_str(_first(target, "region", "target_region"))
    for check in (source_check, target_check):
        if check["source_value"] or check["target_value"]:
            check["status"] = "PASS WITH WARNING"
            check["recommended_fix"] = "API endpoint value is present; live reachability is not tested by this read-only pre-flight."
        else:
            check["status"] = "NEEDS INPUT"
            check["recommended_fix"] = "Provide source and target region/API details."
            check["blocks_migration"] = True
    return [source_check, target_check]


def check_network_mapping(item: dict, target: dict) -> dict:
    check = _check_base(item, target, "Network", "Target network selected")
    check["source_value"] = _safe_str(_first(item, "network_status", "network", "fixed_ip"))
    check["target_value"] = _safe_str(_first(target, "network", "target_network"))
    if check["target_value"]:
        check["status"] = "PASS"
        check["recommended_fix"] = "None"
    else:
        check["status"] = "NEEDS INPUT"
        check["impact"] = "Server cannot boot into the desired FLEX network."
        check["recommended_fix"] = "Select target FLEX network and subnet."
        check["blocks_migration"] = True
    return check


def check_security_group_mapping(item: dict, target: dict) -> dict:
    check = _check_base(item, target, "Security group", "Security group rules mapped")
    check["source_value"] = _safe_str(_first(item, "security_groups", "security_group", default="Source SG mapping required"))
    check["target_value"] = _safe_str(_first(target, "security_group", "target_security_group"))
    if check["target_value"]:
        check["status"] = "PASS"
        check["recommended_fix"] = "None"
    else:
        check["status"] = "NEEDS INPUT"
        check["recommended_fix"] = "Select or create mapped target FLEX security group."
    return check


def check_keypair(item: dict, target: dict) -> dict:
    check = _check_base(item, target, "Keypair", "Target keypair exists or is intentionally omitted")
    check["source_value"] = _safe_str(_first(item, "keypair", "key_name", "source_keypair"))
    check["target_value"] = _safe_str(_first(target, "keypair", "target_keypair"))
    os_type = _safe_str(_first(item, "os_type")).lower()
    if check["target_value"]:
        check["status"] = "PASS"
        check["recommended_fix"] = "None"
    elif os_type == "windows":
        check["status"] = "PASS WITH WARNING"
        check["recommended_fix"] = "Windows can boot without SSH keypair, but confirm console/RDP access path."
    else:
        check["status"] = "NEEDS INPUT"
        check["recommended_fix"] = "Select or create target keypair."
    return check


def check_floating_ip_capacity(item: dict, target: dict) -> dict:
    check = _check_base(item, target, "Floating IP", "Floating IP available or not required")
    required = str(_first(target, "floating_ip_required", "fip_required", default="No")).lower() in ("yes", "true", "1", "required")
    free = _number(_first(target, "floating_ip_free", "fip_quota_free"))
    check["source_value"] = _safe_str(_first(item, "floating_ip", "public_ip", default=""))
    check["target_value"] = f"{free:g} available" if free is not None else ("Required" if required else "Not required")
    if not required:
        check["status"] = "SKIPPED"
        check["recommended_fix"] = "Floating IP not required."
    elif free is None:
        check["status"] = "PASS WITH WARNING"
        check["recommended_fix"] = "Confirm target floating IP quota before cutover."
    elif free > 0:
        check["status"] = "PASS"
        check["recommended_fix"] = "None"
    else:
        check["status"] = "FAIL"
        check["impact"] = "Cutover cannot allocate a floating IP."
        check["recommended_fix"] = "Release or increase target floating IP quota."
        check["blocks_migration"] = True
    return check


def _generic_check(item: dict, target: dict, name: str, target_key: str, requirement: str) -> dict:
    check = _check_base(item, target, name, requirement)
    check["target_value"] = _safe_str(_first(target, target_key))
    if check["target_value"]:
        check["status"] = "PASS"
        check["recommended_fix"] = "None"
    else:
        check["status"] = "PASS WITH WARNING"
        check["recommended_fix"] = f"Confirm {requirement.lower()} manually if this migration path needs it."
    return check


def evaluate_preflight_for_item(item: dict, target: dict) -> list[dict]:
    item = item or {}
    target = target or {}
    checks = [
        check_flavor_mapping(item, target),
        check_glance_quota(item, target),
        check_cinder_quota(item, target),
        check_network_mapping(item, target),
        check_security_group_mapping(item, target),
        check_keypair(item, target),
        check_floating_ip_capacity(item, target),
        _generic_check(item, target, "Volume type", "volume_type", "Target volume type availability"),
        _generic_check(item, target, "Availability zone", "availability_zone", "Target availability zone selected"),
        _generic_check(item, target, "Boot-from-volume", "boot_from_volume_supported", "Target boot-from-volume support"),
        _generic_check(item, target, "DNS/cutover", "dns_cutover_plan", "DNS/cutover requirement documented"),
    ]
    return checks


def build_preflight_remediation_plan(checks: list[dict]) -> str:
    checks = checks or []
    lines = ["# Migration Pre-Flight Remediation Plan", "", f"Created: {_now()}", ""]
    actionable = [check for check in checks if check.get("status") in ("FAIL", "NEEDS INPUT", "PASS WITH WARNING")]
    if not actionable:
        lines.append("All pre-flight checks passed or were intentionally skipped.")
    for check in actionable:
        lines.extend([
            f"## {check.get('source_resource') or check.get('source_resource_id') or 'Resource'} - {check.get('check_name')}",
            "",
            f"- Status: {check.get('status', '')}",
            f"- Impact: {check.get('impact', '') or 'Review required'}",
            f"- Fix: {check.get('recommended_fix', '') or 'Provide target input and rerun pre-flight'}",
            f"- Blocks migration: {check.get('blocks_migration')}",
            "",
        ])
    return "\n".join(lines)


def _summary(checks: List[Dict[str, Any]]) -> Dict[str, int]:
    return {
        "total_checks": len(checks or []),
        "pass": sum(1 for check in checks if check.get("status") == "PASS"),
        "pass_with_warning": sum(1 for check in checks if check.get("status") == "PASS WITH WARNING"),
        "fail": sum(1 for check in checks if check.get("status") == "FAIL"),
        "needs_input": sum(1 for check in checks if check.get("status") == "NEEDS INPUT"),
        "skipped": sum(1 for check in checks if check.get("status") == "SKIPPED"),
    }


def _write_csv(path: Path, checks: List[Dict[str, Any]]) -> None:
    fieldnames = [
        "selected", "source_resource", "source_resource_id", "source_type", "target_region",
        "check_name", "source_value", "target_requirement", "target_value", "status",
        "impact", "recommended_fix", "blocks_migration", "notes",
    ]
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for check in checks:
            row = {key: check.get(key, "") for key in fieldnames}
            row["notes"] = " | ".join(check.get("notes") or []) if isinstance(check.get("notes"), list) else check.get("notes", "")
            writer.writerow(row)


def write_preflight_artifacts(checks: list[dict], target: dict | None = None) -> dict:
    checks = checks or []
    target = target or {}
    tmp_runs = ensure_tmp_runs()
    payload = {
        "stage": "stage_1_discovery",
        "feature": "migration_preflight_check",
        "created_at": _now(),
        "source_cloud": "",
        "source_region": "",
        "target_flex": {
            "cloud": _safe_str(_first(target, "cloud", "target_flex_cloud", default="FLEX")),
            "region": _safe_str(_first(target, "region", "target_region")),
            "project": _safe_str(_first(target, "project", "target_project")),
            "network": _safe_str(_first(target, "network", "target_network")),
            "subnet": _safe_str(_first(target, "subnet", "target_subnet")),
            "security_group": _safe_str(_first(target, "security_group", "target_security_group")),
            "keypair": _safe_str(_first(target, "keypair", "target_keypair")),
        },
        "summary": _summary(checks),
        "checks": checks,
    }
    json_path = tmp_runs / "migration_preflight_report.json"
    csv_path = tmp_runs / "migration_preflight_report.csv"
    md_path = tmp_runs / "migration_preflight_remediation_plan.md"
    json_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    _write_csv(csv_path, checks)
    md_path.write_text(build_preflight_remediation_plan(checks), encoding="utf-8")
    return {
        "migration_preflight_report.json": str(json_path),
        "migration_preflight_report.csv": str(csv_path),
        "migration_preflight_remediation_plan.md": str(md_path),
    }


def send_preflight_to_stage2(selected_checks: list[dict]) -> dict:
    selected_checks = [dict(check, selected=True) for check in (selected_checks or [])]
    grouped: Dict[str, Dict[str, Any]] = {}
    for check in selected_checks:
        rid = _safe_str(_first(check, "source_resource_id", default=_first(check, "source_resource")))
        if not rid:
            continue
        item = grouped.setdefault(rid, {
            "selected": True,
            "source_stage": "migration_preflight_check",
            "source_cloud": "",
            "source_region": "",
            "target_region": check.get("target_region", ""),
            "resource_type": check.get("source_type", ""),
            "resource_name": check.get("source_resource", ""),
            "resource_id": rid,
            "instance_id": rid if check.get("source_type") == "vm" else "",
            "volume_id": rid if check.get("source_type") == "volume" else "",
            "image_id": rid if check.get("source_type") == "image" else "",
            "snapshot_id": rid if check.get("source_type") == "snapshot" else "",
            "workload_type": "",
            "migration_method": "",
            "readiness_status": "",
            "preflight_status": "PASS",
            "risk_level": "Low",
            "recommended_action": "Ready for Stage 2 migration queue",
            "migration_status": "queued",
            "notes": [],
        })
        if check.get("status") in ("FAIL", "NEEDS INPUT"):
            item["preflight_status"] = check.get("status")
            item["risk_level"] = "High"
        elif check.get("status") == "PASS WITH WARNING" and item.get("risk_level") != "High":
            item["preflight_status"] = "PASS WITH WARNING"
            item["risk_level"] = "Medium"
        if check.get("recommended_fix") and check.get("recommended_fix") != "None":
            item.setdefault("notes", []).append(f"{check.get('check_name')}: {check.get('recommended_fix')}")

    items = list(grouped.values())
    tmp_runs = ensure_tmp_runs()
    payload = {
        "stage": "stage_2_migrations",
        "source_stage": "migration_preflight_check",
        "feature": "stage2_preflight_handoff",
        "created_at": _now(),
        "item_count": len(items),
        "items": items,
        "checks": selected_checks,
    }
    json_path = tmp_runs / "stage2_preflight_handoff.json"
    csv_path = tmp_runs / "stage2_preflight_handoff.csv"
    json_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    fieldnames = ["selected", "source_stage", "source_cloud", "source_region", "target_region", "resource_type", "resource_name", "resource_id", "instance_id", "volume_id", "image_id", "snapshot_id", "workload_type", "migration_method", "readiness_status", "preflight_status", "risk_level", "recommended_action", "migration_status", "notes"]
    with csv_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for item in items:
            row = {key: item.get(key, "") for key in fieldnames}
            row["notes"] = " | ".join(item.get("notes") or []) if isinstance(item.get("notes"), list) else item.get("notes", "")
            writer.writerow(row)
    return {"payload": payload, "artifacts": {"stage2_preflight_handoff.json": str(json_path), "stage2_preflight_handoff.csv": str(csv_path)}}


def render_migration_preflight_check() -> None:
    try:
        import streamlit as st  # type: ignore
    except Exception:
        return
    st.subheader("🧪 Migration Pre-Flight Check")
    st.caption("Validate if selected source workloads can land successfully in the target FLEX region before starting migration.")
    ss = st.session_state
    ss.setdefault("migration_preflight_checks", [])
    ss.setdefault("migration_preflight_selected", [])
    ss.setdefault("stage2_preflight_handoff_ready", False)
    if st.button("📥 Import Ready Items from Readiness Scanner"):
        ss["migration_preflight_source_items"] = load_readiness_handoff()
    if st.button("🧪 Run Pre-Flight Check"):
        target = load_target_flex_inventory()
        checks: List[Dict[str, Any]] = []
        for item in ss.get("migration_preflight_source_items") or []:
            checks.extend(evaluate_preflight_for_item(item, target))
        ss["migration_preflight_checks"] = checks
        write_preflight_artifacts(checks, target)
    st.dataframe(ss.get("migration_preflight_checks") or [], use_container_width=True)
