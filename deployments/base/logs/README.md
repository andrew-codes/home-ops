# Logs

VictoriaLogs (`VLSingle`, `vlsingle.yaml`) is the one place the logs of the cluster, the Proxmox hosts, the
backup server, the NAS and the Linux guests go. Grafana reads it through the `victorialogs` data source
(`deployments/base/grafana/helm-release.yaml`), and the alert push links to it.

```text
Kubernetes pods   -> vlagent (DaemonSet) ----------------------+
Proxmox VE        -> rsyslog -+                                |
Proxmox Backup    -> rsyslog -+                                v
Proxmox guests    -> rsyslog -+-> NodePort 30514 -> VictoriaLogs (VLSingle) <- Grafana: Logs dashboard
TrueNAS           -> syslog  -+                                                  and the alert push Logs button
```

## What ships logs, and where it is configured

| Source                       | How                                                                                | Configured in                                                                   | Deploy                                            |
| ---------------------------- | ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- | ------------------------------------------------- |
| Kubernetes pods              | `vlagent` DaemonSet reads the node's container log files and adds the pod metadata | `vlagent.yaml` (this directory)                                                 | Flux, the `logs` Kustomization                    |
| Proxmox VE hosts             | rsyslog forwards everything over TCP as RFC 5424                                   | [`apps/pve`](../../../apps/pve/README.md#8-observability-tasksobservabilityyml) | `nx run pve:deploy` or `pve:deploy-observability` |
| Proxmox Backup Server        | the same rsyslog forwarding                                                        | [`resources/pbs`](../../../resources/pbs/README.md)                             | `nx run pbs:deploy`                               |
| TrueNAS                      | the NAS's own remote syslog server setting, set through `midclt`                   | [`apps/truenas`](../../../apps/truenas/README.md)                               | `nx run truenas:deploy`                           |
| LXC containers and Linux VMs | the same rsyslog forwarding as the Proxmox host                                    | [`apps/pve`](../../../apps/pve/README.md#proxmox-guests)                        | `nx run pve:deploy-guest-observability`           |
| Windows (the gaming PC)      | not shipped, see [Not shipped](#not-shipped)                                       |                                                                                 |                                                   |

The host, appliance and guest streams reach VictoriaLogs through the syslog listeners on port `5140`
(`vlsingle.yaml`), which the `victoria-logs-syslog-node-port` Service publishes on node port `30514` for both
TCP and UDP (`services.yaml`). Every sender targets the Kubernetes node (`k8s/ip`) on that port. Syslog
timestamps carry no time zone, so VictoriaLogs stamps each message with the time it receives it
(`syslog.useLocalTimestamp.*`).

## What a log line carries

| Source          | Fields                                                                                                                                                                                                     |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Syslog          | `hostname`, `app_name` (the program or service), `proc_id`, `level` (`emerg`, `alert`, `critical`, `error`, `warning`, `notice`, `info`, `debug`), `severity`, `facility_keyword`, `format`, `_msg`        |
| Kubernetes pods | `kubernetes.pod_namespace`, `kubernetes.pod_name`, `kubernetes.container_name`, `kubernetes.pod_node_name`, `kubernetes.pod_ip`, `kubernetes.pod_labels.*`, `output_stream` (`stdout` or `stderr`), `_msg` |

Pod logs have a `level` only when the application logs JSON that carries one. A pod's `output_stream` is
`stderr` for many informational lines too, so it is not a severity.

## Logs dashboard

The `Logs` dashboard in Grafana (`dashboards/logs.json`, uid `logs`) is the search and filter surface:

- **Filters.** Host, Source (the syslog program), Namespace, Pod, Container, Level and a Search box for a word
  in the message. All of them start on `All`. The pickers are built so the Grafana mobile app Gaugely can list
  their options (it cannot load the VictoriaLogs plugin's query variables, HO-332 follow-up). Namespace, Pod and
  Container are Prometheus `label_values` variables on `kube_pod_info` and `kube_pod_container_info`, so they
  discover from metrics. Host, Source and Level have no metric that lines up with the log field (the metric
  `hostname` and `instance` labels name other things than the syslog hostnames, and no metric carries the syslog
  program or level), so they are fixed `custom` lists taken from the values seen in VictoriaLogs. A host,
  program or level that is not in the list can still be found with Search or Explore, and the list needs a new
  entry when a new host appears. Every filter is an anchored regular expression in a raw string,
  ``field:~`^${var:regex}$` ``, and the variables use `.*` as their All value. Grafana escapes the selected
  values through `:regex` (so `(sd-pam)` is matched as that exact program name) and leaves the All value
  alone. `.*` matches any value, including no value, so with everything on `All` both syslog lines and pod
  lines show, picking a namespace narrows to pods and picking a host narrows to syslog. Choosing a level
  leaves out the lines that have none. Keep the backquotes: a double-quoted LogsQL string rejects the
  backslashes that `:regex` adds. Do not change the All value back to `*`: plain `field:*` only matches lines
  where the field is non-empty, and no line has both a `hostname` and a `kubernetes.*` field, so a client that
  puts the All value into the query as it is returns nothing. The Grafana mobile app Gaugely does exactly
  that (HO-332: it showed 0 log lines while the same dashboard worked in a browser). A client that does its
  own variable substitution must also support the `:regex` format. Checked on Grafana 12.3.1 and on 11.6.0
  (what the chart deployed before the 13.3.1 upgrade) against VictoriaLogs v1.54.0.
- **Panels.** Counts (lines, errors and worse, hosts, pods), volume by source and by level, the busiest
  hosts, programs and pods, and the matching lines newest first.
- **Search.** Use Explore on the `victorialogs` data source for anything the filters do not cover. Some
  LogsQL to start from: `hostname:=pbs level:in(error, critical)`, `kubernetes.pod_namespace:=default
output_stream:=stderr`, `app_name:=sshd "Failed password"`.

## Alerts point at the logs

The alert push has a `Logs` button that opens the Logs dashboard on the time frame of the alerts, from 15
minutes before the first one started until now (or until 5 minutes after the last one resolved). When every
alert in the push has the same `namespace`, `pod` or `unit` label, the dashboard is filtered to it (the `unit`
label is a systemd unit and maps to Source). The template is the Home Assistant automation in
[`deployments/base/alerting/README.md`](../alerting/README.md#2-home-assistant). No rule needed a new
annotation. The Grafana, VictoriaMetrics and Alertmanager side stays as it was.

## Retention and disk

Retention is 14 days and the data size is capped at 40 GiB (`vlsingle.yaml`). When the data exceeds the cap
VictoriaLogs drops the oldest per-day partitions and keeps ingesting, so storage cannot grow unbounded.
VictoriaLogs only goes read-only if the disk itself runs out of space. The 10 GiB of headroom between the cap
and the 50Gi volume guards against that, because usage is checked periodically and VictoriaLogs recommends at
least 20% free (see
[retention by disk space usage](https://docs.victoriametrics.com/victorialogs/#retention-by-disk-space-usage)).
Both are unchanged by pod log collection: a single node cluster's pod logs are small next to what the cap allows,
and logs compress well. Check `vl_data_size_bytes` for the `victoria-logs` job in Grafana Explore after a week.
If it is near the cap, shorten the retention, or leave a noisy namespace out with
`spec.k8sCollector.excludeFilter` in `vlagent.yaml`.

## vlagent memory and restarts

`vlagent` reads every container log file from the beginning on its first start on a node, then keeps its read
position in `/var/lib/vlagent-data/vlagent-kubernetes-checkpoints.json` on the node (a `hostPath` the operator
mounts). It writes that file about once a minute, so a container that dies in its first seconds never writes it
and starts over each time. That is what happened in HO-330: with the default of two sending queues per CPU core,
each buffering 8MiB blocks, and no `GOMEMLIMIT`, the first backlog read went past the old 256Mi limit and the
container was OOM killed on every start (`CrashLoopBackOff`, no endpoints, `TargetDown`).

`vlagent.yaml` now sets `remoteWriteSettings.queues: 2`, `GOMEMLIMIT=400MiB` and a 512Mi memory limit. Keep
`GOMEMLIMIT` at about 80% of the limit if you change either. Checked with vlagent v1.54.0 on a 512Mi limit and
2GB of container logs (200 files of 10MB): it reads everything, peaks near 310MiB, and after a `kill -9` it
resumes from the checkpoints instead of reading again.

vmagent scrapes VictoriaLogs and `vlagent` (jobs `victoria-logs` and `vlagent`), so the `TargetDown` rule
covers a log pipeline that stops.

## Verify end to end

1. After Flux applies: `kubectl get vlagent,vlsingle -n default` shows both ready, and
   `kubectl get daemonset vlagent-vlagent -n default` has a pod on every node.
   The `vlagent-vlagent` pods are `Running` with no restarts, `kubectl get endpoints vlagent-vlagent` lists
   them, and `kubectl describe pod` shows no `OOMKilled` in Last State.
2. In Grafana open the `Logs` dashboard. `Pods logging` is above zero, and picking a namespace lists its pods'
   lines.
3. A host or guest: run `logger -t smoke "hello from $(hostname)"` on it, then search
   `app_name:=smoke` in Explore.
4. An alert: send the test alert from the [alerting README](../alerting/README.md#verify-end-to-end) and tap
   `Logs` on the push.

## Not shipped

- **Windows hosts.** The gaming PC sends metrics (`apps/gaming-pc`) but not Windows event logs. A forwarder
  (for example Fluent Bit reading the System and Application channels and sending RFC 5424 syslog to the node
  port above) fits the pinned-download pattern in `apps/gaming-pc/src/monitoring.ps1`, but it installs a
  service on the machine used for gaming and cannot be run from here. Add it once the cost can be measured
  on the machine.
- **Guests that need a manual step** are in the [Proxmox guests](../../../apps/pve/README.md#proxmox-guests) table.
