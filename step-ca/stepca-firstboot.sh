#!/bin/bash
set -euo pipefail

# --- Configuration ---
DATA_DIR="/opt/step-ca/data"
SIGNER_SCRIPT="/opt/easyrsa/sign-certs.sh"
IMAGE="smallstep/step-ca:latest"
CA_NAME="Church Family Network CA"
DNS_NAMES="ca.internal"
PW_FILE="${DATA_DIR}/secrets/password"

echo "[*] Step 1: Preparing Directory Structure..."
mkdir -p "${DATA_DIR}/secrets" "${DATA_DIR}/artifacts" "${DATA_DIR}/certs" "${DATA_DIR}/config"
[ ! -f "$PW_FILE" ] && openssl rand -base64 32 > "$PW_FILE"
chown -R 2002:2002 "$DATA_DIR"

echo "[*] Step 2: Initializing ca.json (Headless)..."
docker run --rm \
    -v "${DATA_DIR}:/home/step" \
    --user "2002:2002" \
    "$IMAGE" \
    step ca init --name="$CA_NAME" \
    --dns="$DNS_NAMES" \
    --address=":9000" \
    --provisioner="admin" \
    --password-file="/home/step/secrets/password" \
    --provisioner-password-file="/home/step/secrets/password" \
    --batch > /dev/null

echo "[*] Step 3: Generating CSR and Intermediate Key..."
docker run --rm \
    -v "${DATA_DIR}:/home/step" \
    --user "2002:2002" \
    "$IMAGE" \
    step certificate create "$CA_NAME Intermediate" \
    /home/step/artifacts/intermediate.csr \
    /home/step/secrets/intermediate_ca_key \
    --csr --force --no-password --insecure > /dev/null

echo "[*] Step 4: Signing CSR with EasyRSA..."
# This correctly passes the SAN and targets the default CRT_PATH inside DATA_DIR
bash "$SIGNER_SCRIPT" \
    --csr-path "${DATA_DIR}/artifacts/intermediate.csr" \
    --san "${DNS_NAMES}" \
    --chown "2002:2002"

echo "[*] Step 5: Updating Root CA Trust Chain..."
# Crucial: replace Step's generated root with the one from your EasyRSA Action 1
# This ensures the chain: EasyRSA Root -> Signed Intermediate -> Issued Certs
cp "/opt/step-ca/data/certs/root_ca.crt" "${DATA_DIR}/certs/root_ca.crt"

# Final Permission Polish for the entire volume
chown -R 2002:2002 "$DATA_DIR"

echo "------------------------------------------------------"
echo "[+] Pre-conditioning Complete!"
echo "[+] You can now run your docker-compose up -d"
echo "------------------------------------------------------"
