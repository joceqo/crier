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
