#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------
# setup.sh — Install, update, or run custom tasks for home-core
#
# Modes:
#   (default)    Full install: bootstrap Ansible, run entire playbook.
#   --update     Safe update: re-render scripts only, show config diffs.
#   --custom     Run specific Ansible tags (manual / advanced).
#
# Common flags:
#   --target <ip>   Run against a remote host (default: localhost)
#   --check         Show what would change without applying
#   --review        Dry-run with full file diffs (update mode)
#   --apply         Apply without interactive prompting
#   --force         Include config files in update (dangerous)
#   --tags t1,t2    Ansible tags (required with --custom)
#
# Examples:
#   sudo ./setup.sh                          # Full local install
#   sudo ./setup.sh --target 192.168.1.5     # Full remote install
#   sudo ./setup.sh --update                 # Interactive script update
#   sudo ./setup.sh --update --review        # Preview all changes
#   sudo ./setup.sh --update --apply         # Update scripts, no prompt
#   sudo ./setup.sh --update --force         # Overwrite everything
#   sudo ./setup.sh --custom --tags pki      # Run specific tags
#   sudo ./setup.sh --custom --tags files --check --diff  # Dry-run
# -----------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$SCRIPT_DIR/core"

# shellcheck source=core/version.sh
source "$CORE_DIR/version.sh"

# --- Defaults ---
TARGET_BASE="/opt"
TARGET="localhost"
MODE="install"
SUB_MODE="interactive"     # interactive | check | review | apply
FORCE=false
ANSIBLE_TAGS=""
EXTRA_ANSIBLE_ARGS=()

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
        --update) MODE="update" ;;
        --custom) MODE="custom" ;;
    esac
done

# Pass 2: parse all flags
set -- "${ARGS[@]}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)      usage ;;
        --update)       shift ;;  # already handled
        --custom)       shift ;;  # already handled
        --target)       TARGET="$2"; shift 2 ;;
        --review)       SUB_MODE="review"; shift ;;
        --apply)        SUB_MODE="apply"; shift ;;
        --force)        FORCE=true; shift ;;
        --tags)         ANSIBLE_TAGS="$2"; shift 2 ;;
        --version|-v)   SUB_MODE="version"; shift ;;
        --check)
            # In update mode: git-level summary. In custom mode: Ansible dry-run.
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

# Run the Ansible playbook
run_playbook() {
    local tag_args=()
    local extra=("$@")

    if [ -n "$ANSIBLE_TAGS" ]; then
        tag_args=(--tags "$ANSIBLE_TAGS")
    fi

    ansible-playbook "$CORE_DIR/core-setup.yml" \
        -e "target_host=${TARGET}" \
        -i "${TARGET}," \
        "${tag_args[@]+"${tag_args[@]}"}" \
        "${extra[@]+"${extra[@]}"}" \
        "${EXTRA_ANSIBLE_ARGS[@]+"${EXTRA_ANSIBLE_ARGS[@]}"}"
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
    [ "$INSTALLED_COMMIT" = "$REPO_COMMIT" ] && UP_TO_DATE=true
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
        [[ "$file" == *.j2 ]] && rendered+=("/opt/${file%.j2}")
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
            [ -z "$ANSIBLE_TAGS" ] && ANSIBLE_TAGS="files"
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
            [ -n "$INSTALLED_COMMIT" ] && ! $UP_TO_DATE && show_changes "$INSTALLED_COMMIT"

            if $FORCE; then
                warn "Force mode: ALL files will be overwritten, including configs."
                warn "This may overwrite local changes to BIND9, nginx, docker-compose, etc."
            fi

            info "Running playbook (tags: ${ANSIBLE_TAGS}) on ${TARGET}..."
            echo ""
            run_playbook
            echo ""
            write_version_file "$TARGET_BASE" "$SCRIPT_DIR"
            ok "Update complete."
            ;;

        interactive)
            ANSIBLE_TAGS="$tags"

            if $UP_TO_DATE; then
                read -rp "Already up to date. Re-render templates anyway? [y/N] " choice
                [[ "$choice" =~ ^[yY] ]] || { info "No changes applied."; exit 0; }
            else
                [ -n "$INSTALLED_COMMIT" ] && show_changes "$INSTALLED_COMMIT"
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

            info "Running playbook (tags: ${ANSIBLE_TAGS}) on ${TARGET}..."
            echo ""
            run_playbook
            echo ""
            write_version_file "$TARGET_BASE" "$SCRIPT_DIR"
            ok "Update complete."
            ;;
    esac
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
    install)  do_install ;;
    update)   do_update ;;
    custom)   do_custom ;;
esac
