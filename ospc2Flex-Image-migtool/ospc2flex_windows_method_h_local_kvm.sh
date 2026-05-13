#!/usr/bin/env bash
# Method H — Local KVM VirtIO Prep + Flex Import
#
# SSH capture -> local KVM IDE boot with dummy VirtIO disk -> driver bind
# -> optional local VirtIO boot test -> upload prepared qcow2 to Flex.

set -euo pipefail

if [ -z "${OSPC2FLEX_LINEBUF_WRAPPER:-}" ] && command -v stdbuf >/dev/null 2>&1; then
  export OSPC2FLEX_LINEBUF_WRAPPER=1
  exec stdbuf -oL -eL bash "$0" "$@"
fi

export OSPC2FLEX_METHOD_H_LOCAL_KVM=1
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
FLEX_CREDS="${FLEX_CREDS:-/tmp/ospc2flex_flex.sh}"
export FLEX_EXT_NET="${OSPC2FLEX_FLEX_EXT_NET:-PUBLICNET}"
VIRTIO_ISO="${OSPC2FLEX_VIRTIO_ISO:-/mnt/migration/virtio/virtio-win.iso}"
WIN_REPAIR="${WIN_REPAIR:-/tmp/ospc2flex_windows_repair.sh}"
INSTALL_DEPS="${OSPC2FLEX_INSTALL_DEPS:-0}"
DRIVER_WAIT_SECONDS="${OSPC2FLEX_METHOD_H_DRIVER_WAIT_SECONDS:-7200}"
FINAL_WAIT_SECONDS="${OSPC2FLEX_METHOD_H_FINAL_WAIT_SECONDS:-1200}"
LOCAL_RAM_MB="${OSPC2FLEX_METHOD_H_RAM_MB:-4096}"
LOCAL_VCPUS="${OSPC2FLEX_METHOD_H_VCPUS:-2}"
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
    --virtio-iso) VIRTIO_ISO="$2"; shift 2 ;;
    --server-snet-ip) WIN_SNET_IP="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --os-family|--os-type|--source-server-id|--cloudboot-target-host|--cloudboot-target-user|--cloudboot-target-password|--cloudboot-source-winrm-host|--cloudboot-target-winrm-host)
      shift 2 ;;
    *) shift ;;
  esac
done

[ -n "$LABEL" ] || { echo "ERROR: --label required"; exit 2; }
[ -n "$SERVER_IP" ] || { echo "ERROR: --server-ip required"; exit 2; }
[ -n "$WIN_PASSWORD" ] || { echo "ERROR: --windows-password required for Method H"; exit 2; }
SERVER_NAME="${SERVER_NAME:-$LABEL}"

LOG_DIR="$WORK/logs"
mkdir -p "$LOG_DIR"
PROGRESS_LOG="$LOG_DIR/${LABEL}.progress.log"
BACKGROUND_LOG="$LOG_DIR/${LABEL}.background.log"
STATE_JSON="$WORK/${LABEL}.method_h_local_kvm.json"
RAW_PARTIAL="$WORK/${LABEL}.raw.partial"
RAW="$WORK/${LABEL}.raw"
QCOW="$WORK/${LABEL}.qcow2"
DUMMY_DISK="$WORK/${LABEL}-dummy-virtio.qcow2"
LOCAL_VM_NAME="${LABEL}-method-h-local"
LIBVIRT_XML="$WORK/${LABEL}.method_h.local_vm.xml"
DRIVER_MARKER="$WORK/${LABEL}.method_h.drivers_bound"
FINAL_IMAGE_NAME="${LABEL}-method-h"
FINAL_SERVER_NAME="${LABEL}-method-h-final"

FIRMWARE_TYPE="unknown"
FINAL_IMAGE_ID=""
FINAL_SERVER_ID=""
CURRENT_STAGE="CAPTURE"
TMP_FILES=()
HB_FLAG=""
HB_PID=""

: >"$PROGRESS_LOG"
: >"$BACKGROUND_LOG"

log() {
  local line
  line="[$(date '+%H:%M:%S')][$LABEL][MethodH] $*"
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
for k, v in updates.items():
    if isinstance(v, dict) and isinstance(doc.get(k), dict):
        merged = dict(doc[k])
        merged.update(v)
        doc[k] = merged
    else:
        doc[k] = v
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
PY
}

init_state() {
  json_merge "$(cat <<EOF
{
  "method": "H_LOCAL_KVM",
  "status": "RUNNING",
  "stage": "CAPTURE",
  "source_ip": "$SERVER_IP",
  "raw_artifact": "",
  "qcow2_artifact": "",
  "dummy_disk": "",
  "virtio_iso": "$VIRTIO_ISO",
  "firmware_type": "unknown",
  "local_vm_name": "$LOCAL_VM_NAME",
  "final_image_id": "",
  "final_server_id": "",
  "checkpoints": {
    "capture": "PENDING",
    "offline_repair": "PENDING",
    "local_kvm_boot": "PENDING",
    "virtio_drivers_bound": "PENDING",
    "flex_final_boot": "PENDING"
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
    CAPTURE) echo "capture" ;;
    OFFLINE_REPAIR) echo "offline_repair" ;;
    LOCAL_KVM_PREP) echo "local_kvm_boot" ;;
    DRIVER_BIND) echo "virtio_drivers_bound" ;;
    FLEX_IMPORT) echo "flex_final_boot" ;;
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
  local stage="$1" reason="$2" next="$3"
  local cp
  cp="$(checkpoint_for_stage "$stage")"
  stage_log "$stage" "FAILED $reason"
  log "next_action=$next"
  if [ -n "$cp" ]; then
    json_merge "{\"stage\":\"$stage\",\"status\":\"FAILED\",\"failure_reason\":\"$reason\",\"next_action\":\"$next\",\"final\":false,\"checkpoints\":{\"$cp\":\"FAILED\"}}"
  else
    json_merge "{\"stage\":\"$stage\",\"status\":\"FAILED\",\"failure_reason\":\"$reason\",\"next_action\":\"$next\",\"final\":false}"
  fi
  exit 1
}

unexpected_exit() {
  fail_exit "${CURRENT_STAGE:-CAPTURE}" "unexpected_error_line_$1" "Inspect $BACKGROUND_LOG near: $2"
}

new_tmp_file() {
  local t
  t=$(mktemp "/tmp/ospc2flex_mh_${LABEL}_XXXXXX")
  TMP_FILES+=("$t")
  printf '%s\n' "$t"
}

cleanup_tmp_files() {
  local f
  [ -n "${HB_FLAG:-}" ] && rm -f "$HB_FLAG" 2>/dev/null || true
  [ -n "${HB_PID:-}" ] && kill "$HB_PID" 2>/dev/null || true
  for f in "${TMP_FILES[@]:-}"; do
    [ -n "$f" ] && rm -f "$f" 2>/dev/null || true
  done
}

terminate_exit() {
  local sig="$1"
  trap - TERM INT HUP
  fail_exit "${CURRENT_STAGE:-CAPTURE}" "terminated_by_${sig}" "The Method H process was stopped or replaced while running. Retry only after the prior job is fully stopped; keep Fresh Sync enabled if you want to discard the partial raw."
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail_exit "$CURRENT_STAGE" "missing_command_$1" "Install dependencies: sudo apt install qemu-kvm libvirt-daemon-system libvirt-clients virtinst ovmf"
}

install_deps_if_requested() {
  if [ "$INSTALL_DEPS" = "1" ]; then
    { sudo apt-get update -qq; } >>"$BACKGROUND_LOG" 2>&1 || true
    { sudo DEBIAN_FRONTEND=noninteractive apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients virtinst ovmf; } >>"$BACKGROUND_LOG" 2>&1 || true
  fi
}

ssh_base() {
  sshpass -p "$WIN_PASSWORD" ssh \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -o ConnectTimeout=30 \
    -o PreferredAuthentications=password,keyboard-interactive \
    -o PubkeyAuthentication=no \
    "$WIN_USER@$SERVER_IP" "$@"
}

detect_firmware_type() {
  local _detect_src="$RAW" _nbd_tmp="" _nbd_used=0
  if [ ! -f "$_detect_src" ] && [ -f "$QCOW" ]; then
    _nbd_tmp="${OSPC2FLEX_WIN_NBD_DEV:-/dev/nbd8}"
    { sudo qemu-nbd --read-only --connect="$_nbd_tmp" "$QCOW"; } >>"$BACKGROUND_LOG" 2>&1 && _nbd_used=1 || _nbd_tmp=""
    _detect_src="$_nbd_tmp"
  fi
  if [ -n "$_detect_src" ]; then
    if command -v sgdisk >/dev/null 2>&1 && { sudo sgdisk -p "$_detect_src"; } >>"$BACKGROUND_LOG" 2>&1; then
      if sudo sgdisk -p "$_detect_src" 2>/dev/null | grep -Eiq 'EF00|EFI System'; then
        FIRMWARE_TYPE="uefi"
        [ "$_nbd_used" -eq 1 ] && { sudo qemu-nbd --disconnect "$_nbd_tmp"; } >>"$BACKGROUND_LOG" 2>&1 || true
        return 0
      fi
    fi
    if command -v parted >/dev/null 2>&1; then
      local p
      p=$(sudo parted -m "$_detect_src" print 2>/dev/null || true)
      if printf '%s\n' "$p" | grep -Eiq '^/.*:.*:gpt:' && printf '%s\n' "$p" | grep -Eiq 'esp|EFI'; then
        FIRMWARE_TYPE="uefi"
        [ "$_nbd_used" -eq 1 ] && { sudo qemu-nbd --disconnect "$_nbd_tmp"; } >>"$BACKGROUND_LOG" 2>&1 || true
        return 0
      fi
      if printf '%s\n' "$p" | grep -Eiq '^/.*:.*:msdos:'; then
        FIRMWARE_TYPE="bios"
        [ "$_nbd_used" -eq 1 ] && { sudo qemu-nbd --disconnect "$_nbd_tmp"; } >>"$BACKGROUND_LOG" 2>&1 || true
        return 0
      fi
    fi
  fi
  [ "$_nbd_used" -eq 1 ] && { sudo qemu-nbd --disconnect "$_nbd_tmp"; } >>"$BACKGROUND_LOG" 2>&1 || true
  FIRMWARE_TYPE="unknown"
}

ovmf_code_path() {
  for p in /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
    [ -f "$p" ] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

wait_for_local_shutdown_or_marker() {
  local waited=0 state
  log "Driver install instructions: open the VNC console for $LOCAL_VM_NAME and run pnputil /add-driver D:\\*.inf /subdirs /install or virtio-win guest tools, then shut down Windows."
  log "Marker override: touch $DRIVER_MARKER after drivers are bound."
  while [ "$waited" -lt "$DRIVER_WAIT_SECONDS" ]; do
    [ -f "$DRIVER_MARKER" ] && return 0
    state=$(virsh domstate "$LOCAL_VM_NAME" 2>/dev/null || true)
    if printf '%s\n' "$state" | grep -Eiq 'shut off|shutoff'; then
      return 0
    fi
    sleep 30
    waited=$((waited + 30))
  done
  return 1
}

console_has_fatal_boot_error() {
  local server_id="$1" console
  console="$(openstack console log show "$server_id" 2>/dev/null || true)"
  if printf '%s\n' "$console" | grep -Eiq 'Windows\\system32\\config\\system|0xc0000225'; then return 2; fi
  if printf '%s\n' "$console" | grep -Eiq 'INACCESSIBLE_BOOT_DEVICE'; then return 3; fi
  return 0
}

wait_for_server_status() {
  local server_id="$1" target="$2" timeout="$3" waited=0 status
  while [ "$waited" -lt "$timeout" ]; do
    status=$(openstack server show "$server_id" -f value -c status 2>/dev/null | tr -d '\r' || echo UNKNOWN)
    [ "$status" = "$target" ] && return 0
    sleep 10
    waited=$((waited + 10))
  done
  return 1
}

trap 'unexpected_exit "$LINENO" "$BASH_COMMAND"' ERR
trap 'terminate_exit TERM' TERM
trap 'terminate_exit INT' INT
trap 'terminate_exit HUP' HUP
trap cleanup_tmp_files EXIT

echo "═══════════════════════════════════════════════════════════════════════════"
echo "Method H — Local KVM VirtIO Prep + Flex Import"
echo "═══════════════════════════════════════════════════════════════════════════"
echo "Server  : $SERVER_NAME ($SERVER_IP)"
echo "Label   : $LABEL"
echo "VirtIO  : $VIRTIO_ISO"
echo "═══════════════════════════════════════════════════════════════════════════"

init_state

stage_start "CAPTURE"
install_deps_if_requested
require_cmd nc
require_cmd sshpass
require_cmd ssh
require_cmd qemu-img
require_cmd python3
if [ "$DRY_RUN" = 1 ]; then
  stage_log "CAPTURE" "HIT dry-run dependency check complete"
  json_merge '{"status":"DRY_RUN","final":false}'
  exit 0
fi
METHOD_B_CAPTURE_SCRIPT="${OSPC2FLEX_METHOD_B_CAPTURE_SCRIPT:-/tmp/ospc2flex_windows_method_d_capture.sh}"
[ -f "$METHOD_B_CAPTURE_SCRIPT" ] || METHOD_B_CAPTURE_SCRIPT="$(dirname "$0")/ospc2flex_windows_method_d_capture.sh"
[ -f "$METHOD_B_CAPTURE_SCRIPT" ] || fail_exit "CAPTURE" "method_b_capture_script_missing" "Sync ospc2flex_windows_method_d_capture.sh to the jumphost and retry."
_h_qcow_sz=$(stat -c%s "$QCOW" 2>/dev/null || echo 0)
if [ "${_h_qcow_sz:-0}" -ge $((1*1024*1024*1024)) ] && qemu-img info "$QCOW" >/dev/null 2>&1; then
  stage_log "CAPTURE" "HIT resume from existing qcow2: $QCOW ($((${_h_qcow_sz}/1024/1024))MB)"
  json_merge "{\"qcow2_artifact\":\"$QCOW\",\"checkpoints\":{\"capture\":\"HIT\"}}"
  checkpoint_hit "capture"
elif [ -s "$RAW" ] && qemu-img info "$RAW" >/dev/null 2>&1; then
  stage_log "CAPTURE" "Resume from raw capture: $RAW — converting to qcow2"
  qemu-img convert -O qcow2 "$RAW" "$QCOW" >>"$BACKGROUND_LOG" 2>&1 \
    || fail_exit "CAPTURE" "METHOD_H_RAW_CONVERT_FAILED" "qemu-img convert raw→qcow2 failed. Remove raw file and retry."
  stage_log "CAPTURE" "HIT raw converted to qcow2: $QCOW"
  json_merge "{\"qcow2_artifact\":\"$QCOW\",\"checkpoints\":{\"capture\":\"HIT\"}}"
  checkpoint_hit "capture"
else
  rm -f "$QCOW" "$RAW_PARTIAL" "$RAW" 2>/dev/null || true
  stage_log "CAPTURE" "Using Method B SSH disk download engine: $METHOD_B_CAPTURE_SCRIPT"
  capture_args=(
    --server-name "$SERVER_NAME"
    --server-ip "$SERVER_IP"
    --label "$LABEL"
    --workflow-tag method_h_local_kvm
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
  OSPC2FLEX_METHOD_H_CAPTURE_ONLY=1 \
  OSPC2FLEX_PARENT_METHOD_NAME="Method H Local KVM" \
  OSPC2FLEX_CAPTURE_LOG_CONTEXT="Shared Method B SSH Capture" \
  OSPC2FLEX_LEGACY_IMAGE_NAME=1 \
  OSPC2FLEX_ALLOW_WINDOWS_GLANCE_FALLBACK=0 \
  OSPC2FLEX_ALLOW_PROVIDER_EXPORT_FALLBACK=0 \
  OSPC2FLEX_ALLOW_DISK2VHD=0 \
  OSPC2FLEX_ALLOW_VSS_CAPTURE=0 \
  OSPC2FLEX_ALLOW_SMB_HTTPS_OBJECT_TRANSFER=0 \
  OSPC2FLEX_ALLOW_WINRM_AGENT_CAPTURE=0 \
  bash "$METHOD_B_CAPTURE_SCRIPT" "${capture_args[@]}" 2>&1 | tee -a "$BACKGROUND_LOG"
  pipe_status=("${PIPESTATUS[@]}")
  set +u
  set -u
  set -e
  trap 'unexpected_exit "$LINENO" "$BASH_COMMAND"' ERR
  capture_rc="${pipe_status[0]:-99}"
  tee_rc="${pipe_status[1]:-0}"
  if [ "$capture_rc" -ne 0 ] || [ "$tee_rc" -ne 0 ]; then
    fail_exit "CAPTURE" "METHOD_B_SSH_CAPTURE_FAILED" "Method B SSH disk download failed. Fix SSH/OpenSSH/firewall/credential/elevation before retry."
  fi
  [ -s "$QCOW" ] || fail_exit "CAPTURE" "method_b_qcow_missing" "Method B capture did not produce $QCOW."
  qemu-img info "$QCOW" >>"$BACKGROUND_LOG" 2>&1 || fail_exit "CAPTURE" "method_b_qcow_invalid" "Repeat Method B SSH capture after fixing source disk read."
  qemu-img check "$QCOW" >>"$BACKGROUND_LOG" 2>&1 || fail_exit "CAPTURE" "method_b_qcow_check_failed" "Repeat Method B SSH capture after fixing source disk read."
  json_merge "{\"qcow2_artifact\":\"$QCOW\",\"checkpoints\":{\"capture\":\"HIT\"}}"
  checkpoint_hit "capture"
  stage_log "CAPTURE" "HIT Method B SSH capture produced validated qcow2"
fi

stage_start "OFFLINE_REPAIR"
WIN_REPAIR_SENTINEL="$QCOW.win_repaired"
rm -f "$WIN_REPAIR_SENTINEL"
if [ -f "$WIN_REPAIR" ]; then
  stage_log "OFFLINE_REPAIR" "Running offline Windows repair (VirtIO drivers + Xen class filter removal)"
  _h_repair_log="${QCOW%.qcow2}.repair.debug.log"
  set +e
  bash "$WIN_REPAIR" --qcow2 "$QCOW" --force --debug --debug-log "$_h_repair_log" >>"$BACKGROUND_LOG" 2>&1
  _h_repair_rc=$?
  set -e
  if [ "$_h_repair_rc" -eq 0 ]; then
    stage_log "OFFLINE_REPAIR" "HIT offline repair completed"
  else
    fail_exit "OFFLINE_REPAIR" "WINDOWS_REPAIR_FAILED" "Offline repair exited rc=$_h_repair_rc. Inspect $BACKGROUND_LOG and ${_h_repair_log}."
  fi
else
  stage_log "OFFLINE_REPAIR" "WIN_REPAIR script not found at $WIN_REPAIR — skipping (stage jumphost if needed)"
fi
json_merge "{\"checkpoints\":{\"offline_repair\":\"HIT\"}}"
checkpoint_hit "offline_repair"

stage_start "LOCAL_KVM_PREP"
require_cmd qemu-img
require_cmd virt-install
require_cmd virsh
require_cmd qemu-system-x86_64
if [ ! -S /var/run/libvirt/libvirt-sock ] && [ ! -S /run/libvirt/libvirt-sock ]; then
  fail_exit "LOCAL_KVM_PREP" "libvirt_socket_missing" "Start libvirt: sudo systemctl enable --now libvirtd"
fi
[ -f "$VIRTIO_ISO" ] || fail_exit "LOCAL_KVM_PREP" "virtio_iso_missing" "Set OSPC2FLEX_VIRTIO_ISO=/path/to/virtio-win.iso"
qemu-img info "$QCOW" >>"$BACKGROUND_LOG" 2>&1 || fail_exit "LOCAL_KVM_PREP" "qemu_img_info_failed" "Inspect qcow2 artifact."
qemu-img check "$QCOW" >>"$BACKGROUND_LOG" 2>&1 || fail_exit "LOCAL_KVM_PREP" "qemu_img_check_failed" "Inspect qcow2 artifact."
qemu-img create -f qcow2 "$DUMMY_DISK" 5G >>"$BACKGROUND_LOG" 2>&1 || fail_exit "LOCAL_KVM_PREP" "dummy_disk_create_failed" "Check free space under $WORK."
detect_firmware_type
json_merge "{\"qcow2_artifact\":\"$QCOW\",\"dummy_disk\":\"$DUMMY_DISK\",\"virtio_iso\":\"$VIRTIO_ISO\",\"firmware_type\":\"$FIRMWARE_TYPE\"}"
if [ "$FIRMWARE_TYPE" = "uefi" ]; then
  ovmf_code_path >/dev/null || fail_exit "LOCAL_KVM_PREP" "ovmf_missing_for_uefi" "Install OVMF: sudo apt install ovmf"
fi
stage_log "LOCAL_KVM_PREP" "HIT qcow2/dummy disk ready firmware_type=$FIRMWARE_TYPE"

stage_start "DRIVER_BIND"
if [ ! -e /dev/kvm ]; then
  log "WARNING: No /dev/kvm — Windows VM will run in QEMU software emulation (10-30x slower). Boot may take 20-60 min."
fi
# Ensure libvirt default network is active before virt-install
if ! sudo virsh net-info default 2>/dev/null | grep -q 'Active:.*yes'; then
  log "libvirt default network not active — starting it now"
  { sudo virsh net-start default; } >>"$BACKGROUND_LOG" 2>&1 || fail_exit "DRIVER_BIND" "libvirt_net_start_failed" "Run: sudo virsh net-start default"
  { sudo virsh net-autostart default; } >>"$BACKGROUND_LOG" 2>&1 || true
fi
_kvm_osinfo="win2k19"
case "$LABEL" in
  *2016*|*win16*|*w2k16*) _kvm_osinfo="win2k16" ;;
  *2022*|*win22*|*w2k22*) _kvm_osinfo="win2k22" ;;
  *2025*|*win25*|*w2k25*) _kvm_osinfo="win2k25" ;;
esac
log "Using virt-install osinfo: $_kvm_osinfo"
# shellcheck disable=SC2054
boot_args=(virt-install --name "$LOCAL_VM_NAME" --memory "$LOCAL_RAM_MB" --vcpus "$LOCAL_VCPUS" --import --noautoconsole --os-variant "$_kvm_osinfo" --machine pc --graphics vnc,listen=0.0.0.0 --disk "path=$QCOW,bus=ide,format=qcow2" --disk "path=$DUMMY_DISK,bus=virtio,format=qcow2" --cdrom "$VIRTIO_ISO" --network "network=default,model=virtio")
if [ "$FIRMWARE_TYPE" = "uefi" ]; then
  boot_args+=(--boot uefi)
fi
"${boot_args[@]}" >>"$BACKGROUND_LOG" 2>&1 || fail_exit "DRIVER_BIND" "local_kvm_boot_failed" "Preserved qcow2, dummy disk, and libvirt logs. Inspect with virsh console/VNC."
virsh dumpxml "$LOCAL_VM_NAME" >"$LIBVIRT_XML" 2>>"$BACKGROUND_LOG" || true
json_merge "{\"local_vm_name\":\"$LOCAL_VM_NAME\"}"
checkpoint_hit "local_kvm_boot"
stage_log "DRIVER_BIND" "Local VM booted (q35/SATA) with dummy VirtIO disk and VirtIO ISO attached"
wait_for_local_shutdown_or_marker || fail_exit "DRIVER_BIND" "virtio_driver_binding_timeout" "Local VM kept for manual console/RDP debugging. Install VirtIO drivers and shut it down."
[ -f "$DRIVER_MARKER" ] || log "No explicit marker found; accepting clean local shutdown as operator-completed driver bind."
checkpoint_hit "virtio_drivers_bound"
stage_log "DRIVER_BIND" "HIT driver bind step completed"

stage_start "FLEX_IMPORT"
if virsh dominfo "$LOCAL_VM_NAME" >/dev/null 2>&1; then
  virsh dumpxml "$LOCAL_VM_NAME" >"$LIBVIRT_XML" 2>>"$BACKGROUND_LOG" || true
  virsh undefine "$LOCAL_VM_NAME" --nvram >>"$BACKGROUND_LOG" 2>&1 || virsh undefine "$LOCAL_VM_NAME" >>"$BACKGROUND_LOG" 2>&1 || true
fi
# shellcheck source=/dev/null
source "$FLEX_CREDS"
FINAL_IMAGE_ID=$(openstack image create "$FINAL_IMAGE_NAME" --disk-format qcow2 --container-format bare --file "$QCOW" -f value -c id 2>/dev/null | tr -d '\r\n' || true)
[ -n "$FINAL_IMAGE_ID" ] || fail_exit "FLEX_IMPORT" "final_image_upload_failed" "Inspect Flex Glance quota/auth and retry."
openstack image set --property hw_disk_bus=scsi --property hw_scsi_model=virtio-scsi --property hw_vif_model=virtio --property hw_qemu_guest_agent=yes "$FINAL_IMAGE_ID" >>"$BACKGROUND_LOG" 2>&1 || fail_exit "FLEX_IMPORT" "final_metadata_set_failed" "Inspect Flex image metadata permissions."
if [ "$FIRMWARE_TYPE" = "uefi" ]; then
  openstack image set --property hw_firmware_type=uefi "$FINAL_IMAGE_ID" >>"$BACKGROUND_LOG" 2>&1 || fail_exit "FLEX_IMPORT" "uefi_metadata_set_failed" "Inspect Flex image metadata permissions."
fi
server_args=(server create "$FINAL_SERVER_NAME" --image "$FINAL_IMAGE_ID" --flavor "$FLAVOR" --network "$NETWORK" --wait -f value -c id)
[ -n "$KEYPAIR" ] && server_args+=(--key-name "$KEYPAIR")
FINAL_SERVER_ID=$(openstack "${server_args[@]}" 2>/dev/null | tr -d '\r\n' || true)
[ -n "$FINAL_SERVER_ID" ] || FINAL_SERVER_ID=$(openstack server list --name "$FINAL_SERVER_NAME" -f value -c ID 2>/dev/null | head -1 | tr -d '\r\n' || true)
[ -n "$FINAL_SERVER_ID" ] || fail_exit "FLEX_IMPORT" "final_server_create_failed" "Final image kept for diagnostics."
wait_for_server_status "$FINAL_SERVER_ID" "ACTIVE" "$FINAL_WAIT_SECONDS" || fail_exit "FLEX_IMPORT" "final_server_not_active" "Final image/server kept for diagnostics."
if console_has_fatal_boot_error "$FINAL_SERVER_ID"; then console_rc=0; else console_rc=$?; fi
if [ "$console_rc" -eq 2 ]; then
  fail_exit "FLEX_IMPORT" "WINDOWS_SYSTEM_HIVE_OR_REGISTRY_STOP" "Final image/server kept. Use fresh SSH capture or restore registry backup."
elif [ "$console_rc" -eq 3 ]; then
  fail_exit "FLEX_IMPORT" "INACCESSIBLE_BOOT_DEVICE" "Final image/server kept. Recheck local VirtIO driver bind."
fi
json_merge "{\"final_image_id\":\"$FINAL_IMAGE_ID\",\"final_server_id\":\"$FINAL_SERVER_ID\",\"checkpoints\":{\"flex_final_boot\":\"HIT\"}}"
checkpoint_hit "flex_final_boot"
stage_log "FLEX_IMPORT" "HIT final Flex VM ACTIVE and console clean"
json_merge "{\"stage\":\"FLEX_IMPORT\",\"status\":\"METHOD_H_SUCCESS\",\"final\":true}"
echo "METHOD_H_SUCCESS"
