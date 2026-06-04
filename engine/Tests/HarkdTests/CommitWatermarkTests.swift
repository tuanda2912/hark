// CommitWatermarkTests — regression coverage for ADR-0019's region-based,
// "finalize each audio region exactly once" finalization.
//
// Context (verified 2026-06-01 on-device): with a 30 s window / 5 s hop, every
// audio span is re-transcribed ~6×, and WhisperKit re-segments it slightly
// differently each pass. The OLD finalization rule (ADR-0009: finalize a
// segment when its t_start is in the older zone + text stable, minting fresh
// utterance_ids on re-segmentation) emitted the SAME speech as 3–4 separate
// finals. A 200 s clip produced 129 finals (94 after dedup), with "Let's do
// it." finalized 4×, etc.
//
// The commit-watermark model finalizes each REGION once, behind a monotonic
// `committedUpTo` watermark:
//   commitHorizon = windowStartSessionTime + hopSeconds   (oldest hop aging out)
//   commit segments with committedUpTo < t_start <= commitHorizon, then
//   advance committedUpTo = commitHorizon.
//
// These tests exercise the PURE decision (EngineSession.commitDecision) and a
// faithful in-test reimplementation of the hop loop's watermark advance, so the
// regression is pinned without needing a live WhisperKit/audio pipeline. The
// loop driver below mirrors `runTranscription` and `flushTranscriptionDrain`
// exactly (same horizon formula, same gate, same advance).

import XCTest
@testable import Harkd

@available(macOS 14.4, *)
final class CommitWatermarkTests: XCTestCase {

    // A transcribed segment for one hop: absolute session-time interval + text.
    private struct Seg {
        let tStart: Double
        let tEnd: Double
        let text: String
    }

    // One emission the loop produced, for assertions.
    private struct Emit: Equatable {
        let isFinal: Bool
        let tStart: Double
        let text: String
    }

    // Same as `Emit` but carries the utterance id, for the grow-path tests that
    // assert the LIVE broadcasts (export-only growth re-broadcasts nothing).
    private struct EmitWithId: Equatable {
        let uid: String
        let isFinal: Bool
        let tStart: Double
        let text: String
    }

    private let hop = 5.0  // matches SlidingWindowBuffer(hopSeconds: 5)

    /// Faithful reimplementation of `runTranscription`'s commit loop + watermark
    /// advance, driving the REAL `UtteranceLedger` exactly as the live loop does
    /// (resolve → updateText → finalize-or-partial). Threading the real ledger
    /// matters for the drain: the stop-drain's head guard
    /// (`overlapsFinalized`) consults the ledger's actually-finalized entries,
    /// so the harness must populate them the same way the live loop would.
    /// `committedUpTo` carries across hops (the live state machine keeps it on
    /// the actor). Returns every emission. `windowStart` is the session time of
    /// the oldest sample in that hop's window (what `popHopIfReady` reports);
    /// `segments` are this hop's decode, already mapped to absolute session time.
    private func runHops(_ hops: [(windowStart: Double, segments: [Seg])],
                         ledger: UtteranceLedger,
                         committedUpTo: inout Double) -> [Emit] {
        var emits: [Emit] = []
        for h in hops {
            let commitHorizon = h.windowStart + hop
            // ADR-0019 refinement: track the farthest t_end committed this hop,
            // exactly like `runTranscription`, so a long sentence that straddles
            // the horizon consumes its full span and its tail isn't re-committed.
            var maxCommittedEnd = committedUpTo
            for seg in h.segments {
                // ADR-0036 EXPORT-ONLY grow path: mirror `runTranscription` — a
                // fuller re-decode of an already-finalized line updates the
                // RETAINED row for the saved transcript but is NOT re-broadcast
                // live (no emit here), so the live stream keeps the discrete short
                // line. (runHops doesn't track the retained store; the grow is
                // invisible to `emits` and only advances the watermark.)
                if let grownUid = ledger.extendFinalizedIfGrown(
                    tStart: seg.tStart, tEnd: seg.tEnd, text: seg.text) {
                    _ = grownUid
                    maxCommittedEnd = max(maxCommittedEnd, seg.tEnd)
                    continue
                }
                let uid = ledger.resolve(tStart: seg.tStart, tEnd: seg.tEnd, text: seg.text)
                if ledger.isFinalized(utteranceId: uid) { continue }
                _ = ledger.updateText(seg.text, utteranceId: uid)
                switch EngineSession.commitDecision(segmentStart: seg.tStart,
                                                    committedUpTo: committedUpTo,
                                                    commitHorizon: commitHorizon) {
                case .finalize:
                    ledger.markFinalized(utteranceId: uid)
                    emits.append(Emit(isFinal: true, tStart: seg.tStart, text: seg.text))
                    maxCommittedEnd = max(maxCommittedEnd, seg.tEnd)
                case .partial:
                    emits.append(Emit(isFinal: false, tStart: seg.tStart, text: seg.text))
                case .skipAlreadyCommitted:
                    break
                }
            }
            let advanceTo = max(commitHorizon, maxCommittedEnd)
            if advanceTo > committedUpTo { committedUpTo = advanceTo }
        }
        return emits
    }

    /// Same hop loop as `runHops`, but it ALSO mirrors the retained
    /// `finalizedUtterances` store and returns every LIVE emission with its uid.
    /// Used by the ADR-0036 grow-path tests: a grown re-decode updates the
    /// retained row for the vault (export) WITHOUT a live re-broadcast, so the
    /// tests assert the retained text grows while the live emission count stays 1.
    /// `retained` is the post-write set the vault would receive, last value per
    /// uid — what `finalizedUtterances` holds after `growRetainedFinalized`.
    private func runHopsTracked(_ hops: [(windowStart: Double, segments: [Seg])],
                                ledger: UtteranceLedger,
                                committedUpTo: inout Double,
                                retained: inout [String: (tStart: Double, tEnd: Double, text: String)],
                                retainedOrder: inout [String]) -> [EmitWithId] {
        var emits: [EmitWithId] = []
        func retainFinal(_ uid: String, _ seg: Seg) {
            if retained[uid] == nil { retainedOrder.append(uid) }
            retained[uid] = (seg.tStart, seg.tEnd, seg.text)
        }
        for h in hops {
            let commitHorizon = h.windowStart + hop
            var maxCommittedEnd = committedUpTo
            for seg in h.segments {
                if let grownUid = ledger.extendFinalizedIfGrown(
                    tStart: seg.tStart, tEnd: seg.tEnd, text: seg.text) {
                    // EXPORT-ONLY (ADR-0036): update the retained (vault) row but
                    // do NOT broadcast — the live stream keeps the short line.
                    retainFinal(grownUid, seg)
                    maxCommittedEnd = max(maxCommittedEnd, seg.tEnd)
                    continue
                }
                let uid = ledger.resolve(tStart: seg.tStart, tEnd: seg.tEnd, text: seg.text)
                if ledger.isFinalized(utteranceId: uid) { continue }
                _ = ledger.updateText(seg.text, utteranceId: uid)
                switch EngineSession.commitDecision(segmentStart: seg.tStart,
                                                    committedUpTo: committedUpTo,
                                                    commitHorizon: commitHorizon) {
                case .finalize:
                    ledger.markFinalized(utteranceId: uid)
                    emits.append(EmitWithId(uid: uid, isFinal: true, tStart: seg.tStart, text: seg.text))
                    retainFinal(uid, seg)
                    maxCommittedEnd = max(maxCommittedEnd, seg.tEnd)
                case .partial:
                    emits.append(EmitWithId(uid: uid, isFinal: false, tStart: seg.tStart, text: seg.text))
                case .skipAlreadyCommitted:
                    break
                }
            }
            let advanceTo = max(commitHorizon, maxCommittedEnd)
            if advanceTo > committedUpTo { committedUpTo = advanceTo }
        }
        return emits
    }

    /// Faithful reimplementation of the FIXED `flushTranscriptionDrain` tail
    /// finalize (ADR-0019 content-loss fix): re-decode the whole buffer, skip
    /// only segments that overlap an already-FINALIZED ledger entry (the
    /// committed head), and finalize EVERYTHING else — the hot-region content
    /// that was only ever shown as partials. The drain does NOT gate on the
    /// watermark, because the straddle refinement can push the watermark past
    /// un-finalized hot content. The watermark still advances to the tail end.
    private func runDrain(segments: [Seg], ledger: UtteranceLedger,
                          committedUpTo: inout Double) -> [Emit] {
        var emits: [Emit] = []
        var tailEnd = committedUpTo
        for seg in segments {
            if ledger.overlapsFinalized(tStart: seg.tStart, tEnd: seg.tEnd) { continue }
            let uid = ledger.resolve(tStart: seg.tStart, tEnd: seg.tEnd, text: seg.text)
            if ledger.isFinalized(utteranceId: uid) { continue }
            ledger.markFinalized(utteranceId: uid)
            emits.append(Emit(isFinal: true, tStart: seg.tStart, text: seg.text))
            tailEnd = max(tailEnd, seg.tEnd)
        }
        committedUpTo = max(committedUpTo, tailEnd)
        return emits
    }

    // MARK: - THE regression-defining test

    /// A single audio region ("Let's do it." at ~12 s) is present in the older
    /// part of SEVERAL successive windows as the 30 s window slides past it.
    /// Under the old older-zone rule it would be finalized on every hop where it
    /// sat in the older zone (3–4 finals). Under the watermark it is finalized
    /// EXACTLY ONCE — on the hop where its start first ages into
    /// (committedUpTo, commitHorizon] — and never again.
    func testRegionFinalizedExactlyOnceAcrossSlidingWindows() {
        let ledger = UtteranceLedger()
        var committedUpTo = 0.0
        let phrase = "Let's do it."
        // Six hops; the window left edge advances by `hop` (5 s) each time, and
        // the same region [12.0, 13.2] is re-decoded in every window it covers.
        // windowStart sequence: 0,5,10,15,20,25. The region's start (12.0) is
        // committed on the hop where 10 < 12.0 <= 15 (windowStart 10 → horizon
        // 15). Before that it's a partial; after that it's behind the watermark.
        let region = Seg(tStart: 12.0, tEnd: 13.2, text: phrase)
        let hops: [(windowStart: Double, segments: [Seg])] = [
            (0.0,  [region]),
            (5.0,  [region]),
            (10.0, [region]),   // 10 < 12 <= 15 → FINALIZE here
            (15.0, [region]),   // 12 <= 15 (watermark) → skip
            (20.0, [region]),   // skip
            (25.0, [region]),   // skip
        ]
        let emits = runHops(hops, ledger: ledger, committedUpTo: &committedUpTo)

        let finals = emits.filter { $0.isFinal && $0.text == phrase }
        XCTAssertEqual(finals.count, 1,
            "a region must be finalized exactly once as the window slides over it")
        XCTAssertEqual(finals.first?.tStart, 12.0)
        // It WAS shown live as a partial before being committed.
        XCTAssertTrue(emits.contains(Emit(isFinal: false, tStart: 12.0, text: phrase)),
            "the region grows live as a partial before it is committed")
    }

    // MARK: - THE long-sentence boundary-overlap regression (ADR-0019 refinement)

    /// A long sentence whose t_start <= horizon but t_end >> horizon must be
    /// committed ONCE with its full text, AND the watermark must advance to its
    /// t_end — so subsequent hops whose segments start INSIDE that committed
    /// span (in (horizon, t_end]) are skipped, not re-finalized as overlapping
    /// fragments.
    ///
    /// Verified on-device (vault 2026-06-01-1858.md): line 40 was the full
    /// "But this is the culmination of 10 years… wide field of view." sentence
    /// (t_start 36.2, t_end 58.2, horizon that hop ~42), then lines 43/46/49/52
    /// re-covered content within [40, 58] the long sentence already contained.
    ///
    /// BEFORE the fix the watermark advanced to the horizon only (~42), so the
    /// fragments starting in (42, 58] passed the `committedUpTo < t_start`
    /// guard and were re-finalized. AFTER the fix the watermark advances to the
    /// long segment's t_end (58.2), so those fragments are `.skipAlreadyCommitted`.
    func testLongSentenceConsumesItsTailNoOverlapRefinalization() {
        let ledger = UtteranceLedger()
        var committedUpTo = 0.0

        // The window left edge is ~37 this hop (speech-only buffer), so the
        // horizon is ~42 — the long sentence STARTS (36.2) at/just before the
        // horizon and ENDS far past it (58.2). It is committed in full here.
        let longSentence = Seg(
            tStart: 36.2, tEnd: 58.2,
            text: "But this is the culmination of 10 years of work to basically miniaturize all the computing that you need to have glasses that can put full holograms in the world with a wide field of view.")

        // Subsequent hops re-decode the SAME audio span as the window slides,
        // and WhisperKit re-segments the tail of that one sentence into smaller
        // pieces whose starts fall INSIDE [36.2, 58.2]. These are the lines
        // 43/46/49/52 fragments from the trace.
        let frag1 = Seg(tStart: 43.0, tEnd: 47.0, text: "that we've done to basically miniaturize")
        let frag2 = Seg(tStart: 47.0, tEnd: 51.0, text: "computing that you need to have glasses")
        let frag3 = Seg(tStart: 51.0, tEnd: 55.0, text: "but glasses that can put full holograms")
        let frag4 = Seg(tStart: 55.0, tEnd: 58.0, text: "with a wide field of view. So you can imagine")

        let hops: [(windowStart: Double, segments: [Seg])] = [
            // windowStart 31.2 → horizon 36.2: the long sentence's start (36.2)
            // is exactly at the horizon → FINALIZE here, consuming up to 58.2.
            (31.2, [longSentence]),
            // windowStart 42.0 → horizon 47.0: frag1 (43.0) and frag2 are now
            // INSIDE the committed span (<= 58.2) → must be skipped.
            (42.0, [frag1, frag2]),
            // windowStart 47.0 → horizon 52.0: frag3 still inside → skipped.
            (47.0, [frag3]),
            // windowStart 52.0 → horizon 57.0: frag4 (55.0) still inside → skipped.
            (52.0, [frag4]),
        ]
        let emits = runHops(hops, ledger: ledger, committedUpTo: &committedUpTo)

        let finals = emits.filter(\.isFinal)
        // Exactly one final: the full long sentence. No tail fragments.
        XCTAssertEqual(finals.count, 1,
            "the long sentence is finalized once; its tail fragments must not re-finalize")
        XCTAssertEqual(finals.first?.tStart, 36.2)
        XCTAssertTrue(finals.first?.text.hasPrefix("But this is the culmination") ?? false)

        // The watermark consumed the long sentence's full span, not just the
        // horizon. (Old behavior advanced to ~42 and re-committed the tail.)
        XCTAssertEqual(committedUpTo, 58.2,
            "watermark advances to the committed segment's t_end, not just the horizon")

        // None of the overlapping tail fragments were emitted as finals. Match
        // on the fragments' OWN distinguishing text (the long sentence does not
        // contain "we've done" / "So you can imagine"), and assert no final
        // other than the one long sentence carries a fragment's exact text.
        let fragTexts = frag1.text + " | " + frag2.text + " | " + frag3.text + " | " + frag4.text
        for f in [frag1, frag2, frag3, frag4] {
            XCTAssertFalse(finals.contains { $0.tStart == f.tStart && $0.text == f.text },
                "tail fragment at \(f.tStart) must be skipped, not re-finalized (\(fragTexts))")
        }
        // And the lone final is exactly the long sentence start.
        XCTAssertEqual(finals.map(\.tStart), [36.2],
            "only the long sentence is a final; no tail-fragment starts appear")
    }

    // MARK: - Watermark monotonicity / never re-finalize behind it

    /// The watermark only ever advances, and a region whose start is at/before
    /// the current watermark is never finalized again — regardless of how many
    /// more hops re-decode it.
    func testWatermarkMonotonicAndNeverReFinalizesBehindIt() {
        let ledger = UtteranceLedger()
        var committedUpTo = 0.0
        let a = Seg(tStart: 3.0, tEnd: 4.0, text: "alpha")
        let b = Seg(tStart: 8.0, tEnd: 9.0, text: "bravo")

        // Hop 1: window [0..], horizon 5 → "alpha" (3<=5) finalizes, watermark→5.
        var emits = runHops([(0.0, [a, b])], ledger: ledger, committedUpTo: &committedUpTo)
        XCTAssertEqual(committedUpTo, 5.0)
        XCTAssertEqual(emits.filter { $0.isFinal }.map(\.text), ["alpha"])
        XCTAssertEqual(emits.filter { !$0.isFinal }.map(\.text), ["bravo"])

        // Hop 2: window [5..], horizon 10 → "alpha" now behind watermark (3<=5)
        // → skipped; "bravo" (8<=10) finalizes; watermark→10.
        emits = runHops([(5.0, [a, b])], ledger: ledger, committedUpTo: &committedUpTo)
        XCTAssertEqual(committedUpTo, 10.0)
        XCTAssertEqual(emits.filter { $0.isFinal }.map(\.text), ["bravo"],
            "alpha is behind the watermark and must not re-finalize")
        XCTAssertTrue(emits.allSatisfy { $0.text != "alpha" },
            "no emission at all for a region behind the watermark")

        // Hop 3: re-decode both again — neither re-emits, watermark unchanged-up.
        emits = runHops([(10.0, [a, b])], ledger: ledger, committedUpTo: &committedUpTo)
        XCTAssertEqual(committedUpTo, 15.0)
        XCTAssertTrue(emits.isEmpty, "everything is behind the watermark now")
    }

    // MARK: - Stop-flush drains the tail exactly once

    /// The live loop commits up to some watermark; capture.stop drains the
    /// remaining hot tail. The tail is finalized exactly once and the
    /// already-committed head is NOT re-emitted by the drain.
    func testStopFlushEmitsRemainingTailExactlyOnce() {
        let ledger = UtteranceLedger()
        var committedUpTo = 0.0
        // Live: commit up to 10 s.
        let head = Seg(tStart: 4.0, tEnd: 5.0, text: "committed head")
        _ = runHops([(0.0, [head]), (5.0, [head])], ledger: ledger, committedUpTo: &committedUpTo)
        XCTAssertEqual(committedUpTo, 10.0)

        // Drain re-decodes the whole tail buffer: the already-committed head
        // PLUS the still-hot tail [11..16].
        let tail1 = Seg(tStart: 11.0, tEnd: 13.0, text: "hot tail one")
        let tail2 = Seg(tStart: 13.0, tEnd: 16.0, text: "hot tail two")
        let drainEmits = runDrain(segments: [head, tail1, tail2],
                                  ledger: ledger,
                                  committedUpTo: &committedUpTo)

        XCTAssertEqual(drainEmits.map(\.text), ["hot tail one", "hot tail two"],
            "drain finalizes only the uncommitted tail, head is not re-emitted")
        XCTAssertTrue(drainEmits.allSatisfy { $0.isFinal })
        XCTAssertEqual(committedUpTo, 16.0, "watermark advances to the tail end")

        // A second drain (defensive) finds nothing left — tail1/tail2 are now
        // finalized entries, so the head guard skips them.
        let again = runDrain(segments: [tail1, tail2],
                             ledger: ledger,
                             committedUpTo: &committedUpTo)
        XCTAssertTrue(again.isEmpty, "nothing remains to drain after the first flush")
    }

    // MARK: - THE content-loss regression: the hot tail above the watermark
    //         must be finalized at stop, not dropped.

    /// The OLD drain gate (`tStart <= committedUpTo → skip`), kept here ONLY to
    /// prove the bug. It is the exact predicate the buggy uncommitted code used.
    /// The faithful fixed gate is `runDrain` (head-overlap based) above.
    private func runDrainOldWatermarkGate(segments: [Seg], committedUpTo: inout Double) -> [Emit] {
        let drainWatermark = committedUpTo
        var emits: [Emit] = []
        var tailEnd = drainWatermark
        for seg in segments {
            if seg.tStart <= drainWatermark { continue }  // the bug
            emits.append(Emit(isFinal: true, tStart: seg.tStart, text: seg.text))
            tailEnd = max(tailEnd, seg.tEnd)
        }
        committedUpTo = max(committedUpTo, tailEnd)
        return emits
    }

    /// THE defining test (verified on-device 2026-06-01: a 189.8 s capture lost
    /// its last ~30 s — everything still in the live window at capture.stop was
    /// only ever a `segment.partial`, never finalized, so it never reached the
    /// vault).
    ///
    /// Mechanism reproduced here: a long sentence straddles the commit horizon
    /// and is finalized live with its full span, so the straddle refinement
    /// advances `committedUpTo` to that sentence's far `t_end` — PAST later
    /// speech that began before the sentence ended. That later speech was shown
    /// live only as partials (its start was beyond the horizon on the hop it
    /// appeared) and then sat behind the over-advanced watermark, never
    /// finalized. At capture.stop the drain must finalize it.
    ///
    /// FAIL-BEFORE: the old `tStart <= committedUpTo → skip` gate drops the tail
    /// (its start is behind the watermark). PASS-AFTER: the head-overlap gate
    /// finalizes it (it never overlapped a finalized entry) and the watermark
    /// advances to the end of captured audio.
    func testStopDrainFinalizesHotTailAboveWatermark() {
        let ledger = UtteranceLedger()
        var committedUpTo = 0.0

        // A long sentence [12, 40] straddles this hop's horizon (windowStart 10
        // → horizon 15; 10 < 12 <= 15 → finalize), so the watermark advances to
        // its t_end, 40 — well past the hot tail below.
        let longSentence = Seg(tStart: 12.0, tEnd: 40.0,
            text: "this is one long uninterrupted thought that runs for many seconds")
        // Real later speech [30, 45], shown live only as a partial: on the hop it
        // appears, its start (30) is beyond the horizon (15). On later hops its
        // start (30) is behind the over-advanced watermark (40) → skipped. It is
        // NEVER finalized during the live loop. This is the dropped tail.
        let hotTail = Seg(tStart: 30.0, tEnd: 45.0,
            text: "the trailing content spoken right before the user pressed stop")

        // Hop 1: commit the long sentence (watermark → 40); the tail is a partial.
        var emits = runHops([(10.0, [longSentence, hotTail])],
                            ledger: ledger, committedUpTo: &committedUpTo)
        XCTAssertEqual(committedUpTo, 40.0,
            "the straddle refinement advances the watermark to the long sentence's t_end")
        XCTAssertEqual(emits.filter { $0.isFinal }.map(\.text), [longSentence.text])
        XCTAssertTrue(emits.contains(Emit(isFinal: false, tStart: 30.0, text: hotTail.text)),
            "the tail was shown live as a partial")

        // Later hops slide forward; the tail is now behind the watermark → never
        // finalized live (this is the precondition that makes the drop possible).
        emits = runHops([(15.0, [hotTail]), (20.0, [hotTail]), (25.0, [hotTail])],
                        ledger: ledger, committedUpTo: &committedUpTo)
        XCTAssertTrue(emits.allSatisfy { !$0.isFinal },
            "the tail is behind the watermark; the live loop never finalizes it")
        XCTAssertFalse(ledger.overlapsFinalized(tStart: 30.0, tEnd: 45.0),
            "precondition: the hot tail is NOT yet a finalized region")

        // --- FAIL-BEFORE: the old watermark gate drops the tail entirely. ---
        var wmCommitted = committedUpTo
        let buggyDrain = runDrainOldWatermarkGate(
            segments: [longSentence, hotTail], committedUpTo: &wmCommitted)
        XCTAssertFalse(buggyDrain.contains { $0.text == hotTail.text },
            "regression witness: the OLD gate drops the hot tail (tStart 30 <= watermark 40)")

        // --- PASS-AFTER: the fixed (head-overlap) drain finalizes the tail. ---
        let drainEmits = runDrain(segments: [longSentence, hotTail],
                                  ledger: ledger, committedUpTo: &committedUpTo)
        XCTAssertTrue(drainEmits.contains { $0.isFinal && $0.text == hotTail.text },
            "the stop-drain must finalize the hot tail that lived above the watermark")
        XCTAssertFalse(drainEmits.contains { $0.text == longSentence.text },
            "the already-committed head must NOT be re-finalized by the drain")
        XCTAssertEqual(committedUpTo, 45.0,
            "the watermark advances to the end of captured audio after the drain")
    }

    /// No-duplication: the drained tail must not duplicate content the live loop
    /// already committed, even when the drain re-decodes the whole buffer
    /// (committed head + hot tail). The head guard (`overlapsFinalized`) and the
    /// ledger's `isFinalized` together prevent it.
    func testStopDrainDoesNotDuplicateAlreadyCommitted() {
        let ledger = UtteranceLedger()
        var committedUpTo = 0.0

        // Three regions committed live across hops; the window left edge slides.
        let a = Seg(tStart: 3.0, tEnd: 6.0, text: "alpha committed early")
        let b = Seg(tStart: 8.0, tEnd: 12.0, text: "bravo committed mid")
        let c = Seg(tStart: 14.0, tEnd: 17.0, text: "charlie committed late")
        _ = runHops([(0.0, [a, b, c]), (5.0, [b, c]), (10.0, [c])],
                    ledger: ledger, committedUpTo: &committedUpTo)
        // a, b, c all finalized live (each aged into a commit band).
        XCTAssertTrue(ledger.overlapsFinalized(tStart: a.tStart, tEnd: a.tEnd))
        XCTAssertTrue(ledger.overlapsFinalized(tStart: b.tStart, tEnd: b.tEnd))
        XCTAssertTrue(ledger.overlapsFinalized(tStart: c.tStart, tEnd: c.tEnd))

        // The drain re-decodes the whole buffer: the committed head a/b/c PLUS a
        // genuinely-new hot tail [20, 23] that was never finalized.
        let tail = Seg(tStart: 20.0, tEnd: 23.0, text: "delta the only uncommitted tail")
        let drainEmits = runDrain(segments: [a, b, c, tail],
                                  ledger: ledger, committedUpTo: &committedUpTo)

        XCTAssertEqual(drainEmits.map(\.text), [tail.text],
            "only the uncommitted tail is finalized; a/b/c are not re-emitted")
        XCTAssertTrue(drainEmits.allSatisfy { $0.isFinal })
        XCTAssertEqual(committedUpTo, 23.0)
    }

    // MARK: - Live partials for the hot region are not suppressed

    /// The hot region (after the watermark, ahead of the horizon) still emits
    /// `segment.partial` and refreshes in place across hops — the watermark
    /// must NOT swallow it. This guards the validated live caption experience.
    func testHotRegionStillEmitsAndUpdatesPartials() {
        let ledger = UtteranceLedger()
        var committedUpTo = 0.0
        // A growing utterance in the live tail across two hops, same region.
        let grow1 = Seg(tStart: 22.0, tEnd: 24.0, text: "we are getting")
        let grow2 = Seg(tStart: 22.0, tEnd: 26.0, text: "we are getting there")
        // windowStart 0 → horizon 5; 22 > 5 → partial both times.
        let emits = runHops([(0.0, [grow1]), (0.0, [grow2])], ledger: ledger, committedUpTo: &committedUpTo)

        let partials = emits.filter { !$0.isFinal }
        XCTAssertEqual(partials.count, 2, "the hot region keeps emitting partials")
        XCTAssertEqual(partials.map(\.text), ["we are getting", "we are getting there"],
            "partials refresh in place as the utterance grows")
        XCTAssertTrue(emits.allSatisfy { !$0.isFinal },
            "nothing in the hot region is finalized yet")
    }

    // MARK: - A genuine repeated phrase at a later region still gets its own final

    /// The SAME phrase spoken again at a clearly-later, separate audio region
    /// must still produce its OWN final — the watermark commits regions, not
    /// text, so an identical phrase later is a different region and is committed
    /// independently. (Region commit is time-grounded by design, like the
    /// ADR-0018 supersession gate.)
    func testRepeatedPhraseAtLaterRegionGetsItsOwnFinal() {
        let ledger = UtteranceLedger()
        var committedUpTo = 0.0
        let phrase = "thanks everyone"
        let early = Seg(tStart: 3.0, tEnd: 4.5, text: phrase)
        let late = Seg(tStart: 48.0, tEnd: 49.5, text: phrase)

        // Hop A commits the early one (3 <= 5), watermark → 5.
        var emits = runHops([(0.0, [early])], ledger: ledger, committedUpTo: &committedUpTo)
        XCTAssertEqual(emits.filter { $0.isFinal }.map(\.text), [phrase])

        // Much later, the window has slid forward; the late repeat ages into
        // its own commit band (45 < 48 <= 50), watermark → 50.
        emits = runHops([(45.0, [late])], ledger: ledger, committedUpTo: &committedUpTo)
        XCTAssertEqual(emits.filter { $0.isFinal }.map(\.text), [phrase],
            "an identical phrase at a separate later region still finalizes once")
        XCTAssertEqual(committedUpTo, 50.0)
    }

    // MARK: - THE real content-loss regression: at stop, finalize the ledger's
    //         live hot-region entries DIRECTLY (no re-transcription).
    //
    // The previous "fix" only changed the re-transcription drain's predicate and
    // tested a REIMPLEMENTATION of the drain (`runDrain` above). On device the
    // drain never re-produces the hot-region segments from the residual buffer,
    // so the tail stayed dropped. The real fix finalizes the ledger's LIVE
    // entries above the watermark directly. These tests drive the REAL
    // `UtteranceLedger.liveEntriesAbove` + the REAL
    // `EngineSession.hotRegionFinalizeDecision` — the same functions the live
    // stop path (`finalizeHotRegion`) calls — NOT a reimplementation.

    /// Reproduces the on-device drop (2026-06-01, 203.6 s clip): a long straddle
    /// sentence finalizes live and over-advances the watermark past trailing
    /// speech that was only ever shown as `segment.partial`. The live loop never
    /// finalizes that tail (its start was beyond the horizon, then behind the
    /// watermark). At stop, the hot-region finalize must recover ALL of it.
    ///
    /// FAIL-BEFORE: with no `finalizeHotRegion` step, the ledger's live tail
    /// entries are never finalized (they remain non-finalized in the ledger and
    /// never reach `finalizedUtterances`) — `liveEntriesAbove` returns them and
    /// the old code did nothing with them. PASS-AFTER: the pure decision returns
    /// every one of them and advances the watermark to end-of-audio.
    func testStopFinalizesLedgerHotRegionDirectly() {
        let ledger = UtteranceLedger()
        var committedUpTo = 0.0

        // Live hops: a long straddle sentence [12, 40] finalizes (watermark→40),
        // and FIVE trailing utterances [40..62] are shown only as partials —
        // each minted + updated by the live loop exactly as `runTranscription`
        // does (resolve → updateText), then left non-finalized because their
        // starts are beyond the horizon and then behind the watermark.
        let longSentence = Seg(tStart: 12.0, tEnd: 40.0,
            text: "this is one long uninterrupted thought that runs for many seconds")
        _ = runHops([(10.0, [longSentence])], ledger: ledger, committedUpTo: &committedUpTo)
        XCTAssertEqual(committedUpTo, 40.0,
            "straddle refinement advances the watermark to the long sentence's t_end")

        // The five lost partials from the on-device trace (paraphrased; the test
        // only cares about identity + timing). They all START above 40 (the
        // watermark) and run to the end of audio (~62). The live loop emits them
        // as partials and updates their text — never finalizes them.
        let tailTexts = [
            "it's everything in here from the micro projectors",
            "it's a special type of display system",
            "i mean these aren't normal displays",
            "it's a waveguide system",
            "the projector that's shooting light basically goes into the",
        ]
        var tailIds: [String] = []
        var t = 41.0
        for txt in tailTexts {
            let id = ledger.resolve(tStart: t, tEnd: t + 4.0, text: txt)
            _ = ledger.updateText(txt, utteranceId: id)
            tailIds.append(id)
            t += 4.0
        }
        let audioEnd = t  // last tEnd
        // None of these are finalized by the live loop.
        for id in tailIds {
            XCTAssertFalse(ledger.isFinalized(utteranceId: id),
                "precondition: hot-region partials are NOT finalized live")
        }

        // --- FAIL-BEFORE WITNESS: the OLD stop path dropped this tail. ---
        // The old code's only at-stop step was the re-transcription drain. On
        // device that drain (a) ran with a nil ledger (session state was wiped
        // before the detached flush Task executed) and/or (b) re-decoded a
        // residual buffer that did not reproduce these already-hopped segments —
        // so it finalized NOTHING here. With no hot-region finalize step, every
        // tail entry stays non-finalized and never reaches `finalizedUtterances`
        // → dropped from the vault. We witness that precondition explicitly:
        // before applying the fix's decision, the tail is entirely un-finalized.
        XCTAssertTrue(tailIds.allSatisfy { !ledger.isFinalized(utteranceId: $0) },
            "FAIL-BEFORE: without finalizeHotRegion the whole tail is dropped (un-finalized)")

        // --- The REAL accessor: every hot-region partial is enumerated. ---
        let live = ledger.liveEntriesAbove(committedUpTo)
        XCTAssertEqual(live.map(\.id), tailIds,
            "liveEntriesAbove must return ALL non-finalized entries above the watermark, in t_start order")
        XCTAssertEqual(live.map(\.lastText), tailTexts,
            "each live entry carries its last-known partial text (what the user saw)")

        // --- The REAL pure decision the stop path uses. ---
        let decision = EngineSession.hotRegionFinalizeDecision(
            liveEntries: live, committedUpTo: committedUpTo)
        XCTAssertEqual(decision.toFinalize.map(\.id), tailIds,
            "the stop path finalizes EVERY hot-region partial")
        XCTAssertEqual(decision.advanceTo, audioEnd, accuracy: 0.001,
            "the watermark advances to the end of captured audio")
        XCTAssertEqual(decision.audioEnd, audioEnd, accuracy: 0.001)

        // Apply the decision the way `finalizeHotRegion` does, and assert the
        // ledger ends with the whole tail finalized (nothing left above the
        // watermark). This is what reaches the vault.
        for e in decision.toFinalize {
            XCTAssertFalse(ledger.overlapsFinalized(tStart: e.tStart, tEnd: e.tEnd),
                "the hot tail does not overlap the finalized straddle head")
            ledger.markFinalized(utteranceId: e.id)
        }
        committedUpTo = max(committedUpTo, decision.advanceTo)
        XCTAssertTrue(ledger.liveEntriesAbove(committedUpTo).isEmpty,
            "after the stop finalize nothing remains un-finalized above the watermark")
        for id in tailIds {
            XCTAssertTrue(ledger.isFinalized(utteranceId: id),
                "every hot-region partial is now finalized and will reach the vault")
        }
    }

    /// The hot-region finalize must NOT re-finalize entries already finalized
    /// live, and must NOT touch superseded fragments. `liveEntriesAbove` filters
    /// both out. (Drives the REAL ledger filtering.)
    func testHotRegionFinalizeSkipsFinalizedAndSuperseded() {
        let ledger = UtteranceLedger()
        let committedUpTo = 10.0

        // Already finalized live, above the watermark — must be excluded.
        let doneId = ledger.resolve(tStart: 12.0, tEnd: 14.0, text: "already final")
        _ = ledger.updateText("already final", utteranceId: doneId)
        ledger.markFinalized(utteranceId: doneId)

        // A superseded fragment — must be excluded (retracted, never resurrected).
        let shortId = ledger.resolve(tStart: 20.0, tEnd: 22.0, text: "hello there")
        _ = ledger.updateText("hello there", utteranceId: shortId)
        let grownId = ledger.resolve(tStart: 20.0, tEnd: 29.0, text: "hello there general kenobi")
        _ = ledger.updateText("hello there general kenobi", utteranceId: grownId)
        XCTAssertEqual(ledger.drainSupersessions().count, 1, "the short fragment is superseded")

        // A genuine live hot-region partial — must be INCLUDED.
        let liveId = ledger.resolve(tStart: 35.0, tEnd: 38.0, text: "the trailing content")
        _ = ledger.updateText("the trailing content", utteranceId: liveId)

        let live = ledger.liveEntriesAbove(committedUpTo)
        let ids = live.map(\.id)
        XCTAssertTrue(ids.contains(liveId), "the live hot-region partial is finalized")
        XCTAssertTrue(ids.contains(grownId), "the surviving grown utterance is finalized")
        XCTAssertFalse(ids.contains(doneId), "an already-finalized entry is not re-finalized")
        XCTAssertFalse(ids.contains(shortId), "a superseded fragment is never resurrected")
    }

    /// Entries at/below the watermark are NOT touched by the hot-region finalize
    /// — only strictly-above-watermark live content is the un-finalized tail.
    func testHotRegionFinalizeIgnoresContentBelowWatermark() {
        let ledger = UtteranceLedger()
        let committedUpTo = 30.0
        // Below the watermark (committed region) — never re-emitted.
        let belowId = ledger.resolve(tStart: 25.0, tEnd: 28.0, text: "old committed region")
        _ = ledger.updateText("old committed region", utteranceId: belowId)
        // Above — the tail.
        let aboveId = ledger.resolve(tStart: 31.0, tEnd: 34.0, text: "fresh tail")
        _ = ledger.updateText("fresh tail", utteranceId: aboveId)

        let live = ledger.liveEntriesAbove(committedUpTo)
        XCTAssertEqual(live.map(\.id), [aboveId],
            "only strictly-above-watermark live entries are part of the hot region")
        XCTAssertFalse(live.contains { $0.id == belowId })
    }

    /// On-device magnitudes (2026-06-01 trace): 203.6 s capture, last live
    /// `segment.final` ended ~174 s, and the content from ~174→199 s
    /// (07CAF2E0, C4159D3D, D6110DA7, 169ABCE5, BA9886A9) was emitted ONLY as
    /// partials and never finalized. After the fix, the stop finalize must
    /// recover that whole tail and the watermark must reach ~199 s (≈ the last
    /// utterance's end, which is what the diagnostic's "Y" reports). Drives the
    /// REAL ledger + REAL decision.
    func testHotRegionFinalizeMatchesOnDeviceTrace() {
        let ledger = UtteranceLedger()
        var committedUpTo = 0.0

        // Live loop committed up to ~174 s (the last finalized region).
        let lastFinal = Seg(tStart: 170.0, tEnd: 174.0,
            text: "there's not a single millimeter of space")
        _ = runHops([(168.0, [lastFinal])], ledger: ledger, committedUpTo: &committedUpTo)
        XCTAssertGreaterThanOrEqual(committedUpTo, 174.0,
            "the live loop committed through ~174 s")
        let watermarkAfterLive = committedUpTo

        // The five trailing partials [174..199], never finalized live (their
        // starts were beyond each hop's horizon, then behind the watermark).
        let tail: [(Double, Double, String)] = [
            (174.0, 179.0, "it's everything in here from the micro projectors that basically shoot light into the waveguides"),
            (179.0, 184.0, "it's a special type of display system"),
            (184.0, 189.0, "i mean these aren't normal displays"),
            (189.0, 194.0, "it's a waveguide system"),
            (194.0, 199.0, "the projector that's shooting light basically goes into the"),
        ]
        var tailIds: [String] = []
        for (s, e, txt) in tail {
            let id = ledger.resolve(tStart: s, tEnd: e, text: txt)
            _ = ledger.updateText(txt, utteranceId: id)
            tailIds.append(id)
        }

        // REAL accessor + REAL decision — the stop path's actual functions.
        let live = ledger.liveEntriesAbove(committedUpTo)
        let decision = EngineSession.hotRegionFinalizeDecision(
            liveEntries: live, committedUpTo: committedUpTo)

        XCTAssertEqual(decision.toFinalize.count, 5,
            "all 5 lost partials are recovered (N>0 in the on-device diagnostic)")
        XCTAssertEqual(decision.toFinalize.map(\.id), tailIds)
        XCTAssertEqual(decision.committedUpToBefore, watermarkAfterLive)
        XCTAssertEqual(decision.advanceTo, 199.0, accuracy: 0.001,
            "watermark advances to the last utterance's end (~199 s ≈ end of audio)")
        XCTAssertEqual(decision.audioEnd, 199.0, accuracy: 0.001)
    }

    /// Empty / no-hot-region case: when everything was already finalized live,
    /// the decision finalizes nothing and the watermark is unchanged.
    func testHotRegionFinalizeNoOpWhenNothingLive() {
        let ledger = UtteranceLedger()
        var committedUpTo = 50.0
        let live = ledger.liveEntriesAbove(committedUpTo)
        XCTAssertTrue(live.isEmpty)
        let decision = EngineSession.hotRegionFinalizeDecision(
            liveEntries: live, committedUpTo: committedUpTo)
        XCTAssertTrue(decision.toFinalize.isEmpty)
        XCTAssertEqual(decision.advanceTo, 50.0)
        committedUpTo = max(committedUpTo, decision.advanceTo)
        XCTAssertEqual(committedUpTo, 50.0)
    }

    // MARK: - THE stranded-partial regression (ADR-0019 prune-orphan fix)
    //
    // The reconcile loop prunes ledger entries that fall behind the sliding
    // window. For a NON-finalized, NON-superseded orphan a `segment.partial`
    // was already shown, so it needs CLOSURE or the renderer keeps it as a
    // partial forever (the user-reported bug: an early line strands in the
    // live-tail block at the bottom of the screen while the meeting is at 2:13).
    //
    // The closure is split by the watermark (`prunedOrphanDisposition`):
    //   - AHEAD of the watermark (never committed)  → synthetic `segment.final`.
    //   - BEHIND the watermark (already committed once) → RETRACT via
    //     `segment.superseded` (empty `superseded_by`) — a synthetic final there
    //     would re-emit committed audio (the ADR-0019 duplicate). These tests
    //     drive the REAL `UtteranceLedger.prune` + the REAL
    //     `EngineSession.prunedOrphanDisposition`, so the live prune loop and the
    //     regression share one definition of "close this orphan."

    /// One closure the prune loop produced, for assertions.
    private enum OrphanClosure: Equatable {
        case synthFinal(id: String, text: String)
        case retract(id: String)
    }

    /// Faithful reimplementation of the FIXED prune-orphan closure in
    /// `runTranscription` (the loop at ~line 1193): prune below `windowStart`,
    /// then for each non-finalized, non-superseded orphan apply the pure
    /// disposition. Drives the REAL ledger so the prune filters
    /// (finalized/superseded) and the REAL decision are both exercised.
    private func runPruneClosure(ledger: UtteranceLedger,
                                 windowStart: Double,
                                 committedUpTo: Double) -> [OrphanClosure] {
        var closures: [OrphanClosure] = []
        let pruned = ledger.prune(beforeSessionTime: windowStart)
        for p in pruned where !p.wasFinalized && !p.wasSuperseded {
            switch EngineSession.prunedOrphanDisposition(orphanStart: p.tStart,
                                                         committedUpTo: committedUpTo) {
            case .synthesizeFinal:
                closures.append(.synthFinal(id: p.id, text: p.lastText))
            case .retract:
                closures.append(.retract(id: p.id))
            }
        }
        return closures
    }

    /// THE defining test: a non-finalized, non-superseded entry whose region is
    /// already BEHIND the commit watermark gets pruned → it must be RETRACTED
    /// (a `segment.superseded` for its id), NOT closed with a synthetic final.
    ///
    /// FAIL-BEFORE: the old code did `if p.tStart <= committedUpTo { continue }`
    /// — emitting NEITHER a final NOR a retraction, so the renderer's partial
    /// for that id dangled forever (the stranded-partial bug).
    /// PASS-AFTER: the disposition returns `.retract`, so the UI drops the id.
    func testPrunedOrphanBehindWatermarkIsRetractedNotFinalized() {
        let ledger = UtteranceLedger()
        // The watermark is at 60 s: everything up to 60 was committed once. A
        // straddle long sentence (committed earlier) over-advanced it past an
        // early utterance that was only ever shown as a partial.
        let committedUpTo = 60.0

        // The stranded early partial at ~9 s: minted + text-updated by the live
        // loop exactly as `runTranscription` does, never finalized, never
        // superseded. Its region (9..12) is now far behind the watermark (60).
        let strandedId = ledger.resolve(tStart: 9.0, tEnd: 12.0,
                                        text: "an early line that strands at the bottom")
        _ = ledger.updateText("an early line that strands at the bottom",
                              utteranceId: strandedId)
        XCTAssertFalse(ledger.isFinalized(utteranceId: strandedId),
            "precondition: the orphan was only ever a partial")

        // The window has slid forward to ~50 s; the orphan's tEnd (12) is below
        // the window's left edge, so the live prune drops it.
        let closures = runPruneClosure(ledger: ledger,
                                       windowStart: 50.0,
                                       committedUpTo: committedUpTo)

        XCTAssertEqual(closures, [.retract(id: strandedId)],
            "an orphan behind the watermark is RETRACTED so the UI drops it")
        // And explicitly: NO synthetic final for it (no duplicate of committed audio).
        XCTAssertFalse(closures.contains { if case .synthFinal = $0 { return true }; return false },
            "a behind-watermark orphan must NOT get a synthetic final (ADR-0019 no-dup)")
    }

    /// The complementary case: an orphan AHEAD of the watermark (never
    /// committed) still gets a synthetic `segment.final` — the ADR-0009 closure
    /// for a dangling hot-region partial that aged out without finalizing. This
    /// pins that the fix did NOT regress the normal orphan-final path.
    func testPrunedOrphanAheadOfWatermarkStillSynthesizesFinal() {
        let ledger = UtteranceLedger()
        let committedUpTo = 10.0  // watermark behind the orphan's region.

        // A hot-region partial at ~14 s that ages out of the window before it
        // was ever committed (e.g. window slid past it on a quiet stretch).
        let hotId = ledger.resolve(tStart: 14.0, tEnd: 16.0, text: "a hot partial that aged out")
        _ = ledger.updateText("a hot partial that aged out", utteranceId: hotId)

        let closures = runPruneClosure(ledger: ledger,
                                       windowStart: 18.0,   // 16 < 18 → pruned
                                       committedUpTo: committedUpTo)

        XCTAssertEqual(closures, [.synthFinal(id: hotId, text: "a hot partial that aged out")],
            "an orphan ahead of the watermark is closed with a synthetic final (ADR-0009)")
        XCTAssertFalse(closures.contains { if case .retract = $0 { return true }; return false },
            "an ahead-of-watermark orphan must NOT be retracted")
    }

    /// The prune loop must not touch finalized or superseded entries (the
    /// `where` clause filters them) — neither a retraction nor a synthetic
    /// final fires for them. Drives the REAL ledger's prune flags.
    func testPruneClosureSkipsFinalizedAndSupersededOrphans() {
        let ledger = UtteranceLedger()
        let committedUpTo = 60.0

        // Finalized live, then aged out — no closure (it already has a final).
        let finalId = ledger.resolve(tStart: 5.0, tEnd: 7.0, text: "already final")
        _ = ledger.updateText("already final", utteranceId: finalId)
        ledger.markFinalized(utteranceId: finalId)

        // Superseded by a grown re-segmentation, then aged out — no closure (it
        // was already retracted in favour of the survivor; a final would
        // resurrect the fragment, ADR-0018).
        let shortId = ledger.resolve(tStart: 20.0, tEnd: 22.0, text: "hello there")
        _ = ledger.updateText("hello there", utteranceId: shortId)
        let grownId = ledger.resolve(tStart: 20.0, tEnd: 30.0, text: "hello there general kenobi")
        _ = ledger.updateText("hello there general kenobi", utteranceId: grownId)
        XCTAssertEqual(ledger.drainSupersessions().count, 1, "the short fragment is superseded")
        ledger.markFinalized(utteranceId: grownId)  // survivor finalized.

        // A genuine stranded orphan behind the watermark — the ONLY closure.
        let strandedId = ledger.resolve(tStart: 8.0, tEnd: 10.0, text: "the stranded one")
        _ = ledger.updateText("the stranded one", utteranceId: strandedId)

        // Window slides past all of them (max tEnd is 30 → cutoff 31 prunes all).
        let closures = runPruneClosure(ledger: ledger,
                                       windowStart: 31.0,
                                       committedUpTo: committedUpTo)

        XCTAssertEqual(closures, [.retract(id: strandedId)],
            "only the non-finalized, non-superseded orphan behind the watermark is closed (retracted)")
    }

    /// The watermark boundary for the disposition mirrors `commitDecision`:
    /// `start <= committedUpTo` → retract (already committed), strictly-above →
    /// synthesize a final. Pin the exact boundary.
    func testPrunedOrphanDispositionBoundaries() {
        // start == watermark → already committed → retract.
        XCTAssertEqual(
            EngineSession.prunedOrphanDisposition(orphanStart: 10.0, committedUpTo: 10.0),
            .retract)
        // start below the watermark → retract.
        XCTAssertEqual(
            EngineSession.prunedOrphanDisposition(orphanStart: 4.0, committedUpTo: 10.0),
            .retract)
        // start just above the watermark → never committed → synthesize final.
        XCTAssertEqual(
            EngineSession.prunedOrphanDisposition(orphanStart: 10.01, committedUpTo: 10.0),
            .synthesizeFinal)
    }

    // MARK: - THE grown-after-commit content-loss regression (ADR-0020)
    //
    // The commit watermark finalizes a region ONCE, when a segment's START first
    // crosses the horizon. For a long multi-clause utterance that finalizes the
    // SHORT decode present at that hop; the watermark advances past its start.
    // A later hop re-decodes the GROWN version (same start, fuller text):
    // `resolve` skips finalized entries → fresh uid → `commitDecision` sees the
    // start behind the watermark → `.skipAlreadyCommitted` → the grown TAIL is
    // dropped and the saved transcript truncates at the short version.
    //
    // The fix (extendFinalizedIfGrown, gated like ADR-0018 supersession but aimed
    // at finalized entries) EXTENDS the finalized line in place. These tests
    // drive the REAL `UtteranceLedger.extendFinalizedIfGrown` and the REAL
    // hop loop (which now mirrors the grow path), NOT a reimplementation.

    /// THE defining test: finalize a short utterance, then feed a grown
    /// re-decode (prefix superset, extends past). After the fix the finalized
    /// line holds the FULL text, there is exactly ONE finalized row for that uid
    /// (no orphan, no duplicate), and the grown tail is NOT lost.
    ///
    /// FAIL-BEFORE: the grown re-decode minted a fresh uid, hit
    /// `.skipAlreadyCommitted` (its start behind the watermark), and the tail
    /// ("You know, this is the first version…") never reached the vault.
    func testGrownReDecodeExtendsFinalizedLineNoTruncation() {
        let ledger = UtteranceLedger()
        var committedUpTo = 0.0
        var retained: [String: (tStart: Double, tEnd: Double, text: String)] = [:]
        var retainedOrder: [String] = []

        let short = "So, but this is just the beginning."
        let grown = "So, but this is just the beginning. You know, this is the first version. It's a prototype."

        // Hop 1: window [0..], horizon 5. The short decode [3.0, 6.0] starts at
        // 3.0 (3 <= 5) → FINALIZED; watermark advances to its tEnd (6.0).
        let shortSeg = Seg(tStart: 3.0, tEnd: 6.0, text: short)
        // Hop 2: the SAME region re-decodes fuller — same start, extends to 11.0.
        // windowStart 0 again here is irrelevant: the grow path fires before the
        // commit decision, so the watermark can't drop it.
        let grownSeg = Seg(tStart: 3.0, tEnd: 11.0, text: grown)

        let emits = runHopsTracked(
            [(0.0, [shortSeg]), (0.0, [grownSeg])],
            ledger: ledger, committedUpTo: &committedUpTo,
            retained: &retained, retainedOrder: &retainedOrder)

        // EXPORT-ONLY growth (ADR-0036): only the SHORT final is broadcast live —
        // the grow updates the retained (vault) row WITHOUT re-broadcasting, so
        // the live stream keeps the one discrete short line (no rewrite live).
        let finals = emits.filter(\.isFinal)
        XCTAssertEqual(finals.count, 1, "only the short final is broadcast live; the grow is export-only (no re-emit)")
        XCTAssertEqual(finals[0].text, short)

        // Exactly ONE retained row for that uid, holding the FULL grown text — no
        // orphan, no duplicate. This is what reaches the vault (export recovers
        // the tail even though the live view never showed it).
        XCTAssertEqual(retainedOrder.count, 1, "exactly one finalized utterance retained")
        let uid = finals[0].uid
        XCTAssertEqual(retained[uid]?.text, grown,
            "the retained (saved) line holds the FULL grown text, not the truncated short version")
        XCTAssertEqual(retained[uid]?.tEnd, 11.0,
            "the retained line's tEnd grew to the fuller decode's end")

        // The watermark consumed the grown span's full end.
        XCTAssertEqual(committedUpTo, 11.0,
            "the whole grown span is now committed")
    }

    /// A nearby-start segment whose text is NOT a prefix of the finalized line is
    /// a DIFFERENT utterance — `extendFinalizedIfGrown` must return nil (never
    /// merge two distinct utterances). Same conservative protection ADR-0018 uses.
    func testDistinctUtteranceDoesNotExtendFinalizedLine() {
        let ledger = UtteranceLedger()

        // Finalize a line directly via the real ledger.
        let id = ledger.resolve(tStart: 10.0, tEnd: 13.0, text: "Let's start the design review.")
        _ = ledger.updateText("Let's start the design review.", utteranceId: id)
        ledger.markFinalized(utteranceId: id)

        // A nearby-start, time-contained segment whose text is NOT a prefix —
        // genuinely different words. Must NOT extend.
        let grown = ledger.extendFinalizedIfGrown(
            tStart: 10.5, tEnd: 18.0,
            text: "Completely different sentence about something else entirely.")
        XCTAssertNil(grown,
            "a non-prefix re-decode is a distinct utterance and must never merge")

        // The finalized line is untouched: still its original text/end.
        XCTAssertTrue(ledger.overlapsFinalized(tStart: 10.0, tEnd: 13.0))
    }

    /// An IDENTICAL re-decode of an already-finalized line adds nothing —
    /// `extendFinalizedIfGrown` must return nil (no spurious re-emit). The
    /// "actually grew" guard (tEnd > e.tEnd OR longer normalized text) is what
    /// makes this a no-op.
    func testIdenticalReDecodeIsNoOp() {
        let ledger = UtteranceLedger()
        let text = "This is a complete thought."
        let id = ledger.resolve(tStart: 5.0, tEnd: 9.0, text: text)
        _ = ledger.updateText(text, utteranceId: id)
        ledger.markFinalized(utteranceId: id)

        // Exact same interval + text.
        XCTAssertNil(ledger.extendFinalizedIfGrown(tStart: 5.0, tEnd: 9.0, text: text),
            "an identical re-decode must not re-emit")
        // Same text, sub-slack end wobble that does NOT extend past the entry's
        // end (9.0): still a no-op (normalized text is identical, tEnd not >).
        XCTAssertNil(ledger.extendFinalizedIfGrown(tStart: 5.0, tEnd: 8.8, text: text),
            "punctuation/boundary jitter with identical normalized text is a no-op")
    }

    /// Only FINALIZED entries are extended by this path. A non-finalized overlap
    /// (a live partial that grows) is the existing supersession/partial path's
    /// job, NOT this one — `extendFinalizedIfGrown` must return nil for it.
    func testOnlyFinalizedEntriesAreExtended() {
        let ledger = UtteranceLedger()

        // A LIVE (non-finalized) partial.
        let liveId = ledger.resolve(tStart: 20.0, tEnd: 23.0, text: "we are getting")
        _ = ledger.updateText("we are getting", utteranceId: liveId)
        XCTAssertFalse(ledger.isFinalized(utteranceId: liveId))

        // A grown prefix-superset of that live partial — must NOT be taken by the
        // finalized-extend path (it isn't finalized). Returns nil; the caller
        // then handles it via resolve (live partial refresh) / supersession.
        let grown = ledger.extendFinalizedIfGrown(
            tStart: 20.0, tEnd: 27.0, text: "we are getting there now")
        XCTAssertNil(grown,
            "a non-finalized overlap is handled by the partial/supersession path, not the finalized-extend path")
    }

    // MARK: - Decision-function unit checks (boundaries)

    /// The straddle rule is `start <= commitHorizon` and the exactly-once guard
    /// is `committedUpTo < start`. Pin the exact boundary semantics.
    func testCommitDecisionBoundaries() {
        // start == committedUpTo → already committed (skip).
        XCTAssertEqual(
            EngineSession.commitDecision(segmentStart: 5.0, committedUpTo: 5.0, commitHorizon: 10.0),
            .skipAlreadyCommitted)
        // committedUpTo < start <= horizon → finalize. start == horizon counts.
        XCTAssertEqual(
            EngineSession.commitDecision(segmentStart: 10.0, committedUpTo: 5.0, commitHorizon: 10.0),
            .finalize)
        XCTAssertEqual(
            EngineSession.commitDecision(segmentStart: 7.5, committedUpTo: 5.0, commitHorizon: 10.0),
            .finalize)
        // start just past the horizon → still hot → partial.
        XCTAssertEqual(
            EngineSession.commitDecision(segmentStart: 10.01, committedUpTo: 5.0, commitHorizon: 10.0),
            .partial)
        // start before the watermark → skip even if also before horizon.
        XCTAssertEqual(
            EngineSession.commitDecision(segmentStart: 2.0, committedUpTo: 5.0, commitHorizon: 10.0),
            .skipAlreadyCommitted)
    }
}
