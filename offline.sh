#!/usr/bin/env bash
# offline.sh — offline prerequisite staging and installation for core-template
#
# Usage:
#   sudo ./offline.sh --stage [--output <dir>] [--compress | --package] [--no-images]
#       Internet-connected machine: download, scan, and produce two output bundles:
#         controller/   — Ansible + collections (install on the Ansible host)
#         target/       — system/Docker packages + images (installed on the target)
#
#       Default output is a loose directory tree inside --output.
#       --compress    Package each bundle as a .tar.gz archive
#       --package     Package each bundle as a .tar  archive
#       --no-images   Skip pulling and saving Docker images
#
#   sudo ./offline.sh --install <bundle-dir | bundle.tar | bundle.tar.gz>
#       Air-gapped machine: auto-detects bundle type from manifest and installs accordingly.
#       Accepts a directory, .tar, .tar.gz, or legacy .zip bundle.
#
# Bundle types:
#   controller  apt/ (ansible + python3-yaml + deps)  collections/
#   target      apt/ (system + docker pkgs + deps)    images/

set -euo pipefail

# ── Colour helpers ───────────────────────────────────────────────────────────
BOLD='\033[1m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERR ]${NC}  $*" >&2; exit 1; }
banner(){ echo ""; echo -e "${BOLD}${CYAN}── $* ──${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Argument parsing ─────────────────────────────────────────────────────────
MODE=""
BUNDLE_ARG=""
OUTPUT_ARG=""
NO_IMAGES=false
PACK_FORMAT=""   # "" = loose directory, "tar.gz" = --compress, "tar" = --package

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage)      MODE="stage" ;;
    --output)     [[ "${2:-}" != "" && "${2:-}" != --* ]] || die "--output requires a directory path."
                  OUTPUT_ARG="$2"; shift ;;
    --install)    MODE="install"
                  [[ "${2:-}" != "" && "${2:-}" != --* ]] && { BUNDLE_ARG="$2"; shift; } ;;
    --compress)   PACK_FORMAT="tar.gz" ;;
    --package)    PACK_FORMAT="tar" ;;
    --no-images)  NO_IMAGES=true ;;
    -h|--help)    MODE="help" ;;
    *) die "Unknown argument: $1\nUsage: sudo $0 --stage [--output <dir>] [--compress | --package] [--no-images] | --install <bundle>" ;;
  esac
  shift
done

if [[ "$MODE" == "help" || -z "$MODE" ]]; then
  cat <<EOF
Usage:
  sudo $0 --stage [--output <dir>] [--compress | --package] [--no-images]
      Download, scan, and produce two bundles (loose directories by default).
        --compress    Archive each bundle as .tar.gz
        --package     Archive each bundle as .tar
        --no-images   Skip pulling/saving Docker images

  sudo $0 --install <bundle>
      Install a controller or target bundle on an offline machine.
      Accepts a directory, .tar, .tar.gz, or legacy .zip.

Bundles produced by --stage:
  core-template-controller-<ts>[.tar[.gz]]   Ansible host: ansible, python3-yaml, collections
  core-template-target-<ts>[.tar[.gz]]       Target host:  system/Docker packages, Docker images

EOF
  exit 0
fi

[[ "$EUID" -eq 0 ]] || die "Run as root or with sudo."
[[ "$(uname -m)" == "x86_64" ]] || die "AMD64 (x86_64) required."

DISTRO_ID="$(. /etc/os-release && echo "$ID")"
DISTRO_VER="$(. /etc/os-release && echo "$VERSION_ID")"
CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-noble}")"
[[ "$DISTRO_ID" == "ubuntu" ]] || warn "Detected OS: $DISTRO_ID — optimised for Ubuntu 24.04."
[[ "$DISTRO_VER" == "24.04" ]] || warn "Detected version: $DISTRO_VER — bundle was built for Ubuntu 24.04."

# ═════════════════════════════════════════════════════════════════════════════
# STAGE MODE
# ═════════════════════════════════════════════════════════════════════════════
if [[ "$MODE" == "stage" ]]; then

# ── Output destination (ask up front) ────────────────────────────────────────
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
  [[ "${_mk,,}" == "y" ]] || die "Aborted — destination does not exist."
  mkdir -p "$DEST_DIR"
fi
ok "Output directory: ${DEST_DIR}"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BUNDLE_BASE="core-template"
CTRL_NAME="${BUNDLE_BASE}-controller-${TIMESTAMP}"
TARGET_NAME="${BUNDLE_BASE}-target-${TIMESTAMP}"
WORK_CTRL="/tmp/${CTRL_NAME}"
WORK_TARGET="/tmp/${TARGET_NAME}"

# ── Package lists ─────────────────────────────────────────────────────────────
# Controller (Ansible host) — packages needed on the machine running setup.sh
CONTROLLER_APT_PACKAGES=(
  ansible
  python3-yaml
  python3-pip
)

ANSIBLE_COLLECTIONS=(
  "community.docker"
  "community.general"
  "ansible.posix"
)

# Target (remote host) — packages needed on the machine being provisioned
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
  python3-yaml
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

# Images built locally from a Dockerfile — staged alongside pulled images.
# Each entry: "image:tag|dockerfile-content"
# These are built on the staging machine (requires internet for base layer pulls)
# and saved into the bundle as pre-baked tars so targets never need apk/apt at run time.
ALPINE_TOOLS_DOCKERFILE='FROM alpine:latest
RUN apk add --no-cache easy-rsa openssl'

BUILT_IMAGES=(
  "core-alpine-tools:latest|${ALPINE_TOOLS_DOCKERFILE}"
)

# ── Bootstrap tools ──────────────────────────────────────────────────────────
banner "Bootstrap"
info "Ensuring staging tools are available..."

# Minimal bootstrap so we can add repos (curl, gpg, add-apt-repository)
apt-get update -qq
apt-get install -y --no-install-recommends \
  curl gnupg ca-certificates software-properties-common 2>/dev/null || true

# Add all repos once; only re-update if something actually changed
_REPOS_CHANGED=false

# Docker repo (needed to download Docker packages for target bundle)
if [[ ! -f /etc/apt/sources.list.d/docker.list ]]; then
  info "Adding Docker APT repository..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  _REPOS_CHANGED=true
fi

# Ansible PPA (needed to download Ansible packages for controller bundle)
if ! find /etc/apt/sources.list.d/ -name "ansible*" 2>/dev/null | grep -q .; then
  info "Adding Ansible PPA..."
  add-apt-repository --yes ppa:ansible/ansible
  _REPOS_CHANGED=true
fi

if [[ "$_REPOS_CHANGED" == true ]]; then
  info "Updating APT package index (new repos added)..."
  apt-get update -qq
fi

apt-get install -y --no-install-recommends python3-yaml 2>/dev/null || true

# Docker (needed to pull/save images — skip if --no-images)
if [[ "$NO_IMAGES" == false ]] && ! command -v docker &>/dev/null; then
  info "Installing Docker (needed to pull and save images)..."
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl start docker
fi

# Ansible (needed to download collections)
if ! command -v ansible-galaxy &>/dev/null; then
  info "Installing Ansible (needed to download collections)..."
  apt-get install -y ansible
fi

# ── Work directories ─────────────────────────────────────────────────────────
rm -rf "$WORK_CTRL" "$WORK_TARGET"
mkdir -p "${WORK_CTRL}/apt" "${WORK_CTRL}/collections"
mkdir -p "${WORK_TARGET}/apt" "${WORK_TARGET}/images"

# ── Controller APT packages ──────────────────────────────────────────────────
banner "Controller APT packages (ansible host)"
info "Resolving full transitive dependency tree for controller packages..."
mapfile -t _CTRL_DEBS < <(
  {
    apt-cache depends --recurse --no-recommends --no-suggests \
      --no-conflicts --no-breaks --no-replaces --no-enhances \
      "${CONTROLLER_APT_PACKAGES[@]}" 2>/dev/null \
    | grep -E "^\w" | grep -v "^<"
    printf '%s\n' "${CONTROLLER_APT_PACKAGES[@]}"
  } | sort -u
)
ok "Resolved ${#_CTRL_DEBS[@]} controller packages (direct + transitive + explicit)."

info "Downloading ${#_CTRL_DEBS[@]} controller package(s)..."
# apt-get download always fetches to CWD regardless of install state;
# this avoids the issue where apt skips already-installed packages even
# with --reinstall when using Dir::Cache::Archives.
(cd "${WORK_CTRL}/apt" && apt-get download "${_CTRL_DEBS[@]}" 2>/dev/null) || true

find "${WORK_CTRL}/apt" -name "*.deb" -size 0 -delete 2>/dev/null || true
ok "Downloaded $(find "${WORK_CTRL}/apt" -name "*.deb" | wc -l) controller .deb file(s)."

# ── Ansible collections ──────────────────────────────────────────────────────
banner "Ansible collections (controller)"
for col in "${ANSIBLE_COLLECTIONS[@]}"; do
  info "  Downloading ${col}..."
  ansible-galaxy collection download "$col" \
    --download-path "${WORK_CTRL}/collections/" \
    --no-deps 2>/dev/null || \
  ansible-galaxy collection download "$col" \
    --download-path "${WORK_CTRL}/collections/" || true
done
ok "Downloaded $(find "${WORK_CTRL}/collections" -name "*.tar.gz" | wc -l) collection archive(s)."

# ── Target APT packages ──────────────────────────────────────────────────────
banner "Target APT packages (provisioned host)"


info "Resolving full transitive dependency tree for target packages..."
mapfile -t _TARGET_DEBS < <(
  {
    apt-cache depends --recurse --no-recommends --no-suggests \
      --no-conflicts --no-breaks --no-replaces --no-enhances \
      "${TARGET_APT_PACKAGES[@]}" 2>/dev/null \
    | grep -E "^\w" | grep -v "^<"
    printf '%s\n' "${TARGET_APT_PACKAGES[@]}"
  } | sort -u
)
ok "Resolved ${#_TARGET_DEBS[@]} target packages (direct + transitive + explicit)."

info "Downloading ${#_TARGET_DEBS[@]} target package(s)..."
(cd "${WORK_TARGET}/apt" && apt-get download "${_TARGET_DEBS[@]}" 2>/dev/null) || true

find "${WORK_TARGET}/apt" -name "*.deb" -size 0 -delete 2>/dev/null || true
ok "Downloaded $(find "${WORK_TARGET}/apt" -name "*.deb" | wc -l) target .deb file(s)."

# ── Docker images (pull + build) ─────────────────────────────────────────────
if [[ "$NO_IMAGES" == true ]]; then
  banner "Docker images (skipped — --no-images)"
  info "Skipping image pull and build."
else
  banner "Docker images (target)"
  for image in "${DOCKER_IMAGES[@]}"; do
    safe_name="${image//\//_}"; safe_name="${safe_name//:/_}.tar"
    info "  Pulling ${image}..."
    docker pull --platform linux/amd64 "$image"
    info "  Saving -> images/${safe_name}"
    docker save -o "${WORK_TARGET}/images/${safe_name}" "$image"
    ok "  Saved ${safe_name} ($(du -sh "${WORK_TARGET}/images/${safe_name}" | cut -f1))"
  done

  banner "Docker images — local builds (target)"
  for entry in "${BUILT_IMAGES[@]}"; do
    image="${entry%%|*}"
    dockerfile="${entry#*|}"
    safe_name="${image//\//_}"; safe_name="${safe_name//:/_}.tar"
    info "  Building ${image}..."
    docker build --platform linux/amd64 -t "$image" - <<<"$dockerfile"
    info "  Saving -> images/${safe_name}"
    docker save -o "${WORK_TARGET}/images/${safe_name}" "$image"
    ok "  Saved ${safe_name} ($(du -sh "${WORK_TARGET}/images/${safe_name}" | cut -f1))"
  done
fi

# ── ClamAV scan ───────────────────────────────────────────────────────────────
banner "ClamAV scan"
SCAN_LOG="/tmp/core-template-scan-${TIMESTAMP}.txt"

if ! command -v clamscan &>/dev/null; then
  warn "ClamAV is not installed — skipping virus scan."
  warn "Install clamav and re-run --stage to produce a scanned bundle."
  echo "RESULT: SKIPPED — clamscan not installed." > "$SCAN_LOG"
else
  info "Updating ClamAV definitions (freshclam)..."
  systemctl stop clamav-freshclam 2>/dev/null || true
  freshclam --quiet 2>/dev/null && ok "Definitions updated." \
    || warn "freshclam update failed — proceeding with existing definitions."

  {
    echo "core-template offline bundles — ClamAV scan"
    echo "Generated  : $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "Timestamp  : ${TIMESTAMP}"
    echo "Host       : $(hostname -f 2>/dev/null || hostname)"
    echo "ClamAV     : $(clamscan --version 2>/dev/null | head -1)"
    echo "Scanned    : controller apt/, controller collections/, target apt/, target images/"
    echo "------------------------------------------------------------"
  } > "$SCAN_LOG"

  SCAN_STATUS=0
  info "Scanning all bundle contents..."
  clamscan --recursive --infected --bell=no --log="$SCAN_LOG" \
    "${WORK_CTRL}/apt/" "${WORK_CTRL}/collections/" \
    "${WORK_TARGET}/apt/" "${WORK_TARGET}/images/" \
    2>/dev/null || SCAN_STATUS=$?

  case "$SCAN_STATUS" in
    0)
      echo "RESULT: CLEAN — no threats found." >> "$SCAN_LOG"
      ok "ClamAV scan passed — no threats detected."
      ;;
    1)
      echo "RESULT: THREATS FOUND — review scan-results.txt before use." >> "$SCAN_LOG"
      echo ""
      warn "ClamAV detected one or more threats:"
      grep " FOUND$" "$SCAN_LOG" || true
      echo ""
      read -rp "$(echo -e "${YELLOW}Threats detected. Package the bundles anyway? [y/N]: ${NC}")" _yn
      [[ "${_yn,,}" == "y" ]] || { rm -rf "$WORK_CTRL" "$WORK_TARGET" "$SCAN_LOG"; die "Aborted — threats detected."; }
      warn "Proceeding at user's request — bundles are flagged."
      ;;
    *)
      echo "RESULT: SCAN ERROR (exit code ${SCAN_STATUS})" >> "$SCAN_LOG"
      warn "ClamAV exited with code ${SCAN_STATUS} — scan may be incomplete."
      ;;
  esac
fi

# Copy shared scan log into both bundles
cp "$SCAN_LOG" "${WORK_CTRL}/scan-results.txt"
cp "$SCAN_LOG" "${WORK_TARGET}/scan-results.txt"
rm -f "$SCAN_LOG"

# ── Manifests ─────────────────────────────────────────────────────────────────
banner "Manifests"

_write_manifest_header() {
  local work_dir="$1" bundle_type="$2" bundle_name="$3"
  cat > "${work_dir}/manifest.yaml" <<YAML
---
manifest:
  created: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  bundle_type: ${bundle_type}
  target_os: ubuntu
  target_version: "24.04"
  target_arch: amd64
  codename: ${CODENAME}
  bundle_name: ${bundle_name}
YAML
}

# Controller manifest
info "Generating controller manifest..."
_write_manifest_header "$WORK_CTRL" "controller" "$CTRL_NAME"
{
  echo ""
  echo "apt_packages:"
  echo "  ansible_ppa: \"ppa:ansible/ansible\""
  echo "  packages:"
  for pkg in "${CONTROLLER_APT_PACKAGES[@]}"; do echo "    - ${pkg}"; done
  echo "  deb_files:"
  while IFS= read -r deb; do
    fname="$(basename "$deb")"
    sha256="$(sha256sum "$deb" | cut -d' ' -f1)"
    size="$(stat -c%s "$deb")"
    printf "    - filename: apt/%s\n      sha256: %s\n      size_bytes: %s\n" "$fname" "$sha256" "$size"
  done < <(find "${WORK_CTRL}/apt" -name "*.deb" | sort)
  echo ""
  echo "ansible_collections:"
  while IFS= read -r tarball; do
    fname="$(basename "$tarball")"
    sha256="$(sha256sum "$tarball" | cut -d' ' -f1)"
    base="${fname%.tar.gz}"
    ns="$(echo "$base" | cut -d'-' -f1)"
    name="$(echo "$base" | cut -d'-' -f2)"
    ver="$(echo "$base" | cut -d'-' -f3-)"
    printf "  - filename: collections/%s\n    namespace: %s\n    name: %s\n    version: \"%s\"\n    sha256: %s\n" \
      "$fname" "$ns" "$name" "$ver" "$sha256"
  done < <(find "${WORK_CTRL}/collections" -name "*.tar.gz" | sort)
} >> "${WORK_CTRL}/manifest.yaml"
ok "Controller manifest generated."

# Target manifest
info "Generating target manifest..."
_write_manifest_header "$WORK_TARGET" "target" "$TARGET_NAME"
{
  echo ""
  echo "apt_packages:"
  echo "  packages:"
  for pkg in "${TARGET_APT_PACKAGES[@]}"; do echo "    - ${pkg}"; done
  echo "  deb_files:"
  while IFS= read -r deb; do
    fname="$(basename "$deb")"
    sha256="$(sha256sum "$deb" | cut -d' ' -f1)"
    size="$(stat -c%s "$deb")"
    printf "    - filename: apt/%s\n      sha256: %s\n      size_bytes: %s\n" "$fname" "$sha256" "$size"
  done < <(find "${WORK_TARGET}/apt" -name "*.deb" | sort)
  echo ""
  if [[ "$NO_IMAGES" == true ]]; then
    echo "docker_images: []"
  else
    echo "docker_images:"
    for image in "${DOCKER_IMAGES[@]}"; do
      safe_name="${image//\//_}"; safe_name="${safe_name//:/_}.tar"
      sha256="$(sha256sum "${WORK_TARGET}/images/${safe_name}" | cut -d' ' -f1)"
      size="$(stat -c%s "${WORK_TARGET}/images/${safe_name}")"
      digest="$(docker inspect --format='{{index .RepoDigests 0}}' "$image" 2>/dev/null || echo "n/a")"
      printf "  - filename: images/%s\n    image: \"%s\"\n    tag: \"%s\"\n    digest: \"%s\"\n    sha256: %s\n    size_bytes: %s\n" \
        "$safe_name" "${image%%:*}" "${image##*:}" "$digest" "$sha256" "$size"
    done
    for entry in "${BUILT_IMAGES[@]}"; do
      image="${entry%%|*}"
      safe_name="${image//\//_}"; safe_name="${safe_name//:/_}.tar"
      sha256="$(sha256sum "${WORK_TARGET}/images/${safe_name}" | cut -d' ' -f1)"
      size="$(stat -c%s "${WORK_TARGET}/images/${safe_name}")"
      printf "  - filename: images/%s\n    image: \"%s\"\n    tag: \"%s\"\n    digest: \"local-build\"\n    sha256: %s\n    size_bytes: %s\n" \
        "$safe_name" "${image%%:*}" "${image##*:}" "$sha256" "$size"
    done
  fi
} >> "${WORK_TARGET}/manifest.yaml"
ok "Target manifest generated."

# ── Output ────────────────────────────────────────────────────────────────────
banner "Output"

case "$PACK_FORMAT" in
  tar.gz)
    CTRL_OUT="${DEST_DIR}/${CTRL_NAME}.tar.gz"
    TARGET_OUT="${DEST_DIR}/${TARGET_NAME}.tar.gz"
    info "Creating controller archive: $(basename "$CTRL_OUT")"
    (cd /tmp && tar -czf "$CTRL_OUT" "${CTRL_NAME}/")
    info "Creating target archive: $(basename "$TARGET_OUT")"
    (cd /tmp && tar -czf "$TARGET_OUT" "${TARGET_NAME}/")
    ;;
  tar)
    CTRL_OUT="${DEST_DIR}/${CTRL_NAME}.tar"
    TARGET_OUT="${DEST_DIR}/${TARGET_NAME}.tar"
    info "Creating controller archive: $(basename "$CTRL_OUT")"
    (cd /tmp && tar -cf "$CTRL_OUT" "${CTRL_NAME}/")
    info "Creating target archive: $(basename "$TARGET_OUT")"
    (cd /tmp && tar -cf "$TARGET_OUT" "${TARGET_NAME}/")
    ;;
  *)
    # Loose directories
    CTRL_OUT="${DEST_DIR}/${CTRL_NAME}"
    TARGET_OUT="${DEST_DIR}/${TARGET_NAME}"
    info "Copying controller bundle -> $(basename "$CTRL_OUT")/"
    cp -r "$WORK_CTRL" "$CTRL_OUT"
    info "Copying target bundle    -> $(basename "$TARGET_OUT")/"
    cp -r "$WORK_TARGET" "$TARGET_OUT"
    ;;
esac

CTRL_SIZE="$(du -sh "$CTRL_OUT" | cut -f1)"
TARGET_SIZE="$(du -sh "$TARGET_OUT" | cut -f1)"
ok "Controller : ${CTRL_SIZE}  $(basename "$CTRL_OUT")"
ok "Target     : ${TARGET_SIZE}  $(basename "$TARGET_OUT")"

# ── Cleanup ───────────────────────────────────────────────────────────────────
rm -rf "$WORK_CTRL" "$WORK_TARGET"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}Staging complete. Two bundles produced:${NC}"
[[ "$NO_IMAGES" == true ]] && echo -e "  ${YELLOW}(--no-images: Docker images were not staged)${NC}"
echo ""
echo -e "  ${BOLD}Controller bundle${NC} (install on the Ansible host — the machine running setup.sh):"
echo -e "    ${CYAN}$(basename "$CTRL_OUT")${NC}  (${CTRL_SIZE})"
echo -e "    sudo ./offline.sh --install $(basename "$CTRL_OUT")"
echo ""
echo -e "  ${BOLD}Target bundle${NC} (pass to setup.sh via --prereqs-target, installed on the provisioned host):"
echo -e "    ${CYAN}$(basename "$TARGET_OUT")${NC}  (${TARGET_SIZE})"
echo -e "    sudo ./setup.sh --prereqs-target $(basename "$TARGET_OUT")"
echo ""
echo -e "  ${BOLD}Same machine?${NC} Install both, then run setup.sh:"
echo -e "    sudo ./offline.sh --install $(basename "$CTRL_OUT")"
echo -e "    sudo ./setup.sh --offline --prereqs-target $(basename "$TARGET_OUT")"
echo ""

fi  # end --stage

# ═════════════════════════════════════════════════════════════════════════════
# INSTALL MODE
# ═════════════════════════════════════════════════════════════════════════════
if [[ "$MODE" == "install" ]]; then

[[ -n "$BUNDLE_ARG" ]] || die "Usage: sudo $0 --install <path-to-bundle>"
[[ -f "$BUNDLE_ARG" || -d "$BUNDLE_ARG" ]] || die "Bundle not found: $BUNDLE_ARG"

# ── Extract ───────────────────────────────────────────────────────────────────
banner "Extract"

if [[ -d "$BUNDLE_ARG" ]]; then
  # Loose directory bundle — use directly without copying
  BUNDLE_ROOT="$(realpath "$BUNDLE_ARG")"
  WORK_DIR=""
  ok "Using bundle directory: $BUNDLE_ROOT"
else
  WORK_DIR="/tmp/homecore-install-$$"
  mkdir -p "$WORK_DIR"
  trap 'rm -rf "$WORK_DIR"' EXIT
  info "Extracting $(basename "$BUNDLE_ARG")..."

  if [[ "$BUNDLE_ARG" == *.tar.gz || "$BUNDLE_ARG" == *.tgz ]]; then
    tar -xzf "$BUNDLE_ARG" -C "$WORK_DIR"
  elif [[ "$BUNDLE_ARG" == *.tar ]]; then
    tar -xf "$BUNDLE_ARG" -C "$WORK_DIR"
  elif [[ "$BUNDLE_ARG" == *.zip ]]; then
    if command -v unzip &>/dev/null; then
      unzip -q "$BUNDLE_ARG" -d "$WORK_DIR"
    elif command -v python3 &>/dev/null; then
      python3 -c "
import zipfile, sys
with zipfile.ZipFile(sys.argv[1]) as z:
    z.extractall(sys.argv[2])
" "$BUNDLE_ARG" "$WORK_DIR"
    else
      die "Neither 'unzip' nor 'python3' available — cannot extract .zip bundle."
    fi
  else
    die "Unsupported bundle format: $(basename "$BUNDLE_ARG") — expected directory, .tar, .tar.gz, or .zip"
  fi

  BUNDLE_ROOT="$(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)"
  [[ -n "$BUNDLE_ROOT" ]] || die "Bundle is empty or malformed."
  ok "Extracted to: $BUNDLE_ROOT"
fi

# ── Scan results warning ──────────────────────────────────────────────────────
SCAN_RESULT_FILE="${BUNDLE_ROOT}/scan-results.txt"
if [[ -f "$SCAN_RESULT_FILE" ]]; then
  SCAN_SUMMARY="$(grep "^RESULT:" "$SCAN_RESULT_FILE" | tail -1 || true)"
  if echo "$SCAN_SUMMARY" | grep -qi "THREATS FOUND"; then
    warn "This bundle was flagged by ClamAV during staging:"
    warn "  ${SCAN_SUMMARY}"
    echo ""
    read -rp "$(echo -e "${YELLOW}Continue installation despite scan warnings? [y/N]: ${NC}")" _yn
    [[ "${_yn,,}" == "y" ]] || die "Aborted — scan result was not clean."
  else
    ok "Scan result: ${SCAN_SUMMARY:-CLEAN}"
  fi
else
  warn "No scan-results.txt found in bundle — bundle was not ClamAV-scanned."
fi

# ── Manifest ──────────────────────────────────────────────────────────────────
MANIFEST="${BUNDLE_ROOT}/manifest.yaml"
[[ -f "$MANIFEST" ]] || die "manifest.yaml not found in bundle."

read_manifest() {
  python3 - "$MANIFEST" "$@" <<'PYEOF'
import sys, yaml

with open(sys.argv[1]) as f:
    manifest = yaml.safe_load(f)

cmd = sys.argv[2] if len(sys.argv) > 2 else ""

if   cmd == "bundle_type":    print(manifest["manifest"].get("bundle_type", "unknown"))
elif cmd == "target_os":      print(manifest["manifest"]["target_os"])
elif cmd == "target_version": print(manifest["manifest"]["target_version"])
elif cmd == "created":        print(manifest["manifest"]["created"])
elif cmd == "deb_files":
    for e in manifest.get("apt_packages", {}).get("deb_files", []):
        print(e["filename"])
elif cmd == "collections":
    for e in manifest.get("ansible_collections", []):
        print(e["filename"])
elif cmd == "images":
    for e in manifest.get("docker_images", []):
        print(e["filename"] + "|" + e["image"] + ":" + e["tag"])
elif cmd == "checksums":
    import hashlib, os
    base = os.path.dirname(sys.argv[1])
    errors = 0
    for section in ["apt_packages", "ansible_collections", "docker_images"]:
        items = manifest.get(section, {})
        if isinstance(items, dict):
            items = items.get("deb_files", [])
        for entry in (items or []):
            path = os.path.join(base, entry["filename"])
            expected = entry.get("sha256", "")
            if not expected:
                continue
            if not os.path.exists(path):
                print(f"MISSING  {entry['filename']}", file=sys.stderr)
                errors += 1
                continue
            h = hashlib.sha256()
            with open(path, "rb") as fh:
                for chunk in iter(lambda: fh.read(65536), b""):
                    h.update(chunk)
            actual = h.hexdigest()
            if actual != expected:
                print(f"MISMATCH  {entry['filename']}\n  expected: {expected}\n  actual:   {actual}")
                errors += 1
    sys.exit(errors)
PYEOF
}

BUNDLE_TYPE="$(read_manifest bundle_type)"
MANIFEST_CREATED="$(read_manifest created)"
MANIFEST_OS="$(read_manifest target_os)"
MANIFEST_VER="$(read_manifest target_version)"

info "Bundle info:"
info "  Type    : ${BUNDLE_TYPE}"
info "  Created : ${MANIFEST_CREATED}"
info "  Target  : ${MANIFEST_OS} ${MANIFEST_VER} AMD64"

# ── Checksum verification ─────────────────────────────────────────────────────
banner "Checksums"
info "Verifying bundle integrity..."
if read_manifest checksums 2>&1; then
  ok "All checksums verified."
else
  warn "One or more checksum mismatches (see above). Proceeding anyway."
fi

# ── APT packages (both bundle types) ─────────────────────────────────────────
banner "APT packages"
APT_DIR="${BUNDLE_ROOT}/apt"
[[ -d "$APT_DIR" ]] || die "apt/ directory missing from bundle."


DEB_COUNT=$(find "$APT_DIR" -name "*.deb" | wc -l)
info "Installing ${DEB_COUNT} .deb package(s)..."

if [[ "$DEB_COUNT" -gt 0 ]]; then
  mapfile -t DEB_FILES < <(find "$APT_DIR" -name "*.deb" | sort)
  dpkg -i --force-depends "${DEB_FILES[@]}" 2>&1 | \
    grep -v "^\(Reading database\|Preparing to unpack\|Unpacking\|Setting up\|Processing triggers\)" || true
  apt-get install -f -y --no-install-recommends \
    -o Dir::Cache::Archives="${APT_DIR}" \
    -o APT::Get::AllowUnauthenticated=true 2>/dev/null || true
  ok "APT packages installed."
else
  warn "No .deb files in bundle — skipping APT install."
fi

# ── Controller-specific: Ansible collections ──────────────────────────────────
if [[ "$BUNDLE_TYPE" == "controller" ]]; then
  banner "Ansible collections"
  COLL_DIR="${BUNDLE_ROOT}/collections"
  if [[ -d "$COLL_DIR" ]] && command -v ansible-galaxy &>/dev/null; then
    COL_COUNT=$(find "$COLL_DIR" -name "*.tar.gz" | wc -l)
    info "Installing ${COL_COUNT} collection(s)..."
    while IFS= read -r filename; do
      tarball="${BUNDLE_ROOT}/${filename}"
      if [[ -f "$tarball" ]]; then
        info "  Installing $(basename "$tarball")..."
        ansible-galaxy collection install "$tarball" --offline 2>/dev/null || \
        ansible-galaxy collection install "$tarball" || true
        ok "  Installed: $(basename "$tarball")"
      else
        warn "  Not found in bundle: ${filename}"
      fi
    done < <(read_manifest collections)
  else
    warn "collections/ missing or ansible-galaxy unavailable — skipping."
  fi
fi

# ── Target-specific: Docker start + image load ────────────────────────────────
if [[ "$BUNDLE_TYPE" == "target" ]]; then
  banner "Docker"
  if ! command -v docker &>/dev/null; then
    die "Docker is not installed. Install Docker on the target before running in offline mode."
  fi
  if systemctl list-unit-files docker.service &>/dev/null; then
    systemctl enable docker 2>/dev/null || true
    systemctl start docker 2>/dev/null || true
    for i in {1..10}; do
      docker info &>/dev/null && { ok "Docker is running."; break; }
      sleep 1
    done
    docker info &>/dev/null || warn "Docker did not start — images will not be loaded."
  else
    warn "docker.service not found — skipping."
  fi

  banner "Docker images"
  if [[ -d "${BUNDLE_ROOT}/images" ]] && docker info &>/dev/null; then
    while IFS='|' read -r filename image_ref; do
      tar_path="${BUNDLE_ROOT}/${filename}"
      if [[ -f "$tar_path" ]]; then
        info "  Loading ${image_ref}..."
        docker load -i "$tar_path"
        ok "  Loaded: ${image_ref}"
      else
        warn "  Not found in bundle: ${filename}"
      fi
    done < <(read_manifest images)
  else
    warn "images/ directory missing or Docker unavailable — skipping."
  fi
fi

# ── Verify ────────────────────────────────────────────────────────────────────
banner "Verification"

_check() {
  local label="$1"; shift
  if "$@" &>/dev/null; then ok "  ${label}"
  else warn "  ${label} — not found"; fi
}

if [[ "$BUNDLE_TYPE" == "controller" ]]; then
  _check "Ansible"            ansible --version
  _check "ansible-galaxy"     ansible-galaxy --version
  _check "community.docker"   ansible-galaxy collection list community.docker
  _check "community.general"  ansible-galaxy collection list community.general
  _check "ansible.posix"      ansible-galaxy collection list ansible.posix
  echo ""
  echo -e "${BOLD}${GREEN}Controller prerequisites installed.${NC}"
  echo -e "  Ansible host is ready. Now install the target bundle on the provisioned host,"
  echo -e "  then run: ${CYAN}sudo ./setup.sh --offline --prereqs-target <target-bundle>${NC}"
elif [[ "$BUNDLE_TYPE" == "target" ]]; then
  _check "Docker daemon"   docker info
  _check "Docker Compose"  docker compose version
  _img_count=0
  while IFS='|' read -r _img_file _img_ref; do
    _check "${_img_ref} image"  docker image inspect "$_img_ref"
    (( _img_count++ )) || true
  done < <(read_manifest images)
  [[ "$_img_count" -eq 0 ]] && info "  (no images in bundle — bundle was staged with --no-images)"
  echo ""
  echo -e "${BOLD}${GREEN}Target prerequisites installed.${NC}"
  echo -e "  Run setup.sh from the Ansible host:"
  echo -e "    ${CYAN}sudo ./setup.sh --offline --prereqs-target <target-bundle>${NC}"
else
  echo ""
  warn "Unknown bundle type '${BUNDLE_TYPE}' — manual verification recommended."
fi
echo ""

fi  # end --install
