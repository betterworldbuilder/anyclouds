#!/usr/bin/env python3
"""Read-only Migration Readiness Scanner helpers.

This module intentionally stays conservative: it consumes cached discovery
artifacts, evaluates obvious migration blockers, and writes handoff files for
Stage 2 without touching any source or target cloud resources.
"""

from __future__ import annotations

import csv
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List


READINESS_STATUSES = ("READY", "READY WITH WARNING", "BLOCKED", "NEEDS MANUAL ACTION")
SUPPORTED_IMAGE_TYPES = {"qcow2", "raw", "vmdk", "vhd", "vhdx"}
PREFERRED_IMAGE_TYPES = {"qcow2", "raw"}
DB_KEYWORDS = ("postgres", "postgresql", "mysql", "mariadb", "mongo", "mongodb", "redis", "elasticsearch", "opensearch", "cassandra")


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
    if isinstance(value, (dict, list)):
        return json.dumps(value, sort_keys=True)
    return str(value)


def _first(data: Dict[str, Any], keys: Iterable[str], default: Any = "") -> Any:
    for key in keys:
        value = data.get(key)
        if value not in (None, ""):
            return value
    return default


def _as_list(value: Any) -> List[Any]:
    if value is None:
        return []
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        for key in ("items", "rows", "servers", "vms", "images", "volumes", "snapshots"):
            if isinstance(value.get(key), list):
                return value[key]
        return [value]
    return []


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


def load_source_inventory() -> dict:
    """Load cached inventory from known scanner artifacts."""
    tmp_runs = ensure_tmp_runs()
    for name in ("ospc_inventory.json", "source_inventory.json", "target_inventory.json"):
        payload = _read_json(tmp_runs / name)
        if payload:
            return payload if isinstance(payload, dict) else {"items": _as_list(payload)}

    csv_rows: List[Dict[str, Any]] = []
    for name in ("ospc_inventory.csv", "source_inventory.csv", "app_dependency_summary.csv", "stage2_migration_candidates.csv"):
        csv_rows.extend(_read_csv(tmp_runs / name))
    return {"items": csv_rows} if csv_rows else {}


def load_app_dependency_results() -> dict:
    tmp_runs = ensure_tmp_runs()
    report = _read_json(tmp_runs / "app_dependency_report.json")
    if isinstance(report, dict) and report:
        return report
    rows = _read_csv(tmp_runs / "app_dependencies.csv") or _read_csv(tmp_runs / "app_dependency_summary.csv")
    return {"results": rows} if rows else {}


def _inventory_bucket(source_inventory: dict, *keys: str) -> List[Dict[str, Any]]:
    for key in keys:
        value = source_inventory.get(key)
        if isinstance(value, dict):
            rows = _as_list(value)
        else:
            rows = value if isinstance(value, list) else []
        if rows:
            return [r for r in rows if isinstance(r, dict)]
    return []


def _infer_os_type(data: Dict[str, Any]) -> str:
    text = " ".join(_safe_str(_first(data, keys)) for keys in (
        ("os_type",), ("os_distro",), ("image",), ("image_name",), ("name",), ("metadata",)
    )).lower()
    if "windows" in text or "win201" in text or "win2k" in text:
        return "Windows"
    if any(token in text for token in ("ubuntu", "debian", "centos", "rocky", "alma", "rhel", "linux")):
        return "Linux"
    return "Unknown"


def _infer_boot_mode(data: Dict[str, Any]) -> str:
    text = _safe_str(_first(data, ("boot_mode", "hw_firmware_type", "firmware", "metadata"), "")).lower()
    if "uefi" in text:
        return "UEFI"
    if "bios" in text or "legacy" in text:
        return "BIOS"
    return "unknown"


def _infer_image_type(data: Dict[str, Any]) -> str:
    value = _safe_str(_first(data, ("image_type", "disk_format", "format", "container_format"), "")).lower()
    if value in SUPPORTED_IMAGE_TYPES:
        return value
    name = _safe_str(_first(data, ("image", "image_name", "name"), "")).lower()
    for ext in SUPPORTED_IMAGE_TYPES:
        if re.search(rf"\.{re.escape(ext)}($|[\s_-])", name):
            return ext
    return value or "unknown"


def _disk_size_gb(data: Dict[str, Any]) -> str:
    value = _first(data, ("disk_size_gb", "root_disk_gb", "size_gb", "size", "min_disk", "volume_size"), "")
    text = _safe_str(value).strip()
    if not text:
        return ""
    match = re.search(r"([0-9]+(?:\.[0-9]+)?)", text)
    return match.group(1) if match else text


def _volume_count(vm: Dict[str, Any]) -> int:
    volumes = _first(vm, ("attached_volumes", "volumes", "os-extended-volumes:volumes_attached"), [])
    if isinstance(volumes, list):
        return len(volumes)
    if isinstance(volumes, str) and volumes.strip():
        return len([x for x in re.split(r"[,;|]", volumes) if x.strip()])
    return 0


def _find_appdep(app_dependencies: dict, item: Dict[str, Any]) -> Dict[str, Any]:
    keys = {_safe_str(_first(item, ("id", "resource_id", "instance_id", "server_id"), "")).strip(),
            _safe_str(_first(item, ("name", "resource_name", "server_name"), "")).strip(),
            _safe_str(_first(item, ("ip", "fixed_ip", "access_ip", "public_ip"), "")).strip()}
    keys.discard("")
    for result in _as_list(app_dependencies.get("results") or app_dependencies.get("items") or app_dependencies):
        if not isinstance(result, dict):
            continue
        vm = result.get("vm") if isinstance(result.get("vm"), dict) else result
        result_keys = {_safe_str(_first(vm, ("id", "instance_id", "resource_id"), "")).strip(),
                       _safe_str(_first(vm, ("name", "resource_name"), "")).strip(),
                       _safe_str(_first(vm, ("ip", "fixed_ip", "public_ip"), "")).strip()}
        if keys.intersection(k for k in result_keys if k):
            return result
    return {}


def _db_detected(data: Dict[str, Any], appdep: Dict[str, Any] | None = None) -> bool:
    appdep = appdep or {}
    deps = appdep.get("dependencies") if isinstance(appdep.get("dependencies"), dict) else {}
    if deps.get("database_services"):
        return True
    cls = appdep.get("classification") if isinstance(appdep.get("classification"), dict) else {}
    if "database" in _safe_str(cls.get("workload_type")).lower():
        return True
    text = " ".join(_safe_str(v) for v in list(data.values())[:20]).lower()
    return any(token in text for token in DB_KEYWORDS)


def _blank_item(resource_type: str, data: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "selected": False,
        "resource_type": resource_type,
        "resource_name": _safe_str(_first(data, ("resource_name", "name", "Name", "server_name", "image_name", "snapshot_name"), "")),
        "resource_id": _safe_str(_first(data, ("resource_id", "id", "ID", "instance_id", "server_id", "image_id", "snapshot_id", "volume_id"), "")),
        "source_cloud": _safe_str(_first(data, ("source_cloud", "cloud", "Cloud"), "")),
        "source_region": _safe_str(_first(data, ("source_region", "region", "Region"), "")),
        "vm_status": "",
        "os_type": _infer_os_type(data),
        "boot_mode": _infer_boot_mode(data),
        "image_type": _infer_image_type(data),
        "disk_size_gb": _disk_size_gb(data),
        "volume_count": 0,
        "snapshot_status": "",
        "network_status": "",
        "db_detected": False,
        "readiness_status": "NEEDS MANUAL ACTION",
        "risk_level": "Medium",
        "manual_action_required": "",
        "recommended_action": "",
        "notes": [],
    }


def calculate_readiness_status(checks: list[dict]) -> str:
    statuses = {str((check or {}).get("status", "")).upper() for check in (checks or [])}
    if "BLOCKED" in statuses:
        return "BLOCKED"
    if "NEEDS MANUAL ACTION" in statuses:
        return "NEEDS MANUAL ACTION"
    if "READY WITH WARNING" in statuses:
        return "READY WITH WARNING"
    return "READY"


def evaluate_vm_readiness(vm: dict, appdep: dict | None = None) -> dict:
    vm = vm or {}
    item = _blank_item("vm", vm)
    item["resource_name"] = item["resource_name"] or _safe_str(_first(vm, ("hostname",), "Unnamed VM"))
    item["resource_id"] = item["resource_id"] or item["resource_name"]
    status = _safe_str(_first(vm, ("vm_status", "status", "Status"), "UNKNOWN")).upper()
    item["vm_status"] = status
    item["volume_count"] = _volume_count(vm)
    item["network_status"] = "FOUND" if _first(vm, ("fixed_ip", "ip", "access_ip", "public_ip", "private_ip"), "") else "NEEDS MANUAL ACTION"
    item["snapshot_status"] = "Snapshot exists" if _first(vm, ("snapshot_id", "image_id", "backup_id"), "") else "Snapshot required before migration"
    item["db_detected"] = _db_detected(vm, appdep)

    checks: List[Dict[str, str]] = []
    notes: List[str] = []
    manual: List[str] = []

    if status in ("ACTIVE", "SHUTOFF"):
        checks.append({"status": "READY"})
    elif status in ("ERROR",):
        checks.append({"status": "BLOCKED"})
        manual.append("Fix source VM ERROR state before migration.")
    elif status in ("PAUSED", "SUSPENDED"):
        checks.append({"status": "READY WITH WARNING"})
        manual.append("Resume or shut off VM cleanly before snapshot migration.")
    else:
        checks.append({"status": "NEEDS MANUAL ACTION"})
        manual.append("Confirm source VM status.")

    if not _first(vm, ("image", "image_id", "root_disk", "root_disk_id", "volume_id", "snapshot_id"), ""):
        checks.append({"status": "BLOCKED"})
        manual.append("Missing image/root disk evidence.")
    if item["network_status"] != "FOUND":
        checks.append({"status": "NEEDS MANUAL ACTION"})
        manual.append("Map target FLEX network/subnet/security group.")
    if item["boot_mode"] == "unknown":
        checks.append({"status": "NEEDS MANUAL ACTION"})
        manual.append("Confirm BIOS/UEFI boot mode.")
    if item["os_type"] == "Windows":
        checks.append({"status": "READY WITH WARNING"})
        notes.append("Windows workload detected. Verify VirtIO, boot mode, RDP, and Windows boot repair readiness before migration.")
    if item["db_detected"]:
        checks.append({"status": "READY WITH WARNING"})
        notes.append("Database detected; plan consistency window, snapshot timing, and validation.")

    item["readiness_status"] = calculate_readiness_status(checks)
    item["risk_level"] = "High" if item["readiness_status"] == "BLOCKED" or item["db_detected"] else ("Medium" if item["readiness_status"] != "READY" else "Low")
    item["manual_action_required"] = " | ".join(dict.fromkeys(manual)) or "None"
    item["recommended_action"] = "Resolve blockers before Stage 2" if item["readiness_status"] == "BLOCKED" else ("Review warnings and send to pre-flight" if item["readiness_status"] != "READY" else "Send to pre-flight")
    item["notes"] = notes
    return item


def evaluate_image_readiness(image: dict) -> dict:
    image = image or {}
    item = _blank_item("image", image)
    status = _safe_str(_first(image, ("image_status", "status", "Status"), "unknown")).lower()
    image_type = item["image_type"]
    notes: List[str] = []
    checks = [{"status": "READY"}]
    if status in ("deleted", "killed", "error", "unavailable"):
        checks.append({"status": "BLOCKED"})
    elif status and status not in ("active", "available", "queued", "saving"):
        checks.append({"status": "READY WITH WARNING"})
    if image_type not in SUPPORTED_IMAGE_TYPES:
        checks.append({"status": "NEEDS MANUAL ACTION"})
        notes.append("Unknown image format; validate conversion path.")
    elif image_type not in PREFERRED_IMAGE_TYPES:
        checks.append({"status": "READY WITH WARNING"})
        notes.append(f"{image_type} image requires conversion or validation.")
    item["snapshot_status"] = "Snapshot exists"
    item["readiness_status"] = calculate_readiness_status(checks)
    item["risk_level"] = "High" if item["readiness_status"] == "BLOCKED" else ("Medium" if item["readiness_status"] != "READY" else "Low")
    item["manual_action_required"] = "Validate image format/status" if item["readiness_status"] != "READY" else "None"
    item["recommended_action"] = "Confirm image is active and exportable" if item["readiness_status"] != "READY" else "Send to pre-flight"
    item["notes"] = notes
    return item


def evaluate_volume_readiness(volume: dict) -> dict:
    volume = volume or {}
    item = _blank_item("volume", volume)
    status = _safe_str(_first(volume, ("volume_status", "status", "Status"), "unknown")).lower()
    item["snapshot_status"] = "Snapshot exists" if _first(volume, ("snapshot_id", "backup_id"), "") else "Snapshot required before migration"
    item["volume_count"] = 1
    item["network_status"] = "N/A"
    item["db_detected"] = _db_detected(volume)
    checks = [{"status": "READY"}]
    notes: List[str] = []
    if status in ("error", "error_extending", "error_deleting"):
        checks.append({"status": "BLOCKED"})
    elif status not in ("available", "in-use", "in_use", "attached"):
        checks.append({"status": "NEEDS MANUAL ACTION"})
    if item["snapshot_status"].startswith("Snapshot required"):
        checks.append({"status": "NEEDS MANUAL ACTION"})
    if item["db_detected"]:
        checks.append({"status": "READY WITH WARNING"})
        notes.append("Database volume hint detected; use app-aware snapshot/validation.")
    item["readiness_status"] = calculate_readiness_status(checks)
    item["risk_level"] = "High" if item["db_detected"] or item["readiness_status"] == "BLOCKED" else ("Medium" if item["readiness_status"] != "READY" else "Low")
    item["manual_action_required"] = "Create/verify volume snapshot" if item["snapshot_status"].startswith("Snapshot required") else ("Fix volume state" if item["readiness_status"] == "BLOCKED" else "None")
    item["recommended_action"] = "Snapshot volume before Stage 2" if item["snapshot_status"].startswith("Snapshot required") else "Send to pre-flight"
    item["notes"] = notes
    return item


def evaluate_snapshot_readiness(snapshot: dict) -> dict:
    snapshot = snapshot or {}
    item = _blank_item("snapshot", snapshot)
    status = _safe_str(_first(snapshot, ("snapshot_status", "status", "Status"), "unknown")).lower()
    item["snapshot_status"] = "Snapshot exists" if status in ("available", "active", "completed") else ("Snapshot failed" if "error" in status or "fail" in status else "Snapshot status unknown")
    checks = [{"status": "READY"}]
    if "error" in status or "fail" in status:
        checks.append({"status": "BLOCKED"})
    elif status not in ("available", "active", "completed"):
        checks.append({"status": "NEEDS MANUAL ACTION"})
    item["readiness_status"] = calculate_readiness_status(checks)
    item["risk_level"] = "High" if item["readiness_status"] == "BLOCKED" else ("Medium" if item["readiness_status"] != "READY" else "Low")
    item["manual_action_required"] = "Verify snapshot status" if item["readiness_status"] != "READY" else "None"
    item["recommended_action"] = "Use active snapshot for Stage 2" if item["readiness_status"] == "READY" else "Recreate or repair snapshot"
    return item


def build_readiness_items(source_inventory: dict, app_dependencies: dict) -> list[dict]:
    source_inventory = source_inventory or {}
    app_dependencies = app_dependencies or {}
    items: List[Dict[str, Any]] = []

    vm_rows = _inventory_bucket(source_inventory, "vms", "servers", "instances")
    image_rows = _inventory_bucket(source_inventory, "images")
    volume_rows = _inventory_bucket(source_inventory, "volumes")
    snapshot_rows = _inventory_bucket(source_inventory, "snapshots", "volume_snapshots", "image_snapshots")

    if not any((vm_rows, image_rows, volume_rows, snapshot_rows)):
        generic_rows = _inventory_bucket(source_inventory, "items", "rows")
        for row in generic_rows:
            text = " ".join(_safe_str(v) for v in row.values()).lower()
            kind = _safe_str(_first(row, ("resource_type", "asset_type", "type"), "")).lower()
            if "volume" in kind or "volume" in text and "snapshot" not in kind:
                volume_rows.append(row)
            elif "snapshot" in kind or "snapshot" in text:
                snapshot_rows.append(row)
            elif "image" in kind or _first(row, ("disk_format", "image_id"), ""):
                image_rows.append(row)
            else:
                vm_rows.append(row)

    for vm in vm_rows:
        items.append(evaluate_vm_readiness(vm, _find_appdep(app_dependencies, vm)))
    for image in image_rows:
        items.append(evaluate_image_readiness(image))
    for volume in volume_rows:
        items.append(evaluate_volume_readiness(volume))
    for snapshot in snapshot_rows:
        items.append(evaluate_snapshot_readiness(snapshot))
    return items


def _summary(items: List[Dict[str, Any]]) -> Dict[str, int]:
    return {
        "total_items": len(items or []),
        "ready": sum(1 for item in items if item.get("readiness_status") == "READY"),
        "ready_with_warning": sum(1 for item in items if item.get("readiness_status") == "READY WITH WARNING"),
        "blocked": sum(1 for item in items if item.get("readiness_status") == "BLOCKED"),
        "needs_manual_action": sum(1 for item in items if item.get("readiness_status") == "NEEDS MANUAL ACTION"),
    }


def build_readiness_fix_plan(items: list[dict]) -> str:
    items = items or []
    lines = ["# Migration Readiness Fix Plan", "", f"Created: {_now()}", ""]
    actionable = [item for item in items if item.get("readiness_status") != "READY"]
    if not actionable:
        lines.append("All scanned items are READY. Continue to Migration Pre-Flight Check.")
    for item in actionable:
        lines.extend([
            f"## {item.get('resource_name') or item.get('resource_id') or 'Unnamed resource'}",
            "",
            f"- Type: {item.get('resource_type', '')}",
            f"- Status: {item.get('readiness_status', '')}",
            f"- Risk: {item.get('risk_level', '')}",
            f"- Issue: {item.get('manual_action_required', '') or 'Review required'}",
            f"- Fix: {item.get('recommended_action', '') or 'Resolve blocker and rerun readiness scan'}",
            f"- Notes: {'; '.join(item.get('notes') or []) or 'None'}",
            "",
        ])
    return "\n".join(lines)


def _write_csv(path: Path, rows: List[Dict[str, Any]]) -> None:
    fieldnames = [
        "selected", "resource_type", "resource_name", "resource_id", "source_cloud", "source_region",
        "vm_status", "os_type", "boot_mode", "image_type", "disk_size_gb", "volume_count",
        "snapshot_status", "network_status", "db_detected", "readiness_status", "risk_level",
        "manual_action_required", "recommended_action", "notes",
    ]
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            out = {key: row.get(key, "") for key in fieldnames}
            out["notes"] = " | ".join(row.get("notes") or []) if isinstance(row.get("notes"), list) else row.get("notes", "")
            writer.writerow(out)


def write_readiness_artifacts(items: list[dict]) -> dict:
    items = items or []
    tmp_runs = ensure_tmp_runs()
    payload = {
        "stage": "stage_1_discovery",
        "feature": "migration_readiness_scanner",
        "created_at": _now(),
        "source_cloud": items[0].get("source_cloud", "") if items else "",
        "source_region": items[0].get("source_region", "") if items else "",
        "summary": _summary(items),
        "items": items,
    }
    json_path = tmp_runs / "migration_readiness_report.json"
    csv_path = tmp_runs / "migration_readiness_report.csv"
    md_path = tmp_runs / "migration_readiness_fix_plan.md"
    json_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    _write_csv(csv_path, items)
    md_path.write_text(build_readiness_fix_plan(items), encoding="utf-8")
    return {
        "migration_readiness_report.json": str(json_path),
        "migration_readiness_report.csv": str(csv_path),
        "migration_readiness_fix_plan.md": str(md_path),
    }


def send_readiness_to_stage2(selected_items: list[dict]) -> dict:
    selected_items = [dict(item, selected=True) for item in (selected_items or [])]
    tmp_runs = ensure_tmp_runs()
    payload = {
        "stage": "stage_2_migrations",
        "source_stage": "migration_readiness_scanner",
        "feature": "stage2_readiness_handoff",
        "created_at": _now(),
        "item_count": len(selected_items),
        "items": selected_items,
    }
    json_path = tmp_runs / "stage2_readiness_handoff.json"
    csv_path = tmp_runs / "stage2_readiness_handoff.csv"
    json_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    _write_csv(csv_path, selected_items)
    return {
        "payload": payload,
        "artifacts": {
            "stage2_readiness_handoff.json": str(json_path),
            "stage2_readiness_handoff.csv": str(csv_path),
        },
    }


def render_migration_readiness_scanner() -> None:
    """Optional Streamlit renderer for environments that use services/ui."""
    try:
        import streamlit as st  # type: ignore
    except Exception:
        return
    st.subheader("✅ Migration Readiness Scanner")
    st.caption("Check if selected VMs, volumes, images, databases, and snapshots are ready to move to FLEX.")
    ss = st.session_state
    ss.setdefault("migration_readiness_items", [])
    ss.setdefault("migration_readiness_selected", [])
    ss.setdefault("stage2_readiness_handoff_ready", False)
    if st.button("✅ Run Readiness Scan"):
        ss["migration_readiness_items"] = build_readiness_items(load_source_inventory(), load_app_dependency_results())
        write_readiness_artifacts(ss["migration_readiness_items"])
    st.dataframe(ss.get("migration_readiness_items") or [], use_container_width=True)
