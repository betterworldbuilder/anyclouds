<div align="center">

<h1>🚀 OSPC2FLEX Mission Control</h1>

<p><strong>Full-cycle browser dashboard for migrating OpenStack Private Cloud (OSPC) workloads to Rackspace FLEX</strong></p>

<p>
  <img src="https://img.shields.io/badge/Python-3.12-3776ab?style=for-the-badge&logo=python&logoColor=white" alt="Python">
  <img src="https://img.shields.io/badge/Flask-2.x-000000?style=for-the-badge&logo=flask&logoColor=white" alt="Flask">
  <img src="https://img.shields.io/badge/OpenStack-OSPC→FLEX-ed1944?style=for-the-badge&logo=openstack&logoColor=white" alt="OpenStack">
  <img src="https://img.shields.io/badge/Platform-WSL2%20%2F%20Linux-0078d4?style=for-the-badge&logo=linux&logoColor=white" alt="Platform">
</p>

<p>
  <img src="https://img.shields.io/badge/Lifecycle_Stages-6-22c55e?style=flat-square" alt="Stages">
  <img src="https://img.shields.io/badge/Migration_Strategies-5-f59e0b?style=flat-square" alt="Strategies">
  <img src="https://img.shields.io/badge/Live_Streaming-SSE-a855f7?style=flat-square" alt="SSE">
  <img src="https://img.shields.io/badge/No_DB-CSV_%2B_localStorage-3b82f6?style=flat-square" alt="No DB">
  <img src="https://img.shields.io/badge/Genestack-K8s_Integration-0ea5e9?style=flat-square" alt="Genestack">
</p>

<br>

> **One tab. Six stages. Zero spreadsheets.**
> Discovery → Topology Design → Script Generation → Live Execution → UAT Sign-off → Cutover

</div>

---

## Table of Contents

- [Why This Tool Exists](#why-this-tool-exists)
- [Architecture](#architecture)
- [Full Stage Breakdown](#full-stage-breakdown)
  - [Stage 0 — Customer Migration Tracker](#stage-0--customer-migration-tracker)
  - [Stage 1 — Discovery & Assessment](#stage-1--discovery--assessment)
  - [Stage 2 — Migration Pipeline](#stage-2--migration-pipeline)
    - [Option 1: Direct Shift & Lift (Image Migration)](#option-1-direct-shift--lift-image-migration)
    - [Option 2 Phase 1: REHOST Infra Cloning (Topology Designer)](#option-2-phase-1-rehost-infra-cloning-topology-designer)
    - [Option 2 Phase 2: Apps Servers & DB Replication](#option-2-phase-2-apps-servers--db-replication)
    - [Option 2 Phase 3: Kubernetes Replication Manual / Auto](#option-2-phase-3-kubernetes-replication-manual--auto)
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

GUI wrapper for `ospc2flex_image_migrator.py` — migrates running VMs as raw disk images without downtime.

```
 OSPC VM (live)
      │
      │  live snapshot (no halt)
      ▼
 raw image
      │
      │  scp over SSH tunnel
      ▼
 local disk
      │
      │  qemu-img convert
      ▼
 FLEX-compatible image
      │
      │  upload + boot
      ▼
 FLEX VM ✓
```

| Feature | Detail |
|---------|--------|
| Live snapshot | Snapshots OSPC instances without halting production |
| Secure download | Pulls raw images over SSH tunnel |
| QEMU conversion | `qemu-img` reformats raw → FLEX-compatible |
| SSH key injection | `.pem` keypair override per instance |
| Storage validation | Calculates local disk space needed before download |
| K8s artifact support | Applies Helm charts and raw YAML configs post-lift |
| Live terminal | SSE streaming panel shows conversion progress in real time |

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

**► Node pairing & mock data**

| Component | Detail |
|-----------|--------|
| Node Discovery | Auto-detects OSPC↔FLEX pairs via `data-role` — roles: `server`, `db-primary`, `db-replica` |
| Mock Pairs Table | Pre-built pairs (3 servers + 1 Single DB + 2 HA DB) for dry-run testing without real nodes |
| Use Mockup Data | Checkbox — injects mock IPs into both script generators and the parallel executor |

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

**► DB Script Generator — Single DB**

```
 OSPC DB
    │  mysqldump --single-transaction --master-data=2
    ▼
 dump.sql.gz
    │  scp
    ▼
 FLEX DB
    │  zcat | mysql
    ▼
 row-count validate → cutover app config ✓
```

| Phase | Action |
|-------|--------|
| 0 Pre-flight | SSH + MySQL reachability, disk space |
| 1 Discover | `SHOW DATABASES` on OSPC |
| 2 Dump | `mysqldump` per DB → gzip |
| 3 Transfer | `scp` to FLEX `/tmp` |
| 4 Restore | `zcat *.sql.gz \| mysql` |
| 5 Validate | Row count per table — OSPC vs FLEX |
| 6 Cutover | Update app `DB_HOST` → FLEX, restart services |
| 7 Cleanup | Remove temp dumps from both sides |

---

**► DB Script Generator — HA DB + Replica**

Self-contained approach — OSPC seeds Flex primary, then Flex builds its own internal HA pair. No ongoing cross-cloud replication.

```
 OSPC Primary (HA VIP)
        │
        │  Phase 7: mysqldump → restore  (OSPC role ends here)
        ▼
 Flex Primary
        │
        │  Phase 8: internal dump → restore
        ▼
 Flex Replica
        │
        │  Phase 9: CHANGE MASTER TO MASTER_HOST=FLEX_PRI_IP
        │           START SLAVE → lag monitor → 0
        ▼
 Flex internal HA pair ✓  (OSPC decommissioned)
```

| Phase | OSPC Role | FLEX Role | Action |
|-------|-----------|-----------|--------|
| 5 Expose source | HA VIP reachable | No DB yet | TCP:3306 + auth check on all 3 nodes |
| 6 Verify engines | Version checked | Pri + Rep verified | MySQL version + GTID mode parity |
| 7 Seed Flex primary | **Role ends here** | Receives full clone | `mysqldump` from OSPC → restore + row-count validate |
| 8 Bootstrap internal HA | Not involved | Pri seeds Rep | `REPLICATION SLAVE` user on Flex Pri; dump Pri → restore Rep |
| 9 Start Flex replication | Not involved | Rep follows Pri | `CHANGE MASTER TO FLEX_PRI_IP; START SLAVE`; lag → 0 |
| 10 Cutover | `read_only=ON` → decommission | Pri = new app endpoint | Repoint `DB_HOST`; 48h stability window |

---

**► Parallel Execution Engine**

| Control | Function |
|---------|----------|
| ⚡ Execute in Parallel | Runs the rehost script against all VM pairs simultaneously |
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

**Method 2 — Automated Deployment (Genestack)**

| Feature | Detail |
|---------|--------|
| Command table | Step · description · editable CLI command · target host · status |
| Run button | Each row executes via SSE streaming and auto-marks status |
| IP injection | Genestack host + jump host IPs auto-fill all command templates |
| Coverage | Genestack bootstrap → K8s cluster → namespaces → Helm → PV migration → health checks |

---

### Stage 3 — Validation & UAT

Automated testing harness for post-migration verification.

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

Stability monitoring and sign-off.

- **Success / Failure marking** — operators mark the migration outcome per customer
- **Status persistence** — outcome written back to the customer tracker CSV
- **48–72h stability window guidance** — OSPC kept in `read_only` as warm standby before final decommission

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

Navigate to **http://localhost:5001** (or the WSL network IP shown in terminal output).

---

## Security & Persistence

- **No database** — all state lives in browser `localStorage` and local CSV files
- **Credentials sandboxed locally** — OpenRC tokens and SSH keys never leave the orchestration machine
- **IP auto-propagation** — OSPC and FLEX IPs entered once are persisted to `localStorage` and injected across all panels automatically, surviving hard refresh
- **Dry Run by default** — all script generators and execution engines default to `DRY_RUN=1`; operators must explicitly switch to Live mode
- **`/tmp/` cleanup** — all dump files and temp artifacts are removed in the Cleanup phase of every generated script

---

<div align="center">
<sub>Built for Rackspace OSPC → FLEX migrations · Python 3.12 · Flask · SSE · WSL2</sub>
</div>
