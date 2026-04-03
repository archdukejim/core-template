#!/bin/bash
# rootca.sh — Offline Root CA + Intermediate CA Initialization
#
# Run this ONCE before the Ansible installer. The installer never touches
# the root CA. The root CA key can be destroyed or stored offline after
# signing; only the certs and intermediate key need to reach the target.
#
# Usage:
#   bash core/pki/rootca.sh init     — Full flow (generates all artifacts)
#   bash core/pki/rootca.sh verify   — Verify intermediate cert chain
#   bash core/pki/rootca.sh show     — Print cert text for all outputs
#   bash core/pki/rootca.sh help     — Show this message
#
# Output (core/pki/output/ — gitignored):
#   root_ca.key         — ROOT CA PRIVATE KEY — keep offline or destroy after signing
#   root_ca.crt         — Root CA certificate (deployed to every service as trust anchor)
#   intermediate_ca.key — Intermediate CA private key (deployed to step-ca)
#   intermediate_ca.crt — Intermediate CA certificate (deployed to step-ca)
#   intermediate.csr    — Intermediate CSR (audit record)
#
# Providing your own root CA key:
#   Place a PEM-format private key at output/root_ca.key before running init.
#   The script will skip key generation if that file already exists.
#   Supported types: RSA (any bit size), EC (P-256/P-384/P-521), Ed25519.
#
# Key generation settings:
#   Edit core/advanced-vars.yaml:
#     cert_root_key_type: rsa        # rsa | ec | ed25519
#     cert_root_key_param: '4096'    # RSA: 2048/3072/4096 | EC: P-256/P-384/P-521 | Ed25519: ignored
#   Subject identity is read from custom-vars.yaml (ca_name, cert_country, etc.)

set -euo pipefail

# -----------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OUT_DIR="${SCRIPT_DIR}/output"

CUSTOM_VARS="${REPO_ROOT}/custom-vars.yaml"
ADVANCED_VARS="${REPO_ROOT}/core/advanced-vars.yaml"

# -----------------------------------------------------------------------
# Colours
# -----------------------------------------------------------------------
BOLD='\033[1m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

info()  { echo -e "  ${BOLD}[INFO]${NC}  $*"; }
ok()    { echo -e "  ${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "  ${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "  ${RED}[ERROR]${NC} $*" >&2; }
die()   { err "$*"; exit 1; }

# -----------------------------------------------------------------------
# Read a single scalar value from a YAML file (requires python3 + PyYAML)
# -----------------------------------------------------------------------
_read_yaml() {
    local file="$1" key="$2" default="$3"
    if [ ! -f "$file" ]; then
        echo "$default"
        return
    fi
    python3 - "$file" "$key" "$default" <<'EOF'
import sys, yaml
try:
    with open(sys.argv[1]) as f:
        data = yaml.safe_load(f)
    val = data.get(sys.argv[2])
    print(val if val is not None else sys.argv[3])
except Exception:
    print(sys.argv[3])
EOF
}

# -----------------------------------------------------------------------
# Load config values
# -----------------------------------------------------------------------
_load_config() {
    ROOT_KEY_TYPE="$(_read_yaml "$ADVANCED_VARS" cert_root_key_type rsa)"
    ROOT_KEY_PARAM="$(_read_yaml "$ADVANCED_VARS" cert_root_key_param 4096)"
    ROOT_CA_DAYS="$(_read_yaml "$ADVANCED_VARS" cert_root_ca_days 7300)"
    ROOT_DIGEST="$(_read_yaml "$ADVANCED_VARS" cert_root_digest sha256)"

    INT_KEY_TYPE="$(_read_yaml "$ADVANCED_VARS" cert_intermediate_key_type rsa)"
    INT_KEY_PARAM="$(_read_yaml "$ADVANCED_VARS" cert_intermediate_key_param 4096)"
    INT_CA_DAYS="$(_read_yaml "$ADVANCED_VARS" cert_intermediate_days 5475)"
    INT_DIGEST="$(_read_yaml "$ADVANCED_VARS" cert_intermediate_digest sha256)"

    CA_NAME="$(_read_yaml "$CUSTOM_VARS" ca_name "Home Lab CA")"
    CERT_COUNTRY="$(_read_yaml "$CUSTOM_VARS" cert_country US)"
    CERT_PROVINCE="$(_read_yaml "$CUSTOM_VARS" cert_province "Your State")"
    CERT_CITY="$(_read_yaml "$CUSTOM_VARS" cert_city "Your City")"
    CERT_ORG="$(_read_yaml "$CUSTOM_VARS" cert_org "Home Lab")"
    CERT_OU="$(_read_yaml "$CUSTOM_VARS" cert_ou Infrastructure)"
}

# -----------------------------------------------------------------------
# Build openssl genpkey args for the given key type + param
# -----------------------------------------------------------------------
_genpkey_args() {
    local key_type="$1" key_param="$2"
    case "${key_type,,}" in
        rsa)     echo "-algorithm RSA -pkeyopt rsa_keygen_bits:${key_param}" ;;
        ec)      echo "-algorithm EC  -pkeyopt ec_paramgen_curve:${key_param}" ;;
        ed25519) echo "-algorithm ed25519" ;;
        *)       die "Unknown key type '${key_type}'. Supported: rsa, ec, ed25519" ;;
    esac
}

# -----------------------------------------------------------------------
# cmd_init — Full PKI initialization
# -----------------------------------------------------------------------
cmd_init() {
    _load_config

    echo ""
    echo -e "${BOLD}core-template rootca — PKI Initialization${NC}"
    echo ""

    # Verify openssl is available
    command -v openssl >/dev/null 2>&1 || die "openssl not found in PATH"
    command -v python3 >/dev/null 2>&1 || warn "python3 not found — using built-in defaults for config values"

    mkdir -p "$OUT_DIR"
    chmod 700 "$OUT_DIR"

    local root_key="${OUT_DIR}/root_ca.key"
    local root_crt="${OUT_DIR}/root_ca.crt"
    local int_key="${OUT_DIR}/intermediate_ca.key"
    local int_csr="${OUT_DIR}/intermediate.csr"
    local int_crt="${OUT_DIR}/intermediate_ca.crt"

    echo -e "  Config:"
    echo "    Root CA:        ${ROOT_KEY_TYPE} ${ROOT_KEY_PARAM} / ${ROOT_CA_DAYS} days / ${ROOT_DIGEST}"
    echo "    Intermediate:   ${INT_KEY_TYPE} ${INT_KEY_PARAM} / ${INT_CA_DAYS} days / ${INT_DIGEST}"
    echo "    Subject:        C=${CERT_COUNTRY}/ST=${CERT_PROVINCE}/L=${CERT_CITY}/O=${CERT_ORG}/OU=${CERT_OU}"
    echo "    CA Name:        ${CA_NAME}"
    echo ""

    # ---- 1. Root CA key -----------------------------------------------
    if [ -f "$root_key" ]; then
        ok "Root CA key already exists — skipping generation (using existing key)"
    else
        info "Generating root CA private key (${ROOT_KEY_TYPE} ${ROOT_KEY_PARAM})..."
        # shellcheck disable=SC2086
        openssl genpkey $(_genpkey_args "$ROOT_KEY_TYPE" "$ROOT_KEY_PARAM") \
            -out "$root_key" 2>/dev/null
        chmod 600 "$root_key"
        ok "Root CA key generated: ${root_key}"
    fi

    # ---- 2. Root CA self-signed certificate ---------------------------
    if [ -f "$root_crt" ]; then
        ok "Root CA certificate already exists — skipping self-sign"
    else
        info "Self-signing root CA certificate (${ROOT_CA_DAYS} days)..."
        local root_subj="/C=${CERT_COUNTRY}/ST=${CERT_PROVINCE}/L=${CERT_CITY}/O=${CERT_ORG}/OU=${CERT_OU}/CN=${CA_NAME}"
        openssl req -new -x509 \
            -key "$root_key" \
            -out "$root_crt" \
            -days "$ROOT_CA_DAYS" \
            -"${ROOT_DIGEST}" \
            -subj "$root_subj" \
            -addext "basicConstraints=critical,CA:TRUE" \
            -addext "subjectKeyIdentifier=hash" \
            -addext "keyUsage=critical,keyCertSign,cRLSign" \
            2>/dev/null
        chmod 644 "$root_crt"
        ok "Root CA certificate generated: ${root_crt}"
    fi

    # ---- 3. Intermediate CA key ---------------------------------------
    if [ -f "$int_key" ]; then
        ok "Intermediate CA key already exists — skipping generation"
    else
        info "Generating intermediate CA private key (${INT_KEY_TYPE} ${INT_KEY_PARAM})..."
        # shellcheck disable=SC2086
        openssl genpkey $(_genpkey_args "$INT_KEY_TYPE" "$INT_KEY_PARAM") \
            -out "$int_key" 2>/dev/null
        chmod 600 "$int_key"
        ok "Intermediate CA key generated: ${int_key}"
    fi

    # ---- 4. Intermediate CA CSR ---------------------------------------
    if [ -f "$int_csr" ]; then
        ok "Intermediate CSR already exists — skipping"
    else
        info "Generating intermediate CA CSR..."
        local int_subj="/C=${CERT_COUNTRY}/ST=${CERT_PROVINCE}/L=${CERT_CITY}/O=${CERT_ORG}/OU=Certificate Issuing Authority/CN=${CA_NAME} Intermediate CA"
        openssl req -new \
            -key "$int_key" \
            -out "$int_csr" \
            -"${INT_DIGEST}" \
            -subj "$int_subj" \
            2>/dev/null
        ok "Intermediate CSR generated: ${int_csr}"
    fi

    # ---- 5. Sign intermediate CSR with root CA ------------------------
    if [ -f "$int_crt" ]; then
        ok "Intermediate CA certificate already exists — skipping signing"
    else
        info "Signing intermediate CA certificate (${INT_CA_DAYS} days)..."
        openssl x509 -req \
            -in "$int_csr" \
            -CA "$root_crt" \
            -CAkey "$root_key" \
            -CAcreateserial \
            -out "$int_crt" \
            -days "$INT_CA_DAYS" \
            -"${INT_DIGEST}" \
            -extfile <(printf '[ext]\nbasicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always\n') \
            -extensions ext \
            2>/dev/null
        chmod 640 "$int_crt"
        ok "Intermediate CA certificate signed: ${int_crt}"
    fi

    # ---- 6. Verify chain ----------------------------------------------
    info "Verifying certificate chain..."
    openssl verify -CAfile "$root_crt" "$int_crt" >/dev/null 2>&1 \
        && ok "Chain verified: ${int_crt} → ${root_crt}" \
        || die "Chain verification failed — check your certificates"

    # ---- 7. Summary ---------------------------------------------------
    echo ""
    echo -e "  ${BOLD}Fingerprints:${NC}"
    echo -n "    Root CA:        " && openssl x509 -in "$root_crt" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//'
    echo -n "    Intermediate:   " && openssl x509 -in "$int_crt" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//'
    echo ""
    echo -e "  ${BOLD}Output files:${NC}"
    echo "    ${root_key}"
    echo "    ${root_crt}"
    echo "    ${int_key}"
    echo "    ${int_crt}"
    echo "    ${int_csr}"
    echo ""
    echo -e "  ${YELLOW}${BOLD}IMPORTANT:${NC}"
    echo -e "  ${YELLOW}  root_ca.key is NOT needed by the installer.${NC}"
    echo -e "  ${YELLOW}  Store it offline (e.g. encrypted USB) or destroy it now.${NC}"
    echo -e "  ${YELLOW}  The installer only needs: root_ca.crt, intermediate_ca.crt, intermediate_ca.key${NC}"
    echo ""
}

# -----------------------------------------------------------------------
# cmd_verify — Verify the certificate chain
# -----------------------------------------------------------------------
cmd_verify() {
    local root_crt="${OUT_DIR}/root_ca.crt"
    local int_crt="${OUT_DIR}/intermediate_ca.crt"

    [ -f "$root_crt" ] || die "root_ca.crt not found in ${OUT_DIR}. Run: rootca.sh init"
    [ -f "$int_crt" ]  || die "intermediate_ca.crt not found in ${OUT_DIR}. Run: rootca.sh init"

    echo ""
    info "Verifying: ${int_crt}"
    info "     Against: ${root_crt}"
    openssl verify -CAfile "$root_crt" "$int_crt" \
        && ok "Chain OK" \
        || { err "Chain verification FAILED"; exit 1; }
    echo ""
}

# -----------------------------------------------------------------------
# cmd_show — Print cert text for all output files
# -----------------------------------------------------------------------
cmd_show() {
    echo ""
    for f in root_ca.crt intermediate_ca.crt; do
        local cert="${OUT_DIR}/${f}"
        if [ -f "$cert" ]; then
            echo -e "${BOLD}=== ${f} ===${NC}"
            openssl x509 -in "$cert" -noout -text 2>/dev/null | grep -E '(Subject:|Issuer:|Not Before|Not After|Public Key Algorithm|RSA Public-Key|Signature Algorithm)'
            echo ""
        else
            warn "${f} not found in ${OUT_DIR}"
        fi
    done
}

# -----------------------------------------------------------------------
# cmd_help
# -----------------------------------------------------------------------
cmd_help() {
    sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
}

# -----------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------
case "${1:-help}" in
    init)    cmd_init ;;
    verify)  cmd_verify ;;
    show)    cmd_show ;;
    help|--help|-h) cmd_help ;;
    *) err "Unknown subcommand: $1"; cmd_help; exit 1 ;;
esac
