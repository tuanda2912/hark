# ADR-0036: Export-only grow-in-place finalization — recover dropped tails in the saved transcript, keep the live view discrete

- **Date:** 2026-06-04
- **Status:** Accepted — implemented (on-device confirmation pending)
- **Deciders:** Dang Anh Tuan
- **Amends:** [ADR-0019](0019-region-based-finalization.md) (region-commit watermark), refines [ADR-0018](0018-utterance-supersession-signal.md) (supersession gate)

## Context

ADR-0019 made the streaming engine finalize each audio **region exactly once**, behind a
monotonic `committedUpTo` watermark, to stop the same speech being finalized 3–4× as
WhisperKit re-segments across sliding-window hops. A segment commits when its **start**
crosses the commit horizon; anything whose start is at/behind the watermark is
`.skipAlreadyCommitted`.

That optimized for **no duplicates** — but at the cost of **content loss** on long,
multi-clause utterances:

1. A hop decodes a SHORT version — `"So, but this is just the beginning."` — its start
   crosses the horizon → finalized; the watermark advances past it.
2. A later hop re-decodes the GROWN version — `"…beginning. You know, this is the first
   version. It's a prototype…"` (same start, fuller text). `resolve` skips finalized
   entries so it gets a fresh utterance_id; its start is now behind the watermark →
   `.skipAlreadyCommitted` → it is **never finalized**, and the grown tail is dropped.

Verified in the vault: `meetings/2026-06-04-0904.md` truncates the utterance at
`"…beginning."`, while `0703.md` (a luckier re-segmentation) has it complete. So spoken
content was **silently lost** from the saved transcript — timing-dependent and
non-deterministic.

**For a transcription product, dropping spoken words is the worst failure** — it breaks
trust in a way an occasional duplicate phrase never does. (A recent UI cleanup — the
stranded-partial retraction and a live-tail filter — had also started *hiding* these
orphaned grown-tails from the live view, making the loss invisible. That's a symptom, not
the cause; the cause is the finalization dropping the tail.)

## Decision

**Re-bias the finalization values from "strict no-duplicates" to "completeness first," via
export-only growth.** When a fuller re-decode of an already-FINALIZED utterance arrives,
recover the grown tail into the SAVED transcript — but keep the LIVE view as discrete,
stable lines (no rewrite). The user's explicit choice: **"live clean, export recovers it"**
— a finalized line never changes under you live; the completeness lands in the exported
file (and in the post-stop transcript swap).

Mechanism (engine):

- New `UtteranceLedger.extendFinalizedIfGrown(tStart:tEnd:text:)` mirrors ADR-0018's
  **conservative** supersession gate, re-aimed at FINALIZED, non-superseded entries: it
  matches only on **time-containment** (start ≤ old start + slack, end ≥ old end − slack)
  **AND text-containment** (old normalized text is a prefix of the new) **AND it actually
  grew**. On a match it updates that entry's `tEnd` + `lastText` and returns its id;
  otherwise `nil`. The prefix gate means two genuinely-different utterances **never merge**
  (same protection as ADR-0018) — a non-prefix re-decode is not a growth.
- The reconcile loop tries `extendFinalizedIfGrown` BEFORE `resolve`; on a match it calls
  `growRetainedFinalized(uid:tEnd:text:)` — which updates the RETAINED `finalizedUtterances`
  row in place (keeps the original `tStart`, grows `tEnd` + text) and advances the watermark
  — but **does NOT re-broadcast** a `segment.final`. So the live stream keeps the discrete
  short line it first emitted; the fuller text reaches only the SAVED transcript.
- `emitSegment` retains finalized utterances **append-only** (each uid is finalized once);
  the grow path doesn't go through it.

Why this matches "live clean, export recovers it": the live captions are built from the
broadcast `segment.final` frames (unchanged here → discrete, stable), while the saved
transcript / the post-stop `meeting.transcript` swap are built from `finalizedUtterances`
(now grown → complete). So the LIVE view shows the short line during capture; at Stop the
swap shows the complete transcript, and the saved file + its translation are complete. No
wire change, no live duplicate, no live rewrite.

## Consequences

**Positive** — no content loss in the SAVED transcript for the common case (a grown
re-decode of a finalized line); the LIVE view stays discrete and stable (a finalized line
never rewrites under the user — their explicit preference); no wire/renderer change; the
conservative prefix+time gate preserves ADR-0018's protection against merging distinct
utterances.

**Negative / accepted** — (1) **Live can lag the saved file:** a late-decoded tail is NOT
shown in the live captions (only the short version is), and only appears at Stop (the
`meeting.transcript` swap) / in the saved file. The user explicitly chose this ("live clean,
export recovers it") over a churnier-but-complete live view. (2) **Residual churn:** once a
line's growth is recorded, a later *identical* re-decode returns `nil` and falls through to
the normal path, becoming a redundant orphan that the existing prune-retraction handles — no
loss; transient live-tail churn, tracked separately (source-level finalization).
(3) **Residual loss edge:** a grown re-decode whose START is
**rephrased** (so the old text is no longer a clean prefix) won't match the gate and its
tail can still be dropped — rarer than the prefix case, accepted for now; the conservative
gate is deliberate (better to occasionally miss an extension than to merge two distinct
utterances).

## Test / verification

- Engine suite **191 tests, 0 failures** (4 new in `CommitWatermarkTests`): a grown re-decode
  updates the RETAINED (saved) row to the full text with **no live re-broadcast** (the live
  emission count stays 1, so the live line doesn't rewrite) — verifying both no-truncation in
  the export and a discrete live stream; a distinct (non-prefix) utterance does NOT merge; an
  identical re-decode is a no-op; only finalized entries are extended.
- **Needs on-device (M-series) confirmation:** a real long-utterance capture must show the
  SAVED transcript (and the post-stop swap) hold the full text (no truncation) while the live
  captions stayed discrete — the unit tests pin the pure logic, but WhisperKit's real
  re-segmentation timing is what produced the original truncation.

## References

- ADR-0019 (region-commit watermark — the model this amends), ADR-0018 (supersession gate —
  the conservative time+text-prefix logic reused here), ADR-0009 (utterance_id overlap rule).
- Engine: `UtteranceLedger.extendFinalizedIfGrown` (SlidingWindow.swift), the reconcile
  grow-path + `emitSegment` replace-by-uid (EngineSession.swift), `CommitWatermarkTests.swift`.
