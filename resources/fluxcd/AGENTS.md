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

## The real GitOps install lives in namespace `default`, not `flux-system`

This cluster also carries an orphaned, unmanaged Flux install in the conventional
`flux-system` namespace (a separate `source-controller`, `GitRepository`, and
`Kustomization` named `flux-system`, pointed at this repo over HTTPS with a stale
PAT). It predates this repo's switch to `--namespace=default` and nothing here
references it - every `sourceRef`/`Kustomization` in `clusters/`, `apps.yaml`,
`infrastructure.yaml`, and `image-automation.yaml` points at the `default`
GitRepository/Kustomization in the `default` namespace. `flux` CLI commands run
without `-n default` default to `flux-system` and will inspect this dead install,
not the real one - always pass `-n default` (or `--all-namespaces`) when diagnosing
this cluster.

### Decommissioning `flux-system` (operator-approved, run manually against the live cluster)

Before deleting, confirm the namespace holds nothing but the orphaned Flux install:

```bash
kubectl get all -n flux-system -o wide
kubectl get pvc,pv -n flux-system
kubectl get secrets,configmaps -n flux-system
kubectl get gitrepositories,ocirepositories,helmrepositories,helmcharts,buckets,helmreleases,kustomizations,imagerepositories,imagepolicies,imageupdateautomations -n flux-system
kubectl get sa,role,rolebinding -n flux-system
kubectl get clusterrolebinding -o json | jq -r '.items[] | select(.subjects[]? | .namespace=="flux-system") | .metadata.name'
```

Expect only Flux's own controllers/CRs/RBAC and nothing with real user data (no PVs
bound, no unrelated Secrets/ConfigMaps). The `default` install has its own
identically-shaped resources in its own namespace and its own `ClusterRoleBinding`
subjects, so removing `flux-system`'s namespaced resources and any
`ClusterRoleBinding`s that reference only `flux-system` service accounts is safe;
CRDs are cluster-scoped and shared with (still needed by) the `default` install, so
**never delete the `source.toolkit.fluxcd.io`/`kustomize.toolkit.fluxcd.io`/etc.
CRDs themselves**.

Then delete the namespace - this cascades to every namespaced object inside it
(Deployments, GitRepository/Kustomization/HelmRepository custom resources,
ServiceAccounts, Roles/RoleBindings, Secrets, ConfigMaps, Services):

```bash
kubectl delete namespace flux-system
```

Because the `flux-system` `source-controller`/`kustomize-controller` are crash
looping, they may never process their own finalizers, which can leave the namespace
stuck in `Terminating`. If `kubectl get namespace flux-system` still shows
`Terminating` after a minute or two, clear finalizers on any Flux custom resources
still present and retry:

```bash
for kind in gitrepositories ocirepositories helmrepositories helmcharts buckets helmreleases kustomizations; do
  for name in $(kubectl get "$kind" -n flux-system -o name 2>/dev/null); do
    kubectl patch "$name" -n flux-system --type=merge -p '{"metadata":{"finalizers":[]}}'
  done
done
kubectl delete namespace flux-system --wait=true
```

Verify cleanup:

```bash
kubectl get namespace flux-system   # expect: NotFound
kubectl get pods -A | grep -i flux  # expect: only the default-namespace controllers
```

Any now-unused `ClusterRoleBinding`s whose only subject was a `flux-system` service
account are harmless to leave (they just reference a namespace/SA that no longer
exists) but can be deleted for tidiness once confirmed unused by the check above.

## Recovering a source-controller crash loop from CRD/controller drift

Symptom: `source-controller` crash-loops on `unable to start manager` /
`no matches for kind "OCIRepository" in version "...vX"` - the running controller
image expects an API version its installed CRD no longer serves (or vice versa).

Because `gotk-components.yaml` is only ever replaced atomically, this is not a bad
commit - `git log -- clusters/production/default/gotk-components.yaml` will show the
CRDs and controller images already match at the tip. First confirm which install is
actually affected (see above): a crash loop in `flux-system` is the orphaned install
and is not this repo's problem to fix via manifests. A crash loop in `default` would
be live-cluster state that fell out of sync with git, most often because an apply of
`gotk-components.yaml` (self-managed reconcile, or a manual `kubectl apply`/
`flux bootstrap` rerun) was interrupted partway through, applying the CRDs before the
Deployments. Since a crashed source-controller cannot fetch the repo to reconcile
itself back to the committed state, this is a deadlock GitOps cannot resolve on its
own.

Fix (for the `default` install only): rerun `nx run resource-fluxcd:provision`.
`flux bootstrap` applies CRDs and controllers directly (not via the cluster's own
broken reconciler) and is idempotent - safe to rerun any time to force the live
cluster back into lockstep with the committed manifests. Confirm recovery with
`flux get sources oci -n default` and `flux get kustomizations -n default`.

## Per-environment manifests must stay in lockstep with the CRD versions they bootstrap

`infrastructure/<env>/*` and `deployments/<env>/*` are hand-maintained, per-cluster
copies (not templated) - a Flux CRD/controller version bump via
`nx run resource-fluxcd:provision` does not update `apiVersion`s already committed
under `infrastructure/`/`deployments/`. When bumping the Flux release, grep for
stale `source.toolkit.fluxcd.io`/`helm.toolkit.fluxcd.io` versions across those
trees (compare against `spec.versions` in `gotk-components.yaml`) and cross-check
each `clusters/<env>/*.yaml` Kustomization `path:` still resolves - both have drifted
silently before (see `infrastructure/production/traffic-manager`, added back after
its Kustomization path pointed at a directory that never existed).

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
