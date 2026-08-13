# Home Ops

This mono-repo consists of all the applications and services used in my home lab and automation of my home. Some features of this repo include:

- automated provisioning and deployment of services on Proxmox and K8s cluster
- select services from k8s cluster are exposed and accessible via the Internet; secured by Cloudflare tunnel
- service configuration and secrets are managed by a 1Password vault
- centralized logging, metrics, and monitoring

## Deploy exclusions

`yarn deploy/all` fans a `deploy` out across every project except the ones named in the `--exclude` flag of the `deploy/all` script in [`package.json`](package.json). That flag is the authoritative list; nothing else in the repo repeats it.

Everything on it is a per-machine setup project - a laptop or desktop whose `deploy` configures one physical machine rather than a service. They are excluded as a class because:

- Setting a machine up is a deliberate, one-at-a-time action rather than a fleet deploy. These runs prompt: `darwin-rebuild switch`, `sudo`, `mas` and account creation all want an answer at the terminal.
- They only succeed on their own hardware with their own environment variables set, and exit non-zero anywhere else - which fails the whole fan-out.
- A machine that is off, asleep, or off the network fails the fan-out too, and personal machines are off far more often than servers are.

Keep the exclusion. JSON cannot carry a comment, which is why the reasoning is recorded here instead of beside the script. Each excluded project's own `README.md` says, under **Nx targets**, why that particular machine is on the list. Adding a fourth machine means extending the `--exclude` flag and writing that note in the new project's README - not editing this section.

## Documentation

Full project documentation lives on the [Home Ops docs site](https://docs.home.smith-simms.family/wiki/spaces/HA/overview).
