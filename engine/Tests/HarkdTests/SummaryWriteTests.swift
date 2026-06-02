// SummaryWriteTests — coverage for the `summary.write` persistence path
// (VaultWriter.mergeSummarySection + VaultWriter.appendSummary) and the
// SummaryWriteCommand wire decode (ADR-0031 §6).
//
// Context: the meeting summary is generated in the Electron main process (the
// egress chokepoint, ADR-0029); the ENGINE only persists the text it's handed
// into the most-recently-saved meeting's `.md` under a `## Summary` section +
// local git-commit. There is NO model call here — pure read-modify-write.
//
// The section merge is the PURE `mergeSummarySection` (driven directly, no
// reimplementation, so the live `summary.write` handler and this suite share one
// definition of "append or replace the summary"). The filesystem read-modify-write
// (`appendSummary`) is exercised against a temp file — we never touch the real
// vault, and we don't assert on git (commit is best-effort, off in a non-repo temp
// dir; the `.md` is the durable part).

import XCTest
@testable import Harkd

@available(macOS 14.4, *)
final class SummaryWriteTests: XCTestCase {

    // A minimal but realistic meeting body: front-matter + a `## Transcript`
    // section, exactly the shape VaultWriter.write produces (no `## Summary` yet).
    private let transcriptBody = """
        ---
        title: Meeting 2026-06-02 14:32
        date: 2026-06-02T14:32:07+07:00
        duration_sec: 120
        attendees: [Speaker 1, Speaker 2]
        bookmarks: 0
        hark_version: 0.1.0
        ---

        ## Transcript

        > **Speaker 1** · 14:32:07
        > Hello there.

        > **Speaker 2** · 14:32:12
        > General Kenobi.

        """

    // MARK: - (a) append when absent

    func testAppendsSummaryWhenAbsent() {
        let merged = VaultWriter.mergeSummarySection(into: transcriptBody, summary: "We agreed to ship Friday.")

        // The heading exists exactly once, the body is present, and the original
        // transcript content is untouched.
        XCTAssertEqual(occurrences(of: "## Summary", in: merged), 1, "exactly one Summary heading")
        XCTAssertTrue(merged.contains("## Summary\n\nWe agreed to ship Friday.\n"),
                      "heading + blank line + body shape")
        XCTAssertTrue(merged.contains("## Transcript"), "transcript section preserved")
        XCTAssertTrue(merged.contains("> **Speaker 1** · 14:32:07"), "transcript body preserved")

        // The summary section comes AFTER the transcript (append, not prepend).
        let tIdx = merged.range(of: "## Transcript")!.lowerBound
        let sIdx = merged.range(of: "## Summary")!.lowerBound
        XCTAssertTrue(tIdx < sIdx, "summary is appended after existing content")

        // Exactly one trailing newline.
        XCTAssertTrue(merged.hasSuffix("\n"))
        XCTAssertFalse(merged.hasSuffix("\n\n"), "no doubled trailing newline")
    }

    // MARK: - (b) replace when present (idempotent re-summarize)

    func testReplacesSummaryWhenPresentNoDuplicate() {
        let first = VaultWriter.mergeSummarySection(into: transcriptBody, summary: "First summary.")
        // Re-summarize the SAME file (now carrying a `## Summary`).
        let second = VaultWriter.mergeSummarySection(into: first, summary: "Revised, better summary.")

        XCTAssertEqual(occurrences(of: "## Summary", in: second), 1,
                       "re-summarize must NOT duplicate the heading")
        XCTAssertTrue(second.contains("Revised, better summary."), "new body is present")
        XCTAssertFalse(second.contains("First summary."), "old body is replaced, not stacked")
        // Transcript section still intact above the summary.
        XCTAssertTrue(second.contains("## Transcript"))
        XCTAssertTrue(second.contains("> **Speaker 2** · 14:32:12"))
    }

    /// Idempotent in the strict sense: merging the SAME summary twice is a no-op on
    /// the second pass (byte-for-byte stable output).
    func testMergeIsStableForSameSummary() {
        let once = VaultWriter.mergeSummarySection(into: transcriptBody, summary: "Stable summary.")
        let twice = VaultWriter.mergeSummarySection(into: once, summary: "Stable summary.")
        XCTAssertEqual(once, twice, "merging the same summary again changes nothing")
    }

    // MARK: - (c) markdown shape: heading + body

    func testSummarySectionShape() {
        let merged = VaultWriter.mergeSummarySection(
            into: transcriptBody,
            summary: "  Decision: adopt plan B.  \n\n")  // surrounding whitespace gets trimmed

        // `## Summary`, one blank line, then the trimmed body, then a newline.
        XCTAssertTrue(merged.contains("## Summary\n\nDecision: adopt plan B.\n"),
                      "body trimmed of surrounding whitespace, single blank line after heading")
    }

    /// A multi-line / multi-paragraph summary body is preserved verbatim under one
    /// heading (the body can itself contain blank lines and bullet lists).
    func testMultiLineSummaryBodyPreserved() {
        let body = "Key points:\n\n- Ship Friday\n- Owner: Alice\n\nRisks: none."
        let merged = VaultWriter.mergeSummarySection(into: transcriptBody, summary: body)
        XCTAssertEqual(occurrences(of: "## Summary", in: merged), 1)
        XCTAssertTrue(merged.contains("- Ship Friday\n- Owner: Alice"), "bullet list preserved")
        XCTAssertTrue(merged.contains("Risks: none."), "trailing paragraph preserved")
    }

    /// Replacement is bounded by the NEXT top-level heading: a section AFTER the
    /// summary survives a re-summarize untouched (we only swap the summary's body).
    func testFollowingSectionSurvivesReplace() {
        let withTrailing = transcriptBody
            + "\n## Summary\n\nOld summary.\n\n## Action Items\n\n- Do the thing.\n"
        let merged = VaultWriter.mergeSummarySection(into: withTrailing, summary: "New summary.")

        XCTAssertEqual(occurrences(of: "## Summary", in: merged), 1)
        XCTAssertTrue(merged.contains("New summary."), "summary body replaced")
        XCTAssertFalse(merged.contains("Old summary."), "old summary body gone")
        XCTAssertTrue(merged.contains("## Action Items"), "trailing section heading survives")
        XCTAssertTrue(merged.contains("- Do the thing."), "trailing section body survives")
        // Order: Transcript < Summary < Action Items.
        let t = merged.range(of: "## Transcript")!.lowerBound
        let s = merged.range(of: "## Summary")!.lowerBound
        let a = merged.range(of: "## Action Items")!.lowerBound
        XCTAssertTrue(t < s && s < a, "section order preserved")
    }

    /// A `### Summary` subheading (or a `## Summary` quoted inside the transcript
    /// body) must NOT be mistaken for the section heading — append, don't corrupt.
    func testSubheadingDoesNotMatchSectionHeading() {
        let withDecoy = transcriptBody + "\n> **Speaker 1** · 14:33:00\n> Quoting: ## Summary of last week.\n"
        let merged = VaultWriter.mergeSummarySection(into: withDecoy, summary: "Real summary.")
        // The real `## Summary` (column-0 heading) is appended; the quoted text,
        // which is prefixed by "> ", is left in place.
        XCTAssertEqual(occurrences(of: "\n## Summary", in: "\n" + merged), 1,
                       "exactly one column-0 Summary heading")
        XCTAssertTrue(merged.contains("Quoting: ## Summary of last week."),
                      "the quoted decoy text is untouched")
        XCTAssertTrue(merged.contains("Real summary."))
    }

    // MARK: - (d) appendSummary read-modify-write against a temp file

    func testAppendSummaryWritesToFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-summary-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data(transcriptBody.utf8).write(to: tmp, options: .atomic)

        let writer = VaultWriter()
        // Append.
        let r1 = try writer.appendSummary(to: tmp, summary: "First.",
                                          commitMessage: "docs(meeting): summary for test")
        XCTAssertEqual(r1.fileURL.path, tmp.path, "writes the meeting's OWN file in place")
        var disk = try String(contentsOf: tmp, encoding: .utf8)
        XCTAssertEqual(occurrences(of: "## Summary", in: disk), 1)
        XCTAssertTrue(disk.contains("First."))

        // Replace (re-summarize the same file) — idempotent, no duplicate heading.
        _ = try writer.appendSummary(to: tmp, summary: "Second.",
                                     commitMessage: "docs(meeting): summary for test")
        disk = try String(contentsOf: tmp, encoding: .utf8)
        XCTAssertEqual(occurrences(of: "## Summary", in: disk), 1, "still one heading after replace")
        XCTAssertTrue(disk.contains("Second."))
        XCTAssertFalse(disk.contains("First."), "old summary replaced on disk")
        XCTAssertTrue(disk.contains("## Transcript"), "transcript intact after both writes")
    }

    // MARK: - (e) wire decode: SummaryWriteCommand

    func testSummaryWriteCommandDecodesSnakeCaseSessionId() throws {
        // The full inbound envelope shape, decoded the same way the handler does
        // (decodeInbound → .convertFromSnakeCase folds session_id → sessionId; the
        // summary string content passes through verbatim).
        let json = """
            {"v":1,"id":"abc","type":"summary.write",
             "payload":{"session_id":"sess-42","summary":"Hello: a summary."}}
            """
        let cmd = try decodeInbound(Data(json.utf8), payloadType: SummaryWriteCommand.self)
        XCTAssertEqual(cmd.sessionId, "sess-42")
        XCTAssertEqual(cmd.summary, "Hello: a summary.", "summary content is verbatim, not key-transformed")
    }

    // MARK: - helpers

    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var range = haystack.startIndex..<haystack.endIndex
        while let r = haystack.range(of: needle, range: range) {
            count += 1
            range = r.upperBound..<haystack.endIndex
        }
        return count
    }
}
