"""Flask blueprint for Stage 4 AI Adoption.

Six functional endpoints, not the thirty the specification listed: most of those
operations are computed fields of a single project document rather than
independent resources.

Every mutating route is behind @require_ai_auth.
"""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
from pathlib import Path
from typing import Any, Dict

from flask import Blueprint, Response, jsonify, request
from werkzeug.utils import secure_filename

from . import assess as assess_mod
from . import auth, generate, importers, ontology, palantir, scanner
from .models import ADOPTION_MODES, SENSITIVITIES, SOURCE_TYPES, new_project, now_ms
from .store import ProjectStore

MAX_UPLOAD_BYTES = importers.MAX_ARCHIVE_BYTES


def _detect_sources(project: Dict[str, Any], root: str, src: Dict[str, Any]) -> Dict[str, Any]:
    """Identify what was imported. Shared by /import and /submit.

    Extracted because it was duplicated: a Palantir export was recognised on one
    path and silently treated as a generic bundle on the other.
    """
    manifest = importers.detect_manifest(Path(root)) if root else {"kind": "", "findings": [], "manifest": {}}
    if manifest.get("kind"):
        project["source_type"] = manifest["kind"]
        src["manifest_kind"] = manifest["kind"]
        src["manifest_findings"] = manifest["findings"]
        # Keep the manifest's evaluation and business sections: a bundle that
        # shipped an evaluation report has evidenced its value, and the scorer
        # should be able to credit that.
        declared = manifest.get("manifest") or {}
        if isinstance(declared, dict):
            src["manifest_evaluation"] = declared.get("evaluation") or {}
            src["manifest_project"] = declared.get("project") or {}

    # A Palantir export takes precedence: it changes what can actually be
    # deployed, so it must not be mistaken for a generic upload.
    pal = palantir.detect(Path(root)) if root else {"is_palantir": False}
    if pal.get("is_palantir"):
        project["source_type"] = "PALANTIR"
        project["palantir_required"] = True
        project["palantir_source"] = pal
        src["manifest_kind"] = "PALANTIR"
        src["manifest_findings"] = pal.get("findings", [])
        manifest = {"kind": "PALANTIR", "findings": pal.get("findings", []), "manifest": {}}
    return manifest


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
                    # FLEX_BUSINESS_SYSTEM belongs here too: "we migrated the
                    # Billing Platform, now build a new AI capability around its
                    # data" is a new platform seeded from a migrated app, not an
                    # augmentation of one.
                    "GREENFIELD": [
                        "FLEX_BUSINESS_SYSTEM", "OPENCENTER", "NEW_PROJECT",
                        "GITHUB", "UPLOAD", "NOTEBOOK", "LAUNCHPAD",
                    ],
                    "BROWNFIELD": ["FLEX_BUSINESS_SYSTEM", "OPENCENTER", "MANUAL", "GITHUB"],
                    "EXISTING_POC": ["AI4PEOPLE", "LAUNCHPAD", "PALANTIR", "GITHUB", "UPLOAD", "NOTEBOOK"],
                },
                "auth": {
                    "configured": auth.is_configured(),
                    "authenticated": bool(auth.current_user()),
                    "user": auth.current_user(),
                    # Never the keys themselves, only whether any are configured.
                    "service_auth_configured": auth.service_auth_configured(),
                    "service_caller": auth.service_caller(),
                },
                "submit_endpoint": "/ai-adoption/submit",
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
            "estimated_value", "readiness_evidence", "integration", "foundry_target",
            "is_demo",
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
            # Must mirror the create allow-list, or a PATCH silently drops them.
            "integration", "foundry_target", "readiness_evidence",
            "external_transfer_allowed", "data_location", "pii_present",
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
                elif kind == "OPENCENTER":
                    workload = body.get("workload") or {}
                    if not isinstance(workload, dict) or not workload:
                        return _err("workload object is required")
                    src = importers.import_opencenter_workload(workload)
                    project["source_type"] = "OPENCENTER"
                    project["business_system_id"] = str(workload.get("name") or "")
                    declared = str(workload.get("sensitivity") or "").upper()
                    if not project.get("data_sensitivity") and declared in SENSITIVITIES:
                        project["data_sensitivity"] = declared
                elif kind == "FLEX":
                    system = body.get("system") or {}
                    if not isinstance(system, dict) or not system:
                        return _err("system object is required")
                    # Cloud-native posture may be declared alongside the system,
                    # e.g. {"containerised": true, "kubernetes": true}.
                    src = importers.import_flex_system(system)
                    project["source_type"] = "FLEX_BUSINESS_SYSTEM"
                    project["business_system_id"] = str(system.get("id") or system.get("name") or "")
                    if not project.get("data_sensitivity"):
                        declared = str(system.get("sensitivity") or "").upper()
                        if declared in SENSITIVITIES:
                            project["data_sensitivity"] = declared
                else:
                    return _err("kind must be GITHUB, FLEX or OPENCENTER, or send a multipart file")

            root = src.get("root", "")
            manifest = _detect_sources(project, root, src)

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

    # ---------------------------------------------------------------- ontology
    @bp.get("/pain-categories")
    def pain_categories():
        """The A-3 pain taxonomy, so both entry points offer the same words."""
        return jsonify({"ok": True, "categories": list(ontology.PAIN_CATEGORIES)})

    @bp.post("/projects/<project_id>/ontology")
    @auth.require_ai_auth
    def set_ontology(project_id: str):
        """Declare one business system: pain, inputs, outputs, relationships.

        Returns the derived AI tools. Nothing is proposed without a declared
        pain point behind it.
        """
        project = store.load(project_id)
        if not project:
            return _err("project not found", 404)
        body = request.get_json(silent=True) or {}

        for key in ("pain_points", "inputs", "desired_outputs", "related_orgs"):
            if key in body and not isinstance(body[key], list):
                return _err(f"{key} must be a list")
        unknown = [p for p in (body.get("pain_points") or []) if p not in ontology.PAIN_CATEGORIES]
        if unknown:
            return _err(f"unknown pain categories: {unknown}", 422)

        derived = ontology.derive({
            "name": str(body.get("name") or project.get("name") or "").strip(),
            "pain_points": body.get("pain_points") or [],
            "inputs": body.get("inputs") or [],
            "desired_outputs": body.get("desired_outputs") or [],
            "related_orgs": body.get("related_orgs") or [],
        })
        project["business_ontology"] = derived
        if derived["ai_tools"] and not project.get("business_goal"):
            project["business_goal"] = derived["ai_tools"][0]["capability"]
        store.audit(project, "project.ontology", _actor(),
                    pains=len(derived["ontology"]["properties"]["pain_points"]),
                    tools=len(derived["ai_tools"]))
        store.save(project)
        return jsonify({"ok": True, "ontology": derived})

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

        # The recommendation carries the service ladder, which decides whether
        # this lands on OpenCenter or Spot's own Kubernetes.
        result_with_stack = dict(result)
        result_with_stack["service_stack"] = (project.get("recommendation") or {}).get("service_stack")
        project["deployment_plan"] = generate.build_architecture(project, scan, result_with_stack)
        project["palantir_mapping"] = generate.build_palantir_mapping(project, scan)
        if project.get("palantir_required") or project.get("palantir_source"):
            # How Foundry would actually reach a FLEX-hosted workload.
            project["palantir_connection"] = palantir.connection_kit(
                project, scan, project.get("palantir_source") or {}
            )
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

    # ---------------------------------------------------------------- submit
    @bp.post("/submit")
    @auth.require_ai_auth
    def submit_bundle():
        """One-shot intake for YES AI CAN and AI 4 the People.

        Create → import → assess → plan in a single call, so a sending platform
        does not have to orchestrate four round trips and handle partial
        failure between them.

        Idempotent on `global_ai_project_id` + package checksum: re-sending the
        same bundle returns the existing project instead of creating a duplicate.
        """
        upload = request.files.get("file")
        if upload is None or not upload.filename:
            return _err("a bundle file is required (multipart field 'file')")

        meta_raw = request.form.get("metadata") or "{}"
        try:
            meta = json.loads(meta_raw)
            if not isinstance(meta, dict):
                raise ValueError
        except Exception:
            return _err("metadata must be a JSON object")

        name = str(meta.get("name") or "").strip()
        mode = str(meta.get("adoption_mode") or "").strip().upper()
        if not name:
            return _err("metadata.name is required")
        if mode not in ADOPTION_MODES:
            return _err(f"metadata.adoption_mode must be one of {list(ADOPTION_MODES)}")
        sens = str(meta.get("data_sensitivity") or "").upper()
        if sens and sens not in SENSITIVITIES:
            return _err(f"data_sensitivity must be one of {list(SENSITIVITIES)}")

        gid = str(meta.get("global_ai_project_id") or "").strip()
        actor = _actor()

        filename = secure_filename(upload.filename)
        if not filename:
            return _err("invalid filename")

        workspace = Path(tempfile.mkdtemp(prefix="aiadopt-sub-"))
        try:
            staged = workspace / filename
            upload.save(str(staged))
            size = staged.stat().st_size
            if size > MAX_UPLOAD_BYTES:
                return _err(f"bundle exceeds {MAX_UPLOAD_BYTES} bytes", 413)
            checksum = hashlib.sha256(staged.read_bytes()).hexdigest()

            # Idempotency: the same bundle from the same project is not a new one.
            if gid:
                for row in store.list():
                    existing = store.load(row["id"])
                    if not existing:
                        continue
                    if (
                        existing.get("sender_project_id") == gid
                        and existing.get("sender_package_checksum") == checksum
                    ):
                        return jsonify({
                            "ok": True, "duplicate": True, "project_id": existing["id"],
                            "status": existing["status"],
                            "readiness_score": existing.get("readiness_score"),
                            "message": "identical bundle already submitted",
                        })

            project = new_project(
                name=name,
                adoption_mode=mode,
                source_type="AI4PEOPLE",
                customer_id=str(meta.get("customer_id") or ""),
                business_owner=str(meta.get("business_owner") or ""),
                technical_owner=str(meta.get("technical_owner") or ""),
                data_owner=str(meta.get("data_owner") or ""),
                production_owner=str(meta.get("production_owner") or ""),
                business_goal=str(meta.get("business_goal") or ""),
                data_sensitivity=sens,
                palantir_required=bool(meta.get("palantir_required")),
            )
            # Provenance: who sent it, under which identity, and what it hashed to.
            project["sender"] = actor
            project["sender_project_id"] = gid
            project["sender_package_checksum"] = checksum

            src = importers.import_upload(staged, workspace, display_name=name)
            root = src.get("root", "")
            manifest = _detect_sources(project, root, src)

            scan = scanner.scan_project(root) if root else scanner.scan_project("")
            project["import_source"] = {k: v for k, v in src.items() if k != "root"}
            project["source_reference"] = src.get("source_uri", "")
            project["scan_result"] = scan
            project["components"] = scan.get("components", [])
            project["status"] = "IMPORTED"
            project["imported_at"] = now_ms()

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

            # The recommendation carries the service ladder, which decides
            # whether this lands on OpenCenter or Spot's own Kubernetes.
            result_with_stack = dict(result)
            result_with_stack["service_stack"] = rec.get("service_stack")
            project["deployment_plan"] = generate.build_architecture(project, scan, result_with_stack)
            project["palantir_mapping"] = generate.build_palantir_mapping(project, scan)
            if project.get("palantir_required") or project.get("palantir_source"):
                # How Foundry would actually reach a FLEX-hosted workload.
                project["palantir_connection"] = palantir.connection_kit(
                    project, scan, project.get("palantir_source") or {}
                )
            project["passport"] = generate.build_passport(project, scan, result, kind="AGENT")
            project["journey"] = generate.build_journey(project, result)
            project["status"] = "PLANNED"
            project["planned_at"] = now_ms()
            project["time_to_plan_ms"] = project["planned_at"] - project["imported_at"]

            store.audit(
                project, "project.submit", actor,
                sender_project_id=gid, checksum=checksum, bytes=size,
                manifest_kind=manifest.get("kind"), findings=len(manifest.get("findings") or []),
            )
            store.save(project)

            return jsonify({
                "ok": True,
                "duplicate": False,
                "project_id": project["id"],
                "global_ai_project_id": gid,
                "status": project["status"],
                "manifest_kind": manifest.get("kind") or None,
                "manifest_findings": manifest.get("findings") or [],
                "readiness_score": result["readiness_score"],
                "verdict": result["verdict"],
                "confidence": result["confidence"],
                "production_gaps": len(result["gaps"]),
                "critical_gaps": [g["title"] for g in result["gaps"] if g["severity"] == "CRITICAL"],
                "recommended_entry": rec["recommended_entry"],
                "palantir_fit": rec["palantir_fit"],
                "time_to_plan_ms": project["time_to_plan_ms"],
            }), 201

        except importers.ImportError_ as exc:
            return _err(str(exc), 422)
        except Exception as exc:  # noqa: BLE001
            return _err(f"submission failed: {type(exc).__name__}", 500)
        finally:
            importers.cleanup(workspace)

    # ---------------------------------------------------------------- export
    @bp.get("/projects/<project_id>/export")
    def export(project_id: str):
        project = store.load(project_id)
        if not project:
            return _err("project not found", 404)
        fmt = (request.args.get("format") or "json").lower()
        name = (project.get("name") or "project").replace(" ", "_")[:60]

        if fmt == "zip":
            # The whole handoff pack: one archive a delivery team can act on.
            pack = generate.build_handoff_pack(project)
            store.audit(project, "project.export", _actor(), format="zip", checksum=pack["checksum"])
            store.save(project)
            return Response(
                pack["bytes"],
                mimetype="application/zip",
                headers={"Content-Disposition": f'attachment; filename="{pack["filename"]}"'},
            )

        if fmt == "markdown" or fmt == "md":
            body, mime, ext = generate.report_markdown(project), "text/markdown", "md"
        elif fmt == "csv":
            body, mime, ext = generate.report_csv(project), "text/csv", "csv"
        elif fmt == "json":
            body, mime, ext = generate.report_json(project), "application/json", "json"
        else:
            return _err("format must be json, csv, markdown or zip")

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
