// OpenAiCompatibleProvider — provider for any OpenAI-compatible REST API
// (ADR-0029). Covers cloud (OpenAI, OpenRouter, Gemini's OpenAI-compat
// endpoint) AND local, zero-egress backends (Ollama http://localhost:11434/v1,
// LM Studio, llama.cpp). Uses Node's global `fetch`; no SDK.
//
// testConnection probes `GET {baseUrl}/models` — the standard, cheap,
// content-free OpenAI-compat discovery endpoint. It attaches an
// `Authorization: Bearer <key>` header ONLY when a key exists, so local
// endpoints that take no auth still pass.
//
// PRIVACY (ADR-0029, privacy-audited surface): NEVER logs the key, request, or
// response body. One content-free status line only. `detail` on failure comes
// solely from the HTTP status (detailForStatus) — never the response body.

import type { LlmConfig, LlmTestResult } from './types';
import {
  LlmProvider,
  LlmCompleteOptions,
  LlmStreamChunk,
  LLM_REQUEST_TIMEOUT_MS,
  detailForStatus,
  notImplemented,
} from './provider';

export class OpenAiCompatibleProvider implements LlmProvider {
  constructor(
    private readonly config: LlmConfig,
    private readonly key?: string,
  ) {}

  /** Normalize the configured baseUrl: trim whitespace and strip ONE trailing
   *  slash so `{baseUrl}/models` never doubles up (`.../v1/` → `.../v1`). */
  private normalizedBaseUrl(): string {
    return (this.config.baseUrl ?? '').trim().replace(/\/+$/, '');
  }

  /** Host portion of the baseUrl for a content-free network-failure message.
   *  Falls back to the raw (trimmed) base if it doesn't parse as a URL. */
  private hostForDetail(base: string): string {
    try {
      return new URL(base).host;
    } catch {
      return base;
    }
  }

  async testConnection(): Promise<LlmTestResult> {
    const base = this.normalizedBaseUrl();
    if (!base) {
      return { ok: false, detail: 'No base URL set' };
    }
    if (!this.config.model) {
      return { ok: false, detail: 'No model set' };
    }

    const url = `${base}/models`;
    const headers: Record<string, string> = {};
    // Local endpoints (Ollama / LM Studio / llama.cpp) take no auth — only
    // attach the bearer when the user has actually set a key. A cloud endpoint
    // missing a key will simply return 401, which detailForStatus maps to
    // "Invalid API key".
    if (this.key) {
      headers['Authorization'] = `Bearer ${this.key}`;
    }

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), LLM_REQUEST_TIMEOUT_MS);

    try {
      const res = await fetch(url, {
        method: 'GET',
        headers,
        signal: controller.signal,
      });

      if (res.ok) {
        // eslint-disable-next-line no-console
        console.log('[llm] test openai-compatible → ok');
        return { ok: true, detail: 'Connected' };
      }
      const detail = detailForStatus(res.status);
      // eslint-disable-next-line no-console
      console.log(`[llm] test openai-compatible → fail (${res.status})`);
      return { ok: false, detail };
    } catch (err) {
      const aborted = err instanceof Error && err.name === 'AbortError';
      const host = this.hostForDetail(base);
      // eslint-disable-next-line no-console
      console.log(`[llm] test openai-compatible → ${aborted ? 'timeout' : 'network error'}`);
      return {
        ok: false,
        detail: aborted ? `Timed out reaching ${host}` : `Couldn't reach ${host}`,
      };
    } finally {
      clearTimeout(timer);
    }
  }

  // ── Later slices (Phase 6) ──────────────────────────────────────────────
  async complete(_opts: LlmCompleteOptions): Promise<string> {
    return notImplemented('complete');
  }

  stream(_opts: LlmCompleteOptions): AsyncIterable<LlmStreamChunk> {
    return notImplemented('stream');
  }
}
