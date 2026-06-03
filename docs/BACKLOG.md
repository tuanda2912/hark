# Hark — Deferred Work Backlog

The **"better, but not now" ledger.** Every time we make a deliberate scope cut — a
change that would make Hark a better product but that we chose to defer — it gets
written here with enough context to finish it later, so nothing quietly rots.

This is the *product-improvement* backlog. It is distinct from `STATUS.md` "Open threads"
(technical watch-items / latent risks) and from ADR "Open questions" (decision-specific).
When an item here is done, move it out (cite the commit) — don't let this list lie.

**Format per item:** what it is · why we deferred · where to pick up (files / ADR refs).
Add new items under the right area; create a new area if none fits.

_Last updated: 2026-06-02_

---

## Packaging & distribution (active — Phase 5/7)

- **Notarization + stapling.** The final step to a Gatekeeper-clean, double-clickable app
  that runs on *other* people's Macs without the "unidentified developer / damaged" block.
  - *Deferred because:* requires a **paid Apple Developer Program** membership ($99/yr) and
    a **Developer ID Application** certificate. The dev flow uses a *free* "Apple Development"
    cert (`engine/scripts/sign-dev-bundle.sh`), which **cannot** notarize.
  - *Pick up:* `@electron/notarize` afterSign hook + `notarytool` + `stapler`. We build the
    app **notarization-ready** now (hardened runtime + entitlements), so this is the last mile
    once a Developer ID is available. Packaging ADR (TBD) will record the signing chain.
- **Configurable vault location.** The vault path is fixed at `~/Documents/vault/hark`
  (main `VAULT_DIR` + the engine's `VaultWriter`). The onboarding Setup screen (ADR-0023) and
  Settings show a folder picker, but it's disabled until this lands.
  - *Pick up:* a vault-path pref + a folder picker (`dialog.showOpenDialog`), plumbed to the
    engine so `VaultWriter` writes there. Makes onboarding screen-3 fully match the design.
- **Anthropic API key storage (Keychain).** The onboarding Setup screen + the design show an
  optional API-key field — "stored in macOS Keychain, we never see your key." Disabled until
  Phase 6 (the key has nothing to authenticate against yet).
  - *Pick up:* a Keychain-backed secure store (main process) + the key field; gates the cloud
    features (summary/translation/Q&A). Part of Phase 6.
- **App icon.** No `ui/build/icon.icns` exists; electron-builder warns and falls back to the
  default Electron icon. Fine for the unsigned dry-run, not for a release.
  - *Pick up:* drop a 1024px `icon.icns` (or `.png`, electron-builder converts) at `ui/build/`.

## LLM / model providers (Phase 6 — integration deferred, UI-first)

The product supports **multiple model providers — cloud AND local** — not just Claude
(user directive, 2026-06-02). Local models are a privacy win: summaries / Q&A / translation
with **zero data leaving the machine**, making cloud one *option*, not the only path. The UI
is being built **provider-agnostic now**; the integration lands later.

- **Provider abstraction + foundation — SHIPPED (Slice 1).** Pluggable LLM layer in **Electron
  main** (ADR-0029): Anthropic-native + OpenAI-compatible (covers OpenAI / Gemini / OpenRouter
  cloud AND local Ollama / LM Studio / llama.cpp on `localhost`), raw `fetch` (no SDK). Cloud
  key in macOS Keychain via `safeStorage` (ADR-0030); local needs none. Settings → Models pane
  (provider / model / baseUrl / key / Test connection); `modelConfigured()` gate live. Engine
  stays network-free; CSP unchanged. Privacy-audited PASS.
- **Meeting summary — SHIPPED (Slice 2).** "Summarize" on the saved card → renderer builds the
  transcript → `llm.summarize` in main → (redact if cloud) → Anthropic/OpenAI-compatible
  completion → summary panel + receipt → "Save to note" writes `## Summary` to the vault via the
  engine (`summary.write` → `VaultWriter.appendSummary` + git-commit). Cloud-call log + Settings
  Cloud-activity list shipped. Local model ⇒ full transcript, zero egress. ADR-0031. Audited PASS.
  - *Redaction v1 gaps (ADR-0031 §3, deferred to NER):* regex catches email/url/money/phone/
    long-numbers + known roster names; it does NOT catch zip-style 5–6 digit numbers, word-form
    currency ("50 dollars"), or arbitrary free-text names. The receipt is honest (claims a count,
    not "all PII removed"). *Pick up:* a local NER pass for names + a user-facing redaction toggle.
  - *Non-streaming v1:* the summary returns whole (≤60s), no token streaming. *Pick up:* SSE
    streaming over IPC for a live-typing summary (design wants it; deferred for simplicity).
- **This-meeting Q&A — SHIPPED (Slice 3).** The Ask panel is wired: a question + the current
  meeting transcript → `llm.ask` in main → (redact question AND transcript if cloud) →
  grounded answer ("answer only from this transcript; say you don't know rather than invent").
  Same egress governance + cloud-log (`action:'qa'`) as summary; local ⇒ zero egress. ADR-0031.
  - *Deferred:* rich `[1][2]` **citations / source cards** are left empty (NOT faked) — they need
    retrieval / structured output, which arrives with the vault-RAG slice. Answer streaming also
    deferred (non-streaming v1, like summary).
- **Vault-wide / 2nd-brain Q&A — RAG (Slice 4) — DESIGN-LOCKED (ADR-0032 + ADR-0033), build
  pending. PLUGGABLE backend (ADR-0033):** the user chooses at onboarding — **built-in** Hark
  (engine embedder + index per ADR-0032, out-of-box, default) **or external** (their own local
  retrieval service, ideally a **loopback MCP server**, reusable by other MCP clients). Both feed
  the same redact→LLM→citations path in main; the external endpoint must be loopback-only. Whoever
  picks external skips Hark's CoreML model entirely.
  Cross-meeting questions over the whole vault. Cloud model NEVER sees the vault: **local** embed
  → **local** vector search (top-K) → only the redacted top-K chunks + question go to the model →
  answer + citations. Local model ⇒ zero egress. **Decisions (ADR-0032):** a curated set of LOCAL
  **CoreML embedders in the engine** (ANE, model-cache pattern), **defaulting to multilingual**
  `multilingual-e5-small` (384-dim) for VI/TH/EN notes + an English `bge-small-en` option,
  user-choosable in Settings, **local-only** (never a cloud embed endpoint) and **re-index on
  change**; **brute-force in-memory cosine over
  a flat file** (NOT sqlite-vec for v1 — <80 ms at 50k chunks, no native dep; sqlite-vec is the
  >100k scale-up); index in **app-data** (not the vault); engine **FSEvents watcher (30 s +
  content-hash)**; heading-aware chunking with `notePath/headingPath/charRange` for citations; new
  `rag.retrieve` + `rag.index_status` wire frames; renderer scope toggle (this-meeting | vault).
  - **Obsidian 2nd-brain (HYBRID):** the user's external tool syncs Obsidian → the vault folder
    (Markdown); Hark **reads** it and owns the local index (writes only app-data). Obsidian can
    point at the vault directly (`[[wikilinks]]` parsing is a separate backlog item).
  - **Build plan (ADR-0033 backend split) — ALL FOUR DONE (2026-06-03):** (1) ✅ `RetrievalBackend`
    selector + onboarding/Settings choice (default built-in); (2) ✅ **built-in backend** (4a+4b+4c
    below); (3) ✅ **external backend** — loopback MCP/HTTP client in main + connection check +
    loopback guard; (4) ✅ shared answer path — backend → redact → `llm.ask` → answer + citations +
    Ask-panel scope toggle. Built-in vault RAG is end-to-end usable today; external is selectable +
    configurable in Settings. **Remaining before SHIPPING built-in:** publish the FP16
    `.mlpackage` (deploy TODO under 4a status).
  - **4a status — DONE + on-device validated (2026-06-03).** Engine `TextEmbedder` (CoreML, ANE)
    + loader (+ `HARK_EMBEDDER_LOCAL_DIR` dev override) + curated registry + `swift-transformers`
    1.3.3. The `multilingual-e5-small` CoreML conversion (`scripts/convert-embedder-coreml.py`)
    was run on-device; the gated cross-lingual test (EN↔TH/VI closer than unrelated) **passes on
    ANE**. 123 engine tests green; privacy-audited PASS (network use = the routed model download
    only).
    - **Deploy / model hosting — DONE (2026-06-03).** The base conversion is already **fp16**
      (~224 MB); `scripts/quantize-embedder-int8.py` int8-quantizes it to **~113 MB**
      (fp16↔int8 cosine 0.99986, both gated on-device tests green). Published to
      **`tuanda2912/hark-multilingual-e5-small-coreml`** (public, MIT) via
      `scripts/publish-embedder-hf.sh`; `EmbedderModels.swift` pins that repo + revision
      `0a386d4…`. **Production first-run path validated end-to-end (no env override):** a clean
      run downloaded from HF (24 s), ANE-compiled (6 s), and both the cross-lingual + full
      retrieve tests passed; the second run hit the cache (no re-download). Built-in vault RAG is
      now shippable. Considered + rejected reusing `tamikisg/multilingual-e5-small-coreml` — its
      output is a pre-pooled `[1,384]` with a fixed 256 seq + unstated pooling, incompatible with
      our `last_hidden_state` + flexible-512 + masked-mean-pool loader. Optional later: cache the
      compiled `.mlmodelc` under `HarkPaths` to skip recompiles.
  - **4b status — DONE + on-device validated (2026-06-03).** Heading-aware `RagChunker`,
    `RagIndex` (brute-force cosine over `vectors.bin` + `meta.jsonl` + `manifest.json`),
    `RagIndexer` (cold build + FSEvents watcher + incremental + retrieve), and the
    `rag.retrieve`/`rag.results`/`rag.index_status` wire frames. **Offset-only** (decision
    2026-06-03): `meta.jsonl` holds pointers only (no raw note text); retrieve reads the snippet
    live from the vault at the stored offsets and skips any file deleted/changed since index.
    168 engine tests green incl. the real-embedder end-to-end + the FSEvents SIGSEGV fix
    (`kFSEventStreamCreateFlagUseCFTypes`). Privacy-audited PASS.
  - **4c status — DONE (2026-06-03).** UI wiring: renderer `EngineService.retrieve()` (the one
    request/reply exchange on the socket, id-correlated `rag.retrieve`→`rag.results`, with
    timeout + socket-close cleanup) + a `ragIndexStatus` signal; main `ask()` gains a **vault
    scope** that builds a numbered-Sources prompt and (cloud) redacts EACH chunk independently;
    Ask-panel **this-meeting | vault** scope toggle + index indicator; host orchestration
    (retrieve → llm.ask → numbered source cards from chunk metadata). The empty `[1][2]`
    citations Slice 3 left are now real source cards. Renderer makes no network call; engine
    never calls a model. Live WS smoke proves the round-trip on-device. ADR-0032/0033.
    - *Cold-start ordering — FIXED in 4c.* The RAG embedder used to load in `HarkdCommand`
      strictly AFTER WhisperKit + the diarizer (sequential `await`s), so on a cold start vault
      search was `RAG_UNAVAILABLE` for the *minutes* the large-v3 ANE compile takes — even though
      RAG is independent of capture. Now loaded in a **detached `Task` launched before** the
      WhisperKit await, so the embedder + index come up concurrently with (and never wait behind)
      the speech model. The 4c smoke confirms it: vault retrieval returned 5 hits while
      `meta.hello` still reported `model_loaded=(loading)`.
    - *Jump-to-source (pick up):* source cards + inline `[n]` are display-only. Wire the
      `citation-chip` / source-card `select` to open the note at `char_start` (Finder reveal, or
      an in-app note view) — the chunk already carries `note_path` + offsets. Also: inline `[n]`
      renders as plain text in the answer prose; a later pass can split the prose and render real
      chips inline.
  - **External backend — DONE (2026-06-03), ADR-0034.** Pluggable retrieval is complete: a
    `RetrievalService` (renderer) routes vault Ask to the built-in engine index OR a user-run
    LOCAL service per `prefs.rag.backend`. Main's `src/main/rag/` is a hand-rolled (no SDK, raw
    `fetch`) loopback client with two transports — plain HTTP (`POST {query,k,scope}`→`{chunks}`)
    and minimal MCP-over-HTTP (`initialize`→`tools/call`, JSON or SSE). Loopback guard before every
    fetch + `redirect:'error'` (SSRF). Settings → "Vault search" picks backend + transport +
    endpoint + tool name + Test connection; onboarding has a built-in/external choice. 12-check
    transport smoke + privacy-audited PASS (7/7).
    - *Deferred (external backend):* (1) **live index-status for external** — the Ask-panel
      indicator shows a static "Using your external backend" label (we don't poll the external
      index state); a future `rag.index_status`-equivalent over the bridge could surface
      building/ready. (2) **MCP client is minimal** — initialize + tools/call + tools/list only
      (no resources/prompts/notifications/OAuth, no mandatory multi-event SSE streaming); adopt
      `@modelcontextprotocol/sdk` (new ADR) if a real server outgrows it. (3) **session reuse** —
      the MCP client re-`initialize`s per retrieve (fine at Q&A frequency; cache the session if it
      becomes hot). (4) external chunks carry no char offsets ⇒ no jump-to-source-by-offset.
  - *Renderer/main RAG unit tests (pick up):* the engine side is unit-tested (Swift) + the
    external transports have a Node smoke (`/tmp`, not committed), but the renderer
    (`RetrievalService`, `EngineService.retrieve` correlation) + the main `rag/` transports have no
    committed test runner. Stand up vitest (or `node --test` over the compiled main) and lock the
    loopback guard + `redirect:'error'` + correlation/timeout in (privacy-auditor LOW note).
- **Cloud-call log + PII redaction — SHIPPED (Slice 2).** Every cloud call redacts PII first +
  logs metadata-only; surfaced in Settings → Privacy "Cloud activity". Local calls need neither.
  (NER name redaction + a redaction toggle remain deferred — see the summary entry.)

## Speaker / diarization (Phase 5.1)

- **Rename arbitrary PAST meetings.** `speaker.rename` (ADR-0020) MVP only renames the
  **most-recently-saved** meeting (the one the engine still holds in memory).
  - *Deferred because:* renaming an old meeting needs a meeting-browser UI + reloading or
    re-parsing the saved file's snapshot. MVP scope kept it to the live toast.
  - *Pick up:* meeting browser + persist/reload `SavedMeetingSnapshot` (or re-parse markdown).
    See ADR-0020 "Open questions". Manual markdown edit is the interim escape hatch.
- **Speaker enrollment + cross-meeting recognition.** Turn "Speaker N" into known people
  automatically. `vault/.speakers/*.json` voiceprints + cosine matching (rule #5: stays local).
  - *Deferred because:* Phase 5.1; the rename MVP (ADR-0020) deliberately ships naming first.
  - *Pick up:* ADR-0016 / ADR-0020 references; the `speaker.rename` round-trip is the on-ramp.
- **Diarization clustering-threshold tuning.** Quick back-and-forth can mis-attribute speakers
  (the skew we saw). `HARK_DIAR_THRESHOLD` is the count-agnostic lever.
  - *Deferred because:* tuning against our only test clip (2-person) risks overfitting; can't
    validate N>2 safely without a real 3–4-person recording. Relabeling (ADR-0020) is the
    count-proof fix that made this non-urgent.
  - *Pick up:* record a 3–4-person clip, sweep `HARK_DIAR_THRESHOLD`, compare label splits.
    ADR-0017 flags the `OfflineDiarizerManager` defaults as needing real-meeting confirmation.
- **`Speaker ?` handling in the rename roster.** `applySpeakerNames` is roster-neutral; the
  unattributed "Speaker ?" bucket isn't surfaced for naming or stripped.
  - *Pick up:* decide whether to offer naming it or filter it (engine review LOW note, ADR-0020).
- **Rename success-confirmation frame.** Today the UI is optimistic and keys off bare `ack`;
  only *failures* surface. A `meeting.updated` frame (or a correlation `id` on the ack) would
  give a positive "renamed ✓".
  - *Pick up:* ADR-0020 "Open questions". Low priority — MVP UX is acceptable.

## Transcript quality

- **Source-level finalization strategy.** Residual duplication / run-on fragments on
  continuous, pause-less, repetitive narration aren't fully caught by post-hoc dedup +
  supersession (ADR-0018) + region finalization (ADR-0019). The robust fix: finalize each
  sentence once and dedup against finalized history *at the source*, not after the fact.
  - *Deferred because:* largely an adversarial-input edge; real meeting audio (pauses +
    turn-taking) segments far more cleanly. Tracked (also a spawned task).
- **Mid-sentence region boundaries.** Region-based finalization (ADR-0019) occasionally cuts a
  sentence at a region edge — a readability nit, not a correctness bug.
- **`sessionLanguage` nil in the secondary drain path.** A latent minor issue flagged during
  the content-loss fix; the secondary drain doesn't thread the session language hint.
- **Trailing `"."` segment artifact.** WhisperKit end-of-stream quirk; agreed to filter at the
  UI layer rather than mask at the engine boundary (STATUS open thread #1).

## Wire contract / docs debt

- **`error.code` catalog reconciliation.** `docs/design/08-websocket-api-contract.md` lists a
  partial error-code enum; the engine emits more (`MEETING_NOT_FOUND`, `ALREADY_RUNNING`,
  `ENGINE_WARMING_UP`, `UNSUPPORTED_TYPE`, `PROTOCOL_MISMATCH`, …). Reconcile the doc.
  - *Source:* wire-symmetry review during ADR-0020.
- **Stale `segment.final` `speaker` example.** The contract doc still shows `segment.final`
  carrying a `"Speaker 2"` label "provisional during the meeting." Reality (post-ADR-0017/0020):
  live `segment.final` ships `speaker: nil`; labels exist only post-stop. Fix the doc example.

## Vault / meeting features

- **Bookmark pins in the saved file.** `bookmark.create` works on the wire, but the engine
  keeps no bookmark store, so pins don't land in the meeting markdown.
  - *Pick up:* persist bookmarks per session; render as anchors in the file (STATUS "Deferred polish").
- **User-editable meeting title.** Files are titled by auto-timestamp ("Meeting YYYY-MM-DD HH:MM").
  Let the user set a real title (and reflect it in the frontmatter + filename policy).
- **Post-Meeting Review screen — SHIPPED (slice B2).** The user's verify-by-ear idea: play the
  saved audio, click an utterance to hear that moment, assign/correct speaker names by ear.
  Main reads the `.wav` (vault-fenced, `.wav`-only) → renderer Blob URL → player + per-utterance
  seek + now-playing highlight + reuses `speaker.rename`. Gated by *Keep audio* (no audio ⇒
  the existing inline roster / Attendees tagging path). *Polish left:* a real waveform (we use a
  plain scrubber); audio-read **symlink hardening** (`fs.realpathSync` + re-check before read —
  defense-in-depth; out of the current threat model since the engine is the sole writer of
  `.audio/`, per the privacy audit).
- **Audio compression (AAC/Opus).** ADR-0028 ships uncompressed 16 kHz WAV (~1.9 MB/min). An
  `AVAudioConverter` encode to `.m4a`/Opus would shrink a 1-hour meeting from ~115 MB to ~10 MB.
  - *Deferred because:* WAV reuses `HarkCore.WAVWriter` and plays natively in Chromium with no
    transcode — simplest correct thing first. *Pick up:* ADR-0028 alternatives.
- **Decouple audio buffering from diarizer-load.** The whole-meeting buffer (`sessionAudio`) is
  accumulated only when `diarizer != nil`, so `keep_audio` silently no-ops if the diarizer
  failed to load. *Pick up:* gate the `ingestFrames` buffering on `keepAudio || diarizer != nil`
  (ADR-0028 open question).

## UI surfaces (from the design pass)

The shipped UI is a deliberate **functional core** of the full ~9-surface design
(`vault/hark/docs/design/ui/artboards/`). The rest is deferred until its backing
data/phase exists — building empty shells now would be dead UI. `STATUS.md` "remaining
Phase 4 surfaces" carries the live detail; summary:

- **3-column layout** (attendees | transcript | Q&A). Blocked on diarization (partial now)
  + Q&A (Phase 6). Single-column until the side columns have data.
- **Q&A side panel** (`QAPanel.jsx`). Blocked on Phase 6 (Claude API).
- **Full speaker-management UI** (`SpeakerTagging.jsx` modal + auto-recognition states).
  Naming is covered by the rename MVP (ADR-0020); enrollment/auto-match UI is Phase 5.1.
- **Settings → Privacy pane extras** — redaction toggles, voiceprint folder, cloud-calls
  log. Slot in as their backing features land.
- **Remaining design atoms** — `SpeakerTag`, `Eyebrow`, `Toggle`, `CitationChip`.
- **Light theme** — the design has dark + light; we ship dark only so far.
- **Wikilink `[[term]]` parsing** in the transcript — vault-linking, a later phase.

## Translation (designed, deferred behind RAG — user 2026-06-03)

Translation is already half-wired: `capture.start` carries a `translation` config
(`enabled`/`mode`/`target_lang`), `segment.translation` exists, and `TranscriptLine` renders it —
only the translation *engine* is missing. Two-tier (local = zero egress / cloud = HQ), like the
rest. Three pieces, easiest first:

- **End-of-meeting transcript translation (easy, high-value, pure reuse).** A post-stop
  "Translate to [lang]" → `llm.translate(transcript, targetLang)` in main: a near-clone of
  `summarize` (redact-for-cloud / full-for-local, a "translate to X" prompt, provider completion,
  cloud-log) → show the translation + **Save-to-note** (engine appends a `## Transcript — <lang>`
  section, exactly like the summary `summary.write` path). Works with any configured cloud/local
  model. Minimal new code.
- **Live → English (cheap, local).** WhisperKit has a built-in `task: .translate` that translates
  any source-language audio → **English** text on-device (no extra model). Flip the session's
  `DecodingOptions.task` to `.translate` when the user wants live English captions; the existing
  `segment.translation` plumbing already displays it. Engine-side, zero egress. (Whisper only
  translates *to English* — other targets need MT below.)
- **Live → arbitrary language (the real lift).** Per-segment MT for any pair (English→Thai,
  Thai→Vietnamese, …). Options: a small **local MT model (NLLB-200) as CoreML in the engine** (same
  pattern as the RAG embedder, zero egress) **or Apple's on-device Translation framework** (lovely,
  system-provided, but **macOS 15+** vs our 14.4 floor) **or** the LLM provider per segment (cloud
  = lots of egress + cost + per-segment redaction → better as an optional HQ mode than the live
  default). Its own slice + a model decision; ADR when built.

## i18n / model quality

- **Vietnamese / non-English transcription quality.** Locked-`vi` vs auto-detect, then the
  ladder: (a) initial-prompt vocab injection from the vault, (b) swap to undistilled
  `large-v3`, (c) language-specific fine-tunes (lose code-switching). STATUS open thread #10.
- **Silero VAD upgrade.** Energy VAD lets low-level noise through → Vietnamese hallucinations.
  Silero (gate non-speech before Whisper) is the principled fix; behind a `VAD` protocol for a
  one-file swap. STATUS open threads #11. Capture in an ADR when acted on.

## Infra / tooling

- **Un-ignore `Package.resolved`.** It's currently gitignored, which blocked staging during a
  prior commit. Pin it for reproducible builds (spawned task).

---

> When you defer something in a working session, **add it here in the same turn.** A one-line
> entry with a file/ADR ref is enough. Future sessions (and future-you) build the best version
> of Hark by never losing the thread on what "better" looked like.
