import type { Plugin } from "@opencode-ai/plugin"
import { randomUUID } from "node:crypto"

const ENDPOINT = process.env.CRIER_ENDPOINT ?? "http://127.0.0.1:8731"
const REPLY_TIMEOUT_SEC = Number(process.env.CRIER_REPLY_TIMEOUT ?? 300)

export const Crier: Plugin = async ({ directory }) => ({
  event: async ({ event }) => {
    // event.type is a union of well-known SDK names; we widen to any to
    // tolerate naming drift between OpenCode versions. The SW plugin does
    // similar (it inspects event shape rather than relying on the type tag
    // alone).
    const e = event as any
    let kind: "turn_done" | "needs_permission" | null = null
    if (e.type === "session.idle") kind = "turn_done"
    else if (e.type === "permission.asked" || e.type === "permission.ask") kind = "needs_permission"
    if (!kind) return

    const requestId = randomUUID()
    const sessionId = e.properties?.sessionID ?? e.properties?.sessionId

    try {
      await fetch(`${ENDPOINT}/event`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          agent: "opencode",
          event: kind,
          request_id: requestId,
          session_id: sessionId,
          cwd: directory,
          reply_channel: "http-poll",
          reply_target: requestId,
          ts: new Date().toISOString(),
        }),
      })
    } catch {
      return
    }

    // Block the OpenCode event handler on the user's reply. SW's plugin uses
    // a polled response file for this; we use HTTP long-poll against the
    // daemon. The daemon returns 200+text once the UI POSTs /reply for our
    // request_id, or 204 on timeout.
    let replyText: string | null = null
    try {
      const res = await fetch(
        `${ENDPOINT}/reply?request_id=${encodeURIComponent(requestId)}&wait=${REPLY_TIMEOUT_SEC}`,
      )
      if (res.status === 200) replyText = await res.text()
    } catch {
      return
    }
    if (!replyText) return

    // TODO: feed `replyText` back into the OpenCode session as the next prompt.
    // SW's @superwhisper/opencode does this through normalize.ts + OpenCode's
    // session API; the exact call depends on the OpenCode plugin API version
    // shipping at the time. Left as the next step once we exercise the loop.
  },
})

export default Crier
