import Foundation

// crier-wrap --agent <name> [--session-id <id>] -- <cmd> [args...]
//
// PTY-wraps an agent that has no native hook surface (aider, gemini-cli, ...).
// Mirrors PTY output to the user's terminal, watches for an idle pattern,
// scrapes the last assistant message from scrollback, POSTs a turn_done
// event to the daemon, and exposes a named pipe at /tmp/crier-<session>.in
// for replies coming back from the UI.

let args = CommandLine.arguments
guard let dashDash = args.firstIndex(of: "--"), dashDash + 1 < args.count else {
    FileHandle.standardError.write(Data("usage: crier-wrap --agent <name> [--session-id <id>] -- <cmd> [args...]\n".utf8))
    exit(2)
}

// TODO: forkpty, idle detector per agent, named-pipe reply channel, emit events.
FileHandle.standardError.write(Data("crier-wrap: stub — would PTY-wrap and emit events\n".utf8))
