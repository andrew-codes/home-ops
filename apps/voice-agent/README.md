# voice-agent

A custom **LangGraph (TypeScript)** agent that controls this Home Assistant
home. Voice commands are routed by intent to a specialized subagent, each with a
tightly scoped set of Home Assistant tools.

```
POST /chat  {"text","conversationId?","language?"}  ->  {"text","conversationId"}

 user text ──▶ [router] ──┬─▶ music    (list_media_players, search_music, play_music, …)
                          ├─▶ lists    (get_todo_items, add_todo_item)
                          ├─▶ climate  (list_climate, set_temperature)
                          ├─▶ weather  (get_today_forecast, get_daily_forecast)
                          ├─▶ locks    (list_locks, lock_door)         ← lock only, never unlock
                          ├─▶ lights   (list_lights, set_light)
                          └─▶ states   (get_states, get_entity_state, set_timer, …)
```

The router uses an LLM with structured output to pick a category; each subagent
is a ReAct agent (`createReactAgent`) that loops over its tools to fulfil the
request and returns one short, speakable sentence. Short-term conversation
memory is keyed by `conversationId` via a LangGraph `MemorySaver`.

## Exposed entities only

The agent can only see and act on entities the user has **exposed to the
conversation assistant** in Home Assistant (Settings → Voice assistants →
Expose). That exposed set, plus the area/floor of every entity, is read from the
Home Assistant **WebSocket API** (`homeassistant/expose_entity/list` and the
area/floor/device/entity registries — none of these are available over REST) and
cached briefly in `src/registry.ts`. Reads are filtered to exposed entities and
writes refuse any entity that isn't exposed, so a hallucinated entity id can
never reach Home Assistant.

## Area awareness

`VOICE_AGENT_AREA` names the Home Assistant area this agent lives in. It's the
default room for music when the user doesn't name a player, and it's used to
resolve the right thermostat (by the area's floor) and the View Assist satellite
that timers/alarms attach to.

Adding a category is: add its tools in `src/tools.ts`, a subagent node + edge in
`src/graph.ts`, and the category to the router enum.

## Layout

| File | Purpose |
| --- | --- |
| `src/config.ts` | Env-driven settings |
| `src/haClient.ts` | Minimal Home Assistant REST client (`fetch`) |
| `src/tools.ts` | LangChain tools grouped by category |
| `src/graph.ts` | Router + subagent graph |
| `src/server.ts` | `http` server exposing `/chat` and `/health` |
| `scripts/compile.ts` | esbuild bundle → `dist/server.js` (`@ha/build-ts`) |
| `scripts/image-push.ts` | Build + push the image (`@ha/docker`) |

Because the workspace uses Yarn PnP, the service is **bundled to a single
self-contained file** so the runtime image is a plain `node:slim` with no
`node_modules` / PnP at runtime.

## Develop

```sh
yarn nx run voice-agent:compile        # produce dist/server.js

ANTHROPIC_API_KEY=sk-ant-... \
VOICE_AGENT_HA_BASE_URL=https://ha.smith-simms.family \
VOICE_AGENT_HA_TOKEN=<long-lived-token> \
VOICE_AGENT_AREA=Kitchen \
node apps/voice-agent/dist/server.js

curl -s localhost:8000/chat -d '{"text":"turn on the kitchen light"}'
```

> The HA token must be a long-lived access token belonging to an admin user —
> the exposed-entity list and registries are read over the WebSocket API.

## LangGraph Studio (local graph debugging)

LangGraph Studio lets you step through the graph node-by-node, inspect state at
each checkpoint, replay from any node, and inject test inputs without going
through the full HTTP server.

```sh
yarn nx run voice-agent:start
```

Secrets (`ANTHROPIC_API_KEY`, `VOICE_AGENT_HA_TOKEN`, `LANGCHAIN_API_KEY`) are
pulled live from 1Password and injected as env vars — nothing is written to disk.
Override `VOICE_AGENT_HA_BASE_URL` or `VOICE_AGENT_AREA` in your shell before
running if you need a different target.

## LangSmith (observability)

LangSmith traces every LLM call, node execution, state transition, and tool call.
It's picked up automatically by `@langchain/core`; no code changes are needed.

**Local:** the `start` target automatically sets `LANGCHAIN_TRACING_V2=true`,
`LANGCHAIN_PROJECT=voice-agent`, and pulls `LANGCHAIN_API_KEY` from 1Password.

**In-cluster:** the deployments already include `LANGCHAIN_PROJECT` and reference
`LANGCHAIN_API_KEY` from the `voice-agent` secret (optional — pods start fine
without it). To enable production tracing:

1. Re-seal the `voice-agent` secret to add `langsmith-api-key`:

```sh
yarn nx generate @ha/secrets:seal production
```

2. Change `LANGCHAIN_TRACING_V2` from `"false"` to `"true"` in both deployment
   files (`deployment-kitchen.yaml` and `deployment-game-room.yaml`).

## Build & publish image

Same pattern as the other apps — `nx run-many --target=publish` (or the
`Publish all` / `Manual Publish` workflows) builds and pushes
`ghcr.io/andrew-codes/voice-agent:latest`. The `publish` target `dependsOn`
`compile`, so the bundle is produced first.

```sh
yarn nx run voice-agent:publish
```

## Deploy (FluxCD)

Manifests: `deployments/base/voice-agent` + `deployments/production/voice-agent`,
wired into `clusters/production/apps.yaml` as the `voice-agent` Kustomization.

It needs a `voice-agent` secret with `home-assistant-token` and
`anthropic-api-key` (and optionally `langsmith-api-key` for tracing). Create a
SealedSecret and add it to `infrastructure/production/secrets`:

```sh
kubectl create secret generic voice-agent -n default \
  --from-literal=home-assistant-token="<HA long-lived token>" \
  --from-literal=anthropic-api-key="sk-ant-..." \
  --from-literal=langsmith-api-key="lsv2_..." \
  --dry-run=client -o yaml \
| kubeseal --format yaml \
  > infrastructure/production/secrets/voice-agent-sealed.yaml

# voice-agent-sealed.yaml is already in
# infrastructure/production/secrets/kustomization.yaml
```

Once deployed, the agent is reachable in-cluster at `http://voice-agent:8000`,
which is what the Home Assistant integration points at.
