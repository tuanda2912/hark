// RagChunkerTests — coverage for the vault-RAG chunker (Phase 6 slice 4b,
// ADR-0032/0033). PURE logic, always runs (no embedder, no filesystem): the
// chunker is value→value, so we drive it with literal markdown and assert on the
// produced chunks.
//
// What these pin:
//   - front-matter is stripped to metadata (title/date/tags) and NOT embedded;
//   - heading-aware split carries a "H1 > H2" breadcrumb, prepended to each window;
//   - long sections split into overlapping windows; short ones stay one window;
//   - char offsets point into the ORIGINAL file (front-matter accounted for);
//   - chunkId is stable + content-addressed (same bytes → same id; changed → new).
//
// Privacy: synthetic markdown only; no vault data.

import XCTest
@testable import Harkd

@available(macOS 14.4, *)
final class RagChunkerTests: XCTestCase {

    // MARK: - front-matter

    func testFrontMatterIsParsedAndStrippedNotEmbedded() {
        let md = """
            ---
            title: Q2 Planning
            date: 2026-06-01T14:32:07+07:00
            tags: [planning, budget]
            ---

            # Goals

            Ship the thing by Friday.
            """
        let (chunks, fm) = RagChunker.chunk(notePath: "notes/plan.md", rawMarkdown: md)
        XCTAssertEqual(fm.title, "Q2 Planning")
        XCTAssertEqual(fm.date, "2026-06-01T14:32:07+07:00")
        XCTAssertEqual(fm.tags, ["planning", "budget"])
        // The YAML keys must NOT appear in any embeddable chunk text.
        for c in chunks {
            XCTAssertFalse(c.text.contains("title:"), "front-matter key leaked into chunk")
            XCTAssertFalse(c.text.contains("tags:"), "front-matter key leaked into chunk")
        }
        XCTAssertTrue(chunks.contains { $0.text.contains("Ship the thing by Friday.") })
    }

    func testBlockListTagsForm() {
        let md = """
            ---
            title: Note
            tags:
              - alpha
              - beta
            ---

            Body here.
            """
        let (_, fm) = RagChunker.chunk(notePath: "n.md", rawMarkdown: md)
        XCTAssertEqual(fm.tags, ["alpha", "beta"])
    }

    func testNoFrontMatterIndexesWholeBody() {
        let md = "Just a plain note with no front matter at all."
        let (chunks, fm) = RagChunker.chunk(notePath: "n.md", rawMarkdown: md)
        XCTAssertNil(fm.title)
        XCTAssertEqual(fm.tags, [])
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].charStart, 0, "no front-matter → body starts at 0")
        XCTAssertTrue(chunks[0].text.contains("plain note"))
    }

    // MARK: - heading-aware split + breadcrumb

    func testHeadingBreadcrumbIsPrependedToWindows() {
        let md = """
            # Design

            Top-level design prose.

            ## Risks

            The main risk is scope creep.

            ### Mitigation

            Cut features early.
            """
        let (chunks, _) = RagChunker.chunk(notePath: "n.md", rawMarkdown: md)

        // Section under "Design" carries "Design".
        let design = chunks.first { $0.text.contains("Top-level design prose.") }
        XCTAssertNotNil(design)
        XCTAssertEqual(design?.headingPath, "Design")
        XCTAssertTrue(design!.text.hasPrefix("Design\n\n"), "breadcrumb prepended")

        // "Risks" nests under "Design".
        let risks = chunks.first { $0.text.contains("scope creep") }
        XCTAssertEqual(risks?.headingPath, "Design > Risks")

        // "Mitigation" nests under "Design > Risks".
        let mit = chunks.first { $0.text.contains("Cut features early.") }
        XCTAssertEqual(mit?.headingPath, "Design > Risks > Mitigation")
    }

    func testSiblingHeadingPopsStack() {
        let md = """
            # A

            ## B

            under b

            ## C

            under c
            """
        let (chunks, _) = RagChunker.chunk(notePath: "n.md", rawMarkdown: md)
        let b = chunks.first { $0.text.contains("under b") }
        let c = chunks.first { $0.text.contains("under c") }
        XCTAssertEqual(b?.headingPath, "A > B")
        XCTAssertEqual(c?.headingPath, "A > C", "sibling H2 must pop B, not nest under it")
    }

    func testHeadingParserRejectsNonHeadings() {
        XCTAssertNil(RagChunker.headingOf("#tag-no-space"))
        XCTAssertNil(RagChunker.headingOf("not a heading"))
        XCTAssertNil(RagChunker.headingOf("####### too many"))   // 7 hashes
        XCTAssertEqual(RagChunker.headingOf("## Risks")?.level, 2)
        XCTAssertEqual(RagChunker.headingOf("## Risks")?.title, "Risks")
        XCTAssertEqual(RagChunker.headingOf("# Top")?.level, 1)
    }

    func testFenceContentNotTreatedAsHeading() {
        let md = """
            # Code

            ```
            # this is a shell comment, not a heading
            echo hi
            ```

            after code
            """
        let (chunks, _) = RagChunker.chunk(notePath: "n.md", rawMarkdown: md)
        // Everything stays under "Code" — the `#` inside the fence didn't open a section.
        for c in chunks {
            XCTAssertEqual(c.headingPath, "Code")
        }
        XCTAssertTrue(chunks.contains { $0.text.contains("shell comment") })
        XCTAssertTrue(chunks.contains { $0.text.contains("after code") })
    }

    // MARK: - window packing + overlap

    func testLongSectionSplitsIntoOverlappingWindows() {
        // Build a section well over targetChars so it must split into ≥2 windows.
        let sentence = "This is a reasonably long sentence about the project status. "
        let big = String(repeating: sentence, count: 80)   // ~4800 chars >> 1600
        let md = "# Notes\n\n" + big
        let (chunks, _) = RagChunker.chunk(notePath: "n.md", rawMarkdown: md)

        XCTAssertGreaterThan(chunks.count, 1, "a long section must split")
        // Each window is bounded near the target (allow boundary slack).
        for c in chunks {
            XCTAssertLessThanOrEqual(c.text.count, RagChunker.targetChars + RagChunker.targetChars / 5 + 16)
        }
        // Overlap: consecutive windows of the same section should share text. The
        // second window's start char offset must be < the first window's end offset.
        XCTAssertLessThan(chunks[1].charStart, chunks[0].charEnd,
                          "consecutive windows overlap in the source")
    }

    func testShortSectionIsSingleWindow() {
        let md = "# Tiny\n\nShort body."
        let (chunks, _) = RagChunker.chunk(notePath: "n.md", rawMarkdown: md)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].headingPath, "Tiny")
    }

    // MARK: - char offsets point into the original file

    func testCharOffsetsLocateChunkInOriginal() {
        let md = """
            ---
            title: T
            ---

            # H

            Locate me.
            """
        let (chunks, _) = RagChunker.chunk(notePath: "n.md", rawMarkdown: md)
        let chars = Array(md)
        let c = chunks.first { $0.text.contains("Locate me.") }!
        // The original substring at [charStart, charEnd) must be the prose the
        // chunk wraps (without the breadcrumb, which is prepended to `text` only).
        let original = String(chars[c.charStart..<c.charEnd])
        XCTAssertTrue(original.contains("Locate me."),
                      "char offsets must point at the prose in the ORIGINAL file")
        XCTAssertFalse(original.contains("title:"), "offsets must be past the front-matter")
    }

    // MARK: - stable chunk ids

    func testChunkIdIsStableForSameContent() {
        let md = "# H\n\nStable content."
        let (a, _) = RagChunker.chunk(notePath: "n.md", rawMarkdown: md)
        let (b, _) = RagChunker.chunk(notePath: "n.md", rawMarkdown: md)
        XCTAssertEqual(a.map(\.chunkId), b.map(\.chunkId), "same input → same ids")
    }

    func testChunkIdChangesWhenContentChanges() {
        let (a, _) = RagChunker.chunk(notePath: "n.md", rawMarkdown: "# H\n\nVersion one.")
        let (b, _) = RagChunker.chunk(notePath: "n.md", rawMarkdown: "# H\n\nVersion two.")
        XCTAssertNotEqual(a.first?.chunkId, b.first?.chunkId, "changed content → new id")
        // contentHash also differs.
        XCTAssertNotEqual(a.first?.contentHash, b.first?.contentHash)
    }

    func testChunkIdDiffersByNotePath() {
        let body = "# H\n\nSame text."
        let (a, _) = RagChunker.chunk(notePath: "a.md", rawMarkdown: body)
        let (b, _) = RagChunker.chunk(notePath: "b.md", rawMarkdown: body)
        XCTAssertNotEqual(a.first?.chunkId, b.first?.chunkId, "id is scoped to notePath")
    }

    // MARK: - empty / whitespace-only notes

    func testEmptyNoteProducesNoChunks() {
        let (chunks, _) = RagChunker.chunk(notePath: "n.md", rawMarkdown: "")
        XCTAssertTrue(chunks.isEmpty)
    }

    func testHeadingOnlyNoteProducesNoChunks() {
        // A heading with no prose under it carries no embeddable body.
        let (chunks, _) = RagChunker.chunk(notePath: "n.md", rawMarkdown: "# Just A Heading\n")
        XCTAssertTrue(chunks.isEmpty, "a heading with no body has nothing to embed")
    }
}
