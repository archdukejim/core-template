#!/usr/bin/env bash
# pull-prerequisites.sh
# Downloads all home-core prerequisites for offline installation on Ubuntu 24.04 AMD64.
# Run this on an internet-connected Ubuntu 24.04 AMD64 machine.
# Output: home-core-prerequisites-<timestamp>.zip in the current directory.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BUNDLE_NAME="home-core-prerequisites-${TIMESTAMP}"
WORK_DIR="/tmp/${BUNDLE_NAME}"

# ── Colour helpers ─────────────────────────────────────────────────────────────
BOLD='\033[1m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Validation ─────────────────────────────────────────────────────────────────
[[ "$(uname -m)" == "x86_64" ]] || die "This script must run on an AMD64 (x86_64) machine."
[[ "$EUID" -eq 0 ]] || die "Run as root or with sudo."

DISTRO_ID="$(. /etc/os-release && echo "$ID")"
DISTRO_VER="$(. /etc/os-release && echo "$VERSION_ID")"
[[ "$DISTRO_ID" == "ubuntu" ]] || warn "Detected OS: $DISTRO_ID. This script is optimised for Ubuntu 24.04."
[[ "$DISTRO_VER" == "24.04" ]] || warn "Detected version: $DISTRO_VER. Packages may differ from target 24.04."
CODENAME="$(. /etc/os-release && echo "$UBUNTU_CODENAME")"

# ── APT packages to bundle ──────────────────────────────────────────────────────
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

# Ansible installed via PPA
ANSIBLE_PACKAGES=(
  ansible
)

# ── Docker images to bundle ─────────────────────────────────────────────────────
DOCKER_IMAGES=(
  "nginx:latest"
  "adguard/adguardhome:latest"
  "ubuntu/bind9:latest"
  "smallstep/step-ca:latest"
  "certbot/dns-rfc2136:latest"
  "alpine:latest"
)

# ── Ansible collections to bundle ──────────────────────────────────────────────
ANSIBLE_COLLECTIONS=(
  "community.docker"
  "community.general"
  "ansible.posix"
)

# ── Bootstrap tools needed to do the pulling ───────────────────────────────────
info "Ensuring bootstrap tools are available on this machine..."

apt-get update -qq

# Install zip/unzip if missing
apt-get install -y --no-install-recommends zip curl gnupg ca-certificates software-properties-common python3-yaml 2>/dev/null

# Install Docker if not present (needed to pull/save images)
if ! command -v docker &>/dev/null; then
  info "Installing Docker (needed to pull images)..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl start docker
fi

# Install Ansible if not present (needed to download collections)
if ! command -v ansible-galaxy &>/dev/null; then
  info "Installing Ansible (needed to download collections)..."
  add-apt-repository --yes --update ppa:ansible/ansible
  apt-get install -y ansible
fi

# ── Set up work directory ───────────────────────────────────────────────────────
rm -rf "$WORK_DIR"
mkdir -p "${WORK_DIR}/apt"
mkdir -p "${WORK_DIR}/collections"
mkdir -p "${WORK_DIR}/images"

# ── Download Docker GPG key ─────────────────────────────────────────────────────
info "Downloading Docker GPG key..."
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "${WORK_DIR}/apt/docker-gpg.asc"
ok "Docker GPG key saved."

# ── Download APT packages ───────────────────────────────────────────────────────
info "Adding Docker APT repository (if not already present)..."
install -m 0755 -d /etc/apt/keyrings
cp "${WORK_DIR}/apt/docker-gpg.asc" /etc/apt/keyrings/docker.asc 2>/dev/null || true
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

info "Adding Ansible PPA..."
add-apt-repository --yes --update ppa:ansible/ansible 2>/dev/null || true

apt-get update -qq

ALL_PACKAGES=("${SYSTEM_PACKAGES[@]}" "${DOCKER_PACKAGES[@]}" "${ANSIBLE_PACKAGES[@]}")

info "Downloading APT packages and their dependencies to ${WORK_DIR}/apt/ ..."
# Use a clean temporary apt cache to avoid mixing with system cache
APT_CACHE_DIR="${WORK_DIR}/apt"
for pkg in "${ALL_PACKAGES[@]}"; do
  apt-get install -y --download-only -o Dir::Cache::Archives="${APT_CACHE_DIR}" \
    --reinstall "$pkg" 2>/dev/null || \
  apt-get download $(apt-rdepends "$pkg" 2>/dev/null | grep -v "^ " | grep -v "^Reading" || echo "$pkg") \
    2>/dev/null || \
  apt-get install -y --download-only -o Dir::Cache::Archives="${APT_CACHE_DIR}" "$pkg" 2>/dev/null || true
done

# Bulk download with dependency resolution
apt-get install -y --download-only \
  -o Dir::Cache::Archives="${APT_CACHE_DIR}" \
  "${ALL_PACKAGES[@]}" 2>/dev/null || true

# Clean up lock/partial files
rm -f "${APT_CACHE_DIR}/lock" "${APT_CACHE_DIR}/partial/"* 2>/dev/null || true
find "${APT_CACHE_DIR}" -name "*.deb" -size 0 -delete 2>/dev/null || true

DEB_COUNT=$(find "${APT_CACHE_DIR}" -name "*.deb" | wc -l)
ok "Downloaded ${DEB_COUNT} .deb package file(s)."

# ── Download Ansible collections ────────────────────────────────────────────────
info "Downloading Ansible collections to ${WORK_DIR}/collections/ ..."
for col in "${ANSIBLE_COLLECTIONS[@]}"; do
  ansible-galaxy collection download "$col" \
    --download-path "${WORK_DIR}/collections/" \
    --no-deps 2>/dev/null || \
  ansible-galaxy collection download "$col" \
    --download-path "${WORK_DIR}/collections/" || true
done

COL_COUNT=$(find "${WORK_DIR}/collections" -name "*.tar.gz" | wc -l)
ok "Downloaded ${COL_COUNT} Ansible collection archive(s)."

# ── Pull and save Docker images ─────────────────────────────────────────────────
info "Pulling and saving Docker images..."
for image in "${DOCKER_IMAGES[@]}"; do
  image_name="${image%%:*}"
  image_tag="${image##*:}"
  safe_name="${image_name//\//_}_${image_tag}.tar"
  info "  Pulling ${image}..."
  docker pull --platform linux/amd64 "$image"
  info "  Saving ${image} -> images/${safe_name}"
  docker save -o "${WORK_DIR}/images/${safe_name}" "$image"
  ok "  Saved ${safe_name} ($(du -sh "${WORK_DIR}/images/${safe_name}" | cut -f1))"
done

# ── Build YAML manifest ─────────────────────────────────────────────────────────
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
  for pkg in "${ALL_PACKAGES[@]}"; do
    echo "    - ${pkg}"
  done
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
    # Parse namespace-name-version.tar.gz
    base="${fname%.tar.gz}"
    namespace="$(echo "$base" | cut -d'-' -f1)"
    name="$(echo "$base" | cut -d'-' -f2)"
    version="$(echo "$base" | cut -d'-' -f3-)"
    echo "  - filename: collections/${fname}"
    echo "    namespace: ${namespace}"
    echo "    name: ${name}"
    echo "    version: \"${version}\""
    echo "    sha256: ${sha256}"
  done < <(find "${WORK_DIR}/collections" -name "*.tar.gz" | sort)
  echo ""
  echo "docker_images:"
  for image in "${DOCKER_IMAGES[@]}"; do
    image_name="${image%%:*}"
    image_tag="${image##*:}"
    safe_name="${image_name//\//_}_${image_tag}.tar"
    sha256="$(sha256sum "${WORK_DIR}/images/${safe_name}" | cut -d' ' -f1)"
    size="$(stat -c%s "${WORK_DIR}/images/${safe_name}")"
    digest="$(docker inspect --format='{{index .RepoDigests 0}}' "$image" 2>/dev/null || echo "n/a")"
    echo "  - filename: images/${safe_name}"
    echo "    image: \"${image_name}\""
    echo "    tag: \"${image_tag}\""
    echo "    digest: \"${digest}\""
    echo "    sha256: ${sha256}"
    echo "    size_bytes: ${size}"
  done
} > "${WORK_DIR}/manifest.yaml"

ok "manifest.yaml generated."

# ── Package into zip ────────────────────────────────────────────────────────────
OUT_ZIP="${SCRIPT_DIR}/${BUNDLE_NAME}.zip"
info "Creating archive: ${OUT_ZIP}"
(cd /tmp && zip -r "$OUT_ZIP" "${BUNDLE_NAME}/")
ZIP_SIZE="$(du -sh "$OUT_ZIP" | cut -f1)"
ok "Archive created: ${OUT_ZIP} (${ZIP_SIZE})"

# ── Cleanup ─────────────────────────────────────────────────────────────────────
rm -rf "$WORK_DIR"

echo ""
echo -e "${BOLD}${GREEN}Done!${NC}"
echo -e "  Bundle : ${BOLD}${OUT_ZIP}${NC}"
echo -e "  Size   : ${ZIP_SIZE}"
echo -e "  Copy this file to the target system and run: ${CYAN}sudo ./install-prerequisites.sh ${BUNDLE_NAME}.zip${NC}"
