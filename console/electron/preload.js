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

  // Normalize Electron's { canceled, filePath } / { canceled, filePaths }
  // result into the Tauri dialog plugin's string | null / string[] | null
  // contract the frontend consumes (see console/src/desktop/runtime.ts).
  showSaveDialog: async (defaultPath) => {
    const result = await ipcRenderer.invoke("dialog:save", defaultPath);
    return result && !result.canceled && result.filePath
      ? result.filePath
      : null;
  },

  showOpenDialog: async (options) => {
    const result = await ipcRenderer.invoke("dialog:open", options || {});
    if (!result || result.canceled) return null;
    return result.filePaths && result.filePaths.length > 0
      ? result.filePaths
      : null;
  },
});
