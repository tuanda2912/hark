# ADR-0040: Idle-flush live hops + renderer live-collapse for low-latency captions

- **Date:** 2026-07-03
- **Status:** Accepted
- **Deciders:** Dang Anh Tuan

## Context

Live captions lagged badly in real meetings — a spoken line took 10–20s to appear, and sometimes only surfaced at capture-stop. Unusable for in-meeting Q&A, and the felt gap vs. cloud competitors.

Measurement (on the target M1, not an M4) located the cause, and it was **not** the model or the 30s window:

- The sliding window (ADR-0008) only fired a transcription after **5s of accumulated *speech***. In a meeting at ~40% speech duty cycle that is ~13–16s of wall-clock between transcriptions, so a line waits for the *next* hop — or never emits live and is recovered only by the at-stop drain (ADR-0019).
- Per-hop timing showed a ~1.4s fixed encoder cost + ~0.05s per second of window fill. So the 30s window is ~2.9s of compute, and **shrinking it barely helps** (the encoder floor dominates) — this ruled out the obvious "smaller window" lever before we touched the ADR-tuned reconciliation.
- WhisperKit's default `temperatureFallbackCount: 5` re-decoded low-confidence windows up to 5×, producing the RTF 0.83 spikes and dropped windows under load.

Latency, not throughput, was the problem, and it lived in *when* we transcribe, not *what* we transcribe.

## Decision

Three coordinated changes (engine + renderer), keeping the ADR-0019 commit-watermark finalization path byte-for-byte unchanged:

1. **Bound the live decode** — `temperatureFallbackCount: 0` on the live transcription only. The at-stop vault re-decode keeps full-quality fallback.
2. **Idle-flush hops** — when ≥1s of new speech has accumulated AND ≥1.5s of wall-clock has passed since the last hop, fire a **partial-only** transcription (no finalize, no watermark advance). Finalization stays on the natural 5s-of-speech hop. Affordable because compute is cheap once fallback is off (RTF ~0.13).
3. **Renderer live-collapse** — thin idle-flush windows make WhisperKit re-segment the same audio under fresh `utterance_id`s (ADR-0009), which the per-id renderer stacked as duplicate lines. The renderer now collapses the live (un-finalized) bucket into one evolving caption per utterance, clustering by time-overlap **and** text-relatedness, keyed by cluster start time. Finalized history is untouched (the engine already dedups it).

A hallucination filter (`isLikelyHallucination`) drops the sound-tag artifacts thin windows provoke (`*crickets*`, `[BLANK_AUDIO]`, leading `*`/`♪`, pure punctuation) at both the live and at-stop clean sites.

Result on M1: first caption after a spoken line dropped from ~8s to ~2s; live duplicate lines from ~25 (for 4 phrases) to one-per-utterance.

## Alternatives considered

- **Shrink the 30s window** — smaller window = less decode per hop.
  - ✅ Simple one-line change.
  - ❌ The encoder is a fixed ~1.4s regardless of fill; a 15s window saves only the ~0.05s/s decoder slope. Also degrades Whisper context/accuracy.
  - **Why rejected:** measured to be a weak lever, and it disturbs the ADR-0019/0009 reconciliation for almost no latency win.
- **Lower the natural hop (5s → 2s)** — finalize/transcribe more often.
  - ✅ Fewer, smaller gaps.
  - ❌ Still gated on *speech* accumulation (a lone utterance before a pause still stalls), and it changes the commit quantum, risking the ADR-0019 content-loss fixes.
  - **Why rejected:** the idle-flush gets the latency win without touching the finalization cadence.
- **Engine-side dedup of churned partials** instead of renderer collapse.
  - ✅ Keeps the renderer's per-id model.
  - ❌ Fights the utterance ledger; the engine deliberately mints fresh ids on re-segmentation (ADR-0009). Suppressing them there is fragile.
  - **Why rejected:** the churn is a *display* concern; collapsing at the view layer is cleaner and carries zero engine risk.
- **Two-tier / streaming decode** (small model for live, turbo for commit).
  - **Why deferred:** genuinely reaches sub-second partials but is a large rework; not needed to clear the "usable for Q&A" bar on M1.

## Consequences

- **Positive:** live captions are responsive (~2s after speech) and clean (one line per utterance); no RTF spikes or dropped windows; the commit-watermark finalization and the saved vault transcript are unchanged (all 191 engine tests pass); the "smaller window / bigger model" rabbit holes are closed by data.
- **Negative / tradeoffs accepted:**
  - **Deferred finalization** — idle-flush partials don't finalize, so a live line stays refinable longer before it "locks." Invisible for reading; the saved transcript is still deduped via `collapseReemissions`.
  - **Plain-text silence hallucinations** ("Thank you.", "So,") still slip the filter — real words, not bracketed tags. Turning fallback off removed the confidence re-roll that used to suppress some. Open (see below).
  - Thin-window decodes are lower-context, so live partials are slightly rougher than the finalized text (accepted: "speed over accuracy" for the live view; the vault re-decode recovers quality).
- **Assumptions that must hold:** compute stays cheap enough (RTF well under 1) that frequent partial hops don't backlog; the renderer keeps a live-vs-finalized split for the collapse to key on.

## Open questions

- Suppressing hallucinations without re-introducing latency. **Partly addressed** (2026-07-03): `isNonSpeechDecode()` now gates every decoded segment on the decoder's own confidence signals (`noSpeechProb > 0.6`, `compressionRatio > 2.4`, `avgLogprob < -1.0` — WhisperKit's own fallback thresholds; measured real speech sits far inside all three). This catches silence/noise decodes and runaway-repetition junk at zero latency cost. Still open: **short, confident** hallucinations that the decoder itself scores as speech (`noSpeechProb ≈ 0`, e.g. "Okay."/"So" invented over background media) — no confidence signal flags them, and a phrase denylist would clip real speech. In a clean meeting (no other system audio) these don't occur; the remaining lever is source selection or a stronger VAD gate.
- The renderer collapses the live bucket to one line per utterance (`collapseLiveByOverlap`) and drops a live cluster a finalized line already shows (`finalizedCovers`) — handling the id-churn duplicates the idle-flush introduces.
- Whether a two-tier/streaming decode is worth it to push live partials below ~1s. Revisit if M1 users still feel lag.

## References

- ADR-0008 (sliding-window backpressure), ADR-0009 (utterance_id reconciliation), ADR-0019 (commit-watermark finalization), ADR-0036 (grow-in-place finalization)
- Branch `perf/live-caption-latency`; env-gated per-hop instrumentation behind `HARK_PERF_LOG`
