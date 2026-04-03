#!/bin/bash
# root-ca.sh — PKI management: Root CA init, Intermediate CA, and CSR signing
#
# Usage:
#   ./root-ca.sh init                           Full PKI init (root CA + intermediate CA)
#   ./root-ca.sh verify                         Verify certificate chain
#   ./root-ca.sh show                           Print certificate details
#   ./root-ca.sh --sign-certs <path/to/csr>     Sign a leaf CSR with the root CA
#   ./root-ca.sh help                           Show this message
#
# All identity parameters are read from custom-vars.yaml / core/advanced-vars.yaml.
# CLI flags override the vars files. Missing required fields are prompted interactively.
#
# Flags:
#   --ca-name <name>      CA common name           (custom-vars: ca_name)
#   --country <C>         Country code             (custom-vars: cert_country)
#   --province <ST>       State / province         (custom-vars: cert_province)
#   --city <L>            City / locality          (custom-vars: cert_city)
#   --org <O>             Organization             (custom-vars: cert_org)
#   --ou <OU>             Org unit                 (custom-vars: cert_ou)
#   --key <path>          Provide an existing root CA private key (skips key generation)
#   --key-type <type>     rsa | ec | ed25519       (advanced-vars: cert_root_key_type)
#   --key-param <param>   RSA bits or EC curve     (advanced-vars: cert_root_key_param)
#   --root-days <n>       Root CA validity (days)  (advanced-vars: cert_root_ca_days)
#   --int-days <n>        Intermediate CA validity (advanced-vars: cert_intermediate_days)
#   --leaf-days <n>       Leaf cert validity       (advanced-vars: cert_service_days)
#   --digest <algo>       sha256 | sha384 | sha512 (advanced-vars: cert_root_digest)
#   --outpath <dir>       Output directory         (default: ./root-ca/output/)
#   --no-docker           Run openssl locally instead of using Docker
#
# --sign-certs flags:
#   --sign-certs <csr>    Path to the CSR file to sign
#   --outpath <dir>       Where to write the signed cert (default: script directory)
#   --leaf-days <n>       Override leaf cert validity period

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
MODE="help"
SIGN_CSR=""
USE_DOCKER=true
FLAG_CA_NAME="";  FLAG_COUNTRY="";  FLAG_PROVINCE=""; FLAG_CITY=""
FLAG_ORG="";      FLAG_OU="";       FLAG_KEY_FILE=""; FLAG_KEY_TYPE=""
FLAG_KEY_PARAM=""; FLAG_ROOT_DAYS=""; FLAG_INT_DAYS=""; FLAG_LEAF_DAYS=""
FLAG_DIGEST="";   FLAG_OUTPATH=""

# First positional argument may be a subcommand
if [[ $# -gt 0 ]]; then
    case "$1" in
        init|verify|show|help|--help|-h) MODE="$1"; shift ;;
    esac
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sign-certs)   MODE="sign-certs"; SIGN_CSR="${2:?'--sign-certs requires a CSR file path'}"; shift 2 ;;
        --ca-name)      FLAG_CA_NAME="$2"; shift 2 ;;
        --country)      FLAG_COUNTRY="$2"; shift 2 ;;
        --province)     FLAG_PROVINCE="$2"; shift 2 ;;
        --city)         FLAG_CITY="$2"; shift 2 ;;
        --org)          FLAG_ORG="$2"; shift 2 ;;
        --ou)           FLAG_OU="$2"; shift 2 ;;
        --key)          FLAG_KEY_FILE="$2"; shift 2 ;;
        --key-type)     FLAG_KEY_TYPE="$2"; shift 2 ;;
        --key-param)    FLAG_KEY_PARAM="$2"; shift 2 ;;
        --root-days)    FLAG_ROOT_DAYS="$2"; shift 2 ;;
        --int-days)     FLAG_INT_DAYS="$2"; shift 2 ;;
        --leaf-days)    FLAG_LEAF_DAYS="$2"; shift 2 ;;
        --digest)       FLAG_DIGEST="$2"; shift 2 ;;
        --outpath)      FLAG_OUTPATH="$2"; shift 2 ;;
        --no-docker)    USE_DOCKER=false; shift ;;
        help|--help|-h) MODE="help"; shift ;;
        *) err "Unknown argument: $1"; MODE="help"; set -- ;;
    esac
done

# Apply --outpath for non-sign-certs modes
[[ -n "$FLAG_OUTPATH" && "$MODE" != "sign-certs" ]] && OUT_DIR="$FLAG_OUTPATH"

# -----------------------------------------------------------------------
# YAML reading (requires python3 + PyYAML on host)
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
# Load config from vars files; CLI flags take precedence
# -----------------------------------------------------------------------
_load_config() {
    ROOT_KEY_TYPE="${FLAG_KEY_TYPE:-$(_read_yaml "$ADVANCED_VARS" cert_root_key_type rsa)}"
    ROOT_KEY_PARAM="${FLAG_KEY_PARAM:-$(_read_yaml "$ADVANCED_VARS" cert_root_key_param 4096)}"
    ROOT_CA_DAYS="${FLAG_ROOT_DAYS:-$(_read_yaml "$ADVANCED_VARS" cert_root_ca_days 7300)}"
    ROOT_DIGEST="${FLAG_DIGEST:-$(_read_yaml "$ADVANCED_VARS" cert_root_digest sha256)}"

    INT_KEY_TYPE="$(_read_yaml "$ADVANCED_VARS" cert_intermediate_key_type rsa)"
    INT_KEY_PARAM="$(_read_yaml "$ADVANCED_VARS" cert_intermediate_key_param 4096)"
    INT_CA_DAYS="${FLAG_INT_DAYS:-$(_read_yaml "$ADVANCED_VARS" cert_intermediate_days 5475)}"
    INT_DIGEST="${FLAG_DIGEST:-$(_read_yaml "$ADVANCED_VARS" cert_intermediate_digest sha256)}"
    LEAF_DAYS="${FLAG_LEAF_DAYS:-$(_read_yaml "$ADVANCED_VARS" cert_service_days 5475)}"

    CA_NAME="${FLAG_CA_NAME:-$(_read_yaml "$CUSTOM_VARS" ca_name '')}"
    CERT_COUNTRY="${FLAG_COUNTRY:-$(_read_yaml "$CUSTOM_VARS" cert_country '')}"
    CERT_PROVINCE="${FLAG_PROVINCE:-$(_read_yaml "$CUSTOM_VARS" cert_province '')}"
    CERT_CITY="${FLAG_CITY:-$(_read_yaml "$CUSTOM_VARS" cert_city '')}"
    CERT_ORG="${FLAG_ORG:-$(_read_yaml "$CUSTOM_VARS" cert_org '')}"
    CERT_OU="${FLAG_OU:-$(_read_yaml "$CUSTOM_VARS" cert_ou '')}"
}

# -----------------------------------------------------------------------
# Interactive prompts — prompt only when value is empty
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

_collect_identity() {
    local need_prompt=false
    [[ -z "$CA_NAME" || -z "$CERT_COUNTRY" || -z "$CERT_PROVINCE" ||
       -z "$CERT_CITY" || -z "$CERT_ORG"   || -z "$CERT_OU" ]] && need_prompt=true

    if $need_prompt; then
        echo ""
        echo -e "  ${BOLD}Certificate Identity${NC}"
        echo -e "  ${CYAN}Some fields were not found in custom-vars.yaml.${NC}"
        echo -e "  ${CYAN}Press Enter to accept the suggested default, or type a new value.${NC}"
        echo ""
    fi

    CA_NAME="$(_prompt       "$CA_NAME"       "CA Name"                  "Home Lab CA")"
    CERT_COUNTRY="$(_prompt  "$CERT_COUNTRY"  "Country (2-letter code)"  "US")"
    CERT_PROVINCE="$(_prompt "$CERT_PROVINCE" "State / Province"         "Your State")"
    CERT_CITY="$(_prompt     "$CERT_CITY"     "City / Locality"          "Your City")"
    CERT_ORG="$(_prompt      "$CERT_ORG"      "Organization"             "Home Lab")"
    CERT_OU="$(_prompt       "$CERT_OU"       "Organizational Unit"      "Infrastructure")"
}

# -----------------------------------------------------------------------
# Docker image management
# -----------------------------------------------------------------------
_ensure_docker_image() {
    command -v docker >/dev/null 2>&1 || {
        warn "Docker not found — falling back to local openssl (--no-docker implied)"
        USE_DOCKER=false
        return
    }
    if docker image inspect "$DOCKER_IMAGE" >/dev/null 2>&1; then
        return
    fi
    [ -f "$DOCKERFILE" ] || die "Dockerfile not found: ${DOCKERFILE}"
    info "Building Docker image ${DOCKER_IMAGE} from ${DOCKERFILE}..."
    docker build -t "$DOCKER_IMAGE" "$ROOT_CA_DIR" \
        || die "Docker build failed. Check: ${DOCKERFILE}"
    ok "Docker image built: ${DOCKER_IMAGE}"
}

# -----------------------------------------------------------------------
# Path translation: host path → container path (when OUT_DIR = /pki/output)
# -----------------------------------------------------------------------
_p() {
    local host_path
    host_path="$(realpath "$1" 2>/dev/null || echo "$1")"
    if $USE_DOCKER; then
        local out_real
        out_real="$(realpath "${OUT_DIR}")"
        if [[ "$host_path" == "${out_real}/"* ]]; then
            echo "/pki/output/${host_path#${out_real}/}"
        elif [[ "$host_path" == "${out_real}" ]]; then
            echo "/pki/output"
        else
            echo "$host_path"
        fi
    else
        echo "$host_path"
    fi
}

# -----------------------------------------------------------------------
# Run openssl — Docker (OUT_DIR mounted as /pki/output) or local
# Set _EXTRA_VOLS=("host:container[:opts]" ...) for additional mounts.
# -----------------------------------------------------------------------
_EXTRA_VOLS=()

_run_openssl() {
    if $USE_DOCKER; then
        local vol_args=("-v" "${OUT_DIR}:/pki/output")
        for v in "${_EXTRA_VOLS[@]+"${_EXTRA_VOLS[@]}"}"; do
            vol_args+=("-v" "$v")
        done
        docker run --rm \
            --user "$(id -u):$(id -g)" \
            "${vol_args[@]}" \
            "$DOCKER_IMAGE" \
            openssl "$@"
    else
        openssl "$@"
    fi
}

# -----------------------------------------------------------------------
# cmd_init — Full PKI initialisation
# -----------------------------------------------------------------------
cmd_init() {
    _load_config
    _collect_identity

    $USE_DOCKER && _ensure_docker_image
    ! $USE_DOCKER && { command -v openssl >/dev/null 2>&1 || die "openssl not found in PATH"; }

    mkdir -p "$OUT_DIR"
    chmod 700 "$OUT_DIR"

    local root_key="${OUT_DIR}/root_ca.key"
    local root_crt="${OUT_DIR}/root_ca.crt"
    local int_key="${OUT_DIR}/intermediate_ca.key"
    local int_csr="${OUT_DIR}/intermediate.csr"
    local int_crt="${OUT_DIR}/intermediate_ca.crt"

    echo ""
    echo -e "  ${BOLD}core-template — PKI Initialization${NC}"
    echo ""
    echo "    Root CA:      ${ROOT_KEY_TYPE} ${ROOT_KEY_PARAM} / ${ROOT_CA_DAYS} days / ${ROOT_DIGEST}"
    echo "    Intermediate: ${INT_KEY_TYPE} ${INT_KEY_PARAM} / ${INT_CA_DAYS} days / ${INT_DIGEST}"
    echo "    Subject:      C=${CERT_COUNTRY}/ST=${CERT_PROVINCE}/L=${CERT_CITY}/O=${CERT_ORG}/OU=${CERT_OU}"
    echo "    CA Name:      ${CA_NAME}"
    echo "    Output:       ${OUT_DIR}"
    $USE_DOCKER && echo "    Docker image: ${DOCKER_IMAGE}"
    echo ""

    # ---- Handle key source ----
    if [ -n "$FLAG_KEY_FILE" ]; then
        [ -f "$FLAG_KEY_FILE" ] || die "Key file not found: ${FLAG_KEY_FILE}"
        [ -f "$root_key" ] && warn "Replacing existing root CA key with: ${FLAG_KEY_FILE}"
        cp "$FLAG_KEY_FILE" "$root_key"
        chmod 600 "$root_key"
        ok "Root CA key loaded from: ${FLAG_KEY_FILE}"
    elif [ ! -f "$root_key" ]; then
        # No key on disk and none provided — ask the user
        echo -e "  ${BOLD}Root CA Private Key${NC}"
        echo "  1) Generate a new root CA private key"
        echo "  2) Provide the path to an existing key"
        echo ""
        local key_choice=""
        while [[ "$key_choice" != "1" && "$key_choice" != "2" ]]; do
            read -rp "  Choice [1/2]: " key_choice
        done
        if [ "$key_choice" = "2" ]; then
            local key_path=""
            while [ ! -f "$key_path" ]; do
                read -rp "  Path to existing key: " key_path
                [ ! -f "$key_path" ] && echo -e "  ${RED}File not found.${NC}" >&2
            done
            cp "$key_path" "$root_key"
            chmod 600 "$root_key"
            ok "Root CA key loaded from: ${key_path}"
        fi
        echo ""
    fi

    # ---- 1. Root CA key ----
    if [ -f "$root_key" ]; then
        ok "Root CA key ready"
    else
        info "Generating root CA private key (${ROOT_KEY_TYPE} ${ROOT_KEY_PARAM})..."
        case "${ROOT_KEY_TYPE,,}" in
            rsa)
                _run_openssl genpkey \
                    -algorithm RSA \
                    -pkeyopt "rsa_keygen_bits:${ROOT_KEY_PARAM}" \
                    -out "$(_p "$root_key")" 2>/dev/null ;;
            ec)
                _run_openssl genpkey \
                    -algorithm EC \
                    -pkeyopt "ec_paramgen_curve:${ROOT_KEY_PARAM}" \
                    -out "$(_p "$root_key")" 2>/dev/null ;;
            ed25519)
                _run_openssl genpkey \
                    -algorithm ed25519 \
                    -out "$(_p "$root_key")" 2>/dev/null ;;
            *) die "Unknown key type '${ROOT_KEY_TYPE}'. Supported: rsa, ec, ed25519" ;;
        esac
        chmod 600 "$root_key"
        ok "Root CA key generated: ${root_key}"
    fi

    # ---- 2. Root CA self-signed certificate ----
    if [ -f "$root_crt" ]; then
        ok "Root CA certificate already exists — skipping"
    else
        info "Self-signing root CA certificate (${ROOT_CA_DAYS} days)..."
        local root_subj="/C=${CERT_COUNTRY}/ST=${CERT_PROVINCE}/L=${CERT_CITY}/O=${CERT_ORG}/OU=${CERT_OU}/CN=${CA_NAME}"
        _run_openssl req -new -x509 \
            -key "$(_p "$root_key")" \
            -out "$(_p "$root_crt")" \
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

    # ---- 3. Intermediate CA key ----
    if [ -f "$int_key" ]; then
        ok "Intermediate CA key already exists — skipping"
    else
        info "Generating intermediate CA private key (${INT_KEY_TYPE} ${INT_KEY_PARAM})..."
        case "${INT_KEY_TYPE,,}" in
            rsa)
                _run_openssl genpkey \
                    -algorithm RSA \
                    -pkeyopt "rsa_keygen_bits:${INT_KEY_PARAM}" \
                    -out "$(_p "$int_key")" 2>/dev/null ;;
            ec)
                _run_openssl genpkey \
                    -algorithm EC \
                    -pkeyopt "ec_paramgen_curve:${INT_KEY_PARAM}" \
                    -out "$(_p "$int_key")" 2>/dev/null ;;
            ed25519)
                _run_openssl genpkey \
                    -algorithm ed25519 \
                    -out "$(_p "$int_key")" 2>/dev/null ;;
            *) die "Unknown key type '${INT_KEY_TYPE}'" ;;
        esac
        chmod 600 "$int_key"
        ok "Intermediate CA key generated: ${int_key}"
    fi

    # ---- 4. Intermediate CA CSR ----
    if [ -f "$int_csr" ]; then
        ok "Intermediate CSR already exists — skipping"
    else
        info "Generating intermediate CA CSR..."
        local int_subj="/C=${CERT_COUNTRY}/ST=${CERT_PROVINCE}/L=${CERT_CITY}/O=${CERT_ORG}/OU=Certificate Issuing Authority/CN=${CA_NAME} Intermediate CA"
        _run_openssl req -new \
            -key "$(_p "$int_key")" \
            -out "$(_p "$int_csr")" \
            -"${INT_DIGEST}" \
            -subj "$int_subj" \
            2>/dev/null
        ok "Intermediate CA CSR generated: ${int_csr}"
    fi

    # ---- 5. Sign intermediate CSR with root CA ----
    if [ -f "$int_crt" ]; then
        ok "Intermediate CA certificate already exists — skipping"
    else
        info "Signing intermediate CA certificate (${INT_CA_DAYS} days)..."
        # Write extension config into OUT_DIR so Docker can read it
        local ext_conf="${OUT_DIR}/_int_ext.cnf"
        cat > "$ext_conf" <<'EXTEOF'
[ext]
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always
EXTEOF
        _run_openssl x509 -req \
            -in "$(_p "$int_csr")" \
            -CA "$(_p "$root_crt")" \
            -CAkey "$(_p "$root_key")" \
            -CAcreateserial \
            -out "$(_p "$int_crt")" \
            -days "$INT_CA_DAYS" \
            -"${INT_DIGEST}" \
            -extfile "$(_p "$ext_conf")" \
            -extensions ext \
            2>/dev/null
        rm -f "$ext_conf"
        chmod 640 "$int_crt"
        ok "Intermediate CA certificate signed: ${int_crt}"
    fi

    # ---- 6. Verify chain ----
    info "Verifying certificate chain..."
    _run_openssl verify \
        -CAfile "$(_p "$root_crt")" \
        "$(_p "$int_crt")" >/dev/null 2>&1 \
        && ok "Chain verified: ${int_crt} → ${root_crt}" \
        || die "Chain verification FAILED"

    # ---- Summary ----
    echo ""
    echo -e "  ${BOLD}Fingerprints:${NC}"
    printf "    Root CA:        "
    _run_openssl x509 -in "$(_p "$root_crt")" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//'
    printf "    Intermediate:   "
    _run_openssl x509 -in "$(_p "$int_crt")" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//'
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
    echo -e "  ${CYAN}Add to custom-vars.yaml:${NC}"
    echo -e "  ${CYAN}  root_cert_path: ${root_crt}${NC}"
    echo -e "  ${CYAN}  intermediate_cert_path: ${int_crt}${NC}"
    echo ""
}

# -----------------------------------------------------------------------
# cmd_sign_certs — Sign a leaf CSR with the root CA
# -----------------------------------------------------------------------
cmd_sign_certs() {
    [ -z "$SIGN_CSR" ] && die "--sign-certs requires a CSR file path"
    [ -f "$SIGN_CSR" ]  || die "CSR file not found: ${SIGN_CSR}"

    _load_config

    # CA artifacts always come from root-ca/output (not overridable by --outpath here)
    local ca_dir="${ROOT_CA_DIR}/output"
    local root_crt="${ca_dir}/root_ca.crt"
    local root_key="${ca_dir}/root_ca.key"

    [ -f "$root_crt" ] || die "Root CA certificate not found: ${root_crt}
  Run './root-ca.sh init' first."
    [ -f "$root_key" ] || die "Root CA private key not found: ${root_key}
  The root CA key is required for signing."

    local csr_abs; csr_abs="$(realpath "$SIGN_CSR")"
    local csr_dir; csr_dir="$(dirname "$csr_abs")"
    local csr_file; csr_file="$(basename "$csr_abs")"
    local cert_name="${csr_file%.csr}.crt"

    # Output: --outpath, else the script's directory
    local sign_out="${FLAG_OUTPATH:-${SCRIPT_DIR}}"
    mkdir -p "$sign_out"
    local sign_out_real; sign_out_real="$(realpath "$sign_out")"
    local signed_cert="${sign_out_real}/${cert_name}"

    echo ""
    echo -e "  ${BOLD}core-template — Sign Certificate Request${NC}"
    echo ""
    echo "    CSR:       ${csr_abs}"
    echo "    Signed by: ${root_crt}"
    echo "    Validity:  ${LEAF_DAYS} days / ${ROOT_DIGEST}"
    echo "    Output:    ${signed_cert}"
    echo ""

    $USE_DOCKER && _ensure_docker_image
    ! $USE_DOCKER && { command -v openssl >/dev/null 2>&1 || die "openssl not found"; }

    # Write leaf extensions into ca_dir (Docker-accessible)
    local leaf_ext="${ca_dir}/_leaf_ext.cnf"
    cat > "$leaf_ext" <<'LEAFEOF'
[leaf]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always
LEAFEOF

    info "Signing certificate..."

    if $USE_DOCKER; then
        local vol_args=()
        vol_args+=("-v" "${ca_dir}:/pki/ca")
        vol_args+=("-v" "${sign_out_real}:/pki/output")

        # Mount CSR directory unless it's the same as ca_dir
        local csr_container_path
        if [ "$(realpath "$csr_dir")" = "$(realpath "$ca_dir")" ]; then
            csr_container_path="/pki/ca/${csr_file}"
        else
            vol_args+=("-v" "${csr_dir}:/pki/input:ro")
            csr_container_path="/pki/input/${csr_file}"
        fi

        docker run --rm \
            --user "$(id -u):$(id -g)" \
            "${vol_args[@]}" \
            "$DOCKER_IMAGE" \
            openssl x509 -req \
                -in "$csr_container_path" \
                -CA /pki/ca/root_ca.crt \
                -CAkey /pki/ca/root_ca.key \
                -CAcreateserial \
                -out "/pki/output/${cert_name}" \
                -days "$LEAF_DAYS" \
                -"${ROOT_DIGEST}" \
                -extfile /pki/ca/_leaf_ext.cnf \
                -extensions leaf \
                2>/dev/null \
        || { rm -f "$leaf_ext"; die "Certificate signing failed"; }

        docker run --rm \
            --user "$(id -u):$(id -g)" \
            -v "${ca_dir}:/pki/ca:ro" \
            -v "${sign_out_real}:/pki/output:ro" \
            "$DOCKER_IMAGE" \
            openssl verify \
                -CAfile /pki/ca/root_ca.crt \
                "/pki/output/${cert_name}" >/dev/null 2>&1 \
        && ok "Certificate verified against root CA" \
        || warn "Verification step failed — inspect manually"
    else
        openssl x509 -req \
            -in "$csr_abs" \
            -CA "$root_crt" \
            -CAkey "$root_key" \
            -CAcreateserial \
            -out "$signed_cert" \
            -days "$LEAF_DAYS" \
            -"${ROOT_DIGEST}" \
            -extfile "$leaf_ext" \
            -extensions leaf \
            2>/dev/null \
        || { rm -f "$leaf_ext"; die "Certificate signing failed"; }

        openssl verify -CAfile "$root_crt" "$signed_cert" >/dev/null 2>&1 \
            && ok "Certificate verified against root CA" \
            || warn "Verification step failed — inspect manually"
    fi

    rm -f "$leaf_ext"
    ok "Signed certificate: ${signed_cert}"
    echo ""
}

# -----------------------------------------------------------------------
# cmd_verify — Verify the certificate chain
# -----------------------------------------------------------------------
cmd_verify() {
    local ca_dir="${ROOT_CA_DIR}/output"
    local root_crt="${ca_dir}/root_ca.crt"
    local int_crt="${ca_dir}/intermediate_ca.crt"

    [ -f "$root_crt" ] || die "root_ca.crt not found in ${ca_dir}. Run: ./root-ca.sh init"
    [ -f "$int_crt"  ] || die "intermediate_ca.crt not found in ${ca_dir}. Run: ./root-ca.sh init"

    $USE_DOCKER && _ensure_docker_image

    echo ""
    info "Verifying: ${int_crt}"
    info "   Against: ${root_crt}"
    echo ""

    if $USE_DOCKER; then
        docker run --rm \
            --user "$(id -u):$(id -g)" \
            -v "${ca_dir}:/pki/ca:ro" \
            "$DOCKER_IMAGE" \
            openssl verify -CAfile /pki/ca/root_ca.crt /pki/ca/intermediate_ca.crt \
        && ok "Chain OK" \
        || { err "Chain verification FAILED"; exit 1; }
    else
        openssl verify -CAfile "$root_crt" "$int_crt" \
        && ok "Chain OK" \
        || { err "Chain verification FAILED"; exit 1; }
    fi
    echo ""
}

# -----------------------------------------------------------------------
# cmd_show — Print certificate details
# -----------------------------------------------------------------------
cmd_show() {
    local ca_dir="${ROOT_CA_DIR}/output"
    local grep_pat='(Subject:|Issuer:|Not Before|Not After|Public Key Algorithm|RSA Public-Key|Signature Algorithm)'
    echo ""
    for f in root_ca.crt intermediate_ca.crt; do
        local cert="${ca_dir}/${f}"
        if [ -f "$cert" ]; then
            echo -e "${BOLD}=== ${f} ===${NC}"
            if $USE_DOCKER; then
                docker run --rm \
                    --user "$(id -u):$(id -g)" \
                    -v "${ca_dir}:/pki/ca:ro" \
                    "$DOCKER_IMAGE" \
                    openssl x509 -in "/pki/ca/${f}" -noout -text 2>/dev/null \
                    | grep -E "$grep_pat"
            else
                openssl x509 -in "$cert" -noout -text 2>/dev/null \
                    | grep -E "$grep_pat"
            fi
            echo ""
        else
            warn "${f} not found in ${ca_dir}"
        fi
    done
}

# -----------------------------------------------------------------------
# cmd_help
# -----------------------------------------------------------------------
cmd_help() {
    sed -n '2,46p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
}

# -----------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------
case "${MODE}" in
    init)           cmd_init ;;
    verify)         cmd_verify ;;
    show)           cmd_show ;;
    sign-certs)     cmd_sign_certs ;;
    help|--help|-h) cmd_help ;;
    *) err "Unknown command: ${MODE}"; cmd_help; exit 1 ;;
esac
