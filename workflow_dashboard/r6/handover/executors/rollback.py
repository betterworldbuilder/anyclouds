"""Executor: rollback runbook checks."""
import pathlib
import yaml

from .. execution_engine import register
from .. result_models import CheckStatus, make_check_result

_REQUIRED_SECTIONS = ["gitRevision", "images", "traffic", "vmWorkloads", "dataLimitations", "verificationSteps"]


@register("check_rollback_runbook")
def check_rollback_runbook(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    bd = pathlib.Path(bundle_dir) if bundle_dir else None
    if not bd:
        return make_check_result(cid, CheckStatus.FAIL, "No bundle_dir")
    ops = bd / "operations"
    rr = ops / "rollback-runbook.yaml"
    if not rr.is_file():
        return make_check_result(cid, CheckStatus.FAIL, "operations/rollback-runbook.yaml not found")
    try:
        doc = yaml.safe_load(rr.read_text())
    except Exception as e:
        return make_check_result(cid, CheckStatus.FAIL, f"YAML parse error: {e}")
    if not doc:
        return make_check_result(cid, CheckStatus.FAIL, "rollback-runbook.yaml is empty")
    spec = doc.get("spec", {})
    missing = [s for s in _REQUIRED_SECTIONS if s not in spec]
    if missing:
        return make_check_result(cid, CheckStatus.FAIL,
                                 f"Rollback runbook missing sections: {missing}",
                                 evidence={"present": list(spec.keys()), "missing": missing})
    return make_check_result(cid, CheckStatus.PASS,
                             "Rollback runbook complete with all required sections",
                             evidence={"kind": doc.get("kind"),
                                       "name": doc.get("metadata", {}).get("name")})
