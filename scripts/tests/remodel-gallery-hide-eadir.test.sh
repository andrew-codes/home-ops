#!/usr/bin/env bash
#
# Runs the remodel-gallery Caddyfile in Docker against a scratch captures folder
# and checks that the Synology @eaDir metadata folders are never listed or served,
# while ordinary albums and images still are. Nothing outside a temp directory is
# touched; the real captures volume is never involved.
#
#   scripts/tests/remodel-gallery-hide-eadir.test.sh
#
# Requires docker and curl (skips when either is missing or the daemon is down).

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GALLERY="$TESTS_DIR/../../deployments/production/remodel-gallery"
IMAGE="${CADDY_IMAGE:-caddy:2.11.6-alpine}"
WORK="$(mktemp -d)"
NAME="gallery-eadir-test-$$"
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT

for t in docker curl; do
  command -v "$t" >/dev/null 2>&1 || { echo "SKIP  remodel-gallery-hide-eadir tests: $t is not installed"; exit 0; }
done
docker info >/dev/null 2>&1 || { echo "SKIP  remodel-gallery-hide-eadir tests: docker daemon is not running"; exit 0; }

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok    $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1"; [ -z "${2:-}" ] || echo "      $2"; }

# Scratch captures: an @eaDir at the top level and inside an album, each with a file in it.
CAP="$WORK/captures"
mkdir -p "$CAP/@eaDir" "$CAP/Game room/@eaDir/photo.jpg" "$CAP/Game room/Wide"
printf 'x' >"$CAP/@eaDir/note.jpg"
printf 'x' >"$CAP/Game room/photo.jpg"
printf 'x' >"$CAP/Game room/@eaDir/photo.jpg/SYNOPHOTO_THUMB_M.jpg"
chmod -R a+rX "$CAP"

PORT=$((20000 + RANDOM % 20000))
docker run -d --rm --name "$NAME" -p "127.0.0.1:$PORT:8080" \
  -v "$GALLERY/Caddyfile:/etc/caddy/Caddyfile:ro" -v "$CAP:/captures:ro" -v "$GALLERY/site:/srv/site:ro" \
  "$IMAGE" >/dev/null || { echo "could not start caddy"; exit 1; }
for _ in $(seq 1 50); do curl -fs "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break; sleep 0.2; done

get() { curl -s -o "$WORK/body" -w '%{http_code}' -H 'Accept: application/json' "http://127.0.0.1:$PORT$1"; }

for p in "" "Game%20room/"; do
  code="$(get "/gallery/api/albums/$p")"
  [ "$code" = 200 ] && ! grep -q '@eaDir' "$WORK/body" && ok "listing of '/$p' omits @eaDir" || bad "listing of '/$p' omits @eaDir" "HTTP $code: $(cat "$WORK/body")"
done
grep -q 'Game room' <(curl -s -H 'Accept: application/json' "http://127.0.0.1:$PORT/gallery/api/albums/") && ok "top-level listing still shows Game room" || bad "top-level listing still shows Game room"
grep -q 'photo.jpg' <(curl -s -H 'Accept: application/json' "http://127.0.0.1:$PORT/gallery/api/albums/Game%20room/") && ok "album listing still shows photo.jpg" || bad "album listing still shows photo.jpg"
grep -q 'Wide' <(curl -s -H 'Accept: application/json' "http://127.0.0.1:$PORT/gallery/api/albums/Game%20room/") && ok "album listing still shows subfolder" || bad "album listing still shows subfolder"

for p in "/gallery/api/albums/@eaDir/" "/gallery/api/albums/Game%20room/@eaDir/" "/gallery/api/albums/Game%20room/@eaDir/photo.jpg/" "/gallery/originals/@eaDir/note.jpg" "/gallery/originals/Game%20room/@eaDir/photo.jpg/SYNOPHOTO_THUMB_M.jpg"; do
  code="$(get "$p")"
  [ "$code" = 404 ] && ok "direct request $p is 404" || bad "direct request $p is 404" "got HTTP $code"
done

code="$(get "/gallery/originals/Game%20room/photo.jpg")"
[ "$code" = 200 ] && ok "ordinary original still served" || bad "ordinary original still served" "got HTTP $code"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
