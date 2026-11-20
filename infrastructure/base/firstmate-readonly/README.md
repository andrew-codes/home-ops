# Firstmate read-only cluster access

A ServiceAccount that lets Firstmate read cluster state and change nothing. Flux applies it through the `firstmate-readonly` Kustomization in [`clusters/production/infrastructure.yaml`](../../../clusters/production/infrastructure.yaml). Part of HO-333.

| Object | Purpose |
| --- | --- |
| ServiceAccount `firstmate-readonly` (default) | The identity Firstmate uses |
| ClusterRoleBinding `firstmate-readonly-view` | Binds the built-in `view` ClusterRole: reads namespaced objects and pod logs, no Secrets, no writes |
| ClusterRole and ClusterRoleBinding `firstmate-readonly-cluster-scoped` | `get`, `list` and `watch` on cluster-scoped objects `view` omits: nodes, namespaces, PVs, StorageClasses, webhook configurations, CRDs, ClusterRoles and bindings, cert-manager ClusterIssuers, Tailscale cluster resources |
| Secret `firstmate-readonly-token` | `kubernetes.io/service-account-token`. The cluster fills in the token, so no secret value is committed |

Flux and VictoriaMetrics CRDs are namespaced and already aggregated into `view` (Flux ships `flux-view-default`), so they need nothing extra. Never add Secrets, `pods/exec`, `pods/portforward`, write verbs, `impersonate` or wildcard resources to this role.

## After the PR merges

1. Wait for Flux to reconcile: `flux get kustomization firstmate-readonly`.
2. Read the token and the cluster CA:

   ```sh
   TOKEN=$(kubectl get secret firstmate-readonly-token -n default -o jsonpath='{.data.token}' | base64 -d)
   CA=$(kubectl get secret firstmate-readonly-token -n default -o jsonpath='{.data.ca\.crt}')
   ```

3. Build a kubeconfig that holds only that token (cluster `server` is your usual API server address):

   ```sh
   cat > firstmate-readonly.kubeconfig <<EOF
   apiVersion: v1
   kind: Config
   clusters:
     - name: home-ops
       cluster:
         server: <api-server-url>
         certificate-authority-data: $CA
   users:
     - name: firstmate-readonly
       user:
         token: $TOKEN
   contexts:
     - name: firstmate-readonly
       context: {cluster: home-ops, user: firstmate-readonly}
   current-context: firstmate-readonly
   EOF
   ```

4. Store the file contents in the 1Password item `k8s-firstmate-readonly`, field `kubeconfig`.
5. Delete the local copies, including the file and shell variables.
6. Check it: `kubectl get pods -A` works and `kubectl get secrets -A` is denied.

## Revoke

Delete the `firstmate-readonly-token` Secret to invalidate the token, or delete the `firstmate-readonly-view` and `firstmate-readonly-cluster-scoped` bindings to remove all access. Flux recreates them, so remove them from this directory in a PR to make it permanent.
