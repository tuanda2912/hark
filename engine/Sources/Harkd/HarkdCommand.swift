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

        // Load WhisperKit behind the server (NIO keeps serving during this
        // await). capture.start is gated on readiness until attachModel below.
        eprint("Loading model… (first run on this Mac compiles for ANE — can take ~90s)")
        let loaded = try await loadWhisperKit(progressOutput: .standardError)
        await session.attachModel(loaded.pipe, name: loaded.modelName)
        eprint("Model ready: \(loaded.modelName) — capture available")

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
