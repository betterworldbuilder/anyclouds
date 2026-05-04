$ErrorActionPreference = "Continue"

function Emit($Name, $Value) {
  Write-Output ("{0}={1}" -f $Name, $Value)
}

$services = @("viostor","vioscsi","netkvm","storahci","pciide","intelide","disk","partmgr","volmgr","mountmgr")
foreach ($svc in $services) {
  $path = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
  if (Test-Path $path) {
    try {
      $item = Get-ItemProperty -Path $path -ErrorAction Stop
      Emit "SERVICE.$svc.Start" $item.Start
      Emit "SERVICE.$svc.Group" ($item.Group -as [string])
    } catch {
      Emit "SERVICE.$svc.Error" $_.Exception.Message
    }
  } else {
    Emit "SERVICE.$svc.Missing" "1"
  }
}

$drivers = pnputil /enum-drivers 2>&1 | Out-String
if ($drivers -match "viostor|vioscsi|NetKVM|Red Hat") {
  Emit "DRIVER_MATCH" "1"
} else {
  Emit "DRIVER_MATCH" "0"
}

try {
  $disks = Get-Disk -ErrorAction SilentlyContinue | Format-Table Number,FriendlyName,BusType,OperationalStatus,PartitionStyle -Auto | Out-String
  $disks.TrimEnd() | Write-Output
} catch {
  Emit "DISK_ENUM_ERROR" $_.Exception.Message
}

try {
  $pnp = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match "VirtIO|Red Hat|SCSI|Storage|Disk" } | Format-Table -Auto | Out-String
  $pnp.TrimEnd() | Write-Output
} catch {
  Emit "PNP_ENUM_ERROR" $_.Exception.Message
}

if (Test-Path "C:\ospc2flex_v2_bootstrap_success.txt") {
  Emit "BOOTSTRAP_MARKER" "1"
} else {
  Emit "BOOTSTRAP_MARKER" "0"
}
