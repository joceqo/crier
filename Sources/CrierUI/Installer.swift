import Foundation

// Installer — wires Crier hooks into Claude Code, Cursor, and Codex configs.
//
// Bundled crier-emit lives at:
//   /Applications/Crier.app/Contents/Resources/bin/crier-emit
// (or wherever the user moved Crier.app — Bundle.main.resourceURL gives us
// the live path, so config files always point at the current app location).
//
// Each agent gets its own install function. They all:
//   1. Backup the existing config (timestamped .bak file).
//   2. Strip prior crier-emit entries (idempotent — re-running == updating
//      the path).
//   3. Add fresh entries pointing at the bundled crier-emit.
//
// Mirrors the bash logic in scripts/install-local-{claude-code,cursor,codex}.sh
// — kept in sync deliberately so devs and end-users get the same wiring.

@MainActor
enum Installer {
    enum Agent: String, CaseIterable, Identifiable {
        case claudeCode = "Claude Code"
        case cursor     = "Cursor"
        case codex      = "Codex"

        var id: String { rawValue }
    }

    enum InstallStatus {
        case notDetected         // agent not installed on this machine
        case detectedNotWired    // agent installed, hooks not yet wired
        case wired               // hooks wired and pointing at *this* app
        case wiredOtherPath      // hooks wired but to a stale binary path
                                 // (user moved/reinstalled Crier.app)
    }

    // MARK: - Detection

    static func emitBinaryURL() -> URL? {
        Bundle.main.resourceURL?.appendingPathComponent("bin/crier-emit")
    }

    static func emitBinaryPath() -> String {
        emitBinaryURL()?.path ?? ""
    }

    static func status(_ agent: Agent) -> InstallStatus {
        switch agent {
        case .claudeCode: return statusClaudeCode()
        case .cursor:     return statusCursor()
        case .codex:      return statusCodex()
        }
    }

    /// Fast yes/no — used on first launch to decide whether to auto-show
    /// the setup window. True if any *detected* agent has not been wired
    /// (or is wired to a stale path).
    static func anyAgentNeedsSetup() -> Bool {
        for agent in Agent.allCases {
            switch status(agent) {
            case .detectedNotWired, .wiredOtherPath: return true
            case .notDetected, .wired: continue
            }
        }
        return false
    }

    // MARK: - Install dispatch

    static func install(_ agent: Agent) throws {
        switch agent {
        case .claudeCode: try installClaudeCode()
        case .cursor:     try installCursor()
        case .codex:      try installCodex()
        }
    }

    // MARK: - Claude Code
    //
    // Writes ~/.claude/settings.json. JSON-mergeable — preserves any
    // user-configured non-Crier hooks.

    private static var claudeSettingsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/settings.json")
    }

    private static func statusClaudeCode() -> InstallStatus {
        let claudeBin = whichBinary("claude")
        let detected = claudeBin != nil
            || FileManager.default.fileExists(atPath: claudeSettingsURL.deletingLastPathComponent().path)
        guard detected else { return .notDetected }

        guard let data = try? Data(contentsOf: claudeSettingsURL),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return .detectedNotWired
        }
        let allCommands = hooks.values
            .compactMap { $0 as? [Any] }
            .flatMap { $0.compactMap { $0 as? [String: Any] } }
            .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
        let crierCommands = allCommands.filter { $0.contains("crier-emit") }
        guard !crierCommands.isEmpty else { return .detectedNotWired }
        return crierCommands.allSatisfy { $0.hasPrefix(emitBinaryPath()) }
            ? .wired
            : .wiredOtherPath
    }

    private static func installClaudeCode() throws {
        let emit = emitBinaryPath()
        guard !emit.isEmpty else { throw InstallerError.bundledBinaryMissing }

        let url = claudeSettingsURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            json = parsed
            try backup(url)
        }

        var hooks = (json["hooks"] as? [String: Any]) ?? [:]
        // Stop / Notification / PermissionRequest / PreToolUse / UserPromptSubmit.
        // Schema mirrors install-local-claude-code.sh — kept in sync deliberately.
        //
        // Sync hook (no `async: true`) with `timeout: 540` (9 min):
        //   • Sync avoids the "Stop hook error" UI label async hooks light
        //     up on every reply (anthropics/claude-code#10463 / #34600 /
        //     #39953).
        //   • timeout: 540 is the explicit ceiling — without it,
        //     claude-code's default sync hook timeout (60 s) SIGTERMs the
        //     hook before crier-emit's 5-min /reply/drain finishes.
        //   • While the hook is parked, claude-code's TUI accepts
        //     keystrokes into its prompt buffer; if the user hits Enter,
        //     UserPromptSubmit fires (mapped to `crier-emit claude-code
        //     dismiss` below), which posts event="dismiss" and the daemon
        //     clears the drain immediately. So the user can answer in
        //     the Crier overlay OR in the terminal — whichever they
        //     prefer wins, no race.
        //   • Matches Superwhisper's claude-hook shape (sync, ~5-min
        //     poll, UserPromptSubmit-cancels-poll) verified in
        //     superwhisper-claude-code-plugin-analysis.md.
        hooks["Stop"] = stripCrierAndAppend(
            hooks["Stop"] as? [[String: Any]],
            entry: ["hooks": [["type": "command",
                               "command": "\(emit) claude-code turn_done",
                               "timeout": 540]]]
        )
        hooks["Notification"] = stripCrierAndAppend(
            hooks["Notification"] as? [[String: Any]],
            entry: ["hooks": [["type": "command",
                               "command": "\(emit) claude-code needs_permission"]]]
        )
        hooks["PermissionRequest"] = stripCrierAndAppend(
            hooks["PermissionRequest"] as? [[String: Any]],
            entry: ["hooks": [["type": "command",
                               "command": "\(emit) claude-code needs_permission"]]]
        )
        hooks["PreToolUse"] = stripCrierAndAppend(
            hooks["PreToolUse"] as? [[String: Any]],
            entry: ["matcher": "AskUserQuestion",
                    "hooks": [["type": "command",
                               "command": "\(emit) claude-code needs_input"]]]
        )
        hooks["UserPromptSubmit"] = stripCrierAndAppend(
            hooks["UserPromptSubmit"] as? [[String: Any]],
            entry: ["hooks": [["type": "command",
                               "command": "\(emit) claude-code dismiss"]]]
        )
        json["hooks"] = hooks

        try writeJSON(json, to: url)

        // /crier skill + slash command — copy from bundle.
        if let skillSrc = Bundle.main.resourceURL?
            .appendingPathComponent("agent-assets/claude-skills/crier/SKILL.md") {
            let dst = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".claude/skills/crier/SKILL.md")
            try? FileManager.default.createDirectory(
                at: dst.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: skillSrc, to: dst)
        }
        if let cmdSrc = Bundle.main.resourceURL?
            .appendingPathComponent("agent-assets/claude-commands/crier.md") {
            let dst = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".claude/commands/crier.md")
            try? FileManager.default.createDirectory(
                at: dst.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: cmdSrc, to: dst)
        }
    }

    /// Drop entries whose nested `hooks[].command` references crier-emit,
    /// then append the new entry. Lets re-running update the binary path
    /// without duplicating entries or wiping unrelated hooks.
    private static func stripCrierAndAppend(_ existing: [[String: Any]]?,
                                            entry: [String: Any]) -> [[String: Any]] {
        let kept = (existing ?? []).filter { item in
            let inner = (item["hooks"] as? [[String: Any]]) ?? []
            let commands = inner.compactMap { $0["command"] as? String }
            return !commands.contains { $0.contains("crier-emit") }
        }
        return kept + [entry]
    }

    // MARK: - Cursor
    //
    // Writes ~/.cursor/hooks.json. Flat schema — entries hang off named
    // events as flat objects with a `command` field.

    private static var cursorHooksURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cursor/hooks.json")
    }

    private static func statusCursor() -> InstallStatus {
        let detected = whichBinary("cursor-agent") != nil
            || FileManager.default.fileExists(atPath: cursorHooksURL.deletingLastPathComponent().path)
        guard detected else { return .notDetected }

        guard let data = try? Data(contentsOf: cursorHooksURL),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return .detectedNotWired
        }
        let commands = hooks.values
            .compactMap { $0 as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["command"] as? String }
        let crierCommands = commands.filter { $0.contains("crier-emit") }
        guard !crierCommands.isEmpty else { return .detectedNotWired }
        return crierCommands.allSatisfy { $0.hasPrefix(emitBinaryPath()) }
            ? .wired
            : .wiredOtherPath
    }

    private static func installCursor() throws {
        let emit = emitBinaryPath()
        guard !emit.isEmpty else { throw InstallerError.bundledBinaryMissing }

        let url = cursorHooksURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var json: [String: Any] = ["version": 1, "hooks": [String: Any]()]
        if let data = try? Data(contentsOf: url),
           let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            json = parsed
            try backup(url)
        }
        json["version"] = (json["version"] as? Int) ?? 1
        var hooks = (json["hooks"] as? [String: Any]) ?? [:]

        hooks["stop"] = cursorStripCrierAndAppend(
            hooks["stop"] as? [[String: Any]],
            entry: ["command": "\(emit) cursor turn_done"]
        )
        hooks["beforeShellExecution"] = cursorStripCrierAndAppend(
            hooks["beforeShellExecution"] as? [[String: Any]],
            entry: ["command": "\(emit) cursor needs_permission"]
        )
        json["hooks"] = hooks

        try writeJSON(json, to: url)
    }

    private static func cursorStripCrierAndAppend(_ existing: [[String: Any]]?,
                                                  entry: [String: Any]) -> [[String: Any]] {
        let kept = (existing ?? []).filter { item in
            let cmd = (item["command"] as? String) ?? ""
            return !cmd.contains("crier-emit")
        }
        return kept + [entry]
    }

    // MARK: - Codex
    //
    // Writes ~/.codex/config.toml. TOML round-tripping in Swift would mean
    // a dependency or a hand-written parser; instead we use a marker-block
    // append/replace strategy: any prior Crier block (delimited by # CRIER
    // markers) is stripped, then the fresh block is appended.

    private static var codexConfigURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/config.toml")
    }

    private static let codexBeginMarker = "# >>> CRIER HOOKS — managed by Crier.app, do not edit"
    private static let codexEndMarker   = "# <<< CRIER HOOKS"

    private static func statusCodex() -> InstallStatus {
        let detected = whichBinary("codex") != nil
            || FileManager.default.fileExists(atPath: codexConfigURL.deletingLastPathComponent().path)
        guard detected else { return .notDetected }
        guard let raw = try? String(contentsOf: codexConfigURL, encoding: .utf8) else {
            return .detectedNotWired
        }
        guard raw.contains("crier-emit") else { return .detectedNotWired }
        return raw.contains(emitBinaryPath()) ? .wired : .wiredOtherPath
    }

    private static func installCodex() throws {
        let emit = emitBinaryPath()
        guard !emit.isEmpty else { throw InstallerError.bundledBinaryMissing }

        let url = codexConfigURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var raw = ""
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            raw = existing
            try backup(url)
        }

        // Strip any prior managed block.
        raw = stripCodexBlock(raw)

        // Ensure [features] codex_hooks = true. We append a managed block
        // for that too if nothing matches; if [features] already exists we
        // assume the user has it (printing a warning to user is the bash
        // behaviour, but the user can't see stdout from inside the GUI).
        if !raw.contains("[features]") {
            if !raw.isEmpty && !raw.hasSuffix("\n") { raw += "\n" }
            raw += "\n[features]\ncodex_hooks = true\n"
        }

        if !raw.hasSuffix("\n") { raw += "\n" }
        raw += """

        \(Self.codexBeginMarker)

        [[hooks.Stop]]

        [[hooks.Stop.hooks]]
        type = "command"
        command = "\(emit) codex turn_done"
        timeout = 10

        [[hooks.PermissionRequest]]

        [[hooks.PermissionRequest.hooks]]
        type = "command"
        command = "\(emit) codex needs_permission"
        timeout = 10
        \(Self.codexEndMarker)

        """
        try raw.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func stripCodexBlock(_ s: String) -> String {
        guard let begin = s.range(of: codexBeginMarker),
              let end = s.range(of: codexEndMarker, range: begin.upperBound..<s.endIndex) else {
            return s
        }
        // Also drop a single trailing newline so re-writing doesn't accumulate blanks.
        var stripStart = begin.lowerBound
        // Walk back over a leading blank line introduced by previous writes.
        if stripStart > s.startIndex {
            let prev = s.index(before: stripStart)
            if s[prev] == "\n" { stripStart = prev }
        }
        var stripEnd = end.upperBound
        if stripEnd < s.endIndex && s[stripEnd] == "\n" {
            stripEnd = s.index(after: stripEnd)
        }
        var copy = s
        copy.removeSubrange(stripStart..<stripEnd)
        return copy
    }

    // MARK: - Helpers

    enum InstallerError: Error, LocalizedError {
        case bundledBinaryMissing

        var errorDescription: String? {
            switch self {
            case .bundledBinaryMissing:
                return "Crier.app is missing its bundled crier-emit binary. " +
                       "Try downloading the release again."
            }
        }
    }

    /// `which`-equivalent — searches PATH plus common Homebrew locations
    /// that aren't always on the GUI app's inherited PATH.
    private static func whichBinary(_ name: String) -> String? {
        var paths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        // GUI apps launched from /Applications inherit launchd's PATH which
        // typically excludes /opt/homebrew/bin. Probe these explicitly so
        // detection works for users on Apple Silicon Homebrew.
        paths.append(contentsOf: [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(NSHomeDirectory())/.local/bin",
            "\(NSHomeDirectory())/.cargo/bin",
            "\(NSHomeDirectory())/.bun/bin",
        ])
        for p in paths {
            let candidate = "\(p)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func backup(_ url: URL) throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = url.appendingPathExtension("bak.\(stamp)")
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.copyItem(at: url, to: backup)
        }
    }

    private static func writeJSON(_ json: Any, to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }
}
