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
// Identity rule (overlap-based, max-denominator — see ADR-0009):
//
//   Two segments from consecutive windows are "the same utterance" iff
//   their absolute-session-time intervals overlap by ≥ 50% of the
//   LONGER interval (i.e. `overlap / max(segLen, eLen) ≥ 0.5`).
//   WhisperKit can shift its segment boundaries by 1–3 seconds between
//   consecutive windows (the decoder re-segments the full 30 s buffer
//   each pass), so a 100 ms bucket on tStart routinely misses matches
//   that are obviously the same utterance to a human reader.
//
//   History — two revisions:
//     v1 (commit be31c52, 2026-05-27): `overlap / min(segLen, eLen)`.
//        Caught boundary jitter but had an engulfment hole — when
//        WhisperKit produced a coarser segmentation pass and a long new
//        segment fully contained a short existing entry, the score was
//        always 1.0 regardless of how different the text was. Smoke
//        test 2026-05-28 caught it: utterance_id `1C4B2CBA` flipped
//        from "Okay." → "the scheme where they provide the secure so
//        that's the stack okay i'm now going to enter the". The UI
//        would render an in-place mutation across alien content.
//     v2 (this revision): max-denominator. Engulfment now scores
//        `shorter / longer` — a short entry inside a long new segment
//        gets a low score (typically < 0.4) and falls below the
//        threshold, so a fresh UUID is minted instead of hijacking the
//        existing one. The legitimate continuity cases (8B0877AC's
//        shrink/grow across windows, partial→final for in-zone
//        segments) still score ≥ 0.5 because their interval lengths
//        stay roughly comparable.
//
//   Tradeoff accepted: when WhisperKit dramatically re-segments and
//   the new shape is much wider than the old, we'll mint a fresh ID
//   instead of preserving continuity. The old entry becomes an orphan
//   (no further partials, never finalized). That's better than the
//   alternative — having a stable UUID drift across unrelated content.
//   Orphans get cleaned up by `prune(beforeSessionTime:)` once they
//   drop out of the active window.
//
//   See `UtteranceLedger.resolve` below and ADR-0009 for full rationale.
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
/// against entries by **interval-overlap score**, computed as
/// `overlap_seconds / max(seg_length, entry_length)`. The best-scoring
/// non-finalized entry wins if its score crosses `overlapThreshold`
/// (default 0.5). Otherwise a fresh entry is minted.
///
/// Java analogue: a `List<Entry>` (we don't need hash lookup — N is small
/// per session, typically < 100 utterances over an hour). Linear scan
/// dominated by speech; not a perf concern.
final class UtteranceLedger {
    /// Threshold for "same utterance" — overlap divided by the LONGER
    /// of the two interval lengths must reach this value. 0.5 means:
    /// the two intervals must cover at least half of the longer one.
    /// This rule rejects engulfment (long new ⊃ short existing) because
    /// in that case `overlap == shorter`, so score = `shorter / longer`,
    /// which is small whenever the new segment is much wider than the
    /// existing entry. See class doc comment and ADR-0009.
    ///
    /// Lower this if Phase 4 dogfooding shows missed matches; raise it
    /// if false merges become a problem.
    private let overlapThreshold: Double = 0.5

    // ─── Supersession tuning (ADR-0018) ───────────────────────────────────
    //
    // A new segment SUPERSEDES an existing entry only when BOTH a time-
    // containment AND a text-containment test pass — never on text alone (the
    // time gate is what protects legitimately repeated phrases at a different
    // time; ADR-0018 §Decision). The conservative bias is intentional: a
    // leftover fragment is a lesser evil than retracting a real utterance.

    /// How far the new segment's start may sit AFTER the old entry's start and
    /// still count as "same start". WhisperKit drifts boundaries 1–3 s between
    /// passes (ADR-0009 §Context); 1.5 s absorbs that jitter without letting a
    /// distinct later utterance pose as a re-segmentation of an earlier one.
    private let supersedeStartSlack: Double = 1.5
    /// How far the new segment's end may fall SHORT of the old entry's end and
    /// still count as "new contains old". Same jitter rationale; the dominant
    /// signal is that the new end extends well past the old, so this only
    /// forgives sub-second boundary wobble.
    private let supersedeEndSlack: Double = 0.75

    private struct Entry {
        let id: String
        var tStart: Double
        var tEnd: Double
        var lastText: String
        var finalized: Bool
        /// Set when a later, overlapping, more-complete segment supersedes this
        /// entry (ADR-0018). A superseded entry is never re-matched by `resolve`
        /// and is never emitted as a synthetic final by `prune` — it has been
        /// retracted in favour of `supersededBy`.
        var superseded: Bool
    }

    private var entries: [Entry] = []

    /// One supersession event: the older fragment `oldId` was retracted in
    /// favour of the newer, extending segment `newId`. Drained by the caller
    /// (EngineSession) which broadcasts a `segment.superseded` per event and
    /// filters `oldId` out of the at-stop vault retention. Chains surface as
    /// separate events (A→B then B→C) in the order they were detected.
    struct SupersessionEvent: Equatable {
        let oldId: String
        let newId: String
    }
    private var pendingSupersessions: [SupersessionEvent] = []

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

        // Best non-finalized, non-superseded overlap. We never reuse a
        // finalized entry's ID (emitting a partial after a final confuses the
        // UI) nor a superseded one (it has been retracted — ADR-0018).
        //
        // Score = overlap / max(segLen, eLen). The max-denominator form
        // ensures engulfment (one interval ⊂ the other) does NOT auto-match
        // when the lengths are very different — see class doc + ADR-0009.
        var bestIdx: Int? = nil
        var bestScore: Double = 0.0
        for (i, e) in entries.enumerated() where !e.finalized && !e.superseded {
            let overlapStart = max(tStart, e.tStart)
            let overlapEnd = min(tEnd, e.tEnd)
            let overlap = max(0.0, overlapEnd - overlapStart)
            let eLen = max(0.0, e.tEnd - e.tStart)
            let longer = max(segLen, eLen)
            guard longer > 0 else { continue }
            let score = overlap / longer
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

        // Below threshold → a fresh UUID is minted (ADR-0009). This is exactly
        // the re-segmentation-grows signature: a wider new segment scores
        // `shorter/longer < 0.5` against the short fragment it contains. Before
        // minting, detect whether this new segment SUPERSEDES one or more such
        // fragments (ADR-0018) so the caller can retract them.
        let newId = mint(tStart: tStart, tEnd: tEnd, text: text)
        detectSupersession(newId: newId, newStart: tStart, newEnd: tEnd, newText: text)
        return newId
    }

    private func mint(tStart: Double, tEnd: Double, text: String) -> String {
        let id = UUID().uuidString
        entries.append(Entry(
            id: id, tStart: tStart, tEnd: tEnd, lastText: "",
            finalized: false, superseded: false))
        return id
    }

    // ─── Supersession detection (ADR-0018) ─────────────────────────────────

    /// After a fresh entry `newId` is minted for [newStart, newEnd] / `newText`,
    /// scan the still-live entries for any that this new segment supersedes —
    /// i.e. the new segment is a grown re-segmentation of that earlier fragment.
    /// BOTH conditions must hold (conservative; never text alone — ADR-0018):
    ///
    ///   1. TIME CONTAINMENT — the old entry's [tStart, tEnd] is (approximately)
    ///      contained within the new segment's interval. The new segment starts
    ///      no later than the old (within `supersedeStartSlack`) and ends no
    ///      earlier than the old (within `supersedeEndSlack`). This is the
    ///      re-segmentation signature: the window re-decoded the same span into
    ///      a longer segment. A non-overlapping repeat fails this outright, so
    ///      a legitimately repeated phrase at a different time is never eaten.
    ///
    ///   2. TEXT CONTAINMENT — the old entry's normalized text is a prefix of
    ///      the new segment's normalized text (normalize = lowercase, trim,
    ///      collapse internal whitespace, drop punctuation). The grown version
    ///      literally extends the old words. Prefix (not mere substring) keeps
    ///      it to genuine extensions and avoids matching an incidental
    ///      mid-sentence echo.
    ///
    /// Records each match as a `SupersessionEvent(old → new)` and marks the old
    /// entry `superseded` so `resolve` won't re-match it and `prune` won't emit
    /// a synthetic final for it. Chains fall out naturally: when C later
    /// supersedes B, B is matched here (A was already marked and is skipped),
    /// yielding a separate B→C event after the earlier A→B.
    private func detectSupersession(newId: String, newStart: Double, newEnd: Double, newText: String) {
        let newNorm = Self.normalize(newText)
        if newNorm.isEmpty { return }

        for i in entries.indices {
            let e = entries[i]
            if e.id == newId { continue }
            if e.superseded { continue }

            // 1. Time containment: old ⊆ new, within boundary-jitter slack.
            let startContained = newStart <= e.tStart + supersedeStartSlack
            let endContained = newEnd >= e.tEnd - supersedeEndSlack
            guard startContained && endContained else { continue }

            // 2. Text containment: old normalized text is a prefix of new's.
            let oldNorm = Self.normalize(e.lastText)
            guard !oldNorm.isEmpty else { continue }
            guard oldNorm != newNorm else { continue }  // identical → not a growth
            guard newNorm.hasPrefix(oldNorm) else { continue }

            entries[i].superseded = true
            pendingSupersessions.append(SupersessionEvent(oldId: e.id, newId: newId))
        }
    }

    /// Normalize text for the supersession text-containment test: lowercase,
    /// trim, collapse runs of whitespace to a single space, and strip
    /// punctuation (so "Okay." matches the "okay" inside a longer line and
    /// casing/spacing/punctuation jitter across passes doesn't defeat the
    /// prefix check). Letters/digits/whitespace survive; everything else is
    /// dropped. Unicode-aware via `CharacterSet`.
    private static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
        var out = String.UnicodeScalarView()
        var lastWasSpace = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !lastWasSpace && !out.isEmpty {
                    out.append(" ")
                    lastWasSpace = true
                }
            } else if CharacterSet.alphanumerics.contains(scalar) {
                out.append(scalar)
                lastWasSpace = false
            }
            // else: punctuation/symbol → drop, do NOT reset lastWasSpace so
            // "okay," + space collapses the same as "okay" + space.
        }
        var result = String(out)
        if result.hasSuffix(" ") { result.removeLast() }
        return result
    }

    /// Drain the supersession events detected since the last drain (FIFO).
    /// EngineSession calls this after each `resolve`/`prune` batch and emits a
    /// `segment.superseded` per event. Returns `[]` when nothing was superseded.
    func drainSupersessions() -> [SupersessionEvent] {
        defer { pendingSupersessions.removeAll(keepingCapacity: true) }
        return pendingSupersessions
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

    /// True if a segment occupying [tStart, tEnd] substantially overlaps an
    /// already-FINALIZED entry — i.e. that audio region has already been
    /// committed as a `segment.final`. Used by the at-stop drain (ADR-0019) to
    /// decide "already committed?" by what was ACTUALLY finalized, not by the
    /// commit watermark.
    ///
    /// Why a separate test instead of the watermark: the watermark
    /// (`committedUpTo`) can advance PAST hot-region content without finalizing
    /// it — a long sentence that straddles the commit horizon is finalized with
    /// its full span, advancing the watermark to its `tEnd` (the ADR-0019
    /// straddle refinement), even though later, overlapping speech in that span
    /// was only ever shown as `segment.partial`. The drain must finalize that
    /// still-uncommitted tail, so it cannot gate on the watermark; it gates on
    /// "does this region overlap something we genuinely finalized?" instead.
    ///
    /// `resolve` deliberately does NOT match finalized entries (emitting a
    /// partial after a final confuses the UI), so the drain can't use `resolve`
    /// + `isFinalized` to recognise the head it already committed — it would
    /// mint a fresh id and re-finalize it. This overlap test is the head guard.
    ///
    /// Uses the SAME max-denominator overlap score as `resolve` (ADR-0009) with
    /// the same 0.5 threshold, so "this is the region I already finalized" is
    /// judged by the identical rule that minted the id in the first place.
    func overlapsFinalized(tStart: Double, tEnd: Double) -> Bool {
        let segLen = max(0.0, tEnd - tStart)
        guard segLen > 0 else { return false }
        for e in entries where e.finalized {
            let overlapStart = max(tStart, e.tStart)
            let overlapEnd = min(tEnd, e.tEnd)
            let overlap = max(0.0, overlapEnd - overlapStart)
            let eLen = max(0.0, e.tEnd - e.tStart)
            let longer = max(segLen, eLen)
            guard longer > 0 else { continue }
            if overlap / longer >= overlapThreshold { return true }
        }
        return false
    }

    func markFinalized(utteranceId: String) {
        if let i = entries.firstIndex(where: { $0.id == utteranceId }) {
            entries[i].finalized = true
        }
    }

    // ─── Grow an already-finalized line in place (ADR-0036 content-loss fix) ──
    //
    // The commit watermark finalizes an audio region ONCE, when a segment's
    // start first crosses the horizon (ADR-0019 `commitDecision`). For a long
    // multi-clause utterance that means the SHORT decode present at that hop is
    // what gets finalized; the watermark then advances past its start. A later
    // hop re-decodes the GROWN version with the same start. `resolve` skips
    // finalized entries (emitting a partial after a final confuses the UI), so
    // the grown decode mints a fresh uid, `commitDecision` sees its start behind
    // the watermark → `.skipAlreadyCommitted`, and the grown TAIL is dropped:
    // the saved transcript truncates at the short version.
    //
    // The cure is to EXTEND the finalized line instead of dropping the tail.
    // This is the supersession gate (ADR-0018), re-aimed at finalized entries:
    // same conservative time-containment + text-PREFIX + actually-grew tests, so
    // two genuinely-different utterances never merge. On a match we update the
    // finalized entry's `tEnd`/`lastText` to the fuller values and hand back its
    // id; the caller re-emits its `segment.final` with the full text (the
    // renderer replaces by uid, the vault retains by uid — no loss, no dup). The
    // entry STAYS finalized; we only grow its content.

    /// If `[tStart, tEnd]`/`text` is a GROWN re-decode of an already-FINALIZED,
    /// non-superseded entry — same gate as `detectSupersession`: time containment
    /// (start ≤ e.tStart + supersedeStartSlack AND end ≥ e.tEnd - supersedeEndSlack)
    /// plus text containment (normalized old text is a non-empty prefix of the
    /// normalized new text, and the two differ) AND it genuinely extends
    /// (tEnd > e.tEnd OR the normalized new text is strictly longer than the old)
    /// — UPDATE that entry's `tEnd` + `lastText` to the fuller values and return
    /// its id so the caller can re-emit its `segment.final` with the full text.
    ///
    /// Returns `nil` when no finalized entry matches (NEVER extends on a
    /// non-prefix → two distinct utterances never merge) and when the only match
    /// would be a no-op (an identical re-decode that adds nothing → no spurious
    /// re-emit). Does NOT clear `finalized` — the line stays finalized, just with
    /// fuller text. The entry's `tStart` is left untouched (the committed region
    /// is anchored on its original start; only the end grows).
    func extendFinalizedIfGrown(tStart: Double, tEnd: Double, text: String) -> String? {
        let newNorm = Self.normalize(text)
        if newNorm.isEmpty { return nil }

        for i in entries.indices {
            let e = entries[i]
            guard e.finalized && !e.superseded else { continue }

            // 1. Time containment: old ⊆ new, within boundary-jitter slack —
            //    the same re-segmentation signature `detectSupersession` uses.
            let startContained = tStart <= e.tStart + supersedeStartSlack
            let endContained = tEnd >= e.tEnd - supersedeEndSlack
            guard startContained && endContained else { continue }

            // 2. Text containment: old normalized text is a prefix of new's, and
            //    they differ (identical text is not a growth).
            let oldNorm = Self.normalize(e.lastText)
            guard !oldNorm.isEmpty else { continue }
            guard oldNorm != newNorm else { continue }
            guard newNorm.hasPrefix(oldNorm) else { continue }

            // 3. Actually extends: the time-end grows OR the text is strictly
            //    longer. (Prefix + differ already implies longer text here, but
            //    keep the explicit guard so an identical re-decode that only
            //    nudged tEnd within slack still grows, and a no-op returns nil.)
            let grewInTime = tEnd > e.tEnd
            let grewInText = newNorm.count > oldNorm.count
            guard grewInTime || grewInText else { continue }

            entries[i].tEnd = tEnd
            entries[i].lastText = text
            return e.id
        }
        return nil
    }

    /// A live (non-finalized, non-superseded) ledger entry that still has a
    /// known interval + last-emitted text. Returned by `liveEntriesAbove` for
    /// the at-stop hot-region finalize (ADR-0019 content-loss fix). These are
    /// exactly the trailing `segment.partial`s the user saw on screen but that
    /// the live loop never promoted to `segment.final` (their start was always
    /// ahead of the commit horizon, then behind the over-advanced watermark).
    struct LiveEntry: Equatable {
        let id: String
        let tStart: Double
        let tEnd: Double
        let lastText: String
    }

    /// Enumerate the live (non-finalized, non-superseded) entries whose
    /// `tStart` lies AT OR AFTER `cutoff` (the commit watermark), in ascending
    /// `tStart` order. This is the hot region the user saw as partials but that
    /// was never finalized. Entries with empty `lastText` (minted but never
    /// given text) are skipped — there's nothing to write.
    ///
    /// Why `>=` and not strictly `>`: on device the last live `segment.final`
    /// ended exactly where the lost tail began (watermark ≈ 174 s, first lost
    /// partial started ≈ 174 s). A strict `>` drops a tail utterance that
    /// starts exactly on the watermark — re-introducing the bug at the
    /// boundary. Inclusivity is safe here because `finalizeHotRegion` gates on
    /// `overlapsFinalized` (what was ACTUALLY finalized), not on the watermark:
    /// a boundary entry that genuinely IS the committed region overlaps a
    /// finalized entry and is skipped there; a boundary entry that was only
    /// ever a partial does NOT overlap (zero-length boundary overlap scores 0)
    /// and is correctly recovered. The watermark is the coarse filter; the
    /// overlap test is the precise guard.
    ///
    /// The at-stop path (`finalizeHotRegion`) finalizes each of these directly
    /// from its stored text, deterministically — it does NOT depend on
    /// WhisperKit re-producing the same segments from the residual audio buffer
    /// (the fragile path that dropped the tail). See ADR-0019.
    ///
    /// Read-only: it does not mutate the ledger. Callers mark each entry
    /// finalized via `markFinalized` once they've emitted it.
    func liveEntriesAbove(_ cutoff: Double) -> [LiveEntry] {
        entries
            .filter { !$0.finalized && !$0.superseded
                && $0.tStart >= cutoff
                && !$0.lastText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { LiveEntry(id: $0.id, tStart: $0.tStart, tEnd: $0.tEnd, lastText: $0.lastText) }
            .sorted { $0.tStart < $1.tStart }
    }

    /// Information about an entry that fell out of the active window
    /// and was dropped from the ledger. Returned by `prune` so callers
    /// can react (e.g. emit a `segment.final` for an orphan partial so
    /// the UI doesn't dangle).
    struct PrunedEntry {
        let id: String
        let tStart: Double
        let tEnd: Double
        let lastText: String
        let wasFinalized: Bool
        /// True if this entry was retracted by a later re-segmentation
        /// (ADR-0018). The caller must NOT emit a synthetic `segment.final`
        /// for it — it has already been superseded; a closing final would
        /// resurrect the fragment the supersession just retracted.
        let wasSuperseded: Bool
    }

    /// Drop entries whose `tEnd` is strictly less than `cutoff`. Returns
    /// the dropped entries (in original insertion order) so callers can
    /// emit closure events for any non-finalized orphans.
    ///
    /// Rationale: once an entry's whole interval is before the current
    /// window's left edge, no future window transcription can produce a
    /// segment that overlaps it — so keeping it around would just slow
    /// down `resolve` over a long session and risk false matches in the
    /// pathological case where time arithmetic drifts past the cutoff.
    /// See ADR-0009.
    @discardableResult
    func prune(beforeSessionTime cutoff: Double) -> [PrunedEntry] {
        var dropped: [PrunedEntry] = []
        var kept: [Entry] = []
        kept.reserveCapacity(entries.count)
        for e in entries {
            if e.tEnd < cutoff {
                dropped.append(PrunedEntry(
                    id: e.id,
                    tStart: e.tStart,
                    tEnd: e.tEnd,
                    lastText: e.lastText,
                    wasFinalized: e.finalized,
                    wasSuperseded: e.superseded
                ))
            } else {
                kept.append(e)
            }
        }
        entries = kept
        return dropped
    }

    /// Test-only helper. Returns current entry count.
    var entryCount: Int { entries.count }
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

    /// Speech seconds accumulated since the last hop pop. `> 0` means there's
    /// un-decoded speech that an idle-flush pass could refine into a fresher
    /// partial. Drives the idle-flush trigger (perf/live-caption-latency).
    var pendingHopSeconds: Double { Double(samplesSinceLastHop) / Double(sampleRate) }

    /// Pop the current window for an idle-flush transcription even though a full
    /// `hopSeconds` of speech hasn't accumulated yet — PROVIDED some new speech is
    /// pending. Same snapshot + counter-reset as `popHopIfReady`, minus the
    /// threshold gate. Lets a short utterance before a pause caption promptly
    /// instead of waiting for 5 s of speech to pile up. Returns nil when there's
    /// no new speech (nothing to refine) or no anchor yet.
    func popHopForced() -> (samples: [Float], windowStartSessionTime: Double)? {
        guard samplesSinceLastHop > 0 else { return nil }
        samplesSinceLastHop = 0
        guard let first = anchors.first else { return nil }
        let firstOffsetSeconds = Double(first.offsetInWindow) / Double(sampleRate)
        let windowStartSessionTime = first.sessionTime - firstOffsetSeconds
        return (Array(windowSamples), windowStartSessionTime)
    }

    /// Session time of the oldest sample currently in the buffer, computed the
    /// same way `popHopIfReady` derives `windowStartSessionTime`. `nil` if the
    /// buffer is empty. Used by the at-stop drain (ADR-0019) to map the final
    /// buffer's segments back to absolute session time so the commit watermark
    /// can gate them — the drain doesn't go through `popHopIfReady`, so it needs
    /// this anchor directly.
    var currentWindowStartSessionTime: Double? {
        guard let first = anchors.first else { return nil }
        let firstOffsetSeconds = Double(first.offsetInWindow) / Double(sampleRate)
        return first.sessionTime - firstOffsetSeconds
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
