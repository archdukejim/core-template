#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------
# setup.sh — Install, update, rollback, or uninstall core-template
#
# Modes:
#   (default)    Full install: bootstrap Ansible, run entire playbook.
#   --update     Safe update: re-render scripts only, show config diffs.
#   --rollback   Restore a previous installation from the archive.
#   --uninstall  Tear down containers, users, and project directories.
#   --custom     Run specific Ansible tags (manual / advanced).
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
#   --start             Run 'docker compose up -d' after install completes
#   --export [path]     Save deployed configs to a local build archive after install/update
#                       Default path: ./builds/<commit>-<timestamp>/
#   --check             Show what would change without applying
#   --review            Dry-run with full file diffs (update mode)
#   --apply             Apply without interactive prompting
#   --force             Include config files in update (dangerous)
#   --tags t1,t2        Ansible tags (required with --custom)
#
# For live configuration changes (DNS records, TSIG keys, certificates):
#   Use modify.sh instead.
#
# Examples:
#   sudo ./setup.sh                                      # Full local install (internet)
#   sudo ./setup.sh --prereqs ./core-template-controller.zip --prereqs-target ./core-template-target.zip
#   sudo ./setup.sh --offline --prereqs-target ./core-template-target.zip  # Ansible already installed
#   sudo ./setup.sh --start                             # Install and start services
#   sudo ./setup.sh --target 192.168.1.5                # Full remote install
#   sudo ./setup.sh --target 192.168.1.5 --prereqs ./bundle.zip --start
#   sudo ./setup.sh --export                            # Install and save build artifacts to ./builds/
#   sudo ./setup.sh --export /srv/builds                # Install and save build artifacts to /srv/builds/
#   sudo ./setup.sh --update                            # Interactive script update
#   sudo ./setup.sh --update --review                   # Preview all changes
#   sudo ./setup.sh --update --apply                    # Update scripts, no prompt
#   sudo ./setup.sh --update --force --apply            # Overwrite everything
#   sudo ./setup.sh --rollback                          # Restore from archive
#   sudo ./setup.sh --uninstall                         # Interactive teardown
#   sudo ./setup.sh --custom --tags pki                 # Run specific tags
# -----------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$SCRIPT_DIR/core"

# --- Defaults ---
TARGET_BASE="/opt"
TARGET="localhost"
SSH_USER="${SUDO_USER:-}"   # default to invoking user; overridden by --ssh-user or prompt
START_SERVICES=false
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

ARCHIVE_DIR="$TARGET_BASE/core/archive"

# Directories that contain the live installation state
SERVICE_DIRS=(nginx bind9 stepca openldap easyrsa)
SERVICE_USERS_LIST=(nginx bind step ldap)

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
        --start)        START_SERVICES=true; shift ;;
        --export)
            if [[ "${2:-}" != --* ]] && [ -n "${2:-}" ]; then
                EXPORT_DIR="$2"; shift 2
            else
                EXPORT_DIR="./builds"; shift
            fi
            ;;
        --prereqs)         PREREQS_DIR="$2"; OFFLINE=true; shift 2 ;;
        --prereqs-target)  TARGET_PREREQS_DIR="$2"; OFFLINE=true; shift 2 ;;
        --offline)         OFFLINE=true; shift ;;
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

# Warn if not a git repository (non-fatal — serial versioning is used instead)
if ! command -v git &>/dev/null || ! git -C "$SCRIPT_DIR" rev-parse --git-dir &>/dev/null 2>&1; then
    warn "Not a git repository: $SCRIPT_DIR — version tracking uses serial numbers only."
fi

# Set a scalar value in vars.yaml using targeted sed replacement.
# Only suitable for simple booleans and integers — never rewrites the whole file,
# so Jinja2 expressions and comments in the file are always preserved.
# Usage: _vars_set <key> <value>   (value: true/false or an integer)
_vars_set() {
    local key="$1" val="$2" file="$CORE_DIR/vars.yaml"
    if grep -q "^${key}:" "$file"; then
        sed -i "s|^${key}:.*|${key}: ${val}|" "$file"
    else
        printf '\n%s: %s\n' "$key" "$val" >> "$file"
    fi
}

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
        ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -C "core-template@$(hostname)"
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

# Start services via docker compose on the target (local or remote)

# Export deployed configs to a git-tracked local directory.
# EXPORT_DIR is the repo root — each export is one commit, git history IS the versioning.
# On first use the directory is initialised as a git repo automatically.
export_build() {
    local serial timestamp git_ref
    # Prefer the just-written serial from the installed .version file
    if read_version_file "$TARGET_BASE" 2>/dev/null; then
        serial="${HOMECORE_VERSION:-0000000}"
    else
        serial="0000000"
    fi
    git_ref="$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "nogit")"
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    info "Exporting build artifacts to ${EXPORT_DIR}..."
    mkdir -p "$EXPORT_DIR"

    # Initialise a git repo in the export dir on first use (for diff history)
    if [ ! -d "${EXPORT_DIR}/.git" ]; then
        git -C "$EXPORT_DIR" init
        git -C "$EXPORT_DIR" symbolic-ref HEAD refs/heads/main
        ok "Initialised git repository at ${EXPORT_DIR}"
    fi

    local dirs=(core "${SERVICE_DIRS[@]}")

    if [ "$TARGET" = "localhost" ] || [ "$TARGET" = "127.0.0.1" ]; then
        for dir in "${dirs[@]}"; do
            [ -d "${TARGET_BASE}/${dir}" ] && rsync -a "${TARGET_BASE}/${dir}/" "${EXPORT_DIR}/${dir}/" || true
        done
    else
        for dir in "${dirs[@]}"; do
            rsync -az "${SSH_USER}@${TARGET}:${TARGET_BASE}/${dir}/" \
                "${EXPORT_DIR}/${dir}/" 2>/dev/null || true
        done
    fi

    # Write manifest alongside artifacts
    {
        echo "version:   ${serial}"
        echo "git_ref:   ${git_ref}"
        echo "target:    ${TARGET}"
        echo "timestamp: ${timestamp}"
        echo "mode:      ${MODE}"
    } > "${EXPORT_DIR}/build.manifest"

    git -C "$EXPORT_DIR" add -A
    if git -C "$EXPORT_DIR" diff --cached --quiet; then
        info "No changes since last export — nothing to commit."
    else
        git -C "$EXPORT_DIR" \
            -c user.name="core-template" \
            -c user.email="core-template@$(hostname)" \
            commit -m "build(${MODE}): ${serial} → ${TARGET} [${timestamp}]"
        ok "Build exported and committed to ${EXPORT_DIR}"
    fi
}

# -----------------------------------------------------------------------
# Prerequisite management
#
# LOCAL prerequisites (needed on the machine running setup.sh):
#   - ansible, ansible-playbook, ansible-galaxy
#   - python3, python3-yaml  (used by setup.sh and ansible)
#   - rsync, ssh-client      (used for remote targets and export)
#
# REMOTE prerequisites (needed on the target machine — installed by Ansible):
#   - docker-ce, docker-ce-cli, containerd.io, docker-buildx-plugin,
#     docker-compose-plugin   (container runtime)
#   - python3-docker          (Ansible Docker modules)
#   - acl, openssl, ca-certificates, curl, gnupg, ufw  (system hardening)
#   - Docker images: nginx, ubuntu/bind9, smallstep/step-ca, alpine
#
# When --prereqs <path> is supplied, both categories are served from the
# offline bundle instead of the internet.
# -----------------------------------------------------------------------

# Resolve --prereqs: if a zip file, unpack it and point PREREQS_DIR at the
# extracted directory.  Registers a cleanup trap for the temp dir.
_resolve_prereqs_dir() {
    [[ -n "$PREREQS_DIR" ]] || return 0

    if [[ -f "$PREREQS_DIR" && "$PREREQS_DIR" == *.zip ]]; then
        info "Unpacking prerequisites bundle: $(basename "$PREREQS_DIR") ..."
        _PREREQS_TMPDIR="$(mktemp -d /tmp/homecore-prereqs-XXXXXX)"
        trap 'rm -rf "$_PREREQS_TMPDIR"' EXIT

        if command -v unzip &>/dev/null; then
            unzip -q "$PREREQS_DIR" -d "$_PREREQS_TMPDIR"
        elif command -v python3 &>/dev/null; then
            python3 -c "
import zipfile, sys
with zipfile.ZipFile(sys.argv[1]) as z:
    z.extractall(sys.argv[2])
" "$PREREQS_DIR" "$_PREREQS_TMPDIR"
        else
            err "Cannot unpack bundle: neither 'unzip' nor 'python3' is available."
            exit 1
        fi

        # Bundle zip contains one top-level directory
        PREREQS_DIR="$(find "$_PREREQS_TMPDIR" -mindepth 1 -maxdepth 1 -type d | head -1)"
        [[ -n "$PREREQS_DIR" ]] || { err "Bundle appears empty or malformed."; exit 1; }
        ok "Bundle extracted to: $PREREQS_DIR"
    fi

    [[ -d "$PREREQS_DIR" ]] || { err "Prerequisites directory not found: $PREREQS_DIR"; exit 1; }
    PREREQS_DIR="$(realpath "$PREREQS_DIR")"
    info "Using offline prerequisites: $PREREQS_DIR"

    # Warn if scan result was not clean
    local scan_log="${PREREQS_DIR}/scan-results.txt"
    if [[ -f "$scan_log" ]]; then
        local result
        result="$(grep "^RESULT:" "$scan_log" | tail -1 || true)"
        if echo "$result" | grep -qi "THREATS FOUND"; then
            warn "This bundle was flagged by ClamAV during staging:"
            warn "  $result"
            read -rp "$(echo -e "${YELLOW}Continue installation despite scan warning? [y/N]: ${NC}")" _yn
            [[ "${_yn,,}" == "y" ]] || { info "Aborted."; exit 0; }
        elif echo "$result" | grep -qi "SKIPPED"; then
            warn "Bundle was not ClamAV-scanned during staging."
        else
            ok "Bundle scan result: ${result#RESULT: }"
        fi
    else
        warn "No scan-results.txt found — bundle integrity is unverified."
    fi
}

# Install local prerequisites (Ansible + collections) from the offline bundle.
_install_local_prereqs_offline() {
    local bundle="$1"
    local deb_dir="${bundle}/apt"
    local coll_dir="${bundle}/collections"

    if ! command -v ansible-playbook &>/dev/null; then
        [[ -d "$deb_dir" ]] || { err "apt/ directory not found in bundle: $bundle"; exit 1; }
        local deb_count
        deb_count=$(find "$deb_dir" -name "*.deb" | wc -l)
        [[ "$deb_count" -gt 0 ]] || { err "No .deb files found in bundle apt/ directory."; exit 1; }

        info "Installing local prerequisites from bundle ($deb_count packages)..."
        mapfile -t _debs < <(find "$deb_dir" -name "*.deb" | sort)
        dpkg -i --force-depends "${_debs[@]}" 2>&1 | \
            grep -v "^\(Reading database\|Preparing to unpack\|Unpacking\|Setting up\|Processing triggers\)" || true
        apt-get install -f -y --no-install-recommends \
            -o Dir::Cache::Archives="$deb_dir" \
            -o APT::Get::AllowUnauthenticated=true 2>/dev/null || true
        ok "Ansible installed from bundle."
    else
        ok "Ansible already installed: $(ansible --version 2>/dev/null | head -1)"
    fi

    if [[ -d "$coll_dir" ]]; then
        info "Installing Ansible collections from bundle..."
        local installed=0
        for tarball in "${coll_dir}"/*.tar.gz; do
            [[ -f "$tarball" ]] || continue
            ansible-galaxy collection install "$tarball" --offline 2>/dev/null || \
            ansible-galaxy collection install "$tarball" || true
            (( installed++ )) || true
        done
        ok "Installed $installed collection(s) from bundle."
    else
        warn "collections/ directory not found in bundle — skipping collection install."
    fi
}

# Install local prerequisites (Ansible + collections) from the internet.
_install_local_prereqs_online() {
    if ! command -v ansible-playbook &>/dev/null; then
        info "Installing Ansible via official PPA..."
        apt-get update -qq
        apt-get install -y software-properties-common
        add-apt-repository --yes --update ppa:ansible/ansible
        apt-get install -y ansible
    else
        ok "Ansible already installed: $(ansible --version 2>/dev/null | head -1)"
    fi

    info "Ensuring Ansible collections are present..."
    ansible-galaxy collection install community.docker
    ansible-galaxy collection install community.general
    ansible-galaxy collection install ansible.posix
}

# Entry point: install local prerequisites from bundle or internet.
install_local_prereqs() {
    if [[ -n "$PREREQS_DIR" ]]; then
        _install_local_prereqs_offline "$PREREQS_DIR"
    else
        _install_local_prereqs_online
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

    ansible-playbook "$CORE_DIR/core-config.yml" \
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
# Archive helpers
# -----------------------------------------------------------------------

# Create a snapshot of the current installation before applying changes.
# Stores into $ARCHIVE_DIR/<commit-short>_<timestamp>/
# Returns the snapshot directory path via stdout.
archive_snapshot() {
    # Use docker-compose.yml presence as the signal that an installation exists.
    # The .version file was removed in favour of git-based tracking.
    local compose_file="$TARGET_BASE/core/docker-compose.yml"
    if [ ! -f "$compose_file" ]; then
        info "No existing installation detected — skipping archive."
        return 1
    fi

    local snap_ref snap_date
    snap_ref="$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "nogit")"
    snap_date="$(date -u '+%Y%m%d-%H%M%S')"
    local snap_dir="$ARCHIVE_DIR/${snap_ref}_${snap_date}"
    mkdir -p "$snap_dir"

    info "Archiving current installation to ${snap_dir}..."

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
                local git_part=""
                [ -n "${HOMECORE_COMMIT_SHORT:-}" ] && [ "${HOMECORE_COMMIT_SHORT}" != "nogit" ] \
                    && git_part="  (git: ${HOMECORE_COMMIT_SHORT})"
                printf "  %d)  %-10s  %s%s  %s\n" "$i" \
                    "${HOMECORE_VERSION:-0000000}" \
                    "${HOMECORE_INSTALLED_AT:-?}" \
                    "${git_part}" \
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
    # .version file was removed — detect installation via docker-compose.yml presence
    INSTALLED_SERIAL=""
    INSTALLED_COMMIT=""
    INSTALLED_SHORT=""
    INSTALLED_DATE=""
    if [ -f "$TARGET_BASE/core/docker-compose.yml" ]; then
        INSTALLED_SERIAL="(installed)"
    fi

    # Git metadata — non-fatal; warn if unavailable
    REPO_COMMIT=""
    REPO_SHORT=""
    REPO_DATE=""
    REPO_MSG=""
    REPO_BRANCH=""
    GIT_AVAILABLE_LOCAL=false
    if command -v git &>/dev/null && git -C "$SCRIPT_DIR" rev-parse HEAD &>/dev/null 2>&1; then
        GIT_AVAILABLE_LOCAL=true
        REPO_COMMIT=$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || true)
        REPO_SHORT=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || true)
        REPO_DATE=$(git -C "$SCRIPT_DIR" log -1 --format='%ci' HEAD 2>/dev/null || true)
        REPO_MSG=$(git -C "$SCRIPT_DIR" log -1 --format='%s' HEAD 2>/dev/null || true)
        REPO_BRANCH=$(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "detached")
    else
        warn "Not a git repository — cannot determine repo state."
    fi

    # Without a .version file we can't compare installed commit to repo HEAD
    UP_TO_DATE=false
}

show_versions() {
    echo ""
    if [ -f "$TARGET_BASE/core/docker-compose.yml" ]; then
        echo -e "  ${BOLD}Installed:${NC}  installation detected at ${TARGET_BASE}/core/"
    else
        echo -e "  ${BOLD}Installed:${NC}  ${YELLOW}(no installation found at ${TARGET_BASE}/core/)${NC}"
    fi
    if $GIT_AVAILABLE_LOCAL; then
        echo -e "  ${BOLD}Repo HEAD:${NC}  ${REPO_SHORT}  ${REPO_DATE}  [${REPO_BRANCH}]"
        [ -n "$REPO_MSG" ] && echo -e "              ${REPO_MSG}"
    fi
    echo ""
    if [ -z "$INSTALLED_SERIAL" ]; then
        warn "No installation found — run setup.sh for a fresh install."
    fi
}

show_changes() {
    local base="$1"

    if ! $GIT_AVAILABLE_LOCAL; then
        warn "Git not available — cannot show change diff."
        return
    fi

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
        warn "Ensure all prerequisites are installed on the target before continuing."
        warn "Use --prereqs <bundle> if packages/images have not been installed yet."
    else
        local dns_server
        dns_server=$(grep 'dns_server:' "$CORE_DIR/vars.yaml" | awk '{print $2}' | tr -d '"' | tr -d "'")
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
    $START_SERVICES && EXTRA_ANSIBLE_ARGS+=(-e start_services=true)
    run_playbook

    echo ""
    $START_SERVICES || {
        info "Services not started. Run: ${BOLD}docker compose -f ${TARGET_BASE}/core/docker-compose.yml up -d${NC}"
        info "Or re-run with ${BOLD}--start${NC} to start automatically."
    }

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

            $START_SERVICES && EXTRA_ANSIBLE_ARGS+=(-e start_services=true)
            info "Running playbook (tags: ${ANSIBLE_TAGS}) on ${TARGET}..."
            echo ""
            run_playbook
            echo ""
            [ -n "$EXPORT_DIR" ] && export_build
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

            $START_SERVICES && EXTRA_ANSIBLE_ARGS+=(-e start_services=true)
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

    # Offer to save archive data
    local snap_count=0
    if $is_remote; then
        snap_count=$(ssh "${SSH_USER}@${TARGET}" \
            "sudo find '${ARCHIVE_DIR}' -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l" 2>/dev/null || echo 0)
    elif [ -d "$ARCHIVE_DIR" ]; then
        snap_count=$(find "$ARCHIVE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    fi

    if [ "$snap_count" -gt 0 ]; then
        info "Found ${snap_count} archived snapshot(s) in ${ARCHIVE_DIR} on ${TARGET}."
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
                rsync -az "${SSH_USER}@${TARGET}:${ARCHIVE_DIR}/" "$save_dest/"
            else
                cp -a "$ARCHIVE_DIR" "$save_dest/"
            fi
            ok "Archive saved to ${save_dest}/"
            echo ""
        fi
    fi

    # Offer to snapshot current state
    local has_version=false
    if $is_remote; then
        ssh "${SSH_USER}@${TARGET}" "sudo test -f '${TARGET_BASE}/core/.version'" 2>/dev/null \
            && has_version=true || true
    elif [ -f "$TARGET_BASE/core/.version" ]; then
        has_version=true
    fi

    if $has_version; then
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

    echo ""

    if $is_remote; then
        info "Running teardown on ${TARGET}..."
        # Expand lists locally so the remote script has literal values
        local users_list="${SERVICE_USERS_LIST[*]}"
        local dirs_list="core ${SERVICE_DIRS[*]}"
        # Parse tsig_keys names from vars.yaml for credential dir cleanup
        local tsig_dirs
        tsig_dirs=$(grep -A1 'tsig_keys:' "$CORE_DIR/vars.yaml" | grep '^\s*name:' | awk '{print $2}' || true)
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
        done < <(grep -A1 'tsig_keys:' "$CORE_DIR/vars.yaml" | grep '^\s*name:' | awk '{print $2}' || true)
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
    install)    do_install ;;
    update)     do_update ;;
    rollback)   do_rollback ;;
    uninstall)  do_uninstall ;;
    custom)     do_custom ;;
esac
