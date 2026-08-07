#!/bin/bash
# Sync Discovery Daemon: Securely loop and pull discovery reports down from the Jumphost

JUMPHOST="ubuntu@104.130.165.124"
KEY="/home/dzoan/.ssh/id_rsa"
JUMPHOST_DIR="/mnt/migration/ospc2flex_image"
LOCAL_DIR="/home/dzoan/OSPC2FLEX/osflex-deployer-fullmig-5.0.0420current/discovery_reports"

mkdir -p "$LOCAL_DIR"

echo "Syncing remote discovery reports..."
while true; do
  rsync -avz -e "ssh -i $KEY -o StrictHostKeyChecking=no" "${JUMPHOST}:${JUMPHOST_DIR}/*_discovery.txt" "$LOCAL_DIR/" > /dev/null 2>&1
  sleep 30  # Pull new discovery sweeps every 30 seconds
done
