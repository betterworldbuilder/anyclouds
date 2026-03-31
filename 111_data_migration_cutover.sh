#!/usr/bin/env bash
set -uo pipefail
echo 'Starting Final Cutover Phase'

# Cutover Linux App for web (OpenStack LB Reuse)
echo 'Injecting FLEX clone $TARGET_IP into existing OpenStack Load Balancer Pool'
read -p "Enter the existing OpenStack LB Pool Name/ID to inject $TARGET_IP: " OSPC_OCTAVIA_POOL_NAME
openstack loadbalancer member create --name "web-ab-member" --address "$TARGET_IP" --protocol-port 80 "$OSPC_OCTAVIA_POOL_NAME"
echo 'FLEX Target $TARGET_IP has been added to OSPC load balancer pool: $OSPC_OCTAVIA_POOL_NAME'

# Cutover HA Database for db
echo 'Promoting FLEX DB db to Independent Primary'
ssh -o StrictHostKeyChecking=no centos@$TARGET_IP 'mysql -e "STOP SLAVE; RESET SLAVE ALL;"'
echo 'Operator Action: Update application connection strings to point to $TARGET_IP'
