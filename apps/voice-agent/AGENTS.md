An HTTP service exposing `POST /chat` that accepts natural-language home automation commands and returns spoken-style replies. It routes requests by intent to one of several ReAct subagents, each with a scoped set of Home Assistant tools.

# Architecture

The LangGraph graph in `src/graph.ts` has two layers:

1. **Router node** — calls `ChatAnthropic.withStructuredOutput` to classify user text into `music | lists | climate | weather | locks | lights | states`. No HA calls are made here.
2. **Subagent nodes** — one `createReactAgent` per category, each bound only to tools relevant to that domain (`src/tools.ts`). Each prompt encodes that category's business rules (player/thermostat selection, list dedup, lock-only, etc.). The subagent loops over its tools until it produces one short, speakable sentence.

`MemorySaver` provides per-`conversationId` short-term memory so follow-up commands have context.

# Exposed entities + registry

`src/registry.ts` is the gate for the rule "only entities exposed to the voice assistant are available." It reads the exposed-entity set (`homeassistant/expose_entity/list`) and the area/floor/device/entity registries over the **WebSocket API** (`haClient.wsCommands`; these aren't in REST), caches them briefly, and joins them with live states to produce `EnrichedEntity` objects (state + area + floor). `getExposedEntities` returns exposed-only entities; `isExposed` guards writes; `getAgentArea` resolves `VOICE_AGENT_AREA` to its area/floor; `getAllEntities` (all entities) is used only to locate the View Assist satellite for timers.

# Tools

Tools in `src/tools.ts` read via `getExposedEntities`/`findExposed` and write via `haClient.callService`. Writes call `refuseIfNotExposed` first so a hallucinated entity id can't reach HA. Services that return data (`todo.get_items`, `music_assistant.search`, `view_assist.get_timers`) use `haClient.callServiceWithResponse` (REST `?return_response`). Tools are grouped into per-category sets (`MUSIC_TOOLS`, `LIST_TOOLS`, `CLIMATE_TOOLS`, `WEATHER_TOOLS`, `LOCK_TOOLS`, `LIGHTING_TOOLS`, `STATE_TOOLS`) and assigned to the matching subagent.

To add a new intent category: define tools, add a node, add the category string to the router enum, and wire a conditional edge.

# Build

This workspace uses Yarn PnP (no `node_modules`). The service is bundled to a single `dist/server.js` via `@ha/build-ts` (esbuild) so the runtime image is a plain Node image with no install step.

```
yarn nx run voice-agent:compile   # bundle → dist/server.js
yarn nx run voice-agent:publish   # compile + docker build + push to ghcr.io
```

The `publish` target depends on `compile` — run either; the other is a no-op if cached.

# Configuration

All settings are read from environment variables with a `VOICE_AGENT_` prefix (see `src/config.ts`). The two required secrets (`VOICE_AGENT_HA_TOKEN`, `ANTHROPIC_API_KEY`) are injected in the cluster via the `voice-agent` SealedSecret. `VOICE_AGENT_AREA` names the HA area this agent lives in (default room for music; floor used for thermostat selection). The HA token must belong to an admin user since the exposed-entity list and registries are read over the WebSocket API.
