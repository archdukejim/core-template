#!/bin/bash
# Archive helpers — source this file, do not execute directly.

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
