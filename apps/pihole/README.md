# Pi-hole

Two Pi-hole v6 instances (`pihole/ip`, `pihole2/ip`, LXC containers on Proxmox) serve the household's DNS. Provisioning is
`nx run pihole:provision`, configuration `nx run pihole:deploy`, DNS records `nx run pihole:dns-records`.

## Observability

Everything lands in Grafana through the cluster's VictoriaMetrics and VictoriaLogs. The `Pi-hole` dashboard
(`deployments/base/grafana/dashboards/pihole.json`, uid `pihole`) shows both instances: whether each answers DNS, queries per
second, blocked share, query types, upstreams, top clients, host load and memory, and the FTL log.

```text
Pi-hole API  <-- pihole-exporter (in cluster) <-- vmagent job pihole-exporter --+
Pi-hole DNS  <-- blackbox exporter (in cluster) <-- vmagent job pihole-dns -----+--> VictoriaMetrics --> Grafana, vmalert
Pi-hole host: node_exporter :9100 <------------- vmagent job pihole-host -------+
Pi-hole host: pihole.log, FTL.log -- rsyslog imfile --> NodePort 30514 --> VictoriaLogs --> Grafana (Logs, Pi-hole)
```

Every series carries a `pihole` label (`pihole-1`, `pihole-2`), the same name the logs carry as `hostname`.

| Signal                                                                                    | Source                                                                               | Configured in                                                                                                               |
| ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------- |
| Queries, blocked share, query types, replies, upstreams, top clients, FTL blocking status | [pihole-exporter](https://github.com/eko/pihole-exporter) reading the Pi-hole v6 API | `deployments/base/pihole-monitoring/pihole-exporter.yaml`                                                                   |
| DNS answered (`probe_success`) and answer time (`probe_duration_seconds`)                 | blackbox exporter asking each Pi-hole for `example.com` from the cluster             | `deployments/base/pihole-monitoring/blackbox-exporter.yaml`                                                                 |
| Host load, memory, disk, network                                                          | `prometheus-node-exporter` on each Pi-hole host                                      | `src/observability/index.yml`                                                                                               |
| `pihole.log` (query log, app `pihole-dns`) and `FTL.log` (app `pihole-FTL`)               | rsyslog `imfile` on each Pi-hole host                                                | `src/observability/templates/pihole-logs-rsyslog.conf.j2`                                                                   |
| The hosts' OS logs                                                                        | rsyslog, see [Proxmox guests](../pve/README.md#proxmox-guests)                       | `apps/pve`                                                                                                                  |
| Scrape and probe jobs                                                                     | vmagent                                                                              | `deployments/production/metrics/pihole-scrape.yaml`                                                                         |
| Alerts                                                                                    | vmalert                                                                              | `deployments/production/alerting/pihole-vmrules.yaml`, [alerting README](../../deployments/base/alerting/README.md#pi-hole) |

The exporter keeps its last values when a Pi-hole stops answering its API, so "is it down" always comes from the DNS probe
and the host scrape, never from the exporter's own series. The exporter does not read host load or memory, which is why the
hosts run node_exporter.

`pihole.log` has one line per query, so it is the biggest log stream here (VictoriaLogs keeps 14 days, capped at 40 GiB, see
the [logs README](../../deployments/base/logs/README.md#retention-and-disk)). The log lines are forwarded through their own
rsyslog ruleset, so they do not also fill `/var/log/syslog` on the Pi-hole.

### One-time setup

1. **Seal the credentials** (the captain, signed in to 1Password). The exporter and the vmagent jobs read the `pihole`
   (`ip`, `password`) and `pihole2` (`ip`) secrets, from 1Password `pihole/ip`, `pihole/password` and `pihole2/ip`, which are
   in the sealed list of `packages/configuration-1password`:

   ```bash
   yarn nx g @ha/nx-secrets-generators:seal --env production
   ```

   This reseals every secret in the list. It writes `infrastructure/production/secrets/pihole-sealed.yaml` and
   `pihole2-sealed.yaml` and adds them to that directory's `kustomization.yaml`. Commit the two new files and the
   kustomization change. Both Pi-holes use the one web password, the same one `deploy.ts` sets.

2. **Deploy to the hosts.** `nx run pihole:deploy-observability` installs `prometheus-node-exporter` and the rsyslog
   forwarding of the two log files on both Pi-holes. It does not touch Pi-hole's configuration or need its password, and
   it is safe to run again. `nx run pihole:deploy` runs it as its last step. The Pi-hole hosts' OS logs need
   `nx run pve:deploy-guest-observability` to have run once, which sets the `pihole-1` and `pihole-2` host names the log
   files reuse.
3. **Restart vmagent** (delete its pod in the `default` namespace and let the Deployment recreate it)
   after the secrets exist. vmagent reads `PIHOLE_1_IP` and `PIHOLE_2_IP` from its environment at startup, and the secret
   references are optional, so a pod started before the secrets existed has no addresses and skips the Pi-hole targets.
4. **Check** the `pihole-exporter`, `pihole-host` and `pihole-dns` targets are `up` in the vmagent targets page, the
   `Pi-hole` dashboard fills, and `app_name:=pihole-FTL` returns lines in Explore on the `victorialogs` data source.

Port 9100 on each Pi-hole is open to the LAN (node_exporter's default). The Pi-hole API on port 80 is read with the
Pi-hole web password, which the exporter holds only in its pod environment.

### Tests

`nx test pihole` runs Jest for the DNS records and, through `scripts/test-rules.sh`, the `vmalert-tool` tests for the alert
rules in `tests/pihole-rules.test.yaml` (needs Docker). `nx lint pihole` checks every playbook's syntax.
