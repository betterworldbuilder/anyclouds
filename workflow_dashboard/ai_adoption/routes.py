"""Flask blueprint for Stage 9 AI Adoption.

Six functional endpoints, not the thirty the specification listed: most of those
operations are computed fields of a single project document rather than
independent resources.

Every mutating route is behind @require_ai_auth.
"""

from __future__ import annotations

import os
import tempfile
from pathlib import Path
from typing import Any, Dict

from flask import Blueprint, Response, jsonify, request
from werkzeug.utils import secure_filename

from . import assess as assess_mod
from . import auth, generate, importers, scanner
from .models import ADOPTION_MODES, SENSITIVITIES, SOURCE_TYPES, new_project, now_ms
from .store import ProjectStore

MAX_UPLOAD_BYTES = importers.MAX_ARCHIVE_BYTES


def _err(msg: str, code: int = 400, **extra: Any):
    payload = {"ok": False, "error": msg}
    payload.update(extra)
    return jsonify(payload), code


def create_ai_adoption_blueprint(base_dir: Path) -> Blueprint:
    bp = Blueprint("ai_adoption", __name__, url_prefix="/ai-adoption")
    store = ProjectStore(base_dir)

    # ---------------------------------------------------------------- auth
    bp.add_url_rule("/auth/login", view_func=auth.login_start, methods=["GET"])
    bp.add_url_rule("/auth/callback", view_func=auth.login_callback, methods=["GET"])
    bp.add_url_rule("/auth/logout", view_func=auth.logout, methods=["POST", "GET"])
    bp.add_url_rule("/auth/me", view_func=auth.whoami, methods=["GET"])

    # ---------------------------------------------------------------- meta
    @bp.get("/meta")
    def meta():
        """Everything the UI needs to render the mode and source selectors."""
        return jsonify(
            {
                "ok": True,
                "adoption_modes": list(ADOPTION_MODES),
                "source_types": list(SOURCE_TYPES),
                "sensitivities": list(SENSITIVITIES),
                "sources_by_mode": {
                    "GREENFIELD": ["NEW_PROJECT", "GITHUB", "UPLOAD", "NOTEBOOK", "LAUNCHPAD", "AI4PEOPLE"],
                    "BROWNFIELD": ["FLEX_BUSINESS_SYSTEM", "MANUAL", "GITHUB"],
                    "EXISTING_POC": ["GITHUB", "UPLOAD", "NOTEBOOK", "LAUNCHPAD", "AI4PEOPLE"],
                },
                "auth": {
                    "configured": auth.is_configured(),
                    "authenticated": bool(auth.current_user()),
                    "user": auth.current_user(),
                },
            }
        )

    # ---------------------------------------------------------------- projects
    @bp.get("/projects")
    def list_projects():
        return jsonify({"ok": True, "projects": store.list(request.args.get("customer_id", ""))})

    @bp.post("/projects")
    @auth.require_ai_auth
    def create_project():
        body = request.get_json(silent=True) or {}
        name = str(body.get("name") or "").strip()
        mode = str(body.get("adoption_mode") or "").strip().upper()
        if not name:
            return _err("name is required")
        if mode not in ADOPTION_MODES:
            return _err(f"adoption_mode must be one of {list(ADOPTION_MODES)}")
        source_type = str(body.get("source_type") or "NEW_PROJECT").strip().upper()
        if source_type not in SOURCE_TYPES:
            return _err(f"source_type must be one of {list(SOURCE_TYPES)}")

        allowed = {
            "description", "customer_id", "business_owner", "technical_owner", "data_owner",
            "production_owner", "business_goal", "data_sensitivity", "preferred_environment",
            "sovereignty_requirements", "palantir_required", "department_id", "business_system_id",
            "estimated_value", "readiness_evidence",
        }
        overrides = {k: v for k, v in body.items() if k in allowed}
        ev = overrides.get("readiness_evidence")
        if ev is not None and not isinstance(ev, dict):
            return _err("readiness_evidence must be an object")
        sens = str(overrides.get("data_sensitivity") or "").upper()
        if sens and sens not in SENSITIVITIES:
            return _err(f"data_sensitivity must be one of {list(SENSITIVITIES)}")
        if sens:
            overrides["data_sensitivity"] = sens

        project = new_project(name=name, adoption_mode=mode, source_type=source_type, **overrides)
        store.audit(project, "project.create", _actor(), name=name, mode=mode)
        store.save(project)
        return jsonify({"ok": True, "project": project}), 201

    @bp.get("/projects/<project_id>")
    def get_project(project_id: str):
        project = store.load(project_id)
        if not project:
            return _err("project not found", 404)
        return jsonify({"ok": True, "project": project})

    @bp.patch("/projects/<project_id>")
    @auth.require_ai_auth
    def patch_project(project_id: str):
        project = store.load(project_id)
        if not project:
            return _err("project not found", 404)
        body = request.get_json(silent=True) or {}
        editable = {
            "name", "description", "business_owner", "technical_owner", "data_owner",
            "production_owner", "business_goal", "data_sensitivity", "sovereignty_requirements",
            "palantir_required", "estimated_value", "governance", "customer_id",
        }
        for key, value in body.items():
            if key in editable:
                if key == "data_sensitivity":
                    value = str(value or "").upper()
                    if value and value not in SENSITIVITIES:
                        return _err(f"data_sensitivity must be one of {list(SENSITIVITIES)}")
                project[key] = value
        store.audit(project, "project.update", _actor(), fields=sorted(set(body) & editable))
        store.save(project)
        return jsonify({"ok": True, "project": project})

    @bp.delete("/projects/<project_id>")
    @auth.require_ai_auth
    def delete_project(project_id: str):
        return jsonify({"ok": store.delete(project_id)})

    # ---------------------------------------------------------------- import
    @bp.post("/projects/<project_id>/import")
    @auth.require_ai_auth
    def import_source(project_id: str):
        project = store.load(project_id)
        if not project:
            return _err("project not found", 404)

        workspace = Path(tempfile.mkdtemp(prefix="aiadopt-"))
        try:
            # multipart => upload; JSON => github or flex
            if request.files:
                upload = request.files.get("file")
                if upload is None or not upload.filename:
                    return _err("no file provided")
                filename = secure_filename(upload.filename)
                if not filename:
                    return _err("invalid filename")
                staged = workspace / filename
                upload.save(str(staged))
                if staged.stat().st_size > MAX_UPLOAD_BYTES:
                    return _err(f"upload exceeds {MAX_UPLOAD_BYTES} bytes", 413)
                src = importers.import_upload(staged, workspace, display_name=project.get("name", ""))
                project["source_type"] = "NOTEBOOK" if filename.lower().endswith(".ipynb") else "UPLOAD"
            else:
                body = request.get_json(silent=True) or {}
                kind = str(body.get("kind") or "").upper()
                if kind == "GITHUB":
                    repo = str(body.get("repo_url") or "").strip()
                    if not repo:
                        return _err("repo_url is required")
                    src = importers.import_github(
                        repo_url=repo,
                        workspace=workspace,
                        branch=str(body.get("branch") or "").strip(),
                        commit=str(body.get("commit") or "").strip(),
                        subdir=str(body.get("subdir") or "").strip(),
                        # A credential *reference* (env var name), never a token.
                        credential_reference=str(body.get("credential_reference") or "").strip(),
                    )
                    project["source_type"] = "GITHUB"
                elif kind == "FLEX":
                    system = body.get("system") or {}
                    if not isinstance(system, dict) or not system:
                        return _err("system object is required")
                    src = importers.import_flex_system(system)
                    project["source_type"] = "FLEX_BUSINESS_SYSTEM"
                    project["business_system_id"] = str(system.get("id") or system.get("name") or "")
                    if not project.get("data_sensitivity"):
                        declared = str(system.get("sensitivity") or "").upper()
                        if declared in SENSITIVITIES:
                            project["data_sensitivity"] = declared
                else:
                    return _err("kind must be GITHUB or FLEX, or send a multipart file")

            root = src.get("root", "")
            manifest = importers.detect_manifest(Path(root)) if root else {"kind": "", "findings": [], "manifest": {}}
            if manifest.get("kind"):
                project["source_type"] = manifest["kind"]
                src["manifest_kind"] = manifest["kind"]
                src["manifest_findings"] = manifest["findings"]

            # Scan while the workspace still exists — it is deleted in `finally`.
            scan = scanner.scan_project(root) if root else scanner.scan_project("")

            project["import_source"] = {k: v for k, v in src.items() if k != "root"}
            project["source_reference"] = src.get("source_uri", "")
            project["source_branch"] = src.get("branch", "")
            project["source_commit"] = src.get("commit_sha", "")
            project["scan_result"] = scan
            project["components"] = scan.get("components", [])
            project["status"] = "IMPORTED"
            project["imported_at"] = now_ms()
            project["artifacts"] = [
                a for a in project.get("artifacts", []) if a.get("artifact_type") not in ("SOURCE", "SCAN")
            ] + [
                {"artifact_type": "SOURCE", "filename": src.get("display_name", ""), "version": src.get("commit_sha", ""), "created_at": now_ms()},
                {"artifact_type": "SCAN", "filename": "scan_result.json", "created_at": now_ms()},
            ]
            store.audit(
                project, "project.import", _actor(),
                provider=src.get("provider"), uri=src.get("source_uri"),
                commit=src.get("commit_sha"), files=scan.get("file_count"),
            )
            store.save(project)
            return jsonify({"ok": True, "project": project, "manifest": manifest})

        except importers.ImportError_ as exc:
            project["status"] = "DRAFT"
            store.audit(project, "project.import_failed", _actor(), reason=str(exc)[:300])
            store.save(project)
            return _err(str(exc), 422)
        except Exception as exc:  # noqa: BLE001 - surface, never leak internals
            store.audit(project, "project.import_failed", _actor(), reason=type(exc).__name__)
            store.save(project)
            return _err(f"import failed: {type(exc).__name__}", 500)
        finally:
            # Always removed, success or failure — untrusted content must not
            # outlive the request that fetched it.
            importers.cleanup(workspace)

    # ---------------------------------------------------------------- assess
    @bp.post("/projects/<project_id>/assess")
    @auth.require_ai_auth
    def run_assessment(project_id: str):
        project = store.load(project_id)
        if not project:
            return _err("project not found", 404)
        scan = project.get("scan_result") or {}
        result = assess_mod.assess(project, scan)
        rec = assess_mod.recommend(project, result, scan)

        project["assessment_result"] = result
        project["recommendation"] = rec
        project["gaps"] = result["gaps"]
        project["readiness_score"] = result["readiness_score"]
        project["category_scores"] = result["category_scores"]
        project["production_gap_count"] = len(result["gaps"])
        project["recommended_rackspace_service"] = rec["recommended_entry"]
        project["target_platform"] = rec["target_platform"]
        if project.get("status") in ("DRAFT", "IMPORTED"):
            project["status"] = "ASSESSED"
        store.audit(project, "project.assess", _actor(), score=result["readiness_score"], gaps=len(result["gaps"]))
        store.save(project)
        return jsonify({"ok": True, "project": project})

    # ---------------------------------------------------------------- plan
    @bp.post("/projects/<project_id>/plan")
    @auth.require_ai_auth
    def build_plan(project_id: str):
        project = store.load(project_id)
        if not project:
            return _err("project not found", 404)
        scan = project.get("scan_result") or {}
        result = project.get("assessment_result")
        if not result:
            # Planning without an assessment would produce a plan with nothing
            # behind it; run one rather than fail.
            result = assess_mod.assess(project, scan)
            project["assessment_result"] = result
            project["recommendation"] = assess_mod.recommend(project, result, scan)
            project["gaps"] = result["gaps"]
            project["readiness_score"] = result["readiness_score"]
            project["production_gap_count"] = len(result["gaps"])

        project["deployment_plan"] = generate.build_architecture(project, scan, result)
        project["palantir_mapping"] = generate.build_palantir_mapping(project, scan)
        project["passport"] = generate.build_passport(
            project, scan, result,
            kind={"GREENFIELD": "AGENT", "BROWNFIELD": "APPLICATION", "EXISTING_POC": "POC"}.get(
                project.get("adoption_mode"), "POC"),
        )
        project["journey"] = generate.build_journey(project, result)
        project["status"] = "PLANNED"
        project["planned_at"] = now_ms()
        if project.get("imported_at"):
            # The stated objective is "first AI product in record time"; this is
            # the only number that measures it.
            project["time_to_plan_ms"] = project["planned_at"] - project["imported_at"]
        project["artifacts"] = [
            a for a in project.get("artifacts", []) if a.get("artifact_type") not in ("PLAN", "ARCHITECTURE", "PASSPORT")
        ] + [
            {"artifact_type": "PLAN", "filename": "plan.json", "created_at": now_ms()},
            {"artifact_type": "ARCHITECTURE", "filename": "architecture.json", "created_at": now_ms()},
            {"artifact_type": "PASSPORT", "filename": "passport.json", "created_at": now_ms()},
        ]
        store.audit(project, "project.plan", _actor(), time_to_plan_ms=project.get("time_to_plan_ms"))
        store.save(project)
        return jsonify({"ok": True, "project": project})

    # ---------------------------------------------------------------- export
    @bp.get("/projects/<project_id>/export")
    def export(project_id: str):
        project = store.load(project_id)
        if not project:
            return _err("project not found", 404)
        fmt = (request.args.get("format") or "json").lower()
        name = (project.get("name") or "project").replace(" ", "_")[:60]

        if fmt == "markdown" or fmt == "md":
            body, mime, ext = generate.report_markdown(project), "text/markdown", "md"
        elif fmt == "csv":
            body, mime, ext = generate.report_csv(project), "text/csv", "csv"
        elif fmt == "json":
            body, mime, ext = generate.report_json(project), "application/json", "json"
        else:
            return _err("format must be json, csv or markdown")

        # Export is a read, so it is not auth-gated; it is still audited.
        store.audit(project, "project.export", _actor(), format=fmt)
        store.save(project)
        return Response(
            body,
            mimetype=mime,
            headers={"Content-Disposition": f'attachment; filename="{name}_ai_adoption.{ext}"'},
        )

    return bp


def _actor() -> str:
    user = auth.current_user()
    if user:
        return str(user.get("login") or "unknown")
    return "loopback"
