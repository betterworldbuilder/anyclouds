#!/usr/bin/env bash
set -euo pipefail

HOST=""
USER="Administrator"
PASS_ENV="WIN_PASS_PRIMARY"
FALLBACK_PASS_ENV="WIN_PASS_FALLBACK"
OUT_DIR="${OUT_DIR:-/tmp/ospc2flex_boot_scan}"
TIMEOUT="${TIMEOUT:-6}"

usage() {
  cat <<'EOF'
Usage:
  WIN_PASS_PRIMARY='...' [WIN_PASS_FALLBACK='...'] ./windows-boot-scan.sh --host <ip> [--user Administrator]

This is a read-only Windows boot scanner. It uses WinRM only; it does not install SSH,
change firewall rules, write registry keys, or modify the VM.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host|--server-ip|--ip) HOST="$2"; shift 2 ;;
    --user|--windows-user) USER="$2"; shift 2 ;;
    --password-env) PASS_ENV="$2"; shift 2 ;;
    --fallback-password-env) FALLBACK_PASS_ENV="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$HOST" ] || { echo "ERROR: --host is required" >&2; exit 2; }

mkdir -p "$OUT_DIR"
REPORT="$OUT_DIR/windows_boot_scan_${HOST}_$(date +%Y%m%d-%H%M%S).txt"

echo "============================================================" | tee "$REPORT"
echo "OSPC2FLEX Windows Boot Scan" | tee -a "$REPORT"
echo "Target : $HOST" | tee -a "$REPORT"
echo "User   : $USER" | tee -a "$REPORT"
echo "Report : $REPORT" | tee -a "$REPORT"
echo "============================================================" | tee -a "$REPORT"

probe_port() {
  local port="$1"
  nc -z -w "$TIMEOUT" "$HOST" "$port" >/dev/null 2>&1
}

WINRM_PORT=""
WINRM_SCHEME="http"
if probe_port 5985; then
  WINRM_PORT="5985"
  WINRM_SCHEME="http"
elif probe_port 5986; then
  WINRM_PORT="5986"
  WINRM_SCHEME="https"
fi

if [ -z "$WINRM_PORT" ]; then
  echo "" | tee -a "$REPORT"
  echo "WinRM: CLOSED (5985/5986 not reachable)" | tee -a "$REPORT"
  if probe_port 3389; then
    echo "RDP  : OPEN (3389 reachable)" | tee -a "$REPORT"
  else
    echo "RDP  : CLOSED/TIMEOUT (3389 not reachable)" | tee -a "$REPORT"
  fi
  if probe_port 22; then
    echo "SSH  : OPEN (22 reachable)" | tee -a "$REPORT"
  else
    echo "SSH  : CLOSED/TIMEOUT (22 not reachable)" | tee -a "$REPORT"
  fi
  echo "" | tee -a "$REPORT"
  echo "No guest scan was run because WinRM is closed from this host." | tee -a "$REPORT"
  echo "Enable WinRM inside Windows or run this from a network path that can reach 5985/5986." | tee -a "$REPORT"
  exit 3
fi

echo "" | tee -a "$REPORT"
echo "WinRM: OPEN ($WINRM_SCHEME://$HOST:$WINRM_PORT/wsman)" | tee -a "$REPORT"

python3 -c "import winrm" >/dev/null 2>&1 || {
  echo "pywinrm missing. Install with: python3 -m pip install pywinrm requests_ntlm" | tee -a "$REPORT"
  exit 4
}

export BOOTSCAN_HOST="$HOST"
export BOOTSCAN_USER="$USER"
export BOOTSCAN_PORT="$WINRM_PORT"
export BOOTSCAN_SCHEME="$WINRM_SCHEME"
export BOOTSCAN_PASS_PRIMARY="${!PASS_ENV:-}"
export BOOTSCAN_PASS_FALLBACK="${!FALLBACK_PASS_ENV:-}"

python3 <<'PY' | tee -a "$REPORT"
import os
import sys
import winrm

host = os.environ["BOOTSCAN_HOST"]
user = os.environ["BOOTSCAN_USER"]
port = os.environ["BOOTSCAN_PORT"]
scheme = os.environ["BOOTSCAN_SCHEME"]
passwords = [
    ("primary", os.environ.get("BOOTSCAN_PASS_PRIMARY", "")),
    ("fallback", os.environ.get("BOOTSCAN_PASS_FALLBACK", "")),
]

ps = r'''
$ErrorActionPreference = 'Continue'

function Section($name) {
  Write-Output ""
  Write-Output "===== $name ====="
}

Section "Computer"
Get-CimInstance Win32_OperatingSystem |
  Select-Object Caption,Version,BuildNumber,OSArchitecture,LastBootUpTime |
  Format-List | Out-String -Width 240

Section "Boot Configuration"
bcdedit /enum all

Section "Disk Layout"
Get-Disk | Select-Object Number,FriendlyName,SerialNumber,BusType,PartitionStyle,OperationalStatus,Size,IsBoot,IsSystem |
  Format-Table -AutoSize | Out-String -Width 240

Section "Partitions"
Get-Partition | Select-Object DiskNumber,PartitionNumber,DriveLetter,Type,Size,Offset,IsActive,IsBoot,IsSystem |
  Format-Table -AutoSize | Out-String -Width 240

Section "Volumes"
Get-Volume | Select-Object DriveLetter,FileSystemLabel,FileSystemType,HealthStatus,Size,SizeRemaining |
  Format-Table -AutoSize | Out-String -Width 240

Section "VirtIO/Xen Services"
$svcNames = 'viostor','vioscsi','netkvm','vioser','balloon','xenvbd','xennet','xenvif','xenbus','xeniface','disk','volmgr','volsnap','partmgr','mountmgr'
foreach ($n in $svcNames) {
  $svcPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$n"
  $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
  $reg = Get-ItemProperty -Path $svcPath -ErrorAction SilentlyContinue
  [PSCustomObject]@{
    Name = $n
    Exists = [bool]$reg
    ServiceStatus = if ($svc) { $svc.Status } else { '' }
    Start = if ($reg) { $reg.Start } else { '' }
    Group = if ($reg) { $reg.Group } else { '' }
    ImagePath = if ($reg) { $reg.ImagePath } else { '' }
  }
} | Format-Table -AutoSize | Out-String -Width 260

Section "CriticalDeviceDatabase VirtIO"
$cdd = @(
 'pci#ven_1af4&dev_1000',
 'pci#ven_1af4&dev_1041',
 'pci#ven_1af4&dev_1001',
 'pci#ven_1af4&dev_1042',
 'pci#ven_1af4&dev_1004',
 'pci#ven_1af4&dev_1048'
)
foreach ($id in $cdd) {
  $p = "HKLM:\SYSTEM\CurrentControlSet\Control\CriticalDeviceDatabase\$id"
  $r = Get-ItemProperty -Path $p -ErrorAction SilentlyContinue
  [PSCustomObject]@{
    Device = $id
    Exists = [bool]$r
    Service = if ($r) { $r.Service } else { '' }
    ClassGUID = if ($r) { $r.ClassGUID } else { '' }
  }
} | Format-Table -AutoSize | Out-String -Width 240

Section "MountedDevices"
Get-ItemProperty -Path 'HKLM:\SYSTEM\MountedDevices' -ErrorAction SilentlyContinue |
  Format-List | Out-String -Width 240

Section "Boot Repair Signals"
reagentc /info
'''

last_error = ""
for label, password in passwords:
    if not password:
        continue
    try:
        session = winrm.Session(
            f"{scheme}://{host}:{port}/wsman",
            auth=(user, password),
            transport="ntlm",
            server_cert_validation="ignore",
            read_timeout_sec=180,
            operation_timeout_sec=120,
        )
        result = session.run_ps(ps)
        out = result.std_out.decode("utf-8", errors="replace")
        err = result.std_err.decode("utf-8", errors="replace")
        if result.status_code == 0:
            print(f"Authentication: {label} password succeeded")
            print(out)
            if err.strip():
                print("===== STDERR =====")
                print(err)
            sys.exit(0)
        last_error = f"{label} password failed with status {result.status_code}: {err.strip()[:500]}"
    except Exception as exc:
        last_error = f"{label} password failed: {exc}"

print(f"Authentication failed. {last_error}", file=sys.stderr)
sys.exit(5)
PY

rc=${PIPESTATUS[0]}
if [ "$rc" -eq 0 ]; then
  echo "" | tee -a "$REPORT"
  echo "Boot scan complete: $REPORT" | tee -a "$REPORT"
else
  echo "" | tee -a "$REPORT"
  echo "Boot scan failed with code $rc: $REPORT" | tee -a "$REPORT"
fi
exit "$rc"
