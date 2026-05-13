#!/usr/bin/env bash
# Push Method G Simple + shared lib to a migration jumphost and invalidate the
# dashboard's bundle hash so the next /api/vm_migrator/nbd/* run re-syncs the
# full script bundle if needed.
#
# Usage:
#   ./restage_method_g_jumphost.sh ubuntu@104.239.169.89 ~/.ssh/id_rsa
#
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JH="${1:?Usage: $0 jumphost_user@jumphost_ip [path_to_ssh_private_key]}"
KEY="${2:-$HOME/.ssh/id_rsa}"

G_SIMPLE="$SELF_DIR/ospc2flex_windows_method_g_simple.sh"
G_LIB="$SELF_DIR/ospc2flex_windows_method_g_simple_lib.sh"

[ -f "$G_SIMPLE" ] || { echo "Missing $G_SIMPLE"; exit 1; }
[ -f "$G_LIB" ] || { echo "Missing $G_LIB"; exit 1; }

SSH=(ssh -q -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes)
SCP=(scp -q -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

echo "[restage] Copying Method G scripts to $JH ..."
"${SCP[@]}" "$G_SIMPLE" "$JH:/tmp/ospc2flex_windows_method_g_simple.sh"
"${SCP[@]}" "$G_LIB" "$JH:/tmp/ospc2flex_windows_method_g_simple_lib.sh"

echo "[restage] chmod +x on jumphost ..."
"${SSH[@]}" "$JH" "chmod +x /tmp/ospc2flex_windows_method_g_simple.sh /tmp/ospc2flex_windows_method_g_simple_lib.sh"

echo "[restage] Removing /tmp/ospc2flex_script_bundle.sha256 (forces full bundle sync on next dashboard launch) ..."
"${SSH[@]}" "$JH" "rm -f /tmp/ospc2flex_script_bundle.sha256"

echo "[restage] Done. Restart the workflow dashboard if it is already running (clears in-memory staging cache)."
