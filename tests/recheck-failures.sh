#!/bin/bash
# Minimal recheck for the 8 previously-failing tests
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_CA_SH="${REPO}/root-ca.sh"
GEN_CSR_SH="${REPO}/gen-csr.sh"
ROOT_CA_OUT="${REPO}/root-ca/output"

PASS=0; FAIL=0
fail() { echo "  FAIL $1"; (( FAIL++ )) || true; }
pass() { echo "  PASS $1"; (( PASS++ )) || true; }

IDENT=(--ca-name "Test Lab CA" --country US --province TS --city TC --org TO --ou TOU --no-docker)

T_CA=$(mktemp -d)

# Build shared CA for tests
printf '%b' "1\ny\n" | "${ROOT_CA_SH}" init "${IDENT[@]}" \
  --key-type rsa --key-param 2048 --root-days 30 --int-days 15 --outpath "$T_CA" \
  >/dev/null 2>&1 || { echo "FATAL: CA gen failed"; exit 1; }

# ── Test 1+2: init edit-flow ──
T_EDIT=$(mktemp -d)
printf '%b' "1\nn\n\n\n\n\n\n\n\n\n\n\n\n\n\n\ny\n" | "${ROOT_CA_SH}" init "${IDENT[@]}" \
  --key-type rsa --key-param 2048 --root-days 30 --int-days 15 --outpath "$T_EDIT" \
  >/dev/null 2>&1 && pass "init edit-flow exits 0" || fail "init edit-flow exits 0"
[[ -s "$T_EDIT/root_ca.crt" ]] && pass "init edit-flow — root_ca.crt" || fail "init edit-flow — root_ca.crt"
rm -rf "$T_EDIT"

# ── Test 3: gen-csr --root-cert shows subject (lowercase in OpenSSL 3.x) ──
T_CSR=$(mktemp -d)
mkdir -p "$ROOT_CA_OUT"
cp "$T_CA/root_ca.crt" "$ROOT_CA_OUT/"
cp "$T_CA/root_ca.key" "$ROOT_CA_OUT/"
cp "$T_CA/intermediate_ca.crt" "$ROOT_CA_OUT/"
cp "$T_CA/intermediate_ca.key" "$ROOT_CA_OUT/"
out=$(printf '%b' "y\n" | "${GEN_CSR_SH}" --cn ctx.home --san "DNS:ctx.home" \
  --root-cert "$ROOT_CA_OUT/root_ca.crt" --outpath "$T_CSR" --no-docker 2>&1) || true
echo "$out" | grep -q "subject" && pass "gen-csr --root-cert shows subject" || fail "gen-csr --root-cert shows subject"
rm -rf "$T_CSR" "$ROOT_CA_OUT"

# ── Test 4: root-ca.sh unknown subcommand exits 0 but prints error ──
out=$(bash "${ROOT_CA_SH}" boguscommand 2>&1) || true
echo "$out" | grep -q "Unknown argument" && pass "root-ca unknown subcommand — shows error" || fail "root-ca unknown subcommand"

# ── Test 5: root-ca.sh unknown flag exits 0 but prints error ──
out=$(bash "${ROOT_CA_SH}" init --nonexistent-flag val 2>&1) || true
echo "$out" | grep -q "Unknown argument" && pass "root-ca unknown flag — shows error" || fail "root-ca unknown flag"

# ── Test 6: gen-csr.sh unknown flag exits non-zero ──
out="" ec=0
out=$(bash "${GEN_CSR_SH}" --fake-flag 2>&1) || ec=$?
[[ $ec -ne 0 ]] && echo "$out" | grep -q "Unknown argument" && \
  pass "gen-csr unknown flag exits 1" || fail "gen-csr unknown flag exits 1"

# ── Test 7: sign-certs with missing CSR exits non-zero ──
mkdir -p "$ROOT_CA_OUT"
cp "$T_CA/root_ca.crt" "$ROOT_CA_OUT/"
cp "$T_CA/root_ca.key" "$ROOT_CA_OUT/"
cp "$T_CA/intermediate_ca.crt" "$ROOT_CA_OUT/"
cp "$T_CA/intermediate_ca.key" "$ROOT_CA_OUT/"
out="" ec=0
out=$(printf '%b' "y\n" | bash "${ROOT_CA_SH}" --sign-certs /tmp/no-such-file.csr --no-docker 2>&1) || ec=$?
[[ $ec -ne 0 ]] && echo "$out" | grep -q "not found" && \
  pass "sign-certs missing CSR exits 1" || fail "sign-certs missing CSR exits 1 (ec=$ec)"
rm -rf "$ROOT_CA_OUT"

# ── Test 8: sign-certs without root CA exits non-zero ──
T_FAKE_CSR=$(mktemp -d)
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$T_FAKE_CSR/dummy.key" 2>/dev/null
openssl req -new -key "$T_FAKE_CSR/dummy.key" -out "$T_FAKE_CSR/dummy.csr" -subj "/CN=dummy" 2>/dev/null
out="" ec=0
out=$(printf '%b' "y\n" | bash "${ROOT_CA_SH}" --sign-certs "$T_FAKE_CSR/dummy.csr" --no-docker 2>&1) || ec=$?
[[ $ec -ne 0 ]] && echo "$out" | grep -q "not found" && \
  pass "sign-certs no root CA exits 1" || fail "sign-certs no root CA exits 1 (ec=$ec, out=$out)"
rm -rf "$T_FAKE_CSR" "$ROOT_CA_OUT" "$T_CA"

echo ""
echo "  Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
