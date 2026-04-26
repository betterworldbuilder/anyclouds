#!/usr/bin/env bash
# Revert the half-applied ospc_creds=None from the staging function signature
# This is the ONLY change needed to make app.py 100% clean
set -e

FILE="/home/dzoan/OSPC2FLEX/osflex-deployer-fullmig-5.0.0420current/workflow_dashboard/app.py"

# Check current state
if grep -q 'ospc_creds=None' "$FILE"; then
    sed -i 's/def _stage_scripts_on_jumphost(jumphost_ip, jumphost_user, ssh_key, flex_creds, ssh_base, ospc_creds=None):/def _stage_scripts_on_jumphost(jumphost_ip, jumphost_user, ssh_key, flex_creds, ssh_base):/' "$FILE"
    echo "✅ Reverted staging function signature to clean state"
else
    echo "✅ Already clean — no ospc_creds in signature"
fi

# Verify
echo ""
echo "Verification:"
grep -n "ospc_creds" "$FILE" && echo "⚠ ospc_creds still present" || echo "✅ app.py is 100% clean of ospc_creds"
grep -c "nbd_dd" "/home/dzoan/OSPC2FLEX/osflex-deployer-fullmig-5.0.0420current/workflow_dashboard/templates/image_migrator.html" | xargs -I{} echo "✅ nbd_dd: {} references intact"
