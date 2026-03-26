#!/bin/bash
# Mint a leaf certificate signed by the Step-CA intermediate CA.
# Uses the smallstep/step-ca container with the local CA data volume.
#
# The private key and signed certificate are exported to the calling
# user's home directory (detected via SUDO_USER).
#
# Usage: sudo ./mint-leaf-cert.sh --cn <common-name> [options]
# Options:
#   --cn <name>       Common Name for the certificate (required)
#   --san <name>      Additional Subject Alternative Name(s), repeatable
#   --key <path>      Path to an existing private key (PEM). If omitted, a new
#                     EC P-256 key is generated.
#   --days <n>        Certificate validity in days (default: 365)
#   --out-dir <path>  Override output directory (default: calling user's home)
#
# Examples:
#   sudo ./mint-leaf-cert.sh --cn myservice.internal
#   sudo ./mint-leaf-cert.sh --cn myservice.internal --san api.internal --days 730
#   sudo ./mint-leaf-cert.sh --cn myservice.internal --key /tmp/existing.key

set -euo pipefail

# --- Configuration ---
STEPCA_DATA="/opt/stepca/data"
STEPCA_IMAGE="smallstep/step-ca:latest"
STEP_UID=135
STEP_GID=135
DEFAULT_DAYS=365
LEAF_TEMPLATE="/home/step/templates/certs/leaf.tpl"

# --- Argument parsing ---
CN=""
SANS=()
EXISTING_KEY=""
DAYS="$DEFAULT_DAYS"
OUT_DIR=""

usage() {
    echo "Usage: sudo $0 --cn <common-name> [--san <name>]... [--key <path>] [--days <n>] [--out-dir <path>]"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --cn)
            [ $# -lt 2 ] && usage
            CN="$2"; shift 2 ;;
        --san)
            [ $# -lt 2 ] && usage
            SANS+=("$2"); shift 2 ;;
        --key)
            [ $# -lt 2 ] && usage
            EXISTING_KEY="$2"; shift 2 ;;
        --days)
            [ $# -lt 2 ] && usage
            DAYS="$2"; shift 2 ;;
        --out-dir)
            [ $# -lt 2 ] && usage
            OUT_DIR="$2"; shift 2 ;;
        *)
            echo "Unknown option: $1"
            usage ;;
    esac
done

if [ -z "$CN" ]; then
    echo "ERROR: --cn is required"
    usage
fi

# --- Determine output directory ---
if [ -n "$OUT_DIR" ]; then
    TARGET_DIR="$OUT_DIR"
elif [ -n "${SUDO_USER:-}" ]; then
    TARGET_DIR=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    TARGET_DIR="$HOME"
fi

if [ ! -d "$TARGET_DIR" ]; then
    echo "ERROR: Output directory does not exist: $TARGET_DIR"
    exit 1
fi

# Safe filename based on CN (replace dots/spaces with dashes)
SAFE_CN=$(echo "$CN" | tr './ ' '---')
KEY_OUT="${TARGET_DIR}/${SAFE_CN}.key"
CRT_OUT="${TARGET_DIR}/${SAFE_CN}.crt"

# --- Verify CA assets exist ---
if [ ! -f "${STEPCA_DATA}/certs/intermediate_ca.crt" ]; then
    echo "ERROR: Intermediate CA cert not found at ${STEPCA_DATA}/certs/intermediate_ca.crt"
    exit 1
fi
if [ ! -f "${STEPCA_DATA}/secrets/intermediate_ca_key" ]; then
    echo "ERROR: Intermediate CA key not found at ${STEPCA_DATA}/secrets/intermediate_ca_key"
    exit 1
fi
if [ ! -f "${STEPCA_DATA}/templates/certs/leaf.tpl" ]; then
    echo "ERROR: Leaf certificate template not found at ${STEPCA_DATA}/templates/certs/leaf.tpl"
    echo "Run the Ansible playbook (Section 8) to generate it from the Jinja2 source."
    exit 1
fi

# --- Prepare artifacts directory ---
ARTIFACTS="${STEPCA_DATA}/artifacts"
mkdir -p "$ARTIFACTS"
chown "${STEP_UID}:${STEP_GID}" "$ARTIFACTS"

# --- Handle existing key ---
if [ -n "$EXISTING_KEY" ]; then
    if [ ! -f "$EXISTING_KEY" ]; then
        echo "ERROR: Provided key not found: $EXISTING_KEY"
        exit 1
    fi
    # Copy the key into the artifacts dir so the container can read it
    cp "$EXISTING_KEY" "${ARTIFACTS}/leaf.key"
    chown "${STEP_UID}:${STEP_GID}" "${ARTIFACTS}/leaf.key"
    chmod 0600 "${ARTIFACTS}/leaf.key"

    # Create a CSR from the existing key, then sign it
    echo "Creating CSR from existing key..."
    docker run --rm \
        -v "${STEPCA_DATA}:/home/step" \
        --user "${STEP_UID}:${STEP_GID}" \
        --entrypoint /usr/local/bin/step \
        "$STEPCA_IMAGE" \
        certificate create "$CN" \
        /home/step/artifacts/leaf.csr /dev/null \
        --csr --key /home/step/artifacts/leaf.key \
        --force --no-password --insecure

    # Build SAN arguments
    SAN_ARGS=("--san" "$CN")
    for SAN in "${SANS[@]+"${SANS[@]}"}"; do
        SAN_ARGS+=("--san" "$SAN")
    done

    echo "Signing CSR with intermediate CA..."
    docker run --rm \
        -v "${STEPCA_DATA}:/home/step" \
        --user "${STEP_UID}:${STEP_GID}" \
        --entrypoint /usr/local/bin/step \
        "$STEPCA_IMAGE" \
        certificate sign \
        /home/step/artifacts/leaf.csr \
        /home/step/certs/intermediate_ca.crt \
        /home/step/secrets/intermediate_ca_key \
        --profile leaf \
        --template "$LEAF_TEMPLATE" \
        --not-after "$(( DAYS * 24 ))h" \
        "${SAN_ARGS[@]}" \
        --force \
        --bundle \
        > "${ARTIFACTS}/leaf.crt"

    # Clean up CSR
    rm -f "${ARTIFACTS}/leaf.csr"
else
    # Build SAN arguments for step certificate create
    SAN_ARGS=("--san" "$CN")
    for SAN in "${SANS[@]+"${SANS[@]}"}"; do
        SAN_ARGS+=("--san" "$SAN")
    done

    echo "Generating new key and certificate for ${CN}..."
    docker run --rm \
        -v "${STEPCA_DATA}:/home/step" \
        --user "${STEP_UID}:${STEP_GID}" \
        --entrypoint /usr/local/bin/step \
        "$STEPCA_IMAGE" \
        certificate create "$CN" \
        /home/step/artifacts/leaf.crt /home/step/artifacts/leaf.key \
        --ca /home/step/certs/intermediate_ca.crt \
        --ca-key /home/step/secrets/intermediate_ca_key \
        --no-password --insecure --force \
        --not-after "$(( DAYS * 24 ))h" \
        --profile leaf \
        --template "$LEAF_TEMPLATE" \
        "${SAN_ARGS[@]}"
fi

# --- Export to user's home ---
mv "${ARTIFACTS}/leaf.key" "$KEY_OUT"
mv "${ARTIFACTS}/leaf.crt" "$CRT_OUT"

# Set ownership to the calling user
if [ -n "${SUDO_USER:-}" ]; then
    SUDO_GID=$(id -g "$SUDO_USER")
    chown "${SUDO_USER}:${SUDO_GID}" "$KEY_OUT" "$CRT_OUT"
fi
chmod 0600 "$KEY_OUT"
chmod 0644 "$CRT_OUT"

echo ""
echo "Certificate minted successfully:"
echo "  Key:  $KEY_OUT"
echo "  Cert: $CRT_OUT"
echo ""
echo "Certificate details:"
openssl x509 -in "$CRT_OUT" -noout -subject -dates -ext subjectAltName 2>/dev/null || true
