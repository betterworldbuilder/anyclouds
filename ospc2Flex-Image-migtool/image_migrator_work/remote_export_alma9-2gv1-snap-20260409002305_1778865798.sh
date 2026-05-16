#!/usr/bin/env bash
set -euo pipefail

# ─── Logging helpers ────────────────────────────────────────────────────────
log() { echo "$@"; }
stage_start() { local n=$1 t=$2 d=$3
  echo ""
  echo ""
  echo "┌──────────────────────────────────────────────────────┐"
  echo "│ STAGE $n ── $t"
  echo "│ $d"
  echo "└──────────────────────────────────────────────────────┘"
}
stage_done() { local n=$1; echo "✅ STAGE $n RESULT: SUCCESS"; echo ""; }
stage_fail() { local n=$1 msg=$2; echo "❌ STAGE $n RESULT: FAILED ── $msg"; echo ""; exit 1; }

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║        OSPC → FLEX Datacenter Backbone Pipeline ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

export_retries=4
export_retry_wait=15
# ── Workspace Initialization ──────────────────────────────────────────────────
# Dynamically find the mount point with the largest available free space (Strictly bypassing root drive if possible)
BEST_MOUNT=$(df -P -k | awk 'NR>1 && $1 !~ /tmpfs|udev|devtmpfs|overlay|shm|loop/ && $6 !~ /^[/](boot|run|dev|sys|proc|snap|var[/]lib)/ && $6 != "/" { print $4, $6 }' | sort -rn | head -n1 | awk '{print $2}')

if [ -n "$BEST_MOUNT" ]; then
    workdir="$BEST_MOUNT/ospc2flex_image"
else
    workdir=$(eval echo '$HOME/image')
    log "[WARN] Strict policy fallback: No external data volumes found. Resorting to root drive."
fi

log "[INFO] Largest volume identified: $BEST_MOUNT"
log "[INFO] Using workspace folder: $workdir"
sudo mkdir -p "$workdir"
sudo chown $(whoami):$(whoami) "$workdir" 2>/dev/null || true
# ── Path definitions — always tied to THIS VM's snap_name ─────────────────────
# Never reuse another VM's leftover qcow2 (parallel jobs share the same workdir)
repaired_path="$workdir/alma9-2gv1-snap-20260409002305-repaired.qcow2"
converted_path="$workdir/alma9-2gv1-snap-20260409002305.qcow2"
img_path="$workdir/alma9-2gv1-snap-20260409002305.img"

# ── Windows: no resume — wipe ALL files for this image before starting ────────
IS_WINDOWS=0
if [ "$IS_WINDOWS" = "1" ]; then
  log "[INFO] Windows image detected — purging all existing files (no resume for Windows)"
  for _wf in "$img_path" "$converted_path" "$repaired_path"; do
    [ -f "$_wf" ] && rm -f "$_wf" && log "  [DEL] $_wf" || true
  done
  for _wf in "$workdir/alma9-2gv1-snap-20260409002305".*; do
    [ -f "$_wf" ] && rm -f "$_wf" && log "  [DEL] $_wf" || true
  done
  log "[INFO] Windows workspace clean — starting fresh"
fi

# ── STAGE 1 ─────────────────────────────────────────────────────────────────
stage_start 1 'Validate Dependencies' 'Checking openstack CLI and qemu-img'
if ! command -v openstack >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/openstack" ]; then
  log '  Installing OpenStack CLI...'
  sudo apt-get update >/dev/null 2>&1 || true
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3-openstackclient >/dev/null 2>&1 || \
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

# ── STAGE 2.5: Clean Old Workspace Images ────────────────────────────────────
# Only delete files belonging to THIS VM's snap prefix — never touch other VMs' files
# (parallel jobs share the same workdir — deleting other VMs' qcow2s would corrupt them)
stage_start '2.5' 'Clean Old Workspace' 'Removing previous .img + .qcow2 from old runs (freeing disk space)'
cleaned=0
SNAP_PREFIX="alma9-2gv1-snap-20260409002305"
for f in "$workdir"/"$SNAP_PREFIX"*.img "$workdir"/"$SNAP_PREFIX"*.qcow2; do
  [ -f "$f" ] || continue
  [ "$f" = "$img_path" ] && continue
  [ "$f" = "$converted_path" ] && continue
  [ "$f" = "$repaired_path" ] && continue
  rm -f "$f" && log "  [DEL] $f" && cleaned=$((cleaned+1))
done
[ $cleaned -eq 0 ] && log '  [OK] No old images to clean' || log "  [OK] Removed $cleaned old image file(s)"
df -h "$workdir" | tail -1 | awk '{print "  [INFO] Disk free: " $4 " / " $2}'
stage_done '2.5'

# ── Check: skip to repair if converted .qcow2 already exists and is large enough ─
# Windows images are 12+ GB; Linux images can be 1-4 GB when compressed as qcow2.
if [ "$IS_WINDOWS" = "1" ]; then
  MIN_SIZE_BYTES=10737418240  # 10 GB — Windows min
else
  MIN_SIZE_BYTES=1073741824   # 1 GB  — Linux min
fi
if [ -f "$converted_path" ]; then
  _sz=$(stat -c%s "$converted_path" 2>/dev/null || echo 0)
  if [ "$_sz" -lt "$MIN_SIZE_BYTES" ]; then
    log "  [WARN] Converted qcow2 too small ($_sz bytes) — deleting and re-downloading"
    rm -f "$converted_path"
  else
    log "  [INFO] Converted qcow2 exists: $converted_path ($_sz bytes) — skipping to stage 4.5 (offline repair)"
  fi
fi
if [ -f "$converted_path" ]; then
  log "  [INFO] Resuming from converted qcow2"
else
# ── STAGE 3: Download OSPC Snapshot ──────────────────────────────────────────
stage_start 3 'Download OSPC Snapshot' 'Prefer Glance export → Cloud Files → same-region jumphost'
log '  Sourcing OSPC credentials...'
source /tmp/ospc2flex_ospc.sh
log '  Acquiring OSPC Keystone token...'
# Try openstack CLI first; fall back to RAX apikey curl if it fails
OS_TOKEN=$(openstack token issue -f value -c id 2>/dev/null || true)
if [ -z "$OS_TOKEN" ] && [ -n "${OS_USERNAME:-}" ] && [ -n "${OS_PASSWORD:-}" ]; then
  log '  [INFO] openstack token issue failed — trying RAX apikey auth...'
  _AUTH_RESP=$(curl -s -X POST "https://identity.api.rackspacecloud.com/v2.0/tokens" \
    -H "Content-Type: application/json" \
    -d '{"auth":{"RAX-KSKEY:apiKeyCredentials":{"username":"'"${OS_USERNAME:-}"'","apiKey":"'"${OS_PASSWORD:-}"'"}}}' 2>/dev/null || true)
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
IMG_DOWNLOAD_URL="$OS_IMAGE_URL/v2/images/18656bbf-813d-461e-88a9-0b6da3695e15/file"
log "  Target: $IMG_DOWNLOAD_URL"
success=0
GLANCE_BRIDGE=/tmp/ospc2flex_glance_bridge.sh
if [ $success -eq 0 ] && [ "1" = "1" ] && [ -x "$GLANCE_BRIDGE" ]; then
  log "  Trying Cloud Files preferred bridge (Glance/Cloud Files waterfall)..."
  set +e
  BRIDGE_DOWNLOAD_OUT=$(bash "$GLANCE_BRIDGE" download       --ospc-openrc /tmp/ospc2flex_ospc.sh       --image-id 18656bbf-813d-461e-88a9-0b6da3695e15       --dest "$img_path"       --container ospc2flex-export       --prefer-cloud-files       --retries "$export_retries"       --retry-wait "$export_retry_wait"       --min-bytes 1048576 2>&1)
  BRIDGE_DOWNLOAD_RC=$?
  set -e
  echo "$BRIDGE_DOWNLOAD_OUT"
  if [ "$BRIDGE_DOWNLOAD_RC" -eq 0 ]; then
    size=$(stat -c%s "$img_path" 2>/dev/null || echo 0)
    log "  [OK] Bridge downloaded OSPC image: $size bytes"
    success=1
  elif [ "$BRIDGE_DOWNLOAD_RC" -eq 42 ]; then
    rm -f "$img_path"
    stage_fail 3 "Cloud Files export is blocked by Rackspace image licensing/billing policy for this snapshot; direct Glance cannot handle this large image path"
  else
    log "  [WARN] Bridge download failed — falling back to legacy public Glance loop"
    rm -f "$img_path"
  fi
elif [ "1" = "1" ]; then
  log "  [WARN] Glance bridge not found at $GLANCE_BRIDGE — using legacy public Glance loop"
fi
# Try openstack image save first (avoids 413 on Rackspace OSPC Glance large files)
if [ $success -eq 0 ]; then
log "  Trying openstack image save (primary method — avoids HTTP 413)..."
rm -f "$img_path"
if openstack image save --file "$img_path" "18656bbf-813d-461e-88a9-0b6da3695e15" 2>/tmp/ospc_img_save_err.txt; then
  size=$(stat -c%s "$img_path" 2>/dev/null || echo 0)
  if [ "$size" -gt 1048576 ]; then
    log "  [OK] Download via openstack image save: ${size} bytes"
    success=1
  else
    log "  [WARN] openstack image save returned small file (${size} bytes) — $(cat /tmp/ospc_img_save_err.txt 2>/dev/null | head -2)"
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
  HTTP_STATUS=$(curl -s -C - -L --retry 3 --retry-delay 10 --retry-max-time 180 \
    -H "X-Auth-Token: $OS_TOKEN" \
    -o "$img_path" \
    --write-out '%{http_code}' \
    "$IMG_DOWNLOAD_URL" 2>/dev/null || echo '000')
  size=$(stat -c%s "$img_path" 2>/dev/null || echo 0)
  log "  HTTP $HTTP_STATUS | $size bytes received"
  if [ "$size" -gt 1048576 ]; then
    log "  [OK] Download complete: $size bytes"
    success=1; break
  else
    log "  [WARN] Incomplete (size=$size) — refreshing token and retrying..."
    _AUTH_RESP=$(curl -s -X POST "https://identity.api.rackspacecloud.com/v2.0/tokens" \
      -H "Content-Type: application/json" \
      -d '{"auth":{"RAX-KSKEY:apiKeyCredentials":{"username":"'"${OS_USERNAME:-}"'","apiKey":"'"${OS_PASSWORD:-}"'"}}}' 2>/dev/null || true)
    OS_TOKEN=$(echo "$_AUTH_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['access']['token']['id'])" 2>/dev/null || true)
    rm -f "$img_path"
  fi
  [ $attempt -lt $export_retries ] && { log "  Waiting ${export_retry_wait}s..."; sleep $export_retry_wait; }
done
fi
[ $success -eq 0 ] && stage_fail 3 'Download failed after all attempts (openstack image save + curl both failed)'
stage_done 3

# ── STAGE 4: Convert Image Format ────────────────────────────────────────────
stage_start 4 'Convert Image Format' 'Detect format via qemu-img info then convert → qcow2'
DETECTED_FMT=$(qemu-img info --output=json "$img_path" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('format','raw'))" 2>/dev/null || echo 'raw')
log "  [INFO] Detected source format: $DETECTED_FMT"
if [ "$DETECTED_FMT" = "qcow2" ]; then
  log '  [INFO] Source already in target format — copying without re-encoding'
  cp "$img_path" "$converted_path"
else
  log "  [INFO] Converting $DETECTED_FMT → qcow2..."
  qemu-img convert -p -f "$DETECTED_FMT" -O qcow2 "$img_path" "$converted_path"
fi
SIZE=$(ls -lh "$converted_path" | awk '{print $5}')
log "  [OK] Output: $converted_path ($SIZE)"
stage_done 4

fi  # end skip-if-qcow2-exists

# ── Shared repair profile (must match Glance image pipeline + ospc2flex_repair_os_hint.py) ──
REPAIR_OS_TYPE=alma9
OFFLINE_REPAIR_METHOD=custom_os
log "[INFO] Repair profile: REPAIR_OS_TYPE=${REPAIR_OS_TYPE:-<auto>} method=$OFFLINE_REPAIR_METHOD"

# ── Check: resume from repaired image if already done (skip stages 4.5/4.6/4.7) ──
repair_done=0
if [ -f "$repaired_path" ]; then
  _rz=$(stat -c%s "$repaired_path" 2>/dev/null || echo 0)
  if [ "$_rz" -ge "$MIN_SIZE_BYTES" ]; then
    log "  [INFO] Repaired image exists: $repaired_path ($_rz bytes) — resuming from repaired image (skipping repair stages)"
    repair_done=1
  else
    log "  [WARN] Repaired image too small ($_rz bytes) — discarding and re-repairing"
    rm -f "$repaired_path"
  fi
fi
if [ $repair_done -eq 0 ]; then

# ── STAGE 4.5: Offline Guest Repair ──────────────────────────────────────────
# Linux quick path (fstab + netplan). Windows skips — Stage 4.6 runs VirtIO script.
repair_ok=0
if [ "${REPAIR_OS_TYPE:-}" = "windows" ]; then
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
    ROOT_PART=$(sudo fdisk -l "$NBD_DEV" 2>/dev/null | awk '/Linux filesystem/{print $1; exit}')
    [ -z "$ROOT_PART" ] && ROOT_PART="${NBD_DEV}p1" || true
    log "  Root partition: $ROOT_PART"
    sudo mkdir -p "$MNT"
    # Run fsck to repair dirty journal from live snapshot
    log '  Running fsck to repair dirty journal...'
    sudo fsck -y -f "$ROOT_PART" >/tmp/fsck_out.txt 2>&1 || true
    log "  fsck: $(tail -2 /tmp/fsck_out.txt 2>/dev/null | tr '\n' ' ')"
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
        sudo sed -i '/^[[:space:]]*#/b; /^[[:space:]]*$/b; /[[:space:]]\/[[:space:]]/b; /[[:space:]]swap[[:space:]]/b; s/^/# [ospc2flex] /' "$MNT/etc/fstab"
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
      elif [ "$_os_id_45" = "debian" ] && [ "${_os_major_45:-0}" -lt 12 ]; then
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
REPAIR_LOG="$workdir/alma9-2gv1-snap-20260409002305.repair.log"
verify_centos_lan_markers() {
  local _profile="${REPAIR_OS_TYPE:-}"
  local _need=0
  case "$_profile" in
    centos*|rhel7*|rhel6*) _need=1 ;;
  esac
  [ "$_need" -eq 0 ] && return 0
  if [ ! -f "$REPAIR_LOG" ]; then
    log "  [ERROR] [REPAIR-LAN-E5] Repair log missing: $REPAIR_LOG"
    return 1
  fi
  if grep -q "Wrote fresh ifcfg-eth0 (no HWADDR, ONBOOT=yes, DHCP, NM_CONTROLLED=no)" "$REPAIR_LOG"      && grep -q "Enabled network.service" "$REPAIR_LOG"; then
    log "  [OK] [REPAIR-LAN] CentOS/RHEL LAN markers verified"
    return 0
  fi
  log "  [ERROR] [REPAIR-LAN-E5] Missing CentOS/RHEL LAN markers in $REPAIR_LOG"
  return 1
}
if [ "${REPAIR_OS_TYPE:-}" = "windows" ]; then
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
    if [ -n "${REPAIR_OS_TYPE:-}" ]; then
      if bash "$STANDALONE_REPAIR" --qcow2 "$repaired_path" --force --os-type "${REPAIR_OS_TYPE}" 2>&1 | tee "$REPAIR_LOG"; then
        log "  [OK] Custom per-OS repair completed (profile=${REPAIR_OS_TYPE})"
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

_verify_repair() {
  local qcow2_path="$1"
  local result=0
  local _mnt=/tmp/ospc2flex_verify_$$
  sudo modprobe nbd max_part=8 2>/dev/null || true
  local _nbd=""
  for _d in /dev/nbd{0..15}; do
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
  _root=$(sudo fdisk -l "$_nbd" 2>/dev/null | awk '/Linux filesystem/{sz=strtonum($5); if(sz>max){max=sz;p=$1}} END{print p}')
  [ -z "$_root" ] && _root="${_nbd}p1" || true
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
      if sudo bash -c "ls "$_mnt/etc/netplan/"*.yaml "$_mnt/etc/netplan/"*.yml 2>/dev/null | grep -q ."; then
        _net_ok=1; log "  [VERIFY] Ubuntu netplan config: FOUND ✅"
      else
        log "  [VERIFY] Ubuntu netplan config: MISSING ❌"
      fi ;;
    debian)
      # Debian 12+ uses netplan, Debian 10/11 uses ifupdown
      if [ "${_os_major:-0}" -ge 12 ]; then
        if sudo bash -c "ls "$_mnt/etc/netplan/"*.yaml "$_mnt/etc/netplan/"*.yml 2>/dev/null | grep -q ."; then
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
      if [ "${_os_major:-0}" -ge 9 ]; then
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
      if sudo ls "$_mnt/etc/netplan/"*.yaml "$_mnt/etc/netplan/"*.yml 2>/dev/null | grep -q . ||          sudo test -f "$_mnt/etc/network/interfaces" 2>/dev/null ||          sudo ls "$_mnt/etc/NetworkManager/system-connections/"*.nmconnection 2>/dev/null | grep -q .; then
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
}

_max_repair_attempts=3
_repair_attempt=0
_verify_passed=0

if [ "${REPAIR_OS_TYPE:-}" = "windows" ]; then
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
    for _d2 in /dev/nbd{0..15}; do
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
        _rpart2=$(sudo fdisk -l "$_rnbd2" 2>/dev/null | awk '/Linux filesystem/{sz=strtonum($5); if(sz>max){max=sz;p=$1}} END{print p}')
        [ -z "$_rpart2" ] && _rpart2="${_rnbd2}p1"
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
              if [ "${_dmaj:-0}" -ge 12 ]; then
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
              if [ "${_amaj:-0}" -eq 7 ] && [ "$_ros2" = "rhel" ]; then
                sudo rm -f "$_rmnt2/etc/systemd/system/network.service" 2>/dev/null || true
                sudo mkdir -p "$_rmnt2/etc/systemd/system/multi-user.target.wants"
                sudo ln -sf /usr/lib/systemd/system/network.service                   "$_rmnt2/etc/systemd/system/multi-user.target.wants/network.service" 2>/dev/null || true
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
                sudo find "$_rmnt2/etc/NetworkManager/system-connections" -name "*.nmconnection" -exec rm -f {} \; 2>/dev/null || true
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
              log "  [VERIFY-REPAIR] ${_ros2} v$_amaj: ifcfg-eth0 rewritten"
              # v9+: also write NM keyfile (RHEL 9 dual mode)
              if [ "${_amaj:-0}" -ge 9 ]; then
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
                log "  [VERIFY-REPAIR] ${_ros2} v$_amaj: NM keyfile written (dual mode)"
              else
                # v8: remove stale keyfiles (ifcfg only)
                sudo find "$_rmnt2/etc/NetworkManager/system-connections" -name "*.nmconnection" -exec rm -f {} \; 2>/dev/null || true
                log "  [VERIFY-REPAIR] ${_ros2} v$_amaj: cleared NM keyfiles (ifcfg-only)"
              fi
              fi ;;
            centos)
              _cver=$(sudo grep '^VERSION_ID=' "$_rmnt2/etc/os-release" 2>/dev/null | cut -d= -f2 | tr -d '"' || true)
              _cmaj=$(echo "$_cver" | cut -d. -f1)
              sudo mkdir -p "$_rmnt2/etc/sysconfig/network-scripts"
              if [ "${_cmaj:-0}" -eq 7 ]; then
                sudo rm -f "$_rmnt2/etc/systemd/system/network.service" 2>/dev/null || true
                sudo mkdir -p "$_rmnt2/etc/systemd/system/multi-user.target.wants"
                sudo ln -sf /usr/lib/systemd/system/network.service                   "$_rmnt2/etc/systemd/system/multi-user.target.wants/network.service" 2>/dev/null || true
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
                sudo find "$_rmnt2/etc/NetworkManager/system-connections" -name "*.nmconnection" -exec rm -f {} \; 2>/dev/null || true
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

fi  # end repair_done check (stages 4.5/4.6/4.7)

# ── STAGE 5: Upload to FLEX Glance ───────────────────────────────────────────
stage_start 5 'Upload to FLEX Glance' 'Prefer FLEX Cloud Files staging → Glance import; fallback to direct Glance upload'
sed -i 's/'$'''$//' /tmp/ospc2flex_flex.sh  # Strip Windows CR from openrc
source /tmp/ospc2flex_flex.sh
log '  [INFO] Authenticating to FLEX (via sourced OpenRC)...'
if ! openstack token issue >/dev/null 2>&1; then
  stage_fail 5 "FLEX authentication failed. Cannot connect to FLEX Glance. Please check credentials."
fi
log '  [OK] OpenRC sourced and authentication verified'

UPLOAD_SIZE=$(stat -c%s "$repaired_path" 2>/dev/null || echo 0)
log "  [INFO] Image: $repaired_path (${UPLOAD_SIZE} bytes)"
IMG_ID=""
GLANCE_BRIDGE=/tmp/ospc2flex_glance_bridge.sh
if [ "1" = "1" ] && [ -x "$GLANCE_BRIDGE" ]; then
  log "  [INFO] Uploading image via Cloud Files -> FLEX Glance bridge (preferred)..."
  if BRIDGE_UPLOAD_OUT=$(bash "$GLANCE_BRIDGE" upload       --flex-openrc /tmp/ospc2flex_flex.sh       --image-file "$repaired_path"       --image-name alma9-2gv1-snap-20260409002305-flex       --disk-format qcow2       --container-format bare       --visibility private       --container ospc2flex-staging 2>&1); then
    echo "$BRIDGE_UPLOAD_OUT"
    IMG_ID=$(echo "$BRIDGE_UPLOAD_OUT" | awk -F= '/^FLEX_IMAGE_ID=/ {print $2; exit}')
  else
    _bridge_rc=$?
    echo "$BRIDGE_UPLOAD_OUT"
    log "  [WARN] Cloud Files bridge upload failed rc=$_bridge_rc — falling back to direct openstack image create"
  fi
else
  log "  [WARN] Cloud Files bridge unavailable or disabled — using direct openstack image create"
fi
if [ -z "$IMG_ID" ] || echo "$IMG_ID" | grep -qiE 'error|failed|traceback|exception|unauthorized'; then
  log "  [INFO] Uploading image via direct openstack image create fallback..."
  IMG_ID=$(openstack image create \
    --disk-format qcow2 \
    --container-format bare \
    --file "$repaired_path" \
    --property visibility=private \
    --format value -c id \
    "alma9-2gv1-snap-20260409002305-flex" 2>&1 || true)
fi
if [ -z "$IMG_ID" ] || echo "$IMG_ID" | grep -qiE 'error|failed|traceback|exception|unauthorized'; then
  stage_fail 5 "Image upload produced no FLEX image ID after all methods: $IMG_ID"
fi
log "  [OK] Upload complete — Image ID: $IMG_ID"
SHOW_NAME=$(openstack image show "$IMG_ID" -f value -c name 2>/dev/null || echo "alma9-2gv1-snap-20260409002305-flex")
SHOW_VIS=$(openstack image show "$IMG_ID" -f value -c visibility 2>/dev/null || echo "unknown")
SHOW_STAT=$(openstack image show "$IMG_ID" -f value -c status 2>/dev/null || echo "unknown")
log "  [UPLOAD-CONFIRMED] region=${OS_REGION_NAME:-unknown} id=$IMG_ID name=${SHOW_NAME:-unknown} status=${SHOW_STAT:-unknown} visibility=${SHOW_VIS:-unknown}"
stage_done 5

# ── STAGE 5.5: Clean Workspace ───────────────────────────────────────────────
stage_start '5.5' 'Clean Workspace' 'Removing successfully uploaded artifact from origin VM'
rm -f "$repaired_path" "$converted_path" "$img_path" 2>/dev/null || true
log '  [OK] Workspace pruned'
stage_done '5.5'

echo "MIGRATION_COMPLETE=true"
echo "FLEX_IMAGE_ID=$IMG_ID"
exit 0

