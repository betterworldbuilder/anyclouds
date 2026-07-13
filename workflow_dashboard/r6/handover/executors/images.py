"""Executor: image and registry checks."""
import pathlib
import json
import subprocess
import re

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


@register("check_registry_access")
def check_registry_access(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    bd = pathlib.Path(bundle_dir) if bundle_dir else None
    host = params.get("registry_host", "")
    if not host and bd:
        manifest = bd / "image-manifest.json"
        if manifest.is_file():
            data = json.loads(manifest.read_text())
            images = data.get("images", [])
            if images:
                img = images[0].get("image", "")
                host = img.split("/")[0] if "/" in img else ""
    if not host:
        return make_check_result(cid, CheckStatus.NOT_APPLICABLE,
                                 "No registry host determined from bundle")
    rc, out = _run(["curl", "-sSo", "/dev/null", "-w", "%{http_code}", f"https://{host}/v2/"], 15)
    code = out.strip()
    if code in ("200", "401", "403"):
        return make_check_result(cid, CheckStatus.PASS,
                                 f"Registry {host} responded with HTTP {code}")
    return make_check_result(cid, CheckStatus.WARNING,
                             f"Registry {host} returned HTTP {code} — check connectivity")


@register("check_image_coverage")
def check_image_coverage(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    bd = pathlib.Path(bundle_dir) if bundle_dir else None
    if not bd:
        return make_check_result(cid, CheckStatus.FAIL, "No bundle_dir")
    manifest = bd / "image-manifest.json"
    if not manifest.is_file():
        return make_check_result(cid, CheckStatus.FAIL, "image-manifest.json not found")
    data = json.loads(manifest.read_text())
    images = data.get("images", [])
    if not images:
        return make_check_result(cid, CheckStatus.FAIL, "image-manifest.json has no images")
    return make_check_result(cid, CheckStatus.PASS,
                             f"{len(images)} component image(s) in manifest",
                             evidence={"images": [i.get("image") for i in images[:10]]})


@register("check_validation_job_digests")
def check_validation_job_digests(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    bd = pathlib.Path(bundle_dir) if bundle_dir else None
    if not bd:
        return make_check_result(cid, CheckStatus.FAIL, "No bundle_dir")
    kb = bd / "kustomize_bundle"
    vj = kb / "validation-jobs.yaml"
    if not vj.is_file():
        return make_check_result(cid, CheckStatus.NOT_APPLICABLE,
                                 "validation-jobs.yaml not present")
    text = vj.read_text()
    import yaml
    digest_pattern = re.compile(r'@sha256:[a-f0-9]{64}')
    jobs_without_digest = []
    try:
        docs = list(yaml.safe_load_all(text))
    except Exception as e:
        return make_check_result(cid, CheckStatus.FAIL, f"YAML parse error: {e}")
    for doc in docs:
        if not doc or doc.get("kind") != "Job":
            continue
        name = doc.get("metadata", {}).get("name", "?")
        containers = doc.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
        for c in containers:
            img = c.get("image", "")
            if not digest_pattern.search(img):
                jobs_without_digest.append(f"{name}/{c.get('name', '?')}: {img}")
    if jobs_without_digest:
        return make_check_result(cid, CheckStatus.FAIL,
                                 f"Validation Job images not digest-pinned: {jobs_without_digest}",
                                 evidence={"violations": jobs_without_digest})
    return make_check_result(cid, CheckStatus.PASS,
                             "All validation Job images are digest-pinned")
