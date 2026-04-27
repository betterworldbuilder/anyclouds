#!/usr/bin/env python3
"""
ospc2flex_image_migrator.py
OSPC → FLEX end-to-end image migration tool
Always runs fresh — no smart-resume skip logic.
"""
import argparse
import json
import os
import shlex
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from ospc2flex_repair_os_hint import infer_offline_os_type


# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

def log(msg: str) -> None:
    print(msg, flush=True)


def shell_quote(s: str) -> str:
    return shlex.quote(str(s))


def run(cmd, *, dry_run: bool = False, capture: bool = True, check: bool = True, log_cmd: bool = True) -> str:
    if isinstance(cmd, str):
        cmd_str = cmd
    else:
        cmd_str = " ".join(str(c) for c in cmd)
    if log_cmd:
        log(f"[RUN] {cmd_str}")
    if dry_run:
        return ""
    result = subprocess.run(
        cmd_str, shell=True, capture_output=capture,
        text=True, errors="replace"
    )
    if capture:
        out = (result.stdout or "").strip()
        if result.returncode != 0 and check:
            err = (result.stderr or "").strip()
            raise RuntimeError(f"Command failed ({result.returncode}): {cmd_str}\nSTDOUT: {out}\nSTDERR: {err}")
        return out
    else:
        if result.returncode != 0 and check:
            print(f"\n[EXECUTION ERROR] Command failed with code {result.returncode}")
            if result.stdout:
                print(f"STDOUT:\n{result.stdout}")
            if result.stderr:
                print(f"STDERR:\n{result.stderr}")
            raise RuntimeError(f"Command failed ({result.returncode})")
        return ""


def openstack_cmd(openrc_path: str, cmd: str) -> str:
    return f"bash -lc {shell_quote(f'source {openrc_path} && {cmd}')}"


def _to_int(value) -> int:
    try:
        return int(str(value).strip())
    except Exception:
        return 0


def resolve_target_flavor_with_fallback(
    *,
    flex_openrc: str,
    requested_flavor: str,
    source_vcpus: int = 0,
    source_ram_mb: int = 0,
    source_disk_gb: int = 0,
    dry_run: bool = False,
) -> str:
    req = (requested_flavor or "").strip()
    if dry_run:
        return req
    if req:
        ok = run(
            openstack_cmd(flex_openrc, f"openstack flavor show {shell_quote(req)} -f value -c id"),
            capture=True, check=False, dry_run=False, log_cmd=False,
        )
        if ok.strip():
            log(f"[INFO] Target flavor exists: {req}")
            return req
        log(f"[WARN] Requested target flavor not found in this region: {req}")

    rows_json = run(
        openstack_cmd(
            flex_openrc,
            "openstack flavor list --long -f json -c ID -c Name -c RAM -c Disk -c VCPUs",
        ),
        capture=True, check=False, dry_run=False, log_cmd=False,
    )
    try:
        rows = json.loads(rows_json or "[]")
    except Exception:
        rows = []
    candidates = []
    for r in rows:
        fid = str(r.get("ID", "")).strip()
        name = str(r.get("Name", "")).strip()
        ram = _to_int(r.get("RAM", 0))
        disk = _to_int(r.get("Disk", 0))
        vcpus = _to_int(r.get("VCPUs", 0))
        if fid and ram > 0 and vcpus > 0:
            candidates.append({"id": fid, "name": name, "ram": ram, "disk": disk, "vcpus": vcpus})
    if not candidates:
        return req

    source_vcpus = _to_int(source_vcpus)
    source_ram_mb = _to_int(source_ram_mb)
    source_disk_gb = _to_int(source_disk_gb)
    # Enforce disk-aware pick: same disk size as source or next bigger.
    # Also avoid zero-disk flavors unless absolutely no alternatives exist.
    non_zero = [c for c in candidates if c["disk"] > 0]
    pool = non_zero or candidates

    if source_disk_gb > 0:
        disk_fit = [c for c in pool if c["disk"] >= source_disk_gb]
        if disk_fit:
            pool = disk_fit
        else:
            log(f"[WARN] No target flavor has disk >= source disk ({source_disk_gb} GiB); using largest available disk candidate")
            pool = sorted(pool, key=lambda c: c["disk"], reverse=True)

    chosen = None
    if source_vcpus > 0 and source_ram_mb > 0:
        shape_fit = [c for c in pool if c["vcpus"] >= source_vcpus and c["ram"] >= source_ram_mb]
        if shape_fit:
            chosen = min(
                shape_fit,
                key=lambda c: (
                    c["disk"] - source_disk_gb if source_disk_gb > 0 else c["disk"],
                    c["vcpus"] - source_vcpus,
                    c["ram"] - source_ram_mb,
                ),
            )
    if chosen is None:
        if source_disk_gb > 0:
            chosen = min(pool, key=lambda c: (abs(c["disk"] - source_disk_gb), c["vcpus"], c["ram"]))
        else:
            chosen = min(pool, key=lambda c: (c["disk"], c["vcpus"], c["ram"]))
    log(
        f"[INFO] Auto-selected target flavor: {chosen['id']} ({chosen['name']}) "
        f"vcpu={chosen['vcpus']} ram={chosen['ram']} disk={chosen['disk']} "
        f"source={source_vcpus or '?'}:{source_ram_mb or '?'}:{source_disk_gb or '?'}"
    )
    return chosen["id"]


def resolve_target_network_with_fallback(
    *,
    flex_openrc: str,
    requested_network: str,
    dry_run: bool = False,
) -> str:
    req = (requested_network or "").strip()
    if dry_run:
        return req
    if req:
        ok = run(
            openstack_cmd(flex_openrc, f"openstack network show {shell_quote(req)} -f value -c id"),
            capture=True, check=False, dry_run=False, log_cmd=False,
        )
        if ok.strip():
            log(f"[INFO] Target network exists: {req}")
            return req
        log(f"[WARN] Requested target network not found in this region: {req}")

    rows_json = run(
        openstack_cmd(
            flex_openrc,
            "openstack network list -f json -c ID -c Name",
        ),
        capture=True, check=False, dry_run=False, log_cmd=False,
    )
    try:
        rows = json.loads(rows_json or "[]")
    except Exception:
        rows = []
    candidates = []
    for r in rows:
        nid = str(r.get("ID", "")).strip()
        name = str(r.get("Name", "")).strip()
        if nid:
            candidates.append({"id": nid, "name": name})
    if not candidates:
        return req

    preferred = None
    for c in candidates:
        lname = c["name"].lower()
        if any(x in lname for x in ("private", "tenant", "internal")):
            preferred = c
            break
    chosen = preferred or candidates[0]
    log(f"[INFO] Auto-selected target network: {chosen['id']} ({chosen['name'] or '?'})")
    return chosen["id"]


def resolve_target_keypair_with_fallback(
    *,
    flex_openrc: str,
    requested_keypair: str,
    dry_run: bool = False,
) -> str:
    req = (requested_keypair or "").strip()
    if dry_run:
        return req
    if req:
        ok = run(
            openstack_cmd(flex_openrc, f"openstack keypair show {shell_quote(req)} -f value -c name"),
            capture=True, check=False, dry_run=False, log_cmd=False,
        )
        if ok.strip():
            log(f"[INFO] Target keypair exists: {req}")
            return req
        log(f"[WARN] Requested target keypair not found in this region: {req}")

    kp_list = run(
        openstack_cmd(flex_openrc, "openstack keypair list -f value -c Name"),
        capture=True, check=False, dry_run=False, log_cmd=False,
    )
    first = ""
    for line in (kp_list or "").splitlines():
        val = line.strip()
        if val:
            first = val
            break
    if first:
        log(f"[INFO] Auto-selected target keypair: {first}")
        return first
    log("[WARN] No keypairs found in target project; booting without --key-name")
    return ""


def ssh_base_cmd(key: str, user: str, host: str, port: int = 22) -> str:
    return (
        f"ssh -i {shell_quote(key)}"
        f" -o BatchMode=yes"
        f" -o StrictHostKeyChecking=accept-new"
        f" -o ConnectTimeout=10"
        f" -o ServerAliveInterval=30"
        f" -o ServerAliveCountMax=10"
        f" -p {port}"
        f" {user}@{host}"
    )


def ssh_password_cmd(password: str, user: str, host: str, port: int = 22) -> str:
    return (
        f"sshpass -p {shell_quote(password)} ssh"
        f" -o PreferredAuthentications=password,keyboard-interactive"
        f" -o PubkeyAuthentication=no"
        f" -o StrictHostKeyChecking=accept-new"
        f" -o ConnectTimeout=10"
        f" -o ServerAliveInterval=30"
        f" -o ServerAliveCountMax=10"
        f" -p {port}"
        f" {user}@{host}"
    )


def scp_base_cmd(key: str, port: int = 22) -> str:
    return (
        f"scp -i {shell_quote(key)}"
        f" -o BatchMode=yes"
        f" -o StrictHostKeyChecking=accept-new"
        f" -o ConnectTimeout=10"
        f" -P {port}"
    )


def wait_for_ssh(*, key: str, user: str, host: str, port: int = 22,
                 retries: int = 30, wait: int = 10, dry_run: bool = False) -> None:
    for attempt in range(1, retries + 1):
        log(f"[INFO] SSH connectivity check {attempt}/{retries} → {user}@{host}:{port}")
        if dry_run:
            log(f"[OK] SSH reachable (dry-run): {host}:{port}")
            return
        result = subprocess.run(
            f"{ssh_base_cmd(key, user, host, port)} echo ok",
            shell=True, capture_output=True, text=True
        )
        if result.returncode == 0:
            log(f"[OK] SSH reachable: {host}:{port}")
            return
        if attempt < retries:
            log(f"  Not ready (code={result.returncode}), waiting {wait}s...")
            time.sleep(wait)
    raise RuntimeError(f"SSH {user}@{host}:{port} not reachable after {retries} attempts")


def wait_for_image_status(*, openrc: str, image_ref: str,
                          poll_seconds: int = 5, timeout_seconds: int = 1800,
                          dry_run: bool = False) -> dict:
    if dry_run:
        return {"id": image_ref, "status": "active"}
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        out = run(openstack_cmd(openrc, f"openstack image show {shell_quote(image_ref)} -f json"),
                  dry_run=dry_run, check=False)
        try:
            payload = json.loads(out)
            status = payload.get("status", "unknown")
            log(f"[INFO] image={image_ref} status={status}")
            if status == "active":
                return payload
            if status in ("killed", "deleted", "error"):
                raise RuntimeError(f"Image {image_ref} entered terminal state: {status}")
        except (json.JSONDecodeError, TypeError):
            pass
        time.sleep(poll_seconds)
    raise RuntimeError(f"Timed out waiting for image {image_ref} to become active")


def wait_for_server_status(*, openrc: str, server_ref: str, desired_status: str = "ACTIVE",
                           poll_seconds: int = 5, timeout_seconds: int = 600,
                           dry_run: bool = False) -> dict:
    if dry_run:
        return {"id": server_ref, "status": desired_status, "addresses": ""}
    deadline = time.time() + timeout_seconds
    consecutive_failures = 0
    max_consecutive_failures = 5
    while time.time() < deadline:
        out = run(openstack_cmd(openrc, f"openstack server show {shell_quote(server_ref)} -f json"),
                  dry_run=dry_run, check=False)
        try:
            payload = json.loads(out)
            consecutive_failures = 0
            status = payload.get("status", "unknown")
            log(f"[INFO] server={server_ref} status={status}")
            if status == desired_status:
                return payload
            if status in ("ERROR", "DELETED"):
                raise RuntimeError(f"Server {server_ref} in terminal state: {status}")
        except (json.JSONDecodeError, TypeError):
            consecutive_failures += 1
            log(f"[WARN] openstack server show returned non-JSON (attempt {consecutive_failures}/{max_consecutive_failures}): {str(out).strip()[:200]}")
            if consecutive_failures >= max_consecutive_failures:
                raise RuntimeError(f"openstack server show failed {max_consecutive_failures} times in a row — check OSPC credentials and connectivity. Last output: {str(out).strip()[:300]}")
        time.sleep(poll_seconds)
    raise RuntimeError(f"Timed out waiting for server {server_ref} → {desired_status}")


def parse_addresses_for_floating(addresses_str: str) -> list:
    """Extract IPs from openstack server show addresses field.
    Returns public (non-RFC1918) IPs first, then private IPs.
    """
    import re
    import ipaddress
    all_ips = re.findall(r'(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})', str(addresses_str))
    public, private = [], []
    for ip in all_ips:
        try:
            obj = ipaddress.ip_address(ip)
            if obj.is_private or obj.is_loopback or obj.is_link_local:
                private.append(ip)
            else:
                public.append(ip)
        except ValueError:
            pass
    return public + private  # public IPs first


# ─────────────────────────────────────────────────────────────────────────────
# Remote bash script builder
# ─────────────────────────────────────────────────────────────────────────────

def build_remote_export_script(
    *,
    snap_name: str,
    snap_id: str,
    flex_image_name: str,
    ospc_openrc_path: str,
    flex_openrc_path: str,
    origin_image_dir: str,
    target_format: str = "qcow2",
    container_format: str = "bare",
    visibility: str = "private",
    retries: int = 4,
    retry_wait_seconds: int = 15,
    keep_export: bool = True,
    direct_export: bool = False,
    # Mode 3: stream /dev/vda from origin VM to this (external) host via SSH pipe
    origin_vm_ip: str = "",
    origin_vm_user: str = "ubuntu",
    origin_vm_key_remote_path: str = "",   # path to SSH key ON the external host
    origin_vm_password_remote_path: str = "",  # path to SSH password file ON the external host
    # OS pre-detected from live origin VM via SSH (before stream)
    origin_os_id: str = "",
    origin_os_ver: str = "",
    # Offline repair strategy: 'custom_os' (per-OS profile) or 'generic' (standalone script only)
    offline_repair_method: str = "custom_os",
    # Same profile tokens as ospc2flex_glance_image_migrator / ospc2flex_repair_os_hint.py
    repair_os_type: str = "",
    cloud_files_fallback: bool = True,
    prefer_cloud_files_download: bool = True,
    ospc_cloud_files_container: str = "ospc2flex-export",
    flex_cloud_files_container: str = "ospc2flex-staging",
    glance_bridge_path: str = "/tmp/ospc2flex_glance_bridge.sh",
) -> str:
    """Generate the bash script that runs on the processing host (external or origin VM)."""

    script = f"""#!/usr/bin/env bash
set -euo pipefail

# ─── Logging helpers ────────────────────────────────────────────────────────
log() {{ echo "$@"; }}
stage_start() {{ local n=$1 t=$2 d=$3
  echo ""
  echo ""
  echo "┌──────────────────────────────────────────────────────┐"
  echo "│ STAGE $n ── $t"
  echo "│ $d"
  echo "└──────────────────────────────────────────────────────┘"
}}
stage_done() {{ local n=$1; echo "✅ STAGE $n RESULT: SUCCESS"; echo ""; }}
stage_fail() {{ local n=$1 msg=$2; echo "❌ STAGE $n RESULT: FAILED ── $msg"; echo ""; exit 1; }}

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║        OSPC → FLEX Datacenter Backbone Pipeline ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

export_retries={retries}
export_retry_wait={retry_wait_seconds}
# ── Workspace Initialization ──────────────────────────────────────────────────
# Dynamically find the mount point with the largest available free space (Strictly bypassing root drive if possible)
BEST_MOUNT=$(df -P -k | awk 'NR>1 && $1 !~ /tmpfs|udev|devtmpfs|overlay|shm|loop/ && $6 !~ /^[/](boot|run|dev|sys|proc|snap|var[/]lib)/ && $6 != "/" {{ print $4, $6 }}' | sort -rn | head -n1 | awk '{{print $2}}')

if [ -n "$BEST_MOUNT" ]; then
    workdir="$BEST_MOUNT/ospc2flex_image"
else
    workdir=$(eval echo {shell_quote(origin_image_dir)})
    log "[WARN] Strict policy fallback: No external data volumes found. Resorting to root drive."
fi

log "[INFO] Largest volume identified: $BEST_MOUNT"
log "[INFO] Using workspace folder: $workdir"
sudo mkdir -p "$workdir"
sudo chown $(whoami):$(whoami) "$workdir" 2>/dev/null || true
# ── Path definitions — always tied to THIS VM's snap_name ─────────────────────
# Never reuse another VM's leftover qcow2 (parallel jobs share the same workdir)
repaired_path="$workdir/{snap_name}-repaired.{target_format}"
converted_path="$workdir/{snap_name}.{target_format}"
img_path="$workdir/{snap_name}.img"

# ── Windows: no resume — wipe ALL files for this image before starting ────────
IS_WINDOWS={1 if repair_os_type and 'windows' in repair_os_type.lower() else 0}
if [ "$IS_WINDOWS" = "1" ]; then
  log "[INFO] Windows image detected — purging all existing files (no resume for Windows)"
  for _wf in "$img_path" "$converted_path" "$repaired_path"; do
    [ -f "$_wf" ] && rm -f "$_wf" && log "  [DEL] $_wf" || true
  done
  for _wf in "$workdir/{snap_name}".*; do
    [ -f "$_wf" ] && rm -f "$_wf" && log "  [DEL] $_wf" || true
  done
  log "[INFO] Windows workspace clean — starting fresh"
fi

# ── STAGE 1 ─────────────────────────────────────────────────────────────────
stage_start 1 'Validate Dependencies' 'Checking openstack CLI and qemu-img'
if ! command -v openstack >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/openstack" ]; then
  log '  Installing OpenStack CLI...'
  sudo apt-get update >/dev/null 2>&1 || true
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3-openstackclient >/dev/null 2>&1 || \\
    python3 -m pip install --break-system-packages --user python-openstackclient >/dev/null 2>&1 || true
  log '  [OK] openstack CLI installed'
else
  log '  [OK] openstack CLI present'
fi
if ! command -v qemu-img >/dev/null 2>&1; then
  log '  Installing qemu-utils...'
  sudo apt-get update >/dev/null 2>&1 || true
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y qemu-utils >/dev/null 2>&1
  log '  [OK] qemu-img installed'
else
  log '  [OK] qemu-img present'
fi
stage_done 1

# ── Restore converted image from repaired image ensuring we force Stage 4 re-repair ──
if [ -f "$repaired_path" ]; then
  log "  [INFO] Reverting previous repaired image to converted state to force Stage 4 execution: $repaired_path -> $converted_path"
  mv "$repaired_path" "$converted_path"
fi

# ── STAGE 2.5: Clean Old Workspace Images ────────────────────────────────────
# Only delete files belonging to THIS VM's snap prefix — never touch other VMs' files
# (parallel jobs share the same workdir — deleting other VMs' qcow2s would corrupt them)
stage_start '2.5' 'Clean Old Workspace' 'Removing previous .img + .qcow2 from old runs (freeing disk space)'
cleaned=0
SNAP_PREFIX="{snap_name}"
for f in "$workdir"/"$SNAP_PREFIX"*.img "$workdir"/"$SNAP_PREFIX"*.qcow2; do
  [ -f "$f" ] || continue
  [ "$f" = "$img_path" ] && continue
  [ "$f" = "$converted_path" ] && continue
  [ "$f" = "$repaired_path" ] && continue
  rm -f "$f" && log "  [DEL] $f" && cleaned=$((cleaned+1))
done
[ $cleaned -eq 0 ] && log '  [OK] No old images to clean' || log "  [OK] Removed $cleaned old image file(s)"
df -h "$workdir" | tail -1 | awk '{{print "  [INFO] Disk free: " $4 " / " $2}}'
stage_done '2.5'

# ── Check: skip to repair if converted .qcow2 already exists and is large enough ─
MIN_SIZE_BYTES=10737418240  # 10 GB — images smaller than this are incomplete (Windows min ~12 GB)
if [ -f "$converted_path" ]; then
  _sz=$(stat -c%s "$converted_path" 2>/dev/null || echo 0)
  if [ "$_sz" -lt "$MIN_SIZE_BYTES" ]; then
    log "  [WARN] Converted qcow2 too small ($_sz bytes < 5 GB) — deleting and re-downloading"
    rm -f "$converted_path"
  else
    log "  [INFO] Converted qcow2 exists: $converted_path ($_sz bytes) — skipping to stage 4.5 (offline repair)"
  fi
fi
if [ -f "$converted_path" ]; then
  log "  [INFO] Resuming from converted qcow2"
else
"""

    if origin_vm_ip:
        # ── MODE 3: SSH pipe — stream /dev/vda from origin VM to this external host ──
        script += f"""\
# ── STAGE 3: PRODUCTION MODE — SSH Stream from Origin VM ─────────────────────
# Production Mode: external processing host pulls /dev/vda from origin VM via SSH pipe.
# Origin VM is NOT touched by any processing — just streams raw disk bytes.
# External host converts + repairs + uploads. No OSPC Glance snapshot, no download, no 413 limits.
stage_start 3 'PRODUCTION MODE — SSH Stream' 'Piping /dev/vda from origin VM → qemu-img convert on this host'
ORIGIN_VM_IP={shell_quote(origin_vm_ip)}
ORIGIN_VM_USER={shell_quote(origin_vm_user)}
ORIGIN_VM_KEY={shell_quote(origin_vm_key_remote_path)}
ORIGIN_VM_PASS_FILE={shell_quote(origin_vm_password_remote_path)}
log "  [INFO] Origin VM: $ORIGIN_VM_USER@$ORIGIN_VM_IP"
if [ -n "$ORIGIN_VM_PASS_FILE" ] && [ -f "$ORIGIN_VM_PASS_FILE" ]; then
  log "  [INFO] Origin auth: password file"
  if ! command -v sshpass >/dev/null 2>&1; then
    log "  [INFO] Installing sshpass for password-based origin SSH..."
    sudo apt-get update >/dev/null 2>&1 || true
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y sshpass >/dev/null 2>&1 || true
  fi
elif [ -n "$ORIGIN_VM_KEY" ]; then
  log "  [INFO] Origin key: $ORIGIN_VM_KEY"
else
  stage_fail 3 "Origin VM auth missing — no SSH key or password file available"
fi
origin_ssh() {{
  local _remote_cmd="$1"
  if [ -n "$ORIGIN_VM_PASS_FILE" ] && [ -f "$ORIGIN_VM_PASS_FILE" ]; then
    sshpass -f "$ORIGIN_VM_PASS_FILE" ssh \
      -o PreferredAuthentications=password,keyboard-interactive \
      -o PubkeyAuthentication=no \
      -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=30 \
      -o ServerAliveInterval=30 \
      -o ServerAliveCountMax=20 \
      "$ORIGIN_VM_USER@$ORIGIN_VM_IP" "$_remote_cmd"
  else
    ssh -i "$ORIGIN_VM_KEY" \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=30 \
      -o ServerAliveInterval=30 \
      -o ServerAliveCountMax=20 \
      -o Compression=no \
      "$ORIGIN_VM_USER@$ORIGIN_VM_IP" "$_remote_cmd"
  fi
}}
# Test SSH connectivity to origin VM
if ! origin_ssh "echo ok" >/dev/null 2>&1; then
  stage_fail 3 "Cannot SSH to origin VM $ORIGIN_VM_IP — check key/password and connectivity"
fi
log "  [OK] SSH to origin VM verified"
# Detect root disk on origin VM (prefer vda/xvda/sda — skip loop/nbd/dm devices)
_origin_disk_detect='for d in /dev/vda /dev/xvda /dev/sda; do [ -b "$d" ] && echo "$d" && break; done'
# Get disk size from origin VM for space check
DISK_KB=$(origin_ssh "ORIGIN_DISK=\\$(for d in /dev/vda /dev/xvda /dev/sda; do [ -b \\\"\\$d\\\" ] && echo \\\"\\$d\\\" && break; done); sudo blockdev --getsize64 \\\"\\$ORIGIN_DISK\\\" 2>/dev/null || echo 0" \
    2>/dev/null | awk '{{print int($1/1024)}}' || echo 0)
FREE_KB=$(df -k "$workdir" | tail -1 | awk '{{print $4}}')
NEEDED_KB=$(( DISK_KB / 6 ))
log "  [INFO] Origin disk: ${{DISK_KB}}KB | Estimated compressed: ~${{NEEDED_KB}}KB | Local free: ${{FREE_KB}}KB"
if [ "$FREE_KB" -lt "$NEEDED_KB" ]; then
  log "  [WARN] Tight disk space on external host — need ~${{NEEDED_KB}}KB, have ${{FREE_KB}}KB. Proceeding anyway..."
fi
log "  [INFO] Checking if qemu-img is available on origin VM for direct compressed pipe..."
HAS_QEMU_IMG=$(origin_ssh "command -v qemu-img 2>/dev/null && echo YES || echo NO" 2>/dev/null || echo NO)
if [ "$HAS_QEMU_IMG" = "YES" ]; then
  log "  [INFO] qemu-img found on origin VM — piping compressed qcow2 directly (no intermediate raw file)"
  origin_ssh "ORIGIN_DISK=\\$(for d in /dev/vda /dev/xvda /dev/sda; do [ -b \\\"\\$d\\\" ] && echo \\\"\\$d\\\" && break; done); echo \\\"[ORIGIN] Converting \\$ORIGIN_DISK → qcow2 pipe...\\\" >&2; sudo qemu-img convert -f raw -O qcow2 -c \\\"\\$ORIGIN_DISK\\\" /dev/stdout 2>/dev/null" \
    > "$converted_path"
  SIZE_BYTES=$(stat -c%s "$converted_path" 2>/dev/null || echo 0)
  if [ "$SIZE_BYTES" -lt 10485760 ]; then
    rm -f "$converted_path"
    stage_fail 3 "Direct qcow2 pipe output too small (${{SIZE_BYTES}} bytes) — qemu-img convert on origin failed"
  fi
  SIZE=$(ls -lh "$converted_path" | awk '{{print $5}}')
  log "  [OK] Direct qcow2 pipe complete: $converted_path ($SIZE)"
else
  log "  [INFO] qemu-img not on origin VM — using dd sparse pipe + local convert (no full-disk raw file)"
  RAW_IMG="$workdir/{snap_name}.img"
  origin_ssh "ORIGIN_DISK=\\$(for d in /dev/vda /dev/xvda /dev/sda; do [ -b \\\"\\$d\\\" ] && echo \\\"\\$d\\\" && break; done); echo \\\"[ORIGIN] Streaming \\$ORIGIN_DISK...\\\" >&2; sudo dd if=\\\"\\$ORIGIN_DISK\\\" bs=4M status=none 2>/dev/null" \
    | dd of="$RAW_IMG" bs=4M conv=sparse 2>/dev/null
  RAW_SIZE=$(stat -c%s "$RAW_IMG" 2>/dev/null || echo 0)
  if [ "$RAW_SIZE" -lt 10485760 ]; then
    rm -f "$RAW_IMG"
    stage_fail 3 "Raw image too small (${{RAW_SIZE}} bytes) — SSH stream likely failed"
  fi
  SPARSE_ACTUAL=$(du -sh "$RAW_IMG" 2>/dev/null | cut -f1)
  log "  [OK] Sparse raw received: $RAW_IMG (apparent=$(ls -lh "$RAW_IMG" | awk '{{print $5}}') actual=$SPARSE_ACTUAL), converting..."
  qemu-img convert -p -f raw -O {target_format} -c "$RAW_IMG" "$converted_path"
  rm -f "$RAW_IMG"
  SIZE_BYTES=$(stat -c%s "$converted_path" 2>/dev/null || echo 0)
  if [ "$SIZE_BYTES" -lt 10485760 ]; then
    rm -f "$converted_path"
    stage_fail 3 "Output too small (${{SIZE_BYTES}} bytes) — conversion failed"
  fi
  SIZE=$(ls -lh "$converted_path" | awk '{{print $5}}')
  log "  [OK] SSH stream + convert complete: $converted_path ($SIZE)"
fi
stage_done 3

"""
    elif direct_export:
        # ── MODE 1: script runs ON the origin VM — read /dev/vda directly ──
        script += f"""\
# ── STAGE 3: Direct Disk Export ───────────────────────────────────────────────
stage_start 3 'Direct Disk Export' 'Reading live root disk directly via qemu-img (no Glance download)'
# Exclude nbd, loop, dm devices — pick first real disk (xvda/vda/sda)
DISK=$(lsblk -rno NAME,TYPE | awk '$2=="disk" && $1 !~ /^(nbd|loop|dm-)/ {{print "/dev/"$1; exit}}')
[ -z "$DISK" ] && DISK=/dev/xvda
log "  [INFO] Root disk detected: $DISK"
DISK_KB=$(sudo blockdev --getsize64 "$DISK" 2>/dev/null | awk '{{print int($1/1024)}}' || echo 0)
if [ "$DISK_KB" -eq 0 ]; then
  stage_fail 3 "Disk $DISK has 0 bytes — wrong device detected. Check lsblk output."
fi
log "  [INFO] Maximizing compression: Pre-conditioning root filesystem to zero-out deleted data..."
sudo fstrim / 2>/dev/null || true
sudo dd if=/dev/zero of=/zerofile bs=4M count=5000 2>/dev/null || true
sudo rm -f /zerofile && sudo sync
FREE_KB=$(df -k "$workdir" | tail -1 | awk '{{print $4}}')
NEEDED_KB=$(( DISK_KB / 6 ))
log "  [INFO] Disk size: ${{DISK_KB}}KB | Estimated compressed size: ~${{NEEDED_KB}}KB | Workspace free: ${{FREE_KB}}KB"
if [ "$FREE_KB" -lt "$NEEDED_KB" ]; then
  log "  [WARN] Tight disk space! Estimated need ~${{NEEDED_KB}}KB, but only have ${{FREE_KB}}KB. Attempting anyway..."
fi
log "  [INFO] Converting live disk $DISK → {target_format} with compression..."
sudo qemu-img convert -p -c -f raw -O {target_format} "$DISK" "$converted_path"
SIZE_BYTES=$(stat -c%s "$converted_path" 2>/dev/null || echo 0)
if [ "$SIZE_BYTES" -lt 10485760 ]; then
  rm -f "$converted_path"
  stage_fail 3 "Output qcow2 is too small (${{SIZE_BYTES}} bytes) — disk imaging likely failed"
fi
SIZE=$(ls -lh "$converted_path" | awk '{{print $5}}')
log "  [OK] Direct disk export complete: $converted_path ($SIZE)"
stage_done 3

"""
    else:
        script += f"""\
# ── STAGE 3: Download OSPC Snapshot ──────────────────────────────────────────
stage_start 3 'Download OSPC Snapshot' 'Prefer Glance export → Cloud Files → same-region jumphost'
log '  Sourcing OSPC credentials...'
source {shell_quote(ospc_openrc_path)}
log '  Acquiring OSPC Keystone token...'
# Try openstack CLI first; fall back to RAX apikey curl if it fails
OS_TOKEN=$(openstack token issue -f value -c id 2>/dev/null || true)
if [ -z "$OS_TOKEN" ] && [ -n "${{OS_USERNAME:-}}" ] && [ -n "${{OS_PASSWORD:-}}" ]; then
  log '  [INFO] openstack token issue failed — trying RAX apikey auth...'
  _AUTH_RESP=$(curl -s -X POST "https://identity.api.rackspacecloud.com/v2.0/tokens" \\
    -H "Content-Type: application/json" \\
    -d '{{"auth":{{"RAX-KSKEY:apiKeyCredentials":{{"username":"'"${{OS_USERNAME:-}}"'","apiKey":"'"${{OS_PASSWORD:-}}"'"}}}}}}' 2>/dev/null || true)
  OS_TOKEN=$(echo "$_AUTH_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['access']['token']['id'])" 2>/dev/null || true)
fi
if [ -z "$OS_TOKEN" ]; then
  stage_fail 3 'No OSPC token — check OSPC credentials'
fi
# Get IAD Glance endpoint from catalog
OS_IMAGE_URL=$(openstack catalog show image -f json 2>/dev/null | python3 -c "
import sys,json
data=json.load(sys.stdin)
eps=[e for e in data.get('endpoints',[]) if e.get('interface')=='public']
print(eps[0]['url'].rstrip('/') if eps else '')
" 2>/dev/null || true)
if [ -z "$OS_IMAGE_URL" ]; then
  log '  [WARN] Catalog lookup failed — using IAD Glance endpoint'
  OS_IMAGE_URL="https://iad.images.api.rackspacecloud.com"
fi
IMG_DOWNLOAD_URL="$OS_IMAGE_URL/v2/images/{snap_id}/file"
log "  Target: $IMG_DOWNLOAD_URL"
success=0
GLANCE_BRIDGE={shell_quote(glance_bridge_path)}
if [ $success -eq 0 ] && [ "{1 if cloud_files_fallback else 0}" = "1" ] && [ -x "$GLANCE_BRIDGE" ]; then
  log "  Trying {'Cloud Files preferred' if prefer_cloud_files_download else 'Classic Glance first'} bridge (Glance/Cloud Files waterfall)..."
  if bash "$GLANCE_BRIDGE" download \
      --ospc-openrc {shell_quote(ospc_openrc_path)} \
      --image-id {shell_quote(snap_id)} \
      --dest "$img_path" \
      --container {shell_quote(ospc_cloud_files_container)} \
      {"--prefer-cloud-files" if prefer_cloud_files_download else ""} \
      --retries "$export_retries" \
      --retry-wait "$export_retry_wait" \
      --min-bytes 1048576; then
    size=$(stat -c%s "$img_path" 2>/dev/null || echo 0)
    log "  [OK] Bridge downloaded OSPC image: $size bytes"
    success=1
  else
    log "  [WARN] Bridge download failed — falling back to legacy public Glance loop"
    rm -f "$img_path"
  fi
elif [ "{1 if cloud_files_fallback else 0}" = "1" ]; then
  log "  [WARN] Glance bridge not found at $GLANCE_BRIDGE — using legacy public Glance loop"
fi
# Try openstack image save first (avoids 413 on Rackspace OSPC Glance large files)
if [ $success -eq 0 ]; then
log "  Trying openstack image save (primary method — avoids HTTP 413)..."
rm -f "$img_path"
if openstack image save --file "$img_path" "{snap_id}" 2>/tmp/ospc_img_save_err.txt; then
  size=$(stat -c%s "$img_path" 2>/dev/null || echo 0)
  if [ "$size" -gt 1048576 ]; then
    log "  [OK] Download via openstack image save: ${{size}} bytes"
    success=1
  else
    log "  [WARN] openstack image save returned small file (${{size}} bytes) — $(cat /tmp/ospc_img_save_err.txt 2>/dev/null | head -2)"
    rm -f "$img_path"
  fi
else
  log "  [WARN] openstack image save failed: $(cat /tmp/ospc_img_save_err.txt 2>/dev/null | head -2) — falling back to curl"
  rm -f "$img_path"
fi
fi
# Curl fallback with retry loop (if openstack image save failed)
if [ $success -eq 0 ]; then
for attempt in $(seq 1 $export_retries); do
  log "  curl attempt $attempt/$export_retries — large file, please wait..."
  HTTP_STATUS=$(curl -s -C - -L --retry 3 --retry-delay 10 --retry-max-time 180 \\
    -H "X-Auth-Token: $OS_TOKEN" \\
    -o "$img_path" \\
    --write-out '%{{http_code}}' \\
    "$IMG_DOWNLOAD_URL" 2>/dev/null || echo '000')
  size=$(stat -c%s "$img_path" 2>/dev/null || echo 0)
  log "  HTTP $HTTP_STATUS | $size bytes received"
  if [ "$size" -gt 1048576 ]; then
    log "  [OK] Download complete: $size bytes"
    success=1; break
  else
    log "  [WARN] Incomplete (size=$size) — refreshing token and retrying..."
    _AUTH_RESP=$(curl -s -X POST "https://identity.api.rackspacecloud.com/v2.0/tokens" \\
      -H "Content-Type: application/json" \\
      -d '{{"auth":{{"RAX-KSKEY:apiKeyCredentials":{{"username":"'"${{OS_USERNAME:-}}"'","apiKey":"'"${{OS_PASSWORD:-}}"'"}}}}}}' 2>/dev/null || true)
    OS_TOKEN=$(echo "$_AUTH_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['access']['token']['id'])" 2>/dev/null || true)
    rm -f "$img_path"
  fi
  [ $attempt -lt $export_retries ] && {{ log "  Waiting ${{export_retry_wait}}s..."; sleep $export_retry_wait; }}
done
fi
[ $success -eq 0 ] && stage_fail 3 'Download failed after all attempts (openstack image save + curl both failed)'
stage_done 3

# ── STAGE 4: Convert Image Format ────────────────────────────────────────────
stage_start 4 'Convert Image Format' 'Detect format via qemu-img info then convert → {target_format}'
DETECTED_FMT=$(qemu-img info --output=json "$img_path" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('format','raw'))" 2>/dev/null || echo 'raw')
log "  [INFO] Detected source format: $DETECTED_FMT"
if [ "$DETECTED_FMT" = "{target_format}" ]; then
  log '  [INFO] Source already in target format — copying without re-encoding'
  cp "$img_path" "$converted_path"
else
  log "  [INFO] Converting $DETECTED_FMT → {target_format}..."
  qemu-img convert -p -f "$DETECTED_FMT" -O {target_format} "$img_path" "$converted_path"
fi
SIZE=$(ls -lh "$converted_path" | awk '{{print $5}}')
log "  [OK] Output: $converted_path ($SIZE)"
stage_done 4

"""

    script += f"""\
fi  # end skip-if-qcow2-exists

# ── Shared repair profile (must match Glance image pipeline + ospc2flex_repair_os_hint.py) ──
REPAIR_OS_TYPE={shell_quote(repair_os_type or "")}
OFFLINE_REPAIR_METHOD={shell_quote(offline_repair_method or "custom_os")}
log "[INFO] Repair profile: REPAIR_OS_TYPE=${{REPAIR_OS_TYPE:-<auto>}} method=$OFFLINE_REPAIR_METHOD"

# ── STAGE 4.5: Offline Guest Repair ──────────────────────────────────────────
# Linux quick path (fstab + netplan). Windows skips — Stage 4.6 runs VirtIO script.
repair_ok=0
if [ "${{REPAIR_OS_TYPE:-}}" = "windows" ]; then
  stage_start '4.5' 'Offline Guest Repair' 'Windows — skip Linux fstab/netplan (handled in Stage 4.6)'
  cp "$converted_path" "$repaired_path"
  log "  [OK] Windows qcow2 staged for VirtIO repair: $repaired_path"
  stage_done '4.5'
else
stage_start '4.5' 'Offline Guest Repair' 'Simple repair: fstab + ens3 netplan (then Stage 4.6 per-OS scripts)'
NBD_DEV=/dev/nbd0
MNT=/tmp/ospc2flex_mnt_$$
if ! command -v qemu-nbd >/dev/null 2>&1; then
  log '  [INFO] qemu-nbd not found — installing qemu-utils...'
  sudo apt-get install -y qemu-utils >/dev/null 2>&1 && log '  [OK] qemu-utils installed' || log '  [WARN] Install failed'
fi
if command -v qemu-nbd >/dev/null 2>&1; then
  sudo qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
  sleep 1
  sudo modprobe nbd max_part=8 2>/dev/null || true
  sleep 1
  if sudo qemu-nbd --connect="$NBD_DEV" "$converted_path" 2>/tmp/nbd_err.txt; then
    sleep 3
    ROOT_PART=$(sudo fdisk -l "$NBD_DEV" 2>/dev/null | awk '/Linux filesystem/{{print $1; exit}}')
    [ -z "$ROOT_PART" ] && ROOT_PART="${{NBD_DEV}}p1"
    log "  Root partition: $ROOT_PART"
    sudo mkdir -p "$MNT"
    # Run fsck to repair dirty journal from live snapshot
    log '  Running fsck to repair dirty journal...'
    sudo fsck -y -f "$ROOT_PART" >/tmp/fsck_out.txt 2>&1 || true
    log "  fsck: $(tail -2 /tmp/fsck_out.txt 2>/dev/null | tr '\\n' ' ')"
    # Try normal mount, then norecovery fallback
    if sudo mount "$ROOT_PART" "$MNT" 2>/dev/null; then
      log '  [OK] Mounted normally'
    elif sudo mount -o norecovery,errors=remount-ro "$ROOT_PART" "$MNT" 2>/dev/null; then
      log '  [INFO] Mounted with norecovery flag'
    else
      log '  [WARN] Mount failed (tried normal + norecovery) — skipping offline repair'
      sudo qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
      sudo rmmod nbd 2>/dev/null || true
    fi
    if sudo mountpoint -q "$MNT" 2>/dev/null; then
      # ── Fix fstab: comment out all non-root, non-swap mounts ──────────────
      if [ -f "$MNT/etc/fstab" ]; then
        sudo cp "$MNT/etc/fstab" "$MNT/etc/fstab.ospc2flex.bak"
        sudo sed -i '/^[[:space:]]*#/b; /^[[:space:]]*$/b; /[[:space:]]\\/[[:space:]]/b; /[[:space:]]swap[[:space:]]/b; s/^/# [ospc2flex] /' "$MNT/etc/fstab"
        log '  [OK] fstab non-root mounts commented out'
        sudo grep -v '^#' "$MNT/etc/fstab" | grep -v '^[[:space:]]*$' || log '  (no active mounts other than root/swap)'
      fi
      # ── Fix netplan (Ubuntu + Debian 12+): write wildcard DHCP config ────────
      # repair_ok=1 when netplan is present (Ubuntu all versions / Debian 12+)
      # For RHEL/CentOS/Alma/Rocky (no /etc/netplan), repair_ok stays 0 and
      # Stage 4.6 runs ospc2flex_offline_repair.sh to fix networking.
      _os_id_45=$(sudo grep '^ID=' "$MNT/etc/os-release" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]' || true)
      _os_ver_45=$(sudo grep '^VERSION_ID=' "$MNT/etc/os-release" 2>/dev/null | cut -d= -f2 | tr -d '"' || true)
      _os_major_45=$(echo "$_os_ver_45" | cut -d. -f1)
      log "  [4.5] Detected OS: $_os_id_45 version $_os_ver_45 (major=$_os_major_45)"
      if [ -d "$MNT/etc/netplan" ]; then
        # Write wildcard netplan matching all NIC names (en* + eth*)
        # Works for Ubuntu 20 (enp3s0), 22 (enp3s0), 24 (ens3), Debian 12 (eth0)
        sudo tee "$MNT/etc/netplan/99-ospc2flex.yaml" >/dev/null <<'NETPLAN_EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    all-en:
      match:
        name: "en*"
      dhcp4: true
      dhcp6: false
      optional: true
    all-eth:
      match:
        name: "eth*"
      dhcp4: true
      dhcp6: false
      optional: true
NETPLAN_EOF
        sudo chmod 600 "$MNT/etc/netplan/99-ospc2flex.yaml"
        log '  [OK] Netplan wildcard DHCP written (en*/eth*)'
        # Remove MAC-locked cloud-init netplan that may conflict
        sudo rm -f "$MNT/etc/netplan/50-cloud-init.yaml" "$MNT/etc/netplan/50-curtin-networking.yaml" 2>/dev/null || true
        # ── Common cleanup ──────────────────────────────────────────────────
        sudo rm -f "$MNT/etc/udev/rules.d/70-persistent-net.rules" 2>/dev/null || true
        sudo rm -f "$MNT/etc/udev/rules.d/75-persistent-net-generator.rules" 2>/dev/null || true
        sudo rm -f "$MNT/etc/cloud/cloud-init.disabled" 2>/dev/null || true
        sudo rm -rf "$MNT/var/lib/cloud/instance" "$MNT/var/lib/cloud/instances/"* 2>/dev/null || true
        sudo rm -f "$MNT/var/lib/cloud/data/result.json" 2>/dev/null || true
        echo "" | sudo tee "$MNT/etc/machine-id" >/dev/null
        sudo rm -f "$MNT/var/lib/dbus/machine-id" 2>/dev/null || true
        sudo rm -f "$MNT/var/lib/dhcp/"*.leases "$MNT/var/lib/dhclient/"*.lease 2>/dev/null || true
        log '  [OK] cloud-init state cleared, machine-id reset, DHCP leases removed'
        sudo umount "$MNT" && repair_ok=1 || log '  [WARN] umount failed'
      elif [ "$_os_id_45" = "debian" ] && [ "${{_os_major_45:-0}}" -lt 12 ]; then
        # Debian 10/11: uses ifupdown, no netplan → fall through to Stage 4.6
        log '  [INFO] Debian $_os_major_45 uses ifupdown (no netplan). repair_ok=0 → Stage 4.6'
        sudo umount "$MNT" 2>/dev/null || true
      else
        log '  [INFO] No /etc/netplan dir — RHEL/CentOS/Alma/Rocky. repair_ok=0 → Stage 4.6'
        sudo umount "$MNT" 2>/dev/null || true
      fi
    fi
    sudo qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
    sudo rmmod nbd 2>/dev/null || true
    sudo rm -rf "$MNT"
  else
    log "  [WARN] qemu-nbd connect failed: $(cat /tmp/nbd_err.txt 2>/dev/null | head -3)"
    sudo rmmod nbd 2>/dev/null || true
  fi
else
  log '  [WARN] qemu-nbd not available — skipping offline repair'
fi

if [ $repair_ok -eq 1 ]; then
  mv "$converted_path" "$repaired_path"
  log "  [OK] Repaired image saved as: $repaired_path"
else
  cp "$converted_path" "$repaired_path"
  log "  [WARN] Stage 4.5 simple repair did not set repair_ok — Stage 4.6 will run per-OS repair scripts"
fi
[ $repair_ok -eq 1 ] && log '  [OK] Offline guest repair completed' || log '  [WARN] Offline repair skipped — VM may need manual fstab fix after boot'
stage_done '4.5'
fi

# ── STAGE 4.6: Per-OS offline repair (same scripts as Glance image pipeline) ──
stage_start '4.6' 'Per-OS Offline Repair' 'ospc2flex_offline_repair.sh (--os-type) or ospc2flex_windows_repair.sh (VirtIO)'
STANDALONE_REPAIR=/tmp/ospc2flex_offline_repair.sh
WIN_REPAIR=/tmp/ospc2flex_windows_repair.sh
REPAIR_LOG="$workdir/{snap_name}.repair.log"
verify_centos_lan_markers() {{
  local _profile="${{REPAIR_OS_TYPE:-}}"
  local _need=0
  case "$_profile" in
    centos*|rhel7*|rhel6*) _need=1 ;;
  esac
  [ "$_need" -eq 0 ] && return 0
  if [ ! -f "$REPAIR_LOG" ]; then
    log "  [ERROR] [REPAIR-LAN-E5] Repair log missing: $REPAIR_LOG"
    return 1
  fi
  if grep -q "Wrote fresh ifcfg-eth0 (no HWADDR, ONBOOT=yes, DHCP, NM_CONTROLLED=no)" "$REPAIR_LOG" \
     && grep -q "Enabled network.service" "$REPAIR_LOG"; then
    log "  [OK] [REPAIR-LAN] CentOS/RHEL LAN markers verified"
    return 0
  fi
  log "  [ERROR] [REPAIR-LAN-E5] Missing CentOS/RHEL LAN markers in $REPAIR_LOG"
  return 1
}}
if [ "${{REPAIR_OS_TYPE:-}}" = "windows" ]; then
  if [ -f "$WIN_REPAIR" ]; then
    log "  [INFO] Running Windows VirtIO repair: $WIN_REPAIR"
    if sudo bash "$WIN_REPAIR" --qcow2 "$repaired_path" --force; then
      log "  [OK] Windows offline repair completed"
      repair_ok=1
    else
      log "  [WARN] Windows repair failed — image may not boot on FLEX virtio"
    fi
  else
    log "  [WARN] Windows profile but $WIN_REPAIR not found on jumphost — cannot run VirtIO repair"
  fi
elif [ -f "$STANDALONE_REPAIR" ]; then
  log "  [INFO] Running Linux offline repair: $STANDALONE_REPAIR (method=$OFFLINE_REPAIR_METHOD)"
  rm -f "$REPAIR_LOG"
  log "  [INFO] Repair log: $REPAIR_LOG"
  if [ "$OFFLINE_REPAIR_METHOD" = "generic" ]; then
    if bash "$STANDALONE_REPAIR" --qcow2 "$repaired_path" --force 2>&1 | tee "$REPAIR_LOG"; then
      log "  [OK] Generic ospc2flex_offline_repair.sh completed"
      repair_ok=1
      verify_centos_lan_markers || exit 1
    else
      log "  [WARN] Generic repair failed — continuing upload as-is"
    fi
  else
    if [ -n "${{REPAIR_OS_TYPE:-}}" ]; then
      if bash "$STANDALONE_REPAIR" --qcow2 "$repaired_path" --force --os-type "${{REPAIR_OS_TYPE}}" 2>&1 | tee "$REPAIR_LOG"; then
        log "  [OK] Custom per-OS repair completed (profile=${{REPAIR_OS_TYPE}})"
        repair_ok=1
        verify_centos_lan_markers || exit 1
      else
        log "  [WARN] Profile repair failed — retrying auto-detect (no --os-type)"
        if bash "$STANDALONE_REPAIR" --qcow2 "$repaired_path" --force 2>&1 | tee "$REPAIR_LOG"; then
          log "  [OK] Auto-detect repair completed"
          repair_ok=1
          verify_centos_lan_markers || exit 1
        else
          log "  [WARN] Auto-detect repair also failed"
        fi
      fi
    else
      if bash "$STANDALONE_REPAIR" --qcow2 "$repaired_path" --force 2>&1 | tee "$REPAIR_LOG"; then
        log "  [OK] ospc2flex_offline_repair.sh completed (auto-detect)"
        repair_ok=1
        verify_centos_lan_markers || exit 1
      else
        log "  [WARN] Standalone repair failed"
      fi
    fi
  fi
else
  log "  [WARN] $STANDALONE_REPAIR not found on jumphost — cannot run Linux repair"
fi
stage_done '4.6'



# ── STAGE 4.7: Pre-Upload Repair Verification ────────────────────────────────
# Mount the repaired qcow2 and verify network config + fstab before uploading.
# If verification fails → re-run custom OS repair, then generic fallback.
# Only proceed to Stage 5 if image passes verification (or all repairs exhausted).
stage_start '4.7' 'Pre-Upload Repair Verification' 'Mounting repaired image to verify network config + fstab before upload'

_verify_repair() {{
  local qcow2_path="$1"
  local result=0
  local _mnt=/tmp/ospc2flex_verify_$$
  sudo modprobe nbd max_part=8 2>/dev/null || true
  local _nbd=""
  for _d in /dev/nbd{{0..15}}; do
    local _sz
    _sz=$(sudo blockdev --getsize64 "$_d" 2>/dev/null || echo 0)
    if [ "$_sz" -eq 0 ] 2>/dev/null; then
      if ! sudo fuser "$_d" 2>/dev/null | grep -q .; then
        _nbd="$_d"; break
      fi
    fi
  done
  if [ -z "$_nbd" ]; then
    log '  [VERIFY] No free NBD device — skipping verify (treating as OK)'
    return 0
  fi
  sudo qemu-nbd --disconnect "$_nbd" 2>/dev/null || true
  sleep 1
  if ! sudo qemu-nbd --connect="$_nbd" "$qcow2_path" 2>/tmp/nbd_verify_err.txt; then
    local _nbd_err
    _nbd_err=$(cat /tmp/nbd_verify_err.txt 2>/dev/null)
    log "  [VERIFY] qemu-nbd connect failed: $_nbd_err"
    if echo "$_nbd_err" | grep -qiE 'write.*lock|lock.*write|in use|another process'; then
      log "  [VERIFY] Image locked by another process — skipping verify (treating as OK)"
      sudo rmmod nbd 2>/dev/null || true
      return 0
    fi
    sudo rmmod nbd 2>/dev/null || true
    return 1
  fi
  sleep 3
  local _root
  _root=$(sudo fdisk -l "$_nbd" 2>/dev/null | awk '/Linux filesystem/{{sz=strtonum($5); if(sz>max){{max=sz;p=$1}}}} END{{print p}}')
  [ -z "$_root" ] && _root="${{_nbd}}p1"
  sudo mkdir -p "$_mnt"
  local _mounted=0
  if sudo mount "$_root" "$_mnt" 2>/dev/null; then
    _mounted=1
  elif sudo mount -o ro "$_root" "$_mnt" 2>/dev/null; then
    _mounted=1
  elif sudo mount -o norecovery,ro "$_root" "$_mnt" 2>/dev/null; then
    _mounted=1
  fi
  if [ $_mounted -eq 0 ]; then
    log "  [VERIFY] Mount failed for $_root — image may be corrupt"
    sudo qemu-nbd --disconnect "$_nbd" 2>/dev/null || true
    sudo rmmod nbd 2>/dev/null || true
    sudo rm -rf "$_mnt"
    return 1
  fi
  log "  [VERIFY] Mounted $_root at $_mnt"

  # ── Detect OS + version from mounted image ──────────────────────────────────
  local _os_id _os_ver _os_major
  _os_id=$(sudo grep '^ID=' "$_mnt/etc/os-release" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]' || true)
  _os_ver=$(sudo grep '^VERSION_ID=' "$_mnt/etc/os-release" 2>/dev/null | cut -d= -f2 | tr -d '"' || true)
  _os_major=$(echo "$_os_ver" | cut -d. -f1)
  [ -z "$_os_id" ] && _os_id="unknown"
  log "  [VERIFY] Detected OS: $_os_id version=$_os_ver major=$_os_major"

  # ── Check network config file ─────────────────────────────────────────────
  local _net_ok=0
  case "$_os_id" in
    ubuntu)
      if sudo bash -c "ls \"$_mnt/etc/netplan/\"*.yaml \"$_mnt/etc/netplan/\"*.yml 2>/dev/null | grep -q ."; then
        _net_ok=1; log "  [VERIFY] Ubuntu netplan config: FOUND ✅"
      else
        log "  [VERIFY] Ubuntu netplan config: MISSING ❌"
      fi ;;
    debian)
      # Debian 12+ uses netplan, Debian 10/11 uses ifupdown
      if [ "${{_os_major:-0}}" -ge 12 ]; then
        if sudo bash -c "ls \"$_mnt/etc/netplan/\"*.yaml \"$_mnt/etc/netplan/\"*.yml 2>/dev/null | grep -q ."; then
          _net_ok=1; log "  [VERIFY] Debian $_os_major netplan config: FOUND ✅"
        else
          log "  [VERIFY] Debian $_os_major netplan config: MISSING ❌"
        fi
      else
        if sudo test -f "$_mnt/etc/network/interfaces" 2>/dev/null; then
          _net_ok=1; log "  [VERIFY] Debian $_os_major /etc/network/interfaces: FOUND ✅"
        else
          log "  [VERIFY] Debian $_os_major /etc/network/interfaces: MISSING ❌"
        fi
      fi ;;
    almalinux|rocky|rhel|fedora)
      # v9+: needs both ifcfg AND NM keyfile; v8: ifcfg only
      if [ "${{_os_major:-0}}" -ge 9 ]; then
        local _has_ifcfg=0 _has_keyfile=0
        sudo test -f "$_mnt/etc/sysconfig/network-scripts/ifcfg-eth0" 2>/dev/null && _has_ifcfg=1
        sudo test -f "$_mnt/etc/NetworkManager/system-connections/eth0.nmconnection" 2>/dev/null && _has_keyfile=1
        if [ $_has_ifcfg -eq 1 ] && [ $_has_keyfile -eq 1 ]; then
          _net_ok=1; log "  [VERIFY] $_os_id v$_os_major: ifcfg-eth0 + eth0.nmconnection: BOTH FOUND ✅"
        elif [ $_has_ifcfg -eq 1 ]; then
          _net_ok=1; log "  [VERIFY] $_os_id v$_os_major: ifcfg-eth0 FOUND, nmconnection MISSING (acceptable) ✅"
        else
          log "  [VERIFY] $_os_id v$_os_major: ifcfg=$_has_ifcfg keyfile=$_has_keyfile ❌"
        fi
      else
        if sudo test -f "$_mnt/etc/sysconfig/network-scripts/ifcfg-eth0" 2>/dev/null; then
          _net_ok=1; log "  [VERIFY] $_os_id v$_os_major ifcfg-eth0: FOUND ✅"
        else
          log "  [VERIFY] $_os_id v$_os_major ifcfg-eth0: MISSING ❌"
        fi
      fi ;;
    centos)
      if sudo test -f "$_mnt/etc/sysconfig/network-scripts/ifcfg-eth0" 2>/dev/null; then
        _net_ok=1; log "  [VERIFY] CentOS ifcfg-eth0: FOUND ✅"
      else
        log "  [VERIFY] CentOS ifcfg-eth0: MISSING ❌"
      fi ;;
    *)
      # Unknown OS — check for any netplan or interfaces file
      if sudo ls "$_mnt/etc/netplan/"*.yaml "$_mnt/etc/netplan/"*.yml 2>/dev/null | grep -q . || \
         sudo test -f "$_mnt/etc/network/interfaces" 2>/dev/null || \
         sudo ls "$_mnt/etc/NetworkManager/system-connections/"*.nmconnection 2>/dev/null | grep -q .; then
        _net_ok=1; log "  [VERIFY] Network config (unknown OS fallback): FOUND ✅"
      else
        log "  [VERIFY] Network config (unknown OS): MISSING — proceeding anyway ⚠️"
        _net_ok=1  # Don't block on unknown OS
      fi ;;
  esac

  # ── Check fstab for broken /dev/vd* entries ───────────────────────────────
  local _fstab_ok=1
  if sudo test -f "$_mnt/etc/fstab" 2>/dev/null; then
    local _bad
    _bad=$(sudo grep -v '^#' "$_mnt/etc/fstab" 2>/dev/null | grep -v '^[[:space:]]*$' | grep '/dev/vd' || true)
    if [ -n "$_bad" ]; then
      log "  [VERIFY] fstab has unresolved /dev/vd* entries: ❌"
      echo "$_bad" | while read line; do log "    $line"; done
      _fstab_ok=0
    else
      log "  [VERIFY] fstab: no broken /dev/vd* entries ✅"
    fi
  else
    log "  [VERIFY] fstab: not found (OK for minimal images)"
  fi

  sudo umount "$_mnt" 2>/dev/null || true
  sudo qemu-nbd --disconnect "$_nbd" 2>/dev/null || true
  sudo rmmod nbd 2>/dev/null || true
  sudo rm -rf "$_mnt"

  if [ $_net_ok -eq 1 ] && [ $_fstab_ok -eq 1 ]; then
    log "  [VERIFY] ✅ Image passed pre-upload verification"
    return 0
  else
    log "  [VERIFY] ❌ Image FAILED pre-upload verification (net_ok=$_net_ok fstab_ok=$_fstab_ok)"
    return 1
  fi
}}

_max_repair_attempts=3
_repair_attempt=0
_verify_passed=0

if [ "${{REPAIR_OS_TYPE:-}}" = "windows" ]; then
  log "  [INFO] Windows image — skipping Linux-specific pre-upload verification (NTFS cannot be verified via nbd mount)"
  log "  [INFO] Windows VirtIO repair was applied in Stage 4.6 — proceeding to upload"
  _verify_passed=1
else

while [ $_repair_attempt -lt $_max_repair_attempts ]; do
  if _verify_repair "$repaired_path"; then
    _verify_passed=1
    break
  fi
  _repair_attempt=$((_repair_attempt + 1))
  log "  [VERIFY] Repair attempt $_repair_attempt / $((_max_repair_attempts - 1))..."

  STANDALONE_REPAIR=/tmp/ospc2flex_offline_repair.sh
  if [ $_repair_attempt -eq 1 ]; then
    # First failure: re-run custom OS repair on the repaired_path
    log "  [VERIFY] Re-running custom OS repair (Stage 4.5 profile) on $repaired_path..."
    # Re-mount and apply OS profile repair inline
    _rmnt2=/tmp/ospc2flex_reverify_$$
    sudo modprobe nbd max_part=8 2>/dev/null || true
    _rnbd2=""
    for _d2 in /dev/nbd{{0..15}}; do
      _sz2=$(sudo blockdev --getsize64 "$_d2" 2>/dev/null || echo 0)
      if [ "$_sz2" -eq 0 ] 2>/dev/null; then
        if ! sudo fuser "$_d2" 2>/dev/null | grep -q .; then
          _rnbd2="$_d2"; break
        fi
      fi
    done
    if [ -n "$_rnbd2" ]; then
      sudo qemu-nbd --disconnect "$_rnbd2" 2>/dev/null || true
      sleep 1
      if sudo qemu-nbd --connect="$_rnbd2" "$repaired_path" 2>/dev/null; then
        sleep 3
        _rpart2=$(sudo fdisk -l "$_rnbd2" 2>/dev/null | awk '/Linux filesystem/{{sz=strtonum($5); if(sz>max){{max=sz;p=$1}}}} END{{print p}}')
        [ -z "$_rpart2" ] && _rpart2="${{_rnbd2}}p1"
        sudo mkdir -p "$_rmnt2"
        sudo fsck -y -f "$_rpart2" >/dev/null 2>&1 || true
        if sudo mount "$_rpart2" "$_rmnt2" 2>/dev/null || sudo mount -o ro "$_rpart2" "$_rmnt2" 2>/dev/null; then
          _ros2=$(sudo grep '^ID=' "$_rmnt2/etc/os-release" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]' || echo unknown)
          log "  [VERIFY-REPAIR] OS=$_ros2 — rewriting network config..."
          case "$_ros2" in
            ubuntu)
              sudo rm -f "$_rmnt2/etc/netplan/50-cloud-init.yaml" "$_rmnt2/etc/netplan/50-curtin-networking.yaml" 2>/dev/null || true
              sudo mkdir -p "$_rmnt2/etc/netplan"
              sudo tee "$_rmnt2/etc/netplan/99-ospc2flex.yaml" >/dev/null <<'_NP_EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    all-en:
      match:
        name: "en*"
      dhcp4: true
      dhcp6: false
      optional: true
    all-eth:
      match:
        name: "eth*"
      dhcp4: true
      dhcp6: false
      optional: true
_NP_EOF
              sudo chmod 600 "$_rmnt2/etc/netplan/99-ospc2flex.yaml"
              log "  [VERIFY-REPAIR] Ubuntu: wrote wildcard 99-ospc2flex.yaml" ;;
            debian)
              _dver=$(sudo grep '^VERSION_ID=' "$_rmnt2/etc/os-release" 2>/dev/null | cut -d= -f2 | tr -d '"' || true)
              _dmaj=$(echo "$_dver" | cut -d. -f1)
              if [ "${{_dmaj:-0}}" -ge 12 ]; then
                # Debian 12+: uses netplan + systemd-networkd
                sudo mkdir -p "$_rmnt2/etc/netplan"
                sudo tee "$_rmnt2/etc/netplan/99-ospc2flex.yaml" >/dev/null <<'_NP2_EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    all-en:
      match:
        name: "en*"
      dhcp4: true
      dhcp6: false
      optional: true
    all-eth:
      match:
        name: "eth*"
      dhcp4: true
      dhcp6: false
      optional: true
_NP2_EOF
                sudo chmod 600 "$_rmnt2/etc/netplan/99-ospc2flex.yaml"
                log "  [VERIFY-REPAIR] Debian $_dmaj: wrote wildcard netplan"
              else
                # Debian 10/11: uses ifupdown
                sudo tee "$_rmnt2/etc/network/interfaces" >/dev/null <<'_IF_EOF'
auto lo
iface lo inet loopback
auto eth0
allow-hotplug eth0
iface eth0 inet dhcp
    mtu 3942
_IF_EOF
                log "  [VERIFY-REPAIR] Debian $_dmaj: rewrote /etc/network/interfaces"
              fi ;;
            almalinux|rocky|rhel|fedora)
              _aver=$(sudo grep '^VERSION_ID=' "$_rmnt2/etc/os-release" 2>/dev/null | cut -d= -f2 | tr -d '"' || true)
              _amaj=$(echo "$_aver" | cut -d. -f1)
              sudo mkdir -p "$_rmnt2/etc/sysconfig/network-scripts"
              if [ "${{_amaj:-0}}" -eq 7 ] && [ "$_ros2" = "rhel" ]; then
                sudo rm -f "$_rmnt2/etc/systemd/system/network.service" 2>/dev/null || true
                sudo mkdir -p "$_rmnt2/etc/systemd/system/multi-user.target.wants"
                sudo ln -sf /usr/lib/systemd/system/network.service \
                  "$_rmnt2/etc/systemd/system/multi-user.target.wants/network.service" 2>/dev/null || true
                sudo ln -sf /dev/null "$_rmnt2/etc/systemd/system/NetworkManager-wait-online.service" 2>/dev/null || true
                sudo rm -f "$_rmnt2/etc/systemd/system/multi-user.target.wants/NetworkManager.service" 2>/dev/null || true
                sudo rm -f "$_rmnt2/etc/systemd/system/dbus-org.freedesktop.NetworkManager.service" 2>/dev/null || true
                sudo rm -f "$_rmnt2/etc/systemd/system/graphical.target.wants/NetworkManager.service" 2>/dev/null || true
                sudo ln -sf /dev/null "$_rmnt2/etc/systemd/system/NetworkManager.service" 2>/dev/null || true
                sudo tee "$_rmnt2/etc/sysconfig/network-scripts/ifcfg-eth0" >/dev/null <<'_IC7R_EOF'
DEVICE=eth0
BOOTPROTO=dhcp
ONBOOT=yes
NM_CONTROLLED=no
PEERDNS=yes
DEFROUTE=yes
IPV6INIT=no
TYPE=Ethernet
MTU=1500
_IC7R_EOF
                sudo find "$_rmnt2/etc/NetworkManager/system-connections" -name "*.nmconnection" -exec rm -f {{}} \\; 2>/dev/null || true
                log "  [VERIFY-REPAIR] RHEL 7: ifcfg + network.service + NM masked (matches offline repair)"
              else
              # Always write ifcfg-eth0 (works for both v8 and v9)
              sudo tee "$_rmnt2/etc/sysconfig/network-scripts/ifcfg-eth0" >/dev/null <<'_IC2_EOF'
# Written by ospc2flex VERIFY-REPAIR
DEVICE=eth0
BOOTPROTO=dhcp
ONBOOT=yes
TYPE=Ethernet
USERCTL=no
NM_CONTROLLED=yes
IPV6INIT=no
_IC2_EOF
              log "  [VERIFY-REPAIR] ${{_ros2}} v$_amaj: ifcfg-eth0 rewritten"
              # v9+: also write NM keyfile (RHEL 9 dual mode)
              if [ "${{_amaj:-0}}" -ge 9 ]; then
                sudo mkdir -p "$_rmnt2/etc/NetworkManager/system-connections"
                sudo tee "$_rmnt2/etc/NetworkManager/system-connections/eth0.nmconnection" >/dev/null <<'_NM_EOF'
[connection]
id=eth0
type=ethernet
autoconnect-priority=-100
autoconnect-retries=1
interface-name=eth0

[ethernet]

[ipv4]
dhcp-timeout=90
method=auto

[ipv6]
addr-gen-mode=eui64
method=auto

[proxy]
_NM_EOF
                sudo chmod 600 "$_rmnt2/etc/NetworkManager/system-connections/eth0.nmconnection"
                log "  [VERIFY-REPAIR] ${{_ros2}} v$_amaj: NM keyfile written (dual mode)"
              else
                # v8: remove stale keyfiles (ifcfg only)
                sudo find "$_rmnt2/etc/NetworkManager/system-connections" -name "*.nmconnection" -exec rm -f {{}} \\; 2>/dev/null || true
                log "  [VERIFY-REPAIR] ${{_ros2}} v$_amaj: cleared NM keyfiles (ifcfg-only)"
              fi
              fi ;;
            centos)
              _cver=$(sudo grep '^VERSION_ID=' "$_rmnt2/etc/os-release" 2>/dev/null | cut -d= -f2 | tr -d '"' || true)
              _cmaj=$(echo "$_cver" | cut -d. -f1)
              sudo mkdir -p "$_rmnt2/etc/sysconfig/network-scripts"
              if [ "${{_cmaj:-0}}" -eq 7 ]; then
                sudo rm -f "$_rmnt2/etc/systemd/system/network.service" 2>/dev/null || true
                sudo mkdir -p "$_rmnt2/etc/systemd/system/multi-user.target.wants"
                sudo ln -sf /usr/lib/systemd/system/network.service \
                  "$_rmnt2/etc/systemd/system/multi-user.target.wants/network.service" 2>/dev/null || true
                sudo ln -sf /dev/null "$_rmnt2/etc/systemd/system/NetworkManager-wait-online.service" 2>/dev/null || true
                sudo rm -f "$_rmnt2/etc/systemd/system/multi-user.target.wants/NetworkManager.service" 2>/dev/null || true
                sudo rm -f "$_rmnt2/etc/systemd/system/dbus-org.freedesktop.NetworkManager.service" 2>/dev/null || true
                sudo rm -f "$_rmnt2/etc/systemd/system/graphical.target.wants/NetworkManager.service" 2>/dev/null || true
                sudo ln -sf /dev/null "$_rmnt2/etc/systemd/system/NetworkManager.service" 2>/dev/null || true
                sudo tee "$_rmnt2/etc/sysconfig/network-scripts/ifcfg-eth0" >/dev/null <<'_IC7V_EOF'
DEVICE=eth0
BOOTPROTO=dhcp
ONBOOT=yes
NM_CONTROLLED=no
PEERDNS=yes
DEFROUTE=yes
IPV6INIT=no
TYPE=Ethernet
MTU=1500
_IC7V_EOF
                sudo find "$_rmnt2/etc/NetworkManager/system-connections" -name "*.nmconnection" -exec rm -f {{}} \\; 2>/dev/null || true
                log "  [VERIFY-REPAIR] CentOS 7: ifcfg + network.service + NM masked (matches offline repair)"
              else
                sudo tee "$_rmnt2/etc/sysconfig/network-scripts/ifcfg-eth0" >/dev/null <<'_IC_EOF'
DEVICE=eth0
NAME=eth0
TYPE=Ethernet
BOOTPROTO=dhcp
ONBOOT=yes
MTU=1500
NM_CONTROLLED=yes
DEFROUTE=yes
PEERDNS=yes
IPV6INIT=no
_IC_EOF
                log "  [VERIFY-REPAIR] CentOS (8+/stream): ifcfg-eth0 rewritten (MTU=1500)"
              fi ;;
          esac
          # Fix fstab again
          if sudo test -f "$_rmnt2/etc/fstab" 2>/dev/null; then
            sudo sed -i '/^[[:space:]]*#/b; /^[[:space:]]*$/b; /LABEL=/b; /UUID=/b; /PARTUUID=/b; s/^/# [ospc2flex-reverify] /' "$_rmnt2/etc/fstab"
            log "  [VERIFY-REPAIR] fstab /dev/vd* entries commented"
          fi
          sudo umount "$_rmnt2" 2>/dev/null || true
        fi
        sudo qemu-nbd --disconnect "$_rnbd2" 2>/dev/null || true
        sudo rmmod nbd 2>/dev/null || true
        sudo rm -rf "$_rmnt2"
      fi
    fi
  else
    # Second failure: generic ospc2flex_offline_repair.sh
    log "  [VERIFY] Re-running generic offline repair on $repaired_path..."
    if [ -f "$STANDALONE_REPAIR" ]; then
      bash "$STANDALONE_REPAIR" --qcow2 "$repaired_path" --force 2>&1 | tail -10 | tee -a /tmp/verify_repair.log || true
      log "  [VERIFY] Generic repair complete (non-zero exit ignored)"
    else
      log "  [VERIFY] Generic repair script not found at $STANDALONE_REPAIR — cannot repair further"
      log "  [VERIFY] Proceeding with upload as-is (best-effort)"
      _verify_passed=1
      break
    fi
  fi
done

if [ $_verify_passed -eq 0 ] && [ $_repair_attempt -ge $_max_repair_attempts ]; then
  log "  [VERIFY] ⚠️  Image still failed verification after $_max_repair_attempts repair attempts"
  log "  [VERIFY] Proceeding with upload anyway — manual boot repair may be needed on FLEX"
fi
fi  # end Windows/Linux verify branch
stage_done '4.7'

# ── STAGE 5: Upload to FLEX Glance ───────────────────────────────────────────
stage_start 5 'Upload to FLEX Glance' 'Uploading repaired qcow2 directly from origin VM to FLEX Glance'
sed -i 's/'$'\r''$//' {shell_quote(flex_openrc_path)}  # Strip Windows CR from openrc
source {shell_quote(flex_openrc_path)}
log '  [INFO] Authenticating to FLEX (via sourced OpenRC)...'
if ! openstack token issue >/dev/null 2>&1; then
  stage_fail 5 "FLEX authentication failed. Cannot connect to FLEX Glance. Please check credentials."
fi
log '  [OK] OpenRC sourced and authentication verified'

# Use native openstack CLI for image upload — correctly handles v3 Fernet tokens
# The CLI auto-discovers the correct Glance endpoint from the service catalog
log "  [INFO] Uploading image via openstack CLI..."
UPLOAD_SIZE=$(stat -c%s "$repaired_path" 2>/dev/null || echo 0)
log "  [INFO] Image: $repaired_path (${{UPLOAD_SIZE}} bytes)"
IMG_ID=$(openstack image create \\
  --disk-format {target_format} \\
  --container-format {container_format} \\
  --file "$repaired_path" \\
  --property visibility={visibility} \\
  --format value -c id \\
  "{flex_image_name}" 2>&1 || true)
if echo "$IMG_ID" | grep -qiE 'error|failed|traceback|exception|unauthorized' || [ -z "$IMG_ID" ]; then
  log "  [WARN] Direct openstack image create did not succeed: $IMG_ID"
  GLANCE_BRIDGE={shell_quote(glance_bridge_path)}
  if [ "{1 if cloud_files_fallback else 0}" = "1" ] && [ -x "$GLANCE_BRIDGE" ]; then
    log "  [INFO] Trying Cloud Files -> FLEX Glance bridge fallback..."
    if BRIDGE_UPLOAD_OUT=$(bash "$GLANCE_BRIDGE" upload \
        --flex-openrc {shell_quote(flex_openrc_path)} \
        --image-file "$repaired_path" \
        --image-name {shell_quote(flex_image_name)} \
        --disk-format {shell_quote(target_format)} \
        --container-format {shell_quote(container_format)} \
        --visibility {shell_quote(visibility)} \
        --container {shell_quote(flex_cloud_files_container)} 2>&1); then
      echo "$BRIDGE_UPLOAD_OUT"
      IMG_ID=$(echo "$BRIDGE_UPLOAD_OUT" | awk -F= '/^FLEX_IMAGE_ID=/ {{print $2; exit}}')
    else
      _bridge_rc=$?
      echo "$BRIDGE_UPLOAD_OUT"
      stage_fail 5 "FLEX upload failed via direct Glance and Cloud Files bridge (rc=$_bridge_rc)"
    fi
  else
    stage_fail 5 "Image upload failed and Cloud Files bridge is unavailable: $IMG_ID"
  fi
fi
if [ -z "$IMG_ID" ] || echo "$IMG_ID" | grep -qiE 'error|failed|traceback|exception|unauthorized'; then
  stage_fail 5 "Image upload produced no FLEX image ID after all methods: $IMG_ID"
fi
log "  [OK] Upload complete — Image ID: $IMG_ID"
SHOW_NAME=$(openstack image show "$IMG_ID" -f value -c name 2>/dev/null || echo "{flex_image_name}")
SHOW_VIS=$(openstack image show "$IMG_ID" -f value -c visibility 2>/dev/null || echo "unknown")
SHOW_STAT=$(openstack image show "$IMG_ID" -f value -c status 2>/dev/null || echo "unknown")
log "  [UPLOAD-CONFIRMED] region=${{OS_REGION_NAME:-unknown}} id=$IMG_ID name=${{SHOW_NAME:-unknown}} status=${{SHOW_STAT:-unknown}} visibility=${{SHOW_VIS:-unknown}}"
stage_done 5

# ── STAGE 5.5: Clean Workspace ───────────────────────────────────────────────
stage_start '5.5' 'Clean Workspace' 'Removing successfully uploaded artifact from origin VM'
rm -f "$repaired_path" "$converted_path" "$img_path" 2>/dev/null || true
log '  [OK] Workspace pruned'
stage_done '5.5'

echo "MIGRATION_COMPLETE=true"
echo "FLEX_IMAGE_ID=$IMG_ID"
exit 0

"""
    return script


# ─────────────────────────────────────────────────────────────────────────────
# Guest repair (runs on FLEX VM after boot)
# ─────────────────────────────────────────────────────────────────────────────

def repair_guest(
    *,
    key: str,
    user: str,
    host: str,
    port: int = 22,
    fix_fstab: bool = True,
    fix_netplan: bool = True,
    new_hostname: str = "",
    services: list = None,
    dry_run: bool = False,
) -> None:
    ssh = f"{ssh_base_cmd(key, user, host, port)}"

    def remote(cmd: str) -> str:
        return run(f"{ssh} {shell_quote(cmd)}", dry_run=dry_run, check=False)

    log("[INFO] === Online Guest Repair ===")

    if new_hostname:
        remote(f"sudo hostnamectl set-hostname {shell_quote(new_hostname)}")
        log(f"[OK] Hostname set to {new_hostname}")

    if fix_fstab:
        log("[INFO] STEP 1 — Fix /etc/fstab (comment out non-root mounts):")
        remote("sudo cp /etc/fstab /etc/fstab.ospc2flex.bak 2>/dev/null || true")
        remote(r"sudo sed -i '/^[[:space:]]*#/b; /^[[:space:]]*$/b; /^[[:space:]]*LABEL=/b; /^[[:space:]]*UUID=/b; /^[[:space:]]*PARTUUID=/b; /cloudconfig/b; s/^/# [ospc2flex] /' /etc/fstab")
        fstab = remote("sudo cat /etc/fstab 2>/dev/null || true")
        log(f"[OK] fstab after fix:\n{fstab}")

    if fix_netplan:
        log("[INFO] STEP 2 — Fix netplan (write clean DHCP config):")
        netplan_yaml = "network:\\n  version: 2\\n  ethernets:\\n    id0:\\n      match:\\n        name: en*\\n      dhcp4: true\\n      dhcp6: false\\n      mtu: 3942"
        remote(f"sudo mkdir -p /etc/netplan && printf '{netplan_yaml}' | sudo tee /etc/netplan/99-ospc2flex.yaml >/dev/null")
        log("[OK] Netplan DHCP config written")

    remote("sudo cloud-init clean 2>/dev/null || true")
    remote("sudo touch /etc/cloud/cloud-init.disabled 2>/dev/null || true")
    log("[OK] cloud-init disabled")

    remote("sudo apt-get update -qq >/dev/null 2>&1 && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y qemu-guest-agent >/dev/null 2>&1 || true")
    remote("sudo systemctl enable --now qemu-guest-agent 2>/dev/null || true")
    log("[OK] qemu-guest-agent installed")

    if services:
        for svc in services:
            remote(f"sudo systemctl restart {shell_quote(svc)} 2>&1 || true")
            log(f"[OK] Restarted {svc}")

    log("[INFO] === Online Guest Repair Complete ===")


# ─────────────────────────────────────────────────────────────────────────────
# Argument parser
# ─────────────────────────────────────────────────────────────────────────────

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="OSPC → FLEX image migration tool")
    p.add_argument("--ospc-openrc", required=True)
    p.add_argument("--flex-openrc", required=True)
    p.add_argument("--server-name", required=True)
    p.add_argument("--snapshot-name", help="Auto-generated if omitted")
    p.add_argument("--workdir", default="./image_migrator_work")
    p.add_argument("--target-format", default="qcow2", choices=["qcow2", "raw"])
    p.add_argument("--source-format")
    p.add_argument("--flex-image-name")
    p.add_argument("--visibility", default="private",
                   choices=["public", "private", "shared", "community"])
    p.add_argument("--container-format", default="bare")
    p.add_argument("--poll-seconds", type=int, default=5)
    p.add_argument("--timeout-seconds", type=int, default=1800)
    p.add_argument("--keep-export", action="store_true")
    p.add_argument("--cleanup-snapshot", action="store_true")
    p.add_argument("--export-retries", type=int, default=4)
    p.add_argument("--export-retry-wait", type=int, default=15)
    p.add_argument("--remote-export", action="store_true")
    p.add_argument("--origin-image-dir", default="$HOME/image")
    p.add_argument("--ssh-key-path")
    p.add_argument("--ssh-user", default="ubuntu")
    p.add_argument("--jumphost-user", default="ubuntu",
                   help="SSH user for the jumphost/processing host (default: ubuntu). "
                        "Use this when --ssh-user differs from the jumphost login user.")
    p.add_argument("--ssh-port", type=int, default=22)
    p.add_argument("--source-server-ip")
    p.add_argument("--jump-host")
    p.add_argument("--stop-before-snapshot", action="store_true")
    p.add_argument("--restart-after-snapshot", action="store_true")
    p.add_argument("--boot-test-vm", action="store_true")
    p.add_argument("--test-server-name")
    p.add_argument("--flex-flavor")
    p.add_argument("--flex-network-id")
    p.add_argument("--flex-key-name")
    p.add_argument("--flex-security-group", default="default")
    p.add_argument("--floating-ip")
    p.add_argument("--auto-floating-ip", action="store_true")
    p.add_argument("--flex-external-network", default="PUBLICNET")
    p.add_argument("--test-server-ip")
    p.add_argument("--repair-guest", action="store_true")
    p.add_argument("--new-hostname")
    p.add_argument("--fix-fstab", action="store_true")
    p.add_argument("--fix-netplan", action="store_true")
    p.add_argument("--flex-net-iface")
    p.add_argument("--systemd-services", default="")
    p.add_argument("--skip-cloud-init-clean", action="store_true")
    p.add_argument("--skip-qemu-guest-agent", action="store_true")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--direct-export", action="store_true")
    # Mode 3: stream /dev/vda from origin VM to external processing host via SSH pipe
    p.add_argument("--origin-vm-ip", help="IP of the source VM to stream /dev/vda from (Mode 3). Auto-discovered from OSPC if omitted.")
    p.add_argument("--origin-vm-user", default=None,
                   help="SSH user on the origin VM (default: auto-probed). In Mode 3 (--origin-vm-ip), "
                        "defaults to --ssh-user if not set.")
    p.add_argument("--origin-vm-ssh-key-path", default=None,
                   help="Optional per-instance SSH private key path for the origin VM. Defaults to --ssh-key-path.")
    p.add_argument("--origin-vm-password", default=None,
                   help="Optional per-instance SSH password for the origin VM when password auth is required.")
    p.add_argument("--offline-repair-method", default="custom_os", choices=["custom_os", "generic"],
                   help="Offline guest repair strategy: 'custom_os' (per-OS profile, default) or 'generic' (ospc2flex_offline_repair.sh for all VMs)")
    p.add_argument("--no-cloud-files-fallback", action="store_true",
                   help="Disable Cloud Files fallback for OSPC Glance download and FLEX Glance upload")
    p.add_argument("--no-prefer-cloud-files-download", action="store_true",
                   help="Do not start snapshot downloads with OSPC Glance export to Cloud Files; try direct Glance first")
    p.add_argument("--ospc-cloud-files-container", default="ospc2flex-export",
                   help="Cloud Files container for OSPC Glance export-task fallback")
    p.add_argument("--flex-cloud-files-container", default="ospc2flex-staging",
                   help="Cloud Files container for FLEX Glance import fallback")
    p.add_argument("--windows-admin-password", default=None,
                   help="Administrator password for Windows VMs. Used for automated SSH/WinRM post-boot verification.")
    return p


# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

def smart_copy(src: str, user: str, host: str, dest: str, *, key: str, port: int = 22, dry_run: bool = False) -> None:
    try:
        run(
            f"{scp_base_cmd(key, port)} {shell_quote(src)} {user}@{host}:{shell_quote(dest)}",
            dry_run=dry_run,
            log_cmd=False,
        )
    except RuntimeError as e:
        if 'Permission denied' in str(e) or 'scp' in str(e).lower():
            log(f"[WARN] SCP blocked or failed for {host}. Falling back to SSH stdin pipe...")
            run(
                f"cat {shell_quote(src)} | {ssh_base_cmd(key, user, host, port)} 'cat > {shell_quote(dest)}'",
                dry_run=dry_run,
                log_cmd=False,
            )
        else:
            raise


def main() -> None:
    args = build_parser().parse_args()
    if args.ssh_key_path:
        args.ssh_key_path = os.path.expanduser(args.ssh_key_path)
    if getattr(args, "origin_vm_ssh_key_path", None):
        args.origin_vm_ssh_key_path = os.path.expanduser(args.origin_vm_ssh_key_path)

    workdir = Path(args.workdir)
    workdir.mkdir(parents=True, exist_ok=True)

    timestamp = datetime.now().strftime("%Y%m%d%0H%M%S")
    snapshot_name = args.snapshot_name or f"{args.server_name}-snap-{timestamp}"
    flex_image_name = args.flex_image_name or f"{snapshot_name}-flex"
    test_server_name = args.test_server_name or f"{args.server_name}-lift-test"
    ospc_openrc = str(Path(args.ospc_openrc).resolve())
    flex_openrc = str(Path(args.flex_openrc).resolve())
    metadata_file = workdir / f"{snapshot_name}.metadata.json"

    log("=" * 60)
    log("OSPC -> FLEX image migrator")
    log("=" * 60)
    log(f"[INFO] server-name    : {args.server_name}")
    log(f"[INFO] snapshot-name  : {snapshot_name}")
    log(f"[INFO] flex-image     : {flex_image_name}")
    log(f"[INFO] boot-test-vm   : {args.boot_test_vm}")
    log(f"[INFO] repair-guest   : {args.repair_guest}")
    log(f"[INFO] remote-export  : {args.remote_export}")
    log(f"[INFO] workdir        : {workdir}")
    # Extract region and project from flex openrc for display
    _flex_region = "unknown"
    _flex_project = "unknown"
    try:
        for line in Path(args.flex_openrc).read_text(errors="ignore").splitlines():
            line = line.strip()
            if line.startswith("export OS_REGION_NAME="):
                _flex_region = line.split("=", 1)[1].strip().strip('"\'')
            elif line.startswith("export OS_PROJECT_ID=") or line.startswith("export OS_TENANT_ID="):
                _flex_project = line.split("=", 1)[1].strip().strip('"\'')
    except Exception:
        pass
    log(f"[INFO] flex-region    : {_flex_region}")
    log(f"[INFO] flex-project   : {_flex_project}")
    log("")

    # ── Stage 2: Create OSPC Snapshot ─────────────────────────────────────────
    # Production Mode (external host + SSH pipe) skips snapshot entirely —
    # /dev/vda is streamed directly from origin VM to external processing host.
    # Production Mode = jumphost + explicit origin-vm-ip (SSH pipe, no snapshot)
    # External Offload = jumphost + OSPC Glance snapshot download
    _explicit_origin_vm_ip = getattr(args, 'origin_vm_ip', None)
    _production_mode = args.remote_export and bool(_explicit_origin_vm_ip)
    _snapshot_preexisted = False  # set True when Stage 2 finds existing Glance snapshot
    if args.direct_export or _production_mode:
        if _production_mode:
            log(f"[INFO] ⚡ PRODUCTION MODE: skipping Stage 2 (OSPC snapshot) — /dev/vda will be SSH-piped from {_explicit_origin_vm_ip}")
        else:
            log("[INFO] --direct-export: skipping Stage 2 (OSPC snapshot) — root disk will be imaged directly on origin VM")
        image_id = "production-mode-stream"
    else:
        log("┌" + "─" * 54 + "┐")
        log("│ STAGE 2 ── Create OSPC Snapshot")
        if args.stop_before_snapshot:
            log("│ Stop VM → wait SHUTOFF → snapshot → (optionally restart)")
        else:
            log("│ Create snapshot of live OSPC VM → store in shared Glance")
        log("└" + "─" * 54 + "┘")

        if args.stop_before_snapshot:
            log(f"[INFO] Stopping source VM '{args.server_name}' before snapshot...")
            run(
                openstack_cmd(ospc_openrc, f"openstack server stop {shell_quote(args.server_name)}"),
                dry_run=args.dry_run,
            )
            log("[INFO] Polling until SHUTOFF (max 10 min)...")
            wait_for_server_status(
                openrc=ospc_openrc,
                server_ref=args.server_name,
                desired_status="SHUTOFF",
                poll_seconds=args.poll_seconds,
                timeout_seconds=600,
                dry_run=args.dry_run,
            )
            log("[OK] VM is SHUTOFF — taking consistent snapshot")

        # Check if the snapshot already exists in OSPC Glance — if so, skip creation entirely
        _existing_snap = None
        try:
            _existing_snap = json.loads(run(
                openstack_cmd(ospc_openrc, f"openstack image show {shell_quote(snapshot_name)} -f json"),
                dry_run=False,
            ))
        except Exception:
            pass

        if _existing_snap and _existing_snap.get("id"):
            image_id = _existing_snap["id"]
            _snapshot_preexisted = True
            log(f"[OK] Snapshot '{snapshot_name}' already exists in OSPC Glance (id={image_id}) — skipping Stage 2")
            if not args.dry_run:
                metadata_file.write_text(json.dumps(_existing_snap, indent=2), encoding="utf-8")
                log(f"[INFO] OSPC snapshot metadata written to {metadata_file}")
        else:
            log(f"[INFO] Waiting for server task_state to clear before snapshotting (max 10 min)...")
            for _wait_attempt in range(60):
                if args.dry_run:
                    break
                try:
                    sv = json.loads(run(
                        openstack_cmd(ospc_openrc, f"openstack server show {shell_quote(args.server_name)} -f json"),
                        dry_run=False,
                    ))
                    task_state = sv.get("OS-EXT-STS:task_state") or sv.get("task_state") or ""
                    vm_status  = sv.get("status", "")
                    if not task_state or task_state.lower() == "none":
                        log(f"[OK] Server task_state clear (status={vm_status}) — proceeding with snapshot")
                        break
                    log(f"[INFO] Server task_state={task_state} — waiting 10s...")
                except Exception:
                    pass
                import time as _time; _time.sleep(10)

            log(f"[INFO] Creating OSPC snapshot '{snapshot_name}'...")
            run(
                openstack_cmd(
                    ospc_openrc,
                    f"openstack server image create --name {shell_quote(snapshot_name)} {shell_quote(args.server_name)}"
                ),
                dry_run=args.dry_run,
            )

            image_payload = wait_for_image_status(
                openrc=ospc_openrc,
                image_ref=snapshot_name,
                poll_seconds=args.poll_seconds,
                timeout_seconds=args.timeout_seconds,
                dry_run=args.dry_run,
            )
            if not args.dry_run:
                metadata_file.write_text(json.dumps(image_payload, indent=2), encoding="utf-8")
                log(f"[INFO] OSPC snapshot metadata written to {metadata_file}")
            image_id = image_payload.get("id", snapshot_name)

        if args.stop_before_snapshot and args.restart_after_snapshot:
            log(f"[INFO] Restarting source VM '{args.server_name}' after snapshot...")
            run(
                openstack_cmd(ospc_openrc, f"openstack server start {shell_quote(args.server_name)}"),
                dry_run=args.dry_run,
            )
            log("[OK] VM restart issued — continuing migration while VM comes back up")

    if args.remote_export:
        # ── Discover origin VM IP (the VM being migrated — NOT the jumphost) ──
        # --origin-vm-ip = explicit origin VM IP (Production Mode)
        # If not provided, auto-discover via OSPC API (External Offload Mode)
        origin_vm_ip = getattr(args, 'origin_vm_ip', None) or None
        if origin_vm_ip:
            log(f"[INFO] Using provided origin VM IP: {origin_vm_ip}")
        if not origin_vm_ip and not args.dry_run and not _snapshot_preexisted:
            source_payload = wait_for_server_status(
                openrc=ospc_openrc,
                server_ref=args.server_name,
                desired_status="ACTIVE",
                poll_seconds=args.poll_seconds,
                timeout_seconds=args.timeout_seconds,
                dry_run=args.dry_run,
            )
            ips = parse_addresses_for_floating(source_payload.get("addresses", ""))
            if ips:
                origin_vm_ip = ips[0]
                log(f"[INFO] Discovered origin VM IP: {origin_vm_ip} (all IPs: {ips})")
                if origin_vm_ip.startswith("10.") or origin_vm_ip.startswith("192.168.") or origin_vm_ip.startswith("172."):
                    log(f"[WARN] Origin VM IP appears private — SSH from external host may fail if on different network.")
        elif _snapshot_preexisted:
            log(f"[INFO] Snapshot pre-existed — skipping origin VM IP discovery (Glance download mode)")

        if not origin_vm_ip and args.dry_run:
            origin_vm_ip = "<ORIGIN-VM-IP-AUTO-DISCOVERED>"
            log(f"[DRY-RUN] Origin VM IP not resolved (no OSPC call in dry-run) — using placeholder: {origin_vm_ip}")
        if not origin_vm_ip and not _snapshot_preexisted:
            raise RuntimeError("Cannot determine origin VM IP — pass --origin-vm-ip explicitly")
        if not args.ssh_key_path:
            raise RuntimeError("--ssh-key-path required for --remote-export")

        # ── Determine processing host — jumphost required ──
        external_host_ip = args.source_server_ip or None
        if not external_host_ip:
            raise RuntimeError(
                "--source-server-ip (jumphost IP) is required. "
                "Mode 1 (origin VM) is no longer supported — use a dedicated jumphost."
            )

        processing_host = external_host_ip
        # jh_user: SSH user for the jumphost — always ubuntu on our ospc-jumpHost VM
        jh_user = getattr(args, 'jumphost_user', None) or 'ubuntu'
        # use_mode3 = Production Mode: --origin-vm-ip was explicitly provided AND differs from jumphost
        use_mode3 = bool(getattr(args, 'origin_vm_ip', None) and getattr(args, 'origin_vm_ip') != external_host_ip)
        if use_mode3:
            log(f"[INFO] ⚡ PRODUCTION MODE — Jumphost: {processing_host} — will SSH-pipe /dev/vda from origin VM {origin_vm_ip}")
        else:
            log(f"[INFO] EXTERNAL OFFLOAD — Jumphost: {processing_host} — will download snapshot from OSPC Glance")

        log(f"[INFO] Waiting for SSH on processing host {processing_host}...")
        wait_for_ssh(
            key=args.ssh_key_path,
            user=jh_user,
            host=processing_host,
            port=args.ssh_port,
            dry_run=args.dry_run,
        )

        # ── Copy openrc files to processing host ──
        ospc_remote = "/tmp/ospc2flex_ospc.sh"
        flex_remote = "/tmp/ospc2flex_flex.sh"
        smart_copy(str(ospc_openrc), jh_user, processing_host, ospc_remote, key=args.ssh_key_path, port=args.ssh_port, dry_run=args.dry_run)
        smart_copy(str(flex_openrc), jh_user, processing_host, flex_remote, key=args.ssh_key_path, port=args.ssh_port, dry_run=args.dry_run)

        # ── Copy standalone offline repair script to processing host (Stage 4.6 fallback) ──
        _standalone_repair_local = Path(__file__).parent / "ospc2flex_offline_repair.sh"
        _standalone_repair_remote = "/tmp/ospc2flex_offline_repair.sh"
        if _standalone_repair_local.exists():
            log(f"[INFO] Copying standalone offline repair script to processing host...")
            smart_copy(str(_standalone_repair_local), jh_user, processing_host, _standalone_repair_remote,
                       key=args.ssh_key_path, port=args.ssh_port, dry_run=args.dry_run)
            if not args.dry_run:
                perm_repair = f"{ssh_base_cmd(args.ssh_key_path, jh_user, processing_host, args.ssh_port)} chmod +x {_standalone_repair_remote}"
                run(perm_repair, capture=False, dry_run=False, check=False, log_cmd=False)
            log(f"[OK] Standalone repair script staged at {_standalone_repair_remote} on processing host")
        else:
            log(f"[WARN] ospc2flex_offline_repair.sh not found locally — Stage 4.6 fallback will be unavailable")

        _win_repair_local = Path(__file__).resolve().parent / "ospc2flex_windows_repair.sh"
        _win_repair_remote = "/tmp/ospc2flex_windows_repair.sh"
        if _win_repair_local.exists():
            log("[INFO] Copying Windows VirtIO repair script to processing host...")
            smart_copy(
                str(_win_repair_local),
                jh_user,
                processing_host,
                _win_repair_remote,
                key=args.ssh_key_path,
                port=args.ssh_port,
                dry_run=args.dry_run,
            )
            if not args.dry_run:
                perm_win = f"{ssh_base_cmd(args.ssh_key_path, jh_user, processing_host, args.ssh_port)} chmod +x {_win_repair_remote}"
                run(perm_win, capture=False, dry_run=False, check=False, log_cmd=False)
            log(f"[OK] Windows repair script staged at {_win_repair_remote}")
        else:
            log("[WARN] ospc2flex_windows_repair.sh not found locally — Windows Stage 4.6 will be unavailable")

        _glance_bridge_local = Path(__file__).resolve().parent / "ospc2flex_glance_bridge.sh"
        _glance_bridge_remote = "/tmp/ospc2flex_glance_bridge.sh"
        if _glance_bridge_local.exists() and not getattr(args, "no_cloud_files_fallback", False):
            log("[INFO] Copying Glance/Cloud Files bridge helper to processing host...")
            smart_copy(
                str(_glance_bridge_local),
                jh_user,
                processing_host,
                _glance_bridge_remote,
                key=args.ssh_key_path,
                port=args.ssh_port,
                dry_run=args.dry_run,
            )
            if not args.dry_run:
                perm_bridge = f"{ssh_base_cmd(args.ssh_key_path, jh_user, processing_host, args.ssh_port)} chmod +x {_glance_bridge_remote}"
                run(perm_bridge, capture=False, dry_run=False, check=False, log_cmd=False)
            log(f"[OK] Glance/Cloud Files bridge staged at {_glance_bridge_remote}")
        elif getattr(args, "no_cloud_files_fallback", False):
            log("[INFO] Cloud Files fallback disabled by --no-cloud-files-fallback")
        else:
            log("[WARN] ospc2flex_glance_bridge.sh not found locally — Cloud Files fallback will be unavailable")

        # ── Mode 3: copy SSH key to external host so it can reach origin VM ──
        origin_vm_key_remote_path = ""
        origin_vm_password_remote_path = ""
        if use_mode3:
            origin_vm_auth_key = getattr(args, 'origin_vm_ssh_key_path', None) or args.ssh_key_path
            origin_vm_password = str(getattr(args, 'origin_vm_password', None) or '')
            if origin_vm_password:
                import tempfile
                origin_vm_password_remote_path = "/tmp/ospc2flex_origin_password.txt"
                log(f"[INFO] Copying origin VM password file to external host for password-based access...")
                with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False) as tf:
                    tf.write(origin_vm_password)
                    tmp_password_file = tf.name
                try:
                    smart_copy(tmp_password_file, jh_user, processing_host, origin_vm_password_remote_path,
                               key=args.ssh_key_path, port=args.ssh_port, dry_run=args.dry_run)
                finally:
                    try:
                        os.unlink(tmp_password_file)
                    except OSError:
                        pass
                if not args.dry_run:
                    perm_pass_cmd = f"{ssh_base_cmd(args.ssh_key_path, jh_user, processing_host, args.ssh_port)} chmod 600 {origin_vm_password_remote_path}"
                    run(perm_pass_cmd, capture=False, dry_run=False, check=False, log_cmd=False)
                log(f"[OK] Origin VM password file staged at {origin_vm_password_remote_path}")
            else:
                origin_vm_key_remote_path = "/tmp/ospc2flex_origin_key.pem"
                log(f"[INFO] Copying SSH key to external host for origin VM access...")
                smart_copy(str(origin_vm_auth_key), jh_user, processing_host, origin_vm_key_remote_path,
                           key=args.ssh_key_path, port=args.ssh_port, dry_run=args.dry_run)
                # Fix permissions on key after copy
                if not args.dry_run:
                    perm_cmd = f"{ssh_base_cmd(args.ssh_key_path, jh_user, processing_host, args.ssh_port)} chmod 600 {origin_vm_key_remote_path}"
                    run(perm_cmd, capture=False, dry_run=False, check=False, log_cmd=False)
                log(f"[OK] SSH key copied to external host at {origin_vm_key_remote_path}")

        # ── SSH into origin VM to detect OS (before stream) ──
        # In Mode 3 (production), --ssh-user is the origin VM user; use it as the starting probe user
        _explicit_origin_vm_user = getattr(args, 'origin_vm_user', None) or (args.ssh_user if use_mode3 else None)
        origin_vm_user = _explicit_origin_vm_user or 'ubuntu'
        origin_os_id = ""
        origin_os_ver = ""
        if not args.dry_run and origin_vm_ip and not origin_vm_ip.startswith("<"):
            log(f"[INFO] Detecting OS on origin VM {origin_vm_ip} via SSH...")
            # Auto-probe user list: if caller specified a user, try that first then fallback candidates
            _probe_users = [origin_vm_user] if _explicit_origin_vm_user else []
            for _u in ["ubuntu", "centos", "rocky", "almalinux", "debian", "ec2-user", "root"]:
                if _u not in _probe_users:
                    _probe_users.append(_u)
            _ssh_ok = False
            _origin_probe_password = str(getattr(args, 'origin_vm_password', None) or '')
            _origin_probe_key = getattr(args, 'origin_vm_ssh_key_path', None) or args.ssh_key_path
            for _try_user in _probe_users:
                try:
                    base_cmd = (
                        ssh_password_cmd(_origin_probe_password, _try_user, origin_vm_ip, args.ssh_port)
                        if _origin_probe_password else
                        ssh_base_cmd(_origin_probe_key, _try_user, origin_vm_ip, args.ssh_port)
                    )
                    detect_cmd = (
                        f"{base_cmd}"
                        f" \"grep -E '^(ID|VERSION_ID)=' /etc/os-release 2>/dev/null || true\""
                    )
                    os_out = run(detect_cmd, capture=True, check=False, dry_run=False)
                    _parsed_id = ""
                    _parsed_ver = ""
                    for line in os_out.splitlines():
                        line = line.strip()
                        if line.startswith("ID=") and not line.startswith("ID_LIKE="):
                            _parsed_id = line.split("=", 1)[1].strip('"\'').lower()
                        elif line.startswith("VERSION_ID="):
                            _parsed_ver = line.split("=", 1)[1].strip('"\'')
                    if _parsed_id:
                        origin_os_id = _parsed_id
                        origin_os_ver = _parsed_ver
                        origin_vm_user = _try_user
                        log(f"[OK] SSH user resolved: {_try_user} — Origin VM OS: {origin_os_id} {origin_os_ver}")
                        _ssh_ok = True
                        break
                    elif os_out.strip():
                        origin_vm_user = _try_user
                        log(f"[OK] SSH user resolved: {_try_user} — no OS parsed, will fallback to mounted image detection")
                        _ssh_ok = True
                        break
                except Exception:
                    pass
            if not _ssh_ok:
                log(f"[WARN] SSH probe failed for all users {_probe_users} on {origin_vm_ip} — will fallback to mounted image detection")
        else:
            log(f"[DRY-RUN] Skipping live OS detection — will inject placeholder")

        repair_os_type = infer_offline_os_type(
            name=snapshot_name,
            os_id=origin_os_id,
            os_ver=origin_os_ver,
        )
        log(
            f"[INFO] Offline repair OS profile (VM remote export, matches image pipeline): "
            f"{repair_os_type or '(auto-detect on jumphost)'}"
        )

        # Windows snapshots download via Glance (openstack token issue path) — no auto-switch needed.

        # ── Generate and copy the remote export script ──
        script_content = build_remote_export_script(
            snap_name=snapshot_name,
            snap_id=image_id,
            flex_image_name=flex_image_name,
            ospc_openrc_path=ospc_remote,
            flex_openrc_path=flex_remote,
            origin_image_dir=args.origin_image_dir,
            target_format=args.target_format,
            container_format=args.container_format,
            visibility=args.visibility,
            retries=args.export_retries,
            retry_wait_seconds=args.export_retry_wait,
            keep_export=args.keep_export,
            direct_export=(not use_mode3 and args.direct_export),
            origin_vm_ip=origin_vm_ip if use_mode3 else "",
            origin_vm_user=origin_vm_user,
            origin_vm_key_remote_path=origin_vm_key_remote_path,
            origin_vm_password_remote_path=origin_vm_password_remote_path,
            origin_os_id=origin_os_id,
            origin_os_ver=origin_os_ver,
            offline_repair_method=getattr(args, 'offline_repair_method', 'custom_os') or 'custom_os',
            repair_os_type=repair_os_type,
            cloud_files_fallback=not getattr(args, "no_cloud_files_fallback", False),
            prefer_cloud_files_download=not getattr(args, "no_prefer_cloud_files_download", False),
            ospc_cloud_files_container=getattr(args, "ospc_cloud_files_container", "ospc2flex-export") or "ospc2flex-export",
            flex_cloud_files_container=getattr(args, "flex_cloud_files_container", "ospc2flex-staging") or "ospc2flex-staging",
        )

        # Use unique filename per VM to avoid race condition when parallel jobs share workdir
        ts = int(time.time())
        safe_vm_name = args.server_name.replace(" ", "_").replace("/", "_")
        local_script = workdir / f"remote_export_{safe_vm_name}_{ts}.sh"
        local_script.write_text(script_content, encoding="utf-8")

        remote_script = f"ospc2flex_remote_export_{safe_vm_name}_{ts}.sh"
        smart_copy(str(local_script), jh_user, processing_host, remote_script, key=args.ssh_key_path, port=args.ssh_port, dry_run=args.dry_run)

        ssh_cmd = f"{ssh_base_cmd(args.ssh_key_path, jh_user, processing_host, args.ssh_port)} bash {remote_script}"
        run(ssh_cmd, capture=False, dry_run=args.dry_run)

        log("[OK] STAGE 5 — Upload to FLEX Glance completed on processing host")



    # ── Stage 6: Boot FLEX VM ──────────────────────────────────────────────
    if args.boot_test_vm:
        log("┌" + "─" * 54 + "┐")
        log("│ STAGE 6 ── Boot FLEX VM")
        log("│ Create VM from uploaded image → assign floating IP")
        log("└" + "─" * 54 + "┘")
        log(f"[INFO] Booting test VM '{test_server_name}' on FLEX from image '{flex_image_name}'...")
        if not args.flex_flavor:
            log("[WARN] --flex-flavor not set — skipping boot test VM")
            args.boot_test_vm = False
        elif not args.flex_network_id:
            log("[WARN] --flex-network-id not set — skipping boot test VM")
            args.boot_test_vm = False

        if not args.boot_test_vm:
            log("[INFO] Migration complete!")
            return

        if args.boot_test_vm:
            # Idempotency check: see if ANY server already exists booting from this newly uploaded image
            # This prevents duplicate VMs if multiple scripts/methods trigger boot tests for the same image
            check_cmd = f"openstack server list --image {shell_quote(flex_image_name)} -f value -c ID"
            existing_id = run(openstack_cmd(flex_openrc, check_cmd), capture=True, dry_run=args.dry_run, check=False)
            if existing_id and existing_id.strip():
                first_id = existing_id.strip().splitlines()[0]
                log(f"[WARN] A server booted from image '{flex_image_name}' already exists (ID: {first_id}).")
                log(f"[SKIP] Skipping duplicate test VM creation.")
                log("[INFO] Migration complete!")
                return

            src_vcpus = 0
            src_ram_mb = 0
            src_disk_gb = 0
            src_show = run(
                openstack_cmd(ospc_openrc, f"openstack server show {shell_quote(args.server_name)} -f json"),
                capture=True, dry_run=args.dry_run, check=False, log_cmd=False
            )
            try:
                src_payload = json.loads(src_show or "{}")
            except Exception:
                src_payload = {}
            src_flavor = src_payload.get("flavor") if isinstance(src_payload, dict) else {}
            src_flavor_id = ""
            if isinstance(src_flavor, dict):
                src_flavor_id = str(src_flavor.get("id") or "").strip()
            if src_flavor_id:
                src_flv_show = run(
                    openstack_cmd(ospc_openrc, f"openstack flavor show {shell_quote(src_flavor_id)} -f json"),
                    capture=True, dry_run=args.dry_run, check=False, log_cmd=False
                )
                try:
                    src_flv = json.loads(src_flv_show or "{}")
                except Exception:
                    src_flv = {}
                src_vcpus = _to_int(src_flv.get("vcpus"))
                src_ram_mb = _to_int(src_flv.get("ram"))
                src_disk_gb = _to_int(src_flv.get("disk"))
                if src_vcpus and src_ram_mb:
                    log(
                        f"[INFO] Source flavor shape: id={src_flavor_id} "
                        f"vcpu={src_vcpus} ram={src_ram_mb} disk={src_disk_gb}"
                    )
            resolved_flavor = resolve_target_flavor_with_fallback(
                flex_openrc=flex_openrc,
                requested_flavor=args.flex_flavor,
                source_vcpus=src_vcpus,
                source_ram_mb=src_ram_mb,
                source_disk_gb=src_disk_gb,
                dry_run=args.dry_run,
            )
            resolved_network = resolve_target_network_with_fallback(
                flex_openrc=flex_openrc,
                requested_network=args.flex_network_id,
                dry_run=args.dry_run,
            )
            resolved_keypair = resolve_target_keypair_with_fallback(
                flex_openrc=flex_openrc,
                requested_keypair=args.flex_key_name or "",
                dry_run=args.dry_run,
            )
            boot_cmd = (
                f"openstack server create"
                f" {shell_quote(test_server_name)}"
                f" --image {shell_quote(flex_image_name)}"
                f" --flavor {shell_quote(resolved_flavor)}"
                f" --network {shell_quote(resolved_network)}"
            )

        if resolved_keypair:
            boot_cmd += f" --key-name {shell_quote(resolved_keypair)}"
        if args.flex_security_group:
            boot_cmd += f" --security-group {shell_quote(args.flex_security_group)}"
        boot_cmd += " --config-drive true"  # Rackspace FLEX: ensures ConfigDrive for cloud-init on first boot
        boot_cmd += " -f json"

        boot_resp = run(openstack_cmd(flex_openrc, boot_cmd), dry_run=args.dry_run)
        try:
            server_id = json.loads(boot_resp).get("id", test_server_name)
        except Exception:
            server_id = test_server_name
        log(f"[INFO] Test VM created: {server_id}")

        server_payload = wait_for_server_status(
            openrc=flex_openrc,
            server_ref=server_id,
            desired_status="ACTIVE",
            timeout_seconds=600,
            dry_run=args.dry_run,
        )

        test_ip = args.test_server_ip

        if args.auto_floating_ip and not test_ip:
            log("[INFO] Allocating floating IP...")
            fip_resp = run(openstack_cmd(
                flex_openrc,
                f"openstack floating ip create {shell_quote(args.flex_external_network)} -f json"
            ), dry_run=args.dry_run)
            try:
                fip_payload = json.loads(fip_resp or "{}")
                fip = str(fip_payload.get("floating_ip_address") or "").strip()
                fip_id = str(fip_payload.get("id") or "").strip()
                if fip_id:
                    port_id = run(
                        openstack_cmd(
                            flex_openrc,
                            f"openstack port list --server {shell_quote(server_id)} -f value -c ID -c Status | awk '$2==\"ACTIVE\"{{print $1; exit}}'"
                        ),
                        capture=True, check=False, dry_run=args.dry_run, log_cmd=False,
                    ).strip()
                    if not port_id:
                        port_id = run(
                            openstack_cmd(
                                flex_openrc,
                                f"openstack port list --server {shell_quote(server_id)} -f value -c ID | head -1"
                            ),
                            capture=True, check=False, dry_run=args.dry_run, log_cmd=False,
                        ).strip()
                    if port_id:
                        run(openstack_cmd(
                            flex_openrc,
                            f"openstack floating ip set --port {shell_quote(port_id)} {shell_quote(fip_id)}"
                        ), dry_run=args.dry_run)
                        test_ip = fip
                        log(f"[OK] Floating IP: {test_ip}")
            except Exception as e:
                log(f"[WARN] Floating IP allocation failed: {e}")

        if not test_ip:
            ips = parse_addresses_for_floating(server_payload.get("addresses", ""))
            if ips:
                test_ip = ips[0]

        # Stage 7 — Post-boot diagnostics
        _is_windows = repair_os_type == "windows" if 'repair_os_type' in dir() else False
        _win_password = getattr(args, 'windows_admin_password', None) or str(getattr(args, 'origin_vm_password', None) or '')

        if test_ip and _is_windows:
            # ── Stage 7 Windows: SSH via OpenSSH Server (auto-enabled by RunOnce) ──
            log("┌" + "─" * 54 + "┐")
            log("│ STAGE 7 ── Windows Post-Boot Verification")
            log("│ Wait for RunOnce → SSH as Administrator → read verification report")
            log("└" + "─" * 54 + "┘")

            if not _win_password:
                log("[WARN] No --windows-admin-password provided. Skipping automated verification.")
                log("[INFO] Use noVNC console: openstack console url show " + shell_quote(test_server_name) + " --novnc")
            else:
                log(f"[INFO] Waiting for Windows VM to boot + RunOnce to complete (~3-5 min)...")
                log(f"[INFO] Target: Administrator@{test_ip}")

                # Wait for SSH port 22 (OpenSSH enabled by RunOnce) or WinRM port 5985
                _win_ssh_ready = False
                _win_retries = 40
                _win_wait = 15
                for _attempt in range(1, _win_retries + 1):
                    if args.dry_run:
                        _win_ssh_ready = True
                        break
                    log(f"[INFO] SSH probe {_attempt}/{_win_retries} → Administrator@{test_ip}:22")
                    _probe = subprocess.run(
                        f"sshpass -p {shell_quote(_win_password)} ssh"
                        f" -o PreferredAuthentications=password,keyboard-interactive"
                        f" -o PubkeyAuthentication=no"
                        f" -o StrictHostKeyChecking=accept-new"
                        f" -o ConnectTimeout=10"
                        f" Administrator@{test_ip} echo ok",
                        shell=True, capture_output=True, text=True
                    )
                    if _probe.returncode == 0:
                        log(f"[OK] SSH reachable: Administrator@{test_ip}")
                        _win_ssh_ready = True
                        break
                    if _attempt < _win_retries:
                        log(f"  Not ready (rc={_probe.returncode}), waiting {_win_wait}s...")
                        time.sleep(_win_wait)

                if _win_ssh_ready:
                    _win_ssh_base = (
                        f"sshpass -p {shell_quote(_win_password)} ssh"
                        f" -o PreferredAuthentications=password,keyboard-interactive"
                        f" -o PubkeyAuthentication=no"
                        f" -o StrictHostKeyChecking=accept-new"
                        f" -o ConnectTimeout=30"
                        f" -o ServerAliveInterval=30"
                        f" -o ServerAliveCountMax=10"
                        f" Administrator@{test_ip}"
                    )

                    # Generate report filename: <servername>_windows_report.txt
                    _safe_name = args.server_name.replace(" ", "_").replace("/", "_")
                    _remote_report = f"C:\\{_safe_name}_windows_report.txt"
                    _local_report = str(workdir / f"{_safe_name}_windows_report.txt")

                    # Comprehensive PowerShell audit script
                    _audit_ps = r'''
$reportFile = "''' + _remote_report.replace("\\", "\\\\") + r'''"
$r = @()
$r += "================================================================"
$r += " OSPC to FLEX — Windows Post-Migration Report"
$r += " Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$r += " Server: $env:COMPUTERNAME"
$r += "================================================================"
$r += ""

# ── System Info ──
$r += "──── SYSTEM INFO ────────────────────────────────────────────────"
$os = Get-CimInstance Win32_OperatingSystem -EA SilentlyContinue
$cs = Get-CimInstance Win32_ComputerSystem -EA SilentlyContinue
$r += "  OS Name        : $($os.Caption)"
$r += "  OS Version     : $($os.Version) Build $($os.BuildNumber)"
$r += "  Architecture   : $($os.OSArchitecture)"
$r += "  Install Date   : $($os.InstallDate)"
$r += "  Last Boot      : $($os.LastBootUpTime)"
$r += "  Computer Name  : $($cs.Name)"
$r += "  Domain         : $($cs.Domain)"
$r += "  Total RAM      : $([math]::Round($cs.TotalPhysicalMemory/1GB,1)) GB"
$r += "  CPU            : $((Get-CimInstance Win32_Processor -EA SilentlyContinue).Name)"
$r += "  CPU Cores      : $($cs.NumberOfLogicalProcessors)"
$r += ""

# ── Boot Configuration ──
$r += "──── BOOT CONFIGURATION ─────────────────────────────────────────"
$bcd = bcdedit /enum all 2>&1 | Out-String
$r += $bcd
$r += ""

# ── Disk & Partitions ──
$r += "──── DISKS ──────────────────────────────────────────────────────"
Get-Disk -EA SilentlyContinue | ForEach-Object {
    $r += "  Disk #$($_.Number): $($_.FriendlyName) | $([math]::Round($_.Size/1GB,1))GB | Style=$($_.PartitionStyle) | Status=$($_.OperationalStatus)"
}
$r += ""
$r += "──── PARTITIONS ─────────────────────────────────────────────────"
Get-Partition -EA SilentlyContinue | ForEach-Object {
    $r += "  Disk$($_.DiskNumber) Part$($_.PartitionNumber): $($_.DriveLetter) | $([math]::Round($_.Size/1GB,1))GB | Type=$($_.Type)"
}
$r += ""
$r += "──── VOLUMES ────────────────────────────────────────────────────"
Get-Volume -EA SilentlyContinue | Where-Object { $_.DriveLetter } | ForEach-Object {
    $r += "  $($_.DriveLetter): $([math]::Round($_.Size/1GB,1))GB total | $([math]::Round($_.SizeRemaining/1GB,1))GB free | FS=$($_.FileSystemType) | Label=$($_.FileSystemLabel)"
}
$r += ""

# ── Storage Drivers (VirtIO) ──
$r += "──── STORAGE DRIVERS (VirtIO) ───────────────────────────────────"
foreach ($svc in @("viostor","vioscsi","disk","volmgr","partmgr","volsnap","mountmgr")) {
    $s = Get-Service $svc -EA SilentlyContinue
    if ($s) { $r += "  $svc : $($s.Status) (StartType=$($s.StartType))" }
    else    { $r += "  $svc : NOT FOUND" }
}
$r += ""

# ── Xen Drivers (should be disabled) ──
$r += "──── XEN DRIVERS (should be disabled) ───────────────────────────"
foreach ($svc in @("xenvbd","xennet","xenvif","xeniface","xenbus")) {
    $s = Get-Service $svc -EA SilentlyContinue
    if ($s) { $r += "  $svc : $($s.Status) (StartType=$($s.StartType))" }
    else    { $r += "  $svc : not present (OK)" }
}
$r += ""

# ── Network Adapters ──
$r += "──── NETWORK ADAPTERS ───────────────────────────────────────────"
Get-NetAdapter -EA SilentlyContinue | ForEach-Object {
    $r += "  $($_.Name): $($_.InterfaceDescription) | Status=$($_.Status) | Speed=$($_.LinkSpeed) | MAC=$($_.MacAddress)"
}
$r += ""

# ── IP Configuration ──
$r += "──── IP CONFIGURATION ───────────────────────────────────────────"
$ipconfig = ipconfig /all 2>&1 | Out-String
$r += $ipconfig

# ── DHCP Status ──
$r += "──── DHCP STATUS ────────────────────────────────────────────────"
Get-NetIPInterface -AddressFamily IPv4 -EA SilentlyContinue | Where-Object { $_.InterfaceAlias -notmatch 'Loopback' } | ForEach-Object {
    $r += "  $($_.InterfaceAlias): DHCP=$($_.Dhcp)"
}
$r += ""

# ── Ghost/Unknown Network Devices ──
$r += "──── GHOST NETWORK DEVICES ──────────────────────────────────────"
$ghosts = Get-PnpDevice -Class Net -Status Unknown -EA SilentlyContinue
if ($ghosts) { $ghosts | ForEach-Object { $r += "  GHOST: $($_.FriendlyName) ($($_.InstanceId))" } }
else { $r += "  None (clean)" }
$r += ""

# ── DNS ──
$r += "──── DNS CONFIGURATION ──────────────────────────────────────────"
Get-DnsClientServerAddress -AddressFamily IPv4 -EA SilentlyContinue | ForEach-Object {
    $r += "  $($_.InterfaceAlias): $($_.ServerAddresses -join ', ')"
}
$r += ""

# ── Default Gateway / Routes ──
$r += "──── ROUTING TABLE ──────────────────────────────────────────────"
$routes = route print 2>&1 | Out-String
$r += $routes

# ── Firewall ──
$r += "──── FIREWALL PROFILE ───────────────────────────────────────────"
Get-NetFirewallProfile -EA SilentlyContinue | ForEach-Object {
    $r += "  $($_.Name): Enabled=$($_.Enabled) DefaultInbound=$($_.DefaultInboundAction)"
}
$r += ""
$r += "──── FIREWALL RULES (ospc2flex + RDP + SSH) ─────────────────────"
Get-NetFirewallRule -EA SilentlyContinue | Where-Object { $_.DisplayName -match 'ospc2flex|Remote Desktop|OpenSSH|sshd' -and $_.Enabled -eq 'True' } | ForEach-Object {
    $r += "  $($_.DisplayName): Direction=$($_.Direction) Action=$($_.Action) Profile=$($_.Profile)"
}
$r += ""

# ── Users & Groups ──
$r += "──── LOCAL USERS ────────────────────────────────────────────────"
Get-LocalUser -EA SilentlyContinue | ForEach-Object {
    $r += "  $($_.Name): Enabled=$($_.Enabled) LastLogon=$($_.LastLogon) PasswordExpires=$($_.PasswordExpires)"
}
$r += ""
$r += "──── LOCAL GROUPS (Administrators) ──────────────────────────────"
Get-LocalGroupMember -Group "Administrators" -EA SilentlyContinue | ForEach-Object {
    $r += "  $($_.Name) ($($_.ObjectClass))"
}
$r += ""

# ── Services (Running) ──
$r += "──── RUNNING SERVICES ───────────────────────────────────────────"
Get-Service -EA SilentlyContinue | Where-Object { $_.Status -eq 'Running' } | Sort-Object Name | ForEach-Object {
    $r += "  $($_.Name): $($_.DisplayName)"
}
$r += ""

# ── RDP Status ──
$r += "──── RDP STATUS ─────────────────────────────────────────────────"
$rdpDeny = (Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -EA SilentlyContinue).fDenyTSConnections
$r += "  fDenyTSConnections: $rdpDeny (0=enabled, 1=disabled)"
$rdpSvc = Get-Service TermService -EA SilentlyContinue
$r += "  TermService: $($rdpSvc.Status)"
$r += ""

# ── SSH / WinRM ──
$r += "──── REMOTE ACCESS SERVICES ─────────────────────────────────────"
foreach ($svc in @("sshd","WinRM")) {
    $s = Get-Service $svc -EA SilentlyContinue
    if ($s) { $r += "  $svc : $($s.Status) (StartType=$($s.StartType))" }
    else    { $r += "  $svc : not installed" }
}
$r += ""

# ── Installed Programs (top 30) ──
$r += "──── INSTALLED PROGRAMS (selection) ─────────────────────────────"
Get-CimInstance Win32_Product -EA SilentlyContinue | Select-Object -First 30 | ForEach-Object {
    $r += "  $($_.Name) v$($_.Version)"
}
$r += ""

# ── Windows Features ──
$r += "──── WINDOWS FEATURES (installed) ───────────────────────────────"
Get-WindowsFeature -EA SilentlyContinue | Where-Object { $_.Installed } | ForEach-Object {
    $r += "  [$($_.InstallState)] $($_.Name): $($_.DisplayName)"
}
$r += ""

# ── Event Log (last 10 System errors) ──
$r += "──── RECENT SYSTEM ERRORS (last 10) ─────────────────────────────"
Get-EventLog -LogName System -EntryType Error -Newest 10 -EA SilentlyContinue | ForEach-Object {
    $r += "  [$($_.TimeGenerated)] $($_.Source): $($_.Message.Substring(0, [Math]::Min(120, $_.Message.Length)))"
}
$r += ""

# ── First-boot repair log ──
$r += "──── OSPC2FLEX FIRST-BOOT LOG ───────────────────────────────────"
if (Test-Path C:\ospc2flex_firstboot.log) {
    Get-Content C:\ospc2flex_firstboot.log | Select-String "ospc2flex" | ForEach-Object { $r += "  $_" }
} else { $r += "  (not found)" }
$r += ""

$r += "================================================================"
$r += " END OF REPORT"
$r += "================================================================"

$r | Out-File -FilePath $reportFile -Encoding UTF8
$r | ForEach-Object { Write-Host $_ }
'''

                    log(f"[INFO] Running comprehensive Windows audit → {_remote_report}")
                    _audit_cmd = f'{_win_ssh_base} "powershell.exe -ExecutionPolicy Bypass -Command {shlex.quote(_audit_ps)}"'
                    _ar = subprocess.run(_audit_cmd, shell=True, capture_output=True, text=True, errors="replace", timeout=300)
                    _audit_out = (_ar.stdout or "").strip()

                    if _audit_out:
                        log(f"[REPORT]\n{_audit_out}")
                        # Save locally
                        Path(_local_report).write_text(_audit_out, encoding="utf-8")
                        log(f"[OK] Report saved locally: {_local_report}")
                        log(f"[OK] Report saved on VM:   {_remote_report}")
                    else:
                        _audit_err = (_ar.stderr or "").strip()
                        log(f"[WARN] Audit returned no output. stderr: {_audit_err}")

                    log("│ STAGE 7 ── Windows post-boot audit complete")
                else:
                    log("[WARN] SSH not reachable after all retries.")
                    log("[INFO] Windows VM may still be booting or RunOnce hasn't completed.")
                    log("[INFO] Manual access: openstack console url show " + shell_quote(test_server_name) + " --novnc")

        elif test_ip and args.ssh_key_path and not _is_windows:
            # ── Stage 7 Linux: SSH diagnostics ──
            log("┌" + "─" * 54 + "┐")
            log("│ STAGE 7 ── Linux VM Diagnostics")
            log("│ SSH into FLEX VM → dump network/disk/OS state")
            log("└" + "─" * 54 + "┘")
            wait_for_ssh(
                key=args.ssh_key_path,
                user=args.ssh_user,
                host=test_ip,
                port=args.ssh_port,
                retries=30,
                wait=20,
                dry_run=args.dry_run,
            )
            diag_cmd = (
                "echo '--- ip link ---'; ip link show; "
                "echo '--- ip route ---'; ip route show; "
                "echo '--- fstab ---'; cat /etc/fstab; "
                "echo '--- netplan ---'; ls /etc/netplan/ 2>/dev/null && cat /etc/netplan/*.yaml 2>/dev/null || echo 'no netplan'; "
                "echo '--- lsblk ---'; lsblk -f; "
                "echo '--- cmdline ---'; cat /proc/cmdline; "
                "echo '--- cloud-init status ---'; sudo cloud-init status --long 2>/dev/null || true; "
                "echo '--- cloud-init datasource ---'; sudo cloud-init query ds 2>/dev/null || true; "
                "echo '--- cloud-init log ---'; sudo journalctl -b -u cloud-init --no-pager 2>/dev/null | tail -50 || true; "
                "echo '--- cloud-init cfg datasource ---'; cat /etc/cloud/cloud.cfg 2>/dev/null | grep -A5 datasource || true; "
                "echo '--- os-release ---'; cat /etc/os-release | grep -E 'NAME|VERSION'"
            )
            ssh_cmd = (
                f"ssh -i {args.ssh_key_path} -o BatchMode=yes -o StrictHostKeyChecking=accept-new "
                f"-o ConnectTimeout=30 -o ServerAliveInterval=30 -o ServerAliveCountMax=10 "
                f"-p {args.ssh_port} {args.ssh_user}@{test_ip} {shlex.quote(diag_cmd)}"
            )
            log(f"[RUN] {ssh_cmd}")
            import subprocess as _sp
            r = _sp.run(ssh_cmd, shell=True, capture_output=True, text=True, errors="replace")
            output = (r.stdout or "") + (r.stderr or "")
            log(f"[DIAG]\n{output.strip()}")
            log("│ STAGE 7 ── Linux diagnostics complete")

    log("[INFO] Migration complete!")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as exc:
        log(f"[FATAL] {exc}")
        sys.exit(1)
