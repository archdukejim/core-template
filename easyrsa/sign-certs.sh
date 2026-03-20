#!/bin/bash
set -euo pipefail

# --- Configuration & Pathing ---
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
IMAGE="alpine:latest"
ROOT_VIEW="$SCRIPT_DIR/root"
PKI_DIR="$SCRIPT_DIR/config"
INTER_DIR="$SCRIPT_DIR/ica"
DATA_DIR="$SCRIPT_DIR"

# --- Embedded Security Policy ---
export EASYRSA_ALGO="ec"
export EASYRSA_CURVE="secp384r1"
export EASYRSA_DIGEST="sha384"
export EASYRSA_REQ_COUNTRY="US"
export EASYRSA_REQ_PROVINCE="Florida"
export EASYRSA_REQ_CITY="Brandon"
export EASYRSA_REQ_ORG="Home Network Infrastructure"

show_help() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  --generate-rootca              Initialize Root CA (20yr)"
    echo "  --sign-cert --public <path>    Sign a public key (1yr)"
    echo ""
    echo "Options:"
    echo "  --san <list>                   SANs (e.g. 'DNS:my.host,IP:1.1.1.1')"
}

# Parse Arguments
GEN_ROOT=false
SIGN_CERT=false
PUB_KEY_PATH=""
SAN_LIST=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --generate-rootca) GEN_ROOT=true; shift ;;
    --public) PUB_KEY_PATH="$(realpath "$2")"; shift 2 ;;
    --sign-cert) SIGN_CERT=true; shift ;;
    --san) SAN_LIST="$2"; shift 2 ;;
    *) show_help; exit 1 ;;
  esac
done

run_easyrsa() {
    local cmd="$1"
    local ou="$2"
    local expire="$3"
    # Note: ROOT_VIEW is NOT mounted here
    docker run -it --rm \
        -v "$PKI_DIR:/pki-dir" \
        -v "$INTER_DIR:/inter-pki" \
        -v "$DATA_DIR:/data" \
        -e EASYRSA_ALGO -e EASYRSA_CURVE -e EASYRSA_DIGEST \
        -e EASYRSA_REQ_COUNTRY -e EASYRSA_REQ_PROVINCE -e EASYRSA_REQ_CITY -e EASYRSA_REQ_ORG \
        -e "EASYRSA_REQ_OU=$ou" \
        -e "EASYRSA_CA_EXPIRE=$expire" \
        -e "EASYRSA_CERT_EXPIRE=$expire" \
        -e "CUSTOM_SAN=$SAN_LIST" \
        "$IMAGE" sh -c "
            apk add --no-cache easy-rsa openssl > /dev/null
            set -euo pipefail
            $cmd
        "
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

# --- Function 2: Sign Cert ---
if [ "$SIGN_CERT" = true ]; then
    if [[ -z "$PUB_KEY_PATH" || ! -f "$PUB_KEY_PATH" ]]; then
        echo "Error: --public key path is required."; exit 1
    fi
    
    FILE_NAME=$(basename "$PUB_KEY_PATH")
    REQ_NAME="${FILE_NAME%.*}"

    echo "[*] Signing $REQ_NAME..."
    mkdir -p "$INTER_DIR"
    
    run_easyrsa "
        if [ ! -d /inter-pki/pki ]; then
            cd /inter-pki && /usr/share/easy-rsa/easyrsa init-pki
        fi

        openssl x509 -x509toreq -in /data/$FILE_NAME -signkey /data/$FILE_NAME -out /tmp/$REQ_NAME.req 2>/dev/null || \
        openssl req -new -key /data/$FILE_NAME -subj \"/CN=$REQ_NAME\" -out /tmp/$REQ_NAME.req

        if [ -n \"\$CUSTOM_SAN\" ]; then
            export EASYRSA_EXTRA_EXTS=\"subjectAltName = \$CUSTOM_SAN\"
        else
            export EASYRSA_EXTRA_EXTS=\"subjectAltName = DNS:$REQ_NAME\"
        fi

        cd /pki-dir
        /usr/share/easy-rsa/easyrsa --batch import-req /tmp/$REQ_NAME.req $REQ_NAME
        /usr/share/easy-rsa/easyrsa --batch sign-req client $REQ_NAME
        
        cp /pki-dir/pki/issued/$REQ_NAME.crt /data/
    " "Certificate Issuing Authority" "365"
    
    # Adjust permissions for the newly signed cert on the host
    chmod 644 "$DATA_DIR/$REQ_NAME.crt"
    chown $(id -u):$(id -g) "$DATA_DIR/$REQ_NAME.crt"
    
    echo "[+] Success! Signed cert saved to: $DATA_DIR/$REQ_NAME.crt"
    exit 0
fi
