"use strict";

const { contextBridge, ipcRenderer } = require("electron");

/**
 * Exposes a minimal, stable bridge to the renderer. The frontend detects this
 * object (window.electronAPI) to know it is running inside the Electron shell;
 * see console/src/desktop/runtime.ts. Only the command names the frontend
 * already invokes under Tauri are forwarded, so no frontend command strings
 * change.
 */
contextBridge.exposeInMainWorld("electronAPI", {
  invoke: (command, args) => ipcRenderer.invoke(`desktop:${command}`, args),

  on: (event, handler) => {
    const channel = `event:${event}`;
    const listener = (_e, payload) => handler(payload);
    ipcRenderer.on(channel, listener);
    return () => ipcRenderer.removeListener(channel, listener);
  },

  showSaveDialog: (defaultPath) =>
    ipcRenderer.invoke("dialog:save", defaultPath),

  showOpenDialog: (options) => ipcRenderer.invoke("dialog:open", options),
});
