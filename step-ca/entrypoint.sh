#!/bin/bash
set -e

# Define paths inside the container
STEPPATH="/home/step"
CERT_DIR="$STEPPATH/certs"
CONFIG_FILE="$STEPPATH/config/ca.json"
ROOT_CERT="$CERT_DIR/root_ca.crt"
INTER_CERT="$CERT_DIR/intermediate_ca.crt"
INTER_KEY="$STEPPATH/secrets/intermediate_ca_key"
INTER_CSR="$STEPPATH/artifacts/intermediate.csr"

mkdir -p "$CERT_DIR" "$STEPPATH/secrets" "$STEPPATH/artifacts"

# --- CASE 1: PROD STARTUP ---
# Check if the signed intermediate and root are already present
if [[ -f "$ROOT_CERT" && -f "$INTER_CERT" && -f "$INTER_KEY" ]]; then
    echo "[*] Found signed certificates. Verifying chain..."
    # Optional: verify that the intermediate is actually signed by the root
    step certificate verify "$INTER_CERT" --roots "$ROOT_CERT" > /dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        echo "[+] Chain verified. Starting step-ca..."
        exec /usr/local/bin/step-ca "$CONFIG_FILE" --password-file "$STEPPATH/secrets/password"
    else
        echo "[!] Error: Intermediate certificate does not match the Root CA."
        exit 1
    fi

# --- CASE 2: INITIAL BOOTSTRAP ---
else
    echo "[*] Certificates missing. Starting bootstrap process..."
    
    if [ ! -f "$INTER_KEY" ]; then
        echo "[*] Generating Intermediate Private Key and CSR..."
        # Generate a CSR for the CA to be signed by your offline Root
        # We use --csr to ensure we only get a request, not a self-signed cert
        step certificate create "Home Intermediate CA" "$INTER_CSR" "$INTER_KEY" \
            --csr --force --no-password --insecure
            
        echo "[+] CSR generated at $INTER_CSR"
        echo "[!] ACTION REQUIRED: Sign this CSR with your Root CA, then place 'root_ca.crt' and 'intermediate_ca.crt' in the certs folder."
        echo "[!] The container will now exit. Restart after adding the signed files."
        exit 0
    else
        echo "[!] Private key exists but signed certificate is missing. Please provide 'intermediate_ca.crt'."
        exit 1
    fi
fi
