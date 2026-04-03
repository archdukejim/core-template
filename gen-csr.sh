#!/bin/bash
# gen-csr.sh — Generate a leaf certificate signing request (CSR)
#
# Usage:
#   ./gen-csr.sh [options]
#
# Options:
#   --cn <name>           Common name for the certificate (REQUIRED — prompted if omitted)
#   --san <san-list>      Subject Alternative Names, comma-separated
#                         e.g. DNS:myservice.home,DNS:myservice,IP:10.0.0.5
#   --key <path>          Use an existing private key (generates one if omitted)
#   --key-type <type>     rsa | ec | ed25519  (advanced-vars: cert_root_key_type; default: rsa)
#   --key-param <param>   RSA bits or EC curve (default: 2048 for leaf keys)
#   --digest <algo>       sha256 | sha384 | sha512  (advanced-vars: cert_root_digest)
#   --root-cert <path>    Root CA certificate — displayed for context / verification
#   --outpath <dir>       Output directory for key + CSR  (default: ./root-ca/output/)
#   --no-docker           Use local openssl instead of Docker
#
# Output:
#   <cn>.key   — private key for the leaf entity
#   <cn>.csr   — certificate signing request (present to ./root-ca.sh --sign-certs)
#
# Example:
#   ./gen-csr.sh --cn myservice.home --san "DNS:myservice.home,IP:10.0.0.5"
#   ./root-ca.sh --sign-certs root-ca/output/myservice.home.csr

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_CA_DIR="${SCRIPT_DIR}/root-ca"
OUT_DIR="${ROOT_CA_DIR}/output"
CUSTOM_VARS="${SCRIPT_DIR}/custom-vars.yaml"
ADVANCED_VARS="${SCRIPT_DIR}/core/advanced-vars.yaml"
DOCKER_IMAGE="core-root-ca:latest"
DOCKERFILE="${ROOT_CA_DIR}/Dockerfile"

# -----------------------------------------------------------------------
# Colours
# -----------------------------------------------------------------------
BOLD='\033[1m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'

info()  { echo -e "  ${BOLD}[INFO]${NC}  $*"; }
ok()    { echo -e "  ${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "  ${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "  ${RED}[ERROR]${NC} $*" >&2; }
die()   { err "$*"; exit 1; }

# -----------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------
FLAG_CN=""
FLAG_SAN=""
FLAG_KEY_FILE=""
FLAG_KEY_TYPE=""
FLAG_KEY_PARAM=""
FLAG_DIGEST=""
FLAG_ROOT_CERT=""
FLAG_OUTPATH=""
USE_DOCKER=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cn)          FLAG_CN="$2"; shift 2 ;;
        --san)         FLAG_SAN="$2"; shift 2 ;;
        --key)         FLAG_KEY_FILE="$2"; shift 2 ;;
        --key-type)    FLAG_KEY_TYPE="$2"; shift 2 ;;
        --key-param)   FLAG_KEY_PARAM="$2"; shift 2 ;;
        --digest)      FLAG_DIGEST="$2"; shift 2 ;;
        --root-cert)   FLAG_ROOT_CERT="$2"; shift 2 ;;
        --outpath)     FLAG_OUTPATH="$2"; shift 2 ;;
        --no-docker)   USE_DOCKER=false; shift ;;
        --help|-h)     sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[ -n "$FLAG_OUTPATH" ] && OUT_DIR="$FLAG_OUTPATH"

# -----------------------------------------------------------------------
# YAML reading
# -----------------------------------------------------------------------
_read_yaml() {
    local file="$1" key="$2" default="${3:-}"
    [ -f "$file" ] || { echo "$default"; return; }
    command -v python3 >/dev/null 2>&1 || { echo "$default"; return; }
    python3 - "$file" "$key" "$default" <<'PYEOF'
import sys, yaml
try:
    with open(sys.argv[1]) as f:
        data = yaml.safe_load(f)
    val = data.get(sys.argv[2])
    print(val if val is not None else sys.argv[3])
except Exception:
    print(sys.argv[3])
PYEOF
}

# -----------------------------------------------------------------------
# Load config from vars files
# -----------------------------------------------------------------------
# Use leaf-appropriate key sizes (2048 RSA default vs 4096 for CA keys)
_RAW_KEY_TYPE="$(_read_yaml "$ADVANCED_VARS" cert_root_key_type rsa)"
_RAW_KEY_PARAM="$(_read_yaml "$ADVANCED_VARS" cert_root_key_param 4096)"

KEY_TYPE="${FLAG_KEY_TYPE:-${_RAW_KEY_TYPE}}"
# Default leaf keys to 2048 RSA unless explicitly overridden
if [ -n "$FLAG_KEY_PARAM" ]; then
    KEY_PARAM="$FLAG_KEY_PARAM"
elif [[ "${KEY_TYPE,,}" == "rsa" && "$_RAW_KEY_PARAM" == "4096" ]]; then
    KEY_PARAM="2048"
else
    KEY_PARAM="$_RAW_KEY_PARAM"
fi
DIGEST="${FLAG_DIGEST:-$(_read_yaml "$ADVANCED_VARS" cert_root_digest sha256)}"

# -----------------------------------------------------------------------
# Interactive prompt helpers
# -----------------------------------------------------------------------
_prompt() {
    local val="$1" label="$2" dflt="${3:-}"
    if [ -n "$val" ]; then echo "$val"; return; fi
    local input=""
    if [ -n "$dflt" ]; then
        read -rp "  ${label} [${dflt}]: " input
        echo "${input:-$dflt}"
    else
        while [ -z "$input" ]; do
            read -rp "  ${label}: " input
            [ -z "$input" ] && echo -e "  ${RED}This field is required.${NC}" >&2
        done
        echo "$input"
    fi
}

# Always prompts; uses current value as the shown default
_prompt_forced() {
    local current="$1" label="$2"
    local input=""
    if [ -n "$current" ]; then
        read -rp "  ${label} [${current}]: " input
        echo "${input:-$current}"
    else
        while [ -z "$input" ]; do
            read -rp "  ${label}: " input
            [ -z "$input" ] && echo -e "  ${RED}This field is required.${NC}" >&2
        done
        echo "$input"
    fi
}

# -----------------------------------------------------------------------
# _show_csr_summary — print all settings before issuance
# -----------------------------------------------------------------------
_show_csr_summary() {
    local _cn_safe="${CN//[^a-zA-Z0-9._-]/_}"
    local _key_src
    if [ -n "$FLAG_KEY_FILE" ]; then
        _key_src="provided: ${FLAG_KEY_FILE}"
    elif [ -f "${OUT_DIR}/${_cn_safe}.key" ]; then
        _key_src="existing  (${OUT_DIR}/${_cn_safe}.key)"
    else
        _key_src="generate new"
    fi

    echo ""
    echo -e "  ${BOLD}─── CSR Generation — Review ────────────────────────────────────${NC}"
    echo ""
    echo -e "  ${BOLD}Leaf Certificate${NC}"
    echo    "    Common Name:   ${CN}"
    if [ -n "$SAN" ]; then
        echo "    SANs:          ${SAN}"
    else
        echo "    SANs:          (none)"
    fi
    echo ""
    echo -e "  ${BOLD}Key Parameters${NC}"
    echo    "    Type:          ${KEY_TYPE} ${KEY_PARAM}"
    echo    "    Digest:        ${DIGEST}"
    echo    "    Key source:    ${_key_src}"
    echo ""
    echo -e "  ${BOLD}Output${NC}"
    echo    "    Directory:     ${OUT_DIR}"
    $USE_DOCKER && echo "    Docker image:  ${DOCKER_IMAGE}"
    echo ""
    echo -e "  ${BOLD}────────────────────────────────────────────────────────────────${NC}"
}

# -----------------------------------------------------------------------
# _recollect_csr — re-prompt all CSR settings; current values are defaults
# -----------------------------------------------------------------------
_recollect_csr() {
    echo -e "  ${BOLD}Leaf Certificate${NC}"
    CN="$(_prompt_forced "$CN" "Common Name")"
    local _san_display="${SAN:-none}"
    read -rp "  SANs [${_san_display}]: " _new_san
    if [ -n "$_new_san" ]; then
        [ "$_new_san" = "none" ] && SAN="" || SAN="$_new_san"
    fi
    echo ""
    echo -e "  ${BOLD}Key Parameters${NC}"
    KEY_TYPE="$(_prompt_forced  "$KEY_TYPE"  "Key type   (rsa | ec | ed25519)")"
    KEY_PARAM="$(_prompt_forced "$KEY_PARAM" "Key param  (RSA: 2048/3072/4096  EC: P-256/P-384/P-521)")"
    DIGEST="$(_prompt_forced    "$DIGEST"    "Digest     (sha256 | sha384 | sha512)")"
    echo ""
    echo -e "  ${BOLD}Key Source${NC}"
    local _cn_safe="${CN//[^a-zA-Z0-9._-]/_}"
    local _cur_key_label
    if [ -n "$FLAG_KEY_FILE" ]; then
        _cur_key_label="provided: ${FLAG_KEY_FILE}"
    elif [ -f "${OUT_DIR}/${_cn_safe}.key" ]; then
        _cur_key_label="existing  (${OUT_DIR}/${_cn_safe}.key)"
    else
        _cur_key_label="generate new"
    fi
    echo "  Current: ${_cur_key_label}"
    echo "  a) Generate new key"
    echo "  b) Provide existing key path"
    echo "  c) Keep current (${_cur_key_label})"
    echo ""
    local _kc=""
    while [[ "${_kc,,}" != "a" && "${_kc,,}" != "b" && "${_kc,,}" != "c" ]]; do
        read -rp "  Choice [a/b/c]: " _kc
    done
    case "${_kc,,}" in
        a) FLAG_KEY_FILE="" ;;
        b)
            local _kp=""
            while [ ! -f "$_kp" ]; do
                read -rp "  Path to existing key: " _kp
                [ ! -f "$_kp" ] && echo -e "  ${RED}File not found.${NC}" >&2
            done
            FLAG_KEY_FILE="$_kp" ;;
        c) ;;  # no change
    esac
    echo ""
    echo -e "  ${BOLD}Output${NC}"
    OUT_DIR="$(_prompt_forced "$OUT_DIR" "Output directory")"
    echo ""
}

# -----------------------------------------------------------------------
# Docker image management
# -----------------------------------------------------------------------
_ensure_docker_image() {
    command -v docker >/dev/null 2>&1 || {
        warn "Docker not found — falling back to local openssl"
        USE_DOCKER=false
        return
    }
    docker image inspect "$DOCKER_IMAGE" >/dev/null 2>&1 && return
    [ -f "$DOCKERFILE" ] || die "Dockerfile not found: ${DOCKERFILE}"
    info "Building Docker image ${DOCKER_IMAGE}..."
    docker build -t "$DOCKER_IMAGE" "$ROOT_CA_DIR" \
        || die "Docker build failed. Check: ${DOCKERFILE}"
    ok "Docker image built: ${DOCKER_IMAGE}"
}

# -----------------------------------------------------------------------
# Docker run helper — mounts OUT_DIR as /pki/output
# -----------------------------------------------------------------------
_docker_openssl() {
    docker run --rm \
        --user "$(id -u):$(id -g)" \
        -v "${OUT_DIR}:/pki/output" \
        "$DOCKER_IMAGE" \
        openssl "$@"
}

# -----------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------
echo ""
echo -e "  ${BOLD}core-template — Generate Leaf CSR${NC}"
echo ""

# First pass: collect CN (required) and SANs (optional)
CN="$(_prompt "$FLAG_CN" "Common Name (e.g. myservice.home)" "")"

if [ -z "$FLAG_SAN" ]; then
    read -rp "  Subject Alternative Names (e.g. DNS:myservice.home,IP:10.0.0.5) [skip]: " _san_in
    SAN="${_san_in:-}"
else
    SAN="$FLAG_SAN"
fi

# ---- Confirmation loop ----
while true; do
    _show_csr_summary
    echo ""
    read -rp "  Proceed with these settings? [Y/n/edit]: " _confirm
    case "${_confirm,,}" in
        ""|y|yes) break ;;
        *)
            echo ""
            echo -e "  ${CYAN}Edit settings — press Enter to keep each current value:${NC}"
            echo ""
            _recollect_csr
            ;;
    esac
done

# Derive final safe filename after any edits in the loop
CN_SAFE="${CN//[^a-zA-Z0-9._-]/_}"
leaf_key="${OUT_DIR}/${CN_SAFE}.key"
leaf_csr="${OUT_DIR}/${CN_SAFE}.csr"

echo ""

$USE_DOCKER && _ensure_docker_image
! $USE_DOCKER && { command -v openssl >/dev/null 2>&1 || die "openssl not found in PATH"; }

mkdir -p "$OUT_DIR"

# ---- Key ----
if [ -n "$FLAG_KEY_FILE" ]; then
    [ -f "$FLAG_KEY_FILE" ] || die "Key file not found: ${FLAG_KEY_FILE}"
    cp "$FLAG_KEY_FILE" "$leaf_key"
    chmod 600 "$leaf_key"
    ok "Key loaded from: ${FLAG_KEY_FILE}"
elif [ -f "$leaf_key" ]; then
    ok "Key already exists — reusing: ${leaf_key}"
else
    info "Generating leaf private key (${KEY_TYPE} ${KEY_PARAM})..."
    if $USE_DOCKER; then
        case "${KEY_TYPE,,}" in
            rsa)
                _docker_openssl genpkey \
                    -algorithm RSA \
                    -pkeyopt "rsa_keygen_bits:${KEY_PARAM}" \
                    -out "/pki/output/${CN_SAFE}.key" 2>/dev/null ;;
            ec)
                _docker_openssl genpkey \
                    -algorithm EC \
                    -pkeyopt "ec_paramgen_curve:${KEY_PARAM}" \
                    -out "/pki/output/${CN_SAFE}.key" 2>/dev/null ;;
            ed25519)
                _docker_openssl genpkey \
                    -algorithm ed25519 \
                    -out "/pki/output/${CN_SAFE}.key" 2>/dev/null ;;
            *) die "Unknown key type: ${KEY_TYPE}" ;;
        esac
    else
        case "${KEY_TYPE,,}" in
            rsa)
                openssl genpkey \
                    -algorithm RSA \
                    -pkeyopt "rsa_keygen_bits:${KEY_PARAM}" \
                    -out "$leaf_key" 2>/dev/null ;;
            ec)
                openssl genpkey \
                    -algorithm EC \
                    -pkeyopt "ec_paramgen_curve:${KEY_PARAM}" \
                    -out "$leaf_key" 2>/dev/null ;;
            ed25519)
                openssl genpkey \
                    -algorithm ed25519 \
                    -out "$leaf_key" 2>/dev/null ;;
            *) die "Unknown key type: ${KEY_TYPE}" ;;
        esac
    fi
    chmod 600 "$leaf_key"
    ok "Leaf key generated: ${leaf_key}"
fi

# ---- CSR ----
if [ -f "$leaf_csr" ]; then
    ok "CSR already exists: ${leaf_csr}"
    read -rp "  Regenerate CSR? [y/N]: " _regen
    if [[ "${_regen,,}" != "y" ]]; then
        echo ""
        echo -e "  ${CYAN}Present to root-ca.sh with:${NC}"
        echo -e "  ${CYAN}  ./root-ca.sh --sign-certs ${leaf_csr}${NC}"
        echo ""
        exit 0
    fi
    rm -f "$leaf_csr"
fi

# Build OpenSSL config for CSR (supports optional SANs)
local_cnf="${OUT_DIR}/_csr_${CN_SAFE}.cnf"
cat > "$local_cnf" <<CNFEOF
[req]
prompt = no
distinguished_name = dn
req_extensions = leaf_ext

[dn]
CN = ${CN}

[leaf_ext]
basicConstraints = CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth,clientAuth
CNFEOF

if [ -n "$SAN" ]; then
    echo "subjectAltName = ${SAN}" >> "$local_cnf"
fi

info "Generating CSR for: ${CN}..."

if $USE_DOCKER; then
    _docker_openssl req -new \
        -key "/pki/output/${CN_SAFE}.key" \
        -out "/pki/output/${CN_SAFE}.csr" \
        -"${DIGEST}" \
        -config "/pki/output/_csr_${CN_SAFE}.cnf" \
        2>/dev/null \
    || { rm -f "$local_cnf"; die "CSR generation failed"; }
else
    openssl req -new \
        -key "$leaf_key" \
        -out "$leaf_csr" \
        -"${DIGEST}" \
        -config "$local_cnf" \
        2>/dev/null \
    || { rm -f "$local_cnf"; die "CSR generation failed"; }
fi

rm -f "$local_cnf"
ok "CSR generated: ${leaf_csr}"

# ---- Root cert context (display only) ----
if [ -n "$FLAG_ROOT_CERT" ]; then
    if [ -f "$FLAG_ROOT_CERT" ]; then
        echo ""
        info "Root CA context (${FLAG_ROOT_CERT}):"
        local root_dir; root_dir="$(dirname "$(realpath "$FLAG_ROOT_CERT")")"
        local root_file; root_file="$(basename "$FLAG_ROOT_CERT")"
        if $USE_DOCKER; then
            docker run --rm \
                --user "$(id -u):$(id -g)" \
                -v "${root_dir}:/pki/ca:ro" \
                "$DOCKER_IMAGE" \
                openssl x509 -in "/pki/ca/${root_file}" -noout \
                    -subject -issuer -fingerprint -sha256 2>/dev/null \
            | sed 's/^/    /' || true
        else
            openssl x509 -in "$FLAG_ROOT_CERT" -noout \
                -subject -issuer -fingerprint -sha256 2>/dev/null \
            | sed 's/^/    /' || true
        fi
    else
        warn "Root cert not found: ${FLAG_ROOT_CERT}"
    fi
fi

echo ""
echo -e "  ${BOLD}Output files:${NC}"
echo "    Key: ${leaf_key}"
echo "    CSR: ${leaf_csr}"
echo ""
echo -e "  ${CYAN}Sign this CSR with root-ca.sh:${NC}"
echo -e "  ${CYAN}  ./root-ca.sh --sign-certs ${leaf_csr} [--outpath <dir>]${NC}"
echo ""
