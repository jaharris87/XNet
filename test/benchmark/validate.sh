#!/bin/sh
set -eu
[ "$#" -eq 1 ] || { echo "usage: $0 RECORD_DIRECTORY" >&2; exit 2; }; record=$1; historical=86e867c2a64267a674ce4fbf6a3064af39e2f4e0; meta=$record/metadata.tsv; manifest=$record/input.sha256; reps=$record/repetitions.tsv
[ -f "$meta" ] && [ -f "$manifest" ] && [ -f "$reps" ] || { echo "missing record files" >&2; exit 1; }
required='schema historical_source_sha source_sha source_root case_id execution_mode launcher build_config_path build_config_sha256 executable_path executable_sha256 expected_end_records repetitions_requested captured_utc host uname'; for k in $required; do n=$(awk -F '\t' -v k="$k" '$1==k{n++}END{print n+0}' "$meta"); [ "$n" -eq 1 ] || { echo "bad metadata key $k" >&2; exit 1; }; done
awk -F '\t' 'NF!=2||$1==""||$2==""{exit 1}' "$meta" || { echo "malformed metadata" >&2; exit 1; }; val(){ awk -F '\t' -v k="$1" '$1==k{print $2}' "$meta"; }
[ "$(val schema)" = xnet-v9-benchmark-record-v2 ] && [ "$(val historical_source_sha)" = "$historical" ] && [ "$(val source_sha)" = "$historical" ] && [ "$(val execution_mode)" = direct-serial ] && [ "$(val launcher)" = none ] || { echo "invalid contract binding" >&2; exit 1; }
case "$(val expected_end_records):$(val repetitions_requested)" in *[!0-9:]*|:*|*:0|0:*) echo "invalid counts" >&2; exit 1;; esac
root=$(val source_root); config=$(val build_config_path); exe=$(val executable_path); [ -e "$root/.git" ] && [ "$(git -C "$root" rev-parse HEAD)" = "$historical" ] && [ -z "$(git -C "$root" status --porcelain)" ] || { echo "dirty/unavailable source" >&2; exit 1; }
case_id=$(val case_id)
case "$case_id" in
  batch_alpha) canonical_ends=16; settings=test/test_settings_batch; setup=test/Test_Problems/setup_batch_alpha; network=test/Data_alpha; trajectory_prefix=test/Test_Problems/th_batch/ ;;
  heat_sn160) canonical_ends=6; settings=test/test_settings_heat; setup=test/Test_Problems/setup_heat_sn160; network=test/Data_SN160; trajectory_prefix=test/Test_Problems/th_co_burn_ ;;
  *) echo "unsupported case binding" >&2; exit 1 ;;
esac
[ "$(val expected_end_records)" = "$canonical_ends" ] || { echo "case/end-count binding failed" >&2; exit 1; }
expected_paths=$(mktemp "${TMPDIR:-/tmp}/xnet-benchmark-paths.XXXXXX")
actual_paths=$(mktemp "${TMPDIR:-/tmp}/xnet-benchmark-paths.XXXXXX")
trap 'rm -f "$expected_paths" "$actual_paths"' EXIT HUP INT TERM
{
  printf '%s/%s\n%s/%s\n' "$root" "$settings" "$root" "$setup"
  git -C "$root" ls-files -- "$network" | while IFS= read -r path; do printf '%s/%s\n' "$root" "$path"; done
  if [ "$case_id" = batch_alpha ]; then
    git -C "$root" ls-files -- test/Test_Problems/th_batch | while IFS= read -r path; do printf '%s/%s\n' "$root" "$path"; done
  else
    git -C "$root" ls-files -- test/Test_Problems | grep '/th_co_burn_' | while IFS= read -r path; do printf '%s/%s\n' "$root" "$path"; done
  fi
  printf '%s/tools/starkiller-helmholtz/helm_table.dat\n' "$root"
} | LC_ALL=C sort > "$expected_paths"
awk -F '\t' 'NR > 1 {print $2}' "$manifest" | LC_ALL=C sort > "$actual_paths"
cmp -s "$expected_paths" "$actual_paths" || { echo "case/input-path binding failed" >&2; exit 1; }
hash(){ if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi; }; [ -f "$config" ] && [ -x "$exe" ] && [ "$(hash "$config"|awk '{print $1}')" = "$(val build_config_sha256)" ] && [ "$(hash "$exe"|awk '{print $1}')" = "$(val executable_sha256)" ] || { echo "build binding failed" >&2; exit 1; }
for k in MPI_MODE OPENMP_MODE GPU_MODE OPENACC_MODE OPENMP_OL_MODE; do [ "$(awk -F= -v k="$k" '$1==k{print $2}' "$config")" = OFF ] || { echo "nonserial config" >&2; exit 1; }; done; [ "$(awk -F= '$1=="MATRIX_SOLVER"{print $2}' "$config")" = dense ] || exit 1
awk -F '\t' 'NR==1{if($0!="sha256\tpath")exit 1;next}NF!=2||$1!~/^[0-9a-f]{64}$/||$2!~/^\//||seen[$2]++{exit 1}END{exit NR<2}' "$manifest" || { echo "malformed manifest" >&2; exit 1; }; while IFS='	' read -r h p; do [ "$h" = sha256 ] && continue; [ -f "$p" ] && [ "$(hash "$p"|awk '{print $1}')" = "$h" ] || { echo "changed/missing input" >&2; exit 1; }; done < "$manifest"
expected=$(val expected_end_records); requested=$(val repetitions_requested); awk -F '\t' -v e="$expected" -v n="$requested" 'NR==1{if($0!="repetition\texit_status\tend_records\ttimer_setup_seconds\ttimer_total_seconds\tnumerical_success")bad=1;next}NF!=6||$1!=NR-1||$2!=0||$3!=e||$4!~/^[0-9.eE+-]+$/||$5!~/^[0-9.eE+-]+$/||($5+0)<=0||$6!="structural-pass"{bad=1}END{if(NR-1!=n)bad=1;exit bad}' "$reps" || { echo "invalid repetitions" >&2; exit 1; }
i=1; while [ "$i" -le "$requested" ]; do a=$record/repetitions/$i; [ -f "$a/stdout.txt" ] && [ -f "$a/stderr.txt" ] && [ -s "$a/net_diag01" ] && grep -q '^Timers Summary:' "$a/net_diag01" && [ "$(grep -c '^End[[:space:]]' "$a/net_diag01")" -eq "$expected" ] || { echo "missing/incomplete artifact $i" >&2; exit 1; }; i=$((i+1)); done; echo "valid benchmark record: $record"
