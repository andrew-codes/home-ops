# Home Ops

This mono-repo consists of all the applications and services used in my home lab and automation of my home. Some features of this repo include:

- automated provisioning and deployment of services on Proxmox and K8s cluster
- the remodel site is the only service exposed to the Internet, through a Cloudflare tunnel; every other service is reachable on the tailnet only (see [Access model](#access-model))
- Grafana is also reachable on the tailnet through the [Tailscale Kubernetes operator](infrastructure/base/tailscale-operator/README.md), for CLI and agent use
- service configuration and secrets are managed by a 1Password vault
- centralized logging, metrics, and monitoring

## Access model

Only `remodel.smith-simms.family` goes through the Cloudflare tunnel (`infrastructure/production/cloudflared/config.yaml`). The tunnel's catch-all returns 404.

Everything else is tailnet-only:

- Pi-hole holds exact-name A records for `ha`, `grafana`, `zwave`, `ps`, `nas`, `synology` and `homebox` under `smith-simms.family` (`apps/pihole`, `yarn nx dns-records pihole`). They point at the `home-gateway` Tailscale address held in the 1Password item `home-gateway`, field `ip`.
- That address is the Tailscale operator proxy in front of the Traefik gateway (`infrastructure/production/gateway`), tagged `tag:home-gateway`. Traefik terminates TLS with a Let's Encrypt wildcard certificate for `*.smith-simms.family` and routes by host name.
- In the Tailscale admin console (not managed as code), `tag:home-gateway` needs a tag owner (`tag:k8s-operator`), and a grant must let the owner's users or devices reach `tag:home-gateway` on ports 443 and 80. Devices away from home also need split DNS for `smith-simms.family` to both Pi-holes.
- A device that is off the tailnet or does not use Pi-hole cannot reach these names. They no longer resolve in public DNS.

Break-glass, when the gateway, Tailscale or Pi-hole is down: reach the services directly from the LAN or through the subnet router.

| Service        | Direct address                                                  |
| -------------- | --------------------------------------------------------------- |
| Home Assistant | the Kubernetes node IP, port 8123 (it runs on the host network) |
| TrueNAS        | `http://10.5.90.74`                                             |
| Synology       | `http://10.5.113.53:5000`                                       |
| Proxmox        | `https://10.1.0.100:8006`                                       |

## Deploy exclusions

`yarn deploy/all` fans a `deploy` out across every project except the ones named in the `--exclude` flag of the `deploy/all` script in [`package.json`](package.json). That flag is the authoritative list; nothing else in the repo repeats it.

Everything on it is a per-machine setup project - a laptop or desktop whose `deploy` configures one physical machine rather than a service. They are excluded as a class because:

- Setting a machine up is a deliberate, one-at-a-time action rather than a fleet deploy. These runs prompt: `darwin-rebuild switch`, `sudo`, `mas` and account creation all want an answer at the terminal.
- They only succeed on their own hardware with their own environment variables set, and exit non-zero anywhere else - which fails the whole fan-out.
- A machine that is off, asleep, or off the network fails the fan-out too, and personal machines are off far more often than servers are.

Keep the exclusion. JSON cannot carry a comment, which is why the reasoning is recorded here instead of beside the script. Each excluded project's own `README.md` says, under **Nx targets**, why that particular machine is on the list. Adding a fourth machine means extending the `--exclude` flag and writing that note in the new project's README - not editing this section.

## Documentation

Full project documentation lives on the [Home Ops docs site](https://docs.home.smith-simms.family/wiki/spaces/HA/overview).
