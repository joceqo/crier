import Foundation
import CryptoKit

// crier-emit <agent> <event>
//   agent: claude-code | codex | cursor | ...
//   event: turn_done | needs_permission | needs_input
//
// Reads the hook's JSON payload on stdin, normalizes it to the universal
// Crier event shape, and POSTs to http://127.0.0.1:8731/event. Always exits
// 0 — failures here must never break the host agent's hook chain.

// Append a line to ~/.claude/crier-emit.log. Used to debug what the hook
// did at fire time — Claude Code shows hook stdout/stderr only on error,
// so persistent logs are how we tell whether long-poll worked, what the
// reply was, and whether decision:block was emitted.
func log(_ msg: String) {
    let path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/crier-emit.log")
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(stamp)] [pid:\(getpid())] \(msg)\n"
    let data = line.data(using: .utf8) ?? Data()
    let url = URL(fileURLWithPath: path)
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(data)
        try? h.close()
    } else {
        try? data.write(to: url)
    }
}

// Walk the parent process chain starting at our parent (the agent CLI, e.g.
// `claude`) until we find an ancestor whose executable lives inside an
// `.app/Contents/MacOS/` bundle — that's the GUI terminal/host the agent
// is running in (Terminal.app, iTerm.app, Cursor.app, cmux app, etc.).
// This is what crier-ui will activate before posting CGEvent keystrokes,
// so the reply lands in the agent's terminal even when it's not frontmost.
func findAgentTerminalPID() -> Int32? {
    var pid = getppid()
    var hops = 0
    while pid > 1, hops < 32 {
        if let path = sh(["ps", "-p", "\(pid)", "-o", "comm="]),
           path.contains(".app/Contents/MacOS/") {
            return pid
        }
        guard let parentStr = sh(["ps", "-p", "\(pid)", "-o", "ppid="])?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let parent = Int32(parentStr), parent > 1 else { return nil }
        pid = parent
        hops += 1
    }
    return nil
}

func sh(_ args: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = args
    let outPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }
    guard process.terminationStatus == 0 else { return nil }
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

func extractLastAssistantMessage(transcriptPath: String) -> String {
    guard let raw = try? String(contentsOf: URL(fileURLWithPath: transcriptPath), encoding: .utf8) else { return "" }
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
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
            // Only return if we actually found text. If this assistant entry
            // is e.g. a tool_use-only line, fall through and keep walking
            // backward for the previous assistant text.
            if !parts.isEmpty { return parts.joined(separator: "\n") }
        }
    }
    return ""
}

func prettyAgentName(_ a: String) -> String {
    switch a {
    case "claude-code": return "Claude Code"
    case "codex":       return "Codex"
    case "cursor":      return "Cursor"
    case "opencode":    return "OpenCode"
    case "aider":       return "Aider"
    default:            return a
    }
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: crier-emit <agent> <event>\n".utf8))
    exit(2)
}
let agent = args[1]
let event = args[2]

let stdinData = FileHandle.standardInput.readDataToEndOfFile()
let stdinJSON = (try? JSONSerialization.jsonObject(with: stdinData)) as? [String: Any] ?? [:]

let env = ProcessInfo.processInfo.environment
let cwd = (stdinJSON["cwd"] as? String) ?? FileManager.default.currentDirectoryPath
let sessionIdRaw = (stdinJSON["session_id"] as? String) ?? String(UUID().uuidString.prefix(8))

var tmuxBlob: [String: Any]? = nil
var replyChannel: String? = nil
var replyTarget: String? = nil
if let pane = env["TMUX_PANE"], !pane.isEmpty {
    let target = sh(["tmux", "display-message", "-t", pane, "-p", "#S:#I.#P"]) ?? pane
    replyChannel = "tmux"
    replyTarget = target
    tmuxBlob = ["pane_id": pane, "target": target]
}

var lastMessage = ""
switch agent {
case "claude-code", "cursor":
    if let p = stdinJSON["transcript_path"] as? String, !p.isEmpty {
        log("transcript_path=\(p)")
        // Log file size + last few non-empty lines to debug stale-message bugs.
        if let raw = try? String(contentsOf: URL(fileURLWithPath: p), encoding: .utf8) {
            let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
            log("transcript: \(lines.count) lines, \(raw.count) bytes")
            for (i, line) in lines.suffix(5).enumerated() {
                let preview = String(line.prefix(160))
                log("  L-\(lines.count - lines.suffix(5).count + i): \(preview)")
            }
        } else {
            log("transcript: COULD NOT READ FILE")
        }
        // Race: Claude Code's Stop hook can fire before the assistant turn's
        // text is flushed to the .jsonl. If we read empty, retry briefly so
        // the panel shows the actual message instead of the "No assistant
        // message was read" placeholder. Cap the wait at ~1.5s — past that,
        // there's likely no assistant text (tool-only turn, interrupt, etc.)
        // and we should just post what we have.
        var attempts = 0
        let maxAttempts = 10
        while attempts < maxAttempts {
            lastMessage = extractLastAssistantMessage(transcriptPath: p)
            if !lastMessage.isEmpty { break }
            attempts += 1
            if attempts < maxAttempts { usleep(150_000) }  // 150ms
        }
        log("extracted message after \(attempts) retries (\(lastMessage.count) chars): \(String(lastMessage.prefix(160)))")
    } else {
        log("WARNING: no transcript_path in stdin payload")
    }
case "codex":
    lastMessage = (stdinJSON["last_assistant_message"] as? String) ?? ""
default:
    break
}

let title = "\(prettyAgentName(agent)) · \(URL(fileURLWithPath: cwd).lastPathComponent)"

// For Stop (turn_done), block this hook on the user's reply and emit
// `{"decision":"block","reason":"<reply>"}` on stdout — Claude Code resumes
// with that text as the next user prompt. Same mechanism Superwhisper's
// claude-hook uses (verified: its binary contains the literal string
// "Stop: relaying voice response via decision=block reason"). For other
// events, fire-and-forget — don't block the hook chain.
let blockingEvent = (event == "turn_done")
let requestId = UUID().uuidString

var payload: [String: Any] = [
    "session_id": "\(agent)-\(sessionIdRaw)",
    "agent": agent,
    "event": event,
    "title": title,
    "message": lastMessage,
    "cwd": cwd,
    "pid": Int(ProcessInfo.processInfo.processIdentifier),
    "ts": ISO8601DateFormatter().string(from: Date()),
]
if let tmuxBlob = tmuxBlob { payload["tmux"] = tmuxBlob }
if blockingEvent {
    payload["request_id"] = requestId
    payload["reply_channel"] = "hook-stdout"
} else {
    if let replyChannel = replyChannel { payload["reply_channel"] = replyChannel }
    if let replyTarget = replyTarget { payload["reply_target"] = replyTarget }
}
if let termPid = findAgentTerminalPID() {
    payload["terminal_pid"] = Int(termPid)
}

let payloadData = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()

func postEvent(_ data: Data, timeout: TimeInterval = 2.5) {
    var req = URLRequest(url: URL(string: "http://127.0.0.1:8731/event")!)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "content-type")
    req.httpBody = data
    req.timeoutInterval = timeout
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { _, _, _ in sem.signal() }.resume()
    _ = sem.wait(timeout: .now() + timeout + 0.5)
}

// Mirror Superwhisper's per-CWD disable mechanism: /tmp/crier-agent/disabled-<md5(PWD)>.
// Touched by `/crier off` (the SKILL.md skill) and by the UI's "Disable for
// this session" button. Filesystem-based so it survives daemon restarts and
// works without the daemon running at all.
func crierDisabledPath(forCwd cwd: String) -> String {
    let digest = Insecure.MD5.hash(data: Data(cwd.utf8))
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return "/tmp/crier-agent/disabled-\(hex)"
}

func isCwdDisabled(_ cwd: String) -> Bool {
    FileManager.default.fileExists(atPath: crierDisabledPath(forCwd: cwd))
}

func longPollReply(requestId: String, waitSeconds: Int) -> String? {
    guard let url = URL(string: "http://127.0.0.1:8731/reply?request_id=\(requestId)&wait=\(waitSeconds)") else { return nil }
    var req = URLRequest(url: url)
    req.timeoutInterval = TimeInterval(waitSeconds + 5)
    var result: String?
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, response, _ in
        if let http = response as? HTTPURLResponse, http.statusCode == 200,
           let data = data, !data.isEmpty,
           let s = String(data: data, encoding: .utf8) {
            result = s
        }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + .seconds(waitSeconds + 10))
    return result
}

log("start: agent=\(agent) event=\(event) blocking=\(blockingEvent) request_id=\(requestId)")
log("cwd=\(cwd) tmux_pane=\(env["TMUX_PANE"] ?? "-")")

// Short-circuit if the user has disabled Crier for this CWD (via `/crier
// off` skill or the UI's "Disable for this session" button). Skip the panel
// pop entirely, don't block the hook chain, just exit.
if isCwdDisabled(cwd) {
    log("disabled flag present for cwd=\(cwd) — skipping")
    exit(0)
}

postEvent(payloadData)
log("posted event (\(payloadData.count) bytes)")

if blockingEvent {
    log("long-polling /reply?request_id=\(requestId)&wait=540")
    if let reply = longPollReply(requestId: requestId, waitSeconds: 540), !reply.isEmpty {
        log("got reply (\(reply.count) chars): \(String(reply.prefix(80)))")
        // Wrap the user's text so Claude treats it as the next user message
        // rather than as out-of-band hook info. Without the framing, Claude
        // tends to respond with "Acknowledged — received via Stop hook" or
        // similar meta-acknowledgement instead of actually answering the
        // message. The XML-ish tags mirror Claude's own formatting habits.
        let phrasedReason = """
        The user replied via the Crier overlay. Treat the contents of the \
        <user_message> tag below as their next message and respond to it \
        directly — do not acknowledge that it came from a hook.

        <user_message>
        \(reply)
        </user_message>
        """
        let out: [String: Any] = ["decision": "block", "reason": phrasedReason]
        if let data = try? JSONSerialization.data(withJSONObject: out),
           let s = String(data: data, encoding: .utf8) {
            // FileHandle.write goes straight to fd 1 — bypasses any
            // print() buffering that could be lost when the process
            // exits before stdout flushes.
            FileHandle.standardOutput.write(Data((s + "\n").utf8))
            log("wrote stdout: \(s)")
        } else {
            log("ERROR: failed to serialize decision:block JSON")
        }
    } else {
        log("long-poll returned empty/timeout — exiting without decision:block")
    }
}
log("exit 0")
exit(0)
