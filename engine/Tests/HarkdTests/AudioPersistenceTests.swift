// AudioPersistenceTests — coverage for opt-in meeting-audio persistence
// (AudioStore) and the `keep_audio` privacy gate (slice B, ADR-0027).
//
// These drive the PRODUCTION store directly against a temp `.audio/` dir (no
// reimplementation, no mock) so the live persist path and the suite share one
// definition of "write the meeting audio / write nothing." We never touch the
// real vault — each test points the store at its own temp root and cleans up.
//
// The adversarial gate-off test mirrors SpeakerEnrollmentTests'
// `testGateOffMeansZeroSpeakersStoreIO`: prove that with `keep_audio` off NOTHING
// touches `.audio/` (no dir, no file, audioPath nil), then flip it on with the
// SAME store/inputs to prove the gate — not a dead store — is what suppressed it.
//
// Privacy note: these tests use a synthetic float tone, never real audio.

import XCTest
@testable import Harkd

@available(macOS 14.4, *)
final class AudioPersistenceTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-audio-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    private func store() -> AudioStore { AudioStore(vaultRoot: tempRoot) }

    private var audioDir: URL { tempRoot.appendingPathComponent(".audio", isDirectory: true) }
    private var gitignore: URL { tempRoot.appendingPathComponent(".gitignore") }

    /// A deterministic non-silent buffer: a low-amplitude sine so the conversion
    /// produces a mix of positive/negative Int16 samples (a real waveform, not a
    /// DC block). `seconds` × 16 kHz samples.
    private func tone(seconds: Double, freq: Double = 440) -> [Float] {
        let n = Int(seconds * 16_000)
        return (0..<n).map { i in
            Float(0.5 * sin(2 * Double.pi * freq * Double(i) / 16_000))
        }
    }

    // MARK: - gate OFF ⇒ zero .audio/ I/O (the adversarial, privacy-critical case)

    /// `keep_audio == false` (the default): NOTHING is written. No `.audio/`
    /// directory is created, no file lands, and the returned path is nil — proving
    /// the gate short-circuits before any filesystem touch. Then flip the gate on
    /// with the SAME store + samples to prove the gate, not a broken store, is what
    /// suppressed the I/O. This is the load-bearing privacy guarantee (ADR-0027).
    func testGateOffMeansZeroAudioIO() {
        let s = store()
        let samples = tone(seconds: 2)

        // ── Gate OFF (default / privacy-safe) ──
        XCTAssertFalse(AudioStore.audioPersistenceAllowed(keepAudio: false),
                       "default/off ⇒ no audio persistence")
        let off = s.persist(meetingId: "2026-06-02-1436", samples: samples, keepAudio: false)
        XCTAssertNil(off, "gate off ⇒ persist returns nil (audioPath would be nil)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioDir.path),
                       "gate off ⇒ .audio/ never created — zero store I/O")

        // ── Gate ON (explicit opt-in) ── same store + samples now DO write,
        // proving the gate — not a dead store — suppressed the I/O above.
        XCTAssertTrue(AudioStore.audioPersistenceAllowed(keepAudio: true),
                      "explicit opt-in ⇒ audio persistence allowed")
        let on = s.persist(meetingId: "2026-06-02-1436", samples: samples, keepAudio: true)
        XCTAssertNotNil(on, "gate on ⇒ persist writes and returns the path")
    }

    /// Gate on but nothing captured: an empty buffer writes nothing and returns nil
    /// (no zero-byte WAV in `.audio/`). Distinct from the gate being off.
    func testEmptyAudioWritesNothingEvenWhenGateOn() {
        let s = store()
        let result = s.persist(meetingId: "2026-06-02-1436", samples: [], keepAudio: true)
        XCTAssertNil(result, "empty audio ⇒ nothing written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioDir.path),
                       "empty audio ⇒ .audio/ not created")
    }

    // MARK: - gate ON ⇒ valid WAV at <vault>/.audio/<id>.wav

    /// `keep_audio == true`: the `.wav` lands at `<vault>/.audio/<id>.wav`, the
    /// returned path matches, and the file is a valid 16 kHz mono s16le WAV with a
    /// correct RIFF header and a non-empty data chunk sized to the sample count.
    func testGateOnWritesValidWavAtExpectedPath() throws {
        let s = store()
        let meetingId = "2026-06-02-1436"        // same basename shape as the .md
        let samples = tone(seconds: 2)

        let written = try XCTUnwrap(s.persist(meetingId: meetingId, samples: samples, keepAudio: true))

        // Path: <vault>/.audio/<id>.wav, parallel to .speakers/, NOT under meetings/.
        let expected = audioDir.appendingPathComponent("\(meetingId).wav")
        XCTAssertEqual(written.path, expected.path,
                       "returned path is <vault>/.audio/<id>.wav")
        XCTAssertTrue(written.path.contains("/.audio/"), "audio lives in the hidden .audio/ dir")
        XCTAssertFalse(written.path.contains("/meetings/"), "audio must NOT live under meetings/")
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))

        // No temp/leftover files in .audio/ — only the final .wav.
        let entries = try FileManager.default.contentsOfDirectory(
            at: audioDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(entries.map(\.lastPathComponent), ["\(meetingId).wav"],
                       "only the final .wav remains; the temp file was renamed away")

        // Valid WAV: RIFF/WAVE/fmt /data magic, 16 kHz mono 16-bit, non-empty data
        // sized to the sample count (Int16 = 2 bytes/sample).
        let data = try Data(contentsOf: written)
        XCTAssertGreaterThan(data.count, 44, "header + non-empty data")
        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: data[12..<16], encoding: .ascii), "fmt ")
        XCTAssertEqual(String(data: data[36..<40], encoding: .ascii), "data")

        let channels = data[22..<24].withUnsafeBytes { $0.load(as: UInt16.self) }
        let sampleRate = data[24..<28].withUnsafeBytes { $0.load(as: UInt32.self) }
        let bits = data[34..<36].withUnsafeBytes { $0.load(as: UInt16.self) }
        let dataSize = data[40..<44].withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(channels, 1, "mono")
        XCTAssertEqual(sampleRate, 16_000, "16 kHz")
        XCTAssertEqual(bits, 16, "signed 16-bit")
        XCTAssertEqual(Int(dataSize), samples.count * 2, "data chunk sized to the sample count")
        XCTAssertGreaterThan(Int(dataSize), 0, "non-empty audio data")
    }

    /// Writing for a meeting id whose `.wav` already exists overwrites it
    /// atomically (no second file, no leftover temp) — mirrors the markdown
    /// writer's in-place semantics for the meeting's OWN file.
    func testRepersistOverwritesSameMeetingFile() throws {
        let s = store()
        let id = "2026-06-02-1436"
        _ = try XCTUnwrap(s.persist(meetingId: id, samples: tone(seconds: 1), keepAudio: true))
        let second = try XCTUnwrap(s.persist(meetingId: id, samples: tone(seconds: 2), keepAudio: true))

        let entries = try FileManager.default.contentsOfDirectory(
            at: audioDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(entries.count, 1, "still exactly one file — overwritten in place")
        // The second (longer) write is the one on disk.
        let data = try Data(contentsOf: second)
        let dataSize = data[40..<44].withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(Int(dataSize), 2 * 16_000 * 2, "the latest write replaced the file")
    }

    // MARK: - .audio/ is gitignored the moment we write (ADR-0027 / rule #2)

    /// Persisting (which creates `.audio/`) must also create the vault `.gitignore`
    /// with the `.audio/` rule, even when no meeting `.md` was ever committed —
    /// the store is self-protecting. Drives the real `VaultWriter.ensureAudioGitignored`.
    func testPersistCreatesGitignoreWhenMissing() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: gitignore.path),
                       "precondition: no .gitignore yet")

        _ = store().persist(meetingId: "2026-06-02-1436", samples: tone(seconds: 1), keepAudio: true)

        let contents = try String(contentsOf: gitignore, encoding: .utf8)
        let hasRule = contents.split(separator: "\n")
            .contains { $0.trimmingCharacters(in: .whitespaces) == ".audio/" }
        XCTAssertTrue(hasRule, "the .audio/ rule must exist after the first persist")
    }

    /// Repeated persists (and a pre-existing rule, alongside `.speakers/`) never
    /// duplicate the `.audio/` rule and never rewrite unrelated lines — idempotent.
    func testEnsureAudioGitignoreIsIdempotent() throws {
        // Pre-seed with an unrelated line, the .speakers/ rule, and the .audio/ rule.
        try Data("node_modules/\n.speakers/\n.audio/\n".utf8).write(to: gitignore, options: .atomic)

        let s = store()
        _ = s.persist(meetingId: "2026-06-02-1436", samples: tone(seconds: 1), keepAudio: true)
        _ = s.persist(meetingId: "2026-06-02-1437", samples: tone(seconds: 1), keepAudio: true)

        let lines = try String(contentsOf: gitignore, encoding: .utf8)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(lines.filter { $0 == ".audio/" }.count, 1,
                       "the .audio/ rule is present exactly once, never duplicated")
        XCTAssertEqual(lines.filter { $0 == ".speakers/" }.count, 1,
                       ".speakers/ rule untouched (not duplicated, not removed)")
        XCTAssertTrue(lines.contains("node_modules/"),
                      "unrelated lines are preserved verbatim")
    }

    /// `ensureAudioGitignored` appends `.audio/` to an existing `.gitignore` that
    /// only had `.speakers/`, leaving the existing rule intact — proving the two
    /// self-assertions coexist without clobbering each other.
    func testAudioRuleAppendsAlongsideExistingSpeakersRule() throws {
        VaultWriter.ensureSpeakersGitignored(vaultRoot: tempRoot)
        VaultWriter.ensureAudioGitignored(vaultRoot: tempRoot)

        let lines = try String(contentsOf: gitignore, encoding: .utf8)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertTrue(lines.contains(".speakers/"), ".speakers/ rule survives")
        XCTAssertTrue(lines.contains(".audio/"), ".audio/ rule added")
    }

    // MARK: - Float → Int16 conversion + wire shape

    /// The Float→Int16 conversion scales by 32767 and clamps overshoot, matching
    /// the capture Mixer's convention.
    func testFloatToInt16ScalesAndClamps() {
        let out = AudioStore.floatToInt16([0.0, 1.0, -1.0, 2.0, -2.0, 0.5])
        XCTAssertEqual(out[0], 0)
        XCTAssertEqual(out[1], 32_767)
        XCTAssertEqual(out[2], -32_767)
        XCTAssertEqual(out[3], 32_767, "overshoot clamps to max")
        XCTAssertEqual(out[4], -32_768, "overshoot clamps to min")
        XCTAssertEqual(out[5], 16_383, "0.5 * 32767 truncates toward zero")
    }

    /// `meeting.saved` encodes `audio_path` as a string when set and as explicit
    /// JSON `null` when nil — analogous to `vault_path`, the wire shape slice B
    /// produced. (UI mirrors this on the TS side.)
    func testMeetingSavedEncodesAudioPathSnakeCaseAndNull() throws {
        let withAudio = MeetingSavedPayload(
            sessionId: "sess-1",
            vaultPath: "/v/meetings/2026-06-02-1436.md",
            audioPath: "/v/.audio/2026-06-02-1436.wav",
            speakers: [],
            stats: MeetingStats(segments: 1, durationSec: 1, rtfAvg: 0.3))
        let jsonWith = String(decoding: try encodeWireMessage(
            WireEnvelope(type: "meeting.saved", payload: withAudio)), as: UTF8.self)
        XCTAssertTrue(jsonWith.contains("\"audio_path\":\"/v/.audio/2026-06-02-1436.wav\""),
                      "audio_path is snake_case and carries the absolute path")
        XCTAssertTrue(jsonWith.contains("\"vault_path\":\"/v/meetings/2026-06-02-1436.md\""))

        let noAudio = MeetingSavedPayload(
            sessionId: "sess-1",
            vaultPath: "/v/meetings/2026-06-02-1436.md",
            audioPath: nil,
            speakers: [],
            stats: MeetingStats(segments: 1, durationSec: 1, rtfAvg: 0.3))
        let jsonNil = String(decoding: try encodeWireMessage(
            WireEnvelope(type: "meeting.saved", payload: noAudio)), as: UTF8.self)
        XCTAssertTrue(jsonNil.contains("\"audio_path\":null"),
                      "nil audioPath encodes as explicit JSON null, not a dropped key")
    }
}
