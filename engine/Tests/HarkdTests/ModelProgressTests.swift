// ModelProgressTests — first-run model-load progress over the WebSocket.
//
// Two load-bearing pieces of the engine→UI progress path get pinned here:
//
//   1. `ModelProgressThrottle.decide` — the PURE rate-limit decision in front
//      of the actor hop. The FluidAudio per-byte download callback and the
//      WhisperKit per-1% callback fire very frequently; the throttle drops the
//      flood while NEVER dropping a phase transition. We drive the real `decide`
//      with injected `now`/`lastEmitAt` so the time branch is deterministic.
//
//   2. `MetaModelProgressPayload` JSON encoding — the contract demands the
//      indeterminate ANE-compile state encode `fraction` as JSON `null` (so the
//      UI shows a spinner, not a 0% bar), NOT a dropped key. We encode through
//      the SAME `encodeWireMessage` the live broadcast uses and assert the wire
//      shape.

import XCTest
@testable import Harkd

@available(macOS 14.4, *)
final class ModelProgressTests: XCTestCase {

    // MARK: - Throttle decision (pure)

    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testFirstUpdateAlwaysEmits() {
        // No prior state → always emit, regardless of fraction/phase.
        XCTAssertTrue(ModelProgressThrottle.decide(
            phase: "downloading_speech", fraction: 0.0, now: t0,
            lastPhase: nil, lastFraction: nil, lastEmitAt: nil))
    }

    func testPhaseChangeAlwaysEmits() {
        // A transition must never be dropped — even within the time/delta gate
        // (here: identical timestamp, identical fraction, but different phase).
        XCTAssertTrue(ModelProgressThrottle.decide(
            phase: "optimizing_speech", fraction: 0.5, now: t0,
            lastPhase: "downloading_speech", lastFraction: 0.5, lastEmitAt: t0))
    }

    func testSmallFractionDeltaWithinIntervalIsDropped() {
        // Same phase, +0.005 (< 1%), only 50 ms elapsed → dropped.
        XCTAssertFalse(ModelProgressThrottle.decide(
            phase: "downloading_speech", fraction: 0.505, now: t0.addingTimeInterval(0.05),
            lastPhase: "downloading_speech", lastFraction: 0.5, lastEmitAt: t0))
    }

    func testFractionDeltaAtThresholdEmits() {
        // Exactly +1% within the same phase → emit even though time gate not met.
        XCTAssertTrue(ModelProgressThrottle.decide(
            phase: "downloading_speech", fraction: 0.51, now: t0.addingTimeInterval(0.05),
            lastPhase: "downloading_speech", lastFraction: 0.5, lastEmitAt: t0))
    }

    func testTimeIntervalElapsedEmitsEvenWithoutDelta() {
        // Same phase, sub-threshold delta, but ≥ 200 ms elapsed → emit (keeps the
        // bar alive on a slow/stalled download).
        XCTAssertTrue(ModelProgressThrottle.decide(
            phase: "downloading_speech", fraction: 0.501, now: t0.addingTimeInterval(0.25),
            lastPhase: "downloading_speech", lastFraction: 0.5, lastEmitAt: t0))
    }

    func testTerminalFractionEmits() {
        // 1.0 is a meaningful boundary even if it's a small delta from 0.999.
        XCTAssertTrue(ModelProgressThrottle.decide(
            phase: "downloading_speech", fraction: 1.0, now: t0.addingTimeInterval(0.01),
            lastPhase: "downloading_speech", lastFraction: 0.999, lastEmitAt: t0))
    }

    func testNilFractionCompilePulseGatesOnTimeOnly() {
        // The ANE-compile pulse carries fraction == nil (indeterminate). Within
        // the phase it has no delta to measure, so a re-pulse only 50 ms later
        // is dropped, but one ≥ 200 ms later (the ~1.5s ticker) is forwarded.
        XCTAssertFalse(ModelProgressThrottle.decide(
            phase: "optimizing_speech", fraction: nil, now: t0.addingTimeInterval(0.05),
            lastPhase: "optimizing_speech", lastFraction: nil, lastEmitAt: t0))
        XCTAssertTrue(ModelProgressThrottle.decide(
            phase: "optimizing_speech", fraction: nil, now: t0.addingTimeInterval(0.20),
            lastPhase: "optimizing_speech", lastFraction: nil, lastEmitAt: t0))
    }

    func testStatefulShouldEmitUpdatesLastState() {
        // The stateful wrapper retains the previous emit only when it emits, so a
        // second sub-threshold update is still measured against the FIRST emit.
        let throttle = ModelProgressThrottle()
        XCTAssertTrue(throttle.shouldEmit(phase: "downloading_speech", fraction: 0.10, now: t0))
        // +0.005 / +50 ms → dropped; retained "last" stays 0.10 @ t0.
        XCTAssertFalse(throttle.shouldEmit(
            phase: "downloading_speech", fraction: 0.105, now: t0.addingTimeInterval(0.05)))
        // Now +0.02 from the retained 0.10 → emits (delta gate), even though only
        // +100 ms from the first emit (proves it didn't quietly advance "last").
        XCTAssertTrue(throttle.shouldEmit(
            phase: "downloading_speech", fraction: 0.12, now: t0.addingTimeInterval(0.10)))
    }

    // MARK: - Wire encoding (nil fraction → JSON null)

    func testProgressFractionEncodesAsNull() throws {
        let env = WireEnvelope(
            type: "meta.model_progress",
            payload: MetaModelProgressPayload(
                phase: "optimizing_speech", fraction: nil, detail: "Optimizing for Neural Engine"))
        let json = String(decoding: try encodeWireMessage(env), as: UTF8.self)
        XCTAssertTrue(json.contains("\"fraction\":null"),
                      "indeterminate fraction must serialize as JSON null, not be dropped: \(json)")
        XCTAssertTrue(json.contains("\"phase\":\"optimizing_speech\""))
        XCTAssertTrue(json.contains("\"type\":\"meta.model_progress\""))
    }

    func testProgressFractionEncodesValueWhenPresent() throws {
        let env = WireEnvelope(
            type: "meta.model_progress",
            payload: MetaModelProgressPayload(
                phase: "downloading_speech", fraction: 0.42, detail: "Downloading speech model"))
        let json = String(decoding: try encodeWireMessage(env), as: UTF8.self)
        XCTAssertTrue(json.contains("\"fraction\":0.42"), json)
        XCTAssertFalse(json.contains("null"), "a present fraction must not encode as null: \(json)")
    }
}
