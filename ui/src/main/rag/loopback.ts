// Loopback guard for the external retrieval backend (ADR-0034, the privacy gate).
//
// Retrieval RESULTS are vault content flowing back into Hark. If the retrieval
// endpoint were remote, querying it would put vault content (the query) AND
// receive vault content over the network — a clear rule #1/#2 violation. So an
// external backend MUST be loopback. We refuse anything else BEFORE any fetch.
//
// Same host set as `isLocalEgress` in llm/index.ts: localhost / 127.0.0.1 / ::1.

/** True iff `host` is a loopback host. Normalizes the IPv6 bracketed form
 *  (`[::1]` → `::1`) and lowercases. */
export function isLoopbackHost(host: string): boolean {
  const h = host.replace(/^\[|\]$/g, '').toLowerCase();
  return h === 'localhost' || h === '127.0.0.1' || h === '::1';
}

/**
 * Parse + validate an external endpoint. Returns the parsed URL on success;
 * THROWS a clear, content-free Error if the endpoint is empty, unparseable, not
 * http(s), or non-loopback — so a non-local endpoint can never reach `fetch`.
 * The thrown message names only the host, never any vault content.
 */
export function assertLoopbackEndpoint(endpoint: string): URL {
  const raw = (endpoint ?? '').trim();
  if (raw.length === 0) {
    throw new Error('No external retrieval endpoint set');
  }
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new Error('External retrieval endpoint is not a valid URL');
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    throw new Error(`External retrieval endpoint must be http(s), got ${url.protocol}`);
  }
  if (!isLoopbackHost(url.hostname)) {
    throw new Error(
      `External retrieval endpoint must be loopback (localhost / 127.0.0.1 / ::1), got ${url.hostname}`,
    );
  }
  return url;
}
