// DedupTests — regression coverage for the at-stop, interval-based, time-gated
// re-emission collapse (EngineSession.collapseReemissions).
//
// Context (real 2026-06-01 on-device run, conversational audio): the sliding
// window re-emits the SAME spoken sentence on successive 5 s hops at t_start
// values 1–4 s apart. Each copy gets a DISTINCT utterance_id (ADR-0009 mints a
// fresh id when WhisperKit re-segments coarsely), and the supersession gate
// (ADR-0018) intentionally lets identical copies through (it only retracts
// EXTENSIONS). Stage 2 collapses these copies — but ONLY when their timing
// proves re-emission. Identical text spoken far apart MUST survive (the time
// gate is the entire safety mechanism).

import XCTest
@testable import Harkd

@available(macOS 14.4, *)
final class DedupTests: XCTestCase {

    private let window = EngineSession.defaultDedupWindowSeconds  // 2.5 s

    private func u(_ id: String, _ tStart: Double, _ tEnd: Double, _ text: String) -> FinalizedUtterance {
        FinalizedUtterance(utteranceId: id, tStart: tStart, tEnd: tEnd, text: text)
    }

    private func collapse(_ utts: [FinalizedUtterance], window: Double? = nil) -> [FinalizedUtterance] {
        EngineSession.collapseReemissions(utts, windowSeconds: window ?? self.window)
    }

    // MARK: - The reported bug: re-emitted copies within the window collapse

    /// "We're getting there." appeared 4× within ~3 s in the real run, split
    /// across distinct uids and slightly drifting intervals. With the time
    /// gate they form one transitive cluster and collapse to a single row —
    /// the longest text, tie-broken to the earliest start.
    func testFourReemittedCopiesWithinWindowCollapseToOne() {
        let input = [
            u("a", 10.0, 11.3, "We're getting there."),
            u("b", 10.4, 11.7, "We're getting there"),
            u("c", 11.2, 12.5, "We're getting there."),
            u("d", 13.0, 14.2, "We're getting there."),  // gap to c ≈ 0.5 s < 2.5
        ]
        let out = collapse(input)
        XCTAssertEqual(out.count, 1, "all four copies are re-emissions of one sentence")
        // Longest text wins; the two "We're getting there." (with period) tie on
        // length, earliest start ("a" @ 10.0) breaks the tie.
        XCTAssertEqual(out.first?.utteranceId, "a")
        XCTAssertEqual(out.first?.text, "We're getting there.")
    }

    /// Three copies that mutually overlap collapse regardless of the gap window.
    func testOverlappingCopiesCollapseEvenWithZeroWindow() {
        let input = [
            u("a", 5.0, 9.0, "Ten years of work right there."),
            u("b", 6.0, 10.0, "Ten years of work right there."),
            u("c", 7.0, 11.0, "Ten years of work right there."),
        ]
        // window = 0 disables the gap path; overlap alone must still collapse.
        let out = collapse(input, window: 0)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.utteranceId, "a")
    }

    // MARK: - CRITICAL REGRESSION GUARD: genuine repeats survive

    /// HARD CONSTRAINT. Identical text spoken at clearly-different times
    /// (non-overlapping AND gap >> window) MUST survive as two separate
    /// utterances — people legitimately repeat phrases.
    func testIdenticalTextFarApartPreserved() {
        let input = [
            u("a", 10.0, 11.5, "We're getting there."),
            u("b", 40.0, 41.5, "We're getting there."),  // gap = 28.5 s ≫ 2.5
        ]
        let out = collapse(input)
        XCTAssertEqual(out.count, 2, "a genuine repeat far apart must not collapse")
        XCTAssertEqual(Set(out.map(\.utteranceId)), ["a", "b"])
    }

    /// Boundary: a gap of exactly the window does NOT collapse (gate is `< window`,
    /// "when in doubt, don't collapse"); a gap just under it does.
    func testGapAtWindowBoundary() {
        let atBoundary = [
            u("a", 0.0, 2.0, "okay so"),
            u("b", 4.5, 6.5, "okay so"),  // gap = 2.5 == window → keep both
        ]
        XCTAssertEqual(collapse(atBoundary).count, 2, "gap == window must NOT collapse")

        let underBoundary = [
            u("a", 0.0, 2.0, "okay so"),
            u("b", 4.4, 6.5, "okay so"),  // gap = 2.4 < window → collapse
        ]
        XCTAssertEqual(collapse(underBoundary).count, 1, "gap < window collapses")
    }

    /// Transitivity is bounded by the window: A~B (close) and B~C (close) but
    /// A and C are far apart. They still collapse to one because the CHAIN
    /// links them — that is the intended transitive behaviour. A separate
    /// far-apart copy with no near neighbour stays its own cluster.
    func testTransitiveChainVsIsolatedRepeat() {
        let input = [
            u("a", 0.0, 1.5, "we're getting there"),
            u("b", 1.6, 3.1, "we're getting there"),  // ~0.1 s gap to a
            u("c", 3.2, 4.7, "we're getting there"),  // ~0.1 s gap to b
            u("z", 60.0, 61.5, "we're getting there"),  // isolated, far away
        ]
        let out = collapse(input)
        XCTAssertEqual(out.count, 2, "the a~b~c chain collapses; z stays separate")
        let ids = Set(out.map(\.utteranceId))
        XCTAssertTrue(ids.contains("z"), "the far-apart repeat survives")
    }

    // MARK: - Prefix / superset (near-identical) within the window

    /// A prefix variant the supersession path didn't catch: "These are the first
    /// full holographic AR glasses" emitted both complete and truncated within
    /// the window. The normalized prefix relationship + time link collapses them
    /// to the LONGER (most complete) text.
    func testPrefixSupersetWithinWindowCollapsesToLonger() {
        let longText = "These are the first full holographic augmented reality glasses, I think, that exist in the world."
        let shortText = "These are the first full holographic augmented reality glasses, I think, that exist in the"
        let input = [
            u("short", 17.0, 19.0, shortText),
            u("long", 17.2, 21.0, longText),  // overlaps short
        ]
        let out = collapse(input)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.utteranceId, "long", "the longer, most-complete text is kept")
        XCTAssertEqual(out.first?.text, longText)
    }

    /// Prefix relationship but far apart in time → NOT collapsed (time gate
    /// dominates the text gate, same as the identical-text guard).
    func testPrefixSupersetFarApartPreserved() {
        let input = [
            u("a", 5.0, 7.0, "we've made"),
            u("b", 50.0, 53.0, "we've made I think it's a few thousand or something"),
        ]
        XCTAssertEqual(collapse(input).count, 2, "prefix far apart is two real utterances")
    }

    // MARK: - Distinct content is never touched

    /// Different sentences close in time (even overlapping) must NOT collapse —
    /// the text gate fails (not equal, neither a prefix of the other).
    func testDistinctTextCloseInTimeUntouched() {
        let input = [
            u("a", 10.0, 11.0, "We're getting there."),
            u("b", 11.1, 13.0, "But I'd love to just hear in your voice, what are these?"),
            u("c", 13.0, 14.5, "Let's do it."),
        ]
        let out = collapse(input)
        XCTAssertEqual(out.count, 3, "three distinct sentences stay distinct")
        XCTAssertEqual(Set(out.map(\.utteranceId)), ["a", "b", "c"])
    }

    /// Number-format mismatch ("10 years" vs "Ten years") is deliberately NOT
    /// matched — normalized forms differ and neither is a prefix of the other.
    /// No fuzzy matching, per the dedup contract: these stay separate.
    func testNumberFormatMismatchNotCollapsed() {
        let input = [
            u("a", 5.0, 7.0, "10 years of work right there."),
            u("b", 5.4, 7.4, "Ten years of work right there."),  // overlaps, but text differs
        ]
        XCTAssertEqual(collapse(input).count, 2,
                       "number-format variants are left alone (no edit-distance matching)")
    }

    // MARK: - Degenerate inputs

    func testEmptyInputReturnsEmpty() {
        XCTAssertEqual(collapse([]).count, 0)
    }

    func testSingleInputUnchanged() {
        let out = collapse([u("a", 1.0, 2.0, "hello")])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.utteranceId, "a")
    }

    /// Empty-text rows never link (normalized form is empty) — they pass through
    /// untouched rather than risk false-collapsing on a vacuous prefix match.
    func testEmptyTextNeverLinks() {
        let input = [
            u("a", 1.0, 2.0, "   "),   // normalizes to ""
            u("b", 1.1, 2.1, "...."),  // normalizes to ""
        ]
        XCTAssertEqual(collapse(input).count, 2)
    }

    // MARK: - Env knob parse + clamp

    func testDedupWindowEnvParseClampAndDefault() {
        XCTAssertEqual(EngineSession.resolveDedupWindow(nil),
                       EngineSession.defaultDedupWindowSeconds)
        XCTAssertEqual(EngineSession.resolveDedupWindow("garbage"),
                       EngineSession.defaultDedupWindowSeconds)
        XCTAssertEqual(EngineSession.resolveDedupWindow("3.0"), 3.0)
        XCTAssertEqual(EngineSession.resolveDedupWindow("0"), 0.0)
        XCTAssertEqual(EngineSession.resolveDedupWindow("-5"), 0.0, "clamped to >= 0")
        XCTAssertEqual(EngineSession.resolveDedupWindow("999"),
                       EngineSession.maxDedupWindowSeconds, "clamped to the max")
    }
}
