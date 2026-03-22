#!/bin/sh
# Note: Changed to #!/bin/sh as Alpine uses ash/sh

# 1. Install dependencies inside the container on the fly
apk add --no-cache acl docker-cli

DOMAIN_NAME=$(basename "$RENEWED_LINEAGE")
# Map the path to where it exists inside the container
ARCHIVE_PATH="/etc/letsencrypt/archive/$DOMAIN_NAME"

# 2. Apply permissions (This works because the volume is shared with the host)
setfacl -R -m u:2000:rX "$ARCHIVE_PATH"

if [ "$DOMAIN_NAME" = "dns.internal" ]; then
    setfacl -R -m u:53:rX "$ARCHIVE_PATH"
fi

if [ "$DOMAIN_NAME" = "adguard.internal" ]; then
    setfacl -R -m u:2700:rX "$ARCHIVE_PATH"
fi

if [ "$DOMAIN_NAME" = "ldap.internal" ]; then
    setfacl -R -m u:2003:rX "$ARCHIVE_PATH"
fi

# 3. Reload containers (Works now because we installed docker-cli)
docker exec nginx nginx -s reload 2>/dev/null || true
docker exec bind9 rndc reload 2>/dev/null || true
docker restart openldap 2>/dev/null || true
