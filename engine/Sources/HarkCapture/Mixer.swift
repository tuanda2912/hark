// Mixer — sums two 16 kHz mono Float32 streams, soft-clips, emits Int16.
//
// Both sources push timestamped frames (via mach_absolute_time) into separate
// ring buffers. The mixer pulls the earliest aligned window (default 100 ms
// = 1600 frames at 16 kHz) from each, sums sample-wise, applies tanh(x*0.9)
// soft-clip, scales to Int16, and forwards to the WAV writer.
//
// If a source falls behind by more than `underrunToleranceMs`, the missing
// frames are treated as silence and the underrun counter increments. The
// recording continues — losing one source to a glitch is better than aborting.

import Foundation

public final class Mixer {
    public struct Stats {
        public var framesWritten: Int = 0
        public var micUnderrunFrames: Int = 0
        public var systemUnderrunFrames: Int = 0
        public var peakAmplitude: Float = 0
    }

    public private(set) var stats = Stats()

    /// Mixes one aligned chunk of `frames` samples from each source. Either
    /// buffer may be nil to indicate that source is disabled or underrunning;
    /// nil is treated as silence and the corresponding underrun counter is
    /// incremented.
    /// Returns Int16 PCM samples ready for the WAV writer.
    public func mix(
        mic: UnsafeBufferPointer<Float>?,
        system: UnsafeBufferPointer<Float>?,
        frames: Int
    ) -> [Int16] {
        var out = [Int16](repeating: 0, count: frames)
        if mic == nil { stats.micUnderrunFrames += frames }
        if system == nil { stats.systemUnderrunFrames += frames }

        for i in 0..<frames {
            let m = mic?[i] ?? 0
            let s = system?[i] ?? 0
            let summed = m + s
            // tanh(x * 0.9): identity-like near zero, gently saturates near ±1.
            let limited = tanhf(summed * 0.9)
            stats.peakAmplitude = max(stats.peakAmplitude, abs(limited))
            let scaled = limited * 32_767
            out[i] = Int16(max(-32_768, min(32_767, scaled)))
        }
        stats.framesWritten += frames
        return out
    }
}
