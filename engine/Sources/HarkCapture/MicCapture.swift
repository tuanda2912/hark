// MicCapture — AVAudioEngine input node → AVAudioPCMBuffer chunks.
//
// We install a tap on the engine's inputNode with the input's native format
// (typically 44.1 or 48 kHz, mono or stereo float32 depending on device).
// The Resampler downstream is responsible for normalising to 16 kHz mono.
//
// Threading: the tap callback is invoked on a Core Audio thread. We hand
// the buffer off to the caller's closure synchronously; the caller is
// responsible for not blocking that thread.

import AVFoundation
import Foundation

public final class MicCapture {
    public typealias BufferHandler = (AVAudioPCMBuffer, AVAudioTime) -> Void

    private let engine = AVAudioEngine()
    private var handler: BufferHandler?

    public init() {}

    public var sourceFormat: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    public func start(onBuffer: @escaping BufferHandler) throws {
        self.handler = onBuffer
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // 1024-frame chunks ≈ 21 ms at 48 kHz — small enough for low latency,
        // big enough that the converter and ring buffer aren't busy-looping.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, when in
            self?.handler?(buf, when)
        }
        try engine.start()
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
