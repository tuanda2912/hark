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

    /// The most recent model-load progress snapshot, so a UI that connects
    /// MID-DOWNLOAD immediately sees the current phase instead of a blank
    /// "(loading)" until the next callback fires. Set by `emitModelProgress`,
    /// replayed in `handleConnect` (after `meta.hello`), cleared in `attachModel`
    /// when `meta.ready` makes it terminal. Same spirit as `attachModel` pushing
    /// `meta.ready` to already-connected clients. nil once the model is ready.
    private var lastModelProgress: MetaModelProgressPayload?

    /// At-stop dedup time-gate, seconds (stage 2 of `dedupedFinalizedUtterances`).
    /// Resolved once at init from `HARK_DEDUP_WINDOW_SEC` (clamped, logged) so it
    /// can be swept on-device without recompiling. See `resolveDedupWindow`.
    private let dedupWindowSeconds: Double

    /// Offline speaker diarizer (Phase 5, ADR-0016). Wraps FluidAudio's
    /// `OfflineDiarizerManager` (VBx global clustering, overlapping windows,
    /// exclusive segments). nil until the models finish loading; nil-tolerant
    /// everywhere — a missing/failed diarizer NEVER blocks capture or stop.
    /// Used only by the post-stop pass.
    private var diarizer: Diarizer?

    /// Shared STREAMING diarizer manager for OPTIONAL live provisional labels.
    /// Loaded once at startup (separate model pair from the offline pass), held
    /// for the daemon's life. nil if the streaming models failed to load — in
    /// which case `live_diarization: true` degrades to a no-op (capture + the
    /// offline pass still work). A fresh per-session `LiveDiarizer` actor wraps
    /// this manager only when a session opts in; it resets the manager's
    /// speaker database at session start for clean per-meeting IDs.
    private var liveDiarizerManager: DiarizerManager?

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

    /// Commit watermark (ADR-0019): the session-relative audio time (seconds
    /// since capture start) up to which we have ALREADY finalized. Monotonic,
    /// starts at 0. Each hop finalizes the segments whose `t_start` lies in
    /// `(committedUpTo, commitHorizon]` exactly once, then advances this to the
    /// horizon. Audio at/before this is NEVER re-finalized — that is what kills
    /// the duplicate `segment.final` frames the old older-zone rule produced.
    /// Reset to 0 per capture.start. The hot region (`t_start > committedUpTo`)
    /// still flows partials with ADR-0009-stable utterance_ids, unchanged.
    private var committedUpTo: Double = 0

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

    // ─── Live (provisional) diarization, OPTIONAL per session ───────────────
    //
    // Created per `capture.start` ONLY when the payload sets
    // `live_diarization: true` AND the streaming manager loaded. nil otherwise
    // (the default), so the live path is byte-for-byte unchanged when off.
    //
    /// Per-session streaming diarizer actor (provisional labels). nil = off.
    private var liveDiarizer: LiveDiarizer?
    /// Continuous-audio chunker for the live diarizer. We tee the SAME mixed
    /// frames the transcription window sees into here and, every
    /// `liveChunkSkipSec` of accumulated wall-clock audio, hand the most-recent
    /// `liveChunkDurationSec` window to the LiveDiarizer actor (off the hot
    /// path). Holds raw 16 kHz mono Float; bounded to the chunk window.
    private var liveDiarChunkBuffer: [Float] = []
    /// Session-time (seconds since capture start) of the first sample currently
    /// in `liveDiarChunkBuffer`. Anchors each dispatched chunk on the SAME axis
    /// the emitted utterances use, so overlap tagging is correct.
    private var liveDiarChunkStartTime: Double = 0
    /// Samples accumulated since the last chunk was dispatched.
    private var liveDiarSamplesSinceDispatch: Int = 0
    /// Streaming chunk geometry (FluidAudio docs' 5 s / 2 s recommendation).
    /// 5 s gives the segmentation model enough context; a 2 s skip keeps labels
    /// arriving roughly every 2 s of speech — well inside the provisional remit.
    private let liveChunkDurationSec: Double = 5.0
    private let liveChunkSkipSec: Double = 2.0

    /// Finalized utterances accumulated during the session, kept so the
    /// post-stop diarization pass can label them by time-overlap AND so the
    /// vault writer (Slice 2) can render the transcript body. We retain timing
    /// + uid (for diarization overlap) + text (for the markdown body). The text
    /// lives ONLY in this in-RAM buffer during the session and is written ONLY
    /// to the vault at stop — never logged, never sent anywhere else (rule #2).
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

    // ─── Post-save speaker rename (most-recent meeting) ──────────────────
    //
    // Diarization labels live ONLY in the written vault markdown — `segment.final`
    // carries `speaker: nil` live — so renaming a speaker is a RE-RENDER of the
    // already-saved file with the user's display names. We retain everything
    // `persistMeeting`/`renderMarkdown` needs to reproduce that file identically
    // EXCEPT the labels: the vault path, the session-time anchors, and each
    // utterance's label+text+tStart. Set right after a successful vault write;
    // it deliberately SURVIVES capture.stop's session-state wipe (unlike the
    // session-scoped fields above) so a rename can land after stop. MVP: only the
    // single most-recent meeting is renameable.
    private struct SavedMeetingSnapshot {
        let sessionId: String
        let vaultPath: URL
        let sessionStart: Date
        let durationSec: Double
        let rtfAvg: Double
        let segmentCount: Int
        var labeled: [VaultWriter.Utterance]   // each utterance's label+text+tStart
        var attendees: [String]
    }
    private var lastSavedMeeting: SavedMeetingSnapshot?

    init(server: HarkdWebSocketServer) {
        self.server = server
        self.dedupWindowSeconds = EngineSession.resolveDedupWindow(
            ProcessInfo.processInfo.environment["HARK_DEDUP_WINDOW_SEC"])
    }

    /// Inject the model once it has finished loading. Until this runs,
    /// capture.start is rejected with a recoverable ENGINE_WARMING_UP, so the
    /// WS server + port file can come up before the (slow) model load.
    func attachModel(_ pipe: WhisperKit, name: String) {
        self.whisperKit = pipe
        self.modelName = name
        // `meta.ready` is the terminal readiness signal — model-load progress is
        // done. Clear the snapshot so a client connecting after this point gets
        // the ready hello (model_loaded = name) and no stale progress replay.
        self.lastModelProgress = nil
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

    /// Inject the shared STREAMING diarizer manager for OPTIONAL live labels.
    /// Held for the daemon's life; a per-session `LiveDiarizer` wraps it only
    /// when a `capture.start` opts in. Loaded after both WhisperKit and the
    /// offline diarizer — purely additive, never affects readiness.
    func attachLiveDiarizer(manager: DiarizerManager) {
        self.liveDiarizerManager = manager
    }

    /// Broadcast a `meta.model_progress` frame and retain it as the latest
    /// snapshot for mid-download replay (see `lastModelProgress`). Called from
    /// the model loaders' off-actor `@Sendable` progress callbacks via a
    /// `Task { await session.emitModelProgress(...) }` hop — the callbacks never
    /// touch actor state directly. The CALLER throttles before the hop (the
    /// FluidAudio byte callback + WhisperKit per-1% callback fire very
    /// frequently); this method just snapshots + broadcasts. Additive: it never
    /// affects readiness — `attachModel`/`meta.ready` remains the terminal
    /// signal and clears the snapshot.
    func emitModelProgress(phase: String, fraction: Double?, detail: String) {
        // A late progress callback can arrive after `attachModel` cleared the
        // snapshot (the compile heartbeat / diarizer download races readiness).
        // Once ready, model-load progress is terminal — drop it rather than
        // re-broadcast post-ready noise or resurrect the replay snapshot.
        guard !modelReady else { return }
        let payload = MetaModelProgressPayload(phase: phase, fraction: fraction, detail: detail)
        lastModelProgress = payload
        broadcast(WireEnvelope(type: "meta.model_progress", payload: payload))
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
        // If the model is still loading and we have a progress snapshot, replay
        // it to THIS client right after hello so a UI connecting mid-download
        // sees the current phase/fraction immediately rather than waiting for
        // the next callback. Same spirit as `attachModel` pushing `meta.ready`
        // to already-connected clients. Cleared once `meta.ready` fires.
        if !modelReady, let progress = lastModelProgress {
            sendOnly(client, envelope: WireEnvelope(type: "meta.model_progress", payload: progress))
        }
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
        case "speaker.rename":
            dispatchSpeakerRename(client, id: header.id, data: data)
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
        // Live provisional diarization is OPT-IN and only honoured when the
        // streaming manager actually loaded. Default false → unchanged behavior.
        let wantsLiveDiar = (cmd.liveDiarization ?? false) && (liveDiarizerManager != nil)
        if (cmd.liveDiarization ?? false) && liveDiarizerManager == nil {
            FileHandle.standardError.write(Data(
                "harkd: live_diarization requested but streaming diarizer unavailable — provisional labels disabled this session\n".utf8))
        }

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
                             language: language,
                             liveDiarization: wantsLiveDiar)
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
        // Snapshot the live transcription state (ledger + window + commit
        // watermark) BEFORE we wipe session state below. `dispatchCaptureStop`
        // is non-async — it runs atomically on the actor with no suspension —
        // so it sets `self.ledger`/`self.window`/`self.committedUpTo` to nil/0
        // at the bottom of THIS call, which happens before the detached
        // `flushTask` ever runs. If `flushOnStop` read `self.ledger` it would
        // see nil and the drain + hot-region finalize would no-op — which is
        // EXACTLY why the tail was lost (the drain never had a ledger to work
        // with). We hand the ledger/window/watermark in, mirroring how `sid`/
        // `start` are snapshotted just above. (`ledger`/`window` are reference
        // types, so this passes the live objects, not copies — the flush
        // mutates them, which is fine: they're about to be discarded anyway.)
        let drainLedger = self.ledger
        let drainWindow = self.window
        let drainCommittedUpTo = self.committedUpTo

        // Flush remaining buffered speech, run the offline diarization pass,
        // then write the meeting to the vault + emit `meeting.saved`. All
        // best-effort and OFF the live path — we don't block the ack on it,
        // and a write/git failure can never break the stop lifecycle.
        let flushTask = Task { [weak self] in
            await self?.flushOnStop(sessionId: sid, sessionStart: start,
                                    durationSec: durationSec, rtfAvg: avgRTF,
                                    ledger: drainLedger, window: drainWindow,
                                    committedUpTo: drainCommittedUpTo)
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
        self.committedUpTo = 0
        self.rtfSum = 0
        self.rtfSamples = 0
        // Tear down the per-session live (provisional) diarizer. The offline
        // pass owns the authoritative labels at stop; the live diarizer's
        // timeline is session-scoped and not consumed after stop. Log its
        // run stats (state only) off the actor via a detached Task — the
        // stats() await must not block the synchronous stop handler.
        if let live = self.liveDiarizer {
            Task {
                let s = await live.stats()
                FileHandle.standardError.write(Data(String(
                    format: "harkd: live diarizer session done — chunks processed=%d dropped=%d, provisional speakers=%d, timeline segments=%d\n",
                    s.processed, s.dropped, s.speakers, s.segments).utf8))
            }
        }
        self.liveDiarizer = nil
        self.liveDiarChunkBuffer.removeAll(keepingCapacity: false)
        self.liveDiarChunkStartTime = 0
        self.liveDiarSamplesSinceDispatch = 0
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

    /// Post-save speaker rename. Re-renders the most-recently-saved meeting's OWN
    /// vault file with the user's display names and git-commits the change.
    ///
    /// MVP scope (hard rule #4, "the vault is sacred"): only the single most-
    /// recent meeting is renameable, and we only ever overwrite ITS file at its
    /// existing path — never another file, never a new one. The rewrite is always
    /// git-committed so history stays recoverable. No network — names stay local.
    ///
    /// The label-application is the PURE `applySpeakerNames` (unit-tested); this
    /// handler only does decode → guard → I/O → snapshot-update → ack.
    private func dispatchSpeakerRename(_ client: WebSocketClient, id: String?, data: Data) {
        let cmd: SpeakerRenameCommand
        do {
            cmd = try decodeInbound(data, payloadType: SpeakerRenameCommand.self)
        } catch {
            sendError(client, id: id, code: "PROTOCOL_MISMATCH",
                      message: "bad speaker.rename payload", recoverable: false)
            return
        }

        guard let snapshot = lastSavedMeeting, snapshot.sessionId == cmd.sessionId else {
            sendError(client, id: id, code: "MEETING_NOT_FOUND",
                      message: "can only rename the most recently saved meeting",
                      recoverable: true)
            return
        }

        // Apply the rename (pure): map matching labels, rebuild the attendee
        // roster as distinct labels in first-appearance order AFTER mapping.
        let (relabeled, attendees) = Self.applySpeakerNames(
            to: snapshot.labeled, names: cmd.names)

        // Re-render + overwrite the SAME file, then git-commit. The title is
        // re-derived from the same session start so the front-matter matches the
        // original render exactly except for the (now renamed) attendee roster.
        let title = VaultWriter.autoTitle(forStart: snapshot.sessionStart)
        let writer = VaultWriter()
        let result: VaultWriter.Result
        do {
            result = try writer.rewrite(
                fileURL: snapshot.vaultPath,
                title: title,
                sessionStart: snapshot.sessionStart,
                durationSec: snapshot.durationSec,
                attendees: attendees,
                utterances: relabeled,
                commitMessage: "chore(vault): rename speakers in \(snapshot.vaultPath.lastPathComponent)")
        } catch {
            FileHandle.standardError.write(Data(
                "harkd: speaker rename write failed (\(type(of: error))); file unchanged\n".utf8))
            sendError(client, id: id, code: "INTERNAL",
                      message: "could not rewrite the meeting transcript", recoverable: true)
            return
        }

        // Update the snapshot in place so a SECOND rename within this session maps
        // from the NOW-current names (e.g. a key of "Alice", not "Speaker 1").
        var updated = snapshot
        updated.labeled = relabeled
        updated.attendees = attendees
        lastSavedMeeting = updated

        FileHandle.standardError.write(Data(String(
            format: "harkd: speakers renamed — %@  (committed=%@  attendees=%d)\n",
            result.fileURL.path, result.committed ? "yes" : "no", attendees.count
        ).utf8))

        sendAck(client, id: id)
    }

    // ─── Capture wiring ─────────────────────────────────────────────────

    private func startCapture(captureMic: Bool,
                              captureSystem: Bool,
                              language: String?,
                              liveDiarization: Bool) throws {
        self.sessionId = UUID().uuidString
        self.sessionStartDate = Date()
        self.captureWallStart = Date()
        self.sessionTimeSeconds = 0
        self.window = SlidingWindowBuffer(windowSeconds: 30, hopSeconds: 5, sampleRate: 16_000)
        self.ledger = UtteranceLedger()
        self.vad = EnergyVAD()
        self.sessionLanguage = language
        self.committedUpTo = 0  // ADR-0019: nothing finalized yet this session.
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

        // Live provisional diarizer (OPTIONAL). Create a fresh per-session actor
        // wrapping the shared streaming manager when this session opted in AND
        // the manager loaded. The actor resets the manager's speaker DB at init
        // for clean per-meeting IDs. nil = off (default) → live path unchanged.
        self.liveDiarChunkBuffer.removeAll(keepingCapacity: true)
        self.liveDiarChunkStartTime = 0
        self.liveDiarSamplesSinceDispatch = 0
        if liveDiarization, let mgr = liveDiarizerManager {
            self.liveDiarizer = LiveDiarizer(manager: mgr)
            self.liveDiarChunkBuffer.reserveCapacity(Int(liveChunkDurationSec * 16_000) + 16_000)
            FileHandle.standardError.write(Data(
                "harkd: live provisional diarization ON (chunk=\(liveChunkDurationSec)s skip=\(liveChunkSkipSec)s)\n".utf8))
        } else {
            self.liveDiarizer = nil
        }

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

        // Tee the SAME continuous (pre-VAD) frames to the live provisional
        // diarizer's chunker, off the hot path. We feed continuous audio (not
        // the speech-only window) so the diarizer's segment timeline shares the
        // wall-clock session axis the emitted utterances are tagged against.
        // The actual diarization runs on the LiveDiarizer actor (dispatched
        // below), never here — this just accumulates + decides when to fire.
        if liveDiarizer != nil {
            feedLiveDiarizer(frames, frameStartSessionTime: now)
        }

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

    // ─── Live (provisional) diarizer chunker ─────────────────────────────
    //
    // Accumulates the continuous mixed frames and, every `liveChunkSkipSec` of
    // audio, dispatches the most-recent `liveChunkDurationSec` window to the
    // LiveDiarizer actor. The accumulation + the dispatch decision run on THIS
    // actor (cheap: appends + an index compare); the heavy diarization runs on
    // the LiveDiarizer actor via a `Task { await … }` hop — it NEVER blocks the
    // transcription hot path, and the LiveDiarizer drops a chunk if a prior one
    // is still in flight (so provisional work can never queue unbounded). The
    // chunk is snapshotted by value before the hop, so a later capture.stop that
    // nils `liveDiarizer` can't race the snapshot.

    private func feedLiveDiarizer(_ frames: [Float], frameStartSessionTime: Double) {
        if liveDiarChunkBuffer.isEmpty {
            liveDiarChunkStartTime = frameStartSessionTime
        }
        liveDiarChunkBuffer.append(contentsOf: frames)
        liveDiarSamplesSinceDispatch += frames.count

        let skipSamples = Int(liveChunkSkipSec * 16_000)
        let chunkSamples = Int(liveChunkDurationSec * 16_000)
        guard liveDiarSamplesSinceDispatch >= skipSamples else { return }
        liveDiarSamplesSinceDispatch = 0

        // Take the most-recent `chunkSamples` as this chunk; anchor its start
        // time at the buffer start advanced by however many samples we dropped.
        let dropCount = max(0, liveDiarChunkBuffer.count - chunkSamples)
        let chunk = Array(liveDiarChunkBuffer.suffix(chunkSamples))
        let chunkStart = liveDiarChunkStartTime + Double(dropCount) / 16_000.0

        // Trim the retained buffer to the chunk window so it stays bounded;
        // advance the buffer's start-time anchor to match.
        if dropCount > 0 {
            liveDiarChunkBuffer.removeFirst(dropCount)
            liveDiarChunkStartTime = chunkStart
        }

        guard let live = liveDiarizer else { return }
        let skipSec = liveChunkSkipSec  // capture the immutable value for the hop
        Task { [weak self] in
            let elapsed = await live.ingest(chunk, chunkStartTime: chunkStart)
            if let secs = elapsed, secs > skipSec {
                // Diarizing a chunk took longer than the skip interval — the
                // live diarizer is the limiting factor. The LiveDiarizer's own
                // busy-drop already prevents backlog; just note it (no text).
                await self?.noteLiveDiarSlow(chunkSeconds: secs)
            }
        }
    }

    /// Off-hot-path log when a live-diarization chunk overran the skip interval.
    /// State only — no transcript text (rule #2/#3).
    private func noteLiveDiarSlow(chunkSeconds: Double) {
        FileHandle.standardError.write(Data(String(
            format: "harkd: live diarize chunk slow (%.2fs > %.2fs skip) — provisional labels may lag\n",
            chunkSeconds, liveChunkSkipSec).utf8))
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

        // Reconciliation — COMMIT-WATERMARK model (ADR-0019).
        //
        // Each hop re-transcribes the whole 30 s window, so every audio span is
        // decoded ~6×. The old rule promoted a segment to final whenever its
        // t_start was in the "older zone" AND its text was stable — but because
        // WhisperKit re-segments coarsely across hops, ADR-0009 mints a FRESH
        // utterance_id for each re-shape, so the SAME speech was finalized 3–4×.
        //
        // Instead we finalize each audio REGION exactly once, behind a monotonic
        // watermark `committedUpTo`:
        //   - commitHorizon = the oldest `hop` seconds of speech in the window —
        //     the span that ages out next hop and will NEVER be re-transcribed.
        //     We anchor on the window's left edge (the one timeline point we
        //     always know exactly; the speech-only buffer may not be full).
        //   - Finalize, ONCE, the segments whose t_start is in
        //     (committedUpTo, commitHorizon]. Straddle rule: a segment is
        //     committed when its t_start crosses the horizon, using THIS hop's
        //     (most-refined, fullest-context) text for that region.
        //   - Everything after committedUpTo (the still-hot region) keeps
        //     flowing `segment.partial` with ADR-0009-stable utterance_ids,
        //     exactly as before — the live caption experience is unchanged.
        //   - Advance committedUpTo = commitHorizon. Audio at/before the
        //     watermark is never finalized or re-emitted again.
        let hopSeconds = self.window?.hopSeconds ?? 5.0
        let commitHorizon = windowStartSessionTime + hopSeconds

        guard let ledger = self.ledger else {
            self.transcribeInFlight = false
            return
        }

        // Track the farthest `t_end` of any segment we FINALIZE this hop. A
        // segment is committed when its START crosses the horizon (the straddle
        // rule), but a long sentence can START before the horizon and END well
        // past it — and we emit it with its FULL text. So that whole span is
        // now committed, not just up to the horizon. We advance the watermark
        // to max(horizon, this end) below, so subsequent hops skip any segment
        // whose start falls inside the span the long sentence already covered
        // (they hit `.skipAlreadyCommitted`). Without this, a long sentence's
        // TAIL gets re-committed as overlapping fragments on the following hops
        // — the boundary-overlap bug ADR-0019's refinement fixes.
        var maxCommittedEnd = committedUpTo

        for seg in winSegments {
            // Resolve utterance identity by overlap, not by t_start bucket.
            // See SlidingWindow.swift comments for rationale.
            let uid = ledger.resolve(tStart: seg.tStart, tEnd: seg.tEnd, text: seg.text)
            if ledger.isFinalized(utteranceId: uid) {
                continue
            }
            // Keep the ledger's last-known text current (for supersession's
            // prefix test + orphan finals). The "did it change?" result is no
            // longer the finalize trigger under the watermark model.
            _ = ledger.updateText(seg.text, utteranceId: uid)
            // Region-commit decision (pure; unit-tested in CommitWatermarkTests).
            switch Self.commitDecision(segmentStart: seg.tStart,
                                       committedUpTo: committedUpTo,
                                       commitHorizon: commitHorizon) {
            case .finalize:
                ledger.markFinalized(utteranceId: uid)
                let spk = await provisionalSpeaker(forStart: seg.tStart, end: seg.tEnd)
                emitSegment(uid: uid, isFinal: true, seg: seg, speaker: spk)
                // This region — its FULL span [tStart, tEnd] — is now committed.
                maxCommittedEnd = max(maxCommittedEnd, seg.tEnd)
            case .partial:
                // Still-hot region (after the watermark, ahead of the horizon):
                // a partial — fresh tail or refined. Live replace-in-place.
                let spk = await provisionalSpeaker(forStart: seg.tStart, end: seg.tEnd)
                emitSegment(uid: uid, isFinal: false, seg: seg, speaker: spk)
            case .skipAlreadyCommitted:
                // seg.tStart <= committedUpTo — already finalized in a prior hop.
                // Never re-emit (this is what kills the duplicate finals).
                break
            }
        }

        // Advance the watermark to the farther of the horizon and the longest
        // committed segment's end (ADR-0019 refinement). The oldest `hop`
        // seconds of speech are committed by the horizon; a long sentence that
        // straddled the horizon "consumes" its full audio span so its tail
        // can't be re-committed as overlapping fragments next hop. Monotonic by
        // construction — windowStartSessionTime only increases as the window
        // slides, and we only ever take a max. Trade-off (accepted for v1): an
        // overlapping interjection that STARTS within a committed long span is
        // skipped. WhisperKit rarely emits clean overlapping segments, and a
        // dropped sub-second interjection beats re-covering a whole sentence.
        let advanceTo = max(commitHorizon, maxCommittedEnd)
        if advanceTo > committedUpTo {
            committedUpTo = advanceTo
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
            //
            // ADR-0019: also skip orphans whose region is already behind the
            // commit watermark. That span was finalized exactly once when it
            // aged past the horizon; a closing final here would re-emit
            // already-committed audio — the very duplicate this model removes.
            if p.tStart <= committedUpTo { continue }
            let orphanSeg = WindowSegment(
                tStart: p.tStart, tEnd: p.tEnd, text: p.lastText, language: nil
            )
            let spk = await provisionalSpeaker(forStart: p.tStart, end: p.tEnd)
            emitSegment(uid: p.id, isFinal: true, seg: orphanSeg, speaker: spk)
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
    ///
    /// `ledger`/`window`/`committedUpTo` are SNAPSHOTTED by the caller
    /// (`dispatchCaptureStop`) before it wipes session state — see the snapshot
    /// comment there. We must NOT read `self.ledger`/`self.window`/
    /// `self.committedUpTo` here: by the time this detached Task runs they are
    /// already nil/0, which is exactly why the drain (and the lost tail) never
    /// had a ledger to finalize.
    private func flushOnStop(sessionId: String, sessionStart: Date,
                             durationSec: Double, rtfAvg: Double,
                             ledger: UtteranceLedger?, window: SlidingWindowBuffer?,
                             committedUpTo: Double) async {
        // Snapshot + detach the full-session audio BEFORE the transcription
        // drain's `await` (which suspends this actor and could let a fresh
        // capture.start wipe the live buffer). The drain itself only appends
        // to `finalizedUtterances`, not to `sessionAudio`, so taking the audio
        // here is safe; we grab the finalized list after the drain.
        let capturedAudio = sessionAudio
        sessionAudio.removeAll(keepingCapacity: false)

        // The commit watermark is carried across the drain + hot-region
        // finalize as a local (the actor's `committedUpTo` was reset to 0 when
        // stop wiped session state). Both steps advance it.
        var committedUpTo = committedUpTo

        // Drain the live transcription buffer first (this emits the last
        // finals, populating `finalizedUtterances`), then run the offline
        // diarization pass to label each utterance "Speaker N", then write the
        // meeting to the vault + emit `meeting.saved`. Guarded end-to-end so it
        // can never break the capture/stop lifecycle.
        await flushTranscriptionDrain(ledger: ledger, window: window,
                                      committedUpTo: &committedUpTo)

        // ADR-0019 (CONTENT-LOSS FIX, 2nd attempt — DETERMINISTIC):
        //
        // The re-transcription drain above is FRAGILE: it depends on WhisperKit
        // re-producing the hot-region segments from the residual audio buffer,
        // and it has THREE early-return paths (no window/ledger, empty buffer,
        // transcribe error) that skip the tail entirely. On-device this dropped
        // the last ~30 s of every recording: that content was transcribed by the
        // REGULAR hops and shown as `segment.partial`, but its start was always
        // ahead of the commit horizon (never finalized live), then behind the
        // over-advanced watermark (skipped on later hops), and the drain never
        // re-finalized it.
        //
        // So finalize the hot region DETERMINISTICALLY from the ledger itself,
        // UNCONDITIONALLY (not inside the drain — outside it, so no drain
        // early-return can skip it): take every LIVE (non-finalized,
        // non-superseded) ledger entry whose t_start is above the watermark —
        // exactly the trailing partials the user saw, each carrying its
        // last-known text — and emit each as a `segment.final`. This captures
        // EVERYTHING above the watermark through end-of-audio regardless of what
        // the re-transcription leftover contained. Dedup/supersession backstops
        // still apply (the head-overlap guard here + `collapseReemissions` at
        // vault write). Runs BEFORE `dedupedFinalizedUtterances()` below, so the
        // recovered tail is in `finalizedUtterances` for the diarization +
        // vault-write pass.
        if let ledger = ledger {
            finalizeHotRegion(ledger, committedUpTo: &committedUpTo)
        }

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
    /// Stages:
    ///   0. Drop SUPERSEDED fragments (ADR-0018): a fragment retracted live via
    ///      `segment.superseded` must not survive into the written file. The live
    ///      UI deleted it on the wire frame; the writer filters the same ids here.
    ///   1. By `utterance_id`, last-write-wins. The final emit for a uid is the
    ///      most-complete text (text only ever grows/refines before lock), so
    ///      keeping the last occurrence mirrors the live feed's reconciliation.
    ///   2. Interval-based, TIME-GATED collapse of distinct-uid re-emissions.
    ///      The sliding window re-emits the SAME spoken sentence on successive
    ///      hops at t_start values 1–4 s apart; ADR-0009's max-denominator rule
    ///      mints a fresh uid for each (distinct ids, near-identical text), and
    ///      the conservative supersession gate (which requires the new text to
    ///      EXTEND the old, "not identical") deliberately lets identical copies
    ///      through. Stage 2 mops them up — but ONLY when their timing proves
    ///      re-emission, never on text alone (see `collapseReemissions`).
    ///
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
        let oncePerId = idOrder.compactMap { byId[$0] }

        // Stage 2: time-gated re-emission collapse, then sort by t_start.
        let collapsed = Self.collapseReemissions(oncePerId, windowSeconds: dedupWindowSeconds)
        return collapsed.sorted { $0.tStart < $1.tStart }
    }

    /// Default at-stop dedup time-gate (seconds). Two normalized-equal (or
    /// prefix/superset) utterances collapse when their [tStart,tEnd] intervals
    /// overlap OR their gap is below this. ~2.5 s covers the 1–4 s hop-to-hop
    /// re-emission drift observed on real conversational audio while staying
    /// well under the multi-second pause that separates a deliberate repeat.
    static let defaultDedupWindowSeconds: Double = 2.5
    /// Upper clamp for the env override. A window beyond this would start eating
    /// legitimately-repeated phrases, defeating the whole safety mechanism.
    static let maxDedupWindowSeconds: Double = 15.0

    /// Parse + clamp `HARK_DEDUP_WINDOW_SEC` and log the resolved value once at
    /// startup. Unset / unparseable → the default; a parsed value is clamped to
    /// [0, maxDedupWindowSeconds]. 0 disables the gap-window (overlap-only
    /// collapse still runs). Logged on stderr — value only, no transcript text.
    static func resolveDedupWindow(_ raw: String?) -> Double {
        let resolved: Double
        if let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
           let parsed = Double(raw) {
            resolved = min(maxDedupWindowSeconds, max(0.0, parsed))
            FileHandle.standardError.write(Data(String(
                format: "harkd: dedup window = %.2fs (from HARK_DEDUP_WINDOW_SEC=%@, clamped to [0,%.0f])\n",
                resolved, raw, maxDedupWindowSeconds).utf8))
        } else {
            resolved = defaultDedupWindowSeconds
            FileHandle.standardError.write(Data(String(
                format: "harkd: dedup window = %.2fs (default; set HARK_DEDUP_WINDOW_SEC to override)\n",
                resolved).utf8))
        }
        return resolved
    }

    // ─── Commit-watermark finalization decision (ADR-0019) ──────────────────

    /// What to do with one transcribed segment under the commit-watermark model.
    enum CommitDecision: Equatable {
        /// The segment's region has aged into the stable band and is not yet
        /// behind the watermark — finalize it ONCE.
        case finalize
        /// The segment is in the still-hot region (after the watermark, ahead
        /// of the horizon) — emit/refresh a `segment.partial`.
        case partial
        /// The segment's region is already behind the watermark — it was
        /// finalized in a prior hop. Do nothing (no re-emit). This is the guard
        /// that eliminates duplicate finals.
        case skipAlreadyCommitted
    }

    /// PURE region-commit decision (ADR-0019). Given a segment's absolute
    /// `segmentStart` (session-relative seconds), the current `committedUpTo`
    /// watermark, and this hop's `commitHorizon`:
    ///
    ///   - `committedUpTo < start <= commitHorizon` → `.finalize` (commit once;
    ///     `committedUpTo < start` is the exactly-once guard, `start <= horizon`
    ///     is the straddle rule — a segment is committed when its START is).
    ///   - `start > commitHorizon` (and necessarily `> committedUpTo` since the
    ///     watermark never passes the horizon) → `.partial` (still hot).
    ///   - `start <= committedUpTo` → `.skipAlreadyCommitted`.
    ///
    /// No actor state, no I/O — unit-tested in CommitWatermarkTests so the live
    /// loop and the tests share one definition of "finalize this region once."
    static func commitDecision(segmentStart start: Double,
                               committedUpTo: Double,
                               commitHorizon: Double) -> CommitDecision {
        if start <= committedUpTo { return .skipAlreadyCommitted }
        if start <= commitHorizon { return .finalize }
        return .partial
    }

    /// TIME-GATED collapse of re-emitted utterances. Input is already deduped by
    /// utterance_id (stage 1); this collapses DISTINCT-uid rows that are really
    /// the same speech re-decoded on successive sliding-window hops.
    ///
    /// Rule (per group of normalized-equal text, plus a prefix/superset pass):
    ///   - Two utterances are "linked" (the same re-emitted speech) when their
    ///     [tStart, tEnd] intervals OVERLAP, OR the GAP between them is
    ///     < `windowSeconds`. Gap = the gap between the intervals (0 if they
    ///     touch/overlap); for two points it's |tStart − tStart|.
    ///   - Linking is TRANSITIVE within a group: a chain of close copies
    ///     (A~B~C) collapses to ONE. But links only form across copies within
    ///     the window — copies separated by more than the window stay separate
    ///     clusters, so a genuinely-repeated phrase survives (the HARD rule).
    ///   - The kept representative of a cluster is the LONGEST text (most
    ///     complete); ties → earliest tStart.
    ///
    /// Two matching passes, both behind the SAME time gate:
    ///   (a) normalized-equality groups — the dominant re-emission case;
    ///   (b) prefix/superset — one normalized text is a prefix of another
    ///       (mops up residual prefix variants the supersession path didn't
    ///       catch). NO fuzzy / edit-distance matching — too risky.
    ///
    /// When in doubt this DOES NOT collapse: a leftover duplicate is a lesser
    /// evil than deleting real content. Pure function — no actor state, no I/O.
    static func collapseReemissions(_ utterances: [FinalizedUtterance],
                                    windowSeconds: Double) -> [FinalizedUtterance] {
        let n = utterances.count
        if n < 2 { return utterances }

        let norms = utterances.map { normalizeForDedup($0.text) }

        // Union-Find over the utterances. We union i,j when they are the same
        // re-emitted speech: time-linked AND (normalized-equal OR one norm is a
        // prefix of the other). O(n²) link scan — n is small per meeting (tens
        // to low hundreds of finals), and this runs once at stop, off the live
        // path. See class doc note on UtteranceLedger's linear scan.
        var parent = Array(0..<n)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }
            return r
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        for i in 0..<n {
            let ni = norms[i]
            if ni.isEmpty { continue }
            for j in (i + 1)..<n {
                let nj = norms[j]
                if nj.isEmpty { continue }
                // Text gate: identical, OR one is a prefix of the other.
                let textLinked = ni == nj || ni.hasPrefix(nj) || nj.hasPrefix(ni)
                guard textLinked else { continue }
                // Time gate — the entire safety mechanism. Overlap OR small gap.
                guard timeLinked(utterances[i], utterances[j], windowSeconds: windowSeconds) else { continue }
                union(i, j)
            }
        }

        // Pick one representative per cluster: longest text, ties → earliest start.
        var repForRoot: [Int: Int] = [:]
        for i in 0..<n {
            let root = find(i)
            if let cur = repForRoot[root] {
                if isBetterRepresentative(utterances[i], than: utterances[cur]) {
                    repForRoot[root] = i
                }
            } else {
                repForRoot[root] = i
            }
        }

        // Emit one row per cluster, preserving first-seen order of clusters so
        // the (later, unconditional) sort has a stable input.
        var emitted = Set<Int>()
        var out: [FinalizedUtterance] = []
        out.reserveCapacity(repForRoot.count)
        for i in 0..<n {
            let root = find(i)
            if emitted.insert(root).inserted, let rep = repForRoot[root] {
                out.append(utterances[rep])
            }
        }
        return out
    }

    /// True when two utterances' intervals overlap OR their gap is below the
    /// window. Gap is clamped at 0 for overlapping/touching intervals. This is
    /// the time gate that protects genuine repeats: identical text spoken far
    /// apart (non-overlapping AND gap >= window) is NOT linked.
    private static func timeLinked(_ a: FinalizedUtterance, _ b: FinalizedUtterance,
                                   windowSeconds: Double) -> Bool {
        let overlap = min(a.tEnd, b.tEnd) - max(a.tStart, b.tStart)
        if overlap >= 0 { return true }  // intervals overlap or touch
        let gap = -overlap                // strictly positive separation
        return gap < windowSeconds
    }

    /// The kept representative is the LONGEST text (most complete); ties resolve
    /// to the earliest tStart. Length is on the RAW text (what gets written),
    /// not the normalized form.
    private static func isBetterRepresentative(_ candidate: FinalizedUtterance,
                                               than current: FinalizedUtterance) -> Bool {
        let cLen = candidate.text.count, curLen = current.text.count
        if cLen != curLen { return cLen > curLen }
        return candidate.tStart < current.tStart
    }

    // ─── Post-save speaker rename (pure relabel) ────────────────────────────

    /// Apply a `currentLabel -> newName` map to a set of labeled utterances and
    /// rebuild the attendee roster. PURE — no actor state, no I/O — so the live
    /// rename path and its regression tests share one definition.
    ///
    ///   - Each utterance whose `label` is a key in `names` is relabeled to the
    ///     mapped name; unmatched utterances keep their existing label (so an
    ///     un-renamed "Speaker N" stays "Speaker N"). Text + tStart are untouched.
    ///   - `attendees` is rebuilt as the DISTINCT labels in first-APPEARANCE order
    ///     across the (already time-ordered) utterances, AFTER mapping — so the
    ///     roster reads in speaking order using the new names.
    ///
    /// Idempotent for the snapshot-update path: feeding the result back in with a
    /// map keyed by the NOW-current names renames again from where it left off
    /// (the second-rename case). An empty `names` is a no-op relabel that still
    /// rebuilds a correct roster.
    static func applySpeakerNames(
        to utterances: [VaultWriter.Utterance],
        names: [String: String]
    ) -> (utterances: [VaultWriter.Utterance], attendees: [String]) {
        var relabeled: [VaultWriter.Utterance] = []
        relabeled.reserveCapacity(utterances.count)
        var attendees: [String] = []
        var seen = Set<String>()
        for u in utterances {
            let newLabel = names[u.label] ?? u.label
            relabeled.append(VaultWriter.Utterance(tStart: u.tStart, label: newLabel, text: u.text))
            if seen.insert(newLabel).inserted {
                attendees.append(newLabel)
            }
        }
        return (relabeled, attendees)
    }

    // ─── meeting.transcript mapping (labeled vault set → wire) ──────────────

    /// Map the labeled, deduped vault utterances to `meeting.transcript`'s wire
    /// rows. PURE — no actor state, no I/O — so the emit path and its test share
    /// one definition. Input is the EXACT `[VaultWriter.Utterance]` written to the
    /// markdown body (`tStart` + `label` + `text`); we mint an index-based stable
    /// `id` ("u0", "u1"…) for the UI's `@for` track and carry the "Speaker N"
    /// `label` through as `speaker`. Order is preserved (the input is already
    /// t_start-ordered), so the ids index that same chronological order.
    static func transcriptUtterances(
        from labeled: [VaultWriter.Utterance]
    ) -> [TranscriptUtterance] {
        labeled.enumerated().map { idx, u in
            TranscriptUtterance(id: "u\(idx)", tStart: u.tStart, text: u.text, speaker: u.label)
        }
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

        // Retain the snapshot so a post-save `speaker.rename` can re-render THIS
        // file with the user's display names (see SavedMeetingSnapshot). Captured
        // only on a successful write — we never offer to rename a file we didn't
        // write. Overwrites any prior meeting's snapshot: MVP renames the single
        // most-recent meeting only.
        lastSavedMeeting = SavedMeetingSnapshot(
            sessionId: sessionId,
            vaultPath: result.fileURL,
            sessionStart: sessionStart,
            durationSec: durationSec,
            rtfAvg: rtfAvg,
            segmentCount: segmentCount,
            labeled: labeled,
            attendees: attendees)

        // Emit `meeting.transcript` JUST BEFORE `meeting.saved`, built from the
        // SAME `labeled` set we just wrote to the vault — so the UI can back-
        // annotate the on-screen transcript (live `segment.final` shipped
        // `speaker: nil`) with the identical "Speaker N" labels the markdown body
        // carries, BEFORE the roster/card arrive. Same `sessionId` scopes the
        // replacement. Reuses the deduped/labeled vault utterances verbatim — it
        // does NOT re-derive a different set, so on-screen == saved file.
        broadcast(WireEnvelope(type: "meeting.transcript", payload: MeetingTranscriptPayload(
            sessionId: sessionId,
            utterances: Self.transcriptUtterances(from: labeled))))

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

    /// `ledger`/`window`/`committedUpTo` are passed in (snapshotted by
    /// `dispatchCaptureStop` before session wipe) — NOT read from `self`, which
    /// is already nil/0 by the time this detached Task runs. See `flushOnStop`.
    private func flushTranscriptionDrain(ledger: UtteranceLedger?,
                                         window: SlidingWindowBuffer?,
                                         committedUpTo: inout Double) async {
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

        // ADR-0019 (CONTENT-LOSS FIX): finalize the ENTIRE remaining hot region
        // — every segment in the buffer that was NOT already committed live —
        // through the end of captured audio. Map the drain buffer's
        // window-relative segment times back to absolute session time (the drain
        // doesn't go through `popHopIfReady`, so we read the anchor directly).
        //
        // We must NOT gate on the commit watermark here. The watermark
        // (`committedUpTo`) can advance PAST hot-region content WITHOUT
        // finalizing it: when a long sentence straddles the commit horizon it is
        // finalized with its full span and the watermark jumps to its `tEnd` (the
        // straddle refinement above), even though later overlapping speech in
        // that span was only ever emitted as `segment.partial`. A
        // `tStart <= committedUpTo → skip` gate would then drop that whole tail
        // — the verified bug (last ~30 s of every recording lost).
        //
        // Instead we gate on what was ACTUALLY finalized: skip a drained segment
        // only when its region substantially overlaps an already-finalized ledger
        // entry (the committed head). Everything else is hot-region content that
        // was shown live as a partial and never finalized — finalize it now. The
        // ledger's `isFinalized` (on the resolved id) is the within-drain dedup
        // backstop, and `collapseReemissions` at vault write mops up residual
        // near-duplicates; the watermark still advances to the tail end below so
        // the post-stop bookkeeping stays consistent.
        let windowStart = window.currentWindowStartSessionTime
        var tailEnd = committedUpTo
        for r in results {
            for s in r.segments {
                let cleaned = stripWhisperSpecials(s.text).trimmingCharacters(in: .whitespaces)
                if cleaned.isEmpty { continue }
                // Absolute session time when we have anchors; fall back to the
                // raw window-relative offset only if the anchor table is gone.
                let tStart: Double
                let tEnd: Double
                if let ws = windowStart {
                    tStart = window.windowTimeToSessionTime(
                        windowOffsetSeconds: Double(s.start), windowStartSessionTime: ws)
                    tEnd = window.windowTimeToSessionTime(
                        windowOffsetSeconds: Double(s.end), windowStartSessionTime: ws)
                } else {
                    tStart = Double(s.start)
                    tEnd = Double(s.end)
                }
                // Skip the already-committed HEAD: a region that substantially
                // overlaps an entry we genuinely finalized live. This is the
                // watermark-immune "already committed?" test — see
                // `UtteranceLedger.overlapsFinalized`. Hot-region partials are
                // NOT finalized entries, so they pass through and get committed.
                if ledger.overlapsFinalized(tStart: tStart, tEnd: tEnd) { continue }
                let uid = ledger.resolve(tStart: tStart, tEnd: tEnd, text: cleaned)
                if ledger.isFinalized(utteranceId: uid) { continue }
                ledger.markFinalized(utteranceId: uid)
                emitSegment(uid: uid, isFinal: true, seg: WindowSegment(
                    tStart: tStart, tEnd: tEnd, text: cleaned, language: language
                ))
                tailEnd = max(tailEnd, tEnd)
            }
        }
        // Everything up to the end of the drained tail is now committed.
        committedUpTo = max(committedUpTo, tailEnd)
        // The drain pass can itself supersede earlier fragments (it re-decodes
        // the whole tail buffer). Broadcast those before stop completes so the
        // live UI and the retention filter both see them. See ADR-0018.
        drainAndEmitSupersessions(ledger)
    }

    /// At-stop hot-region finalize (ADR-0019 content-loss fix). Enumerates the
    /// ledger's LIVE entries above the commit watermark — the trailing partials
    /// the user saw but the live loop never finalized — and emits each as a
    /// `segment.final`, marking it finalized and advancing `committedUpTo` to the
    /// max t_end. Deterministic: it reads the ledger's stored text directly, it
    /// does NOT re-transcribe.
    ///
    /// The actual decision (which entries, in what order, new watermark) is the
    /// PURE `hotRegionFinalizeDecision` below — the SAME function the unit tests
    /// drive, so the live path and the regression tests share one definition. We
    /// only do the emission + ledger mutation here. `committedUpTo` is the
    /// caller's local watermark (the actor's was reset at stop); we advance it.
    private func finalizeHotRegion(_ ledger: UtteranceLedger, committedUpTo: inout Double) {
        let live = ledger.liveEntriesAbove(committedUpTo)
        let decision = Self.hotRegionFinalizeDecision(
            liveEntries: live, committedUpTo: committedUpTo)

        for entry in decision.toFinalize {
            // Dedup backstop: never re-emit a region that substantially overlaps
            // something we genuinely finalized live (the committed head). Mirrors
            // the drain's head guard so a straddle sentence's region isn't
            // double-written. Hot-region partials are NOT finalized entries, so
            // they pass through. Cheap (linear, off the live path).
            if ledger.overlapsFinalized(tStart: entry.tStart, tEnd: entry.tEnd) { continue }
            if ledger.isFinalized(utteranceId: entry.id) { continue }
            ledger.markFinalized(utteranceId: entry.id)
            emitSegment(uid: entry.id, isFinal: true, seg: WindowSegment(
                tStart: entry.tStart, tEnd: entry.tEnd, text: entry.lastText, language: nil))
        }
        if decision.advanceTo > committedUpTo {
            committedUpTo = decision.advanceTo
        }

        // Diagnostic (state only, no transcript text): lets an on-device run
        // confirm the tail was captured — N>0 and Y≈Z≈duration.
        FileHandle.standardError.write(Data(String(
            format: "harkd: stop finalized %d hot-region utterances (committedUpTo %.1fs -> %.1fs, audio end %.1fs)\n",
            decision.toFinalize.count,
            decision.committedUpToBefore,
            committedUpTo,
            decision.audioEnd
        ).utf8))
    }

    /// The PURE hot-region-finalize decision (ADR-0019 content-loss fix).
    /// Given the ledger's LIVE entries above the watermark (already filtered to
    /// non-finalized, non-superseded, non-empty, t_start-ascending by
    /// `liveEntriesAbove`) and the current `committedUpTo`, decide:
    ///   - which entries to finalize (ALL of them — they're the trailing
    ///     partials never promoted to final), in t_start order;
    ///   - the new watermark = max(committedUpTo, max entry t_end);
    ///   - the audio end (max t_end across the live set), for the diagnostic.
    ///
    /// No actor state, no I/O, no re-transcription — unit-tested in
    /// CommitWatermarkTests by driving the REAL `UtteranceLedger`, so the live
    /// stop path and the regression test share one definition of "finalize the
    /// hot region the user saw."
    struct HotRegionFinalizeDecision: Equatable {
        let toFinalize: [UtteranceLedger.LiveEntry]
        let committedUpToBefore: Double
        let advanceTo: Double
        let audioEnd: Double
    }

    static func hotRegionFinalizeDecision(
        liveEntries: [UtteranceLedger.LiveEntry],
        committedUpTo: Double
    ) -> HotRegionFinalizeDecision {
        var maxEnd = committedUpTo
        for e in liveEntries { maxEnd = max(maxEnd, e.tEnd) }
        return HotRegionFinalizeDecision(
            toFinalize: liveEntries,
            committedUpToBefore: committedUpTo,
            advanceTo: max(committedUpTo, maxEnd),
            audioEnd: maxEnd)
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

    /// `speaker` is the PROVISIONAL live label ("Speaker A/B/…") when the
    /// session opted into live diarization and the timeline has caught up to
    /// this segment's span; nil otherwise (the default, and for stop-path emits
    /// that `meeting.transcript` replaces within ~1s anyway). It is purely a
    /// display hint — it does NOT affect the offline pass, which always replaces
    /// it with the authoritative "Speaker 1/2/…" labels at stop. We deliberately
    /// do NOT persist the provisional label into `finalizedUtterances`: the
    /// vault write uses the offline labels exclusively.
    private func emitSegment(uid: String, isFinal: Bool, seg: WindowSegment, speaker: String? = nil) {
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
            speaker: speaker,    // provisional live label, or nil (Phase 5 stop pass refines)
            translation: nil     // Phase 6
        )
        let env = WireEnvelope(type: isFinal ? "segment.final" : "segment.partial",
                               payload: payload)
        broadcast(env)
    }

    /// Resolve the provisional live speaker label for a segment's span, or nil
    /// when live diarization is off or the timeline hasn't caught up yet. Awaits
    /// the LiveDiarizer actor — only ever called from the async transcription
    /// path, never the audio hot path.
    private func provisionalSpeaker(forStart start: Double, end: Double) async -> String? {
        guard let live = liveDiarizer else { return nil }
        return await live.provisionalSpeaker(forStart: start, end: end)
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

// ─── At-stop dedup model + text normalization ────────────────────────────
//
// `FinalizedUtterance` is the in-RAM record of a `segment.final` emit, retained
// for the post-stop diarization + vault write (timing for overlap-labelling,
// text for the markdown body). File-scope (not actor-private) so the pure dedup
// logic in `EngineSession.collapseReemissions` can be unit-tested without an
// actor. The text lives ONLY here during a session and is written ONLY to the
// vault at stop — never logged, never sent anywhere else (hard rule #2).

struct FinalizedUtterance {
    let utteranceId: String
    let tStart: Double
    let tEnd: Double
    let text: String
}

/// Normalize text for the at-stop dedup text gate: lowercase, trim, collapse
/// internal whitespace, and strip punctuation/symbols (letters/digits/space
/// survive). Same semantics as `UtteranceLedger.normalize` — kept separate
/// because that one is `private` to the ledger; Phase 4+ should hoist both into
/// HarkCore. This makes "We're getting there." and "We're getting there"
/// (trailing-punctuation jitter across hops) compare equal, while genuine
/// number-format mismatches like "10 years" vs "Ten years" correctly do NOT
/// match — left alone on purpose (no fuzzy matching, per the dedup contract).
func normalizeForDedup(_ s: String) -> String {
    let lowered = s.lowercased()
    var out = String.UnicodeScalarView()
    var lastWasSpace = false
    for scalar in lowered.unicodeScalars {
        if CharacterSet.whitespacesAndNewlines.contains(scalar) {
            if !lastWasSpace && !out.isEmpty {
                out.append(" ")
                lastWasSpace = true
            }
        } else if CharacterSet.alphanumerics.contains(scalar) {
            out.append(scalar)
            lastWasSpace = false
        }
        // else: punctuation/symbol → drop, don't reset lastWasSpace.
    }
    var result = String(out)
    if result.hasSuffix(" ") { result.removeLast() }
    return result
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
