// RagIndexTests — coverage for the vault-RAG vector index (Phase 6 slice 4b,
// ADR-0032/0033). PURE logic + actor behavior, always runs (no real embedder): we
// feed SYNTHETIC L2-normalized vectors directly, so the store/search/persist paths
// are exercised deterministically without CoreML.
//
// What these pin:
//   - brute-force cosine top-K ranking (the pure `topK`) + the actor `search`;
//   - add → search returns the closest chunk first;
//   - persist → reload round-trips vectors + (textless) metadata byte-for-byte;
//   - OFFSET-ONLY: meta.jsonl persists pointers/offsets but NEVER raw note text;
//   - a model-id / model-revision change ⇒ rebuild (the loaded index is dropped);
//   - replaceFile (incremental): a changed file's rows are swapped, an unchanged
//     file is skippable via the hash gate, a removed file's rows are dropped.
//
// Each test uses a UNIQUE temp dir for the index files — never the real
// HarkPaths.indexDir(), never the vault.
//
// Privacy: synthetic vectors + literal pointer strings only; no vault data.

import XCTest
@testable import Harkd

@available(macOS 14.4, *)
final class RagIndexTests: XCTestCase {

    private let dim = 4
    private let modelId = "multilingual-e5-small"
    private let revision = "rev-abc"

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-ragindex-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func l2(_ v: [Float]) -> [Float] { CoreMLTextEmbedder.l2Normalized(v) }

    // `text` is a convenience here ONLY to derive a plausible charEnd offset — it is
    // NOT stored in the meta (offset-only index; the meta carries pointers, not text).
    private func meta(_ id: String, note: String, text: String) -> RagChunkMeta {
        RagChunkMeta(chunkId: id, notePath: note, headingPath: "", charStart: 0,
                     charEnd: text.count, contentHash: "h-\(id)")
    }

    private func makeIndex(_ dir: URL, revision: String? = nil) -> RagIndex {
        RagIndex(dim: dim, modelId: modelId, modelRevision: revision ?? self.revision, dir: dir)
    }

    // MARK: - pure brute-force top-K ranking

    func testTopKRanksByDotProductDescending() {
        // 3 rows, dim 2. Query [1,0]. Row scores: r0·q=1.0, r1·q=0.0, r2·q=0.7.
        let q: [Float] = [1, 0]
        let vectors: [Float] = [1, 0,   0, 1,   0.7, 0.714]
        let ranked = RagIndex.topK(query: q, vectors: vectors, dim: 2, count: 3, k: 3)
        XCTAssertEqual(ranked.map(\.index), [0, 2, 1], "ranked by dot product, descending")
        XCTAssertEqual(ranked[0].score, 1.0, accuracy: 1e-5)
    }

    func testTopKHonorsK() {
        let q: [Float] = [1, 0]
        let vectors: [Float] = [1, 0,   0.5, 0,   0.1, 0]
        let ranked = RagIndex.topK(query: q, vectors: vectors, dim: 2, count: 3, k: 2)
        XCTAssertEqual(ranked.count, 2)
        XCTAssertEqual(ranked.map(\.index), [0, 1])
    }

    func testTopKTiesKeepLowerIndex() {
        let q: [Float] = [1, 0]
        let vectors: [Float] = [1, 0,   1, 0]   // identical → tie
        let ranked = RagIndex.topK(query: q, vectors: vectors, dim: 2, count: 2, k: 2)
        XCTAssertEqual(ranked.map(\.index), [0, 1], "stable: ties keep lower index first")
    }

    func testTopKEmptyInputs() {
        XCTAssertTrue(RagIndex.topK(query: [1, 0], vectors: [], dim: 2, count: 0, k: 5).isEmpty)
        XCTAssertTrue(RagIndex.topK(query: [1, 0], vectors: [1, 0], dim: 2, count: 1, k: 0).isEmpty)
    }

    // MARK: - actor search

    func testAddThenSearchReturnsClosestFirst() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = makeIndex(dir)

        // Three chunks pointing in distinct directions.
        let vNorth = l2([1, 0, 0, 0])
        let vEast = l2([0, 1, 0, 0])
        let vNE = l2([1, 1, 0, 0])
        await index.replaceFile(
            notePath: "n.md", fileContentHash: "f1",
            chunks: [meta("c-north", note: "n.md", text: "north"),
                     meta("c-east", note: "n.md", text: "east"),
                     meta("c-ne", note: "n.md", text: "northeast")],
            vectors: [vNorth, vEast, vNE])

        // Query aligned with "north": expect north first, then NE, then east.
        let hits = await index.search(queryVector: l2([1, 0, 0, 0]), k: 3)
        XCTAssertEqual(hits.map { $0.meta.chunkId }, ["c-north", "c-ne", "c-east"])
        XCTAssertEqual(hits[0].score, 1.0, accuracy: 1e-5)
    }

    func testSearchEmptyIndexReturnsEmpty() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = makeIndex(dir)
        let hits = await index.search(queryVector: l2([1, 0, 0, 0]), k: 5)
        XCTAssertTrue(hits.isEmpty)
    }

    // MARK: - persist → reload round-trip

    func testPersistThenReloadRoundTrips() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writeIndex = makeIndex(dir)
        let vA = l2([1, 2, 3, 4])
        let vB = l2([4, 3, 2, 1])
        await writeIndex.replaceFile(
            notePath: "meetings/m.md", fileContentHash: "filehash-1",
            chunks: [meta("a", note: "meetings/m.md", text: "alpha snippet"),
                     meta("b", note: "meetings/m.md", text: "beta snippet")],
            vectors: [vA, vB])
        try await writeIndex.persist()

        // Fresh index over the SAME dir → load → must match.
        let readIndex = makeIndex(dir)
        let outcome = await readIndex.loadFromDisk()
        guard case .loaded(let count) = outcome else {
            return XCTFail("expected .loaded, got \(outcome)")
        }
        XCTAssertEqual(count, 2)
        let chunkCount = await readIndex.chunkCount
        XCTAssertEqual(chunkCount, 2)

        // The hash gate must reload too: the file is "unchanged" after a reload.
        let unchanged = await readIndex.isFileUnchanged(notePath: "meetings/m.md", fileContentHash: "filehash-1")
        XCTAssertTrue(unchanged, "per-file hash survives the persist/reload round-trip")

        // And a search ranks identically: querying near vA returns "a" first.
        let hits = await readIndex.search(queryVector: vA, k: 2)
        XCTAssertEqual(hits.first?.meta.chunkId, "a")
        // Pointers/offsets round-trip; there is NO text on the meta (offset-only).
        XCTAssertEqual(hits.first?.meta.notePath, "meetings/m.md")
        XCTAssertEqual(hits.first?.meta.charStart, 0)
        XCTAssertEqual(hits.first?.meta.charEnd, "alpha snippet".count)
        XCTAssertEqual(hits.first?.score ?? 0, 1.0, accuracy: 1e-4, "vectors round-trip exactly")
    }

    // MARK: - offset-only: meta.jsonl persists pointers, NEVER raw note text

    func testMetaJsonlPersistsOffsetsWithoutText() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let index = makeIndex(dir)
        // A snippet whose literal text, if persisted, would show up in meta.jsonl.
        let snippet = "SECRET-VAULT-PROSE-should-never-be-on-disk"
        await index.replaceFile(
            notePath: "meetings/m.md", fileContentHash: "fh",
            chunks: [RagChunkMeta(chunkId: "a", notePath: "meetings/m.md",
                                  headingPath: "Design > Risks", charStart: 12,
                                  charEnd: 12 + snippet.count, contentHash: "ch-a")],
            vectors: [l2([1, 0, 0, 0])])
        try await index.persist()

        let metaURL = dir.appendingPathComponent("meta.jsonl")
        let raw = try String(contentsOf: metaURL, encoding: .utf8)

        // The persisted line carries the POINTERS…
        XCTAssertTrue(raw.contains("\"chunk_id\":\"a\""))
        XCTAssertTrue(raw.contains("\"note_path\":\"meetings/m.md\""))
        XCTAssertTrue(raw.contains("\"heading_path\":\"Design > Risks\""))
        XCTAssertTrue(raw.contains("\"char_start\":12"))
        XCTAssertTrue(raw.contains("\"char_end\":\(12 + snippet.count)"))
        XCTAssertTrue(raw.contains("\"content_hash\":\"ch-a\""))
        // …but NEVER the raw note text, nor a `text` key.
        XCTAssertFalse(raw.contains(snippet), "raw note text must NOT be persisted")
        XCTAssertFalse(raw.contains("\"text\""), "meta.jsonl must have no text field")

        // Reload still works (the textless meta decodes fine).
        let reread = makeIndex(dir)
        let outcome = await reread.loadFromDisk()
        guard case .loaded(let count) = outcome else { return XCTFail("expected .loaded, got \(outcome)") }
        XCTAssertEqual(count, 1)
        let hash = await reread.fileContentHash(notePath: "meetings/m.md")
        XCTAssertEqual(hash, "fh", "the recorded whole-file hash round-trips (retrieve staleness gate)")
    }

    func testLoadEmptyDirIsEmptyOutcome() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = makeIndex(dir)
        let outcome = await index.loadFromDisk()
        XCTAssertEqual(outcome, .empty)
    }

    // MARK: - model change ⇒ rebuild

    func testModelRevisionChangeForcesRebuild() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Persist with the original revision.
        let v1 = makeIndex(dir, revision: "rev-OLD")
        await v1.replaceFile(
            notePath: "n.md", fileContentHash: "f",
            chunks: [meta("a", note: "n.md", text: "x")], vectors: [l2([1, 0, 0, 0])])
        try await v1.persist()

        // Open with a DIFFERENT revision → rebuildRequired, index reset to empty.
        let v2 = makeIndex(dir, revision: "rev-NEW")
        let outcome = await v2.loadFromDisk()
        guard case .rebuildRequired(let reason) = outcome else {
            return XCTFail("expected .rebuildRequired, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("model changed"), "reason names the model change")
        let count = await v2.chunkCount
        XCTAssertEqual(count, 0, "incompatible on-disk vectors must NOT be adopted")
    }

    func testModelIdChangeForcesRebuild() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let v1 = RagIndex(dim: dim, modelId: "model-A", modelRevision: "r", dir: dir)
        await v1.replaceFile(notePath: "n.md", fileContentHash: "f",
                             chunks: [meta("a", note: "n.md", text: "x")], vectors: [l2([1, 0, 0, 0])])
        try await v1.persist()

        let v2 = RagIndex(dim: dim, modelId: "model-B", modelRevision: "r", dir: dir)
        let outcome = await v2.loadFromDisk()
        guard case .rebuildRequired = outcome else {
            return XCTFail("expected .rebuildRequired, got \(outcome)")
        }
    }

    // MARK: - incremental: replace / remove / hash gate

    func testReplaceFileSwapsRowsForThatNoteOnly() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = makeIndex(dir)

        await index.replaceFile(notePath: "a.md", fileContentHash: "a1",
                                chunks: [meta("a1", note: "a.md", text: "a one")],
                                vectors: [l2([1, 0, 0, 0])])
        await index.replaceFile(notePath: "b.md", fileContentHash: "b1",
                                chunks: [meta("b1", note: "b.md", text: "b one")],
                                vectors: [l2([0, 1, 0, 0])])
        var count = await index.chunkCount
        XCTAssertEqual(count, 2)

        // Re-index a.md with NEW content (2 chunks). b.md must be untouched.
        await index.replaceFile(notePath: "a.md", fileContentHash: "a2",
                                chunks: [meta("a2", note: "a.md", text: "a two"),
                                         meta("a3", note: "a.md", text: "a three")],
                                vectors: [l2([1, 0, 0, 0]), l2([0.9, 0.1, 0, 0])])
        count = await index.chunkCount
        XCTAssertEqual(count, 3, "a.md's old single chunk dropped, two new added; b.md kept")

        // b.md's chunk still findable.
        let bHits = await index.search(queryVector: l2([0, 1, 0, 0]), k: 1)
        XCTAssertEqual(bHits.first?.meta.chunkId, "b1")
        // a.md's stale chunk is gone.
        let northHits = await index.search(queryVector: l2([1, 0, 0, 0]), k: 3)
        XCTAssertFalse(northHits.contains { $0.meta.chunkId == "a1" }, "stale chunk removed")
    }

    func testRemoveFileDropsRowsAndHash() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = makeIndex(dir)

        await index.replaceFile(notePath: "gone.md", fileContentHash: "g1",
                                chunks: [meta("g", note: "gone.md", text: "bye")],
                                vectors: [l2([1, 0, 0, 0])])
        let before = await index.isFileUnchanged(notePath: "gone.md", fileContentHash: "g1")
        XCTAssertTrue(before)

        await index.removeFile(notePath: "gone.md")
        let count = await index.chunkCount
        XCTAssertEqual(count, 0)
        // Hash gone too → a future appearance is treated as new (false = index it).
        let after = await index.isFileUnchanged(notePath: "gone.md", fileContentHash: "g1")
        XCTAssertFalse(after)
        let paths = await index.indexedNotePaths()
        XCTAssertTrue(paths.isEmpty)
    }

    func testHashGateDetectsUnchangedVsChanged() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = makeIndex(dir)

        await index.replaceFile(notePath: "n.md", fileContentHash: "v1",
                                chunks: [meta("c", note: "n.md", text: "t")],
                                vectors: [l2([1, 0, 0, 0])])
        let sameHash = await index.isFileUnchanged(notePath: "n.md", fileContentHash: "v1")
        let diffHash = await index.isFileUnchanged(notePath: "n.md", fileContentHash: "v2")
        let unseen = await index.isFileUnchanged(notePath: "never-seen.md", fileContentHash: "x")
        XCTAssertTrue(sameHash, "same hash → unchanged → skippable")
        XCTAssertFalse(diffHash, "different hash → changed → re-index")
        XCTAssertFalse(unseen, "unseen note → index it")
    }
}
