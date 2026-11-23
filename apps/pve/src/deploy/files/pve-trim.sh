#!/usr/bin/env bash
# Trims every running LXC container of this Proxmox host and reports the result as
# Prometheus metrics. The containers' root file systems are thin volumes of the
# pve/data pool, so a trim here is what hands freed blocks back to the pool and from
# there to the NVMe drive. The host's own file systems are trimmed by the distro
# fstrim.timer, not by this script. It runs from a systemd timer that apps/pve
# installs (src/deploy/tasks/trim.yml).
#
#   pve-trim.sh print        trim the containers and write the metrics to stdout
#   pve-trim.sh push <url>   trim, then POST the metrics to a VictoriaMetrics
#                            /api/v1/import/prometheus URL
#
# A container that cannot be trimmed is reported on stderr and counted in
# pve_trim_containers_failed, and the run goes on with the next one. The
# pve_trim_last_success_timestamp_seconds series is written only by a run in which
# every container was trimmed, so its age is the time since the last clean run.
set -uo pipefail

# Seconds one `pct fstrim` may take: a container on a stalled drive must not hold
# up the others for ever.
CT_TIMEOUT="${PVE_TRIM_CT_TIMEOUT:-1800}"

mode="${1:-}"
case "$mode" in
print) [ "$#" -eq 1 ] || mode="" ;;
push) [ "$#" -eq 2 ] || mode="" ;;
*) mode="" ;;
esac
if [ -z "$mode" ]; then
  sed -n '2,/^set -/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit 2
fi

host="$(hostname)"
trimmed=0
failed=0

# `pct list` prints VMID, Status and Name; only running containers can be trimmed.
running="$(pct list | awk 'NR > 1 && $2 == "running" { print $1 }')" || {
  echo "pct list failed" >&2
  exit 1
}

for id in $running; do
  if timeout "$CT_TIMEOUT" pct fstrim "$id" >&2; then
    trimmed=$((trimmed + 1))
  else
    echo "pct fstrim $id failed" >&2
    failed=$((failed + 1))
  fi
done

now="$(date +%s)"
body="pve_trim_containers_trimmed{host=\"$host\"} $trimmed
pve_trim_containers_failed{host=\"$host\"} $failed
pve_trim_last_run_timestamp_seconds{host=\"$host\"} $now
"
if [ "$failed" -eq 0 ]; then
  body="${body}pve_trim_last_success_timestamp_seconds{host=\"$host\"} $now
"
fi

if [ "$mode" = "print" ]; then
  printf '%s' "$body"
else
  printf '%s' "$body" | curl --silent --show-error --fail --max-time 30 \
    --request POST --data-binary @- "$2" || {
    echo "push to $2 failed" >&2
    exit 1
  }
fi

[ "$failed" -eq 0 ]
