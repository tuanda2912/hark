// WireProtocol — JSON envelope + payload Codables for the WebSocket API.
//
// Contract source-of-truth: vault/docs/design/08-websocket-api-contract.md
//
// Envelope shape every message must carry:
//   { "v": 1, "id": "uuid-or-null", "type": "ns.action",
//     "ts": "ISO-8601-with-ms", "payload": { ... } }
//
// Java analogue: think of each Codable struct as a `@JsonInclude` POJO that
// JSONEncoder serializes by walking properties. snake_case wire form is
// produced by the encoder's keyEncodingStrategy at the call site — keep
// property names camelCase here (Swift idiom).
//
// Privacy: nothing in this file logs payload content. The envelope helpers
// are pure value-to-bytes transforms.

import Foundation

/// Wire protocol version. Bumped on breaking change. UI hard-fails on mismatch.
let WIRE_PROTOCOL_VERSION = 1

/// Engine semantic version. Surfaced in `meta.hello.engine_version` and in
/// the port file. Bumped manually until we wire a build-tag pipeline.
let HARKD_ENGINE_VERSION = "0.1.0"

// ─── ISO 8601 timestamp helper ────────────────────────────────────────────
//
// The contract demands milliseconds. ISO8601DateFormatter doesn't include
// fractional seconds by default; we format manually with a fixed format
// so the wire timestamp is stable.

private let wireTSFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    return f
}()

func wireTimestamp(_ date: Date = Date()) -> String {
    wireTSFormatter.string(from: date)
}

// ─── Envelope ─────────────────────────────────────────────────────────────
//
// Generic over the payload type so encoder synthesis works statically. The
// `id` field is the correlation ID for request/response — present on UI
// commands and on the engine's ack/error responses; null on unsolicited
// events.

struct WireEnvelope<Payload: Encodable>: Encodable {
    let v: Int
    let id: String?
    let type: String
    let ts: String
    let payload: Payload

    init(type: String, payload: Payload, id: String? = nil, ts: String = wireTimestamp()) {
        self.v = WIRE_PROTOCOL_VERSION
        self.id = id
        self.type = type
        self.ts = ts
        self.payload = payload
    }
}

/// Encodes an envelope to JSON bytes with the wire's snake_case key form.
/// `withoutEscapingSlashes` avoids "\/" in paths.
func encodeWireMessage<Payload: Encodable>(_ envelope: WireEnvelope<Payload>) throws -> Data {
    let enc = JSONEncoder()
    enc.outputFormatting = [.withoutEscapingSlashes]
    enc.keyEncodingStrategy = .convertToSnakeCase
    return try enc.encode(envelope)
}

// ─── UI → Engine command decoding ─────────────────────────────────────────
//
// Commands arrive as JSON. We peek at the envelope to dispatch on `type`,
// then decode the typed payload. Done in two passes because Swift's
// `Decodable` requires a static type — we don't know which payload to
// decode until we read `type`.

struct InboundEnvelopeHeader: Decodable {
    let v: Int?
    let id: String?
    let type: String
    // payload decoded separately
}

/// Pulls the `payload` field as a typed value. Throws if the type doesn't
/// match the JSON shape — caller maps that to a `protocol_mismatch` error.
struct InboundPayload<T: Decodable>: Decodable {
    let payload: T
}

func decodeInbound<T: Decodable>(_ data: Data, payloadType: T.Type) throws -> T {
    let dec = JSONDecoder()
    dec.keyDecodingStrategy = .convertFromSnakeCase
    return try dec.decode(InboundPayload<T>.self, from: data).payload
}

func decodeHeader(_ data: Data) throws -> InboundEnvelopeHeader {
    let dec = JSONDecoder()
    dec.keyDecodingStrategy = .convertFromSnakeCase
    return try dec.decode(InboundEnvelopeHeader.self, from: data)
}

// ─── Engine → UI payloads ────────────────────────────────────────────────

struct EmptyPayload: Encodable {}

struct MetaHelloPayload: Encodable {
    let engineVersion: String
    let protocolVersion: Int
    let modelLoaded: String
    let capabilities: [String]
}

/// Pushed unsolicited the moment the model finishes loading (attachModel),
/// so the UI can drop its "warming up" state without polling capture.start.
/// `modelLoaded` snake_cases to `model_loaded` via the outbound encoder's
/// `.convertToSnakeCase` strategy — same as `MetaHelloPayload.modelLoaded`.
struct MetaReadyPayload: Encodable {
    let modelLoaded: String
}

/// First-run model-load progress (engine→UI event, type `meta.model_progress`).
/// On a fresh install the WhisperKit (~626 MB) + diarizer CoreML bundles
/// download and ANE-compile during warm-up — without this the UI looks hung.
/// Emitted purely additively; `meta.ready` stays the terminal readiness signal.
///
/// `phase` is one of the four literal values below. It's a VALUE, not a key, so
/// `.convertToSnakeCase` leaves it alone — we keep the snake_case form literal.
///
/// `fraction` is nil during the ANE compile/specialize step (WhisperKit's
/// load/prewarm exposes no progress API) — we encode that as JSON `null`, not a
/// dropped key, so the UI can distinguish "indeterminate" from "absent" and show
/// a spinner instead of a bar. Same explicit-`encodeNil` pattern `SegmentPayload`
/// uses, required because `.convertToSnakeCase` keeps optionals' keys but the
/// synthesized `encode(to:)` would omit a nil value entirely.
struct MetaModelProgressPayload: Encodable {
    /// "downloading_speech" | "optimizing_speech" | "downloading_diarizer" | "optimizing_diarizer"
    let phase: String
    /// 0..1, or nil when indeterminate (ANE compile). Encodes as JSON `null`.
    let fraction: Double?
    /// Human label, e.g. "Downloading speech model".
    let detail: String

    enum CodingKeys: String, CodingKey {
        case phase, fraction, detail
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(phase, forKey: .phase)
        if let v = fraction { try c.encode(v, forKey: .fraction) } else { try c.encodeNil(forKey: .fraction) }
        try c.encode(detail, forKey: .detail)
    }
}

struct MetaHeartbeatPayload: Encodable {
    let rtfCurrent: Double
    let ringBufferFillSec: Double
}

struct CaptureStartedPayload: Encodable {
    let sessionId: String
    let sampleRateHz: Int
    let channels: Int
    let model: String
    let vad: String
    let startedAt: String
}

struct CaptureStoppedPayload: Encodable {
    let sessionId: String
    let durationSec: Double
}

/// Both `segment.partial` and `segment.final` use this shape, with some
/// fields nil-or-present depending on stage. Final segments carry the
/// stable `segment_id`; partials carry only the `utterance_id` for replace
/// semantics on the UI side.
struct SegmentPayload: Encodable {
    let utteranceId: String
    let segmentId: String?
    let tStart: Double
    let tEnd: Double
    let text: String
    let language: String?
    let speaker: String?
    let translation: String?

    enum CodingKeys: String, CodingKey {
        case utteranceId, segmentId, tStart, tEnd, text, language, speaker, translation
    }

    // Explicit encode(to:) so nils serialize as JSON `null` rather than
    // dropped keys — keeps the wire shape stable across phases.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(utteranceId, forKey: .utteranceId)
        if let v = segmentId { try c.encode(v, forKey: .segmentId) } else { try c.encodeNil(forKey: .segmentId) }
        try c.encode(tStart, forKey: .tStart)
        try c.encode(tEnd, forKey: .tEnd)
        try c.encode(text, forKey: .text)
        if let v = language { try c.encode(v, forKey: .language) } else { try c.encodeNil(forKey: .language) }
        if let v = speaker { try c.encode(v, forKey: .speaker) } else { try c.encodeNil(forKey: .speaker) }
        if let v = translation { try c.encode(v, forKey: .translation) } else { try c.encodeNil(forKey: .translation) }
    }
}

struct BookmarkCreatedPayload: Encodable {
    let bookmarkId: String
    let t: Double
    let label: String
}

/// Emitted once when the engine determines an utterance has been superseded
/// by a later, overlapping, more-complete re-segmentation (ADR-0009 mints a
/// fresh `utterance_id` when WhisperKit re-segments a growing utterance; this
/// frame retracts the older fragment so the UI — and the saved file — don't
/// show overlapping growing fragments of the same sentence).
///
/// Consumer semantics: remove `utteranceId` from the displayed/retained set;
/// it has been replaced by `supersededBy`. Both props snake_case to
/// `utterance_id` / `superseded_by` via the outbound encoder's
/// `.convertToSnakeCase` strategy — both fields are non-optional, so the
/// synthesized `encode(to:)` is sufficient (no explicit nil handling needed,
/// unlike `SegmentPayload`).
struct SegmentSupersededPayload: Encodable {
    let utteranceId: String
    let supersededBy: String
}

/// Emitted once per meeting after capture.stop, when diarization has run and
/// the transcript has been written to the vault. Carries the vault path so the
/// UI can offer "reveal in Finder", the speaker roster, and a few stats.
///
/// Phase 5 v1 is anonymous: every speaker has `matchedName == nil` and
/// `confidence == nil`. The fields are modelled nullable so Phase 5.1
/// (enrollment / naming) can populate them without a contract change. As with
/// `SegmentPayload`, nested nullables use explicit `encode(to:)` so they
/// serialize as JSON `null` rather than dropped keys — the wire shape stays
/// stable across phases.
/// `audioPath` (ADR-0027, slice B): the ABSOLUTE path to the persisted
/// `<vault>/.audio/<id>.wav` when the session opted in via `keep_audio` AND the
/// write succeeded; `nil` (encoded as explicit JSON `null`) otherwise — opted
/// out, or the write failed. Analogous to `vaultPath`/`vault_path`. The optional
/// uses an explicit `encode(to:)` so it serializes as `null` rather than a
/// dropped key (same reason as `SegmentPayload`/`MeetingSpeaker`): with
/// `.convertToSnakeCase` the synthesized encoder would omit a nil value, and the
/// UI distinguishes "no audio" (null) from a forgotten field.
struct MeetingSavedPayload: Encodable {
    let sessionId: String
    let vaultPath: String
    let audioPath: String?
    let speakers: [MeetingSpeaker]
    let stats: MeetingStats

    enum CodingKeys: String, CodingKey {
        case sessionId, vaultPath, audioPath, speakers, stats
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(vaultPath, forKey: .vaultPath)
        if let v = audioPath { try c.encode(v, forKey: .audioPath) } else { try c.encodeNil(forKey: .audioPath) }
        try c.encode(speakers, forKey: .speakers)
        try c.encode(stats, forKey: .stats)
    }
}

struct MeetingSpeaker: Encodable {
    let label: String
    let matchedName: String?
    let confidence: Double?

    enum CodingKeys: String, CodingKey {
        case label, matchedName, confidence
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(label, forKey: .label)
        if let v = matchedName { try c.encode(v, forKey: .matchedName) } else { try c.encodeNil(forKey: .matchedName) }
        if let v = confidence { try c.encode(v, forKey: .confidence) } else { try c.encodeNil(forKey: .confidence) }
    }
}

struct MeetingStats: Encodable {
    let segments: Int
    let durationSec: Double
    let rtfAvg: Double
}

/// Emitted once per meeting at capture.stop, JUST BEFORE `meeting.saved`, so the
/// UI can back-annotate the on-screen transcript with speakers. Live `segment.final`
/// frames ship `speaker: nil` — diarization is a post-stop batch pass — so until
/// this frame the labels existed ONLY in the written vault file + the `meeting.saved`
/// roster, never back on the live transcript. This carries EXACTLY the deduped,
/// "Speaker N"-labeled utterances that were written to the markdown body, so the
/// on-screen transcript can be replaced to match the saved file verbatim.
///
/// `sessionId` matches `meeting.saved` (and `speaker.rename`), scoping the
/// replacement to the right meeting. Privacy: names/labels stay local — same set
/// the vault write produced, no network (hard rule #1/#2).
struct MeetingTranscriptPayload: Encodable {
    let sessionId: String                 // ← session_id
    let utterances: [TranscriptUtterance]
}

/// One labeled utterance for `meeting.transcript`. `id` is a stable per-utterance
/// key for the UI's `@for` track (index-based, e.g. "u0", "u1"…). `speaker` is the
/// "Speaker N" label from diarization — the SAME value written to the vault.
/// All fields non-optional, so the synthesized `encode(to:)` suffices (no explicit
/// nil handling like `SegmentPayload`). `tStart` snake_cases to `t_start`; the
/// single-word fields pass through unchanged via `.convertToSnakeCase`.
struct TranscriptUtterance: Encodable {
    let id: String
    let tStart: Double
    let text: String
    let speaker: String
}

struct WarningPayload: Encodable {
    let code: String
    let message: String
    let severity: String
}

struct ErrorPayload: Encodable {
    let code: String
    let message: String
    let recoverable: Bool
    let action: String?
}

/// Empty `ack` body. The matching `id` is in the envelope.
struct AckPayload: Encodable {}

// ─── UI → Engine command payloads ────────────────────────────────────────

struct CaptureStartCommand: Decodable {
    struct Sources: Decodable {
        let mic: Bool?
        let system: Bool?
    }
    struct Translation: Decodable {
        let enabled: Bool?
        let mode: String?
        let targetLang: String?
    }
    let sources: Sources?
    let translation: Translation?
    /// Optional language hint, locked for the session. ISO-639-1 ("vi",
    /// "en", "th"…). `nil` means auto-detect — WhisperKit picks per
    /// transcribe call, which is less reliable for short non-English
    /// windows. See language picker on the UI side. Locale is also
    /// implicitly the decoder's prompt language, so this affects more
    /// than just language detection.
    let language: String?
    /// Privacy gates (ADR-0027). BOTH default to the privacy-safe behavior
    /// when ABSENT (`nil` ⇒ treated as `false` by the session) — the user must
    /// explicitly opt in to persist sensitive data. `keep_audio`/
    /// `remember_speakers` arrive snake_case and fold to these property names via
    /// `decodeInbound`'s `.convertFromSnakeCase`.
    ///
    /// `keepAudio` — persist the meeting audio for the future review screen.
    /// Plumbing only for now; audio is still discarded when off (current behavior).
    let keepAudio: Bool?
    /// `rememberSpeakers` — store + match voiceprints (enrollment, ADR-0026).
    /// When false, the engine performs ZERO `.speakers/` reads or writes:
    /// enroll-on-rename is skipped and the post-stop auto-match is skipped, so
    /// speakers stay "Speaker N".
    let rememberSpeakers: Bool?
}

struct BookmarkCreateCommand: Decodable {
    let t: Double
    let label: String?
}

/// Post-save speaker rename (UI → engine). Diarization runs as a post-stop
/// batch pass, so "Speaker N" labels exist ONLY in the already-written vault
/// markdown — renaming is necessarily a re-render of that file with the user's
/// chosen display names. `names` maps a CURRENT speaker label (as it appears in
/// the saved file, e.g. "Speaker 1") to a new display name (e.g. "Alice"); only
/// changed speakers are included. `sessionId` scopes the edit to the meeting —
/// MVP only the most-recently-saved meeting is renameable.
///
/// `session_id` arrives snake_case and is folded to `sessionId` by
/// `decodeInbound`'s `.convertFromSnakeCase`. The `names` DICTIONARY is NOT key-
/// transformed — only struct property names are — so its keys/values pass
/// through verbatim ("Speaker 1" stays "Speaker 1").
struct SpeakerRenameCommand: Decodable {
    let sessionId: String          // ← session_id
    let names: [String: String]    // currentLabel -> newName
}
