<div align="center">
  <img src="https://img.shields.io/badge/OSPC-Legacy-f39c12?style=for-the-badge&logo=openstack&logoColor=white" />
  <img src="https://img.shields.io/badge/➜-MIGRATE-white?style=for-the-badge" />
  <img src="https://img.shields.io/badge/FLEX-Target-2ecc71?style=for-the-badge&logo=openstack&logoColor=white" />
  
  # OSPC2FLEX Deployment Engine
  
  *An advanced, interactive deployment orchestrator designed to systematically shift and lift OpenStack Private Cloud (OSPC) workloads directly into next-generation FLEX infrastructure.*
</div>

---

## 🚀 Overview

The **OSPC2FLEX Deployment Engine** is a python-based, event-driven web dashboard built specifically to streamline complex infrastructure migrations. 

Unlike traditional manual re-platforming, this toolchain provides a "Future Punk" interface that natively wraps CLI conversion tools, API scanners, and automated bash testing suites into a seamless 4-stage browser workflow. It evaluates source cloud state, generates topology mappings, executes live migrations (VM snapshots and QEMU conversion), and finally runs cross-cloud UAT validations—all without the operator needing to touch a Linux terminal.

## ⚙️ Architecture

- **Backend Logic**: Python 3.12, Flask 
- **Frontend UI**: Vanilla HTML/CSS/Javascript utilizing an event-driven `Server-Sent Events (SSE)` streaming architecture for live execution output.
- **Execution Environment**: Designed for Windows Subsystem for Linux (WSL), taking advantage of dynamic Bash scripting, Python subprocess threading, and OpenStack API modules.

---

## 🛠️ The 4-Stage Migration Pipeline

### 1. Assessment Scanner (Discovery Phase)
Integrates securely with legacy OSPC Identity endpoints to rapidly map out source infrastructure. 
The backend constructs dynamic execution scripts (`run_discovery.sh`) to scan and export all Compute nodes, Cinder volumes, Security Groups, Load Balancers, and DNS elements into standardized `servers.csv` and `network.csv` reports.

### 2. Configuration & Mapping (Strategy Phase)
An interactive topology builder that translates legacy components into the FLEX target language. Operators map OSPC IDs directly to FLEX subnets and inject critical deployment payloads, preparing a master Execution Table for automated deployment.

### 3. Direct Shift & Lift (Execution Phase)
The execution core. Provides a GUI for the `ospc2flex_image_migrator.py` engine.
- Calculates and validates local vs. cloud storage bridges.
- Live-snapshots OSPC targets without halting production.
- Downloads massive raw images directly over secure tunnels and reformats them natively using `qemu-img`.
- Includes advanced overrides for specific SSH Key injection (`.pem`) and raw Kubernetes configuration artifact application (Helm / YAML).

### 4. Validation Engine (Internal UAT)
A highly automated testing harness that ensures zero performance or access degradation post-migration.
- **Cross-Cloud Identity Parity**: Authenticates simultaneously against both OSPC and FLEX to diff RBAC roles and guarantee permission boundaries were mathematically cloned.
- **Global API Health**: Evaluates global FLEX compute, network router, and storage integrity limits.
- **Deep Endpoint Targeting**: Automatically executes `ssh`, `ping`, and `curl` integrity tunnels against specific newly-migrated IPs or LoadBalancer URLs to prove immediate viability.

---

## 📦 Prerequisites & Installation

The migration orchestrator is built to run natively on **Ubuntu Linux (22.04+)** or **Windows Subsystem for Linux (WSL)**.

Before launching the engine, ensure your system has the required hypervisor, network, and OpenStack dependencies installed:

```bash
# Update local apt indices
sudo apt-get update -y

# Install Python 3, Pip, and Virtual Environment handlers
sudo apt-get install -y python3 python3-pip python3-venv

# Install QEMU Utilities (Crucial for the Stage 3 image conversion pipeline)
sudo apt-get install -y qemu-utils 

# Install networking tools (Required for the Stage 4 UAT connectivity verification)
sudo apt-get install -y curl iputils-ping netcat-openbsd

# Ensure the OpenStack API client and web framework are available locally 
pip3 install python-openstackclient python-octaviaclient flask
```

---

## ⚡ Deployment & Initialization

The Engine utilizes a localized start script to isolate dependencies and spin up the orchestration GUI.

```bash
# Provide application execution permissions
chmod +x start.sh

# Spin up the Flask environment and launch the UI
./start.sh
```

Navigate your browser to `http://localhost:5001` or the network-assigned IP to access the Live Dashboard.

## 🔐 Security & Persistence
All operational cloud credentials, mapping secrets, and target inputs are securely sandboxed locally onto your orchestration machine via browser `localStorage` and temporary `$TMP/` bash injectors, preventing high-privilege token leaks when navigating across large multi-tenant domains.
