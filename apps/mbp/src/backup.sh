#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <destination>" >&2
  exit 1
fi

DEST="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$SCRIPT_DIR/backup.log"

echo "=== backup started $(date) ===" >> "$LOG"

pids=()
users=()
tmplogs=()
for user_dir in /Users/*/; do
  user="$(basename "$user_dir")"
  [[ $user == "Shared" || $user == ".localized" ]] && continue
  tmplog="$(mktemp)"
  rsync -aHv --delete --ignore-errors --no-perms --no-owner --no-group \
    --exclude='.DS_Store' \
    --exclude='.Trash/' \
    --exclude='Pictures/' \
    --exclude='Applications/' \
    --exclude='Library/' \
    --exclude='Parallels/' \
    --exclude='solidlsp_tmp/' \
    --exclude='.npm/' \
    --exclude='.local/' \
    --exclude='Public/' \
    --exclude='.cache/' \
    --exclude='OneDrive*/' \
    --exclude='node_modules/' \
    --exclude='.nvm/' \
    --exclude='.serena/language_servers/' \
    --exclude='.vscode/extensions/' \
    --exclude='/.yarn/' \
    --exclude='/Documents/WindowsPowerShell/' \
    "$user_dir" "$DEST/$user/" > "$tmplog" 2>&1 &
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

echo "=== backup finished $(date) ===" >> "$LOG"
[[ $failed -eq 0 ]] || exit 1
