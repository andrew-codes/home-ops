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

### First-time setup: create the local admin account

A fresh Windows install signs you in with a Microsoft account. Nothing in this
repo creates the account Ansible connects and elevates as - it is a
precondition, not something the deploy provisions (the only account the
playbook creates is a separate `andrew` admin account, via `win_user` in
`scripts/deploy.yml`). Before anything below, once per machine:

1. Settings > Accounts > Your info > **Sign in with a local account instead**,
   and convert the current account to a local account.
2. Name it exactly the value of `gaming-pc/username` in 1Password, and make it
   an **Administrator**.
3. Sign in as that account at least once, so `C:\Users\<name>` is actually
   created. The resulting profile folder name must match `gaming-pc/user` in
   1Password exactly - the playbook fails fast on a mismatch rather than
   writing authorized keys into a profile the connecting account does not own.

### On the Windows machine (once, from an Administrator PowerShell)

Everything below is built into Windows - nothing is downloaded, no reboot is
needed, and no BIOS change is required. The block is safe to re-run.

```powershell
# Install the OpenSSH server that ships with Windows.
Get-WindowsCapability -Online -Name OpenSSH.Server* | Add-WindowsCapability -Online

# Start it now and on every boot.
Set-Service -Name sshd -StartupType Automatic -Status Running

# The firewall rule OpenSSH installs only allows inbound port 22 on the
# Private/Domain profiles, not Public. Without this, sshd runs but nothing
# can reach it and SSH just times out.
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private

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

`gaming-pc/username` and `gaming-pc/user` must both refer to the local admin
account created in [First-time setup](#first-time-setup-create-the-local-admin-account)
above - see there for why a mismatch stops the run before anything is changed.

> **Migrating a machine provisioned before this change:** it may still have the
> Chocolatey `openssh` package, which registers a competing `sshd` service from
> a different OpenSSH build. Run `choco uninstall openssh -y` before the block
> above. The playbook no longer installs that package.

### Turn off Windows Defender Tamper Protection (once, in Windows Security)

`deploy`'s Chocolatey install fails while this is on. Windows Defender flags
Chocolatey's own bootstrap script (`WebClient.DownloadString` piped into
`iex`) as `Trojan:Win32/GoptaJu.D` - a known false positive on this
fileless-download pattern (see
[chocolatey/choco#2132](https://github.com/chocolatey/choco/issues/2132)) -
and kills the running PowerShell process mid-task. The playbook works around
this by disabling Windows Defender real-time monitoring only for the
duration of the Chocolatey install task, in a `block`/`always`, so it is
re-enabled immediately after regardless of whether that task succeeds -
rather than adding a permanent exclusion. That toggle only works with Tamper
Protection off: while it is on, Tamper Protection silently no-ops scripted
changes to Defender's own settings, including `Set-MpPreference`, so the
toggle reports success while changing nothing and the install still fails.

Tamper Protection can only be turned off interactively - that restriction is
the entire point of it - so, like enabling SSH above, this cannot be
automated from here. On the gaming PC: **Windows Security > Virus & threat
protection > Manage settings > Tamper Protection > Off**. `pre-deploy` checks
this over SSH once the block above is done, and fails with this same
explanation if it is still on.

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

## Software the deploy installs

The list itself lives in [`src/software.ps1`](src/software.ps1), which is the
file to edit when something is added or dropped. It is driven twice from the
playbook, once elevated and once not, because elevation is a property of the
process: machine-scope installers need it, and MSIX packages from the Store and
the per-user MoonDeck Buddy installer must not have it or they land in the wrong
hive.

winget is preferred over Chocolatey throughout. Every entry checks for presence
before acting, so a second deploy installs nothing.

| Software                                                         | Source                    | Package                      |
| ---------------------------------------------------------------- | ------------------------- | ---------------------------- |
| Steam                                                            | winget                    | `Valve.Steam`                |
| Apollo (streaming server)                                        | winget                    | `ClassicOldSong.Apollo`      |
| Logi Options+                                                    | direct download           | see below                    |
| Microsoft Visual C++ Redistributable (Logi Options+ dependency)  | winget                    | `Microsoft.VCRedist.2015+.x64` |
| 1Password                                                        | winget (user scope)       | `AgileBits.1Password`        |
| Tailscale                                                        | winget                    | `Tailscale.Tailscale`        |
| Zed                                                              | winget                    | `ZedIndustries.Zed`          |
| Raycast                                                          | Microsoft Store           | `9PFXXSHC64H3`               |
| Windows HDR Calibration                                          | Microsoft Store           | `9N7F2SM5D1LR`               |
| Dolby Access                                                     | Microsoft Store           | `9N0866FS04W8`               |
| Xbox Accessories                                                 | Microsoft Store           | `9NBLGGH30XJ3`               |
| MoonDeck Buddy                                                   | GitHub release            | `FrogTheFrog/moondeck-buddy` |
| NVIDIA App                                                       | Chocolatey                | `nvidia-app`                 |
| NVIDIA game-ready driver                                         | NVIDIA, via `src/run.ps1` | -                            |
| WinNUT-Client (UPS monitoring, see [below](#nut-ups-monitoring)) | winget (user scope)       | `nutdotnet.WinNUT`           |

**1Password installs at user scope**, not machine scope like the other winget
rows above it. A machine-scope install fails with "The current system
configuration does not support the installation of this package" - a
documented winget limitation provisioning certain packages machine-wide, not
specific to this manifest or this machine.

Kept absent: **Playnite**, **Discord**, **Visual Studio Code** (Zed is the
installed editor, above), and **Epic Games Launcher**. Discord needs more than
a package removal - its Squirrel installer drops a working copy in
`%LOCALAPPDATA%` that no package manager can see - so `software.ps1` also runs
that uninstaller and clears the leftover directories. Epic Games Launcher is
removed via Chocolatey, in `scripts/deploy.yml`, rather than through
`software.ps1`'s winget-based `$UnwantedPackages` - it was installed through
Chocolatey originally, so removal uses the same package manager.

Four of those rows are not plain winget, and each for its own reason:

- **NVIDIA App** has no manifest in the community winget source (the `Nvidia`
  publisher there carries CUDA, FrameView, PhysX and so on, but not the app), so
  Chocolatey stays for it alone.
- **Logi Options+** installs by downloading
  `logioptionsplus_installer.exe` directly and running it
  (`Install-LogiOptionsPlus` in `src/software.ps1`), bypassing winget
  entirely. Its winget manifest (`InstallerType: exe`,
  `ElevationRequirement: elevatesSelf`) makes winget launch it through
  `ShellExecuteEx`, which needs a real interactive desktop/token to elevate -
  unavailable in this deploy's non-interactive `become`/`runas`-over-SSH
  session, so it fails with
  `APPINSTALLER_CLI_ERROR_SHELLEXEC_INSTALL_FAILED` (Win32 error 1008,
  `ERROR_NO_TOKEN`). Steam, Apollo, Tailscale and Zed do not hit this because
  winget installs those installer types through a `CreateProcess`-based path
  that never needs `ShellExecute`. Running the installer directly - without
  `-Verb RunAs`, so it also goes through `CreateProcess` - sidesteps it the
  same way Chocolatey and MoonDeck Buddy already do in this same session:
  this process is already elevated, so no further elevation dance is needed.
  Idempotency comes from checking the installer's `ProductCode` in the
  registry rather than winget's own presence check.
- **MoonDeck Buddy** is published to neither winget nor Chocolatey. It is
  fetched from its GitHub releases - the same way `gsync-toggle` already is, and
  from the same author. Re-running downloads nothing: the installed Inno Setup
  `DisplayVersion` is compared against the latest release tag first.
- **The NVIDIA game-ready driver** is not a package at all.
  [`src/run.ps1`](src/run.ps1) asks NVIDIA for the latest version for this GPU,
  compares it against what `nvidia-smi` reports, and returns without downloading
  anything when they match - which is what "only install if not already on
  latest" asks for. It is also the payload of the nightly `Update-Gaming-PC`
  task, so the deploy-time run exists only so a freshly rebuilt machine gets its
  driver during setup rather than at the next midnight.

Chocolatey's own bootstrap script trips a Windows Defender false positive -
see [Turn off Windows Defender Tamper Protection](#turn-off-windows-defender-tamper-protection-once-in-windows-security)
under Prerequisites for what it is and the one-time manual step it requires.

### NUT UPS monitoring

> [!WARNING]
> **A misconfigured client here can shut this machine down unexpectedly.** Verify
> the NUT server address, UPS name and thresholds below against the real Synology
> NAS before relying on this, or before merging a change to it.

WinNUT-Client (`nutdotnet.WinNUT`) monitors the Synology NAS's built-in UPS Network
Status service (out of scope for this repo - not provisioned here) as a NUT server
at `10.5.113.53:3493`, and shuts this machine down gracefully on `FSD` (forced
shutdown, signalled by the NAS) or on its own low-battery detection. This is
monitoring plus auto-shutdown, not just alerting.

- **Installed in the user phase, not the machine phase.** The only installer winget
  publishes for it is a per-user MSI (`Scope: user` in its manifest) - there is no
  machine-scope build to request, so it is grouped with the Store apps in
  `Invoke-UserPhase` rather than `$MachinePackages`.
- **Configured by [`src/configure-nut-client.ps1`](src/configure-nut-client.ps1)**,
  a separate deploy step from the winget install above. WinNUT-Client has no CLI or
  plain config file - [`src/nut-client.ps1`](src/nut-client.ps1) writes directly to
  its plain flat registry tree under `HKCU:\Software\WinNUT\{Appareance,Connexion,Power}`,
  found by diffing the real registry before and after changing a setting in
  WinNUT-Client's own Preferences dialog on a real host running the exact version
  winget publishes (`v2.2.8719`). An earlier version of this file instead used
  reflection against WinNUT-Client's compiled `My.Settings` class, matching the
  schema on GitHub's `main` branch; that schema turned out not to exist in any
  actual release - `main` is ahead of every shipped version, including the latest
  tag - so `MySettings` had zero real properties and every write failed. `NutLogin`/
  `NutPassword` are DPAPI-protected (`DataProtectionScope.CurrentUser`, Unicode
  bytes) directly here, reproducing the same blob format
  `WinNUT-Client_Common`'s `SerializedProtectedString` produces.
- **Idempotent**: each registry value is compared against its current value and
  only written when it actually needs to change.
- **Deliberately the last task in the playbook.** The NUT server has not been
  provisioned yet (out of scope for this repo), so this task is expected to fail
  until it is. It is kept failing rather than made best-effort - a misconfigured
  client here can shut this host down unexpectedly, so silently tolerating a bad
  config would be worse than blocking the deploy - and ordered last so every other
  task still completes first.
- **Runs as its own Ansible task, `no_log`'d**, separate from the software.ps1
  install task above, so the NUT monitor credentials never appear in Ansible's
  output while the existing Microsoft Store warning visibility
  ([below](#the-microsoft-store-apps-are-best-effort)) is unaffected. The
  credentials are passed as process environment variables, not command-line
  arguments, for the same reason.
- **Started, not just configured.** `StartWithWindows` only takes effect on this
  app's _next_ login; since this deploy's job is protecting the host now, the same
  step also launches WinNUT-Client immediately if it is not already running.
- **The UPS name (`ups`) is an assumption, not a confirmed value** - it is the
  Synology default, but has not been verified against this NAS's real UPS Network
  Status configuration. Confirm it, the monitor account, and allow-list this
  machine as a permitted client (NAS Control Panel > Hardware & Power > UPS >
  Network UPS Server) before the first real run.
- The monitor account is shared with
  [`pve`](../pve/README.md#nut-monitor-account-and-ups-name) and
  [`pbs`](../../resources/pbs/README.md#nut-ups-monitoring), all reading the same
  `nut/monitor-username` / `nut/monitor-password` 1Password fields via
  `configurationApi` in [`scripts/deploy.ts`](scripts/deploy.ts) - one monitor
  account for every client, matching how the NAS itself models it.

### The Microsoft Store apps are best-effort

Raycast, Windows HDR Calibration, Dolby Access and Xbox Accessories are the
only entries allowed to fail without failing the deploy - the first three
matching the ticket's own "if possible", Xbox Accessories added later for the
same technical reason. An MSIX install can require an interactive, signed-in
Microsoft Store session, which a deploy driven over SSH does not necessarily
have.

They are not silent about it: a failure is logged as `WARNING`, repeated in the
run's `SUMMARY` lines, and counted in the `RESULT ... warnings=` line the
playbook prints. If they warn, install that app from the Store by hand once;
`AutoDownload` keeps it updated afterwards.

## Windows settings the deploy applies

| Setting                                    | How                                                                                                                       |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------- |
| Auto-hide the taskbar                      | `StuckRects3` byte 8, Explorer restarted only when it changed                                                             |
| Auto-update Windows and Microsoft software | `AllowMUUpdateService`, installs at 03:00 daily                                                                           |
| Updates restart only late at night         | Active hours pinned to 08:00-01:00                                                                                        |
| Microsoft Store apps auto-update           | `WindowsStore\AutoDownload`                                                                                               |
| Hibernation off                            | `powercfg /hibernate off`                                                                                                 |
| Sleep off                                  | `standby-timeout` 0 on AC and DC                                                                                          |
| Automatic sign-in, including after wake    | `AutoAdminLogon`, plus no password required on wake                                                                       |
| Wake-on-LAN                                | Magic packet only, armed with `powercfg /deviceenablewake`; the device power-down checkbox is left at the Windows default |
| OS notifications off                       | `ToastEnabled`, notification centre and toast policies                                                                    |
| Dark mode                                  | `AppsUseLightTheme` / `SystemUsesLightTheme`                                                                              |
| All desktop icons hidden                   | `HideIcons`                                                                                                               |
| Taskbar widgets off                        | `Dsh\AllowNewsAndInterests` policy                                                                                        |
| UAC off                                    | `EnableLUA`, `ConsentPromptBehaviorAdmin`, `PromptOnSecureDesktop`                                                        |
| Zed as the default text and code editor    | `DefaultAssociationsConfiguration` policy, 139 file types                                                                 |
| Xbox Game Bar off                          | `GameDVR_Enabled`, `AppCaptureEnabled`, plus the `AllowGameDVR` machine policy                                            |
| Auto HDR on                                | `AutoHDREnable=1` merged into the `DirectXUserGlobalSettings` string, preserving any other keys already in it            |
| WiFi off                                   | `Disable-NetAdapter` on adapters with `MediaType -eq 'Native 802.11'` - this machine is wired-only                       |

**Disabling WiFi assumes the deploy itself connects over the wired adapter**,
confirmed against `gaming-pc/ip` before this was added. Disabling the wrong
adapter would sever the deploy's own SSH connection mid-run. If this machine
is ever moved to WiFi, remove this task before the next deploy rather than
after it fails partway through.

Four of these need something the ticket did not ask for, or do not take effect
the moment the deploy finishes:

- **Auto sign-in additionally clears `DevicePasswordLessBuildVersion`.** Windows
  11 ships with passwordless sign-in for Microsoft accounts on, and while it is
  on, Winlogon ignores `DefaultPassword` and stops at the sign-in screen anyway.
  Auto-login does not work without this.
- **Disabling hibernation is what makes Wake-on-LAN work from a full
  shutdown.** Fast Startup is built on hibernation, and it leaves the NIC in a
  state that ignores magic packets. Turning hibernation off disables both.
- **`EnableLUA=0` only takes effect after a reboot.** The other two UAC values
  suppress the consent prompt in the meantime.
- **Zed becomes the default at the next sign-in, not immediately.** Windows
  evaluates `DefaultAssociationsConfiguration` when a user logs on. The file
  itself is [`src/default-associations.xml`](src/default-associations.xml),
  generated from the associations Zed's own installer registers, so the list
  tracks what Zed actually claims to handle rather than a hand-picked guess.

### The auto-login password

It comes from 1Password (`gaming-pc/password`), reaches the playbook as the
`windows_password` play variable, and the task that writes it sets `no_log` so
it stays out of Ansible's output. It is never committed.

Windows stores it in the registry in plaintext regardless - that is what
`AutoAdminLogon` is, not a shortcut taken here. Anyone with administrative
access to the machine can read it back. The account is a local gaming account on
a machine behind Tailscale, which is the trade the ticket accepts.

## Targets

| Target       | What it does                                                                                                                           |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------------- |
| `pre-deploy` | Prepares both ends of a deploy: installs the Mac-side Ansible prerequisites, and prints and verifies the Windows-side ones. See above. |
| `deploy`     | Runs [`scripts/deploy.yml`](scripts/deploy.yml) against the machine over SSH.                                                          |
| `publish`    | Packages `src/` as a GitHub Release for the machine's own self-update task. Unrelated to deploying; see [below](#the-publish-target).  |

`deploy` is deliberately excluded from `yarn deploy/all`; the exclusion list
lives on that script in the root `package.json`, and the rule behind it is
written up under [Deploy exclusions](../../README.md#deploy-exclusions). This
machine is on the list because setting it up is a deliberate one-at-a-time
action rather than a fleet deploy, and it fails the whole fan-out whenever the
PC is off, asleep, or unreachable.

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

## Deploying `src/` scripts to the machine

`Copy scripts to developer/tools` (`win_copy`, `src/` -> `C:\Users\<user>\developer\tools\`)
is preceded by a task that deletes that destination directory first.
`win_copy` is documented as unreliable at detecting a *changed* existing file
during a directory-mode copy - it diffs new files fine, but a modified file
already present at the destination can silently keep its old content. This
was confirmed on a real deploy: a rewritten `src/nut-client.ps1` stayed stale
on the machine across a re-deploy with no error. Deleting the destination
first forces every deploy to get an exact, fresh copy regardless of what
`win_copy`'s own diffing decides, at the cost of always re-copying rather than
skipping unchanged files - cheap here since these are small script files.

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

## The `publish` target

`yarn nx publish gaming-pc` packages the PowerShell scripts in `src/` as a
GitHub release, which the machine's own `Update-Gaming-PC` scheduled task
downloads to update itself. It is the machine's self-update path and is not part
of deploying: nothing in the `deploy` target invokes it, which is why `deploy`
pins its own `dependsOn` above.
