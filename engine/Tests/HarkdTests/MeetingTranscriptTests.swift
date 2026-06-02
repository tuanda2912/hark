// MeetingTranscriptTests — coverage for the `meeting.transcript` mapping
// (EngineSession.transcriptUtterances).
//
// Context: diarization runs as a post-stop batch pass, so live `segment.final`
// frames ship `speaker: nil` — the "Speaker N" labels only ever landed in the
// written vault file + the `meeting.saved` roster, never back on the on-screen
// transcript. `meeting.transcript` carries EXACTLY the deduped, labeled vault
// utterances so the UI can replace the on-screen transcript to match the saved
// file. This drives the PRODUCTION mapping directly (no reimplementation) so the
// emit path and the test share one definition.

import XCTest
@testable import Harkd

@available(macOS 14.4, *)
final class MeetingTranscriptTests: XCTestCase {

    private func utt(_ tStart: Double, _ label: String, _ text: String) -> VaultWriter.Utterance {
        VaultWriter.Utterance(tStart: tStart, label: label, text: text)
    }

    /// The mapping carries tStart/text through unchanged, surfaces the "Speaker N"
    /// label as `speaker`, and mints stable index-based ids in input order.
    func testMapsLabeledUtterancesToWireRowsVerbatim() {
        let labeled = [
            utt(0.0, "Speaker 1", "Hello there."),
            utt(5.0, "Speaker 2", "General Kenobi."),
            utt(9.0, "Speaker ?", "...mystery."),
        ]
        let rows = EngineSession.transcriptUtterances(from: labeled)

        XCTAssertEqual(rows.map(\.id), ["u0", "u1", "u2"], "ids are index-based in input order")
        XCTAssertEqual(rows.map(\.tStart), [0.0, 5.0, 9.0])
        XCTAssertEqual(rows.map(\.text), ["Hello there.", "General Kenobi.", "...mystery."])
        XCTAssertEqual(rows.map(\.speaker), ["Speaker 1", "Speaker 2", "Speaker ?"],
                       "the vault label passes through as speaker, including 'Speaker ?'")
    }

    /// Empty input maps to no rows (no crash, no synthetic content).
    func testEmptyInputMapsToEmpty() {
        XCTAssertTrue(EngineSession.transcriptUtterances(from: []).isEmpty)
    }

    /// The rows encode to the wire with snake_case keys (`session_id`, `t_start`)
    /// and the single-word fields unchanged — matching the contract the UI reads.
    func testEncodesToSnakeCaseWireShape() throws {
        let payload = MeetingTranscriptPayload(
            sessionId: "sess-123",
            utterances: EngineSession.transcriptUtterances(from: [
                utt(1.5, "Speaker 1", "hi"),
            ]))
        let env = WireEnvelope(type: "meeting.transcript", payload: payload)
        let json = String(decoding: try encodeWireMessage(env), as: UTF8.self)

        XCTAssertTrue(json.contains("\"type\":\"meeting.transcript\""))
        XCTAssertTrue(json.contains("\"session_id\":\"sess-123\""))
        XCTAssertTrue(json.contains("\"t_start\":1.5"))
        XCTAssertTrue(json.contains("\"id\":\"u0\""))
        XCTAssertTrue(json.contains("\"speaker\":\"Speaker 1\""))
        XCTAssertTrue(json.contains("\"text\":\"hi\""))
    }
}
