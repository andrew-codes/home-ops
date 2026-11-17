# Metrics and alerting

VictoriaMetrics (VMSingle, in `deployments/base/metrics`) stores metrics and vmagent scrapes. vmalert plus
Alertmanager (`VMAlert`, `VMAlertmanager`, managed by the VictoriaMetrics operator) turn rules into
notifications. They live in their own Flux Kustomization, `alerting`, so a missing receiver secret never
blocks `metrics` or `grafana`.

```text
vmagent -> VMSingle <- vmalert -> Alertmanager -+-> Home Assistant webhook -> companion app push (everyone)
                                                +-> Healthchecks.io ping (Watchdog only, dead-man's switch)
```

- Rules are `VMRule` objects in `vmrules.yaml`. Every rule needs a `summary` (what is wrong, naming the
  target) and a `description` (the instance, job or service and the measured value). The push text is
  built from them: the title is the first alert's `summary` (plus a count of the rest) and the body is one
  `summary` line per alert. The `description` is not in the push, it is on the Grafana alert groups page
  the push opens. `dashboard_url` is optional and becomes the push's Dashboard button.
- Alertmanager config is in `vmalertmanager.yaml`. It contains no secrets: the receiver URLs are read
  from the `alertmanager-receivers` secret (`url_file`).
- Alerts are grouped by severity, so one outage reads as one push listing everything affected. A
  `critical` push is an iOS critical alert (bypasses silent mode and Do Not Disturb). A resolved push is
  sent when the alerts clear.
- Per-machine and per-service checks are vmalert rules. They do not use Healthchecks.io checks. Only the
  Watchdog heartbeat does, so the 20 free checks are not a limit on how much is monitored.
- The Watchdog covers what in-cluster alerting cannot: if the cluster, the node, vmalert, VMSingle or the
  network path is down, the pings stop and Healthchecks.io notifies you directly.

## Cluster metrics, dashboards and rules

Two exporters in `deployments/base/exporters` (their own Flux Kustomization, `exporters`, so a failing
exporter never blocks `metrics`, `grafana` or `alerting`) feed the Kubernetes dashboards and rules:

- `node-exporter` (DaemonSet, scrape job `node-exporter`): host CPU, memory, disk and network per node.
  Series carry a `node` label with the Kubernetes node name.
- `kube-state-metrics` (Deployment, scrape job `kube-state-metrics`): pod, deployment, node and volume
  state, including container restarts and waiting reasons.

vmagent finds both through their Services (the jobs in `deployments/base/metrics/helm-release.yaml`).
It also adds a `cluster="home-ops"` label to everything it scrapes, because the dashboards filter on it.
The kubelet and cAdvisor jobs (`kubernetes-nodes`, `kubernetes-nodes-cadvisor`) also set a `node` label
from the Kubernetes node name, which the Nodes dashboard filters on for container and PVC volume series
(`kubelet_volume_stats_*`). The kubelet reports those for PVC-backed volumes, NFS included, so the
Kubernetes Storage panels only fill for volumes mounted by a running pod.

Grafana provisions dotdc's Kubernetes / Views set (Global, Namespaces, Nodes, Pods) and Node Exporter
Full from grafana.com, pinned by revision in `deployments/base/grafana/helm-release.yaml`. They pick the
datasource through a `datasource` variable, which resolves to the default `victoriametrics` datasource.

The rules built on them:

| Rule                                                           | Severity | Fires when                                                                                |
| -------------------------------------------------------------- | -------- | ----------------------------------------------------------------------------------------- |
| `NodeFilesystemFillingUp`                                      | warning  | a node disk has under 40% free and is predicted to run out within 24 hours (6 hour trend) |
| `NodeFilesystemSpaceLow`                                       | warning  | a node disk has under 10% free for 15 minutes                                             |
| `NodeFilesystemAlmostFull`                                     | critical | a node disk has under 3% free for 5 minutes                                               |
| `KubePodCrashLooping`                                          | warning  | a container is in `CrashLoopBackOff` for 10 minutes                                       |
| `KubePodRestartingTooOften`                                    | warning  | a container restarted more than 5 times in an hour                                        |
| `NodeExporterTargetsMissing`, `KubeStateMetricsTargetsMissing` | warning  | an exporter has no scrape target for 10 minutes, so the rules above cannot fire           |

The disk rules skip `tmpfs`, `overlay`, `squashfs`, read-only and network file systems. Network volumes
(PVCs) are covered by the `PersistentVolume*` rules from the kubelet volume stats. A scrape target that
is present but down is already caught by `TargetDown`, except the gaming PC's, which is off for much of
the day (see [Gaming PC](#gaming-pc)).

## TrueNAS

The NAS pushes its metrics through the Graphite reporting exporter that `apps/truenas` configures. They arrive as dotted names with no labels (`truenas.nas.<family>.<...>`), and the rules read the disk or interface name out of `__name__` with `label_replace`. The `TrueNAS` dashboard in Grafana shows the same series.

The rules are the `truenas` VMRule in `deployments/production/alerting/truenas-vmrules.yaml`. They are in the production overlay, not base, because staging receives no TrueNAS metrics and the missing-data rules would fire there forever. Disks in the text are shown by serial number.

| Rule                                   | Severity | Fires when                                                                                                        |
| -------------------------------------- | -------- | ----------------------------------------------------------------------------------------------------------------- |
| `TrueNASMetricsMissing`                | critical | the uptime series is gone for 10 minutes: host down or unreachable, exporter off, or Graphite not ingested        |
| `TrueNASPoolUsageHigh`                 | warning  | the pool is over 80% full for 30 minutes                                                                          |
| `TrueNASPoolAlmostFull`                | critical | the pool is over 90% full for 15 minutes                                                                          |
| `TrueNASPoolFillingUp`                 | warning  | the pool is over 70% full and the 24 hour trend of free space reaches zero within 7 days (for 1 hour)             |
| `TrueNASDiskTemperatureHigh`           | warning  | a disk is at 50 °C or more for 15 minutes                                                                         |
| `TrueNASDiskTemperatureCritical`       | critical | a disk is at 60 °C or more for 5 minutes                                                                          |
| `TrueNASDiskMissing`                   | warning  | a disk that reported in the last day has no sample for 15 minutes (for 10 minutes) while other disks still do     |
| `TrueNASDiskTemperatureMetricsMissing` | warning  | no disk temperature series for 15 minutes while the host still reports                                            |
| `TrueNASDiskStatsMetricsMissing`       | warning  | no disk busy, IOPS or throughput series for 15 minutes while the host still reports                               |
| `TrueNASNetworkLinkDown`               | warning  | a physical interface (name starting `en` or `eth`) has no carrier for 5 minutes after being up in the last 7 days |

- **Thresholds.** The disk temperatures are typical NAS hard disk limits: drives are rated to 60 to 65 °C, and sustained 50 °C or more shortens their life. NVMe and SSD drives run hotter, so if one lives in the NAS and trips the warning, raise the numbers or split the rule. The pool numbers follow the ZFS rule of thumb that performance drops past 80% full.
- **The pool is one series.** The exporter reports pool usage without a pool name, so the pool rules describe "the pool". Check them again if a second pool is added.
- **Gaps in the push stream.** The disks report together, so a pause of the whole push stream, for example while VictoriaMetrics restarts, silences every disk at once. The disk and link rules read the current value with `last_over_time` over 5 minutes, so a short gap does not reset them. `TrueNASDiskMissing` looks for a disk with no sample in 15 minutes and only fires while at least one other disk has a recent sample. When every disk is quiet, `TrueNASDiskTemperatureMetricsMissing` and `TrueNASMetricsMissing` are the alerts that fire.
- **Rule tests.** `yarn nx test truenas` runs the `vmalert-tool` unit tests in `apps/truenas/tests` against these rules. It needs Docker and `yq`, and runs in the pull request checks.
- **Unused ports.** `TrueNASNetworkLinkDown` ignores a port that was never up in the last 7 days, so a free port does not alert. A port that is unplugged for more than 7 days stops alerting.

**Health.** The exporter has no pool health, vdev state or SMART result, so none of the rules above can see a degraded pool or a failing disk. The rules in the next section cover that, from a different source.

### TrueNAS health

A cron job on the NAS (`apps/truenas`, see its [README](../../../apps/truenas/README.md#pool-and-disk-health) for why and how) pushes ZFS pool, vdev, SMART and scheduled task series into VictoriaMetrics every minute: `truenas_pool_*`, `truenas_smart_*`, `truenas_task_*`, `truenas_job_*` and `truenas_health_*`, all with real labels. The rules are the `truenas-health` VMRule in `deployments/production/alerting/truenas-health-vmrules.yaml`, again in the production overlay only. Each push names the pool, the vdev and the disk by serial number and kernel name, for example `TrueNAS disk <serial> (sdb) in pool tank is FAULTED`. A disk that was pulled keeps the serial TrueNAS remembers for it.

| Rule                                       | Severity | Fires when                                                                                                                                                                                                                                      |
| ------------------------------------------ | -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `TrueNASPoolNotOnline`                     | critical | a pool (boot pool included) is in any state but `ONLINE` for 2 minutes                                                                                                                                                                          |
| `TrueNASVdevNotOnline`                     | critical | a mirror or RAIDZ vdev, or a disk in one, is `DEGRADED`, `FAULTED`, `OFFLINE`, `REMOVED` or `UNAVAIL` for 2 minutes (spares that are `AVAIL` or `INUSE` are fine)                                                                               |
| `TrueNASVdevErrors`                        | warning  | ZFS counts read, write or checksum errors on a vdev or disk, for 5 minutes. The counters stay until `zpool clear`.                                                                                                                              |
| `TrueNASPoolScanErrors`                    | warning  | the last finished scrub or resilver found errors                                                                                                                                                                                                |
| `TrueNASScrubOverdue`                      | warning  | a pool has gone 45 days with no finished scrub or resilver (the schedule scrubs a pool whose last scrub is over 35 days old), for 1 hour. A scrub in progress, or a pool never scrubbed, does not alert.                                        |
| `TrueNASSmartHealthFailed`                 | critical | a disk reports a failed SMART overall health check for 5 minutes                                                                                                                                                                                |
| `TrueNASSmartSelfTestFailed`               | warning  | the newest SMART self-test of a disk did not pass, for 5 minutes                                                                                                                                                                                |
| `TrueNASSmartReallocatedSectorsIncreasing` | warning  | a disk's reallocated sector count grew in the last 7 days                                                                                                                                                                                       |
| `TrueNASSmartPendingSectors`               | warning  | a disk has had pending (unreadable) sectors for 1 hour                                                                                                                                                                                          |
| `TrueNASSmartUncorrectableErrors`          | warning  | a disk reports offline uncorrectable sectors (SMART 198) or reported uncorrectable errors (SMART 187) for 1 hour                                                                                                                                |
| `TrueNASNvmeCriticalWarning`               | critical | an NVMe disk raises any critical warning flag (spare low, temperature, reliability, read-only, backup) for 5 minutes                                                                                                                            |
| `TrueNASNvmeMediaErrorsIncreasing`         | warning  | an NVMe disk logged more media errors in the last 7 days                                                                                                                                                                                        |
| `TrueNASHealthMetricsMissing`              | warning  | the host still reports performance metrics but the health job has not pushed for 15 minutes, so a bad pool would go unseen. Quiet when the host is down, which `TrueNASMetricsMissing` covers.                                                  |
| `TrueNASHealthSourceFailing`               | warning  | the job could not read `disks`, `pool`, `boot_pool`, a task type (`tasks_cloudsync`, `tasks_replication`, `tasks_snapshot`, `tasks_rsync`) or `job_history` from the middleware for 10 minutes, for example after an upgrade changed its output |
| `TrueNASSmartReadFailing`                  | warning  | `smartctl` could not read a disk for 10 minutes                                                                                                                                                                                                 |
| `TrueNASTaskFailed`                        | warning  | the last run of an enabled cloud sync, replication, periodic snapshot or rsync task failed, for 5 minutes. It stays on until the task runs again and succeeds.                                                                                  |
| `TrueNASTaskOverdue`                       | warning  | an enabled task has not started 15 minutes after its schedule called for it, for 5 minutes. A running task, and a task with no recorded run, do not alert.                                                                                      |

- **Sources.** Pool and disk state come from the TrueNAS middleware, SMART from `smartctl`. TrueNAS 25.10 has no SMART API, so no exporter that reads the API can offer these.
- **Counters versus gauges.** The sector counters are gauges, so "increasing" uses `delta` over 7 days. A count that was already there when the job first ran is not alerted on, and a count that stops growing resolves after the window.
- **Gaps and resolving.** A cron run can be missed, and the Graphite exporter pushes with gaps, so no rule reads a bare selector for a current value or for presence. Current values go through `last_over_time` over 5 minutes, and the heartbeat and uptime checks through `absent_over_time` over 10 minutes, so a gap cannot fire or mute an alert. The price is that an alert resolves up to 5 minutes after the state changes: a recovered pool is a new series (the `state` label changes), and the old state series stays in the window.
- **Scheduled tasks.** The job also reads the cloud sync, replication, periodic snapshot and rsync tasks and the middleware's recent job history (`truenas_task_*` and `truenas_job_*`). Each task is identified by `type`, `task` (its name, dataset or path) and `id`. The overdue rule compares `truenas_task_last_run_timestamp_seconds` with `truenas_task_last_scheduled_timestamp_seconds`, the newest time the task's cron schedule called for it in the NAS's time zone. Scrubs and SMART self-tests are not task series: `TrueNASScrubOverdue`, `TrueNASPoolScanErrors` and `TrueNASSmartSelfTestFailed` cover them. TrueNAS keeps snapshot and replication state in memory, so those tasks have no last run after a reboot until they run again and are not checked for overdue until then. The job history only feeds the dashboard.
- **Unit tests.** `apps/truenas/src/health/rules/truenas-health.test.yaml` runs the rules through `vmalert-tool` (`sh apps/truenas/src/health/rules/test-rules.sh`, needs Docker and `yq`). It covers a healthy NAS that fires nothing, each failure, recovery, failed and overdue tasks, gaps between pushes, the exact push text, and the fake-pool test below.

## Proxmox Backup Server

The backup server pushes its host and datastore usage through its InfluxDB metric server (`resources/pbs`), and a systemd timer on the same host (`resources/pbs/scripts/files/pbs-health.py`, see its [README](../../../resources/pbs/README.md#backup-and-task-health)) pushes what the metric server cannot carry: backup and job results, the age of each guest's last good backup, datastore availability and a heartbeat. The `Proxmox Backup Server` dashboard in Grafana shows both. The rules are the `pbs` VMRule in `deployments/production/alerting/pbs-vmrules.yaml`, in the production overlay only because staging receives no PBS metrics and the missing-data rules would fire there forever. Guests are named as Proxmox does, `vm/100` or `ct/101`.

| Rule                         | Severity | Fires when                                                                                                                                                                               |
| ---------------------------- | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PBSMetricsMissing`          | critical | no host metrics for 10 minutes (for 5): the host is down or unreachable, `proxmox-backup-proxy` is stopped or hung on a datastore disk that does not answer, or the metric server is off |
| `PBSHealthMetricsMissing`    | warning  | the host still reports but the health timer has not pushed for 20 minutes (for 5). Quiet when the host is down, which `PBSMetricsMissing` covers.                                        |
| `PBSHealthSourceFailing`     | warning  | the timer could not read `services`, `datastores`, `groups`, `tasks` or a job list from the PBS API for 10 minutes, for example after an upgrade changed the output                      |
| `PBSServiceDown`             | critical | `proxmox-backup` or `proxmox-backup-proxy` has been inactive for 5 minutes. Check `systemctl status` and `journalctl` for the unit on the PBS host.                                      |
| `PBSDatastoreUnavailable`    | critical | PBS cannot open a datastore for 5 minutes. Usually the datastore disk is not mounted or does not answer (see [Storage](../../../resources/pbs/README.md#storage)).                       |
| `PBSDatastoreMetricsMissing` | warning  | a datastore that reported in the last day has had no usage sample for 15 minutes (for 10) while the host still reports: maintenance mode, or unmounted                                   |
| `PBSDatastoreUsageHigh`      | warning  | a datastore is between 80% and 90% full for 30 minutes                                                                                                                                   |
| `PBSDatastoreAlmostFull`     | critical | a datastore is over 90% full for 15 minutes                                                                                                                                              |
| `PBSDatastoreFillingUp`      | warning  | a datastore is over 70% full and the 7 day trend of its free space reaches zero within 14 days (for 1 hour)                                                                              |
| `PBSBackupFailed`            | warning  | the newest backup task of a guest ended with an error, for 5 minutes. It clears when the next backup of that guest succeeds.                                                             |
| `PBSBackupStale`             | warning  | the last good backup of a guest is more than 1.5 times its usual interval old (a daily guest: 36 hours), for 15 minutes                                                                  |
| `PBSBackupVeryStale`         | critical | the last good backup of a guest is more than 3 times its usual interval old                                                                                                              |
| `PBSVerifyFailed`            | critical | the last run of a verify job failed, which usually means corrupt or missing chunks                                                                                                       |
| `PBSPruneFailed`             | warning  | the last run of a prune job failed                                                                                                                                                       |
| `PBSGarbageCollectionFailed` | warning  | the last garbage collection of a datastore failed                                                                                                                                        |

- **The schedule is read from the backups.** The backup job lives in Proxmox VE, so PBS does not know it. The timer takes the median gap between a guest's newest snapshots as its usual interval, so a weekly guest is not treated as a late daily one. A guest with fewer than three snapshots is assumed to be daily. A guest retired on purpose keeps alerting until its backup group is forgotten in the PBS UI.
- **Job failures stay until the next run.** The verify and garbage collection jobs run weekly, so a failed one alerts until the job is fixed and run again by hand from the PBS UI.
- **Gaps and resolving.** The timer pushes every 5 minutes and a push can be missed, so no rule reads a bare selector for a current value or for presence. Current values go through `last_over_time` over 5 minutes (PBS's own series) or 15 minutes (the timer's), and presence through `absent_over_time`. The values are the latest sample, so an alert resolves on the next push after the state changes.
- **The usage rules use the datastore's file system.** The `nas` datastore is an NFS mount, so its total, used and free are those of the NAS volume it sits on.
- **Unit tests.** `resources/pbs/tests/pbs-rules.test.yaml` runs the rules through `vmalert-tool` (`resources/pbs/scripts/test-rules.sh`, or `yarn nx test pbs`; needs Docker and `yq`). It covers a healthy host that fires nothing, each failure, a gap between pushes, recovery, and the exact push text. The script has its own tests in `resources/pbs/tests/test_pbs_health.py`.

## Gaming PC

The gaming PC (`apps/gaming-pc`, see its [README](../../../apps/gaming-pc/README.md#metrics-and-sensors)) is scraped by vmagent as the `gaming-pc` job: `windows_exporter` for the RTX 5090's temperature, fan and power and the frame rate, and OhmGraphite for the Ryzen 9 9950X3D's temperature. The `Gaming PC` dashboard in Grafana shows both. The rules are the `gaming-pc` VMRule in `deployments/production/alerting/gaming-pc-vmrules.yaml`, in the production overlay only because staging has no gaming PC.

| Rule                             | Severity | Fires when                                                                                                                         |
| -------------------------------- | -------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `GamingPCGpuTemperatureHigh`     | warning  | the GPU is at 85 °C or more for 5 minutes. NVIDIA rates the RTX 5090 for 90 °C and gaming sits at about 80 °C.                     |
| `GamingPCGpuTemperatureCritical` | critical | the GPU is at 90 °C or more, its rated maximum, for 2 minutes                                                                      |
| `GamingPCGpuFanStopped`          | critical | the GPU fan reads 0 RPM while the GPU is above 70 °C, for 3 minutes. Fan stop at idle is normal and does not alert.                |
| `GamingPCCpuTemperatureHigh`     | warning  | the hottest CPU temperature sensor is at 85 °C or more for 10 minutes. The 9950X3D is specified for 95 °C and boosts into the 80s. |
| `GamingPCCpuTemperatureCritical` | critical | the hottest CPU temperature sensor is at 90 °C or more for 5 minutes                                                               |

- **The push names the game.** Each `summary` ends with `while playing <game>` when the FPS summary reports one, because the question is what was running when it got hot. The text reads the active application at the moment the alert fires (a `query` template), so the alert's labels do not change when the game does.
- **The PC being off is not an alert.** It is off or asleep for much of the day, so there is no "PC down" or "metrics missing" rule, the rules above only see data while it is on, and `TargetDown` skips the `gaming-pc` job.
- **The thresholds are sustained on purpose.** Both CPU rules and the GPU warning wait several minutes, so a boost spike or a shader compile does not push the phone.
- **What the GPU sensor cannot see.** NVIDIA does not expose the hotspot on Blackwell, and a standard RTX 5090 has no sensor on its 12V-2x6 power connector, which can run hotter than the core. These rules protect the core and the fans.
- **Unit tests.** `apps/gaming-pc/tests/gaming-pc-rules.test.yaml` runs the rules through `vmalert-tool` (`apps/gaming-pc/scripts/test.sh`, or `yarn nx test gaming-pc`; needs Docker and `yq`). It covers a sustained warning and critical, a spike that stays quiet, the game name appearing and disappearing, fan stop while cool and while hot, the CPU thresholds and an off PC firing nothing.

## Alerts in Grafana

Rules stay in git (`VMRule` objects, tested with `vmalert-tool`) and vmalert and Alertmanager keep doing the
work. Grafana's Alerting menu is a read-only window onto them, on `https://grafana.smith-simms.family`:

- **Alert rules** (Alerting > Alert rules, "Data source-managed" section) lists every vmalert rule with its
  state: firing, pending (the `for:` timer is running) or normal. Open a rule for its query and graph, its
  instances (labels and when it became active) and its `summary` and `description`. It is read-only: rules
  are edited in git. It works through the `victoriametrics` data source (`type: prometheus`, `manageAlerts`
  on): Grafana asks VMSingle for `/api/v1/rules`, and VMSingle forwards it to vmalert because of
  `vmalert.proxyURL` in `deployments/base/metrics/vmsingle.yaml`. Without that flag VMSingle answers with an
  empty list and the page looks empty, with no error.
  - A group's name in the list is the path of the rule file the operator generated, followed by the group name.
  - Watchdog always fires and counts as firing. Hide it with the search `label:severity!=none`.
  - Do not create rules with "New alert rule" or "New recording rule" on that page. They would be Grafana-managed
    rules, which are not used here and send no notifications (`handleGrafanaManagedAlerts: false`).
  - Keep the data source `type: prometheus`. Grafana only reads rules from `prometheus` and `loki` data sources,
    not from the VictoriaMetrics plugin type.
- **Alert groups** and **Silences** (the `alertmanager` data source in
  `deployments/base/grafana/helm-release.yaml`) show what is firing now, with the full summary, description,
  labels and start time, and the silences. A silence can be created or expired here and goes to Alertmanager.
  Contact points, notification policies and templates are read-only, they are in `vmalertmanager.yaml`.
  Alert groups is what the push opens.
- **See source** on an alert in Alert groups opens Grafana Explore on the `victoriametrics` data source with the
  rule's expression, over a range that starts an hour before the alert became active. vmalert builds the link
  from `external.url` and `external.alert.source` in `vmalert.yaml`. The Explore link names the data source
  (`victoriametrics`), so keep that name stable too, like the `alertmanager` name below.

### Alert history

Grafana's own alert state history only records Grafana-managed rules, so it shows nothing for vmalert rules.
What fired in the past stays on the `Alert history` dashboard at
`https://grafana.smith-simms.family/d/alert-history`:

- **Alert history** (`deployments/base/grafana/dashboards/alert-history.json`) shows what fired over a time
  range. vmalert writes alert state to VictoriaMetrics as the `ALERTS` and `ALERTS_FOR_STATE` series. They
  carry labels only (plus an `alertgroup` label), so the dashboard has no summary or description: the alert
  names in its table link to Alert groups filtered to that alert, and the dashboard links back to the list.
  Watchdog is left out.
  - The state timeline is `ALERTS{alertstate="firing"}` per alert name and severity.
  - The table has one row per alert label set. First fired and Last firing are `tfirst_over_time` and
    `tlast_over_time` of the firing series, so a row that fired twice spans the gap between. Time firing is
    `duration_over_time` with a 2 minute gap limit, so it adds up only the time the alert was firing.
  - Firings counts how many times an alert started firing. `ALERTS_FOR_STATE` holds the time the alert became
    active, which is a new value for every firing, so the count is `distinct_over_time` of it, kept to the
    series that are firing. The bar gauge sums the same count by alert name.
  - History goes back as far as the VictoriaMetrics retention (two years).

## One-time setup

### 1. Put the two receiver URLs in 1Password and seal them

No receiver values are committed. Alertmanager mounts the `alertmanager-receivers` secret, which does not
exist until you seal and commit it, so its pod waits (`ContainerCreating`) until you do. Until then only
`alerting` is not Ready; `metrics` and `grafana` are unaffected. `alerting` turns Ready once the sealed
`alertmanager-receivers` file is committed. This uses the same path as the other app secrets (for example `grafana-admin`): the names are
registered in `packages/configuration-1password`, the values live in 1Password, and the `seal` generator
writes the SealedSecrets.

1. Pick a long random webhook id (for example `openssl rand -hex 24`) and take the ping URL from the
   Healthchecks.io check (step 3).
2. Scaffold the 1Password item (safe to re-run, existing values are never overwritten):

   ```sh
   export OP_VAULT=home-ops
   yarn nx g @ha/secrets:1password
   ```

3. Fill in the two fields of the item `alertmanager-receivers`:

   ```sh
   op item edit alertmanager-receivers --vault "$OP_VAULT" \
     'home-assistant-webhook-url=http://home-assistant.default.svc.cluster.local:8123/api/webhook/<webhook id>' \
     'healthchecks-ping-url=https://hc-ping.com/<check uuid>'
   ```

4. Seal for each environment and commit the result. The generator rewrites every sealed secret and the
   `kustomization.yaml` in `infrastructure/<env>/secrets`, so expect all of those files to change:

   ```sh
   yarn nx g @ha/secrets:seal production
   yarn nx g @ha/secrets:seal staging
   ```

### 2. Home Assistant

Everyone who should be alerted needs the phone app with notifications allowed. Alerts go through the
Home Assistant script `script.notify_via_control4`, which sends the phone notification to the family
members. It is the single place that decides which app delivers the push: today the Home Assistant iPhone
app, and at the Control4 cutover only this script changes to the Control4 mobile app. The automation
below does not change. No notify group is needed.

Add this automation (UI: Settings, Automations, Create, Edit in YAML). Replace `<webhook id>` with the id
from step 1. Alertmanager reaches Home Assistant through the in-cluster service, so `local_only` can stay on.

If the automation already exists, edit it instead of pasting it again. A second paste creates a duplicate
id, and Home Assistant silently ignores it (`ID alertmanager_push already exists`), so your change never runs.

```yaml
alias: Alertmanager push
id: alertmanager_push
mode: queued
max: 10
triggers:
  - trigger: webhook
    webhook_id: <webhook id>
    allowed_methods: [POST]
    local_only: true
variables:
  grafana: https://grafana.smith-simms.family
  severity: "{{ trigger.json.commonLabels.severity | default('warning') }}"
  firing: "{{ trigger.json.alerts | selectattr('status', 'eq', 'firing') | list }}"
  resolved: "{{ trigger.json.alerts | selectattr('status', 'eq', 'resolved') | list }}"
  alerts: "{{ firing + resolved }}"
  names: "{{ alerts | map(attribute='labels.alertname') | unique | list }}"
  title: >-
    {%- if firing | count > 0 -%}
    {{ severity | upper }}: {{ firing[0].annotations.summary }}{% if firing | count > 1 %} (+{{ firing | count - 1 }} more){% endif %}
    {%- else -%}
    ✅ Resolved: {{ resolved[0].annotations.summary }}{% if resolved | count > 1 %} (+{{ resolved | count - 1 }} more){% endif %}
    {%- endif -%}
  message: |-
    {% for a in firing -%}
    • {{ a.annotations.summary }}
    {% endfor -%}
    {% for a in resolved -%}
    ✅ Resolved: {{ a.annotations.summary }}
    {% endfor -%}
  details: >-
    {{ grafana }}/alerting/groups?alertmanager=alertmanager{% if names | count == 1 %}&queryString={{ ('alertname="' ~ names[0] ~ '"') | urlencode }}{% endif %}
  dashboard: >-
    {{ alerts | map(attribute='annotations.dashboard_url') | reject('undefined') | select | first | default('') }}
  buttons: >-
    {{ [{'action': 'URI', 'title': 'Details', 'uri': details}] + ([{'action': 'URI', 'title': 'Dashboard', 'uri': dashboard}] if dashboard else []) }}
actions:
  - action: script.notify_via_control4
    data:
      recipients: [andrew, dorri]
      title: "{{ title }}"
      message: "{{ message }}"
      critical: "{{ severity == 'critical' and firing | count > 0 }}"
      url: "{{ details }}"
      actions: "{{ buttons }}"
      tag: alertmanager-{{ severity }}
      thread: alertmanager
```

The push is kept short on purpose (iOS shows about four lines collapsed), and the detail is one tap away:

- **Title and body.** The title names what is wrong (`CRITICAL: <first summary> (+2 more)`). The body is one
  `summary` line per alert. No descriptions or start times.
- **Tap.** Opens Grafana, Alerting, Alert groups, on the `alertmanager` data source (the in-cluster
  VMAlertmanager, provisioned in `deployments/base/grafana/helm-release.yaml`). That page lists every firing
  alert with its full summary, description, labels and start time. When all alerts in the push share one
  `alertname`, the link filters to it (`queryString=alertname="<name>"`, URL-encoded by the template).
  Otherwise it is the unfiltered list. The `alertmanager` parameter is the data source name, not its uid, so
  do not rename the data source.
- **Buttons.** `Details` opens the same alert groups page. `Dashboard` opens the first alert's `dashboard_url`
  and is left out when no alert has one.

`script.notify_via_control4` documents `actions` as a list of `{action, title}`. The companion app opens a
link from a button only when the action is `URI` and carries a `uri`, so the script must pass `uri`
through, along with `action` and `title`, unchanged to the notify call. The automation sends:

```yaml
actions:
  - action: URI
    title: Details
    uri: https://grafana.smith-simms.family/alerting/groups?alertmanager=alertmanager&queryString=alertname%3D%22KubePodCrashLooping%22
  - action: URI
    title: Dashboard
    uri: https://grafana.smith-simms.family/dashboards?query=Kubernetes
```

and the script must hand them to the phone notification as `data.actions`, next to `data.url` (the tap
target, from the script's `url` field):

```yaml
action: notify.mobile_app_<phone>
data:
  title: "{{ title }}"
  message: "{{ message }}"
  data:
    url: "{{ url }}"
    actions: "{{ actions }}"
```

If the script drops the `uri` key, the buttons show but do nothing. The script lives in Home Assistant, not
in this repo, so check that it passes `uri` before relying on the buttons.

### 3. Healthchecks.io (one check)

Create one check named `home-ops monitoring stack`:

- Period: 5 minutes. Grace time: 5 minutes. (The Watchdog is resent about every 5 minutes, see
  `repeat_interval` in `vmalertmanager.yaml`. Change them together.)
- Integrations: email, plus any free SMS integration Healthchecks.io offers on your plan.
- Copy the ping URL into `healthchecks-ping-url` in step 1.

At most a few more checks (for example backup jobs that ping on success) are expected.

## Verify end to end

1. After Flux applies, the `vmalert`, `vmalertmanager` and `vmrules` objects should be ready:
   `kubectl get vmalert,vmalertmanager,vmrule -n default`.
2. Healthchecks.io: the check turns green within about 5 minutes of sealing the real ping URL. Proves
   vmalert, VMSingle, Alertmanager and the outbound path.
3. Push a test alert straight into Alertmanager (proves routing, the webhook and the automation):

   ```sh
   kubectl -n default port-forward svc/vmalertmanager-vmalertmanager 9093:9093 &
   curl -XPOST localhost:9093/api/v2/alerts -H 'Content-Type: application/json' -d '[{
     "labels": {"alertname": "TestAlert", "severity": "critical", "job": "manual"},
     "annotations": {"summary": "Test alert", "description": "Manual test alert, nothing is wrong."}
   }]'
   ```

   After the 30 second group wait, every recipient gets a critical push. It resolves by itself about
   5 minutes later and sends a resolved push. Use `severity: warning` to see the non-critical push.
   Tapping the push, or its `Details` button, opens Grafana's Alert groups page filtered to `TestAlert`
   with the full description. Add a `dashboard_url` annotation to see the `Dashboard` button.

4. Exporters and dashboards: `kubectl get pods -n default -l app.kubernetes.io/name=prometheus-node-exporter`
   and `-l app.kubernetes.io/name=kube-state-metrics` should be Running, the `node-exporter` and
   `kube-state-metrics` jobs should be up in the vmagent targets page, and each dashboard in the
   Kubernetes / Views set and Node Exporter Full should show data.

5. TrueNAS: `kubectl get vmrule truenas truenas-health -n default` should list both, and the `truenas-*` groups should list on the vmalert rules page with no errors. The `TrueNAS` dashboard in Grafana should show data in every panel, including the `Pool and disk health` row. A series that never arrives (a family the host does not report) leaves its panel empty.
6. TrueNAS health alerts, end to end, without touching the real pool. Push one sample of a made-up degraded pool into VictoriaMetrics (the `vmsingle` NodePort Service on 30080, the same door the health job uses, or a port-forward to the `vmsingle-vmsingle` Service on 8428):

   ```sh
   curl -X POST "http://<node address>:30080/api/v1/import/prometheus" \
     -d 'truenas_pool_state{pool="alert-test",state="DEGRADED"} 1'
   ```

   `TrueNASPoolNotOnline` shows as pending on the vmalert page, fires after 2 minutes, and everyone gets a critical push reading `TrueNAS pool alert-test is DEGRADED`. The sample goes stale by itself after about 5 minutes and a resolved push follows. The fake pool name matches no real pool, so nothing real is affected. Also check that the health job is alive: `truenas_health_push_timestamp_seconds` in Grafana Explore should be less than 2 minutes old.

7. Proxmox Backup Server: `kubectl get vmrule pbs -n default` should list it, and the `pbs-*` groups should list on the vmalert rules page with no errors. The `Proxmox Backup Server` dashboard should show data in every panel except the datastore throughput and IOPS panels, which stay empty for an NFS-backed datastore. End to end, without touching a real backup, push one sample of a made-up failed backup into VictoriaMetrics (the `vmsingle` NodePort Service on 30080):

   ```sh
   curl -X POST "http://<node address>:30080/api/v1/import/prometheus" \
     -d 'pbs_backup_last_task_ok{datastore="alert-test",backup_type="vm",backup_id="999"} 0'
   ```

   `PBSBackupFailed` shows as pending, fires after 5 minutes, and everyone gets a push reading `Proxmox Backup Server backup of vm/999 failed`. The sample goes stale by itself after about 15 minutes and a resolved push follows. Also check that the health timer is alive: `pbs_health_push_timestamp_seconds` in Grafana Explore should be less than 10 minutes old.

8. Failure path: stop the pings (for example seal a wrong `healthchecks-ping-url`); Healthchecks.io notifies you after the grace time.
9. Grafana sees the rules. Through a port-forward to `svc/vmsingle-vmsingle` (8428), `curl -s localhost:8428/api/v1/rules`
   should list the rule groups (an empty `groups` list means `vmalert.proxyURL` is missing or vmalert is down), and
   Alerting > Alert rules should show the "Data source-managed" groups with Watchdog firing. On Alert groups, "See
   source" on an alert opens Explore with the rule's expression.

## Known limits

- Single node cluster: if the node dies, vmalert dies with it. Only the Watchdog (Healthchecks.io) can
  report that, so a node outage arrives as the Healthchecks.io email or SMS rather than a push.
- Alertmanager keeps silences and notification history in memory. A restart forgets them, including silences
  created in Grafana.
- The Alert rules page and its source links depend on VMSingle (`vmalert.proxyURL`) and vmalert being up. If
  vmalert is down the page shows an error for the data source, while Alert groups keeps working.
- The alert source link uses the production Grafana URL (`external.url`), staging included, like the
  `dashboard_url` annotations in the rules.
- If Home Assistant is down, pushes fail (`AlertmanagerNotificationsFailing` is visible in Grafana).
  Healthchecks.io is independent of Home Assistant.
