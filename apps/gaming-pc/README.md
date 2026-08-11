# Gaming PC

Ansible deployment for the Windows gaming PC, plus the PowerShell scripts that
run on the machine itself.

The deploy runs **remotely from the Mac**. Ansible reaches the gaming PC over
the OpenSSH server that ships with Windows.

## Prerequisites

Start here, from the repo root:

```bash
yarn nx pre-deploy gaming-pc
```

The two halves of the setup are not equally automatable, and the target does not
pretend otherwise:

| Half        | What `pre-deploy` does                                                                                                                                                                                                                              |
| ----------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Mac**     | Fully automated. Installs Ansible and the two collections, skips whatever is already present, and never upgrades a working install.                                                                                                                 |
| **Windows** | Cannot be run from here: the block below is what _enables_ SSH, so there is no SSH to run it over. The target prints that block with this Mac's public key already substituted, and checks over SSH what the machine still needs before you deploy. |

It is safe to re-run, and re-running is how you confirm the manual half landed.
It exits non-zero until the machine answers SSH, accepts this Mac's key, and
reports PowerShell as its `DefaultShell`.

The rest of this section is what `pre-deploy` automates or prints. It stays here
as the reference, and as the fallback for anyone debugging or working without
the target.

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

`gaming-pc/username` is the account Ansible connects and elevates as, and
`gaming-pc/user` must be that same account's profile folder name under
`C:\Users`. The playbook fails fast rather than writing authorized keys into a
profile the connecting account does not own, so a mismatch between those two
1Password entries stops the run before anything is changed.

> **Migrating a machine provisioned before this change:** it may still have the
> Chocolatey `openssh` package, which registers a competing `sshd` service from
> a different OpenSSH build. Run `choco uninstall openssh -y` before the block
> above. The playbook no longer installs that package.

### On the Mac

`yarn nx pre-deploy gaming-pc` does all of this. By hand it is:

```bash
brew install ansible
ansible-galaxy collection install ansible.windows
ansible-galaxy collection install community.windows
```

Homebrew rather than `pip`: a global `pip install` mutates whichever Python
happens to be first on `PATH`, and on a Homebrew Python it is refused outright
(PEP 668). Homebrew keeps Ansible and its interpreter self-contained, which is
also where Ansible already lives on the Mac this repo is driven from.

`pywinrm` is not required _for deploying this app_. The Mac authenticates with the
private key whose public half is `dev/ssh-key/public`, so that key must be
loaded in the SSH agent or be the default identity.

Note that WinRM is not gone from the gaming PC. The machine is a backup target,
and `apps/backups` still reaches the Windows hosts it targets over WinRM on port
5986 (see `apps/backups/scripts/deploy.ts`), so WinRM must remain enabled there
and `pywinrm` is still needed to deploy backups.

## Running

From the repo root:

```bash
yarn nx deploy gaming-pc
```

The playbook is idempotent and safe to re-run; that is the intended update
workflow (`git pull`, re-run).

## Targets

| Target       | What it does                                                                                                                           |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------------- |
| `pre-deploy` | Prepares both ends of a deploy: installs the Mac-side Ansible prerequisites, and prints and verifies the Windows-side ones. See above. |
| `deploy`     | Runs [`scripts/deploy.yml`](scripts/deploy.yml) against the machine over SSH.                                                          |
| `publish`    | Packages `src/` as a GitHub Release for the machine's own self-update task. Unrelated to deploying; see below.                         |

`deploy` is deliberately excluded from `yarn deploy/all`
(`--exclude=andrew-mbp,dorri-mbp,gaming-pc` in the root `package.json`, which
also excludes [`apps/andrew-mbp`](../andrew-mbp) and
[`apps/dorri-mbp`](../dorri-mbp) for the same reason), because setting a machine
up is a deliberate one-at-a-time action rather than a fleet deploy, and this one
fails the whole fan-out whenever the PC is off, asleep, or unreachable. Keep the
exclusion; JSON cannot carry the comment, which is why it is recorded here.

`deploy` also pins its own `dependsOn` rather than inheriting the `nx.json`
default, which ends in `publish`. This is the only project with both targets, so
inheriting it would cut a GitHub Release on every deploy. `provision`, the name
this target had before, carried no such dependency, and the behaviour is
unchanged.

## Why SSH rather than WinRM

Deploying over WinRM required downloading and running
`ConfigureRemotingForAnsible.ps1` from the internet on every fresh machine,
which set up a self-signed certificate, an HTTPS listener on port 5986, and a
firewall rule. The OpenSSH server is already part of Windows, so the
prerequisite is now four built-in commands and the machine ends up
with one SSH implementation instead of two. `scripts/powershell/setup_ansible_windows.ps1`
still performs the WinRM bootstrap, but it now belongs to the `apps/backups`
flow only.

Running Ansible _on_ the gaming PC was evaluated and rejected: Ansible cannot
run on Windows as a control node, so every local option needs WSL, which costs a
reboot - and WSL2 additionally needs hardware virtualization enabled in UEFI,
which no script can do. Neither delivers one-command setup on a fresh machine.

## Transport-sensitive tasks

The playbook now configures the same SSH service Ansible connects through, so
two tasks deserve care when editing:

- **`Copy sshd_config`** replaces the live SSH configuration mid-run. The
  playbook writes the authorized keys _before_ this task, and the deployed
  `src/sshd_config` moves administrators from the shared
  `administrators_authorized_keys` file to per-user `.ssh/authorized_keys`. A
  bad `sshd_config` will lock the deploy out of the machine.
- **`Restart SSH Service`** restarts the daemon Ansible is connected through.
  This is safe because Win32-OpenSSH does not terminate established sessions
  when the service restarts.

### Why that risk was accepted, and when it expires

The SSH transport and the four tasks that configure it were verified without
touching a real machine (syntax check, `--check --diff` against an unroutable
RFC 5737 address, and `ansible-doc` parameter checks), so the first real
deploy is also the first _runtime_ execution of those tasks. That was
accepted because a failure is recoverable rather than a lockout:

- **WinRM is still enabled on the gaming PC**, because `apps/backups` deploys to
  it over WinRM on port 5986. A deploy that breaks SSH still leaves a
  working way in.
- The machine is physically accessible.

**Expiry condition:** if `apps/backups` ever stops using WinRM - and WinRM is
therefore no longer enabled on the machine - this reasoning no longer holds.
Before changing the deploy transport further at that point, exercise the
playbook against a throwaway Windows host first.

## Other targets

`yarn nx publish gaming-pc` is unrelated to deploying. It packages the
PowerShell scripts in `src/` as a GitHub release, which the machine's own
`Update-Gaming-PC` scheduled task downloads to update itself.
