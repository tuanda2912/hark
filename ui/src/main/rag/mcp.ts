// Minimal MCP-over-HTTP (Streamable HTTP) external retrieval transport
// (ADR-0034). Hand-rolled with raw `fetch` — NO @modelcontextprotocol/sdk,
// consistent with ADR-0029's no-SDK LLM layer. We use a tiny slice of MCP:
//   initialize → (notifications/initialized) → tools/call { name, { query, k } }
// and, for the connection test, tools/list. Responses may be a single JSON-RPC
// object (application/json) OR Server-Sent Events (text/event-stream); we handle
// both. Any `Mcp-Session-Id` from initialize is echoed on later requests.
//
// The endpoint is loopback-validated by the caller (index.ts) BEFORE we get
// here. PRIVACY: never logs the query or tool output — one content-free status
// line per step; errors name only the host / a content-free reason.

import type { ExternalChunk, RagConnectionResult } from './types';
import { coerceExternalChunks } from './parse';
import { mapFetchError } from './http';

const MCP_PROTOCOL_VERSION = '2025-06-18';
const MCP_RETRIEVE_TIMEOUT_MS = 15_000;
const MCP_TEST_TIMEOUT_MS = 8_000;
const DEFAULT_TOOL_NAME = 'search';

/** A live MCP session: the endpoint + any negotiated session id. */
interface McpSession {
  url: URL;
  sessionId: string | null;
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

/** One JSON-RPC POST. `id` null ⇒ a notification (no response parsed; server
 *  returns 202). Returns the parsed JSON-RPC `result` (throws on a JSON-RPC
 *  `error` or a non-ok HTTP). Captures `Mcp-Session-Id` into `session` on the
 *  initialize hop. */
async function rpc(
  session: McpSession,
  method: string,
  params: unknown,
  id: number | null,
  timeoutMs: number,
): Promise<unknown> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const headers: Record<string, string> = {
    'content-type': 'application/json',
    accept: 'application/json, text/event-stream',
    'mcp-protocol-version': MCP_PROTOCOL_VERSION,
  };
  if (session.sessionId) headers['mcp-session-id'] = session.sessionId;

  const body: Record<string, unknown> = { jsonrpc: '2.0', method };
  if (params !== undefined) body['params'] = params;
  if (id !== null) body['id'] = id;

  try {
    const res = await fetch(session.url.href, {
      method: 'POST',
      headers,
      body: JSON.stringify(body),
      signal: controller.signal,
      // SSRF guard: refuse redirects — the loopback check validated only the
      // initial endpoint; a redirect to a remote host would exfiltrate the
      // query + vault content off-machine (ADR-0034).
      redirect: 'error',
    });
    // Capture a session id from initialize (case-insensitive header).
    const sid = res.headers.get('mcp-session-id');
    if (sid) session.sessionId = sid;

    // A notification expects no body (202 Accepted). Don't parse.
    if (id === null) {
      if (!res.ok && res.status !== 202) {
        // eslint-disable-next-line no-console
        console.log(`[rag] mcp ${method} → HTTP ${res.status} (ignored, notification)`);
      }
      return undefined;
    }

    if (!res.ok) {
      throw new Error(`HTTP ${res.status}`);
    }

    const ct = res.headers.get('content-type') ?? '';
    const raw = await res.text();
    const message = ct.includes('text/event-stream')
      ? extractRpcFromSse(raw, id)
      : safeJsonParse(raw);
    if (!isRecord(message)) {
      throw new Error(`Malformed JSON-RPC from ${session.url.host}`);
    }
    if (isRecord(message['error'])) {
      // JSON-RPC error: surface only the (server-authored, content-free-by-
      // contract) message string, never the data payload.
      const em = message['error'] as Record<string, unknown>;
      const msg = typeof em['message'] === 'string' ? em['message'] : 'backend error';
      throw new Error(`MCP error: ${msg}`);
    }
    return message['result'];
  } catch (err) {
    throw mapMcpError(err, session.url.host);
  } finally {
    clearTimeout(timer);
  }
}

/** Pull the JSON-RPC message matching `id` out of an SSE body. SSE events are
 *  blank-line-delimited; each `data:` line carries a JSON-RPC message. We scan
 *  for one whose `id` matches (the response to our request). */
function extractRpcFromSse(raw: string, id: number): unknown {
  let last: unknown;
  for (const line of raw.split(/\r?\n/)) {
    const trimmed = line.trimStart();
    if (!trimmed.startsWith('data:')) continue;
    const json = trimmed.slice('data:'.length).trim();
    if (json.length === 0) continue;
    const parsed = safeJsonParse(json);
    if (isRecord(parsed)) {
      if (parsed['id'] === id) return parsed;
      last = parsed; // keep the last as a fallback
    }
  }
  return last;
}

function safeJsonParse(s: string): unknown {
  try {
    return JSON.parse(s);
  } catch {
    return undefined;
  }
}

/** Run the initialize handshake, returning a session ready for tool calls. */
async function handshake(url: URL, timeoutMs: number): Promise<McpSession> {
  const session: McpSession = { url, sessionId: null };
  await rpc(
    session,
    'initialize',
    {
      protocolVersion: MCP_PROTOCOL_VERSION,
      capabilities: {},
      clientInfo: { name: 'hark', version: '0.1.0' },
    },
    1,
    timeoutMs,
  );
  // Best-effort post-initialize notification (server returns 202; ignore result).
  await rpc(session, 'notifications/initialized', {}, null, timeoutMs).catch(() => undefined);
  return session;
}

/** MCP retrieve: initialize → tools/call { name, { query, k } } → parse the
 *  tool's text content as `{ chunks: [...] }` (or a bare array). Throws a
 *  content-free Error on any failure. */
export async function mcpRetrieve(
  url: URL,
  toolName: string | undefined,
  query: string,
  k: number,
): Promise<ExternalChunk[]> {
  const name = toolName && toolName.trim().length > 0 ? toolName.trim() : DEFAULT_TOOL_NAME;
  const session = await handshake(url, MCP_RETRIEVE_TIMEOUT_MS);
  const result = await rpc(
    session,
    'tools/call',
    { name, arguments: { query, k } },
    2,
    MCP_RETRIEVE_TIMEOUT_MS,
  );
  if (isRecord(result) && result['isError'] === true) {
    throw new Error('Retrieval tool reported an error');
  }
  const chunks = coerceExternalChunks(extractToolJson(result));
  // eslint-disable-next-line no-console
  console.log(`[rag] mcp retrieve → ok (${chunks.length} chunks)`);
  return chunks;
}

/** MCP test: initialize → tools/list; ok if the configured tool is present. */
export async function mcpTestConnection(
  url: URL,
  toolName: string | undefined,
): Promise<RagConnectionResult> {
  const name = toolName && toolName.trim().length > 0 ? toolName.trim() : DEFAULT_TOOL_NAME;
  try {
    const session = await handshake(url, MCP_TEST_TIMEOUT_MS);
    const result = await rpc(session, 'tools/list', {}, 3, MCP_TEST_TIMEOUT_MS);
    const tools = isRecord(result) && Array.isArray(result['tools']) ? result['tools'] : [];
    const names = tools
      .filter(isRecord)
      .map((t) => (typeof t['name'] === 'string' ? t['name'] : ''))
      .filter((n) => n.length > 0);
    if (!names.includes(name)) {
      return {
        ok: false,
        detail: `Connected, but no "${name}" tool (found: ${names.join(', ') || 'none'})`,
        count: names.length,
      };
    }
    // eslint-disable-next-line no-console
    console.log('[rag] mcp test → ok');
    return { ok: true, detail: `Connected (${url.host}, tool "${name}")`, count: names.length };
  } catch (err) {
    const detail = err instanceof Error ? err.message : `Couldn't reach ${url.host}`;
    // eslint-disable-next-line no-console
    console.log('[rag] mcp test → fail');
    return { ok: false, detail };
  }
}

/** Extract the JSON payload from a tools/call result's `content` array: concat
 *  all `text` items and parse. Tolerant of the result already being structured. */
function extractToolJson(result: unknown): unknown {
  if (!isRecord(result)) return undefined;
  // Newer MCP returns `structuredContent` for JSON tools — prefer it.
  if (result['structuredContent'] !== undefined) return result['structuredContent'];
  const content = result['content'];
  if (!Array.isArray(content)) return undefined;
  const text = content
    .filter(isRecord)
    .filter((c) => c['type'] === 'text' && typeof c['text'] === 'string')
    .map((c) => c['text'] as string)
    .join('');
  return safeJsonParse(text);
}

/** Map an MCP rpc rejection to a content-free Error. */
function mapMcpError(err: unknown, host: string): Error {
  if (err instanceof Error && (err.message.startsWith('MCP error:') || err.message.startsWith('HTTP ') || err.message.startsWith('Malformed'))) {
    return err;
  }
  return mapFetchError(err, host, 'HTTP ');
}
