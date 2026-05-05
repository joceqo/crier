import Foundation
import CrierEmitCore

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
// Log invocation before any validation so we still have a trace when an
// agent's hook config passes the wrong number of arguments and we'd
// otherwise exit(2) before reaching the start-of-run log later in this file.
log("invoked argv=\(args.dropFirst().joined(separator: " "))")
guard args.count >= 3 else {
    log("argv malformed — expected `crier-emit <agent> <event>`, exiting 2")
    FileHandle.standardError.write(Data("usage: crier-emit <agent> <event>\n".utf8))
    exit(2)
}
let agent = args[1]
let event = args[2]

let stdinData = FileHandle.standardInput.readDataToEndOfFile()
let stdinJSON = (try? JSONSerialization.jsonObject(with: stdinData)) as? [String: Any] ?? [:]

let env = ProcessInfo.processInfo.environment
let crierPort = Int(env["CRIER_PORT"] ?? "") ?? 8731
let crierBase = "http://127.0.0.1:\(crierPort)"
let cwd = (stdinJSON["cwd"] as? String) ?? FileManager.default.currentDirectoryPath
let sessionIdRaw = (stdinJSON["session_id"] as? String) ?? String(UUID().uuidString.prefix(8))
// Same id we post on the wire and persist for per-session disable flags.
// `<agent>-<rawSessionId>` keeps two identical raw ids from different
// agents (claude-code vs codex) from colliding.
let fullSessionId = "\(agent)-\(sessionIdRaw)"

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
case "claude-code", "cursor", "opencode":
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
        // text is flushed to the .jsonl. Poll until a re-read matches so we
        // don't ship a still-growing file as stable too early. Cap ~1.35s.
        // First read is "free" (no sleep) — if the second confirms it, we
        // ship after one 150ms tick. Older code required two confirmations
        // (300ms minimum); empirically one is plenty and halves the delay
        // before the overlay pops.
        let stabilityPollStart = Date()
        var best = CrierEmitCore.extractLastAssistantMessage(transcriptPath: p)
        var stable = 0
        for _ in 0..<9 {
            usleep(150_000)
            let next = CrierEmitCore.extractLastAssistantMessage(transcriptPath: p)
            if next == best {
                stable += 1
                if stable >= 1 { break }
            } else {
                best = next
                stable = 0
            }
        }
        lastMessage = best
        let pollMs = Int(Date().timeIntervalSince(stabilityPollStart) * 1000)
        log("extracted message after \(pollMs)ms stability poll (\(lastMessage.count) chars): \(String(lastMessage.prefix(160)))")
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
// `{"decision":"block","reason":"<reply>"}` on stdout — the agent resumes
// with that text as the next user prompt. Same mechanism Superwhisper's
// claude-hook uses (verified: its binary contains only `decision`, `block`,
// `reason` symbols and no CGEvent/AX symbols at all). For other events,
// fire-and-forget — don't block the hook chain.
//
// Earlier versions excluded claude-code here on the assumption that
// Claude Code 2.1's Stop hook ran with `async: true` (stdout ignored).
// That turned out to be wrong: SW's plugin installs an unasync Stop hook
// and decision:block round-trips fine. Crier now uses the same path so
// replies don't depend on CGEventPost / Accessibility / focus races.
// To answer in the terminal instead, the user dismisses the panel — the
// UI POSTs an empty /reply, this hook returns without decision JSON, and
// Claude Code falls through to its normal prompt.
let blockingEvent = (event == "turn_done")
// Claude Code uses the pre-queue path (mirrors Superwhisper's claude-hook):
// short initial drain on session_id, no fixed long-poll ceiling, terminal
// stays free, no "Stop hook error" UI label. Other agents keep the legacy
// request_id-based /reply long-poll because their UIs / hook ergonomics
// already work with it.
let useQueueDrain = blockingEvent && agent == "claude-code"
let requestId = UUID().uuidString

var payload: [String: Any] = [
    "session_id": fullSessionId,
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
    // request_id is still useful for diagnostics on both paths even when
    // the queue path keys on session_id rather than request_id.
    payload["request_id"] = requestId
    payload["reply_channel"] = useQueueDrain ? "hook-stdout-queue" : "hook-stdout"
} else {
    if let replyChannel = replyChannel { payload["reply_channel"] = replyChannel }
    if let replyTarget = replyTarget { payload["reply_target"] = replyTarget }
}
if let termPid = findAgentTerminalPID() {
    payload["terminal_pid"] = Int(termPid)
}

let payloadData = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()

func postEvent(_ data: Data, timeout: TimeInterval = 2.5) {
    var req = URLRequest(url: URL(string: "\(crierBase)/event")!)
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
func isCwdDisabled(_ cwd: String) -> Bool {
    FileManager.default.fileExists(atPath: CrierEmitCore.disabledPath(forCwd: cwd))
}

/// Synchronously asks the daemon how many UI clients are currently
/// long-polling /current. Used to decide whether the TTY readline
/// fallback should activate. Returns `nil` if the daemon is unreachable
/// (caller should treat that as "no UI" so the TTY fallback engages and
/// the hook can still be answered).
// Tiny mutable box so URLSession's @Sendable completion handler can write a
// result that a synchronous caller (parked on a semaphore) reads back. The
// semaphore wait establishes happens-before with the closure, so no lock is
// needed — `@unchecked Sendable` documents the manual reasoning.
private final class MutableBox<T>: @unchecked Sendable {
    var value: T
    init(_ v: T) { self.value = v }
}

func uiSubscriberCount(timeout: TimeInterval = 1.0) -> Int? {
    guard let url = URL(string: "\(crierBase)/status") else { return nil }
    var req = URLRequest(url: url)
    req.timeoutInterval = timeout
    let count = MutableBox<Int?>(nil)
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, response, _ in
        defer { sem.signal() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let data = data,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let n = obj["ui_subscribers"] as? Int else { return }
        count.value = n
    }.resume()
    _ = sem.wait(timeout: .now() + timeout + 0.5)
    return count.value
}

func longPollReply(requestId: String, waitSeconds: Int) -> String? {
    guard let url = URL(string: "\(crierBase)/reply?request_id=\(requestId)&wait=\(waitSeconds)") else { return nil }
    var req = URLRequest(url: url)
    req.timeoutInterval = TimeInterval(waitSeconds + 5)
    let result = MutableBox<String?>(nil)
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, response, _ in
        if let http = response as? HTTPURLResponse, http.statusCode == 200,
           let data = data, !data.isEmpty,
           let s = String(data: data, encoding: .utf8) {
            result.value = s
        }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + .seconds(waitSeconds + 10))
    return result.value
}

/// Pre-queue drain. Used by claude-code's blocking Stop hook (mirrors
/// Superwhisper's claude-hook short poll). Returns immediately if the user
/// already queued a reply during the turn; otherwise waits up to
/// `baseWaitMs` (extended on the daemon side while the engage flag is in
/// the future). Empty result → no reply, hook exits 0.
func drainReplyQueue(sessionId: String, baseWaitMs: Int) -> String? {
    guard let url = URL(string: "\(crierBase)/reply/drain?session_id=\(sessionId)&wait_ms=\(baseWaitMs)") else { return nil }
    var req = URLRequest(url: url)
    // Engage extensions can push the actual wait well past baseWaitMs, so
    // give the URLSession a generous ceiling. 540 s matches the legacy
    // long-poll cap and is enough for any "user is actively typing"
    // session.
    req.timeoutInterval = 600
    let result = MutableBox<String?>(nil)
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, response, _ in
        if let http = response as? HTTPURLResponse, http.statusCode == 200,
           let data = data, !data.isEmpty,
           let s = String(data: data, encoding: .utf8) {
            result.value = s
        }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + .seconds(610))
    return result.value
}

log("start: agent=\(agent) event=\(event) blocking=\(blockingEvent) request_id=\(requestId)")
log("cwd=\(cwd) tmux_pane=\(env["TMUX_PANE"] ?? "-")")

// Short-circuit if Crier is disabled — globally (menu-bar toggle), for
// this CWD (`/crier off` skill), or for this specific conversation (the
// badge X dialog / Conversations window). All three skip the panel pop
// and exit 0 so the hook chain unblocks normally.
if CrierEmitCore.isGloballyDisabled() {
    log("global disable flag present — skipping")
    exit(0)
}
if isCwdDisabled(cwd) {
    log("disabled flag present for cwd=\(cwd) — skipping")
    exit(0)
}
if CrierEmitCore.isSessionDisabled(fullSessionId) {
    log("disabled flag present for session=\(fullSessionId) — skipping")
    exit(0)
}

// Short-circuit when no Crier UI is listening. Posting an event that
// nobody will see, then blocking the hook for 9 minutes, is worse than
// just letting Claude continue. Two probes 200 ms apart absorb the
// brief window where the UI is between long-polls (handleEvent runs
// before subscribeLoop re-issues GET /current).
func uiAlive() -> Bool {
    if (uiSubscriberCount() ?? 0) > 0 { return true }
    Thread.sleep(forTimeInterval: 0.2)
    return (uiSubscriberCount() ?? 0) > 0
}
if !uiAlive() {
    log("no Crier UI listening — skipping (treat like /crier off)")
    exit(0)
}

if CrierEmptyMessageDiagnostic.shouldLogEmptyMessage(event: event),
   CrierEmptyMessageDiagnostic.isEffectivelyEmptyMessage(lastMessage) {
    var rec: [String: Any] = [
        "ts": CrierEmptyMessageDiagnostic.nowTS(),
        "kind": "empty_assistant_extract",
        "source": "crier-emit",
        "agent": agent,
        "event": event,
        "cwd": cwd,
        "session_id": fullSessionId,
        "stdin_json_keys": stdinJSON.keys.sorted().map { $0 },
    ]
    if let tp = stdinJSON["transcript_path"] as? String {
        rec["transcript_path"] = tp
        if !tp.isEmpty,
           let raw = try? String(contentsOf: URL(fileURLWithPath: tp), encoding: .utf8) {
            let lines = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            let tail = lines.suffix(8).map { String($0.prefix(400)) }
            rec["transcript_line_count"] = lines.count
            rec["transcript_tail_jsonl_lines"] = Array(tail)
            rec["transcript_byte_count"] = raw.count
        } else if !tp.isEmpty {
            rec["transcript_read_ok"] = false
        }
    }
    rec["blocking_turn"] = blockingEvent
    if blockingEvent { rec["request_id"] = requestId }
    rec["note"] = "Hook path produced no assistant text before POST /event; tail lines help debug jsonl timing/shape."
    CrierEmptyMessageDiagnostic.append(record: rec)
}

postEvent(payloadData)
log("posted event (\(payloadData.count) bytes)")

if blockingEvent {
    // Wait for the user's reply. Two paths:
    //   • claude-code → /reply/drain on session_id with a short initial
    //     window. The user can pre-queue during the turn, or start typing
    //     after the hook fires (the daemon extends the wait via /reply/engage).
    //     Empty drain → exit 0, terminal continues normally.
    //   • everyone else → legacy /reply long-poll on request_id.
    // The TTY readline fallback that used to race this was removed because
    // it leaked terminal escape sequences (focus events, mouse motion)
    // into the visible terminal whenever the agent's TUI had the tty in
    // raw mode. The earlier `uiAlive()` short-circuit guarantees a UI is
    // connected before we get here.
    let replyText: String?
    if useQueueDrain {
        // 5-minute base wait — matches Superwhisper's claude-hook poll
        // ceiling (verified in superwhisper-claude-code-plugin-analysis.md
        // bash MVP: `for _ in $(seq 1 300); do ... sleep 1; done`). The
        // sync Stop hook can sit on /reply/drain that long without
        // blocking terminal input — Claude Code accepts keys into the
        // prompt while the hook runs, and UserPromptSubmit firing pipes
        // a "dismiss" event which clears the queue and releases the
        // drain immediately. So during those 5 min the user can type
        // either in the Crier overlay (drain wakes via /reply/queue) or
        // in the terminal (drain releases via UserPromptSubmit dismiss),
        // whichever they prefer.
        log("draining reply queue (session_id=\(fullSessionId))")
        replyText = drainReplyQueue(sessionId: fullSessionId, baseWaitMs: 300_000)
    } else {
        log("waiting for overlay reply (request_id=\(requestId))")
        replyText = longPollReply(requestId: requestId, waitSeconds: 540)
    }
    log("reply from overlay: \(String(replyText?.prefix(80) ?? "nil"))")

    if let reply = replyText, !reply.isEmpty {
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
        log("overlay and terminal both timed out — exiting without decision:block")
    }
}
log("exit 0")
exit(0)
