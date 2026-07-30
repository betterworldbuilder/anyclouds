"""Domain model for Stage 9 AI Adoption.

One project is one JSON document. The original specification called for eight
related entities with UUID primary keys and backward-compatible migrations; this
application has no ORM and no database, so components, gaps, assessments and
artifacts are embedded lists on the project instead. Field names follow the
spec exactly, so porting to a relational store later is mechanical.
"""

from __future__ import annotations

import time
from typing import Any, Dict, List
from uuid import uuid4

SCHEMA_VERSION = "1.0"

ADOPTION_MODES = ("GREENFIELD", "BROWNFIELD", "EXISTING_POC")

# Only the sources with a working provider are advertised. Container and model
# registry imports are deliberately absent: they yield metadata no downstream
# plan step consumes yet, and offering them would imply capability we lack.
SOURCE_TYPES = (
    "NEW_PROJECT",
    "FLEX_BUSINESS_SYSTEM",
    # A containerised workload already running on OpenCenter. Stronger evidence
    # than a declared posture: it came from Kubernetes, so it demonstrably is
    # containerised and orchestrated.
    "OPENCENTER",
    "GITHUB",
    "UPLOAD",
    "NOTEBOOK",
    "LAUNCHPAD",
    "AI4PEOPLE",
    # A Palantir export. Note what this is *not*: an AIP Agent cannot be
    # exported and run outside Foundry — agents are published as functions and
    # invoked through Foundry APIs. What can be imported is the ontology JSON,
    # OSDK application source, and Marketplace product metadata. See
    # docs/palantir-import.md.
    "PALANTIR",
    "MANUAL",
)

# Six states, not the twenty in the spec. The states removed (CANARY, UAT_PASSED,
# ROLLED_BACK, ...) describe events inside Rackspace operations systems, which
# this planning tool does not observe; enum values that never get set are worse
# than absent ones.
STATUSES = ("DRAFT", "IMPORTED", "ASSESSED", "PLANNED", "HANDED_OFF", "ARCHIVED")

SENSITIVITIES = ("LOW", "MEDIUM", "HIGH", "REGULATED")

ARTIFACT_TYPES = ("SOURCE", "SCAN", "PLAN", "PASSPORT", "ARCHITECTURE", "HANDOFF")

SEVERITIES = ("INFO", "LOW", "MEDIUM", "HIGH", "CRITICAL")

# Every control resolves to one of these. NOT_CHECKED is load-bearing: it is what
# keeps an unverified project from reporting as a clean pass.
CONTROL_RESULTS = ("PASS", "WARNING", "FAIL", "NOT_CHECKED")

COMPONENT_TYPES = (
    "APPLICATION",
    "API",
    "DATABASE",
    "VECTOR_DATABASE",
    "MODEL",
    "AGENT",
    "NOTEBOOK",
    "CONTAINER",
)

# Score categories, five rather than the spec's nine. Mode-specific weights stay
# configurable; the sum is asserted at import time so a bad edit fails loudly
# instead of silently skewing every customer's score.
SCORE_CATEGORIES = ("value", "data", "security", "production", "operations")

WEIGHTS: Dict[str, Dict[str, float]] = {
    "GREENFIELD": {"value": 0.30, "data": 0.25, "security": 0.15, "production": 0.15, "operations": 0.15},
    "BROWNFIELD": {"value": 0.25, "data": 0.20, "security": 0.20, "production": 0.20, "operations": 0.15},
    "EXISTING_POC": {"value": 0.15, "data": 0.15, "security": 0.25, "production": 0.30, "operations": 0.15},
}

for _mode, _w in WEIGHTS.items():
    assert abs(sum(_w.values()) - 1.0) < 1e-9, f"weights for {_mode} must sum to 1.0"
    assert set(_w) == set(SCORE_CATEGORIES), f"weights for {_mode} must cover every category"

# Brownfield adds a sixth category. Its defining promise — the application keeps
# working when the AI is switched off — is worth as much as security here, so
# the other weights are reduced to make room rather than the total inflated.
BROWNFIELD_WEIGHTS = {
    "value": 0.20,
    "data": 0.15,
    "security": 0.20,
    "production": 0.15,
    "operations": 0.10,
    "integration": 0.20,
}
assert abs(sum(BROWNFIELD_WEIGHTS.values()) - 1.0) < 1e-9, "brownfield weights must sum to 1.0"

RECOMMENDATIONS = (
    # The only self-service, usage-based GPU option — where a Greenfield build
    # should start, before anyone commits to a platform.
    "Rackspace Spot",
    "AI LaunchPad",
    "FAIR Diagnostic / Ideate",
    "FAIR Incubate / Industrialize",
    "Private Cloud AI / AI Anywhere",
    "UK Sovereign Private AI",
    "AI Business / Inference",
    "Enterprise AI Cloud",
    "FDE + Palantir",
)

# Where a workload may run, given its data. Spot is auction-priced shared
# capacity that can be reclaimed, so it is a build/iterate target, never the
# home for regulated data or an SLA-bound production endpoint.
SPOT_EXCLUDED_SENSITIVITIES = ("HIGH", "REGULATED")

# Mode-specific journeys rendered by the UI (spec section 15).
JOURNEYS: Dict[str, List[str]] = {
    "GREENFIELD": [
        "FAIR Ideate",
        "AI LaunchPad",
        "FLEX/OpenCenter Starter Stack",
        "Foundry / AIP",
        "Enterprise AI Cloud",
    ],
    "BROWNFIELD": [
        "Application Discovery",
        "Integration Readiness",
        "AI LaunchPad",
        "Shadow Mode",
        "Foundry / AIP Governance",
        "Managed Production",
    ],
    "EXISTING_POC": [
        "PoC Import",
        "Production Gap Assessment",
        "Industrialize",
        "FLEX/OpenCenter Migration",
        "Canary Cutover",
        "Managed Production",
    ],
}


def now_ms() -> int:
    return int(time.time() * 1000)


def new_id() -> str:
    return str(uuid4())


def new_project(
    name: str,
    adoption_mode: str,
    customer_id: str = "",
    source_type: str = "NEW_PROJECT",
    **overrides: Any,
) -> Dict[str, Any]:
    """Create an empty project document.

    Everything not supplied stays empty on purpose. The spec's own rule — "no
    readiness must be assumed before evidence is captured" — means a field with
    no evidence renders blank rather than defaulting to something plausible.
    """
    if adoption_mode not in ADOPTION_MODES:
        raise ValueError(f"unknown adoption_mode: {adoption_mode}")
    if source_type not in SOURCE_TYPES:
        raise ValueError(f"unknown source_type: {source_type}")

    ts = now_ms()
    project: Dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "id": new_id(),
        "customer_id": customer_id,
        "name": name,
        "description": "",
        "adoption_mode": adoption_mode,
        "source_type": source_type,
        "source_reference": "",
        "source_version": "",
        "source_commit": "",
        "source_branch": "",
        "business_owner": "",
        "technical_owner": "",
        "data_owner": "",
        "production_owner": "",
        "department_id": "",
        "business_system_id": "",
        # The user-facing intake path (GREENFIELD, BROWNFIELD, or GOLDENFIELD)
        # is preserved when all three converge into the final Palantir stage.
        "starting_condition": "",
        "project_context": {},
        "business_goal": "",
        "data_sensitivity": "",
        "data_location": "",
        "external_transfer_allowed": False,
        "preferred_environment": "FLEX (Rackspace OpenStack)",
        "sovereignty_requirements": "",
        "target_platform": "",
        "recommended_rackspace_service": "",
        "palantir_required": False,
        "status": "DRAFT",
        "readiness_score": None,
        "category_scores": {},
        "production_gap_count": 0,
        "estimated_value": 0,
        "currency": "USD",
        # Embedded collections (spec entities 5.2-5.8).
        "import_source": {},
        "artifacts": [],
        "components": [],
        "dependencies": [],
        "assessments": [],
        "gaps": [],
        "governance": [],
        "deployment_plan": {},
        "palantir_mapping": {},
        "audit": [],
        # Demo runs must be identifiable everywhere they surface, so a sample
        # walkthrough can never be mistaken for a real customer assessment.
        "is_demo": False,
        # Not in the spec. The stated objective is "first AI product in record
        # time", and nothing in the original document measured it.
        "created_at": ts,
        "updated_at": ts,
        "imported_at": None,
        "planned_at": None,
        "time_to_plan_ms": None,
    }
    project.update(overrides)
    return project


def make_component(component_type: str, name: str, **fields: Any) -> Dict[str, Any]:
    comp = {
        "id": new_id(),
        "component_type": component_type,
        "name": name,
        "version": "",
        "location": "",
        "framework": "",
        "runtime": "",
        "sensitivity": "",
        "source": "",
        "metadata_json": {},
    }
    comp.update(fields)
    return comp


def make_gap(category: str, severity: str, title: str, **fields: Any) -> Dict[str, Any]:
    if severity not in SEVERITIES:
        raise ValueError(f"unknown severity: {severity}")
    gap = {
        "id": new_id(),
        "category": category,
        "severity": severity,
        "title": title,
        "description": "",
        "evidence": "",
        "remediation": "",
        "status": "OPEN",
        "owner": "",
    }
    gap.update(fields)
    return gap
