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
  CompleteReq,
  CompleteResult,
  LLM_REQUEST_TIMEOUT_MS,
  LLM_COMPLETE_TIMEOUT_MS,
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

  /**
   * Non-streaming completion against POST {baseUrl}/chat/completions
   * (Slice 2 — summary). Works for cloud (OpenAI/OpenRouter/Gemini-compat)
   * and local (Ollama/LM Studio/llama.cpp) backends alike. The
   * `Authorization: Bearer <key>` header is attached ONLY when a key exists,
   * so a local no-auth endpoint still works (zero egress per ADR-0031).
   *
   * PRIVACY: the request body (system/user content) and the response body are
   * NEVER logged — only metadata (a status line). On a non-ok HTTP we throw an
   * Error whose message is derived ONLY from the numeric status via
   * detailForStatus — the response body is never read into the error.
   */
  async complete(req: CompleteReq): Promise<CompleteResult> {
    const base = this.normalizedBaseUrl();
    if (!base) {
      throw new Error('No base URL set');
    }
    if (!this.config.model) {
      throw new Error('No model set');
    }

    const url = `${base}/chat/completions`;
    const headers: Record<string, string> = { 'content-type': 'application/json' };
    if (this.key) {
      headers['Authorization'] = `Bearer ${this.key}`;
    }

    const controller = new AbortController();
    const timer = setTimeout(
      () => controller.abort(),
      req.timeoutMs ?? LLM_COMPLETE_TIMEOUT_MS,
    );

    try {
      const res = await fetch(url, {
        method: 'POST',
        headers,
        body: JSON.stringify({
          model: this.config.model,
          max_tokens: req.maxTokens,
          messages: [
            { role: 'system', content: req.system },
            { role: 'user', content: req.user },
          ],
        }),
        signal: controller.signal,
      });

      if (!res.ok) {
        // eslint-disable-next-line no-console
        console.log(`[llm] complete openai-compatible → fail (${res.status})`);
        throw new Error(detailForStatus(res.status));
      }

      // Parse: { choices: [{ message: { content } }] }.
      const text = this.extractText(await res.json());
      // eslint-disable-next-line no-console
      console.log(`[llm] complete openai-compatible → ok (${text.length} chars)`);
      return { text };
    } catch (err) {
      const host = this.hostForDetail(base);
      if (err instanceof Error && err.name === 'AbortError') {
        // eslint-disable-next-line no-console
        console.log('[llm] complete openai-compatible → timeout');
        throw new Error(`Timed out reaching ${host}`);
      }
      if (err instanceof Error && this.isStatusDerived(err.message)) {
        throw err;
      }
      // eslint-disable-next-line no-console
      console.log('[llm] complete openai-compatible → network error');
      throw new Error(`Couldn't reach ${host}`);
    } finally {
      clearTimeout(timer);
    }
  }

  /** Extract choices[0].message.content from an OpenAI-compatible response.
   *  Tolerant of unexpected shapes (returns '' rather than throwing on a
   *  malformed body — body content never surfaces in an error). */
  private extractText(body: unknown): string {
    if (typeof body !== 'object' || body === null) return '';
    const choices = (body as Record<string, unknown>)['choices'];
    if (!Array.isArray(choices) || choices.length === 0) return '';
    const first = choices[0];
    if (typeof first !== 'object' || first === null) return '';
    const message = (first as Record<string, unknown>)['message'];
    if (typeof message !== 'object' || message === null) return '';
    const content = (message as Record<string, unknown>)['content'];
    return typeof content === 'string' ? content : '';
  }

  /** True if `msg` is a known status-derived string from detailForStatus, so
   *  the catch re-throws it unchanged rather than masking it as a network
   *  error. Mirrors detailForStatus's outputs. */
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
