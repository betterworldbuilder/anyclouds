# Add and Suggest Migration Cutover Methods

This plan adds two modern, standard-practice network cutover strategies and reorders the full list from lowest downtime to highest downtime.

## User Review Required

> [!IMPORTANT]
> Please review the proposed new cutover strategies (Floating IP Swap and DNS Swap) and confirm if the implementation logic aligns with your environment's OpenStack network architecture and DNS providers.

## Proposed Changes

### 1. New Cutover Strategies (Lowest to Highest Downtime)

Based on cloud migration best practices, here are the suggested cutover methods ordered by expected downtime:

1. **Floating IP Swap (Hot Swap)** - *Lowest Downtime (~1-5s)*
   - **How it works:** Re-assigns the public OpenStack Floating IP (FIP) from the legacy OSPC instance directly to the new FLEX instance via the OpenStack API.
   - **Pros:** Near-zero packet loss, instant global routing updates without waiting for DNS propagation.
2. **DNS CNAME / A-Record Swap** - *Low/Medium Downtime (~30s-300s)*
   - **How it works:** Updates the global DNS A-Record or CNAME to point to the new FLEX internal/external IP.
   - **Pros:** Highly standard. Downtime heavily relies on DNS Record TTL.
3. **OSPC Octavia Native LB Reuse (ab_reuse_lb)** - *Medium Downtime*
   - **How it works:** Injects the FLEX instance into the existing OSPC Load Balancer pool, then drains connections from the OSPC member.
4. **HAProxy Dedicated VM / Local Split (ab_haproxy)** - *Medium-High Downtime*
   - **How it works:** Installs HAProxy on the legacy OSPC server to locally split traffic 50/50, before cutting 100% to FLEX.
5. **Direct Cold Cutover (direct)** - *Highest Downtime*
   - **How it works:** Full stop of OSPC services, complete final rsync/db-sync, and point client to the new backend. Requires an explicit maintenance window.

---

### UI Component Updates

#### [MODIFY] workflow_dashboard/templates/migrate.html
Update the `<select id="migStrategy">` dropdown to list the 5 options in strict priority order (lowest to highest downtime):
- `fip_swap` (Floating IP Swap)
- `dns_swap` (DNS CNAME / A-Record Swap)
- `ab_reuse_lb` (OSPC Octavia Native LB Reuse)
- `ab_haproxy` (HAProxy Local Split)
- `direct` (Direct Cold Cutover)

---

### Backend Logic Updates

#### [MODIFY] generate_data_migration_script.py
Inject the bash scripting logic for `fip_swap` and `dns_swap` into the migration generation engine:
- **`--strategy fip_swap` (Floating IP Swap):**
  - **Sync:** Standard file/DB rsync while application is live.
  - **Cutover:** Finds the associated OpenStack Floating IP of the source and executes `openstack floating ip set --port <new-flex-port> <FIP>`.
  - **Rollback:** Reverts the Floating IP attachment back to the legacy OSPC port.
- **`--strategy dns_swap` (DNS Swap):**
  - **Sync:** Standard file/DB rsync while application is live.
  - **Cutover:** Echoes an operational pause to instruct the engineer to execute the DNS update, wait for TTL propagation, and run a final write-freeze sync.
  - **Rollback:** Echoes instructions to revert the DNS A-Record.

## Open Questions

> [!WARNING]
> 1. Does your OpenStack environment strictly use standard Neutron Floating IPs, or are public IPs managed differently (e.g. BGP peering)?
> 2. Should we attempt to use an automated CLI tool (like `aws route53` or a generic DNS provider CLI) for the DNS swap, or is a manual CLI operational prompt sufficient for `dns_swap`?

## Verification Plan

### Automated Tests
- Run `generate_data_migration_script.py` with `--strategy fip_swap` and `--strategy dns_swap` to ensure they produce valid Bash scripts without syntax errors.

### Manual Verification
- Check the dashboard UI at Step 6 to verify that options are correctly reordered.
- Validate the generated `*_cutover.sh` and `*_rollback.sh` files contain the correct OpenStack CLI commands for Floating IP re-association.
