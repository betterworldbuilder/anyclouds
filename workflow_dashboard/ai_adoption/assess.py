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

from .models import (
    BROWNFIELD_WEIGHTS,
    SCORE_CATEGORIES,
    SPOT_EXCLUDED_SENSITIVITIES,
    WEIGHTS,
    make_gap,
)

# category -> list of (control_id, title, remediation)
# Brownfield only. The defining promise of this mode is that the application
# keeps working when the AI is switched off; these are the controls that make
# that a checked fact rather than a hope.
BROWNFIELD_CONTROLS: List[Tuple[str, str, str]] = [
    ("integration_pattern", "Integration pattern chosen", "Pick how the agent attaches: API, event, sidecar, read-only adapter or facade."),
    ("agent_access_scoped", "Agent access level defined", "Decide whether the agent reads only, writes with approval, or writes automatically."),
    ("works_without_ai", "Existing workflow works with AI disabled", "Prove the original workflow still completes when the agent is off."),
    ("rollback_tested", "Integration rollback tested", "Test removing the AI layer without disrupting the application."),
    ("app_apis_documented", "Application APIs documented", "Document the endpoints the agent will call."),
]

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

# Fallback when a control has no explicit severity below.
SEVERITY_BY_CATEGORY = {
    "security": "HIGH",
    "production": "HIGH",
    "data": "HIGH",
    "operations": "MEDIUM",
    "value": "MEDIUM",
}

# Severity belongs to the control, not to its category. Grading every failed
# security control CRITICAL made a missing requirements.txt rank identically to
# a committed credential, and since any CRITICAL forces a BLOCKED verdict, a
# well-formed handoff bundle came back blocked over dependency hygiene.
#
# CRITICAL is reserved for findings that must stop a production decision on
# their own: a leaked secret, unclassified data, or an undeclared model licence.
SEVERITY_BY_CONTROL = {
    # Brownfield: writing into a system of record with an untested rollback is
    # the one thing that must stop a production decision on its own.
    "rollback_tested": "CRITICAL",
    "works_without_ai": "HIGH",
    "integration_pattern": "MEDIUM",
    "agent_access_scoped": "HIGH",
    "app_apis_documented": "MEDIUM",
    # Genuine blockers.
    "no_hardcoded_secrets": "CRITICAL",
    "sensitivity_declared": "CRITICAL",
    # Serious, but they do not by themselves invalidate a production decision.
    "auth_present": "HIGH",
    "no_blocked_binaries": "HIGH",
    "data_owner": "HIGH",
    "production_owner": "HIGH",
    # Hygiene and completeness: remediate before go-live, do not block triage.
    "dependency_manifest": "MEDIUM",
    "containerised": "MEDIUM",
    "orchestration": "MEDIUM",
    "health_endpoint": "MEDIUM",
    "api_contract": "MEDIUM",
    "tests_present": "MEDIUM",
    "vector_store_known": "LOW",
    "no_external_egress": "LOW",
    "iac_present": "LOW",
    "ci_present": "LOW",
    "business_goal": "MEDIUM",
    "business_owner": "MEDIUM",
    "success_metric": "LOW",
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

    # A validated agent bundle has already evidenced its value — it shipped an
    # evaluation report and a named owner. Without this, a finished, working
    # agent scored *worse* on business value than an untested idea, which is
    # backwards.
    src = project.get("import_source") or {}
    bundle_eval = src.get("manifest_evaluation") or {}
    bundle_project = src.get("manifest_project") or {}
    if isinstance(bundle_eval, dict) and bundle_eval.get("report"):
        r["success_metric"] = "PASS"
        r["business_goal"] = "PASS"
    if isinstance(bundle_project, dict) and bundle_project.get("owner"):
        r["business_owner"] = "PASS"

    # A declared business-system ontology is the strongest evidence of value
    # this tool ever sees: a named pain point with stated inputs and a desired
    # output beats a goal picked from a dropdown.
    onto = project.get("business_ontology") or {}
    if isinstance(onto, dict) and onto.get("ai_tools"):
        props = (onto.get("ontology") or {}).get("properties") or {}
        if props.get("pain_points"):
            r["business_goal"] = "PASS"
        if props.get("desired_outputs"):
            r["success_metric"] = "PASS"

    # Evidence from the A-1..A-9 readiness assessment, when the user chose to
    # reuse it. It can only turn NOT_CHECKED/FAIL into PASS for the two things
    # it genuinely evidences, and assess() records the source on every control
    # it moves — a browser-local sales artifact must never silently inflate a
    # score an operations team will act on.
    # A migrated FLEX application declares its cloud-native posture. There is no
    # source tree to scan, but "already containerised and running on OpenCenter"
    # is a real, checkable fact about production readiness — a modernised app
    # should not score identically to a lift-and-shifted VM. Credited only for
    # the controls it actually evidences, and attributed below.
    posture = ((project.get("import_source") or {}).get("posture")) or {}
    if isinstance(posture, dict) and posture:
        if posture.get("containerised"):
            r["containerised"] = "PASS"
        if posture.get("kubernetes"):
            r["orchestration"] = "PASS"
        if posture.get("health_endpoint"):
            r["health_endpoint"] = "PASS"
        if posture.get("api_published"):
            r["api_contract"] = "PASS"

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
    """Which controls were resolved by declaration rather than by scanning."""
    out: Dict[str, str] = {}

    src = project.get("import_source") or {}
    if (src.get("manifest_evaluation") or {}).get("report"):
        bsrc = f"Validated agent bundle '{src.get('display_name') or 'bundle'}' (evaluation report attached)"
        out["business_goal"] = bsrc
        out["success_metric"] = bsrc
    if (src.get("manifest_project") or {}).get("owner"):
        out["business_owner"] = f"Agent bundle manifest owner '{(src['manifest_project'])['owner']}'"

    onto = project.get("business_ontology") or {}
    if isinstance(onto, dict) and onto.get("ai_tools"):
        osrc = f"Business-system ontology for '{onto.get('system') or 'system'}'"
        props = (onto.get("ontology") or {}).get("properties") or {}
        if props.get("pain_points"):
            out["business_goal"] = osrc
        if props.get("desired_outputs"):
            out["success_metric"] = osrc

    posture = ((project.get("import_source") or {}).get("posture")) or {}
    if isinstance(posture, dict) and posture:
        app = (project.get("import_source") or {}).get("display_name") or "FLEX application"
        psrc = f"Declared posture of migrated FLEX app '{app}'"
        for flag, control in (
            ("containerised", "containerised"),
            ("kubernetes", "orchestration"),
            ("health_endpoint", "health_endpoint"),
            ("api_published", "api_contract"),
        ):
            if posture.get(flag):
                out[control] = psrc

    ev = project.get("readiness_evidence") or {}
    if not isinstance(ev, dict) or not ev.get("assessment_id"):
        return out
    src = f"AI Enhancement Readiness Assessment {ev['assessment_id']}"
    if ev.get("success_metric"):
        out["success_metric"] = src
    if (ev.get("pain_points") or 0) > 0 and (ev.get("ai_opportunities") or 0) > 0:
        out["business_goal"] = src
    if str(ev.get("data_readiness") or "").lower() in ("medium", "high"):
        out["vector_store_known"] = src
    return out


_POINTS = {"PASS": 1.0, "WARNING": 0.5, "FAIL": 0.0}


def _brownfield_results(project: Dict[str, Any]) -> Dict[str, str]:
    """Resolve the Brownfield-only controls from the declared integration plan."""
    integ = project.get("integration") or {}
    if not isinstance(integ, dict):
        integ = {}
    r = {
        "integration_pattern": "PASS" if str(integ.get("pattern") or "").strip() else "FAIL",
        "agent_access_scoped": "PASS" if str(integ.get("agent_access") or "").strip() else "FAIL",
        # A rollback nobody tested is not a rollback. Unticked is unchecked,
        # never a pass — this is the promise the whole mode rests on.
        "works_without_ai": "PASS" if integ.get("works_without_ai") is True else "NOT_CHECKED",
        "rollback_tested": "PASS" if integ.get("rollback_tested") is True else "NOT_CHECKED",
        "app_apis_documented": "PASS" if integ.get("apis_documented") is True else "NOT_CHECKED",
    }
    # Writing automatically into a system of record without a tested rollback is
    # the failure mode this mode exists to prevent.
    if str(integ.get("agent_access") or "") == "WRITE_AUTO" and integ.get("rollback_tested") is not True:
        r["rollback_tested"] = "FAIL"
    return r


def assess(project: Dict[str, Any], scan: Dict[str, Any]) -> Dict[str, Any]:
    """Score the project and enumerate its production gaps."""
    results = _evaluate(project, scan)
    sources = _evidence_sources(project)
    mode = project.get("adoption_mode") or "EXISTING_POC"
    weights = WEIGHTS.get(mode, WEIGHTS["EXISTING_POC"])

    # Brownfield carries extra controls; the other modes never see them.
    controls_by_category = {k: list(v) for k, v in CONTROLS.items()}
    if mode == "BROWNFIELD":
        controls_by_category["integration"] = list(BROWNFIELD_CONTROLS)
        results.update(_brownfield_results(project))
        weights = BROWNFIELD_WEIGHTS

    category_scores: Dict[str, int] = {}
    breakdown: Dict[str, Any] = {}
    gaps: List[Dict[str, Any]] = []
    unchecked_total = 0
    checked_total = 0

    for category, controls in controls_by_category.items():
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
                        severity=(
                            SEVERITY_BY_CONTROL.get(control_id, SEVERITY_BY_CATEGORY.get(category, "MEDIUM"))
                            if outcome == "FAIL"
                            else "LOW"
                        ),
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

    # Iterate the weights, not the fixed category list — Brownfield has six.
    overall = int(round(sum(category_scores[c] * weights[c] for c in weights)))
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

    # The same three services carry every scenario; the ladder decides where
    # this project joins it.
    stack = service_stack(project, scan, assessment)
    entry = stack["build_on"]
    why = stack["why"]

    palantir = bool(project.get("palantir_required")) or regulated
    scale_path = " → ".join(s["service"] for s in stack["ladder"])
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
        # The service ladder and its caveats. Present for every mode.
        "service_stack": stack,
        "greenfield_stack": stack,  # previous key, kept for existing callers
    }


GPU_RUNTIMES = ("vLLM", "HF Transformers", "PyTorch", "TGI", "Ollama", "TensorFlow", "Triton")


def service_stack(
    project: Dict[str, Any],
    scan: Dict[str, Any],
    assessment: Dict[str, Any] | None = None,
) -> Dict[str, Any]:
    """Which Rackspace service to start on, and why — for every adoption mode.

    Three services carry all scenarios:

      AI LaunchPad     prove the use case, managed GPU sandbox
      Rackspace Spot   iterate cheaply, self-service per-second GPU
      FLEX + OpenCenter  production home, customer tenancy, managed operations

    The mode does not change the services, only where a project joins the
    ladder: Greenfield usually starts at the top, an already-validated agent
    joins near the bottom.

    Two constraints override the default entry:
      * Spot capacity is auction-priced and can be reclaimed when the market
        price passes your bid or capacity is needed elsewhere. Fine for
        training and experimentation, wrong for an SLA-bound endpoint.
      * Regulated or sovereign data does not belong on shared auction capacity
        at all — those route to AI Anywhere or UK Sovereign Private AI.
    """
    det = scan.get("detected", {}) if isinstance(scan, dict) else {}
    sens = str(project.get("data_sensitivity") or "").upper()
    sovereignty = str(project.get("sovereignty_requirements") or "").lower()
    gpu = any(r in det.get("model_runtime", []) for r in GPU_RUNTIMES)

    uk = "uk" in sovereignty or "united kingdom" in sovereignty
    spot_allowed = sens not in SPOT_EXCLUDED_SENSITIVITIES and not uk

    # Self-service assumes you know what you are building. When the project is
    # barely evidenced, handing over a GPU is the wrong answer — AI LaunchPad is
    # the guided engagement that establishes the use case first.
    score = (assessment or {}).get("readiness_score")
    confidence = (assessment or {}).get("confidence")
    unevidenced = (score is not None and score < 40) or (confidence is not None and confidence < 50)

    mode = project.get("adoption_mode") or "GREENFIELD"
    # An already-validated agent has nothing left to prove in a LaunchPad; it
    # needs validating on real infrastructure and then a production home.
    already_built = mode == "EXISTING_POC" or str(project.get("source_type") or "") in (
        "AI4PEOPLE", "LAUNCHPAD", "PALANTIR"
    )

    if uk:
        build_on = "UK Sovereign Private AI"
        why = "sovereignty requires the environment to stay under UK control"
    elif sens in SPOT_EXCLUDED_SENSITIVITIES:
        build_on = "Private Cloud AI / AI Anywhere"
        why = (
            f"data is {sens}; auction-priced shared capacity is not an appropriate "
            "home for it, so the work starts on private AI infrastructure"
        )
    elif unevidenced and not already_built:
        build_on = "AI LaunchPad"
        why = (
            f"readiness is {score}% with {confidence}% confidence — not enough evidence to "
            "self-serve, so the guided engagement establishes the use case before any "
            "infrastructure is bought"
        )
    elif already_built and not unevidenced:
        build_on = "Rackspace Spot"
        why = (
            "the agent is already validated, so it needs proving on real infrastructure "
            "rather than another PoC — Spot gives per-second GPU to do that"
        )
    else:
        build_on = "Rackspace Spot"
        why = (
            "Spot is the only self-service, per-second-billed GPU option — the cheapest "
            "way to iterate before committing to a platform"
        )

    # Three go-to services, in the order a Greenfield project meets them.
    # AI Anywhere and UK Sovereign are exceptions layered on top for regulated
    # and sovereign data, not alternative defaults.
    production_home = (
        "UK Sovereign Private AI" if uk
        else "Private Cloud AI / AI Anywhere" if sens in SPOT_EXCLUDED_SENSITIVITIES
        else "FLEX + OpenCenter"
    )

    ladder = [
        {
            "phase": "Prove the use case",
            "service": "AI LaunchPad",
            "why": (
                why if build_on == "AI LaunchPad"
                else "guided engagement with a managed GPU sandbox, if the use case needs establishing"
            ),
            "notes": "Managed PoC sandbox with GPU and a defined path from pilot to production.",
            "entry_point": build_on == "AI LaunchPad",
        },
        {
            "phase": "Build & iterate",
            "service": "Rackspace Spot" if spot_allowed else production_home,
            "why": (
                why if build_on == "Rackspace Spot"
                else "self-service per-second GPU for cheap iteration" if spot_allowed
                else f"data is {sens or 'restricted'}; iteration happens on dedicated capacity instead"
            ),
            "notes": (
                "Hybrid Cloudspace: on-demand node pool for anything that must stay up, "
                "spot node pool for training and batch — both in one Kubernetes cluster."
                if spot_allowed
                else "Dedicated capacity from the start; no auction reclamation risk."
            ),
            "entry_point": build_on == "Rackspace Spot",
        },
        {
            "phase": "Production",
            "service": production_home,
            "why": (
                "the customer's own FLEX tenancy, operated by Rackspace — the same platform "
                "the rest of their estate was migrated to"
                if production_home == "FLEX + OpenCenter"
                else "regulated or sovereign workloads stay on dedicated private infrastructure"
            ),
            "notes": "OpenCenter Kubernetes, GPU node pool as required, managed operations.",
            "entry_point": build_on == production_home,
        },
    ]

    warnings: List[str] = []
    if build_on == "Rackspace Spot":
        warnings.append(
            "Spot instances can be reclaimed when the market price exceeds your bid or "
            "capacity is needed elsewhere — checkpoint training jobs and keep any "
            "always-on endpoint on an on-demand node pool."
        )
    if not spot_allowed and gpu:
        warnings.append(
            f"GPU workload with {sens or 'unclassified'} data: Spot is excluded, so GPU "
            "capacity must come from a dedicated platform."
        )
    # We do not know GPU prices, and the headline general-compute rate is not one.
    warnings.append(
        "No pricing is quoted here. The advertised entry rate applies to the lowest-priced "
        "general compute, not to A30 or H100 GPU instances, whose prices are dynamic."
    )

    return {
        "build_on": build_on,
        "why": why,
        "mode": mode,
        "gpu_workload": gpu,
        "gpu_classes": ["NVIDIA A30", "NVIDIA H100"] if gpu and spot_allowed else [],
        "spot_eligible": spot_allowed,
        "production_home": production_home,
        "ladder": ladder,
        "warnings": warnings,
    }


# Previous name, kept so existing callers do not break.
greenfield_stack = service_stack


def _effort(score: int, gap_count: int) -> str:
    if score >= 80 and gap_count <= 3:
        return "S — under 2 weeks"
    if score >= 55:
        return "M — 2 to 6 weeks"
    if score >= 35:
        return "L — 6 to 12 weeks"
    return "XL — 12 weeks or more"
