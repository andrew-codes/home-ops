#!/usr/bin/env bash
# Tests for the pieces of this app that run without the gaming PC: the PowerShell
# FPS summariser and the OhmGraphite config (need pwsh), and the vmalert-tool unit
# tests for the thermal alert rules (need docker and yq). All of them are on the
# pull request runners.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pwsh -NoProfile -File "$root/tests/fps-summary.test.ps1"
pwsh -NoProfile -File "$root/tests/ohmgraphite-config.test.ps1"

vmrule="$root/../../deployments/production/alerting/gaming-pc-vmrules.yaml"
# Keep in step with the VictoriaMetrics version in deployments/base/metrics/vmsingle.yaml.
image="victoriametrics/vmalert-tool:v1.156.0"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The rules live in a VMRule, which vmalert-tool cannot read, so the rule groups
# are extracted into a plain rules file first.
yq '{"groups": .spec.groups}' "$vmrule" >"$work/gaming-pc-rules.yaml"
cp "$root/tests/gaming-pc-rules.test.yaml" "$work/"

docker run --rm -v "$work:/work:ro" -w /work "$image" \
  unittest --disableAlertgroupLabel --files=/work/gaming-pc-rules.test.yaml
