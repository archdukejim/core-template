#!/bin/bash
set -e

# --- Configuration ---
DNS_CHECK_DOMAIN="google.com"  # The domain used to verify resolution

# --- 0. Network Preconditioning (Critical for Repo Resolution) ---
# Extract the DNS server from your Ansible vars file
DNS_SERVER=$(grep 'dns_server:' core-setup-vars.yml | awk '{print $2}' | tr -d '"' | tr -d "'")
DNS_SERVER=${DNS_SERVER:-"1.1.1.1"} # Fallback if vars file is unreadable

echo "[*] Ensuring DNS resolution via $DNS_SERVER..."

if [ ! -f "/etc/systemd/resolved.conf.d/adguard-bind.conf" ]; then
    echo "[*] Fixing DNS resolution (systemd-resolved)..."
    sudo mkdir -p /etc/systemd/resolved.conf.d/
    sudo tee /etc/systemd/resolved.conf.d/adguard-bind.conf > /dev/null <<EOF
[Resolve]
DNS=$DNS_SERVER
DNSStubListener=no
EOF
    sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    sudo systemctl restart systemd-resolved
fi

# --- 0.5. DNS Resolution Verification ---
echo "[*] Verifying resolution for $DNS_CHECK_DOMAIN..."
if ! host "$DNS_CHECK_DOMAIN" > /dev/null 2>&1; then
    echo "[!] DNS resolution failed. Retrying in 5 seconds..."
    sleep 5
    if ! host "$DNS_CHECK_DOMAIN" > /dev/null 2>&1; then
        echo "[CRITICAL] Unable to resolve $DNS_CHECK_DOMAIN. Check your network or $DNS_SERVER."
        exit 1
    fi
fi
echo "[+] DNS resolution verified."

# --- 1. Install Ansible via Official PPA ---
if ! command -v ansible-playbook &> /dev/null; then
    echo "[*] Installing Ansible via official PPA..."
    sudo apt update
    sudo apt install -y software-properties-common
    sudo add-apt-repository --yes --update ppa:ansible/ansible
    sudo apt install -y ansible
fi

# --- 2. Install Required Collections ---
echo "[*] Ensuring Ansible collections are present..."
ansible-galaxy collection install community.docker

# --- 3. Execute Playbook ---
TARGET=$(grep 'target_host:' core-target-vars.yml | awk '{print $2}' | tr -d '"' | tr -d "'")
echo "[*] Launching Ansible Playbook for target: $TARGET"
ansible-playbook core-setup-playbook.yml -e "target_host=$TARGET" -i "$TARGET," "$@"
