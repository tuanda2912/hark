// EmbedderTests — coverage for the vault-RAG text embedder (Phase 6 slice 4a,
// ADR-0032). Two layers:
//
//   1. PURE pipeline math (always runs, no model needed): masked mean-pooling
//      EXCLUDES padding, L2-normalize yields a 384-dim unit vector, cosine
//      similarity, the e5 query/passage prefix selection, and the MLMultiArray
//      bridging. These pin the invariants the slice depends on regardless of
//      whether the CoreML artifact is present in this environment.
//
//   2. ON-DEVICE cross-lingual sanity (gated): downloads the real model + runs
//      ANE inference, then asserts an EN sentence is closer to its TH/VI
//      translation than to an unrelated sentence — the proof the MULTILINGUAL
//      embedder actually works. This needs the converted `.mlpackage` (which the
//      slice-4a spike could NOT produce in this env — no coremltools, sandboxed
//      Python) AND network for the first-run download, so it is SKIPPED unless
//      `HARK_TEST_EMBEDDER=1` is set on real M-series hardware with the model
//      available. When skipped it logs WHY — it is not a silent pass.
//
// Privacy note: synthetic vectors + literal sentences only; no vault data.

import XCTest
import CoreML
@testable import Harkd

@available(macOS 14.4, *)
final class EmbedderTests: XCTestCase {

    // MARK: - L2 normalize → 384-dim unit vector

    func testL2NormalizedIsUnitLengthAnd384() {
        // A non-trivial 384-vector (the index schema dim) normalizes to unit norm.
        var v = [Float](repeating: 0, count: 384)
        for i in 0..<384 { v[i] = Float(i % 7) - 3 }   // mixed signs, non-zero
        let n = CoreMLTextEmbedder.l2Normalized(v)
        XCTAssertEqual(n.count, 384)
        let mag = n.reduce(0) { $0 + $1 * $1 }.squareRoot()
        XCTAssertEqual(mag, 1.0, accuracy: 1e-5)
    }

    func testL2NormalizedZeroVectorReturnedUnchanged() {
        let z = [Float](repeating: 0, count: 384)
        XCTAssertEqual(CoreMLTextEmbedder.l2Normalized(z), z)
    }

    // MARK: - masked mean-pool EXCLUDES padding (the cross-lingual invariant)

    func testMaskedMeanPoolAveragesOnlyRealTokens() {
        // dim=2, 3 tokens. Real tokens: [1,1] and [3,3]; a padding token [100,100]
        // that MUST be ignored. Mean of the two real tokens = [2,2].
        let dim = 2
        let hidden: [Float] = [1, 1,  3, 3,  100, 100]
        let mask: [Int32] = [1, 1, 0]
        let pooled = CoreMLTextEmbedder.maskedMeanPool(
            hiddenState: hidden, attentionMask: mask, dimension: dim)
        XCTAssertEqual(pooled, [2, 2])
    }

    func testMaskedMeanPoolAllRealTokens() {
        let hidden: [Float] = [1, 0,  3, 0]
        let mask: [Int32] = [1, 1]
        XCTAssertEqual(
            CoreMLTextEmbedder.maskedMeanPool(hiddenState: hidden, attentionMask: mask, dimension: 2),
            [2, 0])
    }

    func testMaskedMeanPoolAllPaddingIsZero() {
        // Degenerate: no real tokens → zero vector (caller never feeds this; the
        // embed() empty-input guard fires first — pinned so the math is total).
        let hidden: [Float] = [5, 5,  6, 6]
        let mask: [Int32] = [0, 0]
        XCTAssertEqual(
            CoreMLTextEmbedder.maskedMeanPool(hiddenState: hidden, attentionMask: mask, dimension: 2),
            [0, 0])
    }

    // MARK: - padding builds the right ids + mask

    func testPaddedAddsPadTokensAndMask() {
        let (ids, mask) = CoreMLTextEmbedder.padded(ids: [10, 20], padTokenId: 1, toLength: 4)
        XCTAssertEqual(ids, [10, 20, 1, 1])
        XCTAssertEqual(mask, [1, 1, 0, 0])
    }

    func testPaddedNoPaddingWhenLengthMatches() {
        // Flexible-shape per-call path: target == ids.count → all-ones mask, no pad.
        let (ids, mask) = CoreMLTextEmbedder.padded(ids: [10, 20, 30], padTokenId: 1)
        XCTAssertEqual(ids, [10, 20, 30])
        XCTAssertEqual(mask, [1, 1, 1])
    }

    func testPaddedNeverTruncates() {
        // A toLength shorter than ids must not drop tokens (truncation is the
        // caller's job, before padding) — target clamps up to ids.count.
        let (ids, mask) = CoreMLTextEmbedder.padded(ids: [1, 2, 3, 4], padTokenId: 1, toLength: 2)
        XCTAssertEqual(ids.count, 4)
        XCTAssertEqual(mask, [1, 1, 1, 1])
    }

    // MARK: - cosine similarity

    func testCosineSimilarityIdenticalIsOne() {
        let v: [Float] = [1, 2, 3, 4]
        XCTAssertEqual(CoreMLTextEmbedder.cosineSimilarity(v, v), 1.0, accuracy: 1e-5)
    }

    func testCosineSimilarityOrthogonalIsZero() {
        XCTAssertEqual(CoreMLTextEmbedder.cosineSimilarity([1, 0], [0, 1]), 0.0, accuracy: 1e-6)
    }

    func testCosineSimilarityIsScaleInvariant() {
        // cosine ignores magnitude — [1,1] and [10,10] are colinear → 1.0.
        XCTAssertEqual(CoreMLTextEmbedder.cosineSimilarity([1, 1], [10, 10]), 1.0, accuracy: 1e-5)
    }

    // MARK: - e5 prefix selection (the descriptor wiring)

    func testDefaultModelIsMultilingual384WithE5Prefixes() {
        let m = EmbedderModels.default
        XCTAssertEqual(m.id, "multilingual-e5-small")
        XCTAssertEqual(m.dimension, 384)
        XCTAssertTrue(m.dimensionIsValid)
        XCTAssertEqual(m.tokenizerFamily, .sentencePieceUnigram)
        XCTAssertEqual(m.queryPrefix, "query: ")
        XCTAssertEqual(m.passagePrefix, "passage: ")
    }

    func testCuratedSetIsAll384AndLocalOnly() {
        // ADR-0032: every v1 curated model is 384-dim (fixed index schema). bge is
        // declared for the slice-5 slot but must still satisfy the schema rule.
        for m in EmbedderModels.curated {
            XCTAssertEqual(m.dimension, 384, "\(m.id) must be 384-dim")
            XCTAssertTrue(m.dimensionIsValid)
        }
        XCTAssertNotNil(EmbedderModels.byId("multilingual-e5-small"))
        XCTAssertNotNil(EmbedderModels.byId("bge-small-en-v1.5"))
        XCTAssertNil(EmbedderModels.byId("some-cloud-endpoint"))
    }

    func testBgeSlotHasQueryOnlyPrefix() {
        // bge convention: instruction prefix on the query, none on passages.
        let bge = EmbedderModels.bgeSmallEn
        XCTAssertEqual(bge.tokenizerFamily, .wordPiece)
        XCTAssertFalse(bge.queryPrefix.isEmpty)
        XCTAssertEqual(bge.passagePrefix, "")
    }

    // MARK: - MLMultiArray bridging + output flattening

    func testInt32MultiArrayShapeAndValues() throws {
        let arr = try CoreMLTextEmbedder.int32MultiArray([7, 8, 9], length: 3)
        XCTAssertEqual(arr.shape.map(\.intValue), [1, 3])
        XCTAssertEqual(arr.dataType, .int32)
        XCTAssertEqual(arr[0].int32Value, 7)
        XCTAssertEqual(arr[2].int32Value, 9)
    }

    func testFloatsFromFloat32MultiArrayRoundTrips() throws {
        // [1, 2, 2] = 2 tokens × dim 2.
        let arr = try MLMultiArray(shape: [1, 2, 2], dataType: .float32)
        let vals: [Float] = [1.5, 2.5, 3.5, 4.5]
        for i in 0..<4 { arr[i] = NSNumber(value: vals[i]) }
        let out = try CoreMLTextEmbedder.floats(from: arr, expectedTokens: 2, dimension: 2)
        XCTAssertEqual(out, vals)
    }

    func testFloatsRejectsWrongElementCount() throws {
        let arr = try MLMultiArray(shape: [1, 2, 2], dataType: .float32)   // 4 elems
        XCTAssertThrowsError(
            try CoreMLTextEmbedder.floats(from: arr, expectedTokens: 3, dimension: 2)) { err in
            // 3×2=6 expected vs 4 present → loud shape error, not silent mis-pool.
            guard case TextEmbedderError.unexpectedOutputShape = err else {
                return XCTFail("expected unexpectedOutputShape, got \(err)")
            }
        }
    }

    // MARK: - end-to-end pooling pipeline (no CoreML — fake hidden states)

    func testPoolThenNormalizeProducesUnitVector() {
        // Simulate the tail of embed(): a [3-token × 384] last_hidden_state with the
        // last token padding, masked-mean-pooled then L2-normalized → 384 unit vec.
        let dim = 384
        var hidden = [Float](repeating: 0, count: 3 * dim)
        for d in 0..<dim { hidden[d] = Float(d % 5) + 1 }            // token 0 (real)
        for d in 0..<dim { hidden[dim + d] = Float(d % 3) + 2 }      // token 1 (real)
        for d in 0..<dim { hidden[2 * dim + d] = 999 }               // token 2 (PAD)
        let mask: [Int32] = [1, 1, 0]

        let pooled = CoreMLTextEmbedder.maskedMeanPool(
            hiddenState: hidden, attentionMask: mask, dimension: dim)
        let vec = CoreMLTextEmbedder.l2Normalized(pooled)
        XCTAssertEqual(vec.count, 384)
        XCTAssertEqual(vec.reduce(0) { $0 + $1 * $1 }.squareRoot(), 1.0, accuracy: 1e-5)
        // The 999 padding token must not have leaked in: pooled is bounded by the
        // two real tokens' range (≤ 5), nowhere near 999.
        XCTAssertLessThan(pooled.max() ?? 0, 10)
    }

    // MARK: - ON-DEVICE cross-lingual sanity (gated; needs the real model)

    /// The proof the multilingual embedder works: an English sentence is closer
    /// (cosine) to its Thai translation than to an unrelated English sentence.
    ///
    /// SKIPPED unless `HARK_TEST_EMBEDDER=1`. The slice-4a spike could NOT obtain
    /// the CoreML `.mlpackage` in this environment (no coremltools / sandboxed
    /// Python), so this can only be run by hand once the converted model is placed
    /// in Hark's models dir on real M-series hardware. Wired against the SAME
    /// `loadTextEmbedder` + `embed` the engine uses — running it is the real-
    /// hardware verification step, not a fabricated pass.
    func testCrossLingualSimilarity_OnDevice() async throws {
        guard ProcessInfo.processInfo.environment["HARK_TEST_EMBEDDER"] == "1" else {
            throw XCTSkip(
                "on-device embedder test skipped: set HARK_TEST_EMBEDDER=1 and provide the "
                + "converted multilingual-e5-small .mlpackage in Hark's models dir "
                + "(slice-4a spike could not convert CoreML in this env — see report).")
        }

        let loaded = try await loadTextEmbedder()
        let embedder = loaded.embedder

        // EN ↔ its TH translation should be MORE similar than EN ↔ unrelated EN.
        let en = "The quarterly budget review is scheduled for next Monday."
        let th = "การทบทวนงบประมาณรายไตรมาสมีกำหนดในวันจันทร์หน้า"      // same meaning, Thai
        let unrelated = "My cat likes to sleep on the warm windowsill in the afternoon."

        let vEn = try await embedder.embed(en, kind: .passage)
        let vTh = try await embedder.embed(th, kind: .passage)
        let vUnrelated = try await embedder.embed(unrelated, kind: .passage)

        // Output contract: 384-dim, unit-norm.
        XCTAssertEqual(vEn.count, 384)
        XCTAssertEqual(vEn.reduce(0) { $0 + $1 * $1 }.squareRoot(), 1.0, accuracy: 1e-3)

        let crossLingual = CoreMLTextEmbedder.cosineSimilarity(vEn, vTh)
        let unrelatedSim = CoreMLTextEmbedder.cosineSimilarity(vEn, vUnrelated)
        XCTAssertGreaterThan(
            crossLingual, unrelatedSim,
            "EN↔TH translation (\(crossLingual)) must beat EN↔unrelated (\(unrelatedSim))")
    }
}
