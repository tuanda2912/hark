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
// Identity rule (overlap-based — supersedes the original 100ms bucket rule):
//
//   Two segments from consecutive windows are "the same utterance" iff
//   their absolute-session-time intervals overlap by ≥ 50% of the shorter
//   interval. WhisperKit can shift its segment boundaries by 1–3 seconds
//   between consecutive windows (the decoder re-segments the full 30 s
//   buffer each pass), so a 100 ms bucket on tStart routinely misses
//   matches that are obviously the same utterance to a human reader.
//
//   Smoke-test evidence (2026-05-27): bucket rule produced 4+ distinct
//   utterance_ids for "And on the backend, the API spec…" across three
//   windows — UI would render duplicates instead of replacing in place.
//
//   Overlap rule trades a tiny risk of false-merging two distinct
//   utterances that happen to share ≥50% time range (rare; speech
//   doesn't usually time-share) for robust identity continuity. See
//   `UtteranceLedger.resolve` below.
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
/// Each entry holds an UUID + the latest known [tStart, tEnd] interval
/// + the latest emitted text + a finalized flag. New segments resolve
/// against entries by **interval-overlap score** (overlap seconds /
/// length of the shorter interval). The best-scoring entry wins if its
/// score crosses `overlapThreshold` (default 0.5). Otherwise a fresh
/// entry is minted.
///
/// Java analogue: a `List<Entry>` (we don't need hash lookup — N is small
/// per session, typically < 100 utterances over an hour). Linear scan
/// dominated by speech; not a perf concern.
final class UtteranceLedger {
    /// Threshold for "same utterance" — overlap-of-shorter ratio. 0.5
    /// means: the two intervals must share at least half of the shorter
    /// one's duration. Lower this if Phase 4 dogfooding shows missed
    /// matches; raise it if false merges become a problem.
    private let overlapThreshold: Double = 0.5

    private struct Entry {
        let id: String
        var tStart: Double
        var tEnd: Double
        var lastText: String
        var finalized: Bool
    }

    private var entries: [Entry] = []

    /// Look up or mint the utterance ID for a segment occupying [tStart, tEnd].
    /// The matched entry's interval is updated to the new range (the latest
    /// transcription pass is treated as the most accurate belief).
    func resolve(tStart: Double, tEnd: Double, text: String) -> String {
        let segLen = max(0.0, tEnd - tStart)
        if segLen <= 0 {
            // Degenerate (zero-length) segment — give it a fresh ID rather
            // than risk falsely matching a real one with overlap=0/0.
            return mint(tStart: tStart, tEnd: tEnd, text: text)
        }

        // Best non-finalized overlap. We never reuse a finalized entry's
        // ID because emitting a partial after a final would confuse the UI.
        var bestIdx: Int? = nil
        var bestScore: Double = 0.0
        for (i, e) in entries.enumerated() where !e.finalized {
            let overlapStart = max(tStart, e.tStart)
            let overlapEnd = min(tEnd, e.tEnd)
            let overlap = max(0.0, overlapEnd - overlapStart)
            let eLen = max(0.0, e.tEnd - e.tStart)
            let shorter = min(segLen, eLen)
            guard shorter > 0 else { continue }
            let score = overlap / shorter
            if score > bestScore {
                bestScore = score
                bestIdx = i
            }
        }

        if let i = bestIdx, bestScore >= overlapThreshold {
            entries[i].tStart = tStart
            entries[i].tEnd = tEnd
            // lastText is updated by `updateText`, not here — so a caller
            // can still ask "did the text change since last emit?".
            return entries[i].id
        }

        return mint(tStart: tStart, tEnd: tEnd, text: text)
    }

    private func mint(tStart: Double, tEnd: Double, text: String) -> String {
        let id = UUID().uuidString
        entries.append(Entry(id: id, tStart: tStart, tEnd: tEnd, lastText: "", finalized: false))
        return id
    }

    /// Returns true if `text` differs from the last text emitted for this
    /// utterance ID. Updates the stored text as a side effect.
    /// Java analogue: `Map.put` returning the previous value, then compare.
    func updateText(_ text: String, utteranceId: String) -> Bool {
        guard let i = entries.firstIndex(where: { $0.id == utteranceId }) else {
            return true  // unknown ID — treat as changed (caller will emit partial)
        }
        let changed = entries[i].lastText != text
        entries[i].lastText = text
        return changed
    }

    func isFinalized(utteranceId: String) -> Bool {
        entries.first(where: { $0.id == utteranceId })?.finalized ?? false
    }

    func markFinalized(utteranceId: String) {
        if let i = entries.firstIndex(where: { $0.id == utteranceId }) {
            entries[i].finalized = true
        }
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
