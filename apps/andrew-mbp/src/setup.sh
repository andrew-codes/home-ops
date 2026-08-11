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

# Time Machine backs up to the NAS over SMB. The share defaults to `backup`,
# which is what the NAS path /Volume1/backup means in SMB terms: on a Synology,
# /volume1 is the underlying volume and `backup` is the shared folder, which is
# what an SMB URL addresses. NAS_SHARE overrides it if that ever stops holding.
NAS_SHARE="${NAS_SHARE:-backup}"

os_type="$OSTYPE"
arch_type="$(uname -m)"
[[ $OSTYPE == darwin* ]] && os_type="macos"
if [[ $os_type != "macos" || $arch_type != "arm64" ]]; then
  echo "Error: andrew-mbp supports macOS on Apple Silicon only." >&2
  echo "Detected: $os_type / $arch_type" >&2
  exit 1
fi

# Validate the NAS credentials up front, before anything has been installed or
# changed, so a missing variable costs nothing to recover from. Report every
# missing variable at once rather than failing on the first and making the user
# re-run three times. Never prompt, never guess a default: the Time Machine
# step configures a real backup destination, and a wrong guess there fails
# silently later.
#
# Deliberately no arrays: /bin/bash on macOS is still 3.2, and `set -u` with an
# empty array is an unbound-variable error there.
missing=""
[ -n "${NAS_HOST:-}" ] || missing="$missing NAS_HOST"
[ -n "${NAS_USERNAME:-}" ] || missing="$missing NAS_USERNAME"
[ -n "${NAS_PASSWORD:-}" ] || missing="$missing NAS_PASSWORD"
if [ -n "$missing" ]; then
  echo "Error: Time Machine needs the NAS credentials, but these environment" >&2
  echo "variables are not set:" >&2
  for var in $missing; do
    echo "  - $var" >&2
  done
  echo "" >&2
  echo "Set all three and re-run. Nothing has been changed on this machine." >&2
  echo "" >&2
  echo "  NAS_HOST      hostname or IP of the NAS" >&2
  echo "  NAS_USERNAME  NAS account Time Machine backs up as" >&2
  echo "  NAS_PASSWORD  that account's password" >&2
  echo "  NAS_SHARE     optional, defaults to '$NAS_SHARE'" >&2
  echo "" >&2
  echo "Keep NAS_PASSWORD out of your shell history - read it from your" >&2
  echo "password manager, e.g. NAS_PASSWORD=\"\$(op read op://...)\"." >&2
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

echo "==> Step 5: Time Machine backups to the NAS"
# Every setting below was verified against a live macOS 26.5.2 configuration
# (`defaults read /Library/Preferences/com.apple.TimeMachine`) rather than
# recalled, because these keys have moved across releases.
#
# tmutil requires root, and also Full Disk Access for the process invoking it -
# see the README. Failures here are surfaced, never swallowed.
TM_URL="smb://${NAS_USERNAME}@${NAS_HOST}/${NAS_SHARE}"

# Turn off xtrace for the whole credential path, so running this under
# `bash -x` cannot dump the password into a terminal or a log.
tm_xtrace=""
case "$-" in
  *x*) tm_xtrace=1; set +x ;;
esac

# destinationinfo needs no privileges, so re-runs cost nothing when the
# destination is already set. Matching on user and share rather than on the
# whole URL is deliberate: macOS reports the host back in its Bonjour form, so
# a destination set as <host> reads back as <host>._smb._tcp.local. and an
# exact URL comparison would never match, reconfiguring on every single run.
tm_existing="$(tmutil destinationinfo 2>/dev/null || true)"
if printf '%s' "$tm_existing" | grep -qF "${NAS_USERNAME}@" &&
  printf '%s' "$tm_existing" | grep -qF "/${NAS_SHARE}"; then
  echo "    destination already configured, leaving it alone"
else
  echo "    configuring destination smb://${NAS_USERNAME}@${NAS_HOST}/${NAS_SHARE}"
  # The password goes over a pipe into expect, which hands it to tmutil's
  # non-echoing prompt. It is never a command-line argument, so it never
  # appears in `ps`; it is never written to disk; and tmutil itself stores it
  # in the system keychain, which is what lets backupd remount the share
  # unattended after a reboot or a network drop.
  #
  # `printf` is a bash builtin, so even this does not fork a process carrying
  # the password in its arguments. sudo reads its own password from /dev/tty
  # rather than stdin, so it does not consume the pipe.
  printf '%s\n' "$NAS_PASSWORD" \
    | sudo "$(nix_tool expect)/bin/expect" -f \
      "$SCRIPT_DIR/set-time-machine-destination.tcl" "$TM_URL"
fi

# Plain `[ -n "$tm_xtrace" ] && set -x` would return non-zero when xtrace was
# never on, and `set -e` would abort the script on it.
if [ -n "$tm_xtrace" ]; then
  set -x
fi

echo "    enabling automatic hourly backups, on battery as well as AC"
sudo tmutil enable
# AutoBackupInterval is in seconds; 3600 is hourly and is Time Machine's own
# default, set explicitly so the value is declared rather than assumed.
sudo defaults write /Library/Preferences/com.apple.TimeMachine \
  AutoBackupInterval -int 3600
# Without this macOS defers backups until the machine is on mains power.
sudo defaults write /Library/Preferences/com.apple.TimeMachine \
  RequiresACPower -bool false

# No exclusions are added here, and none are removed: everything this script
# configures is included by default, so there is nothing of ours to take back
# out. macOS enforces its own exclusions (the sealed system volume, swap,
# caches) which cannot be removed by any tool - see the README. Print the
# current verdict for a couple of representative paths so the outcome is
# visible rather than asserted.
echo "    exclusions (none added by this script; macOS enforces its own):"
tmutil isexcluded / /Users /System 2>/dev/null | sed 's/^/      /' || true

echo "==> Done."
