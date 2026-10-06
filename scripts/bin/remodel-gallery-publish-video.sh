#!/usr/bin/env bash
#
# Publish a video to the Remodel Gallery: upload it to Cloudflare Stream, which
# encodes it and serves it, then write the small <name>.stream.json file the
# gallery lists it from into the album folder on the captures volume.
#
# Stream hosts and encodes the video, streams it adaptively, and makes its
# thumbnail, so the source can be whatever the render produced (MP4, MOV, ...;
# see Stream's supported inputs). The gallery pod holds no credentials and never
# touches the video: the browser plays it straight from Stream.
#
# Usage:
#   remodel-gallery-publish-video.sh <source-video> <album-folder> [options]
#   remodel-gallery-publish-video.sh --uid <stream-video-id> <album-folder> [options]
#
#   <source-video>   the file to upload (a copy goes up; the file is never changed)
#   <album-folder>   the album's folder on the captures volume, as mounted on this
#                    machine (the folder the album's images are copied into).
#                    The sidecar is written there.
#   --uid ID         skip the upload and only write the sidecar for a video that is
#                    already in Stream (for example after a failed run)
#
# Options:
#   --name TITLE       title shown in the gallery and used as the sidecar's file
#                      name (default: the source's file name without extension)
#   --thumb-at TIME    frame used for the thumbnail and the player's poster,
#                      such as 4s (default 1s)
#   --no-wait          do not wait for Stream to finish encoding
#   -h, --help         this text
#
# Environment (never committed; set it in your shell profile or a local env file):
#   CF_ACCOUNT_ID                Cloudflare account id
#   CF_STREAM_API_TOKEN          API token with Stream: Edit on that account, and
#                                nothing else. Sent only to Cloudflare, never on a
#                                command line.
#   GALLERY_ALLOWED_ORIGINS      optional, comma-separated hostnames allowed to play
#                                the video (the gallery's public hostname, for
#                                example gallery.example.com). Set on the video
#                                in Stream. Strongly recommended; see the docs.
#   STREAM_CUSTOMER_SUBDOMAIN    optional, customer-<code>.cloudflarestream.com.
#                                Normally read from Stream's reply for the upload.
#
# Requires: curl, jq (both ship with recent macOS; otherwise brew install jq).
#
# Large files go up over Stream's resumable (tus) upload in 50 MiB chunks. If a
# chunk fails the script asks Stream where it stands and carries on from there.
#
# Docs: https://docs.home.smith-simms.family/wiki/spaces/HA/pages/266436609

set -euo pipefail

API="${CF_STREAM_API_BASE:-https://api.cloudflare.com/client/v4}"
CHUNK_MIB="${STREAM_TUS_CHUNK_MIB:-50}"
POLL_SECONDS="${STREAM_POLL_SECONDS:-10}"
POLL_LIMIT="${STREAM_POLL_LIMIT:-360}"

usage() { sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"; }
die() { echo "error: $*" >&2; exit 1; }
say() { echo "==> $*" >&2; }

# Hosts the API token may be sent to when Stream hands back an upload URL.
host_of() { printf '%s' "$1" | sed -E 's#^[a-z]+://([^/:?]+).*#\1#'; }
trusted_host() {
  local h
  h="$(host_of "$1")"
  [ "$h" = "$(host_of "$API")" ] && return 0
  case "$h" in *.cloudflare.com | *.cloudflarestream.com | *.videodelivery.net) return 0 ;; esac
  return 1
}

# curl with the API token passed as a config file on a pipe, so it never shows up
# in the process list. Extra args follow; the first is a URL.
api_curl() {
  local url="$1"
  shift
  if trusted_host "$url"; then
    curl -sS --config <(printf 'header = "Authorization: Bearer %s"\n' "$CF_STREAM_API_TOKEN") "$url" "$@"
  else
    curl -sS "$url" "$@"
  fi
}

# Headers from a response dump, case-insensitive name, CR stripped.
header() { awk -v k="$1" 'tolower($1) == tolower(k ":") {sub(/^[^:]*:[ \t]*/, ""); sub(/\r$/, ""); print; exit}' <<<"$2"; }

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

# Ask Stream how many bytes of the upload it holds.
server_offset() {
  local out
  out="$(api_curl "$1" -I -H "Tus-Resumable: 1.0.0")" || return 1
  header Upload-Offset "$out"
}

# Upload the file in chunks to the tus upload URL, resuming after a failure.
tus_upload() {
  local url="$1" file="$2" size="$3" chunk=$((CHUNK_MIB * 1048576)) offset=0 attempt=0 out status new
  while [ "$offset" -lt "$size" ]; do
    out="$({ tail -c +$((offset + 1)) "$file" | head -c "$chunk" || true; } |
      api_curl "$url" -i -X PATCH --data-binary @- \
        -H "Tus-Resumable: 1.0.0" -H "Upload-Offset: $offset" \
        -H "Content-Type: application/offset+octet-stream")" || out=""
    status="$(awk 'NR==1{print $2}' <<<"$out")"
    new="$(header Upload-Offset "$out")"
    if [ "${status:-}" = 204 ] && [ -n "$new" ]; then
      offset="$new"
      attempt=0
      printf '\r==> uploading: %d%%' $((offset * 100 / size)) >&2
    else
      attempt=$((attempt + 1))
      [ $attempt -le 3 ] || { echo >&2; die "upload failed at byte $offset (HTTP ${status:-none}); run again, or see --help"; }
      echo >&2
      say "chunk failed (HTTP ${status:-none}); asking Stream where it stands (try $attempt of 3)"
      sleep 2
      new="$(server_offset "$url" || true)"
      [ -z "$new" ] || offset="$new"
    fi
    [ "$chunk" -gt 0 ] || die "bad chunk size"
  done
  echo >&2
}

main() {
  local src="" album="" title="" thumb_at="" uid="" wait=1 have_album=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --uid) [ $# -ge 2 ] || die "--uid needs a value"; uid="$2"; shift 2 ;;
      --name) [ $# -ge 2 ] || die "--name needs a value"; title="$2"; shift 2 ;;
      --thumb-at) [ $# -ge 2 ] || die "--thumb-at needs a value"; thumb_at="$2"; shift 2 ;;
      --no-wait) wait=0; shift ;;
      -h | --help) usage; exit 0 ;;
      -*) die "unknown option $1" ;;
      *)
        if [ -z "$uid" ] && [ -z "$src" ] && [ $have_album -eq 0 ]; then src="$1"
        elif [ $have_album -eq 0 ]; then album="$1"; have_album=1
        else die "unexpected argument $1"; fi
        shift ;;
    esac
  done
  # With --uid the one positional is the album folder.
  if [ -n "$uid" ] && [ -n "$src" ] && [ $have_album -eq 0 ]; then album="$src"; src=""; have_album=1; fi
  { [ -n "$src" ] || [ -n "$uid" ]; } && [ $have_album -eq 1 ] || { usage >&2; exit 2; }

  command -v curl >/dev/null 2>&1 || die "curl is not installed"
  command -v jq >/dev/null 2>&1 || die "jq is not installed (brew install jq)"
  [ -n "${CF_ACCOUNT_ID:-}" ] || die "set CF_ACCOUNT_ID (see --help)"
  [ -n "${CF_STREAM_API_TOKEN:-}" ] || die "set CF_STREAM_API_TOKEN (see --help)"
  [ -d "$album" ] || die "no such album folder: $album"
  [ -w "$album" ] || die "album folder is not writable: $album"
  if [ -n "$thumb_at" ]; then
    printf '%s' "$thumb_at" | grep -Eq '^[0-9]+(\.[0-9]+)?s?$' || die "--thumb-at must look like 4s"
    case "$thumb_at" in *s) ;; *) thumb_at="${thumb_at}s" ;; esac
  fi

  if [ -z "$title" ]; then
    if [ -n "$src" ]; then title="$(basename "$src")"; title="${title%.*}"; else title="$uid"; fi
  fi
  case "$title" in "" | . | .. | .* | */* | *\\*) die "title \"$title\" cannot be empty, start with a dot, or contain a slash or backslash" ;; esac
  if printf '%s' "$title" | LC_ALL=C grep -q '[[:cntrl:]]'; then die "title must not contain control characters"; fi
  local sidecar="$album/$title.stream.json"
  [ ! -e "$sidecar" ] || die "$sidecar already exists; pick another --name, or remove it first"

  local acct="$API/accounts/$CF_ACCOUNT_ID/stream"

  if [ -z "$uid" ]; then
    [ -f "$src" ] || die "no such file: $src"
    local size
    size="$(wc -c <"$src" | tr -d ' ')"
    [ "$size" -gt 0 ] || die "$src is empty"

    say "creating the upload ($((size / 1048576)) MiB)"
    local out status loc
    out="$(api_curl "$acct" -i -X POST -H "Tus-Resumable: 1.0.0" -H "Upload-Length: $size" \
      -H "Upload-Metadata: name $(b64 "$title")")" || die "could not reach Stream"
    status="$(awk 'NR==1{print $2}' <<<"$out")"
    [ "$status" = 201 ] || die "Stream refused the upload (HTTP ${status:-none}). Check CF_ACCOUNT_ID and that the token has Stream: Edit. Reply: $(printf '%s' "$out" | tail -n 1 | cut -c1-300)"
    loc="$(header Location "$out")"
    uid="$(header stream-media-id "$out")"
    [ -n "$loc" ] && [ -n "$uid" ] || die "Stream's reply had no upload URL or video id"
    trusted_host "$loc" || die "Stream returned an upload URL on an unexpected host ($(host_of "$loc")); not sending the token there"
    say "video id: $uid"
    tus_upload "$loc" "$src" "$size"
  fi

  # Restrict where the video plays, and name it for the Stream dashboard.
  local patch
  patch="$(jq -n --arg name "$title" --arg origins "${GALLERY_ALLOWED_ORIGINS:-}" \
    '{meta: {name: $name}} + (if $origins == "" then {} else {allowedOrigins: ($origins | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != "")))} end)')"
  out="$(api_curl "$acct/$uid" -X POST -H "Content-Type: application/json" --data "$patch")" || die "could not update the video's settings"
  [ "$(jq -r '.success // false' <<<"$out" 2>/dev/null)" = true ] || die "Stream did not accept the video's settings: $(printf '%s' "$out" | cut -c1-300)"
  if [ -z "${GALLERY_ALLOWED_ORIGINS:-}" ]; then
    say "warning: GALLERY_ALLOWED_ORIGINS is not set, so this video plays on any site that has its address"
  fi

  # Work out the customer hostname the player and thumbnails are served from.
  local host="${STREAM_CUSTOMER_SUBDOMAIN:-}"
  if [ -z "$host" ]; then
    local u
    u="$(jq -r '.result.thumbnail // .result.preview // .result.playback.hls // empty' <<<"$out")"
    [ -n "$u" ] || { out="$(api_curl "$acct/$uid")"; u="$(jq -r '.result.thumbnail // .result.preview // .result.playback.hls // empty' <<<"$out")"; }
    [ -z "$u" ] || host="$(host_of "$u")"
  fi
  [ -n "$host" ] || die "could not tell Stream's customer hostname; set STREAM_CUSTOMER_SUBDOMAIN (customer-<code>.cloudflarestream.com) and run again with --uid $uid"
  # (localhost is accepted only so the script can be tested against a local stand-in.)
  local scheme=https
  case "$host" in
    *.cloudflarestream.com | *.videodelivery.net) ;;
    localhost:* | 127.0.0.1:*) scheme=http ;;
    *) die "unexpected Stream hostname \"$host\"" ;;
  esac
  jq -n --arg uid "$uid" --arg title "$title" --arg thumbAt "$thumb_at" \
    --arg iframe "$scheme://$host/$uid/iframe" --arg thumb "$scheme://$host/$uid/thumbnails/thumbnail.jpg" \
    '{uid: $uid, title: $title, iframe: $iframe, thumbnail: $thumb} + (if $thumbAt == "" then {} else {thumbAt: $thumbAt} end)' \
    >"$album/.$title.stream.json.tmp"
  mv "$album/.$title.stream.json.tmp" "$sidecar"
  say "wrote $sidecar"

  if [ $wait -eq 1 ]; then
    say "waiting for Stream to finish encoding (Ctrl-C is safe: the sidecar is written and the video finishes on its own)"
    local i state
    for ((i = 0; i < POLL_LIMIT; i++)); do
      out="$(api_curl "$acct/$uid")" || die "could not reach Stream"
      state="$(jq -r '.result.status.state // "unknown"' <<<"$out")"
      case "$state" in
        ready) say "ready: it shows in the gallery on the next page load"; return 0 ;;
        error) die "Stream could not encode the video: $(jq -r '.result.status.errorReasonText // .result.status.errorReasonCode // "no reason given"' <<<"$out")" ;;
      esac
      sleep "$POLL_SECONDS"
    done
    say "still encoding after $((POLL_LIMIT * POLL_SECONDS / 60)) minutes; it will appear when Stream finishes"
  else
    say "uploaded; Stream is encoding it. The gallery tile shows a plain video tile until it is ready"
  fi
}

main "$@"
