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

    public static func disabledPath(forCwd cwd: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(cwd.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "/tmp/crier-agent/disabled-\(hex)"
    }

    // App-wide disable flag — toggled from the menu-bar status item. Takes
    // precedence over per-CWD checks so a single click silences every
    // session at once.
    public static let globalDisabledPath = "/tmp/crier-agent/disabled-global"

    public static func isGloballyDisabled() -> Bool {
        FileManager.default.fileExists(atPath: globalDisabledPath)
    }
}
