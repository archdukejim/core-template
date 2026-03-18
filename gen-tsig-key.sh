#!/bin/bash
# FIPS-Compliant TSIG Generator (HMAC-SHA256)

KEY_NAME="acme_dns-01"
BIND_KEY_FILE="/opt/bind9/config/named.conf.keys"
CERTBOT_KEY_FILE="/opt/certbot/config/tsig.key" # Adjust to your certbot path

# 1. Generate a 32-byte (256-bit) Base64 secret using OpenSSL
SECRET=$(openssl rand -base64 32)

# 2. Generate the BIND configuration block
cat <<EOF > "$BIND_KEY_FILE"
key "$KEY_NAME" {
    algorithm hmac-sha256;
    secret "$SECRET";
};
EOF

# 3. Generate a version for Certbot (usually just the secret or a credential file)
# Most Certbot DNS plugins (like RFC2136) prefer a simple ini-style format:
cat <<EOF > "$CERTBOT_KEY_FILE"
dns_rfc2136_name = $KEY_NAME
dns_rfc2136_secret = $SECRET
dns_rfc2136_algorithm = HMAC-SHA256
EOF

# 4. Set secure permissions
chown 2001:2001 "$BIND_KEY_FILE"
chmod 640 "$BIND_KEY_FILE"
chmod 600 "$CERTBOT_KEY_FILE"

echo "Keys generated and synced to BIND and Certbot directories."
