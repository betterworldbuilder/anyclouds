#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# ospc2flex_windows_method_d_capture.sh — Windows Method D Capture Workflow
# ═══════════════════════════════════════════════════════════════════════════════
# Primary path  (Step 1b+2): WinRM → installs OpenSSH on Windows → SSH+PowerShell
#               reads PhysicalDrive0 directly to jumphost (same as Linux NBD flow).
# Fallback path (Step 2):    Glance snapshot → Cloud Files bridge → download.
#
# Usage:
#   bash ospc2flex_windows_method_d_capture.sh \
#     --server-name "win2019websql2019" \
#     --server-ip "104.130.26.6" \
#     --label "ospc2flex-win2019" \
#     --windows-password "MyAdminPass" \
#     [--windows-user "Administrator"] \
#     [--flavor "gp.0.4.4"] [--network "tenant-net"] [--keypair "laptopubuntu24"]
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
FLAVOR="gp.0.4.4"
NETWORK="tenant-net"
KEYPAIR="laptopubuntu24"
WORK="${WORK:-/mnt/migration/ospc2flex_image}"
OSPC_CREDS="/tmp/ospc2flex_ospc.sh"
export FLEX_CREDS="/tmp/ospc2flex_flex.sh"
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
CAPTURE_MODE="blocked"
WINRM_AUTH_OK=0
OPENSSH_INSTALL_DENIED=0
OPENSSH_NOT_INSTALLED=0
# shellcheck disable=SC2034
OPENSSH_SERVICE_MISSING=0
# shellcheck disable=SC2034
OPENSSH_FIREWALL_BLOCKED=0
# shellcheck disable=SC2034
OPENSSH_ENABLE_OK=0
WINDOWS_TRY_ENABLE_OPENSSH="${OSPC2FLEX_WINDOWS_TRY_ENABLE_OPENSSH:-1}"
WINRM_AGENT_CAPTURE="${OSPC2FLEX_WINRM_AGENT_CAPTURE:-0}"
CLOUDBOOT_BUNDLE=""
FORCE_FRESH_CAPTURE="${OSPC2FLEX_FORCE_FRESH_CAPTURE:-0}"
DISABLE_RESUME="${OSPC2FLEX_DISABLE_RESUME:-0}"
MIN_RESUME_QCOW_BYTES="${OSPC2FLEX_MIN_RESUME_QCOW_BYTES:-1073741824}"
SNAPSHOT_POLICY_BLOCKED=0
METHOD_D_INPUT_ARTIFACT="${METHOD_D_INPUT_ARTIFACT:-}"
METHOD_D_SKIP_SOURCE_CAPTURE="${METHOD_D_SKIP_SOURCE_CAPTURE:-0}"
METHOD_F_PARENT="${METHOD_F_PARENT:-0}"
# Optional: set via --workflow-tag so pgrep/pkill can scope concurrent Method G vs H captures on the same label.
CAPTURE_WORKFLOW_TAG="${CAPTURE_WORKFLOW_TAG:-}"
METHOD_B_CAPTURE_ONLY="${OSPC2FLEX_METHOD_B_CAPTURE_ONLY:-${OSPC2FLEX_METHOD_H_CAPTURE_ONLY:-0}}"
CAPTURE_LOG_METHOD="${OSPC2FLEX_PARENT_METHOD_NAME:-Method D}"
CAPTURE_LOG_CONTEXT="${OSPC2FLEX_CAPTURE_LOG_CONTEXT:-Method B/D SSH Capture}"
CAPTURE_LOG_PREFIX="[$CAPTURE_LOG_METHOD][$CAPTURE_LOG_CONTEXT]"
CAPTURE_HANDOFF_READY=0

# ── Color helpers ─────────────────────────────────────────────────────────────
# Log helpers write to STDERR (not stdout) so they never contaminate captured
# command substitutions like $(_resolve_glance_base) — previous bug was
# WARN inside that helper polluting $OS_IMAGE_URL with multi-line text +
# emoji, which curl then rejected with "URL rejected: Malformed input to a
# URL function" (curl exit 3).  The caller invokes this script with
# `... >log 2>&1` so stderr still lands in the SSE-streamed log file.
log()  { echo "[$(date '+%H:%M:%S')]${CAPTURE_LOG_PREFIX}[$LABEL] $*" >&2; }
PASS() { echo "$CAPTURE_LOG_PREFIX ✅ $*" >&2; }
FAIL() { echo "$CAPTURE_LOG_PREFIX ❌ $*" >&2; }
WARN() { echo "$CAPTURE_LOG_PREFIX ⚠️  $*" >&2; }
INFO() { echo "$CAPTURE_LOG_PREFIX ℹ️  $*" >&2; }

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
  if [ "${OSPC2FLEX_UI_QUIET:-1}" = "1" ] && [ "${OSPC2FLEX_UI_VERBOSE:-0}" != "1" ]; then
    # Keep noisy per-step progress only in background/progress logs by default.
    bg_log "[$LABEL]   [${elapsed}s] $msg"
    progress_log "[$LABEL]   [${elapsed}s] $msg"
  else
    log "  [${elapsed}s] $msg"
  fi
}

step_done() {
  local status="${1:-OK}"
  local elapsed=$(($(date +%s) - _STEP_START_TIME))
  _STEP_STEPS_COMPLETED=$(($_STEP_STEPS_COMPLETED + 1))
  log "Step $_STEP_NUM completed ($status) in ${elapsed}s"
  echo "  └─ [${elapsed}s elapsed] $status" >&2
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
    --cloudboot-bundle) CLOUDBOOT_BUNDLE="$2"; shift 2 ;;
    --force-fresh-capture) FORCE_FRESH_CAPTURE=1; shift ;;
    --disable-resume) DISABLE_RESUME=1; shift ;;
    --input-artifact) METHOD_D_INPUT_ARTIFACT="$2"; shift 2 ;;
    --skip-source-capture) METHOD_D_SKIP_SOURCE_CAPTURE=1; shift ;;
    --method-f-parent) METHOD_F_PARENT=1; shift ;;
    --workflow-tag)    CAPTURE_WORKFLOW_TAG="$2"; shift 2 ;;
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
_ts=$(date +%Y%m%d-%H%M%S)
_resume_qcow=""
RESUME_MODE="${OSPC2FLEX_RESUME_MODE:-on}"
if [ "$FORCE_FRESH_CAPTURE" = "1" ] || [ "$DISABLE_RESUME" = "1" ]; then
  RESUME_MODE="off"
fi

archive_cached_artifacts_for_fresh_capture() {
  local archive_dir="$WORK/cache_archive" ts old_json
  ts="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$archive_dir"
  for f in "$WORK/${BASE_LABEL}.qcow2" "$WORK/${BASE_LABEL}"-*.qcow2; do
    [ -f "$f" ] || continue
    mv "$f" "$archive_dir/$(basename "$f").fresh-archive.${ts}" 2>/dev/null || true
  done
  rm -f "$WORK/${BASE_LABEL}.qcow2.win_repaired" "$WORK/${BASE_LABEL}"-*.qcow2.win_repaired 2>/dev/null || true
  old_json="$WORK/${BASE_LABEL}.windows_v2_rescue.json"
  [ -f "$old_json" ] && rm -f "$old_json" 2>/dev/null || true
}

archive_bad_resume_qcow() {
  local qcow="$1" reason="${2:-invalid}" archive_dir="$WORK/cache_archive" ts
  [ -f "$qcow" ] || return 0
  ts="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$archive_dir"
  WARN "Cached qcow2 is not resumable ($reason); archiving and restarting capture: $qcow"
  mv "$qcow" "$archive_dir/$(basename "$qcow").bad-resume.${ts}" 2>/dev/null || rm -f "$qcow" 2>/dev/null || true
  rm -f "${qcow}.win_repaired" 2>/dev/null || true
}

qcow_resume_ok() {
  local qcow="$1" sz
  [ -f "$qcow" ] || return 1
  if ! qemu-img info "$qcow" >/dev/null 2>&1; then
    archive_bad_resume_qcow "$qcow" "qemu-img-info-failed"
    return 1
  fi
  if ! qemu-img check "$qcow" >/dev/null 2>&1; then
    archive_bad_resume_qcow "$qcow" "qemu-img-check-failed"
    return 1
  fi
  sz=$(stat -c%s "$qcow" 2>/dev/null || echo 0)
  if [ "${sz:-0}" -lt "$MIN_RESUME_QCOW_BYTES" ]; then
    archive_bad_resume_qcow "$qcow" "size-below-1GiB:${sz:-0}B"
    return 1
  fi
  return 0
}

write_failure_handoff_json() {
  local reason="$1" next_action="$2" status="${3:-FAILED}"
  [ -n "${OSPC2FLEX_WINDOWS_OUTPUT_JSON:-}" ] || return 0
  python3 - "$OSPC2FLEX_WINDOWS_OUTPUT_JSON" "$LABEL" "$BASE_LABEL" "$reason" "$next_action" "$status" <<'PY'
import json, sys
out_path, label, base_label, reason, next_action, status = sys.argv[1:7]
doc = {
  "label": label,
  "base_label": base_label,
  "status": status,
  "final": False,
  "failure_reason": reason,
  "next_action": next_action,
  "safe_first_boot": "PENDING",
  "online_virtio_binding": "PENDING",
  "virtio_ready_snapshot": "PENDING",
  "final_optimized_boot": "PENDING"
}
with open(out_path, "w", encoding="utf-8") as f:
  json.dump(doc, f, indent=2)
PY
}

write_windows_access_json() {
  local ssh_open="$1" winrm_auth="$2" endpoint="$3" openssh_present="$4" openssh_attempted="$5" openssh_status="$6" external_ssh="$7" capture_mode="$8" failure_reason="$9" next_action="${10}"
  local out_json="${WORK}/${BASE_LABEL}.windows_access.json"
  python3 - "$out_json" "$SERVER_IP" "$WIN_USER" "$ssh_open" "$winrm_auth" "$endpoint" "$openssh_present" "$openssh_attempted" "$openssh_status" "$external_ssh" "$capture_mode" "$failure_reason" "$next_action" <<'PY'
import json, sys
(
  out_path, source_ip, windows_user, ssh_open, winrm_auth, endpoint,
  openssh_present, openssh_attempted, openssh_status, external_ssh,
  capture_mode, failure_reason, next_action
) = sys.argv[1:14]
doc = {
  "source_ip": source_ip,
  "windows_user": windows_user,
  "ssh_port_open": ssh_open.lower() == "true",
  "winrm_auth": winrm_auth,
  "winrm_endpoint": endpoint,
  "openssh_present": openssh_present.lower() == "true",
  "openssh_enable_attempted": openssh_attempted.lower() == "true",
  "openssh_enable_status": openssh_status,
  "external_ssh_check": external_ssh,
  "capture_mode": capture_mode,
  "failure_reason": failure_reason,
  "next_action": next_action,
}
with open(out_path, "w", encoding="utf-8") as f:
  json.dump(doc, f, indent=2)
PY
}

quarantine_bad_qcow() {
  local artifact="$1" reason="${2:-bad-system-hive}" ts bad_dir bad_path
  [ -n "$artifact" ] || return 0
  [ -f "$artifact" ] || return 0
  ts="$(date +%Y%m%d-%H%M%S)"
  bad_dir="$WORK/bad_artifacts"
  mkdir -p "$bad_dir"
  bad_path="$bad_dir/$(basename "$artifact").${reason}.${ts}"
  mv "$artifact" "$bad_path" 2>/dev/null || { rm -f "$artifact" 2>/dev/null || true; return 1; }
  WARN "Quarantined bad qcow2 artifact: $bad_path"
}

# Raw disk read script for Windows guest (SSH stream). Keep in sync with WinRM dump_ps below.
emit_windows_diskdump_ps1() {
  cat <<'WIN_DISKDUMP_PS1'
$ErrorActionPreference = 'Stop'
$paths = @('\\.\PHYSICALDRIVE0', '\\.\PhysicalDrive0')
$drive = $null
$lastErr = $null
foreach ($p in $paths) {
  try {
    $drive = New-Object System.IO.FileStream(
      $p,
      [System.IO.FileMode]::Open,
      [System.IO.FileAccess]::Read,
      [System.IO.FileShare]::ReadWrite
    )
    if ($drive) { break }
  } catch {
    $lastErr = $_
    if ($drive) { $drive.Dispose(); $drive = $null }
  }
}
if ($null -eq $drive) {
  Write-Error ("OSPC2FLEX_PHYSICAL_DRIVE_OPEN_FAILED: " + $lastErr)
  exit 2
}
$stdout = [System.Console]::OpenStandardOutput()
$bufLen = 4194304
$buf = New-Object byte[] $bufLen
try {
  while ($true) {
    try {
      $n = $drive.Read($buf, 0, $bufLen)
      if ($n -le 0) { break }
      $stdout.Write($buf, 0, $n)
    } catch [System.IO.IOException] {
      break
    }
  }
} finally {
  $drive.Close()
  $stdout.Flush()
}
WIN_DISKDUMP_PS1
}

# When SSH is already open, WinRM bootstrap is skipped — still push diskdump helper to the guest.
deploy_windows_diskdump_via_ssh() {
  local target="$1"
  local tmp b64 rc
  tmp=$(mktemp /tmp/ospc2flex_diskdump_ps1_XXXXXX)
  emit_windows_diskdump_ps1 >"$tmp"
  b64=$(base64 -w0 "$tmp" 2>/dev/null) || b64=$(base64 "$tmp" | tr -d '\n')
  rm -f "$tmp"
  set +e
  if [ -n "${WIN_PASSWORD:-}" ]; then
    sshpass -p "$WIN_PASSWORD" ssh \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=30 \
        -o PreferredAuthentications=password,keyboard-interactive \
        -o PubkeyAuthentication=no \
        "$target" \
        "powershell -NoProfile -NonInteractive -Command \"[IO.File]::WriteAllBytes('C:\\\\Windows\\\\Temp\\\\ospc2flex_diskdump.ps1', [Convert]::FromBase64String('$b64'))\"" \
        >>"$PROGRESS_LOG" 2>&1
    rc=$?
  else
    ssh -i ~/.ssh/id_rsa \
        -o StrictHostKeyChecking=no -o BatchMode=yes \
        -o LogLevel=ERROR -o ConnectTimeout=30 \
        "$target" \
        "powershell -NoProfile -NonInteractive -Command \"[IO.File]::WriteAllBytes('C:\\\\Windows\\\\Temp\\\\ospc2flex_diskdump.ps1', [Convert]::FromBase64String('$b64'))\"" \
        >>"$PROGRESS_LOG" 2>&1
    rc=$?
  fi
  set -e
  if [ "$rc" -ne 0 ]; then
    WARN "Could not push ospc2flex_diskdump.ps1 via SSH (rc=$rc); capture may fail if script is missing"
  else
    PASS "Deployed C:\\Windows\\Temp\\ospc2flex_diskdump.ps1 via SSH"
  fi
}

# Install VirtIO MSI on the live source VM before disk capture.
# Must run while the VM is still online — drivers registered properly in the
# Windows Driver Store so they survive the offline repair step without raw injection.
# Best-effort: failures warn but never abort the capture.
preinstall_virtio_msi_live() {
  local target="$1"
  local msi_src=""
  local msi_rc=0

  # Locate MSI on jumphost
  for _p in \
    /mnt/migration/virtio/virtio-win-gt-x64.msi \
    /mnt/migration/virtio-win-gt-x64.msi \
    /tmp/virtio-win-gt-x64.msi; do
    [ -f "$_p" ] && { msi_src="$_p"; break; }
  done

  if [ -z "$msi_src" ]; then
    WARN "[preinstall_virtio_msi] MSI not found on jumphost — skipping live MSI install"
    WARN "[preinstall_virtio_msi] To enable: place virtio-win-gt-x64.msi at /mnt/migration/virtio/"
    return 0
  fi

  PASS "[preinstall_virtio_msi] MSI found: $msi_src"

  # Idempotency: check if viostor already in Windows Driver Store (MSI already ran)
  local _check_out
  set +e
  if [ -n "${WIN_PASSWORD:-}" ]; then
    _check_out=$(sshpass -p "$WIN_PASSWORD" ssh \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR -o ConnectTimeout=20 \
      -o PreferredAuthentications=password,keyboard-interactive \
      -o PubkeyAuthentication=no \
      "$target" \
      'powershell -NoProfile -NonInteractive -Command "pnputil /enum-drivers | Select-String viostor"' \
      2>/dev/null || true)
  else
    _check_out=$(ssh -i ~/.ssh/id_rsa \
      -o StrictHostKeyChecking=no -o BatchMode=yes \
      -o LogLevel=ERROR -o ConnectTimeout=20 \
      "$target" \
      'powershell -NoProfile -NonInteractive -Command "pnputil /enum-drivers | Select-String viostor"' \
      2>/dev/null || true)
  fi
  set -e

  if printf '%s\n' "$_check_out" | grep -qi "viostor"; then
    PASS "[preinstall_virtio_msi] viostor already in Driver Store — MSI pre-install not needed"
    return 0
  fi

  INFO "[preinstall_virtio_msi] Uploading MSI to Windows Temp..."
  set +e
  if [ -n "${WIN_PASSWORD:-}" ]; then
    sshpass -p "$WIN_PASSWORD" scp \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR -o ConnectTimeout=30 \
      -o PreferredAuthentications=password,keyboard-interactive \
      -o PubkeyAuthentication=no \
      "$msi_src" "${target}:/Windows/Temp/virtio-win-gt-x64.msi" >>"$BACKGROUND_LOG" 2>&1
    msi_rc=$?
  else
    scp -i ~/.ssh/id_rsa \
      -o StrictHostKeyChecking=no -o BatchMode=yes \
      -o LogLevel=ERROR -o ConnectTimeout=30 \
      "$msi_src" "${target}:/Windows/Temp/virtio-win-gt-x64.msi" >>"$BACKGROUND_LOG" 2>&1
    msi_rc=$?
  fi
  set -e

  if [ "$msi_rc" -ne 0 ]; then
    WARN "[preinstall_virtio_msi] SCP failed (rc=$msi_rc) — skipping live MSI install"
    return 0
  fi

  INFO "[preinstall_virtio_msi] Running msiexec /qn on source VM (may take 2-5 min)..."
  set +e
  if [ -n "${WIN_PASSWORD:-}" ]; then
    sshpass -p "$WIN_PASSWORD" ssh \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR -o ConnectTimeout=30 \
      -o PreferredAuthentications=password,keyboard-interactive \
      -o PubkeyAuthentication=no \
      "$target" \
      'msiexec /i C:\Windows\Temp\virtio-win-gt-x64.msi /qn /norestart ADDLOCAL=ALL' \
      >>"$BACKGROUND_LOG" 2>&1
    msi_rc=$?
  else
    ssh -i ~/.ssh/id_rsa \
      -o StrictHostKeyChecking=no -o BatchMode=yes \
      -o LogLevel=ERROR -o ConnectTimeout=300 \
      "$target" \
      'msiexec /i C:\Windows\Temp\virtio-win-gt-x64.msi /qn /norestart ADDLOCAL=ALL' \
      >>"$BACKGROUND_LOG" 2>&1
    msi_rc=$?
  fi
  set -e

  # 0=success, 3010=success+reboot-needed — both are OK for capture
  if [ "$msi_rc" -eq 0 ] || [ "$msi_rc" -eq 3010 ]; then
    PASS "[preinstall_virtio_msi] VirtIO MSI installed on live source VM (rc=$msi_rc)"
  else
    WARN "[preinstall_virtio_msi] msiexec returned rc=$msi_rc — capture will continue; offline repair will inject drivers as fallback"
  fi
  return 0
}

if [ "$FORCE_FRESH_CAPTURE" = "1" ] || [ "$DISABLE_RESUME" = "1" ]; then
  INFO "Force-fresh/disable-resume enabled; archiving cached qcow2 and clearing sentinels."
  archive_cached_artifacts_for_fresh_capture
fi

if [ "$RESUME_MODE" != "off" ] && [ "${OSPC2FLEX_LEGACY_IMAGE_NAME:-0}" != "1" ]; then
  _plain="$WORK/${BASE_LABEL}.qcow2"
  if qcow_resume_ok "$_plain"; then
    _resume_qcow="$_plain"
  fi
  if [ -z "$_resume_qcow" ]; then
    for _c in $(ls -t "$WORK/${BASE_LABEL}"-*.qcow2 2>/dev/null || true); do
      [ -f "$_c" ] || continue
      if qcow_resume_ok "$_c"; then
        _resume_qcow="$_c"
        break
      fi
    done
  fi
  if [ -n "$_resume_qcow" ]; then
    LABEL=$(basename "$_resume_qcow" .qcow2)
  else
    LABEL="${BASE_LABEL}-${_ts}"
  fi
elif [ "$RESUME_MODE" = "off" ] && [ "${OSPC2FLEX_LEGACY_IMAGE_NAME:-0}" != "1" ]; then
  LABEL="${BASE_LABEL}-${_ts}"
fi

_cloud_ts=$(date +%Y%m%d-%H%M%S)
if [ "$LABEL" = "$BASE_LABEL" ]; then
  CLOUD_LABEL="${BASE_LABEL}-${_cloud_ts}"
else
  CLOUD_LABEL="$LABEL"
fi

QCOW="$WORK/${LABEL}.qcow2"
IMG_PATH="$WORK/${LABEL}.img"
IMG_SIZE=0
DOWNLOAD_METHOD=""
RESUME_FROM_QCOW=0

# Per-job debug logs (full noisy command output). UI stream stays readable via ui_log / step_*.
OSPC2FLEX_UI_VERBOSE="${OSPC2FLEX_UI_VERBOSE:-0}"
LOG_DIR="$WORK/logs"
mkdir -p "$LOG_DIR"
BACKGROUND_LOG="$LOG_DIR/${LABEL}.background.log"
PROGRESS_LOG="$LOG_DIR/${LABEL}.progress.log"
: > "$BACKGROUND_LOG"
: > "$PROGRESS_LOG"

ui_log() { echo "[$(date '+%H:%M:%S')]$CAPTURE_LOG_PREFIX $*" >&2; }
bg_log() {
  mkdir -p "$LOG_DIR"
  echo "[$(date '+%H:%M:%S')]$CAPTURE_LOG_PREFIX $*" >> "$BACKGROUND_LOG"
}
progress_log() { echo "[$(date '+%H:%M:%S')]$CAPTURE_LOG_PREFIX $*" >> "$PROGRESS_LOG"; }

# Run a noisy command with full transcript in BACKGROUND_LOG.
# When OSPC2FLEX_UI_VERBOSE=1, allow noisy output to stream to UI.
run_noisy_bg() {
  local title="$1" rc
  shift
  ui_log "▶ $title started. Full details: $BACKGROUND_LOG"
  mkdir -p "$LOG_DIR"

  if [ "${OSPC2FLEX_UI_VERBOSE:-0}" = "1" ]; then
    "$@"
    return $?
  fi

  # Subshell so `exit` does not terminate the whole capture script (brace group would).
  (
    echo "================================================================"
    echo "[$(date '+%F %T')] START: $title"
    echo "CMD: $*"
    echo "================================================================"
    "$@"
    rc=$?
    echo "================================================================"
    echo "[$(date '+%F %T')] END: $title rc=$rc"
    echo "================================================================"
    exit "$rc"
  ) >> "$BACKGROUND_LOG" 2>&1

  rc=$?
  if [ "$rc" -eq 0 ]; then
    ui_log "✅ $title completed"
  else
    ui_log "❌ $title failed rc=$rc. See: $BACKGROUND_LOG"
    tail -n 40 "$BACKGROUND_LOG" 2>/dev/null | sed 's/^/[debug-tail] /' >&2 || true
    return "$rc"
  fi
}

# Capture stdout while sending full details to BACKGROUND_LOG when non-verbose.
# Useful for commands that return IDs (e.g. openstack image create -c id).
run_noisy_bg_capture() {
  local title="$1" rc out
  shift
  ui_log "▶ $title started. Full details: $BACKGROUND_LOG" >&2
  mkdir -p "$LOG_DIR"

  if [ "${OSPC2FLEX_UI_VERBOSE:-0}" = "1" ]; then
    "$@"
    return $?
  fi

  {
    echo "================================================================"
    echo "[$(date '+%F %T')] START: $title"
    echo "CMD: $*"
    echo "================================================================"
  } >> "$BACKGROUND_LOG" 2>&1

  set +e
  out=$("$@" 2>>"$BACKGROUND_LOG")
  rc=$?
  set -e

  {
    echo "================================================================"
    echo "[$(date '+%F %T')] END: $title rc=$rc"
    echo "================================================================"
  } >> "$BACKGROUND_LOG" 2>&1

  if [ "$rc" -eq 0 ]; then
    ui_log "✅ $title completed" >&2
  else
    ui_log "❌ $title failed rc=$rc. See: $BACKGROUND_LOG" >&2
    tail -n 40 "$BACKGROUND_LOG" 2>/dev/null | sed 's/^/[debug-tail] /' >&2 || true
    return "$rc"
  fi

  printf '%s' "$out"
}

_mig_on_exit() {
  local ec=$?
  # Kill any live heartbeat subshells so their open stdout FD doesn't keep
  # the self-tee pipe alive after we exit, causing orphan tee noise.
  rm -f "/tmp/winmig_hb_active_${LABEL:-}" 2>/dev/null || true
  [ -n "${_HB_PID:-}" ] && kill "$_HB_PID" 2>/dev/null || true
  if [ -f "/tmp/winmig_hb_pid_${LABEL:-}" ]; then
    kill "$(cat "/tmp/winmig_hb_pid_${LABEL:-}" 2>/dev/null)" 2>/dev/null || true
    rm -f "/tmp/winmig_hb_pid_${LABEL:-}" 2>/dev/null || true
  fi
  [ -z "${BACKGROUND_LOG:-}" ] && return 0
  ui_log "Background log: $BACKGROUND_LOG"
  ui_log "Progress log: $PROGRESS_LOG"
  # Capture-only: prefer explicit handoff flag, but if the script exited 0 before
  # CAPTURE_HANDOFF_READY=1 (legacy run_noisy_bg brace/exit bug or partial refactor),
  # accept a non-empty qcow2 that passes qemu-img info+check so Method G/H still succeed.
  if [ "$ec" -eq 0 ] && [ "${METHOD_B_CAPTURE_ONLY:-0}" = "1" ]; then
    if [ "${CAPTURE_HANDOFF_READY:-0}" = "1" ] \
      || { [ -n "${QCOW:-}" ] && [ -s "$QCOW" ] && qemu-img info "$QCOW" >/dev/null 2>&1 && qemu-img check "$QCOW" >/dev/null 2>&1; }; then
      ui_log "Capture phase result: METHOD_B_SSH_CAPTURE_READY"
    else
      ui_log "Capture phase result: INCOMPLETE"
      trap - EXIT
      exit 1
    fi
  elif [ "$ec" -eq 0 ] && [ "${OSPC2FLEX_WINDOWS_MODE:-offline_only}" = "two_phase_virtio" ]; then
    ui_log "Migration phase result: RESCUE_READY"
  elif [ "$ec" -eq 0 ]; then
    ui_log "Migration result: SUCCESS"
  else
    ui_log "Migration result: FAILED"
  fi
}
trap '_mig_on_exit' EXIT

LOG="/tmp/mig_${LABEL}.log"
if [ "${OSPC2FLEX_SELF_TEE:-auto}" != "0" ]; then
  exec > >(tee -a "$LOG") 2>&1
fi

echo "═══════════════════════════════════════════════════════════════════════════"
if [ -n "${OSPC2FLEX_PARENT_METHOD_NAME:-}" ]; then
  echo " ${OSPC2FLEX_PARENT_METHOD_NAME} — Shared Method B/D SSH Capture Engine"
else
  echo " OSPC→FLEX Windows Method D Capture Workflow"
fi
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
echo ""
echo "  Steps: 1 (OSPC auth/snapshot) → 1b (SSH check) → 2 (disk read) → 3 (qcow2) →"
echo "         4 (VirtIO repair) → 5 (upload) → 6 (boot) → 7 (floating IP)"
echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""

mkdir -p "$WORK"
if [ "$METHOD_D_SKIP_SOURCE_CAPTURE" = "1" ]; then
  RESUME_MODE="off"
fi
RESUME_FROM_IMG=0
if [ "$RESUME_MODE" = "off" ]; then
  INFO "Resume mode disabled (OSPC2FLEX_RESUME_MODE=off); forcing fresh disk capture + qcow2 conversion."
elif [ -s "$QCOW" ] && qemu-img info "$QCOW" >/dev/null 2>&1; then
  if qcow_resume_ok "$QCOW"; then
    QCOW_EXISTING_BYTES=$(stat -c%s "$QCOW" 2>/dev/null || echo 0)
    RESUME_FROM_QCOW=1
    DOWNLOAD_METHOD="existing-qcow2-resume"
    PASS "Resume point found: $QCOW ($((QCOW_EXISTING_BYTES / 1024 / 1024)) MB)"
    INFO "Skipping SSH/Glance download and raw->qcow2 conversion; resuming at Windows repair stage."
  fi
elif [ -s "$IMG_PATH" ]; then
  _img_resume_sz=$(stat -c%s "$IMG_PATH" 2>/dev/null || echo 0)
  if [ "${_img_resume_sz:-0}" -ge "$MIN_RESUME_QCOW_BYTES" ]; then
    IMG_SIZE="$_img_resume_sz"
    RESUME_FROM_IMG=1
    DOWNLOAD_METHOD="existing-img-resume"
    PASS "Resume point found: $IMG_PATH ($((IMG_SIZE / 1024 / 1024)) MB)"
    _meta_file="${WORK}/${LABEL}.capture_meta.json"
    if [ -f "$_meta_file" ] && python3 -c "
import json, sys
d = json.loads(open('${_meta_file}').read())
sys.exit(0 if d.get('img_complete') else 1)
" 2>/dev/null; then
      INFO "Sidecar confirms this is a complete disk capture."
    else
      WARN "No verified-complete sidecar for this .img; conversion will proceed but qcow2 probe will run after."
    fi
    INFO "Skipping SSH disk capture; will convert existing .img to qcow2."
  fi
fi

# Method D artifact-input mode (used by Method F):
# Source acquisition already completed by Method F.
if [ "$METHOD_D_SKIP_SOURCE_CAPTURE" = "1" ]; then
  [ -n "$METHOD_D_INPUT_ARTIFACT" ] || { FAIL "METHOD_D_ARTIFACT_INPUT_MODE requires --input-artifact"; exit 1; }
  case "$METHOD_D_INPUT_ARTIFACT" in
    /*) ;;
    *)
      FAIL "METHOD_D_ARTIFACT_INPUT_MODE requires absolute --input-artifact path"
      exit 1
      ;;
  esac
  [ -f "$METHOD_D_INPUT_ARTIFACT" ] || { FAIL "Input artifact missing: $METHOD_D_INPUT_ARTIFACT"; exit 1; }
  [ -s "$METHOD_D_INPUT_ARTIFACT" ] || { FAIL "Input artifact empty: $METHOD_D_INPUT_ARTIFACT"; exit 1; }
  if printf '%s' "$METHOD_D_INPUT_ARTIFACT" | grep -q "/bad_artifacts/"; then
    FAIL "Refusing bad artifact path: $METHOD_D_INPUT_ARTIFACT"
    exit 1
  fi
  INFO "METHOD_D_ARTIFACT_INPUT_MODE"
  INFO "Source disk acquisition already completed by upstream export (Method F / G wrapper)."
  INFO "Input artifact: $METHOD_D_INPUT_ARTIFACT"
  _input_fmt="$(qemu-img info "$METHOD_D_INPUT_ARTIFACT" 2>/dev/null | awk -F': ' '/^file format:/{print $2; exit}')"
  [ -n "$_input_fmt" ] || { FAIL "Could not detect input artifact format"; exit 1; }
  mkdir -p "$WORK"
  if [ "$_input_fmt" = "qcow2" ]; then
    if [ "$METHOD_D_INPUT_ARTIFACT" != "$QCOW" ]; then
      cp -f "$METHOD_D_INPUT_ARTIFACT" "$QCOW"
    fi
  else
    run_noisy_bg "qemu-img convert input artifact to qcow2" qemu-img convert -O qcow2 "$METHOD_D_INPUT_ARTIFACT" "$QCOW"
  fi
  qemu-img info "$QCOW" >/dev/null 2>&1 || { FAIL "Converted input qcow2 is unreadable"; exit 1; }
  RESUME_FROM_QCOW=1
  DOWNLOAD_METHOD="method-f-input-artifact"
  DISABLE_RESUME=1
fi

# Guard against stale/invalid resumed qcow2 for Windows runs.
# If dry-run validation cannot discover a Windows partition, drop resume and force recapture.
# Skip probe when capture_meta.json confirms this qcow2 came from a verified complete capture.
if [ "$RESUME_FROM_QCOW" -eq 1 ] && [ "${OS_FAMILY:-windows}" = "windows" ] && [ -f "$WIN_REPAIR" ]; then
  _meta_file="${WORK}/${LABEL}.capture_meta.json"
  _skip_probe=0
  if [ -f "$_meta_file" ]; then
    if python3 -c "
import json, sys
d = json.loads(open('${_meta_file}').read())
sys.exit(0 if d.get('qcow2_complete') and d.get('img_complete') else 1)
" 2>/dev/null; then
      _skip_probe=1
      PASS "Capture sidecar confirms complete capture; skipping dry-run probe for resumed qcow2."
    fi
  fi
  if [ "$_skip_probe" -eq 1 ]; then
    : # probe skipped — sidecar verified
  else
  _resume_probe_log="$WORK/${LABEL}.resume-validate.log"
  ui_log "Validating resumed qcow2 before skipping capture: $QCOW"
  set +e
  bash "$WIN_REPAIR" --qcow2 "$QCOW" --dry-run --force >"$_resume_probe_log" 2>&1
  _resume_probe_rc=$?
  set -e
  if [ "$_resume_probe_rc" -ne 0 ]; then
    WARN "Resume qcow2 validation failed (rc=$_resume_probe_rc); forcing fresh capture."
    bg_log "Resume validation failed for $QCOW (rc=$_resume_probe_rc)."
    cat "$_resume_probe_log" >> "$BACKGROUND_LOG" 2>/dev/null || true
    if grep -Eiq "SYSTEM hive validation failed|hivexsh: failed to open hive file|SYSTEM hive missing or empty|SYSTEM hive corrupted after repair|Operation not supported|WINDOWS_PARTITION_DETECTION_FAILED|0xc0000225|WINDOWS_SYSTEM_REGISTRY_HIVE_CORRUPTED|failure_reason=WINDOWS_SYSTEM_REGISTRY_HIVE_CORRUPTED|status=WINDOWS_SYSTEM_HIVE_INVALID" "$_resume_probe_log" 2>/dev/null; then
      rm -f "${QCOW}.win_repaired" 2>/dev/null || true
      rm -f "$WORK/${BASE_LABEL}.windows_v2_rescue.json" 2>/dev/null || true
      WARN "Detected corrupted SYSTEM hive in resumed qcow2; invalidating artifact and clearing repaired sentinel."
      quarantine_bad_qcow "$QCOW" "bad-system-hive" || true
    else
      _bad_qcow="${QCOW}.invalid.$(date +%Y%m%d-%H%M%S)"
      mv "$QCOW" "$_bad_qcow" 2>/dev/null || rm -f "$QCOW"
      WARN "Moved invalid resume artifact to: ${_bad_qcow}"
    fi
    RESUME_FROM_QCOW=0
    DOWNLOAD_METHOD=""
  else
    PASS "Resume qcow2 validation passed; continuing from existing artifact."
  fi
  fi  # end skip_probe else
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 1b: Check SSH first — skip snapshot entirely if SSH is reachable
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$RESUME_FROM_QCOW" -eq 0 ]; then
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

if [ "$METHOD_B_CAPTURE_ONLY" = "1" ] && [ "${SSH_DISK_METHOD:-0}" -ne 1 ]; then
  FAIL "Capture-only mode requires Method B SSH disk download; SSH port 22 is not reachable."
  INFO "WINDOWS_SSH_BLOCKED"
  INFO "CAPTURE_MODE=blocked"
  exit 1
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
  else
    # Create snapshot via Nova createImage action
    step_progress "Creating snapshot $SNAP_NAME..."
    _create_resp=$(curl -s -X POST -H "X-Auth-Token: $OS_TOKEN" -H "Content-Type: application/json" \
      "$_NOVA_URL/servers/$SERVER_ID/action" \
      -d "{\"createImage\":{\"name\":\"$SNAP_NAME\",\"metadata\":{}}}" 2>/dev/null || true)
    if echo "$_create_resp" | grep -Eiq "forbidden|snapshot_volume|Policy doesn't allow"; then
      SNAPSHOT_POLICY_BLOCKED=1
      WARN "OSPC snapshot policy blocked (403 snapshot_volume). Will attempt SSH/WinRM capture path."
      WARN "Glance fallback will remain unavailable unless provider policy is changed."
      step_done "BLOCKED (policy 403)"
      SNAP_ID=""
      SERVER_ID="${SERVER_ID:-}"
      # Continue so WinRM bootstrap section can run next.
      :
    fi
    [ "$SNAPSHOT_POLICY_BLOCKED" -eq 1 ] || echo "$_create_resp" | python3 -c "import sys,json; print(json.load(sys.stdin))" 2>/dev/null || true

    if [ "$SNAPSHOT_POLICY_BLOCKED" -eq 0 ]; then
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
    fi
  fi

  if [ -z "$SNAP_ID" ] && [ "$SNAPSHOT_POLICY_BLOCKED" -eq 0 ]; then
    FAIL "Failed to create/find snapshot for '$SERVER_NAME'"
    step_done "FAILED"
    exit 1
  fi
  [ "$SNAPSHOT_POLICY_BLOCKED" -eq 1 ] || step_done "OK"
fi  # end SSH_DISK_METHOD==0 block

# ═══════════════════════════════════════════════════════════════════════════════
# Step 1b (continued): WinRM bootstrap if SSH still not available
# ═══════════════════════════════════════════════════════════════════════════════
if [ "${SSH_DISK_METHOD:-0}" -eq 1 ]; then
  CAPTURE_MODE="ssh_guest_capture"
  INFO "WINDOWS_SSH_OPEN"
fi

if [ "${SSH_DISK_METHOD:-0}" -eq 0 ] && [ -n "$WIN_PASSWORD" ] && [ "$METHOD_D_SKIP_SOURCE_CAPTURE" != "1" ]; then
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
    INFO "WINDOWS_WINRM_AUTH_FAILED"
    INFO "WINDOWS_SSH_BLOCKED"
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

    _WINRM_PY=$(mktemp /tmp/ospc2flex_winrm_enable_openssh_XXXXXX.py)
    cat > "$_WINRM_PY" <<'WINRM_SCRIPT'
import base64
import json
import os
import sys
import winrm

ip, port, scheme, user = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
pubkey = sys.argv[5] if len(sys.argv) > 5 else ""
diag_path = sys.argv[6] if len(sys.argv) > 6 else ""
access_json = sys.argv[7] if len(sys.argv) > 7 else ""
password = os.environ.get("OSPC2FLEX_WINRM_PASSWORD", "")
try_enable = os.environ.get("OSPC2FLEX_WINDOWS_TRY_ENABLE_OPENSSH", "1").strip() not in ("0", "false", "False")

def emit(msg):
    print(msg)
    if diag_path:
        with open(diag_path, "a", encoding="utf-8") as fh:
            fh.write(msg + "\n")

def run_ps(session, script, fail_on_error=True):
    r = session.run_ps(script)
    out = r.std_out.decode("utf-8", errors="replace").strip()
    err = r.std_err.decode("utf-8", errors="replace").strip()
    for line in out.splitlines():
        emit(line)
    if err and "CLIXML" not in err:
        for line in err.splitlines():
            emit(f"[STDERR] {line}")
    if fail_on_error and r.status_code != 0:
        raise RuntimeError(f"WinRM PS exit {r.status_code}")
    return r

def write_access_json(payload):
    if not access_json:
        return
    with open(access_json, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2)

try:
    if not password:
        emit("WINDOWS_PASSWORD_MISSING")
        emit("WINDOWS_SOURCE_ACCESS_BLOCKED")
        sys.exit(4)
    s = winrm.Session(
        f"{scheme}://{ip}:{port}/wsman",
        auth=(user, password),
        transport="ntlm",
        server_cert_validation="ignore",
        read_timeout_sec=360,
        operation_timeout_sec=300,
    )
    emit("WINDOWS_WINRM_AUTH_OK")
    emit("WINDOWS_SSH_BLOCKED")

    run_ps(s, r"""
$ErrorActionPreference='Continue'
Write-Output 'WINRM_DIAG_BEGIN'
whoami
whoami /groups
Get-Service sshd -ErrorAction SilentlyContinue | Format-List Name,Status,StartType
Get-WindowsCapability -Online | Where-Object {$_.Name -like "OpenSSH.Server*"} | Format-List Name,State
Get-NetFirewallRule -Name sshd -ErrorAction SilentlyContinue
Test-NetConnection -ComputerName localhost -Port 22 | Format-List ComputerName,RemotePort,TcpTestSucceeded
Write-Output 'WINRM_DIAG_END'
""", fail_on_error=False)

    svc_check = run_ps(s, r"""
if (Get-Service sshd -ErrorAction SilentlyContinue) {
  Write-Output 'WINDOWS_OPENSSH_INSTALLED'
} else {
  Write-Output 'WINDOWS_OPENSSH_NOT_INSTALLED'
}
""", fail_on_error=False)
    open_ssh_present = "WINDOWS_OPENSSH_INSTALLED" in svc_check.std_out.decode("utf-8", errors="replace")

    if not open_ssh_present:
      emit("WINDOWS_OPENSSH_ENABLE_RUNNING")
      add_cap = run_ps(s, r"""
$ErrorActionPreference='Stop'
try {
  Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
  Write-Output 'WINDOWS_OPENSSH_INSTALL_OK'
} catch {
  $msg = $_.Exception.Message
  Write-Output ('ADD_CAPABILITY_ERR: ' + $msg)
  if ($msg -match 'Access is denied') {
    Write-Output 'WINDOWS_OPENSSH_INSTALL_DENIED'
  } else {
    Write-Output 'WINDOWS_OPENSSH_INSTALL_FAILED'
  }
}
""", fail_on_error=False)
      add_out = add_cap.std_out.decode("utf-8", errors="replace")
      if "WINDOWS_OPENSSH_INSTALL_DENIED" in add_out:
        emit("WINDOWS_OPENSSH_INSTALL_DENIED")
        emit("[WinRM] Retrying OpenSSH install via elevated SYSTEM scheduled task...")
        run_ps(s, r"""
$ErrorActionPreference='Continue'
$taskName = 'ospc2flex_openssh_install'
$psPath = 'C:\Windows\Temp\ospc2flex_install_openssh.ps1'
$psBody = "Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null"
Set-Content -Path $psPath -Value $psBody -Encoding ascii
schtasks /Delete /TN $taskName /F | Out-Null
schtasks /Create /TN $taskName /SC ONCE /ST 00:00 /RL HIGHEST /RU SYSTEM /TR "powershell -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\ospc2flex_install_openssh.ps1" /F | Out-Null
schtasks /Run /TN $taskName | Out-Null
Start-Sleep -Seconds 12
schtasks /Query /TN $taskName /V /FO LIST
""", fail_on_error=False)
        svc_retry = run_ps(s, r"""
if (Get-Service sshd -ErrorAction SilentlyContinue) {
  Write-Output 'WINDOWS_OPENSSH_INSTALLED'
} else {
  Write-Output 'WINDOWS_OPENSSH_NOT_INSTALLED'
}
""", fail_on_error=False)
        open_ssh_present = "WINDOWS_OPENSSH_INSTALLED" in svc_retry.std_out.decode("utf-8", errors="replace")
        if not open_ssh_present:
          emit("WINDOWS_BULK_TRANSFER_REQUIRED")
          emit("WINDOWS_SOURCE_ACCESS_BLOCKED")
          emit("WinRM login is valid, but this session cannot install OpenSSH. Log in through console/RDP with elevated Administrator, install OpenSSH Server, enable firewall rule, then rerun. Or enable the WinRM capture path.")
          write_access_json({
              "source_ip": ip,
              "windows_user": user,
              "ssh_port_open": False,
              "winrm_auth": "ok",
              "winrm_endpoint": f"{scheme}://{ip}:{port}/wsman",
              "openssh_present": False,
              "openssh_enable_attempted": True,
              "openssh_enable_status": "denied",
              "external_ssh_check": "blocked",
              "capture_mode": "blocked",
              "failure_reason": "WINRM_AUTH_OK_BUT_SSH_UNAVAILABLE",
              "next_action": "Use WinRM-agent capture, enable SMB/HTTPS/object upload, or install OpenSSH manually from elevated Windows console/RDP."
          })
          sys.exit(2)

      svc_check_after = run_ps(s, r"""
if (Get-Service sshd -ErrorAction SilentlyContinue) {
  Write-Output 'WINDOWS_OPENSSH_INSTALLED'
} else {
  Write-Output 'WINDOWS_OPENSSH_NOT_INSTALLED'
}
""", fail_on_error=False)
      open_ssh_present = "WINDOWS_OPENSSH_INSTALLED" in svc_check_after.std_out.decode("utf-8", errors="replace")

    if not open_ssh_present:
      emit("WINDOWS_OPENSSH_NOT_INSTALLED")
      emit("WINDOWS_OPENSSH_SERVICE_MISSING")
      emit("WINDOWS_BULK_TRANSFER_REQUIRED")
      emit("WINDOWS_SOURCE_ACCESS_BLOCKED")
      sys.exit(2)

    run_ps(s, r"""
$ErrorActionPreference='Stop'
Start-Service sshd -ErrorAction SilentlyContinue
Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue
if (-not (Get-NetFirewallRule -Name sshd -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH (ospc2flex)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}
$psExe='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
if (Test-Path $psExe) {
  if (-not (Test-Path 'HKLM:\SOFTWARE\OpenSSH')) { New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null }
  Set-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value $psExe
}
Write-Output "[WinRM] sshd started and shell configured"
""")

    svc_state = run_ps(s, r"Get-Service sshd -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Status", fail_on_error=False)
    if "Running" not in svc_state.std_out.decode("utf-8", errors="replace"):
      emit("WINDOWS_OPENSSH_SERVICE_MISSING")
      emit("WINDOWS_BULK_TRANSFER_REQUIRED")
      emit("WINDOWS_SOURCE_ACCESS_BLOCKED")
      sys.exit(2)

    fw_state = run_ps(s, r"Get-NetFirewallRule -Name sshd -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Enabled", fail_on_error=False)
    if "True" not in fw_state.std_out.decode("utf-8", errors="replace"):
      emit("WINDOWS_OPENSSH_FIREWALL_BLOCKED")
      emit("WINDOWS_BULK_TRANSFER_REQUIRED")
      emit("WINDOWS_SOURCE_ACCESS_BLOCKED")
      sys.exit(2)

    dump_ps = r"""$ErrorActionPreference='Stop'
$paths=@('\\.\PHYSICALDRIVE0','\\.\PhysicalDrive0')
$drive=$null
$lastErr=$null
foreach($p in $paths){
  try{
    $drive=New-Object System.IO.FileStream($p,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
    if($drive){break}
  }catch{$lastErr=$_;if($drive){$drive.Dispose();$drive=$null}}
}
if($null -eq $drive){Write-Error('OSPC2FLEX_PHYSICAL_DRIVE_OPEN_FAILED: '+$lastErr);exit 2}
$stdout=[System.Console]::OpenStandardOutput()
$bufLen=4194304
$buf=New-Object byte[] $bufLen
try{while(($n=$drive.Read($buf,0,$bufLen))-gt 0){$stdout.Write($buf,0,$n)}}
finally{$drive.Close();$stdout.Flush()}
"""
    dump_b64 = base64.b64encode(dump_ps.encode("utf-8")).decode("ascii")
    run_ps(s, f"""
$c=[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('{dump_b64}'))
Set-Content -Path 'C:\\Windows\\Temp\\ospc2flex_diskdump.ps1' -Value $c -Encoding ascii
Write-Output "[WinRM] Disk dump script written"
""")

    if pubkey:
        key_b64 = base64.b64encode(pubkey.encode("utf-8")).decode("ascii")
        run_ps(s, f"""
$pub=[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('{key_b64}'))
$homeSSH='C:\\Users\\Administrator\\.ssh'
if (-not (Test-Path $homeSSH)) {{ New-Item -ItemType Directory -Path $homeSSH | Out-Null }}
Set-Content -Path "$homeSSH\\authorized_keys" -Value $pub -Encoding ascii
Write-Output "[WinRM] Authorized key installed"
""")

    emit("WINDOWS_OPENSSH_ENABLE_OK")
    emit("WINDOWS_SOURCE_ACCESS_READY")
    emit("[WinRM] Bootstrap complete")
    write_access_json({
        "source_ip": ip,
        "windows_user": user,
        "ssh_port_open": False,
        "winrm_auth": "ok",
        "winrm_endpoint": f"{scheme}://{ip}:{port}/wsman",
        "openssh_present": True,
        "openssh_enable_attempted": bool(try_enable),
        "openssh_enable_status": "ok",
        "external_ssh_check": "unknown",
        "capture_mode": "pending_external_ssh_probe",
        "failure_reason": "",
        "next_action": ""
    })
    sys.exit(0)
except Exception as e:
    emit("WINDOWS_WINRM_AUTH_FAILED")
    emit("WINDOWS_SOURCE_ACCESS_BLOCKED")
    emit(f"[ERROR] WinRM: {e}")
    write_access_json({
        "source_ip": ip,
        "windows_user": user,
        "ssh_port_open": False,
        "winrm_auth": "failed",
        "winrm_endpoint": f"{scheme}://{ip}:{port}/wsman",
        "openssh_present": False,
        "openssh_enable_attempted": False,
        "openssh_enable_status": "not_attempted",
        "external_ssh_check": "blocked",
        "capture_mode": "blocked",
        "failure_reason": "NO_VALID_GUEST_ACCESS",
        "next_action": "Provide valid Windows Administrator credentials, enable WinRM, or enable SSH."
    })
    sys.exit(1)
WINRM_SCRIPT

    _WINRM_BOOTSTRAP_LOG=$(mktemp /tmp/ospc2flex_winrm_bootstrap_XXXXXX.log)
    _WINRM_DIAG_LOG="$WORK/${BASE_LABEL}.winrm_access_diagnostics.log"
    _WIN_ACCESS_JSON="$WORK/${BASE_LABEL}.windows_access.json"
    : > "$_WINRM_DIAG_LOG"
    chmod 600 "$_WINRM_DIAG_LOG" 2>/dev/null || true
    chmod 600 "$_WINRM_PY" 2>/dev/null || true
    set +e
    OSPC2FLEX_WINRM_PASSWORD="$WIN_PASSWORD" OSPC2FLEX_WINDOWS_TRY_ENABLE_OPENSSH="$WINDOWS_TRY_ENABLE_OPENSSH" \
    python3 "$_WINRM_PY" "$_WINRM_IP" "$_WINRM_PORT" "$_WINRM_SCHEME" "$WIN_USER" "$JH_PUBKEY" "$_WINRM_DIAG_LOG" "$_WIN_ACCESS_JSON" \
      2>&1 | tee "$_WINRM_BOOTSTRAP_LOG"
    _WINRM_RC=$?
    set -e
    rm -f "$_WINRM_PY"

    if grep -q "WINDOWS_WINRM_AUTH_OK" "$_WINRM_BOOTSTRAP_LOG" 2>/dev/null; then
      WINRM_AUTH_OK=1
      CAPTURE_MODE="winrm_guest_capture_or_winrm_control"
    fi
    if grep -q "WINDOWS_OPENSSH_INSTALL_DENIED" "$_WINRM_BOOTSTRAP_LOG" 2>/dev/null; then
      OPENSSH_INSTALL_DENIED=1
    fi
    if grep -q "WINDOWS_OPENSSH_SERVICE_MISSING" "$_WINRM_BOOTSTRAP_LOG" 2>/dev/null; then
      # shellcheck disable=SC2034
      OPENSSH_SERVICE_MISSING=1
    fi
    if grep -q "WINDOWS_OPENSSH_FIREWALL_BLOCKED" "$_WINRM_BOOTSTRAP_LOG" 2>/dev/null; then
      # shellcheck disable=SC2034
      OPENSSH_FIREWALL_BLOCKED=1
    fi
    if grep -q "WINDOWS_OPENSSH_NOT_INSTALLED" "$_WINRM_BOOTSTRAP_LOG" 2>/dev/null; then
      OPENSSH_NOT_INSTALLED=1
    fi
    if grep -q "WINDOWS_OPENSSH_ENABLE_OK" "$_WINRM_BOOTSTRAP_LOG" 2>/dev/null; then
      # shellcheck disable=SC2034
      OPENSSH_ENABLE_OK=1
    fi

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
      if [ "$_SSH_UP" -eq 1 ]; then
        SSH_DISK_METHOD=1
        CAPTURE_MODE="ssh_guest_capture"
        INFO "WINDOWS_SSH_OPEN"
        INFO "WINDOWS_OPENSSH_ENABLE_OK"
        INFO "WINDOWS_SOURCE_ACCESS_READY"
        write_windows_access_json "true" "ok" "${_WINRM_SCHEME}://${_WINRM_IP}:${_WINRM_PORT}/wsman" "true" "true" "ok" "open" "$CAPTURE_MODE" "" ""
      else
        INFO "WINDOWS_SSH_BLOCKED"
        INFO "WINDOWS_BULK_TRANSFER_REQUIRED"
        WARN "SSH port 22 did not open within 120s — will use Glance fallback"
        write_windows_access_json "false" "ok" "${_WINRM_SCHEME}://${_WINRM_IP}:${_WINRM_PORT}/wsman" "true" "true" "ssh_port_blocked" "blocked" "blocked" "WINRM_AUTH_OK_BUT_SSH_UNAVAILABLE" "Use WinRM-agent capture, enable SMB/HTTPS/object upload, or install OpenSSH manually from elevated Windows console/RDP."
      fi
    else
      if [ "$WINRM_AUTH_OK" -eq 1 ] && [ "$OPENSSH_INSTALL_DENIED" -eq 1 ]; then
        INFO "WINDOWS_OPENSSH_INSTALL_DENIED"
        INFO "WINDOWS_BULK_TRANSFER_REQUIRED"
        INFO "WINDOWS_SOURCE_ACCESS_BLOCKED"
        WARN "WinRM login is valid, but this session cannot install OpenSSH. Log in through console/RDP with elevated Administrator, install OpenSSH Server, enable firewall rule, then rerun. Or enable the WinRM capture path."
        write_failure_handoff_json \
          "WINRM_AUTH_OK_BUT_SSH_UNAVAILABLE" \
          "Use WinRM-agent capture, enable SMB/HTTPS/object upload, or install OpenSSH manually from elevated Windows console/RDP." \
          "WINDOWS_OPENSSH_INSTALL_DENIED"
      elif [ "$WINRM_AUTH_OK" -eq 1 ]; then
        INFO "WINDOWS_BULK_TRANSFER_REQUIRED"
        INFO "WINDOWS_SOURCE_ACCESS_BLOCKED"
        write_failure_handoff_json \
          "WINRM_AUTH_OK_BUT_SSH_UNAVAILABLE" \
          "Use WinRM-agent capture, enable SMB/HTTPS/object upload, or install OpenSSH manually from elevated Windows console/RDP." \
          "WINDOWS_BULK_TRANSFER_REQUIRED"
      else
        WARN "WinRM bootstrap failed (rc=$_WINRM_RC) — will use Glance fallback"
      fi
    fi
    rm -f "$_WINRM_BOOTSTRAP_LOG"
  fi
elif [ "${SSH_DISK_METHOD:-0}" -eq 0 ] && [ "$METHOD_D_SKIP_SOURCE_CAPTURE" != "1" ]; then
  INFO "WINDOWS_PASSWORD_MISSING"
  INFO "WINDOWS_SSH_BLOCKED"
  INFO "WINDOWS_SOURCE_ACCESS_BLOCKED"
  WARN "SSH not available and --windows-password not provided — using Glance fallback only"
fi
if [ "$WINRM_AUTH_OK" -eq 1 ] && [ "${SSH_DISK_METHOD:-0}" -eq 0 ] && [ "$METHOD_D_SKIP_SOURCE_CAPTURE" != "1" ]; then
  INFO "WINDOWS_WINRM_AUTH_OK"
  if [ "${WINRM_AGENT_CAPTURE:-0}" = "1" ]; then
    CAPTURE_MODE="winrm_agent_capture"
    INFO "CAPTURE_MODE=winrm_agent_capture"
    INFO "WINDOWS_SOURCE_ACCESS_READY"
  else
    CAPTURE_MODE="winrm_guest_capture_or_winrm_control"
    INFO "CAPTURE_MODE=winrm_guest_capture_or_winrm_control"
  fi
fi
if [ "${SSH_DISK_METHOD:-0}" -eq 1 ]; then
  INFO "CAPTURE_MODE=ssh_guest_capture"
fi
else
  INFO "Resume mode: SSH/WinRM/snapshot discovery skipped because qcow2 already exists."
fi

# Step 1c: Install VirtIO MSI on live source VM before disk capture
if [ "$RESUME_FROM_QCOW" -eq 0 ] && [ "${SSH_DISK_METHOD:-0}" -eq 1 ] && [ "$METHOD_D_SKIP_SOURCE_CAPTURE" != "1" ]; then
  step_start "1c" "Pre-capture VirtIO MSI install on live source VM"
  _ssh_msi_target="${WIN_USER}@${WIN_SSH_IP:-$SERVER_IP}"
  preinstall_virtio_msi_live "$_ssh_msi_target"
  step_done "OK (best-effort)"
fi

if [ "${SSH_DISK_METHOD:-0}" -eq 0 ] && [ "${SNAPSHOT_POLICY_BLOCKED:-0}" -eq 1 ] && [ "$METHOD_D_SKIP_SOURCE_CAPTURE" != "1" ]; then
  if [ "${CAPTURE_MODE:-}" = "winrm_agent_capture" ]; then
    PASS "Snapshot blocked but WinRM agent capture is enabled; continuing without SSH snapshot fallback."
  else
  if [ "$WINRM_AUTH_OK" -ne 1 ] && [ -n "${WIN_PASSWORD:-}" ]; then
    INFO "WINDOWS_WINRM_AUTH_FAILED"
  fi
  if [ "$OPENSSH_NOT_INSTALLED" -eq 1 ]; then
    INFO "WINDOWS_OPENSSH_NOT_INSTALLED"
  fi
  [ "${SSH_DISK_METHOD:-0}" -eq 1 ] || INFO "WINDOWS_SSH_BLOCKED"
  INFO "WINDOWS_SOURCE_ACCESS_BLOCKED"
  [ "${CAPTURE_MODE:-blocked}" = "blocked" ] && INFO "CAPTURE_MODE=blocked"
  FAIL "Snapshot path is policy-blocked and no bulk transfer channel is available."
  if [ "$WINRM_AUTH_OK" -eq 1 ]; then
    FAIL "WinRM is reachable, but SSH capture is unavailable. Use WinRM-agent capture, SMB/HTTPS/object upload, or install OpenSSH from elevated console/RDP."
    write_failure_handoff_json \
      "WINRM_AUTH_OK_BUT_SSH_UNAVAILABLE" \
      "Use WinRM-agent capture, enable SMB/HTTPS/object upload, or install OpenSSH manually from elevated Windows console/RDP." \
      "WINDOWS_BULK_TRANSFER_REQUIRED"
  else
    FAIL "Provide valid Windows Administrator credentials, enable WinRM, or enable SSH."
    write_failure_handoff_json \
      "NO_VALID_GUEST_ACCESS" \
      "Provide valid Windows Administrator credentials, enable WinRM, or enable SSH." \
      "WINDOWS_SOURCE_ACCESS_BLOCKED"
  fi
  exit 1
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 2: Download Windows disk image
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$RESUME_FROM_QCOW" -eq 0 ]; then
step_start "2" "Downloading Windows disk image (SSH or Glance fallback)"
if [ "${RESUME_FROM_IMG:-0}" -eq 1 ]; then
  INFO "Resuming from existing .img ($((IMG_SIZE / 1024 / 1024)) MB): $IMG_PATH"
  step_done "SKIPPED (resume from existing .img)"
else
rm -f "$IMG_PATH"

if [ "${SSH_DISK_METHOD:-0}" -eq 1 ]; then
  step_progress "Using SSH direct disk read via PowerShell"
  INFO "Large Windows disks: 30–120+ minutes. Progress logged every 60s."
  # Use the SSH IP resolved in Step 1b (ServiceNet preferred when public port 22 is blocked)
  _SSH_TARGET="${WIN_USER}@${WIN_SSH_IP:-$SERVER_IP}"
  step_progress "SSH target: $_SSH_TARGET"
  deploy_windows_diskdump_via_ssh "$_SSH_TARGET"

  # Prefer password auth for Windows when provided; fall back to SSH key.
  if [ -n "${WIN_PASSWORD:-}" ]; then
    WIN_DISK_BYTES=$(sshpass -p "$WIN_PASSWORD" ssh \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=30 \
        -o PreferredAuthentications=password,keyboard-interactive \
        -o PubkeyAuthentication=no \
        "$_SSH_TARGET" \
        'powershell -NonInteractive -Command "(Get-Disk -Number 0).Size"' 2>/dev/null \
      | tr -d '[:space:]' || echo 0)
  else
    WIN_DISK_BYTES=$(ssh -i ~/.ssh/id_rsa \
        -o StrictHostKeyChecking=no -o BatchMode=yes \
        -o LogLevel=ERROR -o ConnectTimeout=30 \
        "$_SSH_TARGET" \
        'powershell -NonInteractive -Command "(Get-Disk -Number 0).Size"' 2>/dev/null \
      | tr -d '[:space:]' || echo 0)
  fi
  INFO "PhysicalDrive0: $((WIN_DISK_BYTES / 1024 / 1024 / 1024)) GiB reported by Windows"

  # Heartbeat while SSH dd runs (sparse UI; details in PROGRESS_LOG)
  _ssh_hb_start=$(date +%s)
  : > "/tmp/winmig_hb_active_${LABEL}"
  (while [ -f "/tmp/winmig_hb_active_${LABEL}" ]; do
     sleep 60
     _sz=$(stat -c%s "$IMG_PATH" 2>/dev/null || echo 0)
     _el=$(( $(date +%s) - _ssh_hb_start ))
     progress_log "SSH disk read heartbeat: $((_sz / 1024 / 1024)) MiB on disk, elapsed=${_el}s"
     ui_log "SSH disk read: $((_sz / 1024 / 1024)) MiB received, elapsed=${_el}s"
   done) &
  _HB_PID=$!

  _SSH_RC=1
  _DD_RC=1
  set +e
  if [ -n "${WIN_PASSWORD:-}" ]; then
    sshpass -p "$WIN_PASSWORD" ssh \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o PreferredAuthentications=password,keyboard-interactive \
        -o PubkeyAuthentication=no \
        -o ServerAliveInterval=30 -o ServerAliveCountMax=20 \
        "$_SSH_TARGET" \
        'powershell -NonInteractive -File C:\Windows\Temp\ospc2flex_diskdump.ps1' \
    | dd of="$IMG_PATH" bs=4M iflag=fullblock status=none 2>>"$PROGRESS_LOG"
    _ps=("${PIPESTATUS[@]}")
    _SSH_RC=${_ps[0]:-1}
    _DD_RC=${_ps[1]:--1}
  else
    ssh -i ~/.ssh/id_rsa \
        -o StrictHostKeyChecking=no -o BatchMode=yes \
        -o LogLevel=ERROR \
        -o ServerAliveInterval=30 -o ServerAliveCountMax=20 \
        "$_SSH_TARGET" \
        'powershell -NonInteractive -File C:\Windows\Temp\ospc2flex_diskdump.ps1' \
    | dd of="$IMG_PATH" bs=4M iflag=fullblock status=none 2>>"$PROGRESS_LOG"
    _ps=("${PIPESTATUS[@]}")
    _SSH_RC=${_ps[0]:-1}
    _DD_RC=${_ps[1]:--1}
  fi
  set -e

  rm -f "/tmp/winmig_hb_active_${LABEL}"
  kill "$_HB_PID" 2>/dev/null || true

  IMG_SIZE=$(stat -c%s "$IMG_PATH" 2>/dev/null || echo 0)
  SSH_SIZE_MISMATCH=0
  if [ "$_SSH_RC" -eq 0 ] && [ "$_DD_RC" -eq 0 ] && [ "${WIN_DISK_BYTES:-0}" -gt 0 ]; then
    _ssh_tolerance=$((4 * 1024 * 1024))
    _ssh_low=$((WIN_DISK_BYTES - _ssh_tolerance))
    [ "$_ssh_low" -lt 0 ] && _ssh_low=0
    if [ "${IMG_SIZE:-0}" -lt "$_ssh_low" ] || [ "${IMG_SIZE:-0}" -gt "$WIN_DISK_BYTES" ]; then
      SSH_SIZE_MISMATCH=1
      WARN "SSH disk stream size mismatch: expected=${WIN_DISK_BYTES}B actual=${IMG_SIZE}B"
    fi
  fi
  if [ "$_SSH_RC" -eq 0 ] && [ "$_DD_RC" -eq 0 ] && [ "${IMG_SIZE:-0}" -lt 1048576 ]; then
    WARN "SSH disk stream ended with zero-byte payload (rc=0 size=${IMG_SIZE}B); retrying once"
    rm -f "$IMG_PATH"
    sleep 3
    set +e
    if [ -n "${WIN_PASSWORD:-}" ]; then
      sshpass -p "$WIN_PASSWORD" ssh \
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR \
          -o PreferredAuthentications=password,keyboard-interactive \
          -o PubkeyAuthentication=no \
          -o ServerAliveInterval=30 -o ServerAliveCountMax=20 \
          "$_SSH_TARGET" \
          'powershell -NonInteractive -File C:\Windows\Temp\ospc2flex_diskdump.ps1' \
      | dd of="$IMG_PATH" bs=4M iflag=fullblock status=none 2>>"$PROGRESS_LOG"
      _ps=("${PIPESTATUS[@]}")
      _SSH_RC=${_ps[0]:-1}
      _DD_RC=${_ps[1]:--1}
    else
      ssh -i ~/.ssh/id_rsa \
          -o StrictHostKeyChecking=no -o BatchMode=yes \
          -o LogLevel=ERROR \
          -o ServerAliveInterval=30 -o ServerAliveCountMax=20 \
          "$_SSH_TARGET" \
          'powershell -NonInteractive -File C:\Windows\Temp\ospc2flex_diskdump.ps1' \
      | dd of="$IMG_PATH" bs=4M iflag=fullblock status=none 2>>"$PROGRESS_LOG"
      _ps=("${PIPESTATUS[@]}")
      _SSH_RC=${_ps[0]:-1}
      _DD_RC=${_ps[1]:--1}
    fi
    set -e
    IMG_SIZE=$(stat -c%s "$IMG_PATH" 2>/dev/null || echo 0)
    SSH_SIZE_MISMATCH=0
    if [ "${WIN_DISK_BYTES:-0}" -gt 0 ]; then
      _ssh_tolerance=$((4 * 1024 * 1024))
      _ssh_low=$((WIN_DISK_BYTES - _ssh_tolerance))
      [ "$_ssh_low" -lt 0 ] && _ssh_low=0
      if [ "${IMG_SIZE:-0}" -lt "$_ssh_low" ] || [ "${IMG_SIZE:-0}" -gt "$WIN_DISK_BYTES" ]; then
        SSH_SIZE_MISMATCH=1
        WARN "SSH disk stream size mismatch after retry: expected=${WIN_DISK_BYTES}B actual=${IMG_SIZE}B"
      fi
    fi
  fi
  # Windows throws IOException "Incorrect function" when reading past the last physical sector.
  # dd still receives all bytes and exits 0. Accept this as a complete capture when the image
  # size exactly matches the reported disk size (end-of-disk exception, not a real failure).
  _eod_complete=0
  if [ "$_DD_RC" -eq 0 ] && [ "${WIN_DISK_BYTES:-0}" -gt 0 ] && [ "${IMG_SIZE:-0}" -eq "${WIN_DISK_BYTES}" ]; then
    _eod_complete=1
    [ "$_SSH_RC" -ne 0 ] && INFO "SSH exited non-zero but dd captured full disk (end-of-disk IOException); treating as complete."
  fi

  if { [ "$_SSH_RC" -eq 0 ] || [ "$_eod_complete" -eq 1 ]; } && [ "$_DD_RC" -eq 0 ] && [ "${IMG_SIZE:-0}" -ge 1048576 ] && [ "${SSH_SIZE_MISMATCH:-0}" -eq 0 ]; then
    PASS "Downloaded via SSH/PowerShell: $((IMG_SIZE / 1024 / 1024)) MB"
    DOWNLOAD_METHOD="ssh-powershell-disk-read"
  else
    if [ "$METHOD_B_CAPTURE_ONLY" = "1" ]; then
      if [ "${SSH_SIZE_MISMATCH:-0}" -eq 1 ]; then
        FAIL "Capture-only mode uses Method B SSH download only; SSH disk read was partial (expected=${WIN_DISK_BYTES:-unknown}B actual=${IMG_SIZE}B)."
        INFO "CAPTURE_MODE=ssh_guest_capture"
        step_done "FAILED"
        exit 1
      fi
      FAIL "Capture-only mode uses Method B SSH download only; SSH disk read failed (ssh_rc=$_SSH_RC dd_rc=$_DD_RC size=${IMG_SIZE}B)."
      INFO "CAPTURE_MODE=ssh_guest_capture"
      step_done "FAILED"
      exit 1
    fi
    WARN "SSH disk read failed (ssh_rc=$_SSH_RC dd_rc=$_DD_RC size=${IMG_SIZE}B) — falling back to Glance"
    rm -f "$IMG_PATH"
    IMG_SIZE=0
    step_progress "SSH failed, trying Glance fallback..."
  fi
fi

if [ "${IMG_SIZE:-0}" -lt 1048576 ]; then
  step_progress "Using Glance snapshot download (Cloud Files bridge / Classic Glance)"
  INFO "Large Windows disks often take 30–120+ minutes — heartbeat + size logged every 60s."
  rm -f "$IMG_PATH"

# OSPC Rackspace Public Cloud only exposes PUBLIC Glance endpoints per region.
# Using OS_INTERFACE=internal causes `openstack image save` to error with
# "internal endpoint for image service in <region> not found". Force public.
export OS_INTERFACE=public
OS_USERNAME="${OS_USERNAME:-}"
OS_PASSWORD="${OS_PASSWORD:-}"
OS_REGION_NAME="${OS_REGION_NAME:-IAD}"
export OS_USERNAME OS_PASSWORD OS_REGION_NAME

_refresh_ospc_token() {
  if [ -f /tmp/ospc2flex_ospc.sh ]; then
    # Ensure OSPC credentials are loaded for Glance fallback when Step 1 was skipped.
    # shellcheck disable=SC1091
    source /tmp/ospc2flex_ospc.sh
  fi
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

if [ -z "${SNAP_ID:-}" ]; then
  step_progress "SSH path unavailable for full disk read; creating OSPC snapshot for Glance fallback"
  SNAP_NAME="${LABEL}-snap-$(date +%Y%m%d%H%M%S)"
  _fallback_server_id=$(openstack server list --ip "$SERVER_IP" -f value -c ID 2>/dev/null | head -1 | tr -d '\r\n' || true)
  if [ -z "$_fallback_server_id" ]; then
    _fallback_server_id=$(openstack server list --name "$SERVER_NAME" -f value -c ID 2>/dev/null | head -1 | tr -d '\r\n' || true)
  fi
  if [ -z "$_fallback_server_id" ] && [ -n "${SERVER_ID:-}" ]; then
    _fallback_server_id="$SERVER_ID"
  fi
  if [ -z "$_fallback_server_id" ]; then
    FAIL "Cannot create fallback snapshot: unable to resolve OSPC server ID for $SERVER_NAME"
    exit 1
  fi
  SNAP_ID=$(openstack server image create "$_fallback_server_id" --name "$SNAP_NAME" -f value -c id 2>/dev/null | awk 'NF{print $1; exit}' || true)
  if [ -z "${SNAP_ID:-}" ]; then
    FAIL "Failed to create OSPC snapshot for Glance fallback"
    exit 1
  fi
  for i in $(seq 1 90); do
    _snap_status=$(openstack image show "$SNAP_ID" -f value -c status 2>/dev/null | tr -d '\r' || echo "queued")
    if [ "$_snap_status" = "active" ] || [ "$_snap_status" = "ACTIVE" ]; then
      step_progress "Fallback snapshot active: $SNAP_ID"
      break
    fi
    sleep 10
  done
  _snap_status=$(openstack image show "$SNAP_ID" -f value -c status 2>/dev/null | tr -d '\r' || echo "unknown")
  if [ "$_snap_status" != "active" ] && [ "$_snap_status" != "ACTIVE" ]; then
    FAIL "Fallback snapshot did not become active (status=$_snap_status id=$SNAP_ID)"
    exit 1
  fi
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
    _hb_start=$(date +%s)
    while [ -f "/tmp/winmig_hb_active_${LABEL}" ]; do
      sleep 60
      n=$((n + 1))
      sz=$(stat -c%s "$IMG_PATH" 2>/dev/null || echo 0)
      _el=$(( $(date +%s) - _hb_start ))
      bg_log "Glance download heartbeat #${n}: $((sz / 1024 / 1024)) MiB on disk, elapsed=${_el}s"
      progress_log "Glance download heartbeat #${n}: $((sz / 1024 / 1024)) MiB, elapsed=${_el}s"
      ui_log "Glance download: $((sz / 1024 / 1024)) MiB on disk, elapsed=${_el}s"
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
  INFO "  → curl $url (transcript also in $BACKGROUND_LOG)"
  : > "/tmp/winmig_hb_active_${LABEL}"
  _start_heartbeat
  set +e
  {
    echo "================================================================"
    echo "[$(date '+%F %T')] curl download attempt=$attempt url=$url"
    echo "================================================================"
    curl -fsSL --connect-timeout 30 --retry 2 --retry-delay 10 \
      -H 'Expect:' \
      -H 'Accept: application/octet-stream' \
      -H "X-Auth-Token: $OS_TOKEN" \
      -A 'ospc2flex/1.0 (+jumphost-migrator)' \
      -o "$IMG_PATH" \
      --write-out "\\nHTTP_CODE=%{http_code} SIZE=%{size_download}B TIME=%{time_total}s\\n" \
      "$url"
  } >"$log" 2>&1
  cat "$log" >> "$BACKGROUND_LOG"
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
  INFO "  → openstack image save $SNAP_ID (default endpoint; transcript in $BACKGROUND_LOG)"
  : > "/tmp/winmig_hb_active_${LABEL}"
  _start_heartbeat
  set +e
  (
    echo "================================================================"
    echo "[$(date '+%F %T')] openstack image save attempt=$attempt snap=$SNAP_ID"
    echo "================================================================"
    openstack image save --file "$IMG_PATH" "$SNAP_ID"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "[$(date '+%F %T')] retry with OS_IMAGE_URL=$base"
      OS_IMAGE_URL="$base" openstack image save --file "$IMG_PATH" "$SNAP_ID"
      rc=$?
    fi
    exit "$rc"
  ) >"$log" 2>&1
  local rc=$?
  cat "$log" >> "$BACKGROUND_LOG"
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
while [ "$attempt" -le "$max_dl" ]; do
  SAW_GLANCE_DNS_FAIL=0
  SAW_PUBLIC_413=0
  if _try_download_methods "$attempt"; then
    IMG_SIZE=$(stat -c%s "$IMG_PATH" 2>/dev/null || echo 0)
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
_img_complete=false
if [ "${WIN_DISK_BYTES:-0}" -gt 0 ] && [ "${IMG_SIZE:-0}" -eq "${WIN_DISK_BYTES:-0}" ]; then
  _img_complete=true
elif [ "${DOWNLOAD_METHOD:-}" != "ssh-powershell-disk-read" ] && [ "${IMG_SIZE:-0}" -gt 0 ]; then
  _img_complete=true
fi
python3 -c "
import json
d = {
  'img_complete': $_img_complete,
  'disk_bytes': ${WIN_DISK_BYTES:-0},
  'img_size': ${IMG_SIZE:-0},
  'download_method': '${DOWNLOAD_METHOD:-unknown}',
  'capture_timestamp': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
}
open('${WORK}/${LABEL}.capture_meta.json', 'w').write(json.dumps(d) + '\n')
" 2>/dev/null || true
step_done "OK"
fi  # end RESUME_FROM_IMG else block
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
  if ! run_noisy_bg "qemu-img convert to qcow2" qemu-img convert -f "$DETECTED_FMT" -O qcow2 "$IMG_PATH" "$QCOW"; then
    FAIL "qemu-img convert failed"
    step_done "FAILED"
    exit 1
  fi
  rm -f "$IMG_PATH"
  PASS "Converted to qcow2"
fi
QCOW_SIZE=$(stat -c%s "$QCOW" 2>/dev/null || echo 0)
INFO "qcow2 size: $((QCOW_SIZE/1024/1024))MB"
_meta_file="${WORK}/${LABEL}.capture_meta.json"
python3 -c "
import json, os
f = '${_meta_file}'
d = json.loads(open(f).read()) if os.path.isfile(f) else {}
d['qcow2_complete'] = True
d['qcow2_size'] = ${QCOW_SIZE:-0}
d['qcow2_timestamp'] = '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
open(f, 'w').write(json.dumps(d) + '\n')
" 2>/dev/null || true
step_done "OK"
else
step_start "3" "Converting disk image to qcow2 format"
QCOW_SIZE=$(stat -c%s "$QCOW" 2>/dev/null || echo 0)
INFO "Reusing existing qcow2 size: $((QCOW_SIZE/1024/1024))MB"
step_done "SKIPPED (resume from qcow2)"
fi

if [ "$METHOD_B_CAPTURE_ONLY" = "1" ]; then
  step_start "4" "Capture-only handoff after Method B SSH capture"
  qemu-img info "$QCOW" >/dev/null 2>&1 || { FAIL "Capture-only handoff qcow2 is unreadable: $QCOW"; step_done "FAILED"; exit 1; }
  qemu-img check "$QCOW" >/dev/null 2>&1 || { FAIL "Capture-only handoff qcow2 check failed: $QCOW"; step_done "FAILED"; exit 1; }
  PASS "Capture-only handoff qcow2 ready: $QCOW"
  INFO "METHOD_B_CAPTURE_ONLY_QCOW=$QCOW"
  INFO "METHOD_H_CAPTURE_ONLY_QCOW=$QCOW"
  step_done "OK"
  CAPTURE_HANDOFF_READY=1
  exit 0
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
    [ "$DRY_RUN" -eq 1 ] && REPAIR_ARGS+=(--dry-run)
    [ -n "$CLOUDBOOT_BUNDLE" ] && REPAIR_ARGS+=(--cloudboot-bundle "$CLOUDBOOT_BUNDLE")
    # Full repair transcript (default on): OSPC2FLEX_WIN_REPAIR_DEBUG=0 to disable
    if [ "${OSPC2FLEX_WIN_REPAIR_DEBUG:-1}" != "0" ]; then
      _win_dbg="$WORK/${LABEL}.repair.debug.log"
      REPAIR_ARGS+=(--debug --debug-log "$_win_dbg")
      INFO "Windows repair debug: ${_win_dbg} (set OSPC2FLEX_WIN_REPAIR_DEBUG=0 to skip)"
    fi
    ui_log "▶ Windows VirtIO repair started. Full transcript: $BACKGROUND_LOG"
    {
      echo "================================================================"
      echo "[$(date '+%F %T')] START: ospc2flex_windows_repair.sh"
      echo "================================================================"
      bash "$WIN_REPAIR" "${REPAIR_ARGS[@]}"
      REPAIR_EXIT=$?
      echo "================================================================"
      echo "[$(date '+%F %T')] END: repair rc=$REPAIR_EXIT"
      echo "================================================================"
    } >> "$BACKGROUND_LOG" 2>&1
    if [ "$REPAIR_EXIT" -ne 0 ]; then
      ui_log "❌ Windows repair failed rc=$REPAIR_EXIT. See: $BACKGROUND_LOG"
      tail -n 40 "$BACKGROUND_LOG" 2>/dev/null | sed 's/^/[debug-tail] /' || true
    else
      ui_log "✅ Windows VirtIO repair completed"
    fi
    set -e
    if [ "$REPAIR_EXIT" -eq 0 ]; then
      PASS "Windows repair completed successfully"
      step_done "OK"
    else
      if grep -Eiq "SYSTEM hive validation failed|hivexsh: failed to open hive file|Operation not supported|WINDOWS_PARTITION_DETECTION_FAILED|0xc0000225|WINDOWS_SYSTEM_REGISTRY_HIVE_CORRUPTED|failure_reason=WINDOWS_SYSTEM_REGISTRY_HIVE_CORRUPTED|status=WINDOWS_SYSTEM_HIVE_INVALID" "$BACKGROUND_LOG" 2>/dev/null; then
        quarantine_bad_qcow "$QCOW" "bad-system-hive" || true
        rm -f "${QCOW}.win_repaired" 2>/dev/null || true
        rm -f "$WORK/${BASE_LABEL}.windows_v2_rescue.json" 2>/dev/null || true
        WARN "Marked qcow2 invalid due to unreadable SYSTEM hive."
        write_failure_handoff_json "WINDOWS_SYSTEM_REGISTRY_HIVE_CORRUPTED" "Use fresh source export or restore SYSTEM hive backup." "WINDOWS_SYSTEM_HIVE_INVALID"
      fi
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
IMG_DISK_BUS="${OSPC2FLEX_WIN_DISK_BUS:-scsi}"
IMG_VIF_MODEL="${OSPC2FLEX_WIN_VIF_MODEL:-virtio}"
IMG_CDROM_BUS="${OSPC2FLEX_WIN_CDROM_BUS:-}"
IMG_QGA="yes"
IMG_SCSI_MODEL="${OSPC2FLEX_WIN_SCSI_MODEL:-virtio-scsi}"
WINDOWS_WORKFLOW="${OSPC2FLEX_WINDOWS_MODE:-offline_only}"
WINDOWS_BOOT_PROFILE="${OSPC2FLEX_WINDOWS_BOOT_PROFILE:-}"
if [ -z "$WINDOWS_BOOT_PROFILE" ]; then
  if [ "$WINDOWS_WORKFLOW" = "two_phase_virtio" ] && [ "$IMG_DISK_BUS" = "ide" ]; then
    WINDOWS_BOOT_PROFILE="safe_ide_firstboot"
  else
    WINDOWS_BOOT_PROFILE="final_virtio"
  fi
fi
if [ "$WINDOWS_BOOT_PROFILE" = "safe_ide_firstboot" ]; then
  IMG_DISK_BUS="ide"
  IMG_CDROM_BUS="ide"
  IMG_VIF_MODEL="e1000"
  IMG_QGA=""
  IMG_SCSI_MODEL=""
fi
case "$IMG_DISK_BUS" in
  ide|scsi|virtio) ;;
  *) FAIL "Invalid OSPC2FLEX_WIN_DISK_BUS=$IMG_DISK_BUS. Use: ide, virtio, or scsi"; step_done "FAILED"; exit 1 ;;
esac
case "$IMG_VIF_MODEL" in
  virtio|e1000) ;;
  *) FAIL "Invalid OSPC2FLEX_WIN_VIF_MODEL=$IMG_VIF_MODEL. Use: virtio or e1000"; step_done "FAILED"; exit 1 ;;
esac
if [ -z "$IMG_CDROM_BUS" ]; then
  if [ "$IMG_DISK_BUS" = "ide" ]; then
    IMG_CDROM_BUS="ide"
  else
    IMG_CDROM_BUS="scsi"
  fi
fi
step_progress "Uploading: $QCOW_BYTES bytes (${QCOW_MIB} MiB) to FLEX Glance..."
if [ "$WINDOWS_BOOT_PROFILE" = "safe_ide_firstboot" ]; then
  INFO "FLEX image metadata: architecture=$IMG_ARCH vm_mode=$IMG_VM_MODE os_type=$IMG_OS_TYPE os_distro=$IMG_OS_DISTRO hw_disk_bus=$IMG_DISK_BUS hw_cdrom_bus=$IMG_CDROM_BUS hw_vif_model=$IMG_VIF_MODEL"
else
  INFO "FLEX image metadata: architecture=$IMG_ARCH vm_mode=$IMG_VM_MODE os_type=$IMG_OS_TYPE os_distro=$IMG_OS_DISTRO hw_disk_bus=$IMG_DISK_BUS hw_cdrom_bus=$IMG_CDROM_BUS hw_scsi_model=$IMG_SCSI_MODEL hw_vif_model=$IMG_VIF_MODEL hw_qemu_guest_agent=$IMG_QGA"
fi

IMG_CREATE_ARGS=(
  image create "$CLOUD_LABEL"
  --disk-format qcow2
  --container-format bare
  --file "$QCOW"
  --private
  --property "architecture=$IMG_ARCH"
  --property "vm_mode=$IMG_VM_MODE"
  --property "os_type=$IMG_OS_TYPE"
  --property "os_distro=$IMG_OS_DISTRO"
  --property "hw_disk_bus=$IMG_DISK_BUS"
  --property "hw_cdrom_bus=$IMG_CDROM_BUS"
  --property "hw_vif_model=$IMG_VIF_MODEL"
  --format value -c id
)
if [ -n "$IMG_QGA" ]; then
  IMG_CREATE_ARGS+=(--property "hw_qemu_guest_agent=$IMG_QGA")
fi
if [ "$IMG_DISK_BUS" = "scsi" ] && [ -n "$IMG_SCSI_MODEL" ]; then
  IMG_CREATE_ARGS+=(--property "hw_scsi_model=$IMG_SCSI_MODEL")
fi
_upload_start=$(date +%s)
tmp_upload_out="$(mktemp)"
tmp_upload_err="$(mktemp)"
if openstack "${IMG_CREATE_ARGS[@]}" >"$tmp_upload_out" 2>>"$BACKGROUND_LOG"; then
  FLEX_IMG_ID="$(grep -Eo '[0-9a-fA-F-]{36}' "$tmp_upload_out" | tail -n 1)"
else
  rc=$?
  ui_log "❌ Glance upload failed rc=$rc"
  tail -n 80 "$BACKGROUND_LOG" 2>/dev/null | sed 's/^/[debug-tail] /' >&2 || true
  rm -f "$tmp_upload_out" "$tmp_upload_err" 2>/dev/null || true
  step_done "FAILED"
  exit "$rc"
fi
rm -f "$tmp_upload_out" "$tmp_upload_err" 2>/dev/null || true
_upload_el=$(( $(date +%s) - _upload_start ))
ui_log "Upload command finished in ${_upload_el}s"
if ! [[ "${FLEX_IMG_ID:-}" =~ ^[0-9a-fA-F-]{36}$ ]]; then
  ui_log "❌ Invalid Glance image ID captured: ${FLEX_IMG_ID:-<empty>}"
  ui_log "Background log: $BACKGROUND_LOG"
  step_done "FAILED"
  exit 1
fi
ui_log "✅ Image uploaded: $FLEX_IMG_ID"

# Wait for image to become active
step_progress "Waiting for image to become active in Glance..."
STATUS="unknown"
for attempt in $(seq 1 120); do
  STATUS=$(openstack image show "$FLEX_IMG_ID" -f value -c status 2>/dev/null | tr -d '\r' || echo "unknown")
  ui_log "Waiting for image ACTIVE... status=$STATUS attempt=$attempt/120"
  [ "$STATUS" = "active" ] && break
  sleep 10
done
if [ "$STATUS" != "active" ]; then
  ui_log "❌ Image did not become ACTIVE: $FLEX_IMG_ID status=$STATUS"
  step_done "FAILED"
  exit 1
fi
PASS "Image uploaded: $FLEX_IMG_ID (status: $STATUS)"
SHOW_NAME=$(openstack image show "$FLEX_IMG_ID" -f value -c name 2>/dev/null || echo "$CLOUD_LABEL")
SHOW_VIS=$(openstack image show "$FLEX_IMG_ID" -f value -c visibility 2>/dev/null || echo "unknown")
SHOW_STAT=$(openstack image show "$FLEX_IMG_ID" -f value -c status 2>/dev/null || echo "${STATUS:-unknown}")
if [ "$WINDOWS_BOOT_PROFILE" = "safe_ide_firstboot" ] || [ "${WINDOWS_WORKFLOW:-}" = "two_phase_virtio" ]; then
  # Enforce SAFE IDE/E1000 metadata for rescue boot BEFORE any server create.
  openstack image unset --property hw_scsi_model "$FLEX_IMG_ID" >/dev/null 2>&1 || true
  openstack image unset --property hw_qemu_guest_agent "$FLEX_IMG_ID" >/dev/null 2>&1 || true
  openstack image set "$FLEX_IMG_ID" \
    --property architecture=x86_64 \
    --property vm_mode=hvm \
    --property os_type=windows \
    --property os_distro=windows \
    --property hw_disk_bus=ide \
    --property hw_cdrom_bus=ide \
    --property hw_vif_model=e1000 >/dev/null 2>&1 || true

  ui_log "SAFE_IDE_METADATA_APPLIED"

  props="$(openstack image show "$FLEX_IMG_ID" -f value -c properties 2>/dev/null || true)"

  if echo "$props" | grep -Eq "hw_scsi_model[\"']?[[:space:]]*[:=]"; then
    echo "ERROR: unsafe safe-firstboot metadata: hw_scsi_model still present"
    echo "$props"
    exit 1
  fi

  if echo "$props" | grep -Eq "hw_qemu_guest_agent[\"']?[[:space:]]*[:=]"; then
    echo "ERROR: unsafe safe-firstboot metadata: hw_qemu_guest_agent still present"
    echo "$props"
    exit 1
  fi

  echo "$props" | grep -Eq "hw_disk_bus[\"']?[[:space:]]*[:=][[:space:]]*[\"']?ide" || exit 1
  echo "$props" | grep -Eq "hw_cdrom_bus[\"']?[[:space:]]*[:=][[:space:]]*[\"']?ide" || exit 1
  echo "$props" | grep -Eq "hw_vif_model[\"']?[[:space:]]*[:=][[:space:]]*[\"']?e1000" || exit 1

  ui_log "SAFE_IDE_METADATA_VERIFIED"
fi
INFO "[UPLOAD-CONFIRMED] region=${OS_REGION_NAME:-unknown} id=$FLEX_IMG_ID name=${SHOW_NAME:-unknown} status=${SHOW_STAT:-unknown} visibility=${SHOW_VIS:-unknown}"
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
    --format value -c id 2>>"$BACKGROUND_LOG" || true)
else
  VM_ID=$(openstack server create "$CLOUD_LABEL" \
    --image "$FLEX_IMG_ID" \
    --flavor "$FLAVOR" \
    --network "$NETWORK" \
    --wait \
    --format value -c id 2>>"$BACKGROUND_LOG" || true)
fi

sleep 10

# Get VM status
if [ -z "${VM_ID:-}" ]; then
  WARN "server create did not return an ID (see $BACKGROUND_LOG)"
  VM_ID=$(openstack server list -f value -c ID -c Name 2>/dev/null | grep -F "$CLOUD_LABEL" | head -1 | awk '{print $1}' || true)
fi
VM_ID=$(printf '%s' "${VM_ID:-}" | awk 'NF {print $1; exit}')
if [ -z "${VM_ID:-}" ]; then
  FAIL "Unable to determine created VM ID for $CLOUD_LABEL"
  step_done "FAILED"
  exit 1
fi
VM_STATUS=$(openstack server show "$VM_ID" -f value -c status 2>/dev/null | tr -d '\r' || echo "unknown")

if [ "$VM_STATUS" = "ACTIVE" ]; then
  PASS "VM booted: $VM_ID (ACTIVE)"
  # ACTIVE is not enough for Windows; catch common guest boot failures early.
  _vm_console="$(openstack console log show "$VM_ID" 2>/dev/null || true)"
  if printf '%s' "$_vm_console" | grep -Eiq "Windows\\\\system32\\\\config\\\\system|Status:\s*0xc0000225"; then
    FAIL "status=WINDOWS_SYSTEM_HIVE_INVALID failure_reason=WINDOWS_SYSTEM_REGISTRY_HIVE_CORRUPTED next_action=Use fresh source export or restore SYSTEM hive backup."
    quarantine_bad_qcow "$QCOW" "bad-system-hive" || true
    rm -f "${QCOW}.win_repaired" 2>/dev/null || true
    rm -f "$WORK/${BASE_LABEL}.windows_v2_rescue.json" 2>/dev/null || true
    write_failure_handoff_json "WINDOWS_SYSTEM_REGISTRY_HIVE_CORRUPTED" "Use fresh source export or restore SYSTEM hive backup." "WINDOWS_SYSTEM_HIVE_INVALID"
    step_done "FAILED"
    exit 1
  fi
  if printf '%s' "$_vm_console" | grep -q "INACCESSIBLE_BOOT_DEVICE"; then
    FAIL "VM console reports INACCESSIBLE_BOOT_DEVICE (storage/boot binding failed)"
    step_done "FAILED"
    exit 1
  fi
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
echo "║                         RESCUE BOOT COMPLETE                               ║"
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

# Optional handoff artifact for two-phase controllers (Method B/D via v2 engine).
# When OSPC2FLEX_WINDOWS_OUTPUT_JSON is set, persist the uploaded image + booted VM IDs
# so the caller can continue with online driver binding and final virtio snapshot flow.
if [ -n "${OSPC2FLEX_WINDOWS_OUTPUT_JSON:-}" ]; then
  _out_json="${OSPC2FLEX_WINDOWS_OUTPUT_JSON}"
  python3 - "$_out_json" "$FLEX_IMG_ID" "$VM_ID" "${ACTUAL_FIP:-}" "$LABEL" "$BASE_LABEL" "$CLOUD_LABEL" <<'PY'
import json, sys
out_path, image_id, vm_id, fip, label, base_label, cloud_label = sys.argv[1:8]
doc = {
    "image_id": image_id,
    "vm_id": vm_id,
    "rescue_image_id": image_id,
    "rescue_server_id": vm_id,
    "rescue_floating_ip": fip,
    "floating_ip": fip,
    "label": label,
    "base_label": base_label,
    "cloud_label": cloud_label,
    "status": "RESCUE_READY",
    "final": False,
    "safe_first_boot": "HIT",
    "online_virtio_binding": "PENDING",
    "virtio_ready_snapshot": "PENDING",
    "final_optimized_boot": "PENDING",
}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2)
PY
  INFO "Two-phase handoff JSON written: ${_out_json}"
fi

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
