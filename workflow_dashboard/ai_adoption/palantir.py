"""Palantir Foundry / AIP import and connection planning.

What is and is not possible, verified against Palantir's documentation:

* **An AIP Agent cannot be exported and run on FLEX.** Agents live in Foundry;
  they are published as functions and invoked through Foundry APIs or the
  Ontology SDK. There is no artifact to lift out and deploy.
* **An Ontology can be exported as JSON** (object types, link types,
  properties, action types) from Ontology Manager → Advanced. Palantir warns
  the schema "may change over time", so it is parsed defensively and treated as
  evidence, never as a stable contract.
* **Marketplace products export as a file**, but only install into another
  Foundry enrollment — Palantir states the file is for "short-lived transport",
  not permanent storage. Useful to us as an inventory, not as something
  deployable.
* **The direction that does work is the inverse**: host the model or agent
  runtime on FLEX / managed OSPC / the Rackspace AI sandbox, and register it in
  Foundry as an *externally hosted model*. Foundry keeps the ontology,
  permissions and audit; FLEX runs the inference.

So a Palantir import produces two things: an inventory of what the Foundry
project contains, and the connection kit needed to point Foundry at a workload
Flex Migration Hub will deploy.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, List

ONTOLOGY_FILES = ("ontology.json", "ontology-export.json", "working-state.json")
MARKETPLACE_FILES = ("marketplace.yml", "marketplace.yaml", "product.yml", "product.yaml")


def detect(root: Path) -> Dict[str, Any]:
    """Identify a Palantir export in an imported tree."""
    result: Dict[str, Any] = {
        "is_palantir": False,
        "kinds": [],
        "ontology": {},
        "osdk": {},
        "marketplace": {},
        "findings": [],
    }
    if not root or not Path(root).is_dir():
        return result
    root = Path(root)

    for name in ONTOLOGY_FILES:
        path = root / name
        if path.is_file():
            result["ontology"] = _read_ontology(path, result["findings"])
            if result["ontology"]:
                result["kinds"].append("ONTOLOGY")
            break

    osdk = _detect_osdk(root)
    if osdk:
        result["osdk"] = osdk
        result["kinds"].append("OSDK_APP")

    for name in MARKETPLACE_FILES:
        if (root / name).is_file():
            result["marketplace"] = {"file": name}
            result["kinds"].append("MARKETPLACE")
            result["findings"].append(
                "Marketplace products install into another Foundry enrollment; "
                "they are not deployable to FLEX. Imported as inventory only."
            )
            break

    result["is_palantir"] = bool(result["kinds"])
    if result["is_palantir"] and "OSDK_APP" not in result["kinds"]:
        # Without OSDK source there is no code to deploy — say so plainly rather
        # than let a plan imply a deployable workload exists.
        result["findings"].append(
            "No OSDK application source found. An ontology or Marketplace export "
            "alone contains nothing deployable; the deployable artifact is an "
            "OSDK application or a model you host."
        )
    return result


def _read_ontology(path: Path, findings: List[str]) -> Dict[str, Any]:
    """Parse an Ontology Manager export defensively.

    Palantir states the exported JSON schema is not stable, so every shape is
    probed rather than assumed, and a parse failure is a finding, not a crash.
    """
    try:
        raw = json.loads(path.read_text(encoding="utf-8", errors="replace"))
    except Exception as exc:
        findings.append(f"{path.name} is not valid JSON: {type(exc).__name__}")
        return {}
    if not isinstance(raw, dict):
        findings.append(f"{path.name} is not a JSON object")
        return {}

    def _count(*keys: str) -> int:
        for key in keys:
            value = raw.get(key)
            if isinstance(value, (list, dict)):
                return len(value)
        return 0

    summary = {
        "file": path.name,
        "object_types": _count("objectTypes", "object_types", "objects"),
        "link_types": _count("linkTypes", "link_types", "links"),
        "action_types": _count("actionTypes", "action_types", "actions"),
        "shared_property_types": _count("sharedPropertyTypes", "shared_property_types"),
    }
    if not any(v for k, v in summary.items() if k != "file"):
        findings.append(
            f"{path.name} parsed but no ontology entities were recognised — the "
            "export schema may have changed."
        )
    return summary


def _detect_osdk(root: Path) -> Dict[str, Any]:
    """An OSDK application is the one Palantir artifact that runs on FLEX."""
    pkg = root / "package.json"
    if pkg.is_file():
        try:
            data = json.loads(pkg.read_text(encoding="utf-8", errors="replace"))
            deps = {}
            for section in ("dependencies", "devDependencies"):
                if isinstance(data.get(section), dict):
                    deps.update(data[section])
            osdk_deps = sorted(d for d in deps if "@osdk/" in d or "foundry" in d.lower())
            if osdk_deps:
                return {"language": "typescript", "manifest": "package.json", "packages": osdk_deps[:10]}
        except Exception:
            pass

    for name in ("requirements.txt", "pyproject.toml"):
        path = root / name
        if path.is_file():
            text = path.read_text(encoding="utf-8", errors="replace").lower()
            if "foundry-platform-sdk" in text or "osdk" in text or "foundry_sdk" in text:
                return {"language": "python", "manifest": name, "packages": ["foundry/osdk"]}
    return {}


# Rackspace is a preferred operator for on-premise, private-cloud and sovereign
# Palantir deployments, so where Foundry itself runs is a decision — not an
# assumption that it always lives in someone else's SaaS.
PATTERNS = ("FOUNDRY_ON_RACKSPACE", "EXTERNAL_MODEL", "MAPPING_ONLY")


def deployment_pattern(project: Dict[str, Any]) -> Dict[str, Any]:
    """Decide where Foundry runs, from evidence already collected.

    The three questions that decide this are the ones regulated customers ask
    first — who owns the data, where must it live, and can our models be used to
    build someone else's business — and each is already a field on the project.
    So the pattern is derived rather than asked again.
    """
    sens = str(project.get("data_sensitivity") or "").upper()
    sovereignty = str(project.get("sovereignty_requirements") or "").strip()
    transfer_allowed = bool(project.get("external_transfer_allowed"))
    enrollment = ((project.get("foundry_target") or {}).get("enrollment") or "").strip()

    restricted = sens in ("HIGH", "REGULATED") or bool(sovereignty) or not transfer_allowed

    if restricted:
        pattern = "FOUNDRY_ON_RACKSPACE"
        why = []
        if sovereignty:
            why.append(f"sovereignty requirement recorded ({sovereignty})")
        if sens in ("HIGH", "REGULATED"):
            why.append(f"data classified {sens}")
        if not transfer_allowed:
            why.append("external transfer of data is not permitted")
        reason = "; ".join(why)
    elif enrollment:
        pattern = "EXTERNAL_MODEL"
        reason = f"data is {sens or 'unclassified'} and the customer already runs Foundry at {enrollment}"
    else:
        pattern = "MAPPING_ONLY"
        reason = "no Foundry environment named yet, so the deliverable is the mapping itself"

    return {"pattern": pattern, "reason": reason, "restricted": restricted}


# What each pattern actually requires. The point of FOUNDRY_ON_RACKSPACE is that
# most of the external-endpoint prerequisites disappear: Foundry and the runtime
# sit in the same governed estate, so there is no egress boundary to cross.
_PREREQS: Dict[str, List[Dict[str, str]]] = {
    "FOUNDRY_ON_RACKSPACE": [
        {"item": "Sovereign placement decided",
         "detail": "Confirm the region, data-residency boundary and whether the estate is private cloud, "
                   "on-premise or air-gapped.",
         "owner": "Customer + Rackspace architect", "status": "NOT_CHECKED"},
        {"item": "Foundry / AIP licensing",
         "detail": "Foundry and AIP are licensed by Palantir. Rackspace operates the infrastructure and the "
                   "platform; it does not license the software.",
         "owner": "Customer + Palantir", "status": "NOT_CHECKED"},
        {"item": "FDE engagement scheduled",
         "detail": "Palantir-certified Rackspace forward deployed engineers build the workflows inside the "
                   "customer environment.",
         "owner": "Rackspace FDE team", "status": "NOT_CHECKED"},
        {"item": "Ontology scope agreed",
         "detail": "Which business objects, links and actions are in scope for the first deployment.",
         "owner": "Customer business owner", "status": "NOT_CHECKED"},
        {"item": "Managed operations handover",
         "detail": "Day 2 ownership: monitoring, patching, upgrades and incident response.",
         "owner": "Rackspace managed operations", "status": "NOT_CHECKED"},
    ],
    "EXTERNAL_MODEL": [
        {"item": "Egress policy",
         "detail": "Foundry must be allowed to reach the hosted endpoint. Requires an egress policy on the "
                   "enrollment and may need security approval.",
         "owner": "Customer Foundry administrator", "status": "NOT_CHECKED"},
        {"item": "Model adapter",
         "detail": "A Python adapter extending ExternalModelAdapter, implementing init_external() and "
                   "declaring the request/response contract in api().",
         "owner": "Joint — Rackspace supplies the endpoint contract", "status": "NOT_CHECKED"},
        {"item": "Encrypted credentials",
         "detail": "Endpoint credentials stored encrypted in the Foundry model configuration.",
         "owner": "Customer Foundry administrator", "status": "NOT_CHECKED"},
        {"item": "Network egress for transforms",
         "detail": "Python transforms using the model need egress explicitly enabled for the connection.",
         "owner": "Customer Foundry administrator", "status": "NOT_CHECKED"},
    ],
    "MAPPING_ONLY": [
        {"item": "Foundry environment identified",
         "detail": "Name the enrollment and target ontology this mapping will be implemented in.",
         "owner": "Customer", "status": "NOT_CHECKED"},
        {"item": "Ontology review",
         "detail": "The customer's Foundry team reviews the proposed objects, links and AIP tools.",
         "owner": "Customer Foundry team", "status": "NOT_CHECKED"},
    ],
}

# Prerequisites that a pattern removes, stated explicitly — the benefit is only
# real if it is visible.
_NOT_REQUIRED: Dict[str, List[str]] = {
    "FOUNDRY_ON_RACKSPACE": [
        "Foundry egress policy — Foundry and the runtime share one governed estate",
        "Encrypted external-endpoint credentials — there is no external endpoint",
        "Transform network egress — no boundary to cross",
    ],
    "EXTERNAL_MODEL": [],
    "MAPPING_ONLY": [
        "Nothing is provisioned at this stage, so no Foundry-side configuration is required yet",
    ],
}


def _how_to(pattern: str, target: str) -> List[Dict[str, str]]:
    """The steps in order, in plain language, with who does each one."""
    if pattern == "FOUNDRY_ON_RACKSPACE":
        return [
            {"step": "Describe the business problem", "who": "You",
             "detail": "Name the system, what hurts, what goes in and what should come out."},
            {"step": "Agree where it runs", "who": "You + Rackspace",
             "detail": "Pick the region and whether it is private cloud, on-premise or air-gapped."},
            {"step": "License Foundry and AIP", "who": "You + Palantir",
             "detail": "Rackspace operates the platform; Palantir licenses the software."},
            {"step": "Rackspace installs and operates it", "who": "Rackspace",
             "detail": f"Foundry and AIP stood up on {target}, inside your boundary."},
            {"step": "Engineers build the workflows with you", "who": "Rackspace FDE",
             "detail": "Palantir-certified engineers work inside your environment, not from outside it."},
            {"step": "Hand over to managed operations", "who": "Rackspace",
             "detail": "Monitoring, patching, upgrades and incident response from day two."},
        ]
    if pattern == "EXTERNAL_MODEL":
        return [
            {"step": "Describe the business problem", "who": "You", "detail": "Same first step as any path."},
            {"step": "We host the runtime", "who": "Rackspace", "detail": f"Model or agent deployed on {target}."},
            {"step": "Open the path from Foundry", "who": "Your Foundry admin",
             "detail": "Add an egress policy so Foundry can reach the endpoint."},
            {"step": "Register it as an external model", "who": "Joint",
             "detail": "A model adapter declares the request and response contract."},
            {"step": "Foundry calls the model", "who": "Foundry",
             "detail": "Your ontology, permissions and audit trail stay in Foundry."},
        ]
    return [
        {"step": "Describe the business problem", "who": "You",
         "detail": "Name the system, what hurts, what goes in and what should come out."},
        {"step": "We produce the mapping", "who": "Flex Migration Hub",
         "detail": "Objects, relationships and AI tool definitions, each tied to a pain point."},
        {"step": "Your Foundry team implements it", "who": "You",
         "detail": "Nothing is installed by us at this stage."},
        {"step": "Come back when you pick an environment", "who": "You",
         "detail": "Naming a Foundry enrollment or a residency rule moves you onto one of the other two paths."},
    ]


def connection_kit(project: Dict[str, Any], scan: Dict[str, Any], detected: Dict[str, Any]) -> Dict[str, Any]:
    """The artifacts needed to let Foundry call a FLEX-hosted workload.

    This is the deployable direction: Foundry proxies out to a model we host.
    Palantir requires an egress policy, encrypted credentials, and a model
    adapter declaring the API contract — all three are enumerated here as
    requirements, not generated as fake config.
    """
    det = scan.get("detected", {}) if isinstance(scan, dict) else {}
    runtimes = det.get("model_runtime", [])
    foundry = project.get("foundry_target") or {}
    # A Palantir-ready build declares where it will run before anything exists,
    # so that choice takes precedence over the generic target platform.
    target = (
        foundry.get("hosted_on")
        or project.get("target_platform")
        or "FLEX (Rackspace OpenStack) + OpenCenter Kubernetes"
    )
    # Ontology objects come from the declared business system when there was no
    # Foundry export to read them from — that is the point of this path.
    onto = project.get("business_ontology") or {}
    declared_objects = (onto.get("ontology") or {}).get("object") or {}

    decision = deployment_pattern(project)
    pattern = decision["pattern"]

    # Plain-language explanation of each pattern. A reader should not need to
    # know the taxonomy to understand what is being proposed.
    PLAIN = {
        "FOUNDRY_ON_RACKSPACE": {
            "title": "Foundry runs on Rackspace",
            "what": (
                "Palantir Foundry and AIP are installed inside a Rackspace private or sovereign "
                "environment, next to your data. Rackspace operates it and Palantir-certified "
                "Rackspace engineers build the workflows with your team."
            ),
            "why_it_fits": "Your data never leaves the boundary you control, and one operator is accountable for it.",
            "you_get": [
                "Foundry and AIP in your own governed environment",
                "Palantir-certified Rackspace engineers embedded with your team",
                "Rackspace managed operations from day two onward",
            ],
        },
        "EXTERNAL_MODEL": {
            "title": "Your Foundry, our model hosting",
            "what": (
                "You already run Foundry. We host the model or agent on "
                f"{target} and register it in your Foundry as an externally hosted model, "
                "which Foundry then calls."
            ),
            "why_it_fits": "You keep Foundry where it is; only the compute moves to Rackspace.",
            "you_get": [
                "The runtime hosted and operated by Rackspace",
                "Foundry keeps the ontology, permissions and audit trail",
            ],
        },
        "MAPPING_ONLY": {
            "title": "Foundry-ready mapping, no Foundry yet",
            "what": (
                "Nothing is installed. We turn your business problem into the objects, "
                "relationships and AI tool definitions your Foundry team can implement "
                "whenever you are ready."
            ),
            "why_it_fits": "You get the design work done without committing to a platform first.",
            "you_get": [
                "Object, relationship and AIP tool mapping",
                "A plan your Foundry team can pick up directly",
            ],
        },
    }[pattern]

    return {
        "lifecycle_state": "PROPOSED",
        "pattern": pattern,
        "pattern_title": PLAIN["title"],
        "pattern_reason": decision["reason"],
        "what_it_is": PLAIN["what"],
        "why_it_fits": PLAIN["why_it_fits"],
        "you_get": PLAIN["you_get"],
        "not_required": _NOT_REQUIRED[pattern],
        "summary": PLAIN["what"],
        "hosting_options": [
            {"name": "FLEX + OpenCenter", "suits": "production, customer tenancy, GPU node pool"},
            {"name": "Managed OSPC", "suits": "existing OSPC estate, Rackspace-operated"},
            {"name": "Rackspace AI sandbox", "suits": "evaluation and LaunchPad PoC before commitment"},
        ],
        # What still has to happen, and who does it. Every item starts unchecked
        # because none of it can be satisfied from here.
        "foundry_prerequisites": [dict(p) for p in _PREREQS[pattern]],
        # The steps, in order, in plain language.
        "how_to": _how_to(pattern, target),
        "endpoint_contract": {
            "transport": "HTTPS",
            "auth": "bearer token or mTLS, issued by the hosting side",
            "paths": {"inference": "/v1/predict", "health": "/health", "readiness": "/ready"},
            "runtime_detected": runtimes or [],
            "notes": "Contract must match the adapter's api() declaration exactly.",
        },
        "what_cannot_be_migrated": [
            "AIP Agents — they run inside Foundry and are invoked via Foundry APIs or the OSDK.",
            "Ontology data — only schema definitions export; objects stay in Foundry.",
            "Marketplace products — they install into another Foundry enrollment, not onto FLEX.",
        ],
        "deployable_here": (
            ["OSDK application (" + (detected.get("osdk", {}).get("language") or "unknown") + ")"]
            if detected.get("osdk") else []
        ) + (["Model / agent runtime registered as an externally hosted model"] if runtimes else []),
        # Present when the ontology was declared here rather than exported from
        # Foundry — the customer's Foundry team implements this, we do not.
        "declared_not_exported": bool(declared_objects) and not detected.get("kinds"),
        "foundry_target": {
            "enrollment": foundry.get("enrollment") or None,
            "ontology": foundry.get("ontology") or None,
            "hosted_on": foundry.get("hosted_on") or None,
        } if foundry else {},
        "open_questions": [
            "Which Foundry enrollment and ontology will this connect to?",
            "Who approves the egress policy?",
            "Does the data classification permit inference outside Foundry?",
        ],
    }
