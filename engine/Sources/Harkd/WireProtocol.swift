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
}

struct BookmarkCreateCommand: Decodable {
    let t: Double
    let label: String?
}
