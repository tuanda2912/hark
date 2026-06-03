// Plain loopback-HTTP external retrieval transport (ADR-0034).
//
// Contract: POST <endpoint> JSON { query, k, scope } → 200 { chunks: [{ text,
// source, headingPath?, score? }] }. The simplest external backend — a ~20-line
// local server satisfies it. The endpoint is loopback-validated by the caller
// (index.ts) BEFORE we get here, so a non-local host never reaches fetch.
//
// PRIVACY: never logs the query or the response body — one content-free status
// line only. Failure `detail` derives from the HTTP status / host, never a body.

import type { ExternalChunk, RagConnectionResult } from './types';
import { coerceExternalChunks } from './parse';

/** Retrieve timeout — generous (a cold external index might be slow) but bounded
 *  so a hung backend surfaces an error instead of a stuck spinner. */
const HTTP_RETRIEVE_TIMEOUT_MS = 15_000;
/** Test-connection timeout — shorter; it's an interactive probe. */
const HTTP_TEST_TIMEOUT_MS = 8_000;

/** POST a retrieve request to the plain-HTTP endpoint and coerce the response
 *  into `ExternalChunk[]`. Throws a content-free Error on HTTP/network/timeout
 *  failure (the message names only the host + status). */
export async function httpRetrieve(
  url: URL,
  query: string,
  k: number,
  scope: string,
): Promise<ExternalChunk[]> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), HTTP_RETRIEVE_TIMEOUT_MS);
  try {
    const res = await fetch(url.href, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ query, k, scope }),
      signal: controller.signal,
      // SSRF guard: the loopback check validates only the INITIAL url. A
      // redirect to a remote host would exfiltrate the query + receive vault
      // content off-machine. A local retrieval API never redirects, so refuse
      // them outright (fetch rejects rather than following) — see ADR-0034.
      redirect: 'error',
    });
    if (!res.ok) {
      // eslint-disable-next-line no-console
      console.log(`[rag] http retrieve → fail (${res.status})`);
      throw new Error(`Retrieval backend returned HTTP ${res.status}`);
    }
    const chunks = coerceExternalChunks(await res.json());
    // eslint-disable-next-line no-console
    console.log(`[rag] http retrieve → ok (${chunks.length} chunks)`);
    return chunks;
  } catch (err) {
    throw mapFetchError(err, url.host, 'HTTP ');
  } finally {
    clearTimeout(timer);
  }
}

/** Probe the plain-HTTP backend with a canned k=1 retrieve. Success = HTTP 200
 *  + a parseable `{ chunks: [...] }`. Returns a content-free verdict. */
export async function httpTestConnection(url: URL): Promise<RagConnectionResult> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), HTTP_TEST_TIMEOUT_MS);
  try {
    const res = await fetch(url.href, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ query: 'hark connection test', k: 1, scope: 'vault' }),
      signal: controller.signal,
      redirect: 'error', // SSRF guard — see httpRetrieve.
    });
    if (!res.ok) {
      // eslint-disable-next-line no-console
      console.log(`[rag] http test → fail (${res.status})`);
      return { ok: false, detail: `Backend returned HTTP ${res.status}` };
    }
    const chunks = coerceExternalChunks(await res.json());
    // eslint-disable-next-line no-console
    console.log('[rag] http test → ok');
    return { ok: true, detail: `Connected (${url.host})`, count: chunks.length };
  } catch (err) {
    const aborted = err instanceof Error && err.name === 'AbortError';
    // eslint-disable-next-line no-console
    console.log(`[rag] http test → ${aborted ? 'timeout' : 'network error'}`);
    return {
      ok: false,
      detail: aborted ? `Timed out reaching ${url.host}` : `Couldn't reach ${url.host}`,
    };
  } finally {
    clearTimeout(timer);
  }
}

/** Map a fetch rejection to a content-free Error (timeout / network / pass
 *  through an already content-free HTTP message). Shared shape with the LLM
 *  provider's error handling. */
export function mapFetchError(err: unknown, host: string, statusPrefix: string): Error {
  if (err instanceof Error && err.name === 'AbortError') {
    return new Error(`Timed out reaching ${host}`);
  }
  if (err instanceof Error && err.message.startsWith(statusPrefix)) {
    return err; // already a content-free "HTTP <n>" message
  }
  if (err instanceof Error && err.message.startsWith('Retrieval backend returned')) {
    return err;
  }
  return new Error(`Couldn't reach ${host}`);
}
