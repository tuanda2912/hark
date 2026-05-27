// hark-capture — Phase 2 audio capture CLI.
//
// System audio (Core Audio Process Tap) + mic (AVAudioEngine) → resample
// to 16 kHz mono Float32 → sum + tanh soft-clip → Int16 → WAV file.
//
// Architecture decisions: see ADR-0006.
//
// Java analogue: this file is the `public static void main` for the binary.
// `@main` + an `AsyncParsableCommand` from swift-argument-parser is the
// idiomatic shape — same role as picocli's @Command in a Spring Boot CLI.

import ArgumentParser
import Foundation

@available(macOS 14.4, *)
@main
struct HarkCapture: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hark-capture",
        abstract: "Capture system audio + microphone to a 16 kHz mono WAV file.",
        discussion: """
        Records system audio (whatever is playing through the default output \
        device, e.g. a meeting app) and the default microphone, mixes them \
        into a single WAV file the Hark engine can transcribe.

        Requires macOS 14.4+. On first run, grant Microphone and Screen \
        Recording permission in System Settings → Privacy & Security.
        """
    )

    @Option(name: .long, help: "Recording duration in seconds. Omit to record until SIGINT.")
    var duration: Double?

    @Option(name: .shortAndLong, help: "Output WAV path. Required unless --check-permissions.")
    var output: String?

    @Flag(name: .long, help: "Capture only the microphone.")
    var micOnly: Bool = false

    @Flag(name: .long, help: "Capture only system audio.")
    var systemOnly: Bool = false

    @Flag(name: .long, help: "Check TCC permissions and exit. Code 0 = granted, 3 = missing.")
    var checkPermissions: Bool = false

    mutating func run() async throws {
        if checkPermissions {
            // Pure preflight only — must never trigger a prompt (scripts).
            let status = PermissionGate.check()
            status.printReport(to: FileHandle.standardError)
            throw ExitCode(status.exitCode)
        }

        // Normal run: actively request anything missing so the macOS dialog
        // appears on first run (ADR-0007). Re-checks after requesting.
        let status = await PermissionGate.ensureGranted()
        if !status.allGranted {
            status.printReport(to: FileHandle.standardError, afterRequest: true)
            throw ExitCode(3)
        }

        if micOnly && systemOnly {
            throw ValidationError("--mic-only and --system-only are mutually exclusive")
        }
        guard let outputPath = output else {
            throw ValidationError("--output <path> is required when recording")
        }

        let captureMic = !systemOnly
        let captureSystem = !micOnly
        let outURL = URL(fileURLWithPath: outputPath)

        let opts = CapturePipeline.Options(
            captureMic: captureMic,
            captureSystem: captureSystem,
            outputURL: outURL
        )
        let pipeline = try CapturePipeline(options: opts)

        FileHandle.standardError.write(Data("hark-capture: starting (mic=\(captureMic) system=\(captureSystem)) → \(outputPath)\n".utf8))
        try pipeline.start()

        // Coordinate stop via either SIGINT or the optional --duration timer.
        // CheckedContinuation lets the duration timer and the signal source
        // both signal "we're done" without busy-waiting.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let resumeOnce = OneShotResume(cont: cont)

            // SIGINT handler. We install via DispatchSource so we can react
            // without blocking the cooperative Task pool. Default SIGINT
            // disposition would terminate the process before we close the
            // WAV header — we explicitly ignore the default action.
            signal(SIGINT, SIG_IGN)
            let sigSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            sigSource.setEventHandler {
                FileHandle.standardError.write(Data("\nhark-capture: SIGINT received, stopping…\n".utf8))
                resumeOnce.fire()
            }
            sigSource.resume()
            resumeOnce.signalSource = sigSource

            // Optional duration timer.
            if let secs = duration, secs > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
                    FileHandle.standardError.write(Data("hark-capture: duration reached, stopping…\n".utf8))
                    resumeOnce.fire()
                }
            }
        }

        do {
            try pipeline.stop()
        } catch {
            FileHandle.standardError.write(Data("hark-capture: error closing output: \(error)\n".utf8))
            throw ExitCode(1)
        }
        let finalStats = pipeline.stats
        let durationSeconds = Double(finalStats.framesWritten) / 16_000.0
        FileHandle.standardError.write(Data(String(
            format: "hark-capture: wrote %.2fs to %@ (mic_underrun=%d sys_underrun=%d peak=%.3f)\n",
            durationSeconds, outputPath,
            finalStats.micUnderrunFrames, finalStats.systemUnderrunFrames,
            finalStats.peakAmplitude
        ).utf8))
    }
}

/// Resume a continuation exactly once. Dispatch sources or timers may fire
/// in either order; the first one wins, subsequent fires are no-ops.
@available(macOS 14.4, *)
private final class OneShotResume: @unchecked Sendable {
    private let cont: CheckedContinuation<Void, Never>
    private var fired = false
    private let lock = NSLock()
    var signalSource: DispatchSourceSignal?

    init(cont: CheckedContinuation<Void, Never>) { self.cont = cont }

    func fire() {
        lock.lock()
        let shouldFire = !fired
        fired = true
        lock.unlock()
        guard shouldFire else { return }
        signalSource?.cancel()
        cont.resume()
    }
}
