#!/bin/bash

# 1. Ensure the script is run with root privileges
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# 2. Setup Variables
REPO_SOURCE="/home/default_admin/home-core"
TARGET_BASE="/opt"

# 3. Sync files with Cleanup
# --delete: Removes files/folders in /opt that aren't in your Git repo (fixes "Is a directory" errors)
# --mkpath: Creates /opt/service folders if they don't exist yet
SYNC_OPTS="-avz --delete --mkpath --exclude='.git'"

echo "Syncing changes from $REPO_SOURCE to $TARGET_BASE..."

# Note: Changed 'stepca' to 'step-ca' to match your docker-compose.yml volume mounts
rsync $SYNC_OPTS "$REPO_SOURCE/nginx/" "$TARGET_BASE/nginx/"
rsync $SYNC_OPTS "$REPO_SOURCE/adguardhome/" "$TARGET_BASE/adguardhome/"
rsync $SYNC_OPTS "$REPO_SOURCE/easyrsa/" "$TARGET_BASE/easyrsa/"
rsync $SYNC_OPTS "$REPO_SOURCE/bind9/" "$TARGET_BASE/bind9/"
rsync $SYNC_OPTS "$REPO_SOURCE/step-ca/" "$TARGET_BASE/step-ca/"
rsync $SYNC_OPTS "$REPO_SOURCE/openldap/" "$TARGET_BASE/openldap/"
rsync $SYNC_OPTS "$REPO_SOURCE/certbot/" "$TARGET_BASE/certbot/"

# 4. Re-apply Ownership and Permissions
echo "Ensuring correct ownership and making scripts executable..."

# Fix ownership for each service
chown -R 2000:2000 "$TARGET_BASE/nginx"
chown -R 2700:2700 "$TARGET_BASE/adguardhome"
chown -R 2001:2001 "$TARGET_BASE/bind9"
chown -R 2002:2002 "$TARGET_BASE/step-ca"
chown -R 2003:2003 "$TARGET_BASE/openldap"
chown -R 2004:2004 "$TARGET_BASE/certbot"
chown -R root:root "$TARGET_BASE/easyrsa"

# CRITICAL: Fix Step-CA "Permission Denied" and ensure scripts can run
# Ensures the internal data folder is writable by the container user
mkdir -p "$TARGET_BASE/step-ca/data"
chown -R 2002:2002 "$TARGET_BASE/step-ca/data"

# Makes entrypoint scripts executable so they don't fail on "Permission Denied"
find "$TARGET_BASE" -name "*.sh" -exec chmod +x {} +
chmod -R 700 "$TARGET_BASE/easyrsa"

# 5. Reload containers
echo "Reloading services..."
docker exec nginx nginx -s reload 2>/dev/null || echo "Nginx not running."
docker exec bind9 rndc reload 2>/dev/null || echo "Bind9 not running."
docker restart adguardhome 2>/dev/null || echo "AdGuard restart skipped."

echo "Update complete. Now redeploy your stack in Portainer."
