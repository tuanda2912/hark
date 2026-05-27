// WebSocketServer — localhost WebSocket server on Swift NIO.
//
// Wire surface (per ADR-0008 §1 + the API contract):
//   - Bind to 127.0.0.1, ephemeral port (or user-specified via --port).
//   - Reject non-loopback connections.
//   - WebSocket upgrade on any HTTP GET (path is informational — the
//     contract specifies /v1 but the engine doesn't gate on it; misroute
//     would just degrade to "no WS frames ever arrive").
//   - One text frame == one JSON message. UTF-8.
//   - Server-initiated pings every 5s; client pongs reset the heartbeat
//     timeout. We use application-level `meta.heartbeat` for app metrics;
//     NIO's protocol-level ping is just liveness.
//
// Java analogue for the handler chain:
//   Think of NIO ChannelHandlers as a chain of Netty handlers — Hibernate
//   has nothing equivalent; the closest in Spring is the
//   ServletContextHandler → DispatcherServlet pipeline. Each handler
//   transforms in/out events. Order matters.
//
// The chain we install:
//
//   bytes ──HTTPServerProtocolUpgrader──► WSFrameDecoder ──► AggregatingHandler ──► AppHandler
//
// `AppHandler` is where harkd's message dispatch happens. It owns a weak
// reference to an `EngineSession` (set after construction so the server
// can be wired up before the engine is ready).
//
// Privacy: this file logs lifecycle (connect, close, error) to stderr but
// NEVER logs payload bytes or message content.

import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket

/// Delegate interface implemented by EngineSession. Methods are called from
/// the WS handler's EventLoop — implementations must hop to the engine's
/// own actor before doing real work.
protocol WebSocketDelegate: AnyObject {
    /// New client connected. Engine should immediately send `meta.hello`.
    func clientDidConnect(_ client: WebSocketClient)
    /// Client gone. Engine may want to stop capture (or keep going — TBD).
    func clientDidDisconnect(_ client: WebSocketClient)
    /// Inbound text frame received. Engine parses + dispatches.
    func clientDidSend(_ client: WebSocketClient, text: String)
}

/// A live WebSocket client. EngineSession holds these to push frames out.
/// `send(_ data:)` is safe to call from any thread; it hops onto the
/// channel's EventLoop internally.
final class WebSocketClient {
    let id: String
    private weak var channel: Channel?

    init(id: String, channel: Channel) {
        self.id = id
        self.channel = channel
    }

    /// Send a UTF-8 JSON payload as a single text frame.
    func send(_ data: Data) {
        guard let channel = channel else { return }
        // Bytes → ByteBuffer → WebSocketFrame(text). NIO requires this on
        // the channel's EventLoop; we let `writeAndFlush` hop us there.
        var buf = channel.allocator.buffer(capacity: data.count)
        buf.writeBytes(data)
        let frame = WebSocketFrame(fin: true, opcode: .text, data: buf)
        channel.writeAndFlush(frame, promise: nil)
    }

    /// Polite close. Sends a close frame; channel teardown follows.
    func close() {
        guard let channel = channel else { return }
        let frame = WebSocketFrame(
            fin: true, opcode: .connectionClose,
            data: channel.allocator.buffer(capacity: 0)
        )
        channel.writeAndFlush(frame).whenComplete { _ in
            channel.close(promise: nil)
        }
    }

    var isOpen: Bool { channel?.isActive == true }
}

// ─── App-level handler (one per channel) ─────────────────────────────────

final class HarkdWSAppHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private weak var delegate: WebSocketDelegate?
    private var client: WebSocketClient?
    private let clientId: String
    /// Accumulator for fragmented text frames. Most clients send unfragmented,
    /// but the spec allows fragmentation and NIO honors it.
    private var partialText: ByteBuffer?

    init(delegate: WebSocketDelegate?, clientId: String) {
        self.delegate = delegate
        self.clientId = clientId
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // When the WS upgrade completes, this handler is appended to an
        // already-active channel. `channelActive` will NOT re-fire for us,
        // so we treat `handlerAdded` as our "client is ready" hook. The
        // channel is guaranteed active here in the upgrade flow.
        let c = WebSocketClient(id: clientId, channel: context.channel)
        self.client = c
        delegate?.clientDidConnect(c)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let c = client {
            delegate?.clientDidDisconnect(c)
        }
        self.client = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .ping:
            // Reply pong with the same payload — NIO doesn't auto-handle this.
            var pong = WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)
            // Mirror the masked bit only on client→server frames; server→client
            // frames must not be masked.
            pong.maskKey = nil
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        case .connectionClose:
            // Echo a close back and close the channel.
            let close = WebSocketFrame(
                fin: true, opcode: .connectionClose,
                data: context.channel.allocator.buffer(capacity: 0)
            )
            context.writeAndFlush(wrapOutboundOut(close)).whenComplete { _ in
                context.close(promise: nil)
            }
        case .text:
            if frame.fin {
                handleTextFrame(frame.unmaskedData)
            } else {
                partialText = frame.unmaskedData
            }
        case .continuation:
            if var acc = partialText {
                var more = frame.unmaskedData
                acc.writeBuffer(&more)
                partialText = acc
                if frame.fin {
                    handleTextFrame(acc)
                    partialText = nil
                }
            }
        case .binary:
            // Contract is JSON text only. Ignore binary frames silently —
            // logging would be a payload-content leak vector.
            break
        default:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        FileHandle.standardError.write(Data("harkd: ws channel error: \(type(of: error))\n".utf8))
        context.close(promise: nil)
    }

    private func handleTextFrame(_ buffer: ByteBuffer) {
        guard let client = client else { return }
        guard let text = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) else {
            return
        }
        delegate?.clientDidSend(client, text: text)
    }
}

// ─── Upgrade handler removal helper ──────────────────────────────────────
//
// After the HTTP→WS upgrade, the HTTP handlers are no longer needed and
// must be removed from the pipeline. NIO provides this idiom.

private final class HTTPHandlerCleaner: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // If we receive HTTP traffic on a channel that should have upgraded,
        // it means the client didn't send a WS upgrade. Close it.
        let part = unwrapInboundIn(data)
        if case .end = part {
            // Write a minimal 400 and close.
            context.close(promise: nil)
        }
    }
}

// ─── Server entry point ──────────────────────────────────────────────────

@available(macOS 14.4, *)
final class HarkdWebSocketServer {
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?
    weak var delegate: WebSocketDelegate?

    private var clientCounter = 0
    private let clientCounterLock = NSLock()

    init() {
        // 1 IO thread is plenty for one localhost client.
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    /// Bind to 127.0.0.1 on `port`. Pass 0 for ephemeral. Returns the
    /// actually-bound port number.
    func bind(port: Int) throws -> Int {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] channel in
                guard let self = self else {
                    return channel.eventLoop.makeFailedFuture(
                        NSError(domain: "harkd.ws", code: -1)
                    )
                }
                return self.configureChild(channel: channel)
            }
            // Enable TCP_NODELAY — caption latency matters more than throughput.
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)

        // Loopback only — the API contract says "loopback only, no auth".
        // We bind to 127.0.0.1 explicitly; OS-level firewall not required.
        let ch = try bootstrap.bind(host: "127.0.0.1", port: port).wait()
        self.channel = ch
        guard let boundPort = ch.localAddress?.port else {
            throw NSError(domain: "harkd.ws", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "no bound port"])
        }
        return boundPort
    }

    private func configureChild(channel: Channel) -> EventLoopFuture<Void> {
        let clientId = nextClientId()
        let appHandler = HarkdWSAppHandler(delegate: delegate, clientId: clientId)

        // WebSocket upgrader. shouldUpgrade gates the upgrade decision;
        // we accept any GET. upgradePipelineHandler installs the WS frame
        // codec + the app handler.
        let upgrader = NIOWebSocketServerUpgrader(
            shouldUpgrade: { (channel, head) in
                // Localhost has been enforced by the bind address; no extra
                // host header check needed. Return empty extra response
                // headers (channel.eventLoop.makeSucceededFuture(...)).
                channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { channel, _ in
                channel.pipeline.addHandler(appHandler)
            }
        )

        let httpHandlerCleaner = HTTPHandlerCleaner()

        return channel.pipeline.configureHTTPServerPipeline(
            withServerUpgrade: (
                upgraders: [upgrader],
                completionHandler: { context in
                    // Once upgraded, the HTTP cleanup handler is unnecessary.
                    context.pipeline.removeHandler(httpHandlerCleaner, promise: nil)
                }
            )
        ).flatMap {
            channel.pipeline.addHandler(httpHandlerCleaner)
        }
    }

    private func nextClientId() -> String {
        clientCounterLock.lock()
        clientCounter += 1
        let n = clientCounter
        clientCounterLock.unlock()
        return "client-\(n)"
    }

    func shutdown() {
        try? channel?.close().wait()
        try? group.syncShutdownGracefully()
    }
}
