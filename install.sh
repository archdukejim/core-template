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
read -p "Enter source path [$HOME/home-core]: " REPO_SOURCE
REPO_SOURCE=${REPO_SOURCE:-$HOME/home-core}

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
declare -A services=( ["nginx"]="2000" ["bind"]="2001" ["step"]="2002" ["ldap"]="2003" ["certbot"]="2004" ["adguard"]="2700" )

for user in "${!services[@]}"; do
    TARGET_ID="${services[$user]}"
    
    if id "$user" &>/dev/null; then
        EXISTING_UID=$(id -u "$user")
        EXISTING_GID=$(id -g "$user")
        
        if [[ "$EXISTING_UID" != "$TARGET_ID" || "$EXISTING_GID" != "$TARGET_ID" ]]; then
            echo "ERROR: User '$user' already exists but with UID:GID $EXISTING_UID:$EXISTING_GID."
            echo "This script requires $user to have $TARGET_ID:$TARGET_ID. Please fix manually and rerun."
            exit 1
        fi
        echo "[*] User '$user' already exists with correct ID ($TARGET_ID). Skipping creation."
    else
        # Create group and user with matching IDs
        groupadd -g "$TARGET_ID" "$user"
        useradd -u "$TARGET_ID" -g "$TARGET_ID" -s /usr/sbin/nologin -r "$user"
        echo "[+] Created user '$user' with ID $TARGET_ID."
    fi
done

# Rest of your script follows...
mkdir -p "$TARGET_BASE"

mkdir -p "$TARGET_BASE"
cp -r "$REPO_SOURCE/nginx" "$TARGET_BASE/"
cp -r "$REPO_SOURCE/adguardhome" "$TARGET_BASE/"
cp -r "$REPO_SOURCE/bind9" "$TARGET_BASE/"
cp -r "$REPO_SOURCE/stepca" "$TARGET_BASE/stepca"
cp -r "$REPO_SOURCE/openldap" "$TARGET_BASE/"
cp -r "$REPO_SOURCE/certbot" "$TARGET_BASE/"
cp -r "$REPO_SOURCE/easyrsa" "$TARGET_BASE/"

# Set Permissions
chown -R 2000:2000 "$TARGET_BASE/nginx"
chown -R 2700:2700 "$TARGET_BASE/adguardhome"
chown -R 2001:2001 "$TARGET_BASE/bind9"
chown -R 2002:2002 "$TARGET_BASE/stepca"
chown -R 2003:2003 "$TARGET_BASE/openldap"
chown -R 2004:2004 "$TARGET_BASE/certbot"

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
openssl verify -CAfile /opt/stepca/data/certs/root_ca.crt /opt/stepca/data/certs/intermediate_ca.crt

echo "[+] Step-CA setup complete."

# --- 6. Prepare BIND9 (TSIG Keys & Dummy Certs) ---
echo "[*] Preparing BIND9 (Internal Port 5353)..."
BIND_CONTAINER_IP="172.30.255.53" 
BIND_KEY_FILE="$TARGET_BASE/bind9/config/named.conf.keys"
CERTBOT_INI_FILE="$TARGET_BASE/certbot/etc/letsencrypt/rfc2136.ini"

SECRET=$(openssl rand -base64 32)

mkdir -p "$(dirname "$BIND_KEY_FILE")"
cat <<EOF > "$BIND_KEY_FILE"
key "acme_dns-01" {
    algorithm hmac-sha256;
    secret "$SECRET";
};
EOF

mkdir -p "$(dirname "$CERTBOT_INI_FILE")"
cat <<EOF > "$CERTBOT_INI_FILE"
dns_rfc2136_server = $BIND_CONTAINER_IP
dns_rfc2136_port = 5353
dns_rfc2136_name = acme_dns-01
dns_rfc2136_secret = $SECRET
dns_rfc2136_algorithm = HMAC-SHA256
EOF

CERT_DIR="$TARGET_BASE/certbot/etc/letsencrypt/live/dns.internal"
if [ ! -f "$CERT_DIR/privkey.pem" ]; then
    echo "[*] Generating dummy SSL certs for BIND9..."
    mkdir -p "$CERT_DIR"
    openssl req -x509 -newkey rsa:2048 -keyout "$CERT_DIR/privkey.pem" -out "$CERT_DIR/fullchain.pem" \
        -days 1 -nodes -subj "/CN=temporary-dns-placeholder"
fi

chown 2001:2001 "$BIND_KEY_FILE"
chown -R 2001:2001 "$CERT_DIR"
chown 2004:2004 "$CERTBOT_INI_FILE"
chmod 640 "$BIND_KEY_FILE"
chmod 600 "$CERTBOT_INI_FILE"

echo "Check $TARGET_BASE/certbot/etc/letsencrypt for initial dummy certs."

# --- 7. Finalize Hooks ---
# Ensure the deployment hook is executable
chmod +x "$TARGET_BASE/certbot/hooks/cert-update.sh"

# --- 8. Cleanup and Exit ---
echo "[*] Environment prepared."
echo "[*] Cleaning up temporary and leftover containers..."

# 1. Stop by Name
docker stop nginx adguard certbot stepca openldap bind9 2>/dev/null || true

# 2. Stop any "orphans" created by the smallstep image during init
docker ps -q --filter "ancestor=smallstep/step-ca:latest" | xargs -r docker stop 2>/dev/null || true

echo "-------------------------------------------------------"
echo "DONE! You can now run: docker compose up -d"
echo "-------------------------------------------------------"
