from __future__ import annotations

import csv
import json
import re
import shlex
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple


DANGEROUS_PATTERNS = [
    r"\brm\s+-rf\b",
    r"\bmkfs\b",
    r"\bdd\b",
    r"\breboot\b",
    r"\bshutdown\b",
    r"\bpoweroff\b",
    r"\bhalt\b",
    r"\biptables\s+-F\b",
    r"\bfirewall-cmd\s+--reload\b",
    r"\bopenstack\s+server\s+delete\b",
    r"\bopenstack\s+image\s+delete\b",
    r"\bopenstack\s+volume\s+delete\b",
    r"\bDROP\s+DATABASE\b",
    r"\bDROP\s+TABLE\b",
    r"\bDELETE\s+FROM\b",
    r"\bTRUNCATE\b",
]

SECRET_PATTERNS = [
    (re.compile(r"(OS_PASSWORD\s*=\s*)[^\s]+", re.I), r"\1****"),
    (re.compile(r"(OS_APPLICATION_CREDENTIAL_SECRET\s*=\s*)[^\s]+", re.I), r"\1****"),
    (re.compile(r"(KAGGLE_KEY\s*=\s*)[^\s]+", re.I), r"\1****"),
    (re.compile(r"(API_KEY\s*=\s*)[^\s]+", re.I), r"\1****"),
    (re.compile(r"(TOKEN\s*=\s*)[^\s]+", re.I), r"\1****"),
    (re.compile(r"(password\s*=\s*)[^&\s]+", re.I), r"\1****"),
    (re.compile(r"(Authorization:\s*Bearer\s+)[A-Za-z0-9._~+/=-]+", re.I), r"\1****"),
]

SAFE_FIRST_WORDS = {
    "curl", "nc", "ping", "ssh", "hostnamectl", "uname", "uptime", "journalctl",
    "ip", "route", "ss", "lsblk", "blkid", "df", "free", "grep", "tail",
    "cat", "ls", "k6", "ab", "iperf3", "mysql", "psql", "systemctl", "diff", "python",
    "watch", "true", "sudo",
}

SAFE_CAT_PREFIXES = (
    "/etc/",
    "./outputs/",
    "outputs/",
    "/var/log/",
)

CSV_FIELDS = [
    "run_id", "linked_system", "linked_test", "execution_mode", "command", "stdout",
    "stderr", "exit_code", "duration_seconds", "started_at", "finished_at", "status",
    "error",
]


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def mask_secrets(value: Any) -> str:
    text = str(value or "")
    for pattern, replacement in SECRET_PATTERNS:
        text = pattern.sub(replacement, text)
    return text


def split_command_lines(command: str) -> List[str]:
    return [line.strip() for line in str(command or "").splitlines() if line.strip() and not line.strip().startswith("#")]


def contains_dangerous_command(command: str) -> Optional[str]:
    for pattern in DANGEROUS_PATTERNS:
        if re.search(pattern, command, flags=re.I):
            return pattern
    return None


def first_word(command: str) -> str:
    try:
        parts = shlex.split(command, posix=True)
    except ValueError:
        return ""
    return parts[0] if parts else ""


def is_sql_safe(command: str) -> bool:
    lowered = command.lower()
    if first_word(command) not in {"mysql", "psql"}:
        return True
    if any(word in lowered for word in [" drop ", " delete ", " truncate ", " update ", " insert ", " alter ", " create "]):
        return False
    return "select" in lowered or "show" in lowered or "now()" in lowered


def is_cat_safe(command: str) -> bool:
    if first_word(command) != "cat":
        return True
    try:
        parts = shlex.split(command, posix=True)
    except ValueError:
        return False
    paths = [part for part in parts[1:] if not part.startswith("-")]
    return bool(paths) and all(any(path.startswith(prefix) for prefix in SAFE_CAT_PREFIXES) for path in paths)


def is_sudo_safe(command: str) -> bool:
    if first_word(command) != "sudo":
        return True
    try:
        parts = shlex.split(command, posix=True)
    except ValueError:
        return False
    return parts == ["sudo", "-l"]


def validate_command(command: str) -> Tuple[bool, str]:
    command = str(command or "").strip()
    if not command:
        return False, "Command is empty."
    blocked = contains_dangerous_command(command)
    if blocked:
        return False, f"Blocked dangerous command pattern: {blocked}"
    for line in split_command_lines(command):
        word = first_word(line)
        if word not in SAFE_FIRST_WORDS:
            return False, f"Command '{word or line}' is not in the UAT allowlist."
        if not is_sql_safe(line):
            return False, "Only SELECT/SHOW style mysql/psql commands are allowed."
        if not is_cat_safe(line):
            return False, "cat is limited to safe config, log, and output paths."
        if not is_sudo_safe(line):
            return False, "sudo is limited to 'sudo -l' in UAT autorun."
    return True, ""


def is_complex_command(command: str) -> bool:
    return bool(re.search(r"[|&;<>(){}*?$`\n]", command))


def build_local_args(command: str) -> List[str]:
    if is_complex_command(command):
        return ["bash", "-lc", command]
    return shlex.split(command, posix=True)


def build_ssh_command(command: str, ssh_user: str, ssh_host: str, ssh_key_path: str = "", ssh_port: Any = 22) -> List[str]:
    if not ssh_user or not ssh_host:
        raise ValueError("SSH mode requires ssh_user and ssh_host.")
    args = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no", "-p", str(ssh_port or 22)]
    if ssh_key_path:
        args.extend(["-i", str(ssh_key_path)])
    args.append(f"{ssh_user}@{ssh_host}")
    args.append(command)
    return args


def normalize_timeout(timeout: Any) -> int:
    try:
        timeout_i = int(timeout)
    except Exception:
        timeout_i = 30
    return max(1, min(timeout_i, 900))


def result_row(**kwargs: Any) -> Dict[str, Any]:
    row = {field: kwargs.get(field, "") for field in CSV_FIELDS}
    row["command"] = mask_secrets(row["command"])
    row["stdout"] = mask_secrets(row["stdout"])
    row["stderr"] = mask_secrets(row["stderr"])
    row["error"] = mask_secrets(row["error"])
    return row


def append_jsonl(path: Path, row: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(row, sort_keys=True) + "\n")


def append_csv(path: Path, row: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    exists = path.exists() and path.stat().st_size > 0
    with path.open("a", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_FIELDS, extrasaction="ignore")
        if not exists:
            writer.writeheader()
        writer.writerow(row)


def save_run(outputs_dir: Path, row: Dict[str, Any]) -> None:
    append_jsonl(outputs_dir / "uat" / "uat_command_runs.jsonl", row)
    append_csv(outputs_dir / "uat" / "uat_command_runs.csv", row)


def read_command_runs(outputs_dir: Path, limit: int = 200) -> List[Dict[str, Any]]:
    path = outputs_dir / "uat" / "uat_command_runs.jsonl"
    if not path.exists():
        return []
    rows: List[Dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            rows.append(json.loads(line))
        except Exception:
            continue
    return rows[-limit:]


def run_uat_command(
    outputs_dir: Path,
    command: str,
    *,
    linked_system: str = "",
    linked_test: str = "",
    execution_mode: str = "local",
    ssh_user: str = "",
    ssh_host: str = "",
    ssh_key_path: str = "",
    ssh_port: Any = 22,
    timeout: Any = 30,
    confirmed: bool = False,
) -> Dict[str, Any]:
    started = utc_now()
    start = time.monotonic()
    timeout_i = normalize_timeout(timeout)
    run_id = f"uat-run-{int(time.time() * 1000)}"
    command = str(command or "").strip()
    if not confirmed:
        row = result_row(run_id=run_id, linked_system=linked_system, linked_test=linked_test, execution_mode=execution_mode, command=command, started_at=started, finished_at=utc_now(), status="Blocked", error="UI confirmation is required before command execution.")
        save_run(outputs_dir, row)
        return row
    ok, reason = validate_command(command)
    if not ok:
        row = result_row(run_id=run_id, linked_system=linked_system, linked_test=linked_test, execution_mode=execution_mode, command=command, started_at=started, finished_at=utc_now(), status="Blocked", error=reason)
        save_run(outputs_dir, row)
        return row
    try:
        if execution_mode == "ssh":
            args = build_ssh_command(command, ssh_user, ssh_host, ssh_key_path, ssh_port)
        else:
            args = build_local_args(command)
        proc = subprocess.run(args, capture_output=True, text=True, timeout=timeout_i, shell=False)
        status = "Passed" if proc.returncode == 0 else "Failed"
        row = result_row(
            run_id=run_id,
            linked_system=linked_system,
            linked_test=linked_test,
            execution_mode=execution_mode,
            command=command,
            stdout=proc.stdout,
            stderr=proc.stderr,
            exit_code=proc.returncode,
            duration_seconds=round(time.monotonic() - start, 3),
            started_at=started,
            finished_at=utc_now(),
            status=status,
        )
    except subprocess.TimeoutExpired as exc:
        row = result_row(
            run_id=run_id,
            linked_system=linked_system,
            linked_test=linked_test,
            execution_mode=execution_mode,
            command=command,
            stdout=exc.stdout or "",
            stderr=exc.stderr or "",
            exit_code="",
            duration_seconds=round(time.monotonic() - start, 3),
            started_at=started,
            finished_at=utc_now(),
            status="Timeout",
            error=f"Command timed out after {timeout_i}s.",
        )
    except Exception as exc:
        row = result_row(
            run_id=run_id,
            linked_system=linked_system,
            linked_test=linked_test,
            execution_mode=execution_mode,
            command=command,
            duration_seconds=round(time.monotonic() - start, 3),
            started_at=started,
            finished_at=utc_now(),
            status="Failed",
            error=str(exc),
        )
    save_run(outputs_dir, row)
    return row
