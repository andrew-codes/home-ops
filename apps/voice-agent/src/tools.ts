/**
 * LangChain tools, grouped by request category. Each subagent receives only the
 * tools relevant to its category — a tightly scoped tool set keeps each
 * subagent's decisions simple and reliable.
 *
 * Two invariants every tool upholds:
 *   - Reads only ever return entities exposed to the conversation assistant
 *     (see `registry.ts`); non-exposed entities are invisible to the agent.
 *   - Writes refuse to act on a non-exposed entity, so a hallucinated entity id
 *     can never reach Home Assistant.
 */

import { tool } from "@langchain/core/tools"
import { z } from "zod"

import { getHaClient } from "./haClient"
import {
  type EnrichedEntity,
  getAgentArea,
  getAllEntities,
  getExposedEntities,
  isExposed,
} from "./registry"

// --- shared helpers -------------------------------------------------------

/** Render an entity for the LLM: id, name, area/floor, state and chosen attrs. */
const describe = (e: EnrichedEntity, attrs: string[] = []): string => {
  const where = e.areaName
    ? ` [area: ${e.areaName}${e.floorName ? `, floor: ${e.floorName}` : ""}]`
    : ""
  const extra = attrs
    .filter((a) => e.attributes[a] != null)
    .map((a) => `${a}=${JSON.stringify(e.attributes[a])}`)
    .join(", ")
  return `${e.entity_id} (${e.friendlyName})${where}: ${e.state}${
    extra ? ` {${extra}}` : ""
  }`
}

const list = (entities: EnrichedEntity[], attrs: string[] = []): string =>
  entities.length === 0
    ? "(no matching exposed entities)"
    : entities.map((e) => describe(e, attrs)).join("\n")

/**
 * Guard a write: returns a refusal string when the entity is not exposed to the
 * conversation assistant, or null when it is safe to proceed.
 */
const refuseIfNotExposed = async (entityId: string): Promise<string | null> =>
  (await isExposed(entityId))
    ? null
    : `${entityId} is not available to the voice assistant.`

const clamp = (n: number, lo: number, hi: number): number =>
  Math.max(lo, Math.min(hi, n))

const findExposed = async (
  entityId: string,
): Promise<EnrichedEntity | undefined> => {
  const domain = entityId.split(".")[0]
  const entities = await getExposedEntities(domain)
  return entities.find((e) => e.entity_id === entityId)
}

// --- Music / media --------------------------------------------------------

const MEDIA_ATTRS = [
  "volume_level",
  "is_volume_muted",
  "media_title",
  "media_artist",
  "shuffle",
]

const listMediaPlayers = tool(
  async () => list(await getExposedEntities("media_player"), MEDIA_ATTRS),
  {
    name: "list_media_players",
    description:
      "List exposed media_player entities with their area, state and volume. " +
      "Use this to choose the player (by room/device name, or the agent's area).",
    schema: z.object({}),
  },
)

const searchMusic = tool(
  async ({ name, mediaType }) => {
    const data: Record<string, unknown> = { name, limit: 8 }
    if (mediaType) data["media_type"] = [mediaType]
    const res = (await getHaClient().callServiceWithResponse(
      "music_assistant",
      "search",
      data,
    )) as Record<string, Array<Record<string, unknown>>>
    const lines: string[] = []
    for (const [type, items] of Object.entries(res)) {
      for (const item of items ?? []) {
        if (item["uri"]) {
          lines.push(
            `${type}: ${item["name"] ?? item["uri"]} — uri=${item["uri"]}`,
          )
        }
      }
    }
    return lines.length ? lines.join("\n") : "(no matches)"
  },
  {
    name: "search_music",
    description:
      "Search Music Assistant for an artist, track, album or playlist. Returns " +
      "matches with a `uri` to pass to play_music.",
    schema: z.object({
      name: z.string().describe("Search query, e.g. the song or artist name"),
      mediaType: z
        .enum(["artist", "album", "track", "playlist", "radio"])
        .optional(),
    }),
  },
)

const playMusic = tool(
  async ({ entityId, mediaId, mediaType }) => {
    const refusal = await refuseIfNotExposed(entityId)
    if (refusal) return refusal
    const ha = getHaClient()
    // Spec: set volume to 50% before playing, then play via Music Assistant.
    await ha.callService("media_player", "volume_set", {
      entity_id: entityId,
      volume_level: 0.5,
    })
    await ha.callService("music_assistant", "play_media", {
      entity_id: entityId,
      media_id: mediaId,
      media_type: mediaType,
    })
    return `Playing on ${entityId} at 50% volume.`
  },
  {
    name: "play_music",
    description:
      "Play a library item on a media player via Music Assistant. Sets volume " +
      "to 50% first. mediaId is a uri from search_music (or a plain name).",
    schema: z.object({
      entityId: z.string(),
      mediaId: z.string().describe("A Music Assistant uri, or an item name"),
      mediaType: z.enum(["artist", "album", "track", "playlist", "radio"]),
    }),
  },
)

const MEDIA_COMMANDS = {
  pause: "media_pause",
  resume: "media_play",
  stop: "media_stop",
  next: "media_next_track",
  previous: "media_previous_track",
} as const

const mediaControl = tool(
  async ({ entityId, command }) => {
    const refusal = await refuseIfNotExposed(entityId)
    if (refusal) return refusal
    await getHaClient().callService("media_player", MEDIA_COMMANDS[command], {
      entity_id: entityId,
    })
    return `${command} on ${entityId}.`
  },
  {
    name: "media_control",
    description:
      "Control playback: pause, resume/play, stop, next/skip, previous.",
    schema: z.object({
      entityId: z.string(),
      command: z.enum(["pause", "resume", "stop", "next", "previous"]),
    }),
  },
)

const setShuffle = tool(
  async ({ entityId, enabled }) => {
    const refusal = await refuseIfNotExposed(entityId)
    if (refusal) return refusal
    await getHaClient().callService("media_player", "shuffle_set", {
      entity_id: entityId,
      shuffle: enabled,
    })
    return `Shuffle ${enabled ? "on" : "off"} for ${entityId}.`
  },
  {
    name: "set_shuffle",
    description: "Turn shuffle on or off for a media player.",
    schema: z.object({ entityId: z.string(), enabled: z.boolean() }),
  },
)

const setVolume = tool(
  async ({ entityId, level }) => {
    const refusal = await refuseIfNotExposed(entityId)
    if (refusal) return refusal
    const volume = clamp(level, 0, 1)
    await getHaClient().callService("media_player", "volume_set", {
      entity_id: entityId,
      volume_level: volume,
    })
    return `Set ${entityId} volume to ${Math.round(volume * 100)}%.`
  },
  {
    name: "set_volume",
    description:
      "Set absolute volume. level is 0.0–1.0 (e.g. 'volume to 30%' → 0.3).",
    schema: z.object({
      entityId: z.string(),
      level: z.number().min(0).max(1),
    }),
  },
)

const changeVolume = tool(
  async ({ entityId, delta }) => {
    const refusal = await refuseIfNotExposed(entityId)
    if (refusal) return refusal
    const player = await findExposed(entityId)
    const current = Number(player?.attributes["volume_level"] ?? 0)
    const volume = clamp(current + delta, 0, 1)
    await getHaClient().callService("media_player", "volume_set", {
      entity_id: entityId,
      volume_level: volume,
    })
    return `Set ${entityId} volume to ${Math.round(volume * 100)}%.`
  },
  {
    name: "change_volume",
    description:
      "Adjust volume relative to its current level. Use delta +0.1 to turn up " +
      "(louder/increase) and -0.1 to turn down (quieter/decrease).",
    schema: z.object({
      entityId: z.string(),
      delta: z.number().describe("e.g. 0.1 louder, -0.1 quieter"),
    }),
  },
)

const setMute = tool(
  async ({ entityId, muted }) => {
    const refusal = await refuseIfNotExposed(entityId)
    if (refusal) return refusal
    await getHaClient().callService("media_player", "volume_mute", {
      entity_id: entityId,
      is_volume_muted: muted,
    })
    return `${muted ? "Muted" : "Unmuted"} ${entityId}.`
  },
  {
    name: "set_mute",
    description: "Mute or unmute a media player.",
    schema: z.object({ entityId: z.string(), muted: z.boolean() }),
  },
)

// --- Lists / groceries ----------------------------------------------------

const getTodoItems = tool(
  async ({ entityId }) => {
    const refusal = await refuseIfNotExposed(entityId)
    if (refusal) return refusal
    const res = (await getHaClient().callServiceWithResponse(
      "todo",
      "get_items",
      { entity_id: entityId },
    )) as Record<string, { items?: Array<{ summary?: string }> }>
    const items = res[entityId]?.items ?? Object.values(res)[0]?.items ?? []
    if (items.length === 0) return "(list is empty)"
    return items.map((i) => i.summary ?? "").join("\n")
  },
  {
    name: "get_todo_items",
    description:
      "Read the current items of a todo list so you can dedupe before adding. " +
      "Returns one item per line.",
    schema: z.object({
      entityId: z
        .string()
        .describe("todo entity, e.g. todo.to_do_groceries"),
    }),
  },
)

const addTodoItem = tool(
  async ({ listEntityId, item }) => {
    const refusal = await refuseIfNotExposed(listEntityId)
    if (refusal) return refusal
    await getHaClient().callService("ms365_todo", "new_todo", {
      entity_id: listEntityId,
      subject: item,
    })
    return `Added "${item}" to ${listEntityId}.`
  },
  {
    name: "add_todo_item",
    description:
      "Add an item to a todo list via ms365_todo.new_todo. Only call this " +
      "after confirming (via get_todo_items) the item is not already present.",
    schema: z.object({
      listEntityId: z.string(),
      item: z.string(),
    }),
  },
)

// --- Climate --------------------------------------------------------------

const CLIMATE_ATTRS = [
  "temperature",
  "target_temp_high",
  "target_temp_low",
  "current_temperature",
  "hvac_action",
]

const listClimate = tool(
  async () => list(await getExposedEntities("climate"), CLIMATE_ATTRS),
  {
    name: "list_climate",
    description:
      "List exposed climate (thermostat) entities with area, floor, current " +
      "target temperature and mode. Use this to select the right thermostat.",
    schema: z.object({}),
  },
)

const setTemperature = tool(
  async ({ entityId, temperature }) => {
    const refusal = await refuseIfNotExposed(entityId)
    if (refusal) return refusal
    const target = clamp(Math.round(temperature), 60, 74)
    await getHaClient().callService("climate", "set_temperature", {
      entity_id: entityId,
      temperature: target,
    })
    return `Set ${entityId} to ${target} degrees.`
  },
  {
    name: "set_temperature",
    description:
      "Set the target temperature for a climate entity. Value is clamped to " +
      "the safe range 60–74 and rounded to a whole number.",
    schema: z.object({
      entityId: z.string(),
      temperature: z.number(),
    }),
  },
)

// --- Weather --------------------------------------------------------------

const readForecast = async (entityId: string): Promise<string> => {
  const e = await findExposed(entityId)
  if (!e || e.state === "unknown" || e.state === "unavailable" || !e.state) {
    return `(no forecast available from ${entityId})`
  }
  return e.state
}

const getTodayForecast = tool(
  async () => readForecast("input_text.today_forecast"),
  {
    name: "get_today_forecast",
    description: "Get today's weather forecast text (input_text.today_forecast).",
    schema: z.object({}),
  },
)

const getDailyForecast = tool(
  async () => readForecast("input_text.daily_forecast"),
  {
    name: "get_daily_forecast",
    description:
      "Get the multi-day weather forecast text (input_text.daily_forecast) " +
      "for questions about a future day.",
    schema: z.object({}),
  },
)

// --- Locks ----------------------------------------------------------------

const listLocks = tool(async () => list(await getExposedEntities("lock")), {
  name: "list_locks",
  description: "List exposed lock entities and their locked/unlocked state.",
  schema: z.object({}),
})

const lockDoor = tool(
  async ({ entityId }) => {
    const refusal = await refuseIfNotExposed(entityId)
    if (refusal) return refusal
    await getHaClient().callService("lock", "lock", { entity_id: entityId })
    return `Locked ${entityId}.`
  },
  {
    name: "lock_door",
    description:
      "Lock a door. There is intentionally no unlock capability — never unlock.",
    schema: z.object({ entityId: z.string() }),
  },
)

// --- Lights ---------------------------------------------------------------

const listLights = tool(
  async () => list(await getExposedEntities("light"), ["brightness"]),
  {
    name: "list_lights",
    description:
      "List exposed light entities with their on/off state and brightness.",
    schema: z.object({}),
  },
)

const setLight = tool(
  async ({ entityId, on, brightnessPct }) => {
    const refusal = await refuseIfNotExposed(entityId)
    if (refusal) return refusal
    const ha = getHaClient()
    if (on) {
      const data: Record<string, unknown> = { entity_id: entityId }
      if (brightnessPct != null) {
        data["brightness_pct"] = clamp(brightnessPct, 0, 100)
      }
      await ha.callService("light", "turn_on", data)
      return `Turned on ${entityId}${
        brightnessPct != null ? ` at ${brightnessPct}%` : ""
      }.`
    }
    await ha.callService("light", "turn_off", { entity_id: entityId })
    return `Turned off ${entityId}.`
  },
  {
    name: "set_light",
    description:
      "Turn a light on or off; optionally set brightness when turning on.",
    schema: z.object({
      entityId: z.string().describe("Full light entity id, e.g. light.kitchen"),
      on: z.boolean(),
      brightnessPct: z.number().min(0).max(100).optional(),
    }),
  },
)

// --- Fans -----------------------------------------------------------------

const FAN_ATTRS = ["percentage", "preset_mode", "oscillating"]

const listFans = tool(
  async () => list(await getExposedEntities("fan"), FAN_ATTRS),
  {
    name: "list_fans",
    description:
      "List exposed fan entities with their on/off state, speed percentage, " +
      "and preset mode. Use this to choose the right fan.",
    schema: z.object({}),
  },
)

const setFan = tool(
  async ({ entityId, on, speedPct }) => {
    const refusal = await refuseIfNotExposed(entityId)
    if (refusal) return refusal
    const ha = getHaClient()
    if (on) {
      const data: Record<string, unknown> = { entity_id: entityId }
      if (speedPct != null) {
        data["percentage"] = clamp(Math.round(speedPct), 0, 100)
      }
      await ha.callService("fan", "turn_on", data)
      return `Turned on ${entityId}${speedPct != null ? ` at ${Math.round(speedPct)}%` : ""}.`
    }
    await ha.callService("fan", "turn_off", { entity_id: entityId })
    return `Turned off ${entityId}.`
  },
  {
    name: "set_fan",
    description:
      "Turn a fan on or off; optionally set speed when turning on. " +
      "speedPct is 0–100 (e.g. 'low' ≈ 33, 'medium' ≈ 66, 'high' = 100).",
    schema: z.object({
      entityId: z.string().describe("Full fan entity id, e.g. fan.bedroom"),
      on: z.boolean(),
      speedPct: z.number().min(0).max(100).optional(),
    }),
  },
)

const changeFanSpeed = tool(
  async ({ entityId, speedPct }) => {
    const refusal = await refuseIfNotExposed(entityId)
    if (refusal) return refusal
    await getHaClient().callService("fan", "set_percentage", {
      entity_id: entityId,
      percentage: clamp(Math.round(speedPct), 0, 100),
    })
    return `Set ${entityId} speed to ${Math.round(speedPct)}%.`
  },
  {
    name: "change_fan_speed",
    description:
      "Set a fan's speed percentage directly (0–100). Use when the fan is " +
      "already on and only the speed needs to change.",
    schema: z.object({
      entityId: z.string(),
      speedPct: z.number().min(0).max(100),
    }),
  },
)

// --- Entity states --------------------------------------------------------

const getStates = tool(
  async ({ domain }) => list(await getExposedEntities(domain)),
  {
    name: "get_states",
    description:
      "Read the state of exposed entities, optionally filtered to one domain " +
      "(e.g. sensor, switch, binary_sensor, cover).",
    schema: z.object({
      domain: z
        .string()
        .optional()
        .describe("e.g. sensor; omit to list everything exposed"),
    }),
  },
)

const getEntityState = tool(
  async ({ entityId }) => {
    const e = await findExposed(entityId)
    if (!e) return `${entityId} is not available to the voice assistant.`
    return `${describe(e)}\nattributes: ${JSON.stringify(e.attributes)}`
  },
  {
    name: "get_entity_state",
    description:
      "Get the full state and attributes of a single exposed entity.",
    schema: z.object({ entityId: z.string() }),
  },
)

// --- Time -----------------------------------------------------------------

const getCurrentTime = tool(
  async () => {
    const now = new Date()
    return now.toLocaleTimeString("en-US", {
      hour: "numeric",
      minute: "2-digit",
      hour12: true,
    })
  },
  {
    name: "get_current_time",
    description: "Get the current local time. Use when the user asks what time it is.",
    schema: z.object({}),
  },
)

// --- Timers & alarms (View Assist) ---------------------------------------

/**
 * Resolve the View Assist satellite entity for this agent's area. Timers attach
 * to a VA entity, not to anything the user names, so this is resolved from the
 * area rather than from the exposed set.
 *
 * VA satellite sensors can have any user-chosen name (e.g. "sensor.kitchen_vaca"),
 * so we identify them by their distinctive attributes (mediaplayer_device + mic_device)
 * rather than relying solely on the entity_id naming convention.
 */
const resolveViewAssistEntity = async (): Promise<string | undefined> => {
  const area = await getAgentArea()
  const sensors = await getAllEntities("sensor")
  const candidates = sensors.filter(
    (e) =>
      /viewassist|view_assist/i.test(e.entity_id) ||
      ("mediaplayer_device" in e.attributes && "mic_device" in e.attributes),
  )
  if (candidates.length === 0) return undefined
  const inArea = area
    ? candidates.find(
        (e) => e.areaName?.toLowerCase() === area.areaName.toLowerCase(),
      )
    : undefined
  return (inArea ?? candidates[0]).entity_id
}

const setTimer = tool(
  async ({ type, time, name }) => {
    const entityId = await resolveViewAssistEntity()
    if (!entityId) return "I don't have a timer device set up for this room."
    const data: Record<string, unknown> = { entity_id: entityId, type, time }
    if (name) data["name"] = name
    const res = (await getHaClient().callServiceWithResponse(
      "view_assist",
      "set_timer",
      data,
    )) as Record<string, unknown>
    return JSON.stringify(res)
  },
  {
    name: "set_timer",
    description:
      "Set a timer, alarm or reminder via View Assist. `time` is a natural " +
      "phrase like 'two minutes' or '7 am'.",
    schema: z.object({
      type: z.enum(["timer", "alarm", "reminder", "command"]),
      time: z.string(),
      name: z.string().optional(),
    }),
  },
)

const getTimers = tool(
  async () => {
    const entityId = await resolveViewAssistEntity()
    if (!entityId) return "I don't have a timer device set up for this room."
    const res = await getHaClient().callServiceWithResponse(
      "view_assist",
      "get_timers",
      { entity_id: entityId },
    )
    return JSON.stringify(res)
  },
  {
    name: "get_timers",
    description: "List active timers and alarms for this room.",
    schema: z.object({}),
  },
)

const cancelTimers = tool(
  async ({ name }) => {
    const entityId = await resolveViewAssistEntity()
    if (!entityId) return "I don't have a timer device set up for this room."
    const data: Record<string, unknown> = { entity_id: entityId }
    if (name) data["name"] = name
    await getHaClient().callService("view_assist", "cancel_timer", data)
    return name ? `Cancelled timer "${name}".` : "Cancelled the timers."
  },
  {
    name: "cancel_timers",
    description:
      "Cancel timers/alarms for this room. Pass a name to target one, or omit " +
      "to cancel all for this room.",
    schema: z.object({ name: z.string().optional() }),
  },
)

// --- Maintenance (filters & batteries) ------------------------------------

const FILTER_KEYWORDS = [
  "filter",
  "air_quality",
  "hvac",
  "furnace",
  "purifier",
  "maintenance",
  "service",
  "replace",
  "remind",
  "next_change",
  "last_change",
  "change_date",
]
const BATTERY_ATTRS = ["battery_level", "battery"]

/** True when an entity looks filter-related by id or friendly name. */
const isFilterRelated = (e: EnrichedEntity): boolean => {
  const target = `${e.entity_id} ${e.friendlyName}`.toLowerCase()
  return FILTER_KEYWORDS.some((k) => target.includes(k))
}

/** True when an entity is a battery sensor or binary_sensor. */
const isBatteryEntity = (e: EnrichedEntity): boolean => {
  const dc = (e.attributes["device_class"] as string | undefined)?.toLowerCase()
  return dc === "battery"
}

const listFilterStatus = tool(
  async () => {
    // Query all exposed entities regardless of domain so input_datetime,
    // input_text, date, sensor, climate, etc. are all covered.
    const all = await getExposedEntities()

    const filterAttrs = [
      "filter_life",
      "filter_hours_used",
      "filter_replacement",
      "filter_life_remaining",
    ]

    const lines: string[] = []
    for (const e of all) {
      const hasFilterAttr = filterAttrs.some((a) => e.attributes[a] != null)
      if (!isFilterRelated(e) && !hasFilterAttr) continue
      const attrs = [...filterAttrs, "last_changed", "last_reset"]
        .filter((a) => e.attributes[a] != null)
        .map((a) => `${a}=${JSON.stringify(e.attributes[a])}`)
        .join(", ")
      lines.push(
        `${e.entity_id} (${e.friendlyName})${e.areaName ? ` [${e.areaName}]` : ""}: ${e.state}${attrs ? ` {${attrs}}` : ""}`,
      )
    }

    return lines.length > 0
      ? lines.join("\n")
      : "(no filter-related entities found in exposed entities)"
  },
  {
    name: "list_filter_status",
    description:
      "List filter-related exposed entities (air filters, HVAC filters, purifier " +
      "filters, change-date helpers). Shows filter life, hours used, replacement " +
      "status, and next/last change dates. Use to answer questions about filter " +
      "maintenance including when the filter was last changed or when it is due.",
    schema: z.object({}),
  },
)

const listBatteryStatus = tool(
  async () => {
    const [sensors, binary] = await Promise.all([
      getExposedEntities("sensor"),
      getExposedEntities("binary_sensor"),
    ])

    const lines: string[] = []

    for (const e of sensors) {
      if (!isBatteryEntity(e)) continue
      const level = Number(e.state)
      const label = isNaN(level)
        ? e.state
        : level <= 10
          ? `${level}% (CRITICAL)`
          : level <= 20
            ? `${level}% (low)`
            : `${level}%`
      const attrs = BATTERY_ATTRS.filter((a) => e.attributes[a] != null)
        .map((a) => `${a}=${JSON.stringify(e.attributes[a])}`)
        .join(", ")
      lines.push(
        `${e.entity_id} (${e.friendlyName})${e.areaName ? ` [${e.areaName}]` : ""}: ${label}${attrs ? ` {${attrs}}` : ""}`,
      )
    }

    for (const e of binary) {
      if (!isBatteryEntity(e)) continue
      // binary_sensor battery: "on" = low battery, "off" = ok
      const status = e.state === "on" ? "LOW BATTERY" : "ok"
      lines.push(
        `${e.entity_id} (${e.friendlyName})${e.areaName ? ` [${e.areaName}]` : ""}: ${status}`,
      )
    }

    if (lines.length === 0) {
      return "(no battery entities found in exposed entities)"
    }
    const low = lines.filter((l) => l.includes("low") || l.includes("LOW") || l.includes("CRITICAL"))
    return low.length > 0
      ? `Devices needing battery attention:\n${low.join("\n")}\n\nAll battery devices:\n${lines.join("\n")}`
      : `All batteries ok:\n${lines.join("\n")}`
  },
  {
    name: "list_battery_status",
    description:
      "List battery levels for all exposed battery sensor/binary_sensor entities. " +
      "Highlights low and critical batteries. Use to answer questions about which " +
      "devices need new batteries and what battery type/count might be needed.",
    schema: z.object({}),
  },
)

const getEntityMaintenanceDetails = tool(
  async ({ entityId }) => {
    const e = await findExposed(entityId)
    if (!e) return `${entityId} is not available to the voice assistant.`
    return `${describe(e)}\nAll attributes: ${JSON.stringify(e.attributes, null, 2)}`
  },
  {
    name: "get_entity_maintenance_details",
    description:
      "Get full state and all attributes for a specific entity to find maintenance " +
      "details like last filter change date, battery type, model number, etc.",
    schema: z.object({ entityId: z.string() }),
  },
)

const pressButton = tool(
  async ({ entityId }) => {
    const refusal = await refuseIfNotExposed(entityId)
    if (refusal) return refusal
    await getHaClient().callService("input_button", "press", {
      entity_id: entityId,
    })
    return `Pressed ${entityId}.`
  },
  {
    name: "press_button",
    description:
      "Press an input_button entity. Use when the user reports completing a " +
      "maintenance task, e.g. 'I just changed the HVAC filter' → press the " +
      "'Changed HVAC filter' button. Use get_states with domain 'input_button' " +
      "to find the right entity if unsure of the id.",
    schema: z.object({ entityId: z.string() }),
  },
)

// --- Tool sets per category ----------------------------------------------

export const MUSIC_TOOLS = [
  listMediaPlayers,
  searchMusic,
  playMusic,
  mediaControl,
  setShuffle,
  setVolume,
  changeVolume,
  setMute,
]
export const LIST_TOOLS = [getTodoItems, addTodoItem]
export const CLIMATE_TOOLS = [listClimate, setTemperature]
export const WEATHER_TOOLS = [getTodayForecast, getDailyForecast]
export const LOCK_TOOLS = [listLocks, lockDoor]
export const LIGHTING_TOOLS = [listLights, setLight]
export const FAN_TOOLS = [listFans, setFan, changeFanSpeed]
export const STATE_TOOLS = [
  getCurrentTime,
  getStates,
  getEntityState,
  setTimer,
  getTimers,
  cancelTimers,
]
export const MAINTENANCE_TOOLS = [
  listFilterStatus,
  listBatteryStatus,
  getEntityMaintenanceDetails,
  pressButton,
  getStates,
  getEntityState,
]
