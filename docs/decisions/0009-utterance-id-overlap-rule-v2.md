# ADR-0009: Utterance-identity rule v2 — max-denominator overlap with prune

- **Date:** 2026-05-28
- **Status:** Accepted — **extended by [ADR-0018](0018-utterance-supersession-signal.md)** (adds the `segment.superseded` retraction signal this ADR never provided); the decision below is unchanged.
- **Deciders:** Dang Anh Tuan

## Context

[ADR-0008](0008-phase-3-streaming-architecture.md) §"Open questions" item #3 asked how the engine assigns stable `utterance_id`s across consecutive WhisperKit window passes. The original implementation keyed identity on `t_start` rounded to a 100 ms bucket. Smoke testing on 2026-05-27 (Phase 3 hand-off) showed the same utterance receiving 4+ distinct UUIDs across consecutive windows because WhisperKit re-segments the full 30 s buffer on every hop and routinely shifts boundaries by 1–3 seconds.

Commit `be31c52` replaced the bucket rule with an interval-overlap rule scored as `overlap / min(segLen, eLen)` with a 0.5 threshold (call this v1). That fixed the boundary-jitter case and was marked as resolving open question #3, with the commit message noting "re-smoke-testing required before declaring done."

The 2026-05-28 smoke test exposed a new failure mode: **engulfment**. When WhisperKit's next pass produces a *coarser* segmentation — a single long segment where the previous pass had several short ones — the long new segment fully contains one or more old entries. Under the min-denominator rule, `overlap == shorter`, so score = 1.0 regardless of how unrelated the new text is. Examples from the trace (M1, en):

| Existing entry | Existing text | New segment | New text |
|---|---|---|---|
| `1C4B2CBA` [18.06, 23.24] | "Okay." | [15.66, 32.70] | "the scheme where they provide the secure so that's the stack okay…" |
| `71F767F1` [35.34, 36.72] | "the piece in the middle." | [35.26, 41.20] | "what is in the middle so i should be here you know the piece in the middle okay so the blue box" |
| `B034140A` [45.16, 46.34] | "- Okay." | [41.83, 55.36] | "is okay okay the blue box in the middle are all the start contract…" |

The UI consequence is severe: a renderer that keys on `utterance_id` would render an in-place mutation of "Okay." into a sentence about API security. Identity drift across content is worse than the duplicate-IDs problem the v1 rule was designed to fix.

ADR-0008's storage discipline (entries are append-only, never pruned during a session) also stops being free once we accept that some entries will never get re-matched and become orphans. Over a 1-hour meeting that's hundreds of zombies in the ledger, each one scanned on every `resolve` call.

## Decision

Two changes to `UtteranceLedger` in `engine/Sources/Harkd/SlidingWindow.swift`:

1. **Score denominator switches from `min(segLen, eLen)` to `max(segLen, eLen)`.** Threshold stays at 0.5. The rule now reads "two intervals are the same utterance iff their overlap covers at least half of the longer one."

2. **Add `prune(beforeSessionTime:)`.** After each window's reconciliation pass, drop entries whose `tEnd` is strictly less than the current window's left edge. Return the dropped entries so `EngineSession` can emit a closing `segment.final` for any non-finalized orphans (giving the UI a clean state instead of dangling partials).

ADR-0008 §"Open questions" #3 is now considered resolved by the *combination* of `be31c52` and the changes in this ADR. Re-smoke verification is required before closing the corresponding entry in STATUS.md open threads (#13).

## Alternatives considered

- **Stay with v1 (`min` denominator).** Already known to fail per the 2026-05-28 trace. Rejected.

- **Text-similarity tie-breaker on top of v1.** Among entries with score ≥ threshold, prefer the one whose `lastText` shares the longest common prefix with the new text. Catches more cases including the engulfment one, but adds string-distance code we'd then need to tune and test for hostile inputs (Unicode normalisation, locale, etc.). Rejected as overkill given the geometric rule already solves it.

- **Two-sided rule: `overlap ≥ 0.5·shorter AND overlap ≥ 0.3·longer`.** Catches engulfment via the longer-side gate while letting more shrinkages through via the shorter-side gate. Tested against the trace: the 0.3 longer-side bound was perilously close to the actual engulfment ratios in the data (`1C4B2CBA` engulfment scored 0.30, exactly on the line). Picking thresholds that work for one trace is fragile. Rejected for the simpler `max`-denominator rule, which has a single tunable and clearer semantics.

- **Center-distance metric (`|midpoint_a − midpoint_b| < threshold`).** Robust to small shifts but loses information about interval length. Rejected — adds modelling complexity without a clear win over overlap-of-longer.

- **Don't prune at all; let entries accumulate.** Works for short sessions, fails for hour-long meetings. Rejected on perf and (eventually) memory grounds.

- **Prune only finalized entries.** Half-fix: leaves non-finalized orphans growing unbounded whenever WhisperKit aggressively re-segments. Rejected.

## Consequences

### Positive

- The egregious "Okay." → "the scheme where they provide…" failure mode is impossible. Engulfment now scores `shorter / longer` which is small whenever the segments differ in length, so it falls below threshold and a fresh UUID is minted.
- Ledger size is bounded by ≤ 30 s of recent activity instead of growing for the whole session. `resolve` stays O(active utterances) — typically < 10.
- Orphan partials now get a `segment.final` emitted on prune so the UI doesn't have to handle "dangling partials of unknown lifecycle."
- The new rule has a clearer mental model: "two intervals match iff they're roughly the same range." No need to reason about which side is the denominator.

### Negative / tradeoffs accepted

- **Aggressive re-segmentation causes new mints.** If WhisperKit decides what was one segment is actually three, only the leftmost piece (the one whose interval shape best matches the original) keeps the original UUID; the middle and right pieces get fresh UUIDs and the original entry becomes an orphan. The UI sees more `utterance_id`s than the v1 rule produced. This is the consciously-accepted price for never seeing identity drift across content.
- **Threshold 0.5 may be tighter than needed.** A handful of legitimate continuations in the smoke trace landed in the 0.5–0.6 score range; raising the threshold would push them under. Dogfooding in Phase 4 will tell us if false-mismatches become a complaint. Tuning knob lives in one place (`UtteranceLedger.overlapThreshold`).
- **Pruned non-finalized orphans get a synthetic `segment.final` with no language tag.** `Entry` doesn't store language. Acceptable for now (the UI can fall back to the session language), but if we ever need per-segment language guarantees we'll need to extend `Entry`.
- **No retroactive finalization.** If a real utterance never gets re-emitted because WhisperKit drops it (e.g. ASR confidence collapsed), the synthetic final will have the *last partial text*, not corrected text. This is the same UX as v1 — orphans have always had stale text — just now they get an explicit closing message.

### Assumptions for this to remain correct

- WhisperKit's segment boundaries continue to drift by O(seconds), not O(tens of seconds). If a future model version starts producing wildly different timestamps across windows, even max-denominator overlap won't preserve continuity.
- The hop is 5 s and the window is 30 s. Entries with `tEnd < windowStartSessionTime` are safe to prune because future window passes can only see segments with `tStart ≥ windowStartSessionTime`. If the windowing geometry changes (e.g. variable hop), the prune cutoff calculation needs to follow.
- Phase 4's UI honors the contract that `segment.final` is terminal — once it sees a final, no further partial with the same `utterance_id` ever arrives. The engine guarantees this via the `finalized` flag, but the UI side hasn't been built yet.

## Open questions

1. **Should the engine surface the orphan-finalization separately from a normal final?** Adding a flag like `was_orphan: true` could let the UI dim the text or render an uncertainty marker. Defer to Phase 4 UX design — over-engineering until we see how the renderer handles them.
2. **Per-segment language on orphan finals.** Currently `nil` — acceptable today, may need a fix when Phase 6 translation lands and needs reliable per-segment language tags.
3. **Threshold tuning from real meeting data.** The 0.5 value was hand-chosen against one 60-second en/M1 trace. Vietnamese, Thai, and code-switched audio may have different re-segmentation characteristics. Capture a follow-up ADR if Phase 4 dogfooding produces a calibration delta.

## References

- Commit `be31c52` — v1 (min-denominator) fix that this ADR supersedes the rule for.
- Smoke test transcript, 2026-05-28 — engine.log + websocat session showing the engulfment cases above.
- [ADR-0008](0008-phase-3-streaming-architecture.md) §3 + §"Open questions" #3 — Phase 3 streaming architecture and the original utterance-id question.
- `engine/Sources/Harkd/SlidingWindow.swift` — the rule lives in `UtteranceLedger.resolve` + `UtteranceLedger.prune`.
- `engine/Tests/HarkdTests/UtteranceLedgerTests.swift` — regression coverage including the verbatim 1C4B2CBA engulfment scenario from the smoke trace.
