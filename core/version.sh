#!/bin/bash
# -----------------------------------------------------------------------
# version.sh — Shared version utilities for home-core
# -----------------------------------------------------------------------

# Write a .version file capturing the current repo state
# Usage: write_version_file <target_dir> <repo_dir>
write_version_file() {
    local target_dir="$1"
    local repo_dir="$2"
    local version_file="${target_dir}/core/.version"

    local commit_hash commit_short commit_date commit_msg branch

    commit_hash=$(git -C "$repo_dir" rev-parse HEAD)
    commit_short=$(git -C "$repo_dir" rev-parse --short HEAD)
    commit_date=$(git -C "$repo_dir" log -1 --format='%ci' HEAD)
    commit_msg=$(git -C "$repo_dir" log -1 --format='%s' HEAD)
    branch=$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "detached")

    cat > "$version_file" <<EOF
# home-core installation version
# Written by install/update at $(date -u '+%Y-%m-%d %H:%M:%S UTC')
HOMECORE_COMMIT="${commit_hash}"
HOMECORE_COMMIT_SHORT="${commit_short}"
HOMECORE_COMMIT_DATE="${commit_date}"
HOMECORE_COMMIT_MSG="${commit_msg}"
HOMECORE_BRANCH="${branch}"
HOMECORE_INSTALLED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
EOF

    chmod 0640 "$version_file"
    echo "[+] Version file written: ${commit_short} (${commit_date})"
}

# Read the installed version, returns 1 if not found
# Usage: read_version_file <target_dir>
# Sets HOMECORE_* variables in the caller's scope
read_version_file() {
    local target_dir="$1"
    local version_file="${target_dir}/core/.version"

    if [ ! -f "$version_file" ]; then
        return 1
    fi

    # Source the version file (sets HOMECORE_* vars)
    # shellcheck disable=SC1090
    source "$version_file"
    return 0
}

# Generate the version stamp string used in rendered files
# Usage: version_stamp <repo_dir>
version_stamp() {
    local repo_dir="$1"
    local commit_short commit_date
    commit_short=$(git -C "$repo_dir" rev-parse --short HEAD)
    commit_date=$(git -C "$repo_dir" log -1 --format='%ci' HEAD)
    echo "home-core ${commit_short} (${commit_date})"
}
