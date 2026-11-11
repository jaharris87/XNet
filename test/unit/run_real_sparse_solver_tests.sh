#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 SOLVER WORK_DIR EXECUTABLE CONTROLS" >&2
  exit 1
fi

solver=$1
work_root=$2
executable=$3
tracked_controls=$4

case "$solver" in
  ma48)
    failure_diagnostic='Error during MA48'
    ;;
  pardiso-mkl)
    failure_diagnostic='PARDISO factorization failed'
    ;;
  *)
    echo "unsupported real sparse solver: $solver" >&2
    exit 1
    ;;
esac

run_case() {
  local mode=$1
  local work_dir="$work_root/$mode"
  local status

  mkdir -p "$work_dir"
  if (
    cd "$work_dir"
    "$executable" "$mode" .
  ); then
    status=0
  else
    status=$?
  fi
  echo "$solver $mode process status=$status"
  return "$status"
}

run_tracked_controls() {
  local work_dir="$work_root/tracked-controls"
  local status

  mkdir -p "$work_dir"
  cp "$tracked_controls" "$work_dir/sparse_controls.nml"
  if (
    cd "$work_dir"
    XNET_USE_EXISTING_CONTROLS=1 "$executable" base .
  ); then
    status=0
  else
    status=$?
  fi
  echo "$solver tracked-controls process status=$status"
  return "$status"
}

expect_solver_failure() {
  local work_dir="$work_root/solver-failure"
  local log_file="$work_dir/output.log"
  local status

  mkdir -p "$work_dir"
  if (
    cd "$work_dir"
    "$executable" failure .
  ) >"$log_file" 2>&1; then
    echo "$solver accepted controlled failure input" >&2
    exit 1
  else
    status=$?
  fi
  if ! grep -Fq "$failure_diagnostic" "$log_file"; then
    echo "$solver failure probe did not reach the expected production status path" >&2
    cat "$log_file" >&2
    exit 1
  fi
  echo "$solver controlled-failure process status=$status diagnostic='$failure_diagnostic'"
}

expect_result_mutation_failure() {
  local mutation=$1
  local diagnostic=$2
  local work_dir="$work_root/result-mutation-$mutation"
  local log_file="$work_dir/output.log"
  local status

  mkdir -p "$work_dir"
  if (
    cd "$work_dir"
    XNET_SPARSE_REAL_MUTATION="$mutation" "$executable" base .
  ) >"$log_file" 2>&1; then
    echo "$solver result check accepted mutation $mutation" >&2
    exit 1
  else
    status=$?
  fi
  if ! grep -Fq "$diagnostic" "$log_file"; then
    echo "$solver result mutation $mutation did not fail for its intended reason" >&2
    cat "$log_file" >&2
    exit 1
  fi
  echo "$solver result-mutation=$mutation process status=$status diagnostic='$diagnostic'"
}

run_case base
run_case heat
run_tracked_controls
expect_solver_failure
expect_result_mutation_failure excessive_residual 'solver residual exceeds limit'
expect_result_mutation_failure nan_result 'nonfinite solver result'
expect_result_mutation_failure positive_infinity_result 'nonfinite solver result'
expect_result_mutation_failure negative_infinity_result 'nonfinite solver result'

echo "$solver real-library sparse solver tests passed"
