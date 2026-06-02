// LiveDiarizer — OPTIONAL streaming speaker diarization for the LIVE path.
//
// Counterpart to `Diarizer` (the OFFLINE, at-stop, authoritative pass). This
// one wraps FluidAudio's STREAMING `DiarizerManager` (pyannote-3.1 segmentation
// + WeSpeaker embedding + online SpeakerManager clustering) and runs IN PARALLEL
// with WhisperKit transcription so emitted `segment.partial`/`segment.final`
// can carry a PROVISIONAL "Speaker A/B/…" label while the meeting is live.
//
// Why a SEPARATE actor + SEPARATE manager from the offline pass (coexistence):
//   - The two FluidAudio pipelines use DIFFERENT CoreML model files — the
//     streaming `DiarizerModels` loads `pyannote_segmentation.mlmodelc` +
//     `wespeaker_v2.mlmodelc`; the offline `OfflineDiarizerModels` loads
//     `Segmentation/Embedding/FBank/PldaRho.mlmodelc` (variant "offline"). They
//     CANNOT share loaded MLModels. So this needs its own one-time load (see
//     LiveDiarizerLoader) — a second, modest ANE-resident model pair.
//   - FluidAudio's own guidance: "keep one DiarizerManager per stream for
//     consistent speaker IDs." We hold exactly one manager for the session's
//     lifetime; its internal SpeakerManager accumulates embeddings so the same
//     person keeps the same speakerId across chunks. A fresh manager per
//     capture.start means clean per-session IDs (no leakage across meetings).
//
// Threading (CLAUDE.md hot-path rule): `performCompleteDiarization` is a
// synchronous, CPU/ANE-bound `throws` call. We confine it to THIS actor so it
// never runs on the audio pump thread and never blocks WhisperKit. EngineSession
// tees audio to us via `Task { await liveDiarizer.ingest(...) }` (the same
// off-actor hop the capture sink uses) and reads the timeline the same way.
//
// Privacy: speaker IDs/labels are anonymous and local. No embedding, no audio,
// no label ever leaves the machine (hard rules #1/#2/#5). Nothing here logs
// transcript text.

import Foundation
import FluidAudio

@available(macOS 14.4, *)
actor LiveDiarizer {
    private let manager: DiarizerManager

    /// Provisional speaker timeline built from the streaming diarizer's
    /// exclusive segments, in session-time seconds. Append-mostly; queried by
    /// max temporal overlap when tagging an emitted utterance. Lives on the
    /// actor — never touched off-actor.
    private var timeline: [TimelineSegment] = []

    /// streaming speakerId ("S1", "S2"…) → stable display label ("Speaker A",
    /// "Speaker B"…) in FIRST-SEEN order. Live labels need NOT match the offline
    /// numbering — the stop pass replaces them — so we deliberately use LETTERS
    /// (A/B/C) to make it visually obvious on screen that the live label is
    /// provisional and distinct from the final "Speaker 1/2" the vault carries.
    private var labelForSpeakerId: [String: String] = [:]
    private var nextLabelIndex = 0

    /// Chunk accounting for the diagnostic + back-pressure decision.
    private var chunksProcessed = 0
    private var chunksDropped = 0
    private var processingBusy = false

    init(manager: DiarizerManager) {
        self.manager = manager
        // ONE streaming manager is shared for the daemon's life (loaded once),
        // so wipe its accumulated speaker database at the start of each session.
        // This gives clean per-session speaker IDs (no speaker leakage across
        // meetings) without a per-session model reload/recompile. The manager's
        // SpeakerManager is a value-type `public var` we may mutate in place.
        self.manager.speakerManager.reset()
    }

    /// One exclusive provisional speaker segment on the session timeline.
    struct TimelineSegment: Equatable, Sendable {
        let tStart: Double
        let tEnd: Double
        let label: String   // already mapped to "Speaker A/B/…"
    }

    /// Feed one chunk of CONTINUOUS 16 kHz mono audio (the SAME mixed frames
    /// the transcription window sees), anchored at absolute session-time
    /// `chunkStartTime`. Runs the streaming diarizer over it and folds the
    /// resulting exclusive segments into the timeline.
    ///
    /// `processingBusy` is the back-pressure guard: if a prior chunk's
    /// diarization is still running on this actor, a NEW chunk that arrives is
    /// DROPPED (counted) rather than queued — we never let provisional speaker
    /// work stall and never grow an unbounded backlog. The live caption never
    /// depends on this completing; a dropped chunk just means the affected
    /// span stays unlabeled until a later chunk re-covers it (the offline pass
    /// fixes everything at stop regardless). Returns the chunk's processing
    /// seconds (for the caller's RTF-style log), or nil if dropped.
    @discardableResult
    func ingest(_ samples: [Float], chunkStartTime: Double) -> Double? {
        if processingBusy {
            chunksDropped += 1
            return nil
        }
        // Too short to diarize meaningfully (the streaming pipeline pads to its
        // own chunk size, but a sub-second sliver yields no useful segment).
        guard samples.count >= 16_000 / 2 else { return nil }

        processingBusy = true
        defer { processingBusy = false }

        let started = Date()
        let result: DiarizationResult
        do {
            // atTime: anchors the returned segments to absolute session time, so
            // the timeline shares ONE axis with the utterances we tag.
            result = try manager.performCompleteDiarization(
                samples, sampleRate: 16_000, atTime: chunkStartTime)
        } catch {
            // Non-fatal — provisional labels are best-effort. Log type only.
            FileHandle.standardError.write(Data(
                "harkd: live diarize chunk error: \(type(of: error))\n".utf8))
            return nil
        }
        let elapsed = Date().timeIntervalSince(started)
        chunksProcessed += 1

        for seg in result.segments where !seg.speakerId.isEmpty {
            let label = labelFor(speakerId: seg.speakerId)
            timeline.append(TimelineSegment(
                tStart: Double(seg.startTimeSeconds),
                tEnd: Double(seg.endTimeSeconds),
                label: label))
        }
        // Keep the timeline bounded over a long meeting. Provisional tags only
        // ever look back over the just-emitted utterance's [t_start, t_end]
        // (seconds, near the live edge), so segments far behind the newest one
        // can be dropped. Bound to the last ~5 min of timeline.
        pruneTimeline(keepingAfter: (timeline.last?.tEnd ?? 0) - 300)

        return elapsed
    }

    /// Provisional speaker label for an utterance occupying [start, end], by
    /// MAX temporal overlap against the timeline — the SAME rule the offline
    /// pass uses (`EngineSession.matchSpeaker`). `nil` when nothing overlaps
    /// (the diarizer hasn't caught up to that span yet): the caller leaves the
    /// line unattributed; it gets a label on a later emit or at the stop refine.
    func provisionalSpeaker(forStart start: Double, end: Double) -> String? {
        Self.dominantLabel(forStart: start, end: end, timeline: timeline)
    }

    /// Diagnostic snapshot (state only, no transcript text) for the stop log.
    func stats() -> (processed: Int, dropped: Int, speakers: Int, segments: Int) {
        (chunksProcessed, chunksDropped, labelForSpeakerId.count, timeline.count)
    }

    // ─── Pure helpers (no actor state captured — unit-test seam) ─────────────

    /// Map a streaming speakerId to a stable "Speaker A/B/…" label in first-seen
    /// order. Mutates the actor's first-seen map; the PURE ordinal→letter form
    /// is `Self.label(forIndex:)` so the mapping is testable without an actor.
    private func labelFor(speakerId: String) -> String {
        if let existing = labelForSpeakerId[speakerId] { return existing }
        let label = Self.label(forIndex: nextLabelIndex)
        labelForSpeakerId[speakerId] = label
        nextLabelIndex += 1
        return label
    }

    /// PURE: first-seen index → "Speaker A", "Speaker B", … "Speaker Z",
    /// "Speaker AA", … (spreadsheet-column lettering, so it never runs out and
    /// never collides with the offline "Speaker 1/2" numbering). No state, no
    /// I/O — driven directly by the unit test.
    static func label(forIndex index: Int) -> String {
        precondition(index >= 0)
        var n = index
        var letters = ""
        repeat {
            let rem = n % 26
            letters = String(UnicodeScalar(UInt8(65 + rem))) + letters
            n = n / 26 - 1
        } while n >= 0
        return "Speaker \(letters)"
    }

    /// PURE: the dominant label over [start, end] by max temporal overlap.
    /// Mirrors `EngineSession.matchSpeaker` (pick the single max-overlap
    /// segment; require overlap > 0). `nil` when no timeline segment overlaps.
    /// No actor state — driven directly by the unit test.
    static func dominantLabel(
        forStart start: Double, end: Double, timeline: [TimelineSegment]
    ) -> String? {
        var bestLabel: String? = nil
        var bestOverlap = 0.0
        for seg in timeline {
            let overlap = min(end, seg.tEnd) - max(start, seg.tStart)
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestLabel = seg.label
            }
        }
        return bestOverlap > 0 ? bestLabel : nil
    }

    private func pruneTimeline(keepingAfter cutoff: Double) {
        guard cutoff > 0, timeline.count > 256 else { return }
        timeline.removeAll { $0.tEnd < cutoff }
    }
}
