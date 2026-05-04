#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# ospc2flex_windows_migrate.sh — Windows VM Migration (SSH disk read + Glance fallback)
# ═══════════════════════════════════════════════════════════════════════════════
# Primary path  (Step 1b+2): WinRM → installs OpenSSH on Windows → SSH+PowerShell
#               reads PhysicalDrive0 directly to jumphost (same as Linux NBD flow).
# Fallback path (Step 2):    Glance snapshot → Cloud Files bridge → download.
#
# Usage:
#   bash ospc2flex_windows_migrate.sh \
#     --server-name "win2019websql2019" \
#     --server-ip "104.130.26.6" \
#     --label "ospc2flex-win2019" \
#     --windows-password "MyAdminPass" \
#     [--windows-user "Administrator"] \
#     [--flavor "gp.5.4.4"] [--network "tenant-net"] [--keypair "laptopubuntu24"]
#
# Requires: /tmp/ospc2flex_ospc.sh (OSPC creds) and /tmp/ospc2flex_flex.sh (FLEX creds)
#           /tmp/ospc2flex_windows_repair.sh (VirtIO driver injection script)
#
# On-disk qcow2/img: <base-label>-YYYYMMDD-HHMMSS on fresh run, or existing file stem
# when resuming. FLEX Glance + VM name (CLOUD_LABEL): always <base>-YYYYMMDD-HHMMSS
# when resuming plain base qcow2, else same as on-disk label. Override with:
#   OSPC2FLEX_LEGACY_IMAGE_NAME=1  → no timestamp suffix on qcow2 stem (Glance/VM still timed).
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
SERVER_NAME=""
SERVER_IP=""
LABEL=""
FLAVOR="gp.5.4.4"
NETWORK="tenant-net"
KEYPAIR="laptopubuntu24"
WORK="${WORK:-/mnt/migration/ospc2flex_image}"
OSPC_CREDS="/tmp/ospc2flex_ospc.sh"
FLEX_CREDS="/tmp/ospc2flex_flex.sh"
WIN_REPAIR="/tmp/ospc2flex_windows_repair.sh"
DRY_RUN=0
OS_FAMILY="windows"
OS_TYPE="win2019"
LINUX_REPAIR="/tmp/ospc2flex_offline_repair.sh"
WIN_USER="Administrator"
WIN_PASSWORD=""
WIN_SNET_IP=""
WIN_SSH_IP=""
SSH_DISK_METHOD=0
WINDOWS_MODE="${OSPC2FLEX_WINDOWS_MODE:-offline_only}"
OUTPUT_JSON="${OSPC2FLEX_WINDOWS_OUTPUT_JSON:-}"

# ── Color helpers ─────────────────────────────────────────────────────────────
# Log helpers write to STDERR (not stdout) so they never contaminate captured
# command substitutions like $(_resolve_glance_base) — previous bug was
# WARN inside that helper polluting $OS_IMAGE_URL with multi-line text +
# emoji, which curl then rejected with "URL rejected: Malformed input to a
# URL function" (curl exit 3).  The caller invokes this script with
# `... >log 2>&1` so stderr still lands in the SSE-streamed log file.
log()  { echo "[$(date '+%H:%M:%S')][$LABEL] $*" >&2; }
PASS() { echo "  ✅ $*" >&2; }
FAIL() { echo "  ❌ $*" >&2; }
WARN() { echo "  ⚠️  $*" >&2; }
INFO() { echo "  ℹ️  $*" >&2; }

# ── Step tracking (for aligned progress output) ────────────────────────────────
_STEP_NUM=""
_STEP_NAME=""
_STEP_START_TIME=""
_STEP_STEPS_COMPLETED=0

step_start() {
  local num="$1" name="$2"
  _STEP_NUM="$num"
  _STEP_NAME="$name"
  _STEP_START_TIME=$(date +%s)
  if [[ "$num" =~ ^[0-9]+$ ]]; then
    _STEP_STEPS_COMPLETED=$((num - 1))
  fi
  echo "" >&2
  echo "╔════════════════════════════════════════════════════════════════════════════╗" >&2
  printf "║ STEP %s: %-66s ║\n" "$num" "$name" >&2
  echo "╚════════════════════════════════════════════════════════════════════════════╝" >&2
  log "Step $num of 7 started: $name"
}

step_progress() {
  local msg="$1"
  local elapsed=$(($(date +%s) - _STEP_START_TIME))
  log "  [$((elapsed))s] $msg"
}

step_done() {
  local status="${1:-OK}"
  local elapsed=$(($(date +%s) - _STEP_START_TIME))
  _STEP_STEPS_COMPLETED=$(($_STEP_STEPS_COMPLETED + 1))
  log "Step $_STEP_NUM completed ($status) in ${elapsed}s"
  echo "  └─ [${elapsed}s elapsed] $status" >&2
}

validate_virtio_iso_preflight() {
  local iso_path="${OSPC2FLEX_VIRTIO_ISO_LOCAL:-/mnt/migration/virtio/virtio-win.iso}"
  local offline="${OSPC2FLEX_VIRTIO_ISO_OFFLINE:-1}"
  local min_bytes="${OSPC2FLEX_VIRTIO_ISO_MIN_BYTES:-50000000}"

  echo "── Windows VirtIO ISO preflight ─────────────────────────────"
  echo "VirtIO ISO offline mode : $offline"
  echo "VirtIO ISO path         : $iso_path"

  if [ "$offline" = "0" ]; then
    echo "ℹ️  Online VirtIO ISO download is allowed."
    echo "ℹ️  Step 4 may download ISO if local cache is missing."
    return 0
  fi

  if [ ! -f "$iso_path" ]; then
    echo "❌ Missing VirtIO ISO: $iso_path"
    echo ""
    cat <<'EOF'
Fix:
  sudo mkdir -p /mnt/migration/virtio
  scp virtio-win.iso ubuntu@<jumphost-ip>:/tmp/virtio-win.iso
  sudo mv /tmp/virtio-win.iso /mnt/migration/virtio/virtio-win.iso
  sudo chmod 644 /mnt/migration/virtio/virtio-win.iso
  file /mnt/migration/virtio/virtio-win.iso
  sudo mkdir -p /mnt/virtio_test
  sudo mount -o loop,ro /mnt/migration/virtio/virtio-win.iso /mnt/virtio_test
  ls /mnt/virtio_test | head
  sudo umount /mnt/virtio_test

Or allow online download:
  export OSPC2FLEX_VIRTIO_ISO_OFFLINE=0
EOF
    return 20
  fi

  if [ ! -s "$iso_path" ]; then
    echo "❌ VirtIO ISO exists but is empty: $iso_path"
    return 21
  fi

  local size
  size="$(stat -Lc%s "$iso_path" 2>/dev/null || echo 0)"
  if [ "$size" -lt "$min_bytes" ]; then
    echo "❌ VirtIO ISO is too small: $size bytes"
    echo "Expected a real virtio-win.iso larger than 50 MB."
    return 22
  fi

  if command -v file >/dev/null 2>&1; then
    local ftype
    ftype="$(file -L "$iso_path" 2>/dev/null || true)"
    echo "ISO file type: $ftype"
    if ! echo "$ftype" | grep -Eiq 'ISO|UDF|CD-ROM'; then
      echo "❌ VirtIO ISO does not look like a valid ISO/UDF/CD-ROM image."
      echo "File type was: $ftype"
      return 23
    fi
  else
    echo "⚠️  'file' command not found; skipping file type check."
  fi

  if command -v mount >/dev/null 2>&1; then
    local test_mnt
    test_mnt="$(mktemp -d /tmp/virtio_iso_preflight_XXXXXX)"
    if sudo mount -o loop,ro "$iso_path" "$test_mnt" >/dev/null 2>&1; then
      echo "✅ VirtIO ISO mount test passed."
      ls "$test_mnt" | head -10 || true
      sudo umount "$test_mnt" >/dev/null 2>&1 || true
      rmdir "$test_mnt" >/dev/null 2>&1 || true
    else
      echo "❌ VirtIO ISO mount test failed: $iso_path"
      rmdir "$test_mnt" >/dev/null 2>&1 || true
      return 24
    fi
  fi

  echo "✅ VirtIO ISO preflight OK: $iso_path"
  return 0
}

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-name) SERVER_NAME="$2"; shift 2 ;;
    --server-ip)   SERVER_IP="$2"; shift 2 ;;
    --label)       LABEL="$2"; shift 2 ;;
    --flavor)      FLAVOR="$2"; shift 2 ;;
    --network)     NETWORK="$2"; shift 2 ;;
    --keypair)     KEYPAIR="$2"; shift 2 ;;
    --os-family)        OS_FAMILY="$2"; shift 2 ;;
    --os-type)          OS_TYPE="$2"; shift 2 ;;
    --windows-user)     WIN_USER="$2"; shift 2 ;;
    --windows-password) WIN_PASSWORD="$2"; shift 2 ;;
    --server-snet-ip)   WIN_SNET_IP="$2"; shift 2 ;;
    --dry-run)          DRY_RUN=1; shift ;;
    -h|--help)
      echo "Usage: $0 --server-name <name> --server-ip <ip> --label <label> [--flavor <f>] [--network <n>] [--keypair <k>]"
      exit 0 ;;
    *) INFO "Ignoring unknown arg: $1"; shift 1 ;;
  esac
done

[ -z "$SERVER_NAME" ] && { echo "ERROR: --server-name required"; exit 1; }
[ -z "$LABEL" ] && LABEL="ospc2flex-$(echo "$SERVER_NAME" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')"

# Dashboard/job identity vs names:
#   BASE_LABEL   — value from --label (e.g. windows_2016-104.130.26.194)
#   LABEL        — qcow2/img/repair paths; BASE_LABEL-YYYYMMDD-HHMMSS on fresh download,
#                  or existing stem when resuming a qcow2 on disk.
#   CLOUD_LABEL  — Glance image + FLEX VM name; always BASE_LABEL-YYYYMMDD-HHMMSS when
#                  LABEL equals BASE (resume), else same as LABEL.
BASE_LABEL="$LABEL"
_resume_qcow=""
RESUME_MODE="${OSPC2FLEX_RESUME_MODE:-on}"
RESUME_SCAN_NOTE=""
qcow_is_readable() {
  local img="$1"
  qemu-img info --force-share "$img" >/dev/null 2>&1 || qemu-img info "$img" >/dev/null 2>&1
}
if [ "$RESUME_MODE" != "off" ]; then
  _plain="$WORK/${BASE_LABEL}.qcow2"
  if [ -f "$_plain" ] && qcow_is_readable "$_plain"; then
    _sz=$(stat -c%s "$_plain" 2>/dev/null || echo 0)
    if [ "${_sz:-0}" -ge 1048576 ]; then
      _resume_qcow="$_plain"
    fi
  elif [ -f "$_plain" ]; then
    RESUME_SCAN_NOTE="Found $_plain, but qemu-img could not read it; ignoring resume candidate."
  else
    RESUME_SCAN_NOTE="No plain resume qcow2 found at $_plain."
  fi
  if [ -z "$_resume_qcow" ]; then
    _dated_seen=0
    for _c in $(ls -t "$WORK/${BASE_LABEL}"-*.qcow2 2>/dev/null || true); do
      _dated_seen=1
      [ -f "$_c" ] || continue
      qcow_is_readable "$_c" || continue
      _sz=$(stat -c%s "$_c" 2>/dev/null || echo 0)
      if [ "${_sz:-0}" -ge 1048576 ]; then
        _resume_qcow="$_c"
        break
      fi
    done
    if [ -z "$_resume_qcow" ] && [ "${_dated_seen:-0}" = "1" ]; then
      RESUME_SCAN_NOTE="Found dated qcow2 candidate(s), but none were readable and large enough; using fresh path."
    elif [ -z "$_resume_qcow" ] && [ "${_dated_seen:-0}" = "0" ] && [ -z "$RESUME_SCAN_NOTE" ]; then
      RESUME_SCAN_NOTE="No dated resume qcow2 candidates found for $BASE_LABEL."
    fi
  fi
  if [ -n "$_resume_qcow" ]; then
    LABEL=$(basename "$_resume_qcow" .qcow2)
  else
    LABEL="${BASE_LABEL}"
  fi
fi

CLOUD_LABEL="${OSPC2FLEX_CLOUD_LABEL:-$LABEL}"

QCOW="$WORK/${LABEL}.qcow2"
IMG_PATH="$WORK/${LABEL}.img"
IMG_SIZE=0
DOWNLOAD_METHOD=""
RESUME_FROM_QCOW=0
RESUME_FROM_IMG=0
attempt=0
max_dl=5
SAW_GLANCE_DNS_FAIL=0
SAW_PUBLIC_413=0
LAST_CURL_LOG=""
STEP2_DONE=0
LOG="/tmp/mig_${LABEL}.log"
if [ "${OSPC2FLEX_SELF_TEE:-auto}" != "0" ]; then
  exec > >(tee -a "$LOG") 2>&1
fi

echo "═══════════════════════════════════════════════════════════════════════════"
echo " OSPC→FLEX Windows Migration Workflow"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""
echo "  Server    : $SERVER_NAME ($SERVER_IP)"
echo "  Label      : $LABEL  (on-disk qcow2/img)"
echo "  Base label : $BASE_LABEL  (dashboard / job id)"
echo "  Cloud name : $CLOUD_LABEL  (FLEX Glance image + server create)"
echo "  Flavor    : $FLAVOR"
echo "  Network   : $NETWORK"
echo "  Keypair   : $KEYPAIR"
echo "  OS Family : $OS_FAMILY"
echo "  OS Type   : $OS_TYPE"
echo "  Win Mode  : $WINDOWS_MODE"
echo ""
echo "  Steps: 1 (OSPC auth/snapshot) → 1b (SSH check) → 2 (disk read) → 3 (qcow2) →"
echo "         4 (VirtIO repair) → 5 (upload) → 6 (boot) → 7 (floating IP)"
echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""

mkdir -p "$WORK"
if [ "$RESUME_MODE" = "off" ]; then
  INFO "Resume mode: OFF (OSPC2FLEX_RESUME_MODE=off) — forcing fresh download/conversion path."
elif [ -s "$QCOW" ] && qcow_is_readable "$QCOW"; then
  QCOW_EXISTING_BYTES=$(stat -c%s "$QCOW" 2>/dev/null || echo 0)
  if [ "${QCOW_EXISTING_BYTES:-0}" -ge 1048576 ]; then
    RESUME_FROM_QCOW=1
    DOWNLOAD_METHOD="existing-qcow2-resume"
    PASS "Resume point found: $QCOW ($((QCOW_EXISTING_BYTES / 1024 / 1024)) MB)"
    INFO "Skipping SSH/Glance download and raw->qcow2 conversion; resuming at Windows repair stage."
  fi
elif [ -s "$IMG_PATH" ] && [ -s "${IMG_PATH}.complete" ]; then
  IMG_EXISTING_BYTES=$(stat -c%s "$IMG_PATH" 2>/dev/null || echo 0)
  IMG_COMPLETE_BYTES=$(awk -F= '$1 == "bytes" {print $2; exit}' "${IMG_PATH}.complete" 2>/dev/null || echo 0)
  if [ "${IMG_EXISTING_BYTES:-0}" -ge 1048576 ] \
     && [ "${IMG_COMPLETE_BYTES:-0}" -ge 1048576 ] \
     && [ "$IMG_EXISTING_BYTES" -eq "$IMG_COMPLETE_BYTES" ]; then
    RESUME_FROM_IMG=1
    IMG_SIZE="$IMG_EXISTING_BYTES"
    DOWNLOAD_METHOD="existing-raw-img-resume"
    PASS "Raw image resume point found: $IMG_PATH ($((IMG_EXISTING_BYTES / 1024 / 1024)) MB)"
    INFO "Skipping SSH/Glance download; resuming at raw->qcow2 conversion."
  else
    INFO "Found raw image plus completion marker, but byte counts do not match; ignoring raw resume candidate."
    INFO "Raw bytes=${IMG_EXISTING_BYTES:-0}, marker bytes=${IMG_COMPLETE_BYTES:-0}"
  fi
fi
if [ "$RESUME_MODE" != "off" ] && [ "$RESUME_FROM_QCOW" -ne 1 ] && [ "$RESUME_FROM_IMG" -ne 1 ]; then
  INFO "Resume mode: ON, but no valid qcow2/raw resume point was found for $BASE_LABEL."
  [ -n "$RESUME_SCAN_NOTE" ] && INFO "$RESUME_SCAN_NOTE"
fi

if [ "${OS_FAMILY:-}" = "windows" ] || echo "${SERVER_NAME:-} ${LABEL:-}" | grep -qi "windows"; then
  validate_virtio_iso_preflight || exit $?
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 1b: Check SSH first — skip snapshot entirely if SSH is reachable
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$RESUME_FROM_QCOW" -eq 0 ] && [ "$RESUME_FROM_IMG" -eq 0 ]; then
step_start "1b" "Checking Windows SSH availability (public IP + ServiceNet)"
_ssh_check_ip=""
if nc -z -w 8 "$SERVER_IP" 22 2>/dev/null; then
  _ssh_check_ip="$SERVER_IP"
elif [ -n "$WIN_SNET_IP" ] && nc -z -w 8 "$WIN_SNET_IP" 22 2>/dev/null; then
  _ssh_check_ip="$WIN_SNET_IP"
  step_progress "SSH accessible via ServiceNet ($WIN_SNET_IP)"
fi
if [ -n "$_ssh_check_ip" ]; then
  WIN_SSH_IP="$_ssh_check_ip"
  PASS "SSH port 22 open on $WIN_SSH_IP"
  SSH_DISK_METHOD=1
  step_done "OK — SSH available, will skip OSPC snapshot"
else
  step_progress "SSH not reachable — will create OSPC snapshot"
  step_done "DONE"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 1: Create OSPC Snapshot (only if SSH not available — Glance fallback path)
# ═══════════════════════════════════════════════════════════════════════════════
SNAP_ID=""
_NOVA_URL=""
_GLANCE_URL=""
OS_TOKEN=""
if [ "${SSH_DISK_METHOD:-0}" -eq 0 ]; then
  step_start "1" "OSPC authentication + server discovery + snapshot creation"
  step_progress "Authenticating to OSPC..."
  source /tmp/ospc2flex_ospc.sh

  # Auth via RAX Identity v2 curl (same method as ospcscan.py — no openstack CLI needed)
  _OSPC_AUTH=$(curl -s -X POST "https://identity.api.rackspacecloud.com/v2.0/tokens" \
    -H "Content-Type: application/json" \
    -d "{\"auth\":{\"RAX-KSKEY:apiKeyCredentials\":{\"username\":\"${OS_USERNAME}\",\"apiKey\":\"${OS_API_KEY:-$OS_PASSWORD}\"},\"tenantId\":\"${OS_TENANT_ID:-$OS_PROJECT_ID}\"}}" 2>/dev/null)
  OS_TOKEN=$(echo "$_OSPC_AUTH" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['access']['token']['id'])" 2>/dev/null || true)
  _NOVA_URL=$(echo "$_OSPC_AUTH" | python3 -c "
import sys,json; d=json.load(sys.stdin)
region='${OS_REGION_NAME:-IAD}'.upper()
for s in d['access']['serviceCatalog']:
    if s['type']=='compute':
        for e in s['endpoints']:
            if e.get('region','').upper()==region: print(e['publicURL']); break
" 2>/dev/null || true)
  export OS_TOKEN
  export OS_AUTH_TYPE=token

  if [ -z "$OS_TOKEN" ] || [ -z "$_NOVA_URL" ]; then
    FAIL "OSPC auth failed — check OS_USERNAME/OS_API_KEY/OS_TENANT_ID in /tmp/ospc2flex_ospc.sh"
    step_done "FAILED"
    exit 1
  fi
  step_progress "OSPC auth OK — Nova: $_NOVA_URL"

  SNAP_NAME="${LABEL}-snap-$(date +%Y%m%d%H%M)"

  # Find server via Nova API directly (same as ospcscan.py)
  step_progress "Discovering server: $SERVER_NAME ($SERVER_IP)"
  _SERVERS=$(curl -s -H "X-Auth-Token: $OS_TOKEN" "$_NOVA_URL/servers/detail?limit=1000" 2>/dev/null)
  SERVER_ID=$(echo "$_SERVERS" | python3 -c "
import sys,json,os
d=json.load(sys.stdin)
ip='${SERVER_IP}'; nm='${SERVER_NAME}'.lower()
for s in d.get('servers',[]):
    for nets in s.get('addresses',{}).values():
        for a in nets:
            if a.get('addr','')==ip: print(s['id']); sys.exit(0)
for s in d.get('servers',[]):
    if s.get('name','').lower()==nm: print(s['id']); sys.exit(0)
" 2>/dev/null || true)

  if [ -z "$SERVER_ID" ]; then
    FAIL "No server found for IP $SERVER_IP / name $SERVER_NAME in OSPC region ${OS_REGION_NAME:-IAD}"
    step_done "FAILED"
    exit 1
  fi
  step_progress "Server found: $SERVER_ID"

  # Wait for any in-progress task to finish
  step_progress "Checking server task state..."
  for i in $(seq 1 30); do
    _SDETAIL=$(curl -s -H "X-Auth-Token: $OS_TOKEN" "$_NOVA_URL/servers/$SERVER_ID" 2>/dev/null)
    TASK_STATE=$(echo "$_SDETAIL" | python3 -c "import sys,json; print(json.load(sys.stdin).get('server',{}).get('OS-EXT-STS:task_state') or 'none')" 2>/dev/null || echo "none")
    [ "$TASK_STATE" = "None" ] || [ "$TASK_STATE" = "none" ] && break
    step_progress "  Task state: $TASK_STATE (attempt $i/30)"
    sleep 30
  done

  # Check for existing usable snapshot via Glance API
  step_progress "Checking Glance for existing snapshots..."
  _GLANCE_URL=$(echo "$_OSPC_AUTH" | python3 -c "
import sys,json; d=json.load(sys.stdin)
region='${OS_REGION_NAME:-IAD}'.upper()
for s in d['access']['serviceCatalog']:
    if s['type']=='image':
        for e in s['endpoints']:
            if e.get('region','').upper()==region: print(e.get('publicURL','')); break
" 2>/dev/null || true)
  SNAP_ID=""
  if [ -n "$_GLANCE_URL" ]; then
    SNAP_ID=$(curl -s -H "X-Auth-Token: $OS_TOKEN" "$_GLANCE_URL/v2/images?name=${LABEL}-snap&limit=5" 2>/dev/null \
      | python3 -c "import sys,json; imgs=json.load(sys.stdin).get('images',[]); [print(i['id']) for i in imgs if i.get('status')=='active']" 2>/dev/null | head -1 || true)
  fi
  if [ -n "$SNAP_ID" ]; then
    PASS "Reusing existing active snapshot: $SNAP_ID"
    step_done "OK"
  else
    # Create snapshot via Nova createImage action
    step_progress "Creating snapshot $SNAP_NAME..."
    curl -s -X POST -H "X-Auth-Token: $OS_TOKEN" -H "Content-Type: application/json" \
      "$_NOVA_URL/servers/$SERVER_ID/action" \
      -d "{\"createImage\":{\"name\":\"$SNAP_NAME\",\"metadata\":{}}}" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin))" 2>/dev/null || true

    # Poll Glance until active
    step_progress "Waiting for snapshot to become active..."
    for i in $(seq 1 90); do
      sleep 10
      if [ -n "$_GLANCE_URL" ]; then
        SNAP_ID=$(curl -s -H "X-Auth-Token: $OS_TOKEN" "$_GLANCE_URL/v2/images?name=${SNAP_NAME}&limit=5" 2>/dev/null \
          | python3 -c "import sys,json; imgs=json.load(sys.stdin).get('images',[]); [print(i['id']) for i in imgs if i.get('status')=='active']" 2>/dev/null | head -1 || true)
        [ -n "$SNAP_ID" ] && { step_progress "Snapshot active: $SNAP_ID"; break; }
        _SNAP_STATUS=$(curl -s -H "X-Auth-Token: $OS_TOKEN" "$_GLANCE_URL/v2/images?name=${SNAP_NAME}&limit=5" 2>/dev/null \
          | python3 -c "import sys,json; imgs=json.load(sys.stdin).get('images',[]); print(imgs[0].get('status','waiting') if imgs else 'waiting')" 2>/dev/null || echo "waiting")
        step_progress "  Snapshot status: $_SNAP_STATUS ($((i*10))s elapsed)"
      fi
    done
    step_done "OK"
  fi

  if [ -z "$SNAP_ID" ]; then
    FAIL "Failed to create/find snapshot for '$SERVER_NAME'"
    step_done "FAILED"
    exit 1
  fi
fi  # end SSH_DISK_METHOD==0 block

# ═══════════════════════════════════════════════════════════════════════════════
# Step 1b (continued): WinRM bootstrap if SSH still not available
# ═══════════════════════════════════════════════════════════════════════════════
if [ "${SSH_DISK_METHOD:-0}" -eq 0 ] && [ -n "$WIN_PASSWORD" ]; then
  # Probe for WinRM — prefer ServiceNet IP (always accessible from OSPC network),
  # fall back to public IP. Try HTTP (5985) then HTTPS (5986).
  _WINRM_IP=""
  _WINRM_PORT=""
  _WINRM_SCHEME="http"
  for _candidate_ip in ${WIN_SNET_IP:-} "$SERVER_IP"; do
    [ -z "$_candidate_ip" ] && continue
    for _candidate_port in 5985 5986; do
      if nc -z -w 8 "$_candidate_ip" "$_candidate_port" 2>/dev/null; then
        _WINRM_IP="$_candidate_ip"
        _WINRM_PORT="$_candidate_port"
        [ "$_candidate_port" -eq 5986 ] && _WINRM_SCHEME="https"
        break 2
      fi
    done
  done

  if [ -z "$_WINRM_IP" ]; then
    WARN "WinRM (5985/5986) not reachable on ${WIN_SNET_IP:+$WIN_SNET_IP or }$SERVER_IP — cannot bootstrap OpenSSH; will use Glance fallback"
  else
    INFO "SSH not open; bootstrapping OpenSSH via WinRM ${_WINRM_SCHEME}://${_WINRM_IP}:${_WINRM_PORT}..."
    python3 -c "import winrm" 2>/dev/null \
      || python3 -m pip install --quiet pywinrm requests_ntlm 2>/dev/null \
      || WARN "pywinrm install failed — WinRM bootstrap may fail"

    JH_PUBKEY=""
    for _kf in ~/.ssh/id_rsa.pub ~/.ssh/id_ed25519.pub ~/.ssh/id_ecdsa.pub; do
      [ -f "$_kf" ] && { JH_PUBKEY=$(cat "$_kf"); break; }
    done

    _WINRM_PY=$(mktemp /tmp/ospc2flex_winrm_XXXXXX.py)
    cat > "$_WINRM_PY" <<'WINRM_SCRIPT'
import sys, winrm

ip, port, scheme, user, password = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
pubkey = sys.argv[6] if len(sys.argv) > 6 else ""

# PowerShell heredoc — use @'...'@ (here-string) to avoid all escaping issues
PS_BOOTSTRAP = r"""
$ErrorActionPreference = 'Stop'
$pub = "PUBKEY_PLACEHOLDER"

# Install OpenSSH if missing (try built-in capability, then GitHub release from jumphost HTTP)
if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
    $cap = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction SilentlyContinue
    if ($cap -and $cap.State -eq 'NotPresent') {
        Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction SilentlyContinue
    }
}
if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
    # Fallback: download from jumphost HTTP server (ServiceNet)
    $jh = "JUMPHOST_SNET_IP"
    Invoke-WebRequest -Uri "http://${jh}:8080/OpenSSH-Win64.zip" -OutFile 'C:\Windows\Temp\OpenSSH-Win64.zip' -UseBasicParsing
    Expand-Archive -Path 'C:\Windows\Temp\OpenSSH-Win64.zip' -DestinationPath 'C:\Program Files\' -Force
    & 'C:\Program Files\OpenSSH-Win64\install-sshd.ps1'
    Write-Output "[WinRM] OpenSSH installed from jumphost"
}

# Start and persist sshd
$attempts = 0
while ($attempts -lt 6) {
    try { Start-Service sshd; Set-Service -Name sshd -StartupType Automatic; break }
    catch { $attempts++; Start-Sleep 5 }
}
Write-Output "[WinRM] sshd started"

# Firewall rule for port 22
if (-not (Get-NetFirewallRule -Name sshd -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH (ospc2flex)' `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    Write-Output "[WinRM] Firewall rule added"
}

# Set PowerShell as default SSH shell (with correct path)
$psExe = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
if (Test-Path $psExe) {
    if (-not (Test-Path 'HKLM:\SOFTWARE\OpenSSH')) { New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null }
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value $psExe
    Write-Output "[WinRM] Default shell = PowerShell"
}

# Write disk dump script (here-string avoids all escaping)
$dumpScript = @'
$drive = [IO.File]::OpenRead('\\.\PhysicalDrive0')
$stdout = [Console]::OpenStandardOutput()
$buf = New-Object byte[] 4194304
while (($n = $drive.Read($buf, 0, $buf.Length)) -gt 0) { $stdout.Write($buf, 0, $n) }
$drive.Close()
$stdout.Flush()
'@
Set-Content -Path 'C:\Windows\Temp\ospc2flex_diskdump.ps1' -Value $dumpScript -Encoding ascii
Write-Output "[WinRM] Disk dump script written"

# Install SSH authorized key in home dir with strict ACL
if ($pub -ne '') {
    $homeSSH = 'C:\Users\Administrator\.ssh'
    if (-not (Test-Path $homeSSH)) { New-Item -ItemType Directory -Path $homeSSH | Out-Null }
    Set-Content -Path "$homeSSH\authorized_keys" -Value $pub -Encoding ascii
    $fa = New-Object Security.AccessControl.FileSecurity
    $fa.SetAccessRuleProtection($true,$false)
    $fa.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule('NT AUTHORITY\SYSTEM','FullControl','None','None','Allow')))
    $fa.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule('BUILTIN\Administrators','FullControl','None','None','Allow')))
    Set-Acl "$homeSSH\authorized_keys" $fa
    Write-Output "[WinRM] Authorized key installed"
}
Write-Output "[WinRM] Bootstrap complete"
"""

try:
    s = winrm.Session(
        f"{scheme}://{ip}:{port}/wsman",
        auth=(user, password),
        transport="ntlm",
        server_cert_validation="ignore",
        read_timeout_sec=360,
        operation_timeout_sec=300,
    )
    import socket
    jh_snet = ""
    try:
        jh_snet = socket.gethostbyname(socket.gethostname())
    except Exception:
        pass
    ps = PS_BOOTSTRAP.replace("PUBKEY_PLACEHOLDER", pubkey).replace("JUMPHOST_SNET_IP", jh_snet)
    r = s.run_ps(ps)
    out = r.std_out.decode("utf-8", errors="replace").strip()
    err = r.std_err.decode("utf-8", errors="replace").strip()
    for line in out.splitlines(): print(line)
    if err and "CLIXML" not in err:
        for line in err.splitlines(): print(f"[STDERR] {line}", file=sys.stderr)
    if r.status_code != 0:
        print(f"[ERROR] WinRM PS exit {r.status_code}", file=sys.stderr); sys.exit(1)
    sys.exit(0)
except Exception as e:
    print(f"[ERROR] WinRM: {e}", file=sys.stderr); sys.exit(1)
WINRM_SCRIPT

    set +e
    python3 "$_WINRM_PY" "$_WINRM_IP" "$_WINRM_PORT" "$_WINRM_SCHEME" "$WIN_USER" "$WIN_PASSWORD" "$JH_PUBKEY"
    _WINRM_RC=$?
    set -e
    rm -f "$_WINRM_PY"

    if [ "$_WINRM_RC" -eq 0 ]; then
      PASS "WinRM OpenSSH bootstrap complete"
      log "  Waiting for SSH port 22 (up to 120s)..."
      _SSH_UP=0
      for _i in $(seq 1 24); do
        if nc -z -w 5 "$SERVER_IP" 22 2>/dev/null; then
          WIN_SSH_IP="$SERVER_IP"
          PASS "SSH port 22 open after $((_i * 5))s"
          _SSH_UP=1; break
        elif [ -n "$WIN_SNET_IP" ] && nc -z -w 5 "$WIN_SNET_IP" 22 2>/dev/null; then
          WIN_SSH_IP="$WIN_SNET_IP"
          PASS "SSH port 22 open via ServiceNet after $((_i * 5))s"
          _SSH_UP=1; break
        fi
        sleep 5
      done
      [ "$_SSH_UP" -eq 1 ] && SSH_DISK_METHOD=1 \
        || WARN "SSH port 22 did not open within 120s — will use Glance fallback"
    else
      WARN "WinRM bootstrap failed (rc=$_WINRM_RC) — will use Glance fallback"
    fi
  fi
elif [ "${SSH_DISK_METHOD:-0}" -eq 0 ]; then
  WARN "SSH not available and --windows-password not provided — using Glance fallback only"
fi
else
  INFO "Resume mode: SSH/WinRM/snapshot discovery skipped because a disk image resume point already exists."
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 2: Download Windows disk image
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$RESUME_FROM_QCOW" -eq 0 ] && [ "$RESUME_FROM_IMG" -eq 0 ]; then
step_start "2" "Downloading Windows disk image (SSH or Glance fallback)"
rm -f "$IMG_PATH"

if [ "${SSH_DISK_METHOD:-0}" -eq 1 ]; then
  step_progress "Using SSH direct disk read via PowerShell"
  INFO "Large Windows disks: 30–120+ minutes. Progress logged every 60s."
  # Use the SSH IP resolved in Step 1b (ServiceNet preferred when public port 22 is blocked)
  _SSH_TARGET="${WIN_USER}@${WIN_SSH_IP:-$SERVER_IP}"
  step_progress "SSH target: $_SSH_TARGET"

  WIN_DISK_BYTES=$(ssh -i ~/.ssh/id_rsa \
      -o StrictHostKeyChecking=no -o BatchMode=yes \
      -o LogLevel=ERROR -o ConnectTimeout=30 \
      "$_SSH_TARGET" \
      'powershell -NonInteractive -Command "(Get-Disk -Number 0).Size"' 2>/dev/null \
    | tr -d '[:space:]' || echo 0)
  INFO "PhysicalDrive0: $((WIN_DISK_BYTES / 1024 / 1024 / 1024)) GiB reported by Windows"

  # Heartbeat while SSH dd runs
  (while [ -f "/tmp/winmig_hb_active_${LABEL}" ]; do
     sleep 60
     _sz=$(stat -c%s "$IMG_PATH" 2>/dev/null || echo 0)
     step_progress "SSH transfer progress: $((${_sz} / 1024 / 1024)) MB on disk"
   done) &
  _HB_PID=$!
  : > "/tmp/winmig_hb_active_${LABEL}"

  set +e
  ssh -i ~/.ssh/id_rsa \
      -o StrictHostKeyChecking=no -o BatchMode=yes \
      -o LogLevel=ERROR \
      -o ServerAliveInterval=30 -o ServerAliveCountMax=20 \
      "$_SSH_TARGET" \
      'powershell -NonInteractive -File C:\Windows\Temp\ospc2flex_diskdump.ps1' \
  | dd of="$IMG_PATH" bs=4M iflag=fullblock 2>&1
  _SSH_RC=${PIPESTATUS[0]}
  set -e

  rm -f "/tmp/winmig_hb_active_${LABEL}"
  kill "$_HB_PID" 2>/dev/null || true

  IMG_SIZE=$(stat -c%s "$IMG_PATH" 2>/dev/null || echo 0)
  if [ "$_SSH_RC" -eq 0 ] && [ "${IMG_SIZE:-0}" -ge 1048576 ]; then
    PASS "Downloaded via SSH/PowerShell: $((IMG_SIZE / 1024 / 1024)) MB"
    DOWNLOAD_METHOD="ssh-powershell-disk-read"
    printf 'bytes=%s\nmethod=%s\ncompleted_at=%s\n' "$IMG_SIZE" "$DOWNLOAD_METHOD" "$(date -Is)" > "${IMG_PATH}.complete"
    step_done "OK"
    STEP2_DONE=1
  else
    WARN "SSH disk read failed (rc=$_SSH_RC size=${IMG_SIZE}B) — falling back to Glance"
    rm -f "$IMG_PATH"
    IMG_SIZE=0
    step_progress "SSH failed, trying Glance fallback..."
  fi
fi

if [ "${IMG_SIZE:-0}" -lt 1048576 ]; then
  step_progress "Using Glance snapshot download (Cloud Files bridge / Classic Glance)"
  INFO "Large Windows disks often take 30–120+ minutes — heartbeat + size logged every 60s."
  rm -f "$IMG_PATH"

  if [ -z "${SNAP_ID:-}" ]; then
    step_progress "No snapshot ID from Step 1 (SSH-first path); creating on-demand snapshot for Glance fallback..."
    if [ -f /tmp/ospc2flex_ospc.sh ]; then
      # shellcheck disable=SC1091
      source /tmp/ospc2flex_ospc.sh
    fi
    export OS_INTERFACE=public OS_IDENTITY_API_VERSION=2
    SERVER_ID_FALLBACK="$(openstack server list -f value -c ID -c Name 2>/dev/null | awk -v ip="$SERVER_IP" -v nm="$SERVER_NAME" 'tolower($0) ~ tolower(nm) {print $1; exit}')"
    if [ -z "$SERVER_ID_FALLBACK" ] && [ -n "$SERVER_IP" ]; then
      SERVER_ID_FALLBACK="$(openstack server list -f json 2>/dev/null | python3 -c 'import json,sys; t=sys.argv[1]; rows=json.load(sys.stdin); 
for r in rows:
    blob=" ".join(str(v) for v in r.values())
    if t and t in blob:
        print(r.get("ID","")); break' "$SERVER_IP" 2>/dev/null || true)"
    fi
    if [ -z "$SERVER_ID_FALLBACK" ]; then
      FAIL "Glance fallback failed: unable to resolve source server ID for snapshot creation"
      step_done "FAILED"
      exit 1
    fi
    SNAP_NAME_FALLBACK="${BASE_LABEL}-snap-$(date +%Y%m%d%H%M%S)"
    openstack server image create --name "$SNAP_NAME_FALLBACK" "$SERVER_ID_FALLBACK" --wait >/dev/null 2>&1 || true
    SNAP_ID="$(openstack image list --name "$SNAP_NAME_FALLBACK" -f value -c ID 2>/dev/null | head -1 || true)"
    if [ -z "$SNAP_ID" ]; then
      FAIL "Glance fallback failed: on-demand snapshot creation did not return image ID"
      step_done "FAILED"
      exit 1
    fi
    step_progress "On-demand snapshot ready: $SNAP_ID"
  fi

# OSPC Rackspace Public Cloud only exposes PUBLIC Glance endpoints per region.
# Using OS_INTERFACE=internal causes `openstack image save` to error with
# "internal endpoint for image service in <region> not found". Force public.
export OS_INTERFACE=public
OS_USERNAME="${OS_USERNAME:-}"
OS_PASSWORD="${OS_PASSWORD:-}"
OS_REGION_NAME="${OS_REGION_NAME:-IAD}"
export OS_USERNAME OS_PASSWORD OS_REGION_NAME

# If Step 1 was skipped (SSH path), credentials may not be loaded yet.
if [ -z "${OS_USERNAME:-}" ] || { [ -z "${OS_PASSWORD:-}" ] && [ -z "${OS_API_KEY:-}" ]; }; then
  if [ -f /tmp/ospc2flex_ospc.sh ]; then
    # shellcheck disable=SC1091
    source /tmp/ospc2flex_ospc.sh
    OS_USERNAME="${OS_USERNAME:-}"
    OS_PASSWORD="${OS_PASSWORD:-${OS_API_KEY:-}}"
    OS_REGION_NAME="${OS_REGION_NAME:-IAD}"
    export OS_USERNAME OS_PASSWORD OS_REGION_NAME
  fi
fi

_refresh_ospc_token() {
  OS_TOKEN=$(openstack token issue -f value -c id 2>/dev/null || true)
  if [ -z "$OS_TOKEN" ] && [ -n "$OS_USERNAME" ] && [ -n "$OS_PASSWORD" ]; then
    _AUTH=$(curl -s -X POST "${OS_AUTH_URL:-https://identity.api.rackspacecloud.com/v2.0/}tokens" \
      -H "Content-Type: application/json" \
      -d "{\"auth\":{\"RAX-KSKEY:apiKeyCredentials\":{\"username\":\"$OS_USERNAME\",\"apiKey\":\"$OS_PASSWORD\"}}}" 2>/dev/null || true)
    OS_TOKEN=$(echo "$_AUTH" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['access']['token']['id'])" 2>/dev/null || true)
  fi
  # Strip whitespace/CR that would make curl -H "X-Auth-Token: ..." malformed.
  OS_TOKEN=$(printf '%s' "$OS_TOKEN" | tr -d '[:space:]')
}

_region_short() {
  # lowercase region name with trailing digits stripped (e.g. "IAD" -> "iad",
  # "DFW" -> "dfw", "IAD3" -> "iad"). Defaults to "iad" when unset.
  local r
  r=$(echo "$OS_REGION_NAME" | tr '[:upper:]' '[:lower:]' | tr -d '0-9')
  [ -z "$r" ] && r="iad"
  printf '%s' "$r"
}

_glance_public_base() {
  # Classic (public internet) Glance: https://<region>.images.api.rackspacecloud.com
  printf 'https://%s.images.api.rackspacecloud.com' "$(_region_short)"
}

_resolve_glance_base() {
  # Classic Glance only — public catalog URL, then predictable public hostname.
  local out u
  u=""
  if out=$(openstack catalog show image -f json 2>/dev/null); then
    u=$(OPENSTACK_JSON="$out" python3 - <<'PY' 2>/dev/null || true
import json, os
d = json.loads(os.environ["OPENSTACK_JSON"])
eps = d.get("endpoints") or []
for e in eps:
    if str(e.get("interface", "")).lower() == "public" and e.get("url"):
        print(str(e["url"]).rstrip("/"))
        raise SystemExit(0)
print("")
PY
)
  fi
  if [ -z "$u" ]; then
    u=$(openstack endpoint list --service image --interface public -f value -c URL 2>/dev/null | head -1 | sed 's|/$||' || true)
  fi
  if [ -z "$u" ]; then
    u=$(_glance_public_base)
    WARN "Catalog/endpoints empty — using public Glance base: $u (OS_REGION_NAME=$OS_REGION_NAME)"
  fi
  printf '%s' "$u"
}

_url_host() {
  # Extract host from URL like https://host/path
  printf '%s' "$1" | sed -E 's#^[a-zA-Z]+://([^/:]+).*$#\1#'
}

_host_resolves() {
  local h="$1"
  [ -z "$h" ] && return 1
  # If host is already a literal IPv4/IPv6, treat as usable endpoint.
  if echo "$h" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[0-9a-fA-F:]+$'; then
    return 0
  fi
  getent hosts "$h" >/dev/null 2>&1
}

_refresh_ospc_token
if [ -z "${OS_TOKEN:-}" ]; then
  FAIL "No OSPC token for Glance download"
  exit 1
fi

OS_IMAGE_URL=$(_resolve_glance_base)
# Defensive: strip any stray whitespace / CR / log contamination so curl never
# sees a malformed URL (curl ≥7.85 rejects URLs with whitespace).
OS_IMAGE_URL=$(printf '%s' "$OS_IMAGE_URL" | tr -d '[:space:]')

# Build ordered list of Glance base URLs to try (Classic / public only).
PUB_BASE=$(_glance_public_base)
GLANCE_BASES=""
for b in "$OS_IMAGE_URL" "$PUB_BASE"; do
  b=$(printf '%s' "$b" | tr -d '[:space:]')
  [ -z "$b" ] && continue
  _h=$(_url_host "$b")
  if ! _host_resolves "$_h"; then
    WARN "Glance host unresolved on jumphost: $_h (base=$b)"
    continue
  fi
  case " $GLANCE_BASES " in
    *" $b "*) : ;;
    *) GLANCE_BASES="$GLANCE_BASES $b" ;;
  esac
done
GLANCE_BASES=$(echo "$GLANCE_BASES" | sed -E 's/^ +//')
INFO "Glance bases (try order): $GLANCE_BASES"
if [ -z "$GLANCE_BASES" ]; then
  WARN "No resolvable endpoint from computed list; forcing public base fallback"
  GLANCE_BASES="$PUB_BASE"
fi
DL_URL="$OS_IMAGE_URL/v2/images/$SNAP_ID/file"
DL_URL=$(printf '%s' "$DL_URL" | tr -d '[:space:]')
INFO "Glance GET (Classic): $DL_URL"

# Start a heartbeat watcher that monitors $IMG_PATH size while any download
# method is running. This replaces the per-method heartbeat loops.
_start_heartbeat() {
  (
    n=0
    while [ -f "/tmp/winmig_hb_active_${LABEL}" ]; do
      sleep 60
      n=$((n + 1))
      sz=$(stat -c%s "$IMG_PATH" 2>/dev/null || echo 0)
      log "  … download heartbeat #${n} — $((sz / 1024 / 1024)) MiB on disk (still running)"
    done
  ) &
  echo $! > "/tmp/winmig_hb_pid_${LABEL}"
}
_stop_heartbeat() {
  rm -f "/tmp/winmig_hb_active_${LABEL}" 2>/dev/null || true
  if [ -f "/tmp/winmig_hb_pid_${LABEL}" ]; then
    kill "$(cat "/tmp/winmig_hb_pid_${LABEL}" 2>/dev/null)" 2>/dev/null || true
    rm -f "/tmp/winmig_hb_pid_${LABEL}" 2>/dev/null || true
  fi
}

# One curl attempt to $1=base URL. Returns 0 on success (file ≥1MB).
_curl_download_from() {
  local base="$1" attempt="$2"
  local url log
  url="${base}/v2/images/${SNAP_ID}/file"
  url=$(printf '%s' "$url" | tr -d '[:space:]')
  log="/tmp/winmig_curl_${LABEL}_${attempt}_$(echo "$base" | sed 's|[^a-zA-Z0-9]|_|g').log"
  rm -f "$IMG_PATH"
  INFO "  → curl $url"
  : > "/tmp/winmig_hb_active_${LABEL}"
  _start_heartbeat
  set +e
  curl -fSL --connect-timeout 30 --retry 2 --retry-delay 10 \
    -H 'Expect:' \
    -H 'Accept: application/octet-stream' \
    -H "X-Auth-Token: $OS_TOKEN" \
    -A 'ospc2flex/1.0 (+jumphost-migrator)' \
    -o "$IMG_PATH" \
    --write-out "\\nHTTP_CODE=%{http_code} SIZE=%{size_download}B TIME=%{time_total}s\\n" \
    "$url" >"$log" 2>&1
  local rc=$?
  set -e
  _stop_heartbeat
  LAST_CURL_LOG="$log"
  local sz
  sz=$(stat -c%s "$IMG_PATH" 2>/dev/null || echo 0)
  if [ "$rc" -eq 0 ] && [ "$sz" -ge 1048576 ]; then
    return 0
  fi
  WARN "  curl rc=$rc size=${sz}B log=$log — last lines:"
  # show both the curl stderr (headers/errors) AND the response body so 413
  # messages are visible
  tail -6 "$log" 2>/dev/null | while read -r _ln; do WARN "    $_ln"; done || true
  if [ -s "$IMG_PATH" ] && [ "$sz" -lt 2048 ]; then
    # small body = error payload, show it
    WARN "  error body ($sz B):"
    head -c 512 "$IMG_PATH" 2>/dev/null | sed 's/^/    /' | while read -r _ln; do WARN "$_ln"; done || true
  fi
  # Track root-cause signals so the outer loop can fail fast with a useful message.
  if grep -qi "Could not resolve host" "$log" 2>/dev/null; then
    SAW_GLANCE_DNS_FAIL=1
  fi
  if grep -qiE "HTTP_CODE=413|returned error: 413|Unable to download image: InvalidResponse" "$log" 2>/dev/null; then
    SAW_PUBLIC_413=1
  fi
  return 1
}

# One openstack image save attempt against a forced endpoint URL. Uses
# --os-image-url to bypass catalog interface selection.
_osave_download_from() {
  local base="$1" attempt="$2"
  local log
  log="/tmp/winmig_osave_${LABEL}_${attempt}_$(echo "$base" | sed 's|[^a-zA-Z0-9]|_|g').log"
  rm -f "$IMG_PATH"
  INFO "  → openstack image save $SNAP_ID (default endpoint)"
  : > "/tmp/winmig_hb_active_${LABEL}"
  _start_heartbeat
  set +e
  # Prefer plain image save first (most compatible across OpenStack clients).
  openstack image save --file "$IMG_PATH" "$SNAP_ID" >"$log" 2>&1
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    INFO "  default endpoint failed; retrying with OS_IMAGE_URL=$base"
    OS_IMAGE_URL="$base" openstack image save --file "$IMG_PATH" "$SNAP_ID" >"$log" 2>&1
    rc=$?
  fi
  set -e
  _stop_heartbeat
  local sz
  sz=$(stat -c%s "$IMG_PATH" 2>/dev/null || echo 0)
  if [ "$rc" -eq 0 ] && [ "$sz" -ge 1048576 ]; then
    return 0
  fi
  WARN "  openstack image save rc=$rc size=${sz}B log=$log — key error lines:"
  grep -iE "error|fail|forbidden|unauthorized|not found|unrecognized|invalid|endpoint|timeout" "$log" 2>/dev/null | tail -10 | while read -r _ln; do WARN "    $_ln"; done || true
  tail -6 "$log" 2>/dev/null | while read -r _ln; do WARN "    $_ln"; done || true
  return 1
}

# Master waterfall: for each base URL, try openstack CLI then curl.
# First success wins.
_try_download_methods() {
  local attempt="$1"
  local base

  for base in $GLANCE_BASES; do
    INFO "Attempt ${attempt}: trying Glance base: $base"

    # Method A: openstack image save (pinned to this base)
    if _osave_download_from "$base" "$attempt"; then
      _sz=$(stat -c%s "$IMG_PATH" 2>/dev/null || echo 0)
      DOWNLOAD_METHOD="openstack image save via $base"
      PASS "Downloaded via $DOWNLOAD_METHOD: $((_sz / 1024 / 1024))MB (attempt $attempt)"
      return 0
    fi
    if [ -f "/tmp/winmig_osave_${LABEL}_${attempt}_$(echo "$base" | sed 's|[^a-zA-Z0-9]|_|g').log" ]; then
      _oslog="/tmp/winmig_osave_${LABEL}_${attempt}_$(echo "$base" | sed 's|[^a-zA-Z0-9]|_|g').log"
      if grep -qiE "Unable to download image: InvalidResponse|HTTP 413|returned error: 413" "$_oslog" 2>/dev/null; then
        SAW_PUBLIC_413=1
      fi
      if grep -qi "Could not resolve host" "$_oslog" 2>/dev/null; then
        SAW_GLANCE_DNS_FAIL=1
      fi
    fi

    # Method B: curl direct with X-Auth-Token
    if _curl_download_from "$base" "$attempt"; then
      _sz=$(stat -c%s "$IMG_PATH" 2>/dev/null || echo 0)
      DOWNLOAD_METHOD="curl via $base"
      PASS "Downloaded via $DOWNLOAD_METHOD: $((_sz / 1024 / 1024))MB (attempt $attempt)"
      return 0
    fi
  done

  return 1
}

LAST_CURL_LOG="${LAST_CURL_LOG:-}"
if [ "${IMG_SIZE:-0}" -lt 1048576 ] && [ -x /tmp/ospc2flex_glance_bridge.sh ]; then
  INFO "Trying Classic Glance + Cloud Files bridge before legacy Windows downloader..."
  BRIDGE_RC=0
  bash /tmp/ospc2flex_glance_bridge.sh download \
      --ospc-openrc "$OSPC_CREDS" \
      --image-id "$SNAP_ID" \
      --dest "$IMG_PATH" \
      --container ospc2flex-export \
      --prefer-cloud-files \
      --retries 3 \
      --retry-wait 15 \
      --min-bytes 1048576 || BRIDGE_RC=$?
  if [ "$BRIDGE_RC" -eq 0 ]; then
    IMG_SIZE=$(stat -c%s "$IMG_PATH" 2>/dev/null || echo 0)
    DOWNLOAD_METHOD="classic-glance-cloud-files-bridge"
    PASS "Downloaded via $DOWNLOAD_METHOD: $((IMG_SIZE / 1024 / 1024))MB"
    printf 'bytes=%s\nmethod=%s\ncompleted_at=%s\n' "$IMG_SIZE" "$DOWNLOAD_METHOD" "$(date -Is)" > "${IMG_PATH}.complete"
  elif [ "$BRIDGE_RC" -eq 42 ]; then
    FAIL "Windows image export blocked by Rackspace licensing policy — Cloud Files export not permitted for this snapshot."
    FAIL "Contact Rackspace support to enable export for image $SNAP_ID, or migrate data at the application layer."
    exit 1
  else
    WARN "Glance bridge failed (rc=$BRIDGE_RC); attempting legacy Classic Glance waterfall as last resort"
    rm -f "$IMG_PATH"
    IMG_SIZE=0
  fi
fi

attempt=1
max_dl=5
if [ "${IMG_SIZE:-0}" -lt 1048576 ]; then
while [ "${attempt:-1}" -le "${max_dl:-5}" ]; do
  SAW_GLANCE_DNS_FAIL=0
  SAW_PUBLIC_413=0
  if _try_download_methods "$attempt"; then
    IMG_SIZE=$(stat -c%s "$IMG_PATH" 2>/dev/null || echo 0)
    printf 'bytes=%s\nmethod=%s\ncompleted_at=%s\n' "$IMG_SIZE" "$DOWNLOAD_METHOD" "$(date -Is)" > "${IMG_PATH}.complete"
    break
  fi
  if [ "$SAW_PUBLIC_413" -eq 1 ]; then
    WARN "Classic Glance returned HTTP 413; Cloud Files bridge also failed (see above). Stopping waterfall retries."
    break
  fi
  if [ "$SAW_GLANCE_DNS_FAIL" -eq 1 ]; then
    WARN "Classic Glance host could not be resolved; stopping waterfall retries."
    break
  fi
  WARN "All download methods failed on attempt $attempt/$max_dl — refreshing token and retrying..."
  _refresh_ospc_token
  if [ -z "${OS_TOKEN:-}" ]; then
    FAIL "Lost OSPC token during download retries"
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 10
done
fi

fi  # end Glance fallback block

if [ "${IMG_SIZE:-0}" -lt 1048576 ]; then
  FAIL "All download methods failed (SSH disk read + Glance). Image size: ${IMG_SIZE:-0} bytes."
  FAIL "SSH rc=${_SSH_RC:-n/a}. Last curl log: ${LAST_CURL_LOG:-none}"
  step_done "FAILED"
  exit 1
fi

PASS "Step 2 complete: Image downloaded ($((IMG_SIZE / 1024 / 1024)) MB via $DOWNLOAD_METHOD)"
if [ "${STEP2_DONE:-0}" -eq 0 ]; then
  step_done "OK"
fi
elif [ "$RESUME_FROM_IMG" -eq 1 ]; then
step_start "2" "Downloading Windows disk image (SSH or Glance fallback)"
step_progress "Existing completed raw image present; download skipped."
step_done "SKIPPED (resume from raw image)"
else
step_start "2" "Downloading Windows disk image (SSH or Glance fallback)"
step_progress "Existing qcow2 image present; download skipped."
step_done "SKIPPED (resume from qcow2)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 3: Convert to qcow2
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$RESUME_FROM_QCOW" -eq 0 ]; then
step_start "3" "Converting disk image to qcow2 format"
step_progress "Detecting image format..."
DETECTED_FMT=$(qemu-img info --output=json "$IMG_PATH" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('format','raw'))" 2>/dev/null || echo "raw")
INFO "Detected format: $DETECTED_FMT"

if [ "$DETECTED_FMT" = "qcow2" ]; then
  step_progress "Already qcow2 format — renaming"
  mv "$IMG_PATH" "$QCOW"
  PASS "Already qcow2 — renamed"
else
  step_progress "Converting raw → qcow2 (this may take 5-10 minutes)..."
  qemu-img convert -p -f "$DETECTED_FMT" -O qcow2 "$IMG_PATH" "$QCOW" 2>&1 || { FAIL "qemu-img convert failed"; step_done "FAILED"; exit 1; }
  rm -f "$IMG_PATH"
  rm -f "${IMG_PATH}.complete"
  PASS "Converted to qcow2"
fi
QCOW_SIZE=$(stat -c%s "$QCOW" 2>/dev/null || echo 0)
INFO "qcow2 size: $((QCOW_SIZE/1024/1024))MB"
step_done "OK"
else
step_start "3" "Converting disk image to qcow2 format"
QCOW_SIZE=$(stat -c%s "$QCOW" 2>/dev/null || echo 0)
INFO "Reusing existing qcow2 size: $((QCOW_SIZE/1024/1024))MB"
step_done "SKIPPED (resume from qcow2)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 4: Windows VirtIO Repair
# ═══════════════════════════════════════════════════════════════════════════════
step_start "4" "Offline VirtIO driver injection & Windows guest repair"
REPAIR_LOG="$WORK/${LABEL}.repair.log"
if [ "$OS_FAMILY" = "linux" ]; then
  if [ -f "$LINUX_REPAIR" ]; then
    set +e
    # Call the v2.5 RHEL-aware linux repair script
    rm -f "$REPAIR_LOG"
    step_progress "Running Linux repair script..."
    INFO "Repair log: $REPAIR_LOG"
    bash "$LINUX_REPAIR" --qcow2 "$QCOW" --os-type "$OS_TYPE" --force --preserve-password-auth 2>&1 | tee "$REPAIR_LOG"
    REPAIR_EXIT=$?
    set -e
    if [ "$REPAIR_EXIT" -eq 0 ]; then
      PASS "Linux repair completed successfully"
    else
      WARN "Linux repair exited with code $REPAIR_EXIT — continuing anyway"
    fi
    case "${OS_TYPE:-}" in
      centos*|rhel7*|rhel6*)
        if [ -f "$REPAIR_LOG" ] \
           && grep -q "Wrote fresh ifcfg-eth0 (no HWADDR, ONBOOT=yes, DHCP, NM_CONTROLLED=no)" "$REPAIR_LOG" \
           && grep -q "Enabled network.service" "$REPAIR_LOG"; then
          PASS "[REPAIR-LAN] CentOS/RHEL LAN markers verified"
        else
          FAIL "[REPAIR-LAN-E5] Missing CentOS/RHEL LAN markers in $REPAIR_LOG"
          exit 1
        fi
        ;;
    esac
  else
    WARN "$LINUX_REPAIR not found — skipping Linux virtio injection!"
  fi
else
  if [ -f "$WIN_REPAIR" ]; then
    set +e  # temporarily disable abort on error
    REPAIR_ARGS=(--qcow2 "$QCOW" --force)
    if [ -n "${OSPC2FLEX_WIN_NBD_DEV:-}" ]; then
      REPAIR_ARGS+=(--nbd-dev "${OSPC2FLEX_WIN_NBD_DEV}")
      INFO "Windows repair: using explicit NBD device ${OSPC2FLEX_WIN_NBD_DEV}"
    fi
    if [ "${OSPC2FLEX_WIN_PURGE_XEN:-1}" = "1" ]; then
      REPAIR_ARGS+=(--purge-xen)
      INFO "Windows repair: aggressive Xen purge enabled (default; set OSPC2FLEX_WIN_PURGE_XEN=0 to disable)"
    else
      REPAIR_ARGS+=(--no-purge-xen)
      INFO "Windows repair: Xen safe-disable mode enabled (OSPC2FLEX_WIN_PURGE_XEN=0)"
    fi
    if [ "${OSPC2FLEX_WINDOWS_MODE:-}" = "bruteforce_flex" ]; then
      REPAIR_ARGS+=(--bruteforce-flex)
      INFO "Windows repair: brute-force Flex/KVM mode (OSPC2FLEX_WINDOWS_MODE=bruteforce_flex)"
    fi
    [ "$DRY_RUN" -eq 1 ] && REPAIR_ARGS+=(--dry-run)
    # Full repair transcript (default on): OSPC2FLEX_WIN_REPAIR_DEBUG=0 to disable
    if [ "${OSPC2FLEX_WIN_REPAIR_DEBUG:-1}" != "0" ]; then
      _win_dbg="$WORK/${LABEL}.repair.debug.log"
      REPAIR_ARGS+=(--debug --debug-log "$_win_dbg")
      INFO "Windows repair debug: ${_win_dbg} (set OSPC2FLEX_WIN_REPAIR_DEBUG=0 to skip)"
    fi
    bash "$WIN_REPAIR" "${REPAIR_ARGS[@]}" 2>&1
    REPAIR_EXIT=$?
    set -e
    if [ "$REPAIR_EXIT" -eq 0 ]; then
      PASS "Windows repair completed successfully"
      step_done "OK"
    else
      FAIL "Windows repair exited with code $REPAIR_EXIT - refusing to upload an unrepaired Windows image"
      FAIL "A VM booted from an unrepaired image commonly lands in WinRE with no fixed disks visible."
      step_done "FAILED"
      exit 1
    fi
  else
    WARN "$WIN_REPAIR not found - skipping VirtIO injection"
    FAIL "Windows VM will not boot reliably on FLEX without VirtIO storage drivers."
    step_done "FAILED"
    exit 1
  fi
fi

# Step 4b validator removed by request.

# ═══════════════════════════════════════════════════════════════════════════════
# Step 5: Upload to FLEX
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$DRY_RUN" -eq 1 ]; then
  step_start "5" "Dry-run stop before FLEX upload"
  INFO "[DRY-RUN] Would upload qcow2 to FLEX Glance: $QCOW"
  INFO "[DRY-RUN] Would boot FLEX VM, assign floating IP, and run first-boot verification"
  step_done "SKIPPED (dry-run)"
  echo ""
  echo "╔════════════════════════════════════════════════════════════════════════════╗"
  echo "║                         DRY-RUN WORKFLOW COMPLETE                         ║"
  echo "╚════════════════════════════════════════════════════════════════════════════╝"
  exit 0
fi

step_start "5" "Uploading qcow2 image to FLEX Glance"
step_progress "Switching to FLEX credentials..."
OSPC_TOKEN="${OS_TOKEN:-}"
unset OS_TOKEN OS_AUTH_TYPE OS_IDENTITY_API_VERSION
source /tmp/ospc2flex_flex.sh

detect_virtual_size_bytes() {
  local img="$1"
  if ! command -v qemu-img >/dev/null 2>&1; then
    echo 0
    return 0
  fi
  qemu-img info --output json "$img" 2>/dev/null | python3 -c 'import json,sys; print(int(json.load(sys.stdin).get("virtual-size") or 0))' 2>/dev/null || echo 0
}

normalize_int() {
  local _v="${1:-}"
  _v=$(printf '%s' "$_v" | tr -cd '0-9')
  [ -n "$_v" ] && echo "$_v" || echo ""
}

resolve_target_flavor() {
  local _requested="$1"
  local _src_vcpu _src_ram _src_disk _need_disk _eff_vcpu _eff_ram
  _src_vcpu=$(normalize_int "${MIG_SRC_VCPUS:-}")
  _src_ram=$(normalize_int "${MIG_SRC_RAM_MB:-}")
  _src_disk=$(normalize_int "${MIG_SRC_DISK_GB:-}")
  _need_disk="$_src_disk"
  [ -z "$_need_disk" ] && _need_disk=$(normalize_int "${QCOW_VIRTUAL_GIB:-}")
  _eff_vcpu="${_src_vcpu:-2}"
  _eff_ram="${_src_ram:-4096}"
  [ -n "$_src_vcpu" ] && [ "$_src_vcpu" -lt 2 ] && _eff_vcpu=2
  [ -n "$_src_ram" ] && [ "$_src_ram" -lt 4096 ] && _eff_ram=4096

  if [ -n "$_requested" ] && openstack flavor show "$_requested" >/dev/null 2>&1; then
    INFO "Flavor resolved in target region: $_requested" >&2
    echo "$_requested"
    return 0
  fi
  [ -n "$_requested" ] && WARN "Requested flavor not found in target region: $_requested" >&2

  local _rows _rows_bootable _best _fallback _chosen _cid _cname _cram _cdisk _cvcpu
  _rows=$(openstack flavor list --long --format value -c ID -c Name -c RAM -c Disk -c VCPUs 2>/dev/null || true)
  if [ -z "$_rows" ]; then
    WARN "No target flavors discovered; keeping requested flavor" >&2
    echo "$_requested"
    return 0
  fi
  _rows_bootable=$(printf '%s\n' "$_rows" | awk 'NF>=5 && ($4+0) > 0')
  if [ -n "$_rows_bootable" ]; then
    _rows="$_rows_bootable"
  else
    WARN "No bootable (disk>0) flavors found; keeping zero-disk candidates" >&2
  fi
  if [ -n "$_need_disk" ]; then
    local _rows_diskfit
    _rows_diskfit=$(printf '%s\n' "$_rows" | awk -v md="$_need_disk" 'NF>=5 && ($4+0) >= md')
    if [ -n "$_rows_diskfit" ]; then
      _rows="$_rows_diskfit"
    else
      WARN "No flavor has disk >= required ${_need_disk}GiB; keeping best available disk" >&2
    fi
  fi

  _fallback=$(printf '%s\n' "$_rows" | awk '
    NF>=5 {
      id=$1; name=$2; ram=$3+0; disk=$4+0; vcpu=$5+0
      score=(vcpu*1000000000)+(ram*1000000)+disk
      if (!seen || score < best) { seen=1; best=score; out=id"|"name"|"ram"|"disk"|"vcpu }
    }
    END { if (seen) print out }
  ')
  _best=$(printf '%s\n' "$_rows" | awk -v sv="$_eff_vcpu" -v sr="$_eff_ram" '
    NF>=5 {
      id=$1; name=$2; ram=$3+0; disk=$4+0; vcpu=$5+0
      if (vcpu>=sv && ram>=sr) {
        score=((vcpu-sv)*1000000000)+((ram-sr)*1000000)+disk
        if (!seen || score < best) { seen=1; best=score; out=id"|"name"|"ram"|"disk"|"vcpu }
      }
    }
    END { if (seen) print out }
  ')

  _chosen="${_best:-$_fallback}"
  _cid=$(echo "$_chosen" | cut -d'|' -f1)
  _cname=$(echo "$_chosen" | cut -d'|' -f2)
  _cram=$(echo "$_chosen" | cut -d'|' -f3)
  _cdisk=$(echo "$_chosen" | cut -d'|' -f4)
  _cvcpu=$(echo "$_chosen" | cut -d'|' -f5)
  if [ -n "$_cid" ]; then
    INFO "Flavor auto-pick: $_cid name=${_cname:-?} vcpu=${_cvcpu:-?} ram=${_cram:-?} disk=${_cdisk:-?} src=${_src_vcpu:-?}/${_src_ram:-?}/${_src_disk:-?} req=${_eff_vcpu:-?}/${_eff_ram:-?}/${_need_disk:-?}" >&2
    echo "$_cid"
    return 0
  fi

  WARN "Could not auto-pick flavor; keeping requested value" >&2
  echo "$_requested"
}
resolve_target_network() {
  local _requested="$1"
  if [ -n "$_requested" ] && openstack network show "$_requested" >/dev/null 2>&1; then
    INFO "Network resolved in target region: $_requested" >&2
    echo "$_requested"
    return 0
  fi
  [ -n "$_requested" ] && WARN "Requested network not found in target region: $_requested" >&2
  local _rows _pick
  _rows=$(openstack network list --format value -c ID -c Name 2>/dev/null || true)
  [ -z "$_rows" ] && { echo "$_requested"; return 0; }
  _pick=$(printf '%s\n' "$_rows" | awk 'tolower($2) ~ /(private|tenant|internal)/ {print $1; exit}')
  [ -z "$_pick" ] && _pick=$(printf '%s\n' "$_rows" | awk 'NF>=1 {print $1; exit}')
  [ -n "$_pick" ] && INFO "Network auto-pick: $_pick" >&2
  echo "${_pick:-$_requested}"
}
resolve_target_keypair() {
  local _requested="$1"
  if [ -n "$_requested" ] && openstack keypair show "$_requested" >/dev/null 2>&1; then
    INFO "Keypair resolved in target region: $_requested" >&2
    echo "$_requested"
    return 0
  fi
  [ -n "$_requested" ] && WARN "Requested keypair not found in target region: $_requested" >&2
  local _pick
  _pick=$(openstack keypair list --format value -c Name 2>/dev/null | awk 'NF>=1 {print $1; exit}')
  [ -n "$_pick" ] && INFO "Keypair auto-pick: $_pick" >&2 || WARN "No keypairs found; booting without --key-name" >&2
  echo "${_pick:-}"
}

QCOW_BYTES=$(stat -c%s "$QCOW" 2>/dev/null || echo 0)
QCOW_MIB=$((QCOW_BYTES / 1024 / 1024))
QCOW_VIRTUAL_BYTES=$(detect_virtual_size_bytes "$QCOW")
QCOW_VIRTUAL_GIB=0
if [ "$QCOW_VIRTUAL_BYTES" -gt 0 ] 2>/dev/null; then
  QCOW_VIRTUAL_GIB=$(( (QCOW_VIRTUAL_BYTES + 1073741823) / 1073741824 ))
fi
IMG_OS_TYPE="windows"
IMG_OS_DISTRO="windows"
IMG_ARCH="x86_64"
IMG_VM_MODE="hvm"
IMG_DISK_BUS="${OSPC2FLEX_WIN_DISK_BUS:-ide}"
IMG_VIF_MODEL="virtio"
IMG_QGA="yes"
IMG_SCSI_MODEL=""
case "$IMG_DISK_BUS" in
  ide)
    INFO "Windows IDE rescue boot active: hw_disk_bus=ide"
    IMG_VIF_MODEL=""
    IMG_QGA=""
    ;;
  virtio)
    INFO "Windows VirtIO block boot active: hw_disk_bus=virtio"
    ;;
  scsi)
    IMG_SCSI_MODEL="virtio-scsi"
    INFO "Windows VirtIO-SCSI boot active: hw_disk_bus=scsi + hw_scsi_model=virtio-scsi"
    ;;
  *)
    FAIL "Invalid OSPC2FLEX_WIN_DISK_BUS=$IMG_DISK_BUS. Use: ide, virtio, or scsi"
    step_done "FAILED"
    exit 94
    ;;
esac
step_progress "Uploading: $QCOW_BYTES bytes (${QCOW_MIB} MiB) to FLEX Glance..."
INFO "FLEX image metadata: architecture=$IMG_ARCH vm_mode=$IMG_VM_MODE os_type=$IMG_OS_TYPE os_distro=$IMG_OS_DISTRO hw_disk_bus=$IMG_DISK_BUS${IMG_SCSI_MODEL:+ hw_scsi_model=$IMG_SCSI_MODEL}${IMG_VIF_MODEL:+ hw_vif_model=$IMG_VIF_MODEL}${IMG_QGA:+ hw_qemu_guest_agent=$IMG_QGA}"

IMG_PROP_ARGS=(
  --property "architecture=$IMG_ARCH"
  --property "vm_mode=$IMG_VM_MODE"
  --property "os_type=$IMG_OS_TYPE"
  --property "os_distro=$IMG_OS_DISTRO"
  --property "hw_disk_bus=$IMG_DISK_BUS"
)
[ -n "$IMG_VIF_MODEL" ] && IMG_PROP_ARGS+=(--property "hw_vif_model=$IMG_VIF_MODEL")
[ -n "$IMG_QGA" ] && IMG_PROP_ARGS+=(--property "hw_qemu_guest_agent=$IMG_QGA")
[ -n "$IMG_SCSI_MODEL" ] && IMG_PROP_ARGS+=(--property "hw_scsi_model=$IMG_SCSI_MODEL")

FLEX_IMG_ID=$(openstack image create "$CLOUD_LABEL" \
  --disk-format qcow2 \
  --container-format bare \
  --file "$QCOW" \
  --private \
  "${IMG_PROP_ARGS[@]}" \
  --format value -c id 2>/dev/null || true)

if [ -z "$FLEX_IMG_ID" ]; then
  FAIL "Image upload failed"
  step_done "FAILED"
  exit 1
fi

# Wait for image to become active
step_progress "Waiting for image to become active in Glance..."
for i in $(seq 1 30); do
  STATUS=$(openstack image show "$FLEX_IMG_ID" -f value -c status 2>/dev/null || echo "unknown")
  [ "$STATUS" = "active" ] && break
  step_progress "  Image status: $STATUS (attempt $i/30)"
  sleep 5
done
PASS "Image uploaded: $FLEX_IMG_ID (status: $STATUS)"
SHOW_NAME=$(openstack image show "$FLEX_IMG_ID" -f value -c name 2>/dev/null || echo "$CLOUD_LABEL")
SHOW_VIS=$(openstack image show "$FLEX_IMG_ID" -f value -c visibility 2>/dev/null || echo "unknown")
SHOW_STAT=$(openstack image show "$FLEX_IMG_ID" -f value -c status 2>/dev/null || echo "${STATUS:-unknown}")
INFO "[UPLOAD-CONFIRMED] region=${OS_REGION_NAME:-unknown} id=$FLEX_IMG_ID name=${SHOW_NAME:-unknown} status=${SHOW_STAT:-unknown} visibility=${SHOW_VIS:-unknown}"
case "$IMG_DISK_BUS" in
  ide)
    openstack image unset \
      --property hw_scsi_model \
      --property hw_vif_model \
      --property hw_qemu_guest_agent \
      "$FLEX_IMG_ID" 2>/dev/null || true
    openstack image set \
      --property os_type=windows \
      --property os_distro=windows \
      --property vm_mode=hvm \
      --property hw_disk_bus=ide \
      "$FLEX_IMG_ID"
    ;;
  scsi)
    openstack image set \
      --property os_type=windows \
      --property os_distro=windows \
      --property vm_mode=hvm \
      --property hw_disk_bus=scsi \
      --property hw_scsi_model=virtio-scsi \
      --property hw_vif_model=virtio \
      --property hw_qemu_guest_agent=yes \
      "$FLEX_IMG_ID"
    ;;
  virtio)
    openstack image unset \
      --property hw_scsi_model \
      "$FLEX_IMG_ID" 2>/dev/null || true
    openstack image set \
      --property os_type=windows \
      --property os_distro=windows \
      --property vm_mode=hvm \
      --property hw_disk_bus=virtio \
      --property hw_vif_model=virtio \
      --property hw_qemu_guest_agent=yes \
      "$FLEX_IMG_ID"
    ;;
esac

PROPS="$(openstack image show -f value -c properties "$FLEX_IMG_ID" 2>/dev/null || true)"
INFO "Image properties after Windows boot metadata enforcement:"
printf '%s\n' "$PROPS"
prop_equals() {
  local key="$1" expected="$2"
  printf '%s\n' "$PROPS" | grep -Eq \
    "${key}[\"']?[[:space:]]*[:=][[:space:]]*[\"']?${expected}([\"']|,|}|[[:space:]]|$)"
}
if [ "$IMG_DISK_BUS" = "ide" ]; then
  prop_equals "hw_disk_bus" "ide" || {
    FAIL "IDE metadata assertion failed: hw_disk_bus=ide not found"
    step_done "FAILED"
    exit 95
  }
  if echo "$PROPS" | grep -q "hw_scsi_model"; then
    FAIL "IDE metadata assertion failed: hw_scsi_model present"
    step_done "FAILED"
    exit 96
  fi
  if echo "$PROPS" | grep -q "hw_vif_model"; then
    FAIL "IDE metadata assertion failed: hw_vif_model present"
    step_done "FAILED"
    exit 101
  fi
  if echo "$PROPS" | grep -q "hw_qemu_guest_agent"; then
    FAIL "IDE metadata assertion failed: hw_qemu_guest_agent present"
    step_done "FAILED"
    exit 102
  fi
fi
if [ "$IMG_DISK_BUS" = "virtio" ]; then
  prop_equals "hw_disk_bus" "virtio" || {
    FAIL "VirtIO metadata assertion failed: hw_disk_bus=virtio not found"
    step_done "FAILED"
    exit 97
  }
  if echo "$PROPS" | grep -q "hw_scsi_model"; then
    FAIL "VirtIO metadata assertion failed: hw_scsi_model present"
    step_done "FAILED"
    exit 98
  fi
fi
if [ "$IMG_DISK_BUS" = "scsi" ]; then
  prop_equals "hw_disk_bus" "scsi" || {
    FAIL "SCSI metadata assertion failed: hw_disk_bus=scsi not found"
    step_done "FAILED"
    exit 99
  }
  prop_equals "hw_scsi_model" "virtio-scsi" || {
    FAIL "SCSI metadata assertion failed: hw_scsi_model=virtio-scsi not found"
    step_done "FAILED"
    exit 100
  }
fi
PASS "Windows FLEX image metadata assertion passed"
step_done "OK"

# ═══════════════════════════════════════════════════════════════════════════════
# Step 6: Boot VM on FLEX
# ═══════════════════════════════════════════════════════════════════════════════
step_start "6" "Booting Windows VM on FLEX from uploaded image"
step_progress "Resolving target flavor, network, and keypair..."
FLAVOR=$(resolve_target_flavor "${MIG_FLAVOR:-$FLAVOR}")
NETWORK=$(resolve_target_network "${MIG_NETWORK:-$NETWORK}")
KEYPAIR=$(resolve_target_keypair "${MIG_KEYPAIR:-$KEYPAIR}")
INFO "Final boot flavor: $FLAVOR"
INFO "Final boot network: $NETWORK"
INFO "Final boot keypair: ${KEYPAIR:-<none>}"

# Kept logic to not delete old VMs
OLD_VIDS=$(openstack server list -f value -c ID -c Name 2>/dev/null | grep -F "$BASE_LABEL" | awk '{print $1}' || true)
if [ -n "$OLD_VIDS" ]; then
  INFO "Old VMs found: $OLD_VIDS (Skipping deletion as per user request)"
fi

if [ -n "$KEYPAIR" ]; then
  VM_ID=$(openstack server create "$CLOUD_LABEL" \
    --image "$FLEX_IMG_ID" \
    --flavor "$FLAVOR" \
    --network "$NETWORK" \
    --key-name "$KEYPAIR" \
    --wait \
    --format value -c id 2>/tmp/winmig_server_create_${LABEL}.err || true)
else
  VM_ID=$(openstack server create "$CLOUD_LABEL" \
    --image "$FLEX_IMG_ID" \
    --flavor "$FLAVOR" \
    --network "$NETWORK" \
    --wait \
    --format value -c id 2>/tmp/winmig_server_create_${LABEL}.err || true)
fi

sleep 10

# Get VM status
if [ -z "${VM_ID:-}" ]; then
  WARN "server create did not return an ID: $(tr '\n' ' ' </tmp/winmig_server_create_${LABEL}.err 2>/dev/null | cut -c 1-240)"
  VM_ID=$(openstack server list -f value -c ID -c Name 2>/dev/null | grep -F "$CLOUD_LABEL" | head -1 | awk '{print $1}' || true)
fi
VM_ID=$(printf '%s' "${VM_ID:-}" | awk 'NF {print $1; exit}')
rm -f "/tmp/winmig_server_create_${LABEL}.err"
if [ -z "${VM_ID:-}" ]; then
  FAIL "Unable to determine created VM ID for $CLOUD_LABEL"
  step_done "FAILED"
  exit 1
fi
VM_STATUS=$(openstack server show "$VM_ID" -f value -c status 2>/dev/null || echo "unknown")

if [ "$VM_STATUS" = "ACTIVE" ]; then
  PASS "VM booted: $VM_ID (ACTIVE)"
  step_done "OK"
else
  WARN "VM status: $VM_STATUS (may need console check)"
  step_done "DONE"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 7: Assign Floating IP
# ═══════════════════════════════════════════════════════════════════════════════
step_start "7" "Assigning floating IP address"
step_progress "Looking for server port..."
PORT_ID=$(openstack port list --server "$VM_ID" -f value -c ID -c Status 2>/dev/null | awk '$2=="ACTIVE"{print $1; exit}' || true)
[ -z "$PORT_ID" ] && PORT_ID=$(openstack port list --server "$VM_ID" -f value -c ID 2>/dev/null | head -1 || true)
if [ -z "$PORT_ID" ]; then
  FIXED_IP_CANDIDATE=$(openstack server show "$VM_ID" -f value -c addresses 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -E '^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.' | head -1 || true)
  if [ -n "$FIXED_IP_CANDIDATE" ]; then
    PORT_ID=$(openstack port list --fixed-ip "ip-address=$FIXED_IP_CANDIDATE" -f value -c ID 2>/dev/null | head -1 || true)
    [ -n "$PORT_ID" ] && step_progress "Found port by fixed IP $FIXED_IP_CANDIDATE: $PORT_ID"
  fi
fi
if [ -z "$PORT_ID" ]; then
  EXISTING_FIP=$(openstack server show "$VM_ID" -f value -c addresses 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -Ev '^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.' | head -1 || true)
  if [ -n "$EXISTING_FIP" ]; then
    ACTUAL_FIP="$EXISTING_FIP"
    WARN "No server port found, but server already has floating IP $ACTUAL_FIP"
    INFO "RDP: mstsc /v:$ACTUAL_FIP"
    step_done "OK (existing FIP)"
  else
    WARN "No server port found; skipping FIP attach"
    step_done "SKIPPED"
  fi
else
  step_progress "Creating or finding floating IP..."
  FIP_JSON=$(openstack floating ip create PUBLICNET -f json 2>/dev/null || true)
  FIP_ID=$(printf '%s' "$FIP_JSON" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("id",""))' 2>/dev/null || true)
  FIP=$(printf '%s' "$FIP_JSON" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("floating_ip_address",""))' 2>/dev/null || true)
  if [ -z "$FIP_ID" ]; then
    _row=$(openstack floating ip list --status DOWN -f value -c ID -c "Floating IP Address" 2>/dev/null | shuf | head -1 || true)
    FIP_ID=$(echo "$_row" | awk '{print $1}')
    FIP=$(echo "$_row" | awk '{print $2}')
  fi
  if [ -z "$FIP_ID" ]; then
    WARN "No available floating IPs"
    step_done "SKIPPED"
  else
    step_progress "Assigning FIP $FIP to port $PORT_ID..."
    openstack floating ip set --port "$PORT_ID" "$FIP_ID" 2>/dev/null || true
    sleep 3
    # Verify
    ACTUAL_FIP=$(openstack floating ip show "$FIP_ID" -f value -c floating_ip_address 2>/dev/null || true)
    FIXED_IP=$(openstack floating ip show "$FIP_ID" -f value -c fixed_ip_address 2>/dev/null || true)
    if [ -n "$ACTUAL_FIP" ] && [ -n "$FIXED_IP" ] && [ "$FIXED_IP" != "None" ]; then
      PASS "Floating IP: $ACTUAL_FIP"
      INFO "RDP: mstsc /v:$ACTUAL_FIP"
      step_done "OK"
    else
      WARN "FIP assignment may have failed"
      step_done "DONE"
    fi
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Workflow Complete
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "╔════════════════════════════════════════════════════════════════════════════╗"
echo "║                     MIGRATION WORKFLOW COMPLETE                            ║"
echo "╚════════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Server:       $CLOUD_LABEL"
echo "  Image ID:     $FLEX_IMG_ID"
echo "  VM ID:        $VM_ID ($VM_STATUS)"
echo "  Floating IP:  ${ACTUAL_FIP:-not assigned}"
echo "  RDP Connect:  mstsc /v:${ACTUAL_FIP:-unknown}"
echo "  Download:     ${DOWNLOAD_METHOD:-unknown} (Step 2)"
echo ""
echo "═══════════════════════════════════════════════════════════════════════════"

if [ -z "$OUTPUT_JSON" ]; then
  OUTPUT_JSON="$WORK/${CLOUD_LABEL}.windows_migrate_result.json"
fi
export OSPC2FLEX_RESULT_LABEL="$LABEL"
export OSPC2FLEX_RESULT_BASE_LABEL="$BASE_LABEL"
export OSPC2FLEX_RESULT_CLOUD_LABEL="$CLOUD_LABEL"
export OSPC2FLEX_RESULT_MODE="$WINDOWS_MODE"
export OSPC2FLEX_RESULT_SERVER_NAME="$SERVER_NAME"
export OSPC2FLEX_RESULT_SERVER_IP="$SERVER_IP"
export OSPC2FLEX_RESULT_OS_FAMILY="$OS_FAMILY"
export OSPC2FLEX_RESULT_OS_TYPE="$OS_TYPE"
export OSPC2FLEX_RESULT_DOWNLOAD_METHOD="${DOWNLOAD_METHOD:-}"
export OSPC2FLEX_RESULT_RESUME_FROM_QCOW="$RESUME_FROM_QCOW"
export OSPC2FLEX_RESULT_QCOW="$QCOW"
export OSPC2FLEX_RESULT_IMG_PATH="${IMG_PATH:-}"
export OSPC2FLEX_RESULT_REPAIR_LOG="${REPAIR_LOG:-}"
export OSPC2FLEX_RESULT_IMAGE_ID="${FLEX_IMG_ID:-}"
export OSPC2FLEX_RESULT_VM_ID="${VM_ID:-}"
export OSPC2FLEX_RESULT_VM_STATUS="${VM_STATUS:-}"
export OSPC2FLEX_RESULT_FLOATING_IP="${ACTUAL_FIP:-}"
export OSPC2FLEX_RESULT_NETWORK="$NETWORK"
export OSPC2FLEX_RESULT_FLAVOR="$FLAVOR"
export OSPC2FLEX_RESULT_KEYPAIR="${KEYPAIR:-}"
export OSPC2FLEX_RESULT_DISK_BUS="${IMG_DISK_BUS:-}"
export OSPC2FLEX_RESULT_SCSI_MODEL="${IMG_SCSI_MODEL:-}"
export OSPC2FLEX_RESULT_OUTPUT_JSON="$OUTPUT_JSON"
python3 - <<'PY'
import json
import os
from pathlib import Path

payload = {
  "label": os.environ.get("OSPC2FLEX_RESULT_LABEL", ""),
  "base_label": os.environ.get("OSPC2FLEX_RESULT_BASE_LABEL", ""),
  "cloud_label": os.environ.get("OSPC2FLEX_RESULT_CLOUD_LABEL", ""),
  "mode": os.environ.get("OSPC2FLEX_RESULT_MODE", ""),
  "server_name": os.environ.get("OSPC2FLEX_RESULT_SERVER_NAME", ""),
  "server_ip": os.environ.get("OSPC2FLEX_RESULT_SERVER_IP", ""),
  "os_family": os.environ.get("OSPC2FLEX_RESULT_OS_FAMILY", ""),
  "os_type": os.environ.get("OSPC2FLEX_RESULT_OS_TYPE", ""),
  "download_method": os.environ.get("OSPC2FLEX_RESULT_DOWNLOAD_METHOD", ""),
  "resume_from_qcow": os.environ.get("OSPC2FLEX_RESULT_RESUME_FROM_QCOW", "0") not in ("0", "", "false", "False"),
  "qcow_path": os.environ.get("OSPC2FLEX_RESULT_QCOW", ""),
  "image_path": os.environ.get("OSPC2FLEX_RESULT_IMG_PATH", ""),
  "repair_log": os.environ.get("OSPC2FLEX_RESULT_REPAIR_LOG", ""),
  "image_id": os.environ.get("OSPC2FLEX_RESULT_IMAGE_ID", ""),
  "vm_id": os.environ.get("OSPC2FLEX_RESULT_VM_ID", ""),
  "vm_status": os.environ.get("OSPC2FLEX_RESULT_VM_STATUS", ""),
  "floating_ip": os.environ.get("OSPC2FLEX_RESULT_FLOATING_IP", ""),
  "network": os.environ.get("OSPC2FLEX_RESULT_NETWORK", ""),
  "flavor": os.environ.get("OSPC2FLEX_RESULT_FLAVOR", ""),
  "keypair": os.environ.get("OSPC2FLEX_RESULT_KEYPAIR", ""),
  "disk_bus": os.environ.get("OSPC2FLEX_RESULT_DISK_BUS", ""),
  "scsi_model": os.environ.get("OSPC2FLEX_RESULT_SCSI_MODEL", ""),
  "output_json": os.environ.get("OSPC2FLEX_RESULT_OUTPUT_JSON", ""),
}
path = Path(os.environ["OSPC2FLEX_RESULT_OUTPUT_JSON"])
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
PASS "Migration result JSON: $OUTPUT_JSON"

# Cleanup OSPC snapshot
if [ -n "${SNAP_ID:-}" ]; then
  log "Cleaning up OSPC snapshot ${SNAP_NAME:-$SNAP_ID}..."
  source /tmp/ospc2flex_ospc.sh
  if [ -n "${OSPC_TOKEN:-}" ]; then
    export OS_TOKEN="$OSPC_TOKEN"
    export OS_AUTH_TYPE=token
    export OS_IDENTITY_API_VERSION=2
  fi
  openstack image delete "$SNAP_ID" 2>/dev/null || true
  PASS "OSPC snapshot deleted"
else
  INFO "No OSPC snapshot was created; cleanup skipped"
fi
