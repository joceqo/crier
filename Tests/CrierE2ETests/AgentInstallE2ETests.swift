import XCTest
import Foundation
@testable import CrierServer

// Catches the gap that bit us: existing tests spawn `crier-emit` with synthetic
// stdin or call CrierServer in-process, but never exercise the install scripts
// or the real OpenCode plugin module. Result — when an install script wrote
// nothing (or wrote the wrong shape), or when the plugin's silent catch {}
// swallowed the failure, every test still passed and the integration was
// silently broken from the user's perspective.
//
// Each test runs against a temp $HOME so it can't disturb the developer's
// real Claude/Cursor/Codex/OpenCode setup.
final class AgentInstallE2ETests: XCTestCase {
    /// Port specific to this class so we don't collide with CrierEmitIntegrationTests
    /// (8733), CrierServerTests (8732), or CrierE2ETests (8734). Used by the
    /// install→fire chain tests below to assert the daemon actually receives
    /// an event when the parsed hook command runs.
    static let port = 8736
    static let base = "http://127.0.0.1:\(port)"
    nonisolated(unsafe) static var serverStarted = false

    override class func setUp() {
        super.setUp()
        if !serverStarted {
            CrierServer.startInBackground(host: "127.0.0.1", port: port)
            Thread.sleep(forTimeInterval: 0.3)
            serverStarted = true
        }
    }

    private var repoRoot: String { findRepoRoot() }

    private func findRepoRoot() -> String {
        // Tests run with cwd at the package root under `swift test`.
        let cwd = FileManager.default.currentDirectoryPath
        if FileManager.default.fileExists(atPath: cwd + "/Package.swift") { return cwd }
        // Fallback: walk up from this source file.
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir.path
            }
            dir = dir.deletingLastPathComponent()
        }
        return cwd
    }

    private func requireBinary(_ name: String) throws -> String {
        guard let path = which(name) else {
            throw XCTSkip("\(name) not found in PATH")
        }
        return path
    }

    @discardableResult
    private func which(_ name: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["which", name]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty == false) ? s : nil
    }

    /// Run a command with a custom $HOME and capture (exit, stdout, stderr).
    private func run(
        _ executable: String,
        args: [String],
        env: [String: String] = [:],
        cwd: String? = nil
    ) -> (Int32, String, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        var merged = ProcessInfo.processInfo.environment
        for (k, v) in env { merged[k] = v }
        p.environment = merged
        if let cwd = cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch { return (-1, "", "spawn failed: \(error)") }
        p.waitUntilExit()
        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, stdout, stderr)
    }

    private func makeTempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("crier-install-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Pre-built crier-emit path. The install scripts normally invoke
    /// `swift build` themselves, but doing so from inside `swift test` would
    /// nested-deadlock on the `.build/` lock — so the scripts honour
    /// CRIER_EMIT_BIN to skip the build and the test passes that here.
    private func requirePrebuiltCrierEmit() throws -> String {
        let candidates = [
            repoRoot + "/.build/release/crier-emit",
            repoRoot + "/.build/debug/crier-emit",
        ]
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            return c
        }
        throw XCTSkip("crier-emit not built — run `swift build --product crier-emit` first")
    }

    // MARK: - Cursor

    /// install-local-cursor.sh should write two crier-emit hook entries to
    /// ~/.cursor/hooks.json (turn_done on stop, needs_permission on
    /// beforeShellExecution) and remain idempotent on a second run.
    func testCursorInstallProducesValidHooksJsonAndIsIdempotent() throws {
        _ = try requireBinary("jq")
        let emit = try requirePrebuiltCrierEmit()

        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let script = repoRoot + "/scripts/install-local-cursor.sh"
        XCTAssertTrue(FileManager.default.fileExists(atPath: script), "install script missing at \(script)")

        let env = ["HOME": home.path, "CRIER_EMIT_BIN": emit]
        let (rc1, _, err1) = run("/bin/bash", args: [script], env: env)
        XCTAssertEqual(rc1, 0, "first install failed: \(err1)")

        let hooksPath = home.appendingPathComponent(".cursor/hooks.json").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: hooksPath), "hooks.json was not written")
        let firstContent = try String(contentsOfFile: hooksPath, encoding: .utf8)
        XCTAssertTrue(firstContent.contains("crier-emit cursor turn_done"),
                      "missing turn_done hook in hooks.json: \(firstContent)")
        XCTAssertTrue(firstContent.contains("crier-emit cursor needs_permission"),
                      "missing needs_permission hook: \(firstContent)")

        // Idempotency — re-run should leave exactly one of each crier-emit entry.
        let (rc2, _, err2) = run("/bin/bash", args: [script], env: env)
        XCTAssertEqual(rc2, 0, "second install failed: \(err2)")
        let secondContent = try String(contentsOfFile: hooksPath, encoding: .utf8)
        let stopCount = secondContent.components(separatedBy: "crier-emit cursor turn_done").count - 1
        let permCount = secondContent.components(separatedBy: "crier-emit cursor needs_permission").count - 1
        XCTAssertEqual(stopCount, 1, "duplicate turn_done hook after re-run")
        XCTAssertEqual(permCount, 1, "duplicate needs_permission hook after re-run")
    }

    // MARK: - Codex

    /// install-local-codex.sh should append [[hooks.Stop]] and
    /// [[hooks.PermissionRequest]] blocks to ~/.codex/config.toml and refuse
    /// to run a second time (the script bails with a guard message asking
    /// the user to remove old entries by hand — that's the documented
    /// contract; here we verify it).
    func testCodexInstallAppendsHookBlocksAndGuardsAgainstReRun() throws {
        let emit = try requirePrebuiltCrierEmit()

        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let script = repoRoot + "/scripts/install-local-codex.sh"
        XCTAssertTrue(FileManager.default.fileExists(atPath: script), "install script missing at \(script)")

        let env = ["HOME": home.path, "CRIER_EMIT_BIN": emit]
        let (rc1, _, err1) = run("/bin/bash", args: [script], env: env)
        XCTAssertEqual(rc1, 0, "first install failed: \(err1)")

        let cfgPath = home.appendingPathComponent(".codex/config.toml").path
        let firstContent = try String(contentsOfFile: cfgPath, encoding: .utf8)
        XCTAssertTrue(firstContent.contains("[[hooks.Stop]]"),
                      "missing [[hooks.Stop]] block: \(firstContent)")
        XCTAssertTrue(firstContent.contains("[[hooks.PermissionRequest]]"),
                      "missing [[hooks.PermissionRequest]] block: \(firstContent)")
        // Schema regression guard: Codex requires the nested [[hooks.<Event>.hooks]]
        // table — without it the handler fields under [[hooks.Stop]] are silently
        // discarded and the user sees no panel.
        XCTAssertTrue(firstContent.contains("[[hooks.Stop.hooks]]"),
                      "missing nested [[hooks.Stop.hooks]] table — Codex would ignore the handler:\n\(firstContent)")
        XCTAssertTrue(firstContent.contains("[[hooks.PermissionRequest.hooks]]"),
                      "missing nested [[hooks.PermissionRequest.hooks]] table:\n\(firstContent)")
        XCTAssertTrue(firstContent.contains("crier-emit codex turn_done"),
                      "Stop block does not invoke crier-emit codex turn_done")
        XCTAssertTrue(firstContent.contains("crier-emit codex needs_permission"),
                      "PermissionRequest block does not invoke crier-emit codex needs_permission")

        // Re-run guard — script should exit non-zero and not duplicate blocks.
        let (rc2, _, err2) = run("/bin/bash", args: [script], env: env)
        XCTAssertNotEqual(rc2, 0, "second install should refuse but exited 0; stderr=\(err2)")
        let secondContent = try String(contentsOfFile: cfgPath, encoding: .utf8)
        XCTAssertEqual(secondContent, firstContent, "config.toml mutated on guarded second run")
    }

    // MARK: - OpenCode plugin

    /// Drives the real built OpenCode plugin (packages/opencode-plugin/dist/index.js)
    /// through the existing smoke harness, but with HOME pointed at a temp dir
    /// so we can verify the always-on file log gets the expected lifecycle
    /// entries — the silent catch {} that previously hid plugin failures
    /// from the user would now be visible here too.
    func testOpenCodePluginSmokeWritesLifecycleLog() throws {
        _ = try requireBinary("node")
        _ = try requireBinary("npm")

        let pkgDir = repoRoot + "/packages/opencode-plugin"
        guard FileManager.default.fileExists(atPath: pkgDir + "/node_modules") else {
            throw XCTSkip("packages/opencode-plugin/node_modules missing — run `npm install` there first")
        }
        guard FileManager.default.fileExists(atPath: pkgDir + "/dist/index.js") else {
            throw XCTSkip("packages/opencode-plugin/dist not built — run `npm run build` there first")
        }

        // We isolate the log via CRIER_LOG_DIR rather than $HOME because
        // overriding $HOME breaks tool-version managers (asdf, nvm) that
        // need the real $HOME to resolve `node` to a real binary.
        let logDir = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: logDir) }

        let smoke = pkgDir + "/scripts/crier-plugin-smoke.mjs"
        XCTAssertTrue(FileManager.default.fileExists(atPath: smoke), "smoke script missing at \(smoke)")

        let (rc, stdout, stderr) = run(
            "/usr/bin/env",
            args: ["node", smoke],
            env: ["CRIER_LOG_DIR": logDir.path],
            cwd: pkgDir
        )
        XCTAssertEqual(rc, 0, "smoke failed: stdout=\(stdout) stderr=\(stderr)")
        XCTAssertTrue(stdout.contains("crier-plugin-smoke: ok"), "smoke did not report ok: \(stdout)")

        let logPath = logDir.appendingPathComponent("crier-opencode-plugin.log").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: logPath),
                      "plugin log file not created at \(logPath); CRIER_LOG_DIR override broken or logging removed")

        let log = try String(contentsOfFile: logPath, encoding: .utf8)
        // Each of these lines is a checkpoint — if a future refactor silently
        // drops one, that's the regression we're guarding against.
        let required = [
            "plugin module loaded",
            "plugin instantiated",
            "event received",
            "POST /event response",
            "long-poll /reply detached",
            "/reply response",
            "reply received",
            "session.promptAsync delivered reply",
            "permission response posted",
        ]
        for needle in required {
            XCTAssertTrue(log.contains(needle), "plugin log missing checkpoint '\(needle)':\n\(log)")
        }
    }

    // MARK: - Install → fire chain (the "nothing happens" diagnostic, automated)

    /// Long-poll /current; satisfies uiAlive() *and* captures the event the hook posts.
    /// Mirrors what the real Crier overlay does — crier-emit's short-circuit checks
    /// /status for at least one /current subscriber before doing anything.
    private func awaitFirstEvent(waitSeconds: Int = 8) -> [String: Any]? {
        guard let url = URL(string: "\(Self.base)/current?wait=\(waitSeconds)") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = TimeInterval(waitSeconds + 3)
        var result: [String: Any]?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                result = obj
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + TimeInterval(waitSeconds + 5))
        return result
    }

    /// Write a one-line JSONL transcript with a single assistant message
    /// (Claude Code / Cursor stop-hook shape).
    private func makeTranscript(message: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("install-e2e-\(UUID().uuidString).jsonl")
        let entry: [String: Any] = ["type": "assistant", "message": ["content": message]]
        let data = try JSONSerialization.data(withJSONObject: entry) + Data("\n".utf8)
        try data.write(to: url)
        return url
    }

    /// Spawn the parsed hook command exactly as the agent would, with the
    /// supplied JSON on stdin and CRIER_PORT pointed at the test daemon.
    /// The agent invokes the command as a single shell string, so we pass
    /// it through `/bin/sh -c` to match.
    @discardableResult
    private func spawnHookCommand(_ command: String, stdinJSON: [String: Any]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        var env = ProcessInfo.processInfo.environment
        env["CRIER_PORT"] = "\(Self.port)"
        p.environment = env
        let stdinPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        let payload = try JSONSerialization.data(withJSONObject: stdinJSON)
        stdinPipe.fileHandleForWriting.write(payload)
        try? stdinPipe.fileHandleForWriting.close()
        // turn_done blocks on /reply long-poll for up to 540s; we don't wait
        // for it to exit — the test asserts on the event that crier-emit
        // posted *before* it started waiting for a reply.
        return p.processIdentifier
    }

    /// Cursor: install → parse hooks.json → spawn the exact command Cursor
    /// would run on `stop` → assert the daemon receives the event. This is
    /// the "everything between install and daemon works" test that would
    /// have caught a stale binary path, wrong agent label, missing
    /// CRIER_PORT propagation, or the uiAlive() short-circuit misfiring.
    func testCursorInstallChainFiresEventOnDaemon() throws {
        _ = try requireBinary("jq")
        let emit = try requirePrebuiltCrierEmit()

        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let install = run("/bin/bash",
                          args: [repoRoot + "/scripts/install-local-cursor.sh"],
                          env: ["HOME": home.path, "CRIER_EMIT_BIN": emit])
        XCTAssertEqual(install.0, 0, "install failed: \(install.2)")

        // Pull the literal command the install script wrote, exactly the
        // way Cursor itself would read it.
        let jq = run("/usr/bin/env",
                     args: ["jq", "-r", ".hooks.stop[0].command", home.appendingPathComponent(".cursor/hooks.json").path])
        let stopCommand = jq.1.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(stopCommand.isEmpty, "could not extract stop command from hooks.json")
        XCTAssertTrue(stopCommand.contains(" cursor turn_done"),
                      "stop command missing expected `cursor turn_done` argv: \(stopCommand)")

        let transcript = try makeTranscript(message: "Hello from install-chain test")
        let payload: [String: Any] = [
            "transcript_path": transcript.path,
            "session_id": "install-chain-cursor-\(UUID().uuidString)",
            "cwd": "/tmp/install-chain-cursor",
        ]

        // Subscribe BEFORE spawning the hook, so /status shows ui_subscribers=1
        // by the time crier-emit's uiAlive() probe runs.
        var received: [String: Any]?
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            received = self.awaitFirstEvent(waitSeconds: 10)
            sem.signal()
        }
        Thread.sleep(forTimeInterval: 0.1)

        _ = try spawnHookCommand(stopCommand, stdinJSON: payload)

        XCTAssertEqual(sem.wait(timeout: .now() + 12), .success,
                       "long-poll never received an event — chain is broken (likely uiAlive short-circuit, wrong port, or stale binary path)")
        let event = try XCTUnwrap(received, "no event received")
        XCTAssertEqual(event["agent"] as? String, "cursor")
        XCTAssertEqual(event["event"] as? String, "turn_done")
        XCTAssertEqual(event["message"] as? String, "Hello from install-chain test")
        XCTAssertEqual(event["cwd"] as? String, "/tmp/install-chain-cursor")
    }

    /// Codex: install → grep config.toml for the command Codex would run
    /// from [[hooks.Stop.hooks]] → spawn it → assert the daemon receives
    /// the event. Codex's stop hook stdin shape carries the assistant text
    /// in `last_assistant_message`, which is what we feed here.
    func testCodexInstallChainFiresEventOnDaemon() throws {
        let emit = try requirePrebuiltCrierEmit()

        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let install = run("/bin/bash",
                          args: [repoRoot + "/scripts/install-local-codex.sh"],
                          env: ["HOME": home.path, "CRIER_EMIT_BIN": emit])
        XCTAssertEqual(install.0, 0, "install failed: \(install.2)")

        // We intentionally don't pull a TOML library in just for this — the
        // install script writes a known shape and we extract the line that
        // sits inside the [[hooks.Stop.hooks]] table by string match.
        let cfg = try String(contentsOfFile: home.appendingPathComponent(".codex/config.toml").path, encoding: .utf8)
        let stopBlockMarker = "[[hooks.Stop.hooks]]"
        guard let blockStart = cfg.range(of: stopBlockMarker) else {
            return XCTFail("missing \(stopBlockMarker) in config.toml:\n\(cfg)")
        }
        let after = cfg[blockStart.upperBound...]
        // command = "<...>"
        let pattern = #"command\s*=\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: String(after),
                                           range: NSRange(after.startIndex..<after.endIndex, in: after)),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: after) else {
            return XCTFail("could not parse command line under \(stopBlockMarker)")
        }
        let stopCommand = String(after[r])
        XCTAssertTrue(stopCommand.contains(" codex turn_done"),
                      "stop command missing `codex turn_done`: \(stopCommand)")

        let payload: [String: Any] = [
            "last_assistant_message": "Codex install-chain test message",
            "session_id": "install-chain-codex-\(UUID().uuidString)",
            "cwd": "/tmp/install-chain-codex",
        ]

        var received: [String: Any]?
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            received = self.awaitFirstEvent(waitSeconds: 10)
            sem.signal()
        }
        Thread.sleep(forTimeInterval: 0.1)

        _ = try spawnHookCommand(stopCommand, stdinJSON: payload)

        XCTAssertEqual(sem.wait(timeout: .now() + 12), .success,
                       "long-poll never received an event — Codex install→fire chain is broken")
        let event = try XCTUnwrap(received, "no event received")
        XCTAssertEqual(event["agent"] as? String, "codex")
        XCTAssertEqual(event["event"] as? String, "turn_done")
        XCTAssertEqual(event["message"] as? String, "Codex install-chain test message")
    }
}
