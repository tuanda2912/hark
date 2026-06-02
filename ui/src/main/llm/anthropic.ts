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
  CompleteReq,
  CompleteResult,
  LLM_REQUEST_TIMEOUT_MS,
  LLM_COMPLETE_TIMEOUT_MS,
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

  /**
   * Non-streaming completion against POST /v1/messages (Slice 2 — summary).
   *
   * The system prompt is sent as a single text block with
   * `cache_control: { type: 'ephemeral' }` — Anthropic prompt-caching, a cheap
   * win since the SUMMARY_PROMPT is identical across calls. The user message
   * carries the (redacted-if-cloud) transcript.
   *
   * PRIVACY: the request body (system/user content) and the response body are
   * NEVER logged — only metadata (a status line). On a non-ok HTTP we throw an
   * Error whose message is derived ONLY from the numeric status via
   * detailForStatus — the response body is never read into the error.
   */
  async complete(req: CompleteReq): Promise<CompleteResult> {
    if (!this.key) {
      throw new Error('No API key set');
    }
    if (!this.config.model) {
      throw new Error('No model set');
    }

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), LLM_COMPLETE_TIMEOUT_MS);

    try {
      const res = await fetch(ANTHROPIC_MESSAGES_URL, {
        method: 'POST',
        headers: {
          'x-api-key': this.key,
          'anthropic-version': ANTHROPIC_VERSION,
          'content-type': 'application/json',
        },
        body: JSON.stringify({
          model: this.config.model,
          max_tokens: req.maxTokens,
          // Prompt-cache the (stable) system instructions to cut input cost on
          // repeat summaries (ADR-0031). System is an array of text blocks.
          system: [
            {
              type: 'text',
              text: req.system,
              cache_control: { type: 'ephemeral' },
            },
          ],
          messages: [{ role: 'user', content: req.user }],
        }),
        signal: controller.signal,
      });

      if (!res.ok) {
        // STATUS-only message — never read res.body (may contain content).
        // eslint-disable-next-line no-console
        console.log(`[llm] complete anthropic → fail (${res.status})`);
        throw new Error(detailForStatus(res.status));
      }

      // Parse: Anthropic returns { content: [{ type, text }, ...] }. Assemble
      // the response by concatenating the text of every text block.
      const text = this.extractText(await res.json());
      // eslint-disable-next-line no-console
      console.log(`[llm] complete anthropic → ok (${text.length} chars)`);
      return { text };
    } catch (err) {
      // Re-throw a status-derived error untouched; map network/abort to a
      // content-free host-level message (mirrors testConnection).
      if (err instanceof Error && err.name === 'AbortError') {
        // eslint-disable-next-line no-console
        console.log('[llm] complete anthropic → timeout');
        throw new Error(`Timed out reaching ${ANTHROPIC_HOST}`);
      }
      // A thrown detailForStatus Error from the !res.ok branch above lands
      // here too — re-throw it as-is (its message is already status-derived).
      if (err instanceof Error && this.isStatusDerived(err.message)) {
        throw err;
      }
      // eslint-disable-next-line no-console
      console.log('[llm] complete anthropic → network error');
      throw new Error(`Couldn't reach ${ANTHROPIC_HOST}`);
    } finally {
      clearTimeout(timer);
    }
  }

  /** Concatenate the `text` of every text block in an Anthropic messages
   *  response. Tolerant of unexpected shapes (returns '' rather than throwing
   *  on a malformed body — we never surface body content in an error). */
  private extractText(body: unknown): string {
    if (typeof body !== 'object' || body === null) return '';
    const content = (body as Record<string, unknown>)['content'];
    if (!Array.isArray(content)) return '';
    let out = '';
    for (const block of content) {
      if (
        typeof block === 'object' &&
        block !== null &&
        (block as Record<string, unknown>)['type'] === 'text' &&
        typeof (block as Record<string, unknown>)['text'] === 'string'
      ) {
        out += (block as Record<string, unknown>)['text'] as string;
      }
    }
    return out;
  }

  /** True if `msg` is one of the known status-derived strings from
   *  detailForStatus — so the catch can re-throw it unchanged rather than
   *  masking it behind the generic network message. */
  private isStatusDerived(msg: string): boolean {
    return (
      msg === 'Invalid API key' ||
      msg === 'Model not found' ||
      msg === 'Rate limited — try again shortly' ||
      msg.startsWith('Provider error (') ||
      msg.startsWith('HTTP ')
    );
  }

  // ── Later slices (Phase 6) ──────────────────────────────────────────────
  stream(_opts: LlmCompleteOptions): AsyncIterable<LlmStreamChunk> {
    return notImplemented('stream');
  }
}
