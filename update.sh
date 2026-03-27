#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------
# update.sh — Inspect, diff, and apply updates from the home-core repo
#
# Usage:
#   sudo ./update.sh              # Interactive: show changes, prompt to apply
#   sudo ./update.sh --check      # Show what would change, then exit
#   sudo ./update.sh --apply      # Apply without prompting
#   sudo ./update.sh --version    # Show installed vs repo version
#   sudo ./update.sh --tags t1,t2 # Pass specific Ansible tags (default: files)
# -----------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR"
CORE_DIR="$SCRIPT_DIR/core"

# shellcheck source=core/version.sh
source "$CORE_DIR/version.sh"

TARGET_BASE="/opt"
MODE="interactive"
EXTRA_ANSIBLE_ARGS=()
ANSIBLE_TAGS="files"

# --- Output helpers ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${CYAN}[*]${NC} $*"; }
ok()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*"; }

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check|--dry-run)  MODE="check"; shift ;;
        --apply)            MODE="apply"; shift ;;
        --version|-v)       MODE="version"; shift ;;
        --tags)             ANSIBLE_TAGS="$2"; shift 2 ;;
        *)                  EXTRA_ANSIBLE_ARGS+=("$1"); shift ;;
    esac
done

# --- Validate git repo ---
if ! git -C "$REPO_DIR" rev-parse --git-dir &>/dev/null; then
    err "Not a git repository: $REPO_DIR"; exit 1
fi

# --- Gather versions ---
REPO_COMMIT=$(git -C "$REPO_DIR" rev-parse HEAD)
REPO_SHORT=$(git -C "$REPO_DIR" rev-parse --short HEAD)
REPO_DATE=$(git -C "$REPO_DIR" log -1 --format='%ci' HEAD)
REPO_MSG=$(git -C "$REPO_DIR" log -1 --format='%s' HEAD)
REPO_BRANCH=$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "detached")

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

# -----------------------------------------------------------------------
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
    git -C "$REPO_DIR" log --oneline --no-decorate "${base}..HEAD" | sed 's/^/  /'

    echo ""
    echo -e "${BOLD}Files changed:${NC}"
    git -C "$REPO_DIR" diff --stat "${base}..HEAD" | sed 's/^/  /'

    # Show which rendered files will be updated
    local rendered=()
    while IFS= read -r file; do
        [[ "$file" == *.j2 ]] && rendered+=("/opt/${file%.j2}")
    done < <(git -C "$REPO_DIR" diff --name-only "${base}..HEAD")

    if [ ${#rendered[@]} -gt 0 ]; then
        echo ""
        echo -e "${BOLD}Rendered files that will be updated:${NC}"
        printf "  ${GREEN}→${NC} %s\n" "${rendered[@]}"
    fi
}

apply_update() {
    if ! command -v ansible-playbook &>/dev/null; then
        err "ansible-playbook not found. Run install.sh first."; exit 1
    fi

    local target
    target=$(grep 'target_host:' "$CORE_DIR/core-target-vars.yml" | awk '{print $2}' | tr -d '"' | tr -d "'")
    target="${target:-localhost}"

    info "Running playbook (tags: ${ANSIBLE_TAGS}) on ${target}..."
    echo ""

    ansible-playbook "$CORE_DIR/core-setup.yml" \
        -e "target_host=${target}" \
        -i "${target}," \
        --tags "${ANSIBLE_TAGS}" \
        "${EXTRA_ANSIBLE_ARGS[@]+"${EXTRA_ANSIBLE_ARGS[@]}"}"

    echo ""
    write_version_file "$TARGET_BASE" "$REPO_DIR"
    ok "Update complete."
}

# -----------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------
echo -e "${BOLD}home-core update${NC}"
show_versions

case "$MODE" in
    version) ;;

    check)
        if [ -n "$INSTALLED_COMMIT" ] && ! $UP_TO_DATE; then
            show_changes "$INSTALLED_COMMIT"
            echo ""
            info "Run with ${BOLD}--apply${NC} to apply these changes."
        elif [ -z "$INSTALLED_COMMIT" ]; then
            warn "No installed version found — run install.sh for a fresh install."
        fi
        ;;

    apply)
        [ -n "$INSTALLED_COMMIT" ] && ! $UP_TO_DATE && show_changes "$INSTALLED_COMMIT"
        apply_update
        ;;

    interactive)
        if $UP_TO_DATE; then
            read -rp "Already up to date. Re-render templates anyway? [y/N] " choice
            [[ "$choice" =~ ^[yY] ]] && apply_update || info "No changes applied."
            exit 0
        fi

        [ -n "$INSTALLED_COMMIT" ] && show_changes "$INSTALLED_COMMIT"

        echo ""
        read -rp "Apply these changes? [y/N] " choice
        [[ "$choice" =~ ^[yY] ]] && apply_update || info "No changes applied."
        ;;
esac
