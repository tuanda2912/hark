// RagIndex — brute-force in-memory cosine vector store for vault RAG, persisted as
// a flat file set under HarkPaths.indexDir() (Phase 6 slice 4b, ADR-0032/0033).
//
// WHY brute force: at ≤50k chunks (a large personal vault) a single-pass dot
// product over pre-normalized 384-dim vectors is <80 ms on an M-series core — well
// inside an interactive search budget. An ANN index (HNSW/FAISS) is a dependency +
// tuning surface we don't need yet (ADR-0033). When the vault outgrows this, the
// `search` interface stays; only the internals change.
//
// WHY an actor: the index holds mutable state (the vector matrix + metadata) and is
// touched by TWO concurrent producers — the background indexer (FSEvents-driven
// re-index) and the foreground `rag.retrieve` query path. The actor is the single
// owner that serializes them without locks. Java analogue: a `@Service` whose state
// is auto-synchronized; callers `await` its methods like Kotlin coroutines. Disk I/O
// (persist/load) runs ON the actor — it's off the live AUDIO/ASR path entirely, so a
// blocking write here never touches transcription latency.
//
// On-disk layout (HarkPaths.indexDir()):
//   vectors.bin   — contiguous little-endian Float32, `dim` floats per chunk, in
//                   the SAME order as meta.jsonl. Row i = meta line i's vector.
//   meta.jsonl    — one JSON object per line: OFFSETS + POINTERS ONLY (chunkId,
//                   notePath, headingPath, charStart, charEnd, contentHash). NO raw
//                   note text. Parallel to vectors.bin.
//   manifest.json — modelId, modelRevision, dim, schemaVersion, chunkCount, and
//                   perFileContentHashes (notePath → whole-file SHA-256) for the
//                   incremental change-gate.
//
// Privacy (rule #2, OFFSET-ONLY decision 2026-06-03): all three files live ONLY in
// app-support, never the vault — AND they never contain raw note text. The index is
// pure vectors + pointers (notePath + char offsets + content hash). The chunk text
// is fetched LIVE from the vault at retrieve time (see RagIndexer.retrieve), so
// deleting a note from the vault removes its content entirely — nothing lingers in
// this cache. This file NEVER logs chunk text (there is none here to log).

import Foundation

/// Per-chunk metadata persisted to meta.jsonl, parallel to a vectors.bin row.
/// `Codable` with explicit snake_case keys so the on-disk form is stable and
/// human-inspectable (and matches the wire field names 4c mirrors). OFFSET-ONLY: it
/// holds the POINTER to the chunk's source (notePath + charStart/charEnd) and a
/// `contentHash` to detect a stale offset — but NEVER the raw note text. The text is
/// read live from the vault at retrieve time (RagIndexer.retrieve), so no vault
/// content is persisted outside the vault.
struct RagChunkMeta: Codable, Sendable, Equatable {
    let chunkId: String
    let notePath: String
    let headingPath: String
    let charStart: Int
    let charEnd: Int
    /// SHA-256 (hex) of the chunk's embed text. Used at retrieve time as a
    /// staleness gate: if the live file's whole-file hash no longer matches the
    /// note's recorded hash, the stored offsets may point at moved text, so the
    /// chunk is skipped rather than risk returning the wrong slice.
    let contentHash: String

    enum CodingKeys: String, CodingKey {
        case chunkId = "chunk_id"
        case notePath = "note_path"
        case headingPath = "heading_path"
        case charStart = "char_start"
        case charEnd = "char_end"
        case contentHash = "content_hash"
    }
}

/// The index manifest. `schemaVersion` lets a future on-disk layout change force a
/// rebuild; `modelId`/`modelRevision` make a model swap force a rebuild (vectors
/// from a different model live in a different space — mixing them is meaningless).
/// `perFileContentHashes` is the incremental change-gate: a file whose whole-file
/// hash is unchanged is skipped on a watcher event.
struct RagManifest: Codable, Sendable, Equatable {
    var modelId: String
    var modelRevision: String
    var dim: Int
    var schemaVersion: Int
    var chunkCount: Int
    var perFileContentHashes: [String: String]   // notePath → whole-file SHA-256

    enum CodingKeys: String, CodingKey {
        case modelId = "model_id"
        case modelRevision = "model_revision"
        case dim
        case schemaVersion = "schema_version"
        case chunkCount = "chunk_count"
        case perFileContentHashes = "per_file_content_hashes"
    }

    // v2: offset-only meta.jsonl — the `text` field was removed (decision
    // 2026-06-03). A v1 index on disk (with text) is incompatible and rebuilds.
    static let currentSchemaVersion = 2
}

/// A single search hit: the chunk's (textless) metadata + its cosine score against
/// the query. This is the index-layer result — pure vectors/pointers, NO text.
struct RagSearchHit: Sendable, Equatable {
    let meta: RagChunkMeta
    let score: Float
}

/// A retrieve-layer result: a hit whose `text` has been recovered LIVE from the
/// vault at the stored offsets (RagIndexer.retrieve). This is where note text
/// re-enters the picture — never from the persisted index. `text` is the window
/// prose sliced from the note body `[charStart, charEnd)`; the breadcrumb is carried
/// separately in `headingPath` (the UI renders it above the snippet). Only chunks
/// whose source file still exists AND still hashes to its indexed value appear here;
/// missing/changed sources are dropped by the retrieve path.
struct RagRetrievedChunk: Sendable, Equatable {
    let text: String
    let notePath: String
    let headingPath: String
    let charStart: Int
    let charEnd: Int
    let score: Float
}

@available(macOS 14.4, *)
actor RagIndex {
    /// Vector dimension (384 for every v1 curated model — fixed index schema).
    let dim: Int
    private let modelId: String
    private let modelRevision: String

    /// On-disk file URLs (under HarkPaths.indexDir(), injectable for tests).
    private let dir: URL
    private var vectorsURL: URL { dir.appendingPathComponent("vectors.bin") }
    private var metaURL: URL { dir.appendingPathComponent("meta.jsonl") }
    private var manifestURL: URL { dir.appendingPathComponent("manifest.json") }

    // ─── In-memory state ────────────────────────────────────────────────────
    //
    // The vector matrix is ONE contiguous `[Float]` (chunkCount × dim) rather than
    // an array-of-arrays: a flat buffer keeps the search hot loop cache-friendly
    // and matches the on-disk vectors.bin byte-for-byte (a memcpy round-trip). The
    // `metas` array is parallel: metas[i] ↔ vectors[i*dim ..< (i+1)*dim].
    private var vectors: [Float] = []
    private var metas: [RagChunkMeta] = []
    private var perFileContentHashes: [String: String] = [:]

    var chunkCount: Int { metas.count }

    init(dim: Int, modelId: String, modelRevision: String, dir: URL) {
        self.dim = dim
        self.modelId = modelId
        self.modelRevision = modelRevision
        self.dir = dir
    }

    // ─── Open / load / rebuild gating ─────────────────────────────────────────

    /// Outcome of `loadFromDisk`: did we adopt an existing index, or must the
    /// caller cold-build? `.rebuildRequired` carries WHY (for the log) — the index
    /// is left EMPTY in that case so the indexer re-populates from the vault.
    enum LoadOutcome: Equatable {
        case loaded(chunkCount: Int)
        case empty                         // no index on disk yet → cold build
        case rebuildRequired(reason: String)
    }

    /// Load the persisted index from disk IF it's compatible. Compatibility:
    ///   - manifest present + parseable
    ///   - schemaVersion matches
    ///   - modelId AND modelRevision match the CURRENT embedder (a different model
    ///     ⇒ incompatible vectors ⇒ rebuild — the explicit ADR-0033 requirement)
    ///   - dim matches
    ///   - vectors.bin byte length == chunkCount × dim × 4
    /// On any mismatch we DON'T adopt the on-disk vectors (they'd corrupt search);
    /// we reset to empty and return `.rebuildRequired` so the indexer rebuilds.
    func loadFromDisk() -> LoadOutcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: manifestURL.path) else { return .empty }

        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(RagManifest.self, from: manifestData) else {
            reset()
            return .rebuildRequired(reason: "manifest unreadable")
        }
        if manifest.schemaVersion != RagManifest.currentSchemaVersion {
            reset()
            return .rebuildRequired(reason: "schema \(manifest.schemaVersion) != \(RagManifest.currentSchemaVersion)")
        }
        if manifest.modelId != modelId || manifest.modelRevision != modelRevision {
            // The headline ADR-0033 rule: vectors from a different model are
            // incompatible. Full rebuild. (Logged by the caller with both ids.)
            reset()
            return .rebuildRequired(reason: "model changed (\(manifest.modelId)@\(manifest.modelRevision) → \(modelId)@\(modelRevision))")
        }
        if manifest.dim != dim {
            reset()
            return .rebuildRequired(reason: "dim \(manifest.dim) != \(dim)")
        }

        // Parse meta.jsonl (one JSON object per non-empty line).
        guard let metaData = try? Data(contentsOf: metaURL),
              let metaText = String(data: metaData, encoding: .utf8) else {
            reset()
            return .rebuildRequired(reason: "meta.jsonl unreadable")
        }
        let dec = JSONDecoder()
        var loadedMetas: [RagChunkMeta] = []
        for line in metaText.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let m = try? dec.decode(RagChunkMeta.self, from: Data(line.utf8)) else {
                reset()
                return .rebuildRequired(reason: "meta.jsonl line parse failed")
            }
            loadedMetas.append(m)
        }

        // Load vectors.bin and validate its length against the meta count.
        guard let vecData = try? Data(contentsOf: vectorsURL) else {
            reset()
            return .rebuildRequired(reason: "vectors.bin unreadable")
        }
        let expectedFloats = loadedMetas.count * dim
        guard vecData.count == expectedFloats * MemoryLayout<Float32>.size else {
            reset()
            return .rebuildRequired(reason: "vectors.bin length mismatch (\(vecData.count) bytes, expected \(expectedFloats * 4))")
        }
        var loadedVectors = [Float](repeating: 0, count: expectedFloats)
        loadedVectors.withUnsafeMutableBytes { dst in
            _ = vecData.copyBytes(to: dst)
        }

        self.metas = loadedMetas
        self.vectors = loadedVectors
        self.perFileContentHashes = manifest.perFileContentHashes
        return .loaded(chunkCount: loadedMetas.count)
    }

    /// Drop all in-memory state. (Disk files are overwritten on the next persist.)
    func reset() {
        vectors.removeAll(keepingCapacity: false)
        metas.removeAll(keepingCapacity: false)
        perFileContentHashes.removeAll(keepingCapacity: false)
    }

    // ─── Mutation ───────────────────────────────────────────────────────────

    /// Replace ALL chunks for one note. Removes the note's existing rows, appends
    /// the new ones, and records the note's whole-file hash for the change-gate.
    /// `vectorsByChunk[i]` is the embedding for `chunks[i]` (same order, each
    /// `dim`-long, already L2-normalized by the embedder). A length mismatch is a
    /// programming error — we assert and skip rather than corrupt the matrix.
    func replaceFile(notePath: String, fileContentHash: String,
                     chunks: [RagChunkMeta], vectors vectorsByChunk: [[Float]]) {
        guard chunks.count == vectorsByChunk.count else {
            assertionFailure("RagIndex.replaceFile: chunks/vectors count mismatch")
            return
        }
        removeFileRows(notePath: notePath)
        for (i, meta) in chunks.enumerated() {
            let v = vectorsByChunk[i]
            guard v.count == dim else {
                assertionFailure("RagIndex.replaceFile: vector dim \(v.count) != \(dim)")
                continue
            }
            metas.append(meta)
            vectors.append(contentsOf: v)
        }
        perFileContentHashes[notePath] = fileContentHash
    }

    /// Remove all chunks belonging to a note (deleted file, or pre-cleanup before
    /// re-index). Drops the note's hash too. Rebuilds the flat matrix without the
    /// removed rows — O(n) but off the live path.
    func removeFile(notePath: String) {
        removeFileRows(notePath: notePath)
        perFileContentHashes.removeValue(forKey: notePath)
    }

    /// True when the note's whole-file hash matches what we last indexed — i.e. the
    /// file is unchanged and the watcher can SKIP it (the content-hash gate). A note
    /// we've never seen returns false (index it).
    func isFileUnchanged(notePath: String, fileContentHash: String) -> Bool {
        perFileContentHashes[notePath] == fileContentHash
    }

    /// The whole-file hash recorded for a note at index time, or nil if the note
    /// isn't in the index. The retrieve path uses this as a staleness gate: a hit's
    /// stored char offsets are only honored when the live file's hash still matches
    /// the recorded one (otherwise the file was edited since indexing and the offsets
    /// could slice the wrong text → skip the chunk).
    func fileContentHash(notePath: String) -> String? {
        perFileContentHashes[notePath]
    }

    /// The set of notePaths currently represented in the index — used by the cold
    /// build / full rebuild to prune notes that vanished from the vault while the
    /// engine was down (FSEvents only reports live changes, not deletions-while-off).
    func indexedNotePaths() -> Set<String> {
        Set(perFileContentHashes.keys)
    }

    private func removeFileRows(notePath: String) {
        guard metas.contains(where: { $0.notePath == notePath }) else { return }
        var newMetas: [RagChunkMeta] = []
        var newVectors: [Float] = []
        newMetas.reserveCapacity(metas.count)
        newVectors.reserveCapacity(vectors.count)
        for (i, m) in metas.enumerated() where m.notePath != notePath {
            newMetas.append(m)
            let base = i * dim
            newVectors.append(contentsOf: vectors[base..<(base + dim)])
        }
        metas = newMetas
        vectors = newVectors
    }

    // ─── Search ───────────────────────────────────────────────────────────────

    /// Brute-force top-K cosine search. The query vector is L2-normalized and so are
    /// the stored vectors, so cosine == dot product — one multiply-accumulate per
    /// dimension per chunk, no per-row normalization. Returns the K highest-scoring
    /// chunks, score-descending. `k <= 0` or an empty index returns [].
    ///
    /// The score loop is the PURE `Self.topK` (no actor state) so the unit test can
    /// drive ranking against a literal matrix — the live path and the test share one
    /// definition of "rank by dot product."
    func search(queryVector: [Float], k: Int) -> [RagSearchHit] {
        guard k > 0, !metas.isEmpty, queryVector.count == dim else { return [] }
        let ranked = Self.topK(query: queryVector, vectors: vectors, dim: dim, count: metas.count, k: k)
        return ranked.map { RagSearchHit(meta: metas[$0.index], score: $0.score) }
    }

    /// PURE top-K over a flat `[Float]` matrix (count × dim). Dot product per row
    /// (vectors pre-normalized ⇒ dot == cosine), partial-selection of the K best.
    /// Stable: ties keep the lower row index (earlier-indexed chunk). No I/O, no
    /// actor state — unit-tested directly.
    static func topK(query: [Float], vectors: [Float], dim: Int, count: Int, k: Int)
        -> [(index: Int, score: Float)] {
        guard k > 0, count > 0, query.count == dim else { return [] }
        var scored: [(index: Int, score: Float)] = []
        scored.reserveCapacity(count)
        query.withUnsafeBufferPointer { q in
            vectors.withUnsafeBufferPointer { v in
                for row in 0..<count {
                    let base = row * dim
                    var dot: Float = 0
                    for d in 0..<dim { dot += q[d] * v[base + d] }
                    scored.append((row, dot))
                }
            }
        }
        // Sort by score desc, ties → lower index (stable order for determinism).
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return Array(scored.prefix(k))
    }

    // ─── Persist (atomic) ───────────────────────────────────────────────────

    /// Write the full index to disk atomically. Each file is written to a temp path
    /// then renamed (`Data.write(.atomic)` does temp-then-rename on the same volume),
    /// so a crash mid-write never leaves a half-written index that loadFromDisk would
    /// adopt — worst case the old (consistent) files survive, and the manifest is
    /// written LAST so a partial vectors/meta is never blessed by a fresh manifest.
    ///
    /// Runs ON the actor (off the live audio path). Throws on a real I/O failure so
    /// the caller can log it; an index write failure only degrades RAG, never
    /// transcription.
    func persist() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // vectors.bin — raw little-endian Float32 bytes of the flat matrix.
        let vecData = vectors.withUnsafeBufferPointer { Data(buffer: $0) }
        try vecData.write(to: vectorsURL, options: .atomic)

        // meta.jsonl — one compact JSON object per line.
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        var metaBuf = Data()
        for m in metas {
            metaBuf.append(try enc.encode(m))
            metaBuf.append(0x0a)   // '\n'
        }
        try metaBuf.write(to: metaURL, options: .atomic)

        // manifest.json LAST — it blesses the pair above as consistent.
        let manifest = RagManifest(
            modelId: modelId,
            modelRevision: modelRevision,
            dim: dim,
            schemaVersion: RagManifest.currentSchemaVersion,
            chunkCount: metas.count,
            perFileContentHashes: perFileContentHashes)
        let manifestEnc = JSONEncoder()
        manifestEnc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try manifestEnc.encode(manifest).write(to: manifestURL, options: .atomic)
    }
}
