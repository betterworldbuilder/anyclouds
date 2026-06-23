#!/usr/bin/env python3
"""Rollback plan generator helpers for Stage 4 cutover."""

from __future__ import annotations

import csv
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List


ROLLBACK_AREAS = ["VM", "SNAPSHOT", "DNS", "APP", "DB", "NETWORK", "VALIDATION", "SECURITY", "LOAD_BALANCER", "FLOATING_IP"]


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


def load_cutover_input_artifacts() -> dict:
    root = repo_root()
    paths = [
        root / ".tmp_runs" / "post_migration_health_report.json",
        root / "outputs" / "uat" / "post_migration_health_report.json",
        root / ".tmp_runs" / "stage2_migration_output.json",
        root / ".tmp_runs" / "stage2_preflight_handoff.json",
        root / ".tmp_runs" / "stage2_readiness_handoff.json",
        root / ".tmp_runs" / "selected_snapshot_plan.json",
        root / "outputs" / "migration" / "stage2_migration_output.json",
    ]
    data: Dict[str, Any] = {"source_artifacts": [], "missing_artifacts": []}
    for path in paths:
        payload = _read_json(path)
        if payload:
            data[path.name] = payload
            data["source_artifacts"].append(str(path))
        else:
            data["missing_artifacts"].append(str(path))
    return data


def _rows(payload: Any) -> List[Dict[str, Any]]:
    if isinstance(payload, list):
        return [x for x in payload if isinstance(x, dict)]
    if isinstance(payload, dict):
        for key in ("results", "items", "rollback_items", "vms", "candidates"):
            value = payload.get(key)
            if isinstance(value, list):
                return [x for x in value if isinstance(x, dict)]
    return []


def _base_system(row: Dict[str, Any]) -> Dict[str, str]:
    return {
        "system_name": _safe_str(_first(row, "vm_name", "resource_name", "source_resource", "target_vm_name", "name", default="migration-system")),
        "source_vm_name": _safe_str(_first(row, "source_vm_name", "resource_name", "source_resource", "name", default="")),
        "source_instance_id": _safe_str(_first(row, "source_instance_id", "source_resource_id", "resource_id", default="")),
        "source_ip": _safe_str(_first(row, "source_ip", "rollback_value", default="")),
        "target_vm_name": _safe_str(_first(row, "target_vm_name", "vm_name", "resource_name", default="")),
        "target_instance_id": _safe_str(_first(row, "target_instance_id", "instance_id", "resource_id", "source_resource_id", default="")),
        "target_ip": _safe_str(_first(row, "target_ip", "ip", "fixed_ip", default="")),
    }


def build_rollback_items(artifacts: dict) -> list[dict]:
    artifacts = artifacts or {}
    systems: List[Dict[str, str]] = []
    for key, payload in artifacts.items():
        if key in {"source_artifacts", "missing_artifacts"}:
            continue
        for row in _rows(payload):
            systems.append(_base_system(row))
    if not systems:
        systems = [_base_system({"vm_name": "manual-rollback-plan"})]
    deduped: Dict[str, Dict[str, str]] = {}
    for system in systems:
        key = system.get("target_instance_id") or system.get("source_instance_id") or system.get("system_name")
        deduped[key] = system

    items: List[Dict[str, Any]] = []
    actions = {
        "VM": "Keep source VM stopped but not deleted; start source VM if rollback is required.",
        "SNAPSHOT": "Preserve source snapshot ID and verify it remains available.",
        "DNS": "Restore old DNS record.",
        "APP": "Restart source application service.",
        "DB": "Restore source DB or re-enable old primary.",
        "NETWORK": "Repoint traffic to old network path.",
        "VALIDATION": "Run old environment health check.",
        "SECURITY": "Confirm old security groups and ingress remain available.",
        "LOAD_BALANCER": "Reweight or repoint load balancer back to source pool.",
        "FLOATING_IP": "Reassociate floating IP back to old source port.",
    }
    for system in deduped.values():
        for area in ROLLBACK_AREAS:
            rollback_value = system.get("source_ip") if area in {"DNS", "NETWORK", "LOAD_BALANCER", "FLOATING_IP"} else system.get("source_instance_id")
            current_value = system.get("target_ip") if area in {"DNS", "NETWORK", "LOAD_BALANCER", "FLOATING_IP"} else system.get("target_instance_id")
            items.append({
                "selected": False,
                **system,
                "rollback_area": area,
                "rollback_action": actions[area],
                "current_cutover_value": current_value,
                "rollback_value": rollback_value,
                "command_required": area in {"VM", "DNS", "APP", "DB", "NETWORK", "VALIDATION", "LOAD_BALANCER", "FLOATING_IP"},
                "owner": "Cloud Admin Team",
                "estimated_time_minutes": 10 if area in {"VM", "DNS", "NETWORK"} else 15,
                "risk_level": "High" if area in {"DB", "DNS", "LOAD_BALANCER", "FLOATING_IP"} else "Medium",
                "status": "READY WITH WARNING",
                "notes": ["Dry-run rollback plan item. Commands are generated only, not executed."],
            })
    return items


def evaluate_rollback_readiness(items: list[dict]) -> list[dict]:
    evaluated = []
    for item in items or []:
        next_item = dict(item)
        if next_item.get("rollback_area") in {"DNS", "FLOATING_IP", "LOAD_BALANCER"} and not next_item.get("rollback_value"):
            next_item["status"] = "NEEDS INPUT"
            next_item["notes"] = (next_item.get("notes") or []) + ["Rollback value missing for traffic restore."]
        elif next_item.get("rollback_area") == "VM" and not next_item.get("source_instance_id"):
            next_item["status"] = "NEEDS INPUT"
            next_item["notes"] = (next_item.get("notes") or []) + ["Source instance ID missing."]
        else:
            next_item["status"] = "READY WITH WARNING" if next_item.get("command_required") else "READY"
        evaluated.append(next_item)
    return evaluated


def generate_rollback_commands(items: list[dict]) -> str:
    lines = ["#!/usr/bin/env bash", "set -o pipefail", "", "# DRY RUN rollback commands. Review before executing in production.", ""]
    for item in items or []:
        area = item.get("rollback_area")
        name = item.get("system_name") or "system"
        source_id = item.get("source_instance_id", "")
        source_ip = item.get("source_ip", "")
        target_ip = item.get("target_ip", "")
        lines.append(f"echo '===== {name} / {area} ====='")
        if area == "VM" and source_id:
            lines.append(f"openstack server start {source_id!r}")
            lines.append(f"openstack server show {source_id!r}")
        elif area == "DNS":
            lines.append(f"# DNS provider command placeholder: restore DNS from {target_ip or '<target_ip>'} back to {source_ip or '<source_ip>'}")
        elif area == "APP" and source_ip:
            lines.append(f"ssh ubuntu@{source_ip!r} 'sudo systemctl restart <app_service>'")
        elif area == "DB" and source_ip:
            lines.append(f"ssh ubuntu@{source_ip!r} '<db_read_only_health_check>'")
        elif area == "FLOATING_IP":
            lines.append("# openstack floating ip set --port <old_source_port_id> <floating_ip>")
        elif area == "VALIDATION" and source_ip:
            lines.append(f"ssh ubuntu@{source_ip!r} 'hostname; hostname -I; ss -tulpn; df -h'")
        else:
            lines.append(f"# Manual rollback step: {item.get('rollback_action', '')}")
        lines.append("")
    return "\n".join(lines) + "\n"


def _summary(items: List[Dict[str, Any]]) -> Dict[str, int]:
    return {
        "total_items": len(items or []),
        "ready": sum(1 for i in items if i.get("status") == "READY"),
        "ready_with_warning": sum(1 for i in items if i.get("status") == "READY WITH WARNING"),
        "blocked": sum(1 for i in items if i.get("status") == "BLOCKED"),
        "needs_input": sum(1 for i in items if i.get("status") == "NEEDS INPUT"),
    }


def build_rollback_markdown(plan: dict) -> str:
    lines = ["# Rollback Plan", "", f"Created: {plan.get('created_at', '')}", ""]
    for key, value in (plan.get("summary") or {}).items():
        lines.append(f"- {key}: {value}")
    lines.append("")
    for item in plan.get("rollback_items", []):
        lines.extend([f"## {item.get('system_name')} - {item.get('rollback_area')}", "", f"- Action: {item.get('rollback_action')}", f"- Current: {item.get('current_cutover_value')}", f"- Rollback: {item.get('rollback_value')}", f"- Status: {item.get('status')}", ""])
    return "\n".join(lines)


def write_rollback_artifacts(plan: dict, markdown: str, commands: str) -> dict:
    dirs = ensure_output_dirs()
    items = plan.get("rollback_items") or []
    artifacts: Dict[str, str] = {}
    for base in (dirs["cutover"], dirs["tmp"]):
        json_path = base / "rollback_plan.json"
        md_path = base / "rollback_plan.md"
        sh_path = base / "rollback_commands.sh"
        csv_path = base / "rollback_readiness.csv"
        json_path.write_text(json.dumps(plan, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        md_path.write_text(markdown, encoding="utf-8")
        sh_path.write_text(commands, encoding="utf-8")
        try:
            sh_path.chmod(0o700)
        except OSError:
            pass
        fieldnames = ["selected", "system_name", "source_vm_name", "source_instance_id", "source_ip", "target_vm_name", "target_instance_id", "target_ip", "rollback_area", "rollback_action", "current_cutover_value", "rollback_value", "command_required", "owner", "estimated_time_minutes", "risk_level", "status", "notes"]
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


def make_rollback_plan(items: list[dict], source_artifacts: list[str] | None = None) -> dict:
    items = evaluate_rollback_readiness(items or [])
    return {
        "stage": "stage_4_cutover_traffic_transition",
        "feature": "rollback_plan_generator",
        "created_at": _now(),
        "source_artifacts": source_artifacts or [],
        "summary": _summary(items),
        "rollback_items": items,
        "commands_path": "./outputs/cutover/rollback_commands.sh",
    }


def render_rollback_plan_generator() -> None:
    try:
        import streamlit as st  # type: ignore
    except Exception:
        return
    ss = st.session_state
    ss.setdefault("rollback_plan_items", [])
    ss.setdefault("rollback_plan_path", "")
    st.subheader("↩️ Rollback Plan Generator")
    if st.button("📥 Import Migration & Validation Artifacts"):
        artifacts = load_cutover_input_artifacts()
        ss["rollback_plan_items"] = build_rollback_items(artifacts)
    if st.button("↩️ Generate Rollback Plan"):
        plan = make_rollback_plan(ss.get("rollback_plan_items") or [])
        write_rollback_artifacts(plan, build_rollback_markdown(plan), generate_rollback_commands(plan["rollback_items"]))
    st.dataframe(ss.get("rollback_plan_items") or [], use_container_width=True)
