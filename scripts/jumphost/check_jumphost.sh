#!/usr/bin/env bash

JUMPHOST="ubuntu@162.209.124.208"
SSH_KEY="~/.ssh/id_rsa"
# You can change the key path if it is different, e.g. ~/.ssh/id_rsa

echo "=========================================================="
echo " 📡 OSPC-to-FLEX Jumphost Status Monitor"
echo " Jumphost: $JUMPHOST"
echo "=========================================================="
echo ""

ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no ${JUMPHOST} << 'EOF'
echo "==== 1. RUNNING MIGRATION PROCESSES ===="
ps fux | grep -E "mig_worker|ospc2flex_windows|qemu-img|openstack" | grep -v grep || echo "No active processes."
echo ""

echo "==== 2. DISK SPACE ON JUMPHOST (/mnt/migration) ===="
df -h /mnt/migration | awk 'NR==1 || NR==2'
echo ""

echo "==== 3. IMAGE FILES CURRENTLY STAGED ===="
ls -lh /mnt/migration/ospc2flex_image/ 2>/dev/null || echo "Directory empty or missing."
echo ""

echo "==== 4. LINUX NBD DEVICES MAPPED ===="
lsblk | grep -B 1 nbd || echo "No NBD devices attached."
echo ""

echo "==== 5. LATEST LOG ACTIVITY (LAST 3 LINES) ===="
for log in /tmp/mig_*.log; do
    if [ -f "$log" ]; then
        echo "📜 $log :"
        tail -n 3 "$log" | sed 's/^/   /'
        echo ""
    fi
done
EOF
