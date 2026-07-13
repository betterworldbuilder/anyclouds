"""Executor: validation-operations checks."""
import pathlib
import subprocess
import yaml

from .. execution_engine import register
from .. result_models import CheckStatus, make_check_result


def _run(args, timeout=20):
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout + r.stderr
    except FileNotFoundError:
        return 1, f"{args[0]}: not found"
    except subprocess.TimeoutExpired:
        return 1, "timed out"


@register("check_validation_jobs_exist")
def check_validation_jobs_exist(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    bd = pathlib.Path(bundle_dir) if bundle_dir else None
    if not bd:
        return make_check_result(cid, CheckStatus.FAIL, "No bundle_dir")
    kb = bd / "kustomize_bundle"
    vj = kb / "validation-jobs.yaml"
    if not vj.is_file():
        return make_check_result(cid, CheckStatus.FAIL, "validation-jobs.yaml not found")
    try:
        docs = [d for d in yaml.safe_load_all(vj.read_text()) if d and d.get("kind") == "Job"]
    except Exception as e:
        return make_check_result(cid, CheckStatus.FAIL, f"YAML parse error: {e}")
    if not docs:
        return make_check_result(cid, CheckStatus.FAIL, "validation-jobs.yaml has no Job documents")
    names = [d.get("metadata", {}).get("name", "?") for d in docs]
    return make_check_result(cid, CheckStatus.PASS,
                             f"{len(docs)} validation Job(s) present: {names}",
                             evidence={"jobs": names})


@register("check_stage13_endpoint")
def check_stage13_endpoint(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    url = params.get("dashboard_url", "http://localhost:5001")
    rc, out = _run(
        ["curl", "-sSo", "/dev/null", "-w", "%{http_code}",
         "-X", "POST", f"{url}/api/r6/run-validation", "-H", "Content-Type: application/json",
         "-d", "{}"],
        timeout=15,
    )
    code = out.strip()
    if code in ("400", "422"):
        return make_check_result(cid, CheckStatus.PASS,
                                 f"Stage 13 endpoint exists (HTTP {code} on empty body)")
    if code == "404":
        return make_check_result(cid, CheckStatus.FAIL,
                                 "Stage 13 endpoint not registered (HTTP 404)")
    return make_check_result(cid, CheckStatus.WARNING,
                             f"Stage 13 endpoint returned HTTP {code}")
