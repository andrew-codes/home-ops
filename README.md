# Home Ops

This mono-repo consists of all the applications and services used in my home lab and automation of my home. Some features of this repo include:

- automated provisioning and deployment of services on Proxmox and K8s cluster
- select services from k8s cluster are exposed and accessible via the Internet; secured by Cloudflare tunnel
- service configuration and secrets are managed by a 1Password vault
- centralized logging, metrics, and monitoring

See the [documentation site](https://docs.smith-simms.family) for more details or review the [docs files](./docs/index.mdx)
