# truenas

Sends the TrueNAS host's metrics, health and logs to the cluster, so nothing is typed into the TrueNAS UI. It is an idempotent Ansible play ([`src/deploy/index.yml`](src/deploy/index.yml)) that connects over SSH and calls TrueNAS's own middleware with `midclt`. It does not install TrueNAS, create pools or shares, or manage anything else on the NAS.

## What it manages

| Concern                                                                           | Middleware call                                                                  |
| --------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| A `victoriametrics` Graphite reporting exporter, pointed at port 30003            | `reporting.exporters.query`, `reporting.exporters.create` and `.update`          |
| A remote syslog server over TCP, pointed at port 30514                            | `system.advanced.config` and `system.advanced.update` (the `syslogservers` list) |
| A cron job that pushes ZFS pool, vdev and SMART health to port 30080 every minute | `cronjob.query`, `cronjob.create` and `.update`                                  |

The destination is the Kubernetes node (`k8s/ip`), on the NodePorts the `metrics` and `logs` deployments publish. All three tasks read the current state first and write only on drift, so a second run changes nothing.

- **Exporter.** Created when missing. When it exists, the play compares the exporter type, destination, port, prefix, namespace and enabled flag, and updates only on drift. Other attributes (`update_every`, `buffer_on_failures` and so on) keep whatever they are. The prefix is `truenas` and the namespace is `nas`; both are play variables. Confirm the resulting metric names in VictoriaMetrics after the first run.
- **Syslog.** `system.advanced.update` replaces the whole list and allows two servers. The play keeps every server that is not for the cluster node, replaces an entry for the node on another port or transport, and appends one when there is none. If both slots belong to other hosts, it fails with a message instead of removing one.
- **Health cron job.** Created when no cron job has the description `Report ZFS pool and SMART health to VictoriaMetrics`. When one exists, the play compares the command, user, schedule, enabled flag and output flags, and updates on drift. Other cron jobs, including the SMART test jobs, are left alone. See [Pool and disk health](#pool-and-disk-health).

## Deploying

```bash
OP_VAULT=<vault-name> nx run truenas:deploy
```

Run it as the captain, not from an agent session - see [AGENTS.md](AGENTS.md). [`scripts/deploy.ts`](scripts/deploy.ts) reads the secrets below through the repo's [1Password-backed configuration API](../../packages/configuration-1password) and runs the playbook with the SSH user as `ansible_user`. SSH uses your normal key setup, and the user must be able to run `midclt` (an admin user can).

| Secret               | Used for                                                                                |
| -------------------- | --------------------------------------------------------------------------------------- |
| `truenas/ip`         | The host to run the playbook against                                                    |
| `truenas/username`   | The SSH user                                                                            |
| `k8s/ip`             | The Kubernetes node that receives metrics and logs (already exists)                     |
| `truenas/health-dir` | Directory on a pool dataset, under `/mnt`, where the play installs the health collector |

`truenas/ip` and `truenas/username` do not exist in 1Password yet. They are optional: when either is missing, `deploy` logs a warning and does nothing, like `proxmox2/ip` for [`pve`](../pve/README.md). Create a `truenas` item in the infra vault with `ip` and `username` fields to enable it. Once those are set, the item also needs a `health-dir` field, and the directory it names must already exist on the NAS (the play does not create datasets); `deploy` fails without it. The older `nas/ip` is not used here, because it can still point at the previous NAS.

## Dashboard and alerts

The metrics this play turns on feed a Grafana dashboard and sets of alert rules in the cluster:

- **Dashboard.** `TrueNAS`, authored in [`deployments/base/grafana/dashboards/truenas.json`](../../deployments/base/grafana/dashboards/truenas.json) and mounted through the Grafana HelmRelease. It covers CPU usage and temperature, memory, ZFS ARC size and hit ratio, pool usage, per-disk temperature, busy %, IOPS and throughput, network per interface, the NFS server, the backup server VM and the host services, plus a `Pool and disk health` row fed by the health cron job.
- **Alerts.** The `truenas` VMRule in [`deployments/production/alerting/truenas-vmrules.yaml`](../../deployments/production/alerting/truenas-vmrules.yaml) for the Graphite metrics, and the `truenas-health` VMRule in [`deployments/production/alerting/truenas-health-vmrules.yaml`](../../deployments/production/alerting/truenas-health-vmrules.yaml) for pool, vdev and SMART health. The thresholds and what each rule does are in the [alerting README](../../deployments/base/alerting/README.md#truenas).

VictoriaMetrics stores the exporter's metrics as dotted Graphite names with no labels, for example `truenas.nas.truenas_disk_temp.<disk>.temp`. Queries select them with `{__name__=~"..."}` and pull the disk or interface name out of `__name__` with `label_replace`. If you change the exporter's `prefix` or `namespace` (the play variables), update the `truenas.nas.` part of every query in the dashboard and the rules.

### What the Graphite metrics cannot tell you

The Graphite exporter has no pool health, vdev state or SMART result. Those come from a separate source, the health cron job below.

## Pool and disk health

A cron job on the NAS pushes ZFS pool, vdev and SMART health into VictoriaMetrics every minute. The `truenas-health` VMRule ([`deployments/production/alerting/truenas-health-vmrules.yaml`](../../deployments/production/alerting/truenas-health-vmrules.yaml)) alerts on it, and the `Pool and disk health` row of the TrueNAS dashboard shows it. The alert thresholds and what each rule does are in the [alerting README](../../deployments/base/alerting/README.md#truenas-health).

### Why a cron job on the NAS

The TrueNAS Graphite exporter only carries performance data, so pool health and SMART need another source. TrueNAS 25.10 also removed its SMART API: there is no `smart.*` method left in the middleware, and `smartd` is off. The only place SMART data exists on the box is `smartctl`. That settles most of the options:

| Option                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | Verdict                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **An exporter in the cluster that reads the TrueNAS API.** The ones that exist (`scottrus/truenas-scale-exporter`, `USA-RedDragon/truenas-exporter`, `katbyte/truenas-exporter`, `Unknowlars/truenas-scale-api-prometheus-exporter` and a few more) are single-maintainer projects created between December 2025 and October 2026, with 0 to 9 stars, and none documents image signing or provenance (one has no license at all). TrueNAS deprecated REST in 25.04 and removes it in 26, so only the JSON-RPC websocket ones have a future. They read pool and vdev state that way, but none can read SMART on 25.10: their READMEs say the API no longer has it. It would also need an API key and a least-privilege user on the NAS, `wss://` with a self-signed certificate (TrueNAS revokes a key it sees over plain `ws://`), a sealed secret, an image to pin and a Deployment, all to read what `zpool status` prints. | Rejected. Too much machinery for half the data, from projects that may not be around at the next upgrade.                                                                                                                                                                                                                                                                                                                                              |
| **A `smartctl` or ZFS exporter run on the NAS** (`smartctl_exporter`, node-exporter textfile).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | Rejected. TrueNAS is an appliance: a package or binary on the root file system does not survive an upgrade, and the apps service is not configured on this host, so there is nowhere sanctioned to run a container.                                                                                                                                                                                                                                    |
| **TrueNAS's own alert service.** It already raises pool (`VolumeStatus`), scrub and SMART alerts.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | Not enough alone. Its alert services are AWS SNS, E-Mail, InfluxDB, Mattermost, OpsGenie, PagerDuty, SNMP Trap, Slack, Telegram and VictorOps: none posts to Alertmanager or Home Assistant. The SMART alerts only cover uncorrectable errors and a failed self-test, not the overall health check or reallocated and pending sectors. The two services configured on this host (an SNMP trap to localhost and an empty E-Mail address) notify nobody. |
| **A cron job on the NAS that reads `midclt` and `smartctl` and pushes to VictoriaMetrics.**                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | Chosen.                                                                                                                                                                                                                                                                                                                                                                                                                                                |

The chosen route uses only what the appliance ships (`python3`, `midclt`, `smartctl`), needs no API key or other secret, and runs on TrueNAS's own cron mechanism, which is how 25.10 itself now schedules SMART tests. The trade-off is that the collector runs on the NAS instead of in the cluster, and it is a script this repo owns (about 150 lines, with tests). It reads the middleware's own view (`pool.query`, `boot.get_state`, `disk.query`), so it matches what the TrueNAS UI shows, including the serial of a disk that was pulled.

### What survives upgrades and reboots

- **The job is registered through the middleware.** The play calls `cronjob.create` and `cronjob.update` through `midclt`, like the exporter and syslog tasks. It never touches `/etc/crontab`, `/etc/cron.d` or any other file. TrueNAS keeps cron jobs in its configuration database, which is carried across upgrades and included in its config backups, and it regenerates the schedule from there at boot.
- **The collector script is a file on a pool dataset.** The play copies [`src/health/truenas-health.py`](src/health/truenas-health.py) to `truenas-health.py` in the directory named by `truenas/health-dir`, owned by root. TrueNAS resets the boot pool's root file system on upgrade, so the file lives on a pool dataset, which an upgrade keeps. The middleware rejects a cron command over 1024 characters, so the command cannot carry the script and is only `python3 <path> push <url>`. The job fails for a minute or two if the pool is not yet imported after a boot, and `TrueNASHealthMetricsMissing` covers that. The play creates the file, not the directory or dataset.
- **Re-running the play is the repair.** If someone deletes or edits the job or the script, the next `nx run truenas:deploy` puts it back, and the `TrueNASHealthMetricsMissing` alert says when it has stopped.

### What it reports

The job runs `python3 <health-dir>/truenas-health.py push http://<node>:30080/api/v1/import/prometheus`, VictoriaMetrics' Prometheus text ingestion on the `vmsingle` NodePort Service, and every sample carries labels, so no name mangling is needed.

| Series                                                                                                                      | Meaning                                                                                                                                                                    |
| --------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `truenas_pool_state{pool,state}`, `truenas_pool_healthy{pool}`                                                              | Pool state (`ONLINE`, `DEGRADED`, ...) and the middleware's healthy flag. The boot pool is included.                                                                       |
| `truenas_pool_vdev_state{pool,class,vdev,type,parent,disk,serial,state}`                                                    | State of every vdev (mirror, RAIDZ) and every disk. A disk carries its kernel name and serial number. A disk that was removed carries the serial the middleware remembers. |
| `truenas_pool_vdev_errors{...,kind}`                                                                                        | Read, write and checksum error counters per vdev and disk.                                                                                                                 |
| `truenas_pool_last_scan_end_timestamp_seconds`, `truenas_pool_last_scan_errors`, `truenas_pool_scan_in_progress`            | The last finished scrub or resilver (ZFS keeps only the latest scan) and whether one is running. A pool that was never scrubbed has no scan series.                        |
| `truenas_disk_info{disk,serial,model,type}`                                                                                 | One per disk, for the labels.                                                                                                                                              |
| `truenas_smart_healthy`, `truenas_smart_selftest_failed`                                                                    | The drive's overall health check and its newest self-test.                                                                                                                 |
| `truenas_smart_reallocated_sectors`, `_pending_sectors`, `_offline_uncorrectable_sectors`, `_reported_uncorrectable_errors` | ATA attributes 5, 197, 198 and 187. A disk that does not report one has no series for it.                                                                                  |
| `truenas_smart_nvme_critical_warning`, `_media_errors`, `_percentage_used`                                                  | NVMe health log.                                                                                                                                                           |
| `truenas_health_collect_ok{source}`, `truenas_smart_collect_ok{disk,serial}`                                                | 0 when a source (`disks`, `pool`, `boot_pool`) or one disk could not be read. One bad source leaves the rest reporting.                                                    |
| `truenas_health_push_timestamp_seconds`                                                                                     | Heartbeat. Pushed last, so it only appears when the run got that far.                                                                                                      |

A disk in standby is not woken: `smartctl -n standby` skips it and its SMART series just carry no new sample. On this host the disks never spin down.

### Running it by hand

On the NAS shell, as root. This prints the metrics and sends nothing:

```bash
python3 <health-dir>/truenas-health.py print
```

Errors go to stderr, so a source that cannot be read shows up there. The same output is what the job pushes. To run the job itself as TrueNAS does, use the cron job's Run Now in the UI (System, Advanced Settings, Cron Jobs) or `midclt call cronjob.run <id> false`.

### After a TrueNAS upgrade

The collector reads `pool.query`, `boot.get_state` and `disk.query` from the middleware and `smartctl -j`. Those shapes were read from the live 25.10.8 host. If an upgrade changes one, the script does not crash: it reports `truenas_health_collect_ok 0` for that source, and the `TrueNASHealthSourceFailing` alert fires after 10 minutes. Fix [`src/health/truenas-health.py`](src/health/truenas-health.py), run its tests (below) and deploy again.

## What was verified, and what was not

The middleware method names, field names and the TrueNAS version (25.10.8) were read from the live host with query calls only (`system.version`, `reporting.exporters.query`, `system.advanced.config`, `core.get_methods`, `reporting.exporters.exporter_schemas`). Nothing was created, updated or deleted there.

The play was run against a Debian container with a stand-in `midclt` that follows those shapes. It created both settings on a first run, changed nothing on a second, corrected a disabled and mis-pointed exporter and a UDP syslog entry, kept an unrelated syslog server and a custom `update_every`, and failed cleanly when both syslog slots were taken. It has not been run against the real host.

For the health job, the `pool.query`, `boot.get_state` and `disk.query` output and the `cronjob.query` and `core.get_methods` shapes were read from the live host with query calls only, and the `src/health` fixtures are trimmed copies of that output with the serials replaced. In an earlier version that embedded the script in the command, the `health` tasks ran against a stand-in `midclt`: they created the cron job, changed nothing on a second run, and put back a disabled job with a changed schedule, user and command. The stored command was then run the way the middleware runs it (newlines stripped, `sh -c`) and its push was received by a local HTTP server. The collector's output was pushed into a local VictoriaMetrics, evaluated by a real vmalert and shown in a real Grafana. What was not run after moving the script to a file on a dataset: the play against the real host or a stand-in (the render of the cron command was checked to be under 1024 characters). Also not run: the job on the real host (the play makes changes there, so the captain deploys it) and `smartctl` on the real disks, whose JSON the fixtures follow from smartmontools 7.4 and the parsing in TrueNAS's own SMART alert source.

## Nx targets

| Target   | What it does                                                                                                                                                                                     |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `lint`   | `ansible-playbook --syntax-check` against the playbook - no host contact, safe to run anytime.                                                                                                   |
| `test`   | Jest tests for the health collector (recorded `midclt` and `smartctl` output, needs `python3`), then the `vmalert-tool` tests for the `truenas` alert rules in `tests/` (needs Docker and `yq`). |
| `deploy` | Runs the play against the NAS over SSH. Not from an agent session - see [AGENTS.md](AGENTS.md).                                                                                                  |

The `truenas-health` alert rules have their own unit tests, [`src/health/rules/truenas-health.test.yaml`](src/health/rules/truenas-health.test.yaml), which `vmalert-tool` runs against the rules. They need Docker and `yq`, so they are not part of `test`:

```bash
sh apps/truenas/src/health/rules/test-rules.sh
```
