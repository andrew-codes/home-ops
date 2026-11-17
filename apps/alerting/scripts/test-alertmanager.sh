#!/usr/bin/env bash
# Tests the Alertmanager config in deployments/base/alerting/vmalertmanager.yaml
# with amtool: the config loads, every kind of alert goes to the right receivers,
# and the Jira work item (summary, labels, description) renders as intended.
# Needs docker.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
vmalertmanager="$root/../../deployments/base/alerting/vmalertmanager.yaml"
# Keep in step with the Alertmanager version the VictoriaMetrics operator deploys
# (VM_VMALERTMANAGER_VERSION default in the vm-operator release). The Jira
# receiver needs v0.33 or newer.
image="prom/alertmanager:v0.34.1"
# yq runs in docker too, so a developer machine and CI read the YAML the same way
# whichever yq (or none) is installed. It reads standard input.
yq_image="mikefarah/yq:4.54.3"
yq() { docker run --rm -i "$yq_image" "$@"; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# mktemp -d is mode 0700; the container user must be able to read the mount.
chmod 755 "$work"
mkdir -p "$work/secrets"

yq -r '.spec.configRawYaml' <"$vmalertmanager" >"$work/alertmanager.yml"
# The receivers read these files at send time. Empty stand-ins are enough here.
for name in home-assistant-webhook-url healthchecks-ping-url jira-user jira-api-token; do
  printf 'x' >"$work/secrets/$name"
done
cp "$root/tests/jira-alert-data.json" "$work/"

amtool() {
  docker run --rm \
    -v "$work:/work:ro" \
    -v "$work/secrets:/etc/vm/secrets/alertmanager-receivers:ro" \
    --entrypoint amtool "$image" "$@"
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

echo "config loads"
amtool check-config /work/alertmanager.yml >/dev/null

# route <receivers it must reach> <alert labels...>
route() {
  local expected="$1"
  shift
  amtool config routes test --config.file=/work/alertmanager.yml --verify.receivers="$expected" "$@" >/dev/null ||
    fail "expected receivers [$expected] for: $*"
  echo "routes $* -> $expected"
}
route "jira-incidents,home-assistant" severity=critical alertname=KubeletDown
route "jira-incidents,home-assistant" severity=warning incident=true alertname=TargetDown
# Both critical and incident: still one work item, not two.
route "jira-incidents,home-assistant" severity=critical incident=true alertname=Both
route "home-assistant" severity=warning alertname=KubePodCrashLooping
route "healthchecks" severity=none alertname=Watchdog

# Render the Jira receiver's templates against a sample alert.
jira() { yq '.receivers[] | select(.name == "jira-incidents") | .jira_configs[0]' <"$work/alertmanager.yml"; }
render() {
  local expression="$1"
  amtool template render --template.glob=/dev/null --template.text="$(jira | yq -r "$expression")" \
    --template.data=/work/jira-alert-data.json
}
expect_contains() {
  local what="$1" haystack="$2" needle="$3"
  grep -qF -- "$needle" <<<"$haystack" || fail "$what does not contain: $needle
$haystack"
}

echo "jira summary"
summary="$(render '.summary.template')"
[[ "$summary" == "[TargetDown] hass is down" ]] || fail "summary was: $summary"

echo "jira priority"
priority="$(render '.priority')"
[[ "$priority" == "High" ]] || fail "priority was: $priority"

echo "jira labels"
for index in 0 1 2 3; do
  labels+="$(render ".labels[$index]")"$'\n'
done
expect_contains "labels" "$labels" "incident"
expect_contains "labels" "$labels" "TargetDown"
expect_contains "labels" "$labels" "alert-fp-60773b8b339d9395"

echo "jira description"
description="$(render '.description.template')"
expect_contains "description" "$description" "Scrape target hass is down."
expect_contains "description" "$description" "* *Alert:* TargetDown (warning)"
expect_contains "description" "$description" "* *Affected:* job hass instance hass.default.svc:8123"
expect_contains "description" "$description" "* *First seen:* 2026-11-17 13:49:11 UTC"
expect_contains "description" "$description" "[Grafana dashboard|https://grafana.smith-simms.family/dashboards?query=VictoriaMetrics]"
expect_contains "description" "$description" "https://grafana.smith-simms.family/explore?schemaVersion=1&panes="
expect_contains "description" "$description" "queryString=alertname%3D%22TargetDown%22"
expect_contains "description" "$description" "[Runbook|https://example.test/runbook]"
# The alert's own query link carries vmalert's generator URL, which holds raw JSON
# ({ } [ ] "). A bare ] ends the wiki link early and Jira shows the rest as text,
# so every one of those must come out percent-encoded, as one link.
query_link="$(grep -F "The alert's query in Grafana Explore" <<<"$description")"
[[ "$query_link" =~ ^\*\ \[The\ alert\'s\ query\ in\ Grafana\ Explore\|https://grafana\.smith-simms\.family/explore\?schemaVersion=1\&panes=[^][{}\"\|\ ]+\]$ ]] ||
  fail "the alert query link is not one well-formed wiki link: $query_link"
expect_contains "description" "$description" "panes=%7B%22p%22:%7B%22datasource%22:%22victoriametrics%22"
expect_contains "description" "$description" 'job="hass"'
# The log link opens VictoriaLogs from 15 minutes before first seen (13:34:11 UTC),
# with the query from the logs_query annotation.
expect_contains "description" "$description" "%22datasource%22%3A%22victorialogs%22"
expect_contains "description" "$description" "%22from%22%3A%221794922451000%22"
expect_contains "description" "$description" "%22expr%22%3A%22_stream%3A"

echo "alertmanager tests passed"
