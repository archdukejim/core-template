#!/bin/bash
# Runs on the HOST as a systemd service.
# Reads domain names written by the certbot deploy hook via a FIFO,
# then applies filesystem ACLs using the host's setfacl.

FIFO=/opt/certbot/etc/letsencrypt/relay.fifo
ARCHIVE_BASE=/opt/certbot/etc/letsencrypt/archive

while true; do
    while IFS= read -r DOMAIN; do
        [ -z "$DOMAIN" ] && continue
        ARCHIVE_PATH="$ARCHIVE_BASE/$DOMAIN"

        echo "[cert-relay] Applying ACLs for: $DOMAIN"
        setfacl -R -m u:2000:rX "$ARCHIVE_PATH"

        case "$DOMAIN" in
            "adguard.internal")
                setfacl -R -m u:2700:rX "$ARCHIVE_PATH"
                ;;
            "ldap.internal")
                setfacl -R -m u:2003:rX "$ARCHIVE_PATH"
                ;;
        esac

        echo "[cert-relay] ACLs applied for: $DOMAIN"
    done < "$FIFO"
done
