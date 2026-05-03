import type { Plugin } from "@opencode-ai/plugin"
import { randomUUID } from "node:crypto"
import { appendFileSync, mkdirSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

const ENDPOINT = process.env.CRIER_ENDPOINT ?? "http://127.0.0.1:8731"
const REPLY_TIMEOUT_SEC = Number(process.env.CRIER_REPLY_TIMEOUT ?? 300)
const OPENCODE_DEBUG = process.env.CRIER_OPENCODE_DEBUG === "1" || process.env.CRIER_OPENCODE_DEBUG === "true"

// Always-on file log mirrors the Swift hook's ~/.claude/crier-emit.log so every
// agent has a single tail target. Silent catch {} elsewhere in this plugin
// would otherwise hide why nothing reaches the daemon when OpenCode misbehaves.
// CRIER_LOG_DIR exists for the test suite — overriding $HOME breaks tool
// version managers (asdf etc.) that need the real $HOME to find node, so
// tests redirect just the log dir instead.
const LOG_DIR = process.env.CRIER_LOG_DIR ?? join(homedir(), ".claude")
const LOG_PATH = join(LOG_DIR, "crier-opencode-plugin.log")
try {
  mkdirSync(LOG_DIR, { recursive: true })
} catch {
  /* ignore — log() will surface the failure on first write attempt */
}

function fmt(args: unknown[]): string {
  return args
    .map((a) => {
      if (a instanceof Error) return `${a.name}: ${a.message}`
      if (typeof a === "string") return a
      try {
        return JSON.stringify(a)
      } catch {
        return String(a)
      }
    })
    .join(" ")
}

function log(...args: unknown[]) {
  const line = `[${new Date().toISOString()}] [pid:${process.pid}] ${fmt(args)}\n`
  try {
    appendFileSync(LOG_PATH, line)
  } catch {
    /* file system unavailable — fall back to stderr below */
  }
  if (OPENCODE_DEBUG) console.error("[crier/opencode-plugin]", ...args)
}

function debugLog(...args: unknown[]) {
  log(...args)
}

log("plugin module loaded", { endpoint: ENDPOINT, replyTimeoutSec: REPLY_TIMEOUT_SEC })

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

function readSessionId(e: { properties?: Record<string, unknown> }): string | undefined {
  const p = e.properties
  if (!p) return undefined
  const a = p.sessionID ?? p.sessionId
  return typeof a === "string" && a.length > 0 ? a : undefined
}

function normalizeRole(role: string | undefined): string {
  return String(role ?? "").toLowerCase()
}

/** Collect user-visible text from message parts (OpenCode part shapes vary by version). */
function extractFromParts(parts: any[] | undefined): string {
  if (!parts?.length) return ""
  const bits: string[] = []
  for (const p of parts) {
    if (!p) continue
    if (p.type === "text" && typeof p.text === "string") bits.push(p.text)
    else if (p.type === "reasoning" && typeof p.text === "string") bits.push(p.text)
    else if (p.type === "tool" && p.state?.status === "completed" && typeof p.state.output === "string")
      bits.push(p.state.output)
  }
  return bits.join("\n\n").trim()
}

/**
 * Latest assistant plain text for the Crier panel. Tries several `directory` query
 * variants (OpenCode uses directory vs worktree inconsistently), retries briefly to
 * beat session.idle vs persistence races, and falls back to per-message fetch when
 * the list endpoint returns empty parts.
 */
async function lastAssistantPlainText(
  client: {
    session: {
      messages: (opts: any) => Promise<any>
      message: (opts: any) => Promise<any>
    }
  },
  sessionId: string,
  directory: string,
  worktree: string,
): Promise<string> {
  const queryDirs = [...new Set([directory, worktree].filter((d) => typeof d === "string" && d.length > 0))]
  const queryVariants: (Record<string, string> | undefined)[] = queryDirs.map((directory) => ({ directory }))
  queryVariants.push(undefined)

  for (let attempt = 0; attempt < 3; attempt++) {
    if (attempt > 0) await sleep(120)

    for (const query of queryVariants) {
      const res = await client.session.messages({ path: { id: sessionId }, query })
      if (res.error) {
        debugLog("session.messages error", { sessionId, query, error: res.error })
        continue
      }
      const rows = res.data as Array<{ info: { role: string; id?: string }; parts: any[] }> | undefined
      if (!rows?.length) {
        debugLog("session.messages empty list", { sessionId, query, attempt })
        continue
      }

      for (let i = rows.length - 1; i >= 0; i--) {
        const row = rows[i]
        if (normalizeRole(row.info.role) !== "assistant") continue

        let t = extractFromParts(row.parts)
        if (!t && row.info.id) {
          try {
            const one = await client.session.message({
              path: { id: sessionId, messageID: row.info.id },
              query,
            })
            if (one.error) debugLog("session.message error", one.error)
            else t = extractFromParts(one.data?.parts)
          } catch (err) {
            debugLog("session.message threw", err)
          }
        }
        if (t) return t
      }
    }
  }

  debugLog("no assistant text after retries", { sessionId })
  return ""
}

function permissionSummary(e: any): string {
  const t = e.properties?.title
  return typeof t === "string" && t.trim().length > 0 ? t.trim() : "OpenCode needs your approval for a tool or action."
}

/** Map free-text UI reply to OpenCode permission API response. */
function mapPermissionTextToResponse(text: string): "once" | "always" | "reject" | null {
  const t = text.toLowerCase().trim()
  if (!t) return null
  if (/^(reject|deny|no)\b/.test(t) || t === "n") return "reject"
  if (/\b(always|all|forever|every)\b/.test(t)) return "always"
  return "once"
}

export const Crier: Plugin = async ({ directory, worktree, client }) => {
  log("plugin instantiated", { directory, worktree })
  return {
    event: async ({ event }) => {
      // event.type is a union of well-known SDK names; we widen to any to
      // tolerate naming drift between OpenCode versions. The SW plugin does
      // similar (it inspects event shape rather than relying on the type tag
      // alone).
      const e = event as any
      let kind: "turn_done" | "needs_permission" | null = null
      // OpenCode's official event list (opencode.ai/docs/plugins) only emits
      // `permission.asked` and `permission.replied`. Earlier code also matched
      // `permission.ask` / `permission.updated` defensively, but those names
      // never existed in OpenCode — they were dead branches that obscured
      // which matcher actually fires. Keep this list aligned with the docs.
      if (e.type === "session.idle") kind = "turn_done"
      else if (e.type === "permission.asked") kind = "needs_permission"
      if (!kind) {
        log("event ignored", { type: e.type })
        return
      }

      const requestId = randomUUID()
      const sessionId = readSessionId(e)
      if (!sessionId) {
        log("event missing sessionId — dropping", { type: e.type, propertyKeys: Object.keys(e.properties ?? {}) })
        return
      }

      log("event received", { type: e.type, kind, sessionId, requestId })

      let message = ""
      if (kind === "needs_permission") {
        message = permissionSummary(e)
      } else {
        try {
          message = await lastAssistantPlainText(client, sessionId, directory, worktree)
        } catch (err) {
          log("lastAssistantPlainText threw", err)
          message = ""
        }
      }
      log("message extracted", { kind, sessionId, requestId, len: message.length, preview: message.slice(0, 160) })

      try {
        const res = await fetch(`${ENDPOINT}/event`, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            agent: "opencode",
            event: kind,
            request_id: requestId,
            session_id: sessionId,
            cwd: directory,
            message,
            title: "OpenCode",
            reply_channel: "http-poll",
            reply_target: requestId,
            ts: new Date().toISOString(),
          }),
        })
        log("POST /event response", { status: res.status, requestId })
      } catch (err) {
        log("POST /event threw — daemon unreachable?", err)
        return
      }

      // Block the OpenCode event handler on the user's reply. SW's plugin uses
      // a polled response file for this; we use HTTP long-poll against the
      // daemon. The daemon returns 200+text once the UI POSTs /reply for our
      // request_id, or 204 on timeout.
      log("long-poll /reply start", { requestId, waitSec: REPLY_TIMEOUT_SEC })
      let replyText: string | null = null
      try {
        const res = await fetch(
          `${ENDPOINT}/reply?request_id=${encodeURIComponent(requestId)}&wait=${REPLY_TIMEOUT_SEC}`,
        )
        log("/reply response", { status: res.status, requestId })
        if (res.status === 200) replyText = await res.text()
      } catch (err) {
        log("/reply long-poll threw", err)
        return
      }
      if (replyText == null) {
        log("/reply timeout — no user reply", { requestId })
        return
      }
      const trimmed = replyText.trim()
      if (!trimmed) {
        log("/reply returned empty body — dropping", { requestId })
        return
      }
      log("reply received", { requestId, len: trimmed.length, preview: trimmed.slice(0, 160) })

      const query = directory ? { directory } : undefined

      if (kind === "needs_permission") {
        const permId = e.properties?.id
        if (typeof permId === "string" && permId.length > 0) {
          const response = mapPermissionTextToResponse(trimmed)
          if (response) {
            try {
              await client.postSessionIdPermissionsPermissionId({
                path: { id: sessionId, permissionID: permId },
                query,
                body: { response },
              })
              log("permission response posted", { sessionId, permId, response })
            } catch (err) {
              log("permission response threw", err)
            }
          } else {
            log("permission reply text did not map to a response", { trimmed: trimmed.slice(0, 80) })
          }
        } else {
          log("permission event missing id property — cannot answer", { propertyKeys: Object.keys(e.properties ?? {}) })
        }
        return
      }

      // turn_done — inject user text as the next user message and resume the agent.
      try {
        await client.session.promptAsync({
          path: { id: sessionId },
          query,
          body: {
            parts: [{ type: "text", text: trimmed }],
          },
        })
        log("session.promptAsync delivered reply", { sessionId, requestId })
      } catch (err) {
        log("session.promptAsync threw", err)
      }
    },
  }
}

export default Crier
