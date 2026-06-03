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
- **Vault-wide / 2nd-brain Q&A — RAG (Slice 4) — DESIGN-LOCKED (ADR-0032), build pending.**
  Cross-meeting questions over the whole vault. Cloud model NEVER sees the vault: **local** embed
  → **local** vector search (top-K) → only the redacted top-K chunks + question go to the model →
  answer + citations. Local model ⇒ zero egress. **Decisions (ADR-0032):** `bge-small-en-v1.5`
  384-dim **CoreML in the engine** (ANE, model-cache pattern); **brute-force in-memory cosine over
  a flat file** (NOT sqlite-vec for v1 — <80 ms at 50k chunks, no native dep; sqlite-vec is the
  >100k scale-up); index in **app-data** (not the vault); engine **FSEvents watcher (30 s +
  content-hash)**; heading-aware chunking with `notePath/headingPath/charRange` for citations; new
  `rag.retrieve` + `rag.index_status` wire frames; renderer scope toggle (this-meeting | vault).
  - **Obsidian 2nd-brain (HYBRID):** the user's external tool syncs Obsidian → the vault folder
    (Markdown); Hark **reads** it and owns the local index (writes only app-data). Obsidian can
    point at the vault directly (`[[wikilinks]]` parsing is a separate backlog item).
  - **Build sub-slices:** 4a engine embedder (spike the `bge-small` CoreML conversion + WordPiece
    tokenizer first — the key risk); 4b index + brute-force retrieval + watcher + wire frames;
    4c main↔engine retrieval wiring + renderer scope toggle + citations. New dep `swift-transformers`
    (tokenizer) → document under rule #6.
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
