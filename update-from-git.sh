#!/bin/bash

# 1. Ensure the script is run with root privileges
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# 2. Setup Variables
REPO_SOURCE="/home/default_admin/home-core"
TARGET_BASE="/opt"

# 3. Sync files using rsync
# -a: archive mode (preserves permissions/times/links)
# -v: verbose (shows which files changed)
# -z: compress during transfer
echo "Syncing changes from $REPO_SOURCE to $TARGET_BASE..."

# Sync each service directory
# Note: trailing slashes ensure we sync 'contents' to the target folder
rsync -avz --exclude='.git' "$REPO_SOURCE/nginx/" "$TARGET_BASE/nginx/"
rsync -avz --exclude='.git' "$REPO_SOURCE/adguardhome/" "$TARGET_BASE/adguardhome/"
rsync -avz --exclude='.git' "$REPO_SOURCE/easyrsa/" "$TARGET_BASE/easyrsa/"
rsync -avz --exclude='.git' "$REPO_SOURCE/bind9/" "$TARGET_BASE/bind9/"
rsync -avz --exclude='.git' "$REPO_SOURCE/step-ca/" "$TARGET_BASE/stepca/"
rsync -avz --exclude='.git' "$REPO_SOURCE/openldap/" "$TARGET_BASE/openldap/"
rsync -avz --exclude='.git' "$REPO_SOURCE/cerbot/" "$TARGET_BASE/certbot/"

# 4. Re-apply Ownership for Non-Root Users
echo "Ensuring correct ownership for UIDs..."
chown -R 2000:2000 /opt/nginx
chown -R 2700:2700 /opt/adguardhome
chown -R 2001:2001 /opt/bind9
chown -R 2002:2002 /opt/stepca
chown -R 2003:2003 /opt/openldap
chown -R 2004:2004 /opt/certbot
chown -R root:root /opt/easyrsa

# 5. Reload containers to pick up changes
echo "Reloading services..."
docker exec nginx nginx -s reload 2>/dev/null || echo "Nginx not running, skipping reload."
docker exec bind9 rndc reload 2>/dev/null || echo "Bind9 not running, skipping reload."
# AdGuard usually needs a restart to pick up YAML changes reliably
docker restart adguardhome 2>/dev/null || echo "AdGuard not running, skipping restart."

echo "Update complete."