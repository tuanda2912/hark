// SystemAudioTap — Core Audio Process Tap on the default output device.
//
// macOS 14.4+ Process Taps (ADR-0006 §"Capture API") let us read the mixed
// system-audio stream without a kernel extension or virtual device. The
// flow is:
//   1. Build a CATapDescription that targets all processes ("global tap")
//      mixed into the default output, in mono-mixdown / non-private form.
//   2. AudioHardwareCreateProcessTap → tap AudioObjectID.
//   3. Create a private aggregate device whose sub-tap list contains the
//      tap UID, bound to the default output's UID. The aggregate is the
//      thing we actually drive IO on; the tap by itself has no IOProc.
//   4. AudioDeviceCreateIOProcIDWithBlock on the aggregate; in the proc,
//      wrap the AudioBufferList into an AVAudioPCMBuffer (no-copy) and
//      hand it to the caller.
//
// Threading: the IOProc fires on a Core Audio realtime thread. We do not
// allocate ObjC objects, take locks, or call into Swift runtime metadata
// beyond constructing the AVAudioPCMBuffer wrapper (which is necessary to
// preserve the existing BufferHandler contract shared with MicCapture).
//
// Entitlements: on a signed/sandboxed app, the Process Tap path is gated
// by `com.apple.security.device.audio-input` plus Screen Recording TCC.
// This binary is built from source by the dev with no Developer account,
// so it runs unsigned; TCC still applies (CGRequestScreenCaptureAccess
// must have been granted). If a future macOS hardens this to require a
// real entitlement, ADR-0006 calls out the SCK audio-only fallback.

import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

@available(macOS 14.4, *)
public final class SystemAudioTap {
    public typealias BufferHandler = (AVAudioPCMBuffer, AVAudioTime) -> Void

    // Set in start(), torn down in stop(). All three are 0 / nil when idle.
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?

    // Captured at start() so the realtime IOProc can build AVAudioPCMBuffers
    // without touching `self` for the format (which would require a Swift
    // metadata lookup on the audio thread).
    private var runningFormat: AVAudioFormat?

    // Handler retained for the duration of a start/stop cycle.
    private var handler: BufferHandler?

    public init() {}

    /// Native format the tap delivers. Before `start()`, returns a sensible
    /// 48 kHz stereo Float32 default — the typical default-output shape.
    /// After `start()`, reflects what Core Audio actually negotiated.
    public var sourceFormat: AVAudioFormat {
        if let fmt = runningFormat { return fmt }
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        )!
    }

    public func start(onBuffer: @escaping BufferHandler) throws {
        guard tapID == kAudioObjectUnknown else {
            throw Self.error(-1, "SystemAudioTap.start called while already running")
        }

        // 1. Resolve the default output device and its UID. The tap targets
        //    "all processes mixed into this output", so we need the device
        //    UID to pin the aggregate to the right hardware endpoint.
        let outputDevice = try Self.defaultOutputDevice()
        let outputUID = try Self.deviceUID(outputDevice)

        // 2. Build the tap description. `init(stereoMixdownOfProcesses:)` with
        //    an empty list means "all processes" per the WWDC 2024 session
        //    10160 pattern; setting muteBehavior to .unmuted means we observe
        //    the live mix without forcing silence on the user's speakers.
        let tapDesc = CATapDescription(stereoMixdownOfProcesses: [])
        tapDesc.muteBehavior = .unmuted
        tapDesc.isPrivate = true   // tap visible only to this process
        tapDesc.isExclusive = false

        // 3. Create the tap. AudioObjectID out-param; non-zero status throws.
        var createdTapID: AudioObjectID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(tapDesc, &createdTapID)
        guard tapStatus == noErr, createdTapID != kAudioObjectUnknown else {
            throw Self.error(tapStatus, "AudioHardwareCreateProcessTap failed")
        }
        self.tapID = createdTapID

        // Pull the tap's UID — we reference it from the aggregate's sub-tap
        // list by UID string, not by AudioObjectID.
        let tapUID: String
        do {
            tapUID = try Self.stringProperty(
                createdTapID,
                selector: kAudioTapPropertyUID
            )
        } catch {
            cleanupAfterFailure()
            throw error
        }

        // 4. Build the private aggregate device that wraps the tap. The keys
        //    are documented in <CoreAudio/AudioHardware.h>. `IsPrivate = 1`
        //    keeps it out of system-wide device lists. `Tap UID List` is the
        //    macOS 14.2+ key that wires the process tap in as the aggregate's
        //    audio source.
        let aggregateUID = "hark.systemtap.\(UUID().uuidString)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Hark System Tap",
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceIsStackedKey as String: 0,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUID,
                    kAudioSubTapDriftCompensationKey as String: 0
                ]
            ],
            kAudioAggregateDeviceTapAutoStartKey as String: 1
        ]

        var createdAggID: AudioObjectID = kAudioObjectUnknown
        let aggStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &createdAggID
        )
        guard aggStatus == noErr, createdAggID != kAudioObjectUnknown else {
            cleanupAfterFailure()
            throw Self.error(aggStatus, "AudioHardwareCreateAggregateDevice failed")
        }
        self.aggregateID = createdAggID

        // 5. Read the aggregate's input stream description so we can build an
        //    AVAudioFormat that matches what the IOProc will actually receive.
        //    The aggregate exposes the tap on its input scope.
        let asbd: AudioStreamBasicDescription
        do {
            asbd = try Self.streamFormat(createdAggID, scope: kAudioDevicePropertyScopeInput)
        } catch {
            cleanupAfterFailure()
            throw error
        }
        var mutableASBD = asbd
        guard let avFormat = AVAudioFormat(streamDescription: &mutableASBD) else {
            cleanupAfterFailure()
            throw Self.error(-1, "Could not build AVAudioFormat from tap ASBD")
        }
        self.runningFormat = avFormat
        self.handler = onBuffer

        // 6. Install the IOProc. The block captures only Sendable-ish values
        //    (the format reference and handler) — both already retained by
        //    `self`. We deliberately avoid `[weak self]`: weak-resolve on the
        //    audio thread does a runtime ref-count op, and stop() guarantees
        //    the proc is destroyed before we drop the format/handler.
        let capturedFormat = avFormat
        let capturedHandler = onBuffer

        var newProcID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(
            &newProcID,
            createdAggID,
            nil  // run on Core Audio's default IO thread
        ) { _, inputDataPtr, inputTimePtr, _, _ in
            // Wrap the incoming AudioBufferList without copying. The buffer
            // memory is owned by Core Audio for the duration of this call;
            // the BufferHandler must consume it synchronously (matches the
            // contract MicCapture already establishes).
            guard let pcm = AVAudioPCMBuffer(
                pcmFormat: capturedFormat,
                bufferListNoCopy: inputDataPtr,
                deallocator: nil
            ) else {
                return
            }

            // Synthesize an AVAudioTime from the IOProc's input timestamp.
            // We pass the raw AudioTimeStamp through; AVAudioTime will pick
            // up host-time / sample-time as available.
            var ts = inputTimePtr.pointee
            let avTime = AVAudioTime(audioTimeStamp: &ts, sampleRate: capturedFormat.sampleRate)

            capturedHandler(pcm, avTime)
        }

        guard procStatus == noErr, let procID = newProcID else {
            cleanupAfterFailure()
            throw Self.error(procStatus, "AudioDeviceCreateIOProcIDWithBlock failed")
        }
        self.ioProcID = procID

        let startStatus = AudioDeviceStart(createdAggID, procID)
        guard startStatus == noErr else {
            cleanupAfterFailure()
            throw Self.error(startStatus, "AudioDeviceStart failed")
        }
    }

    public func stop() {
        if aggregateID != kAudioObjectUnknown, let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil

        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }

        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }

        runningFormat = nil
        handler = nil
    }

    // MARK: - Cleanup on partial-init failure

    /// Tear down whatever was allocated before an error. Idempotent across
    /// the three possible partial states (tap only, tap+agg, tap+agg+proc).
    private func cleanupAfterFailure() {
        if aggregateID != kAudioObjectUnknown, let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil

        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }

        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }

        runningFormat = nil
        handler = nil
    }

    // MARK: - Core Audio HAL helpers

    private static func defaultOutputDevice() throws -> AudioObjectID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0, nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw error(status, "Could not resolve default output device")
        }
        return deviceID
    }

    private static func deviceUID(_ deviceID: AudioObjectID) throws -> String {
        try stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    /// Read a CFString-typed HAL property as a Swift String.
    private static func stringProperty(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cfStr: CFString? = nil
        let status = withUnsafeMutablePointer(to: &cfStr) { ptr -> OSStatus in
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let str = cfStr as String? else {
            throw error(status, "Could not read string property 0x\(String(selector, radix: 16))")
        }
        return str
    }

    /// Read the AudioStreamBasicDescription for the first input stream of a
    /// device on the given scope. The aggregate's tap audio surfaces on the
    /// input scope; querying the device's stream-format property gives us
    /// the exact shape the IOProc will deliver.
    private static func streamFormat(
        _ deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) throws -> AudioStreamBasicDescription {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &asbd)
        guard status == noErr else {
            throw error(status, "Could not read AudioStreamBasicDescription")
        }
        return asbd
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
