#!/bin/bash
# DNS record management — source this file, do not execute directly.

# -----------------------------------------------------------------------
# do_dns_record
# Interactive or --apply mode: add a DNS record to custom-vars.yaml and
# reload the running BIND9 instance.
# -----------------------------------------------------------------------
do_dns_record() {
    echo -e "${BOLD}core-template dns-record${NC}"
    echo ""

    if ! command -v ansible-playbook &>/dev/null; then
        err "ansible-playbook not found. Run setup.sh (install) first."; exit 1
    fi

    if [ "$SUB_MODE" = "apply" ]; then
        info "Re-rendering zone files and reloading BIND9..."
        echo ""
        ANSIBLE_TAGS="dns-record"
        run_playbook
        echo ""
        ok "DNS zones reloaded."
        return
    fi

    # --- Interactive ---
    info "Interactive DNS record setup"
    echo ""

    local zone; read -rp "  Zone (e.g. internal): " zone
    [ -n "$zone" ] || { err "Zone is required."; exit 1; }

    echo "  Record type:"
    local types=("A" "AAAA" "CNAME" "MX" "TXT" "SRV")
    select rtype in "${types[@]}"; do
        [ -n "$rtype" ] && break
        err "Invalid selection."; exit 1
    done

    echo ""
    local json_record=""
    case "$rtype" in
        A|AAAA)
            local name ip
            read -rp "  Name (e.g. myhost): " name
            read -rp "  IP address: " ip
            [ -n "$name" ] && [ -n "$ip" ] || { err "Name and IP are required."; exit 1; }
            json_record="{\"name\":\"${name}\",\"ip\":\"${ip}\"}"
            ;;
        CNAME)
            local name canonical
            read -rp "  Name (e.g. myalias): " name
            read -rp "  Canonical target (e.g. myhost): " canonical
            [ -n "$name" ] && [ -n "$canonical" ] || { err "Name and canonical are required."; exit 1; }
            json_record="{\"name\":\"${name}\",\"canonical\":\"${canonical}\"}"
            ;;
        MX)
            local name priority exchange
            read -rp "  Name (usually @): " name; name="${name:-@}"
            read -rp "  Priority [10]: " priority; priority="${priority:-10}"
            read -rp "  Mail exchange (e.g. mail.internal): " exchange
            [ -n "$exchange" ] || { err "Mail exchange is required."; exit 1; }
            json_record="{\"name\":\"${name}\",\"priority\":${priority},\"exchange\":\"${exchange}\"}"
            ;;
        TXT)
            local name text
            read -rp "  Name (e.g. @ or _dmarc): " name
            read -rp "  Text value: " text
            [ -n "$name" ] && [ -n "$text" ] || { err "Name and text are required."; exit 1; }
            json_record="{\"name\":\"${name}\",\"text\":\"${text}\"}"
            ;;
        SRV)
            local name priority weight port target
            read -rp "  Service name (e.g. _sip._tcp): " name
            read -rp "  Priority [10]: " priority; priority="${priority:-10}"
            read -rp "  Weight [10]: " weight; weight="${weight:-10}"
            read -rp "  Port: " port
            read -rp "  Target hostname: " target
            [ -n "$name" ] && [ -n "$port" ] && [ -n "$target" ] || { err "Name, port, and target are required."; exit 1; }
            json_record="{\"name\":\"${name}\",\"priority\":${priority},\"weight\":${weight},\"port\":${port},\"target\":\"${target}\"}"
            ;;
    esac

    echo ""
    echo -e "  ${BOLD}Summary:${NC}"
    echo "    Zone:   $zone"
    echo "    Type:   $rtype"
    echo "    Record: $json_record"
    echo ""
    local confirm; read -rp "  Add to custom-vars.yaml and reload BIND9? [y/N] " confirm
    [[ "$confirm" =~ ^[yY] ]] || { info "Cancelled."; exit 0; }

    echo ""
    _vars_archive "dns-record_${zone}_${rtype}"
    _vars_dns_record_append "$zone" "$rtype" "$json_record"
    echo ""

    info "Applying DNS record..."
    echo ""
    ANSIBLE_TAGS="dns-record"
    run_playbook
    echo ""
    ok "${rtype} record added to zone '${zone}' and BIND9 reloaded."
}
