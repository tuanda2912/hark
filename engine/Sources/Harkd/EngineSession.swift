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

    /// Speaker-enrollment store + matcher (Phase 5.1, ADR-0026). Stores a
    /// voiceprint when the user names a speaker post-stop and auto-recognizes
    /// known voices in future meetings. `nil`-tolerant in spirit — a load/match
    /// failure NEVER blocks the diarization pass or the vault write (speakers
    /// just stay "Speaker N"). Threshold resolved once at init from
    /// `HARK_ENROLL_THRESHOLD` (clamped, logged) so it can be swept on-device
    /// without recompiling. See `SpeakerStore`.
    private let speakerStore: SpeakerStore

    /// Opt-in meeting-audio store (slice B, ADR-0027). Persists the full-meeting
    /// 16 kHz mono PCM to `vault/.audio/<meeting-id>.wav` — but ONLY when the
    /// session's `keepAudio` gate is on. When off there is ZERO `.audio/` I/O.
    /// Same nil-tolerant, off-the-live-path spirit as `speakerStore`: an audio
    /// write failure NEVER blocks the vault `.md` write or the stop lifecycle.
    private let audioStore: AudioStore

    /// Offline speaker diarizer (Phase 5, ADR-0016). Wraps FluidAudio's
    /// `OfflineDiarizerManager` (VBx global clustering, overlapping windows,
    /// exclusive segments). nil until the models finish loading; nil-tolerant
    /// everywhere — a missing/failed diarizer NEVER blocks capture or stop.
    /// Used only by the post-stop pass.
    private var diarizer: Diarizer?

    /// Vault-RAG index coordinator (Phase 6 slice 4b, ADR-0032/0033). nil until the
    /// embedder + index finish loading; nil-tolerant — a missing indexer degrades
    /// ONLY `rag.retrieve` (→ RAG_UNAVAILABLE) and never blocks capture/transcription.
    /// Indexing runs entirely in the background inside this actor; the live audio
    /// path never touches it.
    private var ragIndexer: RagIndexer?

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

    /// Live translation → English (BACKLOG translation §2). When true, BOTH
    /// transcribe paths (live hops + the flush-on-stop drain) run WhisperKit with
    /// `task: .translate`, which emits ENGLISH text for any source language —
    /// Whisper's only translation target (other live targets are §3, not built).
    /// Set from `capture.start`'s `translation.enabled`; on-device, ZERO egress
    /// (same local model, different decode task). `sessionLanguage` still passes
    /// the SOURCE-language hint. Reset on stop, like `sessionLanguage`.
    private var liveTranslateToEnglish = false

    /// Privacy gates for THIS session (ADR-0027). Both default false = privacy-
    /// safe; set from `capture.start` (absent ⇒ false). Retained for the meeting's
    /// whole lifetime — `rememberSpeakers` is read by the enroll-on-rename path
    /// (which can fire AFTER stop, off the session-state wipe) and by the post-stop
    /// auto-match, so it deliberately survives `dispatchCaptureStop` alongside
    /// `lastSavedMeeting` rather than being cleared with the session-scoped fields.
    ///
    /// `rememberSpeakers` is the LOAD-BEARING gate: when false there is ZERO
    /// `.speakers/` I/O — enroll is skipped, auto-match is skipped. `keepAudio`
    /// is plumbing only for now (see the TODO in `flushOnStop`).
    private var rememberSpeakers: Bool = false
    private var keepAudio: Bool = false

    /// Commit watermark (ADR-0019): the session-relative audio time (seconds
    /// since capture start) up to which we have ALREADY finalized. Monotonic,
    /// starts at 0. Each hop finalizes the segments whose `t_start` lies in
    /// `(committedUpTo, commitHorizon]` exactly once, then advances this to the
    /// horizon. Audio at/before this is NEVER re-finalized — that is what kills
    /// the duplicate `segment.final` frames the old older-zone rule produced.
    /// Reset to 0 per capture.start. The hot region (`t_start > committedUpTo`)
    /// still flows partials with ADR-0009-stable utterance_ids, unchanged.
    private var committedUpTo: Double = 0

    // ─── Offline diarization buffer — spilled to temp WAV (Phase 5, ADR-0039) ──
    //
    // The post-stop diarization pass needs the CONTINUOUS full-meeting recording
    // — every mixed frame batch INCLUDING silence — so its sample timeline maps
    // 1:1 to the wall-clock session time the segments are emitted against (that
    // shared time axis is what makes the time-overlap speaker assignment correct).
    // Unlike `SlidingWindowBuffer` (speech-only, trimmed to 30 s) this is the
    // whole meeting.
    //
    // ADR-0016 §5 originally held this in a live `[Float]` — but that grew
    // ~3.75 MiB/min (with transient ~2× spikes during array-doubling) and pushed
    // long meetings into swap. ADR-0039 replaced it with a STREAMING spill: frames
    // are appended to a temp WAV under `~/Library/Application Support/Hark/tmp/`
    // as they arrive (flat in-RAM footprint), and the whole buffer is read back
    // ONCE, transiently, at stop to feed the diarizer + the opt-in keep-audio
    // path. Created per session in `startCapture` (only when a diarizer is
    // attached — else the buffer would be wasted), finalized + read + secure-
    // deleted in `flushOnStop`, and secure-deleted on abnormal teardown / deinit.
    private var audioSpill: SessionAudioSpill?

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
    /// Idle-flush hop timing (perf/live-caption-latency). `lastLiveHopAt` is the
    /// session-relative wall time (seconds) of the last transcription dispatch;
    /// a partial-only idle-flush fires when `liveHopMinInterval` has elapsed with
    /// speech still pending, so a short utterance before a pause captions in
    /// ~1.5 s instead of waiting for a full 5 s of speech to accumulate. Cheap
    /// now that temperature fallback is off (RTF ~0.13). `-1` = "flush eagerly".
    private var lastLiveHopAt: Double = -1
    private let liveHopMinInterval: Double = 1.5
    /// Minimum NEW speech (seconds) that must accumulate before an idle-flush
    /// fires. Guards against transcribing a near-silent window built from a thin
    /// VAD false-positive sliver — WhisperKit hallucinates sound-effect tags
    /// ("*crickets*", "[BLANK_AUDIO]") on such windows, and with temperature
    /// fallback off those low-confidence decodes aren't suppressed. 1 s keeps the
    /// latency win (fires ~1 s after real speech) while cutting the hallucinations.
    private let liveHopMinSpeechSeconds: Double = 1.0
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
        // Phase 5.1 enrollment (ADR-0026): the per-LABEL ("Speaker N") L2-normalized
        // diarizer centroid + total spoken duration, captured in runDiarizationPass.
        // The DiarizationResult is discarded by the time dispatchSpeakerRename
        // fires, so we retain just what enrollment needs — the voiceprint to store
        // + the duration to gate on (don't enroll a noisy tiny cluster). Keyed by
        // the label as it appears in `labeled` (an auto-matched speaker's label is
        // already the enrolled NAME, so it won't appear here — that's intended: we
        // only enroll on a deliberate user rename of an anonymous "Speaker N").
        let centroidForLabel: [String: [Float]]
        let durationForLabel: [String: Double]
    }
    private var lastSavedMeeting: SavedMeetingSnapshot?

    init(server: HarkdWebSocketServer) {
        self.server = server
        self.dedupWindowSeconds = EngineSession.resolveDedupWindow(
            ProcessInfo.processInfo.environment["HARK_DEDUP_WINDOW_SEC"])
        // Resolve + log the enrollment match threshold once at startup, same
        // shape as the dedup window + the HARK_DIAR_* config line (ADR-0026).
        let enrollThreshold = SpeakerStore.resolveThreshold(
            ProcessInfo.processInfo.environment["HARK_ENROLL_THRESHOLD"])
        self.speakerStore = SpeakerStore(threshold: enrollThreshold)
        self.audioStore = AudioStore()
    }

    /// Abnormal-teardown safety net (ADR-0039, hard rule #2): if the session is
    /// deallocated while an audio spill is still open — an error path or a shutdown
    /// that never reached a clean `capture.stop` — secure-delete it so raw meeting
    /// audio never lingers on disk. A clean stop already secure-deletes the spill
    /// in `flushOnStop` and nils this, so this is a no-op on the normal path.
    /// `deinit` is `nonisolated`, and `secureDelete` touches only the file (no
    /// actor state), so calling it here is safe.
    deinit {
        audioSpill?.secureDelete()
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

    /// Inject the vault-RAG indexer once the embedder + index are ready (slice 4b).
    /// Optional capability: capture/transcription work whether or not this is ever
    /// attached. The indexer is created with a status sink that hops back here to
    /// broadcast `rag.index_status`, so attaching it is all the session needs.
    func attachRagIndexer(_ indexer: RagIndexer) {
        self.ragIndexer = indexer
    }

    /// Broadcast a `rag.index_status` frame (slice 4b). Called from the indexer's
    /// `@Sendable` status sink via a `Task { await session.emitRagIndexStatus(...) }`
    /// hop — the SAME actor-hop pattern `emitModelProgress` uses. Additive, fire-
    /// and-forget: it never gates readiness or capture.
    func emitRagIndexStatus(state: String, indexedCount: Int, total: Int?) {
        broadcast(WireEnvelope(type: "rag.index_status", payload: RagIndexStatusPayload(
            state: state, indexedCount: indexedCount, total: total)))
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
            // runtime rather than removing the capability. NOTE: end-of-meeting
            // transcript translation exists, but it's generated in Electron main
            // (the egress chokepoint) and the engine only PERSISTS it
            // (translation.write); LIVE in-meeting translation isn't built, so no
            // "translation" capability is advertised — keep this honest.
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
        case "summary.write":
            dispatchSummaryWrite(client, id: header.id, data: data)
        case "translation.write":
            dispatchTranslationWrite(client, id: header.id, data: data)
        case "rag.retrieve":
            await dispatchRagRetrieve(client, id: header.id, data: data)
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
        // Live translation (BACKLOG translation §2): `translation.enabled` ⇒ run
        // the live transcribe with WhisperKit `task: .translate`, which outputs
        // ENGLISH for any source language (Whisper's only translation target;
        // other live targets are §3, not built). On-device, zero egress. `mode`
        // and `target_lang` are reserved for §3 — for §2, enabled means → English.
        let liveTranslateToEnglish = (cmd.translation?.enabled == true)
        if liveTranslateToEnglish {
            FileHandle.standardError.write(Data(
                "harkd: live translation → English enabled (task=.translate)\n".utf8))
        }

        let captureMic = cmd.sources?.mic ?? true
        let captureSystem = cmd.sources?.system ?? true
        // Normalize "auto" / empty to nil so callers can pass either form.
        let language: String? = {
            guard let raw = cmd.language?.trimmingCharacters(in: .whitespaces).lowercased(),
                  !raw.isEmpty, raw != "auto" else { return nil }
            return raw
        }()
        // Privacy gates (ADR-0027): absent ⇒ false = privacy-safe. The coalesce
        // here is the single point where "absent" becomes "off" — there is no
        // other default. Both are threaded into the session via `startCapture`.
        let keepAudio = cmd.keepAudio ?? false
        let rememberSpeakers = cmd.rememberSpeakers ?? false

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
                             keepAudio: keepAudio,
                             rememberSpeakers: rememberSpeakers,
                             liveTranslateToEnglish: liveTranslateToEnglish)
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
        self.liveTranslateToEnglish = false
        self.committedUpTo = 0
        self.rtfSum = 0
        self.rtfSamples = 0
        // NOTE: `finalizedUtterances`, `audioSpill`, and `supersededIds` are
        // NOT cleared here — the flush Task (which runs later on the actor)
        // still needs them for the diarization pass + vault write. The spill is
        // finalized, read back, and secure-deleted inside `flushOnStop`; the
        // other two are cleared there after they've been consumed.
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

        // Phase 5.1 enrollment (ADR-0026): naming a speaker is the deliberate
        // enroll trigger. For each "Speaker N" → name in the rename map, store the
        // retained centroid as a voiceprint so this voice is auto-recognized next
        // time. Gated on a minimum spoken duration (don't enroll a noisy tiny
        // cluster) and on having a retained centroid (an auto-matched speaker
        // carries no ordinal centroid — see runDiarizationPass — so re-tagging a
        // wrong auto-match is a vault relabel only; correcting the voiceprint is a
        // follow-up). OFF the live path; never blocks the ack. Privacy: enroll
        // never logs the name or vector (it logs nothing); we log the count here.
        enrollFromRename(names: cmd.names, snapshot: snapshot)

        sendAck(client, id: id)
    }

    /// Enroll voiceprints for the speakers named in a `speaker.rename` (ADR-0026).
    /// Reads the retained per-label centroid + duration from the meeting snapshot
    /// (captured in `runDiarizationPass`); for each `currentLabel → newName` with a
    /// centroid and ≥ `enrollMinDurationSec` of speech, calls `speakerStore.enroll`.
    /// Best-effort: a store write failure is swallowed inside the store (atomic
    /// write, `try?`), and this never throws or blocks the rename ack. Privacy:
    /// logs a COUNT only — never a name or vector.
    private func enrollFromRename(names: [String: String], snapshot: SavedMeetingSnapshot) {
        // PRIVACY GATE (ADR-0027): no voiceprint is EVER written when the session
        // opted out of remembering speakers. Returning here before touching
        // `speakerStore` means zero `.speakers/` writes on this path. Log a
        // COUNT only — never a name or vector (hard rule #3/#5).
        guard Self.voiceprintAccessAllowed(rememberSpeakers: rememberSpeakers) else {
            if !names.isEmpty {
                FileHandle.standardError.write(Data(String(
                    format: "harkd: enrollment skipped — remember_speakers off (%d name(s))\n",
                    names.count).utf8))
            }
            return
        }
        var enrolled = 0
        var skippedShort = 0
        for (currentLabel, newName) in names {
            guard let centroid = snapshot.centroidForLabel[currentLabel] else { continue }
            let duration = snapshot.durationForLabel[currentLabel] ?? 0
            guard duration >= Self.enrollMinDurationSec else {
                skippedShort += 1
                continue
            }
            if speakerStore.enroll(name: newName, centroid: centroid,
                                   meetingId: snapshot.sessionId, durationSec: duration) != nil {
                enrolled += 1
            }
        }
        if enrolled > 0 || skippedShort > 0 {
            FileHandle.standardError.write(Data(String(
                format: "harkd: enrollment — stored %d voiceprint(s), skipped %d (under %.0fs)\n",
                enrolled, skippedShort, Self.enrollMinDurationSec).utf8))
        }
    }

    /// Minimum total spoken duration (seconds) before a named speaker is enrolled.
    /// A 2-second cluster is too noisy for a trustworthy voiceprint (ADR-0026);
    /// ~4 s is enough for a stable WeSpeaker centroid without being burdensome.
    static let enrollMinDurationSec: Double = 4.0

    /// PURE privacy gate (ADR-0027): may the engine touch the `.speakers/` voice-
    /// print store this session? Both enroll-on-rename and post-stop auto-match
    /// consult this — when it returns false there is ZERO `.speakers/` I/O. Kept
    /// trivial + pure (no actor state, no I/O) so the test can assert the gate's
    /// semantics against the SAME definition production runs, the way
    /// `commitDecision` is shared by the live loop and CommitWatermarkTests.
    static func voiceprintAccessAllowed(rememberSpeakers: Bool) -> Bool {
        rememberSpeakers
    }

    // ─── Summary persistence (ADR-0031 §6) ──────────────────────────────────

    /// Persist a generated meeting summary into the most-recently-saved meeting's
    /// OWN vault markdown and git-commit it. The summary text is generated in the
    /// Electron main process (the cloud/local egress chokepoint, ADR-0029) and
    /// handed to the engine — the engine NEVER calls a model here; it only writes.
    /// Centralizing the vault write + git-commit in the one owner is the whole
    /// point (hard rule #4), exactly mirroring `speaker.rename`'s re-render.
    ///
    /// Same MVP scope + ack/error shape as `speaker.rename`: only the single most-
    /// recent meeting is writable (located by the retained `lastSavedMeeting`
    /// snapshot's `sessionId`); a plain `ack` on success, `MEETING_NOT_FOUND` when
    /// the session id doesn't match the retained meeting, `WRITE_FAILED` when the
    /// `.md` write itself fails. A failed git commit alone is NOT a failure — the
    /// `.md` is the durable artefact (VaultWriter's best-effort-commit semantics).
    private func dispatchSummaryWrite(_ client: WebSocketClient, id: String?, data: Data) {
        let cmd: SummaryWriteCommand
        do {
            cmd = try decodeInbound(data, payloadType: SummaryWriteCommand.self)
        } catch {
            sendError(client, id: id, code: "PROTOCOL_MISMATCH",
                      message: "bad summary.write payload", recoverable: false)
            return
        }

        // Reuse the SAME retained snapshot mechanism speaker.rename uses: only the
        // most-recently-saved meeting is summarizable, and only ITS file is touched
        // (hard rule #4 — never another file, never a new one).
        guard let snapshot = lastSavedMeeting, snapshot.sessionId == cmd.sessionId else {
            sendError(client, id: id, code: "MEETING_NOT_FOUND",
                      message: "can only write a summary for the most recently saved meeting",
                      recoverable: true)
            return
        }

        let writer = VaultWriter()
        let result: VaultWriter.Result
        do {
            result = try writer.appendSummary(
                to: snapshot.vaultPath,
                summary: cmd.summary,
                commitMessage: "docs(meeting): summary for \(snapshot.vaultPath.deletingPathExtension().lastPathComponent)")
        } catch {
            // The `.md` read-modify-write failed (read / atomic write). This is the
            // durable part — a failed write means the summary did NOT land, so it's
            // a hard error. (A failed git COMMIT alone is best-effort, surfaced as
            // committed=false below, NOT an error — same as the meeting write.)
            FileHandle.standardError.write(Data(
                "harkd: summary write failed (\(type(of: error))); file unchanged\n".utf8))
            sendError(client, id: id, code: "WRITE_FAILED",
                      message: "could not write the meeting summary to the vault", recoverable: true)
            return
        }

        // Privacy: log path + commit status only — never the summary text (rule #2/#3).
        FileHandle.standardError.write(Data(String(
            format: "harkd: summary written — %@  (committed=%@)\n",
            result.fileURL.path, result.committed ? "yes" : "no").utf8))

        sendAck(client, id: id)
    }

    // ─── Translation persistence (egress chokepoint, ADR-0029) ──────────────

    /// Persist a whole-transcript translation into the most-recently-saved meeting's
    /// OWN vault markdown under a `## Transcript — <lang>` section and git-commit it.
    /// The translation text is generated in the Electron main process (the cloud/local
    /// egress chokepoint, ADR-0029) and handed to the engine — the engine NEVER calls a
    /// model here; it only writes. Centralizing the vault write + git-commit in the one
    /// owner is the whole point (hard rule #4), exactly mirroring `summary.write`.
    ///
    /// A re-translate to the SAME `lang` replaces that section in place (idempotent); a
    /// DIFFERENT `lang` appends its own section, so multiple languages coexist — the
    /// merge is the PURE `VaultWriter.mergeTranslationSection`.
    ///
    /// TWO BODY SHAPES (exactly one per command):
    ///   - `lines` (PREFERRED, background post-meeting translation): per-utterance
    ///     translated text in the SAME ORDER as the retained `snapshot.labeled`. We zip
    ///     it with those utterances' label + tStart and re-render via the engine's own
    ///     `VaultWriter.renderTranscriptBody`, so the translated section is a STRUCTURAL
    ///     MIRROR of the original `## Transcript` (same labels, same wall-clock
    ///     timestamps, same blockquote format). The renderer supplied only text.
    ///   - `translation` (LEGACY, manual Translate panel): a pre-formatted blob written
    ///     verbatim — UNCHANGED behavior.
    /// NEITHER present → `PROTOCOL_MISMATCH`.
    ///
    /// Same MVP scope + ack/error shape as `summary.write`: only the single most-recent
    /// meeting is writable (located by the retained `lastSavedMeeting` snapshot's
    /// `sessionId`); a plain `ack` on success, `MEETING_NOT_FOUND` when the session id
    /// doesn't match the retained meeting, `WRITE_FAILED` when the `.md` write itself
    /// fails. A failed git commit alone is NOT a failure — the `.md` is the durable
    /// artefact (VaultWriter's best-effort-commit semantics).
    private func dispatchTranslationWrite(_ client: WebSocketClient, id: String?, data: Data) {
        let cmd: TranslationWriteCommand
        do {
            cmd = try decodeInbound(data, payloadType: TranslationWriteCommand.self)
        } catch {
            sendError(client, id: id, code: "PROTOCOL_MISMATCH",
                      message: "bad translation.write payload", recoverable: false)
            return
        }

        // Reuse the SAME retained snapshot mechanism summary.write uses: only the most-
        // recently-saved meeting is translatable, and only ITS file is touched
        // (hard rule #4 — never another file, never a new one).
        guard let snapshot = lastSavedMeeting, snapshot.sessionId == cmd.sessionId else {
            sendError(client, id: id, code: "MEETING_NOT_FOUND",
                      message: "can only write a translation for the most recently saved meeting",
                      recoverable: true)
            return
        }

        let slug = snapshot.vaultPath.deletingPathExtension().lastPathComponent
        let writer = VaultWriter()
        let result: VaultWriter.Result
        do {
            if let lines = cmd.lines {
                // STRUCTURED path (preferred): zip the per-utterance translated lines with
                // the engine's OWN retained `labeled` utterances (label + tStart) and render
                // via the shared `renderTranscriptBody` — so `## Transcript — <lang>` is a
                // structural mirror of the original `## Transcript` (same labels, same
                // wall-clock timestamps, same blockquote format). The renderer supplied only
                // the text; the engine owns all formatting.
                result = try writer.appendTranslationStructured(
                    to: snapshot.vaultPath,
                    lang: cmd.lang,
                    translatedLines: lines,
                    utterances: snapshot.labeled,
                    sessionStart: snapshot.sessionStart,
                    commitMessage: "docs(meeting): \(cmd.lang) translation for \(slug)")
            } else if let blob = cmd.translation {
                // LEGACY blob path (manual Translate panel): write the renderer-supplied
                // pre-formatted body verbatim — UNCHANGED behavior.
                result = try writer.appendTranslation(
                    to: snapshot.vaultPath,
                    lang: cmd.lang,
                    translation: blob,
                    commitMessage: "docs(meeting): \(cmd.lang) translation for \(slug)")
            } else {
                // Neither body shape present — malformed command.
                sendError(client, id: id, code: "PROTOCOL_MISMATCH",
                          message: "translation.write needs lines or translation", recoverable: false)
                return
            }
        } catch {
            // The `.md` read-modify-write failed (read / atomic write). This is the
            // durable part — a failed write means the translation did NOT land, so it's
            // a hard error. (A failed git COMMIT alone is best-effort, surfaced as
            // committed=false below, NOT an error — same as the meeting write.)
            FileHandle.standardError.write(Data(
                "harkd: translation write failed (\(type(of: error))); file unchanged\n".utf8))
            sendError(client, id: id, code: "WRITE_FAILED",
                      message: "could not write the meeting translation to the vault", recoverable: true)
            return
        }

        // Privacy: log path + commit status only — never the translation text (rule #2/#3).
        FileHandle.standardError.write(Data(String(
            format: "harkd: translation written — %@  (committed=%@)\n",
            result.fileURL.path, result.committed ? "yes" : "no").utf8))

        sendAck(client, id: id)
    }

    // ─── Vault RAG retrieval (Phase 6 slice 4b, ADR-0032/0033) ──────────────

    /// Top-K vault retrieval: decode → embed the query (`.query`) → cosine search →
    /// reply with `rag.results`. Mirrors the decode/dispatch/reply shape of the
    /// other handlers. The reply is correlated to the request `id` (like `ack`), so
    /// the UI can await a specific retrieve. Privacy: chunk text is returned ONLY
    /// to the local UI over loopback — never networked, never logged (rule #1/#2).
    ///
    /// Errors:
    ///   - PROTOCOL_MISMATCH — bad payload.
    ///   - RAG_UNAVAILABLE — the embedder/index isn't loaded (recoverable: the model
    ///     may still be warming up, or this build failed the embedder load — only
    ///     RAG is affected, the user can retry).
    private func dispatchRagRetrieve(_ client: WebSocketClient, id: String?, data: Data) async {
        let cmd: RagRetrieveCommand
        do {
            cmd = try decodeInbound(data, payloadType: RagRetrieveCommand.self)
        } catch {
            sendError(client, id: id, code: "PROTOCOL_MISMATCH",
                      message: "bad rag.retrieve payload", recoverable: false)
            return
        }

        guard let indexer = ragIndexer else {
            sendError(client, id: id, code: "RAG_UNAVAILABLE",
                      message: "vault search isn't ready yet (embedder still loading or unavailable)",
                      recoverable: true)
            return
        }

        let query = cmd.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            sendError(client, id: id, code: "PROTOCOL_MISMATCH",
                      message: "rag.retrieve query is empty", recoverable: true)
            return
        }
        // Clamp k to a sane band — a default of 8, never below 1, never above 50
        // (a UI asking for thousands would just waste the wire). The brute-force
        // search is fine at any k; this guards the payload size.
        let k = min(50, max(1, cmd.k ?? 8))

        // Offset-only (decision 2026-06-03): `retrieve` ranks the textless vector
        // index, then reads each hit's snippet LIVE from the vault at the stored
        // offsets, skipping any note that's been deleted or edited since indexing.
        // The wire shape below is UNCHANGED — only the SOURCE of `text` (vault read
        // vs persisted cache) changed.
        let hits: [RagRetrievedChunk]
        do {
            hits = try await indexer.retrieve(query: query, k: k)
        } catch RagIndexer.RagError.unavailable {
            sendError(client, id: id, code: "RAG_UNAVAILABLE",
                      message: "vault search isn't ready yet (embedder unavailable)",
                      recoverable: true)
            return
        } catch {
            sendError(client, id: id, code: "INTERNAL",
                      message: "vault search failed", recoverable: true)
            return
        }

        let chunks = hits.map { hit in
            RagResultChunk(
                text: hit.text,
                notePath: hit.notePath,
                headingPath: hit.headingPath,
                charStart: hit.charStart,
                charEnd: hit.charEnd,
                score: Double(hit.score))
        }
        // Privacy: log the COUNT only — never the query or the returned text.
        FileHandle.standardError.write(Data(String(
            format: "harkd: rag.retrieve k=%d → %d hit(s)\n", k, chunks.count).utf8))
        sendOnly(client, envelope: WireEnvelope(
            type: "rag.results", payload: RagResultsPayload(chunks: chunks), id: id))
    }

    // ─── Capture wiring ─────────────────────────────────────────────────

    private func startCapture(captureMic: Bool,
                              captureSystem: Bool,
                              language: String?,
                              keepAudio: Bool,
                              rememberSpeakers: Bool,
                              liveTranslateToEnglish: Bool) throws {
        self.sessionId = UUID().uuidString
        self.sessionStartDate = Date()
        self.captureWallStart = Date()
        self.sessionTimeSeconds = 0
        self.lastLiveHopAt = -1
        self.window = SlidingWindowBuffer(windowSeconds: 30, hopSeconds: 5, sampleRate: 16_000)
        self.ledger = UtteranceLedger()
        self.vad = EnergyVAD()
        self.sessionLanguage = language
        self.liveTranslateToEnglish = liveTranslateToEnglish
        // Retain the privacy gates for the meeting's lifetime (ADR-0027). These
        // deliberately persist past `dispatchCaptureStop`'s session-state wipe so
        // the enroll-on-rename path (which can fire after stop) reads the right
        // value. Logged value-only (no PII).
        self.keepAudio = keepAudio
        self.rememberSpeakers = rememberSpeakers
        FileHandle.standardError.write(Data(String(
            format: "harkd: privacy gates — keep_audio=%@  remember_speakers=%@\n",
            keepAudio ? "on" : "off", rememberSpeakers ? "on" : "off").utf8))
        self.committedUpTo = 0  // ADR-0019: nothing finalized yet this session.
        self.rtfSum = 0
        self.rtfSamples = 0

        // Open the offline-diarization audio spill for the new session (ADR-0039).
        // A stale spill from a prior stop should never survive, but secure-delete
        // any lingering handle defensively before opening a fresh one. We only open
        // the spill when a diarizer is attached — else the file would be wasted I/O
        // (the post-stop pass is the only consumer). A failed open is non-fatal:
        // `audioSpill` stays nil, diarization degrades to unlabeled, capture is
        // unaffected — same nil-tolerant spirit as the diarizer itself.
        self.audioSpill?.secureDelete()
        self.audioSpill = nil
        if diarizer != nil {
            do {
                self.audioSpill = try SessionAudioSpill()
            } catch {
                FileHandle.standardError.write(Data(
                    "harkd: audio spill open failed (\(type(of: error))); diarization will be skipped this session\n".utf8))
            }
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

        // STREAM the CONTINUOUS recording to the temp-WAV spill for the offline
        // diarization pass (Phase 5, ADR-0039). This runs on the actor's executor
        // — NOT the audio pump thread (the pump bounces here via
        // `Task { await ingestFrames }`), so the blocking file write never blocks
        // the audio callback. We append only when the spill exists (opened only
        // when a diarizer is attached) and only the raw mixed frames — pre-VAD —
        // so the sample timeline stays continuous and maps 1:1 to wall-clock
        // session time. A write error is non-fatal: log once, drop the spill, and
        // let this session fall back to unlabeled diarization (capture continues).
        if let spill = audioSpill {
            do {
                try spill.append(frames)
            } catch {
                FileHandle.standardError.write(Data(
                    "harkd: audio spill write failed (\(type(of: error))); diarization degraded this session\n".utf8))
                spill.secureDelete()
                audioSpill = nil
            }
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

        // Hop trigger. TWO ways to fire (perf/live-caption-latency):
        //   • NATURAL hop — a full `hopSeconds` of speech accumulated (ADR-0008
        //     quantum). This pass runs the full commit-watermark reconciliation
        //     and FINALIZES the aged-out region (ADR-0019).
        //   • IDLE-FLUSH hop — less than a full hop of speech, but `liveHopMinInterval`
        //     of wall-clock has elapsed with new speech pending. This pass emits
        //     PARTIALS ONLY for a low-latency live caption; finalization stays with
        //     the natural hop on its unchanged 5 s cadence, so the ADR-0019/0036
        //     finalization behaviour is untouched. Affordable because compute is
        //     cheap now that temperature fallback is off (RTF ~0.13).
        // Without the idle-flush, in a real meeting (~40 % speech duty cycle) a
        // transcription fires only every ~13 s of wall-clock, so a spoken line
        // waits 10–20 s — or never appears live and surfaces only at the at-stop
        // drain. See the perf/live-caption-latency measurement.
        var finalizeThisHop = true
        var popped = window.popHopIfReady()
        if popped == nil,
           window.pendingHopSeconds >= liveHopMinSpeechSeconds,
           now - lastLiveHopAt >= liveHopMinInterval {
            popped = window.popHopForced()
            finalizeThisHop = false
        }
        guard let hop = popped else { return }
        lastLiveHopAt = now

        if transcribeInFlight {
            // Backpressure: drop this hop rather than queue. ADR-0008 §3. A dropped
            // idle-flush is benign (the next pass re-decodes the same window — no
            // speech is lost), so only a NATURAL hop raises the rtf_high signal.
            if finalizeThisHop {
                pendingDroppedHops += 1
                broadcast(WireEnvelope(type: "warning", payload: WarningPayload(
                    code: "rtf_high",
                    message: "transcription falling behind; dropped 1 window (RTF=\(String(format: "%.2f", lastTranscribeRTF)))",
                    severity: "medium"
                )))
            }
            return
        }

        transcribeInFlight = true
        let snapshot = hop
        let finalize = finalizeThisHop
        Task { [weak self] in
            await self?.runTranscription(samples: snapshot.samples,
                                         windowStartSessionTime: snapshot.windowStartSessionTime,
                                         finalize: finalize)
        }
    }

    // ─── Transcription path ─────────────────────────────────────────────

    private func runTranscription(samples: [Float], windowStartSessionTime: Double,
                                  finalize: Bool = true) async {
        let started = Date()
        let audioSeconds = Double(samples.count) / 16_000.0
        let results: [TranscriptionResult]
        do {
            let opts = DecodingOptions(
                verbose: false,
                // §2: `.translate` → English for any source; else faithful transcribe.
                task: self.liveTranslateToEnglish ? .translate : .transcribe,
                language: self.sessionLanguage,  // nil = auto; "vi"/"en"/… = source hint
                // LIVE-latency (perf/live-caption-latency): no temperature fallback.
                // WhisperKit's default re-decodes a low-confidence window up to 5×
                // (temperatureFallbackCount: 5), which spikes RTF and drops windows
                // under load. The live caption is latency-first; the at-stop vault
                // re-decode (runFinalTranscription) keeps full-quality fallback for
                // the saved transcript. Speed-over-accuracy, per product decision.
                temperatureFallbackCount: 0,
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

        // PERF instrumentation (perf/live-caption-latency), env-gated so it's
        // zero-cost in normal runs. The window fills 0→30 s over the first ~30 s
        // of speech, so logging (fill, elapsed, tokens) each hop reveals the fixed
        // encoder cost (intercept) vs the per-token decoder cost (slope) on THIS
        // hardware — i.e. whether shrinking the window actually cuts latency, or
        // whether the fixed 30 s-mel encoder dominates and only a smaller model
        // helps. Stderr only (local log; no wire/vault surface).
        if ProcessInfo.processInfo.environment["HARK_PERF_LOG"] != nil {
            let tokenCount = results.reduce(0) { $0 + $1.segments.reduce(0) { $0 + $1.tokens.count } }
            let segCount = results.reduce(0) { $0 + $1.segments.count }
            FileHandle.standardError.write(Data(String(
                format: "harkd-perf hop fill=%.2f elapsed=%.3f rtf=%.3f tokens=%d segs=%d\n",
                audioSeconds, elapsed, rtf, tokenCount, segCount).utf8))
        }

        // Map WhisperKit segments → reconciled emissions.
        let language = results.first?.language
        var winSegments: [WindowSegment] = []
        for r in results {
            for s in r.segments {
                let cleaned = stripWhisperSpecials(s.text).trimmingCharacters(in: .whitespaces)
                // PERF: log the decoder's own confidence signals per segment so
                // we can separate real speech from silence/noise hallucinations
                // empirically before gating on them (perf/live-caption-latency).
                if ProcessInfo.processInfo.environment["HARK_PERF_LOG"] != nil {
                    FileHandle.standardError.write(Data(String(
                        format: "harkd-seg noSpeech=%.3f avgLogp=%.3f compRatio=%.2f  «%@»\n",
                        s.noSpeechProb, s.avgLogprob, s.compressionRatio, cleaned).utf8))
                }
                if cleaned.isEmpty || isLikelyHallucination(cleaned) { continue }
                if isNonSpeechDecode(noSpeechProb: s.noSpeechProb,
                                     avgLogprob: s.avgLogprob,
                                     compressionRatio: s.compressionRatio) { continue }
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

        // IDLE-FLUSH pass (perf/live-caption-latency): partial-only, low-latency
        // refresh between natural hops. Resolve each segment to a stable
        // utterance_id (ADR-0009) and emit it as a `segment.partial` — but do NOT
        // finalize, do NOT advance `committedUpTo`, and do NOT prune. Finalization
        // stays entirely with the natural `hopSeconds`-of-speech hop, so the
        // ADR-0019 commit-watermark and ADR-0036 grow behaviour are byte-for-byte
        // unchanged; this only adds fresher partials for the live caption. Any
        // supersessions the `resolve` mints are drained so the retraction signal
        // still reaches the UI.
        if !finalize {
            for seg in winSegments {
                let uid = ledger.resolve(tStart: seg.tStart, tEnd: seg.tEnd, text: seg.text)
                if ledger.isFinalized(utteranceId: uid) { continue }
                _ = ledger.updateText(seg.text, utteranceId: uid)
                emitSegment(uid: uid, isFinal: false, seg: seg)
            }
            drainAndEmitSupersessions(ledger)
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
            // GROW path (ADR-0036 content-loss fix): if this is a fuller
            // re-decode of an already-FINALIZED line (same conservative
            // time+text-prefix+grew gate as ADR-0018 supersession), EXTEND that
            // finalized line in place rather than letting its grown tail fall
            // behind the watermark and get dropped. Re-emit its final with the
            // fuller text (the renderer replaces by uid; the vault retains by
            // uid) — no loss, no duplicate. The whole grown span is now
            // committed. Runs BEFORE resolve so it can't double-process; an
            // identical re-decode returns nil and falls through to the normal
            // path (becomes a redundant orphan the prune-retraction handles —
            // content is already saved, so no loss).
            if let grownUid = ledger.extendFinalizedIfGrown(
                tStart: seg.tStart, tEnd: seg.tEnd, text: seg.text) {
                // EXPORT-ONLY growth (ADR-0036): the grown re-decode updates the
                // RETAINED finalized text so the SAVED transcript is complete,
                // but we do NOT re-broadcast a segment.final — the LIVE view keeps
                // the discrete short line it first finalized (the user's chosen
                // "live clean, export recovers it"). The fuller text surfaces in
                // the post-stop transcript / vault write, not in the live stream.
                growRetainedFinalized(uid: grownUid, tEnd: seg.tEnd, text: seg.text)
                maxCommittedEnd = max(maxCommittedEnd, seg.tEnd)
                continue
            }
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
                emitSegment(uid: uid, isFinal: true, seg: seg)
                // This region — its FULL span [tStart, tEnd] — is now committed.
                maxCommittedEnd = max(maxCommittedEnd, seg.tEnd)
            case .partial:
                // Still-hot region (after the watermark, ahead of the horizon):
                // a partial — fresh tail or refined. Live replace-in-place.
                emitSegment(uid: uid, isFinal: false, seg: seg)
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
            // A superseded orphan is NOT closed at all here — it was already
            // retracted in favour of the segment that grew past it (ADR-0018);
            // the `where` clause excludes it. The remaining orphans are
            // non-finalized AND non-superseded: a `segment.partial` was shown
            // for each, so the UI needs closure or it dangles forever (the
            // "stranded partial" bug).
            switch Self.prunedOrphanDisposition(orphanStart: p.tStart,
                                                committedUpTo: committedUpTo) {
            case .synthesizeFinal:
                // Still ahead of the watermark — never committed. Promote the
                // dangling partial to a final with its last-known text (ADR-0009).
                let orphanSeg = WindowSegment(
                    tStart: p.tStart, tEnd: p.tEnd, text: p.lastText, language: nil
                )
                emitSegment(uid: p.id, isFinal: true, seg: orphanSeg)
            case .retract:
                // ADR-0019: behind the watermark, so that span was already
                // finalized exactly once. A synthetic final would re-emit
                // committed audio (a visible duplicate). Instead RETRACT the
                // dangling partial via `segment.superseded` (empty `superseded_by`)
                // so the renderer drops it — no duplicate, no stranded partial.
                emitOrphanRetraction(utteranceId: p.id)
            }
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
        // Detach the audio spill BEFORE the transcription drain's `await` (which
        // suspends this actor and could let a fresh capture.start open a NEW spill
        // and secure-delete this one). Taking the reference here — synchronously —
        // hands ownership to this flush; `self.audioSpill` is nilled so a
        // subsequent start can't touch it. We defer the expensive full read-back
        // (ADR-0039) to just before the diarization pass, so the ~225 MiB/hr of
        // Float samples aren't held in RAM across the drain's re-transcription.
        let spill = self.audioSpill
        self.audioSpill = nil
        let keepAudio = self.keepAudio

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

        // Read the full-meeting audio back from the spill — the ONE transient full
        // read (ADR-0039). Both consumers below need the whole `[Float]`: the
        // diarizer (`OfflineDiarizerManager.process(audio:)` takes the full array)
        // and, when `keepAudio` is on, the vault `AudioStore` (Float→Int16). We
        // finalize (patch the WAV sizes) then read; on any failure we fall back to
        // an empty buffer, which makes `runDiarizationPass` write the meeting
        // unlabeled — capture/transcription are already safe. The read materializes
        // the buffer only for THIS stop, not for the whole meeting.
        //
        // Slice B (ADR-0027): the SAME `capturedAudio` feeds the opt-in keep-audio
        // write in `persistMeeting` (after the `.md` write, so the `.wav` reuses the
        // `.md`'s exact basename). When `keepAudio` is off (default) it's discarded
        // — `AudioStore`'s gate guarantees zero `.audio/` I/O on that path.
        var capturedAudio: [Float] = []
        if let spill = spill {
            do {
                try spill.finalizeForReadback()
                capturedAudio = try spill.readAllSamples()
            } catch {
                FileHandle.standardError.write(Data(
                    "harkd: audio spill read-back failed (\(type(of: error))); diarization unlabeled this session\n".utf8))
            }
        }

        let outcome = await runDiarizationPass(
            audio: capturedAudio, utterances: capturedUtterances)

        await persistMeeting(
            sessionId: sessionId, sessionStart: sessionStart,
            durationSec: durationSec, rtfAvg: rtfAvg,
            segmentCount: capturedUtterances.count,
            outcome: outcome,
            audio: capturedAudio, keepAudio: keepAudio)

        // Secure-delete the spill now that both consumers (diarizer + keep-audio
        // write) are done (ADR-0039, hard rule #2): raw meeting audio must not
        // linger on disk. Zero-then-unlink, best-effort — see `secureDelete`. The
        // transient `capturedAudio` copy goes out of scope here too.
        spill?.secureDelete()
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

    // ─── Pruned-orphan disposition (ADR-0019 stranded-partial fix) ──────────

    /// What to do with a NON-finalized, NON-superseded ledger entry that fell
    /// out of the active window (pruned). A `segment.partial` was already shown
    /// for its utterance_id, so the entry can't just be dropped — the renderer
    /// would keep it as a partial forever (the "stranded partial" bug: an early
    /// line sits in the live-tail block at the bottom of the screen while the
    /// meeting has moved on). The disposition gives the UI closure either way.
    enum PrunedOrphanDisposition: Equatable {
        /// Its region is still AHEAD of the commit watermark — it was never
        /// committed. Emit a synthetic `segment.final` with its last-known text
        /// so the UI promotes the dangling partial to a final (ADR-0009).
        case synthesizeFinal
        /// Its region is already BEHIND the commit watermark — that span was
        /// finalized exactly once when it aged past the horizon. A synthetic
        /// final here would re-emit already-committed audio (the duplicate
        /// ADR-0019 removes). Instead RETRACT the dangling partial: emit a
        /// `segment.superseded` for its id so the renderer drops it from its
        /// live map. No single successor exists (its span was absorbed into the
        /// committed transcript under other ids), so the retraction carries an
        /// EMPTY `supersededBy` — see `SegmentSupersededPayload`.
        case retract
    }

    /// PURE disposition for a pruned orphan (non-finalized, non-superseded).
    /// `orphanStart` is the entry's `tStart`; `committedUpTo` is the watermark.
    /// Mirrors `commitDecision`'s exactly-once boundary: `start <= committedUpTo`
    /// means the region was already committed (→ retract), otherwise it was
    /// still hot and never committed (→ synthesize a closing final).
    ///
    /// No actor state, no I/O — unit-tested in CommitWatermarkTests so the live
    /// prune loop and the tests share one definition of "close this orphan."
    static func prunedOrphanDisposition(orphanStart: Double,
                                        committedUpTo: Double) -> PrunedOrphanDisposition {
        orphanStart <= committedUpTo ? .retract : .synthesizeFinal
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
        outcome: DiarizationOutcome,
        audio: [Float], keepAudio: Bool
    ) async {
        let labeled = outcome.labeled
        let attendees = outcome.attendees
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

        // Slice B (ADR-0027): persist the meeting audio ONLY when `keepAudio` is on
        // — `AudioStore`'s gate guarantees zero `.audio/` I/O when off. We do this
        // AFTER the `.md` write so the `.wav` reuses the EXACT same basename as the
        // markdown (the VaultWriter result's filename stem, collision suffix and
        // all): `<id>.wav` ↔ `<id>.md` correlate. Best-effort: a failed/absent
        // write yields `audioPath == nil`; it never affects the meeting save.
        let meetingId = result.fileURL.deletingPathExtension().lastPathComponent
        let audioPath = audioStore.persist(
            meetingId: meetingId, samples: audio, keepAudio: keepAudio)?.path

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
            attendees: attendees,
            centroidForLabel: outcome.centroidForLabel,
            durationForLabel: outcome.durationForLabel)

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

        // Phase 5.1 (ADR-0026): a speaker auto-matched to an enrolled voiceprint
        // carries its enrolled name + confidence; everyone else stays anonymous
        // (matchedName/confidence == nil). For a matched speaker the attendee
        // `label` IS the enrolled name (we renamed it during the diarization pass),
        // so `matchedName == label` — the roster reads the name with a confidence
        // badge, and the contract is unchanged (nullable fields built for this).
        let speakers = attendees.map { label -> MeetingSpeaker in
            if let m = outcome.matchForName[label] {
                return MeetingSpeaker(label: label, matchedName: m.name, confidence: m.confidence)
            }
            return MeetingSpeaker(label: label, matchedName: nil, confidence: nil)
        }
        let payload = MeetingSavedPayload(
            sessionId: sessionId,
            vaultPath: result.fileURL.path,
            audioPath: audioPath,   // absolute .wav path when keepAudio + write OK; else nil (slice B)
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
            let opts = DecodingOptions(verbose: false,
                                       // §2: match the live path's task on the final drain.
                                       task: self.liveTranslateToEnglish ? .translate : .transcribe,
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
                if cleaned.isEmpty || isLikelyHallucination(cleaned) { continue }
                if isNonSpeechDecode(noSpeechProb: s.noSpeechProb,
                                     avgLogprob: s.avgLogprob,
                                     compressionRatio: s.compressionRatio) { continue }
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
    ) async -> DiarizationOutcome {

        // Fallback used on every non-success path: no labels, no attendees, but
        // the transcript text is preserved so the vault file is never empty. No
        // centroids/durations to retain — nothing was diarized, so enrollment
        // has nothing to capture this session.
        func unlabeled() -> DiarizationOutcome {
            let labeled = utterances.map {
                VaultWriter.Utterance(tStart: $0.tStart, label: "Speaker ?", text: $0.text)
            }
            return DiarizationOutcome(labeled: labeled, attendees: [],
                                      centroidForLabel: [:], durationForLabel: [:],
                                      matchForName: [:])
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

        // ── Phase 5.1 auto-match (ADR-0026) ──────────────────────────────────
        //
        // For each clustered speakerId, take its (un-normalized) 256-dim centroid
        // from `result.speakerDatabase`, normalize it, and:
        //   (1) retain it keyed by the speaker's DISPLAY label so a later
        //       speaker.rename can enroll the voiceprint (the DiarizationResult is
        //       discarded by then);
        //   (2) match it against the enrolled set — a confident hit RENAMES that
        //       speaker (its display label becomes the enrolled name everywhere:
        //       vault body, meeting.transcript, roster) and records matchedName/
        //       confidence for the roster.
        // Unmatched speakers keep "Speaker N" (the user can rename → enroll).
        //
        // `displayLabelForOrdinal` is the indirection that makes the rename work:
        // the labeling loop below assigns "Speaker N" by overlap, then we remap to
        // the matched name (if any) via this table — so one definition drives the
        // body, the transcript, and the roster. The centroid/duration maps are
        // ALSO keyed by the display label, so an auto-matched speaker (label =
        // name) is intentionally absent from `centroidForLabel` — we only enroll on
        // a deliberate user rename of an anonymous "Speaker N", never re-enrolling
        // a name we just auto-applied.
        let db = result.speakerDatabase ?? [:]
        var matchedNameForLabel: [String: SpeakerStore.Match] = [:]  // "Speaker N" → match
        var normalizedCentroidForOrdinalLabel: [String: [Float]] = [:]
        for (speakerId, ordinal) in ordinalForSpeakerId {
            guard let rawCentroid = db[speakerId] else { continue }
            let normalized = SpeakerStore.l2Normalized(rawCentroid)
            let ordinalLabel = "Speaker \(ordinal)"
            normalizedCentroidForOrdinalLabel[ordinalLabel] = normalized
            // PRIVACY GATE (ADR-0027): the auto-match reads `.speakers/` via
            // `speakerStore.match`. When the session opted out of remembering
            // speakers we MUST NOT read the store at all — `rememberSpeakers`
            // short-circuits the call so no `.speakers/` access happens and the
            // speaker stays "Speaker N". (We still retain `normalized` above so a
            // later rename CAN enroll if the user opts in then — but that enroll
            // path is itself gated in `enrollFromRename`.)
            if Self.voiceprintAccessAllowed(rememberSpeakers: rememberSpeakers),
               let m = speakerStore.match(centroid: rawCentroid) {
                matchedNameForLabel[ordinalLabel] = m
            }
        }
        // Resolve an ordinal "Speaker N" label to its DISPLAY label (the enrolled
        // name when auto-matched, else unchanged). Pure lookup, used everywhere
        // the label is emitted below.
        func display(_ ordinalLabel: String) -> String {
            matchedNameForLabel[ordinalLabel]?.name ?? ordinalLabel
        }
        if !Self.voiceprintAccessAllowed(rememberSpeakers: rememberSpeakers) {
            // PRIVACY GATE (ADR-0027): auto-match was skipped — no `.speakers/`
            // read happened. Be honest in the log rather than reporting "no
            // speaker auto-matched" (which would imply a lookup ran).
            FileHandle.standardError.write(Data(
                "harkd: enrollment auto-match skipped — remember_speakers off\n".utf8))
        } else if !matchedNameForLabel.isEmpty {
            // Privacy: log the COUNT + distances only — never the enrolled name.
            let dists = matchedNameForLabel.values
                .map { String(format: "%.3f", $0.distance) }
                .joined(separator: ",")
            FileHandle.standardError.write(Data(String(
                format: "harkd: enrollment — auto-matched %d/%d speaker(s) (cosine dist=[%@], threshold=%.3f)\n",
                matchedNameForLabel.count, speakerCount, dists, speakerStore.threshold).utf8))
        } else if !db.isEmpty {
            FileHandle.standardError.write(Data(String(
                format: "harkd: enrollment — no speaker auto-matched (%d centroid(s), threshold=%.3f)\n",
                db.count, speakerStore.threshold).utf8))
        }

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
        // Per-DISPLAY-label total spoken duration (sum of its utterances' spans),
        // for the enrollment duration gate. Keyed by the display label (matched
        // name or "Speaker N"); "Speaker ?" never enrolls so it's harmless here.
        var durationForLabel: [String: Double] = [:]
        // Ambiguity accounting (debug summary only — no behavior change).
        var ambiguousCount = 0
        var zeroOverlapCount = 0
        for u in utterances {
            let m = matchSpeaker(
                forUtteranceStart: u.tStart, end: u.tEnd,
                diarSegments: result.segments, ordinals: ordinalForSpeakerId)
            // Remap the overlap-assigned "Speaker N" to its display label — the
            // enrolled NAME when auto-matched (ADR-0026), else unchanged. "Speaker ?"
            // has no centroid/match, so `display` leaves it as-is.
            let label = display(m.label)
            if label != "Speaker ?", seen.insert(label).inserted {
                attendees.append(label)
            }
            durationForLabel[label, default: 0] += max(0, u.tEnd - u.tStart)
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

        // Sort attendees by their ordinal so the anonymous roster reads Speaker 1,
        // Speaker 2… regardless of who happened to speak first. Auto-matched names
        // have no ordinal suffix — keep them in first-appearance order (a stable
        // sort on the ordinal key: `enumerated` index breaks ties so named labels,
        // all `.max`, preserve their order).
        let order = Dictionary(uniqueKeysWithValues: attendees.enumerated().map { ($1, $0) })
        attendees.sort {
            let a = $0.ordinalSuffix ?? .max, b = $1.ordinalSuffix ?? .max
            return a != b ? a < b : (order[$0] ?? 0) < (order[$1] ?? 0)
        }

        // Retain the per-LABEL normalized centroid for enrollment on a later
        // rename (ADR-0026). Only labels that survived to the body get a centroid;
        // an auto-matched speaker's label is its NAME (absent from the ordinal-
        // keyed map) so we never re-enroll a name we just auto-applied.
        var centroidForLabel: [String: [Float]] = [:]
        for (ordinalLabel, centroid) in normalizedCentroidForOrdinalLabel
        where matchedNameForLabel[ordinalLabel] == nil {
            centroidForLabel[ordinalLabel] = centroid
        }

        // Re-key the auto-matches by their DISPLAY name (the attendee label), so
        // persistMeeting can light up the roster's matchedName/confidence. A
        // collision (two clusters matched to one name) keeps the closer match.
        var matchForName: [String: SpeakerStore.Match] = [:]
        for m in matchedNameForLabel.values {
            if let existing = matchForName[m.name], existing.distance <= m.distance { continue }
            matchForName[m.name] = m
        }

        return DiarizationOutcome(
            labeled: labeled, attendees: attendees,
            centroidForLabel: centroidForLabel, durationForLabel: durationForLabel,
            matchForName: matchForName)
    }

    /// Result of `runDiarizationPass`: the labeled body + roster PLUS the
    /// enrollment data captured from the (now-discarded) `DiarizationResult`. The
    /// centroid + duration maps are keyed by DISPLAY label and only carry the
    /// still-anonymous "Speaker N" speakers — exactly the ones a later
    /// `speaker.rename` can enroll (ADR-0026). `matchForName` carries the
    /// auto-matched roster annotation, keyed by the enrolled name (which IS that
    /// speaker's attendee label).
    private struct DiarizationOutcome {
        let labeled: [VaultWriter.Utterance]
        let attendees: [String]
        let centroidForLabel: [String: [Float]]
        let durationForLabel: [String: Double]
        let matchForName: [String: SpeakerStore.Match]
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
            // Each uid is finalized exactly once (markFinalized gates re-finalize),
            // so a plain append never duplicates a uid here. Grown re-decodes do
            // NOT go through emitSegment — they update the retained row silently
            // via growRetainedFinalized (export-only, no live re-broadcast).
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

    /// Apply a grown re-decode to the RETAINED finalized utterance for `uid` —
    /// for the post-stop transcript / vault write ONLY (ADR-0036). Unlike
    /// `emitSegment`, this does NOT broadcast a `segment.final`, so the LIVE view
    /// keeps the discrete short line it first finalized ("live clean, export
    /// recovers it"): the fuller text reaches the saved transcript (built from
    /// `finalizedUtterances`) without rewriting the live stream. Keeps the
    /// original `tStart`; grows `tEnd` + text. No-op if the uid isn't retained
    /// (defensive — `extendFinalizedIfGrown` only matches a finalized entry,
    /// which was retained when it was emitted).
    private func growRetainedFinalized(uid: String, tEnd: Double, text: String) {
        guard let idx = finalizedUtterances.firstIndex(where: { $0.utteranceId == uid }) else { return }
        finalizedUtterances[idx] = FinalizedUtterance(
            utteranceId: uid,
            tStart: finalizedUtterances[idx].tStart,
            tEnd: tEnd,
            text: text)
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

    /// Retract a dangling partial that can't be closed with a synthetic final.
    /// Used for pruned orphans whose region is already behind the commit
    /// watermark (ADR-0019): a synthetic final would re-emit committed audio, so
    /// instead we tell the UI to DROP the utterance via `segment.superseded`.
    /// There is no single successor (its span was absorbed into the committed
    /// transcript under other ids), so `supersededBy` is EMPTY — the renderer's
    /// handler only deletes the id and ignores `superseded_by`, so an empty
    /// value is the honest "retracted, no single successor" signal.
    ///
    /// Idempotent across the supersession path: we record the id in
    /// `supersededIds` (the at-stop vault filter set) just like
    /// `drainAndEmitSupersessions`, and we no-op if it was already retracted —
    /// so a later real supersession of the same id can't double-emit, and a
    /// real supersession that already fired won't be re-broadcast here.
    @discardableResult
    private func emitOrphanRetraction(utteranceId: String) -> Bool {
        guard supersededIds.insert(utteranceId).inserted else { return false }
        FileHandle.standardError.write(Data(
            "harkd: retracted stale orphan \(utteranceId) (behind watermark)\n".utf8))
        broadcast(WireEnvelope(type: "segment.superseded",
                               payload: SegmentSupersededPayload(
                                   utteranceId: utteranceId,
                                   supersededBy: "")))
        return true
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

/// True when `text` is almost certainly a WhisperKit hallucination on
/// non-speech rather than a real transcription — the sound-effect / silence
/// annotations the decoder emits when handed a near-silent window ("*crickets*",
/// "[BLANK_AUDIO]", "(music playing)", "♪♪♪"), or a fragment that is pure
/// punctuation. These proliferated once idle-flush passes began transcribing
/// thin windows AND temperature fallback (which used to re-roll such
/// low-confidence decodes) was disabled for latency. Conservative by design: it
/// only drops a segment that is ENTIRELY a bracketed/asterisked tag or has no
/// letters or digits at all, so real speech — even "(laughs) okay" — survives.
func isLikelyHallucination(_ text: String) -> Bool {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty { return true }
    // No letter or digit anywhere → punctuation/musical-note noise, not speech.
    let hasAlnum = t.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    if !hasAlnum { return true }
    guard let first = t.first, let last = t.last else { return false }
    // Leads with an asterisk or musical note → a sound-effect annotation, even
    // when the closing mark is missing on a mid-decode ("*Minds of the"). Real
    // speech never opens with these, so it's safe to drop unconditionally.
    if first == "*" || first == "♪" { return true }
    // Fully enclosed in a sound-tag bracket pair → non-speech annotation.
    let openers: Set<Character> = ["*", "(", "[", "{", "♪"]
    let closers: Set<Character> = ["*", ")", "]", "}", "♪"]
    return openers.contains(first) && closers.contains(last)
}

/// Reject a decoded segment as non-speech / hallucination using the DECODER's
/// own confidence signals — the same thresholds WhisperKit's temperature
/// fallback used before we turned it off for latency (ADR-0040). With fallback
/// off the decoder no longer re-rolls low-confidence output, so it emits
/// plausible text on silence/noise ("Thank you." on a gap, repeated phrases).
///
/// Measured real speech sits FAR inside all three gates (noSpeechProb ≈ 0.00,
/// avgLogprob > -0.2, compressionRatio < 1.5 — see the HARK_PERF_LOG per-segment
/// values), so these only fire on genuine non-speech:
///   - `noSpeechProb > 0.6`  — the decoder itself flags the window as silence.
///   - `compressionRatio > 2.4` — runaway repetition ("you you you").
///   - `avgLogprob < -1.0` — very-low-confidence garbage.
/// Note: this does NOT filter real background audio the tap captures (media has
/// low noSpeechProb — it IS speech, just not the meeting); that's source
/// selection, not a confidence problem.
func isNonSpeechDecode(noSpeechProb: Float, avgLogprob: Float, compressionRatio: Float) -> Bool {
    if noSpeechProb > 0.6 { return true }
    if compressionRatio > 2.4 { return true }
    if avgLogprob < -1.0 { return true }
    return false
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
