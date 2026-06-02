# ADR-0028: Meeting audio persistence — opt-in WAV in `vault/.audio/` (slice B)

- **Date:** 2026-06-02
- **Status:** Accepted
- **Deciders:** Dang Anh Tuan

## Context

The privacy model (ADR-0027) plumbed a `keep_audio` gate through `capture.start` (default
**off**), but left the actual write path as a `TODO(slice B)` — audio was discarded after the
diarization pass. We now need to persist the meeting audio so the planned **Post-Meeting Review
screen** (the user's verify-by-ear idea: play a clip → assign the speaker) has something to
play. This ADR records the storage decision the privacy auditor asked for: **format, location,
and how it stays inside the privacy model.**

The full-meeting mixed PCM is **already buffered in memory** for the offline diarization pass
(`capturedAudio` → `runDiarizationPass`). So persisting it is "write the buffer we already
have," not "capture audio twice."

## Decision

When — and **only when** — `keep_audio` is true:

- **Write** the buffered whole-meeting PCM as a **16 kHz mono signed-16-bit-LE WAV** via the
  existing `HarkCore.WAVWriter` (reused from Phase 2), Float→Int16 with the same `*32767`+clamp
  scaling the capture mixer uses. Atomic (temp file + rename), like every other vault write.
- **Location:** `<vaultRoot>/.audio/<meeting-id>.wav`, where `<meeting-id>` is the **exact stem
  of the meeting's markdown file** (`2026-06-02-1436.wav` ↔ `2026-06-02-1436.md`, collision
  suffixes preserved). A **hidden `.audio/` folder at the vault root**, parallel to
  `.speakers/` — deliberately **not** inside `meetings/`, whose `.md` files are git-tracked.
- **Gitignored, self-asserted:** `.audio/` is added to the vault `.gitignore` (idempotently)
  whenever the folder is created, so meeting audio **never travels a vault git remote** — same
  guarantee as voiceprints (rule #5 spirit; ADR-0027).
- **Wire:** `meeting.saved` gains `audio_path` (Swift `audioPath: String?` ↔ JSON `audio_path`,
  explicit `null`, never dropped) — the absolute path when written, `null` otherwise. The UI
  retains it for the review screen.
- **Gated identically to voiceprints:** `AudioStore.audioPersistenceAllowed(keepAudio:)` mirrors
  `voiceprintAccessAllowed`. Gate off ⇒ **zero `.audio/` I/O** (no dir, no temp, no file),
  proven by `testGateOffMeansZeroAudioIO`.

## Alternatives considered

- **Compressed audio (AAC / Opus / `.m4a`).** ✅ ~10× smaller on disk. ❌ adds an
  `AVAudioConverter`/`AVAudioFile` encode path + format complexity; WAV reuses the existing
  `WAVWriter` and plays natively in the Chromium `<audio>` element (no transcode for the review
  screen). **Deferred** to a later optimization (logged in BACKLOG) — start with the simplest
  correct thing.
- **Co-locate the audio next to the `.md` in `meetings/`.** ❌ that folder is git-tracked, so
  audio would be committed/synced through the vault remote, violating the privacy model.
  **Rejected** — hidden, gitignored `.audio/` matches the `.speakers/` precedent.
- **Store under app-data (`~/Library/Application Support/Hark/`).** ❌ violates hard rule #2
  (audio is user content → belongs in the vault). **Rejected.**
- **Re-buffer / re-capture audio specifically for persistence.** ❌ wasteful — the diarization
  buffer already holds the whole meeting. **Rejected**; reuse `capturedAudio`.

## Consequences

**Positive**
- Unblocks the Post-Meeting Review screen (verify-by-ear per-utterance tagging).
- Zero extra memory — reuses the diarization buffer; zero new network surface.
- Stays fully within the privacy model: opt-in, vault-only, gitignored, deletable, off by default.

**Negative / tradeoffs accepted**
- **WAV is large** (~1.9 MB/min; a 1-hour meeting ≈ 115 MB). Acceptable for local v1;
  compression is a tracked optimization.
- **Audio only persists when the diarizer loaded** — the whole-meeting buffer
  (`sessionAudio`) is currently accumulated only when `diarizer != nil`. If the diarizer fails
  to load, there's no buffer to persist even with `keep_audio` on (the meeting also has no
  speaker labels in that case). Acceptable v1 edge; logged in BACKLOG to decouple later.
- One more sensitive artifact at rest — mitigated exactly like voiceprints (opt-in, gitignored,
  deletable, vault-only).

## Open questions

- Compression (AAC/Opus) to shrink storage — BACKLOG.
- Retention / auto-delete policy (e.g. purge audio after N days) — shared with ADR-0027's open
  question.
- Decouple audio buffering from diarizer-load so `keep_audio` works even if diarization fails.

## References

- ADR-0027 (privacy & data-control — the `keep_audio` gate this fills in), ADR-0026 (enrollment,
  the gating pattern mirrored), ADR-0024 (post-stop transcript)
- `HarkCore.WAVWriter` (Phase 2 capture), `AudioStore.swift`, `EngineSession.persistMeeting`
- `docs/BACKLOG.md` — Post-Meeting Review screen (now unblocked), audio compression, diarizer
  decoupling
