#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BUILD_DIR=${BUILD_DIR:-"$ROOT/test/unit/build/mpi"}
MPIFC=${MPIFC:-mpifort}
MPIEXEC=${MPIEXEC:-mpirun}

mkdir -p "$BUILD_DIR/mod"

"$MPIFC" -g -O0 -fallow-argument-mismatch -ffree-line-length-none \
  -J"$BUILD_DIR/mod" -I"$BUILD_DIR/mod" \
  -c "$ROOT/source/xnet_types.F90" -o "$BUILD_DIR/xnet_types.o"
"$MPIFC" -g -O0 -fallow-argument-mismatch -ffree-line-length-none \
  -J"$BUILD_DIR/mod" -I"$BUILD_DIR/mod" \
  -c "$ROOT/source/xnet_parallel.F90" -o "$BUILD_DIR/xnet_parallel.o"
"$MPIFC" -g -O0 -fallow-argument-mismatch -ffree-line-length-none \
  -J"$BUILD_DIR/mod" -I"$BUILD_DIR/mod" \
  -c "$ROOT/test/mpi/test_parallel_integer_reductions.F90" \
  -o "$BUILD_DIR/test_parallel_integer_reductions.o"
"$MPIFC" -g -O0 -o "$BUILD_DIR/test_parallel_integer_reductions" \
  "$BUILD_DIR/test_parallel_integer_reductions.o" \
  "$BUILD_DIR/xnet_parallel.o" "$BUILD_DIR/xnet_types.o"

"$MPIEXEC" -n 2 "$BUILD_DIR/test_parallel_integer_reductions" wrapper-owned
"$MPIEXEC" -n 2 "$BUILD_DIR/test_parallel_integer_reductions" caller-owned

set +e
single_rank_output=$("$MPIEXEC" -n 1 \
  "$BUILD_DIR/test_parallel_integer_reductions" wrapper-owned 2>&1)
single_rank_status=$?
set -e
if [[ $single_rank_status -eq 0 ]]; then
  echo 'one-rank negative probe unexpectedly passed' >&2
  exit 1
fi
if ! grep -Fq 'requires exactly 2 MPI ranks' <<<"$single_rank_output"; then
  echo 'one-rank negative probe failed for the wrong reason' >&2
  printf '%s\n' "$single_rank_output" >&2
  exit 1
fi
