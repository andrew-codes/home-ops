#!/usr/bin/env bash
#
# Tests the parts of ../src/setup.sh that create an account, rewrite keyboard
# shortcuts and configure Time Machine, without touching this machine.
#
# Those steps create a real login account, point a real backup destination and
# need root, so they can never be exercised for real from a test. Everything
# privileged or persistent is stubbed: `sudo`, `id`, `dseditgroup`, `defaults`,
# `pgrep`, `tmutil` and `nix_tool` are shell functions here; `sysadminctl`,
# `createhomedir` and `activateSettings` are rewritten to point at this
# script's own temp directory; and the expect scripts are pointed at fake
# `sysadminctl` / `tmutil` binaries that mimic getpass (prompt, echo off, read
# one line). Nothing outside that directory is written, and no real `tmutil`
# ever runs.
#
# Run it after any change to setup.sh, to create-admin-user.tcl or to
# set-time-machine-destination.tcl:
#
#   apps/dorri-mbp/tests/setup.test.sh
#
# Requires `expect`, which the deployment itself builds from this flake's
# pinned nixpkgs. If it is not on PATH the expect-driven cases are skipped
# rather than silently reported as passing.

set -uo pipefail

# setup.sh refuses to run anywhere but macOS on Apple Silicon, and the cases
# below drive its real code paths, so there is nothing meaningful to assert
# elsewhere. CI runs on ubuntu-latest, so skip cleanly rather than fail.
if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
  echo "SKIP  dorri-mbp setup tests: macOS on Apple Silicon only (this is $(uname -s)/$(uname -m))"
  exit 0
fi

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$TESTS_DIR/../src" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A password that would be unmistakable if it ever leaked into output. Used for
# both credentials, so a leak from either path fails the same check.
SENTINEL="S3nt1nel-PaSSw0rd-do-not-log"
ME="$(id -un)"

# setup.sh requires the NAS variables as well as the ADMIN_* ones, and almost
# every case below wants them present. Exported once here so each case only has
# to say what it changes; the validation cases `env -u` the ones they want
# missing, and the Time Machine cases override them per case.
export NAS_HOST=nas-01
export NAS_USERNAME=tmuser
export NAS_PASSWORD="$SENTINEL"

passes=0
failures=0

ok() {
  echo "  PASS  $1"
  passes=$((passes + 1))
}

fail() {
  echo "  FAIL  $1"
  echo "        $2"
  failures=$((failures + 1))
}

check() { # description, expected, actual
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "expected '$2', got '$3'"; fi
}

# Everything before step 1 - the platform check and all of the validation.
# SCRIPT_DIR resolves to $WORK in the extracted copy, so primary-user.txt is
# read from there and each case can choose what it says.
preflight() {
  awk '/^echo "==> Step 1: Nix/{print "echo REACHED_STEP_1"; exit} {print}' \
    "$SRC_DIR/setup.sh"
}

# The stub preamble every harness below shares: the constants at the top of
# setup.sh, plus a shell function for each privileged command. $1 is the body of
# the `tmutil destinationinfo` stub; the real `tmutil` is never invoked, not
# even for the read-only subcommands, because this machine has its own Time
# Machine configuration that must stay untouched.
stubs() {
  awk '/^os_type=/{exit} {print}' "$SRC_DIR/setup.sh"
  echo "SCRIPT_DIR=$SRC_DIR"
  echo "INVOKING_USER=$ME"
  echo "NIX_BIN=/stub-nix"
  echo 'sudo() { echo "[sudo] $*"; }'
  echo 'defaults() { echo "[defaults] $*"; }'
  echo 'nix_tool() { echo /stub-store-path; }'
  echo "tmutil() { case \"\$1\" in destinationinfo) $1 ;; isexcluded) echo \"[Included]  \$*\" ;; *) echo \"[tmutil] \$*\" ;; esac; }"
}

# A runnable copy of steps 3, 4 and 5 with everything privileged stubbed out.
# $1 is the body of the `id` stub, which is what decides whether the account
# already exists. $2 is the exit status of the `dseditgroup` membership check.
# $3 is the body of the `tmutil destinationinfo` stub, defaulting to "no
# destination configured".
harness() {
  {
    stubs "${3:-return 1}"
    echo "id() { $1 ; }"
    echo "dseditgroup() { return $2 ; }"
    echo 'pgrep() { return 1; }'
    # Never let the real activateSettings run against this machine's session.
    awk '/^echo "==> Step 3/{f=1} f' "$SRC_DIR/setup.sh" \
      | sed 's|/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings|true|'
  }
}

# Step 5 alone, for the Time Machine cases, so their assertions are not read
# against the account and hotkey output of the steps before it.
tm_harness() {
  {
    stubs "$1"
    awk '/^echo "==> Step 5/{f=1} f' "$SRC_DIR/setup.sh"
  }
}

echo "== validation fails closed before anything is changed"
preflight > "$WORK/preflight.sh"
printf '%s\n' "$ME" > "$WORK/primary-user.txt"

out="$(env -u ADMIN_USERNAME -u ADMIN_PASSWORD bash "$WORK/preflight.sh" 2>&1)"
check "exits non-zero with neither set" "1" "$?"
for var in ADMIN_USERNAME ADMIN_PASSWORD; do
  case "$out" in
    *"- $var"*) ok "names $var" ;;
    *) fail "names $var" "not present in the error output" ;;
  esac
done
case "$out" in
  *REACHED_STEP_1*) fail "changes nothing before failing" "execution reached step 1" ;;
  *) ok "changes nothing before failing" ;;
esac

# Both missing variables must be reported together, not one per re-run.
case "$out" in
  *"- ADMIN_USERNAME"*"- ADMIN_PASSWORD"*) ok "reports every missing variable at once" ;;
  *) fail "reports every missing variable at once" "$out" ;;
esac

out="$(env -u ADMIN_PASSWORD ADMIN_USERNAME=someone bash "$WORK/preflight.sh" 2>&1)"
case "$out:$?" in
  *"- ADMIN_PASSWORD"*) ok "names only the missing one when the other is set" ;;
  *) fail "names only the missing one when the other is set" "$out" ;;
esac

# The NAS variables are validated in the same pass as the ADMIN_* ones, not in
# a later one, so a run missing credentials on both sides fails once.
out="$(env -u NAS_HOST -u NAS_USERNAME -u NAS_PASSWORD \
  ADMIN_USERNAME=someone ADMIN_PASSWORD="$SENTINEL" bash "$WORK/preflight.sh" 2>&1)"
check "exits non-zero with the NAS variables missing" "1" "$?"
for var in NAS_HOST NAS_USERNAME NAS_PASSWORD; do
  case "$out" in
    *"- $var"*) ok "names $var" ;;
    *) fail "names $var" "not present in the error output" ;;
  esac
done
case "$out" in
  *REACHED_STEP_1*) fail "changes nothing when only the NAS variables are missing" "execution reached step 1" ;;
  *) ok "changes nothing when only the NAS variables are missing" ;;
esac

out="$(env -u ADMIN_USERNAME -u ADMIN_PASSWORD -u NAS_HOST -u NAS_USERNAME -u NAS_PASSWORD \
  bash "$WORK/preflight.sh" 2>&1)"
case "$out" in
  *"- ADMIN_USERNAME"*"- ADMIN_PASSWORD"*"- NAS_HOST"*"- NAS_USERNAME"*"- NAS_PASSWORD"*)
    ok "names every missing account and NAS variable in one message" ;;
  *) fail "names every missing account and NAS variable in one message" "$out" ;;
esac

# NAS_SHARE is optional and must not be demanded.
out="$(env -u NAS_SHARE ADMIN_USERNAME=andrewsmith ADMIN_PASSWORD="$SENTINEL" \
  bash "$WORK/preflight.sh" 2>&1)"
case "$out" in
  *"- NAS_SHARE"*) fail "never demands the optional NAS_SHARE" "$out" ;;
  *REACHED_STEP_1*) ok "never demands the optional NAS_SHARE" ;;
  *) fail "never demands the optional NAS_SHARE" "$out" ;;
esac

# No interactive prompt and no default: a closed stdin must still fail, rather
# than blocking or inventing a value.
out="$(env -u ADMIN_USERNAME -u ADMIN_PASSWORD bash "$WORK/preflight.sh" </dev/null 2>&1)"
check "never prompts - fails the same way with stdin closed" "1" "$?"

echo
echo "== the username is bounded to a macOS short name"
for bad in "Andrew Smith" "root;rm -rf /" "-admin" "andrew/smith" ""; do
  out="$(ADMIN_USERNAME="$bad" ADMIN_PASSWORD="$SENTINEL" bash "$WORK/preflight.sh" 2>&1)"
  status=$?
  case "$out:$status" in
    *REACHED_STEP_1*) fail "rejects '$bad'" "it was accepted" ;;
    *:0) fail "rejects '$bad'" "exited 0" ;;
    *) ok "rejects '$bad'" ;;
  esac
done

out="$(ADMIN_USERNAME=andrewsmith ADMIN_PASSWORD="$SENTINEL" bash "$WORK/preflight.sh" 2>&1)"
case "$out" in
  *REACHED_STEP_1*) ok "accepts a valid short name with both variables set" ;;
  *) fail "accepts a valid short name with both variables set" "$out" ;;
esac

echo
echo "== the full name only rejects the leading hyphen sysadminctl would misread"
out="$(ADMIN_USERNAME=andrewsmith ADMIN_PASSWORD="$SENTINEL" ADMIN_FULL_NAME="-admin" \
  bash "$WORK/preflight.sh" 2>&1)"
status=$?
case "$out:$status" in
  *REACHED_STEP_1*) fail "rejects a full name starting with a hyphen" "it was accepted" ;;
  *:0) fail "rejects a full name starting with a hyphen" "exited 0" ;;
  *"Nothing has been changed on this machine."*) ok "rejects a full name starting with a hyphen" ;;
  *) fail "rejects a full name starting with a hyphen" "$out" ;;
esac

for good in "Andrew Smith" "Dorri O'Neill" "Renée Müller"; do
  out="$(ADMIN_USERNAME=andrewsmith ADMIN_PASSWORD="$SENTINEL" ADMIN_FULL_NAME="$good" \
    bash "$WORK/preflight.sh" 2>&1)"
  case "$out" in
    *REACHED_STEP_1*) ok "accepts the ordinary display name '$good'" ;;
    *) fail "accepts the ordinary display name '$good'" "$out" ;;
  esac
done

echo
echo "== the primary account named in primary-user.txt has to be the one running it"
printf '%s\n' "somebody-else" > "$WORK/primary-user.txt"
out="$(ADMIN_USERNAME=andrewsmith ADMIN_PASSWORD="$SENTINEL" bash "$WORK/preflight.sh" 2>&1)"
status=$?
case "$out:$status" in
  *REACHED_STEP_1*) fail "fails closed on a primary-user mismatch" "it proceeded" ;;
  *"primary-user.txt"*) ok "fails closed on a primary-user mismatch, naming the file to edit" ;;
  *) fail "fails closed on a primary-user mismatch" "$out" ;;
esac
check "exits non-zero on a primary-user mismatch" "1" "$status"

# The committed value has to be readable and free of stray whitespace, or the
# flake would hand Homebrew a user that does not exist.
committed="$(tr -d '[:space:]' < "$SRC_DIR/primary-user.txt")"
case "$committed" in
  "" | *[!a-zA-Z0-9_-]*) fail "primary-user.txt holds a plausible short name" "got '$committed'" ;;
  *) ok "primary-user.txt holds a plausible short name ('$committed')" ;;
esac

echo
echo "== an existing account is never re-created and never has its password reset"
harness 'return 0' 0 > "$WORK/exists.sh"
out="$(ADMIN_USERNAME=andrewsmith ADMIN_PASSWORD="$SENTINEL" bash "$WORK/exists.sh" 2>&1)"
case "$out" in
  *"already exists"*) ok "skips creation when the account is already there" ;;
  *) fail "skips creation when the account is already there" "$out" ;;
esac
case "$out" in
  *create-admin-user.tcl*) fail "never invokes the account-creating expect script" "$out" ;;
  *) ok "never invokes the account-creating expect script" ;;
esac
case "$out" in
  *"already in the admin group"*) ok "leaves admin membership alone when it is already there" ;;
  *) fail "leaves admin membership alone when it is already there" "$out" ;;
esac

echo
echo "== a missing account is created as an admin"
harness 'return 1' 1 > "$WORK/missing.sh"
out="$(ADMIN_USERNAME=andrewsmith ADMIN_PASSWORD="$SENTINEL" bash "$WORK/missing.sh" 2>&1)"
case "$out" in
  *"creating 'andrewsmith'"*) ok "creates the account when it does not exist" ;;
  *) fail "creates the account when it does not exist" "$out" ;;
esac
case "$out" in
  *"create-admin-user.tcl andrewsmith"*) ok "hands the username to the expect script" ;;
  *) fail "hands the username to the expect script" "$out" ;;
esac
case "$out" in
  *"dseditgroup -o edit -a andrewsmith -t user admin"*)
    ok "adds the account to the admin group when it is not a member" ;;
  *) fail "adds the account to the admin group when it is not a member" "$out" ;;
esac
# admin group, never the root account.
case "$out" in
  *"-o edit -a andrewsmith -t user root"* | *"dsenableroot"*)
    fail "never touches the root account" "$out" ;;
  *) ok "never touches the root account" ;;
esac

echo
echo "== neither password leaks, even under xtrace"
# missing.sh runs steps 3 through 5, so this covers both credential paths: the
# account password handed to sysadminctl and the NAS password handed to tmutil.
out="$(ADMIN_USERNAME=andrewsmith ADMIN_PASSWORD="$SENTINEL" bash -x "$WORK/missing.sh" 2>&1)"
case "$out" in
  *"$SENTINEL"*) fail "sentinel absent from stdout, stderr and the xtrace" "leaked" ;;
  *) ok "sentinel absent from stdout, stderr and the xtrace" ;;
esac

echo
echo "== cmd+space is taken off Spotlight and given to Raycast, for both accounts"
out="$(ADMIN_USERNAME=andrewsmith ADMIN_PASSWORD="$SENTINEL" bash "$WORK/missing.sh" 2>&1)"
for key in 64 65; do
  case "$out" in
    *"AppleSymbolicHotKeys -dict-add $key"*) ok "disables the Spotlight hotkey $key" ;;
    *) fail "disables the Spotlight hotkey $key" "$out" ;;
  esac
done
# -dict-add, not a plain write: a plain write would drop every other shortcut
# the account has customised.
case "$out" in
  *"AppleSymbolicHotKeys <dict>"* | *"AppleSymbolicHotKeys -dict "*)
    fail "never replaces the whole AppleSymbolicHotKeys dictionary" "$out" ;;
  *) ok "never replaces the whole AppleSymbolicHotKeys dictionary" ;;
esac
case "$out" in
  *"raycastGlobalHotkey -string Command-49"*) ok "binds Raycast to cmd+space" ;;
  *) fail "binds Raycast to cmd+space" "$out" ;;
esac
# Once for this account directly, once for the second account through sudo -u.
case "$out" in
  *"[sudo] -u andrewsmith defaults write com.raycast.macos"*)
    ok "applies the Raycast hotkey to the second account too" ;;
  *) fail "applies the Raycast hotkey to the second account too" "$out" ;;
esac
case "$out" in
  *"[sudo] -u andrewsmith defaults write com.apple.symbolichotkeys"*)
    ok "applies the Spotlight hotkey change to the second account too" ;;
  *) fail "applies the Spotlight hotkey change to the second account too" "$out" ;;
esac
# Spotlight's binding has to be released before Raycast claims the key.
spotlight_line="$(printf '%s\n' "$out" | grep -n "dict-add 64" | head -1 | cut -d: -f1)"
raycast_line="$(printf '%s\n' "$out" | grep -n "raycastGlobalHotkey" | head -1 | cut -d: -f1)"
if [ -n "$spotlight_line" ] && [ -n "$raycast_line" ] && [ "$spotlight_line" -lt "$raycast_line" ]; then
  ok "releases Spotlight's binding before Raycast takes cmd+space"
else
  fail "releases Spotlight's binding before Raycast takes cmd+space" \
    "spotlight at line '$spotlight_line', raycast at line '$raycast_line'"
fi

echo
echo "== the Time Machine destination is only reconfigured when it differs"
tm_harness 'echo "URL           : smb://tmuser@nas-01._smb._tcp.local./backup"' > "$WORK/tm-same.sh"
out="$(bash "$WORK/tm-same.sh" 2>&1)"
case "$out" in
  *"already configured"*) ok "skips when the destination already matches (Bonjour-form URL)" ;;
  *) fail "skips when the destination already matches" "$out" ;;
esac

# Bounding the host must not cost the plain, non-Bonjour form.
tm_harness 'echo "URL           : smb://tmuser@nas-01/backup"' > "$WORK/tm-plain.sh"
out="$(bash "$WORK/tm-plain.sh" 2>&1)"
case "$out" in
  *"already configured"*) ok "skips when the destination already matches (plain host)" ;;
  *) fail "skips when the destination already matches (plain host)" "$out" ;;
esac

tm_harness 'return 1' > "$WORK/tm-none.sh"
out="$(bash "$WORK/tm-none.sh" 2>&1)"
case "$out" in
  *"configuring destination"*) ok "configures when no destination is set" ;;
  *) fail "configures when no destination is set" "$out" ;;
esac

# A moved NAS must not keep the stale target - the whole reason the idempotency
# check includes the host rather than only the share.
out="$(NAS_HOST=nas-02 bash "$WORK/tm-same.sh" 2>&1)"
case "$out" in
  *"configuring destination"*) ok "reconfigures when the NAS host changed" ;;
  *) fail "reconfigures when the NAS host changed" "stale destination kept: $out" ;;
esac

out="$(NAS_USERNAME=someone-else bash "$WORK/tm-same.sh" 2>&1)"
case "$out" in
  *"configuring destination"*) ok "reconfigures when the NAS user changed" ;;
  *) fail "reconfigures when the NAS user changed" "$out" ;;
esac

# The user is bounded on the left too: a different account whose name merely
# ends with NAS_USERNAME is a stale destination, not a configured one.
tm_harness 'echo "URL           : smb://old-tmuser@nas-01/backup"' \
  > "$WORK/tm-suffix-user.sh"
out="$(bash "$WORK/tm-suffix-user.sh" 2>&1)"
case "$out" in
  *"configuring destination"*) ok "reconfigures when the configured user merely ends with NAS_USERNAME" ;;
  *) fail "reconfigures when the configured user merely ends with NAS_USERNAME" "stale destination kept: $out" ;;
esac

# A stale share whose name merely starts with the wanted one must not be read
# as already configured; the share has to be bounded at the end of the URL.
tm_harness 'echo "URL           : smb://tmuser@nas-01._smb._tcp.local./backup-old"' \
  > "$WORK/tm-wrong-share.sh"
out="$(bash "$WORK/tm-wrong-share.sh" 2>&1)"
case "$out" in
  *"configuring destination"*) ok "reconfigures when the share changed" ;;
  *) fail "reconfigures when the share changed" "stale destination kept: $out" ;;
esac

# user@host from one destination plus the share from another is not a match.
tm_harness 'echo "URL           : smb://tmuser@nas-01._smb._tcp.local./backup-old"
      echo "Mount Point   : /Volumes/backup"' > "$WORK/tm-split.sh"
out="$(bash "$WORK/tm-split.sh" 2>&1)"
case "$out" in
  *"configuring destination"*) ok "reconfigures when user@host and share come from different destinations" ;;
  *) fail "reconfigures when user@host and share come from different destinations" "$out" ;;
esac

# The host is bounded as well as the share: a different host whose name merely
# starts with NAS_HOST is a stale destination, not a configured one.
tm_harness 'echo "URL           : smb://tmuser@nas-011/backup"' > "$WORK/tm-prefix-host.sh"
out="$(bash "$WORK/tm-prefix-host.sh" 2>&1)"
case "$out" in
  *"configuring destination"*) ok "reconfigures when the configured host merely starts with NAS_HOST" ;;
  *) fail "reconfigures when the configured host merely starts with NAS_HOST" "stale destination kept: $out" ;;
esac

tm_harness 'echo "URL           : smb://tmuser@192.168.1.50/backup"' > "$WORK/tm-prefix-ip.sh"
out="$(NAS_HOST=192.168.1.5 bash "$WORK/tm-prefix-ip.sh" 2>&1)"
case "$out" in
  *"configuring destination"*) ok "reconfigures when the configured IP merely starts with NAS_HOST" ;;
  *) fail "reconfigures when the configured IP merely starts with NAS_HOST" "stale destination kept: $out" ;;
esac

echo
echo "== the backup schedule is hourly, on battery, with no exclusions of ours"
out="$(bash "$WORK/tm-none.sh" 2>&1)"
case "$out" in
  *"[sudo] tmutil enable"*) ok "enables automatic backups" ;;
  *) fail "enables automatic backups" "$out" ;;
esac
case "$out" in
  *"AutoBackupInterval -int 3600"*) ok "sets the backup interval to hourly" ;;
  *) fail "sets the backup interval to hourly" "$out" ;;
esac
case "$out" in
  *"RequiresACPower -bool false"*) ok "keeps backing up on battery" ;;
  *) fail "keeps backing up on battery" "$out" ;;
esac
# Adding an exclusion of our own would be a behaviour change, not a tweak.
case "$out" in
  *"tmutil addexclusion"*) fail "adds no exclusions of its own" "$out" ;;
  *) ok "adds no exclusions of its own" ;;
esac
case "$out" in
  *"exclusions (none added by this script"*) ok "reports the exclusions macOS enforces" ;;
  *) fail "reports the exclusions macOS enforces" "$out" ;;
esac
# The replacement is a consequence worth stating at the terminal, not only in
# the README: it silently drops any other destination the machine had.
case "$out" in
  *"REPLACES the destination list"*) ok "warns that the destination list is replaced" ;;
  *) fail "warns that the destination list is replaced" "$out" ;;
esac

echo
echo "== the NAS password never leaks, even under xtrace"
out="$(bash -x "$WORK/tm-none.sh" 2>&1)"
case "$out" in
  *"$SENTINEL"*) fail "sentinel absent from stdout, stderr and the xtrace" "leaked" ;;
  *) ok "sentinel absent from stdout, stderr and the xtrace" ;;
esac

echo
echo "== create-admin-user.tcl"
if ! command -v expect >/dev/null 2>&1; then
  echo "  SKIP  expect not on PATH; the expect-driven cases did not run"
else
  cat > "$WORK/fake-sysadminctl" <<'FAKE'
#!/bin/bash
# Mimics sysadminctl's getpass prompt: echo off, prompt, read one line. Records
# its own argv first, one argument per line, so the tests can assert the
# command form and not merely the branch that led here.
: > "$FAKE_SYSADMINCTL_ARGV"
for a in "$@"; do printf '%s\n' "$a" >> "$FAKE_SYSADMINCTL_ARGV"; done
stty -echo 2>/dev/null
printf 'User password: '
IFS= read -r pw
stty echo 2>/dev/null
printf '\n'
[ "$pw" = "$FAKE_EXPECTED_PASSWORD" ] && exit 0
exit 9
FAKE
  chmod +x "$WORK/fake-sysadminctl"
  export FAKE_SYSADMINCTL_ARGV="$WORK/sysadminctl-argv"
  sed "s|/usr/sbin/sysadminctl|$WORK/fake-sysadminctl|" \
    "$SRC_DIR/create-admin-user.tcl" > "$WORK/script.tcl"

  export FAKE_EXPECTED_PASSWORD="$SENTINEL"

  out="$(printf '%s\n' "$SENTINEL" \
    | expect -f "$WORK/script.tcl" "andrewsmith" "Andrew Smith" 2>&1)"
  check "delivers the password to the prompt" "0" "$?"
  case "$out" in
    *"$SENTINEL"*) fail "never echoes the password" "leaked: $out" ;;
    *) ok "never echoes the password" ;;
  esac

  # Assert the argv itself, so a change that puts the password on the command
  # line, or drops -admin, fails here rather than shipping silently.
  argv="$(cat "$FAKE_SYSADMINCTL_ARGV")"
  check "invokes sysadminctl with -addUser, the prompt flag and -admin" \
    "-addUser
andrewsmith
-fullName
Andrew Smith
-password
-
-admin" "$argv"
  case "$argv" in
    *"$SENTINEL"*) fail "never puts the password in argv" "argv: $argv" ;;
    *) ok "never puts the password in argv" ;;
  esac

  printf '%s\n' "the-wrong-password" \
    | expect -f "$WORK/script.tcl" "andrewsmith" "Andrew Smith" >/dev/null 2>&1
  check "propagates sysadminctl's exit status" "9" "$?"

  expect -f "$WORK/script.tcl" "andrewsmith" >/dev/null 2>&1
  check "rejects a missing full name" "2" "$?"

  expect -f "$WORK/script.tcl" "andrewsmith" "Andrew Smith" </dev/null >/dev/null 2>&1
  check "rejects an empty stdin" "2" "$?"

  printf '\n' | expect -f "$WORK/script.tcl" "andrewsmith" "Andrew Smith" >/dev/null 2>&1
  check "rejects an empty password" "2" "$?"

  # A rejected invocation must not have reached sysadminctl at all.
  : > "$FAKE_SYSADMINCTL_ARGV"
  printf '\n' | expect -f "$WORK/script.tcl" "andrewsmith" "Andrew Smith" >/dev/null 2>&1
  check "creates no account when the password is empty" "" "$(cat "$FAKE_SYSADMINCTL_ARGV")"
fi

echo
echo "== set-time-machine-destination.tcl"
if ! command -v expect >/dev/null 2>&1; then
  echo "  SKIP  expect not on PATH; the expect-driven cases did not run"
else
  cat > "$WORK/fake-tmutil" <<'FAKE'
#!/bin/bash
# Mimics tmutil's getpass prompt: echo off, prompt, read one line. Records its
# own argv first, one argument per line, so the tests can assert the command
# form and not merely the branch that led here.
: > "$FAKE_TMUTIL_ARGV"
for a in "$@"; do printf '%s\n' "$a" >> "$FAKE_TMUTIL_ARGV"; done
stty -echo 2>/dev/null
printf 'Destination password: '
IFS= read -r pw
stty echo 2>/dev/null
printf '\n'
[ "$pw" = "$FAKE_EXPECTED_PASSWORD" ] && exit 0
exit 9
FAKE
  chmod +x "$WORK/fake-tmutil"
  export FAKE_TMUTIL_ARGV="$WORK/tmutil-argv"
  sed "s|/usr/bin/tmutil|$WORK/fake-tmutil|" \
    "$SRC_DIR/set-time-machine-destination.tcl" > "$WORK/tm-script.tcl"

  export FAKE_EXPECTED_PASSWORD="$SENTINEL"

  out="$(printf '%s\n' "$SENTINEL" \
    | expect -f "$WORK/tm-script.tcl" "smb://tmuser@nas-01/backup" 2>&1)"
  check "delivers the password to the prompt" "0" "$?"
  case "$out" in
    *"$SENTINEL"*) fail "never echoes the password" "leaked: $out" ;;
    *) ok "never echoes the password" ;;
  esac

  # The destination list must be REPLACED, not appended to: `tmutil
  # setdestination -a` leaves a superseded destination in the rotation, so a
  # moved NAS would keep receiving backups. Assert the argv itself, so
  # reintroducing -a fails here rather than shipping silently.
  argv="$(cat "$FAKE_TMUTIL_ARGV")"
  check "invokes setdestination with the -p prompt and the given URL" \
    "setdestination
-p
smb://tmuser@nas-01/backup" "$argv"
  case "$argv" in
    *$'\n'-a*) fail "never passes -a, which appends instead of replacing" "argv: $argv" ;;
    -a*) fail "never passes -a, which appends instead of replacing" "argv: $argv" ;;
    *) ok "never passes -a, which appends instead of replacing" ;;
  esac
  case "$argv" in
    *"$SENTINEL"*) fail "never puts the password in argv" "argv: $argv" ;;
    *) ok "never puts the password in argv" ;;
  esac

  printf '%s\n' "the-wrong-password" \
    | expect -f "$WORK/tm-script.tcl" "smb://tmuser@nas-01/backup" >/dev/null 2>&1
  check "propagates tmutil's exit status" "9" "$?"

  expect -f "$WORK/tm-script.tcl" >/dev/null 2>&1
  check "rejects a missing destination URL" "2" "$?"

  expect -f "$WORK/tm-script.tcl" "smb://tmuser@nas-01/backup" </dev/null >/dev/null 2>&1
  check "rejects an empty stdin" "2" "$?"
fi

echo
echo "$passes passed, $failures failed"
[ "$failures" -eq 0 ]
