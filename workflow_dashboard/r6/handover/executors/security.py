"""Executor: security and secret scan checks."""
import pathlib
import re

from .. execution_engine import register
from .. result_models import CheckStatus, make_check_result

_CRED_PATTERNS = [
    re.compile(r'password\s*[:=]\s*["\']?[A-Za-z0-9+/]{6,}', re.I),
    re.compile(r'(token|secret|api_key)\s*[:=]\s*["\']?[A-Za-z0-9+/]{8,}', re.I),
    re.compile(r'-----BEGIN (RSA |EC )?PRIVATE KEY-----'),
]


@register("check_secret_scan")
def check_secret_scan(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    bd = pathlib.Path(bundle_dir) if bundle_dir else None
    if not bd or not bd.is_dir():
        return make_check_result(cid, CheckStatus.FAIL, "No bundle_dir")
    hits = []
    for p in bd.rglob("*.yaml"):
        try:
            text = p.read_text()
        except Exception:
            continue
        for pat in _CRED_PATTERNS:
            for m in pat.finditer(text):
                line_no = text[:m.start()].count("\n") + 1
                hits.append(f"{p.relative_to(bd)}:{line_no}: {m.group()[:60]}")
    if hits:
        return make_check_result(cid, CheckStatus.FAIL,
                                 f"{len(hits)} credential pattern(s) found",
                                 evidence={"hits": hits[:20]})
    return make_check_result(cid, CheckStatus.PASS, "No plaintext credentials found")


@register("check_security_contexts")
def check_security_contexts(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    bd = pathlib.Path(bundle_dir) if bundle_dir else None
    if not bd or not bd.is_dir():
        return make_check_result(cid, CheckStatus.FAIL, "No bundle_dir")
    import yaml
    violations = []
    kb = bd / "kustomize_bundle"
    for p in (kb if kb.is_dir() else bd).glob("*.yaml"):
        try:
            docs = list(yaml.safe_load_all(p.read_text()))
        except Exception:
            continue
        for doc in docs:
            if not doc or doc.get("kind") not in ("Deployment", "StatefulSet"):
                continue
            spec = doc.get("spec", {}).get("template", {}).get("spec", {})
            psc = spec.get("securityContext", {})
            if not psc.get("runAsNonRoot"):
                violations.append(f"{doc.get('metadata', {}).get('name', '?')} ({doc['kind']})")
    if violations:
        return make_check_result(cid, CheckStatus.FAIL,
                                 f"runAsNonRoot not set for: {violations}",
                                 evidence={"violations": violations})
    return make_check_result(cid, CheckStatus.PASS, "All workloads have runAsNonRoot: true")


@register("check_pss_labels")
def check_pss_labels(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    bd = pathlib.Path(bundle_dir) if bundle_dir else None
    if not bd or not bd.is_dir():
        return make_check_result(cid, CheckStatus.FAIL, "No bundle_dir")
    import yaml
    for p in bd.rglob("namespace.yaml"):
        try:
            doc = yaml.safe_load(p.read_text())
        except Exception:
            continue
        if not doc:
            continue
        labels = doc.get("metadata", {}).get("labels", {})
        if "pod-security.kubernetes.io/enforce" in labels:
            return make_check_result(cid, CheckStatus.PASS,
                                     "PSS enforce label present",
                                     evidence={"labels": labels})
        return make_check_result(cid, CheckStatus.FAIL,
                                 "namespace.yaml missing pod-security.kubernetes.io/enforce label",
                                 evidence={"labels": labels})
    return make_check_result(cid, CheckStatus.FAIL, "namespace.yaml not found in bundle")
