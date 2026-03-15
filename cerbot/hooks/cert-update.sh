#!/bin/bash
# This runs only when a certificate is successfully renewed.
# The variable $RENEWED_LINEAGE points to the folder (e.g., /etc/letsencrypt/live/dns.internal)

# 1. Re-apply recursive read to the archive folder for this specific cert
DOMAIN_NAME=$(basename "$RENEWED_LINEAGE")
ARCHIVE_PATH="/etc/letsencrypt/archive/$DOMAIN_NAME"

# Grant Nginx (2000) access to everything in this renewed folder
setfacl -R -m u:2000:rX "$ARCHIVE_PATH"

# Grant BIND (2001) access only if it's the BIND cert
if [[ "$DOMAIN_NAME" == "dns.internal" ]]; then
    setfacl -R -m u:2001:rX "$ARCHIVE_PATH"
fi

# Grant AdGuard (2700) access only if it's the AdGuard cert
if [[ "$DOMAIN_NAME" == "adguard.internal" ]]; then
    setfacl -R -m u:2700:rX "$ARCHIVE_PATH"
fi

# Grant LDAP (2003) access only if it's the LDAP cert
if [[ "$DOMAIN_NAME" == "ldap.internal" ]]; then
    setfacl -R -m u:2003:rX "$ARCHIVE_PATH"
fi

# 2. Tell the containers to reload the new certs
docker exec nginx nginx -s reload 2>/dev/null || true
docker exec bind9 rndc reload 2>/dev/null || true

# For OpenLDAP, a restart is typically required to refresh TLS listeners
docker restart openldap 2>/dev/null || true
