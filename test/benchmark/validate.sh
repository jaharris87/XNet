#!/bin/sh
# Validate the minimum evidence a benchmark record must retain.
set -eu
[ "$#" -eq 1 ] || { echo "usage: $0 RECORD_DIRECTORY" >&2; exit 2; }
record=$1
historical_expected=86e867c2a64267a674ce4fbf6a3064af39e2f4e0
[ -f "$record/metadata.tsv" ] && [ -f "$record/input.sha256" ] && [ -f "$record/repetitions.tsv" ] || {
  echo "missing benchmark record files in $record" >&2; exit 1
}
schema=$(awk -F '\t' '$1 == "schema" {print $2}' "$record/metadata.tsv")
source_sha=$(awk -F '\t' '$1 == "source_sha" {print $2}' "$record/metadata.tsv")
historical_sha=$(awk -F '\t' '$1 == "historical_source_sha" {print $2}' "$record/metadata.tsv")
expected=$(awk -F '\t' '$1 == "expected_end_records" {print $2}' "$record/metadata.tsv")
placement=$(awk -F '\t' '$1 == "placement" {print $2}' "$record/metadata.tsv")
worktree_status=$(awk -F '\t' '$1 == "source_worktree_status" {print $2}' "$record/metadata.tsv")
[ "$schema" = xnet-v9-benchmark-record-v1 ] || { echo "unknown record schema" >&2; exit 1; }
[ "$historical_sha" = "$historical_expected" ] || { echo "record does not name the required staging SHA" >&2; exit 1; }
[ "$source_sha" = "$historical_sha" ] || { echo "source SHA is not the declared historical SHA" >&2; exit 1; }
[ -n "$expected" ] || { echo "missing expected diagnostic count" >&2; exit 1; }
[ -n "$placement" ] || { echo "missing placement record" >&2; exit 1; }
[ "$worktree_status" = clean ] || { echo "source worktree was not recorded clean" >&2; exit 1; }
[ -s "$record/input.sha256" ] || { echo "empty input hash manifest" >&2; exit 1; }
awk -F '\t' -v expected="$expected" '
  NR == 1 { next }
  NF != 6 { bad=1; next }
  $2 != 0 || $3 != expected || $5 <= 0 || $6 != "structural-pass" { bad=1 }
  END { exit bad }
' "$record/repetitions.tsv" || { echo "a repetition did not provide complete successful diagnostics" >&2; exit 1; }
echo "valid benchmark record: $record"
