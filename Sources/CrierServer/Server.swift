import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import CrierEmitCore

// CrierServer — local HTTP server reused by `crier-daemon` (CLI) and `Crier.app`
// (UI process embeds it so launching the app starts the server in-process).
//
//   POST /event              intake from hook adapters (logged + broadcast).
//                            event=="dismiss" also clears any queued reply
//                            and engage flag for that session_id (the user
//                            moved on by typing in the terminal directly).
//   POST /reply              legacy delivery keyed by request_id — wakes
//                            long-poll waiter for cursor/codex/opencode and
//                            runs `tmux send-keys` for channel="tmux".
//   GET  /reply?request_id=X&wait=N
//                            legacy long-poll for non-claude-code agents.
//   POST /reply/queue        Pre-queue architecture (mirrors Superwhisper's
//                            file-IPC pattern). Body: {session_id, text}.
//                            Stores text for that session; wakes any waiter.
//                            UI hits this when the user clicks Send.
//   POST /reply/engage       Body: {session_id, extend_seconds?}. Bumps the
//                            session's "user is engaging" deadline so a
//                            concurrent /reply/drain extends its wait. UI
//                            hits this on the user's first keystroke per
//                            turn.
//   POST /reply/dismiss      Body: {session_id}. Clears the queued reply
//                            and engage flag, releases any parked drain
//                            with no content. UI hits this on Esc/Dismiss
//                            so the hook doesn't keep the terminal blocked
//                            for the rest of the engage window.
//   GET  /reply/drain?session_id=X&wait_ms=N
//                            Hook-side blocking probe. Returns immediately
//                            if a queued reply is present, otherwise waits
//                            up to wait_ms (extended while engage_until is
//                            in the future). 204 on final timeout.
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

    /// Number of UI clients currently long-polling /current. Used by
    /// crier-emit to decide whether the TTY readline fallback should
    /// activate — if a UI is connected, the overlay handles the reply
    /// and the TTY race would only leak terminal escape sequences.
    func subscriberCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
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

// MARK: - EventDedup
//
// Some agent stop hooks fire BOTH for one logical turn — most commonly
// when cursor-agent runs and `~/.cursor/hooks.json` `stop` AND
// `~/.claude/settings.json` `Stop` both fire at the same wall-clock
// second with identical `transcript_path`. Without dedup the user sees
// two overlays per turn and one of the hooks deadlocks at the 9-minute
// drain ceiling because the UI's reply only routes to one of the two
// session_ids.
//
// Rules:
//   - Window: 2 seconds. Real double-emits fire within the same wall-clock
//     second; legitimate back-to-back turns rarely complete that fast.
//   - Key: (transcript_path, event) when transcript_path is present;
//     (session_id, event) as fallback (codex-style payloads). Using
//     transcript_path is essential because the duplicate hooks produce
//     *different* session_ids (`<agent>-<rawSessionId>`).
//   - Whitelist: only turn_done / needs_permission / needs_input are
//     deduped. dismiss must always pass through (each hook needs its own
//     queue cleared).
//   - First wins. The duplicate POST /event is dropped (no broadcast),
//     and its session_id + request_id are flagged so its drain or legacy
//     long-poll returns 204 immediately. The subordinate hook exits clean
//     without decision:block; the agent unblocks normally.
//   - GC on every shouldPublish; hard cap of 256 in-flight primaries.
//
// Internal (not private) so @testable import can call reset() between
// test cases.
final class EventDedup: @unchecked Sendable {
    static let shared = EventDedup()
    private let lock = NSLock()

    private struct Entry {
        let primarySession: String
        let primaryRequestId: String?
        let deadline: Date
    }
    private var primaries: [String: Entry] = [:]
    private var subordinateSessions: [String: Date] = [:]
    private var subordinateRequestIds: [String: Date] = [:]

    private static let windowSeconds: TimeInterval = 2.0
    private static let maxPrimaries = 256
    private static let dedupedEvents: Set<String> = ["turn_done", "needs_permission", "needs_input"]

    /// Decide whether a POST /event should be broadcast. Returns false
    /// when the call is a duplicate within the window — in that case the
    /// duplicate's session_id and request_id are flagged for short-circuit
    /// in subsequent drain/long-poll handlers.
    func shouldPublish(
        transcriptPath: String?,
        event: String,
        sessionId: String,
        requestId: String?
    ) -> Bool {
        guard EventDedup.dedupedEvents.contains(event) else { return true }
        guard let key = dedupKey(transcriptPath: transcriptPath, sessionId: sessionId, event: event) else {
            return true
        }

        lock.lock()
        defer { lock.unlock() }
        gcLocked()

        let now = Date()
        if let existing = primaries[key], existing.deadline > now {
            if existing.primarySession != sessionId, !sessionId.isEmpty {
                subordinateSessions[sessionId] = existing.deadline
            }
            if let rid = requestId, !rid.isEmpty,
               existing.primaryRequestId != rid {
                subordinateRequestIds[rid] = existing.deadline
            }
            return false
        }
        primaries[key] = Entry(
            primarySession: sessionId,
            primaryRequestId: requestId,
            deadline: now.addingTimeInterval(EventDedup.windowSeconds)
        )
        return true
    }

    func isSubordinateSession(_ sessionId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let d = subordinateSessions[sessionId] else { return false }
        if d <= Date() {
            subordinateSessions.removeValue(forKey: sessionId)
            return false
        }
        return true
    }

    func isSubordinateRequestId(_ requestId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let d = subordinateRequestIds[requestId] else { return false }
        if d <= Date() {
            subordinateRequestIds.removeValue(forKey: requestId)
            return false
        }
        return true
    }

    /// Test-only: clear all dedup state. The shared singleton is reused
    /// across server-test cases, so each test that depends on dedup
    /// behavior calls this in its setUp.
    func reset() {
        lock.lock()
        primaries.removeAll()
        subordinateSessions.removeAll()
        subordinateRequestIds.removeAll()
        lock.unlock()
    }

    private func dedupKey(transcriptPath: String?, sessionId: String, event: String) -> String? {
        if let tp = transcriptPath, !tp.isEmpty {
            return "tp:\(tp)|\(event)"
        }
        if !sessionId.isEmpty, sessionId != "?" {
            return "sid:\(sessionId)|\(event)"
        }
        return nil
    }

    private func gcLocked() {
        let now = Date()
        primaries = primaries.filter { $0.value.deadline > now }
        subordinateSessions = subordinateSessions.filter { $0.value > now }
        subordinateRequestIds = subordinateRequestIds.filter { $0.value > now }
        if primaries.count > EventDedup.maxPrimaries {
            let trim = primaries.count - EventDedup.maxPrimaries
            let toDrop = primaries
                .sorted { $0.value.deadline < $1.value.deadline }
                .prefix(trim)
                .map { $0.key }
            for k in toDrop { primaries.removeValue(forKey: k) }
        }
    }
}

// MARK: - ReplyQueueHub
//
// Pre-queue architecture (see crier-prequeue-architecture.md). Mirrors
// Superwhisper's claude-hook IPC pattern: the user can "queue" a reply
// independently of the hook firing, the hook drains the queue with a short
// initial wait, and the wait can be extended on demand while the user is
// actively typing in the overlay. Result: terminal stays free, no fixed
// 540 s ceiling, and decision:block only fires when there's actually a
// reply to deliver.
//
// State per session_id:
//   - `queued`: a reply text waiting to be drained (Send was clicked but
//     no GET /reply/drain was parked yet, or the user pre-queued during
//     the agent's turn).
//   - `engageUntil`: a future Date at which the "user is engaging" hint
//     expires. /reply/drain extends its wait up to this deadline whenever
//     it would otherwise time out.
//
// Waiters (parked GET /reply/drain calls) are stored by their own UUID so
// multiple in-flight drains for the same session (rare; can happen during
// rapid Stop hook re-fires) all wake on the same deliver().
private final class ReplyQueueHub: @unchecked Sendable {
    static let shared = ReplyQueueHub()
    private let lock = NSLock()
    private var queued: [String: String] = [:]
    private var engageUntil: [String: Date] = [:]
    private var waiters: [UUID: (sessionId: String, promise: EventLoopPromise<String?>)] = [:]

    /// Store a reply for later drain, OR wake any drain currently parked
    /// for this session. Empty `text` is treated as "no reply" (matches
    /// the UI's Send-disabled-when-empty contract) and is dropped silently
    /// so a stray POST can't fire a phantom decision:block.
    @discardableResult
    func deliver(sessionId: String, text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        lock.lock()
        let matching = waiters.filter { $0.value.sessionId == sessionId }
        for k in matching.keys { waiters.removeValue(forKey: k) }
        if matching.isEmpty {
            queued[sessionId] = text
        } else {
            // A waiter is taking it — drop any stale queued copy so it
            // isn't double-delivered on the next drain.
            queued.removeValue(forKey: sessionId)
        }
        lock.unlock()
        for (_, w) in matching { w.promise.succeed(text) }
        return matching.count
    }

    /// Bump the "user is engaging" deadline. Idempotent — a later engage
    /// with a smaller extension does not retract the longer one already
    /// in flight. The UI calls this once per keystroke (debounced) so the
    /// hook keeps waiting as long as the user is typing.
    func engage(sessionId: String, extendSeconds: Int) {
        let until = Date().addingTimeInterval(TimeInterval(extendSeconds))
        lock.lock()
        if (engageUntil[sessionId] ?? .distantPast) < until {
            engageUntil[sessionId] = until
        }
        lock.unlock()
    }

    /// Clear queue + engage flag and release any parked waiter with nil.
    /// Triggered on event=="dismiss" (UserPromptSubmit — user moved on)
    /// and on Esc/Dismiss in the overlay.
    func clear(sessionId: String) {
        lock.lock()
        queued.removeValue(forKey: sessionId)
        engageUntil.removeValue(forKey: sessionId)
        let matching = waiters.filter { $0.value.sessionId == sessionId }
        for k in matching.keys { waiters.removeValue(forKey: k) }
        lock.unlock()
        for (_, w) in matching { w.promise.succeed(nil) }
    }

    /// Park until a queued reply is delivered or the wait deadline lapses.
    /// The deadline starts at `baseTimeoutMs` and slides forward to
    /// `engageUntil` whenever the original timer fires while engagement
    /// is still active.
    func awaitDrain(sessionId: String, eventLoop: EventLoop, baseTimeoutMs: Int) -> EventLoopFuture<String?> {
        lock.lock()
        if let text = queued.removeValue(forKey: sessionId) {
            lock.unlock()
            return eventLoop.makeSucceededFuture(text)
        }
        let waiterId = UUID()
        let promise = eventLoop.makePromise(of: String?.self)
        waiters[waiterId] = (sessionId, promise)
        lock.unlock()

        let initialDeadline = Date().addingTimeInterval(TimeInterval(baseTimeoutMs) / 1000.0)
        scheduleCheck(waiterId: waiterId, sessionId: sessionId, eventLoop: eventLoop, deadline: initialDeadline)
        return promise.futureResult
    }

    /// Recursive timer: when the current deadline fires, see whether the
    /// engage flag pushed the deadline further out and reschedule, or
    /// give up with nil.
    private func scheduleCheck(waiterId: UUID, sessionId: String, eventLoop: EventLoop, deadline: Date) {
        let now = Date()
        let delaySeconds = max(0.05, deadline.timeIntervalSince(now))
        eventLoop.scheduleTask(in: .milliseconds(Int64(delaySeconds * 1000))) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            // If deliver()/clear() already removed the waiter, do nothing.
            guard let waiter = self.waiters[waiterId] else {
                self.lock.unlock()
                return
            }
            if let until = self.engageUntil[sessionId], until > Date() {
                self.lock.unlock()
                self.scheduleCheck(waiterId: waiterId, sessionId: sessionId, eventLoop: eventLoop, deadline: until)
                return
            }
            self.waiters.removeValue(forKey: waiterId)
            self.lock.unlock()
            waiter.promise.succeed(nil)
        }
    }
}

// MARK: - HTTP handler

// `@unchecked Sendable` because NIO confines handler instances to their
// channel's event loop — `requestHead`/`bodyBuffer` are only ever touched
// from that single thread, and `whenComplete` callbacks hop back to the
// same loop. We need the conformance for ServerBootstrap's @Sendable
// childChannelInitializer and for capturing self in future callbacks.
private final class CrierHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
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

        case (.POST, "/reply/queue"):
            handlePostReplyQueue(body: bodyData)
            responseFuture = context.eventLoop.makeSucceededFuture((.ok, "application/json", #"{"ok":true}"#))

        case (.POST, "/reply/engage"):
            handlePostReplyEngage(body: bodyData)
            responseFuture = context.eventLoop.makeSucceededFuture((.ok, "application/json", #"{"ok":true}"#))

        case (.POST, "/reply/dismiss"):
            handlePostReplyDismiss(body: bodyData)
            responseFuture = context.eventLoop.makeSucceededFuture((.ok, "application/json", #"{"ok":true}"#))

        case (.POST, "/reply"):
            handlePostReply(body: bodyData)
            responseFuture = context.eventLoop.makeSucceededFuture((.ok, "application/json", #"{"ok":true}"#))

        // /reply/drain must be matched before the broader /reply prefix
        // below, otherwise it falls into handleGetReply.
        case (.GET, let uri) where uri.hasPrefix("/reply/drain"):
            responseFuture = handleGetReplyDrain(uri: uri, eventLoop: context.eventLoop)

        case (.GET, let uri) where uri.hasPrefix("/reply"):
            responseFuture = handleGetReply(uri: uri, eventLoop: context.eventLoop)

        case (.GET, let uri) where uri.hasPrefix("/current"):
            responseFuture = handleGetCurrent(uri: uri, eventLoop: context.eventLoop)

        case (.GET, "/healthz"):
            responseFuture = context.eventLoop.makeSucceededFuture((.ok, "application/json", #"{"ok":true}"#))

        case (.GET, "/status"):
            let n = EventHub.shared.subscriberCount()
            responseFuture = context.eventLoop.makeSucceededFuture((.ok, "application/json", #"{"ui_subscribers":\#(n)}"#))

        default:
            responseFuture = context.eventLoop.makeSucceededFuture((.notFound, "application/json", #"{"error":"not found"}"#))
        }

        let httpVersion = head.version
        // NIOLoopBound lets us carry the non-Sendable ChannelHandlerContext
        // into the @Sendable whenComplete callback — it asserts at runtime
        // that .value is only read on the original event loop, which is
        // exactly where whenComplete fires.
        let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        responseFuture.whenComplete { [weak self] result in
            guard let self else { return }
            let (status, contentType, body): (HTTPResponseStatus, String, String)
            switch result {
            case .success(let r): (status, contentType, body) = r
            case .failure: (status, contentType, body) = (.internalServerError, "application/json", #"{"error":"internal"}"#)
            }
            self.writeResponse(context: boundContext.value, requestVersion: httpVersion, status: status, contentType: contentType, body: body)
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
        let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.writeAndFlush(self.wrapOutboundOut(.end(nil))).whenComplete { _ in
            boundContext.value.close(promise: nil)
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
        let transcriptPath = parsed["transcript_path"] as? String

        // Dedup duplicate stop-hook fires (cursor + claude-code stop both
        // firing for one cursor turn; same transcript_path, different
        // session_ids). When this returns false the caller's drain/long-poll
        // will short-circuit via EventDedup.isSubordinate*, releasing the
        // subordinate hook without an extra overlay.
        let shouldPublish = EventDedup.shared.shouldPublish(
            transcriptPath: transcriptPath,
            event: event,
            sessionId: session,
            requestId: requestId
        )

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
        if !shouldPublish {
            line += "  dedup:   subordinate (transcript already in flight)\n"
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

        // UserPromptSubmit fires this event with kind "dismiss" — the user
        // moved on by typing in the agent's TTY directly, so any pre-queued
        // overlay reply is now stale and must not fire on the next turn.
        if event == "dismiss", session != "?" {
            ReplyQueueHub.shared.clear(sessionId: session)
        }

        if shouldPublish {
            EventHub.shared.publish(body)
        }
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
        // Subordinate of a deduped duplicate /event — short-circuit instead
        // of long-polling. The originating hook will exit clean without a
        // decision:block; the agent unblocks normally.
        if EventDedup.shared.isSubordinateRequestId(requestId) {
            return eventLoop.makeSucceededFuture((.noContent, "application/json", ""))
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

    // MARK: pre-queue handlers

    private func handlePostReplyQueue(body: Data) {
        let parsed = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        guard let session = parsed["session_id"] as? String, !session.isEmpty else { return }
        let text = parsed["text"] as? String ?? ""
        ReplyQueueHub.shared.deliver(sessionId: session, text: text)
        let preview = String(text.prefix(120))
        FileHandle.standardOutput.write(Data(
            "[\(isoFormatter.string(from: Date()))] reply/queue · \(session) · \(preview)\n".utf8
        ))
    }

    private func handlePostReplyDismiss(body: Data) {
        let parsed = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        guard let session = parsed["session_id"] as? String, !session.isEmpty else { return }
        ReplyQueueHub.shared.clear(sessionId: session)
    }

    private func handlePostReplyEngage(body: Data) {
        let parsed = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        guard let session = parsed["session_id"] as? String, !session.isEmpty else { return }
        // Default 30s window per engage call. UI is expected to call this
        // periodically while the user is typing; each call extends the
        // wait by another window. Cap at 540s just to avoid runaway waits.
        let raw = parsed["extend_seconds"] as? Int ?? 30
        let extend = max(1, min(540, raw))
        ReplyQueueHub.shared.engage(sessionId: session, extendSeconds: extend)
    }

    private func handleGetReplyDrain(uri: String, eventLoop: EventLoop) -> EventLoopFuture<(HTTPResponseStatus, String, String)> {
        guard let comps = URLComponents(string: "http://h\(uri)"),
              let session = comps.queryItems?.first(where: { $0.name == "session_id" })?.value,
              !session.isEmpty else {
            return eventLoop.makeSucceededFuture((.badRequest, "application/json", #"{"error":"missing session_id"}"#))
        }
        // Subordinate of a deduped duplicate /event — short-circuit so the
        // originating hook exits clean without a 9-min wait.
        if EventDedup.shared.isSubordinateSession(session) {
            return eventLoop.makeSucceededFuture((.noContent, "application/json", ""))
        }
        let waitMs = Int(comps.queryItems?.first(where: { $0.name == "wait_ms" })?.value ?? "3000") ?? 3000
        // Cap at 600 s. SW's claude-hook polls 300 s; we allow up to
        // double that so the engage extension has headroom and the
        // hook's `timeout: 540` (9 min) is the binding ceiling, not us.
        let clamped = max(50, min(600_000, waitMs))

        return ReplyQueueHub.shared.awaitDrain(sessionId: session, eventLoop: eventLoop, baseTimeoutMs: clamped).map { text in
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
