# Assumptions and Limitations

## Architecture Assumptions

| Assumption | Impact if wrong |
|-----------|----------------|
| OSPC master node is SSH-accessible from the machine running Stage 1 | Export will fail — open firewall or use a bastion jump host |
| kubectl and optionally helm are installed on the OSPC master | Exports will fail or be incomplete |
| The OSPC cluster uses standard Kubernetes RBAC | RBAC manifests are exported and applied verbatim |
| The source cluster is healthy at export time | Exported manifests reflect whatever state the cluster is in |

## Kubernetes Compatibility

- Tested target range: Kubernetes 1.24 – 1.29
- API version deprecations (e.g. `extensions/v1beta1` Ingress → `networking.k8s.io/v1`) are **not** automatically upgraded — use `kubectl-convert` separately if needed
- `CustomResourceDefinitions` from old API versions may require manual migration

## Magnum 2025.2 Assumptions

| Assumption | Impact if wrong |
|-----------|----------------|
| Magnum 2025.2 uses `k8s_capi_helm` or `k8s_cluster_api` driver (Heat deprecated) | ClusterTemplate with Heat driver will show a deprecation warning; may still work until the driver is fully removed |
| Network driver is `flannel` or `calico` | Other CNI drivers (e.g. `cilium`) are not validated by this toolkit |
| Volume driver is `cinder` | PVC provisioning will not work without the Cinder driver |
| Image `os_distro` must be `fedora-coreos` for Kubernetes COE in Magnum 2025.2 | Cluster boot will fail if a different OS distro is used |
| ClusterTemplate has `external_network_id` set | Floating IPs and Octavia LoadBalancers will not be provisioned |

## Storage

- Rackspace Flex uses **Cinder** block storage; volume driver must be set to `cinder` in the ClusterTemplate
- `ReadWriteMany` access mode is **not supported** by Cinder — use NFS, Manila, or object storage for RWX workloads
- Exported PVs are cluster-specific — they will not bind on Flex without explicit data restore
- Live block-level PV data is **not automatically migrated** — run `restore_pv.sh` or `restore_db.sh` manually

## Networking

- This toolkit **does not assume** source and target CNI are identical
- Flex Magnum supports `flannel` or `calico` as network driver (set in ClusterTemplate)
- Network policies are exported but may need adjustment for the Flex CNI
- NodePort and LoadBalancer Services will receive new IPs on Flex — update DNS accordingly
- LoadBalancer Services on Flex are provisioned via **Octavia** (OpenStack LBaaS)
- Source cluster-internal FQDNs (e.g. `service.namespace.svc.cluster.local`) are valid on Flex — cross-cluster FQDNs must be replaced via `endpoint-map.example.yaml`

## Ingress

- Source and target ingress class annotations are **not assumed identical**
- Map all source classes → Flex classes in `configs/ingress-map.example.yaml`
- Ingress TLS certificates are exported as Secrets — ensure the cert is valid for the Flex domain or replace with cert-manager

## Helm

- Helm re-installs pull charts from the original chart registry (not from stored manifests)
- Ensure all chart repositories are added to the Flex cluster's Helm before running Stage 4 Helm phase
- Chart versions are inferred from the export — if the registry no longer has the exact version, install the nearest compatible version

## Secrets

- All Secrets are exported unless listed in `exclude_secret_names`
- Secrets are base64-encoded, not encrypted in the export — treat export output as sensitive
- Secrets encrypted with external KMS (HashiCorp Vault, AWS Secrets Manager) will not decrypt on Flex without re-configuring the integration

## Non-Goals

- **Do not** try to migrate the old OSPC Kubernetes control plane into Magnum
- **Do not** assume source and target CNI are identical
- **Do not** automatically migrate live PV block data — use the explicit helper workflows
- **Do not** hardcode Rackspace credentials in any config or script
- **Do not** delete source resources — this toolkit is non-destructive by design

## Safe Usage Notes

- Always run Stage 4 restore with `--dry-run` first
- Keep OSPC cluster healthy and unchanged until `cutover-complete` state is confirmed
- Back up `output/<timestamp>/` directory — it contains your exported manifests and kubeconfig
- Never commit `.env`, `openrc.sh`, or any kubeconfig file to version control
- The rollback window closes once OSPC data is deleted — preserve source resources until fully decommissioned
