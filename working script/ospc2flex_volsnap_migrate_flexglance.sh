#!/usr/bin/env bash
# ospc2flex_volsnap_migrate.sh — Cinder volume snapshot → FLEX migration (runs on jumphost)
#
# VS1: Create Cinder volume from snapshot (no Glance, no overLimit risk)
# VS2: Attach volume to jumphost
# VS3: dd volume → source_snapshot.img
# VS4: Detach + delete temp Cinder volume
# Then exec → ospc2flex_linux_snap_migrate.sh for LS4-LS9 (repair, upload, boot, SSH)

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
OS_TYPE=""
NBD_DEV="${NBD_DEV:-/dev/nbd0}"
BASE_DIR="${OSPC2FLEX_LINUX_SNAP_BASE_DIR:-/mnt/migration/ospc2flex_linux_snap}"
MAIN_SCRIPT="${OSPC2FLEX_MAIN_SCRIPT:-/tmp/ospc2flex_linux_snap_migrate.sh}"
SNAP_SIZE_GB=75

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label)        LABEL="$2";        shift 2 ;;
    --snapshot-id)  SNAPSHOT_ID="$2";  shift 2 ;;
    --ospc-openrc)  OSPC_OPENRC="$2";  shift 2 ;;
    --flex-openrc)  FLEX_OPENRC="$2";  shift 2 ;;
    --os-type)      OS_TYPE="$2";      shift 2 ;;
    --nbd-dev)      NBD_DEV="$2";      shift 2 ;;
    --base-dir)     BASE_DIR="$2";     shift 2 ;;
    --snap-size-gb) SNAP_SIZE_GB="$2"; shift 2 ;;
    *) echo "ERROR: Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$LABEL" ]       || { echo "ERROR: --label required" >&2; exit 2; }
[ -n "$SNAPSHOT_ID" ] || { echo "ERROR: --snapshot-id required" >&2; exit 2; }
[ -n "$OSPC_OPENRC" ] || { echo "ERROR: --ospc-openrc required" >&2; exit 2; }
[ -n "$FLEX_OPENRC" ] || { echo "ERROR: --flex-openrc required" >&2; exit 2; }
[ -n "$OS_TYPE" ]     || { echo "ERROR: --os-type required" >&2; exit 2; }

LABEL_SAFE="$(printf '%s' "$LABEL" | tr -c 'A-Za-z0-9._-' '_' | sed 's/_$//')"
RUN_ID="${OSPC2FLEX_RUN_ID:-$(date -u +%Y%m%d-%H%M%S)}"
RUN_DIR="$BASE_DIR/runs/$LABEL_SAFE/$RUN_ID"
JOB_ART="$RUN_DIR/artifacts"
JOB_TMP="$RUN_DIR/tmp"
JOB_LOG="$RUN_DIR/logs"

mkdir -p "$JOB_ART" "$JOB_TMP" "$JOB_LOG"

# Tee all output to a log file
exec > >(tee -a "$JOB_LOG/volsnap_extract.log") 2>&1

log()      { printf '[%s][%s][VOLSNAP] %s\n' "$(date -u +%H:%M:%S)" "$LABEL_SAFE" "$*"; }
stage()    { log "══════════════════════════════════════════════════════"; log "  $1"; log "══════════════════════════════════════════════════════"; }
fail_exit(){ log "FAILED: $*"; exit 1; }

# ── Load OSPC creds ───────────────────────────────────────────────────────────
stage "VS0_LOAD_CREDENTIALS"
# shellcheck disable=SC1090
source "$OSPC_OPENRC"
TOKEN="${OS_TOKEN:-}"
TENANT="${OS_TENANT_ID:-${OS_PROJECT_ID:-}}"
[ -n "$TOKEN" ]  || fail_exit "OS_TOKEN not set in $OSPC_OPENRC"
[ -n "$TENANT" ] || fail_exit "OS_TENANT_ID not set in $OSPC_OPENRC"
log "OSPC tenant=$TENANT snapshot=$SNAPSHOT_ID label=$LABEL_SAFE"

BS_BASE="https://iad.blockstorage.api.rackspacecloud.com/v1/$TENANT"
COMPUTE_BASE="https://iad.servers.api.rackspacecloud.com/v2/$TENANT"

# ── Cinder helpers ────────────────────────────────────────────────────────────
_cinder_get() {
  curl -sS -H "X-Auth-Token: $TOKEN" "$BS_BASE/$1" 2>>"$JOB_LOG/cinder.log"
}
_cinder_post() {
  curl -sS -w '\nHTTP_CODE=%{http_code}\n' -X POST \
    -H "X-Auth-Token: $TOKEN" -H "Content-Type: application/json" \
    -d "$2" "$BS_BASE/$1" 2>>"$JOB_LOG/cinder.log"
}
_cinder_delete() {
  curl -sS -o /dev/null -X DELETE -H "X-Auth-Token: $TOKEN" "$BS_BASE/$1" 2>>"$JOB_LOG/cinder.log" || true
}
_compute_post() {
  curl -sS -w '\nHTTP_CODE=%{http_code}\n' -X POST \
    -H "X-Auth-Token: $TOKEN" -H "Content-Type: application/json" \
    -d "$2" "$COMPUTE_BASE/$1" 2>>"$JOB_LOG/cinder.log"
}
_compute_delete() {
  curl -sS -o /dev/null -X DELETE -H "X-Auth-Token: $TOKEN" "$COMPUTE_BASE/$1" 2>>"$JOB_LOG/cinder.log" || true
}

volume_status() {
  _cinder_get "volumes/$1" | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["volume"]["status"])' 2>/dev/null || echo unknown
}

cinder_wait_status() {
  local vid="$1" want="$2" timeout="${3:-3600}" waited=0 status
  while [ "$waited" -lt "$timeout" ]; do
    status="$(volume_status "$vid")"
    [ "$status" = "$want" ] && return 0
    [ "$status" = "error" ] && { log "[CINDER] vol=$vid entered error state"; return 1; }
    [ $((waited % 60)) -eq 0 ] && log "[CINDER] vol=$vid status=$status target=$want waited=${waited}s"
    sleep 10; waited=$((waited + 10))
  done
  log "[CINDER] TIMEOUT vol=$vid target=$want after ${timeout}s"
  return 1
}

local_block_disks() {
  sudo lsblk -dnpo NAME,TYPE 2>/dev/null | awk '$2=="disk" && $1 !~ /^\/dev\/(nbd|loop|sr|fd)/ {print $1}' | sort
}
find_new_block_disk() {
  comm -13 "$1" "$2" | while IFS= read -r c; do [ -b "$c" ] && printf '%s\n' "$c" && break; done | head -1
}

discover_self_server_id() {
  local ips_json server_json
  ips_json="$(hostname -I 2>/dev/null | tr ' ' '\n' | awk 'NF' | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
  server_json="$(openstack server list --long -f json 2>/dev/null || true)"
  LOCAL_IPS_JSON="$ips_json" SERVER_JSON="$server_json" python3 - <<'PY' 2>/dev/null || true
import json, os
try: rows = json.loads(os.environ.get("SERVER_JSON") or "[]")
except Exception: rows = []
try: ips = json.loads(os.environ.get("LOCAL_IPS_JSON") or "[]")
except Exception: ips = []
for row in rows:
    blob = json.dumps(row).lower()
    if any(ip and ip.lower() in blob for ip in ips):
        print(row.get("ID") or row.get("Id") or row.get("id") or ""); raise SystemExit
PY
}

# ── VS1: Create Cinder volume from snapshot ───────────────────────────────────
stage "VS1_CREATE_VOLUME_FROM_SNAPSHOT"
VOL_NAME="${LABEL_SAFE}-volsnap-${RUN_ID}"
PAYLOAD="$(SNAP_ID="$SNAPSHOT_ID" SIZE="$SNAP_SIZE_GB" VNAME="$VOL_NAME" python3 - <<'PY'
import json, os
print(json.dumps({"volume":{"snapshot_id":os.environ["SNAP_ID"],"size":int(os.environ["SIZE"]),"display_name":os.environ["VNAME"]}},separators=(",",":")))
PY
)"
RESP="$(_cinder_post "volumes" "$PAYLOAD")"
HTTP="$(printf '%s' "$RESP" | awk -F= '/HTTP_CODE=/{print $2}' | tail -1)"
BODY="$(printf '%s' "$RESP" | sed '/^HTTP_CODE=/d')"
case "$HTTP" in 200|202) ;; *) fail_exit "Cinder volume create HTTP=$HTTP body=${BODY:0:200}" ;; esac
VOL_ID="$(printf '%s' "$BODY" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("volume") or {}).get("id",""))' 2>/dev/null || true)"
[ -n "$VOL_ID" ] || fail_exit "No volume ID in create response: ${BODY:0:300}"
log "[CINDER] Created vol=$VOL_ID from snapshot=$SNAPSHOT_ID — waiting available"
cinder_wait_status "$VOL_ID" "available" 3600 || fail_exit "Volume $VOL_ID never became available"
log "[CINDER] vol=$VOL_ID available"

# ── VS2: Attach volume to jumphost ────────────────────────────────────────────
stage "VS2_ATTACH_VOLUME"
SERVER_ID="$(discover_self_server_id | head -1 | tr -d '[:space:]')"
[ -n "$SERVER_ID" ] || fail_exit "Could not determine jumphost Nova server ID"
log "[NOVA] server=$SERVER_ID attaching vol=$VOL_ID"

BEFORE_FILE="$JOB_TMP/before_disks.txt"
AFTER_FILE="$JOB_TMP/after_disks.txt"
local_block_disks >"$BEFORE_FILE"

ATTACH_PAYLOAD="$(VOL_ID="$VOL_ID" python3 - <<'PY'
import json, os; print(json.dumps({"volumeAttachment":{"volumeId":os.environ["VOL_ID"]}},separators=(",",":")))
PY
)"
ATTACH_RESP="$(_compute_post "servers/$SERVER_ID/os-volume_attachments" "$ATTACH_PAYLOAD")"
ATTACH_HTTP="$(printf '%s' "$ATTACH_RESP" | awk -F= '/HTTP_CODE=/{print $2}' | tail -1)"
case "$ATTACH_HTTP" in 200|202) ;; *) fail_exit "Volume attach HTTP=$ATTACH_HTTP" ;; esac

log "[NOVA] attach request OK — waiting in-use"
cinder_wait_status "$VOL_ID" "in-use" 300 || fail_exit "Volume $VOL_ID did not reach in-use"

# Get device path directly from Cinder attachment record (avoids parallel-job race condition)
NEW_DEV=""
for _i in $(seq 1 24); do
  sleep 5
  NEW_DEV="$(_cinder_get "volumes/$VOL_ID" | python3 -c \
    'import json,sys; v=json.load(sys.stdin)["volume"]; a=v.get("attachments") or []; print(a[0]["device"] if a else "")' \
    2>/dev/null || true)"
  [ -n "$NEW_DEV" ] && [ -b "$NEW_DEV" ] && break
  NEW_DEV=""
done
[ -n "$NEW_DEV" ] || fail_exit "Could not get device path from Cinder for vol $VOL_ID"
DEV_SIZE="$(sudo blockdev --getsize64 "$NEW_DEV" 2>/dev/null || echo 0)"
log "[NOVA] device from Cinder: $NEW_DEV size=${DEV_SIZE}B"
[ "$DEV_SIZE" -gt 1073741824 ] || fail_exit "Device $NEW_DEV too small: ${DEV_SIZE}B"

# ── VS3: Convert block device directly to qcow2 (no raw intermediate) ────────
# Direct-to-qcow2 avoids writing 75GB raw to disk — only compressed qcow2 size needed.
stage "VS3_CONVERT_TO_QCOW2"
QCOW="$JOB_ART/${LABEL_SAFE}.qcow2"
log "[CONVERT] qemu-img $NEW_DEV → $QCOW (direct, compressed)"
rm -f "$QCOW"
sudo qemu-img convert -p -f raw -O qcow2 -c "$NEW_DEV" "$QCOW" \
  2>&1 | tee -a "$JOB_LOG/extract.log"
sudo chown "$(id -u):$(id -g)" "$QCOW" 2>/dev/null || true
[ -f "$QCOW" ] || fail_exit "qemu-img convert from $NEW_DEV failed"
QCOW_SIZE="$(stat -c%s "$QCOW" 2>/dev/null || echo 0)"
log "[CONVERT] Done: $QCOW (${QCOW_SIZE}B)"
[ "$QCOW_SIZE" -gt 65536 ] || fail_exit "qcow2 too small after convert: ${QCOW_SIZE}B"

# ── VS4: Detach + delete temp volume ─────────────────────────────────────────
stage "VS4_CLEANUP_VOLUME"
log "[CINDER] Detaching vol=$VOL_ID from server=$SERVER_ID"
_compute_delete "servers/$SERVER_ID/os-volume_attachments/$VOL_ID"
cinder_wait_status "$VOL_ID" "available" 300 || true
_cinder_delete "volumes/$VOL_ID"
log "[CINDER] vol=$VOL_ID detached and deleted"

# ── Handoff: exec into main pipeline (LS4-LS9) ───────────────────────────────
log "══════════════════════════════════════════════════════"
log "  HANDOFF → ospc2flex_linux_snap_migrate.sh (LS4-LS9)"
log "══════════════════════════════════════════════════════"
log "  qcow2               : $QCOW"
log "  run_id              : $RUN_ID"
log "  os_type             : $OS_TYPE"
exec env OSPC2FLEX_RUN_ID="$RUN_ID" bash "$MAIN_SCRIPT" \
  --label         "$LABEL" \
  --ospc-image-id "volsnap-$SNAPSHOT_ID" \
  --ospc-openrc   "$OSPC_OPENRC" \
  --flex-openrc   "$FLEX_OPENRC" \
  --os-type       "$OS_TYPE" \
  --nbd-dev       "$NBD_DEV"
