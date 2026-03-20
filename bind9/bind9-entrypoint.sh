# Define your paths
CERT_DIR="/etc/letsencrypt/live/dns.internal"
KEY="$CERT_DIR/privkey.pem"
CERT="$CERT_DIR/fullchain.pem"

# Create the directory if it doesn't exist
mkdir -p "$CERT_DIR"

# Generate dummy certs only if they are missing
if [ ! -f "$KEY" ] || [ ! -f "$CERT" ]; then
    echo "Certificates not found. Generating dummies to allow BIND9 to start..."
    openssl req -x509 -newkey rsa:2048 -keyout "$KEY" -out "$CERT" \
        -days 1 -nodes -subj "/CN=temporary-dns-placeholder"
    
    # Ensure BIND can read them (nominal user is 'bind' or UID 101)
    chown -R 2001:2001 "$CERT_DIR" 
fi