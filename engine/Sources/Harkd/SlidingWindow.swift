// SlidingWindow — speech-gated 30s window with 5s hop + utterance reconciliation.
//
// ADR-0008 §3:
//   - Window: 30 s of audio.
//   - Hop:    5 s.
//   - Only frames classified as speech by VAD accumulate into the window.
//   - Each hop fires a transcription of the latest 30 s.
//   - New segments (in the last 5 s tail) emit as `segment.partial` first;
//     they become `segment.final` once the next window confirms them.
//   - Segments in the older 25 s are re-transcribed; if text changes, emit
//     a replacement `segment.partial` with the SAME utterance_id.
//
// Identity rule (per the prompt's implementation hint):
//   Two segments from consecutive windows are "the same utterance" iff
//   their `t_start` (anchored to absolute session time) rounds to the
//   same 100 ms bucket. We keep a `UtteranceLedger` mapping bucket → UUID.
//
// Threading: this type is NOT thread-safe on its own. It lives inside
// `EngineSession`'s actor, which serializes all mutations.

import Foundation

/// Output of a window transcription, normalized to absolute session time.
struct WindowSegment {
    /// Start time in seconds, relative to capture start (not window start).
    let tStart: Double
    let tEnd: Double
    let text: String
    let language: String?
}

/// Per-segment emission decision after reconciliation.
struct ReconciledEmission {
    let utteranceId: String
    /// `false` for "still in the live 5 s tail" (partial), `true` for "the
    /// next window confirmed it unchanged" (final).
    let isFinal: Bool
    let tStart: Double
    let tEnd: Double
    let text: String
    let language: String?
}

/// Tracks identity of utterances across consecutive window transcriptions.
///
/// Bucket = `Int(round(tStart * 10))` — 100 ms resolution. Java analogue:
/// a `HashMap<Long, UUID>` with the key being `Math.round(tStart * 10)`.
final class UtteranceLedger {
    /// bucket → utterance UUID. Persists for the session.
    private var idByBucket: [Int: String] = [:]
    /// bucket → last-emitted text. Used to detect "still the same partial".
    private var lastTextByBucket: [Int: String] = [:]
    /// bucket → has been emitted as final. Once final, don't downgrade.
    private var finalized: Set<Int> = []

    private func bucket(_ t: Double) -> Int {
        Int((t * 10.0).rounded())
    }

    /// Look up or mint the utterance ID for this segment start.
    func idFor(tStart: Double) -> String {
        let b = bucket(tStart)
        if let existing = idByBucket[b] { return existing }
        let fresh = UUID().uuidString
        idByBucket[b] = fresh
        return fresh
    }

    /// Returns true if the text at this bucket has changed since last emit.
    /// Updates the ledger as a side effect.
    func updateText(_ text: String, tStart: Double) -> Bool {
        let b = bucket(tStart)
        let changed = lastTextByBucket[b] != text
        lastTextByBucket[b] = text
        return changed
    }

    func isFinalized(tStart: Double) -> Bool {
        finalized.contains(bucket(tStart))
    }

    func markFinalized(tStart: Double) {
        finalized.insert(bucket(tStart))
    }
}

/// 30 s sliding-window buffer of speech frames, with a 5 s hop trigger.
///
/// Stores only speech samples (the VAD gate already dropped silence). The
/// timeline tracking is dual:
///   - `windowSamples` — the raw Float32 ring (only speech).
///   - `windowStartTime` — absolute session time of the first sample in
///     the ring. As we hop, we discard the oldest 5 s and advance this.
///
/// The "absolute session time" is incremented by every accepted speech
/// frame batch. Silence frames are simply skipped — they don't take up
/// window space and they don't advance the session clock contribution
/// for what's in the buffer, but the *external* session clock (wall time
/// since capture start) keeps running.
///
/// Why two clocks: window-internal time stays compact (no silence gaps
/// take up Whisper compute), but the segments we emit need *real* session
/// time so the UI can highlight them on a timeline. We track both:
///   - `speechSecondsAccumulated` — seconds of speech in the window.
///   - per-frame `sessionTimeAtSample[i]` would be expensive; instead we
///     keep a parallel array `sampleTimestamps` of (sampleIndex, sessionTime)
///     anchors at each VAD speech transition so segments can be mapped
///     back to wall-clock time.
final class SlidingWindowBuffer {
    let windowSeconds: Double
    let hopSeconds: Double
    let sampleRate: Int

    private(set) var windowSamples: [Float] = []
    /// Parallel anchors: (offset-in-window, session-time-seconds). One
    /// entry per accepted speech batch. Used to map segment t_start
    /// (window-relative) back to absolute session time.
    private var anchors: [(offsetInWindow: Int, sessionTime: Double)] = []

    /// Total speech samples ever appended (monotonic, doesn't decrease on hop).
    private(set) var totalSpeechSamples: Int = 0
    /// Samples ingested since the last `popHopIfReady` returned a window.
    private var samplesSinceLastHop: Int = 0

    init(windowSeconds: Double, hopSeconds: Double, sampleRate: Int) {
        self.windowSeconds = windowSeconds
        self.hopSeconds = hopSeconds
        self.sampleRate = sampleRate
    }

    /// Push speech samples that started at `sessionTime` (seconds since
    /// capture began). Returns nothing — call `popWindowIfReady` after
    /// each push to drive the hop.
    func append(_ samples: [Float], sessionTime: Double) {
        if samples.isEmpty { return }
        anchors.append((offsetInWindow: windowSamples.count, sessionTime: sessionTime))
        windowSamples.append(contentsOf: samples)
        totalSpeechSamples += samples.count
        samplesSinceLastHop += samples.count

        // Trim front if we've exceeded the window length. Drop oldest samples
        // in one shot (rather than per-frame) so this stays O(n) amortized.
        let maxSamples = Int(windowSeconds * Double(sampleRate))
        if windowSamples.count > maxSamples {
            let drop = windowSamples.count - maxSamples
            windowSamples.removeFirst(drop)
            // Shift all anchor offsets down by `drop`; discard anchors that
            // fall off the front of the window.
            anchors = anchors.compactMap { a in
                let newOffset = a.offsetInWindow - drop
                if newOffset < 0 { return nil }
                return (newOffset, a.sessionTime)
            }
        }
    }

    /// Returns (windowSamples, windowStartSessionTime) if a hop's worth of
    /// new speech has accumulated. Resets the hop counter.
    func popHopIfReady() -> (samples: [Float], windowStartSessionTime: Double)? {
        let hopSamples = Int(hopSeconds * Double(sampleRate))
        guard samplesSinceLastHop >= hopSamples else { return nil }
        samplesSinceLastHop = 0
        // Snapshot the current window. Anchor 0 is the session time of the
        // oldest sample in the buffer.
        guard let first = anchors.first else { return nil }
        // Compute the session-time offset for the start of the buffer:
        // first anchor's session time minus seconds equivalent to its offset.
        let firstOffsetSeconds = Double(first.offsetInWindow) / Double(sampleRate)
        let windowStartSessionTime = first.sessionTime - firstOffsetSeconds
        return (Array(windowSamples), windowStartSessionTime)
    }

    /// Maps a window-relative time (seconds from start of `windowSamples`)
    /// to absolute session time. Linear interpolation between anchors.
    func windowTimeToSessionTime(windowOffsetSeconds: Double, windowStartSessionTime: Double) -> Double {
        // Speech-only buffer: 1 second of buffer == 1 second of session-time
        // *speech*. Since silence was already dropped, the offset in the
        // buffer corresponds to "speech seconds since window start" not to
        // wall-clock seconds. We map it back by walking anchors.
        let offsetSamples = Int(windowOffsetSeconds * Double(sampleRate))
        // Find the anchor whose offsetInWindow <= offsetSamples and that
        // is the largest such offset. Linear search — anchors are small.
        var matched: (offsetInWindow: Int, sessionTime: Double) = (0, windowStartSessionTime)
        for a in anchors where a.offsetInWindow <= offsetSamples {
            matched = a
        }
        let extraSamples = offsetSamples - matched.offsetInWindow
        let extraSeconds = Double(extraSamples) / Double(sampleRate)
        return matched.sessionTime + extraSeconds
    }

    var fillSeconds: Double {
        Double(windowSamples.count) / Double(sampleRate)
    }
}
