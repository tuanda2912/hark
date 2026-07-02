// SessionAudioSpill — streams the continuous capture audio to a temp WAV so the
// full meeting doesn't sit in RAM (ADR-0039).
//
// Why this exists: the offline diarization pass needs the WHOLE meeting's 16 kHz
// mono PCM at stop, but holding it in a live `[Float]` grows ~3.75 MiB/min (with
// transient ~2× spikes during array-doubling) and pushed long meetings into swap.
// Instead we append frames to a temp WAV on the actor as they arrive — a flat
// in-RAM footprint (only the OS write buffer) — and read the file back once,
// transiently, at stop to feed the diarizer + the opt-in keep-audio path.
//
// Java analogue: a `RandomAccessFile` opened at session start, appended to per
// frame batch, size-patched + closed on stop. This is a plain class (NOT an
// actor) because its single owner, `EngineSession`, is already an actor and
// touches it only from its own isolation domain — the same reasoning `AudioStore`
// / `VaultWriter` use. It never crosses an actor boundary, so no `Sendable`.
//
// FORMAT (must match the captured stream losslessly): 16 kHz, mono, 32-bit IEEE
// float PCM. That is WAV format code 3 (`WAVE_FORMAT_IEEE_FLOAT`), 32 bits/sample
// — deliberately NOT `HarkCore.WAVWriter`, which is 16-bit integer (format 1) and
// would quantize the capture stream. The read-back returns the exact `[Float]`
// the old in-RAM buffer held, so diarization quality is byte-identical.
//
// HARD RULES (CLAUDE.md #2/#3, ADR-0039):
//   #2: raw audio is PII. The spill lives ONLY under
//       `~/Library/Application Support/Hark/tmp/` (rebuildable app data) — NEVER
//       the vault, NEVER networked. It is secure-deleted at stop and on teardown.
//   #3: this type sees audio (sensitive). It MUST NOT log content — log lines are
//       a session-scoped uuid + sample/byte counts only, never a path that leaks
//       meeting content and never the samples themselves.

import Foundation
import HarkCore

@available(macOS 14.4, *)
final class SessionAudioSpill {
    enum SpillError: Error {
        case cannotCreateFile(String)
    }

    /// The spill file's URL. Kept so `finalize`/`discard` can secure-delete it and
    /// `readAllSamples` can stream it back. Not logged as a full path (rule #3).
    let url: URL
    private let handle: FileHandle
    private var dataBytesWritten: UInt32 = 0
    private var finalized = false

    // 44-byte canonical WAV header, same layout as HarkCore.WAVWriter but with the
    // IEEE-float format code (3) + 32 bits/sample. Sizes are patched on finalize.
    private static let headerBytes = 44
    private static let bytesPerSample = MemoryLayout<Float>.size  // 4

    /// `~/Library/Application Support/Hark/tmp/`, created if missing (hard rule #2:
    /// rebuildable app data lives here, NEVER the vault). One dir shared by all
    /// sessions; each session gets a unique file inside it.
    static func tmpDir() throws -> URL {
        let dir = try HarkPaths.appSupportDir().appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Open a fresh spill file for a session. The name carries a `harkd-spill-`
    /// prefix + a uuid so startup cleanup can recognize + purge stale files a
    /// crashed prior session left behind (see `cleanStaleSpills`). Never reuses a
    /// name across sessions.
    init() throws {
        let dir = try Self.tmpDir()
        self.url = dir.appendingPathComponent("harkd-spill-\(UUID().uuidString).wav")
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw SpillError.cannotCreateFile(url.lastPathComponent)
        }
        self.handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.placeholderHeader())
    }

    /// Append one batch of 16 kHz mono Float samples. Runs on the owning actor's
    /// executor (NOT the audio pump), so the blocking `write` is off the audio
    /// callback — same placement the old `sessionAudio.append` had. No-op after
    /// finalize/discard.
    func append(_ frames: [Float]) throws {
        guard !finalized else { return }
        // Float32 LE on every Apple platform harkd targets (all little-endian), so
        // the in-memory bytes are already the on-disk layout — no per-sample swap.
        let byteCount = frames.count * Self.bytesPerSample
        let data = frames.withUnsafeBufferPointer { Data(buffer: $0) }
        try handle.write(contentsOf: data)
        dataBytesWritten &+= UInt32(byteCount)
    }

    /// Patch the RIFF + data size fields and close the write handle, WITHOUT
    /// deleting the file — the caller reads it back (`readAllSamples`) before
    /// secure-deleting. Idempotent. Returns the sample count written.
    @discardableResult
    func finalizeForReadback() throws -> Int {
        guard !finalized else { return Int(dataBytesWritten) / Self.bytesPerSample }
        finalized = true
        let dataSize = dataBytesWritten
        let riffSize = dataSize + UInt32(Self.headerBytes - 8)
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: Self.uint32LE(riffSize))
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: Self.uint32LE(dataSize))
        try handle.close()
        return Int(dataSize) / Self.bytesPerSample
    }

    /// Read the whole spill back into `[Float]`. This is the ONE transient full
    /// read at stop — the diarizer + keep-audio paths both need the complete
    /// buffer, so we materialize it once here rather than holding it all meeting.
    /// Reads the raw PCM payload after the 44-byte header and reinterprets it as
    /// Float32 LE (the exact bytes `append` wrote). Must be called AFTER
    /// `finalizeForReadback`.
    func readAllSamples() throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count > Self.headerBytes else { return [] }
        let payload = data.subdata(in: Self.headerBytes..<data.count)
        let count = payload.count / Self.bytesPerSample
        guard count > 0 else { return [] }
        return payload.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self).prefix(count))
        }
    }

    /// Secure-delete the spill: best-effort overwrite of the payload with zeros,
    /// then unlink. On APFS a copy-on-write / SSD wear-levelled filesystem cannot
    /// guarantee the original blocks are physically erased (the OS gives no such
    /// primitive), so this is a best-effort defense-in-depth pass, NOT a
    /// cryptographic wipe — the real guarantees are that the file lived only in
    /// local app-support, never networked, and is gone from the namespace before
    /// the process exits. Safe to call more than once and whether or not the file
    /// was finalized (abnormal-teardown path).
    func secureDelete() {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: url) }
        // If we still hold an open write handle (discard before finalize), close it
        // first so the overwrite handle can take the file.
        if !finalized { try? handle.close(); finalized = true }
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value, size > 0,
              let wipe = try? FileHandle(forWritingTo: url) else { return }
        defer { try? wipe.close() }
        // Overwrite in bounded chunks so a long meeting's spill doesn't pull the
        // whole file size back into RAM just to erase it.
        let chunk = Data(count: 1 << 20)  // 1 MiB of zeros
        var remaining = size
        try? wipe.seek(toOffset: 0)
        while remaining > 0 {
            let n = min(remaining, UInt64(chunk.count))
            try? wipe.write(contentsOf: n == UInt64(chunk.count) ? chunk : Data(count: Int(n)))
            remaining -= n
        }
        try? wipe.synchronize()
    }

    // MARK: - Startup stale-file cleanup

    /// Purge any spill files a prior crashed session left behind. Called once at
    /// engine startup — a clean stop always secure-deletes its own file, so anything
    /// still in `tmp/` matching our prefix is orphaned raw audio and must go. Best-
    /// effort + privacy-safe: logs a COUNT only (rule #3), never a path or content.
    static func cleanStaleSpills() {
        let fm = FileManager.default
        guard let dir = try? tmpDir(),
              let entries = try? fm.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: nil) else { return }
        var purged = 0
        for entry in entries where entry.lastPathComponent.hasPrefix("harkd-spill-") {
            // Best-effort secure-delete of the stale file, same zero-then-unlink as
            // a live discard (rule #2: leftover raw audio must not linger).
            secureDeleteFile(at: entry)
            purged += 1
        }
        if purged > 0 {
            FileHandle.standardError.write(Data(String(
                format: "harkd: purged %d stale audio spill file(s) from a prior session\n",
                purged).utf8))
        }
    }

    /// Zero-then-unlink a spill file by URL (no live handle). Shared by the startup
    /// stale-file sweep; the instance path reuses the open-handle form above.
    private static func secureDeleteFile(at url: URL) {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: url) }
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value, size > 0,
              let wipe = try? FileHandle(forWritingTo: url) else { return }
        defer { try? wipe.close() }
        let chunk = Data(count: 1 << 20)
        var remaining = size
        try? wipe.seek(toOffset: 0)
        while remaining > 0 {
            let n = min(remaining, UInt64(chunk.count))
            try? wipe.write(contentsOf: n == UInt64(chunk.count) ? chunk : Data(count: Int(n)))
            remaining -= n
        }
        try? wipe.synchronize()
    }

    // MARK: - Header construction (Float32 / IEEE-float variant)

    /// 44-byte header, IEEE-float PCM (format 3), 16 kHz mono, 32 bits/sample.
    /// Both size fields zeroed — patched in `finalizeForReadback`.
    private static func placeholderHeader() -> Data {
        var d = Data(capacity: headerBytes)
        d.append(contentsOf: Array("RIFF".utf8))
        d.append(uint32LE(0))                       // patched
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        d.append(uint32LE(16))                       // fmt chunk size (PCM/float)
        d.append(uint16LE(3))                        // WAVE_FORMAT_IEEE_FLOAT
        d.append(uint16LE(1))                        // channels: mono
        d.append(uint32LE(16_000))                   // sample rate
        d.append(uint32LE(16_000 * 1 * 4))           // byte rate = sr*ch*4
        d.append(uint16LE(1 * 4))                     // block align = ch*4
        d.append(uint16LE(32))                       // bits per sample
        d.append(contentsOf: Array("data".utf8))
        d.append(uint32LE(0))                        // patched
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
