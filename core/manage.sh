#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------
# manage.sh — Live configuration management for a running core-template
#
# Run this script ON the target machine (must be root / sudo).
#
# Modes:
#   --tsig-keys     Add a TSIG key to custom-vars.yaml and reload BIND9.
#   --list-tsig     List all active TSIG keys and grants from live BIND9 config.
#   --remove-tsig   Remove a TSIG key and its grants from live BIND9 config.
#   --mint-certs    Mint an offline certificate and save to custom-vars.yaml.
#                   --intermediate-ca [N]  Issue as a subordinate CA cert (pathLen=N, default 0).
#                                          pathLen=0: can sign leaf certs, cannot issue further CAs.
#   --service-cert  Re-issue core service TLS certs (dns, ldap, ca, certificates) via Step-CA.
#   --dns-record         Add a DNS record to custom-vars.yaml and reload BIND9.
#   --remove-dns-record  Remove a DNS record from custom-vars.yaml and reload BIND9.
#
# Common flags:
#   --apply            Apply without interactive prompting (uses existing custom-vars.yaml)
#   --kty <type>       Key type for minted certs: RSA | EC | OKP  (default: RSA)
#   --size <bits>      Key size (RSA: 2048/3072/4096, EC: 256/384) (default: 4096)
#
# Examples:
#   sudo ./manage.sh --tsig-keys                  # Interactive: add a TSIG key
#   sudo ./manage.sh --tsig-keys --apply          # Non-interactive: apply tsig_keys from custom-vars.yaml
#   sudo ./manage.sh --list-tsig                  # Show all active TSIG keys and grants
#   sudo ./manage.sh --remove-tsig acme_npm       # Remove a TSIG key by name
#   sudo ./manage.sh --mint-certs                              # Interactive: mint a leaf cert
#   sudo ./manage.sh --mint-certs --intermediate-ca            # Interactive: mint a subordinate CA (pathLen=0)
#   sudo ./manage.sh --mint-certs --intermediate-ca 1          # Subordinate CA that can sign one more CA level
#   sudo ./manage.sh --mint-certs --apply                      # Non-interactive: mint all extra_certs from custom-vars.yaml
#   sudo ./manage.sh --service-cert               # Interactive: re-issue core service certs
#   sudo ./manage.sh --service-cert --apply       # Non-interactive: re-issue all core service certs
#   sudo ./manage.sh --dns-record                 # Interactive: add a DNS record
#   sudo ./manage.sh --dns-record --apply         # Non-interactive: re-render zones and reload BIND9
#   sudo ./manage.sh --remove-dns-record          # Interactive: pick and remove a DNS record
# -----------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$SCRIPT_DIR"
PLAYBOOKS_DIR="$CORE_DIR/playbooks"
CUSTOM_VARS_FILE="$(dirname "$CORE_DIR")/custom-vars.yaml"
ADVANCED_VARS_FILE="$CORE_DIR/advanced-vars.yaml"

# Source shared library modules
source "$CORE_DIR/lib/output.sh"
source "$CORE_DIR/lib/ansible.sh"
source "$CORE_DIR/lib/vars.sh"
source "$CORE_DIR/lib/tsig.sh"
source "$CORE_DIR/lib/certs.sh"
source "$CORE_DIR/lib/dns.sh"

# --- Globals ---
TARGET_BASE="/opt"
MODE=""
SUB_MODE="interactive"
REMOVE_TSIG_KEY=""
IS_CA=false
PATH_LEN=0
CERT_KTY="RSA"
CERT_SIZE="4096"

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
        --tsig-keys|--list-tsig|--mint-certs|--service-cert|--dns-record|--remove-dns-record)  shift ;;
        --remove-tsig)  REMOVE_TSIG_KEY="${2:-}"; shift; [ -n "$REMOVE_TSIG_KEY" ] && shift || true ;;
        --apply)      SUB_MODE="apply"; shift ;;
        --kty)        CERT_KTY="$2";  shift 2 ;;
        --size)       CERT_SIZE="$2"; shift 2 ;;
        --intermediate-ca)
            IS_CA=true
            if [[ "${2:-}" =~ ^[0-9]+$ ]]; then PATH_LEN="$2"; shift; fi
            shift ;;
        *)  err "Unknown flag: $1"; exit 1 ;;
    esac
done

# --- Dispatch ---
case "$MODE" in
    tsig-keys)    do_tsig_keys ;;
    list-tsig)    do_list_tsig ;;
    remove-tsig)  do_remove_tsig ;;
    mint-certs)   do_extra_certs ;;
    service-cert) do_service_cert ;;
    dns-record)          do_dns_record ;;
    remove-dns-record)   do_remove_dns_record ;;
esac
