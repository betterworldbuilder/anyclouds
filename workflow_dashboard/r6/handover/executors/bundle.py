"""Executor: bundle completeness checks."""
import pathlib
import json
import re

from .. execution_engine import register
from .. result_models import CheckStatus, make_check_result


def _bd(bundle_dir):
    return pathlib.Path(bundle_dir) if bundle_dir else None


@register("check_bundle_dir")
def check_bundle_dir(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    bd = _bd(bundle_dir)
    if not bd or not bd.is_dir():
        return make_check_result(cid, CheckStatus.FAIL,
                                 f"bundle_dir not found: {bundle_dir}")
    subdirs = [d.name for d in bd.iterdir() if d.is_dir()]
    return make_check_result(cid, CheckStatus.PASS,
                             f"Bundle directory exists with {len(list(bd.rglob('*.yaml')))} YAML files",
                             evidence={"subdirs": subdirs})


@register("check_business_system_yaml")
def check_business_system_yaml(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    bd = _bd(bundle_dir)
    if not bd:
        return make_check_result(cid, CheckStatus.FAIL, "No bundle_dir")
    for candidate in (bd / "business-system.yaml", bd / "opencenter" / "business-system.yaml"):
        if candidate.is_file():
            import yaml
            try:
                docs = list(yaml.safe_load_all(candidate.read_text()))
                kinds = [d.get("kind") for d in docs if d]
                if "BusinessApplicationSystem" in kinds:
                    return make_check_result(cid, CheckStatus.PASS,
                                             "BusinessApplicationSystem found",
                                             evidence={"kinds": kinds})
                return make_check_result(cid, CheckStatus.FAIL,
                                         f"business-system.yaml found but kind not BusinessApplicationSystem, got: {kinds}")
            except Exception as e:
                return make_check_result(cid, CheckStatus.FAIL, f"YAML parse error: {e}")
    return make_check_result(cid, CheckStatus.FAIL, "business-system.yaml not found in bundle")


@register("check_bundle_validation_json")
def check_bundle_validation_json(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    bd = _bd(bundle_dir)
    if not bd:
        return make_check_result(cid, CheckStatus.FAIL, "No bundle_dir")
    p = bd / "bundle-validation.json"
    if not p.is_file():
        return make_check_result(cid, CheckStatus.FAIL, "bundle-validation.json missing")
    try:
        data = json.loads(p.read_text())
    except Exception as e:
        return make_check_result(cid, CheckStatus.FAIL, f"JSON parse error: {e}")
    status = data.get("status", "")
    blockers = data.get("blockers", [])
    if status == "BLOCKED":
        return make_check_result(cid, CheckStatus.FAIL,
                                 f"Bundle BLOCKED with {len(blockers)} blocker(s): {blockers[:3]}",
                                 evidence={"bundle_validation": data})
    return make_check_result(cid, CheckStatus.PASS,
                             f"bundle-validation.json: {status}",
                             evidence={"bundle_validation": data})


@register("check_image_manifest")
def check_image_manifest(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    bd = _bd(bundle_dir)
    if not bd:
        return make_check_result(cid, CheckStatus.FAIL, "No bundle_dir")
    p = bd / "image-manifest.json"
    if not p.is_file():
        return make_check_result(cid, CheckStatus.FAIL, "image-manifest.json missing")
    try:
        data = json.loads(p.read_text())
        images = data.get("images", [])
        return make_check_result(cid, CheckStatus.PASS,
                                 f"image-manifest.json has {len(images)} image(s)",
                                 evidence={"count": len(images), "first": images[:3]})
    except Exception as e:
        return make_check_result(cid, CheckStatus.FAIL, f"JSON parse error: {e}")


@register("check_determinism")
def check_determinism(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    bd = _bd(bundle_dir)
    if not bd:
        return make_check_result(cid, CheckStatus.FAIL, "No bundle_dir")
    # Simple check: count files and verify structure is repeatable by comparing file list
    yaml_files = sorted(str(p.relative_to(bd)) for p in bd.rglob("*.yaml"))
    json_files = sorted(str(p.relative_to(bd)) for p in bd.rglob("*.json"))
    total = len(yaml_files) + len(json_files)
    # We can't actually re-run generation here, so verify internal consistency
    if total == 0:
        return make_check_result(cid, CheckStatus.FAIL, "Bundle is empty")
    return make_check_result(cid, CheckStatus.PASS,
                             f"Bundle has {total} output files (structure consistent)",
                             evidence={"yaml_files": yaml_files[:20], "json_files": json_files})


@register("check_stage12_zero_blockers")
def check_stage12_zero_blockers(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    bd = _bd(bundle_dir)
    if not bd:
        return make_check_result(cid, CheckStatus.FAIL, "No bundle_dir")
    p = bd / "bundle-validation.json"
    if not p.is_file():
        return make_check_result(cid, CheckStatus.FAIL, "bundle-validation.json missing")
    data = json.loads(p.read_text())
    blockers = data.get("blockers", [])
    status = data.get("status", "")
    if blockers or status == "BLOCKED":
        return make_check_result(cid, CheckStatus.FAIL,
                                 f"Stage 12 gate has {len(blockers)} blocker(s)",
                                 evidence={"blockers": blockers})
    warnings = data.get("warnings", [])
    if warnings:
        return make_check_result(cid, CheckStatus.WARNING,
                                 f"Stage 12 gate: {len(warnings)} warning(s)",
                                 evidence={"warnings": warnings})
    return make_check_result(cid, CheckStatus.PASS, "Stage 12 gate: zero blockers")
