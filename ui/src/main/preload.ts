// Preload script. Runs in a sandboxed context that has access to both
// Node's `require` (limited to electron's exposed bits) and the DOM.
// Anything we want the renderer to see goes through `contextBridge`.
//
// Per ADR-0001's Electron security model: contextIsolation ON,
// nodeIntegration OFF, sandbox ON. Only the explicit `window.hark` API
// surface below crosses the boundary.

import { contextBridge, ipcRenderer } from 'electron';

contextBridge.exposeInMainWorld('hark', {
  /** Returns the port number harkd is listening on. */
  getEnginePort(): Promise<number> {
    return ipcRenderer.invoke('hark:get-engine-port');
  },
});
