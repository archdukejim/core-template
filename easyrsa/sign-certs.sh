#!/bin/bash
set -euo pipefail

# Configuration
IMAGE="alpine:latest"
ROOT_DIR="$(pwd)/root-pki"
INTER_DIR="$(pwd)/inter-pki"
DATA_DIR="$(pwd)"

show_help() {
    echo "Usage: $0 --vars <path> [command]"
    echo ""
    echo "Commands:"
    echo "  --generate-rootca              Initialize and build Root CA (Interactive)"
    echo "  --sign-cert --public <path>    Sign a public key with Intermediate CA"
    echo ""
    echo "Options:"
    echo "  --vars <path>                  Path to the specific vars file to use"
    echo "  --san <list>                   SANs (e.g. 'DNS:apps.internal,IP:192.168.4.5')"
}

# Parse Arguments
GEN_ROOT=false
SIGN_CERT=false
VARS_PATH=""
PUB_KEY_PATH=""
SAN_LIST=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --vars) VARS_PATH="$(realpath "$2")"; shift 2 ;;
    --generate-rootca) GEN_ROOT=true; shift ;;
    --public) PUB_KEY_PATH="$(realpath "$2")"; shift 2 ;;
    --sign-cert) SIGN_CERT=true; shift ;;
    --san) SAN_LIST="$2"; shift 2 ;;
    *) show_help; exit 1 ;;
  esac
done

if [[ -z "$VARS_PATH" || ! -f "$VARS_PATH" ]]; then
    echo "Error: Valid --vars file path is required."; exit 1
fi

run_easyrsa() {
    local cmd="$1"
    docker run -it --rm \
        -v "$ROOT_DIR:/root-pki" \
        -v "$INTER_DIR:/inter-pki" \
        -v "$DATA_DIR:/data" \
        -v "$VARS_PATH:/custom_vars:ro" \
        -e "CUSTOM_SAN=$SAN_LIST" \
        "$IMAGE" sh -c "
            apk add --no-cache easy-rsa openssl > /dev/null
            set -euo pipefail
            $cmd
        "
}

# --- Function 1: Generate Root CA ---
if [ "$GEN_ROOT" = true ]; then
    echo "[*] Initializing Verbose Root CA..."
    mkdir -p "$ROOT_DIR"
    run_easyrsa "
        cd /root-pki
        /usr/share/easy-rsa/easyrsa init-pki
        cp /custom_vars ./pki/vars
        /usr/share/easy-rsa/easyrsa build-ca
    "
    echo "[+] Root CA generated in $ROOT_DIR"
    exit 0
fi

# --- Function 2: Sign Cert with Intermediate ---
if [ "$SIGN_CERT" = true ]; then
    if [[ -z "$PUB_KEY_PATH" || ! -f "$PUB_KEY_PATH" ]]; then
        echo "Error: --public key path is required."; exit 1
    fi
    
    FILE_NAME=$(basename "$PUB_KEY_PATH")
    REQ_NAME="${FILE_NAME%.*}"

    echo "[*] Signing $REQ_NAME using Intermediate PKI..."
    mkdir -p "$INTER_DIR"
    
    run_easyrsa "
        # 1. Setup Intermediate PKI if missing
        if [ ! -d /inter-pki/pki ]; then
            cd /inter-pki && /usr/share/easy-rsa/easyrsa init-pki
            cp /custom_vars ./pki/vars
        fi

        # 2. Convert Public Key to CSR
        openssl x509 -x509toreq -in /data/$FILE_NAME -signkey /data/$FILE_NAME -out /tmp/$REQ_NAME.req 2>/dev/null || \
        openssl req -new -key /data/$FILE_NAME -subj '/CN=$REQ_NAME' -out /tmp/$REQ_NAME.req

        # 3. Inject SANs
        if [ -n \"\$CUSTOM_SAN\" ]; then
            export EASYRSA_EXTRA_EXTS=\"subjectAltName = \$CUSTOM_SAN\"
        else
            export EASYRSA_EXTRA_EXTS=\"subjectAltName = DNS:$REQ_NAME\"
        fi

        # 4. Import to Root (which acts as the signer for this chain) and Sign
        cd /root-pki
        # Ensure Root PKI has the intermediate vars for the signing constraints
        cp /custom_vars ./pki/vars 
        /usr/share/easy-rsa/easyrsa --batch import-req /tmp/$REQ_NAME.req $REQ_NAME
        /usr/share/easy-rsa/easyrsa --batch sign-req client $REQ_NAME
        
        cp /root-pki/pki/issued/$REQ_NAME.crt /data/
    "
    echo "[+] Success! Signed cert saved to: $DATA_DIR/$REQ_NAME.crt"
    exit 0
fi
