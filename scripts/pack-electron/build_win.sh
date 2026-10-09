#!/usr/bin/env bash
# Build the QwenPaw Desktop ELECTRON package for Windows.
#
# Counterpart of scripts/pack-tauri/build_win_pyinstaller.ps1, but ships the
# Electron shell instead of Tauri 2. Electron bundles its own Chromium + Node and
# needs no system WebKitGTK / libsoup, so the desktop shell runs on Windows the
# same way the Tauri build did — the only behavioral change is the shell.
#
# Build order (must be this way):
#   1. console frontend        -> console/dist (bundled into the backend)
#   2. PyInstaller backend      -> dist/pyinstaller/qwenpaw-backend (SKIP_TAURI_STAGING)
#   3. stage backend + python + node runtimes into console/electron/binaries
#   4. electron-builder         -> dist/*.exe (NSIS)
#
# Pre-requirements:
#   * Node / npm on the build host (electron-builder downloads the prebuilt
#     Electron for the target arch); NSIS is required for the installer target.
#   * Set CSC_LINK/CSC_KEY_PASSWORD for Authenticode signing (optional).
#
# Usage (run from a bash shell on the Windows runner, e.g. git-bash / CI shell:bash):
#   ./scripts/pack-electron/build_win.sh

set -e

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

VERSION=$(sed -n 's/^__version__[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' src/qwenpaw/__version__.py)
DIST="${DIST:-dist}"
STAGE="${REPO_ROOT}/console/electron/binaries"

echo "========================================="
echo "QwenPaw Windows Build - Electron desktop"
echo "========================================="
echo "Version: ${VERSION}"
echo ""

echo "== Step 1: Building console frontend =="
cd console
npm ci
npm run build:prod
cd ..

echo "== Step 2: Building PyInstaller backend (Tauri staging skipped) =="
QWENPAW_SKIP_TAURI_STAGING=1 powershell -NoProfile -File ./scripts/pack-tauri/build_pyinstaller.ps1

echo "== Step 3: Staging backend + runtimes into console/electron/binaries =="
rm -rf "${STAGE}"
mkdir -p "${STAGE}/qwenpaw-backend" "${STAGE}/python-runtime" "${STAGE}/node-runtime"

BACKEND_DIR="${DIST}/pyinstaller/qwenpaw-backend"
if [ ! -x "${BACKEND_DIR}/qwenpaw-backend.exe" ]; then
  echo "ERROR: backend not found at ${BACKEND_DIR}/qwenpaw-backend.exe"
  echo "       Build it first with: QWENPAW_SKIP_TAURI_STAGING=1 powershell ./scripts/pack-tauri/build_pyinstaller.ps1"
  exit 1
fi
cp -R "${BACKEND_DIR}/." "${STAGE}/qwenpaw-backend/"

# A stock CPython install for Windows ships `python.exe`, not `python3.exe`, so
# the Git Bash shell the CI job uses cannot be assumed to resolve `python3`
# (build_pyinstaller.sh probes for the same reason on Linux). Probe both and
# keep the first that actually runs.
STAGE_PYTHON=""
for candidate in python3 python; do
  resolved="$(command -v "$candidate" 2>/dev/null || true)"
  if [ -n "$resolved" ] && "$resolved" -c 'import sys; sys.exit(0)' >/dev/null 2>&1; then
    STAGE_PYTHON="$resolved"
    break
  fi
done
if [ -z "${STAGE_PYTHON}" ]; then
  echo "ERROR: no runnable Python on PATH; it is required to stage the bundled runtimes"
  exit 1
fi
echo "Staging python runtime..."
"${STAGE_PYTHON}" scripts/pack-tauri/stage_python_runtime.py --dest "${STAGE}/python-runtime"
echo "Staging node runtime..."
"${STAGE_PYTHON}" scripts/pack-tauri/stage_node_runtime.py --dest "${STAGE}/node-runtime"
echo "Staged."
echo ""

echo "== Step 3b: Building the Computer Use helper (Rust) =="
# The shell spawns this binary out of <resources>/binaries/qwenpaw-backend (see
# console/electron/computerUse.js helperPath). --target-dir is pinned so the
# artifact path cannot move under a CARGO_TARGET_DIR inherited from the caller.
HELPER_CRATE="${REPO_ROOT}/console/native/computer-use-helper"
HELPER_EXE="${HELPER_CRATE}/target/release/qwenpaw-computer-use-helper.exe"
if ! command -v cargo >/dev/null 2>&1; then
  echo "ERROR: cargo not found; the Rust toolchain is required to build"
  echo "       qwenpaw-computer-use-helper (rustup default stable)."
  exit 1
fi
(cd "${HELPER_CRATE}" && cargo build --release --bin qwenpaw-computer-use-helper --target-dir "${HELPER_CRATE}/target")
if [ ! -f "${HELPER_EXE}" ]; then
  echo "ERROR: helper not found at ${HELPER_EXE}"
  exit 1
fi
cp "${HELPER_EXE}" "${STAGE}/qwenpaw-backend/"
echo "Staged helper: ${STAGE}/qwenpaw-backend/qwenpaw-computer-use-helper.exe"
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
echo "NOTE: NSIS is required for the windows target; set CSC_LINK/CSC_KEY_PASSWORD for Authenticode signing."
