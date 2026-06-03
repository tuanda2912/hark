# ADR-0034: External retrieval transport — hand-rolled loopback HTTP + minimal MCP-over-HTTP (no SDK)

- **Date:** 2026-06-03
- **Status:** Accepted
- **Deciders:** Dang Anh Tuan

## Context

ADR-0033 made vault retrieval **pluggable**: a `RetrievalBackend` with two impls —
**built-in** (engine CoreML embedder + index, shipped in slices 4a/4b/4c) and **external** (a
user-run *local* retrieval service). ADR-0033 left the external **transport as a config field**
(`external{ transport, endpoint }`), recommended a **loopback MCP server** (so the same 2nd-brain
index is reusable by Claude Desktop / other MCP clients — the user's stated motivation), and
accepted **plain local HTTP** as an alternative. This ADR pins HOW Hark's main process talks to
that service, and where the code lives.

The hard constraints are unchanged: the external backend is **loopback-only** (retrieval results
are vault content flowing *back into* Hark — a remote backend would put vault content on the
network); the **redact → LLM → log → citations** path stays in main (ADR-0029/0031) regardless of
backend; the backend only does *local retrieval* and never sees the API key.

## Decision

**The external backend is a client in Electron MAIN (`src/main/rag/`), hand-rolled with raw
`fetch` — NO MCP SDK, NO new dependency** — consistent with ADR-0029's "raw fetch, no SDK" choice
for the LLM provider layer. It supports **two transports**, chosen by config:

- **`http` (plain loopback HTTP):** `POST <endpoint>` with JSON `{ query, k, scope }` →
  `200 { chunks: [{ text, source, headingPath?, score? }] }`. The simplest contract; a ~20-line
  local server satisfies it. No second endpoint — *test connection* is a canned retrieve (`k:1`).
- **`mcp` (MCP over Streamable HTTP, loopback):** a minimal JSON-RPC client doing `initialize` →
  (`notifications/initialized`) → `tools/call { name: toolName, arguments: { query, k } }`,
  carrying any `Mcp-Session-Id` the server returns and accepting either a single JSON-RPC response
  or an SSE (`text/event-stream`) one. The tool's text result is parsed as `{ chunks: [...] }` or a
  bare chunk array. *Test connection* = `initialize` + `tools/list` and assert `toolName` exists.
  This is the "reusable local asset" path — the same MCP server serves any MCP client.

**Why hand-rolled, not `@modelcontextprotocol/sdk`:** (1) ADR-0029 already set the precedent —
main speaks HTTP protocols with raw `fetch` and no vendor SDK, keeping the bundle lean and the
egress surface auditable; (2) rule #6 (any network-socket dependency needs an ADR) — a hand-rolled
`fetch` client adds no new dependency to audit/sign; (3) we use a *tiny* slice of MCP (one tool
call), so the SDK's full surface is overkill. If a future need (resources, prompts, notifications,
OAuth) outgrows the hand-rolled client, revisit the SDK in a new ADR.

**Where the branch lives:** the built-in backend retrieves in the **engine** (renderer →
`rag.retrieve` over the loopback WebSocket, ADR-0032). The external backend retrieves in **main**
(renderer → `hark:rag:retrieve` IPC → main's loopback client). So the **renderer** picks the path
per `prefs.rag.backend`; main's `rag/` module is the **external client only**. Both produce the
SAME `RagResultChunk` shape the Ask panel already renders (4c) — external chunks map
`source → note_path`, `headingPath → heading_path`, and carry `char_start/char_end = 0` (the
external backend owns its own addressing; the built-in offsets power a future jump-to-source).

**Config (`prefs.rag`, mirrors the `llm` block):**
`{ backend: 'builtin' | 'external', external?: { transport: 'http' | 'mcp', endpoint: string, toolName?: string } }`.
Default **builtin**. Sanitized like `llm`: a missing/malformed block ⇒ builtin (the safe,
out-of-box default). No secret lives here.

**Loopback guard (the privacy gate):** before ANY fetch, `endpoint`'s host MUST be
`localhost` / `127.0.0.1` / `::1` (same check as `isLocalEgress`). A non-loopback endpoint is
**refused** with a clear error — it never reaches the network. Unparseable ⇒ refused.

## Alternatives considered

- **`@modelcontextprotocol/sdk` client.** ✅ spec-complete, handles SSE/sessions/OAuth. ❌ a new
  networked dependency (rule #6 ADR + signing surface), against ADR-0029's no-SDK grain, for a
  one-tool use. **Rejected for v1** — revisit if MCP usage grows.
- **MCP over stdio (spawn the server).** ✅ no port. ❌ no "loopback endpoint" to guard, Hark
  manages a subprocess lifecycle, and it's *not* the reusable-shared-server model ADR-0033 wants
  ("reusable by other MCP clients"). **Rejected** — the endpoint+loopback-guard framing is HTTP.
- **Plain HTTP only.** ✅ simplest, no MCP complexity. ❌ drops the reuse-by-other-MCP-clients
  motivation. **Rejected as the only option** — shipped as one of the two transports.

## Consequences

**Positive** — no new dependency; one auditable egress style (raw fetch, loopback-guarded); the
external backend is usable by a trivial HTTP server today AND by a real MCP server (reusable);
downstream egress governance is untouched and single-sited (ADR-0029/0031).

**Negative / accepted** — a hand-rolled MCP client covers only the slice we use (initialize +
tools/call, JSON or basic SSE); exotic servers (mandatory streaming chunked over many SSE events,
OAuth-gated, resource-based) aren't supported until we adopt the SDK. The external backend's
*local indexing* is the user's assurance, not Hark's guarantee (only built-in guarantees local
indexing) — the onboarding/Settings copy states this (ADR-0033). char offsets are absent for
external chunks (jump-to-source by offset is built-in-only).

## References

- ADR-0033 (pluggable backend — this is its external transport), ADR-0032 (built-in backend),
  ADR-0029 (egress chokepoint in main; raw fetch / no SDK precedent), ADR-0031 (redaction + log),
  ADR-0030 (keys — N/A here, backend never sees a key), ADR-0027 (privacy model).
