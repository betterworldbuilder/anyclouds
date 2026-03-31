#!/usr/bin/env bash
set -uo pipefail
echo 'Starting Initial Data Sync Phase'

# Server: web -> web (Category: linux_app)
TARGET_IP=$(openstack server show web -f value -c addresses | awk -F'=' '{print $2}' | awk '{print $1}' || echo "TARGET_IP_UNKNOWN")
echo 'Syncing Linux App Files for web'
mkdir -p /tmp/sync_web
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" root@UNKNOWN_IP:/var/www/html/ /tmp/sync_web/
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" /tmp/sync_web/ centos@$TARGET_IP:/var/www/html/

# Server: db -> db (Category: linux_app)
TARGET_IP=$(openstack server show db -f value -c addresses | awk -F'=' '{print $2}' | awk '{print $1}' || echo "TARGET_IP_UNKNOWN")
echo 'Syncing Linux App Files for db'
mkdir -p /tmp/sync_db
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" root@UNKNOWN_IP:/var/www/html/ /tmp/sync_db/
rsync -avz --progress -e "ssh -o StrictHostKeyChecking=no" /tmp/sync_db/ centos@$TARGET_IP:/var/www/html/
