# Superwhisper vs Crier — verified differences

Reference note. Captures what we actually learned about Superwhisper's plugin architecture by inspecting `/Applications/superwhisper.app/Contents/Resources/claude-hook` (Mach-O arm64 binary) and `npm pack @superwhisper/opencode@1.0.7`. **Several claims in early drafts of the spec were wrong** — this note records what's true so we don't drift back.

## How we verified

- `file` + `strings` on the SW `claude-hook` binary — extracted Swift symbol names, log strings, and embedded paths.
- `npm pack @superwhisper/opencode` — pulled the published OpenCode plugin and read its `.d.ts` and compiled `index.js`.
- Cross-referenced both with the public `superultrainc/superwhisper-claude-code` repo (the marketplace plugin shim that ships with SW.app).

## Key differences

### 1. IPC mechanism

| | SW | Crier |
| --- | --- | --- |
| Primary | File-based inbox at `~/Library/Application Support/superwhisper/agent/inbox/` | HTTP daemon on `127.0.0.1:8731` |
| Fallback | `superwhisper://` URL scheme deeplink (only if the inbox file write fails — the literal string `"Inbox write failed; deeplink fallback may be needed"` is in the binary) | None planned |

Implication: SW relies on the SW.app process having the inbox dir under its sandbox container and watching it via filesystem events. Crier doesn't need any app sandbox path; the daemon is just an HTTP server.

### 2. Reply path — **NOT keystroke injection**

The biggest spec correction. Earlier drafts assumed SW typed the user's voice transcription "into the focused text field," and that we needed a `.nonactivatingPanel` + deterministic-first-responder dance to be the focused destination. **That is not how SW works.**

The real mechanism (verified in `@superwhisper/opencode/dist/inbox.d.ts`):

```ts
interface InboxPayload {
  kind: "update" | "dismiss"
  sessionId, requestId, agent, status, summary, message,
  messageFile,         // path to a file containing the full message
  responseFile,        // path the plugin polls for the user's reply
  cwd, project, branch, title, hookPid
}
```

The plugin writes an inbox payload, then `await pollForResponse(responseFile)` — it **synchronously blocks** on a file polling loop. SW writes the user's transcription to that file. The plugin reads it back and hands it to OpenCode's session API as the next prompt. No keystrokes injected anywhere.

Crier mirrors the *pattern* (block-and-poll for the OpenCode plugin) but uses HTTP long-poll (`GET /reply?request_id=X&wait=N`) instead of file polling. Both are equivalent in shape; HTTP avoids sandbox path issues and supports multiple concurrent UIs.

### 3. The "focus-bug mitigation" architecture is unnecessary

Because (2) is wrong, the `.nonactivatingPanel` + "force first-responder before triggering SW" + "configure SW mode with UI hidden" sequence in early drafts was solving a problem that does not exist in current SW. Crier's UI panel still uses `.nonactivatingPanel` (so it can hold focus without activating the app — useful regardless), but we do not need to win a focus race against SW's recording window.

The README's old "Why passthrough works" and "The focus-bug mitigation" sections were deleted on this basis.

### 4. Event vocabulary

| | SW | Crier |
| --- | --- | --- |
| Event kinds | `kind: "update" \| "dismiss"` | `event: "turn_done" \| "needs_permission" \| "needs_input" \| "dismiss"` |
| Discriminator | One field, agent context lives in `status` / `summary` / fields | Four explicit kinds, semantic per Claude-Code-style hook events |

Crier is more granular but less abstract. Either works; Crier's mapping makes the wire payload easier to route to specific UI affordances ("ask for permission" vs "ask the user a question" vs "agent finished").

### 5. Hook coverage on Claude Code

Both wire the same five Claude Code hook events:

- `Stop`
- `Notification`
- `PreToolUse` matcher `AskUserQuestion`
- `PermissionRequest`
- `UserPromptSubmit`

SW routes them all to a single binary; the binary inspects stdin's `hook_event_name` to dispatch. Crier passes the event kind as an argv to `crier-emit`. Equivalent in effect.

### 6. Distribution

| | SW | Crier |
| --- | --- | --- |
| Claude Code | Marketplace plugin (`.claude-plugin/marketplace.json` + `plugin.json`) | Local-test installer (`scripts/install-local-claude-code.sh`); marketplace path planned |
| OpenCode | Published npm package `@superwhisper/opencode` | `packages/opencode-plugin/` shipped via `npm link` for local test |
| Runtime dependency | Requires `Superwhisper.app` to be installed (the hook binary lives in its bundle) | Self-hosted: `crier-daemon` + `crier-ui` are the runtime |
| Bundle | Closed source binary + audio assets (`Stop1-4.m4a`, `Notification1-3.wav`, `PreStop.m4a`, …) + LLM jinja templates (mistral, llama, deepseek, …) | Open source |

### 7. Multi-agent

SW has multi-session support internally (its binary has a `sessions-index.json` for tracking concurrent agent sessions), but its UI is one popup at a time. Crier targets multi-agent natively — the wire payload's `agent` field is first-class, and the UI is designed to list multiple live sessions side-by-side once we get there.

### 8. OpenCode plugin shape

Both plugins block synchronously waiting for the user's reply. SW's does more work in JS:

- Polls `responseFile`
- `extractFullText`, `extractSummary`, `isEndTurn` — message-shape inspection
- `parseQuestionResponse`, `normalizeQuestions`, `normalizePermissionReply` — non-trivial reply normalization to feed back into OpenCode's session API

Crier's plugin currently does the POST + long-poll only. The "feed `replyText` back into the OpenCode session" step is a TODO — needs OpenCode-API-version-specific code analogous to SW's normalize.ts. We left it explicit in `packages/opencode-plugin/src/index.ts`.

### 9. Audio cues

SW.app bundles dozens of audio assets and plays them on agent state transitions (Start, Stop, PreStop, Notification, NoResult). Crier has none. Adding optional audio cues is cheap (NSSound) and a nice ergonomic; not on the immediate roadmap.

### 10. AirPods / hands-free

Crier's spec includes AirPods stem-tap → `crier://dictate?session=<id>`. SW does not have an equivalent — you have to be at the keyboard or use SW's own dictation hotkey. This is one place Crier is intentionally a superset, not a copy.

## What this means for Crier (decisions on record)

- **Stay HTTP-first.** The HTTP daemon model is a strict superset of SW's file inbox: more flexible, no sandbox-path constraints, supports multiple concurrent UI clients. We do not need to mirror the inbox layout.
- **OpenCode plugin must block and poll**, just like SW's. Fire-and-forget loses the user's reply.
- **Drop the focus-bug mitigation theory.** Keep `.nonactivatingPanel` for its general "don't steal app focus" property, but stop pretending it's compensating for SW's keystroke injection (which doesn't exist).
- **`tmux send-keys` is Crier-specific** and a reasonable advantage. SW has no equivalent because SW assumes the agent is a vendor-managed app session (Claude Code TTY, OpenCode), not an arbitrary tmux pane.

## Files to revisit when this changes

If SW ships a new major version (or we discover their architecture has shifted), re-run the verification:

```bash
file /Applications/superwhisper.app/Contents/Resources/claude-hook
strings /Applications/superwhisper.app/Contents/Resources/claude-hook | grep -E '(Library|inbox|response|deeplink|hook_event|requestId)'
npm pack @superwhisper/opencode
tar -xzf superwhisper-opencode-*.tgz
cat package/dist/inbox.d.ts package/dist/index.d.ts
```

If any of the assumptions in this note no longer hold, update both this file and the README.
