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

**► DB Script Generator — Single DB (OSPC DBaaS via Cloud Load Balancer)**

OSPC managed DBaaS instances have **no SSH access**. The only public path is via a Rackspace **Cloud Load Balancer** created in the same region, with MySQL (port 3306) and "Accessible on the Public Internet" selected. All dump commands run **locally** on the jumphost — never SSH to the DBaaS host.

```
 OSPC DBaaS (xxx.rackspaceclouddb.com — private network only, no SSH)
        │
        └─► Cloud Load Balancer (public VIP :3306)
                 │
                 │  Phase 0: nc -zv LB_IP 3306  +  mysql -h LB_IP auth   [local]
                 │  Phase 1: mysql -h LB_IP SHOW DATABASES                [local]
                 │  Phase 2: mysqldump -h LB_IP → local /tmp/*.sql.gz     [local, no SSH to DBaaS]
                 │
                 │  Phase 3: scp local dumps → Flex DB VM                 [local → SSH]
                 │  Phase 4: zcat | mysql restore                         [SSH → Flex]
                 │  Phase 5: row-count validate (LB vs Flex)              [local + SSH]
                 │
                 │  Phase 6: repoint app DB_HOST → Flex IP                [app config]
                 └─► Phase 7: rm local + Flex dumps · DELETE Cloud LB     [local + SSH + Cloud CP]
```

**Setup — before running the script:**
1. Cloud Control Panel → Networking → Load Balancers → **Add External Node** → paste DBaaS hostname, port 3306
2. Select **"Accessible on the Public Internet"** + **MySQL** protocol
3. Note the LB public VIP — enter it in the **LB Public IP** field in the UI
4. Export credentials: `export DBAAS_PASS=yourpassword && export FLEX_ROOT_PASS=yourpassword`

| Phase | Runs on | Action |
|-------|---------|--------|
| 0 Pre-flight | Local | `nc -zv LB_IP 3306` + `mysql -h LB_IP` auth + SSH → Flex |
| 1 Discover | Local | `mysql -h LB_IP SHOW DATABASES` — no SSH to DBaaS |
| 2 Dump | **Local** | `mysqldump -h LB_IP --single-transaction` per DB → local gzip |
| 3 Transfer | Local → SSH | `scp` local dumps → Flex DB VM |
| 4 Restore | SSH → Flex | `zcat *.sql.gz \| mysql` per DB |
| 5 Validate | Local + SSH | Row counts: `mysql -h LB_IP` vs `ssh Flex mysql` per table |
| 6 Cutover | App config | Repoint `DB_HOST → FLEX_IP` · delete Cloud LB to freeze DBaaS writes |
| 7 Cleanup | Local + SSH | `rm` local + Flex dumps · **manual**: delete Cloud LB from Cloud CP |

> **Note:** `--master-data` and `--flush-logs` are omitted — managed DBaaS does not grant the `SUPER` privilege these options require. `--single-transaction` provides consistent read-only snapshot for InnoDB tables.

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
| Engine tabs | Switch between 🟩 Genestack / Kubespray and 🔵 OpenCenter in one click |
| Command table | Step · description · editable CLI command · target host · status |
| Run button | Each row executes via SSE streaming, auto-marks row status on completion |
| IP injection | Genestack host + jump host IPs auto-fill all command templates |
| OSPC → Genestack mapping table | Maps collected OSPC data (IPs, K8s version, roles) to exact Genestack config file paths |

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

| Step | What happens |
|------|-------------|
| 1 | SSH key distribution to all FLEX nodes |
| 2 | Clone Genestack repo + run `bootstrap.sh` |
| 3 | Write `inventory.yaml` from OSPC scan (masters, workers, IPs) |
| 4 | Set `kube_version`, `container_manager` in `group_vars` |
| 5 | Run `host-setup.yml` pre-flight playbook |
| 6 | Run `cluster.yml` via Kubespray (full K8s cluster) |
| 7 | Configure + install Kube-OVN CNI |
| 8 | Apply OSPC workload manifests, Helm charts, PV configs |

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
