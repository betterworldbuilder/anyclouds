<div align="center">

<h1>🚀 CLOUD JUMPER ANYWHERE</h1>

<p><strong>Any OpenStack Cloud to FLEX Migration Full Cycle Mission Control</strong></p>

<p>
  <img src="https://img.shields.io/badge/Python-3.12-3776ab?style=for-the-badge&logo=python&logoColor=white" alt="Python">
  <img src="https://img.shields.io/badge/Flask-2.x-000000?style=for-the-badge&logo=flask&logoColor=white" alt="Flask">
  <img src="https://img.shields.io/badge/OpenStack-OSPC→FLEX-ed1944?style=for-the-badge&logo=openstack&logoColor=white" alt="OpenStack">
  <img src="https://img.shields.io/badge/Platform-WSL2%20%2F%20Linux-0078d4?style=for-the-badge&logo=linux&logoColor=white" alt="Platform">
</p>

<p>
  <img src="https://img.shields.io/badge/Mission_Phases-0--9-22c55e?style=flat-square" alt="Phases">
  <img src="https://img.shields.io/badge/Migration_Strategies-6-f59e0b?style=flat-square" alt="Strategies">
  <img src="https://img.shields.io/badge/DB_Scenarios-4-22d3ee?style=flat-square" alt="DB Scenarios">
  <img src="https://img.shields.io/badge/Verification_Checks-14%2B-a855f7?style=flat-square" alt="Verification Checks">
  <img src="https://img.shields.io/badge/Live_Streaming-SSE-a855f7?style=flat-square" alt="SSE">
  <img src="https://img.shields.io/badge/No_DB-CSV_%2B_localStorage-3b82f6?style=flat-square" alt="No DB">
  <img src="https://img.shields.io/badge/IaC_DR_Backup_Restore-GitOps-0ea5e9?style=flat-square" alt="IAC DR">
  <img src="https://img.shields.io/badge/K8s_Migration_Methods-3-fb923c?style=flat-square" alt="K8s Methods">
  <img src="https://img.shields.io/badge/Magnum_Pipeline_Stages-8-ef4444?style=flat-square" alt="Magnum Stages">
</p>

<br>

> **One Mission Control tab. Full-cycle phases 0–9. Zero spreadsheets.**
> Tracker → Discover → Map & Design → Generate → Rehost & Data → Images & Repair → K8s (WIP) → UAT → Cutover → Post-migration handoff
>
> The result is fewer mystery failures, faster test boots, cleaner customer updates, and a migration path that feels engineered instead of improvised.

</div>

---

## Table of Contents

- [Why This Tool Exists](#why-this-tool-exists)
- [Architecture](#architecture)
- [Full-Cycle Migration Phases](#full-cycle-migration-phases-mission-control-narrative)
- [Current Status](#current-status)
- [Full Stage Breakdown](#full-stage-breakdown)
  - [Stage 0 — Customer Migration Tracker](#stage-0--customer-migration-tracker)
  - [Stage 1 — Discovery & Assessment](#stage-1--discovery--assessment)
  - [Stage 2 — Migration Pipeline](#stage-2--migration-pipeline)
    - [Option 1: Direct Shift & Lift (Image Migration)](#option-1-direct-shift--lift-image-migration)
    - [Option 2 Phase 1: REHOST Infra Cloning (Topology Designer)](#option-2-phase-1-rehost-infra-cloning-topology-designer)
    - [Option 2 Phase 2: Apps Servers & DB Replication](#option-2-phase-2-apps-servers--db-replication)
      - [DB VM — Single Database](#ospc2flex--db-vm-ssh-accessible-ospc-db-server)
      - [Single DBaaS — V2 Streaming](#ospc2flex--single-dbaas-v2-streaming--no-ssh-to-dbaas)
      - [DBaaS + Replica — V2 GTID](#ospc2flex--dbaas--replica-v2-gtid-streaming-replication)
      - [HA DBaaS — FLEX HA pair](#ospc2flex--ha-dbaas-ospc-ha-vip--flex-ha-pair)
      - [Comprehensive Verification Phase](#comprehensive-verification-phase-all-four-scenarios)
      - [HTML Comparison Report](#html-comparison-report-1)
    - [Option 2 Phase 3: Kubernetes Replication Manual / Auto](#option-2-phase-3-kubernetes-replication-manual--auto)
      - [Method 1: Full Manual Runbook](#method-1--full-manual-mode)
      - [Method 2: Automated — Genestack / Kubespray or OpenCenter](#method-2--automated-deployment-genestack--kubespray--or--opencenter)
      - [Method 3: OSPC K8 → Flex Magnum (8-Stage SSH Migration)](#method-3--ospc-k8--flex-magnum-8-stage-ssh-migration)
  - [Stage 3 — Validation & UAT](#stage-3--validation--uat)
  - [Stage 4 — Cutover & Handover](#stage-4--cutover--handover)
  - [Stage 5 — Post-Migration](#stage-5--post-migration)
- [Script Generation Engine](#script-generation-engine)
- [Prerequisites & Installation](#prerequisites--installation)
- [Launch](#launch)
- [Security & Persistence](#security--persistence)

---

## Why This Tool Exists

OSPC (Rackspace OpenStack Private Cloud) customers migrating to FLEX face a multi-week, multi-team gauntlet: discovery audits, topology redesign, VM image conversion, database replication, Kubernetes re-platforming, and final cutover — each with its own CLI toolchain, credentials, and risk surface.

**OSPC2FLEX Mission Control** collapses that entire lifecycle into a single browser tab. It wraps CLI tools, OpenStack API scanners, Bash script generators, and live SSE streaming terminals into a "Future Punk" dashboard UI — so operators coordinate a full migration without dropping to a terminal.

---

## Architecture

| Layer | Technology |
|-------|-----------|
| Backend | Python 3.12, Flask |
| Frontend | Vanilla HTML/CSS/JavaScript — no framework |
| Realtime output | Server-Sent Events (SSE) via `ReadableStream` |
| Script execution | Python `subprocess` threading + Bash |
| Persistence | Browser `localStorage` + CSV files (no database required) |
| Platform | Ubuntu 22.04+ / WSL2 (Windows Subsystem for Linux) |
| OpenStack integration | `python-openstackclient`, `python-octaviaclient` |
| VM image conversion | `qemu-img` (raw → qcow2 → FLEX-compatible) |

The Flask backend serves all pages as iframes within a single unified shell (`combined.html`), providing tab-based navigation across all migration stages without page reloads. Each page streams live execution output via SSE.

---

## Full-Cycle Migration Phases (Mission Control narrative)

CloudJumper works as a full-cycle migration Mission Control. Each phase turns unknowns into artifacts: CSVs, maps, scripts, repaired images, booted test instances, verification results, and rollback paths.

| Phase | Stage | Mission Control Function | Benefit |
|:---:|:---:|---|---|
| 📡 | **0. Customer Tracker** | Tracks customer, estate, status, notes, stage progress, and active migration context. | Keeps multiple migrations organized without losing the human thread. |
| 🔭 | **1. Discover** | Scans OSPC and FLEX inventory: servers, images, flavors, volumes, networks, security groups, load balancers, and floating IPs. | Builds a factual source-of-truth before anyone starts changing infrastructure. |
| 🗺️ | **2. Map & Design** | Compares source/target capacity, edges, and imports topology into a visual model to plan the target build. | Turns "what do we have?" into "where will it land?" and lets engineers see the shape of the migration. |
| ⚙️ | **3. Generate** | Produces deployment, data migration, sync, cutover, rollback, and validation scripts from the migration map. | Makes the work repeatable, reviewable, and safer than manual command assembly. |
| 💾 | **4. Database & Server Rehost** | Provisions target FLEX servers and orchestrates the database migration/sync (MySQL, PostgreSQL, block syncs). | Ensures data gravity is handled seamlessly alongside compute. |
| 📦 | **5. Image Migration & Repair** | Moves Linux/Windows workloads via NBD/Glance and applies offline guest repair (bootloaders, fstab, virtio, network config). | Converts old cloud images into FLEX-ready artifacts and fixes common first-boot failures offline. |
| ☸️ | **6. Kubernetes Mig (WIP)** | Translates Magnum OSPC clusters or raw k8s nodes into modern FLEX Kubernetes deployment models. | Containerized workloads jump alongside legacy VMs. |
| 🔬 | **7. UAT (Boot & Verify)** | Creates FLEX test instances, attaches access, checks ping/SSH, gathers host/kernel data, and streams logs. | Changes "the image uploaded" into "the workload is alive." |
| ✂️ | **8. Cut Over** | Uses generated cutover and rollback scripts with final validation evidence to shift live traffic. | Gives the migration a controlled finish line instead of a nervous handoff. |
| 🏁 | **9. Post Migration** | Generates infrastructure-as-code manifests, documentation, optimization telemetry, FinOps, IAC DR backup/restore packs, and AI context packs. | Hands off a modernized, GitOps-ready environment to the customer. |

**How this maps to the dashboard UI:** The shell uses **Customer List** (tracker) plus **Stages 1–8** in the top bar: Discovery (1), Migration (2), Validation & UAT (3), Cutover (4), Post-Migration bundle (5), TCO/FinOps (6), **IAC DR Backup and Restore** (7), **AI Anywhere** (8). Narrative phases **3–6** appear primarily under **Stage 2 (Migration)** and its subtabs; **7–8** align with post-migration handoff (FinOps, tenant DR/IaC with GitOps hooks, AI). **OpenCenter** is not a separate Mission Control stage; OpenCenter-style GitOps restore prep lives under **IAC DR** Option B, and Kubernetes migration still exposes OpenCenter/Genestack under **Stage 2** where applicable.

---

## Current Status

| Category                        | Details                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | Current Status                                                                                       |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------- |
| **Workflow Stages**             | Stage 0: Customer Migration Tracker (Backlog management)<br>Stage 1: Discovery & Assessment (OSPC/FLEX scanning & topology import)<br>Stage 2: Migration Pipeline (Shift & Lift Images, REHOST Apps/DBs, Kubernetes)<br>Stage 3: Validation & UAT (Automated cross-cloud checks & HTTP health tests)<br>Stage 4: Cutover & Handover (Traffic split, DB promotion, final sync)<br>Stage 5: Post-Migration (Stability tracking, artifact bundle generation)<br>Stage 6: TCO / FinOps<br>Stage 7: IAC DR Backup and Restore<br>Stage 8: AI Anywhere | Stage 2 VM REHOST: ready<br>Windows VM migration: under Test<br>Remaining stages: under construction |
| **Current Features (✅ Ready)**  | Single-Tab Mission Control: No CLI required, full GUI wrapper<br>Live Execution: Real-time logs streaming to browser<br>Visual Topology Designer: Drag-and-drop infra cloning<br>Offline Guest Repair: Pre-boot image patching for networks<br>Parallel Execution: Migrate multiple DBs/Servers simultaneously<br>No Database Required: Stateless backend (CSV + local browser storage)                                                                                                                                                          | **READY**                                                                                            |
| **Available Migration Methods** | Direct Shift & Lift (Images): Production Mode, External Offload, Direct Export<br><br>REHOST (Apps & Servers): Infra duplication, Full Clone, Quick Install<br><br>Database Replication: Dump & Restore, DBaaS Streaming, HA Replica<br><br>Kubernetes Migration: Genestack/Kubespray, OpenCenter (GitOps), Magnum export                                                                                                                                                                                                                        | REHOST VM migration: ready<br>Windows VM migration: under Test<br>Other methods: under construction  |
| **Supported OS Types**          | Ubuntu (20.04, 22.04, 24.04)<br>Debian (10, 11, 12)<br>CentOS 7<br>RedHat 6, 8<br>Rocky Linux 8 / 9<br>AlmaLinux 8 / 9<br>Windows Server 2016 / 2019                                                                                                                                                                                                                                                                                                                                                                                             | Linux VM rehost set: ready<br>Windows VM set: under Test                                             |
| **Future / Upcoming**           | Stage 6: TCO / FinOps (Right-sizing + cost summary)<br>Stage 7: IAC DR backup & restore (Terraform + GitOps hooks)<br>Stage 8: AI Anywhere (auto-repair + risk scoring)                                                                                                                                                                                                                                                                                                                                                                          | under construction                                                                                   |

## Current Workflow Updates

The restored Apollo-style README remains the base operator manual. These are the current workflow additions in this branch:

| Workflow | Current Behavior | Operator Benefit |
|----------|------------------|------------------|
| **MBUX / Apollo Tracker** | Reads jumphost telemetry, retained `/tmp/mig_*.log` files, browser-tracked VM jobs, Glance image jobs, and uploaded-image sentinels. | Running work no longer disappears just because one source is stale or log-only. |
| **Linux Image Repair** | Uses per-OS offline repair for Ubuntu, Debian, AlmaLinux, Rocky, CentOS, and RHEL, including CentOS 7 legacy `ifcfg` / `network.service` handling. | Migrated images are repaired before first FLEX boot instead of being debugged VM by VM. |
| **Windows Image Path** | Uses snapshot-based Glance migration plus offline VirtIO driver injection. | Windows workloads have a dedicated path instead of pretending they can use Linux NBD SSH streaming. |
| **Cloud Files / Glance Bridge** | Falls back to Rackspace image export/import and Cloud Files paths when direct Glance transfer is unreliable. | Large image moves keep progressing even when a direct endpoint path fails. |
| **GitOps Future Output** | Discovery, topology maps, repair profiles, validation reports, and rollback artifacts are structured for later Terraform, Ansible, IAC DR / GitOps workflows, and AI-agent automation. | Migration output can become durable customer infrastructure-as-code rather than one-time scripts. |

---

## Full Stage Breakdown

### Stage 0 — Customer Migration Tracker

A persistent backlog table for managing multiple customer migration engagements simultaneously.

- **CSV-backed tracker** — reads/writes `migration_tracker_db.csv`, survives server restarts
- **Per-customer rows** — customer name, environment size, migration status, notes, assigned engineer
- **Status chips** — color-coded: `Pending`, `In Progress`, `UAT`, `Done`, `Failed`
- **Inline editing** — update status and notes directly in the table, auto-saves
- **Why Move to FLEX promo panel** — business value overview tab for customer-facing presentations

---

### Stage 1 — Discovery & Assessment

```
 openrc credentials
       │
       ▼
 ┌─────────────┐    run_discovery.sh    ┌──────────────────┐
 │ OSPC Scanner│ ──────────────────────►│  servers.csv     │
 │  (live env) │                        │  network.csv     │
 └─────────────┘                        └──────────────────┘
       │                                        │
       │  mirror scan                           │ side-by-side
       ▼                                        ▼
 ┌─────────────┐                        ┌──────────────────┐
 │ FLEX Scanner│ ──────────────────────►│  FLEX inventory  │
 │ (target env)│   flavor auto-detect   │  flavor mapping  │
 └─────────────┘                        └──────────────────┘
```

| Panel | What it does | Output |
|-------|-------------|--------|
| **OSPC Scanner** | Authenticates via `openrc`, runs `run_discovery.sh` — scans Compute, Cinder, Security Groups, LBs, Floating IPs, DNS | `servers.csv`, `network.csv` |
| **FLEX Scanner** | Mirrors the same scan against the FLEX target environment | FLEX inventory for side-by-side comparison, flavor candidates |
| **Topology Import** | Parses existing OpenStack Bash/YAML scripts and reverse-engineers them into the visual canvas | Supports `openstack server create`, `network create`, `router` |
| **References Panel** | OSPC flavor catalog vs FLEX catalog with pricing — nearest-equivalent recommendation | Side-by-side flavor mapping table |

All scanners stream live output to an SSE terminal panel in the browser.

---

### Stage 2 — Migration Pipeline

Three paths depending on workload type:

```
 OSPC Workload
      │
      ├──► Option 1: Direct Shift & Lift  ──► VM snapshot → qemu-img → FLEX
      │
      └──► Option 2: REHOST
                │
                ├── Phase 1: Infra Cloning (Topology Designer)
                ├── Phase 2: Apps Servers & DB Replication
                └── Phase 3: Kubernetes Migration
```

---

#### Option 1: Direct Shift & Lift (Image Migration)

GUI wrapper for `ospc2flex_image_migrator.py` — three migration modes via a dedicated **Jump Host**, with automatic offline boot repair before upload.

**Migration Modes**

```
 OSPC VM (live)
      │
      ├─ Mode A: PRODUCTION ──── SSH-pipe /dev/vda ──────────────────────────────────────┐
      │          (no snapshot)    origin VM → jumphost (stream + convert in one step)     │
      │                                                                                   │
      ├─ Mode B: EXTERNAL OFFLOAD ── OSPC Glance snapshot ──► download to jumphost ──────┤
      │          (snapshot-based)                                                         │
      │                                                                                   │
      └─ Mode C: DIRECT EXPORT ── qemu-img reads live disk directly on jumphost ─────────┘
                 (no snapshot)                                                            │
                                                                                         ▼
                                                                              ┌──────────────────┐
                                                                              │  Stage 4: Convert │
                                                                              │  qemu-img → qcow2 │
                                                                              └────────┬─────────┘
                                                                                       │
                                                                              ┌────────▼─────────┐
                                                                              │ Stage 4.5: Offline│
                                                                              │  Guest Repair     │
                                                                              │  (custom_os /     │
                                                                              │   generic mode)   │
                                                                              └────────┬─────────┘
                                                                                       │
                                                                              ┌────────▼─────────┐
                                                                              │ Stage 5: Upload   │
                                                                              │ to FLEX Glance    │
                                                                              └────────┬─────────┘
                                                                                       │
                                                                                  FLEX VM ✓
```

**Pipeline Stages**

| Stage | Name | What happens |
|-------|------|-------------|
| 1 | Validate Dependencies | Check `openstack` CLI + `qemu-img` on jumphost |
| 2 | Create OSPC Snapshot | Glance snapshot (skipped in Production / Direct Export modes) |
| 2.5 | Clean Workspace | Remove leftover `.img` / `.qcow2` from previous runs |
| 3 | Disk Acquisition | **Production**: SSH-pipe `/dev/vda` from origin VM · **Offload**: download from Glance · **Direct**: read live disk |
| 4 | Convert Image | `qemu-img` auto-detect source format → convert to `qcow2` or `raw` |
| 4.5 | Offline Guest Repair | Mount image via `qemu-nbd`, run OS-profile repair (see below) |
| 4.6 | Repair Fallback | If 4.5 fails — retry with standalone `ospc2flex_offline_repair.sh` |
| 5 | Upload to FLEX Glance | Stream repaired image from jumphost → FLEX Glance |
| 5.5 | Clean Workspace | Remove uploaded artifact from jumphost |

**Offline Guest Repair — OS Profiles (Stage 4.5)**

Repairs the image while it is offline so it boots cleanly on FLEX on first try. Two modes:

| Mode | How it works |
|------|-------------|
| `custom_os` *(default)* | Connects image via `qemu-nbd`, runs `fsck`, auto-detects OS from `/etc/os-release`, applies per-OS profile |
| `generic` | Runs standalone `ospc2flex_offline_repair.sh` directly — no OS detection, no mount |

Per-OS repair profiles applied in `custom_os` mode:

| OS | Repair actions |
|----|---------------|
| **Ubuntu 24.04** | Delete `50-cloud-init.yaml`, write `99-ospc2flex.yaml` netplan (enp3s0), fix fstab UUID refs |
| **Ubuntu 20/22** | Write netplan config, fix fstab, clean cloud-init state, install `qemu-guest-agent` via chroot |
| **Debian** | Same as Ubuntu (apt safe from Ubuntu jumphost), netplan / interfaces fix |
| **Rocky / AlmaLinux** | Fix fstab, write NetworkManager config, enable legacy network via systemd symlink *(no chroot — RPM from Ubuntu jumphost unsafe)* |
| **CentOS / RHEL** | Fix fstab, ifcfg network config, disable cloud-init lock |
| **Fallback** | Detect fails → default to Ubuntu 24.04 netplan profile + generic repair |

All profiles: backup original `fstab` → `fstab.ospc2flex.bak`, strip OSPC MAC bindings, set correct network interface name for FLEX.

**Key Options**

| Option | Detail |
|--------|--------|
| `--jump-host` | Dedicated jumphost IP — all processing runs here (required) |
| `--origin-vm-ip` | Source VM IP for Production Mode (SSH-pipe `/dev/vda`) |
| `--direct-export` | Image live disk directly on jumphost — no snapshot |
| `--offline-repair-method` | `custom_os` (smart per-OS) or `generic` (standalone script) |
| `--dry-run` | Print all commands, make no changes |
| `--stop-before-snapshot` | Cleanly stop VM before snapshot for consistency |
| `--boot-test-vm` | Launch a test VM on FLEX after upload to verify boot |
| `--repair-guest` | Re-run offline repair on an already-uploaded image |
| `--fix-fstab` / `--fix-netplan` | Targeted repair flags |
| `--ssh-key-path` | `.pem` keypair for jumphost + origin VM access |
| `--target-format` | `qcow2` *(default)* or `raw` |
| Live terminal | SSE streaming panel — every stage logged in real time to browser |

---

#### Option 2 Phase 1: REHOST Infra Cloning (Topology Designer)

Interactive canvas for designing the full FLEX target infrastructure before any migration runs.

| Capability | Detail |
|-----------|--------|
| **Visual canvas** | Drag-and-drop nodes — VMs, networks, subnets, routers, LBs, security groups, volumes |
| **Live OSPC import** | Pulls current topology from OpenStack API directly into the canvas |
| **Validation engine** | 25+ checks — orphan nodes, missing router uplinks, duplicate IPs, CIDR overlaps |
| **Topology → Script** | Generates a full ordered OpenStack Bash deployment script from the canvas |
| **Script → Topology** | Paste an existing deployment script — canvas reconstructs automatically |
| **Keypair verification** | Validates all SSH keypairs exist in the FLEX project before deploy |
| **IP auto-propagation** | IPs entered in any panel persist to `localStorage` and inject into all other panels |
| **Execution plan** | Ordered table of every resource creation step with CLI command preview |

---

#### Option 2 Phase 2: Apps Servers & DB Replication

Script generator and parallel execution engine for migrating application servers and databases.

**► Node & DB Pairing — How it works**

Pairs are built automatically from the OSPC discovery scan and topology import. No manual IP entry required.

```
 Stage 1 OSPC Discovery scan
         │
         │  topology.json  (nodes: name, group, IP, OS, packages, runtimes)
         ▼
 "📥 Import Discovered Topology" button
         │
         │  parse topology.json
         │  assign data-role per node:
         │    group contains db/mysql/postgres/mariadb  → db-primary
         │    group contains replica/slave/standby      → db-replica
         │    everything else                           → server
         ▼
 Node cards rendered side by side
 ┌─────────────────────────┐   ┌──────────────────────────┐
 │  OSPC source card       │   │  FLEX target card         │
 │  name, IP, OS, packages │   │  name, FLEX IP (editable) │
 │  data-role="db-primary" │   │  data-role="db-primary"   │
 │  data-verified="false"  │   │  data-verified="false"    │
 └─────────────────────────┘   └──────────────────────────┘
         │                               │
         │  SSH connectivity test        │  SSH connectivity test
         │  packages verified on FLEX    │  border turns green on pass
         ▼                               ▼
 data-verified="true"           data-verified="true"
         │
         │  script generators read IPs directly from node cards
         │  parallel executor reads verified pairs into _rehostPairList
         ▼
 Scripts generated with real IPs ✓
```

**Node role assignment logic**

| Node group keyword | Assigned `data-role` | Used by |
|-------------------|---------------------|---------|
| `db`, `mysql`, `postgres`, `mariadb`, `data` | `db-primary` | DB script generator — primary IP |
| `replica`, `slave`, `standby` + any DB keyword | `db-replica` | DB script generator — replica IP |
| All other nodes | `server` | Server script generator + parallel executor |

**Per-node card details**

Each imported node shows:

| Field | Source |
|-------|--------|
| Name | From `topology.json` node name |
| OSPC IP | Auto-populated from discovery scan; persisted to `localStorage` |
| OS | Detected OS from OSPC scan (e.g. Ubuntu 22.04, Rocky 9) |
| Packages | Key packages found on OSPC node (nginx, mysql-server, python3…) |
| Runtimes | Runtime environments detected (Python, Node.js, Docker, PM2) |
| FLEX IP | Editable field — operator enters the target FLEX VM IP |
| Verification | SSH + package check against FLEX IP; border turns 🟢 green on pass, 🔴 red on fail |
| Force Override | Checkbox to mark a node verified manually (skips SSH check) |

**IP persistence** — OSPC and FLEX IPs are saved to `localStorage` keyed by node name (`node_ospc_ip_<name>`, `node_flex_ip_<name>`) and survive hard refresh. The script generators and parallel executor always read live values from the rendered node cards, not from a static config.

**DB IP resolution** — when a DB script is generated, IPs are pulled in this priority order:

```
Single DB (DBaaS via Cloud LB):
  LB Public IP:  dbaas_lb_ip field (manual override)
                 → card data-role="db-primary" ospc_custom_ip[]
                 → mock data fallback
  Flex DB IP:    card data-role="db-primary" flex_custom_ip[]
                 → mock data fallback

HA DB + Replica:
  OSPC HA VIP:   card data-role="db-primary" ospc_custom_ip[]
  OSPC Replica:  card data-role="db-replica" ospc_custom_ip[]
  Flex Primary:  card data-role="db-primary" flex_custom_ip[]
  Flex Replica:  card data-role="db-replica" flex_custom_ip[]
  Fallback on all: mock data (mock checkbox auto-activates)
```

---

**► Server Script Generator**

Two modes selectable before generation:

| Mode | What it generates |
|------|------------------|
| 📦 Quick Install | `apt`/`dnf` package installation script for matched FLEX servers |
| 🖥️ Full Rehost Clone | 13-layer deep-clone script (see table below) |

**Full Rehost Clone — 13 Layers**

| # | Layer | What it copies |
|---|-------|---------------|
| 1 | Server Identity | Hostname, timezone |
| 2 | SSH & Access | `sshd_config`, `authorized_keys`, `sudoers.d` |
| 3 | Users & Permissions | System users (UID/GID preserved), `/home/` sync |
| 4 | Disk / Mounts | `lsblk`/`df`/`fstab` audit — read-only, no changes |
| 5 | Packages & Repos | `apt`/`rpm` package list mirror |
| 6 | Kernel / Sysctl | `sysctl.conf`, `security/limits.d` |
| 7 | Network | `ip addr`/`route`/`netplan` export — manual apply |
| 8 | Runtime Env | Python, Node.js, Docker, PM2 |
| 9 | App Code & Config | `rsync` `/opt/app` `/srv` `/var/www`; IP substitution in config files |
| 10 | Service Units & Cron | `systemd` units, cron jobs |
| 11 | Data | PostgreSQL/MySQL dump & restore — opt-in only |
| 12 | TLS & Certs | Let's Encrypt transfer, CA trust store refresh |
| 13 | External Deps | `.env`/YAML external URL audit |

**Execution modes:** `🔍 Dry Run` · `🔒 Maint Mode` · `✂️ Cutover Mode` · `🟢 Live`

---

________________________________________
►  OSPC2FLEX — DB VM
Single SSH-accessible OSPC DB server → FLEX DB VM. Classic dump-transfer-restore with no cloud LB required.

```
 OSPC DB VM
        │
        │  mysqldump --single-transaction --routines --triggers --events
        │  per DB → gzip  →  /tmp/ospc_db_dumps/<db>.sql.gz
        ▼
 /tmp/ospc_db_dumps/  (on OSPC VM)
        │
        │  scp -i SSH_KEY
        ▼
 FLEX DB VM  /tmp/ospc_db_dumps/
        │
        │  CREATE DATABASE <db>
        │  zcat <db>.sql.gz | sudo mysql <db>
        ▼
 row-count validate → cutover app config ✓
        │
        └─► PHASE FINAL: comprehensive verification → HTML report
```

| Phase | Action |
|-------|--------|
| 0 Pre-flight | SSH to OSPC + FLEX reachability · disk space check |
| 1 Discover | `SHOW DATABASES` on OSPC · detect MySQL version |
| 2 Dump | `mysqldump` per DB → gzip on OSPC `/tmp` |
| 3 Transfer | `scp` dumps OSPC → FLEX `/tmp` |
| 4 Restore | `CREATE DATABASE` · `zcat *.sql.gz \| sudo mysql` per DB |
| 5 Validate | Row counts per table — OSPC vs FLEX |
| 6 Cutover | Update app `DB_HOST → FLEX_IP` · `SET GLOBAL read_only=ON` on OSPC |
| 7 Cleanup | `rm` temp dumps from OSPC + FLEX |
| Final | Full 14-check schema + data verification → HTML report |

________________________________________
►  OSPC2FLEX — Single DBaaS
OSPC DBaaS has no SSH access — only path is a Rackspace Cloud Load Balancer (port 3306, public internet). V2 streams `mysqldump` directly through a pipe to FLEX — zero local disk, no SCP step.

> **Setup:** Cloud CP → Networking → Load Balancers → Add External Node → DBaaS hostname:3306 → note VIP · `export DBAAS_PASS=... FLEX_ROOT_PASS=...`

```
 OSPC DBaaS  (no SSH — private network only)
        │
        └─► Cloud Load Balancer  (public VIP :3306)
                │
                │  nc -zv LB_IP 3306  +  mysql -h LB_IP  (auth check)
                ▼
             [preflight OK]
                │
                │  mysqldump -h LB_IP --single-transaction
                │    --no-tablespaces --set-gtid-purged=OFF
                │    --routines --triggers --events <db>
                │  | ssh FLEX_IP "mysql -u root <db>"
                │  (streaming pipe — zero local disk, no scp)
                ▼
             FLEX Primary
                │
                │  SELECT COUNT(*) per table  (LB vs FLEX)
                │  first N sample rows side-by-side
                ▼
             row-count validated ✓
                │
                └─► PHASE FINAL: comprehensive verification → HTML report
```

| Phase | OSPC Role | FLEX Role | Action |
|-------|-----------|-----------|--------|
| 0 Pre-flight | LB reachable | SSH-checked | `nc -zv LB:3306` · `mysql -h LB` auth · `df -h` `free -h` |
| 1 Discover | Source only | — | `SHOW DATABASES` via LB — no SSH to DBaaS ever |
| 2 Prepare FLEX | — | Receives setup | Install MySQL if absent · enable service · verify `root` access |
| 3 Stream | **Role ends after seed** | Receives full clone | `mysqldump` pipe · DROP + recreate each DB before import |
| 4 Validate | — | FLEX Primary | Row counts + first N sample rows OSPC vs FLEX |
| Final | — | FLEX Primary | Full 14-check verification · HTML report |

> `--master-data` and `--flush-logs` omitted — managed DBaaS does not grant `SUPER`. `--single-transaction` gives a consistent InnoDB snapshot without write locks.

________________________________________
►  OSPC2FLEX — DBaaS + Replica
Extends Single DBaaS — after FLEX primary is seeded via streaming pipe, the script provisions N FLEX replicas with GTID binary-log replication. OSPC is source only during the initial seed; no ongoing cross-cloud replication.

```
 OSPC DBaaS  (Cloud LB :3306)
        │
        │  mysqldump | ssh pipe → FLEX Primary  (streaming, no temp file)
        ▼
 FLEX Primary  (server-id=101 · GTID ON · log_bin · bind-address=0.0.0.0)
        │
        │  CREATE USER replicator IDENTIFIED WITH mysql_native_password
        │  GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.*
        │
        │  mysqldump --all-databases --master-data=2
        │            --set-gtid-purged=ON | gzip → /tmp/flex_seed.sql.gz
        ▼
 /tmp/flex_seed.sql.gz
        │
        │  cat seed.sql.gz | ssh REPLICA | gunzip | mysql  (per replica)
        ▼
 FLEX Replica(s)  (server-id=201+ · read_only=ON · relay_log)
        │
        │  STOP SLAVE; RESET SLAVE ALL; RESET MASTER  ← clears GTID history
        │  DROP DATABASE <db>  ← remove stale tables before import
        │  CHANGE MASTER TO MASTER_HOST=FLEX_IP
        │                   MASTER_AUTO_POSITION=1
        │                   GET_MASTER_PUBLIC_KEY=1
        │  START SLAVE
        ▼
 GTID replication running ✓
        │
        └─► PHASE FINAL: OSPC vs FLEX Primary + each Replica
                         HTML report — one column per node
```

| Phase | OSPC Role | FLEX Role | Action |
|-------|-----------|-----------|--------|
| 1 Pre-flight | LB reachable | All nodes SSH-checked | `nc`, `mysql` auth, `df -h`, `free -h` per node |
| 2 Prepare primary | — | FLEX Primary | Install MySQL · `server-id=101` · `log_bin` · GTID · `bind=0.0.0.0` · restart |
| 2 Prepare replicas | — | Each FLEX Replica | Install MySQL · `server-id=201+` · `read_only=ON` · GTID · restart |
| 3 Stream → Primary | **Role ends after seed** | Receives full clone | `mysqldump` LB pipe · DROP + recreate each DB |
| 4 Validate primary | — | FLEX Primary | Row counts + sample rows OSPC vs FLEX |
| 5 Seed dump | — | FLEX Primary | `--all-databases --master-data=2 --set-gtid-purged=ON` → gzip |
| 6 Seed replicas | — | Each FLEX Replica | `RESET MASTER` · DROP user DBs · stream seed · import |
| 7 Start replication | — | Each FLEX Replica | `CHANGE MASTER TO ... MASTER_AUTO_POSITION=1; START SLAVE` |
| 8 Postcheck | — | All nodes | `@@read_only` · `SHOW SLAVE STATUS` IO/SQL/Lag per replica |
| Final | — | Primary + Replicas | Full verification per node · HTML report |

________________________________________
►  OSPC2FLEX — HA DBaaS
OSPC seeds FLEX primary, then FLEX builds its own internal HA pair. No ongoing cross-cloud replication — OSPC is the source only during the initial seed.

```
 OSPC Primary  (HA VIP — SSH accessible)
        │
        │  mysqldump --single-transaction --routines --triggers --events
        │  | gzip → OSPC /tmp  →  scp → FLEX Primary /tmp
        ▼
 FLEX Primary  (OSPC role ends here)
        │
        │  CREATE DATABASE <db>;  zcat | sudo mysql  (per DB)
        │  row-count validate
        │
        │  CREATE USER replicator  GRANT REPLICATION SLAVE
        │  sudo mysqldump --all-databases --single-transaction
        │                 --master-data=2
        │                 | gzip → /tmp/flex_ha_seed.sql.gz
        ▼
 /tmp/flex_ha_seed.sql.gz
        │
        │  scp → each FLEX Standby /tmp/
        ▼
 FLEX Standby(s)
        │
        │  zcat flex_ha_seed.sql.gz | sudo mysql
        │  STOP SLAVE; RESET SLAVE ALL
        │  CHANGE MASTER TO MASTER_HOST=FLEX_PRI_IP
        │                   MASTER_AUTO_POSITION=1
        │  START SLAVE
        ▼
 FLEX internal HA pair ✓  (OSPC decommissioned after 48 h)
        │
        └─► PHASE FINAL: OSPC vs FLEX Primary + each Standby
                         HTML report — one column per node
```

| Phase | OSPC Role | FLEX Role | Action |
|-------|-----------|-----------|--------|
| 1 Pre-flight | SSH + `mysql` auth check | All nodes SSH-checked | MySQL version + GTID parity · `df -h` |
| 2 Expose source | HA VIP reachable | No DB yet | TCP:3306 + auth check on all nodes |
| 3 Seed primary | **Source — role ends here** | Receives full clone | `mysqldump` OSPC → SCP → `zcat \| mysql` + row-count validate |
| 4 Replication user | Not involved | FLEX Primary | `CREATE USER replicator` · `GRANT REPLICATION SLAVE` |
| 5 Seed standbys | Not involved | Pri → Standbys | Dump FLEX Primary → SCP to each standby → `zcat \| mysql` |
| 6 Start replication | Not involved | Each Standby | `CHANGE MASTER TO FLEX_PRI_IP; START SLAVE` |
| 7 HA control layer | Not involved | FLEX Primary | keepalived / ProxySQL / MaxScale VIP setup |
| Cutover | `super_read_only=ON` → decommission | Pri = new app endpoint | Repoint `DB_HOST` · 48 h stability window |
| Final | — | Primary + Standbys | Full verification per node · HTML report |

---

**► Comprehensive Verification Phase (all four scenarios)**

Every generated script ends with the same exhaustive comparison run against each target node (FLEX Primary + every replica/standby). Results accumulate across all phases into one TSV then render as a single HTML pivot table.

```
 _run_db_cmp_phase "FLEX PRIMARY"
 _run_db_cmp_phase "REPLICA 10.x.x.x"    ← repeated per replica/standby

 All phases → /tmp/db_mig_v2/cmp_<ts>.tsv
            → /tmp/db_mig_v2/db_report_<ts>.html
```

| # | Check | Method |
|---|-------|--------|
| 1 | Database list | `SHOW DATABASES` diff — system DBs excluded |
| 2 | User list | `mysql.user` — skipped with `[INFO]` when DBaaS returns `RESTRICTED` |
| 3 | Tables | `SHOW TABLES` per DB — sorted diff |
| 4 | TABLE STATUS | Engine + charset — `utf8` normalized to `utf8mb3` (MySQL 8.0 rename) |
| 5 | Columns | `information_schema.COLUMNS` — name, type, nullable, default, key, extra |
| 6 | Indexes | `information_schema.STATISTICS` — all definitions |
| 7 | Views | `information_schema.VIEWS` — definition text |
| 8 | Triggers | `information_schema.TRIGGERS` — event, timing, table |
| 9 | Routines | `information_schema.ROUTINES` — procedures + functions |
| 10 | Events | `information_schema.EVENTS` — name + status |
| 11 | Row counts | `SELECT COUNT(*)` per table |
| 12 | DDL | `SHOW CREATE TABLE` — `AUTO_INCREMENT` stripped before diff |
| 13 | Data ≤ 5 000 rows | Full table `md5sum` hash (`SELECT * ORDER BY 1 \| md5sum`) |
| 14 | Data > 5 000 rows | `CHECKSUM TABLE` — MySQL native CRC32 |

---

**► HTML Comparison Report**

After all phases complete, an embedded Python 3 script generates a self-contained dark-themed HTML report and prints `[REPORT] /tmp/db_mig_v2/db_report_<ts>.html` to the stream.

```
 All phase results → /tmp/db_mig_v2/cmp_<ts>.tsv
    │  python3 (inline heredoc in migration script)
    ▼
 /tmp/db_mig_v2/db_report_<ts>.html
    │  GET /api/agent1/db-report
    ▼
 Browser — dark-themed pivot table  (checks × phases)
```

| Feature | Detail |
|---------|--------|
| **Summary cards** | One card per phase — PASS / FAIL counts · green border = all pass · red = failures |
| **Pivot table** | Rows = every check · columns = FLEX Primary + each replica — color-coded cells |
| **Section grouping** | Checks grouped: Global → per-DB schema → per-table data |
| **Cell detail** | PASS shows row count or checksum mode · FAIL shows diff context |
| **Export CSV** | One-click full comparison matrix download |
| **View Report button** | Green banner in migration terminal links directly to report after script completes |
| **Endpoints** | `GET /api/agent1/db-report` (latest) · `GET /api/agent1/db-report/<filename>` |

---

**► Parallel Execution Engine**

| Control | Function |
|---------|----------|
| ⚡ Execute Server Migration | Runs the rehost script against all VM pairs simultaneously |
| Per-VM terminal | One live SSE streaming panel per node |
| Overview panel | Migration manifest + global status |
| ⏹ Stop | Cancels all in-flight executions |

> Generating a DB script automatically hides the server output panel and vice versa.

---

#### Option 2 Phase 3: Kubernetes Replication Manual / Auto

**Method 1 — Full Manual Mode** — step-by-step runbook with live command execution per stage

| Stage | Phase | Action |
|-------|-------|--------|
| 1 | Extract | K8s manifests, Helm values, PV specs from OSPC cluster |
| 2 | Collect | OSPC kubeconfig + cluster state snapshot |
| 3 | Prepare | FLEX network — subnets, security groups |
| 4 | Bootstrap | Genestack / OpenCenter on FLEX |
| 5 | Deploy | Kubernetes on FLEX via Genestack |
| 6 | Apply | Manifests, Helm charts, ConfigMaps |
| 7 | Migrate | Persistent volumes — Cinder → FLEX block storage |
| 8 | Validate | Pods, services, ingress, DNS health checks |
| 9 | Cutover | DNS switch + traffic redirect to FLEX |
| 10 | Decommission | OSPC cluster teardown |

Lifecycle cards filter the action table by phase group. Each stage has an expandable terminal log panel and file collection tracker. A progress bar tracks overall completion.

---

**Method 2 — Automated Deployment: Genestack / Kubespray  ·or·  OpenCenter**

Two deployment engines are available as selectable tabs. Both are fully driven from the browser via SSE-streaming Run buttons.

| Feature | Detail |
|---------|--------|
| Engine tabs | Switch between 🟩 Genestack / Kubespray, 🔵 OpenCenter, and 🔴 OSPC K8 → Flex Magnum in one click |
| Command table | Step · description · editable CLI command · target host · status |
| Run button | Each row executes via SSE streaming, auto-marks row status on completion |
| **Live IP injection** | Collected OSPC IPs (masters, workers, genestack host, jump host) auto-populate **all** Genestack and OpenCenter command templates the moment "Apply IPs to all rows" is clicked |
| OSPC → Genestack mapping table | Maps collected OSPC data (IPs, K8s version, roles) to exact Genestack config file paths |

> **IP injection flow:** Enter Flex master/worker/genestack IPs in the "Configure Server IPs" panel → click **Apply IPs to all rows** → `inventory.yaml`, SSH key distribution loops, kubeconfig rsync, and OpenCenter SSH commands all update instantly with real IPs.

---

**🟩 Genestack / Kubespray** — Ansible-driven cluster build on bare FLEX VMs

```
 OSPC scan output (IPs, K8s version, node roles)
        │
        │  map to Genestack inventory + group_vars
        ▼
 /etc/genestack/inventory/inventory.yaml
 /etc/genestack/inventory/group_vars/k8s_cluster/k8s-cluster.yml
        │
        │  ansible-playbook host-setup.yml  (pre-flight)
        │  ansible-playbook cluster.yml     (Kubespray — 30–60 min)
        ▼
 Kubernetes cluster on FLEX VMs
        │
        │  install-kube-ovn.sh  (Kube-OVN CNI)
        │  apply Helm overrides + your OSPC workload manifests
        ▼
 Workloads running on FLEX ✓
```

| Step | What happens | IP injection |
|------|-------------|-------------|
| 1 | SSH key distribution to all FLEX nodes | Loop uses `flex_m1/m2/m3`, `flex_w1/w2` from collected IPs |
| 2 | Clone Genestack repo + run `bootstrap.sh` | — |
| 3 | Write `inventory.yaml` from OSPC scan | All host IPs auto-populated; optional nodes (master-3, worker-2) included only when filled |
| 4 | Set `kube_version`, `container_manager` in `group_vars` | — |
| 5 | Run `host-setup.yml` pre-flight (on genestack host) | `ssh ubuntu@flex_gs` prefixed automatically |
| 6 | Run `cluster.yml` via Kubespray on genestack host | `ssh ubuntu@flex_gs` prefixed |
| 7 | Configure + install Kube-OVN CNI | Label loop uses `flex_m1/m2/m3` IPs |
| 8 | Pull kubeconfig from master + verify | `rsync ubuntu@flex_m1:/root/.kube/config` + `sed` with `flex_m1` API address |

**When to choose Genestack:** Full control over every node, network plugin, and K8s version. Best for large production clusters where you need to match the exact OSPC configuration.

---

**🔵 OpenCenter** — CLI-driven GitOps bootstrap (FluxCD + Kind)

```
 opencenter CLI
        │
        │  cluster init my-first-cluster --type kind   (~10 min config)
        ▼
 Kind cluster provisioned
        │
        │  opencenter cluster bootstrap                (~30–50 min)
        ▼
 FluxCD installed → reconciles all platform services automatically
        │
        │  cert-manager, kyverno, Headlamp UI, etc. — zero manual YAML
        ▼
 Cluster + platform services running ✓
```

| Step | Command | Output |
|------|---------|--------|
| 1 Install CLI | `curl -Lo opencenter .../opencenter-linux-amd64` | `opencenter` binary in `/usr/local/bin` |
| 2 Verify | `opencenter version` | `opencenter version 1.0.0` |
| 3 Init cluster | `opencenter cluster init my-first-cluster --type kind` | Cluster config generated |
| 4 Provision | `opencenter cluster setup my-first-cluster` | Cluster provisioned (30–50 min) |
| 5 GitOps | `opencenter cluster bootstrap my-first-cluster` | FluxCD reconciliation started |
| 6 Verify | `kubectl get pods -A` | All platform pods Running |
| 7 UI | `kubectl port-forward -n headlamp svc/headlamp 8080:80` | Headlamp dashboard at `:8080` |

**Why OpenCenter over Genestack?**

| Benefit | Detail |
|---------|--------|
| **Faster setup** | ~10 min config vs 30–60 min Ansible playbook tuning |
| **No inventory files** | `cluster init` generates config — no manual `inventory.yaml` editing |
| **GitOps by default** | FluxCD reconciles platform services automatically — no `helm install` per chart |
| **Self-healing** | FluxCD continuously reconciles desired state — drift is corrected automatically |
| **Platform services included** | `cert-manager`, `kyverno`, `Headlamp UI` bootstrapped automatically |
| **Simpler upgrades** | Update the Git repo → FluxCD propagates changes cluster-wide |
| **Best for** | Smaller clusters, fast bring-up, teams already using GitOps workflows |

> **Rule of thumb:** Use **Genestack** when you need node-level control and exact OSPC parity. Use **OpenCenter** when you want a production-grade cluster running in under an hour with GitOps from day one.

---

#### Method 3 — OSPC K8 → Flex Magnum (8-Stage SSH Migration)

Production-grade toolkit for migrating existing Kubernetes workloads from an **OSPC bare-metal cluster** to a new **Rackspace Flex Magnum** (OpenStack-managed) cluster. Lives in `ospc2flex-k8-migration/ospc-to-flex-k8-migrator/`.

> **Core rule:** do not import the old OSPC control plane into Magnum. Magnum creates a brand-new cluster. This toolkit exports, transforms, and re-applies all workloads onto the new cluster.

```
 OSPC K8 cluster  (bare-metal, SSH-accessible master)
        │
        │  Stage 1: SSH remote master export
        │  python -m ospc_to_flex_k8.cli export --master-ip … --ssh-key …
        │  ─ runs kubectl/helm ON the OSPC master via SSH
        │  ─ copies results back via scp → output/<ts>/export/
        ▼
 output/<ts>/export/
 ├── kubeconfig-ospc
 ├── manifests/  (cluster-scoped + per-namespace)
 ├── helm/       (releases, values, manifests)
 ├── images/images.txt
 ├── summary.json
 └── inventory.txt
        │
        │  Stage 2: Create Flex Magnum cluster
        │  openstack coe cluster create --cluster-template …
        ▼
 Flex Magnum K8s cluster  (CREATE_COMPLETE)
        │
        │  Stage 3: Transform manifests
        │  python -m ospc_to_flex_k8.cli transform …
        │  ─ storageClass remap · ingress class · service annotations
        │  ─ endpoint/FQDN substitution · node-selector strip
        │  ─ secret exclusion · metadata strip
        ▼
 output/<ts>/transform/transformed-manifests/
        │
        │  Stage 4: Restore workloads (phased)
        │  python -m ospc_to_flex_k8.cli restore --dry-run  (always first)
        │  Phase order: CRDs → NS → RBAC → ConfigMaps → Secrets →
        │               Storage → Services → Deployments → StatefulSets →
        │               DaemonSets → Ingresses → Policy → Helm
        ▼
 Workloads running on Flex (no data yet)
        │
        │  Stage 5: Data restore
        │  scripts/restore_db.sh  (MySQL / PostgreSQL — no hardcoded creds)
        │  templates/pvc_restore_helper.pod.yaml  (PVC + rsync)
        ▼
 Data replicated to Flex
        │
        │  Stage 6: Validate + smoke tests
        │  python -m ospc_to_flex_k8.cli validate …
        │  → validation-report.json + validation-summary.txt
        │  → optional HTTP health checks per URL
        ▼
 All checks PASS
        │
        │  Stage 7: Cutover
        │  ─ Maintenance window checklist (manual sign-off)
        │  ─ Final DB delta sync  (scripts/delta_sync.sh)
        │  ─ DNS/LB switch to Flex ingress IPs
        │  ─ Record cutover-record.json + timestamp
        ▼
 Flex is production ✓  (OSPC kept warm for 48 h)
        │
        │  Stage 8: Rollback plan
        │  python -m ospc_to_flex_k8.cli rollback-plan --stage …
        │  → rollback-plan.json with exact rollback commands
        ▼
 scripts/rollback_helper.sh  (if rollback triggered)
```

**Migration states tracked:**

| State | Meaning |
|-------|---------|
| `rehearsal` | Dry-run / test migration — no production impact |
| `pre-cutover` | Flex cluster ready, OSPC still primary |
| `cutover-started` | Traffic switch in progress |
| `cutover-complete` | Flex is primary, OSPC kept as safety net |
| `rollback-triggered` | Decision made to revert to OSPC |
| `rollback-complete` | OSPC is primary again, Flex traffic drained |

**Stage 1 — SSH remote master mode (mandatory):**

Stage 1 never runs kubectl locally. All commands execute on the OSPC master via SSH; results are copied back via `scp`.

```bash
export OSPC_MASTER_IP=10.1.2.3
export SSH_USER=centos
export SSH_KEY_PATH=~/.ssh/id_rsa

python -m ospc_to_flex_k8.cli export \
  --master-ip  $OSPC_MASTER_IP \
  --ssh-user   $SSH_USER \
  --ssh-key    $SSH_KEY_PATH \
  --output-dir ./output
```

**Python CLI commands:**

| Command | What it does |
|---------|-------------|
| `export` | SSH to OSPC master, run full cluster export, scp back |
| `plan` | Display migration plan as JSON |
| `transform` | Transform exported manifests for Flex compatibility |
| `create-target` | Create Flex Magnum cluster via OpenStack API |
| `restore` | Apply transformed manifests in correct phase order |
| `validate` | Run structured validation checks, write JSON + text report |
| `smoke-test` | Quick connectivity + pod health checks |
| `rollback-plan` | Generate rollback plan for a given migration state |

**Transform operations applied (Stage 3):**

| # | Transform | Detail |
|---|-----------|--------|
| 1 | `storageClassName` | Remapped per `storage-map.yaml` (e.g. `ospc-standard` → `cinder-standard`) |
| 2 | Ingress class | Annotation + `ingressClassName` remapped per `ingress-map.yaml` |
| 3 | Service annotations | LoadBalancer → Flex Octavia annotations |
| 4 | Endpoint / FQDN | String substitution per `endpoint-map.yaml` |
| 5 | nodeSelector / affinity / tolerations | Node-specific fields stripped |
| 6 | Namespace filter | Only `include_namespaces` from migration plan |
| 7 | Secret exclusion | Source-cluster SA tokens and listed names excluded |
| 8 | Metadata strip | `uid`, `resourceVersion`, `generation`, `managedFields`, `status` removed |
| 9 | RWX PVC flag | `ReadWriteMany` flagged in `transform-report.json` for manual review |

**Repo structure (`ospc2flex-k8-migration/ospc-to-flex-k8-migrator/`):**

```
├── src/ospc_to_flex_k8/     Python package (cli, exporter, transformer, validator …)
├── scripts/                 Shell wrappers for each stage
│   ├── export_ospc_k8.sh    Stage 1 SSH export (delegates to Python CLI)
│   ├── restore_db.sh        Stage 5 MySQL/PostgreSQL restore (no hardcoded creds)
│   ├── restore_pv.sh        Stage 5 PV block data restore
│   ├── delta_sync.sh        Stage 7 final DB delta sync
│   └── rollback_helper.sh   Stage 8 rollback executor
├── configs/                 Example YAML maps (storage, ingress, endpoint)
├── templates/               pvc_restore_helper.pod.yaml · restore-order.txt
├── docs/                    architecture.md · runbook.md · rollback.md · assumptions.md
├── tests/                   89 unit tests (transformer, validator, planner)
└── env.example              All required env vars with defaults
```

**Key limitations:**
- Live PV block data is **not** automatically migrated — use `restore_pv.sh`
- `ReadWriteMany` PVCs require NFS or Manila on Flex (not Cinder)
- Helm re-installs require the original chart registry to be reachable
- API version deprecations (e.g. `extensions/v1beta1`) are not auto-upgraded — use `kubectl-convert`
- This toolkit is **non-destructive** — it never deletes source resources

---

### Stage 3 — Validation & UAT

Automated testing harness for post-migration verification.

- **UAT input bundle injection** — reuses the Migration Output Bundle and reads the `uat-input/` view:
  - `discovery-output/discovery-manifest.json`
  - `discovery-output/source-inventory.json`
  - `discovery-output/target-inventory.json`
  - `stage2-migration-output/stage2-migration-manifest.json`
  - `stage2-migration-output/vm-migration-results.json`
  - `stage2-migration-output/image-migration-results.json`
  - `stage2-migration-output/data-migration-results.json`
  - `uat-input/uat-input-manifest.json`
  - `uat-input/uat-readiness-checklist.yaml`
  - `uat-input/uat-evidence-map.json`
  - `uat-input/uat-test-plan.yaml`
  - `uat-input/uat-bundle-index.json`
- **Cross-Cloud Identity Parity** — authenticates simultaneously against OSPC and FLEX; diffs RBAC roles and permission boundaries
- **Global API Health** — evaluates FLEX compute, network router, and storage quota limits
- **Endpoint Connectivity** — SSH, ping, and curl checks against newly-migrated IPs and Load Balancer URLs
- **A/B Traffic Split** — provisions HAProxy VM + DB replica for gradual traffic rollover
- **Verification Report Table** — auto-generated findings table with severity (INFO / WARN / ERROR), scope, and remediation hints
- **CSV export** — migration audit report downloadable as CSV

---

### Stage 4 — Cutover & Handover

Controlled production cutover workflow.

- **HAProxy provisioning** — auto-generates HAProxy VM setup script for A/B traffic split
- **DB replica promotion** — script to promote Flex DB replica to primary and repoint applications
- **Cutover checklist** — step-by-step operator sign-off list before OSPC decommission
- **Handover documentation** — generates customer-facing handover notes

---

### Stage 5 — Post-Migration

Stability monitoring, sign-off, and the formal Cloud Jumper output bundle.

- **Success / Failure marking** — operators mark the migration outcome per customer
- **Status persistence** — outcome written back to the customer tracker CSV
- **48–72h stability window guidance** — OSPC kept in `read_only` as warm standby before final decommission
- **Migration Output Bundle** — generates the durable handoff package:
  - `migration_manifest.json`
  - `discovery-output/discovery-manifest.json`
  - `discovery-output/source-inventory.json`
  - `discovery-output/target-inventory.json`
  - `discovery-output/dependency-seed.json`
  - `stage2-migration-output/stage2-migration-manifest.json`
  - `stage2-migration-output/vm-migration-results.json`
  - `stage2-migration-output/image-migration-results.json`
  - `stage2-migration-output/data-migration-results.json`
  - `stage2-migration-output/kubernetes-migration-results.json`
  - `terraform.tfvars.json`
  - `ansible_inventory.ini`
  - `repaired_image_metadata.json`
  - `boot_test_results.json`
  - `dependency_graph.json`
  - `uat-input/uat-input-manifest.json`
  - `uat-input/uat-readiness-checklist.yaml`
  - `uat-input/uat-evidence-map.json`
  - `uat-input/uat-test-plan.yaml`
  - `uat-input/uat-bundle-index.json`
  - `opencenter/estate-map.json`
  - `opencenter/day2-runbook.yaml`
  - `genestack/cloud-images.yaml`
  - `genestack/flavor-map.yaml`
  - `genestack/network-map.yaml`
  - zipped download archive

### Stage 6 — TCO / FinOps

TCO / FinOps turns the migration bundle into financial evidence and optimization actions.

| FinOps lane | What Cloud Jumper provides |
|---|---|
| OSPC baseline | Source flavors, storage, network, workload grouping, and migration wave context |
| FLEX projected run-rate | Target flavor map, booted target artifacts, storage/network placement, and project context |
| Right-sizing candidates | Workload facts and validation evidence for conservative post-migration optimization |
| Executive report | Cost comparison, wave savings, risk notes, and modernization value narrative |

Generated files:

- `finops/tco-report.json`
- `finops/tco-summary.csv`
- `finops/rightsize-candidates.json`

### Stage 7 — IAC DR Backup and Restore (Mission Control)

This stage captures tenant-owned infrastructure as Terraform-first restore artifacts, validates required upstream evidence, prepares cross-region/cross-cloud overlays, and exposes **GitOps integration** (repo push, OpenCenter-oriented restore prep under Option B). The migration output bundle may still include an optional `opencenter/` directory for Day-2 stubs when generated—there is **no separate OpenCenter tab** in the shell.

| IAC DR lane | What Cloud Jumper provides |
|---|---|
| Stage 7 readiness preflight | Required checks for target inventory, migration results, boot/UAT evidence, and Terraform region values |
| Target cloud credential profile | Source/target credential capture, OpenRC import, provider selection (FLEX/OpenStack), and target region settings |
| Terraform-first restore pack | `tenant-iac-dr/terraform/envs/default/terraform.tfvars.json`, generated target env overlays, and translation reports |
| Backup and export | Export IaC pack to configured Git backup repo path and/or S3-compatible object storage |
| GitOps / restore hooks | Push backup to configured GitOps tree; prepare OpenCenter-oriented restore scripts under `tenant-iac-dr/gitops-restore/` when using Option B |
| Runbooks and validation | Same-region and cross-region restore runbooks plus restore validation checklist |

### Stage 8 — AI Anywhere Integration

AI Anywhere consumes the complete chain as a private AI context pack.

| AI Anywhere input | Source |
|---|---|
| CloudJumper output | `migration_manifest.json`, `terraform.tfvars.json`, `ansible_inventory.ini`, repaired image metadata, boot/test results, dependency graph |
| TCO / FinOps output | TCO report, cost summary CSV, right-sizing candidates |
| Optional bundle slices | When present: `opencenter/` estate map, runbook, observability, GitOps workflow stubs alongside `tenant-iac-dr/` |
| Tenant IaC DR output | Tenant IaC DR pack, restore scope, backup policy, region map, target overlays, runbooks, and preflight/live-state reports |
| Optional raw evidence | Migration logs, repair logs, UAT logs, telemetry samples |

| AI Anywhere output | Purpose |
|---|---|
| `risk-score.json` | Scores customer migration risk and identifies blockers |
| `rightsize-recommendations.json` | Recommends safer FLEX flavor and capacity changes |
| `autorepair-plan.yaml` | Proposes boot/network/service repair actions with rollback notes |
| `terraform-patch-suggestions.json` | Suggests infrastructure-as-code changes from validated migration facts |
| `runbook-improvements.yaml` | Improves Day-2 runbooks from observed migration behavior |
| `dr-restore-improvements.yaml` | Suggests DR and restore process improvements from workload and platform facts |

### What Next — Mission Control To GitOps

The next horizon is making Cloud Jumper the translation layer between migration execution and durable customer operations:

```text
Cloud Jumper migration telemetry
        |
        v
Migration Output Bundle
        |
        +--> TCO / FinOps: baseline, run-rate, right-size, report
        |
        +--> IAC DR Backup and Restore: restore scope, preflight, target profiles, GitOps backup/export, optional OpenCenter prep
        |
        +--> AI Anywhere: repair, risk, right-size, patch, optimize
        |
        v
Terraform / Ansible / AI-agent optimization loop
```

The migration does not end when a VM boots. It ends when the customer estate can be rebuilt, reviewed, repaired, observed, and optimized from source-controlled artifacts.

---

## Script Generation Engine

All generated scripts share a common pattern:

```bash
run_cmd() {
  if [ "$DRY_RUN" = "1" ]; then
    echo "[DRY]  $LABEL"; echo "       $CMD"; return 0
  fi
  echo "[RUN]  $LABEL"
  eval "$CMD" && echo "[OK]   $LABEL" || { echo "[ERR]  $LABEL (exit $?)"; return 1; }
}
```

- **`DRY_RUN=1`** — prints every command with `[DRY]` prefix, zero changes made
- **`DRY_RUN=0`** — executes live, logs `[OK]` or `[ERR]` per step
- **`exec > >(tee -a "$LOG_FILE") 2>&1`** — all output written to timestamped log file
- Scripts are displayed in a syntax-highlighted panel, copyable, and executable directly from the browser via the SSE terminal

---

## Prerequisites & Installation

Runs on Ubuntu 22.04+ or WSL2.

```bash
# System dependencies
sudo apt-get update -y
sudo apt-get install -y python3 python3-pip python3-venv
sudo apt-get install -y qemu-utils
sudo apt-get install -y curl iputils-ping netcat-openbsd

# Python packages
pip3 install python-openstackclient python-octaviaclient flask
```

---

## Launch

```bash
chmod +x letsmove.sh
./letsmove.sh
```

Navigate to **https://127.0.0.1:5002** (or the WSL network IP shown in terminal output).

---

## Security & Persistence

- **No database** — all state lives in browser `localStorage` and local CSV files
- **Credentials sandboxed locally** — OpenRC tokens and SSH keys never leave the orchestration machine
- **IP auto-propagation** — OSPC and FLEX IPs entered once are persisted to `localStorage` and injected across all panels automatically, surviving hard refresh
- **Dry Run by default** — all script generators and execution engines default to `DRY_RUN=1`; operators must explicitly switch to Live mode
- **`/tmp/` cleanup** — all dump files and temp artifacts are removed in the Cleanup phase of every generated script

---

<div align="center">
<sub>Built for OpenStack Zen → OpenStack KVM migrations · Python 3.12 · Flask · SSE · WSL2</sub>
</div>
