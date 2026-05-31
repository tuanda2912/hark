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

    // MARK: - Audio Capture TCC (PRIVATE SPI — dev-only, Process-Tap path)
    //
    // ⚠️ PRIVATE-API SMELL. Everything in this section calls Apple's
    // *unpublished* TCC framework via dlopen/dlsym. There is no public Swift
    // or C header for `TCCAccessPreflight` / `TCCAccessRequest`; we resolve
    // them by symbol name at runtime. This is fragile (Apple can rename or
    // remove these at any OS update) and would get an App Store binary
    // rejected. It exists ONLY to test the Core Audio Process Tap backend on
    // our UNSIGNED dev CLI, and is reached ONLY behind `HARK_ENABLE_TCC_SPI=1`
    // from CoreAudioProcessTap — never from the default `ensureGranted()` flow.
    //
    // Why we need it at all: capturing system audio with Process Taps is gated
    // by a TCC service called `kTCCServiceAudioCapture` — a permission DISTINCT
    // from Microphone and Screen Recording. Our normal gate never requests it,
    // so no prompt ever appears and the tap is silently fed no audio. AudioCap
    // (Guilherme Rambo's reference) requests it via this same SPI.
    //
    // PRODUCTION PLAN: a signed .app bundle declares `NSAudioCaptureUsageDescription`
    // in its Info.plist and the system shows the prompt automatically through
    // the PUBLIC path — no dlopen, no SPI. This section gets deleted then.

    /// Path to the private TCC framework. Stable across recent macOS versions,
    /// but still an undocumented internal — hence the smell.
    private static let tccFrameworkPath =
        "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC"

    /// `TCCAccessPreflight(service, options) -> Int`. Return codes (observed):
    /// 0 = authorized, 1 = denied, 2 (or other) = undetermined/unknown.
    private typealias TCCPreflightFn = @convention(c) (CFString, CFDictionary?) -> Int

    /// `TCCAccessRequest(service, options, reply)`. Fires the system prompt (if
    /// undetermined) and calls `reply(granted)` on completion.
    private typealias TCCRequestFn =
        @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    private static let audioCaptureService = "kTCCServiceAudioCapture" as CFString

    /// Preflight the audio-capture TCC service WITHOUT prompting. For
    /// diagnostics only. Returns "authorized" / "denied" / "unknown"
    /// ("unknown" also covers "could not load the SPI").
    ///
    /// ⚠️ PRIVATE API — see the section header. Only call from the dev tap path.
    public static func audioCaptureStatusViaSPI() -> String {
        guard let handle = dlopen(tccFrameworkPath, RTLD_NOW) else { return "unknown" }
        defer { dlclose(handle) }
        guard let sym = dlsym(handle, "TCCAccessPreflight") else { return "unknown" }
        let preflight = unsafeBitCast(sym, to: TCCPreflightFn.self)
        switch preflight(audioCaptureService, nil) {
        case 0: return "authorized"
        case 1: return "denied"
        default: return "unknown"
        }
    }

    /// Request the audio-capture TCC service, firing the system prompt if the
    /// state is undetermined. Returns the user's decision (true = granted).
    ///
    /// async/await here is like a Kotlin coroutine wrapping a callback API: we
    /// suspend until `reply(granted)` fires, then resume with that Bool. The
    /// caller (CoreAudioProcessTap.start, which is synchronous) bridges this
    /// back to sync with a DispatchSemaphore, exactly like the SCK start does.
    ///
    /// ⚠️ PRIVATE API — see the section header. Opt-in via HARK_ENABLE_TCC_SPI.
    public static func requestAudioCaptureViaSPI() async -> Bool {
        guard let handle = dlopen(tccFrameworkPath, RTLD_NOW) else { return false }
        guard let sym = dlsym(handle, "TCCAccessRequest") else {
            dlclose(handle)
            return false
        }
        let request = unsafeBitCast(sym, to: TCCRequestFn.self)
        let granted: Bool = await withCheckedContinuation { cont in
            request(audioCaptureService, nil) { granted in
                cont.resume(returning: granted)
            }
        }
        // Keep `handle` alive until the callback has fired (the function
        // pointer we called lives in that image); only now is it safe to close.
        dlclose(handle)
        return granted
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
