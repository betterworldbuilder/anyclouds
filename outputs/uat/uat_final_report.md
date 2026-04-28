# Cloud Jumper UAT Final Report

Generated: 2026-04-28T06:39:01+00:00
Decision: **Not Ready**

## Loaded Artifacts
- discovery/apps_inventory.csv: Loaded
- discovery/db_inventory.csv: Loaded
- discovery/infra_topology.json: Loaded
- discovery/dependencies_map.json: Loaded
- discovery/performance_baseline.csv: Loaded
- discovery/discovery_summary.json: Loaded
- migration/migrated_vm_list.csv: Loaded
- migration/image_conversion_log.txt: Loaded
- migration/boot_validation_results.csv: Loaded
- migration/network_mapping.json: Loaded
- migration/db_migration_log.txt: Loaded
- migration/migration_summary.json: Loaded

## Systems Under Test
- customer-portal (App) -> 10.50.0.10 [Passed]
- billing-api (App) ->  [Not Started]
- orders-db (DB) ->  [Not Started]
- billing-db (DB) ->  [Not Started]

## Command Execution History

## Failed Commands

## Migration Log Findings

## Issues
- [Low] UAT-001 Fixed: sample fixed issue
- [High] UAT-002 Open: UAT command Failed: curl -v http://<target_ip>/health
systemctl status <service_name> --no-pager
journalctl -u <service_name> -n 100 --no-pager

## Performance
- Overall: Pass
- OSPC p95 ms: 420
- FLEX p95 ms: 450
- API error rate %: 0.2

## Recommended Next Actions
- Not all critical systems are marked Passed.

