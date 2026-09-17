#!/bin/sh
# clean-all holds the acquisition gate from lock scan through deletion.
set -eu
[ "$#" = 4 ] || { echo "usage: xnet_clean_all.sh GATE ROOT SOURCE BUILD_BASE" >&2; exit 2; }
gate=$1 root=$2 source=$3 base=$4
case "$base" in /|"$root"|"$source") echo "refusing unsafe BUILD_BASE: $base" >&2; exit 2;; esac
[ ! -L "$base" ] || { echo "refusing symlink BUILD_BASE: $base" >&2; exit 2; }
if [ -e "$base" ] && [ ! -d "$base" ]; then echo "refusing non-directory BUILD_BASE: $base" >&2; exit 2; fi
mkdir -p "$base"
if ! mkdir "$gate" 2>/dev/null; then echo "another XNet build/clean is acquiring a lock; retry" >&2; exit 2; fi
cleanup() { rmdir "$gate" 2>/dev/null || :; }; trap cleanup EXIT HUP INT TERM
"$(dirname "$0")/clean_all_builds.sh" "$base"
