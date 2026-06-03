// RetrievalService — the renderer-side `RetrievalBackend` switch (ADR-0033).
//
// Vault-scope Ask questions need top-K chunks from SOMEWHERE. There are two
// backends and the user picks one (prefs.rag.backend):
//   - 'builtin'  → the engine's local CoreML index, reached over the WebSocket
//                  (EngineService.retrieve → rag.retrieve/rag.results, ADR-0032).
//   - 'external' → a user-run LOCAL retrieval service, reached via main's
//                  loopback client (window.hark.rag.retrieve, ADR-0034).
//
// Both return the SAME RagResultChunk shape, so the host + Ask panel render
// either identically (slice 4c). This service hides the fork: the host calls
// retrieve() and gets chunks, regardless of backend. Neither path makes a remote
// network call — built-in is loopback WS, external is a loopback-guarded client
// in main; the downstream redact→LLM→citations path is unchanged either way.

import { Injectable, inject, computed, Signal } from '@angular/core';
import { EngineService } from './engine.service';
import { PreferencesService } from './preferences.service';
import type { RagResultChunk } from './engine.types';

@Injectable({ providedIn: 'root' })
export class RetrievalService {
  private readonly engine = inject(EngineService);
  private readonly prefs = inject(PreferencesService);

  /** True when vault retrieval is routed to the EXTERNAL backend (else the
   *  built-in engine index). Drives the Ask panel's backend label + which
   *  channel `retrieve()` uses. */
  readonly isExternal: Signal<boolean> = computed(
    () => this.prefs.ragBackend() === 'external',
  );

  /**
   * Retrieve the top-`k` vault chunks for `query` via the configured backend.
   * Built-in → the engine over the WebSocket; external → main's loopback client.
   * Rejects on failure (RAG_UNAVAILABLE / timeout / unreachable / non-loopback)
   * so the host can surface an honest inline message. Resolves `[]` for an empty
   * query or no hits.
   */
  async retrieve(
    query: string,
    opts?: { k?: number; scope?: string },
  ): Promise<readonly RagResultChunk[]> {
    if (this.isExternal()) {
      const bridge = window.hark?.rag;
      if (!bridge) {
        // External chosen but the bridge is absent (outside Electron, or an old
        // main without the rag surface) — fail honestly rather than silently
        // falling back to the engine (which the user opted out of).
        throw new Error('external retrieval backend unavailable');
      }
      return bridge.retrieve(query, opts);
    }
    return this.engine.retrieve(query, opts);
  }
}
