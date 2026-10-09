#!/usr/bin/env bash
# Build the QwenPaw Desktop ELECTRON package for macOS.
#
# Counterpart of scripts/pack-tauri/build_macos_pyinstaller.sh, but ships the
# Electron shell instead of Tauri 2. Electron bundles its own Chromium + Node and
# needs no system WebKitGTK / libsoup, so the desktop shell runs on the same
# macOS the Tauri build targeted — the only behavioral change is the shell.
#
# Build order (must be this way):
#   1. console frontend        -> console/dist (bundled into the backend)
#   2. PyInstaller backend      -> dist/pyinstaller/qwenpaw-backend (SKIP_TAURI_STAGING)
#   3. stage backend + python + node runtimes into console/electron/binaries
#   4. electron-builder         -> dist/*.dmg + dist/*.zip
#
# Pre-requirements:
#   * Node / npm on the build host (electron-builder downloads the prebuilt
#     Electron for the target arch).
#   * For notarized distribution set CSC_LINK / CSC_KEY_PASSWORD (electron-builder
#     reads them automatically). Without a cert it falls back to ad-hoc signing.
#
# Usage:
#   ./scripts/pack-electron/build_macos.sh

set -e

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

VERSION=$(sed -n 's/^__version__[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' src/qwenpaw/__version__.py)
DIST="${DIST:-dist}"
STAGE="${REPO_ROOT}/console/electron/binaries"

echo "========================================="
echo "QwenPaw macOS Build - Electron desktop"
echo "========================================="
echo "Version: ${VERSION}"
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
if [ ! -x "${BACKEND_DIR}/qwenpaw-backend" ]; then
  echo "ERROR: backend not found at ${BACKEND_DIR}"
  echo "       Build it first with: QWENPAW_SKIP_TAURI_STAGING=1 bash scripts/pack-tauri/build_pyinstaller.sh"
  exit 1
fi
cp -R "${BACKEND_DIR}/." "${STAGE}/qwenpaw-backend/"

echo "Staging python runtime..."
python3 scripts/pack-tauri/stage_python_runtime.py --dest "${STAGE}/python-runtime"
echo "Staging node runtime..."
python3 scripts/pack-tauri/stage_node_runtime.py --dest "${STAGE}/node-runtime"
echo "Staged."
echo ""

echo "== Step 3b: Building the Computer Use helper (Rust) =="
# The shell spawns this binary out of <resources>/binaries/qwenpaw-backend (see
# console/electron/computerUse.js helperPath). --target-dir is pinned so the
# artifact path cannot move under a CARGO_TARGET_DIR inherited from the caller.
HELPER_CRATE="${REPO_ROOT}/console/native/computer-use-helper"
HELPER_BIN="${HELPER_CRATE}/target/release/qwenpaw-computer-use-helper"
if ! command -v cargo >/dev/null 2>&1; then
  echo "ERROR: cargo not found; the Rust toolchain is required to build"
  echo "       qwenpaw-computer-use-helper (rustup default stable)."
  exit 1
fi
(cd "${HELPER_CRATE}" && cargo build --release --bin qwenpaw-computer-use-helper --target-dir "${HELPER_CRATE}/target")
if [ ! -x "${HELPER_BIN}" ]; then
  echo "ERROR: helper not found at ${HELPER_BIN}"
  exit 1
fi
cp "${HELPER_BIN}" "${STAGE}/qwenpaw-backend/"
echo "Staged helper: ${STAGE}/qwenpaw-backend/qwenpaw-computer-use-helper"
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
echo "Distribution: ${REPO_ROOT}/${DIST}"
echo "NOTE: macOS notarization requires an Apple cert via CSC_LINK/CSC_KEY_PASSWORD."
