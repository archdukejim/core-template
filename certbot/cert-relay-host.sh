#!/bin/bash
# Runs on the HOST as a systemd service.
# Reads domain names written by the certbot deploy hook via a FIFO,
# then applies filesystem ACLs using the host's setfacl.

FIFO=/opt/certbot/etc/letsencrypt/relay.fifo
LIVE_BASE=/opt/certbot/etc/letsencrypt/live
ARCHIVE_BASE=/opt/certbot/etc/letsencrypt/archive

while true; do
    while IFS= read -r DOMAIN; do
        [ -z "$DOMAIN" ] && continue
        LIVE_PATH="$LIVE_BASE/$DOMAIN"
        ARCHIVE_PATH="$ARCHIVE_BASE/$DOMAIN"

        echo "[cert-relay] Applying ACLs for: $DOMAIN"

        # Nginx always needs access — set on both live/ (for symlink traversal) and archive/ (for actual files)
        setfacl -m u:2000:rX "$LIVE_PATH"
        setfacl -R -m u:2000:rX "$ARCHIVE_PATH"

        case "$DOMAIN" in
            "adguard.internal")
                setfacl -m u:2700:rX "$LIVE_PATH"
                setfacl -R -m u:2700:rX "$ARCHIVE_PATH"
                ;;
            "ldap.internal")
                setfacl -m u:2003:rX "$LIVE_PATH"
                setfacl -R -m u:2003:rX "$ARCHIVE_PATH"
                ;;
        esac

        echo "[cert-relay] ACLs applied for: $DOMAIN"
    done < "$FIFO"
done
