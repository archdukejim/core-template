#!/bin/bash
set -euo pipefail

# --- Root Check ---
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run with sudo or as root."
   exit 1
fi

show_help() {
    echo "Usage: sudo $0 [options]"
    echo ""
    echo "Actions:"
    echo "  --generate-rootca              Initialize Root CA"
    echo "  --csr-path <path>              Sign a CSR (Triggers signing mode)"
    echo ""
    echo "Parameters (Overrides):"
    echo "  --crt-path <path>              (Required) Output destination for result file"
    echo "  --image <name>                 Docker image (Default: alpine:latest)"
    echo "  --pki-dir <path>               Internal PKI storage (Default: ./config)"
    echo "  --san <list>                   Subject Alternative Names (e.g. 'host.internal')"
    echo "  --chown <user:group>           UID:GID or user:group for output file"
}

# --- Certificate Policy ---
export EASYRSA_ALGO="ec"
export EASYRSA_CURVE="secp384r1"
export EASYRSA_DIGEST="sha384"
export EASYRSA_REQ_COUNTRY="US"
export EASYRSA_REQ_PROVINCE="Florida"
export EASYRSA_REQ_CITY="Brandon"
export EASYRSA_REQ_ORG="Church Family Network"

# --- Defaults ---
GEN_ROOT=false
CSR_PATH=""
CRT_PATH=""
SAN_LIST=""
CHOWN_VAL=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="alpine:latest"
PKI_DIR="${SCRIPT_DIR}/config"

# --- Parse Arguments ---
while [[ $# -gt 0 ]]; do
  case $1 in
    --generate-rootca) GEN_ROOT=true; shift ;;
    --csr-path)        CSR_PATH="$(readlink -f "$2")"; shift 2 ;;
    --crt-path)        CRT_PATH="$2"; shift 2 ;;
    --san)             SAN_LIST="$2"; shift 2 ;;
    --chown)           CHOWN_VAL="$2"; shift 2 ;;
    --image)           IMAGE="$2"; shift 2 ;;
    --pki-dir)         PKI_DIR="$(readlink -f "$2")"; shift 2 ;;
    --sign-cert)       shift ;; # Compat
    -h|--help)         show_help; exit 0 ;;
    *) echo "Unknown option: $1"; show_help; exit 1 ;;
  esac
done

# Logic: Mode Detection
SIGN_CERT=false
if [[ -n "$CSR_PATH" ]]; then SIGN_CERT=true; fi

# Create internal storage only
mkdir -p "$PKI_DIR"
chmod 700 "$PKI_DIR"

run_easyrsa() {
    local cmd="$1"
    local ou="$2"
    local expire="$3"
    # Fallback to script dir for volume mounting if CSR_PATH isn't provided (Root Gen)
    local input_vol_dir=$(dirname "${CSR_PATH:-$SCRIPT_DIR/dummy}")

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
            if [ ! -d "/pki-dir/pki" ]; then
                cd /pki-dir && /usr/share/easy-rsa/easyrsa init-pki > /dev/null
            fi
            $cmd
CONTAINER_EOF
}

# --- Action 1: Generate Root CA ---
if [ "$GEN_ROOT" = true ]; then
    if [[ -z "$CRT_PATH" ]]; then
        echo "Error: --crt-path is mandatory for Root CA generation."; exit 1
    fi

    echo "[*] Generating Root CA (ECC P-384)..."
    run_easyrsa "
        cd /pki-dir
        /usr/share/easy-rsa/easyrsa --batch build-ca nopass
    " "Root Certificate Authority" "7300"
    
    if [ -f "$PKI_DIR/pki/ca.crt" ]; then
        mkdir -p "$(dirname "$CRT_PATH")"
        cp "$PKI_DIR/pki/ca.crt" "$CRT_PATH"
        
        chmod 644 "$CRT_PATH"
        # Secure the internal key
        chmod 600 "$PKI_DIR/pki/private/ca.key"
        
        if [ -n "$CHOWN_VAL" ]; then chown "$CHOWN_VAL" "$CRT_PATH"; fi
        echo "[+] Root CA saved to: $CRT_PATH"
    else
        echo "Error: Root CA generation failed."; exit 1
    fi
    exit 0
fi

# --- Action 2: Sign CSR ---
if [ "$SIGN_CERT" = true ]; then
    if [[ -z "$CRT_PATH" ]]; then
        echo "Error: --crt-path is mandatory for signing operations."; exit 1
    fi
    if [[ ! -f "$CSR_PATH" ]]; then
        echo "Error: CSR file not found at $CSR_PATH"; exit 1
    fi
    
    CSR_FILE=$(basename "$CSR_PATH")
    REQ_NAME="${CSR_FILE%.*}"

    echo "[*] Signing CSR: $CSR_FILE..."
    
    run_easyrsa "
        cd /pki-dir
        /usr/share/easy-rsa/easyrsa show-ca > /dev/null 2>&1 || true
        
        if [ -n \"\$CUSTOM_SAN\" ]; then
            case \"\$CUSTOM_SAN\" in
                DNS:*|IP:*) FINAL_SAN=\"\$CUSTOM_SAN\" ;;
                *)          FINAL_SAN=\"DNS:\$CUSTOM_SAN\" ;;
            esac
            sed -i 's/^#copy_extensions/copy_extensions/' /pki-dir/pki/openssl-easyrsa.cnf
            export EASYRSA_EXTRA_EXTS=\"subjectAltName = \$FINAL_SAN\"
        fi

        /usr/share/easy-rsa/easyrsa --batch import-req /csr-data/$CSR_FILE $REQ_NAME
        /usr/share/easy-rsa/easyrsa --batch sign-req ca $REQ_NAME
        cp /pki-dir/pki/issued/$REQ_NAME.crt /out-data/temp_signed.crt
    " "Certificate Issuing Authority" "3650"
    
    mkdir -p "$(dirname "$CRT_PATH")"
    mv /tmp/temp_signed.crt "$CRT_PATH"
    
    chmod 640 "$CRT_PATH"
    if [ -n "$CHOWN_VAL" ]; then chown "$CHOWN_VAL" "$CRT_PATH"; fi

    echo "[+] Success! Signed cert saved to: $CRT_PATH"
    exit 0
fi

show_help
