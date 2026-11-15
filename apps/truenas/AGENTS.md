This project configures the TrueNAS host's metrics exporter and remote syslog so it reports to the cluster. Read [README.md](README.md) before changing anything here.

# Never Run `nx run truenas:deploy` From An Agent Session

It writes to the live NAS through its middleware. The captain runs it. Validate with non-mutating commands only:

```bash
nx run truenas:lint                            # ansible-playbook --syntax-check, no host contact
ansible-playbook --syntax-check src/deploy/index.yml
```

Read-only checks over SSH are fine when you need the exact middleware method or field names: `midclt call` with a query method (`reporting.exporters.query`, `system.advanced.config`, `system.version`), `core.get_methods` and `reporting.exporters.exporter_schemas`. Never call a `create`, `update` or `delete` method on the host.

`truenas` is excluded from `yarn deploy/all` in the root `package.json`, like `pve`, because it is a supervised, one-host deploy.

# Configure Through `midclt`, Never By Editing Files

TrueNAS owns its configuration in a database behind the middleware. Do not edit files under `/etc` or `/data` to change reporting or syslog, because the middleware overwrites them. Every change goes through `midclt call`, and every task reads the current state first.

# `system.advanced.update` Replaces The Whole Syslog List

`syslogservers` holds at most two entries and an update overwrites the list. `tasks/observability.yml` therefore keeps every entry that is not for the cluster node, and fails when both slots are taken by other hosts. Keep that behavior when you change it.

# Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
