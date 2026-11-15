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
  built from them. `dashboard_url` is optional and becomes the tap target of the push.
- Alertmanager config is in `vmalertmanager.yaml`. It contains no secrets: the receiver URLs are read
  from the `alertmanager-receivers` secret (`url_file`).
- Alerts are grouped by severity, so one outage reads as one push listing everything affected. A
  `critical` push is an iOS critical alert (bypasses silent mode and Do Not Disturb). A resolved push is
  sent when the alerts clear.
- Per-machine and per-service checks are vmalert rules. They do not use Healthchecks.io checks. Only the
  Watchdog heartbeat does, so the 20 free checks are not a limit on how much is monitored.
- The Watchdog covers what in-cluster alerting cannot: if the cluster, the node, vmalert, VMSingle or the
  network path is down, the pings stop and Healthchecks.io notifies you directly.

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

Everyone who should be alerted needs the companion app with notifications allowed. Group their
`notify.mobile_app_*` services into one notify service in `configuration.yaml`, then restart or reload:

```yaml
notify:
  - name: alert_recipients
    platform: group
    services:
      - action: mobile_app_<person one phone>
      - action: mobile_app_<person two phone>
```

Add this automation (UI: Settings, Automations, Create, Edit in YAML). Replace `<webhook id>` with the id
from step 1. Alertmanager reaches Home Assistant through the in-cluster service, so `local_only` can stay on.

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
  severity: "{{ trigger.json.commonLabels.severity | default('warning') }}"
  firing: "{{ trigger.json.alerts | selectattr('status', 'eq', 'firing') | list }}"
  resolved: "{{ trigger.json.alerts | selectattr('status', 'eq', 'resolved') | list }}"
  title: >-
    {%- if firing | count > 0 -%}
    {{ severity | upper }}: {{ firing[0].annotations.summary }}{% if firing | count > 1 %} (+{{ firing | count - 1 }} more){% endif %}
    {%- else -%}
    ✅ Resolved: {{ resolved[0].annotations.summary }}{% if resolved | count > 1 %} (+{{ resolved | count - 1 }} more){% endif %}
    {%- endif -%}
  message: |-
    {% for a in firing -%}
    • [{{ a.labels.alertname }}] {{ a.annotations.description }} Since {{ (a.startsAt | as_datetime | as_local).strftime('%H:%M') }}.
    {% endfor -%}
    {% for a in resolved -%}
    ✅ Resolved: {{ a.annotations.summary }}
    {% endfor -%}
  link: >-
    {{ (firing + resolved) | map(attribute='annotations.dashboard_url') | reject('undefined') | first | default('') }}
actions:
  - choose:
      - conditions:
          - "{{ severity == 'critical' and firing | count > 0 }}"
        sequence:
          - action: notify.alert_recipients
            data:
              title: "{{ title }}"
              message: "{{ message }}"
              data:
                tag: alertmanager-{{ severity }}
                group: alertmanager
                url: "{{ link }}"
                push:
                  sound:
                    name: default
                    critical: 1
                    volume: 1.0
    default:
      - action: notify.alert_recipients
        data:
          title: "{{ title }}"
          message: "{{ message }}"
          data:
            tag: alertmanager-{{ severity }}
            group: alertmanager
            url: "{{ link }}"
```

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

4. Failure path: stop the pings (for example seal a wrong `healthchecks-ping-url`); Healthchecks.io notifies you after the grace time.

## Known limits

- Single node cluster: if the node dies, vmalert dies with it. Only the Watchdog (Healthchecks.io) can
  report that, so a node outage arrives as the Healthchecks.io email or SMS rather than a push.
- Alertmanager keeps silences and notification history in memory. A restart forgets them.
- If Home Assistant is down, pushes fail (`AlertmanagerNotificationsFailing` is visible in Grafana).
  Healthchecks.io is independent of Home Assistant.
