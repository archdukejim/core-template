#!/bin/bash
# Prerequisite management — source this file, do not execute directly.

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

# Verify local prerequisites are present. Package installation is handled
# exclusively by offline.sh — setup.sh assumes deps are already installed.
install_local_prereqs() {
    if command -v ansible-playbook &>/dev/null; then
        ok "Ansible already installed: $(ansible --version 2>/dev/null | head -1)"
    else
        err "ansible-playbook not found. Run setup.sh --install-bundle controller to install prerequisites."
        exit 1
    fi
}
