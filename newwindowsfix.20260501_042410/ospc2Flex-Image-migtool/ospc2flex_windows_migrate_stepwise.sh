#!/usr/bin/env bash
set -euo pipefail

# Stepwise Windows migration:
# 1) Snapshot VM into OSPC Glance
# 2) Download snapshot image to jumphost
# 3) Convert to qcow2
# 4) Run Windows offline repair
# 5) Upload to FLEX Glance
# 6) Boot FLEX VM

SERVER_NAME=""
SERVER_IP=""
LABEL=""
FLAVOR="gp.5.4.4"
NETWORK="tenant-net"
KEYPAIR="laptopubuntu24"
WORK="/mnt/migration/ospc2flex_image"
OSPC_CREDS="/tmp/ospc2flex_ospc.sh"
FLEX_CREDS="/tmp/ospc2flex_flex.sh"
WIN_REPAIR="/tmp/ospc2flex_windows_repair.sh"
RESUME_MODE="${OSPC2FLEX_RESUME_MODE:-on}"

usage() {
  echo "Usage: $0 --server-name <name> [--server-ip <ip>] [--label <label>] [--flavor <f>] [--network <n>] [--keypair <k>]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-name) SERVER_NAME="$2"; shift 2 ;;
    --server-ip) SERVER_IP="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --flavor) FLAVOR="$2"; shift 2 ;;
    --network) NETWORK="$2"; shift 2 ;;
    --keypair) KEYPAIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

[ -z "$SERVER_NAME" ] && { usage; exit 1; }
[ -z "$LABEL" ] && LABEL="$(echo "$SERVER_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"

log()  { echo "[$(date '+%H:%M:%S')][$LABEL] $*"; }
ok()   { echo "  [OK] $*"; }
warn() { echo "  [WARN] $*"; }
die()  { echo "  [ERR] $*"; exit 1; }

[ -f "$OSPC_CREDS" ] || die "Missing OSPC creds file: $OSPC_CREDS"
[ -f "$FLEX_CREDS" ] || die "Missing FLEX creds file: $FLEX_CREDS"

mkdir -p "$WORK"
IMG="$WORK/${LABEL}.img"
QCOW="$WORK/${LABEL}.qcow2"
LOG="/tmp/mig_${LABEL}.log"
exec > >(tee -a "$LOG") 2>&1
RESUME_FROM_QCOW=0
if [ "$RESUME_MODE" != "off" ] && [ -s "$QCOW" ] && qemu-img info "$QCOW" >/dev/null 2>&1; then
  QCOW_EXISTING_BYTES=$(stat -c%s "$QCOW" 2>/dev/null || echo 0)
  if [ "${QCOW_EXISTING_BYTES:-0}" -ge 1048576 ]; then
    RESUME_FROM_QCOW=1
  fi
fi

echo "=============================================================="
echo " OSPC -> FLEX Windows Stepwise Migration"
echo "=============================================================="
echo "Server : $SERVER_NAME ${SERVER_IP:+($SERVER_IP)}"
echo "Label  : $LABEL"
echo "Target : flavor=$FLAVOR network=$NETWORK keypair=$KEYPAIR"
echo "Workdir: $WORK"
echo "Resume : $RESUME_MODE"
echo "=============================================================="
if [ "$RESUME_FROM_QCOW" -eq 1 ]; then
  ok "Resume point found: $QCOW ($((QCOW_EXISTING_BYTES / 1024 / 1024)) MB)"
  log "Resume mode active — skipping snapshot/download/conversion (Steps 1-3)"
elif [ "$RESUME_MODE" = "off" ]; then
  log "Resume mode OFF — forcing fresh snapshot/download/conversion path"
fi

refresh_ospc_token() {
  OS_TOKEN=""
  if [ -n "${OS_USERNAME:-}" ] && [ -n "${OS_API_KEY:-}" ]; then
    _AUTH="$(curl -s -X POST "${OS_AUTH_URL:-https://identity.api.rackspacecloud.com/v2.0/}tokens" \
      -H "Content-Type: application/json" \
      -d "{\"auth\":{\"RAX-KSKEY:apiKeyCredentials\":{\"username\":\"$OS_USERNAME\",\"apiKey\":\"$OS_API_KEY\"}}}" || true)"
    OS_TOKEN="$(echo "$_AUTH" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['access']['token']['id'])" 2>/dev/null || true)"
  fi
  OS_TOKEN="$(printf '%s' "${OS_TOKEN:-}" | tr -d '[:space:]')"
  [ -n "$OS_TOKEN" ] || die "Unable to acquire OSPC token"
}

SNAP_ID=""
if [ "$RESUME_FROM_QCOW" -eq 0 ]; then
  log "Step 1/6: Create fresh OSPC snapshot image"
  source "$OSPC_CREDS"
  export OS_INTERFACE=public OS_IDENTITY_API_VERSION=2
  refresh_ospc_token

  SERVER_ID=""
  if [ -n "$SERVER_IP" ]; then
    # Robust IP match via JSON (Networks/Addresses formatting varies by cloud/client).
    SERVER_ID="$(
      openstack server list -f json 2>/dev/null | \
      python3 -c 'import json,sys
target=sys.argv[1]
try:
    rows=json.load(sys.stdin)
except Exception:
    rows=[]
for r in rows:
    rid=str(r.get("ID",""))
    blob=" ".join(str(v) for v in r.values())
    if target and target in blob:
        print(rid)
        break' "$SERVER_IP" 2>/dev/null || true
    )"
  fi
  [ -z "$SERVER_ID" ] && SERVER_ID="$(openstack server list -f value -c ID -c Name 2>/dev/null | grep -F "$SERVER_NAME" | head -1 | awk '{print $1}' || true)"
  [ -n "$SERVER_ID" ] || die "Could not find source server in OSPC: $SERVER_NAME ${SERVER_IP:+/$SERVER_IP}"

  SNAP_NAME="${LABEL}-snap-${SERVER_ID:0:8}-$(date +%Y%m%d%H%M%S)"
  openstack server image create --name "$SNAP_NAME" "$SERVER_ID" --wait >/dev/null 2>&1 || true
  sleep 5
  SNAP_ID="$(openstack image list --name "$SNAP_NAME" -f value -c ID 2>/dev/null | head -1 || true)"
  [ -n "$SNAP_ID" ] || die "Snapshot image was not created"
  ok "Snapshot image: $SNAP_ID"

  log "Step 2/6: Download snapshot image from OSPC Glance"
  rm -f "$IMG"
  _dl_ok=0
  if openstack image save --file "$IMG" "$SNAP_ID" >/tmp/win_step_osave.log 2>&1; then
    _sz="$(stat -c%s "$IMG" 2>/dev/null || echo 0)"
    [ "$_sz" -ge 1048576 ] && _dl_ok=1
  fi
  if [ "$_dl_ok" -ne 1 ]; then
    warn "openstack image save failed or tiny file; trying direct curl /v2/images/<id>/file"
    refresh_ospc_token
    REGION_SHORT="$(echo "${OS_REGION_NAME:-IAD}" | tr '[:upper:]' '[:lower:]' | tr -d '0-9')"
    [ -z "$REGION_SHORT" ] && REGION_SHORT="iad"
    GLANCE_URL="https://${REGION_SHORT}.images.api.rackspacecloud.com/v2/images/${SNAP_ID}/file"
    rm -f "$IMG"
    curl -fSL --connect-timeout 30 --retry 2 --retry-delay 10 \
      -H "X-Auth-Token: $OS_TOKEN" -H 'Expect:' -H 'Accept: application/octet-stream' \
      -o "$IMG" "$GLANCE_URL" >/tmp/win_step_curl.log 2>&1 || true
    _sz="$(stat -c%s "$IMG" 2>/dev/null || echo 0)"
    [ "$_sz" -ge 1048576 ] && _dl_ok=1
  fi
  [ "$_dl_ok" -eq 1 ] || die "Glance download failed (likely endpoint/network policy)."
  ok "Downloaded image size: $(( _sz / 1024 / 1024 )) MB"

  log "Step 3/6: Convert downloaded image to qcow2"
  FMT="$(qemu-img info --output=json "$IMG" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('format','raw'))" 2>/dev/null || echo raw)"
  if [ "$FMT" = "qcow2" ]; then
    mv "$IMG" "$QCOW"
  else
    qemu-img convert -p -f "$FMT" -O qcow2 "$IMG" "$QCOW"
    rm -f "$IMG"
  fi
  ok "qcow2 ready: $QCOW"
fi

log "Step 4/6: Run Windows offline repair"
if [ -f "$WIN_REPAIR" ]; then
  set +e
  _win_dbg="${QCOW%.qcow2}.repair.debug.log"
  bash "$WIN_REPAIR" --qcow2 "$QCOW" --force --no-purge-xen --debug --debug-log "$_win_dbg"
  _repair_rc=$?
  set -e
  if [ "$_repair_rc" -eq 0 ]; then
    ok "Windows repair completed"
  else
    die "Windows repair exited with code $_repair_rc"
  fi
else
  warn "Windows repair script missing: $WIN_REPAIR"
fi

log "Step 5/6: Upload qcow2 to FLEX Glance"
source "$FLEX_CREDS"
FLEX_IMG_ID="$(openstack image create "$LABEL" --disk-format qcow2 --container-format bare --file "$QCOW" --private -f value -c id)"
[ -n "$FLEX_IMG_ID" ] || die "FLEX image upload failed"
ok "FLEX image ID: $FLEX_IMG_ID"

log "Step 6/6: Boot FLEX VM from migrated image"
VM_ID="$(openstack server create "$LABEL" --image "$FLEX_IMG_ID" --flavor "$FLAVOR" --network "$NETWORK" --key-name "$KEYPAIR" --wait -f value -c id)"
[ -n "$VM_ID" ] || die "FLEX VM boot failed"
ok "FLEX VM ID: $VM_ID"

echo "=============================================================="
echo "DONE"
echo "Source VM   : $SERVER_NAME"
echo "Snapshot ID : ${SNAP_ID:-N/A (resume from existing qcow2)}"
echo "FLEX Image  : $FLEX_IMG_ID"
echo "FLEX VM     : $VM_ID"
echo "Log         : $LOG"
echo "=============================================================="
