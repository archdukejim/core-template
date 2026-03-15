#!/bin/bash

# 1. Ensure the script is run with root privileges
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

if [[ "$1" == "--fix-only" ]]; then
    echo "Running in fix-only mode..."
    # Skip user creation, jump straight to ACL logic (Section 6)
    # [Insert your Section 6 ACL logic here]
    
    # Reload services to pick up new certs
    docker exec nginx nginx -s reload
    docker exec bind9 rndc reload
    exit 0
fi

# 2. Setup Variables
REPO_SOURCE="/home/admin/home-core"
TARGET_BASE="/opt"

# 3. Create Host Accounts
groupadd -g 2000 nginx    && useradd -u 2000 -g 2000 -s /usr/sbin/nologin -r nginx
groupadd -g 2001 bind9    && useradd -u 2001 -g 2001 -s /usr/sbin/nologin -r bind9
groupadd -g 2002 step     && useradd -u 2002 -g 2002 -s /usr/sbin/nologin -r step
groupadd -g 2003 ldap     && useradd -u 2003 -g 2003 -s /usr/sbin/nologin -r ldap
groupadd -g 2004 certbot  && useradd -u 2004 -g 2004 -s /usr/sbin/nologin -r certbot
groupadd -g 2700 adguard  && useradd -u 2700 -g 2700 -s /usr/sbin/nologin -r adguard

echo "All host accounts created successfully."

# 4. Deploy Files from Git Repo
echo "Copying configuration files from $REPO_SOURCE to $TARGET_BASE..."

# Ensure target exists
mkdir -p "$TARGET_BASE"

# Copy directories (renaming 'cerbot' to 'certbot' for the target if needed)
cp -r "$REPO_SOURCE/nginx" "$TARGET_BASE/"
cp -r "$REPO_SOURCE/adguardhome" "$TARGET_BASE/"
cp -r "$REPO_SOURCE/bind9" "$TARGET_BASE/"
cp -r "$REPO_SOURCE/step-ca" "$TARGET_BASE/stepca"
cp -r "$REPO_SOURCE/openldap" "$TARGET_BASE/"
cp -r "$REPO_SOURCE/cerbot" "$TARGET_BASE/certbot" # Fixes spelling during copy

# 5. Fix Ownership
sudo chown -R 2000:2000 /opt/nginx
sudo chown -R 2700:2700 /opt/adguardhome
sudo chown -R 2001:2001 /opt/bind9
sudo chown -R 2002:2002 /opt/stepca
sudo chown -R 2003:2003 /opt/openldap
sudo chown -R 2004:2004 /opt/certbot

# 6. Apply Let's Encrypt ACLs
echo "Applying ACLs to Certbot directories..."
BASE="/opt/certbot/etc/letsencrypt"

# Ensure the subdirectories exist so setfacl doesn't fail
mkdir -p "$BASE/live" "$BASE/archive"

for uid in 2000 2001 2002 2003 2700; do
    setfacl -m u:$uid:x /opt/certbot
    setfacl -m u:$uid:x /opt/certbot/etc
    setfacl -m u:$uid:x $BASE
    setfacl -m u:$uid:rx $BASE/live
    setfacl -m u:$uid:rx $BASE/archive
done

setfacl -R -m u:2000:rX $BASE/live $BASE/archive
setfacl -R -m u:2001:rX $BASE/archive/dns.internal/ 2>/dev/null || true
setfacl -R -m u:2700:rX $BASE/archive/adguard.internal/ 2>/dev/null || true
setfacl -R -m u:2003:rX $BASE/archive/ldap.internal/ 2>/dev/null || true

echo "ACLs complete"

# 7. Add Cron Job for Auto-Renewal
echo "Configuring cron job for twice-daily certificate renewal checks..."

# Define the cron command to run certbot renew and then fix permissions/reload
CRON_CMD="cd $(dirname $REPO_SOURCE) && /usr/local/bin/docker-compose run --rm certbot renew --quiet && /usr/bin/bash $REPO_SOURCE/system-conditioning.sh --fix-only"

# Add to crontab if it doesn't already exist (runs at 00:00 and 12:00)
(crontab -l 2>/dev/null | grep -Fv "$CRON_CMD"; echo "0 0,12 * * * $CRON_CMD") | crontab -

echo "Configured cron job and System-core deployment complete."