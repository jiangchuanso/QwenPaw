/**
 * QwenPaw Desktop — Electron main process.
 *
 * Replaces the Tauri 2 Rust shell (console/src-tauri). Responsibilities kept
 * functionally identical to the Tauri build so the Python backend stays
 * untouched:
 *   - spawn the PyInstaller backend as a sidecar,
 *   - discover its listen port from stdout (`QWENPAW_BACKEND_READY {"port":N}`),
 *   - expose the same IPC command surface the frontend already invokes,
 *   - graceful shutdown via POST /api/desktop/shutdown,
 *   - tray + minimize-to-tray + close-prompt flow,
 *   - external-link / download / workspace-html passthrough.
 *
 * Electron is chosen over Tauri specifically so the desktop shell runs on
 * glibc 2.31 targets (Kylin V10 SP1 / Ubuntu 20.04): it bundles its own
 * Chromium + Node and needs no system WebKitGTK.
 */
"use strict";

const path = require("path");
const fs = require("fs");
const crypto = require("crypto");
const { spawn } = require("child_process");
const {
  app,
  BrowserWindow,
  Tray,
  Menu,
  ipcMain,
  dialog,
  shell,
  nativeImage,
  session,
} = require("electron");

// Computer Use lifecycle (control endpoint + native helper spawn). Replaces the
// Tauri-side computer_use_runtime so the feature works under Electron too.
const computerUse = require("./computerUse");

// --- Content-Security-Policy (aligned with console/src-tauri/tauri.conf.json) -
// Tauri injects this CSP into the webview. Electron loads the console from the
// local Python backend over HTTP, so we inject the equivalent policy as a
// response header for that origin. Here "'self'" resolves to
// http://127.0.0.1:<port> (the backend). Tauri-only schemes
// (asset:, http://asset.localhost, ipc:, http://ipc.localhost) are dropped
// because IPC travels through the contextBridge (window.electronAPI), not fetch.
const DESKTOP_CSP = [
  "default-src 'self';",
  "connect-src 'self' http://127.0.0.1:* ws://127.0.0.1:*;",
  "script-src 'self';",
  "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com;",
  "font-src 'self' https://fonts.gstatic.com;",
  "img-src 'self' http://127.0.0.1:* blob: data: https:;",
].join(" ");

// The hook must be installed before the first window loads a URL, but
// `session.defaultSession` throws `Session can only be received when app is
// ready` when touched during module evaluation, so registration is deferred to
// the `app.whenReady()` block below (see installCspHook()).
function installCspHook() {
  session.defaultSession.webRequest.onHeadersReceived((details, callback) => {
    const headers = details.responseHeaders || {};
    if (/^https?:\/\/127\.0\.0\.1(:\d+)?\//.test(details.url)) {
      headers["Content-Security-Policy"] = [DESKTOP_CSP];
    }
    callback({ responseHeaders: headers });
  });
}

const isDev = !app.isPackaged;
const RESOURCES = app.isPackaged
  ? process.resourcesPath
  : path.resolve(__dirname, "..", "binaries-staging");
const BINARIES = path.join(RESOURCES, "binaries");

const READY_PREFIX = "QWENPAW_BACKEND_READY";
const SHUTDOWN_PATH = "/api/desktop/shutdown";
const SHUTDOWN_HEADER = "X-Qwenpaw-Desktop-Shutdown-Token";
const CLOSE_ACK_TIMEOUT_MS = 1500;

let mainWindow = null;
let tray = null;
let trayLabels = { show: "Show Window", quit: "Quit" };
let backendChild = null;
let backendPort = null;
let backendError = null;
let shutdownToken = null;
let closeSeq = 0;
let closeAck = 0;

function backendExe() {
  const name =
    process.platform === "win32" ? "qwenpaw-backend.exe" : "qwenpaw-backend";
  return path.join(BINARIES, "qwenpaw-backend", name);
}
function bundledPython() {
  const base = path.join(BINARIES, "python-runtime");
  return process.platform === "win32"
    ? path.join(base, "python.exe")
    : path.join(base, "bin", "python3");
}
function bundledNode() {
  const base = path.join(BINARIES, "node-runtime");
  return process.platform === "win32"
    ? path.join(base, "node.exe")
    : path.join(base, "bin", "node");
}

function buildBackendEnv() {
  const env = { ...process.env };
  env.PYTHONUTF8 = "1";
  env.PYTHONIOENCODING = "utf-8";
  env.PYTHONUNBUFFERED = "1";
  env.PYTHONFAULTHANDLER = "1";
  env.QWENPAW_DESKTOP_APP = "1";
  shutdownToken = crypto.randomUUID();
  env.QWENPAW_DESKTOP_SHUTDOWN_TOKEN = shutdownToken;

  const backendDir = path.dirname(backendExe());
  env.PATH = backendDir + path.delimiter + (env.PATH || "");
  env.QWENPAW_TAURI_RESOURCE_DIR = RESOURCES;

  if (fs.existsSync(bundledPython())) {
    env.QWENPAW_DESKTOP_PY_RUNTIME = bundledPython();
  } else {
    console.warn("[backend] bundled python runtime not found");
  }
  if (fs.existsSync(bundledNode())) {
    env.QWENPAW_DESKTOP_NODE_RUNTIME = path.join(BINARIES, "node-runtime");
  } else {
    console.warn("[backend] bundled node runtime not found");
  }
  if (process.platform === "win32") {
    env.QWENPAW_DESKTOP_MANAGED_PLAYWRIGHT = "1";
  }
  if (process.env.QWENPAW_DESKTOP_DEBUG) {
    env.QWENPAW_DESKTOP_DEBUG = process.env.QWENPAW_DESKTOP_DEBUG;
  }

  // Expose the Computer Use control endpoint to the Python backend (no-op until
  // startComputerUse has bound the localhost TCP server during app startup).
  Object.assign(env, computerUse.backendEnvAdditions());

  return env;
}

function startBackend() {
  backendPort = null;
  backendError = null;
  const exe = backendExe();
  if (!fs.existsSync(exe)) {
    backendError = `backend executable not found at ${exe}`;
    console.error("[backend]", backendError);
    sendEvent("backend-state", {});
    return;
  }
  console.log(`[backend] starting ${exe}`);
  const child = spawn(exe, [], {
    cwd: path.dirname(exe),
    env: buildBackendEnv(),
    stdio: ["ignore", "pipe", "pipe"],
  });
  backendChild = child;

  child.stdout.on("data", (chunk) => {
    const text = chunk.toString();
    for (const raw of text.split("\n")) {
      const line = raw.trim();
      if (!line.startsWith(READY_PREFIX)) continue;
      try {
        const json = JSON.parse(line.slice(READY_PREFIX.length).trim());
        if (json && json.port) {
          backendPort = json.port;
          backendError = null;
          console.log(`[backend] ready on port ${backendPort}`);
          onBackendReady();
        }
      } catch {
        /* ignore malformed lines */
      }
    }
  });
  child.stderr.on("data", (chunk) =>
    console.error("[backend]", chunk.toString()),
  );
  child.on("exit", (code, signal) => {
    if (backendChild !== child) return;
    backendChild = null;
    if (backendPort === null && !signal) {
      backendError = `backend exited (code ${code}) before becoming ready`;
    }
    if (mainWindow && !mainWindow.isDestroyed()) {
      sendEvent("backend-state", {});
    }
  });
}

async function requestGracefulShutdown() {
  if (!backendChild || backendPort === null) {
    if (backendChild) backendChild.kill("SIGKILL");
    backendChild = null;
    return;
  }
  const child = backendChild;
  backendChild = null;
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 3000);
    await fetch(`http://127.0.0.1:${backendPort}${SHUTDOWN_PATH}`, {
      method: "POST",
      headers: { [SHUTDOWN_HEADER]: shutdownToken || "" },
      signal: controller.signal,
    });
    clearTimeout(timer);
  } catch (err) {
    console.warn("[backend] graceful shutdown failed:", err.message);
  }
  await new Promise((r) => setTimeout(r, 1500));
  try {
    child.kill("SIGKILL");
  } catch {
    /* already gone */
  }
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1280,
    height: 800,
    minWidth: 960,
    minHeight: 600,
    show: false,
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      preload: path.join(__dirname, "preload.js"),
    },
  });

  mainWindow.on("close", (event) => {
    event.preventDefault();
    requestClose();
  });

  // Security: confine top-level navigation to the local backend and push any
  // external target to the OS browser. This mirrors Tauri's origin confinement
  // and external-link routing, and prevents the app from opening an in-app
  // window with full web access. SPA route changes use history.pushState and do
  // not trigger will-navigate.
  mainWindow.webContents.on("will-navigate", (event, url) => {
    if (!/^http:\/\/127\.0\.0\.1(:\d+)?\//.test(url)) {
      event.preventDefault();
      if (/^https?:/i.test(url)) shell.openExternal(url);
    }
  });
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:/i.test(url)) shell.openExternal(url);
    return { action: "deny" };
  });

  mainWindow.once("ready-to-show", () => mainWindow.show());
  mainWindow.loadFile(path.join(__dirname, "loading.html"));

  if (backendPort === null) {
    startBackend();
  } else {
    loadConsole();
  }
}

function consoleUrl() {
  return `http://127.0.0.1:${backendPort}/console?desktop=1`;
}

function loadConsole() {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  mainWindow.loadURL(consoleUrl());
}

function onBackendReady() {
  loadConsole();
}

function sendEvent(name, payload) {
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.webContents.send(`event:${name}`, payload);
  }
}

// --- Close / tray flow (mirrors src-tauri/src/tray.rs) -----------------------
function requestClose() {
  closeSeq += 1;
  const seq = closeSeq;
  sendEvent("qwenpaw-close-requested", {});
  setTimeout(() => {
    if (closeSeq !== seq) return; // superseded
    if (closeAck >= seq) return; // frontend owns the flow now
    if (mainWindow && !mainWindow.isDestroyed()) mainWindow.hide();
  }, CLOSE_ACK_TIMEOUT_MS);
}

function exitApp() {
  if (mainWindow && !mainWindow.isDestroyed()) mainWindow.show();
  sendEvent("qwenpaw-shutdown-started", {});
  requestGracefulShutdown().finally(() => {
    computerUse.stopComputerUse();
    app.exit(0);
  });
}

function showMainWindow() {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  mainWindow.show();
  if (mainWindow.isMinimized()) mainWindow.restore();
  mainWindow.focus();
}

function buildTray() {
  const iconPath = path.join(
    __dirname,
    process.platform === "darwin" ? "icon.icns" : "icon.png",
  );
  let image = null;
  if (fs.existsSync(iconPath)) image = nativeImage.createFromPath(iconPath);
  const menu = Menu.buildFromTemplate([
    { label: trayLabels.show, click: () => showMainWindow() },
    { label: trayLabels.quit, click: () => exitApp() },
  ]);
  tray = new Tray(image || nativeImage.createEmpty());
  tray.setToolTip("QwenPaw Desktop");
  tray.setContextMenu(menu);
  tray.on("click", () => showMainWindow());
}

// --- IPC command surface (names match the former Tauri commands) ------------
ipcMain.handle("desktop:backend_port", () => backendPort);
ipcMain.handle("desktop:backend_startup_error", () => backendError);
ipcMain.handle("desktop:backend-state", () => ({
  port: backendPort,
  error: backendError,
}));

ipcMain.handle("desktop:restart_backend", async () => {
  await requestGracefulShutdown();
  startBackend();
  return backendError || null;
});

ipcMain.handle("desktop:open_external_link", (_e, { url }) => {
  if (typeof url === "string" && /^https?:|mailto:|tel:/i.test(url)) {
    shell.openExternal(url);
  }
});

ipcMain.handle("desktop:open_workspace_html", (_e, { url }) => {
  if (typeof url === "string") shell.openExternal(url);
});

ipcMain.handle("desktop:download_backend_file", async (_e, { request }) => {
  const { url, filePath, headers } = request || {};
  if (!url || !filePath) throw new Error("missing url or filePath");
  const res = await fetch(url, { headers: headers || {} });
  if (!res.ok) throw new Error(`download failed: HTTP ${res.status}`);
  const buffer = Buffer.from(await res.arrayBuffer());
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, buffer);
});

ipcMain.handle("desktop:read_workspace_binary_file", async () => {
  // Not used by the current frontend path (console is same-origin with the
  // backend, so the browser fetches directly). Kept for API parity.
  return null;
});

ipcMain.handle("desktop:minimize_to_tray", () => {
  if (mainWindow && !mainWindow.isDestroyed()) mainWindow.hide();
});
ipcMain.handle("desktop:quit_app", () => exitApp());
ipcMain.handle("desktop:set_tray_labels", (_e, { show_window, quit }) => {
  if (show_window) trayLabels.show = show_window;
  if (quit) trayLabels.quit = quit;
  if (tray) buildTray();
});
ipcMain.handle("desktop:ack_close", () => {
  closeAck = closeSeq;
});
ipcMain.handle("desktop:open_devtools", () => {
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.webContents.openDevTools({ mode: "detach" });
  }
});

// Updater commands — Electron uses electron-updater; stubbed for v1 parity.
// TODO(electron): wire to electron-updater with the existing signing infra.
const UPDATER_UNSUPPORTED = async () => {
  console.warn("[updater] electron-updater not wired yet");
  return null;
};
ipcMain.handle("desktop:check_desktop_update", UPDATER_UNSUPPORTED);
ipcMain.handle("desktop:install_desktop_update", UPDATER_UNSUPPORTED);
ipcMain.handle("desktop:download_desktop_update", UPDATER_UNSUPPORTED);
ipcMain.handle("desktop:install_downloaded_update", UPDATER_UNSUPPORTED);
ipcMain.handle("desktop:check_cached_update", UPDATER_UNSUPPORTED);

ipcMain.handle("dialog:save", (_e, defaultPath) =>
  dialog.showSaveDialog(mainWindow, { defaultPath }),
);
ipcMain.handle("dialog:open", (_e, options) =>
  dialog.showOpenDialog(mainWindow, options || {}),
);

// --- Lifecycle ---------------------------------------------------------------
app.whenReady().then(async () => {
  // Install the CSP header hook first: it must be in place before the window
  // loads the console URL from the Python backend.
  installCspHook();

  // Bring up the Computer Use control endpoint before the backend (and its env)
  // is created, so the injected control host/port/token are present.
  try {
    await computerUse.startComputerUse({
      binariesDir: BINARIES,
      hideHostWindow: () => {
        if (mainWindow && !mainWindow.isDestroyed()) mainWindow.hide();
      },
      showHostWindow: () => {
        if (mainWindow && !mainWindow.isDestroyed()) mainWindow.show();
      },
    });
  } catch (err) {
    console.warn(
      "[computer-use] failed to start control endpoint:",
      err.message,
    );
  }

  createWindow();
  buildTray();
  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
    else showMainWindow();
  });
});

app.on("window-all-closed", (event) => {
  // Keep running in the tray like the Tauri build.
  event.preventDefault();
});

app.on("before-quit", (event) => {
  event.preventDefault();
  exitApp();
});
