#!/usr/bin/env bash
#
# Run a command with the Cloudflare Stream credentials in its environment, read
# from 1Password with the op CLI, without anyone having to see, print, export or
# paste the token.
#
# Usage:
#   with-stream-token.sh <command> [args...]
#   with-stream-token.sh --check
#   with-stream-token.sh -h | --help
#
# Example:
#   scripts/bin/with-stream-token.sh scripts/bin/remodel-gallery-publish-video.sh \
#     "Kitchen flythrough.mov" "<captures volume>/Kitchen"
#
# The wrapper reads the values with `op read` into variables inside itself, then
# execs the command with CF_ACCOUNT_ID and CF_STREAM_API_TOKEN set for that one
# process and nothing else. It never prints, logs or writes them, and they are
# never in an argument list or a file. It is quiet unless something fails.
#
#   --check   only confirm that both values are readable and not empty: prints
#             "ok", or a plain error. Nothing else is printed.
#
# Where the values come from:
#   CF_STREAM_API_TOKEN   op://home-ops/cloudflare/stream-api-token
#                         (override the reference with STREAM_TOKEN_OP_REF)
#   CF_ACCOUNT_ID         the CF_ACCOUNT_ID already in your environment if set (the
#                         account id is not a secret), otherwise the 1Password
#                         reference in STREAM_ACCOUNT_ID_OP_REF
#
# Other settings:
#   STREAM_TOKEN_OP_TIMEOUT   seconds to wait for each read (default 60). The
#                             1Password desktop app may be waiting for approval.
#
# Never run this with `set -x` or `bash -x`; it refuses to, since a trace would
# print the values.
#
# Docs: https://docs.home.smith-simms.family/wiki/spaces/HA/pages/266436609

set -euo pipefail

# A trace would print every assignment, values included.
case "$-" in *x*) echo "error: refusing to run with xtrace on (set +x, or drop bash -x); it would print the credentials" >&2; exit 1 ;; esac
case ":${SHELLOPTS:-}:" in *:xtrace:*) echo "error: refusing to run with xtrace on (unset SHELLOPTS); it would print the credentials" >&2; exit 1 ;; esac

TOKEN_REF="${STREAM_TOKEN_OP_REF:-op://home-ops/cloudflare/stream-api-token}"
ACCOUNT_REF="${STREAM_ACCOUNT_ID_OP_REF:-}"
TIMEOUT="${STREAM_TOKEN_OP_TIMEOUT:-60}"

usage() { sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"; }
die() { echo "error: $*" >&2; exit 1; }

# read_ref REF NAME: read one 1Password reference into the variable named NAME.
# op's stderr is discarded, so nothing it prints can reach the terminal.
read_ref() {
  local ref="$1" name="$2" value="" rc=0
  # Process substitution, so the value goes through a pipe and never a file.
  # read -t is the timeout: the desktop app may be waiting on an approval prompt.
  IFS= read -r -t "$TIMEOUT" value < <(op read --no-newline "$ref" 2>/dev/null) || rc=$?
  if [ "$rc" -gt 128 ]; then
    die "timed out after ${TIMEOUT}s reading $name from 1Password. The 1Password desktop app may be waiting for approval: approve it and retry"
  fi
  [ -n "$value" ] || die "could not read $name from 1Password (not signed in, access not approved, or the item or field is missing). Run \`op whoami\`, sign in or approve in the 1Password app, and retry"
  printf -v "$name" '%s' "$value"
}

main() {
  local check=0
  case "${1:-}" in
    -h | --help) usage; exit 0 ;;
    --check) check=1; shift ;;
    "") usage >&2; exit 2 ;;
    --) shift ;;
  esac
  if [ "$check" -eq 0 ] && [ $# -eq 0 ]; then usage >&2; exit 2; fi
  [ "$check" -eq 0 ] || [ $# -eq 0 ] || die "--check takes no command"

  command -v op >/dev/null 2>&1 || die "the 1Password CLI (op) is not installed (brew install 1password-cli)"
  if [ "$check" -eq 0 ]; then
    command -v "$1" >/dev/null 2>&1 || die "no such command: $1"
  fi

  local CF_STREAM_API_TOKEN=""
  read_ref "$TOKEN_REF" CF_STREAM_API_TOKEN
  if [ -z "${CF_ACCOUNT_ID:-}" ]; then
    [ -n "$ACCOUNT_REF" ] || die "no account id: set CF_ACCOUNT_ID (it is not a secret) or STREAM_ACCOUNT_ID_OP_REF to its 1Password reference"
    local CF_ACCOUNT_ID=""
    read_ref "$ACCOUNT_REF" CF_ACCOUNT_ID
  fi

  if [ "$check" -eq 1 ]; then
    echo ok
    return 0
  fi
  # Assignments on exec reach only the exec'd process.
  CF_ACCOUNT_ID="$CF_ACCOUNT_ID" CF_STREAM_API_TOKEN="$CF_STREAM_API_TOKEN" exec "$@"
}

main "$@"
