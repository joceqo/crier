#!/usr/bin/env node
/**
 * Smoke test (no LLM): mocks `GET /reply` long-poll + `POST OpenCode client`.
 * Run from package root: `npm run smoke`
 */
import assert from "node:assert/strict"
import http from "node:http"

function mockClient(record) {
  return {
    session: {
      messages: async () => ({
        data: [
          {
            info: { role: "assistant", id: "m1" },
            parts: [
              {
                type: "text",
                text: "Synthetic assistant text for smoke test",
                id: "p1",
                sessionID: "sess-turn-1",
                messageID: "m1",
              },
            ],
          },
        ],
        error: undefined,
      }),
      message: async () => ({
        data: { parts: [{ type: "text", text: "fallback detail fetch", id: "p2", messageID: "m1", sessionID: "sess-turn-1" }] },
        error: undefined,
      }),
      promptAsync: async (opts) => {
        record.promptAsync.push(opts)
        return { error: undefined, request: {}, response: new Response() }
      },
    },
    postSessionIdPermissionsPermissionId: async (opts) => {
      record.permission.push(opts)
      return { error: undefined, request: {}, response: new Response() }
    },
  }
}

/** @typedef {{ promptAsync: unknown[], permission: unknown[] }} Record **/

/** @param {string} port */
function createDaemon(port, state) {
  /** @type {Map<string, import('node:http').ServerResponse>} */
  const waiters = new Map()

  const server = http.createServer((req, res) => {
    const url = new URL(req.url ?? "/", `http://127.0.0.1:${port}`)

    if (req.method === "POST" && url.pathname === "/event") {
      let raw = ""
      req.on("data", (c) => {
        raw += c
      })
      req.on("end", () => {
        const j = JSON.parse(raw)
        state.lastRequestId = j.request_id
        state.lastEvent = j
        res.writeHead(200, { "content-type": "application/json" })
        res.end("{}")
      })
      return
    }

    if (req.method === "GET" && url.pathname === "/reply") {
      const rid = url.searchParams.get("request_id")
      if (!rid) {
        res.writeHead(400)
        res.end()
        return
      }
      if (state.pendingReply.has(rid)) {
        const text = state.pendingReply.get(rid)
        state.pendingReply.delete(rid)
        res.writeHead(200, { "content-type": "text/plain; charset=utf-8" })
        res.end(text)
        return
      }
      waiters.set(rid, res)
      req.on("close", () => {
        if (waiters.get(rid) === res) waiters.delete(rid)
      })
      return
    }

    res.writeHead(404)
    res.end()
  })

  /** @param {string} rid @param {string} text */
  state.fulfill = (rid, text) => {
    const w = waiters.get(rid)
    if (w) {
      waiters.delete(rid)
      w.writeHead(200, { "content-type": "text/plain; charset=utf-8" })
      w.end(text)
    } else {
      state.pendingReply.set(rid, text)
    }
  }

  return server
}

const state = {
  /** @type {string | null} */
  lastRequestId: null,
  /** @type {any} */
  lastEvent: null,
  /** @type {Map<string, string>} */
  pendingReply: new Map(),
  /** @type {((rid: string, text: string) => void) | undefined} */
  fulfill: undefined,
}

const server = createDaemon(0, state)
await new Promise((resolve, reject) => {
  server.listen(0, "127.0.0.1", () => resolve(null))
  server.on("error", reject)
})
const a = server.address()
assert.ok(a && typeof a === "object")
process.env.CRIER_ENDPOINT = `http://127.0.0.1:${a.port}`

let Crier
try {
  ;({ default: Crier } = await import("../dist/index.js"))
} catch (e) {
  console.error("Import ../dist/index.js failed — run `npm run build` first.\n", e)
  process.exit(1)
}

/** @type {{ promptAsync: unknown[], permission: unknown[] }} */
const record = { promptAsync: [], permission: [] }
const hooks = await Crier({
  directory: "/tmp/crier-opencode-smoke",
  worktree: "/tmp/crier-opencode-smoke",
  client: mockClient(record),
})

// session.idle → long-poll → promptAsync
const p1 = hooks.event({
  event: { type: "session.idle", properties: { sessionID: "sess-turn-1" } },
})
await new Promise((r) => setTimeout(r, 20))
assert.ok(state.lastRequestId)
state.fulfill(state.lastRequestId, "  user reply line  ")
await p1

assert.equal(state.lastEvent.session_id, "sess-turn-1")
assert.equal(state.lastEvent.message, "Synthetic assistant text for smoke test")
assert.equal(state.lastEvent.title, "OpenCode")
assert.equal(record.promptAsync.length, 1)
assert.equal(record.promptAsync[0].path.id, "sess-turn-1")
assert.equal(record.promptAsync[0].body.parts[0].text, "user reply line")
assert.equal(record.permission.length, 0)

record.promptAsync.length = 0
state.lastRequestId = null

// permission.asked → long-poll → postSessionIdPermissionsPermissionId
// (OpenCode's actual emitted event name; older drafts of this smoke used
// permission.updated, which the plugin and OpenCode never agreed on.)
const p2 = hooks.event({
  event: {
    type: "permission.asked",
    properties: {
      id: "perm-xyz",
      type: "tool",
      sessionID: "sess-perm-1",
      messageID: "m1",
      title: "allow edits?",
      metadata: {},
      time: { created: Date.now() },
    },
  },
})
await new Promise((r) => setTimeout(r, 20))
state.fulfill(state.lastRequestId, "reject")
await p2

assert.equal(record.permission.length, 1)
assert.equal(record.permission[0].path.id, "sess-perm-1")
assert.equal(record.permission[0].path.permissionID, "perm-xyz")
assert.equal(record.permission[0].body.response, "reject")
assert.equal(record.promptAsync.length, 0)
assert.equal(state.lastEvent.message, "allow edits?")

server.close()
console.log("crier-plugin-smoke: ok")
