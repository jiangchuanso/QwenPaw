#!/usr/bin/env bash
# Build the QwenPaw Desktop ELECTRON package for Linux (arm64 / amd64).
#
# Counterpart of scripts/pack-tauri/build_linux_desktop.sh, but ships the
# Electron shell instead of Tauri 2. Electron bundles its own Chromium + Node
# and needs no system WebKitGTK 4.1 / libsoup3, so this artifact installs and
# runs on glibc 2.31 targets (Kylin V10 SP1 / Ubuntu 20.04).
#
# When invoked from CI the Linux arm64 job runs this INSIDE an ubuntu:20.04
# container so the backend onedir + helper link against glibc 2.31 (linking
# against a newer glibc would produce a package the target OS cannot load).
#
# Build order (must be this way):
#   1. console frontend        -> console/dist (bundled into the backend)
#   2. PyInstaller backend      -> dist/pyinstaller/qwenpaw-backend (SKIP_TAURI_STAGING)
#   3. stage backend + python + node runtimes into console/electron/binaries
#   4. electron-builder         -> dist/*.deb
#
# Usage:
#   ./scripts/pack-electron/build_linux.sh

set -e

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

VERSION=$(sed -n 's/^__version__[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' src/qwenpaw/__version__.py)
DIST="${DIST:-dist}"
STAGE="${REPO_ROOT}/console/electron/binaries"

case "$(uname -m)" in
  aarch64 | arm64) DEB_ARCH="arm64" ;;
  x86_64 | amd64) DEB_ARCH="amd64" ;;
  *) DEB_ARCH="$(uname -m)" ;;
esac

echo "========================================="
echo "QwenPaw Linux Build - Electron desktop"
echo "========================================="
echo "Version: ${VERSION}"
echo "Arch:    $(uname -m) (${DEB_ARCH})"
echo ""

echo "== Step 1: Building console frontend =="
cd console
npm ci
npm run build:prod
cd ..

echo "== Step 2: Building PyInstaller backend (Tauri staging skipped) =="
QWENPAW_SKIP_TAURI_STAGING=1 bash scripts/pack-tauri/build_pyinstaller.sh

echo "== Step 3: Staging backend + runtimes into console/electron/binaries =="
rm -rf "${STAGE}"
mkdir -p "${STAGE}/qwenpaw-backend" "${STAGE}/python-runtime" "${STAGE}/node-runtime"

BACKEND_DIR="${DIST}/pyinstaller/qwenpaw-backend"
if [ ! -x "${BACKEND_DIR}/qwenpaw-backend" ] && [ ! -x "${BACKEND_DIR}/qwenpaw-backend.exe" ]; then
  echo "ERROR: backend not found at ${BACKEND_DIR}"
  exit 1
fi
cp -R "${BACKEND_DIR}/." "${STAGE}/qwenpaw-backend/"

echo "Staging python runtime..."
python3 scripts/pack-tauri/stage_python_runtime.py --dest "${STAGE}/python-runtime"
echo "Staging node runtime..."
python3 scripts/pack-tauri/stage_node_runtime.py --dest "${STAGE}/node-runtime"
echo "Staged."
echo ""

echo "== Step 4: Building Electron bundle =="
cd console
node ../scripts/pack-electron/sync-version.mjs
# The workflows attach the installers themselves (actions/upload-artifact, then
# desktop-publish.yml / upload-release via `gh release upload`). Without this
# flag electron-builder auto-selects `publish: onTag` as soon as CI exposes a
# tag, then fails uploading with the build jobs' read-only GITHUB_TOKEN.
npx electron-builder --publish never
cd ..

echo ""
echo "========================================="
echo "Build Complete!"
echo "========================================="
echo "Distribution:  ${REPO_ROOT}/${DIST}"
echo ""
echo "NOTE: requires libnss3/libgtk-3-0/libgbm1 on the target (see electron-builder.yml)."
echo "      Works on Kylin V10 SP1 (glibc 2.31) where Tauri 2 cannot."
