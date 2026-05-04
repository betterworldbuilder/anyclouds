# Architecture

## Overview

This toolkit migrates Kubernetes workloads from a source cluster running on OSPC
(OpenStack Private Cloud) to a new target cluster created in **Rackspace Flex**
using **Magnum**.

## Core Rule

> **Do not import the old OSPC control plane into Magnum.**

Magnum creates a brand-new cluster from a `ClusterTemplate`. This toolkit therefore:

1. **Exports** source cluster config, Helm metadata, image references, and data metadata from OSPC.
2. **Designs and validates** the Flex Magnum ClusterTemplate against Magnum 2025.2 requirements.
3. **Creates** a new Flex Magnum target cluster.
4. **Transforms** exported manifests to be Flex-compatible.
5. **Restores** workloads into the new target cluster.
6. **Restores** data via explicit helper workflows.
7. **Validates** and smoke-tests the Flex cluster (incl. Magnum health + LB test).
8. **Cuts over** traffic (DNS/LB switch).
9. **Rolls back** if needed.

## Stage Pipeline

```
OSPC Cluster                             Rackspace Flex
─────────────                            ──────────────
Stage 1: Export ──→ local output/

                                         Stage 2: Design & validate ClusterTemplate
                                                     │
                                         Stage 3: Create Magnum cluster
                                                     │
Stage 4: Transform ──→ output/<ts>/transform/        │
                                                     ▼
Stage 5: Restore apps ───────────────────→ Flex cluster
Stage 6: Restore data ───────────────────→ Flex PVCs / DBs
Stage 7: Test & validate ────────────────→ Flex validation (incl. LB test)
Stage 8: Cut over ────────────────────────→ DNS/LB switch
Stage 9: Rollback (if needed) ───────────→ Back to OSPC
```

## Stage 2 — ClusterTemplate Design and Validation

Before creating a cluster (Stage 3), the target ClusterTemplate must be validated
to confirm it meets Magnum 2025.2 requirements:

| Check | Expected value | Impact if wrong |
|-------|---------------|-----------------|
| `coe` | `kubernetes` | Cluster will not run K8s workloads |
| `image_os_distro` | `fedora-coreos` | Cluster boot will fail on Magnum 2025.2 |
| `external_network_id` | (any valid UUID) | Floating IPs and LBs will not work |
| `network_driver` | `flannel` or `calico` | Pod networking will be broken |
| `volume_driver` | `cinder` | PVC provisioning will fail |
| `keypair_id` | (set) | Cannot SSH to nodes for debugging |
| `master_lb_enabled` | informational | Record for HA planning |
| `flavor_id` + `master_flavor_id` | both set | Cluster create will fail |

Run the check with:

```bash
python -m ospc_to_flex_k8.cli design-template \
  --template-name flex-k8s-1-29-coreos \
  --openrc ~/openrc.sh \
  --output-dir ./output/<ts>
```

Output is written to `output/<ts>/design/design-report.json`.

## Magnum 2025.2 Driver Note

Magnum 2025.2 **deprecates** the Heat-based cluster driver.
New clusters should use the **`k8s_capi_helm`** or **`k8s_cluster_api`** driver
(Cluster API for OpenStack, CAPO).

- Templates created with the Heat driver will display a deprecation warning in the
  `driver_note` field of the design-report.
- Existing clusters created with Heat continue to work until the next major Magnum
  release removes the driver entirely.
- For new Flex deployments, always request a CAPI-based ClusterTemplate from your
  Rackspace account team.

## Stage 1 — Remote Master Mode

All export commands run **on the OSPC master node via SSH**. This avoids:
- Needing local kubectl configured for the source cluster.
- Firewall issues accessing the Kubernetes API from outside.
- Version mismatches between local kubectl and the source API server.

```
Local machine  ──SSH──→  OSPC master  ──kubectl/helm──→  OSPC K8s API
                                        (runs exports)
               ←──scp───  OSPC master
(files copied back)
```

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| SSH remote-master export | Works through firewalls; kubectl is already configured on master |
| Phased restore order | CRDs → Namespaces → RBAC → Config → Storage → Workloads → Ingress |
| No live PV data migration | Block data migration requires explicit coordination; scripted separately |
| ruamel.yaml backend | Preserves YAML comments, quotes, and ordering |
| Shell wrapper + Python CLI | Shell wrappers for operators; Python for programmatic use and testing |

## Output Directory Structure

```
output/
└── <timestamp>/
    ├── export/
    │   ├── kubeconfig-ospc
    │   ├── inventory.txt
    │   ├── summary.json
    │   ├── manifests/
    │   │   ├── cluster/
    │   │   └── namespaces/
    │   ├── helm/
    │   ├── images/
    │   └── logs/
    ├── design/                         ← Stage 2 (NEW)
    │   └── design-report.json
    ├── transform/
    │   ├── transformed-manifests/
    │   ├── transform-report.json
    │   └── logs/
    ├── restore/
    │   ├── apply-report.json
    │   ├── restore-order.txt
    │   └── logs/
    └── validation/                     ← Stage 7 (NEW)
        ├── validation-report.json
        └── validation-summary.txt
```

## Component Map

| Module | Responsibility |
|--------|----------------|
| `exporter.py` | SSH remote-master export; scp copy-back |
| `transformer.py` | Manifest transformation engine |
| `planner.py` | Migration plan loading; phase ordering |
| `magnum.py` | Flex Magnum cluster lifecycle via `openstack` CLI |
| `restore.py` | Phased kubectl apply to target cluster |
| `validator.py` | Post-migration health checks |
| `manifests.py` | Low-level manifest manipulation helpers |
| `io_utils.py` | YAML/JSON I/O, subprocess wrapper, logging |
| `models.py` | All dataclasses and enums |
| `cli.py` | 9-command argparse CLI |
