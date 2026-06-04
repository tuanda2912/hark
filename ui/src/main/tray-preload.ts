// Preload for the menu-bar TRAY POPOVER window (src/main/tray-popover.ts).
//
// This is a SECOND, deliberately minimal contextBridge surface — it is NOT
// `window.hark` (the main window's broad bridge). The popover is a dumb view:
// it receives a state snapshot and emits a whitelisted action string. It has
// NO access to the engine port, prefs, the vault, the LLM, or anything else.
//
// Security posture (same as preload.ts / ADR-0001): contextIsolation ON,
// nodeIntegration OFF, sandbox ON. The ONLY things crossing the boundary are:
//   main → popover  `hark:tray:state`  — a validated TrayState snapshot
//   popover → main  `hark:tray:action` — a string from a fixed whitelist
//
// The action string is validated HERE (in the trusted preload) before it is
// sent, and validated AGAIN in main before it does anything — so a compromised
// renderer DOM can never coerce main into an arbitrary action.

import { contextBridge, ipcRenderer, IpcRendererEvent } from 'electron';

/** State snapshot pushed main → popover. Mirrors TrayState in main/tray.ts
 *  plus a resolved `theme` so the popover paints with the SAME light/dark
 *  tokens as the main window (no flash, no second prefs read). */
interface TrayPopoverState {
  capturing: boolean;
  ready: boolean;
  connected: boolean;
  theme: 'light' | 'dark';
}

/** Actions the popover can ask main to perform. This WHITELIST is the trust
 *  boundary: only these strings are ever forwarded, regardless of what the
 *  popover DOM tries to send. Mirrors (a superset of) main/tray.ts TrayAction. */
type TrayPopoverAction = 'start' | 'stop' | 'openMain' | 'settings' | 'quit';
const TRAY_POPOVER_ACTIONS: readonly TrayPopoverAction[] = [
  'start',
  'stop',
  'openMain',
  'settings',
  'quit',
];

function isTrayPopoverState(v: unknown): v is TrayPopoverState {
  if (typeof v !== 'object' || v === null) return false;
  const o = v as Record<string, unknown>;
  return (
    typeof o['capturing'] === 'boolean' &&
    typeof o['ready'] === 'boolean' &&
    typeof o['connected'] === 'boolean' &&
    (o['theme'] === 'light' || o['theme'] === 'dark')
  );
}

contextBridge.exposeInMainWorld('harkTray', {
  /** Subscribe to state snapshots from main (icon/menu enablement source of
   *  truth lives in the renderer; main forwards it here). The callback only
   *  ever receives a shape-validated TrayPopoverState. Returns an unsubscribe. */
  onState(cb: (state: TrayPopoverState) => void): () => void {
    const listener = (_ev: IpcRendererEvent, raw: unknown): void => {
      if (isTrayPopoverState(raw)) cb(raw);
    };
    ipcRenderer.on('hark:tray:state', listener);
    return () => ipcRenderer.removeListener('hark:tray:state', listener);
  },

  /** Emit a tray action to main. Validated against the whitelist HERE before
   *  sending; main validates again. Anything off-whitelist is silently
   *  dropped — it never crosses the bridge. Fire-and-forget. */
  action(name: string): void {
    if ((TRAY_POPOVER_ACTIONS as readonly string[]).includes(name)) {
      ipcRenderer.send('hark:tray:action', name);
    }
  },
});
