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
    /// - String `content`, including `""`, is returned as-is so an empty final turn does not
    ///   show the previous assistant message (stale UI).
    /// - Array `content` with only `text` blocks joins non-empty parts; if there is at least
    ///   one `text` block but all are empty, returns `""`.
    /// - Assistant lines with only non-text blocks (e.g. `tool_use`) are skipped so the last
    ///   **visible** text is used when the model ends on a tool call.
    public static func extractLastAssistantMessage(transcript: String) -> String {
        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["type"] as? String) == "assistant",
                  let message = obj["message"] as? [String: Any] else { continue }

            guard let rawContent = message["content"] else {
                continue
            }
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

    public static func isGloballyDisabled() -> Bool {
        FileManager.default.fileExists(atPath: globalDisabledPath)
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
