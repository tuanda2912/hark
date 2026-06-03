# ADR-0033: Pluggable vault-retrieval backend — built-in engine OR external local MCP, user-chosen

- **Date:** 2026-06-03
- **Status:** Accepted
- **Deciders:** Dang Anh Tuan

## Context

ADR-0032 designed vault RAG as an **in-engine built-in** (CoreML embedder + brute-force index +
watcher). The 4a spike confirmed that path is viable but means **Hark owns a CoreML model
conversion + hosting the `.mlpackage` + a tokenizer dep + the index/watcher** — real ongoing
weight. Separately, the user already runs an **external Obsidian-ingestion tool** and wants the
2nd-brain index to be a **reusable local asset** (usable by other MCP clients, not just Hark).
Neither pure choice wins outright: built-in is out-of-box but heavy + Hark-locked; external is lean
+ reusable but needs a running service. So **don't force one — make retrieval pluggable and let the
user choose at onboarding** (user decision, 2026-06-03).

## Decision

A **`RetrievalBackend` abstraction** in Hark with two implementations behind one interface
(`retrieve(query, k, scope) → [{ text, source, headingPath?, score }]`):

- **Built-in (default, out-of-box):** the engine's CoreML embedder + brute-force in-memory index +
  FSEvents watcher, exactly per **ADR-0032**. Fully self-contained; nothing external to run.
- **External:** a **user-run local retrieval service** — recommended as a **loopback MCP server**
  (so the same index is reusable by Claude Desktop, the user's scripts, any MCP client) — that
  exposes a `search`-style tool. Hark connects as a **client**. A plain local HTTP contract is an
  acceptable alternative transport.

**Chosen at onboarding**, changeable in **Settings → (Knowledge/RAG)**: *"Where should Hark search
your notes? **Built-in** (works out of the box) · **Connect my own** (external tool / MCP server)."*
Default **built-in**. Users who pick external **don't need Hark's CoreML embedder model at all**
(the built-in model download is skipped) — that's the leanness win for that audience.

**Downstream is identical and stays in Hark regardless of backend:** whichever backend returns the
top-K chunks, **Hark's main process redacts (for cloud), calls the LLM, logs the call, and renders
citations** — the egress chokepoint + governance (ADR-0029/0031) never move. The backend only does
*local retrieval*; it never calls an LLM and never sees the API key.

**Privacy guardrails:**
- The external backend **MUST be loopback-only** (`localhost`/`127.0.0.1`/`::1`). Hark **refuses a
  non-local retrieval endpoint** — retrieval results are vault content flowing *back into* Hark, so
  a remote backend would put vault content on the network. Same loopback rule as the embedder/LLM.
- The external backend is responsible for indexing **locally** (the user's choice/assurance);
  Hark *guarantees* local indexing only for the built-in backend. The onboarding copy states this.
- Either way, only the **redacted top-K + question** ever leave Hark (cloud LLM), and a **local
  LLM ⇒ zero egress** — unchanged from ADR-0031.

## Alternatives considered

- **Built-in only (ADR-0032 as-is).** ❌ no reuse of the user's external index; Hark carries the
  whole model/index pipeline for everyone. **Rejected** — user wants the external option.
- **External only.** ❌ no out-of-box vault search; broken for anyone not running a backend.
  **Rejected** — loses the product story.
- **Pluggable (this ADR).** ✅ serves product (built-in default) AND power-user (external/reusable).
  ❌ the most work (two backends + abstraction + onboarding + the MCP contract). **Accepted** — the
  user explicitly chose it.

## Consequences

**Positive** — out-of-box for newcomers, reusable/lean for power users; the built-in CoreML model
becomes *optional* (skipped when external is chosen); the egress governance is unchanged + lives in
one place; a clean MCP contract makes the 2nd brain a shared local asset.

**Negative / accepted** — two retrieval code paths + an abstraction + an onboarding step + the
external contract to define/maintain/audit. The built-in path still needs the ADR-0032 work
(finish 4a's CoreML conversion + 4b). The external path needs an MCP/HTTP client in main + the
loopback guard + a "test connection / index status" affordance.

## Build plan (supersedes ADR-0032's 4a–4c sequencing with a backend split)

1. **Retrieval interface + backend selector** (main): `RetrievalBackend` + config (`builtin` |
   `external{ transport, endpoint }`), surfaced at onboarding + Settings; default built-in.
2. **Built-in backend:** finish ADR-0032's 4a (run the shipped coremltools conversion for
   `multilingual-e5-small`, publish the `.mlpackage`, on-device test) + 4b (index + watcher +
   `rag.retrieve`/`rag.index_status` frames).
3. **External backend:** a loopback **MCP client** (or local HTTP) in main implementing the same
   `retrieve(...)` interface + a connection/index-status check + the loopback guard.
4. **Shared answer path** (4c): backend → top-K → redact (cloud) → `llm.ask` → answer + citations;
   Ask-panel scope toggle (this-meeting | vault). Identical for both backends.

## References

- ADR-0032 (built-in RAG design — now "the built-in backend"), ADR-0029 (egress chokepoint in
  main), ADR-0031 (redaction + log), ADR-0023 (onboarding), ADR-0027 (privacy model).
- The hybrid Obsidian direction (BACKLOG); 4a spike (this session) — built-in embedder scaffolding
  + the CoreML conversion recipe (parked, uncommitted, pending the build of the built-in backend).
