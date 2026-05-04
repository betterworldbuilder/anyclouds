from __future__ import annotations

import csv
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional


KEYWORDS = [
    "ERROR", "FAILED", "EXCEPTION", "TRACEBACK", "TIMEOUT", "REFUSED",
    "AUTHENTICATION", "HTTP 401", "HTTP 403", "HTTP 404", "HTTP 500",
    "HTTP 502", "HTTP 503", "BOOT FAILED", "KERNEL PANIC", "NO NETWORK",
    "DB ERROR", "REPLICATION LAG", "QEMU CONVERT FAILED", "GLANCE UPLOAD FAILED",
]

FINDING_FIELDS = [
    "finding_id", "timestamp", "source_file", "stage", "severity", "category",
    "linked_system", "vm", "db", "ip", "message", "suggested_uat_test",
    "suggested_command", "status",
]

SUGGESTED_COMMANDS = {
    "boot": "hostnamectl\nuname -a\nsystemctl --failed\njournalctl -p err -n 100 --no-pager\nlsblk\nblkid\ncat /etc/fstab",
    "network": "ip a\nip route\ncat /etc/netplan/*.yaml 2>/dev/null || true\nnmcli dev status 2>/dev/null || true\nping -c 5 8.8.8.8\ncurl -I http://<target_ip>/",
    "app": "curl -v http://<target_ip>/health\nsystemctl status <service_name> --no-pager\njournalctl -u <service_name> -n 100 --no-pager",
    "db": "mysql -h <db_ip> -u <db_user> -p -e \"SHOW DATABASES;\"\nmysql -h <db_ip> -u <db_user> -p -e \"SHOW REPLICA STATUS\\G\"\npsql -h <db_ip> -U <db_user> -d <db_name> -c \"SELECT now();\"",
    "auth": "curl -I http://<target_ip>/\ncurl -H \"Authorization: Bearer <TOKEN>\" http://<target_ip>/api/health",
    "timeout": "nc -zv <target_ip> <port>\ncurl -v --connect-timeout 5 http://<target_ip>:<port>/",
    "image": "qemu-img info <image_path>\ntail -100 ./outputs/migration/image_conversion_log.txt",
}


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def configured_log_dirs(base_dir: Path) -> List[Path]:
    return [
        base_dir / "outputs" / "discovery",
        base_dir / "outputs" / "migration",
        base_dir / "logs",
        base_dir / "workdir",
        base_dir / "snapshotbackup",
    ]


def iter_log_files(base_dir: Path) -> Iterable[Path]:
    seen = set()
    for folder in configured_log_dirs(base_dir):
        if not folder.exists():
            continue
        for path in folder.rglob("*"):
            if path.is_file() and path.suffix.lower() in {".log", ".txt", ".json", ".csv"} and path not in seen:
                seen.add(path)
                yield path


def stage_from_path(path: Path) -> str:
    text = path.as_posix().lower()
    if "/discovery/" in text:
        return "Stage 1 Discovery"
    if "/migration/" in text or "image_conversion" in text or "boot_validation" in text:
        return "Stage 2 Migration"
    if "/logs/" in text:
        return "Runtime Logs"
    if "/workdir/" in text:
        return "Workdir"
    if "/snapshotbackup/" in text:
        return "Snapshot Backup"
    return "Unknown"


def classify(line: str) -> Dict[str, str]:
    upper = line.upper()
    if any(k in upper for k in ["KERNEL PANIC", "BOOT FAILED"]):
        return {"severity": "Critical", "category": "boot", "test": "VM Boot Health", "command": SUGGESTED_COMMANDS["boot"]}
    if any(k in upper for k in ["NO NETWORK", "DHCP", "REFUSED"]):
        return {"severity": "High", "category": "network", "test": "Network Connectivity", "command": SUGGESTED_COMMANDS["network"]}
    if any(k in upper for k in ["HTTP 500", "HTTP 502", "HTTP 503"]):
        return {"severity": "High", "category": "app", "test": "Application Health", "command": SUGGESTED_COMMANDS["app"]}
    if any(k in upper for k in ["DB ERROR", "REPLICATION LAG"]):
        return {"severity": "High", "category": "db", "test": "Database Validation", "command": SUGGESTED_COMMANDS["db"]}
    if any(k in upper for k in ["AUTHENTICATION", "HTTP 401", "HTTP 403"]):
        return {"severity": "Medium", "category": "auth", "test": "Access & Login", "command": SUGGESTED_COMMANDS["auth"]}
    if any(k in upper for k in ["TIMEOUT", "REFUSED"]):
        return {"severity": "Medium", "category": "timeout", "test": "Network Connectivity", "command": SUGGESTED_COMMANDS["timeout"]}
    if any(k in upper for k in ["QEMU CONVERT FAILED", "GLANCE UPLOAD FAILED"]):
        return {"severity": "High", "category": "image", "test": "VM Boot Health", "command": SUGGESTED_COMMANDS["image"]}
    if "TRACEBACK" in upper or "EXCEPTION" in upper or "ERROR" in upper or "FAILED" in upper:
        return {"severity": "High", "category": "migration", "test": "Cutover Readiness", "command": "tail -100 <source_file>"}
    if "HTTP 404" in upper:
        return {"severity": "Low", "category": "app", "test": "Application Health", "command": SUGGESTED_COMMANDS["app"]}
    return {"severity": "Medium", "category": "general", "test": "Cutover Readiness", "command": "tail -100 <source_file>"}


def extract_identity(line: str) -> Dict[str, str]:
    ip_match = re.search(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", line)
    vm_match = re.search(r"\b(?:vm|server|host|instance)[=: ]+([A-Za-z0-9_.-]+)", line, re.I)
    db_match = re.search(r"\b(?:db|database)[=: ]+([A-Za-z0-9_.-]+)", line, re.I)
    return {
        "ip": ip_match.group(0) if ip_match else "",
        "vm": vm_match.group(1) if vm_match else "",
        "db": db_match.group(1) if db_match else "",
    }


def read_interesting_lines(path: Path) -> List[str]:
    try:
        if path.suffix.lower() == ".json":
            payload = json.loads(path.read_text(encoding="utf-8", errors="replace"))
            text = json.dumps(payload, indent=2)
        else:
            text = path.read_text(encoding="utf-8", errors="replace")
    except Exception as exc:
        text = f"ERROR reading {path.name}: {exc}"
    lines = []
    for line in text.splitlines():
        upper = line.upper()
        if any(keyword in upper for keyword in KEYWORDS):
            lines.append(line.strip())
    return lines[:500]


def scan_log_findings(base_dir: Path) -> List[Dict[str, str]]:
    findings: List[Dict[str, str]] = []
    idx = 1
    for path in iter_log_files(base_dir):
        rel = path.relative_to(base_dir) if path.is_relative_to(base_dir) else path
        for line in read_interesting_lines(path):
            meta = classify(line)
            ident = extract_identity(line)
            findings.append({
                "finding_id": f"LOG-{idx:04d}",
                "timestamp": utc_now(),
                "source_file": rel.as_posix(),
                "stage": stage_from_path(path),
                "severity": meta["severity"],
                "category": meta["category"],
                "linked_system": ident.get("vm") or ident.get("db") or ident.get("ip") or "",
                "vm": ident.get("vm", ""),
                "db": ident.get("db", ""),
                "ip": ident.get("ip", ""),
                "message": line[:1000],
                "suggested_uat_test": meta["test"],
                "suggested_command": meta["command"].replace("<source_file>", rel.as_posix()),
                "status": "Open",
            })
            idx += 1
    return findings


def write_findings_csv(path: Path, findings: List[Dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=FINDING_FIELDS, extrasaction="ignore")
        writer.writeheader()
        for row in findings:
            writer.writerow({field: row.get(field, "") for field in FINDING_FIELDS})


def load_findings_csv(path: Path) -> List[Dict[str, str]]:
    if not path.exists():
        return []
    with path.open(newline="", encoding="utf-8-sig") as f:
        return [dict(row) for row in csv.DictReader(f)]


def save_or_scan_findings(base_dir: Path, force: bool = False) -> List[Dict[str, str]]:
    target = base_dir / "outputs" / "uat" / "uat_log_findings.csv"
    if target.exists() and not force:
        return load_findings_csv(target)
    findings = scan_log_findings(base_dir)
    write_findings_csv(target, findings)
    return findings
