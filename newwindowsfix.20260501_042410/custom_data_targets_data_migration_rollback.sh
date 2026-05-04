#!/usr/bin/env bash
set -uo pipefail
echo 'Starting Rollback Phase'

# Rollback Linux App for web-prod-01 (Local HAProxy Split)
echo 'Removing HAProxy and restoring 100% traffic to local OSPC node'
ssh -o StrictHostKeyChecking=no root@10.0.0.15 'systemctl stop haproxy && systemctl disable haproxy'

# Rollback DB Cutover for db-prod-01
echo 'Reverting application strings back to OSPC Primary 10.0.0.20'

# Rollback Windows App for api-prod-01
echo 'Restarting IIS on source api-prod-01'
