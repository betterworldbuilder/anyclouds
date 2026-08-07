# CloudJumper — Full Operator Manual

OSPC to FLEX Migration Mission Control — Complete Technical Reference

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Install & Launch](#install--launch)
4. [Stage 0 — Customer Migration Tracker](#stage-0--customer-migration-tracker)
5. [Stage 1 — Discovery Dashboard](#stage-1--discovery-dashboard)
6. [Stage 2 — Migration Pipeline](#stage-2--migration-pipeline)
7. [Stage 3 — Validation & UAT Dashboard](#stage-3--validation--uat-dashboard)
8. [Stage 4 — Cutover](#stage-4--cutover)
9. [Stage 5 — Post-Migration Output Bundle](#stage-5--post-migration-output-bundle)
10. [Stage 6 — TCO / FinOps](#stage-6--tco--finops)
11. [Stage 7 — IAC Backup & Restore](#stage-7--iac-backup--restore)
12. [FLEX2FLEX Region Cloning](#flex2flex-region-cloning)
13. [FLEX Anywhere Hyperscaler Bridge](#flex-anywhere-hyperscaler-bridge)
14. [Script Reference](#script-reference)
15. [API Reference](#api-reference)
16. [Troubleshooting](#troubleshooting)

---

## Overview

CloudJumper is a browser-based migration cockpit that manages the full lifecycle of moving Rackspace OpenStack Private Cloud (OSPC) workloads to Rackspace FLEX. It replaces spreadsheets, ad-hoc scripts, and tribal knowledge with a structured, observable workflow that produces audit-ready evidence at every stage.

**Core design principles:**

- No CLI required for operators — every action is driven from the browser UI
- Stateless backend — all state lives in CSV files and browser localStorage; no database required
- Every scan, run, and repair produces a downloadable artifact
- Real-time log streaming (SSE) for every migration job
- SSH execution happens on the jumphost or target VM; the browser is the control surface only

---

## Architecture

```
Browser (operator)
    │
    │  HTTP / SSE
    ▼
Flask app  (workflow_dashboard/app.py)   port 5001
    │
    ├── /dashboard/          Discovery dashboard (Stage 1 TCO)
    ├── /api/uat/*           UAT state, readiness, checklists
    ├── /api/tco/*           TCO calculation endpoints
    ├── /api/files           File listing (uploads/)
    ├── /api/dashboard/csv-content/<file>   Raw CSV serving
    └── /api/uat/flavor-summary             Flavor map summary for UAT TCO
    │
    ├── workflow_dashboard/templates/combined.html   UAT dashboard (Stage 3)
    ├── workflow_dashboard/static/uat/uat.js         UAT readiness engine
    ├── dashboard/index.html                         Discovery dashboard (Stage 1)
    └── dashboard/app.js                             Discovery dashboard logic
    │
    ├── uploads/             CSV uploads, flavor maps, price lists
    ├── outputs/uat/         UAT checklist, scope, readiness state
    └── ospc2Flex-Image-migtool/   Migration shell scripts
```

**Key data flows:**

- Discovery scans write `flavormap.csv`, `ospc_servers.csv`, `flex_flavors.csv` to `uploads/`
- UAT state is persisted in `outputs/uat/uat_state.json`
- Browser `sessionStorage` caches CSV content to avoid refetch on iframe reload
- Browser `localStorage` stores: workload scope, perf user decisions, FIX modal dismissals

---

## Install & Launch

### Fast path

```bash
git clone https://github.com/rackerlabs/OSPC2FLEX-Cloud-Jumper cloudjumper
cd cloudjumper
chmod +x ./letsmove.sh
./letsmove.sh
```

Dashboard opens at `http://127.0.0.1:5001`

### What `letsmove.sh` does

1. Kills any existing app process on ports 5001/5002
2. Creates/reuses `.venv` and installs the core Python requirements there
3. Validates `workflow_dashboard/app.py` syntax
4. Starts Flask and waits for health check
5. Opens the dashboard URL

### Manual start

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements/requirements-core.txt
.venv/bin/python workflow_dashboard/app.py
```

Optional Whisper speech-to-text support (including its large Torch dependency
stack) can be installed with
`.venv/bin/python -m pip install -r requirements/requirements-ai.txt`.

### Jumphost system packages

```bash
sudo apt-get update && sudo apt-get install -y \
  qemu-utils gdisk e2fsprogs xfsprogs parted \
  ntfs-3g chntpw libhivex-bin wget curl jq \
  mysql-client pulseaudio-utils mpg123 ffmpeg
```

### SSH key

Always use `~/.ssh/id_rsa` for OSPC and FLEX server connections.

---

## Stage 0 — Customer Migration Tracker

The tracker (Stage 0) manages the customer backlog across multiple concurrent migrations.

**What it stores:**
- Customer name, account ID, OSPC region, FLEX region
- Migration status (Backlog / In Progress / UAT / Complete)
- Active context — selecting a customer row sets the source/target credentials for all other stages
- Notes, wave assignment, owner

**How to use:**
1. Click **Customer List** in the top bar
2. Add a new customer row or select an existing one
3. Fill OSPC auth URL, username, password, project, FLEX equivalent
4. Click **Set Active** — all stages now operate against this customer's clouds

**Output:** `outputs/tracker/customer_list.csv`

---

## Stage 1 — Discovery Dashboard

**URL:** `/dashboard/`

The Discovery dashboard scans the OSPC and FLEX estates and computes a TCO comparison.

### What it scans

- OSPC: servers, images, networks, volumes, flavors
- FLEX: available flavors, existing instances
- Produces `flavormap.csv` mapping OSPC server flavors to closest FLEX equivalents

### Flavor Map Auto-Load

The dashboard automatically loads `flavormap.csv` from the `uploads/` directory on page load — no manual upload required. The load uses the `/api/files` endpoint to list available files, then fetches content via `/api/dashboard/csv-content/<filename>`.

**sessionStorage caching:** Once loaded, the CSV is cached under the key `csv_cache:<filename>` so iframe reloads and tab switches do not re-fetch.

Fallback prefix matching logic (in `dashboard/app.js`):
```javascript
const pick = (suffix) =>
  files.find(f => f === prefix + suffix) ||
  files.find(f => f.endsWith(suffix) && !f.includes('flex2flex') && !f.includes('/'));
```

### TCO Calculation

TCO is computed in `dashboard/app.js` (`renderMapperSummary()`) using this priority order:

| Cost side | Priority 1 | Priority 2 (fallback) |
|---|---|---|
| FLEX monthly | FLEX Price List CSV (hourly × 730) | Flavor-match lookup from `flex_flavors.csv` |
| OSPC monthly | OSPC Price List CSV (`monthly_cost_usd` column sum) | FLEX monthly × **2.45** |

**The 2.45× multiplier** is the default OSPC cost assumption when no real billing data is uploaded. An amber warning note is shown whenever this fallback is active:

> ⚠ If no FLEX price list is present, OSPC is assumed 2.45× more expensive than FLEX.

### Price List Upload Panel

Appears automatically once a flavor map loads. Contains:

- **⬆ OSPC Price List** — upload a CSV with columns including `monthly_cost_usd` (one row per server). Sums all monthly costs to override the 2.45× estimate with real OSPC billing data.
- **⬆ FLEX Price List** — upload a CSV with FLEX flavor hourly rates. Computes `hourly_rate × 730` for monthly cost, or reads `monthly_cost` directly if present.

Both uploads are parsed client-side in `parsePriceListCsv()` and stored in `state.ospcPriceMap` / `state.flexPriceMap`. `renderMapperSummary()` re-runs immediately after each upload.

**State object additions in `dashboard/app.js`:**
```javascript
ospcPriceMap: {}, flexPriceMap: {},
hasOspcPriceList: false, hasFlexPriceList: false,
```

### TCO backend (`app.py`)

- `api_tco_report()` (line ~10110): main TCO endpoint, calls `_add_tco_item()` per VM
- `_flex_price_lookup()` (line ~9937): reads FLEX flavor prices from `uploads/flavors/` CSVs
- `_add_tco_item()` (line ~10026): computes `hourly × 730 = monthly` per VM
- Fallback multiplier: `flex_hourly * 2.45` for OSPC estimate when no source price

### Discovery outputs

| File | Content |
|---|---|
| `uploads/flavormap.csv` | OSPC→FLEX flavor mapping with vCPU, RAM, disk, match score |
| `uploads/ospc_servers.csv` | Full OSPC server inventory |
| `uploads/flex_flavors.csv` | Available FLEX flavors with pricing |

---

## Stage 2 — Migration Pipeline

### VM Migration Methods

#### Linux VM — NBD/DD (`mig_worker_v4.sh`)

| Step | Action | Location | Time (80 GB) |
|---|---|---|---|
| 1 | OSPC auth → find VM → check disk | Jumphost → OSPC API | <1 min |
| 2 | SSH tunnel → qemu-nbd exposes disk as NBD | Jumphost ↔ Linux VM | <1 min |
| 3 | `dd` reads NBD → `.img` at ~50–80 MB/s | Linux VM → Jumphost | 20–30 min |
| 4 | `qemu-img convert` raw → qcow2 | Jumphost local | 5–10 min |
| 5 | Offline repair: bootloader, fstab, virtio, network | Jumphost local | 3–5 min |
| 6 | Upload qcow2 to FLEX Glance | Jumphost → FLEX | 10–20 min |
| 7 | Boot VM from image | FLEX cloud | 2–3 min |
| 8 | Assign floating IP | FLEX cloud | <1 min |
| **Total** | | | **45–70 min** |

#### Windows VM — PowerShell disk dump (`ospc2flex_windows_migrate.sh`)

| Step | Action | Time (80 GB) |
|---|---|---|
| 1b | Check SSH port 22, WinRM bootstrap if needed | <1 min |
| 1 | OSPC auth → Nova API → Glance snapshot | 10–20 min |
| 2 | SSH → PowerShell disk dump → dd → .img at ~20 MB/s | ~70 min |
| 3 | qemu-img convert raw → qcow2 | 5–10 min |
| 4 | Offline VirtIO driver injection | 3–5 min |
| 5 | Upload qcow2 to FLEX Glance | 10–20 min |
| 6 | Boot VM | 2–3 min |
| 7 | Assign floating IP | <1 min |
| **Total** | | **~105–130 min** |

### Snapshot Migration

The **Private Snapshot Migration Table** (`image_migrator.html`) has three tabs:

| Tab | Script | Notes |
|---|---|---|
| 🐧 Linux Snapshots | `ospc2flex_linux_snap_migrate.sh` | OSPC snapshot → offline repair → FLEX Glance |
| 🪟 Windows Snapshots | `ospc2flex_windows_method_z_snapshot_existing.sh` | Method Z VirtIO injection |
| 📦 Volume Snapshots | `ospc2flex_volsnap_migrate.sh` | Direct Cinder block stream — no Glance, no qcow2 |

All tabs share: per-row Select checkbox, select-all toggle, no-image-resume checkbox, sortable columns, Export CSV, per-snapshot SSE log stream.

#### Linux Snapshot Pipeline

`ospc2flex_linux_snap_migrate.sh`:
1. OSPC auth → snapshot-to-image staging
2. Download to jumphost
3. Offline Linux repair (bootloader, fstab, virtio, cloud-init)
4. Upload to FLEX Glance
5. Boot FLEX instance

**Ubuntu 24 exception:** Use VM/NBD migration instead of snapshot migration for Ubuntu 24.

#### Windows Snapshot — Method Z

`ospc2flex_windows_method_z_snapshot_existing.sh`:
1. Uses existing OSPC snapshot (no new snapshot creation)
2. Injects VirtIO drivers offline into the qcow2
3. Corrects Xen service start values: `xendisk Start=0`, XENFILT on SCSI class
4. Repairs Windows registry: VirtIO class filters and PnP mappings
5. Uploads to FLEX Glance
6. Boots target FLEX VM

#### Volume Snapshot Pipeline

`ospc2flex_volsnap_migrate.sh` — no image file, no Glance, direct block device stream:

| Stage | Action | Where |
|---|---|---|
| 1 | Verify OSPC snapshot is `available` | OSPC API |
| 2 | Create temp Cinder volume from snapshot | OSPC cloud |
| 3 | Attach temp volume to OSPC helper VM | OSPC cloud |
| 4 | Create blank FLEX Cinder volume (matching size) | FLEX cloud |
| 5 | Attach FLEX volume to FLEX helper VM | FLEX cloud |
| 6 | Stream: `dd if=/dev/sdX \| gzip \| ssh flex "gunzip \| dd of=/dev/sdY"` | Jumphost |
| 7 | Detach temp volumes from both helpers | OSPC + FLEX |
| 8 | Attach final FLEX volume to target FLEX VM | FLEX cloud |

### OS Coverage Matrix

| OS | VM migration | Snapshot migration | Volume snapshot |
|---|---|---|---|
| Ubuntu 20.04 | Live VM/NBD | ✓ | ✓ |
| Ubuntu 22.04 | Live VM/NBD | ✓ | ✓ |
| Ubuntu 24.04 | Live VM/NBD only | ✗ use VM path | ✓ (with target VM ID) |
| Debian 10/11/12 | Live VM/NBD | ✓ | ✓ |
| CentOS 7 | Live VM/NBD | ✓ | ✓ |
| CentOS 8/9/Stream | Live VM/NBD | Expected ✓ | ✓ |
| RHEL 7/8/9 | Live VM/NBD | Expected ✓ | ✓ |
| Rocky 8/9 | Live VM/NBD | ✓ | ✓ |
| AlmaLinux 8/9 | Live VM/NBD | ✓ | ✓ |
| Windows Server 2016 | Under test | Method Z ✓ | Under test |
| Windows Server 2019 | Under test | Method Z ✓ | Under test |

---

## Stage 3 — Validation & UAT Dashboard

**Template:** `workflow_dashboard/templates/combined.html`
**Engine:** `workflow_dashboard/static/uat/uat.js`

The UAT dashboard is the operator's validation cockpit after VMs are migrated to FLEX. It determines cutover readiness through a live analysis engine.

### Readiness Engine (`calculateUatReadinessAnalysis`)

The engine runs on every render and evaluates:

**Check-based gates (scope-aware):**

| Check key | Label | Passes when | Impact |
|---|---|---|---|
| `critical_systems` | Critical Systems Tested | All critical servers marked Passed in Step 1 | Blocks cutover |
| `critical_issues` | No Open Critical Issues | 0 Critical-severity open issues | Blocks cutover |
| `data_validation` | Data Validation | `data_comparison` checklist item passed | Blocks cutover |
| `app_health` | App Health Check | `application_health` checklist item passed | Blocks cutover |
| `database_validation` | Database Validation | `database_validation` item passed — **skipped if DB is out of scope** | Blocks cutover (in scope only) |
| `reports_outputs` | Reports & Outputs | `reports_outputs` checklist item passed | Blocks cutover |
| `performance` | Performance | No FAIL metrics + no pending decisions | Blocks until resolved |

**Service comparison analysis** (from Step 2 — Service Comparison):

| Category | Meaning | Cutover impact |
|---|---|---|
| `svcHardBlocks` | Service critically missing on FLEX | Blocks cutover |
| `svcReviewGaps` | Service on OSPC but missing on FLEX, needs review | Ready With Conditions |
| `svcWarnings` | Extra service on FLEX not on OSPC | Warning only |

**Performance metrics** (from Step 3 — SSH Performance Test):

Each metric has a system assessment badge and a user decision dropdown:

| User Decision | Effect on readiness |
|---|---|
| Pending | Keeps system badge — FAIL/REVIEW blocks |
| Pass | Override to PASS — removes block |
| Fail | Override to FAIL — blocks cutover |
| Accept Risk | Override to WARN — Ready With Conditions |
| Not Applicable | Override to OUT OF SCOPE — ignored |

**Final decision logic:**
- `READY` — all in-scope checks pass, no hard blocks, no perf failures
- `READY WITH CONDITIONS` — no hard blocks but has review gaps / warnings / perf warns
- `NEED REVIEW BEFORE CUT OVER` — any blocker, hard block, or perf failure

### FIX Modal

Clicking the **FIX** button opens a full-screen overlay modal:

**What it shows:**
- All active blockers and review items pulled live from the readiness engine
- Each issue card displays: severity badge, title, detail, evidence source, fix instruction, copyable fix command
- Two action buttons per issue: **✓ Fixed** and **~ Not Relevant**

**Actions:**
- **✓ Fixed** — user attests the issue is resolved. Stored in `localStorage` key `uat_fix_dismissed` as `'fixed'`. The readiness engine immediately re-evaluates and the PASS/FIX buttons + readiness score update without page reload.
- **~ Not Relevant** — marks the issue out of scope (e.g., a service gap expected to be absent). Stored as `'not_relevant'`. Removes the item from blocking count.
- **Undo** — dismissals can be reversed from the collapsed "Previously dismissed" section at the bottom of the modal.
- **↻ Re-run** — re-runs `uatRerenderReadiness()` to refresh from live API data.

**localStorage key:** `uat_fix_dismissed`
```json
{
  "check:critical_systems": "fixed",
  "svc_gap:nginx": "not_relevant",
  "perf:cpu_pct": "fixed"
}
```

**Issue key format:**
- Check-based: `check:<key>` (e.g., `check:app_health`)
- Service hard block: `svc_hard:<service_name>`
- Service gap: `svc_gap:<service_name>`
- Service warning: `svc_warn:<service_name>`
- Performance metric: `perf:<metric_key>`

**Proposed fix commands by check:**

| Check | Fix command |
|---|---|
| `app_health` | `curl -s -o /dev/null -w "%{http_code}" http://FLEX_IP/health` |
| `data_validation` | `diff <(ssh ospc-vm "md5sum /data/*.db \| sort") <(ssh flex-vm "md5sum /data/*.db \| sort")` |
| `database_validation` | `mysql -h FLEX_DB_HOST -u root -p -e "SELECT 1; SHOW DATABASES;"` |
| Service missing | `ssh flex-vm "sudo systemctl start <svc> && sudo systemctl enable <svc>"` |
| Service gap | `ssh flex-vm "sudo systemctl status <svc> 2>/dev/null \|\| sudo systemctl start <svc>"` |

### PASS Button

Clicking **PASS**:
- If blockers exist → prompts for risk acceptance reason and approver name → records "READY WITH CONDITIONS"
- If no blockers → confirms "All required checks passed. Proceed with cutover."

### TCO Cost Estimation Chart

The UAT TCO chart (`#uat-tco-chart`) shows monthly cost comparison between OSPC and FLEX, with:
- Source Monthly Cost (OSPC)
- Target Monthly Cost (FLEX)
- Monthly Savings and Savings %
- Estimated Monthly Savings badge

**Price list overrides** (inline within the chart):
- **⬆ OSPC Price List** — upload a CSV with real OSPC monthly billing totals to replace the 2.45× estimate
- **⬆ FLEX Price List** — upload a CSV with FLEX hourly rates to compute accurate FLEX monthly cost
- Amber warning when the 2.45× fallback is active: *"If no FLEX price list is present, OSPC is assumed 2.45× more expensive than FLEX."*

Price state is stored in `window._uatPriceListState`:
```javascript
{
  ospcMeta: 'filename.csv',
  flexMeta: 'filename.csv',
  ospcMonthly: 12500,   // sum of all OSPC server monthly costs
  flexMonthly: 5100,    // sum of FLEX hourly × 730
}
```

Uploading either file calls `_uatRerunTco()` → `uatRerenderReadiness()` to refresh the chart immediately.

### UAT DB Compare

Side-by-side database comparison between OSPC source and FLEX target:
- Enumerates user databases on both servers (excludes `information_schema`, `performance_schema`, `mysql`, `sys`)
- Compares row counts per table
- Highlights mismatches in red
- Shows "No user databases found" when both servers have no application databases

### Step navigation

The UAT dashboard has 9 steps accessible via the left sidebar. Compact mode (default) shows only Step 5 — Summary. Detailed mode shows all steps. `uatNavTo(stepNumber)` scrolls to any step.

### Data persistence

| Data | Storage | Key |
|---|---|---|
| Workload scope (app type, DB, components) | localStorage | `uat_workload_scope` |
| Performance user decisions | localStorage | `uat_perf_user_decisions` |
| FIX modal dismissals | localStorage | `uat_fix_dismissed` |
| UAT state (scope, checklist, issues, artifacts) | File | `outputs/uat/uat_state.json` |
| UAT checklist | File | `outputs/uat/uat_checklist.json` |
| UAT scope | File | `outputs/uat/uat_scope.csv` |

---

## Stage 4 — Cutover

Cutover is the live traffic switch from OSPC to FLEX.

**Pre-cutover checklist:**
1. UAT dashboard shows READY or READY WITH CONDITIONS with all conditions accepted
2. Export UAT Report as evidence (Step 9 → Download Full Report)
3. Customer change management ticket approved
4. Rollback scripts prepared and tested

**Cutover actions available from the dashboard:**
- Final service comparison run
- DNS cutover script generation
- Floating IP reassignment
- Load balancer member swap
- Post-cutover health check

---

## Stage 5 — Post-Migration Output Bundle

After cutover, Stage 5 generates the handoff bundle:

```
outputs/
  migration_manifest.json
  discovery-output/
  stage2-migration-output/
  terraform.tfvars.json
  ansible_inventory.ini
  repaired_image_metadata.json
  boot_test_results.json
  dependency_graph.json
  uat-input/
```

This bundle feeds Stages 6–9 (TCO, IAC DR, GitOps, AI OPS).

---

## Stage 6 — TCO / FinOps

TCO / FinOps provides financial evidence for the migration:

- **OSPC baseline**: actual monthly spend from OSPC billing data (or 2.45× FLEX estimate)
- **FLEX projected run-rate**: actual from FLEX price list or flavor-match pricing
- **Right-sizing candidates**: VMs where FLEX flavor is significantly smaller than OSPC original
- **Executive TCO report**: downloadable PDF/Excel summary with savings %

**Key TCO backend endpoints:**
- `GET /api/tco/report` — full TCO calculation for all VMs in scope
- `GET /api/dashboard/csv-content/<filename>` — raw CSV serving for client-side price list parsing
- `GET /api/uat/flavor-summary` — aggregated flavor data for UAT TCO chart

---

## Stage 7 — IAC Backup & Restore

Generates a Terraform-first tenant restore pack:

- `terraform.tfvars.json` — FLEX resource definitions from discovery data
- `ansible_inventory.ini` — target host inventory
- OpenRC import template for the FLEX region
- Region mapping and backup policy
- Same-region and cross-region DR runbooks
- Git/S3 backup export hooks
- Optional OpenCenter-oriented restore prep (Option B)

---

## FLEX2FLEX Region Cloning

Copies FLEX resources from one region to another without touching the source.

### Supported clone types

| Source | Target | Purpose |
|---|---|---|
| Linux image snapshot | New image in target region | Rebuild Linux VM in another region |
| Windows image snapshot | New image in target region | Rebuild Windows VM including VirtIO-ready images |
| Bootable volume snapshot | New bootable volume in target region | Restore VM boot disk |
| Data volume snapshot | New data volume in target region | Restore application data |
| DB volume snapshot | New DB volume in target region | Restore or test database recovery |

### Clone workflow

1. Select source FLEX region → scan private snapshots
2. Choose rows from Linux Snapshots, Windows Snapshots, or Volume Snapshots tab
3. Pick target FLEX region
4. Run clone job
5. Tries direct Glance-to-Glance regional copy first
6. Falls back to jumphost stream method if direct import is blocked
7. For volume snapshots: reuses OSPC2FLEX volume snapshot remount/attach process

### Operational notes

- Source resources are never deleted or modified
- FLEX Glance image IDs are region-scoped — target always gets a new ID
- Table selections and per-row choices are cached in browser
- Start Fresh and Stop Batch controls available for all batch types

---

## FLEX Anywhere Hyperscaler Bridge

**Status: WIP**

A bridge for moving images, snapshots, and volumes between FLEX and AWS, Azure, or GCP. Reuses the FLEX2FLEX mission-control layout.

### Supported directions

| Direction | Source | Target |
|---|---|---|
| AWS → FLEX | AMI, EBS snapshot, exported disk image | FLEX image or FLEX volume |
| Azure → FLEX | Managed disk, snapshot, VHD | FLEX image or FLEX volume |
| GCP → FLEX | Image, persistent disk snapshot | FLEX image or FLEX volume |
| FLEX → AWS | FLEX image or volume | AMI, EBS snapshot, or imported disk |
| FLEX → Azure | FLEX image or volume | Managed disk, snapshot, or VHD |
| FLEX → GCP | FLEX image or volume | GCP image or persistent disk snapshot |

### Rackspace account links

- AWS: https://manage.rackspace.com/aws/accounts
- GCP: https://manage.rackspace.com/gcp
- Azure: https://manage.rackspace.com/azure/enrollment

---

## Script Reference

| Script | Location | Purpose |
|---|---|---|
| `mig_worker_v4.sh` | `ospc2Flex-Image-migtool/` | Linux VM live migration via NBD/DD |
| `ospc2flex_offline_repair.sh` | `ospc2Flex-Image-migtool/` | Linux offline guest repair engine |
| `ospc2flex_linux_snap_migrate.sh` | `ospc2Flex-Image-migtool/` | Linux private snapshot → FLEX |
| `ospc2flex_windows_migrate.sh` | `ospc2Flex-Image-migtool/` | Windows live VM migration |
| `ospc2flex_windows_method_z_snapshot_existing.sh` | `ospc2Flex-Image-migtool/` | Windows snapshot Method Z |
| `ospc2flex_windows_repair.sh` | `ospc2Flex-Image-migtool/` | Windows VirtIO repair engine |
| `ospc2flex_volsnap_migrate.sh` | `ospc2Flex-Image-migtool/` | Volume snapshot → FLEX Cinder direct stream |
| `setup_jumphost.sh` | `ospc2Flex-Image-migtool/` | Jumphost bootstrap |
| `letsmove.sh` | root | App install + launch |

---

## API Reference

### Files & CSV

| Endpoint | Method | Description |
|---|---|---|
| `/api/files` | GET | List workspace files. Returns `{"files": [...]}` |
| `/api/dashboard/csv-files` | GET | List CSV files from BASE_DIR + uploads/ |
| `/api/dashboard/csv-content/<filename>` | GET | Raw CSV text for a given file |

### UAT

| Endpoint | Method | Description |
|---|---|---|
| `/api/uat/state` | GET | Full UAT state JSON |
| `/api/uat/scope` | GET/POST | UAT scope rows |
| `/api/uat/checklist` | GET/POST | UAT checklist items |
| `/api/uat/issues` | GET/POST | Issues tracker |
| `/api/uat/run-command` | POST | Execute SSH command and record result |
| `/api/uat/flavor-summary` | GET | Aggregated flavor data for TCO chart |
| `/api/uat/readiness` | GET | Readiness check results |

### TCO

| Endpoint | Method | Description |
|---|---|---|
| `/api/tco/report` | GET | Full TCO calculation for scoped VMs |

### Key response formats

**`/api/files`**
```json
{ "files": ["uploads/flavormap.csv", "uploads/ospc_servers.csv"] }
```

**`/api/uat/flavor-summary`**
```json
{
  "ok": true,
  "vmData": {
    "srcVcpu": 32, "tgtVcpu": 32,
    "srcRam": 128, "tgtRam": 128,
    "srcDisk": 2000, "tgtDisk": 2000,
    "rows": 12,
    "targetMonthly": 4800
  }
}
```

---

## Troubleshooting

### Discovery dashboard CSV not loading

**Cause:** `/api/files` returns `{"files": [...]}` (object), but old code checked `Array.isArray()` on the response directly.

**Fix:** Code in `dashboard/app.js` extracts: `const files = Array.isArray(data) ? data : (data.files || [])`.

If still not loading, check:
```bash
curl http://localhost:5001/api/files
curl http://localhost:5001/api/dashboard/csv-content/flavormap.csv
```

### TCO shows 0 or wrong values

1. Check that `flavormap.csv` loaded (green indicator in the UI)
2. Upload FLEX Price List CSV with columns: `flavor_name`, `hourly_rate` or `monthly_cost`
3. Upload OSPC Price List CSV with column: `monthly_cost_usd`
4. If amber warning is showing, the 2.45× fallback is active — upload real pricing

### UAT FIX modal shows no issues but status is NOT READY

Check `localStorage.uat_fix_dismissed` in browser DevTools → Application → Local Storage. If items were dismissed via the FIX modal, they are removed from the blocking count. Use **Undo** in the dismissed section of the modal to restore them.

### UAT readiness score not updating after marking items Fixed

1. Ensure `uatRerenderReadiness()` is accessible — it is set at `window.uatRerenderReadiness`
2. Check browser console for JS errors
3. Hard refresh the page (Ctrl+Shift+R) to clear any stale script cache

### Playwright screenshots timing out

The app uses SSE connections for log streaming. These keep the network active indefinitely, so `wait_until="networkidle"` will always timeout. Use `wait_until="load"` instead:

```python
page.goto("http://localhost:5001", wait_until="load")
page.wait_for_timeout(5000)  # allow SSE and dynamic content to settle
```

### SSH migration fails with NBD error

```bash
# On the jumphost, check NBD module is loaded
lsmod | grep nbd
sudo modprobe nbd max_part=8

# Verify qemu-nbd is installed
which qemu-nbd || sudo apt-get install -y qemu-utils
```

### Windows VirtIO repair fails

Method Z requires `chntpw` and `libhivex-bin` on the jumphost:
```bash
sudo apt-get install -y chntpw libhivex-bin
```

### Volume snapshot stream hangs

Check that both the OSPC helper VM and FLEX helper VM are reachable from the jumphost via SSH. The stream command requires:
```bash
ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa ubuntu@OSPC_HELPER
ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa ubuntu@FLEX_HELPER
```

---

❤️ Made with Love by 👤 **Dzoan.nguyen@Rackspace.com** using 👤 **brian.abshier@RACKSPACE.COM** awesome 🛠️ **OSFLEX Topology Builder** tool.
