"""Executor: networking and gateway checks."""
import pathlib
import yaml

from .. execution_engine import register
from .. result_models import CheckStatus, make_check_result


@register("check_network_policies")
def check_network_policies(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    bd = pathlib.Path(bundle_dir) if bundle_dir else None
    if not bd:
        return make_check_result(cid, CheckStatus.FAIL, "No bundle_dir")
    kb = bd / "kustomize_bundle"
    deny_ingress = False
    deny_egress = False
    for p in (kb if kb.is_dir() else bd).glob("*.yaml"):
        try:
            for doc in yaml.safe_load_all(p.read_text()):
                if not doc or doc.get("kind") != "NetworkPolicy":
                    continue
                ps = doc.get("spec", {}).get("podSelector", {})
                pol_types = doc.get("spec", {}).get("policyTypes", [])
                if ps == {} or ps is None:
                    if "Ingress" in pol_types and not doc.get("spec", {}).get("ingress"):
                        deny_ingress = True
                    if "Egress" in pol_types and not doc.get("spec", {}).get("egress"):
                        deny_egress = True
        except Exception:
            pass
    missing = []
    if not deny_ingress:
        missing.append("default-deny-ingress")
    if not deny_egress:
        missing.append("default-deny-egress")
    if missing:
        return make_check_result(cid, CheckStatus.FAIL,
                                 f"Default-deny NetworkPolicies missing: {missing}")
    return make_check_result(cid, CheckStatus.PASS,
                             "Default-deny ingress and egress NetworkPolicies present")


@register("check_certificate_renew")
def check_certificate_renew(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    bd = pathlib.Path(bundle_dir) if bundle_dir else None
    if not bd:
        return make_check_result(cid, CheckStatus.FAIL, "No bundle_dir")
    kb = bd / "kustomize_bundle"
    certs = []
    missing_renew = []
    for p in (kb if kb.is_dir() else bd).glob("*.yaml"):
        try:
            for doc in yaml.safe_load_all(p.read_text()):
                if not doc or doc.get("kind") != "Certificate":
                    continue
                name = doc.get("metadata", {}).get("name", "?")
                certs.append(name)
                renew = doc.get("spec", {}).get("renewBefore", "")
                if not renew:
                    missing_renew.append(name)
        except Exception:
            pass
    if not certs:
        return make_check_result(cid, CheckStatus.NOT_APPLICABLE, "No Certificate resources in bundle")
    if missing_renew:
        return make_check_result(cid, CheckStatus.FAIL,
                                 f"Certificates without renewBefore: {missing_renew}")
    return make_check_result(cid, CheckStatus.PASS,
                             f"{len(certs)} Certificate(s) all have renewBefore set")
