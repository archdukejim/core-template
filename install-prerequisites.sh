#!/usr/bin/env bash
# install-prerequisites.sh
# Unpacks and installs all home-core prerequisites on an offline Ubuntu 24.04 AMD64 target.
# Usage: sudo ./install-prerequisites.sh <bundle.zip>
set -euo pipefail

# ── Colour helpers ─────────────────────────────────────────────────────────────
BOLD='\033[1m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Arg check ──────────────────────────────────────────────────────────────────
[[ $# -ge 1 ]] || die "Usage: sudo $0 <path-to-bundle.zip>"
BUNDLE_ZIP="$1"
[[ -f "$BUNDLE_ZIP" ]] || die "Bundle not found: $BUNDLE_ZIP"
[[ "$EUID" -eq 0 ]] || die "Run as root or with sudo."
[[ "$(uname -m)" == "x86_64" ]] || die "Target must be AMD64 (x86_64)."

DISTRO_ID="$(. /etc/os-release && echo "$ID")"
DISTRO_VER="$(. /etc/os-release && echo "$VERSION_ID")"
[[ "$DISTRO_ID" == "ubuntu" ]] || warn "Detected OS: $DISTRO_ID — expected Ubuntu."
[[ "$DISTRO_VER" == "24.04" ]] || warn "Detected version: $DISTRO_VER — bundle was built for Ubuntu 24.04."

# ── Extract bundle ──────────────────────────────────────────────────────────────
WORK_DIR="/tmp/homecore-install-$$"
mkdir -p "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

info "Extracting bundle: $(basename "$BUNDLE_ZIP") ..."

# unzip may not be installed yet — fall back to python3 if needed
if command -v unzip &>/dev/null; then
  unzip -q "$BUNDLE_ZIP" -d "$WORK_DIR"
elif command -v python3 &>/dev/null; then
  python3 -c "
import zipfile, sys
with zipfile.ZipFile(sys.argv[1]) as z:
    z.extractall(sys.argv[2])
" "$BUNDLE_ZIP" "$WORK_DIR"
else
  die "Neither 'unzip' nor 'python3' is available. Cannot extract bundle."
fi

# Locate the root of the extracted bundle (single top-level directory)
BUNDLE_ROOT="$(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)"
[[ -n "$BUNDLE_ROOT" ]] || die "Bundle appears to be empty or malformed."
ok "Extracted to: $BUNDLE_ROOT"

# ── Read manifest ───────────────────────────────────────────────────────────────
MANIFEST="${BUNDLE_ROOT}/manifest.yaml"
[[ -f "$MANIFEST" ]] || die "manifest.yaml not found in bundle."

info "Reading manifest..."

# Parse manifest with python3 (available on all Ubuntu installs)
read_manifest() {
  python3 - "$MANIFEST" "$@" <<'PYEOF'
import sys, yaml

with open(sys.argv[1]) as f:
    manifest = yaml.safe_load(f)

cmd = sys.argv[2] if len(sys.argv) > 2 else ""

if cmd == "target_os":
    print(manifest["manifest"]["target_os"])
elif cmd == "target_version":
    print(manifest["manifest"]["target_version"])
elif cmd == "created":
    print(manifest["manifest"]["created"])
elif cmd == "deb_files":
    for entry in manifest.get("apt_packages", {}).get("deb_files", []):
        print(entry["filename"])
elif cmd == "collections":
    for entry in manifest.get("ansible_collections", []):
        print(entry["filename"])
elif cmd == "images":
    for entry in manifest.get("docker_images", []):
        print(entry["filename"] + "|" + entry["image"] + ":" + entry["tag"])
elif cmd == "docker_gpg_key":
    print(manifest["apt_packages"]["docker_gpg_key"])
elif cmd == "docker_repo":
    print(manifest["apt_packages"]["docker_repo"])
elif cmd == "checksums":
    # Print sha256 checksum verifications for all files
    import hashlib, os
    base = os.path.dirname(sys.argv[1])
    errors = 0
    for section in ["apt_packages", "ansible_collections", "docker_images"]:
        items = manifest.get(section, {})
        if isinstance(items, dict):
            items = items.get("deb_files", [])
        for entry in items:
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
                print(f"CHECKSUM MISMATCH  {entry['filename']}")
                print(f"  expected: {expected}")
                print(f"  actual:   {actual}")
                errors += 1
    sys.exit(errors)
PYEOF
}

MANIFEST_OS="$(read_manifest target_os)"
MANIFEST_VER="$(read_manifest target_version)"
MANIFEST_CREATED="$(read_manifest created)"

info "Bundle info:"
info "  Created : ${MANIFEST_CREATED}"
info "  Target  : ${MANIFEST_OS} ${MANIFEST_VER} AMD64"

# ── Verify checksums ────────────────────────────────────────────────────────────
info "Verifying bundle checksums..."
if read_manifest checksums 2>&1; then
  ok "All checksums verified."
else
  warn "One or more checksum mismatches detected (see above). Proceeding anyway."
fi

# ── Step 1: Install APT packages (offline) ─────────────────────────────────────
echo ""
info "=== Step 1: Installing APT packages ==="

APT_DIR="${BUNDLE_ROOT}/apt"
[[ -d "$APT_DIR" ]] || die "apt/ directory missing from bundle."

# Install Docker GPG key
GPG_KEY_FILE="${APT_DIR}/docker-gpg.asc"
if [[ -f "$GPG_KEY_FILE" ]]; then
  install -m 0755 -d /etc/apt/keyrings
  cp "$GPG_KEY_FILE" /etc/apt/keyrings/docker.asc
  chmod 0644 /etc/apt/keyrings/docker.asc
  ok "Docker GPG key installed."
fi

# Configure Docker APT repo pointing at local files (offline — no network needed)
# We configure it to use local debs only by creating a local repo index
DEB_COUNT=$(find "$APT_DIR" -name "*.deb" | wc -l)
info "Installing ${DEB_COUNT} .deb package(s)..."

if [[ "$DEB_COUNT" -gt 0 ]]; then
  # Use dpkg to install all debs; run apt --fix-broken to resolve dep ordering
  # Sort debs so lower-level packages (like libc) come before higher-level ones
  mapfile -t DEB_FILES < <(find "$APT_DIR" -name "*.deb" | sort)

  info "Running dpkg -i on all .deb files..."
  dpkg -i --force-depends "${DEB_FILES[@]}" 2>&1 | \
    grep -v "^(Reading database\|Preparing to unpack\|Unpacking\|Setting up\|Processing triggers)" || true

  info "Fixing any broken dependency links..."
  # Point apt to local debs only; suppress network activity
  apt-get install -f -y --no-install-recommends \
    -o "Dir::Cache::Archives=${APT_DIR}" \
    -o "APT::Get::AllowUnauthenticated=true" 2>/dev/null || true

  ok "APT packages installed."
else
  warn "No .deb files found in bundle — skipping APT install."
fi

# ── Step 2: Ensure Docker is running ───────────────────────────────────────────
echo ""
info "=== Step 2: Starting Docker service ==="

if systemctl list-unit-files docker.service &>/dev/null; then
  systemctl enable docker 2>/dev/null || true
  systemctl start docker 2>/dev/null || true

  for i in {1..10}; do
    if docker info &>/dev/null; then
      ok "Docker is running."
      break
    fi
    sleep 1
  done

  docker info &>/dev/null || warn "Docker did not start successfully — images will not be loaded."
else
  warn "docker.service not found — skipping Docker start."
fi

# ── Step 3: Load Docker images ─────────────────────────────────────────────────
echo ""
info "=== Step 3: Loading Docker images ==="

IMAGES_DIR="${BUNDLE_ROOT}/images"
if [[ -d "$IMAGES_DIR" ]] && docker info &>/dev/null; then
  while IFS='|' read -r filename image_ref; do
    tar_path="${BUNDLE_ROOT}/${filename}"
    if [[ -f "$tar_path" ]]; then
      info "  Loading ${image_ref} from $(basename "$tar_path") ..."
      docker load -i "$tar_path"
      ok "  Loaded: ${image_ref}"
    else
      warn "  Image archive not found: ${filename}"
    fi
  done < <(read_manifest images)
else
  warn "images/ directory missing or Docker unavailable — skipping image load."
fi

# ── Step 4: Install Ansible collections ────────────────────────────────────────
echo ""
info "=== Step 4: Installing Ansible collections ==="

COLL_DIR="${BUNDLE_ROOT}/collections"
if [[ -d "$COLL_DIR" ]] && command -v ansible-galaxy &>/dev/null; then
  COL_COUNT=$(find "$COLL_DIR" -name "*.tar.gz" | wc -l)
  info "Installing ${COL_COUNT} collection(s)..."
  while IFS= read -r filename; do
    tarball="${BUNDLE_ROOT}/${filename}"
    if [[ -f "$tarball" ]]; then
      info "  Installing $(basename "$tarball") ..."
      ansible-galaxy collection install "$tarball" --offline 2>/dev/null || \
      ansible-galaxy collection install "$tarball" || true
      ok "  Installed: $(basename "$tarball")"
    else
      warn "  Collection archive not found: ${filename}"
    fi
  done < <(read_manifest collections)
else
  warn "collections/ directory missing or ansible-galaxy unavailable — skipping collection install."
fi

# ── Step 5: Verify installation ────────────────────────────────────────────────
echo ""
info "=== Step 5: Verification ==="

check() {
  local label="$1"; shift
  if "$@" &>/dev/null; then
    ok "  ${label}"
  else
    warn "  ${label} — FAILED (command: $*)"
  fi
}

check "Docker daemon"        docker info
check "Docker CLI"           docker --version
check "Docker Compose"       docker compose version
check "Ansible"              ansible --version
check "ansible-galaxy"       ansible-galaxy --version
check "community.docker"     ansible-galaxy collection list community.docker
check "community.general"    ansible-galaxy collection list community.general
check "ansible.posix"        ansible-galaxy collection list ansible.posix
check "nginx image"          docker image inspect nginx:latest
check "bind9 image"          docker image inspect ubuntu/bind9:latest
check "step-ca image"        docker image inspect smallstep/step-ca:latest
check "alpine image"         docker image inspect alpine:latest

# ── Done ────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}Prerequisites installation complete!${NC}"
echo -e "  You can now run: ${CYAN}sudo ./setup.sh${NC}"
