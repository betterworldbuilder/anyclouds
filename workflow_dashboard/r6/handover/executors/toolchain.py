"""Executor: environment-preflight toolchain checks."""
import subprocess
import shutil
import sys

from .. execution_engine import register
from .. result_models import CheckStatus, make_check_result


def _run(args, timeout=10):
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout.strip() + r.stderr.strip()
    except FileNotFoundError:
        return 1, f"{args[0]}: not found"
    except subprocess.TimeoutExpired:
        return 1, f"{args[0]}: timed out"


@register("check_local_toolchain")
def check_local_toolchain(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    versions = {}
    missing = []
    for tool in ("python3", "git", "kubectl", "kustomize"):
        if shutil.which(tool):
            rc, out = _run([tool, "--version"], 5)
            versions[tool] = out[:80] if rc == 0 else "present (version unknown)"
        else:
            missing.append(tool)
    if missing:
        return make_check_result(
            cid, CheckStatus.FAIL,
            f"Missing tools: {', '.join(missing)}",
            evidence={"versions": versions, "missing": missing},
        )
    return make_check_result(
        cid, CheckStatus.PASS, "All required tools present",
        evidence={"versions": versions},
    )


@register("check_yaml_and_kustomize")
def check_yaml_and_kustomize(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    try:
        import yaml
        yaml.safe_load("key: value")
    except ImportError:
        return make_check_result(cid, CheckStatus.FAIL, "PyYAML not installed (pip install pyyaml)")
    rc, out = _run(["kustomize", "version"], 5)
    if rc != 0:
        return make_check_result(cid, CheckStatus.FAIL, f"kustomize not working: {out}")
    return make_check_result(cid, CheckStatus.PASS, "PyYAML and kustomize available",
                             evidence={"kustomize_version": out})


@register("check_git_repo")
def check_git_repo(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    rc, sha = _run(["git", "rev-parse", "HEAD"], 5)
    if rc != 0:
        return make_check_result(cid, CheckStatus.FAIL, "Not a git repository or no commits")
    rc2, branch = _run(["git", "rev-parse", "--abbrev-ref", "HEAD"], 5)
    return make_check_result(cid, CheckStatus.PASS, f"HEAD={sha[:12]} branch={branch}",
                             evidence={"sha": sha, "branch": branch})


@register("check_r6_test_suite")
def check_r6_test_suite(check, bundle_dir, params, cancel_event):
    cid = check["id"]
    rc, out = _run(
        [sys.executable, "-m", "pytest", "tests/test_r6_generate_bundle.py", "-q", "--tb=no"],
        timeout=120,
    )
    lines = out.splitlines()
    summary = next((l for l in reversed(lines) if "passed" in l or "failed" in l or "error" in l), out[-200:])
    if rc != 0:
        return make_check_result(cid, CheckStatus.FAIL, f"Tests failed: {summary}",
                                 evidence={"pytest_output": out[-1000:]})
    return make_check_result(cid, CheckStatus.PASS, f"All tests passed: {summary}",
                             evidence={"pytest_summary": summary})
