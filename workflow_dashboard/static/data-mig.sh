#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# Configuration
# =========================================================

# OSPC Source Infrastructure IPs
OSPC_FE_IP="10.50.0.10"
OSPC_BE_IP="10.50.0.11"
OSPC_DB_IP="10.50.0.12"

# FLEX Target Infrastructure IPs (assuming they were pre-provisioned via the bash scripts)
FLEX_FE_IP="10.60.0.10"
FLEX_BE_IP="10.60.0.11"
FLEX_DB_IP="10.60.0.12"

# Common SSH Credentials
SSH_USER="ubuntu"
SSH_KEY="~/.ssh/id_rsa"

# App specifics
DB_NAME="pocdb"
FE_WEB_ROOT="/var/www/poc"
BE_APP_DIR="/opt/poc-api"

# =========================================================
# 1) Migrate Database Data
# =========================================================
echo "[INFO] Starting Database Migration ($OSPC_DB_IP -> $FLEX_DB_IP)..."

# Stream the database dump from OSPC directly into the new DB on FLEX.
# We use --clean to ensure if the table was created by the target provision script, it is dropped & cleanly replaced.
ssh -i "$SSH_KEY" "$SSH_USER@$OSPC_DB_IP" "sudo -u postgres pg_dump --clean -O $DB_NAME" \
  | ssh -i "$SSH_KEY" "$SSH_USER@$FLEX_DB_IP" "sudo -u postgres psql -d $DB_NAME"

echo "[OK] Database Migration Complete."

# =========================================================
# 2) Migrate Backend Code & Configs
# =========================================================
echo "[INFO] Starting Backend Migration ($OSPC_BE_IP -> $FLEX_BE_IP)..."

# Pull backend from OSPC to a temporary local dir
mkdir -p /tmp/poc-migrate-be
rsync -avz -e "ssh -i $SSH_KEY" \
  --exclude="venv" \
  --rsync-path="sudo rsync" \
  "$SSH_USER@$OSPC_BE_IP:$BE_APP_DIR/" /tmp/poc-migrate-be/

# Ensure target directory is writable, then push to FLEX target
ssh -i "$SSH_KEY" "$SSH_USER@$FLEX_BE_IP" "sudo mkdir -p $BE_APP_DIR && sudo chown -R $SSH_USER:$SSH_USER $BE_APP_DIR"

rsync -avz -e "ssh -i $SSH_KEY" \
  --rsync-path="sudo rsync" \
  /tmp/poc-migrate-be/ "$SSH_USER@$FLEX_BE_IP:$BE_APP_DIR/"

# Re-apply correct ownership and restart backend on target
ssh -i "$SSH_KEY" "$SSH_USER@$FLEX_BE_IP" "sudo chown -R pocapi:pocapi $BE_APP_DIR"
ssh -i "$SSH_KEY" "$SSH_USER@$FLEX_BE_IP" "sudo systemctl restart poc-api"

rm -rf /tmp/poc-migrate-be
echo "[OK] Backend Migration Complete."

# =========================================================
# 3) Migrate Frontend Static Assets
# =========================================================
echo "[INFO] Starting Frontend Migration ($OSPC_FE_IP -> $FLEX_FE_IP)..."

# Pull frontend from OSPC to a temporary local dir
mkdir -p /tmp/poc-migrate-fe
rsync -avz -e "ssh -i $SSH_KEY" \
  --rsync-path="sudo rsync" \
  "$SSH_USER@$OSPC_FE_IP:$FE_WEB_ROOT/" /tmp/poc-migrate-fe/

# Ensure target directory is writable, then push to FLEX target
ssh -i "$SSH_KEY" "$SSH_USER@$FLEX_FE_IP" "sudo mkdir -p $FE_WEB_ROOT && sudo chown -R $SSH_USER:$SSH_USER $FE_WEB_ROOT"

rsync -avz -e "ssh -i $SSH_KEY" \
  --rsync-path="sudo rsync" \
  /tmp/poc-migrate-fe/ "$SSH_USER@$FLEX_FE_IP:$FE_WEB_ROOT/"

# Re-apply ownership and clear Nginx configurations
ssh -i "$SSH_KEY" "$SSH_USER@$FLEX_FE_IP" "sudo chown -R root:root $FE_WEB_ROOT"
ssh -i "$SSH_KEY" "$SSH_USER@$FLEX_FE_IP" "sudo systemctl restart nginx"

rm -rf /tmp/poc-migrate-fe
echo "[OK] Frontend Migration Complete."

echo "---------------------------------------------------------"
echo "[DONE] Successfully migrated the 3-tier App to FLEX!"
echo "You can now verify the FLEX UI at http://$FLEX_FE_IP/"
