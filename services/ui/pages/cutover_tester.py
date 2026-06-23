#!/usr/bin/env python3
"""Blue/green cutover tester helpers for Stage 4.

The tester is installed on a selected source-side jumphost, then the dashboard
calls its local API to validate blue/source and green/FLEX endpoints before the
final traffic switch.
"""

from __future__ import annotations

import csv
import json
import os
import re
import shlex
import subprocess
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, Iterator, List, Tuple

from services.ui.pages.post_migration_health_validation import load_stage2_migration_outputs

REMOTE_APP_DIR = "/opt/blue-green-cutover-app"
REMOTE_TARBALL = "/tmp/blue-green-cutover-app.tar.gz"
REMOTE_STAGE_DIR = "/tmp/blue-green-cutover-app"

JUMPHOST_IP_KEYS = (
    "jumphost_ip",
    "jump_host_ip",
    "process_host_ip",
    "process_ip",
    "runner_ip",
    "scan_runner_ip",
    "scanner_runner_ip",
    "appdep_scan_runner_ip",
    "nbd_jumphost_ip",
    "snapwin_jumphost_ip",
    "flex_jumphost_ip",
    "source_jumphost_ip",
)
JUMPHOST_USER_KEYS = (
    "jumphost_user",
    "jump_host_user",
    "process_ssh_user",
    "runner_user",
    "scanner_runner_user",
    "nbd_jumphost_user",
    "snapwin_jumphost_user",
)
JUMPHOST_KEY_KEYS = (
    "ssh_key",
    "process_ssh_key",
    "jumphost_key",
    "jump_host_key",
    "runner_key",
    "scanner_runner_key",
    "nbd_jumphost_key",
    "snapwin_jumphost_key",
)
REGION_KEYS = (
    "region",
    "source_region",
    "target_region",
    "flex_region",
    "ospc_region",
    "source_flex_region",
    "target_flex_region",
)
NAME_KEYS = (
    "name",
    "server_name",
    "source_vm",
    "source_vm_name",
    "source_server_name",
    "target_server_name",
    "resource_name",
    "vm_name",
    "hostname",
)


def repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def ensure_output_dirs() -> Dict[str, Path]:
    root = repo_root()
    dirs = {"tmp": root / ".tmp_runs", "cutover": root / "outputs" / "cutover"}
    for path in dirs.values():
        path.mkdir(parents=True, exist_ok=True)
    return dirs


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _safe_str(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, (dict, list)):
        return json.dumps(value, sort_keys=True)
    return str(value)


def _row_get(row: Dict[str, Any], *keys: str, default: str = "") -> str:
    lowered = {str(key).lower(): value for key, value in (row or {}).items()}
    for key in keys:
        value = row.get(key)
        if value not in (None, ""):
            return _safe_str(value).strip()
        value = lowered.get(key.lower())
        if value not in (None, ""):
            return _safe_str(value).strip()
    return default


def _row_hint(row: Dict[str, Any], *tokens: str) -> str:
    wanted = [token.lower() for token in tokens]
    for key, value in (row or {}).items():
        key_text = str(key).lower().replace("-", "_")
        if all(token in key_text for token in wanted) and value not in (None, ""):
            return _safe_str(value).strip()
    return ""


def _as_rows(payload: Any) -> List[Dict[str, Any]]:
    if isinstance(payload, list):
        return [row for row in payload if isinstance(row, dict)]
    if isinstance(payload, dict):
        rows: List[Dict[str, Any]] = []
        for key in ("items", "results", "vms", "servers", "checks", "candidates", "links", "targets", "rows"):
            value = payload.get(key)
            if isinstance(value, list):
                rows.extend([row for row in value if isinstance(row, dict)])
        return rows
    return []


def _region_from_artifact(path_key: str) -> str:
    text = str(path_key or "").upper()
    matches = re.findall(r"\b([A-Z]{3}\d?)\b", text)
    filtered: List[str] = []
    for match in matches:
        if match in {"CSV", "JSON", "TMP", "RUNS"}:
            continue
        if match not in filtered:
            filtered.append(match)
    return "/".join(filtered[:2])


def _candidate_key(candidate: Dict[str, Any]) -> Tuple[str, str, str]:
    return (
        _safe_str(candidate.get("region")).lower(),
        _safe_str(candidate.get("jumphost_ip")).lower(),
        _safe_str(candidate.get("name")).lower(),
    )


def _candidate_from_row(row: Dict[str, Any], source: str, row_number: int) -> Dict[str, Any] | None:
    row_text = " ".join(_safe_str(v) for v in (row or {}).values()).lower()
    key_text = " ".join(str(k).lower() for k in (row or {}).keys())
    ip = _row_get(row, *JUMPHOST_IP_KEYS) or _row_hint(row, "jump", "ip") or _row_hint(row, "jumphost", "ip")
    name = _row_get(row, *NAME_KEYS) or _row_hint(row, "jump", "name") or _row_hint(row, "host", "name")
    has_jumphost_signal = "jumphost" in row_text or "jump host" in row_text or "jumphost" in key_text or "process_host_ip" in key_text
    if not (ip or has_jumphost_signal):
        return None
    region = _row_get(row, *REGION_KEYS) or _region_from_artifact(source) or "UNKNOWN"
    user = _row_get(row, *JUMPHOST_USER_KEYS) or "ubuntu"
    ssh_key = _row_get(row, *JUMPHOST_KEY_KEYS) or os.environ.get("NBD_JUMPHOST_KEY") or "~/.ssh/id_rsa"
    return {
        "region": region,
        "jumphost_ip": ip,
        "jumphost_user": user,
        "ssh_key": ssh_key,
        "name": name or f"Stage 2 jumphost row {row_number}",
        "source": source,
        "api_url": f"http://{ip}:8000" if ip else "",
        "frontend_url": f"http://{ip}:8080" if ip else "",
        "status": "READY" if ip else "NEEDS IP",
    }


def _load_json(path: Path) -> Dict[str, Any]:
    try:
        if path.exists():
            data = json.loads(path.read_text(encoding="utf-8"))
            return data if isinstance(data, dict) else {}
    except Exception:
        return {}
    return {}


def _cache_candidates() -> List[Dict[str, Any]]:
    root = repo_root()
    data = _load_json(root / "workflow_dashboard" / ".jumphost_cache.json")
    ip = _safe_str(data.get("jumphost_ip")).strip()
    if not ip:
        return []
    return [{
        "region": _safe_str(data.get("region") or "CACHED"),
        "jumphost_ip": ip,
        "jumphost_user": _safe_str(data.get("jumphost_user") or "ubuntu"),
        "ssh_key": _safe_str(data.get("ssh_key") or "~/.ssh/id_rsa"),
        "name": "Last Stage 2 jumphost",
        "source": "workflow_dashboard/.jumphost_cache.json",
        "api_url": f"http://{ip}:8000",
        "frontend_url": f"http://{ip}:8080",
        "status": "READY",
    }]


def _env_candidates() -> List[Dict[str, Any]]:
    names = ("NBD", "OSPC2FLEX", "SNAPWIN", "FLEX2FLEX")
    rows: List[Dict[str, Any]] = []
    for prefix in names:
        ip = os.environ.get(f"{prefix}_JUMPHOST_IP")
        if not ip:
            continue
        rows.append({
            "region": os.environ.get(f"{prefix}_JUMPHOST_REGION") or "ENV",
            "jumphost_ip": ip,
            "jumphost_user": os.environ.get(f"{prefix}_JUMPHOST_USER") or "ubuntu",
            "ssh_key": os.environ.get(f"{prefix}_JUMPHOST_KEY") or "~/.ssh/id_rsa",
            "name": f"{prefix} jumphost",
            "source": f"env:{prefix}_JUMPHOST_IP",
            "api_url": f"http://{ip}:8000",
            "frontend_url": f"http://{ip}:8080",
            "status": "READY",
        })
    return rows


def discover_stage2_jumphosts(
    stage2_data: Dict[str, Any] | None = None,
    include_cache: bool = True,
    include_env: bool = True,
) -> List[Dict[str, Any]]:
    """Return jumphost candidates grouped by region from Stage 2 artifacts."""
    data = stage2_data if stage2_data is not None else load_stage2_migration_outputs()
    candidates: List[Dict[str, Any]] = []
    if include_cache:
        candidates.extend(_cache_candidates())
    if include_env:
        candidates.extend(_env_candidates())
    for source, payload in (data or {}).items():
        if source in {"source_artifacts", "missing_artifacts"}:
            continue
        for row_number, row in enumerate(_as_rows(payload), start=1):
            candidate = _candidate_from_row(row, source, row_number)
            if candidate:
                candidates.append(candidate)
    deduped: Dict[Tuple[str, str, str], Dict[str, Any]] = {}
    for candidate in candidates:
        key = _candidate_key(candidate)
        if key not in deduped:
            deduped[key] = candidate
        elif not deduped[key].get("jumphost_ip") and candidate.get("jumphost_ip"):
            deduped[key] = candidate
    return sorted(deduped.values(), key=lambda c: (_safe_str(c.get("region")), _safe_str(c.get("name")), _safe_str(c.get("jumphost_ip"))))


def _bundle_dir() -> Path:
    return repo_root() / "cutover" / "blue_green_cutover_app"


def _make_bundle_tar() -> str:
    bundle_dir = _bundle_dir()
    if not bundle_dir.exists():
        raise FileNotFoundError(f"Cutover tester bundle not found: {bundle_dir}")
    handle = tempfile.NamedTemporaryFile(prefix="blue-green-cutover-app-", suffix=".tar.gz", delete=False)
    handle.close()
    with tarfile.open(handle.name, "w:gz") as archive:
        for path in bundle_dir.rglob("*"):
            if "__pycache__" in path.parts or path.name.endswith(".pyc"):
                continue
            archive.add(path, arcname=str(path.relative_to(bundle_dir)))
    return handle.name


def _ssh_key_args(ssh_key: str) -> List[str]:
    key = _safe_str(ssh_key).strip()
    if not key:
        return []
    return ["-i", os.path.expanduser(key)]


def _ssh_base(jumphost_ip: str, jumphost_user: str = "ubuntu", ssh_key: str = "") -> List[str]:
    return [
        "ssh",
        *_ssh_key_args(ssh_key),
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
        "-o",
        "LogLevel=ERROR",
        "-o",
        "BatchMode=yes",
        f"{jumphost_user or 'ubuntu'}@{jumphost_ip}",
    ]


def _scp_base(ssh_key: str = "") -> List[str]:
    return [
        "scp",
        *_ssh_key_args(ssh_key),
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
        "-o",
        "LogLevel=ERROR",
        "-o",
        "BatchMode=yes",
    ]


def _cmd_text(argv: Iterable[str]) -> str:
    return " ".join(shlex.quote(str(part)) for part in argv)


def _run_stream(argv: List[str], label: str, timeout: int = 900, env: Dict[str, str] | None = None) -> Iterator[str]:
    yield f"[{label}] $ {_cmd_text(argv)}"
    started = time.time()
    try:
        process = subprocess.Popen(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            env=env,
        )
    except Exception as exc:
        yield f"[ERROR] {label} failed to start: {exc}"
        return 127
    assert process.stdout is not None
    for line in iter(process.stdout.readline, ""):
        if line:
            yield line.rstrip("\n")
        if timeout and (time.time() - started) > timeout:
            process.kill()
            yield f"[ERROR] {label} timed out after {timeout}s"
            return 124
    rc = process.wait()
    if rc == 0:
        yield f"[OK] {label} completed"
    else:
        yield f"[ERROR] {label} exited with code {rc}"
    return rc


def _run_quiet(argv: List[str], timeout: int = 45) -> int:
    try:
        result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=timeout)
        return result.returncode
    except Exception:
        return 127


def _remote_installed(jumphost_ip: str, user: str, ssh_key: str) -> bool:
    check = (
        f"test -f {shlex.quote(REMOTE_APP_DIR)}/backend/main.py && "
        f"test -f {shlex.quote(REMOTE_APP_DIR)}/docker-compose.yml && "
        f"test -f {shlex.quote(REMOTE_APP_DIR)}/start_cutover_app.sh && "
        f"grep -q performance-validation {shlex.quote(REMOTE_APP_DIR)}/backend/main.py"
    )
    return _run_quiet([*_ssh_base(jumphost_ip, user, ssh_key), check], timeout=45) == 0


def _stream_stop(jumphost_ip: str, user: str, ssh_key: str) -> Iterator[str]:
    command = (
        f"if [ -d {shlex.quote(REMOTE_APP_DIR)} ]; then "
        f"cd {shlex.quote(REMOTE_APP_DIR)} && chmod +x *.sh && bash stop_cutover_app.sh; "
        "else echo '[WARN] Cutover tester is not installed on this jumphost.'; fi"
    )
    rc = yield from _run_stream([*_ssh_base(jumphost_ip, user, ssh_key), command], "stop-tester", timeout=300)
    return rc == 0


def _ensure_installed_and_started(jumphost_ip: str, user: str, ssh_key: str) -> Iterator[str]:
    yield f"[INFO] Checking SSH connectivity to {user}@{jumphost_ip}"
    rc = yield from _run_stream([*_ssh_base(jumphost_ip, user, ssh_key), "true"], "ssh-preflight", timeout=60)
    if rc != 0:
        return False
    if _remote_installed(jumphost_ip, user, ssh_key):
        yield f"[OK] Cutover tester already installed in {REMOTE_APP_DIR}"
    else:
        yield f"[INFO] Cutover tester not found. Installing bundle on {jumphost_ip}."
        tar_path = _make_bundle_tar()
        try:
            rc = yield from _run_stream(
                [*_scp_base(ssh_key), tar_path, f"{user}@{jumphost_ip}:{REMOTE_TARBALL}"],
                "upload-tester-bundle",
                timeout=300,
            )
            if rc != 0:
                return False
            install_cmd = (
                "set -e; "
                f"rm -rf {shlex.quote(REMOTE_STAGE_DIR)}; "
                f"mkdir -p {shlex.quote(REMOTE_STAGE_DIR)}; "
                f"tar -xzf {shlex.quote(REMOTE_TARBALL)} -C {shlex.quote(REMOTE_STAGE_DIR)}; "
                f"cd {shlex.quote(REMOTE_STAGE_DIR)}; "
                "chmod +x *.sh; "
                f"APP_DIR={shlex.quote(REMOTE_APP_DIR)} bash install_cutover_app.sh"
            )
            rc = yield from _run_stream([*_ssh_base(jumphost_ip, user, ssh_key), install_cmd], "install-tester", timeout=1200)
            if rc != 0:
                return False
        finally:
            try:
                os.unlink(tar_path)
            except OSError:
                pass
    start_cmd = f"cd {shlex.quote(REMOTE_APP_DIR)} && chmod +x *.sh && bash start_cutover_app.sh"
    rc = yield from _run_stream([*_ssh_base(jumphost_ip, user, ssh_key), start_cmd], "start-tester", timeout=420)
    if rc == 0:
        yield f"[OK] Tester API expected at http://{jumphost_ip}:8000"
        yield f"[OK] Tester UI expected at http://{jumphost_ip}:8080"
    return rc == 0


def _http_json(method: str, url: str, payload: Dict[str, Any] | None = None, timeout: int = 30) -> Tuple[bool, Dict[str, Any]]:
    body = None
    headers = {"Accept": "application/json"}
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=body, headers=headers, method=method.upper())
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            text = response.read().decode("utf-8", errors="replace")
            try:
                data = json.loads(text) if text else {}
            except Exception:
                data = {"raw": text}
            data.setdefault("_http_status", response.status)
            return 200 <= int(response.status) < 300, data
    except urllib.error.HTTPError as exc:
        text = exc.read().decode("utf-8", errors="replace")
        try:
            data = json.loads(text) if text else {}
        except Exception:
            data = {"raw": text}
        data["_http_status"] = exc.code
        data.setdefault("error", text or str(exc))
        return False, data
    except Exception as exc:
        return False, {"error": str(exc), "_http_status": 0}


def _join_base_url(ip: str, port: Any) -> str:
    host = _safe_str(ip).strip()
    if not host:
        return ""
    if host.startswith("http://") or host.startswith("https://"):
        return host.rstrip("/")
    return f"http://{host}:{_safe_str(port or 80).strip() or '80'}"


def build_cutover_tester_config(data: Dict[str, Any]) -> Dict[str, Any]:
    row = data.get("selected_row") if isinstance(data.get("selected_row"), dict) else {}
    app_port = data.get("app_port") or row.get("app_port") or 80
    health_path = data.get("health_path") or row.get("health_path") or "/health"
    smoke_path = data.get("smoke_path") or "/"
    source_url = data.get("source_url") or _join_base_url(row.get("source_server_ip") or data.get("source_ip"), app_port)
    target_url = data.get("target_url") or _join_base_url(row.get("target_server_ip") or data.get("target_ip"), app_port)
    source_name = data.get("source_name") or row.get("source_server_name") or "source-blue"
    target_name = data.get("target_name") or row.get("target_server_name") or "target-green"
    return {
        "active_environment": "source",
        "traffic_mode": data.get("traffic_mode") or "simulation",
        "source": {
            "name": source_name,
            "base_url": source_url,
            "health_path": health_path,
            "smoke_path": smoke_path,
            "expected_status": int(data.get("expected_status") or 200),
            "timeout_seconds": float(data.get("timeout_seconds") or 5),
        },
        "target": {
            "name": target_name,
            "base_url": target_url,
            "health_path": health_path,
            "smoke_path": smoke_path,
            "expected_status": int(data.get("expected_status") or 200),
            "timeout_seconds": float(data.get("timeout_seconds") or 5),
        },
    }


def _api_url(data: Dict[str, Any], jumphost_ip: str = "") -> str:
    explicit = _safe_str(data.get("api_url")).strip().rstrip("/")
    if explicit:
        return explicit
    ip = jumphost_ip or _safe_str(data.get("jumphost_ip")).strip()
    return f"http://{ip}:8000" if ip else ""


def _stream_api_call(method: str, url: str, payload: Dict[str, Any] | None, label: str, evidence: List[Dict[str, Any]]) -> Iterator[str]:
    yield f"[{label}] {method.upper()} {url}"
    ok, result = _http_json(method, url, payload, timeout=45)
    if not isinstance(result, dict):
        result = {"items": result}
    performance_status = str(result.get("performance_status") or "").upper()
    logical_ok = ok and result.get("ok", True) is not False and performance_status != "FAIL"
    evidence.append({"label": label, "ok": logical_ok, "http_ok": ok, "url": url, "result": result})
    if logical_ok:
        metrics = result.get("metrics") if isinstance(result.get("metrics"), dict) else {}
        summary = (
            result.get("recommendation")
            or result.get("message")
            or metrics.get("performance_status")
            or result.get("active_environment")
            or result.get("status")
            or "ok"
        )
        yield f"[OK] {label}: {summary}"
    else:
        yield f"[ERROR] {label}: {result.get('error') or result}"
    return logical_ok, result


def build_performance_payload(data: Dict[str, Any]) -> Dict[str, Any]:
    fields = (
        "sample_count",
        "ospc_avg_response_ms",
        "flex_avg_response_ms",
        "ospc_p95_ms",
        "flex_p95_ms",
        "target_concurrent_users",
        "peak_concurrent_users_tested",
        "active_sessions_tested",
        "api_error_rate_percent",
        "db_avg_query_ms",
        "report_generation_seconds",
        "mobile_app_load_seconds",
        "mobile_tap_response_ms",
        "network_latency_ms",
        "upload_mbps",
        "download_mbps",
        "mobile_lag_status",
    )
    payload: Dict[str, Any] = {}
    for field in fields:
        value = data.get(field)
        if value not in (None, ""):
            payload[field] = value
    payload.setdefault("sample_count", 12)
    payload.setdefault("target_concurrent_users", 10)
    payload.setdefault("active_sessions_tested", payload["target_concurrent_users"])
    payload.setdefault("mobile_lag_status", "Pass")
    return payload


def build_performance_config_payload(data: Dict[str, Any]) -> Dict[str, Any]:
    config = build_cutover_tester_config(data)
    perf = build_performance_payload(data)
    peak = perf.get("peak_concurrent_users_tested") or data.get("peak_concurrent_users") or 25
    concurrent = perf.get("target_concurrent_users") or data.get("concurrent_users") or 10
    return {
        "source_base_url": data.get("performance_source_url") or config["source"]["base_url"],
        "target_base_url": data.get("performance_target_url") or config["target"]["base_url"],
        "test_path": data.get("performance_test_path") or config["target"].get("smoke_path") or "/",
        "health_path": data.get("health_path") or config["target"].get("health_path") or "/health",
        "concurrent_users": int(concurrent or 10),
        "peak_concurrent_users": int(peak or 25),
        "requests_per_user": int(data.get("requests_per_user") or 5),
        "timeout_seconds": float(data.get("timeout_seconds") or 5),
        "max_avg_response_ms": float(data.get("max_avg_response_ms") or 1000),
        "max_p95_ms": float(data.get("max_p95_ms") or 2000),
        "max_error_rate_percent": float(data.get("max_error_rate_percent") or 2),
        "review_avg_delta_ms": float(data.get("review_avg_delta_ms") or 250),
        "fail_avg_delta_ms": float(data.get("fail_avg_delta_ms") or 750),
        "review_p95_delta_ms": float(data.get("review_p95_delta_ms") or 500),
        "fail_p95_delta_ms": float(data.get("fail_p95_delta_ms") or 1500),
        "db_test_url": data.get("db_test_url") or None,
        "report_test_url": data.get("report_test_url") or None,
        "mobile_test_url": data.get("mobile_test_url") or None,
        "upload_test_url": data.get("upload_test_url") or None,
        "download_test_url": data.get("download_test_url") or None,
    }


def _sanitize(value: Any) -> Any:
    if isinstance(value, dict):
        sanitized = {}
        for key, next_value in value.items():
            key_text = str(key).lower()
            if any(token in key_text for token in ("password", "secret", "token", "apikey", "api_key")):
                sanitized[key] = "***redacted***"
            else:
                sanitized[key] = _sanitize(next_value)
        return sanitized
    if isinstance(value, list):
        return [_sanitize(item) for item in value]
    return value


def _artifact_map(paths: Iterable[Path]) -> Dict[str, Dict[str, str]]:
    root = repo_root()
    artifacts: Dict[str, Dict[str, str]] = {}
    for path in paths:
        try:
            rel = path.relative_to(root)
        except ValueError:
            rel = path
        rel_text = str(rel).replace("\\", "/")
        artifacts[rel_text] = {"path": str(path), "url": f"/api/downloads/{rel_text}"}
    return artifacts


RESULT_FIELDNAMES = [
    "migration_id",
    "test_name",
    "result_status",
    "source_app_url",
    "target_app_url",
    "source_ok",
    "target_ok",
    "source_latency_ms",
    "target_latency_ms",
    "ospc_avg_response_ms",
    "flex_avg_response_ms",
    "ospc_p95_ms",
    "flex_p95_ms",
    "avg_response_delta",
    "p95_delta",
    "target_concurrent_users",
    "peak_concurrent_users_tested",
    "active_sessions_tested",
    "api_error_rate_percent",
    "db_avg_query_ms",
    "report_generation_seconds",
    "mobile_app_load_seconds",
    "mobile_tap_response_ms",
    "network_latency_ms",
    "upload_mbps",
    "download_mbps",
    "mobile_lag_status",
    "performance_status",
    "cutover_gate",
    "recommendation",
    "created_at",
    "details",
]


def _probe_value(result: Dict[str, Any], side: str, key: str) -> Any:
    value = result.get(side)
    if isinstance(value, dict):
        return value.get(key)
    return ""


def _status_from_step(step: Dict[str, Any]) -> str:
    if not step.get("ok"):
        return "FAIL"
    result = step.get("result") if isinstance(step.get("result"), dict) else {}
    metrics = result.get("metrics") if isinstance(result.get("metrics"), dict) else {}
    if metrics.get("performance_status"):
        return str(metrics.get("performance_status")).upper()
    if result.get("allowed") is False:
        return "FAIL"
    return "PASS"


def _cutover_gate_from_status(status: str) -> str:
    text = str(status or "").upper()
    if text == "PASS":
        return "APPROVED"
    if text == "REVIEW":
        return "MANUAL_APPROVAL_REQUIRED"
    return "BLOCKED"


def _rows_from_evidence_steps(request_payload: Dict[str, Any], result: Dict[str, Any]) -> List[Dict[str, Any]]:
    steps = result.get("steps") if isinstance(result.get("steps"), list) else []
    config = build_cutover_tester_config(request_payload)
    source_url = config["source"]["base_url"]
    target_url = config["target"]["base_url"]
    rows: List[Dict[str, Any]] = []
    migration_id = _safe_str(request_payload.get("migration_id") or "cutover")
    for step in steps:
        if not isinstance(step, dict):
            continue
        step_result = step.get("result") if isinstance(step.get("result"), dict) else {}
        metrics = step_result.get("metrics") if isinstance(step_result.get("metrics"), dict) else {}
        if not metrics and "ospc_avg_response_ms" in step_result and "flex_avg_response_ms" in step_result:
            metrics = step_result
        source_result = step_result.get("source_result") if isinstance(step_result.get("source_result"), dict) else {}
        target_result = step_result.get("target_result") if isinstance(step_result.get("target_result"), dict) else {}
        if metrics:
            status = str(metrics.get("performance_status") or _status_from_step(step)).upper()
            row = {
                "migration_id": migration_id,
                "test_name": "performance-validation",
                "result_status": status,
                "source_app_url": source_url,
                "target_app_url": target_url,
                "source_ok": source_result.get("successful_requests", ""),
                "target_ok": target_result.get("successful_requests", ""),
                "source_latency_ms": source_result.get("avg_response_ms", ""),
                "target_latency_ms": target_result.get("avg_response_ms", ""),
                "ospc_avg_response_ms": metrics.get("ospc_avg_response_ms", ""),
                "flex_avg_response_ms": metrics.get("flex_avg_response_ms", ""),
                "ospc_p95_ms": metrics.get("ospc_p95_ms", ""),
                "flex_p95_ms": metrics.get("flex_p95_ms", ""),
                "avg_response_delta": metrics.get("avg_response_delta", ""),
                "p95_delta": metrics.get("p95_delta", ""),
                "target_concurrent_users": metrics.get("target_concurrent_users", ""),
                "peak_concurrent_users_tested": metrics.get("peak_concurrent_users_tested", ""),
                "active_sessions_tested": metrics.get("active_sessions_tested", ""),
                "api_error_rate_percent": metrics.get("api_error_rate_percent", ""),
                "db_avg_query_ms": metrics.get("db_avg_query_ms", ""),
                "report_generation_seconds": metrics.get("report_generation_seconds", ""),
                "mobile_app_load_seconds": metrics.get("mobile_app_load_seconds", ""),
                "mobile_tap_response_ms": metrics.get("mobile_tap_response_ms", ""),
                "network_latency_ms": metrics.get("network_latency_ms", ""),
                "upload_mbps": metrics.get("upload_mbps", ""),
                "download_mbps": metrics.get("download_mbps", ""),
                "mobile_lag_status": metrics.get("mobile_lag_status", ""),
                "performance_status": status,
                "cutover_gate": _cutover_gate_from_status(status),
                "recommendation": step_result.get("recommendation") or " ".join(step_result.get("reasons") or []),
                "created_at": step_result.get("created_at") or _now(),
                "details": json.dumps(_sanitize(step_result), sort_keys=True),
            }
        else:
            status = _status_from_step(step)
            row = {
                "migration_id": migration_id,
                "test_name": step.get("label") or "cutover-test",
                "result_status": status,
                "source_app_url": source_url,
                "target_app_url": target_url,
                "source_ok": _probe_value(step_result, "source", "ok"),
                "target_ok": _probe_value(step_result, "target", "ok"),
                "source_latency_ms": _probe_value(step_result, "source", "latency_ms"),
                "target_latency_ms": _probe_value(step_result, "target", "latency_ms"),
                "performance_status": "",
                "cutover_gate": _cutover_gate_from_status(status),
                "recommendation": step_result.get("recommendation") or step_result.get("note") or step_result.get("message") or "",
                "created_at": step_result.get("created_at") or _now(),
                "details": json.dumps(_sanitize(step_result), sort_keys=True),
            }
        for field in RESULT_FIELDNAMES:
            row.setdefault(field, "")
        rows.append(row)
    if not rows:
        status = "PASS" if result.get("ok") else "FAIL"
        row = {
            "migration_id": migration_id,
            "test_name": _safe_str(request_payload.get("action") or "cutover-test"),
            "result_status": status,
            "source_app_url": source_url,
            "target_app_url": target_url,
            "cutover_gate": _cutover_gate_from_status(status),
            "created_at": _now(),
            "details": json.dumps(_sanitize(result), sort_keys=True),
        }
        for field in RESULT_FIELDNAMES:
            row.setdefault(field, "")
        rows.append(row)
    return rows


def write_cutover_results_table(rows: List[Dict[str, Any]]) -> Dict[str, Dict[str, str]]:
    dirs = ensure_output_dirs()
    payload = {
        "stage": "stage_4_cutover_traffic_transition",
        "feature": "blue_green_cutover_tester_results_table",
        "created_at": _now(),
        "rows": rows or [],
    }
    paths: List[Path] = []
    for base in (dirs["cutover"], dirs["tmp"]):
        json_path = base / "cutover_tester_results.json"
        csv_path = base / "cutover_tester_results.csv"
        json_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        with csv_path.open("w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=RESULT_FIELDNAMES)
            writer.writeheader()
            for row in rows or []:
                writer.writerow({field: row.get(field, "") for field in RESULT_FIELDNAMES})
        paths.extend([json_path, csv_path])
    return _artifact_map(paths)


def load_cutover_tester_results() -> Dict[str, Any]:
    path = ensure_output_dirs()["cutover"] / "cutover_tester_results.json"
    data = _load_json(path)
    rows = data.get("rows") if isinstance(data.get("rows"), list) else []
    artifacts = _artifact_map([
        ensure_output_dirs()["cutover"] / "cutover_tester_results.json",
        ensure_output_dirs()["cutover"] / "cutover_tester_results.csv",
        ensure_output_dirs()["tmp"] / "cutover_tester_results.json",
        ensure_output_dirs()["tmp"] / "cutover_tester_results.csv",
    ])
    return {"rows": rows, "artifacts": artifacts, "created_at": data.get("created_at", "")}


def call_cutover_tester_api(
    data: Dict[str, Any],
    method: str,
    path: str,
    payload: Dict[str, Any] | None = None,
) -> Tuple[bool, Dict[str, Any]]:
    api_url = _api_url(data)
    if not api_url:
        return False, {"error": "Tester API URL or jumphost IP is required."}
    return _http_json(method, f"{api_url.rstrip('/')}/{path.lstrip('/')}", payload, timeout=120)


def proxy_performance_config(migration_id: str, data: Dict[str, Any]) -> Dict[str, Any]:
    payload = data.get("config") if isinstance(data.get("config"), dict) else build_performance_config_payload(data)
    ok, result = call_cutover_tester_api(data, "POST", "/performance/config", payload)
    artifacts = write_cutover_tester_evidence(
        "performance-config",
        {"migration_id": migration_id, **data},
        {"ok": ok, "steps": [{"label": "performance-config", "ok": ok, "result": result}]},
    )
    return {"ok": ok, "result": result, "artifacts": artifacts}


def proxy_performance_run(migration_id: str, data: Dict[str, Any]) -> Dict[str, Any]:
    ok, result = call_cutover_tester_api(data, "POST", "/performance/run", None)
    status = str(result.get("performance_status") or ("PASS" if ok else "FAIL")).upper()
    logical_ok = ok and status != "FAIL"
    artifacts = write_cutover_tester_evidence(
        "performance-validation",
        {"migration_id": migration_id, **data},
        {"ok": logical_ok, "steps": [{"label": "performance-validation", "ok": logical_ok, "result": result}]},
    )
    table = load_cutover_tester_results()
    return {
        "ok": logical_ok,
        "performance_status": status,
        "cutover_gate": _cutover_gate_from_status(status),
        "result": result,
        "artifacts": artifacts,
        "table": table,
    }


def proxy_performance_latest(migration_id: str, data: Dict[str, Any]) -> Dict[str, Any]:
    ok, result = call_cutover_tester_api(data, "GET", "/performance/latest", None)
    if ok:
        status = str(result.get("performance_status") or "REVIEW").upper()
        artifacts = write_cutover_tester_evidence(
            "performance-latest",
            {"migration_id": migration_id, **data},
            {"ok": status != "FAIL", "steps": [{"label": "performance-validation", "ok": status != "FAIL", "result": result}]},
        )
    else:
        artifacts = {}
    return {"ok": ok, "result": result, "artifacts": artifacts, "table": load_cutover_tester_results()}


def proxy_performance_audit(data: Dict[str, Any]) -> Dict[str, Any]:
    ok, result = call_cutover_tester_api(data, "GET", "/performance/audit", None)
    return {"ok": ok, "result": result}


def write_cutover_tester_evidence(action: str, request_payload: Dict[str, Any], result: Dict[str, Any]) -> Dict[str, Dict[str, str]]:
    dirs = ensure_output_dirs()
    payload = {
        "stage": "stage_4_cutover_traffic_transition",
        "feature": "blue_green_cutover_tester",
        "action": action,
        "created_at": _now(),
        "request": _sanitize(request_payload),
        "result": result,
    }
    paths = [
        dirs["cutover"] / "cutover_tester_evidence.json",
        dirs["tmp"] / "cutover_tester_evidence.json",
    ]
    for path in paths:
        path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    for base in (dirs["cutover"], dirs["tmp"]):
        with (base / "cutover_tester_evidence.jsonl").open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(payload, sort_keys=True) + "\n")
    result_rows = _rows_from_evidence_steps(request_payload, result)
    artifacts = _artifact_map(paths + [dirs["cutover"] / "cutover_tester_evidence.jsonl", dirs["tmp"] / "cutover_tester_evidence.jsonl"])
    artifacts.update(write_cutover_results_table(result_rows))
    return artifacts


def stream_cutover_tester_action(data: Dict[str, Any]) -> Iterator[str]:
    action = _safe_str(data.get("action") or "run").strip().lower()
    jumphost_ip = _safe_str(data.get("jumphost_ip")).strip()
    user = _safe_str(data.get("jumphost_user") or "ubuntu").strip() or "ubuntu"
    ssh_key = _safe_str(data.get("ssh_key") or "~/.ssh/id_rsa").strip()
    api_url = _api_url(data, jumphost_ip)
    evidence: List[Dict[str, Any]] = []
    yield "=== BLUE/GREEN CUTOVER TESTER ==="
    yield f"[INFO] Action: {action}"
    if not api_url and action not in {"run", "stop"}:
        yield "[ERROR] Tester API URL or jumphost IP is required."
        return
    if action in {"run", "stop"} and not jumphost_ip:
        yield "[ERROR] Select a Stage 2 jumphost before running or stopping the tester."
        return
    if action == "stop":
        ok = yield from _stream_stop(jumphost_ip, user, ssh_key)
        artifacts = write_cutover_tester_evidence(action, data, {"ok": bool(ok)})
        yield f"[ARTIFACTS] {json.dumps(artifacts, sort_keys=True)}"
        return
    if action == "run":
        ok = yield from _ensure_installed_and_started(jumphost_ip, user, ssh_key)
        if not ok:
            artifacts = write_cutover_tester_evidence(action, data, {"ok": False, "steps": evidence})
            yield f"[ARTIFACTS] {json.dumps(artifacts, sort_keys=True)}"
            return
        api_url = _api_url(data, jumphost_ip)
        yield "[INFO] Waiting for tester API to become reachable."
        time.sleep(2)
        config_payload = build_cutover_tester_config(data)
        if not config_payload["source"]["base_url"] or not config_payload["target"]["base_url"]:
            yield "[ERROR] Source URL and target URL are required before cutover tests can run."
            artifacts = write_cutover_tester_evidence(action, data, {"ok": False, "steps": evidence})
            yield f"[ARTIFACTS] {json.dumps(artifacts, sort_keys=True)}"
            return
        ok, _ = yield from _stream_api_call("POST", f"{api_url}/config", config_payload, "configure", evidence)
        if not ok:
            artifacts = write_cutover_tester_evidence(action, data, {"ok": False, "steps": evidence})
            yield f"[ARTIFACTS] {json.dumps(artifacts, sort_keys=True)}"
            return
        for label, method, path in (
            ("health-check", "GET", "/health-check"),
            ("smoke-test", "GET", "/smoke-test"),
            ("pre-cutover-gate", "POST", "/pre-cutover-check"),
        ):
            ok, _ = yield from _stream_api_call(method, f"{api_url}{path}", None, label, evidence)
            if not ok:
                break
        if ok and data.get("include_performance", True) is not False:
            performance_config = build_performance_config_payload(data)
            if int(performance_config.get("concurrent_users") or 0) > 100:
                yield "[WARN] High-load performance test requested. Safe built-in runner will cap effective concurrency on the tester side."
            ok, _ = yield from _stream_api_call("POST", f"{api_url}/performance/config", performance_config, "performance-config", evidence)
            if not ok:
                artifacts = write_cutover_tester_evidence(action, data, {"ok": False, "steps": evidence})
                yield f"[ARTIFACTS] {json.dumps(artifacts, sort_keys=True)}"
                yield f"[RESULT_TABLE] {json.dumps(load_cutover_tester_results(), sort_keys=True)}"
                return
            ok, perf = yield from _stream_api_call("POST", f"{api_url}/performance/run", None, "performance-validation", evidence)
            metrics = perf.get("metrics") if isinstance(perf.get("metrics"), dict) else {}
            if not metrics and isinstance(perf, dict):
                metrics = perf
            if metrics:
                yield f"[PERF] OSPC avg={metrics.get('ospc_avg_response_ms')}ms FLEX avg={metrics.get('flex_avg_response_ms')}ms delta={metrics.get('avg_response_delta')}ms"
                yield f"[PERF] OSPC p95={metrics.get('ospc_p95_ms')}ms FLEX p95={metrics.get('flex_p95_ms')}ms delta={metrics.get('p95_delta')}ms"
                yield f"[PERF] API error={metrics.get('api_error_rate_percent')}% status={metrics.get('performance_status')}"
        if data.get("switch_after_gate") and evidence and evidence[-1].get("ok"):
            switch_payload = {"target_environment": "target", "require_target_healthy": True}
            yield from _stream_api_call("POST", f"{api_url}/switch", switch_payload, "switch-target", evidence)
        all_ok = all(step.get("ok") for step in evidence)
        yield "[OK] Cutover tester run completed." if all_ok else "[ERROR] Cutover tester run completed with failed checks."
        artifacts = write_cutover_tester_evidence(action, data, {"ok": all_ok, "steps": evidence})
        yield f"[ARTIFACTS] {json.dumps(artifacts, sort_keys=True)}"
        yield f"[RESULT_TABLE] {json.dumps(load_cutover_tester_results(), sort_keys=True)}"
        return
    if action == "switch-target":
        payload = {"target_environment": "target", "require_target_healthy": True}
        ok, _ = yield from _stream_api_call("POST", f"{api_url}/switch", payload, "switch-target", evidence)
    elif action == "rollback":
        payload = {"reason": _safe_str(data.get("rollback_reason") or "Manual rollback requested from migration dashboard")}
        ok, _ = yield from _stream_api_call("POST", f"{api_url}/rollback", payload, "rollback", evidence)
    elif action == "audit":
        ok, _ = yield from _stream_api_call("GET", f"{api_url}/audit", None, "audit", evidence)
    elif action == "health-check":
        ok, _ = yield from _stream_api_call("GET", f"{api_url}/health-check", None, "health-check", evidence)
    elif action == "smoke-test":
        ok, _ = yield from _stream_api_call("GET", f"{api_url}/smoke-test", None, "smoke-test", evidence)
    elif action == "pre-cutover-check":
        ok, _ = yield from _stream_api_call("POST", f"{api_url}/pre-cutover-check", None, "pre-cutover-gate", evidence)
    elif action == "performance-validation":
        config_payload = build_performance_config_payload(data)
        ok, _ = yield from _stream_api_call("POST", f"{api_url}/performance/config", config_payload, "performance-config", evidence)
        result: Dict[str, Any] = {}
        if ok:
            ok, result = yield from _stream_api_call("POST", f"{api_url}/performance/run", None, "performance-validation", evidence)
        metrics = result.get("metrics") if isinstance(result.get("metrics"), dict) else {}
        if not metrics and isinstance(result, dict):
            metrics = result
        if metrics:
            yield f"[PERF] avg_response_delta={metrics.get('avg_response_delta')} p95_delta={metrics.get('p95_delta')} status={metrics.get('performance_status')}"
    else:
        yield f"[ERROR] Unknown cutover tester action: {action}"
        return
    artifacts = write_cutover_tester_evidence(action, data, {"ok": bool(ok), "steps": evidence})
    yield f"[ARTIFACTS] {json.dumps(artifacts, sort_keys=True)}"
    yield f"[RESULT_TABLE] {json.dumps(load_cutover_tester_results(), sort_keys=True)}"


def _stream_command_text(commands: str) -> Iterator[str]:
    for line in commands.splitlines():
        yield "[DRY-RUN] " + line


def stream_blue_green_config_action(data: Dict[str, Any]) -> Iterator[str]:
    from services.ui.pages.cutover_plan_generator import (
        _clean_endpoint_ip,
        apply_traffic_split_to_rows,
        build_blue_green_scan_rows,
        build_cutover_markdown,
        build_cutover_plan,
        generate_cutover_commands,
        load_cutover_targets,
        scan_rows_to_cutover_items,
        write_blue_green_scan_artifacts,
        write_cutover_artifacts,
    )

    yield "=== BLUE/GREEN LB / HAPROXY CONFIG STAGE ==="
    lb_option = _safe_str(data.get("lb_option") or "source_haproxy")
    green_weight = int(data.get("green_weight") or 10)
    export_only = bool(data.get("export_only"))
    apply_changes = bool(data.get("apply")) and not export_only
    rows = data.get("rows") if isinstance(data.get("rows"), list) else []
    source_artifacts = data.get("source_artifacts") if isinstance(data.get("source_artifacts"), list) else []
    if not rows:
        payload = load_cutover_targets()
        source_artifacts = payload.get("source_artifacts", [])
        rows = build_blue_green_scan_rows(payload.get("targets") or [], lb_option, green_weight, payload.get("scanner_indexes"))
    rows = apply_traffic_split_to_rows(rows, green_weight, lb_option)
    items = scan_rows_to_cutover_items(rows)
    plan = build_cutover_plan(items, source_artifacts)
    commands = generate_cutover_commands(plan.get("cutover_items") or [])
    artifacts = write_cutover_artifacts(plan, build_cutover_markdown(plan), commands)
    artifacts.update(write_blue_green_scan_artifacts(rows, source_artifacts))
    applyable_items = [item for item in plan.get("cutover_items") or [] if _clean_endpoint_ip(item.get("source_ip")) and _clean_endpoint_ip(item.get("target_ip"))]
    skipped_items = max(0, len(items) - len(applyable_items))
    yield f"[OK] Generated LB/HAProxy artifacts for {len(items)} cutover item(s)."
    yield f"[INFO] Method: {lb_option}; initial FLEX traffic: {green_weight}%"
    yield f"[INFO] Applyable rows: {len(applyable_items)}; skipped incomplete rows: {skipped_items}"
    yield f"[ARTIFACTS] {json.dumps(artifacts, sort_keys=True)}"
    if apply_changes and not applyable_items:
        yield "[WARN] Apply requested, but no row has both source and target IPs. Nothing was installed on HAProxy."
        yield "[WARN] Select a source row and cloned target row, verify selected IPs in the matrix, then run Apply again."
        write_cutover_tester_evidence("configure-lb-apply-skipped", data, {"ok": False, "items": len(items), "applyable_items": 0, "artifacts": artifacts})
        return
    if not apply_changes:
        if export_only:
            yield "[INFO] Export commands only requested. Printing generated commands in dry-run mode."
        else:
            yield "[INFO] Apply is off. Printing generated commands in dry-run mode."
        yield from _stream_command_text(commands)
        write_cutover_tester_evidence("configure-lb-dry-run", data, {"ok": True, "items": len(items), "artifacts": artifacts})
        return
    script_path = ensure_output_dirs()["cutover"] / "cutover_commands.sh"
    env = os.environ.copy()
    env["CUTOVER_APPLY"] = "1"
    env["SOURCE_CUTOVER_HOST"] = _safe_str(data.get("source_cutover_host") or data.get("jumphost_ip"))
    env["SOURCE_SSH_USER"] = _safe_str(data.get("jumphost_user") or "ubuntu")
    env["SOURCE_SSH_KEY"] = _safe_str(data.get("ssh_key") or "")
    env["SOURCE_LB_VIP_SUBNET_ID"] = _safe_str(data.get("source_lb_vip_subnet_id") or "")
    env["SOURCE_OPENRC"] = _safe_str(data.get("source_openrc") or "")
    yield "[INFO] Apply is on. Executing generated cutover configuration script."
    rc = yield from _run_stream(["bash", str(script_path)], "apply-lb-haproxy-config", timeout=1200, env=env)
    artifacts = write_cutover_tester_evidence("configure-lb-apply", data, {"ok": rc == 0, "items": len(items), "artifacts": artifacts})
    yield f"[ARTIFACTS] {json.dumps(artifacts, sort_keys=True)}"
