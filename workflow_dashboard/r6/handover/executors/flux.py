"""Executor: Flux and observability checks."""
import pathlib
import yaml

from .. execution_engine import register
from .. result_models import CheckStatus, make_check_result


@register("check_service_monitors")
def check_service_monitors(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    bd = pathlib.Path(bundle_dir) if bundle_dir else None
    if not bd:
        return make_check_result(cid, CheckStatus.FAIL, "No bundle_dir")
    kb = bd / "kustomize_bundle"
    obs = kb / "observability.yaml"
    if not obs.is_file():
        return make_check_result(cid, CheckStatus.NOT_APPLICABLE,
                                 "observability.yaml not generated (prometheus-operator absent)")
    try:
        docs = [d for d in yaml.safe_load_all(obs.read_text()) if d and d.get("kind") == "ServiceMonitor"]
    except Exception as e:
        return make_check_result(cid, CheckStatus.FAIL, f"YAML parse error: {e}")
    if not docs:
        return make_check_result(cid, CheckStatus.FAIL,
                                 "observability.yaml has no ServiceMonitor resources")
    names = [d.get("metadata", {}).get("name", "?") for d in docs]
    return make_check_result(cid, CheckStatus.PASS,
                             f"{len(docs)} ServiceMonitor(s) found",
                             evidence={"monitors": names})


@register("check_velero_schedule")
def check_velero_schedule(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    bd = pathlib.Path(bundle_dir) if bundle_dir else None
    if not bd:
        return make_check_result(cid, CheckStatus.FAIL, "No bundle_dir")
    kb = bd / "kustomize_bundle"
    vs = kb / "velero-schedule.yaml"
    if not vs.is_file():
        return make_check_result(cid, CheckStatus.NOT_APPLICABLE,
                                 "velero-schedule.yaml not generated (velero absent or no PVCs)")
    try:
        doc = yaml.safe_load(vs.read_text())
    except Exception as e:
        return make_check_result(cid, CheckStatus.FAIL, f"YAML parse error: {e}")
    if not doc or doc.get("kind") != "Schedule":
        return make_check_result(cid, CheckStatus.FAIL, "velero-schedule.yaml has no Schedule resource")
    sched = doc.get("spec", {}).get("schedule", "")
    return make_check_result(cid, CheckStatus.PASS,
                             f"Velero Schedule present: {sched}",
                             evidence={"schedule": sched})
