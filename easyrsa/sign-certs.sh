#!/bin/bash
set -euo pipefail

# --- Root Check ---
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run with sudo or as root."
   exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Configuration ---
IMAGE="alpine:latest"
PKI_DIR="${SCRIPT_DIR}/config"
INTER_DIR="${SCRIPT_DIR}/ica"
DATA_DIR="${SCRIPT_DIR}"

# Step CA Integration Paths & Names
CERT_VIEW="/opt/step-ca/data/certs"
ROOT_NAME="root_ca.crt"
INTERMEDIATE_NAME="intermediate_ca.crt"

# --- Embedded Security Policy ---
export EASYRSA_ALGO="ec"
export EASYRSA_CURVE="secp384r1"
export EASYRSA_DIGEST="sha384"
export EASYRSA_REQ_COUNTRY="US"
export EASYRSA_REQ_PROVINCE="Florida"
export EASYRSA_REQ_CITY="Brandon"
export EASYRSA_REQ_ORG="Church Family Network"

show_help() {
    echo "Usage: sudo $0 [command]"
    echo ""
    echo "Commands:"
    echo "  --generate-rootca              Initialize Root CA (20yr)"
    echo "  --sign-cert                    Sign a CSR request (10yr)"
    echo ""
    echo "Required for --sign-cert:"
    echo "  --csr-path <path>              Path to the input CSR"
    echo ""
    echo "Options:"
    echo "  --crt-path <path>              Destination (Default: $CERT_VIEW/$INTERMEDIATE_NAME)"
    echo "  --san <list>                   SANs (e.g. 'DNS:my.host,IP:1.1.1.1')"
    echo "  --chown <user:group>           UID:GID or user:group for the output CRT"
}

# Parse Arguments
GEN_ROOT=false
SIGN_CERT=false
CSR_PATH=""
CRT_PATH=""
SAN_LIST=""
CHOWN_VAL=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --generate-rootca) GEN_ROOT=true; shift ;;
    --sign-cert) SIGN_CERT=true; shift ;;
    --csr-path) CSR_PATH="$(readlink -f "$2")"; shift 2 ;;
    --crt-path) CRT_PATH="$2"; shift 2 ;;
    --san) SAN_LIST="$2"; shift 2 ;;
    --chown) CHOWN_VAL="$2"; shift 2 ;;
    *) show_help; exit 1 ;;
  esac
done

# Default CRT path to CERT_VIEW/INTERMEDIATE_NAME if not provided
if [[ "$SIGN_CERT" = true && -z "$CRT_PATH" ]]; then
    CRT_PATH="${CERT_VIEW}/${INTERMEDIATE_NAME}"
fi

mkdir -p "$PKI_DIR" "$CERT_VIEW" "$INTER_DIR"
chmod 700 "$PKI_DIR" "$INTER_DIR"
chmod 755 "$CERT_VIEW"

run_easyrsa() {
    local cmd="$1"
    local ou="$2"
    local expire="$3"
    # Fallback to current dir if CSR_PATH isn't set yet (for root gen)
    local input_vol_dir=$(dirname "${CSR_PATH:-$SCRIPT_DIR}")

    docker run -i --rm \
        -v "$PKI_DIR:/pki-dir" \
        -v "$input_vol_dir:/csr-data" \
        -v "/tmp:/out-data" \
        -e EASYRSA_ALGO -e EASYRSA_CURVE -e EASYRSA_DIGEST \
        -e EASYRSA_REQ_COUNTRY -e EASYRSA_REQ_PROVINCE -e EASYRSA_REQ_CITY -e EASYRSA_REQ_ORG \
        -e "EASYRSA_REQ_OU=$ou" \
        -e "EASYRSA_CA_EXPIRE=$expire" \
        -e "EASYRSA_CERT_EXPIRE=$expire" \
        -e "CUSTOM_SAN=$SAN_LIST" \
        "$IMAGE" sh <<CONTAINER_EOF
            apk add --no-cache easy-rsa openssl > /dev/null
            set -euo pipefail
            $cmd
CONTAINER_EOF
}

# --- Function 1: Generate Root CA ---
if [ "$GEN_ROOT" = true ]; then
    echo "[*] Generating Root CA (ECC P-384)..."
    run_easyrsa "
        cd /pki-dir
        /usr/share/easy-rsa/easyrsa init-pki
        /usr/share/easy-rsa/easyrsa --batch build-ca nopass
    " "Root Certificate Authority" "7300"
    
    if [ -f "$PKI_DIR/pki/ca.crt" ]; then
        cp "$PKI_DIR/pki/ca.crt" "$CERT_VIEW/$ROOT_NAME"
        chmod 644 "$CERT_VIEW/$ROOT_NAME"
        chmod 600 "$PKI_DIR/pki/private/ca.key"
        echo "[+] Root CA moved to: $CERT_VIEW/$ROOT_NAME"
    else
        echo "Error: Root CA generation failed."; exit 1
    fi
    exit 0
fi

# --- Function 2: Sign CSR ---
if [ "$SIGN_CERT" = true ]; then
    if [[ -z "$CSR_PATH" || ! -f "$CSR_PATH" ]]; then
        echo "Error: --csr-path is required."; exit 1
    fi
    
    CSR_FILE=$(basename "$CSR_PATH")
    REQ_NAME="${CSR_FILE%.*}"

    echo "[*] Signing CSR: $CSR_FILE..."
    
    run_easyrsa "
        cd /pki-dir
        if [ -n \"\$CUSTOM_SAN\" ]; then
            sed -i 's/^#copy_extensions/copy_extensions/' ./pki/openssl-easyrsa.cnf
            export EASYRSA_EXTRA_EXTS=\"subjectAltName = \$CUSTOM_SAN\"
        fi

        /usr/share/easy-rsa/easyrsa --batch import-req /csr-data/$CSR_FILE $REQ_NAME
        /usr/share/easy-rsa/easyrsa --batch sign-req ca $REQ_NAME
        
        cp /pki-dir/pki/issued/$REQ_NAME.crt /out-data/temp_signed.crt
    " "Certificate Issuing Authority" "3650"
    
    mv /tmp/temp_signed.crt "$CRT_PATH"
    
    # Secure permissions: 640 allows step-ca group read if chowned
    chmod 640 "$CRT_PATH"
    if [ -n "$CHOWN_VAL" ]; then
        chown "$CHOWN_VAL" "$CRT_PATH"
    fi

    echo "[+] Success! Signed cert saved to: $CRT_PATH"
    exit 0
fi
