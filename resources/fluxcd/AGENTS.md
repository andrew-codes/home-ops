# resources/fluxcd

Bootstraps and self-manages Flux on the production cluster.

## How Flux is managed here

`nx run resource-fluxcd:provision` (`scripts/provision.ts`) runs
`flux bootstrap github --owner=andrew-codes --repository=home-ops --branch=main
--namespace=default --path=clusters/${env}` against the cluster in
`resources/k8s/._secrets/${env}/.kube/config`. There is no CI workflow that applies
Flux manifests - `flux bootstrap` writes `clusters/<env>/default/gotk-components.yaml`
(CRDs + controller Deployments in one file) and `gotk-sync.yaml` (the `GitRepository`/
`Kustomization` pair, both named `default`, in the `default` namespace - not
`flux-system`) back into the repo, and from then on Flux reconciles itself: the
`default` Kustomization applies `clusters/production` (including its own
`gotk-components.yaml`) on every sync.

`gotk-components.yaml` is regenerated wholesale by `flux bootstrap`/`flux install`,
never hand-edited. Each regeneration is one atomic commit (author `Flux <>`) that
replaces the whole file, so the CRDs and controller images it contains are always an
internally consistent set from a single upstream Flux release.

## Recovering a source-controller crash loop from CRD/controller drift

Symptom: `source-controller` crash-loops on `unable to start manager` /
`no matches for kind "OCIRepository" in version "...vX"` - the running controller
image expects an API version its installed CRD no longer serves (or vice versa).

Because `gotk-components.yaml` is only ever replaced atomically, this is not a bad
commit - `git log -- clusters/production/default/gotk-components.yaml` will show the
CRDs and controller images already match at the tip. The drift is a **live-cluster**
state that fell out of sync with git, most often because an apply of that file
(self-managed reconcile, or a manual `kubectl apply`/`flux bootstrap` rerun) was
interrupted partway through, applying the CRDs before the Deployments. Since a
crashed source-controller cannot fetch the repo to reconcile itself back to the
committed state, this is a deadlock GitOps cannot resolve on its own.

Fix: rerun `nx run resource-fluxcd:provision`. `flux bootstrap` applies CRDs and
controllers directly (not via the cluster's own broken reconciler) and is idempotent
- safe to rerun any time to force the live cluster back into lockstep with the
committed manifests. Confirm recovery with `flux get sources oci` and
`flux get kustomizations`.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
