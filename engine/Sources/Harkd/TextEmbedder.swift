// TextEmbedder — on-device CoreML text embedding for vault RAG
// (Phase 6 slice 4a, ADR-0032). String → L2-normalized 384-dim `[Float]`,
// fully LOCAL (no network at embed time).
//
// Pipeline (ADR-0032 §4):
//   text  ──prefix──▶ "query: …" / "passage: …"   (e5 asymmetric convention)
//         ──tokenize─▶ input_ids + attention_mask  (offline swift-transformers)
//         ──pad/trunc▶ fixed [1, L] int32 tensors
//         ──CoreML───▶ last_hidden_state [1, L, 384]   (ANE)
//         ──pool─────▶ masked mean over real tokens   (padding excluded)
//         ──normalize▶ unit-length 384-dim [Float]
//
// WHY masked mean-pooling: e5 is trained with mean-pooling over the tokens the
// attention mask marks as real. Averaging the padding positions too (the easy
// bug) drags every vector toward the pad-token embedding and collapses
// cross-lingual separation — exactly the property the slice-4a sanity test
// guards. We pool ourselves (over `last_hidden_state`) rather than trust a
// model that baked pooling in, so this invariant is OURS to verify.
//
// WHY an actor: a CoreML `MLModel` is a stateful, non-Sendable handle and
// embedding runs off the live audio/ASR path. The actor is the single owner —
// like a Spring `@Service` whose state is auto-synchronized; callers `await`
// `embed(...)` the way you'd await a Kotlin coroutine, never touching the model
// concurrently. The heavy ANE call is wrapped so only ONE inference runs at a
// time, which is what we want (predictable RTF, no ANE contention).
//
// The pure vector math (pad, pool, normalize) is split into `static` functions
// so the unit tests can drive the pipeline deterministically WITHOUT the real
// `.mlpackage` (which can't be converted in CI). See EmbedderTests.

import Foundation
import CoreML
import Tokenizers

/// What a chunk of text is being embedded FOR. Drives the e5 asymmetric prefix:
/// a stored note chunk is a `passage`, a user's search string is a `query`.
/// Mixing them up still works but measurably hurts retrieval — so it's explicit.
enum EmbeddingKind: Sendable {
    case query
    case passage
}

enum TextEmbedderError: Error, CustomStringConvertible {
    case modelNotLoaded
    case emptyInput
    case unexpectedOutputShape(String)
    case missingOutputFeature(String)

    var description: String {
        switch self {
        case .modelNotLoaded:
            return "text embedder used before its CoreML model was loaded"
        case .emptyInput:
            return "cannot embed empty text"
        case .unexpectedOutputShape(let s):
            return "embedder CoreML output had unexpected shape: \(s)"
        case .missingOutputFeature(let name):
            return "embedder CoreML output missing feature \"\(name)\""
        }
    }
}

/// The interface slice 4b retrieval codes against. Keeping it a protocol lets the
/// second curated model (bge-small, WordPiece) — and a future local Ollama
/// endpoint (ADR-0032 deferred tier) — slot in behind the same call site without
/// touching the index/retrieval code.
///
/// `Sendable` because the index actor (4b) holds a reference across awaits.
protocol TextEmbedder: Sendable {
    /// The descriptor this embedder runs (id/revision/dim — recorded in the index
    /// manifest so a model change triggers re-index).
    var model: EmbedderModel { get }

    /// Embed `text` as a `query` or `passage`. Returns an L2-normalized
    /// `model.dimension`-length vector. LOCAL only — never networks.
    func embed(_ text: String, kind: EmbeddingKind) async throws -> [Float]
}

/// CoreML-backed `TextEmbedder` for the curated set. Loaded once via
/// `EmbedderLoader` (download → ANE compile), then embeds offline.
actor CoreMLTextEmbedder: TextEmbedder {
    nonisolated let model: EmbedderModel

    private let mlModel: MLModel
    private let tokenizer: Tokenizer

    /// The CoreML output feature carrying token-level hidden states. Our owned
    /// conversion names it `last_hidden_state`; the loader validates its presence
    /// at load time so a bad artifact fails loudly at startup, not mid-meeting.
    private let hiddenStateFeature: String

    init(model: EmbedderModel, mlModel: MLModel, tokenizer: Tokenizer,
         hiddenStateFeature: String = "last_hidden_state") {
        self.model = model
        self.mlModel = mlModel
        self.tokenizer = tokenizer
        self.hiddenStateFeature = hiddenStateFeature
    }

    func embed(_ text: String, kind: EmbeddingKind) async throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TextEmbedderError.emptyInput }

        // 1. e5 asymmetric prefix.
        let prefix = (kind == .query) ? model.queryPrefix : model.passagePrefix
        let prefixed = prefix + trimmed

        // 2. tokenize (offline) → ids (special tokens included: <s> … </s>).
        var ids = tokenizer.encode(text: prefixed, addSpecialTokens: true)

        // 3. truncate to the model's max length. We keep the trailing EOS so the
        //    sequence still ends the way the model expects after a hard cut.
        if ids.count > model.maxSequenceLength {
            let eos = tokenizer.eosTokenId
            ids = Array(ids.prefix(model.maxSequenceLength))
            if let eos { ids[ids.count - 1] = eos }
        }

        // 4. pad to length + build the attention mask, then run CoreML + pool.
        let (inputIds, attentionMask) = Self.padded(ids: ids, padTokenId: padTokenId)
        let hidden = try runModel(inputIds: inputIds, attentionMask: attentionMask)
        let pooled = Self.maskedMeanPool(
            hiddenState: hidden, attentionMask: attentionMask, dimension: model.dimension)
        return Self.l2Normalized(pooled)
    }

    /// XLM-RoBERTa / e5 pad id is 1 (`<pad>`). We read it from the tokenizer when
    /// available and fall back to 1 — the value the conversion's mask logic assumes.
    private var padTokenId: Int {
        tokenizer.convertTokenToId("<pad>") ?? 1
    }

    // ─── CoreML call ───────────────────────────────────────────────────────────

    /// Run the model on one [1, L] int32 sequence and return `last_hidden_state`
    /// as a row-major `[Float]` of length `L * dimension`.
    private func runModel(inputIds: [Int32], attentionMask: [Int32]) throws -> [Float] {
        let length = inputIds.count
        let idsArray = try Self.int32MultiArray(inputIds, length: length)
        let maskArray = try Self.int32MultiArray(attentionMask, length: length)

        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: idsArray),
            "attention_mask": MLFeatureValue(multiArray: maskArray),
        ])
        let out = try mlModel.prediction(from: provider)
        guard let value = out.featureValue(for: hiddenStateFeature),
              let arr = value.multiArrayValue else {
            throw TextEmbedderError.missingOutputFeature(hiddenStateFeature)
        }
        return try Self.floats(from: arr, expectedTokens: length, dimension: model.dimension)
    }

    // ─── Pure pipeline math (static so tests drive it without a model) ──────────

    /// Pad `ids` with `padTokenId` up to its own length-aligned tensor and emit a
    /// matching attention mask (1 for real tokens, 0 for padding). We do NOT pad
    /// to a fixed 512 — a flexible-shape conversion lets short note chunks run as
    /// short sequences (far less ANE work / lower RTF). `ids` is already truncated
    /// to `maxSequenceLength` by the caller.
    ///
    /// NOTE: with the per-call flexible length there is no padding to add here
    /// (length == ids.count, mask all-ones). The pad path exists for a
    /// fixed-shape conversion fallback and is exercised by the unit tests.
    static func padded(ids: [Int], padTokenId: Int, toLength: Int? = nil)
        -> (inputIds: [Int32], attentionMask: [Int32]) {
        let target = max(toLength ?? ids.count, ids.count)
        var input = [Int32](repeating: Int32(padTokenId), count: target)
        var mask = [Int32](repeating: 0, count: target)
        for (i, id) in ids.enumerated() {
            input[i] = Int32(id)
            mask[i] = 1
        }
        return (input, mask)
    }

    /// Masked mean-pool `hiddenState` (row-major `[tokens * dimension]`) over the
    /// positions the mask marks real. Padding positions are excluded so they
    /// never bias the centroid (the cross-lingual-quality invariant).
    static func maskedMeanPool(hiddenState: [Float], attentionMask: [Int32], dimension: Int)
        -> [Float] {
        var acc = [Float](repeating: 0, count: dimension)
        var realTokens: Float = 0
        let tokens = attentionMask.count
        for t in 0..<tokens where attentionMask[t] != 0 {
            let base = t * dimension
            for d in 0..<dimension { acc[d] += hiddenState[base + d] }
            realTokens += 1
        }
        guard realTokens > 0 else { return acc }
        for d in 0..<dimension { acc[d] /= realTokens }
        return acc
    }

    /// L2-normalize to unit length. Mirrors `SpeakerStore.l2Normalized` (ADR-0026):
    /// a zero vector is returned unchanged. Kept here too so the embedder has no
    /// dependency on the speaker store — same math, independent owners.
    static func l2Normalized(_ v: [Float]) -> [Float] {
        var sumSquares: Float = 0
        for x in v { sumSquares += x * x }
        let magnitude = sumSquares.squareRoot()
        guard magnitude > 0 else { return v }
        return v.map { $0 / magnitude }
    }

    // ─── MLMultiArray bridging ──────────────────────────────────────────────────

    /// Build a `[1, length]` Int32 `MLMultiArray` from a flat token row. CoreML
    /// wants a 2-D shape (batch=1) even for a single sequence.
    static func int32MultiArray(_ values: [Int32], length: Int) throws -> MLMultiArray {
        let arr = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
        let ptr = arr.dataPointer.bindMemory(to: Int32.self, capacity: length)
        for i in 0..<length { ptr[i] = values[i] }
        return arr
    }

    /// Flatten a CoreML float output (`Float16` or `Float32`, shape `[1, T, D]`)
    /// into a row-major `[Float]` of `T * D`. We validate the element count
    /// against the expected `tokens * dimension` so a shape regression in a
    /// re-converted model fails loudly rather than silently mis-pooling.
    static func floats(from arr: MLMultiArray, expectedTokens: Int, dimension: Int) throws
        -> [Float] {
        let expected = expectedTokens * dimension
        guard arr.count == expected else {
            throw TextEmbedderError.unexpectedOutputShape(
                "got \(arr.count) elements, expected \(expectedTokens)×\(dimension)=\(expected) "
                + "(shape \(arr.shape.map(\.intValue)))")
        }
        var out = [Float](repeating: 0, count: expected)
        switch arr.dataType {
        case .float32:
            let p = arr.dataPointer.bindMemory(to: Float.self, capacity: expected)
            for i in 0..<expected { out[i] = p[i] }
        case .float16:
            // No direct Float16→Float vector load on all SDKs; go via the
            // NSNumber accessor which CoreML promotes correctly. Slower, but this
            // path only runs if the conversion emits FP16 outputs.
            for i in 0..<expected { out[i] = arr[i].floatValue }
        case .double:
            let p = arr.dataPointer.bindMemory(to: Double.self, capacity: expected)
            for i in 0..<expected { out[i] = Float(p[i]) }
        default:
            throw TextEmbedderError.unexpectedOutputShape(
                "unsupported output dtype \(arr.dataType.rawValue)")
        }
        return out
    }

    // ─── Cosine (test + 4b helper) ──────────────────────────────────────────────

    /// Cosine similarity of two equal-length vectors. For already-L2-normalized
    /// vectors this is just the dot product, but we divide by magnitudes so it's
    /// correct for un-normalized inputs too. Used by the cross-lingual sanity test
    /// and available to 4b's brute-force search.
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = (na.squareRoot() * nb.squareRoot())
        guard denom > 0 else { return 0 }
        return dot / denom
    }
}
