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
# VOL_POST_ATTACH_VALIDATE: optionally mount migrated volume and optionally query PostgreSQL proof table
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
SOURCE_MODE="${OSPC2FLEX_SOURCE_MODE:-ospc}"
FLEX_HELPER_VM_ID=""
FLEX_HELPER_IP=""
FLEX_HELPER_USER="ubuntu"
SSH_KEY_PATH="${HOME}/.ssh/id_rsa"
FLEX_TARGET_VM_ID=""
OS_TYPE="linux"
FLEX_VOLUME_NAME_OVERRIDE=""
SNAP_SIZE_GB=0                      # 0 = auto-detect from snapshot
CLEANUP_TEMP="true"
ATTACH_TO_FINAL="true"
SOURCE_DEVICE_OVERRIDE=""
TARGET_DEVICE_OVERRIDE=""
POST_ATTACH_VALIDATE_MOUNT="false"
POST_ATTACH_VALIDATE_PG="false"
POST_ATTACH_DB_VALIDATOR="none"
POST_ATTACH_CUSTOM_VALIDATE_CMD=""
POST_ATTACH_PG_DB_NAME="openstack_drinks"
POST_ATTACH_PG_TABLE_NAME="preferred_drinks"
POST_ATTACH_MOUNT_POINT=""
POST_ATTACH_DEVICE_HINT=""
POST_ATTACH_SSH_USER="ubuntu"
POST_ATTACH_SSH_KEY_PATH="${HOME}/.ssh/id_rsa"
POST_ATTACH_SSH_IP=""
POST_ATTACH_ALLOW_LUKS_OPEN="true"
POST_ATTACH_ALLOW_LVM_ACTIVATE="true"
POST_ATTACH_UPDATE_POSTGRESQL_CONF="true"
POST_ATTACH_START_POSTGRESQL="true"
POST_ATTACH_SCRIPT_PATH="/tmp/osflex_post_attach_pg_mount_validate.sh"
BASE_DIR="${VOLSNAP_RUN_ROOT:-${OSPC2FLEX_VOLSNAP_BASE_DIR:-${OSPC2FLEX_LINUX_SNAP_BASE_DIR:-/mnt/migration/ospc2flex_linux_snap}}}"
START_FRESH="${VOLSNAP_START_FRESH:-0}"
JUMPHOST_MIN_FREE_GB="${OSPC2FLEX_JUMPHOST_MIN_FREE_GB:-${VOLSNAP_MIN_FREE_GB:-120}}"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label)               LABEL="$2";                  shift 2 ;;
    --snapshot-id)         SNAPSHOT_ID="$2";             shift 2 ;;
    --ospc-openrc)         OSPC_OPENRC="$2";             shift 2 ;;
    --flex-openrc)         FLEX_OPENRC="$2";             shift 2 ;;
    --source-mode)         SOURCE_MODE="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"; shift 2 ;;
    --flex-helper-vm-id)   FLEX_HELPER_VM_ID="$2";       shift 2 ;;
    --flex-helper-ip)      FLEX_HELPER_IP="$2";          shift 2 ;;
    --flex-helper-user)    FLEX_HELPER_USER="$2";        shift 2 ;;
    --ssh-key-path)        SSH_KEY_PATH="$2";            shift 2 ;;
    --flex-target-vm-id)   FLEX_TARGET_VM_ID="$2";       shift 2 ;;
    --os-type)             OS_TYPE="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"; shift 2 ;;
    --flex-volume-name)    FLEX_VOLUME_NAME_OVERRIDE="$2"; shift 2 ;;
    --snap-size-gb)        SNAP_SIZE_GB="$2";            shift 2 ;;
    --cleanup-temp)        CLEANUP_TEMP="$2";            shift 2 ;;
    --attach-to-final)     ATTACH_TO_FINAL="$2";         shift 2 ;;
    --source-device)       SOURCE_DEVICE_OVERRIDE="$2";  shift 2 ;;
    --target-device)       TARGET_DEVICE_OVERRIDE="$2";  shift 2 ;;
    --post-attach-validate-mount) POST_ATTACH_VALIDATE_MOUNT="$2"; shift 2 ;;
    --post-attach-validate-pg) POST_ATTACH_VALIDATE_PG="$2"; shift 2 ;;
    --post-attach-db-validator) POST_ATTACH_DB_VALIDATOR="$2"; shift 2 ;;
    --post-attach-custom-validate-cmd) POST_ATTACH_CUSTOM_VALIDATE_CMD="$2"; shift 2 ;;
    --post-attach-pg-db-name) POST_ATTACH_PG_DB_NAME="$2"; shift 2 ;;
    --post-attach-pg-table-name) POST_ATTACH_PG_TABLE_NAME="$2"; shift 2 ;;
    --post-attach-mount-point) POST_ATTACH_MOUNT_POINT="$2"; shift 2 ;;
    --post-attach-device-hint) POST_ATTACH_DEVICE_HINT="$2"; shift 2 ;;
    --post-attach-ssh-user) POST_ATTACH_SSH_USER="$2"; shift 2 ;;
    --post-attach-ssh-key-path) POST_ATTACH_SSH_KEY_PATH="$2"; shift 2 ;;
    --post-attach-ssh-ip) POST_ATTACH_SSH_IP="$2"; shift 2 ;;
    --post-attach-allow-luks-open) POST_ATTACH_ALLOW_LUKS_OPEN="$2"; shift 2 ;;
    --post-attach-allow-lvm-activate) POST_ATTACH_ALLOW_LVM_ACTIVATE="$2"; shift 2 ;;
    --post-attach-update-postgresql-conf) POST_ATTACH_UPDATE_POSTGRESQL_CONF="$2"; shift 2 ;;
    --post-attach-start-postgresql) POST_ATTACH_START_POSTGRESQL="$2"; shift 2 ;;
    --post-attach-script-path) POST_ATTACH_SCRIPT_PATH="$2"; shift 2 ;;
    --base-dir)            BASE_DIR="$2";                shift 2 ;;
    --start-fresh)         START_FRESH=1;                shift ;;
    --dry-run)             DRY_RUN=1;                    shift ;;
    # legacy compat — ignored
    --nbd-dev)             shift 2 ;;
    *) echo "ERROR: Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$LABEL" ]             || { echo "ERROR: --label required" >&2; exit 2; }
[ -n "$SNAPSHOT_ID" ]       || { echo "ERROR: --snapshot-id required" >&2; exit 2; }
case "$SOURCE_MODE" in ospc|flex) ;; *) echo "ERROR: --source-mode must be ospc or flex" >&2; exit 2 ;; esac
if [ "$DRY_RUN" != 1 ]; then
  [ -n "$OSPC_OPENRC" ]       || { echo "ERROR: --ospc-openrc required" >&2; exit 2; }
  [ -n "$FLEX_OPENRC" ]       || { echo "ERROR: --flex-openrc required" >&2; exit 2; }
  [ -n "$FLEX_HELPER_IP" ]    || { echo "ERROR: --flex-helper-ip required" >&2; exit 2; }
fi

LABEL_SAFE="$(printf '%s' "$LABEL" | tr -c 'A-Za-z0-9._-' '_' | sed 's/_$//')"
if [ "$OS_TYPE" = "linux" ]; then
  case "$(printf '%s' "$LABEL_SAFE" | tr '[:upper:]' '[:lower:]')" in
    *win*|*windows*) OS_TYPE="windows" ;;
  esac
fi
RUN_ID="${OSPC2FLEX_RUN_ID:-$(date -u +%Y%m%d-%H%M%S)}"
RUN_DIR="$BASE_DIR/runs/$LABEL_SAFE/$RUN_ID"
JOB_ART="$RUN_DIR/artifacts"
JOB_TMP="$RUN_DIR/tmp"
JOB_LOG="$RUN_DIR/logs"
OSPC_VOL_ID=""
SELF_SERVER_ID=""
FLEX_VOL_ID=""
FLEX_TARGET_DEV=""
CLEANUP_DONE=0
FLEX_FINAL_ATTACHED=0
RESUME_STREAM_DONE=0
RESUME_FINAL_ATTACHED=0
RESUME_SOURCE_RUN=""
RESUME_SOURCE_STATUS=""

mkdir -p "$JOB_ART" "$JOB_TMP" "$JOB_LOG"
exec > >(tee -a "$JOB_LOG/volsnap_direct.log") 2>&1

log()      { printf '[%s][%s][VOLSNAP] %s\n' "$(date -u +%H:%M:%S)" "$LABEL_SAFE" "$*"; }
stage()    { log "══════════════════════════════════════════════════════"; log "  $1"; log "══════════════════════════════════════════════════════"; }
fail_exit(){ log "FAILED: $*"; exit 1; }
kv()       { log "  $(printf '%-24s' "$1"): $2"; }
mb_from_bytes() {
  local n="${1:-0}"
  awk -v n="$n" 'BEGIN{if(n>0) printf "%.0f", n/1048576; else printf "0"}'
}
gib_to_bytes() {
  awk -v gb="${1:-0}" 'BEGIN{printf "%.0f", gb*1024*1024*1024}'
}
bytes_to_gib() {
  awk -v b="${1:-0}" 'BEGIN{printf "%.1f", b/1024/1024/1024}'
}
available_bytes_for_path() {
  local p="$1"
  df -PB1 "$p" 2>/dev/null | awk 'NR==2{print $4+0}'
}
require_jumphost_min_free_gb() {
  local path="$1" min_gb="$2" context="$3" avail required
  required="$(gib_to_bytes "$min_gb")"
  avail="$(available_bytes_for_path "$path")"
  [ -n "$avail" ] || fail_exit "$context: could not determine free space for $path"
  log "[SPACE] $context: required=$(bytes_to_gib "$required") GiB available=$(bytes_to_gib "$avail") GiB path=$path"
  if [ "$avail" -lt "$required" ]; then
    fail_exit "Insufficient jumphost workspace after stale cleanup for $context: required $(bytes_to_gib "$required") GiB, available $(bytes_to_gib "$avail") GiB. Clean /mnt/migration or increase the jumphost volume before retry."
  fi
}
download_progress_bar() {
  local phase="$1" downloaded_mb="${2:-0}" total_mb="${3:-0}" status="${4:-unknown}" eta_min="${5:-}" pct="${6:-}"
  if [ -z "$pct" ] || [ "$pct" = "unknown" ]; then
    pct="$(awk -v d="$downloaded_mb" -v t="$total_mb" 'BEGIN{if(t>0) printf "%.1f", (d/t)*100; else printf "0.0"}')"
  fi
  local filled empty bar
  filled="$(awk -v p="$pct" 'BEGIN{n=int(p/5); if(n<0)n=0; if(n>20)n=20; print n}')"
  empty=$((20 - filled))
  bar="$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' "$empty" '' | tr ' ' '-')"
  log "[DOWNLOAD_BAR] phase=$phase [$bar] ${pct}% ${downloaded_mb}/${total_mb}MB status=${status}${eta_min:+ eta_min=$eta_min}"
}
log_download_status() {
  local phase="$1" downloaded_mb="${2:-0}" total_mb="${3:-0}" status="${4:-unknown}" pct="${5:-}" eta_min="${6:-}" extra="${7:-}"
  if [ -z "$pct" ] || [ "$pct" = "unknown" ]; then
    pct="$(awk -v d="$downloaded_mb" -v t="$total_mb" 'BEGIN{if(t>0) printf "%.1f", (d/t)*100; else printf "0.0"}')"
  fi
  log "[DOWNLOAD_STATUS] phase=$phase downloaded_mb=$downloaded_mb total_mb=$total_mb pct=$pct${eta_min:+ eta_min=$eta_min} status=$status${extra:+ $extra}"
  download_progress_bar "$phase" "$downloaded_mb" "$total_mb" "$status" "$eta_min" "$pct"
}

prep_disk_and_stale_image_cleanup() {
  [ "${VOLSNAP_CLEAN_STALE_IMAGES:-1}" = "1" ] || {
    log "[VS0A] stale image cleanup disabled"
    return 0
  }

  local before after min_age_minutes
  before="$(df -hP "$BASE_DIR" 2>/dev/null | awk 'NR==2{print $4 " free / " $2 " total (" $5 " used)"}' || true)"
  log "[VS0A] run root disk before cleanup: ${before:-unknown}"

  min_age_minutes="${VOLSNAP_CLEAN_MIN_AGE_MIN:-60}"
  case "$min_age_minutes" in ''|*[!0-9]*) min_age_minutes=60 ;; esac

  local roots=()
  [ -d /mnt/migration/flex2flex ] && roots+=("/mnt/migration/flex2flex")
  [ -d /mnt/migration/ospc2flex_method_z ] && roots+=("/mnt/migration/ospc2flex_method_z")
  [ -d /mnt/migration/ospc2flex_image ] && roots+=("/mnt/migration/ospc2flex_image")
  [ -d /mnt/migration/ospc2flex_linux_snap ] && roots+=("/mnt/migration/ospc2flex_linux_snap")

  local delete_list="$JOB_TMP/stale_image_delete.tsv"
  : >"$delete_list"

  local root root_real
  for root in "${roots[@]}"; do
    [ -d "$root" ] || continue
    root_real="$(readlink -f "$root" 2>/dev/null || true)"
    case "$root_real" in
      /mnt/migration|/mnt/migration/*) ;;
      *) log "[VS0A] refusing stale image cleanup outside /mnt/migration: $root"; continue ;;
    esac
    find "$root" -xdev -type f -mmin +"$min_age_minutes" \( \
        -iname "*.img" -o -iname "*.raw" -o -iname "*.vhd" -o -iname "*.vhdx" -o -iname "*.vmdk" -o -iname "*.vpc" \
        -o -iname "*repaired*.qcow2" -o -iname "*repair*.qcow2" \
        -o -iname "*flex-rescue*.qcow2" -o -iname "*safe-ide*.qcow2" -o -iname "*final*.qcow2" -o -iname "*rescue*.qcow2" \
        -o -iname "*.invalid*" -o -iname "*.partial*" \
      \) -printf '%s\t%p\n' 2>/dev/null >>"$delete_list" || true
  done

  sort -nr -u -o "$delete_list" "$delete_list" 2>/dev/null || true
  local count bytes
  count="$(wc -l <"$delete_list" | tr -d '[:space:]')"
  bytes="$(awk -F '\t' '{s+=$1} END{printf "%.0f", s+0}' "$delete_list")"
  if [ "${count:-0}" -eq 0 ]; then
    log "[VS0A] no stale image files found; keeping unrepaired qcow2 files"
    after="$(df -hP "$BASE_DIR" 2>/dev/null | awk 'NR==2{print $4 " free / " $2 " total (" $5 " used)"}' || true)"
    log "[VS0A] run root disk after cleanup: ${after:-unknown}"
    require_jumphost_min_free_gb "$BASE_DIR" "$JUMPHOST_MIN_FREE_GB" "volume snapshot migration preflight"
    return 0
  fi

  log "[VS0A] stale image cleanup candidates older than ${min_age_minutes}m: count=$count bytes=$bytes"
  local deleted=0 freed=0 sz path run_root
  while IFS=$'\t' read -r sz path; do
    [ -n "$path" ] || continue
    case "$(basename "$path")" in
      source_snapshot.qcow2|source_snapshot-*.qcow2)
        log "[VS0A] keep unrepaired source qcow2: $path"
        continue
        ;;
    esac
    run_root="$(printf '%s\n' "$path" | sed -E 's#^(/mnt/migration/flex2flex/[^/]+).*#\1#; s#^(/mnt/migration/ospc2flex_method_z/runs/[^/]+/[^/]+).*#\1#; s#^(/mnt/migration/ospc2flex_image/[^/]+).*#\1#')"
    if [ -n "$run_root" ] && ps -eo args= 2>/dev/null | grep -F -- "$run_root" | grep -vq grep; then
      log "[VS0A] keep active run artifact: $path"
      continue
    fi
    case "$path" in
      /mnt/migration/*)
        log "[VS0A] delete stale image: ${sz}B $path"
        rm -f -- "$path" 2>/dev/null || sudo rm -f -- "$path" 2>/dev/null || true
        deleted=$((deleted + 1))
        freed=$((freed + ${sz:-0}))
        ;;
      *) log "[VS0A] skip unsafe stale image path: $path" ;;
    esac
  done <"$delete_list"
  log "[VS0A] stale image cleanup complete; deleted=$deleted freed_bytes=$freed"
  after="$(df -hP "$BASE_DIR" 2>/dev/null | awk 'NR==2{print $4 " free / " $2 " total (" $5 " used)"}' || true)"
  log "[VS0A] run root disk after cleanup: ${after:-unknown}"
  require_jumphost_min_free_gb "$BASE_DIR" "$JUMPHOST_MIN_FREE_GB" "volume snapshot migration preflight"
}

start_fresh_clear_label_resume() {
  [ "$START_FRESH" = "1" ] || return 0
  local label_root="$BASE_DIR/runs/$LABEL_SAFE"
  [ -d "$label_root" ] || return 0
  log "[VS0B] START FRESH: deleting previous VOLSNAP resume artifacts for $LABEL_SAFE"
  find "$label_root" -mindepth 1 -maxdepth 1 -type d ! -name "$RUN_ID" -print 2>/dev/null | while read -r old_run; do
    [ -n "$old_run" ] || continue
    case "$old_run" in
      "$label_root"/*)
        log "[VS0B] delete old run: $old_run"
        rm -rf -- "$old_run"
        ;;
      *)
        log "[VS0B] skip outside label root: $old_run"
        ;;
    esac
  done
}

if [ "$DRY_RUN" = 1 ]; then
  source_label="OSPC"
  [ "$SOURCE_MODE" = "flex" ] && source_label="SOURCE_FLEX"
  for s in \
    VS0_LOAD_CREDENTIALS \
    VS1_CREATE_TEMP_${source_label}_VOLUME \
    VS2_ATTACH_${source_label}_VOLUME \
    VS3_GET_SOURCE_SIZE \
    VS4_CREATE_FLEX_CINDER_VOLUME \
    VS5_ATTACH_FLEX_VOLUME_TO_HELPER \
    VS6_DETECT_FLEX_TARGET_DEVICE \
    VS7_VALIDATE_SIZES \
    VS8_STREAM_BLOCK_DATA \
    VS9_VALIDATE_FLEX_DISK \
    VS10_DETACH_FLEX_FROM_HELPER \
    VOL_POST_ATTACH_VALIDATE \
    VS12_CLEANUP_${source_label}
  do
    stage "$s"
    log "[$s] DRY-RUN volume snapshot stage; no Cinder volume create, attach, block stream, detach, or delete"
  done
  log "METHOD_VOLSNAP_DRY_RUN_SUCCESS"
  exit 0
fi

cleanup_on_exit() {
  local rc=$?
  [ "$CLEANUP_DONE" = "1" ] && return "$rc"
  CLEANUP_DONE=1
  [ "$rc" -eq 0 ] && return 0

  log "[CLEANUP] Failure cleanup start rc=$rc"
  if [ -n "${FLEX_VOL_ID:-}" ] && [ -n "${FLEX_HELPER_VM_ID:-}" ] && [ "$FLEX_FINAL_ATTACHED" != "1" ]; then
    # shellcheck disable=SC1090
    source "$FLEX_OPENRC" 2>/dev/null || true
    log "[CLEANUP] Detaching FLEX volume $FLEX_VOL_ID from helper $FLEX_HELPER_VM_ID"
    openstack server remove volume "$FLEX_HELPER_VM_ID" "$FLEX_VOL_ID" >>"$JOB_LOG/flex_cinder.log" 2>&1 || true
  elif [ -n "${FLEX_VOL_ID:-}" ] && [ "$FLEX_FINAL_ATTACHED" = "1" ]; then
    log "[CLEANUP] Keeping migrated FLEX volume $FLEX_VOL_ID attached to final target after post-copy failure"
  fi
  if [ -n "${OSPC_VOL_ID:-}" ] && [ -n "${SELF_SERVER_ID:-}" ]; then
    source_label="OSPC"
    [ "$SOURCE_MODE" = "flex" ] && source_label="SOURCE FLEX"
    log "[CLEANUP] Detaching $source_label temp volume $OSPC_VOL_ID from $SELF_SERVER_ID"
    source_detach_volume "$SELF_SERVER_ID" "$OSPC_VOL_ID" || true
    source_wait_volume "$OSPC_VOL_ID" "available" 300 || true
    if [ "$CLEANUP_TEMP" = "true" ]; then
      log "[CLEANUP] Deleting $source_label temp volume $OSPC_VOL_ID"
      source_delete_volume "$OSPC_VOL_ID" || true
    fi
  fi
  log "[CLEANUP] Failure cleanup complete"
  return "$rc"
}
trap cleanup_on_exit EXIT
prep_disk_and_stale_image_cleanup
start_fresh_clear_label_resume

# ── SSH helper to FLEX helper VM ──────────────────────────────────────────────
SSH_FLEX_BASE=()
set_ssh_flex_base() {
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
}
set_ssh_flex_base
ssh_flex() { "${SSH_FLEX_BASE[@]}" "$@"; }

# ── OSPC Cinder/Compute REST helpers (use saved OSPC_TOKEN, never overwritten) ─
_cinder_get()    { curl -sS --connect-timeout 15 --max-time 45 -H "X-Auth-Token: $OSPC_TOKEN" "$OSPC_BS_BASE/$1" 2>>"$JOB_LOG/cinder.log"; }
_cinder_post()   { curl -sS --connect-timeout 15 --max-time 60 -w '\nHTTP_CODE=%{http_code}\n' -X POST \
                     -H "X-Auth-Token: $OSPC_TOKEN" -H "Content-Type: application/json" \
                     -d "$2" "$OSPC_BS_BASE/$1" 2>>"$JOB_LOG/cinder.log"; }
_cinder_delete() { curl -sS --connect-timeout 15 --max-time 45 -o /dev/null -X DELETE -H "X-Auth-Token: $OSPC_TOKEN" \
                     "$OSPC_BS_BASE/$1" 2>>"$JOB_LOG/cinder.log" || true; }
_compute_post()  { curl -sS --connect-timeout 15 --max-time 60 -w '\nHTTP_CODE=%{http_code}\n' -X POST \
                     -H "X-Auth-Token: $OSPC_TOKEN" -H "Content-Type: application/json" \
                     -d "$2" "$OSPC_COMPUTE_BASE/$1" 2>>"$JOB_LOG/cinder.log"; }
_compute_delete(){ curl -sS --connect-timeout 15 --max-time 45 -o /dev/null -X DELETE -H "X-Auth-Token: $OSPC_TOKEN" \
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
    log "[OSPC] vol=$vid status=$status → $want (${waited}s)"
    sleep 10; waited=$((waited + 10))
  done
  log "[OSPC] TIMEOUT vol=$vid target=$want after ${timeout}s"; return 1
}

source_openrc() {
  unset OS_TOKEN OS_AUTH_TYPE OS_AUTH_URL OS_TENANT_ID OS_TENANT_NAME \
        OS_REGION_NAME OS_IDENTITY_API_VERSION OS_INTERFACE \
        OS_PROJECT_ID OS_PROJECT_NAME OS_USER_DOMAIN_NAME OS_PROJECT_DOMAIN_NAME \
        OS_PROJECT_DOMAIN_ID OS_USERNAME OS_PASSWORD \
        OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_SECRET
  # shellcheck disable=SC1090
  source "$OSPC_OPENRC"
}
source_volume_status() {
  local vid="$1"
  if [ "$SOURCE_MODE" = "flex" ]; then
    source_openrc
    openstack volume show "$vid" -f value -c status 2>/dev/null || echo unknown
  else
    ospc_volume_status "$vid"
  fi
}
source_wait_volume() {
  local vid="$1" want="$2" timeout="${3:-3600}" waited=0 status label="OSPC"
  [ "$SOURCE_MODE" = "flex" ] && label="SOURCE-FLEX"
  while [ "$waited" -lt "$timeout" ]; do
    status="$(source_volume_status "$vid")"
    [ "$status" = "$want" ] && return 0
    [ "$status" = "error" ] && { log "[$label] vol=$vid error state"; return 1; }
    log "[$label] vol=$vid status=$status → $want (${waited}s)"
    sleep 10; waited=$((waited + 10))
  done
  log "[$label] TIMEOUT vol=$vid target=$want after ${timeout}s"; return 1
}
source_volume_device() {
  local vid="$1"
  if [ "$SOURCE_MODE" = "flex" ]; then
    source_openrc
    openstack volume show "$vid" -f json 2>/dev/null | python3 -c \
      'import json,sys; v=json.load(sys.stdin); a=v.get("attachments") or []; print(a[0].get("device","") if a else "")' \
      2>/dev/null || true
  else
    _cinder_get "volumes/$vid" | python3 -c \
      'import json,sys; v=json.load(sys.stdin)["volume"]; a=v.get("attachments") or []; print(a[0]["device"] if a else "")' \
      2>/dev/null || true
  fi
}
source_detach_volume() {
  local server_id="$1" vid="$2"
  if [ "$SOURCE_MODE" = "flex" ]; then
    source_openrc
    openstack server remove volume "$server_id" "$vid" >>"$JOB_LOG/source_flex_cinder.log" 2>&1 || true
  else
    _compute_delete "servers/$server_id/os-volume_attachments/$vid"
  fi
}
source_delete_volume() {
  local vid="$1"
  if [ "$SOURCE_MODE" = "flex" ]; then
    source_openrc
    openstack volume delete "$vid" >>"$JOB_LOG/source_flex_cinder.log" 2>&1 || true
  else
    _cinder_delete "volumes/$vid"
  fi
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
    log "[FLEX] vol=$vid status=$status → $want (${waited}s)"
    sleep 10; waited=$((waited + 10))
  done
  log "[FLEX] TIMEOUT vol=$vid target=$want after ${timeout}s"; return 1
}
flex_wait_volume_deleted() {
  local vid="$1" timeout="${2:-300}" waited=0
  while [ "$waited" -lt "$timeout" ]; do
    if ! openstack volume show "$vid" >/dev/null 2>&1; then
      return 0
    fi
    [ $((waited % 60)) -eq 0 ] && log "[FLEX] vol=$vid waiting for delete (${waited}s)"
    sleep 10
    waited=$((waited + 10))
  done
  log "[FLEX] TIMEOUT vol=$vid delete after ${timeout}s"; return 1
}
flex_server_status() {
  openstack server show "$1" -f value -c status 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo unknown
}
flex_wait_server_status() {
  local server_id="$1" want="$2" timeout="${3:-600}" waited=0 status
  want="$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')"
  while [ "$waited" -lt "$timeout" ]; do
    status="$(flex_server_status "$server_id")"
    [ "$status" = "$want" ] && return 0
    [ "$status" = "error" ] && { log "[FLEX] server=$server_id error state"; return 1; }
    [ $((waited % 60)) -eq 0 ] && log "[FLEX] server=$server_id status=${status:-unknown} → $want (${waited}s)"
    sleep 10
    waited=$((waited + 10))
  done
  log "[FLEX] TIMEOUT server=$server_id target=$want after ${timeout}s"; return 1
}
flex_volume_device() {
  openstack volume show "$1" -f json 2>/dev/null | python3 -c \
    'import json,sys; v=json.load(sys.stdin); a=v.get("attachments") or []; print(a[0].get("device","") if a else "")' \
    2>/dev/null || true
}
flex_volume_attached_to() {
  local vid="$1" server_id="$2"
  [ -n "$vid" ] && [ -n "$server_id" ] || return 1
  openstack volume show "$vid" -f json 2>>"$JOB_LOG/flex_cinder.log" | python3 -c 'import json,sys
server_id=sys.argv[1]
try:
    vol=json.load(sys.stdin)
except Exception:
    sys.exit(1)
for att in vol.get("attachments") or []:
    if isinstance(att, dict) and (att.get("server_id") or att.get("serverId") or att.get("server") or "") == server_id:
        sys.exit(0)
sys.exit(1)
' "$server_id" 2>>"$JOB_LOG/flex_cinder.log"
}
flex_attach_volume_to_server_verified() {
  local server_id="$1" vid="$2" label="${3:-VS11}" attempt waited status
  [ -n "$server_id" ] && [ -n "$vid" ] || return 1

  for attempt in 1 2 3; do
    if flex_volume_attached_to "$vid" "$server_id"; then
      log "[$label] HIT FLEX volume attached to final VM $server_id"
      return 0
    fi

    status="$(flex_volume_status "$vid")"
    log "[$label] Attach attempt $attempt: $vid -> $server_id (status=${status:-unknown})"
    openstack server add volume "$server_id" "$vid" \
      >>"$JOB_LOG/flex_cinder.log" 2>&1 || true

    waited=0
    while [ "$waited" -lt 120 ]; do
      sleep 10
      waited=$((waited + 10))
      if flex_volume_attached_to "$vid" "$server_id"; then
        log "[$label] HIT FLEX volume attached to final VM $server_id"
        return 0
      fi
      status="$(flex_volume_status "$vid")"
      if [ "$status" = "available" ] && [ "$waited" -ge 20 ]; then
        log "[$label] Attach attempt $attempt did not stick; volume returned to available"
        break
      fi
      [ $((waited % 60)) -eq 0 ] && log "[$label] vol=$vid status=${status:-unknown} waiting for attachment to $server_id (${waited}s)"
    done
  done

  openstack volume show "$vid" -f json >>"$JOB_LOG/flex_cinder.log" 2>&1 || true
  return 1
}
flex_cold_attach_volume_to_server_verified() {
  local server_id="$1" vid="$2" label="${3:-VS11}" was_active="false" status
  [ -n "$server_id" ] && [ -n "$vid" ] || return 1
  if flex_volume_attached_to "$vid" "$server_id"; then
    log "[$label] HIT FLEX volume attached to final VM $server_id"
    return 0
  fi

  status="$(flex_server_status "$server_id")"
  log "[$label] Cold attach fallback: final VM $server_id status=${status:-unknown}"
  if [ "$status" = "active" ]; then
    was_active="true"
    log "[$label] Cold attach fallback: stopping final VM $server_id"
    openstack server stop "$server_id" >>"$JOB_LOG/flex_cinder.log" 2>&1 || return 1
    flex_wait_server_status "$server_id" "shutoff" 900 || return 1
  elif [ "$status" != "shutoff" ]; then
    log "[$label] Cold attach fallback: waiting for final VM $server_id to settle before attach"
    flex_wait_server_status "$server_id" "shutoff" 300 || return 1
  fi

  flex_wait_volume "$vid" "available" 300 || return 1
  log "[$label] Cold attach fallback: attaching $vid -> $server_id while VM is shutoff"
  openstack server add volume "$server_id" "$vid" >>"$JOB_LOG/flex_cinder.log" 2>&1 || return 1
  for waited in $(seq 10 10 300); do
    sleep 10
    if flex_volume_attached_to "$vid" "$server_id"; then
      log "[$label] HIT FLEX volume cold-attached to final VM $server_id"
      if [ "$was_active" = "true" ]; then
        log "[$label] Cold attach fallback: starting final VM $server_id"
        openstack server start "$server_id" >>"$JOB_LOG/flex_cinder.log" 2>&1 || return 1
        flex_wait_server_status "$server_id" "active" 900 || return 1
      fi
      return 0
    fi
    status="$(flex_volume_status "$vid")"
    [ $((waited % 60)) -eq 0 ] && log "[$label] Cold attach fallback: vol=$vid status=${status:-unknown} waiting for attachment (${waited}s)"
  done

  openstack volume show "$vid" -f json >>"$JOB_LOG/flex_cinder.log" 2>&1 || true
  return 1
}
flex_final_attach_volume_to_server_verified() {
  local server_id="$1" vid="$2" label="${3:-VS11}"
  flex_attach_volume_to_server_verified "$server_id" "$vid" "$label" && return 0
  if [ "$OS_TYPE" = "windows" ]; then
    log "[$label] Hot attach did not stick for Windows target; trying cold attach fallback"
    flex_cold_attach_volume_to_server_verified "$server_id" "$vid" "$label" && return 0
  fi
  return 1
}
flex_find_resume_volume() {
  local name="$1" stream_bytes="$2" base="$BASE_DIR/runs/$LABEL_SAFE"
  local run log src vid bytes tmp vol_name status servers device
  [ "$START_FRESH" = "1" ] && return 1
  [ -d "$base" ] || return 1
  while IFS= read -r run; do
    [ -n "$run" ] || continue
    [ "$run" = "$RUN_DIR" ] && continue
    log="$run/logs/volsnap_direct.log"
    src="$run/logs/stream_src.log"
    [ -s "$log" ] && [ -s "$src" ] || continue
    vid="$(awk -F': ' '/FLEX volume ID/{v=$NF} END{gsub(/[[:space:]\r]+/,"",v); print v}' "$log")"
    [ -n "$vid" ] || continue
    bytes="$(python3 -c 'import re,sys
try:
    data=open(sys.argv[1],"rb").read().decode("utf-8","ignore")
except Exception:
    data=""
nums=[int(x) for x in re.findall(r"(\d+)\s+bytes", data)]
print(max(nums) if nums else 0)
' "$src" 2>/dev/null || echo 0)"
    [ "${bytes:-0}" -ge "$stream_bytes" ] 2>/dev/null || continue
    tmp="$JOB_TMP/resume_${vid}.json"
    openstack volume show "$vid" -f json >"$tmp" 2>>"$JOB_LOG/flex_cinder.log" || continue
    vol_name="$(python3 -c 'import json,sys; v=json.load(open(sys.argv[1])); print(v.get("name") or v.get("Name") or "")' "$tmp" 2>/dev/null || true)"
    [ "$vol_name" = "$name" ] || continue
    status="$(python3 -c 'import json,sys; v=json.load(open(sys.argv[1])); print(v.get("status") or v.get("Status") or "")' "$tmp" 2>/dev/null || true)"
    servers="$(python3 -c 'import json,sys
v=json.load(open(sys.argv[1]))
out=[]
for att in v.get("attachments") or []:
    if isinstance(att, dict):
        sid=att.get("server_id") or att.get("serverId") or att.get("server") or ""
        if sid:
            out.append(sid)
print(",".join(out))
' "$tmp" 2>/dev/null || true)"
    case "$status" in
      available) ;;
      in-use)
        case ",$servers," in
          *",$FLEX_HELPER_VM_ID,"*|*",$FLEX_TARGET_VM_ID,"*) ;;
          *) continue ;;
        esac
        ;;
      *) continue ;;
    esac
    device="$(python3 -c 'import json,sys
v=json.load(open(sys.argv[1]))
for att in v.get("attachments") or []:
    if isinstance(att, dict) and att.get("device"):
        print(att.get("device"))
        break
' "$tmp" 2>/dev/null || true)"
    printf '%s\t%s\t%s\t%s\t%s\n' "$vid" "$status" "$servers" "$device" "$run"
    return 0
  done < <(ls -1td "$base"/* 2>/dev/null || true)
  return 1
}
flex_cleanup_existing_mig_volumes() {
  local name="$1" out="$JOB_TMP/flex_existing_${LABEL_SAFE}.tsv"
  : >"$out"
  openstack volume list --name "$name" -f json 2>>"$JOB_LOG/flex_cinder.log" | python3 - "$name" >"$out" <<'PY' 2>>"$JOB_LOG/flex_cinder.log" || true
import json, sys
name = sys.argv[1]
try:
    rows = json.load(sys.stdin)
except Exception:
    rows = []
for row in rows:
    row_name = row.get("Name") or row.get("name") or ""
    if row_name != name:
        continue
    vid = row.get("ID") or row.get("Id") or row.get("id") or ""
    status = row.get("Status") or row.get("status") or ""
    attachments = row.get("Attachments") or row.get("attachments") or ""
    if isinstance(attachments, list):
        servers = []
        for item in attachments:
            if isinstance(item, dict):
                servers.append(item.get("server_id") or item.get("serverId") or item.get("server") or "")
        attachments = ",".join(x for x in servers if x)
    print(f"{vid}\t{status}\t{attachments}")
PY
  [ -s "$out" ] || return 0
  while IFS=$'\t' read -r vid status attachments; do
    [ -n "$vid" ] || continue
    log "[VS4] START FRESH: removing existing FLEX volume name=$name id=$vid status=${status:-unknown}"
    if [ -n "${attachments:-}" ] || [ "${status:-}" = "in-use" ]; then
      local servers="$attachments"
      if [ -z "$servers" ]; then
        servers="$(openstack volume show "$vid" -f json 2>>"$JOB_LOG/flex_cinder.log" | python3 - <<'PY' 2>>"$JOB_LOG/flex_cinder.log" || true
import json, sys
try:
    v=json.load(sys.stdin)
except Exception:
    v={}
servers=[]
for item in (v.get("attachments") or []):
    if isinstance(item, dict):
        sid=item.get("server_id") or item.get("serverId") or item.get("server") or ""
        if sid:
            servers.append(sid)
print(",".join(servers))
PY
)"
      fi
      IFS=',' read -r -a server_arr <<<"$servers"
      for sid in "${server_arr[@]}"; do
        [ -n "$sid" ] || continue
        log "[VS4] START FRESH: detaching old FLEX volume $vid from $sid"
        openstack server remove volume "$sid" "$vid" >>"$JOB_LOG/flex_cinder.log" 2>&1 || true
      done
      flex_wait_volume "$vid" "available" 300 || true
    fi
    log "[VS4] START FRESH: deleting old FLEX volume $vid"
    openstack volume delete "$vid" >>"$JOB_LOG/flex_cinder.log" 2>&1 || true
    flex_wait_volume_deleted "$vid" 300 || true
  done <"$out"
}
flex_cleanup_helper_stale_mig_volumes() {
  [ -n "${FLEX_HELPER_VM_ID:-}" ] || return 0
  [ -n "${FLEX_TARGET_VM_ID:-}" ] || return 0
  [ "$FLEX_HELPER_VM_ID" != "$FLEX_TARGET_VM_ID" ] || return 0

  local out="$JOB_TMP/flex_helper_stale_${LABEL_SAFE}.tsv"
  : >"$out"
  openstack volume list -f value -c ID -c Name 2>>"$JOB_LOG/flex_cinder.log" \
    | awk '$2 ~ /^mig-/ {print $1 "\t" $2}' >"$out" || true
  [ -s "$out" ] || return 0

  while IFS=$'\t' read -r vid vname; do
    [ -n "$vid" ] || continue
    [ -n "${FLEX_VOL_ID:-}" ] && [ "$vid" = "$FLEX_VOL_ID" ] && continue
    local attached_to_helper=""
    attached_to_helper="$(openstack volume show "$vid" -f json 2>>"$JOB_LOG/flex_cinder.log" \
      | python3 -c 'import json,sys
helper=sys.argv[1]
try:
    vol=json.load(sys.stdin)
except Exception:
    vol={}
for att in vol.get("attachments") or []:
    if isinstance(att, dict) and (att.get("server_id") or att.get("serverId") or att.get("server") or "") == helper:
        print("yes")
        break
' "$FLEX_HELPER_VM_ID" 2>>"$JOB_LOG/flex_cinder.log" || true)"
    [ "$attached_to_helper" = "yes" ] || continue
    log "[VS5] START FRESH: removing stale helper FLEX volume name=$vname id=$vid from helper $FLEX_HELPER_VM_ID"
    openstack server remove volume "$FLEX_HELPER_VM_ID" "$vid" >>"$JOB_LOG/flex_cinder.log" 2>&1 || true
    flex_wait_volume "$vid" "available" 300 || true
    openstack volume delete "$vid" >>"$JOB_LOG/flex_cinder.log" 2>&1 || true
    flex_wait_volume_deleted "$vid" 300 || true
  done <"$out"
}
resume_finalize_and_exit() {
  stage "VS8_STREAM_BLOCK_DATA"
  log "[VS8] RESUME: previous run already copied ${STREAM_BYTES} bytes to FLEX volume $FLEX_VOL_ID; skipping block stream"

  FINAL_ATTACH_DEVICE=""
  FINAL_TARGET_VM_ID="${FLEX_TARGET_VM_ID:-$FLEX_HELPER_VM_ID}"
  if [ "$ATTACH_TO_FINAL" = "true" ] && [ -n "$FLEX_HELPER_VM_ID" ] && [ "$FLEX_HELPER_VM_ID" != "$FINAL_TARGET_VM_ID" ] && flex_volume_attached_to "$FLEX_VOL_ID" "$FLEX_HELPER_VM_ID"; then
    stage "VS10_DETACH_FLEX_FROM_HELPER"
    log "[VS10] RESUME: detaching $FLEX_VOL_ID from helper vm=$FLEX_HELPER_VM_ID"
    openstack server remove volume "$FLEX_HELPER_VM_ID" "$FLEX_VOL_ID" \
      2>>"$JOB_LOG/flex_cinder.log" || log "[VS10] WARN: remove volume returned non-zero (continuing)"
    flex_wait_volume "$FLEX_VOL_ID" "available" 300 || log "[VS10] WARN: FLEX volume did not return to available quickly"
    log "[VS10] FLEX volume detached from helper"
  fi

  if [ "$ATTACH_TO_FINAL" = "true" ] && [ -n "$FINAL_TARGET_VM_ID" ]; then
    stage "VS11_ATTACH_TO_FINAL_FLEX_VM"
    kv "Final FLEX VM" "$FINAL_TARGET_VM_ID"
    if flex_volume_attached_to "$FLEX_VOL_ID" "$FINAL_TARGET_VM_ID"; then
      log "[VS11] RESUME: FLEX volume $FLEX_VOL_ID is already attached to final VM $FINAL_TARGET_VM_ID"
    else
      flex_final_attach_volume_to_server_verified "$FINAL_TARGET_VM_ID" "$FLEX_VOL_ID" "VS11" || \
        fail_exit "Final attach to $FINAL_TARGET_VM_ID did not stick; volume status=$(flex_volume_status "$FLEX_VOL_ID")"
    fi
    FLEX_FINAL_ATTACHED=1
    FINAL_ATTACH_DEVICE="$(flex_volume_device "$FLEX_VOL_ID" || true)"
    [ -n "$FINAL_ATTACH_DEVICE" ] && log "[VS11] Final attachment device: $FINAL_ATTACH_DEVICE"
  else
    log "[VS11] RESUME: skipped final attach (attach_to_final=$ATTACH_TO_FINAL final_target='${FINAL_TARGET_VM_ID}')"
  fi

  if [ "$POST_ATTACH_VALIDATE_MOUNT" = "true" ] || [ "$POST_ATTACH_VALIDATE_PG" = "true" ]; then
    log "[VOL_POST_ATTACH_VALIDATE] RESUME: skipped early resume validation; rerun with normal path if validation is required"
  else
    log "[VOL_POST_ATTACH_VALIDATE] skipped (post_attach_validate_mount=false)"
  fi

  if [ "$SOURCE_MODE" = "flex" ]; then
    stage "VS12_CLEANUP_SOURCE_FLEX"
    log "[VS12] RESUME: no Source FLEX temp volume created; cleanup skipped"
  else
    stage "VS12_CLEANUP_OSPC"
    log "[VS12] RESUME: no OSPC temp volume created; cleanup skipped"
  fi
  CLEANUP_DONE=1

  log "══════════════════════════════════════════════════════"
  log "  VOLSNAP DIRECT CINDER COMPLETE"
  log "══════════════════════════════════════════════════════"
  log "  $([ "$SOURCE_MODE" = "flex" ] && echo "Source FLEX snapshot" || echo "OSPC snapshot")         : $SNAPSHOT_ID"
  log "  FLEX Cinder volume    : $FLEX_VOL_ID  ($FLEX_VOL_NAME, ${FLEX_VOL_SIZE_GB}GB)"
  [ -n "$FINAL_TARGET_VM_ID" ] && log "  Attached to FLEX VM   : $FINAL_TARGET_VM_ID"
  log "  Storage path          : Storage → Volumes (not Compute → Images)"
  exit 0
}
flex_server_first_ip() {
  openstack server show "$1" -f json 2>/dev/null | python3 -c '
import json, re, sys
try:
    data=json.load(sys.stdin)
except Exception:
    sys.exit(0)
addresses=data.get("addresses") or data.get("Addresses") or ""
if isinstance(addresses, dict):
    blob=" ".join(str(x) for vals in addresses.values() for x in (vals if isinstance(vals, list) else [vals]))
else:
    blob=str(addresses)
ips=re.findall(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", blob)
print(ips[-1] if ips else "")
' || true
}
validate_flex_helper_server() {
  [ -n "$FLEX_HELPER_VM_ID" ] || return 0
  local out="$JOB_LOG/flex_helper_preflight.log"
  : >"$out"
  (
    set +u
    unset OS_TOKEN OS_AUTH_TYPE OS_AUTH_URL OS_TENANT_ID OS_TENANT_NAME \
          OS_REGION_NAME OS_IDENTITY_API_VERSION OS_INTERFACE \
          OS_PROJECT_ID OS_PROJECT_NAME OS_USER_DOMAIN_NAME OS_PROJECT_DOMAIN_ID
    # shellcheck disable=SC1090
    source "$FLEX_OPENRC"
    openstack token issue >/dev/null 2>&1 || { echo "FLEX authentication failed"; exit 10; }
    if openstack server show "$FLEX_HELPER_VM_ID" -f value -c id >/dev/null 2>&1; then
      exit 0
    fi
    echo "No FLEX server found for: $FLEX_HELPER_VM_ID"
    if openstack image show "$FLEX_HELPER_VM_ID" -f value -c id >/dev/null 2>&1; then
      echo "That UUID exists as an image, not a server. Use the instance/server ID from the VM details."
    fi
    if [ -n "$FLEX_HELPER_IP" ]; then
      echo "Servers matching helper IP $FLEX_HELPER_IP:"
      openstack server list --long -f value -c ID -c Name -c Networks 2>/dev/null | grep -F "$FLEX_HELPER_IP" | head -5 || true
    fi
    exit 11
  ) >"$out" 2>&1
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && log "[FLEX-PREFLIGHT] $line"
    done <"$out"
    fail_exit "Invalid FLEX helper VM ID '$FLEX_HELPER_VM_ID' — use the FLEX instance/server ID, not the Image Info ID"
  fi
}

local_block_disks() {
  sudo lsblk -dnpo NAME,TYPE 2>/dev/null | awk '$2=="disk" && $1 !~ /^\/dev\/(nbd|loop|sr|fd)/ {print $1}' | sort
}
flex_remote_block_disks() {
  ssh_flex "lsblk -dnpo NAME,TYPE 2>/dev/null | awk '\$2==\"disk\" && \$1 !~ /^\\/dev\\/(nbd|loop|sr|fd)/ {print \$1}' | sort" 2>>"$JOB_LOG/flex_ssh.log" || true
}
select_flex_helper_ssh_user() {
  [ -n "$FLEX_HELPER_IP" ] || return 0
  local original_user="$FLEX_HELPER_USER" candidates=() seen=" " user
  for user in "$original_user" root debian ubuntu cloud-user centos almalinux rocky ec2-user; do
    [ -n "$user" ] || continue
    case "$seen" in *" $user "*) continue ;; esac
    seen="${seen}${user} "
    candidates+=("$user")
  done
  for user in "${candidates[@]}"; do
    FLEX_HELPER_USER="$user"
    set_ssh_flex_base
    if ssh_flex "command -v lsblk >/dev/null && lsblk -dnpo NAME,TYPE >/dev/null" >>"$JOB_LOG/flex_ssh.log" 2>&1; then
      if [ "$user" != "$original_user" ]; then
        log "[FLEX-SSH] Row SSH user '$original_user' failed; using '$user' for FLEX helper/target SSH"
      else
        log "[FLEX-SSH] SSH user '$user' verified for FLEX helper/target"
      fi
      return 0
    fi
  done
  FLEX_HELPER_USER="$original_user"
  set_ssh_flex_base
  fail_exit "Cannot SSH to FLEX helper/target ${FLEX_HELPER_IP} with key ${SSH_KEY_PATH}; tried users: ${candidates[*]}"
}
select_post_attach_ssh_user() {
  local target_ip="$1"
  [ -n "$target_ip" ] || return 0
  local original_user="$POST_ATTACH_SSH_USER" candidates=() seen=" " user
  for user in "$POST_ATTACH_SSH_USER" "$FLEX_HELPER_USER" root debian ubuntu cloud-user centos almalinux rocky ec2-user; do
    [ -n "$user" ] || continue
    case "$seen" in *" $user "*) continue ;; esac
    seen="${seen}${user} "
    candidates+=("$user")
  done
  for user in "${candidates[@]}"; do
    if ssh -i "$POST_ATTACH_SSH_KEY_PATH" \
      -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
      -o BatchMode=yes -o ConnectTimeout=12 \
      "${user}@${target_ip}" "command -v sh >/dev/null" >>"$VALIDATE_LOG" 2>&1; then
      POST_ATTACH_SSH_USER="$user"
      if [ "$user" != "$original_user" ]; then
        log "[VOL_POST_ATTACH_VALIDATE] Row SSH user '$original_user' failed; using '$user' for target validation SSH"
      else
        log "[VOL_POST_ATTACH_VALIDATE] SSH user '$user' verified for target validation"
      fi
      return 0
    fi
  done
  fail_exit "Cannot SSH to post-attach target ${target_ip} with key ${POST_ATTACH_SSH_KEY_PATH}; tried users: ${candidates[*]}"
}
flex_remote_device_is_safe() {
  local dev="$1"
  case "$dev" in /dev/*) ;; *) return 1 ;; esac
  printf '%s' "$dev" | grep -Eq '^/dev/[A-Za-z0-9._/-]+$' || return 1
  ssh_flex "set -e
dev='$dev'
[ -b \"\$dev\" ] || { echo \"missing block device: \$dev\" >&2; exit 20; }
[ \"\$(lsblk -dnro TYPE \"\$dev\")\" = disk ] || { echo \"not a disk: \$dev\" >&2; exit 21; }
root_src=\$(findmnt -n -o SOURCE /)
root_mm=\$(findmnt -n -o MAJ:MIN /)
dev_mm=\$(lsblk -dnro MAJ:MIN \"\$dev\")
root_pk=\$(lsblk -npo PKNAME \"\$root_src\" 2>/dev/null | head -1)
[ \"\$dev\" != \"\$root_src\" ] || { echo \"device is root source: \$dev\" >&2; exit 22; }
[ \"\$dev_mm\" != \"\$root_mm\" ] || { echo \"device has root maj:min: \$dev\" >&2; exit 23; }
[ -z \"\$root_pk\" ] || [ \"\$dev\" != \"\$root_pk\" ] || { echo \"device is root parent: \$dev\" >&2; exit 24; }
if lsblk -nrpo NAME,MOUNTPOINT \"\$dev\" | awk 'NF>=2 && \$2 != \"\" {found=1} END{exit found?0:1}'; then
  echo \"device has mounted filesystem: \$dev\" >&2
  exit 25
fi" 2>>"$JOB_LOG/flex_ssh.log"
}
flex_find_new_safe_disk() {
  local before="$1" before_b64
  before_b64="$(printf '%s' "$before" | base64 | tr -d '\n')"
  ssh_flex "set -e
before=\$(printf '%s' '$before_b64' | base64 -d 2>/dev/null || true)
for dev in \$(lsblk -dnpo NAME,TYPE 2>/dev/null | awk '\$2==\"disk\" && \$1 !~ /^\\/dev\\/(nbd|loop|sr|fd)/ {print \$1}' | sort); do
  case \" \$before \" in *\" \$dev \"*) continue ;; esac
  [ -b \"\$dev\" ] || continue
  [ \"\$(lsblk -dnro TYPE \"\$dev\")\" = disk ] || continue
  root_src=\$(findmnt -n -o SOURCE /)
  root_mm=\$(findmnt -n -o MAJ:MIN /)
  dev_mm=\$(lsblk -dnro MAJ:MIN \"\$dev\")
  root_pk=\$(lsblk -npo PKNAME \"\$root_src\" 2>/dev/null | head -1)
  [ \"\$dev\" != \"\$root_src\" ] || continue
  [ \"\$dev_mm\" != \"\$root_mm\" ] || continue
  [ -z \"\$root_pk\" ] || [ \"\$dev\" != \"\$root_pk\" ] || continue
  if lsblk -nrpo NAME,MOUNTPOINT \"\$dev\" | awk 'NF>=2 && \$2 != \"\" {found=1} END{exit found?0:1}'; then
    continue
  fi
  echo \"\$dev\"
  exit 0
done
exit 1" 2>>"$JOB_LOG/flex_ssh.log" || true
}
region_short() {
  local r="${OS_REGION_NAME:-IAD}"
  r="$(printf '%s' "$r" | tr '[:upper:]' '[:lower:]' | tr -d '0-9')"
  [ -n "$r" ] || r="iad"
  printf '%s' "$r"
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

# ── VS0: Load + validate source credentials ───────────────────────────────────
stage "VS0_LOAD_CREDENTIALS"
source_openrc
OSPC_TENANT="${OS_TENANT_ID:-${OS_PROJECT_ID:-}}"
OSPC_API_REGION="$(region_short)"
if [ "$SOURCE_MODE" = "flex" ]; then
  openstack token issue >/dev/null 2>&1 || fail_exit "Source FLEX authentication failed — check $OSPC_OPENRC"
  [ -n "$OSPC_TENANT" ] || OSPC_TENANT="${OS_PROJECT_NAME:-}"
  kv "Source mode"   "flex"
  kv "Source project" "${OSPC_TENANT:-unknown}"
  kv "Source region" "$OSPC_API_REGION"
else
  OSPC_TOKEN="${OS_TOKEN:-}"
  [ -n "$OSPC_TOKEN" ]  || fail_exit "OS_TOKEN not set in $OSPC_OPENRC"
  [ -n "$OSPC_TENANT" ] || fail_exit "OS_TENANT_ID not set in $OSPC_OPENRC"
  OSPC_BS_BASE="https://${OSPC_API_REGION}.blockstorage.api.rackspacecloud.com/v1/$OSPC_TENANT"
  OSPC_COMPUTE_BASE="https://${OSPC_API_REGION}.servers.api.rackspacecloud.com/v2/$OSPC_TENANT"
  kv "Source mode"   "ospc"
  kv "OSPC tenant"   "$OSPC_TENANT"
  kv "OSPC region"   "$OSPC_API_REGION"
fi
kv "Snapshot ID"   "$SNAPSHOT_ID"
kv "Label"         "$LABEL_SAFE"
validate_flex_helper_server
select_flex_helper_ssh_user
kv "FLEX helper"   "${FLEX_HELPER_USER}@${FLEX_HELPER_IP} (vm=${FLEX_HELPER_VM_ID:-none})"

# ── VS1: Create temp source Cinder volume from snapshot ───────────────────────
if [ "$SOURCE_MODE" = "flex" ]; then
  stage "VS1_CREATE_TEMP_SOURCE_FLEX_VOLUME"
else
  stage "VS1_CREATE_TEMP_OSPC_VOLUME"
fi

# Auto-detect snapshot size if not overridden
if [ "$SNAP_SIZE_GB" -le 0 ] 2>/dev/null; then
  if [ "$SOURCE_MODE" = "flex" ]; then
    source_openrc
    SNAP_SIZE_GB="$(openstack volume snapshot show "$SNAPSHOT_ID" -f value -c size 2>/dev/null || echo 75)"
    [ -n "$SNAP_SIZE_GB" ] || SNAP_SIZE_GB=75
  else
    SNAP_SIZE_GB="$(_cinder_get "snapshots/$SNAPSHOT_ID" | python3 -c \
      'import json,sys; print(json.load(sys.stdin)["snapshot"]["size"])' 2>/dev/null || echo 75)"
  fi
  log "[VS1] Auto-detected snapshot size: ${SNAP_SIZE_GB}GB"
fi
[ "$SNAP_SIZE_GB" -gt 0 ] 2>/dev/null || fail_exit "Could not determine snapshot size"
SNAP_SIZE_ORIG_GB="$SNAP_SIZE_GB"
# OSPC Cinder requires minimum 75 GB per volume; use 80 GB default floor for headroom.
# Flex source Cinder does not need this old OSPC floor.
if [ "$SOURCE_MODE" != "flex" ] && [ "$SNAP_SIZE_GB" -lt 80 ] 2>/dev/null; then
  log "[VS1] Snapshot size ${SNAP_SIZE_GB}GB below minimum — using 80GB for OSPC temp vol (FLEX vol stays ${SNAP_SIZE_ORIG_GB}GB)"
  SNAP_SIZE_GB=80
fi

if [ "$SOURCE_MODE" = "flex" ]; then
  source_openrc
  SNAP_STATUS="$(openstack volume snapshot show "$SNAPSHOT_ID" -f value -c status 2>/dev/null || echo unknown)"
else
  SNAP_STATUS="$(_cinder_get "snapshots/$SNAPSHOT_ID" | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["snapshot"]["status"])' 2>/dev/null || echo unknown)"
fi
[ "$SNAP_STATUS" = "available" ] || fail_exit "Snapshot $SNAPSHOT_ID not available (status=$SNAP_STATUS)"
kv "Snapshot status" "$SNAP_STATUS"
kv "Snapshot size"   "${SNAP_SIZE_GB}GB"
STREAM_BYTES=$(( SNAP_SIZE_ORIG_GB * 1073741824 ))

# Try resume before creating any OSPC temp volume. If a previous run already
# copied the full byte stream to FLEX, continue with final attach only.
unset OS_TOKEN OS_AUTH_TYPE OS_AUTH_URL OS_TENANT_ID OS_TENANT_NAME \
      OS_REGION_NAME OS_IDENTITY_API_VERSION OS_INTERFACE \
      OS_PROJECT_ID OS_PROJECT_NAME OS_USER_DOMAIN_NAME OS_PROJECT_DOMAIN_ID
# shellcheck disable=SC1090
source "$FLEX_OPENRC"
openstack token issue >/dev/null 2>&1 || fail_exit "FLEX authentication failed — check $FLEX_OPENRC"
FLEX_VOL_SIZE_GB=$(( SNAP_SIZE_ORIG_GB + 1 ))
FLEX_VOL_NAME="${FLEX_VOLUME_NAME_OVERRIDE:-mig-${LABEL_SAFE}-flex}"
RESUME_INFO="$(flex_find_resume_volume "$FLEX_VOL_NAME" "$STREAM_BYTES" || true)"
if [ -n "$RESUME_INFO" ]; then
  stage "VS4_RESUME_FLEX_CINDER_VOLUME"
  IFS=$'\t' read -r FLEX_VOL_ID RESUME_SOURCE_STATUS RESUME_SERVERS RESUME_DEVICE RESUME_SOURCE_RUN <<<"$RESUME_INFO"
  RESUME_STREAM_DONE=1
  log "[VS4] RESUME: reusing completed FLEX volume $FLEX_VOL_ID from $RESUME_SOURCE_RUN status=${RESUME_SOURCE_STATUS:-unknown}"
  resume_finalize_and_exit
fi
source_openrc

OSPC_VOL_NAME="tmp-osflex-${LABEL_SAFE}-${RUN_ID}"
if [ "$SOURCE_MODE" = "flex" ]; then
  OSPC_VOL_ID="$(openstack volume create \
    --snapshot "$SNAPSHOT_ID" \
    --size "$SNAP_SIZE_GB" \
    --format value -c id \
    "$OSPC_VOL_NAME" 2>>"$JOB_LOG/source_flex_cinder.log" || true)"
  [ -n "$OSPC_VOL_ID" ] || fail_exit "Source FLEX volume create failed — check $JOB_LOG/source_flex_cinder.log"
else
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
fi
kv "$([ "$SOURCE_MODE" = "flex" ] && echo "Source FLEX temp vol" || echo "OSPC temp vol")" "$OSPC_VOL_ID"
log "[VS1] Waiting for temp volume to become available…"
source_wait_volume "$OSPC_VOL_ID" "available" 3600 || fail_exit "Temp volume $OSPC_VOL_ID never became available"
log "[VS1] HIT temp volume available"

# ── VS2: Attach temp source volume to this jumphost ───────────────────────────
if [ "$SOURCE_MODE" = "flex" ]; then
  stage "VS2_ATTACH_SOURCE_FLEX_VOLUME"
else
  stage "VS2_ATTACH_OSPC_VOLUME"
fi
SELF_SERVER_ID="$(discover_self_server_id | head -1 | tr -d '[:space:]')"
[ -n "$SELF_SERVER_ID" ] || fail_exit "Could not determine jumphost Nova server ID"
kv "Jumphost server" "$SELF_SERVER_ID"

if [ "$SOURCE_MODE" = "flex" ]; then
  source_openrc
  openstack server add volume "$SELF_SERVER_ID" "$OSPC_VOL_ID" \
    >>"$JOB_LOG/source_flex_cinder.log" 2>&1 || fail_exit "Source FLEX server add volume failed"
else
  ATTACH_PAYLOAD="$(VOL_ID="$OSPC_VOL_ID" python3 - <<'PY'
import json, os; print(json.dumps({"volumeAttachment":{"volumeId":os.environ["VOL_ID"]}},separators=(",",":")))
PY
)"
  ATTACH_RESP="$(_compute_post "servers/$SELF_SERVER_ID/os-volume_attachments" "$ATTACH_PAYLOAD")"
  ATTACH_HTTP="$(printf '%s' "$ATTACH_RESP" | awk -F= '/HTTP_CODE=/{print $2}' | tail -1)"
  case "$ATTACH_HTTP" in 200|202) ;; *) fail_exit "Volume attach HTTP=$ATTACH_HTTP" ;; esac
fi
log "[VS2] Attach request OK — waiting in-use"
source_wait_volume "$OSPC_VOL_ID" "in-use" 300 || fail_exit "Temp volume did not reach in-use"

# Detect source device from Cinder attachment record (avoids parallel-job race)
if [ -n "$SOURCE_DEVICE_OVERRIDE" ]; then
  SOURCE_DEV="$SOURCE_DEVICE_OVERRIDE"
  log "[VS2] Source device overridden: $SOURCE_DEV"
else
  SOURCE_DEV=""
  for _i in $(seq 1 24); do
    sleep 5
    SOURCE_DEV="$(source_volume_device "$OSPC_VOL_ID")"
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
SOURCE_GB_CEIL=$(( (SOURCE_BYTES + 1073741823) / 1073741824 ))
kv "Source bytes" "$SOURCE_BYTES"
kv "Source GB"    "$SOURCE_GB_CEIL"

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

# FLEX encrypted Cinder can expose a guest block device slightly smaller than
# the requested size because of provider-side encryption/header reservation.
# Use +1GiB headroom, but never request a target smaller than the attached
# source device. OSPC snapshots below the source cloud minimum can materialize
# as an 80GiB temp volume even when the snapshot metadata says 75GiB.
FLEX_VOL_SIZE_GB=$(( SNAP_SIZE_ORIG_GB + 1 ))
if [ "$FLEX_VOL_SIZE_GB" -lt "$SOURCE_GB_CEIL" ] 2>/dev/null; then
  log "[VS4] FLEX requested size ${FLEX_VOL_SIZE_GB}GB is below measured source device ${SOURCE_GB_CEIL}GB; using ${SOURCE_GB_CEIL}GB"
  FLEX_VOL_SIZE_GB="$SOURCE_GB_CEIL"
fi
FLEX_VOL_NAME="${FLEX_VOLUME_NAME_OVERRIDE:-mig-${LABEL_SAFE}-flex}"
kv "FLEX volume name" "$FLEX_VOL_NAME"
kv "FLEX volume size" "${FLEX_VOL_SIZE_GB}GB"
log "[VS4] FLEX volume is sized with headroom and measured source-device floor"
RESUME_INFO="$(flex_find_resume_volume "$FLEX_VOL_NAME" "$STREAM_BYTES" || true)"
if [ -n "$RESUME_INFO" ]; then
  IFS=$'\t' read -r FLEX_VOL_ID RESUME_SOURCE_STATUS RESUME_SERVERS RESUME_DEVICE RESUME_SOURCE_RUN <<<"$RESUME_INFO"
  RESUME_STREAM_DONE=1
  log "[VS4] RESUME: reusing completed FLEX volume $FLEX_VOL_ID from $RESUME_SOURCE_RUN status=${RESUME_SOURCE_STATUS:-unknown}"
  if [ -n "${FLEX_TARGET_VM_ID:-}" ]; then
    case ",$RESUME_SERVERS," in
      *",$FLEX_TARGET_VM_ID,"*)
        RESUME_FINAL_ATTACHED=1
        FLEX_FINAL_ATTACHED=1
        log "[VS4] RESUME: volume is already attached to final FLEX VM $FLEX_TARGET_VM_ID"
        ;;
    esac
  fi
else
  flex_cleanup_existing_mig_volumes "$FLEX_VOL_NAME"

  FLEX_VOL_ID="$(openstack volume create \
    --size "$FLEX_VOL_SIZE_GB" \
    --format value -c id \
    "$FLEX_VOL_NAME" 2>>"$JOB_LOG/flex_cinder.log" || true)"
  if [ -z "$FLEX_VOL_ID" ]; then
    flex_create_tail="$(tail -c 1200 "$JOB_LOG/flex_cinder.log" 2>/dev/null | tr '\n' ' ' || true)"
    log "ICF Issue=FLEX Cinder target volume create failed"
    log "ICF Cause=openstack volume create returned no target volume id for ${FLEX_VOL_SIZE_GB}GB in the target FLEX region"
    log "ICF Fix=verify target FLEX Cinder quota/volume type/minimum size in the selected region, then retry START FRESH"
    [ -n "$flex_create_tail" ] && log "[VS4] flex_cinder.log tail: $flex_create_tail"
    fail_exit "openstack volume create failed — check $JOB_LOG/flex_cinder.log"
  fi
  kv "FLEX volume ID" "$FLEX_VOL_ID"
  log "[VS4] Waiting for FLEX volume to become available…"
  flex_wait_volume "$FLEX_VOL_ID" "available" 3600 || fail_exit "FLEX volume $FLEX_VOL_ID never became available"
  log "[VS4] HIT FLEX volume available"
fi

# ── VS5: Attach blank FLEX volume to FLEX helper VM ───────────────────────────
if [ "$RESUME_FINAL_ATTACHED" != "1" ]; then
stage "VS5_ATTACH_FLEX_VOLUME_TO_HELPER"
FLEX_PRE_ATTACH_DISKS=""
if [ -n "$FLEX_HELPER_VM_ID" ]; then
  flex_cleanup_helper_stale_mig_volumes
  FLEX_PRE_ATTACH_DISKS="$(flex_remote_block_disks | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  if [ -n "$FLEX_PRE_ATTACH_DISKS" ]; then
    log "[VS5] FLEX helper disks before attach: $FLEX_PRE_ATTACH_DISKS"
  else
    log "[VS5] FLEX helper pre-attach disk scan empty; will still use Cinder-reported device"
  fi
  if [ "$RESUME_STREAM_DONE" = "1" ] && flex_volume_attached_to "$FLEX_VOL_ID" "$FLEX_HELPER_VM_ID"; then
    log "[VS5] RESUME: completed FLEX volume $FLEX_VOL_ID already attached to helper vm=$FLEX_HELPER_VM_ID"
  else
    log "[VS5] Attaching $FLEX_VOL_ID to FLEX helper vm=$FLEX_HELPER_VM_ID"
    openstack server add volume "$FLEX_HELPER_VM_ID" "$FLEX_VOL_ID" \
      2>>"$JOB_LOG/flex_cinder.log" || fail_exit "openstack server add volume failed"
    log "[VS5] Waiting for FLEX volume in-use…"
    flex_wait_volume "$FLEX_VOL_ID" "in-use" 300 || fail_exit "FLEX volume did not reach in-use"
    log "[VS5] FLEX volume in-use"
  fi
else
  log "[VS5] No FLEX helper VM ID provided — skipping API attach (assuming volume pre-attached or TARGET_DEVICE_OVERRIDE set)"
fi

# ── VS6: Detect target device on FLEX helper ──────────────────────────────────
stage "VS6_DETECT_FLEX_TARGET_DEVICE"
if [ -n "$TARGET_DEVICE_OVERRIDE" ]; then
  FLEX_TARGET_DEV="$TARGET_DEVICE_OVERRIDE"
  log "[VS6] Target device overridden: $FLEX_TARGET_DEV"
elif [ -n "$FLEX_HELPER_VM_ID" ]; then
  # Full path: poll Cinder API for the exact attachment device.
  FLEX_TARGET_DEV=""
  for _i in $(seq 1 24); do
    sleep 5
    FLEX_TARGET_DEV="$(flex_volume_device "$FLEX_VOL_ID" || true)"
    [ -n "$FLEX_TARGET_DEV" ] && break
    FLEX_TARGET_DEV=""
  done
  [ -n "$FLEX_TARGET_DEV" ] || fail_exit "Cinder did not report target device for FLEX volume $FLEX_VOL_ID — pass --target-device explicitly"
else
  fail_exit "No FLEX helper VM ID was provided — set --target-device explicitly if the FLEX volume is already attached"
fi
kv "FLEX target device" "$FLEX_TARGET_DEV"

# Safety: never allow target to be mounted or be the root device
case "$FLEX_TARGET_DEV" in /dev/*) ;; *) fail_exit "FLEX target device must be a /dev path: $FLEX_TARGET_DEV" ;; esac
printf '%s' "$FLEX_TARGET_DEV" | grep -Eq '^/dev/[A-Za-z0-9._/-]+$' || fail_exit "Unsafe FLEX target device path: $FLEX_TARGET_DEV"
FLEX_TARGET_DEV_REPORTED="$FLEX_TARGET_DEV"
FLEX_TARGET_DEV_READY=""
for _i in $(seq 1 24); do
  if flex_remote_device_is_safe "$FLEX_TARGET_DEV_REPORTED"; then
    FLEX_TARGET_DEV="$FLEX_TARGET_DEV_REPORTED"
    FLEX_TARGET_DEV_READY="true"
    break
  fi
  FLEX_TARGET_DEV_FALLBACK="$(flex_find_new_safe_disk "$FLEX_PRE_ATTACH_DISKS")"
  if [ -n "$FLEX_TARGET_DEV_FALLBACK" ] && flex_remote_device_is_safe "$FLEX_TARGET_DEV_FALLBACK"; then
    if [ "$FLEX_TARGET_DEV_FALLBACK" != "$FLEX_TARGET_DEV_REPORTED" ]; then
      log "[VS6] Remapped Cinder device to guest device: $FLEX_TARGET_DEV_REPORTED -> $FLEX_TARGET_DEV_FALLBACK"
    fi
    FLEX_TARGET_DEV="$FLEX_TARGET_DEV_FALLBACK"
    FLEX_TARGET_DEV_READY="true"
    break
  fi
  [ $((_i % 6)) -eq 0 ] && log "[VS6] Waiting for new safe FLEX guest disk (${_i}/24)"
  sleep 5
done
[ "$FLEX_TARGET_DEV_READY" = "true" ] || {
  log "[VS6] Current FLEX helper disks: $(flex_remote_block_disks | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  fail_exit "FLEX target device $FLEX_TARGET_DEV_REPORTED is root, mounted, missing, or unsafe — aborting to prevent data loss"
}
kv "FLEX target device" "$FLEX_TARGET_DEV"

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
# Compare FLEX target against original snapshot size (not padded OSPC vol which may be 80GB).
# The target must be large enough for the exact byte stream; otherwise dd fails
# at the end and leaves a partial destination volume.
kv "Stream bytes (orig ${SNAP_SIZE_ORIG_GB}GB)" "$STREAM_BYTES"
[ "${TARGET_BYTES}" -ge "${STREAM_BYTES}" ] || \
  fail_exit "FLEX target too small for exact stream: ${TARGET_BYTES}B < ${STREAM_BYTES}B (original snapshot ${SNAP_SIZE_ORIG_GB}GB; recreate FLEX volume with +1GB headroom)"
log "[VS7] Size validation passed (target=${TARGET_BYTES}B stream=${STREAM_BYTES}B)"

# ── VS8: Direct block stream ──────────────────────────────────────────────────
stage "VS8_STREAM_BLOCK_DATA"
if [ "$RESUME_STREAM_DONE" = "1" ]; then
  log "[VS8] RESUME: previous run already copied ${STREAM_BYTES} bytes to FLEX volume $FLEX_VOL_ID; skipping block stream"
else
  log "[VS8] Streaming $SOURCE_DEV → ${FLEX_HELPER_USER}@${FLEX_HELPER_IP}:${FLEX_TARGET_DEV}"
  log "[VS8] Pipeline: dd | gzip -1 | ssh | gunzip | dd"

  _DD_COUNT=$(( SNAP_SIZE_ORIG_GB * 16 ))  # 64M * 16 = 1 GiB → count = orig GB * 16
  log "[VS8] Streaming ${SNAP_SIZE_ORIG_GB}GB (${_DD_COUNT} blocks of 64M)"
  STREAM_TOTAL_MB="$(mb_from_bytes "$STREAM_BYTES")"
  STREAM_START_TS="$(date +%s)"
  log_download_status "volsnap_stream" "0" "$STREAM_TOTAL_MB" "starting" "0.0" "unknown"
  set +e
  (
    set -o pipefail
    sudo dd if="$SOURCE_DEV" bs=64M count="$_DD_COUNT" status=progress conv=sync,noerror 2>>"$JOB_LOG/stream_src.log" \
      | gzip -1 \
      | "${SSH_FLEX_BASE[@]}" "gunzip | sudo dd of='$FLEX_TARGET_DEV' bs=64M status=progress conv=fsync 2>>/tmp/volsnap_stream_dst_${LABEL_SAFE}.log" \
      2>&1 | tee -a "$JOB_LOG/stream.log"
  ) &
  STREAM_PID=$!
  while kill -0 "$STREAM_PID" 2>/dev/null; do
    sleep 60
    if kill -0 "$STREAM_PID" 2>/dev/null; then
      STREAM_DONE_BYTES="$(python3 - "$JOB_LOG/stream_src.log" <<'PY' 2>/dev/null || true
import re, sys
path = sys.argv[1]
try:
    data = open(path, "rb").read().decode("utf-8", "ignore")
except Exception:
    data = ""
matches = re.findall(r"(\d+)\s+bytes", data)
print(matches[-1] if matches else "")
PY
)"
      if [ -n "$STREAM_DONE_BYTES" ]; then
        STREAM_DONE_MB="$(mb_from_bytes "$STREAM_DONE_BYTES")"
        STREAM_PCT="$(awk -v c="$STREAM_DONE_BYTES" -v t="$STREAM_BYTES" 'BEGIN{if(t>0) printf "%.1f", (c/t)*100; else printf "0.0"}')"
        STREAM_ELAPSED_S=$(( $(date +%s) - STREAM_START_TS ))
        STREAM_ETA_MIN="$(awk -v c="$STREAM_DONE_BYTES" -v t="$STREAM_BYTES" -v e="$STREAM_ELAPSED_S" 'BEGIN{if(c>0 && e>0 && t>c) printf "%.0f", ((t-c)/(c/e))/60; else if(t>0 && c>=t) printf "0"; else printf "unknown"}')"
        log "[VS8] Streaming progress: ${STREAM_DONE_BYTES}/${STREAM_BYTES} bytes"
        log_download_status "volsnap_stream" "$STREAM_DONE_MB" "$STREAM_TOTAL_MB" "streaming" "$STREAM_PCT" "$STREAM_ETA_MIN"
      else
        log "[VS8] Streaming progress: active"
        log_download_status "volsnap_stream" "0" "$STREAM_TOTAL_MB" "active" "0.0" "unknown"
      fi
    fi
  done
  wait "$STREAM_PID"
  STREAM_RC=$?
  set -e
  [ "$STREAM_RC" -eq 0 ] || fail_exit "Block stream failed rc=$STREAM_RC — check $JOB_LOG/stream.log"
  log_download_status "volsnap_stream" "$STREAM_TOTAL_MB" "$STREAM_TOTAL_MB" "complete" "100.0" "0"
  log "[VS8] HIT block stream complete"
fi

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
fi

# ── VS11: Attach FLEX volume to paired migrated FLEX VM ───────────────────────
FINAL_ATTACH_DEVICE=""
FINAL_TARGET_VM_ID="${FLEX_TARGET_VM_ID:-$FLEX_HELPER_VM_ID}"
if [ "$RESUME_FINAL_ATTACHED" = "1" ]; then
  stage "VS11_ATTACH_TO_FINAL_FLEX_VM"
  kv "Final FLEX VM" "$FLEX_TARGET_VM_ID"
  flex_volume_attached_to "$FLEX_VOL_ID" "$FLEX_TARGET_VM_ID" || \
    fail_exit "Resume expected FLEX volume $FLEX_VOL_ID attached to final VM $FLEX_TARGET_VM_ID, but attachment is missing"
  log "[VS11] RESUME: FLEX volume $FLEX_VOL_ID is already attached to final VM $FLEX_TARGET_VM_ID"
  FINAL_ATTACH_DEVICE="$(flex_volume_device "$FLEX_VOL_ID" || true)"
  [ -n "$FINAL_ATTACH_DEVICE" ] && log "[VS11] Final attachment device: $FINAL_ATTACH_DEVICE"
elif [ "$ATTACH_TO_FINAL" = "true" ] && [ -n "$FLEX_TARGET_VM_ID" ]; then
  stage "VS11_ATTACH_TO_FINAL_FLEX_VM"
  kv "Final FLEX VM" "$FLEX_TARGET_VM_ID"
  flex_final_attach_volume_to_server_verified "$FLEX_TARGET_VM_ID" "$FLEX_VOL_ID" "VS11" || \
    fail_exit "Final attach to $FLEX_TARGET_VM_ID did not stick; volume status=$(flex_volume_status "$FLEX_VOL_ID")"
  FLEX_FINAL_ATTACHED=1
  FINAL_ATTACH_DEVICE="$(flex_volume_device "$FLEX_VOL_ID" || true)"
  [ -n "$FINAL_ATTACH_DEVICE" ] && log "[VS11] Final attachment device: $FINAL_ATTACH_DEVICE"
elif [ "$ATTACH_TO_FINAL" = "true" ] && [ -n "$FLEX_HELPER_VM_ID" ]; then
  stage "VS11_ATTACH_TO_FINAL_FLEX_VM"
  kv "Final FLEX VM" "$FLEX_HELPER_VM_ID (helper reused as final target)"
  flex_final_attach_volume_to_server_verified "$FLEX_HELPER_VM_ID" "$FLEX_VOL_ID" "VS11" || \
    fail_exit "Final attach to helper/final target $FLEX_HELPER_VM_ID did not stick; volume status=$(flex_volume_status "$FLEX_VOL_ID")"
  FLEX_FINAL_ATTACHED=1
  FINAL_ATTACH_DEVICE="$(flex_volume_device "$FLEX_VOL_ID" || true)"
  [ -n "$FINAL_ATTACH_DEVICE" ] && log "[VS11] Final attachment device: $FINAL_ATTACH_DEVICE"
else
  log "[VS11] Skipped final attach (attach_to_final=$ATTACH_TO_FINAL flex_target_vm_id='${FLEX_TARGET_VM_ID}')"
fi

# ── VOL_POST_ATTACH_VALIDATE: mount migrated volume + optional PostgreSQL query ──
if [ "$POST_ATTACH_VALIDATE_MOUNT" = "true" ] || [ "$POST_ATTACH_VALIDATE_PG" = "true" ]; then
  stage "VOL_POST_ATTACH_VALIDATE"
  [ -n "$FINAL_TARGET_VM_ID" ] || fail_exit "Post-attach validation requested but no final FLEX target VM is known"
  [ "$ATTACH_TO_FINAL" = "true" ] || fail_exit "Post-attach validation requires attach_to_final=true"
  if [ ! -f "$POST_ATTACH_SCRIPT_PATH" ]; then
    fail_exit "Post-attach script not found on jumphost: $POST_ATTACH_SCRIPT_PATH"
  fi

  TARGET_SSH_IP="$POST_ATTACH_SSH_IP"
  if [ -z "$TARGET_SSH_IP" ]; then
    TARGET_SSH_IP="$(flex_server_first_ip "$FINAL_TARGET_VM_ID" | tail -1 | tr -d '[:space:]')"
  fi
  if [ -z "$TARGET_SSH_IP" ]; then
    TARGET_SSH_IP="$FLEX_HELPER_IP"
    log "[VOL_POST_ATTACH_VALIDATE] WARN: could not resolve final VM IP from OpenStack; using FLEX helper IP $TARGET_SSH_IP"
  fi
  [ -n "$TARGET_SSH_IP" ] || fail_exit "Could not determine target VM SSH IP for post-attach validation"

  if [ -z "$POST_ATTACH_DEVICE_HINT" ]; then
    POST_ATTACH_DEVICE_HINT="$FINAL_ATTACH_DEVICE"
  fi

  VALIDATE_LOG="$JOB_ART/post_attach_validate_${FLEX_VOL_ID}.log"
  VALIDATE_JSON="$JOB_ART/post_attach_validate_${FLEX_VOL_ID}.json"
  REMOTE_VALIDATE_SCRIPT="/tmp/osflex_post_attach_pg_mount_validate.sh"
  : >"$VALIDATE_LOG"
  select_post_attach_ssh_user "$TARGET_SSH_IP"
  log "[VOL_POST_ATTACH_VALIDATE] Target SSH: ${POST_ATTACH_SSH_USER}@${TARGET_SSH_IP}"
  log "[VOL_POST_ATTACH_VALIDATE] Device hint: ${POST_ATTACH_DEVICE_HINT:-auto}"
  log "[VOL_POST_ATTACH_VALIDATE] Mount override: ${POST_ATTACH_MOUNT_POINT:-auto}"
  log "[VOL_POST_ATTACH_VALIDATE] DB validator: ${POST_ATTACH_DB_VALIDATOR}"

  scp -i "$POST_ATTACH_SSH_KEY_PATH" \
    -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes -o ConnectTimeout=30 \
    "$POST_ATTACH_SCRIPT_PATH" "${POST_ATTACH_SSH_USER}@${TARGET_SSH_IP}:${REMOTE_VALIDATE_SCRIPT}" \
    >>"$VALIDATE_LOG" 2>&1 || fail_exit "Failed to upload post-attach validation script"

  set +e
  ssh -i "$POST_ATTACH_SSH_KEY_PATH" \
    -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes -o ConnectTimeout=30 \
    "${POST_ATTACH_SSH_USER}@${TARGET_SSH_IP}" \
    "sudo DEV_HINT='${POST_ATTACH_DEVICE_HINT}' MOUNT_POINT='${POST_ATTACH_MOUNT_POINT}' DB_NAME='${POST_ATTACH_PG_DB_NAME}' TABLE_NAME='${POST_ATTACH_PG_TABLE_NAME}' VALIDATE_PG='${POST_ATTACH_VALIDATE_PG}' DB_VALIDATOR='${POST_ATTACH_DB_VALIDATOR}' CUSTOM_VALIDATE_CMD='${POST_ATTACH_CUSTOM_VALIDATE_CMD}' ALLOW_LVM='${POST_ATTACH_ALLOW_LVM_ACTIVATE}' ALLOW_LUKS='${POST_ATTACH_ALLOW_LUKS_OPEN}' UPDATE_PG_CONF='${POST_ATTACH_UPDATE_POSTGRESQL_CONF}' START_POSTGRES='${POST_ATTACH_START_POSTGRESQL}' bash '$REMOTE_VALIDATE_SCRIPT'" \
    2>&1 | tee -a "$VALIDATE_LOG"
  VALIDATE_RC=${PIPESTATUS[0]}
  set -e

  ROW_COUNT="$(awk '/Row count:/{flag=1; next} flag && $0 ~ /^[[:space:]]*[0-9]+[[:space:]]*$/ {print; exit}' "$VALIDATE_LOG" 2>/dev/null | tr -d '[:space:]' || true)"
  python3 - "$VALIDATE_JSON" "$VALIDATE_RC" "$FLEX_VOL_ID" "$POST_ATTACH_DEVICE_HINT" "$POST_ATTACH_MOUNT_POINT" "$POST_ATTACH_PG_DB_NAME" "$POST_ATTACH_PG_TABLE_NAME" "${ROW_COUNT:-}" <<'PY'
import json, sys
path, rc, vol, dev, mp, db, table, rows = sys.argv[1:]
status = "success" if rc == "0" else "failed"
payload = {
    "post_attach_validation_status": status,
    "flex_volume_id": vol,
    "attached_device_hint": dev,
    "post_attach_mount_point": mp,
    "db_name": db,
    "table_name": table,
    "post_attach_query_row_count": int(rows) if rows.isdigit() else None,
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
PY
  log "[VOL_POST_ATTACH_VALIDATE] Log: $VALIDATE_LOG"
  log "[VOL_POST_ATTACH_VALIDATE] Result JSON: $VALIDATE_JSON"
  [ "$VALIDATE_RC" -eq 0 ] || fail_exit "Post-attach validation failed rc=$VALIDATE_RC"
  log "[VOL_POST_ATTACH_VALIDATE] HIT validation complete"
else
  log "[VOL_POST_ATTACH_VALIDATE] skipped (post_attach_validate_mount=false)"
fi

# ── VS12: Cleanup — detach + optionally delete temp source volume ─────────────
if [ "$SOURCE_MODE" = "flex" ]; then
  stage "VS12_CLEANUP_SOURCE_FLEX"
  source_label="Source FLEX"
else
  stage "VS12_CLEANUP_OSPC"
  source_label="OSPC"
fi
log "[VS12] Detaching temp $source_label vol=$OSPC_VOL_ID from server=$SELF_SERVER_ID"
source_detach_volume "$SELF_SERVER_ID" "$OSPC_VOL_ID"
source_wait_volume "$OSPC_VOL_ID" "available" 300 || true

if [ "$CLEANUP_TEMP" = "true" ]; then
  log "[VS12] Deleting temp $source_label volume $OSPC_VOL_ID"
  source_delete_volume "$OSPC_VOL_ID"
  log "[VS12] Temp $source_label volume deleted"
else
  log "[VS12] cleanup_temp=false — temp $source_label volume $OSPC_VOL_ID left in available state"
fi
CLEANUP_DONE=1

log "══════════════════════════════════════════════════════"
log "  VOLSNAP DIRECT CINDER COMPLETE"
log "══════════════════════════════════════════════════════"
log "  $source_label snapshot         : $SNAPSHOT_ID"
log "  FLEX Cinder volume    : $FLEX_VOL_ID  ($FLEX_VOL_NAME, ${FLEX_VOL_SIZE_GB}GB)"
[ -n "$FLEX_TARGET_VM_ID" ] && log "  Attached to FLEX VM   : $FLEX_TARGET_VM_ID"
log "  Storage path          : Storage → Volumes (not Compute → Images)"
