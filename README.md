# Crier

A native macOS popover that surfaces *any* CLI agent's last message wherever you are on screen, lets you reply by text or dictation (using whichever STT engine you want), and can be answered hands-free via an AirPods stem-tap when you're away from the keyboard.

**Status:** Working Claude Code vertical slice. The daemon, hook emitter, SwiftUI panel, reply long-poll, and tmux delivery paths are implemented; Claude Code has been manually tested. Codex, Cursor, OpenCode, and PTY-wrapped agents still need provider-specific validation before they should be treated as supported.

## Repo layout

```
Package.swift                       Swift package, executables + testable support modules
Sources/
  CrierDaemon/                      crier-daemon — local HTTP server (127.0.0.1:8731)
  CrierEmitCore/                    shared hook parsing / disable-state helpers
  CrierUI/                          crier-ui — floating NSPanel (LSUIElement)
  CrierEmit/                        crier-emit — hook adapter for Claude Code / Codex / Cursor
  CrierWrap/                        crier-wrap — PTY wrapper for agents with no hooks (aider, gemini-cli)
packages/
  opencode-plugin/                  @crier/opencode-plugin — TS plugin (OpenCode requires TS)
Tests/
  CrierEmitCoreTests/               XCTest coverage for transcript parsing and disable-state paths
```

Build and test:

```bash
swift build                                      # all four CLI/UI executables
swift test                                       # Swift unit tests
( cd packages/opencode-plugin && npm i && npm run build )
```

## Provider Status

| Provider | State | Next validation |
| --- | --- | --- |
| Claude Code | Manually tested end-to-end with `Stop` → Crier panel → reply via hook stdout. | Add more regression fixtures from real Claude transcripts. |
| Codex CLI | Adapter path implemented for `last_assistant_message`, not yet manually validated. | Install hooks with `codex_hooks = true`, verify `Stop` and `PermissionRequest` payloads. |
| Cursor CLI | Shares transcript parsing with Claude/Codex-style hooks, not yet manually validated. | Verify actual `stop` payload shape and permission hook behavior. |
| OpenCode | Plugin builds and posts/long-polls, but reply injection back into OpenCode is still TODO. | Wire `replyText` into the current OpenCode plugin/session API. |
| Aider / Gemini / generic PTY | Planned only. `crier-wrap` is still a stub. | Implement PTY wrapper, idle detection, scrollback extraction, and named-pipe reply delivery. |

---

## Why this exists

Superwhisper's plugin solves "agent finished → popover lets me dictate next prompt" but:

1. **Locked to Superwhisper.app** — pay a vendor, depend on their dictation engine, suffer their bugs (the popup-vs-popup focus bug documented in *Superwhisper × Claude Code — analyse du plugin*).
2. **Single agent at a time** — no concept of multiple concurrent sessions across Claude Code, Codex, OpenCode, Cursor running in different tmux windows / terminals.
3. **No hands-free reply path** — you still need to be at the keyboard to push-to-talk.

Crier keeps the **idea** (hook → floating window → reply travels back to the right terminal) and replaces every vendor-specific piece with an open, swappable component.

## Does every agent have the same hooks as Claude Code?

**Short answer: no.** Hook coverage is uneven. The system needs a **primary integration per agent** and a **PTY-wrapper fallback** for agents with no native hook surface.

| Agent                                | Native hook surface                                                                                                                                                                                                                                                                                                        | What we use                                                                                  | Notes                                                                                                                                                                                                                                                |
| ------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Claude Code**                      | Rich. `Stop`, `SubagentStop`, `Notification`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `SessionStart`, `SessionEnd`, `PreCompact` via `~/.claude/settings.json`                                                                                                                                                    | `Stop` (turn finished) + `Notification` (waiting for permission)                             | Reference implementation. Hook scripts receive JSON on stdin (session id, transcript path, last message).                                                                                                                                            |
| **OpenAI Codex CLI**                 | Rich, behind feature flag `codex_hooks = true`. Events: `SessionStart`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `UserPromptSubmit`, `Stop`. Config at `~/.codex/hooks.json` or inline `[[hooks.<Event>]]` in `~/.codex/config.toml` (also project-level under `<repo>/.codex/`).                                  | `Stop` (provides `last_assistant_message` directly) + `PermissionRequest` (waiting for user) | Hook gets JSON on stdin. Naming/shape near-identical to Claude Code's hooks — converging de-facto standard.                                                                                                                                          |
| **OpenCode** (sst)                   | Plugin-based, not config-line hooks. TS/JS plugin in `.opencode/plugins/` or npm package referenced in `opencode.json`'s `plugin` array. Plugin receives an `event` handler firing on `session.idle`, `session.created`, `permission.asked`, `tool.execute.before`, `message.updated`, etc.                                | `session.idle` (turn finished) + `permission.asked` (waiting for user)                       | Heavier integration: we ship `@crier/opencode-plugin` as a one-file npm package that POSTs to the daemon.                                                                                                                                            |
| **Cursor CLI** (`cursor-agent`)      | **Rich, as of Jan 2026.** `sessionStart`, `sessionEnd`, `beforeSubmitPrompt`, `preToolUse`, `postToolUse`, `subagentStart`, `subagentStop`, `beforeShellExecution`, `afterShellExecution`, `stop`, `afterAgentResponse`, `afterAgentThought`, `preCompact`, etc. via `~/.cursor/hooks.json` or `<repo>/.cursor/hooks.json`  | `stop` (turn finished) + `beforeShellExecution` w/ `permission: "ask"` (waiting for user)    | Hook receives JSON on stdin, can return JSON on stdout. Cursor docs claim it can also **load Claude Code's hook config** for cross-tool compat.                                                                                                      |
| **Cursor background agents** (cloud) | Webhooks (cloud)                                                                                                                                                                                                                                                                                                           | HTTPS webhook → daemon                                                                       | Different shape — cloud-hosted. Daemon exposes a webhook endpoint they POST to.                                                                                                                                                                      |
| **Aider**                            | None                                                                                                                                                                                                                                                                                                                       | PTY wrapper                                                                                  | Wrap the process and detect "waiting for input" from PTY prompt regex.                                                                                                                                                                               |
| **Gemini CLI**                       | Limited (config-level)                                                                                                                                                                                                                                                                                                     | PTY wrapper                                                                                  | Treat as no-hooks.                                                                                                                                                                                                                                   |
| **Generic future agent**             | Unknown                                                                                                                                                                                                                                                                                                                    | PTY wrapper                                                                                  | Default fallback.                                                                                                                                                                                                                                    |

The hook script is **not the same shell snippet across agents**. It's the same *daemon-side contract*: every integration ends up POSTing the same JSON event payload to `127.0.0.1:8731/event`.

> **Convergence note:** Claude Code, Codex CLI, and Cursor CLI have all converged on near-identical event vocabulary — `SessionStart`, `PreToolUse`, `PostToolUse`, `Stop`, `UserPromptSubmit`, plus a permission-request variant. Cursor's docs even claim cross-load compatibility with Claude Code's hook config. A single `crier-emit` binary really can serve all three with minimal per-agent branching. OpenCode is the outlier (plugin-based, dot-namespaced events like `session.idle`); aider/gemini-cli have nothing.

### Universal event payload

Every integration normalizes to this:

```json
{
  "session_id": "claude-code-tolaria-7ab3",
  "request_id": "f1c1a4b6-...",                  // for block-and-poll reply (OpenCode, PTY)
  "agent": "claude-code" | "codex" | "opencode" | "cursor" | "aider" | "...",
  "event": "turn_done" | "needs_permission" | "needs_input" | "dismiss",
  "title": "Claude Code · tolaria · main",
  "message": "Last assistant message rendered as plaintext (or markdown).",
  "cwd": "/Users/joce/Desktop/coding/tolaria",
  "tmux": { "session": "tolaria", "window": 2, "pane": 0 } | null,
  "pid": 12345,
  "reply_channel": "tmux" | "http-poll" | "named-pipe" | "webhook",
  "reply_target": "tolaria:2.0" | "<request_id>" | "/tmp/crier-7ab3.in" | "https://api.cursor.sh/...",
  "ts": "2026-05-02T14:32:11Z"
}
```

This is the single contract the overlay UI consumes. Adding a new agent = writing one adapter that emits this shape.

## Architecture

```text
┌───────────────────────────────────────────────────────────────┐
│ crier-daemon (Swift, runs at login, 127.0.0.1:8731)           │
│   - HTTP server: /event (in)  /reply (out)  /current (poll)   │
│   - Session registry (per session_id → reply_channel state)   │
│   - URL scheme: crier://dictate?session=...                   │
└───────────┬─────────────────────────────────┬─────────────────┘
            │                                 │
   POST /event from hooks                long-poll subscribe
            │                                 │
┌───────────┴─────────┐         ┌─────────────▼────────────────┐
│ Hook adapters       │         │ crier-ui (SwiftUI panel)     │
│  · crier-emit       │         │  - Floating NSPanel,         │
│    (claude-code,    │         │    .floating level,          │
│     codex, cursor)  │         │    .nonactivatingPanel       │
│  · @crier/opencode- │         │  - Multi-session list (left) │
│    plugin           │         │  - Message body (center)     │
│  · crier-wrap (PTY) │         │  - Reply: text + dictate     │
│  · webhook receiver │         │  - Per-agent badge / color   │
└─────────────────────┘         └──────────────────────────────┘
            │                                 │
            └────────── reply target ─────────┘
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
        tmux send-keys   named pipe      webhook POST
        (most CLI)       (PTY wrap)      (Cursor cloud)
```

### Why a daemon, not a menubar-only app

* A daemon survives across overlay-window dismissals (events keep arriving).
* It owns the single source of truth for "which sessions are live."
* It's also the URL-scheme target → Apple Shortcuts / AirPods triggers can hit it without the UI being focused.
* The UI becomes a thin client over the daemon's HTTP long-poll endpoint.

### Reply channels

| Channel | When | How |
| --- | --- | --- |
| `tmux send-keys` (push) | Agent runs inside a tmux pane (most common, since user already lives in tmux) | `tmux send-keys -t <target> -l -- "<text>" && tmux send-keys -t <target> Enter`. Use `-l` (literal) so the text isn't interpreted as a tmux key spec. The hook returns immediately; the daemon delivers asynchronously when the user submits. |
| `http-poll` (pull) | Agent has no tmux/PTY (OpenCode plugin, future cloud agents) | The hook/plugin POSTs `/event` with a `request_id`, then **blocks** on `GET /reply?request_id=…&wait=300`. The daemon pairs the long-poll waiter with the eventual `POST /reply` from the UI. This is how Superwhisper's `@superwhisper/opencode` delivers replies (via a polled response file); we use HTTP long-poll for the same effect. |
| Named pipe | Agent wrapped in our PTY (`crier-wrap`) | UI POSTs `/reply` with `channel: "named-pipe"`; the wrapper holds `/tmp/crier-<session>.in` and forwards to the PTY master. |
| Webhook | Cloud agents (Cursor background agents) | POST back to vendor's reply endpoint with auth from keychain. |

The daemon picks the delivery mechanism from the `reply_channel` field set at event time (the hook knows whether `$TMUX` is set, the OpenCode plugin always uses `http-poll`, etc.).

## Hook adapter — concrete examples

### Claude Code (`~/.claude/settings.json`)

```json
{
  "hooks": {
    "Stop": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "/usr/local/bin/crier-emit claude-code turn_done" }] }
    ],
    "Notification": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "/usr/local/bin/crier-emit claude-code needs_permission" }] }
    ]
  }
}
```

`crier-emit` reads the JSON Claude Code passes on stdin, reads `$TMUX`/`$TMUX_PANE`/`$PWD`, extracts the last assistant message from the transcript, and POSTs the normalized payload to `127.0.0.1:8731/event`. Same binary, different first arg (`claude-code` / `codex` / `cursor`) — the adapter logic differs only in *how it locates the last message*.

### Codex CLI (`~/.codex/config.toml`)

```toml
[features]
codex_hooks = true

[[hooks.Stop]]
type = "command"
command = "/usr/local/bin/crier-emit codex turn_done"
timeout = 10

[[hooks.PermissionRequest]]
type = "command"
command = "/usr/local/bin/crier-emit codex needs_permission"
timeout = 10
```

Codex's `Stop` event already includes `last_assistant_message` and `transcript_path` on stdin — no transcript scraping needed. The shape is so close to Claude Code's that the same emit binary handles both with a one-line per-agent branch (or skip the branch and treat them as the same code path).

### OpenCode (npm plugin referenced in `opencode.json`)

OpenCode hooks are TS/JS plugins, not config-line shell scripts. We ship `@crier/opencode-plugin` (see `packages/opencode-plugin/`). Unlike the Claude Code path, this plugin **blocks on the user's reply** via long-poll — that's how the user's voice transcription gets back into OpenCode as the next prompt:

```ts
const requestId = crypto.randomUUID()

await fetch("http://127.0.0.1:8731/event", {
  method: "POST",
  body: JSON.stringify({ agent: "opencode", event: "turn_done", request_id: requestId, ... }),
})

// Block until the UI posts /reply for this request_id (or 300s timeout).
const res = await fetch(`http://127.0.0.1:8731/reply?request_id=${requestId}&wait=300`)
const replyText = res.status === 200 ? await res.text() : null
// → feed replyText back to the OpenCode session as the next prompt
```

User opts in by adding `"@crier/opencode-plugin"` to `opencode.json`'s `plugin` array.

### Cursor CLI (`~/.cursor/hooks.json`)

```json
{
  "version": 1,
  "hooks": {
    "stop": [
      { "command": "/usr/local/bin/crier-emit cursor turn_done" }
    ],
    "beforeShellExecution": [
      { "command": "/usr/local/bin/crier-emit cursor needs_permission" }
    ]
  }
}
```

The `stop` hook fires when Cursor's agent loop ends and receives `{ status, loop_count, conversation_id, transcript_path, ... }` on stdin — close enough to Claude Code's `Stop` that the same emit binary handles both with a small per-agent branch. (Cursor also advertises Claude-Code-hook-config compatibility, but keep them explicit until that compat is proven.)

### PTY-wrapped agents (Aider, Gemini CLI, anything else with no hooks)

```bash
crier-wrap --agent aider --session-id auto -- aider
```

The wrapper:

* Spawns the agent under a PTY (`forkpty` or Swift's `Process` + pseudo-terminal).
* Mirrors PTY output to the user's actual terminal (so they still see normal output).
* Watches for "agent idle" patterns (configurable per agent — for Aider it's `> ` at end of line with no recent output).
* On idle: scrapes the last assistant message from the PTY scrollback buffer and POSTs to the daemon.
* Exposes a named pipe at `/tmp/crier-<session>.in`; reading from it pipes into the PTY's master.

This is more fragile than native hooks (regexes break when vendors restyle output). One-time per-agent investment.

## Dictation engine

The overlay UI's dictation button uses on-device speech-to-text. Two backends planned:

1. **Apple `Speech` framework** (free, on-device since macOS 14). Default. Decent latency, no model download, integrates with system permissions.
2. **whisper.cpp local** (whisper-large-v3 on Metal). Better accuracy, ~500 MB model on disk, requires first-run download. Optional.

> **An earlier version of this spec proposed a "Superwhisper passthrough" backend that depended on SW typing into Crier's focused reply field, plus an elaborate `.nonactivatingPanel` + first-responder dance to avoid focus-stealing.** That whole section was based on a misreading of how SW actually delivers replies. Inspecting `@superwhisper/opencode` and SW.app's `claude-hook` binary shows the real mechanism is **a polled response file in `~/Library/Application Support/superwhisper/agent/inbox/`** — no keystroke injection, no focus dependency. So the "focus-bug mitigation" architecture is unnecessary for our case; the long-poll reply path already covers the same ground without UI gymnastics. If we ever want to use SW as a dictation engine for Crier, the right integration is to write a Crier-side inbox payload with `responseFile`, not to hijack first-responder.

## Roadmap

1. **Done:** `crier-daemon` HTTP server — `POST /event`, `POST /reply`, `GET /current`, `GET /reply`.
2. **Done:** `crier-emit` for Claude Code — read stdin, scrape last assistant message, POST, block for reply on `turn_done`.
3. **Done:** `crier-ui` skeleton — NSPanel that pops on event, renders message markdown, and posts replies.
4. **Done:** Text reply loop — hook stdout for Claude Code, daemon-mediated `tmux send-keys`, and HTTP long-poll primitives.
5. **Current:** Provider validation — Codex, Cursor, and OpenCode need real hook/plugin runs.
6. **Next:** OpenCode reply injection — feed long-polled `replyText` back into the active OpenCode session.
7. **Next:** Apple `Speech` dictation — default backend, fastest to integrate.
8. **Later:** PTY wrapper (`crier-wrap`) — Aider first.
9. **Later:** Superwhisper / Handy passthrough backends.
10. **Later:** AirPods stem-tap trigger — Apple Shortcuts → `crier://dictate?session=<id>`.
