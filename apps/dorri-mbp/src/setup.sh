#!/usr/bin/env bash
#
# dorri-mbp - take a stock MacBook Pro to a fully configured machine.
#
# Safe to re-run: every step is idempotent and skips work that is already done.
# Updating the machine is `git pull` followed by re-running this script; there
# is no build or packaging step in between. Every file it reads sits next to
# it in this directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The full name shown at the login window and in System Settings. Cosmetic, so
# unlike the username and password it has a default rather than being required.
ADMIN_FULL_NAME="${ADMIN_FULL_NAME:-${ADMIN_USERNAME:-}}"

# Time Machine backs up to the NAS over SMB. The share defaults to `backup`,
# which is what the NAS path /Volume1/backup means in SMB terms: on a Synology,
# /volume1 is the underlying volume and `backup` is the shared folder, which is
# what an SMB URL addresses. NAS_SHARE overrides it if that ever stops holding.
#
# Same variable names as the sibling apps/andrew-mbp on purpose, so one runbook
# covers both Macs rather than each machine needing its own.
NAS_SHARE="${NAS_SHARE:-backup}"

# Raycast stores its global hotkey as "<modifiers>-<keycode>". 49 is the space
# key, so "Command-49" is cmd+space. Read off a live Raycast install
# (`defaults read com.raycast.macos raycastGlobalHotkey`) rather than recalled.
RAYCAST_HOTKEY="Command-49"

# macOS keeps its own keyboard shortcuts in com.apple.symbolichotkeys, keyed by
# a numeric id. 64 is "Show Spotlight search" and 65 is "Show Finder search
# window"; both are Spotlight, and 64 is the one bound to cmd+space that has to
# be released before Raycast can take it.
#
# The parameters are (character, keycode, modifier mask): 32 is space, 49 is
# the space keycode, 1048576 is command and 1572864 is command+option. The 64
# entry was read off a live macOS 26 system rather than recalled; 65 is absent
# there because it is still at its macOS default, so its parameters are the
# documented default.
#
# `enabled = false` disables the shortcut while leaving its binding intact, so
# re-enabling it later is one flag rather than a reconstruction.
SPOTLIGHT_HOTKEY_64='<dict><key>enabled</key><false/><key>value</key><dict><key>parameters</key><array><integer>32</integer><integer>49</integer><integer>1048576</integer></array><key>type</key><string>standard</string></dict></dict>'
SPOTLIGHT_HOTKEY_65='<dict><key>enabled</key><false/><key>value</key><dict><key>parameters</key><array><integer>32</integer><integer>49</integer><integer>1572864</integer></array><key>type</key><string>standard</string></dict></dict>'

os_type="$OSTYPE"
arch_type="$(uname -m)"
[[ $OSTYPE == darwin* ]] && os_type="macos"
if [[ $os_type != "macos" || $arch_type != "arm64" ]]; then
  echo "Error: dorri-mbp supports macOS on Apple Silicon only." >&2
  echo "Detected: $os_type / $arch_type" >&2
  exit 1
fi

# Validate everything up front, before anything has been installed or changed,
# so a missing variable costs nothing to recover from. Report every missing
# variable at once - across both the account and the NAS, in one pass rather
# than a second check later on - so a run that is short two credentials fails
# once rather than twice. Never prompt, never guess a default: these create a
# real login account and point a real backup destination, and a guessed value
# in either is a security problem or a silent backup failure rather than an
# inconvenience.
#
# Deliberately no arrays: /bin/bash on macOS is still 3.2, and `set -u` with an
# empty array is an unbound-variable error there.
missing=""
[ -n "${ADMIN_USERNAME:-}" ] || missing="$missing ADMIN_USERNAME"
[ -n "${ADMIN_PASSWORD:-}" ] || missing="$missing ADMIN_PASSWORD"
[ -n "${NAS_HOST:-}" ] || missing="$missing NAS_HOST"
[ -n "${NAS_USERNAME:-}" ] || missing="$missing NAS_USERNAME"
[ -n "${NAS_PASSWORD:-}" ] || missing="$missing NAS_PASSWORD"
if [ -n "$missing" ]; then
  echo "Error: this setup needs credentials for the second administrator" >&2
  echo "account and for the NAS that Time Machine backs up to, but these" >&2
  echo "environment variables are not set:" >&2
  for var in $missing; do
    echo "  - $var" >&2
  done
  echo "" >&2
  echo "Set all of them and re-run. Nothing has been changed on this machine." >&2
  echo "" >&2
  echo "  ADMIN_USERNAME   macOS short name of the second admin account" >&2
  echo "  ADMIN_PASSWORD   that account's login password" >&2
  echo "  ADMIN_FULL_NAME  optional, defaults to ADMIN_USERNAME" >&2
  echo "  NAS_HOST         hostname or IP of the NAS" >&2
  echo "  NAS_USERNAME     NAS account Time Machine backs up as" >&2
  echo "  NAS_PASSWORD     that account's password" >&2
  echo "  NAS_SHARE        optional, defaults to '$NAS_SHARE'" >&2
  echo "" >&2
  echo "Keep ADMIN_PASSWORD and NAS_PASSWORD out of your shell history - read" >&2
  echo "them from your password manager, e.g. \"\$(op read op://...)\"." >&2
  exit 1
fi

# The username reaches dseditgroup, createhomedir and a /Users path, so bound
# it to what macOS accepts as a short name rather than passing an arbitrary
# string through. Also catches the common mistake of supplying a full name.
case "$ADMIN_USERNAME" in
  *[!a-zA-Z0-9_-]* | "" | -*)
    echo "Error: ADMIN_USERNAME must be a macOS short name - letters, digits," >&2
    echo "underscore and hyphen only, and not starting with a hyphen." >&2
    echo "Got: '$ADMIN_USERNAME'. Nothing has been changed on this machine." >&2
    exit 1
    ;;
esac

# The full name is a human display name, so spaces, apostrophes and accents all
# belong in it. A leading hyphen does not: it reaches sysadminctl where an
# option is expected, and the argv parse there is ambiguous rather than an
# error. Only that one shape is rejected.
case "$ADMIN_FULL_NAME" in
  -*)
    echo "Error: ADMIN_FULL_NAME must not start with a hyphen - it is passed to" >&2
    echo "sysadminctl, which would read it as an option." >&2
    echo "Got: '$ADMIN_FULL_NAME'. Nothing has been changed on this machine." >&2
    exit 1
    ;;
esac

# primary-user.txt names the account that owns this machine. flake.nix reads
# the same file to decide which account Homebrew belongs to, and a flake cannot
# read the environment without going impure. Checking it here means a mismatch
# is a clear message before anything changes, rather than a Homebrew
# installation owned by an account that does not exist.
PRIMARY_USER="$(tr -d '[:space:]' < "$SCRIPT_DIR/primary-user.txt")"
INVOKING_USER="$(id -un)"
if [ "$PRIMARY_USER" != "$INVOKING_USER" ]; then
  echo "Error: this configuration names '$PRIMARY_USER' as the machine's" >&2
  echo "primary account, but it is being run by '$INVOKING_USER'." >&2
  echo "" >&2
  echo "Either run it as '$PRIMARY_USER', or edit" >&2
  echo "  $SCRIPT_DIR/primary-user.txt" >&2
  echo "to name this account and commit that change." >&2
  echo "" >&2
  echo "Nothing has been changed on this machine." >&2
  exit 1
fi

echo "==> Step 1: Nix"
# Determinate Nix is what devtools installs on the sibling machine, so both
# Macs run the same Nix. The installer is a no-op when Nix is already there,
# but check first so a re-run does not go to the network for nothing.
if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ] \
  || command -v nix >/dev/null 2>&1; then
  echo "    already installed"
else
  echo "    installing Determinate Nix (this needs sudo)"
  curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix \
    | sh -s -- install --determinate --no-confirm
fi

# Everything past here needs nix on PATH. On a first-ever run the installer
# just wrote the daemon profile without re-execing this shell, so pick it up.
if ! command -v nix >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi
NIX_BIN="$(command -v nix)"

# Build a tool from this flake's *locked* nixpkgs rather than a floating
# `nixpkgs#...`, so these helpers are pinned alongside everything else on the
# machine and cost no extra download. Same helper, for the same reason, as the
# sibling apps/andrew-mbp.
#
# `path:` for the same reason as step 2 below: a bare path makes nix read the
# git tree and reject anything git does not track, which would break on a
# checkout that merely has an untracked file lying around in it. `getFlake` on
# a path ref is what needs --impure; the evaluation itself is still pinned by
# flake.lock.
nix_tool() {
  "$NIX_BIN" build --no-link --print-out-paths --impure --expr \
    "let f = builtins.getFlake \"path:$SCRIPT_DIR\"; \
     in f.inputs.nixpkgs.legacyPackages.aarch64-darwin.$1"
}

echo "==> Step 2: apply the dorri-mbp configuration"
# This installs Homebrew (via nix-homebrew), every application in
# applications.nix, and turns Spotlight indexing off.
#
# `path:` on purpose. A bare path inside a git working tree makes nix read the
# *git* tree rather than the directory as it is on disk, so an uncommitted edit
# to applications.nix would be silently ignored and the switch would apply the
# last committed version instead. Since the update path here is "edit, or git
# pull, then re-run", that silent staleness is exactly the wrong behaviour.
if command -v darwin-rebuild >/dev/null 2>&1; then
  DARWIN_REBUILD="$(command -v darwin-rebuild)"
elif [ -x /run/current-system/sw/bin/darwin-rebuild ]; then
  DARWIN_REBUILD=/run/current-system/sw/bin/darwin-rebuild
else
  # First run on a machine with no nix-darwin yet: build this configuration's
  # own darwin-rebuild and bootstrap with it, rather than pulling an unpinned
  # one off the network.
  echo "    bootstrapping nix-darwin"
  DARWIN_REBUILD="$("$NIX_BIN" build --no-link --print-out-paths \
    "path:$SCRIPT_DIR#darwinConfigurations.dorri-mbp.system")/sw/bin/darwin-rebuild"
fi
sudo "$DARWIN_REBUILD" switch --flake "path:$SCRIPT_DIR#dorri-mbp"

echo "==> Step 3: second administrator account"
# "Administrator" here means membership in the macOS `admin` group, which is
# what grants sudo. The root account is deliberately left disabled.
#
# Creating the account is skipped entirely when it already exists, so a re-run
# never resets a password or touches an existing account's data.
if id -u "$ADMIN_USERNAME" >/dev/null 2>&1; then
  echo "    '$ADMIN_USERNAME' already exists; leaving the account and its password alone"
else
  echo "    creating '$ADMIN_USERNAME'"

  # Turn off xtrace for the whole credential path, so running this under
  # `bash -x` cannot dump the password into a terminal or a log.
  admin_xtrace=""
  case "$-" in
    *x*) admin_xtrace=1; set +x ;;
  esac

  # Resolve expect BEFORE the pipeline below, never inside it. A command
  # substitution inside that pipeline would inherit the password pipe as its
  # own stdin, handing it to `nix build` and everything nix spawns, and its
  # progress output would interleave with the credential path. Only `sudo
  # expect` may ever see that stdin.
  EXPECT_BIN="$(nix_tool expect)/bin/expect"

  # The password goes over a pipe into expect, which hands it to sysadminctl's
  # non-echoing prompt. It is never a command-line argument, so it never
  # appears in `ps`, and it is never written to disk. macOS stores it as the
  # account's credential and seeds the account's login keychain from it.
  #
  # `printf` is a bash builtin, so even this does not fork a process carrying
  # the password in its arguments. sudo reads its own password from /dev/tty
  # rather than stdin, so it does not consume the pipe.
  printf '%s\n' "$ADMIN_PASSWORD" \
    | sudo "$EXPECT_BIN" -f "$SCRIPT_DIR/create-admin-user.tcl" \
      "$ADMIN_USERNAME" "$ADMIN_FULL_NAME"

  # Plain `[ -n "$admin_xtrace" ] && set -x` would return non-zero when xtrace
  # was never on, and `set -e` would abort the script on it.
  if [ -n "$admin_xtrace" ]; then
    set -x
  fi
fi

# Checked and repaired on every run, not just on creation: an account that lost
# its admin rights out of band is put back, and one that already has them costs
# a read. `dseditgroup -o checkmember` exits non-zero when the user is not a
# member.
if dseditgroup -o checkmember -m "$ADMIN_USERNAME" admin >/dev/null 2>&1; then
  echo "    already in the admin group"
else
  echo "    adding '$ADMIN_USERNAME' to the admin group"
  sudo dseditgroup -o edit -a "$ADMIN_USERNAME" -t user admin
fi

# sysadminctl records the home directory but does not always populate it until
# first login, and step 4 writes into it. Creating it up front is idempotent -
# createhomedir leaves an existing directory alone.
sudo /usr/sbin/createhomedir -c -u "$ADMIN_USERNAME" >/dev/null

echo "==> Step 4: Raycast on cmd+space, Spotlight's hotkey off"
# Both halves are per-user preferences, which is why they are here and not in
# configuration.nix: nix-darwin activation runs as root, outside any user's
# launchd session, and this machine has two accounts that both want the
# setting. Spotlight *indexing* is the machine-wide half and is turned off
# declaratively during activation; see configuration.nix.
#
# Order matters within a user: releasing cmd+space from Spotlight before
# Raycast claims it. macOS does not arbitrate a double binding, it just gives
# the key to Spotlight.
if pgrep -x Raycast >/dev/null 2>&1; then
  echo "    WARNING: Raycast is running. It rewrites its preferences when it"
  echo "    quits, which can undo the hotkey set below. Quit Raycast and"
  echo "    re-run this script if cmd+space does not open Raycast afterwards."
fi

set_pref_for_user() { # username, domain, then `defaults write` arguments
  local pref_user="$1"
  shift
  if [ "$pref_user" = "$INVOKING_USER" ]; then
    # Straight through cfprefsd, which owns this account's preference cache
    # right now. Writing the plist file behind its back would be overwritten.
    defaults write "$@"
  else
    # Same call, as that user. cfprefsd keys its cache per user, so this lands
    # in their preferences with their ownership rather than root's.
    sudo -u "$pref_user" defaults write "$@"
  fi
}

for account in "$INVOKING_USER" "$ADMIN_USERNAME"; do
  echo "    $account"

  # -dict-add, not a plain write: AppleSymbolicHotKeys holds every keyboard
  # shortcut the account has customised, so replacing the whole dictionary
  # would silently reset the others.
  set_pref_for_user "$account" com.apple.symbolichotkeys \
    AppleSymbolicHotKeys -dict-add 64 "$SPOTLIGHT_HOTKEY_64"
  set_pref_for_user "$account" com.apple.symbolichotkeys \
    AppleSymbolicHotKeys -dict-add 65 "$SPOTLIGHT_HOTKEY_65"
  set_pref_for_user "$account" com.raycast.macos \
    raycastGlobalHotkey -string "$RAYCAST_HOTKEY"
done

# Reloads the keyboard shortcut table from the preferences just written.
# Without it the change is only visible after the next login. It only affects
# the session it runs in, so the second account picks the change up when it
# next logs in - see README.md.
/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u \
  || echo "    WARNING: could not reload the shortcut table; log out and back in."

echo "==> Step 5: Time Machine backups to the NAS"
# Deliberately a near-copy of the sibling apps/andrew-mbp's step 5 rather than a
# shared module, on the same reasoning already recorded in scripts/deploy.ts.
# setup.sh's contract is that every file it reads sits next to it, which is what
# lets `./src/setup.sh` run out of a fresh clone with no build or packaging
# step; sharing would mean either breaking that for both machines or standing up
# a workspace package the deploy executor then has to resolve through. The two
# copies also differ where it matters - nix_tool resolves `expect` from this
# app's own pinned flake, not from devtools' - so they are not the same code
# with the same inputs. Keep them in step by hand; each app's tests cover its
# own copy.
#
# They are not in step today. This copy anchors the NAS user on the `smb://`
# scheme and tolerates only the literal Bonjour suffix, where the sibling still
# allows an unbounded user prefix and any dot-suffix, so a stale
# `smb://old-<user>@<host>/<share>` or `<host>.old-site.example.com` is read as
# configured there. The sibling's expect script also still swallows tmutil's
# error when it exits before prompting. Carrying these across is a follow-up on
# andrew-mbp, out of scope for this app.
#
# Machine-wide, not per-account: the destination and its keychain entry live in
# /Library, so this one configuration backs up both accounts' data.
#
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
# destination is already set.
#
# Match on "user@host" and the share, not on the whole URL. macOS reports the
# host back in its Bonjour form, so a destination set as <host> reads back as
# <host>._smb._tcp.local. and an exact URL comparison would never match,
# reconfiguring on every single run. Tolerating that suffix still catches a
# host change - which matters, because ignoring the host entirely would leave a
# moved or corrected NAS silently backing up to the old destination forever,
# the exact silent failure this step exists to prevent.
#
# One anchored match, not three independent substring searches: user, host and
# share all have to come from the same URL, and the share is bounded at the end
# so a stale ".../backup-old" is not read as a configured ".../backup". With
# several destinations configured, an unbounded search could otherwise take the
# user@host from one and the share from another and skip on a match that exists
# nowhere.
#
# The host is bounded too, and the only suffix tolerated is the Bonjour form
# itself, spelled out literally rather than as "any dot-suffix": NAS_HOST=nas-01
# matches nas-01, nas-01.local and nas-01._smb._tcp.local. but not a different
# host called nas-011, and not a stale nas-01.old-site.example.com, which a
# wildcard suffix would wave through as already configured. NAS_HOST=192.168.1.5
# does not match a stale 192.168.1.50 either.
#
# The user is bounded on the left by the literal scheme for the same reason:
# without it, NAS_USERNAME=tmuser matches a stale smb://old-tmuser@nas-01/backup
# and the moved-account case is skipped silently.
#
# The NAS_* values are user-supplied, so escape any regex metacharacters in
# them before they are interpolated into an extended regular expression.
tm_re_escape() { printf '%s' "$1" | sed 's#[][^$.*+?(){}|\\/]#\\&#g'; }
tm_pattern="smb://$(tm_re_escape "$NAS_USERNAME")@$(tm_re_escape "$NAS_HOST")"
tm_pattern="$tm_pattern"'(\._smb\._tcp)?(\.local\.?)?/'"$(tm_re_escape "$NAS_SHARE")"'([[:space:]]|$)'

tm_existing="$(tmutil destinationinfo 2>/dev/null || true)"
if printf '%s\n' "$tm_existing" | grep -qE "$tm_pattern"; then
  echo "    destination already configured, leaving it alone"
else
  echo "    configuring destination smb://${NAS_USERNAME}@${NAS_HOST}/${NAS_SHARE}"
  echo "    (this REPLACES the destination list; the NAS becomes the only one)"
  # The helper below calls `tmutil setdestination` without -a, which replaces
  # the whole destination list rather than appending to it. Appending would
  # leave a superseded destination in the list for Time Machine to keep
  # choosing from, so a moved NAS would go on receiving backups - the silent
  # stale-destination failure the check above exists to prevent. Any other
  # destination, a local backup disk included, is dropped; see the README.
  #
  # Resolve expect BEFORE the pipeline below, never inside it. A command
  # substitution inside that pipeline would inherit the password pipe as its
  # own stdin, handing it to `nix build` and everything nix spawns, and its
  # progress output would interleave with the credential path. Only `sudo
  # expect` may ever see that stdin.
  EXPECT_BIN="$(nix_tool expect)/bin/expect"

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
    | sudo "$EXPECT_BIN" -f \
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
echo ""
echo "Remaining manual steps are listed in this app's README.md - the short"
echo "version is: launch Raycast once per account and confirm cmd+space opens"
echo "it, and grant each app the permissions it asks for on first launch. If"
echo "the Time Machine step failed, grant your terminal Full Disk Access"
echo "(System Settings > Privacy & Security > Full Disk Access) and re-run."
