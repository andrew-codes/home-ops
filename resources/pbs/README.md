# pbs

Ansible-driven configuration for the [Proxmox Backup Server](https://www.proxmox.com/en/proxmox-backup-server) host, run remotely over SSH. It is the backup target for the sibling `pve` Proxmox VE host. This app configures a host that already runs PBS and already has its datastore. It adopts what is there and does not create or move storage.

## Prerequisites - not automated

1. **The PBS install itself.** Follow the [official Proxmox Backup Server installation docs](https://pbs.proxmox.com/docs/installation.html) to get a host booted into a fresh PBS install, reachable over SSH. Nothing here can do this step; it needs the installer console.
2. **The datastore.** Create the datastore named `main` by hand, on a local disk that the host mounts itself (`/etc/fstab`). The host is a VM on TrueNAS, so the NAS provides the disk underneath and PBS sees a local file system. This app never creates a datastore. If `main` does not exist, the play stops with a message.
3. **Populate the 1Password items this app reads from**, before the first deploy - see [Configuration](#configuration).

**Hostname assumption.** This app sets the hostname to `pbs`. Confirm before running that `pbs` does not collide with anything already on the network.

## What it manages

| Concern                                                                                                                                     | Where                                      |
| ------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------ |
| Timezone (`America/New_York`)                                                                                                               | [`scripts/deploy.yml`](scripts/deploy.yml) |
| DNS (`1.1.1.1`, `1.0.0.1`) and search domain (`smith-simms.family`)                                                                         | [`scripts/deploy.yml`](scripts/deploy.yml) |
| Hostname (`pbs`) and `/etc/hosts`                                                                                                           | [`scripts/deploy.yml`](scripts/deploy.yml) |
| Andrew's SSH public key                                                                                                                     | [`scripts/deploy.yml`](scripts/deploy.yml) |
| apt sources: no enterprise source, one no-subscription source (see [below](#package-and-repositories))                                      | [`scripts/deploy.yml`](scripts/deploy.yml) |
| Proxmox Backup Server package: installed only when absent, never pinned or held                                                             | [`scripts/deploy.yml`](scripts/deploy.yml) |
| Backup user, its ACL, prune and verify jobs and the GC schedule of datastore `main`, each added only when missing (see [Storage](#storage)) | [`scripts/deploy.yml`](scripts/deploy.yml) |
| Firewall (`ufw`: SSH and the PBS web UI)                                                                                                    | [`scripts/deploy.yml`](scripts/deploy.yml) |
| NUT UPS monitoring, opt-in and off by default (see [below](#nut-ups-monitoring))                                                            | [`scripts/deploy.yml`](scripts/deploy.yml) |
| Logs and metrics sent to the cluster (see [below](#observability))                                                                          | [`scripts/deploy.yml`](scripts/deploy.yml) |
| Backup and task health timer (see [below](#backup-and-task-health))                                                                         | [`scripts/deploy.yml`](scripts/deploy.yml) |

Not managed: the network, the datastore itself, any mount, and every datastore other than `main`.

Everything is applied by one playbook, [`scripts/deploy.yml`](scripts/deploy.yml), run against the single host in [`scripts/deploy.ts`](scripts/deploy.ts)'s generated inventory.

## Deploying

```bash
OP_VAULT=<vault-name> nx run pbs:deploy
```

[`scripts/deploy.ts`](scripts/deploy.ts) reads `pbs/ip`, `pbs/username`, `pbs/password`, `pbs/backup-username`, `pbs/backup-password` and `k8s/ip` through the repo's [1Password-backed configuration API](../../packages/configuration-1password), writes them into a gitignored `.secrets/` inventory and vars file next to the playbook, and runs `ansible-playbook` against them.

### Andrew's SSH key is a special case

`pbs/*` above all come from `OP_VAULT`, the shared infra-secrets vault every other `configurationApi.get()` call in this repo reads from. Andrew's own SSH key is different: it is a personal credential that lives in the **`Private`** 1Password vault as the `andrew-mbp` item, independent of whatever `OP_VAULT` is set to. [`scripts/deploy.ts`](scripts/deploy.ts) reads it directly with `op read "op://Private/andrew-mbp/public key"` rather than through `configurationApi`, and installs it as an `authorized_key` for the account the playbook connects as.

### Configuration

| Secret                               | 1Password location          | Needed when                     |
| ------------------------------------ | --------------------------- | ------------------------------- |
| `pbs/ip`                             | infra vault (`OP_VAULT`)    | always                          |
| `pbs/username`                       | infra vault (`OP_VAULT`)    | always                          |
| `pbs/password`                       | infra vault (`OP_VAULT`)    | always                          |
| `pbs/backup-username`                | infra vault (`OP_VAULT`)    | always                          |
| `pbs/backup-password`                | infra vault (`OP_VAULT`)    | always                          |
| `k8s/ip`                             | infra vault (`OP_VAULT`)    | always (the observability node) |
| `op://Private/andrew-mbp/public key` | `Private` vault, fixed item | always                          |
| `truenas/ip`                         | infra vault (`OP_VAULT`)    | only with `PBS_ENABLE_NUT=1`    |
| `nut/monitor-username`               | infra vault (`OP_VAULT`)    | only with `PBS_ENABLE_NUT=1`    |
| `nut/monitor-password`               | infra vault (`OP_VAULT`)    | only with `PBS_ENABLE_NUT=1`    |

All of these exist today, so a default deploy needs no new 1Password field.

`pbs/backup-username` and `pbs/backup-password` are the credentials the PBS-side backup user is created with and the ones any client (`pve`, or a manual `proxmox-backup-client`) authenticates as against the `main` datastore. The play creates the user only when it is missing, and never changes the password of an existing one.

## Network

The network is not managed. A host is reached at the address in `pbs/ip`, so it is already on that address, and a play that rewrote the interface could cut off its own SSH connection. Set the address of the host when you install it, and keep `pbs/ip` in step with it. If the address has to change, change it on the console, then update `pbs/ip`.

## NUT UPS monitoring

NUT is opt-in and off by default. The UPS server will be the TrueNAS host, but it does not run NUT yet, so a default deploy installs nothing and writes no `MONITOR` line.

> [!WARNING] > **A misconfigured client here can shut this host down unexpectedly.** Enable it only
> after TrueNAS runs a NUT server, with the UPS name and the monitor account below
> verified against it.

To enable it, run `PBS_ENABLE_NUT=1 OP_VAULT=<vault-name> nx run pbs:deploy`. [`scripts/deploy.ts`](scripts/deploy.ts) then reads `truenas/ip`, `nut/monitor-username` and `nut/monitor-password`, and the play:

- installs `nut-client` (client only, no local `upsd`) and sets `/etc/nut/nut.conf` to `MODE=netclient`;
- writes `/etc/nut/upsmon.conf` with a `MONITOR` line for UPS `ups` on the TrueNAS host (`secondary` mode, `shutdown -h +0` on `FSD` or low battery), with `no_log: true` because it holds a password;
- enables and starts `nut-monitor`, and restarts it only when the config changed.

The UPS name `ups` is an assumption until the TrueNAS side exists. Change `nut_ups_name` in [`scripts/deploy.yml`](scripts/deploy.yml) if the server names it differently.

Without `PBS_ENABLE_NUT=1`, the play removes any active `MONITOR` line from an existing `/etc/nut/upsmon.conf` and stops and disables `nut-monitor`. A host that an earlier run pointed at an old UPS server is therefore left with no active monitor. A host that never had NUT has no file, and nothing happens.

## Observability

Sends this host's logs and metrics to the Kubernetes node (`k8s/ip`, written to
`.secrets/ansible-secrets.yml` as `observability_host`), on the NodePorts the `logs` and
`metrics` deployments publish. Every task is tagged `observability`.

- Installs `rsyslog` (PBS logs to journald only) and templates
  `/etc/rsyslog.d/90-victorialogs.conf` from
  [`scripts/templates/victorialogs-rsyslog.conf.j2`](scripts/templates/victorialogs-rsyslog.conf.j2).
  It forwards everything to VictoriaLogs over TCP in RFC 5424 format (port `30514`) with a
  100MB disk queue. The file is installed at its real path and then `rsyslogd -N1` checks the
  whole configuration (`/etc/rsyslog.conf` plus `/etc/rsyslog.d`). A config that fails is rolled
  back (the previous file is restored, or the new one removed) and the play fails before rsyslog
  restarts. The `restart rsyslog` handler runs only when the config changed.
- Adds a `victoriametrics` InfluxDB (HTTP) metric server pointed at port `30080` with
  `proxmox-backup-debug api create /config/metrics/influxdb-http`, and reconciles it with
  `api set` when the URL, organization, bucket or enabled flag drifted. PBS has no
  `proxmox-backup-manager` subcommand for metric servers, so this calls the API locally.
  VictoriaMetrics ignores the token, organization and bucket, and the token is optional.

The `proxmox-backup-debug api` calls were checked against the PBS API schema and against a
stand-in binary, not against a real PBS host. Confirm them on the first run with
`proxmox-backup-debug api get /config/metrics/influxdb-http`.

### Metrics, dashboard and alerts

What PBS pushes is shown in Grafana (`Proxmox Backup Server`, [`deployments/base/grafana/dashboards/pbs.json`](../../deployments/base/grafana/dashboards/pbs.json)) and alerted on through Alertmanager (the `pbs` VMRule in [`deployments/production/alerting/pbs-vmrules.yaml`](../../deployments/production/alerting/pbs-vmrules.yaml), listed in the [alerting README](../../deployments/base/alerting/README.md#proxmox-backup-server)).

**Series names.** PBS sends InfluxDB line protocol, and VictoriaMetrics names each series `{measurement}_{field}` with the tags as labels. The measurements and fields come from the PBS source (`src/server/metric_collection` in `proxmox-backup`, and `proxmox-sys` for the CPU and memory fields), and the names were checked by feeding that exact line format to VictoriaMetrics v1.156.0:

| Series                                                                                                             | Labels                                           | Meaning                                                                                                      |
| ------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------ |
| `cpustat_cpu`, `cpustat_iowait_percent`                                                                            | `object="host"`, `host`                          | CPU use and I/O wait, 0 to 1                                                                                 |
| `cpustat_avg1`, `cpustat_avg5`, `cpustat_avg15`, `cpustat_cpu_count`                                               | same                                             | load average and CPU count                                                                                   |
| `memory_memtotal`, `memory_memused`, `memory_memavailable`, `memory_swapused`                                      | same                                             | bytes                                                                                                        |
| `nics_receive`, `nics_send`                                                                                        | `object="host"`, `host`, `instance` (interface)  | cumulative bytes                                                                                             |
| `blockstat_total`, `blockstat_used`, `blockstat_avail`                                                             | `object="host"`, `host`, and `datastore` for one | bytes of the file system. With no `datastore` label it is the root file system of the host.                  |
| `blockstat_read_bytes`, `blockstat_write_bytes`, `blockstat_read_ios`, `blockstat_write_ios`, `blockstat_io_ticks` | same                                             | cumulative block device counters, only when the file system has a local block device (an NFS mount has none) |

PBS leaves a datastore out of these while it is in maintenance mode or, for a removable datastore, unmounted. PBS pushes every 10 seconds. To list what the cluster actually received, run this from a machine that can reach the node, and compare it with the table:

```sh
curl -s 'http://<node address>:30080/api/v1/label/__name__/values' | grep -E '^(cpustat|memory|nics|blockstat)_'
```

## Backup and task health

PBS's metric server carries no task results, so a failed backup, verify, prune or garbage collection is invisible to it. [`scripts/files/pbs-health.py`](scripts/files/pbs-health.py) fills the gap. A systemd timer (`pbs-health.timer`, every 5 minutes, [`scripts/files/pbs-health.timer`](scripts/files/pbs-health.timer) and [`scripts/templates/pbs-health.service.j2`](scripts/templates/pbs-health.service.j2)) runs it and POSTs Prometheus text to VictoriaMetrics' `/api/v1/import/prometheus`, the same door the [TrueNAS health job](../truenas/README.md#pool-and-disk-health) uses. The script is installed as a file at `/usr/local/lib/pbs-health/pbs-health.py`, not inlined in a command. It needs only `python3` (which Ansible requires anyway) and `proxmox-backup-debug`, which calls the local PBS API as root and keeps working while the `proxmox-backup` service is stopped. Every task is tagged `observability` and `health`, and a change to the script or the service runs it once at the end of the deploy, so a script that does not work fails the deploy.

| Series                                                                                                | Labels                                               | Meaning                                                                                                               |
| ----------------------------------------------------------------------------------------------------- | ---------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `pbs_health_push_timestamp_seconds`                                                                   |                                                      | heartbeat, written last                                                                                               |
| `pbs_health_collect_ok`                                                                               | `source`                                             | 0 when the timer could not read `services`, `datastores`, `groups`, `tasks`, `jobs_verify`, `jobs_prune` or `jobs_gc` |
| `pbs_service_up`                                                                                      | `unit`                                               | `proxmox-backup` and `proxmox-backup-proxy` are active                                                                |
| `pbs_datastore_available`                                                                             | `datastore`                                          | 1 when PBS can open the datastore and read its file system (`/admin/datastore/<name>/status`)                         |
| `pbs_backup_last_success_timestamp_seconds`, `pbs_backup_interval_seconds`                            | `datastore`, `namespace`, `backup_type`, `backup_id` | last good backup of each guest (`/admin/datastore/<name>/groups`) and its usual interval                              |
| `pbs_backup_last_task_ok`, `pbs_backup_last_task_end_timestamp_seconds`                               | `datastore`, `backup_type`, `backup_id`              | result of the newest finished backup task of each guest in the last 14 days (`/nodes/localhost/tasks`)                |
| `pbs_job_last_run_ok`, `pbs_job_last_run_end_timestamp_seconds`, `pbs_job_next_run_timestamp_seconds` | `type` (`verify`, `prune`, `gc`), `datastore`, `job` | last run of each scheduled job (`/admin/verify`, `/admin/prune`, `/admin/gc`)                                         |
| `pbs_gc_removed_bytes`, `pbs_gc_pending_bytes`                                                        | `datastore`                                          | what the last garbage collection freed and what it kept for now                                                       |

- **Task results.** A state of `OK` or `WARNINGS: n` is a success, anything else is a failure. The newest finished backup task of each guest wins, so a failure clears when the next backup succeeds. A failed backup task has no namespace in its id, so `pbs_backup_last_task_ok` has none either.
- **The schedule of a guest.** The backup job lives in Proxmox VE, so PBS does not know it. The script reads each guest's usual interval from its newest snapshots (the median gap of up to six), and the stale-backup alerts allow one and a half intervals (warning) and three (critical). A guest with fewer than three snapshots is assumed to be daily. A guest that was retired on purpose keeps alerting until its backup group is forgotten in the PBS UI, or its last snapshot is pruned.
- **A datastore that does not answer.** A datastore disk or mount that stops answering blocks the API call in the kernel. Each call has a 30 second limit, a call that hangs is abandoned (it cannot be killed while it waits on the mount), and the datastore is reported with `pbs_datastore_available 0`. The unit has a 5 minute limit, so a run that still hangs stops before the next one starts, and the heartbeat alert covers it.
- **Dry run.** On the host, `python3 /usr/local/lib/pbs-health/pbs-health.py print` writes the metrics to stdout. `systemctl list-timers pbs-health.timer` and `journalctl -u pbs-health` show the timer and the last run.
- **Not covered.** Only scheduled verify, prune and garbage collection jobs are read from the job APIs, and backup tasks from the task list. A one-off prune or verify started by hand, and sync jobs, are not reported.
- **The API shapes were not run against a real PBS.** They come from the PBS source (`proxmox-backup` `src/api2`) and are exercised by the tests in `tests/test_pbs_health.py` with answers written out in the shape `proxmox-backup-debug api get --output-format json` prints. After the first deploy, confirm with `python3 /usr/local/lib/pbs-health/pbs-health.py print`: every `pbs_health_collect_ok` should be 1, and the `pbs_backup_*` and `pbs_job_*` series should list your guests and jobs. A `0` names the source whose output did not match.

The alert rules and their unit tests are described in the [alerting README](../../deployments/base/alerting/README.md#proxmox-backup-server). The rules are tested with `vmalert-tool` (Docker and `yq` needed): `yarn nx test pbs` runs both these and the script's unit tests, or run `scripts/test-rules.sh` and `python3 -m unittest discover -s tests` from this directory.

## Storage

Storage belongs to the host, not to this app. Datastore `main` lives on a local disk that `/etc/fstab` mounts, and the play never mounts, formats, chowns or moves anything. It reads the datastore list from PBS and adopts `main`. If `main` is missing, the play fails before it changes anything.

Every step below acts only when its object is missing, so a run never duplicates or overwrites what an admin set up:

| Object                     | Added when                               | Kept as it is when                               |
| -------------------------- | ---------------------------------------- | ------------------------------------------------ |
| Backup user                | the user does not exist                  | the user exists (the password is not reset)      |
| `DatastoreBackup` ACL      | the user has no ACL on `/datastore/main` | the ACL exists                                   |
| Prune job (`prune-main`)   | no prune job has store `main`            | any prune job has store `main`, whatever its id  |
| Verify job (`verify-main`) | no verify job has store `main`           | any verify job has store `main`, whatever its id |
| GC schedule (`weekly`)     | the datastore has no `gc-schedule`       | the datastore has a `gc-schedule`                |

Other datastores on the host (for example an S3-backed offsite datastore with a local cache) are not read or changed by the play. The [health collector](#backup-and-task-health) and the dashboard still cover every datastore that PBS lists.

The name of the adopted datastore is `pbs_datastore_name` in [`scripts/deploy.yml`](scripts/deploy.yml).

An older host can still carry an NFS mount at `/mnt/pbs` and a `proxmox-backup.service` drop-in (`RequiresMountsFor=/mnt/pbs`) from an earlier version of this app. The play no longer writes either and does not remove them. Remove them by hand if the host no longer uses that mount.

## Manual steps - not run by this task

- The PBS install itself and the creation of datastore `main` (see [Prerequisites](#prerequisites---not-automated)).
- Any reboot - the play never reboots the host on its own.
- Turning on NUT, once TrueNAS runs a NUT server (see [NUT UPS monitoring](#nut-ups-monitoring)).

## Package and repositories

PBS 4 runs on Debian trixie and keeps its apt sources as deb822 `.sources` files. The play:

- removes any `.list` or `.sources` file under `/etc/apt/sources.list.d` that names `enterprise.proxmox.com`, because the enterprise source needs a subscription and makes `apt-get update` fail;
- adds `pbs-no-subscription.sources` only when no file under `/etc/apt` already names `pbs-no-subscription`, so a source that exists under another file name is not duplicated.

The `proxmox-backup-server` package is not pinned and not held. The play installs it only when `proxmox-backup-manager version` fails (a host from the PBS ISO already has it), at the version the repository offers then. It never upgrades a running install. A host that an earlier run held gets the hold released. To update PBS, run `apt full-upgrade` on the host yourself.

## Idempotency

Every task either checks existing state before changing it (hostname, apt sources, apt package presence via `proxmox-backup-manager version`, the package hold, PBS users, ACLs, prune jobs, verify jobs and the GC schedule) or is naturally idempotent (`apt`, `copy`, `ufw`, `ansible.posix.authorized_key`). Re-running against an already-configured host is expected to report no changes.

## What was verified, and what was not

The 1Password field name (`public key`, not `public-key`) and vault (`Private`) for the `andrew-mbp` SSH key item were confirmed with `op item get andrew-mbp` and a live `op read`, not assumed. The official PBS installation docs URL was fetched and confirmed live.

**This playbook has never been run against the real host.** Verification here is `ansible-playbook --syntax-check`, the unit tests for the health script and the alert rules, `eslint` and `prettier` against the changed files, and a read-only look at the host: it runs PBS 4 on Debian trixie, has a local `main` datastore with jobs and an ACL already in place, no NFS mount, no enterprise source and no NUT. The storage tasks were also run against a stand-in `proxmox-backup-manager` that returns that state. They made no change, and they made the five expected changes against an empty one. A real run is a manually supervised action after PR review.

## Nx targets

| Target   | What it does                                                                                                                                                                           |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `deploy` | Runs [`scripts/deploy.ts`](scripts/deploy.ts), which writes the Ansible inventory/vars from 1Password and runs [`scripts/deploy.yml`](scripts/deploy.yml) against the host.            |
| `test`   | Runs the health script's unit tests (`python3 -m unittest`) and the `vmalert-tool` tests of the alert rules ([`scripts/test-rules.sh`](scripts/test-rules.sh), needs Docker and `yq`). |
