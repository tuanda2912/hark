// External retrieval backend — main-process facade (ADR-0033/0034).
//
// The EXTERNAL backend only. The built-in backend retrieves in the engine over
// the WebSocket (ADR-0032); the renderer picks the path from `prefs.rag.backend`
// and only calls this module when it's 'external'. Here we: read the config,
// enforce the loopback guard, dispatch to the http/mcp transport, and map the
// backend's chunks into the SAME `RagResultChunk` shape the built-in path emits
// (so the Ask panel renders both identically — slice 4c).
//
// PRIVACY: this is a retrieval client, not an egress point — it talks ONLY to a
// loopback service (guarded) and returns vault chunks to the local renderer. The
// downstream redact→LLM→log→citations path stays in llm/index.ts (ADR-0029/0031).
// Nothing here logs the query or chunk text — content-free status lines only.

import { loadPrefs } from '../prefs';
import type {
  RagBackendConfig,
  RetrievedChunk,
  ExternalChunk,
  RagConnectionResult,
  RagTransport,
} from './types';
import { assertLoopbackEndpoint } from './loopback';
import { httpRetrieve, httpTestConnection } from './http';
import { mcpRetrieve, mcpTestConnection } from './mcp';

/** Default + max retrieved chunks (mirror the engine's `rag.retrieve` clamp). */
const DEFAULT_K = 6;
const MAX_K = 50;

/** Read the retrieval-backend config from prefs. Defaults to built-in (the safe,
 *  out-of-box default) when absent/malformed — same posture as the engine. */
export function readRagConfig(): RagBackendConfig {
  const rag = loadPrefs().rag;
  if (rag && rag.backend === 'external' && rag.external) {
    return {
      backend: 'external',
      external: {
        transport: rag.external.transport,
        endpoint: rag.external.endpoint,
        ...(rag.external.toolName !== undefined ? { toolName: rag.external.toolName } : {}),
      },
    };
  }
  return { backend: 'builtin' };
}

/** Clamp an untrusted k into [1, MAX_K], defaulting when absent/NaN. */
function clampK(k: unknown): number {
  if (typeof k !== 'number' || !Number.isFinite(k)) return DEFAULT_K;
  return Math.max(1, Math.min(MAX_K, Math.floor(k)));
}

/** Map an external chunk to the renderer `RagResultChunk` shape. External
 *  backends own their own addressing, so char offsets are 0 (the built-in
 *  offsets power a future jump-to-source); `source`→`note_path`,
 *  `headingPath`→`heading_path`, missing score→0. */
function mapChunk(c: ExternalChunk): RetrievedChunk {
  return {
    text: c.text,
    note_path: c.source,
    heading_path: c.headingPath ?? '',
    char_start: 0,
    char_end: 0,
    score: typeof c.score === 'number' ? c.score : 0,
  };
}

/**
 * Retrieve the top-k vault chunks via the configured EXTERNAL backend. Throws a
 * content-free Error if:
 *   - the backend isn't 'external' (the renderer shouldn't call this for
 *     built-in — guard so a misroute fails loudly, not silently),
 *   - the endpoint isn't loopback (the privacy gate — refused before any fetch),
 *   - the transport call fails (HTTP/network/timeout/malformed).
 */
export async function retrieve(
  query: string,
  opts?: { k?: number; scope?: string },
): Promise<RetrievedChunk[]> {
  const config = readRagConfig();
  if (config.backend !== 'external') {
    throw new Error('External retrieval is not configured (backend is built-in)');
  }
  const q = (query ?? '').trim();
  if (q.length === 0) return [];

  const { transport, endpoint, toolName } = config.external;
  // Loopback guard FIRST — refuses a non-local endpoint before any network I/O.
  const url = assertLoopbackEndpoint(endpoint);
  const k = clampK(opts?.k);
  const scope = typeof opts?.scope === 'string' ? opts.scope : 'vault';

  const chunks =
    transport === 'mcp'
      ? await mcpRetrieve(url, toolName, q, k)
      : await httpRetrieve(url, q, k, scope);
  return chunks.map(mapChunk);
}

/**
 * Probe the configured external backend (Settings "Test connection"). Returns a
 * content-free verdict; never throws (a bad config / unreachable host maps to
 * `{ ok:false, detail }`). Built-in ⇒ a clear "nothing to test" result.
 */
export async function testConnection(): Promise<RagConnectionResult> {
  const config = readRagConfig();
  if (config.backend !== 'external') {
    return { ok: false, detail: 'Built-in backend — nothing external to test' };
  }
  let url: URL;
  try {
    url = assertLoopbackEndpoint(config.external.endpoint);
  } catch (err) {
    return { ok: false, detail: err instanceof Error ? err.message : 'Invalid endpoint' };
  }
  const { transport, toolName } = config.external;
  return transport === 'mcp'
    ? mcpTestConnection(url, toolName)
    : httpTestConnection(url);
}

export type { RagTransport, RagBackendConfig, RetrievedChunk, RagConnectionResult };
