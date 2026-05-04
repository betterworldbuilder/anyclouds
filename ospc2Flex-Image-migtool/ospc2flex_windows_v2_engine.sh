#!/usr/bin/env bash
# Two-phase Windows rescue workflow: IDE rescue boot first, then in-guest
# VirtIO binding, then final VirtIO/SCSI image + boot test.
set -euo pipefail

ORIG_ARGS=("$@")

SERVER_NAME=""
SERVER_IP=""
LABEL=""
FLAVOR="gp.5.4.4"
NETWORK="tenant-net"
KEYPAIR="laptopubuntu24"
WORK="${WORK:-/mnt/migration/ospc2flex_image}"
WIN_USER="Administrator"
WIN_PASSWORD=""
WIN_SNET_IP=""
DRY_RUN=0
OS_FAMILY="windows"
OS_TYPE="windows"

WINDOWS_MODE="${OSPC2FLEX_WINDOWS_MODE:-two_phase_virtio}"
AUTO_CLEANUP_FAILED="${OSPC2FLEX_AUTO_CLEANUP_FAILED:-0}"
KEEP_ARTIFACTS="${OSPC2FLEX_KEEP_ARTIFACTS:-1}"
ALLOW_UNREPAIRED_UPLOAD="${OSPC2FLEX_ALLOW_UNREPAIRED_WINDOWS_UPLOAD:-0}"
STRICT_DUMMY_ATTACH="${OSPC2FLEX_WINDOWS_V2_STRICT_DUMMY_ATTACH:-0}"
WAIT_TIMEOUT="${OSPC2FLEX_WINDOWS_V2_WAIT_SEC:-2700}"
HEALTHCHECK_WAIT="${OSPC2FLEX_WINDOWS_V2_HEALTHCHECK_WAIT_SEC:-1200}"
FLEX_EXT_NET="${OSPC2FLEX_FLEX_EXT_NET:-PUBLICNET}"
METHOD_A="/tmp/ospc2flex_windows_migrate.sh"
FLEX_CREDS="/tmp/ospc2flex_flex.sh"
FIRSTBOOT_PS1_WIN='C:\ospc2flex\ospc2flex_windows_firstboot.ps1'
VERIFY_PS1_WIN='C:\ospc2flex\ospc2flex_windows_v2_verify.ps1'

RESCUE_SERVER_NAME=""
RESCUE_IMAGE_NAME=""
FINAL_IMAGE_NAME=""
FINAL_SERVER_NAME=""
RESCUE_JSON=""
RESULT_JSON=""
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
  STATUS_LOG+=("$CURRENT_STATUS${msg:+ :: $msg}")
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════════"
  echo " $CURRENT_STATUS"
  [ -n "$msg" ] && echo " $msg"
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
  for c in openstack python3 nc ssh sshpass scp; do
    command -v "$c" >/dev/null 2>&1 || { FAIL "Missing required command after install attempt: $c"; exit 1; }
  done
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
    --os-family) OS_FAMILY="$2"; shift 2 ;;
    --os-type) OS_TYPE="$2"; shift 2 ;;
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
ensure_runtime_deps

RESCUE_SERVER_NAME="${LABEL}-ide-rescue"
RESCUE_IMAGE_NAME="${LABEL}-ide-rescue-img"
FINAL_IMAGE_NAME="${LABEL}-virtio-final-img"
FINAL_SERVER_NAME="${LABEL}-virtio-final"
RESCUE_JSON="$WORK/${LABEL}.windows_v2_rescue.json"
RESULT_JSON="$WORK/${LABEL}.windows_v2_result.json"
REPAIR_SENTINEL="$WORK/${LABEL}.qcow2.win_repaired"

save_console_log() {
  local server_id="$1" out="$2"
  openstack console log show "$server_id" >"$out" 2>&1 || true
}

write_result_json() {
  python3 - "$RESULT_JSON" "$LABEL" "$SERVER_IP" "$WINDOWS_MODE" "$RESCUE_IMAGE_ID" "$RESCUE_SERVER_ID" "$DUMMY_VOLUME_ID" "$FINAL_IMAGE_ID" "$FINAL_SERVER_ID" "$CURRENT_STATUS" "$DRIVER_INSTALL_VERIFIED" "$DUMMY_DETECTED" "$FINAL_BOOT_VERIFIED" "$(printf '%s\n' "${STATUS_LOG[@]}")" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
payload = {
  "label": sys.argv[2],
  "source": sys.argv[3],
  "mode": sys.argv[4],
  "rescue_image_id": sys.argv[5],
  "rescue_server_id": sys.argv[6],
  "dummy_volume_id": sys.argv[7],
  "final_image_id": sys.argv[8],
  "final_server_id": sys.argv[9],
  "status": sys.argv[10],
  "driver_install_verified": sys.argv[11].lower() == "true",
  "dummy_volume_detected": sys.argv[12].lower() == "true",
  "final_boot_verified": sys.argv[13].lower() == "true",
  "logs": [line for line in sys.argv[14].splitlines() if line.strip()],
}
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
}

trap 'write_result_json' EXIT

wait_for_server_status() {
  local server_id="$1" target="$2" timeout="$3" waited=0
  while [ "$waited" -lt "$timeout" ]; do
    local status
    status=$(openstack server show "$server_id" -f value -c status 2>/dev/null || echo "UNKNOWN")
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
  printf '%s\n' "$raw" | python3 - "$prefer" <<'PY'
import sys

prefer = (sys.argv[1] or "").strip()
ips_in = [ln.strip() for ln in sys.stdin if ln.strip()]
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
    status=$(openstack server show "$server_id" -f value -c status 2>/dev/null || echo "UNKNOWN")
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
Path(sys.argv[1]).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
  return 1
}

create_and_attach_dummy_volume() {
  emit_status "WINDOWS_V2_DUMMY_VOLUME_CREATE" "Creating best-effort dummy volume"
  DUMMY_VOLUME_NAME="${RESCUE_SERVER_NAME}-dummy-virtio"
  DUMMY_VOLUME_ID=$(openstack volume create --size 5 "$DUMMY_VOLUME_NAME" -f value -c id 2>/dev/null || true)
  if [ -z "$DUMMY_VOLUME_ID" ]; then
    WARN "Dummy volume create failed; continuing"
    return 0
  fi
  local waited=0
  while [ "$waited" -lt 300 ]; do
    local vol_status
    vol_status=$(openstack volume show "$DUMMY_VOLUME_ID" -f value -c status 2>/dev/null || echo "unknown")
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
  emit_status "WINDOWS_V2_DRIVER_INSTALL" "Running in-guest pnputil bootstrap"
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
  emit_status "WINDOWS_V2_FINAL_IMAGE_CREATE" "Snapshotting rescue VM into final image"
  local image_id
  image_id=$(openstack server image create "$RESCUE_SERVER_ID" --name "$FINAL_IMAGE_NAME" -f value -c id 2>/dev/null || true)
  if [ -z "$image_id" ]; then
    image_id=$(openstack image list --name "$FINAL_IMAGE_NAME" -f value -c ID 2>/dev/null | head -1 || true)
  fi
  [ -n "$image_id" ] || return 1
  FINAL_IMAGE_ID="$image_id"
  local waited=0
  while [ "$waited" -lt 1800 ]; do
    local status
    status=$(openstack image show "$FINAL_IMAGE_ID" -f value -c status 2>/dev/null || echo "unknown")
    [ "$status" = "active" ] && break
    sleep 10
    waited=$((waited + 10))
  done
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

boot_final_vm() {
  emit_status "WINDOWS_V2_FINAL_VIRTIO_BOOT" "Booting final VirtIO/SCSI VM"
  local create_args=(server create "$FINAL_SERVER_NAME" --image "$FINAL_IMAGE_ID" --flavor "$FLAVOR" --network "$NETWORK" --wait -f value -c id)
  if [ -n "$KEYPAIR" ]; then
    create_args+=(--key-name "$KEYPAIR")
  fi
  FINAL_SERVER_ID=$(openstack "${create_args[@]}" 2>/dev/null || true)
  [ -n "$FINAL_SERVER_ID" ] || FINAL_SERVER_ID=$(openstack server list --name "$FINAL_SERVER_NAME" -f value -c ID 2>/dev/null | head -1 || true)
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
echo " OSPC→FLEX Windows Two-Phase VirtIO Binding Engine"
echo "═══════════════════════════════════════════════════════════════════════════"
echo "  Server    : $SERVER_NAME ($SERVER_IP)"
echo "  Label     : $LABEL"
echo "  Mode      : $WINDOWS_MODE"
echo "  Flavor    : $FLAVOR"
echo "  Network   : $NETWORK"
echo "  Keypair   : ${KEYPAIR:-<none>}"
echo "═══════════════════════════════════════════════════════════════════════════"

if [ "$WINDOWS_MODE" = "offline_only" ]; then
  INFO "Windows mode requests Method A/offline-only; delegating to current workflow"
  exec "$METHOD_A" "${ORIG_ARGS[@]}"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  emit_status "WINDOWS_V2_PREFLIGHT" "Dry-run preflight"
  env OSPC2FLEX_WINDOWS_MODE=two_phase_virtio \
      OSPC2FLEX_WIN_DISK_BUS=ide \
      OSPC2FLEX_SKIP_BOOT_VALIDATOR=1 \
      OSPC2FLEX_CLOUD_LABEL="$RESCUE_SERVER_NAME" \
      OSPC2FLEX_WINDOWS_OUTPUT_JSON="$RESCUE_JSON" \
      "$METHOD_A" "${ORIG_ARGS[@]}" --dry-run
  emit_status "WINDOWS_V2_DRYRUN_COMPLETE" "Dry-run finished before rescue upload/boot follow-through"
  exit 0
fi

if [ ! -x "$METHOD_A" ]; then
  FAIL "Method A helper missing on jumphost: $METHOD_A"
  exit 1
fi

emit_status "WINDOWS_V2_PREFLIGHT" "Running Method A capture + IDE rescue flow"
env OSPC2FLEX_WINDOWS_MODE=two_phase_virtio \
    OSPC2FLEX_WIN_DISK_BUS=ide \
    OSPC2FLEX_SKIP_BOOT_VALIDATOR=1 \
    OSPC2FLEX_CLOUD_LABEL="$RESCUE_SERVER_NAME" \
    OSPC2FLEX_WINDOWS_OUTPUT_JSON="$RESCUE_JSON" \
    "$METHOD_A" "${ORIG_ARGS[@]}"

load_flex_creds || exit 1

if [ ! -f "$REPAIR_SENTINEL" ] && [ "$ALLOW_UNREPAIRED_UPLOAD" != "1" ]; then
  FAIL "Offline repair sentinel missing: $REPAIR_SENTINEL"
  exit 1
fi

if [ ! -f "$RESCUE_JSON" ]; then
  FAIL "Rescue metadata JSON missing: $RESCUE_JSON"
  exit 1
fi

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

emit_status "WINDOWS_V2_IDE_RESCUE_BOOT" "Rescue VM ready: $RESCUE_SERVER_ID"
emit_status "WINDOWS_V2_WAITING_FOR_GUEST" "Waiting for guest access (WinRM/SSH/RDP)"
if ! OSPC2FLEX_V2_PREFERRED_IP="${RESCUE_FLOATING_IP:-}" wait_for_windows_guest_access "$RESCUE_SERVER_ID" "rescue_wait" "$WAIT_TIMEOUT"; then
  FAIL "Rescue VM never became reachable"
  CURRENT_STATUS="WINDOWS_V2_FAILED"
  [ "$AUTO_CLEANUP_FAILED" = "1" ] && openstack server delete "$RESCUE_SERVER_ID" >/dev/null 2>&1 || true
  exit 1
fi
PASS "Guest access via $ACCESS_METHOD on $ACCESS_IP:$ACCESS_PORT"

create_and_attach_dummy_volume || {
  CURRENT_STATUS="WINDOWS_V2_FAILED"
  exit 1
}

run_windows_v2_firstboot || {
  CURRENT_STATUS="WINDOWS_V2_FAILED"
  exit 1
}

shutdown_rescue_guest || {
  CURRENT_STATUS="WINDOWS_V2_FAILED"
  exit 1
}

create_final_image || {
  FAIL "Final image creation or metadata enforcement failed"
  CURRENT_STATUS="WINDOWS_V2_FAILED"
  exit 1
}

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
