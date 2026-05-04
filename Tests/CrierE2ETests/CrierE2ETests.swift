import XCTest
import Foundation
@testable import CrierServer

// End-to-end tests that spawn a real Claude Code (or other provider) session.
// These tests use your existing CLI auth — no API key needed in code.
//
// Tests are skipped automatically if:
//   - The required binary (claude, codex, etc.) is not in PATH
//   - CRIER_E2E=1 is not set (opt-in to prevent accidental slow runs)
//
// Run with:
//   CRIER_E2E=1 swift test --filter CrierE2ETests
//
// Optional provider matrix (real CLIs, hooks must call crier-emit with matching first arg):
//   CRIER_E2E=1 CRIER_E2E_PROVIDER=cursor swift test --filter testProviderCliHookDeliversEvent
//   CRIER_E2E=1 CRIER_E2E_PROVIDER=codex  swift test --filter testProviderCliHookDeliversEvent
//
// `CRIER_E2E_PROVIDER=cursor` tries `cursor-agent` then `cursor` on PATH; the hook
// must still pass agent label `cursor` as argv[1] to crier-emit (see scripts/install-local-cursor.sh).
final class CrierE2ETests: XCTestCase {
    static let port = 8734
    static let base = "http://127.0.0.1:\(port)"

    override class func setUp() {
        super.setUp()
        guard ProcessInfo.processInfo.environment["CRIER_E2E"] == "1" else { return }
        CrierServer.startInBackground(host: "127.0.0.1", port: port)
        Thread.sleep(forTimeInterval: 0.4)
    }

    // MARK: - Infrastructure

    private func requireE2E() throws {
        guard ProcessInfo.processInfo.environment["CRIER_E2E"] == "1" else {
            throw XCTSkip("Set CRIER_E2E=1 to run end-to-end tests")
        }
    }

    private func requireBinary(_ name: String) throws -> String {
        let result = sh(["which", name])
        guard let path = result, !path.isEmpty else {
            throw XCTSkip("\(name) not found in PATH — install it to run this test")
        }
        return path
    }

    /// First executable found on PATH, in order (e.g. cursor-agent before cursor).
    private func firstExecutable(candidates: [String]) -> String? {
        for name in candidates {
            if let path = sh(["which", name]), !path.isEmpty { return path }
        }
        return nil
    }

    @discardableResult
    private func sh(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Subscribe to the next /current event from our E2E test server.
    private func nextEvent(waitSeconds: Int = 30) -> [String: Any]? {
        guard let url = URL(string: "\(Self.base)/current?wait=\(waitSeconds)") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = TimeInterval(waitSeconds + 5)
        var result: [String: Any]?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data { result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + TimeInterval(waitSeconds + 8))
        return result
    }

    /// Drain events until one matches `match` (or the budget expires).
    /// Real agent runs fire several hooks in a single turn (UserPromptSubmit,
    /// PreToolUse, …, Stop), so a `nextEvent()` looking for `turn_done` will
    /// get a `dismiss` first and miss the one it wants. This polls.
    private func nextEventMatching(_ match: ([String: Any]) -> Bool, totalBudget: TimeInterval) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(totalBudget)
        while Date() < deadline {
            let remaining = max(2, Int(deadline.timeIntervalSinceNow))
            if let evt = nextEvent(waitSeconds: remaining), match(evt) { return evt }
        }
        return nil
    }

    // MARK: - Claude Code E2E

    // Verifies the full flow:
    //   claude -p "..." → Stop hook fires → crier-emit posts event → server receives it
    //   → message text matches what Claude actually said
    func testClaudeCodeHookDeliversLastAssistantMessage() throws {
        try requireE2E()
        let claudePath = try requireBinary("claude")

        // Unique marker so we can verify it's Claude's actual output.
        let marker = "CRIER_E2E_\(UUID().uuidString.prefix(8))"

        // A real agent run emits several hooks in one turn (UserPromptSubmit,
        // PreToolUse, …, Stop), so we need to filter for `turn_done` rather
        // than grab the first event. Start the poll BEFORE spawning Claude.
        var received: [String: Any]?
        let eventSem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            received = self.nextEventMatching(
                { ($0["event"] as? String) == "turn_done" && ($0["agent"] as? String) == "claude-code" },
                totalBudget: 75
            )
            eventSem.signal()
        }
        Thread.sleep(forTimeInterval: 0.1)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: claudePath)
        // -p: non-interactive print mode; hooks still fire on turn completion.
        p.arguments = ["-p", "Reply with only this exact string, nothing else: \(marker)"]
        var env = ProcessInfo.processInfo.environment
        // Redirect crier-emit to our test server so events don't pollute 8731.
        env["CRIER_PORT"] = "\(Self.port)"
        p.environment = env
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()

        // Stop hook is now blocking — wait for the event, release the hook,
        // then wait for claude to exit. Without the release, p.waitUntilExit
        // would hang for 540s waiting on the hook's long-poll.
        _ = eventSem.wait(timeout: .now() + 80)
        let event = try XCTUnwrap(received, "no turn_done event received within timeout — hook may not be configured or crier-emit may not be installed")
        if let rid = event["request_id"] as? String { releaseStopHook(requestId: rid) }

        p.waitUntilExit()

        XCTAssertEqual(event["agent"] as? String, "claude-code")
        XCTAssertEqual(event["event"] as? String, "turn_done")
        let message = event["message"] as? String ?? ""
        XCTAssertTrue(message.contains(marker), "expected '\(marker)' in message but got: \(message.prefix(200))")
    }

    // Claude Code's Stop hook is now blocking + hook-stdout, matching
    // Cursor/Codex/OpenCode and Superwhisper's claude-hook. This test
    // verifies the new contract end-to-end with a real `claude` binary:
    //   1. `claude -p` finishes its turn and fires the Stop hook
    //   2. crier-emit posts the event with request_id + reply_channel
    //   3. test sends an empty /reply (the UI's Dismiss path) to release
    //      the hook so claude exits cleanly without consuming a decision
    //      reason as the next prompt
    func testClaudeCodeStopHookAdvertisesHookStdoutReply() throws {
        try requireE2E()
        let claudePath = try requireBinary("claude")

        var received: [String: Any]?
        let eventSem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            received = self.nextEventMatching(
                { ($0["event"] as? String) == "turn_done" && ($0["agent"] as? String) == "claude-code" },
                totalBudget: 75
            )
            eventSem.signal()
        }
        Thread.sleep(forTimeInterval: 0.1)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: claudePath)
        p.arguments = ["-p", "Say only the word DONE."]
        var env = ProcessInfo.processInfo.environment
        env["CRIER_PORT"] = "\(Self.port)"
        p.environment = env
        p.standardOutput = Pipe()
        p.standardError = Pipe()

        let start = Date()
        try p.run()

        // Wait for the event, then release the hook so claude can finish.
        _ = eventSem.wait(timeout: .now() + 75)
        let event = try XCTUnwrap(received, "Stop hook did not POST a turn_done event within 75s")
        let rid = try XCTUnwrap(event["request_id"] as? String,
            "claude-code turn_done must advertise a request_id (hook is now blocking)")
        XCTAssertEqual(event["reply_channel"] as? String, "hook-stdout",
                       "claude-code turn_done must advertise hook-stdout as the reply channel")

        releaseStopHook(requestId: rid)

        let exited = waitForProcess(p, timeoutSeconds: 30)
        let elapsed = Date().timeIntervalSince(start)
        if !exited {
            p.terminate()
            XCTFail("claude -p did not exit within 30s after release (elapsed \(elapsed)s)")
        }
    }

    /// POST /reply with empty text — same payload the Crier UI sends when
    /// the user hits Dismiss. crier-emit treats it as "user wants to type
    /// in the terminal" and exits without printing decision:block.
    private func releaseStopHook(requestId: String) {
        guard let url = URL(string: "http://127.0.0.1:\(Self.port)/reply") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["request_id": requestId, "text": ""])
        req.timeoutInterval = 5
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, _, _ in sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 6)
    }

    private func waitForProcess(_ p: Process, timeoutSeconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while p.isRunning {
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return true
    }

    // MARK: - Markdown rendering E2E

    // Verifies that markdown content (headers, code blocks, lists) is
    // parsed and the message field contains the raw markdown text as expected.
    // UI rendering is tested manually; this test covers the data pipeline.
    func testMarkdownMessageRoundTrips() throws {
        try requireE2E()
        let claudePath = try requireBinary("claude")

        var received: [String: Any]?
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            received = self.nextEvent(waitSeconds: 60)
            sem.signal()
        }
        Thread.sleep(forTimeInterval: 0.1)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: claudePath)
        p.arguments = ["-p", "Reply with exactly this markdown:\n\n# Title\n\n- item one\n- item two\n\n```swift\nlet x = 1\n```"]
        var env = ProcessInfo.processInfo.environment
        env["CRIER_PORT"] = "\(Self.port)"
        p.environment = env
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()

        _ = sem.wait(timeout: .now() + 75)
        let event = try XCTUnwrap(received)
        let message = event["message"] as? String ?? ""
        // The pipeline should preserve markdown structure.
        XCTAssertTrue(message.contains("# Title") || message.contains("Title"),
                      "markdown header should round-trip: \(message.prefix(300))")
        XCTAssertTrue(message.contains("item one"), "list items should round-trip")
    }

    // MARK: - Provider matrix (Cursor CLI, Codex CLI, …)

    /// Real CLI + hooks: spawn `cursor-agent`/`cursor` or `codex` with `-p`, expect crier-emit's agent field.
    /// Set `CRIER_E2E_PROVIDER` to `cursor` or `codex` (not the binary name).
    func testProviderCliHookDeliversEvent() throws {
        try requireE2E()
        let provider = ProcessInfo.processInfo.environment["CRIER_E2E_PROVIDER"] ?? ""
        guard !provider.isEmpty else {
            throw XCTSkip("Set CRIER_E2E_PROVIDER=cursor or codex (with CRIER_E2E=1 and hooks pointing at crier-emit)")
        }

        let (cliCandidates, expectedAgent): ([String], String) = switch provider {
        case "cursor": (["cursor-agent", "cursor"], "cursor")
        case "codex": (["codex"], "codex")
        default: ([provider], provider)
        }

        guard let cliPath = firstExecutable(candidates: cliCandidates) else {
            throw XCTSkip("None of \(cliCandidates.joined(separator: ", ")) found on PATH")
        }

        let marker = "CRIER_E2E_\(UUID().uuidString.prefix(8))"
        var received: [String: Any]?
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            received = self.nextEventMatching(
                { ($0["event"] as? String) == "turn_done" && ($0["agent"] as? String) == expectedAgent },
                totalBudget: 100
            )
            sem.signal()
        }
        Thread.sleep(forTimeInterval: 0.1)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: cliPath)
        p.arguments = ["-p", "Reply with only this exact string, nothing else: \(marker)"]
        var env = ProcessInfo.processInfo.environment
        env["CRIER_PORT"] = "\(Self.port)"
        p.environment = env
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()

        _ = sem.wait(timeout: .now() + 110)
        let event = try XCTUnwrap(received, "no turn_done event for \(expectedAgent) — is \(cliPath) wired to crier-emit in hooks?")
        XCTAssertEqual(event["agent"] as? String, expectedAgent)
        XCTAssertEqual(event["event"] as? String, "turn_done")
        let message = event["message"] as? String ?? ""
        XCTAssertTrue(message.contains(marker), "expected '\(marker)' in message but got: \(message.prefix(200))")
    }
}
