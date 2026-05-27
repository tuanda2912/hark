// Resampler — wraps AVAudioConverter for arbitrary-input → 16 kHz mono Float32.
//
// AVAudioConverter handles both rate conversion and channel downmix; we just
// have to feed it buffers and ask for output. The trick is that converter
// output may produce more or fewer frames than input on any given call, so
// we size the destination buffer generously and let `convert` tell us how
// many frames it actually wrote.

import AVFoundation
import Foundation

public final class Resampler {
    public let targetFormat: AVAudioFormat
    private let converter: AVAudioConverter

    public init?(sourceFormat: AVAudioFormat) {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else { return nil }
        guard let conv = AVAudioConverter(from: sourceFormat, to: target) else { return nil }
        self.targetFormat = target
        self.converter = conv
    }

    /// Converts one source buffer. Returns nil on converter error; returns
    /// an empty buffer (frameLength == 0) if the converter is buffering.
    public func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        // Output capacity heuristic: input frames scaled to target rate × 2
        // safety margin. Converter is allowed to produce fewer; frameLength
        // is set to the actual count.
        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio * 2.0 + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }

        switch status {
        case .haveData, .inputRanDry:
            return output
        case .endOfStream, .error:
            return nil
        @unknown default:
            return nil
        }
    }
}
