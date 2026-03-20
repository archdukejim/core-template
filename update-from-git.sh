#!/bin/bash

# 1. Ensure the script is run with root privileges
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

REPO_SOURCE="/home/default_admin/home-core"
TARGET_BASE="/opt"

echo "Syncing changes from $REPO_SOURCE to $TARGET_BASE..."

# --delete: Removes files/folders in /opt that aren't in Git (fixes the ghost directory issue)
# --mkpath: Ensures the /opt/service directory exists before syncing
SYNC_OPTS="-avz --delete --mkpath --exclude='.git'"

# Sync each service directory
# FIXED: changed 'stepca' to 'step-ca' to match your docker-compose paths
rsync $SYNC_OPTS "$REPO_SOURCE/nginx/" "$TARGET_BASE/nginx/"
rsync $SYNC_OPTS "$REPO_SOURCE/adguardhome/" "$TARGET_BASE/adguardhome/"
rsync $SYNC_OPTS "$REPO_SOURCE/easyrsa/" "$TARGET_BASE/easyrsa/"
rsync $SYNC_OPTS "$REPO_SOURCE/bind9/" "$TARGET_BASE/bind9/"
rsync $SYNC_OPTS "$REPO_SOURCE/step-ca/" "$TARGET_BASE/step-ca/"
rsync $SYNC_OPTS "$REPO_SOURCE/openldap/" "$TARGET_BASE/openldap/"
rsync $SYNC_OPTS "$REPO_SOURCE/certbot/" "$TARGET_BASE/certbot/"

# 4. Re-apply Ownership and Permissions
echo "Setting permissions..."
chown -R 2000:2000 /opt/nginx
chown -R 2700:2700 /opt/adguardhome
chown -R 2001:2001 /opt/bind9
chown -R 2002:2002 /opt/step-ca
chown -R 2003:2003 /opt/openldap
chown -R 2004:2004 /opt/certbot
chown -R root:root /opt/easyrsa

# Ensure entrypoint scripts are executable
chmod +x /opt/step-ca/*.sh 2>/dev/null
chmod +x /opt/bind9/*.sh 2>/dev/null
chmod -R 700 /opt/easyrsa

# 5. Reload containers
echo "Reloading services..."
docker exec nginx nginx -s reload 2>/dev/null || echo "Nginx not running."
docker exec bind9 rndc reload 2>/dev/null || echo "Bind9 not running."
docker restart adguardhome 2>/dev/null || echo "AdGuard not running."

echo "Update complete. Ensure you restart the 'step-ca' stack in Portainer to clear the directory error."
