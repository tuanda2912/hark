// Preload script. Runs in a sandboxed context that has access to both
// Node's `require` (limited to electron's exposed bits) and the DOM.
// Anything we want the renderer to see goes through `contextBridge`.
//
// Per ADR-0001's Electron security model: contextIsolation ON,
// nodeIntegration OFF, sandbox ON. Only the explicit `window.hark` API
// surface below crosses the boundary.

import { contextBridge, ipcRenderer, IpcRendererEvent } from 'electron';
import type { Prefs } from './prefs';
import type {
  LlmConfig,
  LlmStatus,
  LlmTestResult,
  SummarizeReq,
  SummarizeResult,
  CloudCallLogEntry,
} from './llm/types';

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

  /** Read a persisted meeting-audio file (vault/.audio/<id>.wav) for the
   *  Post-Meeting Review screen. The path comes from MeetingSavedPayload
   *  .audio_path. main VALIDATES it (must be a .wav inside the vault root) and
   *  reads read-only; it rejects anything else, so this can't be used to read
   *  arbitrary files. Resolves with the raw bytes (Uint8Array) for the
   *  renderer to wrap in a Blob; rejects on a bad/forbidden path or I/O error. */
  readMeetingAudio(path: string): Promise<Uint8Array> {
    return ipcRenderer.invoke('hark:read-meeting-audio', path);
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

  // ─── LLM (Phase 6 — ADR-0029 / ADR-0030) ────────────────────────────
  // The provider config + key live in MAIN. This bridge exposes ONLY the
  // five contract methods; crucially there is NO `getKey`/`getApiKey` — the
  // API key can be SET (renderer → main, one-way) but can NEVER be read back
  // across the bridge. get-status/set-config/set-key/clear-key all resolve to
  // an LlmStatus that carries `hasKey: boolean` but no key value. The renderer
  // declares the matching window.hark.llm TS type separately.
  llm: {
    /** Current LLM status (configured / hasKey / config). Never the key. */
    getStatus(): Promise<LlmStatus> {
      return ipcRenderer.invoke('hark:llm:get-status');
    },

    /** Persist provider/model/baseUrl to prefs.llm (CONFIG only — no key) and
     *  resolve a fresh status. We re-shape to ONLY the whitelisted fields here
     *  so nothing extra crosses the bridge; main re-validates again. Rejects
     *  on an invalid config. */
    setConfig(cfg: LlmConfig): Promise<LlmStatus> {
      return ipcRenderer.invoke('hark:llm:set-config', {
        provider: cfg.provider,
        model: typeof cfg.model === 'string' ? cfg.model : '',
        // Pass baseUrl through only when it's actually a string; undefined is
        // dropped by structured-clone so the key stays absent for 'anthropic'.
        baseUrl: typeof cfg.baseUrl === 'string' ? cfg.baseUrl : undefined,
      });
    },

    /** Encrypt + store the API key for the CURRENT provider via safeStorage
     *  in main, then resolve a fresh status. The key crosses the bridge ONE
     *  WAY (renderer → main) and is never returned. Rejects if key storage is
     *  unavailable (no plaintext fallback) or the key is empty. */
    setApiKey(key: string): Promise<LlmStatus> {
      return ipcRenderer.invoke('hark:llm:set-key', key);
    },

    /** Remove the CURRENT provider's stored key; resolve a fresh status. */
    clearApiKey(): Promise<LlmStatus> {
      return ipcRenderer.invoke('hark:llm:clear-key');
    },

    /** Run a cheap live validation call against the current provider
     *  (key + endpoint + model). Resolves { ok, detail } where `detail` is a
     *  short, content-free message — never a response body or the key. */
    testConnection(): Promise<LlmTestResult> {
      return ipcRenderer.invoke('hark:llm:test');
    },

    /** Summarize a meeting transcript (Slice 2 — ADR-0031). For a CLOUD
     *  provider main REDACTS the transcript before send; for a LOCAL (loopback)
     *  endpoint it's sent as-is (zero egress). We re-shape to ONLY the
     *  whitelisted fields here so nothing extra crosses the bridge; main
     *  re-coerces again. Resolves a SummarizeResult — on success the markdown
     *  summary + a content-free redaction receipt, on failure { ok:false,
     *  detail } with a status-derived message (never a key or response body). */
    summarize(req: SummarizeReq): Promise<SummarizeResult> {
      return ipcRenderer.invoke('hark:llm:summarize', {
        transcript: typeof req?.transcript === 'string' ? req.transcript : '',
        knownNames: Array.isArray(req?.knownNames)
          ? req.knownNames.filter((n): n is string => typeof n === 'string')
          : undefined,
      });
    },

    /** Read the local cloud-call activity log (Settings → Privacy). Resolves
     *  an array of METADATA-ONLY entries (lengths/ids/status) — never any
     *  transcript or summary content. */
    getCloudLog(): Promise<CloudCallLogEntry[]> {
      return ipcRenderer.invoke('hark:llm:get-cloud-log');
    },
  },
});
