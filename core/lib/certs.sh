#!/bin/bash
# Certificate management — source this file, do not execute directly.

# -----------------------------------------------------------------------
# _mint_extra_cert <json_entry>
# Mint a single certificate described by a JSON entry (from extra_certs[]).
# Reads runtime config (stepca image, step uid/gid, deploy_base_dir) from
# the live vars.yaml deployed by core-template.
# -----------------------------------------------------------------------
_mint_extra_cert() {
    local json_entry="$1"
    local vars_file="$VARS_FILE"
    [ -f "$vars_file" ] || { err "Live vars not found: ${vars_file}. Is core-template deployed?"; exit 1; }
    [[ "$(id -u)" -eq 0 ]] || { err "Must be run as root."; exit 1; }

    # Parse cert entry + runtime vars into shell variables via shlex-quoted output
    local _tmp; _tmp=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '${_tmp}'" RETURN

    CERT_JSON="$json_entry" RUNTIME_VARS="$vars_file" \
    python3 - > "$_tmp" <<'PYEOF'
import json, yaml, os, shlex

e = json.loads(os.environ['CERT_JSON'])
with open(os.environ['RUNTIME_VARS']) as f:
    v = yaml.safe_load(f)

su = v['service_users']['step']

print(f"DEPLOY_BASE={shlex.quote(v['deploy_base_dir'])}")
print(f"STEPCA_PORT={v.get('stepca_port', 9000)}")
print(f"STEP_UID={su['uid']}")
print(f"STEP_GID={su['gid']}")
print(f"CERT_CN={shlex.quote(e['cn'])}")
print(f"CERT_DAYS={e.get('days', 365)}")
print(f"CERT_OUT_DIR={shlex.quote(e.get('out_dir', ''))}")
print(f"CERT_KTY={shlex.quote(str(e.get('kty', 'RSA')))}")
print(f"CERT_SIZE={e.get('size', 4096)}")
print(f"CERT_IS_CA={'true' if e.get('is_ca', False) else 'false'}")
print(f"CERT_PATH_LEN={e.get('path_len', 0)}")
print(f"CERT_SANS_JSON={shlex.quote(json.dumps(e.get('sans', [])))}")
PYEOF

    # shellcheck source=/dev/null
    source "$_tmp"

    local stepca_data="${DEPLOY_BASE}/stepca/data"
    local artifacts="${stepca_data}/artifacts"

    # Determine output directory (same logic as 07-mint-service-certs.yml)
    local target_dir
    if [ -n "$CERT_OUT_DIR" ]; then
        target_dir="$CERT_OUT_DIR"
    elif [ -n "${SUDO_USER:-}" ]; then
        target_dir=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        target_dir="$HOME"
    fi
    [ -d "$target_dir" ] || { err "Output directory does not exist: ${target_dir}"; exit 1; }

    local safe_cn; safe_cn=$(echo "$CERT_CN" | tr './ ' '---')
    local key_out="${target_dir}/${safe_cn}.key"
    local crt_out="${target_dir}/${safe_cn}.crt"

    mkdir -p "$artifacts"
    chown "${STEP_UID}:${STEP_GID}" "$artifacts"

    # Build SAN / extra args
    local san_args=() extra_args=() cert_template
    if [ "$CERT_IS_CA" = "true" ]; then
        cert_template="/home/step/templates/certs/subca.tpl"
        extra_args=(--set "pathLen=${CERT_PATH_LEN}")
    else
        cert_template="/home/step/templates/certs/leaf.tpl"
        san_args=(--san "$CERT_CN")
        while IFS= read -r san; do
            [ -n "$san" ] && san_args+=(--san "$san")
        done < <(python3 -c "import json,sys; [print(s) for s in json.loads(sys.argv[1])]" "$CERT_SANS_JSON")
    fi

    echo "Generating certificate for ${CERT_CN} (validity: ${CERT_DAYS} days)..."
    local cmd=(
        step ca certificate "$CERT_CN"
        /home/step/artifacts/leaf.crt /home/step/artifacts/leaf.key
        --ca-url "https://127.0.0.1:${STEPCA_PORT}"
        --root "/home/step/certs/root_ca.crt"
        --provisioner "admin"
        --provisioner-password-file "/home/step/secrets/password"
        --kty "$CERT_KTY" --size "$CERT_SIZE"
        --not-after "$(( CERT_DAYS * 24 ))h"
    )
    cmd+=("${san_args[@]}")
    cmd+=("${extra_args[@]}")

    docker exec \
        --user "${STEP_UID}:${STEP_GID}" \
        step-ca \
        "${cmd[@]}"

    mv "${artifacts}/leaf.key" "$key_out"
    mv "${artifacts}/leaf.crt" "$crt_out"

    if [ -n "${SUDO_USER:-}" ]; then
        local sudo_gid; sudo_gid=$(id -g "$SUDO_USER")
        chown "${SUDO_USER}:${sudo_gid}" "$key_out" "$crt_out"
    fi
    chmod 0600 "$key_out"
    chmod 0644 "$crt_out"

    echo "Certificate minted:"
    echo "  Key:  ${key_out}"
    echo "  Cert: ${crt_out}"
    openssl x509 -in "$crt_out" -noout -subject -dates \
        -ext basicConstraints -ext subjectAltName 2>/dev/null || true
}

# -----------------------------------------------------------------------
# do_extra_certs
# Interactive or --apply mode: mint an offline certificate via Step-CA
# and record it in custom-vars.yaml.
# -----------------------------------------------------------------------
do_extra_certs() {
    echo -e "${BOLD}core-template mint-certs${NC}"
    echo ""

    local vars_file="$VARS_FILE"
    [ -f "$vars_file" ] || { err "core-template not deployed (${vars_file} not found)."; exit 1; }

    if [ "$SUB_MODE" = "apply" ]; then
        info "Minting certificates from custom-vars.yaml..."
        echo ""

        local entries
        entries=$(python3 -c "
import yaml, json, sys
with open('$VARS_FILE') as f:
    d = yaml.safe_load(f)
certs = d.get('extra_certs') or []
if not certs:
    print('__EMPTY__')
    sys.exit(0)
for c in certs:
    print(json.dumps(c))
")
        if [ "$entries" = "__EMPTY__" ]; then
            warn "No extra_certs entries in custom-vars.yaml — nothing to mint."; return
        fi

        while IFS= read -r entry; do
            _mint_extra_cert "$entry"
            echo ""
        done <<< "$entries"

        ok "Certificate minting complete."
        return
    fi

    # --- Interactive ---
    if $IS_CA; then
        info "Interactive subordinate CA minting (pathLen=${PATH_LEN} — signed by Step-CA)"
    else
        info "Interactive certificate minting (offline — signed by Step-CA)"
    fi
    echo ""

    local cn; read -rp "  Common Name (e.g. myservice.internal): " cn
    [ -n "$cn" ] || { err "Common Name is required."; exit 1; }

    local sans=()
    if ! $IS_CA; then
        echo "  Additional SANs (blank to finish):"
        while true; do
            local san; read -rp "    SAN: " san
            [ -z "$san" ] && break
            sans+=("$san")
        done
    fi

    local days="" out_dir=""
    read -rp "  Validity in days [365]: " days; days="${days:-365}"
    read -rp "  Output directory [caller's home]: " out_dir

    local kty size
    read -rp "  Key type [${CERT_KTY}]: " kty;   kty="${kty:-${CERT_KTY}}"
    read -rp "  Key size [${CERT_SIZE}]: " size;  size="${size:-${CERT_SIZE}}"

    # Build type label for summary
    local type_label
    if $IS_CA; then
        if [ "$PATH_LEN" -eq 0 ]; then
            type_label="Subordinate CA (pathLen=0 — cannot sign further CAs)"
        else
            type_label="Subordinate CA (pathLen=${PATH_LEN} — can sign up to ${PATH_LEN} more CA level(s))"
        fi
    else
        type_label="Leaf"
    fi

    echo ""
    echo -e "  ${BOLD}─── Certificate — Review ───────────────────────────────────────${NC}"
    echo ""
    echo    "    CN:     ${cn}"
    echo    "    Type:   ${type_label}"
    echo    "    Key:    ${kty} ${size}"
    echo    "    Days:   ${days}"
    if ! $IS_CA && [ ${#sans[@]} -gt 0 ]; then
        echo "    SANs:"
        for s in "${sans[@]}"; do echo "      - ${s}"; done
    fi
    echo    "    Output: ${out_dir:-caller home}"
    echo ""
    echo -e "  ${BOLD}────────────────────────────────────────────────────────────────${NC}"
    echo ""
    local confirm; read -rp "  Add to custom-vars.yaml and mint? [y/N] " confirm
    [[ "$confirm" =~ ^[yY] ]] || { info "Cancelled."; exit 0; }

    # Build JSON
    local sans_json
    if [ ${#sans[@]} -gt 0 ]; then
        sans_json=$(printf '"%s",' "${sans[@]}"); sans_json="[${sans_json%,}]"
    else
        sans_json="[]"
    fi
    local json_entry="{\"cn\":\"${cn}\",\"sans\":${sans_json},\"days\":${days}"
    json_entry+=",\"kty\":\"${kty}\",\"size\":${size}"
    $IS_CA && json_entry+=",\"is_ca\":true,\"path_len\":${PATH_LEN}"
    [ -n "$out_dir" ] && json_entry+=",\"out_dir\":\"${out_dir}\""
    json_entry+="}"

    echo ""
    _vars_archive "mint-certs_${cn}"
    _vars_list_append "extra_certs" "$json_entry"
    echo ""

    info "Minting certificate..."
    echo ""
    _mint_extra_cert "$json_entry"
    echo ""
    ok "Certificate for '${cn}' minted."
}

# -----------------------------------------------------------------------
# do_service_cert
# Interactive or --apply mode: re-issue TLS certificates for the four
# core nginx-proxied services (dns, ldap, ca, certificates).
# -----------------------------------------------------------------------
do_service_cert() {
    echo -e "${BOLD}core-template service-cert${NC}"
    echo ""

    local vars_file="$VARS_FILE"
    [ -f "$vars_file" ] || { err "core-template not deployed (${vars_file} not found)."; exit 1; }

    if [ "$SUB_MODE" = "apply" ]; then
        info "Re-issuing all core service certificates..."
        echo ""
        run_service_certs
        echo ""
        ok "Service certificates re-issued."
        info "Reload nginx to apply: docker exec nginx nginx -s reload"
        return
    fi

    # --- Interactive: show current cert expiry then confirm ---
    local deploy_base domain
    deploy_base=$(python3 -c "import yaml; v=yaml.safe_load(open('${vars_file}')); print(v.get('deploy_base_dir','/opt'))")
    domain=$(python3 -c "import yaml; v=yaml.safe_load(open('${vars_file}')); print(v.get('domain','home'))")

    info "Current core service certificates:"
    echo ""
    for svc_host in "dns.${domain}" "ldap.${domain}" "ca.${domain}" "certificates.${domain}"; do
        local cert_path="${deploy_base}/nginx/certs/${svc_host}/fullchain.pem"
        if [[ -f "$cert_path" ]]; then
            local expiry
            expiry=$(openssl x509 -in "$cert_path" -noout -enddate 2>/dev/null | cut -d= -f2)
            printf "  %-30s expires %s\n" "${svc_host}" "${expiry}"
        else
            printf "  %-30s %b\n" "${svc_host}" "${YELLOW}(not yet issued)${NC}"
        fi
    done

    echo ""
    warn "Re-issuing will replace all four certificates. nginx must be reloaded after."
    local confirm; read -rp "  Re-issue all service certificates? [y/N] " confirm
    [[ "$confirm" =~ ^[yY] ]] || { info "Cancelled."; exit 0; }

    echo ""
    run_service_certs
    echo ""
    ok "Service certificates re-issued."
    info "Reload nginx to apply: docker exec nginx nginx -s reload"
}
