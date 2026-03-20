#!/bin/bash
set -euo pipefail

# --- Configuration & Pathing ---
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
IMAGE="alpine:latest"
ROOT_VIEW="${SCRIPT_DIR}/root"
PKI_DIR="${SCRIPT_DIR}/config"
INTER_DIR="${SCRIPT_DIR}/ica"
DATA_DIR="${SCRIPT_DIR}"



PKI_DIR="${SCRIPT_DIR}/config"

# --- Embedded Security Policy ---
export EASYRSA_ALGO="ec"
export EASYRSA_CURVE="secp384r1"
export EASYRSA_DIGEST="sha384"
export EASYRSA_REQ_COUNTRY="US"
export EASYRSA_REQ_PROVINCE="Florida"
export EASYRSA_REQ_CITY="Brandon"
export EASYRSA_REQ_ORG="Church Family Network"

show_help() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  --generate-rootca              Initialize Root CA (20yr)"
    echo "  --sign-cert --path <path>      Sign a csr request (1yr)"
    echo ""
    echo "Options:"
    echo "  --san <list>                   SANs (e.g. 'DNS:my.host,IP:1.1.1.1')"
}

# Parse Arguments
GEN_ROOT=false
SIGN_CERT=false
PATH=""
SAN_LIST=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --generate-rootca) GEN_ROOT=true; shift ;;
    --path) PATH="$(realpath "$2")"; shift 2 ;;
    --sign-cert) SIGN_CERT=true; shift ;;
    --san) SAN_LIST="$2"; shift 2 ;;
    *) show_help; exit 1 ;;
  esac
done

run_easyrsa() {
    local cmd="$1"
    local ou="$2"
    local expire="$3"

    # We use -i and pipe the command string to sh via STDIN
    docker run -i --rm \
        -v "$PKI_DIR:/pki-dir" \
        -v "$INTER_DIR:/inter-pki" \
        -v "$DATA_DIR:/data" \
        -e EASYRSA_ALGO -e EASYRSA_CURVE -e EASYRSA_DIGEST \
        -e EASYRSA_REQ_COUNTRY -e EASYRSA_REQ_PROVINCE -e EASYRSA_REQ_CITY -e EASYRSA_REQ_ORG \
        -e "EASYRSA_REQ_OU=$ou" \
        -e "EASYRSA_CA_EXPIRE=$expire" \
        -e "EASYRSA_CERT_EXPIRE=$expire" \
        -e "CUSTOM_SAN=$SAN_LIST" \
        "$IMAGE" sh <<EOF
            apk add --no-cache easy-rsa openssl > /dev/null
            set -euo pipefail
            $cmd
EOF
}

# --- Function 1: Generate Root CA ---
if [ "$GEN_ROOT" = true ]; then
    echo "[*] Generating Root CA (ECC P-384)..."
    mkdir -p "$PKI_DIR" "$ROOT_VIEW"
    run_easyrsa "
        cd /pki-dir
        /usr/share/easy-rsa/easyrsa init-pki
        /usr/share/easy-rsa/easyrsa --batch build-ca nopass
    " "Root Certificate Authority" "7300"
    # Move and set permissions on the HOST after container runs
    if [ -f "$PKI_DIR/pki/ca.crt" ]; then
        cp "$PKI_DIR/pki/ca.crt" "$ROOT_VIEW/ca.crt"
        # Ensure the host user owns it and anyone can read it
        chmod 644 "$ROOT_VIEW/ca.crt"
        chown $(id -u):$(id -g) "$ROOT_VIEW/ca.crt"
        echo "[+] Public cert moved to: $ROOT_VIEW/ca.crt (Permissions set to 644)"
    else
        echo "Error: ca.crt was not generated."
        exit 1
    fi
    exit 0
fi

# --- Function 2: Sign CSR (New/Improved) ---
if [ "$SIGN_CERT" = true ]; then
    if [[ -z "$PATH" || ! -f "$PATH" ]]; then
        echo "Error: --public path (CSR) is required."; exit 1
    fi
    
    FILE_NAME=$(basename "$PATH")
    REQ_NAME="${FILE_NAME%.*}"

    echo "[*] Signing CSR: $FILE_NAME..."
    
    run_easyrsa "
        # Skip generation—import the CSR directly from /data
        cd /pki-dir
        
        # Enable SAN copying if provided
        if [ -n \"\$CUSTOM_SAN\" ]; then
            sed -i 's/^#copy_extensions/copy_extensions/' ./pki/openssl-easyrsa.cnf
            export EASYRSA_EXTRA_EXTS=\"subjectAltName = \$CUSTOM_SAN\"
        fi

        # Import and Sign
        /usr/share/easy-rsa/easyrsa --batch import-req /data/$FILE_NAME $REQ_NAME
        /usr/share/easy-rsa/easyrsa --batch sign-req ca $REQ_NAME
        
        # Cleanup config
        sed -i 's/^copy_extensions/#copy_extensions/' ./pki/openssl-easyrsa.cnf

        cp /pki-dir/pki/issued/$REQ_NAME.crt /data/
    " "Certificate Issuing Authority" "3650"
    
    chmod 644 "$DATA_DIR/$REQ_NAME.crt"
    echo "[+] Success! Signed cert saved to: $DATA_DIR/$REQ_NAME.crt"
    exit 0
fi