# ADR-0026: Speaker enrollment — auto-recognize known voices across meetings (Phase 5.1)

- **Date:** 2026-06-02
- **Status:** Accepted
- **Deciders:** Dang Anh Tuan

## Context

Diarization labels speakers anonymously per meeting ("Speaker N"); the user names them
post-stop (ADR-0020 rename / tagging modal). Without memory, the same people must be
re-named every meeting. We want to **store a voiceprint when a speaker is named, then
auto-recognize that voice in future meetings** — the natural follow-on to naming, and the
durable replacement for the (rejected) live-diarization idea (ADR-0025).

A read-only feasibility pass (this session) returned **GREEN**: FluidAudio's offline pass
already produces a **256-dim per-speaker centroid** (`DiarizationResult.speakerDatabase`),
and `SpeakerUtilities.cosineDistance` is a public matching primitive. The offline pipeline
has **no known-speaker pre-seed** (that's the streaming `SpeakerManager`, which we don't use),
so matching is a **post-hoc** relabel layered on top of the unchanged diarizer.

## Decision

- **Storage:** `vault/.speakers/<uuid>.json`, one file per enrolled person — `{ name, centroid
  (256-dim, L2-normalized), samples[], embeddingSpace, createdAt, updatedAt, meetingsSeen }`.
  Local, **gitignored** (`.speakers/` already excluded — ADR-0016), never networked
  (rule #5). Filename is a UUID, not the name (no PII in filenames).
- **Enroll on naming:** when the user names a speaker post-stop (`speaker.rename`), persist
  that speaker's offline centroid as a voiceprint (retained via an extended
  `SavedMeetingSnapshot`). Merge into the existing person if the name matches (append to
  `samples[]`, recompute the centroid); gate on a minimum speaker duration (~4 s) so we don't
  enroll a noisy 2-second cluster.
- **Auto-match post-stop:** in `runDiarizationPass`, match each clustered speaker's centroid
  against the enrolled set via `cosineDistance`; if the best match is within
  `HARK_ENROLL_THRESHOLD` (conservative default, cosine space — **not** the offline 0.6
  Euclidean threshold), **auto-apply** the enrolled name and populate the roster's
  `matchedName` + `confidence` (`1 − distance`; currently always nil). 
- **Auto-apply, correctable** (user's call): a confident match is applied automatically; the
  user can re-tag to correct, which updates the enrollment. Conservative by default — a wrong
  name is worse than "Speaker N", so we start strict and expose the threshold as a knob.

## Alternatives considered

- **Suggest-and-confirm** (show "Recognized as Alice?", one-click confirm) instead of
  auto-apply. ✅ safer against a wrong name. ❌ a tap every meeting; the user explicitly wanted
  automatic. **Rejected** per user preference; mitigated by a conservative threshold + easy
  correction + visible confidence.
- **Pre-seed the offline clusterer with known embeddings.** ❌ Not supported — only the
  streaming `SpeakerManager` takes known speakers, and switching to it regresses DER
  (ADR-0017). **Rejected**; post-hoc match is cleaner and decoupled.
- **DIY cosine math.** ❌ FluidAudio's `SpeakerUtilities.cosineDistance` is public + vDSP +
  normalization-tolerant. **Use the library's.**

## Consequences

**Positive**
- Names persist across meetings; known voices are recognized automatically, post-stop, on the
  *accurate* offline embeddings (not the flaky live path).
- Fully local + private; reuses the audited rename/commit path for corrections.
- The roster's `matchedName`/`confidence` wire fields (built nullable for exactly this) light
  up — no contract change.

**Negative / tradeoffs accepted**
- **Cross-mic / cross-room voice matching is the classic hard part** — the threshold + the
  multi-sample averaging policy need **on-device tuning** across real mics before auto-apply
  is trustworthy. Shipped behind `HARK_ENROLL_THRESHOLD`, conservative default.
- A wrong auto-name is possible — mitigated by the conservative threshold, visible confidence,
  and one-tap correction.
- Voiceprints are sensitive data at rest — local, gitignored, user-deletable.

## Open questions

- **Audio-playback Post-Meeting Review screen** (user's idea): verify-by-ear per-utterance
  tagging + enrollment. Requires **persisting meeting audio** — a separate privacy/storage
  decision + ADR (audio is currently discarded). Tracked as the next step.
- Final threshold + averaging policy after on-device tuning.
- Re-running auto-match on *past* meetings when a new voiceprint is enrolled (retroactive) —
  deferred; current scope is forward-only (next meeting onward).

## References

- ADR-0016 / ADR-0017 (diarization), ADR-0020 (rename/tagging), ADR-0024 (post-stop
  back-annotation), ADR-0025 (live diarization rejected — enrollment is the chosen path)
- Feasibility investigation (this session): `DiarizationResult.speakerDatabase` (256-dim
  centroid), `SpeakerUtilities.cosineDistance`, integration at `EngineSession.runDiarizationPass`
- `docs/BACKLOG.md` — speaker enrollment (now active); audio-review screen (next)
