// Tray POPOVER window — the styled, design-matched panel that drops down
// under the menu-bar icon on a LEFT-click. Replaces the plain native context
// menu as the primary surface (the native menu stays as a RIGHT-click
// fallback; see tray.ts + the wiring in main.ts).
//
// Why a frameless BrowserWindow and not a native Menu? The design (Claude
// artboards/TrayMenu.jsx) wants a custom layout — a status pill, a big action
// button, token-driven colors, a privacy footer — none of which a native
// `Menu` can render. So we lazily create a small, frameless, transparent,
// always-on-top window that loads the SAME renderer bundle with a `#tray`
// URL hash. src/main.ts forks on that hash and bootstraps TrayPopoverComponent
// instead of AppComponent — one bundle, one index.html, the hash picks the
// surface.
//
// Electron notes (the renderer dev is newer to these):
//   - `frame:false, transparent:true` give us a borderless panel so the
//     component can draw its own rounded card + shadow with the design tokens.
//   - `alwaysOnTop + skipTaskbar + show:false` make it behave like a popover,
//     not a regular app window: it floats above, never shows in the Dock/
//     app-switcher, and starts hidden.
//   - `type: 'panel'` (macOS) lets the window sit above full-screen-ish UI and
//     not steal the menu-bar focus the way a normal window would.
//   - It hides itself on `blur` (click-away) and after any action — the way a
//     real menu-bar popover dismisses.
//   - Position is computed from `tray.getBounds()` (where the icon is) and the
//     work area of the display under the icon, so it lands centered beneath the
//     icon and clamped on-screen.

import { app, BrowserWindow, screen, nativeTheme, Rectangle } from 'electron';
import * as path from 'node:path';
import type { TrayState } from './tray';

/** Fixed popover width (matches the design's 280px card) and a height tall
 *  enough for the v1 layout (status header + action + 3 menu rows + privacy
 *  footer). The window is fixed-size; the component never needs to grow. */
const POPOVER_WIDTH = 280;
const POPOVER_HEIGHT = 268;

/** Gap (px) between the bottom of the menu bar and the top of the popover, so
 *  the card doesn't butt right up against the menu bar. */
const MENUBAR_GAP = 4;

const DEV_URL = 'http://localhost:4200';

/**
 * Owns the single, lazily-created popover BrowserWindow. The window is built
 * on first `toggle()` and then reused (hidden, not destroyed) so subsequent
 * opens are instant. `pushState` forwards the renderer's state snapshot into
 * the popover renderer over IPC.
 */
export class TrayPopover {
  private win: BrowserWindow | null = null;
  /** Last state pushed from the main window's renderer. Cached so a freshly
   *  (re)created popover window can be seeded the moment it finishes loading,
   *  rather than rendering an empty/idle frame until the next state push. */
  private lastState: TrayState = {
    capturing: false,
    ready: false,
    connected: false,
  };

  /**
   * Build the window on demand. We don't create it at boot because the user
   * may never click the icon, and a hidden frameless window still costs a
   * renderer process. `webPreferences` mirror the main window's hardened
   * posture (contextIsolation + sandbox + no nodeIntegration) — the popover is
   * pure local UI fed by the minimal `harkTray` bridge.
   */
  private ensureWindow(): BrowserWindow {
    if (this.win && !this.win.isDestroyed()) return this.win;

    const win = new BrowserWindow({
      width: POPOVER_WIDTH,
      height: POPOVER_HEIGHT,
      show: false,
      frame: false,
      transparent: true,
      resizable: false,
      movable: false,
      minimizable: false,
      maximizable: false,
      fullscreenable: false,
      alwaysOnTop: true,
      skipTaskbar: true,
      hasShadow: false, // the component draws its own --shadow-modal
      // macOS panel: floats above, doesn't take over as the key app window.
      type: 'panel',
      backgroundColor: '#00000000',
      webPreferences: {
        preload: path.join(__dirname, 'tray-preload.js'),
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: true,
        // Keep it responsive while it's the focused popover; it's tiny.
        backgroundThrottling: false,
        webSecurity: true,
        devTools:
          !app.isPackaged || process.env['HARK_DEVTOOLS'] === '1',
      },
    });

    // Float above normal windows AND full-screen spaces, like a real popover.
    win.setAlwaysOnTop(true, 'pop-up-menu');
    win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });

    // Dismiss on click-away — the canonical menu-bar-popover behavior.
    win.on('blur', () => {
      if (this.win && !this.win.isDestroyed()) this.win.hide();
    });

    win.on('closed', () => {
      this.win = null;
    });

    // Seed the freshly-loaded renderer with the current state so it paints the
    // right pill/button immediately instead of a flash of idle.
    win.webContents.on('did-finish-load', () => {
      this.pushState(this.lastState);
    });

    // Load the SAME renderer as the main window, but with the `#tray` hash so
    // src/main.ts bootstraps TrayPopoverComponent. Mirror main.ts's useDist
    // logic exactly: dev serves from ng (:4200), prod loads the built file.
    const useDist = app.isPackaged || process.env['HARK_USE_DIST'] === '1';
    if (useDist) {
      const indexHtml = path.join(
        __dirname,
        '..',
        'renderer',
        'browser',
        'index.html',
      );
      void win.loadFile(indexHtml, { hash: 'tray' });
    } else {
      void win.loadURL(`${DEV_URL}/#tray`);
    }

    this.win = win;
    return win;
  }

  /**
   * Toggle the popover for a tray LEFT-click: if it's already visible, hide it
   * (a second click on the icon closes it); otherwise position it under the
   * icon and show it. `trayBounds` comes from `tray.getBounds()`.
   */
  toggle(trayBounds: Rectangle): void {
    if (this.win && !this.win.isDestroyed() && this.win.isVisible()) {
      this.win.hide();
      return;
    }
    this.show(trayBounds);
  }

  /** Position under the tray icon and show + focus the popover. */
  private show(trayBounds: Rectangle): void {
    const win = this.ensureWindow();
    const { x, y } = this.computePosition(trayBounds);
    win.setPosition(x, y, false);
    // Re-seed before showing so the first painted frame is correct.
    this.pushState(this.lastState);
    win.show();
    win.focus();
  }

  /** Hide the popover (called after an action fires, and on blur). */
  hide(): void {
    if (this.win && !this.win.isDestroyed()) this.win.hide();
  }

  /**
   * Forward a state snapshot to the popover renderer. Resolves the user's
   * effective light/dark theme from `nativeTheme` so the popover paints with
   * the SAME tokens as the main window. No-op (but cached) if the window isn't
   * built yet — `did-finish-load` re-seeds from `lastState`.
   */
  pushState(state: TrayState): void {
    this.lastState = state;
    if (!this.win || this.win.isDestroyed()) return;
    if (this.win.webContents.isLoading()) return;
    this.win.webContents.send('hark:tray:state', {
      capturing: state.capturing,
      ready: state.ready,
      connected: state.connected,
      // nativeTheme.shouldUseDarkColors honors the user's macOS appearance AND
      // any app-level override; matches index.html's dark default.
      theme: nativeTheme.shouldUseDarkColors ? 'dark' : 'light',
    });
  }

  /**
   * Compute the popover's top-left so it sits centered horizontally under the
   * tray icon and just below the menu bar, clamped to the work area of the
   * display the icon is on (so it never spills off a small/secondary display).
   */
  private computePosition(trayBounds: Rectangle): {
    x: number;
    y: number;
  } {
    // The display the icon lives on (multi-monitor: the menu bar can be on a
    // secondary display).
    const iconCenter = {
      x: Math.round(trayBounds.x + trayBounds.width / 2),
      y: Math.round(trayBounds.y + trayBounds.height / 2),
    };
    const display = screen.getDisplayNearestPoint(iconCenter);
    const wa = display.workArea;

    // Center the card under the icon …
    let x = Math.round(iconCenter.x - POPOVER_WIDTH / 2);
    // … then clamp so it stays fully within the work area horizontally.
    const maxX = wa.x + wa.width - POPOVER_WIDTH;
    if (x > maxX) x = maxX;
    if (x < wa.x) x = wa.x;

    // The work area starts BELOW the menu bar, so wa.y is the right top edge;
    // a small gap keeps the card off the bar. Fall back to just under the
    // tray icon if for some reason the work area is above it.
    const y = Math.max(wa.y, trayBounds.y + trayBounds.height) + MENUBAR_GAP;

    return { x, y };
  }

  /** Tear down the popover window (on quit). */
  destroy(): void {
    if (this.win && !this.win.isDestroyed()) this.win.destroy();
    this.win = null;
  }
}
