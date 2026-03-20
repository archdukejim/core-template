#!/bin/bash
# FIPS-Compliant TSIG & Certbot Config Generator (HMAC-SHA256)

# Configuration
KEY_NAME="acme_dns-01"
BIND_KEY_FILE="/opt/bind9/config/named.conf.keys"
CERTBOT_INI_FILE="/opt/certbot/etc/letsencrypt/rfc2136.ini"
DNS_SERVER_IP="192.168.4.30" # Update this to your BIND container's IP
DNS_SERVER_PORT="5353"

# Ensure directories exist
mkdir -p "$(dirname "$BIND_KEY_FILE")"
mkdir -p "$(dirname "$CERTBOT_INI_FILE")"

# 1. Generate a 32-byte (256-bit) Base64 secret using OpenSSL
SECRET=$(openssl rand -base64 32)

# 2. Generate the BIND configuration block (named.conf.keys)
cat <<EOF > "$BIND_KEY_FILE"
key "$KEY_NAME" {
    algorithm hmac-sha256;
    secret "$SECRET";
};
EOF

# 3. Generate the Certbot RFC2136 configuration file
cat <<EOF > "$CERTBOT_INI_FILE"
# Target DNS server info
dns_rfc2136_server = $DNS_SERVER_IP
dns_rfc2136_port = $DNS_SERVER_PORT

# TSIG key credentials
dns_rfc2136_name = $KEY_NAME
dns_rfc2136_secret = $SECRET
dns_rfc2136_algorithm = HMAC-SHA256
EOF

# 4. Set secure permissions
# BIND (UID 2001) needs to read the key file
chown 2001:2001 "$BIND_KEY_FILE"
chmod 640 "$BIND_KEY_FILE"

# Certbot (UID 2004) needs to read the ini file
chown 2004:2004 "$CERTBOT_INI_FILE"
chmod 600 "$CERTBOT_INI_FILE"

echo "[+] TSIG Keys generated."
echo "[+] BIND config: $BIND_KEY_FILE"
echo "[+] Certbot config: $CERTBOT_INI_FILE"
