#!/bin/bash
set -euo pipefail

# -------------------------------------------------------------------------
# reinstall_restore.sh - Restore CA data, certs, and config during reinstall
#
# Usage: ./reinstall_restore.sh <BACKUP_DIR> <TARGET_BASE>
# -------------------------------------------------------------------------

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

BACKUP_DIR="${1:-}"
TARGET_BASE="${2:-/opt}"

if [ -z "$BACKUP_DIR" ] || [ ! -d "$BACKUP_DIR" ]; then
    echo "Backup directory not provided or does not exist: $BACKUP_DIR"
    exit 0
fi

echo "[*] Restoring variables and secrets..."
mkdir -p "$TARGET_BASE/core/config"
cp "$BACKUP_DIR/config/vars.yaml" "$TARGET_BASE/core/config/vars.yaml" 2>/dev/null || true
cp "$BACKUP_DIR/config/custom-vars.yaml" "$TARGET_BASE/core/config/custom-vars.yaml" 2>/dev/null || true
cp "$BACKUP_DIR/config/core-secrets.yml" "$TARGET_BASE/core/config/core-secrets.yml" 2>/dev/null || true
chown -R root:root "$TARGET_BASE/core/config"
chmod 640 "$TARGET_BASE/core/config/vars.yaml" 2>/dev/null || true
chmod 600 "$TARGET_BASE/core/config/core-secrets.yml" 2>/dev/null || true

echo "[*] Restoring Step-CA data..."
if [ -d "$BACKUP_DIR/stepca-data" ]; then
    mkdir -p "$TARGET_BASE/stepca/data"
    cp -r "$BACKUP_DIR/stepca-data/"* "$TARGET_BASE/stepca/data/" 2>/dev/null || true
    if id -u step >/dev/null 2>&1; then
        chown -R step:step "$TARGET_BASE/stepca/data"
    fi
fi

echo "[*] Restoring all other certificates..."
if [ -d "$BACKUP_DIR/certs" ]; then
    # We copy them back to TARGET_BASE exactly where they were
    cp -r "$BACKUP_DIR/certs/"* "$TARGET_BASE/" 2>/dev/null || true
    
    # Fix ownership based on the directory they reside in
    for d in nginx bind9 openldap keycloak postgres; do
        if [ -d "$TARGET_BASE/$d" ] && id -u "$d" >/dev/null 2>&1; then
            find "$TARGET_BASE/$d" -type f \( -name '*.crt' -o -name '*.pem' -o -name '*.key' \) -exec chown "$d:$d" {} + 2>/dev/null || true
        elif [ "$d" = "bind9" ] && id -u "bind" >/dev/null 2>&1; then
            find "$TARGET_BASE/$d" -type f \( -name '*.crt' -o -name '*.pem' -o -name '*.key' \) -exec chown "bind:bind" {} + 2>/dev/null || true
        elif [ "$d" = "openldap" ] && id -u "ldap" >/dev/null 2>&1; then
            find "$TARGET_BASE/$d" -type f \( -name '*.crt' -o -name '*.pem' -o -name '*.key' \) -exec chown "ldap:ldap" {} + 2>/dev/null || true
        fi
    done
fi

echo "[*] Restore complete."
