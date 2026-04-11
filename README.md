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

Connects to the live OSPC environment and maps all infrastructure into structured reports.

**OSPC Scanner**
- Authenticates against OSPC Identity endpoints via `openrc` credential injection
- Generates and executes `run_discovery.sh` — scans Compute nodes, Cinder volumes, Security Groups, Load Balancers, Floating IPs, DNS records
- Exports results to `servers.csv` and `network.csv`
- Live SSE terminal streaming of discovery progress

**FLEX Scanner**
- Mirrors the same scan against the target FLEX environment
- Produces a FLEX inventory for side-by-side comparison
- Auto-detects flavor and network mapping candidates

**Topology Import**
- Parses existing OpenStack deployment scripts (YAML/Bash heredocs) and reverse-engineers them into the visual topology canvas
- Supports `openstack server create`, `openstack network create`, `openstack router` command extraction

**References Panel**
- OSPC flavor catalog (CPU/RAM/disk specs)
- FLEX flavor catalog with pricing
- Side-by-side flavor mapping with nearest-equivalent recommendation

---

### Stage 2 — Migration Pipeline

#### Option 1: Direct Shift & Lift (Image Migration)

GUI wrapper for the `ospc2flex_image_migrator.py` engine — moves running VMs as raw disk images.

- **Live snapshot** — snapshots OSPC instances without halting production
- **Secure download** — pulls raw images over SSH tunnel from OSPC
- **QEMU conversion** — reformats raw → FLEX-compatible format via `qemu-img`
- **SSH key injection** — supports `.pem` keypair override per instance
- **Storage bridge validation** — calculates local disk space requirements before download
- **Kubernetes artifact support** — applies Helm charts and raw YAML configs post-lift
- **Live streaming terminal** — SSE output panel shows conversion progress in real time

---

#### Option 2 Phase 1: REHOST Infra Cloning (Topology Designer)

An interactive canvas for designing the FLEX target infrastructure before any migration runs.

- **Visual drag-and-drop topology builder** — nodes for VMs, networks, subnets, routers, load balancers, security groups, volumes
- **Live OpenStack import** — pulls current OSPC topology directly from the API into the canvas
- **Topology validation engine** — 25+ checks: orphan nodes, missing router uplinks, duplicate IPs, invalid CIDR overlaps, unreachable subnets
- **Topology → Bash script** — generates a full ordered OpenStack deployment script from the canvas, phase-aware
- **Script → Topology reverse parser** — paste an existing deployment script and reconstruct the canvas automatically
- **Keypair verification** — validates all SSH keypairs referenced in the topology exist in the target FLEX project
- **IP auto-propagation** — OSPC and FLEX IPs entered in any panel are persisted to `localStorage` and injected into all other panels automatically
- **Execution plan table** — ordered list of every resource creation step with OpenStack CLI command preview

---

#### Option 2 Phase 2: Apps Servers & DB Replication

Script generator + parallel execution engine for migrating application servers and databases.

**Node Discovery Panel**
- Detects OSPC and FLEX node pairs from the topology canvas via `data-role` stamping
- Supports node roles: `server`, `db-primary`, `db-replica`
- Auto-populates IPs into script generators; falls back silently to mock data

**Mock Pairs Preview Table**
- Pre-built example migration pairs (3 servers + 1 Single DB + 2 HA DB nodes)
- "Use Mockup Data" checkbox — injects mock IPs into both script generators and parallel executor for dry-run testing

**Server Script Generator**
- **Quick Install mode** — generates an apt/dnf package installation script for matched FLEX servers
- **Full Rehost Clone mode** — generates a 13-layer server cloning script:
  1. Server Identity (hostname, timezone)
  2. SSH & Access (sshd\_config, authorized\_keys, sudoers)
  3. Users & Permissions (UID/GID-preserved user recreation, `/home/` sync)
  4. Disk / Mounts (lsblk/df/fstab audit — read-only)
  5. Packages & Repos (apt/rpm package list mirror)
  6. Kernel / Sysctl (sysctl.conf, security/limits.d)
  7. Network (ip addr/route/netplan export — manual apply)
  8. Runtime Env (Python, Node.js, Docker, PM2)
  9. App Code & Config (rsync `/opt/app`, `/srv`, `/var/www`; IP substitution in config files)
  10. Service Units & Cron (systemd units, cron jobs)
  11. Data (PostgreSQL/MySQL dump & restore — opt-in)
  12. TLS & Certs (Let's Encrypt transfer, CA trust store refresh)
  13. External Deps (`.env`/YAML external URL audit)
- **Dry Run / Live / Maintenance / Cutover** execution mode selector
- **`run_cmd()` wrapper** — every command prints `[DRY]` in dry run or `[RUN]/[OK]/[ERR]` in live mode

**DB Script Generator — Single DB**
- Scenario: single OSPC source → single Flex DB VM
- 7-phase pipeline: Pre-flight → Discover → Dump → Transfer → Restore → Validate → Cutover
- `mysqldump --single-transaction --master-data=2` per database → gzip → scp → restore
- Row-count validation per table (OSPC vs FLEX) before cutover
- Dry Run support throughout

**DB Script Generator — HA DB + Replica (Reengineered)**
- New self-contained approach — no ongoing cross-cloud replication dependency:
  - **Phase 5**: Expose source — verify Flex primary can reach OSPC HA VIP:3306 (TCP + auth); verify all 3 nodes engine/version/GTID
  - **Phase 6**: Verify engines — MySQL/MariaDB version + GTID mode parity across OSPC, Flex primary, Flex replica
  - **Phase 7**: Seed Flex primary — `mysqldump --single-transaction` from OSPC HA VIP → restore on Flex primary → row-count validate. **OSPC role ends here.**
  - **Phase 8**: Bootstrap Flex-internal HA — create `REPLICATION SLAVE` user on Flex primary; dump Flex primary → restore on Flex replica (self-contained seed)
  - **Phase 9**: Start Flex-internal replication — `CHANGE MASTER TO MASTER_HOST=FLEX_PRI_IP; START SLAVE` on Flex replica; monitor `Seconds_Behind_Master → 0`
  - **Phase 10**: Cutover — set OSPC `read_only=ON`; repoint app `DB_HOST → Flex primary`; Flex replica provides HA; 48h stability window; OSPC decommissioned
- Result: `OSPC Primary → (dump/restore) → Flex Primary → (internal replication) → Flex Replica`

**Parallel Execution Engine**
- `⚡ Execute in Parallel` button — runs the generated rehost script against all VM pairs simultaneously
- Per-VM streaming terminal panel — one SSE terminal block per node, live output
- Overview panel — migration manifest and global status
- Stop button — cancels all in-flight executions

**Panel Exclusivity**
- Generating a DB script hides the server output panel and vice versa — prevents confusing overlap

---

#### Option 2 Phase 3: Kubernetes Replication Manual / Auto

Full K8s migration lifecycle planner with two modes.

**Method 1 — Full Manual Mode**

Step-by-step runbook with live command execution per stage:

| Stage | Description |
|-------|-------------|
| 1 | Extract K8s manifests, Helm values, PV specs from OSPC cluster |
| 2 | Collect OSPC kubeconfig + cluster state |
| 3 | Prepare FLEX network (subnets, security groups) |
| 4 | Bootstrap Genestack / OpenCenter on FLEX |
| 5 | Deploy Kubernetes on FLEX via Genestack |
| 6 | Apply manifests, Helm charts, ConfigMaps |
| 7 | Migrate persistent volumes (Cinder → FLEX block storage) |
| 8 | Validate pods, services, ingress, DNS |
| 9 | DNS cutover + traffic switch |
| 10 | Decommission OSPC cluster |

- **Lifecycle cards** — clickable cards filter the action table to show only relevant stage rows
- **Per-stage log panels** — expandable terminal output per step
- **File collection tracker** — marks artifact files as collected/pending
- **Progress bar** — tracks overall K8s migration completion

**Method 2 — Automated Deployment**

Genestack / OpenCenter automated deployment table:

- Multi-column command table: step number, what it does, OpenStack/Genestack CLI command (editable textarea), target host, status
- Each row has a **Run** button — executes the command via SSE streaming and marks status
- IP injection — Genestack host and jump host IPs auto-fill into all command templates
- Covers: Genestack bootstrap, Kubernetes cluster creation, namespace setup, Helm chart deployment, PV migration, health checks

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
