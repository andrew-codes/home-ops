# truenas

Sends the TrueNAS host's metrics and logs to the cluster, so nothing is typed into the TrueNAS UI. It is an idempotent Ansible play ([`src/deploy/index.yml`](src/deploy/index.yml)) that connects over SSH and calls TrueNAS's own middleware with `midclt`. It does not install TrueNAS, create pools or shares, or manage anything else on the NAS.

## What it manages

| Concern                                                                | Middleware call                                                                  |
| ---------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| A `victoriametrics` Graphite reporting exporter, pointed at port 30003 | `reporting.exporters.query`, `reporting.exporters.create` and `.update`          |
| A remote syslog server over TCP, pointed at port 30514                 | `system.advanced.config` and `system.advanced.update` (the `syslogservers` list) |

The destination is the Kubernetes node (`k8s/ip`), on the NodePorts the `metrics` and `logs` deployments publish. Both tasks read the current state first and write only on drift, so a second run changes nothing.

- **Exporter.** Created when missing. When it exists, the play compares the exporter type, destination, port, prefix, namespace and enabled flag, and updates only on drift. Other attributes (`update_every`, `buffer_on_failures` and so on) keep whatever they are. The prefix is `truenas` and the namespace is `nas`; both are play variables. Confirm the resulting metric names in VictoriaMetrics after the first run.
- **Syslog.** `system.advanced.update` replaces the whole list and allows two servers. The play keeps every server that is not for the cluster node, replaces an entry for the node on another port or transport, and appends one when there is none. If both slots belong to other hosts, it fails with a message instead of removing one.

## Deploying

```bash
OP_VAULT=<vault-name> nx run truenas:deploy
```

Run it as the captain, not from an agent session - see [AGENTS.md](AGENTS.md). [`scripts/deploy.ts`](scripts/deploy.ts) reads the secrets below through the repo's [1Password-backed configuration API](../../packages/configuration-1password) and runs the playbook with the SSH user as `ansible_user`. SSH uses your normal key setup, and the user must be able to run `midclt` (an admin user can).

| Secret             | Used for                                                            |
| ------------------ | ------------------------------------------------------------------- |
| `truenas/ip`       | The host to run the playbook against                                |
| `truenas/username` | The SSH user                                                        |
| `k8s/ip`           | The Kubernetes node that receives metrics and logs (already exists) |

`truenas/ip` and `truenas/username` do not exist in 1Password yet. They are optional: when either is missing, `deploy` logs a warning and does nothing, like `proxmox2/ip` for [`pve`](../pve/README.md). Create a `truenas` item in the infra vault with `ip` and `username` fields to enable it. The older `nas/ip` is not used here, because it can still point at the previous NAS.

## Dashboard and alerts

The metrics this play turns on feed a Grafana dashboard and a set of alert rules in the cluster:

- **Dashboard.** `TrueNAS`, authored in [`deployments/base/grafana/dashboards/truenas.json`](../../deployments/base/grafana/dashboards/truenas.json) and mounted through the Grafana HelmRelease. It covers CPU usage and temperature, memory, ZFS ARC size and hit ratio, pool usage, per-disk temperature, busy %, IOPS and throughput, network per interface, the NFS server, the backup server VM and the host services.
- **Alerts.** The `truenas` VMRule in [`deployments/production/alerting/truenas-vmrules.yaml`](../../deployments/production/alerting/truenas-vmrules.yaml). The thresholds and what each rule does are in the [alerting README](../../deployments/base/alerting/README.md#truenas).

VictoriaMetrics stores the exporter's metrics as dotted Graphite names with no labels, for example `truenas.nas.truenas_disk_temp.<disk>.temp`. Queries select them with `{__name__=~"..."}` and pull the disk or interface name out of `__name__` with `label_replace`. If you change the exporter's `prefix` or `namespace` (the play variables), update the `truenas.nas.` part of every query in the dashboard and the rules.

### What the metrics cannot tell you

The exporter has no pool health, vdev state or SMART result. A degraded pool, a failed disk that is still listed, a scrub error or a failing SMART attribute does not show up in the dashboard or in any alert here. The disk rules only catch the symptoms that do reach the metrics: a disk that stops reporting, runs hot, or a pool that fills up.

Covering it is a separate piece of work. The most maintainable route is TrueNAS's own alert service: it already raises pool, vdev, SMART, scrub and replication alerts, needs no code in this repo, and stays correct across TrueNAS upgrades. Point one of its alert services at somewhere you read. If you later want those states in Grafana and Alertmanager too, run a maintained exporter in the cluster that reads the TrueNAS API with a read-only API key, rather than writing one here.

## What was verified, and what was not

The middleware method names, field names and the TrueNAS version (25.10.8) were read from the live host with query calls only (`system.version`, `reporting.exporters.query`, `system.advanced.config`, `core.get_methods`, `reporting.exporters.exporter_schemas`). Nothing was created, updated or deleted there.

The play was run against a Debian container with a stand-in `midclt` that follows those shapes. It created both settings on a first run, changed nothing on a second, corrected a disabled and mis-pointed exporter and a UDP syslog entry, kept an unrelated syslog server and a custom `update_every`, and failed cleanly when both syslog slots were taken. It has not been run against the real host.

## Nx targets

| Target   | What it does                                                                                    |
| -------- | ----------------------------------------------------------------------------------------------- |
| `lint`   | `ansible-playbook --syntax-check` against the playbook - no host contact, safe to run anytime.  |
| `deploy` | Runs the play against the NAS over SSH. Not from an agent session - see [AGENTS.md](AGENTS.md). |
