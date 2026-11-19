# Tailscale Kubernetes operator

The operator gives a Service or Ingress its own tailnet device, a MagicDNS name and a Tailscale-issued HTTPS certificate. Grafana is the first consumer: [`deployments/base/grafana/ingress.yaml`](../../../deployments/base/grafana/ingress.yaml) serves it at `https://grafana.<tailnet>.ts.net`, so the Grafana CLI (`gcx`) works from any tailnet machine without Cloudflare Access. The Cloudflare tunnel route for browsers is separate and unchanged. The Proxmox LXC in `apps/tailscale` (subnet router and exit node) is not involved.

Flux runs the operator through the `tailscale-operator` Kustomization in [`clusters/production/infrastructure.yaml`](../../../clusters/production/infrastructure.yaml), in the `tailscale` namespace. Until the OAuth secret below is sealed and committed, the operator pod cannot start and that Kustomization stays unready. Nothing else depends on it, and the Grafana Ingress does nothing without the operator.

## One-time setup

1. **Tailscale admin, DNS:** enable MagicDNS and HTTPS Certificates for the tailnet.
2. **Tailscale admin, access controls:** add the tag owners and an access rule.
   - `tagOwners`: `tag:k8s-operator` owned by `autogroup:admin`, and `tag:k8s` owned by `tag:k8s-operator`.
   - A grant or ACL that lets the users or devices that run agents reach `tag:k8s` on port 443.
3. **Tailscale admin, OAuth client:** create an OAuth client with the scopes the operator docs list (Devices Core, Auth Keys and Services, each Read and Write) and the tag `tag:k8s-operator`.
4. **1Password:** create the item `tailscale-operator-oauth` in the `home-ops` vault with the text fields `client-id` and `client-secret`. `OP_VAULT=home-ops yarn nx g @ha/secrets:1password` scaffolds the empty item. Fill in the client ID and secret.
5. **Seal and commit:**

   ```sh
   OP_VAULT=home-ops yarn nx g @ha/secrets:seal production
   ```

   This writes `infrastructure/production/tailscale-operator/tailscale-operator-oauth-sealed.yaml` and lists it in that directory's `kustomization.yaml`. The secret is sealed for the `tailscale` namespace and is applied by the `tailscale-operator` Kustomization, not by the shared `secrets` one, because the namespace does not exist before this Kustomization creates it.

6. **Merge and let Flux apply.** A device named `grafana` appears in the Tailscale admin.
7. **Grafana:** create a service account for CLI use (Viewer role for read-only) and add a token.
8. **Each machine that runs `gcx`:** join the tailnet, then point `gcx` at the tailnet URL and log in once so the token goes into the OS keychain:

   ```sh
   gcx config set stacks.home.grafana.server https://grafana.<tailnet>.ts.net
   gcx config set contexts.default.stack home
   gcx login
   ```

   Follow the installed `gcx` version's docs for the exact login flags. If the server URL changes, `gcx` clears the stored credential and needs a new login.

Tailnet policy is edited by hand in the Tailscale admin. It is not managed as code in this repo.
