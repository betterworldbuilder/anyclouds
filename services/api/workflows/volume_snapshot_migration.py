"""
volume_snapshot_migration.py — OSPC Cinder Volume Snapshot → FLEX Cinder Volume
Direct-stream migration: no Glance, no image file, no qcow2 conversion.

Pipeline:
  OSPC snapshot
    → temp OSPC Cinder volume
    → attach to OSPC helper VM
    → create blank FLEX Cinder volume
    → attach to FLEX helper VM
    → dd | gzip | ssh | gunzip | dd   (streamed across cloud boundary)
    → detach from both helpers
    → attach final FLEX volume to target FLEX VM
"""
from __future__ import annotations

import json
import logging
import os
import shlex
import subprocess
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Generator, List, Optional

log = logging.getLogger(__name__)

# ── Models ────────────────────────────────────────────────────────────────────

@dataclass
class VolumeSnapshotMigrationConfig:
    ospc_openrc:              str
    flex_openrc:              str
    ospc_snapshot:            str           # ID or name
    ospc_helper_vm:           str           # ID or name of OSPC VM with /dev/vdb free
    flex_helper_vm:           str           # ID or name of FLEX VM with /dev/vdb free
    flex_helper_ip:           str           # SSH-reachable IP of FLEX helper
    target_volume_name:       str
    target_size_gb:           int
    ssh_key_path:             str = "~/.ssh/id_rsa"
    flex_helper_user:         str = "ubuntu"
    ospc_helper_ip:           str = ""     # SSH IP of OSPC helper (for device detect)
    ospc_helper_user:         str = "ubuntu"
    flex_target_vm:           str = ""     # required when attach_to_final_vm=True
    source_device:            str = ""     # auto-detect if empty
    target_device:            str = ""     # auto-detect if empty
    dry_run:                  bool = False
    cleanup_temp_ospc_volume: bool = True
    attach_to_final_vm:       bool = False
    rollback_delete_flex_volume: bool = False
    stream_timeout:           int = 7200   # seconds
    volume_poll_timeout:      int = 1800   # seconds
    post_attach_validate_mount: bool = False
    post_attach_validate_pg: bool = False
    post_attach_db_validator: str = "none"
    post_attach_custom_validate_cmd: str = ""
    post_attach_pg_db_name: str = "openstack_drinks"
    post_attach_pg_table_name: str = "preferred_drinks"
    post_attach_mount_point: Optional[str] = None
    post_attach_device_hint: Optional[str] = None
    post_attach_ssh_user: str = "ubuntu"
    post_attach_ssh_key_path: str = "~/.ssh/id_rsa"
    post_attach_allow_luks_open: bool = True
    post_attach_allow_lvm_activate: bool = True
    post_attach_update_postgresql_conf: bool = True
    post_attach_start_postgresql: bool = True
    post_attach_artifact_dir: str = ""
    post_attach_script_path: str = ""

    def __post_init__(self):
        self.ssh_key_path = os.path.expanduser(self.ssh_key_path)
        self.post_attach_ssh_key_path = os.path.expanduser(self.post_attach_ssh_key_path)


@dataclass
class VolumeSnapshotMigrationStepResult:
    name:       str
    status:     str  # "success" | "failed" | "skipped" | "dry_run"
    message:    str = ""
    started_at: str = ""
    ended_at:   str = ""

    @staticmethod
    def _now() -> str:
        return datetime.now(timezone.utc).isoformat()

    @classmethod
    def start(cls, name: str) -> "VolumeSnapshotMigrationStepResult":
        return cls(name=name, status="running", started_at=cls._now())

    def finish(self, status: str, message: str = "") -> None:
        self.status = status
        self.message = message
        self.ended_at = self._now()


@dataclass
class ValidationResult:
    source_bytes:        int = 0
    target_bytes:        int = 0
    filesystem_detected: str = ""
    mount_validation:    str = "skipped"  # "success" | "skipped" | "failed"
    post_attach_validation_status: str = "skipped"
    post_attach_query_row_count: Optional[int] = None
    post_attach_mount_point: str = ""
    post_attach_data_dir: str = ""
    post_attach_log_path: str = ""
    post_attach_result_path: str = ""


@dataclass
class VolumeSnapshotMigrationResult:
    status:               str           # "success" | "failed"
    source_snapshot_id:   str = ""
    temp_ospc_volume_id:  str = ""
    flex_volume_id:       str = ""
    attached_to_final_vm: bool = False
    steps:                List[VolumeSnapshotMigrationStepResult] = field(default_factory=list)
    commands_summary:     List[str] = field(default_factory=list)
    validation:           ValidationResult = field(default_factory=ValidationResult)
    error:                str = ""

    def as_dict(self) -> dict:
        return {
            "status":               self.status,
            "source_snapshot_id":   self.source_snapshot_id,
            "temp_ospc_volume_id":  self.temp_ospc_volume_id,
            "flex_volume_id":       self.flex_volume_id,
            "attached_to_final_vm": self.attached_to_final_vm,
            "steps":                [
                {
                    "name":       s.name,
                    "status":     s.status,
                    "message":    s.message,
                    "started_at": s.started_at,
                    "ended_at":   s.ended_at,
                }
                for s in self.steps
            ],
            "commands_summary": self.commands_summary,
            "validation": {
                "source_bytes":        self.validation.source_bytes,
                "target_bytes":        self.validation.target_bytes,
                "filesystem_detected": self.validation.filesystem_detected,
                "mount_validation":    self.validation.mount_validation,
                "post_attach_validation_status": self.validation.post_attach_validation_status,
                "post_attach_query_row_count": self.validation.post_attach_query_row_count,
                "post_attach_mount_point": self.validation.post_attach_mount_point,
                "post_attach_data_dir": self.validation.post_attach_data_dir,
                "post_attach_log_path": self.validation.post_attach_log_path,
                "post_attach_result_path": self.validation.post_attach_result_path,
            },
            "error": self.error,
        }


# ── Helpers ───────────────────────────────────────────────────────────────────

_ROOT_DISK_NAMES = {"sda", "vda", "xvda", "nvme0n1"}

def _ts() -> str:
    return datetime.now(timezone.utc).isoformat()


def run_openstack(openrc_path: str, args: List[str], timeout: int = 300) -> subprocess.CompletedProcess:
    """Run an openstack CLI command with credentials isolated to openrc_path."""
    env = os.environ.copy()
    for k in list(env):
        if k.startswith("OS_"):
            del env[k]
    env["OS_CLIENT_CONFIG_FILE"] = "/dev/null"
    cmd = ["bash", "-c", f"source {shlex.quote(openrc_path)} && openstack " + " ".join(shlex.quote(a) for a in args)]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)


def _ssh_run(ip: str, user: str, key: str, remote_cmd: str, timeout: int = 60) -> subprocess.CompletedProcess:
    cmd = [
        "ssh", "-i", key,
        "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
        "-o", "BatchMode=yes", "-o", "ConnectTimeout=20",
        "-o", "LogLevel=ERROR", "-o", "IdentitiesOnly=yes",
        f"{user}@{ip}", remote_cmd,
    ]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def _is_root_device(dev: str) -> bool:
    name = dev.lstrip("/").split("/")[-1]
    return name in _ROOT_DISK_NAMES or name.startswith(("sda", "vda", "xvda", "nvme0n1"))


def _wait_volume_status(openrc: str, vol_id: str, target: str, timeout: int = 1800) -> str:
    """Poll until volume reaches target status. Returns final status."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        r = run_openstack(openrc, ["volume", "show", vol_id, "-f", "json"], timeout=60)
        if r.returncode == 0:
            data = json.loads(r.stdout)
            status = str(data.get("status") or data.get("Status") or "").lower()
            if status == target:
                return status
            if status == "error":
                return "error"
        time.sleep(10)
    return "timeout"


def _detect_new_device_via_ssh(ip: str, user: str, key: str) -> str:
    """Return the name of the newest unmounted non-root block device on the helper VM."""
    r = _ssh_run(ip, user, key, "lsblk -ndo NAME,TYPE,SIZE,MOUNTPOINT 2>/dev/null", timeout=30)
    if r.returncode != 0:
        return ""
    candidates = []
    for line in r.stdout.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        name, kind = parts[0], parts[1]
        mountpoint = parts[3] if len(parts) > 3 else ""
        if kind == "disk" and not mountpoint and not _is_root_device(name):
            candidates.append(name)
    return f"/dev/{candidates[-1]}" if candidates else ""


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def _resolve_server_ip(openrc_path: str, server_id: str) -> str:
    if not server_id:
        return ""
    r = run_openstack(openrc_path, ["server", "show", server_id, "-f", "json"], timeout=60)
    if r.returncode != 0:
        return ""
    try:
        data = json.loads(r.stdout or "{}")
    except Exception:
        return ""
    addresses = data.get("addresses") or data.get("Addresses") or ""
    import re
    blob = json.dumps(addresses) if isinstance(addresses, (dict, list)) else str(addresses)
    ips = re.findall(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", blob)
    return ips[-1] if ips else ""


def _flex_volume_attached_device(openrc_path: str, volume_id: str) -> str:
    if not volume_id:
        return ""
    r = run_openstack(openrc_path, ["volume", "show", volume_id, "-f", "json"], timeout=60)
    if r.returncode != 0:
        return ""
    try:
        data = json.loads(r.stdout or "{}")
    except Exception:
        return ""
    attachments = data.get("attachments") or data.get("Attachments") or []
    if isinstance(attachments, str):
        return ""
    if attachments:
        return str(attachments[0].get("device") or "")
    return ""


def run_post_attach_pg_validation(pairing_result: dict, config: VolumeSnapshotMigrationConfig) -> dict:
    """Stage and run the safe post-attach volume mount validator on the FLEX target VM."""
    flex_volume_id = str(pairing_result.get("flex_volume_id") or "")
    flex_target_vm_id = str(pairing_result.get("flex_target_vm_id") or config.flex_target_vm or config.flex_helper_vm or "")
    target_ip = str(pairing_result.get("flex_target_vm_ip") or "")
    if not target_ip:
        target_ip = _resolve_server_ip(config.flex_openrc, flex_target_vm_id)
    if not target_ip and flex_target_vm_id == config.flex_helper_vm:
        target_ip = config.flex_helper_ip

    artifact_dir = Path(config.post_attach_artifact_dir or os.getcwd())
    artifact_dir.mkdir(parents=True, exist_ok=True)
    log_path = artifact_dir / f"post_attach_validate_{flex_volume_id or 'unknown'}.log"
    json_path = artifact_dir / f"post_attach_validate_{flex_volume_id or 'unknown'}.json"

    result = {
        "post_attach_validation_status": "skipped",
        "flex_volume_id": flex_volume_id,
        "flex_target_vm_id": flex_target_vm_id,
        "post_attach_query_row_count": None,
        "post_attach_mount_point": config.post_attach_mount_point or "",
        "post_attach_data_dir": "",
        "log_path": str(log_path),
        "result_path": str(json_path),
    }

    if not (config.post_attach_validate_mount or config.post_attach_validate_pg):
        json_path.write_text(json.dumps(result, indent=2, sort_keys=True), encoding="utf-8")
        return result

    if not target_ip:
        result["post_attach_validation_status"] = "failed"
        result["reason"] = "target_vm_ip_not_resolved"
        json_path.write_text(json.dumps(result, indent=2, sort_keys=True), encoding="utf-8")
        return result

    script_path = Path(config.post_attach_script_path) if config.post_attach_script_path else _repo_root() / "scripts" / "osflex_post_attach_pg_mount_validate.sh"
    if not script_path.is_file():
        result["post_attach_validation_status"] = "failed"
        result["reason"] = f"script_not_found:{script_path}"
        json_path.write_text(json.dumps(result, indent=2, sort_keys=True), encoding="utf-8")
        return result

    device_hint = str(pairing_result.get("attached_device_hint") or config.post_attach_device_hint or "")
    if not device_hint:
        device_hint = _flex_volume_attached_device(config.flex_openrc, flex_volume_id)

    scp_cmd = [
        "scp", "-i", config.post_attach_ssh_key_path,
        "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
        "-o", "BatchMode=yes", "-o", "ConnectTimeout=30",
        str(script_path), f"{config.post_attach_ssh_user}@{target_ip}:/tmp/osflex_post_attach_pg_mount_validate.sh",
    ]
    with log_path.open("w", encoding="utf-8") as log_fh:
        scp_proc = subprocess.run(scp_cmd, stdout=log_fh, stderr=subprocess.STDOUT, text=True, timeout=120)
        if scp_proc.returncode != 0:
            result["post_attach_validation_status"] = "failed"
            result["reason"] = "script_upload_failed"
            json_path.write_text(json.dumps(result, indent=2, sort_keys=True), encoding="utf-8")
            return result

        env_cmd = (
            "sudo "
            f"DEV_HINT={shlex.quote(device_hint)} "
            f"MOUNT_POINT={shlex.quote(config.post_attach_mount_point or '')} "
            f"DB_NAME={shlex.quote(config.post_attach_pg_db_name)} "
            f"TABLE_NAME={shlex.quote(config.post_attach_pg_table_name)} "
            f"VALIDATE_PG={shlex.quote(str(config.post_attach_validate_pg).lower())} "
            f"DB_VALIDATOR={shlex.quote(config.post_attach_db_validator or 'none')} "
            f"CUSTOM_VALIDATE_CMD={shlex.quote(config.post_attach_custom_validate_cmd or '')} "
            f"ALLOW_LVM={shlex.quote(str(config.post_attach_allow_lvm_activate).lower())} "
            f"ALLOW_LUKS={shlex.quote(str(config.post_attach_allow_luks_open).lower())} "
            f"UPDATE_PG_CONF={shlex.quote(str(config.post_attach_update_postgresql_conf).lower())} "
            f"START_POSTGRES={shlex.quote(str(config.post_attach_start_postgresql).lower())} "
            "bash /tmp/osflex_post_attach_pg_mount_validate.sh"
        )
        ssh_cmd = [
            "ssh", "-i", config.post_attach_ssh_key_path,
            "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=30",
            f"{config.post_attach_ssh_user}@{target_ip}", env_cmd,
        ]
        proc = subprocess.run(ssh_cmd, stdout=log_fh, stderr=subprocess.STDOUT, text=True, timeout=1800)

    log_text = log_path.read_text(encoding="utf-8", errors="replace")
    import re
    count_match = re.search(r"Row count:\s*\n\s*(\d+)\s*$", log_text, re.MULTILINE)
    mount_match = re.search(r"Mount point:\s*(\S+)", log_text)
    data_match = re.search(r"Detected PostgreSQL data directory:\s*(\S+)", log_text)
    result["post_attach_validation_status"] = "success" if proc.returncode == 0 else "failed"
    result["post_attach_query_row_count"] = int(count_match.group(1)) if count_match else None
    result["post_attach_mount_point"] = mount_match.group(1) if mount_match else (config.post_attach_mount_point or "")
    result["post_attach_data_dir"] = data_match.group(1) if data_match else ""
    json_path.write_text(json.dumps(result, indent=2, sort_keys=True), encoding="utf-8")
    return result


# ── Migration stages (generators yielding log strings) ────────────────────────

def _stage_validate_inputs(
    cfg: VolumeSnapshotMigrationConfig,
    result: VolumeSnapshotMigrationResult,
) -> Generator[str, None, bool]:
    step = VolumeSnapshotMigrationStepResult.start("validate_inputs")
    result.steps.append(step)

    errors = []
    if not cfg.ospc_snapshot:
        errors.append("ospc_snapshot is required")
    if not cfg.ospc_helper_vm:
        errors.append("ospc_helper_vm is required")
    if not cfg.flex_helper_vm:
        errors.append("flex_helper_vm is required")
    if not cfg.flex_helper_ip:
        errors.append("flex_helper_ip is required")
    if cfg.attach_to_final_vm and not cfg.flex_target_vm:
        errors.append("flex_target_vm is required when attach_to_final_vm=True")
    if not os.path.isfile(cfg.ssh_key_path):
        errors.append(f"SSH key not found: {cfg.ssh_key_path}")
    else:
        mode = oct(os.stat(cfg.ssh_key_path).st_mode)[-3:]
        if mode not in ("600", "400"):
            errors.append(f"SSH key permissions too open ({mode}); must be 600 or 400")
    if not cfg.ospc_openrc or not os.path.isfile(cfg.ospc_openrc):
        errors.append(f"ospc_openrc not found: {cfg.ospc_openrc}")
    if not cfg.flex_openrc or not os.path.isfile(cfg.flex_openrc):
        errors.append(f"flex_openrc not found: {cfg.flex_openrc}")
    if cfg.target_size_gb < 1:
        errors.append("target_size_gb must be >= 1")

    if cfg.source_device and _is_root_device(cfg.source_device):
        errors.append(f"source_device {cfg.source_device} looks like a root disk — use data volumes only")
    if cfg.target_device and _is_root_device(cfg.target_device):
        errors.append(f"target_device {cfg.target_device} looks like a root disk — use data volumes only")

    if errors:
        msg = "; ".join(errors)
        step.finish("failed", msg)
        result.error = msg
        yield f"[validate_inputs] FAILED: {msg}"
        return False

    step.finish("success", "All inputs valid")
    yield "[validate_inputs] OK"
    return True


def _stage_inspect_snapshot(
    cfg: VolumeSnapshotMigrationConfig,
    result: VolumeSnapshotMigrationResult,
) -> Generator[str, None, dict]:
    step = VolumeSnapshotMigrationStepResult.start("ospc_snapshot")
    result.steps.append(step)
    yield f"[OSPC snapshot] openstack volume snapshot show {cfg.ospc_snapshot}"
    result.commands_summary.append(f"openstack volume snapshot show {cfg.ospc_snapshot} -f json")

    if cfg.dry_run:
        step.finish("dry_run", "dry_run — skipped API call")
        yield "[OSPC snapshot] dry_run: would inspect snapshot"
        return {"id": cfg.ospc_snapshot, "name": cfg.ospc_snapshot, "size": cfg.target_size_gb, "status": "available", "volume_id": ""}

    r = run_openstack(cfg.ospc_openrc, ["volume", "snapshot", "show", cfg.ospc_snapshot, "-f", "json"], timeout=60)
    if r.returncode != 0:
        msg = f"snapshot show failed: {(r.stderr or r.stdout or '').strip()[:400]}"
        step.finish("failed", msg)
        result.error = msg
        yield f"[OSPC snapshot] FAILED: {msg}"
        return {}

    try:
        snap = json.loads(r.stdout)
    except Exception as exc:
        msg = f"JSON parse error: {exc}"
        step.finish("failed", msg)
        result.error = msg
        yield f"[OSPC snapshot] FAILED: {msg}"
        return {}

    status = str(snap.get("status") or "").lower()
    if status != "available":
        msg = f"snapshot status={status}, must be 'available'"
        step.finish("failed", msg)
        result.error = msg
        yield f"[OSPC snapshot] FAILED: {msg}"
        return {}

    snap_size = int(snap.get("size") or 0)
    if snap_size and cfg.target_size_gb < snap_size:
        msg = f"target_size_gb={cfg.target_size_gb} < snapshot size={snap_size} GB"
        step.finish("failed", msg)
        result.error = msg
        yield f"[OSPC snapshot] FAILED: {msg}"
        return {}

    result.source_snapshot_id = str(snap.get("id") or cfg.ospc_snapshot)
    step.finish("success", f"snapshot size={snap_size}GB status=available")
    yield f"[OSPC snapshot] OK  id={result.source_snapshot_id}  size={snap_size}GB"
    return snap


def _stage_create_ospc_temp_volume(
    cfg: VolumeSnapshotMigrationConfig,
    snap: dict,
    result: VolumeSnapshotMigrationResult,
) -> Generator[str, None, str]:
    step = VolumeSnapshotMigrationStepResult.start("temporary_ospc_volume")
    result.steps.append(step)
    snap_id = result.source_snapshot_id or cfg.ospc_snapshot
    tmp_name = f"osflex-volmig-tmp-{snap_id[:8]}-{int(time.time())}"
    cmd_args = ["volume", "create", "--snapshot", snap_id, tmp_name, "-f", "json"]
    result.commands_summary.append(f"openstack {' '.join(cmd_args)}")
    yield f"[temporary OSPC volume] Creating temp volume from snapshot={snap_id}"

    if cfg.dry_run:
        step.finish("dry_run", f"dry_run — would create volume '{tmp_name}' from snapshot")
        yield f"[temporary OSPC volume] dry_run: would create '{tmp_name}'"
        return "dry-run-vol-id"

    r = run_openstack(cfg.ospc_openrc, cmd_args, timeout=120)
    if r.returncode != 0:
        msg = f"volume create failed: {(r.stderr or r.stdout or '').strip()[:400]}"
        step.finish("failed", msg)
        result.error = msg
        yield f"[temporary OSPC volume] FAILED: {msg}"
        return ""

    vol = json.loads(r.stdout)
    vol_id = str(vol.get("id") or "")
    if not vol_id:
        msg = "no volume ID in create response"
        step.finish("failed", msg)
        result.error = msg
        yield f"[temporary OSPC volume] FAILED: {msg}"
        return ""

    result.temp_ospc_volume_id = vol_id
    yield f"[temporary OSPC volume] vol={vol_id} — waiting available (timeout={cfg.volume_poll_timeout}s)"
    final_status = _wait_volume_status(cfg.ospc_openrc, vol_id, "available", cfg.volume_poll_timeout)
    if final_status != "available":
        msg = f"temp volume {vol_id} never became available (final={final_status})"
        step.finish("failed", msg)
        result.error = msg
        yield f"[temporary OSPC volume] FAILED: {msg}"
        return ""

    step.finish("success", f"vol={vol_id} available")
    yield f"[temporary OSPC volume] OK  vol={vol_id}"
    return vol_id


def _stage_attach_ospc_volume(
    cfg: VolumeSnapshotMigrationConfig,
    vol_id: str,
    result: VolumeSnapshotMigrationResult,
) -> Generator[str, None, str]:
    step = VolumeSnapshotMigrationStepResult.start("attach_temp_volume_to_ospc_helper_vm")
    result.steps.append(step)
    result.commands_summary.append(f"openstack server add volume {cfg.ospc_helper_vm} {vol_id}")
    yield f"[attach temp volume to OSPC helper VM] Attaching vol={vol_id} to helper={cfg.ospc_helper_vm}"

    if cfg.dry_run:
        dev = cfg.source_device or "/dev/vdb"
        step.finish("dry_run", f"dry_run — would attach; device would be {dev}")
        yield f"[attach temp volume to OSPC helper VM] dry_run: device={dev}"
        return dev

    r = run_openstack(cfg.ospc_openrc, ["server", "add", "volume", cfg.ospc_helper_vm, vol_id], timeout=120)
    if r.returncode != 0:
        msg = f"server add volume failed: {(r.stderr or r.stdout or '').strip()[:400]}"
        step.finish("failed", msg)
        result.error = msg
        yield f"[attach temp volume to OSPC helper VM] FAILED: {msg}"
        return ""

    final_status = _wait_volume_status(cfg.ospc_openrc, vol_id, "in-use", 300)
    if final_status != "in-use":
        msg = f"vol={vol_id} did not reach in-use (final={final_status})"
        step.finish("failed", msg)
        result.error = msg
        yield f"[attach temp volume to OSPC helper VM] FAILED: {msg}"
        return ""

    time.sleep(5)
    dev = ""
    if cfg.ospc_helper_ip:
        dev = _detect_new_device_via_ssh(cfg.ospc_helper_ip, cfg.ospc_helper_user, cfg.ssh_key_path)
        if dev:
            yield f"[attach temp volume to OSPC helper VM] Detected device via SSH: {dev}"
    if not dev:
        dev = cfg.source_device or "/dev/vdb"
        yield f"[attach temp volume to OSPC helper VM] Using configured/fallback device: {dev}"

    if _is_root_device(dev):
        msg = f"detected device {dev} appears to be root disk — aborting for safety"
        step.finish("failed", msg)
        result.error = msg
        yield f"[attach temp volume to OSPC helper VM] FAILED: {msg}"
        return ""

    step.finish("success", f"vol={vol_id} in-use  device={dev}")
    yield f"[attach temp volume to OSPC helper VM] OK  device={dev}"
    return dev


def _stage_create_flex_volume(
    cfg: VolumeSnapshotMigrationConfig,
    result: VolumeSnapshotMigrationResult,
) -> Generator[str, None, str]:
    step = VolumeSnapshotMigrationStepResult.start("create_blank_flex_cinder_volume")
    result.steps.append(step)
    cmd_args = ["volume", "create", "--size", str(cfg.target_size_gb), cfg.target_volume_name, "-f", "json"]
    result.commands_summary.append(f"openstack {' '.join(cmd_args)}")
    yield f"[create blank FLEX Cinder volume] Creating blank FLEX volume '{cfg.target_volume_name}' size={cfg.target_size_gb}GB"

    if cfg.dry_run:
        step.finish("dry_run", "dry_run — would create FLEX volume")
        yield f"[create blank FLEX Cinder volume] dry_run: would create '{cfg.target_volume_name}' {cfg.target_size_gb}GB"
        return "dry-run-flex-vol-id"

    r = run_openstack(cfg.flex_openrc, cmd_args, timeout=120)
    if r.returncode != 0:
        msg = f"FLEX volume create failed: {(r.stderr or r.stdout or '').strip()[:400]}"
        step.finish("failed", msg)
        result.error = msg
        yield f"[create blank FLEX Cinder volume] FAILED: {msg}"
        return ""

    vol = json.loads(r.stdout)
    vol_id = str(vol.get("id") or "")
    if not vol_id:
        msg = "no FLEX volume ID in create response"
        step.finish("failed", msg)
        result.error = msg
        yield f"[create blank FLEX Cinder volume] FAILED: {msg}"
        return ""

    result.flex_volume_id = vol_id
    yield f"[create blank FLEX Cinder volume] vol={vol_id} — waiting available"
    final_status = _wait_volume_status(cfg.flex_openrc, vol_id, "available", cfg.volume_poll_timeout)
    if final_status != "available":
        msg = f"FLEX volume {vol_id} never became available (final={final_status})"
        step.finish("failed", msg)
        result.error = msg
        yield f"[create blank FLEX Cinder volume] FAILED: {msg}"
        return ""

    step.finish("success", f"vol={vol_id} available")
    yield f"[create blank FLEX Cinder volume] OK  vol={vol_id}"
    return vol_id


def _stage_attach_flex_volume(
    cfg: VolumeSnapshotMigrationConfig,
    flex_vol_id: str,
    result: VolumeSnapshotMigrationResult,
) -> Generator[str, None, str]:
    step = VolumeSnapshotMigrationStepResult.start("attach_flex_volume_to_flex_helper_vm")
    result.steps.append(step)
    result.commands_summary.append(f"openstack server add volume {cfg.flex_helper_vm} {flex_vol_id}")
    yield f"[attach FLEX volume to FLEX helper VM] Attaching vol={flex_vol_id} to FLEX helper={cfg.flex_helper_vm}"

    if cfg.dry_run:
        dev = cfg.target_device or "/dev/vdb"
        step.finish("dry_run", f"dry_run — would attach; device={dev}")
        yield f"[attach FLEX volume to FLEX helper VM] dry_run: device={dev}"
        return dev

    r = run_openstack(cfg.flex_openrc, ["server", "add", "volume", cfg.flex_helper_vm, flex_vol_id], timeout=120)
    if r.returncode != 0:
        msg = f"FLEX server add volume failed: {(r.stderr or r.stdout or '').strip()[:400]}"
        step.finish("failed", msg)
        result.error = msg
        yield f"[attach FLEX volume to FLEX helper VM] FAILED: {msg}"
        return ""

    final_status = _wait_volume_status(cfg.flex_openrc, flex_vol_id, "in-use", 300)
    if final_status != "in-use":
        msg = f"FLEX vol={flex_vol_id} did not reach in-use (final={final_status})"
        step.finish("failed", msg)
        result.error = msg
        yield f"[attach FLEX volume to FLEX helper VM] FAILED: {msg}"
        return ""

    time.sleep(5)
    dev = _detect_new_device_via_ssh(cfg.flex_helper_ip, cfg.flex_helper_user, cfg.ssh_key_path)
    if dev:
        yield f"[attach FLEX volume to FLEX helper VM] Detected target device via SSH: {dev}"
    else:
        dev = cfg.target_device or "/dev/vdb"
        yield f"[attach FLEX volume to FLEX helper VM] Using configured/fallback device: {dev}"

    if _is_root_device(dev):
        msg = f"FLEX target device {dev} appears to be root disk — aborting for safety"
        step.finish("failed", msg)
        result.error = msg
        yield f"[attach FLEX volume to FLEX helper VM] FAILED: {msg}"
        return ""

    # Confirm unmounted
    chk = _ssh_run(cfg.flex_helper_ip, cfg.flex_helper_user, cfg.ssh_key_path,
                   f"grep -qs {shlex.quote(dev)} /proc/mounts && echo MOUNTED || echo UNMOUNTED", timeout=20)
    if "MOUNTED" in (chk.stdout or ""):
        msg = f"FLEX target device {dev} is mounted — cannot overwrite"
        step.finish("failed", msg)
        result.error = msg
        yield f"[attach FLEX volume to FLEX helper VM] FAILED: {msg}"
        return ""

    step.finish("success", f"vol={flex_vol_id} in-use  device={dev}")
    yield f"[attach FLEX volume to FLEX helper VM] OK  device={dev}"
    return dev


def _stage_pre_stream_validation(
    cfg: VolumeSnapshotMigrationConfig,
    src_dev: str, tgt_dev: str,
    result: VolumeSnapshotMigrationResult,
) -> Generator[str, None, bool]:
    step = VolumeSnapshotMigrationStepResult.start("pre_stream_validation")
    result.steps.append(step)
    yield "[pre_stream_validation] Checking source/target device sizes and SSH tunnel"

    if cfg.dry_run:
        step.finish("dry_run", "dry_run — skipped")
        yield "[pre_stream_validation] dry_run: skipped"
        return True

    # Source size
    src_bytes = 0
    if cfg.ospc_helper_ip:
        r = _ssh_run(cfg.ospc_helper_ip, cfg.ospc_helper_user, cfg.ssh_key_path,
                     f"sudo blockdev --getsize64 {shlex.quote(src_dev)} 2>/dev/null", timeout=30)
        src_bytes = int(r.stdout.strip()) if r.returncode == 0 and r.stdout.strip().isdigit() else 0
        yield f"[pre_stream_validation] source device {src_dev} = {src_bytes:,} bytes"
        result.validation.source_bytes = src_bytes

    # Target size
    r2 = _ssh_run(cfg.flex_helper_ip, cfg.flex_helper_user, cfg.ssh_key_path,
                  f"sudo blockdev --getsize64 {shlex.quote(tgt_dev)} 2>/dev/null", timeout=30)
    tgt_bytes = int(r2.stdout.strip()) if r2.returncode == 0 and r2.stdout.strip().isdigit() else 0
    yield f"[pre_stream_validation] target device {tgt_dev} = {tgt_bytes:,} bytes"
    result.validation.target_bytes = tgt_bytes

    if src_bytes and tgt_bytes and tgt_bytes < src_bytes:
        msg = f"target ({tgt_bytes:,}B) < source ({src_bytes:,}B) — increase target_size_gb"
        step.finish("failed", msg)
        result.error = msg
        yield f"[pre_stream_validation] FAILED: {msg}"
        return False

    # SSH connectivity: OSPC helper → FLEX helper
    if cfg.ospc_helper_ip:
        probe_cmd = (
            f"ssh -i {shlex.quote(cfg.ssh_key_path)}"
            f" -o StrictHostKeyChecking=accept-new"
            f" -o ConnectTimeout=15"
            f" -o BatchMode=yes"
            f" {shlex.quote(cfg.flex_helper_user)}@{shlex.quote(cfg.flex_helper_ip)}"
            f" 'echo OSPC2FLEX_SSH_OK'"
        )
        r3 = _ssh_run(cfg.ospc_helper_ip, cfg.ospc_helper_user, cfg.ssh_key_path, probe_cmd, timeout=40)
        if "OSPC2FLEX_SSH_OK" not in (r3.stdout or ""):
            msg = f"SSH from OSPC helper→FLEX helper failed: {(r3.stderr or '').strip()[:200]}"
            step.finish("failed", msg)
            result.error = msg
            yield f"[pre_stream_validation] FAILED: {msg}"
            return False
        yield "[pre_stream_validation] SSH OSPC helper → FLEX helper: OK"

    step.finish("success", f"source={src_bytes:,}B target={tgt_bytes:,}B")
    yield "[pre_stream_validation] OK"
    return True


def _stage_stream_copy(
    cfg: VolumeSnapshotMigrationConfig,
    src_dev: str, tgt_dev: str,
    result: VolumeSnapshotMigrationResult,
) -> Generator[str, None, bool]:
    step = VolumeSnapshotMigrationStepResult.start("stream_block_device_over_ssh")
    result.steps.append(step)

    # Build the remote dd | gzip | ssh | gunzip | dd command
    inner_ssh = (
        f"ssh -i {shlex.quote(cfg.ssh_key_path)}"
        f" -o StrictHostKeyChecking=accept-new"
        f" -o UserKnownHostsFile=/dev/null"
        f" -o BatchMode=yes"
        f" -o ConnectTimeout=30"
        f" {shlex.quote(cfg.flex_helper_user)}@{shlex.quote(cfg.flex_helper_ip)}"
        f" 'gunzip | sudo dd of={shlex.quote(tgt_dev)} bs=64M status=progress conv=fsync'"
    )
    stream_cmd = (
        f"set -o pipefail;"
        f" sudo dd if={shlex.quote(src_dev)} bs=64M status=progress conv=sync,noerror"
        f" | gzip -1"
        f" | {inner_ssh}"
    )
    result.commands_summary.append(f"[on OSPC helper] {stream_cmd}")

    if cfg.dry_run:
        step.finish("dry_run", f"dry_run — would execute: {stream_cmd[:200]}...")
        yield f"[stream block device over SSH using dd + gzip] dry_run: {stream_cmd}"
        return True

    if not cfg.ospc_helper_ip:
        msg = "ospc_helper_ip required for stream_copy"
        step.finish("failed", msg)
        result.error = msg
        yield f"[stream block device over SSH using dd + gzip] FAILED: {msg}"
        return False

    yield f"[stream block device over SSH using dd + gzip] Launching dd|gzip|ssh stream from {src_dev} → {cfg.flex_helper_ip}:{tgt_dev}"
    yield f"[stream block device over SSH using dd + gzip] Timeout={cfg.stream_timeout}s"

    ssh_outer = [
        "ssh", "-i", cfg.ssh_key_path,
        "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
        "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
        "-o", f"ConnectTimeout=30",
        "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=8",
        f"{cfg.ospc_helper_user}@{cfg.ospc_helper_ip}",
        stream_cmd,
    ]

    try:
        proc = subprocess.Popen(
            ssh_outer, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, bufsize=1,
        )
        deadline = time.time() + cfg.stream_timeout
        for line in iter(proc.stdout.readline, ""):
            if not line:
                break
            yield f"[stream block device over SSH using dd + gzip] {line.rstrip()}"
            if time.time() > deadline:
                proc.kill()
                msg = f"stream_copy timed out after {cfg.stream_timeout}s"
                step.finish("failed", msg)
                result.error = msg
                yield f"[stream block device over SSH using dd + gzip] FAILED: {msg}"
                return False
        proc.wait()
        if proc.returncode != 0:
            msg = f"stream_copy exited with rc={proc.returncode}"
            step.finish("failed", msg)
            result.error = msg
            yield f"[stream block device over SSH using dd + gzip] FAILED: {msg}"
            return False
    except Exception as exc:
        msg = f"stream_copy exception: {exc}"
        step.finish("failed", msg)
        result.error = msg
        yield f"[stream block device over SSH using dd + gzip] FAILED: {msg}"
        return False

    step.finish("success", "stream complete")
    yield "[stream block device over SSH using dd + gzip] OK — stream complete"
    return True


def _stage_post_stream_validation(
    cfg: VolumeSnapshotMigrationConfig,
    tgt_dev: str,
    result: VolumeSnapshotMigrationResult,
) -> Generator[str, None, None]:
    step = VolumeSnapshotMigrationStepResult.start("post_stream_validation")
    result.steps.append(step)
    yield "[post_stream_validation] Probing target device filesystem"

    if cfg.dry_run:
        step.finish("dry_run", "dry_run — skipped")
        yield "[post_stream_validation] dry_run: skipped"
        return

    def _run_flex(cmd: str, timeout: int = 30) -> str:
        r = _ssh_run(cfg.flex_helper_ip, cfg.flex_helper_user, cfg.ssh_key_path, cmd, timeout)
        return (r.stdout or "") + (r.stderr or "")

    _run_flex(f"sudo partprobe {shlex.quote(tgt_dev)} 2>/dev/null || true", 20)
    time.sleep(2)

    lsblk_out = _run_flex("lsblk 2>/dev/null", 20)
    yield f"[post_stream_validation] lsblk:\n{lsblk_out}"

    blkid_out = _run_flex(f"sudo blkid {shlex.quote(tgt_dev)} 2>/dev/null || true", 20)
    yield f"[post_stream_validation] blkid: {blkid_out.strip()}"

    file_out = _run_flex(f"sudo file -s {shlex.quote(tgt_dev)} 2>/dev/null", 20)
    yield f"[post_stream_validation] file -s: {file_out.strip()}"
    result.validation.filesystem_detected = file_out.strip()

    # Try to find first partition and mount read-only
    part_r = _run_flex(
        f"lsblk -nrpo NAME {shlex.quote(tgt_dev)} 2>/dev/null | grep -v {shlex.quote(tgt_dev)} | head -1", 20)
    partition = part_r.strip()
    if partition and partition != tgt_dev:
        yield f"[post_stream_validation] Found partition: {partition} — mounting read-only"
        mnt = "/mnt/osflex_volume_validate"
        _run_flex(f"sudo mkdir -p {shlex.quote(mnt)}", 10)
        mnt_r = _run_flex(f"sudo mount -o ro {shlex.quote(partition)} {shlex.quote(mnt)} 2>&1", 30)
        if "error" in mnt_r.lower() or "failed" in mnt_r.lower():
            result.validation.mount_validation = "failed"
            yield f"[post_stream_validation] mount failed: {mnt_r.strip()}"
        else:
            result.validation.mount_validation = "success"
            df_out = _run_flex(f"df -h {shlex.quote(mnt)} 2>/dev/null", 15)
            find_out = _run_flex(f"sudo find {shlex.quote(mnt)} -maxdepth 2 2>/dev/null | head -50", 20)
            yield f"[post_stream_validation] df: {df_out.strip()}"
            yield f"[post_stream_validation] find:\n{find_out}"
            _run_flex(f"sudo umount {shlex.quote(mnt)} 2>/dev/null || true", 20)
    else:
        result.validation.mount_validation = "skipped"
        yield "[post_stream_validation] No partition found — skipping mount check"

    step.finish("success", f"filesystem={result.validation.filesystem_detected[:80]}")
    yield "[post_stream_validation] OK"


def _stage_detach_from_helpers(
    cfg: VolumeSnapshotMigrationConfig,
    ospc_vol_id: str, flex_vol_id: str,
    result: VolumeSnapshotMigrationResult,
) -> Generator[str, None, None]:
    step = VolumeSnapshotMigrationStepResult.start("detach_from_helper")
    result.steps.append(step)
    yield "[detach from helper] Detaching volumes from OSPC and FLEX helpers"

    if cfg.dry_run:
        step.finish("dry_run", "dry_run — skipped")
        yield "[detach from helper] dry_run: skipped"
        return

    errors = []
    if ospc_vol_id and ospc_vol_id != "dry-run-vol-id":
        result.commands_summary.append(f"openstack server remove volume {cfg.ospc_helper_vm} {ospc_vol_id}")
        r = run_openstack(cfg.ospc_openrc, ["server", "remove", "volume", cfg.ospc_helper_vm, ospc_vol_id], timeout=120)
        if r.returncode != 0:
            errors.append(f"OSPC detach failed: {(r.stderr or '').strip()[:200]}")
        else:
            _wait_volume_status(cfg.ospc_openrc, ospc_vol_id, "available", 300)
            yield f"[detach from helper] OSPC vol={ospc_vol_id} detached"

    if flex_vol_id and flex_vol_id != "dry-run-flex-vol-id":
        result.commands_summary.append(f"openstack server remove volume {cfg.flex_helper_vm} {flex_vol_id}")
        r2 = run_openstack(cfg.flex_openrc, ["server", "remove", "volume", cfg.flex_helper_vm, flex_vol_id], timeout=120)
        if r2.returncode != 0:
            errors.append(f"FLEX detach failed: {(r2.stderr or '').strip()[:200]}")
        else:
            _wait_volume_status(cfg.flex_openrc, flex_vol_id, "available", 300)
            yield f"[detach from helper] FLEX vol={flex_vol_id} detached"

    if errors:
        step.finish("failed", "; ".join(errors))
        yield f"[detach from helper] WARN: {'; '.join(errors)}"
    else:
        step.finish("success", "all detached")
        yield "[detach from helper] OK"


def _stage_attach_to_final_vm(
    cfg: VolumeSnapshotMigrationConfig,
    flex_vol_id: str,
    result: VolumeSnapshotMigrationResult,
) -> Generator[str, None, None]:
    step = VolumeSnapshotMigrationStepResult.start("attach_final_flex_volume_to_target_vm")
    result.steps.append(step)

    if not cfg.attach_to_final_vm:
        step.finish("skipped", "attach_to_final_vm=False")
        yield "[attach final FLEX volume to target FLEX VM] skipped (attach_to_final_vm=False)"
        return

    yield f"[attach final FLEX volume to target FLEX VM] Attaching vol={flex_vol_id} to FLEX target VM={cfg.flex_target_vm}"
    result.commands_summary.append(f"openstack server add volume {cfg.flex_target_vm} {flex_vol_id}")

    if cfg.dry_run:
        step.finish("dry_run", "dry_run — skipped")
        yield "[attach final FLEX volume to target FLEX VM] dry_run: skipped"
        return

    if not flex_vol_id or flex_vol_id == "dry-run-flex-vol-id":
        step.finish("skipped", "no flex_vol_id")
        return

    r = run_openstack(cfg.flex_openrc, ["server", "add", "volume", cfg.flex_target_vm, flex_vol_id], timeout=120)
    if r.returncode != 0:
        msg = f"attach to final VM failed: {(r.stderr or r.stdout or '').strip()[:400]}"
        step.finish("failed", msg)
        yield f"[attach final FLEX volume to target FLEX VM] FAILED: {msg}"
        return

    final_status = _wait_volume_status(cfg.flex_openrc, flex_vol_id, "in-use", 300)
    if final_status != "in-use":
        msg = f"volume did not reach in-use on final VM (final={final_status})"
        step.finish("failed", msg)
        yield f"[attach final FLEX volume to target FLEX VM] FAILED: {msg}"
        return

    result.attached_to_final_vm = True
    step.finish("success", f"attached to {cfg.flex_target_vm}")
    yield f"[attach final FLEX volume to target FLEX VM] OK — vol={flex_vol_id} attached to {cfg.flex_target_vm}"


def _stage_post_attach_pg_validate(
    cfg: VolumeSnapshotMigrationConfig,
    flex_vol_id: str,
    result: VolumeSnapshotMigrationResult,
) -> Generator[str, None, None]:
    step = VolumeSnapshotMigrationStepResult.start("VOL_POST_ATTACH_VALIDATE")
    result.steps.append(step)

    if not (cfg.post_attach_validate_mount or cfg.post_attach_validate_pg):
        result.validation.post_attach_validation_status = "skipped"
        step.finish("skipped", "post_attach_validate_mount=False")
        yield "[VOL_POST_ATTACH_VALIDATE] skipped (post_attach_validate_mount=False)"
        return

    if cfg.dry_run:
        if not cfg.attach_to_final_vm:
            result.validation.post_attach_validation_status = "skipped"
            step.finish("skipped", "attach_to_final_vm=False")
            yield "[VOL_POST_ATTACH_VALIDATE] skipped — final attach is not enabled"
            return
        result.validation.post_attach_validation_status = "skipped"
        extra = " and PostgreSQL proof query" if cfg.post_attach_validate_pg else ""
        step.finish("dry_run", f"dry_run — would run volume mount validation{extra}")
        yield f"[VOL_POST_ATTACH_VALIDATE] dry_run: would stage script, mount volume, validate mount{extra}"
        return

    if not result.attached_to_final_vm:
        result.validation.post_attach_validation_status = "skipped"
        step.finish("skipped", "final attach did not succeed")
        yield "[VOL_POST_ATTACH_VALIDATE] skipped — final attach did not succeed"
        return

    extra = " + PostgreSQL query" if cfg.post_attach_validate_pg else ""
    yield f"[VOL_POST_ATTACH_VALIDATE] Running post-attach volume mount validation{extra}"
    payload = {
        "flex_volume_id": flex_vol_id,
        "flex_target_vm_id": cfg.flex_target_vm or cfg.flex_helper_vm,
        "attached_device_hint": cfg.post_attach_device_hint or _flex_volume_attached_device(cfg.flex_openrc, flex_vol_id),
    }
    validation = run_post_attach_pg_validation(payload, cfg)

    result.validation.post_attach_validation_status = str(validation.get("post_attach_validation_status") or "failed")
    result.validation.post_attach_query_row_count = validation.get("post_attach_query_row_count")
    result.validation.post_attach_mount_point = str(validation.get("post_attach_mount_point") or "")
    result.validation.post_attach_data_dir = str(validation.get("post_attach_data_dir") or "")
    result.validation.post_attach_log_path = str(validation.get("log_path") or "")
    result.validation.post_attach_result_path = str(validation.get("result_path") or "")

    status = result.validation.post_attach_validation_status
    msg = f"status={status} rows={result.validation.post_attach_query_row_count} log={result.validation.post_attach_log_path}"
    step.finish("success" if status == "success" else "failed", msg)
    yield f"[VOL_POST_ATTACH_VALIDATE] {msg}"


def _stage_cleanup(
    cfg: VolumeSnapshotMigrationConfig,
    ospc_vol_id: str,
    result: VolumeSnapshotMigrationResult,
) -> Generator[str, None, None]:
    step = VolumeSnapshotMigrationStepResult.start("cleanup")
    result.steps.append(step)

    if not cfg.cleanup_temp_ospc_volume:
        step.finish("skipped", "cleanup_temp_ospc_volume=False")
        yield "[cleanup] skipped (cleanup_temp_ospc_volume=False)"
        return

    if not ospc_vol_id or ospc_vol_id == "dry-run-vol-id":
        step.finish("skipped", "no temp volume to delete")
        return

    yield f"[cleanup] Deleting temp OSPC volume={ospc_vol_id}"
    result.commands_summary.append(f"openstack volume delete {ospc_vol_id}")

    if cfg.dry_run:
        step.finish("dry_run", "dry_run — skipped")
        yield "[cleanup] dry_run: skipped"
        return

    r = run_openstack(cfg.ospc_openrc, ["volume", "delete", ospc_vol_id], timeout=120)
    if r.returncode != 0:
        msg = f"delete temp volume failed: {(r.stderr or '').strip()[:200]}"
        step.finish("failed", msg)
        yield f"[cleanup] WARN: {msg}"
    else:
        step.finish("success", f"temp vol={ospc_vol_id} deleted")
        yield f"[cleanup] OK — temp vol={ospc_vol_id} deleted"


def _rollback(
    cfg: VolumeSnapshotMigrationConfig,
    ospc_vol_id: str,
    flex_vol_id: str,
    result: VolumeSnapshotMigrationResult,
) -> Generator[str, None, None]:
    """Best-effort cleanup on failure. Never deletes source snapshot or FLEX volume unless rollback flag set."""
    yield "[rollback] Starting rollback cleanup"

    if ospc_vol_id and ospc_vol_id != "dry-run-vol-id" and not cfg.dry_run:
        # Attempt detach first
        run_openstack(cfg.ospc_openrc,
                      ["server", "remove", "volume", cfg.ospc_helper_vm, ospc_vol_id],
                      timeout=60)
        time.sleep(10)
        if cfg.cleanup_temp_ospc_volume:
            r = run_openstack(cfg.ospc_openrc, ["volume", "delete", ospc_vol_id], timeout=60)
            yield f"[rollback] temp OSPC vol={ospc_vol_id} delete rc={r.returncode}"

    if flex_vol_id and flex_vol_id != "dry-run-flex-vol-id" and not cfg.dry_run:
        run_openstack(cfg.flex_openrc,
                      ["server", "remove", "volume", cfg.flex_helper_vm, flex_vol_id],
                      timeout=60)
        time.sleep(10)
        if cfg.rollback_delete_flex_volume:
            r2 = run_openstack(cfg.flex_openrc, ["volume", "delete", flex_vol_id], timeout=60)
            yield f"[rollback] FLEX vol={flex_vol_id} delete rc={r2.returncode}"
        else:
            yield f"[rollback] FLEX vol={flex_vol_id} kept for inspection (rollback_delete_flex_volume=False)"

    yield "[rollback] done"


# ── Main entry point ──────────────────────────────────────────────────────────

def migrate_volume_snapshot_to_flex(
    config: VolumeSnapshotMigrationConfig,
) -> VolumeSnapshotMigrationResult:
    """
    Migrate an OSPC Cinder volume snapshot to a FLEX Cinder volume using direct
    block-device streaming (dd | gzip | ssh | gunzip | dd). No Glance involved.

    Returns a VolumeSnapshotMigrationResult with per-step status.
    """
    result = VolumeSnapshotMigrationResult(status="failed")

    ospc_vol_id = ""
    flex_vol_id = ""
    src_dev = config.source_device or "/dev/vdb"
    tgt_dev = config.target_device or "/dev/vdb"
    stream_done = False

    try:
        # 1. validate_inputs
        for msg in _stage_validate_inputs(config, result):
            log.info(msg)
        if result.steps[-1].status == "failed":
            return result

        # 2. inspect snapshot
        snap = {}
        for msg in _stage_inspect_snapshot(config, result):
            log.info(msg)
        if result.steps[-1].status == "failed":
            return result

        # 3. create OSPC temp volume
        for msg in _stage_create_ospc_temp_volume(config, {}, result):
            log.info(msg)
        if result.steps[-1].status == "failed":
            return result
        ospc_vol_id = result.temp_ospc_volume_id or "dry-run-vol-id"

        # 4. attach OSPC temp volume to helper
        for msg in _stage_attach_ospc_volume(config, ospc_vol_id, result):
            log.info(msg)
        if result.steps[-1].status == "failed":
            for rb in _rollback(config, ospc_vol_id, "", result):
                log.info(rb)
            return result
        src_dev = next(
            (s.message.split("device=")[-1] for s in result.steps if s.name == "attach_temp_volume_to_ospc_helper_vm" and "device=" in s.message),
            config.source_device or "/dev/vdb"
        )

        # 5. create FLEX blank volume
        for msg in _stage_create_flex_volume(config, result):
            log.info(msg)
        if result.steps[-1].status == "failed":
            for rb in _rollback(config, ospc_vol_id, "", result):
                log.info(rb)
            return result
        flex_vol_id = result.flex_volume_id or "dry-run-flex-vol-id"

        # 6. attach FLEX volume to helper
        for msg in _stage_attach_flex_volume(config, flex_vol_id, result):
            log.info(msg)
        if result.steps[-1].status == "failed":
            for rb in _rollback(config, ospc_vol_id, flex_vol_id, result):
                log.info(rb)
            return result
        tgt_dev = next(
            (s.message.split("device=")[-1] for s in result.steps if s.name == "attach_flex_volume_to_flex_helper_vm" and "device=" in s.message),
            config.target_device or "/dev/vdb"
        )

        # 7. pre-stream validation
        for msg in _stage_pre_stream_validation(config, src_dev, tgt_dev, result):
            log.info(msg)
        if result.steps[-1].status == "failed":
            for rb in _rollback(config, ospc_vol_id, flex_vol_id, result):
                log.info(rb)
            return result

        # 8. stream copy
        for msg in _stage_stream_copy(config, src_dev, tgt_dev, result):
            log.info(msg)
        if result.steps[-1].status == "failed":
            for rb in _rollback(config, ospc_vol_id, flex_vol_id, result):
                log.info(rb)
            return result
        stream_done = True

        # 9. post-stream validation
        for msg in _stage_post_stream_validation(config, tgt_dev, result):
            log.info(msg)

        # 10. detach from helpers
        for msg in _stage_detach_from_helpers(config, ospc_vol_id, flex_vol_id, result):
            log.info(msg)

        # 11. attach to final FLEX VM
        for msg in _stage_attach_to_final_vm(config, flex_vol_id, result):
            log.info(msg)

        # 11b. optional post-attach PostgreSQL validation
        for msg in _stage_post_attach_pg_validate(config, flex_vol_id, result):
            log.info(msg)

        # 12. cleanup temp OSPC volume
        for msg in _stage_cleanup(config, ospc_vol_id, result):
            log.info(msg)

        result.status = "success"

    except Exception as exc:
        result.status = "failed"
        result.error = str(exc)
        log.exception("migrate_volume_snapshot_to_flex: unhandled exception")
        if not stream_done:
            for rb in _rollback(config, ospc_vol_id, flex_vol_id, result):
                log.info(rb)

    return result


# ── Streaming generator variant (for SSE/Flask) ───────────────────────────────

def migrate_volume_snapshot_to_flex_stream(
    config: VolumeSnapshotMigrationConfig,
    result: VolumeSnapshotMigrationResult,
) -> Generator[str, None, None]:
    """
    Same pipeline as migrate_volume_snapshot_to_flex but yields log lines as
    they are produced, suitable for SSE streaming in Flask.
    Mutates the passed-in result object in place.
    """
    ospc_vol_id = ""
    flex_vol_id = ""
    src_dev = config.source_device or "/dev/vdb"
    tgt_dev = config.target_device or "/dev/vdb"
    stream_done = False

    try:
        yield from _stage_validate_inputs(config, result)
        if result.steps and result.steps[-1].status == "failed":
            result.status = "failed"; return

        yield from _stage_inspect_snapshot(config, result)
        if result.steps and result.steps[-1].status == "failed":
            result.status = "failed"; return

        yield from _stage_create_ospc_temp_volume(config, {}, result)
        if result.steps and result.steps[-1].status == "failed":
            result.status = "failed"; return
        ospc_vol_id = result.temp_ospc_volume_id or "dry-run-vol-id"

        yield from _stage_attach_ospc_volume(config, ospc_vol_id, result)
        if result.steps and result.steps[-1].status == "failed":
            yield from _rollback(config, ospc_vol_id, "", result)
            result.status = "failed"; return
        src_dev = next(
            (s.message.split("device=")[-1] for s in result.steps if s.name == "attach_temp_volume_to_ospc_helper_vm" and "device=" in s.message),
            config.source_device or "/dev/vdb"
        )

        yield from _stage_create_flex_volume(config, result)
        if result.steps and result.steps[-1].status == "failed":
            yield from _rollback(config, ospc_vol_id, "", result)
            result.status = "failed"; return
        flex_vol_id = result.flex_volume_id or "dry-run-flex-vol-id"

        yield from _stage_attach_flex_volume(config, flex_vol_id, result)
        if result.steps and result.steps[-1].status == "failed":
            yield from _rollback(config, ospc_vol_id, flex_vol_id, result)
            result.status = "failed"; return
        tgt_dev = next(
            (s.message.split("device=")[-1] for s in result.steps if s.name == "attach_flex_volume_to_flex_helper_vm" and "device=" in s.message),
            config.target_device or "/dev/vdb"
        )

        yield from _stage_pre_stream_validation(config, src_dev, tgt_dev, result)
        if result.steps and result.steps[-1].status == "failed":
            yield from _rollback(config, ospc_vol_id, flex_vol_id, result)
            result.status = "failed"; return

        yield from _stage_stream_copy(config, src_dev, tgt_dev, result)
        if result.steps and result.steps[-1].status == "failed":
            yield from _rollback(config, ospc_vol_id, flex_vol_id, result)
            result.status = "failed"; return
        stream_done = True

        yield from _stage_post_stream_validation(config, tgt_dev, result)
        yield from _stage_detach_from_helpers(config, ospc_vol_id, flex_vol_id, result)
        yield from _stage_attach_to_final_vm(config, flex_vol_id, result)
        yield from _stage_post_attach_pg_validate(config, flex_vol_id, result)
        yield from _stage_cleanup(config, ospc_vol_id, result)

        result.status = "success"
        yield "[MIGRATION COMPLETE] status=success"
        yield f"[RESULT] flex_volume_id={flex_vol_id}"
        yield f"[RESULT] attached_to_final_vm={result.attached_to_final_vm}"

    except Exception as exc:
        result.status = "failed"
        result.error = str(exc)
        yield f"[FATAL] {exc}"
        if not stream_done:
            yield from _rollback(config, ospc_vol_id, flex_vol_id, result)
