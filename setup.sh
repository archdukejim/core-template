#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------
# setup.sh — Install, update, rollback, or uninstall core-template
#
# Modes:
#   (default)    Full install: bootstrap Ansible, run entire playbook.
#   --update     Safe update: re-render scripts only, show config diffs.
#   --upgrade    In-place automated feature upgrades (e.g. OpenLDAP).
#   --rollback   Restore a previous installation from the archive.
#   --uninstall  Tear down containers, users, and project directories.
#   --custom     Run specific Ansible tags (manual / advanced).
#   --package    Create offline dependency bundles on internet-connected hosts.
#   --install-bundle Install offline dependency bundles locally.
#
# Common flags:
#   --target <ip>       Run against a remote host (default: localhost)
#   --ssh-user <user>   SSH username for remote targets (prompts if not set)
#   --prereqs <path>         Path to the controller bundle (zip or dir from offline.sh --stage).
#                            Installs Ansible and collections locally from the bundle.
#   --prereqs-target <path>  Path to the target bundle (zip or dir from offline.sh --stage).
#                            Passed to the Ansible playbook so it installs system packages
#                            and Docker images on the target without internet access.
#   --offline           Skip external DNS resolution check. Use when the target
#                       has no internet access. Implies prerequisites must already
#                       be installed (or supply --prereqs).
#   --no-start          Bring down the docker containers after installation completes
#   --byoc                      Bring Your Own Certs mode. Do not auto-generate Step-CA certificates.
#   --ca-crt <path>             Path to root CA certificate (overrides ca_crt_path in custom-vars.yaml)
#   --ica-crt <path>            Path to intermediate CA certificate (overrides ica_crt_path)
#   --ica-key <path>            Path to intermediate CA private key (overrides ica_key_path)
#   --check             Show what would change without applying
#   --review            Dry-run with full file diffs (update mode)
#   --apply             Apply without interactive prompting
#   --force             Include config files in update, skip missing dependencies
#   --tags t1,t2        Ansible tags (required with --custom)
#
# Bundle Flags (--package, --install-bundle):
#   --output <dir>      Destination directory for built packages
#   --compress          Archive bundles as .tar.gz (default is loose directory)
#   --tar               Archive bundles as .tar
#   --no-images         Skip pulling and saving Docker images
#   --bundle-only       Only install the offline bundles, skip full provisioning
#
# Upgrade Flags (--upgrade):
#   --add-ldap          Perform an in-place upgrade to include OpenLDAP
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
#   sudo ./setup.sh --upgrade --add-ldap                 # In-place deploy OpenLDAP component
#   sudo ./setup.sh --export                             # Install and save build artifacts to ./builds/
#   sudo ./setup.sh --update                             # Interactive script update
#   sudo ./setup.sh --rollback                           # Restore from archive
#   sudo ./setup.sh --uninstall                          # Interactive teardown
# -----------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$SCRIPT_DIR/core"
PLAYBOOKS_DIR="$CORE_DIR/playbooks"
CUSTOM_VARS_FILE="$SCRIPT_DIR/custom-vars.yaml"

# Source library modules
source "$CORE_DIR/lib/output.sh"
source "$CORE_DIR/lib/ssh.sh"
source "$CORE_DIR/lib/prereqs.sh"
source "$CORE_DIR/lib/services.sh"
source "$CORE_DIR/lib/archive.sh"
source "$CORE_DIR/lib/package.sh"
source "$CORE_DIR/lib/upgrade.sh"
# --- Defaults ---
TARGET_BASE="/opt"
TARGET="localhost"
SSH_USER="${SUDO_USER:-}"   # default to invoking user; overridden by --ssh-user or prompt
NO_START=false
EXPORT_DIR=""
PREREQS_DIR=""              # controller bundle dir (set by --prereqs); installs Ansible + collections locally
TARGET_PREREQS_DIR=""       # target bundle dir (set by --prereqs-target); passed to Ansible for remote install
_PREREQS_TMPDIR=""          # temp dir created when --prereqs is a zip; cleaned up on exit
_TARGET_PREREQS_TMPDIR=""   # temp dir created when --prereqs-target is a zip; cleaned up on exit
OFFLINE=false               # skip external DNS check (set by --offline or implied by --prereqs)
_SSH_READY=false            # set after first ensure_ssh_access; prevents repeat prompts
MODE="install"
SUB_MODE="interactive"     # interactive | check | review | apply
FORCE=false
ANSIBLE_TAGS=""
EXTRA_ANSIBLE_ARGS=()
BYOC=false
CA_CRT_PATH=""              # set by --ca-crt; overrides ca_crt_path in custom-vars.yaml
ICA_CRT_PATH=""             # set by --ica-crt; overrides ica_crt_path
ICA_KEY_PATH=""             # set by --ica-key; overrides ica_key_path
FULL_INSTALL=false

# --- New Module Flags ---
NO_IMAGES=false
ADD_LDAP=false
MODE_UPGRADE_ONLY_EXISTING=false
BUNDLE_ONLY=false
PACK_FORMAT=""
OUTPUT_ARG=""
BUNDLE_ARG=""

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
        --rollback)       MODE="rollback" ;;
        --uninstall)      MODE="uninstall" ;;
        --custom)         MODE="custom" ;;
    esac
done

# Pass 2: parse all flags
set -- "${ARGS[@]}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)      usage ;;
        --package|--upgrade|--update|--rollback|--uninstall|--custom)  shift ;;  # already handled
        --install-bundle)
            if [[ -n "${2:-}" && "${2:-}" != --* ]]; then
                BUNDLE_ARG="$2"; shift 2
            else
                BUNDLE_ARG="both"; shift
            fi
            ;;
        --target)       TARGET="$2"; shift 2 ;;
        --ssh-user)     SSH_USER="$2"; shift 2 ;;
        --no-start)     NO_START=true; shift ;;
        --export)
            if [[ "${2:-}" != --* ]] && [ -n "${2:-}" ]; then
                EXPORT_DIR="$2"; shift 2
            else
                EXPORT_DIR="./builds"; shift
            fi
            ;;
        --prereqs)           PREREQS_DIR="$2"; OFFLINE=true; shift 2 ;;
        --prereqs-target)    TARGET_PREREQS_DIR="$2"; OFFLINE=true; shift 2 ;;
        --offline)           OFFLINE=true; shift ;;
        --byoc)              BYOC=true; shift ;;
        --ca-crt)            CA_CRT_PATH="$2"; shift 2 ;;
        --ica-crt)           ICA_CRT_PATH="$2"; shift 2 ;;
        --ica-key)           ICA_KEY_PATH="$2"; shift 2 ;;
        --review)            SUB_MODE="review"; shift ;;
        --apply)        SUB_MODE="apply"; shift ;;
        --force)        FORCE=true; shift ;;
        --full)         FULL_INSTALL=true; shift ;;
        --bundle-only)  BUNDLE_ONLY=true; shift ;;
        --no-images)    NO_IMAGES=true; shift ;;
        --add-ldap)     ADD_LDAP=true; shift ;;
        --only-existing) MODE_UPGRADE_ONLY_EXISTING="true"; shift ;;
        --compress)     PACK_FORMAT="tar.gz"; shift ;;
        --tar)          PACK_FORMAT="tar"; shift ;;
        --output)       OUTPUT_ARG="$2"; shift 2 ;;
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

# Inject cert path overrides into Ansible extra-vars if supplied via CLI
$BYOC                             && EXTRA_ANSIBLE_ARGS+=(-e byoc=true)
[ -n "$CA_CRT_PATH" ]             && EXTRA_ANSIBLE_ARGS+=(-e "ca_crt_path=${CA_CRT_PATH}")
[ -n "$ICA_CRT_PATH" ]            && EXTRA_ANSIBLE_ARGS+=(-e "ica_crt_path=${ICA_CRT_PATH}")
[ -n "$ICA_KEY_PATH" ]            && EXTRA_ANSIBLE_ARGS+=(-e "ica_key_path=${ICA_KEY_PATH}")
$OFFLINE                          && EXTRA_ANSIBLE_ARGS+=(-e offline=true)

if $FULL_INSTALL || [[ " ${ANSIBLE_TAGS} " =~ " add-ldap " ]]; then
    EXTRA_ANSIBLE_ARGS+=(-e install_ldap=true)
else
    EXTRA_ANSIBLE_ARGS+=(-e install_ldap=false)
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

    # Prefer the dedicated target bundle; fall back to PREREQS_DIR for backwards compatibility
    local prereqs_arg=()
    if [[ -n "$TARGET_PREREQS_DIR" ]]; then
        prereqs_arg=(-e "offline_prereqs_dir=${TARGET_PREREQS_DIR}")
    elif [[ -n "$PREREQS_DIR" ]]; then
        prereqs_arg=(-e "offline_prereqs_dir=${PREREQS_DIR}")
    fi

    ansible-playbook "$playbook_path" \
        -e "target_host=${TARGET}" \
        -e "ansible_user=${SSH_USER:-root}" \
        -i "${TARGET}," \
        "${conn_args[@]+"${conn_args[@]}"}" \
        "${become_args[@]+"${become_args[@]}"}" \
        "${tag_args[@]+"${tag_args[@]}"}" \
        "${prereqs_arg[@]+"${prereqs_arg[@]}"}" \
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

    # --- Resolve and validate --prereqs (controller) and --prereqs-target bundles ---
    _resolve_prereqs_dir

    # Resolve --prereqs-target: same logic as _resolve_prereqs_dir but for TARGET_PREREQS_DIR
    if [[ -n "$TARGET_PREREQS_DIR" ]]; then
        if [[ -f "$TARGET_PREREQS_DIR" && "$TARGET_PREREQS_DIR" == *.zip ]]; then
            info "Unpacking target prerequisites bundle: $(basename "$TARGET_PREREQS_DIR") ..."
            _TARGET_PREREQS_TMPDIR="$(mktemp -d /tmp/homecore-target-prereqs-XXXXXX)"
            trap 'rm -rf "$_TARGET_PREREQS_TMPDIR"' EXIT
            if command -v unzip &>/dev/null; then
                unzip -q "$TARGET_PREREQS_DIR" -d "$_TARGET_PREREQS_TMPDIR"
            elif command -v python3 &>/dev/null; then
                python3 -c "
import zipfile, sys
with zipfile.ZipFile(sys.argv[1]) as z:
    z.extractall(sys.argv[2])
" "$TARGET_PREREQS_DIR" "$_TARGET_PREREQS_TMPDIR"
            else
                err "Cannot unpack target bundle: neither 'unzip' nor 'python3' available."; exit 1
            fi
            TARGET_PREREQS_DIR="$(find "$_TARGET_PREREQS_TMPDIR" -mindepth 1 -maxdepth 1 -type d | head -1)"
            [[ -n "$TARGET_PREREQS_DIR" ]] || { err "Target bundle appears empty or malformed."; exit 1; }
            ok "Target bundle extracted to: $TARGET_PREREQS_DIR"
        fi
        [[ -d "$TARGET_PREREQS_DIR" ]] || { err "Target prerequisites directory not found: $TARGET_PREREQS_DIR"; exit 1; }
        TARGET_PREREQS_DIR="$(realpath "$TARGET_PREREQS_DIR")"
        info "Using offline target prerequisites: $TARGET_PREREQS_DIR"
        local _tscan="${TARGET_PREREQS_DIR}/scan-results.txt"
        if [[ -f "$_tscan" ]]; then
            local _tresult; _tresult="$(grep "^RESULT:" "$_tscan" | tail -1 || true)"
            if echo "$_tresult" | grep -qi "THREATS FOUND"; then
                warn "Target bundle was flagged by ClamAV:"; warn "  $_tresult"
                read -rp "$(echo -e "${YELLOW}Continue despite scan warning? [y/N]: ${NC}")" _yn
                [[ "${_yn,,}" == "y" ]] || { info "Aborted."; exit 0; }
            elif echo "$_tresult" | grep -qi "SKIPPED"; then
                warn "Target bundle was not ClamAV-scanned during staging."
            else
                ok "Target bundle scan result: ${_tresult#RESULT: }"
            fi
        else
            warn "No scan-results.txt in target bundle — integrity unverified."
        fi
    fi

    # --- DNS preconditioning ---
    if $OFFLINE; then
        warn "Offline mode — skipping external DNS resolution check."
        warn "Ensure prerequisites are installed via offline.sh before running setup."
    else
        local use_host_dns
        use_host_dns=$(grep 'use_host_dns:' "$CUSTOM_VARS_FILE" "$CORE_DIR/advanced-vars.yaml" 2>/dev/null | tail -1 | awk '{print $2}' | tr -d '"' | tr -d "'")
        use_host_dns=${use_host_dns:-"true"}

        if [ "$use_host_dns" = "false" ]; then
            local dns_server
            dns_server=$(grep 'dns_server:' "$CUSTOM_VARS_FILE" | awk '{print $2}' | tr -d '"' | tr -d "'")
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
    fi

    # --- Install local prerequisites (Ansible + collections) ---
    install_local_prereqs

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

    [ -n "$EXPORT_DIR" ] && export_build

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
            [ -n "$EXPORT_DIR" ] && export_build
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
            [ -n "$EXPORT_DIR" ] && export_build
            ok "Update complete."
            ;;
    esac
}

# -----------------------------------------------------------------------
# MODE: rollback
# -----------------------------------------------------------------------
do_rollback() {
    echo -e "${BOLD}core-template rollback${NC}"
    echo ""

    if ! list_snapshots; then
        err "No archive snapshots found in ${ARCHIVE_DIR}."
        info "Snapshots are created automatically before each update."
        exit 1
    fi

    echo ""
    read -rp "Select snapshot number to restore (or 'q' to cancel): " selection

    [[ "$selection" = "q" || -z "$selection" ]] && { info "Cancelled."; exit 0; }

    if ! [[ "$selection" =~ ^[0-9]+$ ]]; then
        err "Invalid selection."; exit 1
    fi

    local snap_dir
    if ! snap_dir=$(get_snapshot_dir "$selection"); then
        err "Snapshot #${selection} not found."; exit 1
    fi

    # Show what we're restoring
    local snap_version="unknown"
    if [ -f "$snap_dir/.version" ]; then
        # shellcheck disable=SC1090
        source "$snap_dir/.version"
        snap_version="${HOMECORE_VERSION:-0000000}  installed ${HOMECORE_INSTALLED_AT:-?}"
        [ -n "${HOMECORE_COMMIT_SHORT:-}" ] && [ "${HOMECORE_COMMIT_SHORT}" != "nogit" ] \
            && snap_version+="  (git: ${HOMECORE_COMMIT_SHORT})"
    fi

    echo ""
    warn "This will overwrite the current installation with snapshot:"
    echo -e "  ${BOLD}Version:${NC}  ${snap_version}"
    echo -e "  ${BOLD}Archive:${NC}  ${snap_dir}"
    echo ""

    # Show which directories will be restored
    echo -e "${BOLD}Directories to restore:${NC}"
    for dir in core "${SERVICE_DIRS[@]}"; do
        if [ -d "$snap_dir/$dir" ]; then
            echo -e "  ${GREEN}→${NC} ${TARGET_BASE}/${dir}/"
        fi
    done
    echo ""

    read -rp "Restore this snapshot? [y/N] " choice
    [[ "$choice" =~ ^[yY] ]] || { info "Cancelled."; exit 0; }

    # Archive current state first (so rollback of a rollback is possible)
    info "Archiving current state before rollback..."
    archive_snapshot > /dev/null || true

    # Restore from snapshot
    info "Restoring from ${snap_dir}..."

    if [ -d "$snap_dir/core" ]; then
        rsync -a --exclude='archive' "$snap_dir/core/" "$TARGET_BASE/core/"
    fi

    for dir in "${SERVICE_DIRS[@]}"; do
        if [ -d "$snap_dir/$dir" ]; then
            rsync -a "$snap_dir/$dir/" "$TARGET_BASE/$dir/"
        fi
    done

    # Restore the version file
    if [ -f "$snap_dir/.version" ]; then
        cp "$snap_dir/.version" "$TARGET_BASE/core/.version"
    fi

    echo ""
    ok "Rollback complete. Restored to ${snap_version}."
    warn "Services may need to be restarted to pick up changes:"
    echo -e "  ${CYAN}cd /opt/core && sudo docker compose restart${NC}"
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
        tsig_dirs=$(grep -h -A10 'tsig_keys:' "$CORE_DIR/advanced-vars.yaml" "$CUSTOM_VARS_FILE" 2>/dev/null | grep 'name:' | awk '{print $2}' | tr -d '"' | tr -d "'" || true)
        local tmpscript="/tmp/.core-template-uninstall-$$.sh"

        # Step 1: upload the teardown script (heredoc → no TTY conflict)
        ssh "${SSH_USER}@${TARGET}" "cat > ${tmpscript} && chmod 700 ${tmpscript}" << REMOTE
#!/bin/bash
set -euo pipefail
TARGET_BASE="${TARGET_BASE}"

if [ -f "\${TARGET_BASE}/core/docker-compose.yml" ]; then
    echo "[*] Stopping containers..."
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
        if [ -f "$TARGET_BASE/core/docker-compose.yml" ]; then
            info "Stopping containers..."
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
        done < <(grep -h -A10 'tsig_keys:' "$CORE_DIR/advanced-vars.yaml" "$CUSTOM_VARS_FILE" 2>/dev/null | grep 'name:' | awk '{print $2}' | tr -d '"' | tr -d "'" || true)
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
    package)        do_package ;;
    install_bundle)
        do_install_bundle "$BUNDLE_ARG"
        if [[ "$BUNDLE_ONLY" == "false" ]]; then
            do_install
        fi
        ;;
    upgrade)        do_upgrade ;;
    install)        do_install ;;
    update)         do_update ;;
    rollback)       do_rollback ;;
    uninstall)      do_uninstall ;;
    custom)         do_custom ;;
esac
