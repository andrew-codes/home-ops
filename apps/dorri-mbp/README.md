# dorri-mbp

Declarative setup for a second MacBook Pro, as a [nix-darwin](https://github.com/nix-darwin/nix-darwin) configuration.

Takes a stock Apple Silicon Mac to a fully configured machine with one command, and is safe to re-run on a machine that is already configured.

## Relationship to `andrew-mbp`

[`apps/andrew-mbp`](../andrew-mbp) is the same idea for the captain's own laptop, and this app mirrors its layout, its Nx targets and its deployment technology on purpose. It does **not** share its software list, and it deliberately does **not** share its base configuration.

`andrew-mbp` extends [devtools](https://github.com/andrew-codes/devtools), which hardcodes `user = "andrew"` and layers the captain's shell, dotfiles, git identity, CLI toolchain and agent harness onto the machine. That is right for the captain's Mac and wrong for anybody else's, so `dorri-mbp` declares its own small nix-darwin system instead. The Nix release branches are pinned to the same values devtools uses, so both Macs track one generation.

## What it manages

| Concern                                      | Where                                                                                    |
| -------------------------------------------- | ---------------------------------------------------------------------------------------- |
| Nix, nix-darwin, Homebrew                    | [`src/setup.sh`](src/setup.sh), [`src/configuration.nix`](src/configuration.nix)         |
| Applications                                 | [`src/applications.nix`](src/applications.nix)                                           |
| Spotlight indexing off                       | [`src/configuration.nix`](src/configuration.nix)                                         |
| Second administrator account                 | [`src/setup.sh`](src/setup.sh), [`src/create-admin-user.tcl`](src/create-admin-user.tcl) |
| Raycast on cmd+space, Spotlight's hotkey off | [`src/setup.sh`](src/setup.sh)                                                           |

### Applications

Installed as Homebrew casks, declared in [`src/applications.nix`](src/applications.nix):

| App                  | Cask                    |
| -------------------- | ----------------------- |
| 1Password            | `1password`             |
| ChatGPT              | `chatgpt`               |
| Dia browser          | `thebrowsercompany-dia` |
| Logi Options+        | `logi-options+`         |
| Atlassian Loom       | `loom`                  |
| Microsoft Excel      | `microsoft-excel`       |
| Microsoft Outlook    | `microsoft-outlook`     |
| Microsoft PowerPoint | `microsoft-powerpoint`  |
| Microsoft Word       | `microsoft-word`        |
| Raycast              | `raycast`               |
| Tailscale            | `tailscale-app`         |
| Zed                  | `zed`                   |
| Zoom                 | `zoom`                  |

Every token was verified against the live Homebrew cask index rather than guessed, because a wrong token is a silent no-op on a real machine rather than an error.

**Office is installed per app, and OneNote is excluded.** The `microsoft-office` cask is a single bundle installer that also lays down OneNote and Teams, with no supported way to exclude them. The four individual casks are the only way to get exactly Outlook, Excel, Word and PowerPoint, so that is what is used. Note Outlook **is** wanted on this machine, unlike on `andrew-mbp`.

**Tailscale is `tailscale-app`, not `tailscale`.** Homebrew's `tailscale` is now the CLI-only formula; the GUI app is `tailscale-app`.

**Nothing comes from the Mac App Store.** Every application on the list ships as a cask, so this app has none of the `mas` machinery `andrew-mbp` needs.

### Both accounts get every application

This machine has two accounts, and all thirteen applications are available to both. That is a property of how they install, not an extra step:

- casks with an `app` artifact (1Password, ChatGPT, Dia, Loom, Raycast, Zed, Zoom) land in `/Applications`
- casks with a `pkg` artifact (Outlook, Excel, Word, PowerPoint, Tailscale) run a system installer with a system-wide receipt
- Logi Options+ runs a vendor installer that writes `/Applications` and `/Library`

None of them is a per-user install. What **is** per-user is each app's own first-run state - sign-in, login items, and the permission prompts macOS raises the first time an app asks for accessibility, screen recording or a system extension. Each account has to do that for itself; see [manual steps](#one-time-manual-steps-macos-forces).

### Zed is installed for both accounts, not just the admin account

The requirement was Zed for the second account only. That is **not cleanly achievable** given how everything else here is installed, so the pre-authorised fallback was taken: Zed is a cask like the rest, and a cask installs into the shared `/Applications`.

Homebrew has no per-account cask install. Its `--appdir` is a property of the Homebrew installation, not of one cask, so pointing Zed at one account's `~/Applications` would move every other app there too. The alternatives - a second Homebrew prefix owned by the other account, or a home-manager profile just for Zed - both mean standing up a whole second installation mechanism for one editor. Neither is worth it, so Zed sits in `/Applications` and is visible to both accounts. Nothing stops the machine's owner from ignoring it.

## Deploying

```bash
ADMIN_USERNAME=andrewsmith \
ADMIN_PASSWORD="$(op read 'op://…')" \
  nx run dorri-mbp:deploy
```

That runs [`src/setup.sh`](src/setup.sh) straight out of the working tree against this machine.

### Configuration

| Variable          | Required                         | Meaning                                              |
| ----------------- | -------------------------------- | ---------------------------------------------------- |
| `ADMIN_USERNAME`  | yes                              | macOS short name of the second administrator account |
| `ADMIN_PASSWORD`  | yes                              | that account's login password                        |
| `ADMIN_FULL_NAME` | no, defaults to `ADMIN_USERNAME` | name shown at the login window                       |

`andrewsmith` above is an example, not a default. **No username or password is hardcoded anywhere in this app**, and there is no fallback if a variable is unset.

Both required variables are validated **before any change is made**. If either is missing, `setup.sh` names every missing one in a single message and exits non-zero. It never prompts and never guesses: this creates a real login account with administrator rights, so a guessed value is a security problem rather than an inconvenience. `ADMIN_USERNAME` is additionally bounded to a macOS short name - letters, digits, underscore and hyphen - because it reaches `dseditgroup`, `createhomedir` and a `/Users` path.

Read `ADMIN_PASSWORD` from your password manager rather than typing it, so it never lands in shell history.

The same contract applies whether `setup.sh` is run directly or through `nx run dorri-mbp:deploy`, which inherits the environment.

### `src/primary-user.txt`

One line, holding the macOS short name of the account that **owns** this machine - the one that runs the setup, and the one nix-darwin installs Homebrew for. It ships as `dorri`.

It is a committed file rather than an environment variable because `flake.nix` has to read it, and a flake cannot read the environment without `--impure`; making a whole system configuration impure to learn one username is a bad trade. `setup.sh` reads the same file with `tr -d '[:space:]'` before Nix is even installed and **refuses to run** when it does not match the account invoking it, so a wrong value is a clear message rather than a Homebrew installation owned by an account that does not exist.

If the machine's account is not called `dorri`, edit that file and commit the change.

### What the bootstrap does on a clean machine

Beyond the `git` used to clone this repo, nothing needs to be preinstalled - not Nix, not Homebrew, not Nx. `setup.sh`:

1. **Validation.** Platform, both `ADMIN_*` variables, the username's shape, and `primary-user.txt`. All of it before anything is touched.
2. **Nix.** Installs [Determinate Nix](https://determinate.systems/) if it is not already there - the same Nix the sibling machine runs. Skipped on a machine that has it.
3. **The dorri-mbp configuration.** Builds this flake's own `darwin-rebuild` if nix-darwin is not installed yet, then `darwin-rebuild switch`. That installs Homebrew (via `nix-homebrew`), every application in `applications.nix`, and turns Spotlight indexing off.
4. **The second administrator account.** Creates it if it does not exist, and puts it in the `admin` group.
5. **Keyboard shortcuts.** Releases cmd+space from Spotlight and gives it to Raycast, for both accounts.

The switch passes `path:` flake references on purpose. A bare path inside a git working tree makes Nix read the _git_ tree rather than the directory on disk, so an uncommitted edit to `applications.nix` would be silently ignored and the last committed version applied instead. Since the update path here is "edit, or `git pull`, then re-run", that silent staleness is exactly the wrong behaviour.

## The second administrator account

"Administrator" means membership in the macOS `admin` group, which is what grants `sudo`. **The root account is not enabled, unlocked or configured** - nothing here touches it.

### Idempotency

Re-running on a machine where the account already exists **does not** re-create it, reset its password, or alter its data. `setup.sh` checks with `id -u` and skips creation entirely.

Admin group membership is the one thing checked and repaired on every run: an account that lost its rights out of band is put back, and one that already has them costs a read (`dseditgroup -o checkmember`).

### How the password is handled

`sysadminctl -addUser` accepts `-password <plaintext>`, and its own usage text says of the sibling flag: _"Use '-' or 'interactive' to get the authentication string interactively. This preferred for security reasons."_ The reason is that all arguments to a program are visible to every user on the system via `ps`. So the password is never put on a command line.

Instead `setup.sh` pipes it to [`src/create-admin-user.tcl`](src/create-admin-user.tcl), which feeds it to `sysadminctl`'s `-password -` non-echoing prompt. That prompt is `getpass(3)` - confirmed by the symbols `/usr/sbin/sysadminctl` imports - which reads from `/dev/tty` rather than stdin, which is why driving it needs a pty rather than a plain pipe. This is the same mechanism, for the same reason, that `andrew-mbp` uses to hand `tmutil` the NAS password.

The result:

- never on a command line, so never in `ps`
- never written to disk, never committed, and never present in any build output - there is no build
- never echoed or logged; `xtrace` is turned off around the whole credential path, so `bash -x setup.sh` cannot leak it either
- stored by macOS as the account's own credential, which is what seeds its login keychain

An empty password is rejected before `sysadminctl` is spawned: macOS refuses it outright on a FileVault machine and silently creates a passwordless account on one without FileVault, and the caller cannot tell those apart afterwards.

### Secure token and FileVault

An account created by `sysadminctl` running as root, with no administrator credential supplied, does **not** get a secure token. On a machine with FileVault enabled that account cannot unlock the disk at boot - it can log in once someone else has unlocked it, but it will not appear at the FileVault pre-boot screen.

This is not automated, because granting a secure token requires an existing token holder's password as well, which is a second credential this setup deliberately does not ask for. If the new account needs to unlock FileVault, grant it by hand from an account that already has a token:

```bash
sysadminctl -secureTokenOn <admin-username> -password - -adminUser <your-username> -adminPassword -
```

## Spotlight and the Raycast hotkey

Raycast is bound to **cmd+space**, and Spotlight is turned off. Those are coupled: cmd+space is Spotlight's default binding, and macOS does not arbitrate a double binding - it just gives the key to Spotlight - so Spotlight's shortcut has to be released first.

**Both halves of "Spotlight off" are implemented**, per the captain's decision:

| Half              | Where                                                           | What it turns off                                                        |
| ----------------- | --------------------------------------------------------------- | ------------------------------------------------------------------------ |
| Indexing          | `mdutil -i off -d /` during nix-darwin activation (best-effort) | The Spotlight index itself                                               |
| Keyboard shortcut | `com.apple.symbolichotkeys` keys 64 and 65                      | cmd+space (Spotlight search) and cmd+option+space (Finder search window) |

### What disabling indexing also breaks

Turning the index off is not only "no Spotlight window". Anything that queries the metadata index degrades or stops:

- Finder's search field and any smart folder or saved search
- content search inside Mail, Notes and other apps that hand off to Spotlight
- `mdfind` on the command line
- Siri and Spotlight suggestions that draw on local files

Raycast has its own file index and does not depend on Spotlight's, so app launching and file search in Raycast still work.

**To reverse it**, on the machine itself:

```bash
sudo mdutil -i on /        # re-enable indexing on the boot volume
sudo mdutil -E /           # rebuild the index from scratch (takes a while)
```

Re-enabling the shortcuts is _System Settings > Keyboard > Keyboard Shortcuts > Spotlight_, ticking both boxes back on. Note that re-running the deploy turns both back off.

### What is automated, and what is not

**Turning indexing off is best-effort.** `mdutil` generally requires Full Disk Access, and activation is not guaranteed to have it, so a failure there prints a warning and lets the rest of the switch finish rather than aborting it and leaving Homebrew and the applications uninstalled. If the deploy prints `warning: Spotlight indexing was NOT disabled`, indexing is still on; finish the job by hand from a terminal granted Full Disk Access (_System Settings > Privacy and Security > Full Disk Access_):

```bash
sudo mdutil -i off -d /
```

Every subsequent deploy tries again, so nothing has to be remembered once the access is granted.

Automated, for **both** accounts:

- writing `enabled = false` for symbolic hotkeys 64 and 65. The write is a `-dict-add`, not a whole-dictionary replacement, so other customised shortcuts survive.
- writing `raycastGlobalHotkey = "Command-49"` (49 is the space keycode) into `com.raycast.macos`. The key and its format were read off a live Raycast install, not recalled.

Not automated, and genuinely not automatable:

- **The shortcut table only reloads for the session that runs the setup.** `setup.sh` calls `activateSettings -u`, which reloads it for the account running the deploy. The second account picks the change up **at its next login** - there is no way to reload another user's session from outside it.
- **Raycast has to be launched once per account.** Until then Raycast is not running, so nothing is listening on cmd+space, and Raycast's first-run onboarding may offer to set a hotkey of its own. Launch it, confirm cmd+space opens it, and if it does not, either set it in Raycast's own settings or re-run the deploy with Raycast quit.
- **Raycast rewrites its preferences when it quits.** If Raycast is running while the deploy writes the hotkey, that write can be undone. `setup.sh` detects a running Raycast and warns; quit it and re-run.

## One-time manual steps macOS forces

These cannot be automated away, and are not faked:

- **`sudo`.** Installing Nix, `darwin-rebuild switch`, and creating the account all need it, so the deploy is interactive.
- **Launch Raycast once per account** and confirm cmd+space - see above.
- **Log in as the second account once** for its keyboard shortcut change to take effect, and for each app's per-user setup.
- **Grant the second account a secure token** if the machine uses FileVault - see above.
- **TCC / permission prompts on first launch of each app**, per account: Loom and Zoom ask for screen recording, camera and microphone; Raycast asks for accessibility; Tailscale installs a system extension that has to be approved in System Settings; Logi Options+ asks for accessibility and installs a driver bundle; 1Password asks to integrate with the browser.
- **Sign in to each application.** Office, 1Password, ChatGPT, Loom, Tailscale and Zoom all need an account, per user.
- **Microsoft AutoUpdate** installs alongside the Office casks and manages Office updates itself; Homebrew does not.

## On a brand-new MacBook

There is no release artifact to download - the repo is the source of truth, and updating is `git pull`. On a machine with nothing installed, `git` comes from the Xcode Command Line Tools, which macOS offers to install the first time you run `git`:

```bash
git clone https://github.com/andrew-codes/home-ops.git
cd home-ops/apps/dorri-mbp
ADMIN_USERNAME=andrewsmith ADMIN_PASSWORD='…' ./src/setup.sh
```

`setup.sh` reads only files sitting next to it, so it runs directly from the clone with no build, packaging or Nx install needed. Nx is only how the deploy is invoked from an already-set-up machine.

## Updating an already-configured machine

```bash
git pull
ADMIN_USERNAME=andrewsmith ADMIN_PASSWORD='…' ./src/setup.sh
```

or, equivalently, `nx run dorri-mbp:deploy` from the repo root.

**Re-running is the whole update mechanism.** Every step is idempotent and skips work already done, so pulling a change that adds one cask installs that cask and leaves everything else alone. Keep the clone; there is nothing else to keep.

To pick up newer upstream Nix, nix-darwin or Homebrew, update the lock file and re-run:

```bash
cd apps/dorri-mbp/src && nix flake update
```

## Adding a new application

Add the cask token to `homebrew.casks` in [`src/applications.nix`](src/applications.nix), then re-run the setup.

Verify the token against the real source first - a wrong one is a silent no-op on a real machine:

```bash
curl -s https://formulae.brew.sh/api/cask/<token>.json | head
```

## Nx targets

| Target   | What it does                                                                                              |
| -------- | --------------------------------------------------------------------------------------------------------- |
| `deploy` | Runs `src/setup.sh` against this machine, inheriting the environment so the `ADMIN_*` variables reach it. |
| `test`   | Runs [`tests/setup.test.sh`](tests/setup.test.sh); skips on anything but Apple Silicon macOS.             |

`deploy` is deliberately excluded from `yarn deploy/all` (`--exclude=andrew-mbp,dorri-mbp,gaming-pc` in the root `package.json`, which also excludes [`apps/andrew-mbp`](../andrew-mbp) and [`apps/gaming-pc`](../gaming-pc) for the same reason), because setting up a machine is a one-at-a-time interactive action - `darwin-rebuild switch`, `sudo` and account creation all prompt - rather than a fleet deploy, and it exits non-zero anywhere that is not an Apple Silicon Mac with the `ADMIN_*` variables set. Keep the exclusion; JSON cannot carry the comment, which is why it is recorded here.

There is no `provision` target. Provisioning a laptop means unboxing it; this configuration only has a deployment phase.

There are no `package` or `publish` targets either. These setups are not shipped as GitHub Release artifacts - a downloadable bundle makes re-running awkward, and `git pull` plus a re-run keeps one obvious source of truth.

## What was verified, and what was not

**The configuration has never been applied to a machine** - see [AGENTS.md](AGENTS.md). No account was created, nothing was installed, and Spotlight was not switched off anywhere in the course of writing this.

Verified without mutating anything:

- every cask token, against the live Homebrew cask index
- `raycastGlobalHotkey = "Command-49"` and symbolic hotkey 64's parameters, read off a live macOS 26 install
- `/usr/sbin/sysadminctl` importing `_getpass`, and its `-addUser` / `-password -` / `-admin` usage text, read out of the binary
- the flake evaluating: `nix flake check`, and `nix eval` of the cask list, `system.primaryUser`, `homebrew.user` and the module assertions

Covered by [`tests/setup.test.sh`](tests/setup.test.sh) (`nx run dorri-mbp:test`), against stubs and a fake `sysadminctl`: the `ADMIN_*` validation failing closed before anything changes and naming every missing variable at once, the username bound to a short name, `primary-user.txt` mismatches failing closed, an existing account never being re-created or having its password reset, the admin group being repaired only when needed, the root account never being touched, the password never appearing in argv or under `bash -x`, cmd+space being released from Spotlight before Raycast claims it for both accounts, and the expect script's prompt handling, guards and exit-code propagation. It skips on anything but Apple Silicon macOS, so CI reports a skip rather than a false pass.

Not verified, because it cannot be without a real machine:

- that `sysadminctl`'s prompt string is `User password:` on every macOS version. Both strings this matches came out of the binary on macOS 26, and a mismatch fails loudly on a timeout rather than silently.
- that Raycast's onboarding respects a hotkey written before its first launch.
- that `mdutil` succeeds without a Full Disk Access prompt when run from activation. Activation runs as root out of launchd, which normally has it, but that has not been observed here. Because it is unverified, the call is best-effort: on failure it warns and the switch continues, and the warning names the manual `sudo mdutil -i off -d /` fallback.
- that the first `darwin-rebuild switch` on this particular machine finds no `/etc` file it wants to manage but did not create. nix-darwin refuses to clobber one, and names the file and the fix (`sudo mv <file> <file>.before-nix-darwin`) when it happens. It is a loud, one-time, first-run failure, not a silent one.
