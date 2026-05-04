#!/usr/bin/env bash
set -uo pipefail
echo 'Starting Rollback Phase'

# Rollback Linux App for web (Local HAProxy Split)
echo 'Removing HAProxy and restoring 100% traffic to local OSPC node'
ssh -o StrictHostKeyChecking=no root@UNKNOWN_IP 'systemctl stop haproxy && systemctl disable haproxy'

# Rollback Linux App for db (Local HAProxy Split)
echo 'Removing HAProxy and restoring 100% traffic to local OSPC node'
ssh -o StrictHostKeyChecking=no root@UNKNOWN_IP 'systemctl stop haproxy && systemctl disable haproxy'
