#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------
# setup.sh — Install, update, rollback, or uninstall home-core
#
# Modes:
#   (default)    Full install: bootstrap Ansible, run entire playbook.
#   --update     Safe update: re-render scripts only, show config diffs.
#   --rollback   Restore a previous installation from the archive.
#   --uninstall  Tear down containers, users, and project directories.
#   --custom     Run specific Ansible tags (manual / advanced).
#
# Common flags:
#   --target <ip>      Run against a remote host (default: localhost)
#   --ssh-user <user>  SSH username for remote targets (prompts if not set)
#   --check            Show what would change without applying
#   --review           Dry-run with full file diffs (update mode)
#   --apply            Apply without interactive prompting
#   --force            Include config files in update (dangerous)
#   --tags t1,t2       Ansible tags (required with --custom)
#
# For live configuration changes (DNS records, TSIG keys, certificates):
#   Use modify.sh instead.
#
# Examples:
#   sudo ./setup.sh                              # Full local install
#   sudo ./setup.sh --target 192.168.1.5         # Full remote install
#   sudo ./setup.sh --update                     # Interactive script update
#   sudo ./setup.sh --update --review            # Preview all changes
#   sudo ./setup.sh --update --apply             # Update scripts, no prompt
#   sudo ./setup.sh --update --force --apply     # Overwrite everything
#   sudo ./setup.sh --rollback                   # Restore from archive
#   sudo ./setup.sh --uninstall                  # Interactive teardown
#   sudo ./setup.sh --custom --tags pki          # Run specific tags
# -----------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$SCRIPT_DIR/core"

# shellcheck source=core/version.sh
source "$CORE_DIR/version.sh"

# --- Defaults ---
TARGET_BASE="/opt"
TARGET="localhost"
SSH_USER="${SUDO_USER:-}"   # default to invoking user; overridden by --ssh-user or prompt
MODE="install"
SUB_MODE="interactive"     # interactive | check | review | apply
FORCE=false
ANSIBLE_TAGS=""
EXTRA_ANSIBLE_ARGS=()

ARCHIVE_DIR="$TARGET_BASE/core/archive"

# Directories that contain the live installation state
SERVICE_DIRS=(nginx adguardhome bind9 stepca openldap certbot easyrsa)
SERVICE_USERS_LIST=(nginx bind step ldap certbot adguard)

# --- Output helpers ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${CYAN}[*]${NC} $*"; }
ok()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*"; }

usage() {
    sed -n '3,/^# ---/{ /^# ---/d; s/^# \?//p }' "$0"
    exit 0
}

# --- Parse arguments (two-pass: modes first, then flags) ---
ARGS=("$@")
# Pass 1: extract mode
for arg in "${ARGS[@]}"; do
    case "$arg" in
        --update)     MODE="update" ;;
        --rollback)   MODE="rollback" ;;
        --uninstall)  MODE="uninstall" ;;
        --custom)     MODE="custom" ;;
    esac
done

# Pass 2: parse all flags
set -- "${ARGS[@]}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)      usage ;;
        --update|--rollback|--uninstall|--custom)  shift ;;  # already handled
        --target)       TARGET="$2"; shift 2 ;;
        --ssh-user)     SSH_USER="$2"; shift 2 ;;
        --review)       SUB_MODE="review"; shift ;;
        --apply)        SUB_MODE="apply"; shift ;;
        --force)        FORCE=true; shift ;;
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

# -----------------------------------------------------------------------
# Shared helpers
# -----------------------------------------------------------------------

# Validate git repo
if ! git -C "$SCRIPT_DIR" rev-parse --git-dir &>/dev/null; then
    err "Not a git repository: $SCRIPT_DIR"; exit 1
fi

# Prepare SSH access to a remote host:
#   1. Prompt for SSH_USER if not already set
#   2. Generate a local keypair if none exists
#   3. Add the remote host key to known_hosts (first-time trust)
#   4. Copy the public key to the remote (prompts for password if not yet authorized)
ensure_ssh_access() {
    local target="$1"

    if [ -z "$SSH_USER" ]; then
        read -rp "SSH username for ${target}: " SSH_USER
        [ -z "$SSH_USER" ] && { err "SSH username is required for remote targets."; exit 1; }
    fi

    mkdir -p ~/.ssh && chmod 700 ~/.ssh

    if ! ls ~/.ssh/id_*.pub &>/dev/null 2>&1; then
        info "No SSH keypair found — generating ed25519 key..."
        ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -C "home-core@$(hostname)"
        ok "SSH keypair generated: ~/.ssh/id_ed25519"
    fi

    if ! ssh-keygen -F "$target" &>/dev/null; then
        info "Scanning SSH host key for ${target}..."
        ssh-keyscan -H "$target" >> ~/.ssh/known_hosts 2>/dev/null
        ok "Host key added to known_hosts."
    fi

    info "Authorizing SSH key on ${SSH_USER}@${target} (enter remote password if prompted)..."
    if ssh-copy-id "${SSH_USER}@${target}"; then
        ok "SSH key authorized on ${target}."
    else
        err "Failed to authorize SSH key on ${SSH_USER}@${target}."
        exit 1
    fi
}

# Run the Ansible playbook
run_playbook() {
    export ANSIBLE_CONFIG="$CORE_DIR/ansible.cfg"
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
        ensure_ssh_access "$TARGET"
        # Playbook uses become: true — non-root users need sudo password on the remote
        if [ "${SSH_USER}" != "root" ]; then
            become_args=(--ask-become-pass)
        fi
    fi

    ansible-playbook "$CORE_DIR/core-config.yml" \
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
# Archive helpers
# -----------------------------------------------------------------------

# Create a snapshot of the current installation before applying changes.
# Stores into $ARCHIVE_DIR/<commit-short>_<timestamp>/
# Returns the snapshot directory path via stdout.
archive_snapshot() {
    local version_file="$TARGET_BASE/core/.version"

    if [ ! -f "$version_file" ]; then
        warn "No .version file found — nothing to archive."
        return 1
    fi

    # Read current installed version
    local snap_commit snap_date
    # shellcheck disable=SC1090
    source "$version_file"
    snap_commit="${HOMECORE_COMMIT_SHORT:-unknown}"
    snap_date="$(date -u '+%Y%m%d-%H%M%S')"

    local snap_dir="$ARCHIVE_DIR/${snap_commit}_${snap_date}"
    mkdir -p "$snap_dir"

    info "Archiving current installation (${snap_commit}) to ${snap_dir}..."

    # Copy the version file first
    cp "$version_file" "$snap_dir/.version"

    # Archive core/ (excluding the archive dir itself)
    if [ -d "$TARGET_BASE/core" ]; then
        rsync -a --exclude='archive' "$TARGET_BASE/core/" "$snap_dir/core/"
    fi

    # Archive each service directory
    for dir in "${SERVICE_DIRS[@]}"; do
        if [ -d "$TARGET_BASE/$dir" ]; then
            rsync -a "$TARGET_BASE/$dir/" "$snap_dir/$dir/"
        fi
    done

    ok "Archived to ${snap_dir}"
    echo "$snap_dir"
}

# List available archive snapshots, newest first.
# Output: one line per snapshot with version info.
list_snapshots() {
    if [ ! -d "$ARCHIVE_DIR" ]; then
        return 1
    fi

    local found=false
    local i=0
    while IFS= read -r snap_dir; do
        [ -d "$snap_dir" ] || continue
        local ver_file="$snap_dir/.version"
        if [ -f "$ver_file" ]; then
            # shellcheck disable=SC1090
            (
                source "$ver_file"
                printf "  %d)  %-10s  %s  %s\n" "$i" \
                    "${HOMECORE_COMMIT_SHORT:-?}" \
                    "${HOMECORE_COMMIT_DATE:-?}" \
                    "${HOMECORE_COMMIT_MSG:-}"
            )
            found=true
        else
            printf "  %d)  %s  (no version info)\n" "$i" "$(basename "$snap_dir")"
            found=true
        fi
        ((i++))
    done < <(find "$ARCHIVE_DIR" -mindepth 1 -maxdepth 1 -type d | sort -r)

    $found
}

# Get the Nth snapshot directory (0 = newest).
get_snapshot_dir() {
    local index="$1"
    local i=0
    while IFS= read -r snap_dir; do
        [ -d "$snap_dir" ] || continue
        if [ "$i" -eq "$index" ]; then
            echo "$snap_dir"
            return 0
        fi
        ((i++))
    done < <(find "$ARCHIVE_DIR" -mindepth 1 -maxdepth 1 -type d | sort -r)
    return 1
}

# -----------------------------------------------------------------------
# Version & change display (used by --update)
# -----------------------------------------------------------------------
gather_versions() {
    REPO_COMMIT=$(git -C "$SCRIPT_DIR" rev-parse HEAD)
    REPO_SHORT=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD)
    REPO_DATE=$(git -C "$SCRIPT_DIR" log -1 --format='%ci' HEAD)
    REPO_MSG=$(git -C "$SCRIPT_DIR" log -1 --format='%s' HEAD)
    REPO_BRANCH=$(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "detached")

    INSTALLED_COMMIT=""
    INSTALLED_SHORT=""
    INSTALLED_DATE=""
    if read_version_file "$TARGET_BASE" 2>/dev/null; then
        INSTALLED_COMMIT="$HOMECORE_COMMIT"
        INSTALLED_SHORT="$HOMECORE_COMMIT_SHORT"
        INSTALLED_DATE="$HOMECORE_COMMIT_DATE"
    fi

    UP_TO_DATE=false
    [ "$INSTALLED_COMMIT" = "$REPO_COMMIT" ] && UP_TO_DATE=true || true
}

show_versions() {
    echo ""
    if [ -n "$INSTALLED_COMMIT" ]; then
        echo -e "  ${BOLD}Installed:${NC}  ${INSTALLED_SHORT}  ${INSTALLED_DATE}"
    else
        echo -e "  ${BOLD}Installed:${NC}  ${YELLOW}(no .version file)${NC}"
    fi
    echo -e "  ${BOLD}Repo HEAD:${NC}  ${REPO_SHORT}  ${REPO_DATE}  [${REPO_BRANCH}]"
    echo -e "              ${REPO_MSG}"
    echo ""
    if $UP_TO_DATE; then
        ok "Installation is up to date."
    elif [ -n "$INSTALLED_COMMIT" ]; then
        warn "Installation differs from repo HEAD."
    fi
}

show_changes() {
    local base="$1"
    echo ""
    echo -e "${BOLD}Commits (${base:0:7} → ${REPO_SHORT}):${NC}"
    git -C "$SCRIPT_DIR" log --oneline --no-decorate "${base}..HEAD" | sed 's/^/  /'

    echo ""
    echo -e "${BOLD}Files changed:${NC}"
    git -C "$SCRIPT_DIR" diff --stat "${base}..HEAD" | sed 's/^/  /'

    local rendered=()
    while IFS= read -r file; do
        [[ "$file" == *.j2 ]] && rendered+=("/opt/${file%.j2}") || true
    done < <(git -C "$SCRIPT_DIR" diff --name-only "${base}..HEAD")

    if [ ${#rendered[@]} -gt 0 ]; then
        echo ""
        echo -e "${BOLD}Rendered files that will be updated:${NC}"
        printf "  ${GREEN}→${NC} %s\n" "${rendered[@]}"
    fi
}

# -----------------------------------------------------------------------
# MODE: install (default)
# -----------------------------------------------------------------------
do_install() {
    echo -e "${BOLD}home-core install${NC}"
    info "Target: ${TARGET}"
    echo ""

    # --- DNS preconditioning ---
    local dns_server
    dns_server=$(grep 'dns_server:' "$CORE_DIR/vars.yaml" | awk '{print $2}' | tr -d '"' | tr -d "'")
    dns_server=${dns_server:-"1.1.1.1"}

    info "Ensuring DNS resolution via ${dns_server}..."
    if [ ! -f "/etc/systemd/resolved.conf.d/adguard-bind.conf" ]; then
        info "Configuring systemd-resolved..."
        sudo mkdir -p /etc/systemd/resolved.conf.d/
        sudo tee /etc/systemd/resolved.conf.d/adguard-bind.conf > /dev/null <<EOF
[Resolve]
DNS=$dns_server
DNSStubListener=no
EOF
        sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
        sudo systemctl restart systemd-resolved
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

    # --- Install Ansible ---
    if ! command -v ansible-playbook &> /dev/null; then
        info "Installing Ansible via official PPA..."
        sudo apt update
        sudo apt install -y software-properties-common
        sudo add-apt-repository --yes --update ppa:ansible/ansible
        sudo apt install -y ansible
    fi

    # --- Install collections ---
    info "Ensuring Ansible collections are present..."
    ansible-galaxy collection install community.docker
    ansible-galaxy collection install community.general
    ansible-galaxy collection install ansible.posix

    # --- Run full playbook ---
    info "Running full playbook on ${TARGET}..."
    echo ""
    run_playbook

    # --- Write version ---
    echo ""
    write_version_file "$TARGET_BASE" "$SCRIPT_DIR"
    ok "Install complete."
}

# -----------------------------------------------------------------------
# MODE: update
# -----------------------------------------------------------------------
do_update() {
    echo -e "${BOLD}home-core update${NC}"

    if ! command -v ansible-playbook &>/dev/null; then
        err "ansible-playbook not found. Run setup.sh (install) first."; exit 1
    fi

    gather_versions
    show_versions

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
            if [ -n "$INSTALLED_COMMIT" ] && ! $UP_TO_DATE; then
                show_changes "$INSTALLED_COMMIT"
                echo ""
                info "Run with ${BOLD}--update --review${NC} to see exact file diffs."
                info "Run with ${BOLD}--update --apply${NC} to update scripts."
            elif [ -z "$INSTALLED_COMMIT" ]; then
                warn "No installed version found — run setup.sh for a fresh install."
            fi
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
            { [ -n "$INSTALLED_COMMIT" ] && ! $UP_TO_DATE && show_changes "$INSTALLED_COMMIT"; } || true

            if $FORCE; then
                warn "Force mode: ALL files will be overwritten, including configs."
                warn "This may overwrite local changes to BIND9, nginx, docker-compose, etc."
            fi

            # Archive before applying
            archive_snapshot > /dev/null || true

            info "Running playbook (tags: ${ANSIBLE_TAGS}) on ${TARGET}..."
            echo ""
            run_playbook
            echo ""
            write_version_file "$TARGET_BASE" "$SCRIPT_DIR"

            # Restart services to pick up rendered changes
            if [ -f "$TARGET_BASE/core/docker-compose.yml" ]; then
                info "Restarting services..."
                docker compose -f "$TARGET_BASE/core/docker-compose.yml" up -d
            fi

            ok "Update complete."
            ;;

        interactive)
            ANSIBLE_TAGS="$tags"

            if $UP_TO_DATE; then
                read -rp "Already up to date. Re-render templates anyway? [y/N] " choice
                [[ "$choice" =~ ^[yY] ]] || { info "No changes applied."; exit 0; }
            else
                { [ -n "$INSTALLED_COMMIT" ] && show_changes "$INSTALLED_COMMIT"; } || true
                echo ""

                if $FORCE; then
                    warn "Force mode: ALL files will be overwritten, including configs."
                    read -rp "Overwrite everything including configs? [y/N] " choice
                else
                    info "This will update ${BOLD}scripts only${NC}. Configs will not be touched."
                    info "Use ${BOLD}--review${NC} to preview all changes, or ${BOLD}--force${NC} to overwrite configs."
                    read -rp "Update scripts? [y/N] " choice
                fi

                [[ "$choice" =~ ^[yY] ]] || { info "No changes applied."; exit 0; }
            fi

            # Archive before applying
            archive_snapshot > /dev/null || true

            info "Running playbook (tags: ${ANSIBLE_TAGS}) on ${TARGET}..."
            echo ""
            run_playbook
            echo ""
            write_version_file "$TARGET_BASE" "$SCRIPT_DIR"

            # Restart services to pick up rendered changes
            if [ -f "$TARGET_BASE/core/docker-compose.yml" ]; then
                info "Restarting services..."
                docker compose -f "$TARGET_BASE/core/docker-compose.yml" up -d
            fi

            ok "Update complete."
            ;;
    esac
}

# -----------------------------------------------------------------------
# MODE: rollback
# -----------------------------------------------------------------------
do_rollback() {
    echo -e "${BOLD}home-core rollback${NC}"
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
        snap_version="${HOMECORE_COMMIT_SHORT:-?} (${HOMECORE_COMMIT_DATE:-?})"
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
    echo -e "${BOLD}home-core uninstall${NC}"
    echo ""
    warn "This will ${RED}permanently destroy${NC} the following:"
    echo ""
    echo "  - All Docker containers and networks managed by home-core"
    echo "  - Service accounts: ${SERVICE_USERS_LIST[*]}"
    echo "  - All data under ${TARGET_BASE}/:"
    for dir in core "${SERVICE_DIRS[@]}"; do
        [ -d "$TARGET_BASE/$dir" ] && echo "      ${TARGET_BASE}/${dir}/" || true
    done
    echo ""

    # Offer to save archive data
    if [ -d "$ARCHIVE_DIR" ]; then
        local snap_count
        snap_count=$(find "$ARCHIVE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
        if [ "$snap_count" -gt 0 ]; then
            info "Found ${snap_count} archived snapshot(s) in ${ARCHIVE_DIR}."
            read -rp "Save archive to another location before uninstalling? [y/N] " save_choice
            if [[ "$save_choice" =~ ^[yY] ]]; then
                read -rp "Destination directory: " save_dest
                if [ -z "$save_dest" ]; then
                    err "No destination provided. Aborting."
                    exit 1
                fi
                mkdir -p "$save_dest"
                info "Copying archive to ${save_dest}..."
                cp -a "$ARCHIVE_DIR" "$save_dest/"
                ok "Archive saved to ${save_dest}/archive/"
                echo ""
            fi
        fi
    fi

    # Also offer to snapshot current state before destruction
    if [ -f "$TARGET_BASE/core/.version" ]; then
        read -rp "Create a final snapshot of current state before uninstalling? [y/N] " snap_choice
        if [[ "$snap_choice" =~ ^[yY] ]]; then
            read -rp "Save snapshot to [${HOME}/home-core-backup]: " snap_dest
            snap_dest="${snap_dest:-${HOME}/home-core-backup}"
            mkdir -p "$snap_dest"
            info "Saving current installation to ${snap_dest}..."
            for dir in core "${SERVICE_DIRS[@]}"; do
                if [ -d "$TARGET_BASE/$dir" ]; then
                    rsync -a "$TARGET_BASE/$dir/" "$snap_dest/$dir/"
                fi
            done
            if [ -f "$TARGET_BASE/core/.version" ]; then
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

    echo ""

    # Stop and remove containers
    if [ -f "$TARGET_BASE/core/docker-compose.yml" ]; then
        info "Stopping containers..."
        docker compose -f "$TARGET_BASE/core/docker-compose.yml" down -v 2>/dev/null || true
    fi

    info "Pruning Docker networks..."
    docker network prune -f 2>/dev/null || true

    # Remove service accounts
    info "Removing service accounts..."
    for user in "${SERVICE_USERS_LIST[@]}"; do
        if id "$user" &>/dev/null; then
            userdel -r "$user" 2>/dev/null || userdel "$user" 2>/dev/null || true
            ok "Removed user: ${user}"
        fi
    done

    # Remove project directories
    info "Removing project directories from ${TARGET_BASE}/..."
    for dir in core "${SERVICE_DIRS[@]}"; do
        rm -rf "${TARGET_BASE:?}/${dir}"
    done

    # Also remove step-ca (alternate name for stepca)
    rm -rf "${TARGET_BASE:?}/step-ca" 2>/dev/null || true

    echo ""
    ok "Uninstall complete. System is ready for reinstallation."
}

# -----------------------------------------------------------------------
# MODE: custom
# -----------------------------------------------------------------------
do_custom() {
    echo -e "${BOLD}home-core custom${NC}"

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
    install)    do_install ;;
    update)     do_update ;;
    rollback)   do_rollback ;;
    uninstall)  do_uninstall ;;
    custom)     do_custom ;;
esac
