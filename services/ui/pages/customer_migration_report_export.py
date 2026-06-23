#!/usr/bin/env python3
"""Customer migration report export helpers."""

from __future__ import annotations

import csv
import html
import json
import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List


def repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def ensure_output_dirs() -> Dict[str, Path]:
    root = repo_root()
    dirs = {"tmp": root / ".tmp_runs", "handover": root / "outputs" / "handover"}
    for path in dirs.values():
        path.mkdir(parents=True, exist_ok=True)
    return dirs


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def load_json_if_exists(path: str) -> dict:
    try:
        p = Path(path)
        if not p.is_absolute():
            p = repo_root() / p
        if p.exists():
            data = json.loads(p.read_text(encoding="utf-8"))
            return data if isinstance(data, dict) else {}
    except Exception:
        return {}
    return {}


def load_csv_if_exists(path: str) -> list[dict]:
    try:
        p = Path(path)
        if not p.is_absolute():
            p = repo_root() / p
        if p.exists():
            with p.open("r", encoding="utf-8-sig", newline="") as handle:
                return list(csv.DictReader(handle))
    except Exception:
        return []
    return []


def collect_migration_evidence() -> dict:
    root = repo_root()
    specs = [
        ("Stage 1", "app_dependencies.csv", root / ".tmp_runs" / "app_dependencies.csv", "csv"),
        ("Stage 1", "selected_app_dependencies.csv", root / ".tmp_runs" / "selected_app_dependencies.csv", "csv"),
        ("Stage 1", "migration_readiness_report.json", root / ".tmp_runs" / "migration_readiness_report.json", "json"),
        ("Stage 1", "migration_preflight_report.json", root / ".tmp_runs" / "migration_preflight_report.json", "json"),
        ("Stage 1", "stage2_readiness_handoff.json", root / ".tmp_runs" / "stage2_readiness_handoff.json", "json"),
        ("Stage 1", "stage2_preflight_handoff.json", root / ".tmp_runs" / "stage2_preflight_handoff.json", "json"),
        ("Stage 2", "stage2_migration_output.json", root / ".tmp_runs" / "stage2_migration_output.json", "json"),
        ("Stage 2", "stage2_migration_queue.json", root / ".tmp_runs" / "stage2_migration_queue.json", "json"),
        ("Stage 2", "selected_snapshot_plan.json", root / ".tmp_runs" / "selected_snapshot_plan.json", "json"),
        ("Stage 2", "snapshot_selected_commands.sh", root / ".tmp_runs" / "snapshot_selected_commands.sh", "text"),
        ("Stage 3", "post_migration_health_report.json", root / ".tmp_runs" / "post_migration_health_report.json", "json"),
        ("Stage 3", "post_migration_health_report.json", root / "outputs" / "uat" / "post_migration_health_report.json", "json"),
        ("Stage 4", "rollback_plan.json", root / ".tmp_runs" / "rollback_plan.json", "json"),
        ("Stage 4", "rollback_plan.json", root / "outputs" / "cutover" / "rollback_plan.json", "json"),
        ("Stage 4", "rollback_commands.sh", root / ".tmp_runs" / "rollback_commands.sh", "text"),
    ]
    loaded: List[Dict[str, Any]] = []
    missing: List[Dict[str, Any]] = []
    data: Dict[str, Any] = {}
    for stage, artifact, path, kind in specs:
        rel = str(path.relative_to(root)) if path.is_relative_to(root) else str(path)
        if path.exists():
            loaded.append({"stage": stage, "artifact": artifact, "path": rel, "status": "loaded", "included_in_report": True, "warning": "", "actions": "View | Download | Validate"})
            if kind == "json":
                data[rel] = load_json_if_exists(str(path))
            elif kind == "csv":
                data[rel] = load_csv_if_exists(str(path))
            else:
                try:
                    data[rel] = path.read_text(encoding="utf-8")
                except Exception:
                    data[rel] = ""
        else:
            missing.append({"stage": stage, "artifact": artifact, "path": rel, "status": "missing", "included_in_report": False, "warning": "Artifact not found; report will continue.", "actions": "Run prior stage"})
    return {"artifacts_loaded": loaded, "artifacts_missing": missing, "data": data}


def _first_report(evidence: dict, suffix: str) -> dict:
    for path, data in (evidence.get("data") or {}).items():
        if path.endswith(suffix) and isinstance(data, dict):
            return data
    return {}


def _items(payload: dict, key: str) -> list:
    value = (payload or {}).get(key)
    return value if isinstance(value, list) else []


def build_customer_migration_report(evidence: dict) -> dict:
    evidence = evidence or {}
    readiness = _first_report(evidence, "migration_readiness_report.json")
    preflight = _first_report(evidence, "migration_preflight_report.json")
    health = _first_report(evidence, "post_migration_health_report.json")
    rollback = _first_report(evidence, "rollback_plan.json")
    stage2 = _first_report(evidence, "stage2_migration_queue.json") or _first_report(evidence, "stage2_migration_output.json")
    readiness_items = _items(readiness, "items")
    stage2_items = _items(stage2, "items") or _items(stage2, "results")
    health_results = _items(health, "results")
    rollback_items = _items(rollback, "rollback_items")
    open_risks = [i for i in readiness_items if i.get("readiness_status") not in ("READY", "")]
    warnings = [c for c in _items(preflight, "checks") if c.get("status") in ("PASS WITH WARNING", "NEEDS INPUT", "FAIL")]
    return {
        "stage": "stage_5_stabilization_handover",
        "feature": "customer_migration_report_export",
        "created_at": _now(),
        "customer": {"name": "", "project": "", "migration_id": ""},
        "executive_summary": {
            "source_cloud": readiness.get("source_cloud", ""),
            "target_cloud": "FLEX",
            "source_region": readiness.get("source_region", ""),
            "target_region": ((preflight.get("target_flex") or {}).get("region", "")),
            "total_source_vms": len([i for i in readiness_items if i.get("resource_type") == "vm"]),
            "total_migrated_vms": len(stage2_items),
            "validated_vms": (health.get("summary") or {}).get("success", 0) + (health.get("summary") or {}).get("partial_success", 0),
            "failed_validations": (health.get("summary") or {}).get("failed", 0) + (health.get("summary") or {}).get("not_ready", 0),
            "overall_status": "READY FOR HANDOVER" if health_results and not (health.get("summary") or {}).get("failed", 0) else "REVIEW REQUIRED",
        },
        "source": {
            "cloud": readiness.get("source_cloud", ""),
            "region": readiness.get("source_region", ""),
            "vms": [i for i in readiness_items if i.get("resource_type") == "vm"],
            "images": [i for i in readiness_items if i.get("resource_type") == "image"],
            "volumes": [i for i in readiness_items if i.get("resource_type") == "volume"],
            "snapshots": [i for i in readiness_items if i.get("resource_type") == "snapshot"],
        },
        "target": {"cloud": "FLEX", "region": ((preflight.get("target_flex") or {}).get("region", "")), "vms": stage2_items, "images": [], "volumes": [], "snapshots": []},
        "migration_method": {"methods_used": sorted({str(i.get("migration_method") or i.get("recommended_action") or "") for i in stage2_items if i}), "details": stage2_items},
        "timeline": {"start_time": "", "end_time": "", "duration": ""},
        "validation": {"summary": health.get("summary", {}), "results": health_results},
        "risks": {"open_risks": open_risks, "warnings": warnings, "resolved": []},
        "rollback": {"summary": rollback.get("summary", {}), "items": rollback_items},
        "evidence": {"artifacts_loaded": evidence.get("artifacts_loaded", []), "artifacts_missing": evidence.get("artifacts_missing", []), "commands": [], "logs": []},
    }


def render_customer_report_markdown(report: dict) -> str:
    summary = report.get("executive_summary") or {}
    lines = [
        "# Customer Migration Report",
        "",
        "## 1. Executive Summary",
        "",
        f"- Overall status: {summary.get('overall_status', '')}",
        f"- Source: {summary.get('source_cloud', '')} / {summary.get('source_region', '')}",
        f"- Target: {summary.get('target_cloud', 'FLEX')} / {summary.get('target_region', '')}",
        f"- Migrated VMs: {summary.get('total_migrated_vms', 0)}",
        f"- Validated VMs: {summary.get('validated_vms', 0)}",
        "",
        "## 2. Source Environment",
        "",
        f"- VMs: {len((report.get('source') or {}).get('vms') or [])}",
        f"- Images: {len((report.get('source') or {}).get('images') or [])}",
        f"- Volumes: {len((report.get('source') or {}).get('volumes') or [])}",
        f"- Snapshots: {len((report.get('source') or {}).get('snapshots') or [])}",
        "",
        "## 3. Target FLEX Environment",
        "",
        f"- Region: {(report.get('target') or {}).get('region', '')}",
        f"- Target systems: {len((report.get('target') or {}).get('vms') or [])}",
        "",
        "## 4. Migration Method",
        "",
        ", ".join((report.get("migration_method") or {}).get("methods_used") or []) or "Not recorded",
        "",
        "## 5. Migration Timeline",
        "",
        "Timeline not recorded in available artifacts.",
        "",
        "## 6. Migrated Systems",
        "",
        f"{len((report.get('target') or {}).get('vms') or [])} migrated system item(s) loaded.",
        "",
        "## 7. Validation Results",
        "",
        json.dumps((report.get("validation") or {}).get("summary") or {}, indent=2),
        "",
        "## 8. Risks and Open Items",
        "",
        f"- Open risks: {len((report.get('risks') or {}).get('open_risks') or [])}",
        f"- Warnings: {len((report.get('risks') or {}).get('warnings') or [])}",
        "",
        "## 9. Rollback Plan",
        "",
        json.dumps((report.get("rollback") or {}).get("summary") or {}, indent=2),
        "",
        "## 10. Evidence and Artifacts",
        "",
        f"- Loaded: {len((report.get('evidence') or {}).get('artifacts_loaded') or [])}",
        f"- Missing: {len((report.get('evidence') or {}).get('artifacts_missing') or [])}",
        "",
        "## 11. Handover Notes",
        "",
        "Review open risks, validation warnings, and rollback readiness with the customer.",
        "",
        "## 12. Sign-Off",
        "",
        "- Customer sign-off:",
        "- Migration lead:",
        "- Date:",
        "",
    ]
    return "\n".join(lines)


def _html_table(rows: list[dict], columns: list[str]) -> str:
    body = []
    for row in rows[:200]:
        body.append("<tr>" + "".join(f"<td>{html.escape(str(row.get(col, '')))}</td>" for col in columns) + "</tr>")
    return "<table><thead><tr>" + "".join(f"<th>{html.escape(col)}</th>" for col in columns) + "</tr></thead><tbody>" + "".join(body) + "</tbody></table>"


def render_customer_report_html(report: dict) -> str:
    summary = report.get("executive_summary") or {}
    loaded = (report.get("evidence") or {}).get("artifacts_loaded") or []
    missing = (report.get("evidence") or {}).get("artifacts_missing") or []
    return f"""<!doctype html>
<html><head><meta charset="utf-8"><title>Customer Migration Report</title>
<style>
body{{margin:0;background:#020617;color:#dbeafe;font-family:Arial,sans-serif;}}
main{{max-width:1180px;margin:0 auto;padding:28px;}}
h1,h2{{color:#7dd3fc}} .cards{{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px}}
.card{{background:#0f172a;border:1px solid #1e3a8a;border-radius:8px;padding:14px}} .value{{font-size:24px;font-weight:800;color:#86efac}}
table{{width:100%;border-collapse:collapse;margin:12px 0;background:#0f172a}} th,td{{border:1px solid #334155;padding:7px;font-size:12px;text-align:left}} th{{color:#93c5fd;background:#111827}}
.status{{display:inline-block;padding:4px 8px;border-radius:999px;background:#2563eb;color:white;font-weight:700}}
@media print{{body{{background:white;color:#111}} .card,table{{background:white}}}}
</style></head><body><main>
<h1>Customer Migration Report</h1>
<p><span class="status">{html.escape(str(summary.get('overall_status','')))}</span></p>
<div class="cards">
<div class="card"><div>Source VMs</div><div class="value">{summary.get('total_source_vms',0)}</div></div>
<div class="card"><div>Migrated VMs</div><div class="value">{summary.get('total_migrated_vms',0)}</div></div>
<div class="card"><div>Validated VMs</div><div class="value">{summary.get('validated_vms',0)}</div></div>
<div class="card"><div>Failed Validations</div><div class="value">{summary.get('failed_validations',0)}</div></div>
<div class="card"><div>Rollback Items</div><div class="value">{len((report.get('rollback') or {}).get('items') or [])}</div></div>
<div class="card"><div>Open Risks</div><div class="value">{len((report.get('risks') or {}).get('open_risks') or [])}</div></div>
</div>
<h2>Validation</h2><pre>{html.escape(json.dumps((report.get('validation') or {}).get('summary') or {}, indent=2))}</pre>
<h2>Rollback</h2><pre>{html.escape(json.dumps((report.get('rollback') or {}).get('summary') or {}, indent=2))}</pre>
<h2>Evidence Loaded</h2>{_html_table(loaded, ['stage','artifact','path','status','included_in_report','warning'])}
<h2>Evidence Missing</h2>{_html_table(missing, ['stage','artifact','path','status','included_in_report','warning'])}
</main></body></html>"""


def write_customer_report_artifacts(report: dict, markdown: str, html_text: str) -> dict:
    dirs = ensure_output_dirs()
    artifacts: Dict[str, str] = {}
    for base in (dirs["handover"], dirs["tmp"]):
        json_path = base / "customer_migration_report.json"
        md_path = base / "customer_migration_report.md"
        html_path = base / "customer_migration_report.html"
        json_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        md_path.write_text(markdown, encoding="utf-8")
        html_path.write_text(html_text, encoding="utf-8")
        for path in (json_path, md_path, html_path):
            artifacts[str(path.relative_to(repo_root()))] = str(path)
    return artifacts


def add_customer_report_to_handover_bundle(paths: dict) -> None:
    root = repo_root()
    bundle_root = root / "uploads" / "migration_output_bundles"
    if not bundle_root.exists():
        return
    bundles = sorted([p for p in bundle_root.glob("*/*") if p.is_dir()], key=lambda p: p.stat().st_mtime, reverse=True)
    if not bundles:
        return
    target = bundles[0] / "handover"
    target.mkdir(parents=True, exist_ok=True)
    for path in (paths or {}).values():
        src = Path(path)
        if src.exists() and src.is_file():
            shutil.copy2(src, target / src.name)


def render_customer_migration_report_export() -> None:
    try:
        import streamlit as st  # type: ignore
    except Exception:
        return
    ss = st.session_state
    ss.setdefault("customer_migration_report", {})
    ss.setdefault("customer_migration_report_paths", {})
    st.subheader("📦 Customer Migration Report Export")
    if st.button("📥 Collect Migration Evidence"):
        ss["customer_migration_evidence"] = collect_migration_evidence()
    if st.button("📦 Export Customer Migration Report"):
        report = build_customer_migration_report(ss.get("customer_migration_evidence") or collect_migration_evidence())
        ss["customer_migration_report"] = report
        ss["customer_migration_report_paths"] = write_customer_report_artifacts(report, render_customer_report_markdown(report), render_customer_report_html(report))
    st.json(ss.get("customer_migration_report") or {})
