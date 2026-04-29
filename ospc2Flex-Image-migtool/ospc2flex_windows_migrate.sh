#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# ospc2flex_windows_migrate.sh — Windows VM Migration (SSH disk read + Glance fallback)
# ═══════════════════════════════════════════════════════════════════════════════
# Primary path  (Step 1b+2): WinRM → installs OpenSSH on Windows → SSH+PowerShell
#               reads PhysicalDrive0 directly to jumphost (same as Linux NBD flow).
# Fallback path (Step 2):    Glance snapshot → Cloud Files bridge → download.
#
# Usage:
#   bash ospc2flex_windows_migrate.sh \
#     --server-name "win2019websql2019" \
#     --server-ip "104.130.26.6" \
#     --label "ospc2flex-win2019" \
#     --windows-password "MyAdminPass" \
#     [--windows-user "Administrator"] \
#     [--flavor "gp.5.4.4"] [--network "tenant-net"] [--keypair "laptopubuntu24"]
#
# Requires: /tmp/ospc2flex_ospc.sh (OSPC creds) and /tmp/ospc2flex_flex.sh (FLEX creds)
#           /tmp/ospc2flex_windows_repair.sh (VirtIO driver injection script)
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
SERVER_NAME=""
SERVER_IP=""
LABEL=""
FLAVOR="gp.5.4.4"
NETWORK="tenant-net"
KEYPAIR="laptopubuntu24"
WORK="/mnt/migration/ospc2flex_image"
DATE_STR=$(date +%Y%m%d-%H%M)
LOG_FILE="/tmp/winmig_${LABEL}.log"
OSPC_CREDS="/tmp/ospc2flex_ospc.sh"
FLEX_CREDS="/tmp/ospc2flex_flex.sh"
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

# ── Color helpers ─────────────────────────────────────────────────────────────
# Log helpers write to STDERR (not stdout) so they never contaminate captured
# command substitutions like $(_resolve_glance_base) — previous bug was
# WARN inside that helper polluting $OS_IMAGE_URL with multi-line text +
# emoji, which curl then rejected with "URL rejected: Malformed input to a
# URL function" (curl exit 3).  The caller invokes this script with
# `... >log 2>&1` so stderr still lands in the SSE-streamed log file.
log()  { echo "[$(date '+%H:%M:%S')][$LABEL] $*" >&2; }
PASS() { echo "  ✅ $*" >&2; }
FAIL() { echo "  ❌ $*" >&2; }
WARN() { echo "  ⚠️  $*" >&2; }
INFO() { echo "  ℹ️  $*" >&2; }

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
  _STEP_STEPS_COMPLETED=$((num - 1))
  echo "" >&2
  echo "╔════════════════════════════════════════════════════════════════════════════╗" >&2
  printf "║ STEP %s: %-66s ║\n" "$num" "$name" >&2
  echo "╚════════════════════════════════════════════════════════════════════════════╝" >&2
  log "Step $num of 7 started: $name"
}

step_progress() {
  local msg="$1"
  local elapsed=$(($(date +%s) - _STEP_START_TIME))
  log "  [$((elapsed))s] $msg"
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
    --dry-run)          DRY_RUN=1; shift ;;
    -h|--help)
      echo "Usage: $0 --server-name <name> --server-ip <ip> --label <label> [--flavor <f>] [--network <n>] [--keypair <k>]"
      exit 0 ;;
    *) INFO "Ignoring unknown arg: $1"; shift 1 ;;
  esac
done

[ -z "$SERVER_NAME" ] && { echo "ERROR: --server-name required"; exit 1; }
[ -z "$LABEL" ] && LABEL="ospc2flex-$(echo "$SERVER_NAME" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')"



QCOW="$WORK/${LABEL}.qcow2"
LOG="/tmp/mig_${LABEL}.log"
exec > >(tee -a "$LOG") 2>&1

echo "═══════════════════════════════════════════════════════════════════════════"
echo " OSPC→FLEX Windows Migration Workflow"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""
echo "  Server    : $SERVER_NAME ($SERVER_IP)"
echo "  Label     : $LABEL"
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


# ═══════════════════════════════════════════════════════════════════════════════
# Step 1b: Check SSH first — skip snapshot entirely if SSH is reachable
# ═══════════════════════════════════════════════════════════════════════════════
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
    step_done "OK"
  else
    # Create snapshot via Nova createImage action
    step_progress "Creating snapshot $SNAP_NAME..."
    curl -s -X POST -H "X-Auth-Token: $OS_TOKEN" -H "Content-Type: application/json" \
      "$_NOVA_URL/servers/$SERVER_ID/action" \
      -d "{\"createImage\":{\"name\":\"$SNAP_NAME\",\"metadata\":{}}}" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin))" 2>/dev/null || true

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
    step_done "OK"
  fi

  if [ -z "$SNAP_ID" ]; then
    FAIL "Failed to create/find snapshot for '$SERVER_NAME'"
    step_done "FAILED"
    exit 1
  fi
fi  # end SSH_DISK_METHOD==0 block

# ═══════════════════════════════════════════════════════════════════════════════
# Step 1b (continued): WinRM bootstrap if SSH still not available
# ═══════════════════════════════════════════════════════════════════════════════
if [ "${SSH_DISK_METHOD:-0}" -eq 0 ] && [ -n "$WIN_PASSWORD" ]; then
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

    _WINRM_PY=$(mktemp /tmp/ospc2flex_winrm_XXXXXX.py)
    cat > "$_WINRM_PY" <<'WINRM_SCRIPT'
import sys, winrm

ip, port, scheme, user, password = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
pubkey = sys.argv[6] if len(sys.argv) > 6 else ""

# PowerShell heredoc — use @'...'@ (here-string) to avoid all escaping issues
PS_BOOTSTRAP = r"""
$ErrorActionPreference = 'Stop'
$pub = "PUBKEY_PLACEHOLDER"

# Install OpenSSH if missing (try built-in capability, then GitHub release from jumphost HTTP)
if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
    $cap = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction SilentlyContinue
    if ($cap -and $cap.State -eq 'NotPresent') {
        Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction SilentlyContinue
    }
}
if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
    # Fallback: download from jumphost HTTP server (ServiceNet)
    $jh = "JUMPHOST_SNET_IP"
    Invoke-WebRequest -Uri "http://${jh}:8080/OpenSSH-Win64.zip" -OutFile 'C:\Windows\Temp\OpenSSH-Win64.zip' -UseBasicParsing
    Expand-Archive -Path 'C:\Windows\Temp\OpenSSH-Win64.zip' -DestinationPath 'C:\Program Files\' -Force
    & 'C:\Program Files\OpenSSH-Win64\install-sshd.ps1'
    Write-Output "[WinRM] OpenSSH installed from jumphost"
}

# Start and persist sshd
$attempts = 0
while ($attempts -lt 6) {
    try { Start-Service sshd; Set-Service -Name sshd -StartupType Automatic; break }
    catch { $attempts++; Start-Sleep 5 }
}
Write-Output "[WinRM] sshd started"

# Firewall rule for port 22
if (-not (Get-NetFirewallRule -Name sshd -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH (ospc2flex)' `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    Write-Output "[WinRM] Firewall rule added"
}

# Set PowerShell as default SSH shell (with correct path)
$psExe = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
if (Test-Path $psExe) {
    if (-not (Test-Path 'HKLM:\SOFTWARE\OpenSSH')) { New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null }
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value $psExe
    Write-Output "[WinRM] Default shell = PowerShell"
}

# Write disk dump script (here-string avoids all escaping)
$dumpScript = @'
$drive = [IO.File]::OpenRead('\\.\PhysicalDrive0')
$stdout = [Console]::OpenStandardOutput()
$buf = New-Object byte[] 4194304
while (($n = $drive.Read($buf, 0, $buf.Length)) -gt 0) { $stdout.Write($buf, 0, $n) }
$drive.Close()
$stdout.Flush()
'@
Set-Content -Path 'C:\Windows\Temp\ospc2flex_diskdump.ps1' -Value $dumpScript -Encoding ascii
Write-Output "[WinRM] Disk dump script written"

# Install SSH authorized key in home dir with strict ACL
if ($pub -ne '') {
    $homeSSH = 'C:\Users\Administrator\.ssh'
    if (-not (Test-Path $homeSSH)) { New-Item -ItemType Directory -Path $homeSSH | Out-Null }
    Set-Content -Path "$homeSSH\authorized_keys" -Value $pub -Encoding ascii
    $fa = New-Object Security.AccessControl.FileSecurity
    $fa.SetAccessRuleProtection($true,$false)
    $fa.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule('NT AUTHORITY\SYSTEM','FullControl','None','None','Allow')))
    $fa.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule('BUILTIN\Administrators','FullControl','None','None','Allow')))
    Set-Acl "$homeSSH\authorized_keys" $fa
    Write-Output "[WinRM] Authorized key installed"
}
Write-Output "[WinRM] Bootstrap complete"
"""

try:
    s = winrm.Session(
        f"{scheme}://{ip}:{port}/wsman",
        auth=(user, password),
        transport="ntlm",
        server_cert_validation="ignore",
        read_timeout_sec=360,
        operation_timeout_sec=300,
    )
    import socket
    jh_snet = ""
    try:
        jh_snet = socket.gethostbyname(socket.gethostname())
    except Exception:
        pass
    ps = PS_BOOTSTRAP.replace("PUBKEY_PLACEHOLDER", pubkey).replace("JUMPHOST_SNET_IP", jh_snet)
    r = s.run_ps(ps)
    out = r.std_out.decode("utf-8", errors="replace").strip()
    err = r.std_err.decode("utf-8", errors="replace").strip()
    for line in out.splitlines(): print(line)
    if err and "CLIXML" not in err:
        for line in err.splitlines(): print(f"[STDERR] {line}", file=sys.stderr)
    if r.status_code != 0:
        print(f"[ERROR] WinRM PS exit {r.status_code}", file=sys.stderr); sys.exit(1)
    sys.exit(0)
except Exception as e:
    print(f"[ERROR] WinRM: {e}", file=sys.stderr); sys.exit(1)
WINRM_SCRIPT

    set +e
    python3 "$_WINRM_PY" "$_WINRM_IP" "$_WINRM_PORT" "$_WINRM_SCHEME" "$WIN_USER" "$WIN_PASSWORD" "$JH_PUBKEY"
    _WINRM_RC=$?
    set -e
    rm -f "$_WINRM_PY"

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
      [ "$_SSH_UP" -eq 1 ] && SSH_DISK_METHOD=1 \
        || WARN "SSH port 22 did not open within 120s — will use Glance fallback"
    else
      WARN "WinRM bootstrap failed (rc=$_WINRM_RC) — will use Glance fallback"
    fi
  fi
else
  WARN "SSH not available and --windows-password not provided — using Glance fallback only"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 2: Download Windows disk image
# ═══════════════════════════════════════════════════════════════════════════════
step_start "2" "Downloading Windows disk image (SSH or Glance fallback)"
mkdir -p "$WORK"
IMG_PATH="$WORK/${LABEL}.img"
rm -f "$IMG_PATH"
IMG_SIZE=0
DOWNLOAD_METHOD=""

if [ "${SSH_DISK_METHOD:-0}" -eq 1 ]; then
  step_progress "Using SSH direct disk read via PowerShell"
  INFO "Large Windows disks: 30–120+ minutes. Progress logged every 60s."
  # Use the SSH IP resolved in Step 1b (ServiceNet preferred when public port 22 is blocked)
  _SSH_TARGET="${WIN_USER}@${WIN_SSH_IP:-$SERVER_IP}"
  step_progress "SSH target: $_SSH_TARGET"

  WIN_DISK_BYTES=$(ssh -i ~/.ssh/id_rsa \
      -o StrictHostKeyChecking=no -o BatchMode=yes \
      -o LogLevel=ERROR -o ConnectTimeout=30 \
      "$_SSH_TARGET" \
      'powershell -NonInteractive -Command "(Get-Disk -Number 0).Size"' 2>/dev/null \
    | tr -d '[:space:]' || echo 0)
  INFO "PhysicalDrive0: $((WIN_DISK_BYTES / 1024 / 1024 / 1024)) GiB reported by Windows"

  # Heartbeat while SSH dd runs
  (while [ -f "/tmp/winmig_hb_active_${LABEL}" ]; do
     sleep 60
     _sz=$(stat -c%s "$IMG_PATH" 2>/dev/null || echo 0)
     step_progress "SSH transfer progress: $((${_sz} / 1024 / 1024)) MB on disk"
   done) &
  _HB_PID=$!
  : > "/tmp/winmig_hb_active_${LABEL}"

  set +e
  ssh -i ~/.ssh/id_rsa \
      -o StrictHostKeyChecking=no -o BatchMode=yes \
      -o LogLevel=ERROR \
      -o ServerAliveInterval=30 -o ServerAliveCountMax=20 \
      "$_SSH_TARGET" \
      'powershell -NonInteractive -File C:\Windows\Temp\ospc2flex_diskdump.ps1' \
  | dd of="$IMG_PATH" bs=4M iflag=fullblock 2>&1
  _SSH_RC=${PIPESTATUS[0]}
  set -e

  rm -f "/tmp/winmig_hb_active_${LABEL}"
  kill "$_HB_PID" 2>/dev/null || true

  IMG_SIZE=$(stat -c%s "$IMG_PATH" 2>/dev/null || echo 0)
  if [ "$_SSH_RC" -eq 0 ] && [ "${IMG_SIZE:-0}" -ge 1048576 ]; then
    PASS "Downloaded via SSH/PowerShell: $((IMG_SIZE / 1024 / 1024)) MB"
    DOWNLOAD_METHOD="ssh-powershell-disk-read"
    step_done "OK"
  else
    WARN "SSH disk read failed (rc=$_SSH_RC size=${IMG_SIZE}B) — falling back to Glance"
    rm -f "$IMG_PATH"
    IMG_SIZE=0
    step_progress "SSH failed, trying Glance fallback..."
  fi
fi

if [ "${IMG_SIZE:-0}" -lt 1048576 ]; then
  step_progress "Using Glance snapshot download (Cloud Files bridge / ServiceNet / public)"
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
  # Public (internet) Glance endpoint — subject to the WAF that has been
  # returning HTTP 413 on large image /file downloads from OSPC PubCloud.
  printf 'https://%s.images.api.rackspacecloud.com' "$(_region_short)"
}

_glance_snet_base() {
  # ServiceNet (10/8) Glance endpoint — bypasses the public WAF. Reachable
  # from any OSPC jumphost and is the correct path for bulk image downloads.
  printf 'https://snet-%s.images.api.rackspacecloud.com' "$(_region_short)"
}

_resolve_glance_base() {
  # Prefer the catalog's "internal" (ServiceNet) URL when present; fall back
  # to our predictable snet-<region> hostname; then public catalog URL; then
  # public predictable hostname. ServiceNet is strongly preferred because the
  # public endpoint's load-balancer returns HTTP 413 on image file GETs.
  local out u
  u=""
  if out=$(openstack catalog show image -f json 2>/dev/null); then
    u=$(OPENSTACK_JSON="$out" python3 - <<'PY' 2>/dev/null || true
import json, os
d = json.loads(os.environ["OPENSTACK_JSON"])
eps = d.get("endpoints") or []
for w in ("internal", "admin", "public"):
    for e in eps:
        if str(e.get("interface", "")).lower() == w and e.get("url"):
            print(str(e["url"]).rstrip("/"))
            raise SystemExit(0)
print("")
PY
)
  fi
  if [ -z "$u" ]; then
    u=$(openstack endpoint list --service image --interface internal -f value -c URL 2>/dev/null | head -1 | sed 's|/$||' || true)
  fi
  if [ -z "$u" ]; then
    u=$(openstack endpoint list --service image --interface public -f value -c URL 2>/dev/null | head -1 | sed 's|/$||' || true)
  fi
  if [ -z "$u" ]; then
    u=$(_glance_snet_base)
    WARN "Catalog/endpoints empty — ServiceNet fallback: $u (OS_REGION_NAME=$OS_REGION_NAME)"
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

OS_IMAGE_URL=$(_resolve_glance_base)
# Defensive: strip any stray whitespace / CR / log contamination so curl never
# sees a malformed URL (curl ≥7.85 rejects URLs with whitespace).
OS_IMAGE_URL=$(printf '%s' "$OS_IMAGE_URL" | tr -d '[:space:]')

# Build ordered list of Glance base URLs to try. ServiceNet first (bypasses
# the public WAF that returns HTTP 413 on image /file GETs), public last.
SNET_BASE=$(_glance_snet_base)
PUB_BASE=$(_glance_public_base)
PRECHECK_SNET_DNS_FAIL=0
# Dedup/order: catalog-resolved (if it differs from both), snet, public
GLANCE_BASES=""
for b in "$SNET_BASE" "$OS_IMAGE_URL" "$PUB_BASE"; do
  b=$(printf '%s' "$b" | tr -d '[:space:]')
  [ -z "$b" ] && continue
  _h=$(_url_host "$b")
  if ! _host_resolves "$_h"; then
    WARN "Glance host unresolved on jumphost: $_h (base=$b)"
    case "$_h" in
      snet-*.images.api.rackspacecloud.com)
        PRECHECK_SNET_DNS_FAIL=1
        ;;
      *)
        continue
        ;;
    esac
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
INFO "Catalog-resolved Glance GET: $DL_URL"

# Start a heartbeat watcher that monitors $IMG_PATH size while any download
# method is running. This replaces the per-method heartbeat loops.
_start_heartbeat() {
  (
    n=0
    while [ -f "/tmp/winmig_hb_active_${LABEL}" ]; do
      sleep 60
      n=$((n + 1))
      sz=$(stat -c%s "$IMG_PATH" 2>/dev/null || echo 0)
      log "  … download heartbeat #${n} — $((sz / 1024 / 1024)) MiB on disk (still running)"
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
  INFO "  → curl $url"
  : > "/tmp/winmig_hb_active_${LABEL}"
  _start_heartbeat
  set +e
  curl -fSL --connect-timeout 30 --retry 2 --retry-delay 10 \
    -H 'Expect:' \
    -H 'Accept: application/octet-stream' \
    -H "X-Auth-Token: $OS_TOKEN" \
    -A 'ospc2flex/1.0 (+jumphost-migrator)' \
    -o "$IMG_PATH" \
    --write-out "\\nHTTP_CODE=%{http_code} SIZE=%{size_download}B TIME=%{time_total}s\\n" \
    "$url" >"$log" 2>&1
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
    SAW_SNET_DNS_FAIL=1
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
  INFO "  → openstack image save $SNAP_ID (default endpoint)"
  : > "/tmp/winmig_hb_active_${LABEL}"
  _start_heartbeat
  set +e
  # Prefer plain image save first (most compatible across OpenStack clients).
  openstack image save --file "$IMG_PATH" "$SNAP_ID" >"$log" 2>&1
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    INFO "  default endpoint failed; retrying with OS_IMAGE_URL=$base"
    OS_IMAGE_URL="$base" openstack image save --file "$IMG_PATH" "$SNAP_ID" >"$log" 2>&1
    rc=$?
  fi
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
        SAW_SNET_DNS_FAIL=1
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
    WARN "Glance bridge failed (rc=$BRIDGE_RC); attempting legacy ServiceNet/public waterfall as last resort"
    rm -f "$IMG_PATH"
    IMG_SIZE=0
  fi
fi

attempt=1
max_dl=5
SAW_SNET_DNS_FAIL=0
SAW_PUBLIC_413=0
if [ "${IMG_SIZE:-0}" -lt 1048576 ]; then
while [ "$attempt" -le "$max_dl" ]; do
  if [ "${PRECHECK_SNET_DNS_FAIL:-0}" -eq 1 ]; then
    SAW_SNET_DNS_FAIL=1
  fi
  if _try_download_methods "$attempt"; then
    IMG_SIZE=$(stat -c%s "$IMG_PATH" 2>/dev/null || echo 0)
    break
  fi
  if [ "$SAW_SNET_DNS_FAIL" -eq 1 ] && [ "$SAW_PUBLIC_413" -eq 1 ]; then
    WARN "All Glance paths exhausted: ServiceNet DNS unresolvable + public endpoint returning HTTP 413."
    WARN "Cloud Files bridge also failed (see above). No further Glance retries will succeed — stopping waterfall."
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
step_done "OK"

# ═══════════════════════════════════════════════════════════════════════════════
# Step 3: Convert to qcow2
# ═══════════════════════════════════════════════════════════════════════════════
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
  qemu-img convert -p -f "$DETECTED_FMT" -O qcow2 "$IMG_PATH" "$QCOW" 2>&1 || { FAIL "qemu-img convert failed"; step_done "FAILED"; exit 1; }
  rm -f "$IMG_PATH"
  PASS "Converted to qcow2"
fi
QCOW_SIZE=$(stat -c%s "$QCOW" 2>/dev/null || echo 0)
INFO "qcow2 size: $((QCOW_SIZE/1024/1024))MB"
step_done "OK"

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
    bash "$WIN_REPAIR" --qcow2 "$QCOW" --force 2>&1
    REPAIR_EXIT=$?
    set -e
    if [ "$REPAIR_EXIT" -eq 0 ]; then
      PASS "Windows repair completed successfully"
      step_done "OK"
    else
      WARN "Windows repair exited with code $REPAIR_EXIT — continuing anyway"
      step_done "DONE (with warnings)"
    fi
  else
    WARN "$WIN_REPAIR not found — skipping VirtIO injection"
    WARN "Windows VM may not boot without VirtIO drivers!"
    step_done "SKIPPED"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 5: Upload to FLEX
# ═══════════════════════════════════════════════════════════════════════════════
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
  local _src_vcpu _src_ram _src_disk _need_disk
  _src_vcpu=$(normalize_int "${MIG_SRC_VCPUS:-}")
  _src_ram=$(normalize_int "${MIG_SRC_RAM_MB:-}")
  _src_disk=$(normalize_int "${MIG_SRC_DISK_GB:-}")
  _need_disk="$_src_disk"
  [ -z "$_need_disk" ] && _need_disk=$(normalize_int "${QCOW_VIRTUAL_GIB:-}")

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
  if [ -n "$_src_vcpu" ] && [ -n "$_src_ram" ]; then
    _best=$(printf '%s\n' "$_rows" | awk -v sv="$_src_vcpu" -v sr="$_src_ram" '
      NF>=5 {
        id=$1; name=$2; ram=$3+0; disk=$4+0; vcpu=$5+0
        if (vcpu>=sv && ram>=sr) {
          score=((vcpu-sv)*1000000000)+((ram-sr)*1000000)+disk
          if (!seen || score < best) { seen=1; best=score; out=id"|"name"|"ram"|"disk"|"vcpu }
        }
      }
      END { if (seen) print out }
    ')
  fi

  _chosen="${_best:-$_fallback}"
  _cid=$(echo "$_chosen" | cut -d'|' -f1)
  _cname=$(echo "$_chosen" | cut -d'|' -f2)
  _cram=$(echo "$_chosen" | cut -d'|' -f3)
  _cdisk=$(echo "$_chosen" | cut -d'|' -f4)
  _cvcpu=$(echo "$_chosen" | cut -d'|' -f5)
  if [ -n "$_cid" ]; then
    INFO "Flavor auto-pick: $_cid name=${_cname:-?} vcpu=${_cvcpu:-?} ram=${_cram:-?} disk=${_cdisk:-?} src=${_src_vcpu:-?}/${_src_ram:-?}/${_src_disk:-?} req_disk=${_need_disk:-?}" >&2
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
IMG_DISK_BUS="virtio"
IMG_VIF_MODEL="virtio"
IMG_QGA="yes"
step_progress "Uploading: $QCOW_BYTES bytes (${QCOW_MIB} MiB) to FLEX Glance..."
INFO "FLEX image metadata: architecture=$IMG_ARCH vm_mode=$IMG_VM_MODE os_type=$IMG_OS_TYPE os_distro=$IMG_OS_DISTRO hw_disk_bus=$IMG_DISK_BUS hw_vif_model=$IMG_VIF_MODEL hw_qemu_guest_agent=$IMG_QGA"

FLEX_IMG_ID=$(openstack image create "$LABEL" \
  --disk-format qcow2 \
  --container-format bare \
  --file "$QCOW" \
  --private \
  --property "architecture=$IMG_ARCH" \
  --property "vm_mode=$IMG_VM_MODE" \
  --property "os_type=$IMG_OS_TYPE" \
  --property "os_distro=$IMG_OS_DISTRO" \
  --property "hw_disk_bus=$IMG_DISK_BUS" \
  --property "hw_vif_model=$IMG_VIF_MODEL" \
  --property "hw_qemu_guest_agent=$IMG_QGA" \
  --format value -c id 2>/dev/null || true)

if [ -z "$FLEX_IMG_ID" ]; then
  FAIL "Image upload failed"
  step_done "FAILED"
  exit 1
fi

# Wait for image to become active
step_progress "Waiting for image to become active in Glance..."
for i in $(seq 1 30); do
  STATUS=$(openstack image show "$FLEX_IMG_ID" -f value -c status 2>/dev/null || echo "unknown")
  [ "$STATUS" = "active" ] && break
  step_progress "  Image status: $STATUS (attempt $i/30)"
  sleep 5
done
PASS "Image uploaded: $FLEX_IMG_ID (status: $STATUS)"
SHOW_NAME=$(openstack image show "$FLEX_IMG_ID" -f value -c name 2>/dev/null || echo "$LABEL")
SHOW_VIS=$(openstack image show "$FLEX_IMG_ID" -f value -c visibility 2>/dev/null || echo "unknown")
SHOW_STAT=$(openstack image show "$FLEX_IMG_ID" -f value -c status 2>/dev/null || echo "${STATUS:-unknown}")
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
OLD_VIDS=$(openstack server list -f value -c ID -c Name 2>/dev/null | grep -F "$LABEL" | awk '{print $1}' || true)
if [ -n "$OLD_VIDS" ]; then
  INFO "Old VMs found: $OLD_VIDS (Skipping deletion as per user request)"
fi

if [ -n "$KEYPAIR" ]; then
  openstack server create "$LABEL" \
    --image "$FLEX_IMG_ID" \
    --flavor "$FLAVOR" \
    --network "$NETWORK" \
    --key-name "$KEYPAIR" \
    --wait 2>&1
else
  openstack server create "$LABEL" \
    --image "$FLEX_IMG_ID" \
    --flavor "$FLAVOR" \
    --network "$NETWORK" \
    --wait 2>&1
fi

sleep 10

# Get VM status
VM_ID=$(openstack server list -f value -c ID -c Name 2>/dev/null | grep -F "$LABEL" | head -1 | awk '{print $1}' || true)
VM_STATUS=$(openstack server show "$VM_ID" -f value -c status 2>/dev/null || echo "unknown")

if [ "$VM_STATUS" = "ACTIVE" ]; then
  PASS "VM booted: $VM_ID (ACTIVE)"
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
PORT_ID=$(openstack port list --server "$VM_ID" -f value -c ID -c Status 2>/dev/null | awk '$2=="ACTIVE"{print $1; exit}')
[ -z "$PORT_ID" ] && PORT_ID=$(openstack port list --server "$VM_ID" -f value -c ID 2>/dev/null | head -1 || true)
if [ -z "$PORT_ID" ]; then
  WARN "No server port found; skipping FIP attach"
  step_done "SKIPPED"
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
echo "║                     MIGRATION WORKFLOW COMPLETE                            ║"
echo "╚════════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Server:       $LABEL"
echo "  Image ID:     $FLEX_IMG_ID"
echo "  VM ID:        $VM_ID ($VM_STATUS)"
echo "  Floating IP:  ${ACTUAL_FIP:-not assigned}"
echo "  RDP Connect:  mstsc /v:${ACTUAL_FIP:-unknown}"
echo "  Download:     ${DOWNLOAD_METHOD:-unknown} (Step 2)"
echo ""
echo "═══════════════════════════════════════════════════════════════════════════"

# Cleanup OSPC snapshot
log "Cleaning up OSPC snapshot $SNAP_NAME..."
source /tmp/ospc2flex_ospc.sh
if [ -n "${OSPC_TOKEN:-}" ]; then
  export OS_TOKEN="$OSPC_TOKEN"
  export OS_AUTH_TYPE=token
  export OS_IDENTITY_API_VERSION=2
fi
openstack image delete "$SNAP_ID" 2>/dev/null || true
PASS "OSPC snapshot deleted"
