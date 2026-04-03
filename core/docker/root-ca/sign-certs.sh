#!/bin/sh
# sign-certs.sh — Root CA signing entrypoint
#
# Subcommands:
#   sign-intermediate --csr <path> --days <n> --out <path> --subject <dn>
#   sign-leaf         --cn <name> --days <n> --out <path> [--san <value>...]
#   verify            --cert <path>
#
# Environment (set at image build time):
#   ROOT_CA_CRT  — path to root CA certificate inside container
#   ROOT_CA_KEY  — path to root CA private key (mounted at runtime via --mount secret)
#
# Mount strategy:
#   /history  — persistent signed-cert log  (bind-mount from host)
#   /revokes  — persistent revocation log   (bind-mount from host)
#   /out      — output directory            (writable, per-operation bind-mount)
#   /secrets/root_ca.key — root CA key      (bind-mounted read-only at runtime)

set -euo pipefail

ROOT_CA_CRT="${ROOT_CA_CRT:-/ca/root_ca.crt}"
ROOT_CA_KEY="${ROOT_CA_KEY:-/secrets/root_ca.key}"
HISTORY_DIR="/history"
REVOKES_DIR="/revokes"
OUT_DIR="/out"

_require_file() { [ -f "$1" ] || { echo "ERROR: required file not found: $1"; exit 1; }; }
_require_dir()  { [ -d "$1" ] || { echo "ERROR: required directory not found: $1"; exit 1; }; }

_log_signed() {
    local label="$1" cert="$2"
    mkdir -p "$HISTORY_DIR"
    local entry; entry="$(date -u '+%Y-%m-%dT%H:%M:%SZ') signed ${label}"
    echo "$entry" >> "$HISTORY_DIR/signed.log"
    cp "$cert" "$HISTORY_DIR/$(date -u '+%Y%m%d_%H%M%S')_${label}.crt" 2>/dev/null || true
}

cmd_sign_intermediate() {
    local csr_path="" days=5475 out_path="" subject=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --csr)    csr_path="$2"; shift 2 ;;
            --days)   days="$2";    shift 2 ;;
            --out)    out_path="$2"; shift 2 ;;
            --subject) subject="$2"; shift 2 ;;
            *) echo "Unknown arg: $1"; exit 1 ;;
        esac
    done

    [ -n "$csr_path" ] || { echo "ERROR: --csr required"; exit 1; }
    [ -n "$out_path" ] || { echo "ERROR: --out required"; exit 1; }
    _require_file "$csr_path"
    _require_file "$ROOT_CA_CRT"
    _require_file "$ROOT_CA_KEY"
    _require_dir  "$OUT_DIR"

    echo "Signing intermediate CA CSR..."
    openssl x509 -req \
        -in "$csr_path" \
        -CA "$ROOT_CA_CRT" \
        -CAkey "$ROOT_CA_KEY" \
        -CAcreateserial \
        -out "$out_path" \
        -days "$days" \
        -sha256 \
        -extfile /ca/intermediate_ext.cnf

    openssl verify -CAfile "$ROOT_CA_CRT" "$out_path"
    _log_signed "intermediate_ca" "$out_path"
    echo "Intermediate CA certificate written to: $out_path"
}

cmd_sign_leaf() {
    local cn="" days=5475 out_path="" san_args=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --cn)   cn="$2";       shift 2 ;;
            --days) days="$2";     shift 2 ;;
            --out)  out_path="$2"; shift 2 ;;
            --san)  san_args="${san_args}DNS:${2},"; shift 2 ;;
            *) echo "Unknown arg: $1"; exit 1 ;;
        esac
    done

    [ -n "$cn" ]       || { echo "ERROR: --cn required";  exit 1; }
    [ -n "$out_path" ] || { echo "ERROR: --out required"; exit 1; }
    _require_file "$ROOT_CA_CRT"
    _require_file "$ROOT_CA_KEY"
    _require_dir  "$OUT_DIR"

    local key_out="${out_path%.crt}.key"

    # Generate leaf key
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$key_out"

    # Build SAN extension
    local san_value="DNS:${cn}"
    [ -n "$san_args" ] && san_value="${san_value},${san_args%,}"

    # Generate CSR
    openssl req -new -key "$key_out" \
        -subj "/CN=${cn}" \
        -out "/tmp/leaf_${cn}.csr"

    # Sign
    openssl x509 -req \
        -in "/tmp/leaf_${cn}.csr" \
        -CA "$ROOT_CA_CRT" \
        -CAkey "$ROOT_CA_KEY" \
        -CAcreateserial \
        -out "$out_path" \
        -days "$days" \
        -sha256 \
        -extfile /dev/stdin <<EOF
subjectAltName = ${san_value}
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
EOF

    chmod 600 "$key_out"
    _log_signed "leaf_${cn}" "$out_path"
    echo "Leaf certificate written to: $out_path"
    echo "Leaf key written to:         $key_out"
}

cmd_verify() {
    local cert_path=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --cert) cert_path="$2"; shift 2 ;;
            *) echo "Unknown arg: $1"; exit 1 ;;
        esac
    done
    [ -n "$cert_path" ] || { echo "ERROR: --cert required"; exit 1; }
    _require_file "$cert_path"
    _require_file "$ROOT_CA_CRT"
    openssl verify -CAfile "$ROOT_CA_CRT" "$cert_path"
}

cmd_help() {
    cat <<'HELP'
root-ca signing container

Subcommands:
  sign-intermediate --csr <path> --days <n> --out <path>
  sign-leaf         --cn <name>  --days <n> --out <path> [--san <value>...]
  verify            --cert <path>

Mount points:
  /history  — persistent signed-cert log (bind-mount rw)
  /revokes  — revocation log             (bind-mount rw)
  /out      — per-operation output dir   (bind-mount rw)
  /secrets/root_ca.key — root CA key     (bind-mount ro)
HELP
}

case "${1:-help}" in
    sign-intermediate) shift; cmd_sign_intermediate "$@" ;;
    sign-leaf)         shift; cmd_sign_leaf "$@" ;;
    verify)            shift; cmd_verify "$@" ;;
    --version|version) echo "root-ca:local" ;;
    help|--help)       cmd_help ;;
    *) echo "Unknown subcommand: $1"; cmd_help; exit 1 ;;
esac
