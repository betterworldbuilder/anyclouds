$ErrorActionPreference = "Continue"
$LogDir = "C:\ospc2flex"
$Log = Join-Path $LogDir "windows_v2_firstboot.log"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Log($Message) {
  $line = "$(Get-Date -Format o) $Message"
  Write-Host $line
  Add-Content -Path $Log -Value $line
}

Log "OSPC2FLEX Windows V2 firstboot started"

$os = Get-CimInstance Win32_OperatingSystem
Log "OS Caption: $($os.Caption)"
Log "OS Version: $($os.Version)"

$DriverRoots = @(
  "D:\",
  "E:\",
  "F:\",
  "C:\ospc2flex\virtio",
  "C:\virtio"
)

$DriverRoot = $null
foreach ($root in $DriverRoots) {
  if (-not (Test-Path $root)) { continue }
  $probe = Get-ChildItem -Path $root -Recurse -Filter "*.inf" -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match "viostor|vioscsi|NetKVM|Balloon|pvpanic|qemufwcfg" } |
    Select-Object -First 1
  if ($probe) {
    $DriverRoot = $root
    break
  }
}

if (-not $DriverRoot) {
  Log "ERROR: VirtIO driver root not found"
  exit 20
}

Log "Using VirtIO driver root: $DriverRoot"

$wanted = @("viostor", "vioscsi", "NetKVM", "Balloon", "pvpanic", "qemufwcfg")
foreach ($name in $wanted) {
  $infs = Get-ChildItem -Path $DriverRoot -Recurse -Filter "*.inf" -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match $name }
  foreach ($inf in $infs) {
    Log "Installing driver INF: $($inf.FullName)"
    pnputil.exe /add-driver "$($inf.FullName)" /install | Tee-Object -FilePath $Log -Append
  }
}

$services = @(
  "viostor","vioscsi","netkvm","Balloon","pvpanic","qemufwcfg",
  "storahci","pciide","intelide","disk","partmgr","volmgr","mountmgr"
)
foreach ($svc in $services) {
  $path = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
  if (-not (Test-Path $path)) {
    Log "WARN: service key not found: $svc"
    continue
  }
  try {
    Set-ItemProperty -Path $path -Name Start -Type DWord -Value 0 -ErrorAction SilentlyContinue
    Log "Set $svc Start=0"
  } catch {
    Log "WARN: could not set $svc Start=0: $_"
  }
  $override = Join-Path $path "StartOverride"
  if (Test-Path $override) {
    try {
      Remove-Item -Path $override -Recurse -Force -ErrorAction SilentlyContinue
      Log "Removed $svc StartOverride"
    } catch {
      Log "WARN: could not remove $svc StartOverride: $_"
    }
  }
}

try {
  bcdedit /deletevalue "{current}" safeboot | Tee-Object -FilePath $Log -Append
} catch {
  Log "safeboot deletevalue ignored: $_"
}

try {
  bcdedit /set "{current}" detecthal yes | Tee-Object -FilePath $Log -Append
} catch {
  Log "detecthal set ignored: $_"
}

try {
  Get-NetAdapter -ErrorAction SilentlyContinue | ForEach-Object {
    Log "Adapter: $($_.Name) Status=$($_.Status) InterfaceDescription=$($_.InterfaceDescription)"
  }
  Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne "Disabled" } | ForEach-Object {
    try {
      Set-NetIPInterface -InterfaceAlias $_.Name -Dhcp Enabled -ErrorAction SilentlyContinue
      Set-DnsClientServerAddress -InterfaceAlias $_.Name -ResetServerAddresses -ErrorAction SilentlyContinue
      Log "Enabled DHCP on adapter $($_.Name)"
    } catch {
      Log "WARN: DHCP enable failed on $($_.Name): $_"
    }
  }
} catch {
  Log "WARN: NetAdapter block failed: $_"
}

try {
  Enable-PSRemoting -Force | Tee-Object -FilePath $Log -Append
  Set-Item WSMan:\localhost\Service\AllowUnencrypted $true -ErrorAction SilentlyContinue
  Set-Item WSMan:\localhost\Service\Auth\Basic $true -ErrorAction SilentlyContinue
  Enable-NetFirewallRule -DisplayGroup "Windows Remote Management" -ErrorAction SilentlyContinue
  Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
  Enable-NetFirewallRule -DisplayName "File and Printer Sharing (Echo Request - ICMPv4-In)" -ErrorAction SilentlyContinue
} catch {
  Log "WARN: remote access enable failed: $_"
}

try {
  $disks = Get-Disk -ErrorAction SilentlyContinue
  $disks | Format-Table Number,FriendlyName,BusType,OperationalStatus,PartitionStyle -Auto | Out-String | Set-Content -Path "C:\ospc2flex\disk_after_v2.txt"
  $pnps = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match "VirtIO|Red Hat|SCSI|Storage|Disk" }
  $pnps | Format-Table -Auto | Out-String | Set-Content -Path "C:\ospc2flex\pnp_after_v2.txt"
} catch {
  Log "WARN: disk or PnP enumeration failed: $_"
}

driverquery /v | Out-File "C:\ospc2flex\driverquery_after_v2.txt"
pnputil /enum-drivers | Out-File "C:\ospc2flex\pnputil_enum_after_v2.txt"
bcdedit /enum all | Out-File "C:\ospc2flex\bcd_after_v2.txt"

"OK $(Get-Date -Format o)" | Out-File "C:\ospc2flex_v2_bootstrap_success.txt"
Log "OSPC2FLEX Windows V2 firstboot completed successfully"
