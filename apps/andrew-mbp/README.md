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
nx run andrew-mbp:deploy
```

That builds the self-contained package and runs its `setup.sh` against this machine.

### What the bootstrap does on a clean machine

Nothing needs to be preinstalled - not Nix, not Homebrew, not `mas`, not the Xcode Command Line Tools. `setup.sh`:

1. **devtools.** Clones `andrew-codes/devtools` (`zsh` branch) to `~/developer/repos/devtools`, or fast-forwards it if it is already there, then runs devtools' own `setup.sh` exactly as devtools' README documents. That is what installs [Determinate Nix](https://determinate.systems/) on a machine with no Nix, symlinks the checkout to `~/.dotfiles`, trusts Homebrew taps, acquires devtools' own App Store apps, and runs the first `darwin-rebuild switch`. Homebrew itself is installed by `nix-homebrew` during that switch.
2. **Mac App Store apps.** Runs `mas get` for each entry in `mas-apps.nix`, then waits for the download to land.
3. **The andrew-mbp configuration.** `darwin-rebuild switch` onto `andrew-mbp`, which is devtools' configuration plus `applications.nix` - a superset, so nothing devtools installed is removed.
4. **Default browser.** Sets Dia as the `http`/`https` handler.

An existing checkout with uncommitted changes is never reset - devtools is a working checkout whose configs are symlinked out of it, so local edits are left alone and a warning is printed instead.

Step 3 passes `--override-input devtools path:~/developer/repos/devtools`, so the modules evaluated here and the dotfiles devtools symlinks out of `~/.dotfiles` always come from one and the same tree. The revision pinned in `flake.lock` is only the fallback used when the flake is evaluated on its own.

### One-time manual steps macOS forces

These cannot be automated away, and are not faked:

- **Sign in to the Mac App Store first.** `mas` cannot authenticate on its own. If you are not signed in, `mas get` warns and the App Store apps are skipped; re-run after signing in.
- **Confirm the default browser.** macOS shows a confirmation dialog when an app other than the current default asks to become the default browser. If it is dismissed, `setup.sh` says so and leaves the existing browser alone. Set it by hand at _System Settings > Desktop & Dock > Default web browser > Dia_, or re-run.
- **Launch Dia once if it has just been installed.** macOS only registers an app as an `http` handler after it has run at least once. `setup.sh` detects this case and tells you to launch Dia and re-run.
- **`sudo`.** `darwin-rebuild switch` needs it, so the deploy is interactive.
- **devtools' own manual steps.** `~/.env` secrets, `~/.gitconfig.local` signing key, and `twg login`. See devtools' README.
- **TCC / permission prompts.** Screen recording for Snagit and Loom, and the Tailscale system extension, are approved on first launch of each app.

### Re-running and `devtools-rebuild`

Both the deploy and `devtools-rebuild` switch this machine's nix-darwin generation, and `andrew-mbp` is the superset of the two. Running `devtools-rebuild` afterwards drops the andrew-mbp layer from the active generation. Because devtools sets `homebrew.onActivation.cleanup = "none"`, the applications themselves stay installed - nothing is uninstalled - and re-running the deploy restores the layer. Prefer the deploy command above on this machine.

## From a release instead of the monorepo

The motivating case is a brand-new MacBook with no clone of home-ops and no Nx:

1. Download `andrew-mbp.zip` from the [latest release](https://github.com/andrew-codes/home-ops/releases).
2. Unzip it.
3. `cd andrew-mbp && ./setup.sh`

The package is self-contained: the flake, its lock, the nix modules, `setup.sh` and this README are all inside it, and nothing in it references the monorepo or assumes Nx exists.

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

| Target    | What it does                                                                                           |
| --------- | ------------------------------------------------------------------------------------------------------ |
| `package` | Builds the self-contained `dist/andrew-mbp/` and zips it to `dist/andrew-mbp.zip`.                     |
| `publish` | Uploads `dist/andrew-mbp.zip` as a GitHub Release asset via `gh-axi`. Skips if the tag already exists. |
| `deploy`  | Runs the packaged `setup.sh` against this machine.                                                     |

There is no `provision` target. Provisioning a laptop means unboxing it; this configuration only has a deployment phase.

`deploy` declares its own `dependsOn` rather than inheriting the workspace default, which chains `publish` ahead of `deploy`. Deploying a laptop should not cut a GitHub release, so here `deploy` depends on `package` only.
