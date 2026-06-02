// SpeakerEnrollmentTests — coverage for the local voiceprint store + matcher
// (SpeakerStore) and the env-threshold parse/clamp (Phase 5.1, ADR-0026).
//
// These drive the PRODUCTION store directly against a temp `.speakers/` dir (no
// reimplementation, no mock) so the live enroll/auto-match path and the suite
// share one definition of "store a voiceprint / recognize a known voice." We
// never touch the real vault — each test points the store at its own temp root
// and cleans it up.
//
// Privacy note: these tests use synthetic float vectors, never real voice data.

import XCTest
import FluidAudio
@testable import Harkd

@available(macOS 14.4, *)
final class SpeakerEnrollmentTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-enroll-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    private func store(threshold: Double = SpeakerStore.defaultThreshold) -> SpeakerStore {
        SpeakerStore(threshold: threshold, vaultRoot: tempRoot)
    }

    /// A deterministic 256-dim vector: a base value on `axis`, small jitter
    /// elsewhere. Two vectors that differ only on the same axis are near-identical
    /// (cosine distance ≈ 0); orthogonal axes are far apart.
    private func vec(axis: Int, base: Float = 1.0, jitter: Float = 0.0) -> [Float] {
        var v = [Float](repeating: jitter, count: SpeakerStore.embeddingDim)
        v[axis] = base
        return v
    }

    // MARK: - enroll creates a new voiceprint

    func testEnrollCreatesNewSpeakerFile() throws {
        let s = store()
        let created = s.enroll(name: "Alice", centroid: vec(axis: 0),
                               meetingId: "m1", durationSec: 30)
        XCTAssertNotNil(created)
        XCTAssertEqual(created?.name, "Alice")
        XCTAssertEqual(created?.embeddingDim, SpeakerStore.embeddingDim)
        XCTAssertEqual(created?.embeddingSpace, SpeakerStore.embeddingSpace)
        XCTAssertEqual(created?.meetingsSeen, 1)
        XCTAssertEqual(created?.samples.count, 1)

        // Exactly one file on disk, named by uuid (not the name — no PII).
        let speakersDir = tempRoot.appendingPathComponent(".speakers", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: speakersDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertEqual(files.count, 1)
        XCTAssertFalse(files[0].lastPathComponent.lowercased().contains("alice"),
                       "filename must be a uuid, never the name")

        // loadAll round-trips it.
        let loaded = s.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "Alice")
    }

    /// The stored centroid is L2-normalized (unit magnitude) regardless of the
    /// raw input magnitude — the diarizer's centroids are NOT normalized.
    func testEnrollStoresL2NormalizedCentroid() throws {
        let s = store()
        // Raw input with magnitude 5 on one axis.
        let created = s.enroll(name: "Bob", centroid: vec(axis: 3, base: 5.0),
                               meetingId: "m1", durationSec: 30)
        let centroid = try XCTUnwrap(created?.centroid)
        let mag = centroid.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        XCTAssertEqual(mag, 1.0, accuracy: 1e-4, "stored centroid is unit length")
    }

    // MARK: - enroll merges by name + recomputes centroid

    func testEnrollMergesByNameAndRecomputesCentroid() throws {
        let s = store()
        // First meeting: voice leans on axis 0.
        _ = s.enroll(name: "Carol", centroid: vec(axis: 0, base: 1.0, jitter: 0.0),
                     meetingId: "m1", durationSec: 30)
        // Second meeting, SAME name (different case + spacing → still merges):
        // voice now leans equally on axis 1.
        let merged = s.enroll(name: "  carol ", centroid: vec(axis: 1, base: 1.0, jitter: 0.0),
                              meetingId: "m2", durationSec: 40)

        // One file, two samples, meetingsSeen incremented.
        let loaded = s.loadAll()
        XCTAssertEqual(loaded.count, 1, "same name merges, not a second file")
        XCTAssertEqual(merged?.samples.count, 2)
        XCTAssertEqual(merged?.meetingsSeen, 2)
        XCTAssertEqual(merged?.name, "Carol", "original display name preserved on merge")

        // Centroid is the normalized mean of the two unit axes — so axis 0 and
        // axis 1 should each be ~1/sqrt(2) ≈ 0.707, the rest ~0.
        let c = try XCTUnwrap(merged?.centroid)
        XCTAssertEqual(c[0], 0.7071, accuracy: 1e-3)
        XCTAssertEqual(c[1], 0.7071, accuracy: 1e-3)
        let mag = c.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        XCTAssertEqual(mag, 1.0, accuracy: 1e-4, "merged centroid stays unit length")
    }

    // MARK: - match within / beyond threshold

    func testMatchWithinThresholdReturnsName() {
        let s = store(threshold: 0.45)
        _ = s.enroll(name: "Dave", centroid: vec(axis: 5, base: 1.0),
                     meetingId: "m1", durationSec: 30)
        // A near-identical probe (same axis, scaled + tiny jitter) → distance ≈ 0.
        let m = s.match(centroid: vec(axis: 5, base: 3.0, jitter: 0.001))
        let match = unwrap(m)
        XCTAssertEqual(match?.name, "Dave")
        XCTAssertLessThanOrEqual(match?.distance ?? 99, 0.45)
        XCTAssertGreaterThan(match?.confidence ?? 0, 0.9, "near-identical → high confidence")
    }

    func testMatchBeyondThresholdReturnsNil() {
        let s = store(threshold: 0.45)
        _ = s.enroll(name: "Eve", centroid: vec(axis: 5, base: 1.0),
                     meetingId: "m1", durationSec: 30)
        // An ORTHOGONAL probe (different axis) → cosine distance ≈ 1.0 > 0.45.
        XCTAssertNil(s.match(centroid: vec(axis: 100, base: 1.0)),
                     "an orthogonal (unknown) voice must not match")
    }

    func testMatchPicksClosestEnrolledSpeaker() {
        let s = store(threshold: 0.45)
        _ = s.enroll(name: "Frank", centroid: vec(axis: 0, base: 1.0), meetingId: "m1", durationSec: 30)
        _ = s.enroll(name: "Grace", centroid: vec(axis: 1, base: 1.0), meetingId: "m1", durationSec: 30)
        // Probe nearly on axis 1 → Grace, not Frank.
        let m = unwrap(s.match(centroid: vec(axis: 1, base: 2.0, jitter: 0.001)))
        XCTAssertEqual(m?.name, "Grace")
    }

    func testMatchOnEmptyStoreReturnsNil() {
        XCTAssertNil(store().match(centroid: vec(axis: 0)), "no one enrolled → no match")
    }

    // MARK: - input validation (never enroll/match garbage)

    func testEnrollRejectsInvalidCentroid() {
        let s = store()
        XCTAssertNil(s.enroll(name: "Zoe", centroid: [], meetingId: "m1", durationSec: 30),
                     "empty vector is rejected")
        XCTAssertNil(s.enroll(name: "Zoe", centroid: [Float](repeating: 0, count: 256),
                              meetingId: "m1", durationSec: 30),
                     "zero-magnitude vector is rejected")
        XCTAssertNil(s.enroll(name: "Zoe", centroid: vec(axis: 0, base: 1.0).dropLast().map { $0 },
                              meetingId: "m1", durationSec: 30),
                     "wrong-dimension vector is rejected")
        XCTAssertNil(s.enroll(name: "   ", centroid: vec(axis: 0), meetingId: "m1", durationSec: 30),
                     "blank name is rejected")
        XCTAssertTrue(s.loadAll().isEmpty, "no garbage was written")
    }

    // MARK: - .speakers/ is gitignored the moment the store writes (rule #5)

    /// Enrolling (which creates `.speakers/`) must also create the vault
    /// `.gitignore` with the `.speakers/` rule, even when no meeting was ever
    /// saved first — the store is self-protecting, not reliant on VaultWriter
    /// having run. Drives the real `VaultWriter.ensureSpeakersGitignored`.
    func testEnrollCreatesGitignoreWhenMissing() throws {
        let gitignore = tempRoot.appendingPathComponent(".gitignore")
        XCTAssertFalse(FileManager.default.fileExists(atPath: gitignore.path),
                       "precondition: no .gitignore yet")

        _ = store().enroll(name: "Ada", centroid: vec(axis: 0),
                           meetingId: "m1", durationSec: 30)

        let contents = try String(contentsOf: gitignore, encoding: .utf8)
        let hasRule = contents.split(separator: "\n")
            .contains { $0.trimmingCharacters(in: .whitespaces) == ".speakers/" }
        XCTAssertTrue(hasRule, "the .speakers/ rule must exist after the first enroll")
    }

    /// Repeated enrolls (and a pre-existing rule) never duplicate the rule and
    /// never rewrite unrelated lines — the assert is idempotent.
    func testEnsureGitignoreIsIdempotent() throws {
        let gitignore = tempRoot.appendingPathComponent(".gitignore")
        // Pre-seed an existing .gitignore with an unrelated line + the rule.
        try Data("node_modules/\n.speakers/\n".utf8).write(to: gitignore, options: .atomic)

        let s = store()
        _ = s.enroll(name: "Bea", centroid: vec(axis: 0), meetingId: "m1", durationSec: 30)
        // A second enroll (merge) writes again → assert again.
        _ = s.enroll(name: "Bea", centroid: vec(axis: 1), meetingId: "m2", durationSec: 40)

        let lines = try String(contentsOf: gitignore, encoding: .utf8)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(lines.filter { $0 == ".speakers/" }.count, 1,
                       "the rule is present exactly once, never duplicated")
        XCTAssertTrue(lines.contains("node_modules/"),
                      "unrelated lines are preserved verbatim")
    }

    // MARK: - normalization helper

    func testL2NormalizedProducesUnitVector() {
        let n = SpeakerStore.l2Normalized([3, 4] + [Float](repeating: 0, count: 254))
        XCTAssertEqual(n[0], 0.6, accuracy: 1e-4)
        XCTAssertEqual(n[1], 0.8, accuracy: 1e-4)
    }

    func testL2NormalizedLeavesZeroVectorUnchanged() {
        let zero = [Float](repeating: 0, count: 4)
        XCTAssertEqual(SpeakerStore.l2Normalized(zero), zero)
    }

    // MARK: - env threshold parse / clamp

    func testResolveThresholdDefaultsWhenUnsetOrUnparseable() {
        XCTAssertEqual(SpeakerStore.resolveThreshold(nil, log: false), SpeakerStore.defaultThreshold)
        XCTAssertEqual(SpeakerStore.resolveThreshold("", log: false), SpeakerStore.defaultThreshold)
        XCTAssertEqual(SpeakerStore.resolveThreshold("abc", log: false), SpeakerStore.defaultThreshold)
    }

    func testResolveThresholdParsesValidValue() {
        XCTAssertEqual(SpeakerStore.resolveThreshold("0.30", log: false), 0.30, accuracy: 1e-9)
        XCTAssertEqual(SpeakerStore.resolveThreshold(" 0.6 ", log: false), 0.6, accuracy: 1e-9)
    }

    func testResolveThresholdClampsOutOfRange() {
        XCTAssertEqual(SpeakerStore.resolveThreshold("0.001", log: false),
                       SpeakerStore.minThreshold, accuracy: 1e-9, "below min clamps up")
        XCTAssertEqual(SpeakerStore.resolveThreshold("2.0", log: false),
                       SpeakerStore.maxThreshold, accuracy: 1e-9, "above max clamps down")
    }

    // MARK: - privacy gate (ADR-0027): remember_speakers off ⇒ no .speakers/ I/O

    /// The PURE gate `EngineSession` consults at BOTH voiceprint I/O sites
    /// (enroll-on-rename + post-stop auto-match). When `remember_speakers` is off
    /// it must forbid access; on, allow it. This is the same definition the live
    /// engine runs through — driving it here pins the gate's semantics.
    func testVoiceprintGateForbidsAccessWhenRememberSpeakersOff() {
        XCTAssertFalse(EngineSession.voiceprintAccessAllowed(rememberSpeakers: false),
                       "default/off ⇒ no voiceprint access")
        XCTAssertTrue(EngineSession.voiceprintAccessAllowed(rememberSpeakers: true),
                      "explicit opt-in ⇒ voiceprint access allowed")
    }

    /// End-to-end gate behavior against the REAL store: replicate the exact
    /// production guard (`guard voiceprintAccessAllowed(...) else { return }`)
    /// that fronts both `speakerStore.enroll` and `speakerStore.match`, and prove
    /// that with `remember_speakers` off NOTHING touches `.speakers/` — the store
    /// is untouched, no directory is even created. Then flip the gate on and
    /// confirm the SAME store/inputs DO write, so the test proves the gate is the
    /// only thing standing between the data and disk (not a broken store).
    func testGateOffMeansZeroSpeakersStoreIO() {
        let s = store()
        let speakersDir = tempRoot.appendingPathComponent(".speakers", isDirectory: true)
        let centroid = vec(axis: 7, base: 1.0)

        // ── Gate OFF (the default / privacy-safe path) ──
        // Mirror EngineSession.enrollFromRename's guard exactly: the gate
        // short-circuits BEFORE any store call, so enroll never runs.
        let rememberOff = false
        if EngineSession.voiceprintAccessAllowed(rememberSpeakers: rememberOff) {
            _ = s.enroll(name: "Mallory", centroid: centroid, meetingId: "m1", durationSec: 30)
            _ = s.match(centroid: centroid)
            XCTFail("gate is off — no store call should have been reached")
        }
        // The store is untouched: no voiceprint, and `.speakers/` was never even
        // created (loadAll on a missing dir returns [] without creating it).
        XCTAssertTrue(s.loadAll().isEmpty, "gate off ⇒ nothing stored")
        XCTAssertFalse(FileManager.default.fileExists(atPath: speakersDir.path),
                       "gate off ⇒ .speakers/ never created — zero store I/O")

        // ── Gate ON (explicit opt-in) ── same store, same inputs now DO write,
        // proving the gate — not a dead store — is what suppressed the I/O.
        let rememberOn = true
        if EngineSession.voiceprintAccessAllowed(rememberSpeakers: rememberOn) {
            XCTAssertNotNil(s.enroll(name: "Mallory", centroid: centroid,
                                     meetingId: "m1", durationSec: 30),
                            "gate on ⇒ enroll writes")
        } else {
            XCTFail("gate is on — the store call must be reached")
        }
        XCTAssertEqual(s.loadAll().count, 1, "gate on ⇒ exactly one voiceprint stored")
        XCTAssertNotNil(s.match(centroid: centroid), "gate on ⇒ the stored voice matches")
    }

    // MARK: - helpers

    /// XCTUnwrap can't be used in non-throwing test bodies cleanly for an
    /// optional struct; this is a tiny local unwrap that asserts + returns.
    private func unwrap(_ m: SpeakerStore.Match?, file: StaticString = #filePath, line: UInt = #line)
        -> SpeakerStore.Match? {
        XCTAssertNotNil(m, "expected a match", file: file, line: line)
        return m
    }
}
