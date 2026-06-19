/**
 * Runtime configuration, read from the environment so the same image runs in
 * the cluster (secrets injected via Kubernetes) and locally.
 */

export interface Settings {
  /** Home Assistant base URL. In-cluster this is the ClusterIP service. */
  haBaseUrl: string
  /** Long-lived HA access token for the REST API. */
  haToken: string
  anthropicApiKey: string
  host: string
  port: number
  requestTimeoutMs: number
  /**
   * Home Assistant area this voice agent is physically associated with (e.g.
   * the room its speaker lives in). Used to choose a default media player and
   * to resolve the right thermostat when the user is not explicit. Match by
   * area name, case-insensitively. Empty when unset.
   */
  area: string
}

export const getSettings = (): Settings => ({
  haBaseUrl:
    process.env.VOICE_AGENT_HA_BASE_URL ?? "http://home-assistant:8123",
  haToken: process.env.VOICE_AGENT_HA_TOKEN ?? "",
  anthropicApiKey: process.env.ANTHROPIC_API_KEY ?? "",
  host: process.env.VOICE_AGENT_HOST ?? "0.0.0.0",
  port: Number(process.env.VOICE_AGENT_PORT ?? "8000"),
  requestTimeoutMs: Number(
    process.env.VOICE_AGENT_REQUEST_TIMEOUT_MS ?? "30000",
  ),
  area: process.env.VOICE_AGENT_AREA ?? "",
})
