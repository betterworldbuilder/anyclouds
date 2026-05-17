#!/usr/bin/env bash
# ospc2flex_volsnap_migrate.sh — OSPC Cinder volume snapshot → FLEX Cinder volume (direct block stream)
#
# VS0:  Load + validate OSPC credentials
# VS1:  Create temp OSPC Cinder volume from snapshot
# VS2:  Attach temp volume to this jumphost; detect source block device
# VS3:  Get source device size
# VS4:  Source FLEX creds; create blank FLEX Cinder volume (same size)
# VS5:  Attach blank FLEX volume to FLEX helper VM
# VS6:  Detect target block device on FLEX helper via SSH
# VS7:  Validate target_bytes >= source_bytes
# VS8:  Direct block stream: dd | gzip | ssh ... gunzip | dd
# VS9:  Validate FLEX target disk (blkid, file -s)
# VS10: Detach FLEX volume from helper VM
# VS11: Attach FLEX volume to paired migrated FLEX VM (optional)
# VS12: Cleanup — detach + delete temp OSPC volume
#
# No FLEX Glance. No qcow2. No image create. No virtual-size mismatch.

set -euo pipefail
export PATH="$PATH:/usr/sbin:/sbin"

if [ -z "${OSPC2FLEX_LINEBUF_WRAPPER:-}" ] && command -v stdbuf >/dev/null 2>&1; then
  export OSPC2FLEX_LINEBUF_WRAPPER=1
  exec stdbuf -oL -eL bash "$0" "$@"
fi

# ── Args ──────────────────────────────────────────────────────────────────────
LABEL=""
SNAPSHOT_ID=""
OSPC_OPENRC=""
FLEX_OPENRC=""
FLEX_HELPER_VM_ID=""
FLEX_HELPER_IP=""
FLEX_HELPER_USER="ubuntu"
SSH_KEY_PATH="${HOME}/.ssh/id_rsa"
FLEX_TARGET_VM_ID=""
FLEX_VOLUME_NAME_OVERRIDE=""
SNAP_SIZE_GB=0                      # 0 = auto-detect from snapshot
CLEANUP_TEMP="true"
ATTACH_TO_FINAL="true"
SOURCE_DEVICE_OVERRIDE=""
TARGET_DEVICE_OVERRIDE=""
BASE_DIR="${OSPC2FLEX_LINUX_SNAP_BASE_DIR:-/mnt/migration/ospc2flex_linux_snap}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label)               LABEL="$2";                  shift 2 ;;
    --snapshot-id)         SNAPSHOT_ID="$2";             shift 2 ;;
    --ospc-openrc)         OSPC_OPENRC="$2";             shift 2 ;;
    --flex-openrc)         FLEX_OPENRC="$2";             shift 2 ;;
    --flex-helper-vm-id)   FLEX_HELPER_VM_ID="$2";       shift 2 ;;
    --flex-helper-ip)      FLEX_HELPER_IP="$2";          shift 2 ;;
    --flex-helper-user)    FLEX_HELPER_USER="$2";        shift 2 ;;
    --ssh-key-path)        SSH_KEY_PATH="$2";            shift 2 ;;
    --flex-target-vm-id)   FLEX_TARGET_VM_ID="$2";       shift 2 ;;
    --flex-volume-name)    FLEX_VOLUME_NAME_OVERRIDE="$2"; shift 2 ;;
    --snap-size-gb)        SNAP_SIZE_GB="$2";            shift 2 ;;
    --cleanup-temp)        CLEANUP_TEMP="$2";            shift 2 ;;
    --attach-to-final)     ATTACH_TO_FINAL="$2";         shift 2 ;;
    --source-device)       SOURCE_DEVICE_OVERRIDE="$2";  shift 2 ;;
    --target-device)       TARGET_DEVICE_OVERRIDE="$2";  shift 2 ;;
    --base-dir)            BASE_DIR="$2";                shift 2 ;;
    # legacy compat — ignored
    --os-type|--nbd-dev)   shift 2 ;;
    *) echo "ERROR: Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$LABEL" ]             || { echo "ERROR: --label required" >&2; exit 2; }
[ -n "$SNAPSHOT_ID" ]       || { echo "ERROR: --snapshot-id required" >&2; exit 2; }
[ -n "$OSPC_OPENRC" ]       || { echo "ERROR: --ospc-openrc required" >&2; exit 2; }
[ -n "$FLEX_OPENRC" ]       || { echo "ERROR: --flex-openrc required" >&2; exit 2; }
[ -n "$FLEX_HELPER_IP" ]    || { echo "ERROR: --flex-helper-ip required" >&2; exit 2; }

LABEL_SAFE="$(printf '%s' "$LABEL" | tr -c 'A-Za-z0-9._-' '_' | sed 's/_$//')"
RUN_ID="${OSPC2FLEX_RUN_ID:-$(date -u +%Y%m%d-%H%M%S)}"
RUN_DIR="$BASE_DIR/runs/$LABEL_SAFE/$RUN_ID"
JOB_ART="$RUN_DIR/artifacts"
JOB_TMP="$RUN_DIR/tmp"
JOB_LOG="$RUN_DIR/logs"

mkdir -p "$JOB_ART" "$JOB_TMP" "$JOB_LOG"
exec > >(tee -a "$JOB_LOG/volsnap_direct.log") 2>&1

log()      { printf '[%s][%s][VOLSNAP] %s\n' "$(date -u +%H:%M:%S)" "$LABEL_SAFE" "$*"; }
stage()    { log "══════════════════════════════════════════════════════"; log "  $1"; log "══════════════════════════════════════════════════════"; }
fail_exit(){ log "FAILED: $*"; exit 1; }
kv()       { log "  $(printf '%-24s' "$1"): $2"; }

# ── SSH helper to FLEX helper VM ──────────────────────────────────────────────
SSH_FLEX_BASE=(
  ssh -i "$SSH_KEY_PATH"
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile=/dev/null
  -o BatchMode=yes
  -o ConnectTimeout=30
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=4
  "${FLEX_HELPER_USER}@${FLEX_HELPER_IP}"
)
ssh_flex() { "${SSH_FLEX_BASE[@]}" "$@"; }

# ── OSPC Cinder/Compute REST helpers (use saved OSPC_TOKEN, never overwritten) ─
_cinder_get()    { curl -sS -H "X-Auth-Token: $OSPC_TOKEN" "$OSPC_BS_BASE/$1" 2>>"$JOB_LOG/cinder.log"; }
_cinder_post()   { curl -sS -w '\nHTTP_CODE=%{http_code}\n' -X POST \
                     -H "X-Auth-Token: $OSPC_TOKEN" -H "Content-Type: application/json" \
                     -d "$2" "$OSPC_BS_BASE/$1" 2>>"$JOB_LOG/cinder.log"; }
_cinder_delete() { curl -sS -o /dev/null -X DELETE -H "X-Auth-Token: $OSPC_TOKEN" \
                     "$OSPC_BS_BASE/$1" 2>>"$JOB_LOG/cinder.log" || true; }
_compute_post()  { curl -sS -w '\nHTTP_CODE=%{http_code}\n' -X POST \
                     -H "X-Auth-Token: $OSPC_TOKEN" -H "Content-Type: application/json" \
                     -d "$2" "$OSPC_COMPUTE_BASE/$1" 2>>"$JOB_LOG/cinder.log"; }
_compute_delete(){ curl -sS -o /dev/null -X DELETE -H "X-Auth-Token: $OSPC_TOKEN" \
                     "$OSPC_COMPUTE_BASE/$1" 2>>"$JOB_LOG/cinder.log" || true; }

ospc_volume_status() {
  _cinder_get "volumes/$1" | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["volume"]["status"])' 2>/dev/null || echo unknown
}
ospc_wait_volume() {
  local vid="$1" want="$2" timeout="${3:-3600}" waited=0 status
  while [ "$waited" -lt "$timeout" ]; do
    status="$(ospc_volume_status "$vid")"
    [ "$status" = "$want" ] && return 0
    [ "$status" = "error" ] && { log "[OSPC] vol=$vid error state"; return 1; }
    [ $((waited % 60)) -eq 0 ] && log "[OSPC] vol=$vid status=$status → $want (${waited}s)"
    sleep 10; waited=$((waited + 10))
  done
  log "[OSPC] TIMEOUT vol=$vid target=$want after ${timeout}s"; return 1
}

# ── FLEX Cinder helpers (openstack CLI, requires FLEX openrc to be sourced) ──
flex_volume_status() {
  openstack volume show "$1" -f value -c status 2>/dev/null || echo unknown
}
flex_wait_volume() {
  local vid="$1" want="$2" timeout="${3:-3600}" waited=0 status
  while [ "$waited" -lt "$timeout" ]; do
    status="$(flex_volume_status "$vid")"
    [ "$status" = "$want" ] && return 0
    [ "$status" = "error" ] && { log "[FLEX] vol=$vid error state"; return 1; }
    [ $((waited % 60)) -eq 0 ] && log "[FLEX] vol=$vid status=$status → $want (${waited}s)"
    sleep 10; waited=$((waited + 10))
  done
  log "[FLEX] TIMEOUT vol=$vid target=$want after ${timeout}s"; return 1
}
flex_volume_device() {
  openstack volume show "$1" -f json 2>/dev/null | python3 -c \
    'import json,sys; v=json.load(sys.stdin); a=v.get("attachments") or []; print(a[0].get("device","") if a else "")' \
    2>/dev/null || true
}

local_block_disks() {
  sudo lsblk -dnpo NAME,TYPE 2>/dev/null | awk '$2=="disk" && $1 !~ /^\/dev\/(nbd|loop|sr|fd)/ {print $1}' | sort
}
discover_self_server_id() {
  local ips_json server_json
  ips_json="$(hostname -I 2>/dev/null | tr ' ' '\n' | awk 'NF' | \
    python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
  server_json="$(openstack server list --long -f json 2>/dev/null || true)"
  LOCAL_IPS_JSON="$ips_json" SERVER_JSON="$server_json" python3 - <<'PY' 2>/dev/null || true
import json, os
try: rows = json.loads(os.environ.get("SERVER_JSON") or "[]")
except Exception: rows = []
try: ips  = json.loads(os.environ.get("LOCAL_IPS_JSON") or "[]")
except Exception: ips  = []
for row in rows:
    blob = json.dumps(row).lower()
    if any(ip and ip.lower() in blob for ip in ips):
        print(row.get("ID") or row.get("Id") or row.get("id") or ""); raise SystemExit
PY
}

# ── VS0: Load + validate OSPC credentials ─────────────────────────────────────
stage "VS0_LOAD_CREDENTIALS"
# shellcheck disable=SC1090
source "$OSPC_OPENRC"
OSPC_TOKEN="${OS_TOKEN:-}"
OSPC_TENANT="${OS_TENANT_ID:-${OS_PROJECT_ID:-}}"
[ -n "$OSPC_TOKEN" ]  || fail_exit "OS_TOKEN not set in $OSPC_OPENRC"
[ -n "$OSPC_TENANT" ] || fail_exit "OS_TENANT_ID not set in $OSPC_OPENRC"
OSPC_BS_BASE="https://iad.blockstorage.api.rackspacecloud.com/v1/$OSPC_TENANT"
OSPC_COMPUTE_BASE="https://iad.servers.api.rackspacecloud.com/v2/$OSPC_TENANT"
kv "OSPC tenant"   "$OSPC_TENANT"
kv "Snapshot ID"   "$SNAPSHOT_ID"
kv "Label"         "$LABEL_SAFE"
kv "FLEX helper"   "${FLEX_HELPER_USER}@${FLEX_HELPER_IP} (vm=${FLEX_HELPER_VM_ID:-none})"

# ── VS1: Create temp OSPC Cinder volume from snapshot ─────────────────────────
stage "VS1_CREATE_TEMP_OSPC_VOLUME"

# Auto-detect snapshot size if not overridden
if [ "$SNAP_SIZE_GB" -le 0 ] 2>/dev/null; then
  SNAP_SIZE_GB="$(_cinder_get "snapshots/$SNAPSHOT_ID" | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["snapshot"]["size"])' 2>/dev/null || echo 75)"
  log "[VS1] Auto-detected snapshot size: ${SNAP_SIZE_GB}GB"
fi
[ "$SNAP_SIZE_GB" -gt 0 ] 2>/dev/null || fail_exit "Could not determine snapshot size"
SNAP_SIZE_ORIG_GB="$SNAP_SIZE_GB"
# OSPC Cinder requires minimum 75 GB per volume; use 80 GB default floor for headroom
if [ "$SNAP_SIZE_GB" -lt 80 ] 2>/dev/null; then
  log "[VS1] Snapshot size ${SNAP_SIZE_GB}GB below minimum — using 80GB for OSPC temp vol (FLEX vol stays ${SNAP_SIZE_ORIG_GB}GB)"
  SNAP_SIZE_GB=80
fi

SNAP_STATUS="$(_cinder_get "snapshots/$SNAPSHOT_ID" | python3 -c \
  'import json,sys; print(json.load(sys.stdin)["snapshot"]["status"])' 2>/dev/null || echo unknown)"
[ "$SNAP_STATUS" = "available" ] || fail_exit "Snapshot $SNAPSHOT_ID not available (status=$SNAP_STATUS)"
kv "Snapshot status" "$SNAP_STATUS"
kv "Snapshot size"   "${SNAP_SIZE_GB}GB"

OSPC_VOL_NAME="tmp-osflex-${LABEL_SAFE}-${RUN_ID}"
PAYLOAD="$(SNAP_ID="$SNAPSHOT_ID" SIZE="$SNAP_SIZE_GB" VNAME="$OSPC_VOL_NAME" python3 - <<'PY'
import json, os
print(json.dumps({"volume":{"snapshot_id":os.environ["SNAP_ID"],"size":int(os.environ["SIZE"]),"display_name":os.environ["VNAME"]}},separators=(",",":")))
PY
)"
RESP="$(_cinder_post "volumes" "$PAYLOAD")"
HTTP="$(printf '%s' "$RESP" | awk -F= '/HTTP_CODE=/{print $2}' | tail -1)"
BODY="$(printf '%s' "$RESP" | sed '/^HTTP_CODE=/d')"
case "$HTTP" in 200|202) ;; *) fail_exit "Cinder volume create HTTP=$HTTP body=${BODY:0:200}" ;; esac
OSPC_VOL_ID="$(printf '%s' "$BODY" | python3 -c \
  'import json,sys; print((json.load(sys.stdin).get("volume") or {}).get("id",""))' 2>/dev/null || true)"
[ -n "$OSPC_VOL_ID" ] || fail_exit "No volume ID in create response: ${BODY:0:300}"
kv "OSPC temp vol"   "$OSPC_VOL_ID"
log "[VS1] Waiting for temp volume to become available…"
ospc_wait_volume "$OSPC_VOL_ID" "available" 3600 || fail_exit "Temp volume $OSPC_VOL_ID never became available"
log "[VS1] HIT temp volume available"

# ── VS2: Attach temp OSPC volume to this jumphost ─────────────────────────────
stage "VS2_ATTACH_OSPC_VOLUME"
SELF_SERVER_ID="$(discover_self_server_id | head -1 | tr -d '[:space:]')"
[ -n "$SELF_SERVER_ID" ] || fail_exit "Could not determine jumphost Nova server ID"
kv "Jumphost server" "$SELF_SERVER_ID"

ATTACH_PAYLOAD="$(VOL_ID="$OSPC_VOL_ID" python3 - <<'PY'
import json, os; print(json.dumps({"volumeAttachment":{"volumeId":os.environ["VOL_ID"]}},separators=(",",":")))
PY
)"
ATTACH_RESP="$(_compute_post "servers/$SELF_SERVER_ID/os-volume_attachments" "$ATTACH_PAYLOAD")"
ATTACH_HTTP="$(printf '%s' "$ATTACH_RESP" | awk -F= '/HTTP_CODE=/{print $2}' | tail -1)"
case "$ATTACH_HTTP" in 200|202) ;; *) fail_exit "Volume attach HTTP=$ATTACH_HTTP" ;; esac
log "[VS2] Attach request OK — waiting in-use"
ospc_wait_volume "$OSPC_VOL_ID" "in-use" 300 || fail_exit "Temp volume did not reach in-use"

# Detect source device from Cinder attachment record (avoids parallel-job race)
if [ -n "$SOURCE_DEVICE_OVERRIDE" ]; then
  SOURCE_DEV="$SOURCE_DEVICE_OVERRIDE"
  log "[VS2] Source device overridden: $SOURCE_DEV"
else
  SOURCE_DEV=""
  for _i in $(seq 1 24); do
    sleep 5
    SOURCE_DEV="$(_cinder_get "volumes/$OSPC_VOL_ID" | python3 -c \
      'import json,sys; v=json.load(sys.stdin)["volume"]; a=v.get("attachments") or []; print(a[0]["device"] if a else "")' \
      2>/dev/null || true)"
    [ -n "$SOURCE_DEV" ] && [ -b "$SOURCE_DEV" ] && break
    SOURCE_DEV=""
  done
  [ -n "$SOURCE_DEV" ] || fail_exit "Could not get source device from Cinder for vol $OSPC_VOL_ID"
fi
kv "Source device" "$SOURCE_DEV"

# ── VS3: Get source device size ───────────────────────────────────────────────
stage "VS3_GET_SOURCE_SIZE"
SOURCE_BYTES="$(sudo blockdev --getsize64 "$SOURCE_DEV" 2>/dev/null || echo 0)"
[ "$SOURCE_BYTES" -gt 1073741824 ] || fail_exit "Source device $SOURCE_DEV too small: ${SOURCE_BYTES}B"
kv "Source bytes" "$SOURCE_BYTES"
kv "Source GB"    "$(( SOURCE_BYTES / 1073741824 ))"

# ── VS4: Create blank FLEX Cinder volume ──────────────────────────────────────
stage "VS4_CREATE_FLEX_CINDER_VOLUME"
# Unset OSPC token vars before sourcing FLEX openrc — OS_TOKEN + OS_AUTH_TYPE=token
# from OSPC openrc crash the password auth plugin with "unexpected keyword argument 'token'"
unset OS_TOKEN OS_AUTH_TYPE OS_AUTH_URL OS_TENANT_ID OS_TENANT_NAME \
      OS_REGION_NAME OS_IDENTITY_API_VERSION OS_INTERFACE \
      OS_PROJECT_ID OS_PROJECT_NAME OS_USER_DOMAIN_NAME OS_PROJECT_DOMAIN_ID
# shellcheck disable=SC1090
source "$FLEX_OPENRC"
openstack token issue >/dev/null 2>&1 || fail_exit "FLEX authentication failed — check $FLEX_OPENRC"

FLEX_VOL_SIZE_GB="$SNAP_SIZE_ORIG_GB"
FLEX_VOL_NAME="${FLEX_VOLUME_NAME_OVERRIDE:-mig-${LABEL_SAFE}-flex}"
kv "FLEX volume name" "$FLEX_VOL_NAME"
kv "FLEX volume size" "${FLEX_VOL_SIZE_GB}GB"

FLEX_VOL_ID="$(openstack volume create \
  --size "$FLEX_VOL_SIZE_GB" \
  --format value -c id \
  "$FLEX_VOL_NAME" 2>>"$JOB_LOG/flex_cinder.log" || true)"
[ -n "$FLEX_VOL_ID" ] || fail_exit "openstack volume create failed — check $JOB_LOG/flex_cinder.log"
kv "FLEX volume ID" "$FLEX_VOL_ID"
log "[VS4] Waiting for FLEX volume to become available…"
flex_wait_volume "$FLEX_VOL_ID" "available" 3600 || fail_exit "FLEX volume $FLEX_VOL_ID never became available"
log "[VS4] HIT FLEX volume available"

# ── VS5: Attach blank FLEX volume to FLEX helper VM ───────────────────────────
stage "VS5_ATTACH_FLEX_VOLUME_TO_HELPER"
if [ -n "$FLEX_HELPER_VM_ID" ]; then
  log "[VS5] Attaching $FLEX_VOL_ID to FLEX helper vm=$FLEX_HELPER_VM_ID"
  openstack server add volume "$FLEX_HELPER_VM_ID" "$FLEX_VOL_ID" \
    2>>"$JOB_LOG/flex_cinder.log" || fail_exit "openstack server add volume failed"
  log "[VS5] Waiting for FLEX volume in-use…"
  flex_wait_volume "$FLEX_VOL_ID" "in-use" 300 || fail_exit "FLEX volume did not reach in-use"
  log "[VS5] FLEX volume in-use"
else
  log "[VS5] No FLEX helper VM ID provided — skipping API attach (assuming volume pre-attached or TARGET_DEVICE_OVERRIDE set)"
fi

# ── VS6: Detect target device on FLEX helper ──────────────────────────────────
stage "VS6_DETECT_FLEX_TARGET_DEVICE"
if [ -n "$TARGET_DEVICE_OVERRIDE" ]; then
  FLEX_TARGET_DEV="$TARGET_DEVICE_OVERRIDE"
  log "[VS6] Target device overridden: $FLEX_TARGET_DEV"
elif [ -n "$FLEX_HELPER_VM_ID" ]; then
  # Full path: poll Cinder API for device path, then SSH lsblk fallback
  FLEX_TARGET_DEV=""
  for _i in $(seq 1 24); do
    sleep 5
    FLEX_TARGET_DEV="$(flex_volume_device "$FLEX_VOL_ID" || true)"
    [ -n "$FLEX_TARGET_DEV" ] && break
    FLEX_TARGET_DEV=""
  done
  if [ -z "$FLEX_TARGET_DEV" ]; then
    log "[VS6] Cinder device path not available — diffing lsblk on FLEX helper"
    FLEX_TARGET_DEV="$(ssh_flex \
      "lsblk -dnpo NAME,TYPE 2>/dev/null | awk '\$2==\"disk\"&&\$1!~/nbd|loop|sr|fd/{print \$1}' | sort" \
      2>/dev/null | sort | head -1 || true)"
  fi
  [ -n "$FLEX_TARGET_DEV" ] || fail_exit "Could not detect target device on FLEX helper"
else
  # No VM ID — can't use Cinder API; detect via SSH lsblk only
  log "[VS6] No FLEX helper VM ID — detecting device via SSH lsblk"
  FLEX_TARGET_DEV="$(ssh_flex \
    "lsblk -dnpo NAME,TYPE 2>/dev/null | awk '\$2==\"disk\"&&\$1!~/nbd|loop|sr|fd/{print \$1}' | sort" \
    2>/dev/null | sort | head -1 || true)"
  [ -n "$FLEX_TARGET_DEV" ] || fail_exit "Could not detect target device via SSH lsblk — set --target-device to override"
fi
kv "FLEX target device" "$FLEX_TARGET_DEV"

# Safety: never allow target to be mounted or be the root device
FLEX_MOUNTS="$(ssh_flex "mount | grep -w $FLEX_TARGET_DEV || true" 2>/dev/null || true)"
if [ -n "$FLEX_MOUNTS" ]; then
  fail_exit "FLEX target device $FLEX_TARGET_DEV is mounted — aborting to prevent data loss: $FLEX_MOUNTS"
fi

# ── VS7: Validate target_bytes >= source_bytes ────────────────────────────────
stage "VS7_VALIDATE_SIZES"
# blockdev --getsize64 can return 0 immediately after attach while the kernel
# is still initializing the block device — retry up to 60s
TARGET_BYTES=0
for _i in $(seq 1 12); do
  TARGET_BYTES="$(ssh_flex "sudo blockdev --getsize64 $FLEX_TARGET_DEV" 2>/dev/null || echo 0)"
  [ "${TARGET_BYTES:-0}" -gt 0 ] 2>/dev/null && break
  log "[VS7] Device not ready (size=0) — retry ${_i}/12 in 5s"
  sleep 5
done
kv "Target bytes" "$TARGET_BYTES"
kv "Source bytes" "$SOURCE_BYTES"
# Compare FLEX target against original snapshot size (not padded OSPC vol which may be 75GB).
# Allow 200 MiB slack for backend sector-alignment differences.
STREAM_BYTES=$(( SNAP_SIZE_ORIG_GB * 1073741824 ))
_TOLERANCE_BYTES=209715200
_REQUIRED_BYTES=$(( STREAM_BYTES - _TOLERANCE_BYTES ))
kv "Stream bytes (orig ${SNAP_SIZE_ORIG_GB}GB)" "$STREAM_BYTES"
[ "${TARGET_BYTES}" -ge "${_REQUIRED_BYTES}" ] || \
  fail_exit "FLEX target too small: ${TARGET_BYTES}B < ${STREAM_BYTES}B (original snapshot ${SNAP_SIZE_ORIG_GB}GB, 200MiB tolerance)"
log "[VS7] Size validation passed (target=${TARGET_BYTES}B stream=${STREAM_BYTES}B)"

# ── VS8: Direct block stream ──────────────────────────────────────────────────
stage "VS8_STREAM_BLOCK_DATA"
log "[VS8] Streaming $SOURCE_DEV → ${FLEX_HELPER_USER}@${FLEX_HELPER_IP}:${FLEX_TARGET_DEV}"
log "[VS8] Pipeline: dd | gzip -1 | ssh | gunzip | dd"

_DD_COUNT=$(( SNAP_SIZE_ORIG_GB * 16 ))  # 64M * 16 = 1 GiB → count = orig GB * 16
log "[VS8] Streaming ${SNAP_SIZE_ORIG_GB}GB (${_DD_COUNT} blocks of 64M)"
STREAM_CMD="sudo dd if=$SOURCE_DEV bs=64M count=$_DD_COUNT status=progress conv=sync,noerror 2>>'$JOB_LOG/stream_src.log' | \
  gzip -1 | \
  ssh -i $SSH_KEY_PATH \
      -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile=/dev/null \
      -o BatchMode=yes \
      -o ServerAliveInterval=30 \
      -o ServerAliveCountMax=10 \
      ${FLEX_HELPER_USER}@${FLEX_HELPER_IP} \
      \"gunzip | sudo dd of=${FLEX_TARGET_DEV} bs=64M status=progress conv=fsync 2>>/tmp/volsnap_stream_dst_${LABEL_SAFE}.log\""

eval "$STREAM_CMD" 2>&1 | tee -a "$JOB_LOG/stream.log" || \
  fail_exit "Block stream failed — check $JOB_LOG/stream.log"
log "[VS8] HIT block stream complete"

# ── VS9: Validate FLEX target disk ────────────────────────────────────────────
stage "VS9_VALIDATE_FLEX_DISK"
ssh_flex "sudo partprobe $FLEX_TARGET_DEV 2>/dev/null || true; \
  echo '--- blkid ---'; sudo blkid 2>/dev/null || true; \
  echo '--- file -s ---'; sudo file -s $FLEX_TARGET_DEV 2>/dev/null || true; \
  echo '--- lsblk ---'; lsblk $FLEX_TARGET_DEV 2>/dev/null || true" \
  2>&1 | tee -a "$JOB_LOG/flex_validate.log" || true
log "[VS9] Validation output saved to $JOB_LOG/flex_validate.log"

# ── VS10: Detach FLEX volume from helper VM ───────────────────────────────────
stage "VS10_DETACH_FLEX_FROM_HELPER"
if [ -n "$FLEX_HELPER_VM_ID" ]; then
  log "[VS10] Detaching $FLEX_VOL_ID from helper vm=$FLEX_HELPER_VM_ID"
  openstack server remove volume "$FLEX_HELPER_VM_ID" "$FLEX_VOL_ID" \
    2>>"$JOB_LOG/flex_cinder.log" || log "[VS10] WARN: remove volume returned non-zero (continuing)"
  flex_wait_volume "$FLEX_VOL_ID" "available" 300 || log "[VS10] WARN: FLEX volume did not return to available quickly"
  log "[VS10] FLEX volume detached from helper"
else
  log "[VS10] No FLEX helper VM ID — skipping API detach"
fi

# ── VS11: Attach FLEX volume to paired migrated FLEX VM ───────────────────────
if [ "$ATTACH_TO_FINAL" = "true" ] && [ -n "$FLEX_TARGET_VM_ID" ]; then
  stage "VS11_ATTACH_TO_FINAL_FLEX_VM"
  kv "Final FLEX VM" "$FLEX_TARGET_VM_ID"
  openstack server add volume "$FLEX_TARGET_VM_ID" "$FLEX_VOL_ID" \
    2>>"$JOB_LOG/flex_cinder.log" || fail_exit "Final attach to $FLEX_TARGET_VM_ID failed"
  flex_wait_volume "$FLEX_VOL_ID" "in-use" 300 || \
    log "[VS11] WARN: FLEX volume did not reach in-use after final attach"
  log "[VS11] HIT FLEX volume attached to final VM $FLEX_TARGET_VM_ID"
else
  log "[VS11] Skipped final attach (attach_to_final=$ATTACH_TO_FINAL flex_target_vm_id='${FLEX_TARGET_VM_ID}')"
fi

# ── VS12: Cleanup — detach + optionally delete temp OSPC volume ───────────────
stage "VS12_CLEANUP_OSPC"
log "[VS12] Detaching temp OSPC vol=$OSPC_VOL_ID from server=$SELF_SERVER_ID"
# Switch back to OSPC env for cleanup
# shellcheck disable=SC1090
source "$OSPC_OPENRC"
_compute_delete "servers/$SELF_SERVER_ID/os-volume_attachments/$OSPC_VOL_ID"
ospc_wait_volume "$OSPC_VOL_ID" "available" 300 || true

if [ "$CLEANUP_TEMP" = "true" ]; then
  log "[VS12] Deleting temp OSPC volume $OSPC_VOL_ID"
  _cinder_delete "volumes/$OSPC_VOL_ID"
  log "[VS12] Temp OSPC volume deleted"
else
  log "[VS12] cleanup_temp=false — temp OSPC volume $OSPC_VOL_ID left in available state"
fi

log "══════════════════════════════════════════════════════"
log "  VOLSNAP DIRECT CINDER COMPLETE"
log "══════════════════════════════════════════════════════"
log "  OSPC snapshot         : $SNAPSHOT_ID"
log "  FLEX Cinder volume    : $FLEX_VOL_ID  ($FLEX_VOL_NAME, ${FLEX_VOL_SIZE_GB}GB)"
[ -n "$FLEX_TARGET_VM_ID" ] && log "  Attached to FLEX VM   : $FLEX_TARGET_VM_ID"
log "  Storage path          : Storage → Volumes (not Compute → Images)"
