// Diarizer — thin actor around FluidAudio's DiarizerManager.
//
// Java analogue: a single-purpose `@Service` that owns one non-thread-safe
// collaborator and serializes every call to it. `DiarizerManager` holds
// mutable speaker-tracking state and is NOT Sendable, so we confine it to
// this actor's isolation domain — no manual locks.
//
// Why a SEPARATE actor from EngineSession: `performCompleteDiarization` is a
// synchronous, CPU/ANE-bound call that runs the whole meeting through the
// segmentation + embedding + clustering models. If it ran on EngineSession's
// executor it would freeze the live WS/session actor for the duration. By
// putting it on a dedicated actor, only THIS actor blocks during the pass
// (which is fine — it has no other job), and EngineSession stays responsive
// to clients while it `await`s the result.
//
// Strictly OFFLINE: this is only ever invoked from EngineSession.flushOnStop,
// after capture has stopped. It never touches the live transcription path.

import Foundation
import FluidAudio

@available(macOS 14.4, *)
actor Diarizer {
    private let manager: DiarizerManager

    init(manager: DiarizerManager) {
        self.manager = manager
    }

    /// Run a complete offline diarization pass over the full session audio.
    /// `samples` is 16 kHz mono Float — exactly what the capture mixer
    /// produces and WhisperKit consumes.
    ///
    /// Synchronous under the hood; this actor's executor carries the heavy
    /// work so callers just `await`. Throws `DiarizerError` on failure —
    /// the caller treats any throw as "no speakers" and continues.
    func diarize(_ samples: [Float], sampleRate: Int = 16_000) throws -> DiarizationResult {
        try manager.performCompleteDiarization(samples, sampleRate: sampleRate)
    }
}
