// Electron main process entry. Spawns harkd, opens the renderer
// window, mediates the engine-port lookup over IPC.
//
// Lifecycle:
//   ready  → spawn harkd, then open window
//   window → loads ng serve URL (dev) or dist/renderer/index.html (prod)
//   quit   → SIGTERM harkd, wait up to 5 s, SIGKILL if necessary

import { app, BrowserWindow, ipcMain, shell } from 'electron';
import * as path from 'node:path';
import { spawnHarkd, HarkdHandle } from './harkd-spawn';
import { HarkTray, TrayState } from './tray';

let mainWindow: BrowserWindow | null = null;
let harkd: HarkdHandle | null = null;
let tray: HarkTray | null = null;

// True once the user has chosen to quit (tray "Quit Hark" or ⌘Q). The
// window's `close` handler reads this to decide between hiding (the normal
// red-button / ⌘W close, which keeps the tray alive) and actually being
// destroyed during teardown. Electron has no built-in "is quitting" flag,
// so we maintain our own and set it from every real-quit entry point.
let isQuitting = false;

const DEV_URL = 'http://localhost:4200';

/** Show the window if hidden, hide it if visible — the tray click + the
 *  tray menu "Show/Hide" both route here. */
function toggleWindow(): void {
  const win = mainWindow;
  if (!win) return;
  if (win.isVisible()) {
    win.hide();
  } else {
    win.show();
    win.focus();
  }
}

/** Begin a real quit: flip the flag so the window stops intercepting close,
 *  then let Electron run the normal quit sequence (before-quit tears down
 *  harkd + the tray). */
function quitApp(): void {
  isQuitting = true;
  app.quit();
}

async function createWindow(): Promise<void> {
  const win = new BrowserWindow({
    width: 1100,
    height: 700,
    minWidth: 880,
    minHeight: 560,
    backgroundColor: '#0e1116',
    show: false,
    titleBarStyle: 'hiddenInset',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      // Keep the renderer running at full speed even when hidden to the
      // tray. Default `true` throttles a hidden window's rAF/timers, which
      // would (a) stall WebSocket segment processing and the per-second REC
      // counter while capturing in the background, and (b) starve Angular's
      // `_trayStatePush` effect so the tray never learns capture started —
      // leaving the icon stuck on the idle ring. A live-transcription app
      // must keep working while its window is tucked away.
      backgroundThrottling: false,
      // Hard rule #3: no remote content, no telemetry.
      webSecurity: true,
      // DevTools available in dev; safely off when packaged. Toggle on
      // packaged builds with HARK_DEVTOOLS=1 if needed for diagnosis.
      devTools: !app.isPackaged || process.env['HARK_DEVTOOLS'] === '1',
    },
  });

  win.once('ready-to-show', () => win.show());

  // Open all <a target="_blank"> in the system browser, not a new
  // Electron window. Combined with CSP `default-src 'self'`, this keeps
  // the renderer process from ever loading remote content.
  win.webContents.setWindowOpenHandler(({ url }) => {
    void shell.openExternal(url);
    return { action: 'deny' };
  });

  // Dev (ng serve on :4200) vs prod (file:// from dist) detection.
  // `HARK_USE_DIST=1 npx electron .` forces the dist path even when not
  // packaged — useful for testing the prod loading path locally without
  // running ng serve in the background.
  const useDist = app.isPackaged || process.env['HARK_USE_DIST'] === '1';
  if (useDist) {
    // Angular 21's @angular/build outputs into dist/renderer/browser/.
    const indexHtml = path.join(__dirname, '..', 'renderer', 'browser', 'index.html');
    await win.loadFile(indexHtml);
  } else {
    await win.loadURL(DEV_URL);
    win.webContents.openDevTools({ mode: 'detach' });
  }

  // Hide-on-close, don't destroy: the tray is the app's persistent home, so
  // the red traffic-light / ⌘W must just tuck the window away. We only let
  // the window actually close during a real quit (isQuitting), at which
  // point the renderer + WebSocket tear down with it.
  win.on('close', (ev) => {
    if (!isQuitting) {
      ev.preventDefault();
      win.hide();
      // Reflect the now-hidden state in the tray menu's Show/Hide label.
      tray?.setState(lastTrayState);
    }
  });

  win.on('closed', () => {
    mainWindow = null;
  });

  // Keep the tray menu's Show/Hide label honest as the window is shown
  // again (e.g. via Dock or tray click) without waiting for a state push.
  win.on('show', () => tray?.setState(lastTrayState));
  win.on('hide', () => tray?.setState(lastTrayState));

  mainWindow = win;
}

// Last state snapshot pushed by the renderer. Cached so window show/hide
// events can rebuild the tray menu without inventing a state (the only
// field that changes off a state-push is the Show/Hide label, which we
// derive from window visibility inside the tray).
let lastTrayState: TrayState = { capturing: false, ready: false, connected: false };

function createTray(): void {
  tray = new HarkTray({
    getWindow: () => mainWindow,
    // Start/Stop live in the renderer (EngineService owns capture). Forward
    // the action; the renderer reuses its current source/language selections.
    onAction: (action) => {
      mainWindow?.webContents.send('hark:tray-action', action);
    },
    onToggleWindow: toggleWindow,
    onQuit: quitApp,
  });
}

async function bootstrap(): Promise<void> {
  try {
    harkd = await spawnHarkd();
  } catch (err) {
    // eslint-disable-next-line no-console
    console.error('[hark] failed to start engine:', err);
    // Open the window anyway with a friendly error state — Phase 4 thin
    // slice surfaces this via EngineService.connection.kind === 'error'.
  }
  await createWindow();
  createTray();
}

ipcMain.handle('hark:get-engine-port', (): number => {
  if (!harkd) {
    throw new Error('engine not started');
  }
  return harkd.port;
});

// Renderer → main: capture/connection state push. The renderer's
// EngineService is the source of truth; the tray is a projection of it.
// We validate the shape defensively (it crosses the contextBridge as a
// plain structured-clone object) before trusting it.
ipcMain.on('hark:tray-state', (_ev, raw: unknown) => {
  if (!isTrayState(raw)) return;
  lastTrayState = raw;
  tray?.setState(raw);
});

function isTrayState(v: unknown): v is TrayState {
  if (typeof v !== 'object' || v === null) return false;
  const o = v as Record<string, unknown>;
  return (
    typeof o['capturing'] === 'boolean' &&
    typeof o['ready'] === 'boolean' &&
    typeof o['connected'] === 'boolean'
  );
}

app.whenReady().then(bootstrap).catch((err) => {
  // eslint-disable-next-line no-console
  console.error('[hark] bootstrap failed:', err);
  app.quit();
});

app.on('window-all-closed', () => {
  // Intentionally a no-op. The window hides (not destroys) on close, so this
  // normally won't fire while the app is alive. Even if it did, the tray is
  // the app's persistent home — quitting only happens via the tray
  // "Quit Hark" item or ⌘Q, both of which route through quitApp()/before-quit.
});

// macOS: clicking the Dock icon (if shown) re-opens / un-hides the window.
app.on('activate', () => {
  if (mainWindow) {
    mainWindow.show();
    mainWindow.focus();
  }
});

app.on('before-quit', async (ev) => {
  // A real quit is underway — make sure the window's close handler stops
  // intercepting (it checks isQuitting) and tear down harkd + the tray.
  isQuitting = true;
  if (harkd) {
    ev.preventDefault();
    const h = harkd;
    harkd = null;
    try {
      await h.stop();
    } catch (err) {
      // eslint-disable-next-line no-console
      console.warn('[hark] error stopping harkd:', err);
    }
    tray?.destroy();
    tray = null;
    app.quit();
    return;
  }
  // No harkd to stop (e.g. spawn failed) — still drop the tray cleanly.
  tray?.destroy();
  tray = null;
});
