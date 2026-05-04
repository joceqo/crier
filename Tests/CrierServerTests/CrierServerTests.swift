import XCTest
import Foundation
@testable import CrierServer

// Functional tests for the CrierServer HTTP layer.
// Uses a dedicated port (8732) to avoid conflicts with a live crier-daemon on 8731.
// The server is started once for the whole class; tests use unique request_ids to
// avoid cross-test state leakage in ReplyHub.
final class CrierServerTests: XCTestCase {
    static let port = 8732
    static let base = "http://127.0.0.1:\(port)"

    override class func setUp() {
        super.setUp()
        CrierServer.startInBackground(host: "127.0.0.1", port: port)
        // Give NIO time to bind before any test sends requests.
        Thread.sleep(forTimeInterval: 0.3)
    }

    // MARK: - Helpers

    @discardableResult
    private func post(_ path: String, body: [String: Any] = [:]) -> (Data, HTTPURLResponse)? {
        guard let url = URL(string: Self.base + path),
              let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = bodyData
        req.timeoutInterval = 5
        return syncRequest(req)
    }

    private func get(_ path: String, timeout: TimeInterval = 5) -> (Data, HTTPURLResponse)? {
        guard let url = URL(string: Self.base + path) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        return syncRequest(req)
    }

    private func syncRequest(_ req: URLRequest) -> (Data, HTTPURLResponse)? {
        var result: (Data, HTTPURLResponse)?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, response, _ in
            if let data, let http = response as? HTTPURLResponse {
                result = (data, http)
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + req.timeoutInterval + 2)
        return result
    }

    // MARK: - Tests

    func testHealthz() {
        guard let (data, resp) = get("/healthz") else { return XCTFail("no response") }
        XCTAssertEqual(resp.statusCode, 200)
        let body = String(data: data, encoding: .utf8)
        XCTAssertEqual(body, #"{"ok":true}"#)
    }

    func testPostEventReturnsOk() {
        guard let (data, resp) = post("/event", body: ["agent": "codex", "event": "turn_done"]) else {
            return XCTFail("no response")
        }
        XCTAssertEqual(resp.statusCode, 200)
        let body = String(data: data, encoding: .utf8)
        XCTAssertEqual(body, #"{"ok":true}"#)
    }

    func testUnknownRouteReturns404() {
        guard let (_, resp) = get("/nope") else { return XCTFail("no response") }
        XCTAssertEqual(resp.statusCode, 404)
    }

    func testGetReplyWithoutRequestIdReturns400() {
        guard let (_, resp) = get("/reply") else { return XCTFail("no response") }
        XCTAssertEqual(resp.statusCode, 400)
    }

    func testReplyCorrelationWaiterFirst() {
        let rid = UUID().uuidString
        var waiterResult: (Data, HTTPURLResponse)?
        let sem = DispatchSemaphore(value: 0)

        // Register long-poll first.
        DispatchQueue.global().async {
            waiterResult = self.get("/reply?request_id=\(rid)&wait=5", timeout: 8)
            sem.signal()
        }

        // Small delay so the waiter is registered before the reply arrives.
        Thread.sleep(forTimeInterval: 0.1)
        post("/reply", body: ["request_id": rid, "text": "hello from test"])

        _ = sem.wait(timeout: .now() + 10)
        guard let (data, resp) = waiterResult else { return XCTFail("no waiter response") }
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "hello from test")
    }

    func testReplyCorrelationDeliverFirst() {
        let rid = UUID().uuidString
        // Deliver before anyone is waiting — reply parks in pending map.
        post("/reply", body: ["request_id": rid, "text": "parked reply"])
        // Late waiter should get it immediately.
        guard let (data, resp) = get("/reply?request_id=\(rid)&wait=2", timeout: 5) else {
            return XCTFail("no response")
        }
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "parked reply")
    }

    func testReplyTimeoutReturns204() {
        let rid = UUID().uuidString
        guard let (_, resp) = get("/reply?request_id=\(rid)&wait=1", timeout: 5) else {
            return XCTFail("no response")
        }
        XCTAssertEqual(resp.statusCode, 204)
    }

    func testCurrentLongPollReceivesEvent() {
        var pollResult: (Data, HTTPURLResponse)?
        let sem = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            pollResult = self.get("/current?wait=5", timeout: 8)
            sem.signal()
        }

        Thread.sleep(forTimeInterval: 0.1)
        let eventBody: [String: Any] = ["agent": "cursor", "event": "needs_input", "message": "pick a file"]
        post("/event", body: eventBody)

        _ = sem.wait(timeout: .now() + 10)
        guard let (data, resp) = pollResult else { return XCTFail("no poll response") }
        XCTAssertEqual(resp.statusCode, 200)
        // Response body should be the JSON we posted to /event.
        let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        XCTAssertEqual(parsed?["agent"] as? String, "cursor")
        XCTAssertEqual(parsed?["message"] as? String, "pick a file")
    }

    /// No waiter: event is queued; the next GET /current returns it without waiting for a new publish.
    func testCurrentPollDrainsQueuedEvent() {
        post("/event", body: ["agent": "opencode", "event": "turn_done", "message": "queued once"])

        guard let (data, resp) = get("/current?wait=5", timeout: 8) else {
            return XCTFail("no response")
        }
        XCTAssertEqual(resp.statusCode, 200)
        let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        XCTAssertEqual(parsed?["agent"] as? String, "opencode")
        XCTAssertEqual(parsed?["message"] as? String, "queued once")
    }

    /// Shape from `packages/opencode-plugin`: POST /event then long-poll /reply on request_id.
    /// This only asserts the daemon accepts the payload and UI/daemon reply pairing works.
    func testOpenCodeShapedReplyLongPoll() {
        let rid = UUID().uuidString
        var waiterResult: (Data, HTTPURLResponse)?
        let sem = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            waiterResult = self.get("/reply?request_id=\(rid)&wait=6", timeout: 10)
            sem.signal()
        }

        Thread.sleep(forTimeInterval: 0.1)
        let postBody: [String: Any] = [
            "agent": "opencode",
            "event": "turn_done",
            "session_id": "oc-test-session",
            "cwd": "/tmp/opencode",
            "request_id": rid,
            "reply_channel": "http-poll",
            "reply_target": rid,
            "message": "",
            "ts": ISO8601DateFormatter().string(from: Date()),
        ]
        post("/event", body: postBody)
        post("/reply", body: ["request_id": rid, "text": "user typed reply", "channel": "http-poll"])

        _ = sem.wait(timeout: .now() + 12)
        guard let (data, resp) = waiterResult else { return XCTFail("no waiter response") }
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "user typed reply")
    }

    func testCurrentTimeoutReturns204() {
        // Nobody publishes an event, so the long-poll times out.
        guard let (_, resp) = get("/current?wait=1", timeout: 5) else {
            return XCTFail("no response")
        }
        XCTAssertEqual(resp.statusCode, 204)
    }

    // MARK: - pre-queue (/reply/queue, /reply/engage, /reply/drain)

    /// Reply queued before any drain parks → the next drain returns it
    /// immediately. Mirrors Superwhisper's "user pre-talked, hook drains"
    /// case.
    func testReplyQueueDrainImmediate() {
        let sid = "test-queue-immediate-\(UUID().uuidString)"
        post("/reply/queue", body: ["session_id": sid, "text": "hello queue"])
        guard let (data, resp) = get("/reply/drain?session_id=\(sid)&wait_ms=500", timeout: 3) else {
            return XCTFail("no response")
        }
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "hello queue")
    }

    /// Drain parks first, then a queue POST wakes it.
    func testReplyDrainWaitsForQueue() {
        let sid = "test-drain-waits-\(UUID().uuidString)"
        var drainResult: (Data, HTTPURLResponse)?
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            drainResult = self.get("/reply/drain?session_id=\(sid)&wait_ms=2000", timeout: 4)
            sem.signal()
        }
        Thread.sleep(forTimeInterval: 0.1)
        post("/reply/queue", body: ["session_id": sid, "text": "lands while waiting"])

        _ = sem.wait(timeout: .now() + 5)
        guard let (data, resp) = drainResult else { return XCTFail("no response") }
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "lands while waiting")
    }

    /// /reply/engage extends a drain past its initial window. Without the
    /// engage POST, the 300 ms drain would time out before the 800 ms-late
    /// queue arrives.
    func testReplyDrainEngageExtends() {
        let sid = "test-drain-engage-\(UUID().uuidString)"
        var drainResult: (Data, HTTPURLResponse)?
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            drainResult = self.get("/reply/drain?session_id=\(sid)&wait_ms=300", timeout: 5)
            sem.signal()
        }
        Thread.sleep(forTimeInterval: 0.1)
        post("/reply/engage", body: ["session_id": sid, "extend_seconds": 3])
        // Land the queue text well after the original 300 ms window
        // would have lapsed — must still be delivered.
        Thread.sleep(forTimeInterval: 0.8)
        post("/reply/queue", body: ["session_id": sid, "text": "delivered after engage"])

        _ = sem.wait(timeout: .now() + 6)
        guard let (data, resp) = drainResult else { return XCTFail("no response") }
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "delivered after engage")
    }

    /// No queue, no engage → drain returns 204 after the base wait.
    func testReplyDrainTimeoutReturns204() {
        let sid = "test-drain-timeout-\(UUID().uuidString)"
        guard let (_, resp) = get("/reply/drain?session_id=\(sid)&wait_ms=200", timeout: 3) else {
            return XCTFail("no response")
        }
        XCTAssertEqual(resp.statusCode, 204)
    }

    /// /reply/dismiss must release a parked drain immediately, even if a
    /// long engage extension is still in flight. Without this, a sync
    /// claude-code Stop hook would keep the terminal blocked for the rest
    /// of the engage window after the user clicked Dismiss.
    func testReplyDismissReleasesParkedDrain() {
        let sid = "test-drain-dismiss-\(UUID().uuidString)"
        var drainResult: (Data, HTTPURLResponse)?
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            drainResult = self.get("/reply/drain?session_id=\(sid)&wait_ms=2000", timeout: 4)
            sem.signal()
        }
        Thread.sleep(forTimeInterval: 0.1)
        // Long engage so the drain wouldn't time out on its own in time.
        post("/reply/engage", body: ["session_id": sid, "extend_seconds": 30])
        Thread.sleep(forTimeInterval: 0.05)
        post("/reply/dismiss", body: ["session_id": sid])

        _ = sem.wait(timeout: .now() + 4)
        guard let (_, resp) = drainResult else { return XCTFail("no response") }
        XCTAssertEqual(resp.statusCode, 204)
    }

    /// POST /event with event=="dismiss" must drop any pending queued reply
    /// for that session — UserPromptSubmit firing means the user moved on,
    /// and a stale queue would otherwise fire on the next turn.
    func testDismissEventClearsPendingQueue() {
        let sid = "test-dismiss-clears-\(UUID().uuidString)"
        post("/reply/queue", body: ["session_id": sid, "text": "stale"])
        // dismiss event arrives — should wipe the queued text.
        post("/event", body: ["agent": "claude-code", "event": "dismiss", "session_id": sid])
        // Drain should now time out instead of returning the stale text.
        guard let (_, resp) = get("/reply/drain?session_id=\(sid)&wait_ms=200", timeout: 3) else {
            return XCTFail("no response")
        }
        XCTAssertEqual(resp.statusCode, 204)
    }

    /// Empty queue text is dropped — UI's "Send" button is already disabled
    /// when the draft is empty, but a stray POST must not fire a phantom
    /// decision:block.
    func testReplyQueueDropsEmptyText() {
        let sid = "test-queue-empty-\(UUID().uuidString)"
        post("/reply/queue", body: ["session_id": sid, "text": ""])
        guard let (_, resp) = get("/reply/drain?session_id=\(sid)&wait_ms=200", timeout: 3) else {
            return XCTFail("no response")
        }
        XCTAssertEqual(resp.statusCode, 204)
    }

    /// End-to-end: POST /reply with channel=tmux must run `tmux send-keys` and
    /// land the text inside the target pane. Spawns a real detached tmux
    /// session running `cat` so keystrokes echo back into the pane buffer,
    /// which we then read with `tmux capture-pane`.
    func testTmuxReplyDeliversTextToPane() throws {
        guard let tmux = which("tmux") else {
            throw XCTSkip("tmux not installed — skipping tmux delivery test")
        }

        let session = "crier-test-\(UUID().uuidString.prefix(8))"
        defer { _ = run(tmux, ["kill-session", "-t", session]) }

        // Detached session running `cat`: stdin echoes to stdout, so anything
        // send-keys posts shows up in the pane buffer.
        let (newRC, _, newErr) = run(tmux, ["new-session", "-d", "-s", session, "cat"])
        guard newRC == 0 else {
            return XCTFail("tmux new-session failed: \(newErr)")
        }
        // Let `cat` settle so it's actually reading stdin before we send keys.
        Thread.sleep(forTimeInterval: 0.2)

        let payload = "hello-from-tmux-test-\(UUID().uuidString.prefix(6))"
        guard let (_, resp) = post("/reply", body: [
            "channel": "tmux",
            "target": session,
            "text": payload,
        ]) else { return XCTFail("no response from /reply") }
        XCTAssertEqual(resp.statusCode, 200)

        // handlePostReply dispatches send-keys on a background queue, so give
        // it a moment to run both the literal-text and the Enter call.
        var captured = ""
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            let (_, out, _) = run(tmux, ["capture-pane", "-p", "-t", session])
            if out.contains(payload) { captured = out; break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(
            captured.contains(payload),
            "tmux pane never received the reply text. capture-pane output:\n\(captured)"
        )
    }

    // MARK: - shell helpers (tmux test)

    private func which(_ tool: String) -> String? {
        let candidates = ["/opt/homebrew/bin/\(tool)", "/usr/local/bin/\(tool)", "/usr/bin/\(tool)"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        return nil
    }

    private func run(_ exe: String, _ args: [String]) -> (Int32, String, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        do { try p.run() } catch { return (-1, "", "\(error)") }
        p.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, out, err)
    }
}
