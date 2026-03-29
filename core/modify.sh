#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------
# modify.sh — Live configuration modifications for a running home-core
#
# Modes:
#   --tsig-keys    Add a TSIG key to vars.yaml and reload BIND9.
#   --list-tsig    List all active TSIG keys and grants from live BIND9 config.
#   --remove-tsig  Remove a TSIG key and its grants from live BIND9 config.
#   --mint-certs   Mint a certificate (offline or ACME) and save to vars.yaml.
#   --dns-record   Add a DNS record to vars.yaml and reload BIND9.
#
# Common flags:
#   --target <ip>   Run against a remote host (default: localhost)
#   --apply         Apply without interactive prompting (uses existing vars.yaml)
#
# Examples:
#   sudo ./modify.sh --tsig-keys                  # Interactive: add a TSIG key
#   sudo ./modify.sh --tsig-keys --apply          # Non-interactive: apply tsig_extra_keys from vars.yaml
#   sudo ./modify.sh --list-tsig                  # Show all active TSIG keys and grants
#   sudo ./modify.sh --remove-tsig acme_npm       # Remove a TSIG key by name
#   sudo ./modify.sh --mint-certs                 # Interactive: mint a certificate
#   sudo ./modify.sh --mint-certs --apply         # Non-interactive: mint all mint_certs from vars.yaml
#   sudo ./modify.sh --dns-record                 # Interactive: add a DNS record
#   sudo ./modify.sh --dns-record --apply         # Non-interactive: re-render zones and reload BIND9
#   sudo ./modify.sh --tsig-keys --target 192.168.1.5   # Modify a remote host
# -----------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$SCRIPT_DIR"

# shellcheck source=version.sh
source "$CORE_DIR/version.sh"

# --- Defaults ---
TARGET_BASE="/opt"
TARGET="localhost"
MODE=""
SUB_MODE="interactive"   # interactive | apply
REMOVE_TSIG_KEY=""

ARCHIVE_DIR="$TARGET_BASE/core/archive"

# --- Output helpers ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${CYAN}[*]${NC} $*"; }
ok()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*"; }

usage() {
    sed -n '3,/^# ---/{ /^# ---/d; s/^# \?//p }' "$0"
    exit 0
}

# --- Parse arguments ---
ARGS=("$@")
# Pass 1: extract mode
for arg in "${ARGS[@]}"; do
    case "$arg" in
        --tsig-keys)   MODE="tsig-keys" ;;
        --list-tsig)   MODE="list-tsig" ;;
        --remove-tsig) MODE="remove-tsig" ;;
        --mint-certs)  MODE="mint-certs" ;;
        --dns-record)  MODE="dns-record" ;;
    esac
done

if [ -z "$MODE" ]; then
    err "No mode specified."
    echo ""
    usage
fi

# Pass 2: parse flags
set -- "${ARGS[@]}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)    usage ;;
        --tsig-keys|--list-tsig|--mint-certs|--dns-record)  shift ;;  # already handled
        --remove-tsig)  REMOVE_TSIG_KEY="${2:-}"; shift; [ -n "$REMOVE_TSIG_KEY" ] && shift || true ;;
        --target)   TARGET="$2"; shift 2 ;;
        --apply)    SUB_MODE="apply"; shift ;;
        *)          err "Unknown flag: $1"; exit 1 ;;
    esac
done

# -----------------------------------------------------------------------
# Run the Ansible playbook (subset of tags only — no full install)
# -----------------------------------------------------------------------
run_playbook() {
    export ANSIBLE_CONFIG="$CORE_DIR/ansible.cfg"
    local tag_args=()
    local conn_args=()

    if [ -n "$ANSIBLE_TAGS" ]; then
        tag_args=(--tags "$ANSIBLE_TAGS")
    fi

    if [ "$TARGET" = "localhost" ] || [ "$TARGET" = "127.0.0.1" ]; then
        conn_args=(--connection=local)
    fi

    ansible-playbook "$CORE_DIR/core-config.yml" \
        -e "target_host=${TARGET}" \
        -i "${TARGET}," \
        "${conn_args[@]+"${conn_args[@]}"}" \
        "${tag_args[@]+"${tag_args[@]}"}"
}

# -----------------------------------------------------------------------
# Helper: append an entry to a YAML list in vars.yaml
# Tries ruamel.yaml first (preserves comments), falls back to PyYAML
# Usage: _vars_list_append <key> <json_entry>
# -----------------------------------------------------------------------
_vars_list_append() {
    local key="$1" json_entry="$2"
    VARS_KEY="$key" VARS_ENTRY="$json_entry" VARS_FILE="$CORE_DIR/vars.yaml" \
    python3 - <<'PYEOF'
import json, os
key = os.environ['VARS_KEY']
entry = json.loads(os.environ['VARS_ENTRY'])
vars_file = os.environ['VARS_FILE']
try:
    from ruamel.yaml import YAML
    from ruamel.yaml.comments import CommentedSeq
    ry = YAML(); ry.preserve_quotes = True; ry.width = 4096
    with open(vars_file) as f: data = ry.load(f)
    lst = data.get(key)
    if not lst:
        data[key] = CommentedSeq([entry])
    else:
        lst.append(entry)
    with open(vars_file, 'w') as f: ry.dump(data, f)
    print("[+] vars.yaml updated (comments preserved)")
except ImportError:
    import yaml
    with open(vars_file) as f: data = yaml.safe_load(f)
    if not data.get(key): data[key] = []
    data[key].append(entry)
    with open(vars_file, 'w') as f:
        yaml.dump(data, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
    print("[!] vars.yaml updated (ruamel.yaml unavailable — comments may be reformatted)")
PYEOF
}

# -----------------------------------------------------------------------
# Helper: append a DNS record to the nested dns dict in vars.yaml
# Navigates: dns[zone][record_type] → list of records
# Usage: _vars_dns_record_append <zone> <record_type> <json_record>
# -----------------------------------------------------------------------
_vars_dns_record_append() {
    local zone="$1" rtype="$2" json_record="$3"
    VARS_ZONE="$zone" VARS_RTYPE="$rtype" VARS_RECORD="$json_record" VARS_FILE="$CORE_DIR/vars.yaml" \
    python3 - <<'PYEOF'
import json, os
zone      = os.environ['VARS_ZONE']
rtype     = os.environ['VARS_RTYPE']
record    = json.loads(os.environ['VARS_RECORD'])
vars_file = os.environ['VARS_FILE']
try:
    from ruamel.yaml import YAML
    from ruamel.yaml.comments import CommentedMap, CommentedSeq
    ry = YAML(); ry.preserve_quotes = True; ry.width = 4096
    with open(vars_file) as f: data = ry.load(f)
    dns = data.get('dns')
    if dns is None:
        data['dns'] = CommentedMap({zone: CommentedMap({rtype: CommentedSeq([record])})})
    else:
        if zone not in dns:
            dns[zone] = CommentedMap({rtype: CommentedSeq([record])})
        elif rtype not in dns[zone]:
            dns[zone][rtype] = CommentedSeq([record])
        else:
            dns[zone][rtype].append(record)
    with open(vars_file, 'w') as f: ry.dump(data, f)
    print("[+] vars.yaml updated (comments preserved)")
except ImportError:
    import yaml
    with open(vars_file) as f: data = yaml.safe_load(f)
    if 'dns' not in data or data['dns'] is None: data['dns'] = {}
    if zone not in data['dns']: data['dns'][zone] = {}
    if rtype not in data['dns'][zone]: data['dns'][zone][rtype] = []
    data['dns'][zone][rtype].append(record)
    with open(vars_file, 'w') as f:
        yaml.dump(data, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
    print("[!] vars.yaml updated (ruamel.yaml unavailable — comments may be reformatted)")
PYEOF
}

# -----------------------------------------------------------------------
# Helper: save a timestamped backup of vars.yaml before modifying it
# Backups stored in $ARCHIVE_DIR/vars/<timestamp>_<label>.yaml
# Usage: _vars_archive <label>
# -----------------------------------------------------------------------
_vars_archive() {
    local label="$1"
    local timestamp; timestamp="$(date -u '+%Y%m%d-%H%M%S')"
    local vars_archive_dir="$ARCHIVE_DIR/vars"
    mkdir -p "$vars_archive_dir"
    local backup="${vars_archive_dir}/${timestamp}_${label}.yaml"
    cp "$CORE_DIR/vars.yaml" "$backup"
    ok "vars.yaml backed up to ${backup}"
}

# -----------------------------------------------------------------------
# MODE: tsig-keys
# -----------------------------------------------------------------------
do_tsig_keys() {
    echo -e "${BOLD}home-core tsig-keys${NC}"
    echo ""

    if ! command -v ansible-playbook &>/dev/null; then
        err "ansible-playbook not found. Run setup.sh (install) first."; exit 1
    fi

    if [ "$SUB_MODE" = "apply" ]; then
        info "Applying tsig_extra_keys from vars.yaml..."
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

    local scopes=()
    echo "  Enter domains this key may issue certificates for (blank to finish):"
    while true; do
        local scope; read -rp "    Scope: " scope
        [ -z "$scope" ] && break
        scopes+=("$scope")
    done
    [ ${#scopes[@]} -gt 0 ] || { err "At least one scope is required."; exit 1; }

    local out_path
    read -rp "  Credentials output path [/opt/${key_name}/rfc2136.ini]: " out_path

    echo ""
    echo -e "  ${BOLD}Summary:${NC}"
    echo "    Key name:  $key_name"
    echo "    Scopes:"
    for s in "${scopes[@]}"; do echo "      - $s"; done
    [ -n "$out_path" ] && echo "    Output:    $out_path"
    echo ""
    local confirm; read -rp "  Add to vars.yaml and apply? [y/N] " confirm
    [[ "$confirm" =~ ^[yY] ]] || { info "Cancelled."; exit 0; }

    # Build JSON
    local scopes_json; scopes_json=$(printf '"%s",' "${scopes[@]}"); scopes_json="[${scopes_json%,}]"
    local json_entry="{\"name\":\"${key_name}\",\"scopes\":${scopes_json}}"
    [ -n "$out_path" ] && json_entry="{\"name\":\"${key_name}\",\"scopes\":${scopes_json},\"out\":\"${out_path}\"}"

    echo ""
    _vars_archive "tsig-keys_${key_name}"
    _vars_list_append "tsig_extra_keys" "$json_entry"
    echo ""

    info "Applying TSIG key..."
    echo ""
    ANSIBLE_TAGS="tsig-keys"
    run_playbook
    echo ""
    ok "TSIG key '${key_name}' applied."
}

# -----------------------------------------------------------------------
# MODE: list-tsig
# List all active TSIG keys and grants directly from the live BIND9 config
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
# MODE: remove-tsig
# Remove a TSIG key and all its grants from the live BIND9 config
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

# -----------------------------------------------------------------------
# MODE: mint-certs
# -----------------------------------------------------------------------
do_mint_certs() {
    echo -e "${BOLD}home-core mint-certs${NC}"
    echo ""

    if ! command -v ansible-playbook &>/dev/null; then
        err "ansible-playbook not found. Run setup.sh (install) first."; exit 1
    fi

    if [ "$SUB_MODE" = "apply" ]; then
        info "Minting certificates from vars.yaml..."
        echo ""
        ANSIBLE_TAGS="mint-certs"
        run_playbook
        echo ""
        ok "Certificate minting complete."
        return
    fi

    # --- Interactive ---
    info "Interactive certificate minting"
    echo ""

    local cn; read -rp "  Common Name (e.g. myservice.internal): " cn
    [ -n "$cn" ] || { err "Common Name is required."; exit 1; }

    local sans=()
    echo "  Additional SANs (blank to finish):"
    while true; do
        local san; read -rp "    SAN: " san
        [ -z "$san" ] && break
        sans+=("$san")
    done

    local renew=false; local renew_input
    read -rp "  Use ACME auto-renewal? [y/N]: " renew_input
    [[ "$renew_input" =~ ^[yY] ]] && renew=true

    local days="" out_dir="" portainer_webhook=""
    if [ "$renew" = false ]; then
        read -rp "  Validity in days [365]: " days; days="${days:-365}"
        read -rp "  Output directory [caller's home]: " out_dir
    else
        read -rp "  Portainer webhook URL (optional): " portainer_webhook
    fi

    echo ""
    echo -e "  ${BOLD}Summary:${NC}"
    echo "    CN:      $cn"
    [ ${#sans[@]} -gt 0 ] && { echo "    SANs:"; for s in "${sans[@]}"; do echo "      - $s"; done; }
    if [ "$renew" = true ]; then
        echo "    Mode:    ACME (auto-renewed)"
        [ -n "$portainer_webhook" ] && echo "    Webhook: $portainer_webhook"
    else
        echo "    Mode:    Offline (direct CA signing)"
        echo "    Days:    $days"
        [ -n "$out_dir" ] && echo "    Out dir: $out_dir"
    fi
    echo ""
    local confirm; read -rp "  Add to vars.yaml and mint? [y/N] " confirm
    [[ "$confirm" =~ ^[yY] ]] || { info "Cancelled."; exit 0; }

    # Build JSON
    local sans_json
    if [ ${#sans[@]} -gt 0 ]; then
        sans_json=$(printf '"%s",' "${sans[@]}"); sans_json="[${sans_json%,}]"
    else
        sans_json="[]"
    fi
    local json_entry="{\"cn\":\"${cn}\",\"sans\":${sans_json},\"renew\":${renew}"
    if [ "$renew" = false ]; then
        json_entry+=",\"days\":${days}"
        [ -n "$out_dir" ] && json_entry+=",\"out_dir\":\"${out_dir}\""
    else
        [ -n "$portainer_webhook" ] && json_entry+=",\"portainer_webhook\":\"${portainer_webhook}\""
    fi
    json_entry+="}"

    echo ""
    _vars_archive "mint-certs_${cn}"
    _vars_list_append "mint_certs" "$json_entry"
    echo ""

    info "Minting certificate..."
    echo ""
    ANSIBLE_TAGS="mint-certs"
    run_playbook
    echo ""
    ok "Certificate for '${cn}' minted."
}

# -----------------------------------------------------------------------
# MODE: dns-record
# -----------------------------------------------------------------------
do_dns_record() {
    echo -e "${BOLD}home-core dns-record${NC}"
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
    local confirm; read -rp "  Add to vars.yaml and reload BIND9? [y/N] " confirm
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

# -----------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------
case "$MODE" in
    tsig-keys)   do_tsig_keys ;;
    list-tsig)   do_list_tsig ;;
    remove-tsig) do_remove_tsig ;;
    mint-certs)  do_mint_certs ;;
    dns-record)  do_dns_record ;;
esac
