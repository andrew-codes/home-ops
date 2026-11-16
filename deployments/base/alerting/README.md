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
is present but down is already caught by `TargetDown`.

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
| `TrueNASDiskMissing`                   | warning  | a disk that reported in the last day has not for 10 minutes (resolves by itself a day after it was last seen)     |
| `TrueNASDiskTemperatureMetricsMissing` | warning  | no disk temperature series for 15 minutes while the host still reports                                            |
| `TrueNASDiskStatsMetricsMissing`       | warning  | no disk busy, IOPS or throughput series for 15 minutes while the host still reports                               |
| `TrueNASNetworkLinkDown`               | warning  | a physical interface (name starting `en` or `eth`) has no carrier for 5 minutes after being up in the last 7 days |

- **Thresholds.** The disk temperatures are typical NAS hard disk limits: drives are rated to 60 to 65 °C, and sustained 50 °C or more shortens their life. NVMe and SSD drives run hotter, so if one lives in the NAS and trips the warning, raise the numbers or split the rule. The pool numbers follow the ZFS rule of thumb that performance drops past 80% full.
- **The pool is one series.** The exporter reports pool usage without a pool name, so the pool rules describe "the pool". Check them again if a second pool is added.
- **Unused ports.** `TrueNASNetworkLinkDown` ignores a port that was never up in the last 7 days, so a free port does not alert. A port that is unplugged for more than 7 days stops alerting.

**Health gap.** The exporter has no pool health, vdev state or SMART result, so none of these rules can see a degraded pool or a failing disk. The most maintainable cover is TrueNAS's own alert service, which already raises those alerts. See the `apps/truenas` README for the recommendation and why an in-cluster exporter would be the second step.

## Alert history

Two Grafana pages show what fired, both behind the push (Alerting > Alert groups, and the `Alert history`
dashboard at `https://grafana.smith-simms.family/d/alert-history`):

- **Alert groups** (the `alertmanager` data source in `deployments/base/grafana/helm-release.yaml`) shows what
  is firing now, with the full summary, description, labels and start time. It is what the push opens.
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

5. TrueNAS: `kubectl get vmrule truenas -n default` should exist and the `truenas-*` groups should list on the vmalert rules page with no errors. The `TrueNAS` dashboard in Grafana should show data in every panel. A series that never arrives (a family the host does not report) leaves its panel empty.
6. Failure path: stop the pings (for example seal a wrong `healthchecks-ping-url`); Healthchecks.io notifies you after the grace time.

## Known limits

- Single node cluster: if the node dies, vmalert dies with it. Only the Watchdog (Healthchecks.io) can
  report that, so a node outage arrives as the Healthchecks.io email or SMS rather than a push.
- Alertmanager keeps silences and notification history in memory. A restart forgets them.
- If Home Assistant is down, pushes fail (`AlertmanagerNotificationsFailing` is visible in Grafana).
  Healthchecks.io is independent of Home Assistant.
