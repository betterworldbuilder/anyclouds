#!/usr/bin/env bash
set -euo pipefail

JH_IP="${1:-104.130.165.124}"
JH_USER="${2:-ubuntu}"
KEY="${3:-$HOME/.ssh/id_rsa}"

ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${JH_USER}@${JH_IP}" 'bash -s' <<'EOF'
set -euo pipefail
source /mnt/migration/ospc2flex_image/creds/ospc_openrc.sh
IMG="aea39a50-dc0b-430f-9c14-1cf2fd1b4290"
CONTAINER="ospc2flex-export"
OBJ="${IMG}.vhd"
INPUT="$(printf '{"image_uuid":"%s","receiving_swift_container":"%s","image_name":"%s"}' "$IMG" "$CONTAINER" "$OBJ")"
echo "=== openstack image task create ==="
set +e
openstack image task create --type export --json-string "$INPUT" -f json 2>&1
echo "rc=$?"
set -e
echo "=== glance task-create ==="
set +e
glance task-create --type export --input "$INPUT" 2>&1
echo "rc=$?"
set -e
EOF
