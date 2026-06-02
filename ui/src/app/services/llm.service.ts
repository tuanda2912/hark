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
import type { LlmConfig, LlmStatus, LlmTestResult } from './llm.types';

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
}
