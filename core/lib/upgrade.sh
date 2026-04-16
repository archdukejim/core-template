#!/bin/bash
# -----------------------------------------------------------------------
# upgrade.sh — Perform in-place feature upgrades on core-template
# -----------------------------------------------------------------------

do_upgrade() {
    echo -e "${BOLD}core-template upgrade${NC}"
    info "Target: ${TARGET}"
    if $OFFLINE; then
        info "Mode: Offline (Will fail if images missing)"
    fi
    echo ""

    if [ "$SUB_MODE" != "apply" ]; then
        if [ "$MODE_UPGRADE_ONLY_EXISTING" = "true" ]; then
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
    if [ "$MODE_UPGRADE_ONLY_EXISTING" = "true" ]; then
        if $ADD_LDAP; then
            extra_vars+=(-e "install_ldap=true")
        else
            extra_vars+=(-e "install_ldap=false")
        fi
    else
        # Full mode defaults to adding all new features.
        extra_vars+=(-e "install_ldap=true")
    fi

    run_playbook "$PLAYBOOKS_DIR/upgrade.yml" "${extra_vars[@]+"${extra_vars[@]}"}"
    
    if $ADD_LDAP || [ "$MODE_UPGRADE_ONLY_EXISTING" != "true" ]; then
        info "Running LDAP validation..."
        run_playbook "$PLAYBOOKS_DIR/07-validate-ldap.yml"
    fi
        
    echo ""
    ok "Upgrade complete. Stack is up to date."
}
