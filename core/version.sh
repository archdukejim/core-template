#!/bin/bash
# -----------------------------------------------------------------------
# version.sh — Shared version utilities for home-core
#
# Versioning uses a monotonic serial number (e.g. 0000001) stored in the
# .version file at <target_dir>/core/.version.  The serial increments on
# every install or update.  Git metadata is captured when available but
# is never required — a warning is emitted if the working directory is
# not a git repository.
# -----------------------------------------------------------------------

# ── Internal: next serial ──────────────────────────────────────────────────────
# Reads the current HOMECORE_VERSION from an existing .version file and
# returns the next zero-padded 7-digit serial.  Returns 0000001 when no
# prior version file exists.
_next_serial() {
    local version_file="$1"
    local current=0
    if [[ -f "$version_file" ]]; then
        # Strip leading zeros before arithmetic, then re-pad
        local raw
        raw=$(grep -E '^HOMECORE_VERSION=' "$version_file" 2>/dev/null \
              | head -1 | cut -d'"' -f2 | sed 's/^0*//')
        current=${raw:-0}
    fi
    printf '%07d' $(( current + 1 ))
}

# ── Internal: git metadata (best-effort) ──────────────────────────────────────
# Populates the variables below with git data when available.
# Sets GIT_AVAILABLE=true/false for callers.
_resolve_git_meta() {
    local repo_dir="$1"
    GIT_AVAILABLE=false
    GIT_COMMIT="nogit"
    GIT_COMMIT_SHORT="nogit"
    GIT_COMMIT_DATE=""
    GIT_COMMIT_MSG=""
    GIT_BRANCH="nogit"

    if ! command -v git &>/dev/null; then
        echo -e "\033[1;33m[!]\033[0m version.sh: 'git' not found — version tracking uses serial numbers only." >&2
        return
    fi

    if ! git -C "$repo_dir" rev-parse HEAD &>/dev/null 2>&1; then
        echo -e "\033[1;33m[!]\033[0m version.sh: '${repo_dir}' is not a git repository — version tracking uses serial numbers only." >&2
        return
    fi

    GIT_AVAILABLE=true
    GIT_COMMIT=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || echo "nogit")
    GIT_COMMIT_SHORT=$(git -C "$repo_dir" rev-parse --short HEAD 2>/dev/null || echo "nogit")
    GIT_COMMIT_DATE=$(git -C "$repo_dir" log -1 --format='%ci' HEAD 2>/dev/null || echo "")
    GIT_COMMIT_MSG=$(git -C "$repo_dir" log -1 --format='%s' HEAD 2>/dev/null || echo "")
    GIT_BRANCH=$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "detached")
}

# ── write_version_file ────────────────────────────────────────────────────────
# Write a .version file capturing the current serial and (optionally) git state.
# Usage: write_version_file <target_dir> <repo_dir> [remote_target] [ssh_user]
write_version_file() {
    local target_dir="$1"
    local repo_dir="$2"
    local remote_target="${3:-}"
    local ssh_user="${4:-}"

    local version_file="${target_dir}/core/.version"
    local serial
    serial=$(_next_serial "$version_file")

    _resolve_git_meta "$repo_dir"

    local installed_at
    installed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    local content
    content=$(cat <<EOF
# home-core installation version
# Written by install/update at $(date -u '+%Y-%m-%d %H:%M:%S UTC')
HOMECORE_VERSION="${serial}"
HOMECORE_COMMIT="${GIT_COMMIT}"
HOMECORE_COMMIT_SHORT="${GIT_COMMIT_SHORT}"
HOMECORE_COMMIT_DATE="${GIT_COMMIT_DATE}"
HOMECORE_COMMIT_MSG="${GIT_COMMIT_MSG}"
HOMECORE_BRANCH="${GIT_BRANCH}"
HOMECORE_INSTALLED_AT="${installed_at}"
EOF
)

    if [[ -n "$remote_target" && -n "$ssh_user" ]]; then
        ssh "${ssh_user}@${remote_target}" \
            "sudo tee ${version_file} > /dev/null && sudo chmod 0640 ${version_file}" \
            <<< "$content"
    else
        printf '%s\n' "$content" > "$version_file"
        chmod 0640 "$version_file"
    fi

    local git_note=""
    $GIT_AVAILABLE && git_note=" (git: ${GIT_COMMIT_SHORT})"
    echo "[+] Version file written: ${serial}${git_note} installed at ${installed_at}"
}

# ── read_version_file ─────────────────────────────────────────────────────────
# Source the installed .version file, populating HOMECORE_* vars.
# Returns 1 if the file does not exist.
# Usage: read_version_file <target_dir>
read_version_file() {
    local target_dir="$1"
    local version_file="${target_dir}/core/.version"

    if [[ ! -f "$version_file" ]]; then
        return 1
    fi

    # shellcheck disable=SC1090
    source "$version_file"
    return 0
}

# ── version_stamp ─────────────────────────────────────────────────────────────
# Return a short human-readable version stamp for use in rendered files.
# Prefers serial + git short hash when git is available; serial only otherwise.
# Usage: version_stamp <repo_dir> [target_dir]
version_stamp() {
    local repo_dir="$1"
    local target_dir="${2:-}"

    # Determine serial from installed .version if available, else "0000000"
    local serial="0000000"
    if [[ -n "$target_dir" ]]; then
        local vf="${target_dir}/core/.version"
        if [[ -f "$vf" ]]; then
            local raw
            raw=$(grep -E '^HOMECORE_VERSION=' "$vf" 2>/dev/null \
                  | head -1 | cut -d'"' -f2)
            serial="${raw:-0000000}"
        fi
    fi

    _resolve_git_meta "$repo_dir"
    if $GIT_AVAILABLE; then
        echo "home-core ${serial} (git: ${GIT_COMMIT_SHORT}, ${GIT_COMMIT_DATE})"
    else
        echo "home-core ${serial}"
    fi
}
