#!/bin/sh
# /etc/letsencrypt/renewal-hooks/deploy/cert-update.sh

# 1. Identify the new certificate
DOMAIN_NAME=$(basename "$RENEWED_LINEAGE")
ARCHIVE_PATH="/etc/letsencrypt/archive/$DOMAIN_NAME"

echo "[*] Updating permissions for $DOMAIN_NAME..."

# 2. Apply permissions based on the service owner UIDs
# Default: Nginx (2000) always gets read access
setfacl -R -m u:2000:rX "$ARCHIVE_PATH"

case "$DOMAIN_NAME" in
    "dns.internal")
        setfacl -R -m u:53:rX "$ARCHIVE_PATH"
        docker exec bind9 rndc reload 2>/dev/null
        ;;
    "adguard.internal")
        setfacl -R -m u:2700:rX "$ARCHIVE_PATH"
        docker restart adguard 2>/dev/null
        ;;
    "ldap.internal")
        setfacl -R -m u:2003:rX "$ARCHIVE_PATH"
        docker restart openldap 2>/dev/null
        ;;
esac

# 3. Final Nginx reload to pick up any changed certs
docker exec nginx nginx -s reload 2>/dev/null

echo "[+] Hooks for $DOMAIN_NAME completed."
