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
# Mimics tmutil's getpass prompt: echo off, prompt, read one line.
stty -echo 2>/dev/null
printf 'Destination password: '
IFS= read -r pw
stty echo 2>/dev/null
printf '\n'
[ "$pw" = "$FAKE_EXPECTED_PASSWORD" ] && exit 0
exit 9
FAKE
  chmod +x "$WORK/fake-tmutil"
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

  printf '%s\n' "the-wrong-password" \
    | expect -f "$WORK/script.tcl" "smb://tmuser@nas-01/backup" >/dev/null 2>&1
  check "propagates tmutil's exit status" "9" "$?"

  expect -f "$WORK/script.tcl" >/dev/null 2>&1
  check "rejects a missing destination URL" "2" "$?"

  expect -f "$WORK/script.tcl" "smb://tmuser@nas-01/backup" </dev/null >/dev/null 2>&1
  check "rejects an empty stdin" "2" "$?"
fi

echo
echo "$passes passed, $failures failed"
[ "$failures" -eq 0 ]
