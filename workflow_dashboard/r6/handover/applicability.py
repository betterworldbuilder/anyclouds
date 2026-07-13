"""Evaluate check applicability rules against bundle context."""
import pathlib
import json


def _read_json(p):
    try:
        with open(p) as f:
            return json.load(f)
    except Exception:
        return {}


def build_bundle_context(bundle_dir):
    """Return a dict of facts about the bundle used by applicability rules."""
    bd = pathlib.Path(bundle_dir) if bundle_dir else None
    ctx = {
        "deployableCount": 0,
        "hasHPAComponents": False,
        "hasMultiReplicaComponents": False,
        "hasOperatorManagedComponents": False,
        "hasMonitorableComponents": False,
        "hasPVCs": False,
        "hasValidationJobs": False,
        "hasVMComponents": False,
        "hasExposedComponents": False,
        "prometheusAvailable": False,
        "veleroAvailable": False,
        "hasOperatorManagedStateful": False,
        "registry": {"host": ""},
    }
    if not bd or not bd.is_dir():
        return ctx

    kb = bd / "kustomize_bundle"
    if not kb.is_dir():
        return ctx

    # Count YAML docs to infer presence of features
    def _yamls(glob):
        return list(kb.glob(glob))

    if (kb / "observability.yaml").is_file():
        ctx["hasMonitorableComponents"] = True
        ctx["prometheusAvailable"] = True
    if (kb / "velero-schedule.yaml").is_file():
        ctx["hasPVCs"] = True
        ctx["veleroAvailable"] = True
    if (kb / "validation-jobs.yaml").is_file():
        ctx["hasValidationJobs"] = True
    if _yamls("*-hpa.yaml") or _yamls("hpa-*.yaml"):
        ctx["hasHPAComponents"] = True
    if _yamls("*-pdb.yaml") or _yamls("pdb-*.yaml"):
        ctx["hasMultiReplicaComponents"] = True
    if _yamls("*-operator-cr.yaml") or _yamls("operator-cr*.yaml"):
        ctx["hasOperatorManagedComponents"] = True
        ctx["hasOperatorManagedStateful"] = True
    if _yamls("*-pvc.yaml") or _yamls("pvc-*.yaml") or (kb / "storage.yaml").is_file():
        ctx["hasPVCs"] = True

    # image-manifest.json
    img_manifest = bd / "image-manifest.json"
    if img_manifest.is_file():
        data = _read_json(img_manifest)
        images = data.get("images", [])
        ctx["deployableCount"] = len(images)

    # Check for exposed components via gateway or ingress
    for f in kb.glob("*.yaml"):
        try:
            content = f.read_text()
            if "HTTPRoute" in content or "kind: Ingress" in content:
                ctx["hasExposedComponents"] = True
            if "kind: VirtualMachine" in content or "VMServiceBinding" in content:
                ctx["hasVMComponents"] = True
        except Exception:
            pass

    # registry host from image manifest
    img_manifest = bd / "image-manifest.json"
    if img_manifest.is_file():
        data = _read_json(img_manifest)
        images = data.get("images", [])
        if images:
            first = images[0].get("image", "")
            if "/" in first:
                ctx["registry"]["host"] = first.split("/")[0]

    return ctx


def is_applicable(check, bundle_context):
    """Evaluate applicabilityRule against bundle_context. Returns True/False."""
    rule = check.get("applicabilityRule", "true")
    if rule == "true":
        return True
    if rule == "false":
        return False

    bc = bundle_context
    # Evaluate simple rules via restricted eval
    try:
        safe_ns = {k: v for k, v in bc.items() if isinstance(v, (bool, int, str, dict))}
        # Support bundle.X syntax
        import types
        bundle_obj = types.SimpleNamespace(**bc)
        safe_ns["bundle"] = bundle_obj
        return bool(eval(rule, {"__builtins__": {}}, safe_ns))  # noqa: S307
    except Exception:
        return True  # default to applicable if rule cannot be parsed
