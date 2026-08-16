# resources/k8s

Provisions and manages the `k8s-main` node (currently the cluster's only node - both
control plane and the sole worker, with GPU passthrough).

## Kubernetes version

Pinned in one place: `src/deployment/vars/kube-version.yml` (`kube_version` exact patch,
`kube_minor` apt channel line). Both `prepare.yml` (fresh install) and `upgrade-k8s.yml`
(in-place upgrade) source this file - never hardcode a version elsewhere.

## Deploy paths

Two distinct, separately invokable nx targets exist. Do not conflate them:

- `nx run resource-k8s:deploy` (`scripts/deploy.ts` -> `src/deployment/deploy.yml`) - the
  **fresh** path. Resets any prior kubeadm/CNI/kubelet state first (imports
  `playbooks/reset-k8s.yml`), then provisions/inits a clean cluster. Safe to (re-)run
  against a brand-new node or one being intentionally rebuilt. `nx run resource-k8s:provision`
  runs this after Terraform-provisioning the VM.
- `nx run resource-k8s:deploy:upgrade` (`scripts/deploy-upgrade.ts` ->
  `src/deployment/deploy-upgrade.yml` -> `playbooks/upgrade-k8s.yml`) - the **upgrade in
  place** path. Never calls `kubeadm reset`. Installs the pinned kubeadm/kubelet/kubectl
  versions and drives kubeadm's own documented per-node upgrade sequence (`kubeadm upgrade
  plan` / `apply`, cordon, drain, restart kubelet, uncordon). This is the path to run when
  bumping `kube_version` on the live cluster - never `deploy`/`provision`.
- `nx run resource-k8s:reset` (`scripts/reset.ts` -> `playbooks/reset-k8s.yml`) - standalone
  teardown of kubeadm/CNI/kubelet state without reprovisioning, for manual decommissioning.

Kubernetes only supports upgrading one minor version at a time (kubeadm enforces this) - if
the pinned `kube_version` needs to move more than one minor ahead, that requires repeated
`deploy:upgrade` runs, one minor version per run, updating `kube-version.yml` between each.

## Pending multi-hop upgrade (captain-approved plan, as of 2026-08-16)

Currently pinned: 1.32.13 (last patch on the EOL 1.32 line). Latest stable: 1.36.3. Captain
approved a separate PR per hop rather than one bundled jump. Each hop is its own future
task/PR (not part of this one), in order, re-running the manifest/add-on compatibility audit
before each:

1. 1.32.13 -> 1.33.10
2. 1.33.10 -> 1.34.6
3. 1.34.6 -> 1.35.3
4. 1.35.3 -> 1.36.3

At the final hop (1.36.3), also bump Flannel v0.26.4 -> v0.28.x and the NVIDIA device plugin
v0.16.2 -> v0.17.1 (both compatible with every intermediate line, so no rush to move them
earlier). Confirm each target's exact latest patch again at hop time - these drift.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
