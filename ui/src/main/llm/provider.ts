// LlmProvider — the provider abstraction (ADR-0029).
//
// Two implementations live alongside this file: AnthropicProvider
// (anthropic.ts) and OpenAiCompatibleProvider (openai-compatible.ts). All use
// Node's built-in global `fetch` — NO vendor SDK, NO new npm dependency
// (ADR-0029: avoids SDK telemetry + supply-chain/native-dep surface; egress
// stays small + auditable).
//
// This slice (Phase 6 Slice 1) only requires testConnection() to work. The
// complete()/stream() signatures are declared NOW so later slices have a
// stable shape to build against, but they throw "not implemented" for now.

import type { LlmConfig, LlmTestResult } from './types';

/** Network timeout for any provider HTTP call. A misconfigured/dead endpoint
 *  must not hang the main process — we abort via AbortController after this. */
export const LLM_REQUEST_TIMEOUT_MS = 15_000;

/** A single chat message handed to a provider. Text only — main never has an
 *  audio path into a provider (ADR-0029 privacy invariant). */
export interface LlmMessage {
  role: 'system' | 'user' | 'assistant';
  content: string;
}

/** Options for a completion request (later slices). */
export interface LlmCompleteOptions {
  messages: LlmMessage[];
  maxTokens?: number;
  /** Optional cancellation hook from the caller (e.g. user aborts a summary). */
  signal?: AbortSignal;
}

/** A streamed token chunk (later slices). */
export interface LlmStreamChunk {
  /** Incremental text delta. */
  delta: string;
}

/**
 * The provider contract. `testConnection` is the only method implemented this
 * slice; `complete`/`stream` are declared for later slices and throw until
 * then. Implementations must NEVER log keys, request bodies, or response
 * bodies (ADR-0029).
 */
export interface LlmProvider {
  /** Cheap live call validating key + endpoint + model. Resolves an
   *  LlmTestResult (never rejects for an HTTP/network failure — those map to
   *  `{ ok: false, detail }`). */
  testConnection(): Promise<LlmTestResult>;

  /** Non-streaming completion (Phase 6 later slices). Throws 'not implemented'
   *  this slice. */
  complete(opts: LlmCompleteOptions): Promise<string>;

  /** Streaming completion (Phase 6 later slices). Throws 'not implemented'
   *  this slice. */
  stream(opts: LlmCompleteOptions): AsyncIterable<LlmStreamChunk>;
}

/**
 * Build a provider from the current config + optional decrypted key. The key
 * is passed in by the caller (main wiring) AFTER decrypting via the keystore —
 * providers never touch the keystore themselves. `key` may be undefined for a
 * local 'openai-compatible' endpoint that needs no auth.
 *
 * Lazy `require` of the implementations keeps this factory free of a circular
 * import (the impls import the interface from here).
 */
export function makeProvider(config: LlmConfig, key?: string): LlmProvider {
  switch (config.provider) {
    case 'anthropic': {
      // eslint-disable-next-line @typescript-eslint/no-var-requires
      const { AnthropicProvider } = require('./anthropic') as typeof import('./anthropic');
      return new AnthropicProvider(config, key);
    }
    case 'openai-compatible': {
      // eslint-disable-next-line @typescript-eslint/no-var-requires
      const { OpenAiCompatibleProvider } = require('./openai-compatible') as typeof import('./openai-compatible');
      return new OpenAiCompatibleProvider(config, key);
    }
    default: {
      // Exhaustiveness: a new provider id must add a case above.
      const _never: never = config.provider;
      throw new Error(`unknown provider: ${String(_never)}`);
    }
  }
}

/**
 * Map an HTTP status to a SHORT, content-free human message. Shared by both
 * providers so the wording is consistent and provably body-free: the message
 * is derived ONLY from the numeric status (and the standard reason phrase) —
 * never from the response body, which could contain content.
 */
export function detailForStatus(status: number): string {
  switch (status) {
    case 401:
    case 403:
      return 'Invalid API key';
    case 404:
      return 'Model not found';
    case 429:
      return 'Rate limited — try again shortly';
    default:
      if (status >= 500) return `Provider error (${status})`;
      // Derived ONLY from the numeric status — we deliberately do NOT use the
      // server-supplied reason phrase (res.statusText), since the
      // OpenAI-compatible provider points at arbitrary user-configured endpoints
      // and a hostile/buggy server could put arbitrary text in the status line.
      return `HTTP ${status}`;
  }
}

/** The shared "later slice" stub. Keeps the not-implemented message uniform. */
export function notImplemented(method: string): never {
  throw new Error(`LlmProvider.${method} is not implemented in this slice`);
}
