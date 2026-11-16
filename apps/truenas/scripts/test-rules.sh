#!/usr/bin/env bash
# Runs the vmalert-tool unit tests for the TrueNAS alert rules. The rules live
# in a VMRule, which vmalert-tool cannot read, so the rule groups are extracted
# into a plain rules file first. Needs docker and yq.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
vmrule="$root/../../deployments/production/alerting/truenas-vmrules.yaml"
# Keep in step with the VictoriaMetrics version in deployments/base/metrics/vmsingle.yaml.
image="victoriametrics/vmalert-tool:v1.156.0"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

yq '{"groups": .spec.groups}' "$vmrule" >"$work/truenas-rules.yaml"
cp "$root/tests/truenas-rules.test.yaml" "$work/"

docker run --rm -v "$work:/work:ro" -w /work "$image" \
  unittest --disableAlertgroupLabel --files=/work/truenas-rules.test.yaml
