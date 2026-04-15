#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------
# upgrade.sh — Perform in-place feature upgrades on core-template
#
# Flags:
#   --only-existing     Only upgrade existing images/tools. Do not add new automated features.
#   --add-ldap          Perform an in-place upgrade to include OpenLDAP explicitly.
#   --target <ip>       Run against a remote host (default: localhost)
#   --ssh-user <user>   SSH username for remote targets (prompts if not set)
#   --offline           Skip external pulling on host, fails if images missing.
#   --apply             Apply without interactive prompting
# -----------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$SCRIPT_DIR/core"
PLAYBOOKS_DIR="$CORE_DIR/playbooks"
CUSTOM_VARS_FILE="$SCRIPT_DIR/custom-vars.yaml"

source "$CORE_DIR/lib/output.sh"
source "$CORE_DIR/lib/ssh.sh"
source "$CORE_DIR/lib/services.sh"

TARGET="localhost"
SSH_USER="${SUDO_USER:-}"
_SSH_READY=false
MODE="all"
SUB_MODE="interactive"
OFFLINE=false
ADD_LDAP=false

ARGS=("$@")
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)      echo "Usage: ./upgrade.sh [--only-existing | --add-ldap] [--target IP] [--offline] [--apply]"; exit 0 ;;
        --only-existing) MODE="existing"; shift ;;
        --add-ldap)     ADD_LDAP=true; shift ;;
        --offline)      OFFLINE=true; shift ;;
        --target)       TARGET="$2"; shift 2 ;;
        --ssh-user)     SSH_USER="$2"; shift 2 ;;
        --apply)        SUB_MODE="apply"; shift ;;
        *)              shift ;;
    esac
done

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

do_upgrade() {
    echo -e "${BOLD}core-template upgrade${NC}"
    info "Target: ${TARGET}"
    if $OFFLINE; then
        info "Mode: Offline (Will fail if images missing)"
    fi
    echo ""

    if [ "$SUB_MODE" != "apply" ]; then
        if [ "$MODE" = "existing" ]; then
            warn "This will perform an in-place upgrade of EXISTING features only."
        else
            warn "This will perform a full upgrade including all new default features."
        fi
        if $ADD_LDAP; then
            info "OpenLDAP will be explicitly included in this upgrade."
        fi
        read -rp "Proceed with upgrade? [y/N] " choice
        [[ "$choice" =~ ^[yY] ]] || { info "Cancelled."; exit 0; }
    fi

    info "Running upgrade playbook..."
    
    local extra_vars=()
    
    if $OFFLINE; then
        extra_vars+=(-e "offline=true")
    fi

    # Determine LDAP status
    if [ "$MODE" = "existing" ]; then
        # Default behavior for only-existing is to leave it to the vars already mapped on target
        # HOWEVER, we pass install_ldap=false during rendering so that it doesn't ADD it if it's new.
        # But wait – what if it IS installed? It's captured in old_vars, so we do not pass anything
        # and let the user's config remain?
        # Actually, adding LDAP is gated by 'install_ldap'. If we explicitly added it before via flag,
        # does it matter during fresh render?
        # Yes, we pass -e install_ldap=true if $ADD_LDAP is true.
        if $ADD_LDAP; then
            extra_vars+=(-e "install_ldap=true")
        else
            extra_vars+=(-e "install_ldap=false")
        fi
    else
        # Full mode defaults to adding all new features.
        extra_vars+=(-e "install_ldap=true")
    fi

    run_upgrade_playbook "$PLAYBOOKS_DIR/upgrade.yml" "${extra_vars[@]+"${extra_vars[@]}"}"
        
    echo ""
    ok "Upgrade complete. Stack is up to date."
}

do_upgrade
