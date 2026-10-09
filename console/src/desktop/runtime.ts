/**
 * Unified desktop runtime bridge for QwenPaw.
 *
 * The console previously branched on `@tauri-apps/api` directly. We now route
 * every desktop capability (invoke + event subscription + native dialogs)
 * through this module so the same frontend code runs under Tauri OR Electron.
 * The active runtime is detected on import (and re-checked on demand through
 * `isDesktopRuntime()`, for bridges that appear after the bundle loads):
 *   - Electron : `window.electronAPI.invoke` is exposed by the preload script.
 *   - Tauri    : `@tauri-apps/api` reports a Tauri webview (or the injected
 *                `__TAURI_INTERNALS__.invoke` bridge is present).
 *   - Browser  : neither -> pure web fallback (no native desktop features).
 */
import {
  invoke as tauriInvoke,
  isTauri as tauriIsTauri,
} from "@tauri-apps/api/core";
import { listen as tauriListen } from "@tauri-apps/api/event";
import type { UnlistenFn } from "@tauri-apps/api/event";

export type RuntimeKind = "electron" | "tauri" | "browser";

function detectRuntime(): RuntimeKind {
  if (typeof window === "undefined") return "browser";
  const w = window as unknown as {
    electronAPI?: { invoke?: unknown };
    __TAURI_INTERNALS__?: { invoke?: unknown };
  };
  if (w.electronAPI && typeof w.electronAPI.invoke === "function") {
    return "electron";
  }
  if (tauriIsTauri() || w.__TAURI_INTERNALS__?.invoke) {
    return "tauri";
  }
  return "browser";
}

export const runtimeKind = detectRuntime();
export const isElectron = runtimeKind === "electron";
export const isTauri = runtimeKind === "tauri";
export const isBrowser = runtimeKind === "browser";
/** True for any bundled desktop shell (Tauri or Electron). */
export const isDesktop = isElectron || isTauri;

/**
 * Re-detect the active runtime at call time.
 *
 * The module-level flags above are captured on import, which is too early when
 * a shell injects its bridge afterwards (Electron preload racing the bundle, or
 * Tauri's `__TAURI_INTERNALS__` being stubbed by tests). Callers that must react
 * to the live environment should use this instead of `isDesktop`.
 */
export function isDesktopRuntime(): boolean {
  return detectRuntime() !== "browser";
}

type InvokeArgs = Record<string, unknown> | undefined;

/**
 * Send an IPC command to the desktop shell. Routes to Electron or Tauri.
 *
 * Deliberately not `async`: an extra async frame adds microtask hops that delay
 * when callers observe a rejection, and the bridge already returns a promise.
 */
export function invoke<T = unknown>(
  command: string,
  args?: InvokeArgs,
): Promise<T> {
  if (isElectron) {
    return (
      window as unknown as {
        electronAPI: { invoke: (c: string, a: InvokeArgs) => Promise<T> };
      }
    ).electronAPI.invoke(command, args ?? {});
  }
  return tauriInvoke<T>(command, args);
}

/** Subscribe to a desktop-shell event. Returns a synchronous unsubscribe fn. */
export function on<T = unknown>(
  event: string,
  handler: (payload: T) => void,
): () => void {
  if (isElectron) {
    const api = (
      window as unknown as {
        electronAPI: { on: (e: string, h: (p: T) => void) => () => void };
      }
    ).electronAPI;
    return api.on(event, handler);
  }
  let unlisten: UnlistenFn | null = null;
  tauriListen<T>(event, (e) => handler(e.payload)).then((fn) => {
    unlisten = fn;
  });
  return () => {
    if (unlisten) unlisten();
  };
}

/** Native "save as" dialog. Falls back to a browser download when not desktop. */
export async function showSaveDialog(
  defaultPath: string,
): Promise<string | null> {
  if (isElectron) {
    return (
      window as unknown as {
        electronAPI: { showSaveDialog: (p: string) => Promise<string | null> };
      }
    ).electronAPI.showSaveDialog(defaultPath);
  }
  const { save } = await import("@tauri-apps/plugin-dialog");
  return ((await save({ defaultPath })) as string | null) || null;
}

/** Native "open file" dialog. Falls back to a prompt when not desktop. */
export async function showOpenDialog(options?: {
  multiple?: boolean;
  directory?: boolean;
  title?: string;
}): Promise<string[] | null> {
  if (isElectron) {
    return (
      window as unknown as {
        electronAPI: {
          showOpenDialog: (o: object) => Promise<string[] | null>;
        };
      }
    ).electronAPI.showOpenDialog(options ?? {});
  }
  const { open } = await import("@tauri-apps/plugin-dialog");
  return (await open({
    multiple: options?.multiple,
    directory: options?.directory,
    title: options?.title,
  })) as string[] | null;
}
