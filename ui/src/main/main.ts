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

let mainWindow: BrowserWindow | null = null;
let harkd: HarkdHandle | null = null;

const DEV_URL = 'http://localhost:4200';

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

  win.on('closed', () => {
    mainWindow = null;
  });

  mainWindow = win;
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
}

ipcMain.handle('hark:get-engine-port', (): number => {
  if (!harkd) {
    throw new Error('engine not started');
  }
  return harkd.port;
});

app.whenReady().then(bootstrap).catch((err) => {
  // eslint-disable-next-line no-console
  console.error('[hark] bootstrap failed:', err);
  app.quit();
});

app.on('window-all-closed', () => {
  // macOS convention is to keep the app alive when all windows close;
  // for v1 we exit on close to match a typical single-window utility.
  app.quit();
});

app.on('before-quit', async (ev) => {
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
    app.quit();
  }
});
