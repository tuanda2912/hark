// Electron main process entry. Spawns harkd, opens the renderer
// window, mediates the engine-port lookup over IPC.
//
// Lifecycle:
//   ready  → spawn harkd, then open window
//   window → loads ng serve URL (dev) or dist/renderer/index.html (prod)
//   quit   → SIGTERM harkd, wait up to 5 s, SIGKILL if necessary

import { app, BrowserWindow, ipcMain, shell, systemPreferences, screen, Rectangle } from 'electron';
import * as path from 'node:path';
import * as os from 'node:os';
import * as fs from 'node:fs';
import { spawnHarkd, HarkdHandle } from './harkd-spawn';
import { HarkTray, TrayState } from './tray';
import { loadPrefs, savePrefs, getPrefsPath, Prefs } from './prefs';

// The user's vault lives OUTSIDE the repo and the app-support dir. Per
// CLAUDE.md it is the only place transcripts/notes are written, so the
// "Reveal in Finder" affordance and the Settings "Vault" section point
// here. Constructed from the home dir so it's correct on any machine.
const VAULT_DIR = path.join(os.homedir(), 'Documents', 'vault', 'hark');

/**
 * Ensure the vault directory exists on disk. CLAUDE.md hard rule #4 forbids
 * auto-DELETING or auto-REWRITING vault files — creating the empty home
 * directory is neither and is expected: it's the product's home, and
 * `shell.openPath` simply no-ops on a missing path (which reads to the user
 * as a dead "Reveal in Finder" button). `recursive: true` is idempotent, so
 * this is safe to call on every boot and again before each reveal. Never
 * throws — a failure here must not crash boot or the reveal action.
 */
function ensureVaultDir(): void {
  try {
    fs.mkdirSync(VAULT_DIR, { recursive: true });
  } catch (err) {
    // eslint-disable-next-line no-console
    console.error('[hark] failed to create vault dir:', VAULT_DIR, err);
  }
}

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

// ─── Window sizing ────────────────────────────────────────────────────
// Default size comfortably fits the 3-column MainWindow design
// (Attendees 240 ∣ Transcript 1fr ∣ Ask 320), so the transcript isn't
// cramped at first launch. The min stays well below the responsive
// breakpoints (right panel drops ≤960, left ≤760) so the window still
// shrinks gracefully — we never pin a min so high the user can't make it
// small. Persisted user bounds (prefs.window) override the default size
// once the window has been resized/moved; see resolveInitialBounds().
const DEFAULT_WIDTH = 1280;
const DEFAULT_HEIGHT = 820;
const MIN_WIDTH = 900;
const MIN_HEIGHT = 600;

// How long to wait after the last resize/move event before persisting the
// new bounds. Coalesces the burst of events a drag-resize fires into a
// single disk write.
const BOUNDS_SAVE_DEBOUNCE_MS = 400;

/**
 * Decide where to open the window. If prefs hold a saved rect AND it is
 * still usable on the *current* display layout, reuse it; otherwise fall
 * back to the default size, centered (left undefined → Electron centers).
 *
 * Display validation matters: bounds are saved against whatever monitors
 * were attached at the time. If an external display is later unplugged, a
 * literal restore could open the window entirely off-screen (no titlebar to
 * grab, effectively lost). So we require the saved rect to *intersect* some
 * connected display's work area before trusting it.
 */
function resolveInitialBounds(): {
  width: number;
  height: number;
  x?: number;
  y?: number;
} {
  const fallback = { width: DEFAULT_WIDTH, height: DEFAULT_HEIGHT };
  const saved = loadPrefs().window;
  if (!saved) return fallback;

  // Clamp size to the min so a corrupt/tiny saved size can't open a window
  // smaller than the floor (Electron would enforce minWidth/Height anyway,
  // but clamping here keeps what we report consistent).
  const width = Math.max(saved.width, MIN_WIDTH);
  const height = Math.max(saved.height, MIN_HEIGHT);

  // No saved position → use saved size but let the OS center it.
  if (typeof saved.x !== 'number' || typeof saved.y !== 'number') {
    return { width, height };
  }

  const rect: Rectangle = { x: saved.x, y: saved.y, width, height };
  if (isRectOnSomeDisplay(rect)) {
    return rect;
  }
  // Saved position is off every connected display (monitor unplugged /
  // resolution change) → drop the position, keep the size, recenter.
  return { width, height };
}

/** True if `rect` overlaps any connected display's work area by a usable
 *  margin — enough of the window (and crucially its draggable titlebar) is
 *  reachable. We require a real intersection, not just a touching edge. */
function isRectOnSomeDisplay(rect: Rectangle): boolean {
  // Minimum visible overlap (px) on each axis for the window to count as
  // reachable — a sliver peeking onto a display isn't good enough.
  const MIN_VISIBLE = 64;
  return screen.getAllDisplays().some((display) => {
    const wa = display.workArea;
    const overlapX =
      Math.min(rect.x + rect.width, wa.x + wa.width) - Math.max(rect.x, wa.x);
    const overlapY =
      Math.min(rect.y + rect.height, wa.y + wa.height) - Math.max(rect.y, wa.y);
    return overlapX >= MIN_VISIBLE && overlapY >= MIN_VISIBLE;
  });
}

// Pending debounce timer for bounds persistence. Cleared/reset on each
// resize/move; flushed immediately on close so the final position sticks.
let boundsSaveTimer: ReturnType<typeof setTimeout> | null = null;

/**
 * Persist the window's current NORMAL bounds. Skipped while maximized or
 * fullscreen so we never trap the user by reopening into a maximized rect
 * that the OS treats as the new "normal" size — `getBounds()` in those
 * states returns the whole-screen rect, which would then become the literal
 * restore size. By only saving when the window is in its normal state we
 * always remember the last *floating* size/position; entering maximize
 * simply leaves the previously-saved normal bounds in place.
 *
 * Goes through savePrefs (merge semantics) so writing `window` never
 * clobbers `audio` / `hasCompletedOnboarding`.
 */
function persistWindowBounds(win: BrowserWindow): void {
  if (win.isDestroyed()) return;
  if (win.isMaximized() || win.isFullScreen() || win.isMinimized()) return;
  const b = win.getBounds();
  savePrefs({ window: { width: b.width, height: b.height, x: b.x, y: b.y } });
}

/** Debounced bounds save — coalesces the event burst from a drag-resize. */
function scheduleBoundsSave(win: BrowserWindow): void {
  if (boundsSaveTimer) clearTimeout(boundsSaveTimer);
  boundsSaveTimer = setTimeout(() => {
    boundsSaveTimer = null;
    persistWindowBounds(win);
  }, BOUNDS_SAVE_DEBOUNCE_MS);
}

/** Flush any pending debounced save immediately (window closing / quitting). */
function flushBoundsSave(win: BrowserWindow): void {
  if (boundsSaveTimer) {
    clearTimeout(boundsSaveTimer);
    boundsSaveTimer = null;
  }
  persistWindowBounds(win);
}

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
  // Reopen at the user's last bounds if they're still valid on the current
  // display layout; otherwise the roomier default size, centered.
  const initial = resolveInitialBounds();
  const win = new BrowserWindow({
    width: initial.width,
    height: initial.height,
    // x/y omitted (undefined) → Electron centers the window on the primary
    // display, which is what we want when there's no saved position.
    x: initial.x,
    y: initial.y,
    minWidth: MIN_WIDTH,
    minHeight: MIN_HEIGHT,
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

  // Remember the window's size + position. Resize/move fire in bursts during
  // a drag, so the save is debounced; the final state is flushed on close /
  // quit. persistWindowBounds() skips maximized/fullscreen so we only ever
  // store the normal floating bounds.
  win.on('resize', () => scheduleBoundsSave(win));
  win.on('move', () => scheduleBoundsSave(win));

  // Hide-on-close, don't destroy: the tray is the app's persistent home, so
  // the red traffic-light / ⌘W must just tuck the window away. We only let
  // the window actually close during a real quit (isQuitting), at which
  // point the renderer + WebSocket tear down with it.
  win.on('close', (ev) => {
    // Capture the final bounds before the window goes away (real quit) or is
    // hidden (normal close) — either way this is our last chance to persist
    // the position the user left it at.
    flushBoundsSave(win);
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
  // Make the vault's home directory exist before anything tries to open it.
  ensureVaultDir();
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

// ─── Preferences IPC ──────────────────────────────────────────────────
// The prefs module owns disk I/O + validation; main only mediates the IPC.
// load is a `handle` (request/response — the renderer awaits the value);
// save is a fire-and-forget `on` (no reply needed). The save payload
// crosses the contextBridge as untrusted structured-clone data, so
// savePrefs() re-validates it (whitelisted keys only) before writing —
// the renderer can never coerce a write to an arbitrary path or shape.
ipcMain.handle('hark:load-prefs', (): { prefs: Prefs; vaultPath: string } => {
  return { prefs: loadPrefs(), vaultPath: VAULT_DIR };
});

ipcMain.on('hark:save-prefs', (_ev, raw: unknown) => {
  savePrefs(raw);
});

// Open the vault folder in Finder. The path is fixed (VAULT_DIR) — the
// renderer cannot ask main to reveal an arbitrary directory. We re-ensure the
// dir exists first: openPath no-ops on a missing path (the button would read
// as "does nothing"), and boot-time creation may have been skipped/failed.
ipcMain.on('hark:reveal-vault', () => {
  ensureVaultDir();
  void shell.openPath(VAULT_DIR).then((err) => {
    // openPath resolves to a non-empty string ONLY on failure.
    if (err) {
      // eslint-disable-next-line no-console
      console.error('[hark] failed to reveal vault:', VAULT_DIR, err);
    }
  });
});

// ─── Microphone permission IPC (onboarding) ───────────────────────────
// macOS gates Microphone behind TCC. The onboarding Permissions screen
// reads the live status to show a real "Granted / Not yet" badge, and can
// optionally fire the system prompt. System-audio capture uses Core Audio
// Process Taps (kTCCServiceAudioCapture) which Electron exposes NO API for
// and which macOS only prompts for at first capture (ADR-0011/0012) — so we
// deliberately do NOT expose a "grant" for it; onboarding frames it as
// "macOS will ask when you start your first recording".
ipcMain.handle('hark:get-mic-permission', (): string => {
  try {
    return systemPreferences.getMediaAccessStatus('microphone');
  } catch {
    return 'unknown';
  }
});

ipcMain.handle('hark:ask-mic-permission', async (): Promise<boolean> => {
  try {
    // Already-decided returns immediately; otherwise this shows the OS
    // prompt and resolves once the user picks. Granted/denied both resolve
    // (no throw); a denied user is then steered to System Settings in-copy.
    return await systemPreferences.askForMediaAccess('microphone');
  } catch {
    return false;
  }
});

// eslint-disable-next-line no-console
console.log(`[hark] prefs file: ${getPrefsPath()}`);

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
  // Persist the final bounds now: the window may be hidden (so its `close`
  // event won't fire on quit) or about to be destroyed. Safe to call with a
  // live window; no-ops once destroyed.
  if (mainWindow && !mainWindow.isDestroyed()) {
    flushBoundsSave(mainWindow);
  }
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
