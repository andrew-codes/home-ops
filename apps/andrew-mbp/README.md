# andrew-mbp

Declarative setup for the captain's MacBook Pro, as a [nix-darwin](https://github.com/nix-darwin/nix-darwin) configuration.

Takes a stock Apple Silicon Mac to a fully configured machine with one command, and is safe to re-run on a machine that is already configured.

## What it manages

This configuration does not stand alone. [devtools](https://github.com/andrew-codes/devtools) (the `zsh` branch) already defines a complete nix-darwin system for this machine - the shell, dotfiles, CLI toolchain, macOS defaults and agent harness. `andrew-mbp` **extends that exact configuration** with the applications below.

macOS activates exactly one nix-darwin system generation at a time, so `andrew-mbp` is deliberately not a second configuration running alongside devtools. `flake.nix` uses `extendModules` to re-evaluate devtools' own `darwinConfigurations."mac"` with one extra module, so nothing devtools declares is dropped and devtools' internals never need to be duplicated here.

### Applications added here

Installed as Homebrew casks, declared in [`src/applications.nix`](src/applications.nix):

| App                  | Cask                    |
| -------------------- | ----------------------- |
| Dia browser          | `thebrowsercompany-dia` |
| Discord              | `discord`               |
| Atlassian Loom       | `loom`                  |
| Microsoft Excel      | `microsoft-excel`       |
| Microsoft PowerPoint | `microsoft-powerpoint`  |
| Microsoft Word       | `microsoft-word`        |
| Moonlight            | `moonlight`             |
| OneDrive             | `onedrive`              |
| Snagit               | `snagit`                |
| Steam                | `steam`                 |
| Tailscale            | `tailscale-app`         |
| Zed                  | `zed`                   |
| Zoom                 | `zoom`                  |

Installed from the Mac App Store, declared in [`src/mas-apps.nix`](src/mas-apps.nix):

| App                                | App Store ID |
| ---------------------------------- | ------------ |
| PDF Expert                         | `1055273043` |
| Windows App (Microsoft RDP client) | `1295203466` |

**Microsoft Office is installed per app on purpose.** The `microsoft-office` cask is a single bundle installer that also lays down OneNote, Outlook and Teams with no supported way to exclude them. The individual `microsoft-word` / `microsoft-excel` / `microsoft-powerpoint` casks are the only way to get those three alone, so that is what is used.

**Lens is not listed here.** devtools already installs the `lens` cask in its own `homebrew.casks`; devtools owns it, and declaring it again would be a duplicate.

**Tailscale is `tailscale-app`, not `tailscale`.** Homebrew's `tailscale` is now the CLI-only formula; the GUI app is `tailscale-app`.

## Deploying

```bash
NAS_HOST=<nas-ip-or-hostname> \
NAS_USERNAME=<nas-user> \
NAS_PASSWORD="$(op read 'op://…')" \
  nx run andrew-mbp:deploy
```

That runs `src/setup.sh` straight out of the working tree against this machine.

The three `NAS_*` variables configure the Time Machine destination and are **required** - see [Time Machine](#time-machine-backups-to-the-nas). `setup.sh` checks all three before it changes anything, and if any is missing it names every missing one at once and exits non-zero without touching the machine. Read `NAS_PASSWORD` from your password manager rather than typing it, so it never lands in shell history.

### What the bootstrap does on a clean machine

Beyond the `git` used to clone this repo, nothing needs to be preinstalled - not Nix, not Homebrew, not `mas`, not Nx. `setup.sh`:

1. **devtools.** Clones `andrew-codes/devtools` (`zsh` branch) to `~/developer/repos/devtools`, or fast-forwards it if it is already there, then runs devtools' own `setup.sh` exactly as devtools' README documents. That is what installs [Determinate Nix](https://determinate.systems/) on a machine with no Nix, symlinks the checkout to `~/.dotfiles`, trusts Homebrew taps, acquires devtools' own App Store apps, and runs the first `darwin-rebuild switch`. Homebrew itself is installed by `nix-homebrew` during that switch.
2. **Mac App Store apps.** Runs `mas get` for each entry in `mas-apps.nix`, then waits for the download to land.
3. **The andrew-mbp configuration.** `darwin-rebuild switch` onto `andrew-mbp`, which is devtools' configuration plus `applications.nix` - a superset, so nothing devtools installed is removed.
4. **Default browser.** Sets Dia as the `http`/`https` handler.
5. **Time Machine.** Points Time Machine at the NAS and enables hourly backups on battery as well as AC.

Before any of that, it validates the `NAS_*` environment variables, so a missing credential fails while the machine is still untouched rather than four steps in.

An existing checkout with uncommitted changes is never reset - devtools is a working checkout whose configs are symlinked out of it, so local edits are left alone and a warning is printed instead.

Step 3 passes `--override-input devtools path:~/developer/repos/devtools`, so the modules evaluated here and the dotfiles devtools symlinks out of `~/.dotfiles` always come from one and the same tree. The revision pinned in `flake.lock` is only the fallback used when the flake is evaluated on its own.

### One-time manual steps macOS forces

These cannot be automated away, and are not faked:

- **Sign in to the Mac App Store first.** `mas` cannot authenticate on its own. If you are not signed in, `mas get` warns and the App Store apps are skipped; re-run after signing in.
- **Confirm the default browser.** macOS shows a confirmation dialog when an app other than the current default asks to become the default browser. If it is dismissed, `setup.sh` says so and leaves the existing browser alone. Set it by hand at _System Settings > Desktop & Dock > Default web browser > Dia_, or re-run.
- **Launch Dia once if it has just been installed.** macOS only registers an app as an `http` handler after it has run at least once. `setup.sh` detects this case and tells you to launch Dia and re-run.
- **`sudo`.** `darwin-rebuild switch` and every `tmutil` call need it, so the deploy is interactive.
- **Full Disk Access.** `man tmutil` states that `setdestination` "Requires root and Full Disk Access privileges". Grant it to the terminal you run the deploy from, at _System Settings > Privacy & Security > Full Disk Access_. This is a one-time approval that cannot be scripted, because the approval dialog is what authorises the scripting.
- **devtools' own manual steps.** `~/.env` secrets, `~/.gitconfig.local` signing key, and `twg login`. See devtools' README.
- **TCC / permission prompts.** Screen recording for Snagit and Loom, and the Tailscale system extension, are approved on first launch of each app.

## Time Machine backups to the NAS

Backs up to the NAS share at `/Volume1/backup` over SMB, automatically, every hour, on battery as well as mains.

> **The NAS becomes the _only_ Time Machine destination.** Configuring the destination **replaces** the destination list rather than adding to it, so any other destination already set on this machine - a local backup disk, an older NAS - is removed. That is deliberate: appending would leave a superseded destination in the rotation and Time Machine would go on choosing it, which is exactly the silent stale-backup failure this step exists to prevent. If you want a second destination, add it back by hand after the setup, and expect the next run to remove it again.

### Configuration

| Variable       | Required                 | Meaning                              |
| -------------- | ------------------------ | ------------------------------------ |
| `NAS_HOST`     | yes                      | Hostname or IP of the NAS            |
| `NAS_USERNAME` | yes                      | NAS account Time Machine backs up as |
| `NAS_PASSWORD` | yes                      | That account's password              |
| `NAS_SHARE`    | no, defaults to `backup` | SMB share name                       |

All three required variables are validated **before any change is made**. If any is unset, `setup.sh` names every missing one in a single message and exits non-zero. It never prompts and never guesses a default, because a wrong Time Machine destination fails silently rather than loudly.

The same environment-variable contract applies whether `setup.sh` is run directly or through `nx run andrew-mbp:deploy`, which inherits the environment. The repo's 1Password-backed configuration API has a `nas/ip` entry but no NAS username or password, so wiring the deploy through it would mean inventing secrets that do not exist yet; if those are added later, `scripts/deploy.ts` is the place to read them and export them into the environment.

**Protocol and share name.** `/Volume1/backup` is read as SMB share `backup` - on a Synology, `/volume1` is the underlying volume and `backup` is the shared folder, and an SMB URL addresses the share, not the volume path. This is not a guess: it matches the destination already configured on this machine, whose URL ends in `/backup`. `NAS_SHARE` overrides it if that ever stops holding.

### How the password is handled

`tmutil setdestination` accepts the password inside the destination URL, and its own man page warns against exactly that: "all arguments provided to a program are visible by all users on the system via the `ps` tool". So the password is never put on a command line.

Instead `setup.sh` pipes it to [`set-time-machine-destination.tcl`](src/set-time-machine-destination.tcl), which feeds it to `tmutil`'s `-p` non-echoing prompt. That prompt is `getpass(3)` - confirmed by the symbols `/usr/bin/tmutil` imports - which reads from `/dev/tty` rather than stdin, which is why driving it needs a pty rather than a plain pipe.

The result:

- never on a command line, so never in `ps`
- never written to disk, and never committed
- never echoed or logged; `xtrace` is turned off around the whole credential path, so `bash -x setup.sh` cannot leak it either
- stored by `tmutil` itself in the **system keychain**, which is what lets `backupd` remount the share unattended

### Keeping the destination available

A network Time Machine destination is mounted by `backupd` when a backup is due, using that system-keychain credential, and unmounted afterwards. That is the macOS-native mechanism for surviving reboots and network drops - so there is deliberately no separate automount or persistent mount here, which would only contend with `backupd` over the same share.

### Exclusions

This configuration **adds no exclusions**, and there are none of its own to remove.

That is not the same as nothing being excluded. macOS enforces its own exclusion list - the sealed system volume, swap, and various caches - and no tool can remove those. `setup.sh` prints the verdict for a few representative paths after configuring; check any path yourself with:

```bash
tmutil isexcluded /path/to/check
```

### What was verified, and what was not

Every key written here was read off a live macOS 26.5.2 system (`defaults read /Library/Preferences/com.apple.TimeMachine`) rather than recalled, because these have moved between releases: `AutoBackupInterval` (seconds, `3600` for hourly) and `RequiresACPower` (`false` to keep backing up on battery).

The configuration has **never been applied on a machine** - see [AGENTS.md](AGENTS.md). The real `tmutil` calls were deliberately not executed.

What _is_ covered is committed and repeatable, in [`tests/time-machine-step.test.sh`](tests/time-machine-step.test.sh) (`nx run andrew-mbp:test`): the `NAS_*` validation failing closed before anything changes, the idempotency check reconfiguring on a changed host, user or share rather than keeping a stale destination, the destination list being replaced rather than appended to (`-a` is asserted absent, so reintroducing it fails the tests), the password never appearing under `bash -x`, and the expect script's prompt handling, guards and exit-code propagation - all against stubs and a fake `tmutil`. It skips on anything but Apple Silicon macOS, so CI reports a skip rather than a false pass.

### Re-running and `devtools-rebuild`

Both the deploy and `devtools-rebuild` switch this machine's nix-darwin generation, and `andrew-mbp` is the superset of the two. Running `devtools-rebuild` afterwards drops the andrew-mbp layer from the active generation. Because devtools sets `homebrew.onActivation.cleanup = "none"`, the applications themselves stay installed - nothing is uninstalled - and re-running the deploy restores the layer. Prefer the deploy command above on this machine.

## On a brand-new MacBook

There is no release artifact to download - the repo is the source of truth, and updating is `git pull`. On a machine with nothing installed, `git` comes from the Xcode Command Line Tools, which macOS offers to install the first time you run `git`:

```bash
git clone https://github.com/andrew-codes/home-ops.git
cd home-ops/apps/andrew-mbp
NAS_HOST=<nas-ip> NAS_USERNAME=<nas-user> NAS_PASSWORD='<password>' ./src/setup.sh
```

`setup.sh` reads only files sitting next to it, so it runs directly from the clone with no build, packaging or Nx install needed. Nx is only how the deploy is invoked from an already-set-up machine.

## Updating an already-configured machine

```bash
git pull
NAS_HOST=<nas-ip> NAS_USERNAME=<nas-user> NAS_PASSWORD='<password>' ./src/setup.sh
```

or, equivalently, `nx run andrew-mbp:deploy` from the repo root. Re-running is the whole update mechanism: every step is idempotent and skips work already done, so pulling a change that adds one cask installs that cask and leaves everything else alone.

## Adding a new application

| To add                     | Edit                                                                |
| -------------------------- | ------------------------------------------------------------------- |
| A GUI app or Homebrew cask | `homebrew.casks` in [`src/applications.nix`](src/applications.nix)  |
| A Mac App Store app        | [`src/mas-apps.nix`](src/mas-apps.nix), as `"Name" = <numeric id>;` |

Verify the identifier against the real source before adding it - a wrong one is a silent no-op on a real machine:

```bash
# Homebrew cask token
curl -s https://formulae.brew.sh/api/cask/<token>.json | head

# Mac App Store id
mas search "App Name"
```

App Store apps are deliberately kept out of nix-darwin's `homebrew.masApps`; [`src/mas-apps.nix`](src/mas-apps.nix) explains why that option cannot work from inside activation.

If devtools already installs the app, add it in neither place - devtools owns it.

## Nx targets

| Target   | What it does                                                                                                          |
| -------- | --------------------------------------------------------------------------------------------------------------------- |
| `deploy` | Runs `src/setup.sh` against this machine, inheriting the environment so the `NAS_*` variables reach it.               |
| `test`   | Runs [`tests/time-machine-step.test.sh`](tests/time-machine-step.test.sh); skips on anything but Apple Silicon macOS. |

`deploy` is deliberately excluded from `yarn deploy/all` (`--exclude=andrew-mbp` in the root `package.json`), because setting up a machine is a one-at-a-time interactive action - `darwin-rebuild switch`, `mas` and `sudo tmutil` all prompt - rather than a fleet deploy, and it exits non-zero anywhere that is not an Apple Silicon Mac with the `NAS_*` variables set. Keep the exclusion; JSON cannot carry the comment, which is why it is recorded here.

There is no `provision` target. Provisioning a laptop means unboxing it; this configuration only has a deployment phase.

There are no `package` or `publish` targets either. These setups are not shipped as GitHub Release artifacts - a downloadable bundle makes re-running awkward, and `git pull` plus a re-run keeps one obvious source of truth.
