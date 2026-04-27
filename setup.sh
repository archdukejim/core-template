#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------
# setup.sh — Install, update, or uninstall core-template
#
# Modes:
#   (default)    Full install: bootstrap Ansible, run entire playbook.
#   --update     Safe update: re-render scripts only, show config diffs.
#   --upgrade    In-place automated feature upgrades (e.g. OpenLDAP).
#   --uninstall  Tear down containers, users, and project directories.
#   --custom     Run specific Ansible tags (manual / advanced).

#
# Common flags:
#   --target <ip>       Run against a remote host (default: localhost)
#   --ssh-user <user>   SSH username for remote targets (prompts if not set)
#   --check             Show what would change without applying
#   --review            Dry-run with full file diffs (update mode)
#   --apply             Apply without interactive prompting
#   --force             Include config files in update, skip missing dependencies
#   --tags t1,t2        Ansible tags (required with --custom)
#

# Upgrade Flags (--upgrade):
#   --only-existing     Only upgrade existing features; avoid new automated features
#
# For live configuration changes (DNS records, TSIG keys, certificates):
#   Use core/manage.sh instead.
#
# Examples:
#   sudo ./setup.sh                                      # Full local install (internet)
#   sudo ./setup.sh --install-bundle target              # Install just the target bundle
#   sudo ./setup.sh --install-bundle both                # Install local bundles and run setup
#   sudo ./setup.sh --package --compress                 # Generate compressed offline bundles here
#   sudo ./setup.sh --target 192.168.1.5                 # Full remote install

#   sudo ./setup.sh --update                             # Interactive script update
#   sudo ./setup.sh --uninstall                          # Interactive teardown
# -----------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$SCRIPT_DIR/core"
PLAYBOOKS_DIR="$CORE_DIR/playbooks"
CUSTOM_VARS_FILE="$SCRIPT_DIR/custom-vars.yaml"

# Source library modules
source "$CORE_DIR/lib/output.sh"
source "$CORE_DIR/lib/ssh.sh"
source "$CORE_DIR/lib/services.sh"
source "$CORE_DIR/lib/archive.sh"
source "$CORE_DIR/lib/upgrade.sh"
# --- Defaults ---
TARGET_BASE="/opt"
TARGET="localhost"
SSH_USER="${SUDO_USER:-}"   # default to invoking user; overridden by --ssh-user or prompt
NO_START=false
OFFLINE=false
_SSH_READY=false            # set after first ensure_ssh_access; prevents repeat prompts
MODE="install"
SUB_MODE="interactive"     # interactive | check | review | apply
FORCE=false
ANSIBLE_TAGS=""
EXTRA_ANSIBLE_ARGS=()
FULL_INSTALL=false

MODE_UPGRADE_ONLY_EXISTING=false

ARCHIVE_DIR="$TARGET_BASE/core/archive"

# Directories that contain the live installation state
SERVICE_DIRS=(nginx bind9 stepca openldap)
SERVICE_USERS_LIST=(nginx bind step ldap)

# --- Parse arguments (two-pass: modes first, then flags) ---
ARGS=("$@")
# Pass 1: extract mode
for arg in "${ARGS[@]}"; do
    case "$arg" in
        --package)        MODE="package" ;;
        --install-bundle) MODE="install_bundle" ;;
        --upgrade)        MODE="upgrade" ;;
        --update)         MODE="update" ;;
        --uninstall)      MODE="uninstall" ;;
        --custom)         MODE="custom" ;;
    esac
done

# Pass 2: parse all flags
set -- "${ARGS[@]}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)      usage ;;
        --package|--upgrade|--update|--uninstall|--custom)  shift ;;  # already handled

        --target)       TARGET="$2"; shift 2 ;;
        --ssh-user)     SSH_USER="$2"; shift 2 ;;
        --no-start)     NO_START=true; shift ;;
        --offline)      OFFLINE=true; shift ;;

        --review)            SUB_MODE="review"; shift ;;
        --apply)        SUB_MODE="apply"; shift ;;
        --force)        FORCE=true; shift ;;
        --full)         FULL_INSTALL=true; shift ;;

        --only-existing) MODE_UPGRADE_ONLY_EXISTING="true"; shift ;;

        --tags)         ANSIBLE_TAGS="$2"; shift 2 ;;
        --version|-v)   SUB_MODE="version"; shift ;;
        --check)
            # In update mode: git-level summary. In custom/other mode: Ansible dry-run.
            if [ "$MODE" = "update" ]; then
                SUB_MODE="check"
            else
                EXTRA_ANSIBLE_ARGS+=("$1")
            fi
            shift ;;
        *)              EXTRA_ANSIBLE_ARGS+=("$1"); shift ;;
    esac
done

$OFFLINE && EXTRA_ANSIBLE_ARGS+=(-e offline=true)

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
        err "Run 'setup.sh --install-bundle controller' to install prerequisites."
        exit 1
    fi

    local playbook_path="$PLAYBOOKS_DIR/core-config.yml"
    if [[ "${1:-}" == *.yml ]]; then
        playbook_path="$1"
        shift
    fi

    export ANSIBLE_CONFIG="$PLAYBOOKS_DIR/ansible.cfg"
    local tag_args=()
    local conn_args=()
    local become_args=()
    local extra=("$@")

    if [ -n "$ANSIBLE_TAGS" ]; then
        tag_args=(--tags "$ANSIBLE_TAGS")
    fi

    if [ "$TARGET" = "localhost" ] || [ "$TARGET" = "127.0.0.1" ]; then
        conn_args=(--connection=local)
    else
        if ! $_SSH_READY; then
            ensure_ssh_access "$TARGET"
            _SSH_READY=true
        fi
        
        # Playbook uses become: true — non-root users need sudo password on the remote
        if [ "${SSH_USER}" != "root" ]; then
            become_args=(--ask-become-pass)
        fi
    fi

    ansible-playbook "$playbook_path" \
        -e "target_host=${TARGET}" \
        -e "ansible_user=${SSH_USER:-root}" \
        -i "${TARGET}," \
        "${conn_args[@]+"${conn_args[@]}"}" \
        "${become_args[@]+"${become_args[@]}"}" \
        "${tag_args[@]+"${tag_args[@]}"}" \
        "${extra[@]+"${extra[@]}"}" \
        "${EXTRA_ANSIBLE_ARGS[@]+"${EXTRA_ANSIBLE_ARGS[@]}"}"
}

# -----------------------------------------------------------------------
# MODE: install (default)
# -----------------------------------------------------------------------
do_install() {
    echo -e "${BOLD}core-template install${NC}"
    info "Target: ${TARGET}"
    echo ""

    # --- DNS preconditioning ---
    if $OFFLINE; then
        warn "Offline mode — skipping external DNS resolution check."
        warn "Proceeding without installing any system packages. Playbook will fail if dependencies are missing."
    else
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
    info "Running full playbook on ${TARGET}..."
    echo ""
    $NO_START && EXTRA_ANSIBLE_ARGS+=(-e no_start=true)
    run_playbook

    echo ""
    if $NO_START; then
        info "Services were brought down (--no-start)."
        info "Run manually: ${BOLD}docker compose -f ${TARGET_BASE}/core/docker-compose.yml up -d${NC}"
    else
        ok "Services are running."
    fi

    ok "Install complete."
}

# -----------------------------------------------------------------------
# MODE: update
# -----------------------------------------------------------------------
do_update() {
    echo -e "${BOLD}core-template update${NC}"

    if ! command -v ansible-playbook &>/dev/null; then
        err "ansible-playbook not found. Run setup.sh (install) first."; exit 1
    fi
    # Resolve effective tags
    local tags
    if [ -n "$ANSIBLE_TAGS" ]; then
        tags="$ANSIBLE_TAGS"
    elif $FORCE; then
        tags="files"
    else
        tags="update"
    fi

    case "$SUB_MODE" in
        version) ;;

        check)
            info "Run with ${BOLD}--update --review${NC} to see exact file diffs."
            info "Run with ${BOLD}--update --apply${NC} to update scripts."
            ;;

        review)
            # Review always shows everything (files tag) unless user specified --tags
            [ -z "$ANSIBLE_TAGS" ] && ANSIBLE_TAGS="files" || true
            info "Review mode: showing what would change (tags: ${ANSIBLE_TAGS})..."
            info "No files will be modified."
            echo ""

            run_playbook --check --diff

            echo ""
            ok "Review complete. No changes were applied."
            echo ""
            info "To update scripts only:  ${BOLD}sudo ./setup.sh --update --apply${NC}"
            info "To overwrite everything: ${BOLD}sudo ./setup.sh --update --force --apply${NC}  ${RED}(dangerous)${NC}"
            ;;

        apply)
            ANSIBLE_TAGS="$tags"
            if $FORCE; then
                warn "Force mode: ALL files will be overwritten, including configs."
                warn "This may overwrite local changes to BIND9, nginx, docker-compose, etc."
            fi

            # Archive before applying
            archive_snapshot > /dev/null || true

            $NO_START && EXTRA_ANSIBLE_ARGS+=(-e no_start=true)
            info "Running playbook (tags: ${ANSIBLE_TAGS}) on ${TARGET}..."
            echo ""
            run_playbook
            echo ""

            ok "Update complete."
            ;;

        interactive)
            ANSIBLE_TAGS="$tags"

            if $FORCE; then
                warn "Force mode: ALL files will be overwritten, including configs."
                read -rp "Overwrite everything including configs? [y/N] " choice
            else
                info "This will update ${BOLD}scripts only${NC}. Configs will not be touched."
                info "Use ${BOLD}--review${NC} to preview all changes, or ${BOLD}--force${NC} to overwrite configs."
                read -rp "Update scripts? [y/N] " choice
            fi

            [[ "$choice" =~ ^[yY] ]] || { info "No changes applied."; exit 0; }

            # Archive before applying
            archive_snapshot > /dev/null || true

            $NO_START && EXTRA_ANSIBLE_ARGS+=(-e no_start=true)
            info "Running playbook (tags: ${ANSIBLE_TAGS}) on ${TARGET}..."
            echo ""
            run_playbook
            echo ""

            ok "Update complete."
            ;;
    esac
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
        # Offer to save archive data
        local ask_save=false
        if $is_remote; then
            ask_save=true
            info "Remote archive snapshots may exist in ${ARCHIVE_DIR}."
        elif [ -d "$ARCHIVE_DIR" ]; then
            local snap_count=0
            snap_count=$(find "$ARCHIVE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l || echo 0)
            if [ "$snap_count" -gt 0 ]; then
                ask_save=true
                info "Found ${snap_count} archived snapshot(s) in ${ARCHIVE_DIR} on ${TARGET}."
            fi
        fi

        if $ask_save; then
            read -rp "Copy archive to local machine before uninstalling? [y/N] " save_choice
            if [[ "$save_choice" =~ ^[yY] ]]; then
                read -rp "Local destination directory: " save_dest
                if [ -z "$save_dest" ]; then
                    err "No destination provided. Aborting."
                    exit 1
                fi
                mkdir -p "$save_dest"
                info "Copying archive to ${save_dest}..."
                if $is_remote; then
                    # The rsync will require password if sudo is needed, but we don't have to use sudo
                    # Wait, rsync as SSH_USER might not be able to read ARCHIVE_DIR!
                    # Actually, we fallback to asking sudo rsync, but we just use SSH_USER and if it fails, it fails gracefully.
                    rsync -az "${SSH_USER}@${TARGET}:${ARCHIVE_DIR}/" "$save_dest/" 2>/dev/null || \
                        rsync -az --rsync-path="sudo rsync" "${SSH_USER}@${TARGET}:${ARCHIVE_DIR}/" "$save_dest/"
                else
                    cp -a "$ARCHIVE_DIR" "$save_dest/"
                fi
                ok "Archive saved to ${save_dest}/"
                echo ""
            fi
        fi

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
        local tmpscript="/tmp/.core-template-uninstall-$$.sh"

        # Step 1: upload the teardown script (heredoc → no TTY conflict)
        ssh "${SSH_USER}@${TARGET}" "cat > ${tmpscript} && chmod 700 ${tmpscript}" << REMOTE
#!/bin/bash
set -euo pipefail
TARGET_BASE="${TARGET_BASE}"

echo "[*] Stopping and removing systemd services..."
for svc in nginx bind9 ldap stepca; do
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

echo "[*] Removing service accounts..."
for user in ${users_list}; do
    if id "\$user" &>/dev/null; then
        userdel -r "\$user" 2>/dev/null || userdel "\$user" 2>/dev/null || true
        echo "[+] Removed user: \$user"
    fi
done

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
REMOTE

        # Step 2: execute with a TTY so sudo can prompt for the password
        ssh -t "${SSH_USER}@${TARGET}" "sudo bash ${tmpscript}; rm -f ${tmpscript}"
    else
        info "Stopping and removing systemd services..."
        for svc in nginx bind9 ldap stepca; do
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

        info "Removing service accounts..."
        for user in "${SERVICE_USERS_LIST[@]}"; do
            if id "$user" &>/dev/null; then
                userdel -r "$user" 2>/dev/null || userdel "$user" 2>/dev/null || true
                ok "Removed user: ${user}"
            fi
        done

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
    fi

    echo ""
    ok "Uninstall complete. System is ready for reinstallation."
}

# -----------------------------------------------------------------------
# MODE: custom
# -----------------------------------------------------------------------
do_custom() {
    echo -e "${BOLD}core-template custom${NC}"

    if [ -z "$ANSIBLE_TAGS" ]; then
        err "Custom mode requires --tags. Example: --custom --tags pki,bind9"
        exit 1
    fi

    if ! command -v ansible-playbook &>/dev/null; then
        err "ansible-playbook not found. Run setup.sh (install) first."; exit 1
    fi

    info "Running playbook (tags: ${ANSIBLE_TAGS}) on ${TARGET}..."
    echo ""
    run_playbook
    echo ""
    ok "Done."
}

# -----------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------
case "$MODE" in

    upgrade)        do_upgrade ;;
    install)        do_install ;;
    update)         do_update ;;
    uninstall)      do_uninstall ;;
    custom)         do_custom ;;
esac
