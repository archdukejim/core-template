#!/bin/bash
# TSIG key management — source this file, do not execute directly.

# -----------------------------------------------------------------------
# do_tsig_keys
# Interactive or --apply mode: add a TSIG key to custom-vars.yaml and
# apply it to the running BIND9 instance.
# -----------------------------------------------------------------------
do_tsig_keys() {
    echo -e "${BOLD}core-template tsig-keys${NC}"
    echo ""

    if ! command -v ansible-playbook &>/dev/null; then
        err "ansible-playbook not found. Run setup.sh (install) first."; exit 1
    fi

    if [ "$SUB_MODE" = "apply" ]; then
        info "Applying tsig_keys from custom-vars.yaml..."
        echo ""
        ANSIBLE_TAGS="tsig-keys"
        run_playbook
        echo ""
        ok "TSIG keys applied."
        return
    fi

    # --- Interactive ---
    info "Interactive TSIG key setup"
    echo ""

    local key_name
    read -rp "  Key name (e.g. acme_npm): " key_name
    [[ "$key_name" =~ ^[a-zA-Z0-9_-]+$ ]] || { err "Key name must be alphanumeric (with _ or -)."; exit 1; }

    local key_domain
    read -rp "  Domain (e.g. home): " key_domain
    [ -n "$key_domain" ] || { err "Domain is required."; exit 1; }

    local records=()
    echo "  Enter hostnames this key may issue certificates for (blank to finish):"
    while true; do
        local record; read -rp "    Hostname: " record
        [ -z "$record" ] && break
        records+=("$record")
    done
    [ ${#records[@]} -gt 0 ] || { err "At least one hostname is required."; exit 1; }

    local out_path
    read -rp "  Credentials output path [/opt/${key_name}/rfc2136.ini]: " out_path

    echo ""
    echo -e "  ${BOLD}Summary:${NC}"
    echo "    Key name:  $key_name"
    echo "    Domain:    $key_domain"
    echo "    Records:"
    for r in "${records[@]}"; do echo "      - ${r}.${key_domain}"; done
    [ -n "$out_path" ] && echo "    Output:    $out_path"
    echo ""
    local confirm; read -rp "  Add to custom-vars.yaml and apply? [y/N] " confirm
    [[ "$confirm" =~ ^[yY] ]] || { info "Cancelled."; exit 0; }

    # Build JSON
    local records_json; records_json=$(printf '"%s",' "${records[@]}"); records_json="[${records_json%,}]"
    local json_entry="{\"name\":\"${key_name}\",\"domain\":\"${key_domain}\",\"records\":${records_json}}"
    [ -n "$out_path" ] && json_entry="{\"name\":\"${key_name}\",\"domain\":\"${key_domain}\",\"records\":${records_json},\"out\":\"${out_path}\"}"

    echo ""
    _vars_archive "tsig-keys_${key_name}"
    _vars_list_append "tsig_keys" "$json_entry"
    echo ""

    info "Applying TSIG key..."
    echo ""
    ANSIBLE_TAGS="tsig-keys"
    run_playbook
    echo ""
    ok "TSIG key '${key_name}' applied."
}

# -----------------------------------------------------------------------
# do_list_tsig
# List all active TSIG keys and grants directly from the live BIND9 config.
# -----------------------------------------------------------------------
do_list_tsig() {
    local keys_file="$TARGET_BASE/bind9/config/named.conf.keys"
    local zones_file="$TARGET_BASE/bind9/config/named.conf.zones"

    [ -f "$keys_file" ]  || { err "Keys file not found: ${keys_file}"; exit 1; }
    [ -f "$zones_file" ] || { err "Zones file not found: ${zones_file}"; exit 1; }

    echo ""
    echo -e "${BOLD}TSIG Keys (${keys_file}):${NC}"
    grep -E '^key ' "$keys_file" | sed 's/key "\(.*\)".*/  \1/' || echo "  (none)"

    echo ""
    echo -e "${BOLD}Update-Policy Grants (${zones_file}):${NC}"
    grep -E '^\s*grant ' "$zones_file" | sed 's/^[[:space:]]*/  /' || echo "  (none)"
    echo ""
}

# -----------------------------------------------------------------------
# do_remove_tsig
# Remove a TSIG key and all its grants from the live BIND9 config.
# -----------------------------------------------------------------------
do_remove_tsig() {
    local keys_file="$TARGET_BASE/bind9/config/named.conf.keys"
    local zones_file="$TARGET_BASE/bind9/config/named.conf.zones"

    [ -f "$keys_file" ]  || { err "Keys file not found: ${keys_file}"; exit 1; }
    [ -f "$zones_file" ] || { err "Zones file not found: ${zones_file}"; exit 1; }

    local key_name="$REMOVE_TSIG_KEY"
    if [ -z "$key_name" ]; then
        echo ""
        do_list_tsig
        read -rp "  Key name to remove: " key_name
    fi

    [ -n "$key_name" ] || { err "Key name is required."; exit 1; }
    grep -q "key \"${key_name}\"" "$keys_file" || { err "Key '${key_name}' not found in ${keys_file}"; exit 1; }

    echo ""
    warn "This will permanently remove key '${key_name}' and all its ACME grants from BIND9."
    local confirm; read -rp "  Confirm? [y/N] " confirm
    [[ "$confirm" =~ ^[yY] ]] || { info "Cancelled."; exit 0; }

    # Remove key block (key "name" { ... };) from named.conf.keys
    sed -i "/^key \"${key_name}\"/,/^};/d" "$keys_file"
    ok "Key definition removed from ${keys_file}"

    # Remove all grant lines for this key from named.conf.zones
    local grant_count; grant_count=$(grep -c "grant \"${key_name}\"" "$zones_file" || true)
    if [ "$grant_count" -gt 0 ]; then
        sed -i "/grant \"${key_name}\"/d" "$zones_file"
        ok "Removed ${grant_count} grant(s) from ${zones_file}"
    fi

    # Reload BIND9
    info "Reloading BIND9..."
    docker exec bind9 rndc reload
    echo ""
    ok "Key '${key_name}' removed. BIND9 reloaded."
}
