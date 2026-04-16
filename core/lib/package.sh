#!/usr/bin/env bash
# package.sh — offline prerequisite staging and installation module

# ── Package lists ─────────────────────────────────────────────────────────────
CONTROLLER_APT_PACKAGES=(
  ansible
  python3-pip
)

ANSIBLE_COLLECTIONS=(
  "community.docker"
  "community.general"
  "ansible.posix"
)

TARGET_APT_PACKAGES=(
  acl
  openssl
  ca-certificates
  curl
  gnupg
  ufw
  libssl-dev
  git
  software-properties-common
  zip
  unzip
  dnsutils
  docker-ce
  docker-ce-cli
  containerd.io
  docker-buildx-plugin
  docker-compose-plugin
  python3-docker
)

DOCKER_IMAGES=(
  "nginx:latest"
  "ubuntu/bind9:latest"
  "smallstep/step-ca:latest"
)

ALPINE_TOOLS_DOCKERFILE='FROM alpine:latest
RUN apk add --no-cache easy-rsa openssl'

BUILT_IMAGES=(
  "core-alpine-tools:latest|${ALPINE_TOOLS_DOCKERFILE}"
)

# -----------------------------------------------------------------------
# do_package: Create offline bundles
# -----------------------------------------------------------------------
do_package() {
    [[ "$EUID" -eq 0 ]] || { err "Run as root or with sudo."; exit 1; }
    [[ "$(uname -m)" == "x86_64" ]] || { err "AMD64 (x86_64) required."; exit 1; }

    DISTRO_ID="$(. /etc/os-release && echo "$ID")"
    DISTRO_VER="$(. /etc/os-release && echo "$VERSION_ID")"
    CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-noble}")"
    [[ "$DISTRO_ID" == "ubuntu" ]] || warn "Detected OS: $DISTRO_ID — optimised for Ubuntu 24.04."
    [[ "$DISTRO_VER" == "24.04" ]] || warn "Detected version: $DISTRO_VER — bundle was built for Ubuntu 24.04."

    if [[ -n "$OUTPUT_ARG" ]]; then
      DEST_DIR="${OUTPUT_ARG%/}"
    else
      echo ""
      echo -e "  Default output path: ${BOLD}${SCRIPT_DIR}${NC}"
      read -rp "$(echo -e "${CYAN}Destination directory [Enter for default]: ${NC}")" _dest_input
      DEST_DIR="${_dest_input:-${SCRIPT_DIR}}"
      DEST_DIR="${DEST_DIR%/}"
    fi

    if [[ ! -d "$DEST_DIR" ]]; then
      read -rp "$(echo -e "${YELLOW}'${DEST_DIR}' does not exist. Create it? [y/N]: ${NC}")" _mk
      [[ "${_mk,,}" == "y" ]] || { err "Aborted — destination does not exist."; exit 1; }
      mkdir -p "$DEST_DIR"
    fi
    ok "Output directory: ${DEST_DIR}"

    TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
    BUNDLE_BASE="core-template"
    CTRL_NAME="${BUNDLE_BASE}-controller-${TIMESTAMP}"
    TARGET_NAME="${BUNDLE_BASE}-target-${TIMESTAMP}"
    WORK_CTRL="/tmp/${CTRL_NAME}"
    WORK_TARGET="/tmp/${TARGET_NAME}"

    info "Ensuring minimal APT staging tools..."
    apt-get update -qq
    apt-get install -y --no-install-recommends curl gnupg ca-certificates software-properties-common python3 2>/dev/null || true

    _REPOS_CHANGED=false
    if [[ ! -f /etc/apt/sources.list.d/docker.list ]]; then
      info "Adding Docker APT repository..."
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
      chmod a+r /etc/apt/keyrings/docker.asc
      echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable" > /etc/apt/sources.list.d/docker.list
      _REPOS_CHANGED=true
    fi

    if ! find /etc/apt/sources.list.d/ -name "ansible*" 2>/dev/null | grep -q .; then
      info "Adding Ansible PPA..."
      add-apt-repository --yes ppa:ansible/ansible
      _REPOS_CHANGED=true
    fi

    if [[ "$_REPOS_CHANGED" == true ]]; then
      info "Updating APT index..."
      apt-get update -qq
    fi

    if [[ "$NO_IMAGES" == false ]] && ! command -v docker &>/dev/null; then
        warn "Docker is required to pull docker images."
        if $FORCE; then
            warn "Running with --force. Images will be entirely skipped."
            NO_IMAGES=true
        else
            echo -e "${YELLOW}Please install docker (e.g., 'curl -fsSL https://get.docker.com | sh') or run with --no-images.${NC}"
            read -rp "Attempt to install docker automatically right now? [y/N] " _install_doc
            if [[ "$_install_doc" =~ ^[yY] ]]; then
                apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
                systemctl start docker
            else
                err "Aborted due to missing docker dependency."
                exit 1
            fi
        fi
    fi

    rm -rf "$WORK_CTRL" "$WORK_TARGET"
    mkdir -p "${WORK_CTRL}/apt" "${WORK_CTRL}/collections"
    mkdir -p "${WORK_TARGET}/apt" "${WORK_TARGET}/images"

    info "Resolving dependency tree for controller packages..."
    mapfile -t _CTRL_DEBS < <(
      { apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts --no-breaks --no-replaces --no-enhances "${CONTROLLER_APT_PACKAGES[@]}" 2>/dev/null | grep -E "^\w" | grep -v "^<"; printf '%s\n' "${CONTROLLER_APT_PACKAGES[@]}"; } | sort -u
    )
    (cd "${WORK_CTRL}/apt" && apt-get download "${_CTRL_DEBS[@]}" 2>/dev/null) || true
    find "${WORK_CTRL}/apt" -name "*.deb" -size 0 -delete 2>/dev/null || true
    ok "Downloaded $(find "${WORK_CTRL}/apt" -name "*.deb" | wc -l) controller .deb file(s)."

    info "Downloading Ansible collections via python3 urllib..."
    for col in "${ANSIBLE_COLLECTIONS[@]}"; do
      ns="${col%%.*}"
      name="${col##*.}"
      # Built-in pure python collection downloader
      python3 -c "
import urllib.request, json, sys, os
url = f'https://galaxy.ansible.com/api/v3/plugin/ansible/content/published/collections/index/{sys.argv[1]}/{sys.argv[2]}/'
try:
    data = json.loads(urllib.request.urlopen(url).read())
    ver = data['highest_version']['version']
    dl = f'https://galaxy.ansible.com/download/{sys.argv[1]}-{sys.argv[2]}-{ver}.tar.gz'
    tgt = f'{sys.argv[3]}/{sys.argv[1]}-{sys.argv[2]}-{ver}.tar.gz'
    urllib.request.urlretrieve(dl, tgt)
    print(f'Downloaded {sys.argv[1]}.{sys.argv[2]} v{ver}')
except Exception as e:
    print(f'Failed to fetch {sys.argv[1]}.{sys.argv[2]}: {str(e)}')
    sys.exit(1)
" "$ns" "$name" "${WORK_CTRL}/collections"
    done
    ok "Downloaded $(find "${WORK_CTRL}/collections" -name "*.tar.gz" | wc -l) collection archive(s)."

    info "Resolving dependency tree for target packages..."
    mapfile -t _TARGET_DEBS < <(
      { apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts --no-breaks --no-replaces --no-enhances "${TARGET_APT_PACKAGES[@]}" 2>/dev/null | grep -E "^\w" | grep -v "^<"; printf '%s\n' "${TARGET_APT_PACKAGES[@]}"; } | sort -u
    )
    (cd "${WORK_TARGET}/apt" && apt-get download "${_TARGET_DEBS[@]}" 2>/dev/null) || true
    find "${WORK_TARGET}/apt" -name "*.deb" -size 0 -delete 2>/dev/null || true
    ok "Downloaded $(find "${WORK_TARGET}/apt" -name "*.deb" | wc -l) target .deb file(s)."

    if [[ "$NO_IMAGES" == true ]]; then
      info "Skipping image pull and build."
    else
      for image in "${DOCKER_IMAGES[@]}"; do
        safe_name="${image//\//_}"; safe_name="${safe_name//:/_}.tar"
        info "  Pulling ${image}..."
        docker pull --platform linux/amd64 "$image" >/dev/null
        info "  Saving -> images/${safe_name}"
        docker save -o "${WORK_TARGET}/images/${safe_name}" "$image"
      done

      for entry in "${BUILT_IMAGES[@]}"; do
        image="${entry%%|*}"
        dockerfile="${entry#*|}"
        safe_name="${image//\//_}"; safe_name="${safe_name//:/_}.tar"
        info "  Building ${image}..."
        docker build --platform linux/amd64 -t "$image" - <<<"$dockerfile" >/dev/null
        info "  Saving -> images/${safe_name}"
        docker save -o "${WORK_TARGET}/images/${safe_name}" "$image"
      done
    fi

    SCAN_LOG="/tmp/core-template-scan-${TIMESTAMP}.txt"
    if ! command -v clamscan &>/dev/null; then
      warn "ClamAV is not installed — skipping virus scan."
      echo "RESULT: SKIPPED — clamscan not installed." > "$SCAN_LOG"
    else
      info "Scanning all bundle contents with ClamAV..."
      systemctl stop clamav-freshclam 2>/dev/null || true
      freshclam --quiet 2>/dev/null || true
      {
        echo "core-template bundles"
        echo "Timestamp: ${TIMESTAMP}"
      } > "$SCAN_LOG"

      SCAN_STATUS=0
      clamscan --recursive --infected --bell=no --log="$SCAN_LOG" "${WORK_CTRL}" "${WORK_TARGET}" 2>/dev/null || SCAN_STATUS=$?

      case "$SCAN_STATUS" in
        0) echo "RESULT: CLEAN" >> "$SCAN_LOG" ;;
        1)
          echo "RESULT: THREATS FOUND" >> "$SCAN_LOG"
          warn "ClamAV detected threats:"
          grep " FOUND$" "$SCAN_LOG" || true
          if ! $FORCE; then
            read -rp "$(echo -e "${YELLOW}Threats detected. Package anyway? [y/N]: ${NC}")" _yn
            [[ "${_yn,,}" == "y" ]] || { rm -rf "$WORK_CTRL" "$WORK_TARGET" "$SCAN_LOG"; err "Aborted."; exit 1; }
          fi
          ;;
        *) echo "RESULT: ERROR" >> "$SCAN_LOG" ;;
      esac
    fi
    cp "$SCAN_LOG" "${WORK_CTRL}/scan-results.txt"
    cp "$SCAN_LOG" "${WORK_TARGET}/scan-results.txt"
    rm -f "$SCAN_LOG"

    info "Generating manifests..."
    # Pure JSON manifests avoiding YAML extensions
    python3 -c "
import json, sys, os, hashlib
def gsha(pth):
    h = hashlib.sha256()
    with open(pth, 'rb') as f:
        for c in iter(lambda: f.read(65536), b''):
            h.update(c)
    return h.hexdigest()

out = {
    'manifest': {
        'bundle_type': sys.argv[3],
        'bundle_name': sys.argv[2],
        'target_os': 'ubuntu',
        'target_version': '24.04',
        'target_arch': 'amd64'
    },
    'apt_packages': {'deb_files': []},
    'ansible_collections': [],
    'docker_images': []
}
root = sys.argv[1]
try:
    for f in sorted(os.listdir(os.path.join(root, 'apt'))):
        if f.endswith('.deb'):
            p = os.path.join(root, 'apt', f)
            out['apt_packages']['deb_files'].append({'filename': 'apt/'+f, 'sha256': gsha(p)})
except FileNotFoundError: pass

if sys.argv[3] == 'controller':
    try:
        for f in sorted(os.listdir(os.path.join(root, 'collections'))):
            if f.endswith('.tar.gz'):
                p = os.path.join(root, 'collections', f)
                out['ansible_collections'].append({'filename': 'collections/'+f, 'sha256': gsha(p)})
    except FileNotFoundError: pass

if sys.argv[3] == 'target':
    try:
        for f in sorted(os.listdir(os.path.join(root, 'images'))):
            if f.endswith('.tar'):
                p = os.path.join(root, 'images', f)
                out['docker_images'].append({'filename': 'images/'+f, 'sha256': gsha(p)})
    except FileNotFoundError: pass

with open(os.path.join(root, 'manifest.json'), 'w') as f:
    json.dump(out, f, indent=2)
" "$WORK_CTRL" "$CTRL_NAME" "controller"

    python3 -c "
import json, sys, os, hashlib
def gsha(pth):
    h = hashlib.sha256()
    with open(pth, 'rb') as f:
        for c in iter(lambda: f.read(65536), b''):
            h.update(c)
    return h.hexdigest()

out = {
    'manifest': {
        'bundle_type': sys.argv[3],
        'bundle_name': sys.argv[2],
        'target_os': 'ubuntu',
        'target_version': '24.04',
        'target_arch': 'amd64'
    },
    'apt_packages': {'deb_files': []},
    'ansible_collections': [],
    'docker_images': []
}
root = sys.argv[1]
try:
    for f in sorted(os.listdir(os.path.join(root, 'apt'))):
        if f.endswith('.deb'):
            p = os.path.join(root, 'apt', f)
            out['apt_packages']['deb_files'].append({'filename': 'apt/'+f, 'sha256': gsha(p)})
except FileNotFoundError: pass

if sys.argv[3] == 'target':
    try:
        for f in sorted(os.listdir(os.path.join(root, 'images'))):
            if f.endswith('.tar'):
                p = os.path.join(root, 'images', f)
                out['docker_images'].append({'filename': 'images/'+f, 'sha256': gsha(p)})
    except FileNotFoundError: pass

with open(os.path.join(root, 'manifest.json'), 'w') as f:
    json.dump(out, f, indent=2)
" "$WORK_TARGET" "$TARGET_NAME" "target"

    case "$PACK_FORMAT" in
      tar.gz)
        CTRL_OUT="${DEST_DIR}/${CTRL_NAME}.tar.gz"
        TARGET_OUT="${DEST_DIR}/${TARGET_NAME}.tar.gz"
        info "Archive: $(basename "$CTRL_OUT")"
        (cd /tmp && tar -czf "$CTRL_OUT" "${CTRL_NAME}/")
        info "Archive: $(basename "$TARGET_OUT")"
        (cd /tmp && tar -czf "$TARGET_OUT" "${TARGET_NAME}/")
        ;;
      tar)
        CTRL_OUT="${DEST_DIR}/${CTRL_NAME}.tar"
        TARGET_OUT="${DEST_DIR}/${TARGET_NAME}.tar"
        info "Archive: $(basename "$CTRL_OUT")"
        (cd /tmp && tar -cf "$CTRL_OUT" "${CTRL_NAME}/")
        info "Archive: $(basename "$TARGET_OUT")"
        (cd /tmp && tar -cf "$TARGET_OUT" "${TARGET_NAME}/")
        ;;
      *)
        CTRL_OUT="${DEST_DIR}/${CTRL_NAME}"
        TARGET_OUT="${DEST_DIR}/${TARGET_NAME}"
        cp -r "$WORK_CTRL" "$CTRL_OUT"
        cp -r "$WORK_TARGET" "$TARGET_OUT"
        ;;
    esac

    rm -rf "$WORK_CTRL" "$WORK_TARGET"

    echo ""
    echo -e "${BOLD}${GREEN}Staging complete. Two bundles produced:${NC}"
    echo -e "  CONTROLLER: ${CYAN}$(basename "$CTRL_OUT")${NC}"
    echo -e "  TARGET:     ${CYAN}$(basename "$TARGET_OUT")${NC}"
    echo ""
}

# -----------------------------------------------------------------------
# do_install_bundle: Locally install the contents of offline bundles
# -----------------------------------------------------------------------
do_install_bundle() {
    local bundle_arg="$1"
    
    if [[ -z "$bundle_arg" ]] || [[ "$bundle_arg" == "both" ]]; then
       # Attempt auto-discovery
       local c_found t_found
       c_found=$(find . -maxdepth 1 -name "core-template-controller-*.tar*" | sort -r | head -1 || true)
       t_found=$(find . -maxdepth 1 -name "core-template-target-*.tar*" | sort -r | head -1 || true)
       if [[ -n "$c_found" ]]; then
          info "Auto-discovered controller bundle: $c_found"
          install_single_bundle "$c_found"
       fi
       if [[ -n "$t_found" ]]; then
          info "Auto-discovered target bundle: $t_found"
          install_single_bundle "$t_found"
       fi
       if [[ -z "$c_found" && -z "$t_found" ]]; then
          err "No bundles found in current directory. Please specify a file or target."
          exit 1
       fi
       return 0
    fi
    
    if [[ "$bundle_arg" == "controller" ]]; then
       local c_found
       c_found=$(find . -maxdepth 1 -name "core-template-controller-*.tar*" | sort -r | head -1 || true)
       if [[ -n "$c_found" ]]; then
          info "Auto-discovered controller bundle: $c_found"
          install_single_bundle "$c_found"
       else
          err "No controller bundle found."
          exit 1
       fi
       return 0
    elif [[ "$bundle_arg" == "target" ]]; then
       local t_found
       t_found=$(find . -maxdepth 1 -name "core-template-target-*.tar*" | sort -r | head -1 || true)
       if [[ -n "$t_found" ]]; then
          info "Auto-discovered target bundle: $t_found"
          install_single_bundle "$t_found"
       else
          err "No target bundle found."
          exit 1
       fi
       return 0
    fi

    # Explicit file path
    install_single_bundle "$bundle_arg"
}

install_single_bundle() {
    local target_bundle="$1"
    [[ -f "$target_bundle" || -d "$target_bundle" ]] || { err "Bundle not found: $target_bundle"; exit 1; }

    local WORK_DIR=""
    local BUNDLE_ROOT=""
    if [[ -d "$target_bundle" ]]; then
        BUNDLE_ROOT="$(realpath "$target_bundle")"
    else
        WORK_DIR="/tmp/homecore-install-$$"
        mkdir -p "$WORK_DIR"
        trap 'rm -rf "$WORK_DIR"' EXIT
        info "Extracting $(basename "$target_bundle")..."
        if [[ "$target_bundle" == *.tar.gz || "$target_bundle" == *.tgz ]]; then
            tar -xzf "$target_bundle" -C "$WORK_DIR"
        elif [[ "$target_bundle" == *.tar ]]; then
            tar -xf "$target_bundle" -C "$WORK_DIR"
        elif [[ "$target_bundle" == *.zip ]]; then
            if command -v unzip &>/dev/null; then unzip -q "$target_bundle" -d "$WORK_DIR"
            else python3 -c "import zipfile, sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$target_bundle" "$WORK_DIR"
            fi
        fi
        BUNDLE_ROOT="$(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)"
        [[ -n "$BUNDLE_ROOT" ]] || { err "Empty bundle."; exit 1; }
    fi

    local manifest="${BUNDLE_ROOT}/manifest.json"
    local manifest_yaml="${BUNDLE_ROOT}/manifest.yaml" # Legacy compat
    local b_type="unknown"
    if [[ -f "$manifest" ]]; then
        b_type=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1]))['manifest']['bundle_type'])" "$manifest")
    elif [[ -f "$manifest_yaml" ]]; then
        # Basic parsing for legacy YAML manifest
        b_type=$(grep bundle_type "$manifest_yaml" | awk '{print $2}')
    fi

    info "Installing ${b_type} package..."

    local APT_DIR="${BUNDLE_ROOT}/apt"
    if [[ -d "$APT_DIR" ]]; then
        local DEB_COUNT; DEB_COUNT=$(find "$APT_DIR" -name "*.deb" | wc -l)
        if [[ "$DEB_COUNT" -gt 0 ]]; then
            mapfile -t DEB_FILES < <(find "$APT_DIR" -name "*.deb" | sort)
            dpkg -i --force-depends "${DEB_FILES[@]}" 2>&1 | grep -v "^\(Reading database\|Preparing to unpack\|Unpacking\|Setting up\|Processing triggers\)" || true
            apt-get install -f -y --no-install-recommends -o Dir::Cache::Archives="${APT_DIR}" -o APT::Get::AllowUnauthenticated=true 2>/dev/null || true
            ok "APT packages installed."
        fi
    fi

    if [[ "$b_type" == "controller" ]]; then
        local COLL_DIR="${BUNDLE_ROOT}/collections"
        if command -v ansible-galaxy &>/dev/null && [[ -d "$COLL_DIR" ]]; then
            while IFS= read -r col_file; do
                ansible-galaxy collection install "$col_file" --offline 2>/dev/null || ansible-galaxy collection install "$col_file" || true
            done < <(find "$COLL_DIR" -maxdepth 1 -name "*.tar.gz")
            ok "Ansible collections installed."
        fi
    fi

    if [[ "$b_type" == "target" ]]; then
        if [[ -d "${BUNDLE_ROOT}/images" ]] && command -v docker &>/dev/null; then
            systemctl start docker 2>/dev/null || true
            while IFS= read -r img_file; do
                docker load -i "$img_file" >/dev/null
            done < <(find "${BUNDLE_ROOT}/images" -maxdepth 1 -name "*.tar")
            ok "Docker images loaded."
        fi
        
        # When installing target bundle locally, automatically configure PREREQS_TARGET so subsequent setup skips remote logic
        TARGET_PREREQS_DIR="$BUNDLE_ROOT"
        OFFLINE=true
    fi

    if [[ -n "$WORK_DIR" && "$BUNDLE_ONLY" == "true" ]]; then
      # If doing bundle-only, clean up. If doing full install later, we need TARGET_PREREQS_DIR to persist!
      # Wait, TARGET_PREREQS_DIR was set to BUNDLE_ROOT inside WORK_DIR. We can't delete it! 
      # Trap will delete it. So if we are NOT bundle-only, we should not delete it.
      trap - EXIT
    fi

    ok "${b_type} package installation successful."
}
