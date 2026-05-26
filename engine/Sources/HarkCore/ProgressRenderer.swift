// HarkCore — shared between hark-bench and hark-engine binaries.
//
// ProgressRenderer: terminal progress bar that updates in place using \r.
// Pulled out of HarkBench so the Phase 1 batch engine can reuse it during
// first-run model download.
//
// ──────────────────────────────────────────────────────────────────────────
// Swift idioms for a Java/Spring dev:
//   `public`          ≈ Java `public`. Default in Swift is `internal`
//                      (module-private), which is stricter than Java's
//                      package-private. We mark this `public` because it's
//                      called from a different module (HarkBench, HarkEngine).
//   `final class`     ≈ Java `final class`. No subclassing.
//   `@unchecked Sendable` — promise to the compiler that we manage
//                      thread-safety ourselves. We do — via the internal
//                      DispatchQueue. The "unchecked" is the equivalent of
//                      Java `@SuppressWarnings("rawtypes")`: "I know what
//                      I'm doing, stop yelling."
// ──────────────────────────────────────────────────────────────────────────

import Foundation

/// Renders a progress line that updates in place. Writes to the chosen
/// `FileHandle` so callers can route to stderr (engine CLI) or stdout (bench).
public final class ProgressRenderer: @unchecked Sendable {
    private let output: FileHandle
    private let label: String
    private var lastPrintedAt = Date(timeIntervalSince1970: 0)
    private var lastBytes: Int64 = 0
    private var lastBytesAt = Date()
    private let queue = DispatchQueue(label: "hark.core.progress")
    private var finished = false

    public init(label: String = "Downloading model", output: FileHandle = .standardError) {
        self.label = label
        self.output = output
    }

    /// Called from WhisperKit's download callback. May fire on any thread —
    /// we serialise through `queue`. Throttled to ~10 redraws/sec.
    public func update(_ progress: Progress) {
        queue.sync {
            guard !finished else { return }
            let now = Date()
            if now.timeIntervalSince(lastPrintedAt) < 0.1 && progress.fractionCompleted < 1.0 {
                return
            }
            lastPrintedAt = now

            let frac = progress.fractionCompleted
            let done = progress.completedUnitCount
            let total = max(progress.totalUnitCount, 1)

            let dt = max(now.timeIntervalSince(lastBytesAt), 0.001)
            let bps = Double(done - lastBytes) / dt
            lastBytes = done
            lastBytesAt = now

            let bar = renderBar(frac: frac, width: 20)
            let mbDone = Double(done) / 1_048_576.0
            let mbTotal = Double(total) / 1_048_576.0
            let mbps = bps / 1_048_576.0
            let etaStr: String
            if bps > 1024 && frac < 1.0 {
                let remaining = Double(total - done) / bps
                etaStr = "ETA \(formatDuration(remaining))"
            } else {
                etaStr = "ETA --"
            }

            let line = String(format: "%@: %@ %3d%% · %.0f MB / %.0f MB · %.1f MB/s · %@",
                              label, bar, Int(frac * 100), mbDone, mbTotal, mbps, etaStr)
            output.write(Data("\r\(line)   ".utf8))
        }
    }

    public func finish() {
        queue.sync {
            finished = true
            output.write(Data("\n".utf8))
        }
    }

    private func renderBar(frac: Double, width: Int) -> String {
        let filled = Int((Double(width) * frac).rounded())
        return String(repeating: "\u{2501}", count: filled)
            + String(repeating: "\u{2591}", count: width - filled)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m\(s % 60)s"
    }
}
