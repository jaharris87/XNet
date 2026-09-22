"""Shared standard-library support for immutable XNet benchmark records."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import time
from typing import Any, Iterable

RECORD_SCHEMA = "xnet-benchmark-record-v1"
CASE_REGISTRY_SCHEMA = "xnet-benchmark-cases-v1"
TIMER_NAMES = (
    "Total",
    "TimeStep",
    "NewtRaph",
    "Solver",
    "Decomp",
    "BkSub",
    "Jacobian",
    "Deriv",
    "CrossSect",
    "Screening",
    "PreScreen",
    "EOS",
    "Setup",
    "Output",
)


class BenchmarkError(RuntimeError):
    """A rejected benchmark request or record."""


@dataclass(frozen=True)
class BenchmarkCase:
    case_id: str
    status: str
    network: dict[str, Any]
    workload: dict[str, Any]
    expected: dict[str, Any]
    input_identity: dict[str, Any]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_registry(
    directory: Path,
) -> tuple[dict[str, BenchmarkCase], dict[str, dict[str, Any]]]:
    document = json.loads((directory / "cases.json").read_text(encoding="utf-8"))
    if (
        document.get("schema") != CASE_REGISTRY_SCHEMA
        or not isinstance(document.get("cases"), list)
    ):
        raise BenchmarkError("invalid cases.json schema")
    cases: dict[str, BenchmarkCase] = {}
    for item in document["cases"]:
        try:
            case = BenchmarkCase(
                item["case_id"],
                item["status"],
                item["network"],
                item["workload"],
                item.get("expected", {}),
                item.get("input_identity", {}),
            )
        except (KeyError, TypeError) as error:
            raise BenchmarkError("invalid case registry entry") from error
        if not re.fullmatch(r"[a-z0-9_]+", case.case_id) or case.case_id in cases:
            raise BenchmarkError(f"invalid or duplicate case ID: {case.case_id!r}")
        cases[case.case_id] = case
    profiles = document.get("execution_profiles", {})
    if not isinstance(profiles, dict) or "serial-dense" not in profiles:
        raise BenchmarkError("case registry lacks serial-dense execution profile")
    return cases, profiles


def read_cases(directory: Path) -> dict[str, BenchmarkCase]:
    return read_registry(directory)[0]


def require_clean_repository(repository: Path, source_revision: str) -> Path:
    """Require a clean checkout at the explicitly requested source revision."""
    repository = repository.resolve()

    if not re.fullmatch(r"[0-9a-f]{40}", source_revision):
        raise BenchmarkError("--source-revision must be a full lowercase Git SHA")

    def git(*args: str) -> str:
        return subprocess.check_output(
            ["git", "-C", str(repository), *args],
            text=True,
        ).strip()
    try:
        revision = git("rev-parse", "HEAD")
        dirty = git("status", "--porcelain")
    except (OSError, subprocess.CalledProcessError) as error:
        raise BenchmarkError(f"not a readable Git checkout: {repository}") from error
    if revision != source_revision:
        raise BenchmarkError("repository HEAD does not match --source-revision")
    if dirty:
        raise BenchmarkError("source repository must be clean")
    return repository


def tracked_files(repository: Path, relative: Path) -> list[Path]:
    output = subprocess.check_output(
        ["git", "-C", str(repository), "ls-files", "--", relative.as_posix()],
        text=True,
    )
    return [repository / item for item in output.splitlines() if item]


def load_regression(path: Path):
    """Load the comparator from the declared benchmark-input bundle."""
    spec = importlib.util.spec_from_file_location("xnet_benchmark_comparator", path)
    if spec is None or spec.loader is None:
        raise BenchmarkError(f"could not load benchmark comparator: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    previous = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        spec.loader.exec_module(module)
    finally:
        sys.dont_write_bytecode = previous
    return module


def case_inputs(bundle_root: Path, regression_case: Any, comparator: Path) -> list[Path]:
    """Return all source files whose content defines the isolated comparison run."""
    files = [
        regression_case.control,
        regression_case.reference,
        regression_case.helm_table,
    ]
    files.extend(
        regression_case.network_data / name
        for name in regression_case.network_inputs
    )
    files.extend(regression_case.trajectories)
    files.extend(item.source for item in regression_case.staged_inputs)
    files.append(comparator)
    unique = {path.resolve() for path in files}
    return sorted(unique, key=lambda path: path.relative_to(bundle_root).as_posix())


def input_manifest(repository: Path, inputs: Iterable[Path]) -> list[dict[str, str]]:
    entries = []
    for source in inputs:
        relative = source.resolve().relative_to(repository).as_posix()
        entries.append({"path": relative, "sha256": sha256(source)})
    return entries


def manifest_digest(entries: Iterable[dict[str, str]]) -> str:
    canonical = json.dumps(
        sorted(entries, key=lambda item: item["path"]),
        separators=(",", ":"),
        sort_keys=True,
    )
    return hashlib.sha256(canonical.encode()).hexdigest()


def parse_diagnostic_metrics(
    path: Path,
) -> tuple[dict[str, float], dict[str, Any], list[dict[str, float]]]:
    text = path.read_text(encoding="utf-8", errors="replace")
    timers: dict[str, float] = {}
    sections: list[dict[str, float]] = []
    section: dict[str, float] | None = None
    for line in text.splitlines():
        if line.startswith("Timers Summary:"):
            section = {}
            sections.append(section)
            continue
        fields = line.split()
        if len(fields) >= 2 and fields[0] in TIMER_NAMES:
            try:
                timers[fields[0]] = float(fields[1])
                if section is not None:
                    section[fields[0]] = float(fields[1])
            except ValueError:
                continue
    counters: dict[str, Any] = {
        "end_records": len(re.findall(r"^End\s", text, re.MULTILINE)),
        "timer_sections": len(sections),
    }
    rows = []
    reading_counters = False
    counter_pattern = re.compile(
        r"^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$"
    )
    for line in text.splitlines():
        if line.startswith("Counters:"):
            reading_counters = True
            continue
        if line.startswith("Timers Summary:"):
            reading_counters = False
            continue
        if reading_counters and (match := counter_pattern.fullmatch(line)):
            rows.append(match.groups())
    if rows:
        counters["zones"] = {
            zone: {
                "TS": int(ts),
                "NR": int(nr),
                "Jacobian": int(jac),
                "Deriv": int(deriv),
                "CrossSect": int(cross),
            }
            for zone, ts, nr, jac, deriv, cross in rows
        }
    return timers, counters, sections


def run_timed_and_compare(
    regression: Any,
    executable: Path,
    case: Any,
    work: Path,
    timeout_seconds: float,
) -> tuple[float, tuple[Any, ...]]:
    """Time only the existing runner's subprocess helper, then characterize it."""
    reference = regression.load_reference(case.reference)
    regression.validate_reference_for_case(case, reference)
    prepared = regression.prepare_work_directory(case, work)
    started = time.monotonic()
    regression.run_xnet(executable, case, prepared, timeout_seconds=timeout_seconds)
    elapsed = time.monotonic() - started
    diagnostic = (prepared / "net_diag01").read_text(encoding="utf-8")
    missing = tuple(
        marker
        for marker in case.required_diagnostic_markers
        if marker not in diagnostic
    )
    if missing:
        markers = ", ".join(repr(marker) for marker in missing)
        raise regression.ParsingFailure(
            f"required diagnostic marker is missing: {markers}"
        )
    states = regression.parse_diagnostic(
        diagnostic,
        case.expected_zones,
        case.expected_species,
        case.expected_diagnostic_groups,
    )
    diagnostics = regression.calculate_composition_norms(states, reference)
    regression._write_composition_diagnostics(prepared, diagnostics, reference)
    regression.compare_final_states(states, reference)
    regression.compare_equivalent_zone_groups(states, case.equivalent_zone_groups)
    return elapsed, tuple(states)


def inventory(record: Path) -> list[dict[str, object]]:
    inventory_path = record / "inventory.json"
    rows = []
    paths = (
        item
        for item in record.rglob("*")
        if item.is_file() and item != inventory_path
    )
    for path in sorted(paths, key=lambda item: item.relative_to(record).as_posix()):
        rows.append(
            {
                "path": path.relative_to(record).as_posix(),
                "bytes": path.stat().st_size,
                "sha256": sha256(path),
            }
        )
    return rows


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def read_record(record: Path) -> dict[str, Any]:
    try:
        document = json.loads((record / "record.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise BenchmarkError("missing or malformed record.json") from error
    if not isinstance(document, dict) or document.get("schema") != RECORD_SCHEMA:
        raise BenchmarkError("unsupported benchmark record schema")
    return document
