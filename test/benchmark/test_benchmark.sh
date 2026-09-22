#!/bin/sh
# Focused record false-pass probes.  Supply a freshly captured valid record.
set -eu
[ "$#" -eq 1 ] || { echo "usage: $0 VALID_RECORD" >&2; exit 2; }
record=$1
root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
sh "$root/validate.sh" "$record"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/xnet-benchmark-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
reject() { name=$1; shift; if "$@" >/dev/null 2>&1; then echo "false pass: $name" >&2; exit 1; fi; }
copy() { cp -R "$record" "$tmp/$1"; }
copy garbage; printf 'not a manifest\n' > "$tmp/garbage/input.sha256"; reject garbage-manifest sh "$root/validate.sh" "$tmp/garbage"
copy zero; head -1 "$tmp/zero/repetitions.tsv" > "$tmp/zero/rows"; mv "$tmp/zero/rows" "$tmp/zero/repetitions.tsv"; reject zero-rows sh "$root/validate.sh" "$tmp/zero"
copy short; awk -F '\t' 'BEGIN{OFS="\t"} $1=="repetitions_requested" {$2=$2+1} {print}' "$tmp/short/metadata.tsv" > "$tmp/short/meta"; mv "$tmp/short/meta" "$tmp/short/metadata.tsv"; reject short-rows sh "$root/validate.sh" "$tmp/short"
copy missing; sed '2s@/.*@/does/not/exist@' "$tmp/missing/input.sha256" > "$tmp/missing/manifest"; mv "$tmp/missing/manifest" "$tmp/missing/input.sha256"; reject missing-input sh "$root/validate.sh" "$tmp/missing"
copy artifact; rm "$tmp/artifact/repetitions/1/net_diag01"; reject missing-artifact sh "$root/validate.sh" "$tmp/artifact"
copy topology; sed 's/^execution_mode\t.*/execution_mode\tmpi/' "$tmp/topology/metadata.tsv" > "$tmp/topology/meta"; mv "$tmp/topology/meta" "$tmp/topology/metadata.tsv"; reject topology-substitution sh "$root/validate.sh" "$tmp/topology"
copy relabel; awk -F '\t' 'BEGIN{OFS="\t"} $1=="case_id" {$2=($2=="batch_alpha" ? "heat_sn160" : "batch_alpha")} {print}' "$tmp/relabel/metadata.tsv" > "$tmp/relabel/meta"; mv "$tmp/relabel/meta" "$tmp/relabel/metadata.tsv"; reject case-relabel sh "$root/validate.sh" "$tmp/relabel"
if sh "$root/capture.sh" --executable /bin/true >/dev/null 2>&1; then echo "false pass: fake executable option" >&2; exit 1; fi
echo "benchmark false-pass probes: passed"
