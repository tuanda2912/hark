// RagWireTests — the exact wire shapes 4c (the TS mirror) must match for the
// vault-RAG frames (Phase 6 slice 4b, ADR-0032/0033). PURE encode/decode, always
// runs. These pin the snake_case field names + null handling so the TS contract
// can be written against assertions, not guesswork.
//
//   - rag.retrieve  (UI→engine) decodes { query, k, scope }, snake-folded.
//   - rag.results   (engine→UI) encodes { chunks: [{ text, note_path, heading_path,
//                    char_start, char_end, score }] }.
//   - rag.index_status (engine→UI) encodes { state, indexed_count, total|null }.

import XCTest
import Foundation
@testable import Harkd

@available(macOS 14.4, *)
final class RagWireTests: XCTestCase {

    // MARK: - rag.retrieve decode

    func testRagRetrieveDecodesQueryKScope() throws {
        let json = """
            {"v":1,"id":"r1","type":"rag.retrieve",
             "payload":{"query":"budget: what did we decide?","k":5,"scope":"vault"}}
            """
        let cmd = try decodeInbound(Data(json.utf8), payloadType: RagRetrieveCommand.self)
        XCTAssertEqual(cmd.query, "budget: what did we decide?", "query content verbatim")
        XCTAssertEqual(cmd.k, 5)
        XCTAssertEqual(cmd.scope, "vault")
    }

    func testRagRetrieveOptionalFieldsAbsent() throws {
        // k + scope omitted → nil (handler defaults/clamps).
        let json = """
            {"v":1,"id":"r1","type":"rag.retrieve","payload":{"query":"hello"}}
            """
        let cmd = try decodeInbound(Data(json.utf8), payloadType: RagRetrieveCommand.self)
        XCTAssertEqual(cmd.query, "hello")
        XCTAssertNil(cmd.k)
        XCTAssertNil(cmd.scope)
    }

    // MARK: - rag.results encode

    func testRagResultsEncodesSnakeCaseFields() throws {
        let payload = RagResultsPayload(chunks: [
            RagResultChunk(text: "the snippet", notePath: "meetings/m.md",
                           headingPath: "Design > Risks", charStart: 10, charEnd: 42, score: 0.87)
        ])
        let env = WireEnvelope(type: "rag.results", payload: payload, id: "r1")
        let data = try encodeWireMessage(env)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["type"] as? String, "rag.results")
        XCTAssertEqual(obj["id"] as? String, "r1")
        let p = obj["payload"] as! [String: Any]
        let chunks = p["chunks"] as! [[String: Any]]
        XCTAssertEqual(chunks.count, 1)
        let c = chunks[0]
        XCTAssertEqual(c["text"] as? String, "the snippet")
        XCTAssertEqual(c["note_path"] as? String, "meetings/m.md")
        XCTAssertEqual(c["heading_path"] as? String, "Design > Risks")
        XCTAssertEqual(c["char_start"] as? Int, 10)
        XCTAssertEqual(c["char_end"] as? Int, 42)
        XCTAssertEqual((c["score"] as? NSNumber)?.doubleValue ?? 0, 0.87, accuracy: 1e-6)
    }

    func testRagResultsEmptyChunks() throws {
        let env = WireEnvelope(type: "rag.results", payload: RagResultsPayload(chunks: []), id: "r1")
        let data = try encodeWireMessage(env)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let p = obj["payload"] as! [String: Any]
        XCTAssertEqual((p["chunks"] as? [[String: Any]])?.count, 0)
    }

    // MARK: - rag.index_status encode

    func testIndexStatusBuildingCarriesTotal() throws {
        let env = WireEnvelope(type: "rag.index_status",
                               payload: RagIndexStatusPayload(state: "building", indexedCount: 12, total: 40))
        let data = try encodeWireMessage(env)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let p = obj["payload"] as! [String: Any]
        XCTAssertEqual(p["state"] as? String, "building")
        XCTAssertEqual(p["indexed_count"] as? Int, 12)
        XCTAssertEqual(p["total"] as? Int, 40)
    }

    func testIndexStatusReadyEncodesNullTotalExplicitly() throws {
        // total nil must serialize as JSON null (not a dropped key) so the UI can
        // tell "incremental, no total" from a forgotten field.
        let env = WireEnvelope(type: "rag.index_status",
                               payload: RagIndexStatusPayload(state: "ready", indexedCount: 99, total: nil))
        let data = try encodeWireMessage(env)
        let str = String(data: data, encoding: .utf8)!
        XCTAssertTrue(str.contains("\"total\":null"), "nil total encodes as explicit null, got: \(str)")
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let p = obj["payload"] as! [String: Any]
        XCTAssertEqual(p["state"] as? String, "ready")
        XCTAssertEqual(p["indexed_count"] as? Int, 99)
        XCTAssertTrue(p["total"] is NSNull, "total present as null")
    }
}
