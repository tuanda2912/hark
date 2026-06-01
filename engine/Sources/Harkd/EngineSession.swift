// EngineSession — wires Capture → VAD → SlidingWindow → WhisperKit → WS emit.
//
// This is harkd's brain. Java analogue: a `@Service` Spring bean that
// holds the entire transcription session lifecycle. We model it as a
// Swift `actor` so all state mutations serialize on the actor's executor
// without explicit locks.
//
// State machine (simplified):
//
//     [idle] ──capture.start──► [running] ──capture.stop──► [idle]
//                                  │
//                          (pause/resume orthogonal)
//
// Hot path:
//
//   CapturePipeline pump (DispatchQueue) ──floatFrameSink──►
//     Task { await session.ingest(...) } ──►
//       VAD classify ──► append to SlidingWindow ──► popHopIfReady ──►
//         enqueue transcription job ──► (Transcriber actor) ──►
//           reconcile against UtteranceLedger ──► emit WS frames
//
// Backpressure (ADR-0008 §3, hard rule):
//   If a transcription job is already in flight when a new hop is ready,
//   we DROP the in-flight job's pending replacement — meaning we never
//   queue more than one outstanding window. The freshest hop wins; the
//   older window is discarded and we emit `warning code:"rtf_high"`.
//   Never queue unbounded.
//
// Privacy: this actor sees transcript text. It MUST NOT log text content.
// All log lines are progress / state transitions only.

import Foundation
import WhisperKit
import HarkCore
import HarkCapture
import FluidAudio

@available(macOS 14.4, *)
actor EngineSession {
    // ─── Dependencies wired at startup ─────────────────────────────────
    // Set once the model finishes loading (attachModel). Implicitly unwrapped:
    // it's never touched until capture.start, which is gated on model
    // readiness. harkd brings up the WS server + port file BEFORE loading the
    // model so the port is discoverable immediately; the model loads behind it.
    private var whisperKit: WhisperKit!
    private var modelName: String = ""
    private var modelReady: Bool { whisperKit != nil }
    private weak var server: HarkdWebSocketServer?

    /// Offline speaker diarizer (Phase 5, ADR-0016). nil until the models
    /// finish loading; nil-tolerant everywhere — a missing/failed diarizer
    /// NEVER blocks capture or stop. Used only by the post-stop pass.
    private var diarizer: Diarizer?

    // ─── Session-scoped state (reset per capture.start) ────────────────
    private var sessionId: String?
    private var sessionStartDate: Date?
    private var pipeline: CapturePipeline?
    private var window: SlidingWindowBuffer?
    private var ledger: UtteranceLedger?
    private var vad: EnergyVAD = EnergyVAD()

    /// Speech samples ingested across all hops — used as the wall-clock
    /// session-time anchor for fresh frames. Increments on every speech
    /// classification regardless of window trims.
    private var sessionTimeSeconds: Double = 0
    /// Wall-clock seconds since capture start (advances during silence too).
    /// Used for the session-time anchor passed to the SlidingWindow.
    private var captureWallStart: Date?
    /// Optional language lock for the session (ISO-639-1: "vi", "en"…).
    /// `nil` means auto-detect per transcribe call. Passed to WhisperKit's
    /// `DecodingOptions.language` at every hop + the flushOnStop drain.
    private var sessionLanguage: String?

    // ─── Offline diarization buffers (Phase 5, ADR-0016) ───────────────
    //
    // Full-meeting 16 kHz mono audio retained in RAM for the post-stop
    // diarization pass. Unlike `SlidingWindowBuffer` (speech-only, trimmed
    // to 30 s) this is the CONTINUOUS recording — every mixed frame batch,
    // including silence — so its sample-index timeline maps 1:1 to the
    // wall-clock session time the segments are emitted against. That shared
    // time axis is what makes the time-overlap speaker assignment correct.
    //
    // Memory bound (ADR-0016 §5): Float @ 16 kHz = 64 KB/s ≈ 3.84 MB/min;
    // a 60-min meeting ≈ 230 MB. Acceptable for v1; spill-to-temp-WAV is the
    // escape hatch if long meetings pressure memory. Cleared at capture.start
    // and after the diarization pass at stop.
    private var sessionAudio: [Float] = []

    /// Finalized utterances accumulated during the session, kept so the
    /// post-stop diarization pass can label them by time-overlap. We retain
    /// only timing + uid (NOT text) — diarization needs intervals, not words.
    private struct FinalizedUtterance {
        let utteranceId: String
        let tStart: Double
        let tEnd: Double
    }
    private var finalizedUtterances: [FinalizedUtterance] = []

    // ─── Connected clients ──────────────────────────────────────────────
    private var clients: [String: WebSocketClient] = [:]

    // ─── Transcription pacing / backpressure ────────────────────────────
    private var transcribeInFlight = false
    /// True only during the async capture.start setup (the mic-permission
    /// await), to block a second concurrent capture.start during actor
    /// reentrancy before `pipeline` is assigned.
    private var startingCapture = false
    private var lastTranscribeRTF: Double = 0
    private var pendingDroppedHops: Int = 0

    // ─── Heartbeat ──────────────────────────────────────────────────────
    private var heartbeatTask: Task<Void, Never>?

    init(server: HarkdWebSocketServer) {
        self.server = server
    }

    /// Inject the model once it has finished loading. Until this runs,
    /// capture.start is rejected with a recoverable ENGINE_WARMING_UP, so the
    /// WS server + port file can come up before the (slow) model load.
    func attachModel(_ pipe: WhisperKit, name: String) {
        self.whisperKit = pipe
        self.modelName = name
        // Push readiness to any clients already connected behind the warmup
        // gate, so the UI clears "warming up" without polling capture.start.
        broadcast(WireEnvelope(type: "meta.ready", payload: MetaReadyPayload(modelLoaded: name)))
    }

    /// Inject the offline diarizer once its models finish loading (Phase 5).
    /// Optional capability: capture works whether or not this ever runs. No
    /// wire frame in Slice 1 — readiness is logged in HarkdCommand.
    func attachDiarizer(_ diarizer: Diarizer) {
        self.diarizer = diarizer
    }

    // ─── Client connection lifecycle (called by WS delegate) ────────────

    func handleConnect(_ client: WebSocketClient) {
        clients[client.id] = client
        // meta.hello — the very first frame every client should receive.
        let hello = WireEnvelope(type: "meta.hello", payload: MetaHelloPayload(
            engineVersion: HARKD_ENGINE_VERSION,
            protocolVersion: WIRE_PROTOCOL_VERSION,
            modelLoaded: modelReady ? modelName : "(loading)",
            // Phase 3 doesn't actually ship translation or diarization yet,
            // but the capabilities list is the contract's forward-compat
            // signal. List only what's truly available — keep this honest.
            capabilities: []
        ))
        sendOnly(client, envelope: hello)
        startHeartbeatIfNeeded()
    }

    func handleDisconnect(_ client: WebSocketClient) {
        clients.removeValue(forKey: client.id)
        // If the UI dropped, don't tear down capture automatically — Phase 4
        // may want to reconnect mid-session. Capture only stops on explicit
        // `capture.stop` or SIGINT/SIGTERM (handled in main.swift).
    }

    /// Inbound text frame entry point. Parses + dispatches.
    func handleInbound(_ client: WebSocketClient, text: String) async {
        guard let data = text.data(using: .utf8) else { return }
        let header: InboundEnvelopeHeader
        do {
            header = try decodeHeader(data)
        } catch {
            sendError(client, id: nil, code: "PROTOCOL_MISMATCH",
                      message: "could not parse envelope", recoverable: false)
            return
        }
        if let v = header.v, v != WIRE_PROTOCOL_VERSION {
            sendError(client, id: header.id, code: "PROTOCOL_MISMATCH",
                      message: "engine speaks v\(WIRE_PROTOCOL_VERSION); client sent v\(v)",
                      recoverable: false)
            return
        }

        switch header.type {
        case "capture.start":
            await dispatchCaptureStart(client, id: header.id, data: data)
        case "capture.stop":
            dispatchCaptureStop(client, id: header.id)
        case "capture.pause":
            dispatchCapturePause(client, id: header.id)
        case "capture.resume":
            dispatchCaptureResume(client, id: header.id)
        case "bookmark.create":
            dispatchBookmarkCreate(client, id: header.id, data: data)
        case "meta.heartbeat":
            // Client heartbeat — ignored beyond noting liveness. NIO's
            // protocol ping/pong is the actual liveness signal.
            break
        default:
            sendError(client, id: header.id, code: "UNSUPPORTED_TYPE",
                      message: "unknown message type: \(header.type)", recoverable: true)
        }
    }

    // ─── Command handlers ───────────────────────────────────────────────

    private func dispatchCaptureStart(_ client: WebSocketClient, id: String?, data: Data) async {
        guard pipeline == nil, !startingCapture else {
            sendError(client, id: id, code: "ALREADY_RUNNING",
                      message: "capture already in progress", recoverable: true)
            return
        }
        // The model loads BEHIND the WS server (so the port file is available
        // immediately on launch). Reject capture until it's ready — recoverable,
        // so the client just retries in a moment.
        guard modelReady else {
            sendError(client, id: id, code: "ENGINE_WARMING_UP",
                      message: "model still loading; retry in a moment", recoverable: true)
            return
        }
        let cmd: CaptureStartCommand
        do {
            cmd = try decodeInbound(data, payloadType: CaptureStartCommand.self)
        } catch {
            sendError(client, id: id, code: "PROTOCOL_MISMATCH",
                      message: "bad capture.start payload", recoverable: true)
            return
        }
        // Translation is Phase 6 — accept the field, log it as pending.
        if let t = cmd.translation, t.enabled == true {
            FileHandle.standardError.write(Data(
                "harkd: translation_pending (mode=\(t.mode ?? "?") target=\(t.targetLang ?? "?"))\n".utf8))
        }

        let captureMic = cmd.sources?.mic ?? true
        let captureSystem = cmd.sources?.system ?? true
        // Normalize "auto" / empty to nil so callers can pass either form.
        let language: String? = {
            guard let raw = cmd.language?.trimmingCharacters(in: .whitespaces).lowercased(),
                  !raw.isEmpty, raw != "auto" else { return nil }
            return raw
        }()

        startingCapture = true
        defer { startingCapture = false }

        // Acquire mic permission lazily — only when the mic source is on. It
        // grants live (no relaunch), so capture proceeds in the same process.
        // (System-audio permission is handled by the tap backend at start().)
        if captureMic {
            let granted = await PermissionGate.requestMicrophone()
            if !granted {
                sendError(client, id: id, code: "MIC_DENIED",
                          message: "microphone permission denied — enable it in System Settings → Privacy & Security → Microphone",
                          recoverable: true)
                return
            }
        }

        do {
            try startCapture(captureMic: captureMic,
                             captureSystem: captureSystem,
                             language: language)
        } catch {
            sendError(client, id: id, code: "INTERNAL",
                      message: "could not start capture: \(error)", recoverable: false)
            return
        }
        if let lang = language {
            FileHandle.standardError.write(Data("harkd: session language locked to \(lang)\n".utf8))
        }
        sendAck(client, id: id)
        let started = CaptureStartedPayload(
            sessionId: sessionId!,
            sampleRateHz: 16_000,
            channels: 1,
            model: modelName,
            vad: "energy-v0",
            startedAt: wireTimestamp(sessionStartDate!)
        )
        broadcast(WireEnvelope(type: "capture.started", payload: started))
    }

    private func dispatchCaptureStop(_ client: WebSocketClient, id: String?) {
        guard let pipeline = pipeline else {
            sendError(client, id: id, code: "NOT_RUNNING",
                      message: "no capture in progress", recoverable: true)
            return
        }
        let sid = sessionId ?? "unknown"
        let durationSec: Double = sessionStartDate.map { Date().timeIntervalSince($0) } ?? 0

        do {
            try pipeline.stop()
        } catch {
            FileHandle.standardError.write(Data("harkd: pipeline stop error: \(error)\n".utf8))
        }
        // Flush any remaining buffered speech as a final transcription pass.
        // Best-effort — we don't block the ack on it.
        let flushTask = Task { [weak self] in
            await self?.flushOnStop()
        }
        _ = flushTask

        sendAck(client, id: id)
        broadcast(WireEnvelope(type: "capture.stopped", payload: CaptureStoppedPayload(
            sessionId: sid, durationSec: durationSec
        )))

        // Clear session state.
        self.pipeline = nil
        self.window = nil
        self.ledger = nil
        self.sessionId = nil
        self.sessionStartDate = nil
        self.captureWallStart = nil
        self.sessionTimeSeconds = 0
        self.sessionLanguage = nil
        self.vad = EnergyVAD()
    }

    private func dispatchCapturePause(_ client: WebSocketClient, id: String?) {
        // Pause is a no-op stub for Phase 3 — capture pipeline doesn't yet
        // support pause/resume. We ack and emit the lifecycle event so the
        // UI's state machine stays consistent.
        sendAck(client, id: id)
        broadcast(WireEnvelope(type: "capture.paused", payload: EmptyPayload()))
    }

    private func dispatchCaptureResume(_ client: WebSocketClient, id: String?) {
        sendAck(client, id: id)
        broadcast(WireEnvelope(type: "capture.resumed", payload: EmptyPayload()))
    }

    private func dispatchBookmarkCreate(_ client: WebSocketClient, id: String?, data: Data) {
        let cmd: BookmarkCreateCommand
        do {
            cmd = try decodeInbound(data, payloadType: BookmarkCreateCommand.self)
        } catch {
            sendError(client, id: id, code: "PROTOCOL_MISMATCH",
                      message: "bad bookmark.create payload", recoverable: true)
            return
        }
        let label = cmd.label ?? "plain"
        sendAck(client, id: id)
        broadcast(WireEnvelope(type: "bookmark.created", payload: BookmarkCreatedPayload(
            bookmarkId: UUID().uuidString,
            t: cmd.t,
            label: label
        )))
        // Persisting to the vault is Phase 5/6 — for now bookmarks are
        // event-only and the UI is expected to mirror them locally.
    }

    // ─── Capture wiring ─────────────────────────────────────────────────

    private func startCapture(captureMic: Bool,
                              captureSystem: Bool,
                              language: String?) throws {
        self.sessionId = UUID().uuidString
        self.sessionStartDate = Date()
        self.captureWallStart = Date()
        self.sessionTimeSeconds = 0
        self.window = SlidingWindowBuffer(windowSeconds: 30, hopSeconds: 5, sampleRate: 16_000)
        self.ledger = UtteranceLedger()
        self.vad = EnergyVAD()
        self.sessionLanguage = language

        // Reset the offline-diarization buffers for the new session and
        // pre-reserve ~10 min of audio so early growth doesn't reallocate.
        // (10 min × 60 s × 16 kHz = 9.6M floats ≈ 38 MB.) Longer meetings
        // grow past this via amortized doubling — still off the audio thread.
        self.sessionAudio.removeAll(keepingCapacity: true)
        if diarizer != nil {
            self.sessionAudio.reserveCapacity(16_000 * 60 * 10)
        }
        self.finalizedUtterances.removeAll(keepingCapacity: true)

        // CapturePipeline runs its pump on a background DispatchQueue. The
        // floatFrameSink fires there. We bounce into the actor via a Task
        // — capturing self weakly because the pump may outlive a stop().
        let opts = CapturePipeline.Options(
            captureMic: captureMic,
            captureSystem: captureSystem,
            outputURL: nil,  // streaming-only; no WAV
            floatFrameSink: { [weak self] frames in
                guard let self = self else { return }
                Task { await self.ingestFrames(frames) }
            }
        )
        let pipe = try CapturePipeline(options: opts)
        try pipe.start()
        self.pipeline = pipe
    }

    // ─── Ingest path (called from pump → Task → actor) ──────────────────

    private func ingestFrames(_ frames: [Float]) {
        guard let window = window else { return }

        // Retain the CONTINUOUS recording for the offline diarization pass
        // (Phase 5). This runs on the actor's executor — NOT the audio pump
        // thread (the pump bounces here via `Task { await ingestFrames }`), so
        // a plain `append(contentsOf:)` is safe: it never blocks the audio
        // callback, and array growth is amortized O(1). We only buffer while
        // the diarizer exists (else it'd be wasted RAM) and only the raw mixed
        // frames — pre-VAD — so the sample timeline stays continuous and maps
        // 1:1 to wall-clock session time. See the `sessionAudio` declaration
        // for the memory bound.
        if diarizer != nil {
            sessionAudio.append(contentsOf: frames)
        }

        // Wall-clock session time for these frames. We use real elapsed
        // time rather than sample-count arithmetic so that silence gaps
        // (which the VAD drops) still advance the timeline.
        let now = captureWallStart.map { Date().timeIntervalSince($0) } ?? sessionTimeSeconds

        let verdict = vad.classify(frames)
        switch verdict {
        case .silence:
            // Drop. Session clock advances via `now`; nothing buffered.
            return
        case .speech:
            window.append(frames, sessionTime: now)
            sessionTimeSeconds = now
        }

        // Check for hop trigger and kick a transcription if not in flight.
        guard let hop = window.popHopIfReady() else { return }

        if transcribeInFlight {
            // Backpressure: drop this hop rather than queue. ADR-0008 §3.
            pendingDroppedHops += 1
            broadcast(WireEnvelope(type: "warning", payload: WarningPayload(
                code: "rtf_high",
                message: "transcription falling behind; dropped 1 window (RTF=\(String(format: "%.2f", lastTranscribeRTF)))",
                severity: "medium"
            )))
            return
        }

        transcribeInFlight = true
        let snapshot = hop
        Task { [weak self] in
            await self?.runTranscription(samples: snapshot.samples,
                                         windowStartSessionTime: snapshot.windowStartSessionTime)
        }
    }

    // ─── Transcription path ─────────────────────────────────────────────

    private func runTranscription(samples: [Float], windowStartSessionTime: Double) async {
        let started = Date()
        let audioSeconds = Double(samples.count) / 16_000.0
        let results: [TranscriptionResult]
        do {
            let opts = DecodingOptions(
                verbose: false,
                task: .transcribe,
                language: self.sessionLanguage,  // nil = auto; "vi"/"en"/… = locked
                withoutTimestamps: false
            )
            results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: opts)
        } catch {
            FileHandle.standardError.write(Data("harkd: transcribe error: \(type(of: error))\n".utf8))
            self.transcribeInFlight = false
            return
        }
        let elapsed = Date().timeIntervalSince(started)
        let rtf = audioSeconds > 0 ? elapsed / audioSeconds : 0
        self.lastTranscribeRTF = rtf

        // Map WhisperKit segments → reconciled emissions.
        let language = results.first?.language
        var winSegments: [WindowSegment] = []
        for r in results {
            for s in r.segments {
                let cleaned = stripWhisperSpecials(s.text).trimmingCharacters(in: .whitespaces)
                if cleaned.isEmpty { continue }
                // s.start / s.end are window-relative (seconds since the
                // start of the 30 s window). Map back to absolute session
                // time via the SlidingWindow's anchor table.
                guard let window = self.window else { continue }
                let tStartAbs = window.windowTimeToSessionTime(
                    windowOffsetSeconds: Double(s.start),
                    windowStartSessionTime: windowStartSessionTime
                )
                let tEndAbs = window.windowTimeToSessionTime(
                    windowOffsetSeconds: Double(s.end),
                    windowStartSessionTime: windowStartSessionTime
                )
                winSegments.append(WindowSegment(
                    tStart: tStartAbs, tEnd: tEndAbs, text: cleaned, language: language
                ))
            }
        }

        // Reconciliation:
        //   - segments whose t_start falls in the OLDER 25 s of the window
        //     are candidates for promotion to final (same text twice).
        //   - segments in the NEW 5 s tail are partials.
        let hopSeconds = 5.0
        let oldestOldEnd = windowStartSessionTime + (30.0 - hopSeconds)

        guard let ledger = self.ledger else {
            self.transcribeInFlight = false
            return
        }

        for seg in winSegments {
            // Resolve utterance identity by overlap, not by t_start bucket.
            // See SlidingWindow.swift comments for rationale.
            let uid = ledger.resolve(tStart: seg.tStart, tEnd: seg.tEnd, text: seg.text)
            if ledger.isFinalized(utteranceId: uid) {
                continue
            }
            let textChanged = ledger.updateText(seg.text, utteranceId: uid)
            let isInOlderZone = seg.tStart < oldestOldEnd
            // Final: a segment in the older zone that didn't change is
            // confirmed by this window; emit `segment.final` and lock it.
            if isInOlderZone && !textChanged {
                ledger.markFinalized(utteranceId: uid)
                emitSegment(uid: uid, isFinal: true, seg: seg)
            } else {
                // Partial: either fresh (tail) or refined (text changed).
                emitSegment(uid: uid, isFinal: false, seg: seg)
            }
        }

        // Drop entries that have fallen out of the active window. Anything
        // whose tEnd is below the current window's left edge can never be
        // matched by a future segment, so it'd just slow `resolve` over a
        // long session. For non-finalized orphans, emit a `segment.final`
        // with their last known state so the UI gets closure on dangling
        // partials. See ADR-0009.
        let pruned = ledger.prune(beforeSessionTime: windowStartSessionTime)
        for p in pruned where !p.wasFinalized {
            let orphanSeg = WindowSegment(
                tStart: p.tStart, tEnd: p.tEnd, text: p.lastText, language: nil
            )
            emitSegment(uid: p.id, isFinal: true, seg: orphanSeg)
        }

        self.transcribeInFlight = false
    }

    /// Drain whatever's left after capture.stop. Transcribes the buffered
    /// window once (if any speech is present) and emits remaining partials
    /// as finals so the UI doesn't leave dangling partials.
    private func flushOnStop() async {
        // Snapshot + detach the full-session audio BEFORE the transcription
        // drain's `await` (which suspends this actor and could let a fresh
        // capture.start wipe the live buffer). The drain itself only appends
        // to `finalizedUtterances`, not to `sessionAudio`, so taking the audio
        // here is safe; we grab the finalized list after the drain.
        let capturedAudio = sessionAudio
        sessionAudio.removeAll(keepingCapacity: false)

        // Drain the live transcription buffer first (this emits the last
        // finals, populating `finalizedUtterances`), then (Phase 5) run the
        // offline diarization pass over the captured audio and log the speaker
        // assignment. Guarded so it can never break the capture/stop lifecycle.
        await flushTranscriptionDrain()

        let capturedUtterances = finalizedUtterances
        finalizedUtterances.removeAll(keepingCapacity: false)
        await runDiarizationPass(audio: capturedAudio, utterances: capturedUtterances)
    }

    private func flushTranscriptionDrain() async {
        guard let window = window, let ledger = ledger else { return }
        if window.windowSamples.isEmpty { return }
        // One last pass — pretend the whole buffer is a hop.
        let samples = window.windowSamples
        let started = Date()
        let results: [TranscriptionResult]
        do {
            let opts = DecodingOptions(verbose: false, task: .transcribe,
                                       language: self.sessionLanguage,
                                       withoutTimestamps: false)
            results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: opts)
        } catch {
            FileHandle.standardError.write(Data("harkd: flush transcribe error: \(type(of: error))\n".utf8))
            return
        }
        _ = Date().timeIntervalSince(started)
        let language = results.first?.language
        for r in results {
            for s in r.segments {
                let cleaned = stripWhisperSpecials(s.text).trimmingCharacters(in: .whitespaces)
                if cleaned.isEmpty { continue }
                // Best-effort time mapping (anchors may have been trimmed).
                let tStart = Double(s.start)
                let tEnd = Double(s.end)
                let uid = ledger.resolve(tStart: tStart, tEnd: tEnd, text: cleaned)
                if ledger.isFinalized(utteranceId: uid) { continue }
                ledger.markFinalized(utteranceId: uid)
                emitSegment(uid: uid, isFinal: true, seg: WindowSegment(
                    tStart: tStart, tEnd: tEnd, text: cleaned, language: language
                ))
            }
        }
    }

    // ─── Offline diarization pass (Phase 5, ADR-0016) ───────────────────
    //
    // Slice 1: log-only. Runs after the transcription drain, over the full
    // session audio. Assigns each finalized utterance a "Speaker N" label by
    // max time-overlap against FluidAudio's diarization segments, and logs a
    // summary (always) + per-utterance lines (HARK_DIAR_DEBUG=1). No wire
    // frame, no vault write — those are Slice 2. Guarded end-to-end: any
    // failure logs and returns; capture/stop already completed by here.

    private func runDiarizationPass(audio samples: [Float],
                                    utterances: [FinalizedUtterance]) async {
        guard let diarizer = diarizer else { return }

        let audioSeconds = Double(samples.count) / 16_000.0
        if samples.isEmpty || audioSeconds < 1.0 {
            FileHandle.standardError.write(Data(
                "harkd: diarization skipped (only \(String(format: "%.2f", audioSeconds))s of audio)\n".utf8))
            return
        }

        let started = Date()
        let result: DiarizationResult
        do {
            result = try await diarizer.diarize(samples)
        } catch {
            FileHandle.standardError.write(Data(
                "harkd: diarization failed (\(error)); no speaker labels this session\n".utf8))
            return
        }
        let diarSeconds = Date().timeIntervalSince(started)
        let rtf = audioSeconds > 0 ? diarSeconds / audioSeconds : 0

        // Map FluidAudio speakerId strings → stable "Speaker N" ordinals in
        // first-seen order across the diarization segments.
        var ordinalForSpeakerId: [String: Int] = [:]
        var nextOrdinal = 1
        for seg in result.segments where !seg.speakerId.isEmpty {
            if ordinalForSpeakerId[seg.speakerId] == nil {
                ordinalForSpeakerId[seg.speakerId] = nextOrdinal
                nextOrdinal += 1
            }
        }
        let speakerCount = ordinalForSpeakerId.count

        // Always-on summary line.
        FileHandle.standardError.write(Data(String(
            format: "harkd: diarization done — speakers=%d  diar_segments=%d  utterances=%d  audio=%.1fs  diar_time=%.2fs  rtf=%.3f\n",
            speakerCount, result.segments.count, utterances.count,
            audioSeconds, diarSeconds, rtf
        ).utf8))

        // Per-utterance assignment by max temporal overlap. Verbose — gated
        // behind HARK_DIAR_DEBUG=1 so the default run stays quiet.
        let debug = ProcessInfo.processInfo.environment["HARK_DIAR_DEBUG"] == "1"
        guard debug else { return }

        for u in utterances {
            let label = speakerLabel(
                forUtteranceStart: u.tStart, end: u.tEnd,
                diarSegments: result.segments, ordinals: ordinalForSpeakerId)
            FileHandle.standardError.write(Data(String(
                format: "harkd: diar  %7.2f..%7.2f → %@\n",
                u.tStart, u.tEnd, label
            ).utf8))
        }
    }

    /// Pick the "Speaker N" label whose diarization segment has the greatest
    /// temporal overlap with the utterance interval [start, end]. Returns
    /// "Speaker ?" when no diarization segment overlaps (e.g. cross-talk
    /// dropped by the segmenter, or a sub-minSpeechDuration utterance).
    private func speakerLabel(
        forUtteranceStart start: Double, end: Double,
        diarSegments: [TimedSpeakerSegment], ordinals: [String: Int]
    ) -> String {
        var bestOrdinal: Int? = nil
        var bestOverlap = 0.0
        for seg in diarSegments where !seg.speakerId.isEmpty {
            let segStart = Double(seg.startTimeSeconds)
            let segEnd = Double(seg.endTimeSeconds)
            let overlap = max(0.0, min(end, segEnd) - max(start, segStart))
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestOrdinal = ordinals[seg.speakerId]
            }
        }
        if let n = bestOrdinal, bestOverlap > 0 {
            return "Speaker \(n)"
        }
        return "Speaker ?"
    }

    // ─── Heartbeat ──────────────────────────────────────────────────────

    private func startHeartbeatIfNeeded() {
        if heartbeatTask != nil { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { break }
                await self?.tickHeartbeat()
            }
        }
    }

    private func tickHeartbeat() {
        let fill = window?.fillSeconds ?? 0
        let beat = MetaHeartbeatPayload(rtfCurrent: lastTranscribeRTF, ringBufferFillSec: fill)
        broadcast(WireEnvelope(type: "meta.heartbeat", payload: beat))
    }

    // ─── Emission helpers ───────────────────────────────────────────────

    private func emitSegment(uid: String, isFinal: Bool, seg: WindowSegment) {
        // Retain finalized intervals for the post-stop diarization pass
        // (Phase 5). Only when a diarizer is attached — otherwise it's dead
        // bookkeeping. Timing only; no text is stored here.
        if isFinal, diarizer != nil {
            finalizedUtterances.append(FinalizedUtterance(
                utteranceId: uid, tStart: seg.tStart, tEnd: seg.tEnd))
        }
        let payload = SegmentPayload(
            utteranceId: uid,
            segmentId: isFinal ? UUID().uuidString : nil,
            tStart: seg.tStart,
            tEnd: seg.tEnd,
            text: seg.text,
            language: seg.language,
            speaker: nil,        // Phase 5
            translation: nil     // Phase 6
        )
        let env = WireEnvelope(type: isFinal ? "segment.final" : "segment.partial",
                               payload: payload)
        broadcast(env)
    }

    private func sendAck(_ client: WebSocketClient, id: String?) {
        let env = WireEnvelope(type: "ack", payload: AckPayload(), id: id)
        sendOnly(client, envelope: env)
    }

    private func sendError(_ client: WebSocketClient, id: String?,
                           code: String, message: String, recoverable: Bool,
                           action: String? = nil) {
        let env = WireEnvelope(type: "error", payload: ErrorPayload(
            code: code, message: message, recoverable: recoverable, action: action
        ), id: id)
        sendOnly(client, envelope: env)
    }

    private func sendOnly<P: Encodable>(_ client: WebSocketClient, envelope: WireEnvelope<P>) {
        guard let data = try? encodeWireMessage(envelope) else { return }
        client.send(data)
    }

    private func broadcast<P: Encodable>(_ envelope: WireEnvelope<P>) {
        guard let data = try? encodeWireMessage(envelope) else { return }
        for client in clients.values where client.isOpen {
            client.send(data)
        }
    }
}

// ─── Whisper special-token scrubbing (duplicated from HarkEngine) ────────
//
// Same regex as hark-engine's stripWhisperSpecialTokens. Phase 4+ should
// move this into HarkCore so both call sites share one definition.

private let _harkdSpecialTokenRegex = try! NSRegularExpression(
    pattern: #"<\|[^|]*\|>"#, options: []
)

func stripWhisperSpecials(_ s: String) -> String {
    let range = NSRange(s.startIndex..<s.endIndex, in: s)
    return _harkdSpecialTokenRegex.stringByReplacingMatches(
        in: s, options: [], range: range, withTemplate: ""
    )
}
