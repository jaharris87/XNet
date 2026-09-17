#!/bin/sh
# Called only while the global acquisition gate is held.
set -eu
[ "$#" = 1 ] || { echo "usage: clean_all_builds.sh BUILD_BASE" >&2; exit 2; }
base=$1
for lock in "$base"/*.lock; do
  [ -e "$lock" ] || continue
  echo "refusing clean-all while a build lock exists: $lock" >&2
  exit 2
done
for entry in "$base"/* "$base"/.[!.]* "$base"/..?*; do
  [ -e "$entry" ] || [ -L "$entry" ] || continue
  case "${entry##*/}" in .xnet-gate.lock) continue;; esac
  if [ -L "$entry" ]; then echo "leaving symlink $entry" >&2; continue; fi
  if [ ! -f "$entry/config.txt" ] || [ "$(sed -n '1p' "$entry/config.txt" 2>/dev/null || :)" != "XNET_CONFIG_SCHEMA=1" ]; then
    echo "leaving unrecognized $entry" >&2
    continue
  fi
  rm -rf -- "$entry"
done
