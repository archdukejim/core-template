#!/bin/bash
set -euo pipefail

# -------------------------------------------------------------------------
# reinstall_backup.sh - Backup CA data, certs, and config for a reinstall
#
# Usage: ./reinstall_backup.sh <BACKUP_DIR> <TARGET_BASE>
# Example: ./reinstall_backup.sh /root/.core-reinstall-backup /opt
# -------------------------------------------------------------------------

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

BACKUP_DIR="${1:-}"
TARGET_BASE="${2:-/opt}"

if [ -z "$BACKUP_DIR" ]; then
    echo "Usage: $0 <BACKUP_DIR> <TARGET_BASE>"
    exit 1
fi

echo "[*] Creating backup directory: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR/config"
mkdir -p "$BACKUP_DIR/certs"

echo "[*] Backing up variables and secrets..."
cp "$TARGET_BASE/core/config/vars.yaml" "$BACKUP_DIR/config/vars.yaml" 2>/dev/null || true
cp "$TARGET_BASE/core/config/custom-vars.yaml" "$BACKUP_DIR/config/custom-vars.yaml" 2>/dev/null || true
cp "$TARGET_BASE/core/config/core-secrets.yml" "$BACKUP_DIR/config/core-secrets.yml" 2>/dev/null || true

echo "[*] Backing up Step-CA data..."
if [ -d "$TARGET_BASE/stepca/data" ]; then
    cp -r "$TARGET_BASE/stepca/data" "$BACKUP_DIR/stepca-data"
fi

echo "[*] Discovering and backing up all certificates across $TARGET_BASE..."
# We search for .crt, .pem, .key files, ignoring the stepca dir as we already backed it up fully
find "$TARGET_BASE" -type f \( -name '*.crt' -o -name '*.pem' -o -name '*.key' \) | grep -v "$TARGET_BASE/stepca/" | while read -r f; do
    rel="${f#$TARGET_BASE/}"
    mkdir -p "$BACKUP_DIR/certs/$(dirname "$rel")"
    cp "$f" "$BACKUP_DIR/certs/$rel"
done

echo "[*] Backup complete."
