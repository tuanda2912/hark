// WAVWriter — streaming WAV writer for 16 kHz mono PCM s16le.
//
// Why streaming? hark-capture may record for hours; we can't buffer the whole
// recording before knowing the size. The RIFF format demands two size fields
// in the header that depend on the total data length — we write zero
// placeholders, append samples as they arrive, then seek back and fix the
// sizes on close.
//
// File shape (44-byte header + interleaved Int16 samples):
//
//   offset  bytes  contents
//   ------  -----  ----------------------------------------------
//   0       4      "RIFF"
//   4       4      file size - 8                  ← patched on close
//   8       4      "WAVE"
//   12      4      "fmt "
//   16      4      16                              (PCM fmt chunk size)
//   20      2      1                               (PCM format code)
//   22      2      1                               (channels: mono)
//   24      4      16000                           (sample rate)
//   28      4      32000                           (byte rate = sr*ch*2)
//   32      2      2                               (block align = ch*2)
//   34      2      16                              (bits per sample)
//   36      4      "data"
//   40      4      data size                       ← patched on close
//   44      …      PCM samples (Int16 LE)
//
// Java analogue: think `RandomAccessFile` with explicit seek-and-patch on
// close. Foundation's `FileHandle` is the equivalent here.

import Foundation

public final class WAVWriter {
    public enum WAVWriterError: Error {
        case cannotCreateFile(String)
    }

    private let handle: FileHandle
    private let url: URL
    private var dataBytesWritten: UInt32 = 0
    private var closed = false

    /// Opens `url` for writing and emits a 44-byte placeholder header.
    public init(url: URL) throws {
        self.url = url
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw WAVWriterError.cannotCreateFile(url.path)
        }
        self.handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.placeholderHeader())
    }

    /// Appends Int16 samples. Caller is responsible for ensuring they're
    /// already at 16 kHz mono — WAVWriter does no resampling.
    public func append(_ samples: [Int16]) throws {
        guard !closed else { return }
        let byteCount = samples.count * MemoryLayout<Int16>.size
        let data = samples.withUnsafeBufferPointer { buf in
            Data(buffer: buf)
        }
        try handle.write(contentsOf: data)
        dataBytesWritten &+= UInt32(byteCount)
    }

    /// Seeks back, patches the two size fields, closes the file.
    /// Safe to call more than once (idempotent).
    public func close() throws {
        guard !closed else { return }
        closed = true

        let dataSize = dataBytesWritten
        let riffSize = dataSize + 36  // 44-byte header - 8 ("RIFF" + size field)

        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: Self.uint32LE(riffSize))

        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: Self.uint32LE(dataSize))

        try handle.close()
    }

    deinit { try? close() }

    // MARK: - Header construction

    /// 44-byte header with both size fields zeroed. Patched on close().
    private static func placeholderHeader() -> Data {
        var d = Data(capacity: 44)
        d.append(contentsOf: Array("RIFF".utf8))
        d.append(uint32LE(0))                            // patched
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        d.append(uint32LE(16))                           // fmt chunk size (PCM)
        d.append(uint16LE(1))                            // PCM format code
        d.append(uint16LE(1))                            // channels
        d.append(uint32LE(16_000))                       // sample rate
        d.append(uint32LE(16_000 * 1 * 2))               // byte rate
        d.append(uint16LE(1 * 2))                        // block align
        d.append(uint16LE(16))                           // bits per sample
        d.append(contentsOf: Array("data".utf8))
        d.append(uint32LE(0))                            // patched
        return d
    }

    private static func uint32LE(_ v: UInt32) -> Data {
        var le = v.littleEndian
        return withUnsafeBytes(of: &le) { Data($0) }
    }

    private static func uint16LE(_ v: UInt16) -> Data {
        var le = v.littleEndian
        return withUnsafeBytes(of: &le) { Data($0) }
    }
}
