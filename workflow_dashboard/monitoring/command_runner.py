"""Timeout-guarded execution of allowlisted monitoring commands."""
from __future__ import annotations

import json
import os
import subprocess
import time
from typing import Any, Dict, Optional

from .command_registry import CommandSpec, get_command
from .models import MonitoringContext
from .redaction import redact_text


def openstack_env(ctx: MonitoringContext) -> Dict[str, str]:
    """Build OS_* auth env from the cluster blueprint (server-side only).

    The values are passed to child processes and never returned to callers.
    """
    cloud = ctx.blueprint_cloud()
    auth_url = str(cloud.get("auth_url") or "").strip()
    cred_id = str(cloud.get("application_credential_id") or "").strip()
    secret = str(cloud.get("application_credential_secret") or "").strip()
    if not (auth_url and cred_id and secret):
        return {}
    env = {
        "OS_AUTH_URL": auth_url.rstrip("/"),
        "OS_AUTH_TYPE": "v3applicationcredential",
        "OS_APPLICATION_CREDENTIAL_ID": cred_id,
        "OS_APPLICATION_CREDENTIAL_SECRET": secret,
        "OS_IDENTITY_API_VERSION": "3",
        "OS_INTERFACE": "public",
    }
    region = str(cloud.get("region") or "").strip()
    if region:
        env["OS_REGION_NAME"] = region
    return env


def run_command(ctx: MonitoringContext, command_id: str) -> Dict[str, Any]:
    """Run one allowlisted command; failures are recorded, never raised."""
    spec: CommandSpec = get_command(command_id)

    if spec.needs_kubeconfig and not ctx.kubeconfig_available():
        return {"ok": False, "unavailable": True,
                "error": "not available yet: kubeconfig does not exist"}
    if spec.needs_openstack:
        if not ctx.is_openstack():
            return {"ok": False, "unavailable": True,
                    "error": "not available: cluster provider is not OpenStack"}
        auth = openstack_env(ctx)
        if not auth:
            return {"ok": False, "unavailable": True,
                    "error": "not available: OpenStack credentials are not configured for this cluster"}
    else:
        auth = {}

    env = dict(os.environ)
    # Never let ambient credentials leak into non-OpenStack commands; for
    # OpenStack commands use exactly the blueprint credentials.
    for key in list(env):
        if key.startswith("OS_"):
            env.pop(key)
    env.update(auth)

    started = time.monotonic()
    try:
        completed = subprocess.run(
            spec.build(ctx),
            capture_output=True,
            text=True,
            timeout=spec.timeout,
            env=env,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "command timed out after %ss" % spec.timeout,
                "duration": round(time.monotonic() - started, 2)}
    except FileNotFoundError as exc:
        return {"ok": False, "unavailable": True,
                "error": "required binary missing: %s" % exc.filename}
    except Exception as exc:  # never crash the monitoring API
        return {"ok": False, "error": redact_text(str(exc))}

    duration = round(time.monotonic() - started, 2)
    if completed.returncode != 0:
        return {
            "ok": False,
            "returncode": completed.returncode,
            "error": redact_text((completed.stderr or completed.stdout or "").strip()[-2000:]),
            "duration": duration,
        }
    return {"ok": True, "stdout": completed.stdout, "duration": duration}


def run_json_command(ctx: MonitoringContext, command_id: str) -> Dict[str, Any]:
    """Run a command whose stdout is JSON; parse into ``data``."""
    result = run_command(ctx, command_id)
    if not result.get("ok"):
        return result
    try:
        result["data"] = json.loads(result.pop("stdout") or "null")
    except ValueError as exc:
        return {"ok": False, "error": "invalid JSON from %s: %s" % (command_id, exc)}
    return result
