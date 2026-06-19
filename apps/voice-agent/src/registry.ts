/**
 * Voice-assistant exposure + area/floor resolution.
 *
 * Two hard rules live here:
 *
 *  1. The agent may only see and act on entities that the user has exposed to
 *     the *conversation* assistant in Home Assistant (Settings → Voice
 *     assistants → Expose). The exposed set is read from the WebSocket API
 *     command `homeassistant/expose_entity/list`; it is not available over REST.
 *
 *  2. Entities are enriched with their area and floor (resolved through the
 *     entity → device → area → floor registries) so subagents can pick the
 *     right device for the agent's configured area (`VOICE_AGENT_AREA`).
 *
 * Registry + exposure data changes rarely, so it is cached with a short TTL.
 * Entity *states* are always fetched fresh.
 */

import { getSettings } from "./config"
import { type EntityState, getHaClient } from "./haClient"

export interface EnrichedEntity extends EntityState {
  domain: string
  friendlyName: string
  areaId?: string
  areaName?: string
  floorId?: string
  floorName?: string
}

interface AreaEntry {
  area_id: string
  name: string
  floor_id: string | null
}
interface FloorEntry {
  floor_id: string
  name: string
}
interface DeviceEntry {
  id: string
  area_id: string | null
}
interface EntityRegEntry {
  entity_id: string
  device_id: string | null
  area_id: string | null
}
type ExposedList = {
  exposed_entities: Record<string, Record<string, boolean | undefined>>
}

interface Snapshot {
  /** entity_ids exposed to the `conversation` assistant. */
  exposed: Set<string>
  areas: Map<string, AreaEntry>
  floors: Map<string, FloorEntry>
  deviceArea: Map<string, string | null>
  /** entity_id → { areaId override, deviceId } */
  entityReg: Map<string, { areaId: string | null; deviceId: string | null }>
}

const SNAPSHOT_TTL_MS = 60_000
let cached: { at: number; snapshot: Snapshot } | undefined

const loadSnapshot = async (): Promise<Snapshot> => {
  const now = Date.now()
  if (cached && now - cached.at < SNAPSHOT_TTL_MS) return cached.snapshot

  const ha = getHaClient()
  const [exposedRes, areaList, floorList, deviceList, entityList] =
    await ha.wsCommands<unknown>([
      { type: "homeassistant/expose_entity/list" },
      { type: "config/area_registry/list" },
      { type: "config/floor_registry/list" },
      { type: "config/device_registry/list" },
      { type: "config/entity_registry/list" },
    ])

  const exposed = new Set<string>()
  const exposedEntities = (exposedRes as ExposedList).exposed_entities ?? {}
  for (const [entityId, assistants] of Object.entries(exposedEntities)) {
    if (assistants?.["conversation"]) exposed.add(entityId)
  }

  const areas = new Map<string, AreaEntry>()
  for (const a of areaList as AreaEntry[]) areas.set(a.area_id, a)

  const floors = new Map<string, FloorEntry>()
  for (const f of floorList as FloorEntry[]) floors.set(f.floor_id, f)

  const deviceArea = new Map<string, string | null>()
  for (const d of deviceList as DeviceEntry[]) deviceArea.set(d.id, d.area_id)

  const entityReg = new Map<
    string,
    { areaId: string | null; deviceId: string | null }
  >()
  for (const e of entityList as EntityRegEntry[]) {
    entityReg.set(e.entity_id, { areaId: e.area_id, deviceId: e.device_id })
  }

  const snapshot: Snapshot = { exposed, areas, floors, deviceArea, entityReg }
  cached = { at: now, snapshot }
  return snapshot
}

/** Resolve the area_id an entity belongs to: entity override, else its device's area. */
const areaIdFor = (snap: Snapshot, entityId: string): string | null => {
  const reg = snap.entityReg.get(entityId)
  if (!reg) return null
  if (reg.areaId) return reg.areaId
  if (reg.deviceId) return snap.deviceArea.get(reg.deviceId) ?? null
  return null
}

const enrich = (snap: Snapshot, s: EntityState): EnrichedEntity => {
  const areaId = areaIdFor(snap, s.entity_id) ?? undefined
  const area = areaId ? snap.areas.get(areaId) : undefined
  const floorId = area?.floor_id ?? undefined
  const floor = floorId ? snap.floors.get(floorId) : undefined
  return {
    ...s,
    domain: s.entity_id.split(".")[0] ?? "",
    friendlyName: (s.attributes["friendly_name"] as string) ?? s.entity_id,
    areaId,
    areaName: area?.name,
    floorId,
    floorName: floor?.name,
  }
}

/**
 * All entities exposed to the conversation assistant, enriched with area/floor,
 * optionally filtered to a single domain (e.g. "media_player").
 */
export const getExposedEntities = async (
  domain?: string,
): Promise<EnrichedEntity[]> => {
  const snap = await loadSnapshot()
  const states = await getHaClient().getStates(domain)
  return states
    .filter((s) => snap.exposed.has(s.entity_id))
    .map((s) => enrich(snap, s))
}

/** True when an entity is exposed to the conversation assistant. */
export const isExposed = async (entityId: string): Promise<boolean> => {
  const snap = await loadSnapshot()
  return snap.exposed.has(entityId)
}

/**
 * All entities (regardless of exposure) enriched with area/floor. Used only for
 * resolving infrastructure entities the user never names directly — e.g. the
 * View Assist satellite a timer is attached to.
 */
export const getAllEntities = async (
  domain?: string,
): Promise<EnrichedEntity[]> => {
  const snap = await loadSnapshot()
  const states = await getHaClient().getStates(domain)
  return states.map((s) => enrich(snap, s))
}

export interface AgentArea {
  areaId: string
  areaName: string
  floorId?: string
  floorName?: string
}

/**
 * Resolve `VOICE_AGENT_AREA` (matched by name, case-insensitively) to its area
 * and floor. Returns undefined when unset or not found.
 */
export const getAgentArea = async (): Promise<AgentArea | undefined> => {
  const name = getSettings().area.trim()
  if (!name) return undefined
  const snap = await loadSnapshot()
  for (const area of snap.areas.values()) {
    if (area.name.toLowerCase() === name.toLowerCase()) {
      const floor = area.floor_id ? snap.floors.get(area.floor_id) : undefined
      return {
        areaId: area.area_id,
        areaName: area.name,
        floorId: area.floor_id ?? undefined,
        floorName: floor?.name,
      }
    }
  }
  return undefined
}
