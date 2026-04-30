# Windows Boot Config Comparison (OSPC vs FLEX)

Generated: 2026-04-23

## Summary Table

| VM | Cloud | IP | Reachability | Partition Style | Boot Partition | Volume Label | viostor | netkvm | BCD Loader Path | Notes |
|---|---|---|---|---|---|---|---|---|---|---|
| windows2016 | OSPC | `104.130.26.194` | Collected via WinRM | MBR | Disk0/Part1 (`C:`), `IsBoot=True`, `IsSystem=True` | `System` | Not returned (service query blank) | Not returned (service query blank) | `\windows\system32\winload.exe` | Single-partition MBR boot layout |
| win2019 | OSPC | `23.253.159.97` | Collected via WinRM | MBR | Disk0/Part1 (`C:`), `IsBoot=True`, `IsSystem=True` | `System` | Not returned (service query blank) | Not returned (service query blank) | `\windows\system32\winload.exe` | Single-partition MBR boot layout |
| windows2016 | FLEX | `146.20.61.130` | Collected via RDP/console PowerShell | MBR | Disk0/Part2 (`C:`), `IsBoot=True`, `IsSystem=True`; Disk0/Part1 recovery | `Boot,System` | `Start=0` | `Start=3` | `\Windows\system32\winload.exe` | VirtIO SCSI boot disk; `vioscsi Start=0` |
| win2019 | FLEX | Not recorded | Collected via RDP/console PowerShell | MBR | Disk0/Part2 (`C:`), `IsBoot=True`, `IsSystem=True`; Disk0/Part1 recovery | Not captured | `Start=0` | `Start=3` | `\Windows\system32\winload.exe` | Same FLEX boot/storage shape as 2016; `vioscsi Start=0` |

## OSPC Collected Details

- `windows2016` (`104.130.26.194`)
  - Disk: `MBR`, 40 GB, Online
  - Partition: only partition is `C:`, Boot+System
  - BCD loader path: `\windows\system32\winload.exe`

- `win2019` (`23.253.159.97`)
  - Disk: `MBR`, 40 GB, Online
  - Partition: only partition is `C:`, Boot+System
  - BCD loader path: `\windows\system32\winload.exe`

## Migration Repair Implications

- OSPC sources are classic BIOS/MBR-style (`winload.exe`), not UEFI (`winload.efi`).
- FLEX target should preserve boot mode compatibility (BIOS/MBR) unless explicit conversion is performed.
- VirtIO services must remain present/started on FLEX (`viostor`, `netkvm`; optionally `vioscsi` if controller type changes).

## FLEX Collected Details

- `windows2016` (`146.20.61.130`)
  - Disk: `Red Hat VirtIO SCSI`, `MBR`, 80 GB, Online
  - Partitions: Disk0/Part1 Recovery 1 GB; Disk0/Part2 `C:` Boot+System
  - BCD boot manager: `device partition=C:`
  - BCD loader: `device partition=C:`, `osdevice partition=C:`, `\Windows\system32\winload.exe`
  - Storage drivers: `viostor=0`, `vioscsi=0`, `disk=0`, `partmgr=0`, `volmgr=0`, `volsnap=0`, `mountmgr=0`

- `win2019` (IP not recorded in pasted scan)
  - Disk: `Red Hat VirtIO SCSI`, `MBR`, 80 GB, Online
  - Partitions: Disk0/Part1 Recovery 1 GB; Disk0/Part2 `C:` Boot+System
  - BCD boot manager: `device partition=C:`
  - BCD loader: `device partition=C:`, `osdevice partition=C:`, `\Windows\system32\winload.exe`
  - Storage drivers: `viostor=0`, `vioscsi=0`, `disk=0`, `partmgr=0`, `volmgr=0`, `volsnap=0`, `mountmgr=0`

## Remaining Data Needed (FLEX)

Run on each FLEX VM and capture output:

```powershell
bcdedit /enum all
Get-Disk
Get-Partition
Get-Volume
Get-Service viostor,netkvm,vioscsi
```
