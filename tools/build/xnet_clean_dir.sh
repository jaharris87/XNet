#!/bin/sh
# Remove one marked XNet build directory without following symlink roots.
set -eu
[ "$#" = 4 ] || { echo "usage: xnet_clean_dir.sh ROOT SOURCE BUILD_BASE BUILD_DIR" >&2; exit 2; }
root=$1 source=$2 base=$3 directory=$4
case "$directory" in /|"$root"|"$source"|"$base") echo "refusing unsafe BUILD_DIR: $directory" >&2; exit 2;; esac
[ ! -L "$directory" ] || { echo "refusing symlink BUILD_DIR: $directory" >&2; exit 2; }
[ -e "$directory" ] || exit 0
[ -d "$directory" ] || { echo "refusing non-directory BUILD_DIR: $directory" >&2; exit 2; }
[ -f "$directory/config.txt" ] && [ "$(sed -n '1p' "$directory/config.txt" 2>/dev/null || :)" = "XNET_CONFIG_SCHEMA=1" ] || {
  echo "refusing unmarked BUILD_DIR: $directory" >&2
  exit 2
}
rm -rf -- "$directory"
