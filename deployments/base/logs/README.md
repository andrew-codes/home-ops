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
  in the message. All of them start on `All`. A filter on a field a line does not have leaves the line in until
  a value is picked for that field, so picking a namespace narrows to pods and picking a host narrows to
  syslog. Choosing a level leaves out the lines that have none.
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

Retention is 14 days and the data size is capped at 40 GiB (`vlsingle.yaml`). When the cap is reached
VictoriaLogs stops accepting new logs (goes read-only) rather than filling the NFS volume. Both are
unchanged by pod log collection: a single node cluster's pod logs are small next to what the cap allows,
and logs compress well. Check `vl_data_size_bytes` for the `victoria-logs` job in Grafana Explore after a week.
If it is near the cap, shorten the retention, or leave a noisy namespace out with
`spec.k8sCollector.excludeFilter` in `vlagent.yaml`.

vmagent scrapes VictoriaLogs and `vlagent` (jobs `victoria-logs` and `vlagent`), so the `TargetDown` rule
covers a log pipeline that stops.

## Verify end to end

1. After Flux applies: `kubectl get vlagent,vlsingle -n default` shows both ready, and
   `kubectl get daemonset vlagent-vlagent -n default` has a pod on every node.
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
