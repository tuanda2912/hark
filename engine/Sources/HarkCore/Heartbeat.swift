// Heartbeat — prints "[ N s elapsed ] <label>..." on a background Task.
// Used while WhisperKit compiles for ANE (no progress API for that step).
//
// Swift `Task { ... }` ≈ Kotlin coroutine scope. Returns a cancellable handle.
// `Task.sleep` is non-blocking (suspends, doesn't park a kernel thread).

import Foundation

/// Starts a heartbeat ticker. Cancel the returned task when work completes.
/// - Parameters:
///   - label: text appended after "elapsed".
///   - intervalSeconds: tick interval.
///   - output: file handle to write to. Defaults to stderr so JSON on stdout
///     stays clean for piping into `jq`.
@discardableResult
public func startHeartbeat(
    label: String,
    intervalSeconds: UInt64 = 5,
    output: FileHandle = .standardError
) -> Task<Void, Never> {
    let started = Date()
    return Task {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: intervalSeconds * 1_000_000_000)
            if Task.isCancelled { break }
            let elapsed = Int(Date().timeIntervalSince(started))
            let line = "  [ \(elapsed)s elapsed ] \(label)...\n"
            output.write(Data(line.utf8))
        }
    }
}
