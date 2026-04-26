# Windows Boot Config Comparison (OSPC vs FLEX)

Generated: 2026-04-23

## Summary Table

| VM | Cloud | IP | Reachability | Partition Style | Boot Partition | Volume Label | viostor | netkvm | BCD Loader Path | Notes |
|---|---|---|---|---|---|---|---|---|---|---|
| windows2016 | OSPC | `104.130.26.194` | Collected via WinRM | MBR | Disk0/Part1 (`C:`), `IsBoot=True`, `IsSystem=True` | `System` | Not returned (service query blank) | Not returned (service query blank) | `\windows\system32\winload.exe` | Single-partition MBR boot layout |
| win2019 | OSPC | `23.253.159.97` | Collected via WinRM | MBR | Disk0/Part1 (`C:`), `IsBoot=True`, `IsSystem=True` | `System` | Not returned (service query blank) | Not returned (service query blank) | `\windows\system32\winload.exe` | Single-partition MBR boot layout |
| windows2016 | FLEX | `50.56.159.92` | Console-only evidence (no WinRM) | Unknown (need `Get-Disk`) | `C:` shown as Boot/System in screenshot | `Boot,System` (from screenshot output) | Running (from screenshot) | Running (from screenshot) | Not collected yet | Need `bcdedit /enum all`, `Get-Disk`, `Get-Partition` |
| win2019 | FLEX | `50.56.159.81` | Not collected yet | Unknown | Unknown | Unknown | Unknown | Unknown | Unknown | Need full command output |

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

## Remaining Data Needed (FLEX)

Run on each FLEX VM and capture output:

```powershell
bcdedit /enum all
Get-Disk
Get-Partition
Get-Volume
Get-Service viostor,netkvm,vioscsi
```

