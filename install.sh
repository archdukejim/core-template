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
echo "[*] Creating service users and copying files..."
declare -A services=( ["nginx"]="2000" ["bind"]="2001" ["step"]="2002" ["ldap"]="2003" ["certbot"]="2004" ["adguard"]="2700" )

for user in "${!services[@]}"; do
    id -u "$user" &>/dev/null || groupadd -g "${services[$user]}" "$user" && useradd -u "${services[$user]}" -g "${services[$user]}" -s /usr/sbin/nologin -r "$user"
done

mkdir -p "$TARGET_BASE"
cp -r "$REPO_SOURCE/nginx" "$TARGET_BASE/"
cp -r "$REPO_SOURCE/adguardhome" "$TARGET_BASE/"
cp -r "$REPO_SOURCE/bind9" "$TARGET_BASE/"
cp -r "$REPO_SOURCE/step-ca" "$TARGET_BASE/stepca"
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

# --- 5. Bootstrapping PKI (EasyRSA & Step-CA) ---
echo "[*] Generating Root CA via EasyRSA..."
# Note: Assumes sign-certs.sh is configured to handle the --generate-rootca flag
bash "$TARGET_BASE/easyrsa/sign-certs.sh" --generate-rootca

echo "[*] Initializing Step-CA and Intermediate CSR..."
bash "$TARGET_BASE/stepca/stepca-firstboot.sh"

# --- 6. Prepare BIND9 Dummies ---
echo "[*] Preparing BIND9 for first boot..."
# This handles the circular dependency where BIND needs certs to start, but Certbot needs BIND to get certs.
CERT_DIR="$TARGET_BASE/certbot/etc/letsencrypt/live/dns.internal"
mkdir -p "$CERT_DIR"
if [ ! -f "$CERT_DIR/privkey.pem" ]; then
    openssl req -x509 -newkey rsa:2048 -keyout "$CERT_DIR/privkey.pem" -out "$CERT_DIR/fullchain.pem" \
        -days 1 -nodes -subj "/CN=temporary-dns-placeholder"
    chown -R 2001:2001 "$CERT_DIR"
fi

# --- 7. Finalize Hooks ---
# Ensure the deployment hook is executable
chmod +x "$TARGET_BASE/certbot/hooks/cert-update.sh"

# --- 8. Cleanup and Exit ---
echo "[*] Environment prepared."
echo "[*] Cleaning up temporary containers..."
docker ps -q --filter "name=step-ca" | xargs -r docker stop

echo "-------------------------------------------------------"
echo "DONE! You can now run: docker compose up -d"
echo "Check /etc/letsencrypt for initial dummy certs."
echo "-------------------------------------------------------"
