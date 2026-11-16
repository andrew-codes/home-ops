#!/bin/sh
# Unit-tests deployments/production/alerting/pbs-vmrules.yaml with vmalert-tool:
# it feeds the series in tests/pbs-rules.test.yaml to the rules and checks which
# alerts fire, with their labels and text. Needs docker and yq.
#
#   sh resources/pbs/scripts/test-rules.sh
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# vmalert-tool reads plain rule groups, not the VMRule object that wraps them.
rules="$repo/deployments/production/alerting/pbs-vmrules.yaml"
if yq --version | grep -q mikefarah; then
  yq '.spec' "$rules" >"$work/rules.yaml"
else
  yq -y '.spec' "$rules" >"$work/rules.yaml"
fi
cp "$here/../tests/pbs-rules.test.yaml" "$work/pbs-rules.test.yaml"

# Pinned to the version of VictoriaMetrics that deployments/base/metrics runs.
docker run --rm -v "$work:/work" -w /work victoriametrics/vmalert-tool:v1.156.0 \
  unittest --disableAlertgroupLabel --files=/work/pbs-rules.test.yaml
