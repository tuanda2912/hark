// AudioStore — opt-in meeting-audio persistence to the vault (slice B, ADR-0027).
//
// Writes the full-meeting 16 kHz mono PCM (already buffered in RAM for the
// post-stop diarization pass) to `<vaultRoot>/.audio/<meeting-id>.wav` — but
// ONLY when the session opted in via `keep_audio`. When off (the default), this
// performs ZERO `.audio/` I/O: no directory, no file (ADR-0027, the load-bearing
// privacy gate).
//
// Java analogue: a stateless `@Repository` that writes one file per meeting. Like
// `SpeakerStore` it's a `struct`, not an `actor`, because it holds NO mutable
// in-memory state — the vault root is injected, every call writes atomically. The
// single call site is `EngineSession` (an actor), which serializes it, and only
// invokes it OFF the live path (at stop, after the markdown write), exactly like
// `VaultWriter` and `SpeakerStore`. We mark it `Sendable` so it crosses the actor
// boundary cleanly.
//
// HARD RULES (CLAUDE.md #2, ADR-0027):
//   #2: audio is PII; it lives ONLY under `vault/.audio/`, never elsewhere, never
//       networked. `.audio/` sits PARALLEL to `.speakers/` at the vault root —
//       NOT inside `meetings/`, whose `.md` files are git-tracked. The store
//       asserts the `.audio/` `.gitignore` rule itself (via
//       `VaultWriter.ensureAudioGitignored`) the moment it creates that dir, so
//       meeting audio can never become git-committable even if no meeting `.md`
//       was committed first.
//   #3: this type sees audio (sensitive). It MUST NOT log content — log lines are
//       a sample count + duration + the meeting id only (the id is the same
//       basename as the already-written, git-tracked `.md`, so it leaks nothing
//       beyond the meeting itself).
//   No network: pure local filesystem. Reuses HarkCore.WAVWriter — no new dep.

import Foundation
import HarkCore

@available(macOS 14.4, *)
struct AudioStore: Sendable {
    /// Vault root — `~/Documents/vault/hark`, same resolution as `VaultWriter` /
    /// `SpeakerStore`. Injectable so tests point the store at a temp dir; the
    /// `.audio/` folder lives under `<vaultRoot>/.audio/`, parallel to `.speakers/`.
    private let vaultRoot: URL

    init(vaultRoot: URL? = nil) {
        self.vaultRoot = vaultRoot ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/vault/hark", isDirectory: true)
    }

    private var audioDir: URL {
        vaultRoot.appendingPathComponent(".audio", isDirectory: true)
    }

    /// Persist the full-meeting audio to `<vaultRoot>/.audio/<meetingId>.wav`,
    /// gated on `keepAudio`. Returns the ABSOLUTE path written, or nil when the
    /// gate is off / there's nothing to write / the write fails.
    ///
    /// `meetingId` MUST be the SAME basename as the meeting's markdown file (the
    /// VaultWriter result's filename stem), so the `.wav` and `.md` correlate
    /// (e.g. `2026-06-02-1436.wav` ↔ `2026-06-02-1436.md`).
    ///
    /// `samples` is the continuous 16 kHz mono Float buffer the diarization pass
    /// uses (`-1..1`); we convert to Int16 LE here with the same `*32767` + clamp
    /// the capture Mixer uses. Atomic: written to a temp `.wav` then renamed into
    /// place, so a crash mid-write never leaves a half file in `.audio/`. Best-
    /// effort like the other vault writers — a failure logs (count only) and
    /// returns nil; it never throws into the stop lifecycle. Privacy: logs a
    /// count + duration + the meeting id, never audio content (rule #3).
    func persist(meetingId: String, samples: [Float], keepAudio: Bool) -> URL? {
        // PRIVACY GATE (ADR-0027): no audio is EVER written when the session opted
        // out. Returning here before touching the filesystem means ZERO `.audio/`
        // I/O — no directory, no temp file (mirrors `enrollFromRename`'s gate).
        guard Self.audioPersistenceAllowed(keepAudio: keepAudio) else { return nil }
        guard !samples.isEmpty else { return nil }

        let fm = FileManager.default
        let finalURL = audioDir.appendingPathComponent("\(meetingId).wav")
        // Write to a unique temp name in the SAME dir, then rename — rename is
        // atomic on the same volume, so `<meetingId>.wav` only ever appears whole.
        let tempURL = audioDir.appendingPathComponent(".\(meetingId).\(UUID().uuidString).wav.tmp")
        do {
            try fm.createDirectory(at: audioDir, withIntermediateDirectories: true)
            // Rule #2 forward-safety: a `.audio/` dir must never exist without the
            // vault `.gitignore` rule that excludes it. Idempotent (shared helper),
            // so asserting it here can't duplicate the rule. Best-effort.
            VaultWriter.ensureAudioGitignored(vaultRoot: vaultRoot)

            let writer = try WAVWriter(url: tempURL)
            // WAVWriter wants Int16 16 kHz mono; convert from the Float buffer with
            // the capture Mixer's `*32767` + clamp (it never re-soft-clips — the
            // mixed Float stream is already tanh-limited to ±1).
            try writer.append(Self.floatToInt16(samples))
            try writer.close()

            // Replace any prior file atomically. `replaceItemAt` falls back to a
            // plain rename when nothing's there; both are atomic on one volume.
            if fm.fileExists(atPath: finalURL.path) {
                _ = try fm.replaceItemAt(finalURL, withItemAt: tempURL)
            } else {
                try fm.moveItem(at: tempURL, to: finalURL)
            }
        } catch {
            try? fm.removeItem(at: tempURL)
            FileHandle.standardError.write(Data(
                "harkd: audio persist failed (\(type(of: error))); meeting audio not saved\n".utf8))
            return nil
        }

        let durationSec = Double(samples.count) / 16_000.0
        FileHandle.standardError.write(Data(String(
            format: "harkd: meeting audio saved — %@.wav  (samples=%d  duration=%.1fs)\n",
            meetingId, samples.count, durationSec).utf8))
        return finalURL
    }

    // ─── Pure privacy gate (ADR-0027) ──────────────────────────────────────────

    /// PURE privacy gate (ADR-0027): may the engine persist meeting audio this
    /// session? The audio-persist path consults this — when it returns false there
    /// is ZERO `.audio/` I/O. Kept trivial + pure (no state, no I/O) so the test
    /// asserts the gate against the SAME definition production runs, mirroring
    /// `EngineSession.voiceprintAccessAllowed`.
    static func audioPersistenceAllowed(keepAudio: Bool) -> Bool {
        keepAudio
    }

    // ─── Float → Int16 conversion (shared convention) ──────────────────────────

    /// Convert a `-1..1` Float buffer to Int16 LE PCM, the same `*32767` + clamp
    /// the capture `Mixer` uses. The mixed Float stream is already tanh soft-
    /// limited to ±1, so we don't re-limit — just scale + clamp the rare overshoot.
    /// `static` + pure so the test can drive it without a store instance.
    static func floatToInt16(_ samples: [Float]) -> [Int16] {
        var out = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let scaled = samples[i] * 32_767
            out[i] = Int16(max(-32_768, min(32_767, scaled)))
        }
        return out
    }
}
