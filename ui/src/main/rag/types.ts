// External retrieval-backend types (ADR-0033/0034).
//
// The EXTERNAL vault-retrieval backend is a user-run, LOCAL retrieval service
// Hark's main process queries as a client (the built-in backend retrieves in
// the engine instead — see ADR-0032). Main supports two loopback transports,
// hand-rolled with raw `fetch` (no SDK, per ADR-0029): plain HTTP and a minimal
// MCP-over-HTTP client.
//
// PRIVACY: the endpoint MUST be loopback (ADR-0034) — retrieval results are
// vault content flowing back INTO Hark; a remote backend would put vault
// content on the network. The backend NEVER sees the API key and NEVER calls an
// LLM; main owns the downstream redact→LLM→log→citations path (ADR-0029/0031).

/** Which transport an external backend speaks. */
export type RagTransport = 'http' | 'mcp';

/** The retrieval-backend selection (mirrors `prefs.rag`). `builtin` ⇒ the
 *  engine handles retrieval over the WebSocket (this module is not involved);
 *  `external` ⇒ main queries the configured loopback service here. */
export type RagBackendConfig =
  | { backend: 'builtin' }
  | {
      backend: 'external';
      external: {
        transport: RagTransport;
        /** Loopback URL. For 'http' the POST retrieve endpoint; for 'mcp' the
         *  Streamable-HTTP MCP endpoint. Validated loopback-only before any fetch. */
        endpoint: string;
        /** MCP only: the search tool name to call. Defaults to 'search'. */
        toolName?: string;
      };
    };

/**
 * One retrieval hit returned to the renderer — the SAME shape the built-in
 * engine path produces (renderer `RagResultChunk`), so the Ask panel renders
 * both identically (4c). External backends supply `source` + optional
 * `headingPath`/`score`; we map `source → note_path`, `headingPath →
 * heading_path`, and set `char_start/char_end = 0` (external backends own their
 * own addressing — the built-in offsets power a future jump-to-source).
 */
export interface RetrievedChunk {
  text: string;
  note_path: string;
  heading_path: string;
  char_start: number;
  char_end: number;
  score: number;
}

/** The raw chunk shape an external backend returns (ADR-0033 contract):
 *  `{ text, source, headingPath?, score? }`. All untrusted — coerced on read. */
export interface ExternalChunk {
  text: string;
  source: string;
  headingPath?: string;
  score?: number;
}

/** Result of a `testConnection()` probe against an external backend — a
 *  one-line, content-free verdict (mirrors LlmTestResult). `count`, when known,
 *  is how many hits a canned probe query returned / how many tools were listed. */
export interface RagConnectionResult {
  ok: boolean;
  detail: string;
  count?: number;
}
