import Foundation

/// Append-only JSONL at `~/.claude/crier-empty-message.jsonl` when the Crier panel would show
/// the “No assistant message was read…” placeholder. Each line is one JSON object you can
/// paste to another model for triage (`kind` + `source` identify where it was recorded).
public enum CrierEmptyMessageDiagnostic {
    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static var jsonlFileURL: URL {
        URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent(".claude/crier-empty-message.jsonl"))
    }

    public static func nowTS() -> String {
        iso8601.string(from: Date())
    }

    /// Events whose empty `message` produces the transcript placeholder in `crier-ui`.
    public static func shouldLogEmptyMessage(event: String) -> Bool {
        switch event {
        case "turn_done", "needs_permission", "needs_input": true
        default: false
        }
    }

    public static func isEffectivelyEmptyMessage(_ s: String?) -> Bool {
        (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func append(record: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(record) else { return }
        guard let json = try? JSONSerialization.data(withJSONObject: record),
              var line = String(data: json, encoding: .utf8) else { return }
        line.append("\n")
        guard let bytes = line.data(using: .utf8) else { return }
        let url = jsonlFileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(bytes)
            try? h.close()
        } else {
            try? bytes.write(to: url)
        }
    }
}
