#!/bin/sh
# Unit-tests deployments/production/alerting/truenas-health-vmrules.yaml with
# vmalert-tool: it feeds the series in truenas-health.test.yaml to the rules and
# checks which alerts fire, with their labels and text. Needs docker and yq.
#
#   sh apps/truenas/src/health/rules/test-rules.sh
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../../../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# vmalert-tool reads plain rule groups, not the VMRule object that wraps them.
rules="$repo/deployments/production/alerting/truenas-health-vmrules.yaml"
if yq --version | grep -q mikefarah; then
  yq '.spec' "$rules" >"$work/rules.yaml"
else
  yq -y '.spec' "$rules" >"$work/rules.yaml"
fi
cp "$here/truenas-health.test.yaml" "$work/truenas-health.test.yaml"

# Pinned to the version of VictoriaMetrics that deployments/base/metrics runs.
docker run --rm -v "$work:/work" -w /work victoriametrics/vmalert-tool:v1.156.0 \
  unittest --disableAlertgroupLabel --files=/work/truenas-health.test.yaml
