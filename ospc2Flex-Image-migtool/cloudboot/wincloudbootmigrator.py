#!/usr/bin/env python3
"""
wincloudbootmigrator.py

Linux-side Windows cloud boot migration helper.

Purpose:
  - Read boot/runtime configuration from an existing source Windows server.
  - Read boot/runtime configuration from an existing target-cloud Windows server.
  - Compare source vs target.
  - Generate a target-compatible Windows repair bundle:
      * firstboot PowerShell script
      * offline registry .reg patch
      * repair plan JSON
      * human-readable markdown report

Example:
  OSPC Windows Server 2016 Xen -> Flex Windows Server 2016 KVM/OpenStack Nova

Transport:
  Uses SSH to run PowerShell on Windows hosts.
  If SSH is unavailable and a Windows password is supplied, it can bootstrap
  OpenSSH Server over WinRM (5985/5986), then retry SSH collection.
"""

from __future__ import annotations

import argparse
import base64
import dataclasses
import shlex
import datetime as dt
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

# Logged at startup and on SSH errors — confirms the runner picked up this file (not a stale copy elsewhere).
_TRANSPORT_REV = "proxycommand-v6-fullmig-stage1"
SSH_CONNECT_TIMEOUT = 45
SSH_PREFLIGHT_TIMEOUT = 75
SSH_PROBE_TIMEOUT = 75
BASTION_TCP_PROBE_TIMEOUT = 60
WINRM_BOOTSTRAP_TIMEOUT = 420


BOOT_CRITICAL_DRIVERS = [
    "viostor", "vioscsi", "storahci", "pciide", "intelide",
    "disk", "partmgr", "mountmgr", "volmgr", "volsnap",
]

FLEX_RUNTIME_DRIVERS = [
    "netkvm", "Balloon", "vioser", "VirtioSerial", "viorng",
    "VirtRng", "qemufwcfg", "FwCfg", "VioGpuDod", "qxldod",
]

FLEX_RUNTIME_SERVICES = [
    "QEMU-GA", "BalloonService", "Dhcp", "Dnscache", "NlaSvc",
    "netprofm", "nsi", "MpsSvc", "TermService", "UmRdpService", "WinRM",
]


COLLECT_PS1 = r"""
$ErrorActionPreference = "SilentlyContinue"

function Get-DriverInfo {
    Get-CimInstance Win32_SystemDriver |
      Select-Object Name, DisplayName, State, Status, Started, StartMode, PathName |
      Sort-Object Name
}

function Get-ServiceInfo {
    Get-Service |
      Select-Object Name, DisplayName, Status, StartType |
      Sort-Object Name
}

function Get-DiskInfoSafe {
    try {
        Get-Disk |
          Select-Object Number, FriendlyName, SerialNumber, HealthStatus, OperationalStatus, TotalSize, PartitionStyle, BusType, IsBoot, IsSystem, IsOffline |
          Sort-Object Number
    } catch {
        @()
    }
}

function Get-NetInfoSafe {
    try {
        Get-NetAdapter |
          Select-Object Name, InterfaceDescription, ifIndex, Status, MacAddress, LinkSpeed |
          Sort-Object ifIndex
    } catch {
        @()
    }
}

function Get-RegValueSafe($Path, $Name) {
    try {
        $v = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        if ($null -ne $v) { return $v.$Name }
    } catch {}
    return $null
}

function Get-ServiceReg($svc) {
    $p = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
    [PSCustomObject]@{
        Name = $svc
        Start = Get-RegValueSafe $p "Start"
        Type = Get-RegValueSafe $p "Type"
        Group = Get-RegValueSafe $p "Group"
        ImagePath = Get-RegValueSafe $p "ImagePath"
        ErrorControl = Get-RegValueSafe $p "ErrorControl"
    }
}

$bcdText = ""
try {
    $bcdText = (bcdedit /enum all) -join "`n"
} catch {
    $bcdText = "BCD_READ_FAILED: $($_.Exception.Message)"
}

$computer = Get-ComputerInfo

$serviceRegs = @()
$names = @(
 "viostor","vioscsi","storahci","pciide","intelide",
 "netkvm","Balloon","vioser","VirtioSerial","viorng","VirtRng",
 "qemufwcfg","FwCfg","VioGpuDod","qxldod",
 "xenvbd","xennet","xenvif","xeniface","xenbus","xendisk","xenfilt","xenagent",
 "QEMU-GA"
)
foreach ($n in $names) {
    $serviceRegs += Get-ServiceReg $n
}

$result = [PSCustomObject]@{
    CollectedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    ComputerInfo = $computer
    BcdEdit = $bcdText
    Drivers = @(Get-DriverInfo)
    Services = @(Get-ServiceInfo)
    ServiceRegistry = @($serviceRegs)
    Disks = @(Get-DiskInfoSafe)
    NetworkAdapters = @(Get-NetInfoSafe)
    Env = [PSCustomObject]@{
        ComputerName = $env:COMPUTERNAME
        SystemRoot = $env:SystemRoot
        ProcessorArchitecture = $env:PROCESSOR_ARCHITECTURE
    }
}

$result | ConvertTo-Json -Depth 7 -Compress
"""


FIRSTBOOT_PS1_TEMPLATE = r"""
$ErrorActionPreference = "Continue"
$Log = "C:\cloudboot-migrator\firstboot-repair.log"

function LogLine($msg) {
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$stamp $msg" | Out-File -FilePath $Log -Append -Encoding UTF8
    Write-Host $msg
}

New-Item -ItemType Directory -Force -Path "C:\cloudboot-migrator" | Out-Null
LogLine "Starting cloudboot firstboot repair"

$driverRoots = @(
    "C:\cloudboot-migrator\drivers",
    "C:\ospc2flex\virtio"
)

foreach ($root in $driverRoots) {
    if (Test-Path $root) {
        LogLine "Installing drivers from $root"
        pnputil /add-driver "$root\*.inf" /subdirs /install | Out-File -FilePath $Log -Append -Encoding UTF8
    }
}

try {
    pnputil /scan-devices | Out-File -FilePath $Log -Append -Encoding UTF8
} catch {
    LogLine "WARN: pnputil scan-devices failed: $_"
}

$qemuGaCandidates = @(
    "C:\cloudboot-migrator\guest-agent\qemu-ga-x86_64.msi",
    "C:\ospc2flex\guest-agent\qemu-ga-x86_64.msi"
)

foreach ($msi in $qemuGaCandidates) {
    if (Test-Path $msi) {
        LogLine "Installing QEMU Guest Agent from $msi"
        Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait
        break
    }
}

$servicesToAuto = @(
    "QEMU-GA", "BalloonService", "Dhcp", "Dnscache", "NlaSvc",
    "netprofm", "nsi", "MpsSvc", "TermService", "UmRdpService", "WinRM"
)

foreach ($svc in $servicesToAuto) {
    try {
        $s = Get-Service $svc -ErrorAction SilentlyContinue
        if ($s) {
            LogLine "Configuring service $svc Automatic + Start"
            sc.exe config $svc start= auto | Out-Null
            Start-Service $svc -ErrorAction SilentlyContinue
        }
    } catch {
        LogLine "WARN: Could not configure service $svc : $_"
    }
}

try {
    Get-NetAdapter | Where-Object {$_.Status -eq "Up"} | ForEach-Object {
        LogLine "Enabling DHCP on adapter $($_.Name)"
        Set-NetIPInterface -InterfaceAlias $_.Name -Dhcp Enabled -ErrorAction SilentlyContinue
        Set-DnsClientServerAddress -InterfaceAlias $_.Name -ResetServerAddresses -ErrorAction SilentlyContinue
    }
} catch {
    LogLine "WARN: DHCP repair failed: $_"
}

try {
    LogLine "Enabling RDP and firewall rules"
    Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
    Enable-NetFirewallRule -Name "FPS-ICMP4-ERQ-In" -ErrorAction SilentlyContinue
} catch {
    LogLine "WARN: RDP/firewall repair failed: $_"
}

try {
    winrm quickconfig -quiet
    Enable-PSRemoting -Force
} catch {
    LogLine "WARN: WinRM enable failed: $_"
}

try {
    LogLine "Applying BIOS/MBR BCD repair"
    bcdedit /set "{default}" device partition=C: | Out-File -FilePath $Log -Append -Encoding UTF8
    bcdedit /set "{default}" osdevice partition=C: | Out-File -FilePath $Log -Append -Encoding UTF8
    bcdedit /set "{default}" path \Windows\system32\winload.exe | Out-File -FilePath $Log -Append -Encoding UTF8
    bcdedit /set "{default}" systemroot \Windows | Out-File -FilePath $Log -Append -Encoding UTF8
    bcdedit /set "{default}" recoveryenabled No | Out-File -FilePath $Log -Append -Encoding UTF8
    bcdedit /deletevalue "{default}" safeboot | Out-File -FilePath $Log -Append -Encoding UTF8
    bcdedit /deletevalue "{default}" detecthal | Out-File -FilePath $Log -Append -Encoding UTF8
    bcdboot C:\Windows /s C: /f BIOS | Out-File -FilePath $Log -Append -Encoding UTF8
} catch {
    LogLine "WARN: BCD repair failed: $_"
}

LogLine "Final service status"
Get-Service QEMU-GA,BalloonService,Dhcp,Dnscache,NlaSvc,netprofm,MpsSvc,TermService,WinRM -ErrorAction SilentlyContinue |
    Format-Table -AutoSize | Out-File -FilePath $Log -Append -Encoding UTF8

LogLine "Final target driver status"
Get-CimInstance Win32_SystemDriver |
    Where-Object {
        $_.Name -match "viostor|vioscsi|netkvm|balloon|vioser|VirtioSerial|viorng|VirtRng|qemu|FwCfg|qemufwcfg|qxldod|VioGpu"
    } |
    Select-Object Name, DisplayName, State, Started, Status |
    Format-Table -AutoSize | Out-File -FilePath $Log -Append -Encoding UTF8

LogLine "cloudboot firstboot repair completed"
"""


@dataclasses.dataclass
class HostSpec:
    name: str
    host: str
    user: str
    port: int = 22
    key: Optional[str] = None
    password: Optional[str] = None
    winrm_host: Optional[str] = None


def run(
    cmd: List[str],
    timeout: int = 120,
    env: Optional[Dict[str, str]] = None,
) -> subprocess.CompletedProcess[str]:
    def _text(v: Any) -> str:
        if v is None:
            return ""
        if isinstance(v, bytes):
            return v.decode("utf-8", errors="replace")
        return str(v)

    try:
        return subprocess.run(
            cmd,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
            env=env,
        )
    except subprocess.TimeoutExpired as e:
        return subprocess.CompletedProcess(
            cmd,
            124,
            stdout=_text(e.stdout),
            stderr=_text(e.stderr) + f"\nCommand timed out after {timeout}s.",
        )


def encode_powershell(ps: str) -> str:
    return base64.b64encode(ps.encode("utf-16le")).decode("ascii")


def _expand_ssh_key_path(key: Optional[str]) -> Optional[str]:
    if not key:
        return None
    p = os.path.expanduser(str(key).strip())
    return p or None


def _ssh_troubleshoot_hint(spec: HostSpec, stderr: str, proxy_jump: Optional[str]) -> str:
    s = (stderr or "").lower()
    tgt = shlex.quote(spec.user + "@" + spec.host)
    if proxy_jump:
        pj = shlex.quote(proxy_jump)
        probe_pc = (
            f"ssh -o ProxyCommand={shlex.quote('ssh -W %h:%p ' + proxy_jump)} "
            f"-p {spec.port} -i <windows-key> {tgt}"
        )
        probe_j = f"ssh -J {pj} -p {spec.port} -i <key> {tgt}"
    else:
        probe_pc = ""
        probe_j = f"ssh -p {spec.port} -i <key> {tgt}"
    lines = [
        "",
        "Hints:",
    ]
    if proxy_jump:
        lines += [
            f"  • Manual test (matches CloudJumper bastion transport): {probe_pc}",
            f"  • Optional different client path: {probe_j}",
        ]
    else:
        lines += [f"  • From THIS machine, test: {probe_j}"]
    if proxy_jump:
        lines += [
            "  • Bastion hop uses ProxyCommand (not ssh -J) — avoids some OpenSSH 'UNKNOWN port 65535' banner quirks.",
            "  • Set CLOUDBOOT_JUMP_IDENTITY=/path/to/key if the key for the jumphost differs from the Windows SSH key.",
            "  • The TARGET must allow SSH from the JUMPHOST egress IP (firewall/NSG), not only from your laptop.",
            "  • On Windows: OpenSSH Server running, port " + str(spec.port) + " open, correct user (often Administrator).",
        ]
    if "timed out" in s or "banner" in s or "connection refused" in s:
        lines += [
            "  • Timeouts during banner: wrong port (Windows SSH is usually 22), blocked path to VM, or SSH not listening.",
            "  • If target port in the UI is not 22, confirm it matches Windows OpenSSH (sshd_config / firewall).",
        ]
    if "65535" in stderr or spec.port >= 65000:
        lines += [
            "  • 'UNKNOWN port 65535' is OpenSSH's proxy-channel label, not your configured target port. "
            "With a banner timeout, it usually means the bastion could not complete SSH negotiation with the target.",
            "  • Confirm Target port is 22 unless Windows sshd_config uses another port.",
        ]
    return "\n".join(lines)


def _jump_ssh_command(proxy_jump: str, jump_identity: Optional[str]) -> List[str]:
    """Return the ssh command prefix for reaching the bastion."""
    inner = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new"]
    env_ji = (os.environ.get("CLOUDBOOT_JUMP_IDENTITY") or "").strip()
    id_for_jump = _expand_ssh_key_path(env_ji) if env_ji else jump_identity
    if id_for_jump:
        inner += ["-i", id_for_jump]
    inner += ["-o", f"ConnectTimeout={SSH_CONNECT_TIMEOUT}", proxy_jump]
    return inner


def _bastion_proxy_command(proxy_jump: str, jump_identity: Optional[str]) -> str:
    """Return ProxyCommand=… string for ssh -W through the bastion (more reliable than -J with some clients)."""
    inner = _jump_ssh_command(proxy_jump, jump_identity)
    inner.insert(-1, "%h:%p")
    inner.insert(-2, "-W")
    return shlex.join(inner)


def _bastion_tcp_probe(spec: HostSpec, proxy_jump: Optional[str], jump_identity: Optional[str]) -> str:
    if not proxy_jump:
        return ""
    host = shlex.quote(spec.host)
    probe_ports: List[int] = []
    for p in [spec.port, 22, 5985, 5986, 3389, 445]:
        if p not in probe_ports:
            probe_ports.append(p)
    ports = " ".join(shlex.quote(str(p)) for p in probe_ports)
    remote = (
        "if command -v nc >/dev/null 2>&1; then "
        f"for p in {ports}; do "
        f"printf 'port %s: ' \"$p\"; "
        f"timeout 8 nc -vz {host} \"$p\" >/tmp/cloudboot-nc.out 2>&1 "
        "&& echo open "
        "|| { rc=$?; msg=$(tr '\\n' ' ' </tmp/cloudboot-nc.out | sed 's/[[:space:]]\\+/ /g'); echo \"blocked_or_timeout rc=$rc $msg\"; }; "
        "done; "
        "elif command -v python3 >/dev/null 2>&1; then "
        "python3 -c 'import socket,sys; host=sys.argv[1]; "
        "ports=[int(x) for x in sys.argv[2:]]; "
        "\nfor p in ports:\n "
        "\n    try:\n     s=socket.create_connection((host,p),8); s.close(); print(f\"port {p}: open\")\n "
        "\n    except Exception as e:\n     print(f\"port {p}: blocked_or_timeout {e}\")' "
        f"{host} {ports}; "
        "else "
        f"for p in {ports}; do printf 'port %s: ' \"$p\"; timeout 8 bash -lc \"</dev/tcp/{host}/$p\" && echo open || echo blocked_or_timeout; done; "
        "fi"
    )
    cp = run(_jump_ssh_command(proxy_jump, jump_identity) + [remote], timeout=BASTION_TCP_PROBE_TIMEOUT)
    out = (cp.stdout or "").strip()
    err = (cp.stderr or "").strip()
    mgmt_open = any(
        f"port {p}: open" in out
        for p in [spec.port, 22, 5985, 5986]
    )
    rdp_open = "port 3389: open" in out
    lines = [
        "",
        "Bastion TCP probe:",
        f"  • jump: {proxy_jump}",
        f"  • target: {spec.host}",
        f"  • command: probe TCP ports {' '.join(str(p) for p in probe_ports)} from jumphost",
        f"  • rc={cp.returncode}",
        f"  • stdout: {out[:500] or '<empty>'}",
        f"  • stderr: {err[:500] or '<empty>'}",
    ]
    if mgmt_open and f"port {spec.port}: open" in out:
        lines += [
            "  • TCP opened from the jumphost, but the Windows SSH banner did not complete. Check sshd health, "
            "MaxStartups/LoginGraceTime, security software, or a non-SSH service on this port.",
        ]
    elif rdp_open and not mgmt_open:
        lines += [
            "  • Root cause: the VM is reachable for RDP, but SSH/WinRM management ports are blocked from the jumphost.",
            "  • CloudJumper cannot collect or bootstrap OpenSSH until TCP 22 or WinRM 5985/5986 is allowed, "
            "or OpenSSH is injected by another out-of-band path.",
        ]
    else:
        lines += [
            "  • TCP did not open on CloudJumper management ports from the jumphost. Fix target firewall/security-group/"
            "routing for the jumphost egress path before rerunning CloudJumper.",
        ]
    return "\n".join(lines)


WINRM_BOOTSTRAP_PY = r'''
import json
import socket
import sys

req = json.loads(sys.stdin.read())
hosts = [h for h in req.get("hosts", []) if h]
user = req.get("user") or "Administrator"
password = req.get("password") or ""
pubkey = req.get("pubkey") or ""
jumphost_http_ip = req.get("jumphost_http_ip") or ""
if not hosts or not password:
    print("[WinRM] hosts and password are required", file=sys.stderr)
    sys.exit(12)

target = None
for host in hosts:
    for port, scheme in ((5985, "http"), (5986, "https")):
        try:
            with socket.create_connection((host, port), timeout=8):
                target = (host, port, scheme)
                break
        except OSError:
            pass
    if target:
        break

if not target:
    print("[WinRM] 5985/5986 not reachable on " + ", ".join(hosts), file=sys.stderr)
    sys.exit(13)

try:
    import winrm
except Exception as e:
    print(f"[WinRM] pywinrm import failed after TCP probe succeeded: {e}", file=sys.stderr)
    sys.exit(11)

host, port, scheme = target
print(f"[WinRM] using {scheme}://{host}:{port}/wsman")

ps = r"""
$ErrorActionPreference = 'Stop'
$pub = @'
__PUBKEY__
'@.Trim()

Write-Output '[WinRM] Checking OpenSSH Server'
$sshd = Get-Service sshd -ErrorAction SilentlyContinue
if ($sshd) {
    Write-Output '[WinRM] OpenSSH Server already installed; skipping install'
} else {
    $cap = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction SilentlyContinue
    if ($cap -and $cap.State -eq 'NotPresent') {
        Write-Output '[WinRM] Installing OpenSSH.Server capability'
        Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction SilentlyContinue | Out-Null
    } elseif ($cap -and $cap.State -eq 'Installed') {
        Write-Output '[WinRM] OpenSSH.Server capability already installed; waiting for sshd service'
    } else {
        Write-Output '[WinRM] OpenSSH.Server capability state unknown; will try offline fallback if sshd is still missing'
    }
}

if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
    Write-Output '[WinRM] OpenSSH capability did not create sshd service'
    $jh = '__JUMPHOST_HTTP_IP__'
    if ($jh -ne '') {
        Write-Output "[WinRM] Trying OpenSSH-Win64.zip fallback from jumphost http://${jh}:8080"
        Invoke-WebRequest -Uri "http://${jh}:8080/OpenSSH-Win64.zip" -OutFile 'C:\Windows\Temp\OpenSSH-Win64.zip' -UseBasicParsing
        Expand-Archive -Path 'C:\Windows\Temp\OpenSSH-Win64.zip' -DestinationPath 'C:\Program Files\' -Force
        & 'C:\Program Files\OpenSSH-Win64\install-sshd.ps1'
        Write-Output '[WinRM] OpenSSH installed from jumphost package'
    }
}

if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
    throw 'OpenSSH Server is not installed after capability and jumphost package fallback'
}

Write-Output '[WinRM] Starting sshd'
$attempts = 0
while ($attempts -lt 6) {
    try {
        Start-Service sshd -ErrorAction Stop
        Set-Service -Name sshd -StartupType Automatic
        break
    } catch {
        $attempts++
        Start-Sleep -Seconds 5
        if ($attempts -ge 6) { throw }
    }
}

if (-not (Get-NetFirewallRule -Name sshd -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH (CloudJumper)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    Write-Output '[WinRM] Firewall rule added'
} else {
    Enable-NetFirewallRule -Name sshd | Out-Null
    Write-Output '[WinRM] Firewall rule enabled'
}

$psExe = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
if (Test-Path $psExe) {
    if (-not (Test-Path 'HKLM:\SOFTWARE\OpenSSH')) { New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null }
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value $psExe
    Write-Output '[WinRM] Default shell set to Windows PowerShell'
}

if ($pub -ne '') {
    $home = Join-Path $env:SystemDrive 'Users\Administrator\.ssh'
    if (-not (Test-Path $home)) { New-Item -ItemType Directory -Path $home -Force | Out-Null }
    $ak = Join-Path $home 'authorized_keys'
    Set-Content -Path $ak -Value $pub -Encoding ascii
    $fa = New-Object Security.AccessControl.FileSecurity
    $fa.SetAccessRuleProtection($true,$false)
    $fa.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule('NT AUTHORITY\SYSTEM','FullControl','None','None','Allow')))
    $fa.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule('BUILTIN\Administrators','FullControl','None','None','Allow')))
    Set-Acl $ak $fa
    Write-Output '[WinRM] Administrator authorized_keys installed'

    $pd = Join-Path $env:ProgramData 'ssh'
    if (Test-Path $pd) {
        $adminAk = Join-Path $pd 'administrators_authorized_keys'
        Set-Content -Path $adminAk -Value $pub -Encoding ascii
        $fa2 = New-Object Security.AccessControl.FileSecurity
        $fa2.SetAccessRuleProtection($true,$false)
        $fa2.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule('NT AUTHORITY\SYSTEM','FullControl','None','None','Allow')))
        $fa2.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule('BUILTIN\Administrators','FullControl','None','None','Allow')))
        Set-Acl $adminAk $fa2
        Write-Output '[WinRM] administrators_authorized_keys installed'
    }
}

Restart-Service sshd -Force
Write-Output '[WinRM] Bootstrap complete'
"""
ps = ps.replace("__PUBKEY__", pubkey)
if not jumphost_http_ip:
    try:
        jumphost_http_ip = socket.gethostbyname(socket.gethostname())
    except Exception:
        jumphost_http_ip = ""
ps = ps.replace("__JUMPHOST_HTTP_IP__", jumphost_http_ip)

try:
    session = winrm.Session(
        f"{scheme}://{host}:{port}/wsman",
        auth=(user, password),
        transport="ntlm",
        server_cert_validation="ignore",
        # pywinrm requires read_timeout_sec > operation_timeout_sec.
        read_timeout_sec=900,
        operation_timeout_sec=300,
    )
    result = session.run_ps(ps)
except Exception as e:
    print(f"[WinRM] session failed: {e}", file=sys.stderr)
    sys.exit(14)

out = result.std_out.decode("utf-8", errors="replace").strip()
err = result.std_err.decode("utf-8", errors="replace").strip()
if out:
    print(out)
if err and "CLIXML" not in err:
    print(err, file=sys.stderr)
if result.status_code != 0:
    print(f"[WinRM] PowerShell exit {result.status_code}", file=sys.stderr)
    sys.exit(result.status_code)
sys.exit(0)
'''


def _local_public_key() -> str:
    env_pub = (os.environ.get("CLOUDBOOT_BOOTSTRAP_PUBLIC_KEY") or "").strip()
    if env_pub:
        return env_pub
    for name in ("id_rsa.pub", "id_ed25519.pub", "id_ecdsa.pub"):
        p = Path.home() / ".ssh" / name
        try:
            if p.is_file():
                return p.read_text(encoding="utf-8").strip()
        except OSError:
            pass
    return ""


def _winrm_bootstrap_ssh(spec: HostSpec, proxy_jump: Optional[str], jump_identity: Optional[str]) -> subprocess.CompletedProcess[str]:
    hosts = []
    if spec.winrm_host:
        hosts.append(spec.winrm_host)
    hosts.append(spec.host)
    jumphost_http_ip = ""
    if proxy_jump:
        jump_target = proxy_jump.rsplit("@", 1)[-1]
        jumphost_http_ip = jump_target.rsplit(":", 1)[0].strip("[]")
    payload = {
        "hosts": hosts,
        "user": spec.user,
        "password": spec.password or "",
        "pubkey": _local_public_key(),
        "jumphost_http_ip": jumphost_http_ip,
    }
    data = json.dumps(payload)
    ensure = (
        "PY=python3; "
        "if ! python3 -c 'import winrm' >/dev/null 2>&1; then "
        "python3 -m pip install --user --break-system-packages --quiet pywinrm requests_ntlm >/dev/null 2>&1 || "
        "(python3 -m venv /tmp/cloudjumper-winrm-venv >/dev/null 2>&1 && "
        "/tmp/cloudjumper-winrm-venv/bin/pip install --quiet pywinrm requests_ntlm >/dev/null 2>&1 && "
        "PY=/tmp/cloudjumper-winrm-venv/bin/python) || true; "
        "fi"
    )
    if proxy_jump:
        remote_cmd = ensure + "; $PY -c " + shlex.quote(WINRM_BOOTSTRAP_PY)
        return subprocess.run(
            _jump_ssh_command(proxy_jump, jump_identity) + [remote_cmd],
            input=data,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=WINRM_BOOTSTRAP_TIMEOUT,
            check=False,
        )
    local_cmd = (
        ensure + "; $PY -c " + shlex.quote(WINRM_BOOTSTRAP_PY)
    )
    return subprocess.run(
        ["bash", "-lc", local_cmd],
        input=data,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=WINRM_BOOTSTRAP_TIMEOUT,
        check=False,
    )


def _wait_for_ssh_open(spec: HostSpec, proxy_jump: Optional[str], jump_identity: Optional[str]) -> bool:
    print(
        f"[cloudboot] Waiting for {spec.name} SSH TCP to open after bootstrap on candidate IPs...",
        flush=True,
    )
    for i in range(24):
        print(f"[cloudboot]   SSH port check attempt {i + 1}/24 for {spec.name}...", flush=True)
        for host in _host_candidates(spec, ssh_order=True):
            probe = f"nc -z -w 5 {shlex.quote(host)} {shlex.quote(str(spec.port))}"
            if proxy_jump:
                cp = run(_jump_ssh_command(proxy_jump, jump_identity) + [probe], timeout=15)
            else:
                cp = run(["bash", "-lc", probe], timeout=15)
            if cp.returncode == 0:
                print(f"[cloudboot]   SSH port is open for {spec.name} on {host}.", flush=True)
                return True
        time.sleep(5)
    return False


def _try_winrm_bootstrap(spec: HostSpec, proxy_jump: Optional[str], jump_identity: Optional[str]) -> str:
    if not spec.password:
        return "\nWinRM bootstrap skipped: Windows password not supplied."
    if spec.port != 22:
        return f"\nWinRM bootstrap skipped: target SSH port is {spec.port}, but OpenSSH bootstrap opens port 22."
    winrm_candidates = _host_candidates(spec, ssh_order=False)
    lines = ["", f"WinRM OpenSSH bootstrap for {spec.name} ({', '.join(winrm_candidates)}):"]
    if proxy_jump:
        print(
            f"[cloudboot] WinRM bootstrap will run from jumphost {proxy_jump} toward {', '.join(winrm_candidates)}.",
            flush=True,
        )
    else:
        print(f"[cloudboot] WinRM bootstrap will run locally toward {', '.join(winrm_candidates)}.", flush=True)
    print("[cloudboot] Probing WinRM TCP 5985/5986 and preparing pywinrm helper...", flush=True)
    cp = _winrm_bootstrap_ssh(spec, proxy_jump, jump_identity)
    print(f"[cloudboot] WinRM bootstrap command finished with rc={cp.returncode}.", flush=True)
    out = (cp.stdout or "").strip()
    err = (cp.stderr or "").strip()
    lines += [
        f"  • rc={cp.returncode}",
        f"  • stdout: {out[:2000] or '<empty>'}",
        f"  • stderr: {err[:2000] or '<empty>'}",
    ]
    if cp.returncode == 0:
        opened = _wait_for_ssh_open(spec, proxy_jump, jump_identity)
        lines.append(f"  • ssh port check after bootstrap: {'open' if opened else 'not open'}")
    return "\n".join(lines)


def _redact_ssh_command(cmd: List[str]) -> str:
    redacted: List[str] = []
    skip_next = False
    for i, part in enumerate(cmd):
        if skip_next:
            skip_next = False
            continue
        redacted.append(part)
        if part in ("-i", "-o") and i + 1 < len(cmd):
            val = cmd[i + 1]
            if part == "-i":
                redacted.append("<key>")
            elif val.startswith("ProxyCommand="):
                redacted.append("ProxyCommand=<redacted>")
            else:
                redacted.append(val)
            skip_next = True
    return shlex.join(redacted)


def _run_ssh_for_spec(spec: HostSpec, ssh_cmd: List[str], timeout: int) -> subprocess.CompletedProcess[str]:
    if spec.password:
        if not shutil.which("sshpass"):
            raise RuntimeError(
                "SSH password auth requires `sshpass` on PATH (e.g. apt install sshpass). "
                f"Install it or use key-based auth for {spec.name}."
            )
        return run(["sshpass", "-e"] + ssh_cmd, timeout=timeout, env={**os.environ, "SSHPASS": spec.password})
    return run(ssh_cmd, timeout=timeout)


def _host_candidates(spec: HostSpec, *, ssh_order: bool = True) -> List[str]:
    raw = [spec.host, spec.winrm_host] if ssh_order else [spec.winrm_host, spec.host]
    out: List[str] = []
    for h in raw:
        h = (h or "").strip()
        if h and h not in out:
            out.append(h)
    return out


def _ssh_cmd_for_host(
    spec: HostSpec,
    host: str,
    proxy_jump: Optional[str],
    jump_identity: Optional[str],
) -> List[str]:
    ssh_base_cmd: List[str] = ["ssh"]
    if proxy_jump:
        pc = _bastion_proxy_command(proxy_jump, jump_identity)
        ssh_base_cmd += ["-o", f"ProxyCommand={pc}"]
    ssh_base_cmd += [
        "-p", str(spec.port),
        # CloudJumper is an automation tool and frequently targets ephemeral hosts.
        # Avoid interactive SSH prompts and known_hosts churn.
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", f"ConnectTimeout={SSH_CONNECT_TIMEOUT}",
        "-o", "ServerAliveInterval=10",
        "-o", "ServerAliveCountMax=6",
    ]
    if spec.password:
        ssh_base_cmd += ["-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no"]
    else:
        ssh_base_cmd += ["-o", "BatchMode=yes"]
        if jump_identity:
            ssh_base_cmd += ["-i", jump_identity, "-o", "IdentitiesOnly=yes"]
    ssh_base_cmd.append(f"{spec.user}@{host}")
    return ssh_base_cmd


def _ssh_preflight_once(spec: HostSpec, ssh_base_cmd: List[str], host: str, proxy_jump: Optional[str]) -> subprocess.CompletedProcess[str]:
    print(
        f"[cloudboot] SSH preflight for {spec.name}: {spec.user}@{host}:{spec.port}",
        flush=True,
    )
    if proxy_jump:
        print(f"[cloudboot]   via jumphost/proxy: {proxy_jump}", flush=True)
    print(
        f"[cloudboot]   auth: {'password' if spec.password else 'key/batch'}; timeout={SSH_PREFLIGHT_TIMEOUT}s",
        flush=True,
    )
    print("[cloudboot]   running remote check: cmd.exe /c ver", flush=True)
    cp = _run_ssh_for_spec(spec, ssh_base_cmd + ["cmd.exe", "/c", "ver"], timeout=SSH_PREFLIGHT_TIMEOUT)
    if cp.returncode == 0:
        ver = (cp.stdout or "").strip().replace("\r", "")
        print(f"[cloudboot] SSH preflight succeeded for {spec.name} via {host}: {ver[:200] or 'connected'}", flush=True)
    return cp


def _tcp_port_open(host: str, port: int, proxy_jump: Optional[str], jump_identity: Optional[str], label: str) -> bool:
    probe = (
        "if command -v nc >/dev/null 2>&1; then "
        f"nc -z -w 8 {shlex.quote(host)} {shlex.quote(str(port))}; "
        "else "
        f"timeout 8 bash -lc '</dev/tcp/{shlex.quote(host)}/{shlex.quote(str(port))}'; "
        "fi"
    )
    if proxy_jump:
        cp = run(_jump_ssh_command(proxy_jump, jump_identity) + [probe], timeout=15)
    else:
        cp = run(["bash", "-lc", probe], timeout=15)
    state = "open" if cp.returncode == 0 else "blocked_or_timeout"
    print(f"[cloudboot] Stage 1 TCP probe for {label}: {host}:{port} -> {state}", flush=True)
    return cp.returncode == 0


def _ssh_tcp_preflight(
    spec: HostSpec,
    ssh_base_cmd: List[str],
    proxy_jump: Optional[str],
    jump_identity: Optional[str],
) -> None:
    print(
        f"[cloudboot] SSH preflight for {spec.name}: {spec.user}@{spec.host}:{spec.port}",
        flush=True,
    )
    if proxy_jump:
        print(f"[cloudboot]   via jumphost/proxy: {proxy_jump}", flush=True)
    print(
        f"[cloudboot]   auth: {'password' if spec.password else 'key/batch'}; timeout={SSH_PREFLIGHT_TIMEOUT}s",
        flush=True,
    )
    print("[cloudboot]   running remote check: cmd.exe /c ver", flush=True)
    cp = _run_ssh_for_spec(spec, ssh_base_cmd + ["cmd.exe", "/c", "ver"], timeout=SSH_PREFLIGHT_TIMEOUT)
    if cp.returncode == 0:
        ver = (cp.stdout or "").strip().replace("\r", "")
        print(f"[cloudboot] SSH preflight succeeded for {spec.name}: {ver[:200] or 'connected'}", flush=True)
        return
    bootstrap_report = ""
    if spec.password:
        print(
            f"[cloudboot] SSH preflight failed for {spec.name}; trying WinRM OpenSSH bootstrap...",
            flush=True,
        )
        bootstrap_report = _try_winrm_bootstrap(spec, proxy_jump, jump_identity)
        print(bootstrap_report, flush=True)
        print(f"[cloudboot] Retrying SSH preflight for {spec.name} after bootstrap attempt...", flush=True)
        cp_retry = _run_ssh_for_spec(spec, ssh_base_cmd + ["cmd.exe", "/c", "ver"], timeout=SSH_PREFLIGHT_TIMEOUT)
        if cp_retry.returncode == 0:
            print(f"[cloudboot] SSH preflight succeeded for {spec.name} after WinRM bootstrap.", flush=True)
            return
        cp = cp_retry
    err = (cp.stderr or "").strip()
    out = (cp.stdout or "").strip()
    tcp_probe = _bastion_tcp_probe(spec, proxy_jump, jump_identity)
    hint = _ssh_troubleshoot_hint(spec, err, proxy_jump)
    raise RuntimeError(
        f"SSH preflight failed for {spec.name} ({spec.host}:{spec.port})\n"
        f"(migrator {_TRANSPORT_REV}: {os.path.abspath(__file__)})\n"
        f"ReturnCode: {cp.returncode}\n"
        f"Command: {_redact_ssh_command(ssh_base_cmd + ['cmd.exe', '/c', 'ver'])}\n"
        f"STDERR:\n{err or '<empty>'}\nSTDOUT:\n{out[:2000] or '<empty>'}\n"
        "This failed before the PowerShell collector ran. Confirm the Windows target is reachable over SSH "
        "from the selected jumphost, OpenSSH Server is running, and firewall/security-group rules allow TCP "
        f"{spec.port} from that path."
        + bootstrap_report
        + tcp_probe
        + hint
    )


def _ssh_failure_probe(spec: HostSpec, ssh_base_cmd: List[str]) -> str:
    probes = [
        ("cmd version", ["cmd.exe", "/c", "ver"]),
        (
            "powershell version",
            [
                "powershell.exe",
                "-NoProfile",
                "-Command",
                "$PSVersionTable.PSVersion.ToString(); Write-Output $env:COMPUTERNAME",
            ],
        ),
    ]
    lines = ["", "Diagnostic probes:"]
    for label, remote in probes:
        cp = _run_ssh_for_spec(spec, ssh_base_cmd + remote, timeout=SSH_PROBE_TIMEOUT)
        lines += [
            f"  • {label}: rc={cp.returncode}",
            f"    stdout: {(cp.stdout or '').strip()[:500] or '<empty>'}",
            f"    stderr: {(cp.stderr or '').strip()[:500] or '<empty>'}",
        ]
    return "\n".join(lines)


def ssh_powershell_json(
    spec: HostSpec,
    ps_script: str,
    timeout: int = 180,
    proxy_jump: Optional[str] = None,
) -> Dict[str, Any]:
    def winrm_powershell_json() -> Optional[Dict[str, Any]]:
        """
        Collect PowerShell JSON via WinRM when SSH is unavailable.

        This avoids the OpenSSH bootstrap path entirely and prevents failures like
        'The command line is too long.' on some Windows builds/policies.
        """
        if not spec.password:
            return None
        try:
            import winrm  # type: ignore
        except Exception:
            return None

        # Prefer WinRM host hint first (ServiceNet/private), then public host.
        candidates = _host_candidates(spec, ssh_order=False)
        for host in candidates:
            host = (host or "").strip()
            if not host:
                continue
            for port, scheme in ((5985, "http"), (5986, "https")):
                if not _tcp_port_open(host, port, proxy_jump, None, f"{spec.name} WinRM {port}"):
                    continue
                print(f"[cloudboot] Using WinRM for {spec.name}: {scheme}://{host}:{port}/wsman", flush=True)
                try:
                    session = winrm.Session(
                        f"{scheme}://{host}:{port}/wsman",
                        auth=(spec.user, spec.password),
                        transport="ntlm",
                        server_cert_validation="ignore",
                        # pywinrm requires: read_timeout_sec > operation_timeout_sec, and both non-zero.
                        # Keep operation bounded, but always set read > operation.
                        read_timeout_sec=max(900, int(timeout) + 400),
                        operation_timeout_sec=300,
                    )
                    result = session.run_ps(ps_script)
                except Exception as e:
                    print(f"[cloudboot] WinRM session failed for {spec.name} on {host}:{port}: {e}", flush=True)
                    continue

                out = (result.std_out or b"").decode("utf-8", errors="replace").strip()
                err = (result.std_err or b"").decode("utf-8", errors="replace").strip()
                if result.status_code != 0:
                    print(f"[cloudboot] WinRM PowerShell exit {result.status_code} for {spec.name} on {host}:{port}", flush=True)
                    if err and "CLIXML" not in err:
                        print(f"[cloudboot] WinRM stderr: {err[:1200]}", flush=True)
                    continue
                if not out:
                    print(f"[cloudboot] WinRM returned empty output for {spec.name} on {host}:{port}", flush=True)
                    continue

                start = out.find("{")
                end = out.rfind("}")
                if start < 0 or end < start:
                    print(f"[cloudboot] WinRM output did not contain JSON for {spec.name}: {out[:1200]}", flush=True)
                    continue
                parsed = json.loads(out[start:end + 1])
                print(f"[cloudboot] Parsed collector JSON for {spec.name} via WinRM.", flush=True)
                return parsed
        return None

    print(f"[cloudboot] Preparing PowerShell collector for {spec.name} ({spec.host}).", flush=True)
    encoded = encode_powershell(ps_script)
    key_path = _expand_ssh_key_path(spec.key)
    if proxy_jump:
        print(f"[cloudboot] Collector transport for {spec.name}: ProxyCommand via {proxy_jump}.", flush=True)
    else:
        print(f"[cloudboot] Collector transport for {spec.name}: direct SSH.", flush=True)
    if spec.password:
        print(f"[cloudboot] Collector auth for {spec.name}: password/sshpass.", flush=True)
    else:
        print(f"[cloudboot] Collector auth for {spec.name}: key/batch mode.", flush=True)
    if key_path and not spec.password:
        print(f"[cloudboot] Collector key for {spec.name}: {key_path}", flush=True)

    ssh_candidates = _host_candidates(spec, ssh_order=True)
    if len(ssh_candidates) > 1:
        print(
            f"[cloudboot] Stage 1 access order for {spec.name}: SSH public/primary first, then private/ServiceNet ({', '.join(ssh_candidates)}).",
            flush=True,
        )

    all_ssh_candidates = list(ssh_candidates)
    open_candidates: List[str] = []
    for host in ssh_candidates:
        if _tcp_port_open(host, spec.port, proxy_jump, key_path, f"{spec.name} SSH"):
            open_candidates.append(host)
    if open_candidates:
        ssh_candidates = open_candidates
    else:
        print(
            f"[cloudboot] No SSH TCP candidate opened for {spec.name}; proceeding to WinRM bootstrap check before any long SSH retry.",
            flush=True,
        )
        # If WinRM is reachable, collect directly via WinRM and skip any SSH bootstrap.
        w = winrm_powershell_json()
        if w is not None:
            return w

    ssh_base_cmd: List[str] | None = None
    selected_host = ""
    attempts: List[tuple[str, subprocess.CompletedProcess[str]]] = []
    for host in ssh_candidates:
        if not open_candidates:
            break
        candidate_cmd = _ssh_cmd_for_host(spec, host, proxy_jump, key_path)
        cp = _ssh_preflight_once(spec, candidate_cmd, host, proxy_jump)
        attempts.append((host, cp))
        if cp.returncode == 0:
            ssh_base_cmd = candidate_cmd
            selected_host = host
            break

    bootstrap_report = ""
    if ssh_base_cmd is None and spec.password:
        print(
            f"[cloudboot] SSH was not reachable for {spec.name} on candidate IPs; trying WinRM OpenSSH bootstrap like fullmig Stage 1b...",
            flush=True,
        )
        # Try direct WinRM collection before attempting OpenSSH bootstrap (more reliable).
        w = winrm_powershell_json()
        if w is not None:
            return w
        bootstrap_report = _try_winrm_bootstrap(spec, proxy_jump, key_path)
        print(bootstrap_report, flush=True)
        print(f"[cloudboot] Retrying SSH candidate IPs for {spec.name} after WinRM bootstrap...", flush=True)
        attempts = []
        retry_candidates = []
        for host in all_ssh_candidates:
            if _tcp_port_open(host, spec.port, proxy_jump, key_path, f"{spec.name} SSH retry"):
                retry_candidates.append(host)
        for host in retry_candidates or all_ssh_candidates:
            candidate_cmd = _ssh_cmd_for_host(spec, host, proxy_jump, key_path)
            cp = _ssh_preflight_once(spec, candidate_cmd, host, proxy_jump)
            attempts.append((host, cp))
            if cp.returncode == 0:
                ssh_base_cmd = candidate_cmd
                selected_host = host
                break

    if ssh_base_cmd is None:
        host, cp = attempts[-1] if attempts else (spec.host, subprocess.CompletedProcess([], 255, "", "no SSH candidate attempted"))
        err = (cp.stderr or "").strip()
        out = (cp.stdout or "").strip()
        tcp_probe = _bastion_tcp_probe(HostSpec(spec.name, host, spec.user, spec.port, spec.key, password=spec.password, winrm_host=spec.winrm_host), proxy_jump, key_path)
        hint = _ssh_troubleshoot_hint(HostSpec(spec.name, host, spec.user, spec.port, spec.key, password=spec.password, winrm_host=spec.winrm_host), err, proxy_jump)
        tried = ", ".join(all_ssh_candidates) or spec.host
        raise RuntimeError(
            f"SSH preflight failed for {spec.name} on all Stage 1 candidate IPs ({tried})\n"
            f"(migrator {_TRANSPORT_REV}: {os.path.abspath(__file__)})\n"
            f"ReturnCode: {cp.returncode}\n"
            f"Command: {_redact_ssh_command(_ssh_cmd_for_host(spec, host, proxy_jump, key_path) + ['cmd.exe', '/c', 'ver'])}\n"
            f"STDERR:\n{err or '<empty>'}\nSTDOUT:\n{out[:2000] or '<empty>'}\n"
            "This matches the fullmig Stage 1b hard boundary: SSH is unavailable and WinRM bootstrap could not make SSH reachable. "
            "Full migration can continue only through the snapshot/Glance path; live boot comparison still needs a reachable source/reference collector."
            + bootstrap_report
            + tcp_probe
            + hint
        )

    if selected_host and selected_host != spec.host:
        print(f"[cloudboot] Using {selected_host} for {spec.name} PowerShell collection.", flush=True)
    ssh_cmd = ssh_base_cmd + ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encoded]

    print(f"[cloudboot] Running PowerShell collector on {spec.name}; timeout={timeout}s.", flush=True)
    cp = _run_ssh_for_spec(spec, ssh_cmd, timeout=timeout)
    if cp.returncode != 0:
        err = cp.stderr or ""
        hint = _ssh_troubleshoot_hint(spec, err, proxy_jump)
        probe = _ssh_failure_probe(spec, ssh_base_cmd)
        raise RuntimeError(
            f"SSH PowerShell collection failed for {spec.name} ({spec.host})\n"
            f"(migrator {_TRANSPORT_REV}: {os.path.abspath(__file__)})\n"
            f"ReturnCode: {cp.returncode}\n"
            f"Command: {_redact_ssh_command(ssh_cmd)}\n"
            f"STDERR:\n{err}\nSTDOUT:\n{(cp.stdout or '')[:2000]}"
            + probe
            + hint
        )

    stdout = cp.stdout.strip()
    if not stdout:
        raise RuntimeError(f"No JSON returned from {spec.name}")

    start = stdout.find("{")
    end = stdout.rfind("}")
    if start < 0 or end < start:
        raise RuntimeError(f"Could not find JSON in output from {spec.name}: {stdout[:2000]}")
    parsed = json.loads(stdout[start:end + 1])
    print(f"[cloudboot] Parsed collector JSON for {spec.name}.", flush=True)
    return parsed


def normalize_list(x: Any) -> List[Any]:
    if x is None:
        return []
    if isinstance(x, list):
        return x
    return [x]


def index_by_name(items: List[Dict[str, Any]]) -> Dict[str, Dict[str, Any]]:
    out: Dict[str, Dict[str, Any]] = {}
    for item in items:
        if not isinstance(item, dict):
            continue
        name = str(item.get("Name", "")).lower()
        if name:
            out[name] = item
    return out


def detect_cloud_profile(profile: Dict[str, Any]) -> Dict[str, Any]:
    ci = profile.get("ComputerInfo", {}) or {}
    disks = normalize_list(profile.get("Disks"))
    nics = normalize_list(profile.get("NetworkAdapters"))
    drivers = index_by_name(normalize_list(profile.get("Drivers")))
    services = index_by_name(normalize_list(profile.get("Services")))

    bios_vendor = str(ci.get("BiosManufacturer", ""))
    bios_fw = str(ci.get("BiosFirmwareType", ""))
    cs_manufacturer = str(ci.get("CsManufacturer", ""))
    cs_model = str(ci.get("CsModel", ""))
    os_name = str(ci.get("OsName", ""))
    os_ver = str(ci.get("OsVersion", ""))

    partition_styles = sorted(set(str(d.get("PartitionStyle", "")) for d in disks if isinstance(d, dict)))
    bus_types = sorted(set(str(d.get("BusType", "")) for d in disks if isinstance(d, dict)))
    nic_desc = " | ".join(str(n.get("InterfaceDescription", "")) for n in nics if isinstance(n, dict))

    return {
        "os_name": os_name,
        "os_version": os_ver,
        "firmware": bios_fw,
        "bios_vendor": bios_vendor,
        "manufacturer": cs_manufacturer,
        "model": cs_model,
        "partition_styles": partition_styles,
        "disk_bus_types": bus_types,
        "nic_descriptions": nic_desc,
        "is_openstack_nova": "openstack" in cs_manufacturer.lower() or "nova" in cs_model.lower(),
        "is_bios": bios_fw.lower() == "bios" or "seabios" in bios_vendor.lower(),
        "uses_virtio_disk": ("viostor" in drivers or "vioscsi" in drivers or "virtio" in " ".join(bus_types).lower()),
        "uses_virtio_nic": ("virtio" in nic_desc.lower() or "red hat virtio" in nic_desc.lower() or "netkvm" in drivers),
        "has_qemu_ga": "qemu-ga" in services,
        "running_drivers": sorted([k for k, v in drivers.items() if str(v.get("State", "")).lower() == "running"]),
    }


def compare_profiles(source: Dict[str, Any], target: Dict[str, Any]) -> Dict[str, Any]:
    sp = detect_cloud_profile(source)
    tp = detect_cloud_profile(target)

    source_drivers = index_by_name(normalize_list(source.get("Drivers")))
    target_drivers = index_by_name(normalize_list(target.get("Drivers")))
    source_services = index_by_name(normalize_list(source.get("Services")))
    target_services = index_by_name(normalize_list(target.get("Services")))

    missing_target_drivers = [
        d for d in BOOT_CRITICAL_DRIVERS + FLEX_RUNTIME_DRIVERS
        if d.lower() in target_drivers and d.lower() not in source_drivers
    ]
    missing_target_services = [
        s for s in FLEX_RUNTIME_SERVICES
        if s.lower() in target_services and s.lower() not in source_services
    ]

    risks = []
    if tp["is_bios"] and not sp["is_bios"]:
        risks.append("Target uses BIOS/SeaBIOS but source may not. Force BIOS/MBR BCD repair.")
    if tp["uses_virtio_disk"] and not sp["uses_virtio_disk"]:
        risks.append("Target uses VirtIO disk. Source needs viostor/vioscsi injected and Start=0.")
    if tp["uses_virtio_nic"] and not sp["uses_virtio_nic"]:
        risks.append("Target uses VirtIO NIC. Source needs netkvm staged/installed.")
    if tp["has_qemu_ga"] and not sp["has_qemu_ga"]:
        risks.append("Target has QEMU Guest Agent. Source should install/start QEMU-GA after boot.")

    return {
        "source_detected": sp,
        "target_detected": tp,
        "missing_target_drivers_on_source": missing_target_drivers,
        "missing_target_services_on_source": missing_target_services,
        "risks": risks,
        "recommended_mode": "bruteforce_flex" if tp["is_openstack_nova"] and tp["uses_virtio_disk"] else "target_clone",
    }


def generate_registry_patch() -> str:
    return r"""Windows Registry Editor Version 5.00

; Boot-critical storage drivers
"ControlSet001\Services\viostor\Type"=dword:00000001
"ControlSet001\Services\viostor\Start"=dword:00000000
"ControlSet001\Services\viostor\ErrorControl"=dword:00000001
"ControlSet001\Services\viostor\Tag"=dword:00000021
"ControlSet001\Services\viostor\ImagePath"="system32\\drivers\\viostor.sys"
"ControlSet001\Services\viostor\Group"="SCSI miniport"

"ControlSet001\Services\vioscsi\Type"=dword:00000001
"ControlSet001\Services\vioscsi\Start"=dword:00000000
"ControlSet001\Services\vioscsi\ErrorControl"=dword:00000001
"ControlSet001\Services\vioscsi\Tag"=dword:00000022
"ControlSet001\Services\vioscsi\ImagePath"="system32\\drivers\\vioscsi.sys"
"ControlSet001\Services\vioscsi\Group"="SCSI miniport"

"ControlSet001\Services\storahci\Start"=dword:00000000
"ControlSet001\Services\pciide\Start"=dword:00000000
"ControlSet001\Services\intelide\Start"=dword:00000000

; VirtIO network
"ControlSet001\Services\netkvm\Type"=dword:00000001
"ControlSet001\Services\netkvm\Start"=dword:00000003
"ControlSet001\Services\netkvm\ErrorControl"=dword:00000001
"ControlSet001\Services\netkvm\ImagePath"="system32\\drivers\\netkvm.sys"
"ControlSet001\Services\netkvm\Group"="NDIS"

; Flex/OpenStack runtime drivers
"ControlSet001\Services\Balloon\Type"=dword:00000001
"ControlSet001\Services\Balloon\Start"=dword:00000000
"ControlSet001\Services\Balloon\ErrorControl"=dword:00000001
"ControlSet001\Services\Balloon\ImagePath"="system32\\drivers\\balloon.sys"
"ControlSet001\Services\Balloon\Group"="System Bus Extender"

"ControlSet001\Services\vioser\Type"=dword:00000001
"ControlSet001\Services\vioser\Start"=dword:00000000
"ControlSet001\Services\vioser\ErrorControl"=dword:00000001
"ControlSet001\Services\vioser\ImagePath"="system32\\drivers\\vioser.sys"
"ControlSet001\Services\vioser\Group"="System Bus Extender"

"ControlSet001\Services\viorng\Type"=dword:00000001
"ControlSet001\Services\viorng\Start"=dword:00000000
"ControlSet001\Services\viorng\ErrorControl"=dword:00000001
"ControlSet001\Services\viorng\ImagePath"="system32\\drivers\\viorng.sys"
"ControlSet001\Services\viorng\Group"="System Bus Extender"

"ControlSet001\Services\qemufwcfg\Type"=dword:00000001
"ControlSet001\Services\qemufwcfg\Start"=dword:00000000
"ControlSet001\Services\qemufwcfg\ErrorControl"=dword:00000001
"ControlSet001\Services\qemufwcfg\ImagePath"="system32\\drivers\\qemufwcfg.sys"
"ControlSet001\Services\qemufwcfg\Group"="System Bus Extender"

"ControlSet001\Services\VioGpuDod\Type"=dword:00000001
"ControlSet001\Services\VioGpuDod\Start"=dword:00000000
"ControlSet001\Services\VioGpuDod\ErrorControl"=dword:00000001
"ControlSet001\Services\VioGpuDod\ImagePath"="system32\\drivers\\viogpudo.sys"
"ControlSet001\Services\VioGpuDod\Group"="Video"

; Disable common Xen PV drivers for KVM target
"ControlSet001\Services\xenvbd\Start"=dword:00000004
"ControlSet001\Services\xennet\Start"=dword:00000004
"ControlSet001\Services\xenvif\Start"=dword:00000004
"ControlSet001\Services\xeniface\Start"=dword:00000004
"ControlSet001\Services\xenbus\Start"=dword:00000004
"ControlSet001\Services\xendisk\Start"=dword:00000004
"ControlSet001\Services\xenfilt\Start"=dword:00000004
"ControlSet001\Services\xenagent\Start"=dword:00000004

; Critical device mappings for VirtIO block/SCSI
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1001\ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1001\Service"="viostor"
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1042\ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1042\Service"="viostor"
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1004\ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1004\Service"="vioscsi"
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1048\ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"
"ControlSet001\Control\CriticalDeviceDatabase\pci#ven_1af4&dev_1048\Service"="vioscsi"
"""


def generate_report(compare: Dict[str, Any]) -> str:
    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    sp = compare["source_detected"]
    tp = compare["target_detected"]

    def bullet(items: List[str]) -> str:
        return "- None detected\n" if not items else "".join(f"- {x}\n" for x in items)

    return f"""# Windows Cloud Boot Migration Report

Generated: {now}

## Source profile

| Field | Value |
|---|---|
| OS | {sp.get('os_name')} |
| Version | {sp.get('os_version')} |
| Firmware | {sp.get('firmware')} |
| BIOS vendor | {sp.get('bios_vendor')} |
| Manufacturer | {sp.get('manufacturer')} |
| Model | {sp.get('model')} |
| Partition styles | {', '.join(sp.get('partition_styles', []))} |
| Disk bus types | {', '.join(sp.get('disk_bus_types', []))} |
| NIC | {sp.get('nic_descriptions')} |

## Target profile

| Field | Value |
|---|---|
| OS | {tp.get('os_name')} |
| Version | {tp.get('os_version')} |
| Firmware | {tp.get('firmware')} |
| BIOS vendor | {tp.get('bios_vendor')} |
| Manufacturer | {tp.get('manufacturer')} |
| Model | {tp.get('model')} |
| Partition styles | {', '.join(tp.get('partition_styles', []))} |
| Disk bus types | {', '.join(tp.get('disk_bus_types', []))} |
| NIC | {tp.get('nic_descriptions')} |

## Risks

{bullet(compare.get('risks', []))}

## Missing target drivers on source

{bullet(compare.get('missing_target_drivers_on_source', []))}

## Missing target services on source

{bullet(compare.get('missing_target_services_on_source', []))}

## Recommended mode

`{compare.get('recommended_mode')}`

## Generated repair assets

- `repair_plan.json`
- `offline_registry_patch.reg`
- `firstboot-repair.ps1`
- `source_profile.json`
- `target_profile.json`

## Use this bundle

1. Snapshot/export the source Windows image.
2. Convert to target image format if required.
3. Mount the Windows image offline on Linux.
4. Copy target-cloud drivers into the mounted Windows image.
5. Import `offline_registry_patch.reg` into the offline SYSTEM hive using `reged`/`hivex`.
6. Place `firstboot-repair.ps1` at `C:\\cloudboot-migrator\\firstboot-repair.ps1`.
7. Register the firstboot script via `SetupComplete.cmd` or RunOnce.
8. Boot the image on the target cloud.
"""


def write_outputs(outdir: Path, source: Dict[str, Any], target: Dict[str, Any], compare: Dict[str, Any]) -> None:
    outdir.mkdir(parents=True, exist_ok=True)
    (outdir / "source_profile.json").write_text(json.dumps(source, indent=2), encoding="utf-8")
    (outdir / "target_profile.json").write_text(json.dumps(target, indent=2), encoding="utf-8")
    (outdir / "repair_plan.json").write_text(json.dumps(compare, indent=2), encoding="utf-8")
    (outdir / "offline_registry_patch.reg").write_text(generate_registry_patch(), encoding="utf-8")
    (outdir / "firstboot-repair.ps1").write_text(FIRSTBOOT_PS1_TEMPLATE, encoding="utf-8")
    (outdir / "report.md").write_text(generate_report(compare), encoding="utf-8")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Compare source/target Windows cloud boot configs and generate repair bundle.")
    p.add_argument("--source-host", required=True)
    p.add_argument("--source-user", required=True)
    p.add_argument("--source-port", type=int, default=22)
    p.add_argument("--source-key")
    p.add_argument("--source-winrm-host", help="Optional source WinRM/ServiceNet IP to try before --source-host for OpenSSH bootstrap.")
    p.add_argument(
        "--source-password-env",
        metavar="VAR",
        help="Read SSH password from this environment variable (requires sshpass on PATH).",
    )

    p.add_argument("--target-host", required=True)
    p.add_argument("--target-user", required=True)
    p.add_argument("--target-port", type=int, default=22)
    p.add_argument("--target-key")
    p.add_argument("--target-winrm-host", help="Optional target WinRM/ServiceNet IP to try before --target-host for OpenSSH bootstrap.")
    p.add_argument(
        "--target-password-env",
        metavar="VAR",
        help="Read SSH password from this environment variable (requires sshpass on PATH).",
    )

    p.add_argument("--outdir", default="./cloudboot_repair_bundle")
    p.add_argument(
        "--ssh-proxy-jump",
        metavar="USER@HOST",
        help="Bastion for both SSH collections (inner hop via ProxyCommand ssh -W %%h:%%p). Example: ubuntu@104.130.29.126",
    )
    p.add_argument("--from-json-source", help="Use existing source_profile.json instead of SSH collection.")
    p.add_argument("--from-json-target", help="Use existing target_profile.json instead of SSH collection.")
    return p.parse_args()


def load_json(path: str) -> Dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def _ssh_password_from_env(var: Optional[str], role: str) -> Optional[str]:
    if not var:
        return None
    if var not in os.environ:
        raise SystemExit(f"--{role}-password-env: environment variable {var!r} is not set.")
    val = os.environ[var]
    if not val:
        raise SystemExit(f"--{role}-password-env: {var!r} is empty.")
    return val


def main() -> int:
    args = parse_args()

    source_pw = _ssh_password_from_env(args.source_password_env, "source")
    target_pw = _ssh_password_from_env(args.target_password_env, "target")

    source_spec = HostSpec(
        "source",
        args.source_host,
        args.source_user,
        args.source_port,
        args.source_key,
        password=source_pw,
        winrm_host=args.source_winrm_host,
    )
    target_spec = HostSpec(
        "target",
        args.target_host,
        args.target_user,
        args.target_port,
        args.target_key,
        password=target_pw,
        winrm_host=args.target_winrm_host,
    )

    jump = (args.ssh_proxy_jump or "").strip() or None

    print(f"[cloudboot] migrator rev={_TRANSPORT_REV} ({Path(__file__).resolve()})", flush=True)

    print("[cloudboot] Collecting source profile...")
    source = (
        load_json(args.from_json_source)
        if args.from_json_source
        else ssh_powershell_json(source_spec, COLLECT_PS1, proxy_jump=jump)
    )

    print("[cloudboot] Collecting target profile...")
    target = (
        load_json(args.from_json_target)
        if args.from_json_target
        else ssh_powershell_json(target_spec, COLLECT_PS1, proxy_jump=jump)
    )

    print("[cloudboot] Comparing profiles...")
    compare = compare_profiles(source, target)

    outdir = Path(args.outdir)
    print(f"[cloudboot] Writing repair bundle: {outdir}")
    write_outputs(outdir, source, target, compare)

    print("[cloudboot] Done.")
    print(f"  Report: {outdir / 'report.md'}")
    print(f"  Plan:   {outdir / 'repair_plan.json'}")
    print(f"  Patch:  {outdir / 'offline_registry_patch.reg'}")
    print(f"  First boot script: {outdir / 'firstboot-repair.ps1'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
