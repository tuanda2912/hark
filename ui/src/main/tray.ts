// Tray — the persistent macOS menu-bar surface for Hark.
//
// Why a separate module: the main process is built with plain `tsc`
// (tsconfig.main.json) and has NO asset-copy step, so a loose .png in
// src/main would never land in dist/main. The two glyphs are therefore
// embedded as base64 PNGs below and rehydrated with
// nativeImage.createFromBuffer at runtime — zero filesystem dependency.
//
// The glyphs are TEMPLATE images (`setTemplateImage(true)`): macOS ignores
// their RGB and recolors them from the alpha channel to match light/dark
// menu bars and selection state. They're Hark's "Heard ripples" family
// (Claude-design deliverables): idle is a HOLLOW source dot + ripples
// (subtle), recording is a FILLED dot + ripples (obvious). 16px logical +
// 32px @2x so Retina stays crisp.
//
// State note: capture/connection state lives in the renderer's
// EngineService. The renderer pushes a snapshot here via
// `window.hark.setTrayState(...)`; this module re-derives the icon and the
// menu-item enablement from that snapshot. There is NO "paused" state —
// pause is an engine stub, so the icon is binary idle/recording.

import {
  Tray,
  Menu,
  nativeImage,
  NativeImage,
  BrowserWindow,
  Rectangle,
  MenuItemConstructorOptions,
} from 'electron';

/**
 * Snapshot of the renderer's capture/connection state, pushed over IPC.
 * Mirrors the `TrayState` shape exposed in preload.ts and consumed by the
 * `window.hark.setTrayState` contract in engine.service.ts.
 */
export interface TrayState {
  capturing: boolean;
  ready: boolean;
  connected: boolean;
}

/** Action strings sent main → renderer. Whitelisted; see preload.ts.
 *  `settings` opens the main window AND tells the renderer to open its
 *  Settings modal (it crosses the same `hark:tray-action` channel as
 *  start/stop). `openMain`/`quit` are handled in MAIN directly and never
 *  forwarded to the renderer. */
export type TrayAction = 'start' | 'stop' | 'settings';

// ─── Embedded template glyphs (base64 PNG) ────────────────────────────
// Hark's "Heard ripples" tray family (Claude-design "Hark Icon Deliverables"
// → tray/*Template.png). Idle: hollow source dot + ripples. Recording:
// filled dot + ripples. Black + alpha; template mode makes macOS recolor
// them. Embedded as base64 (not loose .png) because the main build (plain
// tsc, tsconfig.main.json) has no asset-copy step. To regenerate, re-encode
// the four tray PNGs: `base64 -i tray/trayIdleTemplate.png`, etc.
const ICON_IDLE_1X =
  'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAA6ElEQVR4AbSSMQ4BURCGNxoF0TiCQiVUtFrRuIBSxxnEDQQ30ItGtFo6UTmERuh9f3iy3tuxEtnNfPknOzP/zr7dXPTnlZnBksVGLxA7rA3msZEzucyQMCyDPa0zKMMChtCEICyDEp0TGIMzSdzCNygwsIYrNKADMjmhP20woLEIVZDW0R204QCBib9BniYrgmE1+gY6sBsFnbz0SK6nawvSSFtI3/gGdyo96MIUtqDDrKEyRz7DN3DVDYkOT8MXcn3G+L/BrWdYBi3KK6iA3r2PJsY3Aw3qqRoO3t25WQapg2kGrp6qDwAAAP//mEu/uQAAAAZJREFUAwBRkSIh0tmHEAAAAABJRU5ErkJggg==';
const ICON_IDLE_2X =
  'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAACLUlEQVR4AeyWQS4GQRCFi6UlB7C0YkHClgNwAwmx5Qy4AvYkbsABsCRhY2XpACxted+Yl3Qkprt+EiEm9VR19Uy919Vt5h+PH77+BfyqDuzouJRY1PjLlunAtthKnGpsQQpHs4yAI1GAG3mbBSHEuZTPCDhU5XthXZgRECPXGUIeFKW3JSPgVQQXgv2U4o9C2Bal2y0joKy6rMGusCfQGbqisLOUiIyAMZXf7yHXGSLoyIRG3hK2AShVt4yASZU7EFi1xWjYGULohA9o86FsEbAqilvhqQcxOYTQEaWDLQGICF10ACgctpoAiM5UYl6wEZNjDhGX/QRdcAf6VN3VBEBAlUf92exBrDA8dxXvFx0gsoglBjUMCWDPWS01IDtRAIgVBnPc4w6Qswjib9kCCtVQknKvO2BP7lMMdeBZT90JGKveUACIFQZz3ENs0I2mlfuBIQHcY7JpDY57ECsMz3H4QhfkcvGtAs5VcU1gtXKdEZNjziKY4DCW///XJGuodYDnIVpQwLsfEJOD3KvnfcCYj5JuDd6KXz4DFCrBfs8pAREfJZMrFeTK1Ufr1dIB1+Kdb2KffPZ9RTew7+Xq/UbU1LBlBJSVTAz5rCbKL2AzuZ6LjAA+QBDav6gAxF65hlF+lhlXkRFAm7dUEVJ+/eDJKRUcOH6c4Bk3IyPAhCaFBEJWDRinkRHgfy08hAYi0sR+ICOAwwUpHlLgOiP7jICRSYYe/PsChlbP3BsAAAD//8+iB4wAAAAGSURBVAMAyl9lQdEj4mUAAAAASUVORK5CYII=';
const ICON_REC_1X =
  'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAA4klEQVR4AbSSMQ4BQRSGF0dwBLWWEo1buAEnIBEJ0eMGej0NiShoVQ7hBEJ8f1hZM/OMRGzet/9m5r1/3sxsPvnx+ZvBnMY6TxA7rA6mmZIT3zJD/LAM9qROoAgzaEMFvLAMcmQOoA+pSbCLkEGXoiVcoAEyOaJfdVAjcQhNkF7RDdThAJ6J28GNJCu8YiW6BlsGe7ACaQHV6uqCz0RdSF+4BpoY8RrDDtagwyyjug3kPUIGylChDk/FZwZ0jdl/g6FHWAZVphdQAu29hQbjk4EKtaqKvb2nbpZBtDBmkM5H9Q4AAP//1b1pAQAAAAZJREFUAwBSgCMhxJPQ+AAAAABJRU5ErkJggg==';
const ICON_REC_2X =
  'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAACEklEQVR4AeyWvS5FQRSFh1LrIVRaOj8h3kKlpaUgQUJByxt4CyF+OlqVF9GyvntnJePGPTP7OokQJ7Punr3Pmb3W7Jkz506nH77+BfyqCuxou5RYkP/tFqnAtthKXMm3IHUnaxEBl6IAz7JuFoQQx0I2IuBCmV+ETWFOQIzMoCHkVb3wskQEvIvgTrCdVX9UCMuicHuLCCizrsg5FI4EKkNV1B20kIiIgCmlP86QGTREUJEZeV4SlgEoVG8RAWRjxsBiiAGEUAlv0OZN2SpgSSwnGWuyNIRQEfosCUAEPhUA9DvRIuBMGR6E/YwbWWIyCRH3aXhRBVdgGGn4rQlgtrtf5CFGVbiFOCwVwFrEIk4NNQGrHQk28j1XANci6Pe2BCTrQknKc66ALbGxqFXgeuzIlDiURm9TjaaZe2BNwKMePBdGG7HbHGTz0YUc26sAEu7pZ104zViWJSaTeAtSvtiM5fv/lOOdplYBD2a2B3IAVVE3Qe7Zcx7g81FKujgVe9kDyvWpseEgYv1NzgPEytkTa0JrBUjGmW9ihBBj3XlVWfdy9j4ReaYTEQFlIhNDPq8b5RewmVzjUkQAHyAIbd+UAGLPXG4qP8v4VUQEUOYtZYSUfz9YYgolNhx/TrD4zYgIMKFJIYGQWQP8MCIC/GphITQQESb2gIgANhekWEiB80xsIwImJuka+PcFdM2eex8AAAD//2UUjDQAAAAGSURBVAMAuoxaQW0N46wAAAAASUVORK5CYII=';

function decode(b64: string): Buffer {
  return Buffer.from(b64, 'base64');
}

/** Build a 16px template image with its 32px @2x representation attached. */
function makeTemplateImage(b1x: string, b2x: string): NativeImage {
  const img = nativeImage.createFromBuffer(decode(b1x), { scaleFactor: 1 });
  img.addRepresentation({
    scaleFactor: 2,
    buffer: decode(b2x),
  });
  img.setTemplateImage(true);
  return img;
}

/**
 * Owns the single Tray instance and the menu it presents. Construct once,
 * after `app.whenReady()`. `onAction` is invoked for Start/Stop (forwarded
 * to the renderer); `onToggleWindow` and `onQuit` are handled in main.
 */
export class HarkTray {
  private readonly tray: Tray;
  private readonly idleIcon: NativeImage;
  private readonly recIcon: NativeImage;
  private state: TrayState = { capturing: false, ready: false, connected: false };

  constructor(opts: {
    getWindow(): BrowserWindow | null;
    onAction(action: TrayAction): void;
    onToggleWindow(): void;
    onQuit(): void;
    /** Tray icon LEFT-clicked — toggle the styled popover under the icon.
     *  `bounds` is the icon's screen rect (for positioning). */
    onLeftClick(bounds: Rectangle): void;
  }) {
    this.idleIcon = makeTemplateImage(ICON_IDLE_1X, ICON_IDLE_2X);
    this.recIcon = makeTemplateImage(ICON_REC_1X, ICON_REC_2X);

    this.tray = new Tray(this.idleIcon);
    this.tray.setToolTip('Hark');

    this.onAction = opts.onAction;
    this.onToggleWindow = opts.onToggleWindow;
    this.onQuit = opts.onQuit;
    this.getWindow = opts.getWindow;
    this.onLeftClick = opts.onLeftClick;

    // LEFT-click → the styled popover (the primary surface). We deliberately
    // DON'T call tray.setContextMenu(): on macOS that makes a left-click pop
    // the native menu too, which would fight the popover. Instead we handle
    // 'click' (left) ourselves and pop the native menu only on 'right-click'
    // (the fallback). `bounds` is the icon's screen rect for positioning.
    this.tray.on('click', (_ev, bounds) => this.onLeftClick(bounds));
    // RIGHT-click → the native context menu (fallback). popUpContextMenu shows
    // the current (state-rebuilt) menu at the icon without making it the
    // left-click action.
    this.tray.on('right-click', () => {
      this.tray.popUpContextMenu(this.menu);
    });

    // Build the menu once so `right-click` has something to show; rebuilt on
    // every state push so its enablement + Show/Hide label stay honest.
    this.rebuildMenu();
  }

  private readonly onAction: (action: TrayAction) => void;
  private readonly onToggleWindow: () => void;
  private readonly onQuit: () => void;
  private readonly getWindow: () => BrowserWindow | null;
  private readonly onLeftClick: (bounds: Rectangle) => void;
  /** The current native fallback menu — rebuilt on each state push, shown on
   *  right-click. Held so right-click doesn't have to rebuild synchronously. */
  private menu: Menu = Menu.buildFromTemplate([]);

  /** Push a fresh state snapshot from the renderer; updates icon + menu. */
  setState(next: TrayState): void {
    this.state = next;
    this.tray.setImage(next.capturing ? this.recIcon : this.idleIcon);
    // Belt-and-suspenders for non-template fallbacks: title stays empty so
    // the bar isn't cluttered, but flips to a dot if the image ever fails
    // to render. Harmless when the template image is showing.
    this.tray.setToolTip(next.capturing ? 'Hark — recording' : 'Hark');
    this.rebuildMenu();
  }

  /** The icon's current screen rect — used by main to position the popover. */
  getBounds(): Rectangle {
    return this.tray.getBounds();
  }

  /** Rebuild + cache the native fallback menu from the current state. NOT
   *  installed via setContextMenu (that would hijack the left-click); it's
   *  shown explicitly on right-click via popUpContextMenu. */
  private rebuildMenu(): void {
    this.menu = this.buildMenu();
  }

  private buildMenu(): Menu {
    const win = this.getWindow();
    const visible = !!win && win.isVisible();
    const { capturing, ready, connected } = this.state;

    const template: MenuItemConstructorOptions[] = [
      {
        label: visible ? 'Hide Hark' : 'Show Hark',
        click: () => this.onToggleWindow(),
      },
      { type: 'separator' },
      {
        label: 'Start Capture',
        enabled: connected && ready && !capturing,
        click: () => this.onAction('start'),
      },
      {
        label: 'Stop Capture',
        enabled: capturing,
        click: () => this.onAction('stop'),
      },
      { type: 'separator' },
      {
        label: 'Quit Hark',
        accelerator: 'Command+Q',
        click: () => this.onQuit(),
      },
    ];

    return Menu.buildFromTemplate(template);
  }

  /** Tear down the tray (called on quit so the icon disappears promptly). */
  destroy(): void {
    this.tray.destroy();
  }
}
