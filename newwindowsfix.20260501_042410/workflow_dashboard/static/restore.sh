#!/bin/bash
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "======================================================"
echo "    Migration Builder - Restore Utility"
echo "======================================================"

read -p "Enter directory where backups are stored [Default: /home/dzoan/OSPC2FLEX/datamigbackup/]: " INPUT_DIR
BACKUP_DIR=${INPUT_DIR:-"/home/dzoan/OSPC2FLEX/datamigbackup/"}

if [ ! -d "$BACKUP_DIR" ]; then
    echo "[ERROR] No backups directory found at $BACKUP_DIR"
    exit 1
fi

# Load tar files into array
shopt -s nullglob
BACKUPS=("$BACKUP_DIR"/*.tar.gz)
shopt -u nullglob

if [ ${#BACKUPS[@]} -eq 0 ]; then
    echo "[INFO] No backup archives (*.tar.gz) found in $BACKUP_DIR"
    exit 1
fi

echo ""
echo "Available Snapshot Backups:"
echo "--------------------------------------------------------------------------------"
for i in "${!BACKUPS[@]}"; do
    FILE="${BACKUPS[$i]}"
    FILENAME=$(basename "$FILE")
    DETAILS=$(ls -lh "$FILE" | awk '{print $5, "[ "$6, $7, $8" ]"}')
    
    # Check for linked comment file
    COMMENT_FILE="${FILE%.tar.gz}.txt"
    COMMENT=""
    if [ -f "$COMMENT_FILE" ]; then
        COMMENT=$(cat "$COMMENT_FILE")
    fi
    
    if [ -n "$COMMENT" ]; then
        printf "%2s) %-50s %s\n    Comment: %s\n" "$((i+1))" "$FILENAME" "$DETAILS" "$COMMENT"
    else
        printf "%2s) %-50s %s\n" "$((i+1))" "$FILENAME" "$DETAILS"
    fi
done
echo "--------------------------------------------------------------------------------"

read -p "Select a backup number to restore (or 'q' to quit): " CHOICE

if [[ "$CHOICE" == "q" || "$CHOICE" == "Q" ]]; then
    echo "Exiting."
    exit 0
fi

if ! [[ "$CHOICE" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] Invalid selection."
    exit 1
fi

INDEX=$((CHOICE-1))

if [ "$INDEX" -lt 0 ] || [ "$INDEX" -ge "${#BACKUPS[@]}" ]; then
    echo "[ERROR] Selected number is out of range."
    exit 1
fi

TARGET_FILE="${BACKUPS[$INDEX]}"

echo ""
echo "You selected: $(basename "$TARGET_FILE")"

# Allow selecting a custom restore location
RESTORE_DATE=$(date +"%Y%m%d_%H%M%S")
DEFAULT_RESTORE="/home/dzoan/OSPC2FLEX/datamigrestore_${RESTORE_DATE}"
read -p "Enter target destination to extract to [Default: $DEFAULT_RESTORE]: " RESTORE_DIR_INPUT
RESTORE_DIR=${RESTORE_DIR_INPUT:-"$DEFAULT_RESTORE"}

if [ ! -d "$RESTORE_DIR" ]; then
    echo "[WARNING] Directory $RESTORE_DIR does not exist. Creating it now..."
    mkdir -p "$RESTORE_DIR"
fi

echo ""
echo "[WARNING] This will extract the backup files over $RESTORE_DIR!"
read -p "Are you sure you want to proceed? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    tar -xzf "$TARGET_FILE" -C "$RESTORE_DIR"
    echo ""
    echo "[SUCCESS] The application has been fully restored to $RESTORE_DIR!"
else
    echo "[ABORTED] Restoration cancelled. Your current files are untouched."
fi
