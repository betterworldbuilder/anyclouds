#!/usr/bin/env bash
# Method E — B-Capture + G-Deploy
#
# Method B SSH disk capture (Steps 1b+1+2+3: SSH check, OSPC auth/snapshot,
# disk read, qcow2 convert) followed by Method G's offline repair + online
# VirtIO binding pipeline (G5–G12).
#
# Stages:
#   E0  PREFLIGHT              deps + dry-run gate
#   E1  SSH_DISK_CAPTURE       B Steps 1b+1+2+3 via method_d_capture.sh
#   E2  ARTIFACT_VALIDATE      qcow2 integrity check
#   E3  WINDOWS_REPAIR         offline VirtIO inject + SYSTEM hive repair
#   E4  UPLOAD_SAFE_RESCUE_IMAGE  upload IDE/e1000 image to FLEX Glance
#   E5  BOOT_SAFE_RESCUE_VM    boot IDE/e1000 rescue VM
#   E6  ATTACH_DUMMY_VIRTIO    hot-attach 1 GiB VirtIO volume
#   E7  ONLINE_VIRTIO_BINDING  in-guest pnputil VirtIO driver install
#   E8  REBOOT_STILL_IDE       reboot on IDE, verify drivers survive
#   E9  SNAPSHOT_VIRTIO_READY  stop rescue VM, snapshot, apply VirtIO metadata
#   E10 BOOT_FINAL_VIRTIO      launch final virtio-scsi/virtio VM
#   E11 SUCCESS

set -euo pipefail

if [ -z "${OSPC2FLEX_LINEBUF_WRAPPER:-}" ] && command -v stdbuf >/dev/null 2>&1; then
  export OSPC2FLEX_LINEBUF_WRAPPER=1
  exec stdbuf -oL -eL bash "$0" "$@"
fi

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SELF_DIR}/ospc2flex_windows_method_g_simple_lib.sh"

export OSPC2FLEX_METHOD_E=1
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
GLANCE_BRIDGE="${OSPC2FLEX_GLANCE_BRIDGE:-/tmp/ospc2flex_glance_bridge.sh}"
WIN_REPAIR="${WIN_REPAIR:-/tmp/ospc2flex_windows_repair.sh}"
METHOD_B_CAPTURE_SCRIPT="${OSPC2FLEX_METHOD_B_CAPTURE_SCRIPT:-/tmp/ospc2flex_windows_method_d_capture.sh}"
HEALTHCHECK_WAIT="${OSPC2FLEX_HEALTHCHECK_WAIT:-1200}"
SKIP_CAPTURE="${OSPC2FLEX_METHOD_E_SKIP_CAPTURE:-0}"
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
    --skip-capture) SKIP_CAPTURE=1; shift ;;
    --os-family|--os-type|--source-server-id|--cloudboot-target-host|--cloudboot-target-user|--cloudboot-target-password|--cloudboot-source-winrm-host|--cloudboot-target-winrm-host)
      shift 2 ;;
    *) shift ;;
  esac
done

[ -n "$LABEL" ]        || { echo "ERROR: --label required"; exit 2; }
[ -n "$SERVER_IP" ]    || { echo "ERROR: --server-ip required"; exit 2; }
[ -n "$WIN_PASSWORD" ] || { echo "ERROR: --windows-password required for Method E"; exit 2; }
SERVER_NAME="${SERVER_NAME:-$LABEL}"

if [ "$DRY_RUN" = 1 ] && ! mkdir -p "$WORK" 2>/dev/null; then
  WORK="/tmp/ospc2flex_method_e_dryrun"
fi
LOG_DIR="$WORK/logs"
mkdir -p "$LOG_DIR"
PROGRESS_LOG="$LOG_DIR/${LABEL}.progress.log"
BACKGROUND_LOG="$LOG_DIR/${LABEL}.background.log"
STATE_JSON="$WORK/${LABEL}.method_e.json"
QCOW="$WORK/${LABEL}.qcow2"
RESCUE_IMAGE_NAME="${LABEL}-me-safe-ide-img"
RESCUE_SERVER_NAME="${LABEL}-me-safe-ide"
FINAL_IMAGE_NAME="${LABEL}-me-virtio-ready-img"
FINAL_SERVER_NAME="${LABEL}-me-final-virtio"
DUMMY_VOLUME_NAME="${LABEL}-me-dummy-virtio"

RESCUE_IMAGE_ID=""
RESCUE_SERVER_ID=""
RESCUE_FLOATING_IP=""
DUMMY_VOLUME_ID=""
DUMMY_ATTACHMENT_ID=""
DUMMY_DEVICE=""
FINAL_IMAGE_ID=""
FINAL_SERVER_ID=""
export FINAL_FLOATING_IP=""
export ACCESS_METHOD=""
export ACCESS_IP=""
export ACCESS_PORT=""
CURRENT_STAGE="E0_PREFLIGHT"
TMP_FILES=()

: >"$PROGRESS_LOG"
: >"$BACKGROUND_LOG"

log() {
  local line
  line="[$(date '+%H:%M:%S')][$LABEL][MethodE] $*"
  echo "$line"
  echo "$line" >>"$PROGRESS_LOG"
  echo "$line" >>"$BACKGROUND_LOG"
}

stage_log() { log "[$1] $2"; }

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
        merged = dict(doc[key]); merged.update(val); doc[key] = merged
    else:
        doc[key] = val
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
PY
}

init_state() {
  json_merge "$(cat <<EOF
{
  "method": "METHOD_E_B_CAPTURE_G_DEPLOY",
  "status": "RUNNING",
  "stage": "E0_PREFLIGHT",
  "source_ip": "$SERVER_IP",
  "capture_mode": "ssh_guest_capture",
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
    E1_SSH_DISK_CAPTURE)                                          echo "ssh_capture" ;;
    E2_ARTIFACT_VALIDATE)                                         echo "artifact_validated" ;;
    E3_WINDOWS_REPAIR)                                            echo "windows_repaired" ;;
    E4_UPLOAD_SAFE_RESCUE_IMAGE|E5_BOOT_SAFE_RESCUE_VM)          echo "safe_rescue_boot" ;;
    E6_ATTACH_DUMMY_VIRTIO)                                       echo "dummy_virtio_attached" ;;
    E7_ONLINE_VIRTIO_BINDING|E8_REBOOT_STILL_IDE)                echo "online_virtio_bound" ;;
    E9_SNAPSHOT_VIRTIO_READY|E10_BOOT_FINAL_VIRTIO|E11_SUCCESS)  echo "final_boot_validated" ;;
    *) echo "" ;;
  esac
}

stage_start() {
  CURRENT_STAGE="$1"
  stage_log "$CURRENT_STAGE" "START"
  json_merge "{\"stage\":\"$CURRENT_STAGE\",\"status\":\"RUNNING\",\"failure_reason\":\"\",\"next_action\":\"\"}"
}

checkpoint_hit() {
  json_merge "{\"checkpoints\":{\"$1\":\"HIT\"}}"
}

fail_exit() {
  local stage="$1" status="$2" reason="$3" next="$4"
  local cp; cp="$(checkpoint_for_stage "$stage")"
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
  fail_exit "${CURRENT_STAGE:-E0_PREFLIGHT}" "FAILED" "unexpected_error_line_$1" "Inspect $BACKGROUND_LOG near: $2"
}

new_tmp_file() {
  local t; t=$(mktemp "/tmp/ospc2flex_me_${LABEL}_XXXXXX")
  TMP_FILES+=("$t"); printf '%s\n' "$t"
}

cleanup_tmp_files() {
  local f
  for f in "${TMP_FILES[@]:-}"; do [ -n "$f" ] && rm -f "$f" 2>/dev/null || true; done
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail_exit "E0_PREFLIGHT" "MISSING_DEPENDENCY" "missing_command_$1" "Install $1 on the jumphost and retry."
}

console_has_fatal_boot_error() {
  local server_id="$1" console
  console="$(openstack console log show "$server_id" 2>/dev/null || true)"
  printf '%s\n' "$console" | grep -Eiq 'Windows\\system32\\config\\system|0xc0000225' && return 2
  printf '%s\n' "$console" | grep -Eiq 'INACCESSIBLE_BOOT_DEVICE' && return 3
  return 0
}

wait_for_image_active() {
  local image_id="$1" timeout="${2:-1800}" waited=0 status
  while [ "$waited" -lt "$timeout" ]; do
    status=$(openstack image show "$image_id" -f value -c status 2>/dev/null || echo "unknown")
    [ "$status" = "active" ] && return 0
    sleep 10; waited=$((waited + 10))
  done
  return 1
}

verify_safe_metadata() {
  local image_id="$1" props
  props=$(openstack image show "$image_id" -f value -c properties 2>/dev/null || true)
  mgs_prop_equals "$props" "hw_disk_bus"  "ide"     || return 1
  mgs_prop_equals "$props" "hw_cdrom_bus" "ide"     || return 1
  mgs_prop_equals "$props" "hw_vif_model" "e1000"   || return 1
  mgs_prop_equals "$props" "os_type"      "windows" || return 1
  mgs_prop_equals "$props" "os_distro"    "windows" || return 1
  mgs_prop_equals "$props" "vm_mode"      "hvm"     || return 1
  ! printf '%s\n' "$props" | grep -Eq "hw_scsi_model[\"']?[[:space:]]*[:=]"       || return 1
  ! printf '%s\n' "$props" | grep -Eq "hw_qemu_guest_agent[\"']?[[:space:]]*[:=]" || return 1
}

verify_final_metadata() {
  local image_id="$1" props
  props=$(openstack image show "$image_id" -f value -c properties 2>/dev/null || true)
  mgs_prop_equals "$props" "hw_disk_bus"         "scsi"       || return 1
  mgs_prop_equals "$props" "hw_scsi_model"       "virtio-scsi" || return 1
  mgs_prop_equals "$props" "hw_vif_model"        "virtio"     || return 1
  mgs_prop_equals "$props" "hw_qemu_guest_agent" "yes"        || return 1
}

run_driver_binding() {
  local ps='
$ErrorActionPreference = "Continue"
New-Item -ItemType Directory -Force C:\ospc2flex | Out-Null
pnputil /add-driver C:\ospc2flex\drivers\*.inf /subdirs /install
$drivers  = driverquery /v /fo csv | Out-String
$services = Get-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Services\viostor,HKLM:\SYSTEM\CurrentControlSet\Services\vioscsi -ErrorAction SilentlyContinue | Out-String
$disks    = Get-Disk | Format-Table Number,FriendlyName,BusType,OperationalStatus -Auto | Out-String
$pnp      = Get-PnpDevice | Where-Object { $_.FriendlyName -match "VirtIO|Red Hat|SCSI|Storage|Disk" } | Format-Table -Auto | Out-String
"DRIVERS_BEGIN"; $drivers; "SERVICES_BEGIN"; $services; "DISKS_BEGIN"; $disks; "PNP_BEGIN"; $pnp
if (($drivers -notmatch "viostor")  -and ($services -notmatch "viostor"))  { exit 11 }
if (($drivers -notmatch "vioscsi")  -and ($services -notmatch "vioscsi"))  { exit 12 }
if (($disks   -notmatch "VirtIO|SCSI") -and ($pnp -notmatch "VirtIO|Red Hat|SCSI")) { exit 13 }
exit 0
'
  mgs_run_windows_ps "$ps" >>"$BACKGROUND_LOG" 2>&1
}

terminate_exit() {
  trap - TERM INT HUP
  fail_exit "${CURRENT_STAGE:-E0_PREFLIGHT}" "FAILED" "terminated_by_$1" "The Method E process was stopped. Retry only after the prior job is fully stopped."
}

trap 'unexpected_exit "$LINENO" "$BASH_COMMAND"' ERR
trap 'terminate_exit TERM' TERM
trap 'terminate_exit INT'  INT
trap 'terminate_exit HUP'  HUP
trap cleanup_tmp_files EXIT

echo "═══════════════════════════════════════════════════════════════════════════"
echo "OSPC→FLEX Windows Method E — B-Capture + G-Deploy"
echo "═══════════════════════════════════════════════════════════════════════════"
echo "Server  : $SERVER_NAME ($SERVER_IP)"
echo "Label   : $LABEL"
echo "Flavor  : $FLAVOR"
echo "Network : $NETWORK"
echo "Keypair : ${KEYPAIR:-<none>}"
echo "═══════════════════════════════════════════════════════════════════════════"

init_state

# ─── E0: Preflight ────────────────────────────────────────────────────────────
stage_start "E0_PREFLIGHT"
require_cmd nc
require_cmd sshpass
require_cmd ssh
require_cmd qemu-img
require_cmd openstack
require_cmd python3
[ -f "$WIN_REPAIR" ] || fail_exit "E0_PREFLIGHT" "MISSING_DEPENDENCY" "windows_repair_script_missing" \
  "Stage $WIN_REPAIR on the jumphost before retry."
[ -f "$FLEX_CREDS" ] || fail_exit "E0_PREFLIGHT" "MISSING_DEPENDENCY" "flex_creds_missing" \
  "Stage Flex OpenStack credentials at $FLEX_CREDS before retry."
[ -f "$METHOD_B_CAPTURE_SCRIPT" ] || METHOD_B_CAPTURE_SCRIPT="${SELF_DIR}/ospc2flex_windows_method_d_capture.sh"
[ -f "$METHOD_B_CAPTURE_SCRIPT" ] || fail_exit "E0_PREFLIGHT" "MISSING_DEPENDENCY" "method_b_capture_script_missing" \
  "Stage ospc2flex_windows_method_d_capture.sh on the jumphost before retry."
if [ "$DRY_RUN" = 1 ]; then
  stage_log "E0_PREFLIGHT" "HIT dry-run preflight complete"
  json_merge '{"stage":"E0_PREFLIGHT","status":"DRY_RUN","final":false}'
  exit 0
fi
stage_log "E0_PREFLIGHT" "HIT dependencies ready"

# ─── E1: SSH disk capture — Method B Steps 1b + 1 + 2 + 3 ───────────────────
stage_start "E1_SSH_DISK_CAPTURE"
if [ "$SKIP_CAPTURE" = "1" ]; then
  stage_log "E1_SSH_DISK_CAPTURE" "SKIP_CAPTURE=1 — validating existing qcow2"
  [ -s "$QCOW" ] || fail_exit "E1_SSH_DISK_CAPTURE" "WINDOWS_DISK_CAPTURE_FAILED" \
    "skip_capture_qcow2_missing" "No qcow2 at $QCOW — set OSPC2FLEX_METHOD_E_SKIP_CAPTURE=0 to re-capture."
  qemu-img info  "$QCOW" >>"$BACKGROUND_LOG" 2>&1 || fail_exit "E1_SSH_DISK_CAPTURE" "WINDOWS_DISK_CAPTURE_FAILED" \
    "skip_capture_qcow2_invalid"      "Existing qcow2 unreadable — re-run without --skip-capture."
  qemu-img check "$QCOW" >>"$BACKGROUND_LOG" 2>&1 || fail_exit "E1_SSH_DISK_CAPTURE" "WINDOWS_DISK_CAPTURE_FAILED" \
    "skip_capture_qcow2_check_failed" "Existing qcow2 failed integrity check — re-run without --skip-capture."
  _QCOW_SIZE=$(stat -c%s "$QCOW" 2>/dev/null || echo 0)
  [ "${_QCOW_SIZE:-0}" -ge $((10 * 1024 * 1024 * 1024)) ] || fail_exit "E1_SSH_DISK_CAPTURE" "WINDOWS_DISK_CAPTURE_FAILED" \
    "skip_capture_qcow2_too_small_${_QCOW_SIZE}B" "Existing qcow2 is ${_QCOW_SIZE}B < 10GiB — re-run without --skip-capture."
  json_merge "{\"qcow2_artifact\":\"$QCOW\",\"checkpoints\":{\"ssh_capture\":\"HIT\"}}"
  stage_log "E1_SSH_DISK_CAPTURE" "HIT skipped re-capture; using existing qcow2 ($((${_QCOW_SIZE}/1024/1024))MB)"
else
  stage_log "E1_SSH_DISK_CAPTURE" "Using Method B SSH capture engine: $METHOD_B_CAPTURE_SCRIPT"
  rm -f "${QCOW}.win_repaired" 2>/dev/null || true
  # Honor resume mode from launch env; only force-fresh when explicitly requested.
  _disable_resume="${OSPC2FLEX_DISABLE_RESUME:-0}"
  _resume_mode="${OSPC2FLEX_RESUME_MODE:-on}"
  capture_args=(
    --server-name "$SERVER_NAME"
    --server-ip   "$SERVER_IP"
    --label       "$LABEL"
    --workflow-tag method_e
    --windows-user     "$WIN_USER"
    --windows-password "$WIN_PASSWORD"
    --flavor   "$FLAVOR"
    --network  "$NETWORK"
    --keypair  "$KEYPAIR"
    --os-family windows
    --os-type   windows
  )
  [ "$_disable_resume" = "1" ] && capture_args+=(--disable-resume --force-fresh-capture)
  [ -n "$WIN_SNET_IP" ] && capture_args+=(--server-snet-ip "$WIN_SNET_IP")
  trap - ERR
  set +e
  OSPC2FLEX_METHOD_B_CAPTURE_ONLY=1 \
  OSPC2FLEX_SELF_TEE=0 \
  OSPC2FLEX_PARENT_METHOD_NAME="Method E" \
  OSPC2FLEX_CAPTURE_LOG_CONTEXT="Method E SSH Capture" \
  OSPC2FLEX_LEGACY_IMAGE_NAME=1 \
  OSPC2FLEX_DISABLE_RESUME="$_disable_resume" \
  OSPC2FLEX_FORCE_FRESH_CAPTURE="$_disable_resume" \
  OSPC2FLEX_RESUME_MODE="$_resume_mode" \
  OSPC2FLEX_ALLOW_WINDOWS_GLANCE_FALLBACK=0 \
  OSPC2FLEX_ALLOW_PROVIDER_EXPORT_FALLBACK=0 \
  OSPC2FLEX_ALLOW_DISK2VHD=0 \
  OSPC2FLEX_ALLOW_VSS_CAPTURE=0 \
  OSPC2FLEX_ALLOW_SMB_HTTPS_OBJECT_TRANSFER=0 \
  OSPC2FLEX_ALLOW_WINRM_AGENT_CAPTURE=0 \
  bash "$METHOD_B_CAPTURE_SCRIPT" "${capture_args[@]}" 2>&1 | tee -a "$BACKGROUND_LOG"
  pipe_status=("${PIPESTATUS[@]}")
  set +u; set -u; set -e
  trap 'unexpected_exit "$LINENO" "$BASH_COMMAND"' ERR
  capture_rc="${pipe_status[0]:-99}"
  tee_rc="${pipe_status[1]:-99}"
  if [ "$capture_rc" -ne 0 ] || [ "$tee_rc" -ne 0 ]; then
    if grep -Eiq 'Incorrect function|OSPC2FLEX_PHYSICAL_DRIVE_OPEN_FAILED|WINDOWS_RAW_DISK_READ_FAILED' "$BACKGROUND_LOG"; then
      fail_exit "E1_SSH_DISK_CAPTURE" "WINDOWS_DISK_CAPTURE_FAILED" "WINDOWS_RAW_DISK_READ_FAILED" \
        "SSH works but Windows rejected raw disk read. Fix SSH elevation/P/Invoke access before retry."
    fi
    fail_exit "E1_SSH_DISK_CAPTURE" "WINDOWS_DISK_CAPTURE_FAILED" "METHOD_B_SSH_CAPTURE_FAILED" \
      "Method B SSH capture failed. Fix SSH/OpenSSH/firewall/credential/elevation before retry."
  fi
  [ -s "$QCOW" ] || fail_exit "E1_SSH_DISK_CAPTURE" "WINDOWS_DISK_CAPTURE_FAILED" \
    "method_b_qcow_missing" "Method B capture did not produce $QCOW."
  qemu-img info  "$QCOW" >>"$BACKGROUND_LOG" 2>&1 || fail_exit "E1_SSH_DISK_CAPTURE" "WINDOWS_DISK_CAPTURE_FAILED" \
    "method_b_qcow_invalid"      "Repeat Method B SSH capture after fixing source disk read."
  qemu-img check "$QCOW" >>"$BACKGROUND_LOG" 2>&1 || fail_exit "E1_SSH_DISK_CAPTURE" "WINDOWS_DISK_CAPTURE_FAILED" \
    "method_b_qcow_check_failed" "Repeat Method B SSH capture after fixing source disk read."
  _QCOW_SIZE=$(stat -c%s "$QCOW" 2>/dev/null || echo 0)
  [ "${_QCOW_SIZE:-0}" -ge $((10 * 1024 * 1024 * 1024)) ] || fail_exit "E1_SSH_DISK_CAPTURE" "WINDOWS_DISK_CAPTURE_FAILED" \
    "partial_capture_qcow2_too_small_${_QCOW_SIZE}B" "Method B captured only ${_QCOW_SIZE}B — partial read. Fix SSH elevation before retry."
  json_merge "{\"qcow2_artifact\":\"$QCOW\",\"checkpoints\":{\"ssh_capture\":\"HIT\"}}"
  stage_log "E1_SSH_DISK_CAPTURE" "HIT Method B SSH capture produced validated qcow2"
fi

# ─── E2: Artifact validate ────────────────────────────────────────────────────
stage_start "E2_ARTIFACT_VALIDATE"
[ -s "$QCOW" ] || fail_exit "E2_ARTIFACT_VALIDATE" "SOURCE_ARTIFACT_INVALID" \
  "SSH_CAPTURE_ARTIFACT_INVALID" "Repeat Method B SSH capture after fixing source disk read."
qemu-img info  "$QCOW" >>"$BACKGROUND_LOG" 2>&1 || fail_exit "E2_ARTIFACT_VALIDATE" "SOURCE_ARTIFACT_INVALID" \
  "SSH_CAPTURE_ARTIFACT_INVALID" "Repeat Method B SSH capture after fixing source disk read."
qemu-img check "$QCOW" >>"$BACKGROUND_LOG" 2>&1 || fail_exit "E2_ARTIFACT_VALIDATE" "SOURCE_ARTIFACT_INVALID" \
  "SSH_CAPTURE_ARTIFACT_INVALID" "Repeat Method B SSH capture after fixing source disk read."
json_merge "{\"qcow2_artifact\":\"$QCOW\",\"checkpoints\":{\"artifact_validated\":\"HIT\"}}"
stage_log "E2_ARTIFACT_VALIDATE" "HIT qcow2 artifact validated"

# ─── E3: Offline Windows repair ───────────────────────────────────────────────
stage_start "E3_WINDOWS_REPAIR"
rm -f "${QCOW}.win_repaired" 2>/dev/null || true
bash "$WIN_REPAIR" --qcow2 "$QCOW" >>"$BACKGROUND_LOG" 2>&1 || fail_exit "E3_WINDOWS_REPAIR" "WINDOWS_REPAIR_FAILED" \
  "windows_repair_failed" "Use fresh SSH capture or restore registry backup."
[ -f "${QCOW}.win_repaired" ] || fail_exit "E3_WINDOWS_REPAIR" "WINDOWS_REPAIR_FAILED" \
  "win_repaired_sentinel_missing" "Use fresh SSH capture or restore registry backup."
qemu-img check "$QCOW" >>"$BACKGROUND_LOG" 2>&1 || fail_exit "E3_WINDOWS_REPAIR" "WINDOWS_REPAIR_FAILED" \
  "post_repair_qcow2_check_failed" "Use fresh SSH capture or restore registry backup."
checkpoint_hit "windows_repaired"
stage_log "E3_WINDOWS_REPAIR" "HIT qcow2 repaired and SYSTEM hive valid"

# ─── E4: Upload safe IDE/e1000 rescue image ───────────────────────────────────
stage_start "E4_UPLOAD_SAFE_RESCUE_IMAGE"
# shellcheck source=/dev/null
source "$FLEX_CREDS"
stage_log "E4_UPLOAD_SAFE_RESCUE_IMAGE" "Uploading via glance bridge (Cloud Files → Glance): $QCOW"
_bridge_out=$(env -u OS_TOKEN bash "$GLANCE_BRIDGE" upload \
  --flex-openrc "$FLEX_CREDS" \
  --image-file "$QCOW" \
  --image-name "$RESCUE_IMAGE_NAME" 2>>"$BACKGROUND_LOG" || true)
RESCUE_IMAGE_ID=$(printf '%s\n' "$_bridge_out" | grep '^FLEX_IMAGE_ID=' | cut -d= -f2 | head -1 | tr -d '\r' || true)
[ -n "$RESCUE_IMAGE_ID" ] || fail_exit "E4_UPLOAD_SAFE_RESCUE_IMAGE" "SAFE_RESCUE_IMAGE_FAILED" \
  "safe_rescue_image_upload_failed" "Inspect Flex Glance quota/auth and retry."
wait_for_image_active "$RESCUE_IMAGE_ID" "${OSPC2FLEX_IMAGE_ACTIVE_WAIT_SEC:-3600}" \
  || fail_exit "E4_UPLOAD_SAFE_RESCUE_IMAGE" "SAFE_RESCUE_IMAGE_FAILED" \
     "safe_rescue_image_not_active" "Inspect Flex Glance image status and retry."
openstack image set \
  --property hw_disk_bus=ide \
  --property hw_cdrom_bus=ide \
  --property hw_vif_model=e1000 \
  --property os_type=windows \
  --property os_distro=windows \
  --property vm_mode=hvm \
  "$RESCUE_IMAGE_ID" >>"$BACKGROUND_LOG" 2>&1 \
  || fail_exit "E4_UPLOAD_SAFE_RESCUE_IMAGE" "SAFE_RESCUE_IMAGE_FAILED" \
     "safe_metadata_set_failed" "Inspect Flex Glance metadata permissions and retry."
verify_safe_metadata "$RESCUE_IMAGE_ID" \
  || fail_exit "E4_UPLOAD_SAFE_RESCUE_IMAGE" "SAFE_RESCUE_IMAGE_FAILED" \
     "safe_metadata_verify_failed" "Safe rescue metadata must be IDE/e1000 only before boot."
json_merge "{\"rescue_image_id\":\"$RESCUE_IMAGE_ID\"}"
stage_log "E4_UPLOAD_SAFE_RESCUE_IMAGE" "HIT safe IDE/e1000 image uploaded"

# ─── E5: Boot safe IDE/e1000 rescue VM ───────────────────────────────────────
stage_start "E5_BOOT_SAFE_RESCUE_VM"
create_args=(server create "$RESCUE_SERVER_NAME" \
  --image "$RESCUE_IMAGE_ID" --flavor "$FLAVOR" --network "$NETWORK" \
  --wait -f value -c id)
[ -n "$KEYPAIR" ] && create_args+=(--key-name "$KEYPAIR")
RESCUE_SERVER_ID=$(openstack "${create_args[@]}" 2>/dev/null | tr -d '\r\n' || true)
[ -n "$RESCUE_SERVER_ID" ] || RESCUE_SERVER_ID=$(openstack server list \
  --name "$RESCUE_SERVER_NAME" -f value -c ID 2>/dev/null | head -1 | tr -d '\r\n' || true)
[ -n "$RESCUE_SERVER_ID" ] || fail_exit "E5_BOOT_SAFE_RESCUE_VM" "SAFE_IDE_RESCUE_BOOT_FAILED" \
  "rescue_server_create_failed" "Inspect rescue console and preserved rescue VM."
mgs_wait_for_server_status "$RESCUE_SERVER_ID" "ACTIVE" 900 \
  || fail_exit "E5_BOOT_SAFE_RESCUE_VM" "SAFE_IDE_RESCUE_BOOT_FAILED" \
     "rescue_server_not_active" "Inspect rescue console and preserved rescue VM."
RESCUE_FLOATING_IP=$(mgs_attach_floating_ip "$RESCUE_SERVER_ID" || true)
if console_has_fatal_boot_error "$RESCUE_SERVER_ID"; then console_rc=0; else console_rc=$?; fi
if [ "$console_rc" -eq 2 ]; then
  fail_exit "E5_BOOT_SAFE_RESCUE_VM" "SAFE_IDE_RESCUE_BOOT_FAILED" \
    "WINDOWS_SYSTEM_HIVE_OR_REGISTRY_STOP" "Restore SYSTEM hive backup and retry."
elif [ "$console_rc" -eq 3 ]; then
  fail_exit "E5_BOOT_SAFE_RESCUE_VM" "SAFE_IDE_RESCUE_BOOT_FAILED" \
    "INACCESSIBLE_BOOT_DEVICE" "Inspect rescue console and preserved rescue VM."
fi
OSPC2FLEX_V2_PREFERRED_IP="${RESCUE_FLOATING_IP:-}" \
  mgs_wait_for_windows_guest_access "$RESCUE_SERVER_ID" "safe_rescue" "$HEALTHCHECK_WAIT" \
  || fail_exit "E5_BOOT_SAFE_RESCUE_VM" "SAFE_IDE_RESCUE_BOOT_FAILED" \
     "rescue_guest_unreachable" "Inspect rescue console and preserved rescue VM."
json_merge "{\"rescue_server_id\":\"$RESCUE_SERVER_ID\",\"checkpoints\":{\"safe_rescue_boot\":\"HIT\"}}"
stage_log "E5_BOOT_SAFE_RESCUE_VM" "HIT safe IDE/e1000 rescue VM booted"

# ─── E6: Attach dummy VirtIO disk ────────────────────────────────────────────
stage_start "E6_ATTACH_DUMMY_VIRTIO"
DUMMY_VOLUME_ID=$(openstack volume create --size 1 "$DUMMY_VOLUME_NAME" \
  -f value -c id 2>/dev/null | tr -d '\r\n' || true)
[ -n "$DUMMY_VOLUME_ID" ] || fail_exit "E6_ATTACH_DUMMY_VIRTIO" "DUMMY_VIRTIO_ATTACH_FAILED" \
  "dummy_volume_create_failed" "Inspect Cinder quota/status; preserve rescue VM."
waited=0
while [ "$waited" -lt 300 ]; do
  vol_status=$(openstack volume show "$DUMMY_VOLUME_ID" -f value -c status 2>/dev/null | tr -d '\r' || echo "unknown")
  [ "$vol_status" = "available" ] && break
  sleep 5; waited=$((waited + 5))
done
[ "$(openstack volume show "$DUMMY_VOLUME_ID" -f value -c status 2>/dev/null | tr -d '\r' || echo unknown)" = "available" ] \
  || fail_exit "E6_ATTACH_DUMMY_VIRTIO" "DUMMY_VIRTIO_ATTACH_FAILED" \
     "dummy_volume_not_available" "Inspect Cinder volume status; preserve rescue VM and dummy disk."
openstack server add volume "$RESCUE_SERVER_ID" "$DUMMY_VOLUME_ID" >>"$BACKGROUND_LOG" 2>&1 \
  || fail_exit "E6_ATTACH_DUMMY_VIRTIO" "DUMMY_VIRTIO_ATTACH_FAILED" \
     "dummy_volume_attach_failed" "Inspect Nova/Cinder attachment; preserve rescue VM and dummy disk."
sleep 10
DUMMY_ATTACHMENT_ID=$(openstack volume show "$DUMMY_VOLUME_ID" -f json 2>/dev/null \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); a=d.get("attachments") or []; print((a[0] or {}).get("attachment_id","") if a else "")' \
  2>/dev/null || true)
DUMMY_DEVICE=$(openstack volume show "$DUMMY_VOLUME_ID" -f json 2>/dev/null \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); a=d.get("attachments") or []; print((a[0] or {}).get("device","") if a else "")' \
  2>/dev/null || true)
[ -n "$DUMMY_ATTACHMENT_ID$DUMMY_DEVICE" ] \
  || fail_exit "E6_ATTACH_DUMMY_VIRTIO" "DUMMY_VIRTIO_ATTACH_FAILED" \
     "dummy_volume_attachment_unconfirmed" "Inspect Nova/Cinder attachment; preserve rescue VM and dummy disk."
json_merge "{\"dummy_volume_id\":\"$DUMMY_VOLUME_ID\",\"dummy_attachment_id\":\"$DUMMY_ATTACHMENT_ID\",\"dummy_device\":\"$DUMMY_DEVICE\",\"checkpoints\":{\"dummy_virtio_attached\":\"HIT\"}}"
stage_log "E6_ATTACH_DUMMY_VIRTIO" "HIT dummy VirtIO disk attached"

# ─── E7: Online VirtIO driver binding ────────────────────────────────────────
stage_start "E7_ONLINE_VIRTIO_BINDING"
stage_log "E7_ONLINE_VIRTIO_BINDING" "Waiting 60s for Windows to enumerate hot-attached VirtIO disk..."
sleep 60
_BIND_DONE=0
for _try in 1 2 3; do
  if run_driver_binding; then _BIND_DONE=1; break; fi
  [ "$_try" -lt 3 ] && { stage_log "E7_ONLINE_VIRTIO_BINDING" "Binding attempt $_try/3 pending — waiting 60s..."; sleep 60; }
done
[ "$_BIND_DONE" -eq 1 ] || fail_exit "E7_ONLINE_VIRTIO_BINDING" "VIRTIO_DRIVER_BINDING_FAILED" \
  "virtio_driver_binding_failed" "Use console/RDP to inspect VirtIO driver install."
checkpoint_hit "online_virtio_bound"
stage_log "E7_ONLINE_VIRTIO_BINDING" "HIT VirtIO drivers installed and dummy device visible"

# ─── E8: Reboot on IDE, verify drivers survive ───────────────────────────────
stage_start "E8_REBOOT_STILL_IDE"
mgs_run_windows_ps "Restart-Computer -Force" >>"$BACKGROUND_LOG" 2>&1 || true
sleep 20
ACCESS_METHOD=""; ACCESS_IP=""; ACCESS_PORT=""
OSPC2FLEX_V2_PREFERRED_IP="${RESCUE_FLOATING_IP:-}" \
  mgs_wait_for_windows_guest_access "$RESCUE_SERVER_ID" "rescue_reboot_still_ide" "$HEALTHCHECK_WAIT" \
  || fail_exit "E8_REBOOT_STILL_IDE" "WINDOWS_REBOOT_AFTER_DRIVER_BINDING_FAILED" \
     "rescue_reboot_guest_unreachable" "Use console/RDP to inspect driver install."
run_driver_binding \
  || fail_exit "E8_REBOOT_STILL_IDE" "WINDOWS_REBOOT_AFTER_DRIVER_BINDING_FAILED" \
     "post_reboot_virtio_verify_failed" "Use console/RDP to inspect driver install."
checkpoint_hit "online_virtio_bound"
stage_log "E8_REBOOT_STILL_IDE" "HIT Windows rebooted successfully while still IDE/e1000"

# ─── E9: Snapshot VirtIO-ready state ─────────────────────────────────────────
stage_start "E9_SNAPSHOT_VIRTIO_READY"
openstack server stop "$RESCUE_SERVER_ID" >>"$BACKGROUND_LOG" 2>&1 || true
mgs_wait_for_server_status "$RESCUE_SERVER_ID" "SHUTOFF" 900 \
  || fail_exit "E9_SNAPSHOT_VIRTIO_READY" "VIRTIO_READY_SNAPSHOT_FAILED" \
     "rescue_server_stop_failed" "Inspect rescue VM and retry snapshot."
FINAL_IMAGE_ID=$(openstack server image create "$RESCUE_SERVER_ID" \
  --name "$FINAL_IMAGE_NAME" -f value -c id 2>/dev/null | tr -d '\r\n' || true)
[ -n "$FINAL_IMAGE_ID" ] || fail_exit "E9_SNAPSHOT_VIRTIO_READY" "VIRTIO_READY_SNAPSHOT_FAILED" \
  "virtio_ready_snapshot_failed" "Inspect rescue VM snapshot task."
wait_for_image_active "$FINAL_IMAGE_ID" "${OSPC2FLEX_IMAGE_ACTIVE_WAIT_SEC:-3600}" \
  || fail_exit "E9_SNAPSHOT_VIRTIO_READY" "VIRTIO_READY_SNAPSHOT_FAILED" \
     "virtio_ready_image_not_active" "Inspect Flex Glance image status."
openstack image set \
  --property hw_disk_bus=scsi \
  --property hw_scsi_model=virtio-scsi \
  --property hw_vif_model=virtio \
  --property hw_qemu_guest_agent=yes \
  "$FINAL_IMAGE_ID" >>"$BACKGROUND_LOG" 2>&1 \
  || fail_exit "E9_SNAPSHOT_VIRTIO_READY" "VIRTIO_READY_SNAPSHOT_FAILED" \
     "final_metadata_set_failed" "Inspect Flex Glance metadata permissions."
verify_final_metadata "$FINAL_IMAGE_ID" \
  || fail_exit "E9_SNAPSHOT_VIRTIO_READY" "VIRTIO_READY_SNAPSHOT_FAILED" \
     "final_metadata_verify_failed" "Final image metadata must be virtio-scsi/virtio."
json_merge "{\"virtio_ready_image_id\":\"$FINAL_IMAGE_ID\"}"
stage_log "E9_SNAPSHOT_VIRTIO_READY" "HIT virtio-ready snapshot created and metadata applied"

# ─── E10: Boot final VirtIO/SCSI VM ──────────────────────────────────────────
stage_start "E10_BOOT_FINAL_VIRTIO"
final_args=(server create "$FINAL_SERVER_NAME" \
  --image "$FINAL_IMAGE_ID" --flavor "$FLAVOR" --network "$NETWORK" \
  --wait -f value -c id)
[ -n "$KEYPAIR" ] && final_args+=(--key-name "$KEYPAIR")
FINAL_SERVER_ID=$(openstack "${final_args[@]}" 2>/dev/null | tr -d '\r\n' || true)
[ -n "$FINAL_SERVER_ID" ] || FINAL_SERVER_ID=$(openstack server list \
  --name "$FINAL_SERVER_NAME" -f value -c ID 2>/dev/null | head -1 | tr -d '\r\n' || true)
[ -n "$FINAL_SERVER_ID" ] || fail_exit "E10_BOOT_FINAL_VIRTIO" "FINAL_VIRTIO_BOOT_FAILED" \
  "final_server_create_failed" "Inspect final image metadata and Nova boot request."
mgs_wait_for_server_status "$FINAL_SERVER_ID" "ACTIVE" 900 \
  || fail_exit "E10_BOOT_FINAL_VIRTIO" "FINAL_VIRTIO_BOOT_FAILED" \
     "final_server_not_active" "Inspect final VM console."
FINAL_FLOATING_IP=$(mgs_attach_floating_ip "$FINAL_SERVER_ID" || true)
json_merge "{\"final_server_id\":\"$FINAL_SERVER_ID\"}"
stage_log "E10_BOOT_FINAL_VIRTIO" "HIT final virtio-scsi VM ACTIVE"

# ─── E11: Success ─────────────────────────────────────────────────────────────
stage_start "E11_SUCCESS"
json_merge "{\"stage\":\"E11_SUCCESS\",\"status\":\"METHOD_E_SUCCESS\",\"final\":true,\"checkpoints\":{\"final_boot_validated\":\"HIT\"}}"
stage_log "E11_SUCCESS" "HIT METHOD_E_SUCCESS — B-capture + G-deploy pipeline complete"
echo "METHOD_E_SUCCESS"
