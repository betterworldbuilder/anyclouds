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
import os
import re
import urllib.error
import urllib.request
from typing import Any, Dict, List

from .models import JOURNEYS, now_ms

LIFECYCLE = ("PROPOSED", "APPROVED", "PROVISIONED", "VALIDATED", "PRODUCTION")


# ---------------------------------------------------------------- architecture


# Where the workload actually lands. Two different Kubernetes offerings — Spot
# ships its own managed control plane and is NOT OpenCenter — so the plan has to
# say which, and name the cluster, or admit it does not know.
RUNTIME_OPENCENTER = "OPENCENTER"
RUNTIME_SPOT = "SPOT_K8S"

_SLUG_RE = re.compile(r"[^a-z0-9-]+")


def _namespace_for(project: Dict[str, Any]) -> str:
    """A Kubernetes-legal namespace derived from the project identity.

    Identity, not display name. `global_ai_project_id` only exists on projects
    submitted from YES AI CAN, so falling back to `name` produced one-letter
    namespaces for projects called "A" — and two projects sharing a name would
    have collided on the same namespace. The project's own id is unique and
    always present, so it is the fallback.
    """
    parts = [
        project.get("global_ai_project_id"),   # set by YES AI CAN / AI 4 the People
        project.get("sender_project_id"),      # set on a submitted bundle
        project.get("id"),                     # always present, always unique
    ]
    raw = next((str(p) for p in parts if str(p or "").strip()), "")

    if raw:
        slug = _SLUG_RE.sub("-", raw.lower()).strip("-")
        # A bare UUID is unreadable in kubectl output, so prefix a name hint
        # when the identity is the id rather than a readable project code.
        if raw == str(project.get("id") or "") and project.get("name"):
            hint = _SLUG_RE.sub("-", str(project["name"]).lower()).strip("-")[:20].strip("-")
            if hint:
                slug = f"{hint}-{slug.split('-')[0]}"
    else:
        slug = ""

    slug = slug[:63].strip("-")
    # Kubernetes requires the first character to be alphanumeric.
    if not slug or not slug[0].isalnum():
        slug = f"ai-{slug}".strip("-")[:63]
    return slug or "ai-project"


def _opencenter_clusters(base_url: str = "") -> Dict[str, Any]:
    """Read the cluster list the OpenCenter GitOps stage already exposes.

    Read-only and best-effort: an unreachable API must leave the target
    unresolved rather than block planning or invent a cluster name.
    """
    url = (base_url or os.environ.get("OPENCENTER_API_BASE") or "http://127.0.0.1:5001").rstrip("/")
    try:
        req = urllib.request.Request(url + "/api/opencenter/clusters", headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read().decode("utf-8", "replace") or "{}")
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def resolve_runtime_target(project: Dict[str, Any], stack: Dict[str, Any] | None) -> Dict[str, Any]:
    """Decide which Kubernetes this deploys to, and name the cluster if we can.

    Nothing here is guessed. When no cluster can be read, the target is marked
    unresolved and the caller surfaces it as an open decision — a bill of
    materials line saying "OpenCenter Kubernetes cluster" with no cluster behind
    it is exactly the kind of plausible-but-unbound claim this engine refuses.
    """
    build_on = (stack or {}).get("build_on") or ""
    production_home = (stack or {}).get("production_home") or ""

    # Spot has its own managed Kubernetes. Sending a Spot-bound workload to the
    # OpenCenter GitOps repo would deploy it to the wrong cluster entirely.
    if build_on == "Rackspace Spot":
        return {
            "runtime": RUNTIME_SPOT,
            "runtime_label": "Rackspace Spot managed Kubernetes",
            "cluster": None,
            "organization": None,
            "namespace": _namespace_for(project),
            "gitops_repo": None,
            "resolved": False,
            "note": "Spot provides its own managed Kubernetes control plane; it is not OpenCenter. "
                    "The Cloudspace and node pools are created when the build starts.",
        }

    info = _opencenter_clusters()
    pair = info.get("active_pair") if isinstance(info.get("active_pair"), dict) else {}
    cluster = (pair.get("cluster") or info.get("active_cluster") or "").strip() or None
    organization = (pair.get("organization") or info.get("organization") or "").strip() or None

    return {
        "runtime": RUNTIME_OPENCENTER,
        "runtime_label": f"OpenCenter Kubernetes ({production_home or 'FLEX + OpenCenter'})",
        "cluster": cluster,
        "organization": organization,
        "namespace": _namespace_for(project),
        # The repo s9 manages. Named only when the org is known.
        "gitops_repo": f"{organization}" if organization else None,
        "resolved": bool(cluster and organization),
        "available_clusters": info.get("clusters") or [],
        "note": (
            f"Deploys to OpenCenter cluster '{cluster}' in organisation '{organization}'."
            if cluster and organization
            else "No OpenCenter cluster could be read, so the target cluster is undecided."
        ),
    }


def build_architecture(project: Dict[str, Any], scan: Dict[str, Any], assessment: Dict[str, Any]) -> Dict[str, Any]:
    sens = str(project.get("data_sensitivity") or "").upper()
    det = scan.get("detected", {}) if isinstance(scan, dict) else {}
    regulated = sens in ("HIGH", "REGULATED")
    gpu = bool(det.get("model_runtime")) and any(
        r in det.get("model_runtime", []) for r in ("vLLM", "HF Transformers", "PyTorch", "TGI", "Ollama")
    )

    # Resolve where this actually lands before listing it as a component.
    target = resolve_runtime_target(project, (assessment or {}).get("service_stack") or project.get("service_stack"))

    if target["runtime"] == RUNTIME_SPOT:
        orchestration = {"name": "Rackspace Spot managed Kubernetes",
                         "role": "workload orchestration (spot + on-demand node pools)"}
    elif target["resolved"]:
        orchestration = {"name": f"OpenCenter cluster '{target['cluster']}'",
                         "role": f"workload orchestration · org {target['organization']} · ns {target['namespace']}"}
    else:
        # Named honestly: no cluster read, so this is not yet a decision.
        orchestration = {"name": "OpenCenter Kubernetes cluster (not yet chosen)",
                         "role": "workload orchestration — target cluster undecided"}

    components: List[Dict[str, str]] = [
        {"name": "FLEX OpenStack project", "role": "tenancy and quota boundary"},
        orchestration,
        {"name": f"Namespace {target['namespace']} + NetworkPolicy", "role": "isolation, default-deny egress"},
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
        "target_platform": target["runtime_label"],
        "runtime_target": target,
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
        "unresolved": _unresolved(project, scan, target),
        "mermaid": _mermaid(project, det, gpu, regulated),
    }


def _unresolved(project: Dict[str, Any], scan: Dict[str, Any], target: Dict[str, Any] | None = None) -> List[str]:
    """Open questions. Blank beats a plausible guess."""
    out: List[str] = []
    if target and not target.get("resolved"):
        if target.get("runtime") == RUNTIME_SPOT:
            out.append("Spot Cloudspace and node pools not yet created — sizing decided at build time.")
        else:
            out.append(
                "Target OpenCenter cluster not chosen. "
                + (f"Available: {', '.join(target.get('available_clusters') or [])}. "
                   if target.get("available_clusters") else "No clusters were readable. ")
                + "A GitOps overlay cannot be generated until a cluster and organisation are named."
            )
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

    # A declared business-system ontology gives real objects, links and actions.
    # Without one we fall back to the two generic objects, which is a much
    # weaker deliverable — the difference is visible in the output.
    onto = project.get("business_ontology") or {}
    declared = (onto.get("ontology") or {}) if isinstance(onto, dict) else {}
    if declared.get("object"):
        objects = [{"object": "BusinessSystem", "source": declared["object"].get("name", "")}]
        objects += [{"object": "Organisation", "source": link["to"]} for link in declared.get("links", [])]
        # Tools derived from declared pain carry the pain that justified them.
        for tool in onto.get("ai_tools", []):
            tools.append({
                "tool_name": "tool_" + tool["tool"].lower().replace(" ", "_")[:40],
                "endpoint": "(to be implemented)",
                "method": "POST" if tool["changes_data"] else "GET",
                "permission": tool["permission"],
                "human_approval_required": tool["human_approval_required"],
                "audit_event": True,
                "derived_from_pain": tool["because"],
            })
    else:
        objects = [
            {"object": "BusinessSystem", "source": project.get("name") or ""},
            {"object": "Department", "source": project.get("department_id") or ""},
        ]

    return {
        "lifecycle_state": "PROPOSED",
        "required_datasets": [
            {"name": f"{project.get('name') or 'project'}_source", "classification": sens or "UNCLASSIFIED"},
        ],
        "proposed_ontology_objects": objects,
        "object_relationships": declared.get("links", []),
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
    if project.get("is_demo"):
        # Must be the first thing a reader sees, not a footnote.
        md.append("> ⚠️ **DEMO — sample data, not a real customer system.** "
                  "Nothing in this report describes a real assessment.")
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

    # The business case, in the words the customer used. This is what Greenfield
    # exists to gather, so it leads the report rather than being buried.
    onto = project.get("business_ontology") or {}
    if onto.get("ai_tools") or (onto.get("ontology") or {}).get("object"):
        props = (onto.get("ontology") or {}).get("properties") or {}
        links = (onto.get("ontology") or {}).get("links") or []
        md.append("## Business case")
        md.append("")
        md.append(line("Business system", onto.get("system")))
        md.append(line("Pain points", ", ".join(props.get("pain_points") or [])))
        md.append(line("Current inputs", ", ".join(props.get("current_inputs") or [])))
        md.append(line("Desired outputs", ", ".join(props.get("desired_outputs") or [])))
        md.append(line("Related teams", ", ".join(x.get("to", "") for x in links)))
        md.append(line("Where AI sits", onto.get("placement")))
        md.append("")
        if onto.get("ai_tools"):
            md.append("### Proposed AI tools")
            md.append("")
            md.append("| Build this | Capability | Because | Human approval |")
            md.append("|---|---|---|---|")
            for t in onto["ai_tools"]:
                md.append(
                    f"| {t['tool']} | {t['capability']} | {', '.join(t['because'])} | "
                    f"{'Required' if t['human_approval_required'] else 'No'} |"
                )
            md.append("")
        if onto.get("missing"):
            md.append("**Still to answer:** " + " · ".join(onto["missing"]))
            md.append("")

    integ = project.get("integration") or {}
    if integ:
        md.append("## Integration with the existing application")
        md.append("")
        md.append("| Field | Value |")
        md.append("|---|---|")
        md.append(line("Pattern", integ.get("pattern")))
        md.append(line("Agent access", integ.get("agent_access")))
        md.append(line("Activation level", integ.get("activation_level")))
        md.append(line("Works with AI disabled", "yes" if integ.get("works_without_ai") else "NOT CONFIRMED"))
        md.append(line("Rollback tested", "yes" if integ.get("rollback_tested") else "NOT TESTED"))
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
        t = arch.get("runtime_target") or {}
        if t:
            md.append("| Deploy target | Value |")
            md.append("|---|---|")
            md.append(line("Kubernetes", t.get("runtime_label")))
            md.append(line("Cluster", t.get("cluster") or "**not yet chosen**"))
            md.append(line("Organisation / GitOps repo", t.get("organization") or "—"))
            md.append(line("Namespace", t.get("namespace")))
            md.append(line("Target resolved", "yes" if t.get("resolved") else "**no**"))
            md.append("")
            if t.get("note"):
                md.append(f"*{t['note']}*")
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


# Files a receiving team gets, and nothing else. The scan result is deliberately
# excluded: it can run to megabytes and contains every external URL found in the
# source, which is inventory rather than something a LaunchPad reviewer needs.
def build_handoff_pack(project: Dict[str, Any]) -> Dict[str, Any]:
    """Bundle everything a delivery team needs into one checksummed ZIP.

    There is no LaunchPad API to post to — the handoff is a file a human picks
    up. So it has to be self-contained and verifiable: one archive, every file
    hashed, and a README that says what it is and what is still unanswered.
    """
    import hashlib
    import io
    import zipfile

    name = (project.get("name") or "project").replace(" ", "_")[:60]
    onto = project.get("business_ontology") or {}
    a = project.get("assessment_result", {}) or {}
    rec = project.get("recommendation", {}) or {}

    files: Dict[str, str] = {
        "README.md": report_markdown(project),
        "project.json": json.dumps(project, indent=2, sort_keys=False),
        "readiness.csv": report_csv(project),
    }
    if onto:
        files["business-ontology.json"] = json.dumps(onto, indent=2)
    if project.get("deployment_plan"):
        files["target-architecture.json"] = json.dumps(project["deployment_plan"], indent=2)
        mermaid = (project["deployment_plan"] or {}).get("mermaid")
        if mermaid:
            files["target-architecture.mmd"] = mermaid
    if project.get("palantir_mapping"):
        files["palantir-mapping.json"] = json.dumps(project["palantir_mapping"], indent=2)
    if project.get("palantir_connection"):
        files["palantir-connection-kit.json"] = json.dumps(project["palantir_connection"], indent=2)
    if project.get("passport"):
        files["passport.json"] = json.dumps(project["passport"], indent=2)
    if project.get("integration"):
        files["integration-plan.json"] = json.dumps(project["integration"], indent=2)

    # A cover note, so whoever opens this knows what it is and what it is not.
    unresolved = (project.get("deployment_plan") or {}).get("unresolved") or []
    cover = [
        f"# Handoff pack — {project.get('name')}",
        "",
    ] + ([
        "> ⚠️ **DEMO PACK — sample data, not a real customer system.** Do not act on this.",
        "",
    ] if project.get("is_demo") else []) + [
        f"- Adoption mode: **{project.get('adoption_mode')}**",
        f"- Recommended entry: **{rec.get('recommended_entry') or '—'}**",
        f"- Readiness: **{a.get('readiness_score')}%** ({a.get('verdict')}), "
        f"confidence **{a.get('confidence')}%** "
        f"({a.get('controls_checked')} checked, {a.get('controls_not_checked')} not checked)",
        f"- Production gaps: **{len(a.get('gaps') or [])}**",
        "",
        "Everything in this pack is **PROPOSED**. Nothing has been provisioned or deployed.",
        "",
        "## Still unanswered",
        "",
    ]
    cover += [f"- {u}" for u in unresolved] or ["- none recorded"]
    if onto.get("missing"):
        cover += [f"- {m}" for m in onto["missing"]]
    cover += ["", "## Contents", ""]
    cover += [f"- `{n}`" for n in sorted(files)]
    files["HANDOFF.md"] = "\n".join(cover) + "\n"

    buf = io.BytesIO()
    digests = []
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        for fname in sorted(files):
            data = files[fname].encode("utf-8")
            zf.writestr(f"{name}-handoff/{fname}", data)
            digests.append(f"{hashlib.sha256(data).hexdigest()}  {fname}")
        zf.writestr(f"{name}-handoff/checksums.sha256", ("\n".join(digests) + "\n").encode("utf-8"))

    blob = buf.getvalue()
    return {
        "bytes": blob,
        "filename": f"{name}-handoff.zip",
        "checksum": hashlib.sha256(blob).hexdigest(),
        "files": sorted(files) + ["checksums.sha256"],
        "size": len(blob),
    }
