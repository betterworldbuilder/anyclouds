#!/usr/bin/env bash
# ospc2flex_linux_snap_migrate.sh — Linux snapshot migration (runs on jumphost)
#
# Download:  Method Z waterfall (Glance direct → curl → Cloud Files → Cinder)
# Repair:    ospc2flex_offline_repair.sh  (mig_worker_v4 Step 4 — proven working)
# Upload:    openstack image create with retry  (mig_worker_v4 Step 5)
# Boot:      FLEX VM create + wait ACTIVE  (mig_worker_v4 Step 7)
# SSH test:  FIP + ssh-ok probe  (mig_worker_v4 Step 9)
#
# Resume:    If QCOW exists → skip download.  If repair marker exists → skip repair.

set -euo pipefail
export PATH="$PATH:/usr/sbin:/sbin"

if [ -z "${OSPC2FLEX_LINEBUF_WRAPPER:-}" ] && command -v stdbuf >/dev/null 2>&1; then
  export OSPC2FLEX_LINEBUF_WRAPPER=1
  exec stdbuf -oL -eL bash "$0" "$@"
fi

# ── Defaults ─────────────────────────────────────────────────────────────────
LABEL=""
OSPC_IMAGE_ID=""
OSPC_OPENRC=""
FLEX_OPENRC=""
OS_TYPE=""
CLOUD_FILES_CONTAINER=""
CLOUD_FILES_OBJECT=""
BASE_DIR="${OSPC2FLEX_LINUX_SNAP_BASE_DIR:-/mnt/migration/ospc2flex_linux_snap}"
FLEX_REGION="${FLEX_REGION:-DFW3}"
FLAVOR="${FLEX_FLAVOR:-${MIG_FLAVOR:-gp.0.4.4}}"
NETWORK="${FLEX_NETWORK:-${MIG_NETWORK:-tenant-net}}"
KEYPAIR="${FLEX_KEYPAIR:-}"
FLEX_EXT_NET="${FLEX_EXT_NET:-${OSPC2FLEX_FLEX_EXT_NET:-${PUBLIC_NETWORK:-PUBLICNET}}}"
SSH_KEY_PATH="${SSH_KEY_PATH:-${OSPC2FLEX_SSH_KEY_PATH:-$HOME/.ssh/id_rsa}}"
SSH_ATTEMPTS="${OSPC2FLEX_LINUX_SNAP_SSH_ATTEMPTS:-30}"
SSH_WAIT="${OSPC2FLEX_LINUX_SNAP_SSH_WAIT:-20}"
EXPORT_RETRIES="${OSPC2FLEX_IMAGE_EXPORT_RETRIES:-4}"
EXPORT_RETRY_WAIT="${OSPC2FLEX_IMAGE_EXPORT_RETRY_WAIT:-15}"
CLOUD_FILES_EXPORT_TIMEOUT="${OSPC2FLEX_CF_EXPORT_TIMEOUT:-7200}"
CF_FAILURE_CACHE_TTL="${OSPC2FLEX_CF_FAILURE_CACHE_TTL:-21600}"
USE_CLOUD_FILES_EXPORT="${OSPC2FLEX_USE_CLOUD_FILES_EXPORT:-1}"
CINDER_VOLUME_EXPORT_ON_LICENSED="${OSPC2FLEX_CINDER_VOLUME_EXPORT_ON_LICENSED:-1}"
CINDER_MIN_VOLUME_SIZE_GB="${OSPC2FLEX_CINDER_MIN_VOLUME_SIZE_GB:-75}"
CINDER_CREATE_TIMEOUT="${OSPC2FLEX_CINDER_CREATE_TIMEOUT:-7200}"
CINDER_CREATE_ATTEMPTS="${OSPC2FLEX_CINDER_CREATE_ATTEMPTS:-3}"
CINDER_CREATE_RETRY_WAIT="${OSPC2FLEX_CINDER_CREATE_RETRY_WAIT:-45}"
PREFER_CINDER_FOR_RACKSPACE_SNAPSHOT="${OSPC2FLEX_PREFER_CINDER_FOR_RACKSPACE_SNAPSHOT:-0}"
LIVE_ORIGIN_FALLBACK="${OSPC2FLEX_LIVE_ORIGIN_FALLBACK:-1}"
LIVE_ORIGIN_EXPORT_FIRST="${OSPC2FLEX_LIVE_ORIGIN_EXPORT_FIRST:-0}"
ORIGIN_SSH_USER="${OSPC2FLEX_ORIGIN_SSH_USER:-ubuntu}"
# NO IMAGE RESUME → recreate a fresh source snapshot before the CF/Cinder upload waterfall, so a
# stale/broken existing snapshot is bypassed. Needs a source server id (from image metadata
# instance_uuid, or OSPC2FLEX_SOURCE_SERVER_ID passed by the dashboard).
RECREATE_IMAGE_ON_NO_RESUME="${OSPC2FLEX_RECREATE_IMAGE_ON_NO_RESUME:-0}"
SOURCE_SERVER_ID="${OSPC2FLEX_SOURCE_SERVER_ID:-}"
RECREATE_IMAGE_TIMEOUT="${OSPC2FLEX_RECREATE_IMAGE_TIMEOUT:-1800}"
WORKSPACE_MIN_FREE_GB="${OSPC2FLEX_LINUX_SNAP_MIN_FREE_GB:-120}"
WORKSPACE_CONVERT_BUFFER_GB="${OSPC2FLEX_LINUX_SNAP_CONVERT_BUFFER_GB:-10}"
LOCK_TIMEOUT="${OSPC2FLEX_LINUX_SNAP_LOCK_TIMEOUT:-21600}"
KEEP_RAW_AFTER_QCOW="${OSPC2FLEX_LINUX_SNAP_KEEP_RAW_AFTER_QCOW:-0}"
DOWNLOAD_ONLY=0
DRY_RUN=0
START_FRESH=0
REPAIR_VERSION="${OSPC2FLEX_LINUX_SNAP_REPAIR_VERSION:-20260516-v1}"
JOB_ID="${OSPC2FLEX_JOB_ID:-$(date -u +%s)}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label)              LABEL="$2";        shift 2 ;;
    --ospc-image-id|--ospc-snapshot-id) OSPC_IMAGE_ID="$2"; shift 2 ;;
    --ospc-openrc)        OSPC_OPENRC="$2";  shift 2 ;;
    --flex-openrc)        FLEX_OPENRC="$2";  shift 2 ;;
    --os-type)            OS_TYPE="$2";      shift 2 ;;
    --cloud-files-container) CLOUD_FILES_CONTAINER="$2"; shift 2 ;;
    --cloud-files-object) CLOUD_FILES_OBJECT="$2"; shift 2 ;;
    --base-dir)           BASE_DIR="$2";     shift 2 ;;
    --flex-region)        FLEX_REGION="$2";  shift 2 ;;
    --flavor|--flex-flavor) FLAVOR="$2";     shift 2 ;;
    --network|--flex-network) NETWORK="$2";  shift 2 ;;
    --keypair|--flex-keypair) KEYPAIR="$2";  shift 2 ;;
    --flex-ext-net|--external-network|--public-network) FLEX_EXT_NET="$2"; shift 2 ;;
    --ssh-key-path)     SSH_KEY_PATH="$2"; shift 2 ;;
    --nbd-dev)           NBD_DEV="$2";      shift 2 ;;
    --download-only)      DOWNLOAD_ONLY=1;   shift ;;
    --dry-run)            DRY_RUN=1;         shift ;;
    --start-fresh)        START_FRESH=1;     shift ;;
    --job-id)             JOB_ID="$2";       shift 2 ;;
    *) echo "ERROR: Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$LABEL" ]       || { echo "ERROR: --label required" >&2; exit 2; }
case "${OS_TYPE,,}" in
  alma) OS_TYPE="almalinux" ;;
esac
if [ "$DRY_RUN" != 1 ]; then
  [ -n "$OSPC_OPENRC" ] || { echo "ERROR: --ospc-openrc required" >&2; exit 2; }
  [ -n "$FLEX_OPENRC" ] || { echo "ERROR: --flex-openrc required" >&2; exit 2; }
elif [ "$BASE_DIR" = "/mnt/migration/ospc2flex_linux_snap" ]; then
  BASE_DIR="/tmp/ospc2flex_linux_snap_dryrun"
fi

LABEL_SAFE="$(printf '%s' "$LABEL" | tr -c 'A-Za-z0-9._-' '_' | sed 's/_$//')"
RUN_ID="${OSPC2FLEX_RUN_ID:-$(date -u +%Y%m%d-%H%M%S)}"
RUN_DIR="$BASE_DIR/runs/$LABEL_SAFE/$RUN_ID"
JOB_ART="$RUN_DIR/artifacts"
JOB_LOG="$RUN_DIR/logs"
JOB_TMP="$RUN_DIR/tmp"

if ! mkdir -p "$JOB_ART" "$JOB_LOG" "$JOB_TMP" 2>/dev/null; then
  sudo mkdir -p "$BASE_DIR" && sudo chown -R "$(id -u):$(id -g)" "$BASE_DIR"
  mkdir -p "$JOB_ART" "$JOB_LOG" "$JOB_TMP"
fi

PROGRESS_LOG="$JOB_LOG/linux_snap.progress.log"
BACKGROUND_LOG="$JOB_LOG/linux_snap.background.log"
: >"$PROGRESS_LOG"; : >"$BACKGROUND_LOG"

QCOW="$JOB_ART/${LABEL_SAFE}.qcow2"
REPAIR_MARKER="${QCOW}.linux_repaired"
REPAIR_LOG="$JOB_ART/${LABEL_SAFE}.repair.log"
NBD_DEV="${NBD_DEV:-/dev/nbd0}"
CURRENT_STAGE="LS0_PREFLIGHT"
DOWNLOAD_FAILURE_REASON="OSPC_SNAPSHOT_DOWNLOAD_UNAVAILABLE"

# ── Per-OS defaults ───────────────────────────────────────────────────────────
infer_flex_user() {
  case "${OS_TYPE,,}" in
    ubuntu*) echo "ubuntu" ;;
    debian*) echo "admin" ;;
    centos*|rhel7*|rhel6*) echo "centos" ;;
    alma*|almalinux*) echo "almalinux" ;;
    rocky*) echo "rocky" ;;
    *) echo "root" ;;
  esac
}
FLEX_USER="${FLEX_USER:-$(infer_flex_user)}"

# ── Logging ───────────────────────────────────────────────────────────────────
log() {
  local msg="$*" ts
  ts="[$(date '+%H:%M:%S')]"
  echo "${ts}[$LABEL_SAFE][job:$JOB_ID][LINSNAP] ${msg}"
  echo "${ts}[$LABEL_SAFE][job:$JOB_ID][LINSNAP] ${msg}" >>"$BACKGROUND_LOG"
  echo "${ts}[$LABEL_SAFE][job:$JOB_ID][LINSNAP] ${msg}" >>"$PROGRESS_LOG"
}
fmt_bytes() {
  local n="${1:-0}"
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec --suffix=B "$n" 2>/dev/null || printf '%sB\n' "$n"
  else
    printf '%sB\n' "$n"
  fi
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
require_workspace_free_bytes() {
  local path="$1" required="$2" context="$3" avail
  avail="$(available_bytes_for_path "$path")"
  [ -n "$avail" ] || fail_exit "$CURRENT_STAGE" "Could not determine free space for $path"
  log "[SPACE] $context: required=$(fmt_bytes "$required") available=$(fmt_bytes "$avail") path=$path"
  if [ "$avail" -lt "$required" ]; then
    fail_exit "$CURRENT_STAGE" "Insufficient jumphost workspace for $context: required $(bytes_to_gib "$required") GiB, available $(bytes_to_gib "$avail") GiB. Clean /mnt/migration artifacts or increase the jumphost volume before retry."
  fi
}
require_workspace_min_free_gb() {
  local path="$1" min_gb="$2" context="$3"
  require_workspace_free_bytes "$path" "$(gib_to_bytes "$min_gb")" "$context"
}
acquire_linux_snap_lock() {
  [ "${OSPC2FLEX_LINUX_SNAP_DISABLE_LOCK:-0}" = "1" ] && {
    log "[LOCK] Linux snapshot job lock disabled by OSPC2FLEX_LINUX_SNAP_DISABLE_LOCK=1"
    return 0
  }
  command -v flock >/dev/null 2>&1 || {
    log "[LOCK] flock not available; continuing without serialized migration guard"
    return 0
  }
  # Per-label lock: different images run in parallel; same image can't run twice simultaneously.
  local lock_file="$BASE_DIR/.linux_snap_migration_${LABEL_SAFE}.lock"
  exec 9>"$lock_file"
  log "[LOCK] Waiting for per-label lock: $lock_file timeout=${LOCK_TIMEOUT}s"
  if ! flock -w "$LOCK_TIMEOUT" 9; then
    fail_exit "LS0_PREFLIGHT" "This image label ($LABEL_SAFE) is already running on this jumphost. Retry later or raise OSPC2FLEX_LINUX_SNAP_LOCK_TIMEOUT."
  fi
  log "[LOCK] Acquired per-label lock for $LABEL_SAFE"
}
mb_from_bytes() {
  local n="${1:-0}"
  awk -v n="$n" 'BEGIN{if(n>0) printf "%.0f", n/1048576; else printf "0"}'
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
log_download_wait_status() {
  local phase="$1" elapsed_s="${2:-0}" total_s="${3:-0}" status="${4:-waiting}" extra="${5:-}" pct filled empty bar
  pct="$(awk -v e="$elapsed_s" -v t="$total_s" 'BEGIN{if(t>0) printf "%.1f", (e/t)*100; else printf "0.0"}')"
  filled="$(awk -v p="$pct" 'BEGIN{n=int(p/5); if(n<0)n=0; if(n>20)n=20; print n}')"
  empty=$((20 - filled))
  bar="$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' "$empty" '' | tr ' ' '-')"
  log "[DOWNLOAD_STATUS] phase=$phase downloaded_mb=0 total_mb=0 pct=$pct status=$status elapsed_s=$elapsed_s timeout_s=$total_s${extra:+ $extra}"
  log "[DOWNLOAD_BAR] phase=$phase [$bar] ${pct}% elapsed=${elapsed_s}/${total_s}s status=${status}${extra:+ $extra}"
}
upload_progress_bar() {
  local phase="$1" uploaded_mb="${2:-0}" total_mb="${3:-0}" status="${4:-unknown}" eta_min="${5:-}" pct="${6:-}" extra="${7:-}"
  if [ -z "$pct" ] || [ "$pct" = "unknown" ]; then
    pct="$(awk -v d="$uploaded_mb" -v t="$total_mb" 'BEGIN{if(t>0) printf "%.1f", (d/t)*100; else printf "0.0"}')"
  fi
  local filled empty bar
  filled="$(awk -v p="$pct" 'BEGIN{n=int(p/5); if(n<0)n=0; if(n>20)n=20; print n}')"
  empty=$((20 - filled))
  bar="$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' "$empty" '' | tr ' ' '-')"
  log "[UPLOAD_BAR] phase=$phase [$bar] ${pct}% ${uploaded_mb}/${total_mb}MB status=${status}${eta_min:+ eta_min=$eta_min}${extra:+ $extra}"
}
log_upload_status() {
  local phase="$1" uploaded_mb="${2:-0}" total_mb="${3:-0}" status="${4:-unknown}" pct="${5:-}" eta_min="${6:-}" extra="${7:-}"
  if [ -z "$pct" ] || [ "$pct" = "unknown" ]; then
    pct="$(awk -v d="$uploaded_mb" -v t="$total_mb" 'BEGIN{if(t>0) printf "%.1f", (d/t)*100; else printf "0.0"}')"
  fi
  log "[UPLOAD_STATUS] phase=$phase uploaded_mb=$uploaded_mb total_mb=$total_mb pct=$pct${eta_min:+ eta_min=$eta_min} status=$status${extra:+ $extra}"
  upload_progress_bar "$phase" "$uploaded_mb" "$total_mb" "$status" "$eta_min" "$pct" "$extra"
}
log_upload_wait_status() {
  local phase="$1" elapsed_s="${2:-0}" total_s="${3:-0}" status="${4:-waiting}" extra="${5:-}" pct filled empty bar
  pct="$(awk -v e="$elapsed_s" -v t="$total_s" 'BEGIN{if(t>0) printf "%.1f", (e/t)*100; else printf "0.0"}')"
  filled="$(awk -v p="$pct" 'BEGIN{n=int(p/5); if(n<0)n=0; if(n>20)n=20; print n}')"
  empty=$((20 - filled))
  bar="$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' "$empty" '' | tr ' ' '-')"
  log "[UPLOAD_STATUS] phase=$phase uploaded_mb=0 total_mb=0 pct=$pct status=$status elapsed_s=$elapsed_s timeout_s=$total_s${extra:+ $extra}"
  log "[UPLOAD_BAR] phase=$phase [$bar] ${pct}% elapsed=${elapsed_s}/${total_s}s status=${status}${extra:+ $extra}"
}
proc_io_bytes() {
  local pid="$1"
  awk '
    /^read_bytes:/ { rb=$2 }
    /^rchar:/ { rc=$2 }
    END {
      if (rb > 0) print rb;
      else if (rc > 0) print rc;
      else print 0;
    }
  ' "/proc/$pid/io" 2>/dev/null || printf '0\n'
}
run_qemu_convert_with_progress() {
  local phase="$1" src="$2" fmt="$3" out="$4" qlog="$5"
  local src_bytes src_mb out_bytes out_mb pct pid rc
  src_bytes="$(stat -c%s "$src" 2>/dev/null || echo 0)"
  src_mb="$(mb_from_bytes "$src_bytes")"
  : >"$qlog"
  set +e
  qemu-img convert -f "$fmt" -O qcow2 -c "$src" "$out" >>"$qlog" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    out_bytes="$(stat -c%s "$out" 2>/dev/null || echo 0)"
    out_mb="$(mb_from_bytes "$out_bytes")"
    pct="$(awk -v d="$out_bytes" -v t="$src_bytes" 'BEGIN{if(t>0){p=(d/t)*100; if(p>99)p=99; printf "%.1f", p}else printf "0.0"}')"
    log_download_status "$phase" "$out_mb" "$src_mb" "converting" "$pct" "" "output=$out"
    sleep 30
  done
  wait "$pid"; rc=$?
  set -e
  out_bytes="$(stat -c%s "$out" 2>/dev/null || echo 0)"
  out_mb="$(mb_from_bytes "$out_bytes")"
  if [ "$rc" -eq 0 ]; then
    log_download_status "$phase" "$out_mb" "$src_mb" "complete" "100.0" "" "output=$out"
  else
    log "[${phase}] qemu-img convert failed rc=$rc; detail_log=$qlog"
    log "[${phase}] workspace free after failure: $(df -hP "$(dirname "$out")" 2>/dev/null | awk 'NR==2{print $4 " free / " $2 " total (" $5 " used)"}' || echo unknown)"
    if [ -s "$qlog" ]; then
      log "[${phase}] qemu detail tail:"
      tail -20 "$qlog" 2>/dev/null | while IFS= read -r qline; do
        log "[${phase}][qemu] $qline"
      done
    else
      log "[${phase}] qemu detail log is empty; check kernel/dmesg and storage health on the jumphost."
    fi
  fi
  return "$rc"
}
kv() { log "  $(printf '%-18s' "$1") : ${*:2}"; }
stage() {
  CURRENT_STAGE="$1"
  log "══════════════════════════════════════════════════════"
  log "  $CURRENT_STAGE"
  log "══════════════════════════════════════════════════════"
}
fail_exit() {
  local s="$1" reason="$2"
  log "[$s] FAILED: $reason"
  exit 1
}
trap 'log "TRAP: unexpected error at line $LINENO: $BASH_COMMAND"; exit 1' ERR

if [ "$DRY_RUN" = 1 ]; then
  for s in \
    LS0_PREFLIGHT \
    LS0A_CLEAN_STALE_IMAGES \
    LS1_LOAD_CREDENTIALS \
    LS2_SELECT_SNAPSHOT \
    LS3_DOWNLOAD_SNAPSHOT \
    LS4_NORMALIZE_QCOW2 \
    LS5_OFFLINE_REPAIR \
    LS6_UPLOAD_FLEX \
    LS7_BOOT_FLEX_VM \
    LS8_FLOATING_IP \
    LS9_SSH_TEST
  do
    stage "$s"
    log "[$s] DRY-RUN Linux snapshot stage; no snapshot download, repair, upload, boot, or SSH probe"
  done
  log "METHOD_LINUX_SNAPSHOT_DRY_RUN_SUCCESS"
  exit 0
fi

acquire_linux_snap_lock

# ── Tool check / install ──────────────────────────────────────────────────────
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail_exit "$CURRENT_STAGE" "missing_command: $1 — install it on the jumphost"
}
install_if_missing() {
  local missing=() c pkg
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  [ "${#missing[@]}" -gt 0 ] || return 0
  log "[LS0] Installing missing: ${missing[*]}"
  command -v apt-get >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1 || {
    fail_exit "LS0_PREFLIGHT" "Missing: ${missing[*]} and cannot auto-install (no apt-get or passwordless sudo)"
  }
  sudo -n env DEBIAN_FRONTEND=noninteractive apt-get update >>"$BACKGROUND_LOG" 2>&1
  for c in "${missing[@]}"; do
    case "$c" in
      qemu-img|qemu-nbd) pkg="qemu-utils" ;;
      openstack) pkg="python3-openstackclient" ;;
      curl) pkg="curl" ;;
      python3) pkg="python3" ;;
      *) pkg="$c" ;;
    esac
    sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >>"$BACKGROUND_LOG" 2>&1 || true
    command -v "$c" >/dev/null 2>&1 || fail_exit "LS0_PREFLIGHT" "$c still missing after install attempt"
    log "[LS0] OK: $c"
  done
}

cleanup_stale_jumphost_images() {
  [ "${OSPC2FLEX_LINUX_SNAP_CLEAN_STALE_IMAGES:-1}" = "1" ] || {
    log "[LS0A] stale image cleanup disabled"
    return 0
  }

  local cleanup_root="$BASE_DIR/runs/$LABEL_SAFE"
  local min_age_minutes="${OSPC2FLEX_LINUX_SNAP_CLEAN_MIN_AGE_MIN:-60}"
  if [ "${OSPC2FLEX_LINUX_SNAP_GLOBAL_CLEANUP:-1}" = "1" ]; then
    cleanup_root="/mnt/migration"
  fi
  [ -d "$cleanup_root" ] || {
    log "[LS0A] no stale image files found; label cleanup root not found: $cleanup_root"
    return 0
  }
  local resolved_cleanup_root resolved_migration_root resolved_label_root
  resolved_cleanup_root="$(readlink -f "$cleanup_root" 2>/dev/null || true)"
  resolved_migration_root="$(readlink -f /mnt/migration 2>/dev/null || printf '%s' /mnt/migration)"
  resolved_label_root="$(readlink -f "$BASE_DIR/runs/$LABEL_SAFE" 2>/dev/null || true)"
  case "$resolved_cleanup_root" in
    "$resolved_migration_root"|"$resolved_migration_root"/*) ;;
    *)
      log "[LS0A] refusing cleanup outside /mnt/migration: $cleanup_root resolved=$resolved_cleanup_root migration_root=$resolved_migration_root"
      return 0
      ;;
  esac
  if [ "${OSPC2FLEX_LINUX_SNAP_GLOBAL_CLEANUP:-1}" != "1" ] && [ "$resolved_cleanup_root" != "$resolved_label_root" ]; then
    log "[LS0A] refusing cleanup outside current label root: $cleanup_root resolved=$resolved_cleanup_root label_root=$resolved_label_root"
    return 0
  fi

  local delete_list="$JOB_TMP/stale_image_delete.tsv"
  : >"$delete_list"

  sudo find "$cleanup_root" -xdev -type f -mmin +"$min_age_minutes" \( \
      -iname "*.img" -o -iname "*.raw" -o -iname "*.vhd" -o -iname "*.vhdx" -o -iname "*.vpc" \
      -o -iname "*.qcow2" -o -iname "*repaired*.qcow2" -o -iname "*repair*.qcow2" \
      -o -iname "*flex-rescue*.qcow2" -o -iname "*final*.qcow2" -o -iname "*rescue*.qcow2" \
      -o -iname "*.invalid*" -o -iname "*.partial*" \
    \) -printf '%s\t%p\n' 2>/dev/null | sort -nr >"$delete_list" || true

  local count bytes
  count="$(wc -l <"$delete_list" | tr -d '[:space:]')"
  bytes="$(awk -F '\t' '{s+=$1} END{printf "%.0f", s+0}' "$delete_list")"
  if [ "${count:-0}" -eq 0 ]; then
    log "[LS0A] no stale image files found"
    return 0
  fi

  log "[LS0A] deleting stale image files older than ${min_age_minutes}m: count=$count bytes=$bytes"
  head -20 "$delete_list" | while IFS=$'\t' read -r sz path; do
    log "[LS0A] delete candidate: ${sz}B $path"
  done

  while IFS=$'\t' read -r _sz path; do
    [ -n "$path" ] || continue
    active_root="$(printf '%s\n' "$path" | sed -E 's#^(/mnt/migration/[^/]+/runs/[^/]+/[^/]+).*#\1#; s#^(/mnt/migration/flex2flex/[^/]+).*#\1#')"
    if [ -n "$active_root" ] && ps -eo args= 2>/dev/null | grep -F -- "$active_root" | grep -vq grep; then
      log "[LS0A] keep active run artifact: $path"
      continue
    fi
    case "$path" in
      "$QCOW"|"${SOURCE_RAW:-__none__}") log "[LS0A] keep current run artifact: $path" ;;
      /mnt/migration/*) sudo rm -f -- "$path" ;;
      *) log "[LS0A] skip outside cleanup root: $path" ;;
    esac
  done <"$delete_list"

  log "[LS0A] stale image cleanup complete; only active/current-run files and files younger than ${min_age_minutes}m are kept"
}

start_fresh_clear_label_resume() {
  [ "$START_FRESH" = "1" ] || return 0
  local label_root="$BASE_DIR/runs/$LABEL_SAFE"
  [ -d "$label_root" ] || return 0
  log "[LS0B] START FRESH: deleting previous resume artifacts for $LABEL_SAFE"
  find "$label_root" -mindepth 1 -maxdepth 1 -type d ! -name "$RUN_ID" -print 2>/dev/null | while read -r old_run; do
    [ -n "$old_run" ] || continue
    if ps -eo args= 2>/dev/null | grep -F -- "$old_run" | grep -vq grep; then
      log "[LS0B] keep active old run: $old_run"
      continue
    fi
    log "[LS0B] delete old run: $old_run"
    rm -rf -- "$old_run"
  done
}

# ── openrc helpers ────────────────────────────────────────────────────────────
source_ospc_openrc() {
  [ -f "$OSPC_OPENRC" ] || fail_exit "$CURRENT_STAGE" "OSPC openrc not found: $OSPC_OPENRC"
  unset OS_TOKEN OS_AUTH_TOKEN OS_SERVICE_TOKEN OS_AUTH_TYPE \
        OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_NAME OS_APPLICATION_CREDENTIAL_SECRET \
        OS_USERNAME OS_PASSWORD OS_PROJECT_ID OS_PROJECT_NAME OS_TENANT_ID OS_TENANT_NAME \
        OS_USER_DOMAIN_NAME OS_PROJECT_DOMAIN_NAME OS_DOMAIN_NAME 2>/dev/null || true
  # shellcheck source=/dev/null
  source "$OSPC_OPENRC"
}
source_flex_openrc() {
  [ -f "$FLEX_OPENRC" ] || fail_exit "$CURRENT_STAGE" "FLEX openrc not found: $FLEX_OPENRC"
  unset OS_TOKEN OS_AUTH_TOKEN OS_SERVICE_TOKEN OS_AUTH_TYPE \
        OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_NAME OS_APPLICATION_CREDENTIAL_SECRET \
        OS_USERNAME OS_PASSWORD OS_PROJECT_ID OS_PROJECT_NAME OS_TENANT_ID OS_TENANT_NAME \
        OS_USER_DOMAIN_NAME OS_PROJECT_DOMAIN_NAME OS_DOMAIN_NAME 2>/dev/null || true
  # shellcheck source=/dev/null
  source "$FLEX_OPENRC"
}

# ════════════════════════════════════════════════════════════════════════════
# ── DOWNLOAD HELPERS — copied verbatim from Method Z (proven working) ────────
# ════════════════════════════════════════════════════════════════════════════
url_host() { printf '%s' "$1" | sed -E 's#^[a-zA-Z]+://([^/:]+).*$#\1#'; }
host_resolves() {
  local h="$1"; [ -n "$h" ] || return 1
  printf '%s' "$h" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[0-9a-fA-F:]+$' && return 0
  getent hosts "$h" >/dev/null 2>&1
}
normalize_glance_base() { printf '%s' "$1" | tr -d '[:space:]' | sed -E 's#/v2/?$##'; }
region_short() {
  local r="${OS_REGION_NAME:-IAD}"
  r="$(printf '%s' "$r" | tr '[:upper:]' '[:lower:]' | tr -d '0-9')"
  [ -n "$r" ] || r="iad"; printf '%s' "$r"
}
ospc_tenant_id() {
  printf '%s' "${OS_TENANT_ID:-${OS_PROJECT_ID:-${OS_TENANT_NAME:-${OS_PROJECT_NAME:-}}}}"
}
translate_rackspace_images_base() {
  local base host label prefix region translated_host
  base="$(normalize_glance_base "$1")"
  host="$(url_host "$base")"
  case "$host" in
    *.images.api.rackspacecloud.com)
      label="${host%.images.api.rackspacecloud.com}"; prefix=""; region="$label"
      printf '%s' "$region" | grep -q '^snet-' && { prefix="snet-"; region="${region#snet-}"; }
      printf '%s' "$region" | grep -q '[0-9]' || region="${region}3"
      translated_host="${prefix}${region}.images.api.rackspacecloud.com"
      printf '%s' "$base" | sed "s#${host}#${translated_host}#" ;;
    *) printf '%s' "$base" ;;
  esac
}
image_bases() {
  local region catalog_json url translated
  region="$(region_short)"
  catalog_json="$(openstack catalog show image -f json 2>/dev/null || true)"
  {
    if [ -s "$JOB_TMP/ospc_identity_v2_auth.json" ]; then
      WANTED_REGION="$(printf '%s' "${OS_REGION_NAME:-ALL}" | tr '[:lower:]' '[:upper:]')" python3 - "$JOB_TMP/ospc_identity_v2_auth.json" <<'PY' 2>/dev/null || true
import json, os, sys
wanted = (os.environ.get("WANTED_REGION") or "ALL").strip().upper()
try: data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception: data = {}
for svc in (((data or {}).get("access") or {}).get("serviceCatalog") or []):
    stype = str((svc or {}).get("type") or "").strip().lower()
    sname = str((svc or {}).get("name") or "").strip().lower()
    if stype not in {"image","cloudimages"} and sname not in {"image","cloudimages"}: continue
    for ep in (svc or {}).get("endpoints") or []:
        region = str((ep or {}).get("region") or "").strip().upper()
        url = str((ep or {}).get("publicURL") or (ep or {}).get("url") or "").strip().rstrip("/")
        if not url: continue
        if wanted != "ALL" and region != wanted: continue
        print(url)
PY
    fi
    if [ -n "$catalog_json" ]; then
      CATALOG_JSON="$catalog_json" python3 - <<'PY' 2>/dev/null || true
import json, os
try: data = json.loads(os.environ.get("CATALOG_JSON","{}"))
except Exception: data = {}
for ep in data.get("endpoints") or []:
    iface = str(ep.get("interface") or "").lower()
    if iface == "public":
        url = ep.get("url") or ep.get("publicURL") or ep.get("internalURL") or ep.get("adminURL")
        if url: print(str(url).rstrip("/"))
PY
    fi
    openstack endpoint list --service image --interface public -f value -c URL 2>/dev/null || true
    printf 'https://%s.images.api.rackspacecloud.com\n' "$region"
    printf 'https://%s3.images.api.rackspacecloud.com\n' "$region"
  } | while IFS= read -r url; do
    [ -n "$url" ] || continue
    url="$(normalize_glance_base "$url")"
    printf '%s\n' "$url"
    translated="$(translate_rackspace_images_base "$url")"
    [ "$translated" != "$url" ] && printf '%s\n' "$translated"
  done | awk 'NF && !seen[$0]++'
}

rackspace_identity_v2_auth() {
  local auth_url api_key tenant payload auth_resp token
  api_key="${OS_API_KEY:-${OS_PASSWORD:-}}"
  tenant="$(ospc_tenant_id)"
  [ -n "${OS_USERNAME:-}" ] && [ -n "$api_key" ] && [ -n "$tenant" ] || return 1
  auth_url="${OS_AUTH_URL:-https://identity.api.rackspacecloud.com/v2.0/}"
  auth_url="${auth_url%/}/tokens"
  payload="$(OSPC_USER="$OS_USERNAME" OSPC_API_KEY="$api_key" OSPC_TENANT="$tenant" python3 - <<'PY'
import json, os
print(json.dumps({"auth":{"RAX-KSKEY:apiKeyCredentials":{"username":os.environ["OSPC_USER"],"apiKey":os.environ["OSPC_API_KEY"]},"tenantId":os.environ["OSPC_TENANT"]}},separators=(",",":")))
PY
)"
  auth_resp="$(curl -sS -k -X POST "$auth_url" -H "Content-Type: application/json" -H "Accept: application/json" -d "$payload" 2>/dev/null || true)"
  token="$(printf '%s' "$auth_resp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["access"]["token"]["id"])' 2>/dev/null || true)"
  [ -n "$token" ] || return 1
  printf '%s\n' "$auth_resp" >"$JOB_TMP/ospc_identity_v2_auth.json" 2>/dev/null || true
  chmod 600 "$JOB_TMP/ospc_identity_v2_auth.json" 2>/dev/null || true
  printf '%s' "$token"
}
refresh_ospc_token() {
  local token
  token="$(rackspace_identity_v2_auth || true)"
  [ -n "$token" ] && { printf '%s' "$token"; return 0; }
  token="$(openstack token issue -f value -c id 2>/dev/null || true)"
  [ -n "$token" ] && { printf '%s' "$token"; return 0; }
  return 1
}
safe_object_name() {
  python3 -c 'import re,sys; print(re.sub(r"[^A-Za-z0-9._-]+","_",sys.argv[1]).strip("._-") or "ospc2flex-linux-snap-image")' "$1"
}
first_resolvable_image_base() {
  local base host
  while IFS= read -r base; do
    [ -n "$base" ] || continue
    host="$(url_host "$base")"
    if host_resolves "$host"; then printf '%s' "$base"; return 0; fi
  done < <(image_bases)
  return 1
}
log_file_excerpt() {
  local prefix="$1" file="$2"
  [ -s "$file" ] || return 0
  grep -iE 'error|fail|invalid|413|403|404|forbidden|unauthorized|endpoint|resolve|timeout|exception|denied' "$file" 2>/dev/null | tail -8 | while IFS= read -r line; do [ -n "$line" ] && log "$prefix $line"; done
  tail -5 "$file" 2>/dev/null | while IFS= read -r line; do [ -n "$line" ] && log "$prefix tail: $line"; done
}
is_terminal_direct_download_block() {
  local file="$1"
  [ -s "$file" ] || return 1
  grep -qiE 'HTTP_CODE=413|returned error: 413|Request Entity Too Large|InvalidResponse' "$file"
}
download_openstack_save() {
  local base="$1" image_id="$2" dest="$3" min_bytes="$4" tmp_log="$5" rc size
  rm -f "$dest"
  [ -n "$base" ] && log "[ZS3] openstack image save via OS_IMAGE_URL=$base" || log "[ZS3] openstack image save via catalog default"
  set +e
  if [ -n "$base" ]; then
    OS_IMAGE_URL="$base" openstack image save --file "$dest" "$image_id" >"$tmp_log" 2>&1
  else
    openstack image save --file "$dest" "$image_id" >"$tmp_log" 2>&1
  fi
  rc=$?; set -e
  size="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
  if [ "$rc" -eq 0 ] && [ "$size" -ge "$min_bytes" ]; then
    log "[ZS3] HIT openstack image save downloaded $size bytes"; return 0
  fi
  log "[ZS3] WARN openstack image save failed rc=$rc size=${size}B"
  log_file_excerpt "[ZS3] save-error:" "$tmp_log"
  rm -f "$dest"; return 1
}
download_curl_glance() {
  local base="$1" image_id="$2" dest="$3" min_bytes="$4" token="$5" tmp_log="$6" url rc size project_header=()
  rm -f "$dest"
  url="${base}/v2/images/${image_id}/file"
  [ -n "$(ospc_tenant_id)" ] && project_header=(-H "X-Auth-Project-Id: $(ospc_tenant_id)")
  log "[ZS3] curl direct Glance download: $url"
  set +e
  curl -fSL --connect-timeout 30 --retry 2 --retry-delay 10 \
    --speed-time 180 --speed-limit 1024 \
    -H "X-Auth-Token: $token" "${project_header[@]}" \
    -H "Accept: application/octet-stream" -H "Expect:" \
    -A "ospc2flex-linsnap/1.0" -o "$dest" \
    --write-out "\nHTTP_CODE=%{http_code} SIZE=%{size_download}B TIME=%{time_total}s\n" \
    "$url" >"$tmp_log" 2>&1
  rc=$?; set -e
  size="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
  if [ "$rc" -eq 0 ] && [ "$size" -ge "$min_bytes" ]; then
    log "[ZS3] HIT curl downloaded $size bytes"; return 0
  fi
  log "[ZS3] WARN curl failed rc=$rc size=${size}B"
  log_file_excerpt "[ZS3] curl-error:" "$tmp_log"
  rm -f "$dest"; return 1
}
download_cloud_files_object() {
  local container="$1" object_name="$2" dest="$3" min_bytes="$4" tmp_log="$5" size total_bytes total_mb save_pid dl_start_s copied copied_mb pct elapsed_s eta_min rc
  CF_OBJECT_DOWNLOAD_REASON=""
  rm -f "$dest"
  log "[ZS3] Cloud Files object download: $container/$object_name"
  total_bytes="$(openstack object show "$container" "$object_name" -f value -c bytes 2>/dev/null | tr -dc '0-9' || true)"
  [ -n "$total_bytes" ] || total_bytes="$min_bytes"
  total_mb="$(mb_from_bytes "$total_bytes")"
  log_download_status "cloud_files_object_download" "0" "$total_mb" "starting" "0.0" "unknown" "object=$object_name"
  set +e
  openstack object save "$container" "$object_name" --file "$dest" >"$tmp_log" 2>&1 &
  save_pid=$!
  dl_start_s="$(date +%s)"
  while kill -0 "$save_pid" 2>/dev/null; do
    sleep 10
    if kill -0 "$save_pid" 2>/dev/null; then
      copied="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
      copied_mb="$(mb_from_bytes "$copied")"
      pct="$(awk -v c="$copied" -v t="$total_bytes" 'BEGIN{if(t>0) printf "%.1f", (c/t)*100; else printf "0.0"}')"
      elapsed_s=$(( $(date +%s) - dl_start_s ))
      eta_min="$(awk -v c="$copied" -v t="$total_bytes" -v e="$elapsed_s" 'BEGIN{if(c>0 && e>0 && t>c) printf "%.0f", ((t-c)/(c/e))/60; else if(t>0 && c>=t) printf "0"; else printf "unknown"}')"
      log_download_status "cloud_files_object_download" "$copied_mb" "$total_mb" "downloading" "$pct" "$eta_min" "object=$object_name"
    fi
  done
  wait "$save_pid"; rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    size="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
    if [ "$size" -ge "$min_bytes" ]; then
      log_download_status "cloud_files_object_download" "$(mb_from_bytes "$size")" "$total_mb" "complete" "100.0" "0" "object=$object_name"
      log "[ZS3] HIT Cloud Files downloaded $size bytes"
      return 0
    fi
  fi
  rm -f "$dest"
  if grep -qiE 'No space left on device|Errno 28' "$tmp_log" 2>/dev/null; then
    CF_OBJECT_DOWNLOAD_REASON="no_space"
  elif grep -qiE 'Not Found|HTTP 404|404' "$tmp_log" 2>/dev/null; then
    CF_OBJECT_DOWNLOAD_REASON="missing"
  else
    CF_OBJECT_DOWNLOAD_REASON="failed"
  fi
  if [ "$CF_OBJECT_DOWNLOAD_REASON" = "missing" ]; then
    log "[ZS3] Cloud Files object not present yet: $container/$object_name"
  else
    log "[ZS3] WARN Cloud Files download failed"
    log_file_excerpt "[ZS3] cloud-files-error:" "$tmp_log"
  fi
  return 1
}
download_cloud_files_export_task() {
  local image_id="$1" dest="$2" container="$3" min_bytes="$4"
  local object_name glance_base tasks_url payload token create_resp task_id task_json status elapsed start task_msg tmp_log project_header=()
  local cf_fail_dir cf_fail_marker
  [ -n "$container" ] || container="ospc2flex-export"
  cf_fail_dir="$BASE_DIR/cache/cf_export_failures"
  cf_fail_marker="$cf_fail_dir/${image_id}.failed"
  # Use UUID-only object names. Existing successful exports in Cloud Files use
  # this shape, and it avoids label-specific export/task differences.
  object_name="$(safe_object_name "${image_id}.vhd")"
  tmp_log="$JOB_LOG/cloud_files_object_save.log"
  log "[ZS3] Cloud Files export task → $container/$object_name"
  openstack container create "$container" >"$JOB_LOG/cf_container_create.log" 2>&1 || true
  download_cloud_files_object "$container" "$object_name" "$dest" "$min_bytes" "$tmp_log" && return 0
  if [ "${CF_OBJECT_DOWNLOAD_REASON:-}" = "no_space" ]; then
    log "[ZS3] WARN Cloud Files object download stopped: no space left on jumphost"
    return 1
  fi
  if openstack object show "$container" "$object_name" >/dev/null 2>&1; then
    log "[ZS3] Existing Cloud Files object is stale/unreadable — deleting before fresh export"
    openstack object delete "$container" "$object_name" >/dev/null 2>&1 || true
  fi
  local _uuid_vhd="${image_id}.vhd"
  if [ "$_uuid_vhd" != "$object_name" ]; then
    log "[ZS3] Checking UUID-based CF object: $container/$_uuid_vhd"
    download_cloud_files_object "$container" "$_uuid_vhd" "$dest" "$min_bytes" "$tmp_log" && return 0
  fi
  if [ -s "$cf_fail_marker" ]; then
    if [ "${OSPC2FLEX_RETRY_FAILED_CF_EXPORT:-0}" = "1" ] || [ "${START_FRESH:-0}" = "1" ]; then
      log "[ZS3] Ignoring cached Cloud Files export failure for START FRESH/retry: $(head -1 "$cf_fail_marker" 2>/dev/null || echo cached failure)"
      rm -f "$cf_fail_marker" 2>/dev/null || true
    elif [ "${CF_FAILURE_CACHE_TTL:-0}" -gt 0 ] 2>/dev/null && [ "$(find "$cf_fail_marker" -mmin +"$((CF_FAILURE_CACHE_TTL / 60))" -print -quit 2>/dev/null)" = "$cf_fail_marker" ]; then
      log "[ZS3] Expiring stale Cloud Files export failure cache: $(head -1 "$cf_fail_marker" 2>/dev/null || echo cached failure)"
      rm -f "$cf_fail_marker" 2>/dev/null || true
    else
      log "[ZS3] Skipping Cloud Files export for $image_id — recent Rackspace export failed ($(head -1 "$cf_fail_marker" 2>/dev/null || echo cached failure))"
      log "[ZS3] Falling through to Cinder fallback. Set OSPC2FLEX_RETRY_FAILED_CF_EXPORT=1 to force a new CF export attempt"
      return 1
    fi
  fi
  glance_base="$(first_resolvable_image_base || true)"
  [ -n "$glance_base" ] || return 1
  tasks_url="${glance_base}/v2/tasks"
  payload="$(IMAGE_ID="$image_id" CF_CONTAINER="$container" CF_OBJECT="$object_name" python3 - <<'PY'
import json, os
print(json.dumps({"type":"export","input":{"image_uuid":os.environ["IMAGE_ID"],"receiving_swift_container":os.environ["CF_CONTAINER"],"image_name":os.environ["CF_OBJECT"]}},separators=(",",":")))
PY
)"
  token="$(refresh_ospc_token || true)"
  [ -n "$token" ] || return 1
  [ -n "$(ospc_tenant_id)" ] && project_header=(-H "X-Auth-Project-Id: $(ospc_tenant_id)")
  create_resp="$(curl -sS -X POST "$tasks_url" -H "X-Auth-Token: $token" "${project_header[@]}" -H "Content-Type: application/json" -d "$payload" 2>"$JOB_LOG/cf_task_create.err" || true)"
  task_id="$(printf '%s' "$create_resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
  [ -n "$task_id" ] || {
    log "[ZS3] WARN Cloud Files task create failed: ${create_resp:0:300}"
    mkdir -p "$cf_fail_dir" 2>/dev/null || true
    printf 'task_create_failed %s\n' "${create_resp:0:220}" >"$cf_fail_marker" 2>/dev/null || true
    return 1
  }
  log "[ZS3] Cloud Files export task: $task_id"
  start="$(date +%s)"
  log_download_wait_status "cloud_files_export" "0" "$CLOUD_FILES_EXPORT_TIMEOUT" "starting" "task=$task_id"
  while true; do
    elapsed=$(( $(date +%s) - start ))
    [ "$elapsed" -gt "$CLOUD_FILES_EXPORT_TIMEOUT" ] && {
      log "[ZS3] WARN Cloud Files export timed out after ${elapsed}s"
      mkdir -p "$cf_fail_dir" 2>/dev/null || true
      printf 'task_timeout task=%s elapsed=%ss\n' "$task_id" "$elapsed" >"$cf_fail_marker" 2>/dev/null || true
      return 1
    }
    token="$(refresh_ospc_token || printf '%s' "$token")"
    task_json="$(curl -sS "$tasks_url/$task_id" -H "X-Auth-Token: $token" "${project_header[@]}" 2>/dev/null || true)"
    status="$(printf '%s' "$task_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status","unknown"))' 2>/dev/null | tr -d '\r\n[:space:]' || echo unknown)"
    [ -n "$status" ] || status="unknown"
    log "[ZS3] CF task status=$status elapsed=${elapsed}s"
    log_download_wait_status "cloud_files_export" "$elapsed" "$CLOUD_FILES_EXPORT_TIMEOUT" "$status" "task=$task_id"
    case "$status" in
      success)
        log_download_wait_status "cloud_files_export" "$CLOUD_FILES_EXPORT_TIMEOUT" "$CLOUD_FILES_EXPORT_TIMEOUT" "complete" "task=$task_id"
        break ;;
      failure|error)
        task_msg="$(printf '%s' "$task_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("message") or d.get("result") or "")' 2>/dev/null || true)"
        log "[ZS3] WARN CF task failed: ${task_msg:-<no message>}"
        if printf '%s' "$task_msg $task_json" | grep -qiE 'licensing|billing restrictions|cannot be exported|exported by the image owner|only be exported by the image owner|com\.rackspace__1__options'; then
          DOWNLOAD_FAILURE_REASON="OSPC_SNAPSHOT_EXPORT_BLOCKED_LICENSED"
          log "[ZS3] Licensed image — Cinder fallback (not caching CF failure marker)"
          cinder_volume_raw_export "$image_id" "$dest" && return 0
          return 1
        fi
        mkdir -p "$cf_fail_dir" 2>/dev/null || true
        printf 'task_failed task=%s message=%s\n' "$task_id" "${task_msg:-<no message>}" >"$cf_fail_marker" 2>/dev/null || true
        if printf '%s' "$task_msg $task_json" | grep -qi 'Object already exists'; then
          _actual_obj="$(printf '%s' "$task_msg" | python3 -c '
import sys, re
blob = sys.stdin.read()
m = re.search(r"Container/Object:\s*[^/]+/(\S+?)[\s\"\x27}]", blob + " ")
print(m.group(1) if m else "")
' 2>/dev/null || true)"
          log "[ZS3] Object-already-exists: actual_obj='${_actual_obj:-<empty>}'"
          if [ -n "$_actual_obj" ] && [ "$_actual_obj" != "$object_name" ]; then
            log "[ZS3] Trying CF object from error: $container/$_actual_obj"
            download_cloud_files_object "$container" "$_actual_obj" "$dest" "$min_bytes" "$tmp_log" && return 0
          fi
          _uuid_vhd="${image_id}.vhd"
          if [ "$_uuid_vhd" != "$object_name" ]; then
            log "[ZS3] Trying UUID-based CF object: $container/$_uuid_vhd"
            download_cloud_files_object "$container" "$_uuid_vhd" "$dest" "$min_bytes" "$tmp_log" && return 0
          fi
          download_cloud_files_object "$container" "$object_name" "$dest" "$min_bytes" "$tmp_log" && return 0
          if [ "${CF_OBJECT_DOWNLOAD_REASON:-}" != "no_space" ]; then
            log "[ZS3] Existing export object is stale/unreadable — deleting it for next retry"
            openstack object delete "$container" "$object_name" >/dev/null 2>&1 || true
          fi
        fi
        return 1 ;;
      *) sleep 15 ;;
    esac
  done
  download_cloud_files_object "$container" "$object_name" "$dest" "$min_bytes" "$tmp_log" && return 0
  local _uuid_vhd="${image_id}.vhd"
  if [ "$_uuid_vhd" != "$object_name" ]; then
    log "[ZS3] Trying UUID-based CF object after task success: $container/$_uuid_vhd"
    download_cloud_files_object "$container" "$_uuid_vhd" "$dest" "$min_bytes" "$tmp_log" && return 0
  fi
  return 1
}

# ── Cinder helpers (for licensed images — copied from Method Z) ───────────────
rackspace_region_lc() { printf '%s' "${OS_REGION_NAME:-IAD}" | tr '[:upper:]' '[:lower:]' | tr -d '0-9'; }
rackspace_tenant_id() { printf '%s' "${OS_TENANT_ID:-${OS_PROJECT_ID:-${OS_TENANT_NAME:-${OS_PROJECT_NAME:-}}}}"; }
rackspace_blockstorage_base() {
  local r t; r="$(rackspace_region_lc)"; t="$(rackspace_tenant_id)"
  [ -n "$t" ] || return 1
  printf 'https://%s.blockstorage.api.rackspacecloud.com/v1/%s' "$r" "$t"
}
rackspace_compute_base() {
  local r t; r="$(rackspace_region_lc)"; t="$(rackspace_tenant_id)"
  [ -n "$t" ] || return 1
  printf 'https://%s.servers.api.rackspacecloud.com/v2/%s' "$r" "$t"
}
rackspace_volume_status() {
  local vol_id="$1" token base resp
  token="$(refresh_ospc_token || true)"; base="$(rackspace_blockstorage_base)"
  [ -n "$token" ] && [ -n "$base" ] || return 1
  resp="$(curl -sS "$base/volumes/$vol_id" -H "X-Auth-Token: $token" 2>/dev/null || true)"
  printf '%s' "$resp" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("volume") or {}).get("status","unknown"))' 2>/dev/null || echo unknown
}
rackspace_volume_error_summary() {
  local vol_id="$1" token base resp
  token="$(refresh_ospc_token || true)"; base="$(rackspace_blockstorage_base)"
  [ -n "$token" ] && [ -n "$base" ] || return 1
  resp="$(curl -sS "$base/volumes/$vol_id" -H "X-Auth-Token: $token" 2>>"$JOB_LOG/cinder.log" || true)"
  printf '\n[CINDER volume detail %s]\n%s\n' "$vol_id" "$resp" >>"$JOB_LOG/cinder.log" 2>/dev/null || true
  VOLUME_JSON="$resp" python3 - <<'PY' 2>/dev/null || true
import json, os
try:
    doc = json.loads(os.environ.get("VOLUME_JSON") or "{}")
except Exception:
    raise SystemExit
v = doc.get("volume") if isinstance(doc, dict) else {}
if not isinstance(v, dict):
    v = {}
parts = []
for key in ("status", "display_name", "id", "size", "bootable", "availability_zone", "migration_status"):
    val = v.get(key)
    if val not in (None, ""):
        parts.append(f"{key}={val}")
for key in ("error", "error_message", "message", "fault"):
    val = v.get(key)
    if val:
        parts.append(f"{key}={val}")
meta = v.get("metadata")
if isinstance(meta, dict):
    for key in ("readonly", "attached_mode", "image_id", "image_name"):
        val = meta.get(key)
        if val not in (None, ""):
            parts.append(f"metadata.{key}={val}")
print(" ".join(str(p).replace("\n", " ") for p in parts[:12]))
PY
}
cinder_wait_volume_status() {
  local vol_id="$1" want="$2" timeout="${3:-1800}" phase="${4:-cinder_wait}" total_mb="${5:-0}" downloaded_mb="${6:-0}" waited=0 status poll_rc
  while [ "$waited" -lt "$timeout" ]; do
    set +e
    status="$(rackspace_volume_status "$vol_id" 2>>"$JOB_LOG/cinder.log" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    poll_rc=$?
    set -e
    [ -n "$status" ] || status="unknown"
    if [ "$status" = "$want" ]; then
      log_download_wait_status "$phase" "$waited" "$timeout" "$status" "target=$want volume=$vol_id"
      return 0
    fi
    if [ "$status" = "error" ]; then
      log_download_wait_status "$phase" "$waited" "$timeout" "error" "target=$want volume=$vol_id"
      log "[CINDER] vol=$vol_id status=error target=$want waited=${waited}s poll_rc=$poll_rc"
      local err_summary; err_summary="$(rackspace_volume_error_summary "$vol_id" || true)"
      [ -n "$err_summary" ] && log "[CINDER] error detail: $err_summary"
      return 1
    fi
    if [ $((waited % 60)) -eq 0 ]; then
      log "[CINDER] vol=$vol_id status=$status target=$want waited=${waited}s poll_rc=$poll_rc"
      log_download_wait_status "$phase" "$waited" "$timeout" "$status" "target=$want volume=$vol_id"
    fi
    sleep 10; waited=$((waited + 10))
  done
  log_download_wait_status "$phase" "$timeout" "$timeout" "timeout" "target=$want volume=$vol_id"
  local err_summary; err_summary="$(rackspace_volume_error_summary "$vol_id" || true)"
  [ -n "$err_summary" ] && log "[CINDER] timeout detail: $err_summary"
  return 1
}
local_block_disks() {
  sudo lsblk -dnpo NAME,TYPE 2>/dev/null | awk '$2=="disk" && $1 !~ /^\/dev\/(nbd|loop|sr|fd)/ {print $1}' | sort
}
find_new_block_disk() {
  comm -13 "$1" "$2" | while IFS= read -r c; do [ -b "$c" ] && printf '%s\n' "$c" && break; done | head -1
}
rackspace_create_volume_from_image() {
  local image_id="$1" size_gb="$2" vol_name="$3" token base payload resp http body msg
  token="$(refresh_ospc_token || true)"; base="$(rackspace_blockstorage_base)"
  [ -n "$token" ] && [ -n "$base" ] || return 1
  payload="$(IMAGE_ID="$image_id" SIZE_GB="$size_gb" VNAME="$vol_name" python3 - <<'PY'
import json,os; print(json.dumps({"volume":{"display_name":os.environ["VNAME"],"size":int(os.environ["SIZE_GB"]),"imageRef":os.environ["IMAGE_ID"]}},separators=(",",":")))
PY
)"
  resp="$(curl -sS -w '\nHTTP_CODE=%{http_code}\n' -X POST "$base/volumes" -H "X-Auth-Token: $token" -H "Content-Type: application/json" -d "$payload" 2>>"$JOB_LOG/cinder.log" || true)"
  http="$(printf '%s' "$resp" | awk -F= '/HTTP_CODE=/{print $2}' | tail -1)"
  body="$(printf '%s' "$resp" | sed '/^HTTP_CODE=/d')"
  case "$http" in
    200|202) ;;
    *)
      printf '\n[CINDER volume create HTTP=%s]\n%s\n' "${http:-unknown}" "$body" >>"$JOB_LOG/cinder.log" 2>/dev/null || true
      msg="$(printf '%s' "$body" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit
for key in ("badRequest", "forbidden", "itemNotFound", "overLimit", "unauthorized", "computeFault"):
    row = d.get(key) if isinstance(d, dict) else None
    if isinstance(row, dict):
        print(row.get("message") or row.get("details") or "")
        raise SystemExit
print((d.get("message") if isinstance(d, dict) else "") or "")
' 2>/dev/null || true)"
      log "[CINDER] WARN volume create HTTP=${http:-unknown}${msg:+ reason=$msg}" >&2
      return 1
      ;;
  esac
  printf '%s' "$body" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("volume") or {}).get("id",""))' 2>/dev/null
}
rackspace_attach_volume() {
  local server_id="$1" vol_id="$2" token base payload resp http
  token="$(refresh_ospc_token || true)"; base="$(rackspace_compute_base)"
  [ -n "$token" ] && [ -n "$base" ] || return 1
  payload="$(VOL_ID="$vol_id" python3 - <<'PY'
import json,os; print(json.dumps({"volumeAttachment":{"volumeId":os.environ["VOL_ID"]}},separators=(",",":")))
PY
)"
  resp="$(curl -sS -w '\nHTTP_CODE=%{http_code}\n' -X POST "$base/servers/$server_id/os-volume_attachments" -H "X-Auth-Token: $token" -H "Content-Type: application/json" -d "$payload" 2>>"$JOB_LOG/cinder.log" || true)"
  http="$(printf '%s' "$resp" | awk -F= '/HTTP_CODE=/{print $2}' | tail -1)"
  case "$http" in 200|202) return 0 ;; esac
  log "[CINDER] WARN volume attach HTTP=$http"; return 1
}
rackspace_attachment_device() {
  local server_id="$1" vol_id="$2" token base resp
  token="$(refresh_ospc_token || true)"; base="$(rackspace_compute_base)"
  [ -n "$server_id" ] && [ -n "$vol_id" ] && [ -n "$token" ] && [ -n "$base" ] || return 1
  resp="$(curl -sS "$base/servers/$server_id/os-volume_attachments" -H "X-Auth-Token: $token" 2>>"$JOB_LOG/cinder.log" || true)"
  RESP_JSON="$resp" VOL_ID="$vol_id" python3 - <<'PY' 2>/dev/null
import json, os, sys
vol = os.environ.get("VOL_ID")
try:
    doc = json.loads(os.environ.get("RESP_JSON") or "{}")
except Exception:
    raise SystemExit(1)
rows = doc.get("volumeAttachments") or doc.get("volume_attachments") or []
for row in rows:
    if str(row.get("volumeId") or row.get("volume_id") or row.get("id") or "") == vol:
        dev = str(row.get("device") or row.get("mountpoint") or "")
        if dev:
            print(dev)
            raise SystemExit(0)
raise SystemExit(1)
PY
}
resolve_attached_device_for_volume() {
  local server_id="$1" vol_id="$2" api_dev="" dev=""
  api_dev="$(rackspace_attachment_device "$server_id" "$vol_id" | tail -1 | tr -d '\r' || true)"
  if [ -n "$api_dev" ]; then
    for dev in "$api_dev" "/dev/$(basename "$api_dev")"; do
      [ -b "$dev" ] && { printf '%s\n' "$dev"; return 0; }
    done
  fi
  return 1
}
rackspace_detach_volume() {
  local server_id="$1" vol_id="$2" token base
  token="$(refresh_ospc_token || true)"; base="$(rackspace_compute_base)"
  [ -n "$server_id" ] && [ -n "$vol_id" ] && [ -n "$token" ] && [ -n "$base" ] || return 0
  curl -sS -X DELETE "$base/servers/$server_id/os-volume_attachments/$vol_id" -H "X-Auth-Token: $token" -o /dev/null >>"$JOB_LOG/cinder.log" 2>&1 || true
}
rackspace_delete_volume() {
  local vol_id="$1" token base
  token="$(refresh_ospc_token || true)"; base="$(rackspace_blockstorage_base)"
  [ -n "$vol_id" ] && [ -n "$token" ] && [ -n "$base" ] || return 0
  curl -sS -X DELETE "$base/volumes/$vol_id" -H "X-Auth-Token: $token" -o /dev/null >>"$JOB_LOG/cinder.log" 2>&1 || true
}
cinder_create_available_volume_from_image() {
  local image_id="$1" size_gb="$2" name_prefix="$3" source_mb="${4:-0}" phase="${5:-cinder_volume_create}"
  local attempts wait_s attempt volume_name volume_id status
  CINDER_AVAILABLE_VOLUME_ID=""
  attempts="${CINDER_CREATE_ATTEMPTS:-3}"
  wait_s="${CINDER_CREATE_RETRY_WAIT:-45}"
  [ "$attempts" -ge 1 ] 2>/dev/null || attempts=1
  attempt=1
  while [ "$attempt" -le "$attempts" ]; do
    volume_name="${name_prefix}-a${attempt}"
    log "[CINDER] create image-volume attempt $attempt/$attempts: name=$volume_name size=${size_gb}GB"
    volume_id="$(rackspace_create_volume_from_image "$image_id" "$size_gb" "$volume_name" | tr -d '\r' | tail -1)" || volume_id=""
    if [ -z "$volume_id" ]; then
      log "[CINDER] WARN image-volume create request returned no volume id on attempt $attempt/$attempts"
    else
      log "[CINDER] volume=$volume_id — waiting available (attempt $attempt/$attempts)"
      if cinder_wait_volume_status "$volume_id" "available" "$CINDER_CREATE_TIMEOUT" "$phase" "$source_mb" "0"; then
        CINDER_AVAILABLE_VOLUME_ID="$volume_id"
        return 0
      fi
      status="$(rackspace_volume_status "$volume_id" 2>/dev/null || echo unknown)"
      log "[CINDER] WARN image-volume attempt $attempt/$attempts did not become available: volume=$volume_id status=$status"
      log "[CINDER] cleanup: requesting delete for failed temp volume=$volume_id"
      rackspace_delete_volume "$volume_id" || true
    fi
    if [ "$attempt" -lt "$attempts" ]; then
      log "[CINDER] retrying image-volume create after ${wait_s}s with a fresh temp volume"
      sleep "$wait_s"
    fi
    attempt=$((attempt + 1))
  done
  return 1
}
discover_ospc_helper_server_id() {
  local ips_json server_json meta_id
  if [ -n "${OSPC2FLEX_OSPC_HELPER_SERVER_ID:-${OSPC2FLEX_CINDER_HELPER_SERVER_ID:-}}" ]; then
    printf '%s\n' "${OSPC2FLEX_OSPC_HELPER_SERVER_ID:-${OSPC2FLEX_CINDER_HELPER_SERVER_ID:-}}"
    return 0
  fi
  meta_id="$(curl -fsS --connect-timeout 2 --max-time 4 http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || true)"
  if [ -n "$meta_id" ]; then
    printf '%s\n' "$meta_id"
    return 0
  fi
  ips_json="$(
    {
      [ -n "${OSPC2FLEX_JUMPHOST_IP:-}" ] && printf '%s\n' "$OSPC2FLEX_JUMPHOST_IP"
      hostname -I 2>/dev/null | tr ' ' '\n'
    } | awk 'NF' | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))'
  )"
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
discover_remote_ospc_helper() {
  local server_json
  if [ -n "${OSPC2FLEX_REMOTE_OSPC_HELPER_SERVER_ID:-}" ] && [ -n "${OSPC2FLEX_REMOTE_OSPC_HELPER_IP:-}" ]; then
    printf '%s %s\n' "$OSPC2FLEX_REMOTE_OSPC_HELPER_SERVER_ID" "$OSPC2FLEX_REMOTE_OSPC_HELPER_IP"
    return 0
  fi
  server_json="$(openstack server list --long -f json 2>/dev/null || true)"
  SERVER_JSON="$server_json" python3 - <<'PY' 2>/dev/null || true
import json, re, sys
try:
    rows = json.loads(__import__("os").environ.get("SERVER_JSON") or "[]")
except Exception:
    rows = []
for row in rows:
    name = str(row.get("Name") or row.get("name") or "")
    status = str(row.get("Status") or row.get("status") or "").upper()
    if status != "ACTIVE" or not re.search(r"(codex|ospc2flex|linsnap).*helper", name, re.I):
        continue
    blob = json.dumps(row)
    ips = re.findall(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", blob)
    public = [ip for ip in ips if not ip.startswith(("10.", "192.168.", "172.16.", "172.17.", "172.18.", "172.19.", "172.2", "172.30.", "172.31."))]
    ip = (public or ips or [""])[0]
    sid = row.get("ID") or row.get("Id") or row.get("id") or ""
    if sid and ip:
        print(sid, ip)
        raise SystemExit(0)
PY
}
remote_ospc_helper_volume_export() {
  local image_id="$1" dest="$2"
  local helper_line helper_id helper_ip size_gb volume_name volume_id helper_tmp dev dev_size ssh_key_file
  helper_line="$(discover_remote_ospc_helper | head -1 || true)"
  helper_id="$(printf '%s' "$helper_line" | awk '{print $1}')"
  helper_ip="$(printf '%s' "$helper_line" | awk '{print $2}')"
  [ -n "$helper_id" ] && [ -n "$helper_ip" ] || {
    log "[CINDER] FAILED remote helper discovery"
    log "[CINDER] ICF Issue=Cinder fallback needs an OSPC helper VM Cause=jumpshost is not an OSPC server Fix=create/reuse codex-linsnap-helper or set OSPC2FLEX_REMOTE_OSPC_HELPER_SERVER_ID and OSPC2FLEX_REMOTE_OSPC_HELPER_IP"
    return 1
  }
  size_gb="$(apply_cinder_min_volume_size "$(image_cinder_size_gb "$image_id")")"
  source_mb=0
  volume_name="${LABEL_SAFE}-linsnap-remote-cinder-${RUN_ID}"
  helper_tmp="/tmp/ospc2flex_${LABEL_SAFE}_${RUN_ID}.qcow2"
  ssh_key_file="${SSH_KEY_PATH/#\~/$HOME}"
  log "[CINDER] Remote OSPC helper fallback: helper=$helper_id ip=$helper_ip size=${size_gb}GB"

  cinder_create_available_volume_from_image "$image_id" "$size_gb" "$volume_name" "$source_mb" "cinder_volume_create" || {
    log "[CINDER] FAILED remote helper volume create after ${CINDER_CREATE_ATTEMPTS:-3} attempt(s)"
    return 1
  }
  volume_id="$CINDER_AVAILABLE_VOLUME_ID"

  rackspace_attach_volume "$helper_id" "$volume_id" || { rackspace_delete_volume "$volume_id" || true; return 1; }
  cinder_wait_volume_status "$volume_id" "in-use" 900 "cinder_attach" "$source_mb" "0" || {
    rackspace_detach_volume "$helper_id" "$volume_id" || true
    rackspace_delete_volume "$volume_id" || true
    return 1
  }

  dev=""
  for _i in $(seq 1 60); do
    dev="$(rackspace_attachment_device "$helper_id" "$volume_id" | tail -1 | tr -d '\r' || true)"
    if [ -n "$dev" ]; then
      ssh -i "$ssh_key_file" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes -o IdentitiesOnly=yes "ubuntu@$helper_ip" "test -b '$dev'" >/dev/null 2>&1 && break
    fi
    sleep 5
  done
  if [ -z "$dev" ]; then
    dev="$(ssh -i "$ssh_key_file" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes -o IdentitiesOnly=yes "ubuntu@$helper_ip" "lsblk -dnpo NAME,TYPE,SIZE | awk '\$2==\"disk\" && \$1!~/xvda/ && \$3!~/64M/{print \$1; exit}'" 2>/dev/null || true)"
  fi
  [ -n "$dev" ] || {
    log "[CINDER] FAILED remote helper attached device discovery"
    rackspace_detach_volume "$helper_id" "$volume_id" || true
    rackspace_delete_volume "$volume_id" || true
    return 1
  }
  dev_size="$(ssh -i "$ssh_key_file" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes -o IdentitiesOnly=yes "ubuntu@$helper_ip" "sudo blockdev --getsize64 '$dev'" 2>/dev/null || echo 0)"
  log "[CINDER] remote helper device=$dev bytes=$dev_size"
  [ "$dev_size" -gt 1073741824 ] 2>/dev/null || return 1

  ssh -i "$ssh_key_file" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes -o IdentitiesOnly=yes "ubuntu@$helper_ip" \
    "if ! command -v qemu-img >/dev/null 2>&1; then sudo apt-get update -y >/dev/null 2>&1 && sudo apt-get install -y qemu-utils >/dev/null 2>&1; fi; sudo rm -f '$helper_tmp'; sudo qemu-img convert -p -f raw -O qcow2 -c '$dev' '$helper_tmp' && sudo chown ubuntu:ubuntu '$helper_tmp' && qemu-img check '$helper_tmp'" \
    >>"$JOB_LOG/cinder.log" 2>&1 || {
      log "[CINDER] FAILED remote helper qemu-img convert"
      rackspace_detach_volume "$helper_id" "$volume_id" || true
      rackspace_delete_volume "$volume_id" || true
      return 1
    }
  rm -f "$dest"
  scp -i "$ssh_key_file" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes -o IdentitiesOnly=yes "ubuntu@$helper_ip:$helper_tmp" "$dest" >>"$JOB_LOG/cinder.log" 2>&1 || {
    log "[CINDER] FAILED copy from remote helper"
    rackspace_detach_volume "$helper_id" "$volume_id" || true
    rackspace_delete_volume "$volume_id" || true
    return 1
  }
  qemu-img check "$dest" >>"$JOB_LOG/cinder.log" 2>&1 || return 1
  log "[CINDER] HIT remote helper artifact: $dest ($(stat -c%s "$dest" 2>/dev/null || echo 0) bytes)"
  ssh -i "$ssh_key_file" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes -o IdentitiesOnly=yes "ubuntu@$helper_ip" "rm -f '$helper_tmp'" >/dev/null 2>&1 || true
  rackspace_detach_volume "$helper_id" "$volume_id" || true
  cinder_wait_volume_status "$volume_id" "available" 120 || log "[CINDER] WARN temp volume detach still pending; delete requested anyway"
  rackspace_delete_volume "$volume_id" || true
  return 0
}
image_cinder_size_gb() {
  local image_id="$1" meta="$JOB_TMP/cinder_img_meta.json"
  openstack image show "$image_id" -f json >"$meta"
  python3 - "$meta" <<'PY'
import json, math, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
size = int(d.get("size") or 0); min_disk = int(d.get("min_disk") or 0); virtual = int(d.get("virtual_size") or 0)
gb = max(1, min_disk, math.ceil(size/(1024**3)), math.ceil(virtual/(1024**3)) if virtual else 0)
print(gb)
PY
}
image_origin_instance_uuid() {
  local image_id="$1" meta="$JOB_TMP/origin_img_meta.json"
  openstack image show "$image_id" -f json >"$meta" 2>/dev/null || return 1
  python3 - "$meta" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print("")
    raise SystemExit
props = data.get("properties") or {}
if not isinstance(props, dict):
    props = {}
print(props.get("instance_uuid") or data.get("instance_uuid") or "")
PY
}
server_public_ipv4() {
  local server_id="$1" meta="$JOB_TMP/origin_server_meta.json"
  openstack server show "$server_id" -f json >"$meta" 2>/dev/null || return 1
  python3 - "$meta" <<'PY'
import ipaddress, json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    raise SystemExit
def public_v4(value):
    try:
        ip = ipaddress.ip_address(str(value))
    except Exception:
        return ""
    if ip.version == 4 and not ip.is_private:
        return str(ip)
    return ""
for key in ("accessIPv4", "public_v4", "publicIPv4"):
    out = public_v4(data.get(key))
    if out:
        print(out)
        raise SystemExit
addresses = data.get("addresses") or {}
if isinstance(addresses, dict):
    for rows in addresses.values():
        if not isinstance(rows, list):
            rows = [rows]
        for row in rows:
            if isinstance(row, dict):
                candidates = [row.get("addr"), row.get("ip")]
            else:
                candidates = [row]
            for item in candidates:
                out = public_v4(item)
                if out:
                    print(out)
                    raise SystemExit
print("")
PY
}
server_status_value() {
  local server_id="$1"
  openstack server show "$server_id" -f value -c status 2>/dev/null | tr -d '[:space:]'
}
origin_vm_raw_export() {
  local image_id="$1" dest="$2" min_bytes="${3:-1073741824}"
  local origin_id status origin_ip ssh_key_file disk dev_size dev_mb export_log export_pid start_s copied copied_mb pct elapsed_s eta_min rc final_bytes final_mb
  [ "$LIVE_ORIGIN_FALLBACK" = "1" ] || return 1
  origin_id="${OSPC2FLEX_ORIGIN_SERVER_ID:-$(image_origin_instance_uuid "$image_id" | tr -d '[:space:]' || true)}"
  [ -n "$origin_id" ] || { log "[ORIGIN] No source server id found in snapshot metadata"; return 1; }
  status="$(server_status_value "$origin_id" | tr '[:lower:]' '[:upper:]')"
  [ "$status" = "ACTIVE" ] || { log "[ORIGIN] Source server $origin_id is not ACTIVE (status=${status:-unknown})"; return 1; }
  origin_ip="${OSPC2FLEX_ORIGIN_SERVER_IP:-$(server_public_ipv4 "$origin_id" | head -1 | tr -d '[:space:]' || true)}"
  [ -n "$origin_ip" ] || { log "[ORIGIN] No public IPv4 found for source server $origin_id"; return 1; }
  ssh_key_file="${SSH_KEY_PATH/#\~/$HOME}"
  [ -f "$ssh_key_file" ] || { log "[ORIGIN] SSH key not found: $ssh_key_file"; return 1; }
  log "[ORIGIN] Live source VM export fallback: server=$origin_id ip=$origin_ip user=$ORIGIN_SSH_USER"
  disk="$(ssh -i "$ssh_key_file" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=12 -o IdentitiesOnly=yes "$ORIGIN_SSH_USER@$origin_ip" 'for d in /dev/vda /dev/xvda /dev/sda; do [ -b "$d" ] && printf "%s\n" "$d" && exit 0; done; exit 1' 2>/dev/null | head -1 | tr -d '[:space:]' || true)"
  [ -n "$disk" ] || { log "[ORIGIN] Could not detect root disk on source VM"; return 1; }
  dev_size="$(ssh -i "$ssh_key_file" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=12 -o IdentitiesOnly=yes "$ORIGIN_SSH_USER@$origin_ip" "sudo blockdev --getsize64 '$disk'" 2>/dev/null | tr -dc '0-9' || true)"
  [ "${dev_size:-0}" -ge "$min_bytes" ] 2>/dev/null || { log "[ORIGIN] Source disk size invalid: disk=$disk bytes=${dev_size:-0}"; return 1; }
  dev_mb="$(mb_from_bytes "$dev_size")"
  export_log="$JOB_LOG/origin_vm_export.log"
  rm -f "$dest" "$export_log"
  log "[ORIGIN] Streaming source disk $disk ($(fmt_bytes "$dev_size")) to $dest"
  log_download_status "origin_vm_raw_export" "0" "$dev_mb" "starting" "0.0" "unknown" "server=$origin_id disk=$disk"
  set +e
  ssh -i "$ssh_key_file" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=20 -o IdentitiesOnly=yes "$ORIGIN_SSH_USER@$origin_ip" \
    "sudo dd if='$disk' bs=16M status=none" >"$dest" 2>"$export_log" &
  export_pid=$!
  start_s="$(date +%s)"
  while kill -0 "$export_pid" 2>/dev/null; do
    sleep 30
    if kill -0 "$export_pid" 2>/dev/null; then
      copied="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
      copied_mb="$(mb_from_bytes "$copied")"
      pct="$(awk -v c="$copied" -v t="$dev_size" 'BEGIN{if(t>0) printf "%.1f", (c/t)*100; else printf "0.0"}')"
      elapsed_s=$(( $(date +%s) - start_s ))
      eta_min="$(awk -v c="$copied" -v t="$dev_size" -v e="$elapsed_s" 'BEGIN{if(c>0 && e>0 && t>c) printf "%.0f", ((t-c)/(c/e))/60; else if(t>0 && c>=t) printf "0"; else printf "unknown"}')"
      log_download_status "origin_vm_raw_export" "$copied_mb" "$dev_mb" "streaming" "$pct" "$eta_min" "server=$origin_id disk=$disk"
    fi
  done
  wait "$export_pid"; rc=$?
  set -e
  final_bytes="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
  if [ "$rc" -eq 0 ] && [ "$final_bytes" -ge "$min_bytes" ]; then
    final_mb="$(mb_from_bytes "$final_bytes")"
    log_download_status "origin_vm_raw_export" "$final_mb" "$dev_mb" "complete" "100.0" "0" "server=$origin_id disk=$disk"
    log "[ORIGIN] HIT live source raw artifact: $dest (${final_bytes} bytes)"
    return 0
  fi
  log "[ORIGIN] WARN live source export failed rc=$rc size=${final_bytes}B log=$export_log"
  log_file_excerpt "[ORIGIN] export-error:" "$export_log"
  rm -f "$dest"
  return 1
}
image_is_cinder_preferred_snapshot() {
  local image_id="$1" meta="$JOB_TMP/img_meta_export.json"
  openstack image show "$image_id" -f json >"$meta" 2>/dev/null || return 1
  python3 - "$meta" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print("0")
    raise SystemExit
props = d.get("properties") or {}
if not isinstance(props, dict):
    props = {}
flag = str(props.get("com.rackspace__1__options", d.get("com.rackspace__1__options", ""))).strip()
image_type = str(props.get("image_type", d.get("image_type", ""))).strip().lower()
rackspace_managed = any(str(props.get(k, "")).strip() for k in (
    "com.rackspace__1__build_managed",
    "com.rackspace__1__visible_managed",
    "com.rackspace__1__build_config_options",
))
# flag=4 is the classic licensed/export-blocked case.  Rackspace-managed snapshots
# may still use Cinder, but the safer default is Cloud Files first because image-to-volume
# can sit in creating for a long time before failing in Rackspace Cinder.
print("1" if flag == "4" or (image_type == "snapshot" and rackspace_managed) else "0")
PY
}
apply_cinder_min_volume_size() {
  local size_gb="${1:-0}" min_size="${CINDER_MIN_VOLUME_SIZE_GB:-75}"
  if [ "$min_size" -gt 0 ] 2>/dev/null && [ "$size_gb" -lt "$min_size" ] 2>/dev/null; then
    printf '%s\n' "$min_size"
    return 0
  fi
  printf '%s\n' "$size_gb"
}
cinder_volume_raw_export() {
  local image_id="$1" dest="$2"
  local helper_id volume_name volume_id before_file after_file dev dev_size dd_rc source_bytes source_mb volume_mb dev_mb copied copied_mb pct final_bytes final_mb copy_start_ts elapsed_s eta_min
  helper_id="$(discover_ospc_helper_server_id | head -1 | tr -d '[:space:]')"
  [ -n "$helper_id" ] || {
    log "[CINDER] FAILED helper server discovery"
    log "[CINDER] Local jumphost is not an OSPC server; trying remote OSPC helper"
    remote_ospc_helper_volume_export "$image_id" "$dest" && return 0
    log "[CINDER] ICF Issue=Cinder fallback could not identify/use an OSPC helper Cause=metadata/openstack server list did not expose local helper and remote helper failed Fix=reuse codex-linsnap-helper or set OSPC2FLEX_REMOTE_OSPC_HELPER_SERVER_ID/IP"
    return 1
  }
  local size_gb; size_gb="$(apply_cinder_min_volume_size "$(image_cinder_size_gb "$image_id")")"
  source_bytes="$(python3 - "$JOB_TMP/cinder_img_meta.json" <<'PYSIZE'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    data = {}
print(data.get("size") or data.get("Size") or 0)
PYSIZE
)"
  source_mb="$(mb_from_bytes "$source_bytes")"
  volume_mb=$((size_gb * 1024))
  volume_name="${LABEL_SAFE}-linsnap-cinder-${RUN_ID}"
  before_file="$JOB_TMP/cinder_before.txt"; after_file="$JOB_TMP/cinder_after.txt"
  log "[CINDER] Licensed image — Cinder attach fallback: helper=$helper_id size=${size_gb}GB"
  log_download_status "cinder_volume_create" "0" "$source_mb" "starting" "" "" "volume_mb=$volume_mb"
  local_block_disks >"$before_file"
  cinder_create_available_volume_from_image "$image_id" "$size_gb" "$volume_name" "$source_mb" "cinder_volume_create" || {
    log "[CINDER] FAILED volume create after ${CINDER_CREATE_ATTEMPTS:-3} attempt(s)"
    log "[CINDER] ICF Issue=volume stuck creating/error Cause=Rackspace Cinder backend did not finish image-to-volume create Fix=retry later or use START FRESH after failed temp volumes are deleted"
    return 1
  }
  volume_id="$CINDER_AVAILABLE_VOLUME_ID"
  log_download_status "cinder_attach" "0" "$source_mb" "starting"
  rackspace_attach_volume "$helper_id" "$volume_id" || {
    log "[CINDER] FAILED attach temp volume=$volume_id to helper=$helper_id"
    rackspace_delete_volume "$volume_id" || true
    return 1
  }
  cinder_wait_volume_status "$volume_id" "in-use" 900 "cinder_attach" "$source_mb" "0" || {
    log "[CINDER] FAILED temp volume attach wait: volume=$volume_id"
    rackspace_detach_volume "$helper_id" "$volume_id" || true
    rackspace_delete_volume "$volume_id" || true
    return 1
  }
  dev=""
  for _i in $(seq 1 60); do
    sleep 3
    dev="$(resolve_attached_device_for_volume "$helper_id" "$volume_id" || true)"
    [ -n "$dev" ] && break
  done
  if [ -z "$dev" ]; then
    if [ "${OSPC2FLEX_CINDER_ALLOW_DEVICE_HEURISTIC:-0}" = "1" ]; then
      log "[CINDER] WARN could not map volume attachment by volume id; falling back to new-disk detection"
      local_block_disks >"$after_file"
      dev="$(find_new_block_disk "$before_file" "$after_file" || true)"
    else
      log "[CINDER] ERROR could not map volume=$volume_id to an attached block device; refusing unsafe parallel disk guess"
      rackspace_detach_volume "$helper_id" "$volume_id" || true
      rackspace_delete_volume "$volume_id" || true
      return 1
    fi
  fi
  [ -n "$dev" ] || {
    rackspace_detach_volume "$helper_id" "$volume_id" || true
    rackspace_delete_volume "$volume_id" || true
    return 1
  }
  dev_size="$(sudo blockdev --getsize64 "$dev" 2>/dev/null || echo 0)"
  dev_mb="$(mb_from_bytes "$dev_size")"
  log "[CINDER] attached block device for volume=$volume_id: $dev bytes=$dev_size"
  [ "$dev_size" -gt 1073741824 ] || {
    log "[CINDER] FAILED attached device too small/invalid: volume=$volume_id dev=$dev bytes=$dev_size"
    rackspace_detach_volume "$helper_id" "$volume_id" || true
    rackspace_delete_volume "$volume_id" || true
    return 1
  }
  rm -f "$dest"
  log "[CINDER] raw-copying $dev → $dest"
  copy_start_ts="$(date +%s)"
  log_download_status "raw_copy" "0" "$dev_mb" "starting" "0.0" "unknown"
  set +e
  sudo dd if="$dev" of="$dest" bs=64M status=progress conv=noerror,sync >>"$JOB_LOG/cinder.log" 2>&1 &
  dd_pid=$!
  while kill -0 "$dd_pid" 2>/dev/null; do
    sleep 60
    copied="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
    copied_mb="$(mb_from_bytes "$copied")"
    pct="$(awk -v c="$copied" -v t="$dev_size" 'BEGIN{if(t>0)printf "%.1f", (c/t)*100; else printf "0.0"}')"
    elapsed_s=$(( $(date +%s) - copy_start_ts ))
    eta_min="$(awk -v c="$copied" -v t="$dev_size" -v e="$elapsed_s" 'BEGIN{if(c>0 && e>0 && t>c) printf "%.0f", ((t-c)/(c/e))/60; else if(t>0 && c>=t) printf "0"; else printf "unknown"}')"
    log "[CINDER] copy progress: ${copied_mb}MB / ${dev_mb}MB (${pct}%), eta=${eta_min}min"
    log_download_status "raw_copy" "$copied_mb" "$dev_mb" "copying" "$pct" "$eta_min"
  done
  wait "$dd_pid"; dd_rc=$?
  set -e
  [ "$dd_rc" -eq 0 ] || {
    log "[CINDER] FAILED raw copy from temp volume=$volume_id rc=$dd_rc"
    rackspace_detach_volume "$helper_id" "$volume_id" || true
    rackspace_delete_volume "$volume_id" || true
    return 1
  }
  sudo chown "$(id -u):$(id -g)" "$dest" 2>/dev/null || true
  final_bytes="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
  final_mb="$(mb_from_bytes "$final_bytes")"
  log_download_status "raw_copy" "$final_mb" "$dev_mb" "complete" "100.0" "0"
  log "[CINDER] HIT raw artifact: $dest (${final_bytes} bytes)"
  rackspace_detach_volume "$helper_id" "$volume_id"
  cinder_wait_volume_status "$volume_id" "available" 900 || true
  rackspace_delete_volume "$volume_id"
  return 0
}

recreate_source_snapshot() {
  # Create a brand-new Glance snapshot from the source VM and put its id in RECREATED_IMAGE_ID.
  # Returns 0 on success; non-zero (with a clear reason logged) if recreation isn't possible.
  RECREATED_IMAGE_ID=""
  local orig_image_id="$1" src_id status new_name new_id waited
  src_id="${SOURCE_SERVER_ID:-$(image_origin_instance_uuid "$orig_image_id" | tr -d '[:space:]' || true)}"
  if [ -z "$src_id" ]; then
    log "[RECREATE] Cannot recreate: no source server id (image metadata has no instance_uuid and OSPC2FLEX_SOURCE_SERVER_ID unset). Using existing image."
    return 1
  fi
  status="$(server_status_value "$src_id" 2>/dev/null | tr '[:lower:]' '[:upper:]' || true)"
  if [ "$status" != "ACTIVE" ]; then
    log "[RECREATE] Cannot recreate: source server $src_id is not ACTIVE (status=${status:-unknown}). Using existing image."
    return 1
  fi
  new_name="${LABEL_SAFE}-fresh-${RUN_ID}"
  log "[RECREATE] NO IMAGE RESUME: creating a fresh snapshot from source server $src_id (name=$new_name)"
  new_id="$(openstack server image create --name "$new_name" --wait -f value -c id "$src_id" 2>>"$JOB_LOG/recreate.log" | tr -d '[:space:]' || true)"
  if [ -z "$new_id" ]; then
    new_id="$(openstack image list --name "$new_name" -f value -c ID 2>/dev/null | head -1 | tr -d '[:space:]' || true)"
  fi
  if [ -z "$new_id" ]; then
    log "[RECREATE] Failed to create a fresh snapshot from $src_id (see $JOB_LOG/recreate.log). Using existing image."
    return 1
  fi
  waited=0
  while :; do
    status="$(openstack image show "$new_id" -f value -c status 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]' || true)"
    [ "$status" = "active" ] && break
    if [ "$waited" -ge "$RECREATE_IMAGE_TIMEOUT" ]; then
      log "[RECREATE] New image $new_id did not reach ACTIVE within ${RECREATE_IMAGE_TIMEOUT}s (status=${status:-unknown}). Using existing image."
      return 1
    fi
    sleep 15; waited=$((waited+15))
    log "[RECREATE] Waiting for fresh image $new_id to become ACTIVE (status=${status:-queued} elapsed=${waited}s)"
  done
  RECREATED_IMAGE_ID="$new_id"
  log "[RECREATE] Fresh snapshot ready: image=$new_id (from source server $src_id)"
  return 0
}
download_existing_ospc_snapshot() {
  local image_id="$1" dest="$2" min_bytes=1073741824 tmp_log token attempt base host base_i direct_blocked=0
  if [ "$RECREATE_IMAGE_ON_NO_RESUME" = "1" ]; then
    if recreate_source_snapshot "$image_id"; then
      log "[ZS3] Using freshly recreated image ${RECREATED_IMAGE_ID} in place of ${image_id}"
      image_id="$RECREATED_IMAGE_ID"
    else
      log "[ZS3] Recreation not available — proceeding with existing image $image_id"
    fi
  fi
  log "[ZS3] Download waterfall for image=$image_id"
  if [ "$LIVE_ORIGIN_EXPORT_FIRST" = "1" ]; then
    log "[ZS3] Live-origin export requested first"
    origin_vm_raw_export "$image_id" "$dest" "$min_bytes" && return 0
    log "[ZS3] Live-origin export-first failed — continuing waterfall"
  fi
  if [ "$CINDER_VOLUME_EXPORT_ON_LICENSED" = "1" ] && [ "$PREFER_CINDER_FOR_RACKSPACE_SNAPSHOT" = "1" ] && [ "$(image_is_cinder_preferred_snapshot "$image_id" || echo 0)" = "1" ]; then
    log "[ZS3] Rackspace-managed snapshot — using Cinder fallback first; set OSPC2FLEX_PREFER_CINDER_FOR_RACKSPACE_SNAPSHOT=0 to try Cloud Files first"
    OSPC2FLEX_CINDER_FALLBACK_ALREADY_TRIED=1
    cinder_volume_raw_export "$image_id" "$dest" && return 0
    log "[ZS3] Cinder-first export failed. Not retrying the same Cinder path in this run."
    origin_vm_raw_export "$image_id" "$dest" "$min_bytes" && return 0
    if [ "$USE_CLOUD_FILES_EXPORT" != "1" ]; then
      log "[ZS3] Enabling Cloud Files export automatically because Cinder image-to-volume did not become available"
      USE_CLOUD_FILES_EXPORT=1
    fi
    log "[ZS3] Trying Cloud Files export next"
  fi
  if [ "${OSPC2FLEX_ALLOW_LEGACY_GLANCE_DOWNLOAD:-0}" = "1" ]; then
    log "[ZS3] Legacy direct Glance retry enabled by OSPC2FLEX_ALLOW_LEGACY_GLANCE_DOWNLOAD=1"
    log "[ZS3] Glance endpoints:"; image_bases | sed 's/^/  - /' | while IFS= read -r l; do log "$l"; done
    token="$(refresh_ospc_token || true)"
    attempt=1
    while [ "$attempt" -le "$EXPORT_RETRIES" ]; do
      log "[ZS3] Direct Glance attempt $attempt/$EXPORT_RETRIES"
      tmp_log="$JOB_LOG/image_save_default_a${attempt}.log"
      download_openstack_save "" "$image_id" "$dest" "$min_bytes" "$tmp_log" && return 0
      is_terminal_direct_download_block "$tmp_log" && { direct_blocked=1; log "[ZS3] terminal block — skipping direct retries"; break; }
      base_i=0
      while IFS= read -r base; do
        [ -n "$base" ] || continue; base_i=$((base_i+1))
        host="$(url_host "$base")"
        host_resolves "$host" || { log "[ZS3] WARN unresolved host: $host"; continue; }
        tmp_log="$JOB_LOG/image_save_a${attempt}_b${base_i}.log"
        download_openstack_save "$base" "$image_id" "$dest" "$min_bytes" "$tmp_log" && return 0
        is_terminal_direct_download_block "$tmp_log" && { direct_blocked=1; break; }
        token="$(refresh_ospc_token || printf '%s' "$token")"
        if [ -n "$token" ]; then
          tmp_log="$JOB_LOG/curl_a${attempt}_b${base_i}.log"
          download_curl_glance "$base" "$image_id" "$dest" "$min_bytes" "$token" "$tmp_log" && return 0
          is_terminal_direct_download_block "$tmp_log" && { direct_blocked=1; break; }
        fi
      done < <(image_bases)
      [ "$direct_blocked" = "1" ] && break
      [ "$attempt" -lt "$EXPORT_RETRIES" ] && sleep "$EXPORT_RETRY_WAIT"
      token="$(refresh_ospc_token || printf '%s' "$token")"
      attempt=$((attempt+1))
    done
  else
    log "[ZS3] Skipping legacy direct Glance retry; using Cloud Files then Cinder fallback"
  fi
  if [ -n "$CLOUD_FILES_CONTAINER" ] && [ -n "$CLOUD_FILES_OBJECT" ]; then
    log "[ZS3] Explicit Cloud Files object provided: $CLOUD_FILES_CONTAINER/$CLOUD_FILES_OBJECT"
    if command -v openstack >/dev/null 2>&1; then
      tmp_log="$JOB_LOG/cloud_files_object_save.log"
      rm -f "$dest"
      if openstack object save "$CLOUD_FILES_CONTAINER" "$CLOUD_FILES_OBJECT" --file "$dest" >"$tmp_log" 2>&1 && [ "$(stat -c%s "$dest" 2>/dev/null || echo 0)" -ge "$min_bytes" ]; then
        log "[ZS3] HIT Cloud Files object downloaded"
        return 0
      fi
      log "[ZS3] WARN Cloud Files object download failed log=$tmp_log"
      log_file_excerpt "[ZS3] cloud-files-error:" "$tmp_log"
    elif command -v swift >/dev/null 2>&1; then
      tmp_log="$JOB_LOG/swift_download.log"
      rm -f "$dest"
      if swift download "$CLOUD_FILES_CONTAINER" "$CLOUD_FILES_OBJECT" --output "$dest" >"$tmp_log" 2>&1 && [ "$(stat -c%s "$dest" 2>/dev/null || echo 0)" -ge "$min_bytes" ]; then
        log "[ZS3] HIT Cloud Files object downloaded via swift"
        return 0
      fi
      log_file_excerpt "[ZS3] swift-error:" "$tmp_log"
    fi
  fi

  if [ "$USE_CLOUD_FILES_EXPORT" = "1" ]; then
    set +e; download_cloud_files_export_task "$image_id" "$dest" "${CLOUD_FILES_CONTAINER:-ospc2flex-export}" "$min_bytes"; local cf_rc=$?; set -e
    [ "$cf_rc" -eq 0 ] && return 0
    log "[ZS3] CF export failed — trying Cinder volume fallback"
  else
    log "[ZS3] Skipping Cloud Files export task. Set OSPC2FLEX_USE_CLOUD_FILES_EXPORT=1 to enable Cloud Files."
  fi
  if [ "${OSPC2FLEX_CINDER_FALLBACK_ALREADY_TRIED:-0}" = "1" ]; then
    log "[ZS3] Cinder fallback already failed once in this run; stopping to avoid duplicate stuck temp volumes."
    origin_vm_raw_export "$image_id" "$dest" "$min_bytes" && return 0
    return 1
  fi
  local _cinder_fail_dir _cinder_fail_marker
  _cinder_fail_dir="$BASE_DIR/cache/cinder_failures"
  _cinder_fail_marker="$_cinder_fail_dir/${image_id}.failed"
  if [ -s "$_cinder_fail_marker" ] && [ "${OSPC2FLEX_RETRY_FAILED_CINDER:-0}" != "1" ]; then
    log "[ZS3] Skipping Cinder fallback — previous Cinder attempt failed for image=$image_id ($(head -1 "$_cinder_fail_marker" 2>/dev/null))"
    log "[ZS3] Set OSPC2FLEX_RETRY_FAILED_CINDER=1 to force a new Cinder attempt. Falling through to origin VM export."
    origin_vm_raw_export "$image_id" "$dest" "$min_bytes" && return 0
    return 1
  fi
  OSPC2FLEX_CINDER_FALLBACK_ALREADY_TRIED=1 cinder_volume_raw_export "$image_id" "$dest" && return 0
  mkdir -p "$_cinder_fail_dir" 2>/dev/null || true
  printf 'cinder_failed image=%s ts=%s\n' "$image_id" "$(date -u +%Y%m%dT%H%M%SZ)" >"$_cinder_fail_marker" 2>/dev/null || true
  log "[ZS3] Cinder failure cached for image=$image_id — next run will skip Cinder and go straight to origin VM export"
  origin_vm_raw_export "$image_id" "$dest" "$min_bytes" && return 0
  return 1
}

# ── Resume: find existing qcow2 across all run dirs ───────────────────────────
find_resume_qcow2() {
  [ "$START_FRESH" = "1" ] && return 1
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    qemu-img info "$p" >/dev/null 2>&1 || continue
    qemu-img check "$p" >/dev/null 2>&1 || continue
    printf '%s\n' "$p"
    return 0
  done < <(find "$BASE_DIR/runs/$LABEL_SAFE" -type f -name "*.qcow2" -size +64k -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr | awk '{$1=""; sub(/^ /,""); print}')
  return 1
}

# ── FLEX helpers (mig_worker_v4 verbatim) ────────────────────────────────────
detect_virtual_size_bytes() {
  command -v qemu-img >/dev/null 2>&1 || { echo 0; return 0; }
  qemu-img info --output json "$1" 2>/dev/null | python3 -c 'import json,sys; print(int(json.load(sys.stdin).get("virtual-size") or 0))' 2>/dev/null || echo 0
}
infer_image_os_family() {
  case "${OS_TYPE,,}" in win*|windows*) echo "windows" ;; *) echo "linux" ;; esac
}
infer_image_os_distro() {
  case "${OS_TYPE,,}" in
    ubuntu24*|ubuntu22*|ubuntu20*|ubuntu*) echo "ubuntu" ;;
    debian*) echo "debian" ;;
    rocky*) echo "rocky" ;;
    alma*|almalinux*) echo "almalinux" ;;
    centos*) echo "centos" ;;
    rhel*|redhat*) echo "rhel" ;;
    *) echo "" ;;
  esac
}
normalize_int() { printf '%s' "${1:-}" | tr -cd '0-9'; }
resolve_target_flavor() {
  local req="$1" min_disk_gb="${2:-0}" req_disk
  if [ -n "$req" ] && openstack flavor show "$req" >/dev/null 2>&1; then
    req_disk="$(openstack flavor show "$req" -f json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(int(d.get("disk") or d.get("Disk") or 0))' 2>/dev/null || echo 0)"
    if [ "${min_disk_gb:-0}" -le 0 ] || [ "${req_disk:-0}" -ge "$min_disk_gb" ]; then
      echo "$req"
      return 0
    fi
    echo "  Requested flavor $req rejected: root disk ${req_disk}GB is smaller than image virtual size ${min_disk_gb}GB" >&2
  fi
  local rows _rows_fit _fallback _chosen _cid _cname
  rows="$(openstack flavor list --long --format value -c ID -c Name -c RAM -c Disk -c VCPUs 2>/dev/null || true)"
  [ -z "$rows" ] && { echo "$req"; return 0; }
  _rows_fit="$(printf '%s\n' "$rows" | awk -v min="${min_disk_gb:-0}" 'NF>=5 && ($4+0) > 0 && ($4+0) >= min')"
  [ -n "$_rows_fit" ] && rows="$_rows_fit"
  if [ "${min_disk_gb:-0}" -gt 0 ] && [ -z "$_rows_fit" ]; then
    echo "  No flavor with root disk >= ${min_disk_gb}GB found" >&2
    echo ""
    return 1
  fi
  _fallback="$(printf '%s\n' "$rows" | awk 'NF>=5{id=$1;name=$2;ram=$3+0;disk=$4+0;vcpu=$5+0;score=(disk*1000000000)+(vcpu*1000000)+ram;if(!seen||score<best){seen=1;best=score;out=id"|"name}}END{if(seen)print out}')"
  _chosen="${_fallback}"; _cid="$(echo "$_chosen" | cut -d'|' -f1)"; _cname="$(echo "$_chosen" | cut -d'|' -f2)"
  [ -n "$_cid" ] && { echo "  Flavor auto-pick: $_cid ($_cname)" >&2; echo "$_cid"; return 0; }
  echo "$req"
}
resolve_target_network() {
  local req="$1"
  [ -n "$req" ] && openstack network show "$req" >/dev/null 2>&1 && { echo "$req"; return 0; }
  local pick
  pick="$(openstack network list --format value -c ID -c Name 2>/dev/null | awk 'tolower($2)~/(private|tenant|internal)/{print $1;exit}')"
  [ -z "$pick" ] && pick="$(openstack network list --format value -c ID 2>/dev/null | awk 'NF>=1{print $1;exit}')"
  [ -n "$pick" ] && { echo "  Network auto-pick: $pick" >&2; echo "$pick"; return 0; }
  echo "$req"
}
resolve_target_keypair() {
  local req="$1"
  [ -n "$req" ] && openstack keypair show "$req" >/dev/null 2>&1 && { echo "$req"; return 0; }
  local pick
  pick="$(openstack keypair list --format value -c Name 2>/dev/null | awk 'NF>=1{print $1;exit}')"
  [ -n "$pick" ] && { echo "  Keypair auto-pick: $pick" >&2; echo "$pick"; return 0; }
  echo ""
}

# ════════════════════════════════════════════════════════════════════════════
# ── MAIN PIPELINE ────────────────────────────────────────────────────────────
# ════════════════════════════════════════════════════════════════════════════

stage "LS0_PREFLIGHT"
log "label=$LABEL_SAFE job_id=$JOB_ID run_id=$RUN_ID"
log "ospc_openrc=$OSPC_OPENRC flex_openrc=$FLEX_OPENRC"
log "os_type=${OS_TYPE:-auto} flex_user=$FLEX_USER"
log "base_dir=$BASE_DIR"

stage "LS0A_CLEAN_STALE_IMAGES"
cleanup_stale_jumphost_images
start_fresh_clear_label_resume
require_workspace_min_free_gb "$BASE_DIR" "$WORKSPACE_MIN_FREE_GB" "linux snapshot migration preflight after stale cleanup"
install_if_missing qemu-img qemu-nbd python3 openstack curl

stage "LS1_LOAD_CREDENTIALS"
source_ospc_openrc
log "OSPC region=${OS_REGION_NAME:-?} user=${OS_USERNAME:-?} tenant=$(ospc_tenant_id)"
log "LS1 OK"

stage "LS2_SELECT_SNAPSHOT"
if [ -z "$OSPC_IMAGE_ID" ]; then
  log "Looking up image by name: $LABEL"
  OSPC_IMAGE_ID="$(openstack image show "$LABEL" -f value -c id 2>/dev/null | tr -d '\r' | head -1 || true)"
  [ -n "$OSPC_IMAGE_ID" ] || fail_exit "LS2_SELECT_SNAPSHOT" "Could not find OSPC image '$LABEL' — pass --ospc-image-id explicitly"
fi
log "OSPC image ID: $OSPC_IMAGE_ID"

# ── LS3: Resume check + Download ─────────────────────────────────────────────
stage "LS3_DOWNLOAD_SNAPSHOT"
RESUME_QCOW="$(find_resume_qcow2 || true)"
if [ -n "$RESUME_QCOW" ] && [ -f "$RESUME_QCOW" ]; then
  sz="$(stat -c%s "$RESUME_QCOW" 2>/dev/null || echo 0)"
  log "[LS3] HIT resume artifact found: $RESUME_QCOW ($sz bytes) — skipping download"
  QCOW="$RESUME_QCOW"
  REPAIR_MARKER="${QCOW}.linux_repaired"
  REPAIR_LOG="${QCOW%.qcow2}.repair.log"
else
  RESUME_RAW=""
  if [ "$START_FRESH" != "1" ]; then
    RESUME_RAW="$(find "$BASE_DIR/runs/$LABEL_SAFE" -type f -name "source_snapshot.img" -size +1G -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk '{$1=""; sub(/^ /,""); print; exit}')"
  fi
  if [ -n "$RESUME_RAW" ] && [ -f "$RESUME_RAW" ]; then
    log "[LS3] HIT resume raw img found: $RESUME_RAW — skipping download"
    SOURCE_RAW="$RESUME_RAW"
  else
    log "[LS3] No valid resume artifact — downloading from OSPC"
    SOURCE_RAW="$JOB_ART/source_snapshot.img"
    download_existing_ospc_snapshot "$OSPC_IMAGE_ID" "$SOURCE_RAW" \
      || fail_exit "LS3_DOWNLOAD_SNAPSHOT" "All download strategies failed. Check $JOB_LOG for details."
  fi
  sz="$(stat -c%s "$SOURCE_RAW" 2>/dev/null || echo 0)"
  log "[LS3] HIT downloaded: $SOURCE_RAW ($sz bytes)"
  if [ "${sz:-0}" -gt 0 ]; then
    require_workspace_free_bytes "$BASE_DIR" "$((sz + $(gib_to_bytes "$WORKSPACE_CONVERT_BUFFER_GB")))" "qcow2 normalize workspace for downloaded source"
  fi
fi

# ── LS4: Normalize to qcow2 ──────────────────────────────────────────────────
stage "LS4_NORMALIZE_QCOW2"
if [ -f "$QCOW" ] && [ "$(stat -c%s "$QCOW" 2>/dev/null || echo 0)" -gt 65536 ]; then
  log "[LS4] qcow2 already present: $QCOW — skipping convert"
else
  SOURCE_RAW="${SOURCE_RAW:-$JOB_ART/source_snapshot.img}"
  FMT="$(qemu-img info --output=json "$SOURCE_RAW" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("format","raw"))' 2>/dev/null || echo raw)"
  log "[LS4] Converting $SOURCE_RAW (format=$FMT) → $QCOW"
  rm -f "$QCOW"
  run_qemu_convert_with_progress "qcow2_normalize" "$SOURCE_RAW" "$FMT" "$QCOW" "$JOB_LOG/qemu_convert.log" \
    || fail_exit "LS4_NORMALIZE_QCOW2" "qemu-img convert failed — check disk space; see $JOB_LOG/qemu_convert.log"
  sz="$(stat -c%s "$QCOW" 2>/dev/null || echo 0)"
  log "[LS4] HIT qcow2: $QCOW ($sz bytes)"
  if [ "$KEEP_RAW_AFTER_QCOW" != "1" ] && [ -n "${SOURCE_RAW:-}" ] && [ "$SOURCE_RAW" != "$QCOW" ] && [ -f "$SOURCE_RAW" ]; then
    log "[LS4] Removing raw source artifact after successful qcow2 normalize to preserve jumphost space: $SOURCE_RAW"
    rm -f -- "$SOURCE_RAW"
  fi
fi
[ -f "$QCOW" ] || fail_exit "LS4_NORMALIZE_QCOW2" "qcow2 not found after normalize step"

[ "$DOWNLOAD_ONLY" = "1" ] && { log "DOWNLOAD_ONLY=1 — stopping after LS4"; exit 0; }

# ── LS5: Offline repair (mig_worker_v4 Step 4 — verbatim) ────────────────────
stage "LS5_OFFLINE_REPAIR"
REPAIR_SCRIPT=/tmp/ospc2flex_offline_repair.sh
if [ -f "$REPAIR_MARKER" ]; then
  log "[LS5] Repair marker found: $REPAIR_MARKER — skipping repair (resume)"
else
  if [ -f "$REPAIR_SCRIPT" ]; then
    if [ -z "${OS_TYPE:-}" ]; then
      log "[LS5] WARN OS_TYPE not set — repair script will auto-detect"
    fi
    log "[LS5] Running: $REPAIR_SCRIPT --qcow2 $QCOW --os-type ${OS_TYPE:-} --force"
    rm -f "$REPAIR_LOG"
    sudo modprobe nbd max_part=8 2>/dev/null || true
    set +eo pipefail
    if [ -n "${OS_TYPE:-}" ]; then
      bash "$REPAIR_SCRIPT" --qcow2 "$QCOW" --os-type "$OS_TYPE" --force 2>&1 | tee "$REPAIR_LOG"
    else
      bash "$REPAIR_SCRIPT" --qcow2 "$QCOW" --force 2>&1 | tee "$REPAIR_LOG"
    fi
    REPAIR_EXIT="${PIPESTATUS[0]}"
    set -eo pipefail
    if [ "$REPAIR_EXIT" -eq 0 ]; then
      log "[LS5] ospc2flex_offline_repair.sh completed successfully"
    else
      log "[LS5] ERROR repair exit=$REPAIR_EXIT"
      if [ "${OSPC2FLEX_ALLOW_FAILED_REPAIR_UPLOAD:-0}" = "1" ]; then
        log "[LS5] Override OSPC2FLEX_ALLOW_FAILED_REPAIR_UPLOAD=1 set — continuing by request"
      else
        fail_exit "LS5_OFFLINE_REPAIR" "Offline repair failed; refusing to upload a possibly broken image"
      fi
    fi
    # CentOS/RHEL LAN markers — warn-only, same relaxed approach as alma9
    case "${OS_TYPE,,}" in
      centos*|rhel7*|rhel6*)
        if [ -f "$REPAIR_LOG" ] \
           && grep -q "Wrote fresh ifcfg-eth0 (no HWADDR, ONBOOT=yes, DHCP, NM_CONTROLLED=no)" "$REPAIR_LOG" \
           && grep -q "Enabled network.service" "$REPAIR_LOG"; then
          log "[LS5] PASS — CentOS/RHEL LAN repair markers present"
        else
          log "[LS5] WARN [REPAIR-LAN-W5] CentOS/RHEL LAN repair markers not confirmed — continuing (alma9-style, no hard fail)"
        fi ;;
    esac
    sudo qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
  else
    log "[LS5] WARN $REPAIR_SCRIPT not found — running minimal inline repair"
    sudo qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
    sudo modprobe nbd max_part=8 2>/dev/null || true
    sudo qemu-nbd --connect="$NBD_DEV" "$QCOW"; sleep 3
    ROOT_PART="$(sudo fdisk -l "$NBD_DEV" 2>/dev/null | awk '/Linux filesystem/{print $1; exit}')"
    [ -n "$ROOT_PART" ] || ROOT_PART="${NBD_DEV}p1"
    log "[LS5] minimal: root=$ROOT_PART"
    FS_TYPE="$(sudo blkid -o value -s TYPE "$ROOT_PART" 2>/dev/null || echo ext4)"
    [ "$FS_TYPE" = "xfs" ] && sudo xfs_repair -L "$ROOT_PART" >/dev/null 2>&1 || true \
      || sudo fsck -y -f "$ROOT_PART" >/dev/null 2>&1 || true
    MNT_TMP="/tmp/linsnap_mnt_$$"; sudo mkdir -p "$MNT_TMP"
    if sudo mount "$ROOT_PART" "$MNT_TMP" 2>/dev/null || sudo mount -o norecovery "$ROOT_PART" "$MNT_TMP" 2>/dev/null; then
      sudo test -f "$MNT_TMP/etc/fstab" && { sudo cp "$MNT_TMP/etc/fstab" "$MNT_TMP/etc/fstab.orig" 2>/dev/null || true; sudo sed -i '/^[[:space:]]*#/b;/^[[:space:]]*$/b;/LABEL=/b;/UUID=/b;/PARTUUID=/b;s/^/# [flex] /' "$MNT_TMP/etc/fstab"; } || true
      sudo rm -rf "$MNT_TMP/var/lib/cloud/instance" "$MNT_TMP/var/lib/cloud/instances/"* 2>/dev/null || true
      printf '' | sudo tee "$MNT_TMP/etc/machine-id" >/dev/null
      sudo rm -f "$MNT_TMP/var/lib/dbus/machine-id" "$MNT_TMP/etc/udev/rules.d/70-persistent-net.rules" 2>/dev/null || true
      log "[LS5] minimal: fstab + cloud-init + machine-id cleaned"
      sudo umount "$MNT_TMP" 2>/dev/null || true
    fi
    sudo qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
    sudo rm -rf "$MNT_TMP"
  fi
  echo "LINUX_SNAP_REPAIR_VERSION=$REPAIR_VERSION" >"$REPAIR_MARKER"
  log "[LS5] Repair marker written: $REPAIR_MARKER"
fi

# ── LS6: Upload to FLEX Glance (mig_worker_v4 Step 5 — verbatim) ─────────────
stage "LS6_UPLOAD_FLEX"
source_flex_openrc
log "FLEX region=${OS_REGION_NAME:-?} user=${OS_USERNAME:-?}"
openstack token issue >/dev/null 2>&1 || fail_exit "LS6_UPLOAD_FLEX" "FLEX authentication failed"

QCOW_BYTES="$(stat -c%s "$QCOW" 2>/dev/null || echo 0)"
QCOW_MIB="$((QCOW_BYTES / 1024 / 1024))"
QCOW_VIRTUAL_BYTES="$(detect_virtual_size_bytes "$QCOW")"
QCOW_VIRTUAL_GIB=0
[ "$QCOW_VIRTUAL_BYTES" -gt 0 ] 2>/dev/null && QCOW_VIRTUAL_GIB=$(( (QCOW_VIRTUAL_BYTES + 1073741823) / 1073741824 ))
IMG_NAME="${LABEL_SAFE}-linsnap-flex"
IMG_OS_FAMILY="$(infer_image_os_family)"
IMG_OS_DISTRO="$(infer_image_os_distro)"
kv "Image name"    "$IMG_NAME"
kv "Source qcow2"  "$QCOW"
kv "File size"     "${QCOW_BYTES}B (${QCOW_MIB} MiB)"
kv "Virtual size"  "~${QCOW_VIRTUAL_GIB} GiB"
kv "os_family"     "$IMG_OS_FAMILY / distro=${IMG_OS_DISTRO:-unset}"

IMG_DISK_BUS="virtio"
IMG_VIF_MODEL="virtio"
IMG_QGA="yes"
if printf '%s\n%s\n' "${OS_TYPE:-}" "$(cat "$REPAIR_LOG" 2>/dev/null || true)" \
   | grep -Eiq 'centos[[:space:]-]*5|"major_version"[[:space:]]*:[[:space:]]*5|CentOS release 5'; then
  IMG_DISK_BUS="ide"
  IMG_VIF_MODEL="e1000"
  IMG_QGA="no"
  log "[LS6] CentOS 5 compatibility image properties: hw_disk_bus=$IMG_DISK_BUS hw_vif_model=$IMG_VIF_MODEL hw_qemu_guest_agent=$IMG_QGA"
fi

IMAGE_CREATE_ARGS=(
  --disk-format qcow2 --container-format bare --file "$QCOW" --private
  --property "architecture=x86_64"
  --property "vm_mode=hvm"
  --property "os_type=$IMG_OS_FAMILY"
  --property "hw_disk_bus=$IMG_DISK_BUS"
  --property "hw_vif_model=$IMG_VIF_MODEL"
  --property "hw_qemu_guest_agent=$IMG_QGA"
)
[ -n "$IMG_OS_DISTRO" ] && IMAGE_CREATE_ARGS+=(--property "os_distro=$IMG_OS_DISTRO")

NEW_ID=""
for _up_try in 1 2 3; do
  UPLOAD_OUT="$JOB_TMP/flex_glance_upload_${_up_try}.out"
  UPLOAD_ERR="$JOB_TMP/flex_glance_upload_${_up_try}.err"
  : >"$UPLOAD_OUT"
  : >"$UPLOAD_ERR"
  log "  [UPLOAD $_up_try/3] starting..."
  log_upload_status "flex_glance_upload" "0" "$QCOW_MIB" "starting" "0.0" "unknown" "attempt=$_up_try image=$IMG_NAME"
  set +e
  openstack image create --format value -c id "${IMAGE_CREATE_ARGS[@]}" "$IMG_NAME" >"$UPLOAD_OUT" 2>"$UPLOAD_ERR" &
  UPLOAD_PID="$!"
  UPLOAD_START="$(date +%s)"
  while kill -0 "$UPLOAD_PID" 2>/dev/null; do
    sleep 15
    kill -0 "$UPLOAD_PID" 2>/dev/null || break
    UPLOAD_BYTES="$(proc_io_bytes "$UPLOAD_PID")"
    [ "${UPLOAD_BYTES:-0}" -gt "$QCOW_BYTES" ] 2>/dev/null && UPLOAD_BYTES="$QCOW_BYTES"
    UPLOAD_MB="$(mb_from_bytes "$UPLOAD_BYTES")"
    UPLOAD_PCT="$(awk -v d="${UPLOAD_BYTES:-0}" -v t="$QCOW_BYTES" 'BEGIN{if(t>0){p=(d/t)*100; if(p>99)p=99; printf "%.1f", p}else printf "0.0"}')"
    UPLOAD_ELAPSED="$(( $(date +%s) - UPLOAD_START ))"
    UPLOAD_ETA="$(awk -v d="${UPLOAD_BYTES:-0}" -v t="$QCOW_BYTES" -v e="$UPLOAD_ELAPSED" 'BEGIN{if(d>0 && e>0 && t>d){eta=((t-d)/(d/e))/60; printf "%.0f", eta}else printf "unknown"}')"
    log_upload_status "flex_glance_upload" "$UPLOAD_MB" "$QCOW_MIB" "uploading" "$UPLOAD_PCT" "$UPLOAD_ETA" "attempt=$_up_try pid=$UPLOAD_PID image=$IMG_NAME"
  done
  wait "$UPLOAD_PID"
  UPLOAD_RC="$?"
  set -e
  [ -s "$UPLOAD_ERR" ] && cat "$UPLOAD_ERR" >>"$BACKGROUND_LOG" 2>/dev/null || true
  NEW_ID="$(awk 'NF{print $1; exit}' "$UPLOAD_OUT" 2>/dev/null | tr -d '\r')"
  if [ "$UPLOAD_RC" -ne 0 ]; then
    log_upload_status "flex_glance_upload" "$(mb_from_bytes "$QCOW_BYTES")" "$QCOW_MIB" "failed" "100.0" "0" "attempt=$_up_try rc=$UPLOAD_RC image=$IMG_NAME"
    log "  [WARN] upload attempt $_up_try failed rc=$UPLOAD_RC"
    [ -s "$UPLOAD_ERR" ] && tail -n 12 "$UPLOAD_ERR" | while IFS= read -r _upload_err_line; do log "  [UPLOAD_ERR] $_upload_err_line"; done
    [ "$_up_try" -lt 3 ] && sleep 20
    continue
  fi
  if [ -n "$NEW_ID" ]; then
    log_upload_status "flex_glance_upload" "$QCOW_MIB" "$QCOW_MIB" "submitted" "100.0" "0" "attempt=$_up_try image_id=$NEW_ID image=$IMG_NAME"
    log "  [UPLOAD $_up_try/3] image id: $NEW_ID"
    break
  fi
  log_upload_status "flex_glance_upload" "$(mb_from_bytes "$QCOW_BYTES")" "$QCOW_MIB" "failed" "100.0" "0" "attempt=$_up_try rc=0 reason=no_image_id image=$IMG_NAME"
  log "  [WARN] upload attempt $_up_try failed: no image id returned"
  [ "$_up_try" -lt 3 ] && sleep 20
done
[ -n "$NEW_ID" ] || fail_exit "LS6_UPLOAD_FLEX" "Upload failed after 3 attempts"
for _poll in $(seq 1 60); do
  ST="$(openstack image show "$NEW_ID" -f value -c status 2>/dev/null || echo "")"
  [ "$ST" = "active" ] && break
  [ "$ST" = "killed" ] && fail_exit "LS6_UPLOAD_FLEX" "Image $NEW_ID killed by Glance"
  log_upload_wait_status "flex_glance_activate" "$((_poll * 20))" "1200" "${ST:-unknown}" "poll=$_poll/60 image_id=$NEW_ID"
  log "  [UPLOAD_POLL $_poll/60] status=${ST:-unknown}"; sleep 20
done
[ "$ST" = "active" ] || fail_exit "LS6_UPLOAD_FLEX" "Image $NEW_ID never reached active (status=$ST)"
log_upload_wait_status "flex_glance_activate" "1200" "1200" "active" "image_id=$NEW_ID"
log "[LS6] HIT image active: $NEW_ID"

# ── LS6A: Volume-snapshot only — fix Glance virtual_size + create FLEX Cinder volume ──
if printf '%s' "${OSPC_IMAGE_ID:-}" | grep -q '^volsnap-'; then
  stage "LS6A_CREATE_FLEX_CINDER_VOLUME"

  # Fix Glance virtual_size metadata to match the actual qcow2 virtual size from
  # qemu-img. Without this, Cinder rejects volume creation if virtual_size in
  # Glance doesn't match the requested volume size.
  if [ "${QCOW_VIRTUAL_BYTES:-0}" -gt 0 ] 2>/dev/null; then
    log "[LS6A] Setting Glance virtual_size=${QCOW_VIRTUAL_BYTES}B on image $NEW_ID"
    openstack image set --property "virtual_size=${QCOW_VIRTUAL_BYTES}" "$NEW_ID" \
      2>>"$BACKGROUND_LOG" || log "[LS6A] WARN: image set virtual_size failed (non-fatal)"
  fi

  FLEX_VOL_SIZE_GB="${QCOW_VIRTUAL_GIB:-0}"
  [ "${FLEX_VOL_SIZE_GB}" -gt 0 ] 2>/dev/null || FLEX_VOL_SIZE_GB=75
  FLEX_VOL_NAME="${LABEL_SAFE}-flex-vol-${RUN_ID}"
  kv "FLEX volume name"    "$FLEX_VOL_NAME"
  kv "FLEX volume size GB" "$FLEX_VOL_SIZE_GB"
  kv "Source image"        "$NEW_ID"

  FLEX_VOL_ID="$(openstack volume create \
    --image "$NEW_ID" \
    --size  "$FLEX_VOL_SIZE_GB" \
    --format value -c id \
    "$FLEX_VOL_NAME" 2>>"$BACKGROUND_LOG" || true)"
  [ -n "$FLEX_VOL_ID" ] || fail_exit "LS6A_CREATE_FLEX_CINDER_VOLUME" \
    "openstack volume create failed — check $BACKGROUND_LOG"
  kv "FLEX volume ID" "$FLEX_VOL_ID"

  log "[LS6A] Waiting for volume $FLEX_VOL_ID to become available…"
  _VSTAT=""
  for _vp in $(seq 1 180); do
    _VSTAT="$(openstack volume show "$FLEX_VOL_ID" -f value -c status 2>/dev/null || echo "")"
    [ "$_VSTAT" = "available" ] && break
    [ "$_VSTAT" = "error" ] && fail_exit "LS6A_CREATE_FLEX_CINDER_VOLUME" \
      "Volume $FLEX_VOL_ID entered error state"
    [ $((_vp % 6)) -eq 0 ] && log "  [VOL_WAIT] $_vp/180 status=${_VSTAT:-unknown}"
    sleep 10
  done
  [ "$_VSTAT" = "available" ] || fail_exit "LS6A_CREATE_FLEX_CINDER_VOLUME" \
    "Volume $FLEX_VOL_ID never reached available after $(( 180 * 10 ))s (status=${_VSTAT})"
  log "[LS6A] HIT FLEX Cinder volume ready: $FLEX_VOL_ID (${FLEX_VOL_SIZE_GB}GB)"

  log "[LS6A] Volume snapshot migration complete. Skipping LS7 VM boot (not needed for data volumes)."
  log "[LS6A] Summary:"
  log "  FLEX Glance image  : $NEW_ID  ($IMG_NAME)"
  log "  FLEX Cinder volume : $FLEX_VOL_ID  ($FLEX_VOL_NAME, ${FLEX_VOL_SIZE_GB}GB)"
  exit 0
fi

# ── LS7: Boot FLEX VM (mig_worker_v4 Step 7 — verbatim) ──────────────────────
stage "LS7_BOOT_FLEX_VM"
DATE="$(date +%Y%m%d-%H%M)"
VMNAME="linsnap-${LABEL_SAFE}-${DATE}"
FLAVOR="$(resolve_target_flavor "$FLAVOR" "${QCOW_VIRTUAL_GIB:-0}")"
[ -n "$FLAVOR" ] || fail_exit "LS7_BOOT_FLEX_VM" "No FLEX flavor has enough root disk for image virtual size ${QCOW_VIRTUAL_GIB:-unknown}GB"
NETWORK="$(resolve_target_network "$NETWORK")"
KEYPAIR="$(resolve_target_keypair "$KEYPAIR")"
kv "VM name"  "$VMNAME"
kv "Image"    "$NEW_ID"
kv "Flavor"   "$FLAVOR"
kv "Network"  "$NETWORK"
kv "Keypair"  "${KEYPAIR:-<none>}"
kv "Public net" "$FLEX_EXT_NET"
kv "SSH key"  "$SSH_KEY_PATH"

EXISTING="$(openstack server list --name "linsnap-${LABEL_SAFE}-" --format value -c ID 2>/dev/null || true)"
if [ -n "$EXISTING" ]; then
  while IFS= read -r _old_id; do
    [ -z "$_old_id" ] && continue
    log "  Deleting old test VM: $_old_id"
    timeout 300 openstack server delete "$_old_id" --wait >/dev/null 2>&1 || true
  done <<< "$EXISTING"
fi

if [ -n "$KEYPAIR" ]; then
  VM_ID="$(timeout 180 openstack server create --image "$NEW_ID" --flavor "$FLAVOR" --network "$NETWORK" --key-name "$KEYPAIR" --format value -c id "$VMNAME" 2>/tmp/srv_create_$$.err || true)"
else
  VM_ID="$(timeout 180 openstack server create --image "$NEW_ID" --flavor "$FLAVOR" --network "$NETWORK" --format value -c id "$VMNAME" 2>/tmp/srv_create_$$.err || true)"
fi
[ -n "$VM_ID" ] || fail_exit "LS7_BOOT_FLEX_VM" "Server create failed: $(tr '\n' ' ' </tmp/srv_create_$$.err 2>/dev/null | cut -c1-300)"
rm -f /tmp/srv_create_$$.err
kv "VM ID" "$VM_ID"

VM_ST=""
for _bp in $(seq 1 90); do
  VM_ST="$(openstack server show "$VM_ID" -f value -c status 2>/dev/null || echo "")"
  VM_TASK="$(openstack server show "$VM_ID" -f value -c "OS-EXT-STS:task_state" 2>/dev/null || true)"
  log "  [BOOT $_bp/90] status=${VM_ST:-?} task=${VM_TASK:-none}"
  [ "$VM_ST" = "ACTIVE" ] && break
  if [ "$VM_ST" = "ERROR" ]; then
    _fault="$(openstack server show "$VM_ID" -f json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("fault") or d.get("OS-EXT-SRV-ATTR:instance_name") or "")' 2>/dev/null | tr '\n' ' ' | cut -c1-500 || true)"
    fail_exit "LS7_BOOT_FLEX_VM" "Server $VM_ID entered ERROR state${_fault:+; fault=$_fault}"
  fi
  sleep 10
done
[ "$VM_ST" = "ACTIVE" ] || fail_exit "LS7_BOOT_FLEX_VM" "Server $VM_ID did not reach ACTIVE"
log "[LS7] HIT VM ACTIVE: $VM_ID"

# ── LS8: Floating IP ──────────────────────────────────────────────────────────
stage "LS8_FLOATING_IP"
_port_id=""
for _pw in $(seq 1 18); do
  _port_id="$(openstack port list --server "$VM_ID" --format value -c ID -c Status 2>/dev/null | awk '$2=="ACTIVE"{print $1; exit}')"
  [ -n "$_port_id" ] && break
  log "  [$_pw/18] waiting for port ACTIVE (10s)..."; sleep 10
done
[ -z "$_port_id" ] && _port_id="$(openstack port list --server "$VM_ID" --format value -c ID 2>/dev/null | head -1)"

REAL_FIP="NO_FIP"
if [ -n "$_port_id" ]; then
  log "  Using FLEX external network: $FLEX_EXT_NET"
  for _fip_try in 1 2 3; do
    _fip_json="$(openstack floating ip create "$FLEX_EXT_NET" -f json 2>/tmp/fip_$$.err || true)"
    FIP_ID="$(printf '%s' "$_fip_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
    FIP="$(printf '%s' "$_fip_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("floating_ip_address",""))' 2>/dev/null || true)"
    if [ -z "$FIP_ID" ]; then
      _fip_err="$(tr '\n' ' ' </tmp/fip_$$.err 2>/dev/null | cut -c1-240)"
      [ -n "$_fip_err" ] && log "  Floating IP create failed on $FLEX_EXT_NET: $_fip_err"
      _fip_row="$(openstack floating ip list --status DOWN --format value -c ID -c "Floating IP Address" 2>/dev/null | shuf | head -1 || true)"
      FIP_ID="$(echo "$_fip_row" | awk '{print $1}')"; FIP="$(echo "$_fip_row" | awk '{print $2}')"
      [ -n "$FIP_ID" ] && log "  Reusing available floating IP: $FIP ($FIP_ID)"
    fi
    [ -z "$FIP_ID" ] && { log "  No FIP available (try $_fip_try)"; sleep 10; continue; }
    openstack floating ip set --port "$_port_id" "$FIP_ID" >/tmp/fip_attach_$$.out 2>/tmp/fip_attach_$$.err || true
    sleep 5
    _fip_fixed="$(openstack floating ip show "$FIP_ID" --format value -c fixed_ip_address 2>/dev/null || true)"
    if { [ -z "$_fip_fixed" ] || [ "$_fip_fixed" = "None" ]; } && [ -n "$FIP" ]; then
      _attach_err="$(tr '\n' ' ' </tmp/fip_attach_$$.err 2>/dev/null | cut -c1-240)"
      [ -n "$_attach_err" ] && log "  Port attach failed, trying server add floating ip: $_attach_err"
      openstack server add floating ip "$VM_ID" "$FIP" >/tmp/fip_attach2_$$.out 2>/tmp/fip_attach2_$$.err || true
      sleep 5
      _fip_fixed="$(openstack floating ip show "$FIP_ID" --format value -c fixed_ip_address 2>/dev/null || true)"
    fi
    if [ -n "$_fip_fixed" ] && [ "$_fip_fixed" != "None" ]; then
      REAL_FIP="$FIP"; log "  FIP attached: $REAL_FIP → $_fip_fixed"; break
    fi
    _attach2_err="$(tr '\n' ' ' </tmp/fip_attach2_$$.err 2>/dev/null | cut -c1-240)"
    [ -n "$_attach2_err" ] && log "  Server floating IP attach failed: $_attach2_err"
    log "  FIP $FIP did not attach (try $_fip_try)"; sleep 15
  done
  rm -f /tmp/fip_$$.err /tmp/fip_attach_$$.out /tmp/fip_attach_$$.err /tmp/fip_attach2_$$.out /tmp/fip_attach2_$$.err
else
  log "  WARN: no Neutron port found for VM $VM_ID"
  openstack port list --server "$VM_ID" 2>>"$BACKGROUND_LOG" || true
fi
[ "$REAL_FIP" = "NO_FIP" ] && log "  WARN: no floating IP attached — VM has private IP only"
kv "Floating IP" "$REAL_FIP"

# ── LS9: SSH test (mig_worker_v4 Step 9 — verbatim) ──────────────────────────
stage "LS9_SSH_TEST"
SSH_OK=0; SSH_ACTUAL_USER=""
if [ "$REAL_FIP" = "NO_FIP" ]; then
  log "  SSH test skipped — no floating IP"
else
  SSH_BASE=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=12 -o BatchMode=yes -o ServerAliveInterval=10 -o ServerAliveCountMax=2)
  if [ -f "$SSH_KEY_PATH" ]; then
    SSH_BASE=(-i "$SSH_KEY_PATH" "${SSH_BASE[@]}")
  else
    log "  WARN: SSH key not found: $SSH_KEY_PATH (trying ssh-agent/default keys)"
  fi
  SSH_USERS="$FLEX_USER ubuntu cloud-user debian almalinux rocky centos root"
  TRIED_USERS=""
  for i in $(seq 1 "$SSH_ATTEMPTS"); do
    for _ssh_user in $SSH_USERS; do
      [ -n "$_ssh_user" ] || continue
      case " $TRIED_USERS " in *" $_ssh_user "*) continue ;; esac
      log "  [SSH $i/$SSH_ATTEMPTS] trying ${_ssh_user}@${REAL_FIP}"
      if ssh "${SSH_BASE[@]}" "${_ssh_user}@${REAL_FIP}" 'echo ssh-ok' 2>/tmp/linsnap_ssh_$$.err | grep -q ssh-ok; then
        SSH_OK=1; SSH_ACTUAL_USER="$_ssh_user"; break 2
      fi
      _ssh_err="$(tr '\n' ' ' </tmp/linsnap_ssh_$$.err 2>/dev/null | cut -c1-180)"
      [ -n "$_ssh_err" ] && log "    ssh: $_ssh_err"
      TRIED_USERS="$TRIED_USERS $_ssh_user"
    done
    TRIED_USERS=""
    log "  [SSH $i/$SSH_ATTEMPTS] not ready — retry in ${SSH_WAIT}s"
    sleep "$SSH_WAIT"
  done
  rm -f /tmp/linsnap_ssh_$$.err
  if [ "$SSH_OK" -eq 1 ]; then
    log "=== SSH OK: ${SSH_ACTUAL_USER}@${REAL_FIP} ==="
  else
    log "=== SSH FAILED: no tested Linux user responded on ${REAL_FIP} after $((SSH_ATTEMPTS * SSH_WAIT))s ==="
  fi
fi

# ── Final report ──────────────────────────────────────────────────────────────
log "═══════════════════════════════════════════════════════"
log "MIGRATION COMPLETE"
log "  label        : $LABEL_SAFE"
log "  flex_image   : $NEW_ID ($IMG_NAME)"
log "  flex_vm      : $VM_ID ($VMNAME)"
log "  floating_ip  : $REAL_FIP"
log "  ssh_test     : $([ $SSH_OK -eq 1 ] && echo "PASS (${SSH_ACTUAL_USER}@${REAL_FIP})" || echo "FAIL (manual check needed)")"
log "  repair_log   : $REPAIR_LOG"
log "  background   : $BACKGROUND_LOG"
log "═══════════════════════════════════════════════════════"
echo "MIGRATION_COMPLETE=true"
echo "FLEX_IMAGE_ID=$NEW_ID"
echo "FLEX_VM_ID=$VM_ID"
echo "FLEX_FIP=$REAL_FIP"
echo "SSH_OK=$SSH_OK"
exit 0
