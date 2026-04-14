#!/bin/bash
# Direct execution runner — source this file, do not execute directly.
#
# Replaces the former ansible-based run_playbook() with direct shell/docker
# functions.  manage.sh must run ON the target machine (no remote support).

# -----------------------------------------------------------------------
# run_dns_reload
# Re-render BIND9 zone data files from custom-vars.yaml and reload BIND9.
# Replaces: ansible-playbook --tags dns-record
#
# Renders forward zones (db.<zone>) and reverse zones (db.<rev-zone>)
# using the same logic as jinja/bind9/data/zone.j2 and reverse-zone.j2.
# Does NOT touch named.conf.zones — preserves TSIG grants added live by
# do_tsig_keys().
# -----------------------------------------------------------------------
run_dns_reload() {
    local bind9_data="${TARGET_BASE}/bind9/data"
    [ -d "$bind9_data" ]        || { err "BIND9 data dir not found: ${bind9_data}. Is core-template deployed?"; exit 1; }
    [ -f "$VARS_FILE" ]  || { err "vars.yaml not found: ${VARS_FILE}"; exit 1; }

    info "Rendering zone files..."

    CUSTOM_VARS="$VARS_FILE" \
    BIND9_DATA="$bind9_data" \
    python3 - <<'PYEOF'
import yaml, os, sys, re
from datetime import datetime

with open(os.environ['CUSTOM_VARS']) as f:
    v = yaml.safe_load(f) or {}

domain     = v['domain']
host_ip    = v['host_ip']
dns        = v.get('dns', {})
bind9_data = os.environ['BIND9_DATA']

# bind ownership from advanced-vars defaults (uid/gid 53)
bind_uid = int(v.get('service_users', {}).get('bind', {}).get('uid', 53))
bind_gid = int(v.get('service_users', {}).get('bind', {}).get('gid', 53))

today = datetime.now().strftime('%Y%m%d')

def next_serial(zone_file):
    """YYYYMMDDNN — increment NN if date already matches, else start at 01."""
    try:
        with open(zone_file) as f:
            for line in f:
                m = re.search(r'\b(\d{8})(\d{2})\b', line)
                if m and '; Serial' in line:
                    d, n = m.group(1), int(m.group(2))
                    return (today + f"{n + 1:02d}") if d == today else (today + '01')
    except FileNotFoundError:
        pass
    return today + '01'

def render_zone(zone_name, recs, domain, host_ip, serial):
    out = [
        '$TTL 86400',
        f'$ORIGIN {zone_name}.',
        '',
        ';-----------------------------------------------------------------',
        '; SOA Record',
        ';-----------------------------------------------------------------',
        f'@       IN      SOA     ns.{domain}. hostmaster.{domain}. (',
        f'                        {serial} ; Serial (YYYYMMDDNN)',
        f'                        3600             ; Refresh',
        f'                        1800             ; Retry',
        f'                        604800           ; Expire',
        f'                        86400            ; Negative caching TTL',
        ')',
        '',
        ';-----------------------------------------------------------------',
        '; NS Records',
        ';-----------------------------------------------------------------',
        f'@       IN      NS      ns.{domain}.',
        '',
        ';-----------------------------------------------------------------',
        '; A Records',
        ';-----------------------------------------------------------------',
    ]
    if recs.get('zone_authority'):
        out.append(f"{'ns':<24}A       {host_ip}")
    for r in recs.get('A', []):
        out.append(f"{r['name']:<24}A       {r['ip']}")

    out += ['', ';-----------------------------------------------------------------',
            '; AAAA Records', ';-----------------------------------------------------------------']
    for r in recs.get('AAAA', []):
        out.append(f"{r['name']:<24}AAAA    {r['ip']}")

    out += ['', ';-----------------------------------------------------------------',
            '; CNAME Records', ';-----------------------------------------------------------------']
    for r in recs.get('CNAME', []):
        out.append(f"{r['name']:<24}CNAME   {r['canonical']}")

    out += ['', ';-----------------------------------------------------------------',
            '; MX Records', ';-----------------------------------------------------------------']
    for r in recs.get('MX', []):
        out.append(f"{r['name']:<24}MX      {r['priority']} {r['exchange']}")

    out += ['', ';-----------------------------------------------------------------',
            '; TXT Records', ';-----------------------------------------------------------------']
    for r in recs.get('TXT', []):
        out.append(f"{r['name']:<24}TXT     \"{r['text']}\"")

    out += ['', ';-----------------------------------------------------------------',
            '; SRV Records', ';-----------------------------------------------------------------']
    for r in recs.get('SRV', []):
        out.append(f"{r['name']:<24}SRV     {r['priority']} {r['weight']} {r['port']} {r['target']}")

    return '\n'.join(out) + '\n'

def render_reverse(rev_zone, dns, domain, serial):
    out = [
        '$TTL 86400',
        f'$ORIGIN {rev_zone}.',
        '',
        ';-----------------------------------------------------------------',
        '; SOA Record',
        ';-----------------------------------------------------------------',
        f'@       IN      SOA     ns.{domain}. hostmaster.{domain}. (',
        f'                        {serial} ; Serial (YYYYMMDDNN)',
        f'                        3600             ; Refresh',
        f'                        1800             ; Retry',
        f'                        604800           ; Expire',
        f'                        86400            ; Negative caching TTL',
        ')',
        '',
        ';-----------------------------------------------------------------',
        '; NS Records',
        ';-----------------------------------------------------------------',
        f'@       IN      NS      ns.{domain}.',
        '',
        ';-----------------------------------------------------------------',
        '; PTR Records  (auto-generated from forward zone A records)',
        ';-----------------------------------------------------------------',
    ]
    for zone_key, recs in dns.items():
        fwd = domain if zone_key == 'dynamic_zone_var' else zone_key
        for r in recs.get('A', []):
            p = r['ip'].split('.')
            if len(p) == 4:
                rz = f"{p[2]}.{p[1]}.{p[0]}.in-addr.arpa"
                if rz == rev_zone:
                    out.append(f"{p[3]:<24}PTR     {r['name']}.{fwd}.")
    return '\n'.join(out) + '\n'

def write_zone(path, content, uid, gid):
    with open(path, 'w') as f:
        f.write(content)
    os.chown(path, uid, gid)
    os.chmod(path, 0o640)

rev_zones = set()
errors    = []

for zone_key, zone_recs in dns.items():
    zone_name = domain if zone_key == 'dynamic_zone_var' else zone_key
    zone_file = os.path.join(bind9_data, f'db.{zone_name}')
    try:
        serial = next_serial(zone_file)
        write_zone(zone_file, render_zone(zone_name, zone_recs, domain, host_ip, serial), bind_uid, bind_gid)
        print(f"  rendered db.{zone_name}  (serial {serial})")
    except Exception as e:
        errors.append(f"db.{zone_name}: {e}")

    for r in zone_recs.get('A', []):
        p = r['ip'].split('.')
        if len(p) == 4:
            rev_zones.add(f"{p[2]}.{p[1]}.{p[0]}.in-addr.arpa")

for rev_zone in sorted(rev_zones):
    zone_file = os.path.join(bind9_data, f'db.{rev_zone}')
    try:
        serial = next_serial(zone_file)
        write_zone(zone_file, render_reverse(rev_zone, dns, domain, serial), bind_uid, bind_gid)
        print(f"  rendered db.{rev_zone}  (serial {serial})")
    except Exception as e:
        errors.append(f"db.{rev_zone}: {e}")

if errors:
    for e in errors:
        print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

    # Reload BIND9 if running
    local running
    running=$(docker inspect --format='{{.State.Running}}' bind9 2>/dev/null || true)
    if [ "$running" = "true" ]; then
        info "Reloading BIND9..."
        docker exec bind9 rndc reload
        ok "BIND9 zones reloaded."
    else
        warn "bind9 container is not running — zone files updated but not reloaded."
    fi
}

# -----------------------------------------------------------------------
# run_service_certs
# Re-mint TLS certificates for the four core nginx-proxied services:
#   dns.<domain>, ldap.<domain>, ca.<domain>, certificates.<domain>
# Also installs the dns cert to bind9/ssl/ for DoT.
#
# Replaces: ansible-playbook --tags service-certs  (sections 8b–8f of
#           08-mint-service-certs.yml)
#
# Requires: step-ca image available locally; intermediate CA key present
#           at $deploy_base_dir/stepca/data/secrets/intermediate_ca_key
# -----------------------------------------------------------------------
run_service_certs() {
    local vars_file="$VARS_FILE"
    [ -f "$vars_file" ] || { err "Live vars not found: ${vars_file}. Is core-template deployed?"; exit 1; }

    # Read runtime config from live vars.yaml (all values already resolved)
    local deploy_base image_stepca step_uid step_gid nginx_uid nginx_gid bind_uid bind_gid
    local domain hostname_bind9 hostname_ldap hostname_stepca hostname_certs cert_service_days
    IFS=' ' read -r deploy_base image_stepca \
                    step_uid  step_gid \
                    nginx_uid nginx_gid \
                    bind_uid  bind_gid \
                    domain \
                    hostname_bind9 hostname_ldap hostname_stepca hostname_certs \
                    cert_service_days \
        < <(python3 - <<PYEOF
import yaml
with open('${vars_file}') as f:
    v = yaml.safe_load(f)
su = v['service_users']
print(
    v['deploy_base_dir'],
    v['image_stepca'],
    su['step']['uid'],  su['step']['gid'],
    su['nginx']['uid'], su['nginx']['gid'],
    su['bind']['uid'],  su['bind']['gid'],
    v['domain'],
    v['hostname_bind9'],
    v['hostname_ldap'],
    v['hostname_stepca'],
    v['hostname_certs'],
    v.get('cert_service_days', 5475),
)
PYEOF
)

    local stepca_data="${deploy_base}/stepca/data"
    local artifacts="${stepca_data}/artifacts"
    local int_crt="${stepca_data}/certs/intermediate_ca.crt"
    local int_key="${stepca_data}/secrets/intermediate_ca_key"
    local not_after=$(( cert_service_days * 24 ))h

    [ -f "$int_crt" ] || { err "Intermediate CA cert not found: ${int_crt}"; exit 1; }
    [ -f "$int_key" ] || { err "Intermediate CA key not found: ${int_key}"; exit 1; }

    # Ensure artifacts dir exists with step ownership
    mkdir -p "$artifacts"
    chown "${step_uid}:${step_gid}" "$artifacts"

    # ---- helper: mint one cert into artifacts/ ----
    _mint_svc() {
        local cn="$1"; shift
        local sans=("$@")
        local safe; safe=$(echo "$cn" | tr './ ' '---')

        local san_args=("--san" "$cn")
        for s in "${sans[@]}"; do san_args+=("--san" "$s"); done

        info "  Minting ${cn}..."
        docker run --rm \
            -v "${stepca_data}:/home/step" \
            --user "${step_uid}:${step_gid}" \
            --entrypoint /usr/local/bin/step \
            "$image_stepca" \
            certificate create "$cn" \
            "/home/step/artifacts/${safe}.crt" \
            "/home/step/artifacts/${safe}.key" \
            --ca  "/home/step/certs/intermediate_ca.crt" \
            --ca-key "/home/step/secrets/intermediate_ca_key" \
            --no-password --insecure --force \
            --kty RSA --size 4096 \
            --not-after "$not_after" \
            --template "/home/step/templates/certs/leaf.tpl" \
            "${san_args[@]}"
    }

    # ---- helper: install cert + key to nginx certs dir ----
    _install_nginx_cert() {
        local cn="$1"
        local safe; safe=$(echo "$cn" | tr './ ' '---')
        local cert_dir="${deploy_base}/nginx/certs/${cn}"

        mkdir -p "$cert_dir"
        chown "${nginx_uid}:${nginx_gid}" "$cert_dir"
        chmod 750 "$cert_dir"

        cat "${artifacts}/${safe}.crt" \
            "${stepca_data}/certs/intermediate_ca.crt" \
            > "${cert_dir}/fullchain.pem"
        mv  "${artifacts}/${safe}.key"  "${cert_dir}/privkey.pem"
        rm -f "${artifacts}/${safe}.crt"

        chown "${nginx_uid}:${nginx_gid}" \
            "${cert_dir}/fullchain.pem" \
            "${cert_dir}/privkey.pem"
        chmod 644 "${cert_dir}/fullchain.pem"
        chmod 640 "${cert_dir}/privkey.pem"
        ok "  Installed ${cn} → ${cert_dir}"
    }

    # ---- Mint + install each service cert ----
    _mint_svc "$hostname_ldap";   _install_nginx_cert "$hostname_ldap"
    _mint_svc "$hostname_stepca"; _install_nginx_cert "$hostname_stepca"
    _mint_svc "$hostname_certs";  _install_nginx_cert "$hostname_certs"

    # bind9 hostname gets nginx cert AND a dedicated bind9/ssl/ cert
    _mint_svc "$hostname_bind9" "ns.${domain}" "127.0.0.1"
    _install_nginx_cert "$hostname_bind9"

    # ---- Install dedicated BIND9 TLS cert to bind9/ssl/ ----
    local bind9_ssl="${deploy_base}/bind9/ssl"
    mkdir -p "$bind9_ssl"

    # Re-mint so the nginx copy and the bind9/ssl copy are independent files
    local bind_safe; bind_safe=$(echo "$hostname_bind9" | tr './ ' '---')
    _mint_svc "$hostname_bind9" "ns.${domain}" "127.0.0.1"

    mv  "${artifacts}/${bind_safe}.key" "${bind9_ssl}/privkey.pem"
    cat "${artifacts}/${bind_safe}.crt" \
        "${stepca_data}/certs/intermediate_ca.crt" \
        > "${bind9_ssl}/fullchain.pem"
    cp  "${stepca_data}/certs/root_ca.crt" "${bind9_ssl}/root_ca.crt"
    rm -f "${artifacts}/${bind_safe}.crt"

    chown "${bind_uid}:${bind_gid}" \
        "${bind9_ssl}/privkey.pem" \
        "${bind9_ssl}/fullchain.pem" \
        "${bind9_ssl}/root_ca.crt"
    chmod 600 "${bind9_ssl}/privkey.pem"
    chmod 644 "${bind9_ssl}/fullchain.pem" "${bind9_ssl}/root_ca.crt"
    ok "  Installed BIND9 TLS cert → ${bind9_ssl}"
}
