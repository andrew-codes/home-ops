# Gaming PC

Ansible provisioning for the Windows gaming PC, plus the PowerShell scripts that
run on the machine itself.

Provisioning runs **remotely from the Mac**. Ansible reaches the gaming PC over
the OpenSSH server that ships with Windows.

## Prerequisites

### On the Windows machine (once, from an Administrator PowerShell)

Everything below is built into Windows - nothing is downloaded, no reboot is
needed, and no BIOS change is required. The block is safe to re-run.

```powershell
# Install the OpenSSH server that ships with Windows.
Get-WindowsCapability -Online -Name OpenSSH.Server* | Add-WindowsCapability -Online

# Start it now and on every boot.
Set-Service -Name sshd -StartupType Automatic -Status Running

# Ansible drives Windows through PowerShell, not cmd.
New-ItemProperty -Path HKLM:\SOFTWARE\OpenSSH -Name DefaultShell `
  -Value C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe `
  -PropertyType String -Force

# Authorize the Mac's public key (1Password: dev/ssh-key/public). Until the
# playbook installs its own sshd_config, administrators share one key file.
$key = '<paste dev/ssh-key/public here>'
$adminKeys = "$env:ProgramData\ssh\administrators_authorized_keys"
if (-not (Select-String -Path $adminKeys -SimpleMatch $key -ErrorAction SilentlyContinue)) {
  Add-Content -Path $adminKeys -Value $key
}
icacls $adminKeys /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F'
```

Then set a static IP, or note the machine's current one - it goes into the
Ansible inventory via the `gaming-pc/ip` entry in 1Password.

> **Migrating a machine provisioned before this change:** it may still have the
> Chocolatey `openssh` package, which registers a competing `sshd` service from
> a different OpenSSH build. Run `choco uninstall openssh -y` before the block
> above. The playbook no longer installs that package.

### On the Mac

```bash
pip install ansible
ansible-galaxy collection install ansible.windows
ansible-galaxy collection install community.windows
```

`pywinrm` is not required *for provisioning*. The Mac authenticates with the
private key whose public half is `dev/ssh-key/public`, so that key must be
loaded in the SSH agent or be the default identity.

Note that WinRM is not gone from the gaming PC. The machine is a backup target,
and `apps/backups` still reaches the Windows hosts it targets over WinRM on port
5986 (see `apps/backups/scripts/deploy.ts`), so WinRM must remain enabled there
and `pywinrm` is still needed to deploy backups.

## Running

From the repo root:

```bash
yarn nx provision gaming-pc
```

The playbook is idempotent and safe to re-run; that is the intended update
workflow (`git pull`, re-run).

## Why SSH rather than WinRM

Provisioning over WinRM required downloading and running
`ConfigureRemotingForAnsible.ps1` from the internet on every fresh machine,
which set up a self-signed certificate, an HTTPS listener on port 5986, and a
firewall rule. The OpenSSH server is already part of Windows, so the
provisioning prerequisite is now four built-in commands and the machine ends up
with one SSH implementation instead of two. `scripts/powershell/setup_ansible_windows.ps1`
still performs the WinRM bootstrap, but it now belongs to the `apps/backups`
flow only.

Running Ansible *on* the gaming PC was evaluated and rejected: Ansible cannot
run on Windows as a control node, so every local option needs WSL, which costs a
reboot - and WSL2 additionally needs hardware virtualization enabled in UEFI,
which no script can do. Neither delivers one-command setup on a fresh machine.

## Transport-sensitive tasks

The playbook now configures the same SSH service Ansible connects through, so
two tasks deserve care when editing:

- **`Copy sshd_config`** replaces the live SSH configuration mid-run. The
  playbook writes the authorized keys *before* this task, and the deployed
  `src/sshd_config` moves administrators from the shared
  `administrators_authorized_keys` file to per-user `.ssh/authorized_keys`. A
  bad `sshd_config` will lock provisioning out of the machine.
- **`Restart SSH Service`** restarts the daemon Ansible is connected through.
  This is safe because Win32-OpenSSH does not terminate established sessions
  when the service restarts.

### Why that risk was accepted, and when it expires

The SSH transport and the four tasks that configure it were verified without
touching a real machine (syntax check, `--check --diff` against an unroutable
RFC 5737 address, and `ansible-doc` parameter checks), so the first real
provisioning run is also the first *runtime* execution of those tasks. That was
accepted because a failure is recoverable rather than a lockout:

- **WinRM is still enabled on the gaming PC**, because `apps/backups` deploys to
  it over WinRM on port 5986. A provisioning run that breaks SSH still leaves a
  working way in.
- The machine is physically accessible.

**Expiry condition:** if `apps/backups` ever stops using WinRM - and WinRM is
therefore no longer enabled on the machine - this reasoning no longer holds.
Before changing the provisioning transport further at that point, exercise the
playbook against a throwaway Windows host first.

## Other targets

`yarn nx publish gaming-pc` is unrelated to provisioning. It packages the
PowerShell scripts in `src/` as a GitHub release, which the machine's own
`Update-Gaming-PC` scheduled task downloads to update itself.
