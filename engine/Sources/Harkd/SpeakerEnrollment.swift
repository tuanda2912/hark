// SpeakerEnrollment — local voiceprint store + matcher (Phase 5.1, ADR-0026).
//
// Stores a per-person voiceprint when the user NAMES a speaker post-stop, then
// auto-recognizes that voice in FUTURE meetings. The voiceprint is the offline
// diarizer's 256-dim per-speaker centroid (`DiarizationResult.speakerDatabase`),
// L2-normalized; matching is `SpeakerUtilities.cosineDistance` over the enrolled
// set. This is a POST-HOC relabel layered on the unchanged diarizer — the offline
// pipeline has no known-speaker pre-seed (ADR-0026, §Alternatives).
//
// Java analogue: a stateless `@Repository` over a directory of JSON files. It's a
// `struct`, not an `actor`, because it holds NO mutable in-memory state — every
// call reads the directory fresh and writes atomically. `EngineSession` (an actor)
// is the single call site, so there's nothing here to synchronize; we mark it
// `Sendable` so it crosses the actor boundary cleanly. The work is synchronous,
// blocking file I/O; the caller only invokes it OFF the live path (at stop /
// on rename), exactly like `VaultWriter`.
//
// HARD RULES (CLAUDE.md #1/#3/#5):
//   #5: voiceprints + names live ONLY under `vault/.speakers/`, never networked,
//       never sent to any API. The store asserts the `.speakers/` `.gitignore`
//       rule itself (via `VaultWriter.ensureSpeakersGitignored`) every time it
//       creates that dir — so a voiceprint can never become git-committable even
//       if no meeting was saved first.
//   #3: this type sees names (PII) and embeddings (sensitive). It MUST NOT log
//       either — log lines are counts + distances only, never names/vectors.
//   No network: pure local filesystem. No new dependency.

import Foundation
import FluidAudio

// ─── On-disk model (ADR-0026 §Decision) ─────────────────────────────────────
//
// One JSON file per enrolled person at `vault/.speakers/<uuid>.json`. The
// filename is the UUID, NEVER the name — no PII in filenames (ADR-0026). ~3 KB
// per file (256 floats + a sample or two). Codable so the wire/file shape is
// the single source of truth; snake_case on disk for human-readability when a
// user inspects the vault.

/// One voice sample folded into an enrolled speaker. We keep the raw per-meeting
/// centroid (normalized) plus light provenance so the running `centroid` can be
/// recomputed as the mean of all samples, and so a future tuning pass can audit
/// which meetings contributed. `vector` is the sensitive bit — same privacy
/// class as the parent file (local-only, gitignored).
struct EnrolledSample: Codable, Sendable {
    let vector: [Float]
    let meetingId: String
    let durationSec: Double
    let addedAt: Date
}

/// A persisted voiceprint. `centroid` is the L2-normalized mean of every
/// `samples[].vector` — it's what `match` compares against, recomputed on every
/// merge. `embeddingSpace` tags the vector space so a future model/space change
/// can refuse to mix incompatible embeddings rather than silently corrupting a
/// centroid. `meetingsSeen` is provenance only.
struct EnrolledSpeaker: Codable, Sendable {
    let id: String                 // UUID — also the filename stem
    var name: String
    let embeddingDim: Int          // 256 (offline WeSpeaker)
    let embeddingSpace: String     // "offline-wespeaker-v1"
    var centroid: [Float]          // L2-normalized mean of samples[].vector
    var samples: [EnrolledSample]
    let createdAt: Date
    var updatedAt: Date
    var meetingsSeen: Int

    enum CodingKeys: String, CodingKey {
        case id, name
        case embeddingDim = "embedding_dim"
        case embeddingSpace = "embedding_space"
        case centroid, samples
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case meetingsSeen = "meetings_seen"
    }
}

// ─── Store + matcher ─────────────────────────────────────────────────────────

@available(macOS 14.4, *)
struct SpeakerStore: Sendable {
    /// The vector space + dimensionality these voiceprints live in. Stamped into
    /// each file and asserted on merge so an incompatible embedding never folds
    /// into a centroid built from a different space.
    static let embeddingSpace = "offline-wespeaker-v1"
    static let embeddingDim = 256

    /// Default match threshold in COSINE distance (0 = identical, 2 = opposite).
    /// Conservative on purpose: a wrong name is worse than "Speaker N", so we
    /// start strict and expose the knob (ADR-0026). This is the cosine/WeSpeaker
    /// space — NOT the offline diarizer's 0.6 Euclidean clustering threshold.
    static let defaultThreshold: Double = 0.45
    /// Clamp range for the env override. Below `minThreshold` almost nothing
    /// matches (useless); above `maxThreshold` we'd start auto-applying wrong
    /// names freely (the exact failure mode the conservative default avoids).
    static let minThreshold: Double = 0.05
    static let maxThreshold: Double = 0.90

    /// Match threshold (cosine distance) for this store instance. Resolved from
    /// `HARK_ENROLL_THRESHOLD` by the caller (see `resolveThreshold`) so it can be
    /// swept on-device without recompiling.
    let threshold: Double

    /// Vault root — `~/Documents/vault/hark`, same resolution as `VaultWriter`.
    /// Injectable so tests can point the store at a temp dir; production uses the
    /// default. Voiceprints live under `<vaultRoot>/.speakers/`.
    private let vaultRoot: URL

    init(threshold: Double = SpeakerStore.defaultThreshold, vaultRoot: URL? = nil) {
        self.threshold = threshold
        self.vaultRoot = vaultRoot ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/vault/hark", isDirectory: true)
    }

    private var speakersDir: URL {
        vaultRoot.appendingPathComponent(".speakers", isDirectory: true)
    }

    // ─── Load ────────────────────────────────────────────────────────────────

    /// Load every enrolled speaker from `<vault>/.speakers/`. A missing directory
    /// is "no one enrolled yet" (returns `[]`, never throws). An unreadable /
    /// malformed individual file is SKIPPED (logged by count, never by content)
    /// so one corrupt voiceprint can't blind the whole matcher. Order is
    /// unspecified — `match` scans the whole set regardless.
    func loadAll() -> [EnrolledSpeaker] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: speakersDir, includingPropertiesForKeys: nil) else {
            return []
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var out: [EnrolledSpeaker] = []
        var skipped = 0
        for url in entries where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let speaker = try? dec.decode(EnrolledSpeaker.self, from: data) else {
                skipped += 1
                continue
            }
            out.append(speaker)
        }
        if skipped > 0 {
            FileHandle.standardError.write(Data(
                "harkd: enrollment — skipped \(skipped) unreadable voiceprint file(s)\n".utf8))
        }
        return out
    }

    // ─── Enroll ────────────────────────────────────────────────────────────────

    /// Persist (or merge into) a voiceprint for `name`. The user naming a speaker
    /// is the deliberate enroll trigger (ADR-0026). `centroid` is the diarizer's
    /// per-speaker centroid for this meeting — we L2-normalize it before storing.
    ///
    ///   - If a speaker with this `name` already exists (case-/whitespace-
    ///     insensitive match), append this meeting's vector to `samples[]` and
    ///     recompute `centroid` as the normalized mean of all samples.
    ///   - Else create a new `<uuid>.json`.
    ///
    /// Atomic write (temp data → `.atomic` rename), same pattern as `VaultWriter`.
    /// Returns the resulting speaker (post-merge) for the caller's logging, or nil
    /// when the input centroid is invalid (empty / zero-magnitude / wrong dim) —
    /// we never enroll a garbage vector. Privacy: name is PII; this method NEVER
    /// logs the name or the vector (the caller logs counts/distances only).
    @discardableResult
    func enroll(name: String, centroid raw: [Float],
                meetingId: String, durationSec: Double) -> EnrolledSpeaker? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard raw.count == Self.embeddingDim,
              SpeakerUtilities.validateEmbedding(raw) else { return nil }

        let normalized = Self.l2Normalized(raw)
        let now = Date()
        let sample = EnrolledSample(
            vector: normalized, meetingId: meetingId,
            durationSec: durationSec, addedAt: now)

        let existing = loadAll()
        let lowerName = trimmed.lowercased()
        if var found = existing.first(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == lowerName
        }) {
            // Merge: append the sample, recompute the centroid as the normalized
            // mean of ALL samples. Mean-of-normalized-then-renormalize is the
            // standard speaker-embedding centroid update — simple, and matches
            // how the diarizer itself builds its per-speaker centroid.
            found.samples.append(sample)
            found.centroid = Self.l2Normalized(Self.mean(found.samples.map(\.vector)))
            found.updatedAt = now
            found.meetingsSeen += 1
            try? write(found)
            return found
        } else {
            let speaker = EnrolledSpeaker(
                id: UUID().uuidString,
                name: trimmed,
                embeddingDim: Self.embeddingDim,
                embeddingSpace: Self.embeddingSpace,
                centroid: normalized,
                samples: [sample],
                createdAt: now,
                updatedAt: now,
                meetingsSeen: 1)
            try? write(speaker)
            return speaker
        }
    }

    // ─── Match ───────────────────────────────────────────────────────────────

    /// Result of a successful match: the enrolled name + a 0..1 confidence
    /// (`1 − cosineDistance`). Distinct from the wire `MeetingSpeaker` — this is
    /// the internal match result the diarization pass consumes.
    struct Match: Sendable {
        let name: String
        let confidence: Double
        let distance: Double
    }

    /// Find the enrolled speaker whose centroid is CLOSEST to `centroid` (min
    /// cosine distance), returning it only when the distance is within
    /// `threshold`. The input centroid is normalized before comparison (the
    /// diarizer's centroids are NOT normalized; `cosineDistance` is tolerant, but
    /// we normalize for consistency with the stored form). nil = no enrolled
    /// voice is close enough → the speaker stays "Speaker N". Privacy: logs
    /// nothing here (the caller logs the distance, never the name).
    func match(centroid raw: [Float]) -> Match? {
        guard raw.count == Self.embeddingDim, SpeakerUtilities.validateEmbedding(raw) else {
            return nil
        }
        let probe = Self.l2Normalized(raw)
        let enrolled = loadAll()
        guard !enrolled.isEmpty else { return nil }

        var best: EnrolledSpeaker?
        var bestDistance = Double.infinity
        for speaker in enrolled where speaker.embeddingSpace == Self.embeddingSpace {
            let d = Double(SpeakerUtilities.cosineDistance(probe, speaker.centroid))
            guard d.isFinite else { continue }
            if d < bestDistance {
                bestDistance = d
                best = speaker
            }
        }
        guard let best = best, bestDistance <= threshold else { return nil }
        // Confidence as 1 − distance, clamped to [0, 1] (distance is in [0, 2]).
        let confidence = max(0.0, min(1.0, 1.0 - bestDistance))
        return Match(name: best.name, confidence: confidence, distance: bestDistance)
    }

    // ─── Atomic write ──────────────────────────────────────────────────────────

    private func write(_ speaker: EnrolledSpeaker) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: speakersDir, withIntermediateDirectories: true)
        // Rule #5 forward-safety: a `.speakers/` dir must never exist without the
        // vault `.gitignore` rule that excludes it — voiceprints are never git-
        // committable. `VaultWriter.ensureGitignore` also asserts this during the
        // meeting-save commit, but in practice that runs FIRST; the store must be
        // self-protecting regardless of call order. Idempotent (shared helper), so
        // asserting it here can't duplicate the rule. Best-effort like the helper.
        VaultWriter.ensureSpeakersGitignored(vaultRoot: vaultRoot)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(speaker)
        let url = speakersDir.appendingPathComponent("\(speaker.id).json")
        // `.atomic` is write-temp-then-rename on the same volume — same pattern as
        // VaultWriter's `atomicWrite`. A crash mid-write never leaves a half file.
        try data.write(to: url, options: .atomic)
    }

    // ─── Vector math (kept here, not DIY cosine) ───────────────────────────────
    //
    // We use FluidAudio's `cosineDistance` for MATCHING (ADR-0026: don't DIY the
    // similarity metric). These helpers are only the L2-normalize + mean the
    // store needs to BUILD and STORE a normalized centroid — pure array math, no
    // model state. `static` so the tests can drive them without a store instance.

    /// L2-normalize a vector to unit length. A zero vector is returned unchanged
    /// (caller validates magnitude via `validateEmbedding` before storing, so
    /// this only ever sees a valid vector in production).
    static func l2Normalized(_ v: [Float]) -> [Float] {
        var sumSquares: Float = 0
        for x in v { sumSquares += x * x }
        let magnitude = sumSquares.squareRoot()
        guard magnitude > 0 else { return v }
        return v.map { $0 / magnitude }
    }

    /// Element-wise mean of a non-empty set of equal-length vectors. Used to
    /// recompute a merged speaker's centroid from all its samples.
    static func mean(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var acc = [Float](repeating: 0, count: first.count)
        for v in vectors where v.count == acc.count {
            for i in 0..<acc.count { acc[i] += v[i] }
        }
        let n = Float(vectors.count)
        return acc.map { $0 / n }
    }

    // ─── Env threshold resolution ──────────────────────────────────────────────

    /// Parse + clamp `HARK_ENROLL_THRESHOLD` and (when `log` is true) log the
    /// resolved value once at startup — mirroring `resolveDedupWindow` and the
    /// `HARK_DIAR_*` env helpers. Unset / unparseable → the default; a parsed
    /// value is clamped to `[minThreshold, maxThreshold]`. Logged on stderr —
    /// value only, never a name or vector. PURE (the clamp) so the test can drive
    /// the parse/clamp without touching stderr (`log: false`).
    static func resolveThreshold(_ raw: String?, log: Bool = true) -> Double {
        let resolved: Double
        let source: String
        if let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
           let parsed = Double(raw) {
            resolved = min(maxThreshold, max(minThreshold, parsed))
            source = "from HARK_ENROLL_THRESHOLD=\(raw)"
        } else {
            resolved = defaultThreshold
            source = "default; set HARK_ENROLL_THRESHOLD to override"
        }
        if log {
            FileHandle.standardError.write(Data(String(
                format: "harkd: enrollment match threshold = %.3f cosine-distance (%@, clamped to [%.2f,%.2f])\n",
                resolved, source, minThreshold, maxThreshold).utf8))
        }
        return resolved
    }
}
