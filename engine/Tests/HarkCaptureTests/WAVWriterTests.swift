// Round-trip tests for HarkCore.WAVWriter.

import HarkCore
import XCTest

final class WAVWriterTests: XCTestCase {
    func testWritesValidHeaderAndPayload() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-wavwriter-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let samples: [Int16] = [0, 100, -100, 32_000, -32_000, 1, -1, 0]
        let writer = try WAVWriter(url: url)
        try writer.append(samples)
        try writer.close()

        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 44 + samples.count * 2)

        // Header sanity
        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: data[12..<16], encoding: .ascii), "fmt ")
        XCTAssertEqual(String(data: data[36..<40], encoding: .ascii), "data")

        // Patched size fields
        let riffSize = data[4..<8].withUnsafeBytes { $0.load(as: UInt32.self) }
        let dataSize = data[40..<44].withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(Int(dataSize), samples.count * 2)
        XCTAssertEqual(Int(riffSize), Int(dataSize) + 36)

        // Format fields
        let channels = data[22..<24].withUnsafeBytes { $0.load(as: UInt16.self) }
        let sampleRate = data[24..<28].withUnsafeBytes { $0.load(as: UInt32.self) }
        let bitsPerSample = data[34..<36].withUnsafeBytes { $0.load(as: UInt16.self) }
        XCTAssertEqual(channels, 1)
        XCTAssertEqual(sampleRate, 16_000)
        XCTAssertEqual(bitsPerSample, 16)

        // Round-trip samples
        let recovered: [Int16] = stride(from: 44, to: data.count, by: 2).map {
            data[$0 ..< $0 + 2].withUnsafeBytes { $0.load(as: Int16.self) }
        }
        XCTAssertEqual(recovered, samples)
    }

    func testCloseIsIdempotent() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-wavwriter-idem-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WAVWriter(url: url)
        try writer.append([1, 2, 3])
        try writer.close()
        XCTAssertNoThrow(try writer.close())
    }
}
