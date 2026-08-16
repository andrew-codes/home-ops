This project configures `pve`, the physical Proxmox VE hypervisor - the machine every VM and container in the home lab runs on. Read [README.md](README.md) before changing anything here.

# Never Run `nx run pve:deploy` From An Agent Session

This is not a lab machine with a snapshot to roll back to - it is the host underneath everything else. `nx run pve:deploy` rewrites `/etc/network/interfaces` and `/etc/resolv.conf` and reloads networking with `ifreload`, which can cut SSH access to `pve` (and therefore to every VM/LXC behind it) if the static IP, gateway or bridge name is wrong. It also edits GRUB and initramfs for IOMMU/vfio, which only take effect after a reboot - a reboot this playbook never performs itself.

Only run this deliberately, with physical console or IPMI/iDRAC access available as a fallback (see the README's rollback procedure). Validate with non-mutating commands only:

```bash
nx run pve:lint                                # ansible-playbook --syntax-check, no host contact
ansible-playbook --syntax-check src/deploy/index.yml
```

`pve` is excluded from `yarn deploy/all` in the root `package.json` for the same reason `andrew-mbp`, `dorri-mbp` and `gaming-pc` are - this is a one-at-a-time, manually supervised deploy, not a fleet target.

# The GPU PCI Ids Are Discovered, Never Hardcoded

`tasks/gpu-passthrough.yml` enumerates NVIDIA vendor:device ids via `lspci -nn` at apply time and writes them into `/etc/modprobe.d/vfio-pci-nvidia.conf`. Do not hardcode a PCI id here - it belongs to one specific machine's hardware and would silently do nothing (or bind the wrong device) on any other host.

# IOMMU Grouping Is Reported, Not Guaranteed

Whether the two NVIDIA cards land in separate IOMMU groups (required to pass each to a different VM) is a motherboard/PCIe-topology property this playbook cannot control. `tasks/gpu-passthrough.yml` only reports the groups it finds; verifying isolation after the required reboot, and applying the ACS-override workaround if needed, is a documented manual step - do not "fix" this by writing IOMMU group assumptions into the playbook.

# Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
