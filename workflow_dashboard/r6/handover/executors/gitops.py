"""Executor: GitOps and repository checks."""
import pathlib
import subprocess

from .. execution_engine import register
from .. result_models import CheckStatus, make_check_result


def _run(args, cwd=None, timeout=30):
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=timeout, cwd=cwd)
        return r.returncode, r.stdout + r.stderr
    except FileNotFoundError:
        return 1, f"{args[0]}: not found"
    except subprocess.TimeoutExpired:
        return 1, "timed out"


@register("check_gitops_access")
def check_gitops_access(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    gitops_dir = params.get("gitops_dir", "")
    if not gitops_dir:
        return make_check_result(cid, CheckStatus.WARNING,
                                 "gitops_dir not provided in params")
    gd = pathlib.Path(gitops_dir)
    if not gd.is_dir():
        return make_check_result(cid, CheckStatus.FAIL,
                                 f"GitOps directory not found: {gitops_dir}")
    rc, out = _run(["git", "status", "--short"], cwd=str(gd), timeout=10)
    if rc != 0:
        return make_check_result(cid, CheckStatus.FAIL,
                                 f"git status failed in {gitops_dir}: {out[:200]}")
    return make_check_result(cid, CheckStatus.PASS,
                             f"GitOps repo accessible at {gitops_dir}",
                             evidence={"git_status": out[:200]})


@register("check_kustomize_staging")
def check_kustomize_staging(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    bd = pathlib.Path(bundle_dir) if bundle_dir else None
    if not bd:
        return make_check_result(cid, CheckStatus.FAIL, "No bundle_dir")
    overlay = bd / "overlays" / "staging"
    if not overlay.is_dir():
        return make_check_result(cid, CheckStatus.NOT_APPLICABLE,
                                 "No overlays/staging directory in bundle")
    rc, out = _run(["kubectl", "kustomize", str(overlay)], timeout=30)
    if rc != 0:
        return make_check_result(cid, CheckStatus.FAIL,
                                 f"kustomize staging failed: {out[:400]}")
    return make_check_result(cid, CheckStatus.PASS,
                             "Staging overlay renders successfully",
                             evidence={"doc_count": out.count("kind:")})


@register("check_kustomize_production")
def check_kustomize_production(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    bd = pathlib.Path(bundle_dir) if bundle_dir else None
    if not bd:
        return make_check_result(cid, CheckStatus.FAIL, "No bundle_dir")
    overlay = bd / "overlays" / "production"
    if not overlay.is_dir():
        return make_check_result(cid, CheckStatus.NOT_APPLICABLE,
                                 "No overlays/production directory in bundle")
    rc, out = _run(["kubectl", "kustomize", str(overlay)], timeout=30)
    if rc != 0:
        return make_check_result(cid, CheckStatus.FAIL,
                                 f"kustomize production failed: {out[:400]}")
    return make_check_result(cid, CheckStatus.PASS,
                             "Production overlay renders successfully",
                             evidence={"doc_count": out.count("kind:")})


@register("check_yaml_parse_all")
def check_yaml_parse_all(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    bd = pathlib.Path(bundle_dir) if bundle_dir else None
    if not bd:
        return make_check_result(cid, CheckStatus.FAIL, "No bundle_dir")
    import yaml
    errors = []
    count = 0
    kb = bd / "kustomize_bundle"
    for p in (kb if kb.is_dir() else bd).glob("*.yaml"):
        try:
            list(yaml.safe_load_all(p.read_text()))
            count += 1
        except Exception as e:
            errors.append(f"{p.name}: {e}")
    if errors:
        return make_check_result(cid, CheckStatus.FAIL,
                                 f"{len(errors)} YAML parse error(s)",
                                 evidence={"errors": errors})
    return make_check_result(cid, CheckStatus.PASS,
                             f"All {count} YAML file(s) parse successfully")


@register("check_flux_kustomization")
def check_flux_kustomization(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    bd = pathlib.Path(bundle_dir) if bundle_dir else None
    if not bd:
        return make_check_result(cid, CheckStatus.FAIL, "No bundle_dir")
    import yaml
    flux_dir = bd / "flux"
    if not flux_dir.is_dir():
        return make_check_result(cid, CheckStatus.FAIL, "No flux/ directory in bundle")
    for p in flux_dir.glob("*.yaml"):
        try:
            doc = yaml.safe_load(p.read_text())
        except Exception:
            continue
        if not doc or doc.get("kind") != "Kustomization":
            continue
        prune = doc.get("spec", {}).get("prune", False)
        if not prune:
            return make_check_result(cid, CheckStatus.FAIL,
                                     f"Flux Kustomization {p.name} missing prune: true")
        return make_check_result(cid, CheckStatus.PASS,
                                 f"Flux Kustomization {p.name} has prune: true",
                                 evidence={"path": p.name, "prune": prune})
    return make_check_result(cid, CheckStatus.FAIL,
                             "No Flux Kustomization resource found in flux/ directory")
