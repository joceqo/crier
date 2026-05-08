import Foundation

// Installer — wires Crier hooks into Claude Code, Cursor, and Codex configs.
//
// Bundled crier-emit lives at:
//   /Applications/Crier.app/Contents/Resources/bin/crier-emit
// (or wherever the user placed Crier.app). We resolve the path written into
// hook configs via `emitBinaryURL()`.
//
// macOS App Translocation: launching Crier from a quarantined download/DMG can
// place the bundle under /var/.../AppTranslocation/... — that directory is not
// a stable anchor for hooks; it disappears after quit. When translocated, we
// only embed a hook path after `/Applications/Crier.app` matches this bundle ID;
// otherwise install fails with guidance to drag Crier into Applications first.
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
        case opencode   = "OpenCode"

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
        guard let resource = Bundle.main.resourceURL else { return nil }
        let bundled = resource.appendingPathComponent("bin/crier-emit")
        guard FileManager.default.isExecutableFile(atPath: bundled.path) else { return nil }

        // Never write translocated paths into agent configs — hooks would break
        // whenever Crier is not running (path no longer exists).
        if Self.isRunningFromAppTranslocation {
            let appsBundle = URL(fileURLWithPath: "/Applications/Crier.app", isDirectory: true)
            let appsEmit = appsBundle.appendingPathComponent("Contents/Resources/bin/crier-emit")
            guard FileManager.default.isExecutableFile(atPath: appsEmit.path),
                  Self.bundleAtAppsMatchesRunningApp(appsBundle) else {
                return nil
            }
            return appsEmit
        }
        return bundled
    }

    static func emitBinaryPath() -> String {
        emitBinaryURL()?.path ?? ""
    }

    private static var isRunningFromAppTranslocation: Bool {
        Bundle.main.bundlePath.contains("AppTranslocation")
    }

    /// True when `/Applications/Crier.app` exists and matches this process's bundle identifier.
    private static func bundleAtAppsMatchesRunningApp(_ appURL: URL) -> Bool {
        guard let installed = Bundle(url: appURL),
              let installedID = installed.bundleIdentifier,
              let runningID = Bundle.main.bundleIdentifier else {
            return false
        }
        return installedID == runningID
    }

    static func status(_ agent: Agent) -> InstallStatus {
        switch agent {
        case .claudeCode: return statusClaudeCode()
        case .cursor:     return statusCursor()
        case .codex:      return statusCodex()
        case .opencode:   return statusOpenCode()
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
        case .opencode:   try installOpenCode()
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
        let emit = emitBinaryPath()
        guard !emit.isEmpty else { return .wiredOtherPath }
        return crierCommands.allSatisfy { $0.hasPrefix(emit) }
            ? .wired
            : .wiredOtherPath
    }

    private static func installClaudeCode() throws {
        let emit = emitBinaryPath()
        try Self.ensureEmitPathForInstall(emit)

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
        // Sync hook with NO `timeout` field — exactly what Superwhisper's
        // hooks.json does. Empirically validated against SW.app's binary:
        // Stop hook stayed alive past 6 minutes while polling its inbox
        // file. Setting `timeout` was a defensive guess that didn't match
        // SW and added an artificial 9-min ceiling we don't actually need.
        //
        // While the hook is parked, claude-code's TUI accepts keystrokes
        // into its prompt buffer; if the user hits Enter, UserPromptSubmit
        // fires (mapped to `crier-emit claude-code dismiss` below) which
        // posts event="dismiss" and the daemon clears the drain
        // immediately. So the user can answer in the Crier overlay OR in
        // the terminal — whichever they prefer wins, no race, no async,
        // no "Stop hook error" UI label.
        hooks["Stop"] = stripCrierAndAppend(
            hooks["Stop"] as? [[String: Any]],
            entry: ["hooks": [["type": "command",
                               "command": "\(emit) claude-code turn_done"]]]
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
        let emit = emitBinaryPath()
        guard !emit.isEmpty else { return .wiredOtherPath }
        return crierCommands.allSatisfy { $0.hasPrefix(emit) }
            ? .wired
            : .wiredOtherPath
    }

    private static func installCursor() throws {
        let emit = emitBinaryPath()
        try Self.ensureEmitPathForInstall(emit)

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
        let emit = emitBinaryPath()
        guard !emit.isEmpty else { return .wiredOtherPath }
        return raw.contains(emit) ? .wired : .wiredOtherPath
    }

    private static func installCodex() throws {
        let emit = emitBinaryPath()
        try Self.ensureEmitPathForInstall(emit)

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

    // MARK: - OpenCode
    //
    // Writes ~/.config/opencode/opencode.json. Unlike the other agents,
    // OpenCode integration is a Node plugin (not a hook command) — but
    // opencode resolves absolute paths in the `plugin` array directly,
    // so we sidestep npm-link entirely and just point at the pre-built
    // dist bundled inside Crier.app.

    private static var opencodeConfigURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/opencode/opencode.json")
    }

    /// Path to the OpenCode plugin shipped inside Crier.app. Same App
    /// Translocation guard as `emitBinaryURL()` — never write a /var/...
    /// translocated path into opencode.json or the plugin breaks the
    /// moment Crier quits.
    static func opencodePluginEntryURL() -> URL? {
        guard let resource = Bundle.main.resourceURL else { return nil }
        let bundled = resource.appendingPathComponent("agent-assets/opencode-plugin/dist/index.js")
        guard FileManager.default.fileExists(atPath: bundled.path) else { return nil }
        if Self.isRunningFromAppTranslocation {
            let appsBundle = URL(fileURLWithPath: "/Applications/Crier.app", isDirectory: true)
            let appsEntry = appsBundle.appendingPathComponent(
                "Contents/Resources/agent-assets/opencode-plugin/dist/index.js"
            )
            guard FileManager.default.fileExists(atPath: appsEntry.path),
                  Self.bundleAtAppsMatchesRunningApp(appsBundle) else {
                return nil
            }
            return appsEntry
        }
        return bundled
    }

    static func opencodePluginEntryPath() -> String {
        opencodePluginEntryURL()?.path ?? ""
    }

    private static func statusOpenCode() -> InstallStatus {
        // Hide the row entirely when this Crier build doesn't ship the
        // plugin (e.g. ad-hoc dev build with `node` missing). The user
        // can't act on a status they can't satisfy.
        guard !opencodePluginEntryPath().isEmpty else { return .notDetected }

        let detected = whichBinary("opencode") != nil
            || FileManager.default.fileExists(atPath: opencodeConfigURL.deletingLastPathComponent().path)
        guard detected else { return .notDetected }

        guard let data = try? Data(contentsOf: opencodeConfigURL),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .detectedNotWired
        }
        let pluginEntries = (json["plugin"] as? [String]) ?? []
        let crierEntries = pluginEntries.filter {
            $0.contains("crier") && $0.hasSuffix("opencode-plugin/dist/index.js")
        }
        if crierEntries.isEmpty { return .detectedNotWired }
        let entry = opencodePluginEntryPath()
        return crierEntries.contains(entry) ? .wired : .wiredOtherPath
    }

    private static func installOpenCode() throws {
        let entry = opencodePluginEntryPath()
        guard !entry.isEmpty else {
            if isRunningFromAppTranslocation {
                throw InstallerError.copyToApplicationsBeforeHooks
            }
            throw InstallerError.bundledBinaryMissing
        }

        let url = opencodeConfigURL
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

        let existing = (json["plugin"] as? [String]) ?? []
        // Drop any prior Crier plugin path (different Crier.app install,
        // npm-linked package name, or stale translocated path), then add
        // the fresh absolute path. Other plugins the user has wired stay
        // intact.
        let filtered = existing.filter { p in
            !(p.contains("crier") && p.hasSuffix("opencode-plugin/dist/index.js"))
                && p != "@crier/opencode-plugin"
        }
        json["plugin"] = filtered + [entry]

        try writeJSON(json, to: url)
    }

    // MARK: - Helpers

    private static func ensureEmitPathForInstall(_ emit: String) throws {
        guard !emit.isEmpty else {
            if isRunningFromAppTranslocation {
                throw InstallerError.copyToApplicationsBeforeHooks
            }
            throw InstallerError.bundledBinaryMissing
        }
    }

    enum InstallerError: Error, LocalizedError {
        case bundledBinaryMissing
        /// Translocated app has no stable path for hook configs.
        case copyToApplicationsBeforeHooks

        var errorDescription: String? {
            switch self {
            case .bundledBinaryMissing:
                return "Crier.app is missing its bundled crier-emit binary. " +
                       "Try downloading the release again."
            case .copyToApplicationsBeforeHooks:
                return "Crier is running from a temporary download location (App Translocation). " +
                       "Drag Crier.app into your Applications folder, open it from there, " +
                       "then run Install again so hooks point at a path that stays on disk."
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
