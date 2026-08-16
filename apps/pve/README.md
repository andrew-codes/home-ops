# pve

Provisions `pve`, the physical Proxmox VE hypervisor host - the machine that
underpins the whole home lab. Pinned to Proxmox VE 9.2.2 (see
[Proxmox version pin](#0-proxmox-version-pin-tasksversionyml)).

**This automation has never been run against the real host.** It was implemented,
lint/syntax-checked, and reviewed, but never executed - see
[Status: not yet applied](#status-not-yet-applied) below.

## Start-to-finish guide

1. **Bare-metal ISO install** (out of scope for this automation - do it by hand
   following [Proxmox's own installer docs](https://pve.proxmox.com/pve-docs/pve-admin-guide.html#chapter_installation)).
2. **Manual steps that must happen before this playbook runs** - see
   [Manual steps](#manual-steps-that-cannot-be-automated) below. Several of these
   (BIOS settings, physically installing the GPUs) can only be done with hands on the
   machine.
3. **Populate the 1Password secrets this automation reads** - see
   [Secrets](#secrets).
4. **Run this playbook** - see [Deploying](#deploying). Not from an agent session, see
   [AGENTS.md](AGENTS.md).
5. **Reboot** - required for the IOMMU/GRUB/vfio changes to take effect. A manually
   supervised step, with console access available - see
   [Manual steps](#manual-steps-that-cannot-be-automated).
6. **Verify IOMMU grouping post-reboot** - see
   [GPU passthrough](#nvidia-gpu-passthrough-two-cards-two-vms).

## What the automation does

Everything below is implemented as one Ansible playbook
([`src/deploy/index.yml`](src/deploy/index.yml)) run over SSH against the host, wired
into `nx run pve:deploy`. Every task checks current state before changing it and is
safe to re-run - see each section for exactly how.

### 0. Proxmox version pin ([`tasks/version.yml`](src/deploy/tasks/version.yml))

Runs first, before anything else, and fails the whole playbook closed if the host
isn't on exactly the pinned version.

- Reads `pveversion` and extracts the `pve-manager` version.
- **Fails loudly** if it isn't exactly `9.2.2` - this automation never upgrades or
  downgrades Proxmox itself; that's the separate, manually run
  [Upgrading Proxmox](#upgrading-proxmox) runbook.
- Enumerates the installed `pve-kernel-*` packages and holds them, along with
  `pve-manager`, via `apt-mark hold` - checking `apt-mark showhold` first and only
  holding whatever isn't already held. This means a stray `apt full-upgrade` run
  outside this playbook can't silently move the host off `9.2.2`; moving to a new
  pinned version requires deliberately running `apt-mark unhold` first (the
  [Upgrading Proxmox](#upgrading-proxmox) runbook covers this).

### 1. Network ([`tasks/network.yml`](src/deploy/tasks/network.yml))

> [!WARNING]
> **This step can lock out SSH access to `pve` and everything it hosts.** Read
> [Network rollback](#network-rollback-if-this-goes-wrong) before running it.

Sets the host to static IP `10.1.0.100/24`, gateway `10.1.0.1`, DNS `1.1.1.1` and
`1.0.0.1`, search domain `smith-simms.family`.

- The primary bridge is **detected, not assumed**: the playbook reads
  `ansible_default_ipv4.interface` (the interface currently holding the default
  route) and fails closed if it doesn't look like a Proxmox bridge (`vmbr*`).
- The bridge's existing `bridge-ports` (the physical NIC(s) it's attached to) is read
  out of the current `/etc/network/interfaces` and preserved in the new config, so the
  physical NIC binding is never guessed.
- `/etc/network/interfaces` is backed up to `/etc/network/interfaces.pre-pve-automation.bak`
  **once**, before the first change - re-running never overwrites that backup.
- The new config is written via `ansible.builtin.template`, which is a no-op when the
  rendered file already matches - so re-running with unchanged inputs makes no
  network change at all. `ifup --syntax-check` validates the rendered file before it's
  installed.
- Applied with `ifreload -a` (Proxmox ships `ifupdown2`, which supports this) - **not**
  a reboot. `ifreload` only runs when the templated file actually changed.
- `/etc/resolv.conf` is templated directly as a second, independent step (in case
  resolvconf integration isn't wiring DNS through from `/etc/network/interfaces` on
  this install).

#### Network rollback (if this goes wrong)

If `ifreload` applies a bad config and SSH drops:

1. **Physical console.** This automation does not currently know whether this
   hardware has IPMI, iDRAC, or an equivalent out-of-band management interface -
   **check for one and document it here** before running this playbook for the first
   time. Until then, assume physical console access (keyboard + monitor, or a KVM) is
   the only fallback.
2. At the console, log in as root and restore the backup:
   ```bash
   cp /etc/network/interfaces.pre-pve-automation.bak /etc/network/interfaces
   ifreload -a
   ```
3. If `ifreload` itself is unresponsive, a reboot will pick up the restored
   `/etc/network/interfaces` on the next boot.
4. Confirm SSH access is back (`ssh root@10.1.0.100` from a machine on that subnet)
   before re-attempting the playbook.

### 2. Time zone ([`tasks/timezone.yml`](src/deploy/tasks/timezone.yml))

Sets `America/New_York` via `timedatectl set-timezone`, only when it isn't already
set - `timedatectl show --property=Timezone --value` is checked first.

### 3. SSH access ([`tasks/ssh.yml`](src/deploy/tasks/ssh.yml))

Installs the operator's SSH public key into `root`'s `authorized_keys`, the same way
other host apps in this repo install `dev/ssh-key/public` - see
[Secrets](#secrets) for where the key comes from. Idempotent via
`ansible.builtin.lineinfile`: the exact key line is added once and left alone on
every subsequent run.

### 4. `nas-iso` storage ([`tasks/storage-nas-iso.yml`](src/deploy/tasks/storage-nas-iso.yml))

Registers a Proxmox storage entry named `nas-iso`, backed by the SMB share `ISO` on
the home-ops NAS, mounted at `/mnt/pve/nas-iso` (Proxmox's own convention for
storage-id `nas-iso` - not a literal `/pve/mnt/...` path). Content types `iso,vztmpl`.

`pvesm status --storage nas-iso` is checked first; `pvesm add cifs` runs only if it's
absent, `pvesm set` reconciles settings if it's already there (a cheap no-op when
nothing changed).

> [!IMPORTANT]
> **The NAS credentials for this share do not exist in 1Password yet.** See
> [Secrets](#secrets-that-do-not-exist-yet).

### 5. Proxmox Backup Server storage ([`tasks/storage-pbs.yml`](src/deploy/tasks/storage-pbs.yml))

Registers a PBS storage entry (Proxmox storage id `pbs-nas`) against `10.0.209.71`,
datastore `nas`. Same check-then-add-or-reconcile idempotency as `nas-iso`, via
`pvesm status --storage pbs-nas`.

> [!IMPORTANT]
> **The PBS credentials for this integration do not exist in 1Password yet**, and the
> **TLS fingerprint may need manual approval on first connect** - see
> [Secrets](#secrets-that-do-not-exist-yet) and [PBS TLS fingerprint](#pbs-tls-fingerprint).

#### PBS TLS fingerprint

`pvesm add pbs` can fail on a self-signed/non-authoritative PBS certificate unless a
`--fingerprint` is supplied. The playbook only appends `--fingerprint` when the
`PBS_FINGERPRINT` environment variable is set (see [Deploying](#deploying)) - it is
optional because it isn't known until someone fetches it from the real PBS server.

Fetch and verify it before the first run:

```bash
echo | openssl s_client -connect 10.0.209.71:8007 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha256
```

Compare that against what the PBS server's own web UI shows under
_Dashboard > Certificate_ before trusting it - a fingerprint fetched over an
untrusted network could be a MITM's, not the server's.

### 6. NVIDIA GPU passthrough, two cards, two VMs ([`tasks/gpu-passthrough.yml`](src/deploy/tasks/gpu-passthrough.yml))

Host CPU is AMD EPYC, so this uses AMD-V/AMD-Vi (IOMMU), not Intel VT-d.

- Adds `amd_iommu=on iommu=pt` to `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`
  - additively (existing params are read first and only the two missing tokens are
    appended), so re-running never duplicates them.
- Loads `vfio`, `vfio_iommu_type1`, `vfio_pci`, `vfio_virqfd` at boot via
  `/etc/modules-load.d/vfio.conf`.
- Blacklists `nouveau` and the in-box `nvidia` driver on the **host** via
  `/etc/modprobe.d/blacklist-nvidia-host.conf`, so both cards stay unclaimed and are
  available to hand to VMs.
- **Discovers both cards' PCI vendor:device ids at runtime** with `lspci -nn` -
  nothing hardware-specific is hardcoded. It enumerates every NVIDIA VGA and
  audio/HDMI function, and writes the combined `ids=` line to
  `/etc/modprobe.d/vfio-pci-nvidia.conf`. Fails loudly if no NVIDIA device is found
  (most likely: the cards aren't installed yet).
- Runs `update-initramfs -u -k all` and `update-grub` - but only when something
  actually changed (Ansible handlers, one per file that can change).
- **Reports** each NVIDIA device's IOMMU group (`/sys/kernel/iommu_groups`) as an
  informational step. It does **not** and cannot guarantee the two cards land in
  separate groups - see [IOMMU grouping](#verifying-iommu-grouping-after-reboot).

None of this takes effect until the host reboots - see
[Manual steps](#manual-steps-that-cannot-be-automated).

**Downstream consumer:** `resources/k8s/src/provision/provision.tf` already takes
`gpuPci` / `gpuAudioPci` Terraform variables (PCI addresses like `01:00.0`) for
`k8s-main`'s passthrough config (one card's VGA+audio pair). Once GPUs are bound to
`vfio-pci` here, read their PCI addresses back out with `lspci -nnk | grep -i
nvidia`. The second card is enabled for passthrough by this playbook but currently
has no Terraform consumer - the dedicated GPU worker node that previously used it
was decommissioned and its provisioning resource removed from the repo.

#### Verifying IOMMU grouping after reboot

After the reboot, check that each card's VGA and audio function share a group with
**only each other** (or nothing at all) - not with the other card's functions, and
ideally not with unrelated devices:

```bash
find /sys/kernel/iommu_groups -type l | sort -t/ -k5 -n
for g in /sys/kernel/iommu_groups/*/devices/*; do
  echo "$(basename "$(dirname "$(dirname "$g")")"): $(lspci -nns "$(basename "$g")")"
done | grep -i nvidia
```

If both cards' functions land in one shared group, or share a group with an unrelated
device, they cannot be split across two VMs as-is. This is a motherboard/PCIe
topology property this playbook cannot fix. The fallback is the ACS-override kernel
workaround (`pcie_acs_override=downstream,multifunction` on the kernel command line),
which forces the kernel to treat downstream/multifunction devices as isolated even
when the hardware doesn't guarantee real isolation. **Tradeoff:** it's explicitly a
correctness override, not a fix - it can allow DMA between devices the hardware would
otherwise have kept apart, which is a real (if narrow, for a home lab) security and
stability concession. Only reach for it after confirming, via the grouping check
above, that the topology genuinely doesn't separate the two cards; try a different
PCIe slot for one card first if that's an option on this board.

## Manual steps that cannot be automated

These need a human at the machine (or its console), not this playbook:

- **Physically installing both NVIDIA GPUs** in the server.
- **Enabling virtualization/IOMMU in BIOS/UEFI** (AMD-V/SVM and AMD-Vi) - no script
  can reach firmware settings.
- **Verifying PCIe slot placement gives each GPU its own IOMMU group** once both cards
  are installed, and applying the ACS-override workaround if not - see
  [Verifying IOMMU grouping](#verifying-iommu-grouping-after-reboot). Board-specific,
  cannot be resolved in software beyond that documented workaround.
- **The bare-metal Proxmox 9.2.2 ISO install itself**, if starting from nothing - see
  [Proxmox's installer docs](https://pve.proxmox.com/pve-docs/pve-admin-guide.html#chapter_installation).
- **Creating the PBS and NAS-share service accounts** and putting their real
  credentials into the 1Password items this automation reads - see
  [Secrets that do not exist yet](#secrets-that-do-not-exist-yet).
- **Approving the PBS TLS fingerprint** on first connect, if `pvesm add pbs` doesn't
  auto-accept it even with `--fingerprint` supplied - see
  [PBS TLS fingerprint](#pbs-tls-fingerprint).
- **The reboot(s)** needed after the network, GRUB/IOMMU, and blacklist changes -
  a manually supervised step, with console access available as a fallback. Confirm SSH access
  survives the network change (step 1) before rebooting for the GPU changes (step 6),
  so a stacked failure doesn't leave two things to debug through a console at once.
- **Confirming an out-of-band management interface** (IPMI/iDRAC or equivalent) exists
  for this hardware, or confirming physical console access is the only fallback -
  needed before the [network step](#network-rollback-if-this-goes-wrong) is ever run
  for real.

## Secrets

Read through [`packages/configuration-1password`](../../packages/configuration-1password),
the same as every other host app in this repo.

| Secret                  | Used for                                                                 |
| ----------------------- | ------------------------------------------------------------------------ |
| `proxmox/ip`            | The host to run the playbook against (the Ansible inventory target)      |
| `andrew-mbp/public-key` | The operator's SSH public key, installed into `root`'s `authorized_keys` |
| `nas/ip`                | The NAS host backing the `nas-iso` SMB share                             |
| `pve-nas-iso/username`  | NAS `ISO` share username (see [below](#secrets-that-do-not-exist-yet))   |
| `pve-nas-iso/password`  | NAS `ISO` share password (see [below](#secrets-that-do-not-exist-yet))   |
| `pve-pbs/username`      | PBS datastore username (see [below](#secrets-that-do-not-exist-yet))     |
| `pve-pbs/password`      | PBS datastore password (see [below](#secrets-that-do-not-exist-yet))     |

`PBS_FINGERPRINT` is an optional **environment variable**, not a 1Password secret -
see [PBS TLS fingerprint](#pbs-tls-fingerprint).

### `andrew-mbp/public-key`: confirm the field name

`andrew-mbp/public-key` is registered assuming the 1Password item is literally named
`andrew-mbp`, of the native **SSH Key** item type, with its public key in a field
labeled `public-key`. That assumption has **not** been verified against the real
item - confirm it before the first run:

```bash
op item get andrew-mbp --format json
```

1Password's native SSH Key item type typically labels this field `public key` (with
a space), not `public-key`. If that's what the real item shows, update the secret
name in [`packages/configuration-1password/src/index.ts`](../../packages/configuration-1password/src/index.ts)
from `andrew-mbp/public-key` to `andrew-mbp/public key` (and in
[`scripts/deploy.ts`](scripts/deploy.ts)) to match.

### Secrets that do not exist yet

Per [`apps/andrew-mbp/README.md`](../andrew-mbp/README.md#time-machine-backups-to-the-nas)
and [`apps/dorri-mbp/README.md`](../dorri-mbp/README.md), only `nas/ip` exists in
1Password today - there is no NAS username/password. The same gap applies to PBS.

**These four 1Password items must be created with real values before
`nx run pve:deploy` can run non-interactively:**

- `pve-nas-iso` (fields `username`, `password`) - a service account for the NAS's
  `ISO` SMB share.
- `pve-pbs` (fields `username`, `password`) - a service account for the PBS
  datastore.

`nx run pve:deploy` fails fast with `op`'s own "item not found" error if these are
missing - it does not silently skip storage configuration.

## Deploying

```bash
PBS_FINGERPRINT="$(echo | openssl s_client -connect 10.0.209.71:8007 2>/dev/null | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2)" \
  nx run pve:deploy
```

`PBS_FINGERPRINT` is optional - omit it to let `pvesm add pbs` attempt its own
auto-accept first, and only set it if that fails (see
[PBS TLS fingerprint](#pbs-tls-fingerprint)).

> [!CAUTION]
> **Do not run this from an agent session.** See [AGENTS.md](AGENTS.md). This is a
> manually supervised action, ideally with physical console access on hand, taken
> after this automation has been reviewed - not something to run casually while
> iterating on the playbook.

### Status: not yet applied

This automation has been implemented and syntax-checked (`nx run pve:lint`), but has
**never been run against the real `pve` host** - not even in Ansible's `--check`
(dry-run) mode, since exercising `--check` still requires live SSH connectivity to the
host this automation is deliberately not touching yet. Applying it for the first time,
and the reboot(s) that follow, are manually supervised actions to take after review,
with console access available as a fallback per
[Network rollback](#network-rollback-if-this-goes-wrong).

## Nx targets

| Target   | What it does                                                                                           |
| -------- | ------------------------------------------------------------------------------------------------------ |
| `lint`   | `ansible-playbook --syntax-check` against the playbook - no host contact, safe to run anytime.         |
| `deploy` | Runs the full playbook against `pve` over SSH. Not from an agent session - see [AGENTS.md](AGENTS.md). |

`deploy` is deliberately excluded from `yarn deploy/all` in the root `package.json`,
alongside `andrew-mbp`, `dorri-mbp` and `gaming-pc` - see
[Deploy exclusions](../../README.md#deploy-exclusions). This host is on the list
because it is a one-at-a-time, manually supervised action with real lockout risk, not a
fleet deploy target.

There is no `provision` target - `pve` is the physical machine everything else is
provisioned onto, not something provisioned itself by Terraform.

## Upgrading Proxmox

A runbook for later use - **this task does not run any of this.**

1. **Check the current version.**
   ```bash
   pveversion
   ```
2. **Release the version pin.** [Proxmox version pin](#0-proxmox-version-pin-tasksversionyml)
   holds `pve-manager` and the installed `pve-kernel-*` packages via `apt-mark` so they
   can't drift by accident - an upgrade must release that hold deliberately first:
   ```bash
   apt-mark unhold pve-manager $(dpkg-query -W -f='${Package}\n' 'pve-kernel-*')
   ```
3. **Snapshot/back up VMs first.** Every VM and container on this host should have a
   current backup (via the `pbs-nas` storage this automation registers, or a manual
   snapshot) before upgrading - an upgrade that goes wrong is much cheaper to recover
   from with a recent restore point.
4. **Confirm the repository configuration.** A subscription-less Proxmox host should
   be on the no-subscription repo, not the enterprise repo it doesn't have a license
   for:
   ```bash
   cat /etc/apt/sources.list.d/pve-enterprise.list 2>/dev/null       # should be absent or commented out
   cat /etc/apt/sources.list.d/pve-no-subscription.list 2>/dev/null  # should be present
   ```
   Proxmox's own docs cover switching between them:
   [Package Repositories](https://pve.proxmox.com/pve-docs/pve-admin-guide.html#sysadmin_package_repositories).
5. **Update and upgrade.**
   ```bash
   apt update
   apt full-upgrade
   ```
6. **Reboot** if the upgrade included a new kernel (it usually does) - check
   `apt list --upgradable` output or just reboot after any `full-upgrade` that touched
   `pve-kernel-*` or `proxmox-kernel-*`.
7. **Re-verify everything this automation configured survived the upgrade:**
   ```bash
   pveversion                                    # confirm the new version
   pvesm status --storage nas-iso                # NAS ISO storage still registered
   pvesm status --storage pbs-nas                # PBS storage still registered
   cat /proc/cmdline | grep -o 'amd_iommu=on\|iommu=pt'  # IOMMU flags survived
   lspci -nnk | grep -A2 -i nvidia | grep 'Kernel driver'  # both cards still bound to vfio-pci, not nouveau/nvidia
   ip -br addr show                              # static IP/bridge config intact
   ```
8. **Update the pinned version** in
   [`src/deploy/index.yml`](src/deploy/index.yml)'s `pinned_pve_version` to match the
   new `pveversion` output, so the version pin task re-holds the new packages instead
   of failing on every future run. Then re-run `nx run pve:deploy` - every step here is
   idempotent, so it only touches what actually drifted.
