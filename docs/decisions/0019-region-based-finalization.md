# ADR-0019: Region-based finalization — a commit-watermark, "finalize each audio region exactly once"

- **Date:** 2026-06-01
- **Status:** Accepted
- **Extends / refines:** [ADR-0009](0009-utterance-id-overlap-rule-v2.md) — keeps ADR-0009's partial identity rule unchanged; changes only *when/what becomes a* `segment.final`. Makes [ADR-0018](0018-utterance-supersession-signal.md)'s supersession signal a backstop rather than the primary cleanup.
- **Deciders:** Dang Anh Tuan

## Context

The streaming engine ([ADR-0008](0008-phase-3-streaming-architecture.md)) runs a **30 s window with a 5 s hop**: every hop re-transcribes the *entire* 30 s buffer. That means each span of audio is transcribed ~6 times (30 ÷ 5), each pass with slightly different WhisperKit segmentation and boundaries.

The finalization rule we had ([ADR-0009](0009-utterance-id-overlap-rule-v2.md)) promoted a segment to `segment.final` when its `t_start` fell in the "older zone" (the older 25 s of the window) *and* its text was stable since the last emit. Because WhisperKit re-segments the whole buffer every hop, the **same speech gets re-segmented into different shapes across hops** — and ADR-0009's max-denominator overlap rule (correctly, to avoid identity drift across content) **mints a fresh `utterance_id`** for each materially-different shape. The net effect: a single spoken sentence is finalized **3–4 separate times** under different `utterance_id`s.

We bolted on two post-hoc safety nets — [ADR-0018](0018-utterance-supersession-signal.md)'s `segment.superseded` retraction (catches prefix/extension growth) and a time-gated at-stop `collapseReemissions` dedup (catches identical/prefix re-emissions within a small time window). They only **partially** clean it: a verified 2026-06-01 on-device run of a ~200 s clip emitted **129 finals** (deduped to 94), with `"Let's do it."` finalized **4×**, `"I got to demo them…"` **4×**, and similar repeats throughout. The duplicates are produced **at the source** (the finalization decision) and then chased down imperfectly after the fact. That is the wrong layer to fix it.

## Decision

Finalize **each audio region exactly once**, using a monotonic **commit watermark** instead of a per-segment "older-zone + text-stable" heuristic.

Maintain `committedUpTo` (session-relative seconds since capture start), starting at `0`. On each hop, after WhisperKit returns segments for the window:

1. **Compute a commit horizon** — the audio time that is now stable because it is about to leave the window and will not be re-transcribed:

   ```
   commitHorizon = windowStartSessionTime + hopSeconds
   ```

   This is the **oldest `hopSeconds` of speech in the window** — precisely the span that ages out on the next hop and will never be seen by a future pass. (Equivalent to the task's `windowEndAbs − (windowLen − hop)` when the window is full; we express it from the window's left edge because the buffer is *speech-only* and may not be full, and the left edge `windowStartSessionTime` is the one timeline anchor we always have exactly. See "absolute time" note below.)

2. **Finalize, exactly once,** the segments of *this hop's* transcription whose start lies in `(committedUpTo, commitHorizon]` — i.e. `committedUpTo < seg.tStart <= commitHorizon`. Straddle rule: **a segment is committed when its `t_start` is committed.** Each region's start is committed once; we use *this* (most-refined, fullest-context) hop's text for that region. One `segment.final` per such segment.

3. **Advance** `committedUpTo = max(commitHorizon, maxCommittedEnd)`, where `maxCommittedEnd` is the farthest `t_end` of any segment finalized **this hop**. Audio at or before `committedUpTo` is **never finalized or re-emitted again.** This is what kills the duplicates: a region cannot be finalized twice because its start is already behind the watermark.

   > **Refinement (2026-06-01, see "Long-sentence boundary-overlap" below).** Originally this step advanced only to `commitHorizon`. A long sentence whose `t_start` straddles the horizon but whose `t_end` runs well past it is finalized with its **full text**, so its whole span `[t_start, t_end]` is committed — the watermark must reflect that, not just the horizon. Advancing to `max(commitHorizon, maxCommittedEnd)` makes a long committed segment **consume its full audio span**, so subsequent hops skip any segment whose `t_start` falls inside it (`.skipAlreadyCommitted`). The straddle commit rule itself (`committedUpTo < t_start <= commitHorizon`), the hot-region partials, and the drain are unchanged.

4. **Partials are unchanged for the hot region.** For audio *after* `committedUpTo` (the still-hot region), keep emitting `segment.partial` with ADR-0009-stable `utterance_id`s exactly as before, so live captions still grow in place. Only finalization changed; the partial/replace-in-place flow is untouched.

At **`capture.stop`**, flush: finalize everything remaining after `committedUpTo` to the end in a single drain pass, then we are done.

No wire-contract change: this is still `segment.partial` / `segment.final` / `segment.superseded` with their existing shapes.

### How absolute audio time is tracked (and why the horizon is conservative)

`SlidingWindowBuffer` stores **speech-only** samples (VAD drops silence). It records `windowStartSessionTime` = the session time of the oldest sample in the buffer, and maps window-relative segment offsets back to absolute session time via per-speech-batch anchors (`windowTimeToSessionTime`). So a segment's `tStart`/`tEnd` are absolute session-relative seconds.

Because the buffer is speech-only and may not be full (early in a meeting, or after silence trims), the *only* edge we know exactly each hop is the **left edge** `windowStartSessionTime`. Anchoring the horizon there — committing just the oldest `hopSeconds` — is deliberately **conservative**: we commit a region only once it is genuinely about to leave the window, never the still-hot tail. If anything errs, it errs toward committing *later* (a region might be re-decoded one more hop before commit), which is the safe direction: a slightly-delayed final beats finalizing text that is still changing.

## Alternatives considered

- **More post-hoc heuristics** (extend supersession to fuzzy/edit-distance text, more aggressive at-stop merging).
  - ✅ Pros: no change to the live path; keeps the source as-is.
  - ❌ Cons: still chasing the symptom; every loosening of a text gate risks **eating real repeated content** (the exact danger ADR-0009 §Alternatives and ADR-0018 §Decision call out). Fragile threshold-tuning against one trace.
  - **Why rejected:** doesn't fix the root cause, and trades a visible duplicate for a worse silent deletion.

- **Widen the at-stop dedup time window.** Raise `HARK_DEDUP_WINDOW_SEC` so more re-emissions collapse.
  - ✅ Pros: one-line knob.
  - ❌ Cons: a wider window starts collapsing **legitimately-repeated phrases** spoken close together (the hard constraint the time gate exists to protect). Defeats the safety mechanism.
  - **Why rejected:** unsafe at the width needed to actually catch the 1–4 s re-emission drift seen on conversational audio.

- **Defer finals until text is "stable for N hops."** A confidence-over-time rule instead of a region rule.
  - ✅ Pros: intuitive.
  - ❌ Cons: still per-segment and identity-keyed, so re-segmentation that mints a fresh `utterance_id` *resets* the stability counter — the same failure mode, just slower. Adds latency without removing duplicates.
  - **Why rejected:** doesn't break the link between "WhisperKit re-segmented" and "we finalized again."

- **Commit watermark (chosen).** Finalize by audio *region*, once, behind a monotonic watermark.
  - ✅ Pros: a region structurally cannot be finalized twice; duplicates die at the source; partials/live experience unchanged; no new heuristic to tune; no wire change.
  - ❌ Cons: the final's text is whichever hop first crossed the region past the horizon — slightly less "settled" than waiting for the full re-decode history (mitigated by the conservative horizon: the region already had ~5 hops of context by the time it ages out).

## Consequences

### Positive

- **Duplicate finals are eliminated at the source.** Each audio region produces exactly one `segment.final`. The 2–4× finalization of the same sentence is structurally impossible because a region's start is committed once and never revisited.
- **Live captions are unchanged.** Partials for the hot region (`> committedUpTo`) still emit/update in place by `utterance_id` per ADR-0009. The validated live experience does not regress.
- **The at-stop transcript reads as one clean line per sentence, in order**, with far less work for the dedup backstop to do.
- **`committedUpTo` is monotonic**, so the cleanup invariant is trivially checkable: nothing at/before the watermark is ever re-finalized.

### Negative / tradeoffs accepted

- **Final text is the first-past-the-horizon decode, not a maximally-settled one.** A region is finalized using the hop where its start crossed the horizon. Because the horizon is the *oldest* part of the window, that region has already been re-decoded ~5 times by then, so it is well-settled in practice — but it is not, by construction, "the last possible decode."
- **Two utterance-identity mechanisms still coexist** (ADR-0009 mint + ADR-0018 retract). They remain coherent; the watermark just makes the retract path rarely necessary for finals.
- **Horizon too aggressive would commit unstable text.** If `commitHorizon` were pushed toward the hot tail, we would finalize text still being refined. Mitigated by: anchoring at `windowStartSessionTime + hopSeconds` (the genuinely-aging-out oldest slice), and the regression tests below.

- **Dropped overlapping interjection (refinement trade-off, accepted for v1).** Advancing the watermark to a long committed segment's `t_end` means an overlapping interjection that **starts inside** that committed span is skipped (it lands at/before the watermark → `.skipAlreadyCommitted`). This is acceptable: WhisperKit rarely emits clean overlapping segments anyway, and dropping a sub-second interjection buried inside one speaker's long sentence is far less bad than re-covering a whole sentence as a string of overlapping fragments (the bug this fixes). If real overlapping speech becomes important (e.g. paired with diarization-level overlap detection in a later phase), this is the place to revisit — strictly an additive change, no contract impact.

### Long-sentence boundary-overlap bug + refinement (2026-06-01)

The first cut of region commit advanced the watermark to `commitHorizon` only. That works for normal-length sentences (a verified 214 s clip went **94 → 39 finals**, ~one per sentence), but **long sentences had their tail re-committed as overlapping fragments.**

Mechanism: a segment is committed when `committedUpTo < t_start <= commitHorizon`, and it is emitted with its **full text** even when `t_end` runs well past the horizon. Advancing only to `commitHorizon` left the span `(commitHorizon, t_end]` *uncommitted*, so the next hops finalized segments starting there — the same audio the long sentence already contained.

Verified evidence (vault `2026-06-01-1858.md`): line 40 is the full "But this is the culmination of 10 years… wide field of view." sentence (`t_start` 36.2, `t_end` 58.2, horizon that hop ~42), and lines 43/46/49/52 ("that we've done to basically miniaturize", "computing that you need to have glasses…", "but glasses that can put full holograms…", "with a wide field of view. So you can imagine…") re-cover content already inside `[40, 58]`.

**Fix:** after committing this hop's segments, advance `committedUpTo = max(commitHorizon, max(t_end of all segments committed this hop))`, so a long committed segment consumes its full audio span and the following hops skip any segment whose `t_start` falls before the new watermark. The same `max(t_end)` logic already governs the stop-drain (`flushTranscriptionDrain` advances to the end of the drained tail). Everything else — the commit rule, hot-region partials, ADR-0009 partial-id stability — is identical. Pinned by `testLongSentenceConsumesItsTailNoOverlapRefinalization` (fails against horizon-only advance: 5 finals + watermark stuck at the horizon; passes after: 1 final, watermark at the sentence's `t_end`).

### Interaction with prior ADRs

- **ADR-0009 (partial identity).** *Unchanged.* The max-denominator overlap rule, the fresh-ID mint, partial replace-in-place, and orphan prune all still apply to the **hot region** (`> committedUpTo`). This ADR only changes the **finalization** decision; ADR-0009's `segment.final`-is-terminal contract is preserved (and now easier to honor: a committed region is terminal by the watermark).
- **ADR-0018 (supersession).** Now a **backstop**, not the primary cleanup. Under region commit, the same sentence is no longer finalized as multiple growing fragments, so supersession should fire **rarely or never** for finals. We **keep** it (and the at-stop `collapseReemissions` dedup) as defense-in-depth — they must not fire spuriously, but they remain a safety net for any residual hot-region churn. Region-based commit is the **primary** mechanism; the post-hoc dedup is the backstop.

### What needs to remain true

- Window = 30 s, hop = 5 s (or whatever `SlidingWindowBuffer` is constructed with — the horizon reads `hopSeconds` from the buffer, not a literal). If the geometry changes, the horizon follows automatically.
- WhisperKit boundaries drift by O(seconds), not O(tens of seconds) — the same assumption ADR-0009 already relies on. A region that ages out of the window is genuinely not re-decoded.
- The UI honors `segment.final` as terminal for an `utterance_id` (ADR-0009 §Assumptions). Unchanged.

## Privacy / threat-model note

Unchanged. No new persistence, no new network surface, no new frame. The watermark is an in-RAM `Double` (session-relative seconds); finalization still flows over the existing localhost WebSocket as `segment.final` carrying only the text already being emitted. Nothing leaves the machine; transcript text is still never logged (state/progress only). Hard rules #1–#3 are untouched.

## Open questions

- **Optimal horizon offset.** We anchor at `windowStartSessionTime + hopSeconds`. If dogfooding shows the first-past-horizon decode is occasionally rougher than a slightly-later one, the offset can be widened (commit later) with no contract change — strictly the safe direction.
- **Whether the dedup backstop can eventually be retired.** If long-run dogfooding shows `collapseReemissions` consistently finds `raw ≈ kept`, we may drop it. Not now — keep the net while the model is fresh.

## References

- Refines: [ADR-0009](0009-utterance-id-overlap-rule-v2.md) — partial identity rule (unchanged); finalization changed here
- Makes a backstop of: [ADR-0018](0018-utterance-supersession-signal.md) — `segment.superseded` retraction
- Streaming geometry: [ADR-0008](0008-phase-3-streaming-architecture.md) §3 — 30 s window / 5 s hop, backpressure
- Implementation: `engine/Sources/Harkd/EngineSession.swift` (`runTranscription`, `flushTranscriptionDrain`, `committedUpTo`), `engine/Sources/Harkd/SlidingWindow.swift` (window/hop, `UtteranceLedger`)
- Regression coverage: `engine/Tests/HarkdTests/CommitWatermarkTests.swift`
- Verified evidence: 2026-06-01 on-device run, ~200 s clip — 129 finals (94 after dedup), "Let's do it." ×4, "I got to demo them…" ×4
- Refinement evidence: 2026-06-01 on-device run, 214 s clip — region commit took 94 → 39 finals; long-sentence boundary-overlap bug (vault `2026-06-01-1858.md`, line 40 vs 43/46/49/52) fixed by advancing the watermark to `max(commitHorizon, max committed t_end)`
