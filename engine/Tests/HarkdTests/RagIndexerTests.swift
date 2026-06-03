// RagIndexerTests — coverage for the vault-RAG indexer coordinator (Phase 6 slice
// 4b, ADR-0032/0033): cold build, the content-hash gate (unchanged files skipped),
// incremental change handling (changed file re-indexed, deleted file dropped),
// graceful degradation when the embedder is unavailable, and the OFFSET-ONLY
// retrieve path (text recovered LIVE from the vault at the stored offsets; a note
// deleted or edited since indexing is skipped).
//
// The heavy chunk→embed→store flow is driven with a DETERMINISTIC FAKE embedder
// (no CoreML) so these ALWAYS run — the indexer's coordination logic is what's
// under test, not the embedding quality (that's EmbedderTests' gated on-device
// check). A separate, gated test exercises the REAL embedder end-to-end.
//
// All tests use a UNIQUE temp "vault" + temp index dir — never the real vault,
// never HarkPaths.indexDir(). The vault is treated read-only by the indexer; we
// only WRITE the fixture files ourselves to set up each case.
//
// Privacy: synthetic notes + a fake hashing embedder; no vault data.

import XCTest
import Foundation
@testable import Harkd

// ─── Deterministic fake embedder ─────────────────────────────────────────────
//
// Maps any text to a stable 384-dim L2-normalized vector by hashing the text into
// a few non-zero coordinates. Same text → same vector (so identical chunks rank
// 1.0 against their query); different text → (almost surely) different vector. No
// CoreML, no network — pure, fast, deterministic.

@available(macOS 14.4, *)
struct FakeEmbedder: TextEmbedder {
    let model = EmbedderModels.default   // 384-dim descriptor

    func embed(_ text: String, kind: EmbeddingKind) async throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw TextEmbedderError.emptyInput }
        var v = [Float](repeating: 0, count: 384)
        // Spread a few deterministic non-zero coords from the bytes of the text.
        var h: UInt64 = 1469598103934665603   // FNV-1a offset basis
        for b in trimmed.utf8 {
            h ^= UInt64(b)
            h = h &* 1099511628211
            let idx = Int(h % 384)
            v[idx] += Float((h >> 13) & 0xff) / 255.0 + 0.1
        }
        return CoreMLTextEmbedder.l2Normalized(v)
    }
}

@available(macOS 14.4, *)
final class RagIndexerTests: XCTestCase {

    /// Every indexer made via `makeIndexer`, stopped in tearDown so each FSEvents
    /// watcher's stream is invalidated DURING the run. A live FSEventStream left to
    /// process teardown SIGSEGVs the test binary (all tests pass, exit code 1).
    private var createdIndexers: [RagIndexer] = []

    override func tearDown() async throws {
        for ix in createdIndexers { await ix.stop() }
        createdIndexers.removeAll()
        try await super.tearDown()
    }

    private func tempDir(_ tag: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    private func makeIndexer(vault: URL, indexDir: URL, embedder: TextEmbedder?) -> RagIndexer {
        let model = EmbedderModels.default
        let index = RagIndex(dim: model.dimension, modelId: model.id,
                             modelRevision: model.revision, dir: indexDir)
        // debounce 0 so the (unused-in-these-tests) watcher would fire instantly;
        // we drive `handleDebouncedChanges` directly rather than via FSEvents.
        let indexer = RagIndexer(index: index, embedder: embedder, vaultRoot: vault,
                                 debounceSeconds: 0, statusSink: nil)
        createdIndexers.append(indexer)
        return indexer
    }

    // MARK: - cold build + retrieve

    func testColdBuildIndexesAllMarkdownThenRetrieves() async throws {
        let vault = tempDir("vault")
        let indexDir = tempDir("index")
        defer { try? FileManager.default.removeItem(at: vault); try? FileManager.default.removeItem(at: indexDir) }

        write("# Budget\n\nWe approved the Q2 budget on Friday.", to: vault.appendingPathComponent("meetings/m1.md"))
        write("# Hiring\n\nTwo new engineers start next month.", to: vault.appendingPathComponent("notes/hiring.md"))
        // A non-md file must be ignored.
        write("not a note", to: vault.appendingPathComponent("notes/data.txt"))

        let indexer = makeIndexer(vault: vault, indexDir: indexDir, embedder: FakeEmbedder())
        await indexer.start()

        // Query with the EXACT embed text (breadcrumb + window) → that chunk ranks
        // first (fake embedder maps identical text to an identical vector → 1.0).
        let q = "Budget\n\nWe approved the Q2 budget on Friday."
        let hits = try await indexer.retrieve(query: q, k: 3)
        XCTAssertFalse(hits.isEmpty, "cold build indexed the vault")
        XCTAssertEqual(hits.first?.notePath, "meetings/m1.md")
        // The recovered `text` is sliced LIVE from the vault file at the stored
        // offsets — the window PROSE (no breadcrumb prefix; that's headingPath).
        XCTAssertEqual(hits.first?.text, "We approved the Q2 budget on Friday.",
                       "text recovered from the vault at the indexed offsets")
        XCTAssertEqual(hits.first?.headingPath, "Budget")
        XCTAssertEqual(hits.first?.score ?? 0, 1.0, accuracy: 1e-4)
        // The .txt file was not indexed.
        XCTAssertFalse(hits.contains { $0.notePath.hasSuffix(".txt") })
        await indexer.stop()
    }

    // MARK: - hash gate (unchanged file skipped) + reload

    func testUnchangedFileSkippedOnSecondBuild() async throws {
        let vault = tempDir("vault")
        let indexDir = tempDir("index")
        defer { try? FileManager.default.removeItem(at: vault); try? FileManager.default.removeItem(at: indexDir) }

        let note = vault.appendingPathComponent("n.md")
        write("# H\n\nStable body.", to: note)

        // First build persists the index + the per-file hash.
        let i1 = makeIndexer(vault: vault, indexDir: indexDir, embedder: FakeEmbedder())
        await i1.start(); await i1.stop()

        // A fresh indexer over the SAME index dir loads from disk; the file is
        // unchanged, so the reconcile re-embeds NOTHING (the hash gate). We can't
        // observe the skip directly, but the index must still serve the chunk.
        let i2 = makeIndexer(vault: vault, indexDir: indexDir, embedder: FakeEmbedder())
        await i2.start()
        let hits = try await i2.retrieve(query: "H\n\nStable body.", k: 1)
        XCTAssertEqual(hits.first?.notePath, "n.md", "reloaded index serves the chunk")
        XCTAssertEqual(hits.first?.text, "Stable body.", "text recovered from the vault file")
        await i2.stop()
    }

    // MARK: - incremental: changed / deleted

    func testIncrementalChangedFileReindexed() async throws {
        let vault = tempDir("vault")
        let indexDir = tempDir("index")
        defer { try? FileManager.default.removeItem(at: vault); try? FileManager.default.removeItem(at: indexDir) }

        let note = vault.appendingPathComponent("n.md")
        write("# H\n\nOriginal text here.", to: note)
        let indexer = makeIndexer(vault: vault, indexDir: indexDir, embedder: FakeEmbedder())
        await indexer.start()

        // Edit the file, then drive the debounced-change handler with its path.
        write("# H\n\nCompletely different content now.", to: note)
        await indexer.handleDebouncedChanges([note.path])

        // The NEW content is retrievable; the OLD content no longer ranks 1.0.
        let newHits = try await indexer.retrieve(query: "H\n\nCompletely different content now.", k: 1)
        XCTAssertEqual(newHits.first?.score ?? 0, 1.0, accuracy: 1e-4, "edited content indexed")
        // Recovered from the (re-indexed) vault file — the new prose, sliced at the
        // new offsets, with the hash gate now passing against the edited file.
        XCTAssertEqual(newHits.first?.text, "Completely different content now.")
        await indexer.stop()
    }

    func testIncrementalDeletedFileDropped() async throws {
        let vault = tempDir("vault")
        let indexDir = tempDir("index")
        defer { try? FileManager.default.removeItem(at: vault); try? FileManager.default.removeItem(at: indexDir) }

        let note = vault.appendingPathComponent("temp.md")
        write("# Temp\n\nDelete me soon.", to: note)
        let indexer = makeIndexer(vault: vault, indexDir: indexDir, embedder: FakeEmbedder())
        await indexer.start()

        // Confirm it's indexed.
        var hits = try await indexer.retrieve(query: "Temp\n\nDelete me soon.", k: 3)
        XCTAssertTrue(hits.contains { $0.notePath == "temp.md" })

        // Delete the file on disk, then signal its path as changed → must be dropped.
        try FileManager.default.removeItem(at: note)
        await indexer.handleDebouncedChanges([note.path])

        hits = try await indexer.retrieve(query: "Temp\n\nDelete me soon.", k: 3)
        XCTAssertFalse(hits.contains { $0.notePath == "temp.md" }, "deleted note dropped from index")
        await indexer.stop()
    }

    // MARK: - graceful degradation (no embedder)

    func testNoEmbedderDegradesRetrieve() async {
        let vault = tempDir("vault")
        let indexDir = tempDir("index")
        defer { try? FileManager.default.removeItem(at: vault); try? FileManager.default.removeItem(at: indexDir) }
        write("# H\n\nbody", to: vault.appendingPathComponent("n.md"))

        let indexer = makeIndexer(vault: vault, indexDir: indexDir, embedder: nil)
        await indexer.start()   // must not crash; no build

        do {
            _ = try await indexer.retrieve(query: "anything", k: 3)
            XCTFail("retrieve must throw RagError.unavailable without an embedder")
        } catch RagIndexer.RagError.unavailable {
            // expected — only RAG degraded.
        } catch {
            XCTFail("expected RagError.unavailable, got \(error)")
        }
        await indexer.stop()
    }

    // MARK: - manual rebuild

    func testManualRebuildRepopulatesIndex() async throws {
        let vault = tempDir("vault")
        let indexDir = tempDir("index")
        defer { try? FileManager.default.removeItem(at: vault); try? FileManager.default.removeItem(at: indexDir) }
        write("# A\n\nalpha", to: vault.appendingPathComponent("a.md"))

        let indexer = makeIndexer(vault: vault, indexDir: indexDir, embedder: FakeEmbedder())
        await indexer.start()
        // Add a file AFTER start, then rebuild → it gets picked up.
        write("# B\n\nbeta", to: vault.appendingPathComponent("b.md"))
        await indexer.rebuild()

        let hits = try await indexer.retrieve(query: "B\n\nbeta", k: 1)
        XCTAssertEqual(hits.first?.notePath, "b.md", "rebuild picked up the new file")
        await indexer.stop()
    }

    // MARK: - REAL embedder end-to-end (gated on real hardware)

    /// Full pipeline against the REAL CoreML embedder: index a couple of notes,
    /// retrieve by a semantic (not verbatim) query, assert the relevant note ranks
    /// above an unrelated one. SKIPPED unless HARK_TEST_EMBEDDER=1 (the runner sets
    /// HARK_EMBEDDER_LOCAL_DIR=/tmp/hark-coreml/out). This is the real-hardware
    /// verification step — not a fabricated pass.
    func testRealEmbedderEndToEnd_OnDevice() async throws {
        guard ProcessInfo.processInfo.environment["HARK_TEST_EMBEDDER"] == "1" else {
            throw XCTSkip("on-device RAG e2e skipped: set HARK_TEST_EMBEDDER=1 (+ "
                + "HARK_EMBEDDER_LOCAL_DIR) on real M-series hardware with the converted model.")
        }
        let vault = tempDir("vault")
        let indexDir = tempDir("index")
        defer { try? FileManager.default.removeItem(at: vault); try? FileManager.default.removeItem(at: indexDir) }

        write("# Budget\n\nThe quarterly finance review approved next year's spending plan.",
              to: vault.appendingPathComponent("budget.md"))
        write("# Pets\n\nMy cat enjoys sleeping on the warm windowsill all afternoon.",
              to: vault.appendingPathComponent("pets.md"))

        let loaded = try await loadTextEmbedder()
        let model = loaded.model
        let index = RagIndex(dim: model.dimension, modelId: model.id,
                             modelRevision: model.revision, dir: indexDir)
        let indexer = RagIndexer(index: index, embedder: loaded.embedder,
                                 vaultRoot: vault, debounceSeconds: 0, statusSink: nil)
        await indexer.start()

        // Semantic query (not verbatim) about money → budget.md must outrank pets.md.
        let hits = try await indexer.retrieve(query: "what did we decide about the financial budget?", k: 2)
        XCTAssertEqual(hits.first?.notePath, "budget.md",
                       "semantic retrieval ranks the budget note above the unrelated pet note")
        // Text is recovered live from the vault (offset-only index).
        XCTAssertTrue(hits.first?.text.contains("spending plan") ?? false,
                      "snippet recovered from the vault at the indexed offsets")
        await indexer.stop()
    }

    // MARK: - offset-only retrieve: text recovered from the vault; stale sources skipped

    /// The retrieve path reads each hit's snippet LIVE from the vault file at the
    /// stored offsets — the index holds NO text. Pin that the recovered slice equals
    /// the actual file content at [charStart, charEnd), across two notes.
    func testRetrieveRecoversTextFromVaultAtOffsets() async throws {
        let vault = tempDir("vault")
        let indexDir = tempDir("index")
        defer { try? FileManager.default.removeItem(at: vault); try? FileManager.default.removeItem(at: indexDir) }

        write("# Alpha\n\nThe first note body about migrations.",
              to: vault.appendingPathComponent("a.md"))
        write("# Beta\n\nThe second note body about rollbacks.",
              to: vault.appendingPathComponent("sub/b.md"))

        let indexer = makeIndexer(vault: vault, indexDir: indexDir, embedder: FakeEmbedder())
        await indexer.start()

        let a = try await indexer.retrieve(query: "Alpha\n\nThe first note body about migrations.", k: 1)
        XCTAssertEqual(a.first?.notePath, "a.md")
        XCTAssertEqual(a.first?.text, "The first note body about migrations.")

        let b = try await indexer.retrieve(query: "Beta\n\nThe second note body about rollbacks.", k: 1)
        XCTAssertEqual(b.first?.notePath, "sub/b.md")
        XCTAssertEqual(b.first?.text, "The second note body about rollbacks.")
        await indexer.stop()
    }

    /// A file DELETED between index and retrieve → its chunk is skipped (its content
    /// is gone from the vault and never lingered in the index). The watcher hasn't
    /// run yet (we don't signal the change), so the row is still in the in-memory
    /// index — the retrieve-time vault read is what drops it.
    func testRetrieveSkipsChunkWhenFileDeletedAfterIndex() async throws {
        let vault = tempDir("vault")
        let indexDir = tempDir("index")
        defer { try? FileManager.default.removeItem(at: vault); try? FileManager.default.removeItem(at: indexDir) }

        let note = vault.appendingPathComponent("ghost.md")
        write("# Ghost\n\nSoon to vanish without a watcher tick.", to: note)
        let indexer = makeIndexer(vault: vault, indexDir: indexDir, embedder: FakeEmbedder())
        await indexer.start()

        let q = "Ghost\n\nSoon to vanish without a watcher tick."
        let before = try await indexer.retrieve(query: q, k: 3)
        XCTAssertFalse(before.isEmpty, "indexed before deletion")

        // Delete the file WITHOUT signaling the watcher: the index row survives, but
        // the retrieve-time vault read finds no file → the chunk is skipped.
        try FileManager.default.removeItem(at: note)
        let hits = try await indexer.retrieve(query: q, k: 3)
        XCTAssertTrue(hits.isEmpty, "deleted-since-index chunk skipped (no text lingered to return)")
        await indexer.stop()
    }

    /// A file EDITED between index and retrieve (before the watcher re-indexes) →
    /// its chunks are skipped: the live whole-file hash no longer matches the indexed
    /// one, so the stored offsets are untrustworthy. Better to drop than return a
    /// wrong slice. (Once the watcher re-indexes, the new content is retrievable —
    /// covered by testIncrementalChangedFileReindexed.)
    func testRetrieveSkipsChunkWhenFileChangedAfterIndex() async throws {
        let vault = tempDir("vault")
        let indexDir = tempDir("index")
        defer { try? FileManager.default.removeItem(at: vault); try? FileManager.default.removeItem(at: indexDir) }

        let note = vault.appendingPathComponent("edited.md")
        write("# Edit\n\nOriginal body that was indexed.", to: note)
        let indexer = makeIndexer(vault: vault, indexDir: indexDir, embedder: FakeEmbedder())
        await indexer.start()

        let q = "Edit\n\nOriginal body that was indexed."
        let before = try await indexer.retrieve(query: q, k: 3)
        XCTAssertFalse(before.isEmpty, "indexed before the edit")

        // Edit the file WITHOUT signaling the watcher: the index still holds the old
        // offsets + old whole-file hash; the live hash now differs → skip the chunk.
        write("# Edit\n\nThis body was changed AFTER indexing and is much longer than before.", to: note)
        let hits = try await indexer.retrieve(query: q, k: 3)
        XCTAssertTrue(hits.isEmpty, "changed-since-index chunk skipped (stale offsets not trusted)")
        await indexer.stop()
    }
}
