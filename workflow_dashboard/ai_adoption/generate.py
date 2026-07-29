"""Generators: target architecture, Palantir mapping, passport, report.

Everything produced here is labelled PROPOSED. This tool plans and evidences; it
does not provision. The specification was explicit — "do not claim deployment
has occurred when only a plan exists" — and that distinction is carried on every
artifact rather than assumed.
"""

from __future__ import annotations

import csv
import io
import json
from typing import Any, Dict, List

from .models import JOURNEYS, now_ms

LIFECYCLE = ("PROPOSED", "APPROVED", "PROVISIONED", "VALIDATED", "PRODUCTION")


# ---------------------------------------------------------------- architecture


def build_architecture(project: Dict[str, Any], scan: Dict[str, Any], assessment: Dict[str, Any]) -> Dict[str, Any]:
    sens = str(project.get("data_sensitivity") or "").upper()
    det = scan.get("detected", {}) if isinstance(scan, dict) else {}
    regulated = sens in ("HIGH", "REGULATED")
    gpu = bool(det.get("model_runtime")) and any(
        r in det.get("model_runtime", []) for r in ("vLLM", "HF Transformers", "PyTorch", "TGI", "Ollama")
    )

    components: List[Dict[str, str]] = [
        {"name": "FLEX OpenStack project", "role": "tenancy and quota boundary"},
        {"name": "OpenCenter Kubernetes cluster", "role": "workload orchestration"},
        {"name": "Namespace + NetworkPolicy", "role": "isolation, default-deny egress"},
        {"name": "Ingress + TLS", "role": "north-south entry"},
        {"name": "Secrets manager", "role": "credential storage; no secrets in images"},
        {"name": "Object storage", "role": "artifacts, prompt logs, backups"},
        {"name": "Monitoring + logging", "role": "SLO evidence and audit trail"},
    ]
    if det.get("vector_store"):
        components.append({"name": f"Vector store ({det['vector_store'][0]})", "role": "retrieval index"})
    if det.get("database"):
        components.append({"name": f"Database ({det['database'][0]})", "role": "system of record"})
    if gpu:
        components.append({"name": "GPU node pool", "role": "model serving"})
    else:
        components.append({"name": "CPU node pool", "role": "inference and application"})
    if regulated:
        components.append({"name": "Dedicated/private zone", "role": f"{sens} data residency"})
    if project.get("palantir_required") or regulated:
        components.append({"name": "Foundry connector", "role": "dataset sync and ontology binding"})

    return {
        "lifecycle_state": "PROPOSED",
        "generated_at": now_ms(),
        "target_platform": "FLEX (Rackspace OpenStack) + OpenCenter Kubernetes",
        "components": components,
        "gpu_required": gpu,
        "data_zone": "private / dedicated" if regulated else "standard FLEX tenancy",
        "open_ports": [{"port": 443, "purpose": "HTTPS ingress"}, {"port": 8080, "purpose": "service (cluster-internal)"}],
        "bill_of_materials": [c["name"] for c in components],
        "assumptions": [
            "Rackspace operates the FLEX tenancy and the OpenCenter cluster.",
            "Egress is default-deny; every external endpoint is allow-listed explicitly.",
            "No customer data is used for model training unless separately approved.",
        ],
        "unresolved": _unresolved(project, scan),
        "mermaid": _mermaid(project, det, gpu, regulated),
    }


def _unresolved(project: Dict[str, Any], scan: Dict[str, Any]) -> List[str]:
    """Open questions. Blank beats a plausible guess."""
    out: List[str] = []
    if not project.get("data_sensitivity"):
        out.append("Data sensitivity not classified.")
    if not project.get("production_owner"):
        out.append("Production owner not assigned.")
    if not project.get("business_owner"):
        out.append("Business sponsor not named.")
    if scan.get("external_endpoints"):
        total = scan.get("external_endpoint_count") or len(scan["external_endpoints"])
        shown = len(scan["external_endpoints"])
        suffix = f" ({shown} listed)" if total > shown else ""
        out.append(f"{total} external endpoint(s) need an egress decision{suffix}.")
    if not scan.get("scanned"):
        out.append("No source tree was scanned; code-level findings are unverified.")
    return out


def _mermaid(project: Dict[str, Any], det: Dict[str, List[str]], gpu: bool, regulated: bool) -> str:
    lines = [
        "flowchart LR",
        "  U[User / Existing App] --> IG[Ingress + TLS]",
        "  IG --> AG[Agent runtime]",
        "  AG --> M[Model runtime%s]" % (" GPU" if gpu else " CPU"),
    ]
    if det.get("vector_store"):
        lines.append(f"  AG --> V[(Vector store: {det['vector_store'][0]})]")
    if det.get("database"):
        lines.append(f"  AG --> D[(Database: {det['database'][0]})]")
    lines.append("  AG --> S[Secrets manager]")
    lines.append("  AG --> L[Logging / metrics]")
    if project.get("palantir_required") or regulated:
        lines.append("  AG --> F[Foundry connector]")
        lines.append("  F --> ONT[AIP ontology + actions]")
    if project.get("adoption_mode") == "BROWNFIELD":
        lines.append("  U -.rollback: AI disabled.-> APP[Original application]")
    return "\n".join(lines)


# ---------------------------------------------------------------- palantir


def build_palantir_mapping(project: Dict[str, Any], scan: Dict[str, Any]) -> Dict[str, Any]:
    """A filled-in Foundry/AIP deliverable, not a modelling exercise.

    Agent tools are derived from the routes the scanner actually found, so the
    customer's Foundry team receives concrete candidates instead of a template.
    """
    routes = scan.get("api_routes", []) if isinstance(scan, dict) else []
    tools = []
    seen = set()
    for r in routes:
        path = r.get("path", "")
        if not path or path in seen:
            continue
        seen.add(path)
        method = r.get("method", "ANY")
        # Anything not provably a read is treated as state-changing and gated.
        mutating = method in ("POST", "PUT", "PATCH", "DELETE", "ANY")
        tools.append(
            {
                "tool_name": "tool_" + path.strip("/").replace("/", "_").replace("<", "").replace(">", "").replace(":", "") or "tool_root",
                "endpoint": path,
                "method": method,
                "permission": "WRITE" if mutating else "READ",
                "human_approval_required": mutating,
                "audit_event": True,
            }
        )
        if len(tools) >= 25:
            break

    sens = str(project.get("data_sensitivity") or "").upper()
    return {
        "lifecycle_state": "PROPOSED",
        "required_datasets": [
            {"name": f"{project.get('name') or 'project'}_source", "classification": sens or "UNCLASSIFIED"},
        ],
        "proposed_ontology_objects": [
            {"object": "BusinessSystem", "source": project.get("name") or ""},
            {"object": "Department", "source": project.get("department_id") or ""},
        ],
        "aip_tools": tools,
        "approvals": [
            {"action": t["tool_name"], "approver_role": "Business owner"}
            for t in tools
            if t["human_approval_required"]
        ][:15],
        "security_requirements": [
            "AIP policies mirror the agent's permission level; deny by default.",
            "Every tool invocation emits an audit event with a correlation id.",
            "Regulated datasets stay in the customer's residency boundary." if sens in ("HIGH", "REGULATED") else
            "Dataset residency confirmed before connector enablement.",
        ],
        "open_questions": [
            "Which Foundry environment and connector credentials will be used?",
            "Who approves ontology changes?",
        ] + ([] if tools else ["No API routes were detected — tools must be defined manually."]),
    }


# ---------------------------------------------------------------- passport


def build_passport(project: Dict[str, Any], scan: Dict[str, Any], assessment: Dict[str, Any], kind: str = "POC") -> Dict[str, Any]:
    """One passport with a kind, rather than four near-identical documents."""
    det = scan.get("detected", {}) if isinstance(scan, dict) else {}
    src = project.get("import_source", {}) or {}
    return {
        "kind": kind,  # AGENT | APPLICATION | POC | DEPLOYMENT
        "lifecycle_state": "PROPOSED",
        "generated_at": now_ms(),
        "project": {
            "id": project.get("id"),
            "name": project.get("name"),
            "adoption_mode": project.get("adoption_mode"),
            "customer_id": project.get("customer_id"),
        },
        "source": {
            "provider": src.get("provider", ""),
            "uri": src.get("source_uri", ""),
            "branch": src.get("branch", ""),
            "commit": src.get("commit_sha", ""),
            "imported_at": src.get("imported_at"),
        },
        "owners": {
            "business": project.get("business_owner", ""),
            "technical": project.get("technical_owner", ""),
            "data": project.get("data_owner", ""),
            "production": project.get("production_owner", ""),
        },
        "stack": {
            "languages": scan.get("languages", {}),
            "app_frameworks": det.get("app_framework", []),
            "ai_frameworks": det.get("ai_framework", []),
            "model_runtimes": det.get("model_runtime", []),
            "vector_stores": det.get("vector_store", []),
            "deployment_assets": scan.get("deployment_assets", []),
        },
        "data": {
            "sensitivity": project.get("data_sensitivity", ""),
            "sovereignty": project.get("sovereignty_requirements", ""),
            "external_endpoints": scan.get("external_endpoints", [])[:20],
        },
        "readiness": {
            "score": assessment.get("readiness_score"),
            "confidence": assessment.get("confidence"),
            "verdict": assessment.get("verdict"),
            "controls_checked": assessment.get("controls_checked"),
            "controls_not_checked": assessment.get("controls_not_checked"),
        },
        "gaps": [
            {"severity": g["severity"], "title": g["title"], "remediation": g["remediation"]}
            for g in assessment.get("gaps", [])
        ],
        "licenses": scan.get("licenses", []),
    }


# ---------------------------------------------------------------- journey


# How many leading journey steps this tool actually performs itself. Everything
# beyond that is a Rackspace delivery engagement or a customer activity, and can
# never be marked DONE from inside CloudJumper — producing a plan does not
# complete an AI LaunchPad.
SELF_COMPLETED_STEPS = {
    "GREENFIELD": 0,   # FAIR Ideate onwards are all delivery engagements
    "BROWNFIELD": 2,   # Application Discovery, Integration Readiness
    "EXISTING_POC": 2,  # PoC Import, Production Gap Assessment
}

_STATUS_PROGRESS = {"DRAFT": 0, "IMPORTED": 1, "ASSESSED": 2, "PLANNED": 2, "HANDED_OFF": 3, "ARCHIVED": 3}


def build_journey(project: Dict[str, Any], assessment: Dict[str, Any]) -> List[Dict[str, Any]]:
    mode = project.get("adoption_mode") or ""
    steps = JOURNEYS.get(mode, [])
    owned = SELF_COMPLETED_STEPS.get(mode, 0)

    # Done-ness is bounded twice: by how far this project has got, and by how
    # many steps this tool is entitled to complete at all.
    done = min(_STATUS_PROGRESS.get(project.get("status"), 0), owned)
    blockers = [g["title"] for g in assessment.get("gaps", []) if g["severity"] == "CRITICAL"][:3]

    out = []
    for i, name in enumerate(steps):
        if i < done:
            status = "DONE"
        elif i == done:
            # The next step is only "in progress" once there is a plan to act on.
            status = "IN_PROGRESS" if project.get("status") in ("PLANNED", "HANDED_OFF") else "PENDING"
        else:
            status = "PENDING"
        out.append(
            {
                "step": name,
                "status": status,
                "performed_by": "CloudJumper" if i < owned else "Rackspace delivery",
                "owner": project.get("technical_owner") or "",
                "blockers": blockers if status == "IN_PROGRESS" else [],
            }
        )
    return out


# ---------------------------------------------------------------- reports


def report_markdown(project: Dict[str, Any]) -> str:
    a = project.get("assessment_result", {}) or {}
    rec = project.get("recommendation", {}) or {}
    arch = project.get("deployment_plan", {}) or {}
    pal = project.get("palantir_mapping", {}) or {}
    scan = project.get("scan_result", {}) or {}

    def line(k: str, v: Any) -> str:
        return f"| {k} | {v if v not in (None, '', []) else '—'} |"

    md: List[str] = []
    md.append(f"# AI Adoption Report — {project.get('name')}")
    md.append("")
    md.append(f"**Adoption mode:** {project.get('adoption_mode')}  ")
    md.append(f"**Status:** {project.get('status')}  ")
    md.append(f"**Lifecycle:** PROPOSED — this is a plan, not a deployment.")
    if project.get("time_to_plan_ms"):
        md.append(f"**Time from import to plan:** {round(project['time_to_plan_ms'] / 1000, 1)}s")
    md.append("")

    md.append("## Readiness")
    md.append("")
    md.append("| Field | Value |")
    md.append("|---|---|")
    md.append(line("Score", f"{a.get('readiness_score')}%"))
    md.append(line("Verdict", a.get("verdict")))
    md.append(line("Confidence", f"{a.get('confidence')}% ({a.get('controls_checked')} checked, {a.get('controls_not_checked')} not checked)"))
    md.append(line("Formula", a.get("formula")))
    md.append("")

    if a.get("category_scores"):
        md.append("| Category | Score | Weight | Checked | Not checked |")
        md.append("|---|---|---|---|---|")
        for cat, b in (a.get("breakdown") or {}).items():
            md.append(f"| {cat} | {b['score']}% | {b['weight']} | {b['checked']} | {b['not_checked']} |")
        md.append("")

    md.append("## Recommendation")
    md.append("")
    md.append("| Field | Value |")
    md.append("|---|---|")
    md.append(line("Recommended entry", rec.get("recommended_entry")))
    md.append(line("Why", rec.get("why")))
    md.append(line("Main gap", rec.get("main_gap")))
    md.append(line("Scale-up path", rec.get("scale_up_path")))
    md.append(line("Estimated effort", rec.get("estimated_effort")))
    md.append(line("Palantir fit", rec.get("palantir_fit")))
    md.append(line("Next action", rec.get("next_action")))
    md.append("")

    gaps = a.get("gaps", [])
    md.append(f"## Production gaps ({len(gaps)})")
    md.append("")
    if gaps:
        md.append("| Severity | Gap | Remediation | Evidence |")
        md.append("|---|---|---|---|")
        for g in gaps:
            md.append(f"| {g['severity']} | {g['title']} | {g['remediation']} | {g.get('evidence') or '—'} |")
    else:
        md.append("None recorded.")
    md.append("")

    if arch.get("mermaid"):
        md.append("## Proposed target architecture")
        md.append("")
        md.append("```mermaid")
        md.append(arch["mermaid"])
        md.append("```")
        md.append("")
        md.append("**Bill of materials:** " + ", ".join(arch.get("bill_of_materials", [])))
        md.append("")
        if arch.get("unresolved"):
            md.append("**Unresolved decisions:**")
            for u in arch["unresolved"]:
                md.append(f"- {u}")
            md.append("")

    if pal.get("aip_tools"):
        md.append("## Palantir Foundry / AIP mapping")
        md.append("")
        md.append("| Tool | Endpoint | Method | Permission | Human approval |")
        md.append("|---|---|---|---|---|")
        for t in pal["aip_tools"][:25]:
            md.append(f"| {t['tool_name']} | {t['endpoint']} | {t['method']} | {t['permission']} | {'Yes' if t['human_approval_required'] else 'No'} |")
        md.append("")

    if scan.get("scanned"):
        md.append("## Discovered stack")
        md.append("")
        for cat, items in (scan.get("detected") or {}).items():
            if items:
                md.append(f"- **{cat}**: {', '.join(items)}")
        md.append("")

    md.append("---")
    md.append("")
    md.append("Generated by CloudJumper Stage 9 — AI Adoption & Production Factory.")
    return "\n".join(md)


def report_csv(project: Dict[str, Any]) -> str:
    a = project.get("assessment_result", {}) or {}
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(["section", "key", "value"])
    w.writerow(["project", "name", project.get("name", "")])
    w.writerow(["project", "adoption_mode", project.get("adoption_mode", "")])
    w.writerow(["project", "source_type", project.get("source_type", "")])
    w.writerow(["project", "status", project.get("status", "")])
    w.writerow(["readiness", "score", a.get("readiness_score", "")])
    w.writerow(["readiness", "verdict", a.get("verdict", "")])
    w.writerow(["readiness", "confidence", a.get("confidence", "")])
    for cat, score in (a.get("category_scores") or {}).items():
        w.writerow(["category", cat, score])
    for g in a.get("gaps", []):
        w.writerow(["gap", g["severity"], g["title"]])
    rec = project.get("recommendation", {}) or {}
    for k in ("recommended_entry", "main_gap", "scale_up_path", "estimated_effort", "next_action"):
        w.writerow(["recommendation", k, rec.get(k, "")])
    return buf.getvalue()


def report_json(project: Dict[str, Any]) -> str:
    return json.dumps(project, indent=2)
