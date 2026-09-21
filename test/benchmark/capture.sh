#!/bin/sh
# Capture one exact-staging standalone baseline with raw XNet timer values.
set -eu

historical_sha=86e867c2a64267a674ce4fbf6a3064af39e2f4e0

usage() {
  echo "usage: $0 --repository DIR --executable FILE --case batch_alpha|heat_sn160 --placement TEXT --records DIR [--repetitions N]" >&2
  exit 2
}

repository= executable= case= placement= records= repetitions=5
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repository|--executable|--case|--placement|--records|--repetitions)
      [ "$#" -ge 2 ] || usage
      case "$1" in
        --repository) repository=$2 ;;
        --executable) executable=$2 ;;
        --case) case=$2 ;;
        --placement) placement=$2 ;;
        --records) records=$2 ;;
        --repetitions) repetitions=$2 ;;
      esac
      shift 2
      ;;
    *) usage ;;
  esac
done

[ -n "$repository" ] && [ -n "$executable" ] && [ -n "$case" ] && [ -n "$placement" ] && [ -n "$records" ] || usage
case "$repetitions" in *[!0-9]*|'') usage ;; esac
[ "$repetitions" -gt 0 ] || usage

repository=$(cd "$repository" && pwd -P)
executable=$(cd "$(dirname "$executable")" && pwd -P)/$(basename "$executable")
[ -x "$executable" ] || { echo "executable is not runnable: $executable" >&2; exit 2; }
source_sha=$(git -C "$repository" rev-parse HEAD)
[ "$source_sha" = "$historical_sha" ] || {
  echo "refusing non-historical source $source_sha; expected $historical_sha" >&2
  exit 2
}
[ -z "$(git -C "$repository" status --porcelain)" ] || {
  echo "refusing a source worktree with tracked changes" >&2
  exit 2
}

case "$case" in
  batch_alpha)
    settings=$repository/test/test_settings_batch
    setup_file=$repository/test/Test_Problems/setup_batch_alpha
    network=Data_alpha
    trajectories=th_batch
    expected_ends=16
    ;;
  heat_sn160)
    settings=$repository/test/test_settings_heat
    setup_file=$repository/test/Test_Problems/setup_heat_sn160
    network=Data_SN160
    trajectories=co_burn
    expected_ends=6
    ;;
  *) echo "case is not a ready standalone baseline: $case" >&2; exit 2 ;;
esac

[ -f "$settings" ] && [ -f "$setup_file" ] && [ -d "$repository/test/$network" ] || {
  echo "required tracked input is absent for $case" >&2; exit 2
}

mkdir -p "$records"
run_id=${case}-$(date -u +%Y%m%dT%H%M%SZ)-$$
record=$records/$run_id
mkdir "$record"
mkdir "$record/repetitions"

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi
}

hash_tracked_tree() {
  git -C "$repository" ls-files -- "$1" | while IFS= read -r file; do
    hash_file "$repository/$file"
  done
}

{
  printf 'schema\txnet-v9-benchmark-record-v1\n'
  printf 'historical_source_sha\t%s\n' "$historical_sha"
  printf 'source_sha\t%s\n' "$source_sha"
  printf 'case_id\t%s\n' "$case"
  printf 'executable_path\t%s\n' "$executable"
  printf 'executable_sha256\t%s\n' "$(hash_file "$executable" | awk '{print $1}')"
  printf 'build_config_path\t%s\n' "$(dirname "$executable")/../config.txt"
  printf 'command\t%s\n' "$executable"
  printf 'placement\t%s\n' "$placement"
  printf 'source_worktree_status\tclean\n'
  printf 'expected_end_records\t%s\n' "$expected_ends"
  printf 'repetitions_requested\t%s\n' "$repetitions"
  printf 'host\t%s\n' "$(hostname)"
  printf 'uname\t%s\n' "$(uname -a)"
  printf 'compiler_version\tsee build-config.txt and operator note\n'
  printf 'captured_utc\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$record/metadata.tsv"
[ -f "$(dirname "$executable")/../config.txt" ] && cp "$(dirname "$executable")/../config.txt" "$record/build-config.txt"
{
  hash_file "$settings"
  hash_file "$setup_file"
  hash_tracked_tree "test/$network"
  if [ "$trajectories" = th_batch ]; then
    hash_tracked_tree test/Test_Problems/th_batch
  else
    git -C "$repository" ls-files -- test/Test_Problems | grep '/th_co_burn_' | while IFS= read -r file; do
      hash_file "$repository/$file"
    done
  fi
  hash_file "$repository/tools/starkiller-helmholtz/helm_table.dat"
} > "$record/input.sha256"

printf 'repetition\texit_status\tend_records\ttimer_setup_seconds\ttimer_total_seconds\tnumerical_success\n' > "$record/repetitions.tsv"
rep=1
while [ "$rep" -le "$repetitions" ]; do
  work=$(mktemp -d "${TMPDIR:-/tmp}/xnet-benchmark.XXXXXX")
  trap 'rm -rf "$work"' EXIT HUP INT TERM
  cat "$settings" "$setup_file" > "$work/control"
  mkdir "$work/Test_Results"
  cp -R "$repository/test/$network" "$work/$network"
  ln -s "$repository/tools/starkiller-helmholtz/helm_table.dat" "$work/helm_table.dat"
  if [ "$trajectories" = th_batch ]; then
    mkdir "$work/Test_Problems"
    ln -s "$repository/test/Test_Problems/th_batch" "$work/Test_Problems/th_batch"
  else
    mkdir "$work/Test_Problems"
    for trajectory in "$repository"/test/Test_Problems/th_co_burn_*; do
      ln -s "$trajectory" "$work/Test_Problems/$(basename "$trajectory")"
    done
  fi
  set +e
  (cd "$work" && "$executable") > "$record/repetitions/$rep.stdout.txt" 2> "$record/repetitions/$rep.stderr.txt"
  status=$?
  set -e
  mkdir "$record/repetitions/$rep"
  cp "$work"/net_diag* "$record/repetitions/$rep/" 2>/dev/null || true
  diagnostics=$record/repetitions/$rep
  end_records=$(grep -h '^End[[:space:]]' "$diagnostics"/net_diag* 2>/dev/null | wc -l | tr -d ' ')
  setup_timer=$(awk '$1 == "Setup" { value=$2 } END { print value+0 }' "$diagnostics"/net_diag* 2>/dev/null || printf '0')
  total=$(awk '$1 == "Total" { value=$2 } END { print value+0 }' "$diagnostics"/net_diag* 2>/dev/null || printf '0')
  numerical=no
  if [ "$status" -eq 0 ] && [ "$end_records" -eq "$expected_ends" ] && [ "$total" != 0 ]; then numerical=structural-pass; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$rep" "$status" "$end_records" "$setup_timer" "$total" "$numerical" >> "$record/repetitions.tsv"
  rm -rf "$work"
  trap - EXIT HUP INT TERM
  rep=$((rep + 1))
done

sh "$(dirname "$0")/validate.sh" "$record"
echo "$record"
