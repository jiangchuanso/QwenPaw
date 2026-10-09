#!/usr/bin/env bash
# Install the Electron .deb (its Depends already declare the Chromium/Electron
# runtime libraries), launch the shell headless (to start the bundled backend),
# wait for the backend port, and export BASE_URL to $GITHUB_ENV for the verifier
# step.
#
# Runs inside the ubuntu:20.04 arm64 container used by the Linux build job.
# '--no-sandbox' is required because the container runs as root.
set -euo pipefail

DEB="$(ls dist/QwenPaw-*-linux-*.deb 2>/dev/null | head -1)"
if [ -z "$DEB" ]; then
  echo "::error::Electron .deb not found in dist/"
  exit 1
fi
echo "[launch_electron_linux] Installing $DEB (resolves runtime deps via apt)..."
apt-get update -qq
apt-get install -y "./$DEB"

# Locate the installed Electron binary (electron-builder deb layout:
# /opt/<productName>/<executableName>).
BIN="$(find /opt/QwenPaw -maxdepth 2 -type f -name QwenPaw 2>/dev/null | head -1)"
if [ -z "$BIN" ]; then
  # Fallback: ask dpkg where the binary shipped.
  BIN="$(dpkg -L qwenpaw 2>/dev/null | grep -E '/QwenPaw$' | head -1)"
fi
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  echo "::error::Electron binary not found after .deb install"
  exit 1
fi
echo "[launch_electron_linux] Electron binary: $BIN"

"$BIN" --headless --no-sandbox --ozone-platform=headless --disable-gpu &
echo "[launch_electron_linux] launched pid=$!"

# Wait for the sidecar to write the port file and respond.
PORT_FILE="$HOME/.qwenpaw/desktop_port"
PORT=""
for i in $(seq 1 90); do
  if [ -f "$PORT_FILE" ]; then
    PORT="$(cat "$PORT_FILE" | tr -d '[:space:]')"
    if [ -n "$PORT" ] && curl -sf "http://127.0.0.1:$PORT/api/version" >/dev/null; then
      echo "[launch_electron_linux] Electron backend ready on port $PORT after ~$((i*2))s"
      break
    fi
  fi
  if [ "$i" = "90" ]; then
    echo "::error::Electron backend did not start within 180s"
    echo "[debug] PORT_FILE=$PORT_FILE exists=$([ -f "$PORT_FILE" ] && echo yes || echo no)"
    echo "[debug] desktop.log tail (if exists):"
    tail -50 "$HOME/.qwenpaw/desktop.log" 2>/dev/null || echo "  (no desktop.log)"
    exit 1
  fi
  sleep 2
done

# Remove auto-init BOOTSTRAP.md so the verifier drives the agent in normal QA mode.
rm -f "$HOME/.qwenpaw/workspaces/default/BOOTSTRAP.md"

export BASE_URL="http://127.0.0.1:$PORT"
echo "BASE_URL=$BASE_URL" >> "$GITHUB_ENV"
echo "$BASE_URL"
