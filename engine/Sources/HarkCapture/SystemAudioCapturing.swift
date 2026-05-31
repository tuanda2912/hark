// SystemAudioCapturing — the interface both system-audio backends implement.
//
// Hark has two ways to capture the mixed system-audio stream:
//
//   1. SystemAudioTap        — ScreenCaptureKit (SCStream). The DEFAULT and
//                              the only path proven to work for our unsigned
//                              dev CLI (it rides the Screen Recording TCC
//                              grant we already have).
//   2. CoreAudioProcessTap   — Core Audio Process Taps (macOS 14.4+). The
//                              path we want to re-test now that we know it
//                              needs the distinct `kTCCServiceAudioCapture`
//                              permission (see CoreAudioProcessTap.swift).
//
// This protocol is the seam between them. CapturePipeline talks to whichever
// backend was selected purely through this interface, so swapping backends is
// a one-line factory change and never touches the pump/FIFO/mixer logic.
//
// Java/Spring analogue: this is the interface, the two classes are the @Service
// implementations, and CapturePipeline picks one at runtime the way you'd pick
// a bean by @Profile / a config flag. `any SystemAudioCapturing` is Swift's
// "existential" — a reference typed by protocol rather than concrete class,
// i.e. exactly what a `SystemAudioCapturing field` is in Java.
//
// The members are identical to what SystemAudioTap already exposes, so making
// the existing backend conform is pure additive work — no behavior change.

import AVFoundation

@available(macOS 14.4, *)
public protocol SystemAudioCapturing: AnyObject {
    /// Native format the backend delivers. Valid both before and after
    /// `start()` (backends return a sensible default pre-start). CapturePipeline
    /// reads this immediately after `start()` returns to build its Resampler.
    var sourceFormat: AVAudioFormat { get }

    /// Begin capture. `onBuffer` is invoked for every delivered PCM buffer on
    /// the backend's own audio thread; the handler must consume synchronously
    /// and must not block. Throws if setup fails (no audio device, permission
    /// denied at the API level, etc.).
    func start(onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) throws

    /// Stop capture and release all resources. Safe to call when already idle.
    func stop()
}
