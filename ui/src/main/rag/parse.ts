// Coercion for untrusted external-backend responses (ADR-0034).
//
// Both transports (http, mcp) receive JSON from a user-run service we don't
// control. Treat it as untrusted: accept either a `{ chunks: [...] }` wrapper
// or a bare array, keep only well-formed `{ text, source, headingPath?, score? }`
// items, and drop the rest. Pure — no network, no logging of content.

import type { ExternalChunk } from './types';

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

/** Coerce an arbitrary JSON value into a clean `ExternalChunk[]`. Accepts a
 *  `{ chunks: [...] }` envelope or a bare array; requires string `text` +
 *  `source` per item (others dropped); carries `headingPath` only if a string
 *  and `score` only if a finite number. Never throws. */
export function coerceExternalChunks(value: unknown): ExternalChunk[] {
  const arr: unknown = isRecord(value) ? value['chunks'] : value;
  if (!Array.isArray(arr)) return [];
  const out: ExternalChunk[] = [];
  for (const item of arr) {
    if (!isRecord(item)) continue;
    const text = item['text'];
    const source = item['source'];
    if (typeof text !== 'string' || typeof source !== 'string') continue;
    const chunk: ExternalChunk = { text, source };
    if (typeof item['headingPath'] === 'string') chunk.headingPath = item['headingPath'];
    if (typeof item['score'] === 'number' && Number.isFinite(item['score'])) {
      chunk.score = item['score'];
    }
    out.push(chunk);
  }
  return out;
}
