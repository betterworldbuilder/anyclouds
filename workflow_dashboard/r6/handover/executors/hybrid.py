"""Executor: hybrid VM connectivity checks."""
import pathlib
import yaml

from .. execution_engine import register
from .. result_models import CheckStatus, make_check_result


@register("check_vm_bindings")
def check_vm_bindings(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    bd = pathlib.Path(bundle_dir) if bundle_dir else None
    if not bd:
        return make_check_result(cid, CheckStatus.FAIL, "No bundle_dir")
    kb = bd / "kustomize_bundle"
    bindings = []
    for p in (kb if kb.is_dir() else bd).glob("*.yaml"):
        try:
            for doc in yaml.safe_load_all(p.read_text()):
                if doc and doc.get("kind") == "VMServiceBinding":
                    bindings.append(doc.get("metadata", {}).get("name", "?"))
        except Exception:
            pass
    if not bindings:
        return make_check_result(cid, CheckStatus.WARNING,
                                 "No VMServiceBinding resources found (OK if no unresolved VMs)")
    return make_check_result(cid, CheckStatus.PASS,
                             f"{len(bindings)} VMServiceBinding(s) found",
                             evidence={"bindings": bindings})


@register("check_no_fake_ips")
def check_no_fake_ips(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    bd = pathlib.Path(bundle_dir) if bundle_dir else None
    if not bd:
        return make_check_result(cid, CheckStatus.FAIL, "No bundle_dir")
    kb = bd / "kustomize_bundle"
    import re
    fake_ip_pattern = re.compile(r'0\.0\.0\.0|255\.255\.255\.255|1\.2\.3\.4')
    violations = []
    for p in (kb if kb.is_dir() else bd).glob("*.yaml"):
        try:
            for doc in yaml.safe_load_all(p.read_text()):
                if not doc or doc.get("kind") != "EndpointSlice":
                    continue
                endpoints = doc.get("endpoints", [])
                for ep in endpoints:
                    for addr in ep.get("addresses", []):
                        if fake_ip_pattern.match(addr):
                            violations.append(
                                f"{doc.get('metadata', {}).get('name', '?')}: {addr}"
                            )
        except Exception:
            pass
    if violations:
        return make_check_result(cid, CheckStatus.FAIL,
                                 f"Fabricated IPs in EndpointSlices: {violations}")
    return make_check_result(cid, CheckStatus.PASS,
                             "No fabricated IPs found in EndpointSlices")
