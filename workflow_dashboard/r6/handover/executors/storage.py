"""Executor: storage checks."""
import pathlib
import yaml

from .. execution_engine import register
from .. result_models import CheckStatus, make_check_result


@register("check_pvc_storage_class")
def check_pvc_storage_class(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    bd = pathlib.Path(bundle_dir) if bundle_dir else None
    if not bd:
        return make_check_result(cid, CheckStatus.FAIL, "No bundle_dir")
    kb = bd / "kustomize_bundle"
    pvcs = []
    missing_class = []
    for p in (kb if kb.is_dir() else bd).glob("*.yaml"):
        try:
            for doc in yaml.safe_load_all(p.read_text()):
                if not doc or doc.get("kind") != "PersistentVolumeClaim":
                    continue
                name = doc.get("metadata", {}).get("name", "?")
                pvcs.append(name)
                spec = doc.get("spec", {})
                sc = spec.get("storageClassName", "")
                if sc == "" or sc is None:
                    missing_class.append(name)
        except Exception:
            pass
    if not pvcs:
        return make_check_result(cid, CheckStatus.NOT_APPLICABLE, "No PVCs in bundle")
    if missing_class:
        return make_check_result(cid, CheckStatus.WARNING,
                                 f"PVCs without explicit storageClassName: {missing_class}",
                                 evidence={"pvcs": pvcs, "missing_class": missing_class})
    return make_check_result(cid, CheckStatus.PASS,
                             f"{len(pvcs)} PVC(s) all have storageClassName set")
