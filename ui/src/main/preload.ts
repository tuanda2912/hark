// Preload script. Runs in a sandboxed context that has access to both
// Node's `require` (limited to electron's exposed bits) and the DOM.
// Anything we want the renderer to see goes through `contextBridge`.
//
// Per ADR-0001's Electron security model: contextIsolation ON,
// nodeIntegration OFF, sandbox ON. Only the explicit `window.hark` API
// surface below crosses the boundary.

import { contextBridge, ipcRenderer, IpcRendererEvent } from 'electron';

/** State snapshot the renderer pushes to the tray. Mirrors TrayState in
 *  main/tray.ts and the Window.hark interface in engine.service.ts. */
interface TrayState {
  capturing: boolean;
  ready: boolean;
  connected: boolean;
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
});
