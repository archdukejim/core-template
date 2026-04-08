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

    if [ "$SUB_MODE" = "apply" ]; then
        info "Re-rendering zone files and reloading BIND9..."
        echo ""
        run_dns_reload
        echo ""
        ok "DNS zones reloaded."
        return
    fi

    # --- Interactive ---
    info "Interactive DNS record setup"
    echo ""

    info "Available zones:"
    python3 -c "
import yaml, sys
with open('$CUSTOM_VARS_FILE') as f: d = yaml.safe_load(f)
domain = d.get('domain', '')
for k in (d.get('dns') or {}):
    label = domain if k == 'dynamic_zone_var' else k
    print(f'    - {k}  ({label})')
" 2>/dev/null || true
    echo ""
    local zone; read -rp "  Zone key [dynamic_zone_var]: " zone
    zone="${zone:-dynamic_zone_var}"

    echo "  Record type:"
    local types=("A" "AAAA" "CNAME" "MX" "TXT" "SRV")
    select rtype in "${types[@]}"; do
        [ -n "$rtype" ] && break
        err "Invalid selection."; exit 1
    done

    echo ""
    local json_record=""
    local ptr_info=""
    case "$rtype" in
        A|AAAA)
            local name ip
            read -rp "  Name (e.g. myhost): " name
            read -rp "  IP address: " ip
            [ -n "$name" ] && [ -n "$ip" ] || { err "Name and IP are required."; exit 1; }
            json_record="{\"name\":\"${name}\",\"ip\":\"${ip}\"}"
            if [[ "$rtype" == "A" && "$ip" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
                local domain_val rev_zone last_octet fwd_zone
                domain_val=$(python3 -c "import yaml; d=yaml.safe_load(open('$CUSTOM_VARS_FILE')); print(d.get('domain',''))")
                fwd_zone="${domain_val}"
                last_octet="${BASH_REMATCH[4]}"
                rev_zone="${BASH_REMATCH[3]}.${BASH_REMATCH[2]}.${BASH_REMATCH[1]}.in-addr.arpa"
                ptr_info="${last_octet}.${rev_zone} → ${name}.${fwd_zone}."
            fi
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
    [ -n "$ptr_info" ] && echo "    PTR:    $ptr_info  (auto-generated)"
    echo ""
    local confirm; read -rp "  Add to custom-vars.yaml and reload BIND9? [y/N] " confirm
    [[ "$confirm" =~ ^[yY] ]] || { info "Cancelled."; exit 0; }

    echo ""
    _vars_archive "dns-record_${zone}_${rtype}"
    _vars_dns_record_append "$zone" "$rtype" "$json_record"
    echo ""

    info "Applying DNS record..."
    echo ""
    run_dns_reload
    echo ""
    ok "${rtype} record added to zone '${zone}' and BIND9 reloaded."
}

# -----------------------------------------------------------------------
# do_remove_dns_record
# Interactive: read existing records from live vars.yaml, prompt user to
# pick one, remove it from custom-vars.yaml, re-render zone, reload BIND9.
# -----------------------------------------------------------------------
do_remove_dns_record() {
    echo -e "${BOLD}core-template remove-dns-record${NC}"
    echo ""

    local live_vars="${TARGET_BASE}/core/vars.yaml"
    [ -f "$live_vars" ] || { err "Live vars not found at ${live_vars}. Is core-template installed?"; exit 1; }

    # --- Show available zones ---
    info "Available zones (from live vars):"
    python3 -c "
import yaml, sys
with open('$live_vars') as f: d = yaml.safe_load(f)
for z in (d.get('dns') or {}): print('  -', z)
"
    echo ""
    local zone; read -rp "  Zone to remove record from: " zone
    [ -n "$zone" ] || { err "Zone is required."; exit 1; }

    # --- Prompt for record type ---
    echo "  Record type:"
    local types=("A" "AAAA" "CNAME" "MX" "TXT" "SRV")
    select rtype in "${types[@]}"; do
        [ -n "$rtype" ] && break
        err "Invalid selection."; exit 1
    done
    echo ""

    # --- List records of that type ---
    info "Existing ${rtype} records in zone '${zone}':"
    local records_out
    records_out=$(python3 -c "
import yaml, sys
with open('$live_vars') as f: d = yaml.safe_load(f)
recs = (d.get('dns') or {}).get('$zone', {}).get('$rtype', [])
if not recs: sys.exit(1)
for i, r in enumerate(recs, 1): print(f'  {i}) {r}')
" 2>/dev/null) || { err "No ${rtype} records found in zone '${zone}'."; exit 1; }
    echo "$records_out"
    echo ""

    local idx; read -rp "  Number to remove: " idx
    [[ "$idx" =~ ^[0-9]+$ ]] || { err "Must be a number."; exit 1; }

    # --- Resolve the record's name field ---
    local match_field="name"
    local match_value
    match_value=$(python3 -c "
import yaml, sys
with open('$live_vars') as f: d = yaml.safe_load(f)
recs = (d.get('dns') or {}).get('$zone', {}).get('$rtype', [])
idx = int('$idx') - 1
if idx < 0 or idx >= len(recs): sys.exit(1)
print(recs[idx].get('name', ''))
" 2>/dev/null) || { err "Invalid selection."; exit 1; }
    [ -n "$match_value" ] || { err "Could not determine record name for removal."; exit 1; }

    # For A records, look up the IP so we can show the PTR that will be removed
    local remove_ptr_info=""
    if [ "$rtype" = "A" ]; then
        local record_ip
        record_ip=$(python3 -c "
import yaml, sys
with open('$live_vars') as f: d = yaml.safe_load(f)
recs = (d.get('dns') or {}).get('$zone', {}).get('$rtype', [])
idx = int('$idx') - 1
print(recs[idx].get('ip', '') if 0 <= idx < len(recs) else '')
" 2>/dev/null)
        if [[ "$record_ip" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
            local domain_val rev_zone last_octet fwd_zone
            domain_val=$(python3 -c "
import yaml
with open('$live_vars') as f: d = yaml.safe_load(f)
print(d.get('domain', ''))
" 2>/dev/null)
            last_octet="${BASH_REMATCH[4]}"
            rev_zone="${BASH_REMATCH[3]}.${BASH_REMATCH[2]}.${BASH_REMATCH[1]}.in-addr.arpa"
            fwd_zone="${domain_val}"
            remove_ptr_info="${last_octet}.${rev_zone} → ${match_value}.${fwd_zone}."
        fi
    fi

    echo ""
    echo -e "  ${BOLD}Will remove:${NC}"
    echo "    Zone:   $zone"
    echo "    Type:   $rtype"
    echo "    Name:   $match_value"
    [ -n "$remove_ptr_info" ] && echo "    PTR:    $remove_ptr_info  (auto-removed)"
    echo ""
    local confirm; read -rp "  Remove from custom-vars.yaml and reload BIND9? [y/N] " confirm
    [[ "$confirm" =~ ^[yY] ]] || { info "Cancelled."; exit 0; }

    echo ""
    _vars_archive "remove-dns-record_${zone}_${rtype}_${match_value}"
    _vars_dns_record_remove "$zone" "$rtype" "$match_field" "$match_value"
    echo ""

    info "Re-rendering zone and reloading BIND9..."
    echo ""
    run_dns_reload
    echo ""
    ok "${rtype} record '${match_value}' removed from zone '${zone}' and BIND9 reloaded."
}
