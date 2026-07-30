"""Business-system ontology: pain in, AI tools out.

Five questions about one business system — what hurts, what goes in, what
should come out, and who else it touches — turned into concrete AI tools.

This is the Palantir ontology shape applied to opportunity discovery:

    business system   -> object
    related orgs      -> links
    pain points       -> properties that justify change
    derived AI tools  -> actions

The pain categories are taken verbatim from A-3 of the AI Enhancement Readiness
Assessment, so the nine-step discovery and this five-question version speak one
vocabulary rather than two.

Nothing is invented: a tool is only ever derived from a pain point the user
declared, and every tool records which pain produced it.
"""

from __future__ import annotations

from typing import Any, Dict, List

# A-3's categories -> what AI actually does about them.
# (capability, tool, what it needs, whether an action needs human approval)
PAIN_TO_CAPABILITY: Dict[str, Dict[str, Any]] = {
    "Manual data entry": {
        "capability": "Document AI / extraction",
        "tool": "Extraction agent with a typed output schema",
        "needs": ["document store", "output schema"],
        "writes": True,
    },
    "Repeated lookup": {
        "capability": "Retrieval (RAG)",
        "tool": "Retrieval assistant over the system's own records",
        "needs": ["vector store", "source documents"],
        "writes": False,
    },
    "Document reading": {
        "capability": "Document AI / summarisation",
        "tool": "Summarisation agent with citations back to the source",
        "needs": ["document store"],
        "writes": False,
    },
    "Approval delay": {
        "capability": "Workflow automation",
        "tool": "Workflow agent that prepares the decision for a human to approve",
        "needs": ["workflow API", "approver role"],
        "writes": True,
    },
    "Email dependency": {
        "capability": "Classification and routing",
        "tool": "Triage agent that classifies and routes inbound mail",
        "needs": ["mailbox connector", "routing rules"],
        "writes": True,
    },
    "Spreadsheet dependency": {
        "capability": "Data consolidation",
        "tool": "Ingestion pipeline replacing the spreadsheet as the source of truth",
        "needs": ["target datastore"],
        "writes": True,
    },
    "Handoff delay": {
        "capability": "Event-driven orchestration",
        "tool": "Orchestration agent spanning the linked teams",
        "needs": ["event source", "APIs of linked systems"],
        "writes": True,
    },
    "Duplicate work": {
        "capability": "Deduplication and matching",
        "tool": "Matching agent with a confidence score and an exception queue",
        "needs": ["record store"],
        "writes": True,
    },
    "Error-prone work": {
        "capability": "Prediction with explainability",
        "tool": "Scoring model with an explainability surface for reviewers",
        "needs": ["labelled history", "explainability method"],
        "writes": False,
    },
    "Knowledge search": {
        "capability": "Retrieval (RAG)",
        "tool": "Knowledge assistant over documentation and past cases",
        "needs": ["vector store", "knowledge base"],
        "writes": False,
    },
    "Compliance burden": {
        "capability": "Policy checking and audit",
        "tool": "Compliance checker emitting an auditable decision trail",
        "needs": ["policy set", "audit sink"],
        "writes": False,
    },
}

PAIN_CATEGORIES = tuple(PAIN_TO_CAPABILITY)


def derive(system: Dict[str, Any]) -> Dict[str, Any]:
    """Turn one declared business system into an ontology and an AI tool list.

    `system` carries: name, pain_points[], inputs[], desired_outputs[],
    related_orgs[]. Everything is optional; whatever is missing simply produces
    less, never a guess.
    """
    name = str(system.get("name") or "").strip()
    pains = [p for p in (system.get("pain_points") or []) if str(p).strip()]
    inputs = [i for i in (system.get("inputs") or []) if str(i).strip()]
    outputs = [o for o in (system.get("desired_outputs") or []) if str(o).strip()]
    related = [r for r in (system.get("related_orgs") or []) if str(r).strip()]

    tools: List[Dict[str, Any]] = []
    seen: set[str] = set()
    for pain in pains:
        spec = PAIN_TO_CAPABILITY.get(pain)
        if not spec:
            continue
        # Two pains can map to the same capability; keep one tool, cite both.
        if spec["tool"] in seen:
            for existing in tools:
                if existing["tool"] == spec["tool"] and pain not in existing["because"]:
                    existing["because"].append(pain)
            continue
        seen.add(spec["tool"])
        tools.append({
            "capability": spec["capability"],
            "tool": spec["tool"],
            "because": [pain],           # never a recommendation without a cause
            "requires": list(spec["needs"]),
            "changes_data": spec["writes"],
            "human_approval_required": spec["writes"],
            "permission": "WRITE" if spec["writes"] else "READ",
        })

    # Where the AI sits: between what goes in today and what should come out.
    placement = ""
    if inputs and outputs:
        placement = f"Between {', '.join(inputs[:3])} and {', '.join(outputs[:3])}"
    elif inputs:
        placement = f"Downstream of {', '.join(inputs[:3])} — desired output not yet stated"
    elif outputs:
        placement = f"Producing {', '.join(outputs[:3])} — current inputs not yet stated"

    ontology = {
        "object": {"name": name, "type": "BusinessSystem"} if name else {},
        "links": [{"from": name, "to": org, "type": "SERVES_OR_DEPENDS_ON"} for org in related],
        "properties": {
            "pain_points": pains,
            "current_inputs": inputs,
            "desired_outputs": outputs,
        },
        "actions": [{"name": t["tool"], "permission": t["permission"],
                     "human_approval_required": t["human_approval_required"]} for t in tools],
    }

    return {
        "system": name,
        "ontology": ontology,
        "ai_tools": tools,
        "placement": placement,
        "complete": bool(name and pains and inputs and outputs),
        "missing": _missing(name, pains, inputs, outputs),
        "summary": _summary(name, pains, tools, related),
    }


def _missing(name: str, pains: List[str], inputs: List[str], outputs: List[str]) -> List[str]:
    gaps = []
    if not name:
        gaps.append("business system not selected")
    if not pains:
        gaps.append("no pain point declared — nothing to justify an AI tool")
    if not inputs:
        gaps.append("current inputs not stated")
    if not outputs:
        gaps.append("desired output not stated")
    return gaps


def _summary(name: str, pains: List[str], tools: List[Dict[str, Any]], related: List[str]) -> str:
    if not name:
        return ""
    if not tools:
        return f"{name}: no AI tool proposed — declare a pain point first."
    caps = sorted({t["capability"] for t in tools})
    text = f"{name}: {len(pains)} pain point(s) → {len(tools)} tool(s) across {', '.join(caps)}"
    if related:
        text += f"; touches {', '.join(related[:3])}"
    return text + "."
