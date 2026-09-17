#!/bin/sh
set -eu
[ "$#" -ge 3 ] || { echo "usage: xnet_lock.sh GATE DIR command..." >&2; exit 2; }
gate=$1 dir=$2; shift 2
mkdir -p "$(dirname "$gate")"
limit=${XNET_GATE_RETRIES:-200}
case "$limit" in ''|*[!0-9]*) echo "XNET_GATE_RETRIES must be a positive integer" >&2; exit 2;; esac
attempt=0
while ! mkdir "$gate" 2>/dev/null; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge "$limit" ]; then
    echo "another XNet build/clean is acquiring a lock; retry or remove a confirmed stale gate" >&2
    exit 2
  fi
  sleep 0.05
done
release_gate() { rmdir "$gate" 2>/dev/null || :; }; trap release_gate EXIT HUP INT TERM
if ! mkdir "$dir" 2>/dev/null; then owner=unknown; [ -f "$dir/owner" ] && owner=$(cat "$dir/owner" 2>/dev/null || :); echo "BUILD_DIR is busy ($owner); wait or choose another BUILD_DIR" >&2; exit 2; fi
token="$$.$(date +%s 2>/dev/null || echo unknown)"
printf 'pid=%s host=%s\n' "$$" "$(hostname 2>/dev/null || echo unknown)" > "$dir/owner"
printf '%s\n' "$token" > "$dir/token"
release_gate; trap - EXIT HUP INT TERM
cleanup() { rm -f "$dir/owner" "$dir/token"; rmdir "$dir" 2>/dev/null || :; }; trap cleanup EXIT HUP INT TERM
XNET_LOCK_TOKEN=$token XNET_LOCK_DIR=$dir
export XNET_LOCK_TOKEN XNET_LOCK_DIR
"$@"
