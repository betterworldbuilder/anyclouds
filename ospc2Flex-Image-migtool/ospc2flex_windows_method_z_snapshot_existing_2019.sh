#!/usr/bin/env bash
# Method SNAPWIN — standalone existing OSPC Windows snapshot migration.
#
# Cold snapshot/image -> download/export -> qcow2 -> standalone offline Windows
# repair -> Flex IDE/e1000 rescue boot -> dummy VirtIO attach -> driver bind ->
# final virtio-scsi image/VM.
#
# Hard rules:
#   * no new OSPC source snapshot by default
#   * no SSH/live guest raw disk capture
#   * no local KVM, virt-install, virsh, or /dev/kvm dependency
#   * no Method D/G/H/v2 helper stages or sourced helper scripts

set -euo pipefail
export PATH="$PATH:/usr/sbin:/sbin"

if [ -z "${OSPC2FLEX_LINEBUF_WRAPPER:-}" ] && command -v stdbuf >/dev/null 2>&1; then
  export OSPC2FLEX_LINEBUF_WRAPPER=1
  exec stdbuf -oL -eL bash "$0" "$@"
fi

LABEL=""
OSPC_SNAPSHOT_ID="${OSPC_SNAPSHOT_ID:-}"
OSPC_IMAGE_ID="${OSPC_IMAGE_ID:-}"
LOCAL_ARTIFACT=""
OSPC_OPENRC="${OSPC_OPENRC:-}"
FLEX_OPENRC="${FLEX_OPENRC:-}"
CLOUD_FILES_CONTAINER=""
CLOUD_FILES_OBJECT=""
BASE_DIR="${OSPC2FLEX_METHOD_Z_BASE_DIR:-/mnt/migration/ospc2flex_method_z}"
DOWNLOAD_DIR=""
FLEX_REGION="${FLEX_REGION:-DFW3}"
VIRTIO_ISO="${OSPC2FLEX_VIRTIO_ISO_LOCAL:-/mnt/migration/virtio/virtio-win.iso}"
LEGACY_VIRTIO_ISO="${OSPC2FLEX_LEGACY_VIRTIO_ISO:-/usr/share/virtio-win/virtio-win-0.1.108.iso}"
VIRTIO_ISO_URL="${OSPC2FLEX_VIRTIO_ISO_URL:-https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso}"
LEGACY_VIRTIO_ISO_URL="${OSPC2FLEX_LEGACY_VIRTIO_ISO_URL:-https://fedorapeople.org/groups/virt/virtio-win/deprecated-isos/archives/virtio-win-0.1.108/virtio-win-0.1.108.iso}"
WINDOWS_VERSION="2019"
WINDOWS_VERSION_REQUESTED="${WINDOWS_VERSION}"
SNAPWIN_REPAIR_VERSION="${OSPC2FLEX_SNAPWIN_REPAIR_VERSION:-20260515-win2019-startoverride-v1}"
SKIP_RESCUE_BOOT=0
MANUAL_DRIVER_BIND=0
CONTINUE_AFTER_DRIVER_BIND=0
DOWNLOAD_ONLY=0
DRY_RUN=0
FLAVOR="${FLEX_FLAVOR:-${MIG_FLAVOR:-gp.0.4.4}}"
NETWORK="${FLEX_NETWORK:-${MIG_NETWORK:-tenant-net}}"
KEYPAIR="${FLEX_KEYPAIR:-}"
SECURITY_GROUP="${FLEX_SECURITY_GROUP:-}"
FLEX_EXT_NET="${OSPC2FLEX_FLEX_EXT_NET:-PUBLICNET}"
WIN_USER="${WIN_USER:-Administrator}"
WIN_PASSWORD="${WIN_PASSWORD:-${WINDOWS_ADMIN_PASSWORD:-}}"
HEALTHCHECK_WAIT="${OSPC2FLEX_HEALTHCHECK_WAIT:-1200}"
EXPORT_RETRIES="${OSPC2FLEX_IMAGE_EXPORT_RETRIES:-4}"
EXPORT_RETRY_WAIT="${OSPC2FLEX_IMAGE_EXPORT_RETRY_WAIT:-15}"
CLOUD_FILES_EXPORT_TIMEOUT="${OSPC2FLEX_CF_EXPORT_TIMEOUT:-7200}"
OSPC_HELPER_SERVER_ID="${OSPC_HELPER_SERVER_ID:-}"
CINDER_VOLUME_EXPORT_ON_LICENSED="${OSPC2FLEX_CINDER_VOLUME_EXPORT_ON_LICENSED:-1}"
KEEP_CINDER_EXPORT_VOLUME="${OSPC2FLEX_KEEP_CINDER_EXPORT_VOLUME:-0}"
CINDER_MIN_VOLUME_SIZE_GB="${OSPC2FLEX_CINDER_MIN_VOLUME_SIZE_GB:-75}"
DUMMY_VOLUME_SIZE_GB="${OSPC2FLEX_DUMMY_VOLUME_SIZE_GB:-10}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label) LABEL="$2"; shift 2 ;;
    --ospc-snapshot-id) OSPC_SNAPSHOT_ID="$2"; shift 2 ;;
    --ospc-image-id) OSPC_IMAGE_ID="$2"; shift 2 ;;
    --local-artifact) LOCAL_ARTIFACT="$2"; shift 2 ;;
    --ospc-openrc) OSPC_OPENRC="$2"; shift 2 ;;
    --flex-openrc) FLEX_OPENRC="$2"; shift 2 ;;
    --cloud-files-container) CLOUD_FILES_CONTAINER="$2"; shift 2 ;;
    --cloud-files-object) CLOUD_FILES_OBJECT="$2"; shift 2 ;;
    --download-dir) DOWNLOAD_DIR="$2"; shift 2 ;;
    --flex-region) FLEX_REGION="$2"; shift 2 ;;
    --virtio-iso) VIRTIO_ISO="$2"; shift 2 ;;
    --legacy-virtio-iso) LEGACY_VIRTIO_ISO="$2"; shift 2 ;;
    --windows-version) WINDOWS_VERSION="$2"; shift 2 ;;
    --flavor|--flex-flavor) FLAVOR="$2"; shift 2 ;;
    --network|--flex-network|--flex-network-id) NETWORK="$2"; shift 2 ;;
    --keypair|--flex-keypair|--flex-key-name) KEYPAIR="$2"; shift 2 ;;
    --security-group|--flex-security-group) SECURITY_GROUP="$2"; shift 2 ;;
    --windows-user) WIN_USER="$2"; shift 2 ;;
    --windows-password) WIN_PASSWORD="$2"; shift 2 ;;
    --export-retries) EXPORT_RETRIES="$2"; shift 2 ;;
    --export-retry-wait) EXPORT_RETRY_WAIT="$2"; shift 2 ;;
    --ospc-helper-server-id|--helper-server-id) OSPC_HELPER_SERVER_ID="$2"; shift 2 ;;
    --dummy-volume-size|--dummy-volume-size-gb) DUMMY_VOLUME_SIZE_GB="$2"; shift 2 ;;
    --keep-cinder-volume) KEEP_CINDER_EXPORT_VOLUME=1; shift ;;
    --no-cinder-volume-fallback) CINDER_VOLUME_EXPORT_ON_LICENSED=0; shift ;;
    --skip-rescue-boot) SKIP_RESCUE_BOOT=1; shift ;;
    --manual-driver-bind) MANUAL_DRIVER_BIND=1; shift ;;
    --continue-after-driver-bind) CONTINUE_AFTER_DRIVER_BIND=1; shift ;;
    --download-only) DOWNLOAD_ONLY=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --server-name|--server-ip|--os-family|--os-type)
      shift 2 ;;
    *) echo "ERROR: Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$LABEL" ] || { echo "ERROR: --label required" >&2; exit 2; }
LABEL_SAFE="$(printf '%s' "$LABEL" | tr -c 'A-Za-z0-9._-' '_' | sed 's/_$//')"
RUN_ID="${OSPC2FLEX_RUN_ID:-$(date -u +%Y%m%d-%H%M%S)}"
RUN_DIR="$BASE_DIR/runs/$LABEL_SAFE/$RUN_ID"
JOB_ART="${DOWNLOAD_DIR:-$RUN_DIR/artifacts}"
JOB_LOG="$RUN_DIR/logs"
JOB_STATE="$RUN_DIR/state"
JOB_TMP="$RUN_DIR/tmp"
JOB_REPORT="$RUN_DIR/reports"
PROGRESS_LOG="$JOB_LOG/method_snapwin.progress.log"
BACKGROUND_LOG="$JOB_LOG/method_snapwin.background.log"
STATE_JSON="$JOB_STATE/result.json"
RESULT_JSON="$JOB_ART/result.json"
QCOW2="$JOB_ART/${LABEL_SAFE}.flex-rescue.qcow2"
REPAIR_LOG="$JOB_ART/${LABEL_SAFE}.repair.log"
MNT="$JOB_TMP/mnt"
VIRTIO_MNT="$JOB_TMP/virtio-iso"
RESCUE_IMAGE_NAME="${LABEL_SAFE}-snapwin-safe-ide-img"
RESCUE_SERVER_NAME="${LABEL_SAFE}-snapwin-safe-ide"
DUMMY_VOLUME_NAME="${LABEL_SAFE}-snapwin-dummy-virtio"
FINAL_IMAGE_NAME="${LABEL_SAFE}-snapwin-virtio-ready-img"
FINAL_SERVER_NAME="${LABEL_SAFE}-snapwin-final-virtio"
SOURCE_ARTIFACT=""
SOURCE_FORMAT=""
RESCUE_IMAGE_ID=""
RESCUE_SERVER_ID=""
RESCUE_FLOATING_IP=""
DUMMY_VOLUME_ID=""
FINAL_IMAGE_ID=""
FINAL_SERVER_ID=""
FINAL_FLOATING_IP=""
ACCESS_METHOD=""
ACCESS_IP=""
ACCESS_PORT=""
SNAPWIN_NBD_DEV=""
CURRENT_STAGE="ZS0_PREFLIGHT"
DOWNLOAD_FAILURE_REASON="OSPC_SNAPSHOT_DOWNLOAD_UNAVAILABLE"
DOWNLOAD_NEXT_ACTION="Provide a local artifact, enable Glance image download/export, or provide Cloud Files object details."

if ! mkdir -p "$JOB_ART" "$JOB_LOG" "$JOB_STATE" "$JOB_TMP" "$JOB_REPORT" 2>/dev/null; then
  echo "[SNAPWIN] Base directory is not writable by $(id -un); preparing $BASE_DIR with sudo" >&2
  if ! command -v sudo >/dev/null 2>&1; then
    echo "ERROR: cannot create $BASE_DIR and sudo is not available" >&2
    exit 1
  fi
  sudo -n mkdir -p "$BASE_DIR"
  sudo -n chown -R "$(id -u):$(id -g)" "$BASE_DIR"
  mkdir -p "$JOB_ART" "$JOB_LOG" "$JOB_STATE" "$JOB_TMP" "$JOB_REPORT"
fi
: >"$PROGRESS_LOG"
: >"$BACKGROUND_LOG"

WINDOWS_VERSION_REQUESTED="$WINDOWS_VERSION"
if [ "${WINDOWS_VERSION,,}" = "auto" ] || [ -z "$WINDOWS_VERSION" ]; then
  case "${LABEL_SAFE,,}" in
    *2008*r2*|*2k8r2*) WINDOWS_VERSION="2008r2" ;;
    *2012*r2*|*2k12r2*) WINDOWS_VERSION="2012r2" ;;
    *2012*|*2k12*) WINDOWS_VERSION="2012" ;;
    *2016*|*2k16*) WINDOWS_VERSION="2016" ;;
    *2019*|*2k19*) WINDOWS_VERSION="2019" ;;
    *2022*|*2k22*) WINDOWS_VERSION="2022" ;;
    *) WINDOWS_VERSION="${OSPC2FLEX_SNAPWIN_DEFAULT_WINDOWS_VERSION:-2016}" ;;
  esac
fi
WINDOWS_VERSION="${WINDOWS_VERSION,,}"

step_title() {
  case "$1" in
    ZS0_PREFLIGHT) echo "Bootstrap / preflight" ;;
    ZS1_LOAD_CREDENTIALS) echo "Load cloud credentials" ;;
    ZS2_SELECT_SNAPSHOT) echo "Select existing OSPC Windows snapshot/image" ;;
    ZS3_DOWNLOAD_SNAPSHOT) echo "Download/export existing OSPC snapshot" ;;
    ZS4_NORMALIZE_QCOW2) echo "Normalize source artifact to qcow2" ;;
    ZS5_OFFLINE_WINDOWS_REPAIR) echo "Standalone offline Windows repair" ;;
    ZS6_UPLOAD_FLEX_RESCUE_IMAGE) echo "Upload repaired qcow2 to Flex as IDE/e1000 rescue image" ;;
    ZS7_BOOT_FLEX_RESCUE_VM) echo "Boot Flex rescue VM" ;;
    ZS8_ATTACH_DUMMY_VIRTIO) echo "Attach dummy VirtIO volume" ;;
    ZS9_DRIVER_BIND) echo "Bind VirtIO drivers in rescue VM" ;;
    ZS10_SNAPSHOT_VIRTIO_READY) echo "Snapshot final Windows rescue VM" ;;
    ZS11_BOOT_FINAL_FLEX_VM) echo "Boot final Flex Windows VM" ;;
    ZS12_VALIDATE_AND_REPORT) echo "Validate and report" ;;
    *) echo "$1" ;;
  esac
}

log() {
  local msg="$*" prefix body ts raw_line display_line
  ts="[$(date '+%H:%M:%S')]"
  raw_line="${ts}[$LABEL_SAFE][SNAPWIN] ${msg}"
  # Strip leading [STAGE_NAME] tag for display
  body="$(printf '%s' "$msg" | sed 's/^\[[A-Z0-9_]*\] //')"
  case "$msg" in
    *FAILED*) prefix="  └── ✗" ;;
    *" HIT "*)  prefix="  ├── ✓" ;;
    *" START"*) prefix="  ├──" ;;
    *) prefix="  ├──" ;;
  esac
  display_line="${ts} ${prefix} ${body}"
  echo "$display_line"
  echo "$raw_line" >>"$PROGRESS_LOG"
  echo "$raw_line" >>"$BACKGROUND_LOG"
}

banner() {
  local stage="$1" title w=75
  title="$(step_title "$stage")"
  local num; num="$(printf '%s' "$stage" | grep -oP '(?<=ZS)\d+')"
  local inner="MZ-Stage ${num}  │  ${title}"
  local pad=$(( w - ${#inner} - 2 ))
  [ "$pad" -lt 0 ] && pad=0
  local spaces
  spaces="$(printf '%*s' "$pad" '')"
  {
    printf '┌%s┐\n' "$(printf '─%.0s' $(seq 1 $w))"
    printf '│ %s%s │\n' "$inner" "$spaces"
    printf '└%s┘\n' "$(printf '─%.0s' $(seq 1 $w))"
  } | tee -a "$PROGRESS_LOG" "$BACKGROUND_LOG"
}

json_merge() {
  local payload="$1"
  python3 - "$STATE_JSON" "$RESULT_JSON" "$payload" <<'PY'
import json, sys
from pathlib import Path
state = Path(sys.argv[1])
result = Path(sys.argv[2])
updates = json.loads(sys.argv[3])
doc = {}
if state.is_file():
    try:
        doc = json.loads(state.read_text(encoding="utf-8"))
    except Exception:
        doc = {}
for key, val in updates.items():
    if isinstance(val, dict) and isinstance(doc.get(key), dict):
        merged = dict(doc[key])
        for subk, subv in val.items():
            if isinstance(subv, dict) and isinstance(merged.get(subk), dict):
                sub = dict(merged[subk])
                sub.update(subv)
                merged[subk] = sub
            else:
                merged[subk] = subv
        doc[key] = merged
    else:
        doc[key] = val
for path in (state, result):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
PY
}

json_string() {
  python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1"
}

checkpoint_for_stage() {
  case "$1" in
    ZS0_PREFLIGHT|ZS1_LOAD_CREDENTIALS) echo "preflight" ;;
    ZS2_SELECT_SNAPSHOT) echo "snapshot_selected" ;;
    ZS3_DOWNLOAD_SNAPSHOT) echo "snapshot_downloaded" ;;
    ZS4_NORMALIZE_QCOW2) echo "qcow2_normalized" ;;
    ZS5_OFFLINE_WINDOWS_REPAIR) echo "offline_repair" ;;
    ZS6_UPLOAD_FLEX_RESCUE_IMAGE) echo "flex_upload" ;;
    ZS7_BOOT_FLEX_RESCUE_VM) echo "rescue_boot" ;;
    ZS8_ATTACH_DUMMY_VIRTIO) echo "dummy_attach" ;;
    ZS9_DRIVER_BIND) echo "driver_bind" ;;
    ZS10_SNAPSHOT_VIRTIO_READY) echo "final_snapshot" ;;
    ZS11_BOOT_FINAL_FLEX_VM) echo "final_boot" ;;
    ZS12_VALIDATE_AND_REPORT) echo "validation" ;;
    *) echo "" ;;
  esac
}

stage_start() {
  CURRENT_STAGE="$1"
  banner "$CURRENT_STAGE"
  log "[$CURRENT_STAGE] START"
  json_merge "{\"stage\":\"$CURRENT_STAGE\",\"status\":\"RUNNING\",\"failure_reason\":\"\",\"next_action\":\"\"}"
}

checkpoint_hit() {
  json_merge "{\"checkpoints\":{\"$1\":\"HIT\"}}"
}

fail_exit() {
  local stage="$1" reason="$2" next="$3" cp stage_json reason_json next_json cp_json
  cp="$(checkpoint_for_stage "$stage")"
  log "[$stage] FAILED $reason"
  log "next_action=$next"
  stage_json="$(json_string "$stage")"
  reason_json="$(json_string "$reason")"
  next_json="$(json_string "$next")"
  if [ -n "$cp" ]; then
    cp_json="$(json_string "$cp")"
    json_merge "{\"stage\":$stage_json,\"status\":\"FAILED\",\"failure_reason\":$reason_json,\"next_action\":$next_json,\"final\":false,\"checkpoints\":{$cp_json:\"FAILED\"}}"
  else
    json_merge "{\"stage\":$stage_json,\"status\":\"FAILED\",\"failure_reason\":$reason_json,\"next_action\":$next_json,\"final\":false}"
  fi
  exit 1
}

unexpected_exit() {
  local line_no="$1" command_text="$2"
  fail_exit "${CURRENT_STAGE:-ZS0_PREFLIGHT}" "unexpected_error_line_${line_no}" "Inspect $BACKGROUND_LOG near: ${command_text}"
}
trap 'unexpected_exit "$LINENO" "$BASH_COMMAND"' ERR

redacted_env_snapshot() {
  local out="$1"
  env | sort | awk -F= '
    /^OS_/ {
      k=$1; v=$0; sub(/^[^=]*=/, "", v)
      if (k ~ /(PASSWORD|TOKEN|SECRET|KEY|CREDENTIAL)/) v="********"
      print k "=" v
    }' >"$out"
}

source_openrc_if_present() {
  local path="$1"
  if [ -n "$path" ]; then
    [ -f "$path" ] || fail_exit "$CURRENT_STAGE" "openrc_missing" "Check path: $path"
    unset OS_TOKEN OS_AUTH_TOKEN OS_SERVICE_TOKEN OS_AUTH_TYPE
    unset OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_NAME OS_APPLICATION_CREDENTIAL_SECRET
    unset OS_USERNAME OS_PASSWORD OS_PROJECT_ID OS_PROJECT_NAME OS_TENANT_ID OS_TENANT_NAME
    unset OS_USER_DOMAIN_NAME OS_PROJECT_DOMAIN_NAME OS_DOMAIN_NAME
    # shellcheck source=/dev/null
    source "$path"
  fi
}

region_from_flex_auth_url() {
  local url="${OS_AUTH_URL:-}"
  case "$url" in
    *keystone.api.dfw3.rackspacecloud.com*) echo "DFW3" ;;
    *keystone.api.iad3.rackspacecloud.com*) echo "IAD3" ;;
    *keystone.api.ord3.rackspacecloud.com*) echo "ORD3" ;;
    *) echo "" ;;
  esac
}

resolve_flex_region_after_openrc() {
  local openrc_region="${OS_REGION_NAME:-}" auth_region
  auth_region="$(region_from_flex_auth_url)"
  if [ -n "$openrc_region" ]; then
    if [ -n "${FLEX_REGION:-}" ] && [ "$FLEX_REGION" != "$openrc_region" ]; then
      log "[ZS6_UPLOAD_FLEX_RESCUE_IMAGE] WARN requested FLEX region $FLEX_REGION differs from Flex OpenRC region $openrc_region; using OpenRC region"
    fi
    FLEX_REGION="$openrc_region"
  elif [ -n "$auth_region" ]; then
    if [ -n "${FLEX_REGION:-}" ] && [ "$FLEX_REGION" != "$auth_region" ]; then
      log "[ZS6_UPLOAD_FLEX_RESCUE_IMAGE] WARN requested FLEX region $FLEX_REGION differs from Flex auth URL region $auth_region; using auth URL region"
    fi
    FLEX_REGION="$auth_region"
  else
    FLEX_REGION="${FLEX_REGION:-DFW3}"
  fi
  export OS_REGION_NAME="$FLEX_REGION"
}

check_flex_glance_access() {
  local token_log image_log rc msg
  token_log="$JOB_LOG/flex_token_issue.log"
  image_log="$JOB_LOG/flex_image_access.log"
  set +e
  openstack token issue >"$token_log" 2>&1
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    msg="$(tail -n 5 "$token_log" 2>/dev/null | tr '\n' ' ' | cut -c 1-260)"
    log "[ZS6_UPLOAD_FLEX_RESCUE_IMAGE] FLEX token issue failed rc=$rc: ${msg:-unknown error}"
    return 1
  fi
  set +e
  openstack image list --limit 1 >"$image_log" 2>&1
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    msg="$(tail -n 8 "$image_log" 2>/dev/null | tr '\n' ' ' | cut -c 1-320)"
    log "[ZS6_UPLOAD_FLEX_RESCUE_IMAGE] FLEX Glance access failed rc=$rc: ${msg:-unknown error}"
    return 2
  fi
  return 0
}

effective_keypair() {
  local requested="${KEYPAIR:-}"
  [ -n "$requested" ] || return 0
  if openstack keypair show "$requested" >/dev/null 2>&1; then
    printf '%s' "$requested"
    return 0
  fi
  log "[$CURRENT_STAGE] WARN requested keypair '$requested' not found in FLEX region ${OS_REGION_NAME:-unset}; booting without keypair" >&2
  return 0
}

require_cmd() {
  if [ "$DRY_RUN" = 1 ]; then
    command -v "$1" >/dev/null 2>&1 || log "[DRY-RUN] command not present here, would require on jumphost: $1"
  else
    command -v "$1" >/dev/null 2>&1 || fail_exit "ZS0_PREFLIGHT" "missing_command_$1" "Install $1 on the jumphost and retry."
  fi
}

pkg_for_cmd() {
  case "$1" in
    qemu-img|qemu-nbd) echo "qemu-utils" ;;
    guestmount|guestunmount) echo "libguestfs-tools" ;;
    hivexsh) echo "libhivex-bin" ;;
    reged|chntpw) echo "chntpw" ;;
    openstack) echo "python3-openstackclient" ;;
    jq) echo "jq" ;;
    curl) echo "curl" ;;
    rsync) echo "rsync" ;;
    python3) echo "python3" ;;
    ntfs-3g|ntfsfix) echo "ntfs-3g" ;;
    7z) echo "p7zip-full" ;;
    *) echo "" ;;
  esac
}

install_missing_prereqs() {
  [ "$DRY_RUN" = 1 ] && return 0
  local missing=() pkgs=() c pkg unique_pkgs
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  [ "${#missing[@]}" -gt 0 ] || return 0

  log "[ZS0_PREFLIGHT] Missing tool(s): ${missing[*]}"
  if ! command -v apt-get >/dev/null 2>&1; then
    fail_exit "ZS0_PREFLIGHT" "missing_commands_${missing[*]}" "This jumphost is missing tools and does not have apt-get. Install: ${missing[*]}"
  fi
  if ! command -v sudo >/dev/null 2>&1 || ! sudo -n true >/dev/null 2>&1; then
    fail_exit "ZS0_PREFLIGHT" "sudo_required_for_prereq_install" "Configure passwordless sudo or preinstall: ${missing[*]}"
  fi

  for c in "${missing[@]}"; do
    pkg="$(pkg_for_cmd "$c")"
    [ -n "$pkg" ] && pkgs+=("$pkg")
  done
  [ "${#pkgs[@]}" -gt 0 ] || fail_exit "ZS0_PREFLIGHT" "unknown_prereq_package" "No package mapping for missing tools: ${missing[*]}"
  unique_pkgs="$(printf '%s\n' "${pkgs[@]}" | awk 'NF && !seen[$0]++' | tr '\n' ' ')"
  log "[ZS0_PREFLIGHT] Installing missing package(s): $unique_pkgs"
  sudo -n env DEBIAN_FRONTEND=noninteractive apt-get update >>"$BACKGROUND_LOG" 2>&1
  sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y $unique_pkgs >>"$BACKGROUND_LOG" 2>&1

  for c in "${missing[@]}"; do
    if command -v "$c" >/dev/null 2>&1; then
      log "[ZS0_PREFLIGHT] OK after install: $c=$(command -v "$c")"
    else
      fail_exit "ZS0_PREFLIGHT" "missing_command_${c}_after_install" "apt install completed but $c is still unavailable. Inspect $BACKGROUND_LOG."
    fi
  done
}

ensure_virtio_iso() {
  [ "$DRY_RUN" = 1 ] && return 0
  [ "$DOWNLOAD_ONLY" = 1 ] && return 0
  local iso="$1" url="$2" label="$3" min_bytes="${4:-50000000}" tmp
  if [ -s "$iso" ] && [ "$(stat -c%s "$iso" 2>/dev/null || echo 0)" -ge "$min_bytes" ]; then
    log "[ZS0_PREFLIGHT] HIT $label present: $iso"
    return 0
  fi
  [ -n "$url" ] || return 0
  if ! command -v curl >/dev/null 2>&1; then
    log "[ZS0_PREFLIGHT] WARN cannot download $label because curl is unavailable"
    return 0
  fi
  if ! command -v sudo >/dev/null 2>&1 || ! sudo -n true >/dev/null 2>&1; then
    log "[ZS0_PREFLIGHT] WARN cannot stage $label because passwordless sudo is unavailable"
    return 0
  fi
  log "[ZS0_PREFLIGHT] Downloading missing $label to $iso"
  sudo -n mkdir -p "$(dirname "$iso")"
  sudo -n chown "$(id -u):$(id -g)" "$(dirname "$iso")" 2>/dev/null || true
  tmp="${iso}.tmp.$$"
  if curl -fL --retry 3 --retry-delay 5 --connect-timeout 20 -o "$tmp" "$url" >>"$BACKGROUND_LOG" 2>&1 \
     && [ -s "$tmp" ] && [ "$(stat -c%s "$tmp" 2>/dev/null || echo 0)" -ge "$min_bytes" ]; then
    mv -f "$tmp" "$iso"
    log "[ZS0_PREFLIGHT] HIT downloaded $label: $iso"
  else
    rm -f "$tmp"
    log "[ZS0_PREFLIGHT] WARN failed to download $label from $url; repair will fail later if the ISO is required"
  fi
}

format_from_path() {
  case "${1##*.}" in
    qcow2) echo "qcow2" ;;
    raw|img) echo "raw" ;;
    vhd) echo "vpc" ;;
    vhdx) echo "vhdx" ;;
    *) echo "unknown" ;;
  esac
}

detect_format() {
  local path="$1"
  qemu-img info --output=json "$path" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("format","unknown"))' 2>/dev/null \
    || format_from_path "$path"
}

safe_cp_source() {
  local src="$1" dest="$2"
  [ "$src" = "$dest" ] && return 0
  rsync -a --inplace "$src" "$dest"
}

qemu_convert_to_qcow2() {
  local src="$1" dest="$2"; shift 2
  rm -f "$dest"
  if ! qemu-img convert "$@" -p -O qcow2 "$src" "$dest" 2>&1 | tee -a "$BACKGROUND_LOG"; then
    rm -f "$dest"
    fail_exit "ZS4_NORMALIZE_QCOW2" "qcow2_convert_failed" "qemu-img convert failed. Check free space on $(dirname "$dest") and inspect $BACKGROUND_LOG."
  fi
}

repair_marker_path() {
  printf '%s/snapwin_repair_version' "$JOB_STATE"
}

is_current_repaired_qcow() {
  local qcow="$1" marker
  marker="$(repair_marker_path "$qcow")"
  [ -f "$marker" ] && grep -qx "SNAPWIN_REPAIR_VERSION=$SNAPWIN_REPAIR_VERSION" "$marker"
}

write_repair_marker() {
  local qcow="$1" marker token
  marker="$(repair_marker_path "$qcow")"
  token="$(choose_driver_token || true)"
  {
    echo "SNAPWIN_REPAIR_VERSION=$SNAPWIN_REPAIR_VERSION"
    echo "windows_version_requested=$WINDOWS_VERSION_REQUESTED"
    echo "windows_version_effective=$WINDOWS_VERSION"
    echo "virtio_driver_token=$token"
    echo "repaired_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$marker"
}

find_resume_artifact() {
  [ "${OSPC2FLEX_SNAPWIN_AUTO_RESUME:-1}" = "1" ] || return 1
  local f dirs=()
  [ -d "$BASE_DIR/runs/$LABEL_SAFE" ] && dirs+=("$BASE_DIR/runs/$LABEL_SAFE")
  IFS=: read -ra _extra <<< "${OSPC2FLEX_ARTIFACT_SEARCH_DIRS:-}"
  dirs+=("${_extra[@]}")
  for dir in "${dirs[@]}"; do
    [ -d "$dir" ] || continue
    while IFS= read -r f; do
      if ! qemu-img check -q "$f" >>"$BACKGROUND_LOG" 2>&1; then
        log "[ZS3_DOWNLOAD_SNAPSHOT] corrupt qcow2 skipped: $f"
        continue
      fi
      echo "$f"; return 0
    done < <(find "$dir" -maxdepth 3 -type f -name "*${LABEL_SAFE}*.qcow2" \
        -size +1G -printf '%s %p\n' 2>/dev/null | sort -nr | awk '{ $1=""; sub(/^ /, ""); print }')
  done
  return 1
}

ensure_libguestfs_kernel_readable() {
  [ "$DOWNLOAD_ONLY" = 1 ] && return 0
  command -v guestmount >/dev/null 2>&1 || return 0
  local unreadable=() kernel
  while IFS= read -r kernel; do
    [ -n "$kernel" ] && [ ! -r "$kernel" ] && unreadable+=("$kernel")
  done < <(find /boot -maxdepth 1 -type f -name 'vmlinuz-*' 2>/dev/null | sort -r)
  [ "${#unreadable[@]}" -eq 0 ] && return 0
  log "[ZS0_PREFLIGHT] libguestfs kernel image(s) are not readable by $(id -un): ${unreadable[*]}"
  if ! command -v sudo >/dev/null 2>&1 || ! sudo -n true >/dev/null 2>&1; then
    fail_exit "ZS0_PREFLIGHT" "libguestfs_kernel_not_readable" "Make /boot/vmlinuz-* readable or run SNAPWIN with passwordless sudo available."
  fi
  sudo -n chmod a+r "${unreadable[@]}" >>"$BACKGROUND_LOG" 2>&1 || fail_exit "ZS0_PREFLIGHT" "libguestfs_kernel_chmod_failed" "Allow the jumphost user to read /boot/vmlinuz-* for libguestfs/supermin."
  for kernel in "${unreadable[@]}"; do
    [ -r "$kernel" ] || fail_exit "ZS0_PREFLIGHT" "libguestfs_kernel_still_unreadable" "Make $kernel readable and retry."
    log "[ZS0_PREFLIGHT] OK libguestfs kernel readable: $kernel"
  done
}

validate_artifact() {
  local path="$1" min_bytes="${2:-1073741824}" sz
  [ -f "$path" ] || fail_exit "$CURRENT_STAGE" "source_artifact_missing" "Provide a valid local artifact or downloadable OSPC image."
  sz=$(stat -c%s "$path" 2>/dev/null || echo 0)
  [ "$sz" -gt "$min_bytes" ] || fail_exit "$CURRENT_STAGE" "source_artifact_too_small" "Artifact must be larger than 1GB for real runs."
  qemu-img info "$path" >>"$BACKGROUND_LOG" 2>&1 || fail_exit "$CURRENT_STAGE" "source_artifact_qemu_info_failed" "Check source image format and retry."
}

write_initial_state() {
  json_merge "$(cat <<EOF
{
  "method": "SNAPWIN_STANDALONE",
  "method_key": "windows_method_z_snapshot_existing",
  "status": "RUNNING",
  "stage": "ZS0_PREFLIGHT",
  "run_id": "$RUN_ID",
  "label": "$LABEL_SAFE",
  "ospc_image_id": "$OSPC_IMAGE_ID",
  "ospc_snapshot_id": "$OSPC_SNAPSHOT_ID",
  "source_artifact": "",
  "qcow2_artifact": "",
  "flex_region": "$FLEX_REGION",
  "rescue_image_id": "",
  "rescue_server_id": "",
  "dummy_volume_id": "",
  "final_image_id": "",
  "final_server_id": "",
  "checkpoints": {
    "preflight": "PENDING",
    "snapshot_selected": "PENDING",
    "snapshot_downloaded": "PENDING",
    "cinder_volume_export": "PENDING",
    "qcow2_normalized": "PENDING",
    "offline_repair": "PENDING",
    "flex_upload": "PENDING",
    "rescue_boot": "PENDING",
    "dummy_attach": "PENDING",
    "driver_bind": "PENDING",
    "final_snapshot": "PENDING",
    "final_boot": "PENDING",
    "validation": "PENDING"
  },
  "failure_reason": "",
  "next_action": "",
  "final": false
}
EOF
)"
}

list_snapshot_candidates() {
  local json_out="$JOB_REPORT/ospc_snapshot_candidates.json"
  local csv_out="$JOB_REPORT/ospc_snapshot_candidates.csv"
  openstack image list --private --long -f json >"$json_out"
  python3 - "$json_out" "$csv_out" <<'PY'
import csv, json, re, sys
rows = json.load(open(sys.argv[1], encoding="utf-8"))
pat = re.compile(r"(windows|win|server)", re.I)
allowed = {"qcow2", "raw", "vhd", "vhdx", "vpc"}
out = []
for row in rows:
    name = str(row.get("Name") or row.get("name") or "")
    fmt = str(row.get("Disk Format") or row.get("disk_format") or "").lower()
    status = str(row.get("Status") or row.get("status") or "").lower()
    vis = str(row.get("Visibility") or row.get("visibility") or "").lower()
    if pat.search(name) and fmt in allowed and status == "active" and vis in {"private", "shared", ""}:
        out.append(row)
fields = ["ID", "Name", "Status", "Disk Format", "Visibility", "Size"]
with open(sys.argv[2], "w", newline="", encoding="utf-8") as f:
    w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
    w.writeheader()
    for row in out:
        w.writerow(row)
print(len(out))
PY
}

url_host() {
  printf '%s' "$1" | sed -E 's#^[a-zA-Z]+://([^/:]+).*$#\1#'
}

host_resolves() {
  local h="$1"
  [ -n "$h" ] || return 1
  if printf '%s' "$h" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[0-9a-fA-F:]+$'; then
    return 0
  fi
  getent hosts "$h" >/dev/null 2>&1
}

normalize_glance_base() {
  printf '%s' "$1" | tr -d '[:space:]' | sed -E 's#/v2/?$##'
}

region_short() {
  local r="${OS_REGION_NAME:-IAD}"
  r="$(printf '%s' "$r" | tr '[:upper:]' '[:lower:]' | tr -d '0-9')"
  [ -n "$r" ] || r="iad"
  printf '%s' "$r"
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
      label="${host%.images.api.rackspacecloud.com}"
      prefix=""
      region="$label"
      if printf '%s' "$region" | grep -q '^snet-'; then
        prefix="snet-"
        region="${region#snet-}"
      fi
      if ! printf '%s' "$region" | grep -q '[0-9]'; then
        region="${region}3"
      fi
      translated_host="${prefix}${region}.images.api.rackspacecloud.com"
      printf '%s' "$base" | sed "s#${host}#${translated_host}#"
      ;;
    *) printf '%s' "$base" ;;
  esac
}

image_bases() {
  local region catalog_json url translated
  region="$(region_short)"
  catalog_json="$(openstack catalog show image -f json 2>/dev/null || true)"
  {
    if rackspace_identity_v2_auth >/dev/null 2>&1 && [ -s "$JOB_TMP/ospc_identity_v2_auth.json" ]; then
      WANTED_REGION="$(printf '%s' "${OS_REGION_NAME:-ALL}" | tr '[:lower:]' '[:upper:]')" python3 - "$JOB_TMP/ospc_identity_v2_auth.json" <<'PY' 2>/dev/null || true
import json, os, sys
wanted = (os.environ.get("WANTED_REGION") or "ALL").strip().upper()
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    data = {}
for svc in (((data or {}).get("access") or {}).get("serviceCatalog") or []):
    stype = str((svc or {}).get("type") or "").strip().lower()
    sname = str((svc or {}).get("name") or "").strip().lower()
    if stype not in {"image", "cloudimages"} and sname not in {"image", "cloudimages"}:
        continue
    for ep in (svc or {}).get("endpoints") or []:
        region = str((ep or {}).get("region") or "").strip().upper()
        url = str((ep or {}).get("publicURL") or (ep or {}).get("url") or "").strip().rstrip("/")
        if not url:
            continue
        if wanted != "ALL" and region != wanted:
            continue
        print(url)
PY
    fi
    if [ -n "$catalog_json" ]; then
      CATALOG_JSON="$catalog_json" python3 - <<'PY' 2>/dev/null || true
import json, os
try:
    data = json.loads(os.environ.get("CATALOG_JSON", "{}"))
except Exception:
    data = {}
for ep in data.get("endpoints") or []:
    iface = str(ep.get("interface") or "").lower()
    if iface == "public":
        url = ep.get("url") or ep.get("publicURL") or ep.get("internalURL") or ep.get("adminURL")
        if url:
            print(str(url).rstrip("/"))
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
print(json.dumps({
    "auth": {
        "RAX-KSKEY:apiKeyCredentials": {
            "username": os.environ["OSPC_USER"],
            "apiKey": os.environ["OSPC_API_KEY"],
        },
        "tenantId": os.environ["OSPC_TENANT"],
    }
}, separators=(",", ":")))
PY
)"
  auth_resp="$(curl -sS -k -X POST "$auth_url" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "$payload" 2>/dev/null || true)"
  token="$(printf '%s' "$auth_resp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["access"]["token"]["id"])' 2>/dev/null || true)"
  [ -n "$token" ] || return 1
  printf '%s\n' "$auth_resp" >"$JOB_TMP/ospc_identity_v2_auth.json" 2>/dev/null || true
  chmod 600 "$JOB_TMP/ospc_identity_v2_auth.json" 2>/dev/null || true
  printf '%s' "$token"
}

refresh_ospc_token() {
  local token
  token="$(rackspace_identity_v2_auth || true)"
  if [ -n "$token" ]; then
    printf '%s' "$token"
    return 0
  fi
  token="$(openstack token issue -f value -c id 2>/dev/null || true)"
  if [ -n "$token" ]; then
    printf '%s' "$token"
    return 0
  fi
  return 1
}

safe_object_name() {
  python3 - "$1" <<'PY'
import re, sys
name = re.sub(r"[^A-Za-z0-9._-]+", "_", sys.argv[1]).strip("._-")
print(name or "ospc2flex-snapwin-image")
PY
}

first_resolvable_image_base() {
  local base host
  while IFS= read -r base; do
    [ -n "$base" ] || continue
    host="$(url_host "$base")"
    if host_resolves "$host"; then
      printf '%s' "$base"
      return 0
    fi
  done < <(image_bases)
  return 1
}

ospc_image_exists() {
  local image_id="$1" token base code project_header=()
  openstack image show "$image_id" >/dev/null 2>&1 && return 0
  token="$(refresh_ospc_token || true)"
  token="$(printf '%s' "$token" | tr -d '[:space:]\r')"
  [ -n "$token" ] || return 1
  base="$(first_resolvable_image_base || true)"
  [ -n "$base" ] || return 1
  [ -n "$(ospc_tenant_id)" ] && project_header=(-H "X-Auth-Project-Id: $(ospc_tenant_id)")
  code="$(curl -sS -o /dev/null -w '%{http_code}' -H "X-Auth-Token: $token" "${project_header[@]}" "$base/v2/images/$image_id" 2>/dev/null || echo 000)"
  [ "$code" = "200" ]
}

log_file_excerpt() {
  local prefix="$1" file="$2"
  [ -s "$file" ] || return 0
  grep -iE 'error|fail|invalid|413|403|404|forbidden|unauthorized|endpoint|resolve|timeout|exception|denied' "$file" 2>/dev/null | tail -8 | while IFS= read -r line; do
    [ -n "$line" ] && log "$prefix $line"
  done
  tail -5 "$file" 2>/dev/null | while IFS= read -r line; do
    [ -n "$line" ] && log "$prefix tail: $line"
  done
}

is_terminal_direct_download_block() {
  local file="$1"
  [ -s "$file" ] || return 1
  grep -qiE 'HTTP_CODE=413|returned error: 413|Request Entity Too Large|InvalidResponse' "$file"
}

download_cloud_files_object() {
  local container="$1" object_name="$2" dest="$3" min_bytes="$4" tmp_log="$5" size
  rm -f "$dest"
  log "[ZS3_DOWNLOAD_SNAPSHOT] Cloud Files object download: $container/$object_name"
  if openstack object save "$container" "$object_name" --file "$dest" >"$tmp_log" 2>&1; then
    size="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
    if [ "$size" -ge "$min_bytes" ]; then
      log "[ZS3_DOWNLOAD_SNAPSHOT] HIT Cloud Files object downloaded $size bytes"
      return 0
    fi
  fi
  log "[ZS3_DOWNLOAD_SNAPSHOT] WARN Cloud Files object download failed log=$tmp_log"
  log_file_excerpt "[ZS3_DOWNLOAD_SNAPSHOT] cloud-files-error:" "$tmp_log"
  rm -f "$dest"
  return 1
}

download_cloud_files_export_task() {
  local image_id="$1" dest="$2" container="$3" min_bytes="$4"
  local object_name glance_base tasks_url payload token create_resp task_id task_json status elapsed start task_msg tmp_log project_header=()

  [ -n "$container" ] || container="ospc2flex-export"
  object_name="$(safe_object_name "${LABEL_SAFE}-${image_id}.vhd")"
  tmp_log="$JOB_LOG/cloud_files_object_save.log"

  log "[ZS3_DOWNLOAD_SNAPSHOT] Download strategy: Glance export task -> Cloud Files -> jumphost"
  log "[ZS3_DOWNLOAD_SNAPSHOT] Cloud Files target: $container/$object_name"
  openstack container create "$container" >"$JOB_LOG/cloud_files_container_create.log" 2>&1 || true

  if download_cloud_files_object "$container" "$object_name" "$dest" "$min_bytes" "$tmp_log"; then
    log "[ZS3_DOWNLOAD_SNAPSHOT] HIT reused existing Cloud Files export object"
    return 0
  fi

  glance_base="$(first_resolvable_image_base || true)"
  [ -n "$glance_base" ] || return 1
  tasks_url="${glance_base}/v2/tasks"
  payload="$(IMAGE_ID="$image_id" CF_CONTAINER="$container" CF_OBJECT="$object_name" python3 - <<'PY'
import json, os
print(json.dumps({
    "type": "export",
    "input": {
        "image_uuid": os.environ["IMAGE_ID"],
        "receiving_swift_container": os.environ["CF_CONTAINER"],
        "image_name": os.environ["CF_OBJECT"],
    },
}, separators=(",", ":")))
PY
)"
  token="$(refresh_ospc_token || true)"
  [ -n "$token" ] || return 1
  [ -n "$(ospc_tenant_id)" ] && project_header=(-H "X-Auth-Project-Id: $(ospc_tenant_id)")

  create_resp="$(curl -sS -X POST "$tasks_url" \
    -H "X-Auth-Token: $token" \
    "${project_header[@]}" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>"$JOB_LOG/cloud_files_task_create.err" || true)"
  task_id="$(printf '%s' "$create_resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
  if [ -z "$task_id" ]; then
    log "[ZS3_DOWNLOAD_SNAPSHOT] WARN Cloud Files export task create failed: ${create_resp:0:500}"
    return 1
  fi
  log "[ZS3_DOWNLOAD_SNAPSHOT] Cloud Files export task created: $task_id"

  start="$(date +%s)"
  while true; do
    elapsed=$(( $(date +%s) - start ))
    if [ "$elapsed" -gt "$CLOUD_FILES_EXPORT_TIMEOUT" ]; then
      log "[ZS3_DOWNLOAD_SNAPSHOT] WARN Cloud Files export task timed out after ${elapsed}s"
      return 1
    fi
    token="$(refresh_ospc_token || printf '%s' "$token")"
    task_json="$(curl -sS "$tasks_url/$task_id" -H "X-Auth-Token: $token" "${project_header[@]}" 2>/dev/null || true)"
    status="$(printf '%s' "$task_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status","unknown"))' 2>/dev/null || echo unknown)"
    log "[ZS3_DOWNLOAD_SNAPSHOT] Cloud Files export task status=$status elapsed=${elapsed}s"
    case "$status" in
      success) break ;;
      failure|error)
        task_msg="$(printf '%s' "$task_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("message") or d.get("result") or "")' 2>/dev/null || true)"
        log "[ZS3_DOWNLOAD_SNAPSHOT] WARN Cloud Files export task failed: ${task_msg:-<no message>}"
        if printf '%s' "$task_msg $task_json" | grep -qiE 'licensing|billing restrictions|cannot be exported|exported by the image owner|only be exported by the image owner|com\.rackspace__1__options'; then
          DOWNLOAD_FAILURE_REASON="OSPC_SNAPSHOT_EXPORT_BLOCKED_LICENSED_CINDER_ONLY"
          DOWNLOAD_NEXT_ACTION="This OSPC image is licensed/cinder-only (com.rackspace__1__options=4). Use the Cinder volume migration path or provide an operator-exported local artifact; Glance/Cloud Files export is blocked by Rackspace policy."
          if [ "$CINDER_VOLUME_EXPORT_ON_LICENSED" = "1" ]; then
            log "[ZS3B_CINDER_VOLUME_EXPORT] Licensed image export is blocked; attempting Cinder volume attach/raw-copy fallback on this IAD jumphost"
            if cinder_volume_raw_export "$image_id" "$dest"; then
              DOWNLOAD_FAILURE_REASON="OSPC_SNAPSHOT_DOWNLOAD_UNAVAILABLE"
              DOWNLOAD_NEXT_ACTION="Provide a local artifact, enable Glance image download/export, or provide Cloud Files object details."
              return 0
            fi
            DOWNLOAD_FAILURE_REASON="OSPC_CINDER_VOLUME_EXPORT_FAILED"
            DOWNLOAD_NEXT_ACTION="Cinder fallback could not create/attach/read the image volume from this jumphost. Inspect $JOB_LOG/cinder_volume_export.log and detach/delete any temporary volume named ${LABEL_SAFE}-snapwin-cinder-export-${RUN_ID} if needed."
          fi
          fail_exit "ZS3_DOWNLOAD_SNAPSHOT" "$DOWNLOAD_FAILURE_REASON" "$DOWNLOAD_NEXT_ACTION"
        fi
        if printf '%s' "$task_json" | grep -qi 'Object already exists'; then
          log "[ZS3_DOWNLOAD_SNAPSHOT] Export object already exists; attempting reuse"
          download_cloud_files_object "$container" "$object_name" "$dest" "$min_bytes" "$tmp_log" && return 0
        fi
        return 1
        ;;
      *) sleep 15 ;;
    esac
  done

  download_cloud_files_object "$container" "$object_name" "$dest" "$min_bytes" "$tmp_log"
}

cinder_wait_volume_status() {
  local vol_id="$1" want="$2" timeout="${3:-1800}" waited=0 status detail
  while [ "$waited" -lt "$timeout" ]; do
    status="$(rackspace_volume_status "$vol_id" 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '\r' || echo unknown)"
    [ "$status" = "$want" ] && return 0
    [ "$status" = "error" ] && return 1
    if [ $((waited % 60)) -eq 0 ]; then
      detail="$(rackspace_volume_detail_summary "$vol_id")"
      log "[ZS3B_CINDER_VOLUME_EXPORT] volume=$vol_id status=$status target=$want waited=${waited}s ${detail}"
    fi
    sleep 10
    waited=$((waited + 10))
  done
  return 1
}

rackspace_region_lc() {
  local r="${OS_REGION_NAME:-IAD}"
  printf '%s' "$r" | tr '[:upper:]' '[:lower:]' | tr -d '0-9'
}

rackspace_tenant_id() {
  printf '%s' "${OS_TENANT_ID:-${OS_PROJECT_ID:-${OS_TENANT_NAME:-${OS_PROJECT_NAME:-}}}}"
}

rackspace_blockstorage_base() {
  local region tenant
  region="$(rackspace_region_lc)"
  tenant="$(rackspace_tenant_id)"
  [ -n "$tenant" ] || return 1
  printf 'https://%s.blockstorage.api.rackspacecloud.com/v1/%s' "$region" "$tenant"
}

rackspace_compute_base() {
  local region tenant
  region="$(rackspace_region_lc)"
  tenant="$(rackspace_tenant_id)"
  [ -n "$tenant" ] || return 1
  printf 'https://%s.servers.api.rackspacecloud.com/v2/%s' "$region" "$tenant"
}

rackspace_volume_status() {
  local vol_id="$1" token base resp
  token="$(refresh_ospc_token || true)"
  base="$(rackspace_blockstorage_base)"
  [ -n "$token" ] && [ -n "$base" ] || return 1
  resp="$(curl -sS "$base/volumes/$vol_id" -H "X-Auth-Token: $token" 2>/dev/null || true)"
  printf '%s\n' "$resp" >"$JOB_TMP/volume_${vol_id}.json" 2>/dev/null || true
  printf '%s' "$resp" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("volume") or {}).get("status","unknown"))' 2>/dev/null || echo unknown
}

rackspace_volume_detail_summary() {
  local vol_id="$1" file="$JOB_TMP/volume_${vol_id}.json"
  [ -s "$file" ] || return 0
  python3 - "$file" <<'PY' 2>/dev/null || true
import json, sys
v = (json.load(open(sys.argv[1], encoding="utf-8")).get("volume") or {})
fields = ["status", "size", "display_name", "display_description", "availability_zone", "created_at", "volume_type", "bootable"]
parts = []
for key in fields:
    val = v.get(key)
    if val not in (None, ""):
        parts.append(f"{key}={val}")
for key in ("error", "fault", "os-vol-tenant-attr:tenant_id"):
    val = v.get(key)
    if val not in (None, ""):
        parts.append(f"{key}={val}")
print(" ".join(parts))
PY
}

rackspace_create_volume_from_image() {
  local image_id="$1" size_gb="$2" volume_name="$3" token base payload resp http body
  token="$(refresh_ospc_token || true)"
  base="$(rackspace_blockstorage_base)"
  [ -n "$token" ] && [ -n "$base" ] || return 1
  payload="$(IMAGE_ID="$image_id" SIZE_GB="$size_gb" VOLUME_NAME="$volume_name" python3 - <<'PY'
import json, os
print(json.dumps({
    "volume": {
        "display_name": os.environ["VOLUME_NAME"],
        "display_description": "OSPC2FLEX SNAPWIN cinder export temporary volume",
        "size": int(os.environ["SIZE_GB"]),
        "imageRef": os.environ["IMAGE_ID"],
    }
}, separators=(",", ":")))
PY
)"
  resp="$(curl -sS -w '\nHTTP_CODE=%{http_code}\n' -X POST "$base/volumes" \
    -H "X-Auth-Token: $token" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>>"$JOB_LOG/cinder_volume_export.log" || true)"
  http="$(printf '%s' "$resp" | awk -F= '/HTTP_CODE=/{print $2}' | tail -1)"
  body="$(printf '%s' "$resp" | sed '/^HTTP_CODE=/d')"
  printf '%s\n' "$body" >>"$JOB_LOG/cinder_volume_export.log"
  case "$http" in
    200|202) ;;
    *) log "[ZS3B_CINDER_VOLUME_EXPORT] WARN volume create HTTP=$http body=${body:0:500}" >&2; return 1 ;;
  esac
  printf '%s' "$body" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("volume") or {}).get("id",""))' 2>/dev/null
}

rackspace_delete_volume() {
  local vol_id="$1" token base
  token="$(refresh_ospc_token || true)"
  base="$(rackspace_blockstorage_base)"
  [ -n "$vol_id" ] && [ -n "$token" ] && [ -n "$base" ] || return 0
  curl -sS -X DELETE "$base/volumes/$vol_id" -H "X-Auth-Token: $token" -o /dev/null >>"$JOB_LOG/cinder_volume_export.log" 2>&1 || true
}

rackspace_attach_volume() {
  local server_id="$1" vol_id="$2" token base payload resp http body
  token="$(refresh_ospc_token || true)"
  base="$(rackspace_compute_base)"
  [ -n "$token" ] && [ -n "$base" ] || return 1
  payload="$(VOL_ID="$vol_id" python3 - <<'PY'
import json, os
print(json.dumps({"volumeAttachment": {"volumeId": os.environ["VOL_ID"]}}, separators=(",", ":")))
PY
)"
  resp="$(curl -sS -w '\nHTTP_CODE=%{http_code}\n' -X POST "$base/servers/$server_id/os-volume_attachments" \
    -H "X-Auth-Token: $token" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>>"$JOB_LOG/cinder_volume_export.log" || true)"
  http="$(printf '%s' "$resp" | awk -F= '/HTTP_CODE=/{print $2}' | tail -1)"
  body="$(printf '%s' "$resp" | sed '/^HTTP_CODE=/d')"
  printf '%s\n' "$body" >>"$JOB_LOG/cinder_volume_export.log"
  case "$http" in 200|202) return 0 ;; esac
  log "[ZS3B_CINDER_VOLUME_EXPORT] WARN volume attach HTTP=$http body=${body:0:500}"
  return 1
}

rackspace_detach_volume() {
  local server_id="$1" vol_id="$2" token base
  token="$(refresh_ospc_token || true)"
  base="$(rackspace_compute_base)"
  [ -n "$server_id" ] && [ -n "$vol_id" ] && [ -n "$token" ] && [ -n "$base" ] || return 0
  curl -sS -X DELETE "$base/servers/$server_id/os-volume_attachments/$vol_id" \
    -H "X-Auth-Token: $token" -o /dev/null >>"$JOB_LOG/cinder_volume_export.log" 2>&1 || true
}

local_block_disks() {
  sudo lsblk -dnpo NAME,TYPE 2>/dev/null \
    | awk '$2=="disk" && $1 !~ /^\/dev\/(nbd|loop|sr|fd)/ {print $1}' \
    | sort
}

find_new_block_disk() {
  local before_file="$1" after_file="$2" dev=""
  comm -13 "$before_file" "$after_file" | while IFS= read -r candidate; do
    [ -b "$candidate" ] || continue
    printf '%s\n' "$candidate"
    break
  done | head -1
}

discover_ospc_helper_server_id() {
  local ips_json hostname_text server_json
  if [ -n "$OSPC_HELPER_SERVER_ID" ]; then
    printf '%s' "$OSPC_HELPER_SERVER_ID"
    return 0
  fi
  hostname_text="$(hostname 2>/dev/null || true)"
  ips_json="$(hostname -I 2>/dev/null | tr ' ' '\n' | awk 'NF' | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
  server_json="$(openstack server list --long -f json 2>/dev/null || true)"
  LOCAL_IPS_JSON="$ips_json" LOCAL_HOSTNAME="$hostname_text" SERVER_JSON="$server_json" python3 - <<'PY'
import json, os
try:
    rows = json.loads(os.environ.get("SERVER_JSON") or "[]")
except Exception:
    rows = []
try:
    ips = json.loads(os.environ.get("LOCAL_IPS_JSON") or "[]")
except Exception:
    ips = []
host = (os.environ.get("LOCAL_HOSTNAME") or "").lower()
for row in rows:
    blob = json.dumps(row).lower()
    if any(ip and ip.lower() in blob for ip in ips):
        print(row.get("ID") or row.get("Id") or row.get("id") or "")
        raise SystemExit
if host:
    for row in rows:
        name = str(row.get("Name") or row.get("name") or "").lower()
        if host == name or host in name or name in host:
            print(row.get("ID") or row.get("Id") or row.get("id") or "")
            raise SystemExit
PY
}

image_cinder_size_gb() {
  local image_id="$1" meta_json="$JOB_TMP/cinder_image_meta.json"
  openstack image show "$image_id" -f json >"$meta_json"
  python3 - "$meta_json" <<'PY'
import json, math, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
size = int(d.get("size") or 0)
min_disk = int(d.get("min_disk") or 0)
virtual = int(d.get("virtual_size") or 0)
gb = max(1, min_disk, math.ceil(size / (1024**3)), math.ceil(virtual / (1024**3)) if virtual else 0)
print(gb)
PY
}

image_is_licensed_cinder_only() {
  local image_id="$1" meta_json="$JOB_TMP/image_meta_for_export.json"
  openstack image show "$image_id" -f json >"$meta_json" 2>/dev/null || return 1
  python3 - "$meta_json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print("0")
    raise SystemExit
props = d.get("properties") or {}
flag = ""
if isinstance(props, dict):
    flag = str(props.get("com.rackspace__1__options", "")).strip()
if not flag:
    flag = str(d.get("com.rackspace__1__options", "")).strip()
print("1" if flag == "4" else "0")
PY
}

apply_cinder_min_volume_size() {
  local requested="$1" min_size="${CINDER_MIN_VOLUME_SIZE_GB:-75}"
  if ! printf '%s' "$requested" | grep -Eq '^[0-9]+$'; then
    printf '%s' "$min_size"
    return 0
  fi
  if ! printf '%s' "$min_size" | grep -Eq '^[0-9]+$'; then
    min_size=75
  fi
  if [ "$requested" -lt "$min_size" ]; then
    printf '%s' "$min_size"
  else
    printf '%s' "$requested"
  fi
}

cinder_volume_raw_export() {
  local image_id="$1" dest="$2"
  local helper_id volume_name volume_size volume_id before_file after_file dev dev_size tmp_log dd_rc
  helper_id="$(discover_ospc_helper_server_id | head -1 | tr -d '[:space:]')"
  [ -n "$helper_id" ] || return 1
  volume_size="$(apply_cinder_min_volume_size "$(image_cinder_size_gb "$image_id")")"
  volume_name="${LABEL_SAFE}-snapwin-cinder-export-${RUN_ID}"
  before_file="$JOB_TMP/cinder_before_disks.txt"
  after_file="$JOB_TMP/cinder_after_disks.txt"
  tmp_log="$JOB_LOG/cinder_volume_export.log"
  : >"$tmp_log"

  log "[ZS3B_CINDER_VOLUME_EXPORT] START licensed/cinder-only workaround"
  log "[ZS3B_CINDER_VOLUME_EXPORT] helper_server_id=$helper_id volume_size=${volume_size}GB image=$image_id"
  local_block_disks >"$before_file"

  volume_id="$(rackspace_create_volume_from_image "$image_id" "$volume_size" "$volume_name" | tr -d '\r' | tail -1)"
  [ -n "$volume_id" ] || return 1
  log "[ZS3B_CINDER_VOLUME_EXPORT] created volume=$volume_id name=$volume_name"
  json_merge "{\"checkpoints\":{\"cinder_volume_export\":\"RUNNING\"},\"cinder_export_volume_id\":\"$volume_id\"}"
  cinder_wait_volume_status "$volume_id" "available" 3600 || return 1

  log "[ZS3B_CINDER_VOLUME_EXPORT] attaching volume to helper/jumphost"
  rackspace_attach_volume "$helper_id" "$volume_id" || return 1
  cinder_wait_volume_status "$volume_id" "in-use" 900 || return 1

  dev=""
  for _i in $(seq 1 60); do
    sleep 3
    local_block_disks >"$after_file"
    dev="$(find_new_block_disk "$before_file" "$after_file" || true)"
    [ -n "$dev" ] && break
  done
  [ -n "$dev" ] || return 1
  dev_size="$(sudo blockdev --getsize64 "$dev" 2>/dev/null || echo 0)"
  log "[ZS3B_CINDER_VOLUME_EXPORT] detected attached block device: $dev bytes=$dev_size"
  [ "$dev_size" -gt 1073741824 ] || return 1

  rm -f "$dest"
  log "[ZS3B_CINDER_VOLUME_EXPORT] raw-copying $dev -> $dest"
  set +e
  sudo dd if="$dev" of="$dest" bs=64M status=progress conv=noerror,sync >>"$tmp_log" 2>&1
  dd_rc=$?
  set -e
  [ "$dd_rc" -eq 0 ] || return 1
  sudo chown "$(id -u):$(id -g)" "$dest" 2>/dev/null || true
  [ -s "$dest" ] || return 1
  log "[ZS3B_CINDER_VOLUME_EXPORT] HIT raw artifact copied: $dest ($(stat -c%s "$dest" 2>/dev/null || echo 0) bytes)"

  log "[ZS3B_CINDER_VOLUME_EXPORT] detaching temporary volume"
  rackspace_detach_volume "$helper_id" "$volume_id"
  cinder_wait_volume_status "$volume_id" "available" 900 || true
  if [ "$KEEP_CINDER_EXPORT_VOLUME" != "1" ]; then
    log "[ZS3B_CINDER_VOLUME_EXPORT] deleting temporary volume"
    rackspace_delete_volume "$volume_id"
  else
    log "[ZS3B_CINDER_VOLUME_EXPORT] keeping temporary volume by request: $volume_id"
  fi
  json_merge "{\"checkpoints\":{\"cinder_volume_export\":\"HIT\"},\"cinder_export_volume_id\":\"$volume_id\"}"
  return 0
}

download_openstack_save() {
  local base="$1" image_id="$2" dest="$3" min_bytes="$4" tmp_log="$5" rc size
  rm -f "$dest"
  if [ -n "$base" ]; then
    log "[ZS3_DOWNLOAD_SNAPSHOT] openstack image save via OS_IMAGE_URL=$base"
  else
    log "[ZS3_DOWNLOAD_SNAPSHOT] openstack image save via catalog default"
  fi
  set +e
  if [ -n "$base" ]; then
    OS_IMAGE_URL="$base" openstack image save --file "$dest" "$image_id" >"$tmp_log" 2>&1
  else
    openstack image save --file "$dest" "$image_id" >"$tmp_log" 2>&1
  fi
  rc=$?
  set -e
  size="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
  if [ "$rc" -eq 0 ] && [ "$size" -ge "$min_bytes" ]; then
    log "[ZS3_DOWNLOAD_SNAPSHOT] HIT openstack image save downloaded $size bytes"
    return 0
  fi
  log "[ZS3_DOWNLOAD_SNAPSHOT] WARN openstack image save failed rc=$rc size=${size}B log=$tmp_log"
  log_file_excerpt "[ZS3_DOWNLOAD_SNAPSHOT] save-error:" "$tmp_log"
  rm -f "$dest"
  return 1
}

download_curl_glance() {
  local base="$1" image_id="$2" dest="$3" min_bytes="$4" token="$5" tmp_log="$6" url rc size project_header=()
  rm -f "$dest"
  url="${base}/v2/images/${image_id}/file"
  [ -n "$(ospc_tenant_id)" ] && project_header=(-H "X-Auth-Project-Id: $(ospc_tenant_id)")
  log "[ZS3_DOWNLOAD_SNAPSHOT] curl direct Glance download: $url"
  set +e
  curl -fSL --connect-timeout 30 --retry 2 --retry-delay 10 \
    --speed-time 180 --speed-limit 1024 \
    -H "X-Auth-Token: $token" \
    "${project_header[@]}" \
    -H "Accept: application/octet-stream" \
    -H "Expect:" \
    -A "ospc2flex-snapwin/1.0" \
    -o "$dest" \
    --write-out "\nHTTP_CODE=%{http_code} SIZE=%{size_download}B TIME=%{time_total}s\n" \
    "$url" >"$tmp_log" 2>&1
  rc=$?
  set -e
  size="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
  if [ "$rc" -eq 0 ] && [ "$size" -ge "$min_bytes" ]; then
    log "[ZS3_DOWNLOAD_SNAPSHOT] HIT curl downloaded $size bytes"
    return 0
  fi
  log "[ZS3_DOWNLOAD_SNAPSHOT] WARN curl failed rc=$rc size=${size}B log=$tmp_log"
  log_file_excerpt "[ZS3_DOWNLOAD_SNAPSHOT] curl-error:" "$tmp_log"
  if [ -s "$dest" ] && [ "$size" -lt 4096 ]; then
    head -c 768 "$dest" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | while IFS= read -r line; do
      [ -n "$line" ] && log "[ZS3_DOWNLOAD_SNAPSHOT] curl-error-body: $line"
    done
  fi
  rm -f "$dest"
  return 1
}

download_existing_ospc_snapshot() {
  local image_id="$1" dest="$2" min_bytes=1073741824 tmp_log token attempt base host base_i direct_blocked=0
  log "[ZS3_DOWNLOAD_SNAPSHOT] Download waterfall for existing image=$image_id"
  if [ "$CINDER_VOLUME_EXPORT_ON_LICENSED" = "1" ] && [ "$(image_is_licensed_cinder_only "$image_id" || echo 0)" = "1" ]; then
    log "[ZS3_DOWNLOAD_SNAPSHOT] HIT image metadata indicates licensed/cinder-only (com.rackspace__1__options=4)"
    log "[ZS3_DOWNLOAD_SNAPSHOT] Prioritizing Cinder volume attach/raw-copy fallback before Glance export attempts"
    if cinder_volume_raw_export "$image_id" "$dest"; then
      return 0
    fi
    DOWNLOAD_FAILURE_REASON="OSPC_CINDER_VOLUME_EXPORT_FAILED"
    DOWNLOAD_NEXT_ACTION="Cinder fallback could not create/attach/read the image volume from this jumphost. Inspect $JOB_LOG/cinder_volume_export.log and detach/delete any temporary volume named ${LABEL_SAFE}-snapwin-cinder-export-${RUN_ID} if needed."
    return 1
  fi
  log "[ZS3_DOWNLOAD_SNAPSHOT] Glance endpoint candidates:"
  image_bases | sed 's/^/[ZS3_DOWNLOAD_SNAPSHOT]   - /' | while IFS= read -r line; do log "$line"; done

  token="$(refresh_ospc_token || true)"

  attempt=1
  while [ "$attempt" -le "$EXPORT_RETRIES" ]; do
    log "[ZS3_DOWNLOAD_SNAPSHOT] Classic Glance attempt $attempt/$EXPORT_RETRIES"
    tmp_log="$JOB_LOG/openstack_image_save_default_attempt${attempt}.log"
    if download_openstack_save "" "$image_id" "$dest" "$min_bytes" "$tmp_log"; then
      return 0
    fi
    if is_terminal_direct_download_block "$tmp_log"; then
      direct_blocked=1
      log "[ZS3_DOWNLOAD_SNAPSHOT] Direct Glance save is terminally blocked for this image; skipping remaining direct retries."
      break
    fi
    base_i=0
    while IFS= read -r base; do
      [ -n "$base" ] || continue
      base_i=$((base_i + 1))
      host="$(url_host "$base")"
      if ! host_resolves "$host"; then
        log "[ZS3_DOWNLOAD_SNAPSHOT] WARN skipping unresolved Glance host: $host"
        continue
      fi
      tmp_log="$JOB_LOG/openstack_image_save_attempt${attempt}_base${base_i}.log"
      if download_openstack_save "$base" "$image_id" "$dest" "$min_bytes" "$tmp_log"; then
        return 0
      fi
      if is_terminal_direct_download_block "$tmp_log"; then
        direct_blocked=1
        log "[ZS3_DOWNLOAD_SNAPSHOT] Direct Glance save is terminally blocked for $base; skipping remaining direct retries."
        break
      fi
      token="$(refresh_ospc_token || printf '%s' "$token")"
      if [ -n "$token" ]; then
        tmp_log="$JOB_LOG/curl_glance_attempt${attempt}_base${base_i}.log"
        if download_curl_glance "$base" "$image_id" "$dest" "$min_bytes" "$token" "$tmp_log"; then
          return 0
        fi
        if is_terminal_direct_download_block "$tmp_log"; then
          direct_blocked=1
          log "[ZS3_DOWNLOAD_SNAPSHOT] Direct Glance file endpoint returned terminal block for $base; skipping remaining direct retries."
          break
        fi
      else
        log "[ZS3_DOWNLOAD_SNAPSHOT] WARN token refresh failed; skipping curl fallback for $base"
      fi
    done < <(image_bases)
    if [ "$direct_blocked" = "1" ]; then
      log "[ZS3_DOWNLOAD_SNAPSHOT] Falling through to Cloud Files export / Cinder fallback after terminal direct-download block."
      break
    fi
    [ "$attempt" -lt "$EXPORT_RETRIES" ] && sleep "$EXPORT_RETRY_WAIT"
    token="$(refresh_ospc_token || printf '%s' "$token")"
    attempt=$((attempt + 1))
  done

  if [ -n "$CLOUD_FILES_CONTAINER" ] && [ -n "$CLOUD_FILES_OBJECT" ]; then
    log "[ZS3_DOWNLOAD_SNAPSHOT] Download strategy 2: existing Cloud Files object $CLOUD_FILES_CONTAINER/$CLOUD_FILES_OBJECT"
    if command -v openstack >/dev/null 2>&1; then
      tmp_log="$JOB_LOG/cloud_files_object_save.log"
      rm -f "$dest"
      if openstack object save "$CLOUD_FILES_CONTAINER" "$CLOUD_FILES_OBJECT" --file "$dest" >"$tmp_log" 2>&1 && [ "$(stat -c%s "$dest" 2>/dev/null || echo 0)" -ge "$min_bytes" ]; then
        log "[ZS3_DOWNLOAD_SNAPSHOT] HIT Cloud Files object downloaded"
        return 0
      fi
      log "[ZS3_DOWNLOAD_SNAPSHOT] WARN Cloud Files object download failed log=$tmp_log"
      log_file_excerpt "[ZS3_DOWNLOAD_SNAPSHOT] cloud-files-error:" "$tmp_log"
    elif command -v swift >/dev/null 2>&1; then
      tmp_log="$JOB_LOG/swift_download.log"
      rm -f "$dest"
      if swift download "$CLOUD_FILES_CONTAINER" "$CLOUD_FILES_OBJECT" --output "$dest" >"$tmp_log" 2>&1 && [ "$(stat -c%s "$dest" 2>/dev/null || echo 0)" -ge "$min_bytes" ]; then
        log "[ZS3_DOWNLOAD_SNAPSHOT] HIT Cloud Files object downloaded via swift"
        return 0
      fi
      log_file_excerpt "[ZS3_DOWNLOAD_SNAPSHOT] swift-error:" "$tmp_log"
    fi
  fi

  local cf_rc
  set +e
  download_cloud_files_export_task "$image_id" "$dest" "${CLOUD_FILES_CONTAINER:-ospc2flex-export}" "$min_bytes"
  cf_rc=$?
  set -e
  if [ "$cf_rc" -eq 0 ]; then
    return 0
  fi
  if [ "$cf_rc" -eq 42 ]; then
    return 42
  fi
  return 1
}

z_wait_for_image_active() {
  local image_id="$1" timeout="${2:-1800}" waited=0 status
  while [ "$waited" -lt "$timeout" ]; do
    status="$(openstack image show "$image_id" -f value -c status 2>/dev/null | tr -d '\r' || echo unknown)"
    [ "$status" = "active" ] && return 0
    [ "$status" = "killed" ] && return 1
    [ $((waited % 60)) -eq 0 ] && log "[wait_image_active] image=$image_id status=$status waited=${waited}s"
    sleep 10
    waited=$((waited + 10))
  done
  return 1
}

z_wait_for_server_status() {
  local server_id="$1" target="$2" timeout="${3:-900}" waited=0 status
  while [ "$waited" -lt "$timeout" ]; do
    status="$(openstack server show "$server_id" -f value -c status 2>/dev/null | tr -d '\r' || echo unknown)"
    [ "$status" = "$target" ] && return 0
    [ "$status" = "ERROR" ] && return 1
    [ $((waited % 60)) -eq 0 ] && log "[wait_server_status] server=$server_id status=$status target=$target waited=${waited}s"
    sleep 10
    waited=$((waited + 10))
  done
  return 1
}

z_attach_floating_ip() {
  local server_id="$1" port_id fip_json fip_id fip
  port_id="$(openstack port list --server "$server_id" -f value -c ID 2>/dev/null | head -1 | tr -d '\r' || true)"
  [ -n "$port_id" ] || return 1
  fip_json="$(openstack floating ip create "$FLEX_EXT_NET" -f json 2>/dev/null || true)"
  fip_id="$(printf '%s' "$fip_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("id",""))' 2>/dev/null || true)"
  fip="$(printf '%s' "$fip_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("floating_ip_address",""))' 2>/dev/null || true)"
  [ -n "$fip_id" ] || return 1
  openstack floating ip set --port "$port_id" "$fip_id" >/dev/null 2>&1 || return 1
  printf '%s\n' "$fip"
}

console_has_fatal_boot_error() {
  local server_id="$1" console
  console="$(openstack console log show "$server_id" 2>/dev/null || true)"
  if printf '%s\n' "$console" | grep -Eiq 'Windows\\system32\\config\\system|0xc0000225'; then return 2; fi
  if printf '%s\n' "$console" | grep -Eiq 'INACCESSIBLE[ _]BOOT[ _]DEVICE|INACCESSIBLE_BOOT_DEVICE'; then return 3; fi
  return 0
}

probe_winrm() {
  local host="$1" port="$2"
  [ -n "$WIN_PASSWORD" ] || return 1
  WINRM_HOST="$host" WINRM_PORT="$port" WINRM_USER="$WIN_USER" WINRM_PASS="$WIN_PASSWORD" python3 - <<'PY' >/dev/null 2>&1
import os, sys
try:
    import winrm
except Exception:
    sys.exit(99)
scheme = "https" if os.environ["WINRM_PORT"] == "5986" else "http"
try:
    s = winrm.Session(f"{scheme}://{os.environ['WINRM_HOST']}:{os.environ['WINRM_PORT']}/wsman",
                      auth=(os.environ["WINRM_USER"], os.environ["WINRM_PASS"]),
                      transport="ntlm", server_cert_validation="ignore",
                      read_timeout_sec=18, operation_timeout_sec=14)
    sys.exit(s.run_ps("1").status_code)
except Exception:
    sys.exit(96)
PY
}

run_winrm_ps() {
  local script="$1"
  WINRM_HOST="$ACCESS_IP" WINRM_PORT="$ACCESS_PORT" WINRM_USER="$WIN_USER" WINRM_PASS="$WIN_PASSWORD" WINRM_SCRIPT="$script" python3 - <<'PY'
import os, sys
import winrm
scheme = "https" if os.environ["WINRM_PORT"] == "5986" else "http"
s = winrm.Session(f"{scheme}://{os.environ['WINRM_HOST']}:{os.environ['WINRM_PORT']}/wsman",
                  auth=(os.environ["WINRM_USER"], os.environ["WINRM_PASS"]),
                  transport="ntlm", server_cert_validation="ignore",
                  read_timeout_sec=900, operation_timeout_sec=300)
r = s.run_ps(os.environ["WINRM_SCRIPT"])
sys.stdout.write(r.std_out.decode("utf-8", "replace"))
sys.stderr.write(r.std_err.decode("utf-8", "replace"))
sys.exit(r.status_code)
PY
}

z_wait_for_windows_access() {
  local server_id="$1" timeout="${2:-1200}" waited=0 ips ip
  while [ "$waited" -lt "$timeout" ]; do
    ips="$(openstack server show "$server_id" -f value -c addresses 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' || true)"
    for ip in $RESCUE_FLOATING_IP $FINAL_FLOATING_IP $ips; do
      [ -n "$ip" ] || continue
      if probe_winrm "$ip" 5986; then ACCESS_METHOD=winrm_https; ACCESS_IP="$ip"; ACCESS_PORT=5986; return 0; fi
      if probe_winrm "$ip" 5985; then ACCESS_METHOD=winrm_http; ACCESS_IP="$ip"; ACCESS_PORT=5985; return 0; fi
    done
    [ $((waited % 60)) -eq 0 ] && log "[wait_windows_access] waited=${waited}s server=$server_id"
    sleep 15
    waited=$((waited + 15))
  done
  return 1
}

show_manual_driver_card() {
  cat <<'EOF'
═══════════════════════════════════════════════════════════════════════════
Required: Bind VirtIO Drivers in Flex Rescue VM
═══════════════════════════════════════════════════════════════════════════
Write-Host "=== Method SNAPWIN: VirtIO Driver Bind ==="
Test-Path C:\ospc2flex\drivers
Get-ChildItem C:\ospc2flex\drivers | Select-Object Name
pnputil /add-driver C:\ospc2flex\drivers\*.inf /subdirs /install
pnputil /enum-drivers | findstr /i "viostor vioscsi netkvm balloon"
Get-Disk
Get-PnpDevice | findstr /i "virtio red hat scsi ethernet balloon"
Get-PnpDevice -Class SCSIAdapter
Get-PnpDevice -Class Net
Restart-Computer
EOF
}

run_driver_binding() {
  local script
  script='pnputil /add-driver C:\ospc2flex\drivers\*.inf /subdirs /install; pnputil /enum-drivers | findstr /i "viostor vioscsi netkvm balloon"; Get-Disk | Out-String'
  [ "$ACCESS_METHOD" = "winrm_http" ] || [ "$ACCESS_METHOD" = "winrm_https" ] || return 1
  run_winrm_ps "$script" >>"$BACKGROUND_LOG" 2>&1
}

upload_flex_rescue_image_method_ab() {
  local upload_try out_file err_file rc image_id status_line err_msg
  local qcow_bytes qcow_mib
  qcow_bytes=$(stat -c%s "$QCOW2" 2>/dev/null || echo 0)
  qcow_mib=$((qcow_bytes / 1024 / 1024))

  log "[ZS6_UPLOAD_FLEX_RESCUE_IMAGE] Method A/B Glance upload path"
  log "[ZS6_UPLOAD_FLEX_RESCUE_IMAGE] Uploading: ${qcow_bytes} bytes (${qcow_mib} MiB) to FLEX Glance"
  log "[ZS6_UPLOAD_FLEX_RESCUE_IMAGE] Metadata: architecture=x86_64 vm_mode=hvm os_type=windows os_distro=windows hw_disk_bus=ide hw_cdrom_bus=ide hw_vif_model=e1000 hw_qemu_guest_agent=yes"

  local image_create_args=(
    image create "$RESCUE_IMAGE_NAME"
    --disk-format qcow2
    --container-format bare
    --file "$QCOW2"
    --private
    --property "architecture=x86_64"
    --property "vm_mode=hvm"
    --property "os_type=windows"
    --property "os_distro=windows"
    --property "hw_disk_bus=ide"
    --property "hw_cdrom_bus=ide"
    --property "hw_vif_model=e1000"
    --property "hw_qemu_guest_agent=yes"
    --property "ospc2flex_method=SNAPWIN_STANDALONE"
    --property "ospc2flex_run_id=$RUN_ID"
    --format value -c id
  )

  for upload_try in 1 2 3; do
    [ "$upload_try" -gt 1 ] && log "[ZS6_UPLOAD_FLEX_RESCUE_IMAGE] Upload attempt $upload_try/3"
    log "[ZS6_UPLOAD_FLEX_RESCUE_IMAGE] [UPLOAD $upload_try/3] starting image upload (stderr -> $BACKGROUND_LOG)"
    echo "[$(date '+%F %T')] openstack image create name=$RESCUE_IMAGE_NAME file=$QCOW2 bytes=$qcow_bytes try=$upload_try" >>"$BACKGROUND_LOG"
    out_file="$(mktemp)"
    err_file="$(mktemp)"
    if openstack "${image_create_args[@]}" >"$out_file" 2>"$err_file"; then
      cat "$err_file" >>"$BACKGROUND_LOG"
      image_id="$(grep -Eo '[0-9a-fA-F-]{36}' "$out_file" | tail -n 1 || true)"
      rm -f "$out_file" "$err_file" 2>/dev/null || true
      if [ -n "$image_id" ]; then
        status_line="$(openstack image show "$image_id" -f value -c status 2>/dev/null || echo "unknown")"
        log "[ZS6_UPLOAD_FLEX_RESCUE_IMAGE] [UPLOAD $upload_try/3] returned image id: $image_id"
        log "[ZS6_UPLOAD_FLEX_RESCUE_IMAGE] [UPLOAD $upload_try/3] initial image status: ${status_line:-unknown}"
        RESCUE_IMAGE_ID="$image_id"
        return 0
      fi
      log "[ZS6_UPLOAD_FLEX_RESCUE_IMAGE] WARN upload returned no image id"
    else
      rc=$?
      cat "$err_file" >>"$BACKGROUND_LOG"
      err_msg="$(tail -n 8 "$err_file" 2>/dev/null | tr '\n' ' ' | cut -c 1-320 || echo "Unknown error")"
      rm -f "$out_file" "$err_file" 2>/dev/null || true
      log "[ZS6_UPLOAD_FLEX_RESCUE_IMAGE] WARN upload attempt $upload_try failed rc=$rc: $err_msg"
    fi

    if [ "$upload_try" -lt 3 ]; then
      log "[ZS6_UPLOAD_FLEX_RESCUE_IMAGE] [UPLOAD $upload_try/3] sleeping 20s before retry"
      sleep 20
    fi
  done
  return 1
}

find_existing_rescue_image() {
  local image_id
  image_id="$(
    openstack image list --name "$RESCUE_IMAGE_NAME" -f value -c ID -c Status 2>/dev/null \
      | awk '$2 == "active" { print $1; exit }'
  )"
  [ -n "$image_id" ] || return 1
  printf '%s' "$image_id"
}

find_existing_rescue_server() {
  local server_id
  while read -r server_id _status; do
    [ -n "$server_id" ] || continue
    if server_has_volume "$server_id" "$DUMMY_VOLUME_ID"; then
      printf '%s' "$server_id"
      return 0
    fi
    log "[ZS7_BOOT_FLEX_RESCUE_VM] WARN deleting stale rescue VM without dummy volume: $server_id" >&2
    openstack server delete "$server_id" >>"$BACKGROUND_LOG" 2>&1 || true
    for _ in $(seq 1 90); do
      openstack server show "$server_id" >/dev/null 2>&1 || break
      sleep 5
    done
  done < <(openstack server list --name "$RESCUE_SERVER_NAME" -f value -c ID -c Status 2>/dev/null | awk '$2 == "ACTIVE"')
  return 1
}

find_available_dummy_volume() {
  local volume_id
  volume_id="$(
    openstack volume list --name "$DUMMY_VOLUME_NAME" -f value -c ID -c Status 2>/dev/null \
      | awk '$2 == "available" { print $1; exit }'
  )"
  [ -n "$volume_id" ] || return 1
  printf '%s' "$volume_id"
}

wait_volume_status() {
  local volume_id="$1" target="$2" waited=0 status
  while [ "$waited" -lt 600 ]; do
    status="$(openstack volume show "$volume_id" -f value -c status 2>/dev/null | tr -d '\r' || true)"
    [ "$status" = "$target" ] && return 0
    sleep 5
    waited=$((waited + 5))
  done
  return 1
}

server_has_volume() {
  local server_id="$1" volume_id="$2"
  [ -n "$server_id" ] && [ -n "$volume_id" ] || return 1
  openstack server show "$server_id" -f json -c volumes_attached 2>/dev/null \
    | jq -e --arg id "$volume_id" '.volumes_attached[]?.id == $id' >/dev/null 2>&1
}

find_windows_root() {
  if [ -f "$MNT/Windows/System32/config/SYSTEM" ]; then echo "$MNT/Windows"; return 0; fi
  if [ -f "$MNT/windows/system32/config/SYSTEM" ]; then echo "$MNT/windows"; return 0; fi
  return 1
}

detect_windows_ntfs_partition() {
  virt-filesystems -a "$QCOW2" --filesystems --long 2>>"$REPAIR_LOG" \
    | awk '$3 == "ntfs" { print $1; exit }'
}

wait_for_nbd_ntfs_partition() {
  local nbd="$1" i part fstype
  for i in $(seq 1 30); do
    sudo -n partprobe "$nbd" >>"$REPAIR_LOG" 2>&1 || true
    command -v udevadm >/dev/null 2>&1 && sudo -n udevadm settle >>"$REPAIR_LOG" 2>&1 || true
    for part in "${nbd}"p*; do
      [ -b "$part" ] || continue
      fstype="$(sudo -n blkid -o value -s TYPE "$part" 2>/dev/null || true)"
      if [ "$fstype" = "ntfs" ]; then
        echo "$part"
        return 0
      fi
    done
    sleep 1
  done
  return 1
}

cleanup_guest_mountpoint() {
  local mnt="$1"
  if mountpoint -q "$mnt" 2>/dev/null; then
    guestunmount "$mnt" >>"$REPAIR_LOG" 2>&1 || fusermount3 -u "$mnt" >>"$REPAIR_LOG" 2>&1 || fusermount -u "$mnt" >>"$REPAIR_LOG" 2>&1 || sudo -n umount "$mnt" >>"$REPAIR_LOG" 2>&1 || true
  fi
}

cleanup_windows_mount() {
  if mountpoint -q "$MNT" 2>/dev/null; then
    sudo -n umount "$MNT" >>"$REPAIR_LOG" 2>&1 || guestunmount "$MNT" >>"$REPAIR_LOG" 2>&1 || fusermount3 -u "$MNT" >>"$REPAIR_LOG" 2>&1 || sudo -n umount -l "$MNT" >>"$REPAIR_LOG" 2>&1 || true
  fi
  if [ -n "$SNAPWIN_NBD_DEV" ]; then
    sudo -n qemu-nbd --disconnect "$SNAPWIN_NBD_DEV" >>"$REPAIR_LOG" 2>&1 || true
    SNAPWIN_NBD_DEV=""
  fi
}

cleanup_stale_guestfs_for_qcow2() {
  local pid cmd
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    cmd="$(ps -p "$pid" -o args= 2>/dev/null || true)"
    case "$cmd" in
      *guestmount*|*qemu-system*x86_64*)
        log "[ZS5_OFFLINE_WINDOWS_REPAIR] cleaning stale libguestfs process pid=$pid"
        kill "$pid" 2>/dev/null || true
        sleep 1
        kill -9 "$pid" 2>/dev/null || true
        ;;
    esac
  done < <(pgrep -f "$QCOW2" 2>/dev/null || true)
}

mount_windows_ntfs_nbd_rw() {
  local nbd part
  if ! command -v sudo >/dev/null 2>&1 || ! sudo -n true >/dev/null 2>&1; then
    fail_exit "ZS5_OFFLINE_WINDOWS_REPAIR" "sudo_required_for_nbd_mount" "Configure passwordless sudo for qemu-nbd/ntfs-3g offline repair."
  fi
  sudo -n modprobe nbd max_part=16 >>"$REPAIR_LOG" 2>&1 || true
  nbd="$(pick_free_nbd_device || true)"
  [ -n "$nbd" ] || fail_exit "ZS5_OFFLINE_WINDOWS_REPAIR" "no_free_nbd_device" "Detach stale /dev/nbd devices and retry."
  sudo -n qemu-nbd --disconnect "$nbd" >>"$REPAIR_LOG" 2>&1 || true
  log "[ZS5_OFFLINE_WINDOWS_REPAIR] mounting qcow2 via $nbd + ntfs-3g"
  sudo -n qemu-nbd --connect="$nbd" --format=qcow2 "$QCOW2" >>"$REPAIR_LOG" 2>&1 || fail_exit "ZS5_OFFLINE_WINDOWS_REPAIR" "qemu_nbd_connect_failed" "Inspect $REPAIR_LOG."
  SNAPWIN_NBD_DEV="$nbd"
  part="$(wait_for_nbd_ntfs_partition "$nbd" || true)"
  [ -n "$part" ] || { cleanup_windows_mount; fail_exit "ZS5_OFFLINE_WINDOWS_REPAIR" "ntfs_partition_not_found" "Inspect partition table with fdisk -l $nbd."; }
  log "[ZS5_OFFLINE_WINDOWS_REPAIR] NTFS partition for repair: $part"
  sudo -n ntfsfix -d "$part" >>"$REPAIR_LOG" 2>&1 || log "[ZS5_OFFLINE_WINDOWS_REPAIR] WARN: ntfsfix returned non-zero for $part"
  sudo -n ntfs-3g -o rw,remove_hiberfile,big_writes "$part" "$MNT" >>"$REPAIR_LOG" 2>&1 || fail_exit "ZS5_OFFLINE_WINDOWS_REPAIR" "ntfs3g_mount_failed" "Inspect $REPAIR_LOG."
  touch "$MNT/.snapwin-rw-test" 2>>"$REPAIR_LOG" && rm -f "$MNT/.snapwin-rw-test" 2>>"$REPAIR_LOG" || fail_exit "ZS5_OFFLINE_WINDOWS_REPAIR" "ntfs3g_mount_read_only" "NTFS mount is read-only; inspect $REPAIR_LOG."
}

prepare_guest_mountpoint() {
  cleanup_guest_mountpoint "$MNT"
  cleanup_stale_guestfs_for_qcow2
  cleanup_windows_mount
  rm -rf "$MNT" 2>/dev/null || sudo -n rm -rf "$MNT"
  mkdir -p "$MNT" 2>/dev/null || {
    sudo -n mkdir -p "$MNT"
    sudo -n chown "$(id -u):$(id -g)" "$MNT"
  }
}

pick_free_nbd_device() {
  local i n size
  for i in $(seq 15 -1 0); do
    n="/dev/nbd$i"
    [ -b "$n" ] || continue
    size="$(cat "/sys/block/nbd$i/size" 2>/dev/null || echo 1)"
    [ "$size" = "0" ] && { echo "$n"; return 0; }
  done
  return 1
}

preclean_ntfs_for_rw_mount() {
  local nbd part fstype found=0 i
  command -v ntfsfix >/dev/null 2>&1 || return 0
  command -v qemu-nbd >/dev/null 2>&1 || return 0
  if ! command -v sudo >/dev/null 2>&1 || ! sudo -n true >/dev/null 2>&1; then
    log "[ZS5_OFFLINE_WINDOWS_REPAIR] WARN: sudo unavailable; skipping NTFS dirty-bit preclean"
    return 0
  fi
  sudo -n modprobe nbd max_part=16 >>"$REPAIR_LOG" 2>&1 || true
  nbd="$(pick_free_nbd_device || true)"
  [ -n "$nbd" ] || { log "[ZS5_OFFLINE_WINDOWS_REPAIR] WARN: no free /dev/nbd device for NTFS preclean"; return 0; }
  sudo -n qemu-nbd --disconnect "$nbd" >>"$REPAIR_LOG" 2>&1 || true
  log "[ZS5_OFFLINE_WINDOWS_REPAIR] NTFS preclean via $nbd"
  if ! sudo -n qemu-nbd --connect="$nbd" --format=qcow2 "$QCOW2" >>"$REPAIR_LOG" 2>&1; then
    log "[ZS5_OFFLINE_WINDOWS_REPAIR] WARN: qemu-nbd connect failed; continuing to guestmount"
    return 0
  fi
  sleep 3
  sudo -n partprobe "$nbd" >>"$REPAIR_LOG" 2>&1 || true
  command -v udevadm >/dev/null 2>&1 && sudo -n udevadm settle >>"$REPAIR_LOG" 2>&1 || true
  for i in $(seq 1 10); do
    compgen -G "${nbd}p*" >/dev/null && break
    sleep 1
    sudo -n partprobe "$nbd" >>"$REPAIR_LOG" 2>&1 || true
  done
  for part in "${nbd}"p*; do
    [ -b "$part" ] || continue
    fstype="$(blkid -o value -s TYPE "$part" 2>/dev/null || true)"
    [ "$fstype" = "ntfs" ] || continue
    found=1
    log "[ZS5_OFFLINE_WINDOWS_REPAIR] running ntfsfix -d on $part"
    sudo -n ntfsfix -d "$part" >>"$REPAIR_LOG" 2>&1 || log "[ZS5_OFFLINE_WINDOWS_REPAIR] WARN: ntfsfix returned non-zero for $part"
  done
  [ "$found" = "1" ] || log "[ZS5_OFFLINE_WINDOWS_REPAIR] WARN: no NTFS partition found on $nbd"
  sudo -n qemu-nbd --disconnect "$nbd" >>"$REPAIR_LOG" 2>&1 || true
  sleep 2
}

merge_system_reg() {
  local reg="$1" hive="$2"
  if command -v hivexregedit >/dev/null 2>&1; then
    sudo hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\SYSTEM' "$hive" "$reg" >>"$REPAIR_LOG" 2>&1
    return $?
  fi
  printf 'y\n' | sudo reged -I "$hive" "HKEY_LOCAL_MACHINE\\SYSTEM" "$reg" >>"$REPAIR_LOG" 2>&1
}

merge_software_reg() {
  local reg="$1" hive="$2"
  if command -v hivexregedit >/dev/null 2>&1; then
    sudo hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\SOFTWARE' "$hive" "$reg" >>"$REPAIR_LOG" 2>&1
    return $?
  fi
  printf 'y\n' | sudo reged -I "$hive" "HKEY_LOCAL_MACHINE\\SOFTWARE" "$reg" >>"$REPAIR_LOG" 2>&1
}

choose_driver_token() {
  case "$WINDOWS_VERSION" in
    2008r2|2k8r2) echo "2k8R2" ;;
    2012|2012r2|2k12|2k12r2) echo "2k12R2" ;;
    2016|2k16) echo "2k16" ;;
    2019|2k19) echo "2k19" ;;
    2022|2k22) echo "2k22" ;;
    *) echo "" ;;
  esac
}

driver_token_candidates() {
  case "$WINDOWS_VERSION" in
    2008r2|2k8r2) echo "2k8R2 2k8" ;;
    2012|2012r2|2k12|2k12r2) echo "2k12R2 2k12" ;;
    2016|2k16) echo "2k16 w10" ;;
    2019|2k19) echo "2k19 2k16 w10" ;;
    2022|2k22) echo "2k22 2k19 2k16 w10" ;;
    *) return 1 ;;
  esac
}

mount_virtio_iso() {
  local iso="$1"
  [ -f "$iso" ] || return 1
  mkdir -p "$VIRTIO_MNT"
  sudo umount "$VIRTIO_MNT" >/dev/null 2>&1 || true
  sudo mount -o loop,ro "$iso" "$VIRTIO_MNT" >>"$REPAIR_LOG" 2>&1
}

stage_virtio_drivers() {
  local winroot="$1" drv_root="$winroot/ospc2flex/drivers" sys32="$winroot/System32" infdir="$winroot/inf"
  local iso="$VIRTIO_ISO" token tokens bundle dir target candidate missing_required=0
  if [ "$WINDOWS_VERSION" = "2008r2" ] && [ -f "$LEGACY_VIRTIO_ISO" ]; then
    iso="$LEGACY_VIRTIO_ISO"
  fi
  mount_virtio_iso "$iso" || fail_exit "ZS5_OFFLINE_WINDOWS_REPAIR" "virtio_iso_mount_failed" "Set --virtio-iso to a readable virtio-win ISO."
  token="$(choose_driver_token)"
  tokens="$(driver_token_candidates || true)"
  [ -n "$token" ] && [ -n "$tokens" ] || fail_exit "ZS5_OFFLINE_WINDOWS_REPAIR" "windows_version_not_supported" "Pass --windows-version 2008r2, 2012r2, 2016, 2019, or 2022."
  log "[ZS5_OFFLINE_WINDOWS_REPAIR] Windows version requested=${WINDOWS_VERSION_REQUESTED}; effective=${WINDOWS_VERSION}; VirtIO token preference=$tokens"
  sudo mkdir -p "$drv_root" "$sys32" "$sys32/drivers" "$infdir"
  for bundle in viostor vioscsi NetKVM Balloon vioserial viorng; do
    dir=""
    for candidate in $tokens; do
      dir="$(find "$VIRTIO_MNT/$bundle" -type d -path "*/$candidate/amd64" 2>/dev/null | head -1 || true)"
      [ -n "$dir" ] && break
    done
    if [ -n "$dir" ]; then
      target="$drv_root/$bundle"
      sudo mkdir -p "$target"
      sudo cp -f "$dir"/* "$target/" 2>/dev/null || true
      sudo find "$target" -maxdepth 1 -iname '*.sys' -exec cp -f {} "$sys32/drivers/" \; 2>/dev/null || true
      sudo find "$target" -maxdepth 1 \( -iname '*.sys' -o -iname '*.inf' -o -iname '*.cat' \) -exec cp -f {} "$infdir/" \; 2>/dev/null || true
      sudo find "$target" -maxdepth 1 \( -iname '*.dll' -o -iname '*.exe' \) -exec cp -f {} "$sys32/" \; 2>/dev/null || true
      log "[ZS5_OFFLINE_WINDOWS_REPAIR] staged $bundle drivers from ${dir#$VIRTIO_MNT/}"
    else
      case "$bundle" in
        viostor|vioscsi|NetKVM)
          log "[ZS5_OFFLINE_WINDOWS_REPAIR] ERROR: $bundle amd64 driver not found for Windows $WINDOWS_VERSION in ISO"
          missing_required=1
          ;;
        *)
          log "[ZS5_OFFLINE_WINDOWS_REPAIR] WARN: $bundle amd64 driver not found for Windows $WINDOWS_VERSION in ISO"
          ;;
      esac
    fi
  done
  sudo umount "$VIRTIO_MNT" >/dev/null 2>&1 || true
  [ "$missing_required" = "0" ] || fail_exit "ZS5_OFFLINE_WINDOWS_REPAIR" "virtio_required_driver_missing" "Use a virtio-win ISO that contains drivers for Windows $WINDOWS_VERSION."
}

write_firstboot_network_reset() {
  local winroot="$1" program_data="$winroot/ProgramData/OSPC2FLEX" ps1
  ps1="$program_data/windows-network-reset.ps1"
  sudo mkdir -p "$program_data/logs" "$program_data/backup-network"
  sudo tee "$ps1" >/dev/null <<'EOF'
$Base = "C:\ProgramData\OSPC2FLEX"
$Done = Join-Path $Base "windows-network-reset.done"
$Log = Join-Path $Base "logs\windows-network-reset.log"
if (Test-Path $Done) { exit 0 }
New-Item -ItemType Directory -Force -Path (Join-Path $Base "backup-network") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Base "logs") | Out-Null
ipconfig /all > (Join-Path $Base "backup-network\ipconfig-all.txt")
route print > (Join-Path $Base "backup-network\route-print.txt")
netsh interface dump > (Join-Path $Base "backup-network\netsh-interface-dump.txt")
wmic nicconfig get Description,MACAddress,DHCPEnabled,IPAddress,IPSubnet,DefaultIPGateway,DNSServerSearchOrder /format:list > (Join-Path $Base "backup-network\wmic-nicconfig.txt")
& reg export "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" (Join-Path $Base "backup-network\tcpip-parameters.reg") /y | Out-Null
& reg export "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces" (Join-Path $Base "backup-network\tcpip-interfaces.reg") /y | Out-Null
netsh interface ip set address name="Local Area Connection" source=dhcp >> $Log 2>&1
netsh interface ip set dns name="Local Area Connection" source=dhcp >> $Log 2>&1
ipconfig /release >> $Log 2>&1
ipconfig /renew >> $Log 2>&1
Set-Content -Path $Done -Value (Get-Date).ToString("s")
EOF
}

apply_windows_bcd_boot_policy() {
  local winroot="$1" root bcd export reg loader_count
  root="$(dirname "$winroot")"
  for bcd in "$root/Boot/BCD" "$root/EFI/Microsoft/Boot/BCD"; do
    [ -f "$bcd" ] || continue
    export="$JOB_TMP/bcd_export.reg"
    reg="$JOB_TMP/bcd_boot_policy.reg"
    if ! sudo hivexregedit --export --unsafe-printable-strings "$bcd" '\Objects' >"$export" 2>>"$REPAIR_LOG"; then
      log "[ZS5_OFFLINE_WINDOWS_REPAIR] WARN: BCD export failed for ${bcd#$root/}"
      continue
    fi
    loader_count="$(python3 - "$export" "$reg" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(errors="ignore")
objects = {}
current = None
for line in text.splitlines():
    m = re.match(r"\[\\Objects\\(\{[0-9a-fA-F-]+\})(?:\\(.+))?\]", line)
    if m:
        current = m.group(1).lower()
        objects.setdefault(current, "")
    if current:
        objects[current] += line + "\n"

loaders = sorted(
    guid for guid, body in objects.items()
    if "winload.exe" in body.lower() or '"Type"=dword:10200003' in body
)

lines = ["Windows Registry Editor Version 5.00", ""]
for guid in loaders:
    lines.extend([
        f"[HKEY_LOCAL_MACHINE\\BCD\\Objects\\{guid}\\Elements\\16000009]",
        '"Element"=hex(3):00',
        "",
        f"[HKEY_LOCAL_MACHINE\\BCD\\Objects\\{guid}\\Elements\\250000e0]",
        '"Element"=hex(3):01,00,00,00,00,00,00,00',
        "",
    ])

Path(sys.argv[2]).write_text("\n".join(lines), encoding="ascii")
print(len(loaders))
PY
)"
    if [ "${loader_count:-0}" = "0" ]; then
      log "[ZS5_OFFLINE_WINDOWS_REPAIR] WARN: no Windows loader found in BCD ${bcd#$root/}"
      continue
    fi
    if sudo hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\BCD' "$bcd" "$reg" >>"$REPAIR_LOG" 2>&1; then
      log "[ZS5_OFFLINE_WINDOWS_REPAIR] applied BCD boot policy repair to ${bcd#$root/}"
    else
      log "[ZS5_OFFLINE_WINDOWS_REPAIR] WARN: BCD boot policy merge failed for ${bcd#$root/}"
    fi
  done
}

standalone_offline_windows_repair() {
  local ts winroot cfg hives backup_dir reg_file sw_reg
  ts="$(date -u +%Y%m%d-%H%M%S)"
  prepare_guest_mountpoint
  mount_windows_ntfs_nbd_rw
  winroot="$(find_windows_root)" || { cleanup_windows_mount; fail_exit "ZS5_OFFLINE_WINDOWS_REPAIR" "non_windows_image" "Windows/System32/config/SYSTEM was not found in the mounted image."; }
  [ -f "$winroot/System32/ntoskrnl.exe" ] || [ -f "$winroot/system32/ntoskrnl.exe" ] || { cleanup_windows_mount; fail_exit "ZS5_OFFLINE_WINDOWS_REPAIR" "windows_kernel_missing" "Windows ntoskrnl.exe was not found."; }
  cfg="$winroot/System32/config"
  backup_dir="$winroot/ospc2flex/registry-backups/$ts"
  sudo mkdir -p "$backup_dir"
  for hive in SYSTEM SOFTWARE SAM SECURITY DEFAULT; do
    [ -f "$cfg/$hive" ] || continue
    [ -f "$cfg/${hive}.ospc2flex.bak" ] || sudo cp -a "$cfg/$hive" "$cfg/${hive}.ospc2flex.bak"
    sudo cp -a "$cfg/$hive" "$backup_dir/$hive"
  done
  log "[ZS5_OFFLINE_WINDOWS_REPAIR] registry hives backed up to C:\\ospc2flex\\registry-backups\\$ts"
  stage_virtio_drivers "$winroot"
  write_firstboot_network_reset "$winroot"
  apply_windows_bcd_boot_policy "$winroot"

  reg_file="$JOB_TMP/snapwin_system.reg"
  cat >"$reg_file" <<'EOF'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\xenbus]
"Start"=dword:00000004

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\xenvbd]
"Start"=dword:00000004

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\xenfilt]
"Start"=dword:00000004

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\xenvif]
"Start"=dword:00000004

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\xeniface]
"Start"=dword:00000004

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\xennet]
"Start"=dword:00000004

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\xenpci]
"Start"=dword:00000004

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\xensvc]
"Start"=dword:00000004

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet002\Services\xenbus]
"Start"=dword:00000004

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet002\Services\xenvbd]
"Start"=dword:00000004

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet002\Services\xenfilt]
"Start"=dword:00000004

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet002\Services\xenvif]
"Start"=dword:00000004

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet002\Services\xeniface]
"Start"=dword:00000004

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet002\Services\xennet]
"Start"=dword:00000004

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet002\Services\xenpci]
"Start"=dword:00000004

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet002\Services\xensvc]
"Start"=dword:00000004

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\intelppm]
"Start"=dword:00000004

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\amdppm]
"Start"=dword:00000004

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\processr]
"Start"=dword:00000004

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet002\Services\intelppm]
"Start"=dword:00000004

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet002\Services\amdppm]
"Start"=dword:00000004

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet002\Services\processr]
"Start"=dword:00000004

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\intelide]
"Start"=dword:00000000

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\atapi]
"Start"=dword:00000000

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\pciide]
"Start"=dword:00000000

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\pciide\StartOverride]
"0"=dword:00000000

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\storahci]
"Start"=dword:00000000

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\storahci\StartOverride]
"0"=dword:00000000

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\msahci]
"Start"=dword:00000000

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\iaStorV]
"Start"=dword:00000000

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\iaStorV\StartOverride]
"0"=dword:00000000

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet002\Services\intelide]
"Start"=dword:00000000

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet002\Services\atapi]
"Start"=dword:00000000

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet002\Services\pciide]
"Start"=dword:00000000

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet002\Services\pciide\StartOverride]
"0"=dword:00000000

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet002\Services\storahci]
"Start"=dword:00000000

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet002\Services\storahci\StartOverride]
"0"=dword:00000000

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet002\Services\msahci]
"Start"=dword:00000000

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet002\Services\iaStorV]
"Start"=dword:00000000

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet002\Services\iaStorV\StartOverride]
"0"=dword:00000000

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\viostor]
"Type"=dword:00000001
"Start"=dword:00000000
"ErrorControl"=dword:00000001
"Group"="SCSI miniport"
"ImagePath"="system32\\drivers\\viostor.sys"

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\viostor\StartOverride]
"0"=dword:00000000

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\vioscsi]
"Type"=dword:00000001
"Start"=dword:00000000
"ErrorControl"=dword:00000001
"Group"="SCSI miniport"
"ImagePath"="system32\\drivers\\vioscsi.sys"

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\vioscsi\StartOverride]
"0"=dword:00000000

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet002\Services\viostor]
"Type"=dword:00000001
"Start"=dword:00000000
"ErrorControl"=dword:00000001
"Group"="SCSI miniport"
"ImagePath"="system32\\drivers\\viostor.sys"

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet002\Services\viostor\StartOverride]
"0"=dword:00000000

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet002\Services\vioscsi]
"Type"=dword:00000001
"Start"=dword:00000000
"ErrorControl"=dword:00000001
"Group"="SCSI miniport"
"ImagePath"="system32\\drivers\\vioscsi.sys"

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet002\Services\vioscsi\StartOverride]
"0"=dword:00000000

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\CriticalDeviceDatabase]

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1001]
"ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"
"Service"="viostor"

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1042]
"ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"
"Service"="viostor"

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1004]
"ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"
"Service"="vioscsi"

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1048]
"ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"
"Service"="vioscsi"

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet002\Control\CriticalDeviceDatabase]

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet002\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1001]
"ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"
"Service"="viostor"

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet002\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1042]
"ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"
"Service"="viostor"

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet002\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1004]
"ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"
"Service"="vioscsi"

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet002\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1048]
"ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"
"Service"="vioscsi"

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\Class\{4D36E97D-E325-11CE-BFC1-08002BE10318}]
"UpperFilters"=hex(7):00,00

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet002\Control\Class\{4D36E97D-E325-11CE-BFC1-08002BE10318}]
"UpperFilters"=hex(7):00,00
EOF
  merge_system_reg "$reg_file" "$cfg/SYSTEM" || log "[ZS5_OFFLINE_WINDOWS_REPAIR] WARN: SYSTEM registry merge returned non-zero; inspect $REPAIR_LOG"

  sw_reg="$JOB_TMP/snapwin_software.reg"
  cat >"$sw_reg" <<'EOF'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce]
"ospc2flex_snapwin_network_reset"="cmd.exe /c powershell.exe -ExecutionPolicy Bypass -File C:\\ProgramData\\OSPC2FLEX\\windows-network-reset.ps1"
EOF
  merge_software_reg "$sw_reg" "$cfg/SOFTWARE" || log "[ZS5_OFFLINE_WINDOWS_REPAIR] WARN: SOFTWARE RunOnce merge returned non-zero; inspect $REPAIR_LOG"

  cleanup_windows_mount
  write_repair_marker "$QCOW2"
  touch "${QCOW2}.win_repaired"
}

write_report() {
  python3 - "$STATE_JSON" "$JOB_REPORT/method_snapwin_report.json" "$JOB_REPORT/method_snapwin_summary.txt" <<'PY'
import json, sys
from pathlib import Path
doc = json.load(open(sys.argv[1], encoding="utf-8"))
Path(sys.argv[2]).write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
lines = [
    f"Method: {doc.get('method')}",
    f"Status: {doc.get('status')}",
    f"Label: {doc.get('label')}",
    f"Run ID: {doc.get('run_id')}",
    f"Source artifact: {doc.get('source_artifact')}",
    f"QCOW2 artifact: {doc.get('qcow2_artifact')}",
    f"Rescue image: {doc.get('rescue_image_id')}",
    f"Final image: {doc.get('final_image_id')}",
    f"Final server: {doc.get('final_server_id')}",
    f"Failure reason: {doc.get('failure_reason')}",
    f"Next action: {doc.get('next_action')}",
]
Path(sys.argv[3]).write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
}

write_initial_state

stage_start "ZS0_PREFLIGHT"
BASE_CMDS=(qemu-img openstack jq curl rsync python3)
REPAIR_CMDS=(guestmount guestunmount qemu-nbd hivexsh reged chntpw ntfs-3g ntfsfix 7z)
install_missing_prereqs "${BASE_CMDS[@]}"
if [ "$DOWNLOAD_ONLY" != 1 ]; then
  install_missing_prereqs "${REPAIR_CMDS[@]}"
fi
for c in "${BASE_CMDS[@]}"; do
  require_cmd "$c"
done
if [ "$DOWNLOAD_ONLY" != 1 ]; then
  for c in "${REPAIR_CMDS[@]}"; do
    require_cmd "$c"
  done
  ensure_libguestfs_kernel_readable
else
  log "[ZS0_PREFLIGHT] download-only mode: deferred offline-repair dependency checks (guestmount/qemu-nbd/hivex/reged/chntpw)"
fi
ensure_virtio_iso "$VIRTIO_ISO" "$VIRTIO_ISO_URL" "virtio-win ISO" 50000000
if [ "$WINDOWS_VERSION" = "2008r2" ] || [ "$WINDOWS_VERSION" = "2k8r2" ]; then
  ensure_virtio_iso "$LEGACY_VIRTIO_ISO" "$LEGACY_VIRTIO_ISO_URL" "legacy virtio-win 0.1.108 ISO" 30000000
fi
if mount | grep -q "$RUN_DIR"; then
  fail_exit "ZS0_PREFLIGHT" "stale_guestmount_mount" "Unmount stale guestmount paths under $RUN_DIR."
fi
checkpoint_hit "preflight"
log "[ZS0_PREFLIGHT] HIT dependencies checked; /dev/kvm is not required and no Method D/G/H/v2 helper is used"

if [ "$DRY_RUN" = 1 ]; then
  for s in ZS1_LOAD_CREDENTIALS ZS2_SELECT_SNAPSHOT ZS3_DOWNLOAD_SNAPSHOT ZS4_NORMALIZE_QCOW2 ZS5_OFFLINE_WINDOWS_REPAIR ZS6_UPLOAD_FLEX_RESCUE_IMAGE ZS7_BOOT_FLEX_RESCUE_VM ZS8_ATTACH_DUMMY_VIRTIO ZS9_DRIVER_BIND ZS10_SNAPSHOT_VIRTIO_READY ZS11_BOOT_FINAL_FLEX_VM ZS12_VALIDATE_AND_REPORT; do
    stage_start "$s"
    cp="$(checkpoint_for_stage "$s")"
    [ -n "$cp" ] && checkpoint_hit "$cp"
    log "[$s] DRY-RUN standalone SNAPWIN stage; no source snapshot creation, SSH raw capture, local KVM, virt-install, virsh, or helper-script handoff"
  done
  json_merge "{\"stage\":\"ZS12_VALIDATE_AND_REPORT\",\"status\":\"METHOD_SNAPWIN_SUCCESS\",\"source_artifact\":\"DRY_RUN\",\"qcow2_artifact\":\"$QCOW2\",\"final\":true}"
  write_report
  echo "METHOD_SNAPWIN_SUCCESS"
  exit 0
fi

stage_start "ZS1_LOAD_CREDENTIALS"
source_openrc_if_present "$OSPC_OPENRC"
OSPC_TOKEN="$(rackspace_identity_v2_auth || true)"
[ -n "$OSPC_TOKEN" ] || fail_exit "ZS1_LOAD_CREDENTIALS" "ospc_v2_token_issue_failed" "Use the same OSPC username/API key/account ID as the private snapshot scanner."
log "[ZS1_LOAD_CREDENTIALS] Rackspace Identity v2 auth succeeded"
redacted_env_snapshot "$JOB_STATE/ospc_env_redacted.txt"
checkpoint_hit "preflight"
log "[ZS1_LOAD_CREDENTIALS] HIT OSPC credentials validated"

stage_start "ZS2_SELECT_SNAPSHOT"
if [ -z "$OSPC_IMAGE_ID" ] && [ -n "$OSPC_SNAPSHOT_ID" ]; then
  OSPC_IMAGE_ID="$OSPC_SNAPSHOT_ID"
fi
if [ -n "$LOCAL_ARTIFACT" ]; then
  [ -f "$LOCAL_ARTIFACT" ] || fail_exit "ZS2_SELECT_SNAPSHOT" "local_artifact_missing" "Check --local-artifact path."
elif [ -n "$OSPC_IMAGE_ID" ]; then
  ospc_image_exists "$OSPC_IMAGE_ID" || fail_exit "ZS2_SELECT_SNAPSHOT" "ospc_image_not_found" "Choose a valid existing OSPC snapshot/image ID from the cold scan."
else
  count="$(list_snapshot_candidates | tail -1)"
  json_merge "{\"stage\":\"ZS2_SELECT_SNAPSHOT\",\"status\":\"WAITING_FOR_SNAPSHOT_SELECTION\",\"failure_reason\":\"\",\"next_action\":\"Choose an OSPC snapshot/image ID.\",\"checkpoints\":{\"snapshot_selected\":\"PENDING\"}}"
  log "[ZS2_SELECT_SNAPSHOT] WAITING_FOR_SNAPSHOT_SELECTION candidates=$count"
  exit 0
fi
json_merge "{\"ospc_image_id\":\"$OSPC_IMAGE_ID\",\"ospc_snapshot_id\":\"$OSPC_SNAPSHOT_ID\"}"
checkpoint_hit "snapshot_selected"
log "[ZS2_SELECT_SNAPSHOT] HIT selected existing snapshot/image: ${OSPC_IMAGE_ID:-$LOCAL_ARTIFACT}"

stage_start "ZS3_DOWNLOAD_SNAPSHOT"
# List available non-repaired qcow2 candidates for this label only
if [ -d "$BASE_DIR/runs/$LABEL_SAFE" ]; then
  while IFS= read -r _f; do
    log "[ZS3_DOWNLOAD_SNAPSHOT] available qcow2: $_f ($(stat -c%s "$_f" 2>/dev/null | awk '{printf "%.1f GB", $1/1024/1024/1024}'))"
  done < <(find "$BASE_DIR/runs/$LABEL_SAFE" -type f -name "*.qcow2" -size +1G -printf '%s %p\n' 2>/dev/null | sort -nr | awk '{ $1=""; sub(/^ /, ""); print }')
fi
if [ -n "$LOCAL_ARTIFACT" ]; then
  log "[ZS3_DOWNLOAD_SNAPSHOT] Using existing local artifact: $LOCAL_ARTIFACT"
  SOURCE_FORMAT="$(detect_format "$LOCAL_ARTIFACT")"
  if [ "${OSPC2FLEX_LOCAL_ARTIFACT_IN_PLACE:-0}" = "1" ]; then
    SOURCE_ARTIFACT="$LOCAL_ARTIFACT"
    log "[ZS3_DOWNLOAD_SNAPSHOT] Local artifact in-place mode enabled; avoiding duplicate copy."
  else
    case "$SOURCE_FORMAT" in
      qcow2) SOURCE_ARTIFACT="$JOB_ART/source_snapshot.qcow2" ;;
      raw) SOURCE_ARTIFACT="$JOB_ART/source_snapshot.raw" ;;
      vpc) SOURCE_ARTIFACT="$JOB_ART/source_snapshot.vhd" ;;
      vhdx) SOURCE_ARTIFACT="$JOB_ART/source_snapshot.vhdx" ;;
      *) SOURCE_ARTIFACT="$JOB_ART/source_snapshot.img" ;;
    esac
    safe_cp_source "$LOCAL_ARTIFACT" "$SOURCE_ARTIFACT"
  fi
else
  RESUME_ARTIFACT="$(find_resume_artifact || true)"
  if [ -n "$RESUME_ARTIFACT" ]; then
    log "[ZS3_DOWNLOAD_SNAPSHOT] HIT auto-resume artifact found on jumphost: $RESUME_ARTIFACT"
    SOURCE_ARTIFACT="$RESUME_ARTIFACT"
  else
    SOURCE_ARTIFACT="$JOB_ART/source_snapshot.img"
    set +e
    download_existing_ospc_snapshot "$OSPC_IMAGE_ID" "$SOURCE_ARTIFACT"
    dl_rc=$?
    set -e
    [ "$dl_rc" -eq 0 ] || fail_exit "ZS3_DOWNLOAD_SNAPSHOT" "$DOWNLOAD_FAILURE_REASON" "$DOWNLOAD_NEXT_ACTION"
  fi
  SOURCE_FORMAT="$(detect_format "$SOURCE_ARTIFACT")"
fi
validate_artifact "$SOURCE_ARTIFACT"
json_merge "{\"source_artifact\":\"$SOURCE_ARTIFACT\"}"
checkpoint_hit "snapshot_downloaded"
log "[ZS3_DOWNLOAD_SNAPSHOT] HIT source artifact ready: $SOURCE_ARTIFACT format=$SOURCE_FORMAT"

stage_start "ZS4_NORMALIZE_QCOW2"
SOURCE_FORMAT="$(detect_format "$SOURCE_ARTIFACT")"
case "$SOURCE_FORMAT" in
  qcow2)
    log "[ZS4_NORMALIZE_QCOW2] Source already qcow2; using in place: $SOURCE_ARTIFACT"
    QCOW2="$SOURCE_ARTIFACT"
    ;;
  raw)
    qemu_convert_to_qcow2 "$SOURCE_ARTIFACT" "$QCOW2" -f raw
    ;;
  vpc|vhdx)
    qemu-img check -r all -f "$SOURCE_FORMAT" "$SOURCE_ARTIFACT" >>"$BACKGROUND_LOG" 2>&1 || true
    qemu_convert_to_qcow2 "$SOURCE_ARTIFACT" "$QCOW2" -f "$SOURCE_FORMAT"
    ;;
  unknown)
    qemu_convert_to_qcow2 "$SOURCE_ARTIFACT" "$QCOW2"
    ;;
  *)
    qemu_convert_to_qcow2 "$SOURCE_ARTIFACT" "$QCOW2"
    ;;
esac
[ -s "$QCOW2" ] || fail_exit "ZS4_NORMALIZE_QCOW2" "qcow2_zero_size" "Repeat source download/export."
qemu-img info "$QCOW2" >>"$BACKGROUND_LOG" 2>&1 || fail_exit "ZS4_NORMALIZE_QCOW2" "qcow2_info_failed" "Check qemu-img output."
qemu-img check "$QCOW2" >>"$BACKGROUND_LOG" 2>&1 || fail_exit "ZS4_NORMALIZE_QCOW2" "qcow2_check_failed" "Repair source artifact or repeat conversion."
json_merge "{\"qcow2_artifact\":\"$QCOW2\"}"
checkpoint_hit "qcow2_normalized"
log "[ZS4_NORMALIZE_QCOW2] HIT normalized qcow2: $QCOW2"

if [ "$DOWNLOAD_ONLY" = 1 ]; then
  json_merge "{\"stage\":\"ZS4_NORMALIZE_QCOW2\",\"status\":\"METHOD_SNAPWIN_DOWNLOAD_READY\",\"final\":false,\"next_action\":\"Download-only test completed; rerun without --download-only to continue offline repair and Flex boot.\"}"
  write_report
  log "[ZS4_NORMALIZE_QCOW2] HIT METHOD_SNAPWIN_DOWNLOAD_READY download-only stop requested"
  echo "METHOD_SNAPWIN_DOWNLOAD_READY"
  exit 0
fi

stage_start "ZS5_OFFLINE_WINDOWS_REPAIR"
standalone_offline_windows_repair
is_current_repaired_qcow "$QCOW2" || fail_exit "ZS5_OFFLINE_WINDOWS_REPAIR" "snapwin_repair_marker_missing" "Inspect $REPAIR_LOG."
qemu-img check "$QCOW2" >>"$BACKGROUND_LOG" 2>&1 || fail_exit "ZS5_OFFLINE_WINDOWS_REPAIR" "post_repair_qcow2_check_failed" "Use registry backup or fresh source export."
checkpoint_hit "offline_repair"
log "[ZS5_OFFLINE_WINDOWS_REPAIR] HIT standalone offline Windows repair complete"

stage_start "ZS6_UPLOAD_FLEX_RESCUE_IMAGE"
source_openrc_if_present "$FLEX_OPENRC"
resolve_flex_region_after_openrc
redacted_env_snapshot "$JOB_STATE/flex_env_redacted.txt"
json_merge "{\"flex_region\":\"$FLEX_REGION\"}"
log "[ZS6_UPLOAD_FLEX_RESCUE_IMAGE] FLEX region: ${OS_REGION_NAME:-unset}"
check_flex_glance_access || fail_exit "ZS6_UPLOAD_FLEX_RESCUE_IMAGE" "flex_glance_auth_failed" "Flex Keystone token works only if Glance also accepts it. Check FLEX project/region/API credentials; see $JOB_LOG/flex_image_access.log."
RESCUE_IMAGE_ID=""
if [ "${OSPC2FLEX_SNAPWIN_REUSE_RESCUE_IMAGE:-0}" = "1" ]; then
  RESCUE_IMAGE_ID="$(find_existing_rescue_image || true)"
else
  log "[ZS6_UPLOAD_FLEX_RESCUE_IMAGE] Rescue image reuse disabled; uploading fresh repaired qcow2."
fi
if [ -n "$RESCUE_IMAGE_ID" ]; then
  log "[ZS6_UPLOAD_FLEX_RESCUE_IMAGE] Reusing existing active rescue image: $RESCUE_IMAGE_ID"
else
  upload_flex_rescue_image_method_ab || fail_exit "ZS6_UPLOAD_FLEX_RESCUE_IMAGE" "rescue_image_upload_failed" "Method A/B Glance upload path failed after 3 attempts; inspect $BACKGROUND_LOG."
fi
[ -n "$RESCUE_IMAGE_ID" ] || fail_exit "ZS6_UPLOAD_FLEX_RESCUE_IMAGE" "rescue_image_upload_failed" "Method A/B Glance upload path returned no image id; inspect $BACKGROUND_LOG."
z_wait_for_image_active "$RESCUE_IMAGE_ID" 1800 || fail_exit "ZS6_UPLOAD_FLEX_RESCUE_IMAGE" "rescue_image_not_active" "Inspect Flex Glance image status."
openstack image set "$RESCUE_IMAGE_ID" \
  --property architecture=x86_64 \
  --property hw_disk_bus=ide \
  --property hw_cdrom_bus=ide \
  --property hw_vif_model=e1000 \
  --property hw_qemu_guest_agent=yes \
  --property os_type=windows \
  --property os_distro=windows \
  --property vm_mode=hvm \
  --property ospc2flex_method=SNAPWIN_STANDALONE \
  --property ospc2flex_run_id="$RUN_ID" >>"$BACKGROUND_LOG" 2>&1
json_merge "{\"rescue_image_id\":\"$RESCUE_IMAGE_ID\"}"
checkpoint_hit "flex_upload"
log "[ZS6_UPLOAD_FLEX_RESCUE_IMAGE] HIT rescue image ready: $RESCUE_IMAGE_ID"

if [ "$SKIP_RESCUE_BOOT" = 1 ]; then
  json_merge "{\"stage\":\"ZS6_UPLOAD_FLEX_RESCUE_IMAGE\",\"status\":\"WAITING_FOR_DRIVER_BIND\",\"next_action\":\"Rescue boot was skipped by request; boot image manually or rerun without --skip-rescue-boot.\"}"
  write_report
  exit 0
fi

stage_start "ZS7_BOOT_FLEX_RESCUE_VM"
DUMMY_VOLUME_ID="$(find_available_dummy_volume || true)"
if [ -n "$DUMMY_VOLUME_ID" ]; then
  log "[ZS7_BOOT_FLEX_RESCUE_VM] Reusing available dummy VirtIO volume for boot-time attach: $DUMMY_VOLUME_ID"
else
  log "[ZS7_BOOT_FLEX_RESCUE_VM] Creating ${DUMMY_VOLUME_SIZE_GB}GB dummy VirtIO volume for boot-time attach"
  DUMMY_VOLUME_ID="$(openstack volume create --size "$DUMMY_VOLUME_SIZE_GB" "$DUMMY_VOLUME_NAME" -f value -c id 2>>"$BACKGROUND_LOG" | tr -d '\r\n' || true)"
  [ -n "$DUMMY_VOLUME_ID" ] || fail_exit "ZS7_BOOT_FLEX_RESCUE_VM" "dummy_volume_create_failed" "Inspect Cinder quota/status."
fi
wait_volume_status "$DUMMY_VOLUME_ID" "available" || fail_exit "ZS7_BOOT_FLEX_RESCUE_VM" "dummy_volume_not_available" "Inspect Cinder volume status."
json_merge "{\"dummy_volume_id\":\"$DUMMY_VOLUME_ID\"}"
RESCUE_SERVER_ID="$(find_existing_rescue_server || true)"
if [ -n "$RESCUE_SERVER_ID" ]; then
  log "[ZS7_BOOT_FLEX_RESCUE_VM] Reusing existing ACTIVE rescue VM with dummy volume attached: $RESCUE_SERVER_ID"
else
  create_args=(server create "$RESCUE_SERVER_NAME" --image "$RESCUE_IMAGE_ID" --flavor "$FLAVOR" --network "$NETWORK" --wait -f value -c id)
  EFFECTIVE_KEYPAIR="$(effective_keypair)"
  [ -n "$EFFECTIVE_KEYPAIR" ] && create_args+=(--key-name "$EFFECTIVE_KEYPAIR")
  [ -n "$SECURITY_GROUP" ] && create_args+=(--security-group "$SECURITY_GROUP")
  create_args+=(--block-device "uuid=$DUMMY_VOLUME_ID,source_type=volume,destination_type=volume,boot_index=-1,delete_on_termination=false")
  RESCUE_SERVER_ID="$(openstack "${create_args[@]}" 2>>"$BACKGROUND_LOG" | tr -d '\r\n' || true)"
fi
[ -n "$RESCUE_SERVER_ID" ] || fail_exit "ZS7_BOOT_FLEX_RESCUE_VM" "rescue_server_create_failed" "Inspect rescue image metadata and Nova boot request."
z_wait_for_server_status "$RESCUE_SERVER_ID" "ACTIVE" 900 || fail_exit "ZS7_BOOT_FLEX_RESCUE_VM" "rescue_server_not_active" "Inspect rescue VM console."
wait_volume_status "$DUMMY_VOLUME_ID" "in-use" || fail_exit "ZS7_BOOT_FLEX_RESCUE_VM" "dummy_volume_attach_failed" "FLEX did not attach the dummy VirtIO volume during rescue VM boot."
server_has_volume "$RESCUE_SERVER_ID" "$DUMMY_VOLUME_ID" || fail_exit "ZS7_BOOT_FLEX_RESCUE_VM" "dummy_volume_attach_missing" "Nova server details do not show the dummy VirtIO volume."
RESCUE_FLOATING_IP="$(z_attach_floating_ip "$RESCUE_SERVER_ID" || true)"
if console_has_fatal_boot_error "$RESCUE_SERVER_ID"; then console_rc=0; else console_rc=$?; fi
if [ "$console_rc" -eq 2 ]; then fail_exit "ZS7_BOOT_FLEX_RESCUE_VM" "WINDOWS_SYSTEM_HIVE_OR_REGISTRY_STOP" "Inspect rescue console and restore SYSTEM hive backup."; fi
if [ "$console_rc" -eq 3 ]; then fail_exit "ZS7_BOOT_FLEX_RESCUE_VM" "INACCESSIBLE_BOOT_DEVICE" "Inspect rescue console and offline VirtIO repair."; fi
json_merge "{\"rescue_server_id\":\"$RESCUE_SERVER_ID\"}"
checkpoint_hit "rescue_boot"
log "[ZS7_BOOT_FLEX_RESCUE_VM] HIT rescue VM ACTIVE: $RESCUE_SERVER_ID fip=${RESCUE_FLOATING_IP:-none}"

stage_start "ZS8_ATTACH_DUMMY_VIRTIO"
checkpoint_hit "dummy_attach"
log "[ZS8_ATTACH_DUMMY_VIRTIO] HIT dummy VirtIO volume attached at rescue boot: $DUMMY_VOLUME_ID"

stage_start "ZS9_DRIVER_BIND"
if [ "${OSPC2FLEX_SNAPWIN_FORCE_MANUAL_BIND:-0}" = "1" ]; then
  show_manual_driver_card
  json_merge "{\"stage\":\"ZS9_DRIVER_BIND\",\"status\":\"WAITING_FOR_DRIVER_BIND\",\"next_action\":\"Run the displayed pnputil commands in the rescue VM, reboot, then continue Method SNAPWIN.\",\"checkpoints\":{\"driver_bind\":\"PENDING\"}}"
  log "[ZS9_DRIVER_BIND] WAITING_FOR_DRIVER_BIND manual confirmation required"
  write_report
  exit 0
fi

if [ "$MANUAL_DRIVER_BIND" = 1 ]; then
  log "[ZS9_DRIVER_BIND] WARN --manual-driver-bind is deprecated; SNAPWIN will auto-bind unless OSPC2FLEX_SNAPWIN_FORCE_MANUAL_BIND=1."
fi

SNAPWIN_ONLINE_BIND=0
if [ -n "$WIN_PASSWORD" ] && z_wait_for_windows_access "$RESCUE_SERVER_ID" "$HEALTHCHECK_WAIT"; then
  run_driver_binding || fail_exit "ZS9_DRIVER_BIND" "virtio_driver_binding_failed" "Use console/RDP and manual pnputil bind."
  SNAPWIN_ONLINE_BIND=1
  log "[ZS9_DRIVER_BIND] HIT VirtIO driver bind completed over $ACCESS_METHOD on $ACCESS_IP:$ACCESS_PORT"
else
  log "[ZS9_DRIVER_BIND] WinRM not available or no Windows password supplied; using offline-staged VirtIO drivers and registry/CDDB boot binding."
  log "[ZS9_DRIVER_BIND] HIT offline VirtIO bind path accepted (no rescue reboot — matching win2016 working method)"
fi
checkpoint_hit "driver_bind"
log "[ZS9_DRIVER_BIND] HIT VirtIO driver bind confirmed"

stage_start "ZS10_SNAPSHOT_VIRTIO_READY"
openstack server stop "$RESCUE_SERVER_ID" >>"$BACKGROUND_LOG" 2>&1 || true
z_wait_for_server_status "$RESCUE_SERVER_ID" "SHUTOFF" 900 || fail_exit "ZS10_SNAPSHOT_VIRTIO_READY" "rescue_server_stop_failed" "Inspect rescue VM."
FINAL_IMAGE_ID="$(openstack server image create "$RESCUE_SERVER_ID" --name "$FINAL_IMAGE_NAME" -f value -c id 2>>"$BACKGROUND_LOG" | tr -d '\r\n' || true)"
[ -n "$FINAL_IMAGE_ID" ] || fail_exit "ZS10_SNAPSHOT_VIRTIO_READY" "final_snapshot_failed" "Inspect rescue VM snapshot task."
z_wait_for_image_active "$FINAL_IMAGE_ID" 1800 || fail_exit "ZS10_SNAPSHOT_VIRTIO_READY" "final_image_not_active" "Inspect Flex Glance image status."
if [ "$SNAPWIN_ONLINE_BIND" = "1" ]; then
  log "[ZS10_SNAPSHOT_VIRTIO_READY] Online driver bind confirmed; setting final image to virtio-scsi/virtio."
  openstack image set "$FINAL_IMAGE_ID" \
    --property hw_disk_bus=scsi \
    --property hw_scsi_model=virtio-scsi \
    --property hw_vif_model=virtio \
    --property hw_qemu_guest_agent=yes \
    --property os_type=windows \
    --property os_distro=windows \
    --property ospc2flex_method=SNAPWIN_STANDALONE \
    --property ospc2flex_run_id="$RUN_ID" >>"$BACKGROUND_LOG" 2>&1
else
  log "[ZS10_SNAPSHOT_VIRTIO_READY] No online driver bind confirmation; keeping final image on IDE/e1000 safe boot metadata."
  openstack image set "$FINAL_IMAGE_ID" \
    --property architecture=x86_64 \
    --property hw_disk_bus=ide \
    --property hw_cdrom_bus=ide \
    --property hw_vif_model=e1000 \
    --property hw_qemu_guest_agent=yes \
    --property os_type=windows \
    --property os_distro=windows \
    --property vm_mode=hvm \
    --property ospc2flex_method=SNAPWIN_STANDALONE \
    --property ospc2flex_run_id="$RUN_ID" >>"$BACKGROUND_LOG" 2>&1
fi
json_merge "{\"final_image_id\":\"$FINAL_IMAGE_ID\"}"
checkpoint_hit "final_snapshot"
log "[ZS10_SNAPSHOT_VIRTIO_READY] HIT final Windows image: $FINAL_IMAGE_ID"

stage_start "ZS11_BOOT_FINAL_FLEX_VM"
final_args=(server create "$FINAL_SERVER_NAME" --image "$FINAL_IMAGE_ID" --flavor "$FLAVOR" --network "$NETWORK" --wait -f value -c id)
EFFECTIVE_KEYPAIR="$(effective_keypair)"
[ -n "$EFFECTIVE_KEYPAIR" ] && final_args+=(--key-name "$EFFECTIVE_KEYPAIR")
[ -n "$SECURITY_GROUP" ] && final_args+=(--security-group "$SECURITY_GROUP")
FINAL_SERVER_ID="$(openstack "${final_args[@]}" 2>>"$BACKGROUND_LOG" | tr -d '\r\n' || true)"
[ -n "$FINAL_SERVER_ID" ] || fail_exit "ZS11_BOOT_FINAL_FLEX_VM" "final_server_create_failed" "Inspect final image metadata and Nova request."
z_wait_for_server_status "$FINAL_SERVER_ID" "ACTIVE" 900 || fail_exit "ZS11_BOOT_FINAL_FLEX_VM" "final_server_not_active" "Inspect final VM console."
FINAL_FLOATING_IP="$(z_attach_floating_ip "$FINAL_SERVER_ID" || true)"
sleep "${OSPC2FLEX_SNAPWIN_FINAL_BOOT_SETTLE_SECONDS:-180}"
if console_has_fatal_boot_error "$FINAL_SERVER_ID"; then console_rc=0; else console_rc=$?; fi
if [ "$console_rc" -eq 2 ]; then fail_exit "ZS11_BOOT_FINAL_FLEX_VM" "WINDOWS_SYSTEM_HIVE_OR_REGISTRY_STOP" "Inspect final VM console and restore SYSTEM hive backup."; fi
if [ "$console_rc" -eq 3 ]; then fail_exit "ZS11_BOOT_FINAL_FLEX_VM" "INACCESSIBLE_BOOT_DEVICE" "Final Windows boot hit INACCESSIBLE_BOOT_DEVICE; do not mark success."; fi
json_merge "{\"final_server_id\":\"$FINAL_SERVER_ID\"}"
checkpoint_hit "final_boot"
log "[ZS11_BOOT_FINAL_FLEX_VM] HIT final VM ACTIVE: $FINAL_SERVER_ID fip=${FINAL_FLOATING_IP:-none}"

stage_start "ZS12_VALIDATE_AND_REPORT"
openstack server show "$FINAL_SERVER_ID" >>"$BACKGROUND_LOG" 2>&1 || fail_exit "ZS12_VALIDATE_AND_REPORT" "final_server_show_failed" "Inspect final server ID."
openstack console log show "$FINAL_SERVER_ID" >>"$BACKGROUND_LOG" 2>&1 || true
checkpoint_hit "validation"
json_merge "{\"stage\":\"ZS12_VALIDATE_AND_REPORT\",\"status\":\"METHOD_SNAPWIN_SUCCESS\",\"final\":true}"
write_report
log "[ZS12_VALIDATE_AND_REPORT] HIT METHOD_SNAPWIN_SUCCESS"
echo "METHOD_SNAPWIN_SUCCESS"
