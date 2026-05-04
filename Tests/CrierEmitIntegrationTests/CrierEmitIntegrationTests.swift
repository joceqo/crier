import XCTest
import Foundation
@testable import CrierServer

// Integration tests for crier-emit as a subprocess.
// These tests spawn the actual crier-emit binary with synthetic inputs (no
// real Claude session needed) and verify the event arrives at a test server.
//
// Requires the binary to be built first: swift build --product crier-emit
final class CrierEmitIntegrationTests: XCTestCase {
    static let port = 8733
    static let base = "http://127.0.0.1:\(port)"
    nonisolated(unsafe) static var emitBinaryPath: String = ""

    override class func setUp() {
        super.setUp()
        // Find the built binary relative to the package root.
        let fm = FileManager.default
        let candidates = [
            ".build/debug/crier-emit",
            ".build/release/crier-emit",
        ]
        for rel in candidates {
            let abs = fm.currentDirectoryPath + "/" + rel
            if fm.fileExists(atPath: abs) { emitBinaryPath = abs; break }
        }
        if emitBinaryPath.isEmpty {
            // Also try the Xcode-derived build location.
            if let url = Bundle.allBundles
                .compactMap({ $0.url(forResource: "crier-emit", withExtension: nil) })
                .first {
                emitBinaryPath = url.path
            }
        }
        CrierServer.startInBackground(host: "127.0.0.1", port: port)
        Thread.sleep(forTimeInterval: 0.3)
    }

    // MARK: - Helpers

    /// Write a JSONL transcript file with one assistant entry.
    private func makeTranscript(message: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("crier-test-\(UUID().uuidString).jsonl")
        let entry: [String: Any] = [
            "type": "assistant",
            "message": ["content": message]
        ]
        let data = try JSONSerialization.data(withJSONObject: entry)
        try (data + Data("\n".utf8)).write(to: url)
        return url
    }

    /// Run crier-emit synchronously. Returns (exitCode, stdout, stderr).
    private func runEmit(
        agent: String,
        event: String,
        stdinPayload: [String: Any],
        extraEnv: [String: String] = [:]
    ) -> (Int32, String, String) {
        guard !Self.emitBinaryPath.isEmpty else {
            return (-1, "", "crier-emit binary not found — run `swift build --product crier-emit` first")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.emitBinaryPath)
        p.arguments = [agent, event]

        var env = ProcessInfo.processInfo.environment
        env["CRIER_PORT"] = "\(Self.port)"
        for (k, v) in extraEnv { env[k] = v }
        p.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = stdoutPipe
        p.standardError = stderrPipe

        let payload = (try? JSONSerialization.data(withJSONObject: stdinPayload)) ?? Data()
        stdinPipe.fileHandleForWriting.write(payload)
        stdinPipe.fileHandleForWriting.closeFile()

        try? p.run()
        p.waitUntilExit()

        let out = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, out, err)
    }

    /// Subscribe to the next event on the test server (long-poll).
    private func nextEvent(waitSeconds: Int = 10) -> [String: Any]? {
        guard let url = URL(string: "\(Self.base)/current?wait=\(waitSeconds)") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = TimeInterval(waitSeconds + 3)
        var result: [String: Any]?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let data, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                result = obj
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + TimeInterval(waitSeconds + 5))
        return result
    }

    // MARK: - Tests

    func testEmitClaudeCodeTurnDonePostsEvent() throws {
        guard !Self.emitBinaryPath.isEmpty else { throw XCTSkip("crier-emit binary not built") }

        let transcript = try makeTranscript(message: "Hello from integration test")
        let stdinPayload: [String: Any] = [
            "transcript_path": transcript.path,
            "session_id": "test-session-\(UUID().uuidString)",
            "cwd": "/tmp",
        ]

        // Register the long-poll BEFORE spawning crier-emit.
        var received: [String: Any]?
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            received = self.nextEvent(waitSeconds: 8)
            sem.signal()
        }
        Thread.sleep(forTimeInterval: 0.05)

        // Run crier-emit — it should POST the event and then block on /reply
        // (turn_done is blocking). We want it to time out quickly, so run in background.
        DispatchQueue.global().async {
            _ = self.runEmit(agent: "claude-code", event: "turn_done", stdinPayload: stdinPayload)
        }

        _ = sem.wait(timeout: .now() + 15)
        let event = try XCTUnwrap(received, "no event received from crier-emit")
        XCTAssertEqual(event["agent"] as? String, "claude-code")
        XCTAssertEqual(event["event"] as? String, "turn_done")
        XCTAssertEqual(event["message"] as? String, "Hello from integration test")
        XCTAssertEqual(event["cwd"] as? String, "/tmp")
    }

    /// Cursor hooks use `crier-emit cursor …`; message extraction matches Claude Code (transcript JSONL).
    func testEmitCursorTurnDoneReadsTranscript() throws {
        guard !Self.emitBinaryPath.isEmpty else { throw XCTSkip("crier-emit binary not built") }

        let transcript = try makeTranscript(message: "Cursor hook message")
        let stdinPayload: [String: Any] = [
            "transcript_path": transcript.path,
            "session_id": "cursor-session-\(UUID().uuidString)",
            "cwd": "/tmp/cursor",
        ]

        var received: [String: Any]?
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            received = self.nextEvent(waitSeconds: 8)
            sem.signal()
        }
        Thread.sleep(forTimeInterval: 0.05)

        DispatchQueue.global().async {
            _ = self.runEmit(agent: "cursor", event: "turn_done", stdinPayload: stdinPayload)
        }

        _ = sem.wait(timeout: .now() + 15)
        let event = try XCTUnwrap(received, "no event received")
        XCTAssertEqual(event["agent"] as? String, "cursor")
        XCTAssertEqual(event["message"] as? String, "Cursor hook message")
        XCTAssertEqual(event["cwd"] as? String, "/tmp/cursor")
    }

    /// Same transcript path as Claude/Cursor for setups that invoke `crier-emit opencode` (OpenCode npm plugin posts to /event directly; this covers CLI parity).
    func testEmitOpenCodeTurnDoneReadsTranscript() throws {
        guard !Self.emitBinaryPath.isEmpty else { throw XCTSkip("crier-emit binary not built") }

        let transcript = try makeTranscript(message: "OpenCode transcript path")
        let stdinPayload: [String: Any] = [
            "transcript_path": transcript.path,
            "session_id": "oc-session-\(UUID().uuidString)",
            "cwd": "/tmp/opencode",
        ]

        var received: [String: Any]?
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            received = self.nextEvent(waitSeconds: 8)
            sem.signal()
        }
        Thread.sleep(forTimeInterval: 0.05)

        DispatchQueue.global().async {
            _ = self.runEmit(agent: "opencode", event: "turn_done", stdinPayload: stdinPayload)
        }

        _ = sem.wait(timeout: .now() + 15)
        let event = try XCTUnwrap(received, "no event received")
        XCTAssertEqual(event["agent"] as? String, "opencode")
        XCTAssertEqual(event["message"] as? String, "OpenCode transcript path")
    }

    func testEmitCodexTurnDoneUsesLastAssistantMessageFromStdin() throws {
        guard !Self.emitBinaryPath.isEmpty else { throw XCTSkip("crier-emit binary not built") }

        let stdinPayload: [String: Any] = [
            "last_assistant_message": "Codex says hi",
            "session_id": "codex-session-\(UUID().uuidString)",
            "cwd": "/tmp/codex",
        ]

        var received: [String: Any]?
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            received = self.nextEvent(waitSeconds: 8)
            sem.signal()
        }
        Thread.sleep(forTimeInterval: 0.05)

        DispatchQueue.global().async {
            _ = self.runEmit(agent: "codex", event: "turn_done", stdinPayload: stdinPayload)
        }

        _ = sem.wait(timeout: .now() + 15)
        let event = try XCTUnwrap(received, "no event received")
        XCTAssertEqual(event["agent"] as? String, "codex")
        XCTAssertEqual(event["message"] as? String, "Codex says hi")
    }

    func testEmitCodexNeedsPermissionIsNonBlocking() throws {
        guard !Self.emitBinaryPath.isEmpty else { throw XCTSkip("crier-emit binary not built") }

        let stdinPayload: [String: Any] = [
            "last_assistant_message": "Codex needs ok",
            "session_id": "codex-perm-\(UUID().uuidString)",
            "cwd": "/tmp",
        ]

        var received: [String: Any]?
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            received = self.nextEvent(waitSeconds: 8)
            sem.signal()
        }
        Thread.sleep(forTimeInterval: 0.05)

        let start = Date()
        let (code, _, _) = runEmit(agent: "codex", event: "needs_permission", stdinPayload: stdinPayload)
        let elapsed = Date().timeIntervalSince(start)

        _ = sem.wait(timeout: .now() + 10)
        XCTAssertEqual(code, 0)
        XCTAssertLessThan(elapsed, 5, "needs_permission should not block")
        let event = try XCTUnwrap(received)
        XCTAssertEqual(event["agent"] as? String, "codex")
        XCTAssertEqual(event["event"] as? String, "needs_permission")
        XCTAssertEqual(event["message"] as? String, "Codex needs ok")
    }

    func testEmitNeedsPermissionIsNonBlockingAndPostsEvent() throws {
        guard !Self.emitBinaryPath.isEmpty else { throw XCTSkip("crier-emit binary not built") }

        let transcript = try makeTranscript(message: "asking for permission")
        let stdinPayload: [String: Any] = [
            "transcript_path": transcript.path,
            "session_id": "perm-\(UUID().uuidString)",
            "cwd": "/tmp",
        ]

        var received: [String: Any]?
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            received = self.nextEvent(waitSeconds: 8)
            sem.signal()
        }
        Thread.sleep(forTimeInterval: 0.05)

        // needs_permission is non-blocking — crier-emit should exit quickly.
        let start = Date()
        let (code, _, _) = runEmit(agent: "claude-code", event: "needs_permission", stdinPayload: stdinPayload)
        let elapsed = Date().timeIntervalSince(start)

        _ = sem.wait(timeout: .now() + 10)
        XCTAssertEqual(code, 0)
        XCTAssertLessThan(elapsed, 5, "needs_permission hook should exit quickly, not block")
        let event = try XCTUnwrap(received)
        XCTAssertEqual(event["event"] as? String, "needs_permission")
    }

/// Same reply/decision:block path as Claude; Cursor `stop` hook uses the first arg `cursor`.
    func testEmitCursorTurnDoneDeliversReplyViaHookStdout() throws {
        try runHookStdoutReplyRoundTrip(agent: "cursor", replyText: "two")
    }

    /// Claude Code reply round-trip via hook-stdout. Previously excluded
    /// from the blocking path; restored once we confirmed (via Superwhisper)
    /// that Claude Code's Stop hook does respect synchronous decision:block.
    /// This test is the regression guard for that change.
    func testEmitClaudeCodeTurnDoneDeliversReplyViaHookStdout() throws {
        try runHookStdoutReplyRoundTrip(agent: "claude-code", replyText: "claude-reply")
    }

    func testEmitCodexTurnDoneDeliversReplyViaHookStdout() throws {
        // Codex uses TOML-config hooks invoking `crier-emit codex turn_done`.
        // last_assistant_message arrives via stdin (no transcript file).
        try runHookStdoutReplyRoundTrip(
            agent: "codex",
            replyText: "codex-reply",
            stdinPayload: [
                "last_assistant_message": "Codex says hi",
                "session_id": "codex-reply-\(UUID().uuidString)",
                "cwd": "/tmp/codex",
            ]
        )
    }

    func testEmitOpenCodeTurnDoneDeliversReplyViaHookStdout() throws {
        // CLI parity path: setups invoking `crier-emit opencode` directly
        // (not via the npm plugin which posts to /event itself).
        try runHookStdoutReplyRoundTrip(agent: "opencode", replyText: "opencode-reply")
    }

    /// Drives the full hook-stdout reply round-trip for an agent:
    ///   1. spawn crier-emit; it POSTs an event with a request_id and blocks
    ///      on /reply long-poll
    ///   2. test reads the request_id off the event
    ///   3. test POSTs /reply (mimicking what the UI does on submit)
    ///   4. crier-emit unblocks and prints `{"decision":"block","reason":...}`
    ///   5. assert the reply text round-tripped into the decision JSON
    private func runHookStdoutReplyRoundTrip(
        agent: String,
        replyText: String,
        stdinPayload: [String: Any]? = nil
    ) throws {
        guard !Self.emitBinaryPath.isEmpty else { throw XCTSkip("crier-emit binary not built") }

        let payload: [String: Any]
        if let stdinPayload {
            payload = stdinPayload
        } else {
            let transcript = try makeTranscript(message: "\(agent): what is 1+1?")
            payload = [
                "transcript_path": transcript.path,
                "session_id": "\(agent)-reply-\(UUID().uuidString)",
                "cwd": "/tmp",
            ]
        }

        var received: [String: Any]?
        let eventSem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            received = self.nextEvent(waitSeconds: 10)
            eventSem.signal()
        }
        Thread.sleep(forTimeInterval: 0.05)

        var emitOutput = ""
        let emitSem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let (_, stdout, _) = self.runEmit(agent: agent, event: "turn_done", stdinPayload: payload)
            emitOutput = stdout
            emitSem.signal()
        }

        _ = eventSem.wait(timeout: .now() + 15)
        guard let receivedRequestId = received?["request_id"] as? String else {
            return XCTFail("[\(agent)] event missing request_id")
        }
        XCTAssertEqual(received?["agent"] as? String, agent)

        guard let replyURL = URL(string: "\(Self.base)/reply") else { return }
        var req = URLRequest(url: replyURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "request_id": receivedRequestId,
            "text": replyText,
            "channel": "hook-stdout",
        ])
        req.timeoutInterval = 5
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, _, _ in sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 6)

        _ = emitSem.wait(timeout: .now() + 10)
        let parsed = (try? JSONSerialization.jsonObject(with: Data(emitOutput.utf8))) as? [String: Any]
        XCTAssertEqual(parsed?["decision"] as? String, "block", "[\(agent)] expected decision:block")
        let reason = parsed?["reason"] as? String ?? ""
        XCTAssertTrue(reason.contains(replyText), "[\(agent)] reason should contain the reply text, got: \(reason)")
    }

    func testEmitRespectsGlobalDisableFlag() throws {
        guard !Self.emitBinaryPath.isEmpty else { throw XCTSkip("crier-emit binary not built") }

        let flagPath = "/tmp/crier-agent/disabled-global"
        try FileManager.default.createDirectory(
            atPath: "/tmp/crier-agent",
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: flagPath, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: flagPath) }

        let (code, stdout, _) = runEmit(
            agent: "claude-code",
            event: "turn_done",
            stdinPayload: ["cwd": "/tmp", "session_id": "disabled-test"]
        )
        XCTAssertEqual(code, 0)
        XCTAssertTrue(stdout.isEmpty, "globally disabled: should produce no stdout")
    }
}
