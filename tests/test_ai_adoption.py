"""Tests for Stage 9 — AI Adoption & Production Factory."""

import io
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
    # Low confidence must force manual review rather than a verdict.
    assert result["verdict"] == "MANUAL_REVIEW"


def test_secret_finding_produces_critical_gap(sample_project):
    project = models.new_project("P", "EXISTING_POC", data_sensitivity="LOW")
    result = assess.assess(project, scanner.scan_project(str(sample_project)))
    criticals = [g for g in result["gaps"] if g["severity"] == "CRITICAL"]
    assert any("secret" in g["title"].lower() for g in criticals)
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


def test_regulated_data_routes_to_private_cloud(sample_project):
    project = models.new_project("P", "GREENFIELD", data_sensitivity="REGULATED")
    scan = scanner.scan_project(str(sample_project))
    rec = assess.recommend(project, assess.assess(project, scan), scan)
    assert rec["recommended_entry"] == "Private Cloud AI / AI Anywhere"
    assert rec["palantir_fit"] == "Required"


# ------------------------------------------------------------------ generators


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


def test_loopback_bypass_can_be_disabled(client, monkeypatch):
    monkeypatch.setenv("AI_ADOPTION_ALLOW_LOOPBACK", "0")
    r = client.post(
        "/ai-adoption/projects",
        json={"name": "X", "adoption_mode": "GREENFIELD"},
        environ_overrides={"REMOTE_ADDR": "127.0.0.1"},
    )
    assert r.status_code == 401
