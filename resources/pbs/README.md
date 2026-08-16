# pbs

Ansible-driven configuration for the captain's [Proxmox Backup Server](https://www.proxmox.com/en/proxmox-backup-server) host, run remotely over SSH. It is the backup target for the sibling `pve` Proxmox VE host: `pve` adds a PBS storage connection pointed at the datastore named `nas` this app creates here.

## Prerequisites - not automated

1. **The PBS ISO install itself.** Follow the [official Proxmox Backup Server installation docs](https://pbs.proxmox.com/docs/installation.html) to get a bare-metal or VM host booted into a fresh PBS install, reachable over SSH. Nothing here can do this step; it needs the installer console.
2. **Populate the 1Password items this app reads from**, before the first deploy - see [Configuration](#configuration).

**Hostname assumption.** If a hostname was not set during the ISO install, this app sets it to `pbs`. Confirm with the captain before running if `pbs` collides with anything already on the network.

## What it manages

| Concern                                                              | Where                                      |
| -------------------------------------------------------------------- | ------------------------------------------ |
| Timezone (`America/New_York`)                                        | [`scripts/deploy.yml`](scripts/deploy.yml) |
| DNS (`1.1.1.1`, `1.0.0.1`) and search domain (`smith-simms.family`)  | [`scripts/deploy.yml`](scripts/deploy.yml) |
| Hostname (`pbs`) and `/etc/hosts`                                    | [`scripts/deploy.yml`](scripts/deploy.yml) |
| Captain's SSH public key                                             | [`scripts/deploy.yml`](scripts/deploy.yml) |
| Static network (`10.0.209.71/24`, gateway `10.0.209.1`)              | [`scripts/deploy.yml`](scripts/deploy.yml) |
| Proxmox Backup Server package                                        | [`scripts/deploy.yml`](scripts/deploy.yml) |
| NFS-backed `nas` datastore, backup user, prune/verify jobs, firewall | [`scripts/deploy.yml`](scripts/deploy.yml) |

Everything is applied by one playbook, [`scripts/deploy.yml`](scripts/deploy.yml), run against the single host in [`scripts/deploy.ts`](scripts/deploy.ts)'s generated inventory.

## Deploying

```bash
OP_VAULT=<vault-name> nx run pbs:deploy
```

[`scripts/deploy.ts`](scripts/deploy.ts) reads `pbs/ip`, `pbs/username`, `pbs/password`, `nas/ip`, `pbs/backup-username` and `pbs/backup-password` through the repo's [1Password-backed configuration API](../../packages/configuration-1password), writes them into a gitignored `.secrets/` inventory and vars file next to the playbook, and runs `ansible-playbook` against them.

### The captain's SSH key is a special case

`pbs/*` above all come from `OP_VAULT`, the shared infra-secrets vault every other `configurationApi.get()` call in this repo reads from. The captain's own SSH key is different: it is a personal credential that lives in the **`Private`** 1Password vault as the `andrew-mbp` item, independent of whatever `OP_VAULT` is set to. [`scripts/deploy.ts`](scripts/deploy.ts) reads it directly with `op read "op://Private/andrew-mbp/public key"` rather than through `configurationApi`, and installs it as an `authorized_key` for the account the playbook connects as.

### Configuration

| Secret                               | 1Password location          | Populated?                           |
| ------------------------------------ | --------------------------- | ------------------------------------ |
| `pbs/ip`                             | infra vault (`OP_VAULT`)    | yes                                  |
| `pbs/username`                       | infra vault (`OP_VAULT`)    | yes                                  |
| `pbs/password`                       | infra vault (`OP_VAULT`)    | yes                                  |
| `nas/ip`                             | infra vault (`OP_VAULT`)    | yes                                  |
| `pbs/backup-username`                | infra vault (`OP_VAULT`)    | **captain must confirm/populate**    |
| `pbs/backup-password`                | infra vault (`OP_VAULT`)    | **captain must confirm/populate**    |
| `op://Private/andrew-mbp/public key` | `Private` vault, fixed item | yes (the captain's existing SSH key) |

`pbs/backup-username` and `pbs/backup-password` are the credentials the PBS-side backup user is created with and the ones any client (`pve`, or a manual `proxmox-backup-client`) authenticates as against the `nas` datastore. Confirm their values are real before relying on a deploy that creates that user.

No new secret names were added for this task - `pbs/*` and `nas/ip` already covered everything needed once the missing automation steps (network, hostname, SSH key, install) were added on top of the existing datastore/backup-user/job automation.

## Network change: risk and rollback

Changing the interface to a static `10.0.209.71/24` can drop the current SSH connection if the host was not already on that address (for example, still on the DHCP address the ISO installer picked). That is expected on a first run, not a failure:

- The playbook applies the change with `ifreload -a` (ifupdown2, installed by the PBS ISO by default) rather than restarting networking or rebooting, because `ifreload` diffs and only touches changed interfaces - the smallest blast radius the tooling supports.
- If the connection drops, reconnect the inventory at `10.0.209.71` and re-run `nx run pbs:deploy`. Every task in the playbook is idempotent, so already-applied steps (hostname, SSH key, timezone, DNS) are skipped and only the remainder runs.
- **Rollback**, if `10.0.209.71` is unreachable afterward: connect over the physical/hypervisor console (not SSH - that is exactly what may be broken) and either hand-correct `/etc/network/interfaces` or revert the managed stanza to `iface <name> inet dhcp`, then run `ifreload -a`.

## Manual steps - not run by this task

- The PBS ISO install itself (see [Prerequisites](#prerequisites---not-automated)).
- Populating `pbs/backup-username` and `pbs/backup-password` with real values, if not already done.
- Any reboot after the network change - the playbook prefers `ifreload -a` and never reboots the host on its own; a reboot, if one is ever needed, is a captain-supervised action.
- **Confirming the storage backing the `nas` NFS mount and the datastore matches what was actually racked.** This app assumes the NAS export at `<nas_host>:/volume1/pbs` is already sized and available for PBS backups; it does not provision NAS-side storage. If that assumption does not hold, treat it as a needs-decision rather than letting the playbook guess.

## Idempotency

Every task either checks existing state before changing it (hostname, network file content, apt package presence via `proxmox-backup-manager version`, PBS users, prune jobs, verify jobs, the NFS mount) or is naturally idempotent (`apt`, `copy`, `ufw`, `ansible.posix.authorized_key`, `ansible.posix.mount`). Re-running against an already-configured host is expected to report no changes.

## What was verified, and what was not

The 1Password field name (`public key`, not `public-key`) and vault (`Private`) for the `andrew-mbp` SSH key item were confirmed with `op item get andrew-mbp` and a live `op read`, not assumed. The official PBS installation docs URL was fetched and confirmed live.

**This playbook has never been run against the real host.** Verification here is `ansible-playbook --syntax-check`, `eslint` and `prettier` against the changed files - not a check-mode or live run, since `10.0.209.71` is a real host backing up the whole home lab and applying this is a captain-supervised action after PR review.

## Nx targets

| Target   | What it does                                                                                                                                                                |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `deploy` | Runs [`scripts/deploy.ts`](scripts/deploy.ts), which writes the Ansible inventory/vars from 1Password and runs [`scripts/deploy.yml`](scripts/deploy.yml) against the host. |
