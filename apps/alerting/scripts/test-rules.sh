#!/usr/bin/env bash
# Runs the vmalert-tool unit tests for the incident related rules in
# deployments/base/alerting/vmrules.yaml. The rules live in VMRule objects, which
# vmalert-tool cannot read, so the rule groups are extracted into a plain rules
# file first. Needs docker.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
vmrules="$root/../../deployments/base/alerting/vmrules.yaml"
# Keep in step with the VictoriaMetrics version in deployments/base/metrics/vmsingle.yaml.
image="victoriametrics/vmalert-tool:v1.156.0"
# yq runs in docker too, so a developer machine and CI read the YAML the same way.
yq_image="mikefarah/yq:4.54.3"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# vmrules.yaml holds several VMRule documents. Merge all their groups.
docker run --rm -i "$yq_image" ea '{"groups": [select(.kind == "VMRule") | .spec.groups[]]}' <"$vmrules" >"$work/base-rules.yaml"
cp "$root/tests/base-rules.test.yaml" "$work/"

docker run --rm -v "$work:/work:ro" -w /work "$image" \
  unittest --disableAlertgroupLabel --files=/work/base-rules.test.yaml
