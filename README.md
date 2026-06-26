# 🚀 CLOUD FLEX UPLOAD MISSION CONTROL

Any OpenStack Cloud to FLEX Migration Full Cycle Mission Control

Browser-based orbital migration cockpit for safely jumping Rackspace OpenStack Private Cloud (OSPC) workloads into the modern Rackspace FLEX atmosphere.

Move the customers who trusted Rackspace OpenStack Private Cloud into the next Rackspace cloud chapter: FLEX.

CloudJumper is a migration cockpit for discovering OSPC estates, translating their topology, moving their VM images, repairing old guest operating systems, and validating workloads on Rackspace FLEX. It is built for the practical middle of migration work: the place where APIs, snapshots, old kernels, customer timelines, and operator judgment all meet.

*(The full historical telemetry and operator manual has been restored in `README.long.MD`)*

## 🛰️ Mission Capabilities (What It Does)

CloudJumper is a browser-based control room for OSPC to FLEX migration. It brings together:

- **Deep Space Recon**: OSPC and FLEX discovery.
- **Flight Path Tracking**: Customer migration tracking.
- **Orbital Mechanics**: Topology import, design, validation, deploy, and rollback.
- **Zero-G Image Transport**: VM image migration through a jumphost using NBD, Glance, Cloud Files, and `qemu-img`.
- **Private Snapshot Migration**: Browser-driven Linux, Windows, and Volume snapshot migration from OSPC to FLEX — no Glance round-trip, no qcow2 conversion, streamed directly to FLEX Cinder.
- **FLEX2FLEX Region Cloning**: FLEX region-to-region cloning for private Glance images, Linux snapshots, Windows snapshots, bootable volume snapshots, data volume snapshots, and DB volume snapshots.
- **FLEX Anywhere Hyperscaler Bridge (WIP)**: A cloned mission-control surface for AWS, Azure, and GCP image/snapshot/volume movement to and from FLEX using the proven snapshot table, per-job terminal, and batch controls.
- **In-Flight Pod Repair**: Linux offline repair (Ubuntu, Debian, CentOS, RHEL, Rocky, AlmaLinux) and Windows offline VirtIO repair/snapshot-based migration.
- **Mission Telemetry**: Batch job telemetry in the MBUX/Apollo dashboard.
- **Atmospheric Re-entry**: SSH/UAT verification, reports, and J.A.R.V.I.S. audio alerts.
- **Tenant IaC DR Pack**: Preflight checks, target cloud credential profile, OpenRC import, restore-plan overlays, and Git/S3 backup export for cross-region or cross-cloud restore.

## ✨ Latest Features

### Discovery Dashboard (`/dashboard/`)

The Discovery stage now includes a full TCO (Total Cost of Ownership) analysis engine:

- **Auto-load Flavor Map**: The dashboard automatically loads the `flavormap.csv` generated in Stage 1 without any manual upload. Data is cached in `sessionStorage` so iframe reloads do not re-fetch.
- **OSPC Price List Upload**: Upload a CSV with server-level monthly cost data to override the default pricing assumption with real OSPC billing data.
- **FLEX Price List Upload**: Upload a CSV with FLEX flavor hourly rates to compute accurate target-side monthly costs.
- **2.45× Fallback Assumption**: When no OSPC price list is present, OSPC cost is assumed to be **2.45× more expensive** than FLEX. An amber warning note is shown in the UI whenever this fallback is active.
- **Price List Upload Panel**: Appears automatically once a flavor map is loaded. Shows file metadata and current load state for both OSPC and FLEX price lists.

TCO calculation logic:
| Source | Method |
|---|---|
| FLEX monthly cost | FLEX Price List CSV (hourly × 730) or flavor-match lookup |
| OSPC monthly cost | OSPC Price List CSV (sum of `monthly_cost_usd`) or FLEX cost × 2.45 fallback |
| Savings | OSPC monthly − FLEX monthly |

### UAT Dashboard (Stage 3)

The UAT cutover readiness dashboard has been significantly upgraded:

#### TCO Chart — Price List Uploads
The UAT TCO Cost Estimation chart now supports inline price list overrides directly from the dashboard:
- **⬆ OSPC Price List** button — upload a CSV with real OSPC monthly billing data to override the 2.45× estimate
- **⬆ FLEX Price List** button — upload a CSV with FLEX hourly rates to compute accurate FLEX monthly cost
- Amber warning note when the 2.45× fallback is active
- Price overrides are applied immediately and update the chart: Source Monthly Cost, Target Monthly Cost, Monthly Savings, and Savings %

#### UAT DB Compare
- Side-by-side database comparison between OSPC and FLEX target servers
- User database enumeration (excludes system DBs)
- Row count comparison with mismatch highlighting
- Full table diff view per database

#### Cutover Scanner — Full-Width Table
- Cutover readiness scanner now renders as a full-width table
- Improved layout for long server lists and multi-column scan results

#### Sidebar Cleanup
- Removed the "Environment: UAT / Admin User" footer section from the UAT sidebar for a cleaner operator view

#### PASS / FIX Buttons
- **PASS** (green): Proceeds with cutover, with risk-acceptance prompt if blockers remain
- **FIX** (red): Active — scrolls to the blockers and next-action panel showing all unresolved items
- Buttons are flat rectangle style matching the design template

#### Cutover Readiness Engine
The readiness analysis engine evaluates:
- Critical systems tested
- No open critical issues
- Data validation checklist passed
- App health check passed
- Database validation (scope-aware — skipped when DB is out of scope)
- Reports & outputs verified
- Performance validation (with per-metric user decisions: Pass / Fail / Accept Risk / Not Applicable)
- Service comparison gaps (hard blocks vs. review gaps vs. warnings)

Status output: **READY FOR CUTOVER** / **READY WITH CONDITIONS** / **NEED REVIEW BEFORE CUT OVER**

## New: FLEX Region Cloning And FLEX Anywhere

### FLEX2FLEX Region Cloning

The **FLEX2FLEX Region Cloning** workflow copies FLEX resources from one FLEX region to another while preserving the source. It creates new target-region resource IDs and records the mapping in the job terminal.

| Source type | Target result | Purpose |
|---|---|---|
| Linux image snapshot | New Linux image in target FLEX region | Rebuild Linux VM in another region |
| Windows image snapshot | New Windows image in target FLEX region | Rebuild Windows VM, including virtio-ready images |
| Bootable volume snapshot | New bootable volume in target region | Restore VM boot disk |
| Data volume snapshot | New data volume in target region | Restore application data |
| DB volume snapshot | New DB volume in target region | Restore or test database recovery |

How it works:

1. Select the source FLEX region and scan private source snapshots.
2. Choose Linux Snapshots, Windows Snapshots, or Volume Snapshots rows from the same migration table pattern used by OSPC2FLEX.
3. Pick the target FLEX region.
4. Run the clone job. The workflow tries direct Glance-to-Glance regional copy first.
5. If the provider blocks direct import, the workflow falls back to the proven jumphost stream method.
6. For volume snapshots, the path reuses the OSPC2FLEX volume snapshot remount/attach process, adapted for FLEX source and FLEX target regions.
7. Validate the result from the per-job terminal, including source snapshot ID, new target image/volume ID, target VM/server details, clone status, and attach or mount result.

Operational notes:

- Source FLEX resources are not deleted or changed.
- FLEX Glance image IDs are region-scoped; the target region always receives a newly created image ID.
- Table selections, common field inputs, and per-row choices are cached in the browser.
- Start Fresh and Stop Batch controls are available for image, Windows, and volume batches.
- Direct Glance import is still provider-dependent; the jumphost fallback remains the reliable path for large images or blocked web-download imports.

### FLEX Anywhere Hyperscaler Bridge (WIP)

The **FLEX Anywhere / HYPER FLEX** workflow is a work-in-progress bridge for moving images, snapshots, and volume artifacts between FLEX and AWS, Azure, or GCP. It intentionally reuses the FLEX2FLEX mission-control layout and the existing batch/job wiring before adding provider-specific logic.

Supported directions being wired:

| Direction | Source artifacts | Target artifacts |
|---|---|---|
| AWS to FLEX | AMI, EBS snapshot, exported disk image | FLEX image or FLEX volume |
| Azure to FLEX | Managed disk, snapshot, VHD | FLEX image or FLEX volume |
| GCP to FLEX | Image, persistent disk snapshot | FLEX image or FLEX volume |
| FLEX to AWS | FLEX image or volume | AMI, EBS snapshot, or imported disk |
| FLEX to Azure | FLEX image or volume | Managed disk, snapshot, or VHD |
| FLEX to GCP | FLEX image or volume | GCP image or persistent disk snapshot |

Hyperscaler credential/input sections planned in the UI:

- Migration direction: hyperscaler to FLEX, FLEX to hyperscaler, or bidirectional planning.
- Provider selector: AWS, Azure, or GCP.
- FLEX credentials: existing OpenRC/Auth URL, username, password, project, domain, and region fields.
- AWS inputs: access key, secret key, profile, role ARN, account ID, source/target region, S3 bucket, AMI ID, EBS snapshot ID, instance type, subnet/security group, and key pair.
- Azure inputs: tenant ID, subscription ID, client ID, client secret, resource group, source/target region, storage account/container, managed disk ID, snapshot ID, VM size, VNet/subnet, and SSH key.
- GCP inputs: project ID, service account JSON, source/target region or zone, Cloud Storage bucket, image ID, disk snapshot ID, machine type, VPC/subnet, and SSH key.
- Artifact options: image format, OS family, boot/data/DB volume type, target name prefix, and validation mode.

Rackspace hyperscaler account links for operators:

- AWS accounts: <https://manage.rackspace.com/aws/accounts>
- GCP accounts: <https://manage.rackspace.com/gcp>
- Azure enrollment: <https://manage.rackspace.com/azure/enrollment>

Status: **WIP**. The page, provider credential sections, account access links, and operator flow are being added first. Provider-specific export/import adapters should be implemented by extending the working FLEX2FLEX and OSPC2FLEX paths, not by replacing them.

## 🌌 The "Why" and "So What"

**Why:** OSPC was a powerful chapter in Rackspace cloud history. It gave customers dedicated OpenStack environments, real control, familiar APIs, and the confidence of a managed private cloud. But platforms age. Images accumulate assumptions. Networks drift. Kernels, initramfs, cloud-init, virtio drivers, static routes, bootloaders, and application dependencies all remember the cloud they came from. FLEX is the forward path: modern Rackspace cloud capacity, newer operating models, cleaner automation targets, and a better place for customers to keep building. The challenge is carrying customer trust forward without losing the details that make their workloads boot, connect, and serve traffic.

**So What:** Migration should not feel like a blind leap from one console to another. CloudJumper turns migration into an observable workflow:
- See the source estate before you move it.
- Map the target before you build it.
- Generate scripts instead of hand-copying commands.
- Repair guest images before first boot instead of debugging every failure live.
- Track every VM, image, upload, and jumphost signal from one place.
- Keep rollback and verification close to the work.

The result is fewer mystery failures, faster test boots, cleaner customer updates, and a migration path that feels engineered instead of improvised.

## 🚀 Full-Cycle Migration Phases (How)

CloudJumper works as a full-cycle migration Mission Control. Each stage turns unknowns into artifacts: CSVs, maps, scripts, repaired images, booted test instances, verification results, and rollback path

| Phase | Stage | Mission Control Function | Benefit |
|:---:|---|---|---|
| 📡 | 0. Customer Tracker | Tracks customer, estate, status, and active migration context. | Keeps multiple migrations organized without losing the human thread. |
| 🔭 | 1. Discovery | Scans OSPC and FLEX inventory: servers, images, networks, etc. | Builds a factual source-of-truth before anyone starts changing infrastructure. |
| 🗺️ | 2. Select & Execute R-Path | **Gartner 7R Governance**: Strategic selection of Retain, Retire, Rehost, Replatform, or Refactor paths. | Turns "what do we have?" into a strategic "where should it go?" decision based on business value. |
| 🧪 | 3. Validation & UAT | Creates FLEX test instances, checks connectivity, and streams logs. | Changes "the image uploaded" into "the workload is alive." |
| ✂️ | 4. Cutover | Final validation and live traffic shift using cutover scripts. | Gives the migration a controlled finish line instead of a nervous handoff. |
| 🏁 | 5. Post-Migration | Final documentation, infrastructure clean-up, and handoff. | Delivers a modernized, production-ready environment. |
| 💰 | 6. TCO / FinOps | Cost tracking and cloud optimization telemetry for the new environment. | Provides immediate visibility into cost savings and resource utilization. |
| 🛡️ | 7. IAC Backup & Restore | Automated generation of IAC backup and DR restore packs. | Ensures the new environment is protected and recoverable from day one. |
| 🚀 | 8. GitOps / OpenCenter | Integration with OpenCenter and GitOps-driven deployment models. | Moves from manual management to automated, version-controlled operations. |
| 🤖 | 9. AI OPS | Context pack generation for AI-driven predictive maintenance. | Prepares the platform for advanced automation and AI-assisted troubleshooting. |

### How narrative phases map to the Mission Control UI

The top bar uses **Customer List** (tracker) plus **Stages 1–9**: Discovery, Migration, Validation & UAT, Cutover, Post-Migration output bundle, TCO/FinOps baseline/right-size, **IAC Backup & Restore (Terraform + Ansible)**, **GitOps / OpenCenter**, and **AI OPS**. The **0–9** table above is the *full lifecycle story*; phases **3–6** (generate, rehost, image repair, Kubernetes) surface mainly inside **Stage 2 (Migration)** and its subtabs, while **7–9** align with post-migration handoff and continuous operations.

The dashboard is not only a launcher. It is an evidence machine. Every scan, map, run log, repair log, manifest, and verification table becomes data that can feed the next automation layer.

### 1. Linux VM Migration Process

`mig_worker_v4.sh` — NBD/DD direct disk read over SSH.

| Stage | What Happens | Where | Estimated Time (80 GB) |
|-------|-------------|-------|----------------------|
| **Step 1** | OSPC auth → find VM → check disk size | Jumphost → OSPC API | < 1 min |
| **Step 2** | SSH tunnel → `qemu-nbd` exposes remote disk as local NBD device | Jumphost ↔ Linux VM | < 1 min |
| **Step 3** | `dd` reads NBD device to `.img` at ~50–80 MB/s | Linux VM → Jumphost | ~20–30 min |
| **Step 4** | `qemu-img convert` raw → qcow2 | Jumphost (local) | 5–10 min |
| **Step 5** | Offline guest repair: bootloader, fstab, virtio drivers, network config | Jumphost (local) | 3–5 min |
| **Step 6** | Upload qcow2 to FLEX Glance | Jumphost → FLEX cloud | 10–20 min |
| **Step 7** | Boot VM from image | FLEX cloud (server-side) | 2–3 min |
| **Step 8** | Assign floating IP | FLEX cloud (server-side) | < 1 min |
| **TOTAL** | | | ~45–70 min |

## Current Migration Method Tables

### VM Migration Methods

| OS type | Versions covered | Current method | Dashboard section | Main script/path | Status |
|---|---|---|---|---|---|
| Linux VM | Ubuntu 20.04, Ubuntu 22.04, Ubuntu 24.04, Debian 10/11/12, CentOS 7, RedHat 6/8, Rocky 8/9, AlmaLinux 8/9 | Live VM/NBD migration | Live Server VM Migration method | `mig_worker_v4.sh` / Linux live VM path | Ready |
| Windows VM | Windows Server 2016, Windows Server 2019 | Windows live VM migration | Live Server VM Migration method | `ospc2flex_windows_migrate.sh` | Under test |

### Snapshot Migration Methods

| Snapshot type | OS versions covered | Current method | Dashboard section | Main script/path | Status |
|---|---|---|---|---|---|
| Linux private VM snapshot | Ubuntu 20.04, Ubuntu 22.04, Debian 10/11/12, CentOS 7, RedHat 6/8, Rocky 8/9, AlmaLinux 8/9 | Linux snapshot migration | SNAPSHOT migration → Linux Snapshots | `ospc2flex_linux_snap_migrate.sh` | Ready |
| Ubuntu 24 private VM snapshot | Ubuntu 24.04 | Use VM migration instead | Live Server VM Migration method | `mig_worker_v4.sh` / Linux live VM path | Use VM path |
| Windows private VM snapshot | Windows Server 2016, Windows Server 2019 | SNAPWIN / Method Z existing snapshot | SNAPSHOT migration → Windows Snapshots | `ospc2flex_windows_method_z_snapshot_existing.sh` | Ready |
| Linux volume snapshot | Linux volume snapshots for the supported Linux target set | Volume-Snapshot-Mig direct Cinder stream | SNAPSHOT migration → Volume Snapshots | `ospc2flex_volsnap_migrate.sh` | Ready |
| Windows volume snapshot | Windows Server 2016, Windows Server 2019 volume snapshots | Volume-Snapshot-Mig using Windows volume helper | SNAPSHOT migration → Volume Snapshots | `ospc2flex_volsnap_migrate.sh` | Under test |

### OS Coverage Matrix

| OS / version | VM migration | Private snapshot migration | Volume snapshot migration |
|---|---|---|---|
| Ubuntu 20.04 | Live VM/NBD | Linux snapshot migration | Linux Volume-Snapshot-Mig |
| Ubuntu 22.04 | Live VM/NBD | Linux snapshot migration | Linux Volume-Snapshot-Mig |
| Ubuntu 24.04 | Live VM/NBD primary | Use VM migration instead | Linux Volume-Snapshot-Mig when target VM ID/IP are supplied |
| Debian 10 | Live VM/NBD | Linux snapshot migration | Linux Volume-Snapshot-Mig |
| Debian 11 | Live VM/NBD | Linux snapshot migration | Linux Volume-Snapshot-Mig |
| Debian 12 | Live VM/NBD | Linux snapshot migration | Linux Volume-Snapshot-Mig |
| CentOS 7 | Live VM/NBD | Linux snapshot migration | Linux Volume-Snapshot-Mig |
| RedHat 6 | Live VM/NBD | Linux snapshot migration | Linux Volume-Snapshot-Mig |
| RedHat 8 | Live VM/NBD | Linux snapshot migration | Linux Volume-Snapshot-Mig |
| Rocky 8 | Live VM/NBD | Linux snapshot migration | Linux Volume-Snapshot-Mig |
| Rocky 9 | Live VM/NBD | Linux snapshot migration | Linux Volume-Snapshot-Mig |
| AlmaLinux 8 | Live VM/NBD | Linux snapshot migration | Linux Volume-Snapshot-Mig |
| AlmaLinux 9 | Live VM/NBD | Linux snapshot migration | Linux Volume-Snapshot-Mig |
| Windows Server 2016 | Windows live VM migration under test | SNAPWIN / Method Z | Windows Volume-Snapshot-Mig under test |
| Windows Server 2019 | Windows live VM migration under test | SNAPWIN / Method Z | Windows Volume-Snapshot-Mig under test |

### 3. Private Server Volume Snapshot Migration

The **Private Server Volume Snapshot Migration Table** (`image_migrator.html`) is a browser-native snapshot migration cockpit. It scans all OSPC private snapshots and organises them into three dedicated tabs:

| Tab | Content | Migration Script |
|-----|---------|-----------------|
| 🐧 Linux Snapshots | Non-Windows, non-volume OSPC snapshots | `ospc2flex_linux_snap_migrate.sh` |
| 🪟 Windows Snapshots | Windows private snapshots | `ospc2flex_windows_method_z_snapshot_existing.sh` |
| 📦 Volume Snapshots | OSPC Cinder volume snapshots | `ospc2flex_volsnap_migrate.sh` |

All three tabs share:
- Per-row **Select** checkbox + select-all toggle
- **No image resume** checkbox (force fresh start, per-row + select-all toggle)
- Sortable columns (▲/▼/⇅) on all fields: type, snapshot name, ID, source VM, OS distro, size, format, status, migratable, licensed, method, reason, created date
- **Export CSV** button next to summary stats line
- Real-time SSE log stream per snapshot in the results panel below the table

#### 3a. Linux Snapshot Migration Pipeline

`ospc2flex_linux_snap_migrate.sh` — staged on jumphost, streamed over SSH.

Each selected Linux snapshot is migrated independently. The script handles OSPC auth, snapshot-to-image staging, download to jumphost, offline Linux repair (bootloader, fstab, virtio drivers, network), upload to FLEX Glance, and FLEX instance boot.

#### 3a-1. Snapshot vs VM Migration OS Method Matrix

Use snapshot migration for the operating systems below unless the table explicitly says otherwise. Ubuntu 24 is the known exception: use the live VM/NBD migration path for Ubuntu 24 workloads.

| OS / Distro | `os_type` | Snapshot Migration Method | VM Migration Method | Notes |
|---|---|---|---|---|
| Ubuntu 20 | `ubuntu20` / `ubuntu` | Works | Works | Snapshot/Cloud Files path OK |
| Ubuntu 22 | `ubuntu22` | Works | Works | Cloud Files export/download confirmed |
| Ubuntu 24 | `ubuntu24` | Do not use | Works only | Use NBD Inline Live / VM migration |
| Debian 10 | `debian10` | Works | Works | Snapshot path OK |
| Debian 11 / 12 | `debian11` / `debian12` | Expected works | Works | Same Debian family handling |
| Rocky 8 | `rocky8` | Works | Works | Same Rocky repair path |
| Rocky 9 | `rocky9` | Works | Works | Cloud Files download confirmed |
| AlmaLinux 8 | `alma8` | Works | Works | Same Alma repair path |
| AlmaLinux 9 | `alma9` / `almalinux` | Works | Works | Snapshot flow confirmed through upload/boot path |
| CentOS 7 | `centos7` | Works | Works | Cloud Files download confirmed |
| CentOS 8 / 9 / Stream 9 | `centos8`, `centos9`, `centosstream9` | Expected works | Works | Same CentOS family handling |
| RHEL 7 / 8 / 9 | `rhel7`, `rhel8`, `rhel9` | Expected works | Works | Supported by NBD defaults; snapshot family maps like RHEL/CentOS |
| Windows Server 2016 | `windows2016` / `windows` | Works | Works with Windows methods | Use Windows Snapshot Mig / Method Z path |
| Windows Server 2019 | `windows2019` / `windows` | Works | Works with Windows methods | Use Windows Snapshot Mig / Method Z path |

Quick routing rule:

| Case | Use |
|---|---|
| Ubuntu 24 / `u24*` / `postgresqlU24` / `u24clean` | VM Migration: NBD Inline Live |
| Windows Server 2016 / 2019 | Snapshot Migration |
| Other supported Linux images | Snapshot Migration preferred |

#### 3b. Windows Snapshot Migration Pipeline

`ospc2flex_windows_method_z_snapshot_existing.sh` — triggered via **Windows Snapshot Mig** button.

Applies Method Z: uses an existing OSPC snapshot, injects VirtIO drivers offline, corrects Xen service start values (`xendisk Start=0`, `XENFILT` on SCSI class), repairs the Windows registry for VirtIO class filters and PnP mappings, uploads to FLEX Glance, and boots the target FLEX VM.

#### 3c. Volume Snapshot Migration Pipeline

`ospc2flex_volsnap_migrate.sh` — triggered via **Volume-Snapshot-Mig** button. No Glance. No image file. No qcow2. Direct block-device stream.

| Stage | What Happens | Where |
|-------|-------------|-------|
| **1. OSPC snapshot** | Verify snapshot exists and is `available` | OSPC API |
| **2. Temporary OSPC volume** | Create a temporary Cinder volume from the snapshot | OSPC cloud |
| **3. Attach temp volume to OSPC helper VM** | Attach temp volume so block device is accessible over SSH | OSPC cloud |
| **4. Create blank FLEX Cinder volume** | Provision an empty target Cinder volume of matching size | FLEX cloud |
| **5. Attach FLEX volume to FLEX helper VM** | Attach target volume to a FLEX helper VM to receive the stream | FLEX cloud |
| **6. Stream block device over SSH using dd + gzip** | `dd if=/dev/sdX | gzip | ssh flex-helper "gunzip | dd of=/dev/sdY"` | Jumphost → OSPC helper → FLEX helper |
| **7. Detach from helper** | Detach temp volumes from both helper VMs | OSPC + FLEX clouds |
| **8. Attach final FLEX volume to target FLEX VM** | Attach the new FLEX Cinder volume to the target FLEX instance | FLEX cloud |

Jumphost credentials (IP, SSH user, SSH key) and OSPC/FLEX cloud credentials are read from the existing page fields — no separate modal required.

### 2. Windows VM Migration Process

`ospc2flex_windows_migrate.sh` — SSH direct disk read via PowerShell, no agent required.

| Stage | What Happens | Where | Estimated Time (80 GB) |
|-------|-------------|-------|----------------------|
| **Step 1b** | Check SSH port 22 (public → ServiceNet fallback) → WinRM bootstrap if needed | Jumphost → Windows VM | < 1 min |
| **Step 1** | OSPC auth (curl) → Nova API find server → create Glance snapshot *(skipped if SSH reachable)* | OSPC cloud (server-side) | 10–20 min |
| **Step 2** | SSH → PowerShell disk dump → `dd` to `.img` at ~20 MB/s | Windows VM → Jumphost | ~70 min |
| **Step 3** | `qemu-img convert` raw → qcow2 | Jumphost (local) | 5–10 min |
| **Step 4** | Offline VirtIO driver injection into qcow2 | Jumphost (local) | 3–5 min |
| **Step 5** | Upload qcow2 to FLEX Glance | Jumphost → FLEX cloud | 10–20 min |
| **Step 6** | Boot VM from image | FLEX cloud (server-side) | 2–3 min |
| **Step 7** | Assign floating IP | FLEX cloud (server-side) | < 1 min |
| **TOTAL** | | | ~105–130 min |

## Current Status

| Category                        | Details                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | Current Status                                                                                       |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------- |
| **Workflow Stages**             | Stage 0: Customer Migration Tracker (Backlog management)<br>Stage 1: Discovery & Assessment (OSPC/FLEX scanning & topology import)<br>Stage 2: Migration Pipeline (Shift & Lift Images, REHOST Apps/DBs, Kubernetes)<br>Stage 3: Validation & UAT (Automated cross-cloud checks & HTTP health tests)<br>Stage 4: Cutover & Handover (Traffic split, DB promotion, final sync)<br>Stage 5: Post-Migration (Stability tracking, artifact bundle generation)<br>Stage 6: TCO / FinOps<br>Stage 7: IAC Backup & Restore (Terraform + Ansible)<br>Stage 8: GitOps / OpenCenter<br>Stage 9: AI OPS | Stage 2 VM shift and lift: ready<br>Server and DB rehost: ready<br>Windows VM migration: WIP<br>Stage 3 to 5: under construction<br>Stage 6 to 9: to be validated and build |
| **Current Features (✅ Ready)**  | Single-Tab Mission Control: No CLI required, full GUI wrapper<br>Live Execution: Real-time logs streaming to browser<br>Visual Topology Designer: Drag-and-drop infra cloning<br>Offline Guest Repair: Pre-boot image patching for networks<br>Parallel Execution: Migrate multiple DBs/Servers simultaneously<br>No Database Required: Stateless backend (CSV + local browser storage)<br>**Private Snapshot Migration Table**: 3-tab (Linux/Windows/Volume) snapshot discovery and migration cockpit with sortable columns, Export CSV, per-row SSE log stream<br>**Discovery TCO Dashboard**: Auto-load flavor map, OSPC/FLEX price list upload, 2.45× fallback assumption, sessionStorage caching<br>**UAT TCO Chart**: Inline OSPC/FLEX price list upload buttons with real-time savings recalculation<br>**UAT DB Compare**: Side-by-side OSPC vs FLEX database comparison with row-count diff<br>**UAT Cutover Readiness**: PASS/FIX buttons, scope-aware checks, service gap analysis, per-metric performance decisions | **READY**                                                                                            |
| **Available Migration Methods** | Direct Shift & Lift (Images): Production Mode, External Offload, Direct Export<br><br>REHOST (Apps & Servers): Infra duplication, Full Clone, Quick Install<br><br>Database Replication: Dump & Restore, DBaaS Streaming, HA Replica<br><br>Kubernetes Migration: Genestack/Kubespray, OpenCenter (GitOps), Magnum export<br><br>**Snapshot Migration**: Linux private snapshots → FLEX Glance; Windows snapshots → Method Z VirtIO repair → FLEX; Volume snapshots → direct block-device stream → FLEX Cinder (no Glance, no qcow2) | All Shift and rehost READY<br>Linux snapshot migration: READY<br>Windows snapshot migration: READY<br>Volume snapshot migration: READY<br>Stage 3 to 5: under construction<br>Stage 6 to 9: to be validated and build |
| **Supported OS Types**          | Ubuntu (20.04, 22.04, 24.04)<br>Debian (10, 11, 12)<br>CentOS 7<br>RedHat 6, 8<br>Rocky Linux 8 / 9<br>AlmaLinux 8 / 9<br>Windows Server 2016 / 2019                                                                                                                                                                                                                                                                                                                                                                                             | Linux VM rehost set: ready<br>Linux/Windows/Volume snapshot migration: ready<br>Windows live-VM migration: under Test                                             |
| **Future / Upcoming**           | Stage 6: TCO / FinOps (Right-sizing + cost summary)<br>Stage 7: IAC Backup & Restore (Terraform + Ansible)<br>Stage 8: GitOps / OpenCenter<br>Stage 9: AI OPS (optimization + autorepair recommendations using GitOps)                                                                                                                                                                                                                                                                                                                                                                          | under construction |

## 👨‍🚀 For Who

CloudJumper is for:
- **Rackspace Migration Engineers** moving customer workloads from OSPC to FLEX.
- **Cloud Operators** who need repeatable VM, image, topology, and data migration workflows.
- **Architects** planning customer modernization paths.
- **Support Teams** validating migrated servers after boot.
- Anyone who has stared at a migrated CentOS 7 image with no network and thought: *there has to be a better ritual for this.*

## 📡 Primary Control Modules (Where)

Run the dashboard from a Linux or WSL2 operator workstation. Run heavy image work on a same-region migration jumphost with enough block storage mounted at `/mnt/migration/ospc2flex_image`.

| Module Path | Mission Purpose |
|---|---|
| `workflow_dashboard/app.py` | Flask dashboard backend and API endpoints |
| `workflow_dashboard/templates/combined.html` | UAT dashboard — cutover readiness, TCO, DB compare, PASS/FIX buttons |
| `workflow_dashboard/static/uat/uat.js` | UAT readiness engine, TCO chart, service gap analysis |
| `workflow_dashboard/templates/image_migrator.html` | Main VM/image migration console (snapshot tabs, modal, SSE logs) |
| `dashboard/index.html` | Discovery dashboard — TCO pricing, flavor map autoload, price list uploads |
| `dashboard/app.js` | Discovery dashboard logic — CSV autoload, sessionStorage cache, TCO calculation |
| `ospc2Flex-Image-migtool/ospc2flex_image_migrator.py` | Standalone image migration pipeline |
| `ospc2Flex-Image-migtool/ospc2flex_offline_repair.sh` | Linux offline repair engine |
| `ospc2Flex-Image-migtool/ospc2flex_linux_snap_migrate.sh` | Linux private snapshot → FLEX migration |
| `ospc2Flex-Image-migtool/ospc2flex_windows_migrate.sh` | Windows live-VM migration workflow |
| `ospc2Flex-Image-migtool/ospc2flex_windows_method_z_snapshot_existing.sh` | Windows snapshot migration (Method Z — existing OSPC snapshot) |
| `ospc2Flex-Image-migtool/ospc2flex_windows_repair.sh` | Windows VirtIO repair engine |
| `ospc2Flex-Image-migtool/ospc2flex_volsnap_migrate.sh` | Volume snapshot → FLEX Cinder direct-stream (no Glance, no qcow2) |
| `ospc2Flex-Image-migtool/setup_jumphost.sh` | Jumphost bootstrap |

## 🛠️ Easy Install + Launch

### Fast path (recommended)

```bash
git clone <your-repo-url> cloudjumper
cd cloudjumper
chmod +x ./letsmove.sh
./letsmove.sh
```

This script handles dependency install, syntax check, app startup, and opens the dashboard at:

`https://127.0.0.1:5002`

Logs are written to:

`./dashboard.log`

### What `./letsmove.sh` does

- Cleans old app processes and frees conflicting ports.
- Installs Python requirements from `requirements/requirements.txt`.
- Validates `workflow_dashboard/app.py` syntax before launch.
- Starts the Flask dashboard and waits for health.
- Opens the dashboard URL automatically when possible.

### Manual fallback (if needed)

```bash
pip3 install -r requirements/requirements.txt
python3 workflow_dashboard/app.py
```

**Jumphost Outfitting (System Packages):**
```bash
sudo apt-get update
sudo apt-get install -y \
  qemu-utils gdisk e2fsprogs xfsprogs parted \
  ntfs-3g chntpw libhivex-bin wget curl jq \
  mysql-client pulseaudio-utils mpg123 ffmpeg
```

## 🔭 What Next: The GitOps Horizon

CloudJumper is the migration cockpit. The next step is turning its output into a durable modernization pipeline.

The vision is a **Full Cycle Migration Mission Control** that produces structured data for GitOps workflows:
- Discovery output becomes versioned infrastructure intent.
- Topology maps become Terraform modules and environment overlays.
- Server and repair profiles become Ansible playbooks.
- App dependency maps become deployment order, health checks, and service ownership.
- Validation reports become pull request evidence.
- Rollback scripts become tested recovery automation.
- Migration telemetry becomes optimization data for future waves.
- Tenant IaC DR outputs become restore-ready overlays for another FLEX region or another OpenStack cloud.

The new handoff path is:

```text
Stage 5: Migration Output Bundle
  migration_manifest.json
  discovery-output/
  stage2-migration-output/
  terraform.tfvars.json
  ansible_inventory.ini
  repaired_image_metadata.json
  boot_test_results.json
  dependency_graph.json
  uat-input/
        |
        +--> Stage 6: TCO / FinOps
        |       OSPC baseline cost
        |       FLEX projected run-rate
        |       right-sizing candidates
        |       executive TCO report
        |
        +--> Stage 7: IAC Backup & Restore (Terraform + Ansible)
        |       Terraform-first tenant restore pack
        |       target cloud profile + OpenRC import
        |       region mapping and backup policy
        |       same-region / cross-region DR runbooks
        |       Git/S3 backup export and GitOps restore hooks
        |       optional OpenCenter-oriented restore prep (Option B)
        |
        +--> Stage 8: GitOps / OpenCenter
        +--> Stage 9: AI OPS
                private AI context pack
                autorepair plans
                risk and right-sizing recommendations
                Terraform/Ansible/DR patch suggestions
```

UAT does not need a separate disconnected artifact. It reuses the Migration Output Bundle through `uat-input/`, and that UAT view points back to `discovery-output/` and `stage2-migration-output/` so testers can validate what was discovered, what migrated, what was repaired, and what evidence exists before cutover.

That means CloudJumper can interconnect with FinOps reporting, **GitOps** remotes, and other control planes. TCO / FinOps turns the migration into financial evidence: source baseline, target run-rate, right-sizing candidates, and executive reporting. **IAC DR Backup and Restore** is the repeatable customer handoff layer: Terraform-first desired state, region mapping, backup policy, tested restore runbooks, and optional GitOps/OpenCenter-oriented restore prep when you use Option B in that stage.

AI OPS becomes the private intelligence layer over the whole chain after GitOps/OpenCenter reconciliation. It reads the CloudJumper output bundle plus IAC DR outputs (and optional bundle slices such as `opencenter/` when generated), then produces risk scores, autorepair plans, right-sizing recommendations, runbook improvements, and infrastructure patch suggestions without losing the customer-specific context.

Instead of finishing with a one-time migration script, the customer leaves with a repeatable operating model: infrastructure saved as code, repairs encoded as playbooks, topology represented as reviewable templates, and deployment state controlled through pull requests.

From there, AI agents can help with the work that usually gets lost after migration day: autorepair failed boots, recommend right-sized FLEX flavors, generate Terraform patches from validated migration maps, summarize risk before each cutover, and keep customer environments optimized as they scale.

### 🌟 The Promise

OSPC carried important workloads for a long time. FLEX is where those workloads can keep moving.

CloudJumper is the bridge: part scanner, part repair bench, part launch console, part field notebook. It does not replace engineering judgment. It gives that judgment a cockpit, a checklist, and a live instrument panel.

**Move carefully. Verify everything. Bring the customer forward.**

## Details for the Nerds

Need the full operator notes, workflow history, script map, and deeper telemetry? Read the extended mission manual: [README.long.MD](README.long.MD).

❤️ Made with Love by 👤 **Dzoan.nguyen@Rackspace.com** using 👤 **brian.abshier@RACKSPACE.COM** awesome 🛠️ **OSFLEX Topology Builder** tool.
