import CryptoKit
import Foundation

public enum CrierEmitCore {
    public static func extractLastAssistantMessage(transcriptPath: String) -> String {
        guard let raw = try? String(contentsOf: URL(fileURLWithPath: transcriptPath), encoding: .utf8) else {
            return ""
        }
        return extractLastAssistantMessage(transcript: raw)
    }

    public static func extractLastAssistantMessage(transcript: String) -> String {
        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["type"] as? String) == "assistant",
                  let message = obj["message"] as? [String: Any] else { continue }

            if let s = message["content"] as? String, !s.isEmpty { return s }
            if let blocks = message["content"] as? [[String: Any]] {
                var parts: [String] = []
                for block in blocks where (block["type"] as? String) == "text" {
                    if let t = block["text"] as? String, !t.isEmpty { parts.append(t) }
                }
                if !parts.isEmpty { return parts.joined(separator: "\n") }
            }
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
