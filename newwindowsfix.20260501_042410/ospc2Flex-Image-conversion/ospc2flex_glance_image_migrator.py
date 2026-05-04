#!/usr/bin/env python3
"""
OSPC Glance image -> FLEX Glance image migration pipeline.

Stage-3 download policy (restored to the proven pattern from
osflex-deployer-fullmig-5.0.1704, which successfully exports Rackspace OSPC
Windows snapshots in production):

1) Primary: `openstack image save --file <path> <uuid>` with NO extra flags
   (no --chunk-size, no --os-image-api-version). Success = file size > min.
2) Fallback: curl loop against <public-glance>/v2/images/<id>/file using
   `-C - -L --retry 3 --retry-delay 10 --retry-max-time 180` with X-Auth-Token,
   up to `--export-retries` attempts and `--export-retry-wait`s between them.
   Every failed attempt refreshes the RAX token via RAX-KSKEY:apiKeyCredentials.
   Success = file size > min; HTTP status is logged but NOT used to gate.
3) Deliberately does NOT retry with `--os-image-api-version 1` (Rackspace V1
   Glance returns HTTP 500 on large /file downloads) and does NOT treat
   HTTP 413 as a fatal policy block.
4) Diagnostic artefacts preserved: .stderr.txt, .headers.txt, .http_status.txt,
   .error_body.txt for post-mortem inspection.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import traceback
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional


VERBOSE = False


def log(msg: str) -> None:
    print(redact_secrets(msg), flush=True)


def err(msg: str) -> None:
    safe = redact_secrets(msg)
    print(safe, file=sys.stderr, flush=True)
    print(safe, flush=True)


def shell_quote(value: str) -> str:
    return shlex.quote(str(value))


def redact_secrets(text: str) -> str:
    """Best-effort redaction for tokens/keys/auth payloads."""
    if not text:
        return text
    out = str(text)
    patterns = [
        (r"(?i)(x-auth-token\s*[:=]\s*)([^\s'\";]+)", r"\1***REDACTED_TOKEN***"),
        (r"(?i)(os_token\s*[:=]\s*)([^\s'\";]+)", r"\1***REDACTED_TOKEN***"),
        (r"(?i)(apiKey\"\s*:\s*\")([^\"]+)(\")", r"\1***REDACTED_API_KEY***\3"),
        (r"(?i)(OS_API_KEY\s*=\s*)([^\s'\";]+)", r"\1***REDACTED_API_KEY***"),
        (r"(?i)(OS_PASSWORD\s*=\s*)([^\s'\";]+)", r"\1***REDACTED_API_KEY***"),
        # Rackspace tokens often start with AAB... and are long opaque strings.
        (r"\bAAB[0-9A-Za-z_\-]{20,}\b", "***REDACTED_TOKEN***"),
    ]
    for pat, repl in patterns:
        out = re.sub(pat, repl, out)
    return out


@dataclass
class DownloadResult:
    ok: bool
    method: str
    size: int = 0
    http_status: Optional[int] = None
    curl_rc: Optional[int] = None
    stderr_path: Optional[Path] = None
    headers_path: Optional[Path] = None
    error_body_path: Optional[Path] = None
    message: str = ""


def _run_openrc_cmd(
    openrc_path: str,
    argv: list[str],
    *,
    timeout: int = 3600,
    extra_exports: Optional[dict[str, str]] = None,
) -> subprocess.CompletedProcess:
    export_snippet = ""
    if extra_exports:
        export_snippet = " ".join(
            f"export {k}={shell_quote(v)};" for k, v in extra_exports.items() if v is not None
        )
    cmd = f"source {shell_quote(openrc_path)} && {export_snippet} {' '.join(shell_quote(x) for x in argv)}"
    if VERBOSE:
        log(f"[RUN] bash -lc {shell_quote(cmd)}")
    proc = subprocess.run(
        ["bash", "-lc", cmd],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return proc


def _write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text or "", encoding="utf-8", errors="replace")


def should_refresh_token(http_status: Optional[int], stderr_text: str) -> bool:
    if http_status in (401, 403):
        return True
    s = (stderr_text or "").lower()
    auth_markers = [
        "http 401",
        "http 403",
        "unauthorized",
        "forbidden",
        "invalid token",
        "token expired",
        "authentication required",
        "failed to discover available identity versions",
    ]
    return any(m in s for m in auth_markers)


def _is_transient_cli_failure(stderr_text: str) -> bool:
    s = (stderr_text or "").lower()
    transient = [
        "timed out",
        "timeout",
        "temporarily unavailable",
        "connection reset",
        "broken pipe",
        "service unavailable",
        "gateway timeout",
    ]
    return any(m in s for m in transient)


def _is_invalid_response_cli_failure(stderr_text: str) -> bool:
    s = (stderr_text or "").lower()
    markers = [
        "invalidresponse",
        "unable to download image",
        "expecting value",
        "could not decode response body",
    ]
    return any(m in s for m in markers)


def refresh_ospc_token(ospc_openrc: str) -> str:
    """Acquire fresh OSPC token via RAX-KSKEY flow without logging secrets."""
    script = f"""
source {shell_quote(ospc_openrc)}
OS_USERNAME="${{OS_USERNAME:-}}"
OS_API_KEY="${{OS_API_KEY:-${{OS_PASSWORD:-}}}}"
if [ -z "$OS_USERNAME" ] || [ -z "$OS_API_KEY" ]; then
  exit 9
fi
RESP=$(curl -s -X POST "https://identity.api.rackspacecloud.com/v2.0/tokens" \\
  -H "Content-Type: application/json" \\
  -d "{{\\"auth\\":{{\\"RAX-KSKEY:apiKeyCredentials\\":{{\\"username\\":\\"$OS_USERNAME\\",\\"apiKey\\":\\"$OS_API_KEY\\"}}}}}}" 2>/dev/null || true)
printf '%s' "$RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['access']['token']['id'])" 2>/dev/null || true
"""
    proc = subprocess.run(
        ["bash", "-lc", script],
        capture_output=True,
        text=True,
        timeout=45,
        input="",
    )
    token = (proc.stdout or "").strip()
    if not token:
        raise RuntimeError("OSPC token refresh failed")
    return token


def validate_downloaded_image(
    path: Path,
    *,
    min_size_bytes: int,
    method: str,
    http_status: Optional[int] = None,
    stderr_path: Optional[Path] = None,
    error_body_path: Optional[Path] = None,
) -> int:
    if not path.exists():
        raise RuntimeError(
            f"Download validation failed: file missing ({path}) method={method} http={http_status} "
            f"stderr={stderr_path} error_body={error_body_path}"
        )
    size = path.stat().st_size
    if size < min_size_bytes:
        raise RuntimeError(
            f"Download validation failed: file too small ({size} bytes < {min_size_bytes}) "
            f"method={method} http={http_status} stderr={stderr_path} error_body={error_body_path}"
        )
    # Optional deeper check when plausible size is present.
    try:
        info = subprocess.run(
            ["qemu-img", "info", "--output=json", str(path)],
            capture_output=True,
            text=True,
            timeout=20,
        )
        if info.returncode != 0:
            log(f"[WARN] qemu-img info failed after download validation: {redact_secrets(info.stderr)}")
    except Exception as exc:
        log(f"[WARN] qemu-img info skipped: {exc}")
    return size


def _resolve_image_download_url(ospc_openrc: str, region: str) -> str:
    # Rackspace v2 catalog shape uses endpoint key `publicURL`.
    proc = _run_openrc_cmd(ospc_openrc, ["openstack", "catalog", "show", "image", "-f", "json"], timeout=30)
    if proc.returncode == 0 and proc.stdout.strip():
        try:
            payload = json.loads(proc.stdout)
            endpoints = payload.get("endpoints") or []
            if endpoints:
                preferred = [e for e in endpoints if str(e.get("region", "")).upper() == region.upper()]
                pick = preferred[0] if preferred else endpoints[0]
                url = (pick.get("publicURL") or pick.get("url") or "").rstrip("/")
                if url:
                    return url
        except Exception:
            pass
    # deterministic fallback
    return f"https://{region.lower()}.images.api.rackspacecloud.com"


def _normalize_glance_base(url: str) -> str:
    base = (url or "").strip().rstrip("/")
    if base.endswith("/v2"):
        base = base[:-3]
    return base


def list_private_images(ospc_openrc: str) -> list[dict]:
    proc = _run_openrc_cmd(
        ospc_openrc,
        ["openstack", "image", "list", "--private", "-f", "json"],
        timeout=60,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"Failed to list private images: {redact_secrets(proc.stderr or proc.stdout or '')}"
        )
    try:
        payload = json.loads(proc.stdout or "[]")
        return payload if isinstance(payload, list) else []
    except Exception as exc:
        raise RuntimeError(f"Failed to parse private image list JSON: {exc}") from exc


def show_image(ospc_openrc: str, image_id: str) -> dict:
    proc = _run_openrc_cmd(
        ospc_openrc,
        ["openstack", "image", "show", image_id, "-f", "json"],
        timeout=60,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"Failed to show image {image_id}: {redact_secrets(proc.stderr or proc.stdout or '')}"
        )
    try:
        payload = json.loads(proc.stdout or "{}")
        return payload if isinstance(payload, dict) else {}
    except Exception as exc:
        raise RuntimeError(f"Failed to parse image show JSON for {image_id}: {exc}") from exc


def _to_bool(value: object) -> bool:
    if isinstance(value, bool):
        return value
    s = str(value or "").strip().lower()
    return s in ("1", "true", "yes", "y", "on")


def is_downloadable_saved_image(meta: dict) -> tuple[bool, str]:
    status = str(meta.get("status", "")).lower()
    visibility = str(meta.get("visibility", "")).lower()
    protected = _to_bool(meta.get("protected", False))
    if status != "active":
        return False, f"image not active: status={status or 'unknown'}"
    if protected:
        return False, "image is protected/provider-managed"
    if visibility == "public":
        return False, "image is public/provider-managed"
    return True, "downloadable saved image"


def _image_timestamp(meta: dict) -> str:
    return str(meta.get("updated_at") or meta.get("created_at") or "")


def select_saved_image(
    ospc_openrc: str,
    source_image_id: str | None,
    source_image_name: str | None,
    saved_images_only: bool,
) -> dict:
    src_id = (source_image_id or "").strip()
    src_name = (source_image_name or "").strip()

    if src_id:
        meta = show_image(ospc_openrc, src_id)
        ok, reason = is_downloadable_saved_image(meta)
        if not ok:
            raise RuntimeError(
                f"Rejected source image {src_id}: {reason}. "
                "Image is not a downloadable Saved Image. It is public/protected/provider-managed. "
                "Use a tenant Saved Image from MyCloud > Servers > Images, or create a VM snapshot first."
            )
        return meta

    private_images = list_private_images(ospc_openrc)
    candidates: list[dict] = []
    for item in private_images:
        candidate_id = str(item.get("ID") or item.get("id") or "").strip()
        if not candidate_id:
            continue
        try:
            meta = show_image(ospc_openrc, candidate_id)
        except Exception:
            continue
        ok, _ = is_downloadable_saved_image(meta)
        if ok:
            candidates.append(meta)

    if src_name:
        name_matches = [m for m in candidates if str(m.get("name", "")).strip() == src_name]
        if not name_matches:
            raise RuntimeError(
                f"No matching Saved Image found for name '{src_name}'. "
                "Use openstack image list --private to confirm available tenant Saved Images."
            )
        name_matches.sort(key=_image_timestamp, reverse=True)
        return name_matches[0]

    if saved_images_only and not candidates:
        raise RuntimeError(
            "No downloadable Saved Images found in tenant private images. "
            "Create a VM snapshot in MyCloud > Servers > Images first."
        )
    if not candidates:
        raise RuntimeError(
            "No valid source image selected. Provide --source-image-id or --source-image-name."
        )
    candidates.sort(key=_image_timestamp, reverse=True)
    return candidates[0]


def download_via_openstack_cli(
    ospc_openrc: str,
    image_id: str,
    dest: Path,
    *,
    chunk_size: int,
    token_override: Optional[str] = None,
    force_image_api_v1: bool = False,
) -> DownloadResult:
    stderr_path = Path(str(dest) + ".stderr.txt")
    args = ["openstack"]
    if force_image_api_v1:
        args += ["--os-image-api-version", "1"]
    args += ["image", "save", "--file", str(dest)]
    # --chunk-size is a v2 client feature; v1 "image save" rejects it.
    if chunk_size > 0 and not force_image_api_v1:
        args += ["--chunk-size", str(chunk_size)]
    args.append(image_id)
    proc = _run_openrc_cmd(
        ospc_openrc,
        args,
        timeout=7200,
        extra_exports={"OS_TOKEN": token_override} if token_override else None,
    )
    _write_text(stderr_path, proc.stderr)
    if proc.returncode != 0:
        return DownloadResult(
            ok=False,
            method="openstack-cli",
            stderr_path=stderr_path,
            message=f"openstack image save failed rc={proc.returncode}",
        )
    size = dest.stat().st_size if dest.exists() else 0
    return DownloadResult(ok=True, method="openstack-cli", size=size, stderr_path=stderr_path)


def download_via_curl(
    ospc_openrc: str,
    image_id: str,
    dest: Path,
    *,
    region: str,
    token_override: Optional[str] = None,
    retries: int = 4,
    retry_wait: int = 15,
    min_size_bytes: int = 1024 * 1024,
) -> DownloadResult:
    """
    Proven download pattern from osflex-deployer-fullmig-5.0.1704 Windows export.
    Loops up to `retries` times:
      curl -s -C - -L --retry 3 --retry-delay 10 --retry-max-time 180 \
           -H "X-Auth-Token: <tok>" -o <dest> "<public-glance>/v2/images/<id>/file"
    Success criterion = local file size > min_size_bytes. HTTP status is logged
    but NOT used to gate success (Rackspace OSPC intermittently reports 413/500
    mid-stream even when the byte stream eventually succeeds after a token
    refresh). Every failed attempt refreshes the RAX token via
    RAX-KSKEY:apiKeyCredentials before the next try.
    """
    headers_path = Path(str(dest) + ".headers.txt")
    stderr_path = Path(str(dest) + ".stderr.txt")
    error_body_path = Path(str(dest) + ".error_body.txt")
    status_path = Path(str(dest) + ".http_status.txt")

    for p in (headers_path, stderr_path, error_body_path, status_path):
        try:
            p.unlink()
        except FileNotFoundError:
            pass
    try:
        if dest.exists():
            dest.unlink()
    except Exception:
        pass

    base_url = _normalize_glance_base(_resolve_image_download_url(ospc_openrc, region))
    url = f"{base_url}/v2/images/{image_id}/file"

    script = f"""
set +x
source {shell_quote(ospc_openrc)}
OS_USERNAME="${{OS_USERNAME:-}}"
OS_API_KEY="${{OS_API_KEY:-${{OS_PASSWORD:-}}}}"
OS_TOKEN_IN={shell_quote(token_override or "")}
TOK="$OS_TOKEN_IN"
[ -z "$TOK" ] && TOK="${{OS_TOKEN:-}}"

_rax_refresh() {{
  local r
  r=$(curl -s -X POST "https://identity.api.rackspacecloud.com/v2.0/tokens" \\
      -H "Content-Type: application/json" \\
      -d "{{\\"auth\\":{{\\"RAX-KSKEY:apiKeyCredentials\\":{{\\"username\\":\\"$OS_USERNAME\\",\\"apiKey\\":\\"$OS_API_KEY\\"}}}}}}" 2>/dev/null || true)
  printf '%s' "$r" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['access']['token']['id'])" 2>/dev/null || true
}}

if [ -z "$TOK" ] && [ -n "$OS_USERNAME" ] && [ -n "$OS_API_KEY" ]; then
  TOK=$(_rax_refresh)
fi
if [ -z "$TOK" ]; then
  echo "[curl] no OSPC token available (missing OS_TOKEN / RAX apiKey)" 1>&2
  echo "000" > {shell_quote(str(status_path))}
  exit 9
fi

RETRIES={int(retries)}
RETRY_WAIT={int(retry_wait)}
MIN_SIZE={int(min_size_bytes)}
URL={shell_quote(url)}
DEST={shell_quote(str(dest))}
HDRS={shell_quote(str(headers_path))}
ERRLOG={shell_quote(str(stderr_path))}
LAST_HTTP="000"
LAST_SIZE=0
success=0
for attempt in $(seq 1 $RETRIES); do
  echo "[curl] attempt $attempt/$RETRIES -> $URL" 1>&2
  HTTP_CODE=$(curl -s -C - -L --retry 3 --retry-delay 10 --retry-max-time 180 \\
      -H "X-Auth-Token: $TOK" \\
      -D "$HDRS" \\
      -o "$DEST" \\
      --write-out '%{{http_code}}' \\
      "$URL" 2>> "$ERRLOG" || echo "000")
  LAST_HTTP="$HTTP_CODE"
  LAST_SIZE=$(stat -c%s "$DEST" 2>/dev/null || echo 0)
  echo "[curl] attempt $attempt: HTTP=$LAST_HTTP size=$LAST_SIZE" 1>&2
  if [ "$LAST_SIZE" -gt "$MIN_SIZE" ]; then
    success=1
    break
  fi
  echo "[curl] attempt $attempt incomplete - refreshing RAX token and retrying" 1>&2
  NEW_TOK=$(_rax_refresh)
  [ -n "$NEW_TOK" ] && TOK="$NEW_TOK"
  rm -f "$DEST"
  if [ "$attempt" -lt "$RETRIES" ]; then
    sleep $RETRY_WAIT
  fi
done
printf '%s' "$LAST_HTTP" > {shell_quote(str(status_path))}
[ "$success" -eq 1 ] && exit 0 || exit 22
"""
    # Stream the bash loop line-by-line so the operator sees every
    # "[curl] attempt N: HTTP=X size=Y" progress line in real time
    # (subprocess.run(capture_output=True) would buffer for up to 7200s).
    proc = subprocess.Popen(
        ["bash", "-lc", script],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        errors="replace",
        bufsize=1,
    )
    captured_lines: list[str] = []
    assert proc.stdout is not None
    try:
        for raw_line in proc.stdout:
            line = raw_line.rstrip("\n")
            if not line:
                continue
            safe = redact_secrets(line)
            print(safe, flush=True)
            captured_lines.append(safe)
    finally:
        proc.wait(timeout=7200)
    if captured_lines:
        try:
            with stderr_path.open("a", encoding="utf-8", errors="replace") as fh:
                fh.write("\n".join(captured_lines) + "\n")
        except Exception:
            pass

    http_status: Optional[int] = None
    try:
        http_status = int(status_path.read_text(encoding="utf-8").strip())
    except Exception:
        http_status = None

    size = dest.stat().st_size if dest.exists() else 0
    if size and size < min_size_bytes and dest.exists():
        try:
            error_body_path.write_bytes(dest.read_bytes())
        except Exception:
            pass

    return DownloadResult(
        ok=(proc.returncode == 0 and size > min_size_bytes),
        method="curl-loop",
        size=size,
        http_status=http_status,
        curl_rc=proc.returncode,
        stderr_path=stderr_path,
        headers_path=headers_path,
        error_body_path=error_body_path if error_body_path.exists() else None,
        message=f"curl-loop rc={proc.returncode} http={http_status} size={size}",
    )


def _run_openrc_streaming(
    openrc_path: str,
    argv: list[str],
    *,
    timeout: int,
    log_prefix: str = "",
) -> tuple[int, str]:
    """Run an openstack CLI command with openrc sourced, streaming stdout/stderr
    line-by-line through the migrator's log() so operators see live progress.
    Returns (returncode, merged_output_text).
    """
    cmd = (
        f"source {shell_quote(openrc_path)} && "
        + " ".join(shell_quote(x) for x in argv)
        + " 2>&1"
    )
    proc = subprocess.Popen(
        ["bash", "-lc", cmd],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        errors="replace",
        bufsize=1,
    )
    captured: list[str] = []
    assert proc.stdout is not None
    try:
        for raw in proc.stdout:
            line = raw.rstrip("\n")
            if not line:
                continue
            safe = redact_secrets(line)
            if log_prefix:
                print(f"{log_prefix} {safe}", flush=True)
            else:
                print(safe, flush=True)
            captured.append(safe)
    finally:
        proc.wait(timeout=timeout)
    return proc.returncode, "\n".join(captured)


def download_via_image_task_swift(
    ospc_openrc: str,
    image_id: str,
    dest: Path,
    *,
    region: str = "IAD",
    swift_container: str = "ospc2flex-export",
    task_timeout_sec: int = 1800,
    poll_interval_sec: int = 10,
    cleanup_swift_object: bool = True,
    min_size_bytes: int = 1024 * 1024,
) -> DownloadResult:
    """
    Rackspace-documented fallback for large image exports that direct Glance
    /file downloads reject with HTTP 413 / InvalidResponse.

    Flow:
      1) Create an image export task:
           openstack image task create --type export \
               --json-string '{"image_uuid":"...","receiving_swift_container":"...","image_name":"<id>.vhd"}'
      2) Poll `openstack image task show <task_id>` every `poll_interval_sec`
         until status transitions to "success" (download) or "failure" (raise).
      3) Download the Swift object via `openstack object save <container> <name>`.
      4) Optionally remove the Swift object after successful download.

    The Swift path is chunked/segmented by Cloud Files and is not subject to the
    direct-Glance 413 policy.
    """
    stderr_path = Path(str(dest) + ".swift.log")
    try:
        stderr_path.unlink()
    except FileNotFoundError:
        pass
    try:
        if dest.exists():
            dest.unlink()
    except Exception:
        pass

    object_name = f"{image_id}.vhd"
    log(
        f"[SWIFT] Export task fallback starting: image={image_id} "
        f"container={swift_container} object={object_name} timeout={task_timeout_sec}s"
    )

    # 1) Create the export task via direct Glance v2 API.
    # The local openstackclient on jumphosts often has `image task show/list`
    # but not `image task create`, so we POST /v2/tasks ourselves.
    glance_base = _normalize_glance_base(_resolve_image_download_url(ospc_openrc, region))
    tasks_url = f"{glance_base}/v2/tasks"
    try:
        tok = refresh_ospc_token(ospc_openrc)
    except Exception as exc:
        return DownloadResult(
            ok=False,
            method="swift-task",
            stderr_path=stderr_path,
            message=f"token refresh failed before task create: {exc}",
        )

    task_payload = json.dumps(
        {
            "type": "export",
            "input": {
                "image_uuid": image_id,
                "receiving_swift_container": swift_container,
                "image_name": object_name,
            },
        },
        separators=(",", ":"),
    )
    create_proc = _run_openrc_cmd(
        ospc_openrc,
        [
            "curl",
            "-sS",
            "-X",
            "POST",
            tasks_url,
            "-H",
            f"X-Auth-Token: {tok}",
            "-H",
            "Content-Type: application/json",
            "-d",
            task_payload,
        ],
        timeout=120,
    )
    _write_text(stderr_path, (create_proc.stdout or "") + "\n" + (create_proc.stderr or ""))
    if create_proc.returncode != 0 or not (create_proc.stdout or "").strip():
        return DownloadResult(
            ok=False,
            method="swift-task",
            stderr_path=stderr_path,
            message=(
                "image task create failed "
                f"rc={create_proc.returncode} stderr="
                f"{redact_secrets((create_proc.stderr or '')[:500])} "
                f"stdout={redact_secrets((create_proc.stdout or '')[:500])}"
            ),
        )
    try:
        task_meta = json.loads(create_proc.stdout)
    except Exception as exc:
        return DownloadResult(
            ok=False,
            method="swift-task",
            stderr_path=stderr_path,
            message=f"image task create returned non-JSON: {exc}",
        )
    task_id = str(task_meta.get("id") or task_meta.get("ID") or "").strip()
    if not task_id:
        return DownloadResult(
            ok=False,
            method="swift-task",
            stderr_path=stderr_path,
            message="image task create succeeded but returned no task id",
        )
    log(f"[SWIFT] Export task created: task_id={task_id} (status={task_meta.get('status', 'pending')})")

    # 2) Poll the task until terminal status via direct GET /v2/tasks/<id>.
    import time as _time

    started_at = _time.monotonic()
    last_status = ""
    terminal_ok = False
    terminal_failure_msg = ""
    while True:
        elapsed = _time.monotonic() - started_at
        if elapsed > task_timeout_sec:
            terminal_failure_msg = (
                f"task polling timed out after {int(elapsed)}s (status={last_status or 'unknown'})"
            )
            break
        show_proc = _run_openrc_cmd(
            ospc_openrc,
            [
                "curl",
                "-sS",
                "-X",
                "GET",
                f"{tasks_url}/{task_id}",
                "-H",
                f"X-Auth-Token: {tok}",
            ],
            timeout=60,
        )
        try:
            with stderr_path.open("a", encoding="utf-8", errors="replace") as fh:
                fh.write((show_proc.stdout or "") + "\n" + (show_proc.stderr or "") + "\n")
        except Exception:
            pass
        if show_proc.returncode != 0:
            log(
                f"[SWIFT] task show rc={show_proc.returncode} stderr="
                f"{redact_secrets((show_proc.stderr or '')[:200])} — refreshing token and retrying"
            )
            try:
                tok = refresh_ospc_token(ospc_openrc)
            except Exception:
                pass
            _time.sleep(poll_interval_sec)
            continue
        try:
            show_meta = json.loads(show_proc.stdout or "{}")
        except Exception:
            _time.sleep(poll_interval_sec)
            continue
        status = str(show_meta.get("status", "")).strip().lower()
        if status and status != last_status:
            log(f"[SWIFT] task status={status} (elapsed={int(elapsed)}s)")
            last_status = status
        if status == "success":
            terminal_ok = True
            break
        if status in ("failure", "error"):
            terminal_failure_msg = (
                f"task terminal status={status} message="
                f"{redact_secrets(str(show_meta.get('message', ''))[:500])}"
            )
            break
        _time.sleep(poll_interval_sec)

    if not terminal_ok:
        return DownloadResult(
            ok=False,
            method="swift-task",
            stderr_path=stderr_path,
            message=terminal_failure_msg or "task did not reach success",
        )

    # 3) Download the Swift object, streaming progress.
    log(f"[SWIFT] Downloading Cloud Files object: container={swift_container} object={object_name}")
    dest.parent.mkdir(parents=True, exist_ok=True)
    rc, out = _run_openrc_streaming(
        ospc_openrc,
        [
            "openstack",
            "object",
            "save",
            swift_container,
            object_name,
            "--file",
            str(dest),
        ],
        timeout=max(task_timeout_sec, 3600),
        log_prefix="[SWIFT]",
    )
    try:
        with stderr_path.open("a", encoding="utf-8", errors="replace") as fh:
            fh.write(out + "\n")
    except Exception:
        pass
    size = dest.stat().st_size if dest.exists() else 0
    if rc != 0 or size <= min_size_bytes:
        return DownloadResult(
            ok=False,
            method="swift-task",
            size=size,
            stderr_path=stderr_path,
            message=(
                f"object save rc={rc} size={size} (min={min_size_bytes}) "
                f"container={swift_container} object={object_name}"
            ),
        )

    # 4) Best-effort cleanup of the Swift object (avoid Cloud Files storage costs).
    if cleanup_swift_object:
        del_proc = _run_openrc_cmd(
            ospc_openrc,
            ["openstack", "object", "delete", swift_container, object_name],
            timeout=120,
        )
        if del_proc.returncode == 0:
            log(f"[SWIFT] Cleaned up Swift object {swift_container}/{object_name}")
        else:
            log(
                f"[SWIFT] WARNING: failed to delete Swift object "
                f"{swift_container}/{object_name}: "
                f"{redact_secrets((del_proc.stderr or '')[:200])}"
            )

    log(f"[SWIFT] Export via image task + object save complete: {size} bytes")
    return DownloadResult(
        ok=True,
        method="swift-task",
        size=size,
        stderr_path=stderr_path,
        message=f"swift-task rc=0 size={size} task_id={task_id}",
    )


def download_ospc_glance_image(
    ospc_openrc: str,
    image_id: str,
    dest: Path,
    *,
    export_retries: int = 4,
    export_retry_wait: int = 15,
    min_size_bytes: int = 1024 * 1024,
    enable_curl_fallback: bool = True,
    enable_swift_export: bool = True,
    swift_container: str = "ospc2flex-export",
    swift_task_timeout_sec: int = 1800,
    swift_poll_interval_sec: int = 10,
    swift_cleanup_object: bool = True,
    cli_chunk_size: int = 0,
    region: str = "IAD",
) -> None:
    """
    Stage-3 download policy (proven pattern from osflex-deployer-fullmig-5.0.1704
    Windows snapshot export; see remote_export_Windows_Server_2019Re_*.sh lines
    103-172 in that tree):

      1) Primary: `openstack image save --file <path> <uuid>` with NO extra
         flags (no --chunk-size, no --os-image-api-version). Success = file
         size > min_size_bytes.
      2) Fallback: curl loop against the public Glance /v2/images/<id>/file
         endpoint, up to `export_retries` attempts with `export_retry_wait`s
         between attempts, refreshing the RAX apiKey token on every failed
         attempt. Success = file size > min_size_bytes.

    Deliberately does NOT:
      - Retry with `--os-image-api-version 1` (Rackspace V1 Glance returns 500
        on /image download for snapshots - verified 2026-04 migration logs).
      - Treat HTTP 413 as a fatal policy block (observed to clear after a RAX
        token refresh in the working 5.0.1704 pipeline).
      - Pass `--chunk-size` to the v2 CLI (observed to trigger InvalidResponse
        against Rackspace Glance; 5.0.1704 never used it).
    """
    # cli_chunk_size is accepted for CLI backward-compat but intentionally
    # ignored here: the proven pattern never passed --chunk-size.
    del cli_chunk_size

    if dest.exists():
        dest.unlink()

    # 1) Primary: plain `openstack image save` (no extra flags).
    log("[INFO] Stage 3 download: openstack image save (plain v2, no --chunk-size)")
    first = download_via_openstack_cli(
        ospc_openrc,
        image_id,
        dest,
        chunk_size=0,
        token_override=None,
    )
    if first.ok:
        size = dest.stat().st_size if dest.exists() else 0
        if size > min_size_bytes:
            validate_downloaded_image(
                dest,
                min_size_bytes=min_size_bytes,
                method=first.method,
                stderr_path=first.stderr_path,
            )
            log(f"[OK] Download via openstack image save: {size} bytes")
            return
        log(
            f"[WARN] openstack image save produced small file ({size} bytes < "
            f"{min_size_bytes}) - continuing to curl loop fallback"
        )

    stderr_text = (
        first.stderr_path.read_text(encoding="utf-8", errors="replace")
        if first.stderr_path and first.stderr_path.exists()
        else ""
    )
    stderr_preview = "\n".join((stderr_text or "").splitlines()[:6]).strip() or "(no stderr output)"
    log(f"[WARN] openstack image save failed: {redact_secrets(first.message)}")
    log(f"[WARN] openstack image save stderr preview: {redact_secrets(stderr_preview)}")

    if not enable_curl_fallback:
        raise RuntimeError(
            "Glance image download failed via openstack image save and curl "
            "fallback is disabled. "
            f"method={first.method} stderr={first.stderr_path} "
            f"stderr_preview={redact_secrets(stderr_preview)}"
        )

    # 2) Fallback: curl loop with RAX token refresh per attempt.
    log(
        f"[INFO] Falling back to curl loop (retries={export_retries}, "
        f"wait={export_retry_wait}s, min_size={min_size_bytes})"
    )
    curl_res = download_via_curl(
        ospc_openrc,
        image_id,
        dest,
        region=region,
        token_override=None,
        retries=max(1, int(export_retries)),
        retry_wait=max(1, int(export_retry_wait)),
        min_size_bytes=min_size_bytes,
    )
    if curl_res.ok:
        size = validate_downloaded_image(
            dest,
            min_size_bytes=min_size_bytes,
            method=curl_res.method,
            http_status=curl_res.http_status,
            stderr_path=curl_res.stderr_path,
            error_body_path=curl_res.error_body_path,
        )
        log(
            f"[OK] Download via curl loop: {size} bytes "
            f"(last HTTP={curl_res.http_status})"
        )
        return

    # 3) Last-resort fallback: image-task export to Swift/Cloud Files.
    # This path avoids direct /v2/images/<id>/file policies that often return
    # HTTP 413 on large snapshots behind public edge proxies.
    if enable_swift_export:
        log(
            "[INFO] Direct Glance download failed; falling back to image task "
            f"export via Swift container '{swift_container}'"
        )
        swift_res = download_via_image_task_swift(
            ospc_openrc,
            image_id,
            dest,
            region=region,
            swift_container=swift_container,
            task_timeout_sec=max(60, int(swift_task_timeout_sec)),
            poll_interval_sec=max(2, int(swift_poll_interval_sec)),
            cleanup_swift_object=bool(swift_cleanup_object),
            min_size_bytes=min_size_bytes,
        )
        if swift_res.ok:
            size = validate_downloaded_image(
                dest,
                min_size_bytes=min_size_bytes,
                method=swift_res.method,
                stderr_path=swift_res.stderr_path,
            )
            log(f"[OK] Download via Swift export fallback: {size} bytes")
            return
        raise RuntimeError(
            "Glance image download failed after openstack image save + curl loop, "
            "and Swift export fallback also failed. "
            f"curl_http={curl_res.http_status} curl_rc={curl_res.curl_rc} "
            f"curl_size={curl_res.size} curl_stderr={curl_res.stderr_path} "
            f"curl_headers={curl_res.headers_path} curl_error_body={curl_res.error_body_path} "
            f"swift_stderr={swift_res.stderr_path} swift_msg={swift_res.message}"
        )

    raise RuntimeError(
        "Glance image download failed after openstack image save + curl loop. "
        f"method={curl_res.method} http={curl_res.http_status} "
        f"curl_rc={curl_res.curl_rc} size={curl_res.size} "
        f"stderr={curl_res.stderr_path} headers={curl_res.headers_path} "
        f"error_body={curl_res.error_body_path}"
    )


def validate_download_checksum(path: Path, expected_checksum: str) -> None:
    expected = (expected_checksum or "").strip().lower()
    if not expected:
        return
    if len(expected) != 32 or not all(c in "0123456789abcdef" for c in expected):
        log("[WARN] Source image checksum is non-md5 or invalid format; skipping checksum validation")
        return
    digest = hashlib.md5()  # nosec B303 - OpenStack image checksum field is MD5
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    got = digest.hexdigest().lower()
    if got != expected:
        raise RuntimeError(
            f"Downloaded image checksum mismatch: expected={expected} actual={got} file={path}"
        )
    log(f"[OK] Download checksum validated: {got}")


def run(cmd: str, *, check: bool = True) -> str:
    log(f"[RUN] {cmd}")
    proc = subprocess.Popen(
        cmd,
        shell=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        errors="replace",
        bufsize=1,
    )
    captured: list[str] = []
    assert proc.stdout is not None
    for line in proc.stdout:
        line = line.rstrip("\n")
        captured.append(line)
        print(redact_secrets(line), flush=True)
    proc.wait()
    out = "\n".join(captured).strip()
    if proc.returncode != 0 and check:
        tail = "\n".join(captured[-20:]) if captured else "(no output captured)"
        raise RuntimeError(
            f"Command failed ({proc.returncode}): {redact_secrets(cmd)}\n--- last 20 lines ---\n{redact_secrets(tail)}"
        )
    return out


def openstack_cmd(openrc_path: str, cli_cmd: str) -> str:
    return f"bash -lc {shell_quote(f'source {openrc_path} && {cli_cmd}')}"


def _resolve_migtool_dir() -> Path:
    env = (os.environ.get("OSPC2FLEX_MIGTOOL_DIR") or "").strip()
    if env:
        return Path(env).expanduser().resolve()
    here = Path(__file__).resolve().parent
    if (here / "ospc2flex_offline_repair.sh").is_file():
        return here
    return Path(__file__).resolve().parent.parent / "ospc2Flex-Image-migtool"


def sanitize_name(name: str) -> str:
    safe = "".join(ch if ch.isalnum() or ch in ("-", "_", ".") else "-" for ch in str(name))
    while "--" in safe:
        safe = safe.replace("--", "-")
    return safe.strip("-") or "ospc-image"


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="OSPC Glance image to FLEX Glance migration")
    p.add_argument("--ospc-openrc", required=True)
    p.add_argument("--flex-openrc", required=True)
    p.add_argument("--source-image-id", default="")
    p.add_argument("--source-image-name", default="")
    p.add_argument(
        "--saved-images-only",
        action="store_true",
        help="Require source image to be a tenant Saved Image (active/private/non-protected)",
    )
    p.add_argument("--workdir", default="/mnt/migration/ospc2flex_image")
    p.add_argument("--target-format", default="qcow2", choices=["qcow2", "raw"])
    p.add_argument("--container-format", default="bare")
    p.add_argument("--visibility", default="private", choices=["private", "public", "shared", "community"])
    p.add_argument("--flex-image-name", default="")
    p.add_argument("--keep-export", action="store_true")
    p.add_argument("--skip-repair", action="store_true")
    p.add_argument("--offline-repair-script", default="")
    p.add_argument("--os-type-override", default="")
    p.add_argument("--export-retries", type=int, default=4)
    p.add_argument("--export-retry-wait", type=int, default=15)
    p.add_argument("--verbose", action="store_true")
    p.add_argument(
        "--enable-curl-fallback",
        action="store_true",
        default=True,
        help="(default: on) Allow curl-loop fallback after openstack image save fails. "
             "Kept for CLI backward compatibility; curl fallback is always on.",
    )
    p.add_argument(
        "--no-curl-fallback",
        action="store_true",
        help="Disable the curl-loop fallback (primary openstack image save only).",
    )
    p.add_argument("--min-download-bytes", type=int, default=1024 * 1024, help="Minimum valid downloaded image size")
    p.add_argument(
        "--openstack-chunk-size",
        type=int,
        default=0,
        help="(deprecated/no-op) The proven 5.0.1704 pipeline never passed --chunk-size; ignored.",
    )
    p.add_argument("--ospc-region", default="IAD")
    p.add_argument(
        "--download-only",
        action="store_true",
        help="Run only Stage 1 (OSPC download) and exit before convert/repair/upload",
    )
    return p.parse_args()


def main() -> int:
    global VERBOSE
    args = parse_args()
    VERBOSE = bool(getattr(args, "verbose", False))
    ts = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
    src_id = args.source_image_id.strip()
    src_name = args.source_image_name.strip()
    src_safe = sanitize_name(src_name)
    flex_image_name = args.flex_image_name.strip() or f"{sanitize_name(src_name or src_id or 'saved-image')}-flex-{ts}"

    workdir = Path(args.workdir).expanduser().resolve()
    workdir.mkdir(parents=True, exist_ok=True)
    raw_path = workdir / f"{src_safe}-{src_id}.img"
    converted_path = workdir / f"{src_safe}-{src_id}.{args.target_format}"
    upload_path = converted_path if args.target_format == "qcow2" else raw_path

    migtool_dir = _resolve_migtool_dir()
    if str(migtool_dir) not in sys.path:
        sys.path.insert(0, str(migtool_dir))
    from ospc2flex_repair_os_hint import infer_offline_os_type

    repair_script = args.offline_repair_script.strip() or str((migtool_dir / "ospc2flex_offline_repair.sh").resolve())
    windows_repair_script = str((migtool_dir / "ospc2flex_windows_repair.sh").resolve())

    log("=== OSPC IMAGE -> FLEX IMAGE PIPELINE ===")
    log(
        "[INFO] Stage 3 policy: plain `openstack image save` first, then curl loop "
        "with RAX token refresh (5.0.1704 proven pattern)"
    )
    log(f"[INFO] Requested image ID   : {src_id or '(not provided)'}")
    log(f"[INFO] Requested image name : {src_name or '(not provided)'}")
    log(f"[INFO] FLEX image name   : {flex_image_name}")
    log(f"[INFO] Workdir           : {workdir}")

    if not src_id and not src_name:
        raise RuntimeError(
            "No source image selector provided. Use --source-image-id or --source-image-name."
        )

    image_payload = select_saved_image(
        args.ospc_openrc,
        src_id,
        src_name,
        bool(args.saved_images_only),
    )
    selected_id = str(image_payload.get("id") or image_payload.get("ID") or "").strip()
    selected_name = str(image_payload.get("name") or "").strip() or selected_id
    ok_saved, why_saved = is_downloadable_saved_image(image_payload)
    if not ok_saved:
        raise RuntimeError(
            f"Rejected source image {selected_id}: {why_saved}. "
            "Image is not a downloadable Saved Image. It is public/protected/provider-managed. "
            "Use a tenant Saved Image from MyCloud > Servers > Images, or create a VM snapshot first."
        )

    src_id = selected_id
    src_name = selected_name
    src_safe = sanitize_name(src_name)
    raw_path = workdir / f"{src_safe}-{src_id}.img"
    converted_path = workdir / f"{src_safe}-{src_id}.{args.target_format}"
    upload_path = converted_path if args.target_format == "qcow2" else raw_path

    log(f"[INFO] Selected Saved Image: {src_name} ({src_id})")
    log(
        "[INFO] Selected image traits: "
        f"visibility={str(image_payload.get('visibility', '')).lower()} "
        f"protected={_to_bool(image_payload.get('protected', False))} "
        f"status={str(image_payload.get('status', '')).lower()}"
    )
    log("[INFO] Proceeding with openstack image save")
    src_disk_fmt = (image_payload.get("disk_format") or "").strip().lower()

    os_type_hint = (args.os_type_override or "").strip().lower() or infer_offline_os_type(
        name=src_name,
        image_props=image_payload,
    )
    log(f"[INFO] Offline repair OS profile: {os_type_hint or 'unknown'}")

    log("[STAGE-START] 1 · Download source image from OSPC Glance")
    try:
        download_ospc_glance_image(
            args.ospc_openrc,
            src_id,
            raw_path,
            export_retries=max(1, int(args.export_retries)),
            export_retry_wait=max(1, int(args.export_retry_wait)),
            min_size_bytes=max(1024, int(args.min_download_bytes)),
            enable_curl_fallback=not bool(getattr(args, "no_curl_fallback", False)),
            cli_chunk_size=max(0, int(args.openstack_chunk_size)),
            region=(args.ospc_region or "IAD").strip() or "IAD",
        )
        validate_download_checksum(raw_path, str(image_payload.get("checksum") or ""))
        log(f"[STAGE-OK] 1 · Downloaded: {raw_path} ({raw_path.stat().st_size} bytes)")
    except Exception as exc:
        err(f"[STAGE-FAIL] 1 · Glance download: {exc}")
        raise

    if args.download_only:
        log("[STAGE-SKIP] 2 · Convert image format skipped (--download-only)")
        log("[STAGE-SKIP] 3 · Offline repair skipped (--download-only)")
        log("[STAGE-SKIP] 4 · FLEX upload skipped (--download-only)")
        log("=== PIPELINE DONE (download-only) ===")
        return 0

    log("[STAGE-START] 2 · Convert image format if needed")
    try:
        if args.target_format == "raw":
            upload_path = raw_path
            log("[STAGE-OK] 2 · target-format=raw, no conversion required")
        elif src_disk_fmt == "qcow2":
            run(f"cp -f {shell_quote(str(raw_path))} {shell_quote(str(converted_path))}")
            upload_path = converted_path
            log("[STAGE-OK] 2 · Source already qcow2; copied to qcow2 artifact")
        else:
            detected_fmt = run(f"qemu-img info --output=json {shell_quote(str(raw_path))}", check=False).strip()
            fmt = "raw"
            if detected_fmt:
                try:
                    fmt = (json.loads(detected_fmt).get("format") or "raw").strip() or "raw"
                except Exception:
                    pass
            log(f"[INFO] Detected downloaded format: {fmt}")
            run(f"qemu-img convert -p -f {shell_quote(fmt)} -O qcow2 {shell_quote(str(raw_path))} {shell_quote(str(converted_path))}")
            upload_path = converted_path
            log(f"[STAGE-OK] 2 · Converted to qcow2: {converted_path}")
    except Exception as exc:
        err(f"[STAGE-FAIL] 2 · Format conversion: {exc}")
        raise

    if not args.skip_repair and args.target_format == "qcow2":
        log("[STAGE-START] 3 · Offline repair")
        try:
            if os_type_hint == "windows":
                _win_dbg = f"{converted_path}.repair.debug.log"
                run(
                    f"sudo bash {shell_quote(windows_repair_script)} --qcow2 {shell_quote(str(converted_path))} "
                    f"--force --debug --debug-log {shell_quote(_win_dbg)}",
                    check=True,
                )
                log("[STAGE-OK] 3 · Windows offline repair completed")
            else:
                repair_cmd = f"sudo bash {shell_quote(repair_script)} --qcow2 {shell_quote(str(converted_path))} --force"
                if os_type_hint:
                    repair_cmd += f" --os-type {shell_quote(os_type_hint)}"
                run(repair_cmd)
                log("[STAGE-OK] 3 · Linux offline repair completed")
        except Exception as exc:
            err(f"[STAGE-FAIL] 3 · Offline repair: {exc}")
            raise
    else:
        log("[STAGE-OK] 3 · Offline repair skipped")

    log("[STAGE-START] 4 · Upload converted image to FLEX Glance")
    try:
        run(
            openstack_cmd(
                args.flex_openrc,
                " ".join(
                    [
                        "openstack image create",
                        shell_quote(flex_image_name),
                        f"--file {shell_quote(str(upload_path))}",
                        f"--disk-format {shell_quote(args.target_format)}",
                        f"--container-format {shell_quote(args.container_format)}",
                        f"--visibility {shell_quote(args.visibility)}",
                    ]
                ),
            ),
            check=True,
        )
        log(f"[STAGE-OK] 4 · FLEX image upload requested: {flex_image_name}")
    except Exception as exc:
        err(f"[STAGE-FAIL] 4 · FLEX Glance upload: {exc}")
        raise

    if not args.keep_export:
        try:
            if raw_path.exists():
                raw_path.unlink()
            if converted_path.exists():
                converted_path.unlink()
            log("[CLEANUP] Local export files removed")
        except Exception as exc:
            log(f"[WARN] Cleanup failed: {exc}")

    log("=== PIPELINE DONE ===")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        err(f"[FATAL] {type(exc).__name__}: {exc}")
        err("[FATAL] Traceback:")
        for line in traceback.format_exc().rstrip("\n").splitlines():
            err(f"[FATAL]   {line}")
        sys.exit(1)

