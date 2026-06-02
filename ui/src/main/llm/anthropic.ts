// AnthropicProvider — Anthropic-native LLM provider (ADR-0029).
//
// Endpoint: https://api.anthropic.com/v1/messages (x-api-key auth,
// anthropic-version header). Uses Node's global `fetch`; no SDK.
//
// PRIVACY (ADR-0029, privacy-audited surface): this file NEVER logs the API
// key, the request body, or the response body. The only log is a single
// content-free status line. `detail` on a failure is derived solely from the
// HTTP status code (via detailForStatus) — never from the response body.

import type { LlmConfig, LlmTestResult } from './types';
import {
  LlmProvider,
  LlmCompleteOptions,
  LlmStreamChunk,
  LLM_REQUEST_TIMEOUT_MS,
  detailForStatus,
  notImplemented,
} from './provider';

const ANTHROPIC_MESSAGES_URL = 'https://api.anthropic.com/v1/messages';
const ANTHROPIC_VERSION = '2023-06-01';
/** Host shown in a network-failure detail (no scheme/path → nothing sensitive). */
const ANTHROPIC_HOST = 'api.anthropic.com';

export class AnthropicProvider implements LlmProvider {
  constructor(
    private readonly config: LlmConfig,
    private readonly key?: string,
  ) {}

  async testConnection(): Promise<LlmTestResult> {
    // Anthropic always requires a key. Validate locally before any egress so
    // we never make a guaranteed-401 call.
    if (!this.key) {
      return { ok: false, detail: 'No API key set' };
    }
    if (!this.config.model) {
      return { ok: false, detail: 'No model set' };
    }

    // Abort after the timeout so a hung/slow endpoint can't block main.
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), LLM_REQUEST_TIMEOUT_MS);

    try {
      // A minimal "ping" with max_tokens: 1 — the cheapest call that still
      // exercises auth + model + endpoint. The body carries no user content.
      const res = await fetch(ANTHROPIC_MESSAGES_URL, {
        method: 'POST',
        headers: {
          'x-api-key': this.key,
          'anthropic-version': ANTHROPIC_VERSION,
          'content-type': 'application/json',
        },
        body: JSON.stringify({
          model: this.config.model,
          max_tokens: 1,
          messages: [{ role: 'user', content: 'ping' }],
        }),
        signal: controller.signal,
      });

      if (res.ok) {
        // eslint-disable-next-line no-console
        console.log('[llm] test anthropic → ok');
        return { ok: true, detail: 'Connected' };
      }
      // Derive a SHORT message from the STATUS only — never read res.body
      // (which may contain content). detailForStatus maps 401→invalid key,
      // 404→model not found, etc.
      const detail = detailForStatus(res.status);
      // eslint-disable-next-line no-console
      console.log(`[llm] test anthropic → fail (${res.status})`);
      return { ok: false, detail };
    } catch (err) {
      // Network error / abort / DNS — generic host-level message, no detail
      // that could leak the request.
      const aborted = err instanceof Error && err.name === 'AbortError';
      // eslint-disable-next-line no-console
      console.log(`[llm] test anthropic → ${aborted ? 'timeout' : 'network error'}`);
      return {
        ok: false,
        detail: aborted
          ? `Timed out reaching ${ANTHROPIC_HOST}`
          : `Couldn't reach ${ANTHROPIC_HOST}`,
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
