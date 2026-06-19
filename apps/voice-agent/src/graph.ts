/**
 * The LangGraph agent: an intent router that dispatches to a specialized
 * subagent per category of request.
 *
 *   user text
 *       |
 *    [router]  -- classifies intent --> music | lists | climate | weather |
 *       |                                locks | lights | states | maintenance
 *  [subagent]  -- ReAct loop with category-scoped HA tools --> reply
 *
 * Every subagent sees only entities the user has exposed to the conversation
 * assistant in Home Assistant (enforced in `registry.ts`/`tools.ts`).
 *
 * Adding a category is: write its tools, add a subagent node, and add the
 * category to the router enum + the conditional-edge map.
 */

import { ChatAnthropic } from "@langchain/anthropic"
import { SystemMessage } from "@langchain/core/messages"
import {
  Annotation,
  END,
  MemorySaver,
  MessagesAnnotation,
  START,
  StateGraph,
} from "@langchain/langgraph"
import { createReactAgent } from "@langchain/langgraph/prebuilt"
import { z } from "zod"

import { getSettings } from "./config"
import {
  CLIMATE_TOOLS,
  LIGHTING_TOOLS,
  LIST_TOOLS,
  LOCK_TOOLS,
  MAINTENANCE_TOOLS,
  MUSIC_TOOLS,
  STATE_TOOLS,
  WEATHER_TOOLS,
} from "./tools"

const CATEGORIES = [
  "music",
  "lists",
  "climate",
  "weather",
  "locks",
  "lights",
  "states",
  "maintenance",
] as const
type Category = (typeof CATEGORIES)[number]

const RouteDecision = z.object({
  category: z
    .enum(CATEGORIES)
    .describe(
      "music = play/control music or media playback & volume; " +
        "lists = add to or read a todo/grocery/shopping list; " +
        "climate = thermostats/temperature; " +
        "weather = forecast questions; " +
        "locks = locking doors; " +
        "lights = control or query lights; " +
        "states = any other device/entity state question, plus timers, alarms, and current time; " +
        "maintenance = filter replacement, battery levels, or any maintenance/upkeep question.",
    ),
})

// Custom state = the built-in message channel plus the router's decision.
const AgentState = Annotation.Root({
  ...MessagesAnnotation.spec,
  category: Annotation<Category>,
})

const ROUTER_SYSTEM =
  "You are the intent router for a smart home assistant. Classify the user's " +
  "most recent request into exactly one category. Do not answer the request."

/** The room this agent lives in, woven into prompts that need a default. */
const areaClause = (): string => {
  const area = getSettings().area.trim()
  return area
    ? `This voice assistant is located in the "${area}" area; treat that as the ` +
        `default room when the user doesn't name one.`
    : `This voice assistant has no configured area, so the user must name the ` +
        `room/device explicitly.`
}

const SPEAK = "Reply in one short sentence suitable for being spoken aloud."

const subagentPrompts = (): Record<Category, string> => ({
  music:
    `You control music and media playback. ${areaClause()}\n` +
    "Choose the media_player first: if the user names a room/device use the " +
    "matching player; otherwise use the player in this agent's area. If no " +
    "media player is found for the area, stop and say so.\n" +
    "- Play a specific artist/song/playlist: search_music, pick the single best " +
    "match, then play_music (it sets volume to 50% and plays via Music Assistant).\n" +
    "- pause/resume/stop/next/previous: media_control.\n" +
    "- shuffle on/off: set_shuffle.\n" +
    "- 'set volume to X%' → set_volume with X/100 (0.0–1.0). 'louder'/'turn up' " +
    "→ change_volume +0.1; 'quieter'/'turn down' → change_volume -0.1. " +
    "'mute' → set_mute.\n" +
    SPEAK,
  lists:
    "You manage todo/grocery lists and must never create duplicates.\n" +
    "Pick the list: groceries/food/shopping → todo.to_do_groceries; Costco → " +
    "todo.to_do_costco; family/tasks → todo.to_do_family; other → " +
    "todo.to_do_other; if unspecified default to todo.to_do_groceries.\n" +
    "To add an item: 1) get_todo_items for the selected list. If it can't be " +
    "read, say you can't prevent duplicates and stop. 2) Normalize for " +
    "comparison (lowercase, trim, drop punctuation .,!?:;'\"()[]{}/\\- , collapse " +
    "spaces, '&'→'and'). 3) If it already exists, do NOT add — say it's already " +
    "on the list. 4) Otherwise add_todo_item, then stop. Never claim you added " +
    "something unless the add succeeded.\n" +
    SPEAK,
  climate:
    `You control thermostats. ${areaClause()}\n` +
    "Select the climate entity with list_climate: if there's only one, use it; " +
    "otherwise prefer the one on the same floor as this agent's area (first " +
    "found). Adjust relative to the current TARGET temperature (attribute " +
    "`temperature`, or the midpoint of target_temp_high/low). If no target can " +
    "be read, say you can't see the thermostat's target and stop.\n" +
    "Intent: 'set to X' → X; warmer/raise/hotter → +2; cooler/lower/colder → -2; " +
    "'up/down by N' → ±N; 'turn it up/down' with no number → ±2. set_temperature " +
    "rounds and clamps to 60–74. Tell the user the new target temperature.\n" +
    SPEAK,
  weather:
    "You answer weather questions from stored forecasts. For today's weather, " +
    "summarize get_today_forecast in 1–2 sentences. For a future day, use " +
    "get_daily_forecast and answer only for the requested day. Use natural " +
    "dates and Fahrenheit; say 'degrees', not 'F'.",
  locks:
    "You can LOCK doors but must NEVER unlock. Use list_locks to find the door " +
    "and lock_door to lock it. If asked to unlock, refuse politely and do not " +
    "call any service. " +
    SPEAK,
  lights:
    "You control the home's lights. Use list_lights to find the right entity, " +
    "then set_light to turn it on/off or set brightness. If the user is vague " +
    "about which light, list the lights first. " +
    SPEAK,
  states:
    `You answer questions about device/entity state and manage timers & alarms. ` +
    `${areaClause()}\n` +
    "For time questions ('what time is it?'): use get_current_time.\n" +
    "For state questions: when you don't know the exact entity ID, call " +
    "get_states with the relevant domain (e.g. 'sensor') to discover exposed " +
    "entities first, then report the matching entity's state. Only call " +
    "get_entity_state when you already have the exact entity ID from a prior " +
    "get_states result. Never guess entity IDs.\n" +
    "IMPORTANT: All home information — including wifi network names, wifi " +
    "passwords, and guest network credentials — is stored as HA sensor entities. " +
    "When asked about wifi or network info, always call get_states with domain " +
    "'sensor' to find the relevant sensor. Never say you don't have access to " +
    "network or router information; use get_states to look it up.\n" +
    "For timers and alarms (View Assist):\n" +
    "- Multiple named timers can run simultaneously.\n" +
    "- set_timer: create a timer or alarm; pass the name the user gave " +
    "(e.g. 'pasta timer'). Ad-hoc timers without a name are also fine.\n" +
    "- get_timers: call this to list all active timers and their remaining time. " +
    "Use it to answer 'how much time is left' questions.\n" +
    "- cancel_timers: pass name to cancel one specific timer. Omit name only " +
    "when cancelling ALL active timers. If the user wants to cancel a specific " +
    "timer but multiple are active and no name was mentioned, call get_timers " +
    "first, report what's running, and ask which one to cancel.\n" +
    SPEAK,
  maintenance:
    "You answer questions about home maintenance and record completed maintenance tasks.\n" +
    "For filter questions (is a filter due, when was it last changed, next change " +
    "date, filter life remaining): call list_filter_status first. It covers all " +
    "exposed entity domains including input_datetime and sensor. If list_filter_status " +
    "returns no relevant results, fall back to get_states with domain 'sensor' to " +
    "search for entities whose name or id suggests a filter/HVAC maintenance date, " +
    "then use get_entity_state or get_entity_maintenance_details for details.\n" +
    "When the user reports completing a maintenance task (e.g. 'I just changed the " +
    "HVAC filter', 'I replaced the filter'): use get_states with domain 'input_button' " +
    "to find the matching button, then press_button to record it. Confirm to the user.\n" +
    "For battery questions (which devices have low batteries, what battery is needed, " +
    "how many): use list_battery_status. If a device's battery type or count is not " +
    "in the sensor state, use get_entity_maintenance_details to check its attributes " +
    "for model info that could indicate battery type.\n" +
    "Summarise only actionable findings: report what needs attention first, then give " +
    "context (e.g. last changed date, next due date, remaining life, battery level). " +
    SPEAK,
})

const makeLlm = (model: string): ChatAnthropic =>
  new ChatAnthropic({
    model,
    apiKey: getSettings().anthropicApiKey,
    maxTokens: 1024,
  })

export const buildGraph = () => {
  const haiku  = makeLlm("claude-haiku-4-5")
  const sonnet = makeLlm("claude-sonnet-4-6")
  const routerLlm = haiku.withStructuredOutput(RouteDecision, { name: "route" })
  const prompts = subagentPrompts()

  const makeAgent = (
    llm: ChatAnthropic,
    tools: Parameters<typeof createReactAgent>[0]["tools"],
    category: Category,
  ) => createReactAgent({ llm, tools, prompt: prompts[category] })

  const subagents: Record<Category, ReturnType<typeof createReactAgent>> = {
    music:       makeAgent(sonnet, MUSIC_TOOLS,       "music"),
    lists:       makeAgent(sonnet, LIST_TOOLS,        "lists"),
    climate:     makeAgent(haiku,  CLIMATE_TOOLS,     "climate"),
    weather:     makeAgent(haiku,  WEATHER_TOOLS,     "weather"),
    locks:       makeAgent(haiku,  LOCK_TOOLS,        "locks"),
    lights:      makeAgent(haiku,  LIGHTING_TOOLS,    "lights"),
    states:      makeAgent(haiku,  STATE_TOOLS,       "states"),
    maintenance: makeAgent(haiku,  MAINTENANCE_TOOLS, "maintenance"),
  }

  const router = async (state: typeof AgentState.State) => {
    const decision = await routerLlm.invoke([
      new SystemMessage(ROUTER_SYSTEM),
      ...state.messages,
    ])
    return { category: decision.category }
  }

  const edgeMap = Object.fromEntries(
    CATEGORIES.map((c) => [c, c]),
  ) as Record<Category, Category>

  const graph = new StateGraph(AgentState)
    .addNode("router", router)
    .addNode("music", subagents.music)
    .addNode("lists", subagents.lists)
    .addNode("climate", subagents.climate)
    .addNode("weather", subagents.weather)
    .addNode("locks", subagents.locks)
    .addNode("lights", subagents.lights)
    .addNode("states", subagents.states)
    .addNode("maintenance", subagents.maintenance)
    .addEdge(START, "router")
    .addConditionalEdges("router", (state) => state.category, edgeMap)
    .addEdge("music", END)
    .addEdge("lists", END)
    .addEdge("climate", END)
    .addEdge("weather", END)
    .addEdge("locks", END)
    .addEdge("lights", END)
    .addEdge("states", END)
    .addEdge("maintenance", END)

  // MemorySaver keeps short conversation context keyed by thread_id so
  // follow-ups ("now make it warmer") have context. Swap for a persistent
  // checkpointer if you need durability across restarts.
  return graph.compile({ checkpointer: new MemorySaver() })
}
