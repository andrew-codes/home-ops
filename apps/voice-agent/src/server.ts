/**
 * HTTP entrypoint. Exposes POST /chat for the Home Assistant integration.
 *
 * Request:  {"text": "...", "conversationId": "...", "language": "en"}
 * Response: {"text": "...", "conversationId": "..."}
 */

import { randomUUID } from "node:crypto"
import {
  createServer,
  type IncomingMessage,
  type ServerResponse,
} from "node:http"

import { AIMessage, HumanMessage } from "@langchain/core/messages"

import { getSettings } from "./config"
import { buildGraph } from "./graph"

// Phrases that signal the user wants to end the conversation rather than issue
// a home-automation command. Matched case-insensitively with optional trailing
// punctuation.
const STOP_RE =
  /^\s*(stop|cancel|never ?mind|forget (?:it|that)|exit|quit|end|goodbye|bye|no thanks?|that'?s (?:all|it)|done|dismiss)\s*[.!?]?\s*$/i

const isStopRequest = (text: string): boolean =>
  text.trim() === "" || STOP_RE.test(text)

// Lazily build the graph on first use so the server can start and serve
// /health (k8s probes) even if construction would fail.
let graph: ReturnType<typeof buildGraph> | undefined
const getGraph = (): ReturnType<typeof buildGraph> => {
  if (!graph) graph = buildGraph()
  return graph
}

const readBody = (req: IncomingMessage): Promise<string> =>
  new Promise((resolve, reject) => {
    const chunks: Buffer[] = []
    req.on("data", (c) => chunks.push(c as Buffer))
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")))
    req.on("error", reject)
  })

const sendJson = (res: ServerResponse, status: number, body: unknown): void => {
  const payload = JSON.stringify(body)
  res.writeHead(status, { "Content-Type": "application/json" })
  res.end(payload)
}

const handleChat = async (
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> => {
  const raw = await readBody(req)
  const { text, conversationId } = JSON.parse(raw || "{}") as {
    text?: string
    conversationId?: string
  }
  if (text === undefined || text === null) {
    sendJson(res, 400, { error: "missing 'text'" })
    return
  }

  const threadId = conversationId ?? randomUUID()

  if (isStopRequest(text)) {
    sendJson(res, 200, { text: "", conversationId: threadId })
    return
  }

  const result = await getGraph().invoke(
    { messages: [new HumanMessage(text)] },
    { configurable: { thread_id: threadId } },
  )

  let reply = "Sorry, I couldn't handle that."
  for (let i = result.messages.length - 1; i >= 0; i--) {
    const m = result.messages[i]
    if (m instanceof AIMessage && typeof m.content === "string" && m.content) {
      reply = m.content
      break
    }
  }

  sendJson(res, 200, { text: reply, conversationId: threadId })
}

const server = createServer((req, res) => {
  if (req.method === "GET" && req.url === "/health") {
    sendJson(res, 200, { status: "ok" })
    return
  }
  if (req.method === "POST" && req.url === "/chat") {
    handleChat(req, res).catch((err) => {
      console.error(err)
      sendJson(res, 500, { error: (err as Error).message })
    })
    return
  }
  sendJson(res, 404, { error: "not found" })
})

const { host, port } = getSettings()
server.listen(port, host, () => {
  console.log(`voice-agent listening on http://${host}:${port}`)
})
