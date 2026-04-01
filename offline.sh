#!/usr/bin/env bash
# offline.sh — offline prerequisite staging and installation for home-core
#
# Usage:
#   sudo ./offline.sh --stage [--output <dir>]   # Internet-connected machine: download,
#                                                #   scan, and package all prerequisites.
#   sudo ./offline.sh --install <bundle>         # Air-gapped target: unpack and install.
#
# --stage produces a timestamped zip containing:
#   apt/          .deb files for system, Docker, and Ansible packages
#   images/       Docker image tarballs
#   collections/  Ansible collection tarballs
#   manifest.yaml SHA-256 manifest of all bundle contents
#   scan-results.txt ClamAV scan log

set -euo pipefail

# ── Colour helpers ──────────────────────────────────────────────────────────────
BOLD='\033[1m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERR ]${NC}  $*" >&2; exit 1; }
banner(){ echo ""; echo -e "${BOLD}${CYAN}── $* ──${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Argument parsing ────────────────────────────────────────────────────────────
MODE=""
BUNDLE_ARG=""
OUTPUT_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage)   MODE="stage" ;;
    --output)  [[ "${2:-}" != "" && "${2:-}" != --* ]] || die "--output requires a directory path."
               OUTPUT_ARG="$2"; shift ;;
    --install) MODE="install"
               [[ "${2:-}" != "" && "${2:-}" != --* ]] && { BUNDLE_ARG="$2"; shift; } ;;
    -h|--help) MODE="help" ;;
    *) die "Unknown argument: $1\nUsage: sudo $0 --stage [--output <dir>] | --install <bundle.zip>" ;;
  esac
  shift
done

if [[ "$MODE" == "help" || -z "$MODE" ]]; then
  cat <<EOF
Usage:
  sudo $0 --stage [--output <dir>]   Download, scan, and package all prerequisites
  sudo $0 --install <bundle>         Install from a staged bundle on an offline target

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

# ══════════════════════════════════════════════════════════════════════════════
# STAGE MODE
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$MODE" == "stage" ]]; then

# ── Output destination (ask up front) ───────────────────────────────────────
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
BUNDLE_NAME="home-core-prerequisites-${TIMESTAMP}"
WORK_DIR="/tmp/${BUNDLE_NAME}"

# ── Package lists ───────────────────────────────────────────────────────────
SYSTEM_PACKAGES=(
  acl
  openssl
  ca-certificates
  curl
  gnupg
  ufw
  libssl-dev
  git
  software-properties-common
  python3-pip
  zip
  unzip
  python3-yaml
)

DOCKER_PACKAGES=(
  docker-ce
  docker-ce-cli
  containerd.io
  docker-buildx-plugin
  docker-compose-plugin
  python3-docker
)

ANSIBLE_PACKAGES=(
  ansible
)

DOCKER_IMAGES=(
  "nginx:latest"
  "ubuntu/bind9:latest"
  "smallstep/step-ca:latest"
  "alpine:latest"
)

ANSIBLE_COLLECTIONS=(
  "community.docker"
  "community.general"
  "ansible.posix"
)

# ── Bootstrap tools ─────────────────────────────────────────────────────────
banner "Bootstrap"
info "Ensuring staging tools are available..."

# Minimal bootstrap so we can add repos (curl, gpg, add-apt-repository)
apt-get update -qq
apt-get install -y --no-install-recommends \
  curl gnupg ca-certificates software-properties-common 2>/dev/null || true

# Add all repos once; track whether anything changed so we only re-update when needed
_REPOS_CHANGED=false

# Docker repo
if [[ ! -f /etc/apt/sources.list.d/docker.list ]]; then
  info "Adding Docker APT repository..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  _REPOS_CHANGED=true
fi

# Ansible PPA
if ! find /etc/apt/sources.list.d/ -name "ansible*" 2>/dev/null | grep -q .; then
  info "Adding Ansible PPA..."
  add-apt-repository --yes ppa:ansible/ansible
  _REPOS_CHANGED=true
fi

if [[ "$_REPOS_CHANGED" == true ]]; then
  info "Updating APT package index (new repos added)..."
  apt-get update -qq
fi

# Install remaining bootstrap tools now that all repos are present
apt-get install -y --no-install-recommends \
  zip python3-yaml 2>/dev/null || true

# Docker (needed to pull/save images)
if ! command -v docker &>/dev/null; then
  info "Installing Docker (needed to pull and save images)..."
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl start docker
fi

# Ansible (needed to download collections)
if ! command -v ansible-galaxy &>/dev/null; then
  info "Installing Ansible (needed to download collections)..."
  apt-get install -y ansible
fi

# ── Work directory ───────────────────────────────────────────────────────────
rm -rf "$WORK_DIR"
mkdir -p "${WORK_DIR}/apt"
mkdir -p "${WORK_DIR}/collections"
mkdir -p "${WORK_DIR}/images"

# ── APT packages ─────────────────────────────────────────────────────────────
banner "APT packages"

# Save the Docker GPG key into the bundle for use on the offline target
info "Saving Docker GPG key to bundle..."
cp /etc/apt/keyrings/docker.asc "${WORK_DIR}/apt/docker-gpg.asc"
ok "Docker GPG key saved."

ALL_PACKAGES=("${SYSTEM_PACKAGES[@]}" "${DOCKER_PACKAGES[@]}" "${ANSIBLE_PACKAGES[@]}")
APT_CACHE_DIR="${WORK_DIR}/apt"

info "Downloading ${#ALL_PACKAGES[@]} package(s) with dependencies (including already-installed)..."

# --reinstall ensures packages already present on this host are downloaded too
apt-get install -y --download-only --reinstall \
  -o Dir::Cache::Archives="${APT_CACHE_DIR}" \
  "${ALL_PACKAGES[@]}" 2>/dev/null || true

rm -f "${APT_CACHE_DIR}/lock" "${APT_CACHE_DIR}/partial/"* 2>/dev/null || true
find "${APT_CACHE_DIR}" -name "*.deb" -size 0 -delete 2>/dev/null || true

DEB_COUNT=$(find "${APT_CACHE_DIR}" -name "*.deb" | wc -l)
ok "Downloaded ${DEB_COUNT} .deb file(s)."

# ── Ansible collections ──────────────────────────────────────────────────────
banner "Ansible collections"
for col in "${ANSIBLE_COLLECTIONS[@]}"; do
  info "  Downloading ${col}..."
  ansible-galaxy collection download "$col" \
    --download-path "${WORK_DIR}/collections/" \
    --no-deps 2>/dev/null || \
  ansible-galaxy collection download "$col" \
    --download-path "${WORK_DIR}/collections/" || true
done
COL_COUNT=$(find "${WORK_DIR}/collections" -name "*.tar.gz" | wc -l)
ok "Downloaded ${COL_COUNT} collection archive(s)."

# ── Docker images ────────────────────────────────────────────────────────────
banner "Docker images"
for image in "${DOCKER_IMAGES[@]}"; do
  safe_name="${image//\//_}"
  safe_name="${safe_name//:/_}.tar"
  info "  Pulling ${image}..."
  docker pull --platform linux/amd64 "$image"
  info "  Saving -> images/${safe_name}"
  docker save -o "${WORK_DIR}/images/${safe_name}" "$image"
  ok "  Saved ${safe_name} ($(du -sh "${WORK_DIR}/images/${safe_name}" | cut -f1))"
done

# ── ClamAV scan ──────────────────────────────────────────────────────────────
banner "ClamAV scan"

SCAN_LOG="${WORK_DIR}/scan-results.txt"

if ! command -v clamscan &>/dev/null; then
  warn "ClamAV is not installed — skipping virus scan."
  warn "Install clamav and re-run --stage to produce a scanned bundle."
  echo "RESULT: SKIPPED — clamscan not installed." > "$SCAN_LOG"
else
  # Attempt a definition update; warn but continue if it fails
  info "Updating ClamAV definitions (freshclam)..."
  systemctl stop clamav-freshclam 2>/dev/null || true
  freshclam --quiet 2>/dev/null && ok "Definitions updated." \
    || warn "freshclam update failed — proceeding with existing definitions."

  {
    echo "home-core offline bundle — ClamAV scan"
    echo "Generated : $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "Bundle    : ${BUNDLE_NAME}"
    echo "Host      : $(hostname -f 2>/dev/null || hostname)"
    echo "ClamAV    : $(clamscan --version 2>/dev/null | head -1)"
    echo "------------------------------------------------------------"
  } > "$SCAN_LOG"

  SCAN_STATUS=0
  info "Scanning bundle contents..."
  clamscan \
    --recursive \
    --infected \
    --bell=no \
    --log="$SCAN_LOG" \
    "${WORK_DIR}/apt/" \
    "${WORK_DIR}/collections/" \
    "${WORK_DIR}/images/" \
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
      read -rp "$(echo -e "${YELLOW}Threats detected. Package the bundle anyway? [y/N]: ${NC}")" _yn
      [[ "${_yn,,}" == "y" ]] || { rm -rf "$WORK_DIR"; die "Aborted — threats detected."; }
      warn "Proceeding at user's request — bundle is flagged."
      ;;
    *)
      echo "RESULT: SCAN ERROR (exit code ${SCAN_STATUS})" >> "$SCAN_LOG"
      warn "ClamAV exited with code ${SCAN_STATUS} — scan may be incomplete."
      ;;
  esac
fi

# ── Manifest ─────────────────────────────────────────────────────────────────
banner "Manifest"
info "Generating manifest.yaml..."

{
  echo "---"
  echo "manifest:"
  echo "  created: \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
  echo "  target_os: ubuntu"
  echo "  target_version: \"24.04\""
  echo "  target_arch: amd64"
  echo "  codename: ${CODENAME}"
  echo "  bundle_name: ${BUNDLE_NAME}"
  echo ""
  echo "apt_packages:"
  echo "  docker_gpg_key: apt/docker-gpg.asc"
  echo "  docker_repo: \"deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable\""
  echo "  ansible_ppa: \"ppa:ansible/ansible\""
  echo "  packages:"
  for pkg in "${ALL_PACKAGES[@]}"; do echo "    - ${pkg}"; done
  echo "  deb_files:"
  while IFS= read -r deb; do
    fname="$(basename "$deb")"
    sha256="$(sha256sum "$deb" | cut -d' ' -f1)"
    size="$(stat -c%s "$deb")"
    echo "    - filename: apt/${fname}"
    echo "      sha256: ${sha256}"
    echo "      size_bytes: ${size}"
  done < <(find "${WORK_DIR}/apt" -name "*.deb" | sort)
  echo ""
  echo "ansible_collections:"
  while IFS= read -r tarball; do
    fname="$(basename "$tarball")"
    sha256="$(sha256sum "$tarball" | cut -d' ' -f1)"
    base="${fname%.tar.gz}"
    ns="$(echo "$base" | cut -d'-' -f1)"
    name="$(echo "$base" | cut -d'-' -f2)"
    ver="$(echo "$base" | cut -d'-' -f3-)"
    echo "  - filename: collections/${fname}"
    echo "    namespace: ${ns}"
    echo "    name: ${name}"
    echo "    version: \"${ver}\""
    echo "    sha256: ${sha256}"
  done < <(find "${WORK_DIR}/collections" -name "*.tar.gz" | sort)
  echo ""
  echo "docker_images:"
  for image in "${DOCKER_IMAGES[@]}"; do
    safe_name="${image//\//_}"
    safe_name="${safe_name//:/_}.tar"
    sha256="$(sha256sum "${WORK_DIR}/images/${safe_name}" | cut -d' ' -f1)"
    size="$(stat -c%s "${WORK_DIR}/images/${safe_name}")"
    digest="$(docker inspect --format='{{index .RepoDigests 0}}' "$image" 2>/dev/null || echo "n/a")"
    image_name="${image%%:*}"
    image_tag="${image##*:}"
    echo "  - filename: images/${safe_name}"
    echo "    image: \"${image_name}\""
    echo "    tag: \"${image_tag}\""
    echo "    digest: \"${digest}\""
    echo "    sha256: ${sha256}"
    echo "    size_bytes: ${size}"
  done
} > "${WORK_DIR}/manifest.yaml"

ok "manifest.yaml generated."

# ── Package ──────────────────────────────────────────────────────────────────
banner "Output"
OUT_ZIP="${DEST_DIR}/${BUNDLE_NAME}.zip"
info "Creating archive: ${OUT_ZIP}"
(cd /tmp && zip -r "$OUT_ZIP" "${BUNDLE_NAME}/")
ZIP_SIZE="$(du -sh "$OUT_ZIP" | cut -f1)"
ok "Archive created (${ZIP_SIZE})."

# ── Cleanup ──────────────────────────────────────────────────────────────────
rm -rf "$WORK_DIR"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}Staging complete.${NC}"
echo -e "  Bundle : ${BOLD}${OUT_ZIP}${NC}"
echo -e "  Size   : ${ZIP_SIZE}"
echo ""
echo -e "  Copy this file to the target system and run:"
echo -e "    ${CYAN}sudo ./offline.sh --install ${BUNDLE_NAME}.zip${NC}"
echo ""

fi  # end --stage

# ══════════════════════════════════════════════════════════════════════════════
# INSTALL MODE
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$MODE" == "install" ]]; then

[[ -n "$BUNDLE_ARG" ]] || die "Usage: sudo $0 --install <path-to-bundle.zip>"
[[ -f "$BUNDLE_ARG" ]] || die "Bundle not found: $BUNDLE_ARG"

WORK_DIR="/tmp/homecore-install-$$"
mkdir -p "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

# ── Extract ──────────────────────────────────────────────────────────────────
banner "Extract"
info "Extracting $(basename "$BUNDLE_ARG")..."

if command -v unzip &>/dev/null; then
  unzip -q "$BUNDLE_ARG" -d "$WORK_DIR"
elif command -v python3 &>/dev/null; then
  python3 -c "
import zipfile, sys
with zipfile.ZipFile(sys.argv[1]) as z:
    z.extractall(sys.argv[2])
" "$BUNDLE_ARG" "$WORK_DIR"
else
  die "Neither 'unzip' nor 'python3' available — cannot extract bundle."
fi

BUNDLE_ROOT="$(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)"
[[ -n "$BUNDLE_ROOT" ]] || die "Bundle is empty or malformed."
ok "Extracted to: $BUNDLE_ROOT"

# ── Scan results warning ─────────────────────────────────────────────────────
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

# ── Manifest ─────────────────────────────────────────────────────────────────
MANIFEST="${BUNDLE_ROOT}/manifest.yaml"
[[ -f "$MANIFEST" ]] || die "manifest.yaml not found in bundle."

# Parse manifest with python3
read_manifest() {
  python3 - "$MANIFEST" "$@" <<'PYEOF'
import sys, yaml

with open(sys.argv[1]) as f:
    manifest = yaml.safe_load(f)

cmd = sys.argv[2] if len(sys.argv) > 2 else ""

if cmd == "target_os":      print(manifest["manifest"]["target_os"])
elif cmd == "target_version": print(manifest["manifest"]["target_version"])
elif cmd == "created":      print(manifest["manifest"]["created"])
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

MANIFEST_CREATED="$(read_manifest created)"
MANIFEST_OS="$(read_manifest target_os)"
MANIFEST_VER="$(read_manifest target_version)"

info "Bundle info:"
info "  Created : ${MANIFEST_CREATED}"
info "  Target  : ${MANIFEST_OS} ${MANIFEST_VER} AMD64"

# ── Checksum verification ────────────────────────────────────────────────────
banner "Checksums"
info "Verifying bundle integrity..."
if read_manifest checksums 2>&1; then
  ok "All checksums verified."
else
  warn "One or more checksum mismatches (see above). Proceeding anyway."
fi

# ── Step 1: APT packages ─────────────────────────────────────────────────────
banner "Step 1 — APT packages"
APT_DIR="${BUNDLE_ROOT}/apt"
[[ -d "$APT_DIR" ]] || die "apt/ directory missing from bundle."

GPG_KEY="${APT_DIR}/docker-gpg.asc"
if [[ -f "$GPG_KEY" ]]; then
  install -m 0755 -d /etc/apt/keyrings
  cp "$GPG_KEY" /etc/apt/keyrings/docker.asc
  chmod 0644 /etc/apt/keyrings/docker.asc
  ok "Docker GPG key installed."
fi

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

# ── Step 2: Docker ───────────────────────────────────────────────────────────
banner "Step 2 — Docker"
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

# ── Step 3: Docker images ────────────────────────────────────────────────────
banner "Step 3 — Docker images"
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

# ── Step 4: Ansible collections ─────────────────────────────────────────────
banner "Step 4 — Ansible collections"
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
  warn "collections/ directory missing or ansible-galaxy unavailable — skipping."
fi

# ── Step 5: Verify ───────────────────────────────────────────────────────────
banner "Step 5 — Verification"

_check() {
  local label="$1"; shift
  if "$@" &>/dev/null; then ok "  ${label}"
  else warn "  ${label} — not found (command: $*)"; fi
}

_check "Docker daemon"      docker info
_check "Docker Compose"     docker compose version
_check "Ansible"            ansible --version
_check "ansible-galaxy"     ansible-galaxy --version
_check "community.docker"   ansible-galaxy collection list community.docker
_check "community.general"  ansible-galaxy collection list community.general
_check "ansible.posix"      ansible-galaxy collection list ansible.posix
_check "nginx image"        docker image inspect nginx:latest
_check "bind9 image"        docker image inspect ubuntu/bind9:latest
_check "step-ca image"      docker image inspect smallstep/step-ca:latest
_check "alpine image"       docker image inspect alpine:latest

echo ""
echo -e "${BOLD}${GREEN}Prerequisites installed.${NC}"
echo -e "  Run: ${CYAN}sudo ./setup.sh${NC}"
echo ""

fi  # end --install
