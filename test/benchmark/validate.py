#!/usr/bin/env python3
"""Validate a portable V9 benchmark record without requiring a live checkout."""

from __future__ import annotations

import argparse
from dataclasses import replace
from datetime import datetime
import json
import math
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Any

from benchmark import (
    BenchmarkError,
    HISTORICAL_SHA,
    TIMER_NAMES,
    inventory,
    load_regression,
    manifest_digest,
    read_record,
    read_registry,
    parse_diagnostic_metrics,
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


def read_config_values(path: Path) -> dict[str, str]:
    return {
        key: value
        for line in path.read_text(encoding="utf-8").splitlines()
        if "=" in line
        for key, value in [line.split("=", 1)]
    }


def retained_path(record: Path, value: object, message: str) -> Path:
    if not isinstance(value, str):
        raise BenchmarkError(message)
    relative = Path(value)
    if relative.is_absolute() or ".." in relative.parts:
        raise BenchmarkError(message)
    return record / relative


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
    try:
        current = subprocess.check_output(
            ["git", "-C", str(Path(__file__).resolve().parents[2]), "rev-parse", "HEAD"],
            text=True,
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        current = None
    if current is not None and current != revision:
        raise BenchmarkError("harness revision is not the current checkout HEAD")


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

    if bundle.get("type") != "versioned-relative-path-manifest":
        raise BenchmarkError("unsupported input-bundle type")
    if bundle.get("revision") != identity.get("bundle_revision"):
        raise BenchmarkError("input bundle revision does not match the case registry")
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


def validate_capture_provenance(
    document: dict[str, object],
    record: Path,
    profile: dict[str, Any],
) -> None:
    """Check retained build, executable, and safe operational evidence."""
    capture = document.get("capture")
    if not isinstance(capture, dict):
        raise BenchmarkError("missing capture provenance")
    for key in ("captured_utc", "timeout_seconds", "build_argv", "run_argv"):
        if key not in capture:
            raise BenchmarkError(f"capture lacks {key}")
    if not isinstance(capture["captured_utc"], str):
        raise BenchmarkError("capture has malformed timestamp")
    try:
        datetime.fromisoformat(capture["captured_utc"])
    except ValueError as error:
        raise BenchmarkError("capture has malformed timestamp") from error
    if as_finite_nonnegative(capture["timeout_seconds"], "invalid timeout") <= 0.0:
        raise BenchmarkError("invalid timeout")
    command_values = (capture["build_argv"], capture["run_argv"])
    if not all(
        isinstance(value, list)
        and value
        and all(isinstance(argument, str) and argument for argument in value)
        for value in command_values
    ):
        raise BenchmarkError("capture lacks command provenance")

    build = capture.get("build")
    executable = capture.get("executable")
    environment = capture.get("environment")
    if not isinstance(build, dict) or not isinstance(executable, dict):
        raise BenchmarkError("capture lacks build or executable provenance")
    environment_fields = {"platform", "python", "processor", "host", "uname"}
    if not isinstance(environment, dict) or not environment_fields <= set(environment):
        raise BenchmarkError("capture lacks environment provenance")
    for field in ("config", "log"):
        path = build.get(f"{field}_path")
        digest = build.get(f"{field}_sha256")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise BenchmarkError("malformed build provenance")
        artifact = retained_path(record, path, "malformed build provenance")
        if not artifact.is_file() or sha256(artifact) != digest:
            raise BenchmarkError("retained build artifact hash mismatch")
    executable_digest = executable.get("sha256")
    if (
        not isinstance(executable_digest, str)
        or not re.fullmatch(r"[0-9a-f]{64}", executable_digest)
        or executable.get("copied") is not False
    ):
        raise BenchmarkError("malformed executable provenance")
    settings = read_config_values(record / build["config_path"])
    if "MATRIX_SOLVER" not in settings or "SOURCE_ROOT" not in settings:
        raise BenchmarkError("retained build config is incomplete")
    build_argv = capture["build_argv"]
    try:
        source_argument = build_argv[build_argv.index("-C") + 1]
    except (ValueError, IndexError) as error:
        raise BenchmarkError("build command lacks its source checkout") from error
    if settings["SOURCE_ROOT"] != source_argument:
        raise BenchmarkError("build command and config source roots disagree")
    dimensions = profile["dimensions"]
    if settings.get("MATRIX_SOLVER") != dimensions["solver"]:
        raise BenchmarkError("retained build config solver does not match profile")
    expected_switches = {
        "MPI_MODE": dimensions["mpi"],
        "OPENMP_MODE": dimensions["openmp"],
        "GPU_MODE": dimensions["gpu"],
    }
    for name, value in expected_switches.items():
        if settings.get(name) != value:
            raise BenchmarkError("retained build config does not match profile")
    for name in ("OPENACC_MODE", "OPENMP_OL_MODE"):
        if settings.get(name) != "OFF":
            raise BenchmarkError("retained build config does not match profile")

    operational = capture.get("operational")
    if not isinstance(operational, dict):
        raise BenchmarkError("capture lacks operational provenance")
    cpu_count = operational.get("cpu_count")
    affinity = operational.get("affinity")
    if not isinstance(cpu_count, int) or cpu_count < 1:
        raise BenchmarkError("capture lacks CPU-count provenance")
    if affinity != "unavailable" and not (
        isinstance(affinity, list)
        and affinity
        and all(isinstance(cpu, int) and cpu >= 0 for cpu in affinity)
    ):
        raise BenchmarkError("capture has malformed affinity provenance")

    compiler = operational.get("compiler")
    if not isinstance(compiler, dict):
        raise BenchmarkError("capture lacks compiler provenance")
    compiler_path = compiler.get("path")
    compiler_digest = compiler.get("sha256")
    if not isinstance(compiler_path, str) or not compiler_path.startswith("/"):
        raise BenchmarkError("capture lacks resolved compiler provenance")
    if not isinstance(compiler_digest, str) or not re.fullmatch(
        r"[0-9a-f]{64}",
        compiler_digest,
    ):
        raise BenchmarkError("capture has malformed compiler provenance")

    def validate_transcript(name: str, entry: object) -> None:
        if not isinstance(entry, dict):
            raise BenchmarkError(f"capture lacks {name} provenance")
        path = entry.get("path")
        digest = entry.get("sha256")
        argv = entry.get("argv")
        if not isinstance(digest, str):
            raise BenchmarkError(f"malformed {name} provenance")
        if not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise BenchmarkError(f"malformed {name} provenance")
        if not isinstance(argv, list) or not argv:
            raise BenchmarkError(f"malformed {name} provenance")
        artifact = retained_path(
            record,
            path,
            f"malformed {name} provenance",
        )
        if not artifact.is_file() or sha256(artifact) != digest:
            raise BenchmarkError(f"retained {name} evidence hash mismatch")

    validate_transcript("compiler version", compiler.get("version"))
    for name in ("runtime", "topology"):
        validate_transcript(name, operational.get(name))


def validate_comparison_binding(
    document: dict[str, object],
    identity: dict[str, Any],
    record: Path,
    entries: list[dict[str, str]],
) -> dict[str, Path]:
    """Verify that the captured comparator/reference are exact bundle copies."""
    comparison = document.get("comparison")
    if not isinstance(comparison, dict):
        raise BenchmarkError("missing captured comparison inputs")
    paths: dict[str, Path] = {}
    manifest_hashes = {entry["path"]: entry["sha256"] for entry in entries}
    for name in ("comparator", "reference"):
        entry = comparison.get(name)
        if not isinstance(entry, dict):
            raise BenchmarkError("malformed captured comparison input")
        if entry.get("source_path") != identity.get(name):
            raise BenchmarkError("captured comparison source path mismatch")
        path = entry.get("path")
        digest = entry.get("sha256")
        if not isinstance(digest, str):
            raise BenchmarkError("malformed captured comparison input")
        artifact = retained_path(
            record,
            path,
            "malformed captured comparison input",
        )
        if not artifact.is_file() or sha256(artifact) != digest:
            raise BenchmarkError("captured comparison input hash mismatch")
        if digest != manifest_hashes.get(entry["source_path"]):
            raise BenchmarkError("captured comparison does not match input manifest")
        paths[name] = artifact
    return paths


def compare_retained_diagnostic(
    diagnostic: Path,
    comparison_paths: dict[str, Path],
    factory_name: str,
) -> None:
    """Run the captured historical comparator without a live source checkout."""
    try:
        regression = load_regression(comparison_paths["comparator"])
        with tempfile.TemporaryDirectory(prefix="xnet-v9-comparison-") as temporary:
            locator = Path(temporary)
            case = getattr(regression, factory_name)(locator)
            case = replace(case, reference=comparison_paths["reference"])
            reference = regression.load_reference(case.reference)
            text = diagnostic.read_text(encoding="utf-8")
            states = regression.parse_diagnostic(
                text,
                case.expected_zones,
                case.expected_species,
                case.expected_diagnostic_groups,
            )
            regression.compare_final_states(states, reference)
            regression.compare_equivalent_zone_groups(
                states,
                case.equivalent_zone_groups,
            )
    except Exception as error:
        raise BenchmarkError(f"retained diagnostic comparison failed: {error}") from error


def validate_repetition(
    repetition: object,
    number: int,
    expected: dict[str, object],
    record: Path,
    comparison_paths: dict[str, Path],
    factory_name: str,
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
    parsed_timers, parsed_counters, parsed_sections = parse_diagnostic_metrics(
        artifact / "net_diag01"
    )
    if (
        parsed_timers != checked_timers
        or parsed_counters != counters
        or parsed_sections != checked_sections
    ):
        raise BenchmarkError("retained diagnostic disagrees with repetition summary")
    composition = artifact / "composition_error_norms.json"
    artifacts = repetition.get("artifacts")
    composition_entry = (
        artifacts.get("composition_error_norms") if isinstance(artifacts, dict) else None
    )
    if not isinstance(composition_entry, dict):
        raise BenchmarkError("missing composition diagnostics binding")
    if composition_entry.get("path") != composition.relative_to(record).as_posix():
        raise BenchmarkError("composition diagnostics path mismatch")
    if not composition.is_file() or sha256(composition) != composition_entry.get("sha256"):
        raise BenchmarkError("missing composition diagnostics")
    try:
        composition_value = json.loads(composition.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise BenchmarkError("malformed composition diagnostics") from error
    if not isinstance(composition_value, dict):
        raise BenchmarkError("malformed composition diagnostics")
    compare_retained_diagnostic(
        artifact / "net_diag01",
        comparison_paths,
        factory_name,
    )


def validate_inventory(record: Path) -> None:
    try:
        recorded = json.loads((record / "inventory.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise BenchmarkError("missing or malformed inventory.json") from error
    if not isinstance(recorded, list) or recorded != inventory(record):
        raise BenchmarkError("artifact inventory is incomplete or tampered")


def rehydrate(
    repository: Path | None,
    input_bundle: Path | None,
    executable: Path | None,
    entries: list[dict[str, str]],
    document: dict[str, object],
) -> None:
    if repository:
        try:
            revision = subprocess.check_output(
                ["git", "-C", str(repository), "rev-parse", "HEAD"], text=True
            ).strip()
        except (OSError, subprocess.CalledProcessError) as error:
            raise BenchmarkError("rehydration repository is not a Git checkout") from error
        if revision != HISTORICAL_SHA:
            raise BenchmarkError("rehydration repository is not the historical source")
    if input_bundle:
        bundle = document.get("input_bundle")
        revision = bundle.get("revision") if isinstance(bundle, dict) else None
        if isinstance(revision, str) and re.fullmatch(r"[0-9a-f]{40}", revision):
            try:
                actual = subprocess.check_output(
                    ["git", "-C", str(input_bundle), "rev-parse", "HEAD"],
                    text=True,
                ).strip()
            except (OSError, subprocess.CalledProcessError) as error:
                raise BenchmarkError(
                    "rehydration input bundle is not a Git checkout"
                ) from error
            if actual != revision:
                raise BenchmarkError("rehydration input bundle revision mismatch")
        for entry in entries:
            source = input_bundle.resolve() / entry["path"]
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
    parser.add_argument(
        "--input-bundle",
        type=Path,
        help="optional versioned input bundle for manifest rehydration",
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
    profile_name = document["execution"]["profile"]
    validate_capture_provenance(document, record, profiles[profile_name])
    comparison_paths = validate_comparison_binding(
        document,
        case.input_identity,
        record,
        entries,
    )

    capture = document.get("capture")
    repetitions = document.get("repetitions")
    requested = capture.get("repetitions_requested") if isinstance(capture, dict) else None
    if not isinstance(repetitions, list) or not isinstance(requested, int):
        raise BenchmarkError("missing repetition list")
    if requested < 1 or len(repetitions) != requested:
        raise BenchmarkError("missing or short repetition list")
    for number, repetition in enumerate(repetitions, start=1):
        validate_repetition(
            repetition,
            number,
            expected,
            record,
            comparison_paths,
            case.workload["regression_factory"],
        )

    validate_inventory(record)
    rehydrate(
        args.repository,
        args.input_bundle,
        args.executable,
        entries,
        document,
    )
    print(f"valid benchmark record: {record}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BenchmarkError as error:
        print(f"validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
