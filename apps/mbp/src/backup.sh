#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <destination>" >&2
  exit 1
fi

DEST="$1"

pids=()
for user_dir in /Users/*/; do
  user="$(basename "$user_dir")"
  [[ "$user" == "Shared" || "$user" == ".localized" ]] && continue
  rsync -aHv \
    --exclude='.DS_Store' \
    --exclude='.Trash/' \
    --exclude='Pictures/' \
    --exclude='Applications/' \
    --exclude='Library/' \
    --exclude='Parallels/' \
    --exclude='solidlsp_tmp/' \
    --exclude='Public/' \
    "$user_dir" "$DEST/$user/" &
  pids+=($!)
done

for pid in "${pids[@]}"; do
  wait "$pid" || { echo "rsync failed for PID $pid" >&2; exit 1; }
done
