#!/usr/bin/env bash
#
# andrew-mbp - take a stock MacBook Pro to a fully configured machine.
#
# Safe to re-run: every step is idempotent and skips work that is already done.
# Nothing outside this directory is read, so this works the same whether it is
# run from a clone of home-ops or from an unzipped release artifact.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# devtools' README installs to ~/developer/repos/devtools. Honour REPO_HOME if
# devtools' own shell config has already set it, so a re-run on a configured
# machine reuses the existing checkout rather than making a second one.
DEVTOOLS_DIR="${REPO_HOME:-$HOME/developer/repos}/devtools"
DEVTOOLS_BRANCH="zsh"
DEVTOOLS_REMOTE="https://github.com/andrew-codes/devtools.git"

os_type="$OSTYPE"
arch_type="$(uname -m)"
[[ $OSTYPE == darwin* ]] && os_type="macos"
if [[ $os_type != "macos" || $arch_type != "arm64" ]]; then
  echo "Error: andrew-mbp supports macOS on Apple Silicon only." >&2
  echo "Detected: $os_type / $arch_type" >&2
  exit 1
fi

echo "==> Step 1: devtools ($DEVTOOLS_BRANCH branch)"
# devtools is the baseline this machine extends: it installs Nix itself, the
# shell, the dotfiles, the CLI toolchain and the agent harness. Rather than
# reimplement any of that, run devtools' own documented install procedure
# (clone, then ./setup.sh) exactly as its README describes.
#
# This also has to happen before anything else, because devtools' setup script
# is what bootstraps Nix on a machine that has none.
if [ -d "$DEVTOOLS_DIR/.git" ]; then
  echo "    checkout exists, fetching $DEVTOOLS_BRANCH"
  git -C "$DEVTOOLS_DIR" fetch --quiet origin "$DEVTOOLS_BRANCH"
  git -C "$DEVTOOLS_DIR" checkout --quiet "$DEVTOOLS_BRANCH"
  # Only fast-forward. Never discard uncommitted local work: devtools is a
  # working checkout the captain edits in place (its configs are symlinked out
  # of it), so a hard reset here would throw away real changes.
  if git -C "$DEVTOOLS_DIR" diff --quiet && git -C "$DEVTOOLS_DIR" diff --cached --quiet; then
    git -C "$DEVTOOLS_DIR" merge --quiet --ff-only "origin/$DEVTOOLS_BRANCH" \
      || echo "    WARNING: could not fast-forward $DEVTOOLS_BRANCH; leaving the checkout as-is."
  else
    echo "    WARNING: $DEVTOOLS_DIR has uncommitted changes; skipping update."
  fi
else
  echo "    cloning into $DEVTOOLS_DIR"
  mkdir -p "$(dirname "$DEVTOOLS_DIR")"
  git clone --branch "$DEVTOOLS_BRANCH" "$DEVTOOLS_REMOTE" "$DEVTOOLS_DIR"
fi

echo "    running devtools' setup.sh"
# devtools' setup.sh installs Determinate Nix if missing, symlinks the checkout
# to ~/.dotfiles, offers to match the configured username to this account,
# trusts Homebrew taps, acquires devtools' own Mac App Store apps, and runs the
# first darwin-rebuild switch. It may prompt: for sudo, and for the username
# rewrite if this account is not the one devtools' flake.nix names.
#
# Step 3 below then re-switches to the andrew-mbp configuration, which is that
# same configuration plus this repo's applications. On a first run that is one
# extra switch; on a re-run both are near no-ops.
"$DEVTOOLS_DIR/setup.sh"

# Everything past here needs nix on PATH. On a first-ever run devtools' setup
# just installed it into this shell's environment without re-execing, so pick
# up the daemon profile if the current shell has not seen it yet.
if ! command -v nix >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi
NIX_BIN="$(command -v nix)"

# Build a tool from devtools' *locked* nixpkgs rather than a floating
# `nixpkgs#...`, so these helpers are pinned alongside everything else on the
# machine and cost no extra download. Mirrors how devtools obtains `mas`.
#
# `path:` for the same reason as step 3 below: a bare path makes nix read the
# git tree and reject anything git does not track, which would break on a
# checkout that merely has an untracked file lying around in it.
nix_tool() {
  "$NIX_BIN" build --no-link --print-out-paths --impure --expr \
    "let f = builtins.getFlake \"path:$DEVTOOLS_DIR\"; \
     in f.inputs.nixpkgs.legacyPackages.aarch64-darwin.$1"
}

echo "==> Step 2: Mac App Store apps"
# See mas-apps.nix: nix-darwin's `homebrew.masApps` cannot install from inside
# activation, so these are acquired here, as the real user, in the real
# per-user launchd session where `mas` can reach StoreAgent.
MAS_BIN="$(nix_tool mas)/bin/mas"

# Emit "<id> <name>" per line; empty when mas-apps.nix is an empty set.
# shellcheck disable=SC2016  # ${n} below is Nix, not shell; it must not expand
"$NIX_BIN" eval --raw --file "$SCRIPT_DIR/mas-apps.nix" \
  --apply 'apps: builtins.concatStringsSep "\n"
    (map (n: (toString apps.${n}) + " " + n) (builtins.attrNames apps))' \
  | while read -r id name || [ -n "$id" ]; do
      # `|| [ -n "$id" ]`: the nix eval output has no trailing newline, so a
      # plain `read` would discard the final (often only) entry.
      [ -n "$id" ] || continue
      echo "    $name ($id)"
      # Run as the invoking user, NOT under sudo -- that is the whole reason
      # this step exists. mas escalates by itself when it has real work to do.
      # Not fatal on failure; setup should still finish.
      "$MAS_BIN" get "$id" \
        || echo "    WARNING: could not acquire $name. Check that the App Store is signed in (mas needs an admin password here)."

      # `mas get` hands the download to the App Store and can return before the
      # app is on disk, so wait for it to land rather than reporting success on
      # a download still in flight. Match on id: the store's display name often
      # differs from the name used here.
      for _ in $(seq 1 60); do
        "$MAS_BIN" list 2>/dev/null | grep -q "^$id " && break
        sleep 5
      done
      "$MAS_BIN" list 2>/dev/null | grep -q "^$id " \
        || echo "    WARNING: $name still not installed after 5 minutes."
    done

echo "==> Step 3: apply the andrew-mbp configuration"
# devtools' setup already switched this machine to devtools' own configuration.
# Switch again to the andrew-mbp configuration, which is that configuration
# extended with applications.nix -- a superset, so nothing devtools installed
# is removed.
#
# --override-input points the flake's `devtools` input at the working checkout
# that ~/.dotfiles resolves to, so the modules evaluated here and the dotfiles
# devtools symlinks out of ~/.dotfiles come from one and the same tree. Without
# it the flake would evaluate the revision pinned in flake.lock while the
# symlinks resolved through the checkout, and the two could drift.
#
# Both flake refs are `path:` on purpose. A bare path inside a git working
# tree makes nix read the *git* tree instead of the directory, and then refuse
# every file git does not track -- which is exactly what happens when this runs
# from the monorepo, where dist/ is gitignored. `path:` reads the directory as
# it is on disk, and is also what makes the devtools override pick up
# uncommitted local edits to that checkout.
DARWIN_REBUILD="$(command -v darwin-rebuild || echo /run/current-system/sw/bin/darwin-rebuild)"
sudo "$DARWIN_REBUILD" switch \
  --flake "path:$SCRIPT_DIR#andrew-mbp" \
  --override-input devtools "path:$DEVTOOLS_DIR"

echo "==> Step 4: default browser"
# LaunchServices handler defaults are per-user and live in the user's launchd
# session, so this cannot be an activation script -- nix-darwin activation runs
# as root, outside that session. It has to happen here, as the invoking user.
#
# macOS shows a one-time confirmation dialog when an application other than the
# current default asks to become the default browser. That prompt cannot be
# suppressed, and is not faked here: if it is dismissed or ignored, the check
# below reports it and the machine is left on its existing browser.
DEFAULTBROWSER_BIN="$(nix_tool defaultbrowser)/bin/defaultbrowser"
current_browser() { "$DEFAULTBROWSER_BIN" | awk '/^\*/ { print $2 }'; }

if [ "$(current_browser)" = "dia" ]; then
  echo "    Dia is already the default browser"
elif ! "$DEFAULTBROWSER_BIN" | grep -qE '^[* ] dia$'; then
  echo "    WARNING: Dia is not registered as an http handler yet."
  echo "    Launch Dia once so macOS registers it, then re-run this script."
else
  echo "    setting Dia as the default browser (macOS will ask you to confirm)"
  "$DEFAULTBROWSER_BIN" dia || true
  if [ "$(current_browser)" = "dia" ]; then
    echo "    Dia is now the default browser"
  else
    echo "    WARNING: default browser is still '$(current_browser)'."
    echo "    macOS requires confirming this change by hand:"
    echo "      System Settings > Desktop & Dock > Default web browser > Dia"
  fi
fi

echo "==> Done."
