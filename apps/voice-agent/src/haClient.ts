/**
 * Thin client around the Home Assistant REST API. Only the endpoints the agent
 * needs are wrapped. Uses the global fetch built into Node 22.
 *
 * Docs: https://developers.home-assistant.io/docs/api/rest/
 */

import { getSettings } from "./config"

export interface EntityState {
  entity_id: string
  state: string
  attributes: Record<string, unknown>
}

export class HomeAssistantClient {
  constructor(
    private readonly baseUrl: string,
    private readonly token: string,
    private readonly timeoutMs: number,
  ) {}

  private async request<T>(path: string, init?: RequestInit): Promise<T> {
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), this.timeoutMs)
    try {
      const res = await fetch(`${this.baseUrl.replace(/\/$/, "")}${path}`, {
        ...init,
        signal: controller.signal,
        headers: {
          Authorization: `Bearer ${this.token}`,
          "Content-Type": "application/json",
          ...(init?.headers ?? {}),
        },
      })
      if (!res.ok) {
        throw new Error(`HA ${path} -> ${res.status} ${res.statusText}`)
      }
      return (await res.json()) as T
    } finally {
      clearTimeout(timer)
    }
  }

  /** Return all entity states, optionally filtered to a single domain. */
  async getStates(domain?: string): Promise<EntityState[]> {
    const states = await this.request<EntityState[]>("/api/states")
    if (!domain) return states
    return states.filter((s) => s.entity_id.startsWith(`${domain}.`))
  }

  /** Call a Home Assistant service, e.g. light.turn_on. */
  async callService(
    domain: string,
    service: string,
    data: Record<string, unknown> = {},
  ): Promise<unknown> {
    return this.request(`/api/services/${domain}/${service}`, {
      method: "POST",
      body: JSON.stringify(data),
    })
  }

  /**
   * Call a service that returns response data (e.g. todo.get_items,
   * music_assistant.search, view_assist.get_timers) and return only the
   * `service_response` payload.
   */
  async callServiceWithResponse(
    domain: string,
    service: string,
    data: Record<string, unknown> = {},
  ): Promise<unknown> {
    const res = await this.request<{ service_response?: unknown }>(
      `/api/services/${domain}/${service}?return_response`,
      { method: "POST", body: JSON.stringify(data) },
    )
    return res.service_response ?? {}
  }

  private wsUrl(): string {
    return `${this.baseUrl.replace(/^http/, "ws").replace(/\/$/, "")}/api/websocket`
  }

  /**
   * Run one or more WebSocket API commands over a single short-lived
   * connection and return their results in order. The exposed-entity list and
   * the area/floor/device/entity registries are only available over the
   * WebSocket API, not REST.
   *
   * Docs: https://developers.home-assistant.io/docs/api/websocket/
   */
  async wsCommands<T = unknown>(
    commands: Array<{ type: string } & Record<string, unknown>>,
  ): Promise<T[]> {
    if (commands.length === 0) return []
    return new Promise<T[]>((resolve, reject) => {
      const ws = new WebSocket(this.wsUrl())
      const results = new Array<T>(commands.length)
      const idToIndex = new Map<number, number>()
      let nextId = 1
      let pending = commands.length
      let settled = false

      const timer = setTimeout(() => finish(new Error("HA websocket timeout")), this.timeoutMs)

      const finish = (err?: Error) => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        try {
          ws.close()
        } catch {
          // ignore close errors
        }
        if (err) reject(err)
        else resolve(results)
      }

      ws.addEventListener("message", (ev) => {
        let msg: {
          type: string
          id?: number
          success?: boolean
          result?: unknown
          error?: { message?: string }
        }
        try {
          const raw = typeof ev.data === "string" ? ev.data : String(ev.data)
          msg = JSON.parse(raw)
        } catch {
          return
        }
        if (msg.type === "auth_required") {
          ws.send(JSON.stringify({ type: "auth", access_token: this.token }))
          return
        }
        if (msg.type === "auth_invalid") {
          finish(new Error("HA websocket auth failed"))
          return
        }
        if (msg.type === "auth_ok") {
          commands.forEach((c, i) => {
            const id = nextId++
            idToIndex.set(id, i)
            ws.send(JSON.stringify({ ...c, id }))
          })
          return
        }
        if (msg.type === "result" && msg.id != null) {
          const idx = idToIndex.get(msg.id)
          if (idx == null) return
          if (!msg.success) {
            finish(
              new Error(
                `HA ws ${commands[idx].type}: ${msg.error?.message ?? "command failed"}`,
              ),
            )
            return
          }
          results[idx] = msg.result as T
          if (--pending === 0) finish()
        }
      })
      ws.addEventListener("error", () => finish(new Error("HA websocket error")))
      ws.addEventListener("close", () =>
        finish(new Error("HA websocket closed before completing")),
      )
    })
  }
}

let client: HomeAssistantClient | undefined

/** Process-wide singleton. */
export const getHaClient = (): HomeAssistantClient => {
  if (!client) {
    const s = getSettings()
    client = new HomeAssistantClient(s.haBaseUrl, s.haToken, s.requestTimeoutMs)
  }
  return client
}
