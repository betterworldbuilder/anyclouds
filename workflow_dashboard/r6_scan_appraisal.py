"""Production R6 component scan appraisal.

All remote commands are selected server-side from PROBE_REGISTRY.  The browser
can select targets and credentials, but cannot submit shell text.
"""
from __future__ import annotations

import hashlib
import base64
import csv
import io
import json
import os
import re
import subprocess
import socket
import tarfile
import tempfile
import threading
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Optional
from uuid import uuid4
from urllib.parse import urlparse

from flask import Blueprint, Response, jsonify, request, send_file

STATUSES = frozenset({"PENDING", "RUNNING", "PASS", "PASS_WITH_WARNING", "WARNING", "PARTIAL", "FAIL", "BLOCKED", "SKIPPED_PREREQUISITE", "NOT_DETECTED", "NOT_APPLICABLE", "NOT_TESTED", "CANCELLED"})
RETRYABLE = frozenset({"FAIL", "PASS_WITH_WARNING", "WARNING", "PARTIAL", "BLOCKED", "SKIPPED_PREREQUISITE"})
MAX_OUTPUT = 64 * 1024
SCHEMA_VERSION = "r6.scan-appraisal/v2"
SCANNER_VERSION = "2.0.0"

CSV_FIELDS = (
    "scan_run_id", "business_system", "component_id", "component_name",
    "source_vm_id", "source_host", "verdict", "state_classification",
    "capture_recommendation", "containerization_recommendation",
    "readiness_score", "evidence_score", "runtime", "ports",
    "application_paths", "persistent_paths", "warnings", "blockers",
    "probe_id", "probe_name", "probe_status", "probe_duration_ms",
    "probe_exit_code", "probe_error_code", "probe_error_category",
    "probe_prerequisite_id", "probe_derived_from", "probe_retryable",
    "probe_truncated", "probe_remediation",
)


def _csv_cell(value: Any) -> str:
    """Render a safe spreadsheet cell without exporting raw probe output."""
    if isinstance(value, (list, tuple)):
        value = " | ".join(str(item) for item in value)
    value = "" if value is None else str(value)
    if value.startswith(("=", "+", "-", "@", "\t", "\r")):
        value = "'" + value
    return value


def appraisal_csv(run: Dict[str, Any], components: List[Dict[str, Any]]) -> str:
    output = io.StringIO(newline="")
    writer = csv.DictWriter(output, fieldnames=CSV_FIELDS, extrasaction="ignore")
    writer.writeheader()
    system_name = (run.get("businessSystem") or {}).get("name") or "Business Apps System"
    for component in components:
        warnings = ["%s: %s" % (item.get("code", "WARNING"), item.get("message", "")) for item in component.get("warnings", [])]
        blockers = ["%s: %s" % (item.get("code", "BLOCKER"), item.get("message", "")) for item in component.get("blockers", [])]
        base = {
            "scan_run_id": run.get("runId"), "business_system": system_name,
            "component_id": component.get("componentId"), "component_name": component.get("componentName"),
            "source_vm_id": component.get("sourceVmId"), "source_host": component.get("sourceHost"),
            "verdict": component.get("componentVerdict"), "state_classification": component.get("stateClassification"),
            "capture_recommendation": component.get("captureRecommendation"),
            "containerization_recommendation": component.get("containerizationRecommendation"),
            "readiness_score": component.get("containerReadinessScore"), "evidence_score": component.get("evidenceCompletenessScore"),
            "runtime": (component.get("runtime") or {}).get("type"), "ports": component.get("ports", []),
            "application_paths": component.get("applicationPaths", []), "persistent_paths": component.get("persistentPaths", []),
            "warnings": warnings, "blockers": blockers,
        }
        probes = component.get("probes") or [None]
        for probe in probes:
            row = dict(base)
            if probe:
                row.update({"probe_id": probe.get("probeId"), "probe_name": probe.get("probeName"),
                            "probe_status": probe.get("status"), "probe_duration_ms": probe.get("durationMs"),
                            "probe_exit_code": probe.get("exitCode"), "probe_truncated": probe.get("truncated"),
                            "probe_error_code": probe.get("errorCode"), "probe_error_category": probe.get("errorCategory"),
                            "probe_prerequisite_id": probe.get("prerequisiteProbeId"), "probe_derived_from": probe.get("derivedFrom"),
                            "probe_retryable": probe.get("retryable"),
                            "probe_remediation": probe.get("remediation")})
            writer.writerow({key: _csv_cell(row.get(key)) for key in CSV_FIELDS})
    return output.getvalue()


def failed_checks_csv(run: Dict[str, Any], root_causes_only: bool = True) -> str:
    fields = ("scan_run_id", "component_id", "component_name", "source_vm_id", "probe_id",
              "probe_name", "status", "error_code", "error_category", "root_cause_id", "derived_from",
              "skipped_dependents", "exit_code", "duration_ms", "details", "recommended_action")
    output = io.StringIO(newline="")
    writer = csv.DictWriter(output, fieldnames=fields)
    writer.writeheader()
    roots = (run.get("appraisal") or {}).get("rootCauses") or []
    if root_causes_only and roots:
        for root in roots:
            row = {"scan_run_id": run.get("runId"), "component_id": root.get("componentId"),
                   "component_name": root.get("componentName"), "source_vm_id": root.get("sourceVmId"),
                   "probe_id": root.get("probeId"), "probe_name": "Root cause", "status": "BLOCKED",
                   "error_code": root.get("errorCode"), "error_category": "ROOT_CAUSE",
                   "root_cause_id": root.get("rootCauseId"), "derived_from": "",
                   "skipped_dependents": root.get("skippedChecks") or 0, "exit_code": "", "duration_ms": "",
                   "details": redact(str(root.get("summary") or "No diagnostic summary returned."))[:4000],
                   "recommended_action": " | ".join(root.get("recommendedActions") or [])}
            writer.writerow({key: _csv_cell(row.get(key)) for key in fields})
        return output.getvalue()
    seen = set()
    for component in run.get("components", []):
        for probe in component.get("probes", []):
            if probe.get("status") not in ({"FAIL", "BLOCKED"} if root_causes_only else {"FAIL", "BLOCKED", "SKIPPED_PREREQUISITE"}):
                continue
            root_key = probe.get("rootCauseId") or probe.get("derivedFrom") or "%s:%s:%s" % (component.get("sourceVmId") or component.get("componentId"), probe.get("probeId"), probe.get("errorCode"))
            dedupe_key = (component.get("sourceVmId") or component.get("componentId"), probe.get("probeId"), probe.get("errorCode"), root_key)
            if root_causes_only and dedupe_key in seen: continue
            seen.add(dedupe_key)
            detail = probe.get("stderr") or probe.get("stdout") or "No diagnostic output was returned."
            row = {"scan_run_id": run.get("runId"), "component_id": component.get("componentId"),
                   "component_name": component.get("componentName"), "source_vm_id": component.get("sourceVmId"),
                   "probe_id": probe.get("probeId"), "probe_name": probe.get("probeName"), "status": probe.get("status"),
                   "error_code": probe.get("errorCode"), "error_category": probe.get("errorCategory"),
                   "root_cause_id": root_key, "derived_from": probe.get("derivedFrom"),
                   "skipped_dependents": sum(1 for item in component.get("probes", []) if item.get("derivedFrom") == root_key),
                   "exit_code": probe.get("exitCode"), "duration_ms": probe.get("durationMs"),
                   "details": redact(str(detail))[:4000],
                   "recommended_action": probe.get("remediation") or "Resolve the failed check and retry this component."}
            writer.writerow({key: _csv_cell(row.get(key)) for key in fields})
    return output.getvalue()

# id, title, fixed read-only command, timeout, weight
PROBE_REGISTRY = (
    ("SCAN-001", "SSH Connectivity", "true", 10, 5),
    ("SCAN-002", "Host Identity", "printf 'VM_ID='; cat /sys/class/dmi/id/product_uuid 2>/dev/null; hostnamectl 2>/dev/null; uname -a; cat /etc/os-release 2>/dev/null", 15, 5),
    ("SCAN-003", "Runtime Detection", "found=0; for c in python3 node java dotnet go ruby php; do if command -v $c >/dev/null 2>&1; then printf '%s: ' \"$c\"; $c --version 2>&1 | head -1; found=1; fi; done; exit 0", 15, 5),
    ("SCAN-004", "Process Discovery", "ps -eo pid=,ppid=,user=,comm=,args= --sort=pid", 20, 8),
    ("SCAN-005", "Service Discovery", "systemctl list-units --type=service --state=running --no-legend --no-pager; systemctl list-unit-files --type=service --no-legend --no-pager", 25, 7),
    ("SCAN-006", "Port Discovery", "ss -H -lntup", 15, 5),
    ("SCAN-007", "Application Path Discovery", "for root in /opt /srv /var/www /usr/local /home/*/apps /home/*/services; do [ -e \"$root\" ] || continue; find \"$root\" -xdev -maxdepth 6 \\( -name .git -o -name __pycache__ -o -name node_modules -o -name .venv -o -name venv -o -name .cache \\) -prune -o -type f ! -name '*.pyc' -print; done", 25, 15),
    ("SCAN-008", "Mounted Storage", "lsblk -P -o NAME,UUID,FSTYPE,SIZE,RO,MOUNTPOINTS; findmnt -rn -o SOURCE,TARGET,FSTYPE,OPTIONS", 20, 7),
    ("SCAN-009", "Writable Path Discovery", "checked=0; for root in /opt /srv /var/www /usr/local /home/*/apps /home/*/services; do [ -d \"$root\" ] || continue; checked=$((checked+1)); find \"$root\" -xdev -maxdepth 4 -type d -writable -exec stat -c 'path=%n owner=%U group=%G permissions=%a writable=true' {} \\;; done; [ $checked -gt 0 ] || printf 'No writable application path detected; checked paths: /opt /srv /var/www /usr/local /home/*/{apps,services}\\n'", 20, 4),
    ("SCAN-010", "Persistent Path Discovery", "find /var/lib /opt /srv -xdev -maxdepth 4 -type d 2>/dev/null | grep -Ei 'postgres|mysql|maria|mongo|redis|upload|queue|data|state'", 20, 8),
    ("SCAN-011", "Configuration Classification", "find /etc /opt /srv -xdev -maxdepth 5 -type f 2>/dev/null | grep -Ei '\\.(conf|ini|ya?ml|json|env)$|environmentfile'", 25, 5),
    ("SCAN-012", "Outbound Dependency Discovery", "ss -H -ntup state established", 15, 15),
    ("SCAN-013", "Health Validation", "systemctl --failed --no-legend --no-pager; ss -H -lnt", 15, 10),
    ("SCAN-014", "Scheduled Work", "systemctl list-timers --all --no-legend --no-pager; crontab -l 2>/dev/null; find /etc/cron.d -maxdepth 1 -type f -printf '%p\\n' 2>/dev/null", 15, 2),
    ("SCAN-015", "Resource Baseline", "uptime; free -b; df -B1 -P", 15, 2),
    ("SCAN-016", "Container Constraints", "lsmod; sysctl -n net.ipv4.ip_forward 2>/dev/null; find /dev -maxdepth 2 -type c -printf '%p\\n' 2>/dev/null | head -100", 20, 3),
    ("SCAN-017", "Licensing Constraints", "find /etc /opt /srv -xdev -maxdepth 5 -type f 2>/dev/null | grep -Ei 'licen[cs]e|dongle|machine.?id|hostid'", 20, 2),
    ("SCAN-018", "Secret Exposure", "find /opt /srv /var/www /etc -xdev -maxdepth 5 -type f 2>/dev/null | grep -Ei '(^|/)(id_rsa|id_ed25519|.*\\.pem|.*\\.key)(\\.|$|/)' | while read -r f; do if [ -r \"$f\" ] && grep -q 'BEGIN CERTIFICATE' \"$f\" 2>/dev/null && ! grep -Eq 'BEGIN (RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY' \"$f\" 2>/dev/null; then printf 'PUBLIC_CERT_FILE:%s\\n' \"$f\"; else printf '%s\\n' \"$f\"; fi; done; find /opt /srv /var/www /etc -xdev -maxdepth 5 -type f 2>/dev/null | grep -Ei '(^|/)(\\.?env(\\.[a-z]+)?|credentials|secrets?)(\\.|$|/)' | sed 's#^#ENV_SECRET_FILE:#'; grep -RIoHE '(password|passwd|token|secret|api[_-]?key)[[:space:]]*[:=][[:space:]]*[^[:space:],;]+' /opt /srv /var/www 2>/dev/null | sed 's#^#PLAINTEXT_SECRET_MATCH:#'", 25, 5),
    ("SCAN-019", "Database Detection", "ps -eo comm=,args= | grep -Ei 'postgres|mysqld|mariadbd|mongod|redis-server' | grep -v grep; ss -H -lnt | grep -E ':(5432|3306|33060|27017|6379)\\b'", 15, 5),
    ("SCAN-020", "Snapshot Source Readiness", "printf 'VM_ID='; cat /sys/class/dmi/id/product_uuid 2>/dev/null; lsblk -P -o NAME,UUID,TYPE,FSTYPE,SIZE,RO,MOUNTPOINTS", 20, 5),
)
PROBES = {row[0]: row for row in PROBE_REGISTRY}

SECRET_VALUE = re.compile(r"(?i)(password|passwd|token|secret|api[_-]?key|authorization|os_password|aws_secret_access_key)\s*[:=]\s*([^\s,;]+)")
DATABASE_URL = re.compile(r"(?i)\b(postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis)://([^\s/@:]+):([^\s/@]+)@")
PRIVATE_KEY = re.compile(r"(?i)(^|/)(id_rsa|id_ed25519|[^/]+\.key|[^/]+\.pem)$")
DB_PATH = re.compile(r"(?i)(/var/lib/(postgresql|mysql|redis|mongo)|/data/(postgres|mysql|redis|mongo))")
HOST_AGENT = re.compile(r"(?i)(/home/[^/]+/(\.ssh|\.cache)|/root/\.ssh|/var/log|/tmp|/var/tmp|\.deb$|authorized_keys$|\.bash(rc|_profile|_logout)$|qemu|ssm-agent|modemmanager)")
PLACEHOLDER_HOST = re.compile(r"(?i)^(flex-ip|tbd|pending|unknown|n/?a|none|null|not[-_]?set|todo|placeholder|)$")
SOURCE_FILE_EXTENSION = re.compile(r"(?i)\.(py|js|ts|jsx|tsx|java|go|rb|php|cs|c|cpp|sh|pl)$")
ENV_FILE = re.compile(r"(?i)(^|/)\.?env(\.[a-z]+)?$")
PLACEHOLDER_SECRET_VALUE = re.compile(r"(?i)^[\"']?(changeme|change_me|example|xxx+|<.*>|\$\{.*\}|placeholder|dummy|test123|redacted|your[_-]?(password|secret|key)|insert[_-]?.*here|todo|fixme|sample|fake|secret|password|123456|null|none|n/?a)[\"']?$")
SECRET_MATCH_LINE = re.compile(r"(?i)^(?P<path>.+?):(?:password|passwd|token|secret|api[_-]?key)\s*[:=]\s*(?P<value>.+)$")


def _classify_secret_match(line: str) -> str:
    """Turn a raw `path:key=value` SCAN-018 match into a path-only marker, scoring
    confidence from the value without ever letting the value itself survive into stdout."""
    if not line.startswith("PLAINTEXT_SECRET_MATCH:"):
        return line
    match = SECRET_MATCH_LINE.match(line[len("PLAINTEXT_SECRET_MATCH:"):])
    if not match:
        return line
    value = match.group("value").strip().strip("\"'")
    marker = "PLAINTEXT_SECRET_LOW_CONFIDENCE_FILE:" if PLACEHOLDER_SECRET_VALUE.match(value) else "PLAINTEXT_SECRET_FILE:"
    return marker + match.group("path")
# systemd units that are host/hypervisor/agent noise, not the application under scan.
# A failed unit outside this list is treated as a real application health blocker.
IRRELEVANT_SERVICE_NOISE = re.compile(r"(?i)(nova-agent|qemu|cloud-init|snapd|apt-daily|unattended-upgrades|systemd-|network-manager|modemmanager|packagekit|motd|fwupd|multipathd|lvm2|^ssh(d)?\.service|^cron\.service|rsyslog|chrony|ntp|walinuxagent|hv-kvp|hv-vss|open-vm-tools|polkit|accounts-daemon|colord|switcheroo|getty@|serial-getty|dbus|udisks2|avahi-daemon|^cups|bluetooth|networkd-dispatcher|apport|whoopsie|kerneloops|e2scrub|anacron|plymouth|irqbalance|thermald|acpid|atd\.service)")
MAINTENANCE_DIR_NOISE = re.compile(r"(?i)/var/lib/(apt|dpkg|snapd|cloud-init|ubuntu-advantage|update-manager|polkit-1|private|misc|udisks2|fwupd|colord|NetworkManager|dhcp|logrotate|man-db|PackageKit|systemd)(/|$)")
OS_CONFIG_NOISE = re.compile(r"(?i)^/etc/(systemd|network|apt|cron\.[dw]|logrotate\.d|rsyslog\.d|security|pam\.d|default|init\.d|sysctl\.d|udev|dbus-1|ssl/(certs|private)|ca-certificates|fonts|X11|skel|update-motd\.d|NetworkManager|polkit-1|modprobe\.d|kernel)(/|$)")
GENERIC_DEVICE_NOISE = re.compile(r"^/dev/(tty\d*|loop\d+|ram\d+|null|zero|random|urandom|core|fd|std(in|out|err)|pts/.*|full|kmsg|mem|port)$")
KERNEL_THREAD = re.compile(r"^\[.*\]$")

# Severity taxonomy (see design-template/r6-scanner-status-contract.md classification rules).
SEVERITY_BLOCKER = "BLOCKER"
SEVERITY_BLOCKER_SECURITY = "BLOCKER_SECURITY"
SEVERITY_BLOCKER_APPLICATION = "BLOCKER_APPLICATION"
SEVERITY_BLOCKER_INFRASTRUCTURE = "BLOCKER_INFRASTRUCTURE"
SEVERITY_REVIEW_REQUIRED = "REVIEW_REQUIRED"
SEVERITY_WARNING = "WARNING"
SEVERITY_INFO = "INFO"
SEVERITY_UNKNOWN = "UNKNOWN"


def utcnow() -> str:
    return datetime.now(timezone.utc).isoformat()


def redact(value: str) -> str:
    value = re.sub(r"-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----", "[REDACTED PRIVATE KEY]", value, flags=re.S)
    value = SECRET_VALUE.sub(lambda m: "%s=[REDACTED]" % m.group(1), value)
    value = DATABASE_URL.sub(lambda m: "%s://[REDACTED]@" % m.group(1), value)
    value = re.sub(r"(?i)(authorization:\s*(?:bearer|basic)\s+)\S+", r"\1[REDACTED]", value)
    return value


def filter_application_paths(lines: Iterable[str]) -> List[str]:
    result = []
    for line in lines:
        path = line.strip()
        generated = re.search(r"(^|/)(\.git|__pycache__|node_modules|\.venv|venv|\.cache)(/|$)|\.pyc$|(^|/)(tmp|var/tmp)(/|$)", path)
        if path.startswith(("/opt/", "/srv/", "/var/www/", "/usr/local/", "/home/")) and not generated and not HOST_AGENT.search(path) and not PRIVATE_KEY.search(path):
            result.append(path)
    return sorted(set(result))


def classify_ssh_failure(stderr: str, exit_code: Optional[int], timed_out: bool) -> str:
    value = (stderr or "").lower()
    if "remote host identification has changed" in value or "offending " in value and "known_hosts" in value:
        return "SSH_HOST_KEY_CHANGED"
    if "could not resolve hostname" in value or "name or service not known" in value or "temporary failure in name resolution" in value:
        return "SSH_DNS_RESOLUTION_FAILED"
    if "no route to host" in value or "network is unreachable" in value:
        return "SSH_NETWORK_UNREACHABLE"
    if "connection refused" in value:
        return "SSH_CONNECTION_REFUSED"
    if "connection timed out" in value or "operation timed out" in value:
        return "SSH_NETWORK_TIMEOUT"
    if "host key verification failed" in value or "no matching host key" in value:
        return "SSH_HOST_KEY_UNKNOWN"
    if "permission denied" in value or "publickey" in value or "authentication failed" in value:
        return "SSH_AUTHENTICATION_FAILED"
    if timed_out or exit_code == 124:
        return "SSH_COMMAND_TIMEOUT"
    if exit_code not in (None, 0):
        return "SSH_REMOTE_COMMAND_FAILED"
    return "SSH_UNKNOWN_ERROR"


def remediation_for(error_code: Optional[str]) -> List[str]:
    return {
        "SSH_DNS_RESOLUTION_FAILED": ["Verify the source hostname or select the VM floating IP.", "Check DNS from the scanner host."],
        "SSH_NETWORK_UNREACHABLE": ["Verify VM ACTIVE state, floating IP, route and network reachability."],
        "SSH_CONNECTION_REFUSED": ["Verify sshd is running and TCP/22 is allowed by the guest firewall and security group."],
        "SSH_NETWORK_TIMEOUT": ["Verify VM ACTIVE state, floating IP assignment, route, security group TCP/22, guest firewall and sshd."],
        "SSH_HOST_KEY_CHANGED": ["Verify the replacement VM fingerprint with the infrastructure owner, then use Verify and Replace Key.",
                                  "Do not disable host-key checking; replace only the managed known_hosts entry for this host."],
        "SSH_HOST_KEY_UNKNOWN": ["Verify and register the server fingerprint in the managed known_hosts file."],
        "SSH_AUTHENTICATION_FAILED": ["Verify the per-VM SSH username, selected private key and authorized_keys configuration."],
        "SSH_PERMISSION_DENIED": ["Grant the scan user read-only access to the required evidence path and retry."],
        "SSH_COMMAND_TIMEOUT": ["Increase the command timeout or investigate the remote command, host load and blocked filesystem operations."],
        "SSH_REMOTE_COMMAND_FAILED": ["Review stderr, command availability and scan-user permissions, then retry the probe."],
        "DATABASE_ENDPOINT_UNREACHABLE": ["Verify database endpoint DNS, routing, firewall rules and service availability."],
        "COMPONENT_VM_MAPPING_MISSING": ["Open Stage 1, inspect the Business System component, and map it to the correct OpenStack server UUID.",
                                         "Set the FLEX Target IP/URL or source VM UUID, save the Business System, then retry this component."],
        "VM_UUID_UNMAPPED": ["Map the component to an OpenStack server UUID to enable snapshot-based capture; guest discovery over SSH is unaffected."],
        "TARGET_RESOLUTION_FAILED": ["Resolve the component's scan target to a real hostname or IP before scanning; a placeholder value was configured."],
        "SSH_KEY_NOT_FOUND": ["The configured SSH private key file does not exist on the scanner host. Verify the key path or provision the key."],
        "SSH_KEY_UNREADABLE": ["The scanner process cannot read the configured SSH private key. Verify the effective service user and file ownership/permissions."],
        "SSH_KEY_INVALID": ["The configured SSH key file is not a valid private key. Verify the correct key file is selected."],
        "SSH_KEY_PERMISSIONS_INVALID": ["The private key file permissions are broader than 0600. Run chmod 600 on the key before retrying; OpenSSH will refuse an insecure key."],
        "PRIVATE_KEY_CAPTURE_PATH": ["Remove or relocate the private key out of the application/capture path on the source VM.",
                                     "Re-issue the key pair post-migration instead of copying it, or import it into the target secret manager (e.g. OpenStack Barbican/Vault).",
                                     "Exclude the path from the capture set and retry the component."],
        "PLAINTEXT_SECRET": ["Externalize the detected plaintext secret into the target secret manager and rotate the credential.",
                             "Block container package generation for this component until the secret is removed from the capture path."],
        "PLAINTEXT_SECRET_HARDCODED": ["A credential appears hardcoded in application source. Move it to the environment/secret manager and rotate it before packaging.",
                                        "Block container package generation for this component until the secret is externalized."],
        "PLAINTEXT_SECRET_ENV_FILE": ["An environment file contains a confirmed credential. This is expected for local config, but do not bake the file into the container image unchanged.",
                                       "Inject the value at deploy time via the target secret manager instead of copying the file."],
        "PLAINTEXT_SECRET_LOW_CONFIDENCE": ["A possible secret-like value was matched with low confidence (placeholder or example value). Review the file directly to confirm before treating it as a real credential; it is not an automatic block."],
        "APPLICATION_HEALTH_CHECK_FAILED": ["The application's own service is reporting a failed systemd unit. Investigate and restore application health before approving this component."],
    }.get(error_code or "", ["Review the structured diagnostics and retry the affected check."])


def _status(exit_code: int, stdout: str, timed_out: bool, probe_id: str, stderr: str = "") -> str:
    if timed_out:
        # Writable-path discovery is optional, non-critical evidence -- a timeout here
        # is a warning, never a blocking root cause.
        return "PASS_WITH_WARNING" if probe_id == "SCAN-009" else "FAIL"
    if probe_id == "SCAN-003":
        return "PASS" if re.search(r"(?i)\b(python|node|java|openjdk|php|\.net|dotnet|go version|ruby)\b", stdout) else ("NOT_DETECTED" if exit_code in {0, 1, 127} else "FAIL")
    if probe_id == "SCAN-007":
        if filter_application_paths(stdout.splitlines()):
            return "PASS_WITH_WARNING" if exit_code != 0 or stderr.strip() else "PASS"
        return "NOT_DETECTED" if exit_code in {0, 1} else "FAIL"
    if probe_id == "SCAN-009":
        if "no writable application path detected" in stdout.lower():
            return "NOT_DETECTED"
        return "PASS" if stdout.strip() else ("PASS_WITH_WARNING" if stderr.strip() else "NOT_DETECTED")
    if exit_code != 0:
        # grep-based discovery returning 1 means no finding, not command failure.
        if probe_id in {"SCAN-010", "SCAN-011", "SCAN-012", "SCAN-017", "SCAN-018", "SCAN-019"} and exit_code == 1:
            return "NOT_DETECTED"
        return "FAIL"
    if probe_id in {"SCAN-004", "SCAN-005", "SCAN-006", "SCAN-007"} and not stdout.strip():
        return "PARTIAL"
    if probe_id == "SCAN-013":
        return "WARNING"  # listening ports are not an application-level health assertion
    return "PASS"


def _validate_ssh_key(key_path: Path) -> Optional[str]:
    """Preflight the configured private key so a missing/insecure key produces a
    diagnosable BLOCKER instead of an opaque SSH failure. Returns an error code,
    or None if the key looks usable."""
    try:
        if not key_path.is_file():
            return "SSH_KEY_NOT_FOUND"
        info = key_path.stat()
    except OSError:
        return "SSH_KEY_NOT_FOUND"
    try:
        head = key_path.read_text(encoding="utf-8", errors="replace")
    except (OSError, PermissionError):
        return "SSH_KEY_UNREADABLE"
    if os.name != "nt" and (info.st_mode & 0o077):
        return "SSH_KEY_PERMISSIONS_INVALID"
    if not re.search(r"-----BEGIN (RSA |EC |OPENSSH |DSA |ENCRYPTED |)?PRIVATE KEY-----", head):
        return "SSH_KEY_INVALID"
    return None


def run_probe(target: Dict[str, Any], probe_id: str, runner: Callable[..., subprocess.CompletedProcess] = subprocess.run) -> Dict[str, Any]:
    if probe_id not in PROBES:
        raise ValueError("unknown probe")
    _, title, remote, timeout, _ = PROBES[probe_id]
    started = time.monotonic()
    started_at = utcnow()
    host = str(target.get("host") or "").strip()
    user = str(target.get("user") or "").strip()
    key = str(target.get("keyPath") or "~/.ssh/id_rsa").strip()
    port = int(target.get("port") or 22)
    connect_timeout = max(1, min(int(target.get("connectTimeout") or 8), 120))
    command_timeout = max(1, min(int(target.get("commandTimeout") or timeout), 600))
    expected = str(target.get("expectedFingerprint") or "").strip()
    known_hosts = str(Path(str(target.get("knownHostsFile"))).expanduser()) if target.get("knownHostsFile") else str(default_managed_known_hosts_file())
    if not host or PLACEHOLDER_HOST.match(host):
        result = _probe_result(probe_id, title, started_at, started, 2, "", "SSH target is unresolved or a placeholder value: %r" % host, False, False, "BLOCKED")
        result.update(_error_fields("TARGET_RESOLUTION_FAILED", "TARGET"))
        result["remediation"] = result["recommendedActions"][0]
        return result
    if not re.fullmatch(r"[A-Za-z0-9_.:-]+", host) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.-]*", user):
        return _probe_result(probe_id, title, started_at, started, 2, "", "invalid SSH target or user", False, False, "BLOCKED")
    key_path = Path(key).expanduser()
    key_error = _validate_ssh_key(key_path)
    if key_error:
        result = _probe_result(probe_id, title, started_at, started, 2, "", "SSH key preflight failed: %s (%s)" % (key_error, key_path), False, False, "BLOCKED")
        result.update(_error_fields(key_error, "CREDENTIAL"))
        result["remediation"] = result["recommendedActions"][0]
        return result
    if probe_id == "SCAN-013":
        health_path = str(target.get("healthPath") or "").strip()
        health_port = target.get("healthPort")
        if re.fullmatch(r"/[A-Za-z0-9_./?=&%-]*", health_path) and str(health_port or "").isdigit():
            health_port = int(health_port)
            if 1 <= health_port <= 65535:
                remote += "; if command -v curl >/dev/null 2>&1; then code=$(curl -ksS -o /dev/null -w '%%{http_code}' --max-time 5 'http://127.0.0.1:%s%s' || true); printf '\\nHEALTH_CHECK_HTTP=%%s\\n' \"$code\"; fi" % (health_port, health_path)
    argv = ["ssh", "-i", str(key_path), "-p", str(port), "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=%s" % known_hosts, "-o", "ConnectTimeout=%s" % connect_timeout, "-o", "ConnectionAttempts=1", "%s@%s" % (user, host), remote]
    try:
        completed = runner(argv, capture_output=True, text=True, timeout=command_timeout, check=False)
        raw_stdout = completed.stdout or ""
        if probe_id == "SCAN-018":
            # Classify each matched secret's confidence (placeholder/example vs a real-looking
            # value) using the raw value, then immediately discard the value itself -- only the
            # confidence marker + path survive into stdout, which is redact()-ed right after.
            raw_stdout = "\n".join(_classify_secret_match(line) for line in raw_stdout.splitlines())
        stdout, stderr = redact(raw_stdout), redact(completed.stderr or "")
        truncated = len(stdout) > MAX_OUTPUT or len(stderr) > MAX_OUTPUT
        stdout, stderr = stdout[:MAX_OUTPUT], stderr[:MAX_OUTPUT]
        status = _status(completed.returncode, stdout, False, probe_id, stderr)
        result = _probe_result(probe_id, title, started_at, started, completed.returncode, stdout, stderr, False, truncated, status)
    except subprocess.TimeoutExpired as exc:
        result = _probe_result(probe_id, title, started_at, started, 124, redact(str(exc.stdout or ""))[:MAX_OUTPUT], redact(str(exc.stderr or ""))[:MAX_OUTPUT], True, False, "FAIL")
    result["timeoutSeconds"] = command_timeout
    if result.get("exitCode") == 124:
        result["timeout"] = result["timedOut"] = True
        result["summary"] = "Command timed out after %s seconds during %s on %s." % (command_timeout, probe_id, host)
    if result["status"] in {"FAIL", "BLOCKED"}:
        error_code = classify_ssh_failure(result.get("stderr", ""), result.get("exitCode"), bool(result.get("timeout")))
        if probe_id != "SCAN-001" and error_code in {"SSH_UNKNOWN_ERROR", "SSH_NETWORK_TIMEOUT"} and not result.get("timeout"):
            error_code = "SSH_REMOTE_COMMAND_FAILED"
        result.update(_error_fields(error_code, "SSH" if error_code.startswith("SSH_") else "COMMAND"))
        result["remediation"] = result["recommendedActions"][0]
    if probe_id == "SCAN-001":
        result["hostFingerprint"] = expected or None
        if not expected:
            # Connectivity and every downstream probe work fine here; only the managed
            # known_hosts trust record is incomplete, so this is a WARNING, not a BLOCKER.
            result["status"] = "PASS_WITH_WARNING" if result["status"] == "PASS" else result["status"]
            if result["status"] == "PASS_WITH_WARNING":
                result["summary"] = "SSH succeeded, but the host fingerprint is not yet permanently approved for this VM."
                result["recommendedActions"] = ["Approve Fingerprint to persist trust for this VM in the managed known_hosts file."]
                result["remediation"] = result["recommendedActions"][0]
                result["approveFingerprintAvailable"] = True
        if result.get("errorCode") == "SSH_HOST_KEY_CHANGED":
            result["operatorActionRequired"] = True
            result["oldFingerprint"] = expected or None
            result["newFingerprint"] = _extract_fingerprint(result.get("stderr", ""), "new")
    return result


def _extract_fingerprint(text: str, which: str = "new") -> Optional[str]:
    values = re.findall(r"(?:SHA256:|MD5:)[A-Za-z0-9+/=:.-]+", text or "")
    if not values:
        return None
    return values[0] if which == "old" else values[-1]


def _known_host_fingerprint(keyscan_line: str) -> Optional[str]:
    fields = keyscan_line.strip().split()
    if len(fields) < 3:
        return None
    try:
        digest = hashlib.sha256(base64.b64decode(fields[2].encode("ascii"))).digest()
        return "SHA256:" + base64.b64encode(digest).decode("ascii").rstrip("=")
    except Exception:
        return None


def default_managed_known_hosts_file() -> Path:
    """App-owned known_hosts path -- never the operator's global ~/.ssh/known_hosts."""
    return Path(os.environ.get("MANAGED_KNOWN_HOSTS_FILE", "./data/ssh/known_hosts")).expanduser()


def _ensure_known_hosts_file(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    path.touch(mode=0o600, exist_ok=True)
    os.chmod(path, 0o600)


def _host_token(host: str, port: int) -> str:
    return host if port == 22 else "[%s]:%s" % (host, port)


def _read_known_host_entry(known_hosts: Path, host: str, port: int) -> Optional[str]:
    if not known_hosts.is_file():
        return None
    token = _host_token(host, port)
    for line in known_hosts.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.strip() and not line.startswith("#") and line.split()[0] == token:
            return line
    return None


def scan_host_key(host: str, port: int, runner: Callable[..., subprocess.CompletedProcess] = subprocess.run) -> Dict[str, Any]:
    """Collect the live host key for exactly this host+port. Never scans an unrelated host."""
    if not re.fullmatch(r"[A-Za-z0-9_.:-]+", host) or not (1 <= port <= 65535):
        return {"ok": False, "error": "invalid host or port"}
    try:
        scanned = runner(["ssh-keyscan", "-T", "5", "-p", str(port), host], capture_output=True, text=True, timeout=10, check=False)
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "ssh-keyscan timed out", "status": "UNREACHABLE"}
    except FileNotFoundError:
        return {"ok": False, "error": "ssh-keyscan binary is not available on the scanner host", "status": "UNREACHABLE"}
    lines = [line for line in (scanned.stdout or "").splitlines() if line and not line.startswith("#")]
    if not lines:
        return {"ok": False, "error": "no host key returned (port unreachable or closed)", "status": "UNREACHABLE"}
    preference = {"ssh-ed25519": 0, "ecdsa-sha2-nistp256": 1, "ssh-rsa": 2}
    lines.sort(key=lambda l: preference.get(l.split()[1], 9) if len(l.split()) > 1 else 9)
    best = lines[0]
    fields = best.split()
    if len(fields) < 3:
        return {"ok": False, "error": "unsupported or malformed key", "status": "UNREACHABLE"}
    fingerprint = _known_host_fingerprint(best)
    if not fingerprint:
        return {"ok": False, "error": "unsupported or malformed key", "status": "UNREACHABLE"}
    return {"ok": True, "line": best, "keyType": fields[1], "fingerprint": fingerprint}


def get_trust_status(host: str, port: int, known_hosts_file: Optional[Path] = None,
                      runner: Callable[..., subprocess.CompletedProcess] = subprocess.run) -> Dict[str, Any]:
    known_hosts = known_hosts_file or default_managed_known_hosts_file()
    trusted_line = _read_known_host_entry(known_hosts, host, port)
    trusted_fingerprint = _known_host_fingerprint(trusted_line) if trusted_line else None
    scanned = scan_host_key(host, port, runner)
    if not scanned.get("ok"):
        return {"ok": True, "host": host, "port": port, "status": "UNREACHABLE", "error": scanned.get("error"),
                "trustedFingerprint": trusted_fingerprint, "knownHostsFile": str(known_hosts)}
    live_fingerprint = scanned["fingerprint"]
    status = "UNKNOWN" if trusted_fingerprint is None else "TRUSTED" if trusted_fingerprint == live_fingerprint else "CHANGED"
    return {"ok": True, "host": host, "port": port, "status": status, "keyType": scanned.get("keyType"),
            "fingerprint": live_fingerprint, "trustedFingerprint": trusted_fingerprint, "knownHostsFile": str(known_hosts)}


_KNOWN_HOSTS_LOCK = threading.RLock()


def _audit_log_path(known_hosts: Path) -> Path:
    return known_hosts.parent / "known_hosts_audit.jsonl"


def _record_host_key_audit(known_hosts: Path, actor: str, action: str, host: str, port: int,
                            fingerprint: Optional[str], result: str, vm_id: Optional[str] = None) -> None:
    """Append-only audit trail for fingerprint trust decisions. Never logs credentials --
    only host/port/fingerprint/actor/action/result, matching the same fields shown in the UI."""
    entry = {"timestamp": utcnow(), "actor": actor or "dashboard-user", "action": action, "vmId": vm_id,
              "host": host, "port": port, "fingerprint": fingerprint, "result": result}
    try:
        path = _audit_log_path(known_hosts)
        path.parent.mkdir(parents=True, exist_ok=True)
        with _KNOWN_HOSTS_LOCK, path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(entry, sort_keys=True) + "\n")
    except OSError:
        pass  # audit logging must never block the underlying trust decision


def approve_host_key(host: str, port: int, expected_fingerprint: str, known_hosts_file: Optional[Path] = None,
                      runner: Callable[..., subprocess.CompletedProcess] = subprocess.run,
                      actor: str = "dashboard-user", action: str = "APPROVE", vm_id: Optional[str] = None) -> tuple:
    """Scoped, re-verified persistence of a single host+port key. Shared by both first-time
    approval (UNKNOWN) and explicit replacement (CHANGED): the caller's claimed fingerprint is
    never trusted directly -- the host is re-scanned live and must match before anything is written."""
    known_hosts = known_hosts_file or default_managed_known_hosts_file()
    if not re.fullmatch(r"[A-Za-z0-9_.:-]+", host) or not (1 <= port <= 65535):
        _record_host_key_audit(known_hosts, actor, action, host, port, None, "REJECTED_INVALID_TARGET", vm_id)
        return {"ok": False, "error": "invalid host or port"}, 400
    if not str(expected_fingerprint or "").startswith("SHA256:"):
        _record_host_key_audit(known_hosts, actor, action, host, port, None, "REJECTED_NO_FINGERPRINT", vm_id)
        return {"ok": False, "error": "a verified SHA256 fingerprint is required"}, 400
    scanned = scan_host_key(host, port, runner)
    if not scanned.get("ok"):
        _record_host_key_audit(known_hosts, actor, action, host, port, expected_fingerprint, "SCAN_FAILED: %s" % scanned.get("error"), vm_id)
        return {"ok": False, "error": scanned.get("error") or "host key scan failed"}, 409
    if scanned["fingerprint"] != expected_fingerprint:
        _record_host_key_audit(known_hosts, actor, action, host, port, scanned["fingerprint"], "REJECTED_FINGERPRINT_MISMATCH", vm_id)
        return {"ok": False, "error": "scanned host key does not match the approved fingerprint (it changed between scan and approval)",
                "observedFingerprint": scanned["fingerprint"]}, 409
    try:
        with _KNOWN_HOSTS_LOCK:
            _ensure_known_hosts_file(known_hosts)
            token = _host_token(host, port)
            existing = known_hosts.read_text(encoding="utf-8", errors="replace").splitlines() if known_hosts.is_file() else []
            kept = [line for line in existing if not (line.strip() and not line.startswith("#") and line.split()[0] == token)]
            kept.append(scanned["line"])
            tmp = known_hosts.with_name(known_hosts.name + ".%s.tmp" % uuid4().hex[:8])
            tmp.write_text("\n".join(kept) + "\n", encoding="utf-8")
            os.chmod(tmp, 0o600)
            tmp.replace(known_hosts)
            os.chmod(known_hosts, 0o600)
    except OSError as exc:
        _record_host_key_audit(known_hosts, actor, action, host, port, scanned["fingerprint"], "WRITE_FAILED: %s" % redact(str(exc)), vm_id)
        return {"ok": False, "error": "managed known_hosts file is not writable: %s" % redact(str(exc))}, 500
    if _read_known_host_entry(known_hosts, host, port) != scanned["line"]:
        _record_host_key_audit(known_hosts, actor, action, host, port, scanned["fingerprint"], "VERIFY_FAILED", vm_id)
        return {"ok": False, "error": "failed to verify the persisted known_hosts entry"}, 500
    _record_host_key_audit(known_hosts, actor, action, host, port, scanned["fingerprint"], "TRUSTED", vm_id)
    return {"ok": True, "status": "TRUSTED", "host": host, "port": port, "keyType": scanned.get("keyType"),
            "fingerprint": scanned["fingerprint"], "knownHostsFile": str(known_hosts), "connectionRetried": False}, 200


# Maps a finding's error code to the severity taxonomy from the scanner status contract.
# BLOCKER_INFRASTRUCTURE = access/connectivity cannot be established at all.
# BLOCKER_SECURITY = a confirmed credential would be carried into the migrated artifact.
# BLOCKER_APPLICATION = the source application itself is confirmed unhealthy.
BLOCKER_KIND_BY_CODE = {
    "SSH_KEY_NOT_FOUND": SEVERITY_BLOCKER_INFRASTRUCTURE, "SSH_KEY_UNREADABLE": SEVERITY_BLOCKER_INFRASTRUCTURE,
    "SSH_KEY_INVALID": SEVERITY_BLOCKER_INFRASTRUCTURE, "SSH_KEY_PERMISSIONS_INVALID": SEVERITY_BLOCKER_INFRASTRUCTURE,
    "TARGET_RESOLUTION_FAILED": SEVERITY_BLOCKER_INFRASTRUCTURE, "COMPONENT_VM_MAPPING_MISSING": SEVERITY_BLOCKER_INFRASTRUCTURE,
    "SSH_DNS_RESOLUTION_FAILED": SEVERITY_BLOCKER_INFRASTRUCTURE, "SSH_NETWORK_UNREACHABLE": SEVERITY_BLOCKER_INFRASTRUCTURE,
    "SSH_CONNECTION_REFUSED": SEVERITY_BLOCKER_INFRASTRUCTURE, "SSH_NETWORK_TIMEOUT": SEVERITY_BLOCKER_INFRASTRUCTURE,
    "SSH_HOST_KEY_CHANGED": SEVERITY_BLOCKER_INFRASTRUCTURE, "SSH_HOST_KEY_UNKNOWN": SEVERITY_BLOCKER_INFRASTRUCTURE,
    "SSH_AUTHENTICATION_FAILED": SEVERITY_BLOCKER_INFRASTRUCTURE, "SSH_PERMISSION_DENIED": SEVERITY_BLOCKER_INFRASTRUCTURE,
    "SSH_COMMAND_TIMEOUT": SEVERITY_BLOCKER_INFRASTRUCTURE, "SSH_REMOTE_COMMAND_FAILED": SEVERITY_BLOCKER_INFRASTRUCTURE,
    "PRIVATE_KEY_CAPTURE_PATH": SEVERITY_BLOCKER_SECURITY, "PLAINTEXT_SECRET_HARDCODED": SEVERITY_BLOCKER_SECURITY,
    "APPLICATION_HEALTH_CHECK_FAILED": SEVERITY_BLOCKER_APPLICATION,
}


def _error_fields(error_code: str, category: str, prerequisite: Optional[str] = None) -> Dict[str, Any]:
    actions = remediation_for(error_code)
    stage = {"SSH_DNS_RESOLUTION_FAILED": "DNS_RESOLUTION", "SSH_NETWORK_UNREACHABLE": "TCP_REACHABILITY",
             "SSH_CONNECTION_REFUSED": "TCP_REACHABILITY", "SSH_NETWORK_TIMEOUT": "TCP_REACHABILITY",
             "SSH_HOST_KEY_CHANGED": "HOST_KEY_VERIFICATION", "SSH_HOST_KEY_UNKNOWN": "HOST_KEY_VERIFICATION",
             "SSH_AUTHENTICATION_FAILED": "AUTHENTICATION", "SSH_PERMISSION_DENIED": "REMOTE_COMMAND_EXECUTION",
             "SSH_COMMAND_TIMEOUT": "REMOTE_COMMAND_EXECUTION", "SSH_REMOTE_COMMAND_FAILED": "REMOTE_COMMAND_EXECUTION",
             "COMPONENT_VM_MAPPING_MISSING": "VM_MAPPING", "TARGET_RESOLUTION_FAILED": "TARGET_RESOLUTION",
             "SSH_KEY_NOT_FOUND": "CREDENTIAL_PREFLIGHT", "SSH_KEY_UNREADABLE": "CREDENTIAL_PREFLIGHT",
             "SSH_KEY_INVALID": "CREDENTIAL_PREFLIGHT", "SSH_KEY_PERMISSIONS_INVALID": "CREDENTIAL_PREFLIGHT",
             "APPLICATION_HEALTH_CHECK_FAILED": "APPLICATION_HEALTH"}.get(error_code, "UNKNOWN")
    return {"errorCode": error_code, "error_code": error_code, "errorCategory": category,
            "error_category": category, "failureStage": stage, "failure_stage": stage, "prerequisiteProbeId": prerequisite,
            "prerequisite_check_id": prerequisite, "retryable": error_code != "SSH_HOST_KEY_CHANGED",
            "operatorActionRequired": error_code in {"SSH_HOST_KEY_CHANGED", "COMPONENT_VM_MAPPING_MISSING"},
            "operator_action_required": error_code in {"SSH_HOST_KEY_CHANGED", "COMPONENT_VM_MAPPING_MISSING"},
            "severity": "ERROR", "severityKind": BLOCKER_KIND_BY_CODE.get(error_code, SEVERITY_BLOCKER),
            "recommendedActions": actions, "diagnosticSummary": actions[0], "diagnostic_summary": actions[0]}


def _probe_result(probe_id: str, title: str, started_at: str, started: float, code: int, stdout: str, stderr: str, timeout: bool, truncated: bool, status: str) -> Dict[str, Any]:
    completed_at = utcnow()
    duration = round((time.monotonic() - started) * 1000)
    summary = (stdout.strip().splitlines() or stderr.strip().splitlines() or ["No output returned."])[0][:500]
    actions = ["Review the structured diagnostics and retry the affected check."] if status in {"FAIL", "BLOCKED"} else []
    return {"probeId": probe_id, "probeName": title, "targetId": None, "componentId": None,
            "sourceVmId": None, "startedAt": started_at, "completedAt": completed_at,
            "durationMs": duration, "commandIdentifier": probe_id, "exitCode": code,
            "rawExitCode": code, "raw_exit_code": code, "stdout": redact(stdout), "stderr": redact(stderr),
            "timeout": timeout, "timedOut": timeout, "evidenceCount": len([x for x in stdout.splitlines() if x.strip()]),
            "truncated": truncated, "status": status, "summary": redact(summary),
            "recommendedActions": actions, "retryable": status in RETRYABLE,
            "operatorActionRequired": False, "severity": "ERROR" if status in {"FAIL", "BLOCKED"} else "WARNING" if status in {"WARNING", "PASS_WITH_WARNING", "PARTIAL"} else "INFO",
            "evidence": {}, "remediation": actions[0] if actions else ""}


def _application_health_status(scan013_stdout: str) -> List[str]:
    """Return systemd unit names that are FAILED and are not host/hypervisor/agent
    noise (e.g. python3-nova-agent on KVM) -- i.e. real application health failures."""
    failed = []
    for line in scan013_stdout.splitlines():
        match = re.match(r"^\s*(\S+\.service)\s+\S+\s+failed\s+failed\b", line)
        if match and not IRRELEVANT_SERVICE_NOISE.search(match.group(1)):
            failed.append(match.group(1))
    return failed


def _configured_health_validated(scan013_stdout: str) -> bool:
    match = re.search(r"(?m)^HEALTH_CHECK_HTTP=(\d{3})$", scan013_stdout or "")
    return bool(match and 200 <= int(match.group(1)) < 400)

def appraisal(component: Dict[str, Any], probes: List[Dict[str, Any]], scan_run_id: str) -> Dict[str, Any]:
    by_id = {p["probeId"]: p for p in probes}
    counts = {s: 0 for s in STATUSES}
    for p in probes:
        counts[p["status"]] += 1
    applicable = [p for p in probes if p["status"] != "NOT_APPLICABLE"]
    executed = [p for p in applicable if p["status"] != "SKIPPED_PREREQUISITE"]
    weight_total = sum(PROBES[p["probeId"]][4] for p in applicable)
    factor = {"PASS": 1, "PASS_WITH_WARNING": .85, "WARNING": .75, "PARTIAL": .5, "NOT_DETECTED": .5}
    evidence_score = round(100 * sum(PROBES[p["probeId"]][4] * factor.get(p["status"], 0) for p in applicable) / max(weight_total, 1))
    discovery_coverage = round(100 * len(executed) / max(len(applicable), 1))
    app_paths = filter_application_paths(by_id.get("SCAN-007", {}).get("stdout", "").splitlines())
    persistent = _relevant_persistent_paths(by_id.get("SCAN-010", {}).get("stdout", ""))
    secret_lines = [x.strip() for x in by_id.get("SCAN-018", {}).get("stdout", "").splitlines() if x.strip()]
    public_certs = sorted(set(x.split("PUBLIC_CERT_FILE:", 1)[-1] for x in secret_lines if x.startswith("PUBLIC_CERT_FILE:")))
    key_candidates = [x for x in secret_lines if not x.startswith(("PUBLIC_CERT_FILE:", "PLAINTEXT_SECRET_FILE:", "PLAINTEXT_SECRET_LOW_CONFIDENCE_FILE:", "ENV_SECRET_FILE:"))]
    private_key_paths = sorted(set(x for x in key_candidates if PRIVATE_KEY.search(x)))
    plaintext_file_paths = sorted(set(x.split("PLAINTEXT_SECRET_FILE:", 1)[-1] for x in secret_lines if x.startswith("PLAINTEXT_SECRET_FILE:")))
    low_confidence_secret_paths = sorted(set(x.split("PLAINTEXT_SECRET_LOW_CONFIDENCE_FILE:", 1)[-1] for x in secret_lines if x.startswith("PLAINTEXT_SECRET_LOW_CONFIDENCE_FILE:")))
    env_secret_paths = sorted(set(x.split("ENV_SECRET_FILE:", 1)[-1] for x in secret_lines if x.startswith("ENV_SECRET_FILE:")))
    # A confirmed secret assignment found inside actual source code is high-confidence and
    # would be baked into the container image; the same finding in a .env/config file is a
    # normal (if risky) config pattern that needs a redesign, not an automatic hard block.
    hardcoded_secret_paths = sorted(x for x in plaintext_file_paths if SOURCE_FILE_EXTENSION.search(x))
    config_value_matches = sorted(set(x.strip() for x in by_id.get("SCAN-011", {}).get("stdout", "").splitlines() if SECRET_VALUE.search(x)))
    config_secret_paths = sorted(set(x for x in plaintext_file_paths if not SOURCE_FILE_EXTENSION.search(x)) | set(env_secret_paths) | set(config_value_matches))
    db_output = by_id.get("SCAN-019", {}).get("stdout", "")
    db_detected = bool(re.search(r"(?i)\b(postgres(?:ql)?|mysqld|mariadbd|mongod|redis-server)\b|:(5432|3306|33060|27017|6379)\b", db_output) or any(DB_PATH.search(x) for x in persistent))
    failed_app_units = _application_health_status(by_id.get("SCAN-013", {}).get("stdout", ""))
    blockers = []
    warnings = []
    review_required = []
    readiness = 100
    if not _configured_health_validated(by_id.get("SCAN-013", {}).get("stdout", "")) and not failed_app_units:
        readiness -= 10; warnings.append({"code": "HEALTH_NOT_VALIDATED", "message": "Application health was not independently validated."})
    if not app_paths:
        readiness -= 20; warnings.append({"code": "APPLICATION_PATH_UNKNOWN", "message": "No approved application path was discovered."})
    if by_id.get("SCAN-012", {}).get("status") in {"PARTIAL", "FAIL", "BLOCKED"}:
        readiness -= 10; warnings.append({"code": "DEPENDENCY_EVIDENCE_INCOMPLETE", "message": "Outbound dependency evidence is incomplete."})
    ssh_failed = by_id.get("SCAN-001", {}).get("status") in {"FAIL", "BLOCKED"}
    # Persistent-storage evidence being unresolved is a migration design question (map the
    # path to a PVC/object store/external DB), not proof migration is unsafe -- REVIEW_REQUIRED,
    # not a hard BLOCKER. The component stays assessable; only deployment approval is gated.
    if not ssh_failed and by_id.get("SCAN-010", {}).get("status") in {"PARTIAL", "FAIL", "BLOCKED", "NOT_TESTED"}:
        readiness -= 10
        review_required.append({"code": "PERSISTENCE_UNKNOWN", "message": "Writable or persistent storage evidence is unresolved; map any confirmed persistent path to a PVC, object store, database or external service.",
                                "recommendedActions": ["Correlate writable-path evidence with process activity and service user before deciding on a migration method.", "Block deployment approval only if required data storage remains unmapped when Stage 8 is reached."]})
    if component.get("vmUuidUnmapped"):
        warnings.append({"code": "VM_UUID_UNMAPPED", "message": "Guest discovery succeeded over SSH, but no OpenStack server UUID is mapped, so snapshot-based capture is unavailable until it is mapped.",
                         "recommendedActions": remediation_for("VM_UUID_UNMAPPED")})
    if low_confidence_secret_paths:
        shown = low_confidence_secret_paths[:5]
        warnings.append({"code": "PLAINTEXT_SECRET_LOW_CONFIDENCE", "message": "A possible secret-like assignment was matched with low confidence (placeholder/example value): %s" % ", ".join(shown),
                         "recommendedActions": remediation_for("PLAINTEXT_SECRET_LOW_CONFIDENCE")})
    if ssh_failed:
        ssh_probe = by_id.get("SCAN-001", {})
        blockers.append({"code": ssh_probe.get("errorCode") or "SSH_ACCESS_FAILED", "kind": SEVERITY_BLOCKER_INFRASTRUCTURE,
                         "message": ssh_probe.get("diagnosticSummary") or ssh_probe.get("summary") or "SSH access failed.",
                         "rootCauseId": ssh_probe.get("rootCauseId"),
                         "recommendedActions": ssh_probe.get("recommendedActions") or remediation_for(probe.get("errorCode"))})
    if private_key_paths:
        shown = private_key_paths[:5]
        blockers.append({"code": "PRIVATE_KEY_CAPTURE_PATH", "kind": SEVERITY_BLOCKER_SECURITY,
                         "message": "A private key was detected in a potential capture path: %s" % ", ".join(shown),
                         "recommendedActions": remediation_for("PRIVATE_KEY_CAPTURE_PATH")})
    if hardcoded_secret_paths:
        shown = hardcoded_secret_paths[:5]
        warnings.append({"code": "PLAINTEXT_SECRET_HARDCODED",
                         "message": "A credential appears hardcoded in application source: %s" % ", ".join(shown),
                         "recommendedActions": remediation_for("PLAINTEXT_SECRET_HARDCODED")})
    if config_secret_paths:
        shown = config_secret_paths[:5]
        review_required.append({"code": "PLAINTEXT_SECRET_ENV_FILE", "message": "An environment/config file contains a confirmed credential: %s. This is normal for local config, but do not bake the file into the container image unchanged." % ", ".join(shown),
                                "recommendedActions": remediation_for("PLAINTEXT_SECRET_ENV_FILE")})
    if failed_app_units:
        blockers.append({"code": "APPLICATION_HEALTH_CHECK_FAILED", "kind": SEVERITY_BLOCKER_APPLICATION,
                         "message": "The application's own service is reporting a failed unit: %s" % ", ".join(failed_app_units),
                         "recommendedActions": remediation_for("APPLICATION_HEALTH_CHECK_FAILED")})
    security_blockers = [b for b in blockers if b.get("kind") == SEVERITY_BLOCKER_SECURITY]
    application_blockers = [b for b in blockers if b.get("kind") == SEVERITY_BLOCKER_APPLICATION]
    if blockers:
        recommendation, capture, verdict, state = "BLOCKED", "BLOCKED", "BLOCKED", "UNKNOWN"
    elif db_detected:
        recommendation, capture, verdict, state = "DB_NATIVE_MIGRATION", "DB_NATIVE", "DB_NATIVE_REQUIRED", "STATEFUL"
    elif any(p["status"] in {"FAIL", "BLOCKED", "NOT_TESTED"} for p in probes if p["probeId"] in {"SCAN-001", "SCAN-002", "SCAN-004", "SCAN-005", "SCAN-007"}):
        recommendation, capture, verdict, state = "MANUAL_REVIEW", "BLOCKED", "NEEDS_MORE_EVIDENCE", "UNKNOWN"
    elif review_required:
        # Evidence exists and discovery is complete, but a migration-design decision remains.
        # The component is assessable -- it is not blocked -- so Stage 8 is gated, not discovery.
        recommendation, capture, verdict, state = "MANUAL_REVIEW", "LIVE_ONLY", "REVIEW_REQUIRED", "STATELESS" if not persistent else "MIXED"
    elif readiness >= 85 and not warnings:
        recommendation, capture, verdict, state = "STRONG_CONTAINER_CANDIDATE", "LIVE_PLUS_SNAPSHOT", "READY_FOR_STAGE_8", "STATELESS"
    elif readiness >= 70:
        recommendation, capture, verdict, state = "CANDIDATE_WITH_REMEDIATION", "LIVE_PLUS_SNAPSHOT", "READY_FOR_STAGE_8_WITH_WARNINGS", "STATELESS" if not persistent else "MIXED"
    else:
        recommendation, capture, verdict, state = "MANUAL_REVIEW", "LIVE_ONLY", "NEEDS_MORE_EVIDENCE", "UNKNOWN"
    if component.get("vmUuidUnmapped") and capture == "LIVE_PLUS_SNAPSHOT":
        capture = "LIVE_ONLY"  # snapshot-based capture needs the OpenStack server UUID
    if security_blockers:
        verdict = "BLOCKED_SECURITY"
    elif application_blockers:
        verdict = "BLOCKED_APPLICATION"
    if ssh_failed:
        verdict = "BLOCKED_INFRASTRUCTURE"; recommendation = "BLOCKED_INFRASTRUCTURE"; capture = "CLOUD_CHECK_PARTIAL"
    probe_summary = {"pass": counts["PASS"], "passWithWarning": counts["PASS_WITH_WARNING"], "warning": counts["WARNING"], "partial": counts["PARTIAL"], "fail": counts["FAIL"], "blocked": counts["BLOCKED"], "skippedPrerequisite": counts["SKIPPED_PREREQUISITE"], "notDetected": counts["NOT_DETECTED"], "notApplicable": counts["NOT_APPLICABLE"], "notTested": counts["NOT_TESTED"], "completed": len(executed), "applicable": len(applicable)}
    source_vm_id = component.get("sourceVmId") or component.get("vmId") or component.get("source_vm_id")
    return {"componentId": _slug(component.get("id") or component.get("name") or "component"), "componentName": component.get("name") or "Component", "sourceVmId": source_vm_id, "sourceVmName": component.get("sourceVmName") or component.get("source_vm_name") or component.get("vmName"), "sourceIp": component.get("sourceIp") or component.get("source_ip") or component.get("sshHost"), "sshUser": component.get("sshUser") or component.get("ssh_user"), "cloudRegion": component.get("cloudRegion") or component.get("cloud_region"), "scanTargetId": component.get("scanTargetId") or component.get("scan_target_id") or source_vm_id, "sourceHost": component.get("sshHost") or component.get("targetIp") or component.get("target") or component.get("tgt"), "sshPort": component.get("sshPort") or 22, "databaseAccessMode": component.get("databaseAccessMode"), "requiredForBusinessTransaction": component.get("requiredForBusinessTransaction") if component.get("requiredForBusinessTransaction") is not None else component.get("critical") if component.get("critical") is not None else True, "scanRunId": scan_run_id, "scanStatus": "COMPLETE", "probeSummary": probe_summary, "evidenceCompletenessScore": evidence_score, "discoveryCoveragePercent": discovery_coverage, "containerReadinessScore": max(0, readiness), "stateClassification": state, "captureRecommendation": capture, "containerizationRecommendation": recommendation, "componentVerdict": verdict, "runtime": _runtime(by_id.get("SCAN-003", {}).get("stdout", "")), "services": _relevant_services(by_id.get("SCAN-005", {}).get("stdout", "")), "ports": _ports(by_id.get("SCAN-006", {}).get("stdout", "")), "applicationPaths": app_paths, "writablePaths": _writable_paths(by_id.get("SCAN-009", {}).get("stdout", "")), "configurationPaths": _relevant_config_paths(by_id.get("SCAN-011", {}).get("stdout", "")), "persistentPaths": persistent, "certificatesFound": public_certs, "processes": _relevant_processes(by_id.get("SCAN-004", {}).get("stdout", "")), "outboundDependencies": _outbound_dependencies(by_id.get("SCAN-012", {}).get("stdout", ""), int(component.get("sshPort") or 22)), "containerConstraints": _relevant_container_constraints(by_id.get("SCAN-016", {}).get("stdout", "")), "excludedPaths": ["/home/*/.ssh", "/root/.ssh", "/var/log", "/tmp", "/var/tmp"], "warnings": warnings, "reviewRequired": review_required, "blockers": blockers, "recommendedActions": list(dict.fromkeys([action for item in warnings + review_required + blockers for action in (item.get("recommendedActions") or [item.get("message")]) if action])), "probes": probes}


def _required_for_business_transaction(component: Dict[str, Any]) -> bool:
    value = component.get("requiredForBusinessTransaction")
    if value is not None:
        return bool(value)
    critical = component.get("critical")
    return True if critical is None else bool(critical)


def final_appraisal(run_id: str, system: Dict[str, Any], components: List[Dict[str, Any]]) -> Dict[str, Any]:
    verdicts = [c["componentVerdict"] for c in components]
    mapping_warnings = []
    for index, left in enumerate(components):
        left_services = set(left.get("services") or [])
        for right in components[index + 1:]:
            overlap = left_services.intersection(right.get("services") or [])
            if overlap and left.get("sourceVmId") != right.get("sourceVmId"):
                mapping_warnings.append("POSSIBLE_HA_OR_CLONE: %s and %s share %s" % (left["componentName"], right["componentName"], ", ".join(sorted(overlap)[:3])))
    partial_scope = int(system.get("totalComponentCount") or len(components)) > len(components)
    all_probes = [p for c in components for p in c.get("probes", [])]
    root_probes = [p for p in all_probes if p.get("status") in {"FAIL", "BLOCKED"}]
    # Critical-path rule: a component blocker affects the Business System only when the
    # component is required_for_business_transaction=true AND its status is BLOCKED*.
    # Optional components (reporting, monitoring, non-critical scheduled jobs) never
    # block the whole Business System on their own.
    required_components = [c for c in components if _required_for_business_transaction(c)]
    required_probes = [p for c in required_components for p in c.get("probes", [])]
    required_root_probes = [p for p in required_probes if p.get("status") in {"FAIL", "BLOCKED"}]
    infra_codes = {p.get("errorCode") for p in required_root_probes
                   if (p.get("errorCode") or "").startswith("SSH_") or (p.get("errorCode") or "") in
                   {"COMPONENT_VM_MAPPING_MISSING", "TARGET_RESOLUTION_FAILED"}}
    infrastructure = "BLOCKED" if infra_codes else ("PARTIAL" if any(p.get("status") in {"PASS_WITH_WARNING", "PARTIAL"} and p.get("probeId") == "SCAN-001" for p in all_probes) else "READY")
    security_components = [c for c in required_components if c.get("componentVerdict") == "BLOCKED_SECURITY"]
    application_blocked_components = [c for c in required_components if c.get("componentVerdict") == "BLOCKED_APPLICATION"]
    blocked_verdicts = {"BLOCKED", "BLOCKED_SECURITY", "BLOCKED_APPLICATION"}
    app_components = [c for c in components if c.get("componentVerdict") != "DB_NATIVE_REQUIRED"]
    if infrastructure == "BLOCKED": application = "UNKNOWN"
    elif any(c.get("componentVerdict") in blocked_verdicts for c in app_components): application = "BLOCKED"
    elif any(c.get("componentVerdict") in {"NEEDS_MORE_EVIDENCE", "MANUAL_REVIEW_REQUIRED", "REVIEW_REQUIRED"} for c in app_components): application = "REVIEW_REQUIRED"
    else: application = "READY"
    db_components = [c for c in components if c.get("databaseAccessMode") not in {None, "VM_SSH"} or c.get("componentVerdict") == "DB_NATIVE_REQUIRED"]
    db_native_statuses = [next((p.get("status") for p in c.get("probes", []) if p.get("probeId") == "SCAN-019"), "NOT_TESTED") for c in db_components]
    if not db_components: database = "NOT_APPLICABLE"
    elif any(c.get("componentVerdict") in blocked_verdicts | {"BLOCKED_INFRASTRUCTURE"} for c in db_components) or any(status in {"FAIL", "BLOCKED"} for status in db_native_statuses): database = "BLOCKED"
    elif all(status == "PASS" for status in db_native_statuses): database = "READY"
    else: database = "REVIEW_REQUIRED"
    snapshot_probes = [p for p in all_probes if p.get("probeId") == "SCAN-020"]
    snapshot_applicable = [p for p in snapshot_probes if p.get("status") != "NOT_APPLICABLE"]
    snapshot = "NOT_APPLICABLE" if snapshot_probes and not snapshot_applicable else "READY" if snapshot_applicable and all(p.get("status") == "PASS" for p in snapshot_applicable) else "UNKNOWN" if snapshot_applicable and any(p.get("status") == "NOT_TESTED" for p in snapshot_applicable) else "PARTIAL" if snapshot_applicable else "UNKNOWN"
    if infrastructure == "BLOCKED": containerization = final = "BLOCKED_INFRASTRUCTURE"
    elif security_components: containerization = final = "BLOCKED_SECURITY"
    elif application_blocked_components: containerization = final = "BLOCKED_APPLICATION"
    elif application in {"BLOCKED", "REVIEW_REQUIRED", "UNKNOWN"} or database in {"BLOCKED", "REVIEW_REQUIRED", "UNKNOWN"} or partial_scope or mapping_warnings: containerization = final = "REVIEW_REQUIRED"
    elif any(p.get("status") == "FAIL" and not p.get("derivedFrom") for p in all_probes): containerization = final = "REVIEW_REQUIRED"
    elif any(c.get("componentVerdict") == "READY_FOR_STAGE_8_WITH_WARNINGS" for c in components): containerization = final = "READY_WITH_WARNINGS"
    else: containerization = final = "READY"
    def n(*values): return sum(v in values for v in verdicts)
    scope_warning = ["Only %s of %s components were scanned; scan the remaining components before full-system approval." % (len(components), system.get("totalComponentCount"))] if partial_scope else []
    applicable = [p for p in all_probes if p.get("status") != "NOT_APPLICABLE"]
    completed = [p for p in applicable if p.get("status") != "SKIPPED_PREREQUISITE"]
    skipped = [p for p in all_probes if p.get("status") == "SKIPPED_PREREQUISITE"]
    not_applicable = [p for p in all_probes if p.get("status") == "NOT_APPLICABLE"]
    coverage = round(100 * len(completed) / max(len(applicable), 1))
    root_causes = []
    seen = set()
    for component in components:
        for probe in component.get("probes", []):
            if probe.get("status") not in {"FAIL", "BLOCKED"}: continue
            key = probe.get("rootCauseId") or "%s:%s:%s" % (component.get("componentId"), probe.get("probeId"), probe.get("errorCode"))
            if key in seen: continue
            seen.add(key); root_causes.append({"rootCauseId": key, "componentId": component.get("componentId"), "componentName": component.get("componentName"), "sourceVmId": component.get("sourceVmId"), "targetHost": component.get("sourceHost"), "probeId": probe.get("probeId"), "errorCode": probe.get("errorCode"), "oldFingerprint": probe.get("oldFingerprint"), "newFingerprint": probe.get("newFingerprint"), "summary": probe.get("diagnosticSummary") or probe.get("summary"), "recommendedActions": probe.get("recommendedActions") or remediation_for(probe.get("errorCode")), "skippedChecks": sum(1 for p in component.get("probes", []) if p.get("derivedFrom") == key)})
        for blocker in component.get("blockers", []):
            key = blocker.get("rootCauseId") or "%s:%s" % (component.get("componentId"), blocker.get("code"))
            if key in seen: continue
            seen.add(key); root_causes.append({"rootCauseId": key, "componentId": component.get("componentId"), "componentName": component.get("componentName"), "sourceVmId": component.get("sourceVmId"), "probeId": None, "errorCode": blocker.get("code"), "summary": blocker.get("message"), "recommendedActions": blocker.get("recommendedActions") or remediation_for(blocker.get("code")), "skippedChecks": 0})
    next_action = "Scan the remaining components before full-system approval." if partial_scope else "Resolve infrastructure access root causes, then retry only affected VMs." if infrastructure == "BLOCKED" else "Restore database endpoint reachability, then retry the database component." if database == "BLOCKED" else "Review application and database findings before Stage 8 approval." if final == "REVIEW_REQUIRED" else "Continue to Stage 7 classification and Stage 8 approval."
    reason = "Several source VMs could not be accessed; no application incompatibility is inferred." if infrastructure == "BLOCKED" else "The database-native endpoint is not ready; probe execution itself completed successfully." if database == "BLOCKED" else "Assessment is based on applicable completed checks."
    return {"businessSystemId": system.get("id"), "businessSystemName": system.get("name"), "scanRunId": run_id, "scanScope": system.get("scanScope") or "ALL_COMPONENTS", "finalVerdict": final, "discoveryCoveragePercent": coverage, "infrastructureAccessStatus": infrastructure, "applicationReadiness": application, "databaseReadiness": database, "snapshotReadiness": snapshot, "containerizationReadiness": containerization, "reason": reason, "overallEvidenceScore": coverage, "evidenceCoverage": {"completed": len(completed), "applicable": len(applicable), "blocked": len(root_probes), "skipped": len(skipped), "notApplicable": len(not_applicable)}, "rootCauses": root_causes, "summary": {"sourceVms": len(set(c.get("sourceVmId") for c in components if c.get("sourceVmId"))), "components": len(components), "totalComponents": int(system.get("totalComponentCount") or len(components)), "ready": n("READY_FOR_STAGE_8"), "readyWithWarnings": n("READY_FOR_STAGE_8_WITH_WARNINGS"), "databaseNative": n("DB_NATIVE_REQUIRED"), "retainVm": n("RETAIN_VM_RECOMMENDED"), "needsReview": n("NEEDS_MORE_EVIDENCE", "MANUAL_REVIEW_REQUIRED", "REVIEW_REQUIRED"), "blocked": n("BLOCKED", "BLOCKED_INFRASTRUCTURE", "BLOCKED_SECURITY", "BLOCKED_APPLICATION"), "scanFailed": n("SCAN_FAILED")}, "systemWarnings": [w["message"] for c in components for w in c["warnings"]] + mapping_warnings + scope_warning, "mappingWarnings": mapping_warnings, "systemBlockers": [b["message"] for c in components for b in c["blockers"]] + [p.get("diagnosticSummary") or p.get("summary") for p in root_probes], "nextAction": next_action}


# --- Stage-specific gating -------------------------------------------------
# A finding must not block every migration stage equally (see design-template
# scanner status contract). This table and the two functions below are the
# real, callable implementation Stage 4-7 code can invoke; nothing here is
# hypothetical/unused -- it is wired to /api/r6/scans/runs/<id>/stage-gate/<stage>.
MIGRATION_STAGES = ("DISCOVERY", "CONTAINER_PACKAGE_GENERATION", "TARGET_DEPLOYMENT", "UAT", "CUTOVER")

STAGE_GATING: Dict[str, Dict[str, str]] = {
    "SSH_ACCESS_FAILED": {"DISCOVERY": "BLOCK", "CONTAINER_PACKAGE_GENERATION": "REVIEW", "TARGET_DEPLOYMENT": "REVIEW", "UAT": "REVIEW", "CUTOVER": "BLOCK"},
    "COMPONENT_VM_MAPPING_MISSING": {"DISCOVERY": "PARTIAL", "CONTAINER_PACKAGE_GENERATION": "REVIEW", "TARGET_DEPLOYMENT": "BLOCK", "UAT": "REVIEW", "CUTOVER": "REVIEW"},
    "VM_UUID_UNMAPPED": {"DISCOVERY": "PARTIAL", "CONTAINER_PACKAGE_GENERATION": "REVIEW", "TARGET_DEPLOYMENT": "BLOCK", "UAT": "REVIEW", "CUTOVER": "REVIEW"},
    "PLAINTEXT_SECRET_LOW_CONFIDENCE": {"DISCOVERY": "ALLOW", "CONTAINER_PACKAGE_GENERATION": "REVIEW", "TARGET_DEPLOYMENT": "REVIEW", "UAT": "ALLOW", "CUTOVER": "ALLOW"},
    "PRIVATE_KEY_CAPTURE_PATH": {"DISCOVERY": "ALLOW", "CONTAINER_PACKAGE_GENERATION": "BLOCK", "TARGET_DEPLOYMENT": "BLOCK", "UAT": "BLOCK", "CUTOVER": "BLOCK"},
    "PLAINTEXT_SECRET_HARDCODED": {"DISCOVERY": "ALLOW", "CONTAINER_PACKAGE_GENERATION": "REVIEW", "TARGET_DEPLOYMENT": "REVIEW", "UAT": "REVIEW", "CUTOVER": "REVIEW"},
    "PLAINTEXT_SECRET_ENV_FILE": {"DISCOVERY": "ALLOW", "CONTAINER_PACKAGE_GENERATION": "REVIEW", "TARGET_DEPLOYMENT": "REVIEW", "UAT": "ALLOW", "CUTOVER": "ALLOW"},
    "HEALTH_NOT_VALIDATED": {"DISCOVERY": "ALLOW", "CONTAINER_PACKAGE_GENERATION": "ALLOW", "TARGET_DEPLOYMENT": "ALLOW", "UAT": "BLOCK", "CUTOVER": "BLOCK"},
    "APPLICATION_HEALTH_CHECK_FAILED": {"DISCOVERY": "REVIEW", "CONTAINER_PACKAGE_GENERATION": "REVIEW", "TARGET_DEPLOYMENT": "BLOCK", "UAT": "BLOCK", "CUTOVER": "BLOCK"},
    "PERSISTENCE_UNKNOWN": {"DISCOVERY": "ALLOW", "CONTAINER_PACKAGE_GENERATION": "REVIEW", "TARGET_DEPLOYMENT": "BLOCK", "UAT": "BLOCK", "CUTOVER": "BLOCK"},
    "DATABASE_NATIVE_ASSESSMENT_MISSING": {"DISCOVERY": "PARTIAL", "CONTAINER_PACKAGE_GENERATION": "REVIEW", "TARGET_DEPLOYMENT": "BLOCK", "UAT": "BLOCK", "CUTOVER": "BLOCK"},
}


def _stage_gate_key(finding_code: Optional[str]) -> str:
    code = finding_code or ""
    return "SSH_ACCESS_FAILED" if code.startswith("SSH_") else code


def blocks_current_stage(finding_code: str, stage: str, component_required: bool) -> bool:
    if stage not in MIGRATION_STAGES:
        raise ValueError("unknown migration stage: %s" % stage)
    if STAGE_GATING.get(_stage_gate_key(finding_code), {}).get(stage) != "BLOCK":
        return False
    return component_required


def evaluate_stage_gate(components: List[Dict[str, Any]], stage: str) -> Dict[str, Any]:
    """Real, callable stage gate: walk every component's blockers/reviewRequired/warnings
    and decide whether `stage` can proceed, honoring the critical-path rule (an optional
    component's finding is surfaced for review but never blocks the stage)."""
    if stage not in MIGRATION_STAGES:
        raise ValueError("unknown migration stage: %s" % stage)
    blocking, review = [], []
    for component in components:
        required = _required_for_business_transaction(component)
        findings = list(component.get("blockers") or []) + list(component.get("reviewRequired") or []) + list(component.get("warnings") or [])
        for finding in findings:
            code = finding.get("code")
            action = STAGE_GATING.get(_stage_gate_key(code), {}).get(stage)
            if action is None or action == "ALLOW":
                continue
            entry = {"componentId": component.get("componentId"), "componentName": component.get("componentName"),
                     "code": code, "action": action, "message": finding.get("message"), "requiredForBusinessTransaction": required}
            if action == "BLOCK" and required:
                blocking.append(entry)
            else:
                review.append(entry)
    return {"stage": stage, "blocked": bool(blocking), "blockingFindings": blocking, "reviewFindings": review}


def _runtime(text: str) -> Dict[str, Any]:
    first = next((x.strip() for x in text.splitlines() if x.strip()), "")
    kind = next((k for k in ("python", "java", "node", "php", "dotnet", "go") if k in first.lower()), "unknown")
    version = (re.search(r"\d+(?:\.\d+)+", first) or [None])[0]
    return {"type": kind, "version": version}


def _lines(by_id: Dict[str, Dict[str, Any]], probe_id: str, limit: int) -> List[str]:
    return [x.strip() for x in by_id.get(probe_id, {}).get("stdout", "").splitlines() if x.strip()][:limit]


def _relevant_services(text: str, limit: int = 20) -> List[str]:
    """Drop host/hypervisor/agent background services -- excess OS noise, not a migration signal."""
    return [x.strip() for x in text.splitlines() if x.strip() and not IRRELEVANT_SERVICE_NOISE.search(x)][:limit]


def _relevant_config_paths(text: str, limit: int = 30) -> List[str]:
    """Drop whole-host OS baseline config (network, apt, pam, etc.) that is not app-specific."""
    return [x.strip() for x in text.splitlines() if x.strip() and not OS_CONFIG_NOISE.search(x.strip())][:limit]


def _relevant_persistent_paths(text: str) -> List[str]:
    """Drop OS/package-manager maintenance directories under /var/lib that are not application data."""
    return sorted(set(x.strip() for x in text.splitlines() if x.strip() and not MAINTENANCE_DIR_NOISE.search(x)))


def _relevant_processes(text: str, limit: int = 30) -> List[str]:
    """Drop kernel threads (`[kworker/0:1]`) and PID/PPID housekeeping columns -- not application evidence."""
    result = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        fields = line.split(None, 4)
        comm = fields[3] if len(fields) > 3 else ""
        if KERNEL_THREAD.match(comm) or IRRELEVANT_SERVICE_NOISE.search(comm):
            continue
        result.append(line)
    return result[:limit]


def _outbound_dependencies(text: str, scanner_port: int = 22) -> List[str]:
    """Drop the scanner's own inbound SSH session from outbound-dependency evidence -- it is
    administrative traffic, not something the application depends on."""
    result = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        local = re.search(r"\S+:(\d{1,5})\s", line + " ")
        if local and int(local.group(1)) == scanner_port:
            continue
        result.append(line)
    return result


def _relevant_container_constraints(text: str, limit: int = 40) -> List[str]:
    """Drop generic virtual devices (tty/loop/null/...) that every host exposes and that the
    application does not specifically require."""
    result = []
    for line in text.splitlines():
        line = line.strip()
        if not line or (line.startswith("/dev/") and GENERIC_DEVICE_NOISE.match(line)):
            continue
        result.append(line)
    return result[:limit]


def _ports(text: str) -> List[int]:
    return sorted(set(int(x) for x in re.findall(r":(\d{1,5})\b", text) if int(x) <= 65535))


def _writable_paths(text: str) -> List[Dict[str, Any]]:
    values = []
    for line in text.splitlines():
        match = re.match(r"path=(.*?) owner=(\S+) group=(\S+) permissions=(\S+) writable=(\S+)", line.strip())
        if not match: continue
        path, owner, group, permissions, writable = match.groups()
        lower = path.lower()
        classification = "LOGGING" if "/log" in lower else "CACHE" if "cache" in lower else "TEMPORARY" if "/tmp" in lower else "PERSISTENT_REQUIRED" if re.search(r"upload|data|state|var/lib", lower) else "UNKNOWN"
        values.append({"path": path, "owner": owner, "group": group, "permissions": permissions,
                       "mount": "UNKNOWN", "filesystemType": "UNKNOWN", "writable": writable == "true",
                       "persistenceRecommendation": classification, "evidenceSource": "SCAN-009"})
    return values


def _slug(value: Any) -> str:
    return re.sub(r"[^a-z0-9]+", "-", str(value).lower()).strip("-") or "component"


def _record_live_probe(run: Dict[str, Any], component: Dict[str, Any], probe: Dict[str, Any],
                       completed: int, total: int, persist: Callable[[Dict[str, Any]], None]) -> None:
    status = probe.get("status") or "UNKNOWN"
    live_limit = 16 * 1024
    stdout = redact(str(probe.get("stdout") or ""))
    stderr = redact(str(probe.get("stderr") or ""))
    stdout_live = stdout[:live_limit] + ("\n[LIVE TERMINAL OUTPUT TRUNCATED; see evidence archive]" if len(stdout) > live_limit else "")
    stderr_live = stderr[:live_limit] + ("\n[LIVE TERMINAL OUTPUT TRUNCATED; see evidence archive]" if len(stderr) > live_limit else "")
    event = {"timestamp": utcnow(), "level": "ERROR" if status in {"FAIL", "BLOCKED"} else "WARN" if status in {"WARNING", "PASS_WITH_WARNING", "PARTIAL", "NOT_DETECTED"} else "DEBUG" if status == "SKIPPED_PREREQUISITE" else "INFO",
             "component": component.get("name"), "probeId": probe.get("probeId"), "probeName": probe.get("probeName"),
             "sourceVmId": component.get("vmId") or component.get("sourceVmId"),
             "targetHost": component.get("sshHost") or component.get("sourceHost") or component.get("targetIp"),
             "targetPort": component.get("sshPort") or 22, "phase": "REMOTE_PROBE_EXECUTION",
             "status": status, "exitCode": probe.get("exitCode"), "durationMs": probe.get("durationMs"),
             "commandIdentifier": probe.get("commandIdentifier"), "startedAt": probe.get("startedAt"), "completedAt": probe.get("completedAt"),
             "timeout": bool(probe.get("timeout")), "truncated": bool(probe.get("truncated")),
             "evidenceCount": probe.get("evidenceCount"), "message": "Probe completed",
             "stdout": stdout_live, "stderr": stderr_live,
             "remediation": probe.get("remediation") or ("Resolve the failed check and retry this component." if status in {"FAIL", "BLOCKED"} else "")}
    run.setdefault("liveLog", []).append(event)
    run["liveLog"] = run["liveLog"][-500:]
    progress = dict(run.get("progress") or {})
    progress.update({"currentProbe": probe.get("probeId"), "currentProbeName": probe.get("probeName"),
                     "completedProbes": completed, "totalProbes": total})
    run["progress"] = progress
    persist(run)


def _record_live_probe_start(run: Dict[str, Any], component: Dict[str, Any], probe_id: str,
                             completed: int, total: int, persist: Callable[[Dict[str, Any]], None]) -> None:
    _, title, _, timeout, _ = PROBES[probe_id]
    run.setdefault("liveLog", []).append({"timestamp": utcnow(), "level": "DEBUG", "component": component.get("name"),
                                          "probeId": probe_id, "probeName": title, "commandIdentifier": probe_id,
                                          "sourceVmId": component.get("vmId") or component.get("sourceVmId"),
                                          "targetHost": component.get("sshHost") or component.get("sourceHost") or component.get("targetIp"),
                                          "targetPort": component.get("sshPort") or 22, "phase": "REMOTE_PROBE_EXECUTION",
                                          "message": "Probe started", "status": "RUNNING", "timeoutSeconds": timeout})
    run["liveLog"] = run["liveLog"][-500:]
    progress = dict(run.get("progress") or {})
    progress.update({"currentProbe": probe_id, "currentProbeName": title, "completedProbes": completed, "totalProbes": total})
    run["progress"] = progress
    persist(run)


def _mapping_probe(component: Dict[str, Any]) -> Dict[str, Any]:
    started = time.monotonic(); started_at = utcnow()
    result = _probe_result("MAP-001", "Component VM Mapping", started_at, started, 2, "", "Component has no OpenStack server UUID mapping.", False, False, "BLOCKED")
    result.update(_error_fields("COMPONENT_VM_MAPPING_MISSING", "MAPPING"))
    result.update({"componentId": component.get("id") or component.get("name"), "targetId": component.get("scanTargetId")})
    result["remediation"] = result["recommendedActions"][0]
    return result


def _skipped_probe(probe_id: str, prerequisite: Dict[str, Any]) -> Dict[str, Any]:
    _, title, _, _, _ = PROBES[probe_id]
    result = _probe_result(probe_id, title, utcnow(), time.monotonic(), None, "", "", False, False, "SKIPPED_PREREQUISITE")
    root_id = prerequisite.get("rootCauseId") or "%s:%s" % (prerequisite.get("probeId"), prerequisite.get("errorCode") or "FAILED")
    result.update({"prerequisiteProbeId": prerequisite.get("probeId"), "prerequisite_check_id": prerequisite.get("probeId"),
                   "derivedFrom": root_id, "derived_from": root_id, "rootCauseId": root_id,
                   "summary": "Skipped because %s failed." % prerequisite.get("probeId"), "retryable": True,
                   "severity": "INFO", "recommendedActions": [], "remediation": "Repair and retry the prerequisite check."})
    return result


def _cloud_snapshot_probe(component: Dict[str, Any]) -> Dict[str, Any]:
    started = time.monotonic(); started_at = utcnow()
    cloud = component.get("cloudInventory") or component.get("cloud_inventory") or {}
    vm_id = component.get("sourceVmId") or component.get("vmId") or component.get("source_vm_id")
    evidence = {"vmId": vm_id, "vmStatus": cloud.get("status") or component.get("vmStatus") or "UNKNOWN",
                "bootSource": cloud.get("bootSource") or component.get("bootSource") or "UNKNOWN",
                "volumeIds": cloud.get("volumeIds") or component.get("volumeIds") or [],
                "imageVisible": cloud.get("imageVisible"), "snapshotCapable": cloud.get("snapshotCapable")}
    # Missing VM UUID makes snapshot readiness genuinely UNKNOWN (not a failure): the
    # scanner has no evidence either way, so it must not be reported as PASS or FAIL.
    capability = evidence["snapshotCapable"]
    access_mode = _database_access_mode(component)
    if access_mode in {"MANAGED_DATABASE", "KUBERNETES_SERVICE", "PRIVATE_ENDPOINT", "UNKNOWN"}:
        result = _probe_result("SCAN-020", "Snapshot Source Readiness (cloud control plane)", started_at, started, 0,
                               json.dumps(evidence, sort_keys=True), "", False, False, "NOT_APPLICABLE")
        result.update({"evidence": evidence, "summary": "VM snapshot capture is not applicable to this database-native endpoint.",
                       "recommendedActions": [], "remediation": ""})
        return result

    status = "NOT_TESTED" if not vm_id or capability is None else "PASS" if capability is True else "PASS_WITH_WARNING"
    result = _probe_result("SCAN-020", "Snapshot Source Readiness (cloud control plane)", started_at, started, 0,
                           json.dumps(evidence, sort_keys=True), "", False, False, status)
    actions = (["Map the component to an OpenStack server UUID to enable snapshot-based capture."] if not vm_id else
               ["Load OpenStack inventory for this VM before claiming snapshot readiness."] if capability is None else
               [] if status == "PASS" else ["Confirm image and volume snapshot capability in OpenStack."])
    result.update({"evidence": evidence, "summary": "Cloud-side snapshot readiness assessed independently of guest SSH." if vm_id else "Snapshot readiness is unknown: no OpenStack server UUID is mapped for this component.",
                   "recommendedActions": actions, "remediation": actions[0] if actions else ""})
    if vm_id and capability is None:
        result.update(_error_fields("SNAPSHOT_CAPABILITY_UNKNOWN", "CLOUD_INVENTORY"))
        result["operatorActionRequired"] = False
        result["severity"] = "WARNING"
    if not vm_id:
        result.update(_error_fields("VM_UUID_UNMAPPED", "MAPPING"))
        result["operatorActionRequired"] = False
        result["severity"] = "WARNING"  # UNKNOWN evidence, not a confirmed failure
    return result


def _database_access_mode(component: Dict[str, Any]) -> str:
    value = str(component.get("databaseAccessMode") or component.get("database_access_mode") or component.get("databaseTargetType") or "").upper()
    aliases = {"VM_HOSTED": "VM_SSH", "EXTERNAL_DATABASE": "PRIVATE_ENDPOINT", "KUBERNETES_DATABASE": "KUBERNETES_SERVICE"}
    if value:
        return aliases.get(value, value)
    kind = str(component.get("type") or component.get("role") or "").lower()
    endpoint = str(component.get("target") or component.get("tgt") or component.get("sshHost") or "").lower()
    if "database" not in kind and not re.match(r"^(postgres(?:ql)?|mysql|mongodb|redis)://", endpoint):
        return "VM_SSH"
    if component.get("vmId") or component.get("sourceVmId"):
        return "VM_SSH"
    ssh_key = component.get("sshKeyPath") or component.get("ssh_key_path") or component.get("sshKey")
    ssh_user = component.get("sshUser") or component.get("ssh_user")
    return "VM_SSH" if endpoint and ssh_key and ssh_user else "UNKNOWN"


def normalize_component_mapping(component: Dict[str, Any], default_ssh_user: Optional[str] = None) -> Dict[str, Any]:
    item = dict(component)
    vm_id = next((item.get(key) for key in ("sourceVmId", "source_vm_id", "vmId", "vm_id", "openstackServerId", "serverId", "flexVmId") if item.get(key)), None)
    vm_name = next((item.get(key) for key in ("sourceVmName", "source_vm_name", "vmName", "vm_name", "serverName") if item.get(key)), None)
    source_ip = next((item.get(key) for key in ("sourceIp", "source_ip") if item.get(key)), None)
    target_ip = next((item.get(key) for key in ("sshHost", "targetHost", "targetIp", "target_ip", "target", "tgt") if item.get(key)), None)
    source_ip = source_ip or target_ip  # response compatibility only; never selected as an executable target
    item.update({"sourceVmId": vm_id, "source_vm_id": vm_id, "sourceVmName": vm_name,
                 "source_vm_name": vm_name, "sourceIp": source_ip, "source_ip": source_ip,
                 "targetIp": target_ip, "target_ip": target_ip,
                 "targetHost": target_ip, "sshHost": target_ip,
                 "sshUser": item.get("sshUser") or item.get("ssh_user") or default_ssh_user,
                 "ssh_user": item.get("sshUser") or item.get("ssh_user") or default_ssh_user,
                 "cloudRegion": item.get("cloudRegion") or item.get("cloud_region"),
                 "scanTargetId": item.get("scanTargetId") or item.get("scan_target_id") or vm_id,
                 "scan_target_id": item.get("scanTargetId") or item.get("scan_target_id") or vm_id})
    return item


def _managed_database_probes(component: Dict[str, Any]) -> List[Dict[str, Any]]:
    endpoint = str(component.get("databaseEndpoint") or component.get("target") or component.get("tgt") or component.get("sshHost") or "")
    parsed = urlparse(endpoint if "://" in endpoint else "//" + endpoint)
    engine = ((re.match(r"(?i)^([a-z0-9+.-]+)://", endpoint) or [None, "unknown"])[1]).lower()
    default_ports = {"postgres": 5432, "postgresql": 5432, "mysql": 3306, "mariadb": 3306, "mongodb": 27017, "redis": 6379}
    host = parsed.hostname; port = parsed.port or default_ports.get(engine)
    reachability = component.get("databaseReachability")
    reachability_error = ""
    if not reachability and host and port:
        try:
            connection = socket.create_connection((host, port), timeout=2); connection.close(); reachability = "REACHABLE"
        except OSError as exc:
            reachability = "UNREACHABLE"; reachability_error = redact(str(exc))
    reachability = reachability or "NOT_TESTED"
    started = time.monotonic(); started_at = utcnow()
    ssh = _probe_result("SCAN-001", "SSH Connectivity", started_at, started, None, "", "", False, False, "NOT_APPLICABLE")
    ssh.update({"summary": "Direct SSH is not applicable to this database access mode.", "retryable": False})
    native_evidence = {"engine": engine, "endpoint": re.sub(r"(?i)://.*@", "://[REDACTED]@", endpoint),
                       "tls": component.get("databaseTls") or "UNKNOWN", "version": component.get("databaseVersion"),
                       "endpointReachability": reachability,
                       "databaseNames": component.get("databaseNames") or [],
                       "replicationMode": component.get("replicationMode") or "UNKNOWN",
                       "backupCapability": component.get("backupCapability") or "UNKNOWN",
                       "migrationMethod": "native dump/restore or replication"}
    native_status = "PASS" if engine in {"postgres", "postgresql", "mysql", "mariadb", "mongodb", "redis"} and reachability == "REACHABLE" else "FAIL" if reachability == "UNREACHABLE" else "PASS_WITH_WARNING" if engine in {"postgres", "postgresql", "mysql", "mariadb", "mongodb", "redis"} else "NOT_DETECTED"
    native = _probe_result("SCAN-019", "Database Native Readiness", utcnow(), time.monotonic(), 0,
                           json.dumps(native_evidence, sort_keys=True), reachability_error, False, False, native_status)
    native.update({"evidence": native_evidence, "summary": "Database-native metadata assessed without SSH.",
                   "recommendedActions": ["Verify database endpoint routing, firewall and service availability."] if reachability == "UNREACHABLE" else ["Supply a least-privilege database credential to validate version and TLS."] if native_status != "PASS" else []})
    if native_status == "FAIL": native.update(_error_fields("DATABASE_ENDPOINT_UNREACHABLE", "DATABASE"))
    native["remediation"] = (native.get("recommendedActions") or [""])[0]
    snapshot = _cloud_snapshot_probe(component)
    return [ssh, native, snapshot]


def create_r6_scan_blueprint(base_dir: Path, probe_runner: Callable[..., subprocess.CompletedProcess] = subprocess.run) -> Blueprint:
    bp = Blueprint("r6_scan_appraisal", __name__)
    root = Path(os.environ.get("R6_SCAN_STATE_DIR", str(Path.home() / ".config" / "opencenter" / "reports" / "scans")))
    cancelled = set()
    state_lock = threading.RLock()
    request_runs: Dict[str, str] = {}
    active_runs = set()

    def load(run_id: str) -> Dict[str, Any]:
        path = root / _slug(run_id) / "summary.json"
        if not path.is_file(): raise FileNotFoundError(run_id)
        return json.loads(path.read_text(encoding="utf-8"))

    def save(run: Dict[str, Any]) -> None:
        with state_lock:
            run["persistedAt"] = utcnow()  # when evidence artifacts were actually closed to disk,
            # distinct from executionCompletedAt (probes finished) and appraisalCompletedAt (verdict computed)
            folder = root / run["runId"]
            (folder / "component-appraisals").mkdir(parents=True, exist_ok=True)
            (folder / "probes").mkdir(exist_ok=True)
            (folder / "raw").mkdir(exist_ok=True)
            persisted = dict(run)
            persisted.pop("ssh", None)
            summary_path = folder / "summary.json"
            summary_tmp = folder / "summary.json.tmp"
            (folder / "final-appraisal.json").write_text(json.dumps(run.get("appraisal", {}), indent=2), encoding="utf-8")
            for comp in run.get("components", []):
                (folder / "component-appraisals" / (comp["componentId"] + ".json")).write_text(json.dumps(comp, indent=2), encoding="utf-8")
                vm = _slug(comp.get("sourceVmId") or comp["componentId"])
                vm_dir = folder / "probes" / vm
                vm_dir.mkdir(parents=True, exist_ok=True)
                raw = []
                for probe in comp.get("probes", []):
                    (vm_dir / (probe["probeId"] + ".json")).write_text(json.dumps(probe, indent=2), encoding="utf-8")
                    raw.append("== %s %s ==\n%s\n%s" % (probe["probeId"], probe["status"], probe.get("stdout", ""), probe.get("stderr", "")))
                (folder / "raw" / (vm + ".log")).write_text("\n".join(raw), encoding="utf-8")
            checksums = {str(p.relative_to(folder)): hashlib.sha256(p.read_bytes()).hexdigest() for p in folder.rglob("*.json") if p.name != "evidence-checksums.json"}
            (folder / "evidence-checksums.json").write_text(json.dumps(checksums, indent=2), encoding="utf-8")
            report = ["# Business System Scan Appraisal", "", "- Run: `%s`" % run["runId"], "- Status: **%s**" % run.get("status", "PENDING")]
            if run.get("appraisal"):
                report += ["- Final verdict: **%s**" % run["appraisal"].get("finalVerdict"), "- Evidence score: **%s%%**" % run["appraisal"].get("overallEvidenceScore"), "", "## Components", ""]
                for comp in run.get("components", []):
                    report += ["### %s" % comp["componentName"], "", "- Verdict: **%s**" % comp["componentVerdict"], "- Readiness: %s%%" % comp["containerReadinessScore"], "- Evidence: %s%%" % comp["evidenceCompletenessScore"], "- Capture: `%s`" % comp["captureRecommendation"], "- Recommendation: `%s`" % comp["containerizationRecommendation"], ""]
            (folder / "scan-report.md").write_text("\n".join(report) + "\n", encoding="utf-8")
            # Publish COMPLETE/FAILED state only after every evidence artifact
            # is closed, so an immediate export cannot archive partial files.
            summary_tmp.write_text(json.dumps(persisted, indent=2), encoding="utf-8")
            summary_tmp.replace(summary_path)
            (root / "latest.json").parent.mkdir(parents=True, exist_ok=True)
            (root / "latest.json").write_text(json.dumps({"runId": run["runId"]}), encoding="utf-8")

    def save_live(run: Dict[str, Any]) -> None:
        """Persist pollable progress atomically without rebuilding evidence artifacts."""
        with state_lock:
            folder = root / run["runId"]
            folder.mkdir(parents=True, exist_ok=True)
            persisted = dict(run)
            persisted.pop("ssh", None)
            path = folder / "summary.json"
            tmp = folder / "summary.json.tmp"
            tmp.write_text(json.dumps(persisted, indent=2), encoding="utf-8")
            tmp.replace(path)

    def execute_component(run: Dict[str, Any], component: Dict[str, Any], only: Optional[set] = None) -> Dict[str, Any]:
        # OSPC source fields are lineage only; executable operations use FLEX target fields.
        target = {"host": component.get("targetHost") or component.get("sshHost") or component.get("targetIp") or component.get("target") or component.get("tgt") or (component.get("sourceHost") if component.get("scanStatus") == "COMPLETE" else None), "port": component.get("sshPort") or 22, "user": component.get("sshUser") or run["ssh"]["user"], "keyPath": component.get("sshKeyPath") or run["ssh"]["keyPath"], "knownHostsFile": run["ssh"].get("knownHostsFile"), "expectedFingerprint": component.get("expectedFingerprint"), "healthPath": component.get("healthPath") or component.get("health_path"), "healthPort": component.get("healthPort") or component.get("applicationPort")}
        access_mode = _database_access_mode(component)
        component["databaseAccessMode"] = access_mode
        if access_mode in {"MANAGED_DATABASE", "KUBERNETES_SERVICE", "PRIVATE_ENDPOINT", "UNKNOWN"}:
            results = _managed_database_probes(component)
            component["probeResults"] = results
            for index, result in enumerate(results, 1):
                _record_live_probe(run, component, result, index, len(results), save_live)
            return appraisal(component, results, run["runId"])
        old = {p["probeId"]: p for p in component.get("probeResults", [])}
        results = []
        connectivity_ok = True
        prerequisite = None
        source_vm_id = component.get("sourceVmId") or component.get("vmId") or component.get("source_vm_id")
        has_endpoint = bool(target.get("host")) and not PLACEHOLDER_HOST.match(str(target.get("host") or ""))
        if not source_vm_id and not has_endpoint:
            # No OpenStack UUID and no host/IP either: there is genuinely nothing to scan.
            result = _probe_result("SCAN-001", "Component VM Mapping", utcnow(), time.monotonic(), 2, "", "Component has no OpenStack server UUID and no resolvable host/IP.", False, False, "BLOCKED")
            result.update(_error_fields("COMPONENT_VM_MAPPING_MISSING", "MAPPING"))
            result["rootCauseId"] = "%s:COMPONENT_VM_MAPPING_MISSING" % _slug(component.get("id") or component.get("name"))
            result["remediation"] = result["recommendedActions"][0]
            results.append(result); prerequisite = result; connectivity_ok = False
        elif not source_vm_id:
            # Has a host/IP but no OpenStack UUID: guest discovery over SSH can still proceed.
            # Only cloud/snapshot-based checks (SCAN-020) are affected; see _cloud_snapshot_probe.
            component["vmUuidUnmapped"] = True
        for probe_id in PROBES:
            if probe_id == "SCAN-001" and prerequisite:
                continue
            if only is not None and probe_id not in only and probe_id in old:
                results.append(old[probe_id]); continue
            if probe_id == "SCAN-020":
                result = _cloud_snapshot_probe(component)
                results.append(result)
                _record_live_probe(run, component, result, len(results), len(PROBES), save_live)
                continue
            if probe_id != "SCAN-001" and not connectivity_ok:
                result = _skipped_probe(probe_id, prerequisite or results[0])
                results.append(result)
                _record_live_probe(run, component, result, len(results), len(PROBES), save_live)
                continue
            _record_live_probe_start(run, component, probe_id, len(results), len(PROBES), save_live)
            result = run_probe(target, probe_id, probe_runner)
            result.update({"targetId": component.get("scanTargetId"), "componentId": component.get("id") or component.get("name"), "sourceVmId": source_vm_id})
            results.append(result)
            _record_live_probe(run, component, result, len(results), len(PROBES), save_live)
            if probe_id == "SCAN-001":
                connectivity_ok = result["status"] in {"PASS", "PASS_WITH_WARNING", "PARTIAL", "WARNING"}
                if not connectivity_ok:
                    result["rootCauseId"] = "%s:%s" % (_slug(component.get("id") or component.get("name")), result.get("errorCode") or "SSH_FAILED")
                    prerequisite = result
        component["probeResults"] = results
        return appraisal(component, results, run["runId"])

    @bp.post("/api/r6/scans/business-system/run")
    def start_scan():
        body = request.get_json(silent=True) or {}
        request_id = str(body.get("requestId") or "").strip()[:128]
        if request_id:
            with state_lock:
                existing_id = request_runs.get(request_id)
            if existing_id:
                try:
                    existing = load(existing_id)
                    return jsonify({"ok": True, "runId": existing_id, "status": existing.get("status", "RUNNING"), "deduplicated": True, "progress": existing.get("progress", {})}), 202
                except FileNotFoundError:
                    with state_lock:
                        request_runs.pop(request_id, None)
        system = body.get("businessSystem") or {}
        components = system.get("components") or []
        ssh = body.get("ssh") or {}
        if not components:
            return jsonify({"ok": False, "error": "businessSystem.components are required"}), 400
        components = [normalize_component_mapping(item, ssh.get("user")) for item in components]
        ssh_required = any(_database_access_mode(item) not in {"MANAGED_DATABASE", "KUBERNETES_SERVICE", "PRIVATE_ENDPOINT", "UNKNOWN"} for item in components)
        if ssh_required and (not ssh.get("user") or not ssh.get("keyPath")):
            return jsonify({"ok": False, "error": "ssh user/keyPath are required for VM-hosted components"}), 400
        run_id = "scan-%s-%s" % (datetime.now().strftime("%Y%m%d%H%M%S"), uuid4().hex[:6])
        run = {"runId": run_id, "schemaVersion": SCHEMA_VERSION, "scannerVersion": SCANNER_VERSION, "actor": body.get("actor") or "dashboard-user", "status": "RUNNING", "startedAt": utcnow(), "evidenceExpiresAt": (datetime.now(timezone.utc) + timedelta(days=30)).isoformat(), "businessSystem": {"id": system.get("id"), "name": system.get("name"), "totalComponentCount": int(system.get("totalComponentCount") or len(components)), "scanScope": system.get("scanScope") or "ALL_COMPONENTS"}, "ssh": {"user": ssh.get("user") or "not-applicable", "keyPath": ssh.get("keyPath") or "not-applicable", "knownHostsFile": ssh.get("knownHostsFile") or str(default_managed_known_hosts_file())}, "components": [], "liveLog": [{"timestamp": utcnow(), "level": "INFO", "message": "Structured component scan started", "status": "RUNNING"}]}
        with state_lock:
            active_runs.add(run_id)
        save(run)
        if request_id:
            with state_lock:
                request_runs[request_id] = run_id
        def worker():
            try:
                vm_evidence = {}
                for component in components:
                    if run_id in cancelled: break
                    run["currentComponent"] = component.get("name")
                    run["progress"] = {"completedComponents": len(run["components"]), "totalComponents": len(components)}
                    run["liveLog"].append({"timestamp": utcnow(), "level": "INFO", "component": component.get("name"), "message": "Component scan started", "status": "RUNNING"})
                    save(run)
                    target_key = component.get("sourceVmId") or component.get("scanTargetId") or "%s:%s" % (component.get("targetHost") or component.get("sshHost") or component.get("targetIp") or component.get("target") or component.get("tgt"), component.get("sshPort") or 22)
                    if target_key in vm_evidence:
                        assessed = appraisal(dict(component), vm_evidence[target_key], run_id)
                        run["liveLog"].append({"timestamp": utcnow(), "level": "INFO", "component": component.get("name"), "message": "Reused probe evidence from the same source VM", "status": assessed.get("componentVerdict")})
                    else:
                        assessed = execute_component(run, dict(component))
                        vm_evidence[target_key] = assessed["probes"]
                    run["components"].append(assessed)
                    run["liveLog"].append({"timestamp": utcnow(), "level": "ERROR" if assessed.get("componentVerdict") in {"BLOCKED", "SCAN_FAILED"} else "INFO", "component": assessed.get("componentName"), "message": "Component appraisal complete", "status": assessed.get("componentVerdict"), "remediation": "; ".join(assessed.get("recommendedActions", []))})
                # "status: COMPLETE" means probe execution finished, not that the system is
                # migration-ready -- that is appraisal.finalVerdict. executionState makes the
                # distinction explicit without changing the `status` value existing UI polls on.
                run["status"] = "CANCELLED" if run_id in cancelled else "COMPLETE"
                run["executionState"] = "CANCELLED" if run_id in cancelled else "EXECUTION_COMPLETE"
                run["currentComponent"] = None  # scan finished; no component is "current" anymore
                execution_completed_at = utcnow()
                run["executionCompletedAt"] = execution_completed_at
                run["completedAt"] = execution_completed_at
                run["progress"] = {"completedComponents": len(run["components"]), "totalComponents": len(components)}
                run["appraisal"] = final_appraisal(run_id, system, run["components"])
                run["appraisalCompletedAt"] = utcnow()
                run["liveLog"].append({"timestamp": utcnow(), "level": "INFO", "message": "Business System scan complete", "status": run["appraisal"].get("finalVerdict")})
            except Exception as exc:
                run["status"] = "SCAN_FAILED"
                run["executionState"] = "SCAN_FAILED"
                run["currentComponent"] = None
                run["error"] = redact(str(exc))
                run["completedAt"] = utcnow()
                run["executionCompletedAt"] = run["completedAt"]
            finally:
                run.pop("ssh", None)  # never persist credentials/key configuration in final evidence
                save(run)
                cancelled.discard(run_id)
                with state_lock:
                    active_runs.discard(run_id)
        threading.Thread(target=worker, name="r6-scan-" + run_id, daemon=True).start()
        return jsonify({"ok": True, "runId": run_id, "status": "RUNNING", "progress": {"completedComponents": 0, "totalComponents": len(components)}}), 202

    @bp.get("/api/r6/scans/runs/<run_id>")
    def get_run(run_id):
        try:
            run = load(run_id)
            with state_lock:
                is_active = run_id in active_runs
            if run.get("status") == "RUNNING" and not is_active:
                interrupted_at = utcnow()
                run.update({
                    "status": "INTERRUPTED",
                    "executionState": "INTERRUPTED",
                    "currentComponent": None,
                    "completedAt": interrupted_at,
                    "executionCompletedAt": interrupted_at,
                    "error": "The scan worker stopped during a service restart. Retry the scan to continue.",
                })
                run.setdefault("liveLog", []).append({
                    "timestamp": interrupted_at,
                    "level": "ERROR",
                    "message": "Scan interrupted by service restart; retry is required",
                    "status": "INTERRUPTED",
                })
                save_live(run)
            response = jsonify({"ok": True, **run})
            response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
            response.headers["Pragma"] = "no-cache"
            return response
        except FileNotFoundError: return jsonify({"ok": False, "error": "scan run not found"}), 404

    @bp.get("/api/r6/scans/runs/<run_id>/components")
    def get_components(run_id):
        try:
            run = load(run_id); return jsonify({"ok": True, "runId": run_id, "components": run.get("components", [])})
        except FileNotFoundError: return jsonify({"ok": False, "error": "scan run not found"}), 404

    @bp.get("/api/r6/scans/runs/<run_id>/components/<component_id>")
    def get_component(run_id, component_id):
        try: run = load(run_id)
        except FileNotFoundError: return jsonify({"ok": False, "error": "scan run not found"}), 404
        comp = next((c for c in run.get("components", []) if c["componentId"] == component_id), None)
        return jsonify({"ok": bool(comp), "component": comp}) if comp else (jsonify({"ok": False, "error": "component not found"}), 404)

    @bp.get("/api/r6/scans/runs/<run_id>/appraisal")
    def get_appraisal(run_id):
        try: return jsonify({"ok": True, "appraisal": load(run_id).get("appraisal")})
        except FileNotFoundError: return jsonify({"ok": False, "error": "scan run not found"}), 404

    @bp.get("/api/r6/scans/runs/<run_id>/stage-gate/<stage>")
    def get_stage_gate(run_id, stage):
        try: run = load(run_id)
        except FileNotFoundError: return jsonify({"ok": False, "error": "scan run not found"}), 404
        stage_key = stage.upper().replace("-", "_")
        if stage_key not in MIGRATION_STAGES:
            return jsonify({"ok": False, "error": "unknown stage", "validStages": list(MIGRATION_STAGES)}), 400
        result = evaluate_stage_gate(run.get("components", []), stage_key)
        return jsonify({"ok": True, "runId": run_id, **result})

    @bp.get("/api/r6/scans/runs/<run_id>/appraisals.csv")
    def export_all_appraisals_csv(run_id):
        try: run = load(run_id)
        except FileNotFoundError: return jsonify({"ok": False, "error": "scan run not found"}), 404
        filename = _slug(run_id) + "-all-appraisal-results.csv"
        return Response(appraisal_csv(run, run.get("components", [])), mimetype="text/csv",
                        headers={"Content-Disposition": 'attachment; filename="%s"' % filename})

    @bp.get("/api/r6/scans/runs/<run_id>/failed-checks.csv")
    def export_failed_checks_csv(run_id):
        try: run = load(run_id)
        except FileNotFoundError: return jsonify({"ok": False, "error": "scan run not found"}), 404
        filename = _slug(run_id) + "-failed-checks.csv"
        root_only = request.args.get("scope", "root-causes") != "all"
        return Response(failed_checks_csv(run, root_causes_only=root_only), mimetype="text/csv",
                        headers={"Content-Disposition": 'attachment; filename="%s"' % filename})

    @bp.get("/api/r6/scans/runs/<run_id>/components/<component_id>/appraisal.csv")
    def export_component_appraisal_csv(run_id, component_id):
        try: run = load(run_id)
        except FileNotFoundError: return jsonify({"ok": False, "error": "scan run not found"}), 404
        component = next((item for item in run.get("components", []) if item.get("componentId") == component_id), None)
        if not component: return jsonify({"ok": False, "error": "component not found"}), 404
        filename = "%s-%s-appraisal-result.csv" % (_slug(run_id), _slug(component_id))
        return Response(appraisal_csv(run, [component]), mimetype="text/csv",
                        headers={"Content-Disposition": 'attachment; filename="%s"' % filename})

    @bp.post("/api/r6/scans/runs/<run_id>/components/<component_id>/retry")
    def retry_component(run_id, component_id):
        try: run = load(run_id)
        except FileNotFoundError: return jsonify({"ok": False, "error": "scan run not found"}), 404
        comp = next((c for c in run.get("components", []) if c["componentId"] == component_id), None)
        if not comp: return jsonify({"ok": False, "error": "component not found"}), 404
        only = {p["probeId"] for p in comp.get("probes", []) if p["status"] in RETRYABLE}
        if not only: return jsonify({"ok": True, "component": comp, "retried": []})
        body = request.get_json(silent=True) or {}
        run["ssh"] = body.get("ssh") or {}
        needs_ssh = _database_access_mode(comp) not in {"MANAGED_DATABASE", "KUBERNETES_SERVICE", "PRIVATE_ENDPOINT", "UNKNOWN"}
        if needs_ssh and (not run["ssh"].get("user") or not run["ssh"].get("keyPath")):
            run.pop("ssh", None)
            return jsonify({"ok": False, "error": "ssh user/keyPath are required for retry"}), 400
        run["ssh"].setdefault("user", "not-applicable"); run["ssh"].setdefault("keyPath", "not-applicable")
        updated = execute_component(run, {**comp, "probeResults": comp.get("probes", [])}, only)
        updated["attemptHistory"] = (comp.get("attemptHistory") or []) + [{"completedAt": utcnow(), "probes": comp.get("probes", [])}]
        run["components"] = [updated if c["componentId"] == component_id else c for c in run["components"]]
        run["appraisal"] = final_appraisal(run_id, run.get("businessSystem", {}), run["components"])
        run.pop("ssh", None); save(run)
        return jsonify({"ok": True, "component": updated, "retried": sorted(only)})

    def retry_matching(run_id: str, predicate: Callable[[Dict[str, Any]], bool]):
        try: run = load(run_id)
        except FileNotFoundError: return jsonify({"ok": False, "error": "scan run not found"}), 404
        body = request.get_json(silent=True) or {}; run["ssh"] = body.get("ssh") or {}
        selected = [comp for comp in run.get("components", []) if predicate(comp)]
        needs_ssh = any(_database_access_mode(comp) not in {"MANAGED_DATABASE", "KUBERNETES_SERVICE", "PRIVATE_ENDPOINT", "UNKNOWN"} for comp in selected)
        if needs_ssh and (not run["ssh"].get("user") or not run["ssh"].get("keyPath")):
            run.pop("ssh", None); return jsonify({"ok": False, "error": "ssh user/keyPath are required for retry"}), 400
        run["ssh"].setdefault("user", "not-applicable"); run["ssh"].setdefault("keyPath", "not-applicable")
        updated_ids = []; new_components = []
        for comp in run.get("components", []):
            if not predicate(comp): new_components.append(comp); continue
            retry_ids = {p["probeId"] for p in comp.get("probes", []) if p.get("status") in RETRYABLE}
            if any(p.get("probeId") == "SCAN-001" and p.get("status") in {"FAIL", "BLOCKED"} for p in comp.get("probes", [])):
                retry_ids = set(PROBES)
            updated = execute_component(run, {**comp, "probeResults": comp.get("probes", [])}, retry_ids)
            updated["attemptHistory"] = (comp.get("attemptHistory") or []) + [{"completedAt": utcnow(), "probes": comp.get("probes", [])}]
            new_components.append(updated); updated_ids.append(comp.get("componentId"))
        run["components"] = new_components; run["appraisal"] = final_appraisal(run_id, run.get("businessSystem", {}), new_components)
        run.pop("ssh", None); save(run)
        return jsonify({"ok": True, "retriedComponents": updated_ids, "appraisal": run["appraisal"]})

    @bp.post("/api/r6/scans/runs/<run_id>/vms/<source_vm_id>/retry")
    def retry_vm(run_id, source_vm_id):
        return retry_matching(run_id, lambda comp: str(comp.get("sourceVmId")) == source_vm_id)

    @bp.post("/api/r6/scans/runs/<run_id>/retry-failed")
    def retry_all_failed(run_id):
        return retry_matching(run_id, lambda comp: any(p.get("status") in RETRYABLE for p in comp.get("probes", [])))

    def _known_hosts_path_from_body(body: Dict[str, Any]) -> Path:
        return Path(str(body.get("knownHostsFile"))).expanduser() if body.get("knownHostsFile") else default_managed_known_hosts_file()

    @bp.get("/api/r6/scans/known-hosts/status")
    def known_host_status():
        host = str(request.args.get("host") or ""); port = int(request.args.get("port") or 22)
        if not host:
            return jsonify({"ok": False, "error": "host is required"}), 400
        known_hosts_arg = request.args.get("knownHostsFile")
        known_hosts = Path(known_hosts_arg).expanduser() if known_hosts_arg else default_managed_known_hosts_file()
        return jsonify(get_trust_status(host, port, known_hosts, probe_runner))

    @bp.post("/api/r6/scans/known-hosts/approve")
    def approve_known_host():
        # First-time trust (status must be UNKNOWN client-side); scoped to exactly this host+port.
        body = request.get_json(silent=True) or {}
        host = str(body.get("host") or ""); port = int(body.get("port") or 22)
        expected = str(body.get("fingerprint") or body.get("expectedFingerprint") or "")
        result, code = approve_host_key(host, port, expected, _known_hosts_path_from_body(body), probe_runner,
                                         actor=str(body.get("actor") or "dashboard-user"), action="APPROVE", vm_id=body.get("vmId"))
        return jsonify(result), code

    @bp.post("/api/r6/scans/known-hosts/verify-and-replace")
    def verify_and_replace_host_key():
        # Destructive replacement of an already-trusted, now-CHANGED fingerprint. Requires
        # explicit operator approval in addition to the live re-scan match that approve_host_key
        # already performs -- a changed key is never silently overwritten.
        body = request.get_json(silent=True) or {}
        if body.get("approved") is not True:
            return jsonify({"ok": False, "error": "explicit operator approval is required"}), 409
        host = str(body.get("host") or ""); port = int(body.get("port") or 22)
        expected = str(body.get("expectedFingerprint") or body.get("fingerprint") or "")
        result, code = approve_host_key(host, port, expected, _known_hosts_path_from_body(body), probe_runner,
                                         actor=str(body.get("actor") or "dashboard-user"), action="REPLACE", vm_id=body.get("vmId"))
        if result.get("ok"):
            result["oldKeyRemoval"] = "replaced"
        return jsonify(result), code

    @bp.post("/api/r6/scans/known-hosts/connection-test")
    def known_host_connection_test():
        # Reuses the same probe path the live scan uses (SSH -o StrictHostKeyChecking=yes
        # against the managed known_hosts) so "automatically retry the connection" after an
        # approval is a real re-verification, not a client-side status re-read.
        body = request.get_json(silent=True) or {}
        host = str(body.get("host") or "")
        if not host:
            return jsonify({"ok": False, "error": "host is required"}), 400
        target = {"host": host, "port": int(body.get("port") or 22), "user": str(body.get("user") or ""),
                   "keyPath": body.get("keyPath") or "~/.ssh/id_rsa", "knownHostsFile": str(_known_hosts_path_from_body(body)),
                   "expectedFingerprint": body.get("expectedFingerprint") or ""}
        result = run_probe(target, "SCAN-001", probe_runner)
        return jsonify({"ok": True, "status": result.get("status"), "errorCode": result.get("errorCode"),
                        "summary": result.get("summary"), "connectionResult": "PASS" if result.get("status") in
                        {"PASS", "PASS_WITH_WARNING"} else "FAIL"})

    @bp.post("/api/r6/scans/runs/<run_id>/cancel")
    def cancel(run_id):
        try: run = load(run_id)
        except FileNotFoundError: return jsonify({"ok": False, "error": "scan run not found"}), 404
        cancelled.add(run_id)
        run["cancelRequested"] = True; save(run)
        return jsonify({"ok": True, "runId": run_id, "status": "CANCELLATION_REQUESTED"})

    @bp.get("/api/r6/scans/runs/<run_id>/export")
    def export(run_id):
        try: load(run_id)
        except FileNotFoundError: return jsonify({"ok": False, "error": "scan run not found"}), 404
        folder = root / _slug(run_id)
        tmp = tempfile.NamedTemporaryFile(suffix=".tar.gz", delete=False); tmp.close()
        with tarfile.open(tmp.name, "w:gz") as archive: archive.add(folder, arcname=folder.name)
        return send_file(tmp.name, as_attachment=True, download_name=run_id + "-evidence.tar.gz")

    return bp
