#!/bin/bash

# 1. Extract the target_host value
TARGET=$(grep 'target_host:' target-vars.yml | awk '{print $2}' | tr -d '"' | tr -d "'")

if [ -z "$TARGET" ]; then
    echo "Error: Could not find target_host in target-vars.yml"
    exit 1
fi

echo "[*] Target found: $TARGET"
echo "[*] Running Ansible with extra args: $@"

# 2. Run Ansible
# -e passes the variable
# -i treats the string as a host list (the comma is key for single IPs)
# "$@" passes through any flags you added (like --tags, --check, -v)
ansible-playbook playbook.yml -e "target_host=$TARGET" -i "$TARGET," "$@"
