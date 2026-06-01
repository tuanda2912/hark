// UtteranceLedgerTests — regression coverage for the overlap-based
// identity rule. The numbers in `testEngulfmentFromSmokeTrace_20260528`
// are taken directly from the 2026-05-28 smoke test that caught the
// engulfment bug fixed in this commit. See ADR-0009 for full context.

import XCTest
@testable import Harkd

final class UtteranceLedgerTests: XCTestCase {

    // MARK: - Engulfment regression (the bug this commit fixes)

    /// Reproduces the exact 1C4B2CBA failure from the 2026-05-28 smoke
    /// trace. Before the fix: `1C4B2CBA` "Okay." [18.06, 23.24] would
    /// match a coarse new segment [15.66, 32.70] "the scheme where they
    /// provide…" because `overlap / min(shorter)` = 5.18 / 5.18 = 1.0.
    /// After the fix: `overlap / max(longer)` = 5.18 / 17.04 ≈ 0.30,
    /// well below the 0.5 threshold, so a fresh ID is minted.
    func testEngulfmentDoesNotReassignId() {
        let ledger = UtteranceLedger()

        // Seed: a short "Okay." utterance, like 1C4B2CBA in the trace.
        let okayId = ledger.resolve(tStart: 18.06, tEnd: 23.24, text: "Okay.")
        _ = ledger.updateText("Okay.", utteranceId: okayId)

        // The bug: WhisperKit's next window returns a much wider segment
        // covering 15.66–32.70 with totally different content.
        let coarseId = ledger.resolve(
            tStart: 15.66, tEnd: 32.70,
            text: "the scheme where they provide the secure so that's the stack okay"
        )

        XCTAssertNotEqual(
            coarseId, okayId,
            "Engulfment must mint a new UUID, not hijack the existing one."
        )
    }

    /// Same shape, different absolute scale. A long new segment that
    /// fully contains a tiny existing one should never reuse the tiny
    /// entry's ID — even when overlap == shorter.
    func testEngulfmentRejectsRegardlessOfAbsoluteScale() {
        let ledger = UtteranceLedger()
        let smallId = ledger.resolve(tStart: 45.16, tEnd: 46.34, text: "- Okay.")
        let bigId = ledger.resolve(
            tStart: 41.83, tEnd: 55.36,
            text: "is okay okay the blue box in the middle are all the start contract"
        )
        XCTAssertNotEqual(smallId, bigId)
    }

    // MARK: - Continuity cases (must still match after the fix)

    /// 8B0877AC in the trace: started at [5.72, 11.02], grew to
    /// [5.72, 11.54] in the next window. Both intervals are roughly
    /// comparable in length so the max-denominator rule still matches.
    /// score = 5.30 / 5.82 ≈ 0.91.
    func testLegitimateGrowKeepsId() {
        let ledger = UtteranceLedger()
        let firstId = ledger.resolve(tStart: 5.72, tEnd: 11.02, text: "identify my customer")
        _ = ledger.updateText("identify my customer", utteranceId: firstId)
        let secondId = ledger.resolve(
            tStart: 5.72, tEnd: 11.54,
            text: "identify my customer and to integrate with my customer so i can be back"
        )
        XCTAssertEqual(firstId, secondId)
    }

    /// 8B0877AC again: [5.72, 11.54] then shrinks to [5.72, 9.14].
    /// score = 3.42 / 5.82 ≈ 0.59 — above threshold, must match.
    func testLegitimateShrinkKeepsId() {
        let ledger = UtteranceLedger()
        let firstId = ledger.resolve(tStart: 5.72, tEnd: 11.54, text: "...")
        let secondId = ledger.resolve(tStart: 5.72, tEnd: 9.14, text: "to identify my customer")
        XCTAssertEqual(firstId, secondId)
    }

    /// 286E4AF2 in the trace: same interval emitted across windows
    /// (partial → final). Exact overlap = exact match.
    func testIdenticalIntervalAlwaysMatches() {
        let ledger = UtteranceLedger()
        let firstId = ledger.resolve(tStart: 15.56, tEnd: 18.06, text: "So that's the stack.")
        let secondId = ledger.resolve(tStart: 15.56, tEnd: 18.06, text: "So that's the stack.")
        XCTAssertEqual(firstId, secondId)
    }

    // MARK: - Boundary semantics

    /// Threshold is `>=`, so a score of exactly 0.5 matches. Sanity check.
    func testScoreAtThresholdMatches() {
        let ledger = UtteranceLedger()
        // Existing [0, 10], new [0, 20] → overlap=10, longer=20, score=0.5
        let firstId = ledger.resolve(tStart: 0, tEnd: 10, text: "a")
        let secondId = ledger.resolve(tStart: 0, tEnd: 20, text: "a")
        XCTAssertEqual(firstId, secondId)
    }

    /// Score just below 0.5 must mint a fresh ID.
    func testScoreBelowThresholdMints() {
        let ledger = UtteranceLedger()
        // Existing [0, 10], new [0, 21] → overlap=10, longer=21, score≈0.476
        let firstId = ledger.resolve(tStart: 0, tEnd: 10, text: "a")
        let secondId = ledger.resolve(tStart: 0, tEnd: 21, text: "a")
        XCTAssertNotEqual(firstId, secondId)
    }

    /// Finalized entries are never re-matched. A new segment with the
    /// same interval after finalization must get a fresh UUID.
    func testFinalizedEntryNeverReused() {
        let ledger = UtteranceLedger()
        let firstId = ledger.resolve(tStart: 10, tEnd: 15, text: "hello")
        ledger.markFinalized(utteranceId: firstId)
        let secondId = ledger.resolve(tStart: 10, tEnd: 15, text: "hello again")
        XCTAssertNotEqual(firstId, secondId)
    }

    /// Zero-length (degenerate) segments must mint rather than risk
    /// false-matching via 0/0 arithmetic.
    func testZeroLengthSegmentMints() {
        let ledger = UtteranceLedger()
        let id1 = ledger.resolve(tStart: 5.0, tEnd: 5.0, text: "")
        let id2 = ledger.resolve(tStart: 5.0, tEnd: 5.0, text: "")
        XCTAssertNotEqual(id1, id2)
    }

    // MARK: - Prune

    /// Entries whose tEnd is strictly less than the cutoff are dropped.
    /// Entries straddling or after the cutoff are kept.
    func testPruneDropsEntriesBeforeCutoff() {
        let ledger = UtteranceLedger()
        let oldId = ledger.resolve(tStart: 0, tEnd: 5, text: "old")
        ledger.markFinalized(utteranceId: oldId)
        let straddleId = ledger.resolve(tStart: 8, tEnd: 12, text: "straddle")
        let recentId = ledger.resolve(tStart: 15, tEnd: 20, text: "recent")

        let dropped = ledger.prune(beforeSessionTime: 10.0)

        XCTAssertEqual(dropped.count, 1)
        XCTAssertEqual(dropped.first?.id, oldId)
        XCTAssertEqual(ledger.entryCount, 2)

        // The straddle and recent entries should still resolve to themselves
        // (i.e. they're still in the ledger).
        XCTAssertEqual(ledger.resolve(tStart: 8, tEnd: 12, text: "straddle"), straddleId)
        XCTAssertEqual(ledger.resolve(tStart: 15, tEnd: 20, text: "recent"), recentId)
    }

    /// Prune surfaces the finalized flag so callers can decide whether
    /// to emit a closure event for orphan (non-finalized) partials.
    func testPruneReportsFinalizationState() {
        let ledger = UtteranceLedger()
        let finalizedId = ledger.resolve(tStart: 0, tEnd: 4, text: "done")
        _ = ledger.updateText("done", utteranceId: finalizedId)
        ledger.markFinalized(utteranceId: finalizedId)

        let orphanId = ledger.resolve(tStart: 0, tEnd: 4, text: "orphan")
        _ = ledger.updateText("orphan", utteranceId: orphanId)
        // orphan stays non-finalized

        let dropped = ledger.prune(beforeSessionTime: 10.0)
        XCTAssertEqual(dropped.count, 2)

        let byId = Dictionary(uniqueKeysWithValues: dropped.map { ($0.id, $0) })
        XCTAssertEqual(byId[finalizedId]?.wasFinalized, true)
        XCTAssertEqual(byId[orphanId]?.wasFinalized, false)
        XCTAssertEqual(byId[orphanId]?.lastText, "orphan")
    }

    /// After prune, a fresh segment with the same interval as a dropped
    /// entry gets a new UUID — the ledger no longer carries that history.
    func testPrunedEntryCanNotBeMatched() {
        let ledger = UtteranceLedger()
        let oldId = ledger.resolve(tStart: 0, tEnd: 5, text: "old")
        _ = ledger.prune(beforeSessionTime: 10.0)
        let newId = ledger.resolve(tStart: 0, tEnd: 5, text: "old")
        XCTAssertNotEqual(oldId, newId)
    }

    // MARK: - Supersession (ADR-0018)

    /// GROWTH SUPERSEDES. A short fragment is finalized, then a later window
    /// re-decodes the same span into a longer segment that (a) time-contains it
    /// and (b) text-contains it (the old text is a prefix of the new). The short
    /// fragment must be reported superseded by the longer one, and the longer
    /// one must keep its own id and keep flowing.
    func testGrowthSupersedesContainedFragment() {
        let ledger = UtteranceLedger()
        // Fragment as the live path produces it: resolve (mint) then updateText.
        let shortId = ledger.resolve(tStart: 10.0, tEnd: 12.0, text: "in berlin with my partner")
        _ = ledger.updateText("in berlin with my partner", utteranceId: shortId)
        XCTAssertTrue(ledger.drainSupersessions().isEmpty,
                      "minting the first fragment supersedes nothing")

        // Re-segmentation: same start (~), grown end, old text is a prefix.
        // Overlap-of-longer = 2.0 / 7.5 ≈ 0.27 < 0.5 → a fresh id is minted,
        // which is exactly the supersession trigger point.
        let grownId = ledger.resolve(
            tStart: 10.0, tEnd: 17.5,
            text: "in berlin with my partner, and I have one younger brother")
        XCTAssertNotEqual(grownId, shortId, "the grown segment gets its own fresh id")

        let events = ledger.drainSupersessions()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.oldId, shortId)
        XCTAssertEqual(events.first?.newId, grownId)

        // The survivor keeps flowing: re-resolving its interval re-matches it.
        let again = ledger.resolve(tStart: 10.0, tEnd: 17.5, text: "in berlin with my partner, and I have one younger brother")
        XCTAssertEqual(again, grownId, "the surviving (grown) utterance keeps its id")
    }

    /// CRITICAL REGRESSION GUARD: legitimate repeat preserved. The SAME text
    /// spoken again at a DIFFERENT, non-overlapping time must NOT be superseded
    /// — the time gate has zero overlap, so containment fails (#1) even though
    /// the text is identical. Both survive. This is the whole reason the gate
    /// is time-AND-text and never text alone (ADR-0018 §Decision).
    func testLegitimateRepeatAtDifferentTimeNotSuperseded() {
        let ledger = UtteranceLedger()
        let firstId = ledger.resolve(tStart: 5.0, tEnd: 8.0, text: "repeat after me")
        _ = ledger.updateText("repeat after me", utteranceId: firstId)
        _ = ledger.drainSupersessions()

        // Same words, much later — no time overlap with the first.
        let secondId = ledger.resolve(tStart: 40.0, tEnd: 43.0, text: "repeat after me")
        _ = ledger.updateText("repeat after me", utteranceId: secondId)

        XCTAssertNotEqual(firstId, secondId, "different times → different utterances")
        XCTAssertTrue(ledger.drainSupersessions().isEmpty,
                      "a non-overlapping repeat must never be superseded")
    }

    /// DISTINCT CONSECUTIVE preserved. Two different utterances with a small
    /// boundary overlap, where neither time-contains the other AND neither
    /// text is a prefix of the other. Must NOT supersede (fails both gates).
    func testDistinctConsecutiveWithBoundaryOverlapNotSuperseded() {
        let ledger = UtteranceLedger()
        let firstId = ledger.resolve(tStart: 0.0, tEnd: 6.0, text: "thanks everyone for joining")
        _ = ledger.updateText("thanks everyone for joining", utteranceId: firstId)
        _ = ledger.drainSupersessions()

        // Starts inside the tail of the first (0.5 s overlap) but is a distinct
        // sentence — different content, and it does NOT contain the first.
        // It also starts LATER than the first by > slack, so time-containment
        // (new.start <= old.start + slack) fails too.
        let secondId = ledger.resolve(tStart: 5.5, tEnd: 11.0, text: "lets get started with the agenda")
        _ = ledger.updateText("lets get started with the agenda", utteranceId: secondId)

        XCTAssertNotEqual(firstId, secondId)
        XCTAssertTrue(ledger.drainSupersessions().isEmpty,
                      "distinct adjacent utterances must not supersede each other")
    }

    /// Text gate alone is not sufficient: a later segment that time-contains an
    /// earlier one but whose text is NOT an extension of it (the old text is not
    /// a prefix) must NOT supersede. Guards against an unrelated coarse pass
    /// eating a short fragment purely on geometry — the engulfment shape from
    /// ADR-0009 with alien content.
    func testTimeContainedButTextUnrelatedNotSuperseded() {
        let ledger = UtteranceLedger()
        let shortId = ledger.resolve(tStart: 18.0, tEnd: 20.0, text: "okay")
        _ = ledger.updateText("okay", utteranceId: shortId)
        _ = ledger.drainSupersessions()

        // Time-contains [18,20] but the text does not begin with "okay".
        let coarseId = ledger.resolve(
            tStart: 16.0, tEnd: 30.0,
            text: "the scheme where they provide the secure so thats the stack")
        _ = ledger.updateText(
            "the scheme where they provide the secure so thats the stack",
            utteranceId: coarseId)

        XCTAssertNotEqual(shortId, coarseId)
        XCTAssertTrue(ledger.drainSupersessions().isEmpty,
                      "geometry alone must not supersede — text must extend the old")
    }

    /// CHAIN A→B→C: a fragment grows once, then grows again. Each growth
    /// supersedes the immediately-prior survivor. Two events surface (A→B then
    /// B→C); only C is left unretracted. Order is preserved.
    func testSupersessionChainEmitsEachLink() {
        let ledger = UtteranceLedger()
        let aId = ledger.resolve(tStart: 10.0, tEnd: 11.5, text: "I live")
        _ = ledger.updateText("I live", utteranceId: aId)
        _ = ledger.drainSupersessions()

        let bId = ledger.resolve(tStart: 10.0, tEnd: 13.5, text: "I live in berlin")
        _ = ledger.updateText("I live in berlin", utteranceId: bId)
        let firstLink = ledger.drainSupersessions()
        XCTAssertEqual(firstLink, [UtteranceLedger.SupersessionEvent(oldId: aId, newId: bId)])

        let cId = ledger.resolve(tStart: 10.0, tEnd: 18.0, text: "I live in berlin with my partner")
        _ = ledger.updateText("I live in berlin with my partner", utteranceId: cId)
        let secondLink = ledger.drainSupersessions()

        // Only B→C surfaces here — A is already marked superseded and skipped,
        // so C does NOT also re-supersede A (no duplicate A→C event).
        XCTAssertEqual(secondLink, [UtteranceLedger.SupersessionEvent(oldId: bId, newId: cId)])
        XCTAssertNotEqual(aId, bId)
        XCTAssertNotEqual(bId, cId)

        // C survives; re-resolving its span re-matches it.
        XCTAssertEqual(
            ledger.resolve(tStart: 10.0, tEnd: 18.0, text: "I live in berlin with my partner"),
            cId)
    }

    /// A superseded entry must NOT be emitted as a synthetic final by prune —
    /// the prune report carries `wasSuperseded` so the caller can skip it. (The
    /// surviving longer entry, if pruned while non-finalized, still reports as a
    /// normal orphan.)
    func testPrunedSupersededEntryFlaggedAndNotResurrected() {
        let ledger = UtteranceLedger()
        let shortId = ledger.resolve(tStart: 2.0, tEnd: 4.0, text: "hello there")
        _ = ledger.updateText("hello there", utteranceId: shortId)
        let grownId = ledger.resolve(tStart: 2.0, tEnd: 9.0, text: "hello there general kenobi")
        _ = ledger.updateText("hello there general kenobi", utteranceId: grownId)
        XCTAssertEqual(ledger.drainSupersessions().count, 1)

        let dropped = ledger.prune(beforeSessionTime: 100.0)
        let byId = Dictionary(uniqueKeysWithValues: dropped.map { ($0.id, $0) })
        XCTAssertEqual(byId[shortId]?.wasSuperseded, true,
                       "the superseded fragment is flagged so prune won't finalize it")
        XCTAssertEqual(byId[grownId]?.wasSuperseded, false,
                       "the surviving grown entry is a normal (non-superseded) orphan")
    }

    /// Identical text + identical interval is the partial→final re-emit, NOT a
    /// growth — it must keep the same id (matches via overlap) and never report
    /// a supersession.
    func testIdenticalReemitIsNotSupersession() {
        let ledger = UtteranceLedger()
        let firstId = ledger.resolve(tStart: 3.0, tEnd: 7.0, text: "same sentence")
        _ = ledger.updateText("same sentence", utteranceId: firstId)
        let secondId = ledger.resolve(tStart: 3.0, tEnd: 7.0, text: "same sentence")
        XCTAssertEqual(firstId, secondId)
        XCTAssertTrue(ledger.drainSupersessions().isEmpty)
    }
}
