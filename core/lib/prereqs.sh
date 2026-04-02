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
