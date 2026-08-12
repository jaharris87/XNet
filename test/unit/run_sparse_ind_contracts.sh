#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 WORK_DIR SPARSE_IND_CONTRACT_EXE" >&2
  exit 1
fi

work_dir=$1
executable=$2
mutation_log="$work_dir/transform-mutation.log"

mkdir -p "$work_dir"
"$executable" "$work_dir"

if XNET_PARDISO_TRANSFORM_MUTATION=missing-heat-entry \
    "$executable" "$work_dir" >"$mutation_log" 2>&1; then
  echo "sparse_ind tests did not detect a missing PARDISO heat entry" >&2
  exit 1
fi
if [[ $(grep -Fc '[FAILED]' "$mutation_log") -ne 1 ]] || \
    ! grep -Fq '... PARDISO heat augmentation and remapping [FAILED]' "$mutation_log" || \
    ! grep -Fq '1 test(s) failed' "$mutation_log"; then
  echo "sparse_ind mutation did not fail only the intended PARDISO transformation test" >&2
  cat "$mutation_log" >&2
  exit 1
fi

echo "sparse_ind reader and PARDISO transformation contracts passed"
