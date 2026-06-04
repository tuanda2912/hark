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
  AskReq,
  AskResult,
  TranslateReq,
  TranslateResult,
  TranslateSegmentReq,
  TranslateSegmentResult,
  CloudCallLogEntry,
} from './llm/types';
import type { RetrievedChunk, RagConnectionResult } from './rag/types';

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
 *  WHITELIST below is the trust boundary: only these strings are ever
 *  forwarded to the renderer callback, regardless of what main sends.
 *  `settings` (from the popover's Settings… row) asks the renderer to open
 *  its Settings modal; start/stop drive capture. (`openMain`/`quit` are
 *  handled in MAIN and never reach the renderer.) */
type TrayAction = 'start' | 'stop' | 'settings';
const TRAY_ACTIONS: readonly TrayAction[] = ['start', 'stop', 'settings'];

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
      // Appearance pref — only the three known values cross the bridge; main's
      // sanitizeTheme collapses anything else to 'system'.
      theme:
        prefs.theme === 'light' || prefs.theme === 'dark' ? prefs.theme : 'system',
      // ADR-0027 privacy flags — re-shaped to strict booleans so nothing
      // extra crosses the bridge; main re-validates again before writing.
      privacy: {
        keepAudio: !!prefs.privacy?.keepAudio,
        rememberSpeakers: !!prefs.privacy?.rememberSpeakers,
        syncAudio: !!prefs.privacy?.syncAudio,
        syncSpeakers: !!prefs.privacy?.syncSpeakers,
      },
      // Vault-retrieval backend (ADR-0033/0034). Forwarded so the user's
      // backend choice actually persists across restarts — main's sanitizeRag
      // is the final trust boundary (drops a half-config back to built-in).
      // Whole-value passthrough; the renderer's ragSnapshot() builds the shape.
      rag: prefs.rag,
    });
  },

  /** Open the vault folder in Finder. main holds the fixed path. */
  revealVault(): void {
    ipcRenderer.send('hark:reveal-vault');
  },

  /** Reveal a SPECIFIC vault file in Finder (open its folder + select it) —
   *  e.g. the saved meeting note, so the user lands on it instead of the vault
   *  root. main validates the path is inside the vault (untrusted-input gate)
   *  and only reveals; never reads/writes. */
  revealPath(filePath: string): void {
    ipcRenderer.send('hark:reveal-path', filePath);
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

    /** Translate the whole transcript to `targetLang` (BACKLOG translation §1).
     *  Same egress model as summarize: CLOUD redacts the transcript first, LOCAL
     *  sends it as-is (zero egress). Re-shaped to whitelisted fields; main
     *  re-coerces. Resolves a TranslateResult (translation + content-free
     *  receipt, or { ok:false, detail }). */
    translate(req: TranslateReq): Promise<TranslateResult> {
      return ipcRenderer.invoke('hark:llm:translate', {
        transcript: typeof req?.transcript === 'string' ? req.transcript : '',
        targetLang: typeof req?.targetLang === 'string' ? req.targetLang : '',
        knownNames: Array.isArray(req?.knownNames)
          ? req.knownNames.filter((n): n is string => typeof n === 'string')
          : undefined,
      });
    },

    /** Ask a question about THIS meeting (Slice 3 — Phase 6). For a CLOUD
     *  provider main REDACTS BOTH the question and the transcript before send
     *  (the question is user content leaving the machine too); for a LOCAL
     *  (loopback) endpoint both are sent as-is (zero egress). We re-shape to
     *  ONLY the whitelisted fields here so nothing extra crosses the bridge;
     *  main re-coerces again. Resolves an AskResult — on success the answer + a
     *  content-free redaction receipt, on failure { ok:false, detail } with a
     *  status-derived message (never a key or response body). */
    ask(req: AskReq): Promise<AskResult> {
      return ipcRenderer.invoke('hark:llm:ask', {
        question: typeof req?.question === 'string' ? req.question : '',
        scope: req?.scope === 'vault' ? 'vault' : 'meeting',
        transcript: typeof req?.transcript === 'string' ? req.transcript : '',
        // Vault scope (slice 4c): the retrieved chunk texts, in citation order.
        context: Array.isArray(req?.context)
          ? req.context.filter((c): c is string => typeof c === 'string')
          : undefined,
        knownNames: Array.isArray(req?.knownNames)
          ? req.knownNames.filter((n): n is string => typeof n === 'string')
          : undefined,
      });
    },

    /** Translate ONE finalized caption line to an arbitrary target (ADR-0035,
     *  §3 — live translation). Fired per finalized segment when the user opted
     *  in. CLOUD redacts the line first; LOCAL (loopback) sends it as-is (zero
     *  egress — the recommended setup). Re-shaped to whitelisted fields; main
     *  re-coerces. Resolves a TranslateSegmentResult (translation + content-free
     *  egress/redaction receipt, or { ok:false, detail }). */
    translateSegment(req: TranslateSegmentReq): Promise<TranslateSegmentResult> {
      return ipcRenderer.invoke('hark:llm:translate-segment', {
        text: typeof req?.text === 'string' ? req.text : '',
        targetLang: typeof req?.targetLang === 'string' ? req.targetLang : '',
        knownNames: Array.isArray(req?.knownNames)
          ? req.knownNames.filter((n): n is string => typeof n === 'string')
          : undefined,
      });
    },

    /** Commit the pending live-translation roll-up to its single aggregated
     *  cloud-log entry (the renderer calls this when live translation stops, so
     *  the metadata-only audit entry lands promptly). Fire-and-forget. */
    flushLiveTranslate(): void {
      ipcRenderer.send('hark:llm:flush-live-translate');
    },

    /** Read the local cloud-call activity log (Settings → Privacy). Resolves
     *  an array of METADATA-ONLY entries (lengths/ids/status) — never any
     *  transcript or summary content. */
    getCloudLog(): Promise<CloudCallLogEntry[]> {
      return ipcRenderer.invoke('hark:llm:get-cloud-log');
    },
  },

  /**
   * EXTERNAL vault-retrieval backend bridge (ADR-0033/0034). Only used when the
   * user picked an external backend (prefs.rag.backend === 'external'); the
   * built-in backend retrieves in the engine over the WebSocket instead. All
   * retrieval is LOOPBACK-only — main enforces the guard and is the egress
   * chokepoint; this bridge never reaches a remote host. Re-shaped to the
   * whitelisted fields; main re-coerces again.
   */
  rag: {
    /** Retrieve top-K vault chunks via the configured external backend.
     *  Resolves the SAME chunk shape the built-in engine path emits, or rejects
     *  with a content-free error (unreachable / non-loopback / malformed). */
    retrieve(
      query: string,
      opts?: { k?: number; scope?: string },
    ): Promise<RetrievedChunk[]> {
      return ipcRenderer.invoke('hark:rag:retrieve', {
        query: typeof query === 'string' ? query : '',
        k: typeof opts?.k === 'number' ? opts.k : undefined,
        scope: typeof opts?.scope === 'string' ? opts.scope : undefined,
      });
    },
    /** Probe the configured external backend (Settings "Test connection").
     *  Resolves a content-free verdict; never rejects. */
    testConnection(): Promise<RagConnectionResult> {
      return ipcRenderer.invoke('hark:rag:test');
    },
  },
});
