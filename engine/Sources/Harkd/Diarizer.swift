// Diarizer — thin actor around FluidAudio's OfflineDiarizerManager.
//
// Java analogue: a single-purpose `@Service` that owns one heavyweight
// collaborator and serializes every call to it. `OfflineDiarizerManager` holds
// the loaded CoreML models + config; we confine it to this actor's isolation
// domain so its model state is touched from exactly one place — no manual locks.
//
// Why a SEPARATE actor from EngineSession: the offline pass runs the whole
// meeting through segmentation + embedding extraction + VBx clustering. Even
// though it's `async` internally (it fans out segmentation/embedding onto
// detached tasks), confining it here means EngineSession stays responsive to
// clients while it `await`s the result, and the diarizer's own state never
// races with the live session actor.
//
// Strictly OFFLINE: this is only ever invoked from EngineSession.flushOnStop,
// after capture has stopped. It never touches the live transcription path.

import Foundation
import FluidAudio

@available(macOS 14.4, *)
actor Diarizer {
    private let manager: OfflineDiarizerManager

    init(manager: OfflineDiarizerManager) {
        self.manager = manager
    }

    /// Run a complete offline diarization pass over the full session audio.
    /// `samples` is 16 kHz mono Float — exactly what the capture mixer
    /// produces and WhisperKit consumes (the offline pipeline's segmentation
    /// is configured for 16 kHz, so no resample is needed).
    ///
    /// Returns FluidAudio's `DiarizationResult` whose `.segments` are EXCLUSIVE
    /// (non-overlapping) `TimedSpeakerSegment`s — the same result shape the
    /// streaming pipeline returned, so EngineSession's overlap-assignment is
    /// unchanged. Throws on failure (e.g. `noSpeechDetected`); the caller treats
    /// any throw as "no speakers" and writes the meeting unlabeled.
    ///
    /// NOTE: `sampleRate` is accepted for call-site symmetry but the offline
    /// `process(audio:)` reads its own `segmentation.sampleRate` (16 kHz) from
    /// the config — our capture is already 16 kHz so the two agree.
    func diarize(_ samples: [Float], sampleRate: Int = 16_000) async throws -> DiarizationResult {
        try await manager.process(audio: samples)
    }
}
