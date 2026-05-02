#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------
# manage.sh — Live configuration management for a running core-template
#
# Run this script ON the target machine (must be root / sudo).
#
# Modes:
#   --tsig-keys     Add a TSIG key to vars.yaml and reload BIND9.
#   --list-tsig     List all active TSIG keys and grants from live BIND9 config.
#   --remove-tsig   Remove a TSIG key and its grants from live BIND9 config.
#   --mint-certs    Mint an offline certificate and save to vars.yaml.
#                   --intermediate-ca [N]  Issue as a subordinate CA cert (pathLen=N, default 0).
#                                          pathLen=0: can sign leaf certs, cannot issue further CAs.
#   --service-cert  Re-issue core service TLS certs (dns, ldap, ca, certificates) via Step-CA.
#   --dns-record         Add a DNS record to vars.yaml and reload BIND9.
#   --remove-dns-record  Remove a DNS record from vars.yaml and reload BIND9.
#   --render-jinja <j2>  Render a Jinja2 template using core-template vars.
#
# Common flags:
#   --apply            Apply without interactive prompting (uses existing vars.yaml)
#   --vars <file>      Vars file to use for --render-jinja (default: /opt/core/vars.yaml)
#   --output <file>    Output destination for --render-jinja (default: non-root user's home directory)
#   --kty <type>       Key type for minted certs: RSA | EC | OKP  (default: RSA)
#   --size <bits>      Key size (RSA: 2048/3072/4096, EC: 256/384) (default: 4096)
#
# Examples:
#   sudo ./manage.sh --tsig-keys                  # Interactive: add a TSIG key
#   sudo ./manage.sh --tsig-keys --apply          # Non-interactive: apply tsig_keys from vars.yaml
#   sudo ./manage.sh --list-tsig                  # Show all active TSIG keys and grants
#   sudo ./manage.sh --remove-tsig acme_npm       # Remove a TSIG key by name
#   sudo ./manage.sh --mint-certs                              # Interactive: mint a leaf cert
#   sudo ./manage.sh --mint-certs --intermediate-ca            # Interactive: mint a subordinate CA (pathLen=0)
#   sudo ./manage.sh --mint-certs --intermediate-ca 1          # Subordinate CA that can sign one more CA level
#   sudo ./manage.sh --mint-certs --apply                      # Non-interactive: mint all extra_certs from vars.yaml
#   sudo ./manage.sh --service-cert               # Interactive: re-issue core service certs
#   sudo ./manage.sh --service-cert --apply       # Non-interactive: re-issue all core service certs
#   sudo ./manage.sh --dns-record                 # Interactive: add a DNS record
#   sudo ./manage.sh --dns-record --apply         # Non-interactive: re-render zones and reload BIND9
#   sudo ./manage.sh --remove-dns-record          # Interactive: pick and remove a DNS record
# -----------------------------------------------------------------------

# Resolve the actual script path even if invoked via a symlink
actual_script=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "${BASH_SOURCE[0]}")
SCRIPT_DIR="$(cd "$(dirname "$actual_script")" && pwd)"
CORE_DIR="$(dirname "$SCRIPT_DIR")"
PLAYBOOKS_DIR="$CORE_DIR/playbooks"
VARS_FILE="$CORE_DIR/config/vars.yaml"

# Source shared library modules
source "$CORE_DIR/lib/output.sh"
source "$CORE_DIR/lib/services.sh"
source "$CORE_DIR/lib/vars.sh"
source "$CORE_DIR/lib/tsig.sh"
source "$CORE_DIR/lib/certs.sh"
source "$CORE_DIR/lib/dns.sh"

# --- Globals ---
TARGET_BASE="$(dirname "$CORE_DIR")"
MODE=""
SUB_MODE="interactive"
REMOVE_TSIG_KEY=""
IS_CA=false
PATH_LEN=0
CERT_KTY="RSA"
CERT_SIZE="4096"
RENDER_TEMPLATE=""
RENDER_VARS=""
RENDER_OUTPUT=""

ARCHIVE_DIR="$TARGET_BASE/core/archive"

# --- Parse arguments ---
ARGS=("$@")

# Pass 1: extract mode
for arg in "${ARGS[@]}"; do
    case "$arg" in
        --tsig-keys)    MODE="tsig-keys" ;;
        --list-tsig)    MODE="list-tsig" ;;
        --remove-tsig)  MODE="remove-tsig" ;;
        --mint-certs)   MODE="mint-certs" ;;
        --service-cert) MODE="service-cert" ;;
        --dns-record)          MODE="dns-record" ;;
        --remove-dns-record)   MODE="remove-dns-record" ;;
        --render-jinja) MODE="render-jinja" ;;
        --print)        MODE="print" ;;
        --interactive)  MODE="interactive" ;;
        --version)      MODE="version" ;;
        --update-containers) MODE="update-containers" ;;
        --apply)        [ -z "$MODE" ] && MODE="apply" ;;
    esac
done

if [ -z "$MODE" ]; then
    MODE="interactive"
fi

export CORE_DEBUG=0

# Pass 2: parse flags
set -- "${ARGS[@]}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)    usage ;;
        --version)    shift ;;
        --tsig-keys|--list-tsig|--mint-certs|--service-cert|--dns-record|--remove-dns-record|--print|--interactive|--update-containers)  shift ;;
        --remove-tsig)  REMOVE_TSIG_KEY="${2:-}"; shift; [ -n "$REMOVE_TSIG_KEY" ] && shift || true ;;
        --render-jinja) RENDER_TEMPLATE="${2:-}"; shift; [ -n "$RENDER_TEMPLATE" ] && shift || true ;;
        --vars)         RENDER_VARS="${2:-}"; shift; [ -n "$RENDER_VARS" ] && shift || true ;;
        --output)       RENDER_OUTPUT="${2:-}"; shift; [ -n "$RENDER_OUTPUT" ] && shift || true ;;
        --apply)      SUB_MODE="apply"; shift ;;
        --kty)        CERT_KTY="$2";  shift 2 ;;
        --size)       CERT_SIZE="$2"; shift 2 ;;
        --intermediate-ca)
            IS_CA=true
            if [[ "${2:-}" =~ ^[0-9]+$ ]]; then PATH_LEN="$2"; shift; fi
            shift ;;
        --debug)
            export CORE_DEBUG=1
            export ANSIBLE_LOG_PATH="/var/log/core-mgr-debug.log"
            export ANSIBLE_VERBOSITY=4
            echo -e "${BLUE}Debug mode enabled. Logging all ansible actions to: $ANSIBLE_LOG_PATH${NC}"
            shift ;;
        *)  err "Unknown flag: $1"; exit 1 ;;
    esac
done

# --- Dispatch ---
do_render_jinja() {
    echo -e "${BOLD}core-template render-jinja${NC}"
    if [ -z "$RENDER_TEMPLATE" ]; then
        err "Missing template file. Usage: --render-jinja <file.j2>"
        exit 1
    fi
    if [ ! -f "$RENDER_TEMPLATE" ]; then
        err "Template file not found: $RENDER_TEMPLATE"
        exit 1
    fi

    local vars="${RENDER_VARS:-$VARS_FILE}"
    if [ ! -f "$vars" ]; then
        err "Vars file not found: $vars"
        exit 1
    fi

    local exec_user="${SUDO_USER:-$USER}"
    local exec_home
    exec_home=$(getent passwd "$exec_user" | cut -d: -f6)

    local default_filename="$(basename "${RENDER_TEMPLATE%.j2}")"
    if [[ "$default_filename" == "$(basename "$RENDER_TEMPLATE")" ]]; then
        default_filename="${default_filename}.rendered"
    fi

    local dest
    if [ -n "$RENDER_OUTPUT" ]; then
        if [ -d "$RENDER_OUTPUT" ]; then
            dest="${RENDER_OUTPUT}/${default_filename}"
        else
            dest="$RENDER_OUTPUT"
        fi
    else
        dest="${exec_home}/${default_filename}"
    fi

    echo "Rendering $RENDER_TEMPLATE -> $dest"
    echo "Using vars: $vars"
    
    python3 -c "
import sys, yaml, jinja2, os
vars_path = '$vars'
template_path = '$RENDER_TEMPLATE'
dest_path = '$dest'

try:
    with open(vars_path, 'r') as f:
        vars_dict = yaml.safe_load(f) or {}
except Exception as e:
    print(f'Error reading vars: {e}')
    sys.exit(1)

# Set up jinja environment with the same custom filters as core-mgr
env = jinja2.Environment(loader=jinja2.FileSystemLoader(os.path.dirname(template_path) or '.'), keep_trailing_newline=True)
env.filters['to_nice_yaml'] = lambda x, indent=4: yaml.safe_dump(x, default_flow_style=False, indent=indent).strip()
def unique_filter_manage(x, attribute=None):
    import json
    if not x: return []
    seen = set()
    res = []
    for item in x:
        val = item.get(attribute, item) if isinstance(item, dict) and attribute else getattr(item, attribute, item) if attribute else item
        try:
            hash_val = val
            if isinstance(val, (dict, list)):
                hash_val = json.dumps(val, sort_keys=True)
        except Exception:
            hash_val = str(val)
        if hash_val not in seen:
            seen.add(hash_val)
            res.append(item)
    return res
env.filters['unique'] = unique_filter_manage

def flatten_filter(value):
    import collections.abc
    result = []
    for item in value:
        if isinstance(item, collections.abc.Iterable) and not isinstance(item, (str, bytes, dict)):
            result.extend(flatten_filter(item))
        else:
            result.append(item)
    return result
env.filters['flatten'] = flatten_filter

def match_test(value, pattern):
    import re
    return bool(re.search(pattern, str(value)))
env.tests['match'] = match_test
env.filters['bool'] = lambda x: str(x).lower() in ['true', 'yes', '1', 'on', 't', 'y']
env.filters['dirname'] = os.path.dirname
env.filters['basename'] = os.path.basename

try:
    template = env.get_template(os.path.basename(template_path))
    result = template.render(**vars_dict)
    with open(dest_path, 'w') as f:
        f.write(result)
    os.chmod(dest_path, 0o644)
    if '$exec_user' != 'root':
        import pwd
        try:
            uid = pwd.getpwnam('$exec_user').pw_uid
            gid = pwd.getpwnam('$exec_user').pw_gid
            os.chown(dest_path, uid, gid)
        except Exception as e:
            pass
except Exception as e:
    print(f'Template error: {e}')
    sys.exit(1)
" >/dev/null

    echo -e "${GREEN}Render complete: $dest${NC}"
}

case "$MODE" in
    tsig-keys)    do_tsig_keys ;;
    list-tsig)    do_list_tsig ;;
    remove-tsig)  do_remove_tsig ;;
    mint-certs)   do_extra_certs ;;
    service-cert) do_service_cert ;;
    dns-record)          do_dns_record ;;
    remove-dns-record)   do_remove_dns_record ;;
    render-jinja) do_render_jinja ;;
    print)        python3 "${CORE_DIR}/lib/interactive.py" --print ;;
    interactive)  python3 "${CORE_DIR}/lib/interactive.py" --interactive ;;
    apply)        python3 "${CORE_DIR}/lib/interactive.py" --apply ;;
    update-containers) python3 "${CORE_DIR}/lib/interactive.py" --update-containers ;;
    version)      echo "core-mgr version 1.4.0"
                  echo "Last Modified: 2026-05-01T03:06:00Z" ;;
esac
