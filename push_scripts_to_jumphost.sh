#!/usr/bin/env bash
set -euo pipefail

# Override from your shell if needed: JHOST=... JUSER=... KEY=~/.ssh/id_rsa bash push_scripts_to_jumphost.sh
JHOST="${JHOST:-104.239.169.89}"
JUSER="${JUSER:-ubuntu}"
KEY="${KEY:-$HOME/.ssh/id_rsa}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SRC:-$SCRIPT_DIR/ospc2Flex-Image-migtool}"

SCP_OPTS="-i $KEY -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=20"
SSH_OPTS="-i $KEY -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=20"

echo "=== Pushing all method scripts to jumphost ${JHOST} ==="

SCRIPTS=(
  ospc2flex_offline_repair.sh
  ospc2flex_windows_repair.sh
  ospc2flex_windows_migrate.sh
  ospc2flex_windows_method_d_capture.sh
  ospc2flex_windows_method_d_standalone.sh
  ospc2flex_windows_method_g_simple.sh
  ospc2flex_windows_method_g_simple_lib.sh
  ospc2flex_windows_method_h_local_kvm.sh
  ospc2flex_windows_method_z_snapshot_existing.sh
  ospc2flex_windows_v2_engine.sh
  ospc2flex_windows_firstboot.ps1
  ospc2flex_windows_v2_verify.ps1
  ospc2flex_glance_bridge.sh
)

for f in "${SCRIPTS[@]}"; do
  echo "  -> $f"
  scp $SCP_OPTS "${SRC}/${f}" "${JUSER}@${JHOST}:/tmp/${f}"
done

echo "  -> wincloudbootmigrator.py"
scp $SCP_OPTS "${SRC}/cloudboot/wincloudbootmigrator.py" "${JUSER}@${JHOST}:/tmp/wincloudbootmigrator.py"

echo "=== chmod +x and clear sha256 cache ==="
ssh $SSH_OPTS "${JUSER}@${JHOST}" \
  'chmod +x /tmp/ospc2flex_*.sh /tmp/wincloudbootmigrator.py 2>/dev/null; rm -f /tmp/ospc2flex_script_bundle.sha256; echo "=== ALL DONE ==="'
