# ADR-0032: Vault-wide RAG — engine-side on-device embeddings + brute-force retrieval (Phase 6 slice 4)

- **Date:** 2026-06-03
- **Status:** Accepted
- **Deciders:** Dang Anh Tuan

## Context

Cross-meeting / 2nd-brain Q&A ("Ask Hark across the vault") needs semantic search over the whole
vault — meeting notes plus, via the **hybrid Obsidian direction** (BACKLOG, user 2026-06-02), an
external tool that syncs the user's Obsidian notes into the vault folder. The hard constraint
(rules #1/#5, ADR-0029/0031): **indexing must be fully local** — the whole vault must never be
sent out to embed; only the few retrieved chunks (redacted, if cloud) + the question may go to an
LLM at answer time, and a *local* LLM means zero egress. This ADR settles the architecture after a
two-thread research + design pass and a user sign-off on the embedder-runtime fork.

## Decision

**The Swift engine owns the entire local-retrieval pipeline; Electron main owns the egress; the
renderer gets a scope toggle + citations.**

- **Embeddings: `bge-small-en-v1.5` (384-dim) as CoreML, in the engine (ANE).** Reuses the
  existing WhisperKit/FluidAudio model-cache pattern (`HarkPaths.modelsDir()` →
  `~/Library/Application Support/Hark/Models/`, first-run download + ANE compile, progress frames).
  Chosen over **Node/ONNX (transformers.js)** — which would add a heavy native `onnxruntime-node`
  module, breaking ADR-0021's clean "no native node addon / single static binary" signing story —
  and over **local Ollama `/embeddings`**, which would require the user to install Ollama for vault
  Q&A to work at all. Engine-CoreML keeps the app bundle clean (the model is downloaded *data*, not
  a new Mach-O; the WordPiece tokenizer links statically), is ANE-fast, and keeps the engine
  network-free (local inference).
- **Vector store: brute-force in-memory cosine over a flat persisted file — NOT sqlite-vec for v1.**
  At personal scale (1k–50k chunks) that's ~1.5–77 MB RAM and **<80 ms/query** (vs the design's
  ≤200 ms budget) — *exact* KNN, zero new native dependency. sqlite-vec would pull a native
  `.node` + a loadable `vec0.dylib` (deep-sign under hardened runtime + a known electron-builder
  `dylib.dylib` footgun) — disproportionate at this scale. **Scale-up path (don't re-litigate):**
  migrate to sqlite-vec + an ANN index only past ~100k chunks; the storage location + chunk schema
  are identical, so it's a backend swap behind the same retrieval interface.
- **Index storage: app-data** (`~/Library/Application Support/Hark/index/` — `vectors.bin` +
  `meta.jsonl` + `manifest.json`), a **rebuildable cache** — never the vault. The vault is sacred
  + externally synced; the indexer **reads it, writes only app-data**.
- **Freshness:** an engine-side **FSEvents watcher, ~30 s debounced**, **content-hash-gated** so an
  atomic-save that only bumps mtime is skipped; on a real change, re-chunk/re-embed only that file;
  on delete, drop its chunks. `manifest.json` carries the embedding-model version → a model change
  triggers a one-time full rebuild. Full rebuild is first-run only (+ a manual "Rebuild index").
- **Chunking:** heading-aware, then ~256–512-token windows with ~10–15 % overlap; carry
  `notePath + headingPath + charRange` per chunk so an answer's citation deep-links to the source
  note (this fills the empty `[1][2]` citations Slice 3 deliberately left unfaked). Meeting files'
  `> **Speaker** · time` turns are natural units.
- **Wire contract (new `rag.*` frames):** `rag.retrieve` (UI→engine: `{ query, k, scope }` →
  engine embeds the query locally, brute-force top-K, returns `[{ text, notePath, headingPath,
  charRange, score }]`) and `rag.index_status` / progress (index building / counts). The engine
  never calls an LLM; it only returns local chunks.
- **Answer flow:** renderer Ask panel gains a **scope toggle (this meeting | vault)**. For vault
  scope: renderer → `rag.retrieve` (engine, local) → top-K chunks → `llm.ask` (main) redacts the
  chunks + question for cloud (or sends as-is for local) → LLM → answer + **citations** rendered
  from the chunk metadata. Only the redacted top-K ever leaves; local LLM ⇒ zero egress.

## Alternatives considered

- **Node/ONNX (transformers.js) embeddings in main.** ✅ least code, one process, out-of-box.
  ❌ adds `onnxruntime-node` (heavy native module) → breaks ADR-0021's clean packaging/signing
  invariants. **Rejected** (user sign-off).
- **Local Ollama `/embeddings`.** ✅ least code, cleanest packaging. ❌ vault Q&A wouldn't work
  without the user installing/running Ollama; risk of pointing the embed endpoint at a cloud API.
  **Rejected** as the default (keep as a future optional embed provider).
- **sqlite-vec for v1.** ✅ scales, persistent. ❌ native `.node` + `.dylib` + deep-signing +
  electron-builder footgun, for no benefit at personal scale where brute-force is <80 ms.
  **Rejected for v1**; the documented scale-up target.
- **Index in the vault (`.index/`).** ❌ makes Hark a constant autonomous writer in the sacred,
  externally-synced vault. **Rejected** — app-data cache.

## Consequences

**Positive** — fully local indexing (vault never egresses to embed); ANE-fast; app bundle stays
clean (no new native node module, single static engine binary); engine stays network-free; only
redacted top-K leaves, local LLM = zero egress; citations finally light up; clean scale-up path.

**Negative / accepted** — the most engine work of the three options: a new CoreML embedder + a
WordPiece tokenizer dependency + new `rag.*` wire frames + the index/watcher subsystem. The
`bge-small` CoreML artifact must be obtained or converted (community CoreML conversions are stale →
likely a `coremltools` conversion we own + validate — a build risk to spike first). A new Swift
tokenizer dep (`swift-transformers`) can network-fetch → **document under rule #6** and pin its use
to the offline tokenizer + the sanctioned model-cache download.

## Build sub-slices

1. **4a — engine embedder (spike-first):** obtain/convert `bge-small` CoreML, integrate the
   WordPiece tokenizer, embed text → L2-normalized 384-dim, unit-tested (similar sentences close).
   The foundational + riskiest piece (model conversion).
2. **4b — index + retrieval:** chunker, flat-file vector store + brute-force search, FSEvents
   watcher (30 s + content-hash), the `rag.retrieve` + `rag.index_status` wire frames.
3. **4c — main + renderer:** main wires `rag.retrieve` → `llm.ask` (redact chunks); renderer adds
   the scope toggle + renders citations from chunk metadata.

## Open questions

- Exact `bge-small` query prefix + pooling; CoreML conversion validation on-device.
- Re-rank step (later); spend-aware chunk budget; multilingual notes (bge-small is en).

## References

- ADR-0029 (egress in main; engine network-free), ADR-0030 (keys), ADR-0031 (redaction + log),
  ADR-0021 (packaging — why we avoid native node modules / dylibs), ADR-0027 (privacy model).
- Research (this session): engine model-load pattern (`ModelLoader.swift`, `HarkPaths.swift`,
  `DiarizerLoader.swift`); brute-force vs sqlite-vec scale numbers; chunking + watcher.
- Design: `hark-docs/docs/design/07-data-flows.md` (RAG sequence, ≤200 ms / <60 s budgets),
  `06-architecture-overview.md`. `docs/BACKLOG.md` — Slice 4 (now design-locked).
