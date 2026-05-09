import CryptoKit
import Foundation

public enum CrierEmitCore {
    public static func extractLastAssistantMessage(transcriptPath: String) -> String {
        guard let raw = try? String(contentsOf: URL(fileURLWithPath: transcriptPath), encoding: .utf8) else {
            return ""
        }
        return extractLastAssistantMessage(transcript: raw)
    }

    /// Last assistant **turn** in the JSONL transcript (scanning from the bottom).
    ///
    /// Accepts both envelope shapes we've seen in the wild:
    /// - Claude Code: `{"type":"assistant","message":{...}}`
    /// - Cursor:      `{"role":"assistant","message":{...}}`
    /// The downstream content grammar (`{type:"text",text:"..."}` blocks, optional
    /// `tool_use` siblings) is identical, so detection is a per-line OR on the two keys.
    ///
    /// - String `content`, including `""`, is returned as-is so an empty final turn does not
    ///   show the previous assistant message (stale UI).
    /// - Array `content` with only `text` blocks joins non-empty parts; if there is at least
    ///   one `text` block but all are empty, returns `""`.
    /// - Assistant lines with only non-text blocks (e.g. `tool_use`) are skipped so the last
    ///   **visible** text is used when the model ends on a tool call.
    /// - As defensive fallback, if an assistant line lacks a `message` envelope, we try
    ///   reading `content` directly off the top-level object.
    public static func extractLastAssistantMessage(transcript: String) -> String {
        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let isAssistant = (obj["type"] as? String) == "assistant"
                              || (obj["role"] as? String) == "assistant"
            guard isAssistant else { continue }

            let rawContent: Any?
            if let message = obj["message"] as? [String: Any] {
                rawContent = message["content"]
            } else {
                rawContent = obj["content"]
            }
            guard let rawContent = rawContent else { continue }

            if rawContent is NSNull {
                return ""
            }
            if let s = rawContent as? String {
                return s
            }
            if let blocks = rawContent as? [[String: Any]] {
                var textParts: [String] = []
                var sawTextBlock = false
                for block in blocks {
                    guard (block["type"] as? String) == "text" else { continue }
                    sawTextBlock = true
                    if let t = block["text"] as? String, !t.isEmpty {
                        textParts.append(t)
                    }
                }
                if sawTextBlock {
                    return textParts.joined(separator: "\n")
                }
                continue
            }
            continue
        }
        return ""
    }

    // MARK: - cwd recovery
    //
    // Some agents (notably Cursor) report their *config* dir as `cwd` in
    // hook stdin instead of the project the user was actually running in.
    // The truth is recoverable from `transcript_path`, which always lives
    // at `<configDir>/projects/<encoded>/...` where `<encoded>` is the
    // absolute project path with `/` replaced by `-` (Cursor: no leading
    // dash; Claude Code: leading dash). The encoding is lossy when a real
    // directory contains a literal `-` (`tinker-app`, `test-ux-researcher`),
    // so decoding requires filesystem validation: we walk the tree picking
    // the longest fully-existing path. Tie-break: fewer path components
    // wins (more dashes preserved — the conservative choice).

    public static let agentConfigDirNames: [String] = [
        ".cursor", ".claude", ".codex", ".opencode"
    ]

    /// Recover the project cwd when stdin's cwd points at the agent's
    /// own config dir. Returns `stdinCwd` unchanged in every case where
    /// we can't confidently improve on it: non-suspicious cwd, missing
    /// transcript path, no `<configDir>/projects/<encoded>/` segment, or
    /// no candidate directory exists for the decoded encoding.
    ///
    /// `home`, `configDirNames`, and `fileManager` are injectable so unit
    /// tests can assemble a hermetic fake home with real subdirectories.
    public static func recoverCwdFromTranscript(
        stdinCwd: String,
        transcriptPath: String?,
        home: String = NSHomeDirectory(),
        configDirNames: [String] = agentConfigDirNames,
        fileManager: FileManager = .default
    ) -> String {
        let configDirs = configDirNames.map {
            (home as NSString).appendingPathComponent($0)
        }
        let stdinIsSuspicious = configDirs.contains { dir in
            stdinCwd == dir || stdinCwd.hasPrefix(dir + "/")
        }
        guard stdinIsSuspicious else { return stdinCwd }
        guard let tp = transcriptPath, !tp.isEmpty else { return stdinCwd }

        let parts = URL(fileURLWithPath: tp).pathComponents
        var encoded: String?
        for i in 0..<parts.count {
            if parts[i] == "projects", i + 1 < parts.count {
                encoded = parts[i + 1]
                break
            }
        }
        guard var name = encoded, !name.isEmpty else { return stdinCwd }
        if name.hasPrefix("-") { name = String(name.dropFirst()) }

        let tokens = name
            .split(separator: "-", omittingEmptySubsequences: true)
            .map(String.init)
        if tokens.isEmpty { return stdinCwd }

        var best = ""
        var budget = 64
        func walk(remaining: ArraySlice<String>, current: String) {
            if budget <= 0 { return }
            if remaining.isEmpty {
                let bestComps = best.split(separator: "/").count
                let curComps = current.split(separator: "/").count
                if current.count > best.count
                    || (current.count == best.count && curComps < bestComps) {
                    best = current
                }
                return
            }
            for i in 1...remaining.count {
                if budget <= 0 { return }
                budget -= 1
                let component = remaining.prefix(i).joined(separator: "-")
                let next = current + "/" + component
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: next, isDirectory: &isDir),
                   isDir.boolValue {
                    walk(remaining: remaining.dropFirst(i), current: next)
                }
            }
        }
        walk(remaining: tokens[...], current: "")

        return best.count > 1 ? best : stdinCwd
    }

    /// Cursor's `beforeShellExecution` hook stdin sometimes omits
    /// `transcript_path` (observed empirically — schema isn't documented
    /// and seems to vary by command/agent context). When that happens
    /// we still get `session_id`; the transcript file lives at a
    /// deterministic path:
    ///
    ///   ~/.cursor/projects/<encoded-cwd>/agent-transcripts/<sid>/<sid>.jsonl
    ///
    /// Rather than reverse-engineering Cursor's cwd encoding rules
    /// (different from claude-code's), walk every project dir under
    /// `~/.cursor/projects/` and return the first that contains a
    /// transcript matching `sessionId`. Cursor session_ids are UUIDs,
    /// globally unique, so the first hit is correct. Returns `nil` when
    /// no match exists — caller should treat as "no transcript known".
    ///
    /// `home` and `fileManager` are injectable for unit testing.
    public static func findCursorTranscriptPath(
        sessionId: String,
        home: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> String? {
        guard !sessionId.isEmpty else { return nil }
        let projectsDir = (home as NSString).appendingPathComponent(".cursor/projects")
        guard let projectDirs = try? fileManager.contentsOfDirectory(atPath: projectsDir) else {
            return nil
        }
        for projectDir in projectDirs {
            let candidate = (projectsDir as NSString)
                .appendingPathComponent(projectDir)
                .appending("/agent-transcripts/\(sessionId)/\(sessionId).jsonl")
            if fileManager.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// ISO 8601 timestamp in the user's local timezone, e.g.
    /// `2026-05-08T11:02:17+02:00`. Preferred for human-readable log
    /// lines so timestamps match wall-clock time the user sees on their
    /// laptop. Wire formats (event payloads) can keep UTC for stability,
    /// but this is shipped from CrierEmitCore so all three modules
    /// (emit, server, UI) share one canonical helper.
    public static func localISOTimestamp(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }

    public static let crierAgentDir = "/tmp/crier-agent"

    public static func disabledPath(forCwd cwd: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(cwd.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(crierAgentDir)/disabled-\(hex)"
    }

    // App-wide disable flag — toggled from the menu-bar status item. Takes
    // precedence over per-CWD checks so a single click silences every
    // session at once.
    public static let globalDisabledPath = "\(crierAgentDir)/disabled-global"

    /// Temporary silence: hooks skip until this instant (wall clock, Unix time).
    /// Menu bar "Pause for …" writes this file; `crier-emit` checks alongside global disable.
    public static let globalPauseUntilPath = "\(crierAgentDir)/pause-until"

    public static func isGloballyDisabled() -> Bool {
        FileManager.default.fileExists(atPath: globalDisabledPath)
    }

    /// End time of an active pause, if any. When the stamp is in the past, the file is removed and this returns `nil`.
    public static func globalPauseExpiry() -> Date? {
        let p = globalPauseUntilPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
              let s = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty,
              let unix = TimeInterval(s) else {
            return nil
        }
        let end = Date(timeIntervalSince1970: unix)
        if end <= Date() {
            try? FileManager.default.removeItem(atPath: p)
            return nil
        }
        return end
    }

    public static func isGlobalPauseActive() -> Bool {
        globalPauseExpiry() != nil
    }

    public static func setGlobalPause(until end: Date) {
        try? FileManager.default.createDirectory(
            atPath: crierAgentDir,
            withIntermediateDirectories: true
        )
        let unix = Int(floor(end.timeIntervalSince1970))
        let data = "\(unix)\n".data(using: .utf8)
        FileManager.default.createFile(atPath: globalPauseUntilPath, contents: data)
    }

    public static func clearGlobalPause() {
        try? FileManager.default.removeItem(atPath: globalPauseUntilPath)
    }

    /// True when either the global disable flag or a menu-bar pause should short-circuit hooks.
    public static func isGlobalSilenceActive() -> Bool {
        isGloballyDisabled() || isGlobalPauseActive()
    }

    public static func isCwdDisabled(_ cwd: String) -> Bool {
        FileManager.default.fileExists(atPath: disabledPath(forCwd: cwd))
    }

    /// Mark a CWD as disabled. Writes the cwd as the file content so the
    /// Conversations window can recover the path later (md5 isn't reversible).
    public static func setCwdDisabled(_ cwd: String) {
        try? FileManager.default.createDirectory(
            atPath: crierAgentDir,
            withIntermediateDirectories: true
        )
        let data = (cwd + "\n").data(using: .utf8) ?? Data()
        FileManager.default.createFile(atPath: disabledPath(forCwd: cwd), contents: data)
    }

    public static func clearCwdDisabled(_ cwd: String) {
        try? FileManager.default.removeItem(atPath: disabledPath(forCwd: cwd))
    }

    /// Every cwd currently flagged disabled (excludes the global and
    /// per-session flags). Reads each `disabled-<hex>` file's contents to
    /// recover the original path. Files written before content-tracking
    /// landed appear empty and are reported via `unknownDigests` so the UI
    /// can offer to clean them.
    public static func disabledCwds() -> (known: [String], unknownDigests: [String]) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: crierAgentDir) else {
            return ([], [])
        }
        var known: [String] = []
        var unknown: [String] = []
        for name in entries {
            guard name.hasPrefix("disabled-"),
                  name != "disabled-global",
                  !name.hasPrefix("disabled-session-") else { continue }
            let path = "\(crierAgentDir)/\(name)"
            let data = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
            let s = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if s.isEmpty {
                unknown.append(String(name.dropFirst("disabled-".count)))
            } else {
                known.append(s)
            }
        }
        return (known.sorted(), unknown)
    }

    // MARK: - Per-session disable
    //
    // Session-id-scoped disable is the finer-grained sibling of the cwd
    // disable. Two parallel Claude conversations in the same project keep
    // independent toggles: silencing one (via the badge X dialog or the
    // Conversations window) leaves the other untouched.
    //
    // Storage: `/tmp/crier-agent/disabled-session-<fullSessionId>`. The
    // file content is the cwd, so the Conversations window can label
    // inactive disabled sessions by project even after the live tab is
    // gone. `<fullSessionId>` is `<agent>-<rawSessionId>` (the same
    // identifier crier-emit posts to /event), so crier-emit can gate on
    // this without any extra state lookup.

    public static func sessionDisabledPath(forFullId id: String) -> String {
        "\(crierAgentDir)/disabled-session-\(id)"
    }

    public static func isSessionDisabled(_ fullId: String) -> Bool {
        FileManager.default.fileExists(atPath: sessionDisabledPath(forFullId: fullId))
    }

    public static func setSessionDisabled(_ fullId: String, cwd: String) {
        try? FileManager.default.createDirectory(
            atPath: crierAgentDir,
            withIntermediateDirectories: true
        )
        let data = (cwd + "\n").data(using: .utf8) ?? Data()
        FileManager.default.createFile(atPath: sessionDisabledPath(forFullId: fullId), contents: data)
    }

    public static func clearSessionDisabled(_ fullId: String) {
        try? FileManager.default.removeItem(atPath: sessionDisabledPath(forFullId: fullId))
    }

    // MARK: - Per-session mute (timed)
    //
    // Timed sibling of disable. Where disable persists until manually
    // cleared, mute auto-expires at a wall-clock deadline written into
    // the flag file. crier-emit checks the deadline on every hook fire
    // and treats expired files as cleared (and tidies them up so we
    // don't leak entries forever).
    //
    // Storage: `/tmp/crier-agent/muted-session-<fullSessionId>`. File
    // content is the unix epoch (seconds, integer) when the mute lifts.
    // Same `<agent>-<rawSessionId>` scheme as the disable flag, so the
    // per-tab kebab can scope mutes the same way it scopes disables.

    public static func sessionMutedPath(forFullId id: String) -> String {
        "\(crierAgentDir)/muted-session-\(id)"
    }

    public static func setSessionMuted(_ fullId: String, until: Date) {
        try? FileManager.default.createDirectory(
            atPath: crierAgentDir,
            withIntermediateDirectories: true
        )
        let epoch = Int(until.timeIntervalSince1970)
        let data = "\(epoch)\n".data(using: .utf8) ?? Data()
        FileManager.default.createFile(atPath: sessionMutedPath(forFullId: fullId), contents: data)
    }

    public static func clearSessionMuted(_ fullId: String) {
        try? FileManager.default.removeItem(atPath: sessionMutedPath(forFullId: fullId))
    }

    /// True iff a non-expired mute flag exists. Side-effect: deletes
    /// the flag when its deadline has passed so future calls return
    /// false without us having to garbage-collect from elsewhere.
    public static func isSessionMuted(_ fullId: String) -> Bool {
        let path = sessionMutedPath(forFullId: fullId)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let s = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              let epoch = TimeInterval(s)
        else { return false }
        if Date(timeIntervalSince1970: epoch) <= Date() {
            try? FileManager.default.removeItem(atPath: path)
            return false
        }
        return true
    }

    // MARK: - Summary affordance gating
    //
    // Pure-logic helpers used by the CrierUI overlay's "Summarize" chip.
    // The actual on-device summarization lives in CrierUI/MessageSummary.swift
    // because it depends on FoundationModels; this layer only decides
    // whether to offer the affordance, so it stays unit-testable.

    /// Minimum assistant message length (in characters) before the
    /// "Summarize" chip is offered. Below this, the message itself is
    /// short enough that an extra summary card adds no value.
    public static let summarizeMinimumChars = 400

    /// True iff the chip should be shown for a message of the given
    /// length and current model availability.
    public static func shouldOfferSummary(textLength: Int, modelAvailable: Bool) -> Bool {
        textLength >= summarizeMinimumChars && modelAvailable
    }

    /// (fullSessionId, cwdRecorded) for every session currently disabled.
    /// `cwd` may be empty for files written before content-tracking landed.
    public static func disabledSessions() -> [(fullId: String, cwd: String)] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: crierAgentDir) else {
            return []
        }
        var out: [(String, String)] = []
        let prefix = "disabled-session-"
        for name in entries where name.hasPrefix(prefix) {
            let fullId = String(name.dropFirst(prefix.count))
            let path = "\(crierAgentDir)/\(name)"
            let data = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
            let cwd = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            out.append((fullId, cwd))
        }
        return out.sorted { $0.0 < $1.0 }
    }
}

// MARK: - UI Send routing
//
// Decoupled from CrierUI so the routing logic is reachable from tests
// (CrierUI is an executable target whose top-level NSApplication launch
// would break a test bundle). The UI's panel.submit() is a thin wrapper
// around `buildReplyPost(...)` + URLSession.dataTask.

extension CrierEmitCore {
    /// Output of Send routing — the URL to POST to and the JSON body.
    /// Pure data; no network. Equatable so tests can assert on shape.
    public struct ReplyPostPlan: Equatable {
        public let url: URL
        public let body: Data

        public init(url: URL, body: Data) {
            self.url = url
            self.body = body
        }
    }

    /// Decide which endpoint Send should hit and assemble the JSON body.
    /// Mirrors what CrierUI's submit() does at runtime.
    ///
    /// Routing:
    ///   • replyChannel == "hook-stdout-queue" (claude-code, pre-queue
    ///     architecture) → POST /reply/queue with {"session_id":...,
    ///     "text":...}. Wakes whichever GET /reply/drain is parked or
    ///     stores the reply for the next drain.
    ///   • anything else → legacy POST /reply keyed on request_id, with
    ///     channel + target carried so tmux / http-poll routing works.
    ///
    /// Returns `nil` if the URL or JSON can't be constructed (the caller
    /// treats that as "skip POST" — happens only on truly invalid input).
    public static func buildReplyPost(
        endpoint: String,
        sessionId: String,
        text: String,
        replyChannel: String?,
        requestId: String?,
        replyTarget: String?
    ) -> ReplyPostPlan? {
        let useQueueEndpoint = (replyChannel == "hook-stdout-queue")
        let postPath = useQueueEndpoint ? "/reply/queue" : "/reply"

        var body: [String: Any] = ["text": text]
        body["session_id"] = sessionId
        if !useQueueEndpoint {
            if let r = requestId { body["request_id"] = r }
            if let c = replyChannel { body["channel"] = c }
            if let t = replyTarget { body["target"] = t }
        }

        guard let url = URL(string: "\(endpoint)\(postPath)"),
              let data = try? JSONSerialization.data(
                withJSONObject: body,
                options: [.sortedKeys]   // deterministic byte order for tests
              ) else {
            return nil
        }
        return ReplyPostPlan(url: url, body: data)
    }
}
