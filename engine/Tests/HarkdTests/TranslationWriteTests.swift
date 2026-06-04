// TranslationWriteTests — coverage for the `translation.write` persistence path
// (VaultWriter.mergeTranslationSection + VaultWriter.appendTranslation) and the
// TranslationWriteCommand wire decode.
//
// Context: a whole-transcript translation is generated in the Electron main process
// (the egress chokepoint, ADR-0029); the ENGINE only persists the text it's handed
// into the most-recently-saved meeting's `.md` under a `## Transcript — <lang>`
// section + local git-commit. There is NO model call here — pure read-modify-write,
// exactly like `summary.write`.
//
// The section merge is the PURE `mergeTranslationSection` (driven directly, no
// reimplementation, so the live `translation.write` handler and this suite share one
// definition of "append or replace the translation for a language"). The filesystem
// read-modify-write (`appendTranslation`) is exercised against a temp file — we never
// touch the real vault, and we don't assert on git (commit is best-effort, off in a
// non-repo temp dir; the `.md` is the durable part).
//
// CRITICAL property under test: the heading match is EXACT including the language, so
// `## Transcript — Thai` and `## Transcript — French` are independent sections that
// coexist; re-translating to ONE language replaces only that language's section.

import XCTest
@testable import Harkd

@available(macOS 14.4, *)
final class TranslationWriteTests: XCTestCase {

    // A minimal but realistic meeting body: front-matter + a `## Transcript`
    // section, exactly the shape VaultWriter.write produces (no translation yet).
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

    func testAppendsTranslationWhenAbsent() {
        let merged = VaultWriter.mergeTranslationSection(
            into: transcriptBody, lang: "Thai", translation: "สวัสดีครับ")

        // The heading exists exactly once, the body is present, and the original
        // transcript content is untouched.
        XCTAssertEqual(occurrences(of: "## Transcript — Thai", in: merged), 1,
                       "exactly one Thai translation heading")
        XCTAssertTrue(merged.contains("## Transcript — Thai\n\nสวัสดีครับ\n"),
                      "heading + blank line + body shape")
        XCTAssertTrue(merged.contains("## Transcript\n"), "original transcript section preserved")
        XCTAssertTrue(merged.contains("> **Speaker 1** · 14:32:07"), "transcript body preserved")

        // The translation section comes AFTER the transcript (append, not prepend).
        let tIdx = merged.range(of: "## Transcript\n")!.lowerBound
        let xIdx = merged.range(of: "## Transcript — Thai")!.lowerBound
        XCTAssertTrue(tIdx < xIdx, "translation is appended after existing content")

        // Exactly one trailing newline.
        XCTAssertTrue(merged.hasSuffix("\n"))
        XCTAssertFalse(merged.hasSuffix("\n\n"), "no doubled trailing newline")
    }

    // MARK: - (b) replace when present, same lang (idempotent re-translate)

    func testReplacesSameLangWhenPresentNoDuplicate() {
        let first = VaultWriter.mergeTranslationSection(
            into: transcriptBody, lang: "Thai", translation: "เวอร์ชันแรก")
        // Re-translate the SAME language (file now carries a `## Transcript — Thai`).
        let second = VaultWriter.mergeTranslationSection(
            into: first, lang: "Thai", translation: "เวอร์ชันที่แก้ไข")

        XCTAssertEqual(occurrences(of: "## Transcript — Thai", in: second), 1,
                       "re-translate to the same lang must NOT duplicate the heading")
        XCTAssertTrue(second.contains("เวอร์ชันที่แก้ไข"), "new body is present")
        XCTAssertFalse(second.contains("เวอร์ชันแรก"), "old body is replaced, not stacked")
        // Original transcript section still intact above the translation.
        XCTAssertTrue(second.contains("## Transcript\n"))
        XCTAssertTrue(second.contains("> **Speaker 2** · 14:32:12"))
    }

    /// Idempotent in the strict sense: merging the SAME lang + body twice is a no-op on
    /// the second pass (byte-for-byte stable output).
    func testMergeIsStableForSameLangAndBody() {
        let once = VaultWriter.mergeTranslationSection(
            into: transcriptBody, lang: "Thai", translation: "ข้อความคงที่")
        let twice = VaultWriter.mergeTranslationSection(
            into: once, lang: "Thai", translation: "ข้อความคงที่")
        XCTAssertEqual(once, twice, "merging the same lang + body again changes nothing")
    }

    // MARK: - (c) two languages coexist as separate sections

    func testTwoLanguagesCoexistAsSeparateSections() {
        let withThai = VaultWriter.mergeTranslationSection(
            into: transcriptBody, lang: "Thai", translation: "สวัสดี")
        // A DIFFERENT language → a SEPARATE section, not a replace.
        let withBoth = VaultWriter.mergeTranslationSection(
            into: withThai, lang: "French", translation: "Bonjour")

        XCTAssertEqual(occurrences(of: "## Transcript — Thai", in: withBoth), 1,
                       "Thai section still present exactly once")
        XCTAssertEqual(occurrences(of: "## Transcript — French", in: withBoth), 1,
                       "French section added exactly once")
        XCTAssertTrue(withBoth.contains("สวัสดี"), "Thai body present")
        XCTAssertTrue(withBoth.contains("Bonjour"), "French body present")

        // Both sections sit AFTER the original transcript, in first-added order.
        let tIdx = withBoth.range(of: "## Transcript\n")!.lowerBound
        let thaiIdx = withBoth.range(of: "## Transcript — Thai")!.lowerBound
        let frIdx = withBoth.range(of: "## Transcript — French")!.lowerBound
        XCTAssertTrue(tIdx < thaiIdx && thaiIdx < frIdx, "transcript < Thai < French order")
    }

    /// Re-translating ONE language leaves the OTHER language's section untouched.
    func testReTranslateOneLangLeavesOtherUntouched() {
        var doc = VaultWriter.mergeTranslationSection(
            into: transcriptBody, lang: "Thai", translation: "ไทยเก่า")
        doc = VaultWriter.mergeTranslationSection(
            into: doc, lang: "French", translation: "Français original")
        // Re-translate ONLY Thai.
        doc = VaultWriter.mergeTranslationSection(
            into: doc, lang: "Thai", translation: "ไทยใหม่")

        XCTAssertEqual(occurrences(of: "## Transcript — Thai", in: doc), 1, "still one Thai heading")
        XCTAssertEqual(occurrences(of: "## Transcript — French", in: doc), 1, "still one French heading")
        XCTAssertTrue(doc.contains("ไทยใหม่"), "Thai body replaced")
        XCTAssertFalse(doc.contains("ไทยเก่า"), "old Thai body gone")
        XCTAssertTrue(doc.contains("Français original"), "French body untouched by Thai re-translate")
    }

    // MARK: - (d) markdown shape: heading + trimmed body

    func testTranslationSectionShapeBodyTrimmed() {
        let merged = VaultWriter.mergeTranslationSection(
            into: transcriptBody, lang: "Vietnamese",
            translation: "  Xin chào.  \n\n")  // surrounding whitespace gets trimmed

        // `## Transcript — Vietnamese`, one blank line, then the trimmed body, newline.
        XCTAssertTrue(merged.contains("## Transcript — Vietnamese\n\nXin chào.\n"),
                      "body trimmed of surrounding whitespace, single blank line after heading")
    }

    /// A multi-line / multi-paragraph translation body is preserved verbatim under one
    /// heading (the body can itself contain blank lines and blockquoted utterances).
    func testMultiLineTranslationBodyPreserved() {
        let body = "> **Speaker 1** · 14:32:07\n> Xin chào.\n\n> **Speaker 2** · 14:32:12\n> Tướng quân Kenobi."
        let merged = VaultWriter.mergeTranslationSection(
            into: transcriptBody, lang: "Vietnamese", translation: body)
        XCTAssertEqual(occurrences(of: "## Transcript — Vietnamese", in: merged), 1)
        XCTAssertTrue(merged.contains("> Xin chào."), "first utterance preserved")
        XCTAssertTrue(merged.contains("> Tướng quân Kenobi."), "trailing utterance preserved")
    }

    /// Replacement is bounded by the NEXT top-level heading: a section AFTER the
    /// translation survives a re-translate untouched (we only swap that lang's body).
    func testFollowingSectionSurvivesReplace() {
        let withTrailing = transcriptBody
            + "\n## Transcript — Thai\n\nไทยเก่า\n\n## Summary\n\nWe shipped.\n"
        let merged = VaultWriter.mergeTranslationSection(
            into: withTrailing, lang: "Thai", translation: "ไทยใหม่")

        XCTAssertEqual(occurrences(of: "## Transcript — Thai", in: merged), 1)
        XCTAssertTrue(merged.contains("ไทยใหม่"), "translation body replaced")
        XCTAssertFalse(merged.contains("ไทยเก่า"), "old translation body gone")
        XCTAssertTrue(merged.contains("## Summary"), "trailing section heading survives")
        XCTAssertTrue(merged.contains("We shipped."), "trailing section body survives")
        // Order: Transcript < Transcript — Thai < Summary.
        let t = merged.range(of: "## Transcript\n")!.lowerBound
        let x = merged.range(of: "## Transcript — Thai")!.lowerBound
        let s = merged.range(of: "## Summary")!.lowerBound
        XCTAssertTrue(t < x && x < s, "section order preserved")
    }

    /// A `### Transcript — Thai` subheading (or a quoted heading inside the body) must
    /// NOT be mistaken for the section heading — append, don't corrupt.
    func testSubheadingDoesNotMatchSectionHeading() {
        let withDecoy = transcriptBody
            + "\n> **Speaker 1** · 14:33:00\n> Quoting: ## Transcript — Thai from last week.\n"
        let merged = VaultWriter.mergeTranslationSection(
            into: withDecoy, lang: "Thai", translation: "ของจริง")
        // The real `## Transcript — Thai` (column-0 heading) is appended; the quoted
        // text, which is prefixed by "> ", is left in place.
        XCTAssertEqual(occurrences(of: "\n## Transcript — Thai", in: "\n" + merged), 1,
                       "exactly one column-0 Thai heading")
        XCTAssertTrue(merged.contains("Quoting: ## Transcript — Thai from last week."),
                      "the quoted decoy text is untouched")
        XCTAssertTrue(merged.contains("ของจริง"))
    }

    // MARK: - (e) appendTranslation read-modify-write against a temp file

    func testAppendTranslationWritesToFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-translation-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data(transcriptBody.utf8).write(to: tmp, options: .atomic)

        let writer = VaultWriter()
        // Append Thai.
        let r1 = try writer.appendTranslation(to: tmp, lang: "Thai", translation: "ครั้งแรก",
                                              commitMessage: "docs(meeting): Thai translation for test")
        XCTAssertEqual(r1.fileURL.path, tmp.path, "writes the meeting's OWN file in place")
        var disk = try String(contentsOf: tmp, encoding: .utf8)
        XCTAssertEqual(occurrences(of: "## Transcript — Thai", in: disk), 1)
        XCTAssertTrue(disk.contains("ครั้งแรก"))

        // Add French — a SEPARATE section; Thai survives.
        _ = try writer.appendTranslation(to: tmp, lang: "French", translation: "Bonjour",
                                         commitMessage: "docs(meeting): French translation for test")
        disk = try String(contentsOf: tmp, encoding: .utf8)
        XCTAssertEqual(occurrences(of: "## Transcript — Thai", in: disk), 1, "Thai still present")
        XCTAssertEqual(occurrences(of: "## Transcript — French", in: disk), 1, "French added")
        XCTAssertTrue(disk.contains("Bonjour"))

        // Re-translate Thai (replace) — idempotent, no duplicate heading; French intact.
        _ = try writer.appendTranslation(to: tmp, lang: "Thai", translation: "ครั้งที่สอง",
                                         commitMessage: "docs(meeting): Thai translation for test")
        disk = try String(contentsOf: tmp, encoding: .utf8)
        XCTAssertEqual(occurrences(of: "## Transcript — Thai", in: disk), 1, "still one Thai heading")
        XCTAssertTrue(disk.contains("ครั้งที่สอง"))
        XCTAssertFalse(disk.contains("ครั้งแรก"), "old Thai translation replaced on disk")
        XCTAssertTrue(disk.contains("Bonjour"), "French untouched by Thai re-translate")
        XCTAssertTrue(disk.contains("## Transcript\n"), "original transcript intact after all writes")
    }

    // MARK: - (f) wire decode: TranslationWriteCommand

    func testTranslationWriteCommandDecodesSnakeCaseSessionId() throws {
        // The full inbound envelope shape, decoded the same way the handler does
        // (decodeInbound → .convertFromSnakeCase folds session_id → sessionId; the
        // lang + translation string content passes through verbatim).
        let json = """
            {"v":1,"id":"abc","type":"translation.write",
             "payload":{"session_id":"sess-42","lang":"Thai","translation":"Hello: a translation."}}
            """
        let cmd = try decodeInbound(Data(json.utf8), payloadType: TranslationWriteCommand.self)
        XCTAssertEqual(cmd.sessionId, "sess-42")
        XCTAssertEqual(cmd.lang, "Thai", "lang is verbatim, not key-transformed")
        XCTAssertEqual(cmd.translation, "Hello: a translation.",
                       "legacy translation blob is verbatim, not key-transformed")
        XCTAssertNil(cmd.lines, "no `lines` field present in the legacy-blob frame")
    }

    /// The NEW structured frame: `lines` (per-utterance translated text, in saved order)
    /// decodes as a string array; `lines` is single-word so `.convertFromSnakeCase`
    /// leaves it unchanged, and `translation` is ABSENT (decodes to nil — the optional).
    func testTranslationWriteCommandDecodesStructuredLines() throws {
        let json = """
            {"v":1,"id":"abc","type":"translation.write",
             "payload":{"session_id":"sess-7","lang":"Vietnamese",
                        "lines":["Xin chào.","Tướng quân Kenobi."]}}
            """
        let cmd = try decodeInbound(Data(json.utf8), payloadType: TranslationWriteCommand.self)
        XCTAssertEqual(cmd.sessionId, "sess-7")
        XCTAssertEqual(cmd.lang, "Vietnamese")
        XCTAssertNil(cmd.translation, "legacy blob absent in a structured frame")
        XCTAssertEqual(cmd.lines, ["Xin chào.", "Tướng quân Kenobi."],
                       "per-utterance lines decode verbatim, in order")
    }

    // MARK: - (g) structured translation MIRRORS the original transcript format

    /// The crux of the fix: a translated `## Transcript — <lang>` section built from
    /// per-utterance lines must carry the SAME `> **<label>** · HH:MM:SS` headers (same
    /// wall-clock `clockOffset` base, same blockquote format) as the ORIGINAL
    /// `## Transcript` — only the text differs. We render the original via the SAME
    /// `renderMarkdown` the live save uses, then build the structured translation from
    /// the IDENTICAL utterances (translated text) and assert the header lines match
    /// byte-for-byte.
    func testStructuredTranslationMirrorsOriginalHeaders() throws {
        // A fixed wall-clock anchor so the expected HH:MM:SS is deterministic.
        // 2026-06-04 07:03:45 +07:00 → epoch.
        let sessionStart = Date(timeIntervalSince1970: 1_749_002_625)  // arbitrary fixed instant
        let utterances = [
            VaultWriter.Utterance(tStart: 2.0, label: "Mark", text: "Hello there."),
            VaultWriter.Utterance(tStart: 7.5, label: "Speaker 2", text: "General Kenobi."),
        ]
        // The wall-clock headers the ENGINE renders for these utterances (single source
        // of truth — the same formatter `renderMarkdown` and `appendTranslationStructured`
        // both call). We compute the expected strings from that helper so the test stays
        // timezone-agnostic (CI may not be +07:00).
        let clock0 = VaultWriter.clockOffset(from: sessionStart, plus: 2.0)
        let clock1 = VaultWriter.clockOffset(from: sessionStart, plus: 7.5)
        let header0 = "> **Mark** · \(clock0)"
        let header1 = "> **Speaker 2** · \(clock1)"

        // 1. The ORIGINAL transcript body (what the saved `## Transcript` carries).
        let original = VaultWriter.renderTranscriptBody(utterances, sessionStart: sessionStart)
        XCTAssertTrue(original.contains(header0), "original carries Mark's wall-clock header")
        XCTAssertTrue(original.contains(header1), "original carries Speaker 2's wall-clock header")
        XCTAssertTrue(original.contains("> Hello there."), "original body line present")

        // 2. The STRUCTURED translation: same utterances' label+tStart, translated text.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-structured-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data(transcriptBody.utf8).write(to: tmp, options: .atomic)

        let writer = VaultWriter()
        _ = try writer.appendTranslationStructured(
            to: tmp, lang: "Vietnamese",
            translatedLines: ["Xin chào.", "Tướng quân Kenobi."],
            utterances: utterances, sessionStart: sessionStart,
            commitMessage: "docs(meeting): structured translation for test")
        let disk = try String(contentsOf: tmp, encoding: .utf8)

        // The translated section uses the engine's OWN headers — identical to the
        // original's wall-clock + blockquote shape, NOT a renderer-supplied flat blob.
        XCTAssertEqual(occurrences(of: "## Transcript — Vietnamese", in: disk), 1)
        XCTAssertTrue(disk.contains(header0), "translated section mirrors Mark's wall-clock header")
        XCTAssertTrue(disk.contains(header1), "translated section mirrors Speaker 2's header")
        // Translated TEXT under those mirrored headers; original text not duplicated there.
        XCTAssertTrue(disk.contains("> Xin chào."), "translated text under the mirrored header")
        XCTAssertTrue(disk.contains("> Tướng quân Kenobi."), "second translated line present")
        // Original `## Transcript` section still intact above the translation.
        XCTAssertTrue(disk.contains("## Transcript\n"), "original transcript preserved")
        XCTAssertTrue(disk.contains("> **Speaker 1** · 14:32:07"), "original transcript body preserved")
    }

    /// Structured translation is IDEMPOTENT PER LANG via the shared
    /// `mergeTranslationSection`: re-running the same lang replaces the section in place
    /// (no duplicate heading), and a DIFFERENT lang coexists as its own section.
    func testStructuredTranslationIsIdempotentPerLang() throws {
        let sessionStart = Date(timeIntervalSince1970: 1_749_002_625)
        let utterances = [
            VaultWriter.Utterance(tStart: 0.0, label: "Speaker 1", text: "Hello there."),
            VaultWriter.Utterance(tStart: 5.0, label: "Speaker 2", text: "General Kenobi."),
        ]
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-structured-idem-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data(transcriptBody.utf8).write(to: tmp, options: .atomic)

        let writer = VaultWriter()
        // First Thai.
        _ = try writer.appendTranslationStructured(
            to: tmp, lang: "Thai", translatedLines: ["สวัสดี", "นายพลเคโนบี"],
            utterances: utterances, sessionStart: sessionStart, commitMessage: "test")
        // Re-translate Thai (replace).
        _ = try writer.appendTranslationStructured(
            to: tmp, lang: "Thai", translatedLines: ["สวัสดีครับ", "ท่านนายพลเคโนบี"],
            utterances: utterances, sessionStart: sessionStart, commitMessage: "test")
        // Add French (coexists).
        _ = try writer.appendTranslationStructured(
            to: tmp, lang: "French", translatedLines: ["Bonjour.", "Général Kenobi."],
            utterances: utterances, sessionStart: sessionStart, commitMessage: "test")

        let disk = try String(contentsOf: tmp, encoding: .utf8)
        XCTAssertEqual(occurrences(of: "## Transcript — Thai", in: disk), 1,
                       "re-translate replaces in place — one Thai heading")
        XCTAssertEqual(occurrences(of: "## Transcript — French", in: disk), 1, "French added")
        XCTAssertTrue(disk.contains("> สวัสดีครับ"), "replaced Thai body present")
        XCTAssertFalse(disk.contains("> สวัสดี\n"), "old Thai body gone (not stacked)")
        XCTAssertTrue(disk.contains("> Bonjour."), "French body present")
    }

    /// DEFENSIVE index-zip: a count mismatch between `translatedLines` and the retained
    /// utterances truncates to the shorter (never crashes / out-of-bounds). Counts should
    /// always be 1:1 in practice, but a stray mismatch must not take down the daemon.
    func testStructuredTranslationCountMismatchTruncatesSafely() throws {
        let sessionStart = Date(timeIntervalSince1970: 1_749_002_625)
        let utterances = [
            VaultWriter.Utterance(tStart: 0.0, label: "Speaker 1", text: "One."),
            VaultWriter.Utterance(tStart: 3.0, label: "Speaker 2", text: "Two."),
            VaultWriter.Utterance(tStart: 6.0, label: "Speaker 3", text: "Three."),
        ]
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-structured-mismatch-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data(transcriptBody.utf8).write(to: tmp, options: .atomic)

        let writer = VaultWriter()
        // Fewer lines (2) than utterances (3): pairs the first 2, drops the 3rd.
        let header2 = "> **Speaker 3** · \(VaultWriter.clockOffset(from: sessionStart, plus: 6.0))"
        let r = try writer.appendTranslationStructured(
            to: tmp, lang: "Thai", translatedLines: ["หนึ่ง", "สอง"],
            utterances: utterances, sessionStart: sessionStart, commitMessage: "test")
        XCTAssertEqual(r.fileURL.path, tmp.path)
        var disk = try String(contentsOf: tmp, encoding: .utf8)
        XCTAssertTrue(disk.contains("> หนึ่ง"), "first translated line present")
        XCTAssertTrue(disk.contains("> สอง"), "second translated line present")
        XCTAssertFalse(disk.contains(header2), "unpaired 3rd utterance header is NOT rendered")

        // The symmetric case: more lines than utterances — extra lines are dropped, no crash.
        try Data(transcriptBody.utf8).write(to: tmp, options: .atomic)
        _ = try writer.appendTranslationStructured(
            to: tmp, lang: "Thai", translatedLines: ["A", "B", "C", "D", "E"],
            utterances: [utterances[0]], sessionStart: sessionStart, commitMessage: "test")
        disk = try String(contentsOf: tmp, encoding: .utf8)
        XCTAssertTrue(disk.contains("> A"), "the one paired line is rendered")
        XCTAssertFalse(disk.contains("> B"), "surplus lines beyond the utterance count dropped")
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
