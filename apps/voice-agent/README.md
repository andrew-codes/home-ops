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

## Configuration (env)

| Var | Default | Notes |
| --- | --- | --- |
| `VOICE_AGENT_HA_BASE_URL` | `http://home-assistant:8123` | In-cluster ClusterIP |
| `VOICE_AGENT_HA_TOKEN` | — | HA long-lived access token (admin) |
| `ANTHROPIC_API_KEY` | — | Anthropic key |
| `VOICE_AGENT_MODEL` | `claude-opus-4-8` | e.g. `claude-haiku-4-5` for lower voice latency |
| `VOICE_AGENT_AREA` | _(unset)_ | HA area name this agent lives in; default room for music & thermostat selection |
| `VOICE_AGENT_PORT` | `8000` | |

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

It needs a `voice-agent` secret with `ha-token` and `anthropic-api-key`. Create a
SealedSecret and add it to `infrastructure/production/secrets`:

```sh
kubectl create secret generic voice-agent -n default \
  --from-literal=ha-token="<HA long-lived token>" \
  --from-literal=anthropic-api-key="sk-ant-..." \
  --dry-run=client -o yaml \
| kubeseal --format yaml \
  > infrastructure/production/secrets/voice-agent-sealed.yaml

# then add voice-agent-sealed.yaml to
# infrastructure/production/secrets/kustomization.yaml
```

Once deployed, the agent is reachable in-cluster at `http://voice-agent:8000`,
which is what the Home Assistant integration points at.
