// HallucinationFilterTests — regression coverage for the two non-speech gates
// added with the low-latency live-caption work (ADR-0040):
//
//   - isLikelyHallucination(text): drops sound-tag / punctuation artifacts by
//     shape ("*crickets*", "[BLANK_AUDIO]", a leading "*Minds of the").
//   - isNonSpeechDecode(noSpeechProb:avgLogprob:compressionRatio:): drops
//     silence/noise decodes by the DECODER's own confidence signals, using
//     WhisperKit's own default thresholds (0.6 / -1.0 / 2.4). Measured real
//     speech sits far inside all three (noSpeechProb ~0.00, avgLogprob > -0.2,
//     compressionRatio < 1.5), which these tests pin so a future threshold
//     change can't silently start clipping real speech.

import XCTest
@testable import Harkd

final class HallucinationFilterTests: XCTestCase {

    // ─── isLikelyHallucination (text shape) ──────────────────────────────

    func testRealSpeechIsNotHallucination() {
        for t in [
            "Let's start with the quarterly numbers.",
            "Revenue is up 12% since March.",
            "(laughs) okay, moving on",          // opens with '(' but not enclosed
            "the meeting is at 3pm",
        ] {
            XCTAssertFalse(isLikelyHallucination(t), "false positive on: \(t)")
        }
    }

    func testSoundTagsAndNoiseAreHallucinations() {
        for t in [
            "*crickets*",        // fully asterisk-enclosed
            "[BLANK_AUDIO]",     // fully bracket-enclosed
            "(music playing)",   // fully paren-enclosed
            "*Minds of the",     // leading '*', unclosed mid-decode
            "♪",                 // musical note, no alnum
            "- -",               // punctuation only
            "...",               // punctuation only
            "   ",               // whitespace only
        ] {
            XCTAssertTrue(isLikelyHallucination(t), "missed hallucination: \(t)")
        }
    }

    // ─── isNonSpeechDecode (confidence) ──────────────────────────────────

    func testMeasuredRealSpeechConfidencePasses() {
        // Values observed in HARK_PERF_LOG across real spoken phrases.
        XCTAssertFalse(isNonSpeechDecode(noSpeechProb: 0.000, avgLogprob: -0.017, compressionRatio: 1.07))
        XCTAssertFalse(isNonSpeechDecode(noSpeechProb: 0.000, avgLogprob: -0.153, compressionRatio: 1.43))
        XCTAssertFalse(isNonSpeechDecode(noSpeechProb: 0.05, avgLogprob: -0.5, compressionRatio: 1.9))
    }

    func testHighNoSpeechProbIsDropped() {
        XCTAssertTrue(isNonSpeechDecode(noSpeechProb: 0.90, avgLogprob: -0.1, compressionRatio: 1.4))
        XCTAssertTrue(isNonSpeechDecode(noSpeechProb: 0.61, avgLogprob: -0.1, compressionRatio: 1.4))
        XCTAssertFalse(isNonSpeechDecode(noSpeechProb: 0.59, avgLogprob: -0.1, compressionRatio: 1.4))
    }

    func testLowAvgLogprobIsDropped() {
        XCTAssertTrue(isNonSpeechDecode(noSpeechProb: 0.0, avgLogprob: -1.5, compressionRatio: 1.4))
        XCTAssertFalse(isNonSpeechDecode(noSpeechProb: 0.0, avgLogprob: -0.99, compressionRatio: 1.4))
    }

    func testRunawayCompressionRatioIsDropped() {
        XCTAssertTrue(isNonSpeechDecode(noSpeechProb: 0.0, avgLogprob: -0.1, compressionRatio: 2.5))
        XCTAssertFalse(isNonSpeechDecode(noSpeechProb: 0.0, avgLogprob: -0.1, compressionRatio: 2.39))
    }
}
