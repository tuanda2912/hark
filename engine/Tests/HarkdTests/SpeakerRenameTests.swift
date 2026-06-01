// SpeakerRenameTests — regression coverage for the post-save speaker-rename
// relabel + re-render (EngineSession.applySpeakerNames + VaultWriter.renderMarkdown).
//
// Context: diarization runs as a post-stop batch pass, so "Speaker N" labels
// exist ONLY in the already-written vault markdown — renaming a speaker means
// re-rendering that same file with the user's chosen display names. The label
// mapping is the pure `applySpeakerNames`; the file output is `renderMarkdown`.
// These tests drive the PRODUCTION functions directly (no reimplementation) so
// the live `speaker.rename` path and the regression suite share one definition
// of "what does renaming actually do."

import XCTest
@testable import Harkd

@available(macOS 14.4, *)
final class SpeakerRenameTests: XCTestCase {

    private func utt(_ tStart: Double, _ label: String, _ text: String) -> VaultWriter.Utterance {
        VaultWriter.Utterance(tStart: tStart, label: label, text: text)
    }

    private func apply(_ utts: [VaultWriter.Utterance], _ names: [String: String])
        -> (utterances: [VaultWriter.Utterance], attendees: [String]) {
        EngineSession.applySpeakerNames(to: utts, names: names)
    }

    // MARK: - (a) renaming a subset maps only those labels

    func testSubsetRenameMapsOnlyMatchingLabels() {
        let input = [
            utt(0.0, "Speaker 1", "Hello there."),
            utt(2.0, "Speaker 2", "Hi back."),
            utt(4.0, "Speaker 3", "And me too."),
        ]
        // Only Speaker 1 and Speaker 3 are renamed; Speaker 2 is left out.
        let (out, _) = apply(input, ["Speaker 1": "Alice", "Speaker 3": "Carol"])
        XCTAssertEqual(out.map(\.label), ["Alice", "Speaker 2", "Carol"])
        // Text + timing untouched.
        XCTAssertEqual(out.map(\.text), ["Hello there.", "Hi back.", "And me too."])
        XCTAssertEqual(out.map(\.tStart), [0.0, 2.0, 4.0])
    }

    // MARK: - (b) attendees rebuilt distinct + in first-appearance order

    func testAttendeesDistinctInFirstAppearanceOrderAfterMapping() {
        // Speaker 2 speaks first, then Speaker 1, then Speaker 2 again. After
        // renaming, the roster must read in first-APPEARANCE order using the new
        // names, with each name appearing once.
        let input = [
            utt(0.0, "Speaker 2", "I start."),
            utt(1.0, "Speaker 1", "Then me."),
            utt(2.0, "Speaker 2", "Me again."),
            utt(3.0, "Speaker 1", "And me again."),
        ]
        let (_, attendees) = apply(input, ["Speaker 1": "Alice", "Speaker 2": "Bob"])
        XCTAssertEqual(attendees, ["Bob", "Alice"],
                       "first-appearance order is Bob (Speaker 2) then Alice (Speaker 1)")
    }

    /// Renaming two labels to the SAME display name collapses them into a single
    /// distinct attendee (first-appearance order preserved).
    func testTwoLabelsMergedToOneNameDedupInRoster() {
        let input = [
            utt(0.0, "Speaker 1", "a"),
            utt(1.0, "Speaker 2", "b"),
            utt(2.0, "Speaker 1", "c"),
        ]
        let (out, attendees) = apply(input, ["Speaker 1": "Alice", "Speaker 2": "Alice"])
        XCTAssertEqual(out.map(\.label), ["Alice", "Alice", "Alice"])
        XCTAssertEqual(attendees, ["Alice"], "merged speakers appear once in the roster")
    }

    // MARK: - (c) idempotent / second-rename-from-current-name works

    func testSecondRenameFromCurrentNameWorks() {
        let input = [
            utt(0.0, "Speaker 1", "Hello."),
            utt(2.0, "Speaker 2", "Hi."),
        ]
        // First rename: Speaker 1 -> Alice.
        let (afterFirst, attendeesFirst) = apply(input, ["Speaker 1": "Alice"])
        XCTAssertEqual(afterFirst.map(\.label), ["Alice", "Speaker 2"])
        XCTAssertEqual(attendeesFirst, ["Alice", "Speaker 2"])

        // Second rename maps from the NOW-current names: key is "Alice", and we
        // also fix up Speaker 2 -> Bob. This mirrors how the live handler updates
        // the snapshot in place between renames.
        let (afterSecond, attendeesSecond) = apply(
            afterFirst, ["Alice": "Alice Smith", "Speaker 2": "Bob"])
        XCTAssertEqual(afterSecond.map(\.label), ["Alice Smith", "Bob"])
        XCTAssertEqual(attendeesSecond, ["Alice Smith", "Bob"])
    }

    /// Empty map is a no-op relabel that still rebuilds a correct roster.
    func testEmptyNamesIsNoOpButRebuildsRoster() {
        let input = [
            utt(0.0, "Speaker 1", "a"),
            utt(1.0, "Speaker 2", "b"),
            utt(2.0, "Speaker 1", "c"),
        ]
        let (out, attendees) = apply(input, [:])
        XCTAssertEqual(out.map(\.label), ["Speaker 1", "Speaker 2", "Speaker 1"])
        XCTAssertEqual(attendees, ["Speaker 1", "Speaker 2"])
    }

    // MARK: - (d) unrenamed speakers keep "Speaker N"

    func testUnrenamedSpeakersKeepSpeakerN() {
        let input = [
            utt(0.0, "Speaker 1", "named"),
            utt(1.0, "Speaker 2", "anonymous"),
            utt(2.0, "Speaker ?", "unattributed"),
        ]
        let (out, attendees) = apply(input, ["Speaker 1": "Alice"])
        XCTAssertEqual(out.map(\.label), ["Alice", "Speaker 2", "Speaker ?"])
        // Roster includes every distinct post-map label in appearance order —
        // including the untouched "Speaker 2" and "Speaker ?" (the relabel helper
        // is roster-neutral; attendee filtering of "Speaker ?" is the diarization
        // pass's concern, not the rename's).
        XCTAssertEqual(attendees, ["Alice", "Speaker 2", "Speaker ?"])
    }

    // MARK: - (e) re-render carries the new names in front-matter + headers

    func testRenderedMarkdownContainsNewNamesInFrontmatterAndHeaders() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let input = [
            utt(0.0, "Speaker 1", "Hello there."),
            utt(5.0, "Speaker 2", "General Kenobi."),
        ]
        let (relabeled, attendees) = apply(input, ["Speaker 1": "Alice", "Speaker 2": "Bob"])

        // Drive the SAME render path the rename handler calls (VaultWriter.rewrite
        // → renderMarkdown). We render directly to assert content without touching
        // the filesystem.
        let writer = VaultWriter()
        let md = writer.renderMarkdown(
            title: VaultWriter.autoTitle(forStart: start),
            sessionStart: start,
            durationSec: 12,
            attendees: attendees,
            utterances: relabeled)

        // Front-matter attendees line carries the new names, not "Speaker N".
        XCTAssertTrue(md.contains("attendees: [Alice, Bob]"),
                      "front-matter roster uses the new names")
        XCTAssertFalse(md.contains("Speaker 1"), "no stale Speaker label survives")
        XCTAssertFalse(md.contains("Speaker 2"), "no stale Speaker label survives")

        // Per-utterance blockquote headers carry the new names.
        XCTAssertTrue(md.contains("> **Alice** ·"), "header uses the new name Alice")
        XCTAssertTrue(md.contains("> **Bob** ·"), "header uses the new name Bob")
    }
}
