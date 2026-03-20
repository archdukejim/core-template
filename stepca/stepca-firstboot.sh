# --- 5. Bootstrapping PKI (EasyRSA & Step-CA) ---
echo "[*] Generating Root CA via EasyRSA..."
bash "$TARGET_BASE/easyrsa/sign-certs.sh" --generate-rootca

echo "[*] Initializing Step-CA..."
DATA_DIR="$TARGET_BASE/stepca/data"
PW_FILE="${DATA_DIR}/secrets/password"

mkdir -p "${DATA_DIR}/secrets" "${DATA_DIR}/artifacts"
[ ! -f "$PW_FILE" ] && openssl rand -base64 32 > "$PW_FILE"
chown -R 2002:2002 "$DATA_DIR"

# Run Init - Explicitly using the 'step' entrypoint to avoid "ca.json missing" errors
docker run --rm \
    -v "${DATA_DIR}:/home/step" \
    --user "2002:2002" \
    smallstep/step-ca:latest \
    step ca init --name="Internal CA" \
    --dns="ca.internal" \
    --address=":9000" \
    --provisioner="admin" \
    --password-file="/home/step/secrets/password" \
    --provisioner-password-file="/home/step/secrets/password" \
    --batch

# Generate Intermediate CSR
docker run --rm \
    -v "${DATA_DIR}:/home/step" \
    --user "2002:2002" \
    smallstep/step-ca:latest \
    step certificate create "Intermediate CA" \
    /home/step/artifacts/intermediate.csr \
    /home/step/secrets/intermediate_ca_key \
    --csr --force --no-password --insecure

# Sign the Intermediate with EasyRSA
bash "$TARGET_BASE/easyrsa/sign-certs.sh" \
    --csr-path "${DATA_DIR}/artifacts/intermediate.csr" \
    --chown "2002:2002"

# --- 6. Generate RFC2136 TSIG Keys ---
echo "[*] Generating TSIG keys for BIND and Certbot..."
SECRET=$(openssl rand -base64 32)
BIND_KEY_FILE="$TARGET_BASE/bind9/config/named.conf.keys"
CERTBOT_INI_FILE="$TARGET_BASE/certbot/rfc2136.ini"

cat <<EOF > "$BIND_KEY_FILE"
key "acme_dns-01" {
    algorithm hmac-sha256;
    secret "$SECRET";
};
EOF

cat <<EOF > "$CERTBOT_INI_FILE"
dns_rfc2136_server = 172.30.255.53
dns_rfc2136_port = 53
dns_rfc2136_name = acme_dns-01
dns_rfc2136_secret = $SECRET
dns_rfc2136_algorithm = HMAC-SHA256
EOF

chown 2001:2001 "$BIND_KEY_FILE"
chown 2004:2004 "$CERTBOT_INI_FILE"
chmod 640 "$BIND_KEY_FILE"
chmod 600 "$CERTBOT_INI_FILE"
