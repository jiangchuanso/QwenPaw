#!/usr/bin/env bash
# Build the QwenPaw Tauri DESKTOP .deb for MODERN Linux (aarch64).
#
# Counterpart of build_linux_pyinstaller.sh (the glibc-2.31 backend package for
# Kylin V10 SP1). This one links the real Tauri desktop shell, which requires
# WebKitGTK 4.1 + libsoup3. Those exist only on Ubuntu 22.04 and newer, so this
# build runs natively on the ubuntu-24.04-arm runner — NO ubuntu:20.04 container
# — and the resulting .deb requires glibc >= 2.35 from the target system. It will
# NOT install on Kylin V10 SP1 / Ubuntu 20.04; use the backend package there.
#
# Usage:
#   ./scripts/pack-tauri/build_linux_desktop.sh
#
# Produces (distinct name so it never collides with the backend package):
#   dist/QwenPaw-Desktop-Tauri-<version>-Linux-<arch>.deb (+ .sha256)

set -e

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

VERSION=$(sed -n 's/^__version__[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' src/qwenpaw/__version__.py)

echo "========================================="
echo "QwenPaw Tauri Build - Linux desktop (modern)"
echo "========================================="
echo "Version: ${VERSION}"
echo "Arch:    $(uname -m)"
echo ""

# Step 0: Prerequisites
echo "== Step 0: Checking Prerequisites =="
missing=()

if command -v npm &>/dev/null; then
    echo "  [OK] npm ($(npm --version))"
else
    echo "  [MISSING] npm"
    echo "    Install Node.js 20: https://nodejs.org/"
    missing+=("npm")
fi

if command -v rustc &>/dev/null; then
    echo "  [OK] rustc ($(rustc --version))"
else
    echo "  [MISSING] rustc (Rust)"
    echo "    Install: https://rustup.rs"
    missing+=("rustc")
fi

if command -v uv &>/dev/null; then
    echo "  [OK] uv ($(uv --version))"
elif command -v python3 &>/dev/null; then
    echo "  [OK] python3 ($(python3 --version)) — uv not found, falling back to pip"
else
    echo "  [MISSING] uv / python3"
    missing+=("uv")
fi

if [ ${#missing[@]} -gt 0 ]; then
    echo ""
    echo "Missing prerequisites: ${missing[*]}"
    echo "Install the missing tools and re-run this script."
    exit 1
fi
echo ""

# Step 1: Build console static assets
echo "== Step 1: Building Console Static Assets =="
cd console
npm ci
echo "Generating Tauri icons..."
# Also emits the PNG icons the Linux .deb bundler requires.
npm exec -- tauri icon ../scripts/pack/assets/icon.svg
echo "Syncing Tauri version..."
node ../scripts/pack-tauri/sync_tauri_version.mjs
echo "Building console frontend..."
npm run build:prod
cd ..
echo "Console static assets built"
echo ""

# Step 2: Build PyInstaller backend (onedir, with the bundled Python and Node
# runtimes the desktop shell expects) and copy it into console/src-tauri/binaries
# as a Tauri resource. Tauri-only staging is REQUIRED here.
echo "== Step 2: Building PyInstaller Backend =="
bash scripts/pack-tauri/build_pyinstaller.sh
echo "PyInstaller backend built"
echo ""

# Step 3: Build the Tauri .deb bundle
echo "== Step 3: Building Tauri .deb =="
BUNDLE_DIR="${REPO_ROOT}/console/src-tauri/target/release/bundle"
rm -rf "${BUNDLE_DIR}/deb"
cd console
echo "Building for Linux..."
npm exec -- tauri build \
    --config src-tauri/tauri.version.conf.json \
    --bundles deb
cd ..
echo "Tauri .deb built"
echo ""

# Step 4: Collect the distribution artifact
echo "== Step 4: Collecting Distribution Artifacts =="
DIST="${DIST:-dist}"
if [[ "${DIST}" = /* ]]; then
    DIST_ROOT="${DIST}"
else
    DIST_ROOT="${REPO_ROOT}/${DIST}"
fi
mkdir -p "${DIST_ROOT}"

DEB_SRC="$(find "${BUNDLE_DIR}/deb" -maxdepth 1 -name '*.deb' 2>/dev/null | head -1 || true)"
if [ -z "${DEB_SRC}" ]; then
    echo "ERROR: No Tauri .deb produced under ${BUNDLE_DIR}/deb"
    exit 1
fi

case "$(uname -m)" in
    aarch64 | arm64) ARCH_SUFFIX="arm64" ;;
    x86_64 | amd64) ARCH_SUFFIX="amd64" ;;
    *) ARCH_SUFFIX="$(uname -m)" ;;
esac

DEB_NAME="QwenPaw-Desktop-Tauri-${VERSION}-Linux-${ARCH_SUFFIX}.deb"
DEB_OUT="${DIST_ROOT}/${DEB_NAME}"
cp -f "${DEB_SRC}" "${DEB_OUT}"

if [ ! -f "${DEB_OUT}" ]; then
    echo "ERROR: Failed to stage ${DEB_OUT}"
    exit 1
fi

(
    cd "${DIST_ROOT}"
    sha256sum "${DEB_NAME}" > "${DEB_NAME}.sha256"
)

SIZE=$(du -sh "${DEB_OUT}" | cut -f1)
echo "Created ${DEB_OUT} (${SIZE})"
echo ""

echo "========================================="
echo "Build Complete!"
echo "========================================="
echo "Distribution:  ${DEB_OUT}"
echo ""
echo "NOTE: requires glibc >= 2.35 and libwebkit2gtk-4.1-0 on the target system."
echo "      For Kylin V10 SP1 use QwenPaw-Tauri-<version>-Linux-<arch>.deb instead."
echo ""
