#!/usr/bin/env bash
#
# Tests the Time Machine step of ../src/setup.sh without touching this machine.
#
# The step it covers configures a real backup destination and needs root, so it
# can never be exercised for real from a test. Everything privileged is stubbed:
# `sudo`, `tmutil` and `nix_tool` are shell functions here, and the expect
# script is pointed at a fake `tmutil` that mimics getpass (prompt, echo off,
# read one line). Nothing outside this script's own temp directory is written.
#
# Run it after any change to setup.sh's step 5 or to
# set-time-machine-destination.tcl:
#
#   apps/andrew-mbp/tests/time-machine-step.test.sh
#
# Requires `expect`, which the deployment itself builds from devtools' pinned
# nixpkgs. If it is not on PATH the expect-driven cases are skipped rather than
# silently reported as passing.

set -uo pipefail

# setup.sh refuses to run anywhere but macOS on Apple Silicon, and the cases
# below drive its real code paths, so there is nothing meaningful to assert
# elsewhere. CI runs on ubuntu-latest, so skip cleanly rather than fail.
if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
  echo "SKIP  andrew-mbp Time Machine tests: macOS on Apple Silicon only (this is $(uname -s)/$(uname -m))"
  exit 0
fi

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$TESTS_DIR/../src" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A password that would be unmistakable if it ever leaked into output.
SENTINEL="S3nt1nel-PaSSw0rd-do-not-log"

# Seeds the stubbed TM_CRED_HASH_FILE with the hash of the password every case
# below uses, so the pre-existing "already configured" cases keep skipping -
# only the dedicated password-rotation case overrides NAS_PASSWORD to
# something that hashes differently.
printf '%s' "$SENTINEL" | shasum -a 256 | awk '{print $1}' > "$WORK/tm-cred-hash"

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

# Builds a runnable copy of one region of setup.sh with the privileged commands
# stubbed out. $1 is the body of the `tmutil destinationinfo` stub.
harness() {
  {
    echo 'set -euo pipefail'
    echo "SCRIPT_DIR=$SRC_DIR"
    # shellcheck disable=SC2016  # emitted verbatim into the harness, expanded there
    echo 'NAS_SHARE="${NAS_SHARE:-backup}"'
    echo "TM_CRED_HASH_FILE=$WORK/tm-cred-hash"
    echo 'sudo() { echo "[sudo] $*"; }'
    echo "tmutil() { case \"\$1\" in destinationinfo) $1 ;; isexcluded) echo \"[Included]  \$*\" ;; *) echo \"[tmutil] \$*\" ;; esac; }"
    echo 'nix_tool() { echo /stub-store-path; }'
    awk '/^echo "==> Step 5/{f=1} f' "$SRC_DIR/setup.sh"
  }
}

# Everything before step 1 - the platform check and the NAS_* validation.
preflight() {
  awk '/^echo "==> Step 1: devtools/{print "echo REACHED_STEP_1"; exit} {print}' \
    "$SRC_DIR/setup.sh"
}

echo "== NAS_* validation fails closed before anything is changed"
preflight > "$WORK/preflight.sh"

out="$(env -u NAS_HOST -u NAS_USERNAME -u NAS_PASSWORD bash "$WORK/preflight.sh" 2>&1)"
check "exits non-zero with none set" "1" "$?"
for var in NAS_HOST NAS_USERNAME NAS_PASSWORD; do
  case "$out" in
    *"- $var"*) ok "names $var" ;;
    *) fail "names $var" "not present in the error output" ;;
  esac
done
case "$out" in
  *REACHED_STEP_1*) fail "changes nothing before failing" "execution reached step 1" ;;
  *) ok "changes nothing before failing" ;;
esac

# All missing variables must be reported together, not one per re-run.
out="$(env -u NAS_USERNAME -u NAS_PASSWORD NAS_HOST=nas.example bash "$WORK/preflight.sh" 2>&1)"
case "$out:$?" in
  *"- NAS_USERNAME"*"- NAS_PASSWORD"*) ok "reports every missing variable at once" ;;
  *) fail "reports every missing variable at once" "$out" ;;
esac

out="$(NAS_HOST=h NAS_USERNAME=u NAS_PASSWORD=p bash "$WORK/preflight.sh" 2>&1)"
case "$out" in
  *REACHED_STEP_1*) ok "proceeds when all three are set" ;;
  *) fail "proceeds when all three are set" "$out" ;;
esac

echo
echo "== the destination is only reconfigured when it actually differs"
harness 'echo "URL           : smb://tmuser@nas-01._smb._tcp.local./backup"' > "$WORK/same.sh"
out="$(NAS_HOST=nas-01 NAS_USERNAME=tmuser NAS_PASSWORD="$SENTINEL" bash "$WORK/same.sh" 2>&1)"
case "$out" in
  *"already configured"*) ok "skips when the destination already matches (Bonjour-form URL)" ;;
  *) fail "skips when the destination already matches" "$out" ;;
esac

harness 'return 1' > "$WORK/none.sh"
out="$(NAS_HOST=nas-01 NAS_USERNAME=tmuser NAS_PASSWORD="$SENTINEL" bash "$WORK/none.sh" 2>&1)"
case "$out" in
  *"configuring destination"*) ok "configures when no destination is set" ;;
  *) fail "configures when no destination is set" "$out" ;;
esac

# The regression behind review-1: a moved NAS must not keep the stale target.
out="$(NAS_HOST=nas-02 NAS_USERNAME=tmuser NAS_PASSWORD="$SENTINEL" bash "$WORK/same.sh" 2>&1)"
case "$out" in
  *"configuring destination"*) ok "reconfigures when the NAS host changed" ;;
  *) fail "reconfigures when the NAS host changed" "stale destination kept: $out" ;;
esac

out="$(NAS_HOST=nas-01 NAS_USERNAME=someone-else NAS_PASSWORD="$SENTINEL" bash "$WORK/same.sh" 2>&1)"
case "$out" in
  *"configuring destination"*) ok "reconfigures when the NAS user changed" ;;
  *) fail "reconfigures when the NAS user changed" "$out" ;;
esac

# A stale share whose name merely starts with the wanted one must not be read
# as already configured; the share has to be bounded at the end of the URL.
harness 'echo "URL           : smb://tmuser@nas-01._smb._tcp.local./backup-old"' \
  > "$WORK/wrong-share.sh"
out="$(NAS_HOST=nas-01 NAS_USERNAME=tmuser NAS_PASSWORD="$SENTINEL" bash "$WORK/wrong-share.sh" 2>&1)"
case "$out" in
  *"configuring destination"*) ok "reconfigures when the share changed" ;;
  *) fail "reconfigures when the share changed" "stale destination kept: $out" ;;
esac

# user@host from one destination plus the share from another is not a match.
harness 'echo "URL           : smb://tmuser@nas-01._smb._tcp.local./backup-old"
      echo "Mount Point   : /Volumes/backup"' > "$WORK/split.sh"
out="$(NAS_HOST=nas-01 NAS_USERNAME=tmuser NAS_PASSWORD="$SENTINEL" bash "$WORK/split.sh" 2>&1)"
case "$out" in
  *"configuring destination"*) ok "reconfigures when user@host and share come from different destinations" ;;
  *) fail "reconfigures when user@host and share come from different destinations" "$out" ;;
esac

# The host is bounded as well as the share: a different host whose name merely
# starts with NAS_HOST is a stale destination, not a configured one.
harness 'echo "URL           : smb://tmuser@nas-011/backup"' > "$WORK/prefix-host.sh"
out="$(NAS_HOST=nas-01 NAS_USERNAME=tmuser NAS_PASSWORD="$SENTINEL" bash "$WORK/prefix-host.sh" 2>&1)"
case "$out" in
  *"configuring destination"*) ok "reconfigures when the configured host merely starts with NAS_HOST" ;;
  *) fail "reconfigures when the configured host merely starts with NAS_HOST" "stale destination kept: $out" ;;
esac

harness 'echo "URL           : smb://tmuser@192.168.1.50/backup"' > "$WORK/prefix-ip.sh"
out="$(NAS_HOST=192.168.1.5 NAS_USERNAME=tmuser NAS_PASSWORD="$SENTINEL" bash "$WORK/prefix-ip.sh" 2>&1)"
case "$out" in
  *"configuring destination"*) ok "reconfigures when the configured IP merely starts with NAS_HOST" ;;
  *) fail "reconfigures when the configured IP merely starts with NAS_HOST" "stale destination kept: $out" ;;
esac

# Bounding the host must not cost the plain, non-Bonjour form.
harness 'echo "URL           : smb://tmuser@nas-01/backup"' > "$WORK/plain-host.sh"
out="$(NAS_HOST=nas-01 NAS_USERNAME=tmuser NAS_PASSWORD="$SENTINEL" bash "$WORK/plain-host.sh" 2>&1)"
case "$out" in
  *"already configured"*) ok "skips when the destination already matches (plain host)" ;;
  *) fail "skips when the destination already matches (plain host)" "$out" ;;
esac

echo
echo "== a rotated NAS password is noticed even when the destination URL is not"
# The destination URL matches, but the password differs from what
# tm-cred-hash was seeded with - the idempotency check must not read that as
# "already configured", or a rotated NAS password would be silently ignored.
out="$(NAS_HOST=nas-01 NAS_USERNAME=tmuser NAS_PASSWORD=a-different-password bash "$WORK/same.sh" 2>&1)"
case "$out" in
  *"already configured"*) fail "reconfigures when the NAS password has changed" "stale credential kept: $out" ;;
  *"re-applying the credential"*) ok "reconfigures when the NAS password has changed" ;;
  *) fail "reconfigures when the NAS password has changed" "$out" ;;
esac
case "$out" in
  *"[sudo] dd of=$WORK/tm-cred-hash status=none"*) ok "records a hash of the newly applied password" ;;
  *) fail "records a hash of the newly applied password" "$out" ;;
esac
case "$out" in
  *"a-different-password"*) fail "never writes the password itself to the hash file" "leaked: $out" ;;
  *) ok "never writes the password itself to the hash file" ;;
esac

# With the destination URL AND the password both unchanged, it still skips.
out="$(NAS_HOST=nas-01 NAS_USERNAME=tmuser NAS_PASSWORD="$SENTINEL" bash "$WORK/same.sh" 2>&1)"
case "$out" in
  *"already configured"*) ok "still skips when both the destination and the password are unchanged" ;;
  *) fail "still skips when both the destination and the password are unchanged" "$out" ;;
esac

# A failing destination call aborts the run before the closing summary, so the
# remedy has to be named at the point of failure or the operator never sees it.
{
  echo 'set -euo pipefail'
  echo "SCRIPT_DIR=$SRC_DIR"
  # shellcheck disable=SC2016  # emitted verbatim into the harness, expanded there
  echo 'NAS_SHARE="${NAS_SHARE:-backup}"'
  echo "TM_CRED_HASH_FILE=$WORK/tm-cred-hash"
  echo 'sudo() { case "$*" in *set-time-machine-destination.tcl*) return 1 ;; *) echo "[sudo] $*" ;; esac; }'
  echo "tmutil() { case \"\$1\" in destinationinfo) return 1 ;; isexcluded) echo \"[Included]  \$*\" ;; *) echo \"[tmutil] \$*\" ;; esac; }"
  echo 'nix_tool() { echo /stub-store-path; }'
  awk '/^echo "==> Step 5/{f=1} f' "$SRC_DIR/setup.sh"
} > "$WORK/setdest-fails.sh"
out="$(NAS_HOST=nas-01 NAS_USERNAME=tmuser NAS_PASSWORD="$SENTINEL" bash "$WORK/setdest-fails.sh" 2>&1)"
status="$?"
check "exits non-zero when the destination cannot be set" "1" "$status"
case "$out" in
  *"Full Disk Access"*) ok "names Full Disk Access when the destination cannot be set" ;;
  *) fail "names Full Disk Access when the destination cannot be set" "$out" ;;
esac

echo
echo "== the password never leaks, even under xtrace"
out="$(NAS_HOST=nas-01 NAS_USERNAME=tmuser NAS_PASSWORD="$SENTINEL" bash -x "$WORK/none.sh" 2>&1)"
case "$out" in
  *"$SENTINEL"*) fail "sentinel absent from stdout, stderr and the xtrace" "leaked" ;;
  *) ok "sentinel absent from stdout, stderr and the xtrace" ;;
esac

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
# Refusing before the prompt is what a terminal without Full Disk Access does.
if [ -n "${FAKE_TMUTIL_REFUSE:-}" ]; then
  echo "tmutil: unable to set destination: Operation not permitted"
  exit 78
fi
# A tmutil whose prompt wording changed: it says something else and waits.
if [ -n "${FAKE_TMUTIL_WRONG_PROMPT:-}" ]; then
  printf 'Enter the password for the backup destination: '
  sleep 30
  exit 0
fi
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
    "$SRC_DIR/set-time-machine-destination.tcl" > "$WORK/script.tcl"

  export FAKE_EXPECTED_PASSWORD="$SENTINEL"

  out="$(printf '%s\n' "$SENTINEL" \
    | expect -f "$WORK/script.tcl" "smb://tmuser@nas-01/backup" 2>&1)"
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

  printf '%s\n' "the-wrong-password" \
    | expect -f "$WORK/script.tcl" "smb://tmuser@nas-01/backup" >/dev/null 2>&1
  check "propagates tmutil's exit status" "9" "$?"

  # A tmutil that refuses before prompting - the Full Disk Access case - must
  # not have its only diagnostic swallowed by the silenced prompt wait.
  out="$(printf '%s\n' "$SENTINEL" \
    | FAKE_TMUTIL_REFUSE=1 expect -f "$WORK/script.tcl" \
      "smb://tmuser@nas-01/backup" 2>&1)"
  status="$?"
  check "propagates tmutil's exit status when it refuses before prompting" "78" "$status"
  case "$out" in
    *"Operation not permitted"*) ok "reports tmutil's own error when it exits before prompting" ;;
    *) fail "reports tmutil's own error when it exits before prompting" "no diagnostic: '$out'" ;;
  esac

  # A tmutil whose prompt wording changed is the residual risk this app's
  # README records; whatever it printed instead is the only evidence of that,
  # so the timeout must not throw it away either. Same script with a short
  # timeout so the case does not sit for the real two minutes.
  sed 's|^set timeout 120$|set timeout 2|' "$WORK/script.tcl" \
    > "$WORK/script-quick.tcl"
  out="$(printf '%s\n' "$SENTINEL" \
    | FAKE_TMUTIL_WRONG_PROMPT=1 expect -f "$WORK/script-quick.tcl" \
      "smb://tmuser@nas-01/backup" 2>&1)"
  status="$?"
  check "fails when tmutil never shows the expected prompt" "1" "$status"
  case "$out" in
    *"Enter the password for the backup destination"*)
      ok "reports what tmutil printed instead of the expected prompt" ;;
    *) fail "reports what tmutil printed instead of the expected prompt" "no evidence: '$out'" ;;
  esac
  case "$out" in
    *"$SENTINEL"*) fail "never echoes the password on a prompt mismatch" "leaked: $out" ;;
    *) ok "never echoes the password on a prompt mismatch" ;;
  esac

  expect -f "$WORK/script.tcl" >/dev/null 2>&1
  check "rejects a missing destination URL" "2" "$?"

  expect -f "$WORK/script.tcl" "smb://tmuser@nas-01/backup" </dev/null >/dev/null 2>&1
  check "rejects an empty stdin" "2" "$?"
fi

echo
echo "$passes passed, $failures failed"
[ "$failures" -eq 0 ]
