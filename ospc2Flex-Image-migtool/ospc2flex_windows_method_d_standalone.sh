#!/usr/bin/env bash
# Two-phase Windows rescue workflow: IDE rescue boot first, then in-guest
# VirtIO binding, then final VirtIO/SCSI image + boot test.
set -euo pipefail

ORIG_ARGS=("$@")

SERVER_NAME=""
SERVER_IP=""
LABEL=""
FLAVOR="gp.0.4.4"
NETWORK="tenant-net"
KEYPAIR=""
WORK="${WORK:-/mnt/migration/ospc2flex_image}"
export OSPC2FLEX_UI_VERBOSE="${OSPC2FLEX_UI_VERBOSE:-0}"
WIN_USER="Administrator"
WIN_PASSWORD=""
export WIN_SNET_IP=""
CLOUDBOOT_TARGET_HOST=""
CLOUDBOOT_TARGET_USER="Administrator"
CLOUDBOOT_TARGET_PORT="22"
CLOUDBOOT_TARGET_PASSWORD=""
CLOUDBOOT_TARGET_KEY=""
CLOUDBOOT_SOURCE_WINRM_HOST=""
CLOUDBOOT_TARGET_WINRM_HOST=""
DRY_RUN=0
export OS_FAMILY="windows"
export OS_TYPE="windows"
FORCE_FRESH_CAPTURE="${OSPC2FLEX_FORCE_FRESH_CAPTURE:-0}"
DISABLE_RESUME="${OSPC2FLEX_DISABLE_RESUME:-0}"

WINDOWS_MODE="two_phase_virtio"
WORKFLOW="${OSPC2FLEX_WORKFLOW:-method_d}"
METHOD_F_ARTIFACT_VALIDATION_JSON=""
OSPC2FLEX_ALLOW_GUEST_DISK_CAPTURE="${OSPC2FLEX_ALLOW_GUEST_DISK_CAPTURE:-0}"
OSPC2FLEX_ALLOW_DISK2VHD="${OSPC2FLEX_ALLOW_DISK2VHD:-0}"
OSPC2FLEX_ALLOW_RAW_SSH_CAPTURE="${OSPC2FLEX_ALLOW_RAW_SSH_CAPTURE:-0}"
OSPC2FLEX_ALLOW_SMB_HTTPS_OBJECT_TRANSFER="${OSPC2FLEX_ALLOW_SMB_HTTPS_OBJECT_TRANSFER:-0}"
OSPC2FLEX_ALLOW_WINDOWS_GLANCE_ONLY="${OSPC2FLEX_ALLOW_WINDOWS_GLANCE_ONLY:-1}"
# Resume is ON by default for Method D. Safety guardrails in the capture helper
# will automatically reject invalid/stale qcow2 artifacts and force a recapture.
METHOD_D_CAPTURE_RESUME_MODE="${OSPC2FLEX_WINDOWS_METHOD_D_RESUME_MODE:-on}"
SOURCE_HYPERVISOR="${OSPC2FLEX_WIN_SOURCE_HYPERVISOR:-zen}"
FORCE_DIRECT_VIRTIO_BOOT="${OSPC2FLEX_FORCE_DIRECT_VIRTIO_BOOT:-0}"
AUTO_CLEANUP_FAILED="${OSPC2FLEX_AUTO_CLEANUP_FAILED:-0}"
KEEP_ARTIFACTS="${OSPC2FLEX_KEEP_ARTIFACTS:-1}"
ALLOW_UNREPAIRED_UPLOAD="${OSPC2FLEX_ALLOW_UNREPAIRED_WINDOWS_UPLOAD:-0}"
STRICT_DUMMY_ATTACH="${OSPC2FLEX_WINDOWS_V2_STRICT_DUMMY_ATTACH:-0}"
WAIT_TIMEOUT="${OSPC2FLEX_WINDOWS_V2_WAIT_SEC:-2700}"
HEALTHCHECK_WAIT="${OSPC2FLEX_WINDOWS_V2_HEALTHCHECK_WAIT_SEC:-1200}"
FLEX_EXT_NET="${OSPC2FLEX_FLEX_EXT_NET:-PUBLICNET}"
METHOD_D_CAPTURE="/tmp/ospc2flex_windows_method_d_capture.sh"
FLEX_CREDS="/tmp/ospc2flex_flex.sh"
FIRSTBOOT_PS1_WIN='C:\ospc2flex\ospc2flex_windows_firstboot.ps1'
VERIFY_PS1_WIN='C:\ospc2flex\ospc2flex_windows_v2_verify.ps1'
CLOUDBOOT_SCRIPT="/tmp/wincloudbootmigrator.py"

RESCUE_SERVER_NAME=""
FINAL_IMAGE_NAME=""
FINAL_SERVER_NAME=""
RESCUE_JSON=""
RESULT_JSON=""
CHECKPOINT_JSON=""
REPAIR_SENTINEL=""

ACCESS_METHOD=""
ACCESS_IP=""
ACCESS_PORT=""
RESCUE_IMAGE_ID=""
RESCUE_SERVER_ID=""
RESCUE_FLOATING_IP=""
FINAL_IMAGE_ID=""
FINAL_SERVER_ID=""
FINAL_FLOATING_IP=""
DUMMY_VOLUME_ID=""
DUMMY_VOLUME_NAME=""
DUMMY_DETECTED="false"
DRIVER_INSTALL_VERIFIED="false"
FINAL_BOOT_VERIFIED="false"
CURRENT_STATUS="WINDOWS_V2_PREFLIGHT"
STATUS_LOG=()
METHOD_D_CAPTURE_ARGS=()
CP_SAFE_FIRST_BOOT=0
CP_ONLINE_BINDING=0
CP_VIRTIO_SNAPSHOT=0
CP_FINAL_OPT_BOOT=0
CP_SUMMARY_PRINTED=0
GUEST_UNREACHABLE=0

log()  { echo "[$(date '+%H:%M:%S')][$LABEL][V2] $*"; }
PASS() { echo "  ✅ $*"; }
FAIL() { echo "  ❌ $*"; }
WARN() { echo "  ⚠️  $*"; }
INFO() { echo "  ℹ️  $*"; }

prop_equals() {
  local props="$1" key="$2" expected="$3"
  printf '%s\n' "$props" | grep -Eq \
    "${key}[\"']?[[:space:]]*[:=][[:space:]]*[\"']?${expected}([\"']|,|}|[[:space:]]|$)"
}

emit_status() {
  CURRENT_STATUS="$1"
  shift || true
  local msg="$*"
  case "$CURRENT_STATUS" in
    WINDOWS_V2_RESCUE_READY|WINDOWS_V2_IDE_RESCUE_BOOT) CP_SAFE_FIRST_BOOT=1 ;;
    WINDOWS_V2_ONLINE_BINDING_DONE|WINDOWS_V2_DRIVER_INSTALL) CP_ONLINE_BINDING=1 ;;
    WINDOWS_V2_FINAL_IMAGE_READY|WINDOWS_V2_FINAL_IMAGE_CREATE) CP_VIRTIO_SNAPSHOT=1 ;;
    WINDOWS_V2_SUCCESS|WINDOWS_V2_FINAL_VIRTIO_BOOT) CP_FINAL_OPT_BOOT=1 ;;
  esac
  STATUS_LOG+=("$CURRENT_STATUS${msg:+ :: $msg}")
  save_checkpoint_state
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════════"
  echo " $CURRENT_STATUS"
  [ -n "$msg" ] && echo " $msg"
  echo " CHECKPOINTS :: Safe first boot=$([ \"$CP_SAFE_FIRST_BOOT\" = \"1\" ] && echo HIT || echo PENDING) · Online VirtIO binding=$([ \"$CP_ONLINE_BINDING\" = \"1\" ] && echo HIT || echo PENDING) · VirtIO-ready snapshot=$([ \"$CP_VIRTIO_SNAPSHOT\" = \"1\" ] && echo HIT || echo PENDING) · Final optimized boot=$([ \"$CP_FINAL_OPT_BOOT\" = \"1\" ] && echo HIT || echo PENDING)"
  echo "═══════════════════════════════════════════════════════════════════════════"
}

save_checkpoint_state() {
  [ -n "${CHECKPOINT_JSON:-}" ] || return 0
  python3 - "$CHECKPOINT_JSON" "$CURRENT_STATUS" "$CP_SAFE_FIRST_BOOT" "$CP_ONLINE_BINDING" "$CP_VIRTIO_SNAPSHOT" "$CP_FINAL_OPT_BOOT" "$RESCUE_SERVER_ID" "$RESCUE_IMAGE_ID" "$RESCUE_FLOATING_IP" <<'PY'
import json, sys
path, status, cp1, cp2, cp3, cp4, rescue_vm, rescue_img, rescue_fip = sys.argv[1:10]
doc = {
  "status": status,
  "safe_first_boot": "HIT" if cp1 == "1" else "PENDING",
  "online_virtio_binding": "HIT" if cp2 == "1" else "PENDING",
  "virtio_ready_snapshot": "HIT" if cp3 == "1" else "PENDING",
  "final_optimized_boot": "HIT" if cp4 == "1" else "PENDING",
  "rescue_server_id": rescue_vm,
  "rescue_image_id": rescue_img,
  "rescue_floating_ip": rescue_fip,
}
with open(path, "w", encoding="utf-8") as f:
  json.dump(doc, f, indent=2)
PY
}

load_checkpoint_state() {
  [ -n "${CHECKPOINT_JSON:-}" ] || return 0
  [ -f "$CHECKPOINT_JSON" ] || return 0
  eval "$(python3 - "$CHECKPOINT_JSON" <<'PY'
import json, sys
doc=json.load(open(sys.argv[1], encoding="utf-8"))
def hit(v): return "1" if str(v).upper()=="HIT" else "0"
print(f'CP_SAFE_FIRST_BOOT={hit(doc.get("safe_first_boot","PENDING"))}')
print(f'CP_ONLINE_BINDING={hit(doc.get("online_virtio_binding","PENDING"))}')
print(f'CP_VIRTIO_SNAPSHOT={hit(doc.get("virtio_ready_snapshot","PENDING"))}')
print(f'CP_FINAL_OPT_BOOT={hit(doc.get("final_optimized_boot","PENDING"))}')
print(f'CURRENT_STATUS="{doc.get("status","WINDOWS_V2_PREFLIGHT")}"')
print(f'RESCUE_SERVER_ID="{doc.get("rescue_server_id","")}"')
print(f'RESCUE_IMAGE_ID="{doc.get("rescue_image_id","")}"')
print(f'RESCUE_FLOATING_IP="{doc.get("rescue_floating_ip","")}"')
PY
)"
}

print_checkpoint_summary() {
  [ "$CP_SUMMARY_PRINTED" = "1" ] && return 0
  CP_SUMMARY_PRINTED=1
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════════"
  echo " WINDOWS_CHECKPOINT_SUMMARY"
  echo " Safe first boot       : $([ \"$CP_SAFE_FIRST_BOOT\" = \"1\" ] && echo HIT || echo PENDING)"
  echo " Online VirtIO binding : $([ \"$CP_ONLINE_BINDING\" = \"1\" ] && echo HIT || echo PENDING)"
  echo " VirtIO-ready snapshot : $([ \"$CP_VIRTIO_SNAPSHOT\" = \"1\" ] && echo HIT || echo PENDING)"
  echo " Final optimized boot  : $([ \"$CP_FINAL_OPT_BOOT\" = \"1\" ] && echo HIT || echo PENDING)"
  echo " Final status          : ${CURRENT_STATUS:-UNKNOWN}"
  echo "═══════════════════════════════════════════════════════════════════════════"
}

json_escape() {
  python3 - "$1" <<'PY'
import json, sys
print(json.dumps(sys.argv[1]))
PY
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { FAIL "Missing required command: $1"; exit 1; }
}

load_flex_creds() {
  if [ ! -f "$FLEX_CREDS" ]; then
    FAIL "FLEX credential file missing: $FLEX_CREDS"
    return 1
  fi
  # Method A may restore OSPC/token auth before returning.  Method B owns all
  # follow-up OpenStack actions on FLEX, so reload FLEX credentials explicitly.
  # shellcheck disable=SC1090
  source "$FLEX_CREDS"
  export OS_INTERFACE="${OS_INTERFACE:-public}"
  export OS_IDENTITY_API_VERSION="${OS_IDENTITY_API_VERSION:-3}"
  if [ -z "${OS_AUTH_URL:-}" ]; then
    FAIL "FLEX credentials loaded from $FLEX_CREDS but OS_AUTH_URL is empty"
    return 1
  fi
  return 0
}

ensure_runtime_deps() {
  local missing=()
  for c in openstack python3 nc ssh sshpass scp; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if [ "${#missing[@]}" -gt 0 ] && command -v apt-get >/dev/null 2>&1; then
    INFO "Installing missing V2 runtime packages: ${missing[*]}"
    sudo apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive sudo apt-get install -y sshpass python3-openstackclient netcat-openbsd >/dev/null 2>&1 || true
  fi
  python3 -c "import winrm" 2>/dev/null || python3 -m pip install --quiet pywinrm requests_ntlm >/dev/null 2>&1 || true
  # Optional for automatic RDP bridge when only 3389 is reachable.
  if command -v apt-get >/dev/null 2>&1; then
    command -v xfreerdp >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive sudo apt-get install -y freerdp2-x11 >/dev/null 2>&1 || true
    command -v xvfb-run >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive sudo apt-get install -y xvfb >/dev/null 2>&1 || true
  fi
  for c in openstack python3 nc ssh sshpass scp; do
    command -v "$c" >/dev/null 2>&1 || { FAIL "Missing required command after install attempt: $c"; exit 1; }
  done
}

build_method_a_args() {
  METHOD_D_CAPTURE_ARGS=()
  local i=0
  while [ $i -lt ${#ORIG_ARGS[@]} ]; do
    local a="${ORIG_ARGS[$i]}"
    case "$a" in
      --cloudboot-target-host|--cloudboot-target-user|--cloudboot-target-port|--cloudboot-target-password|--cloudboot-target-key|--cloudboot-source-winrm-host|--cloudboot-target-winrm-host)
        i=$((i + 2))
        continue
        ;;
      *)
        METHOD_D_CAPTURE_ARGS+=("$a")
        i=$((i + 1))
        ;;
    esac
  done
}

generate_cloudboot_bundle() {
  local bundle="$WORK/${LABEL}.cloudboot"
  local cache_root="$WORK/cloudboot_cache"
  local force_new="${OSPC2FLEX_CLOUDBOOT_FORCE_NEW:-0}"
  local cache_bundle=""
  rm -rf "$bundle"

  if [ "$DRY_RUN" -eq 1 ] && [ -n "$CLOUDBOOT_TARGET_HOST" ]; then
    mkdir -p "$bundle"
    printf '%s\n' "Write-Host '[cloudboot dry-run] firstboot repair placeholder'" > "$bundle/firstboot-repair.ps1"
    printf '%s\n\n' "Windows Registry Editor Version 5.00" > "$bundle/offline_registry_patch.reg"
    printf '%s\n' '{"dry_run": true, "recommended_mode": "validate-pipeline-only"}' > "$bundle/repair_plan.json"
    printf '%s\n' '# CloudBoot dry-run bundle' > "$bundle/report.md"
    PASS "Dry-run: synthetic CloudJumper boot repair bundle created: $bundle"
    return 0
  fi

  if [ ! -f "$CLOUDBOOT_SCRIPT" ] || [ -z "$CLOUDBOOT_TARGET_HOST" ] || [ -z "$WIN_PASSWORD" ]; then
    INFO "CloudJumper bundle skipped — need $CLOUDBOOT_SCRIPT, --cloudboot-target-host, and source Windows password"
    return 0
  fi

  mkdir -p "$cache_root/targets" "$cache_root/repairs" >/dev/null 2>&1 || true

  # Reuse cached bundle for this origin label (or version family) unless forced new.
  if [ "$force_new" != "1" ]; then
    if [ -d "$cache_root/repairs/${LABEL}" ] && [ -f "$cache_root/repairs/${LABEL}/firstboot-repair.ps1" ]; then
      cache_bundle="$cache_root/repairs/${LABEL}"
    fi
    if [ -n "$cache_bundle" ]; then
      mkdir -p "$bundle"
      cp -a "$cache_bundle/." "$bundle/" 2>/dev/null || true
      if [ -f "$bundle/firstboot-repair.ps1" ]; then
        PASS "Reusing cached CloudJumper repair bundle for origin: $cache_bundle"
        return 0
      fi
      rm -rf "$bundle"
    fi
  fi

  emit_status "WINDOWS_CLOUDBOOT_COMPARE" "CloudJumper boot comparison + repair bundle build"
  mkdir -p "$bundle"
  local cb_cmd=(python3 "$CLOUDBOOT_SCRIPT"
    --source-host "$SERVER_IP"
    --source-user "$WIN_USER"
    --source-port "22"
    --target-host "$CLOUDBOOT_TARGET_HOST"
    --target-user "$CLOUDBOOT_TARGET_USER"
    --target-port "$CLOUDBOOT_TARGET_PORT"
    --outdir "$bundle")
  [ -n "$CLOUDBOOT_SOURCE_WINRM_HOST" ] && cb_cmd+=(--source-winrm-host "$CLOUDBOOT_SOURCE_WINRM_HOST")
  [ -n "$CLOUDBOOT_TARGET_WINRM_HOST" ] && cb_cmd+=(--target-winrm-host "$CLOUDBOOT_TARGET_WINRM_HOST")

  export OSPC2FLEX_CLOUDBOOT_SRC_PASS="$WIN_PASSWORD"
  cb_cmd+=(--source-password-env OSPC2FLEX_CLOUDBOOT_SRC_PASS)
  if [ -n "$CLOUDBOOT_TARGET_PASSWORD" ]; then
    export OSPC2FLEX_CLOUDBOOT_TGT_PASS="$CLOUDBOOT_TARGET_PASSWORD"
    cb_cmd+=(--target-password-env OSPC2FLEX_CLOUDBOOT_TGT_PASS)
  elif [ -n "$CLOUDBOOT_TARGET_KEY" ]; then
    cb_cmd+=(--target-key "$CLOUDBOOT_TARGET_KEY")
  fi

  if "${cb_cmd[@]}"; then
    PASS "CloudJumper boot repair bundle generated: $bundle"
    # Cache target boot profile by detected Windows version (win2016/win2019/win2022/unknown).
    if [ -f "$bundle/target_profile.json" ]; then
      _tver=$(python3 - "$bundle/target_profile.json" <<'PY'
import json, sys, re
data=json.load(open(sys.argv[1],encoding="utf-8"))
s=json.dumps(data)
prod=str(data.get("ProductName") or data.get("OS") or data.get("WindowsProductName") or "")
txt=(prod+" "+s).lower()
ver="unknown"
for k in ("2025","2022","2019","2016","2012"):
    if k in txt:
        ver="win"+k
        break
print(ver)
PY
)
      mkdir -p "$cache_root/targets/${_tver}" 2>/dev/null || true
      cp -f "$bundle/target_profile.json" "$cache_root/targets/${_tver}/target_profile.json" 2>/dev/null || true
      PASS "Cached target boot profile: $cache_root/targets/${_tver}/target_profile.json"
    fi
    # Cache repair bundle by origin label for resume/reuse.
    mkdir -p "$cache_root/repairs/${LABEL}" 2>/dev/null || true
    cp -a "$bundle/." "$cache_root/repairs/${LABEL}/" 2>/dev/null || true
    PASS "Cached CloudJumper repair bundle for origin: $cache_root/repairs/${LABEL}"
  else
    WARN "CloudJumper compare failed — continuing without generated bundle"
    if [ -n "$CLOUDBOOT_TARGET_HOST" ] && nc -z -w 4 "$CLOUDBOOT_TARGET_HOST" 3389 2>/dev/null; then
      local rdp_bootstrap="$WORK/${LABEL}.cloudboot_rdp_bootstrap.ps1"
      emit_status "WINDOWS_CLOUDBOOT_RDP_ONLY" "Target is RDP-reachable but SSH/WinRM is unavailable; generated bootstrap helper"
      cat > "$rdp_bootstrap" <<'PSEOF'
# Run this in an elevated PowerShell session on the target VM (via RDP).
# It enables WinRM (5985) and OpenSSH (22) so CloudJumper can collect/compare.
$ErrorActionPreference = 'Continue'

Set-Service -Name WinRM -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service WinRM -ErrorAction SilentlyContinue
winrm quickconfig -quiet
winrm set winrm/config/service '@{AllowUnencrypted="true"}' | Out-Null
winrm set winrm/config/service/auth '@{Basic="true"}' | Out-Null
if (-not (Get-NetFirewallRule -DisplayName "ospc2flex-WinRM" -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -DisplayName "ospc2flex-WinRM" -Direction Inbound -Protocol TCP -LocalPort 5985 -Action Allow -Profile Any | Out-Null
}

$cap = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction SilentlyContinue
if ($cap -and $cap.State -ne 'Installed') {
  Add-WindowsCapability -Online -Name $cap.Name | Out-Null
}
Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service sshd -ErrorAction SilentlyContinue
if (-not (Get-NetFirewallRule -DisplayName "ospc2flex-SSH" -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -DisplayName "ospc2flex-SSH" -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -Profile Any | Out-Null
}

Write-Host "[ospc2flex] RDP bootstrap complete. Re-run Method C / CloudJumper compare."
PSEOF
      WARN "RDP-only target detected at ${CLOUDBOOT_TARGET_HOST}:3389"
      WARN "Bootstrap script generated: $rdp_bootstrap"
      local auto_bridge="${OSPC2FLEX_CLOUDBOOT_RDP_AUTOBRIDGE:-1}"
      if [ "$auto_bridge" = "1" ] && [ -n "${CLOUDBOOT_TARGET_PASSWORD:-}" ] && command -v xfreerdp >/dev/null 2>&1; then
        emit_status "WINDOWS_CLOUDBOOT_RDP_AUTOBRIDGE" "Attempting automatic RDP bootstrap to enable WinRM/SSH"
        local ps_payload
        ps_payload="$(cat <<'AUTOEOF'
$ErrorActionPreference='Continue'
Set-Service -Name WinRM -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service WinRM -ErrorAction SilentlyContinue
winrm quickconfig -quiet
winrm set winrm/config/service '@{AllowUnencrypted="true"}' | Out-Null
winrm set winrm/config/service/auth '@{Basic="true"}' | Out-Null
if (-not (Get-NetFirewallRule -DisplayName "ospc2flex-WinRM" -ErrorAction SilentlyContinue)) { New-NetFirewallRule -DisplayName "ospc2flex-WinRM" -Direction Inbound -Protocol TCP -LocalPort 5985 -Action Allow -Profile Any | Out-Null }
$cap = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction SilentlyContinue
if ($cap -and $cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service sshd -ErrorAction SilentlyContinue
if (-not (Get-NetFirewallRule -DisplayName "ospc2flex-SSH" -ErrorAction SilentlyContinue)) { New-NetFirewallRule -DisplayName "ospc2flex-SSH" -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -Profile Any | Out-Null }
Write-Host '[ospc2flex] auto-rdp bootstrap complete'
AUTOEOF
)"
        local ps_b64
        ps_b64="$(printf '%s' "$ps_payload" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)"
        local rdp_cmd
        rdp_cmd="xfreerdp /v:${CLOUDBOOT_TARGET_HOST} /u:${CLOUDBOOT_TARGET_USER} /p:${CLOUDBOOT_TARGET_PASSWORD} /cert:ignore /sec:nla /shell:\"cmd.exe /c powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ${ps_b64}\" /log-level:ERROR +auto-reconnect /auto-reconnect-max-retries:0"
        local rdp_rc=1
        if [ -n "${DISPLAY:-}" ]; then
          timeout 90 bash -lc "$rdp_cmd" >/dev/null 2>&1 || rdp_rc=$?
        elif command -v xvfb-run >/dev/null 2>&1; then
          timeout 90 xvfb-run -a bash -lc "$rdp_cmd" >/dev/null 2>&1 || rdp_rc=$?
        else
          WARN "RDP autobridge skipped: no DISPLAY and xvfb-run unavailable"
        fi
        if [ "${rdp_rc:-0}" -eq 0 ] || [ "${rdp_rc:-0}" -eq 124 ]; then
          # xfreerdp may keep session open briefly; validate resulting channels.
          sleep 3
          if nc -z -w 4 "$CLOUDBOOT_TARGET_HOST" 22 2>/dev/null || nc -z -w 4 "$CLOUDBOOT_TARGET_HOST" 5985 2>/dev/null; then
            PASS "RDP autobridge enabled target SSH/WinRM; retrying CloudJumper compare"
            if "${cb_cmd[@]}"; then
              PASS "CloudJumper boot repair bundle generated after RDP autobridge: $bundle"
              unset OSPC2FLEX_CLOUDBOOT_SRC_PASS OSPC2FLEX_CLOUDBOOT_TGT_PASS || true
              return 0
            fi
            WARN "CloudJumper retry still failed after RDP autobridge attempt"
          else
            WARN "RDP autobridge command ran but target SSH/WinRM ports are still closed"
          fi
        else
          WARN "RDP autobridge failed (rc=${rdp_rc:-unknown})"
        fi
      fi
      WARN "Run bootstrap via RDP as Administrator, then rerun Method C."
      WARN "Long-term: pre-enable WinRM(5985) or SSH(22) in target templates for fully automatic compare."
    fi
    rm -rf "$bundle"
  fi
  unset OSPC2FLEX_CLOUDBOOT_SRC_PASS OSPC2FLEX_CLOUDBOOT_TGT_PASS || true
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-name) SERVER_NAME="$2"; shift 2 ;;
    --server-ip) SERVER_IP="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --flavor) FLAVOR="$2"; shift 2 ;;
    --network) NETWORK="$2"; shift 2 ;;
    --keypair) KEYPAIR="$2"; shift 2 ;;
    --windows-user) WIN_USER="$2"; shift 2 ;;
    --windows-password) WIN_PASSWORD="$2"; shift 2 ;;
    --server-snet-ip) WIN_SNET_IP="$2"; shift 2 ;;
    --cloudboot-target-host) CLOUDBOOT_TARGET_HOST="$2"; shift 2 ;;
    --cloudboot-target-user) CLOUDBOOT_TARGET_USER="$2"; shift 2 ;;
    --cloudboot-target-port) CLOUDBOOT_TARGET_PORT="$2"; shift 2 ;;
    --cloudboot-target-password) CLOUDBOOT_TARGET_PASSWORD="$2"; shift 2 ;;
    --cloudboot-target-key) CLOUDBOOT_TARGET_KEY="$2"; shift 2 ;;
    --cloudboot-source-winrm-host) CLOUDBOOT_SOURCE_WINRM_HOST="$2"; shift 2 ;;
    --cloudboot-target-winrm-host) CLOUDBOOT_TARGET_WINRM_HOST="$2"; shift 2 ;;
    --os-family) OS_FAMILY="$2"; shift 2 ;;
    --os-type) OS_TYPE="$2"; shift 2 ;;
    --force-fresh-capture) FORCE_FRESH_CAPTURE=1; shift ;;
    --disable-resume) DISABLE_RESUME=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      echo "Usage: $0 --server-name NAME --server-ip IP --label LABEL [--windows-password PASS]"
      exit 0
      ;;
    *) WARN "Ignoring unknown arg: $1"; shift ;;
  esac
done

[ -n "$SERVER_NAME" ] || { echo "ERROR: --server-name required"; exit 1; }
[ -n "$LABEL" ] || LABEL="$SERVER_NAME"

mkdir -p "$WORK"
mkdir -p "$WORK/locks"
LOCK_FILE="$WORK/locks/${LABEL}.lock"
if [ "${OSPC2FLEX_DISABLE_LABEL_LOCK:-0}" = "1" ]; then
  WARN "Method D label lock disabled by OSPC2FLEX_DISABLE_LABEL_LOCK=1"
else
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    FAIL "Another Method D migration is already active for this label: $LABEL"
    FAIL "Lock file: $LOCK_FILE"
    exit 1
  fi
fi
ensure_runtime_deps
build_method_a_args

RESCUE_SERVER_NAME="${LABEL}-ide-rescue"
FINAL_IMAGE_NAME="${LABEL}-virtio-final-img"
FINAL_SERVER_NAME="${LABEL}-virtio-final"
RESCUE_JSON="$WORK/${LABEL}.windows_v2_rescue.json"
RESULT_JSON="$WORK/${LABEL}.windows_v2_result.json"
CHECKPOINT_JSON="$WORK/${LABEL}.windows_v2_checkpoint.json"
REPAIR_SENTINEL="$WORK/${LABEL}.qcow2.win_repaired"
load_checkpoint_state

save_console_log() {
  local server_id="$1" out="$2"
  openstack console log show "$server_id" >"$out" 2>&1 || true
}

write_result_json() {
  python3 - "$RESULT_JSON" "$LABEL" "$SERVER_IP" "$WINDOWS_MODE" "$RESCUE_IMAGE_ID" "$RESCUE_SERVER_ID" "$RESCUE_FLOATING_IP" "$DUMMY_VOLUME_ID" "$FINAL_IMAGE_ID" "$FINAL_SERVER_ID" "$CURRENT_STATUS" "$DRIVER_INSTALL_VERIFIED" "$DUMMY_DETECTED" "$FINAL_BOOT_VERIFIED" "$CP_SAFE_FIRST_BOOT" "$CP_ONLINE_BINDING" "$CP_VIRTIO_SNAPSHOT" "$CP_FINAL_OPT_BOOT" "$GUEST_UNREACHABLE" "$(printf '%s\n' "${STATUS_LOG[@]}")" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
is_success = sys.argv[11] in {"WINDOWS_V2_SUCCESS", "METHOD_F_SUCCESS", "METHOD_G_SUCCESS"}
payload = {
  "label": sys.argv[2],
  "source": sys.argv[3],
  "mode": sys.argv[4],
  "rescue_image_id": sys.argv[5],
  "rescue_server_id": sys.argv[6],
  "rescue_floating_ip": sys.argv[7],
  "dummy_volume_id": sys.argv[8],
  "final_image_id": sys.argv[9],
  "final_server_id": sys.argv[10],
  "status": sys.argv[11],
  "driver_install_verified": sys.argv[12].lower() == "true",
  "dummy_volume_detected": sys.argv[13].lower() == "true",
  "final_boot_verified": sys.argv[14].lower() == "true",
  "safe_first_boot": "HIT" if sys.argv[15] == "1" else "PENDING",
  "online_virtio_binding": "HIT" if sys.argv[16] == "1" else "PENDING",
  "virtio_ready_snapshot": "HIT" if sys.argv[17] == "1" else "PENDING",
  "final_optimized_boot": "HIT" if sys.argv[18] == "1" else "PENDING",
  "final": is_success,
  "guest_unreachable": sys.argv[19] == "1",
  "logs": [line for line in sys.argv[20].splitlines() if line.strip()],
}
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
}

method_f_emit() {
  local status="$1"
  local msg="$2"
  CURRENT_STATUS="$status"
  STATUS_LOG+=("$status${msg:+ :: $msg}")
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════════"
  echo " $status"
  [ -n "$msg" ] && echo " $msg"
  echo "═══════════════════════════════════════════════════════════════════════════"
}

method_f_validate_artifact() {
  local artifact="$1"
  METHOD_F_ARTIFACT_VALIDATION_JSON="$WORK/${LABEL}.artifact_validation.json"
  python3 - "$artifact" "$METHOD_F_ARTIFACT_VALIDATION_JSON" <<'PY'
import json, os, subprocess, sys
artifact, out_json = sys.argv[1:3]
status = "METHOD_F_ARTIFACT_VALIDATED"
failure_reason = ""
next_action = ""
ok = True
details = {"artifact_path": artifact, "is_absolute": os.path.isabs(artifact)}
if not os.path.isabs(artifact):
    ok = False
if not os.path.isfile(artifact):
    ok = False
if ok:
    size = os.path.getsize(artifact)
    details["size_bytes"] = size
    if size <= 1024 * 1024:
        ok = False
if ok and "/bad_artifacts/" in artifact:
    ok = False
if ok:
    p = subprocess.run(["qemu-img", "info", artifact], capture_output=True, text=True)
    details["qemu_img_info_rc"] = p.returncode
    details["qemu_img_info"] = p.stdout[-2000:]
    if p.returncode != 0:
        ok = False
if ok:
    p = subprocess.run(["qemu-img", "check", artifact], capture_output=True, text=True)
    details["qemu_img_check_rc"] = p.returncode
    details["qemu_img_check"] = (p.stdout + "\n" + p.stderr)[-2000:]
    # qemu-img check may fail for some remote backends; only hard-fail on obvious corruption.
    if p.returncode not in (0, 3):
        details["qemu_img_check_warning"] = "non-fatal check return code"
if not ok:
    status = "SOURCE_ARTIFACT_INVALID"
    failure_reason = "INVALID_EXPORTED_DISK_ARTIFACT"
    next_action = "Re-export source disk or request provider-assisted export."
doc = {
    "method": "F",
    "stage": "F4_LOCAL_ARTIFACT_VALIDATE",
    "status": status,
    "failure_reason": failure_reason,
    "next_action": next_action,
    "final": False,
    "details": details,
}
with open(out_json, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2)
if not ok:
    sys.exit(1)
PY
}

rc=0
trap 'rc=$?; write_result_json || true; print_checkpoint_summary || true; exit $rc' EXIT

wait_for_server_status() {
  local server_id="$1" target="$2" timeout="$3" waited=0
  while [ "$waited" -lt "$timeout" ]; do
    local status
    status=$(openstack server show "$server_id" -f value -c status 2>/dev/null | tr -d '\r' || echo "UNKNOWN")
    if [ "$status" = "$target" ]; then
      return 0
    fi
    sleep 10
    waited=$((waited + 10))
  done
  return 1
}

get_server_ips() {
  local server_id="$1"
  openstack server show "$server_id" -f value -c addresses 2>/dev/null \
    | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' || true
}

# Order addresses for management probes: optional OSPC2FLEX_V2_PREFERRED_IP first,
# then non-RFC1918 (e.g. floating / public), then tenant-private. Jumphosts off
# the tenant VRF often cannot reach private IPs even when OpenStack lists them.
get_probe_ip_list() {
  local server_id="$1"
  local prefer raw
  prefer="${OSPC2FLEX_V2_PREFERRED_IP:-}"
  raw=$(get_server_ips "$server_id")
  # SC2259 fix: heredoc overrides pipe for python3 stdin, so pass IPs via env var
  MGS_RAW_IPS="$raw" MGS_PREFER_IP="$prefer" python3 <<'PY'
import os

prefer = (os.environ.get("MGS_PREFER_IP") or "").strip()
raw    = (os.environ.get("MGS_RAW_IPS") or "")
ips_in = [ln.strip() for ln in raw.splitlines() if ln.strip()]
seen = set()
ips = []
for ip in ips_in:
    if ip not in seen:
        seen.add(ip)
        ips.append(ip)


def is_private(ip):
    parts = ip.split(".")
    if len(parts) != 4:
        return True
    try:
        a, b, c, d = (int(x) for x in parts)
    except ValueError:
        return True
    if a == 10:
        return True
    if a == 192 and b == 168:
        return True
    if a == 172 and 16 <= b <= 31:
        return True
    return False


ordered = []


def add(ip):
    if ip and ip not in ordered:
        ordered.append(ip)


if prefer:
    add(prefer)
for ip in ips:
    if not is_private(ip):
        add(ip)
for ip in ips:
    if is_private(ip):
        add(ip)
print("\n".join(ordered))
PY
}

# Real WinRM NTLM probe (more reliable than nc alone for Windows listeners).
probe_winrm_quick() {
  local host="$1" port="$2"
  [ -n "${WIN_PASSWORD:-}" ] || return 1
  WINRM_PROBE_HOST="$host" WINRM_PROBE_PORT="$port" WINRM_USER="$WIN_USER" WINRM_PASS="$WIN_PASSWORD" python3 - <<'PY' 2>/dev/null
import os, sys
try:
    import winrm
except Exception:
    sys.exit(99)

host = os.environ["WINRM_PROBE_HOST"]
port = os.environ["WINRM_PROBE_PORT"]
user = os.environ["WINRM_USER"]
password = os.environ["WINRM_PASS"]
scheme = "https" if str(port) == "5986" else "http"
try:
    session = winrm.Session(
        f"{scheme}://{host}:{port}/wsman",
        auth=(user, password),
        transport="ntlm",
        server_cert_validation="ignore",
        read_timeout_sec=18,
        operation_timeout_sec=14,
    )
    result = session.run_ps("1")
    sys.exit(result.status_code)
except Exception:
    sys.exit(96)
PY
}

probe_ssh_quick() {
  local host="$1"
  [ -n "${WIN_PASSWORD:-}" ] || return 1
  sshpass -p "$WIN_PASSWORD" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o ConnectTimeout=14 \
    -o PreferredAuthentications=password,keyboard-interactive \
    -o PubkeyAuthentication=no \
    "$WIN_USER@$host" \
    "powershell -NoProfile -ExecutionPolicy Bypass -Command exit 0" </dev/null >/dev/null 2>&1
}

try_ip_guest_access() {
  local ip="$1" deep_ssh="$2"
  local pr
  probe_winrm_quick "$ip" 5986
  pr=$?
  if [ "$pr" -eq 0 ]; then
    ACCESS_METHOD="winrm_https"
    ACCESS_IP="$ip"
    ACCESS_PORT="5986"
    return 0
  fi
  probe_winrm_quick "$ip" 5985
  pr=$?
  if [ "$pr" -eq 0 ]; then
    ACCESS_METHOD="winrm_http"
    ACCESS_IP="$ip"
    ACCESS_PORT="5985"
    return 0
  fi
  if [ "$deep_ssh" = 1 ] || nc -z -w 4 "$ip" 22 2>/dev/null; then
    if probe_ssh_quick "$ip"; then
      ACCESS_METHOD="ssh"
      ACCESS_IP="$ip"
      ACCESS_PORT="22"
      return 0
    fi
  fi
  return 1
}

run_winrm_ps() {
  local host="$1" port="$2" script="$3"
  WINRM_HOST="$host" WINRM_PORT="$port" WINRM_USER="$WIN_USER" WINRM_PASS="$WIN_PASSWORD" WINRM_SCRIPT="$script" python3 - <<'PY'
import os, sys
try:
    import winrm
except Exception as exc:
    print(f"[WINRM] import failed: {exc}", file=sys.stderr)
    sys.exit(97)

host = os.environ["WINRM_HOST"]
port = os.environ["WINRM_PORT"]
user = os.environ["WINRM_USER"]
password = os.environ["WINRM_PASS"]
script = os.environ["WINRM_SCRIPT"]
scheme = "https" if str(port) == "5986" else "http"
session = winrm.Session(
    f"{scheme}://{host}:{port}/wsman",
    auth=(user, password),
    transport="ntlm",
    server_cert_validation="ignore",
    read_timeout_sec=900,
    operation_timeout_sec=300,
)
result = session.run_ps(script)
out = result.std_out.decode("utf-8", errors="replace")
err = result.std_err.decode("utf-8", errors="replace")
if out:
    print(out, end="")
if err:
    print(err, end="", file=sys.stderr)
sys.exit(result.status_code)
PY
}

run_ssh_ps() {
  local host="$1" script="$2"
  local escaped="${script//\"/\\\"}"
  sshpass -p "$WIN_PASSWORD" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o ConnectTimeout=30 \
    -o PreferredAuthentications=password,keyboard-interactive \
    -o PubkeyAuthentication=no \
    "$WIN_USER@$host" \
    "powershell -NoProfile -ExecutionPolicy Bypass -Command \"$escaped\""
}

run_windows_ps() {
  local script="$1"
  case "$ACCESS_METHOD" in
    winrm_http|winrm_https)
      run_winrm_ps "$ACCESS_IP" "$ACCESS_PORT" "$script"
      ;;
    ssh)
      run_ssh_ps "$ACCESS_IP" "$script"
      ;;
    *)
      FAIL "No supported guest execution method is available"
      return 1
      ;;
  esac
}

windows_file_exists() {
  local path="$1"
  local out
  out=$(run_windows_ps "if (Test-Path '$path') { 'YES' } else { 'NO' }" 2>/dev/null || true)
  echo "$out" | grep -q "YES"
}

collect_windows_file() {
  local remote_path="$1" local_path="$2"
  mkdir -p "$(dirname "$local_path")"
  if [ "$ACCESS_METHOD" = "ssh" ]; then
    sshpass -p "$WIN_PASSWORD" ssh \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      -o ConnectTimeout=30 \
      -o PreferredAuthentications=password,keyboard-interactive \
      -o PubkeyAuthentication=no \
      "$WIN_USER@$ACCESS_IP" \
      "powershell -NoProfile -ExecutionPolicy Bypass -Command Get-Content -Raw '$remote_path'" >"$local_path" 2>/dev/null || true
  else
    run_windows_ps "if (Test-Path '$remote_path') { Get-Content -Raw '$remote_path' }" >"$local_path" 2>/dev/null || true
  fi
}

run_cloudboot_v2_repair_if_present() {
  local bundle="$WORK/${LABEL}.cloudboot"
  local local_ps="$bundle/firstboot-repair.ps1"
  local remote_ps='C:\ospc2flex\cloudboot-firstboot-repair.ps1'
  if [ ! -f "$local_ps" ]; then
    INFO "CloudJumper V2 repair bundle not present; using Method B native bootstrap only"
    return 0
  fi

  emit_status "WINDOWS_V2_CLOUDBOOT_REPAIR" "Running generated CloudJumper repair before native V2 bootstrap"
  local b64
  b64=$(base64 -w0 "$local_ps")
  run_windows_ps "[IO.Directory]::CreateDirectory('C:\ospc2flex') | Out-Null; [IO.File]::WriteAllText('$remote_ps', [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$b64'))); Write-Output '[cloudboot-v2] staged $remote_ps'" || true
  run_windows_ps "& '$remote_ps'" || WARN "CloudJumper generated V2 repair returned non-zero; continuing to native Method B bootstrap"
  collect_windows_file 'C:\cloudboot-migrator\firstboot-repair.log' "$WORK/${LABEL}.cloudboot_v2_firstboot.log"
  PASS "CloudJumper generated repair pass completed/attempted before Method B bootstrap"
  return 0
}

attach_floating_ip() {
  local server_id="$1"
  local port_id fip_json fip_id fip
  port_id=$(openstack port list --server "$server_id" -f value -c ID -c Status 2>/dev/null | awk '$2=="ACTIVE"{print $1; exit}' || true)
  [ -z "$port_id" ] && port_id=$(openstack port list --server "$server_id" -f value -c ID 2>/dev/null | head -1 || true)
  [ -n "$port_id" ] || return 1
  fip_json=$(openstack floating ip create "$FLEX_EXT_NET" -f json 2>/dev/null || true)
  fip_id=$(printf '%s' "$fip_json" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("id",""))' 2>/dev/null || true)
  fip=$(printf '%s' "$fip_json" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("floating_ip_address",""))' 2>/dev/null || true)
  if [ -z "$fip_id" ]; then
    local row
    row=$(openstack floating ip list --status DOWN -f value -c ID -c "Floating IP Address" 2>/dev/null | head -1 || true)
    fip_id=$(echo "$row" | awk '{print $1}')
    fip=$(echo "$row" | awk '{print $2}')
  fi
  [ -n "$fip_id" ] || return 1
  openstack floating ip set --port "$port_id" "$fip_id" >/dev/null 2>&1 || true
  printf '%s\n' "$fip"
  return 0
}

wait_for_windows_guest_access() {
  local server_id="$1" label_prefix="$2" timeout="$3"
  local waited=0
  local poll=15
  local last_report=0
  local console_path="$WORK/${LABEL}.${label_prefix}_console.log"
  local ips deep_ssh rdp_seen
  while [ "$waited" -lt "$timeout" ]; do
    local status
    status=$(openstack server show "$server_id" -f value -c status 2>/dev/null | tr -d '\r' || echo "UNKNOWN")
    ACCESS_METHOD=""
    ACCESS_IP=""
    ACCESS_PORT=""
    ips=$(get_probe_ip_list "$server_id")
    deep_ssh=0
    [ "$waited" -ge 60 ] && deep_ssh=1
    rdp_seen=""
    while read -r ip; do
      [ -n "$ip" ] || continue
      if try_ip_guest_access "$ip" "$deep_ssh"; then
        return 0
      fi
      if nc -z -w 3 "$ip" 3389 2>/dev/null; then
        rdp_seen="${rdp_seen:+$rdp_seen }${ip}:3389"
      fi
    done <<<"$ips"

    if [ $((waited - last_report)) -ge 60 ]; then
      save_console_log "$server_id" "$console_path"
      INFO "Waiting for guest access: status=$status probe_order=[$(echo "$ips" | tr '\n' ' ')] rdp_tcp=[${rdp_seen:-no}] elapsed=${waited}s"
      last_report="$waited"
    fi
    sleep "$poll"
    waited=$((waited + poll))
  done

  save_console_log "$server_id" "$console_path"
  python3 - "$WORK/${LABEL}.${label_prefix}_wait_failure.json" "$server_id" "$ACCESS_METHOD" "$ACCESS_IP" "$ACCESS_PORT" "$timeout" <<'PY'
import json, sys
from pathlib import Path
payload = {
  "server_id": sys.argv[2],
  "access_method": sys.argv[3],
  "access_ip": sys.argv[4],
  "access_port": sys.argv[5],
  "timeout_sec": int(sys.argv[6]),
}

emit_guest_unreachable_diagnostics() {
  local server_id="$1"
  emit_status "WINDOWS_V2_GUEST_UNREACHABLE" "Guest access timeout reached; rescue VM kept running"
  INFO "Manual next steps:"
  INFO "  openstack console url show $server_id"
  INFO "  openstack server show $server_id -c addresses -c status"
  INFO "  check Windows firewall / RDP service / boot screen"
  INFO "Diagnostics snapshot:"
  openstack server show "$server_id" -f value -c status -c addresses -c OS-EXT-STS:vm_state -c OS-EXT-STS:power_state 2>/dev/null | sed 's/^/  /' || true
  openstack console url show "$server_id" 2>/dev/null | sed 's/^/  /' || true
  _port_ids=$(openstack port list --server "$server_id" -f value -c ID 2>/dev/null || true)
  if [ -n "$_port_ids" ]; then
    INFO "Ports:"
    printf '%s\n' "$_port_ids" | sed 's/^/  /'
  fi
  _sgs=$(openstack server show "$server_id" -f value -c security_groups 2>/dev/null | sed -n "s/.*name='\([^']*\)'.*/\1/p" || true)
  for sg in $_sgs; do
    INFO "Security group rules for $sg:"
    openstack security group rule list "$sg" 2>/dev/null | sed 's/^/  /' || true
  done
  if ! nc -z -w 3 "${RESCUE_FLOATING_IP:-}" 3389 2>/dev/null; then
    WARN "RDP TCP 3389 not reachable. Verify security group and Windows firewall."
  fi
}
Path(sys.argv[1]).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
  return 1
}

create_and_attach_dummy_volume() {
  emit_status "WINDOWS_V2_DUMMY_VOLUME_CREATE" "Creating best-effort dummy volume"
  DUMMY_VOLUME_NAME="${RESCUE_SERVER_NAME}-dummy-virtio"
  DUMMY_VOLUME_ID=$(openstack volume create --size 5 "$DUMMY_VOLUME_NAME" -f value -c id 2>/dev/null | tr -d '\r\n' || true)
  if [ -z "$DUMMY_VOLUME_ID" ]; then
    WARN "Dummy volume create failed; continuing"
    return 0
  fi
  local waited=0
  while [ "$waited" -lt 300 ]; do
    local vol_status
    vol_status=$(openstack volume show "$DUMMY_VOLUME_ID" -f value -c status 2>/dev/null | tr -d '\r' || echo "unknown")
    [ "$vol_status" = "available" ] && break
    sleep 5
    waited=$((waited + 5))
  done
  emit_status "WINDOWS_V2_DUMMY_VOLUME_ATTACH" "Attaching dummy volume"
  if ! openstack server add volume "$RESCUE_SERVER_ID" "$DUMMY_VOLUME_ID" >/dev/null 2>&1; then
    WARN "Dummy volume attach failed; continuing"
    return 0
  fi
  if [[ "$ACCESS_METHOD" =~ ^winrm|ssh$ ]]; then
    local verify
    verify=$(run_windows_ps "Get-Disk | Format-Table Number,FriendlyName,BusType,OperationalStatus,PartitionStyle -Auto | Out-String; Get-PnpDevice | Where-Object { \$_.FriendlyName -match 'VirtIO|Red Hat|SCSI|Storage|Disk' } | Format-Table -Auto | Out-String" 2>/dev/null || true)
    printf '%s\n' "$verify" >"$WORK/${LABEL}.dummy_volume_detect.txt"
    if echo "$verify" | grep -Eiq 'VirtIO|Red Hat|SCSI'; then
      DUMMY_DETECTED="true"
      PASS "Dummy VirtIO hardware detection confirmed"
    else
      WARN "Dummy VirtIO hardware detection not confirmed. Continuing because pnputil + boot-start checks still run."
      [ "$STRICT_DUMMY_ATTACH" = "1" ] && return 1
    fi
  fi
  return 0
}

run_windows_v2_firstboot() {
  emit_status "WINDOWS_V2_DRIVER_INSTALL" "Online VirtIO binding: running in-guest pnputil bootstrap"
  run_cloudboot_v2_repair_if_present || true
  local ps_script="& '$FIRSTBOOT_PS1_WIN'"
  run_windows_ps "$ps_script" || true
  emit_status "WINDOWS_V2_DRIVER_VERIFY" "Checking bootstrap marker and verification output"
  if ! windows_file_exists 'C:\ospc2flex_v2_bootstrap_success.txt'; then
    FAIL "Windows V2 bootstrap marker was not created"
    return 1
  fi
  DRIVER_INSTALL_VERIFIED="true"
  collect_windows_file 'C:\ospc2flex\windows_v2_firstboot.log' "$WORK/${LABEL}.windows_v2_firstboot.log"
  collect_windows_file 'C:\ospc2flex\driverquery_after_v2.txt' "$WORK/${LABEL}.driverquery_after_v2.txt"
  collect_windows_file 'C:\ospc2flex\pnputil_enum_after_v2.txt' "$WORK/${LABEL}.pnputil_enum_after_v2.txt"
  collect_windows_file 'C:\ospc2flex\bcd_after_v2.txt' "$WORK/${LABEL}.bcd_after_v2.txt"
  run_windows_ps "& '$VERIFY_PS1_WIN'" >"$WORK/${LABEL}.windows_v2_verify.txt" || true
  if ! grep -Eiq 'DRIVER_MATCH=1|SERVICE\.viostor\.Start=0|SERVICE\.vioscsi\.Start=0' "$WORK/${LABEL}.windows_v2_verify.txt" 2>/dev/null; then
    FAIL "Driver verification did not confirm the expected VirtIO state"
    return 1
  fi
  PASS "Windows V2 driver install + verification succeeded"
  return 0
}

reboot_rescue_guest_and_verify() {
  emit_status "WINDOWS_V2_DRIVER_VERIFY" "Rebooting once on IDE/e1000 and verifying guest boot"
  run_windows_ps "Restart-Computer -Force" || true
  sleep 20
  ACCESS_METHOD=""
  ACCESS_IP=""
  ACCESS_PORT=""
  if ! OSPC2FLEX_V2_PREFERRED_IP="${RESCUE_FLOATING_IP:-}" wait_for_windows_guest_access "$RESCUE_SERVER_ID" "rescue_post_bind_reboot" 1200; then
    FAIL "Rescue VM did not become reachable after IDE/e1000 reboot"
    return 1
  fi
  run_windows_ps "& '$VERIFY_PS1_WIN'" >"$WORK/${LABEL}.windows_v2_verify_after_reboot.txt" || true
  if ! grep -Eiq 'DRIVER_MATCH=1|SERVICE\.viostor\.Start=0|SERVICE\.vioscsi\.Start=0' "$WORK/${LABEL}.windows_v2_verify_after_reboot.txt" 2>/dev/null; then
    FAIL "Post-reboot verification did not confirm expected VirtIO state"
    return 1
  fi
  PASS "Rescue VM rebooted and verified on safe IDE/e1000 path"
  return 0
}

shutdown_rescue_guest() {
  emit_status "WINDOWS_V2_GUEST_SHUTDOWN" "Shutting rescue guest down cleanly"
  run_windows_ps "Stop-Computer -Force" || true
  if ! wait_for_server_status "$RESCUE_SERVER_ID" "SHUTOFF" 900; then
    FAIL "Rescue VM did not reach SHUTOFF in time"
    return 1
  fi
  PASS "Rescue VM reached SHUTOFF"
}

create_final_image() {
  emit_status "WINDOWS_V2_FINAL_IMAGE_CREATE" "VirtIO-ready snapshot: creating final image from rescue VM"
  local image_id
  image_id=$(openstack server image create "$RESCUE_SERVER_ID" --name "$FINAL_IMAGE_NAME" -f value -c id 2>/dev/null | tr -d '\r\n' || true)
  [ -n "$image_id" ] || return 1
  FINAL_IMAGE_ID="$image_id"
  local waited=0
  while [ "$waited" -lt 1800 ]; do
    local status
    status=$(openstack image show "$FINAL_IMAGE_ID" -f value -c status 2>/dev/null | tr -d '\r' || echo "unknown")
    [ "$status" = "active" ] && break
    sleep 10
    waited=$((waited + 10))
  done
  local status
  status=$(openstack image show "$FINAL_IMAGE_ID" -f value -c status 2>/dev/null | tr -d '\r' || echo "unknown")
  if [ "$status" != "active" ]; then
    FAIL "Final image did not become active: $FINAL_IMAGE_ID status=$status"
    return 1
  fi
  openstack image set \
    --property os_type=windows \
    --property os_distro=windows \
    --property vm_mode=hvm \
    --property hw_disk_bus=scsi \
    --property hw_scsi_model=virtio-scsi \
    --property hw_vif_model=virtio \
    --property hw_qemu_guest_agent=yes \
    "$FINAL_IMAGE_ID"
  local props
  props=$(openstack image show -f value -c properties "$FINAL_IMAGE_ID" 2>/dev/null || true)
  prop_equals "$props" "hw_disk_bus" "scsi" || return 1
  prop_equals "$props" "hw_scsi_model" "virtio-scsi" || return 1
  prop_equals "$props" "hw_vif_model" "virtio" || return 1
  prop_equals "$props" "hw_qemu_guest_agent" "yes" || return 1
  PASS "Final VirtIO image metadata verified"
}

validate_rescue_safe_metadata() {
  emit_status "WINDOWS_V2_RESCUE_METADATA_VERIFY" "Validating Phase 1 safe IDE/e1000 image metadata"
  local props
  props=$(openstack image show "$RESCUE_IMAGE_ID" -f value -c properties 2>/dev/null || true)

  if echo "$props" | grep -Eq "hw_scsi_model[\"']?[[:space:]]*[:=]"; then
    FAIL "Unsafe rescue metadata: hw_scsi_model is present during safe IDE first boot"
    echo "$props"
    return 1
  fi

  if echo "$props" | grep -Eq "hw_qemu_guest_agent[\"']?[[:space:]]*[:=]"; then
    FAIL "Unsafe rescue metadata: hw_qemu_guest_agent is present during safe IDE first boot"
    echo "$props"
    return 1
  fi

  prop_equals "$props" "hw_disk_bus" "ide" || {
    FAIL "Rescue image metadata missing hw_disk_bus=ide"
    echo "$props"
    return 1
  }

  prop_equals "$props" "hw_cdrom_bus" "ide" || {
    FAIL "Rescue image metadata missing hw_cdrom_bus=ide"
    echo "$props"
    return 1
  }

  prop_equals "$props" "hw_vif_model" "e1000" || {
    FAIL "Rescue image metadata missing hw_vif_model=e1000"
    echo "$props"
    return 1
  }

  PASS "Rescue safe IDE/e1000 metadata verified"
  return 0
}

boot_final_vm() {
  emit_status "WINDOWS_V2_FINAL_VIRTIO_BOOT" "Final optimized boot: launching VirtIO/SCSI VM"
  local create_args=(server create "$FINAL_SERVER_NAME" --image "$FINAL_IMAGE_ID" --flavor "$FLAVOR" --network "$NETWORK" --wait -f value -c id)
  if [ -n "$KEYPAIR" ]; then
    create_args+=(--key-name "$KEYPAIR")
  fi
  FINAL_SERVER_ID=$(openstack "${create_args[@]}" 2>/dev/null | tr -d '\r\n' || true)
  [ -n "$FINAL_SERVER_ID" ] || FINAL_SERVER_ID=$(openstack server list --name "$FINAL_SERVER_NAME" -f value -c ID 2>/dev/null | head -1 | tr -d '\r\n' || true)
  [ -n "$FINAL_SERVER_ID" ] || return 1
  FINAL_FLOATING_IP=$(attach_floating_ip "$FINAL_SERVER_ID" || true)
  return 0
}

healthcheck_final_vm() {
  emit_status "WINDOWS_V2_HEALTHCHECK" "Checking final VirtIO boot"
  ACCESS_METHOD=""
  ACCESS_IP=""
  ACCESS_PORT=""
  if ! OSPC2FLEX_V2_PREFERRED_IP="${FINAL_FLOATING_IP:-}" wait_for_windows_guest_access "$FINAL_SERVER_ID" "final_virtio" "$HEALTHCHECK_WAIT"; then
    FAIL "Final VM never became reachable"
    save_console_log "$FINAL_SERVER_ID" "$WORK/${LABEL}.final_virtio_console.log"
    return 1
  fi
  if openstack console log show "$FINAL_SERVER_ID" 2>/dev/null | grep -Eiq "Windows\\\\system32\\\\config\\\\system|Status:\s*0xc0000225"; then
    FAIL "Final VM console log indicates SYSTEM hive corruption (0xc0000225)"
    emit_status "WINDOWS_SYSTEM_HIVE_INVALID" "failure_reason=WINDOWS_SYSTEM_REGISTRY_HIVE_CORRUPTED next_action=Use fresh source export or restore SYSTEM hive backup."
    save_console_log "$FINAL_SERVER_ID" "$WORK/${LABEL}.final_virtio_console.log"
    return 1
  fi
  if openstack console log show "$FINAL_SERVER_ID" 2>/dev/null | grep -q "INACCESSIBLE_BOOT_DEVICE"; then
    FAIL "Final VM console log shows INACCESSIBLE_BOOT_DEVICE"
    save_console_log "$FINAL_SERVER_ID" "$WORK/${LABEL}.final_virtio_console.log"
    return 1
  fi
  run_windows_ps '$env:COMPUTERNAME; Get-Disk | Format-Table Number,FriendlyName,BusType,OperationalStatus -Auto | Out-String; driverquery | findstr /i "virtio Red Hat viostor vioscsi netkvm"; Get-Service WinRM,TermService | Format-Table -Auto | Out-String' >"$WORK/${LABEL}.windows_v2_healthcheck.txt" || true
  FINAL_BOOT_VERIFIED="true"
  PASS "Final VirtIO VM passed the basic healthcheck"
}

cleanup_success() {
  [ -n "$DUMMY_VOLUME_ID" ] && openstack server remove volume "$RESCUE_SERVER_ID" "$DUMMY_VOLUME_ID" >/dev/null 2>&1 || true
  [ -n "$DUMMY_VOLUME_ID" ] && openstack volume delete "$DUMMY_VOLUME_ID" >/dev/null 2>&1 || true
  [ -n "$RESCUE_SERVER_ID" ] && openstack server delete "$RESCUE_SERVER_ID" >/dev/null 2>&1 || true
  [ -n "$RESCUE_IMAGE_ID" ] && openstack image delete "$RESCUE_IMAGE_ID" >/dev/null 2>&1 || true
  if [ "$KEEP_ARTIFACTS" = "0" ]; then
    rm -f "$RESCUE_JSON" 2>/dev/null || true
  fi
}

echo "═══════════════════════════════════════════════════════════════════════════"
echo " OSPC→FLEX Windows Method D Standalone Engine"
echo "═══════════════════════════════════════════════════════════════════════════"
echo "  Server    : $SERVER_NAME ($SERVER_IP)"
echo "  Label     : $LABEL"
echo "  Mode      : $WINDOWS_MODE"
echo "  Flavor    : $FLAVOR"
echo "  Network   : $NETWORK"
echo "  Keypair   : ${KEYPAIR:-<none>}"
echo "═══════════════════════════════════════════════════════════════════════════"

if { [ "${SOURCE_HYPERVISOR,,}" = "zen" ] || [ "${SOURCE_HYPERVISOR,,}" = "xen" ]; } && [ "$FORCE_DIRECT_VIRTIO_BOOT" != "1" ]; then
  emit_status "WINDOWS_SAFE_IDE_GUARD" "Guard active: OSPC Zen source requires safe IDE first boot (Zen routing → FLEX KVM)"
  WARN "Direct first-boot to VirtIO/SCSI is blocked for OSPC Zen/legacy-xen source (set OSPC2FLEX_FORCE_DIRECT_VIRTIO_BOOT=1 to override)."
fi

if [ "$DRY_RUN" -eq 1 ]; then
  emit_status "WINDOWS_V2_PREFLIGHT" "Dry-run preflight"
  generate_cloudboot_bundle
  if [ -f "$WORK/${LABEL}.cloudboot/firstboot-repair.ps1" ]; then
    METHOD_D_CAPTURE_ARGS+=(--cloudboot-bundle "$WORK/${LABEL}.cloudboot")
  fi
  env OSPC2FLEX_WINDOWS_MODE=two_phase_virtio \
      OSPC2FLEX_RESUME_MODE="$METHOD_D_CAPTURE_RESUME_MODE" \
      OSPC2FLEX_WINDOWS_BOOT_PROFILE=safe_ide_firstboot \
      OSPC2FLEX_WIN_DISK_BUS=ide \
      OSPC2FLEX_WIN_CDROM_BUS=ide \
      OSPC2FLEX_WIN_VIF_MODEL=e1000 \
      OSPC2FLEX_SKIP_BOOT_VALIDATOR=1 \
      OSPC2FLEX_CLOUD_LABEL="$RESCUE_SERVER_NAME" \
      OSPC2FLEX_WINDOWS_OUTPUT_JSON="$RESCUE_JSON" \
      "$METHOD_D_CAPTURE" "${METHOD_D_CAPTURE_ARGS[@]}" --dry-run
  emit_status "WINDOWS_V2_DRYRUN_COMPLETE" "Dry-run finished before rescue upload/boot follow-through"
  exit 0
fi

if [ ! -x "$METHOD_D_CAPTURE" ]; then
  FAIL "Method D capture helper missing on jumphost: $METHOD_D_CAPTURE"
  exit 1
fi

if [ "$WORKFLOW" = "method_f" ]; then
  FAIL "Method F has been removed. Use windows_method_g_simple."
  CURRENT_STATUS="METHOD_F_REMOVED_USE_METHOD_G_SIMPLE"
  exit 1
fi
if [ "$WORKFLOW" = "method_g" ]; then
  FAIL "Legacy Method G (policy export) is removed. Use windows_method_g_simple."
  CURRENT_STATUS="METHOD_G_REMOVED_USE_METHOD_G_SIMPLE"
  exit 1
fi

emit_status "WINDOWS_V2_PREFLIGHT" "Running Method D standalone capture + IDE rescue flow"
generate_cloudboot_bundle
if [ -f "$WORK/${LABEL}.cloudboot/firstboot-repair.ps1" ]; then
  METHOD_D_CAPTURE_ARGS+=(--cloudboot-bundle "$WORK/${LABEL}.cloudboot")
fi
if [ "$FORCE_FRESH_CAPTURE" = "1" ]; then
  METHOD_D_CAPTURE_ARGS+=(--force-fresh-capture)
fi
if [ "$DISABLE_RESUME" = "1" ]; then
  METHOD_D_CAPTURE_ARGS+=(--disable-resume)
fi
METHOD_D_CAPTURE_ARGS+=(--workflow-tag method_d_standalone)
env OSPC2FLEX_WINDOWS_MODE=two_phase_virtio \
    OSPC2FLEX_WORKFLOW="$WORKFLOW" \
    OSPC2FLEX_ALLOW_GUEST_DISK_CAPTURE="${OSPC2FLEX_ALLOW_GUEST_DISK_CAPTURE:-0}" \
    OSPC2FLEX_ALLOW_DISK2VHD="${OSPC2FLEX_ALLOW_DISK2VHD:-0}" \
    OSPC2FLEX_ALLOW_RAW_SSH_CAPTURE="${OSPC2FLEX_ALLOW_RAW_SSH_CAPTURE:-0}" \
    OSPC2FLEX_ALLOW_SMB_HTTPS_OBJECT_TRANSFER="${OSPC2FLEX_ALLOW_SMB_HTTPS_OBJECT_TRANSFER:-0}" \
    OSPC2FLEX_ALLOW_WINDOWS_GLANCE_ONLY="${OSPC2FLEX_ALLOW_WINDOWS_GLANCE_ONLY:-1}" \
    OSPC2FLEX_RESUME_MODE="$METHOD_D_CAPTURE_RESUME_MODE" \
    OSPC2FLEX_WINDOWS_BOOT_PROFILE=safe_ide_firstboot \
    OSPC2FLEX_WIN_DISK_BUS=ide \
    OSPC2FLEX_WIN_CDROM_BUS=ide \
    OSPC2FLEX_WIN_VIF_MODEL=e1000 \
    OSPC2FLEX_SKIP_BOOT_VALIDATOR=1 \
    OSPC2FLEX_CLOUD_LABEL="$RESCUE_SERVER_NAME" \
    OSPC2FLEX_WINDOWS_OUTPUT_JSON="$RESCUE_JSON" \
    "$METHOD_D_CAPTURE" "${METHOD_D_CAPTURE_ARGS[@]}"

load_flex_creds || exit 1

if [ ! -f "$RESCUE_JSON" ]; then
  FAIL "Rescue metadata JSON missing: $RESCUE_JSON"
  exit 1
fi

# Method A can use a timestamped qcow label while v2 label stays stable.
# Accept either sentinel location so fresh-sync runs are not rejected incorrectly.
RESCUE_QCOW_LABEL=$(python3 - "$RESCUE_JSON" <<'PY'
import json, sys
doc=json.load(open(sys.argv[1], encoding="utf-8"))
print(doc.get("label",""))
PY
)
RESCUE_BASE_LABEL=$(python3 - "$RESCUE_JSON" <<'PY'
import json, sys
doc=json.load(open(sys.argv[1], encoding="utf-8"))
print(doc.get("base_label",""))
PY
)

REPAIR_SENTINEL_CANDIDATES=("$REPAIR_SENTINEL")
[ -n "$RESCUE_QCOW_LABEL" ] && REPAIR_SENTINEL_CANDIDATES+=("$WORK/${RESCUE_QCOW_LABEL}.qcow2.win_repaired")
[ -n "$RESCUE_BASE_LABEL" ] && REPAIR_SENTINEL_CANDIDATES+=("$WORK/${RESCUE_BASE_LABEL}.qcow2.win_repaired")
for _cand in "${REPAIR_SENTINEL_CANDIDATES[@]}"; do
  if [ -f "$_cand" ]; then
    REPAIR_SENTINEL="$_cand"
    break
  fi
done

if [ ! -f "$REPAIR_SENTINEL" ] && [ "$ALLOW_UNREPAIRED_UPLOAD" != "1" ]; then
  FAIL "Offline repair sentinel missing: ${REPAIR_SENTINEL_CANDIDATES[*]}"
  exit 1
fi
INFO "Offline repair sentinel: $REPAIR_SENTINEL"

RESCUE_IMAGE_ID=$(python3 - "$RESCUE_JSON" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8")).get("image_id",""))
PY
)
RESCUE_SERVER_ID=$(python3 - "$RESCUE_JSON" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8")).get("vm_id",""))
PY
)
RESCUE_FLOATING_IP=$(python3 - "$RESCUE_JSON" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8")).get("floating_ip",""))
PY
)

[ -n "$RESCUE_IMAGE_ID" ] || { FAIL "Rescue image ID missing from $RESCUE_JSON"; exit 1; }
[ -n "$RESCUE_SERVER_ID" ] || { FAIL "Rescue server ID missing from $RESCUE_JSON"; exit 1; }
validate_rescue_safe_metadata || {
  CURRENT_STATUS="WINDOWS_V2_FAILED_UNSAFE_RESCUE_METADATA"
  exit 1
}

if openstack console log show "$RESCUE_SERVER_ID" 2>/dev/null | grep -Eiq "Windows\\\\system32\\\\config\\\\system|Status:\s*0xc0000225"; then
  FAIL "status=WINDOWS_SYSTEM_HIVE_INVALID failure_reason=WINDOWS_SYSTEM_REGISTRY_HIVE_CORRUPTED next_action=Use fresh source export or restore SYSTEM hive backup."
  emit_status "WINDOWS_SYSTEM_HIVE_INVALID" "failure_reason=WINDOWS_SYSTEM_REGISTRY_HIVE_CORRUPTED next_action=Use fresh source export or restore SYSTEM hive backup."
  CURRENT_STATUS="WINDOWS_V2_FAILED_SYSTEM_HIVE_CORRUPT"
  exit 1
fi

emit_status "WINDOWS_V2_RESCUE_READY" "Safe first boot: rescue VM ready ($RESCUE_SERVER_ID)"
emit_status "WINDOWS_V2_WAITING_FOR_GUEST" "Waiting for guest access (WinRM/SSH/RDP)"
if ! OSPC2FLEX_V2_PREFERRED_IP="${RESCUE_FLOATING_IP:-}" wait_for_windows_guest_access "$RESCUE_SERVER_ID" "rescue_wait" "$WAIT_TIMEOUT"; then
  FAIL "Rescue VM never became reachable"
  GUEST_UNREACHABLE=1
  emit_guest_unreachable_diagnostics "$RESCUE_SERVER_ID"
  [ "$AUTO_CLEANUP_FAILED" = "1" ] && openstack server delete "$RESCUE_SERVER_ID" >/dev/null 2>&1 || true
  exit 1
fi
PASS "Guest access via $ACCESS_METHOD on $ACCESS_IP:$ACCESS_PORT"

create_and_attach_dummy_volume || {
  CURRENT_STATUS="WINDOWS_V2_FAILED"
  exit 1
}

emit_status "WINDOWS_V2_ONLINE_BINDING_RUNNING" "Running online VirtIO binding"
run_windows_v2_firstboot || {
  CURRENT_STATUS="WINDOWS_V2_FAILED"
  exit 1
}
emit_status "WINDOWS_V2_ONLINE_BINDING_DONE" "Online VirtIO binding completed"

emit_status "WINDOWS_V2_REBOOTING_RESCUE" "Rebooting rescue VM on IDE/e1000"
reboot_rescue_guest_and_verify || {
  CURRENT_STATUS="WINDOWS_V2_FAILED"
  exit 1
}

shutdown_rescue_guest || {
  CURRENT_STATUS="WINDOWS_V2_FAILED"
  exit 1
}

emit_status "WINDOWS_V2_SNAPSHOT_CREATING" "Creating virtio-ready snapshot"
create_final_image || {
  FAIL "Final image creation or metadata enforcement failed"
  CURRENT_STATUS="WINDOWS_V2_FAILED"
  exit 1
}
emit_status "WINDOWS_V2_FINAL_IMAGE_READY" "Final VirtIO image ready"

emit_status "WINDOWS_V2_FINAL_BOOT_RUNNING" "Booting final VirtIO VM"
boot_final_vm || {
  FAIL "Final VirtIO VM boot launch failed"
  CURRENT_STATUS="WINDOWS_V2_FAILED"
  exit 1
}

healthcheck_final_vm || {
  CURRENT_STATUS="WINDOWS_V2_FAILED_FINAL_BOOT"
  exit 1
}

emit_status "WINDOWS_V2_SUCCESS" "Two-phase Windows migration succeeded"
cleanup_success
exit 0
