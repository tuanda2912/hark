// CoreAudioProcessTap — system-audio capture via Core Audio Process Taps.
//
// ── What this is ───────────────────────────────────────────────────────────
// macOS 14.4+ "Process Taps" let us read the mixed system-audio stream without
// a kernel extension or a virtual audio device. This is the SELECTABLE tap
// backend (the current default is SystemAudioTap = ScreenCaptureKit). It is
// PROVEN WORKING on macOS 26 — captures built-in-speaker and Bluetooth output
// (the latter without forcing A2DP→HFP, since we tap only rendered output).
// The full debug story and the exact recipe live in ADR-0011.
//
// Select it with env `HARK_CAPTURE_BACKEND=tap`. With anything else (or unset)
// CapturePipeline uses the ScreenCaptureKit backend.
//
// ── The Core Audio dance (for a JVM/Spring reader) ─────────────────────────
// Core Audio's HAL is a flat, C-style object database: every device/stream/tap
// is an `AudioObjectID` (an integer handle), and you read/write typed
// "properties" on it by (selector, scope, element) address. There's no OO
// surface — think JNDI lookups returning opaque handles. The flow:
//
//   1. Build a CATapDescription describing WHAT to tap. We use a GLOBAL tap
//      that excludes no processes → "everything mixed to the default output".
//   2. AudioHardwareCreateProcessTap → a tap AudioObjectID. The tap on its own
//      has no IO cycle; it's just a source.
//   3. Create a PRIVATE aggregate device that wraps the tap AND includes the
//      default OUTPUT device as its main sub-device + sole sub-device. The
//      output device is the CLOCK that drives the IO cycle; the tap rides
//      alongside it in the aggregate's tap list. (A tap-only aggregate with no
//      hardware clock never spins — see ADR-0011.)
//   4. AudioDeviceCreateIOProcIDWithBlock on the aggregate, passing a real
//      dispatch queue (NOT nil — the block variant requires one). The block
//      fires per buffer; we wrap it (no-copy) as an AVAudioPCMBuffer and hand
//      it to the caller's BufferHandler.
//   5. AudioDeviceStart to spin the cycle.
//
// ── The three things that made this actually work (ADR-0011) ───────────────
//   • PERMISSION + IDENTITY. Process Taps are gated by `kTCCServiceAudioCapture`
//     (distinct from Microphone and Screen Recording), and the request only
//     sticks for a STABLE signed identity. Dev builds request it via the
//     private TCC SPI behind `HARK_ENABLE_TCC_SPI=1` (see PermissionGate);
//     production ships a signed bundle with NSAudioCaptureUsageDescription and
//     uses the public path. An unsigned/terminal-attributed binary is denied
//     silently — every call returns noErr and the tap is fed nothing.
//   • A RUNNING CFRunLoop. AudioDeviceStart is async; the HAL delivers its
//     start completion on a CFRunLoop. A GUI app gets this from its main run
//     loop, but a CLI/daemon does not — so we run a real CFRunLoop on a
//     dedicated thread and point kAudioHardwarePropertyRunLoop at it. Without
//     it the device stays isRunning=0 and the IOProc never fires (every call
//     still returns noErr). Setting that property to NULL was a no-op here.
//   • NO isPrivate / isExclusive on the tap description. With them set the tap
//     binds (the aggregate shows one input stream) but the device never starts.
//     We leave them at their defaults, matching the working AudioCap reference.
//
//   Format note: we read kAudioTapPropertyFormat off the tap object itself
//   (authoritative), falling back to the aggregate's input-scope stream format
//   only if that read fails.
//
// ── Threading ──────────────────────────────────────────────────────────────
// The IOProc block is dispatched on a dedicated serial queue (Core Audio drives
// it at realtime priority). We avoid allocating ObjC objects, taking locks, or
// touching `self` from it — the block captures the format reference and handler
// by value, and stop() guarantees the proc is destroyed before we drop them.
// A SECOND dedicated thread runs the CFRunLoop that services HAL notifications.

import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

@available(macOS 14.4, *)
public final class CoreAudioProcessTap: SystemAudioCapturing {
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

    // Serial queue the IOProc block is dispatched on. The BLOCK variant of
    // AudioDeviceCreateIOProcIDWithBlock REQUIRES a real dispatch queue — unlike
    // the function-pointer variant, passing nil makes the call still return
    // noErr but the block is never invoked (the original 0-frames-yet-all-
    // statuses-OK bug). Core Audio retains the queue for the proc's lifetime;
    // we also hold it here so it can't be deallocated mid-cycle. AudioCap does
    // exactly this (one dedicated serial queue per tap).
    private var ioQueue: DispatchQueue?

    // Dedicated thread running a real CFRunLoop, used purely to service the
    // HAL's async notifications (device-start completion, property changes).
    // A GUI app gets this from its always-spinning main run loop; our CLI /
    // daemon doesn't, so AudioDeviceStart's async completion never lands and
    // the device stays isRunning=0. We point kAudioHardwarePropertyRunLoop at
    // THIS loop (NULL — "HAL, use your own thread" — was observed to be a
    // no-op on macOS 26, likely because AVFoundation already bound the HAL to
    // the main run loop during the permission check).
    private var halRunLoopThread: Thread?
    private var halRunLoop: CFRunLoop?

    /// Box to ferry the CFRunLoop out of the notification thread without a
    /// weak-self write race.
    private final class LoopBox: @unchecked Sendable { var loop: CFRunLoop? }

    public init() {}

    // Diagnostic logging, gated by env `HARK_TAP_DEBUG=1`. SAME env var name and
    // `hark-tap:` prefix as the ScreenCaptureKit backend, so the existing test
    // recipe is unchanged: look for `hark-tap: ioproc call #1 frames=…`.
    private static let tapDebug = ProcessInfo.processInfo.environment["HARK_TAP_DEBUG"] != nil
    private static func dbg(_ s: String) {
        if tapDebug { FileHandle.standardError.write(Data("hark-tap: \(s)\n".utf8)) }
    }

    /// Counts IOProc invocations so debug logging can prove the audio thread
    /// actually fires (the crux of the old 0-frames symptom). Mutated only on
    /// the realtime thread; `@unchecked Sendable` because we promise that.
    private final class CallCounter: @unchecked Sendable { var n = 0 }
    private let dbgCounter = CallCounter()

    /// Native format the tap delivers. Before `start()`, returns a sensible
    /// 48 kHz stereo Float32 default — the typical default-output shape.
    /// After `start()`, reflects what Core Audio actually negotiated.
    public var sourceFormat: AVAudioFormat {
        if let fmt = runningFormat { return fmt }
        return Self.defaultFormat
    }

    private static let defaultFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
    )!

    public func start(onBuffer: @escaping BufferHandler) throws {
        guard tapID == kAudioObjectUnknown else {
            throw Self.error(-1, "CoreAudioProcessTap.start called while already running")
        }

        // 0a. CRITICAL for a CLI/daemon: AudioDeviceStart() is ASYNCHRONOUS —
        //     coreaudiod messages back to actually spin up the IO cycle, and the
        //     HAL delivers those notifications on a CFRunLoop. A SwiftUI app
        //     (AudioCap) has its always-spinning main run loop; our `@main async`
        //     CLI parks in dispatch_main() — the main DISPATCH QUEUE drains
        //     (timers fire) but NO CFRunLoop runs, so the start completion is
        //     never serviced: the device stays isRunning=0 and the IOProc never
        //     fires (every call still returns noErr — confirmed by diagnostics).
        //     We give the HAL a real, running CFRunLoop on a dedicated thread.
        bindHALNotificationsToDedicatedRunLoop()

        // 0. PRIVATE-SPI permission request (opt-in via HARK_ENABLE_TCC_SPI).
        //    We block on the async request at this one boundary, exactly like
        //    the SCK backend bridges its async setup with a semaphore. We then
        //    proceed to create the tap REGARDLESS of the result, so we can
        //    observe behavior whether granted, denied, or the SPI no-ops.
        if ProcessInfo.processInfo.environment["HARK_ENABLE_TCC_SPI"] == "1" {
            Self.dbg("TCC audio-capture preflight (before request): \(PermissionGate.audioCaptureStatusViaSPI())")
            let granted = Self.awaitBool { await PermissionGate.requestAudioCaptureViaSPI() }
            Self.dbg("TCC audio-capture request via SPI returned granted=\(granted)")
            Self.dbg("TCC audio-capture preflight (after request): \(PermissionGate.audioCaptureStatusViaSPI())")
        } else {
            Self.dbg("HARK_ENABLE_TCC_SPI not set; skipping TCC audio-capture request (tap will likely get no audio if unauthorized)")
        }

        // 1. Build the tap description. GLOBAL tap excluding NO processes =
        //    "the whole system mix". muteBehavior .unmuted observes the live mix
        //    without silencing the user's speakers. We own the uuid and set ONLY
        //    muteBehavior — deliberately NOT isPrivate/isExclusive: on a global
        //    tap those flags let the tap bind but stop the aggregate device from
        //    ever starting (ADR-0011). Matches the working AudioCap reference.
        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDesc.uuid = UUID()
        tapDesc.muteBehavior = .unmuted
        Self.dbg("created CATapDescription (global, exclude none, unmuted) uuid=\(tapDesc.uuid.uuidString)")

        // 2. Create the tap. AudioObjectID out-param; non-zero status throws.
        var createdTapID: AudioObjectID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(tapDesc, &createdTapID)
        Self.dbg("AudioHardwareCreateProcessTap status=\(tapStatus) tapID=\(createdTapID)")
        guard tapStatus == noErr, createdTapID != kAudioObjectUnknown else {
            throw Self.error(tapStatus, "AudioHardwareCreateProcessTap failed")
        }
        self.tapID = createdTapID

        // Pull the tap's UID — the aggregate references it by UID string.
        let tapUID: String
        do {
            tapUID = try Self.stringProperty(createdTapID, selector: kAudioTapPropertyUID)
        } catch {
            cleanupAfterFailure()
            throw error
        }
        Self.dbg("tap UID = \(tapUID)")

        // 3. Build the PRIVATE aggregate device wrapping the tap — EXACTLY as
        //    Apple's AudioCap reference does. The default output device is
        //    included BOTH as the main sub-device (clock master) AND in the
        //    sub-device list. That hardware sub-device is what drives the
        //    aggregate's IO cycle; the tap rides alongside it as the audio
        //    source. (A tap-only aggregate with no sub-device never spins its
        //    IO cycle, so the IOProc never fires — that was the bug. The
        //    earlier output-clocked attempts only "failed" because the audio
        //    permission wasn't granted yet, so no test was valid until now.)
        let outputDevice = try Self.defaultOutputDevice()
        let outputUID = try Self.deviceUID(outputDevice)
        Self.dbg("aggregate clock/sub-device = default output UID \(outputUID)")
        let aggregateUID = "hark.systemtap.\(UUID().uuidString)"
        // NOTE: boolean-valued keys MUST be real Bools (→ CFBoolean), NOT Int
        // 1/0 (→ CFNumber). Core Audio reads these with CFBooleanGetValue();
        // a CFNumber there reads as false. Passing Int 1 for TapAutoStart was
        // why the aggregate never auto-started its tap and the IOProc never
        // fired — every call still returned noErr. AudioCap uses true/false.
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Hark System Tap",
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [
                    kAudioSubDeviceUIDKey as String: outputUID
                ]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    // Reference the DESCRIPTION's uuid string, exactly as AudioCap
                    // does — not the value read back from kAudioTapPropertyUID.
                    kAudioSubTapUIDKey as String: tapDesc.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey as String: true
                ]
            ]
        ]

        var createdAggID: AudioObjectID = kAudioObjectUnknown
        let aggStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &createdAggID
        )
        Self.dbg("AudioHardwareCreateAggregateDevice status=\(aggStatus) aggID=\(createdAggID)")
        guard aggStatus == noErr, createdAggID != kAudioObjectUnknown else {
            cleanupAfterFailure()
            throw Self.error(aggStatus, "AudioHardwareCreateAggregateDevice failed")
        }
        self.aggregateID = createdAggID

        // 4. Determine the delivered format. AUTHORITATIVE source is the tap's
        //    own kAudioTapPropertyFormat; fall back to the aggregate's
        //    input-scope stream format if that read fails for any reason.
        let avFormat: AVAudioFormat
        if let tapFormat = try? Self.tapStreamFormat(createdTapID) {
            avFormat = tapFormat
            Self.dbg("format from tap (kAudioTapPropertyFormat): \(tapFormat.sampleRate)Hz ch=\(tapFormat.channelCount) interleaved=\(tapFormat.isInterleaved)")
        } else {
            let asbd: AudioStreamBasicDescription
            do {
                asbd = try Self.streamFormat(createdAggID, scope: kAudioDevicePropertyScopeInput)
            } catch {
                cleanupAfterFailure()
                throw error
            }
            var mutableASBD = asbd
            guard let fallback = AVAudioFormat(streamDescription: &mutableASBD) else {
                cleanupAfterFailure()
                throw Self.error(-1, "Could not build AVAudioFormat from aggregate input ASBD")
            }
            avFormat = fallback
            Self.dbg("format from aggregate input scope (fallback): \(fallback.sampleRate)Hz ch=\(fallback.channelCount) interleaved=\(fallback.isInterleaved)")
        }
        self.runningFormat = avFormat
        self.handler = onBuffer

        // 5. Install the IOProc. The block captures only the format reference
        //    and handler by value (both already retained by `self`). No
        //    `[weak self]`: weak-resolve on the audio thread is a runtime
        //    ref-count op, and stop() destroys the proc before we drop these.
        let capturedFormat = avFormat
        let capturedHandler = onBuffer
        let counter = dbgCounter
        let debug = Self.tapDebug

        // Dedicated serial queue for the IOProc block. MUST be non-nil for the
        // block variant — see the ioQueue property note. Core Audio drives it
        // at realtime priority; the block still runs effectively on the audio
        // thread, so the no-copy buffer wrap below stays valid.
        let queue = DispatchQueue(label: "hark.systemtap.io")
        self.ioQueue = queue

        var newProcID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(
            &newProcID,
            createdAggID,
            queue
        ) { _, inputDataPtr, inputTimePtr, _, _ in
            // Diagnostic: prove the IOProc fires and how many frames arrive.
            // First five only — SAME line format as the SCK backend, so the
            // test recipe is unchanged.
            if debug {
                counter.n += 1
                if counter.n <= 5 {
                    let frames = inputDataPtr.pointee.mBuffers.mDataByteSize
                        / max(1, capturedFormat.streamDescription.pointee.mBytesPerFrame)
                    FileHandle.standardError.write(Data("hark-tap: ioproc call #\(counter.n) frames=\(frames)\n".utf8))
                }
            }

            // Wrap the incoming AudioBufferList without copying. Core Audio owns
            // the memory for the duration of this call; the BufferHandler must
            // consume it synchronously (the contract MicCapture also relies on).
            guard let pcm = AVAudioPCMBuffer(
                pcmFormat: capturedFormat,
                bufferListNoCopy: inputDataPtr,
                deallocator: nil
            ) else {
                return
            }

            var ts = inputTimePtr.pointee
            let avTime = AVAudioTime(audioTimeStamp: &ts, sampleRate: capturedFormat.sampleRate)
            capturedHandler(pcm, avTime)
        }

        Self.dbg("AudioDeviceCreateIOProcIDWithBlock status=\(procStatus)")
        guard procStatus == noErr, let procID = newProcID else {
            cleanupAfterFailure()
            throw Self.error(procStatus, "AudioDeviceCreateIOProcIDWithBlock failed")
        }
        self.ioProcID = procID

        let startStatus = AudioDeviceStart(createdAggID, procID)
        Self.dbg("AudioDeviceStart status=\(startStatus)")
        guard startStatus == noErr else {
            cleanupAfterFailure()
            throw Self.error(startStatus, "AudioDeviceStart failed")
        }
        Self.dbg("started; waiting for IOProc callbacks…")
        // Read back what Core Audio ACTUALLY built/started. This discriminates
        // the failure: isRunning=0 → clock/composition never started;
        // inputStreams=0 → tap isn't feeding the aggregate; activeSubDevices=0
        // → the output sub-device didn't attach. If all look healthy but the
        // IOProc is still silent, the problem is callback delivery, not setup.
        Self.dbgAggregateState(createdAggID)
    }

    public func stop() {
        // Diagnostic: read the aggregate state again AFTER the full capture
        // window. If isRunning is still 0 here, the device never started its IO
        // cycle (a start/composition problem). If it's 1 but no callbacks
        // arrived, the IOProc delivery is what's broken.
        if aggregateID != kAudioObjectUnknown {
            Self.dbg("aggregate state at stop:")
            Self.dbgAggregateState(aggregateID)
        }

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
        ioQueue = nil

        // Stop the HAL notification loop LAST — after the device/aggregate/tap
        // teardown above, so those async teardown notifications are serviced.
        teardownHALRunLoop()
    }

    // MARK: - Cleanup on partial-init failure

    /// Tear down whatever was allocated before an error. Idempotent across the
    /// possible partial states (tap only, tap+agg, tap+agg+proc).
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
        ioQueue = nil

        // Stop the HAL notification loop LAST — after the device/aggregate/tap
        // teardown above, so those async teardown notifications are serviced.
        teardownHALRunLoop()
    }

    // MARK: - async → sync bridge (start() boundary only)

    /// Run an async closure to completion and return its Bool, blocking the
    /// calling (start) thread. Used ONCE, for the TCC request, never on the
    /// audio hot path. Java analogue: CompletableFuture.get() at startup.
    private static func awaitBool(_ body: @escaping () async -> Bool) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        var result = false
        Task {
            result = await body()
            sem.signal()
        }
        sem.wait()
        return result
    }

    // MARK: - Core Audio HAL helpers (reused from the original Process Tap impl)

    /// Spin up a dedicated thread that runs a real CFRunLoop, then point
    /// kAudioHardwarePropertyRunLoop at it so the HAL services its async
    /// notifications (the AudioDeviceStart completion in particular) on a loop
    /// that is actually running. Idempotent; torn down in stop().
    private func bindHALNotificationsToDedicatedRunLoop() {
        guard halRunLoop == nil else { return }

        let box = LoopBox()
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            let loop = CFRunLoopGetCurrent()
            // A no-op (version-0) source keeps CFRunLoopRun() from returning
            // immediately for lack of any input source.
            var ctx = CFRunLoopSourceContext()
            if let keepAlive = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &ctx) {
                CFRunLoopAddSource(loop, keepAlive, .commonModes)
            }
            box.loop = loop
            ready.signal()
            CFRunLoopRun()  // blocks until CFRunLoopStop in stop()
        }
        thread.name = "hark.hal.notify"
        thread.start()
        ready.wait()

        self.halRunLoopThread = thread
        self.halRunLoop = box.loop

        guard let loop = box.loop else {
            Self.dbg("WARNING: dedicated HAL run loop not captured")
            return
        }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyRunLoop,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var loopRef: CFRunLoop? = loop
        let status = withUnsafeMutablePointer(to: &loopRef) { ptr in
            AudioObjectSetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &addr,
                0, nil,
                UInt32(MemoryLayout<CFRunLoop?>.size),
                ptr
            )
        }
        Self.dbg("bound HAL notifications to dedicated running CFRunLoop, status=\(status)")
    }

    /// Stop the dedicated HAL notification run loop and let its thread exit.
    /// Called LAST in teardown, after the device/aggregate/tap are destroyed,
    /// so those teardown notifications are still serviced.
    private func teardownHALRunLoop() {
        if let loop = halRunLoop {
            CFRunLoopStop(loop)
        }
        halRunLoopThread = nil
        halRunLoop = nil
    }

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

    /// Read the tap's authoritative output format. macOS exposes the tap's
    /// stream shape as an AudioStreamBasicDescription under
    /// kAudioTapPropertyFormat on the tap object itself.
    private static func tapStreamFormat(_ tapID: AudioObjectID) throws -> AVAudioFormat {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard status == noErr else {
            throw error(status, "Could not read kAudioTapPropertyFormat")
        }
        guard let fmt = AVAudioFormat(streamDescription: &asbd) else {
            throw error(-1, "Could not build AVAudioFormat from tap ASBD")
        }
        return fmt
    }

    /// Read the AudioStreamBasicDescription for a device on the given scope.
    /// The aggregate's tap audio surfaces on the input scope; this is the
    /// fallback when the tap's own format read fails.
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

    /// Diagnostic dump of the aggregate's real composition + run state, to
    /// tell whether AudioDeviceStart==noErr actually produced a running device
    /// with a clock and input streams. Gated by HARK_TAP_DEBUG.
    private static func dbgAggregateState(_ aggID: AudioObjectID) {
        guard tapDebug else { return }

        func u32(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> String {
            var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var v: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let s = AudioObjectGetPropertyData(aggID, &addr, 0, nil, &size, &v)
            return s == noErr ? "\(v)" : "err(\(s))"
        }
        func count(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, stride: Int) -> String {
            var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            let s = AudioObjectGetPropertyDataSize(aggID, &addr, 0, nil, &size)
            return s == noErr ? "\(Int(size) / max(1, stride))" : "err(\(s))"
        }

        dbg("aggregate state: isAlive=\(u32(kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal)) "
            + "isRunning=\(u32(kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal)) "
            + "inputStreams=\(count(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeInput, stride: MemoryLayout<AudioStreamID>.size)) "
            + "activeSubDevices=\(count(kAudioAggregateDevicePropertyActiveSubDeviceList, kAudioObjectPropertyScopeGlobal, stride: MemoryLayout<AudioObjectID>.size))")
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
