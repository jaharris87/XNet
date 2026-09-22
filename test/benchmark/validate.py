#!/usr/bin/env python3
"""Validate a portable V9 benchmark record without requiring a live checkout."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

from benchmark import BenchmarkError, HISTORICAL_SHA, inventory, manifest_digest, read_cases, read_record, sha256


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("record", type=Path)
    parser.add_argument("--repository", type=Path, help="optional historical checkout for rehydration checks")
    parser.add_argument("--executable", type=Path, help="optional executable whose hash is checked")
    args = parser.parse_args()
    record = args.record.resolve()
    document = read_record(record)
    cases = read_cases(Path(__file__).parent)
    case_id = document.get("case", {}).get("case_id")
    if document.get("historical_source_sha") != HISTORICAL_SHA or document.get("source_sha") != HISTORICAL_SHA:
        raise BenchmarkError("record does not bind the exact historical source")
    if case_id not in cases or cases[case_id].status != "ready" or document.get("case", {}).get("network") != cases[case_id].network or document.get("case", {}).get("workload") != cases[case_id].workload or document.get("case", {}).get("input_identity") != cases[case_id].input_identity:
        raise BenchmarkError("case relabel or registry binding mismatch")
    if document.get("execution", {}).get("profile") != "serial-dense" or document["execution"].get("launcher") != "none":
        raise BenchmarkError("unsupported execution profile")
    expected = cases[case_id].expected
    if document.get("expected") != expected:
        raise BenchmarkError("expected outputs or zones do not match the case registry")
    identity = cases[case_id].input_identity
    entries = document.get("input_bundle", {}).get("entries")
    if not isinstance(entries, list) or not entries:
        raise BenchmarkError("missing input-bundle manifest")
    seen = set()
    for entry in entries:
        path = entry.get("path", "") if isinstance(entry, dict) else ""
        if not path or path.startswith("/") or ".." in Path(path).parts or path in seen:
            raise BenchmarkError("malformed input-bundle path")
        seen.add(path)
        if not isinstance(entry.get("sha256"), str):
            raise BenchmarkError(f"malformed input hash: {path}")
    if document.get("input_bundle", {}).get("type") != "historical-source-manifest" or document["input_bundle"].get("revision") != HISTORICAL_SHA or document["input_bundle"].get("manifest_sha256") != manifest_digest(entries) or manifest_digest(entries) != identity.get("manifest_sha256"):
        raise BenchmarkError("input manifest binding mismatch")
    required_paths = {identity.get(key) for key in ("control", "reference", "helm_table", "comparator")}
    if not required_paths <= seen or not any(path.startswith(identity.get("network_root", "!")) for path in seen):
        raise BenchmarkError("case input identity binding mismatch")
    trajectory_root = identity.get("trajectory_root")
    if trajectory_root and not any(path.startswith(trajectory_root) for path in seen):
        raise BenchmarkError("case trajectory input identity binding mismatch")
    repetitions = document.get("repetitions")
    if not isinstance(repetitions, list) or len(repetitions) != document.get("capture", {}).get("repetitions_requested") or not repetitions:
        raise BenchmarkError("missing or short repetition list")
    for index, repetition in enumerate(repetitions, 1):
        if repetition.get("number") != index or repetition.get("numerical_result") != "pass" or repetition.get("structural_result") != "pass":
            raise BenchmarkError("failed or malformed repetition")
        timers = repetition.get("timers_seconds", {})
        if not isinstance(timers, dict) or float(timers.get("Total", 0.0)) <= 0:
            raise BenchmarkError("repetition lacks positive Total timer")
        counters = repetition.get("counters", {})
        if counters.get("end_records") != len(expected["zones"]):
            raise BenchmarkError("diagnostic end-record count mismatch")
        artifact = record / "repetitions" / str(index)
        if not (artifact / "net_diag01").is_file() or not (artifact / "comparison.json").is_file() or not (artifact / "xnet.stdout.txt").is_file() or not (artifact / "xnet.stderr.txt").is_file():
            raise BenchmarkError("missing retained repetition artifacts")
        comparison = json.loads((artifact / "comparison.json").read_text(encoding="utf-8"))
        if comparison.get("result") != "pass" or comparison.get("timing_excluded") is not True:
            raise BenchmarkError("comparison did not pass outside the timing interval")
        if (artifact / "xnet.status.txt").read_text(encoding="utf-8").strip() != "return_code=0":
            raise BenchmarkError("XNet did not retain a zero direct status")
    recorded_inventory = __import__("json").loads((record / "inventory.json").read_text(encoding="utf-8"))
    if recorded_inventory != inventory(record):
        raise BenchmarkError("artifact inventory is incomplete or tampered")
    if args.repository:
        for entry in entries:
            source = args.repository.resolve() / entry["path"]
            if not source.is_file() or sha256(source) != entry["sha256"]:
                raise BenchmarkError(f"rehydration input mismatch: {entry['path']}")
    if args.executable and (not args.executable.is_file() or sha256(args.executable) != document["capture"]["executable"]["sha256"]):
        raise BenchmarkError("rehydration executable mismatch")
    print(f"valid benchmark record: {record}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BenchmarkError as error:
        print(f"validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
