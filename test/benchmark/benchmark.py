"""Shared standard-library support for immutable XNet benchmark records."""

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
    specifications = document.get("workload_specifications", {})
    if not isinstance(specifications, dict):
        raise BenchmarkError("invalid workload specifications")
    for item in document["cases"]:
        try:
            workload = dict(item["workload"])
            specification_id = workload.get("specification")
            if specification_id is not None:
                if specification_id not in specifications:
                    raise BenchmarkError("unknown workload specification")
                workload["specification_definition"] = specifications[specification_id]
            case = BenchmarkCase(
                item["case_id"],
                item["status"],
                item["network"],
                workload,
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


def declared_compatibility_overlays(
    paths: Iterable[Path], digests: Iterable[str]
) -> list[tuple[Path, str]]:
    """Validate the ordered compatibility patches declared by the caller."""
    path_list = [path.resolve() for path in paths]
    digest_list = list(digests)
    if len(path_list) != len(digest_list):
        raise BenchmarkError(
            "each --compatibility-overlay requires one ordered "
            "--compatibility-overlay-sha256"
        )
    declarations: list[tuple[Path, str]] = []
    for path, digest in zip(path_list, digest_list, strict=True):
        if not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise BenchmarkError("compatibility overlay SHA-256 is malformed")
        if not path.is_file():
            raise BenchmarkError("compatibility overlay is not a readable file")
        if sha256(path) != digest:
            raise BenchmarkError("compatibility overlay SHA-256 mismatch")
        declarations.append((path, digest))
    return declarations


def apply_compatibility_overlays(
    repository: Path,
    source_revision: str,
    destination: Path,
    overlays: Iterable[Path],
) -> tuple[str, str, list[str]]:
    """Create a private checkout and apply an ordered patch set to its index."""
    if destination.exists():
        raise BenchmarkError("capture owns a fresh compatibility source directory")
    try:
        subprocess.run(
            [
                "git",
                "clone",
                "--quiet",
                "--no-hardlinks",
                "--no-checkout",
                str(repository),
                str(destination),
            ],
            check=True,
        )
        subprocess.run(
            [
                "git",
                "-C",
                str(destination),
                "checkout",
                "--quiet",
                "--detach",
                source_revision,
            ],
            check=True,
        )
        base_tree = subprocess.check_output(
            ["git", "-C", str(destination), "rev-parse", "HEAD^{tree}"],
            text=True,
        ).strip()
        for overlay in overlays:
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(destination),
                    "apply",
                    "--check",
                    "--index",
                    str(overlay),
                ],
                check=True,
            )
            subprocess.run(
                ["git", "-C", str(destination), "apply", "--index", str(overlay)],
                check=True,
            )
        changed_paths = subprocess.check_output(
            ["git", "-C", str(destination), "diff", "--cached", "--name-only"],
            text=True,
        ).splitlines()
        result_tree = subprocess.check_output(
            ["git", "-C", str(destination), "write-tree"],
            text=True,
        ).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        if destination.exists():
            shutil.rmtree(destination)
        raise BenchmarkError("could not apply declared compatibility overlays") from error
    if not changed_paths or result_tree == base_tree:
        shutil.rmtree(destination)
        raise BenchmarkError("compatibility overlays do not change the source tree")
    return base_tree, result_tree, changed_paths


def verify_compatibility_checkout(
    repository: Path,
    source_revision: str,
    result_tree: str,
    changed_paths: Iterable[str],
) -> None:
    """Reject source changes beyond the staged, declared overlay result."""
    try:
        revision = subprocess.check_output(
            ["git", "-C", str(repository), "rev-parse", "HEAD"], text=True
        ).strip()
        actual_tree = subprocess.check_output(
            ["git", "-C", str(repository), "write-tree"], text=True
        ).strip()
        actual_paths = subprocess.check_output(
            ["git", "-C", str(repository), "diff", "--cached", "--name-only"],
            text=True,
        ).splitlines()
        unstaged = subprocess.run(
            ["git", "-C", str(repository), "diff", "--quiet"],
        ).returncode
        untracked = subprocess.check_output(
            [
                "git",
                "-C",
                str(repository),
                "ls-files",
                "--others",
                "--exclude-standard",
            ],
            text=True,
        ).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise BenchmarkError("compatibility source checkout is unreadable") from error
    if (
        revision != source_revision
        or actual_tree != result_tree
        or actual_paths != list(changed_paths)
        or unstaged != 0
        or untracked
    ):
        raise BenchmarkError("compatibility source changed beyond declared overlays")


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
    root = repository.resolve()
    entries = []
    for source in inputs:
        relative = source.resolve().relative_to(root).as_posix()
        entries.append({"path": relative, "sha256": sha256(source)})
    return entries


def manifest_digest(entries: Iterable[dict[str, str]]) -> str:
    canonical = json.dumps(
        sorted(entries, key=lambda item: item["path"]),
        separators=(",", ":"),
        sort_keys=True,
    )
    return hashlib.sha256(canonical.encode()).hexdigest()


def verify_input_manifest(
    bundle_root: Path,
    entries: Iterable[dict[str, str]],
) -> None:
    """Require every declared input to retain its pre-run content identity."""
    root = bundle_root.resolve()
    for entry in entries:
        relative = Path(entry["path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise BenchmarkError("input manifest contains an unsafe path")
        source = root / relative
        if not source.is_file() or sha256(source) != entry["sha256"]:
            raise BenchmarkError(
                f"input changed after manifest capture: {entry['path']}"
            )


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


def diagnostic_groups(path: Path) -> tuple[tuple[int, ...], ...]:
    """Discover the End/counter group structure emitted by one XNet worker."""
    groups: list[tuple[int, ...]] = []
    current: list[int] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("End"):
            fields = line.split()
            if len(fields) < 2 or not fields[1].isdigit():
                raise BenchmarkError(f"malformed End record in {path.name}")
            current.append(int(fields[1]))
        elif line.startswith("Counters:"):
            if not current:
                raise BenchmarkError(f"counter section without End records in {path.name}")
            groups.append(tuple(current))
            current = []
    if current or not groups:
        raise BenchmarkError(f"incomplete or empty diagnostic groups in {path.name}")
    return tuple(groups)


def worker_topology(paths: Iterable[Path]) -> dict[str, list[dict[str, int]]]:
    """Read XNet's own rank and OpenMP-team records from worker diagnostics."""
    ranks: set[tuple[int, int]] = set()
    threads: set[tuple[int, int, int]] = set()
    for path in paths:
        rank: int | None = None
        size: int | None = None
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            fields = line.split()
            if fields and fields[0] == "MyId" and len(fields) == 3:
                rank, size = int(fields[1]), int(fields[2])
                ranks.add((rank, size))
            elif fields and fields[0] == "Thread" and len(fields) == 4 and fields[2] == "of":
                if rank is None:
                    raise BenchmarkError(f"thread record precedes rank record in {path.name}")
                threads.add((rank, int(fields[1]), int(fields[3])))
    return {
        "ranks": [
            {"rank": rank, "size": size} for rank, size in sorted(ranks)
        ],
        "threads": [
            {"rank": rank, "thread": thread, "team": team}
            for rank, thread, team in sorted(threads)
        ],
    }


def parse_execution_probe(path: Path) -> list[dict[str, Any]]:
    """Reparse rank/host/affinity observations from a retained probe transcript."""
    observations = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("XNET_EXECUTION_PROBE "):
            try:
                value = json.loads(line.removeprefix("XNET_EXECUTION_PROBE "))
            except json.JSONDecodeError as error:
                raise BenchmarkError("malformed launcher probe output") from error
            if not isinstance(value, dict):
                raise BenchmarkError("malformed launcher probe output")
            observations.append(value)
    return observations


def parse_openmp_probe(path: Path) -> list[dict[str, Any]]:
    """Reparse OpenMP team/place observations from a retained transcript."""
    observations = []
    for line in path.read_text(encoding="utf-8").splitlines():
        fields = line.split()
        labels = fields[1::2] if len(fields) == 13 else []
        if fields[:1] == ["XNET_BENCHMARK_OPENMP"] and labels != [
            "rank",
            "thread",
            "team",
            "place",
            "binding",
            "cpus",
        ]:
            raise BenchmarkError("malformed OpenMP probe output")
        if len(fields) == 13 and labels == [
            "rank",
            "thread",
            "team",
            "place",
            "binding",
            "cpus",
        ]:
            try:
                cpus = [int(cpu) for cpu in fields[12].split(",")]
                if not cpus:
                    raise ValueError
                observations.append(
                    {
                        "rank": fields[2],
                        "thread": int(fields[4]),
                        "team": int(fields[6]),
                        "place": int(fields[8]),
                        "binding": int(fields[10]),
                        "affinity": cpus,
                    }
                )
            except ValueError as error:
                raise BenchmarkError("malformed OpenMP probe output") from error
    return observations


def parse_device_probe(path: Path) -> list[dict[str, Any]]:
    """Reparse device/offload observations from a retained probe transcript."""
    observations = []
    for line in path.read_text(encoding="utf-8").splitlines():
        fields = line.split()
        labels = fields[1::2] if len(fields) == 15 else []
        if fields[:1] == ["XNET_BENCHMARK_DEVICE"] and labels != [
            "rank",
            "device",
            "count",
            "offloaded",
            "data_present",
            "info",
            "residual",
        ]:
            raise BenchmarkError("malformed device probe output")
        if len(fields) == 15 and labels == [
            "rank",
            "device",
            "count",
            "offloaded",
            "data_present",
            "info",
            "residual",
        ]:
            try:
                observations.append(
                    {
                        "rank": fields[2],
                        "device": int(fields[4]),
                        "device_count": int(fields[6]),
                        "offloaded": fields[8].upper() == "T",
                        "data_present": fields[10].upper() == "T",
                        "info": int(fields[12]),
                        "residual": float(fields[14]),
                    }
                )
            except ValueError as error:
                raise BenchmarkError("malformed device probe output") from error
    return observations


def parse_slurm_job(path: Path) -> dict[str, str]:
    """Parse the key/value form produced by ``scontrol show job --oneliner``."""
    text = path.read_text(encoding="utf-8", errors="replace")
    fields = dict(
        re.findall(r"(?:^|\s)([A-Za-z][A-Za-z0-9/]*)=(\S+)", text)
    )
    if not fields.get("JobId"):
        raise BenchmarkError("malformed Slurm allocation output")
    return fields


def parse_worker_states(regression: Any, case: Any, paths: Iterable[Path]) -> tuple[Any, ...]:
    """Parse all worker diagnostics and return one ordered state per global zone."""
    by_zone: dict[int, Any] = {}
    for path in paths:
        groups = diagnostic_groups(path)
        zones = tuple(zone for group in groups for zone in group)
        states = regression.parse_diagnostic(
            path.read_text(encoding="utf-8"),
            zones,
            case.expected_species,
            groups,
        )
        for state in states:
            if state.zone in by_zone:
                raise BenchmarkError(f"duplicate final state for zone {state.zone}")
            by_zone[state.zone] = state
    expected = tuple(case.expected_zones)
    if set(by_zone) != set(expected):
        raise BenchmarkError(
            f"worker diagnostic zone coverage mismatch: expected {expected}, "
            f"found {tuple(sorted(by_zone))}"
        )
    return tuple(by_zone[zone] for zone in expected)


def run_timed_and_compare(
    regression: Any,
    executable: Path,
    run_argv: list[str],
    case: Any,
    work: Path,
    timeout_seconds: float,
    reference_transform: Any | None = None,
    prepare_callback: Any | None = None,
) -> tuple[float, tuple[Any, ...]]:
    """Time only the existing runner's subprocess helper, then characterize it."""
    reference = regression.load_reference(case.reference)
    if reference_transform is not None:
        reference = reference_transform(regression, reference, case)
    regression.validate_reference_for_case(case, reference)
    prepared = (
        regression.prepare_work_directory(case, work)
        if prepare_callback is None
        else prepare_callback(case, work)
    )
    started = time.monotonic()
    # The regression helper is intentionally direct-executable only.  Keep its
    # comparison preparation, but allow this capture harness to time the exact
    # launcher argv retained in the record.
    if run_argv == [str(executable)] and prepare_callback is None:
        regression.run_xnet(executable, case, prepared, timeout_seconds=timeout_seconds)
    else:
        try:
            completed = subprocess.run(
                run_argv, cwd=prepared, capture_output=True, text=True,
                timeout=timeout_seconds, check=False,
            )
        except subprocess.TimeoutExpired as error:
            regression._write_process_artifacts(
                prepared, error.stdout or "", error.stderr or "", "timeout"
            )
            raise BenchmarkError("launched XNet timed out") from error
        except OSError as error:
            regression._write_process_artifacts(prepared, "", str(error), "launch-error")
            raise BenchmarkError(f"could not launch XNet: {error}") from error
        regression._write_process_artifacts(
            prepared, completed.stdout, completed.stderr,
            f"return_code={completed.returncode}",
        )
        if completed.returncode != 0:
            raise BenchmarkError(f"launched XNet returned {completed.returncode}")
        missing_outputs = [
            name for name in case.required_outputs
            if not (prepared / name).is_file() or (prepared / name).stat().st_size == 0
        ]
        if missing_outputs:
            raise BenchmarkError(f"launched XNet did not produce: {', '.join(missing_outputs)}")
    elapsed = time.monotonic() - started
    diagnostic_paths = sorted(prepared.glob("net_diag*"))
    if not diagnostic_paths:
        raise BenchmarkError("launched XNet produced no worker diagnostics")
    diagnostic = "\n".join(
        path.read_text(encoding="utf-8") for path in diagnostic_paths
    )
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
    states = parse_worker_states(regression, case, diagnostic_paths)
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
