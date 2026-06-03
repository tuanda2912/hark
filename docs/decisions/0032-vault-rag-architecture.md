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

- **Embeddings: an on-device CoreML embedder in the engine (ANE), from a small curated set of
  LOCAL models, defaulting to a MULTILINGUAL one** (refined 2026-06-03 — was a hardcoded
  `bge-small-en-v1.5`). Reuses the WhisperKit/FluidAudio model-cache pattern
  (`HarkPaths.modelsDir()` → `~/Library/Application Support/Hark/Models/`, first-run download + ANE
  compile, progress frames). Chosen over **Node/ONNX (transformers.js)** — a heavy native
  `onnxruntime-node` module that breaks ADR-0021's clean "no native node addon / single static
  binary" signing story — and over **local Ollama `/embeddings`** as the default, which would
  require the user to install Ollama for vault Q&A to work at all. Engine-CoreML keeps the app
  bundle clean (the model is downloaded *data*, not a new Mach-O; tokenizers link statically), is
  ANE-fast, and keeps the engine network-free.
  - **Why multilingual default:** Hark's audience runs meetings/notes in Vietnamese / Thai /
    English; an English-only embedder (`bge-small-en`) retrieves poorly on non-English notes. The
    v1 default is therefore a **384-dim multilingual** model (`multilingual-e5-small`), keeping the
    index schema fixed at 384-dim.
  - **Curated set, user-choosable (local-only):** Settings exposes a small dropdown of Hark-shipped
    local embedders — e.g. `multilingual-e5-small` (default, multilingual) and `bge-small-en-v1.5`
    (English-optimized). All v1 options are **384-dim** so the index schema is constant. Each
    curated model carries its tokenizer + a validated CoreML conversion — the set spans **WordPiece**
    (bge / MiniLM) and **SentencePiece** (e5 / multilingual-e5), both supported by
    `swift-transformers`. The embedder may NEVER be a *cloud* endpoint — indexing embeds the whole
    vault, so a cloud embedder would egress all of it (the hard local-indexing invariant).
  - **Changing the embedder ⇒ full re-index.** Vectors are embedder-specific; `manifest.json`
    records the model id+version, and selecting a different embedder invalidates the index and
    triggers a one-time rebuild (~<60 s / 1k notes). It is a "pick it, re-index if you change it"
    setting, not a per-query toggle.
  - **Deferred (later tier):** a power-user override to point embeddings at a **local**
    Ollama/llama.cpp embedding endpoint (loopback-guarded so it can never egress) — open-ended
    model choice without Hark shipping a conversion. Not v1.
- **Vector store: brute-force in-memory cosine over a flat persisted file — NOT sqlite-vec for v1.**
  At personal scale (1k–50k chunks) that's ~1.5–77 MB RAM and **<80 ms/query** (vs the design's
  ≤200 ms budget) — *exact* KNN, zero new native dependency. sqlite-vec would pull a native
  `.node` + a loadable `vec0.dylib` (deep-sign under hardened runtime + a known electron-builder
  `dylib.dylib` footgun) — disproportionate at this scale. **Scale-up path (don't re-litigate):**
  migrate to sqlite-vec + an ANN index only past ~100k chunks; the storage location + chunk schema
  are identical, so it's a backend swap behind the same retrieval interface.
- **Index storage: app-data** (`~/Library/Application Support/Hark/index/` — `vectors.bin` +
  `meta.jsonl` + `manifest.json`), a **rebuildable cache** — never the vault. The vault is sacred
  + externally synced; the indexer **reads it, writes only app-data**. **Offset-only (decision
  2026-06-03):** `meta.jsonl` holds **pointers/offsets ONLY** — `chunk_id`, `note_path`,
  `heading_path`, `char_start`, `char_end`, `content_hash` — and **never the raw note text**.
  Rationale: raw note text is never persisted outside the vault, so **deleting a note from the
  vault removes its content** (nothing lingers in the cache). At retrieve time the engine **reads
  the snippet live from the vault** at the stored `[char_start, char_end)` offsets, **skipping any
  chunk whose source file is missing (deleted) or changed-since-index** (live whole-file hash ≠ the
  note's recorded hash → stale offsets aren't trusted), so results stay honest. This retrieve-time
  vault read is **read-only** (a single read per distinct note per query, zero writes). Removing the
  `text` field changed the on-disk format → `schema_version` bumped (1 → 2); a pre-existing v1
  index rebuilds on first launch. The `rag.results` wire shape is unchanged (still `{ text, … }`) —
  only the SOURCE of `text` changed (vault read vs cache).
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
**Offset-only** strengthens rule #2/#4: the cache holds no vault prose, so deleting a note erases
its content everywhere (no stale copy in app-data), and a half-stale cache can never surface text
that no longer matches the vault — the live read + hash gate drops it instead.

**Negative / accepted** — the most engine work of the three options: a new CoreML embedder + a
WordPiece tokenizer dependency + new `rag.*` wire frames + the index/watcher subsystem. The
`bge-small` CoreML artifact must be obtained or converted (community CoreML conversions are stale →
likely a `coremltools` conversion we own + validate — a build risk to spike first). A new Swift
tokenizer dep (`swift-transformers`) can network-fetch → **document under rule #6** and pin its use
to the offline tokenizer + the sanctioned model-cache download.

## Build sub-slices

1. **4a — engine embedder (spike-first):** obtain/convert the **default `multilingual-e5-small`**
   CoreML (384-dim) + integrate its **SentencePiece** tokenizer, embed text → L2-normalized
   384-dim, unit-tested (similar sentences close; a VI/TH/EN cross-language sanity check). Build
   the loader so a second curated model (`bge-small-en`, WordPiece) can slot in behind the same
   interface. The foundational + riskiest piece (model conversion + the SentencePiece tokenizer).
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
