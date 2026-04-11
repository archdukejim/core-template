#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------
# upgrade.sh — Perform in-place feature upgrades on core-template
#
# Flags:
#   --add-ldap          Perform an in-place upgrade to include OpenLDAP
#   --target <ip>       Run against a remote host (default: localhost)
#   --ssh-user <user>   SSH username for remote targets (prompts if not set)
#   --apply             Apply without interactive prompting
# -----------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$SCRIPT_DIR/core"
PLAYBOOKS_DIR="$CORE_DIR/playbooks"
CUSTOM_VARS_FILE="$SCRIPT_DIR/custom-vars.yaml"

source "$CORE_DIR/lib/output.sh"
source "$CORE_DIR/lib/ssh.sh"
source "$CORE_DIR/lib/ansible.sh"

TARGET="localhost"
SSH_USER="${SUDO_USER:-}"
_SSH_READY=false
MODE=""
SUB_MODE="interactive"

ARGS=("$@")
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)      echo "Usage: ./upgrade.sh --add-ldap [--target IP] [--apply]"; exit 0 ;;
        --add-ldap)     MODE="add-ldap"; shift ;;
        --target)       TARGET="$2"; shift 2 ;;
        --ssh-user)     SSH_USER="$2"; shift 2 ;;
        --apply)        SUB_MODE="apply"; shift ;;
        *)              shift ;;
    esac
done

if [ -z "$MODE" ]; then
    err "No upgrade mode specified. Try: ./upgrade.sh --add-ldap"
    exit 1
fi

run_upgrade_playbook() {
    local playbook="$1"
    shift
    local extra=("$@")
    
    export ANSIBLE_CONFIG="$PLAYBOOKS_DIR/ansible.cfg"
    local conn_args=()
    local become_args=()

    if [ "$TARGET" = "localhost" ] || [ "$TARGET" = "127.0.0.1" ]; then
        conn_args=(--connection=local)
    else
        if ! $_SSH_READY; then
            ensure_ssh_access "$TARGET"
            _SSH_READY=true
        fi
        if [ "${SSH_USER}" != "root" ]; then
            become_args=(--ask-become-pass)
        fi
    fi

    ansible-playbook "$playbook" \
        -e "target_host=${TARGET}" \
        -e "ansible_user=${SSH_USER:-root}" \
        -i "${TARGET}," \
        "${conn_args[@]+"${conn_args[@]}"}" \
        "${become_args[@]+"${become_args[@]}"}" \
        "${extra[@]+"${extra[@]}"}"
}

do_add_ldap() {
    echo -e "${BOLD}core-template upgrade: Add LDAP${NC}"
    info "Target: ${TARGET}"
    echo ""

    if [ "$SUB_MODE" != "apply" ]; then
        warn "This will perform an in-place upgrade to install and start OpenLDAP."
        read -rp "Proceed with upgrade? [y/N] " choice
        [[ "$choice" =~ ^[yY] ]] || { info "Cancelled."; exit 0; }
    fi

    info "Running LDAP upgrade playbook..."
    # We pass install_ldap=true and limit execution using the add-ldap tag
    run_upgrade_playbook "$PLAYBOOKS_DIR/upgrade/add-ldap.yml" \
        --tags "add-ldap" \
        -e "install_ldap=true"
        
    echo ""
    ok "LDAP upgrade complete. Services have been updated."
}

case "$MODE" in
    add-ldap) do_add_ldap ;;
esac
