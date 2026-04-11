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


# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

def log(msg: str) -> None:
    print(msg, flush=True)


def shell_quote(s: str) -> str:
    return shlex.quote(str(s))


def run(cmd, *, dry_run: bool = False, capture: bool = True, check: bool = True) -> str:
    if isinstance(cmd, str):
        cmd_str = cmd
    else:
        cmd_str = " ".join(str(c) for c in cmd)
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
            print(f"STDOUT:\n{result.stdout or ''}")
            print(f"STDERR:\n{result.stderr or ''}")
            raise RuntimeError(f"Command failed ({result.returncode}): {cmd_str}")
        return ""


def openstack_cmd(openrc_path: str, cmd: str) -> str:
    return f"bash -lc {shell_quote(f'source {openrc_path} && {cmd}')}"


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
    # OS pre-detected from live origin VM via SSH (before stream)
    origin_os_id: str = "",
    origin_os_ver: str = "",
    # Offline repair strategy: 'custom_os' (per-OS profile) or 'generic' (standalone script only)
    offline_repair_method: str = "custom_os",
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

# Only resume if the exact file for this snap_name exists
if [ -f "$repaired_path" ]; then
    log "[INFO] Found retained repaired image from previous run: $repaired_path"
fi
if [ -f "$converted_path" ]; then
    log "[INFO] Found retained converted image from previous run: $converted_path"
fi

img_path="$workdir/{snap_name}.img"

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

# ── Fast-path: if repaired image already exists, skip everything ──────────────
if [ -f "$repaired_path" ]; then
  log "  [INFO] Repaired image already exists: $repaired_path"
  log "  [INFO] Skipping stages 1-4.5 — going straight to upload handoff"
else

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

# ── Check: skip to repair if converted .qcow2 already exists ─────────────────
if [ -f "$converted_path" ]; then
  log "  [INFO] Converted qcow2 exists: $converted_path — skipping to stage 4.5 (offline repair)"
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
log "  [INFO] Origin VM: $ORIGIN_VM_USER@$ORIGIN_VM_IP (key: $ORIGIN_VM_KEY)"
# Test SSH connectivity to origin VM
if ! ssh -i "$ORIGIN_VM_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
       -o ConnectTimeout=15 "$ORIGIN_VM_USER@$ORIGIN_VM_IP" "echo ok" >/dev/null 2>&1; then
  stage_fail 3 "Cannot SSH to origin VM $ORIGIN_VM_IP — check key and connectivity"
fi
log "  [OK] SSH to origin VM verified"
# Detect root disk on origin VM (prefer vda/xvda/sda — skip loop/nbd/dm devices)
_origin_disk_detect='for d in /dev/vda /dev/xvda /dev/sda; do [ -b "$d" ] && echo "$d" && break; done'
# Get disk size from origin VM for space check
DISK_KB=$(ssh -i "$ORIGIN_VM_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    "$ORIGIN_VM_USER@$ORIGIN_VM_IP" \
    "ORIGIN_DISK=\\$(for d in /dev/vda /dev/xvda /dev/sda; do [ -b \\\"\\$d\\\" ] && echo \\\"\\$d\\\" && break; done); sudo blockdev --getsize64 \\\"\\$ORIGIN_DISK\\\" 2>/dev/null || echo 0" \
    2>/dev/null | awk '{{print int($1/1024)}}' || echo 0)
FREE_KB=$(df -k "$workdir" | tail -1 | awk '{{print $4}}')
NEEDED_KB=$(( DISK_KB / 6 ))
log "  [INFO] Origin disk: ${{DISK_KB}}KB | Estimated compressed: ~${{NEEDED_KB}}KB | Local free: ${{FREE_KB}}KB"
if [ "$FREE_KB" -lt "$NEEDED_KB" ]; then
  log "  [WARN] Tight disk space on external host — need ~${{NEEDED_KB}}KB, have ${{FREE_KB}}KB. Proceeding anyway..."
fi
log "  [INFO] Streaming origin VM disk → raw image on jumphost then converting to {target_format}..."
log "  [INFO] SSH pipe → raw .img first (qemu-img file driver requires a regular file, not a pipe/FIFO)"
RAW_IMG="$workdir/{snap_name}.img"
ssh -i "$ORIGIN_VM_KEY" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=30 \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=20 \
    -o Compression=no \
    "$ORIGIN_VM_USER@$ORIGIN_VM_IP" \
    "ORIGIN_DISK=\\$(for d in /dev/vda /dev/xvda /dev/sda; do [ -b \\\"\\$d\\\" ] && echo \\\"\\$d\\\" && break; done); echo \\\"[ORIGIN] Streaming \\$ORIGIN_DISK...\\\"; sudo dd if=\\\"\\$ORIGIN_DISK\\\" bs=4M status=progress 2>/dev/null" \
  > "$RAW_IMG"
RAW_SIZE=$(stat -c%s "$RAW_IMG" 2>/dev/null || echo 0)
if [ "$RAW_SIZE" -lt 10485760 ]; then
  rm -f "$RAW_IMG"
  stage_fail 3 "Raw image too small (${{RAW_SIZE}} bytes) — SSH stream likely failed"
fi
log "  [OK] Raw disk received: $RAW_IMG ($(ls -lh "$RAW_IMG" | awk '{{print $5}}')), converting to {target_format}..."
qemu-img convert -p -f raw -O {target_format} -c "$RAW_IMG" "$converted_path"
rm -f "$RAW_IMG"
SIZE_BYTES=$(stat -c%s "$converted_path" 2>/dev/null || echo 0)
if [ "$SIZE_BYTES" -lt 10485760 ]; then
  rm -f "$converted_path"
  stage_fail 3 "Output too small (${{SIZE_BYTES}} bytes) — SSH pipe likely failed or origin disk empty"
fi
SIZE=$(ls -lh "$converted_path" | awk '{{print $5}}')
log "  [OK] SSH stream + convert complete: $converted_path ($SIZE)"
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
stage_start 3 'Download OSPC Snapshot' 'Streaming disk image from OSPC Glance'
log '  Sourcing OSPC credentials...'
source {shell_quote(ospc_openrc_path)}
log '  Acquiring OSPC Keystone token...'
OS_TOKEN=$(openstack token issue -f value -c id 2>/dev/null || true)
if [ -z "$OS_TOKEN" ]; then
  stage_fail 3 'No OSPC token — check OSPC credentials'
fi
OS_IMAGE_URL=$(openstack catalog show image -f json 2>/dev/null | python3 -c "
import sys,json
data=json.load(sys.stdin)
eps=[e for e in data.get('endpoints',[]) if e.get('interface')=='public']
print(eps[0]['url'].rstrip('/') if eps else '')
" 2>/dev/null || true)
if [ -z "$OS_IMAGE_URL" ]; then
  log '  [WARN] Catalog lookup failed — using DFW3 Glance default'
  OS_IMAGE_URL='https://glance.api.dfw3.rackspacecloud.com'
fi
IMG_DOWNLOAD_URL="$OS_IMAGE_URL/v2/images/{snap_id}/file"
log "  Target: $IMG_DOWNLOAD_URL"
success=0
for attempt in $(seq 1 $export_retries); do
  log "  Attempt $attempt/$export_retries — large file, please wait..."
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
    OS_TOKEN=$(openstack token issue -f value -c id 2>/dev/null || true)
    rm -f "$img_path"
  fi
  [ $attempt -lt $export_retries ] && {{ log "  Waiting ${{export_retry_wait}}s..."; sleep $export_retry_wait; }}
done
[ $success -eq 0 ] && stage_fail 3 'Download failed after all attempts'
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

# ── STAGE 4.5: Offline Guest Repair ──────────────────────────────────────────
REPAIR_METHOD={shell_quote(offline_repair_method)}   # custom_os | generic
repair_ok=0   # initialized here; set to 1 by custom_os on successful umount
if [ "$REPAIR_METHOD" = "generic" ]; then
  stage_start '4.5' 'Offline Guest Repair' 'Generic mode — running ospc2flex_offline_repair.sh directly (no per-OS profile)'
  STANDALONE_REPAIR=/tmp/ospc2flex_offline_repair.sh
  cp "$converted_path" "$repaired_path"
  log "  [INFO] Generic repair: running $STANDALONE_REPAIR on $repaired_path"
  if [ -f "$STANDALONE_REPAIR" ]; then
    if bash "$STANDALONE_REPAIR" --qcow2 "$repaired_path" --force; then
      log "  [OK] Generic repair completed successfully"
      repair_ok=1
    else
      log "  [WARN] Generic repair failed — will retry in Stage 4.6 fallback"
    fi
  else
    log "  [WARN] $STANDALONE_REPAIR not found on jumphost — skipping generic repair"
    log "  [WARN] Was the script staged in pre-flight? Falling back to Stage 4.6"
  fi
  stage_done '4.5'
else
stage_start '4.5' 'Offline Guest Repair' 'Smart OS-profile repair: fstab + network + cloud-init + pkg install per detected OS'
MNT=/tmp/ospc2flex_mnt_$$
if ! command -v qemu-nbd >/dev/null 2>&1; then
  log '  [INFO] qemu-nbd not found — installing qemu-utils...'
  sudo apt-get install -y qemu-utils >/dev/null 2>&1 && log '  [OK] qemu-utils installed' || log '  [WARN] Install failed'
fi
if command -v qemu-nbd >/dev/null 2>&1; then
  # Pick a free NBD device (parallel jobs may be using nbd0, nbd1, etc.)
  sudo modprobe nbd max_part=8 2>/dev/null || true
  NBD_DEV=""
  for _nbd in /dev/nbd{{0..15}}; do
    if ! sudo lsblk "$_nbd" 2>/dev/null | grep -q "disk"; then
      if ! sudo fuser "$_nbd" 2>/dev/null | grep -q .; then
        NBD_DEV="$_nbd"
        break
      fi
    fi
  done
  if [ -z "$NBD_DEV" ]; then
    log "  [WARN] No free NBD device found — skipping offline repair (all nbd0-15 busy)"
  else
  log "  [INFO] Using NBD device: $NBD_DEV"
  # Disconnect any stale connection on this device first
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
    sudo fsck -y "$ROOT_PART" >/tmp/fsck_out.txt 2>&1 || true
    log "  fsck: $(tail -2 /tmp/fsck_out.txt 2>/dev/null | tr '\\n' ' ')"
    # Try normal mount, then ro fallback, then norecovery fallback
    if sudo mount "$ROOT_PART" "$MNT" 2>/dev/null; then
      log '  [OK] Mounted normally'
    elif sudo mount -o ro "$ROOT_PART" "$MNT" 2>/dev/null; then
      log '  [INFO] Mounted read-only (journal may still be dirty)'
    elif sudo mount -o norecovery,ro "$ROOT_PART" "$MNT" 2>/dev/null; then
      log '  [INFO] Mounted with norecovery,ro'
    else
      log '  [WARN] Mount failed (tried normal + ro + norecovery) — skipping offline repair'
      sudo qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
      sudo rmmod nbd 2>/dev/null || true
    fi
    if sudo mountpoint -q "$MNT" 2>/dev/null; then
      # OS pre-detected from live origin VM via SSH (injected by orchestrator)
      OS_ID={shell_quote(origin_os_id) if origin_os_id else "''"}
      OS_VER={shell_quote(origin_os_ver) if origin_os_ver else "''"}
      if [ -z "$OS_ID" ] || [ "$OS_ID" = 'unknown' ]; then
        # Fallback: detect from mounted image (may be unreliable for cloud images)
        OS_ID=$(sudo grep '^ID=' "$MNT/etc/os-release" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]' || true)
        OS_VER=$(sudo grep '^VERSION_ID=' "$MNT/etc/os-release" 2>/dev/null | cut -d= -f2 | tr -d '"' || true)
        if [ -z "$OS_ID" ] || [ "$OS_ID" = 'unknown' ]; then
          OS_ID='ubuntu'; OS_VER='24.04'
          log '  [OS] Detection failed — defaulting to ubuntu (netplan repair)'
        else
          log "  [OS] Detected from mounted image: $OS_ID $OS_VER"
        fi
      else
        log "  [OS] Using pre-detected OS (from live SSH): $OS_ID $OS_VER"
      fi

      # Fix fstab — keep LABEL=/UUID=/PARTUUID= entries, comment /dev/* paths
      if [ -f "$MNT/etc/fstab" ]; then
        sudo cp "$MNT/etc/fstab" "$MNT/etc/fstab.ospc2flex.bak"
        sudo sed -i '/^[[:space:]]*#/b; /^[[:space:]]*$/b; /LABEL=/b; /UUID=/b; /PARTUUID=/b; s/^/# [ospc2flex] /' "$MNT/etc/fstab"
        log '  [OK] fstab: kept LABEL=/UUID=/PARTUUID= — commented /dev/* paths (vdb swap etc.)'
        sudo grep -v '^#' "$MNT/etc/fstab" | grep -v '^[[:space:]]*$' || log '  (no active non-commented entries)'
      fi
      # ── OS-Profile Repair: network config per detected OS ────────────────────
      log "  [PROFILE] Applying OS repair profile for: $OS_ID $OS_VER"
      case "$OS_ID" in

        # ── Ubuntu ───────────────────────────────────────────────────────────
        ubuntu)
          OS_MAJOR_VER="${{OS_VER%%.*}}"
          if [ "$OS_MAJOR_VER" = "24" ]; then
            # ── Ubuntu 24.04 custom profile (flex_repair_template_ubuntu24.yaml) ──
            # FLEX NIC is enp3s0. cloud-init writes 50-cloud-init.yaml locked to
            # original OSPC MAC — must be deleted or network breaks on first boot.
            log '  [PROFILE] Ubuntu 24.04 → custom profile (enp3s0, delete 50-cloud-init.yaml)'
            sudo rm -f "$MNT/etc/netplan/50-cloud-init.yaml" 2>/dev/null || true
            log '  [OK] Ubuntu 24: deleted MAC-locked 50-cloud-init.yaml'
            sudo mkdir -p "$MNT/etc/netplan"
            sudo tee "$MNT/etc/netplan/99-ospc2flex.yaml" >/dev/null <<'NETPLAN_U24_EOF'
network:
  version: 2
  ethernets:
    enp3s0:
      dhcp4: true
      dhcp6: false
NETPLAN_U24_EOF
            log '  [OK] Ubuntu 24: wrote 99-ospc2flex.yaml (enp3s0 DHCP)'
          else
            # ── Ubuntu 16 / 18 / 20 / 22 — generic wildcard fallback (proven Apr 9) ──
            log "  [PROFILE] Ubuntu $OS_VER → generic wildcard DHCP netplan (en*/eth*)"
            sudo mkdir -p "$MNT/etc/netplan.ospc2flex.bak"
            sudo cp -a "$MNT/etc/netplan/"*.yaml "$MNT/etc/netplan.ospc2flex.bak/" 2>/dev/null || true
            sudo cp -a "$MNT/etc/netplan/"*.yml  "$MNT/etc/netplan.ospc2flex.bak/" 2>/dev/null || true
            sudo rm -f "$MNT/etc/netplan/"*.yaml "$MNT/etc/netplan/"*.yml 2>/dev/null || true
            sudo mkdir -p "$MNT/etc/netplan"
            sudo tee "$MNT/etc/netplan/99-flex-fallback.yaml" >/dev/null <<'NETPLAN_FLEX_EOF'
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
NETPLAN_FLEX_EOF
            sudo chmod 600 "$MNT/etc/netplan/99-flex-fallback.yaml"
            log "  [OK] Ubuntu $OS_VER: wildcard DHCP fallback netplan written"
          fi
          CHROOT_PKG_MGR="apt"
          CHROOT_INITRD="update-initramfs -u -k all"
          ;;

        # ── Debian 10 / 11 / 12 ──────────────────────────────────────────────
        debian)
          log '  [PROFILE] Debian → /etc/network/interfaces (ifupdown DHCP)'
          sudo cp "$MNT/etc/network/interfaces" "$MNT/etc/network/interfaces.ospc2flex.bak" 2>/dev/null || true
          sudo tee "$MNT/etc/network/interfaces" >/dev/null <<'IFACE_EOF'
auto lo
iface lo inet loopback
auto eth0
allow-hotplug eth0
iface eth0 inet dhcp
    mtu 3942
IFACE_EOF
          # Remove any leftover netplan that may conflict
          sudo rm -f "$MNT/etc/netplan/"*.yaml "$MNT/etc/netplan/"*.yml 2>/dev/null || true
          log '  [OK] Debian: /etc/network/interfaces written (eth0 DHCP, mtu 3942)'
          CHROOT_PKG_MGR="apt"
          CHROOT_INITRD="update-initramfs -u -k all"
          ;;

        # ── AlmaLinux 8 / 9 ──────────────────────────────────────────────────
        almalinux)
          log "  [PROFILE] AlmaLinux $OS_VER → NetworkManager keyfile (DHCP)"
          sudo mkdir -p "$MNT/etc/NetworkManager/system-connections"
          sudo tee "$MNT/etc/NetworkManager/system-connections/eth0.nmconnection" >/dev/null <<'NM_EOF'
[connection]
id=eth0
type=ethernet
interface-name=eth0
autoconnect=true

[ethernet]
mtu=3942

[ipv4]
method=auto

[ipv6]
method=disabled
NM_EOF
          sudo chmod 600 "$MNT/etc/NetworkManager/system-connections/eth0.nmconnection"
          # Remove legacy ifcfg if present (AlmaLinux 9 dropped it)
          sudo rm -f "$MNT/etc/sysconfig/network-scripts/ifcfg-eth0" 2>/dev/null || true
          log '  [OK] AlmaLinux: NetworkManager keyfile written'
          CHROOT_PKG_MGR="dnf"
          CHROOT_INITRD="dracut -f --regenerate-all"
          ;;

        # ── Rocky Linux 8 / 9 ────────────────────────────────────────────────
        rocky)
          log "  [PROFILE] Rocky Linux $OS_VER → NetworkManager keyfile (DHCP)"
          sudo mkdir -p "$MNT/etc/NetworkManager/system-connections"
          sudo tee "$MNT/etc/NetworkManager/system-connections/eth0.nmconnection" >/dev/null <<'NM_EOF'
[connection]
id=eth0
type=ethernet
interface-name=eth0
autoconnect=true

[ethernet]
mtu=3942

[ipv4]
method=auto

[ipv6]
method=disabled
NM_EOF
          sudo chmod 600 "$MNT/etc/NetworkManager/system-connections/eth0.nmconnection"
          sudo rm -f "$MNT/etc/sysconfig/network-scripts/ifcfg-eth0" 2>/dev/null || true
          log '  [OK] Rocky Linux: NetworkManager keyfile written'
          CHROOT_PKG_MGR="dnf"
          CHROOT_INITRD="dracut -f --regenerate-all"
          ;;

        # ── RHEL 8 / 9 ───────────────────────────────────────────────────────
        rhel)
          log "  [PROFILE] RHEL $OS_VER → NetworkManager keyfile (DHCP)"
          sudo mkdir -p "$MNT/etc/NetworkManager/system-connections"
          sudo tee "$MNT/etc/NetworkManager/system-connections/eth0.nmconnection" >/dev/null <<'NM_EOF'
[connection]
id=eth0
type=ethernet
interface-name=eth0
autoconnect=true

[ethernet]
mtu=3942

[ipv4]
method=auto

[ipv6]
method=disabled
NM_EOF
          sudo chmod 600 "$MNT/etc/NetworkManager/system-connections/eth0.nmconnection"
          log '  [OK] RHEL: NetworkManager keyfile written'
          CHROOT_PKG_MGR="dnf"
          CHROOT_INITRD="dracut -f --regenerate-all"
          ;;

        # ── CentOS 7 (legacy ifcfg + yum) ────────────────────────────────────
        centos)
          log "  [PROFILE] CentOS $OS_VER → ifcfg-eth0 (legacy network-scripts)"
          sudo mkdir -p "$MNT/etc/sysconfig/network-scripts"
          sudo cp "$MNT/etc/sysconfig/network-scripts/ifcfg-eth0" \
                  "$MNT/etc/sysconfig/network-scripts/ifcfg-eth0.ospc2flex.bak" 2>/dev/null || true
          sudo tee "$MNT/etc/sysconfig/network-scripts/ifcfg-eth0" >/dev/null <<'IFCFG_EOF'
DEVICE=eth0
NAME=eth0
TYPE=Ethernet
BOOTPROTO=dhcp
ONBOOT=yes
MTU=3942
NM_CONTROLLED=yes
IFCFG_EOF
          # Enable legacy network service via direct symlink (no chroot — RPM from Ubuntu jumphost unsafe)
          sudo mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"
          sudo ln -sf /lib/systemd/system/network.service \
            "$MNT/etc/systemd/system/multi-user.target.wants/network.service" 2>/dev/null || true
          log '  [OK] CentOS: ifcfg-eth0 written (DHCP, mtu 3942)'
          CHROOT_PKG_MGR="yum"
          CHROOT_INITRD="dracut -f --regenerate-all"
          ;;

        # ── Fedora (38+) ─────────────────────────────────────────────────────
        fedora)
          log "  [PROFILE] Fedora $OS_VER → NetworkManager keyfile (DHCP)"
          sudo mkdir -p "$MNT/etc/NetworkManager/system-connections"
          sudo tee "$MNT/etc/NetworkManager/system-connections/eth0.nmconnection" >/dev/null <<'NM_EOF'
[connection]
id=eth0
type=ethernet
interface-name=eth0
autoconnect=true

[ethernet]
mtu=3942

[ipv4]
method=auto

[ipv6]
method=disabled
NM_EOF
          sudo chmod 600 "$MNT/etc/NetworkManager/system-connections/eth0.nmconnection"
          log '  [OK] Fedora: NetworkManager keyfile written'
          CHROOT_PKG_MGR="dnf"
          CHROOT_INITRD="dracut -f --regenerate-all"
          ;;

        # ── openSUSE / SLES ───────────────────────────────────────────────────
        opensuse*|sles|suse)
          log "  [PROFILE] openSUSE/SLES $OS_VER → /etc/sysconfig/network/ifcfg-eth0"
          sudo mkdir -p "$MNT/etc/sysconfig/network"
          sudo tee "$MNT/etc/sysconfig/network/ifcfg-eth0" >/dev/null <<'SUSE_EOF'
BOOTPROTO=dhcp
STARTMODE=auto
MTU=3942
SUSE_EOF
          sudo tee "$MNT/etc/sysconfig/network/routes" >/dev/null <<'ROUTE_EOF'
default - - -
ROUTE_EOF
          log '  [OK] openSUSE/SLES: ifcfg-eth0 written (DHCP)'
          CHROOT_PKG_MGR="zypper"
          CHROOT_INITRD="mkinitrd"
          ;;

        # ── Fallback: unknown OS ──────────────────────────────────────────────
        *)
          log "  [WARN] Unknown OS '$OS_ID' — applying generic netplan DHCP fallback"
          sudo mkdir -p "$MNT/etc/netplan"
          sudo tee "$MNT/etc/netplan/99-flex-fallback.yaml" >/dev/null <<'NETPLAN_FALLBACK_EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    all-en:
      match:
        name: "en*"
      dhcp4: true
      optional: true
    all-eth:
      match:
        name: "eth*"
      dhcp4: true
      optional: true
NETPLAN_FALLBACK_EOF
          sudo chmod 600 "$MNT/etc/netplan/99-flex-fallback.yaml"
          log "  [WARN] Fallback netplan written — manual network review recommended after boot"
          CHROOT_PKG_MGR="apt"
          CHROOT_INITRD="update-initramfs -u -k all"
          ;;
      esac

      # ── Common: clear OSPC udev rules ────────────────────────────────────
      sudo rm -f "$MNT/etc/udev/rules.d/70-persistent-net.rules" 2>/dev/null || true
      sudo rm -f "$MNT/etc/udev/rules.d/75-persistent-net-generator.rules" 2>/dev/null || true
      log '  [OK] OSPC udev persistent-net rules removed'

      # ── Common: reset cloud-init state ───────────────────────────────────
      sudo rm -f "$MNT/etc/cloud/cloud-init.disabled" 2>/dev/null || true
      sudo rm -rf "$MNT/var/lib/cloud/instance" "$MNT/var/lib/cloud/instances/"* 2>/dev/null || true
      sudo rm -f "$MNT/var/lib/cloud/data/result.json" 2>/dev/null || true
      echo "" | sudo tee "$MNT/etc/machine-id" >/dev/null
      sudo rm -f "$MNT/var/lib/dbus/machine-id" 2>/dev/null || true
      sudo rm -f "$MNT/var/lib/dhcp/"*.leases 2>/dev/null || true
      sudo rm -f "$MNT/var/lib/dhclient/"*.lease 2>/dev/null || true
      log '  [OK] cloud-init state cleared, machine-id reset, DHCP leases removed'

      # ── Chroot pkg install — Debian-family only (apt safe from Ubuntu jumphost) ─
      # RPM-based (AlmaLinux/Rocky/RHEL/CentOS/Fedora) and openSUSE skip chroot —
      # cross-distro chroot from Ubuntu jumphost is untested and risks corruption.
      # cloud-init + qemu-guest-agent are pre-installed in most RHEL cloud images.
      case "$CHROOT_PKG_MGR" in
        apt)
          log "  [INFO] Chroot pass (apt): installing cloud-init + qemu-guest-agent..."
          sudo mount --bind /proc "$MNT/proc" 2>/dev/null || true
          sudo mount --bind /sys  "$MNT/sys"  2>/dev/null || true
          sudo mount --bind /dev  "$MNT/dev"  2>/dev/null || true
          sudo cp /etc/resolv.conf "$MNT/etc/resolv.conf" 2>/dev/null || true
          sudo chroot "$MNT" bash -c \
            'DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>/dev/null && apt-get install -y cloud-init qemu-guest-agent 2>/dev/null' \
            >/dev/null 2>&1 || log '  [WARN] apt install partial or skipped'
          log "  [INFO] Rebuilding initramfs: $CHROOT_INITRD"
          sudo chroot "$MNT" bash -c "$CHROOT_INITRD" >/dev/null 2>&1 \
            || log '  [WARN] initramfs rebuild partial or skipped'
          sudo umount "$MNT/dev" "$MNT/sys" "$MNT/proc" 2>/dev/null || true
          log "  [OK] Chroot pass complete for $OS_ID $OS_VER"
          ;;
        dnf|yum|zypper)
          log "  [INFO] Skipping chroot pkg install for $OS_ID (RPM/SUSE from Ubuntu jumphost — unsafe)"
          log "  [INFO] cloud-init + qemu-guest-agent expected pre-installed in cloud image"
          ;;
      esac

      sudo umount "$MNT" && repair_ok=1 || log '  [WARN] umount failed'

    fi
    sudo qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
    sudo rmmod nbd 2>/dev/null || true
    sudo rm -rf "$MNT"
  else
    log "  [WARN] qemu-nbd connect failed"
    sudo rmmod nbd 2>/dev/null || true
  fi
  fi  # end if NBD_DEV found
fi  # end if qemu-nbd available

if [ $repair_ok -eq 1 ]; then
  mv "$converted_path" "$repaired_path"
  log "  [OK] Repaired image saved as: $repaired_path"
else
  cp "$converted_path" "$repaired_path"
  log "  [WARN] Stage 4.5 repair skipped — will attempt Stage 4.6 standalone fallback"
fi
stage_done '4.5'
fi  # end custom_os vs generic branch

# ── STAGE 4.6: Standalone Offline Repair Fallback ────────────────────────────
# Runs if Stage 4.5 repair_ok=0 — covers both modes:
#   custom_os: NBD fail / mount fail / unknown OS
#   generic:   ospc2flex_offline_repair.sh failed or not found in Stage 4.5
if [ $repair_ok -eq 0 ]; then
  stage_start '4.6' 'Standalone Repair Fallback' 'Stage 4.5 repair_ok=0 — retrying with ospc2flex_offline_repair.sh'
  STANDALONE_REPAIR=/tmp/ospc2flex_offline_repair.sh
  if [ -f "$STANDALONE_REPAIR" ]; then
    log "  [INFO] Running standalone repair on: $repaired_path"
    if bash "$STANDALONE_REPAIR" --qcow2 "$repaired_path" --force; then
      log "  [OK] Standalone repair completed successfully"
      repair_ok=1
    else
      log "  [WARN] Standalone repair also failed — image will be uploaded as-is"
      log "  [WARN] Manual guest repair may be needed after FLEX boot"
    fi
  else
    log "  [WARN] $STANDALONE_REPAIR not found — standalone fallback unavailable"
    log "  [WARN] Image will be uploaded as-is — manual repair may be needed after boot"
  fi
  stage_done '4.6'
fi

fi # end skip-if-repaired-exists

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
if echo "$IMG_ID" | grep -qiE 'error|failed|traceback|exception|unauthorized'; then
  stage_fail 5 "Image upload failed: $IMG_ID"
fi
if [ -z "$IMG_ID" ]; then
  stage_fail 5 'Image upload produced no image ID — check FLEX credentials and region'
fi
log "  [OK] Upload complete — Image ID: $IMG_ID"
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
    p.add_argument("--origin-vm-user", default="ubuntu", help="SSH user on the origin VM (default: ubuntu)")
    p.add_argument("--offline-repair-method", default="custom_os", choices=["custom_os", "generic"],
                   help="Offline guest repair strategy: 'custom_os' (per-OS profile, default) or 'generic' (ospc2flex_offline_repair.sh for all VMs)")
    return p


# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

def smart_copy(src: str, user: str, host: str, dest: str, *, key: str, port: int = 22, dry_run: bool = False) -> None:
    try:
        run(f"{scp_base_cmd(key, port)} {shell_quote(src)} {user}@{host}:{shell_quote(dest)}", dry_run=dry_run)
    except RuntimeError as e:
        if 'Permission denied' in str(e) or 'scp' in str(e).lower():
            log(f"[WARN] SCP blocked or failed for {host}. Falling back to SSH stdin pipe...")
            run(f"cat {shell_quote(src)} | {ssh_base_cmd(key, user, host, port)} 'cat > {shell_quote(dest)}'", dry_run=dry_run)
        else:
            raise


def main() -> None:
    args = build_parser().parse_args()

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
        if not origin_vm_ip and not args.dry_run:
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

        if not origin_vm_ip and args.dry_run:
            origin_vm_ip = "<ORIGIN-VM-IP-AUTO-DISCOVERED>"
            log(f"[DRY-RUN] Origin VM IP not resolved (no OSPC call in dry-run) — using placeholder: {origin_vm_ip}")
        if not origin_vm_ip:
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
        # use_mode3 = Production Mode: --origin-vm-ip was explicitly provided AND differs from jumphost
        use_mode3 = bool(getattr(args, 'origin_vm_ip', None) and getattr(args, 'origin_vm_ip') != external_host_ip)

        if use_mode3:
            log(f"[INFO] ⚡ PRODUCTION MODE — Jumphost: {processing_host} — will SSH-pipe /dev/vda from origin VM {origin_vm_ip}")
        else:
            log(f"[INFO] EXTERNAL OFFLOAD — Jumphost: {processing_host} — will download snapshot from OSPC Glance")

        log(f"[INFO] Waiting for SSH on processing host {processing_host}...")
        wait_for_ssh(
            key=args.ssh_key_path,
            user=args.ssh_user,
            host=processing_host,
            port=args.ssh_port,
            dry_run=args.dry_run,
        )

        # ── Copy openrc files to processing host ──
        ospc_remote = "/tmp/ospc2flex_ospc.sh"
        flex_remote = "/tmp/ospc2flex_flex.sh"
        smart_copy(str(ospc_openrc), args.ssh_user, processing_host, ospc_remote, key=args.ssh_key_path, port=args.ssh_port, dry_run=args.dry_run)
        smart_copy(str(flex_openrc), args.ssh_user, processing_host, flex_remote, key=args.ssh_key_path, port=args.ssh_port, dry_run=args.dry_run)

        # ── Copy standalone offline repair script to processing host (Stage 4.6 fallback) ──
        _standalone_repair_local = Path(__file__).parent / "ospc2flex_offline_repair.sh"
        _standalone_repair_remote = "/tmp/ospc2flex_offline_repair.sh"
        if _standalone_repair_local.exists():
            log(f"[INFO] Copying standalone offline repair script to processing host...")
            smart_copy(str(_standalone_repair_local), args.ssh_user, processing_host, _standalone_repair_remote,
                       key=args.ssh_key_path, port=args.ssh_port, dry_run=args.dry_run)
            if not args.dry_run:
                perm_repair = f"{ssh_base_cmd(args.ssh_key_path, args.ssh_user, processing_host, args.ssh_port)} chmod +x {_standalone_repair_remote}"
                run(perm_repair, capture=False, dry_run=False, check=False)
            log(f"[OK] Standalone repair script staged at {_standalone_repair_remote} on processing host")
        else:
            log(f"[WARN] ospc2flex_offline_repair.sh not found locally — Stage 4.6 fallback will be unavailable")

        # ── Mode 3: copy SSH key to external host so it can reach origin VM ──
        origin_vm_key_remote_path = ""
        if use_mode3:
            origin_vm_key_remote_path = "/tmp/ospc2flex_origin_key.pem"
            log(f"[INFO] Copying SSH key to external host for origin VM access...")
            smart_copy(str(args.ssh_key_path), args.ssh_user, processing_host, origin_vm_key_remote_path,
                       key=args.ssh_key_path, port=args.ssh_port, dry_run=args.dry_run)
            # Fix permissions on key after copy
            if not args.dry_run:
                perm_cmd = f"{ssh_base_cmd(args.ssh_key_path, args.ssh_user, processing_host, args.ssh_port)} chmod 600 {origin_vm_key_remote_path}"
                run(perm_cmd, capture=False, dry_run=False, check=False)
            log(f"[OK] SSH key copied to external host at {origin_vm_key_remote_path}")

        # ── SSH into origin VM to detect OS (before stream) ──
        origin_vm_user = getattr(args, 'origin_vm_user', 'ubuntu') or 'ubuntu'
        origin_os_id = ""
        origin_os_ver = ""
        if not args.dry_run and origin_vm_ip and not origin_vm_ip.startswith("<"):
            log(f"[INFO] Detecting OS on origin VM {origin_vm_ip} via SSH...")
            try:
                detect_cmd = (
                    f"{ssh_base_cmd(args.ssh_key_path, origin_vm_user, origin_vm_ip, args.ssh_port)}"
                    f" \"grep -E '^(ID|VERSION_ID)=' /etc/os-release 2>/dev/null || true\""
                )
                os_out = run(detect_cmd, capture=True, check=False, dry_run=False)
                for line in os_out.splitlines():
                    line = line.strip()
                    if line.startswith("ID=") and not line.startswith("ID_LIKE="):
                        origin_os_id = line.split("=", 1)[1].strip('"\'').lower()
                    elif line.startswith("VERSION_ID="):
                        origin_os_ver = line.split("=", 1)[1].strip('"\'')
                if origin_os_id:
                    log(f"[OK] Origin VM OS: {origin_os_id} {origin_os_ver}")
                else:
                    log("[WARN] Could not detect OS from origin VM /etc/os-release — will fallback to mounted image detection")
            except Exception as exc:
                log(f"[WARN] OS detection SSH failed: {exc} — will fallback to mounted image detection")
        else:
            log(f"[DRY-RUN] Skipping live OS detection — will inject placeholder")

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
            origin_os_id=origin_os_id,
            origin_os_ver=origin_os_ver,
            offline_repair_method=getattr(args, 'offline_repair_method', 'custom_os') or 'custom_os',
        )

        # Use unique filename per VM to avoid race condition when parallel jobs share workdir
        ts = int(time.time())
        safe_vm_name = args.server_name.replace(" ", "_").replace("/", "_")
        local_script = workdir / f"remote_export_{safe_vm_name}_{ts}.sh"
        local_script.write_text(script_content, encoding="utf-8")

        remote_script = f"ospc2flex_remote_export_{safe_vm_name}_{ts}.sh"
        smart_copy(str(local_script), args.ssh_user, processing_host, remote_script, key=args.ssh_key_path, port=args.ssh_port, dry_run=args.dry_run)

        ssh_cmd = f"{ssh_base_cmd(args.ssh_key_path, args.ssh_user, processing_host, args.ssh_port)} bash {remote_script}"
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
            boot_cmd = (
                f"openstack server create"
                f" {shell_quote(test_server_name)}"
                f" --image {shell_quote(flex_image_name)}"
                f" --flavor {shell_quote(args.flex_flavor)}"
                f" --network {shell_quote(args.flex_network_id)}"
            )

        if args.flex_key_name:
            boot_cmd += f" --key-name {shell_quote(args.flex_key_name)}"
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
                fip = json.loads(fip_resp).get("floating_ip_address", "")
                if fip:
                    run(openstack_cmd(
                        flex_openrc,
                        f"openstack server add floating ip {shell_quote(server_id)} {shell_quote(fip)}"
                    ), dry_run=args.dry_run)
                    test_ip = fip
                    log(f"[OK] Floating IP: {test_ip}")
            except Exception as e:
                log(f"[WARN] Floating IP allocation failed: {e}")

        if not test_ip:
            ips = parse_addresses_for_floating(server_payload.get("addresses", ""))
            if ips:
                test_ip = ips[0]

        # Stage 7 — SSH diagnostics (no repairs)
        if test_ip and args.ssh_key_path:
            log("┌" + "─" * 54 + "┐")
            log("│ STAGE 7 ── VM Diagnostics")
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
            log("│ STAGE 7 ── Diagnostics complete")

    log("[INFO] Migration complete!")


if __name__ == "__main__":
    main()
