// TrayPopoverComponent — the styled menu-bar popover (the Claude-design
// artboards/TrayMenu.jsx, v1 cut). Bootstrapped INSTEAD of AppComponent when
// the renderer loads with the `#tray` URL hash (see src/main.ts). It lives in
// a separate, frameless BrowserWindow that main positions under the tray icon
// (see main/tray-popover.ts).
//
// This is a DUMB VIEW. It does NOT open a WebSocket to harkd and does NOT
// import EngineService — that would be a SECOND engine connection. It receives
// its entire state from the minimal `window.harkTray` bridge (main/tray-
// preload.ts) and emits whitelisted action strings back. State flows:
//
//   renderer (main window EngineService) → main → `harkTray.onState` → here
//   here → `harkTray.action(name)` → main → dispatch (start/stop/openMain/
//                                                      settings/quit)
//
// Design fidelity: token vars only (--bg-2, --border, --accent, --status-*,
// --text*, --font-*, --shadow-modal, the .rec-dot pulse) — NO hardcoded hex.
// The CSP is the same strict `default-src 'self'` (one bundle, one index.html);
// all styles are inline component styles or token vars, no remote anything.

import {
  ChangeDetectionStrategy,
  Component,
  OnDestroy,
  OnInit,
  computed,
  signal,
} from '@angular/core';

/** State snapshot pushed from main over the `harkTray` bridge. Mirrors
 *  TrayPopoverState in main/tray-preload.ts. */
interface TrayPopoverState {
  capturing: boolean;
  ready: boolean;
  connected: boolean;
  theme: 'light' | 'dark';
}

/** Actions this popover can emit. Mirrors the whitelist in tray-preload.ts +
 *  main's `hark:tray:action` dispatch. */
type TrayPopoverAction = 'start' | 'stop' | 'openMain' | 'settings' | 'quit';

declare global {
  interface Window {
    /** Minimal tray-popover bridge (main/tray-preload.ts). Present ONLY in the
     *  popover window; undefined elsewhere, so always guard. */
    harkTray?: {
      onState(cb: (state: TrayPopoverState) => void): () => void;
      action(name: TrayPopoverAction): void;
    };
  }
}

@Component({
  selector: 'hark-tray-popover',
  standalone: true,
  changeDetection: ChangeDetectionStrategy.OnPush,
  styles: [
    `
      /* The transparent BrowserWindow shows whatever this paints. The host is
         the full window; the .card is the rounded panel with its own shadow
         (the design's --shadow-modal), leaving a small transparent margin so
         the shadow has room to fall. */
      :host {
        display: block;
        width: 100vw;
        height: 100vh;
        background: transparent;
        font-family: var(--font-ui);
        -webkit-font-smoothing: antialiased;
        letter-spacing: -0.005em;
        /* Don't let a stray drag select text or rubber-band the window. */
        user-select: none;
        -webkit-user-select: none;
        overflow: hidden;
      }

      .card {
        width: 280px;
        margin: 0 auto;
        background: var(--bg-2);
        border: 1px solid var(--border);
        border-radius: 10px;
        box-shadow: var(--shadow-modal);
        overflow: hidden;
        font-size: 13px;
        color: var(--text);
      }

      /* ── Status header ── */
      .header {
        padding: 12px 14px 10px;
        border-bottom: 1px solid var(--border);
      }
      .header-row {
        display: flex;
        align-items: center;
        justify-content: space-between;
      }
      .status {
        display: flex;
        align-items: center;
        gap: 8px;
      }
      .dot {
        width: 8px;
        height: 8px;
        border-radius: 50%;
        flex-shrink: 0;
      }
      .dot.idle {
        background: var(--text-3);
      }
      /* .rec-dot (pulsing red) is defined globally in tokens.css. */
      .status-label {
        font-family: var(--font-mono);
        font-size: 11px;
        letter-spacing: 0.06em;
        font-weight: 600;
      }
      .status-label.idle {
        color: var(--text-3);
      }
      .status-label.recording {
        color: var(--status-recording);
      }
      .header-hint {
        margin-top: 6px;
        font-size: 11.5px;
        color: var(--text-3);
      }

      /* ── Primary action ── */
      .action-wrap {
        padding: 10px 12px;
      }
      .action {
        width: 100%;
        padding: 10px 12px;
        border-radius: 6px;
        font-size: 13px;
        font-weight: 600;
        cursor: pointer;
        display: flex;
        align-items: center;
        gap: 8px;
        justify-content: center;
        font-family: var(--font-ui);
        transition: filter 120ms ease, background 120ms ease;
      }
      .action-start {
        border: 1px solid var(--accent);
        background: var(--accent);
        color: var(--bg);
      }
      [data-theme='dark'] .action-start {
        color: #0e1116;
      }
      .action-start:hover {
        filter: brightness(1.06);
      }
      .action-start:disabled {
        opacity: 0.5;
        cursor: default;
        filter: none;
      }
      .action-stop {
        border: 1px solid
          color-mix(in oklab, var(--status-recording) 50%, transparent);
        background: color-mix(in oklab, var(--status-recording) 14%, transparent);
        color: var(--status-recording);
      }
      .action-stop:hover {
        background: color-mix(in oklab, var(--status-recording) 22%, transparent);
      }

      /* ── Menu rows ── */
      .divider {
        height: 1px;
        background: var(--border);
      }
      .rows {
        padding: 8px 6px;
      }
      .row {
        width: 100%;
        padding: 6px 8px;
        border-radius: 5px;
        background: transparent;
        border: none;
        cursor: pointer;
        display: flex;
        align-items: center;
        gap: 10px;
        font-size: 12.5px;
        font-family: var(--font-ui);
        color: var(--text);
        transition: background 120ms ease;
      }
      .row:hover {
        background: var(--highlight);
      }
      .row-icon {
        width: 14px;
        display: inline-flex;
        color: var(--text-2);
      }
      .row-label {
        flex: 1;
        text-align: left;
      }
      .row-hotkey {
        font-family: var(--font-mono);
        font-size: 10.5px;
        color: var(--text-3);
      }

      /* ── Privacy footer ── */
      .footer {
        padding: 8px 14px;
        border-top: 1px solid var(--border);
        background: var(--bg);
        font-family: var(--font-mono);
        font-size: 10px;
        color: var(--text-3);
        display: flex;
        align-items: center;
        gap: 6px;
        letter-spacing: 0.04em;
      }

      svg {
        display: inline-block;
        vertical-align: -0.15em;
      }
    `,
  ],
  template: `
    <div class="card">
      <!-- Status header: pill + colored dot. RECORDING pulses; IDLE is static. -->
      <div class="header">
        <div class="header-row">
          <div class="status">
            @if (recording()) {
              <span class="rec-dot"></span>
              <span class="status-label recording">RECORDING</span>
            } @else {
              <span class="dot idle"></span>
              <span class="status-label idle">IDLE</span>
            }
          </div>
          <!-- TODO(tray): elapsed timer + meeting title — main doesn't pass a
               clean elapsed string through TrayState yet (would need churn in
               the renderer→main state push). Add the timer here only once it
               can be threaded through without that churn. -->
        </div>
        @if (!recording()) {
          <div class="header-hint">No active recording.</div>
        }
      </div>

      <!-- Primary action: Start when idle, Stop & review when recording.
           NOTE: no ⌘⇧R hotkey chip — there is NO global shortcut registered
           for start/stop (the main window's ⌘⇧B is window-scoped, not global),
           so showing a chip would lie. Re-add when a real globalShortcut lands. -->
      <div class="action-wrap">
        @if (recording()) {
          <button type="button" class="action action-stop" (click)="emit('stop')">
            <svg
              viewBox="0 0 24 24"
              width="11"
              height="11"
              fill="currentColor"
              stroke="none"
            >
              <path d="M6.5 6.5h11v11h-11z" />
            </svg>
            Stop &amp; review
          </button>
        } @else {
          <button
            type="button"
            class="action action-start"
            [disabled]="!canStart()"
            (click)="emit('start')"
          >
            <svg
              viewBox="0 0 24 24"
              width="13"
              height="13"
              fill="none"
              stroke="currentColor"
              stroke-width="1.6"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <path
                d="M12 3a3 3 0 0 0-3 3v6a3 3 0 0 0 6 0V6a3 3 0 0 0-3-3zM5.5 11.5a.75.75 0 0 1 1.5 0 5 5 0 0 0 10 0 .75.75 0 0 1 1.5 0 6.5 6.5 0 0 1-5.75 6.46V20.5a.75.75 0 0 1-1.5 0v-2.54A6.5 6.5 0 0 1 5.5 11.5z"
              />
            </svg>
            Start recording
          </button>
        }
      </div>

      <!-- TODO(tray): Pause/Resume + Bookmark sub-grid, "Search transcripts",
           and the "Recent" meetings list are DEFERRED — the engine has no real
           pause and no Recent data is wired to the popover yet. -->

      <div class="divider"></div>

      <!-- Open / Settings rows -->
      <div class="rows">
        <button type="button" class="row" (click)="emit('openMain')">
          <span class="row-icon">
            <svg
              viewBox="0 0 24 24"
              width="13"
              height="13"
              fill="none"
              stroke="currentColor"
              stroke-width="1.6"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <path
                d="M4 5.5A1.5 1.5 0 0 1 5.5 4h13A1.5 1.5 0 0 1 20 5.5v13a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 18.5v-13zm5 .5H5.5v12H9V6z"
              />
            </svg>
          </span>
          <span class="row-label">Open main window</span>
        </button>
        <button type="button" class="row" (click)="emit('settings')">
          <span class="row-icon">
            <svg
              viewBox="0 0 24 24"
              width="13"
              height="13"
              fill="none"
              stroke="currentColor"
              stroke-width="1.6"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <path
                d="M12 8.5a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7zM19.4 13a7.5 7.5 0 0 0 0-2l1.7-1.3a.5.5 0 0 0 .12-.62l-1.6-2.78a.5.5 0 0 0-.6-.22l-2 .8a7.4 7.4 0 0 0-1.74-1L15 3.9a.5.5 0 0 0-.5-.4h-3.2a.5.5 0 0 0-.5.4l-.3 2.1a7.4 7.4 0 0 0-1.74 1l-2-.8a.5.5 0 0 0-.6.22L4.7 9.2a.5.5 0 0 0 .12.6L6.5 11a7.5 7.5 0 0 0 0 2l-1.68 1.3a.5.5 0 0 0-.12.6l1.6 2.78a.5.5 0 0 0 .6.22l2-.8a7.4 7.4 0 0 0 1.74 1l.3 2.1a.5.5 0 0 0 .5.4h3.2a.5.5 0 0 0 .5-.4l.3-2.1a7.4 7.4 0 0 0 1.74-1l2 .8a.5.5 0 0 0 .6-.22l1.6-2.78a.5.5 0 0 0-.12-.6L19.4 13z"
              />
            </svg>
          </span>
          <span class="row-label">Settings…</span>
          <span class="row-hotkey">⌘,</span>
        </button>
      </div>

      <div class="divider"></div>

      <!-- Quit row -->
      <div class="rows">
        <button type="button" class="row" (click)="emit('quit')">
          <span class="row-icon">
            <svg
              viewBox="0 0 24 24"
              width="13"
              height="13"
              fill="none"
              stroke="currentColor"
              stroke-width="1.6"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <path d="M6 6l12 12M18 6L6 18" />
            </svg>
          </span>
          <span class="row-label">Quit Hark</span>
          <span class="row-hotkey">⌘Q</span>
        </button>
      </div>

      <!-- Privacy footer -->
      <div class="footer">
        <svg
          viewBox="0 0 24 24"
          width="11"
          height="11"
          fill="none"
          stroke="currentColor"
          stroke-width="1.6"
          stroke-linecap="round"
          stroke-linejoin="round"
        >
          <path
            d="M3 3l18 18M7 17.5A4.5 4.5 0 0 1 7.5 8.5M9.5 5.5A6 6 0 0 1 19 10a3.5 3.5 0 0 1 1.7 6.6"
          />
        </svg>
        Audio stays on this Mac.
      </div>
    </div>
  `,
})
export class TrayPopoverComponent implements OnInit, OnDestroy {
  /** Latest state pushed from main. Starts idle/disconnected so the first
   *  paint is sensible before the seed arrives (main re-seeds on load). */
  private readonly state = signal<TrayPopoverState>({
    capturing: false,
    ready: false,
    connected: false,
    theme: 'dark',
  });

  /** True while the engine is capturing — drives the RECORDING pill + the
   *  Start↔Stop button swap. */
  readonly recording = computed(() => this.state().capturing);

  /** Start is offered only when connected + the model is ready + idle — same
   *  gate the main window applies (sans the source toggles, which the popover
   *  doesn't surface; capture reuses the main window's persisted selections). */
  readonly canStart = computed(() => {
    const s = this.state();
    return s.connected && s.ready && !s.capturing;
  });

  /** Unsubscribe handle for the `harkTray.onState` listener. */
  private unsubState: (() => void) | null = null;

  ngOnInit(): void {
    // Subscribe to main's state pushes. Outside the popover window (no
    // harkTray bridge) this no-ops — the component still renders its idle
    // default, which is the right thing for a bare `ng serve` preview.
    this.unsubState =
      window.harkTray?.onState((next) => {
        this.state.set(next);
        // Mirror main's resolved light/dark onto <html> so the token cascade
        // paints the popover to match the main window. No ThemeService here —
        // that needs the full `hark` bridge (prefs IPC); the popover stays
        // minimal and takes the already-resolved theme from main.
        document.documentElement.setAttribute('data-theme', next.theme);
      }) ?? null;
  }

  ngOnDestroy(): void {
    this.unsubState?.();
  }

  /** Emit a whitelisted action to main (no-op outside the popover window). */
  emit(action: TrayPopoverAction): void {
    window.harkTray?.action(action);
  }
}
