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

- **Provider abstraction + integration.** A pluggable LLM layer: cloud (Anthropic native +
  an OpenAI-compatible client covers OpenAI / Gemini / OpenRouter / …) and local (Ollama /
  LM Studio / llama.cpp — mostly OpenAI-compatible on `localhost`). Cloud keys in Keychain;
  local needs none. Each **cloud** call is explicit, itemized egress (rules #1/#6 — **ADR
  required before any network egress lands**).
  - *Pick up:* design the provider interface + decide where it runs (engine vs Electron main);
    powers summaries, Q&A, and translation-high-quality. UI hooks (model picker, "answered by
    X") are being built now.
- **Cloud-call log + PII redaction** (the design's "PII redacted · View log"). Itemize every
  cloud call and redact PII before sending; local calls need neither. Part of the integration.

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
