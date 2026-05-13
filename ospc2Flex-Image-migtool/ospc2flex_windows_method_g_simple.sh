#!/usr/bin/env bash
# Method G Simple — SSH Capture + Dummy VirtIO Boot
#
# Clean SSH-only Method G:
#   Method B/D-style SSH disk capture first, then Method G safe IDE/e1000
#   boot, dummy VirtIO binding, final virtio-scsi boot, and final validation.

set -euo pipefail

if [ -z "${OSPC2FLEX_LINEBUF_WRAPPER:-}" ] && command -v stdbuf >/dev/null 2>&1; then
  export OSPC2FLEX_LINEBUF_WRAPPER=1
  exec stdbuf -oL -eL bash "$0" "$@"
fi

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SELF_DIR}/ospc2flex_windows_method_g_simple_lib.sh"

export OSPC2FLEX_METHOD_G_SIMPLE=1
export OSPC2FLEX_ALLOW_GUEST_DISK_CAPTURE=1
export OSPC2FLEX_ALLOW_RAW_SSH_CAPTURE=1
export OSPC2FLEX_WINDOWS_ALLOW_RAW_PHYSICALDRIVE_READ=1
export OSPC2FLEX_ALLOW_WINDOWS_GLANCE_FALLBACK=0
export OSPC2FLEX_ALLOW_PROVIDER_EXPORT_FALLBACK=0
export OSPC2FLEX_ALLOW_DISK2VHD=0
export OSPC2FLEX_ALLOW_VSS_CAPTURE=0
export OSPC2FLEX_ALLOW_SMB_HTTPS_OBJECT_TRANSFER=0
export OSPC2FLEX_ALLOW_WINRM_AGENT_CAPTURE=0

SERVER_NAME=""
SERVER_IP=""
LABEL=""
WIN_USER="Administrator"
WIN_PASSWORD=""
WIN_SNET_IP=""
FLAVOR="${MIG_FLAVOR:-gp.0.4.4}"
NETWORK="${MIG_NETWORK:-tenant-net}"
KEYPAIR=""
WORK="${WORK:-/mnt/migration/ospc2flex_image}"
export FLEX_EXT_NET="${OSPC2FLEX_FLEX_EXT_NET:-PUBLICNET}"
FLEX_CREDS="${FLEX_CREDS:-/tmp/ospc2flex_flex.sh}"
WIN_REPAIR="${WIN_REPAIR:-/tmp/ospc2flex_windows_repair.sh}"
METHOD_B_CAPTURE_SCRIPT="${OSPC2FLEX_METHOD_B_CAPTURE_SCRIPT:-/tmp/ospc2flex_windows_method_d_capture.sh}"
HEALTHCHECK_WAIT="${OSPC2FLEX_HEALTHCHECK_WAIT:-1200}"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-name) SERVER_NAME="$2"; shift 2 ;;
    --server-ip) SERVER_IP="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --windows-user) WIN_USER="$2"; shift 2 ;;
    --windows-password) WIN_PASSWORD="$2"; shift 2 ;;
    --flavor) FLAVOR="$2"; shift 2 ;;
    --network) NETWORK="$2"; shift 2 ;;
    --keypair) KEYPAIR="$2"; shift 2 ;;
    --server-snet-ip) WIN_SNET_IP="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --os-family|--os-type|--source-server-id|--cloudboot-target-host|--cloudboot-target-user|--cloudboot-target-password|--cloudboot-source-winrm-host|--cloudboot-target-winrm-host)
      shift 2 ;;
    *) shift ;;
  esac
done

[ -n "$LABEL" ] || { echo "ERROR: --label required"; exit 2; }
[ -n "$SERVER_IP" ] || { echo "ERROR: --server-ip required"; exit 2; }
[ -n "$WIN_PASSWORD" ] || { echo "ERROR: --windows-password required for Method G Simple"; exit 2; }
SERVER_NAME="${SERVER_NAME:-$LABEL}"

LOG_DIR="$WORK/logs"
mkdir -p "$LOG_DIR"
PROGRESS_LOG="$LOG_DIR/${LABEL}.progress.log"
BACKGROUND_LOG="$LOG_DIR/${LABEL}.background.log"
STATE_JSON="$WORK/${LABEL}.method_g_simple.json"
QCOW="$WORK/${LABEL}.qcow2"
RESCUE_IMAGE_NAME="${LABEL}-mgs-safe-ide-img"
RESCUE_SERVER_NAME="${LABEL}-mgs-safe-ide"
FINAL_IMAGE_NAME="${LABEL}-mgs-virtio-ready-img"
FINAL_SERVER_NAME="${LABEL}-mgs-final-virtio"
DUMMY_VOLUME_NAME="${LABEL}-dummy-virtio"

RESCUE_IMAGE_ID=""
RESCUE_SERVER_ID=""
RESCUE_FLOATING_IP=""
DUMMY_VOLUME_ID=""
DUMMY_ATTACHMENT_ID=""
DUMMY_DEVICE=""
FINAL_IMAGE_ID=""
FINAL_SERVER_ID=""
FINAL_FLOATING_IP=""
ACCESS_METHOD=""
ACCESS_IP=""
ACCESS_PORT=""

CURRENT_STAGE="G0_PREFLIGHT"
TMP_FILES=()

: >"$PROGRESS_LOG"
: >"$BACKGROUND_LOG"

log() {
  local line
  line="[$(date '+%H:%M:%S')][$LABEL][MethodG] $*"
  echo "$line"
  echo "$line" >>"$PROGRESS_LOG"
  echo "$line" >>"$BACKGROUND_LOG"
}

stage_log() {
  log "[$1] $2"
}

json_merge() {
  local payload="$1"
  python3 - "$STATE_JSON" "$payload" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
updates = json.loads(sys.argv[2])
doc = {}
if path.is_file():
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        doc = {}

for key, val in updates.items():
    if isinstance(val, dict) and isinstance(doc.get(key), dict):
        merged = dict(doc[key])
        merged.update(val)
        doc[key] = merged
    else:
        doc[key] = val

path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
PY
}

init_state() {
  json_merge "$(cat <<EOF
{
  "method": "G_SIMPLE_SSH_ONLY",
  "status": "RUNNING",
  "stage": "G0_PREFLIGHT",
  "source_ip": "$SERVER_IP",
  "capture_mode": "ssh_guest_capture",
  "raw_artifact": "",
  "qcow2_artifact": "",
  "rescue_image_id": "",
  "rescue_server_id": "",
  "dummy_volume_id": "",
  "dummy_attachment_id": "",
  "dummy_device": "",
  "virtio_ready_image_id": "",
  "final_server_id": "",
  "checkpoints": {
    "ssh_capture": "PENDING",
    "artifact_validated": "PENDING",
    "windows_repaired": "PENDING",
    "safe_rescue_boot": "PENDING",
    "dummy_virtio_attached": "PENDING",
    "online_virtio_bound": "PENDING",
    "final_boot_validated": "PENDING"
  },
  "failure_reason": "",
  "next_action": "",
  "final": false
}
EOF
)"
}

checkpoint_for_stage() {
  case "$1" in
    G1_SSH_ACCESS_CHECK|G2_SSH_DISK_CAPTURE) echo "ssh_capture" ;;
    G3_ARTIFACT_VALIDATE|G4_QCOW2_CONVERT) echo "artifact_validated" ;;
    G5_WINDOWS_REPAIR) echo "windows_repaired" ;;
    G6_UPLOAD_SAFE_RESCUE_IMAGE|G7_BOOT_SAFE_RESCUE_VM) echo "safe_rescue_boot" ;;
    G8_ATTACH_DUMMY_VIRTIO) echo "dummy_virtio_attached" ;;
    G9_ONLINE_VIRTIO_BINDING|G10_REBOOT_STILL_IDE) echo "online_virtio_bound" ;;
    G11_SNAPSHOT_VIRTIO_READY|G12_BOOT_FINAL_VIRTIO|G13_FINAL_VALIDATE|G14_SUCCESS) echo "final_boot_validated" ;;
    *) echo "" ;;
  esac
}

stage_start() {
  CURRENT_STAGE="$1"
  stage_log "$CURRENT_STAGE" "START"
  json_merge "{\"stage\":\"$CURRENT_STAGE\",\"status\":\"RUNNING\",\"failure_reason\":\"\",\"next_action\":\"\"}"
}

checkpoint_hit() {
  local key="$1"
  json_merge "{\"checkpoints\":{\"$key\":\"HIT\"}}"
}

fail_exit() {
  local stage="$1" status="$2" reason="$3" next="$4"
  local cp
  cp="$(checkpoint_for_stage "$stage")"
  stage_log "$stage" "FAILED $reason"
  log "next_action=$next"
  if [ -n "$cp" ]; then
    json_merge "{\"stage\":\"$stage\",\"status\":\"$status\",\"failure_reason\":\"$reason\",\"next_action\":\"$next\",\"final\":false,\"checkpoints\":{\"$cp\":\"FAILED\"}}"
  else
    json_merge "{\"stage\":\"$stage\",\"status\":\"$status\",\"failure_reason\":\"$reason\",\"next_action\":\"$next\",\"final\":false}"
  fi
  exit 1
}

unexpected_exit() {
  local line_no="$1" command_text="$2"
  fail_exit "${CURRENT_STAGE:-G0_PREFLIGHT}" "FAILED" "unexpected_error_line_${line_no}" "Inspect $BACKGROUND_LOG near: ${command_text}"
}

new_tmp_file() {
  local t
  t=$(mktemp "/tmp/ospc2flex_mgs_${LABEL}_XXXXXX")
  TMP_FILES+=("$t")
  printf '%s\n' "$t"
}

cleanup_tmp_files() {
  local f
  for f in "${TMP_FILES[@]:-}"; do
    [ -n "$f" ] && rm -f "$f" 2>/dev/null || true
  done
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail_exit "G0_PREFLIGHT" "MISSING_DEPENDENCY" "missing_command_$1" "Install $1 on the jumphost and retry."
}

ssh_base() {
  sshpass -p "$WIN_PASSWORD" ssh \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -o ConnectTimeout=30 \
    -o PreferredAuthentications=password,keyboard-interactive \
    -o PubkeyAuthentication=no \
    "$WIN_USER@$SERVER_IP" "$@"
}

console_has_fatal_boot_error() {
  local server_id="$1" console
  console="$(openstack console log show "$server_id" 2>/dev/null || true)"
  if printf '%s\n' "$console" | grep -Eiq 'Windows\\system32\\config\\system|0xc0000225'; then
    return 2
  fi
  if printf '%s\n' "$console" | grep -Eiq 'INACCESSIBLE_BOOT_DEVICE'; then
    return 3
  fi
  return 0
}

wait_for_image_active() {
  local image_id="$1" timeout="${2:-1800}" waited=0 status last_report=0
  log "[wait_image_active] Waiting for image=$image_id to become active (timeout=${timeout}s)"
  while [ "$waited" -lt "$timeout" ]; do
    status=$(openstack image show "$image_id" -f value -c status 2>/dev/null || echo "unknown")
    [ "$status" = "active" ] && { log "[wait_image_active] image=$image_id active after ${waited}s"; return 0; }
    if [ "$status" = "killed" ] || [ "$status" = "deleted" ]; then
      log "[wait_image_active] image=$image_id in terminal state: $status — aborting"
      return 1
    fi
    if [ $((waited - last_report)) -ge 60 ]; then
      log "[wait_image_active] image=$image_id status=$status waited=${waited}s"
      last_report=$waited
    fi
    sleep 10
    waited=$((waited + 10))
  done
  log "[wait_image_active] TIMEOUT ${timeout}s: image=$image_id status=$status"
  return 1
}

verify_safe_metadata() {
  local image_id="$1" props
  props=$(openstack image show "$image_id" -f value -c properties 2>/dev/null || true)
  mgs_prop_equals "$props" "hw_disk_bus" "ide" || return 1
  mgs_prop_equals "$props" "hw_cdrom_bus" "ide" || return 1
  mgs_prop_equals "$props" "hw_vif_model" "e1000" || return 1
  mgs_prop_equals "$props" "os_type" "windows" || return 1
  mgs_prop_equals "$props" "os_distro" "windows" || return 1
  mgs_prop_equals "$props" "vm_mode" "hvm" || return 1
  ! printf '%s\n' "$props" | grep -Eq "hw_scsi_model[\"']?[[:space:]]*[:=]" || return 1
  ! printf '%s\n' "$props" | grep -Eq "hw_qemu_guest_agent[\"']?[[:space:]]*[:=]" || return 1
}

verify_final_metadata() {
  local image_id="$1" props
  props=$(openstack image show "$image_id" -f value -c properties 2>/dev/null || true)
  mgs_prop_equals "$props" "hw_disk_bus" "scsi" || return 1
  mgs_prop_equals "$props" "hw_scsi_model" "virtio-scsi" || return 1
  mgs_prop_equals "$props" "hw_vif_model" "virtio" || return 1
  mgs_prop_equals "$props" "hw_qemu_guest_agent" "yes" || return 1
}

run_driver_binding() {
  local ps rc=0
  ps='
$ErrorActionPreference = "Continue"
New-Item -ItemType Directory -Force C:\ospc2flex | Out-Null
"[run_driver_binding] pnputil: installing drivers from C:\ospc2flex\drivers\"
pnputil /add-driver C:\ospc2flex\drivers\*.inf /subdirs /install
$drivers = driverquery /v /fo csv | Out-String
$services = Get-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Services\viostor,HKLM:\SYSTEM\CurrentControlSet\Services\vioscsi -ErrorAction SilentlyContinue | Out-String
$disks = Get-Disk | Format-Table Number,FriendlyName,BusType,OperationalStatus -Auto | Out-String
$pnp = Get-PnpDevice | Where-Object { $_.FriendlyName -match "VirtIO|Red Hat|SCSI|Storage|Disk" } | Format-Table -Auto | Out-String
"DRIVERS_BEGIN"; $drivers; "SERVICES_BEGIN"; $services; "DISKS_BEGIN"; $disks; "PNP_BEGIN"; $pnp
if (($drivers -notmatch "viostor") -and ($services -notmatch "viostor")) { "[run_driver_binding] viostor missing"; exit 11 }
if (($drivers -notmatch "vioscsi") -and ($services -notmatch "vioscsi")) { "[run_driver_binding] vioscsi missing"; exit 12 }
if (($disks -notmatch "VirtIO|SCSI") -and ($pnp -notmatch "VirtIO|Red Hat|SCSI")) { "[run_driver_binding] dummy VirtIO disk not visible"; exit 13 }
"[run_driver_binding] OK: viostor+vioscsi present and VirtIO disk visible"
exit 0
'
  log "[run_driver_binding] Running VirtIO driver binding via $ACCESS_METHOD@$ACCESS_IP:$ACCESS_PORT"
  mgs_run_windows_ps "$ps" >>"$BACKGROUND_LOG" 2>&1 || rc=$?
  log "[run_driver_binding] exit_code=$rc (0=ok 11=viostor_missing 12=vioscsi_missing 13=disk_not_visible)"
  return $rc
}

verify_guest_health() {
  local out
  out="$(new_tmp_file)"
  mgs_run_windows_ps '$env:COMPUTERNAME; Get-Disk | Format-Table Number,FriendlyName,BusType,OperationalStatus -Auto | Out-String; driverquery | findstr /i "virtio Red Hat viostor vioscsi netkvm"; Get-NetAdapter | Format-Table Name,Status,LinkSpeed -Auto | Out-String' >"$out" 2>&1 || return 1
  grep -Eiq 'virtio|viostor|vioscsi|Red Hat' "$out" || return 1
  grep -Eiq 'Up|Connected|OperationalStatus' "$out" || return 1
}

trap 'unexpected_exit "$LINENO" "$BASH_COMMAND"' ERR
trap cleanup_tmp_files EXIT

echo "═══════════════════════════════════════════════════════════════════════════"
echo "Method G Simple — SSH Capture + Dummy VirtIO Boot"
echo "═══════════════════════════════════════════════════════════════════════════"
echo "Server  : $SERVER_NAME ($SERVER_IP)"
echo "Label   : $LABEL"
echo "Flavor  : $FLAVOR"
echo "Network : $NETWORK"
echo "Keypair : ${KEYPAIR:-<none>}"
echo "═══════════════════════════════════════════════════════════════════════════"

init_state

stage_start "G0_PREFLIGHT"
require_cmd nc
require_cmd sshpass
require_cmd ssh
require_cmd qemu-img
require_cmd openstack
require_cmd python3
[ -f "$WIN_REPAIR" ] || fail_exit "G0_PREFLIGHT" "MISSING_DEPENDENCY" "windows_repair_script_missing" "Stage $WIN_REPAIR on the jumphost before retry."
[ -f "$FLEX_CREDS" ] || fail_exit "G0_PREFLIGHT" "MISSING_DEPENDENCY" "flex_creds_missing" "Stage Flex OpenStack credentials at $FLEX_CREDS before retry."
[ -f "$METHOD_B_CAPTURE_SCRIPT" ] || METHOD_B_CAPTURE_SCRIPT="${SELF_DIR}/ospc2flex_windows_method_d_capture.sh"
[ -f "$METHOD_B_CAPTURE_SCRIPT" ] || fail_exit "G0_PREFLIGHT" "MISSING_DEPENDENCY" "method_b_capture_script_missing" "Stage ospc2flex_windows_method_d_capture.sh on the jumphost before retry."
if [ "$DRY_RUN" = 1 ]; then
  stage_log "G0_PREFLIGHT" "HIT dry-run preflight complete"
  json_merge '{"stage":"G0_PREFLIGHT","status":"DRY_RUN","final":false}'
  exit 0
fi
stage_log "G0_PREFLIGHT" "HIT dependencies ready"

stage_start "G1_SSH_ACCESS_CHECK"
stage_log "G1_SSH_ACCESS_CHECK" "Delegating SSH public/ServiceNet access checks to Method B capture engine"
stage_log "G1_SSH_ACCESS_CHECK" "HIT Method B SSH access check will run inside capture stage"

stage_start "G2_SSH_DISK_CAPTURE"
stage_log "G2_SSH_DISK_CAPTURE" "Using Method B SSH disk download engine: $METHOD_B_CAPTURE_SCRIPT"
if [ "${OSPC2FLEX_FORCE_FRESH_CAPTURE:-0}" = "1" ] || [ "${OSPC2FLEX_DISABLE_RESUME:-0}" = "1" ] || [ "${OSPC2FLEX_RESUME_MODE:-on}" = "off" ]; then
  rm -f "$QCOW" "${QCOW}.win_repaired" 2>/dev/null || true
else
  rm -f "${QCOW}.win_repaired" 2>/dev/null || true
fi
capture_args=(
  --server-name "$SERVER_NAME"
  --server-ip "$SERVER_IP"
  --label "$LABEL"
  --workflow-tag method_g_simple
  --windows-user "$WIN_USER"
  --windows-password "$WIN_PASSWORD"
  --flavor "$FLAVOR"
  --network "$NETWORK"
  --keypair "$KEYPAIR"
  --os-family windows
  --os-type windows
)
[ -n "$WIN_SNET_IP" ] && capture_args+=(--server-snet-ip "$WIN_SNET_IP")
trap - ERR
set +e
OSPC2FLEX_METHOD_B_CAPTURE_ONLY=1 \
OSPC2FLEX_PARENT_METHOD_NAME="Method G Simple" \
OSPC2FLEX_CAPTURE_LOG_CONTEXT="Shared Method B SSH Capture" \
OSPC2FLEX_LEGACY_IMAGE_NAME=1 \
OSPC2FLEX_DISABLE_RESUME=1 \
OSPC2FLEX_FORCE_FRESH_CAPTURE=1 \
OSPC2FLEX_RESUME_MODE=off \
OSPC2FLEX_ALLOW_WINDOWS_GLANCE_FALLBACK=0 \
OSPC2FLEX_ALLOW_PROVIDER_EXPORT_FALLBACK=0 \
OSPC2FLEX_ALLOW_DISK2VHD=0 \
OSPC2FLEX_ALLOW_VSS_CAPTURE=0 \
OSPC2FLEX_ALLOW_SMB_HTTPS_OBJECT_TRANSFER=0 \
OSPC2FLEX_ALLOW_WINRM_AGENT_CAPTURE=0 \
bash "$METHOD_B_CAPTURE_SCRIPT" "${capture_args[@]}" 2>&1 | tee -a "$BACKGROUND_LOG"
pipe_status=("${PIPESTATUS[@]}")
set +u
capture_rc="${pipe_status[0]:-99}"
tee_rc="${pipe_status[1]:-0}"
set -u
set -e
trap 'unexpected_exit "$LINENO" "$BASH_COMMAND"' ERR
if [ "$capture_rc" -ne 0 ] || [ "$tee_rc" -ne 0 ]; then
  if grep -Eiq 'Incorrect function|OSPC2FLEX_PHYSICAL_DRIVE_OPEN_FAILED|WINDOWS_RAW_DISK_READ_FAILED' "$BACKGROUND_LOG"; then
    fail_exit "G2_SSH_DISK_CAPTURE" "WINDOWS_DISK_CAPTURE_FAILED" "WINDOWS_RAW_DISK_READ_FAILED" "SSH works but Windows rejected raw disk read. Fix SSH capture/elevation/device access before retry."
  fi
  fail_exit "G2_SSH_DISK_CAPTURE" "WINDOWS_DISK_CAPTURE_FAILED" "METHOD_B_SSH_CAPTURE_FAILED" "Method B SSH disk download failed. Fix SSH/OpenSSH/firewall/credential/elevation before retry."
fi
[ -s "$QCOW" ] || fail_exit "G2_SSH_DISK_CAPTURE" "WINDOWS_DISK_CAPTURE_FAILED" "method_b_qcow_missing" "Method B capture did not produce $QCOW."
qemu-img info "$QCOW" >>"$BACKGROUND_LOG" 2>&1 || fail_exit "G2_SSH_DISK_CAPTURE" "WINDOWS_DISK_CAPTURE_FAILED" "method_b_qcow_invalid" "Repeat Method B SSH capture after fixing source disk read."
qemu-img check "$QCOW" >>"$BACKGROUND_LOG" 2>&1 || fail_exit "G2_SSH_DISK_CAPTURE" "WINDOWS_DISK_CAPTURE_FAILED" "method_b_qcow_check_failed" "Repeat Method B SSH capture after fixing source disk read."
json_merge "{\"qcow2_artifact\":\"$QCOW\",\"checkpoints\":{\"ssh_capture\":\"HIT\"}}"
stage_log "G2_SSH_DISK_CAPTURE" "HIT Method B SSH capture produced validated qcow2"

stage_start "G3_ARTIFACT_VALIDATE"
[ -s "$QCOW" ] || fail_exit "G3_ARTIFACT_VALIDATE" "SOURCE_ARTIFACT_INVALID" "SSH_CAPTURE_ARTIFACT_INVALID" "Repeat Method B SSH capture after fixing source disk read."
qemu-img info "$QCOW" >>"$BACKGROUND_LOG" 2>&1 || fail_exit "G3_ARTIFACT_VALIDATE" "SOURCE_ARTIFACT_INVALID" "SSH_CAPTURE_ARTIFACT_INVALID" "Repeat Method B SSH capture after fixing source disk read."
qemu-img check "$QCOW" >>"$BACKGROUND_LOG" 2>&1 || fail_exit "G3_ARTIFACT_VALIDATE" "SOURCE_ARTIFACT_INVALID" "SSH_CAPTURE_ARTIFACT_INVALID" "Repeat Method B SSH capture after fixing source disk read."
checkpoint_hit "artifact_validated"
stage_log "G3_ARTIFACT_VALIDATE" "HIT Method B qcow2 artifact validated"

stage_start "G4_QCOW2_CONVERT"
qemu-img info "$QCOW" >>"$BACKGROUND_LOG" 2>&1 || fail_exit "G4_QCOW2_CONVERT" "SOURCE_ARTIFACT_INVALID" "SSH_CAPTURE_ARTIFACT_INVALID" "Repeat SSH capture after fixing source disk read."
qemu-img check "$QCOW" >>"$BACKGROUND_LOG" 2>&1 || fail_exit "G4_QCOW2_CONVERT" "SOURCE_ARTIFACT_INVALID" "SSH_CAPTURE_ARTIFACT_INVALID" "Repeat SSH capture after fixing source disk read."
json_merge "{\"qcow2_artifact\":\"$QCOW\",\"checkpoints\":{\"artifact_validated\":\"HIT\"}}"
stage_log "G4_QCOW2_CONVERT" "HIT qcow2 already converted by Method B and validated"

stage_start "G5_WINDOWS_REPAIR"
bash "$WIN_REPAIR" --qcow2 "$QCOW" >>"$BACKGROUND_LOG" 2>&1 || fail_exit "G5_WINDOWS_REPAIR" "WINDOWS_REPAIR_FAILED" "windows_repair_failed" "Use fresh SSH capture or restore registry backup."
[ -f "${QCOW}.win_repaired" ] || fail_exit "G5_WINDOWS_REPAIR" "WINDOWS_REPAIR_FAILED" "win_repaired_sentinel_missing" "Use fresh SSH capture or restore registry backup."
qemu-img check "$QCOW" >>"$BACKGROUND_LOG" 2>&1 || fail_exit "G5_WINDOWS_REPAIR" "WINDOWS_REPAIR_FAILED" "post_repair_qcow2_check_failed" "Use fresh SSH capture or restore registry backup."
checkpoint_hit "windows_repaired"
stage_log "G5_WINDOWS_REPAIR" "HIT qcow2 repaired and SYSTEM hive valid"

stage_start "G6_UPLOAD_SAFE_RESCUE_IMAGE"
# shellcheck source=/dev/null
source "$FLEX_CREDS"
_qcow_size=$(du -sh "$QCOW" 2>/dev/null | cut -f1 || echo "?")
stage_log "G6_UPLOAD_SAFE_RESCUE_IMAGE" "Uploading $QCOW as $RESCUE_IMAGE_NAME (size=${_qcow_size}) — may take 10-30 min"
RESCUE_IMAGE_ID=$(openstack image create "$RESCUE_IMAGE_NAME" --disk-format qcow2 --container-format bare --file "$QCOW" -f value -c id 2>>"$BACKGROUND_LOG" | tr -d '\r' || true)
[ -n "$RESCUE_IMAGE_ID" ] || fail_exit "G6_UPLOAD_SAFE_RESCUE_IMAGE" "SAFE_RESCUE_IMAGE_FAILED" "safe_rescue_image_upload_failed" "Inspect Flex Glance quota/auth and retry."
stage_log "G6_UPLOAD_SAFE_RESCUE_IMAGE" "Glance image created: $RESCUE_IMAGE_ID — waiting for active"
wait_for_image_active "$RESCUE_IMAGE_ID" 1800 || fail_exit "G6_UPLOAD_SAFE_RESCUE_IMAGE" "SAFE_RESCUE_IMAGE_FAILED" "safe_rescue_image_not_active" "Inspect Flex Glance image status and retry."
openstack image set \
  --property hw_disk_bus=ide \
  --property hw_cdrom_bus=ide \
  --property hw_vif_model=e1000 \
  --property os_type=windows \
  --property os_distro=windows \
  --property vm_mode=hvm \
  "$RESCUE_IMAGE_ID" >>"$BACKGROUND_LOG" 2>&1 || fail_exit "G6_UPLOAD_SAFE_RESCUE_IMAGE" "SAFE_RESCUE_IMAGE_FAILED" "safe_metadata_set_failed" "Inspect Flex Glance metadata permissions and retry."
verify_safe_metadata "$RESCUE_IMAGE_ID" || fail_exit "G6_UPLOAD_SAFE_RESCUE_IMAGE" "SAFE_RESCUE_IMAGE_FAILED" "safe_metadata_verify_failed" "Safe rescue metadata must be IDE/e1000 only before boot."
json_merge "{\"rescue_image_id\":\"$RESCUE_IMAGE_ID\"}"
stage_log "G6_UPLOAD_SAFE_RESCUE_IMAGE" "HIT safe IDE/e1000 image uploaded: $RESCUE_IMAGE_ID"

stage_start "G7_BOOT_SAFE_RESCUE_VM"
# Validate flavor exists; fall back to known-good if not
if ! openstack flavor show "$FLAVOR" >/dev/null 2>&1; then
  _flavor_fallbacks=(gp.0.4.4 gp.0.2.8 gp.0.2.4 gp.0.1.4)
  _new_flavor=""
  for _fb in "${_flavor_fallbacks[@]}"; do
    if openstack flavor show "$_fb" >/dev/null 2>&1; then
      _new_flavor="$_fb"; break
    fi
  done
  [ -n "$_new_flavor" ] || fail_exit "G7_BOOT_SAFE_RESCUE_VM" "SAFE_IDE_RESCUE_BOOT_FAILED" "flavor_not_found_$FLAVOR" "Set MIG_FLAVOR to a valid FLEX flavor (e.g. gp.0.4.4) and retry."
  stage_log "G7_BOOT_SAFE_RESCUE_VM" "Flavor $FLAVOR not found; using fallback $_new_flavor"
  FLAVOR="$_new_flavor"
fi
stage_log "G7_BOOT_SAFE_RESCUE_VM" "Rescue image metadata (IDE/e1000):"
openstack image show "$RESCUE_IMAGE_ID" -f value -c properties >>"$BACKGROUND_LOG" 2>&1 || true
create_args=(server create "$RESCUE_SERVER_NAME" --image "$RESCUE_IMAGE_ID" --flavor "$FLAVOR" --network "$NETWORK" --wait -f value -c id)
[ -n "$KEYPAIR" ] && create_args+=(--key-name "$KEYPAIR")
stage_log "G7_BOOT_SAFE_RESCUE_VM" "Creating rescue VM: openstack ${create_args[*]}"
RESCUE_SERVER_ID=$(openstack "${create_args[@]}" 2>>"$BACKGROUND_LOG" | tr -d '\r\n' || true)
[ -n "$RESCUE_SERVER_ID" ] || RESCUE_SERVER_ID=$(openstack server list --name "$RESCUE_SERVER_NAME" -f value -c ID 2>/dev/null | tr -d '\r\n' | head -c 36 || true)
[ -n "$RESCUE_SERVER_ID" ] || fail_exit "G7_BOOT_SAFE_RESCUE_VM" "SAFE_IDE_RESCUE_BOOT_FAILED" "rescue_server_create_failed" "Inspect rescue console and preserved rescue VM."
stage_log "G7_BOOT_SAFE_RESCUE_VM" "Rescue server created: $RESCUE_SERVER_ID — waiting for ACTIVE"
mgs_wait_for_server_status "$RESCUE_SERVER_ID" "ACTIVE" 900 || fail_exit "G7_BOOT_SAFE_RESCUE_VM" "SAFE_IDE_RESCUE_BOOT_FAILED" "rescue_server_not_active" "Inspect rescue console and preserved rescue VM."
RESCUE_FLOATING_IP=$(mgs_attach_floating_ip "$RESCUE_SERVER_ID" || true)
stage_log "G7_BOOT_SAFE_RESCUE_VM" "Rescue VM ACTIVE: $RESCUE_SERVER_ID fip=${RESCUE_FLOATING_IP:-none}"
stage_log "G7_BOOT_SAFE_RESCUE_VM" "Checking rescue VM console for fatal boot errors"
mgs_save_console_log "$RESCUE_SERVER_ID" "$BACKGROUND_LOG"
if console_has_fatal_boot_error "$RESCUE_SERVER_ID"; then console_rc=0; else console_rc=$?; fi
if [ "$console_rc" -eq 2 ]; then
  fail_exit "G7_BOOT_SAFE_RESCUE_VM" "SAFE_IDE_RESCUE_BOOT_FAILED" "WINDOWS_SYSTEM_HIVE_OR_REGISTRY_STOP" "Inspect rescue console and restore SYSTEM hive backup."
elif [ "$console_rc" -eq 3 ]; then
  fail_exit "G7_BOOT_SAFE_RESCUE_VM" "SAFE_IDE_RESCUE_BOOT_FAILED" "INACCESSIBLE_BOOT_DEVICE" "Inspect rescue console and preserved rescue VM."
fi
OSPC2FLEX_V2_PREFERRED_IP="${RESCUE_FLOATING_IP:-}" mgs_wait_for_windows_guest_access "$RESCUE_SERVER_ID" "safe_rescue" "$HEALTHCHECK_WAIT" || fail_exit "G7_BOOT_SAFE_RESCUE_VM" "SAFE_IDE_RESCUE_BOOT_FAILED" "rescue_guest_unreachable" "Inspect rescue console and preserved rescue VM."
json_merge "{\"rescue_server_id\":\"$RESCUE_SERVER_ID\",\"checkpoints\":{\"safe_rescue_boot\":\"HIT\"}}"
stage_log "G7_BOOT_SAFE_RESCUE_VM" "HIT safe IDE/e1000 rescue VM booted: $RESCUE_SERVER_ID access=$ACCESS_METHOD@$ACCESS_IP"

stage_start "G8_ATTACH_DUMMY_VIRTIO"
stage_log "G8_ATTACH_DUMMY_VIRTIO" "Creating 1 GiB dummy VirtIO volume: $DUMMY_VOLUME_NAME"
DUMMY_VOLUME_ID=$(openstack volume create --size 1 "$DUMMY_VOLUME_NAME" -f value -c id 2>>"$BACKGROUND_LOG" | tr -d '\r' || true)
[ -n "$DUMMY_VOLUME_ID" ] || fail_exit "G8_ATTACH_DUMMY_VIRTIO" "DUMMY_VIRTIO_ATTACH_FAILED" "dummy_volume_create_failed" "Inspect Cinder quota/status; preserve rescue VM."
stage_log "G8_ATTACH_DUMMY_VIRTIO" "Volume created: $DUMMY_VOLUME_ID — waiting for available"
waited=0
while [ "$waited" -lt 300 ]; do
  vol_status=$(openstack volume show "$DUMMY_VOLUME_ID" -f value -c status 2>/dev/null | tr -d '\r' || echo "unknown")
  [ "$vol_status" = "available" ] && break
  [ $((waited % 30)) -eq 0 ] && stage_log "G8_ATTACH_DUMMY_VIRTIO" "Volume $DUMMY_VOLUME_ID status=$vol_status waited=${waited}s"
  sleep 5
  waited=$((waited + 5))
done
[ "$(openstack volume show "$DUMMY_VOLUME_ID" -f value -c status 2>/dev/null || echo unknown)" = "available" ] || fail_exit "G8_ATTACH_DUMMY_VIRTIO" "DUMMY_VIRTIO_ATTACH_FAILED" "dummy_volume_not_available" "Inspect Cinder volume status; preserve rescue VM and dummy disk."
stage_log "G8_ATTACH_DUMMY_VIRTIO" "Attaching volume $DUMMY_VOLUME_ID to rescue VM $RESCUE_SERVER_ID"
openstack server add volume "$RESCUE_SERVER_ID" "$DUMMY_VOLUME_ID" >>"$BACKGROUND_LOG" 2>&1 || fail_exit "G8_ATTACH_DUMMY_VIRTIO" "DUMMY_VIRTIO_ATTACH_FAILED" "dummy_volume_attach_failed" "Inspect Nova/Cinder attachment; preserve rescue VM and dummy disk."
sleep 10
DUMMY_ATTACHMENT_ID=$(openstack volume show "$DUMMY_VOLUME_ID" -f json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); a=d.get("attachments") or []; print((a[0] or {}).get("attachment_id","") if a else "")' 2>/dev/null || true)
DUMMY_DEVICE=$(openstack volume show "$DUMMY_VOLUME_ID" -f json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); a=d.get("attachments") or []; print((a[0] or {}).get("device","") if a else "")' 2>/dev/null || true)
[ -n "$DUMMY_ATTACHMENT_ID$DUMMY_DEVICE" ] || fail_exit "G8_ATTACH_DUMMY_VIRTIO" "DUMMY_VIRTIO_ATTACH_FAILED" "dummy_volume_attachment_unconfirmed" "Inspect Nova/Cinder attachment; preserve rescue VM and dummy disk."
json_merge "{\"dummy_volume_id\":\"$DUMMY_VOLUME_ID\",\"dummy_attachment_id\":\"$DUMMY_ATTACHMENT_ID\",\"dummy_device\":\"$DUMMY_DEVICE\",\"checkpoints\":{\"dummy_virtio_attached\":\"HIT\"}}"
stage_log "G8_ATTACH_DUMMY_VIRTIO" "HIT dummy VirtIO disk attached: volume=$DUMMY_VOLUME_ID device=$DUMMY_DEVICE"

stage_start "G9_ONLINE_VIRTIO_BINDING"
stage_log "G9_ONLINE_VIRTIO_BINDING" "Running driver binding via $ACCESS_METHOD@$ACCESS_IP"
run_driver_binding || fail_exit "G9_ONLINE_VIRTIO_BINDING" "VIRTIO_DRIVER_BINDING_FAILED" "virtio_driver_binding_failed" "Use console/RDP to inspect VirtIO driver install."
checkpoint_hit "online_virtio_bound"
stage_log "G9_ONLINE_VIRTIO_BINDING" "HIT VirtIO drivers installed and dummy device visible"

stage_start "G10_REBOOT_STILL_IDE"
mgs_run_windows_ps "Restart-Computer -Force" >>"$BACKGROUND_LOG" 2>&1 || true
sleep 20
ACCESS_METHOD=""
ACCESS_IP=""
ACCESS_PORT=""
OSPC2FLEX_V2_PREFERRED_IP="${RESCUE_FLOATING_IP:-}" mgs_wait_for_windows_guest_access "$RESCUE_SERVER_ID" "rescue_reboot_still_ide" "$HEALTHCHECK_WAIT" || fail_exit "G10_REBOOT_STILL_IDE" "WINDOWS_REBOOT_AFTER_DRIVER_BINDING_FAILED" "rescue_reboot_guest_unreachable" "Use console/RDP to inspect driver install."
run_driver_binding || fail_exit "G10_REBOOT_STILL_IDE" "WINDOWS_REBOOT_AFTER_DRIVER_BINDING_FAILED" "post_reboot_virtio_verify_failed" "Use console/RDP to inspect driver install."
checkpoint_hit "online_virtio_bound"
stage_log "G10_REBOOT_STILL_IDE" "HIT Windows rebooted successfully while still IDE/e1000"

stage_start "G11_SNAPSHOT_VIRTIO_READY"
stage_log "G11_SNAPSHOT_VIRTIO_READY" "Stopping rescue VM $RESCUE_SERVER_ID for snapshot"
openstack server stop "$RESCUE_SERVER_ID" >>"$BACKGROUND_LOG" 2>&1 || true
mgs_wait_for_server_status "$RESCUE_SERVER_ID" "SHUTOFF" 900 || fail_exit "G11_SNAPSHOT_VIRTIO_READY" "VIRTIO_READY_SNAPSHOT_FAILED" "rescue_server_stop_failed" "Inspect rescue VM and retry snapshot."
stage_log "G11_SNAPSHOT_VIRTIO_READY" "Rescue VM SHUTOFF — creating snapshot $FINAL_IMAGE_NAME"
FINAL_IMAGE_ID=$(openstack server image create "$RESCUE_SERVER_ID" --name "$FINAL_IMAGE_NAME" -f value -c id 2>>"$BACKGROUND_LOG" | tr -d '\r\n' || true)
[ -n "$FINAL_IMAGE_ID" ] || fail_exit "G11_SNAPSHOT_VIRTIO_READY" "VIRTIO_READY_SNAPSHOT_FAILED" "virtio_ready_snapshot_failed" "Inspect rescue VM snapshot task."
wait_for_image_active "$FINAL_IMAGE_ID" 1800 || fail_exit "G11_SNAPSHOT_VIRTIO_READY" "VIRTIO_READY_SNAPSHOT_FAILED" "virtio_ready_image_not_active" "Inspect Flex Glance image status."
openstack image set \
  --property hw_disk_bus=scsi \
  --property hw_scsi_model=virtio-scsi \
  --property hw_vif_model=virtio \
  --property hw_qemu_guest_agent=yes \
  "$FINAL_IMAGE_ID" >>"$BACKGROUND_LOG" 2>&1 || fail_exit "G11_SNAPSHOT_VIRTIO_READY" "VIRTIO_READY_SNAPSHOT_FAILED" "final_metadata_set_failed" "Inspect Flex Glance metadata permissions."
verify_final_metadata "$FINAL_IMAGE_ID" || fail_exit "G11_SNAPSHOT_VIRTIO_READY" "VIRTIO_READY_SNAPSHOT_FAILED" "final_metadata_verify_failed" "Final image metadata must be virtio-scsi/virtio."
json_merge "{\"virtio_ready_image_id\":\"$FINAL_IMAGE_ID\"}"
stage_log "G11_SNAPSHOT_VIRTIO_READY" "HIT virtio-ready snapshot created and metadata applied"

stage_start "G12_BOOT_FINAL_VIRTIO"
final_args=(server create "$FINAL_SERVER_NAME" --image "$FINAL_IMAGE_ID" --flavor "$FLAVOR" --network "$NETWORK" --wait -f value -c id)
[ -n "$KEYPAIR" ] && final_args+=(--key-name "$KEYPAIR")
stage_log "G12_BOOT_FINAL_VIRTIO" "Creating final VirtIO VM: openstack ${final_args[*]}"
FINAL_SERVER_ID=$(openstack "${final_args[@]}" 2>>"$BACKGROUND_LOG" | tr -d '\r\n' || true)
[ -n "$FINAL_SERVER_ID" ] || FINAL_SERVER_ID=$(openstack server list --name "$FINAL_SERVER_NAME" -f value -c ID 2>/dev/null | tr -d '\r' | head -1 || true)
[ -n "$FINAL_SERVER_ID" ] || fail_exit "G12_BOOT_FINAL_VIRTIO" "FINAL_VIRTIO_BOOT_FAILED" "final_server_create_failed" "Inspect final image metadata and Nova boot request."
mgs_wait_for_server_status "$FINAL_SERVER_ID" "ACTIVE" 900 || fail_exit "G12_BOOT_FINAL_VIRTIO" "FINAL_VIRTIO_BOOT_FAILED" "final_server_not_active" "Inspect final VM console."
FINAL_FLOATING_IP=$(mgs_attach_floating_ip "$FINAL_SERVER_ID" || true)
json_merge "{\"final_server_id\":\"$FINAL_SERVER_ID\"}"
stage_log "G12_BOOT_FINAL_VIRTIO" "HIT final virtio-scsi VM ACTIVE"

stage_start "G13_FINAL_VALIDATE"
if console_has_fatal_boot_error "$FINAL_SERVER_ID"; then console_rc=0; else console_rc=$?; fi
if [ "$console_rc" -eq 2 ]; then
  fail_exit "G13_FINAL_VALIDATE" "FINAL_VALIDATE_FAILED" "WINDOWS_SYSTEM_HIVE_OR_REGISTRY_STOP" "Use fresh SSH capture or restore registry backup."
elif [ "$console_rc" -eq 3 ]; then
  fail_exit "G13_FINAL_VALIDATE" "FINAL_VALIDATE_FAILED" "INACCESSIBLE_BOOT_DEVICE" "Inspect VirtIO binding and final image metadata."
fi
ACCESS_METHOD=""
ACCESS_IP=""
ACCESS_PORT=""
OSPC2FLEX_V2_PREFERRED_IP="${FINAL_FLOATING_IP:-}" mgs_wait_for_windows_guest_access "$FINAL_SERVER_ID" "final_virtio" "$HEALTHCHECK_WAIT" || fail_exit "G13_FINAL_VALIDATE" "FINAL_VALIDATE_FAILED" "final_guest_unreachable" "Inspect final VM console/network/security group."
verify_guest_health || fail_exit "G13_FINAL_VALIDATE" "FINAL_VALIDATE_FAILED" "final_healthcheck_driver_missing" "Inspect final VM guest drivers/network."
checkpoint_hit "final_boot_validated"
stage_log "G13_FINAL_VALIDATE" "HIT final VM validated"

stage_start "G14_SUCCESS"
json_merge "{\"stage\":\"G14_SUCCESS\",\"status\":\"METHOD_G_SIMPLE_SUCCESS\",\"final\":true,\"checkpoints\":{\"final_boot_validated\":\"HIT\"}}"
stage_log "G14_SUCCESS" "HIT METHOD_G_SIMPLE_SUCCESS final VM validated"
echo "METHOD_G_SIMPLE_SUCCESS"
