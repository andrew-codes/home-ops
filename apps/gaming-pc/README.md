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

| Software                                                         | Source                            | Package                        |
| ---------------------------------------------------------------- | --------------------------------- | ------------------------------ |
| Steam                                                            | winget                            | `Valve.Steam`                  |
| Apollo (streaming server)                                        | winget                            | `ClassicOldSong.Apollo`        |
| Logi Options+                                                    | direct download                   | see below                      |
| Microsoft Visual C++ Redistributable (Logi Options+ dependency)  | winget                            | `Microsoft.VCRedist.2015+.x64` |
| 1Password                                                        | winget (user scope)               | `AgileBits.1Password`          |
| Tailscale                                                        | winget                            | `Tailscale.Tailscale`          |
| Zed                                                              | winget                            | `ZedIndustries.Zed`            |
| Raycast                                                          | Microsoft Store                   | `9PFXXSHC64H3`                 |
| Windows HDR Calibration                                          | Microsoft Store                   | `9N7F2SM5D1LR`                 |
| Dolby Access                                                     | Microsoft Store                   | `9N0866FS04W8`                 |
| Xbox Accessories                                                 | Microsoft Store                   | `9NBLGGH30XJ3`                 |
| MoonDeck Buddy                                                   | GitHub release                    | `FrogTheFrog/moondeck-buddy`   |
| NVIDIA App                                                       | Chocolatey                        | `nvidia-app`                   |
| NVIDIA game-ready driver                                         | NVIDIA, via `src/run.ps1`         | -                              |
| DXL (DLSS eXtended Loader)                                       | GitHub release, via `src/dxl.ps1` | `LCPD15/DXL`                   |
| WinNUT-Client (UPS monitoring, see [below](#nut-ups-monitoring)) | winget (user scope)               | `nutdotnet.WinNUT`             |

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
- **DXL** ([`LCPD15/DXL`](https://github.com/LCPD15/DXL)) is updated by
  [`src/dxl.ps1`](src/dxl.ps1), driven from the same `Update-Gaming-PC` task as
  the NVIDIA driver above, to `~/developer/tools/dxl`. Its release zip
  (`DXL-v<version>-win64.zip`) has a single version-named top-level folder,
  which extraction flattens away so `dxl/` holds the application files
  directly; idempotency compares the installed `PACKAGE_MANIFEST.json`
  version against the latest release tag, the same shape as MoonDeck Buddy and
  the NVIDIA driver above. DXL's own README documents no elevation
  requirement, confirmed by running a real downloaded release, so unlike
  `Update-Gaming-PC` (SYSTEM, headless), the `Start-DXL` task that launches it
  runs at normal privilege in the logged-in user's own session (`install.ps1`)
  - a GUI app that injects into games needs the interactive desktop, which a
    SYSTEM-run task cannot reach. [`src/start-dxl.ps1`](src/start-dxl.ps1) is
    also installed for starting DXL by hand; it no-ops if DXL is already running
    and minimizes the window after launch.
  - The deploy empties `developer\tools` before copying `src/` in, but skips
    `dxl/`: DXL runs from there, so its exe is locked and deleting it fails the
    deploy. `dxl.ps1` owns that folder, so DXL keeps running untouched through a
    deploy and still updates through `Update-DXL` when a release is newer.

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

## Metrics and sensors

The machine's sensors and frame rate go to the cluster's VictoriaMetrics, so the
Gaming PC dashboard in Grafana can show temperatures getting hot before they
become a problem, next to the FPS and the game that was running.

| Hardware | What it is                                                  |
| -------- | ----------------------------------------------------------- |
| CPU      | AMD Ryzen 9 9950X3D (Tjmax 95 C)                            |
| Board    | ASUS ROG Crosshair X670E Hero                               |
| GPU      | NVIDIA GeForce RTX 5090 (`src/config.json`, rated for 90 C) |

Recorded here because LibreHardwareMonitor and the temperature thresholds depend
on them.

### What runs on the PC

[`src/monitoring.ps1`](src/monitoring.ps1) installs and converges three things.
The deploy task `Install and configure the metrics exporters` runs it, and its
last line (`RESULT changed=N warnings=N failures=N`) is what the task reads.
Everything is pinned to an exact version and SHA-256 (the digest GitHub publishes
for the release asset), so a deploy installs exactly those bits. To bump one, edit
the version, URL and hash at the top of the script.

| Piece                                                                                                                                          | Gives                                                                                                                                                                                                                                                                                                                                                                                   | Cost and risk                                                                                                                                     |
| ---------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| **windows_exporter** 0.32.1, port 9182, collectors `cpu,gpu,memory,textfile`                                                                   | GPU temperature, fan, power, clocks, utilisation and VRAM, CPU load and clocks, memory, and the FPS file below                                                                                                                                                                                                                                                                          | User-mode Windows service, no kernel driver. The GPU sensors come from the Windows graphics kernel, the same source Task Manager uses.            |
| **PresentMon** 2.6.0 console, started at boot by the `Gaming-PC-FPS` task as SYSTEM, wrapped by [`src/fps-exporter.ps1`](src/fps-exporter.ps1) | Frame times through event tracing (ETW), summarised by [`src/fps-summary.ps1`](src/fps-summary.ps1) every 30 s into `C:\ProgramData\gaming-pc\monitoring\textfile\gaming-pc-fps.prom`: `gaming_pc_fps_average`, `gaming_pc_fps_1pct_low`, `gaming_pc_frametime_p99_milliseconds`, `gaming_pc_frametime_max_milliseconds`, `gaming_pc_frames_total` and `gaming_pc_active_app_info{app}` | It does not inject into or hook any game. The file is empty when no game is running, so the series disappear instead of freezing.                 |
| **OhmGraphite** 0.38.0, port 4445, Prometheus pull mode                                                                                        | CPU temperature only (`ohm_cpu_celsius`, plus package power and clocks)                                                                                                                                                                                                                                                                                                                 | A second reader of the same LibreHardwareMonitor stack FanControl already runs, through the PawnIO driver FanControl installs. It adds no driver. |

Where things live: `C:\Program Files\windows_exporter`, `C:\Program Files\OhmGraphite`
and `C:\ProgramData\gaming-pc\monitoring` (PresentMon, the two FPS scripts, the
textfile directory and `fps-exporter.log`). The monitoring directory is locked to
administrators, because a SYSTEM task runs the scripts in it and windows_exporter
reads its textfile directory. The scripts are copied there out of
`developer\tools` because the deploy empties and refills that directory (every entry
except `dxl`, which stays untouched).

### Why these, and what each is not

- **FanControl is not replaced and not read.** It has no export path (no API, log
  or shared memory, and its plugin API only injects sensors into it), so the CPU
  temperature needs a second reader. OhmGraphite is scoped to the CPU class only:
  the GPU, motherboard (Super I/O and embedded controller), storage, RAM, network,
  controller, PSU and battery classes are all switched off in its config, so
  LibreHardwareMonitor never opens them. The Super I/O and embedded controller are
  what FanControl is controlling fans through, and storage SMART reads are the
  classic in-game hitch, so none of them is polled. As a result **fan speeds other
  than the GPU's and motherboard temperatures are not exported.**
- **The GPU is read through the Windows graphics kernel, not NVAPI.** LibreHardwareMonitor
  issue 598 ties NVAPI GPU polling to in-game stutter on an RTX 3090, and FanControl
  already polls the card at 1 Hz, so a second NVAPI reader is the one to avoid.
- **RTSS and Afterburner are not used for FPS.** They hook into the game process,
  and games with an anti-cheat have been reported to block or flag them. PresentMon
  only traces ETW events.
- **No hotspot or 12V-2x6 connector temperature.** NVIDIA does not expose the
  hotspot on Blackwell, and a standard RTX 5090 has no connector sensor. The
  connector can run hotter than the core reads, so the GPU temperature alerts
  protect the core and the fans, not the connector.

### Gameplay cost

None of this has been measured on the machine yet. What is known:

- **The FPS summariser** costs about 6 microseconds of CPU per frame line (measured
  by feeding 500,000 lines to PowerShell 7.6 on an Apple M-series Mac, so only the
  order of magnitude carries over). At 300 lines a second that is under 0.2% of one
  core. Both it and PresentMon run at below-normal priority.
- **windows_exporter** is scraped every 30 s. The `gpu` collector has no switch to
  skip its per-process counters, so each scrape reads all GPU engine and memory
  instances; vmagent drops the per-process series, which saves storage but not
  that work. The same data feeds Task Manager.
- **Always-on ETW tracing** has no independent benchmark. Intel's 2.6.0 notes claim
  78% less CPU than 2.5, with no absolute figure.
- **OhmGraphite** only reads sensors when scraped (30 s), CPU class only.

Measure before trusting it, with PresentMon capturing frame times from a built-in
game benchmark or a fixed route, three runs per arm, alternating the order:

1. Everything stopped: `Stop-ScheduledTask Gaming-PC-FPS`, then `Stop-Service windows_exporter, OhmGraphite`.
2. `windows_exporter` only.
3. Everything running.

```powershell
.\PresentMon-2.6.0-x64.exe --process_name <game>.exe --timed 300 --delay 20 --terminate_after_timed --no_console_stats --output_file C:\temp\run.csv
```

Compare the 99.9th percentile frame time, the maximum and the count of frames
over twice the median, not the average FPS: a periodic sensor hitch hardly moves
the average. If the hitches land at multiples of the scrape interval, the scrape
is the cause. PresentMon is itself an ETW observer in every arm, so the first arm
cannot isolate the always-on tracing cost; use the game's own benchmark summary
for that comparison.

### Anti-cheat

- **windows_exporter** and **PresentMon** load no kernel driver and do not touch the
  game process. PresentMon issue 573 shows an anti-cheat (EA AntiCheat) can refuse
  a _new_ ETW trace session once it is running, which is why the capture starts at
  boot, before any game. If the task is restarted while such a game is open, the
  new session can be refused and FPS is simply missing for that game.
- **OhmGraphite** only listens on 4445 when its config says `type` is `prometheus`;
  without that key it defaults to Graphite push and the service runs with the port
  closed. `tests/ohmgraphite-config.test.ps1` pins the generated config.
- **OhmGraphite** uses PawnIO, which FanControl has already put on the machine.
  FACEIT was reported to block PawnIO and FanControl's README says that was fixed
  in PawnIO 2.1.0. If a game ever complains about FanControl, stop the
  `OhmGraphite` service the same way.

### Checks on the first deploy

`monitoring.ps1` turns these into warnings in the deploy output, and none of them
fails the deploy:

- `windows_exporter` must report `windows_gpu_temperature_celsius` for the RTX 5090
  from a service account. This is unverified on this card: the collector's author
  tested a GTX 1070. If it is missing, fall back to `nvidia_gpu_exporter`.
- `OhmGraphite` must report `ohm_cpu_celsius`. If it does not, check the PawnIO
  driver (`HKLM:\SYSTEM\CurrentControlSet\Services\PawnIO`) and
  `C:\Program Files\OhmGraphite\OhmGraphite.log`.
- PresentMon accepts `--no_track_display --no_track_gpu --no_track_input`
  together (documented, not yet run) and writes `Application` and
  `MsBetweenPresents` columns. `fps-exporter.log` records its messages.
- vmagent's scrapes arrive from the cluster node's address. The firewall rules
  allow only `k8s/ip`; if the cluster's network does not source-NAT pod traffic,
  the scrape is blocked and the rules need the pod network instead.

### Cluster side

- **Scrape job.** [`deployments/production/metrics/gaming-pc-scrape.yaml`](../../deployments/production/metrics/gaming-pc-scrape.yaml)
  adds a `gaming-pc` job (30 s, one target per exporter, labelled `exporter`) to
  vmagent in production. The PC's address comes from the `gaming-pc` sealed secret
  (key `ip`, from 1Password `gaming-pc/ip`) through the `GAMING_PC_IP` environment
  variable, so no address is committed. The secret is optional: until it exists
  vmagent skips these two targets and keeps running every other job.
- **Seal the secret** (once, as the captain, signed in to 1Password):

  ```bash
  OP_VAULT=<vault> sh -c 'kubectl create secret generic gaming-pc \
    --from-literal="ip=$(op read --no-newline "op://$OP_VAULT/gaming-pc/ip")" \
    --namespace default --dry-run=client -o yaml \
    | kubeseal --format=yaml --cert=resources/sealed-secrets/keys/production.pub' \
    > infrastructure/production/secrets/gaming-pc-sealed.yaml
  ```

  then add `- gaming-pc-sealed.yaml` to `infrastructure/production/secrets/kustomization.yaml`.
  `gaming-pc/ip` is also in the sealed list in `packages/configuration-1password`, so
  `yarn nx g @ha/nx-secrets-generators:seal --env production` produces the same file
  (it reseals every secret). Restart vmagent (recreate the pod) after the secret lands:
  vmagent expands `%{GAMING_PC_IP}` from its environment at startup, and the secret
  reference is optional, so a pod started before the secret existed has no variable
  and skips both gaming-pc targets.

- **Firewall.** `deploy.yml` opens ports 9182 and 4445 on the Private profile to
  `k8s/ip` only, read from 1Password by `scripts/deploy.ts`.
- **Dashboard and alerts.** The `Gaming PC` dashboard is
  [`deployments/base/grafana/dashboards/gaming-pc.json`](../../deployments/base/grafana/dashboards/gaming-pc.json).
  The thermal alert rules are in the alerting
  [README](../../deployments/base/alerting/README.md#gaming-pc). The PC is often
  off, so nothing alerts on it being down, and `TargetDown` skips the `gaming-pc` job.

### Tests

`yarn nx test gaming-pc` runs [`tests/fps-summary.test.ps1`](tests/fps-summary.test.ps1)
(the summariser, with a fake clock and no PresentMon; needs `pwsh`),
[`tests/ohmgraphite-config.test.ps1`](tests/ohmgraphite-config.test.ps1) (the generated
OhmGraphite config; needs `pwsh`) and the `vmalert-tool` tests for the alert rules in
[`tests/gaming-pc-rules.test.yaml`](tests/gaming-pc-rules.test.yaml) (needs Docker
and `yq`). All run in the pull request checks.

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
| Dia cannot be relaunched by a push         | `LetAppsRunInBackground_ForceDenyTheseApps` machine policy, see [Dia stays closed](#dia-stays-closed)                     |
| Dark mode                                  | `AppsUseLightTheme` / `SystemUsesLightTheme`                                                                              |
| All desktop icons hidden                   | `HideIcons`                                                                                                               |
| Taskbar widgets off                        | `Dsh\AllowNewsAndInterests` policy                                                                                        |
| UAC off                                    | `EnableLUA`, `ConsentPromptBehaviorAdmin`, `PromptOnSecureDesktop`                                                        |
| Zed as the default text and code editor    | `DefaultAssociationsConfiguration` policy, 139 file types                                                                 |
| Xbox Game Bar off                          | `GameDVR_Enabled`, `AppCaptureEnabled`, plus the `AllowGameDVR` machine policy                                            |
| Auto HDR on                                | `AutoHDREnable=1` merged into the `DirectXUserGlobalSettings` string, preserving any other keys already in it             |
| WiFi off                                   | `Disable-NetAdapter` on adapters with `MediaType -eq 'Native 802.11'` - this machine is wired-only                        |

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

### Dia stays closed

Dia is not part of this deploy. Its package manifest declares a push COM server.
When Dia's backend sends a Windows Push Notification Service (WNS) raw
notification while Dia is closed, Windows starts
`Dia.exe ----WindowsAppRuntimePushServer: -Embedding` through the DCOM launcher.
The full browser then opens over the desktop, on top of the animated background
this couch PC shows when no game is running.

Turning toasts off does not stop this, because a raw notification has no UI. The
deploy denies background activity for Dia's package family name instead, with the
`LetAppsRunInBackground_ForceDenyTheseApps` machine policy. Other apps keep their
pushes, including the Xbox app. The policy is machine scope and keyed by package
family name, so it writes no per-user hive.

**This is unverified, and the confidence is medium-low.** Microsoft documents
background access as the control for
[raw notification background tasks](https://learn.microsoft.com/en-us/windows/apps/develop/notifications/push-notifications/raw-notification-overview)
and
[enterprise background activity](https://learn.microsoft.com/en-us/windows/application-management/enterprise-background-activity-controls).
The Windows App SDK push design says it runs on the same background
infrastructure and follows enterprise policies. Nothing documents the control for
a full-trust app like Dia, though. One
[Microsoft Q&A thread](https://learn.microsoft.com/en-us/answers/questions/5955952/can-a-packaged-with-external-location-winui-2-c-wi)
reports a packaged desktop app whose push COM server still started while
background access was denied.

To test it, close Dia and wait for a push. Event 1010 for Dia in the
`Microsoft-Windows-PushNotification-Platform/Operational` log shows the push
arrived. Event 2033 ("A raw notification has activated a background task") and a
new `Dia.exe ----WindowsAppRuntimePushServer: -Embedding` process after it mean
the block did not work.

**Fallback, not applied:** the `NoCloudApplicationNotification` machine policy
turns off the connection between Windows and WNS, so no app receives a push.
[Microsoft documents it](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-notifications)
as device scope, covering raw notifications, with no restart needed. It could also
stop the Xbox app's invites, party and message alerts, Armoury Crate, and pushes
sent from another device such as a remote install. Replace the Dia task in
[`scripts/deploy.yml`](scripts/deploy.yml) with this one only if the Dia-only
block fails:

```yaml
- name: Turn off WNS push so a closed app cannot be relaunched by a raw notification
  win_regedit:
    path: HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications
    name: NoCloudApplicationNotification
    data: 1
    type: dword
  become: yes
  become_method: runas
  vars:
    ansible_become_user: "{{ ansible_user }}"
    ansible_become_password: "{{ windows_password }}"
```

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
| `test`       | Runs the FPS summariser tests and the thermal alert rule tests, no machine needed. See [Tests](#tests).                                |

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
`win_copy` is documented as unreliable at detecting a _changed_ existing file
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
