#!/bin/bash
# SSH helpers — source this file, do not execute directly.

# Prepare SSH access to a remote host:
#   1. Prompt for SSH_USER if not already set
#   2. Generate a local keypair if none exists
#   3. Add the remote host key to known_hosts (first-time trust)
#   4. Copy the public key to the remote (prompts for password if not yet authorized)
ensure_ssh_access() {
    local target="$1"

    if [ -z "$SSH_USER" ]; then
        read -rp "SSH username for ${target}: " SSH_USER
        [ -z "$SSH_USER" ] && { err "SSH username is required for remote targets."; exit 1; }
    fi

    mkdir -p ~/.ssh && chmod 700 ~/.ssh

    if ! ls ~/.ssh/id_*.pub &>/dev/null 2>&1; then
        info "No SSH keypair found — generating ed25519 key..."
        ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -C "core-template@$(hostname)"
        ok "SSH keypair generated: ~/.ssh/id_ed25519"
    fi

    if ! ssh-keygen -F "$target" &>/dev/null; then
        info "Scanning SSH host key for ${target}..."
        ssh-keyscan -H "$target" >> ~/.ssh/known_hosts 2>/dev/null || true
        ok "Host key added to known_hosts."
    fi

    info "Authorizing SSH key on ${SSH_USER}@${target} (enter remote password if prompted)..."
    if ssh-copy-id "${SSH_USER}@${target}"; then
        ok "SSH key authorized on ${target}."
    else
        err "Failed to authorize SSH key on ${SSH_USER}@${target}."
        exit 1
    fi
}
