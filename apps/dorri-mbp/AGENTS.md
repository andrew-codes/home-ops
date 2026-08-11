This project configures a second, real, in-use MacBook Pro belonging to somebody other than the captain. Read [README.md](README.md) before changing anything here; it covers why this app does not build on devtools, the application list, the account contract, and the manual steps macOS forces.

# Never Deploy From An Agent Session

`nx run dorri-mbp:deploy` mutates the machine the agent is running on: it installs Nix and Homebrew, switches the nix-darwin system generation, installs applications, turns Spotlight off, and creates an administrator account. Never run it, and never run `darwin-rebuild switch`, the Nix installer, `brew install`, `mdutil -i off`, or `src/setup.sh`.

# Never Create Or Modify A User Account

`sysadminctl`, `dscl . -create`, `dseditgroup -o edit` and `createhomedir` create or alter real login accounts on whatever machine they run on. Never invoke them - not even "to see what happens". [`tests/setup.test.sh`](tests/setup.test.sh) already exercises that path against stubs and a fake `sysadminctl`; extend it rather than running anything for real.

Reading is fine: `strings`/`nm` on the binaries, `id -u`, and `dseditgroup -o checkmember` are read-only.

Validate with non-mutating commands only:

```bash
nx run dorri-mbp:test                                            # stubbed; skips off Apple Silicon macOS
cd apps/dorri-mbp/src && nix flake check
nix eval --json '.#darwinConfigurations.dorri-mbp.config.homebrew.casks' --apply 'cs: map (c: c.name) cs'
nix eval --raw '.#darwinConfigurations.dorri-mbp.config.system.primaryUser'
```

`nix eval` and `nix flake check` evaluate and instantiate derivations without building or activating them, so they are safe.

# Never Print The Admin Password

`ADMIN_PASSWORD` reaches `setup.sh` through the environment and must never appear on a command line, on disk, or in output - all arguments to a program are world-visible via `ps`. Beware command substitutions inside the credential pipeline: they inherit the password on stdin. `nx run dorri-mbp:test` includes the sentinel leak check; re-run it after any change to step 3.

# Verify Every Package Identifier

A wrong cask token is a silent no-op on a real machine, not an error. Check against the real source before adding one:

```bash
curl -s https://formulae.brew.sh/api/cask/<token>.json                                   # cask exists
```

# `src/primary-user.txt` Has Two Readers

`flake.nix` reads it to decide who owns Homebrew; `setup.sh` reads it with `tr` before Nix exists and refuses to run when it disagrees with `id -un`. Change the parsing on one side and you have to change it on the other.

# Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
