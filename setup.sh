#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------
# setup.sh — Install or uninstall core-template
#
# Flags:
#   --remote <user>@<ip> Run against a remote host (e.g. root@192.168.1.5)
#   --uninstall         Tear down containers, users, and project directories.
#   --force             Skip confirmations (useful with --uninstall)
#
# Any other arguments are passed directly to ansible-playbook.
# -----------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$SCRIPT_DIR/core"
PLAYBOOKS_DIR="$CORE_DIR/playbooks"
if [ -f "$SCRIPT_DIR/custom-vars.yaml" ]; then
    CUSTOM_VARS_FILE="$SCRIPT_DIR/custom-vars.yaml"
elif [ -f "$SCRIPT_DIR/config/vars.yaml" ]; then
    CUSTOM_VARS_FILE="$SCRIPT_DIR/config/vars.yaml"
else
    CUSTOM_VARS_FILE="$SCRIPT_DIR/custom-vars.yaml"
fi

# Source library modules
source "$CORE_DIR/lib/output.sh"
source "$CORE_DIR/lib/ssh.sh"
source "$CORE_DIR/lib/services.sh"

# --- Defaults ---
TARGET_BASE="/opt"
TARGET="localhost"
SSH_USER="${SUDO_USER:-}"   # default to invoking user; overridden by --ssh-user or prompt
_SSH_READY=false            # set after first ensure_ssh_access; prevents repeat prompts
MODE="install"
FORCE=false
EXTRA_ANSIBLE_ARGS=()

# Directories that contain the live installation state
SERVICE_DIRS=(nginx bind9 stepca openldap keycloak postgres)
SERVICE_USERS_LIST=(nginx bind step ldap keycloak postgres)

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            cat <<EOF
Usage: $0 [OPTIONS] [ANSIBLE_ARGS...]

Install or uninstall the core-template infrastructure.

Options:
  -h, --help            Show this help message and exit.
  --remote USER@HOST    Run against a remote host via SSH. (e.g. root@192.168.1.5)
                        If USER@ is omitted, uses the current or default SSH user.
  --uninstall           Tear down containers, users, and project directories.
  --force               Skip confirmations (useful with --uninstall).

Any additional arguments are passed directly to ansible-playbook.

Examples:
  # Install locally using default playbook
  sudo $0

  # Install on a remote host
  sudo $0 --remote root@10.0.0.50

  # Run specific tags locally (passed to ansible-playbook)
  sudo $0 --tags nginx,bind9

  # Uninstall from a remote host without prompting
  sudo $0 --uninstall --remote admin@server.local --force
EOF
            exit 0
            ;;
        --uninstall)    MODE="uninstall"; shift ;;
        --remote)
            if [[ "$2" == *@* ]]; then
                SSH_USER="${2%%@*}"
                TARGET="${2#*@}"
            else
                TARGET="$2"
            fi
            shift 2
            ;;
        --force)        FORCE=true; shift ;;
        *)              EXTRA_ANSIBLE_ARGS+=("$1"); shift ;;
    esac
done

# Capture remote sudo password early to avoid waiting
if [ "$TARGET" != "localhost" ] && [ "$TARGET" != "127.0.0.1" ] && [ "${SSH_USER}" != "root" ]; then
    echo -n "Enter sudo password for ${SSH_USER}@${TARGET}: "
    read -rs REMOTE_SUDO_PASS
    echo ""
    
    # Create secure temp file for ansible
    BECOME_PASS_FILE=$(mktemp)
    chmod 600 "$BECOME_PASS_FILE"
    printf "%s\n" "$REMOTE_SUDO_PASS" > "$BECOME_PASS_FILE"
    
    # Ensure it gets cleaned up
    trap 'rm -f "$BECOME_PASS_FILE"' EXIT
fi

# -----------------------------------------------------------------------
# Shared helpers
# -----------------------------------------------------------------------

# Warn if not a git repository (non-fatal — serial versioning is used instead)
if ! command -v git &>/dev/null || ! git -C "$SCRIPT_DIR" rev-parse --git-dir &>/dev/null 2>&1; then
    warn "Not a git repository: $SCRIPT_DIR — version tracking uses serial numbers only."
fi

# -----------------------------------------------------------------------
# shared helper: run_playbook
# -----------------------------------------------------------------------
run_playbook() {
    if ! command -v ansible-playbook &>/dev/null; then
        err "ansible-playbook is missing."
        if [ "$TARGET" != "localhost" ] && [ "$TARGET" != "127.0.0.1" ]; then
            err "The --target parameter requires ansible to execute playbooks against remote hosts."
        fi
        exit 1
    fi

    local playbook_path="$PLAYBOOKS_DIR/core-config.yml"
    if [[ "${1:-}" == *.yml ]]; then
        playbook_path="$1"
        shift
    fi

    export ANSIBLE_CONFIG="$PLAYBOOKS_DIR/ansible.cfg"
    local conn_args=()
    local become_args=()
    local extra=("$@")

    if [ "$TARGET" = "localhost" ] || [ "$TARGET" = "127.0.0.1" ]; then
        conn_args=(--connection=local)
    else
        if ! $_SSH_READY; then
            ensure_ssh_access "$TARGET"
            _SSH_READY=true
        fi
        
        # Playbook uses become: true — non-root users need sudo password on the remote
        if [ "${SSH_USER}" != "root" ]; then
            if [ -n "${BECOME_PASS_FILE:-}" ] && [ -f "${BECOME_PASS_FILE:-}" ]; then
                become_args=(--become-password-file "$BECOME_PASS_FILE")
            else
                become_args=(--ask-become-pass)
            fi
        fi
    fi

    ansible-playbook "$playbook_path" \
        -e "custom_vars_path=${CUSTOM_VARS_FILE}" \
        -e "target_host=${TARGET}" \
        -e "ansible_user=${SSH_USER:-root}" \
        -i "${TARGET}," \
        "${conn_args[@]+"${conn_args[@]}"}" \
        "${become_args[@]+"${become_args[@]}"}" \
        "${extra[@]+"${extra[@]}"}" \
        "${EXTRA_ANSIBLE_ARGS[@]+"${EXTRA_ANSIBLE_ARGS[@]}"}"
}

# -----------------------------------------------------------------------
# MODE: install (default)
# -----------------------------------------------------------------------
do_install() {
    echo -e "${BOLD}core-template execution${NC}"
    info "Target: ${TARGET}"
    echo ""

    # --- DNS preconditioning ---
    local use_host_dns
    use_host_dns=$(grep 'use_host_dns:' "$CUSTOM_VARS_FILE" 2>/dev/null | tail -1 | awk '{print $2}' | tr -d '"' | tr -d "'" || true)
    use_host_dns=${use_host_dns:-"true"}

    if [ "$use_host_dns" = "false" ]; then
        local dns_server
        dns_server=$(grep 'dns_server:' "$CUSTOM_VARS_FILE" 2>/dev/null | awk '{print $2}' | tr -d '"' | tr -d "'" || true)
        dns_server=${dns_server:-"1.1.1.1"}

        info "Ensuring DNS resolution via ${dns_server}..."
        if [ ! -f "/etc/systemd/resolved.conf.d/core-dns.conf" ]; then
            info "Configuring systemd-resolved..."
            sudo mkdir -p /etc/systemd/resolved.conf.d/
            sudo tee /etc/systemd/resolved.conf.d/core-dns.conf > /dev/null <<EOF
[Resolve]
DNS=$dns_server
DNSStubListener=no
EOF
            sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
            sudo systemctl restart systemd-resolved
        fi
    else
        info "Using host DNS resolver (use_host_dns=true)."
    fi

    local check_domain="google.com"
    info "Verifying DNS resolution for ${check_domain}..."
    if ! host "$check_domain" > /dev/null 2>&1; then
        warn "DNS resolution failed. Retrying in 5 seconds..."
        sleep 5
        if ! host "$check_domain" > /dev/null 2>&1; then
            err "Unable to resolve ${check_domain}. Check your network or ${dns_server}."
            exit 1
        fi
    fi
    ok "DNS resolution verified."

    # --- Run full playbook ---
    info "Running playbook on ${TARGET}..."
    echo ""
    run_playbook

    echo ""
    ok "Playbook execution complete."
}

# -----------------------------------------------------------------------
# MODE: uninstall
# -----------------------------------------------------------------------
do_uninstall() {
    local is_remote=false
    if [ "$TARGET" != "localhost" ] && [ "$TARGET" != "127.0.0.1" ]; then
        is_remote=true
        ensure_ssh_access "$TARGET"
    fi

    echo -e "${BOLD}core-template uninstall${NC}"
    echo ""
    warn "This will ${RED}permanently destroy${NC} the following on ${TARGET}:"
    echo ""
    echo "  - All Docker containers and networks managed by core-template"
    echo "  - Service accounts: ${SERVICE_USERS_LIST[*]}"
    echo "  - All data under ${TARGET_BASE}/:"
    for dir in core "${SERVICE_DIRS[@]}"; do
        echo "      ${TARGET_BASE}/${dir}/"
    done
    echo ""

    if ! $FORCE; then
        # Offer to snapshot current state
        local ask_snap=false
        if $is_remote; then
            ask_snap=true
        elif [ -f "$TARGET_BASE/core/.version" ]; then
            ask_snap=true
        fi

        if $ask_snap; then
            read -rp "Save a final snapshot to this machine before uninstalling? [y/N] " snap_choice
            if [[ "$snap_choice" =~ ^[yY] ]]; then
                read -rp "Local destination [${HOME}/core-template-backup]: " snap_dest
                snap_dest="${snap_dest:-${HOME}/core-template-backup}"
                mkdir -p "$snap_dest"
                info "Saving snapshot to ${snap_dest}..."
                if $is_remote; then
                    for dir in core "${SERVICE_DIRS[@]}"; do
                        rsync -az "${SSH_USER}@${TARGET}:${TARGET_BASE}/${dir}/" \
                            "$snap_dest/${dir}/" 2>/dev/null || true
                    done
                    rsync -az "${SSH_USER}@${TARGET}:${TARGET_BASE}/core/.version" \
                        "$snap_dest/.version" 2>/dev/null || true
                else
                    for dir in core "${SERVICE_DIRS[@]}"; do
                        [ -d "$TARGET_BASE/$dir" ] && rsync -a "$TARGET_BASE/$dir/" "$snap_dest/$dir/"
                    done
                    [ -f "$TARGET_BASE/core/.version" ] && \
                        cp "$TARGET_BASE/core/.version" "$snap_dest/.version"
                fi
                ok "Snapshot saved to ${snap_dest}/"
                echo ""
            fi
        fi

        # Final confirmation
        echo -e "${RED}${BOLD}THIS ACTION IS IRREVERSIBLE.${NC}"
        read -rp "Type 'UNINSTALL' to confirm: " confirm
        if [ "$confirm" != "UNINSTALL" ]; then
            info "Cancelled."
            exit 0
        fi
    else
        warn "Force mode: skipping backups and confirmation."
    fi

    echo ""

    if $is_remote; then
        info "Running teardown on ${TARGET}..."
        # Expand lists locally so the remote script has literal values
        local users_list="${SERVICE_USERS_LIST[*]}"
        local dirs_list="core ${SERVICE_DIRS[*]}"
        # Parse tsig_keys names from vars.yaml for credential dir cleanup
        local tsig_dirs
        tsig_dirs=$(grep -h -A10 '^tsig_keys:' "$CUSTOM_VARS_FILE" 2>/dev/null | grep -E '^[[:space:]]*-.*name:' | awk -F'name:' '{print $2}' | awk -F',' '{print $1}' | tr -d " '\"" || true)
        
        # Parse data mounts locally to pass them as literals
        local kc_data_local
        kc_data_local=$(awk '/^keycloak_data_dir:/ {print $2}' "$CUSTOM_VARS_FILE" 2>/dev/null | tr -d '"' | tr -d "'" || true)
        local pg_data_local
        pg_data_local=$(awk '/^postgres_data_dir:/ {print $2}' "$CUSTOM_VARS_FILE" 2>/dev/null | tr -d '"' | tr -d "'" || true)

        local tmpscript="/tmp/.core-template-uninstall-$$.sh"

        # Step 1: upload the teardown script (heredoc → no TTY conflict)
        ssh "${SSH_USER}@${TARGET}" "cat > ${tmpscript} && chmod 700 ${tmpscript}" << REMOTE
#!/bin/bash
set -euo pipefail
TARGET_BASE="${TARGET_BASE}"

echo "[*] Stopping and removing systemd services..."
for svc in nginx bind9 ldap stepca keycloak postgres; do
    systemctl stop \$svc 2>/dev/null || true
    systemctl disable \$svc 2>/dev/null || true
    rm -f /etc/systemd/system/\$svc.service
done
systemctl daemon-reload || true

if [ -f "\${TARGET_BASE}/core/docker-compose.yml" ]; then
    echo "[*] Stopping remaining containers..."
    docker compose -f "\${TARGET_BASE}/core/docker-compose.yml" down -v 2>/dev/null || true
fi

echo "[*] Pruning Docker networks..."
docker network prune -f 2>/dev/null || true

echo "[*] Restarting Docker to clear stale networking rules..."
systemctl restart docker || true

echo "[*] Removing service accounts..."
for user in ${users_list}; do
    if id "\$user" &>/dev/null; then
        userdel -r "\$user" 2>/dev/null || userdel "\$user" 2>/dev/null || true
        echo "[+] Removed user: \$user"
    fi
done

echo "[*] Removing heavy workload data mounts..."
KC_DATA="${kc_data_local}"
if [[ -z "\$KC_DATA" ]]; then
    KC_DATA=\$(awk '/^keycloak_data_dir:/ {print \$2}' "\${TARGET_BASE}/core/config/vars.yaml" 2>/dev/null | tr -d '"' | tr -d "'" || true)
fi
PG_DATA="${pg_data_local}"
if [[ -z "\$PG_DATA" ]]; then
    PG_DATA=\$(awk '/^postgres_data_dir:/ {print \$2}' "\${TARGET_BASE}/core/config/vars.yaml" 2>/dev/null | tr -d '"' | tr -d "'" || true)
fi

if [[ -n "\$KC_DATA" && "\$KC_DATA" != "\${TARGET_BASE}/keycloak/data" && -d "\$KC_DATA" ]]; then
    rm -rf "\$KC_DATA"
    echo "[+] Removed Keycloak data mount: \$KC_DATA"
fi
if [[ -n "\$PG_DATA" && "\$PG_DATA" != "\${TARGET_BASE}/postgres/data" && -d "\$PG_DATA" ]]; then
    rm -rf "\$PG_DATA"
    echo "[+] Removed Postgres data mount: \$PG_DATA"
fi

echo "[*] Removing project directories..."
for dir in ${dirs_list}; do
    rm -rf "\${TARGET_BASE:?}/\$dir"
done
rm -rf "\${TARGET_BASE:?}/step-ca" 2>/dev/null || true

echo "[*] Removing TSIG credential directories..."
for tsig_dir in ${tsig_dirs}; do
    rm -rf "\${TARGET_BASE:?}/\${tsig_dir}"
    echo "[+] Removed: \${TARGET_BASE}/\${tsig_dir}"
done
# Catch any acme_* dirs not explicitly listed
find "\${TARGET_BASE}" -maxdepth 1 -name 'acme_*' -type d -exec rm -rf {} + 2>/dev/null || true

echo "[*] Removing global executable..."
rm -f /usr/local/bin/core-mgr
REMOTE

        # Step 2: execute remotely
        if [ -n "${REMOTE_SUDO_PASS:-}" ]; then
            printf "%s\n" "$REMOTE_SUDO_PASS" | ssh "${SSH_USER}@${TARGET}" "sudo -S bash ${tmpscript}; rm -f ${tmpscript}"
        else
            # Execute with a TTY so sudo can prompt for the password
            ssh -t "${SSH_USER}@${TARGET}" "sudo bash ${tmpscript}; rm -f ${tmpscript}"
        fi
    else
        info "Stopping and removing systemd services..."
        for svc in nginx bind9 ldap stepca keycloak postgres; do
            systemctl stop $svc 2>/dev/null || true
            systemctl disable $svc 2>/dev/null || true
            rm -f /etc/systemd/system/$svc.service
        done
        systemctl daemon-reload || true

        if [ -f "$TARGET_BASE/core/docker-compose.yml" ]; then
            info "Stopping remaining containers..."
            docker compose -f "$TARGET_BASE/core/docker-compose.yml" down -v 2>/dev/null || true
        fi

        info "Pruning Docker networks..."
        docker network prune -f 2>/dev/null || true

        info "Restarting Docker to clear stale networking rules..."
        systemctl restart docker || true

        info "Removing service accounts..."
        for user in "${SERVICE_USERS_LIST[@]}"; do
            if id "$user" &>/dev/null; then
                userdel -r "$user" 2>/dev/null || userdel "$user" 2>/dev/null || true
                ok "Removed user: ${user}"
            fi
        done

        info "Removing heavy workload data mounts..."
        KC_DATA=$(awk '/^keycloak_data_dir:/ {print $2}' "$CUSTOM_VARS_FILE" 2>/dev/null | tr -d '"' | tr -d "'" || true)
        if [[ -z "$KC_DATA" ]]; then
            KC_DATA=$(awk '/^keycloak_data_dir:/ {print $2}' "${TARGET_BASE}/core/config/vars.yaml" 2>/dev/null | tr -d '"' | tr -d "'" || true)
        fi
        PG_DATA=$(awk '/^postgres_data_dir:/ {print $2}' "$CUSTOM_VARS_FILE" 2>/dev/null | tr -d '"' | tr -d "'" || true)
        if [[ -z "$PG_DATA" ]]; then
            PG_DATA=$(awk '/^postgres_data_dir:/ {print $2}' "${TARGET_BASE}/core/config/vars.yaml" 2>/dev/null | tr -d '"' | tr -d "'" || true)
        fi

        if [[ -n "$KC_DATA" && "$KC_DATA" != "${TARGET_BASE}/keycloak/data" && -d "$KC_DATA" ]]; then
            rm -rf "$KC_DATA"
            ok "Removed Keycloak data mount: $KC_DATA"
        fi
        if [[ -n "$PG_DATA" && "$PG_DATA" != "${TARGET_BASE}/postgres/data" && -d "$PG_DATA" ]]; then
            rm -rf "$PG_DATA"
            ok "Removed Postgres data mount: $PG_DATA"
        fi

        info "Removing project directories from ${TARGET_BASE}/..."
        for dir in core "${SERVICE_DIRS[@]}"; do
            rm -rf "${TARGET_BASE:?}/${dir}"
        done
        rm -rf "${TARGET_BASE:?}/step-ca" 2>/dev/null || true

        info "Removing TSIG credential directories..."
        while IFS= read -r tsig_dir; do
            [ -z "$tsig_dir" ] && continue
            rm -rf "${TARGET_BASE:?}/${tsig_dir}"
            ok "Removed: ${TARGET_BASE}/${tsig_dir}"
        done < <(grep -h -A10 '^tsig_keys:' "$CUSTOM_VARS_FILE" 2>/dev/null | grep -E '^[[:space:]]*-.*name:' | awk -F'name:' '{print $2}' | awk -F',' '{print $1}' | tr -d " '\"" || true)
        find "${TARGET_BASE}" -maxdepth 1 -name 'acme_*' -type d -exec rm -rf {} + 2>/dev/null || true
        
        info "Removing global executable..."
        rm -f /usr/local/bin/core-mgr
    fi

    echo ""
    ok "Uninstall complete. System is ready for reinstallation."
}

# -----------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------
case "$MODE" in
    install)        do_install ;;
    uninstall)      do_uninstall ;;
esac
