#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <source>" >&2
  exit 1
fi

SRC="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$SCRIPT_DIR/restore.log"

echo "=== restore started $(date) ===" >> "$LOG"

pids=()
users=()
tmplogs=()
for user_backup in "$SRC"/*/; do
  [[ -d "$user_backup" ]] || continue
  user="$(basename "$user_backup")"
  [[ $user == "Shared" || $user == ".localized" ]] && continue
  dest="/Users/$user"
  if [[ ! -d "$dest" ]]; then
    echo "Skipping $user: /Users/$user does not exist" | tee -a "$LOG" >&2
    continue
  fi
  tmplog="$(mktemp)"
  rsync -aHv --delete --ignore-errors --no-perms --no-owner --no-group \
    --exclude='.DS_Store' \
    --exclude='OneDrive*/' \
    "$user_backup" "$dest/" > "$tmplog" 2>&1 &
  pids+=($!)
  users+=("$user")
  tmplogs+=("$tmplog")
done

failed=0
for i in "${!pids[@]}"; do
  pid="${pids[$i]}"
  user="${users[$i]}"
  tmplog="${tmplogs[$i]}"
  wait "$pid" && rc=0 || rc=$?
  echo "=== $user (exit $rc) ===" >> "$LOG"
  cat "$tmplog" >> "$LOG"
  rm -f "$tmplog"
  if [[ $rc -ne 0 && $rc -ne 23 && $rc -ne 24 ]]; then
    echo "rsync failed for $user (exit $rc)" | tee -a "$LOG" >&2
    failed=1
  fi
done

echo "=== restore finished $(date) ===" >> "$LOG"
[[ $failed -eq 0 ]] || exit 1
