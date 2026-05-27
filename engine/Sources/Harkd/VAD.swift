// VAD — Voice Activity Detection interface + initial energy-based impl.
//
// ADR-0008 §3 specifies Silero VAD via CoreML. The open question (§Open
// questions #1) acknowledged that a canonical CoreML bundle might not
// exist and accepted either (a) shipping ONNX + Runtime Swift bindings, or
// (b) a coremltools conversion. Both add real dependency surface.
//
// For Phase 3's initial cut we ship an **energy-based VAD with hangover**
// behind a `VAD` protocol so the Silero CoreML path can drop in later
// without touching the sliding-window driver. The energy gate:
//   - Computes RMS of each 100 ms frame (1600 samples at 16 kHz).
//   - State machine: silence → speech when RMS crosses `speechThreshold`;
//     speech → silence after `hangoverFrames` consecutive sub-threshold
//     frames. The hangover prevents word-internal stop consonants from
//     terminating an utterance.
//
// Why ship this rather than block on Silero CoreML:
//   1. Energy gate catches the worst hallucination case (steady silence)
//      which is what ADR-0008 §3 actually motivates.
//   2. Phase 4 dogfooding will reveal if hallucinations during *low-energy
//      speech* are a real problem; if so we upgrade to Silero with data
//      driving the choice.
//   3. Avoids committing to ONNX Runtime as a transitive dependency until
//      we know we need it (every dependency that opens a network or system
//      surface is an ADR per CLAUDE.md hard rule #6).
//
// Documented as deviation in the report — Silero is the next upgrade.

import Foundation

/// VAD verdict per frame batch.
enum VADState {
    case speech
    case silence
}

/// VAD interface — keeps the rest of the pipeline indifferent to the
/// implementation (energy-gate today, Silero CoreML tomorrow).
protocol VAD {
    /// Classify a Float32 frame batch at 16 kHz mono. The implementation
    /// may track state across calls (hangover, smoothing, etc.).
    mutating func classify(_ frames: [Float]) -> VADState
}

/// Energy-based VAD with hangover. Good-enough for Phase 3 initial cut.
///
/// Tuning notes:
///   - `speechThreshold = 0.01` (RMS in linear amplitude) sits below normal
///     conversational speech (~0.05–0.2) and above room-tone noise floor
///     (~0.001–0.005). Verified empirically against Phase 2's smoke-test
///     Vietnamese clip.
///   - `hangoverFrames = 8` × 100 ms = 800 ms tail. Long enough to bridge
///     within-utterance pauses ("uh ... what I meant was"), short enough
///     to mark end-of-turn within a normal conversational gap.
struct EnergyVAD: VAD {
    var speechThreshold: Float = 0.01
    var hangoverFrames: Int = 8

    private var inSpeech = false
    private var silenceRun = 0

    mutating func classify(_ frames: [Float]) -> VADState {
        let rms = computeRMS(frames)
        if rms >= speechThreshold {
            inSpeech = true
            silenceRun = 0
            return .speech
        }
        // Below threshold. If we're already in speech, keep emitting speech
        // until the hangover runs out — this prevents a 50 ms gap from
        // chopping a sentence.
        if inSpeech {
            silenceRun += 1
            if silenceRun >= hangoverFrames {
                inSpeech = false
                silenceRun = 0
                return .silence
            }
            return .speech
        }
        return .silence
    }

    private func computeRMS(_ frames: [Float]) -> Float {
        guard !frames.isEmpty else { return 0 }
        var sumSquares: Float = 0
        for f in frames {
            sumSquares += f * f
        }
        return (sumSquares / Float(frames.count)).squareRoot()
    }
}
