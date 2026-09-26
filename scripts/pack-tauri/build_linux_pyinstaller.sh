#!/usr/bin/env bash
# Build QwenPaw for Linux as BACKEND-ONLY packages (no Tauri desktop shell):
#   1. a .deb that installs the server into /opt/qwenpaw (+ launcher, desktop
#      entry, systemd --user unit);
#   2. a relocatable .tar.gz that runs straight from the extracted directory.
#
# Why no Tauri shell on Linux: Tauri 2 links against WebKitGTK 4.1 + libsoup3,
# which Ubuntu 20.04 / Kylin V10 SP1 (glibc 2.31) do not ship — the PPA that
# used to backport webkit2gtk-4.1 for focal is gone, and wry (Tauri's webview
# layer) hard-locks to the 4.1/libsoup3 crate line with no 4.0 switch. So these
# packages ship the FastAPI backend plus the prebuilt console and open the UI in
# the system browser instead.
#
# Target platform: Ubuntu 20.04 aarch64 (glibc 2.31) so the artifacts also work
# on Kylin V10 SP1 (飞腾/ARM). Build this inside an ubuntu:20.04 arm64
# environment — see the build-tauri-linux-arm64 job in
# .github/workflows/desktop-build.yml — otherwise the compiled extensions may
# link a newer glibc than the target OS provides.
#
# Usage:
#   ./scripts/pack-tauri/build_linux_pyinstaller.sh
#
# Produces (the "Tauri" stem is kept for the release plumbing globs):
#   dist/QwenPaw-Tauri-<version>-Linux-<arch>.deb        (+ .sha256)
#   dist/QwenPaw-Tauri-<version>-Linux-<arch>.tar.gz     (+ .sha256)

set -e

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

VERSION=$(sed -n 's/^__version__[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' src/qwenpaw/__version__.py)
DIST="${DIST:-dist}"
# Exported so build_pyinstaller.sh (invoked below) writes into the same tree.
export DIST
PACKAGE_NAME="qwenpaw"
INSTALL_DIR="/opt/qwenpaw"

echo "========================================="
echo "QwenPaw Linux Build - backend only (deb + tar.gz)"
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

if command -v uv &>/dev/null; then
    echo "  [OK] uv ($(uv --version))"
elif command -v python3 &>/dev/null; then
    echo "  [OK] python3 ($(python3 --version)) — uv not found, falling back to pip"
else
    echo "  [MISSING] uv / python3"
    missing+=("uv")
fi

if command -v dpkg-deb &>/dev/null; then
    echo "  [OK] dpkg-deb"
else
    echo "  [MISSING] dpkg-deb (install the 'dpkg' package)"
    missing+=("dpkg-deb")
fi

if [ ${#missing[@]} -gt 0 ]; then
    echo ""
    echo "Missing prerequisites: ${missing[*]}"
    echo "Install the missing tools and re-run this script."
    exit 1
fi
echo ""

case "$(uname -m)" in
    aarch64 | arm64) DEB_ARCH="arm64" ;;
    x86_64 | amd64) DEB_ARCH="amd64" ;;
    *) DEB_ARCH="$(uname -m)" ;;
esac

# Step 1: Build console static assets
echo "== Step 1: Building Console Static Assets =="
cd console
npm ci
echo "Building console frontend..."
npm run build:prod
cd ..
echo "Console static assets built"
echo ""

# Step 2: Build the PyInstaller backend bundle (self-contained: bundled CPython,
# all Python deps and the console assets are embedded by qwenpaw.spec).
# Tauri-only staging (Node runtime / Chrome native-messaging host / copying into
# console/src-tauri/binaries) is skipped — none of it is used by these packages.
echo "== Step 2: Building PyInstaller Backend =="
QWENPAW_SKIP_TAURI_STAGING=1 bash scripts/pack-tauri/build_pyinstaller.sh
BACKEND_DIR="${DIST}/pyinstaller/qwenpaw-backend"
if [ ! -x "${BACKEND_DIR}/qwenpaw" ]; then
    echo "ERROR: bundled CLI not found at ${BACKEND_DIR}/qwenpaw"
    exit 1
fi
echo "PyInstaller backend built"
echo ""

# The launcher is shared by both formats: it resolves its own directory, so it
# works from /opt/qwenpaw (deb) and from the extracted tarball alike.
write_launcher() {
    cat > "$1" << 'EOF'
#!/bin/sh
# Start the QwenPaw server (if it is not already running) and open the web UI
# in the default browser.
set -e

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
HOST="${QWENPAW_HOST:-127.0.0.1}"
PORT="${QWENPAW_PORT:-8088}"
URL="http://${HOST}:${PORT}"
STATE_DIR="${HOME}/.qwenpaw"
mkdir -p "${STATE_DIR}"

if ! curl -sf "${URL}/api/version" >/dev/null 2>&1; then
  echo "Starting QwenPaw server on ${URL} ..."
  nohup "${HERE}/qwenpaw" app --host "${HOST}" --port "${PORT}" \
    >>"${STATE_DIR}/server.log" 2>&1 &
  i=0
  while [ "${i}" -lt 120 ]; do
    if curl -sf "${URL}/api/version" >/dev/null 2>&1; then
      break
    fi
    i=$((i + 1))
    sleep 1
  done
fi

if command -v xdg-open >/dev/null 2>&1; then
  xdg-open "${URL}" >/dev/null 2>&1 || true
else
  echo "QwenPaw is available at ${URL}"
fi
EOF
    chmod 755 "$1"
}

write_readme() {
    cat > "$1" << EOF
QwenPaw ${VERSION} - Linux ${DEB_ARCH} backend bundle
================================================

This bundle runs the QwenPaw server and serves the web UI to your browser.
It is self-contained (a bundled CPython plus every Python dependency and the
web console are included) and needs no installation.

Quick start
-----------
    ./qwenpaw-web       start the server and open http://127.0.0.1:8088
    ./qwenpaw app       start the server only
    ./qwenpaw --help    full CLI

Notes
-----
* Data, configuration and logs live in ~/.qwenpaw
* Default bind address 127.0.0.1:8088 (override with QWENPAW_HOST / QWENPAW_PORT)
* Needs a CA certificate store (ca-certificates) and curl for the launcher.
* The Tauri desktop shell is not shipped for Linux because Tauri 2 requires
  WebKitGTK 4.1 + libsoup3, which Ubuntu 20.04 based systems (for example
  Kylin V10 SP1) do not provide.
EOF
}

# Step 3: Assemble the releases into a staging tree
echo "== Step 3: Assembling the packages =="
STAGE_ROOT="${DIST}/linux-stage"
DEB_ROOT="${STAGE_ROOT}/deb-root"
TAR_DIR_NAME="QwenPaw-${VERSION}-Linux-${DEB_ARCH}"
TAR_ROOT="${STAGE_ROOT}/${TAR_DIR_NAME}"

rm -rf "${STAGE_ROOT}"
mkdir -p \
    "${DEB_ROOT}${INSTALL_DIR}" \
    "${DEB_ROOT}/usr/bin" \
    "${DEB_ROOT}/usr/share/applications" \
    "${DEB_ROOT}/usr/share/icons/hicolor/256x256/apps" \
    "${DEB_ROOT}/usr/lib/systemd/user" \
    "${DEB_ROOT}/DEBIAN" \
    "${TAR_ROOT}"

# 3a. Shared payload: the self-contained backend bundle + the launcher.
for root in "${DEB_ROOT}${INSTALL_DIR}" "${TAR_ROOT}"; do
    cp -R "${BACKEND_DIR}/." "${root}/"
    chmod +x "${root}/qwenpaw" "${root}/qwenpaw-backend"
    write_launcher "${root}/qwenpaw-web"
done

# 3b. .deb extras: CLI on PATH, desktop entry, icon, optional user service.
# A tiny wrapper (not a symlink) keeps the onedir bundle's _internal/
# directory resolvable regardless of $0 handling.
cat > "${DEB_ROOT}/usr/bin/qwenpaw" << EOF
#!/bin/sh
# QwenPaw CLI (bundled, self-contained).
exec ${INSTALL_DIR}/qwenpaw "\$@"
EOF

cat > "${DEB_ROOT}/usr/bin/qwenpaw-web" << EOF
#!/bin/sh
# Launcher shipped inside ${INSTALL_DIR}; see qwenpaw-web there.
exec ${INSTALL_DIR}/qwenpaw-web "\$@"
EOF

cat > "${DEB_ROOT}/usr/share/applications/qwenpaw.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Name=QwenPaw
GenericName=Personal Assistant
Comment=Start the QwenPaw server and open the web console
Exec=/usr/bin/qwenpaw-web
Icon=qwenpaw
Terminal=false
Categories=Utility;Office;
StartupNotify=false
EOF

if [ -f "console/src-tauri/icons/icon.png" ]; then
    cp "console/src-tauri/icons/icon.png" \
       "${DEB_ROOT}/usr/share/icons/hicolor/256x256/apps/qwenpaw.png"
else
    echo "  [WARN] console/src-tauri/icons/icon.png not found; shipping without an icon"
fi

cat > "${DEB_ROOT}/usr/lib/systemd/user/qwenpaw.service" << 'EOF'
[Unit]
Description=QwenPaw personal assistant server
Documentation=https://github.com/agentscope-ai/QwenPaw
After=network-online.target

[Service]
Type=simple
ExecStart=/opt/qwenpaw/qwenpaw app --host 127.0.0.1 --port 8088
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF

chmod 755 "${DEB_ROOT}/usr/bin/qwenpaw" \
          "${DEB_ROOT}/usr/bin/qwenpaw-web"

# 3c. Control metadata. Depends stays deliberately short: the bundle embeds
# CPython and every Python dependency, so only the C library (plus a CA store and
# curl for the launcher) are expected from the system.
INSTALLED_SIZE="$(du -sk "${DEB_ROOT}${INSTALL_DIR}" | cut -f1)"

cat > "${DEB_ROOT}/DEBIAN/control" << EOF
Package: ${PACKAGE_NAME}
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: ${DEB_ARCH}
Maintainer: QwenPaw <noreply@qwenpaw.agentscope.io>
Installed-Size: ${INSTALLED_SIZE}
Depends: libc6 (>= 2.31), ca-certificates, curl
Homepage: https://github.com/agentscope-ai/QwenPaw
Description: QwenPaw personal assistant (backend server, browser UI)
 QwenPaw runs a local FastAPI backend that serves both the HTTP API and the
 bundled web console. This is the Linux backend build: start the server and use
 the UI from your browser.
 .
 The Tauri desktop shell is intentionally not included on Linux: Tauri 2
 requires WebKitGTK 4.1 and libsoup3, which are unavailable on Ubuntu 20.04
 based systems such as Kylin V10 SP1.
EOF

cat > "${DEB_ROOT}/DEBIAN/postinst" << 'EOF'
#!/bin/sh
set -e

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database -q /usr/share/applications || true
fi

cat << 'NOTICE'
QwenPaw (backend) installed.

  Start the server     : qwenpaw app            # http://127.0.0.1:8088
  Or use the launcher  : qwenpaw-web            # starts server + opens browser
  Start at login (user): systemctl --user enable --now qwenpaw
  Data, config and logs: ~/.qwenpaw

NOTICE
exit 0
EOF

cat > "${DEB_ROOT}/DEBIAN/prerm" << 'EOF'
#!/bin/sh
set -e

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user stop qwenpaw >/dev/null 2>&1 || true
fi

exit 0
EOF

chmod 755 "${DEB_ROOT}/DEBIAN/postinst" "${DEB_ROOT}/DEBIAN/prerm"

# 3d. Tarball extras: README next to the binaries.
write_readme "${TAR_ROOT}/README.txt"

# Step 4: Build the artifacts and stage them for distribution
echo "== Step 4: Building the artifacts =="

if [[ "${DIST}" = /* ]]; then
    DIST_ROOT="${DIST}"
else
    DIST_ROOT="${REPO_ROOT}/${DIST}"
fi
mkdir -p "${DIST_ROOT}"

DEB_NAME="QwenPaw-Tauri-${VERSION}-Linux-${DEB_ARCH}.deb"
TAR_NAME="QwenPaw-Tauri-${VERSION}-Linux-${DEB_ARCH}.tar.gz"
DEB_OUT="${DIST_ROOT}/${DEB_NAME}"
TAR_OUT="${DIST_ROOT}/${TAR_NAME}"

# --root-owner-group keeps the payload owned by root:root without fakeroot.
dpkg-deb --build --root-owner-group "${DEB_ROOT}" "${DEB_OUT}"

# -C keeps a single top-level directory inside the archive.
tar -czf "${TAR_OUT}" -C "${STAGE_ROOT}" "${TAR_DIR_NAME}"

for artifact in "${DEB_OUT}" "${TAR_OUT}"; do
    if [ ! -f "${artifact}" ]; then
        echo "ERROR: Failed to stage ${artifact}"
        exit 1
    fi
done

(
    cd "${DIST_ROOT}"
    sha256sum "${DEB_NAME}" > "${DEB_NAME}.sha256"
    sha256sum "${TAR_NAME}" > "${TAR_NAME}.sha256"
)

echo "Created ${DEB_OUT} ($(du -sh "${DEB_OUT}" | cut -f1))"
echo "Created ${TAR_OUT} ($(du -sh "${TAR_OUT}" | cut -f1))"
echo ""

echo "========================================="
echo "Build Complete!"
echo "========================================="
echo "Distribution:  ${DEB_OUT}"
echo "               ${TAR_OUT}"
echo ""
echo ".deb install:  sudo dpkg -i \"${DEB_OUT}\" && sudo apt-get -f install"
echo ".tar.gz usage: tar -xzf \"${TAR_OUT}\" && cd ${TAR_DIR_NAME} && ./qwenpaw-web"
echo ""
