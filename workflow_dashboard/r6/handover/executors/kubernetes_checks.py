"""Executor: Kubernetes resource checks (dry-run, HPA, PDB, Operator CRs)."""
import pathlib
import subprocess
import shutil
import yaml

from .. execution_engine import register
from .. result_models import CheckStatus, make_check_result


def _run(args, timeout=30):
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout + r.stderr
    except FileNotFoundError:
        return 1, f"{args[0]}: not found"
    except subprocess.TimeoutExpired:
        return 1, "timed out"


@register("check_kubernetes_access")
def check_kubernetes_access(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    rc, out = _run(["kubectl", "cluster-info"], 15)
    if rc != 0:
        return make_check_result(cid, CheckStatus.FAIL, f"kubectl cluster-info failed: {out[:200]}")
    return make_check_result(cid, CheckStatus.PASS, "Cluster accessible",
                             evidence={"info": out[:300]})


@register("check_k8s_dry_run")
def check_k8s_dry_run(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    bd = pathlib.Path(bundle_dir) if bundle_dir else None
    if not bd:
        return make_check_result(cid, CheckStatus.FAIL, "No bundle_dir")
    kb = bd / "kustomize_bundle"
    if not kb.is_dir():
        return make_check_result(cid, CheckStatus.NOT_APPLICABLE, "No kustomize_bundle directory")
    if not shutil.which("kubectl"):
        return make_check_result(cid, CheckStatus.FAIL, "kubectl not found")
    # Collect YAML files to dry-run
    yamls = list(kb.glob("*.yaml"))
    if not yamls:
        return make_check_result(cid, CheckStatus.NOT_APPLICABLE, "No YAML files to dry-run")
    rc, out = _run(
        ["kubectl", "apply", "--dry-run=server", "--recursive", "-f", str(kb)],
        timeout=60,
    )
    if rc != 0:
        return make_check_result(cid, CheckStatus.FAIL,
                                 f"Server dry-run failed: {out[:400]}",
                                 evidence={"output": out[:1000]})
    return make_check_result(cid, CheckStatus.PASS,
                             "Server-side dry-run passed",
                             evidence={"output": out[:400]})


@register("check_hpa_generation")
def check_hpa_generation(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    bd = pathlib.Path(bundle_dir) if bundle_dir else None
    if not bd:
        return make_check_result(cid, CheckStatus.FAIL, "No bundle_dir")
    kb = bd / "kustomize_bundle"
    hpa_docs = []
    for p in (kb if kb.is_dir() else bd).glob("*.yaml"):
        try:
            for doc in yaml.safe_load_all(p.read_text()):
                if doc and doc.get("kind") == "HorizontalPodAutoscaler":
                    hpa_docs.append(doc.get("metadata", {}).get("name"))
        except Exception:
            pass
    if not hpa_docs:
        return make_check_result(cid, CheckStatus.FAIL, "No HPA resources found in bundle")
    return make_check_result(cid, CheckStatus.PASS,
                             f"{len(hpa_docs)} HPA resource(s) found",
                             evidence={"hpas": hpa_docs})


@register("check_pdb_generation")
def check_pdb_generation(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    bd = pathlib.Path(bundle_dir) if bundle_dir else None
    if not bd:
        return make_check_result(cid, CheckStatus.FAIL, "No bundle_dir")
    kb = bd / "kustomize_bundle"
    pdb_docs = []
    for p in (kb if kb.is_dir() else bd).glob("*.yaml"):
        try:
            for doc in yaml.safe_load_all(p.read_text()):
                if doc and doc.get("kind") == "PodDisruptionBudget":
                    pdb_docs.append(doc.get("metadata", {}).get("name"))
        except Exception:
            pass
    if not pdb_docs:
        return make_check_result(cid, CheckStatus.FAIL, "No PDB resources found in bundle")
    return make_check_result(cid, CheckStatus.PASS,
                             f"{len(pdb_docs)} PDB resource(s) found",
                             evidence={"pdbs": pdb_docs})


@register("check_operator_crs")
def check_operator_crs(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    bd = pathlib.Path(bundle_dir) if bundle_dir else None
    if not bd:
        return make_check_result(cid, CheckStatus.FAIL, "No bundle_dir")
    kb = bd / "kustomize_bundle"
    operator_kinds = []
    for p in (kb if kb.is_dir() else bd).glob("*.yaml"):
        try:
            for doc in yaml.safe_load_all(p.read_text()):
                if doc and "." in doc.get("apiVersion", ""):
                    api = doc["apiVersion"]
                    if any(op in api for op in ("postgres-operator", "redis", "rabbitmq", "kafka", "zookeeper")):
                        operator_kinds.append(f"{api}/{doc.get('kind')}")
        except Exception:
            pass
    if not operator_kinds:
        return make_check_result(cid, CheckStatus.FAIL, "No operator CR resources found in bundle")
    return make_check_result(cid, CheckStatus.PASS,
                             f"{len(operator_kinds)} operator CR(s) found",
                             evidence={"kinds": operator_kinds})


@register("check_prometheus_operator")
def check_prometheus_operator(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    rc, out = _run(["kubectl", "get", "crd", "servicemonitors.monitoring.coreos.com"], 15)
    if rc != 0:
        return make_check_result(cid, CheckStatus.NOT_APPLICABLE,
                                 "Prometheus Operator CRD not installed",
                                 evidence={"output": out[:200]})
    return make_check_result(cid, CheckStatus.PASS,
                             "Prometheus Operator CRD present",
                             evidence={"output": out[:200]})


@register("check_velero")
def check_velero(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    rc, out = _run(["kubectl", "get", "crd", "schedules.velero.io"], 15)
    if rc != 0:
        return make_check_result(cid, CheckStatus.NOT_APPLICABLE,
                                 "Velero CRD not installed",
                                 evidence={"output": out[:200]})
    return make_check_result(cid, CheckStatus.PASS,
                             "Velero CRD present",
                             evidence={"output": out[:200]})


@register("check_storage_classes")
def check_storage_classes(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    rc, out = _run(["kubectl", "get", "storageclass", "-o", "name"], 20)
    if rc != 0:
        return make_check_result(cid, CheckStatus.WARNING,
                                 "Could not list StorageClasses",
                                 evidence={"output": out[:200]})
    classes = [l.strip() for l in out.splitlines() if l.strip()]
    return make_check_result(cid, CheckStatus.PASS,
                             f"{len(classes)} StorageClass(es) found",
                             evidence={"classes": classes})
