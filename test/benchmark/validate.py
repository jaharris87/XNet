#!/usr/bin/env python3
"""Validate a portable V9 benchmark record without requiring a live checkout."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import re
import sys
from typing import Any

from benchmark import (
    BenchmarkError,
    HISTORICAL_SHA,
    TIMER_NAMES,
    inventory,
    manifest_digest,
    read_record,
    read_registry,
    sha256,
)

HARNESS_FILES = {
    "benchmark.py",
    "capture.py",
    "validate.py",
    "test_benchmark.py",
    "cases.json",
}
COUNTER_NAMES = {"TS", "NR", "Jacobian", "Deriv", "CrossSect"}


def as_finite_nonnegative(value: object, message: str) -> float:
    """Convert a record number while reporting malformed JSON as a rejection."""
    if isinstance(value, bool):
        raise BenchmarkError(message)
    try:
        number = float(value)
    except (TypeError, ValueError) as error:
        raise BenchmarkError(message) from error
    if not math.isfinite(number) or number < 0.0:
        raise BenchmarkError(message)
    return number


def read_json(path: Path, message: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise BenchmarkError(message) from error
    if not isinstance(value, dict):
        raise BenchmarkError(message)
    return value


def validate_harness_identity(document: dict[str, object]) -> None:
    capture = document.get("capture", {})
    harness = capture.get("harness", {}) if isinstance(capture, dict) else {}
    if not isinstance(harness, dict):
        raise BenchmarkError("missing harness identity")

    revision = harness.get("repository_revision")
    files = harness.get("files")
    if harness.get("dirty") is not False:
        raise BenchmarkError("harness must be captured from a clean committed revision")
    if not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise BenchmarkError("malformed harness revision")
    if not isinstance(files, dict) or set(files) != HARNESS_FILES:
        raise BenchmarkError("harness file set mismatch")

    for name, digest in files.items():
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise BenchmarkError("malformed harness hash")
        if sha256(Path(__file__).parent / name) != digest:
            raise BenchmarkError(f"current harness hash mismatch: {name}")


def validate_case_and_execution(
    document: dict[str, object],
    cases: dict[str, Any],
    profiles: dict[str, dict[str, Any]],
) -> tuple[Any, dict[str, object]]:
    case_document = document.get("case")
    if not isinstance(case_document, dict):
        raise BenchmarkError("missing case binding")
    case_id = case_document.get("case_id")
    if not isinstance(case_id, str) or case_id not in cases:
        raise BenchmarkError("unknown benchmark case")

    case = cases[case_id]
    if case.status != "ready":
        raise BenchmarkError("record binds a case that is not ready")
    if case_document.get("network") != case.network:
        raise BenchmarkError("case relabel or network binding mismatch")
    if case_document.get("workload") != case.workload:
        raise BenchmarkError("case relabel or workload binding mismatch")
    if case_document.get("input_identity") != case.input_identity:
        raise BenchmarkError("case relabel or input binding mismatch")

    execution = document.get("execution")
    if not isinstance(execution, dict):
        raise BenchmarkError("missing execution profile")
    profile_name = execution.get("profile")
    if not isinstance(profile_name, str) or profile_name not in profiles:
        raise BenchmarkError("unknown execution profile")
    expected_execution = {"profile": profile_name, **profiles[profile_name]}
    if execution != expected_execution:
        raise BenchmarkError("execution profile does not match the registry")

    expected = case.expected
    if document.get("expected") != expected:
        raise BenchmarkError("expected outputs or zones do not match the case registry")
    return case, expected


def validate_input_bundle(
    document: dict[str, object],
    identity: dict[str, Any],
) -> list[dict[str, str]]:
    bundle = document.get("input_bundle")
    if not isinstance(bundle, dict):
        raise BenchmarkError("missing input-bundle manifest")
    entries = bundle.get("entries")
    if not isinstance(entries, list) or not entries:
        raise BenchmarkError("missing input-bundle manifest")

    seen: set[str] = set()
    checked_entries: list[dict[str, str]] = []
    for entry in entries:
        if not isinstance(entry, dict):
            raise BenchmarkError("malformed input manifest entry")
        path = entry.get("path")
        digest = entry.get("sha256")
        if not isinstance(path, str) or not path:
            raise BenchmarkError("malformed input-bundle path")
        if path.startswith("/") or ".." in Path(path).parts or path in seen:
            raise BenchmarkError("malformed input-bundle path")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise BenchmarkError(f"malformed input hash: {path}")
        seen.add(path)
        checked_entries.append({"path": path, "sha256": digest})

    if bundle.get("type") != "historical-source-manifest":
        raise BenchmarkError("unsupported input-bundle type")
    if bundle.get("revision") != HISTORICAL_SHA:
        raise BenchmarkError("input bundle does not bind the historical source")
    if bundle.get("manifest_sha256") != manifest_digest(checked_entries):
        raise BenchmarkError("input manifest digest mismatch")
    if manifest_digest(checked_entries) != identity.get("manifest_sha256"):
        raise BenchmarkError("input manifest binding mismatch")

    required_paths = {
        identity.get(key)
        for key in ("control", "reference", "helm_table", "comparator")
    }
    if not required_paths <= seen:
        raise BenchmarkError("case input identity binding mismatch")
    network_root = identity.get("network_root")
    if not isinstance(network_root, str) or not any(
        path.startswith(network_root) for path in seen
    ):
        raise BenchmarkError("case network input identity binding mismatch")
    trajectory_root = identity.get("trajectory_root")
    if trajectory_root and not any(path.startswith(trajectory_root) for path in seen):
        raise BenchmarkError("case trajectory input identity binding mismatch")
    return checked_entries


def validate_timer_section(section: object) -> dict[str, float]:
    if not isinstance(section, dict) or set(section) != set(TIMER_NAMES):
        raise BenchmarkError("timer section does not contain the full timer set")
    return {
        name: as_finite_nonnegative(section[name], "invalid timer section value")
        for name in TIMER_NAMES
    }


def validate_repetition(
    repetition: object,
    number: int,
    expected: dict[str, object],
    record: Path,
) -> None:
    if not isinstance(repetition, dict):
        raise BenchmarkError("malformed repetition")
    if repetition.get("number") != number:
        raise BenchmarkError("repetition number mismatch")
    if repetition.get("numerical_result") != "pass":
        raise BenchmarkError("numerical comparison did not pass")
    if repetition.get("structural_result") != "pass":
        raise BenchmarkError("structural capture result did not pass")
    if as_finite_nonnegative(
        repetition.get("process_wall_seconds"),
        "repetition lacks finite positive process wall time",
    ) <= 0.0:
        raise BenchmarkError("repetition lacks finite positive process wall time")

    timers = repetition.get("timers_seconds")
    if not isinstance(timers, dict) or set(timers) != set(TIMER_NAMES):
        raise BenchmarkError("repetition lacks the full timer set")
    checked_timers = {
        name: as_finite_nonnegative(timers[name], "invalid timer value")
        for name in TIMER_NAMES
    }
    if checked_timers["Total"] <= 0.0:
        raise BenchmarkError("repetition lacks positive Total timer")

    sections = repetition.get("timer_sections_seconds")
    expected_section_count = expected.get("timer_sections")
    if not isinstance(sections, list) or len(sections) != expected_section_count:
        raise BenchmarkError("unexpected timer section count")
    checked_sections = [validate_timer_section(section) for section in sections]
    if checked_sections[-1] != checked_timers:
        raise BenchmarkError("timer sections do not end with cumulative timers")

    counters = repetition.get("counters")
    if not isinstance(counters, dict):
        raise BenchmarkError("missing diagnostic counters")
    if counters.get("end_records") != len(expected["zones"]):
        raise BenchmarkError("diagnostic end-record count mismatch")
    if counters.get("timer_sections") != expected_section_count:
        raise BenchmarkError("diagnostic timer-section count mismatch")

    zone_counters = counters.get("zones")
    expected_zones = {str(zone) for zone in expected["zones"]}
    if not isinstance(zone_counters, dict) or set(zone_counters) != expected_zones:
        raise BenchmarkError("per-zone counter coverage mismatch")
    for values in zone_counters.values():
        if not isinstance(values, dict) or set(values) != COUNTER_NAMES:
            raise BenchmarkError("invalid per-zone counter values")
        if any(not isinstance(value, int) or value < 0 for value in values.values()):
            raise BenchmarkError("invalid per-zone counter values")

    artifact = record / "repetitions" / str(number)
    required_artifacts = (
        "net_diag01",
        "comparison.json",
        "xnet.stdout.txt",
        "xnet.stderr.txt",
        "xnet.status.txt",
    )
    if any(not (artifact / name).is_file() for name in required_artifacts):
        raise BenchmarkError("missing retained repetition artifacts")
    comparison = read_json(
        artifact / "comparison.json",
        "missing or malformed comparison result",
    )
    if comparison.get("result") != "pass":
        raise BenchmarkError("comparison did not pass")
    if comparison.get("timing_excluded") is not True:
        raise BenchmarkError("comparison was not excluded from timing")
    status = (artifact / "xnet.status.txt").read_text(encoding="utf-8").strip()
    if status != "return_code=0":
        raise BenchmarkError("XNet did not retain a zero direct status")


def validate_inventory(record: Path) -> None:
    try:
        recorded = json.loads((record / "inventory.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise BenchmarkError("missing or malformed inventory.json") from error
    if not isinstance(recorded, list) or recorded != inventory(record):
        raise BenchmarkError("artifact inventory is incomplete or tampered")


def rehydrate(
    repository: Path | None,
    executable: Path | None,
    entries: list[dict[str, str]],
    document: dict[str, object],
) -> None:
    if repository:
        for entry in entries:
            source = repository.resolve() / entry["path"]
            if not source.is_file() or sha256(source) != entry["sha256"]:
                raise BenchmarkError(f"rehydration input mismatch: {entry['path']}")
    if executable:
        capture = document.get("capture")
        if isinstance(capture, dict):
            expected = capture.get("executable", {}).get("sha256")
        else:
            expected = None
        if not executable.is_file() or sha256(executable) != expected:
            raise BenchmarkError("rehydration executable mismatch")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("record", type=Path)
    parser.add_argument(
        "--repository",
        type=Path,
        help="optional historical checkout for rehydration checks",
    )
    parser.add_argument(
        "--executable",
        type=Path,
        help="optional executable whose hash is checked",
    )
    args = parser.parse_args()

    record = args.record.resolve()
    document = read_record(record)
    validate_harness_identity(document)
    if document.get("historical_source_sha") != HISTORICAL_SHA:
        raise BenchmarkError("record does not bind the exact historical source")
    if document.get("source_sha") != HISTORICAL_SHA:
        raise BenchmarkError("record source SHA is not historical")

    cases, profiles = read_registry(Path(__file__).parent)
    case, expected = validate_case_and_execution(document, cases, profiles)
    entries = validate_input_bundle(document, case.input_identity)

    capture = document.get("capture")
    repetitions = document.get("repetitions")
    requested = capture.get("repetitions_requested") if isinstance(capture, dict) else None
    if not isinstance(repetitions, list) or not isinstance(requested, int):
        raise BenchmarkError("missing repetition list")
    if requested < 1 or len(repetitions) != requested:
        raise BenchmarkError("missing or short repetition list")
    for number, repetition in enumerate(repetitions, start=1):
        validate_repetition(repetition, number, expected, record)

    validate_inventory(record)
    rehydrate(args.repository, args.executable, entries, document)
    print(f"valid benchmark record: {record}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BenchmarkError as error:
        print(f"validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
