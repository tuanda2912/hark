// LlmService — renderer-side facade over the `window.hark.llm` IPC bridge
// (ADR-0029).
//
// The provider HTTP lives entirely in the Electron MAIN process; this service
// is a thin, signals-based projection of provider readiness. It NEVER touches
// the network and NEVER sees a stored API key — it sends a key down to main
// (which encrypts it via safeStorage) and only ever reads back an `LlmStatus`
// (booleans + non-secret config) or an `LlmTestResult`.
//
// Every bridge call is guarded for `window.hark?.llm` so a bare `ng serve`
// (no Electron, no preload) degrades gracefully instead of throwing —
// `configured()` simply stays false there.
//
// Java/Spring analogue: a `@Service` wrapping a remote client, exposing a
// read model (the status signals) the UI binds to.

import { Injectable, signal, computed } from '@angular/core';
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
  CloudCallLogEntry,
} from './llm.types';

@Injectable({ providedIn: 'root' })
export class LlmService {
  // ─── Status projection ──────────────────────────────────────────────

  private readonly _status = signal<LlmStatus | null>(null);
  /** Latest provider status from main, or null before the first refresh /
   *  when running outside Electron. */
  readonly status = this._status.asReadonly();

  /** True once the active provider is usable. This is computed BY MAIN and
   *  consumed as-is here — the gate the Ask panel reads. */
  readonly configured = computed(() => this._status()?.configured ?? false);
  /** Whether a key is currently saved for the active provider. Drives the
   *  "key saved" indicator; the key itself is never exposed to the renderer. */
  readonly hasKey = computed(() => this._status()?.hasKey ?? false);
  /** The current non-secret config, or null. */
  readonly config = computed<LlmConfig | null>(
    () => this._status()?.config ?? null,
  );

  // ─── Test-connection state ──────────────────────────────────────────

  /** True while a `testConnection()` probe is in flight. */
  readonly testing = signal(false);
  /** Result of the most recent probe, or null if none has run / it was reset. */
  readonly testResult = signal<LlmTestResult | null>(null);

  // ─── Summarize state (ADR-0031) ─────────────────────────────────────

  /** True while a `summarize()` call is in flight. Drives the panel's
   *  "Summarizing…" state. */
  readonly summarizing = signal(false);
  /** The most recent summarize result (success or failure), or null before the
   *  first call / after a reset. */
  readonly summary = signal<SummarizeResult | null>(null);

  /** True while an `ask()` call is in flight. Drives the Ask panel's
   *  "thinking" state. */
  readonly asking = signal(false);
  /** The local cloud-activity log (metadata only — never content). Surfaced
   *  read-only in Settings → Privacy. */
  readonly cloudLog = signal<CloudCallLogEntry[]>([]);

  constructor() {
    // Pull the initial status once. Fire-and-forget: the guard inside
    // refresh() makes this a no-op outside Electron.
    void this.refresh();
  }

  // ─── Bridge calls (all guarded for window.hark?.llm) ────────────────

  /** Re-read the provider status from main into the signals. */
  async refresh(): Promise<void> {
    const llm = window.hark?.llm;
    if (!llm) return;
    this._status.set(await llm.getStatus());
  }

  /** Persist the non-secret provider/model/baseUrl; stores the returned
   *  status (which re-derives `configured`). */
  async setConfig(cfg: LlmConfig): Promise<void> {
    const llm = window.hark?.llm;
    if (!llm) return;
    this._status.set(await llm.setConfig(cfg));
  }

  /** Save the API key for the current provider. The key goes to main and is
   *  never read back; we only learn the new `hasKey` from the returned status. */
  async setApiKey(key: string): Promise<void> {
    const llm = window.hark?.llm;
    if (!llm) return;
    this._status.set(await llm.setApiKey(key));
  }

  /** Forget the saved key for the current provider. */
  async clearApiKey(): Promise<void> {
    const llm = window.hark?.llm;
    if (!llm) return;
    this._status.set(await llm.clearApiKey());
  }

  /** Probe the configured provider, storing the verdict in `testResult` and
   *  toggling `testing` around the call. Safe to call repeatedly. */
  async test(): Promise<void> {
    const llm = window.hark?.llm;
    if (!llm) return;
    this.testing.set(true);
    this.testResult.set(null);
    try {
      this.testResult.set(await llm.testConnection());
    } catch (err) {
      this.testResult.set({
        ok: false,
        detail: err instanceof Error ? err.message : 'connection test failed',
      });
    } finally {
      this.testing.set(false);
    }
  }

  // ─── Summarize (ADR-0031) ───────────────────────────────────────────

  /**
   * Send the transcript text to main for summarization (no direct network —
   * main owns the provider HTTP + redaction + cloud/local fork). Stores the
   * result in `summary` and toggles `summarizing`. Returns the result so a
   * caller can react inline; resolves with `{ ok: false }` (never throws) so
   * the panel only ever renders a result. No-op (a failure result) outside
   * Electron, where `window.hark.llm` is absent.
   */
  async summarize(req: SummarizeReq): Promise<SummarizeResult> {
    const llm = window.hark?.llm;
    if (!llm) {
      const result: SummarizeResult = {
        ok: false,
        detail: 'No model bridge available (running outside Electron).',
      };
      this.summary.set(result);
      return result;
    }
    this.summarizing.set(true);
    this.summary.set(null);
    try {
      const result = await llm.summarize(req);
      this.summary.set(result);
      return result;
    } catch (err) {
      const result: SummarizeResult = {
        ok: false,
        detail: err instanceof Error ? err.message : 'summarize failed',
      };
      this.summary.set(result);
      return result;
    } finally {
      this.summarizing.set(false);
    }
  }

  /** Reset the summarize state — used when a panel opens fresh so a prior
   *  meeting's summary doesn't flash. */
  resetSummary(): void {
    this.summary.set(null);
    this.summarizing.set(false);
  }

  // ─── Translate (end-of-meeting transcript translation) ──────────────

  /** True while a `translate()` call is in flight. Drives the panel's
   *  "Translating…" state. */
  readonly translating = signal(false);
  /** The most recent translate result (success or failure), or null before the
   *  first call / after a reset. */
  readonly translation = signal<TranslateResult | null>(null);

  /**
   * Translate the whole transcript to `req.targetLang` via main (no direct
   * network — main owns the cloud/local fork + redaction + cloud-call log).
   * Mirrors `summarize`: stores the result in `translation`, toggles
   * `translating`, never throws (resolves `{ ok:false }` so the panel only ever
   * renders a result). No-op (a failure result) outside Electron.
   */
  async translate(req: TranslateReq): Promise<TranslateResult> {
    const llm = window.hark?.llm;
    if (!llm) {
      const result: TranslateResult = {
        ok: false,
        detail: 'No model bridge available (running outside Electron).',
      };
      this.translation.set(result);
      return result;
    }
    this.translating.set(true);
    this.translation.set(null);
    try {
      const result = await llm.translate(req);
      this.translation.set(result);
      return result;
    } catch (err) {
      const result: TranslateResult = {
        ok: false,
        detail: err instanceof Error ? err.message : 'translate failed',
      };
      this.translation.set(result);
      return result;
    } finally {
      this.translating.set(false);
    }
  }

  /** Reset the translate state — used when the panel opens fresh. */
  resetTranslation(): void {
    this.translation.set(null);
    this.translating.set(false);
  }

  // ─── Ask: this-meeting Q&A (Phase 6 slice 3) ────────────────────────

  /**
   * Send a question + the transcript text to main to be answered (no direct
   * network — main owns the provider HTTP + redaction + cloud/local fork +
   * the local cloud-call log). Toggles `asking` around the call and returns
   * the result so the caller can react inline; resolves with `{ ok: false }`
   * (never throws) so the panel only ever renders a result. No-op (a failure
   * result) outside Electron, where `window.hark.llm` is absent. Unlike
   * `summarize`, the answer is NOT retained in a service signal — Q&A is
   * transient (the host holds the latest answer for display) and nothing is
   * persisted to the vault in this slice.
   */
  async ask(req: AskReq): Promise<AskResult> {
    const llm = window.hark?.llm;
    if (!llm) {
      return {
        ok: false,
        detail: 'No model bridge available (running outside Electron).',
      };
    }
    this.asking.set(true);
    try {
      return await llm.ask(req);
    } catch (err) {
      return {
        ok: false,
        detail: err instanceof Error ? err.message : 'ask failed',
      };
    } finally {
      this.asking.set(false);
    }
  }

  /** Re-read the local cloud-activity log from main into the `cloudLog`
   *  signal. Guarded for `window.hark?.llm`; a no-op outside Electron. */
  async refreshCloudLog(): Promise<void> {
    const llm = window.hark?.llm;
    if (!llm) return;
    this.cloudLog.set(await llm.getCloudLog());
  }
}
