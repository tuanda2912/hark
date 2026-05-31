// SystemAudioTap — system-audio capture via ScreenCaptureKit (SCStream).
//
// ── Why ScreenCaptureKit instead of Core Audio Process Taps ────────────────
// This file used to drive a Core Audio "process tap" (AudioHardwareCreateProcessTap
// + a private aggregate device + an IOProc). On macOS 15+ that path is gated
// behind the "Audio Recording" TCC class, which an UNSIGNED, ad-hoc-signed,
// LaunchServices-unregistered dev build cannot acquire: no permission prompt
// ever appears, the binary never shows up under System Settings → Screen &
// System Audio Recording, and the IOProc never fires even though every
// Core Audio call returns status=0 with a valid 48 kHz/2ch format. Empirically
// dead for our build mode.
//
// ScreenCaptureKit captures system audio under the *Screen Recording* TCC
// grant instead — which this environment already has (PermissionGate preflights
// it via CGPreflightScreenCaptureAccess). So we switch the capture engine to an
// SCStream while keeping this class's public API byte-identical. This supersedes
// ADR-0006's "Capture API" choice (Process Taps).
//
// ── How SCK audio capture works (for a JVM/Spring reader) ──────────────────
// SCStream is Apple's screen+audio capture pipeline. You describe WHAT to
// capture with an SCContentFilter (here: the main display), HOW with an
// SCStreamConfiguration (resolution, frame rate, audio on/off, sample rate…),
// then register one or more "outputs" (sinks). Each output is an object that
// conforms to SCStreamOutput and receives CMSampleBuffers on a queue you pick —
// conceptually a callback subscriber, like an RxJava Subscriber pulling items
// off a Scheduler. We register ONE output, for audio only, and ignore video.
//
// SMELL (also flagged in ADR-0006): SCK has no audio-only mode. To get audio
// you MUST configure and run a video stream too. We therefore set a deliberately
// tiny, slow video config (2×2 px, ~1 fps) and silently drop every video sample
// buffer. The video pixels are never read, decoded, or written anywhere. This
// is the documented Apple workaround, not an oversight.
//
// ── Threading ──────────────────────────────────────────────────────────────
// Audio sample buffers arrive on a dedicated serial DispatchQueue (see
// `sampleQueue`). We convert each CMSampleBuffer to an AVAudioPCMBuffer
// (copying the samples so they outlive the callback) and hand it to the
// caller's BufferHandler synchronously — the exact contract MicCapture uses.
// The caller (CapturePipeline) must not block this queue.
//
// ── start() is sync but SCK is async ───────────────────────────────────────
// The public start(onBuffer:) is synchronous-throwing (the API contract,
// because CapturePipeline reads `sourceFormat` on the very next line). SCK's
// setup (SCShareableContent.current, SCStream.startCapture) is async. We bridge
// with a semaphore ONLY at the start() boundary; once running, all IO is async
// on the GCD queue. Any SCK setup error is propagated out of start() as a throw.

import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

@available(macOS 14.4, *)
public final class SystemAudioTap: NSObject, SCStreamOutput, SystemAudioCapturing {
    public typealias BufferHandler = (AVAudioPCMBuffer, AVAudioTime) -> Void

    // Live only between start() and stop(); nil when idle.
    private var stream: SCStream?
    private var handler: BufferHandler?

    // The actual AVAudioFormat SCK delivers, learned from the first audio
    // sample buffer (or negotiated during start — see start()). Read by
    // `sourceFormat` to build CapturePipeline's Resampler. Synchronized via
    // `formatLock` because it's written on the sample queue and read on the
    // start() thread.
    private var runningFormat: AVAudioFormat?
    private let formatLock = NSLock()

    // Dedicated serial queue for SCK sample delivery. A serial queue keeps
    // buffer ordering deterministic (no out-of-order audio) and means our
    // SCStreamOutput callback never re-enters itself.
    private let sampleQueue = DispatchQueue(label: "hark.capture.sck.audio", qos: .userInitiated)

    public override init() { super.init() }

    // Diagnostic logging, gated by env `HARK_TAP_DEBUG=1`. Off in normal runs
    // (incl. the daemon) so stderr stays clean; flip on to trace SCK setup and
    // confirm audio buffers actually arrive. Writes to stderr. (Kept the same
    // env var name and `hark-tap:` prefix as the old Process Tap path so the
    // existing test recipe and muscle memory still work.)
    private static let tapDebug = ProcessInfo.processInfo.environment["HARK_TAP_DEBUG"] != nil
    private static func dbg(_ s: String) {
        if tapDebug { FileHandle.standardError.write(Data("hark-tap: \(s)\n".utf8)) }
    }

    /// Counts audio-buffer deliveries so debug logging can prove the SCStream
    /// output callback actually fires (the crux of the old 0-frames symptom).
    private final class CallCounter: @unchecked Sendable { var n = 0 }
    private let dbgCounter = CallCounter()

    /// Native format the stream delivers. Before `start()` (and as a fallback
    /// if the first-buffer probe times out), returns the 48 kHz stereo Float32
    /// shape we ask SCK for in the configuration. After `start()`, reflects the
    /// exact AVAudioFormat of the audio sample buffers SCK actually delivers.
    public var sourceFormat: AVAudioFormat {
        formatLock.lock()
        let fmt = runningFormat
        formatLock.unlock()
        if let fmt { return fmt }
        return Self.defaultFormat
    }

    /// The 48 kHz stereo Float32 (non-interleaved) shape we request from SCK.
    /// SCK delivers deinterleaved Float32, so non-interleaved is the truthful
    /// default and also what the first-buffer-derived format will be.
    private static let defaultFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
    )!

    public func start(onBuffer: @escaping BufferHandler) throws {
        guard stream == nil else {
            throw Self.error(-1, "SystemAudioTap.start called while already running")
        }
        self.handler = onBuffer
        Self.dbg("start: requesting shareable content…")

        // 1. Resolve what we're allowed to capture. SCShareableContent.current
        //    enumerates displays/windows/apps and (importantly) is the call
        //    that surfaces the Screen Recording TCC gate. We only need a
        //    display to anchor the content filter.
        let content: SCShareableContent
        do {
            content = try Self.awaitThrowing { completion in
                SCShareableContent.getWithCompletionHandler { shareable, err in
                    completion(shareable, err)
                }
            }
        } catch {
            cleanupAfterFailure()
            throw Self.error(-2, "SCShareableContent failed: \(error.localizedDescription)")
        }
        guard let display = content.displays.first else {
            cleanupAfterFailure()
            throw Self.error(-3, "No display available for ScreenCaptureKit capture")
        }
        Self.dbg("shareable content resolved: \(content.displays.count) display(s), using \(display.width)x\(display.height)")

        // 2. Content filter: capture the main display, excluding no windows.
        //    We never read the video, so the visual content is irrelevant —
        //    the filter just has to be valid.
        let filter = SCContentFilter(display: display, excludingWindows: [])

        // 3. Stream configuration. Audio is what we're here for; the video
        //    config is the required no-op (see file header SMELL note).
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true   // don't capture our own output
        config.sampleRate = 48_000
        config.channelCount = 2
        // Minimal video stream: 2×2 px, ~1 frame/sec. SCK refuses to deliver
        // audio without a running video stream, so we make the video as cheap
        // as possible and drop every frame in the output callback.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps
        config.queueDepth = 6   // small buffer ring; we consume promptly

        // 4. Build the stream and register OURSELVES as the audio output sink.
        //    addStreamOutput delivers audio CMSampleBuffers to
        //    stream(_:didOutputSampleBuffer:of:) on `sampleQueue`.
        let scStream = SCStream(filter: filter, configuration: config, delegate: nil)
        do {
            try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        } catch {
            cleanupAfterFailure()
            throw Self.error(-4, "addStreamOutput(.audio) failed: \(error.localizedDescription)")
        }
        self.stream = scStream
        Self.dbg("stream created; starting capture…")

        // 5. Start capture (async → sync bridge via semaphore at the boundary).
        do {
            try Self.awaitThrowingVoid { completion in
                scStream.startCapture { err in completion(err) }
            }
        } catch {
            cleanupAfterFailure()
            throw Self.error(-5, "SCStream.startCapture failed: \(error.localizedDescription)")
        }
        Self.dbg("startCapture returned ok")

        // 6. Negotiate the real delivered format BEFORE start() returns, because
        //    CapturePipeline reads `sourceFormat` on the next line to build its
        //    Resampler. We block briefly for the first audio buffer, which sets
        //    `runningFormat` from the sample buffer's own CMFormatDescription.
        //    If no audio arrives within the window (e.g. dead silence on the
        //    output), we fall back to the requested 48 kHz/2ch default — which
        //    is what SCK is configured to deliver anyway, so the Resampler is
        //    still built correctly and real buffers will match it.
        if !waitForFirstFormat(timeout: 2.0) {
            formatLock.lock()
            if runningFormat == nil { runningFormat = Self.defaultFormat }
            formatLock.unlock()
            Self.dbg("no audio buffer within probe window; using default 48kHz/2ch format")
        }
    }

    public func stop() {
        guard let scStream = stream else { return }
        stream = nil
        // stopCapture is async; we don't need to wait for it to finish to
        // satisfy the (void) stop() contract. Fire it and tear down.
        scStream.stopCapture { err in
            if let err { Self.dbg("stopCapture error (ignored): \(err.localizedDescription)") }
        }
        // removeStreamOutput is best-effort; ignore errors during teardown.
        try? scStream.removeStreamOutput(self, type: .audio)
        handler = nil
        formatLock.lock()
        runningFormat = nil
        formatLock.unlock()
    }

    // MARK: - SCStreamOutput

    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        // We registered only for .audio, but guard anyway — ignore video.
        guard type == .audio else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let pcm = Self.makePCMBuffer(from: sampleBuffer) else {
            if Self.tapDebug {
                dbgCounter.n += 1
                if dbgCounter.n <= 3 {
                    FileHandle.standardError.write(Data("hark-tap: audio buffer arrived but PCM wrap FAILED (call #\(dbgCounter.n))\n".utf8))
                }
            }
            return
        }

        // Latch the delivered format on the very first buffer so start()'s
        // probe (and `sourceFormat`) report exactly what we emit.
        formatLock.lock()
        if runningFormat == nil { runningFormat = pcm.format }
        formatLock.unlock()

        // Diagnostic: prove the SCStream output callback fires and how many
        // frames each buffer carries. First five buffers only — same line
        // format the old Process Tap path emitted, so the test recipe is
        // unchanged: look for `hark-tap: ioproc call #1 frames=…`.
        if Self.tapDebug {
            dbgCounter.n += 1
            if dbgCounter.n <= 5 {
                FileHandle.standardError.write(Data("hark-tap: ioproc call #\(dbgCounter.n) frames=\(pcm.frameLength)\n".utf8))
            }
        }

        // Synthesize an AVAudioTime from the sample buffer's presentation
        // timestamp, expressed as host time. CapturePipeline ignores this
        // value today (it aligns by FIFO depth, not timestamps), but the
        // BufferHandler contract supplies it, so we provide a truthful one.
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostTime = AVAudioTime.hostTime(forSeconds: pts.seconds)
        let avTime = AVAudioTime(
            hostTime: hostTime,
            sampleTime: 0,
            atRate: pcm.format.sampleRate
        )

        handler?(pcm, avTime)
    }

    // MARK: - CMSampleBuffer → AVAudioPCMBuffer

    /// Convert an audio CMSampleBuffer to an AVAudioPCMBuffer, COPYING the
    /// samples so the result safely outlives this callback (SCK owns the
    /// underlying block buffer only for the duration of the call).
    ///
    /// Why copy instead of no-copy: AVAudioPCMBuffer(pcmFormat:bufferListNoCopy:)
    /// would alias SCK's memory, which is freed when this callback returns.
    /// CapturePipeline appends samples synchronously, so in practice a no-copy
    /// would survive — but the cost of a copy here (a few KB, ~hundreds of µs)
    /// is trivial next to the per-buffer resample work, and copying removes a
    /// whole class of lifetime bugs. Correctness over micro-optimization.
    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }
        // Build the AVAudioFormat straight from the CMFormatDescription. This
        // is more robust than reconstructing it from a bare ASBD: it carries
        // the channel layout and interleaving exactly as SCK delivers them, so
        // the destination buffer's shape always matches the source — which is
        // what the in-place ASBD approach got wrong (cause of "PCM wrap FAILED").
        let format = AVAudioFormat(cmAudioFormatDescription: formatDesc)

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        pcm.frameLength = frameCount

        // Copy SCK's PCM samples into pcm's own storage with the purpose-built
        // Core Media API. It understands BOTH the source sample buffer's layout
        // and the destination AudioBufferList, so interleaved vs deinterleaved
        // and channel count are handled correctly — no manual ABL sizing, no
        // retained block buffer to manage. The copy means the result safely
        // outlives this callback (SCK owns its block buffer only for the call).
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcm.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return pcm
    }

    // MARK: - Cleanup

    private func cleanupAfterFailure() {
        if let scStream = stream {
            scStream.stopCapture { _ in }
            try? scStream.removeStreamOutput(self, type: .audio)
        }
        stream = nil
        handler = nil
        formatLock.lock()
        runningFormat = nil
        formatLock.unlock()
    }

    // MARK: - First-buffer format probe

    /// Block (on the start() thread) until the first audio buffer has set
    /// `runningFormat`, or `timeout` seconds elapse. Returns true if a format
    /// was latched. Polls a lock-guarded flag rather than holding a condition
    /// variable across the SCK callback (simpler, and the window is tiny).
    private func waitForFirstFormat(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            formatLock.lock()
            let have = runningFormat != nil
            formatLock.unlock()
            if have { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        formatLock.lock()
        let have = runningFormat != nil
        formatLock.unlock()
        return have
    }

    // MARK: - async → sync bridges (start() boundary only)

    /// Bridge a completion-handler API that yields (T?, Error?) into a sync
    /// throwing call. Used ONLY in start(); the IO itself stays async on the
    /// sample queue. (Java analogue: blocking on a CompletableFuture.get()
    /// once, at startup, not on the hot path.)
    private static func awaitThrowing<T>(
        _ body: (@escaping (T?, Error?) -> Void) -> Void
    ) throws -> T {
        let sem = DispatchSemaphore(value: 0)
        var result: T?
        var failure: Error?
        body { value, err in
            result = value
            failure = err
            sem.signal()
        }
        sem.wait()
        if let failure { throw failure }
        guard let result else { throw error(-10, "async bridge produced neither value nor error") }
        return result
    }

    /// Bridge a completion-handler API that yields only an optional Error.
    private static func awaitThrowingVoid(
        _ body: (@escaping (Error?) -> Void) -> Void
    ) throws {
        let sem = DispatchSemaphore(value: 0)
        var failure: Error?
        body { err in
            failure = err
            sem.signal()
        }
        sem.wait()
        if let failure { throw failure }
    }

    private static func error(_ status: OSStatus, _ message: String) -> NSError {
        NSError(
            domain: "hark.capture.system",
            code: Int(status),
            userInfo: [
                NSLocalizedDescriptionKey: "\(message) (OSStatus=\(status))",
                "OSStatus": NSNumber(value: status)
            ]
        )
    }
}
