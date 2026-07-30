"""Tests for Stage 9 — AI Adoption & Production Factory."""

import io
import re
import json
import os
import sys
import zipfile
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(REPO / "workflow_dashboard"))

from workflow_dashboard.ai_adoption import assess, generate, importers, models, scanner  # noqa: E402
from workflow_dashboard.ai_adoption.store import ProjectStore  # noqa: E402


# ------------------------------------------------------------------ models


def test_weights_sum_to_one_for_every_mode():
    for mode, weights in models.WEIGHTS.items():
        assert abs(sum(weights.values()) - 1.0) < 1e-9, mode
        assert set(weights) == set(models.SCORE_CATEGORIES), mode


def test_new_project_rejects_unknown_mode():
    with pytest.raises(ValueError):
        models.new_project("x", "SIDEWAYS")


def test_new_project_leaves_unevidenced_fields_empty():
    p = models.new_project("Demo", "GREENFIELD")
    # Evidence-or-blank: no plausible defaults.
    assert p["data_sensitivity"] == ""
    assert p["business_owner"] == ""
    assert p["readiness_score"] is None
    assert p["status"] == "DRAFT"


# ------------------------------------------------------------------ store


def test_store_roundtrip_and_list(tmp_path):
    store = ProjectStore(tmp_path)
    p = models.new_project("Alpha", "BROWNFIELD", customer_id="c1")
    store.save(p)
    assert store.load(p["id"])["name"] == "Alpha"
    assert [r["name"] for r in store.list()] == ["Alpha"]
    assert store.list(customer_id="nope") == []
    assert store.delete(p["id"]) is True
    assert store.load(p["id"]) is None


def test_store_rejects_traversal_ids(tmp_path):
    store = ProjectStore(tmp_path)
    # A crafted id must not escape the directory.
    for bad in ("../../etc/passwd", "..", "", "/abs"):
        try:
            path = store._path(bad)
        except ValueError:
            continue
        assert path.parent == store.root


def test_audit_is_capped(tmp_path):
    store = ProjectStore(tmp_path)
    p = models.new_project("A", "GREENFIELD")
    for i in range(600):
        store.audit(p, "x", "tester", i=i)
    assert len(p["audit"]) == 500


# ------------------------------------------------------------------ archive safety


def _zip_with(entries, path):
    with zipfile.ZipFile(path, "w") as zf:
        for name, content in entries:
            zf.writestr(name, content)
    return path


def test_zip_traversal_is_rejected(tmp_path):
    archive = _zip_with([("../../evil.txt", "pwned"), ("ok.txt", "fine")], tmp_path / "a.zip")
    dest = tmp_path / "out"
    warnings = importers.extract_archive(archive, dest)
    assert any("traversal" in w for w in warnings)
    assert not (tmp_path.parent / "evil.txt").exists()
    assert (dest / "ok.txt").read_text() == "fine"


def test_zip_absolute_path_is_rejected(tmp_path):
    archive = _zip_with([("/etc/evil", "x"), ("ok.txt", "y")], tmp_path / "b.zip")
    warnings = importers.extract_archive(archive, tmp_path / "out")
    assert any("absolute path" in w or "traversal" in w for w in warnings)


def test_blocked_binary_extension_is_skipped(tmp_path):
    archive = _zip_with([("payload.so", "x"), ("ok.txt", "y")], tmp_path / "c.zip")
    dest = tmp_path / "out"
    warnings = importers.extract_archive(archive, dest)
    assert any("blocked file type" in w for w in warnings)
    assert not (dest / "payload.so").exists()


def test_unsupported_archive_raises(tmp_path):
    plain = tmp_path / "notanarchive.bin"
    plain.write_bytes(b"just bytes")
    with pytest.raises(importers.ImportError_):
        importers.extract_archive(plain, tmp_path / "out")


def test_redact_strips_tokens():
    assert "ghp_" not in importers._redact("token ghp_" + "a" * 30)
    assert "***" in importers._redact("https://user:supersecret@github.com/x.git")


# ------------------------------------------------------------------ scanner


@pytest.fixture
def sample_project(tmp_path):
    root = tmp_path / "proj"
    (root / "app").mkdir(parents=True)
    (root / "requirements.txt").write_text("fastapi==0.110\nlangchain==0.1\nchromadb==0.4\n")
    (root / "Dockerfile").write_text("FROM python:3.11\nCMD [\"python\",\"main.py\"]\n")
    (root / "app" / "main.py").write_text(
        "from fastapi import FastAPI\n"
        "import chromadb\n"
        "app = FastAPI()\n"
        "@app.get('/health')\n"
        "def health(): return {'ok': True}\n"
        "@app.post('/predict')\n"
        "def predict(): return {}\n"
        "API_KEY = 'sk-" + "a" * 32 + "'\n"
        "EXTERNAL = 'https://api.example.com/v1/chat'\n"
    )
    return root


def test_scanner_detects_stack(sample_project):
    out = scanner.scan_project(str(sample_project))
    assert out["scanned"] is True
    assert "FastAPI" in out["detected"]["app_framework"]
    assert "LangChain" in out["detected"]["ai_framework"]
    assert "ChromaDB" in out["detected"]["vector_store"]
    assert "Dockerfile" in out["deployment_assets"]
    assert out["has_healthcheck"] is True
    assert "requirements.txt" in out["dependency_manifests"]


def test_scanner_finds_secret_without_recording_value(sample_project):
    out = scanner.scan_project(str(sample_project))
    assert out["secret_findings"], "expected a secret finding"
    blob = json.dumps(out)
    # The finding records the pattern and file, never the matched secret.
    assert "sk-" + "a" * 32 not in blob
    assert any(f["pattern"] for f in out["secret_findings"])


def test_scanner_records_external_endpoint(sample_project):
    out = scanner.scan_project(str(sample_project))
    assert any("api.example.com" in e for e in out["external_endpoints"])


def test_scanner_derives_components(sample_project):
    out = scanner.scan_project(str(sample_project))
    kinds = {c["component_type"] for c in out["components"]}
    assert {"APPLICATION", "AGENT", "VECTOR_DATABASE", "CONTAINER", "API"} <= kinds


def test_scan_of_missing_tree_is_not_a_clean_pass():
    out = scanner.scan_project("")
    assert out["scanned"] is False
    assert "note" in out


def test_notebook_outputs_are_ignored(tmp_path):
    nb = {
        "cells": [
            {"cell_type": "code", "source": ["import langchain\n"], "outputs": [{"text": "AKIA" + "B" * 16}]}
        ]
    }
    root = tmp_path / "nbproj"
    root.mkdir()
    (root / "a.ipynb").write_text(json.dumps(nb))
    out = scanner.scan_project(str(root))
    assert "LangChain" in out["detected"]["ai_framework"]
    # The AWS key lives only in an output cell, which is never scanned.
    assert not out["secret_findings"]


# ------------------------------------------------------------------ assessment


def test_unscanned_project_is_not_checked_not_passed():
    project = models.new_project("Brown", "BROWNFIELD")
    result = assess.assess(project, scanner.scan_project(""))
    controls = result["breakdown"]["production"]["controls"]
    assert all(c["result"] == "NOT_CHECKED" for c in controls)
    assert result["breakdown"]["production"]["score"] == 0
    assert result["breakdown"]["production"]["checked"] == 0
    assert result["controls_not_checked"] > 0


def test_unclassified_data_blocks_even_when_unscanned():
    """Data classification is a declared fact, not a scan result — its absence
    is a real finding and blocks regardless of what could be scanned."""
    project = models.new_project("Brown", "BROWNFIELD")   # no data_sensitivity
    result = assess.assess(project, scanner.scan_project(""))
    assert result["verdict"] == "BLOCKED"
    assert any(g["severity"] == "CRITICAL" and "classified" in g["title"].lower()
               for g in result["gaps"])


def test_unscannable_but_declared_project_is_manual_review():
    """With nothing blocking, low confidence must force review, not a verdict."""
    project = models.new_project(
        "Brown", "BROWNFIELD", data_sensitivity="MEDIUM",
        data_owner="d@x.com", production_owner="p@x.com",
        business_goal="g", business_owner="b@x.com", description="metric",
    )
    result = assess.assess(project, scanner.scan_project(""))
    assert not [g for g in result["gaps"] if g["severity"] == "CRITICAL"]
    assert result["confidence"] < 50
    assert result["verdict"] == "MANUAL_REVIEW"


def test_secret_finding_produces_critical_gap(sample_project):
    project = models.new_project("P", "EXISTING_POC", data_sensitivity="LOW")
    result = assess.assess(project, scanner.scan_project(str(sample_project)))
    criticals = [g for g in result["gaps"] if g["severity"] == "CRITICAL"]
    assert any("secret" in g["title"].lower() for g in criticals)
    assert result["verdict"] == "BLOCKED"


def test_severity_is_per_control_not_per_category(tmp_path):
    """Regression: every failed security control was graded CRITICAL, so a
    missing requirements.txt blocked a project as hard as a leaked credential."""
    root = tmp_path / "clean"
    root.mkdir()
    # No secrets, but also no dependency manifest.
    (root / "main.py").write_text("def run():\n    return 1\n")
    scan = scanner.scan_project(str(root))
    assert not scan["secret_findings"]

    project = models.new_project("P", "EXISTING_POC", data_sensitivity="LOW",
                                 business_goal="g", business_owner="o", data_owner="d")
    result = assess.assess(project, scan)
    dep = [g for g in result["gaps"] if g["title"].startswith("Dependencies are pinned")]
    assert dep and dep[0]["severity"] == "MEDIUM", "dependency hygiene must not be CRITICAL"
    # With no genuine blocker the verdict must not be BLOCKED.
    assert result["verdict"] != "BLOCKED"


def test_real_blockers_are_still_critical(sample_project):
    """A committed secret and unclassified data must still stop the decision."""
    project = models.new_project("P", "EXISTING_POC")  # no data_sensitivity
    result = assess.assess(project, scanner.scan_project(str(sample_project)))
    crit = {g["title"] for g in result["gaps"] if g["severity"] == "CRITICAL"}
    assert any("secret" in t.lower() for t in crit)
    assert any("classified" in t.lower() for t in crit)
    assert result["verdict"] == "BLOCKED"


def test_score_is_reproducible_and_formula_exposed(sample_project):
    project = models.new_project("P", "GREENFIELD", data_sensitivity="LOW")
    scan = scanner.scan_project(str(sample_project))
    a1 = assess.assess(project, scan)
    a2 = assess.assess(project, scan)
    assert a1["readiness_score"] == a2["readiness_score"]
    assert "Σ" in a1["formula"]
    total = sum(b["contribution"] for b in a1["breakdown"].values())
    assert abs(total - a1["readiness_score"]) <= 1  # rounding only


# ------------------------------------------------------------------ A-1..A-9 reuse


def _evidence(**over):
    base = {"assessment_id": "ai-1785", "departments": 2, "pain_points": 3,
            "ai_opportunities": 2, "data_readiness": "High", "success_metric": "cut handling time 30%"}
    base.update(over)
    return base


def test_assessment_evidence_is_credited_and_attributed(sample_project):
    scan = scanner.scan_project(str(sample_project))
    plain = models.new_project("P", "GREENFIELD", data_sensitivity="LOW")
    with_ev = models.new_project("P", "GREENFIELD", data_sensitivity="LOW")
    with_ev["readiness_evidence"] = _evidence()

    a1, a2 = assess.assess(plain, scan), assess.assess(with_ev, scan)
    assert a2["readiness_score"] > a1["readiness_score"]

    # Every credited control names where it came from.
    assert a2["evidence_sources"], "expected attributed sources"
    for ctrl, src in a2["evidence_sources"].items():
        assert "ai-1785" in src
    value_controls = {c["control"]: c for c in a2["breakdown"]["value"]["controls"]}
    assert value_controls["business_goal"]["result"] == "PASS"
    assert "ai-1785" in value_controls["business_goal"]["source"]


def test_evidence_without_an_id_is_ignored(sample_project):
    """A blob with no assessment id cannot move a score — nothing to attribute to."""
    scan = scanner.scan_project(str(sample_project))
    plain = models.new_project("P", "GREENFIELD", data_sensitivity="LOW")
    forged = models.new_project("P", "GREENFIELD", data_sensitivity="LOW")
    forged["readiness_evidence"] = _evidence(assessment_id="")
    assert assess.assess(forged, scan)["readiness_score"] == assess.assess(plain, scan)["readiness_score"]
    assert assess.assess(forged, scan)["evidence_sources"] == {}


def test_empty_assessment_credits_nothing(sample_project):
    scan = scanner.scan_project(str(sample_project))
    p = models.new_project("P", "GREENFIELD", data_sensitivity="LOW")
    p["readiness_evidence"] = _evidence(pain_points=0, ai_opportunities=0, success_metric="", data_readiness="Unknown")
    assert assess.assess(p, scan)["evidence_sources"] == {}


def test_evidence_cannot_pass_a_security_or_production_control(sample_project):
    """The assessment evidences business value, not code. It must not touch these."""
    scan = scanner.scan_project(str(sample_project))
    p = models.new_project("P", "EXISTING_POC", data_sensitivity="LOW")
    p["readiness_evidence"] = _evidence()
    a = assess.assess(p, scan)
    for category in ("security", "production", "operations"):
        for c in a["breakdown"][category]["controls"]:
            assert "source" not in c, f"{category}/{c['control']} must not be credited by assessment evidence"
    # Secrets are still found, so the verdict stands.
    assert a["verdict"] == "BLOCKED"


def test_evidence_survives_the_api(client):
    r = client.post("/ai-adoption/projects", json={
        "name": "Reuse", "adoption_mode": "BROWNFIELD",
        "readiness_evidence": _evidence(),
    })
    assert r.status_code == 201
    assert r.get_json()["project"]["readiness_evidence"]["assessment_id"] == "ai-1785"


def test_evidence_must_be_an_object(client):
    r = client.post("/ai-adoption/projects", json={
        "name": "Bad", "adoption_mode": "BROWNFIELD", "readiness_evidence": "not-an-object"})
    assert r.status_code == 400


# ------------------------------------------------------------------ OpenCenter import


def test_opencenter_workload_proves_cloud_native_posture():
    """Arriving from Kubernetes is evidence, not an assertion."""
    src = importers.import_opencenter_workload({
        "name": "billing-api", "namespace": "billing", "image": "reg/billing@sha256:abc",
        "replicas": 3, "sensitivity": "MEDIUM"})
    p = src["posture"]
    assert p["containerised"] is True and p["kubernetes"] is True
    assert p["cloud_native"] is True
    assert p["observed_from"] == "OpenCenter"
    # Health and API still have to be declared — Kubernetes does not imply them.
    assert p["health_endpoint"] is False and p["api_published"] is False


def test_opencenter_without_image_digest_warns():
    src = importers.import_opencenter_workload({"name": "x", "namespace": "y"})
    assert any("not reproducible" in w for w in src["warnings"])


def test_opencenter_posture_credits_production_controls():
    src = importers.import_opencenter_workload({
        "name": "billing-api", "namespace": "billing", "image": "reg/b@sha256:a",
        "health_endpoint": "/health"})
    project = models.new_project("AI on Billing", "GREENFIELD", data_sensitivity="MEDIUM",
                                 source_type="OPENCENTER", business_owner="b@x.com",
                                 data_owner="d@x.com", production_owner="p@x.com", business_goal="g")
    project["import_source"] = {k: v for k, v in src.items() if k != "root"}
    r = assess.assess(project, scanner.scan_project(""))
    controls = {c["control"]: c for c in r["breakdown"]["production"]["controls"]}
    assert controls["containerised"]["result"] == "PASS"
    assert controls["orchestration"]["result"] == "PASS"
    assert controls["health_endpoint"]["result"] == "PASS"
    assert "Declared posture" in controls["containerised"]["source"]


@pytest.mark.parametrize("field,value", [
    ("foundry_target", {"hosted_on": "AI LaunchPad", "enrollment": "acme.palantirfoundry.com"}),
    ("integration", {"pattern": "Sidecar", "agent_access": "READ_ONLY"}),
    ("readiness_evidence", {"assessment_id": "ai-1", "pain_points": 2, "ai_opportunities": 1}),
])
def test_patch_accepts_everything_create_accepts(client, field, value):
    """Regression: the PATCH allow-list lagged the create allow-list, so these
    were accepted at creation and silently dropped on update."""
    r = client.post("/ai-adoption/projects", json={"name": "X", "adoption_mode": "GREENFIELD"})
    pid = r.get_json()["project"]["id"]
    patched = client.patch(f"/ai-adoption/projects/{pid}", json={field: value})
    assert patched.status_code == 200
    assert patched.get_json()["project"][field] == value


def test_opencenter_is_an_offered_source(client):
    sources = client.get("/ai-adoption/meta").get_json()["sources_by_mode"]
    assert "OPENCENTER" in sources["GREENFIELD"]
    assert "OPENCENTER" in sources["BROWNFIELD"]
    assert "OPENCENTER" in models.SOURCE_TYPES


def test_opencenter_import_over_the_api(client):
    r = client.post("/ai-adoption/projects", json={"name": "AI on Billing", "adoption_mode": "GREENFIELD"})
    pid = r.get_json()["project"]["id"]
    r = client.post(f"/ai-adoption/projects/{pid}/import", json={
        "kind": "OPENCENTER",
        "workload": {"name": "billing-api", "namespace": "billing",
                     "image": "reg/b@sha256:a", "sensitivity": "HIGH"}})
    assert r.status_code == 200
    p = r.get_json()["project"]
    assert p["source_type"] == "OPENCENTER"
    assert p["data_sensitivity"] == "HIGH"
    assert p["import_source"]["posture"]["cloud_native"] is True


# ------------------------------------------------------------------ demo flagging + bundle value


def test_demo_flag_travels_into_every_export(client):
    """A demo walkthrough must never be mistakable for a real assessment."""
    r = client.post("/ai-adoption/projects", json={
        "name": "Billing AI", "adoption_mode": "GREENFIELD", "is_demo": True})
    pid = r.get_json()["project"]["id"]
    assert r.get_json()["project"]["is_demo"] is True
    client.post(f"/ai-adoption/projects/{pid}/assess")
    client.post(f"/ai-adoption/projects/{pid}/plan")

    md = client.get(f"/ai-adoption/projects/{pid}/export?format=markdown").get_data(as_text=True)
    assert "DEMO" in md.split("\n")[2] or "DEMO" in md[:400]

    z = client.get(f"/ai-adoption/projects/{pid}/export?format=zip")
    with zipfile.ZipFile(io.BytesIO(z.data)) as zf:
        cover = zf.read([n for n in zf.namelist() if n.endswith("HANDOFF.md")][0]).decode()
    assert "DEMO PACK" in cover


def test_real_project_carries_no_demo_banner(client):
    r = client.post("/ai-adoption/projects", json={"name": "Real AI", "adoption_mode": "GREENFIELD"})
    pid = r.get_json()["project"]["id"]
    assert r.get_json()["project"]["is_demo"] is False
    client.post(f"/ai-adoption/projects/{pid}/assess")
    md = client.get(f"/ai-adoption/projects/{pid}/export?format=markdown").get_data(as_text=True)
    assert "DEMO" not in md


def test_validated_bundle_gets_value_credit(client):
    """Regression: a finished, evaluated agent scored worse on business value
    than an untested idea, because only the ontology could credit value."""
    plain = models.new_project("Idea", "EXISTING_POC", data_sensitivity="LOW")
    bundled = models.new_project("Agent", "EXISTING_POC", data_sensitivity="LOW")
    bundled["import_source"] = {
        "display_name": "KYC Agent",
        "manifest_kind": "AI4PEOPLE",
        "manifest_evaluation": {"report": "evaluation-report.json"},
        "manifest_project": {"owner": "risk@acme.com"},
    }
    scan = scanner.scan_project("")
    a_plain = assess.assess(plain, scan)
    a_bundle = assess.assess(bundled, scan)

    assert a_bundle["category_scores"]["value"] > a_plain["category_scores"]["value"]
    controls = {c["control"]: c for c in a_bundle["breakdown"]["value"]["controls"]}
    assert controls["business_goal"]["result"] == "PASS"
    assert "Validated agent bundle" in controls["business_goal"]["source"]
    assert "risk@acme.com" in controls["business_owner"]["source"]


def test_bundle_without_evaluation_gets_no_value_credit():
    p = models.new_project("Agent", "EXISTING_POC", data_sensitivity="LOW")
    p["import_source"] = {"display_name": "X", "manifest_kind": "AI4PEOPLE", "manifest_evaluation": {}}
    a = assess.assess(p, scanner.scan_project(""))
    assert "business_goal" not in a["evidence_sources"]


# ------------------------------------------------------------------ handoff pack


def _planned_project(client, with_ontology=True):
    r = client.post("/ai-adoption/projects", json={
        "name": "Billing AI", "adoption_mode": "GREENFIELD",
        "data_sensitivity": "MEDIUM", "business_owner": "cfo@acme.com"})
    pid = r.get_json()["project"]["id"]
    if with_ontology:
        client.post(f"/ai-adoption/projects/{pid}/ontology", json={
            "name": "Billing Platform",
            "pain_points": ["Manual data entry", "Approval delay"],
            "inputs": ["PDF invoices", "ERP records"],
            "desired_outputs": ["matched invoice"],
            "related_orgs": ["Finance", "Collections"]})
    client.post(f"/ai-adoption/projects/{pid}/assess")
    client.post(f"/ai-adoption/projects/{pid}/plan")
    return pid


def test_ontology_reaches_the_report(client):
    """Regression: the business case was scored and mapped but never written
    into the document a delivery team actually receives."""
    pid = _planned_project(client)
    md = client.get(f"/ai-adoption/projects/{pid}/export?format=markdown").get_data(as_text=True)
    assert "## Business case" in md
    for expected in ("Billing Platform", "Manual data entry", "Approval delay",
                     "Finance", "matched invoice", "Extraction agent"):
        assert expected in md, expected


def test_zip_handoff_pack_is_self_contained(client):
    pid = _planned_project(client)
    r = client.get(f"/ai-adoption/projects/{pid}/export?format=zip")
    assert r.status_code == 200
    assert r.mimetype == "application/zip"

    with zipfile.ZipFile(io.BytesIO(r.data)) as zf:
        names = {n.split("/", 1)[1] for n in zf.namelist()}
        assert {"HANDOFF.md", "README.md", "project.json", "readiness.csv",
                "business-ontology.json", "checksums.sha256"} <= names
        # Every file is hashed.
        lines = zf.read([n for n in zf.namelist() if n.endswith("checksums.sha256")][0]).decode().strip().splitlines()
        recorded = {ln.split("  ", 1)[1] for ln in lines}
        assert recorded == names - {"checksums.sha256"}
        cover = zf.read([n for n in zf.namelist() if n.endswith("HANDOFF.md")][0]).decode()

    # The cover note must not let anyone think this is a deployment.
    assert "PROPOSED" in cover
    assert "Nothing has been provisioned or deployed" in cover
    assert "Still unanswered" in cover


def test_pack_omits_the_bulky_scan_inventory(client):
    """The scan can run to megabytes of external URLs — inventory, not handoff."""
    pid = _planned_project(client)
    r = client.get(f"/ai-adoption/projects/{pid}/export?format=zip")
    with zipfile.ZipFile(io.BytesIO(r.data)) as zf:
        names = {n.split("/", 1)[1] for n in zf.namelist()}
    assert "scan_result.json" not in names


def test_palantir_handoff_preserves_starting_path_system_and_governance(client):
    context = {
        "workflow": "BROWNFIELD_TO_PALANTIR_READY",
        "starting_condition": "BROWNFIELD",
        "source_kind": "FLEX_BUSINESS_SYSTEM",
        "business_system": {
            "id": "mockbank",
            "name": "MockBank Mobile Banking",
            "components": [{"name": "bank-api"}, {"name": "bank-db"}],
        },
        "ontology_intent": {
            "pain_points": ["Approval delay"],
            "inputs": ["claims"],
            "desired_outputs": ["approved claim"],
            "related_orgs": ["Finance"],
        },
    }
    created = client.post("/ai-adoption/projects", json={
        "name": "MockBank AI",
        "adoption_mode": "BROWNFIELD",
        "source_type": "FLEX_BUSINESS_SYSTEM",
        "starting_condition": "BROWNFIELD",
        "business_system_id": "mockbank",
        "business_owner": "sponsor@customer.com",
        "data_owner": "data.owner@customer.com",
        "data_sensitivity": "HIGH",
        "sovereignty_requirements": "UK only",
        "external_transfer_allowed": False,
        "project_context": context,
        "palantir_required": True,
    })
    assert created.status_code == 201
    project = created.get_json()["project"]
    assert project["project_context"]["business_system"]["components"][0]["name"] == "bank-api"
    assert project["data_owner"] == "data.owner@customer.com"
    pid = project["id"]

    client.post(f"/ai-adoption/projects/{pid}/ontology", json={
        "name": "MockBank Mobile Banking",
        "pain_points": ["Approval delay"],
        "inputs": ["claims"],
        "desired_outputs": ["approved claim"],
        "related_orgs": ["Finance"],
    })
    client.post(f"/ai-adoption/projects/{pid}/assess")
    planned = client.post(f"/ai-adoption/projects/{pid}/plan").get_json()["project"]
    manifest = planned["palantir_handoff_manifest"]

    assert manifest["format"] == "AI_SWITCH_PALANTIR_HANDOFF_V1"
    assert manifest["workflow"]["starting_condition"] == "BROWNFIELD"
    assert manifest["project"]["business_system"]["name"] == "MockBank Mobile Banking"
    assert manifest["data_governance"]["residency_or_sovereignty"] == "UK only"
    assert manifest["direct_ingestion_ready"] is False
    assert manifest["requires_authorized_foundry_connection"] is True
    assert set(manifest["deployment_operating_model"]) == {
        "ai_switch", "palantir", "rackspace", "customer",
    }
    assert all(x["status"] == "NOT_CHECKED" for x in manifest["customer_approvals"])


def test_palantir_zip_contains_machine_readable_manifest_and_operating_model(client):
    created = client.post("/ai-adoption/projects", json={
        "name": "Claims AI",
        "adoption_mode": "GREENFIELD",
        "starting_condition": "GREENFIELD",
        "palantir_required": True,
        "project_context": {
            "business_system": {"id": "claims", "name": "Claims System", "components": []},
        },
    })
    pid = created.get_json()["project"]["id"]
    client.post(f"/ai-adoption/projects/{pid}/assess")
    client.post(f"/ai-adoption/projects/{pid}/plan")

    response = client.get(f"/ai-adoption/projects/{pid}/export?format=zip")
    with zipfile.ZipFile(io.BytesIO(response.data)) as zf:
        manifest_name = next(n for n in zf.namelist() if n.endswith("palantir-handoff-manifest.json"))
        manifest = json.loads(zf.read(manifest_name))
        cover = zf.read(next(n for n in zf.namelist() if n.endswith("HANDOFF.md"))).decode()
        report = zf.read(next(n for n in zf.namelist() if n.endswith("README.md"))).decode()

    assert manifest["direct_ingestion_ready"] is False
    assert "Palantir operates Foundry" in cover
    assert "Rackspace implements and manages" in cover
    assert "Direct-ingestion boundary" in report


def test_unknown_export_format_is_rejected(client):
    pid = _planned_project(client, with_ontology=False)
    r = client.get(f"/ai-adoption/projects/{pid}/export?format=tar")
    assert r.status_code == 400
    assert "zip" in r.get_json()["error"]


# ------------------------------------------------------------------ brownfield integration


def _brownfield(**integration):
    p = models.new_project("Portal AI", "BROWNFIELD", data_sensitivity="MEDIUM",
                           business_owner="b@x.com", data_owner="d@x.com",
                           production_owner="p@x.com", business_goal="g")
    if integration:
        p["integration"] = integration
    return p, scanner.scan_project("")


def test_brownfield_gets_an_integration_category():
    p, scan = _brownfield()
    r = assess.assess(p, scan)
    assert "integration" in r["breakdown"]
    assert abs(sum(r["weights"].values()) - 1.0) < 1e-9
    assert r["weights"]["integration"] == 0.20


@pytest.mark.parametrize("mode", ["GREENFIELD", "EXISTING_POC"])
def test_other_modes_never_see_integration_controls(mode):
    p = models.new_project("X", mode, data_sensitivity="LOW")
    r = assess.assess(p, scanner.scan_project(""))
    assert "integration" not in r["breakdown"]
    assert set(r["weights"]) == set(models.SCORE_CATEGORIES)


def test_untested_rollback_is_not_checked_not_passed():
    """The mode's whole promise is that the app survives the AI being switched
    off; an untested rollback must never read as satisfied."""
    p, scan = _brownfield(pattern="API-based", agent_access="READ_ONLY")
    r = assess.assess(p, scan)
    controls = {c["control"]: c for c in r["breakdown"]["integration"]["controls"]}
    assert controls["rollback_tested"]["result"] == "NOT_CHECKED"
    assert controls["works_without_ai"]["result"] == "NOT_CHECKED"


def test_automated_writes_without_tested_rollback_are_blocking():
    p, scan = _brownfield(pattern="API-based", agent_access="WRITE_AUTO")
    r = assess.assess(p, scan)
    controls = {c["control"]: c for c in r["breakdown"]["integration"]["controls"]}
    assert controls["rollback_tested"]["result"] == "FAIL"
    assert any(g["severity"] == "CRITICAL" and "rollback" in g["title"].lower() for g in r["gaps"])
    assert r["verdict"] == "BLOCKED"


def test_read_only_access_without_rollback_is_not_blocking():
    """Read-only cannot corrupt the system of record, so it must not block."""
    p, scan = _brownfield(pattern="Read-only data adapter", agent_access="READ_ONLY")
    r = assess.assess(p, scan)
    assert not [g for g in r["gaps"] if g["severity"] == "CRITICAL"]


def test_fully_answered_integration_scores_full_marks():
    p, scan = _brownfield(pattern="API-based", agent_access="WRITE_APPROVED",
                          works_without_ai=True, rollback_tested=True, apis_documented=True)
    r = assess.assess(p, scan)
    assert r["breakdown"]["integration"]["score"] == 100
    assert r["breakdown"]["integration"]["not_checked"] == 0


def test_integration_survives_the_api(client):
    r = client.post("/ai-adoption/projects", json={
        "name": "Portal AI", "adoption_mode": "BROWNFIELD",
        "integration": {"pattern": "Sidecar", "agent_access": "READ_ONLY", "rollback_tested": True},
    })
    assert r.status_code == 201
    pid = r.get_json()["project"]["id"]
    got = client.post(f"/ai-adoption/projects/{pid}/assess").get_json()["project"]
    assert got["assessment_result"]["breakdown"]["integration"]["checked"] >= 3


# ------------------------------------------------------------------ business ontology


def test_pain_vocabulary_matches_the_a3_assessment():
    """Both entry points must offer the same words, or they are two products."""
    from workflow_dashboard.ai_adoption import ontology

    a3 = {"Manual data entry", "Repeated lookup", "Document reading", "Approval delay",
          "Email dependency", "Spreadsheet dependency", "Handoff delay", "Duplicate work",
          "Error-prone work", "Knowledge search", "Compliance burden"}
    assert set(ontology.PAIN_CATEGORIES) == a3


def test_no_pain_means_no_tool():
    from workflow_dashboard.ai_adoption import ontology

    out = ontology.derive({"name": "Billing Platform", "inputs": ["PDFs"], "desired_outputs": ["matched invoice"]})
    assert out["ai_tools"] == []
    assert any("no pain point" in m for m in out["missing"])
    assert "no AI tool proposed" in out["summary"]


def test_every_tool_cites_the_pain_that_produced_it():
    from workflow_dashboard.ai_adoption import ontology

    out = ontology.derive({
        "name": "Billing Platform",
        "pain_points": ["Manual data entry", "Approval delay"],
        "inputs": ["PDF invoices", "ERP records"],
        "desired_outputs": ["matched invoice", "exception queue"],
        "related_orgs": ["Finance", "Collections"],
    })
    assert len(out["ai_tools"]) == 2
    for tool in out["ai_tools"]:
        assert tool["because"], tool["tool"]
        assert all(p in ontology.PAIN_CATEGORIES for p in tool["because"])
    assert out["complete"] is True
    assert out["missing"] == []


def test_two_pains_one_capability_merge_and_cite_both():
    from workflow_dashboard.ai_adoption import ontology

    out = ontology.derive({"name": "Support", "pain_points": ["Repeated lookup", "Knowledge search"]})
    rag = [t for t in out["ai_tools"] if t["capability"] == "Retrieval (RAG)"]
    assert len(rag) == 2  # different tools, same capability
    out2 = ontology.derive({"name": "Support", "pain_points": ["Repeated lookup", "Repeated lookup"]})
    assert len(out2["ai_tools"]) == 1


def test_data_changing_tools_require_human_approval():
    from workflow_dashboard.ai_adoption import ontology

    out = ontology.derive({"name": "X", "pain_points": list(ontology.PAIN_CATEGORIES)})
    for tool in out["ai_tools"]:
        assert tool["human_approval_required"] == tool["changes_data"]
        assert tool["permission"] == ("WRITE" if tool["changes_data"] else "READ")


def test_placement_derives_from_inputs_and_outputs():
    from workflow_dashboard.ai_adoption import ontology

    out = ontology.derive({"name": "X", "pain_points": ["Duplicate work"],
                           "inputs": ["ERP records"], "desired_outputs": ["matched invoice"]})
    assert "ERP records" in out["placement"] and "matched invoice" in out["placement"]
    partial = ontology.derive({"name": "X", "pain_points": ["Duplicate work"], "inputs": ["ERP records"]})
    assert "not yet stated" in partial["placement"]


def test_related_orgs_become_ontology_links():
    from workflow_dashboard.ai_adoption import ontology

    out = ontology.derive({"name": "Billing", "pain_points": ["Handoff delay"],
                           "related_orgs": ["Finance", "Collections"]})
    links = out["ontology"]["links"]
    assert [x["to"] for x in links] == ["Finance", "Collections"]
    assert all(x["from"] == "Billing" for x in links)


def test_ontology_endpoint_rejects_unknown_pain(client):
    r = client.post("/ai-adoption/projects", json={"name": "X", "adoption_mode": "GREENFIELD"})
    pid = r.get_json()["project"]["id"]
    bad = client.post(f"/ai-adoption/projects/{pid}/ontology", json={"pain_points": ["Vibes"]})
    assert bad.status_code == 422


def test_ontology_raises_the_value_score_with_attribution(client):
    r = client.post("/ai-adoption/projects", json={
        "name": "Billing AI", "adoption_mode": "GREENFIELD", "data_sensitivity": "MEDIUM"})
    pid = r.get_json()["project"]["id"]
    before = client.post(f"/ai-adoption/projects/{pid}/assess").get_json()["project"]["category_scores"]["value"]

    client.post(f"/ai-adoption/projects/{pid}/ontology", json={
        "name": "Billing Platform", "pain_points": ["Manual data entry"],
        "inputs": ["PDF invoices"], "desired_outputs": ["matched invoice"]})
    after_proj = client.post(f"/ai-adoption/projects/{pid}/assess").get_json()["project"]
    assert after_proj["category_scores"]["value"] > before

    controls = {c["control"]: c for c in after_proj["assessment_result"]["breakdown"]["value"]["controls"]}
    assert controls["business_goal"]["result"] == "PASS"
    assert "Business-system ontology" in controls["business_goal"]["source"]


def test_ontology_feeds_the_palantir_mapping(client):
    r = client.post("/ai-adoption/projects", json={"name": "Billing AI", "adoption_mode": "GREENFIELD"})
    pid = r.get_json()["project"]["id"]
    client.post(f"/ai-adoption/projects/{pid}/ontology", json={
        "name": "Billing Platform", "pain_points": ["Approval delay"],
        "related_orgs": ["Finance"], "inputs": ["ERP"], "desired_outputs": ["decision"]})
    plan = client.post(f"/ai-adoption/projects/{pid}/plan").get_json()["project"]
    mapping = plan["palantir_mapping"]

    objects = [o["source"] for o in mapping["proposed_ontology_objects"]]
    assert "Billing Platform" in objects and "Finance" in objects
    assert mapping["object_relationships"]
    derived = [t for t in mapping["aip_tools"] if t.get("derived_from_pain")]
    assert derived and "Approval delay" in derived[0]["derived_from_pain"]


# ------------------------------------------------------------------ FLEX app posture


def _flex_project(mode="GREENFIELD", **posture):
    system = {"id": "s1", "name": "Billing Platform", "vms": 6, "sensitivity": "MEDIUM"}
    system.update(posture)
    src = importers.import_flex_system(system)
    project = models.new_project(
        "AI on Billing", mode, data_sensitivity="MEDIUM", source_type="FLEX_BUSINESS_SYSTEM",
        business_owner="b@x.com", data_owner="d@x.com", production_owner="p@x.com", business_goal="g",
    )
    project["import_source"] = {k: v for k, v in src.items() if k != "root"}
    return project, scanner.scan_project(src.get("root", ""))


def test_legacy_flex_app_leaves_production_controls_unchecked():
    project, scan = _flex_project()
    r = assess.assess(project, scan)
    controls = r["breakdown"]["production"]["controls"]
    assert all(c["result"] == "NOT_CHECKED" for c in controls)
    assert r["breakdown"]["production"]["checked"] == 0


def test_cloud_native_flex_app_scores_better_than_a_lifted_vm():
    """A containerised app on OpenCenter is genuinely readier to host AI."""
    legacy, legacy_scan = _flex_project()
    modern, modern_scan = _flex_project(
        containerised=True, kubernetes=True, health_endpoint=True, api_published=True)

    a_legacy = assess.assess(legacy, legacy_scan)
    a_modern = assess.assess(modern, modern_scan)

    assert a_modern["readiness_score"] > a_legacy["readiness_score"]
    assert a_modern["confidence"] > a_legacy["confidence"]
    assert a_modern["breakdown"]["production"]["checked"] == 4
    assert a_modern["breakdown"]["production"]["score"] == 100


def test_declared_posture_is_attributed_not_silent():
    _, _ = _flex_project()
    modern, scan = _flex_project(containerised=True, kubernetes=True)
    a = assess.assess(modern, scan)
    controls = {c["control"]: c for c in a["breakdown"]["production"]["controls"]}
    assert controls["containerised"]["result"] == "PASS"
    assert "Declared posture" in controls["containerised"]["source"]
    assert "Billing Platform" in controls["containerised"]["source"]
    # Untick means unchecked, never a silent pass.
    assert controls["health_endpoint"]["result"] == "NOT_CHECKED"
    assert "source" not in controls["health_endpoint"]


def test_posture_cannot_satisfy_a_security_control():
    modern, scan = _flex_project(containerised=True, kubernetes=True,
                                 health_endpoint=True, api_published=True)
    a = assess.assess(modern, scan)
    for c in a["breakdown"]["security"]["controls"]:
        assert "source" not in c, c["control"]


def test_greenfield_can_seed_from_a_cloud_native_flex_app():
    """Building a new AI platform around an already-modernised FLEX app."""
    project, scan = _flex_project("GREENFIELD", containerised=True, kubernetes=True)
    assert project["import_source"]["posture"]["cloud_native"] is True
    rec = assess.recommend(project, assess.assess(project, scan), scan)
    assert rec["service_stack"]["production_home"] == "FLEX + OpenCenter"


# ------------------------------------------------------------------ greenfield service ladder


def _gpu_scan(tmp_path):
    root = tmp_path / "gpuproj"
    root.mkdir(exist_ok=True)   # callers may build several projects per tmp_path
    (root / "requirements.txt").write_text("vllm==0.5\ntorch==2.3\nfastapi\n")
    (root / "serve.py").write_text("import vllm, torch\n")
    return scanner.scan_project(str(root))


def test_evidenced_project_builds_on_spot_when_data_permits(tmp_path):
    """Spot is the only self-service per-second GPU option — the right place to
    iterate once the use case is evidenced."""
    project = models.new_project("New AI", "GREENFIELD", data_sensitivity="MEDIUM")
    scan = _gpu_scan(tmp_path)
    stack = assess.service_stack(project, scan, {"readiness_score": 70, "confidence": 90})
    assert stack["build_on"] == "Rackspace Spot"
    assert stack["spot_eligible"] is True
    assert stack["gpu_workload"] is True
    assert stack["gpu_classes"] == ["NVIDIA A30", "NVIDIA H100"]
    # Hybrid cloudspace guidance, because spot capacity can be reclaimed.
    spot_phase = [s for s in stack["ladder"] if s["service"] == "Rackspace Spot"][0]
    assert "on-demand node pool" in spot_phase["notes"]
    assert any("reclaimed" in w for w in stack["warnings"])


def test_regulated_data_never_lands_on_spot(tmp_path):
    for sens in ("HIGH", "REGULATED"):
        project = models.new_project("New AI", "GREENFIELD", data_sensitivity=sens)
        stack = assess.greenfield_stack(project, _gpu_scan(tmp_path))
        assert stack["spot_eligible"] is False, sens
        assert stack["build_on"] == "Private Cloud AI / AI Anywhere", sens
        assert stack["gpu_classes"] == [], sens


def test_uk_sovereignty_overrides_everything(tmp_path):
    project = models.new_project("New AI", "GREENFIELD", data_sensitivity="LOW")
    project["sovereignty_requirements"] = "Must remain in the UK"
    stack = assess.greenfield_stack(project, _gpu_scan(tmp_path))
    assert stack["build_on"] == "UK Sovereign Private AI"
    assert stack["spot_eligible"] is False
    assert stack["ladder"][-1]["service"] == "UK Sovereign Private AI"


def test_ladder_phases_are_stable(tmp_path):
    project = models.new_project("New AI", "GREENFIELD", data_sensitivity="LOW")
    stack = assess.service_stack(project, _gpu_scan(tmp_path))
    assert [s["phase"] for s in stack["ladder"]] == ["Prove the use case", "Build & iterate", "Production"]
    assert stack["ladder"][0]["service"] == "AI LaunchPad"


def test_no_pricing_is_ever_quoted(tmp_path):
    """The advertised entry rate is general compute, not A30/H100."""
    project = models.new_project("New AI", "GREENFIELD", data_sensitivity="LOW")
    stack = assess.greenfield_stack(project, _gpu_scan(tmp_path))
    blob = json.dumps(stack)
    assert "$" not in blob
    assert "0.001" not in blob
    assert any("No pricing is quoted" in w for w in stack["warnings"])


def test_bare_greenfield_project_enters_at_launchpad(tmp_path):
    """A new project with no owners or KPIs is not ready to self-serve GPUs."""
    project = models.new_project("New AI", "GREENFIELD", data_sensitivity="LOW")
    scan = _gpu_scan(tmp_path)
    rec = assess.recommend(project, assess.assess(project, scan), scan)
    assert rec["recommended_entry"] == "AI LaunchPad"
    assert "Rackspace Spot" in rec["scale_up_path"]
    assert "FLEX + OpenCenter" in rec["scale_up_path"]


def test_well_evidenced_greenfield_enters_at_spot(tmp_path):
    project = models.new_project(
        "New AI", "GREENFIELD", data_sensitivity="LOW",
        business_goal="g", business_owner="b@x.com", data_owner="d@x.com",
        production_owner="p@x.com", description="metric",
    )
    scan = _gpu_scan(tmp_path)
    rec = assess.recommend(project, assess.assess(project, scan), scan)
    assert rec["recommended_entry"] == "Rackspace Spot"
    assert rec["service_stack"]["ladder"][1]["entry_point"] is True


@pytest.mark.parametrize("mode", ["GREENFIELD", "BROWNFIELD", "EXISTING_POC"])
def test_same_three_services_carry_every_scenario(tmp_path, mode):
    """LaunchPad, Spot and FLEX are the go-to options for all AI projects."""
    project = models.new_project("P", mode, data_sensitivity="LOW")
    stack = assess.service_stack(project, _gpu_scan(tmp_path), {"readiness_score": 70, "confidence": 90})
    services = [s["service"] for s in stack["ladder"]]
    assert services == ["AI LaunchPad", "Rackspace Spot", "FLEX + OpenCenter"], mode
    assert stack["production_home"] == "FLEX + OpenCenter", mode
    # Exactly one phase is the entry point.
    assert sum(1 for s in stack["ladder"] if s["entry_point"]) == 1, mode


def test_unevidenced_project_enters_at_launchpad(tmp_path):
    project = models.new_project("P", "GREENFIELD", data_sensitivity="LOW")
    stack = assess.service_stack(project, _gpu_scan(tmp_path), {"readiness_score": 20, "confidence": 40})
    assert stack["build_on"] == "AI LaunchPad"
    assert stack["ladder"][0]["entry_point"] is True


def test_validated_agent_skips_launchpad(tmp_path):
    """An AI 4 the People agent has already been proven; another PoC is waste."""
    project = models.new_project("P", "EXISTING_POC", data_sensitivity="LOW",
                                 source_type="AI4PEOPLE")
    stack = assess.service_stack(project, _gpu_scan(tmp_path), {"readiness_score": 75, "confidence": 90})
    assert stack["build_on"] == "Rackspace Spot"
    assert "already validated" in stack["why"]
    assert stack["ladder"][1]["entry_point"] is True


def test_production_home_is_flex_unless_restricted(tmp_path):
    scan = _gpu_scan(tmp_path)
    plain = models.new_project("P", "BROWNFIELD", data_sensitivity="LOW")
    assert assess.service_stack(plain, scan)["production_home"] == "FLEX + OpenCenter"

    reg = models.new_project("P", "BROWNFIELD", data_sensitivity="REGULATED")
    assert assess.service_stack(reg, scan)["production_home"] == "Private Cloud AI / AI Anywhere"

    uk = models.new_project("P", "BROWNFIELD", data_sensitivity="LOW")
    uk["sovereignty_requirements"] = "UK only"
    assert assess.service_stack(uk, scan)["production_home"] == "UK Sovereign Private AI"


def test_scale_path_is_built_from_the_ladder(sample_project):
    project = models.new_project("P", "BROWNFIELD", data_sensitivity="LOW")
    scan = scanner.scan_project(str(sample_project))
    rec = assess.recommend(project, assess.assess(project, scan), scan)
    assert "AI LaunchPad" in rec["scale_up_path"]
    assert "Rackspace Spot" in rec["scale_up_path"]
    assert "FLEX + OpenCenter" in rec["scale_up_path"]
    assert rec["service_stack"]["ladder"]


# ------------------------------------------------------------------ palantir


def test_palantir_ontology_export_is_detected(tmp_path):
    from workflow_dashboard.ai_adoption import palantir

    root = tmp_path / "foundry"
    root.mkdir()
    (root / "ontology.json").write_text(json.dumps({
        "objectTypes": [{"apiName": "Claim"}, {"apiName": "Customer"}],
        "linkTypes": [{"apiName": "claimToCustomer"}],
        "actionTypes": [{"apiName": "approveClaim"}],
    }))
    out = palantir.detect(root)
    assert out["is_palantir"] and "ONTOLOGY" in out["kinds"]
    assert out["ontology"]["object_types"] == 2
    assert out["ontology"]["action_types"] == 1
    # No OSDK source => nothing deployable, and it must say so.
    assert any("nothing deployable" in f for f in out["findings"])


def test_osdk_application_is_the_deployable_artifact(tmp_path):
    from workflow_dashboard.ai_adoption import palantir

    root = tmp_path / "osdkapp"
    root.mkdir()
    (root / "package.json").write_text(json.dumps({
        "dependencies": {"@osdk/client": "^2.0.0", "react": "^18"}}))
    out = palantir.detect(root)
    assert out["is_palantir"] and "OSDK_APP" in out["kinds"]
    assert out["osdk"]["language"] == "typescript"
    assert not any("nothing deployable" in f for f in out["findings"])


def test_unstable_ontology_schema_is_a_finding_not_a_crash(tmp_path):
    """Palantir states the export schema may change; a surprise must not throw."""
    from workflow_dashboard.ai_adoption import palantir

    root = tmp_path / "weird"
    root.mkdir()
    (root / "ontology.json").write_text(json.dumps({"somethingElse": {"v": 1}}))
    out = palantir.detect(root)
    assert out["is_palantir"]
    assert any("schema may have changed" in f for f in out["findings"])

    (root / "ontology.json").write_text("{not json")
    out2 = palantir.detect(root)
    assert any("not valid JSON" in f for f in out2["findings"])


def test_marketplace_export_is_inventory_not_deployable(tmp_path):
    from workflow_dashboard.ai_adoption import palantir

    root = tmp_path / "mkt"
    root.mkdir()
    (root / "marketplace.yml").write_text("name: product\n")
    out = palantir.detect(root)
    assert "MARKETPLACE" in out["kinds"]
    assert any("not deployable to FLEX" in f for f in out["findings"])


def test_regulated_data_puts_foundry_on_rackspace():
    """Rackspace is a preferred operator for sovereign Palantir deployments, so
    data that cannot move means Foundry comes to the data."""
    from workflow_dashboard.ai_adoption import palantir

    p = models.new_project("X", "GREENFIELD", data_sensitivity="REGULATED")
    d = palantir.deployment_pattern(p)
    assert d["pattern"] == "FOUNDRY_ON_RACKSPACE"
    assert "REGULATED" in d["reason"]

    kit = palantir.connection_kit(p, scanner.scan_project(""), {})
    assert kit["pattern_title"] == "Foundry runs on Rackspace"
    # The benefit is only real if the removed prerequisites are stated.
    assert any("egress" in x.lower() for x in kit["not_required"])
    assert any("FDE" in q["item"] or "FDE" in q["owner"] for q in kit["foundry_prerequisites"])


def test_sovereignty_alone_is_enough():
    from workflow_dashboard.ai_adoption import palantir

    p = models.new_project("X", "GREENFIELD", data_sensitivity="LOW")
    p["sovereignty_requirements"] = "Must remain in the UK"
    p["external_transfer_allowed"] = True
    assert palantir.deployment_pattern(p)["pattern"] == "FOUNDRY_ON_RACKSPACE"


def test_existing_foundry_with_movable_data_uses_external_model():
    from workflow_dashboard.ai_adoption import palantir

    p = models.new_project("X", "GREENFIELD", data_sensitivity="LOW")
    p["external_transfer_allowed"] = True
    p["foundry_target"] = {"enrollment": "acme.palantirfoundry.com"}
    d = palantir.deployment_pattern(p)
    assert d["pattern"] == "EXTERNAL_MODEL"
    kit = palantir.connection_kit(p, scanner.scan_project(""), {})
    assert any("Egress policy" in q["item"] for q in kit["foundry_prerequisites"])


def test_no_foundry_named_yields_mapping_only():
    from workflow_dashboard.ai_adoption import palantir

    p = models.new_project("X", "GREENFIELD", data_sensitivity="LOW")
    p["external_transfer_allowed"] = True
    d = palantir.deployment_pattern(p)
    assert d["pattern"] == "MAPPING_ONLY"
    kit = palantir.connection_kit(p, scanner.scan_project(""), {})
    assert "no Foundry" in kit["pattern_title"] or "Foundry-ready" in kit["pattern_title"]


@pytest.mark.parametrize("pattern_setup,expected", [
    ({"data_sensitivity": "REGULATED"}, "FOUNDRY_ON_RACKSPACE"),
    ({"data_sensitivity": "LOW", "external_transfer_allowed": True}, "MAPPING_ONLY"),
])
def test_every_pattern_explains_itself_in_plain_language(pattern_setup, expected):
    from workflow_dashboard.ai_adoption import palantir

    p = models.new_project("X", "GREENFIELD", **{k: v for k, v in pattern_setup.items() if k == "data_sensitivity"})
    for k, v in pattern_setup.items():
        p[k] = v
    kit = palantir.connection_kit(p, scanner.scan_project(""), {})
    assert kit["pattern"] == expected
    # Every pattern must be explainable without knowing the taxonomy.
    for field in ("pattern_title", "pattern_reason", "what_it_is", "why_it_fits"):
        assert kit[field] and len(kit[field]) > 10, field
    assert kit["you_get"] and kit["how_to"]
    # Steps say who does them.
    for step in kit["how_to"]:
        assert step["who"] and step["step"] and step["detail"]


def test_connection_kit_states_what_cannot_be_migrated(sample_project):
    from workflow_dashboard.ai_adoption import palantir

    project = models.new_project("P", "EXISTING_POC", data_sensitivity="REGULATED")
    project["palantir_required"] = True
    scan = scanner.scan_project(str(sample_project))
    kit = palantir.connection_kit(project, scan, {"osdk": {"language": "typescript"}})

    assert kit["lifecycle_state"] == "PROPOSED"
    # REGULATED data now selects Foundry-on-Rackspace rather than assuming the
    # externally-hosted-model pattern.
    assert kit["pattern"] == "FOUNDRY_ON_RACKSPACE"
    # The honest limits must be carried, not quietly dropped.
    assert any("AIP Agents" in x for x in kit["what_cannot_be_migrated"])
    assert any("Ontology data" in x for x in kit["what_cannot_be_migrated"])
    # Every Foundry-side prerequisite starts unverified.
    assert kit["foundry_prerequisites"]
    assert all(p["status"] == "NOT_CHECKED" for p in kit["foundry_prerequisites"])
    # Under Foundry-on-Rackspace the external-endpoint prerequisites are gone by
    # design — Foundry and the runtime share one governed estate — and are
    # listed as not required instead.
    items = " ".join(p["item"] for p in kit["foundry_prerequisites"])
    assert "Egress policy" not in items
    assert any("egress" in x.lower() for x in kit["not_required"])
    assert "Sovereign placement decided" in items
    assert "FDE engagement scheduled" in items
    # All three hosting targets offered.
    names = " ".join(h["name"] for h in kit["hosting_options"])
    assert "FLEX" in names and "OSPC" in names and "sandbox" in names


def test_palantir_is_an_offered_source(client):
    sources = client.get("/ai-adoption/meta").get_json()["sources_by_mode"]
    assert "PALANTIR" in sources["EXISTING_POC"]
    assert "PALANTIR" in models.SOURCE_TYPES


def test_regulated_data_routes_to_private_cloud(sample_project):
    project = models.new_project("P", "GREENFIELD", data_sensitivity="REGULATED")
    scan = scanner.scan_project(str(sample_project))
    rec = assess.recommend(project, assess.assess(project, scan), scan)
    assert rec["recommended_entry"] == "Private Cloud AI / AI Anywhere"
    assert rec["palantir_fit"] == "Required"


# ------------------------------------------------------------------ generators


# ------------------------------------------------------------------ runtime target


def test_spot_does_not_target_opencenter(sample_project):
    """Spot ships its own managed Kubernetes. Sending a Spot-bound workload to
    the OpenCenter GitOps repo would deploy it to the wrong cluster."""
    project = models.new_project("P", "GREENFIELD", data_sensitivity="LOW")
    t = generate.resolve_runtime_target(project, {"build_on": "Rackspace Spot"})
    assert t["runtime"] == "SPOT_K8S"
    assert t["cluster"] is None and t["gitops_repo"] is None
    assert t["resolved"] is False
    assert "not OpenCenter" in t["note"]


_K8S_NS = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")


def test_namespace_prefers_the_global_project_id():
    project = models.new_project("Billing AI!! (v2)", "GREENFIELD")
    project["global_ai_project_id"] = "AIPROJ-2026-000101"
    ns = generate.resolve_runtime_target(project, {"build_on": "FLEX + OpenCenter"})["namespace"]
    assert ns == "aiproj-2026-000101"
    assert _K8S_NS.match(ns) and len(ns) <= 63


def test_namespace_falls_back_to_the_project_id_not_the_name():
    """Regression: a project called "A" produced namespace "a", and two projects
    sharing a name would have collided on one namespace."""
    a = models.new_project("A", "GREENFIELD")
    b = models.new_project("A", "GREENFIELD")
    ns_a = generate.resolve_runtime_target(a, {"build_on": "FLEX + OpenCenter"})["namespace"]
    ns_b = generate.resolve_runtime_target(b, {"build_on": "FLEX + OpenCenter"})["namespace"]
    assert ns_a != "a" and ns_b != "a"
    assert ns_a != ns_b, "two same-named projects must not share a namespace"
    for ns in (ns_a, ns_b):
        assert _K8S_NS.match(ns), ns
        assert len(ns) <= 63
        assert ns.startswith("a-")   # readable hint, then a slice of the uuid


def test_namespace_uses_sender_id_for_submitted_bundles():
    p = models.new_project("KYC", "EXISTING_POC")
    p["sender_project_id"] = "AIPROJ-2026-000201"
    ns = generate.resolve_runtime_target(p, {"build_on": "FLEX + OpenCenter"})["namespace"]
    assert ns == "aiproj-2026-000201"


@pytest.mark.parametrize("name", ["", "!!!", "---", "9lives", "Ünïcodé"])
def test_namespace_is_always_kubernetes_legal(name):
    p = models.new_project(name or "x", "GREENFIELD")
    ns = generate.resolve_runtime_target(p, {"build_on": "FLEX + OpenCenter"})["namespace"]
    assert _K8S_NS.match(ns), f"{name!r} -> {ns!r}"
    assert 0 < len(ns) <= 63


def test_unreadable_cluster_api_leaves_target_unresolved(monkeypatch):
    """An unreachable OpenCenter must not block planning or invent a cluster."""
    monkeypatch.setattr(generate, "_opencenter_clusters", lambda *a, **k: {})
    project = models.new_project("P", "BROWNFIELD", data_sensitivity="MEDIUM")
    t = generate.resolve_runtime_target(project, {"build_on": "FLEX + OpenCenter"})
    assert t["runtime"] == "OPENCENTER"
    assert t["cluster"] is None
    assert t["resolved"] is False
    assert "undecided" in t["note"]


def test_readable_cluster_binds_the_target(monkeypatch):
    monkeypatch.setattr(generate, "_opencenter_clusters", lambda *a, **k: {
        "active_pair": {"cluster": "mockbank", "organization": "mockbank-org"},
        "clusters": ["mockbank"]})
    project = models.new_project("P", "BROWNFIELD", data_sensitivity="MEDIUM")
    t = generate.resolve_runtime_target(project, {"build_on": "FLEX + OpenCenter"})
    assert (t["cluster"], t["organization"], t["gitops_repo"]) == ("mockbank", "mockbank-org", "mockbank-org")
    assert t["resolved"] is True


def test_unresolved_target_becomes_an_open_decision(monkeypatch, sample_project):
    """Regression: the plan listed 'OpenCenter Kubernetes cluster' in the bill of
    materials as though it were a decision, with no cluster behind it."""
    monkeypatch.setattr(generate, "_opencenter_clusters", lambda *a, **k: {})
    project = models.new_project("P", "BROWNFIELD", data_sensitivity="MEDIUM")
    scan = scanner.scan_project(str(sample_project))
    arch = generate.build_architecture(project, scan,
                                       {"service_stack": {"build_on": "FLEX + OpenCenter"}, "gaps": []})
    assert any("not yet chosen" in c["name"] for c in arch["components"])
    assert any("cluster not chosen" in u for u in arch["unresolved"])
    assert arch["runtime_target"]["resolved"] is False


def test_resolved_target_names_the_cluster_in_the_bom(monkeypatch, sample_project):
    monkeypatch.setattr(generate, "_opencenter_clusters", lambda *a, **k: {
        "active_pair": {"cluster": "mockbank", "organization": "mockbank-org"}})
    project = models.new_project("P", "BROWNFIELD", data_sensitivity="MEDIUM")
    arch = generate.build_architecture(project, scanner.scan_project(str(sample_project)),
                                       {"service_stack": {"build_on": "FLEX + OpenCenter"}, "gaps": []})
    assert any("mockbank" in c["name"] for c in arch["components"])
    assert not any("cluster not chosen" in u for u in arch["unresolved"])


def test_report_states_whether_the_target_is_resolved(monkeypatch, sample_project):
    monkeypatch.setattr(generate, "_opencenter_clusters", lambda *a, **k: {})
    project = models.new_project("P", "BROWNFIELD", data_sensitivity="MEDIUM")
    scan = scanner.scan_project(str(sample_project))
    project["scan_result"] = scan
    project["assessment_result"] = assess.assess(project, scan)
    project["deployment_plan"] = generate.build_architecture(
        project, scan, {"service_stack": {"build_on": "FLEX + OpenCenter"}, "gaps": []})
    md = generate.report_markdown(project)
    assert "Deploy target" in md
    assert "**not yet chosen**" in md
    assert "Target resolved | **no**" in md


def test_architecture_is_labelled_proposed(sample_project):
    project = models.new_project("P", "GREENFIELD", data_sensitivity="LOW")
    scan = scanner.scan_project(str(sample_project))
    arch = generate.build_architecture(project, scan, assess.assess(project, scan))
    assert arch["lifecycle_state"] == "PROPOSED"
    assert "flowchart" in arch["mermaid"]
    assert arch["bill_of_materials"]


def test_palantir_tools_gate_mutating_endpoints(sample_project):
    project = models.new_project("P", "BROWNFIELD")
    scan = scanner.scan_project(str(sample_project))
    mapping = generate.build_palantir_mapping(project, scan)
    post = [t for t in mapping["aip_tools"] if t["endpoint"] == "/predict"]
    assert post and post[0]["human_approval_required"] is True
    assert post[0]["permission"] == "WRITE"


def test_journey_never_marks_delivery_engagements_done(sample_project):
    """Regression: a plan must not complete FAIR Ideate or an AI LaunchPad."""
    project = models.new_project("P", "GREENFIELD")
    project["status"] = "PLANNED"
    scan = scanner.scan_project(str(sample_project))
    journey = generate.build_journey(project, assess.assess(project, scan))
    assert [j["step"] for j in journey][0] == "FAIR Ideate"
    # GREENFIELD performs none of its own journey steps.
    assert not any(j["status"] == "DONE" for j in journey)
    assert journey[0]["status"] == "IN_PROGRESS"
    assert all(j["performed_by"] == "Rackspace delivery" for j in journey)


def test_journey_credits_only_steps_this_tool_performs():
    project = models.new_project("P", "EXISTING_POC")
    project["status"] = "PLANNED"
    journey = generate.build_journey(project, {"gaps": []})
    done = [j["step"] for j in journey if j["status"] == "DONE"]
    # Import and gap assessment are genuinely done here; Industrialize is not.
    assert done == ["PoC Import", "Production Gap Assessment"]
    assert journey[2]["step"] == "Industrialize"
    assert journey[2]["status"] == "IN_PROGRESS"
    assert journey[2]["performed_by"] == "Rackspace delivery"


def test_draft_project_has_no_progress():
    project = models.new_project("P", "BROWNFIELD")
    journey = generate.build_journey(project, {"gaps": []})
    assert all(j["status"] == "PENDING" for j in journey)


def test_endpoint_count_is_not_the_capped_list_length(tmp_path):
    """Regression: the plan reported the truncated list length as the total."""
    root = tmp_path / "many"
    root.mkdir()
    urls = "\n".join(f"u = 'https://host{i}.example.com/x'" for i in range(150))
    (root / "m.py").write_text(urls)
    scan = scanner.scan_project(str(root))
    assert len(scan["external_endpoints"]) == 80
    assert scan["external_endpoint_count"] == 150
    arch = generate.build_architecture(models.new_project("P", "GREENFIELD"), scan, {"gaps": []})
    assert any("150 external endpoint" in u for u in arch["unresolved"])


def test_reports_render_in_all_three_formats(sample_project):
    project = models.new_project("P", "EXISTING_POC", data_sensitivity="LOW")
    scan = scanner.scan_project(str(sample_project))
    result = assess.assess(project, scan)
    project["scan_result"] = scan
    project["assessment_result"] = result
    project["recommendation"] = assess.recommend(project, result, scan)
    project["deployment_plan"] = generate.build_architecture(project, scan, result)
    project["palantir_mapping"] = generate.build_palantir_mapping(project, scan)

    md = generate.report_markdown(project)
    assert "# AI Adoption Report" in md and "```mermaid" in md
    assert "not a deployment" in md
    csv_out = generate.report_csv(project)
    assert "readiness,score" in csv_out.replace(", ", ",")
    assert json.loads(generate.report_json(project))["name"] == "P"


# ------------------------------------------------------------------ routes


@pytest.fixture
def client(tmp_path, monkeypatch):
    from flask import Flask

    from workflow_dashboard.ai_adoption.routes import create_ai_adoption_blueprint

    app = Flask(__name__)
    app.secret_key = "test"
    app.register_blueprint(create_ai_adoption_blueprint(tmp_path))
    app.config["TESTING"] = True
    return app.test_client()


def test_meta_lists_modes(client):
    r = client.get("/ai-adoption/meta")
    assert r.status_code == 200
    assert set(r.get_json()["adoption_modes"]) == set(models.ADOPTION_MODES)


def test_greenfield_can_start_from_a_migrated_flex_app(client):
    """Regression: Greenfield could not be seeded from a migrated FLEX system,
    so "build new AI around the Billing Platform we just migrated" had no path."""
    sources = client.get("/ai-adoption/meta").get_json()["sources_by_mode"]
    assert "FLEX_BUSINESS_SYSTEM" in sources["GREENFIELD"]
    assert "FLEX_BUSINESS_SYSTEM" in sources["BROWNFIELD"]


def test_every_scenario_can_use_a_migration_log_business_system(client):
    """Greenfield, Brownfield and Goldenfield all deploy for some application,
    so all three can attach one defined in the Migration Log."""
    sources = client.get("/ai-adoption/meta").get_json()["sources_by_mode"]
    for mode in ("GREENFIELD", "BROWNFIELD", "EXISTING_POC"):
        assert "FLEX_BUSINESS_SYSTEM" in sources[mode], mode
        assert "OPENCENTER" in sources[mode], mode


def test_declared_components_become_project_components(client):
    """A business system has no source tree, but its components are known from
    the Migration Log engine and must reach the plan."""
    r = client.post("/ai-adoption/projects", json={
        "name": "Portal AI", "adoption_mode": "BROWNFIELD", "data_sensitivity": "MEDIUM"})
    pid = r.get_json()["project"]["id"]
    r = client.post(f"/ai-adoption/projects/{pid}/import", json={
        "kind": "FLEX",
        "system": {
            "id": "mockbank", "name": "MockBank Mobile Banking", "vms": 3,
            "sensitivity": "MEDIUM", "archetype": "Banking", "criticality": "Critical",
            "components": ["bank-frontend", "bank-api", "bank-db"],
            "containerised": True, "kubernetes": True,
        }})
    assert r.status_code == 200
    p = r.get_json()["project"]

    declared = p["import_source"]["declared"]
    assert declared["components"] == ["bank-frontend", "bank-api", "bank-db"]
    assert declared["archetype"] == "Banking"
    assert declared["criticality"] == "Critical"
    # And they land as real component records the plan can target.
    names = [c["name"] for c in p["components"]]
    assert "bank-api" in names
    assert all(c["source"] == "migration-log business system"
               for c in p["components"] if c["name"] in declared["components"])


def test_migration_log_component_records_keep_runtime_and_location(client):
    """The browser store uses component objects, not just names. Importing one
    must not stringify the object or discard the fields the AI plan needs."""
    r = client.post("/ai-adoption/projects", json={
        "name": "Payments AI", "adoption_mode": "GREENFIELD",
        "data_sensitivity": "HIGH",
    })
    pid = r.get_json()["project"]["id"]
    r = client.post(f"/ai-adoption/projects/{pid}/import", json={
        "kind": "FLEX",
        "system": {
            "id": "payments", "name": "Payments Platform",
            "vms": [{"id": "vm-1"}, {"id": "vm-2"}],
            "archetype": "api", "criticality": "Critical",
            "components": [
                {
                    "name": "payments-api", "type": "API Server",
                    "runtime": "Python / gunicorn", "src": "http://10.0.0.8:8000",
                    "path": "/opt/payments",
                },
                {"name": "payments-db", "type": "Database", "runtime": "PostgreSQL"},
            ],
        },
    })
    assert r.status_code == 200
    project = r.get_json()["project"]
    declared = project["import_source"]["declared"]
    assert declared["vms"] == 2
    assert declared["components"] == ["payments-api", "payments-db"]
    api = next(c for c in project["components"] if c["name"] == "payments-api")
    assert api["runtime"] == "Python / gunicorn"
    assert api["location"] == "/opt/payments"
    assert api["metadata_json"]["source"] == "http://10.0.0.8:8000"


def test_business_system_components_raise_confidence(client):
    """The measurable point of importing from the Migration Log."""
    def build(system):
        r = client.post("/ai-adoption/projects", json={
            "name": "X", "adoption_mode": "BROWNFIELD", "data_sensitivity": "MEDIUM",
            "business_owner": "b@x.com", "data_owner": "d@x.com",
            "production_owner": "p@x.com", "business_goal": "g"})
        pid = r.get_json()["project"]["id"]
        client.post(f"/ai-adoption/projects/{pid}/import", json={"kind": "FLEX", "system": system})
        return client.post(f"/ai-adoption/projects/{pid}/assess").get_json()["project"]["assessment_result"]

    flat = build({"id": "a", "name": "Customer Portal", "vms": 4})
    rich = build({"id": "b", "name": "MockBank", "vms": 3, "archetype": "Banking",
                  "criticality": "Critical", "components": ["fe", "api", "db"],
                  "containerised": True, "kubernetes": True,
                  "health_endpoint": True, "api_published": True})

    assert rich["confidence"] > flat["confidence"]
    assert rich["breakdown"]["production"]["checked"] > flat["breakdown"]["production"]["checked"]


def test_ready_agent_path_leads_with_ai4people(client):
    """Deploying a validated AI 4 the People / YES AI CAN agent is the headline
    route for EXISTING_POC now that direct submit exists."""
    sources = client.get("/ai-adoption/meta").get_json()["sources_by_mode"]
    assert sources["EXISTING_POC"][0] == "AI4PEOPLE"


def test_every_advertised_source_is_a_known_type(client):
    sources = client.get("/ai-adoption/meta").get_json()["sources_by_mode"]
    for mode, listed in sources.items():
        assert set(listed) <= set(models.SOURCE_TYPES), mode
        assert listed, mode


def test_create_validates_mode(client):
    r = client.post("/ai-adoption/projects", json={"name": "X", "adoption_mode": "NOPE"})
    assert r.status_code == 400


def test_full_flow_upload_to_export(client, tmp_path):
    r = client.post("/ai-adoption/projects", json={
        "name": "Claims AI", "adoption_mode": "EXISTING_POC",
        "data_sensitivity": "MEDIUM", "business_owner": "ops@x.com",
        "business_goal": "Ticket automation",
    })
    assert r.status_code == 201
    pid = r.get_json()["project"]["id"]

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr("proj/requirements.txt", "fastapi\nlangchain\n")
        zf.writestr("proj/main.py", "from fastapi import FastAPI\n@app.get('/health')\ndef h(): pass\n")
        zf.writestr("proj/Dockerfile", "FROM python:3.11\n")
    buf.seek(0)

    r = client.post(
        f"/ai-adoption/projects/{pid}/import",
        data={"file": (buf, "proj.zip")},
        content_type="multipart/form-data",
    )
    assert r.status_code == 200, r.get_data(as_text=True)
    project = r.get_json()["project"]
    assert project["status"] == "IMPORTED"
    assert project["scan_result"]["scanned"] is True
    assert "FastAPI" in project["scan_result"]["detected"]["app_framework"]

    r = client.post(f"/ai-adoption/projects/{pid}/assess")
    assert r.status_code == 200
    assert r.get_json()["project"]["status"] == "ASSESSED"

    r = client.post(f"/ai-adoption/projects/{pid}/plan")
    assert r.status_code == 200
    planned = r.get_json()["project"]
    assert planned["status"] == "PLANNED"
    assert planned["time_to_plan_ms"] is not None
    assert planned["deployment_plan"]["lifecycle_state"] == "PROPOSED"
    assert planned["journey"]

    for fmt in ("json", "csv", "markdown"):
        r = client.get(f"/ai-adoption/projects/{pid}/export?format={fmt}")
        assert r.status_code == 200, fmt
        assert r.data


def test_import_rejects_unknown_kind(client):
    r = client.post("/ai-adoption/projects", json={"name": "X", "adoption_mode": "GREENFIELD"})
    pid = r.get_json()["project"]["id"]
    r = client.post(f"/ai-adoption/projects/{pid}/import", json={"kind": "TELEPATHY"})
    assert r.status_code == 400


def test_brownfield_flex_import_needs_no_source_tree(client):
    r = client.post("/ai-adoption/projects", json={"name": "Portal", "adoption_mode": "BROWNFIELD"})
    pid = r.get_json()["project"]["id"]
    r = client.post(f"/ai-adoption/projects/{pid}/import", json={
        "kind": "FLEX",
        "system": {"id": "sys1", "name": "Customer Portal", "vms": 4, "sensitivity": "MEDIUM"},
    })
    assert r.status_code == 200
    project = r.get_json()["project"]
    assert project["source_type"] == "FLEX_BUSINESS_SYSTEM"
    assert project["data_sensitivity"] == "MEDIUM"
    assert project["scan_result"]["scanned"] is False


def test_export_404_for_unknown_project(client):
    assert client.get("/ai-adoption/projects/does-not-exist/export").status_code == 404


@pytest.mark.parametrize("bad_id", ["..", ".", "%2e%2e", "..%00"])
def test_hostile_project_id_is_404_not_500(client, bad_id):
    """Regression: store._path raised ValueError, surfacing as a 500."""
    r = client.get(f"/ai-adoption/projects/{bad_id}")
    assert r.status_code in (404, 400), r.status_code


def test_auth_denies_remote_when_unconfigured(client, monkeypatch):
    monkeypatch.delenv("AI_ADOPTION_GITHUB_CLIENT_ID", raising=False)
    # A non-loopback peer with no OAuth configured must be denied, not admitted.
    r = client.post(
        "/ai-adoption/projects",
        json={"name": "X", "adoption_mode": "GREENFIELD"},
        environ_overrides={"REMOTE_ADDR": "203.0.113.9"},
    )
    assert r.status_code == 401
    assert r.get_json()["login_url"] == "/ai-adoption/auth/login"


def test_auth_allows_loopback(client):
    r = client.post(
        "/ai-adoption/projects",
        json={"name": "X", "adoption_mode": "GREENFIELD"},
        environ_overrides={"REMOTE_ADDR": "127.0.0.1"},
    )
    assert r.status_code == 201


SERVICE_KEY = "s3cret-key-for-yesaican-0123456789"


def test_service_key_authenticates_a_remote_caller(client, monkeypatch):
    """YES AI CAN / AI 4 the People submit from a server, not a browser."""
    monkeypatch.setenv("AI_ADOPTION_API_KEYS", f"yesaican:{SERVICE_KEY}")
    r = client.post(
        "/ai-adoption/projects",
        json={"name": "X", "adoption_mode": "GREENFIELD"},
        headers={"X-API-Key": SERVICE_KEY},
        environ_overrides={"REMOTE_ADDR": "203.0.113.9"},
    )
    assert r.status_code == 201


def test_wrong_service_key_is_rejected(client, monkeypatch):
    monkeypatch.setenv("AI_ADOPTION_API_KEYS", f"yesaican:{SERVICE_KEY}")
    r = client.post(
        "/ai-adoption/projects",
        json={"name": "X", "adoption_mode": "GREENFIELD"},
        headers={"X-API-Key": "wrong-but-long-enough-key-here"},
        environ_overrides={"REMOTE_ADDR": "203.0.113.9"},
    )
    assert r.status_code == 401


def test_short_service_keys_are_ignored(client, monkeypatch):
    """A placeholder-length secret must not guard an import endpoint."""
    monkeypatch.setenv("AI_ADOPTION_API_KEYS", "yesaican:short")
    r = client.post(
        "/ai-adoption/projects",
        json={"name": "X", "adoption_mode": "GREENFIELD"},
        headers={"X-API-Key": "short"},
        environ_overrides={"REMOTE_ADDR": "203.0.113.9"},
    )
    assert r.status_code == 401


def _bundle(manifest_extra=None):
    """A minimal AI4People bundle, as the sending platforms produce."""
    import yaml as _yaml

    manifest = {
        "schema_version": "1.0",
        "project": {"name": "Agent", "owner": "biz@x.com", "version": "1.0.0"},
        "agent": {"passport_file": "agent-passport.json", "health_endpoint": "/health"},
        "model": {"model_name": "llama3.1", "license": "Llama 3.1 Community"},
        "data": {"sensitivity": "MEDIUM"},
        "deployment": {"dockerfile": None},
    }
    if manifest_extra:
        manifest.update(manifest_extra)
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr("production-handoff/cloudjumper-handoff.yaml", _yaml.safe_dump(manifest))
        zf.writestr("production-handoff/agent-passport.json", json.dumps({"agent": {"name": "Agent"}}))
    buf.seek(0)
    return buf


def test_submit_creates_imports_assesses_and_plans_in_one_call(client, monkeypatch):
    monkeypatch.setenv("AI_ADOPTION_API_KEYS", f"yesaican:{SERVICE_KEY}")
    r = client.post(
        "/ai-adoption/submit",
        data={
            "metadata": json.dumps({
                "name": "KYC Agent", "adoption_mode": "BROWNFIELD",
                "global_ai_project_id": "AIPROJ-2026-000201",
                "data_sensitivity": "REGULATED", "business_owner": "risk@x.com",
            }),
            "file": (_bundle(), "handoff.zip"),
        },
        content_type="multipart/form-data",
        headers={"X-API-Key": SERVICE_KEY},
        environ_overrides={"REMOTE_ADDR": "203.0.113.9"},
    )
    assert r.status_code == 201, r.get_data(as_text=True)
    body = r.get_json()
    assert body["manifest_kind"] == "AI4PEOPLE"
    assert body["manifest_findings"] == []
    assert body["status"] == "PLANNED"
    assert body["readiness_score"] is not None
    assert body["time_to_plan_ms"] is not None
    # REGULATED data must route to the private-cloud entry point.
    assert body["recommended_entry"] == "Private Cloud AI / AI Anywhere"


def test_resubmitting_the_same_bundle_is_idempotent(client, monkeypatch):
    """Retrying a timeout must not create a second project."""
    monkeypatch.setenv("AI_ADOPTION_API_KEYS", f"yesaican:{SERVICE_KEY}")
    meta = json.dumps({"name": "Dup", "adoption_mode": "GREENFIELD",
                       "global_ai_project_id": "AIPROJ-2026-000999"})

    def send():
        return client.post(
            "/ai-adoption/submit",
            data={"metadata": meta, "file": (_bundle(), "handoff.zip")},
            content_type="multipart/form-data",
            headers={"X-API-Key": SERVICE_KEY},
            environ_overrides={"REMOTE_ADDR": "203.0.113.9"},
        )

    first = send().get_json()
    second = send().get_json()
    assert first["duplicate"] is False
    assert second["duplicate"] is True
    assert second["project_id"] == first["project_id"]


def test_submit_requires_authentication(client, monkeypatch):
    monkeypatch.setenv("AI_ADOPTION_API_KEYS", f"yesaican:{SERVICE_KEY}")
    r = client.post(
        "/ai-adoption/submit",
        data={"metadata": json.dumps({"name": "X", "adoption_mode": "GREENFIELD"}),
              "file": (_bundle(), "h.zip")},
        content_type="multipart/form-data",
        environ_overrides={"REMOTE_ADDR": "203.0.113.9"},
    )
    assert r.status_code == 401


def test_submit_validates_metadata(client, monkeypatch):
    monkeypatch.setenv("AI_ADOPTION_API_KEYS", f"yesaican:{SERVICE_KEY}")
    for meta in ('{"adoption_mode":"GREENFIELD"}', '{"name":"X","adoption_mode":"NOPE"}', "not-json"):
        r = client.post(
            "/ai-adoption/submit",
            data={"metadata": meta, "file": (_bundle(), "h.zip")},
            content_type="multipart/form-data",
            headers={"X-API-Key": SERVICE_KEY},
        )
        assert r.status_code == 400, meta


def test_loopback_bypass_can_be_disabled(client, monkeypatch):
    monkeypatch.setenv("AI_ADOPTION_ALLOW_LOOPBACK", "0")
    r = client.post(
        "/ai-adoption/projects",
        json={"name": "X", "adoption_mode": "GREENFIELD"},
        environ_overrides={"REMOTE_ADDR": "127.0.0.1"},
    )
    assert r.status_code == 401
