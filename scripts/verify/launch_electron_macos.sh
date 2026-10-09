#!/usr/bin/env bash
# Unpack the Electron macOS zip, launch the shell headless (to start the
# bundled backend), wait for the backend port, and export BASE_URL to
# $GITHUB_ENV for the verifier step.
#
# Mirrors launch_tauri_macos.sh but for the Electron build. We launch headless
# (no visible window) because verification drives the SPA with an independent
# Playwright Chromium; the Electron window itself is not inspected.
set -euo pipefail

echo "[launch_electron_macos] Unpacking zip..."
mkdir -p dist/verify-electron
unzip -q dist/QwenPaw-*-mac-*.zip -d dist/verify-electron
APP_BIN="$(find dist/verify-electron -maxdepth 4 -path '*Contents/MacOS/QwenPaw' -type f | head -1)"
if [ -z "$APP_BIN" ]; then
  echo "::error::Electron Mac binary not found inside zip"
  exit 1
fi
echo "[launch_electron_macos] Found binary: $APP_BIN"

# Remove quarantine (CI download marks it) across the whole .app.
xattr -dr com.apple.quarantine "$(dirname "$(dirname "$(dirname "$APP_BIN")")")" 2>/dev/null || true

echo "[launch_electron_macos] Launching headless..."
"$APP_BIN" --headless &
echo "[launch_electron_macos] launched pid=$!"

# Wait for the sidecar to write the port file and respond.
PORT_FILE="$HOME/.qwenpaw/desktop_port"
PORT=""
for i in $(seq 1 90); do
  if [ -f "$PORT_FILE" ]; then
    PORT="$(cat "$PORT_FILE" | tr -d '[:space:]')"
    if [ -n "$PORT" ] && curl -sf "http://127.0.0.1:$PORT/api/version" >/dev/null; then
      echo "[launch_electron_macos] Electron backend ready on port $PORT after ~$((i*2))s"
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
