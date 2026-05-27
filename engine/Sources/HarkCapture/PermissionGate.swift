// PermissionGate — TCC checks + active request for hark-capture.
//
// Decision: actively request missing permissions on first run so the macOS
// system dialog appears (ADR-0007), superseding the preflight-only design
// from ADR-0006 §3. Pure preflight is still available via `check()` and is
// what `--check-permissions` uses (scripts must never trigger a prompt).
//
// Attribution caveat (ADR-0007): for an unsigned dev-built CLI, TCC keys on
// the parent terminal's signing identity. The prompt says "Terminal" (or
// iTerm / Ghostty / etc.), not "hark-capture". The grant works correctly;
// only the label is off. Fixed when we ship a signed .app bundle.
//
// Why CoreGraphics for screen capture? `CGPreflightScreenCaptureAccess()`
// reads TCC state without firing a prompt; `CGRequestScreenCaptureAccess()`
// fires the prompt and returns immediately. The matching pair is exactly
// what we want for "check, then request if missing".

import AVFoundation
import CoreGraphics
import Foundation

public enum PermissionGate {
    public struct Status {
        public let micGranted: Bool
        public let screenGranted: Bool

        public var allGranted: Bool { micGranted && screenGranted }
        public var exitCode: Int32 { allGranted ? 0 : 3 }
    }

    /// Pure preflight. Does NOT trigger a system prompt. Safe for scripts
    /// and for `--check-permissions`.
    public static func check() -> Status {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let screen = CGPreflightScreenCaptureAccess()
        return Status(micGranted: mic, screenGranted: screen)
    }

    /// First-run flow: read state, then actively request anything missing
    /// so macOS shows the system dialog. Returns the *post-request* state.
    ///
    /// Mic is requested via `AVCaptureDevice.requestAccess` which awaits
    /// the user's choice. Screen recording is requested via
    /// `CGRequestScreenCaptureAccess` which returns immediately — its grant
    /// only takes effect after the parent terminal relaunches, so a re-run
    /// hint is the right UX there.
    public static func ensureGranted() async -> Status {
        var status = check()

        if !status.micGranted {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { _ in
                    cont.resume()
                }
            }
        }

        if !status.screenGranted {
            // Returns true if access is already granted (rare here — we just
            // checked) and false otherwise. The side effect — firing the
            // prompt — is what we want.
            _ = CGRequestScreenCaptureAccess()
        }

        status = check()
        return status
    }
}

extension PermissionGate.Status {
    /// - Parameter afterRequest: true if `ensureGranted()` was just called
    ///   (so a dialog should have just appeared); false for pure preflight.
    public func printReport(to handle: FileHandle, afterRequest: Bool = false) {
        if allGranted {
            handle.write(Data("hark-capture: permissions OK (microphone + screen recording granted)\n".utf8))
            return
        }

        var lines: [String] = ["hark-capture: missing permission(s):"]
        if !micGranted {
            lines.append("  • Microphone")
            if afterRequest {
                lines.append("    A system dialog should have appeared. If you clicked Don't Allow,")
                lines.append("    re-enable in: System Settings → Privacy & Security → Microphone")
            } else {
                lines.append("    Grant in: System Settings → Privacy & Security → Microphone")
                lines.append("    (or just run `hark-capture` without --check-permissions to be prompted)")
            }
        }
        if !screenGranted {
            lines.append("  • Screen Recording (required for system-audio Process Tap)")
            if afterRequest {
                lines.append("    A system dialog should have appeared. After clicking Allow,")
                lines.append("    quit your terminal app, reopen it, and re-run hark-capture —")
                lines.append("    macOS only honors the new grant after the terminal restarts.")
                lines.append("    If the dialog did not appear, grant manually in:")
                lines.append("      System Settings → Privacy & Security → Screen Recording")
            } else {
                lines.append("    Grant in: System Settings → Privacy & Security → Screen Recording")
                lines.append("    (or just run `hark-capture` without --check-permissions to be prompted)")
            }
        }
        if afterRequest {
            lines.append("Note: the dialog attributes to your terminal app (Terminal/iTerm/etc.),")
            lines.append("not to hark-capture — this is normal for unsigned dev builds (ADR-0007).")
        }
        handle.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }
}
