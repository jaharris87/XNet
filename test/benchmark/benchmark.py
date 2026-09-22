"""Shared standard-library support for immutable XNet V9 benchmark records."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
from typing import Any, Iterable

HISTORICAL_SHA = "86e867c2a64267a674ce4fbf6a3064af39e2f4e0"
RECORD_SCHEMA = "xnet-v9-benchmark-record-v3"
TIMER_NAMES = ("Total", "TimeStep", "NewtRaph", "Solver", "Decomp", "BkSub", "Jacobian", "Deriv", "CrossSect", "Screening", "PreScreen", "EOS", "Setup", "Output")


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


def read_cases(directory: Path) -> dict[str, BenchmarkCase]:
    document = json.loads((directory / "cases.json").read_text(encoding="utf-8"))
    if document.get("schema") != "xnet-v9-benchmark-cases-v1" or not isinstance(document.get("cases"), list):
        raise BenchmarkError("invalid cases.json schema")
    cases: dict[str, BenchmarkCase] = {}
    for item in document["cases"]:
        try:
            case = BenchmarkCase(item["case_id"], item["status"], item["network"], item["workload"], item.get("expected", {}), item.get("input_identity", {}))
        except (KeyError, TypeError) as error:
            raise BenchmarkError("invalid case registry entry") from error
        if not re.fullmatch(r"[a-z0-9_]+", case.case_id) or case.case_id in cases:
            raise BenchmarkError(f"invalid or duplicate case ID: {case.case_id!r}")
        cases[case.case_id] = case
    return cases


def require_clean_historical_repository(repository: Path) -> Path:
    repository = repository.resolve()
    def git(*args: str) -> str:
        return subprocess.check_output(["git", "-C", str(repository), *args], text=True).strip()
    try:
        revision = git("rev-parse", "HEAD")
        dirty = git("status", "--porcelain")
    except (OSError, subprocess.CalledProcessError) as error:
        raise BenchmarkError(f"not a readable Git checkout: {repository}") from error
    if revision != HISTORICAL_SHA or dirty:
        raise BenchmarkError(f"repository must be clean at historical SHA {HISTORICAL_SHA}")
    return repository


def tracked_files(repository: Path, relative: Path) -> list[Path]:
    output = subprocess.check_output(["git", "-C", str(repository), "ls-files", "--", relative.as_posix()], text=True)
    return [repository / item for item in output.splitlines() if item]


def load_regression(repository: Path):
    path = repository / "test/regression/xnet_regression.py"
    spec = importlib.util.spec_from_file_location("xnet_v9_historical_regression", path)
    if spec is None or spec.loader is None:
        raise BenchmarkError(f"could not load historical comparator: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def case_inputs(repository: Path, regression_case: Any) -> list[Path]:
    """Return all source files whose content defines the isolated comparison run."""
    files = [regression_case.control, regression_case.reference, regression_case.helm_table]
    files.extend(tracked_files(repository, regression_case.network_data.relative_to(repository)))
    files.extend(regression_case.trajectories)
    files.extend(item.source for item in regression_case.staged_inputs)
    files.append(repository / "test/regression/xnet_regression.py")
    unique = {path.resolve() for path in files}
    return sorted(unique, key=lambda path: path.relative_to(repository).as_posix())


def copy_input_bundle(repository: Path, record: Path, inputs: Iterable[Path]) -> list[dict[str, str]]:
    bundle = record / "input-bundle"
    entries = []
    for source in inputs:
        relative = source.resolve().relative_to(repository).as_posix()
        target = bundle / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        entries.append({"path": relative, "sha256": sha256(target)})
    return entries


def parse_diagnostic_metrics(path: Path) -> tuple[dict[str, float], dict[str, int]]:
    text = path.read_text(encoding="utf-8", errors="replace")
    timers: dict[str, float] = {}
    for line in text.splitlines():
        fields = line.split()
        if len(fields) >= 2 and fields[0] in TIMER_NAMES:
            try:
                timers[fields[0]] = float(fields[1])
            except ValueError:
                continue
    counters = {"end_records": len(re.findall(r"^End\s", text, re.MULTILINE)), "timer_sections": text.count("Timers Summary:")}
    for label in ("Number of timesteps", "Number of Newton iterations", "Number of Jacobian evaluations"):
        match = re.search(re.escape(label) + r"\\s*[:=]?\\s*(\\d+)", text)
        if match:
            counters[label.lower().replace(" ", "_")] = int(match.group(1))
    return timers, counters


def run_timed_and_compare(regression: Any, executable: Path, case: Any, work: Path, timeout_seconds: float) -> tuple[float, str | None]:
    """Time only the existing runner's subprocess helper, then characterize it."""
    reference = regression.load_reference(case.reference)
    regression.validate_reference_for_case(case, reference)
    prepared = regression.prepare_work_directory(case, work)
    started = time.monotonic()
    regression.run_xnet(executable, case, prepared, timeout_seconds=timeout_seconds)
    elapsed = time.monotonic() - started
    diagnostic = (prepared / "net_diag01").read_text(encoding="utf-8")
    missing = tuple(marker for marker in case.required_diagnostic_markers if marker not in diagnostic)
    if missing:
        raise regression.ParsingFailure("required diagnostic marker is missing: " + ", ".join(repr(marker) for marker in missing))
    states = regression.parse_diagnostic(diagnostic, case.expected_zones, case.expected_species, case.expected_diagnostic_groups)
    diagnostics = regression.calculate_composition_norms(states, reference)
    regression._write_composition_diagnostics(prepared, diagnostics, reference)
    regression.compare_final_states(states, reference)
    regression.compare_equivalent_zone_groups(states, case.equivalent_zone_groups)
    return elapsed, None


def inventory(record: Path) -> list[dict[str, object]]:
    ignored = {"inventory.json"}
    rows = []
    for path in sorted((item for item in record.rglob("*") if item.is_file() and item.name not in ignored), key=lambda item: item.relative_to(record).as_posix()):
        rows.append({"path": path.relative_to(record).as_posix(), "bytes": path.stat().st_size, "sha256": sha256(path)})
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
