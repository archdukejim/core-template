#!/bin/bash
# Version & change display helpers — source this file, do not execute directly.

# Set a scalar value in vars.yaml using targeted sed replacement.
# Only suitable for simple booleans and integers — never rewrites the whole file,
# so Jinja2 expressions and comments in the file are always preserved.
# Usage: _vars_set <key> <value>   (value: true/false or an integer)
_vars_set() {
    local key="$1" val="$2" file="${CUSTOM_VARS_FILE:-$SCRIPT_DIR/custom-vars.yaml}"
    if grep -q "^${key}:" "$file"; then
        sed -i "s|^${key}:.*|${key}: ${val}|" "$file"
    else
        printf '\n%s: %s\n' "$key" "$val" >> "$file"
    fi
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
