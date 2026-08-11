This project configures the captain's actual, in-use MacBook Pro. Read [README.md](README.md) before changing anything here; it covers the layering on devtools, the application lists, and the manual steps macOS forces.

# Never Deploy From An Agent Session

`nx run andrew-mbp:deploy` mutates the machine the agent is running on: it installs Nix, switches the nix-darwin system generation, installs applications, changes the default browser, and reconfigures Time Machine. Never run it, and never run `darwin-rebuild switch`, the Nix installer, `brew install`, `mas install`, `sudo tmutil ...`, or `src/setup.sh`.

This machine already has a working Time Machine destination. `tmutil setdestination` would overwrite it, so never invoke it - not even with a bogus URL to "see what happens". Test the Time Machine path against stubs instead: point a copy of `src/set-time-machine-destination.tcl` at a fake `tmutil`, and stub `sudo`/`tmutil` when exercising `setup.sh`'s step 5.

Validate with non-mutating commands only:

```bash
nx run andrew-mbp:package                                        # builds dist/, touches nothing else
cd apps/andrew-mbp/src && nix flake check
nix eval --json '.#darwinConfigurations.andrew-mbp.config.homebrew.casks' --apply 'cs: map (c: c.name) cs'
```

`nix eval` and `nix flake check` evaluate and instantiate derivations without building or activating them, so they are safe. `tmutil destinationinfo`, `tmutil isexcluded` and `defaults read /Library/Preferences/com.apple.TimeMachine` are read-only and safe; anything that writes is not.

# Never Print The NAS Password

`NAS_PASSWORD` reaches `setup.sh` through the environment and must never appear on a command line, on disk, or in output - `man tmutil` warns that arguments are world-visible via `ps`. When changing step 5, re-run the leak check: run the step under `bash -x` with a sentinel password and assert the sentinel appears nowhere in stdout or stderr.

# Never Publish A Real Release

`nx run andrew-mbp:publish` creates a public GitHub Release. Treat it as outward-facing and leave it to the captain. `gh-axi release list` and `gh-axi release view` are read-only and safe.

# Verify Every Package Identifier

A wrong cask token or App Store id is a silent no-op on a real machine, not an error. Check against the real source before adding one:

```bash
curl -s https://formulae.brew.sh/api/cask/<token>.json                                  # cask exists
curl -s "https://itunes.apple.com/lookup?bundleId=<bundle.id>&entity=macSoftware"       # App Store id
```

# Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
