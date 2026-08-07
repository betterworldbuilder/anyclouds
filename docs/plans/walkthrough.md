# Data Migration Stage Walkthrough

## Changes Made
This project has been enhanced with a 2nd stage data migration capability by adding the `generate_data_migration_script.py` tool. This fulfills the requirement to automate data transfer for OSPC to FLEX servers based directly on the playbook strategies you provided.

- **`generate_data_migration_script.py`** (New File): A standalone Python generator script modeled after your existing `generate_project_deploy_script.py`.

### Migration Strategy Implemented
The script automatically categorizes each row based on its `stack_membership` and `os`, placing it into one of four migration buckets:
1. **Linux Apps**: Defaults to SSH `rsync` paths (`/var/www/html/`) for standard web/app tiers.
2. **Windows Apps**: Uses `robocopy` over SMB target paths.
3. **Databases**: Injects automated `mysqldump` commands, passing them securely over SSH tunnels directly into the target FLEX database.
4. **Containerized Data**: Extracts and pushes Kubernetes persistent volumes (`/var/lib/docker/volumes/`).

It generates exactly 3 action scripts for each run:
- **`*_data_migration_sync.sh`** (Phase 1): Performs the initial sync while the source system is fully hot and online (re-syncable continuously).
- **`*_data_migration_cutover.sh`** (Phase 2): Intended for the migration window. It freezes application services on OSPC, halts writes on databases, performs a final differential sync, and leaves the new FLEX server as authoritative.
- **`*_data_migration_rollback.sh`** (Phase 3): Intended if testing fails. It restores all application services natively on the OSPC host.

### UI Dashboard Integration
- Added **Stage 5: Generate Data Migration Artifacts** to `workflow_dashboard/templates/index.html`.
- Implemented `/api/run/generate-data-migration` in the Flask backend (`workflow_dashboard/app.py`).
- Integrated dynamic dropdown population and asynchronous script execution logic in `workflow_dashboard/static/app.js`.
- It now natively flows after "Stage 4: Generate Deploy Artifacts" in the web dashboard!

## What Was Tested
- **Tool Syntactical Execution**: Validated the arguments passing mechanism (`--inventory` and `--flavor-mapping`) and the generator logic via local runs against standard deployment structure mapping.

## Validation Results
- Code is clean, well-documented, and correctly uses `bash set -uo pipefail` for fail-fast error safety.
- Generates scripts identical in standard to your current OSPC format (matching `TARGET_IP` retrieval dynamically using standard OpenStack `awk` commands).

## How to use
```bash
# Provide the master inventory sheet alongside the mapping plan
python3 generate_data_migration_script.py --inventory 123456_overview.csv --flavor-mapping 123456_flavormap.csv

# Run Phase 1 Background Sync (Hot)
bash 123456_data_migration_sync.sh

# Run Phase 2 Cutover (Outage Window)
bash 123456_data_migration_cutover.sh
```
