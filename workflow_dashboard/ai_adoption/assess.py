"""Production-gap assessment and scoring.

Two rules shape this module:

1. The formula is visible. Every score returns its inputs, its weights and its
   arithmetic so a customer can argue with it.
2. Unverified is not the same as passing. Controls resolve to PASS / WARNING /
   FAIL / NOT_CHECKED, and NOT_CHECKED is carried into the result as a
   confidence penalty rather than being quietly treated as a pass. A project
   scoring 85% with six unchecked controls must not read like a clean 85%.
"""

from __future__ import annotations

from typing import Any, Dict, List, Tuple

from .models import SCORE_CATEGORIES, WEIGHTS, make_gap

# category -> list of (control_id, title, remediation)
CONTROLS: Dict[str, List[Tuple[str, str, str]]] = {
    "security": [
        ("no_hardcoded_secrets", "No hard-coded secrets in source", "Move secrets to the platform secret store and rotate anything committed."),
        ("dependency_manifest", "Dependencies are pinned in a manifest", "Add requirements.txt / pyproject.toml / package.json with pinned versions."),
        ("auth_present", "Application enforces authentication", "Add authentication in front of every non-public route."),
        ("no_blocked_binaries", "No opaque binaries in the source tree", "Remove committed binaries; build them from source in CI."),
    ],
    "production": [
        ("containerised", "Container build definition present", "Add a Dockerfile so the workload is reproducible."),
        ("orchestration", "Kubernetes or Helm deployment assets present", "Generate OpenCenter deployment manifests."),
        ("health_endpoint", "Health/readiness endpoint present", "Expose /health and /ready so orchestration can schedule safely."),
        ("api_contract", "API contract published", "Publish an OpenAPI document for the service."),
        ("tests_present", "Automated tests present", "Add regression tests covering the inference path."),
    ],
    "data": [
        ("sensitivity_declared", "Data sensitivity classified", "Classify every data source as LOW/MEDIUM/HIGH/REGULATED."),
        ("data_owner", "Data owner identified", "Name an accountable data owner."),
        ("vector_store_known", "Vector/RAG store identified", "Record which vector store holds retrieval data and who owns its contents."),
        ("no_external_egress", "No undeclared external endpoints", "Review outbound calls; declare or remove third-party endpoints."),
    ],
    "operations": [
        ("iac_present", "Infrastructure as code present", "Add Terraform/Ansible so the environment is rebuildable."),
        ("ci_present", "CI pipeline present", "Add a pipeline that builds, scans and publishes the image."),
        ("production_owner", "Production owner assigned", "Name the team accountable once it is live."),
    ],
    "value": [
        ("business_goal", "Business goal selected", "Pick the business outcome this workload improves."),
        ("business_owner", "Business owner identified", "Name the business sponsor."),
        ("success_metric", "Success metric defined", "Define the KPI that proves the AI is working."),
    ],
}

SEVERITY_BY_CATEGORY = {
    "security": "CRITICAL",
    "production": "HIGH",
    "data": "HIGH",
    "operations": "MEDIUM",
    "value": "MEDIUM",
}


def _evaluate(project: Dict[str, Any], scan: Dict[str, Any]) -> Dict[str, str]:
    """Resolve every control to PASS / WARNING / FAIL / NOT_CHECKED."""
    det = scan.get("detected", {}) if isinstance(scan, dict) else {}
    assets = scan.get("deployment_assets", []) or []
    scanned = bool(scan.get("scanned"))
    r: Dict[str, str] = {}

    # Without a source tree (Brownfield FLEX systems) the code-level controls
    # were not checked. They are not passes.
    code_result = (lambda ok: "PASS" if ok else "FAIL") if scanned else (lambda ok: "NOT_CHECKED")

    r["no_hardcoded_secrets"] = code_result(not scan.get("secret_findings"))
    r["dependency_manifest"] = code_result(bool(scan.get("dependency_manifests")))
    r["no_blocked_binaries"] = "PASS" if scanned else "NOT_CHECKED"
    # Authentication cannot be proven by grep. Detecting an auth library is
    # evidence worth surfacing, but never evidence that routes are protected.
    if not scanned:
        r["auth_present"] = "NOT_CHECKED"
    else:
        hints = ("oauth", "jwt", "authlib", "passport", "keycloak", "auth")
        text = " ".join(str(x).lower() for x in scan.get("dependency_manifests", []))
        r["auth_present"] = "WARNING" if any(h in text for h in hints) else "NOT_CHECKED"

    r["containerised"] = code_result("Dockerfile" in assets)
    r["orchestration"] = code_result(any(a in assets for a in ("Kubernetes", "Helm")))
    r["health_endpoint"] = code_result(bool(scan.get("has_healthcheck")))
    r["api_contract"] = code_result(bool(scan.get("has_openapi")))
    r["tests_present"] = code_result(bool(scan.get("has_tests")))

    sens = str(project.get("data_sensitivity") or "").upper()
    r["sensitivity_declared"] = "PASS" if sens in ("LOW", "MEDIUM", "HIGH", "REGULATED") else "FAIL"
    r["data_owner"] = "PASS" if project.get("data_owner") else "FAIL"
    r["vector_store_known"] = code_result(bool(det.get("vector_store")))
    if not scanned:
        r["no_external_egress"] = "NOT_CHECKED"
    else:
        r["no_external_egress"] = "PASS" if not scan.get("external_endpoints") else "WARNING"

    r["iac_present"] = code_result(any(a in assets for a in ("Terraform", "Ansible")))
    r["ci_present"] = code_result("GitHub Actions" in assets)
    r["production_owner"] = "PASS" if project.get("production_owner") else "FAIL"

    r["business_goal"] = "PASS" if project.get("business_goal") else "FAIL"
    r["business_owner"] = "PASS" if project.get("business_owner") else "FAIL"
    r["success_metric"] = "PASS" if project.get("description") else "NOT_CHECKED"

    # Evidence from the A-1..A-9 readiness assessment, when the user chose to
    # reuse it. It can only turn NOT_CHECKED/FAIL into PASS for the two things
    # it genuinely evidences, and assess() records the source on every control
    # it moves — a browser-local sales artifact must never silently inflate a
    # score an operations team will act on.
    ev = project.get("readiness_evidence") or {}
    if isinstance(ev, dict) and ev.get("assessment_id"):
        if ev.get("success_metric"):
            r["success_metric"] = "PASS"
        # Documented pain points and opportunities are what "business value
        # evidenced" actually means; a goal picked from a dropdown is not.
        if (ev.get("pain_points") or 0) > 0 and (ev.get("ai_opportunities") or 0) > 0:
            r["business_goal"] = "PASS"
        if str(ev.get("data_readiness") or "").lower() in ("medium", "high"):
            # Classification still has to be declared; readiness is not sensitivity.
            if r["vector_store_known"] == "NOT_CHECKED":
                r["vector_store_known"] = "WARNING"
    return r


def _evidence_sources(project: Dict[str, Any]) -> Dict[str, str]:
    """Which controls were resolved by the readiness assessment, not by scanning."""
    ev = project.get("readiness_evidence") or {}
    if not isinstance(ev, dict) or not ev.get("assessment_id"):
        return {}
    src = f"AI Enhancement Readiness Assessment {ev['assessment_id']}"
    out: Dict[str, str] = {}
    if ev.get("success_metric"):
        out["success_metric"] = src
    if (ev.get("pain_points") or 0) > 0 and (ev.get("ai_opportunities") or 0) > 0:
        out["business_goal"] = src
    if str(ev.get("data_readiness") or "").lower() in ("medium", "high"):
        out["vector_store_known"] = src
    return out


_POINTS = {"PASS": 1.0, "WARNING": 0.5, "FAIL": 0.0}


def assess(project: Dict[str, Any], scan: Dict[str, Any]) -> Dict[str, Any]:
    """Score the project and enumerate its production gaps."""
    results = _evaluate(project, scan)
    sources = _evidence_sources(project)
    mode = project.get("adoption_mode") or "EXISTING_POC"
    weights = WEIGHTS.get(mode, WEIGHTS["EXISTING_POC"])

    category_scores: Dict[str, int] = {}
    breakdown: Dict[str, Any] = {}
    gaps: List[Dict[str, Any]] = []
    unchecked_total = 0
    checked_total = 0

    for category, controls in CONTROLS.items():
        scored = 0.0
        possible = 0
        unchecked = 0
        detail = []
        for control_id, title, remediation in controls:
            outcome = results.get(control_id, "NOT_CHECKED")
            entry = {"control": control_id, "title": title, "result": outcome}
            if control_id in sources:
                # Attributed, so a reviewer can see this PASS came from a
                # declared assessment rather than from inspecting the code.
                entry["source"] = sources[control_id]
            detail.append(entry)
            if outcome == "NOT_CHECKED":
                unchecked += 1
                unchecked_total += 1
            else:
                scored += _POINTS.get(outcome, 0.0)
                possible += 1
                checked_total += 1
            if outcome in ("FAIL", "WARNING"):
                gaps.append(
                    make_gap(
                        category=category,
                        severity=SEVERITY_BY_CATEGORY.get(category, "MEDIUM") if outcome == "FAIL" else "LOW",
                        title=title,
                        description=f"Control '{control_id}' resolved {outcome}.",
                        remediation=remediation,
                        evidence=_evidence_for(control_id, scan),
                    )
                )

        # Score over what was actually checked. Dividing by the full control
        # count would let an unscannable project score 0% and look failed when
        # it is merely unexamined — a different thing, reported separately.
        pct = int(round((scored / possible) * 100)) if possible else 0
        category_scores[category] = pct
        breakdown[category] = {
            "score": pct,
            "weight": weights[category],
            "checked": possible,
            "not_checked": unchecked,
            "controls": detail,
            "contribution": round(pct * weights[category], 2),
        }

    overall = int(round(sum(category_scores[c] * weights[c] for c in SCORE_CATEGORIES)))
    total_controls = checked_total + unchecked_total
    confidence = int(round((checked_total / total_controls) * 100)) if total_controls else 0

    return {
        "readiness_score": overall,
        "category_scores": category_scores,
        "breakdown": breakdown,
        "weights": weights,
        "mode": mode,
        # Reported alongside the score, never folded into it: a reader must be
        # able to see that a high score rests on few verified controls.
        "confidence": confidence,
        "controls_checked": checked_total,
        "controls_not_checked": unchecked_total,
        "verdict": _verdict(overall, confidence, gaps),
        "evidence_sources": sources,
        "formula": (
            "overall = Σ(category_score × weight); category_score = "
            "Σ(PASS=1, WARNING=0.5, FAIL=0) ÷ controls_checked; "
            "NOT_CHECKED controls are excluded from the score and reported as confidence."
        ),
        "gaps": gaps,
    }


def _evidence_for(control_id: str, scan: Dict[str, Any]) -> str:
    if control_id == "no_hardcoded_secrets" and scan.get("secret_findings"):
        hits = scan["secret_findings"][:5]
        return "; ".join(f"{h['pattern']} in {h['file']}" for h in hits)
    if control_id == "no_external_egress" and scan.get("external_endpoints"):
        return "; ".join(scan["external_endpoints"][:5])
    if control_id == "dependency_manifest":
        return ", ".join(scan.get("dependency_manifests", [])[:5])
    return ""


def _verdict(score: int, confidence: int, gaps: List[Dict[str, Any]]) -> str:
    critical = sum(1 for g in gaps if g["severity"] == "CRITICAL")
    if critical:
        return "BLOCKED"
    if confidence < 50:
        return "MANUAL_REVIEW"
    if score >= 80:
        return "READY"
    if score >= 55:
        return "READY_WITH_CHANGES"
    return "WARNING"


def recommend(project: Dict[str, Any], assessment: Dict[str, Any], scan: Dict[str, Any]) -> Dict[str, Any]:
    """Pick the Rackspace entry service and explain why."""
    mode = project.get("adoption_mode")
    sens = str(project.get("data_sensitivity") or "").upper()
    score = assessment.get("readiness_score") or 0
    gaps = assessment.get("gaps", [])
    critical = [g for g in gaps if g["severity"] == "CRITICAL"]
    regulated = sens in ("HIGH", "REGULATED")

    if regulated:
        entry = "Private Cloud AI / AI Anywhere"
        why = f"data sensitivity is {sens}, so the workload stays close to the data"
    elif mode == "EXISTING_POC" and score < 55:
        entry = "FAIR Incubate / Industrialize"
        why = f"an existing PoC at {score}% production readiness needs industrialisation before it can be operated"
    elif mode == "GREENFIELD" and score < 40:
        entry = "FAIR Diagnostic / Ideate"
        why = "the use case is not yet evidenced enough to build against"
    else:
        entry = "AI LaunchPad"
        why = f"readiness is {score}% with no sensitivity blocker, so the fastest route to value is a LaunchPad PoC"

    palantir = bool(project.get("palantir_required")) or regulated
    scale_path = {
        "GREENFIELD": "AI LaunchPad → FLEX/OpenCenter Starter Stack → Foundry/AIP → Enterprise AI Cloud",
        "BROWNFIELD": "Integration Readiness → Shadow Mode → Foundry/AIP Governance → Managed Production",
        "EXISTING_POC": "Industrialize → FLEX/OpenCenter Migration → Canary Cutover → Managed Production",
    }.get(mode, "")
    if palantir:
        scale_path += " → FDE + Palantir"

    main_gap = ""
    if critical:
        main_gap = critical[0]["title"]
    elif gaps:
        main_gap = gaps[0]["title"]

    return {
        "recommended_entry": entry,
        "why": why,
        "main_gap": main_gap,
        "scale_up_path": scale_path,
        "target_platform": "FLEX (Rackspace OpenStack) + OpenCenter Kubernetes",
        "palantir_fit": "Required" if palantir else "Optional",
        "critical_blockers": len(critical),
        "estimated_effort": _effort(score, len(gaps)),
        "risks": [g["title"] for g in critical[:5]],
        "next_action": critical[0]["remediation"] if critical else "Approve the plan and schedule the LaunchPad session",
    }


def _effort(score: int, gap_count: int) -> str:
    if score >= 80 and gap_count <= 3:
        return "S — under 2 weeks"
    if score >= 55:
        return "M — 2 to 6 weeks"
    if score >= 35:
        return "L — 6 to 12 weeks"
    return "XL — 12 weeks or more"
