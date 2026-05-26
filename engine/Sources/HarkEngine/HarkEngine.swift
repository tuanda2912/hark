// hark-engine — Phase 1 batch transcription CLI.
//
// File in (audio), JSON segments out. No streaming, no diarization, no
// translation — those land in Phases 3, 5, 6 respectively. This binary's
// only job is "run WhisperKit on a file and emit a structured result that
// Phase 3's WebSocket layer can wrap cleanly."
//
// Output shape matches `segment.final` from the WebSocket API contract
// (see vault/docs/design/08-websocket-api-contract.md) minus the fields
// that don't exist yet — speaker and translation are emitted as JSON `null`.
//
// Discipline: progress + errors → stderr. JSON → stdout (unless `--output`
// is set). This is so `hark-engine foo.wav | jq '.segments[0]'` works.
//
// ──────────────────────────────────────────────────────────────────────────
// Swift idioms for a Java/Spring dev:
//   `@main`              ≈ `public static void main`. ArgumentParser's
//                          `AsyncParsableCommand` looks for an `async`
//                          `run()` method on the type and calls it after
//                          parsing argv into the struct's properties.
//   `@Argument`/`@Option`/`@Flag` — property wrappers that double as
//                          annotations: ArgumentParser reads them via
//                          reflection-equivalent to wire argv into fields.
//                          Like Spring's `@Value("${...}")` on a field.
//   `struct ... : AsyncParsableCommand` — value type. Each parse creates a
//                          fresh instance, no shared mutable state across
//                          invocations. Different from a Spring controller
//                          (singleton). Conceptually closer to a JAX-RS
//                          request-scoped command bean.
// ──────────────────────────────────────────────────────────────────────────

import Foundation
import WhisperKit
import HarkCore
import ArgumentParser

// Engine version string. Bumped manually for now — when we ship a real
// release pipeline this will come from a build setting / git tag.
let HARK_ENGINE_VERSION = "0.1.0"

// ─── stderr helper ────────────────────────────────────────────────────────
// `print(...)` in Swift writes to stdout. We need a stderr equivalent so
// progress doesn't pollute the JSON output stream.
@inline(__always)
func eprint(_ s: String, terminator: String = "\n") {
    FileHandle.standardError.write(Data((s + terminator).utf8))
}

// ─── JSON model — matches segment.final payload ───────────────────────────
//
// All `Codable` so JSONEncoder synthesises encode/decode for free.
// Snake_case keys produced by encoder.keyEncodingStrategy below; we keep
// camelCase property names (Swift idiom).

struct EngineMeta: Codable {
    let engineVersion: String
    let model: String
    let inputFile: String
    let audioDurationSeconds: Double
    let transcribedAt: String       // ISO 8601
    let languageDetected: String?
    // Marker for the ndjson header line so consumers can dispatch on it.
    // Omitted in the default pretty-array output.
    let type: String?
}

/// One transcript segment. `speaker` and `translation` are reserved for
/// Phase 5 / Phase 6 — we emit JSON `null` until then.
///
/// Two ID fields, both UUID v4:
///   - `segment_id`  — unique per emitted JSON object.
///   - `utterance_id` — groups partials that converged to the same final.
///     In batch mode there are no partials, so it's currently always a
///     fresh UUID per segment. Kept for Phase 3 wire-compat.
struct EngineSegment: Codable {
    let segmentId: String
    let utteranceId: String
    let tStart: Double
    let tEnd: Double
    let text: String
    let language: String?
    // Codable's synthesized encoder treats `nil` Optionals as missing keys
    // by default. We want explicit `"speaker": null` to keep the wire
    // contract honest. So we mark them as String? but customise below.
    let speaker: String?
    let translation: String?

    // Explicit CodingKeys + encode(to:) to force `null` for absent
    // optional fields rather than dropping the key entirely. Future-proofs
    // the contract for Phase 5/6.
    enum CodingKeys: String, CodingKey {
        case segmentId, utteranceId, tStart, tEnd, text, language, speaker, translation
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(segmentId, forKey: .segmentId)
        try c.encode(utteranceId, forKey: .utteranceId)
        try c.encode(tStart, forKey: .tStart)
        try c.encode(tEnd, forKey: .tEnd)
        try c.encode(text, forKey: .text)
        // `encodeIfPresent` would drop nils — we want them explicit.
        if let l = language { try c.encode(l, forKey: .language) } else { try c.encodeNil(forKey: .language) }
        if let s = speaker  { try c.encode(s, forKey: .speaker) }  else { try c.encodeNil(forKey: .speaker)  }
        if let t = translation { try c.encode(t, forKey: .translation) } else { try c.encodeNil(forKey: .translation) }
    }
}

struct EngineReport: Codable {
    let meta: EngineMeta
    let segments: [EngineSegment]
}

// ─── Language enum for --language ─────────────────────────────────────────
// We accept the literal string and pass it through. WhisperKit handles the
// validation. `auto` translates to "detect" (no explicit hint).

struct LanguageOption: ExpressibleByArgument, CustomStringConvertible {
    let raw: String
    var description: String { raw }  // controls how default is rendered in --help
    init?(argument: String) {
        // Trim, lowercase, store. Empty / invalid will surface as a
        // WhisperKit error later — we don't second-guess the list of
        // supported langs here.
        let trimmed = argument.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }
        self.raw = trimmed
    }
    /// Whisper language hint or nil for auto-detect.
    var whisperHint: String? { raw == "auto" ? nil : raw }
}

// ─── The command itself ───────────────────────────────────────────────────

@main
struct HarkEngineCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hark-engine",
        abstract: "Transcribe an audio file using WhisperKit (Phase 1 — batch mode).",
        discussion: """
        Reads an audio file, runs WhisperKit large-v3-turbo on the Apple Neural
        Engine, and emits structured JSON segments. Default output is a pretty
        JSON array on stdout; use --output to write to a file, --ndjson to emit
        one segment per line for streaming consumers.

        Progress and errors go to stderr. JSON goes to stdout, so you can do:
            hark-engine recording.wav | jq '.segments[].text'
        """
    )

    @Argument(help: "Path to the audio file (.wav .mp3 .m4a .flac).")
    var audioPath: String

    @Option(name: .shortAndLong, help: "Write JSON to this path instead of stdout.")
    var output: String?

    @Option(name: .shortAndLong, help: "Language hint: 'auto', 'en', 'th', etc.")
    var language: LanguageOption = LanguageOption(argument: "auto")!

    @Flag(help: "Emit newline-delimited JSON (one segment per line, no array).")
    var ndjson: Bool = false

    // ArgumentParser invokes this. `mutating` because `@Argument` properties
    // are written into `self` during decode — Swift requires `mutating` on
    // any method that may mutate a value-type's state.
    mutating func run() async throws {
        // Validate input file exists. ArgumentParser's `ValidationError`
        // prints usage + the message and exits non-zero — exactly what we
        // want for bad CLI args.
        guard FileManager.default.fileExists(atPath: audioPath) else {
            throw ValidationError("audio file not found: \(audioPath)")
        }

        eprint("──────────────────────────────────────────────────────────────")
        eprint("hark-engine \(HARK_ENGINE_VERSION) — batch transcribe")
        eprint("──────────────────────────────────────────────────────────────")
        eprint("Input:    \(audioPath)")
        eprint("Language: \(language.raw)")
        eprint("Output:   \(output ?? "stdout")\(ndjson ? " (ndjson)" : "")")
        eprint("")

        // ── Load WhisperKit (download + compile + load) ──
        let loaded = try await loadWhisperKit(
            modelName: DEFAULT_MODEL_NAME,
            downloadBase: nil,
            progressOutput: .standardError
        )

        // ── Decode audio ──
        // AudioProcessor.loadAudioAsFloatArray resamples to 16 kHz mono.
        eprint("Decoding audio...")
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioPath)
        guard !samples.isEmpty else {
            throw ValidationError("decoded zero samples from \(audioPath)")
        }
        let sampleRate = 16_000
        let audioSeconds = Double(samples.count) / Double(sampleRate)
        eprint(String(format: "Decoded %d samples (%.2fs of audio).", samples.count, audioSeconds))
        eprint("")

        // ── Transcribe ──
        // For Phase 1 we do a single-shot transcribe of the whole file and
        // let WhisperKit produce its own segmentation. Real streaming with
        // sliding windows lands in Phase 3.
        //
        // Heartbeat ensures we never go silent for >5s during long files.
        eprint("Transcribing...")
        let transcribeStart = Date()
        let heartbeat = startHeartbeat(label: "transcribing", output: .standardError)

        let results: [TranscriptionResult]
        do {
            let options = DecodingOptions(
                verbose: false,
                task: .transcribe,
                language: language.whisperHint,
                // Default temperature schedule — let WhisperKit decide.
                withoutTimestamps: false
            )
            results = try await loaded.pipe.transcribe(
                audioArray: samples,
                decodeOptions: options
            )
        } catch {
            heartbeat.cancel()
            throw error
        }
        heartbeat.cancel()
        let transcribeSeconds = Date().timeIntervalSince(transcribeStart)
        let rtf = transcribeSeconds / audioSeconds
        eprint(String(format: "Transcribed in %.2fs (RTF=%.3f).", transcribeSeconds, rtf))
        eprint("")

        // ── Flatten WhisperKit segments to our wire shape ──
        // WhisperKit returns one TranscriptionResult per decoded chunk;
        // each carries an array of `segments` with timing. We concatenate
        // and re-wrap in our Codable type.
        var segments: [EngineSegment] = []
        var detectedLanguage: String? = nil
        for result in results {
            if detectedLanguage == nil, !result.language.isEmpty {
                detectedLanguage = result.language
            }
            for seg in result.segments {
                let cleaned = stripWhisperSpecialTokens(seg.text)
                    .trimmingCharacters(in: .whitespaces)
                // WhisperKit can emit empty segments around silence;
                // drop them — they're noise on the wire.
                guard !cleaned.isEmpty else { continue }
                segments.append(EngineSegment(
                    segmentId: UUID().uuidString,
                    utteranceId: UUID().uuidString,
                    tStart: Double(seg.start),
                    tEnd: Double(seg.end),
                    text: cleaned,
                    language: detectedLanguage ?? language.whisperHint,
                    speaker: nil,
                    translation: nil
                ))
            }
        }
        eprint("Produced \(segments.count) segment(s).")

        // ── Emit JSON ──
        let meta = EngineMeta(
            engineVersion: HARK_ENGINE_VERSION,
            model: loaded.modelName,
            inputFile: audioPath,
            audioDurationSeconds: audioSeconds,
            transcribedAt: ISO8601DateFormatter().string(from: Date()),
            languageDetected: detectedLanguage ?? language.whisperHint,
            type: nil
        )

        let sink = try OutputSink(path: output)
        defer { sink.close() }

        if ndjson {
            try emitNDJSON(meta: meta, segments: segments, sink: sink)
        } else {
            try emitPretty(meta: meta, segments: segments, sink: sink)
        }

        if let path = output {
            eprint("Wrote \(segments.count) segment(s) to \(path)")
        }
    }
}

// ─── Whisper special-token scrubbing ─────────────────────────────────────
//
// WhisperKit's segment.text includes the raw decoder output, which contains
// special tokens like <|startoftranscript|>, <|en|>, <|transcribe|>, and
// per-word timestamp tokens like <|2.82|>. They're not meant for human
// consumption. Strip anything between `<|` and `|>`.
//
// We use a regex literal — Swift 5.7+ supports them inline (the `#/.../#`
// syntax). Equivalent to Java `Pattern.compile("<\\|[^|]*\\|>")`.
private let whisperSpecialTokenRegex = try! NSRegularExpression(
    pattern: #"<\|[^|]*\|>"#,
    options: []
)

private func stripWhisperSpecialTokens(_ s: String) -> String {
    let range = NSRange(s.startIndex..<s.endIndex, in: s)
    return whisperSpecialTokenRegex.stringByReplacingMatches(
        in: s, options: [], range: range, withTemplate: ""
    )
}

// ─── Output sink — stdout or file ────────────────────────────────────────
//
// Wraps a FileHandle so we can swap stdout/file at one boundary.
// Privacy note: per CLAUDE.md hard rule #2 we only write to the path the
// user explicitly passed. No fallback paths, no log mirrors.

final class OutputSink {
    private let handle: FileHandle
    private let ownsHandle: Bool

    init(path: String?) throws {
        if let path = path {
            // Create or truncate. Don't follow symlinks blindly — but
            // FileManager.createFile honors them on macOS. We accept that
            // for v1; the user provided the path.
            let fm = FileManager.default
            if fm.fileExists(atPath: path) {
                try fm.removeItem(atPath: path)
            }
            fm.createFile(atPath: path, contents: nil)
            guard let h = FileHandle(forWritingAtPath: path) else {
                throw ValidationError("could not open output for write: \(path)")
            }
            self.handle = h
            self.ownsHandle = true
        } else {
            self.handle = .standardOutput
            self.ownsHandle = false
        }
    }

    func write(_ data: Data) { handle.write(data) }
    func writeLine(_ s: String) { handle.write(Data((s + "\n").utf8)) }
    func close() { if ownsHandle { try? handle.close() } }
}

// ─── Encoders ────────────────────────────────────────────────────────────

private func makeEncoder(pretty: Bool) -> JSONEncoder {
    let enc = JSONEncoder()
    if pretty {
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    } else {
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }
    enc.keyEncodingStrategy = .convertToSnakeCase
    return enc
}

private func emitPretty(meta: EngineMeta, segments: [EngineSegment], sink: OutputSink) throws {
    let report = EngineReport(meta: meta, segments: segments)
    let enc = makeEncoder(pretty: true)
    let data = try enc.encode(report)
    sink.write(data)
    sink.write(Data("\n".utf8))
}

private func emitNDJSON(meta: EngineMeta, segments: [EngineSegment], sink: OutputSink) throws {
    let enc = makeEncoder(pretty: false)
    // First line: meta header with explicit `"type": "meta"` so Phase 3
    // consumers can dispatch on it.
    let header = EngineMeta(
        engineVersion: meta.engineVersion,
        model: meta.model,
        inputFile: meta.inputFile,
        audioDurationSeconds: meta.audioDurationSeconds,
        transcribedAt: meta.transcribedAt,
        languageDetected: meta.languageDetected,
        type: "meta"
    )
    let headerData = try enc.encode(header)
    sink.write(headerData)
    sink.write(Data("\n".utf8))
    for seg in segments {
        let line = try enc.encode(seg)
        sink.write(line)
        sink.write(Data("\n".utf8))
    }
}
