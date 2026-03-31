#!/bin/bash
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$APP_DIR")"
APP_BASENAME="$(basename "$APP_DIR")"

echo "======================================================"
echo "    Migration Builder - Backup Utility"
echo "======================================================"

# 1. Ask for Custom Name
read -p "Enter a short name for this snapshot [Default: snapshot]: " RAW_NAME
CUSTOM_NAME=${RAW_NAME:-"snapshot"}
CLEAN_NAME=$(echo "$CUSTOM_NAME" | sed 's/[^a-zA-Z0-9_]/_/g')

# 2. Ask for Comment
read -p "Enter a descriptive comment (Optional): " BACKUP_COMMENT

# 3. Ask for Target Folder
read -p "Enter destination directory to store backup [Default: /home/dzoan/OSPC2FLEX/datamigbackup/]: " INPUT_DIR
BACKUP_DIR=${INPUT_DIR:-"/home/dzoan/OSPC2FLEX/datamigbackup/"}

mkdir -p "$BACKUP_DIR"

DATE_STAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILENAME="migration_builder_${CLEAN_NAME}_${DATE_STAMP}.tar.gz"
BACKUP_PATH="${BACKUP_DIR}/${BACKUP_FILENAME}"
COMMENT_PATH="${BACKUP_DIR}/migration_builder_${CLEAN_NAME}_${DATE_STAMP}.txt"

echo "------------------------------------------------------"
echo "[*] Source Directory  : $APP_DIR"
echo "[*] Target Archive    : $BACKUP_PATH"
if [ -n "$BACKUP_COMMENT" ]; then
    echo "[*] Comment           : $BACKUP_COMMENT"
    echo "$BACKUP_COMMENT" > "$COMMENT_PATH"
fi
echo "------------------------------------------------------"
echo "Creating archive..."

tar -czf "$BACKUP_PATH" \
    --exclude="backups" \
    --exclude="venv" \
    --exclude="__pycache__" \
    --exclude=".git" \
    -C "$PARENT_DIR" \
    "$APP_BASENAME"

echo "[SUCCESS] Application successfully backed up!"
