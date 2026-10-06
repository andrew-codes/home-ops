#!/usr/bin/env bash
#
# Tests scripts/bin/with-stream-token.sh with a fake `op` on PATH that returns a
# recognizable dummy secret, so no real 1Password item, token or network is
# involved. Nothing outside this script's own temp directory is written.
#
# Run it after any change to the wrapper:
#
#   scripts/tests/with-stream-token.test.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TESTS_DIR/../bin/with-stream-token.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SECRET="dummy-stream-secret_9f3a7c1e"
ACCOUNT="dummy-account-id_42"
OTHER_ACCOUNT="dummy-other-account_77"
FAKE_BIN="$WORK/bin"
EMPTY_BIN="$WORK/empty"
mkdir -p "$FAKE_BIN" "$EMPTY_BIN"

# FAKE_OP_MODE: ok (default), fail (leaks the secret on stderr, as a careless op
# might), empty (exit 0, no output), hang (waits for an approval that never comes).
cat >"$FAKE_BIN/op" <<EOF
#!/usr/bin/env bash
ref=""
for a in "\$@"; do ref="\$a"; done
case "\${FAKE_OP_MODE:-ok}" in
  fail) echo "op: error reading \$ref (value $SECRET)" >&2; exit 1 ;;
  empty) exit 0 ;;
  hang) sleep 30; exit 0 ;;
esac
case "\$ref" in
  *stream-api-token) printf '%s' '$SECRET' ;;
  op://home-ops/cloudflare/account-id) printf '%s' '$ACCOUNT' ;;
  op://other/item/acct) printf '%s' '$OTHER_ACCOUNT' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$FAKE_BIN/op"

# Child that reports what it sees without printing the secret itself.
cat >"$FAKE_BIN/child" <<'EOF'
#!/usr/bin/env bash
[ "${CF_STREAM_API_TOKEN:-}" = "$EXPECT_SECRET" ] && echo "child: token ok" || echo "child: token wrong"
[ "${CF_ACCOUNT_ID:-}" = "$EXPECT_ACCOUNT" ] && echo "child: account ok" || echo "child: account wrong"
echo "child: args=$*"
exit "${CHILD_EXIT:-0}"
EOF
chmod +x "$FAKE_BIN/child"

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok    $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1"; [ -z "${2:-}" ] || echo "      $2"; }
check() { # check "name" condition-exit-status [detail]
  if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1" "${3:-}"; fi
}
no_leak() { # no_leak "name" -- the dummy secret is not in $OUT
  check "$1: secret not in output" "$(printf '%s' "$OUT" | grep -qF "$SECRET" && echo 1 || echo 0)"
}

run() { # run args... ; stdout+stderr in $OUT, status in $RC
  OUT="$(env PATH="$FAKE_BIN:$PATH" \
    STREAM_TOKEN_OP_TIMEOUT=2 EXPECT_SECRET="$SECRET" EXPECT_ACCOUNT="$ACCOUNT" "$@" 2>&1)"
  RC=$?
}

echo "--- command runs with the credentials"
run "$SCRIPT" child one "two words"
check "exit status 0" "$RC" "$OUT"
check "child sees the token" "$(printf '%s' "$OUT" | grep -q 'child: token ok' && echo 0 || echo 1)" "$OUT"
check "child sees the account id from 1Password" "$(printf '%s' "$OUT" | grep -q 'child: account ok' && echo 0 || echo 1)" "$OUT"
check "arguments pass through" "$(printf '%s' "$OUT" | grep -qF 'child: args=one two words' && echo 0 || echo 1)" "$OUT"
no_leak "success"
check "quiet: only the child's own output" "$([ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 3 ] && echo 0 || echo 1)" "$OUT"

echo "--- account id sources"
run CF_ACCOUNT_ID="env-account-id" "$SCRIPT" child
check "CF_ACCOUNT_ID from the environment wins" "$(printf '%s' "$OUT" | grep -q 'child: account wrong' && echo 0 || echo 1)" "$OUT"
run EXPECT_ACCOUNT="$OTHER_ACCOUNT" STREAM_ACCOUNT_ID_OP_REF="op://other/item/acct" "$SCRIPT" child
check "STREAM_ACCOUNT_ID_OP_REF overrides the default reference" "$(printf '%s' "$OUT" | grep -q 'child: account ok' && echo 0 || echo 1)" "$OUT"
run STREAM_ACCOUNT_ID_OP_REF="op://home-ops/cloudflare/missing-field" "$SCRIPT" child
check "missing account-id field fails" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"
check "missing field error names the account id" "$(printf '%s' "$OUT" | grep -q 'CF_ACCOUNT_ID' && echo 0 || echo 1)" "$OUT"
check "child did not run" "$(printf '%s' "$OUT" | grep -q 'child:' && echo 1 || echo 0)"
no_leak "missing account id field"

echo "--- exit code passes through"
run CHILD_EXIT=7 "$SCRIPT" child
check "child exit 7 is returned" "$([ "$RC" -eq 7 ] && echo 0 || echo 1)" "rc=$RC"
no_leak "non-zero child"

echo "--- --check"
run "$SCRIPT" --check
check "--check succeeds" "$RC" "$OUT"
check "--check prints only ok" "$([ "$OUT" = ok ] && echo 0 || echo 1)" "$OUT"
no_leak "--check"
run FAKE_OP_MODE=fail "$SCRIPT" --check
check "--check fails when op fails" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"
no_leak "--check failure"
run FAKE_OP_MODE=empty "$SCRIPT" --check
check "--check fails on an empty value" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)" "$OUT"

echo "--- failures"
run FAKE_OP_MODE=fail "$SCRIPT" child
check "op failure is non-zero" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"
check "op failure says what to do" "$(printf '%s' "$OUT" | grep -q 'op whoami' && echo 0 || echo 1)" "$OUT"
check "child did not run" "$(printf '%s' "$OUT" | grep -q 'child:' && echo 1 || echo 0)"
no_leak "op failure (op's stderr carries the secret)"

run FAKE_OP_MODE=hang "$SCRIPT" child
check "approval timeout is non-zero" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"
check "timeout mentions the desktop app and retry" "$(printf '%s' "$OUT" | grep -q 'desktop app may be waiting for approval' && printf '%s' "$OUT" | grep -q 'retry' && echo 0 || echo 1)" "$OUT"
no_leak "timeout"

OUT="$(env PATH="$EMPTY_BIN:/usr/bin:/bin" "$(command -v bash)" "$SCRIPT" child 2>&1)"
RC=$?
check "missing op is non-zero" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"
check "missing op is named" "$(printf '%s' "$OUT" | grep -q 'not installed' && echo 0 || echo 1)" "$OUT"

run "$SCRIPT" no-such-command-here
check "unknown command fails clearly" "$([ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'no such command' && echo 0 || echo 1)" "$OUT"
no_leak "unknown command"

run "$SCRIPT"
check "no command prints usage and fails" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)" "rc=$RC"

echo "--- xtrace is refused"
OUT="$(env PATH="$FAKE_BIN:$PATH" bash -x "$SCRIPT" child 2>&1)"
RC=$?
check "bash -x refuses" "$([ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'xtrace' && echo 0 || echo 1)" "$OUT"
no_leak "bash -x"
OUT="$(env PATH="$FAKE_BIN:$PATH" SHELLOPTS=xtrace bash "$SCRIPT" child 2>&1)"
RC=$?
check "SHELLOPTS=xtrace refuses" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)" "$OUT"
no_leak "SHELLOPTS=xtrace"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
