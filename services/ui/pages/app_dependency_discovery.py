#!/usr/bin/env python3
"""Read-only App Dependency Discovery helpers.

The first version intentionally stays small: parse pasted Linux command output,
classify the workload, and write report artifacts for migration planning.
"""

from __future__ import annotations

import ipaddress
import json
import csv
import os
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List


PORT_HINTS = {
    "22": "SSH / admin access",
    "80": "HTTP web service",
    "443": "HTTPS web service",
    "5432": "PostgreSQL database",
    "3306": "MySQL / MariaDB database",
    "27017": "MongoDB database",
    "6379": "Redis cache",
    "9200": "Elasticsearch / OpenSearch",
    "5601": "Kibana / OpenSearch dashboard",
    "5672": "RabbitMQ",
    "9092": "Kafka",
    "8080": "Application / API service",
    "8443": "HTTPS application service",
    "5000": "Flask / API service",
    "8000": "Python app / API service",
    "9000": "App / MinIO / custom service",
}

DB_KEYWORDS = [
    "postgres",
    "postgresql",
    "mysql",
    "mysqld",
    "mariadb",
    "mongo",
    "mongodb",
    "mongod",
    "redis",
    "elasticsearch",
    "opensearch",
    "cassandra",
]

WEB_APP_KEYWORDS = [
    "nginx",
    "apache",
    "httpd",
    "gunicorn",
    "uwsgi",
    "node",
    "npm",
    "pm2",
    "java",
    "tomcat",
    "flask",
    "django",
    "uvicorn",
    "streamlit",
]

QUEUE_KEYWORDS = [
    "rabbitmq",
    "kafka",
    "celery",
    "sidekiq",
    "redis",
]

STORAGE_KEYWORDS = [
    "nfs",
    "smb",
    "minio",
    "ceph",
    "gluster",
]

IMPORTANT_MOUNT_PREFIXES = [
    "/var/lib/postgresql",
    "/var/lib/mysql",
    "/var/lib/mongodb",
    "/var/lib/docker",
    "/var/www",
    "/opt",
    "/data",
    "/app",
    "/srv",
    "/mnt",
]

SYSTEM_MOUNT_PREFIXES = (
    "/dev",
    "/proc",
    "/sys",
    "/run",
    "/boot",
    "/snap",
    "/var/lib/snapd",
)

COMMANDS = {
    "ss_tulpn": "ss -tulpn",
    "systemctl": "systemctl list-units --type=service --state=running",
    "df_h": "df -h",
    "lsblk": "lsblk",
    "fstab": "cat /etc/fstab",
    "ps_aux": "ps aux",
}

READONLY_SCAN_SCRIPT = """#!/usr/bin/env bash
set -o pipefail

echo "===== hostname ====="
hostname || true

echo "===== hostname_ip ====="
hostname -I || true

echo "===== os_release ====="
cat /etc/os-release || true

echo "===== uname ====="
uname -a || true

echo "===== ip_route ====="
ip route || true

echo "===== ip_addr ====="
ip addr || true

echo "===== ss_tulpn ====="
ss -tulpn || true

echo "===== systemctl_running ====="
systemctl list-units --type=service --state=running || true

echo "===== df_h ====="
df -h || true

echo "===== lsblk ====="
lsblk || true

echo "===== fstab ====="
cat /etc/fstab || true

echo "===== ps_aux ====="
ps aux || true
"""

SECRET_PATTERNS = [
    re.compile(r"(?i)(password|passwd|secret|token|api[_-]?key|access[_-]?key)\s*=\s*([^\s]+)"),
    re.compile(r"(?i)(DATABASE_URL|REDIS_URL|MYSQL_URL|POSTGRES_URL)=([^\s]+)"),
]


def ensure_tmp_runs() -> Path:
    repo_root = Path(__file__).resolve().parents[3]
    tmp_runs = repo_root / ".tmp_runs"
    tmp_runs.mkdir(parents=True, exist_ok=True)
    return tmp_runs


def write_readonly_scan_script() -> Path:
    script_path = ensure_tmp_runs() / "app_dependency_scan_script.sh"
    script_path.write_text(READONLY_SCAN_SCRIPT, encoding="utf-8")
    try:
        script_path.chmod(0o700)
    except OSError:
        pass
    return script_path


def mask_secrets(text: str) -> str:
    masked = text or ""
    for pattern in SECRET_PATTERNS:
        masked = pattern.sub(lambda match: f"{match.group(1)}=***MASKED***", masked)
    return masked


def _lines(text: str) -> Iterable[str]:
    for line in (text or "").splitlines():
        stripped = line.strip()
        if stripped:
            yield stripped


def _split_address_port(value: str) -> tuple[str, str]:
    local = (value or "").strip()
    local = local.strip('"')
    if not local:
        return "", ""
    if local.startswith("[") and "]:" in local:
        address, port = local.rsplit("]:", 1)
        return address.lstrip("["), port.strip()
    if ":" in local:
        address, port = local.rsplit(":", 1)
        return address.strip(), port.strip()
    return local, ""


def parse_listening_ports(ss_output: str) -> List[Dict[str, Any]]:
    ports: List[Dict[str, Any]] = []
    seen = set()
    for line in _lines(ss_output):
        if line.lower().startswith(("netid ", "state ", "recv-q ")):
            continue
        parts = line.split()
        if not parts or not parts[0].lower().startswith(("tcp", "udp")):
            continue
        protocol = parts[0]
        state = parts[1] if len(parts) > 1 else ""
        if protocol.lower().startswith("tcp") and state.upper() not in {"LISTEN", "UNCONN"}:
            continue

        local = parts[4] if len(parts) >= 5 else ""
        if not local:
            for token in parts[1:]:
                if ":" in token and not token.startswith("users:"):
                    local = token
                    break
        address, port = _split_address_port(local)
        if not port:
            continue

        process = ""
        process_match = re.search(r'users:\(\("([^"]+)"', line)
        if process_match:
            process = process_match.group(1)
        elif "users:" in line:
            process = line.split("users:", 1)[1].strip()

        key = (protocol, address, port, process, line)
        if key in seen:
            continue
        seen.add(key)
        ports.append(
            {
                "protocol": protocol,
                "state": state,
                "local_address": address,
                "port": port,
                "hint": PORT_HINTS.get(port, "Custom or unknown service"),
                "process": process,
                "raw": line,
            }
        )
    return ports


def parse_running_services(systemctl_output: str) -> List[Dict[str, str]]:
    services: List[Dict[str, str]] = []
    seen = set()
    for line in _lines(systemctl_output):
        clean = line.lstrip("●").strip()
        if not clean or clean.lower().startswith(("unit ", "load ", "active ", "legend:")):
            continue
        if ".service" not in clean:
            continue
        parts = clean.split(None, 4)
        if len(parts) < 4:
            continue
        unit = parts[0]
        if unit in seen:
            continue
        seen.add(unit)
        services.append(
            {
                "unit": unit,
                "load": parts[1],
                "active": parts[2],
                "sub": parts[3],
                "description": parts[4] if len(parts) > 4 else "",
                "raw": line,
            }
        )
    return services


def _is_important_mount(mountpoint: str) -> bool:
    mount = (mountpoint or "").strip()
    return any(mount == prefix or mount.startswith(prefix + "/") for prefix in IMPORTANT_MOUNT_PREFIXES)


def _is_system_mount(mountpoint: str) -> bool:
    mount = (mountpoint or "").strip()
    return mount in {"", "/", "/home"} or mount.startswith(SYSTEM_MOUNT_PREFIXES)


def parse_filesystems(df_output: str) -> List[Dict[str, Any]]:
    filesystems: List[Dict[str, Any]] = []
    for line in _lines(df_output):
        if line.lower().startswith("filesystem"):
            continue
        parts = line.split(None, 5)
        if len(parts) < 6:
            continue
        mountpoint = parts[5]
        filesystems.append(
            {
                "filesystem": parts[0],
                "size": parts[1],
                "used": parts[2],
                "available": parts[3],
                "use_percent": parts[4],
                "mountpoint": mountpoint,
                "is_root": mountpoint == "/",
                "is_extra_volume": not _is_system_mount(mountpoint),
                "important": _is_important_mount(mountpoint),
                "raw": line,
            }
        )
    return filesystems


def _clean_lsblk_name(name: str) -> str:
    return re.sub(r"^[`\-|+\\_\s]*", "", (name or "").replace("├─", "").replace("└─", "").replace("│", "")).strip()


def parse_block_devices(lsblk_output: str) -> List[Dict[str, Any]]:
    devices: List[Dict[str, Any]] = []
    for line in _lines(lsblk_output):
        if line.lower().startswith("name "):
            continue
        parts = line.split(None, 6)
        if len(parts) < 6:
            devices.append({"raw": line})
            continue
        name = _clean_lsblk_name(parts[0])
        mountpoint = parts[6] if len(parts) > 6 else ""
        devices.append(
            {
                "name": name,
                "device_path": f"/dev/{name}" if name and not name.startswith("/dev/") else name,
                "maj_min": parts[1],
                "removable": parts[2],
                "size": parts[3],
                "read_only": parts[4],
                "type": parts[5],
                "mountpoint": mountpoint,
                "important": _is_important_mount(mountpoint),
                "raw": line,
            }
        )
    return devices


def parse_fstab(fstab_output: str) -> List[Dict[str, Any]]:
    entries: List[Dict[str, Any]] = []
    for line in _lines(fstab_output):
        if line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 4:
            continue
        mountpoint = parts[1]
        entries.append(
            {
                "device": parts[0],
                "mountpoint": mountpoint,
                "filesystem": parts[2],
                "options": parts[3],
                "dump": parts[4] if len(parts) > 4 else "",
                "pass": parts[5] if len(parts) > 5 else "",
                "important": _is_important_mount(mountpoint),
                "raw": line,
            }
        )
    return entries


def parse_processes(ps_output: str) -> List[Dict[str, str]]:
    keywords_by_category = {
        "database": DB_KEYWORDS,
        "web_app": WEB_APP_KEYWORDS,
        "queue": QUEUE_KEYWORDS,
        "storage": STORAGE_KEYWORDS,
    }
    matches: List[Dict[str, str]] = []
    seen = set()
    for line in _lines(ps_output):
        lower = line.lower()
        if lower.startswith("user ") and "command" in lower:
            continue
        for category, keywords in keywords_by_category.items():
            for keyword in keywords:
                if re.search(rf"(^|[^a-z0-9_]){re.escape(keyword)}([^a-z0-9_]|$)", lower):
                    key = (category, keyword, line)
                    if key not in seen:
                        seen.add(key)
                        matches.append({"category": category, "keyword": keyword, "raw": line})
                    break
    return matches


def _ip_scope(ip_text: str) -> tuple[str, str]:
    ip_obj = ipaddress.ip_address(ip_text)
    if ip_obj.version == 4:
        if ip_obj in ipaddress.ip_network("10.0.0.0/8"):
            return "private", "10.0.0.0/8"
        if ip_obj in ipaddress.ip_network("172.16.0.0/12"):
            return "private", "172.16.0.0/12"
        if ip_obj in ipaddress.ip_network("192.168.0.0/16"):
            return "private", "192.168.0.0/16"
    return "public", "public"


def detect_external_ips(*texts: str) -> List[Dict[str, str]]:
    ignored = {"127.0.0.1", "0.0.0.0", "255.255.255.255"}
    found: Dict[str, Dict[str, str]] = {}
    for text in texts:
        for candidate in re.findall(r"\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b", text or ""):
            if candidate in ignored:
                continue
            try:
                ipaddress.ip_address(candidate)
            except ValueError:
                continue
            scope, network = _ip_scope(candidate)
            found[candidate] = {"ip": candidate, "scope": scope, "range": network}
    return [found[ip] for ip in sorted(found, key=lambda value: tuple(int(p) for p in value.split(".")))]


def _matching_keyword_hints(texts: Iterable[str], keywords: List[str], category: str) -> List[Dict[str, str]]:
    hits: List[Dict[str, str]] = []
    seen = set()
    for text in texts:
        lower = (text or "").lower()
        for keyword in keywords:
            if keyword in lower and keyword not in seen:
                seen.add(keyword)
                hits.append({"category": category, "keyword": keyword, "evidence": text[:220]})
    return hits


def detect_workload_hints(parsed: Dict[str, Any]) -> Dict[str, Any]:
    services = parsed.get("running_services") or []
    ports = parsed.get("listening_ports") or []
    processes = parsed.get("processes") or []
    filesystems = parsed.get("filesystems") or []
    fstab_entries = parsed.get("fstab_entries") or []

    evidence_texts = [p.get("raw", "") for p in processes]
    evidence_texts.extend(s.get("raw", "") for s in services)
    evidence_texts.extend(p.get("raw", "") for p in ports)

    hints = {
        "database": _matching_keyword_hints(evidence_texts, DB_KEYWORDS, "database"),
        "web_app": _matching_keyword_hints(evidence_texts, WEB_APP_KEYWORDS, "web_app"),
        "queue": _matching_keyword_hints(evidence_texts, QUEUE_KEYWORDS, "queue"),
        "storage": _matching_keyword_hints(evidence_texts, STORAGE_KEYWORDS, "storage"),
        "port_hints": [p for p in ports if p.get("port") in PORT_HINTS],
        "important_mounts": [],
    }

    mount_seen = set()
    for entry in [*filesystems, *fstab_entries]:
        mountpoint = entry.get("mountpoint", "")
        if mountpoint and _is_important_mount(mountpoint) and mountpoint not in mount_seen:
            mount_seen.add(mountpoint)
            hints["important_mounts"].append(
                {
                    "mountpoint": mountpoint,
                    "device": entry.get("filesystem") or entry.get("device") or "",
                    "source": "fstab" if "device" in entry else "df",
                    "recommendation": "These mount points may require volume migration and post-migration remount validation.",
                }
            )
    return hints


def classify_workload(parsed: Dict[str, Any], hints: Dict[str, Any]) -> Dict[str, Any]:
    ports = {str(p.get("port", "")) for p in parsed.get("listening_ports", [])}
    service_count = len(parsed.get("running_services") or [])
    detected_ips = parsed.get("detected_ips") or []
    important_mounts = hints.get("important_mounts") or []
    extra_volumes = [fs for fs in parsed.get("filesystems", []) if fs.get("is_extra_volume")]

    db_keywords = {h.get("keyword", "") for h in hints.get("database", [])}
    web_keywords = {h.get("keyword", "") for h in hints.get("web_app", [])}
    queue_keywords = {h.get("keyword", "") for h in hints.get("queue", [])}
    storage_keywords = {h.get("keyword", "") for h in hints.get("storage", [])}

    db_detected = bool(db_keywords or ports.intersection({"5432", "3306", "27017", "9200"}))
    non_admin_ports = ports - {"22"}
    redis_only = bool((db_keywords == {"redis"} or non_admin_ports == {"6379"}) and not (web_keywords or queue_keywords - {"redis"}))
    web_port_detected = bool(ports.intersection({"80", "443"}))
    app_port_detected = bool(ports.intersection({"8080", "8443", "5000", "8000", "9000"}))
    web_detected = bool(web_keywords or web_port_detected or app_port_detected)
    queue_detected = bool(queue_keywords or ports.intersection({"5672", "9092"}))
    storage_detected = bool(storage_keywords)

    reasons: List[str] = []
    if db_detected:
        reasons.append("Database process name or database port detected.")
    if web_detected:
        reasons.append("Web/application process name or HTTP/API port detected.")
    if queue_detected:
        reasons.append("Queue/cache indicator detected.")
    if storage_detected:
        reasons.append("Storage/file-service indicator detected.")
    if important_mounts:
        reasons.append("Important application/data mount point detected.")
    if detected_ips:
        reasons.append("IP addresses were found in pasted discovery output or notes.")

    if redis_only:
        workload_type = "cache_server"
    elif db_detected and web_detected:
        workload_type = "mixed_workload"
    elif web_port_detected and (db_detected or queue_detected or storage_detected):
        workload_type = "mixed_workload"
    elif web_port_detected:
        workload_type = "web_server"
    elif db_detected:
        workload_type = "database_server"
    elif web_detected:
        workload_type = "app_server"
    elif queue_detected:
        workload_type = "message_queue"
    elif storage_detected:
        workload_type = "storage_node"
    else:
        workload_type = "unknown"
        reasons.append("No known database, web/app, queue, or storage indicators were found.")

    if workload_type == "unknown":
        confidence = "low"
    elif ports or service_count or hints.get("database") or hints.get("web_app"):
        confidence = "medium"
    else:
        confidence = "low"
    if (db_detected and ports) or (web_detected and service_count):
        confidence = "high"

    if (
        workload_type in {"database_server", "mixed_workload"}
        or len(important_mounts) > 1
        or len(extra_volumes) > 2
        or len(detected_ips) > 5
        or (workload_type == "unknown" and bool(detected_ips))
    ):
        complexity = "high"
    elif (workload_type in {"web_server", "app_server"} and (important_mounts or extra_volumes)) or workload_type in {"message_queue", "storage_node", "cache_server"}:
        complexity = "medium"
    elif service_count <= 1 and not important_mounts and not db_detected:
        complexity = "low"
    else:
        complexity = "medium"

    return {
        "type": workload_type,
        "confidence": confidence,
        "migration_complexity": complexity,
        "reasons": reasons,
    }


def _volume_migration_hints(parsed: Dict[str, Any], hints: Dict[str, Any]) -> List[Dict[str, str]]:
    fstab_mounts = {entry.get("mountpoint", "") for entry in parsed.get("fstab_entries", [])}
    rows: List[Dict[str, str]] = []
    seen = set()
    for fs in parsed.get("filesystems", []) or []:
        mountpoint = fs.get("mountpoint", "")
        if not mountpoint or mountpoint in seen:
            continue
        if fs.get("important") or fs.get("is_extra_volume"):
            seen.add(mountpoint)
            rows.append(
                {
                    "mountpoint": mountpoint,
                    "device": fs.get("filesystem", ""),
                    "size": fs.get("size", ""),
                    "used": fs.get("used", ""),
                    "fstab_persistent": "yes" if mountpoint in fstab_mounts else "unknown",
                    "recommendation": "These mount points may require volume migration and post-migration remount validation.",
                }
            )
    for mount in hints.get("important_mounts", []) or []:
        mountpoint = mount.get("mountpoint", "")
        if mountpoint and mountpoint not in seen:
            rows.append(
                {
                    "mountpoint": mountpoint,
                    "device": mount.get("device", ""),
                    "size": "",
                    "used": "",
                    "fstab_persistent": "yes" if mountpoint in fstab_mounts else "unknown",
                    "recommendation": mount.get("recommendation", ""),
                }
            )
    return rows


def build_app_dependency_report(
    source_vm: Dict[str, str],
    raw_outputs: Dict[str, str],
    parsed: Dict[str, Any],
    hints: Dict[str, Any],
) -> Dict[str, Any]:
    classification = classify_workload(parsed, hints)
    volume_hints = _volume_migration_hints(parsed, hints)

    risks: List[str] = []
    validations = [
        "Verify VM boot",
        "Verify network reachability",
        "Verify service startup",
        "Verify listening ports",
        "Verify volume mounts",
    ]
    if hints.get("database"):
        risks.append("Database workload detected. Plan snapshot consistency, volume migration, and database validation before cutover.")
        validations.append("Verify database query if database workload")
    if hints.get("web_app"):
        validations.append("Verify HTTP/API health endpoint if app workload")
    if volume_hints:
        risks.append("Important data mounts detected. Validate volume attachment and fstab remounts on FLEX/HYPERFLEX.")
    if parsed.get("detected_ips"):
        risks.append("External or private IP references detected. Review source OSPC, hyperscaler, and FLEX network reachability.")
    if classification["type"] == "mixed_workload":
        risks.append("Mixed workload detected. Consider separating app, database, cache, and queue validation steps.")

    return {
        "stage": "discovery",
        "feature": "app_dependency_discovery",
        "source_vm": {
            "name": source_vm.get("name", ""),
            "id": source_vm.get("id", ""),
            "ip": source_vm.get("ip", ""),
            "cloud": source_vm.get("cloud", ""),
            "region": source_vm.get("region", ""),
        },
        "commands": COMMANDS,
        "listening_ports": parsed.get("listening_ports", []),
        "running_services": parsed.get("running_services", []),
        "filesystems": parsed.get("filesystems", []),
        "block_devices": parsed.get("block_devices", []),
        "fstab_entries": parsed.get("fstab_entries", []),
        "process_hints": {
            "database": hints.get("database", []),
            "web_app": hints.get("web_app", []),
            "queue": hints.get("queue", []),
            "storage": hints.get("storage", []),
        },
        "detected_ips": parsed.get("detected_ips", []),
        "workload_classification": classification,
        "volume_migration_hints": volume_hints,
        "migration_risks": risks,
        "recommended_validation_after_migration": validations,
        "created_at": datetime.now(timezone.utc).isoformat(),
    }


def _wave_for_report(report: Dict[str, Any]) -> tuple[str, str, str]:
    classification = report.get("workload_classification") or {}
    workload_type = classification.get("type", "unknown")
    complexity = classification.get("migration_complexity", "medium")
    ports = {str(p.get("port", "")) for p in report.get("listening_ports", [])}
    db_detected = bool(report.get("process_hints", {}).get("database") or ports.intersection({"5432", "3306", "27017", "9200"}))
    important_mounts = report.get("volume_migration_hints") or []
    detected_ips = report.get("detected_ips") or []

    if workload_type == "mixed_workload" or (complexity == "high" and (len(detected_ips) > 5 or workload_type == "unknown")):
        return (
            "Wave 4 - Mixed or high-risk workload.",
            "Mixed services, high complexity, many IP dependencies, or uncertain classification detected.",
            "Break this VM into an explicit app, data, network, and validation checklist before cutover.",
        )
    if db_detected or workload_type == "database_server" or any("/var/lib/" in h.get("mountpoint", "") for h in important_mounts):
        return (
            "Wave 3 - Stateful database workload.",
            "Database indicators, database ports, or database data directories were detected.",
            "Plan snapshot consistency, volume migration, and database validation before cutover.",
        )
    if workload_type in {"web_server", "app_server"} and important_mounts:
        return (
            "Wave 2 - App/web server with attached data.",
            "Application service and mounted data path were detected.",
            "Migrate after stateless services and validate mounted data paths plus HTTP/API health.",
        )
    return (
        "Wave 1 - Low-risk stateless service.",
        "No database or important attached data volume was detected.",
        "Move early after basic network and service validation.",
    )


def _md_list(items: List[str]) -> str:
    return "\n".join(f"- {item}" for item in items) if items else "- None detected"


def build_migration_wave_recommendation(report: Dict[str, Any]) -> str:
    source = report.get("source_vm") or {}
    classification = report.get("workload_classification") or {}
    wave, reason, action = _wave_for_report(report)
    ports = report.get("listening_ports") or []
    services = report.get("running_services") or []
    volumes = report.get("volume_migration_hints") or []
    hints = report.get("process_hints") or {}
    ips = report.get("detected_ips") or []

    port_lines = [
        f"{p.get('protocol', '')}/{p.get('port', '')} on {p.get('local_address', '')} - {p.get('hint', '')}".strip()
        for p in ports
    ]
    service_lines = [s.get("unit", "") for s in services if s.get("unit")]
    volume_lines = [
        f"{v.get('mountpoint', '')} ({v.get('device', '')}, {v.get('size', '')})".strip()
        for v in volumes
    ]
    db_lines = [h.get("keyword", "") for h in hints.get("database", [])]
    web_lines = [h.get("keyword", "") for h in hints.get("web_app", [])]
    ip_lines = [f"{ip.get('ip')} ({ip.get('scope')})" for ip in ips]

    return f"""# Migration Wave Recommendation

## Source VM

- Name: {source.get("name", "")}
- IP: {source.get("ip", "")}
- Cloud: {source.get("cloud", "")}
- Region: {source.get("region", "")}

## Detected Workload

- Type: {classification.get("type", "")}
- Complexity: {classification.get("migration_complexity", "")}
- Confidence: {classification.get("confidence", "")}

## Key Dependencies

### Listening Ports

{_md_list(port_lines)}

### Running Services

{_md_list(service_lines)}

### Mounted Volumes

{_md_list(volume_lines)}

### Database Indicators

{_md_list(db_lines)}

### Web/App Indicators

{_md_list(web_lines)}

### External IPs

{_md_list(ip_lines)}

## Recommended Migration Wave

Wave recommendation:

- Wave 1: Low-risk stateless services
- Wave 2: App servers with attached data
- Wave 3: Database or stateful services
- Wave 4: Mixed or high-risk workloads

Recommended Wave: {wave}
Reason: {reason}

## Recommended Action

{action}

## Post-Migration Validation

- Verify VM boot
- Verify network reachability
- Verify service startup
- Verify listening ports
- Verify volume mounts
- Verify database query if database workload
- Verify HTTP/API health endpoint if app workload
"""


def write_app_dependency_artifacts(report: Dict[str, Any], recommendation_md: str) -> Dict[str, str]:
    tmp_runs = ensure_tmp_runs()
    report_path = tmp_runs / "app_dependency_report.json"
    recommendation_path = tmp_runs / "migration_wave_recommendation.md"
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    recommendation_path.write_text(recommendation_md, encoding="utf-8")
    return {
        "report_path": str(report_path),
        "recommendation_path": str(recommendation_path),
    }


def analyze_app_dependency_payload(payload: Dict[str, Any]) -> Dict[str, Any]:
    source_vm = payload.get("source_vm") or {}
    raw_outputs = payload.get("raw_outputs") or {}
    notes = raw_outputs.get("notes", "")
    parsed = {
        "listening_ports": parse_listening_ports(raw_outputs.get("ss_tulpn", "")),
        "running_services": parse_running_services(raw_outputs.get("systemctl", "")),
        "filesystems": parse_filesystems(raw_outputs.get("df_h", "")),
        "block_devices": parse_block_devices(raw_outputs.get("lsblk", "")),
        "fstab_entries": parse_fstab(raw_outputs.get("fstab", "")),
        "processes": parse_processes(raw_outputs.get("ps_aux", "")),
    }
    parsed["detected_ips"] = detect_external_ips(
        raw_outputs.get("ss_tulpn", ""),
        raw_outputs.get("ps_aux", ""),
        raw_outputs.get("ip_route", ""),
        raw_outputs.get("ip_addr", ""),
        notes,
        source_vm.get("ip", ""),
    )
    hints = detect_workload_hints(parsed)
    report = build_app_dependency_report(source_vm, raw_outputs, parsed, hints)
    recommendation_md = build_migration_wave_recommendation(report)
    artifacts = write_app_dependency_artifacts(report, recommendation_md)
    return {
        "report": report,
        "recommendation_markdown": recommendation_md,
        "artifacts": artifacts,
    }


def split_command_output(raw_output: str) -> Dict[str, str]:
    sections: Dict[str, List[str]] = {}
    current = "raw"
    sections[current] = []
    for line in (raw_output or "").splitlines():
        match = re.match(r"^===== ([a-zA-Z0-9_ -]+) =====$", line.strip())
        if match:
            current = match.group(1).strip().lower().replace("-", "_").replace(" ", "_")
            sections.setdefault(current, [])
            continue
        sections.setdefault(current, []).append(line)
    return {key: mask_secrets("\n".join(lines).strip()) for key, lines in sections.items()}


def run_remote_readonly_commands(vm: Dict[str, Any], ssh_profile: Dict[str, Any]) -> Dict[str, Any]:
    write_readonly_scan_script()
    ip = str(vm.get("ip") or vm.get("ip_address") or vm.get("managementip") or "").strip()
    user = str(ssh_profile.get("username") or ssh_profile.get("user") or "ubuntu").strip() or "ubuntu"
    port = str(ssh_profile.get("port") or "22").strip() or "22"
    key_raw = str(
        ssh_profile.get("key_path")
        or ssh_profile.get("private_key_path")
        or ssh_profile.get("ssh_key_path")
        or ssh_profile.get("key_profile")
        or ""
    ).strip()

    if not ip:
        return {"status": "SCAN_FAILED", "error": "VM IP address is required for SSH scan.", "outputs": {}}
    if not key_raw:
        return {
            "status": "SCAN_FAILED",
            "error": "SSH key path or key profile is required. Use Advanced: Manual Paste Mode if SSH is unavailable.",
            "outputs": {},
        }

    key_path = os.path.expanduser(key_raw)
    if not Path(key_path).exists():
        return {
            "status": "SCAN_FAILED",
            "error": "SSH key path was not found. Check the key profile/path and retry.",
            "outputs": {},
        }

    cmd = [
        "ssh",
        "-i",
        key_path,
        "-p",
        port,
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "ConnectTimeout=10",
        f"{user}@{ip}",
        "bash -s",
    ]
    try:
        proc = subprocess.run(
            cmd,
            input=READONLY_SCAN_SCRIPT,
            text=True,
            capture_output=True,
            timeout=int(ssh_profile.get("timeout") or 45),
            check=False,
        )
    except subprocess.TimeoutExpired:
        return {
            "status": "SCAN_FAILED",
            "error": "Could not connect to VM before timeout. Check IP, SSH username, key, security group, and route.",
            "outputs": {},
        }
    except OSError as exc:
        return {"status": "SCAN_FAILED", "error": f"SSH execution failed: {exc}", "outputs": {}}

    raw = mask_secrets((proc.stdout or "") + ("\n" + proc.stderr if proc.stderr else ""))
    if proc.returncode != 0:
        return {
            "status": "SCAN_FAILED",
            "return_code": proc.returncode,
            "error": "Could not connect to VM. Check IP, SSH username, key, security group, and route.",
            "raw_output": raw,
            "outputs": split_command_output(raw),
        }
    outputs = split_command_output(raw)
    missing = [name for name in ("ss_tulpn", "systemctl_running", "df_h", "lsblk", "fstab", "ps_aux") if not outputs.get(name)]
    return {
        "status": "PARTIAL_RESULT" if missing else "SCAN_COMPLETE",
        "return_code": proc.returncode,
        "missing_sections": missing,
        "raw_output": raw,
        "outputs": outputs,
    }


def parse_appdep_outputs(vm: Dict[str, Any], outputs: Dict[str, str]) -> Dict[str, Any]:
    outputs = outputs or {}
    raw_outputs = {
        "ss_tulpn": outputs.get("ss_tulpn", ""),
        "systemctl": outputs.get("systemctl_running", "") or outputs.get("systemctl", ""),
        "df_h": outputs.get("df_h", ""),
        "lsblk": outputs.get("lsblk", ""),
        "fstab": outputs.get("fstab", ""),
        "ps_aux": outputs.get("ps_aux", ""),
        "ip_route": outputs.get("ip_route", ""),
        "ip_addr": outputs.get("ip_addr", ""),
        "notes": outputs.get("hostname", ""),
        "os_release": outputs.get("os_release", ""),
        "uname": outputs.get("uname", ""),
    }
    parsed = {
        "raw_outputs": raw_outputs,
        "listening_ports": parse_listening_ports(raw_outputs["ss_tulpn"]),
        "running_services": parse_running_services(raw_outputs["systemctl"]),
        "filesystems": parse_filesystems(raw_outputs["df_h"]),
        "block_devices": parse_block_devices(raw_outputs["lsblk"]),
        "fstab_entries": parse_fstab(raw_outputs["fstab"]),
        "processes": parse_processes(raw_outputs["ps_aux"]),
    }
    parsed["detected_ips"] = detect_external_ips(
        raw_outputs["ss_tulpn"],
        raw_outputs["ps_aux"],
        raw_outputs["ip_route"],
        raw_outputs["ip_addr"],
        outputs.get("hostname_ip", ""),
        str(vm.get("ip", "")),
    )
    parsed["hints"] = detect_workload_hints(parsed)
    return parsed


def classify_appdep_vm(parsed: Dict[str, Any]) -> Dict[str, Any]:
    hints = parsed.get("hints") or detect_workload_hints(parsed)
    classification = classify_workload(parsed, hints)
    return {
        "workload_type": classification.get("type", "unknown"),
        "complexity": classification.get("migration_complexity", "unknown"),
        "confidence": classification.get("confidence", "low"),
        "reasons": classification.get("reasons", []),
    }


def _keywords_for_category(hints: Dict[str, Any], category: str) -> List[str]:
    values = []
    seen = set()
    for item in hints.get(category, []) or []:
        keyword = str(item.get("keyword", "")).strip()
        if keyword and keyword not in seen:
            seen.add(keyword)
            values.append(keyword)
    return values


def _database_services(parsed: Dict[str, Any]) -> List[Dict[str, str]]:
    hints = parsed.get("hints") or {}
    rows: List[Dict[str, str]] = []
    db_ports = {"5432": "PostgreSQL", "3306": "MySQL / MariaDB", "27017": "MongoDB", "6379": "Redis", "9200": "Elasticsearch / OpenSearch"}
    for port in parsed.get("listening_ports", []) or []:
        port_num = str(port.get("port", ""))
        if port_num in db_ports:
            rows.append(
                {
                    "db_type": db_ports[port_num],
                    "port": port_num,
                    "process": port.get("process", ""),
                    "data_path_hint": "",
                    "risk": "Stateful service. Validate data consistency and query after migration.",
                }
            )
    for keyword in _keywords_for_category(hints, "database"):
        if not any(keyword.lower() in (row.get("db_type", "") + row.get("process", "")).lower() for row in rows):
            rows.append(
                {
                    "db_type": keyword,
                    "port": "",
                    "process": keyword,
                    "data_path_hint": "",
                    "risk": "Database process indicator detected.",
                }
            )
    for row in rows:
        for mount in hints.get("important_mounts", []) or []:
            mountpoint = mount.get("mountpoint", "")
            if any(db_word in mountpoint for db_word in ("postgres", "mysql", "mongodb")):
                row["data_path_hint"] = mountpoint
                break
    return rows


def build_appdep_scan_result(vm: Dict[str, Any], parsed: Dict[str, Any], classification: Dict[str, Any]) -> Dict[str, Any]:
    hints = parsed.get("hints") or {}
    source_vm = {
        "name": str(vm.get("name") or vm.get("hostname") or ""),
        "id": str(vm.get("id") or vm.get("instance_id") or ""),
        "ip": str(vm.get("ip") or vm.get("ip_address") or vm.get("managementip") or ""),
        "cloud": str(vm.get("cloud") or vm.get("source_cloud") or ""),
        "region": str(vm.get("region") or ""),
        "status": str(vm.get("status") or ""),
        "flavor": str(vm.get("flavor") or ""),
        "image": str(vm.get("image") or vm.get("os") or ""),
    }
    report = build_app_dependency_report(source_vm, parsed.get("raw_outputs", {}), parsed, hints)
    wave, _, _ = _wave_for_report(report)
    normalized_classification = {
        "workload_type": classification.get("workload_type") or report.get("workload_classification", {}).get("type", "unknown"),
        "complexity": classification.get("complexity") or report.get("workload_classification", {}).get("migration_complexity", "unknown"),
        "confidence": classification.get("confidence") or report.get("workload_classification", {}).get("confidence", "low"),
        "recommended_wave": wave,
        "reasons": classification.get("reasons") or report.get("workload_classification", {}).get("reasons", []),
    }
    return {
        "vm": source_vm,
        "classification": normalized_classification,
        "dependencies": {
            "listening_ports": parsed.get("listening_ports", []),
            "running_services": parsed.get("running_services", []),
            "database_services": _database_services(parsed),
            "web_services": _keywords_for_category(hints, "web_app"),
            "queue_services": _keywords_for_category(hints, "queue"),
            "storage_services": _keywords_for_category(hints, "storage"),
            "external_ips": parsed.get("detected_ips", []),
        },
        "volumes": {
            "block_devices": parsed.get("block_devices", []),
            "filesystems": parsed.get("filesystems", []),
            "fstab_entries": parsed.get("fstab_entries", []),
            "important_mounts": hints.get("important_mounts", []),
        },
        "risks": report.get("migration_risks", []),
        "post_migration_validation": report.get("recommended_validation_after_migration", []),
        "raw_evidence": parsed.get("raw_outputs", {}),
        "status": str(vm.get("scan_status") or "SCAN_COMPLETE"),
    }


def run_appdep_scan_for_selected_vms(vms: List[Dict[str, Any]], ssh_profile: Dict[str, Any]) -> List[Dict[str, Any]]:
    results: List[Dict[str, Any]] = []
    for vm in vms or []:
        scan = run_remote_readonly_commands(vm, ssh_profile or {})
        vm_with_status = dict(vm)
        vm_with_status["scan_status"] = scan.get("status", "SCAN_FAILED")
        if scan.get("outputs"):
            parsed = parse_appdep_outputs(vm_with_status, scan.get("outputs", {}))
            classification = classify_appdep_vm(parsed)
            result = build_appdep_scan_result(vm_with_status, parsed, classification)
            result["status"] = scan.get("status", "SCAN_COMPLETE")
            if scan.get("error"):
                result.setdefault("risks", []).append(scan.get("error", "Scan failed."))
            results.append(result)
        else:
            results.append(
                {
                    "vm": {
                        "name": str(vm.get("name") or vm.get("hostname") or ""),
                        "id": str(vm.get("id") or vm.get("instance_id") or ""),
                        "ip": str(vm.get("ip") or vm.get("ip_address") or vm.get("managementip") or ""),
                        "cloud": str(vm.get("cloud") or vm.get("source_cloud") or ""),
                        "region": str(vm.get("region") or ""),
                        "status": str(vm.get("status") or ""),
                        "flavor": str(vm.get("flavor") or ""),
                        "image": str(vm.get("image") or vm.get("os") or ""),
                    },
                    "classification": {
                        "workload_type": "unknown",
                        "complexity": "unknown",
                        "confidence": "low",
                        "recommended_wave": "Manual review required",
                        "reasons": [scan.get("error", "Scan failed.")],
                    },
                    "dependencies": {
                        "listening_ports": [],
                        "running_services": [],
                        "database_services": [],
                        "web_services": [],
                        "queue_services": [],
                        "storage_services": [],
                        "external_ips": [],
                    },
                    "volumes": {"block_devices": [], "filesystems": [], "fstab_entries": [], "important_mounts": []},
                    "risks": [scan.get("error", "Scan failed.")],
                    "post_migration_validation": [],
                    "raw_evidence": {},
                    "status": "SCAN_FAILED",
                }
            )
    return results


def _summary_rows(results: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    for result in results or []:
        vm = result.get("vm") or {}
        deps = result.get("dependencies") or {}
        vols = result.get("volumes") or {}
        classification = result.get("classification") or {}
        db_names = [row.get("db_type", "") for row in deps.get("database_services", []) if row.get("db_type")]
        ports = [str(row.get("port", "")) for row in deps.get("listening_ports", []) if row.get("port")]
        rows.append(
            {
                "VM Name": vm.get("name", ""),
                "Instance ID": vm.get("id", ""),
                "IP": vm.get("ip", ""),
                "Cloud": vm.get("cloud", ""),
                "Region": vm.get("region", ""),
                "Workload Type": classification.get("workload_type", ""),
                "DB": ", ".join(db_names) if db_names else "No",
                "Web/API": ", ".join(deps.get("web_services", []) or []) or "No",
                "Ports": ",".join(ports),
                "Important Mounts": ", ".join(m.get("mountpoint", "") for m in vols.get("important_mounts", []) if m.get("mountpoint")),
                "Volumes": len(vols.get("block_devices", []) or []),
                "Complexity": classification.get("complexity", ""),
                "Recommended Wave": classification.get("recommended_wave", ""),
                "Status": result.get("status", ""),
            }
        )
    return rows


def _build_wave_plan(results: List[Dict[str, Any]]) -> Dict[str, Any]:
    waves = {"Wave 1": [], "Wave 2": [], "Wave 3": [], "Wave 4": [], "Manual Review": []}
    for result in results or []:
        vm = result.get("vm") or {}
        wave = str((result.get("classification") or {}).get("recommended_wave") or "")
        key = "Manual Review"
        for candidate in ("Wave 1", "Wave 2", "Wave 3", "Wave 4"):
            if wave.startswith(candidate):
                key = candidate
                break
        waves[key].append(
            {
                "name": vm.get("name", ""),
                "id": vm.get("id", ""),
                "ip": vm.get("ip", ""),
                "workload_type": (result.get("classification") or {}).get("workload_type", ""),
                "complexity": (result.get("classification") or {}).get("complexity", ""),
                "risks": result.get("risks", []),
            }
        )
    return {"stage": "discovery", "feature": "app_dependency_auto_discovery", "waves": waves, "created_at": datetime.now(timezone.utc).isoformat()}


def _stage2_path_for_result(result: Dict[str, Any]) -> Dict[str, str]:
    vm = result.get("vm") or {}
    classification = result.get("classification") or {}
    cloud = str(vm.get("cloud") or "").strip().lower()
    workload = str(classification.get("workload_type") or "").strip().lower()
    complexity = str(classification.get("complexity") or "").strip().lower()

    if cloud in {"aws", "azure", "gcp"}:
        return {
            "substage": "s2flexanywhere",
            "label": "R3 HYPER FLEX - Hyperscaler Bridge",
            "reason": "Source cloud is a hyperscaler environment.",
        }
    if cloud == "flex":
        return {
            "substage": "s2flex2flex",
            "label": "R3 FLEX2FLEX-Region Cloning",
            "reason": "Source cloud is FLEX.",
        }
    if workload in {"database_server", "mixed_workload", "message_queue", "storage_node"} or complexity == "high":
        return {
            "substage": "s2rehost_p2_1",
            "label": "R5 Replatform - App & DB Replication",
            "reason": "Stateful, mixed, or high-complexity workload detected.",
        }
    return {
        "substage": "s2image",
        "label": "R3 Rehost / Relocate - VM Lift & Shift",
        "reason": "VM appears suitable for lift-and-shift planning.",
    }


def build_stage2_readiness(result: Dict[str, Any]) -> Dict[str, Any]:
    vm = result.get("vm") or {}
    classification = result.get("classification") or {}
    deps = result.get("dependencies") or {}
    vols = result.get("volumes") or {}

    blockers: List[str] = []
    review_notes: List[str] = []

    if result.get("status") == "SCAN_FAILED":
        blockers.append("Dependency scan failed. Check SSH route, username, key, security group, and source VM reachability.")
    if not str(vm.get("ip") or "").strip():
        blockers.append("No reachable VM IP is available for dependency validation.")

    databases = deps.get("database_services") or []
    important_mounts = vols.get("important_mounts") or []
    block_devices = vols.get("block_devices") or []
    filesystems = vols.get("filesystems") or []
    fstab_entries = vols.get("fstab_entries") or []
    external_ips = deps.get("external_ips") or []
    workload = str(classification.get("workload_type") or "").strip()
    complexity = str(classification.get("complexity") or "").strip().lower()

    if databases and not (important_mounts or block_devices or filesystems):
        review_notes.append("Database detected but no volume or mount mapping was found. Confirm data location before Stage 2.")
    if workload == "mixed_workload":
        review_notes.append("Mixed workload detected. Split app, DB, cache, and queue validation before migration.")
    if important_mounts:
        fstab_mounts = {str(entry.get("mountpoint") or "") for entry in fstab_entries}
        missing = [m.get("mountpoint", "") for m in important_mounts if m.get("mountpoint") and m.get("mountpoint") not in fstab_mounts]
        if missing:
            review_notes.append("Important mount found without matching fstab entry: " + ", ".join(missing))
    if external_ips:
        review_notes.append("External or private IP dependencies detected. Validate routing, allow lists, DNS, and firewall rules.")
    if complexity == "high":
        review_notes.append("High migration complexity. Require manual review before cutover scheduling.")

    if blockers:
        status = "Blocked"
    elif review_notes:
        status = "Needs Review"
    else:
        status = "Ready for Stage 2"

    return {
        "status": status,
        "blockers": blockers,
        "review_notes": review_notes,
        "recommended_action": "Resolve blockers before Stage 2." if blockers else (
            "Review notes, then approve Stage 2 plan." if review_notes else "Promote to Stage 2 migration planning."
        ),
    }


def build_stage2_migration_candidates(results: List[Dict[str, Any]]) -> Dict[str, Any]:
    candidates: List[Dict[str, Any]] = []
    for result in results or []:
        vm = result.get("vm") or {}
        classification = result.get("classification") or {}
        deps = result.get("dependencies") or {}
        vols = result.get("volumes") or {}
        readiness = build_stage2_readiness(result)
        stage2_path = _stage2_path_for_result(result)
        candidates.append(
            {
                "source": "app_dependency_discovery",
                "vm": vm,
                "classification": classification,
                "readiness": readiness,
                "stage2_path": stage2_path,
                "dependencies": {
                    "listening_ports": deps.get("listening_ports", []),
                    "running_services": deps.get("running_services", []),
                    "database_services": deps.get("database_services", []),
                    "web_services": deps.get("web_services", []),
                    "queue_services": deps.get("queue_services", []),
                    "storage_services": deps.get("storage_services", []),
                    "external_ips": deps.get("external_ips", []),
                },
                "volumes": {
                    "block_devices": vols.get("block_devices", []),
                    "filesystems": vols.get("filesystems", []),
                    "fstab_entries": vols.get("fstab_entries", []),
                    "important_mounts": vols.get("important_mounts", []),
                },
                "risks": result.get("risks", []),
                "post_migration_validation": result.get("post_migration_validation", []),
                "stage2_inputs": {
                    "source_vm_name": vm.get("name", ""),
                    "source_vm_id": vm.get("id", ""),
                    "source_vm_ip": vm.get("ip", ""),
                    "source_cloud": vm.get("cloud", ""),
                    "source_region": vm.get("region", ""),
                    "recommended_wave": classification.get("recommended_wave", ""),
                    "recommended_stage2_substage": stage2_path.get("substage", ""),
                },
            }
        )
    return {
        "stage": "stage2",
        "feature": "app_dependency_stage2_handoff",
        "created_at": datetime.now(timezone.utc).isoformat(),
        "candidate_count": len(candidates),
        "ready_count": sum(1 for item in candidates if item.get("readiness", {}).get("status") == "Ready for Stage 2"),
        "needs_review_count": sum(1 for item in candidates if item.get("readiness", {}).get("status") == "Needs Review"),
        "blocked_count": sum(1 for item in candidates if item.get("readiness", {}).get("status") == "Blocked"),
        "candidates": candidates,
    }


def export_stage2_migration_candidates(results: List[Dict[str, Any]]) -> tuple[Dict[str, Any], Dict[str, str]]:
    tmp_runs = ensure_tmp_runs()
    payload = build_stage2_migration_candidates(results or [])
    json_path = tmp_runs / "stage2_migration_candidates.json"
    csv_path = tmp_runs / "stage2_migration_candidates.csv"
    md_path = tmp_runs / "stage2_migration_wave_plan.md"

    json_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    fieldnames = [
        "VM Name",
        "Instance ID",
        "IP",
        "Cloud",
        "Region",
        "Readiness",
        "Recommended Stage 2 Path",
        "Recommended Wave",
        "Workload Type",
        "Complexity",
        "Ports",
        "Databases",
        "Important Mounts",
        "Blockers",
        "Review Notes",
    ]
    with csv_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for item in payload["candidates"]:
            vm = item.get("vm") or {}
            cls = item.get("classification") or {}
            deps = item.get("dependencies") or {}
            vols = item.get("volumes") or {}
            readiness = item.get("readiness") or {}
            writer.writerow(
                {
                    "VM Name": vm.get("name", ""),
                    "Instance ID": vm.get("id", ""),
                    "IP": vm.get("ip", ""),
                    "Cloud": vm.get("cloud", ""),
                    "Region": vm.get("region", ""),
                    "Readiness": readiness.get("status", ""),
                    "Recommended Stage 2 Path": (item.get("stage2_path") or {}).get("label", ""),
                    "Recommended Wave": cls.get("recommended_wave", ""),
                    "Workload Type": cls.get("workload_type", ""),
                    "Complexity": cls.get("complexity", ""),
                    "Ports": ",".join(str(p.get("port", "")) for p in deps.get("listening_ports", []) if p.get("port")),
                    "Databases": ", ".join(str(db.get("db_type", "")) for db in deps.get("database_services", []) if db.get("db_type")),
                    "Important Mounts": ", ".join(str(m.get("mountpoint", "")) for m in vols.get("important_mounts", []) if m.get("mountpoint")),
                    "Blockers": " | ".join(readiness.get("blockers", []) or []),
                    "Review Notes": " | ".join(readiness.get("review_notes", []) or []),
                }
            )

    md_lines = [
        "# Stage 2 Migration Candidate Handoff",
        "",
        f"Created: {payload['created_at']}",
        "",
        f"- Candidates: {payload['candidate_count']}",
        f"- Ready for Stage 2: {payload['ready_count']}",
        f"- Needs Review: {payload['needs_review_count']}",
        f"- Blocked: {payload['blocked_count']}",
        "",
    ]
    for item in payload["candidates"]:
        vm = item.get("vm") or {}
        cls = item.get("classification") or {}
        readiness = item.get("readiness") or {}
        path = item.get("stage2_path") or {}
        md_lines.extend(
            [
                f"## {vm.get('name') or vm.get('id') or vm.get('ip') or 'Unnamed VM'}",
                "",
                f"- IP: {vm.get('ip', '')}",
                f"- Cloud / Region: {vm.get('cloud', '')} / {vm.get('region', '')}",
                f"- Workload: {cls.get('workload_type', '')}",
                f"- Complexity: {cls.get('complexity', '')}",
                f"- Recommended Wave: {cls.get('recommended_wave', '')}",
                f"- Stage 2 Path: {path.get('label', '')}",
                f"- Readiness: {readiness.get('status', '')}",
                f"- Blockers: {'; '.join(readiness.get('blockers', []) or []) or 'None'}",
                f"- Review Notes: {'; '.join(readiness.get('review_notes', []) or []) or 'None'}",
                "",
            ]
        )
    md_path.write_text("\n".join(md_lines), encoding="utf-8")

    return payload, {
        "stage2_migration_candidates.json": str(json_path),
        "stage2_migration_candidates.csv": str(csv_path),
        "stage2_migration_wave_plan.md": str(md_path),
    }


def load_stage2_migration_candidates() -> Dict[str, Any]:
    path = ensure_tmp_runs() / "stage2_migration_candidates.json"
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def export_appdep_reports(results: List[Dict[str, Any]]) -> Dict[str, str]:
    tmp_runs = ensure_tmp_runs()
    write_readonly_scan_script()
    report_path = tmp_runs / "app_dependency_report.json"
    summary_path = tmp_runs / "app_dependency_summary.csv"
    recommendation_path = tmp_runs / "migration_wave_recommendation.md"
    wave_json_path = tmp_runs / "app_dependency_wave_plan.json"
    wave_md_path = tmp_runs / "app_dependency_wave_plan.md"

    payload = {
        "stage": "discovery",
        "feature": "app_dependency_auto_discovery",
        "created_at": datetime.now(timezone.utc).isoformat(),
        "results": results or [],
    }
    report_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    rows = _summary_rows(results or [])
    fieldnames = [
        "VM Name",
        "Instance ID",
        "IP",
        "Cloud",
        "Region",
        "Workload Type",
        "DB",
        "Web/API",
        "Ports",
        "Important Mounts",
        "Volumes",
        "Complexity",
        "Recommended Wave",
        "Status",
    ]
    with summary_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    wave_plan = _build_wave_plan(results or [])
    wave_json_path.write_text(json.dumps(wave_plan, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    md_lines = ["# App Dependency Migration Wave Plan", "", f"Created: {payload['created_at']}", ""]
    for wave_name, items in wave_plan["waves"].items():
        md_lines.extend([f"## {wave_name}", ""])
        if not items:
            md_lines.append("- No VMs")
        for item in items:
            md_lines.append(
                f"- {item.get('name') or item.get('id') or item.get('ip')} ({item.get('ip', '')}) - {item.get('workload_type', '')}, {item.get('complexity', '')}"
            )
        md_lines.append("")
    wave_md_path.write_text("\n".join(md_lines), encoding="utf-8")

    rec_lines = ["# Migration Wave Recommendation", ""]
    for row in rows:
        rec_lines.extend(
            [
                f"## {row['VM Name'] or row['Instance ID'] or row['IP']}",
                "",
                f"- IP: {row['IP']}",
                f"- Workload Type: {row['Workload Type']}",
                f"- Complexity: {row['Complexity']}",
                f"- Recommended Wave: {row['Recommended Wave']}",
                f"- DB: {row['DB']}",
                f"- Web/API: {row['Web/API']}",
                f"- Important Mounts: {row['Important Mounts'] or 'None detected'}",
                "",
            ]
        )
    recommendation_path.write_text("\n".join(rec_lines), encoding="utf-8")

    return {
        "app_dependency_report.json": str(report_path),
        "app_dependency_summary.csv": str(summary_path),
        "migration_wave_recommendation.md": str(recommendation_path),
        "app_dependency_wave_plan.json": str(wave_json_path),
        "app_dependency_wave_plan.md": str(wave_md_path),
        "app_dependency_scan_script.sh": str(tmp_runs / "app_dependency_scan_script.sh"),
    }


def refresh_appdep_vm_inventory() -> List[Dict[str, Any]]:
    return []


def render_appdep_action_bar() -> None:
    return None


def render_appdep_vm_selector() -> List[Dict[str, Any]]:
    return []


def render_appdep_results_dashboard() -> None:
    return None


def render_appdep_manual_paste_mode() -> None:
    return None


def render_app_dependency_discovery() -> None:
    """Streamlit compatibility hook.

    This repository currently renders Mission Control through Flask templates.
    The parser/report functions above are used by the Flask Stage 1 tab.
    """

    return None
