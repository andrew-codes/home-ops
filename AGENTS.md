Cloud ID: cca19622-1a7b-4310-bcfb-3f1d51db0dfd

# Documentation

Documentation lives in the Confluence space `HA` ("Home Ops"), published at
https://docs.home.smith-simms.family/wiki/spaces/HA/overview
(canonical: https://smithsimms.atlassian.net/wiki/spaces/HA).

- Search that space for relevant documentation before starting work.
- When you add, change, or remove a feature, service, or operational procedure, update the
  affected pages in space `HA` in the same unit of work. Documentation is not optional follow-up.
- Read and write those pages with the `twg` CLI (`twg confluence search`, `twg confluence tree`,
  `twg confluence content get|create|update`); see the `twg-confluence` skill. Never use an
  Atlassian MCP server for this.

# Issues

Found in Jira `HO` project.

# Troubleshooting with gcx

`gcx` (Grafana CLI) is installed and already logged in to the production Grafana with a read-only token.
Use it to troubleshoot: query logs (VictoriaLogs), metrics (VictoriaMetrics) and alert state.
Never ask for, print or handle the token. gcx keeps it in the OS keychain.

```sh
gcx datasources list                                        # datasource UIDs
gcx metrics query 'up == 0' --since 1h                      # PromQL; default datasource is VictoriaMetrics
gcx alert rules list --state firing                         # alert state
# Logs: gcx logs query is Loki-only, so call VictoriaLogs (LogsQL) through Grafana's datasource proxy.
# Use the victorialogs UID from `gcx datasources list`.
gcx api /api/datasources/proxy/uid/<victorialogs-uid>/select/logsql/query \
  -d 'query=kubernetes.pod_namespace:="default" error&start=30m&limit=20' \
  -H 'Content-Type: application/x-www-form-urlencoded' -o json
```

# Writing Content for AI Consumption

When creating or editing content intended to be consumed by AI agents (e.g., AGENTS.md files, prompt instructions, agent configuration), follow the guidelines in [.agents/writing-for-ai.md](.agents/writing-for-ai.md).

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
