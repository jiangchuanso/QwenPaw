/**
 * QwenPaw Desktop — Computer Use lifecycle (Electron port).
 *
 * Faithful re-implementation of console/src-tauri/src/computer_use_runtime.rs
 * and the macOS bundle seeding in computer_use_helper.rs, so the native
 * `qwenpaw-computer-use-helper` works under the Electron shell exactly as it did
 * under Tauri.
 *
 * Responsibilities (mirroring the Rust design):
 *   - `startComputerUse` brings up an authenticated localhost TCP *control*
 *     endpoint. The Python backend reads its host/port/token from the env vars
 *     this module injects, then connects and sends `{action:"acquire"}` whenever
 *     it needs screen control.
 *   - On `acquire` we spawn the helper binary (if not already running), wait for
 *     its `QWENPAW_COMPUTER_USE_READY {protocol_version}` line on stdout, and
 *     return the pipe name + capability secret the Python client uses to talk to
 *     the helper directly.
 *   - On shutdown we kill the helper (Linux/macOS/Windows) and clean up the
 *     Unix socket / pid marker.
 *
 * Differences from the Rust build (documented, not silent):
 *   - Windows crash-safety: Rust assigns the helper to a KILL_ON_JOB_CLOSE Job
 *     Object so it dies even if the host crashes. Pure-JS Electron has no FFI,
 *     so we kill the helper on graceful `before-quit` only. A crashed desktop
 *     process may leave a stray helper on Windows (an annoyance, not a leak of
 *     the desktop window). Linux/macOS already had no Job Object in the Rust
 *     build (macOS relies on the helper's own parent-death watch).
 *   - macOS focus leases hide/show the host BrowserWindow instead of a Tauri
 *     webview window; behaviour is equivalent for the single-window desktop.
 *
 * @type {import('electron')}
 */
"use strict";

const { spawn } = require("child_process");
const net = require("net");
const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");

const PROTOCOL_VERSION = 2;
const HELPER_READY_PREFIX = "QWENPAW_COMPUTER_USE_READY ";
const CAPABILITY_ENV = "QWENPAW_CU_CAPABILITY";
const CONTROL_HOST_ENV = "QWENPAW_COMPUTER_USE_CONTROL_HOST";
const CONTROL_PORT_ENV = "QWENPAW_COMPUTER_USE_CONTROL_PORT";
const CONTROL_TOKEN_ENV = "QWENPAW_COMPUTER_USE_CONTROL_TOKEN";
const HELPER_READY_TIMEOUT_MS = 8000;
const CONTROL_CONNECTION_TIMEOUT_MS = 2000;
const CONTROL_MAX_MESSAGE_BYTES = 4096;
const MAX_CAPTURED_HELPER_STDERR_CHARS = 4096;

/** @type {{ server: net.Server|null, port: number|null, token: string|null,
 *           child: import('child_process').ChildProcess|null, childReady: (()=>void)|null,
 *           capability: string|null, pipeName: string|null, helperPid: number|null,
 *           stopping: boolean, focusLeases: Set<string>, restoreHostAfterFocus: boolean,
 *           hideHostWindow: (()=>void)|null, showHostWindow: (()=>void)|null,
 *           binariesDir: string|null }} */
let state = null;

function randomHex(byteCount) {
  return crypto.randomBytes(byteCount).toString("hex");
}

function isWindows() {
  return process.platform === "win32";
}
function isMac() {
  return process.platform === "darwin";
}

function helperName() {
  return isWindows()
    ? "qwenpaw-computer-use-helper.exe"
    : "qwenpaw-computer-use-helper";
}

function helperPath() {
  return path.join(state.binariesDir, "qwenpaw-backend", helperName());
}

/**
 * Build the endpoint the helper listens on: a Windows named-pipe name, or a
 * private Unix domain socket path elsewhere. Mirrors endpoint_address() in the
 * Rust runtime (random 0700 dir on Unix to avoid predictable /tmp names).
 */
function endpointAddress() {
  if (isWindows()) {
    return `qwenpaw-computer-use-${process.pid}-${randomHex(6)}`;
  }
  const socketRoot = isMac() ? "/tmp" : os.tmpdir();
  const dir = path.join(socketRoot, `qwenpaw-cu-${randomHex(16)}`);
  fs.mkdirSync(dir, { recursive: false, mode: 0o700 });
  return path.join(dir, `${randomHex(8)}.sock`);
}

function helperPidPath(endpoint) {
  return `${endpoint}.pid`;
}

function cleanupEndpoint(endpoint) {
  if (isWindows()) return; // named-pipe instances vanish when the helper exits
  for (const p of [endpoint, helperPidPath(endpoint)]) {
    try {
      fs.unlinkSync(p);
    } catch (err) {
      if (err.code !== "ENOENT") {
        console.warn(`[computer-use] failed to remove ${p}: ${err.message}`);
      }
    }
  }
  const directory = path.dirname(endpoint);
  if (path.basename(directory).startsWith("qwenpaw-cu-")) {
    try {
      fs.rmdirSync(directory);
    } catch (err) {
      if (err.code !== "ENOENT") {
        console.debug(
          `[computer-use] failed to remove helper dir ${directory}: ${err.message}`,
        );
      }
    }
  }
}

/**
 * On macOS the helper must live in ~/Applications as a real .app so TCC grants
 * Screen Recording / Accessibility. Seed it from the bundled binary on first use
 * (and keep it refreshed), matching computer_use_helper::installed_bundle.
 * Returns the .app bundle path, or null if seeding is not possible.
 */
function ensureMacBundle() {
  const home = os.homedir();
  if (!home) return null;
  const bundle = path.join(home, "Applications", "QwenPaw Computer Use.app");
  const executable = path.join(
    bundle,
    "Contents",
    "MacOS",
    "qwenpaw-computer-use-helper",
  );
  const seed = helperPath();
  if (!fs.existsSync(seed)) return null;

  try {
    if (
      fs.existsSync(executable) &&
      fs.readFileSync(executable).equals(fs.readFileSync(seed))
    ) {
      return bundle;
    }
    const macosDir = path.dirname(executable);
    fs.mkdirSync(macosDir, { recursive: true });
    fs.copyFileSync(seed, executable);
    fs.chmodSync(executable, 0o755);
    const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleDisplayName</key><string>QwenPaw Computer Use</string>
    <key>CFBundleExecutable</key><string>qwenpaw-computer-use-helper</string>
    <key>CFBundleIdentifier</key><string>io.agentscope.qwenpaw.computer-use.v1</string>
    <key>CFBundleName</key><string>QwenPaw Computer Use</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
`;
    fs.writeFileSync(path.join(bundle, "Contents", "Info.plist"), plist);
    return bundle;
  } catch (err) {
    console.warn(
      `[computer-use] failed to seed macOS helper bundle: ${err.message}`,
    );
    return null;
  }
}

function controlResponse(payload) {
  return JSON.stringify(payload);
}

function serveControlConnection(sock, token) {
  sock.setTimeout(CONTROL_CONNECTION_TIMEOUT_MS);
  let buffer = "";
  let handled = false;

  const fail = (msg) => {
    if (handled) return;
    handled = true;
    try {
      sock.write(controlResponse({ ok: false, error: msg }) + "\n");
    } catch {
      /* socket already gone */
    }
    sock.destroy();
  };

  sock.on("timeout", () => fail("timeout"));
  sock.on("error", () => fail("error"));
  sock.on("data", (chunk) => {
    if (handled) return;
    buffer += chunk.toString("latin1");
    if (buffer.length > CONTROL_MAX_MESSAGE_BYTES) {
      fail("invalid_request");
      return;
    }
    const nl = buffer.indexOf("\n");
    if (nl === -1) return;
    const line = buffer.slice(0, nl);
    buffer = buffer.slice(nl + 1);

    let request;
    try {
      request = JSON.parse(line);
    } catch {
      fail("invalid_request");
      return;
    }
    if (request.token !== token) {
      fail("unauthorized");
      return;
    }
    handleControlAction(request)
      .then((payload) => {
        if (handled) return;
        handled = true;
        try {
          sock.write(controlResponse({ ok: true, ...payload }) + "\n");
        } catch {
          /* socket gone */
        }
        sock.end();
      })
      .catch((err) => fail(err.message || "runtime_unavailable"));
  });
}

async function handleControlAction(request) {
  switch (request.action) {
    case "acquire": {
      const cap = await ensureHelper();
      return { pipe_name: cap.pipeName, capability: cap.capability };
    }
    case "begin_focus": {
      if (!isMac()) return Promise.reject(new Error("invalid_request"));
      const leaseId = request.lease_id;
      if (!leaseId) return Promise.reject(new Error("invalid_request"));
      if (state.focusLeases.has(leaseId)) return { lease_id: leaseId };
      const wasVisible = isWindowVisible();
      if (wasVisible && state.hideHostWindow) state.hideHostWindow();
      state.restoreHostAfterFocus = state.restoreHostAfterFocus || wasVisible;
      state.focusLeases.add(leaseId);
      return { lease_id: leaseId };
    }
    case "end_focus": {
      if (!isMac()) return Promise.reject(new Error("invalid_request"));
      const leaseId = request.lease_id;
      if (!leaseId) return Promise.reject(new Error("invalid_request"));
      state.focusLeases.delete(leaseId);
      if (state.focusLeases.size === 0 && state.restoreHostAfterFocus) {
        state.restoreHostAfterFocus = false;
        if (state.showHostWindow) state.showHostWindow();
      }
      return {};
    }
    default:
      return Promise.reject(new Error("invalid_request"));
  }
}

function isWindowVisible() {
  try {
    return require("electron")
      .BrowserWindow.getAllWindows()
      .some((w) => w.isVisible());
  } catch {
    return false;
  }
}

function parseHelperReadyLine(line) {
  if (!line.startsWith(HELPER_READY_PREFIX)) return null;
  let payload;
  try {
    payload = JSON.parse(line.slice(HELPER_READY_PREFIX.length).trim());
  } catch (err) {
    throw new Error(
      `Computer Use helper emitted invalid readiness JSON: ${err.message}`,
    );
  }
  if (payload.protocol_version !== PROTOCOL_VERSION) {
    throw new Error(
      `Computer Use helper protocol ${payload.protocol_version} is incompatible with host protocol ${PROTOCOL_VERSION}`,
    );
  }
  return true;
}

/**
 * Spawn (if needed) and wait for readiness of the native helper. Resolves with
 * { pipeName, capability }. Mirrors computer_use_runtime::ensure.
 */
function ensureHelper() {
  if (state.child && state.capability && state.pipeName) {
    if (state.child.exitCode === null && state.child.signalCode === null) {
      return Promise.resolve({
        pipeName: state.pipeName,
        capability: state.capability,
      });
    }
    stopHelperChild();
  }

  const pipeName = endpointAddress();
  const capability = randomHex(32);
  let command;
  let args;
  const env = { ...process.env, [CAPABILITY_ENV]: capability };

  if (isMac()) {
    const bundle = ensureMacBundle();
    if (!bundle)
      throw new Error("Computer Use helper bundle unavailable on macOS");
    command = "open";
    args = ["-n", "-W", bundle, "--args", "serve", "--pipe", pipeName];
  } else {
    command = helperPath();
    args = ["serve", "--pipe", pipeName];
  }

  let child;
  try {
    child = spawn(command, args, {
      env,
      windowsHide: isWindows(),
      stdio: ["ignore", "pipe", "pipe"],
    });
  } catch (err) {
    cleanupEndpoint(pipeName);
    throw new Error(`failed to start Computer Use helper: ${err.message}`);
  }

  state.child = child;
  state.capability = capability;
  state.pipeName = pipeName;
  state.helperPid = child.pid ?? null;

  return new Promise((resolve, reject) => {
    let capturedStderr = "";
    let settled = false;
    const timeout = setTimeout(() => {
      if (settled) return;
      settled = true;
      stopHelperChild();
      cleanupEndpoint(pipeName);
      reject(
        new Error(
          `timed out after ${
            HELPER_READY_TIMEOUT_MS / 1000
          }s waiting for Computer Use helper readiness${
            capturedStderr ? `; helper stderr: ${capturedStderr}` : ""
          }`,
        ),
      );
    }, HELPER_READY_TIMEOUT_MS);

    const onStdout = (chunk) => {
      const text = chunk.toString();
      for (const raw of text.split("\n")) {
        const line = raw.trim();
        if (!line) continue;
        if (!line.startsWith(HELPER_READY_PREFIX)) {
          console.log(`[computer-use] helper stdout: ${line}`);
          continue;
        }
        try {
          parseHelperReadyLine(line);
        } catch (err) {
          if (!settled) {
            settled = true;
            clearTimeout(timeout);
            stopHelperChild();
            cleanupEndpoint(pipeName);
            reject(new Error(err.message));
          }
          return;
        }
        if (!settled) {
          settled = true;
          clearTimeout(timeout);
          console.log(`[computer-use] helper ready pid=${state.helperPid}`);
          resolve({ pipeName, capability });
        }
        return;
      }
    };
    const onStderr = (chunk) => {
      const text = chunk.toString();
      for (const raw of text.split("\n")) {
        const line = raw.trim();
        if (!line) continue;
        console.error(`[computer-use] helper stderr: ${line}`);
        if (capturedStderr.length < MAX_CAPTURED_HELPER_STDERR_CHARS) {
          capturedStderr += line + "\n";
          if (capturedStderr.length > MAX_CAPTURED_HELPER_STDERR_CHARS) {
            capturedStderr = capturedStderr.slice(
              -MAX_CAPTURED_HELPER_STDERR_CHARS,
            );
          }
        }
      }
    };
    const onExit = (code, signal) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      cleanupEndpoint(pipeName);
      reject(
        new Error(
          `Computer Use helper exited before readiness (code ${code}${
            signal ? `/${signal}` : ""
          })${capturedStderr ? `; helper stderr: ${capturedStderr}` : ""}`,
        ),
      );
    };

    child.stdout.on("data", onStdout);
    child.stderr.on("data", onStderr);
    child.on("exit", onExit);
  });
}

function stopHelperChild() {
  const child = state.child;
  if (!child) return;
  state.child = null;
  const pid = state.helperPid;
  state.helperPid = null;
  const capability = state.capability;
  state.capability = null;
  const pipeName = state.pipeName;
  state.pipeName = null;

  try {
    if (isMac() && pid) {
      try {
        process.kill(pid, "SIGTERM");
      } catch {
        /* already gone */
      }
      // Best-effort reaping: escalate to SIGKILL after a short grace period so we
      // never block shutdown (and never busy-wait).
      setTimeout(() => {
        try {
          process.kill(pid, "SIGKILL");
        } catch {
          /* already gone */
        }
      }, 1000);
    } else if (child.pid) {
      try {
        child.kill("SIGKILL");
      } catch {
        /* already gone */
      }
    }
  } catch {
    /* best effort */
  }
  if (capability && pipeName) cleanupEndpoint(pipeName);
}

/**
 * Start the control endpoint. Resolves once the localhost TCP server is bound
 * and returns the host/port/token the Python backend should receive via env.
 *
 * @param {{ binariesDir: string, hideHostWindow?: ()=>void, showHostWindow?: ()=>void }} options
 */
function startComputerUse(options) {
  state = {
    server: null,
    port: null,
    token: null,
    child: null,
    childReady: null,
    capability: null,
    pipeName: null,
    helperPid: null,
    stopping: false,
    focusLeases: new Set(),
    restoreHostAfterFocus: false,
    hideHostWindow: options.hideHostWindow || null,
    showHostWindow: options.showHostWindow || null,
    binariesDir: options.binariesDir,
  };

  return new Promise((resolve, reject) => {
    const server = net.createServer((sock) => {
      if (!sock.remoteAddress || !sock.remoteAddress.startsWith("127.")) {
        sock.destroy();
        return;
      }
      serveControlConnection(sock, state.token);
    });
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const addr = server.address();
      state.server = server;
      state.port = addr.port;
      state.token = randomHex(32);
      console.log(
        `[computer-use] control endpoint listening on 127.0.0.1:${state.port}`,
      );
      resolve();
    });
  });
}

/** Env additions the Python backend reads to reach the control endpoint. */
function backendEnvAdditions() {
  if (!state || state.port === null || !state.token) return {};
  return {
    [CONTROL_HOST_ENV]: "127.0.0.1",
    [CONTROL_PORT_ENV]: String(state.port),
    [CONTROL_TOKEN_ENV]: state.token,
  };
}

function stopComputerUse() {
  if (!state || state.stopping) return;
  state.stopping = true;
  stopHelperChild();
  if (state.server) {
    try {
      state.server.close();
    } catch {
      /* ignore */
    }
    state.server = null;
  }
  state.port = null;
  state.token = null;
}

module.exports = {
  PROTOCOL_VERSION,
  startComputerUse,
  backendEnvAdditions,
  stopComputerUse,
};
