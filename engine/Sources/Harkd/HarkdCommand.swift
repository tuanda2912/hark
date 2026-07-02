// harkd — Phase 3 streaming engine daemon.
//
// CLI: `harkd [--port N] [--port-file PATH] [--verbose]`
//
// Lifecycle:
//   1. Bind the WebSocket server on 127.0.0.1 and write the `engine.port`
//      file (JSON `{port, pid, version}`) — so the UI can discover harkd
//      IMMEDIATELY, before the slow model load.
//   2. Load WhisperKit large-v3-turbo via HarkCore.ModelLoader (download +
//      ANE compile) BEHIND the running server; capture.start is gated on
//      readiness (ENGINE_WARMING_UP) until the model is attached.
//   3. Wait for SIGINT/SIGTERM. On signal: close clients, stop capture if
//      running, delete port file, exit 0.
//
// Permissions: harkd does NOT gate on permissions at startup. They're
// requested lazily at capture.start — mic via PermissionGate (only if the
// mic source is on), system audio inside the Process Tap backend — both of
// which grant live, so capture continues without a relaunch. See ADR-0011.
//
// Why JSON in the port file (per ADR-0008 §Open questions #2): forward
// compatibility. Phase 4's Electron main can grow to validate pid liveness
// and version compatibility without a file format change.
//
// Privacy: stderr carries lifecycle + state transitions only. No transcript
// content, no audio data, no port-file path leakage to anywhere else.

import Foundation
import ArgumentParser
import HarkCore
import HarkCapture
import WhisperKit

@available(macOS 14.4, *)
@main
struct HarkdCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "harkd",
        abstract: "Hark streaming engine daemon (Phase 3).",
        discussion: """
        Long-lived process the Electron UI spawns. Captures system audio +
        mic, runs VAD-gated sliding-window WhisperKit transcription, streams
        JSON segments over a localhost WebSocket.

        Port is chosen at startup (ephemeral by default) and written to
        --port-file so the UI can discover it. Loopback only — no auth.

        Permissions are requested when capture starts (not at launch):
        Microphone (only if the mic source is on) and system-audio capture
        (handled by the Process Tap backend). Both grant live — no relaunch.

        Stop with SIGINT (Ctrl+C) or SIGTERM. The daemon flushes any
        in-flight final segments before exiting.
        """
    )

    @Option(name: .long, help: "TCP port to bind on 127.0.0.1. 0 (default) = ephemeral.")
    var port: Int = 0

    @Option(name: .long, help: "Path to write the chosen port to. Default: ~/Library/Application Support/Hark/engine.port")
    var portFile: String?

    @Flag(name: .shortAndLong, help: "Extra lifecycle logging on stderr.")
    var verbose: Bool = false

    mutating func run() async throws {
        eprint("──────────────────────────────────────────────────────────────")
        eprint("harkd \(HARKD_ENGINE_VERSION) — streaming engine")
        eprint("──────────────────────────────────────────────────────────────")

        // No startup permission gate. harkd needs NO capture permission just to
        // boot + serve; capture permissions are requested lazily at
        // capture.start (mic via PermissionGate; system audio inside the tap
        // backend), both of which grant live — so the user grants once and
        // capture continues in the SAME process, no relaunch. (Amends the
        // fail-fast gate of ADR-0006 §3 for the daemon; see ADR-0011.)

        // Purge any audio spill files a prior crashed session left in app-support
        // (ADR-0039, hard rule #2): a clean stop secure-deletes its own spill, so
        // anything still in `tmp/` is orphaned raw audio and must go before we
        // start. Best-effort, logs a COUNT only.
        SessionAudioSpill.cleanStaleSpills()

        // Bring up the WS server + session FIRST, then write the port file, so
        // the UI can discover harkd IMMEDIATELY. The model loads behind it.
        let server = HarkdWebSocketServer()
        let session = EngineSession(server: server)
        let delegate = WSDelegateAdapter(session: session)
        server.delegate = delegate

        let boundPort: Int
        do {
            boundPort = try server.bind(port: port)
        } catch {
            eprint("harkd: failed to bind WS server on port \(port): \(error)")
            throw ExitCode(2)
        }
        eprint("WebSocket server listening on ws://127.0.0.1:\(boundPort)/v1")

        // Write the port file. JSON for forward compat.
        let portFileURL = try resolvePortFileURL(override: portFile)
        try writePortFile(at: portFileURL, port: boundPort, pid: Int(ProcessInfo.processInfo.processIdentifier))
        eprint("Port file: \(portFileURL.path)")

        // Model-load progress → UI. The loaders' progress callbacks fire OFF the
        // actor on unspecified/arbitrary queues; we bounce each into the actor
        // via `Task { await session.emitModelProgress(...) }` (the SAME hop the
        // WS delegate + capture sink use). The FluidAudio byte callback and the
        // WhisperKit per-1% callback can both fire very frequently, so we
        // THROTTLE before the Task hop (a flood of tasks would be the cost we're
        // trying to avoid): forward only when fraction moved ≥0.01, ≥200ms
        // elapsed, OR the phase changed. See `ModelProgressThrottle`.
        let progressThrottle = ModelProgressThrottle()
        let onModelProgress: @Sendable (String, Double?, String) -> Void = { phase, fraction, detail in
            guard progressThrottle.shouldEmit(phase: phase, fraction: fraction) else { return }
            Task { await session.emitModelProgress(phase: phase, fraction: fraction, detail: detail) }
        }

        // Bring up vault-RAG (embedder + index) CONCURRENTLY with the speech /
        // diarizer loads below — a detached Task launched BEFORE the WhisperKit
        // await, so vault search never waits behind the multi-minute large-v3
        // ANE compile (RAG is independent of capture; the embedder is small).
        // NON-FATAL: a failed embedder load disables ONLY vault search
        // (rag.retrieve → RAG_UNAVAILABLE); capture + live transcription are
        // unaffected. The index cold-builds / reconciles in the background and an
        // FSEvents watcher (30 s debounce, content-hash gated) keeps it fresh.
        // `session` (actor) + `onModelProgress` (@Sendable) are safe to capture.
        Task {
            do {
                let loadedEmbedder = try await loadTextEmbedder(
                    progressOutput: .standardError, onProgress: onModelProgress)
                let model = loadedEmbedder.model
                let indexDir = try HarkPaths.indexDir()
                let ragIndex = RagIndex(
                    dim: model.dimension, modelId: model.id, modelRevision: model.revision, dir: indexDir)
                // Status sink → UI: hop each index-state change into the session
                // actor, same pattern as the model-progress hop. `state` is the
                // RagIndexState rawValue ("idle"|"building"|"ready").
                let statusSink: RagStatusSink = { state, indexedCount, total in
                    Task { await session.emitRagIndexStatus(
                        state: state.rawValue, indexedCount: indexedCount, total: total) }
                }
                let vaultRoot = URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Documents/vault/hark", isDirectory: true)
                let indexer = RagIndexer(
                    index: ragIndex, embedder: loadedEmbedder.embedder,
                    vaultRoot: vaultRoot, statusSink: statusSink)
                await session.attachRagIndexer(indexer)
                eprint("Vault RAG embedder ready — index building in background (model: \(model.id))")
                // Cold build / reconcile + start the watcher. We're already off the
                // capture-readiness path (this whole Task is concurrent), so awaiting
                // here is fine — it just keeps this Task alive for the build.
                await indexer.start()
            } catch {
                eprint("harkd: embedder load failed (\(error)); continuing WITHOUT vault search")
            }
        }

        // Load WhisperKit behind the server (NIO keeps serving during this
        // await). capture.start is gated on readiness until attachModel below.
        eprint("Loading model… (first run on this Mac compiles for ANE — can take ~90s)")
        let loaded = try await loadWhisperKit(progressOutput: .standardError, onProgress: onModelProgress)
        await session.attachModel(loaded.pipe, name: loaded.modelName)
        eprint("Model ready: \(loaded.modelName) — capture available")

        // Load the offline diarizer behind the same readiness gate (Phase 5,
        // ADR-0016). This is NON-FATAL: if the download/compile fails, capture
        // and live transcription still work — only the post-stop speaker pass
        // is skipped. Loaded AFTER WhisperKit so the live path is available as
        // early as possible (capture doesn't need the diarizer to start).
        do {
            let diar = try await loadDiarizerModels(progressOutput: .standardError, onProgress: onModelProgress)
            await session.attachDiarizer(Diarizer(manager: diar.manager))
            eprint("Diarizer ready — offline speaker pass enabled (models: \(diar.modelsDir.path))")
        } catch {
            eprint("harkd: diarizer load failed (\(error)); continuing WITHOUT speaker labels")
        }

        if verbose {
            eprint("harkd: pid=\(ProcessInfo.processInfo.processIdentifier) ready, waiting for client")
        }

        // Park on SIGINT/SIGTERM. Same OneShotResume pattern as hark-capture.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let one = HarkdShutdown(cont: cont)

            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)

            let s1 = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            s1.setEventHandler {
                FileHandle.standardError.write(Data("\nharkd: SIGINT received, shutting down…\n".utf8))
                one.fire()
            }
            s1.resume()
            one.sources.append(s1)

            let s2 = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            s2.setEventHandler {
                FileHandle.standardError.write(Data("\nharkd: SIGTERM received, shutting down…\n".utf8))
                one.fire()
            }
            s2.resume()
            one.sources.append(s2)
        }

        // Graceful teardown. Best-effort — don't propagate errors past here.
        eprint("harkd: closing WS server")
        server.shutdown()
        try? FileManager.default.removeItem(at: portFileURL)
        eprint("harkd: bye")
    }

    // ─── Helpers ────────────────────────────────────────────────────────

    private func resolvePortFileURL(override: String?) throws -> URL {
        if let override = override {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("Hark", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("engine.port")
    }

    private func writePortFile(at url: URL, port: Int, pid: Int) throws {
        struct PortFile: Encodable {
            let port: Int
            let pid: Int
            let version: String
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try enc.encode(PortFile(port: port, pid: pid, version: HARKD_ENGINE_VERSION))
        try data.write(to: url, options: .atomic)
    }
}

// ─── Stderr helper ────────────────────────────────────────────────────────

@inline(__always)
func eprint(_ s: String, terminator: String = "\n") {
    FileHandle.standardError.write(Data((s + terminator).utf8))
}

// ─── Model-load progress throttle ────────────────────────────────────────
//
// The model-load progress callbacks fire on arbitrary queues, potentially
// concurrently, and VERY often (FluidAudio's per-byte download callback,
// WhisperKit's per-1% callback). We throttle BEFORE spawning the actor-hop
// Task so we don't flood the actor with thousands of tiny `emitModelProgress`
// tasks. The decision is forced through whenever the phase changes (so a
// transition is never dropped) or a terminal 1.0 fraction arrives, and
// otherwise rate-limited to a meaningful delta or a time interval.
//
// `@unchecked Sendable`: the cross-call state (last phase/fraction/time) is
// guarded by an internal lock, the same pattern as `ProgressRenderer`. The
// PURE `decide` static below carries no state and is what the unit test drives,
// so the time-based branch is deterministic in tests (we pass `now`).

@available(macOS 14.4, *)
final class ModelProgressThrottle: @unchecked Sendable {
    /// Minimum fraction delta to emit on (1%). Below this, only time/phase gate.
    static let minFractionDelta = 0.01
    /// Minimum wall interval between emits within the same phase (200 ms).
    static let minInterval = 0.2

    private let lock = NSLock()
    private var lastPhase: String?
    private var lastFraction: Double?
    private var lastEmitAt: Date?

    /// Thread-safe gate used from the `@Sendable` progress callbacks. Returns
    /// true when this update should be forwarded to the actor; updates the
    /// retained "last emitted" state when it does.
    func shouldEmit(phase: String, fraction: Double?, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let emit = Self.decide(
            phase: phase, fraction: fraction, now: now,
            lastPhase: lastPhase, lastFraction: lastFraction, lastEmitAt: lastEmitAt)
        if emit {
            lastPhase = phase
            lastFraction = fraction
            lastEmitAt = now
        }
        return emit
    }

    /// PURE throttle decision (no state, no I/O) so the unit test can drive the
    /// time-based branch deterministically. Emit when:
    ///   - the phase changed (a transition must never be dropped), OR
    ///   - this is the first update, OR
    ///   - the fraction is terminal (1.0) and wasn't already, OR
    ///   - the fraction moved ≥ `minFractionDelta`, OR
    ///   - ≥ `minInterval` elapsed since the last emit.
    /// A nil fraction (the indeterminate ANE-compile pulse) has no delta to
    /// measure, so within a phase it gates purely on time — exactly what the
    /// ~1.5s compile re-emit wants.
    static func decide(
        phase: String, fraction: Double?, now: Date,
        lastPhase: String?, lastFraction: Double?, lastEmitAt: Date?
    ) -> Bool {
        guard let lastPhase = lastPhase, let lastEmitAt = lastEmitAt else { return true }
        if phase != lastPhase { return true }
        if let f = fraction {
            if f >= 1.0 && lastFraction != 1.0 { return true }
            if let lf = lastFraction, abs(f - lf) >= minFractionDelta { return true }
            if lastFraction == nil { return true }  // nil → known fraction is news
        }
        return now.timeIntervalSince(lastEmitAt) >= minInterval
    }
}

// ─── Shutdown coordinator (one-shot) ─────────────────────────────────────
//
// Multiple signals or duplicate Ctrl+C must not double-resume the
// continuation. Same shape as hark-capture's OneShotResume.

@available(macOS 14.4, *)
private final class HarkdShutdown: @unchecked Sendable {
    private let cont: CheckedContinuation<Void, Never>
    private var fired = false
    private let lock = NSLock()
    var sources: [DispatchSourceSignal] = []

    init(cont: CheckedContinuation<Void, Never>) { self.cont = cont }

    func fire() {
        lock.lock()
        let shouldFire = !fired
        fired = true
        lock.unlock()
        guard shouldFire else { return }
        for s in sources { s.cancel() }
        cont.resume()
    }
}

// ─── WebSocket delegate adapter ──────────────────────────────────────────
//
// `HarkdWebSocketServer` calls these methods on its NIO EventLoop. Each
// hand-off into the actor uses `Task { await ... }` so the actor's
// executor serializes mutations. This is the standard way to bridge
// NIO callbacks into Swift Concurrency.

@available(macOS 14.4, *)
final class WSDelegateAdapter: WebSocketDelegate {
    private let session: EngineSession

    init(session: EngineSession) {
        self.session = session
    }

    func clientDidConnect(_ client: WebSocketClient) {
        Task { await session.handleConnect(client) }
    }
    func clientDidDisconnect(_ client: WebSocketClient) {
        Task { await session.handleDisconnect(client) }
    }
    func clientDidSend(_ client: WebSocketClient, text: String) {
        Task { await session.handleInbound(client, text: text) }
    }
}
