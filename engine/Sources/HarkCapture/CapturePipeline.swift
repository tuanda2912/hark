// CapturePipeline — orchestrates MicCapture + SystemAudioTap → Resampler →
// per-source FIFO → Mixer → WAVWriter.
//
// Time alignment strategy for Phase 2 (v0):
//
// Each source produces 16 kHz mono Float32 frames asynchronously on its own
// Core Audio thread. We do NOT use mach timestamps to align frames; we keep
// a FIFO per source and the pump pulls `min(mic_avail, sys_avail)` frames
// at a time. The two hardware clocks may drift ~1 sample/sec relative to
// each other (≈225 ms over a 1-hour recording in the worst case), which is
// acceptable for transcription. If drift becomes a problem during Phase 4
// dogfooding, the fix is to drop or insert samples in the slower FIFO based
// on mach-time deltas — out of scope for Phase 2.
//
// If a source falls behind by more than `underrunGraceFrames`, the pump
// emits silence for the lagging source and bumps the underrun counter. The
// recording continues; one source glitching shouldn't kill the meeting.
//
// Threading:
//   - Mic/system tap callbacks run on Core Audio threads. They take the
//     pipeline's lock briefly to append resampled samples to their FIFO.
//   - The pump runs on a dedicated DispatchQueue at 100 ms cadence.
//   - The heartbeat runs as a Task on the cooperative pool.

import AVFoundation
import Foundation
import HarkCore

@available(macOS 14.4, *)
public final class CapturePipeline {
    public struct Options {
        public var captureMic: Bool
        public var captureSystem: Bool
        public var outputURL: URL
        /// 100 ms at 16 kHz = 1600 frames. The pump batches at this size.
        public var pumpFrames: Int = 1_600
        /// If a source has < this many frames buffered when the pump fires,
        /// we count the deficit as underrun and emit silence for it.
        public var underrunGraceFrames: Int = 1_600
        public init(captureMic: Bool, captureSystem: Bool, outputURL: URL) {
            self.captureMic = captureMic
            self.captureSystem = captureSystem
            self.outputURL = outputURL
        }
    }

    private let options: Options
    private let writer: WAVWriter
    private let mixer = Mixer()

    // Per-source state.
    private var mic: MicCapture?
    private var micResampler: Resampler?
    private var system: SystemAudioTap?
    private var systemResampler: Resampler?

    // FIFOs of resampled 16 kHz mono Float32 samples. Append under lock,
    // drain under lock.
    private let fifoLock = NSLock()
    private var micFIFO: [Float] = []
    private var systemFIFO: [Float] = []

    private let pumpQueue = DispatchQueue(label: "hark.capture.pump", qos: .userInitiated)
    private var pumpTimer: DispatchSourceTimer?
    private var heartbeatTask: Task<Void, Never>?
    private var stopped = false

    public init(options: Options) throws {
        self.options = options
        self.writer = try WAVWriter(url: options.outputURL)
    }

    public func start() throws {
        if options.captureMic {
            let m = MicCapture()
            guard let r = Resampler(sourceFormat: m.sourceFormat) else {
                throw error("Could not build resampler for mic format \(m.sourceFormat)")
            }
            self.mic = m
            self.micResampler = r
            try m.start { [weak self] buf, _ in
                self?.ingestMic(buf)
            }
        }

        if options.captureSystem {
            let s = SystemAudioTap()
            try s.start { [weak self] buf, _ in
                // SystemAudioTap's sourceFormat is only known after start()
                // returns, so build the resampler lazily on the first buffer.
                self?.ingestSystem(buf)
            }
            guard let r = Resampler(sourceFormat: s.sourceFormat) else {
                s.stop()
                throw error("Could not build resampler for system format \(s.sourceFormat)")
            }
            self.system = s
            self.systemResampler = r
        }

        startPump()
        startHeartbeat()
    }

    public func stop() throws {
        guard !stopped else { return }
        stopped = true

        pumpTimer?.cancel()
        pumpTimer = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil

        mic?.stop()
        system?.stop()

        // Drain whatever's left in the FIFOs.
        drainOnce()
        try writer.close()
    }

    // MARK: - Source callbacks (Core Audio threads)

    private func ingestMic(_ buf: AVAudioPCMBuffer) {
        guard let resampler = micResampler else { return }
        guard let out = resampler.convert(buf) else { return }
        appendFloatSamples(out, into: \CapturePipeline.micFIFO)
    }

    private func ingestSystem(_ buf: AVAudioPCMBuffer) {
        guard let resampler = systemResampler else { return }
        guard let out = resampler.convert(buf) else { return }
        appendFloatSamples(out, into: \CapturePipeline.systemFIFO)
    }

    private func appendFloatSamples(
        _ buffer: AVAudioPCMBuffer,
        into keyPath: ReferenceWritableKeyPath<CapturePipeline, [Float]>
    ) {
        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let ptr = channelData[0]
        fifoLock.lock()
        self[keyPath: keyPath].append(contentsOf: UnsafeBufferPointer(start: ptr, count: frames))
        fifoLock.unlock()
    }

    // MARK: - Pump (100 ms cadence)

    private func startPump() {
        let timer = DispatchSource.makeTimerSource(queue: pumpQueue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.drainOnce()
        }
        timer.resume()
        self.pumpTimer = timer
    }

    private func drainOnce() {
        let frames = options.pumpFrames
        var micSlice: [Float]? = nil
        var sysSlice: [Float]? = nil

        fifoLock.lock()
        if options.captureMic {
            if micFIFO.count >= frames {
                micSlice = Array(micFIFO.prefix(frames))
                micFIFO.removeFirst(frames)
            } else if micFIFO.count >= options.underrunGraceFrames {
                // Have some, just not a full chunk — pad to size with silence.
                var s = micFIFO
                s.append(contentsOf: repeatElement(0, count: frames - s.count))
                micFIFO.removeAll(keepingCapacity: true)
                micSlice = s
            }
            // else: < grace frames available → leave nil (counts as underrun).
        }
        if options.captureSystem {
            if systemFIFO.count >= frames {
                sysSlice = Array(systemFIFO.prefix(frames))
                systemFIFO.removeFirst(frames)
            } else if systemFIFO.count >= options.underrunGraceFrames {
                var s = systemFIFO
                s.append(contentsOf: repeatElement(0, count: frames - s.count))
                systemFIFO.removeAll(keepingCapacity: true)
                sysSlice = s
            }
        }
        fifoLock.unlock()

        // If neither source has anything, skip this tick — keeps the WAV from
        // filling with leading silence while sources warm up.
        if micSlice == nil && sysSlice == nil { return }

        let samples: [Int16] = micSlice.withUnsafeBufferPointerOrNil { micPtr in
            sysSlice.withUnsafeBufferPointerOrNil { sysPtr in
                mixer.mix(mic: micPtr, system: sysPtr, frames: frames)
            }
        }

        try? writer.append(samples)
    }

    // MARK: - Heartbeat

    public var stats: Mixer.Stats { mixer.stats }

    private func startHeartbeat() {
        heartbeatTask = Task { [weak self] in
            let started = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                guard let self = self else { break }
                let elapsed = Int(Date().timeIntervalSince(started))
                let s = self.stats
                let line = """
                {"elapsed_s":\(elapsed),"frames_written":\(s.framesWritten),\
                "mic_underrun_frames":\(s.micUnderrunFrames),\
                "system_underrun_frames":\(s.systemUnderrunFrames),\
                "peak":\(String(format: "%.3f", s.peakAmplitude))}

                """
                FileHandle.standardError.write(Data(line.utf8))
            }
        }
    }

    private func error(_ msg: String) -> NSError {
        NSError(domain: "hark.capture.pipeline", code: -1,
                userInfo: [NSLocalizedDescriptionKey: msg])
    }
}

// Allows passing nil through a withUnsafeBufferPointer chain so we can use
// the same Mixer call for mic-only / system-only / both modes.
private extension Optional where Wrapped == [Float] {
    func withUnsafeBufferPointerOrNil<R>(_ body: (UnsafeBufferPointer<Float>?) -> R) -> R {
        switch self {
        case .some(let arr):
            return arr.withUnsafeBufferPointer { body($0) }
        case .none:
            return body(nil)
        }
    }
}
