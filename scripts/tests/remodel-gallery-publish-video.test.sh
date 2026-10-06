#!/usr/bin/env bash
#
# Tests scripts/bin/remodel-gallery-publish-video.sh against a local stand-in for
# the Cloudflare Stream API (mock-stream-api.py), so no account, token or network
# is involved. Nothing outside this script's own temp directory is written.
#
# Run it after any change to the script:
#
#   scripts/tests/remodel-gallery-publish-video.test.sh
#
# Requires curl, jq and python3.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TESTS_DIR/../bin/remodel-gallery-publish-video.sh"
MOCK="$TESTS_DIR/mock-stream-api.py"
WORK="$(mktemp -d)"
MOCK_PID=""
cleanup() { [ -z "$MOCK_PID" ] || kill "$MOCK_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

for t in curl jq python3; do
  command -v "$t" >/dev/null 2>&1 || { echo "SKIP  remodel-gallery-publish-video tests: $t is not installed"; exit 0; }
done

TOKEN="stream-test-token_0123456789"
PORT=$((20000 + RANDOM % 20000))
pass=0
fail=0

ok() { pass=$((pass + 1)); echo "ok    $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1"; [ -z "${2:-}" ] || echo "      $2"; }
check() { # check "name" condition-exit-status [detail]
  if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1" "${3:-}"; fi
}

start_mock() { # start_mock [flags...]
  stop_mock
  rm -rf "$WORK/state"
  mkdir -p "$WORK/state"
  python3 "$MOCK" "$PORT" "$WORK/state" "$TOKEN" "$@" &
  MOCK_PID=$!
  for _ in $(seq 1 50); do [ -e "$WORK/state/ready" ] && return 0; sleep 0.1; done
  echo "mock did not start"; exit 1
}
stop_mock() { [ -z "$MOCK_PID" ] || { kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null; MOCK_PID=""; }; }

run() { # run args... ; leaves output in $OUT and status in $RC
  OUT="$(env CF_ACCOUNT_ID=acct123 CF_STREAM_API_TOKEN="$TOKEN" CF_STREAM_API_BASE="http://127.0.0.1:$PORT" \
    STREAM_TUS_CHUNK_MIB=1 STREAM_POLL_SECONDS=0 "$@" 2>&1)"
  RC=$?
}

# A 2.5 MiB file: three chunks at 1 MiB, the last one short.
SRC="$WORK/Kitchen flythrough.mov"
head -c 2621440 /dev/urandom >"$SRC"
ALBUM="$WORK/album"
mkdir -p "$ALBUM"

echo "--- upload and sidecar"
start_mock
run GALLERY_ALLOWED_ORIGINS="gallery.example.com, www.example.com" "$SCRIPT" "$SRC" "$ALBUM" --thumb-at 4
check "exit status 0" "$RC" "$OUT"
SIDECAR="$ALBUM/Kitchen flythrough.stream.json"
UID_="$(jq -r .uid "$SIDECAR" 2>/dev/null)"
check "sidecar is written under the title" "$([ -f "$SIDECAR" ] && echo 0 || echo 1)"
check "sidecar title" "$([ "$(jq -r .title "$SIDECAR")" = "Kitchen flythrough" ] && echo 0 || echo 1)"
check "sidecar player url" "$([ "$(jq -r .iframe "$SIDECAR")" = "https://customer-mock.cloudflarestream.com/$UID_/iframe" ] && echo 0 || echo 1)" "$(cat "$SIDECAR")"
check "sidecar thumbnail url" "$([ "$(jq -r .thumbnail "$SIDECAR")" = "https://customer-mock.cloudflarestream.com/$UID_/thumbnails/thumbnail.jpg" ] && echo 0 || echo 1)"
check "sidecar thumb-at" "$([ "$(jq -r .thumbAt "$SIDECAR")" = "4s" ] && echo 0 || echo 1)"
check "uploaded bytes match the source" "$(cmp -s "$SRC" "$WORK/state/$UID_.bin" && echo 0 || echo 1)"
check "no temp file is left in the album" "$([ "$(find "$ALBUM" -type f | wc -l | tr -d ' ')" = 1 ] && echo 0 || echo 1)" "$(find "$ALBUM" -type f)"
check "upload was chunked" "$([ "$(jq -s '[.[] | select(.method=="PATCH")] | length' "$WORK/state/requests.jsonl")" = 3 ] && echo 0 || echo 1)"
check "upload metadata carries the title" "$([ "$(jq -r 'select(.metadata) | .metadata' "$WORK/state/requests.jsonl" | cut -d' ' -f2 | base64 -d)" = "Kitchen flythrough" ] && echo 0 || echo 1)"
check "allowed origins set, trimmed" "$([ "$(jq -c 'select(.body) | .body.allowedOrigins' "$WORK/state/requests.jsonl")" = '["gallery.example.com","www.example.com"]' ] && echo 0 || echo 1)"
check "token only ever sent as a bearer header" "$([ "$(jq -r 'select(.auth != null) | .auth' "$WORK/state/requests.jsonl" | sort -u)" = "Bearer $TOKEN" ] && echo 0 || echo 1)"
check "token not echoed in output" "$(printf '%s' "$OUT" | grep -qF "$TOKEN" && echo 1 || echo 0)"
check "waited for ready" "$(printf '%s' "$OUT" | grep -q 'ready' && echo 0 || echo 1)" "$OUT"

echo "--- refuses to overwrite a sidecar"
run "$SCRIPT" "$SRC" "$ALBUM"
check "second publish under the same name fails" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"
check "and says why" "$(printf '%s' "$OUT" | grep -q 'already exists' && echo 0 || echo 1)" "$OUT"

echo "--- resume after a failed chunk"
start_mock fail-first-patch
ALBUM2="$WORK/album2"
mkdir -p "$ALBUM2"
run "$SCRIPT" "$SRC" "$ALBUM2" --name "Resumed" --no-wait
check "exit status 0" "$RC" "$OUT"
UID_="$(jq -r .uid "$ALBUM2/Resumed.stream.json" 2>/dev/null)"
check "bytes still match" "$(cmp -s "$SRC" "$WORK/state/$UID_.bin" && echo 0 || echo 1)"
check "the failed chunk was retried from Stream's offset" "$(grep -q '"method": "HEAD"' "$WORK/state/requests.jsonl" && echo 0 || echo 1)"
check "no thumbAt when not asked" "$([ "$(jq 'has("thumbAt")' "$ALBUM2/Resumed.stream.json")" = false ] && echo 0 || echo 1)"

echo "--- wrong token"
start_mock
ALBUM3="$WORK/album3"
mkdir -p "$ALBUM3"
run CF_STREAM_API_TOKEN=nope "$SCRIPT" "$SRC" "$ALBUM3"
check "fails" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"
check "explains the token or account" "$(printf '%s' "$OUT" | grep -q 'Stream: Edit' && echo 0 || echo 1)" "$OUT"
check "writes no sidecar" "$([ -z "$(find "$ALBUM3" -type f)" ] && echo 0 || echo 1)"

echo "--- a failed encode"
start_mock encode-error
ALBUM4="$WORK/album4"
mkdir -p "$ALBUM4"
run "$SCRIPT" "$SRC" "$ALBUM4"
check "exits non-zero" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"
check "reports Stream's reason" "$(printf '%s' "$OUT" | grep -q 'unsupported codec' && echo 0 || echo 1)" "$OUT"

echo "--- upload URL on an unexpected host"
start_mock evil-location
ALBUM5="$WORK/album5"
mkdir -p "$ALBUM5"
run "$SCRIPT" "$SRC" "$ALBUM5"
check "refuses to send the token there" "$([ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'unexpected host' && echo 0 || echo 1)" "$OUT"
check "no PATCH was made" "$([ "$(jq -s '[.[] | select(.method=="PATCH")] | length' "$WORK/state/requests.jsonl")" = 0 ] && echo 0 || echo 1)"

echo "--- sidecar only, with --uid and an explicit hostname"
start_mock
ALBUM6="$WORK/album6"
mkdir -p "$ALBUM6"
run "$SCRIPT" "$SRC" "$WORK/album6x" --no-wait
check "a missing album folder is refused" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"
run "$SCRIPT" "$SRC" "$ALBUM6" --no-wait
UID6="$(jq -r .uid "$ALBUM6/Kitchen flythrough.stream.json")"
ALBUM7="$WORK/album7"
mkdir -p "$ALBUM7"
run STREAM_CUSTOMER_SUBDOMAIN=customer-override.cloudflarestream.com "$SCRIPT" --uid "$UID6" "$ALBUM7" --name "From uid" --no-wait
check "exit status 0" "$RC" "$OUT"
check "uses the override hostname" "$([ "$(jq -r .iframe "$ALBUM7/From uid.stream.json")" = "https://customer-override.cloudflarestream.com/$UID6/iframe" ] && echo 0 || echo 1)"

echo "--- missing configuration"
OUT="$(env -u CF_ACCOUNT_ID CF_STREAM_API_TOKEN=x "$SCRIPT" "$SRC" "$ALBUM" 2>&1)"
RC=$?
check "names the missing variable" "$([ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q CF_ACCOUNT_ID && echo 0 || echo 1)" "$OUT"
run "$SCRIPT" "$SRC" "$ALBUM" --name ".hidden"
check "refuses a title starting with a dot" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"
run "$SCRIPT" "$SRC" "$ALBUM" --name "a/b"
check "refuses a title with a slash" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"

stop_mock
echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
