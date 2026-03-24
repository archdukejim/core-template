#!/bin/bash
# Mint a new certificate for the Step-CA domain via Certbot + ACME
# Runs a one-off certbot container on the existing Portainer-managed network.
# The cert is written to the shared letsencrypt volume and automatically
# managed by the long-running certbot renewal loop.
#
# The primary domain is derived from the ACME server URL in cli.ini.
#
# Usage: sudo ./mint-cert.sh [options]
# Options:
#   --san <name>                Additional Subject Alternative Name(s), repeatable
#   --portainer-webhook <url>   Trigger Portainer stack redeploy after minting
#
# Examples:
#   sudo ./mint-cert.sh
#   sudo ./mint-cert.sh --san stepca.internal
#   sudo ./mint-cert.sh --san stepca.internal --portainer-webhook https://portainer.example/api/stacks/webhooks/abc123

set -euo pipefail

# --- Configuration ---
LETSENCRYPT_DIR="/opt/certbot/etc/letsencrypt"
CLI_INI="${LETSENCRYPT_DIR}/cli.ini"

usage() {
    echo "Usage: $0 [--san <name>]... [--portainer-webhook <url>]"
    exit 1
}

WEBHOOK_URL=""
SANS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --portainer-webhook)
            [ $# -lt 2 ] && usage
            WEBHOOK_URL="$2"
            shift 2
            ;;
        --san)
            [ $# -lt 2 ] && usage
            SANS+=("$2")
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Derive the CA domain from the ACME server URL in cli.ini
if [ ! -f "$CLI_INI" ]; then
    echo "ERROR: Certbot config not found at $CLI_INI"
    exit 1
fi

DOMAIN=$(grep -oP '(?<=server = https://)[^:]+' "$CLI_INI")

if [ -z "$DOMAIN" ]; then
    echo "ERROR: Could not determine CA domain from $CLI_INI"
    exit 1
fi

# Verify BIND9 and Step-CA are running and healthy
BIND_OK=$(docker inspect -f '{{.State.Health.Status}}' bind9 2>/dev/null || echo "not found")
STEP_OK=$(docker inspect -f '{{.State.Health.Status}}' step-ca 2>/dev/null || echo "not found")

if [ "$BIND_OK" != "healthy" ] || [ "$STEP_OK" != "healthy" ]; then
    echo "ERROR: Required services not healthy (bind9=$BIND_OK, step-ca=$STEP_OK)"
    echo "Ensure the core stack is running in Portainer before minting certificates."
    exit 1
fi

# Discover the network and IPs from the running containers
NETWORK=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' step-ca)
STEPCA_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' step-ca)
BIND_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' bind9)

# Build domain arguments
DOMAIN_ARGS=("-d" "$DOMAIN")
for SAN in "${SANS[@]}"; do
    DOMAIN_ARGS+=("-d" "$SAN")
done

# Stop the certbot renewal loop so it doesn't conflict
docker stop certbot 2>/dev/null || true

echo "Requesting certificate for $DOMAIN (SANs: ${SANS[*]:-none}) on network $NETWORK..."
docker run --rm \
    --network "$NETWORK" \
    --add-host "${DOMAIN}:${STEPCA_IP}" \
    --dns "$BIND_IP" \
    -e REQUESTS_CA_BUNDLE=/etc/letsencrypt/root_ca.crt \
    -v "${LETSENCRYPT_DIR}:/etc/letsencrypt" \
    -v /opt/certbot/hooks:/etc/letsencrypt/renewal-hooks/deploy \
    -v /var/run/docker.sock:/var/run/docker.sock \
    certbot/dns-rfc2136:latest \
    certonly --non-interactive --force-renewal \
    --disable-hook-validation \
    --deploy-hook "/etc/letsencrypt/renewal-hooks/deploy/cert-update.sh" \
    "${DOMAIN_ARGS[@]}"

# Restart the certbot renewal loop
docker start certbot

echo "Certificate minted for $DOMAIN and added to certbot managed renewals."

# Trigger Portainer stack redeploy if webhook provided
if [ -n "$WEBHOOK_URL" ]; then
    echo "Triggering Portainer stack redeploy..."
    curl -s -X POST "$WEBHOOK_URL"
    echo "Portainer redeploy triggered."
fi
