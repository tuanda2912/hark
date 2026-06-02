// LiveDiarizerTests — pure-logic coverage for the OPTIONAL live (provisional)
// diarization label mapping + segment-range speaker lookup.
//
// These drive the REAL pure functions the live path uses:
//   - LiveDiarizer.label(forIndex:)      — streaming-speakerId→"Speaker A/B/…"
//   - LiveDiarizer.dominantLabel(...)    — utterance [t_start,t_end] → label by
//                                          max temporal overlap (or nil)
// so the on-screen provisional tagging is pinned without a live FluidAudio
// model / audio pipeline. The actor's `ingest`/`provisionalSpeaker` simply
// build a timeline and delegate to these two functions, so testing them is
// testing the behavior that reaches the wire.

import XCTest
@testable import Harkd

@available(macOS 14.4, *)
final class LiveDiarizerTests: XCTestCase {

    // ─── speakerId → "Speaker A/B/…" first-seen labelling ────────────────────

    func testLabelForIndexUsesSpreadsheetLetters() {
        XCTAssertEqual(LiveDiarizer.label(forIndex: 0), "Speaker A")
        XCTAssertEqual(LiveDiarizer.label(forIndex: 1), "Speaker B")
        XCTAssertEqual(LiveDiarizer.label(forIndex: 25), "Speaker Z")
        // Past Z it rolls to AA, AB… so it never runs out and never collides
        // with the offline "Speaker 1/2" numbering.
        XCTAssertEqual(LiveDiarizer.label(forIndex: 26), "Speaker AA")
        XCTAssertEqual(LiveDiarizer.label(forIndex: 27), "Speaker AB")
        XCTAssertEqual(LiveDiarizer.label(forIndex: 51), "Speaker AZ")
        XCTAssertEqual(LiveDiarizer.label(forIndex: 52), "Speaker BA")
    }

    func testLiveLabelsNeverLookLikeOfflineNumbering() {
        // The whole point of letters: a glance at the screen distinguishes a
        // provisional live label from the authoritative "Speaker 1/2" the stop
        // pass writes. Guard that no early index renders as a bare number.
        for i in 0..<60 {
            let label = LiveDiarizer.label(forIndex: i)
            XCTAssertTrue(label.hasPrefix("Speaker "))
            let suffix = label.dropFirst("Speaker ".count)
            XCTAssertNil(Int(suffix), "live label \(label) must not be numeric")
        }
    }

    // ─── max-overlap segment-range → speaker lookup ──────────────────────────

    private func seg(_ start: Double, _ end: Double, _ label: String) -> LiveDiarizer.TimelineSegment {
        LiveDiarizer.TimelineSegment(tStart: start, tEnd: end, label: label)
    }

    func testNilWhenTimelineEmpty() {
        XCTAssertNil(LiveDiarizer.dominantLabel(forStart: 0, end: 5, timeline: []))
    }

    func testNilWhenNoOverlap() {
        // Utterance sits entirely before the only timeline segment.
        let timeline = [seg(10, 20, "Speaker A")]
        XCTAssertNil(LiveDiarizer.dominantLabel(forStart: 0, end: 5, timeline: timeline))
    }

    func testPicksSingleOverlappingSpeaker() {
        let timeline = [seg(0, 10, "Speaker A")]
        XCTAssertEqual(
            LiveDiarizer.dominantLabel(forStart: 2, end: 8, timeline: timeline),
            "Speaker A")
    }

    func testPicksMaxOverlapAcrossSpeakers() {
        // Utterance [4, 12] overlaps A by 1s ([4,5]) and B by 7s ([5,12]) → B.
        let timeline = [seg(0, 5, "Speaker A"), seg(5, 15, "Speaker B")]
        XCTAssertEqual(
            LiveDiarizer.dominantLabel(forStart: 4, end: 12, timeline: timeline),
            "Speaker B")
    }

    func testTouchingBoundaryIsNotOverlap() {
        // [5,10] only touches a segment that ends exactly at 5 — zero overlap,
        // so it falls through to the later, genuinely-overlapping segment.
        let timeline = [seg(0, 5, "Speaker A"), seg(5, 10, "Speaker B")]
        XCTAssertEqual(
            LiveDiarizer.dominantLabel(forStart: 5, end: 10, timeline: timeline),
            "Speaker B")
    }

    func testFirstWinsOnExactOverlapTie() {
        // Equal overlap (3s each) — strict ">" keeps the first-scanned segment,
        // matching the offline matchSpeaker tie behavior (deterministic).
        let timeline = [seg(0, 6, "Speaker A"), seg(6, 12, "Speaker B")]
        XCTAssertEqual(
            LiveDiarizer.dominantLabel(forStart: 3, end: 9, timeline: timeline),
            "Speaker A")
    }

    // ─── HARK_LIVE_DIAR_THRESHOLD → clusteringThreshold mapping ──────────────
    //
    // Pins the env→config seam that fixes the all-voices-collapse-to-one bug:
    // unset uses the chosen 0.55 default (NOT FluidAudio's permissive 0.7),
    // a valid env value passes through, out-of-range clamps, junk falls back.
    // A silent drift back to 0.7 would re-merge all speakers — guard it.

    func testLiveTuningDefaultIsNotFluidAudioDefault() {
        let t = makeLiveDiarizerTuning(env: [:], progressOutput: .nullDevice)
        XCTAssertEqual(t.clusteringThreshold, defaultLiveDiarThreshold)
        XCTAssertFalse(t.fromEnv)
        // The bug was the 0.7 default → speakerThreshold 0.84 (everyone merges).
        // Our default must sit clearly below that.
        XCTAssertLessThan(t.clusteringThreshold, 0.7)
    }

    func testLiveTuningHonorsValidEnvValue() {
        let t = makeLiveDiarizerTuning(
            env: ["HARK_LIVE_DIAR_THRESHOLD": "0.45"], progressOutput: .nullDevice)
        XCTAssertEqual(t.clusteringThreshold, 0.45, accuracy: 1e-6)
        XCTAssertTrue(t.fromEnv)
    }

    func testLiveTuningClampsAboveRange() {
        // 1.5 > 0.9 upper bound → clamped to 0.9 (still counts as env-sourced).
        let t = makeLiveDiarizerTuning(
            env: ["HARK_LIVE_DIAR_THRESHOLD": "1.5"], progressOutput: .nullDevice)
        XCTAssertEqual(t.clusteringThreshold, 0.9, accuracy: 1e-6)
        XCTAssertTrue(t.fromEnv)
    }

    func testLiveTuningClampsBelowRange() {
        let t = makeLiveDiarizerTuning(
            env: ["HARK_LIVE_DIAR_THRESHOLD": "0.0"], progressOutput: .nullDevice)
        XCTAssertEqual(t.clusteringThreshold, 0.1, accuracy: 1e-6)
        XCTAssertTrue(t.fromEnv)
    }

    func testLiveTuningFallsBackOnJunk() {
        let t = makeLiveDiarizerTuning(
            env: ["HARK_LIVE_DIAR_THRESHOLD": "not-a-number"], progressOutput: .nullDevice)
        XCTAssertEqual(t.clusteringThreshold, defaultLiveDiarThreshold)
        XCTAssertFalse(t.fromEnv)
    }
}
