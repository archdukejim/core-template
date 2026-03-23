#!/bin/bash
set -e

# --- 1. Root Check & Dependency Setup ---
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root."
   exit 1
fi

# Check for setfacl (part of the 'acl' package)
if ! command -v setfacl &> /dev/null; then
    echo "Installing 'acl' package for permission management..."
    apt-get update && apt-get install -y acl
else
    echo "[*] Dependency check: 'setfacl' is already installed."
fi

# --- 2. Variable Selection ---
# Get the home directory of the actual user who ran sudo
REAL_USER_HOME=$(eval echo "~$SUDO_USER")
DEFAULT_REPO="${REAL_USER_HOME}/home-core"

read -p "Enter source path [$DEFAULT_REPO]: " REPO_SOURCE
REPO_SOURCE=${REPO_SOURCE:-$DEFAULT_REPO}

read -p "Enter target path [/opt]: " TARGET_BASE
TARGET_BASE=${TARGET_BASE:-/opt}

# --- 2.5. Pre-Install Cleanup ---
echo "[*] Stopping any existing project containers to prevent file locks..."
# This stops containers by name if they exist, targeting your specific service list
docker stop nginx adguard certbot stepca openldap bind9 2>/dev/null || true

# --- 3. Free Port 53 (Systemd-resolved) ---
if [ -f "/etc/systemd/resolved.conf.d/adguard-bind.conf" ] && ! ss -tulnp | grep -q ":53 "; then
    echo "[*] Port 53 already freed. Skipping."
else
    echo "[*] Disabling systemd-resolved stub listener..."
    mkdir -p /etc/systemd/resolved.conf.d/
    cat <<EOF > /etc/systemd/resolved.conf.d/adguard-bind.conf
[Resolve]
DNS=127.0.0.1
DNSStubListener=no
EOF
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    systemctl restart systemd-resolved
fi

# --- 4. Users and Directory Structure ---
echo "[*] Verifying and creating service users..."
# Fixed bind to 53 based on container 'id -u bind' check
declare -A services=( ["nginx"]="2000" ["bind"]="53" ["step"]="2002" ["ldap"]="2003" ["certbot"]="2004" ["adguard"]="2700" )

for user in "${!services[@]}"; do
    TARGET_ID="${services[$user]}"
    
    if id "$user" &>/dev/null; then
        EXISTING_UID=$(id -u "$user")
        
        if [[ "$EXISTING_UID" != "$TARGET_ID" ]]; then
            echo "[!] User '$user' exists with ID $EXISTING_UID. Re-aligning to $TARGET_ID..."
            # Kill any active bind processes so usermod doesn't fail
            pkill -u "$user" || true
            # Force the existing user/group to 53:53
            groupmod -g "$TARGET_ID" "$user"
            usermod -u "$TARGET_ID" -g "$TARGET_ID" "$user"
            echo "[+] Re-aligned '$user' to $TARGET_ID."
        else
            echo "[*] User '$user' already exists with correct ID ($TARGET_ID)."
        fi
    else
        groupadd -g "$TARGET_ID" "$user"
        useradd -u "$TARGET_ID" -g "$TARGET_ID" -s /usr/sbin/nologin -r "$user"
        echo "[+] Created user '$user' with ID $TARGET_ID."
    fi
done

# Prepare Target Base
mkdir -p "$TARGET_BASE/core"

echo "[*] Copying project files..."
find "$REPO_SOURCE" -maxdepth 1 -type f -exec cp -t "$TARGET_BASE/core/" {} +

cp -r "$REPO_SOURCE/nginx" "$TARGET_BASE/"
cp -r "$REPO_SOURCE/adguardhome" "$TARGET_BASE/"
cp -r "$REPO_SOURCE/bind9" "$TARGET_BASE/"
cp -r "$REPO_SOURCE/stepca" "$TARGET_BASE/stepca"
cp -r "$REPO_SOURCE/openldap" "$TARGET_BASE/"
cp -r "$REPO_SOURCE/certbot" "$TARGET_BASE/"
cp -r "$REPO_SOURCE/easyrsa" "$TARGET_BASE/"

# 3. Set Permissions (Everything now synced to UID 53 for bind)
echo "[*] Setting directory permissions..."
chown -R 2000:2000 "$TARGET_BASE/nginx"
chown -R 2700:2700 "$TARGET_BASE/adguardhome"
chown -R 53:53 "$TARGET_BASE/bind9"
chown -R 2002:2002 "$TARGET_BASE/stepca"
chown -R 2003:2003 "$TARGET_BASE/openldap"
chown -R 2004:2004 "$TARGET_BASE/certbot"
chown -R root:root "$TARGET_BASE/core"

# --- 5. Bootstrapping PKI (Optimized with sign-certs.sh parameters) ---
echo "[*] Configuring Step-CA..."
DATA_DIR="$TARGET_BASE/stepca/data"
PW_FILE="${DATA_DIR}/secrets/password"
SIGNER="$TARGET_BASE/easyrsa/sign-certs.sh"

# Ensure secrets directory exists for the password file
mkdir -p "${DATA_DIR}/secrets" "${DATA_DIR}/artifacts" "${DATA_DIR}/certs"
[ ! -f "$PW_FILE" ] && openssl rand -base64 32 > "$PW_FILE"
chown -R 2002:2002 "$DATA_DIR"

# 1. Generate Root CA
echo "[*] Generating Root CA..."
bash "$SIGNER" --generate-rootca --crt-path "${DATA_DIR}/certs/root_ca.crt"

# 2. Initialize Step-CA 
if [ ! -f "${DATA_DIR}/config/ca.json" ]; then
    echo "[*] Initializing Step-CA structure..."
    
    # CRITICAL: Temporarily move the Root CA so 'step' doesn't prompt for overwrite and crash
    mv "${DATA_DIR}/certs/root_ca.crt" /tmp/root_ca.crt.bak

    docker run --rm -v "${DATA_DIR}:/home/step" --user "2002:2002" --entrypoint /usr/local/bin/step \
        smallstep/step-ca:latest ca init --name="Internal CA" --dns="ca.internal" --address=":9000" \
        --provisioner="admin" --password-file="/home/step/secrets/password" --provisioner-password-file="/home/step/secrets/password"

    # Restore the real Root CA, overwriting the one 'step' just made
    mv /tmp/root_ca.crt.bak "${DATA_DIR}/certs/root_ca.crt"
else
    echo "[*] Step-CA already initialized. Skipping 'ca init'."
fi

# 3. Generate Intermediate CSR and Sign it
echo "[*] Generating and Signing Intermediate..."
docker run --rm -v "${DATA_DIR}:/home/step" --user "2002:2002" --entrypoint /usr/local/bin/step \
    smallstep/step-ca:latest certificate create "Intermediate CA" \
    /home/step/artifacts/intermediate.csr /home/step/secrets/intermediate_ca_key \
    --csr --force --no-password --insecure

bash "$SIGNER" --csr-path "${DATA_DIR}/artifacts/intermediate.csr" \
               --crt-path "${DATA_DIR}/certs/intermediate_ca.crt" \
               --chown "2002:2002"

# 4. Final Surgical Config Update
sed -i 's|"root": ".*"|"root": "/home/step/certs/root_ca.crt"|' "${DATA_DIR}/config/ca.json"
sed -i 's|"crt": ".*"|"crt": "/home/step/certs/intermediate_ca.crt"|' "${DATA_DIR}/config/ca.json"
sed -i 's|"key": ".*"|"key": "/home/step/secrets/intermediate_ca_key"|' "${DATA_DIR}/config/ca.json"

chown -R 2002:2002 "$DATA_DIR"

# Verify the intermediate certificate against the root
openssl verify -CAfile "${DATA_DIR}/certs/root_ca.crt" "${DATA_DIR}/certs/intermediate_ca.crt"

echo "[+] Step-CA setup complete."

# --- 6. Prepare BIND9 (TSIG Keys & Static 10-Year TLS) ---
echo "[*] Generating TSIG keys and infrastructure certificates..."

# Define shared directory variables
COMPOSE_FILE="/opt/core/docker-compose.yml"
DATA_DIR="$TARGET_BASE/stepca/data"
ARTIFACT_DIR="${DATA_DIR}/artifacts"

BIND_STATIC_IP="172.30.255.30" 
BIND_KEY_FILE="$TARGET_BASE/bind9/config/named.conf.keys"
BIND_TLS_DIR="$TARGET_BASE/bind9/ssl"
CERTBOT_ETC="$TARGET_BASE/certbot/etc/letsencrypt"
CERTBOT_INI="$CERTBOT_ETC/rfc2136.ini"
CERTBOT_CLI="$CERTBOT_ETC/cli.ini"

# 1. Generate Shared TSIG Secret
SECRET=$(openssl rand -base64 32)

# 2. Create BIND9 Key File (Server Side)
mkdir -p "$(dirname "$BIND_KEY_FILE")"
cat <<EOF > "$BIND_KEY_FILE"
key "acme_dns-01" {
    algorithm hmac-sha256;
    secret "$SECRET";
};
EOF

# 3. Setup Certbot Directory
mkdir -p "$CERTBOT_ETC"

# 4. Create RFC2136 Credentials (Client Side)
# base_domain here prevents the "unrecognized arguments" CLI error
cat <<EOF > "$CERTBOT_INI"
dns_rfc2136_server = $BIND_STATIC_IP
dns_rfc2136_port = 5353
dns_rfc2136_name = acme_dns-01
dns_rfc2136_secret = $SECRET
dns_rfc2136_algorithm = HMAC-SHA256
dns_rfc2136_base_domain = internal
EOF

# 5. Create Global Certbot CLI Config
cat <<EOF > "$CERTBOT_CLI"
server = https://ca.internal:9000/acme/acme/directory
agree-tos = true
no-eff-email = true
email = admin@home.internal
authenticator = dns-rfc2136
dns-rfc2136-credentials = /etc/letsencrypt/rfc2136.ini
dns-rfc2136-propagation-seconds = 10
EOF

# 6. Apply Initial Permissions
chown 53:53 "$BIND_KEY_FILE" && chmod 600 "$BIND_KEY_FILE"
chown 2004:2004 "$CERTBOT_INI" "$CERTBOT_CLI" && chmod 600 "$CERTBOT_INI" "$CERTBOT_CLI"

# 7. Mint 10-Year Static TLS Cert for BIND9
echo "[*] Minting 10-year TLS certificate for BIND9 via Step-CA..."
mkdir -p "$BIND_TLS_DIR"

docker run --rm -v "${DATA_DIR}:/home/step" \
    --user "2002:2002" --entrypoint /usr/local/bin/step \
    smallstep/step-ca:latest certificate create "dns.internal" \
    "/home/step/artifacts/bind9.key" "/home/step/artifacts/bind9.crt" \
    --ca "/home/step/certs/intermediate_ca.crt" \
    --ca-key "/home/step/secrets/intermediate_ca_key" \
    --no-password --insecure --force \
    --not-after 87600h \
    --profile leaf \
    --san dns.internal --san ns.internal --san 127.0.0.1

# Move files and build fullchain
mv "${ARTIFACT_DIR}/bind9.key" "$BIND_TLS_DIR/privkey.pem"
mv "${ARTIFACT_DIR}/bind9.crt" "$BIND_TLS_DIR/cert.pem"

cat "$BIND_TLS_DIR/cert.pem" "${DATA_DIR}/certs/intermediate_ca.crt" > "$BIND_TLS_DIR/fullchain.pem"
cp "${DATA_DIR}/certs/root_ca.crt" "$BIND_TLS_DIR/root_ca.crt"
cp "${DATA_DIR}/certs/root_ca.crt" "$CERTBOT_ETC/root_ca.crt"

rm "$BIND_TLS_DIR/cert.pem"

# 8. Final Polish & Permissions
echo "[*] Finalizing BIND9 and Certbot infrastructure permissions..."
chown 53:53 "$BIND_KEY_FILE"
chown -R 53:53 "$BIND_TLS_DIR"
chmod 600 "$BIND_TLS_DIR/privkey.pem"
chmod 644 "$BIND_TLS_DIR/fullchain.pem"
chmod 644 "$BIND_TLS_DIR/root_ca.crt"

chown 2004:2004 "$CERTBOT_INI" "$CERTBOT_CLI" "$CERTBOT_ETC/root_ca.crt"

echo "[+] Infrastructure setup complete."

# --- 7. Finalize Hooks ---
chmod +x "$TARGET_BASE/certbot/hooks/cert-update.sh"
chmod +x "$TARGET_BASE/certbot/cert-relay-host.sh"

# Create the FIFO relay pipe (inside the letsencrypt volume so certbot can see it)
mkdir -p "$TARGET_BASE/certbot/etc/letsencrypt"
RELAY_FIFO="$TARGET_BASE/certbot/etc/letsencrypt/relay.fifo"
[ -p "$RELAY_FIFO" ] || mkfifo "$RELAY_FIFO"
chown root:root "$RELAY_FIFO"
chmod 600 "$RELAY_FIFO"

# Install and start the host-side ACL relay service
cp "$TARGET_BASE/certbot/cert-relay.service" /etc/systemd/system/cert-relay.service
systemctl daemon-reload
systemctl enable cert-relay
systemctl restart cert-relay

# --- 8. Initial Certificate Issuance (First Boot) ---
echo "[*] Configuring Certbot and triggering initial issuance..."
CORE_DIR="$TARGET_BASE/core"
cd "$CORE_DIR"

# 1. Ensure Step-CA Trust is in place
# Note: cli.ini and rfc2136.ini were already generated in Section 6
echo "[*] Ensuring Certbot trusts Internal CA..."
mkdir -p "$TARGET_BASE/certbot/etc/letsencrypt"
cp "$TARGET_BASE/stepca/data/certs/root_ca.crt" "$TARGET_BASE/certbot/etc/letsencrypt/root_ca.crt"

# 2. Start Infrastructure
echo "[*] Starting BIND9 and Step-CA..."
docker compose -f "$COMPOSE_FILE" up -d bind9 step-ca

# 3. Wait for BIND9 Healthy
echo -n "[*] Waiting for BIND9 health check"
until [ "$(docker inspect -f '{{.State.Health.Status}}' bind9 2>/dev/null)" == "healthy" ]; do
    printf "."
    sleep 1
done
echo " [OK]"

# 4. Enable ACME Provisioner in Step-CA
echo "[*] Checking for ACME provisioner..."
if ! docker exec --workdir / step-ca step ca provisioner list \
    --ca-url https://ca.internal:9000 \
    --root /home/step/certs/root_ca.crt | grep -q '"type": "ACME"'; then
    
    echo "[+] Adding ACME provisioner to Step-CA..."
    docker exec --workdir / step-ca step ca provisioner add acme --type ACME
    docker compose -f "$COMPOSE_FILE" restart step-ca
    sleep 5
fi

# 5. Issue Real Certificates
echo "[*] Requesting initial certificates..."

# Ensure core infra is running, stop the certbot loop container to prevent locks
docker compose -f "$COMPOSE_FILE" up -d bind9 step-ca
docker compose -f "$COMPOSE_FILE" stop certbot

# Certbot manages these dynamic services (dns.internal is static 10-year)
DOMAINS=("adguard.internal" "ldap.internal")

# Check the first domain to decide if bootstrap is needed
if [ ! -f "$TARGET_BASE/certbot/etc/letsencrypt/renewal/${DOMAINS[0]}.conf" ]; then
    echo "[!] No renewal config found. Running initial certificate requests..."
    
    for DOMAIN in "${DOMAINS[@]}"; do
        echo "[*] Requesting certificate for: $DOMAIN"
        
        # Clean artifacts to ensure fresh lineage
        rm -rf "$TARGET_BASE/certbot/etc/letsencrypt/live/$DOMAIN"
        rm -rf "$TARGET_BASE/certbot/etc/letsencrypt/archive/$DOMAIN"
        rm -f "$TARGET_BASE/certbot/etc/letsencrypt/renewal/$DOMAIN.conf"
        
        # Run Certbot: No plugin flags here! They are pulled from cli.ini/rfc2136.ini
        docker compose -f "$COMPOSE_FILE" run --rm \
            --entrypoint certbot \
            -e REQUESTS_CA_BUNDLE=/etc/letsencrypt/root_ca.crt \
            certbot \
            certonly --non-interactive --force-renewal \
            --deploy-hook "/etc/letsencrypt/renewal-hooks/deploy/cert-update.sh" \
            -d "$DOMAIN"
    done
    
    # 6. Ensure ACLs are set (fallback in case cert-relay had a timing issue during initial issuance)
    echo "[*] Setting certificate ACLs..."
    LETSE="$TARGET_BASE/certbot/etc/letsencrypt"
    for DOMAIN in "${DOMAINS[@]}"; do
        setfacl -m  u:2000:rX "$LETSE/live/$DOMAIN"
        setfacl -R -m u:2000:rX "$LETSE/archive/$DOMAIN"
    done
    setfacl -m  u:2700:rX "$LETSE/live/adguard.internal"
    setfacl -R -m u:2700:rX "$LETSE/archive/adguard.internal"
    setfacl -m  u:2003:rX "$LETSE/live/ldap.internal"
    setfacl -R -m u:2003:rX "$LETSE/archive/ldap.internal"

    # 7. Resume background loop and reload Nginx
    echo "[*] Starting Certbot renewal loop..."
    docker compose -f "$COMPOSE_FILE" up -d certbot
    
    echo "[*] Reloading Nginx..."
    docker exec --workdir / nginx nginx -s reload 2>/dev/null || true
else
    echo "[*] Renewal config exists for ${DOMAINS[0]}. Skipping initial bootstrap."
    docker compose -f "$COMPOSE_FILE" up -d certbot
fi

# 7. Final Verification
echo -n "[*] Verifying certificate validity..."
sleep 2
if docker exec certbot certbot certificates 2>/dev/null | grep -q "Expiry Date:"; then
    echo " [SUCCESS]"
else
    echo " [FAILED]"
    exit 1
fi


# --- 9. Cleanup and Exit ---
echo "[*] Shutting down bootstrap stack..."
docker compose -f "$COMPOSE_FILE" down
docker ps -q --filter "ancestor=smallstep/step-ca:latest" | xargs -r docker stop 2>/dev/null || true

echo "-------------------------------------------------------"
echo "INSTALLATION COMPLETE"
echo "-------------------------------------------------------"
