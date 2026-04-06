#!/bin/bash
# tests/test-pki.sh — Comprehensive test suite for root-ca.sh and gen-csr.sh
#
# Usage:
#   cd <repo-root>
#   bash tests/test-pki.sh
#
# Requirements: openssl in PATH, python3 + PyYAML
# Docker tests are automatically skipped when Docker is unavailable.

set -uo pipefail   # no -e: individual test failures must not abort the suite

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT_CA_SH="${REPO}/root-ca.sh"
GEN_CSR_SH="${REPO}/gen-csr.sh"
ROOT_CA_OUT="${REPO}/root-ca/output"

# ─── Counters ────────────────────────────────────────────────────────────────
PASS=0; FAIL=0; SKIP=0
declare -a FAILURES=()

_p() { (( PASS++ )) || true; }
_f() { (( FAIL++ )) || true; FAILURES+=("$1"); }

pass()  { echo "  PASS  $1"; _p; }
fail()  { echo "  FAIL  $1"; _f "$1"; }
skip()  { echo "  SKIP  $1 ($2)"; (( SKIP++ )) || true; }

# t_ok NAME cmd...   — expects exit 0
t_ok() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi
}

# t_fail NAME cmd...  — expects non-zero exit
t_fail() {
    local name="$1"; shift
    if ! "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi
}

# t_ok_in NAME needle cmd...  — expects exit 0 and needle in stdout+stderr
t_ok_in() {
    local name="$1" needle="$2"; shift 2
    local out; out="$("$@" 2>&1)" || true
    if echo "$out" | grep -q "$needle"; then pass "$name"; else fail "$name — expected '${needle}' in output"; fi
}

# t_fail_in NAME needle cmd...  — expects non-zero AND needle in stderr
t_fail_in() {
    local name="$1" needle="$2"; shift 2
    local out ec=0
    out="$("$@" 2>&1)" || ec=$?
    if [[ $ec -ne 0 ]] && echo "$out" | grep -q "$needle"; then
        pass "$name"
    else
        fail "$name — expected failure with '${needle}'"
    fi
}

# t_file NAME path  — expects file to exist and be non-empty
t_file() {
    local name="$1" path="$2"
    if [[ -f "$path" && -s "$path" ]]; then pass "$name"; else fail "$name — missing: ${path}"; fi
}

# stdin_ok NAME stdin_data cmd...  — pipes stdin_data, expects exit 0
stdin_ok() {
    local name="$1" data="$2"; shift 2
    if printf '%b' "$data" | "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi
}

# stdin_ok_in NAME stdin_data needle cmd...
stdin_ok_in() {
    local name="$1" data="$2" needle="$3"; shift 3
    local out; out="$(printf '%b' "$data" | "$@" 2>&1)" || true
    if echo "$out" | grep -q "$needle"; then pass "$name"; else fail "$name — expected '${needle}'"; fi
}

# ─── Common identity flags ────────────────────────────────────────────────────
# Supply all identity fields to bypass interactive prompts in root-ca.sh init.
# _determine_key_source still runs when no key exists — needs "1\n" prepended.
IDENT=(
    --ca-name "Test Lab CA"
    --country "US" --province "TestState" --city "TestCity"
    --org "TestOrg" --ou "TestOU"
    --no-docker
)

# init stdin when generating a new key:  "1\ny\n" (key-source choice + confirm)
# init stdin when --key provided:        "y\n"   (just confirm)
INIT_STDIN_NEW="1\ny\n"
INIT_STDIN_KEY="y\n"

# ─── CA population helpers (verify/show/sign-certs use root-ca/output) ───────
pki_install() {
    local src="$1"
    mkdir -p "$ROOT_CA_OUT"
    cp "$src/root_ca.crt"         "$ROOT_CA_OUT/"
    cp "$src/root_ca.key"         "$ROOT_CA_OUT/"
    cp "$src/intermediate_ca.crt" "$ROOT_CA_OUT/"
    cp "$src/intermediate_ca.key" "$ROOT_CA_OUT/"
    cp "$src/intermediate.csr"    "$ROOT_CA_OUT/" 2>/dev/null || true
    cp "$src/root_ca.srl"         "$ROOT_CA_OUT/" 2>/dev/null || true
}

pki_clean() {
    rm -rf "$ROOT_CA_OUT"
}

# ─── Temp dir management ─────────────────────────────────────────────────────
declare -a TMPDIRS=()
new_tmp() { local d; d="$(mktemp -d)"; TMPDIRS+=("$d"); echo "$d"; }

cleanup_all() {
    pki_clean
    for d in "${TMPDIRS[@]+"${TMPDIRS[@]}"}"; do rm -rf "$d"; done
}
trap cleanup_all EXIT

# ─── Shared CA (generated once; reused for verify/show/sign tests) ───────────
SHARED_CA=""

setup_shared_ca() {
    SHARED_CA="$(new_tmp)"
    echo "  Generating shared RSA-2048 CA for verify/show/sign tests…"
    if ! printf '%b' "$INIT_STDIN_NEW" \
            | "${ROOT_CA_SH}" init "${IDENT[@]}" \
                --key-type rsa --key-param 2048 \
                --root-days 30 --int-days 15 \
                --outpath "$SHARED_CA" \
            >/dev/null 2>&1; then
        echo "  FATAL: shared CA generation failed — cannot continue."
        exit 1
    fi
    echo "  Shared CA ready."
    echo ""
}

# ─── Section header ───────────────────────────────────────────────────────────
section() { echo ""; echo "  ── $* ──────────────────────────────────────────────────────────"; echo ""; }

# =============================================================================
echo ""
echo "  ════════════════════════════════════════════════════════════"
echo "  PKI Test Suite  —  $(date)"
echo "  ════════════════════════════════════════════════════════════"
echo ""

setup_shared_ca

# =============================================================================
section "1. Help / Usage"

t_ok_in  "root-ca.sh help"          "root-ca.sh"    "${ROOT_CA_SH}" help
t_ok_in  "root-ca.sh --help"        "root-ca.sh"    "${ROOT_CA_SH}" --help
t_ok_in  "root-ca.sh -h"            "root-ca.sh"    "${ROOT_CA_SH}" -h
t_ok_in  "gen-csr.sh --help"        "gen-csr.sh"    "${GEN_CSR_SH}" --help
t_ok_in  "gen-csr.sh -h"            "gen-csr.sh"    "${GEN_CSR_SH}" -h

# =============================================================================
section "2. root-ca.sh init — Key Types"

# RSA 2048
T="$(new_tmp)"
stdin_ok "init RSA 2048 exits 0" "$INIT_STDIN_NEW" \
    "${ROOT_CA_SH}" init "${IDENT[@]}" --key-type rsa --key-param 2048 --root-days 30 --int-days 15 --outpath "$T"
t_file "init RSA 2048 — root_ca.key"         "$T/root_ca.key"
t_file "init RSA 2048 — root_ca.crt"         "$T/root_ca.crt"
t_file "init RSA 2048 — intermediate_ca.key" "$T/intermediate_ca.key"
t_file "init RSA 2048 — intermediate_ca.crt" "$T/intermediate_ca.crt"

# RSA 4096
T="$(new_tmp)"
stdin_ok "init RSA 4096 exits 0" "$INIT_STDIN_NEW" \
    "${ROOT_CA_SH}" init "${IDENT[@]}" --key-type rsa --key-param 4096 --root-days 30 --int-days 15 --outpath "$T"
t_file "init RSA 4096 — root_ca.crt" "$T/root_ca.crt"

# EC P-256
T="$(new_tmp)"
stdin_ok "init EC P-256 exits 0" "$INIT_STDIN_NEW" \
    "${ROOT_CA_SH}" init "${IDENT[@]}" --key-type ec --key-param P-256 --root-days 30 --int-days 15 --outpath "$T"
t_file "init EC P-256 — root_ca.crt" "$T/root_ca.crt"
t_file "init EC P-256 — intermediate_ca.crt" "$T/intermediate_ca.crt"

# EC P-384
T="$(new_tmp)"
stdin_ok "init EC P-384 exits 0" "$INIT_STDIN_NEW" \
    "${ROOT_CA_SH}" init "${IDENT[@]}" --key-type ec --key-param P-384 --root-days 30 --int-days 15 --outpath "$T"
t_file "init EC P-384 — root_ca.crt" "$T/root_ca.crt"

# EC P-521
T="$(new_tmp)"
stdin_ok "init EC P-521 exits 0" "$INIT_STDIN_NEW" \
    "${ROOT_CA_SH}" init "${IDENT[@]}" --key-type ec --key-param P-521 --root-days 30 --int-days 15 --outpath "$T"
t_file "init EC P-521 — root_ca.crt" "$T/root_ca.crt"

# Ed25519 (no meaningful --key-param for ed25519; just pass "na" for display)
T="$(new_tmp)"
stdin_ok "init Ed25519 exits 0" "$INIT_STDIN_NEW" \
    "${ROOT_CA_SH}" init "${IDENT[@]}" --key-type ed25519 --key-param na --root-days 30 --int-days 15 --outpath "$T"
t_file "init Ed25519 — root_ca.crt" "$T/root_ca.crt"
t_file "init Ed25519 — intermediate_ca.crt" "$T/intermediate_ca.crt"

# =============================================================================
section "3. root-ca.sh init — Digest Variants"

T="$(new_tmp)"
stdin_ok "init digest sha384" "$INIT_STDIN_NEW" \
    "${ROOT_CA_SH}" init "${IDENT[@]}" --key-type rsa --key-param 2048 --digest sha384 --root-days 30 --int-days 15 --outpath "$T"
t_file "init sha384 — root_ca.crt" "$T/root_ca.crt"

T="$(new_tmp)"
stdin_ok "init digest sha512" "$INIT_STDIN_NEW" \
    "${ROOT_CA_SH}" init "${IDENT[@]}" --key-type rsa --key-param 2048 --digest sha512 --root-days 30 --int-days 15 --outpath "$T"
t_file "init sha512 — root_ca.crt" "$T/root_ca.crt"

# =============================================================================
section "4. root-ca.sh init — Custom Validity"

T="$(new_tmp)"
stdin_ok "init custom root/int days" "$INIT_STDIN_NEW" \
    "${ROOT_CA_SH}" init "${IDENT[@]}" --key-type rsa --key-param 2048 \
    --root-days 3650 --int-days 1825 --outpath "$T"
# Verify root cert validity is actually ~3650 days
t_ok "init custom validity — root cert enddate" \
    bash -c "openssl x509 -in '$T/root_ca.crt' -noout -enddate 2>/dev/null | grep -q ."

# =============================================================================
section "5. root-ca.sh init — Provided --key"

# RSA key provided
K_DIR="$(new_tmp)"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$K_DIR/rsa.key" 2>/dev/null
T="$(new_tmp)"
stdin_ok "init --key RSA exits 0" "$INIT_STDIN_KEY" \
    "${ROOT_CA_SH}" init "${IDENT[@]}" --key "$K_DIR/rsa.key" --root-days 30 --int-days 15 --outpath "$T"
t_file "init --key RSA — root_ca.crt" "$T/root_ca.crt"

# EC key provided
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$K_DIR/ec.key" 2>/dev/null
T="$(new_tmp)"
stdin_ok "init --key EC exits 0" "$INIT_STDIN_KEY" \
    "${ROOT_CA_SH}" init "${IDENT[@]}" --key "$K_DIR/ec.key" --root-days 30 --int-days 15 --outpath "$T"
t_file "init --key EC — root_ca.crt" "$T/root_ca.crt"

# Ed25519 key provided
openssl genpkey -algorithm ed25519 -out "$K_DIR/ed25519.key" 2>/dev/null
T="$(new_tmp)"
stdin_ok "init --key Ed25519 exits 0" "$INIT_STDIN_KEY" \
    "${ROOT_CA_SH}" init "${IDENT[@]}" --key "$K_DIR/ed25519.key" --root-days 30 --int-days 15 --outpath "$T"
t_file "init --key Ed25519 — root_ca.crt" "$T/root_ca.crt"

# =============================================================================
section "6. root-ca.sh init — Idempotent (second run skips existing files)"

T="$(new_tmp)"
# First run
printf '%b' "$INIT_STDIN_NEW" \
    | "${ROOT_CA_SH}" init "${IDENT[@]}" --key-type rsa --key-param 2048 --root-days 30 --int-days 15 --outpath "$T" \
    >/dev/null 2>&1 || true
# Record root cert mtime
MTIME1="$(stat -c '%Y' "$T/root_ca.crt" 2>/dev/null || echo "0")"
sleep 1
# Second run — key already exists in OUT_DIR, so _determine_key_source returns immediately → stdin is just "y\n"
stdin_ok "init idempotent — second run exits 0" "$INIT_STDIN_KEY" \
    "${ROOT_CA_SH}" init "${IDENT[@]}" --key-type rsa --key-param 2048 --root-days 30 --int-days 15 --outpath "$T"
MTIME2="$(stat -c '%Y' "$T/root_ca.crt" 2>/dev/null || echo "1")"
if [[ "$MTIME1" == "$MTIME2" ]]; then
    pass "init idempotent — root_ca.crt not overwritten"
else
    fail "init idempotent — root_ca.crt was overwritten"
fi

# =============================================================================
section "7. root-ca.sh init — Edit Flow (decline then accept)"

T="$(new_tmp)"
# _determine_key_source runs before the confirmation loop and reads key source once.
# stdin: 1 (generate new key) → n (decline summary) → 14 field accepts → y (confirm)
# Note: _recollect_init key source loop exits immediately (empty grep pattern always matches)
# so it reads ZERO lines for key choice; only the 14 field prompts consume stdin.
EDIT_STDIN="1\nn\n\n\n\n\n\n\n\n\n\n\n\n\n\n\ny\n"
stdin_ok "init edit-flow exits 0" "$EDIT_STDIN" \
    "${ROOT_CA_SH}" init "${IDENT[@]}" --key-type rsa --key-param 2048 --root-days 30 --int-days 15 --outpath "$T"
t_file "init edit-flow — root_ca.crt" "$T/root_ca.crt"

# =============================================================================
section "8. root-ca.sh verify"

pki_install "$SHARED_CA"
stdin_ok_in "verify chain OK" "" "Chain OK" \
    "${ROOT_CA_SH}" verify --no-docker
pki_clean

# =============================================================================
section "9. root-ca.sh show"

pki_install "$SHARED_CA"
stdin_ok_in "show — Subject in output" "" "Subject" \
    "${ROOT_CA_SH}" show --no-docker
pki_clean

# =============================================================================
section "10. root-ca.sh --sign-certs"

# Generate a leaf CSR for signing tests
CSR_DIR="$(new_tmp)"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$CSR_DIR/leaf.key" 2>/dev/null
openssl req -new -key "$CSR_DIR/leaf.key" -out "$CSR_DIR/leaf.csr" \
    -subj "/CN=test.leaf.home" 2>/dev/null

SIGN_STDIN="y\n"

# Basic sign
pki_install "$SHARED_CA"
OUT_SIGN="$(new_tmp)"
stdin_ok "sign-certs basic exits 0" "$SIGN_STDIN" \
    "${ROOT_CA_SH}" --sign-certs "$CSR_DIR/leaf.csr" --outpath "$OUT_SIGN" --no-docker
t_file "sign-certs basic — leaf.crt" "$OUT_SIGN/leaf.crt"
pki_clean

# Verify signed cert chains back to root
pki_install "$SHARED_CA"
OUT_SIGN2="$(new_tmp)"
printf '%b' "$SIGN_STDIN" | "${ROOT_CA_SH}" --sign-certs "$CSR_DIR/leaf.csr" --outpath "$OUT_SIGN2" --no-docker >/dev/null 2>&1 || true
t_ok "sign-certs — openssl verify against root" \
    openssl verify -CAfile "$SHARED_CA/root_ca.crt" "$OUT_SIGN2/leaf.crt"
pki_clean

# Custom --leaf-days
pki_install "$SHARED_CA"
OUT_SIGN3="$(new_tmp)"
stdin_ok "sign-certs --leaf-days 90 exits 0" "$SIGN_STDIN" \
    "${ROOT_CA_SH}" --sign-certs "$CSR_DIR/leaf.csr" --outpath "$OUT_SIGN3" --leaf-days 90 --no-docker
t_file "sign-certs --leaf-days 90 — leaf.crt" "$OUT_SIGN3/leaf.crt"
pki_clean

# Custom --digest
pki_install "$SHARED_CA"
OUT_SIGN4="$(new_tmp)"
stdin_ok "sign-certs --digest sha384 exits 0" "$SIGN_STDIN" \
    "${ROOT_CA_SH}" --sign-certs "$CSR_DIR/leaf.csr" --outpath "$OUT_SIGN4" --digest sha384 --no-docker
t_file "sign-certs --digest sha384 — leaf.crt" "$OUT_SIGN4/leaf.crt"
pki_clean

# Default outpath (should land in SCRIPT_DIR = REPO root)
pki_install "$SHARED_CA"
rm -f "$REPO/leaf.crt"
stdin_ok "sign-certs default outpath exits 0" "$SIGN_STDIN" \
    "${ROOT_CA_SH}" --sign-certs "$CSR_DIR/leaf.csr" --no-docker
t_file "sign-certs default outpath — leaf.crt in REPO" "$REPO/leaf.crt"
rm -f "$REPO/leaf.crt"
pki_clean

# Edit flow for sign-certs: decline → accept 3 fields (leaf-days, digest, outpath) → confirm
pki_install "$SHARED_CA"
OUT_SIGN5="$(new_tmp)"
# stdin: n → leaf_days (enter) → digest (enter) → outpath (enter real path) → y
SIGN_EDIT_STDIN="n\n\n\n${OUT_SIGN5}\ny\n"
stdin_ok "sign-certs edit-flow exits 0" "$SIGN_EDIT_STDIN" \
    "${ROOT_CA_SH}" --sign-certs "$CSR_DIR/leaf.csr" --no-docker
t_file "sign-certs edit-flow — leaf.crt" "$OUT_SIGN5/leaf.crt"
pki_clean

# =============================================================================
section "11. gen-csr.sh — Basic"

CSR_BASIC="$(new_tmp)"

# --cn and --san provided → stdin just confirms
stdin_ok "gen-csr --cn --san exits 0" "y\n" \
    "${GEN_CSR_SH}" --cn test.home --san "DNS:test.home,IP:192.168.1.1" --outpath "$CSR_BASIC" --no-docker
t_file "gen-csr --cn --san — test.home.key" "$CSR_BASIC/test.home.key"
t_file "gen-csr --cn --san — test.home.csr" "$CSR_BASIC/test.home.csr"

# --cn only (no --san) → SAN prompt needs empty line before confirm
CSR_BASIC2="$(new_tmp)"
stdin_ok "gen-csr --cn only exits 0" "\ny\n" \
    "${GEN_CSR_SH}" --cn nowan.home --outpath "$CSR_BASIC2" --no-docker
t_file "gen-csr --cn only — nowan.home.csr" "$CSR_BASIC2/nowan.home.csr"

# Interactive CN input (no --cn flag) → type CN, empty SAN, confirm
CSR_BASIC3="$(new_tmp)"
stdin_ok "gen-csr interactive CN exits 0" "interactive.home\n\ny\n" \
    "${GEN_CSR_SH}" --outpath "$CSR_BASIC3" --no-docker
t_file "gen-csr interactive CN — interactive.home.csr" "$CSR_BASIC3/interactive.home.csr"

# =============================================================================
section "12. gen-csr.sh — Key Types"

# EC P-256
T="$(new_tmp)"
stdin_ok "gen-csr key-type EC P-256" "y\n" \
    "${GEN_CSR_SH}" --cn ec256.home --san "DNS:ec256.home" --key-type ec --key-param P-256 --outpath "$T" --no-docker
t_file "gen-csr EC P-256 — ec256.home.csr" "$T/ec256.home.csr"

# EC P-384
T="$(new_tmp)"
stdin_ok "gen-csr key-type EC P-384" "y\n" \
    "${GEN_CSR_SH}" --cn ec384.home --san "DNS:ec384.home" --key-type ec --key-param P-384 --outpath "$T" --no-docker
t_file "gen-csr EC P-384 — ec384.home.csr" "$T/ec384.home.csr"

# Ed25519
T="$(new_tmp)"
stdin_ok "gen-csr key-type Ed25519" "y\n" \
    "${GEN_CSR_SH}" --cn ed25519svc.home --san "DNS:ed25519svc.home" --key-type ed25519 --key-param na --outpath "$T" --no-docker
t_file "gen-csr Ed25519 — ed25519svc.home.csr" "$T/ed25519svc.home.csr"

# RSA 4096
T="$(new_tmp)"
stdin_ok "gen-csr key-type RSA 4096" "y\n" \
    "${GEN_CSR_SH}" --cn rsa4096.home --san "DNS:rsa4096.home" --key-type rsa --key-param 4096 --outpath "$T" --no-docker
t_file "gen-csr RSA 4096 — rsa4096.home.csr" "$T/rsa4096.home.csr"

# sha384 digest
T="$(new_tmp)"
stdin_ok "gen-csr digest sha384" "y\n" \
    "${GEN_CSR_SH}" --cn sha384svc.home --san "DNS:sha384svc.home" --digest sha384 --outpath "$T" --no-docker
t_file "gen-csr sha384 — sha384svc.home.csr" "$T/sha384svc.home.csr"

# =============================================================================
section "13. gen-csr.sh — Provided --key"

LEAF_KEYS="$(new_tmp)"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$LEAF_KEYS/ext_rsa.key" 2>/dev/null
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$LEAF_KEYS/ext_ec.key" 2>/dev/null

T="$(new_tmp)"
stdin_ok "gen-csr --key RSA exits 0" "y\n" \
    "${GEN_CSR_SH}" --cn provided-rsa.home --san "DNS:provided-rsa.home" \
        --key "$LEAF_KEYS/ext_rsa.key" --outpath "$T" --no-docker
t_file "gen-csr --key RSA — provided-rsa.home.csr" "$T/provided-rsa.home.csr"

T="$(new_tmp)"
stdin_ok "gen-csr --key EC exits 0" "y\n" \
    "${GEN_CSR_SH}" --cn provided-ec.home --san "DNS:provided-ec.home" \
        --key "$LEAF_KEYS/ext_ec.key" --outpath "$T" --no-docker
t_file "gen-csr --key EC — provided-ec.home.csr" "$T/provided-ec.home.csr"

# =============================================================================
section "14. gen-csr.sh — --root-cert context display"

T="$(new_tmp)"
pki_install "$SHARED_CA"
stdin_ok_in "gen-csr --root-cert valid — shows subject" "y\n" "subject" \
    "${GEN_CSR_SH}" --cn ctx.home --san "DNS:ctx.home" \
        --root-cert "$ROOT_CA_OUT/root_ca.crt" --outpath "$T" --no-docker
pki_clean

T="$(new_tmp)"
# Missing --root-cert path — should still succeed (warn only), CSR generated
stdin_ok "gen-csr --root-cert missing — exits 0" "y\n" \
    "${GEN_CSR_SH}" --cn ctx-miss.home --san "DNS:ctx-miss.home" \
        --root-cert "/tmp/nonexistent-root-ca.crt" --outpath "$T" --no-docker
t_file "gen-csr --root-cert missing — ctx-miss.home.csr" "$T/ctx-miss.home.csr"

# =============================================================================
section "15. gen-csr.sh — CSR Regen"

T="$(new_tmp)"
# First run — create key + CSR
printf '%b' "y\n" | "${GEN_CSR_SH}" --cn regen.home --san "DNS:regen.home" \
    --outpath "$T" --no-docker >/dev/null 2>&1 || true

# Second run with regen=yes
stdin_ok "gen-csr regen CSR yes exits 0" "y\ny\n" \
    "${GEN_CSR_SH}" --cn regen.home --san "DNS:regen.home" --outpath "$T" --no-docker
t_file "gen-csr regen yes — regen.home.csr" "$T/regen.home.csr"

# Third run with regen=no (should exit 0 and keep existing CSR)
MTIME_CSR="$(stat -c '%Y' "$T/regen.home.csr" 2>/dev/null || echo "0")"
sleep 1
stdin_ok "gen-csr regen CSR no exits 0" "y\nn\n" \
    "${GEN_CSR_SH}" --cn regen.home --san "DNS:regen.home" --outpath "$T" --no-docker
MTIME_CSR2="$(stat -c '%Y' "$T/regen.home.csr" 2>/dev/null || echo "1")"
if [[ "$MTIME_CSR" == "$MTIME_CSR2" ]]; then
    pass "gen-csr regen no — CSR unchanged"
else
    fail "gen-csr regen no — CSR was modified"
fi

# =============================================================================
section "16. gen-csr.sh — Edit Flow"

T="$(new_tmp)"
# Decline, then accept all 7 field defaults: CN, SAN, key-type, key-param, digest, key-choice (c = keep), outpath
# Since there's no existing key, choices are a/b/c — send 'a' (generate new)
EDIT_CSR_STDIN="n\n\n\n\n\n\na\n${T}\ny\n"
stdin_ok "gen-csr edit-flow exits 0" "$EDIT_CSR_STDIN" \
    "${GEN_CSR_SH}" --cn edit-flow.home --san "DNS:edit-flow.home" --outpath "$T" --no-docker
t_file "gen-csr edit-flow — edit-flow.home.csr" "$T/edit-flow.home.csr"

# =============================================================================
section "17. Full Pipeline — gen-csr → sign-certs → verify"

pki_install "$SHARED_CA"
PIPE_DIR="$(new_tmp)"

# Step 1: generate CSR
printf '%b' "y\n" | "${GEN_CSR_SH}" \
    --cn pipeline.home --san "DNS:pipeline.home,IP:192.168.100.1" \
    --outpath "$PIPE_DIR" --no-docker >/dev/null 2>&1 || true

t_file "pipeline — CSR generated" "$PIPE_DIR/pipeline.home.csr"

# Step 2: sign CSR
printf '%b' "y\n" | "${ROOT_CA_SH}" \
    --sign-certs "$PIPE_DIR/pipeline.home.csr" --outpath "$PIPE_DIR" --leaf-days 90 --no-docker \
    >/dev/null 2>&1 || true

t_file "pipeline — signed cert generated" "$PIPE_DIR/pipeline.home.crt"

# Step 3: verify signed cert chains to root
t_ok "pipeline — openssl verify against root" \
    openssl verify -CAfile "$SHARED_CA/root_ca.crt" "$PIPE_DIR/pipeline.home.crt"

# Step 4: check leaf extensions (CA:FALSE)
t_ok_in "pipeline — cert is not a CA" "CA:FALSE" \
    openssl x509 -in "$PIPE_DIR/pipeline.home.crt" -noout -text

pki_clean

# =============================================================================
section "18. Error Cases"

# Unknown subcommand — root-ca.sh falls back to help (exits 0), prints error to stderr
t_ok_in "error — unknown subcommand prints error message" "Unknown argument" \
    "${ROOT_CA_SH}" boguscommand

# Unknown flag for root-ca.sh — same: falls back to help, exits 0
t_ok_in "error — root-ca.sh unknown flag prints error" "Unknown argument" \
    "${ROOT_CA_SH}" init --nonexistent-flag somevalue

# Unknown flag for gen-csr.sh — gen-csr calls die(), exits 1
t_fail_in "error — gen-csr.sh unknown flag exits non-zero" "Unknown argument" \
    "${GEN_CSR_SH}" --totally-fake-flag

# Missing CSR file for --sign-certs
pki_install "$SHARED_CA"
t_fail_in "error — sign-certs missing CSR" "CSR file not found" \
    "${ROOT_CA_SH}" --sign-certs /tmp/nonexistent-pki-XXXXXX.csr --no-docker
pki_clean

# sign-certs when root CA not initialised (no root-ca/output/)
pki_clean
DUMMY_CSR="$(new_tmp)/dummy.csr"
openssl req -new -newkey rsa:2048 -nodes -keyout /dev/null -out "$DUMMY_CSR" -subj "/CN=dummy" 2>/dev/null || true
if [[ -f "$DUMMY_CSR" ]]; then
    t_fail_in "error — sign-certs no root CA" "Root CA certificate not found" \
        "${ROOT_CA_SH}" --sign-certs "$DUMMY_CSR" --no-docker
else
    skip "error — sign-certs no root CA" "could not create dummy CSR"
fi

# =============================================================================
section "19. Docker Tests (skip when daemon unavailable)"

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    T="$(new_tmp)"
    stdin_ok "init with Docker (image auto-build)" "$INIT_STDIN_NEW" \
        "${ROOT_CA_SH}" init "${IDENT[@]/--no-docker}" --key-type rsa --key-param 2048 \
        --root-days 30 --int-days 15 --outpath "$T"
    t_file "init with Docker — root_ca.crt" "$T/root_ca.crt"
else
    skip "init via Docker" "Docker daemon unavailable"
    skip "gen-csr via Docker" "Docker daemon unavailable"
fi

# =============================================================================
section "Summary"

TOTAL=$(( PASS + FAIL + SKIP ))
echo "  Tests run:  ${TOTAL}"
echo "  Passed:     ${PASS}"
echo "  Failed:     ${FAIL}"
echo "  Skipped:    ${SKIP}"
echo ""

if (( ${#FAILURES[@]} > 0 )); then
    echo "  Failed tests:"
    for f in "${FAILURES[@]}"; do
        echo "    ✗ ${f}"
    done
    echo ""
    exit 1
else
    echo "  All tests passed."
    echo ""
    exit 0
fi
