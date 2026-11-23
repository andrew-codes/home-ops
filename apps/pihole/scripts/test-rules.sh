#!/usr/bin/env bash
# Runs the vmalert-tool unit tests for the Pi-hole alert rules. The rules live in
# a VMRule, which vmalert-tool cannot read, so the rule groups are extracted into
# a plain rules file first. Needs docker.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
vmrule="$root/../../deployments/production/alerting/pihole-vmrules.yaml"
# Keep in step with the VictoriaMetrics version in deployments/base/metrics/vmsingle.yaml.
image="victoriametrics/vmalert-tool:v1.156.0"
# yq runs in docker too, so a developer machine and CI read the YAML the same way.
yq_image="mikefarah/yq:4.54.3"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# mktemp -d is mode 0700; the container user must be able to read the mount.
chmod 755 "$work"

docker run --rm -i "$yq_image" '{"groups": .spec.groups}' <"$vmrule" >"$work/pihole-rules.yaml"
cp "$root/tests/pihole-rules.test.yaml" "$work/"

docker run --rm -v "$work:/work:ro" -w /work "$image" \
  unittest --disableAlertgroupLabel --files=/work/pihole-rules.test.yaml
