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

    /// Offline speaker diarizer (Phase 5, ADR-0016). Wraps FluidAudio's
    /// `OfflineDiarizerManager` (VBx global clustering, overlapping windows,
    /// exclusive segments). nil until the models finish loading; nil-tolerant
    /// everywhere — a missing/failed diarizer NEVER blocks capture or stop.
    /// Used only by the post-stop pass.
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
    /// post-stop diarization pass can label them by time-overlap AND so the
    /// vault writer (Slice 2) can render the transcript body. We retain timing
    /// + uid (for diarization overlap) + text (for the markdown body). The text
    /// lives ONLY in this in-RAM buffer during the session and is written ONLY
    /// to the vault at stop — never logged, never sent anywhere else (rule #2).
    private struct FinalizedUtterance {
        let utteranceId: String
        let tStart: Double
        let tEnd: Double
        let text: String
    }
    private var finalizedUtterances: [FinalizedUtterance] = []

    /// utterance_ids the ledger reported as SUPERSEDED during the session
    /// (ADR-0018). A superseded fragment has been retracted in favour of a
    /// later, overlapping, more-complete re-segmentation: it is broadcast once
    /// via `segment.superseded` (so the live UI deletes it) and filtered out of
    /// the at-stop vault retention in `dedupedFinalizedUtterances()`. Populated
    /// from `ledger.drainSupersessions()` after every reconcile/prune batch.
    /// Reset per capture.start.
    private var supersededIds: Set<String> = []

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
    /// Running average of per-hop transcription RTF across the session, for the
    /// `meeting.saved` stats. We accumulate sum + count rather than keep only a
    /// last/current value so `rtfAvg` is an honest session mean, not a snapshot.
    /// Reset at capture.start; sampled at stop. (Excludes the diarization pass's
    /// own RTF — this is the live transcription RTF the latency budget targets.)
    private var rtfSum: Double = 0
    private var rtfSamples: Int = 0

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
            // Static build capability: this build ships offline diarization.
            // meta.hello describes what the build can do, not per-session
            // diarizer-load state — the model-load failure path degrades at
            // runtime rather than removing the capability. Translation is not
            // built yet, so it stays off the list — keep this honest.
            capabilities: ["diarization"]
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
        // Snapshot session identity + start BEFORE we clear session state
        // below: `dispatchCaptureStop` runs to completion on the actor and
        // wipes `sessionId`/`sessionStartDate` synchronously, so the flush Task
        // (which acquires the actor later) would otherwise see them already
        // nil. We pass them in so the vault file + `meeting.saved` carry the
        // real session id and the correct wall-clock anchor. No session id is
        // ever generated here — `startCapture` always assigns one.
        let sid = sessionId ?? UUID().uuidString
        let start = sessionStartDate ?? Date()
        let durationSec: Double = Date().timeIntervalSince(start)
        let avgRTF = rtfSamples > 0 ? rtfSum / Double(rtfSamples) : lastTranscribeRTF

        do {
            try pipeline.stop()
        } catch {
            FileHandle.standardError.write(Data("harkd: pipeline stop error: \(error)\n".utf8))
        }
        // Flush remaining buffered speech, run the offline diarization pass,
        // then write the meeting to the vault + emit `meeting.saved`. All
        // best-effort and OFF the live path — we don't block the ack on it,
        // and a write/git failure can never break the stop lifecycle.
        let flushTask = Task { [weak self] in
            await self?.flushOnStop(sessionId: sid, sessionStart: start,
                                    durationSec: durationSec, rtfAvg: avgRTF)
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
        self.rtfSum = 0
        self.rtfSamples = 0
        // NOTE: `finalizedUtterances`, `sessionAudio`, and `supersededIds` are
        // NOT cleared here — the flush Task (which runs later on the actor)
        // still needs them for the diarization pass + vault write. They're
        // cleared inside `flushOnStop` after they've been consumed.
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
        self.rtfSum = 0
        self.rtfSamples = 0

        // Reset the offline-diarization buffers for the new session and
        // pre-reserve ~10 min of audio so early growth doesn't reallocate.
        // (10 min × 60 s × 16 kHz = 9.6M floats ≈ 38 MB.) Longer meetings
        // grow past this via amortized doubling — still off the audio thread.
        self.sessionAudio.removeAll(keepingCapacity: true)
        if diarizer != nil {
            self.sessionAudio.reserveCapacity(16_000 * 60 * 10)
        }
        self.finalizedUtterances.removeAll(keepingCapacity: true)
        self.supersededIds.removeAll(keepingCapacity: true)

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
        if audioSeconds > 0 {
            self.rtfSum += rtf
            self.rtfSamples += 1
        }

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
        for p in pruned where !p.wasFinalized && !p.wasSuperseded {
            // A superseded orphan is NOT closed with a synthetic final — it was
            // already retracted in favour of the segment that grew past it
            // (ADR-0018); a closing final would resurrect the fragment.
            let orphanSeg = WindowSegment(
                tStart: p.tStart, tEnd: p.tEnd, text: p.lastText, language: nil
            )
            emitSegment(uid: p.id, isFinal: true, seg: orphanSeg)
        }

        // Drain + broadcast any supersessions detected during this reconcile
        // batch (the `resolve` mints above). Additive retraction signal — it
        // does not alter the partial/final lifecycle. See ADR-0018.
        drainAndEmitSupersessions(ledger)

        self.transcribeInFlight = false
    }

    /// Drain whatever's left after capture.stop. Transcribes the buffered
    /// window once (if any speech is present) and emits remaining partials
    /// as finals so the UI doesn't leave dangling partials.
    private func flushOnStop(sessionId: String, sessionStart: Date,
                             durationSec: Double, rtfAvg: Double) async {
        // Snapshot + detach the full-session audio BEFORE the transcription
        // drain's `await` (which suspends this actor and could let a fresh
        // capture.start wipe the live buffer). The drain itself only appends
        // to `finalizedUtterances`, not to `sessionAudio`, so taking the audio
        // here is safe; we grab the finalized list after the drain.
        let capturedAudio = sessionAudio
        sessionAudio.removeAll(keepingCapacity: false)

        // Drain the live transcription buffer first (this emits the last
        // finals, populating `finalizedUtterances`), then run the offline
        // diarization pass to label each utterance "Speaker N", then write the
        // meeting to the vault + emit `meeting.saved`. Guarded end-to-end so it
        // can never break the capture/stop lifecycle.
        await flushTranscriptionDrain()

        // `finalizedUtterances` is the APPEND-ONLY emission log: `emitSegment`
        // pushes a row every time a `segment.final` fires. A single utterance
        // can be finalized more than once across the session — the live feed
        // dedups by `utterance_id` on the UI side (last write wins), but the
        // retained log keeps every emit, so the written transcript ends up with
        // duplicates AND out-of-order rows (finals append in emission order, not
        // t_start order). Two duplicate sources, both real in the traces:
        //   1. same utterance_id finalized twice (normal final + drain/orphan).
        //   2. ADR-0009's accepted tradeoff: when WhisperKit re-segments coarsely
        //      the max-denominator rule MINTS A FRESH uid for what is really the
        //      same utterance — distinct ids, near-identical text + t_start.
        // Dedup mirrors the live FINAL set: collapse to one row per utterance,
        // last-write-wins (the most-complete final text), then sort by t_start.
        let capturedUtterances = dedupedFinalizedUtterances()
        let rawCount = finalizedUtterances.count
        let supersededCount = supersededIds.count
        finalizedUtterances.removeAll(keepingCapacity: false)
        supersededIds.removeAll(keepingCapacity: false)
        if rawCount != capturedUtterances.count {
            FileHandle.standardError.write(Data(String(
                format: "harkd: finalized utterances deduped %d → %d for vault write (superseded=%d)\n",
                rawCount, capturedUtterances.count, supersededCount).utf8))
        }

        let (labeled, attendees) = await runDiarizationPass(
            audio: capturedAudio, utterances: capturedUtterances)

        await persistMeeting(
            sessionId: sessionId, sessionStart: sessionStart,
            durationSec: durationSec, rtfAvg: rtfAvg,
            segmentCount: capturedUtterances.count,
            labeled: labeled, attendees: attendees)
    }

    /// Collapse the append-only `finalizedUtterances` emission log into the set
    /// the vault should contain — each utterance ONCE — then return it sorted by
    /// `tStart` ascending. Off the live path (stop only).
    ///
    /// Dedup is two-stage:
    ///   1. By `utterance_id`, last-write-wins. The final emit for a uid is the
    ///      most-complete text (text only ever grows/refines before lock), so
    ///      keeping the last occurrence mirrors the live feed's reconciliation.
    ///   2. By (rounded t_start, normalized text) for DISTINCT uids that are
    ///      really the same utterance — ADR-0009 mints a fresh id when WhisperKit
    ///      re-segments coarsely, yielding duplicate rows with identical text and
    ///      near-identical timing. We round t_start to 1 s so a 1-3 s boundary
    ///      shift still collapses, and lowercase/trim the text so casing/spacing
    ///      jitter across passes doesn't defeat the match. Keep the later row.
    ///
    /// Before either stage, SUPERSEDED utterances (ADR-0018) are dropped: a
    /// fragment retracted live via `segment.superseded` must not survive into
    /// the written file. This is the at-stop half of the one-signal-two-readers
    /// rule — the live UI deleted it on the wire frame; the writer filters the
    /// same ids here. (Stages 1+2 still run as a backstop for re-segmentation
    /// duplicates the conservative supersession gate intentionally let through.)
    /// The sort is unconditional — a safety net so the body is chronological even
    /// if dedup ever leaves rows in a different order.
    private func dedupedFinalizedUtterances() -> [FinalizedUtterance] {
        // Stage 0: drop superseded fragments (retracted live; never written).
        let retained = finalizedUtterances.filter { !supersededIds.contains($0.utteranceId) }

        // Stage 1: last-write-wins by utterance_id, preserving last-seen order.
        var byId: [String: FinalizedUtterance] = [:]
        var idOrder: [String] = []
        for u in retained {
            if byId[u.utteranceId] == nil { idOrder.append(u.utteranceId) }
            byId[u.utteranceId] = u
        }

        // Stage 2: collapse distinct-uid duplicates (same text + ~same start).
        func key(_ u: FinalizedUtterance) -> String {
            let t = (u.tStart).rounded()  // 1 s bucket absorbs boundary jitter
            let text = u.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(Int(t))|\(text)"
        }
        var byKey: [String: FinalizedUtterance] = [:]
        for id in idOrder {
            guard let u = byId[id] else { continue }
            byKey[key(u)] = u  // later occurrence wins
        }

        return byKey.values.sorted { $0.tStart < $1.tStart }
    }

    // ─── Vault persistence + meeting.saved (Phase 5 Slice 2, ADR-0015/0016) ──
    //
    // Runs only at stop, after diarization — OFF the live hot path. Writes the
    // meeting markdown to the vault and broadcasts `meeting.saved`. Guarded:
    // a write/git failure logs and returns; it must NOT crash stop, must NOT
    // prevent the session from finalizing, and must NOT emit a malformed frame.

    private func persistMeeting(
        sessionId: String, sessionStart: Date,
        durationSec: Double, rtfAvg: Double, segmentCount: Int,
        labeled: [VaultWriter.Utterance], attendees: [String]
    ) async {
        let title = VaultWriter.autoTitle(forStart: sessionStart)
        let writer = VaultWriter()
        let result: VaultWriter.Result
        do {
            result = try writer.write(
                title: title,
                sessionStart: sessionStart,
                durationSec: durationSec,
                attendees: attendees,
                utterances: labeled)
        } catch {
            // The .md write itself failed (mkdir / atomic write). Surface a
            // warning on the existing `warning` frame — do NOT invent a new
            // frame — and bail. The session has already finalized.
            FileHandle.standardError.write(Data(
                "harkd: vault write failed (\(type(of: error))); meeting not saved this session\n".utf8))
            broadcast(WireEnvelope(type: "warning", payload: WarningPayload(
                code: "vault_write_failed",
                message: "could not write the meeting transcript to the vault",
                severity: "high"
            )))
            return
        }

        FileHandle.standardError.write(Data(String(
            format: "harkd: meeting saved — %@  (committed=%@  segments=%d  speakers=%d)\n",
            result.fileURL.path, result.committed ? "yes" : "no",
            segmentCount, attendees.count
        ).utf8))

        // v1 is anonymous: every speaker carries matchedName/confidence == nil.
        // Phase 5.1 (enrollment/naming) populates them without a contract change.
        let speakers = attendees.map { MeetingSpeaker(label: $0, matchedName: nil, confidence: nil) }
        let payload = MeetingSavedPayload(
            sessionId: sessionId,
            vaultPath: result.fileURL.path,
            speakers: speakers,
            stats: MeetingStats(
                segments: segmentCount,
                durationSec: durationSec,
                rtfAvg: rtfAvg))
        broadcast(WireEnvelope(type: "meeting.saved", payload: payload))
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
        // The drain pass can itself supersede earlier fragments (it re-decodes
        // the whole tail buffer). Broadcast those before stop completes so the
        // live UI and the retention filter both see them. See ADR-0018.
        drainAndEmitSupersessions(ledger)
    }

    // ─── Offline diarization pass (Phase 5, ADR-0016) ───────────────────
    //
    // Runs after the transcription drain, over the full session audio. Assigns
    // each finalized utterance a "Speaker N" label by max time-overlap against
    // FluidAudio's diarization segments. Returns the labeled, time-ordered
    // utterances ready for the vault body PLUS the distinct attendee labels in
    // first-seen order, so `persistMeeting` can write the file + emit
    // `meeting.saved`. Guarded end-to-end: on no-diarizer / too-short-audio /
    // diarize failure it returns the utterances labeled "Speaker ?" (and no
    // attendees), so the meeting is STILL written — just without attribution.
    // Capture/stop already completed by the time this runs.

    private func runDiarizationPass(
        audio samples: [Float],
        utterances: [FinalizedUtterance]
    ) async -> (labeled: [VaultWriter.Utterance], attendees: [String]) {

        // Fallback used on every non-success path: no labels, no attendees, but
        // the transcript text is preserved so the vault file is never empty.
        func unlabeled() -> ([VaultWriter.Utterance], [String]) {
            let labeled = utterances.map {
                VaultWriter.Utterance(tStart: $0.tStart, label: "Speaker ?", text: $0.text)
            }
            return (labeled, [])
        }

        guard let diarizer = diarizer else { return unlabeled() }

        let audioSeconds = Double(samples.count) / 16_000.0
        if samples.isEmpty || audioSeconds < 1.0 {
            FileHandle.standardError.write(Data(
                "harkd: diarization skipped (only \(String(format: "%.2f", audioSeconds))s of audio)\n".utf8))
            return unlabeled()
        }

        let started = Date()
        let result: DiarizationResult
        do {
            // OFFLINE pipeline (ADR-0016 / offline rewire): VBx global clustering
            // over overlapping windows → EXCLUSIVE (non-overlapping) segments.
            // Finer/exclusive segments make the max-overlap assignment below
            // accurate on rapid back-and-forth; the debug ambiguity summary
            // confirms the straddle case drops toward zero.
            result = try await diarizer.diarize(samples)
        } catch {
            FileHandle.standardError.write(Data(
                "harkd: diarization failed (\(error)); no speaker labels this session\n".utf8))
            return unlabeled()
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

        // Always-on summary line. avg_seg_dur lets a verification run see the
        // offline pipeline's finer/exclusive segmentation at a glance (shorter
        // average vs the old streaming chunked pass = the expected improvement).
        let totalSegDur = result.segments.reduce(0.0) { $0 + Double($1.durationSeconds) }
        let avgSegDur = result.segments.isEmpty ? 0.0 : totalSegDur / Double(result.segments.count)
        FileHandle.standardError.write(Data(String(
            format: "harkd: diarization done (offline) — speakers=%d  diar_segments=%d  avg_seg_dur=%.2fs  utterances=%d  audio=%.1fs  diar_time=%.2fs  rtf=%.3f\n",
            speakerCount, result.segments.count, avgSegDur, utterances.count,
            audioSeconds, diarSeconds, rtf
        ).utf8))

        // Verbose diagnostics gate. When set, dump the full diar-segment table
        // up front so the per-utterance overlap lines below can be read against
        // it. All extra output stays behind this flag — the summary line above
        // is unconditional and unchanged.
        let debug = ProcessInfo.processInfo.environment["HARK_DIAR_DEBUG"] == "1"
        if debug {
            FileHandle.standardError.write(Data(
                "harkd: diar-segments (idx | speakerId→ord | start..end | dur)\n".utf8))
            for (i, seg) in result.segments.enumerated() {
                let ord = ordinalForSpeakerId[seg.speakerId].map { "S\($0)" } ?? "—"
                FileHandle.standardError.write(Data(String(
                    format: "harkd:   %3d | %@ %@ | %8.2f..%8.2f | %6.2f\n",
                    i, seg.speakerId.isEmpty ? "(empty)" : seg.speakerId, ord,
                    Double(seg.startTimeSeconds), Double(seg.endTimeSeconds),
                    Double(seg.durationSeconds)
                ).utf8))
            }
        }

        // Label each utterance by max temporal overlap, and collect the
        // distinct labels in the order utterances first reference them (i.e.
        // session-time order) so `attendees` reads naturally. "Speaker ?" is a
        // valid label but is NOT added to attendees — it's "unattributed", not
        // a roster member.
        var labeled: [VaultWriter.Utterance] = []
        labeled.reserveCapacity(utterances.count)
        var attendees: [String] = []
        var seen = Set<String>()
        // Ambiguity accounting (debug summary only — no behavior change).
        var ambiguousCount = 0
        var zeroOverlapCount = 0
        for u in utterances {
            let m = matchSpeaker(
                forUtteranceStart: u.tStart, end: u.tEnd,
                diarSegments: result.segments, ordinals: ordinalForSpeakerId)
            let label = m.label
            if label != "Speaker ?", seen.insert(label).inserted {
                attendees.append(label)
            }
            labeled.append(VaultWriter.Utterance(tStart: u.tStart, label: label, text: u.text))
            if debug {
                // "Ambiguous" = the chosen and runner-up overlaps are within
                // 25% of each other AND the runner-up is a DIFFERENT speaker —
                // i.e. a near-tie across a speaker boundary, the straddle case.
                let ambiguous = m.runnerUpOverlap > 0
                    && m.runnerUpSpeakerOrdinal != m.chosenSpeakerOrdinal
                    && m.runnerUpOverlap >= m.chosenOverlap * 0.75
                if m.chosenOverlap <= 0 { zeroOverlapCount += 1 }
                if ambiguous { ambiguousCount += 1 }
                let chosenDesc = m.chosenSegmentIndex.map { idx in
                    String(format: "seg#%d %@ ovl=%.2f", idx,
                            m.chosenSpeakerOrdinal.map { "S\($0)" } ?? "—", m.chosenOverlap)
                } ?? "none"
                let runnerDesc = m.runnerUpSegmentIndex.map { idx in
                    String(format: "seg#%d %@ ovl=%.2f", idx,
                            m.runnerUpSpeakerOrdinal.map { "S\($0)" } ?? "—", m.runnerUpOverlap)
                } ?? "none"
                let flag = m.chosenOverlap <= 0 ? " [ZERO-OVERLAP]" : (ambiguous ? " [AMBIGUOUS]" : "")
                FileHandle.standardError.write(Data(String(
                    format: "harkd: diar  %8.2f..%8.2f → %@  chosen={%@}  runnerUp={%@}%@\n",
                    u.tStart, u.tEnd, label, chosenDesc, runnerDesc, flag
                ).utf8))
            }
        }

        if debug {
            FileHandle.standardError.write(Data(String(
                format: "harkd: diar-ambiguity — utterances=%d  ambiguous=%d  zeroOverlap(Speaker ?)=%d\n",
                utterances.count, ambiguousCount, zeroOverlapCount
            ).utf8))
        }

        // Sort attendees by their ordinal so the roster reads Speaker 1,
        // Speaker 2… regardless of who happened to speak first.
        attendees.sort { ($0.ordinalSuffix ?? .max) < ($1.ordinalSuffix ?? .max) }
        return (labeled, attendees)
    }

    /// Diagnostic-rich result of matching one utterance to a diar segment.
    /// `label` is the SAME value the old `speakerLabel` returned; the rest is
    /// observability for the debug log (which segment won, by how much, and
    /// what the strongest competing-speaker segment was). Sendable-free; it
    /// never crosses an actor boundary.
    private struct SpeakerMatch {
        let label: String
        let chosenSegmentIndex: Int?
        let chosenSpeakerOrdinal: Int?
        let chosenOverlap: Double
        let runnerUpSegmentIndex: Int?
        let runnerUpSpeakerOrdinal: Int?
        let runnerUpOverlap: Double
    }

    /// Match the utterance interval [start, end] to the diarization segment with
    /// the greatest temporal overlap, returning a "Speaker N" label (or
    /// "Speaker ?" when nothing overlaps). The label decision is identical to
    /// the prior `speakerLabel`: pick the single max-overlap segment, require
    /// overlap > 0. The extra fields are pure diagnostics — they DO NOT affect
    /// the label — and surface the straddle case (a diar segment spanning a
    /// speaker change so a back-and-forth all inherits one label): when the
    /// runner-up belongs to a different speaker with comparable overlap, the
    /// caller marks the assignment ambiguous.
    ///
    /// NOTE: the runner-up is the best overlap from a speaker DIFFERENT from the
    /// chosen one, so "ambiguous" specifically means a near-tie ACROSS speakers,
    /// not two segments of the same speaker.
    private func matchSpeaker(
        forUtteranceStart start: Double, end: Double,
        diarSegments: [TimedSpeakerSegment], ordinals: [String: Int]
    ) -> SpeakerMatch {
        var bestOrdinal: Int? = nil
        var bestOverlap = 0.0
        var bestIndex: Int? = nil
        // Strongest overlap from a speaker other than the current best.
        var runnerOrdinal: Int? = nil
        var runnerOverlap = 0.0
        var runnerIndex: Int? = nil

        for (i, seg) in diarSegments.enumerated() where !seg.speakerId.isEmpty {
            let segStart = Double(seg.startTimeSeconds)
            let segEnd = Double(seg.endTimeSeconds)
            let overlap = max(0.0, min(end, segEnd) - max(start, segStart))
            if overlap <= 0 { continue }
            let ord = ordinals[seg.speakerId]
            if overlap > bestOverlap {
                // The previous best becomes the runner-up only if it's a
                // different speaker; otherwise keep searching for a competitor.
                if let prevOrd = bestOrdinal, prevOrd != ord, bestOverlap > runnerOverlap {
                    runnerOverlap = bestOverlap
                    runnerOrdinal = bestOrdinal
                    runnerIndex = bestIndex
                }
                bestOverlap = overlap
                bestOrdinal = ord
                bestIndex = i
            } else if ord != bestOrdinal, overlap > runnerOverlap {
                runnerOverlap = overlap
                runnerOrdinal = ord
                runnerIndex = i
            }
        }

        let label: String = (bestOrdinal != nil && bestOverlap > 0) ? "Speaker \(bestOrdinal!)" : "Speaker ?"
        return SpeakerMatch(
            label: label,
            chosenSegmentIndex: bestIndex,
            chosenSpeakerOrdinal: bestOrdinal,
            chosenOverlap: bestOverlap,
            runnerUpSegmentIndex: runnerIndex,
            runnerUpSpeakerOrdinal: runnerOrdinal,
            runnerUpOverlap: runnerOverlap
        )
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
        // Retain finalized utterances for the post-stop pass: timing+uid drive
        // the diarization time-overlap labelling, and text feeds the vault
        // markdown body (Slice 2). We retain UNCONDITIONALLY now (not only when
        // a diarizer is attached) so the meeting file is written even if the
        // diarizer failed to load — those utterances just get "Speaker ?".
        if isFinal {
            finalizedUtterances.append(FinalizedUtterance(
                utteranceId: uid, tStart: seg.tStart, tEnd: seg.tEnd, text: seg.text))
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

    /// Drain any supersession events the ledger recorded since the last drain
    /// and, for each, broadcast a `segment.superseded { utteranceId, supersededBy }`
    /// ONCE and remember the retracted id (ADR-0018). The UI deletes the old
    /// utterance from its live map on receipt; the at-stop vault writer filters
    /// it from the retained set via `supersededIds`. Chains (A→B→C) surface as
    /// separate events and each is emitted in order — only the final survivor
    /// is left unretracted. Pure retraction signal: it never changes when a
    /// `segment.final` fires for a non-superseded utterance.
    private func drainAndEmitSupersessions(_ ledger: UtteranceLedger) {
        for ev in ledger.drainSupersessions() {
            supersededIds.insert(ev.oldId)
            FileHandle.standardError.write(Data(
                "harkd: superseded \(ev.oldId) → \(ev.newId)\n".utf8))
            broadcast(WireEnvelope(type: "segment.superseded",
                                   payload: SegmentSupersededPayload(
                                       utteranceId: ev.oldId,
                                       supersededBy: ev.newId)))
        }
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

// ─── "Speaker N" ordinal parsing ─────────────────────────────────────────
//
// Used to sort the attendee roster by speaker ordinal (Speaker 1, Speaker 2…)
// rather than by who spoke first. "Speaker ?" has no ordinal (returns nil).

private extension String {
    var ordinalSuffix: Int? {
        guard let n = self.split(separator: " ").last else { return nil }
        return Int(n)
    }
}
