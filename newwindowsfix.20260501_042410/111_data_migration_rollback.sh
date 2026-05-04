#!/usr/bin/env bash
set -uo pipefail
echo 'Starting Rollback Phase'

# Rollback Linux App for web (OpenStack LB Reuse)
echo 'Removing FLEX clone $TARGET_IP from OpenStack Load Balancer Pool'
read -p "Confirm OpenStack LB Pool Name/ID to remove $TARGET_IP from: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member delete "$OSPC_OCTAVIA_POOL_NAME" "web-ab-member"

# Rollback DB Cutover for db
echo 'Reverting application strings back to OSPC Primary 10.0.0.2'
