import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import CrierEmitCore

// CrierServer — local HTTP server reused by `crier-daemon` (CLI) and `Crier.app`
// (UI process embeds it so launching the app starts the server in-process).
//
//   POST /event              intake from hook adapters (logged + broadcast)
//   POST /reply              deliver the user's reply (wakes long-poll waiter
//                            keyed by request_id; runs `tmux send-keys` for
//                            channel="tmux"; for keystroke channel the UI
//                            does its own CGEvent dispatch).
//   GET  /reply?request_id=X&wait=N
//                            long-poll until the matching POST /reply lands
//                            (or N seconds elapse, returning 204).
//   GET  /current?wait=N     long-poll for the next event broadcast.
//   GET  /healthz            cheap liveness probe.

// ISO8601DateFormatter is documented as thread-safe; mark nonisolated so we
// can format timestamps from any handler context under Swift 6 strict concurrency.
nonisolated(unsafe) private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

// MARK: - EventHub

// One-shot broadcaster: connected GET /current waiters are all signaled with
// the same payload when a new event arrives. If nobody is waiting, the event
// is queued so a poller that starts slightly later (e.g. UI still showing the
// previous blocking panel) does not miss it. Queue is bounded — under flood,
// oldest events drop first.
private final class EventHub: @unchecked Sendable {
    static let shared = EventHub()
    private let lock = NSLock()
    private var waiters: [UUID: EventLoopPromise<Data?>] = [:]
    private var eventQueue: [Data] = []
    private let maxQueuedEvents = 32

    func publish(_ data: Data) {
        lock.lock()
        let snapshot = waiters
        waiters.removeAll()
        if snapshot.isEmpty {
            if eventQueue.count >= maxQueuedEvents {
                eventQueue.removeFirst()
            }
            eventQueue.append(data)
            lock.unlock()
            return
        }
        lock.unlock()
        for (_, p) in snapshot {
            p.succeed(data)
        }
    }

    func awaitNext(eventLoop: EventLoop, timeoutSeconds: Int) -> EventLoopFuture<Data?> {
        lock.lock()
        if !eventQueue.isEmpty {
            let data = eventQueue.removeFirst()
            lock.unlock()
            return eventLoop.makeSucceededFuture(data)
        }
        let id = UUID()
        let promise = eventLoop.makePromise(of: Data?.self)
        waiters[id] = promise
        lock.unlock()

        eventLoop.scheduleTask(in: .seconds(Int64(timeoutSeconds))) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let p = self.waiters.removeValue(forKey: id)
            self.lock.unlock()
            p?.succeed(nil)
        }
        return promise.futureResult
    }
}

// Per-CWD disable is now filesystem-based at /tmp/crier-agent/disabled-<md5(cwd)>,
// matching Superwhisper's pattern. crier-emit checks it directly; the daemon
// has no involvement, which means disable state survives daemon restarts.
// See assets/claude-skills/crier/SKILL.md.

// MARK: - ReplyHub

// Correlates POST /reply (delivery) with GET /reply (long-poll) by request_id.
private final class ReplyHub: @unchecked Sendable {
    static let shared = ReplyHub()
    private let lock = NSLock()
    private var pending: [String: String] = [:]
    private var waiters: [String: EventLoopPromise<String?>] = [:]

    func deliver(requestId: String, text: String) -> Bool {
        lock.lock()
        if let waiter = waiters.removeValue(forKey: requestId) {
            lock.unlock()
            waiter.succeed(text)
            return true
        }
        pending[requestId] = text
        lock.unlock()
        return false
    }

    func awaitReply(requestId: String, eventLoop: EventLoop, timeoutSeconds: Int) -> EventLoopFuture<String?> {
        lock.lock()
        if let p = pending.removeValue(forKey: requestId) {
            lock.unlock()
            return eventLoop.makeSucceededFuture(p)
        }
        let promise = eventLoop.makePromise(of: String?.self)
        waiters[requestId] = promise
        lock.unlock()

        eventLoop.scheduleTask(in: .seconds(Int64(timeoutSeconds))) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let waiter = self.waiters.removeValue(forKey: requestId)
            self.lock.unlock()
            waiter?.succeed(nil)
        }
        return promise.futureResult
    }
}

// MARK: - HTTP handler

private final class CrierHTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private var requestHead: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch self.unwrapInboundIn(data) {
        case .head(let head):
            self.requestHead = head
            self.bodyBuffer = context.channel.allocator.buffer(capacity: 0)
        case .body(var body):
            self.bodyBuffer?.writeBuffer(&body)
        case .end:
            handleRequest(context: context)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        FileHandle.standardError.write(Data("crier-server: connection error: \(error)\n".utf8))
        context.close(promise: nil)
    }

    private func handleRequest(context: ChannelHandlerContext) {
        guard let head = requestHead else { return }
        let bodyData = bodyBuffer.flatMap { Data($0.readableBytesView) } ?? Data()

        let responseFuture: EventLoopFuture<(HTTPResponseStatus, String, String)>

        switch (head.method, head.uri) {
        case (.POST, "/event"):
            handleEvent(body: bodyData)
            responseFuture = context.eventLoop.makeSucceededFuture((.ok, "application/json", #"{"ok":true}"#))

        case (.POST, "/reply"):
            handlePostReply(body: bodyData)
            responseFuture = context.eventLoop.makeSucceededFuture((.ok, "application/json", #"{"ok":true}"#))

        case (.GET, let uri) where uri.hasPrefix("/reply"):
            responseFuture = handleGetReply(uri: uri, eventLoop: context.eventLoop)

        case (.GET, let uri) where uri.hasPrefix("/current"):
            responseFuture = handleGetCurrent(uri: uri, eventLoop: context.eventLoop)

        case (.GET, "/healthz"):
            responseFuture = context.eventLoop.makeSucceededFuture((.ok, "application/json", #"{"ok":true}"#))

        default:
            responseFuture = context.eventLoop.makeSucceededFuture((.notFound, "application/json", #"{"error":"not found"}"#))
        }

        let httpVersion = head.version
        responseFuture.whenComplete { [weak self] result in
            guard let self else { return }
            let (status, contentType, body): (HTTPResponseStatus, String, String)
            switch result {
            case .success(let r): (status, contentType, body) = r
            case .failure: (status, contentType, body) = (.internalServerError, "application/json", #"{"error":"internal"}"#)
            }
            self.writeResponse(context: context, requestVersion: httpVersion, status: status, contentType: contentType, body: body)
        }

        self.requestHead = nil
        self.bodyBuffer = nil
    }

    private func writeResponse(context: ChannelHandlerContext, requestVersion: HTTPVersion, status: HTTPResponseStatus, contentType: String, body: String) {
        var responseBuffer = context.channel.allocator.buffer(capacity: body.utf8.count)
        responseBuffer.writeString(body)

        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: contentType)
        headers.add(name: "content-length", value: "\(body.utf8.count)")
        headers.add(name: "connection", value: "close")

        let responseHead = HTTPResponseHead(version: requestVersion, status: status, headers: headers)
        context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(self.wrapOutboundOut(.body(.byteBuffer(responseBuffer))), promise: nil)
        context.writeAndFlush(self.wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }

    // MARK: route handlers

    private func handleEvent(body: Data) {
        let parsed = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let agent = parsed["agent"] as? String ?? "?"
        let event = parsed["event"] as? String ?? "?"
        let cwd = parsed["cwd"] as? String ?? "?"
        let session = parsed["session_id"] as? String ?? "?"
        let requestId = parsed["request_id"] as? String
        let message = parsed["message"] as? String ?? ""
        let replyChannel = parsed["reply_channel"] as? String
        let replyTarget = parsed["reply_target"] as? String

        var line = "[\(isoFormatter.string(from: Date()))] \(event) · \(agent) · \(cwd)\n"
        line += "  session: \(session)\n"
        if let rid = requestId { line += "  req:     \(rid)\n" }
        if let rc = replyChannel, let rt = replyTarget {
            line += "  reply:   \(rc) → \(rt)\n"
        }
        if !message.isEmpty {
            let firstLine = message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? message
            let preview: String = firstLine.count > 240 ? String(firstLine.prefix(240)) + "…" : firstLine
            line += "  message: \(preview)\n"
        }
        FileHandle.standardOutput.write(Data(line.utf8))

        if CrierEmptyMessageDiagnostic.shouldLogEmptyMessage(event: event),
           CrierEmptyMessageDiagnostic.isEffectivelyEmptyMessage(message) {
            var rec: [String: Any] = [
                "ts": isoFormatter.string(from: Date()),
                "kind": "empty_message_event",
                "source": "crier-server",
                "agent": agent,
                "event": event,
                "session_id": session,
                "cwd": cwd,
            ]
            if let rid = requestId { rec["request_id"] = rid }
            if let rc = replyChannel { rec["reply_channel"] = rc }
            if let rt = replyTarget { rec["reply_target"] = rt }
            if let t = parsed["title"] as? String, !t.isEmpty { rec["title"] = t }
            if let tp = parsed["transcript_path"] as? String, !tp.isEmpty { rec["transcript_path"] = tp }
            rec["payload_keys"] = parsed.keys.sorted().map { $0 }
            rec["note"] = "POST /event had empty message; crier-ui shows the transcript placeholder for this session."
            CrierEmptyMessageDiagnostic.append(record: rec)
        }

        EventHub.shared.publish(body)
    }

    private func handleGetCurrent(uri: String, eventLoop: EventLoop) -> EventLoopFuture<(HTTPResponseStatus, String, String)> {
        let comps = URLComponents(string: "http://h\(uri)")
        let waitSeconds = Int(comps?.queryItems?.first(where: { $0.name == "wait" })?.value ?? "30") ?? 30
        let clamped = max(1, min(600, waitSeconds))
        return EventHub.shared.awaitNext(eventLoop: eventLoop, timeoutSeconds: clamped).map { data in
            if let data = data {
                let body = String(data: data, encoding: .utf8) ?? "{}"
                return (.ok, "application/json", body)
            }
            return (.noContent, "application/json", "")
        }
    }

    private func handlePostReply(body: Data) {
        let parsed = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let session = parsed["session_id"] as? String ?? "?"
        let requestId = parsed["request_id"] as? String
        let text = parsed["text"] as? String ?? ""
        let channel = parsed["channel"] as? String
        let target = parsed["target"] as? String

        var line = "[\(isoFormatter.string(from: Date()))] reply · \(session)"
        if let rid = requestId { line += " · req=\(rid)" }
        if let ch = channel { line += " · ch=\(ch)" }
        if let tg = target { line += " · target=\(tg)" }
        line += "\n  text: \(text.prefix(200))\n"
        FileHandle.standardOutput.write(Data(line.utf8))

        if let rid = requestId {
            let woke = ReplyHub.shared.deliver(requestId: rid, text: text)
            if !woke {
                FileHandle.standardError.write(Data("  (no waiter — reply parked for late long-poll)\n".utf8))
            }
        }

        // Tmux delivery only for non-blocking events (no request_id).
        // Blocking events (turn_done) use the hook-stdout path via ReplyHub;
        // injecting keystrokes on top would double-submit the reply.
        if requestId == nil, channel == "tmux", let target, !text.isEmpty {
            DispatchQueue.global(qos: .userInitiated).async {
                Self.runTmuxReply(target: target, text: text)
            }
        }
    }

    private static func runTmuxReply(target: String, text: String) {
        let literal = Process()
        literal.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        literal.arguments = ["tmux", "send-keys", "-t", target, "-l", "--", text]
        literal.standardOutput = Pipe(); literal.standardError = Pipe()
        do { try literal.run(); literal.waitUntilExit() } catch {
            FileHandle.standardError.write(Data("crier-server: tmux send-keys (text) failed: \(error)\n".utf8))
            return
        }

        let enter = Process()
        enter.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        enter.arguments = ["tmux", "send-keys", "-t", target, "Enter"]
        enter.standardOutput = Pipe(); enter.standardError = Pipe()
        do { try enter.run(); enter.waitUntilExit() } catch {
            FileHandle.standardError.write(Data("crier-server: tmux send-keys (Enter) failed: \(error)\n".utf8))
        }
    }

    private func handleGetReply(uri: String, eventLoop: EventLoop) -> EventLoopFuture<(HTTPResponseStatus, String, String)> {
        guard let comps = URLComponents(string: "http://h\(uri)"),
              let requestId = comps.queryItems?.first(where: { $0.name == "request_id" })?.value,
              !requestId.isEmpty else {
            return eventLoop.makeSucceededFuture((.badRequest, "application/json", #"{"error":"missing request_id"}"#))
        }
        let waitSeconds = Int(comps.queryItems?.first(where: { $0.name == "wait" })?.value ?? "30") ?? 30
        let clamped = max(1, min(600, waitSeconds))

        return ReplyHub.shared.awaitReply(requestId: requestId, eventLoop: eventLoop, timeoutSeconds: clamped).map { text in
            if let text = text {
                return (.ok, "text/plain; charset=utf-8", text)
            } else {
                return (.noContent, "application/json", "")
            }
        }
    }
}

// MARK: - public API

public enum CrierServer {
    /// Bind and serve on host:port. Blocks until the channel closes (which only
    /// happens on process exit). Throws if bind fails (most commonly because
    /// another process — e.g. a separately-launched `crier-daemon` — already
    /// owns the port).
    public static func run(host: String = "127.0.0.1", port: Int = 8731) throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 32)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(CrierHTTPHandler())
                }
            }

        let channel = try bootstrap.bind(host: host, port: port).wait()
        FileHandle.standardError.write(Data("crier-server: listening on http://\(host):\(port)\n".utf8))
        try channel.closeFuture.wait()
    }

    /// Background-friendly variant: tries to bind on a detached thread,
    /// silently no-ops if the port is already taken (i.e. another daemon is
    /// already serving). For Crier.app to embed the server without conflicting
    /// with a manually-launched `crier-daemon`.
    public static func startInBackground(host: String = "127.0.0.1", port: Int = 8731) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try run(host: host, port: port)
            } catch {
                FileHandle.standardError.write(Data(
                    "crier-server: not starting embedded daemon (\(error)) — assuming an external daemon is serving \(host):\(port)\n".utf8
                ))
            }
        }
    }
}
