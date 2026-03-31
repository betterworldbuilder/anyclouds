# Saved Topology Notes

This file explains what each saved topology JSON is intended for.

## topology.json
- Purpose: Generic baseline topology for quick sanity checks.
- Includes: 1 network, 1 subnet, 1 router, 1 security group, 1 instance, 1 volume.
- Use when: You want a broad all-in-one starter with core resource types.

## web_with_fip.json
- Purpose: Minimal web workload with public reachability.
- Includes: 1 network/subnet/router, 1 SG, 1 VM (with FIP), 1 attached volume.
- Use when: You want to test a single externally accessible VM pattern.

## two_tier_app.json
- Purpose: Basic two-tier app structure.
- Includes: Web + backend instances, separate SGs, shared network stack, backend volume.
- Use when: You want app/front-end + internal service segmentation.

## ha_pair.json
- Purpose: HA-style paired node pattern.
- Includes: 2 app nodes, shared network stack, per-node volumes, shared SG policy.
- Use when: You want active/standby or active/active pair testing.

## with_octavia_lb.json
- Purpose: Octavia load balancer baseline.
- Includes: 1 LB, 2 backend instances as pool members, LB FIP, network/subnet/router.
- Use when: You want to validate LB workflow end-to-end.

## web_tier_2vm_lb_fip.json
- Purpose: Standard public web tier behind LB.
- Includes: 2 web VMs, 1 LB (amphora, HTTP), LB FIP, shared web SG.
- Use when: You want a production-like web entry tier pattern.

## app_db_split_with_data_vols.json
- Purpose: App + DB split with data persistence.
- Includes: app VM and db VM, separate SGs, dedicated data volumes for each.
- Use when: You want to test app/database separation and volume attachments.

## multi_tier_3vm_bastion.json
- Purpose: Bastion + private app nodes.
- Includes: 1 bastion VM (with FIP), 2 private app VMs, separate SGs.
- Use when: You want SSH entrypoint architecture with private workloads.

## blue_green_lb_cutover.json
- Purpose: Blue/green cutover simulation behind single LB.
- Includes: 4 backend VMs (blue and green sets) attached to one LB.
- Use when: You want migration/cutover rehearsal patterns.

## single_vm_minimal_valid.json
- Purpose: Smallest valid topology deploy.
- Includes: 1 network/subnet/router, 1 SG, 1 VM.
- Use when: You want fastest validation of credentials/workflow.

## storage_heavy_app.json
- Purpose: Single app node with multiple attached data volumes.
- Includes: 1 app VM (with FIP), 3 attached volumes, network stack, SG.
- Use when: You want to test volume lifecycle and attachment ordering.

## segmented_isolated_lab.json
- Purpose: Fully private segmented lab with no public routing.
- Includes: Separate app and db networks/subnets, no router-to-public links, app/db SGs, db data volume.
- Use when: You want strict isolation testing where nothing has egress/ingress via `PUBLICNET`.

## segmented_public_private_tiers.json
- Purpose: DMZ + private app + private db segmentation.
- Includes: Public-routed DMZ subnet for web/LB, isolated app/db networks without router gateway, per-tier SGs.
- Use when: You want a classic public-ingress plus private backend segmentation pattern.

## segmented_dual_router_shared_services.json
- Purpose: Two independently routed environments plus shared private services zone.
- Includes: Separate prod/dev networks each with its own router to `PUBLICNET`, plus a shared isolated services network.
- Use when: You want to model environment isolation with distinct edge routers and a non-public shared layer.

## segmented_private_with_public_ingress_lb.json
- Purpose: Public ingress through LB with private-only backend segment.
- Includes: Routed ingress subnet, isolated backend subnet, LB on ingress subnet, backend members on private subnet.
- Use when: You want internet entry only at the LB while keeping app nodes fully private.

---

## Notes
- Most templates use placeholder values for image and keypair (for example `Ubuntu 22.04`, `my-keypair`).
- Update `image` and `key_name` in Visual Topology Properties before deployment.
- LB templates assume Octavia and may require provider/protocol adjustments by region/platform.
