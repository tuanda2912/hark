// Preload script. Runs in a sandboxed context that has access to both
// Node's `require` (limited to electron's exposed bits) and the DOM.
// Anything we want the renderer to see goes through `contextBridge`.
//
// Per ADR-0001's Electron security model: contextIsolation ON,
// nodeIntegration OFF, sandbox ON. Only the explicit `window.hark` API
// surface below crosses the boundary.

import { contextBridge, ipcRenderer, IpcRendererEvent } from 'electron';
import type { Prefs } from './prefs';

/** State snapshot the renderer pushes to the tray. Mirrors TrayState in
 *  main/tray.ts and the Window.hark interface in engine.service.ts. */
interface TrayState {
  capturing: boolean;
  ready: boolean;
  connected: boolean;
}

/** Response from `hark:load-prefs` — the persisted prefs plus the vault
 *  path (so the renderer can show it without a second round-trip). */
interface PrefsResult {
  prefs: Prefs;
  vaultPath: string;
}

/** Tray actions the main process can ask the renderer to perform. The
 *  WHITELIST below is the trust boundary: only these two strings are ever
 *  forwarded to the renderer callback, regardless of what main sends. */
type TrayAction = 'start' | 'stop';
const TRAY_ACTIONS: readonly TrayAction[] = ['start', 'stop'];

contextBridge.exposeInMainWorld('hark', {
  /** Returns the port number harkd is listening on. */
  getEnginePort(): Promise<number> {
    return ipcRenderer.invoke('hark:get-engine-port');
  },

  /** Push the renderer's capture/connection state to the tray (icon +
   *  menu-item enablement). Fire-and-forget; no reply. */
  setTrayState(state: TrayState): void {
    ipcRenderer.send('hark:tray-state', {
      capturing: !!state.capturing,
      ready: !!state.ready,
      connected: !!state.connected,
    });
  },

  /** Subscribe to tray-initiated Start/Stop actions. The callback only ever
   *  receives a whitelisted action string — anything else is dropped here,
   *  in the preload, before it can reach renderer code. */
  onTrayAction(cb: (action: TrayAction) => void): void {
    ipcRenderer.on('hark:tray-action', (_ev: IpcRendererEvent, action: unknown) => {
      if (typeof action === 'string' && (TRAY_ACTIONS as readonly string[]).includes(action)) {
        cb(action as TrayAction);
      }
    });
  },

  /** Load persisted prefs + the vault path. Returns defaults on first run
   *  or a corrupt file (main never throws). */
  loadPrefs(): Promise<PrefsResult> {
    return ipcRenderer.invoke('hark:load-prefs');
  },

  /** Persist prefs (fire-and-forget). We re-shape to ONLY the whitelisted
   *  fields here so nothing extra crosses the bridge; main re-validates
   *  again before writing. */
  savePrefs(prefs: Prefs): void {
    ipcRenderer.send('hark:save-prefs', {
      version: 1,
      audio: {
        mic: !!prefs.audio.mic,
        system: !!prefs.audio.system,
        language:
          typeof prefs.audio.language === 'string' ? prefs.audio.language : null,
      },
      hasCompletedOnboarding: !!prefs.hasCompletedOnboarding,
      // ADR-0027 privacy flags — re-shaped to strict booleans so nothing
      // extra crosses the bridge; main re-validates again before writing.
      privacy: {
        keepAudio: !!prefs.privacy?.keepAudio,
        rememberSpeakers: !!prefs.privacy?.rememberSpeakers,
        syncAudio: !!prefs.privacy?.syncAudio,
        syncSpeakers: !!prefs.privacy?.syncSpeakers,
      },
    });
  },

  /** Open the vault folder in Finder. main holds the fixed path. */
  revealVault(): void {
    ipcRenderer.send('hark:reveal-vault');
  },

  /** Read the current Microphone TCC authorization status from macOS, via
   *  the main process (`systemPreferences.getMediaAccessStatus`). Returns a
   *  status string ('granted' | 'denied' | 'restricted' | 'not-determined'
   *  | 'unknown'); never throws. Used by onboarding to show a real badge. */
  getMicPermission(): Promise<string> {
    return ipcRenderer.invoke('hark:get-mic-permission');
  },

  /** Trigger the macOS Microphone permission prompt (no-op if already
   *  decided). Resolves true if access is granted afterward, false
   *  otherwise. Optional nicety on the onboarding Permissions screen. */
  askMicPermission(): Promise<boolean> {
    return ipcRenderer.invoke('hark:ask-mic-permission');
  },
});
