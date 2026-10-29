#!/usr/bin/env bash
# Stage the readable channel runtime for the Electron desktop package.
#
# Why this exists instead of relying on scripts/pack-tauri/build_pyinstaller.sh:
# that step writes <console/src-tauri>/binaries/channel-runtime — the Tauri
# resource root, deleted together with the Tauri shell — and it only runs when
# Tauri staging is NOT skipped, which the Electron build never does (it always
# sets QWENPAW_SKIP_TAURI_STAGING=1). Without this step the packaged Python
# finds no
#     <resources>/binaries/channel-runtime/runtime.json
# and qwenpaw.plugins.channel_bootstrap rejects the launcher environment with
# CHANNEL_RUNTIME_MANIFEST_INVALID as soon as a channel plugin resolves its
# dependencies: that module requires QWENPAW_TAURI_RESOURCE_DIR and the three
# QWENPAW_CHANNEL_* variables to be set together or not at all, and the shell
# already exports the first one.
#
# The resource directory passed here becomes Electron's process.resourcesPath
# (console/electron), so the relative paths recorded in the manifest resolve
# identically at runtime.
#
# Usage:
#   scripts/pack-electron/stage_channel_runtime.sh <resource-dir> [dist-dir]

set -e

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RESOURCE_DIR="${1:?usage: $0 <resource-dir> [dist-dir]}"
DIST="${2:-dist}"
if [ ! -d "${RESOURCE_DIR}" ]; then
  echo "ERROR: resource directory not found: ${RESOURCE_DIR}"
  exit 1
fi

BINARIES="${RESOURCE_DIR}/binaries"
DESKTOP_WHEELS="${REPO_ROOT}/${DIST}/desktop-wheels"
CHANNEL_WHEELS="${REPO_ROOT}/${DIST}/channel-wheels"

# The bootstrap interpreter only runs the staging script. Prefer the PyInstaller
# virtualenv the backend build created (it already has `packaging`), then fall
# back to any PATH interpreter that actually starts: a CI tool-cache Python can
# be built against a newer glibc than the container ships and die before
# argparse.
STAGE_PYTHON=""
for candidate in \
  "${REPO_ROOT}/${DIST}/pyinstaller-venv/bin/python" \
  "${REPO_ROOT}/${DIST}/pyinstaller-venv/Scripts/python.exe" \
  python3 \
  python; do
  resolved="$(command -v "$candidate" 2>/dev/null || true)"
  if [ -z "$resolved" ] && [ -x "$candidate" ]; then
    resolved="$candidate"
  fi
  if [ -n "$resolved" ] && "$resolved" -c 'import sys; sys.exit(0)' >/dev/null 2>&1; then
    STAGE_PYTHON="$resolved"
    break
  fi
done
if [ -z "${STAGE_PYTHON}" ]; then
  echo "ERROR: no runnable Python on PATH; it is required to stage the channel runtime"
  exit 1
fi
if ! "${STAGE_PYTHON}" -c 'import packaging' >/dev/null 2>&1; then
  echo "Installing packaging for the staging script..."
  "${STAGE_PYTHON}" -m pip install --disable-pip-version-check --quiet packaging
fi
echo "Bootstrap Python: ${STAGE_PYTHON}"

# The manifest records the interpreter relative to the resource root, so this
# must be the bundled runtime the shell exports as QWENPAW_DESKTOP_PY_RUNTIME
# (see console/electron/main.js bundledPython) — a mismatch is rejected as
# CHANNEL_RUNTIME_MANIFEST_MISMATCH at runtime.
NATIVE_HOST_PYTHON="${BINARIES}/python-runtime/python/bin/python3"
if [ ! -x "${NATIVE_HOST_PYTHON}" ]; then
  NATIVE_HOST_PYTHON="${BINARIES}/python-runtime/python/python.exe"
fi
if [ ! -x "${NATIVE_HOST_PYTHON}" ]; then
  echo "ERROR: bundled Python not found under ${BINARIES}/python-runtime"
  echo "       stage the runtimes first (they are what the manifest pins)."
  exit 1
fi

RELEASE_FILE="${BINARIES}/python-runtime/.python-runtime-version"
if [ ! -f "${RELEASE_FILE}" ]; then
  echo "ERROR: ${RELEASE_FILE} not found; stage the python runtime first"
  exit 1
fi

HOST_WHEELS=("${DESKTOP_WHEELS}"/qwenpaw-*.whl)
if [ "${#HOST_WHEELS[@]}" -ne 1 ] || [ ! -f "${HOST_WHEELS[0]}" ]; then
  echo "ERROR: expected exactly one qwenpaw wheel in ${DESKTOP_WHEELS}"
  echo "       build the backend first (scripts/pack-tauri/build_pyinstaller.*)."
  exit 1
fi
HOST_WHEEL="${HOST_WHEELS[0]}"

echo "Staging readable channel runtime..."
rm -rf "${CHANNEL_WHEELS}" "${BINARIES}/channel-runtime"
mkdir -p "${CHANNEL_WHEELS}"
# Offline by design: every wheel comes from the pool the backend build already
# produced, so the channel site cannot drift onto a newer PyPI release. That
# pool is built from QWENPAW_EXTRAS, so the list must include the "channels"
# extra; the frozen host still excludes those SDKs through
# scripts/pack-tauri/qwenpaw.spec.
"${NATIVE_HOST_PYTHON}" -m pip download \
  --disable-pip-version-check \
  --no-index \
  --only-binary=:all: \
  --find-links "${DESKTOP_WHEELS}" \
  --dest "${CHANNEL_WHEELS}" "${HOST_WHEEL}[channels]"
"${STAGE_PYTHON}" "${REPO_ROOT}/scripts/pack-tauri/stage_channel_runtime.py" \
  --python "${NATIVE_HOST_PYTHON}" \
  --wheel "${HOST_WHEEL}" \
  --resource-dir "${RESOURCE_DIR}" \
  --wheelhouse "${CHANNEL_WHEELS}" \
  --python-runtime-release "$(cat "${RELEASE_FILE}")"
echo "Staged channel runtime: ${BINARIES}/channel-runtime"
