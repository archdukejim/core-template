#!/usr/bin/env bash
# check.sh — home-core stack health checks
#
#   Local mode  (default) — run ON the target as root, checks everything
#     sudo bash check.sh
#
#   Remote mode — run from any machine, network-reachable checks only
#     bash check.sh --target 192.168.7.53

set -uo pipefail

# ── read vars.yaml ─────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VARS="$SCRIPT_DIR/core/vars.yaml"
_var() { grep "^${1}:" "$VARS" 2>/dev/null | awk '{print $2}' | tr -d "'\""; }

DOMAIN="$(_var domain)";           DOMAIN="${DOMAIN:-home}"
BIND_DNS_PORT="$(_var bind_dns_port)"; BIND_DNS_PORT="${BIND_DNS_PORT:-5353}"
STEPCA_PORT="$(_var stepca_port)"; STEPCA_PORT="${STEPCA_PORT:-9000}"
TARGET_BASE="$(_var target_base)"; TARGET_BASE="${TARGET_BASE:-/opt}"

# ── arg parsing ────────────────────────────────────────────────────────────
MODE="local"
TARGET="127.0.0.1"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)  MODE="remote"; TARGET="$2"; shift 2 ;;
        --domain)  DOMAIN="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

if [[ "$MODE" == "local" && $EUID -ne 0 ]]; then
    echo "Local mode requires root. Run: sudo bash check.sh"
    exit 1
fi

# ── colours / counters ─────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
NPASS=0; NFAIL=0; NWARN=0

pass()    { printf "  ${GREEN}[PASS]${NC} %s\n" "$*"; ((NPASS++)); }
fail()    { printf "  ${RED}[FAIL]${NC} %s\n" "$*"; ((NFAIL++)); }
warn()    { printf "  ${YELLOW}[WARN]${NC} %s\n" "$*"; ((NWARN++)); }
section() { printf "\n${BOLD}${CYAN}══ %s ══${NC}\n" "$*"; }

# ── DNS ────────────────────────────────────────────────────────────────────
# check_dig LABEL QTYPE NAME [PORT] [EXPECTED_SUBSTR]
check_dig() {
    local label="$1" qtype="$2" name="$3" port="${4:-53}" expected="${5:-}"
    local result
    result=$(dig +short +time=3 +tries=1 "@${TARGET}" -p "${port}" "${qtype}" "${name}" 2>/dev/null)
    if [[ -z "$result" ]]; then
        fail "${label}: ${qtype} ${name} → (no answer)"
    elif [[ -n "$expected" && "$result" != *"$expected"* ]]; then
        fail "${label}: ${qtype} ${name} → ${result} (expected '${expected}')"
    else
        pass "${label}: ${qtype} ${name} → ${result}"
    fi
}

# ── TLS ────────────────────────────────────────────────────────────────────
# check_tls LABEL SNI_HOST PORT [CA_CERT_PATH]
# Without a CA cert (remote mode), still connects and shows cert info but
# downgrades trust failures to [WARN] — cert may be internal PKI.
check_tls() {
    local label="$1" sni="$2" port="$3" cacert="${4:-}"
    local out expiry subj

    # Always fetch the cert (no verify) to get subject/expiry
    out=$(echo | timeout 6 openssl s_client \
        -connect "${TARGET}:${port}" -servername "${sni}" 2>&1)

    if ! echo "$out" | grep -q "BEGIN CERTIFICATE"; then
        fail "${label}: no TLS response on ${TARGET}:${port}"
        return
    fi

    expiry=$(echo "$out" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    subj=$(echo "$out" | openssl x509 -noout -subject 2>/dev/null | sed 's/subject=//')

    if [[ -n "$cacert" ]]; then
        # Validate against provided CA
        local vout
        vout=$(echo | timeout 6 openssl s_client \
            -connect "${TARGET}:${port}" -servername "${sni}" \
            -CAfile "$cacert" -verify_return_error 2>&1)
        if echo "$vout" | grep -q "Verify return code: 0"; then
            pass "${label}: TLS OK — ${subj} (expires ${expiry})"
        else
            local rc
            rc=$(echo "$vout" | grep "Verify return code" | head -1 | sed 's/.*Verify/Verify/')
            fail "${label}: ${rc}"
        fi
    else
        # No CA — report cert info but note we can't validate trust
        warn "${label}: cert present, trust unverified (no CA) — ${subj} (expires ${expiry})"
    fi
}

# ── HTTP ───────────────────────────────────────────────────────────────────
# check_http LABEL URL [CA_CERT] [EXPECTED_CODES_CSV] [HOST:PORT:IP_RESOLVE]
check_http() {
    local label="$1" url="$2" cacert="${3:-}" expected="${4:-200}" resolve="${5:-}"
    local args=(-s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10)
    if [[ -n "$cacert" ]]; then
        args+=(--cacert "$cacert")
    else
        args+=(--insecure)   # no CA available — check reachability, not cert trust
    fi
    [[ -n "$resolve" ]] && args+=(--resolve "$resolve")
    local code
    code=$(curl "${args[@]}" "$url" 2>/dev/null)
    local ok=false
    IFS=',' read -ra codes <<< "$expected"
    for c in "${codes[@]}"; do [[ "$code" == "$c" ]] && ok=true && break; done
    if $ok; then
        pass "${label}: HTTP ${code}"
    elif [[ "$code" == "000" ]]; then
        warn "${label}: connection refused/timeout (service may not be up yet)"
    else
        fail "${label}: HTTP ${code} (expected ${expected})"
    fi
}

# ══════════════════════════════════════════════════════════════════════════
printf "\n${BOLD}home-core stack check${NC}  [${BOLD}${MODE} mode${NC}]\n"
printf "  Target : %s\n" "$TARGET"
printf "  Domain : %s\n" "$DOMAIN"

# ══════════════════════════════════════════════════════════════════════════
# NETWORK CHECKS (both modes)
# ══════════════════════════════════════════════════════════════════════════

section "DNS — AdGuard via nginx (:53)"
check_dig "A  pi-core"     A     "pi-core.${DOMAIN}"    53 "192.168.7.53"
check_dig "A  nas25"       A     "nas25.${DOMAIN}"       53 "192.168.7.10"
check_dig "A  portainer"   A     "portainer.${DOMAIN}"   53 "192.168.7.11"
check_dig "A  nas25-apps"  A     "nas25-apps.${DOMAIN}"  53 "192.168.7.12"
check_dig "CNAME  ca"      CNAME "ca.${DOMAIN}"          53 "pi-core"
check_dig "CNAME  adguard" CNAME "adguard.${DOMAIN}"     53 "pi-core"
check_dig "CNAME  ldap"    CNAME "ldap.${DOMAIN}"        53 "pi-core"
check_dig "Ext google.com" A     "google.com"             53

section "DNS — BIND9 direct (:${BIND_DNS_PORT})"
check_dig "A  pi-core"    A   "pi-core.${DOMAIN}" "$BIND_DNS_PORT" "192.168.7.53"
check_dig "A  nas25"      A   "nas25.${DOMAIN}"   "$BIND_DNS_PORT" "192.168.7.10"
check_dig "SOA ${DOMAIN}" SOA "${DOMAIN}"         "$BIND_DNS_PORT"

section "HTTP endpoints"
# Plain HTTP redirects to HTTPS — 301 is correct
check_http "nginx http"       "http://${TARGET}/"           "" "301"
check_http "AdGuard UI http"  "http://adguard.${DOMAIN}/"   "" "301"  "adguard.${DOMAIN}:80:${TARGET}"
check_http "AdGuard UI https" "https://adguard.${DOMAIN}/"  "" "200"  "adguard.${DOMAIN}:443:${TARGET}"
check_http "step-ca /health"  "https://ca.${DOMAIN}/health" "" "200"  "ca.${DOMAIN}:443:${TARGET}"

section "TLS certificates"
# Fetch root CA for validation (local: read direct; remote: try connecting without validation first)
TMPCA=$(mktemp); TMPINT=$(mktemp)
trap 'rm -f "$TMPCA" "$TMPINT"' EXIT

if [[ "$MODE" == "local" ]]; then
    CA_ROOT="${TARGET_BASE}/stepca/data/certs/root_ca.crt"
    CA_INT="${TARGET_BASE}/stepca/data/certs/intermediate_ca.crt"
    [[ -f "$CA_ROOT" ]] && cp "$CA_ROOT" "$TMPCA"
    [[ -f "$CA_INT"  ]] && cp "$CA_INT"  "$TMPINT"
fi

if [[ -s "$TMPCA" ]]; then
    check_tls "adguard.${DOMAIN}:443" "adguard.${DOMAIN}" 443 "$TMPCA"
    check_tls "ca.${DOMAIN}:443"      "ca.${DOMAIN}"      443 "$TMPCA"
    check_tls "ldap.${DOMAIN}:636"    "ldap.${DOMAIN}"    636 "$TMPCA"
else
    warn "Root CA not available — validating against system trust store"
    check_tls "adguard.${DOMAIN}:443" "adguard.${DOMAIN}" 443
    check_tls "ca.${DOMAIN}:443"      "ca.${DOMAIN}"      443
    check_tls "ldap.${DOMAIN}:636"    "ldap.${DOMAIN}"    636
fi

# ══════════════════════════════════════════════════════════════════════════
# LOCAL CHECKS (sudo bash check.sh only)
# ══════════════════════════════════════════════════════════════════════════
if [[ "$MODE" == "remote" ]]; then
    printf "\n${BOLD}══ Results ══${NC}\n"
    printf "  ${GREEN}${NPASS} passed${NC}   ${RED}${NFAIL} failed${NC}   ${YELLOW}${NWARN} warnings${NC}\n\n"
    [[ "$NFAIL" -gt 0 ]] && exit 1 || exit 0
fi

section "Docker containers"
containers=(nginx adguardhome certbot step-ca openldap bind9)
running=$(docker ps --format '{{.Names}}')
for c in "${containers[@]}"; do
    if echo "$running" | grep -qx "$c"; then
        status=$(docker inspect --format='{{.State.Health.Status}}' "$c" 2>/dev/null | tr -d '[:space:]')
        case "$status" in
            healthy)   pass "$c: running, healthy" ;;
            none|"")   pass "$c: running (no healthcheck)" ;;
            starting)  warn "$c: running, still starting" ;;
            unhealthy) fail "$c: running but UNHEALTHY" ;;
            *)         warn "$c: running, status=${status}" ;;
        esac
    else
        fail "$c: not running"
    fi
done

section "CA files"
for pair in "Root CA:${CA_ROOT:-}:${TMPCA}" "Intermediate CA:${CA_INT:-}:${TMPINT}"; do
    label="${pair%%:*}"; rest="${pair#*:}"; path="${rest%%:*}"; tmpf="${rest##*:}"
    if [[ -f "$path" ]]; then
        info=$(openssl x509 -in "$path" -noout -subject -dates 2>/dev/null)
        subj=$(echo "$info" | grep subject | sed 's/subject=//')
        expiry=$(echo "$info" | grep notAfter | cut -d= -f2)
        pass "${label}: ${subj} — expires ${expiry}"
    else
        fail "${label}: missing at ${path}"
    fi
done

section "step-ca internal health"
health=$(docker exec step-ca wget -q --no-check-certificate -O - \
    "https://localhost:${STEPCA_PORT}/health" 2>/dev/null || echo "")
if echo "$health" | grep -q '"status":"ok"'; then
    pass "step-ca /health: ${health}"
elif [[ -z "$health" ]]; then
    warn "step-ca /health: no response (container may be starting)"
else
    fail "step-ca /health: '${health}'"
fi

section "Certbot certificate expiry"
live_dir="${TARGET_BASE}/certbot/etc/letsencrypt/live"
cert_dirs=$(ls "$live_dir" 2>/dev/null | grep -v README || true)
if [[ -z "$cert_dirs" ]]; then
    warn "No certbot certs found in ${live_dir}"
else
    now_epoch=$(date +%s)
    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        cert="${live_dir}/${dir}/cert.pem"
        expiry=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2)
        if [[ -z "$expiry" ]]; then
            fail "certbot/${dir}: could not read cert"; continue
        fi
        exp_epoch=$(date -d "$expiry" +%s 2>/dev/null || echo 0)
        days_left=$(( (exp_epoch - now_epoch) / 86400 ))
        if   [[ "$days_left" -le 0  ]]; then fail "certbot/${dir}: EXPIRED (${expiry})"
        elif [[ "$days_left" -le 15 ]]; then warn "certbot/${dir}: expires in ${days_left}d (${expiry})"
        else                                  pass "certbot/${dir}: ${days_left}d remaining (expires ${expiry})"
        fi
    done <<< "$cert_dirs"
fi

section "LDAP"
rootdse=$(docker exec openldap ldapsearch -x -H "ldap://localhost:389" \
    -b "" -s base "(objectClass=*)" namingContexts 2>/dev/null || echo "")
if echo "$rootdse" | grep -q "namingContexts"; then
    nc=$(echo "$rootdse" | grep "^namingContexts" | awk '{print $2}')
    pass "LDAP rootDSE: namingContexts=${nc}"
else
    fail "LDAP rootDSE: no response"
fi

count=$(docker exec openldap ldapsearch -x -H "ldap://localhost:389" \
    -b "dc=${DOMAIN}" -s base 2>/dev/null | grep -c "^dn:" || echo "0")
count=$(echo "$count" | tr -d '[:space:]')
if [[ "${count:-0}" -gt 0 ]]; then
    pass "LDAP base search: dc=${DOMAIN} found"
else
    fail "LDAP base search: dc=${DOMAIN} returned nothing"
fi

section "BIND9"
tsig_file="${TARGET_BASE}/bind9/config/named.conf.keys"
if [[ -f "$tsig_file" ]]; then
    lines=$(wc -l < "$tsig_file" | tr -d '[:space:]')
    pass "TSIG keys file: present (${lines} lines)"
else
    fail "TSIG keys file: missing at ${tsig_file}"
fi

rndc=$(docker exec bind9 rndc status 2>/dev/null | head -1 || echo "")
if [[ -n "$rndc" ]]; then
    pass "BIND9 rndc: ${rndc}"
else
    warn "BIND9 rndc: no response (may be starting)"
fi

# ── summary ────────────────────────────────────────────────────────────────
printf "\n${BOLD}══ Results ══${NC}\n"
printf "  ${GREEN}${NPASS} passed${NC}   ${RED}${NFAIL} failed${NC}   ${YELLOW}${NWARN} warnings${NC}\n\n"
[[ "$NFAIL" -gt 0 ]] && exit 1 || exit 0
