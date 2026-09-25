#!/usr/bin/env python3
"""Build and capture one small, inspectable XNet benchmark record."""

from __future__ import annotations

import argparse
from dataclasses import asdict, replace
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import subprocess
import sys
import time
from types import ModuleType
from typing import Any, Iterable, Mapping, Sequence


ROOT = Path(__file__).resolve().parents[2]
BENCHMARK_DIR = Path(__file__).resolve().parent
NETWORK_FILES = ("sunet", "netsu", "netweak", "netwinv")
FULL_SHA = re.compile(r"[0-9a-f]{40}")
MAKE_ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=.*", re.DOTALL)
FLOAT = r"[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[EeDd][+-]?\d+)?"
TIMER_ROW = re.compile(rf"^\s*([A-Za-z][A-Za-z0-9_/-]*)\s+({FLOAT})\s*$")
RELEVANT_ENVIRONMENT = (
    "LOADEDMODULES",
    "OMP_NUM_THREADS",
    "OMP_PLACES",
    "OMP_PROC_BIND",
    "OMP_DISPLAY_ENV",
    "CUDA_VISIBLE_DEVICES",
    "ROCR_VISIBLE_DEVICES",
    "ROCM_VISIBLE_DEVICES",
    "SLURM_JOB_ID",
    "SLURM_STEP_ID",
    "SLURM_NODELIST",
    "SLURM_NTASKS",
    "SLURM_CPUS_PER_TASK",
    "SLURM_GPUS",
    "SLURM_GPUS_PER_NODE",
    "SLURM_GPUS_PER_TASK",
)


class BenchmarkError(RuntimeError):
    """A requested record cannot be captured credibly."""


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def git(repository: Path, *arguments: str) -> str:
    try:
        return subprocess.check_output(
            ["git", "-C", str(repository), *arguments],
            text=True,
            stderr=subprocess.STDOUT,
        ).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise BenchmarkError(f"Git inspection failed for {repository}: {error}") from error


def verify_source(repository: Path, revision: str) -> dict[str, str]:
    repository = repository.resolve()
    if not repository.is_dir() or FULL_SHA.fullmatch(revision) is None:
        raise BenchmarkError("--source and a full 40-character --source-revision are required")
    actual = git(repository, "rev-parse", "HEAD")
    if actual != revision:
        raise BenchmarkError(f"source revision is {actual}, expected {revision}")
    dirty = git(repository, "status", "--porcelain", "--untracked-files=no")
    if dirty:
        raise BenchmarkError("source checkout has tracked modifications")
    return {"repository": str(repository), "revision": actual}


def repository_identity(repository: Path, paths: Sequence[Path]) -> dict[str, object]:
    revision = git(repository, "rev-parse", "HEAD")
    relative = [str(path.resolve().relative_to(repository.resolve())) for path in paths]
    status = git(repository, "status", "--porcelain", "--untracked-files=no", "--", *relative)
    if status:
        raise BenchmarkError("benchmark input files have tracked modifications")
    return {"repository": str(repository.resolve()), "revision": revision}


def load_registry() -> dict[str, Any]:
    try:
        value = json.loads((BENCHMARK_DIR / "cases.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise BenchmarkError(f"could not read cases.json: {error}") from error
    if not isinstance(value.get("cases"), dict):
        raise BenchmarkError("cases.json lacks cases")
    return value


def load_regression_helper(root: Path) -> ModuleType:
    path = root / "test/regression/xnet_regression.py"
    if not path.is_file():
        raise BenchmarkError(f"missing regression helper: {path}")
    name = f"xnet_benchmark_regression_{hashlib.sha1(str(path).encode()).hexdigest()}"
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise BenchmarkError(f"could not load regression helper: {path}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


def read_species(path: Path) -> tuple[str, ...]:
    species = tuple(
        line.split()[0].lower()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    )
    if not species or len(species) != len(set(species)):
        raise BenchmarkError(f"invalid species list: {path}")
    return species


def abundance_text(species: Sequence[str]) -> str:
    if not {"c12", "o16"} <= set(species):
        raise BenchmarkError("controlled network lacks C12 or O16")
    values = [
        (name, 0.5 / 12.0 if name == "c12" else 0.5 / 16.0 if name == "o16" else 0.0)
        for name in species
    ]
    rows = ["controlled mass fractions expressed as molar abundances Y=X/A"]
    rows.extend(
        "".join(f"{name:>5s} {value:14.7E}" for name, value in values[start : start + 4])
        for start in range(0, len(values), 4)
    )
    return "\n".join(rows) + "\n"


def trajectory_text() -> str:
    return """fixed thermodynamic state for controlled-scaling benchmark
0.000000E+00    Start Time
1.000000E+01    Stop Time
1.000000E-12    Init Del t
0.000000E+00 1.700000E+00 1.000000E+08 5.000000E-01
1.000000E+01 1.700000E+00 1.000000E+08 5.000000E-01
"""


def control_text(case_name: str, network_name: str, species: Sequence[str], zones: int, batch: int, self_heating: bool) -> str:
    output_species = species[: min(14, len(species))]
    heading = f"{'# Species to output in ASCII output (format 14a5):':<50}{len(output_species):4d}"
    return f"""## Problem Description
controlled-scaling fixed C/O workload
10-second approved early-burn interval; not an equilibrium claim
generated by test/benchmark/run.py
## Job Controls
1         Initial Zone
{zones}         # of Zones
1         Include Weak Reactions (yes=1,no=0,only=-1)
1         Include Screening (yes=1)
1         Process Nuclear Data at Run Time (yes=1,no=0)
## Neutrinos
0         Include Neutrino Reactions (yes=1, no=0)
## NSE Initial Conditions
11.0      Temperature in GK to use NSE initial conditions instead of file
## Integration Controls
1         Choice of integration Scheme
9999      Max. number of timesteps before quit
5         Max. iterations per step
1         Rebuild the jacobian every ijac iterations after the first
0         Convergence Condition
1.00E-01  Max. Abundance Change per timestep
1.00E-07  Smallest Abundance used in timestep calculation
1.00E-06  Mass Conservation Limit
1.00E-04  Convergence Criterion
1.00E-30  Lower Abundance limit
2.00E+00  Max. Factor to change dt in a timestep
## Self-heating Controls
{1 if self_heating else 0}         Include self-heating (yes=1,no=0)
1.00E-02  Max. Temperature Change per timestep
1.00E-04  Temperature Convergence Criterion
## Zone Batching Controls
{batch}         Blocking size for zone loop

## Output Controls
0         Diagnostic Output Level
0         Per Timestep Output Level
# ASCII output filename root, network will append zone number
ev_{case_name}_
# Binary output filename root, network will append zone number
ts_{case_name}_
{heading}
{"".join(f"{name:>5s}" for name in output_species)}
## Input Controls
# Nuclear Data Directory
{network_name}
# Initial Abundance and Thermodynamic Trajectory Files
controlled_abundance_
controlled_trajectory_
"""


def symlink(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.symlink_to(source.resolve())


def controlled_inputs(
    root: Path,
    case_name: str,
    definition: Mapping[str, Any],
    zones: int,
    batch: int,
    self_heating: bool,
) -> dict[str, Any]:
    network = root / definition["network"]
    reference_key = "self_heating_reference" if self_heating else "reference"
    if reference_key not in definition:
        raise BenchmarkError(f"case {case_name} has no self-heating reference")
    reference = root / definition[reference_key]
    helm = root / "tools/starkiller-helmholtz/helm_table.dat"
    helper = root / "test/regression/xnet_regression.py"
    paths = [reference, helm, helper, *(network / name for name in NETWORK_FILES)]
    if any(not path.is_file() for path in paths):
        raise BenchmarkError(f"case {case_name} lacks a required input")
    for name, expected in definition["network_sha256"].items():
        actual = sha256(network / name)
        if actual != expected:
            raise BenchmarkError(f"{case_name} {name} hash differs from cases.json")
    species = read_species(network / "sunet")
    if len(species) != definition["species"]:
        raise BenchmarkError(f"{case_name} species count differs from cases.json")
    if zones < 1 or batch < 1 or batch > zones:
        raise BenchmarkError("controlled zones and batch size must be positive, with batch <= zones")
    retained = {
        "control": control_text(case_name, network.name, species, zones, batch, self_heating),
        "controlled_abundance": abundance_text(species),
        "controlled_trajectory": trajectory_text(),
    }
    manifest = [{"path": str(path.relative_to(root)), "sha256": sha256(path)} for path in paths]
    return {
        "kind": "controlled",
        "root": root,
        "case_name": case_name,
        "network": network,
        "reference": reference,
        "helm": helm,
        "helper": helper,
        "species": species,
        "zones": tuple(range(1, zones + 1)),
        "batch": batch,
        "self_heating": self_heating,
        "retained": retained,
        "manifest": manifest,
        "identity": repository_identity(root, paths),
    }


def regression_inputs(source: Path, definition: Mapping[str, Any]) -> dict[str, Any]:
    helper = load_regression_helper(source)
    factory = getattr(helper, definition["factory"], None)
    if factory is None:
        raise BenchmarkError(f"missing regression factory {definition['factory']}")
    case = factory(source)
    paths = [case.control, case.reference, case.helm_table, source / "test/regression/xnet_regression.py"]
    paths.extend(case.trajectories)
    paths.extend(case.network_data / name for name in case.network_inputs)
    paths.extend(item.source for item in case.staged_inputs)
    unique = sorted(set(path.resolve() for path in paths))
    if any(not path.is_file() for path in unique):
        raise BenchmarkError("historical regression case lacks a required input")
    return {
        "kind": "regression",
        "root": source,
        "case_name": case.name,
        "case": case,
        "helper_module": helper,
        "helper": source / "test/regression/xnet_regression.py",
        "species": tuple(case.expected_species),
        "zones": tuple(case.expected_zones),
        "reference": case.reference,
        "manifest": [{"path": str(path.relative_to(source)), "sha256": sha256(path)} for path in unique],
        "identity": {"repository": str(source), "revision": git(source, "rev-parse", "HEAD")},
    }


def retain_generated_inputs(output: Path, inputs: Mapping[str, Any]) -> None:
    if inputs["kind"] != "controlled":
        return
    directory = output / "inputs"
    directory.mkdir()
    for name, text in inputs["retained"].items():
        (directory / name).write_text(text, encoding="utf-8")


def stage_work(output: Path, inputs: Mapping[str, Any]) -> None:
    if inputs["kind"] == "regression":
        inputs["helper_module"].prepare_work_directory(inputs["case"], output)
        return
    output.mkdir()
    retained = output.parents[2] / "inputs"
    shutil.copy2(retained / "control", output / "control")
    network = inputs["network"]
    for name in NETWORK_FILES:
        symlink(network / name, output / network.name / name)
    symlink(inputs["helm"], output / inputs["helm"].name)
    width = len(str(len(inputs["zones"])))
    for zone in inputs["zones"]:
        symlink(retained / "controlled_abundance", output / f"controlled_abundance_{zone:0{width}d}")
        symlink(retained / "controlled_trajectory", output / f"controlled_trajectory_{zone:0{width}d}")


def parse_assignments(values: Sequence[str]) -> dict[str, str]:
    result: dict[str, str] = {}
    for value in values:
        if MAKE_ASSIGNMENT.fullmatch(value) is None:
            raise BenchmarkError("--make-option must be NAME=VALUE")
        name, setting = value.split("=", 1)
        if name in result or not setting or "\n" in setting:
            raise BenchmarkError("duplicate or empty --make-option")
        result[name] = setting
    return result


def build_xnet(source: Path, build_dir: Path, output: Path, options: Mapping[str, str], jobs: int) -> tuple[list[str], int]:
    if build_dir.exists():
        raise BenchmarkError("--build-dir must not already exist")
    command = ["make", "-C", str(source), f"BUILD_DIR={build_dir}", f"-j{jobs}"]
    command.extend(f"{name}={value}" for name, value in options.items())
    command.append("xnet")
    with (output / "build.log").open("w", encoding="utf-8") as log:
        completed = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, text=True, check=False)
    return command, completed.returncode


def config_values(path: Path) -> dict[str, str]:
    if not path.is_file():
        return {}
    return {
        key: value
        for line in path.read_text(encoding="utf-8").splitlines()
        if "=" in line
        for key, value in [line.split("=", 1)]
    }


def compiler_evidence(output: Path, config: Mapping[str, str]) -> dict[str, object]:
    compiler_argv = shlex.split(config.get("FC", config.get("F90", "gfortran")))
    if not compiler_argv:
        return {"argv": [], "status": "unavailable"}
    executable = shutil.which(compiler_argv[0])
    if executable is None:
        return {"argv": compiler_argv, "status": "unavailable"}
    command = [executable, *compiler_argv[1:], "--version"]
    completed = subprocess.run(command, capture_output=True, text=True, check=False)
    path = output / "compiler-version.txt"
    path.write_text(completed.stdout + completed.stderr, encoding="utf-8")
    return {"argv": command, "status": completed.returncode, "output": path.name}


def diagnostic_groups(text: str) -> tuple[tuple[int, ...], ...]:
    groups: list[tuple[int, ...]] = []
    current: list[int] = []
    for line in text.splitlines():
        if line.startswith("End"):
            fields = line.split()
            if len(fields) > 1 and fields[1].isdigit():
                current.append(int(fields[1]))
        elif line.startswith("Counters:"):
            if not current:
                raise BenchmarkError("diagnostic Counters section has no End records")
            groups.append(tuple(current))
            current = []
    if current or not groups:
        raise BenchmarkError("diagnostic group structure is incomplete")
    return tuple(groups)


def timer_sections(text: str) -> list[dict[str, float]]:
    sections: list[dict[str, float]] = []
    current: dict[str, float] | None = None
    for line in text.splitlines():
        if line.strip() == "Timers Summary:":
            if current:
                sections.append(current)
            current = {}
            continue
        if current is not None:
            match = TIMER_ROW.match(line)
            if match:
                current[match.group(1)] = float(match.group(2).replace("D", "E").replace("d", "e"))
            elif current:
                sections.append(current)
                current = None
    if current:
        sections.append(current)
    return sections


def expand_reference(reference: Any, zones: Sequence[int]) -> Any:
    if reference.expected_zones != (1,):
        raise BenchmarkError("controlled reference must contain one canonical zone")
    repeated = lambda value: {zone: value[1] for zone in zones}
    return replace(
        reference,
        expected_zones=tuple(zones),
        final_steps=repeated(reference.final_steps),
        fields=repeated(reference.fields),
        mass_fractions=repeated(reference.mass_fractions),
        mass_fraction_tolerances=repeated(reference.mass_fraction_tolerances),
        mass_fraction_sum_atols=repeated(reference.mass_fraction_sum_atols),
        mass_fraction_printed_sum_tolerances=(
            None if reference.mass_fraction_printed_sum_tolerances is None else repeated(reference.mass_fraction_printed_sum_tolerances)
        ),
        composition_norm_limits=(
            None if reference.composition_norm_limits is None else repeated(reference.composition_norm_limits)
        ),
        solver_counters=None if reference.solver_counters is None else repeated(reference.solver_counters),
    )


def compare_diagnostics(work: Path, inputs: Mapping[str, Any]) -> tuple[str, dict[str, Any], list[dict[str, Any]]]:
    paths = sorted(path for path in work.glob("net_diag*") if path.is_file() and path.stat().st_size)
    if not paths:
        raise BenchmarkError("XNet produced no nonempty net_diag output")
    helper = inputs.get("helper_module") or load_regression_helper(inputs["root"])
    states = []
    workers = []
    for path in paths:
        text = path.read_text(encoding="utf-8")
        groups = diagnostic_groups(text)
        zones = tuple(zone for group in groups for zone in group)
        parsed = helper.parse_diagnostic(text, zones, inputs["species"], groups)
        states.extend(parsed)
        sections = timer_sections(text)
        workers.append(
            {
                "path": path.name,
                "zone_count": len(zones),
                "first_zone": min(zones),
                "last_zone": max(zones),
                "timer_sections": len(sections),
                "final_timers_seconds": sections[-1] if sections else {},
            }
        )
    states.sort(key=lambda state: state.zone)
    actual_zones = tuple(state.zone for state in states)
    if actual_zones != tuple(inputs["zones"]):
        raise BenchmarkError(f"diagnostic zones {actual_zones} != expected {tuple(inputs['zones'])}")
    reference = helper.load_reference(inputs["reference"])
    if inputs["kind"] == "controlled":
        reference = expand_reference(reference, actual_zones)
    norms = helper.calculate_composition_norms(states, reference)
    max_l1 = max(norms, key=lambda item: item.l1)
    max_l2 = max(norms, key=lambda item: item.l2)
    max_linf = max(norms, key=lambda item: item.linf)
    counter_rows = [asdict(state.counters) for state in states]
    counter_summary = {
        name: {
            "minimum": min(row[name] for row in counter_rows),
            "maximum": max(row[name] for row in counter_rows),
            "sum": sum(row[name] for row in counter_rows),
        }
        for name in counter_rows[0]
    }
    diagnostics = {
        "zones": len(states),
        "composition_norms": {
            "maximum_l1": asdict(max_l1),
            "maximum_l2": asdict(max_l2),
            "maximum_linf": asdict(max_linf),
        },
        "counters": counter_summary,
    }
    try:
        helper.compare_final_states(states, reference)
        return "PASS", diagnostics, workers
    except helper.ComparisonFailure as error:
        lines = str(error).splitlines()
        diagnostics["failure"] = "\n".join(lines[:20])
        diagnostics["failure_lines_omitted"] = max(0, len(lines) - 20)
        return "FAIL", diagnostics, workers


def run_process(argv: Sequence[str], work: Path, environment: Mapping[str, str], timeout: float) -> tuple[subprocess.CompletedProcess[str], float]:
    started = time.perf_counter()
    completed = subprocess.run(
        list(argv),
        cwd=work,
        env=dict(environment),
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    return completed, time.perf_counter() - started


def capture_repetition(
    number: int,
    output: Path,
    argv: Sequence[str],
    environment: Mapping[str, str],
    timeout: float,
    inputs: Mapping[str, Any],
) -> dict[str, Any]:
    directory = output / "repetitions" / f"{number:02d}"
    work = directory / "work"
    directory.mkdir(parents=True)
    stage_work(work, inputs)
    try:
        completed, wall = run_process(argv, work, environment, timeout)
        status: int | str = completed.returncode
        stdout, stderr = completed.stdout, completed.stderr
    except subprocess.TimeoutExpired as error:
        wall = timeout
        status = "timeout"
        stdout = "" if error.stdout is None else str(error.stdout)
        stderr = "" if error.stderr is None else str(error.stderr)
    (directory / "stdout.txt").write_text(stdout, encoding="utf-8")
    (directory / "stderr.txt").write_text(stderr, encoding="utf-8")
    (directory / "status.txt").write_text(f"{status}\n", encoding="utf-8")
    for diagnostic in work.glob("net_diag*"):
        if diagnostic.is_file():
            shutil.copy2(diagnostic, directory / diagnostic.name)
    row: dict[str, Any] = {
        "number": number,
        "process_status": status,
        "wall_seconds": wall,
        "stdout": str((directory / "stdout.txt").relative_to(output)),
        "stderr": str((directory / "stderr.txt").relative_to(output)),
    }
    if status != 0:
        row.update({"execution": "FAIL", "numerical": "NOT-RUN", "diagnostic": f"XNet process status {status}"})
        return row
    try:
        numerical, diagnostics, workers = compare_diagnostics(work, inputs)
        row.update({"execution": "PASS", "numerical": numerical, "comparison": diagnostics, "workers": workers})
    except Exception as error:
        row.update({"execution": "FAIL", "numerical": "FAIL", "diagnostic": f"{type(error).__name__}: {error}"})
    return row


def relevant_environment(overrides: Mapping[str, str]) -> tuple[dict[str, str], dict[str, str]]:
    environment = dict(os.environ)
    environment.update(overrides)
    retained = {name: environment[name] for name in RELEVANT_ENVIRONMENT if name in environment}
    retained.update({"platform": platform.platform(), "host": platform.node()})
    try:
        retained["capture_affinity"] = ",".join(str(value) for value in sorted(os.sched_getaffinity(0)))
    except (AttributeError, OSError):
        retained["capture_affinity"] = "unavailable"
    return environment, retained


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--source-revision")
    parser.add_argument("--input-root", type=Path, default=ROOT)
    parser.add_argument("--case")
    parser.add_argument("--build-dir", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--make-option", action="append", default=[])
    parser.add_argument("--launcher", default="", help="launcher prefix parsed with shlex; no shell is used")
    parser.add_argument("--environment", action="append", default=[], metavar="NAME=VALUE")
    parser.add_argument("--ranks", type=int, default=1)
    parser.add_argument("--threads", type=int, default=1)
    parser.add_argument("--zones", type=int)
    parser.add_argument("--batch-size", type=int)
    parser.add_argument("--self-heating", action="store_true")
    parser.add_argument("--repetitions", type=int, default=5)
    parser.add_argument("--timeout-seconds", type=float, default=1800.0)
    parser.add_argument("--jobs", type=int, default=1)
    parser.add_argument("--qualification-note")
    parser.add_argument("--record-unavailable", metavar="REASON")
    parser.add_argument("--list-cases", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = arguments()
    registry = load_registry()
    if args.list_cases:
        for name, case in registry["cases"].items():
            print(f"{name}\t{case['kind']}\t{case.get('description', case.get('network', ''))}")
        return 0
    required = (args.source, args.source_revision, args.case, args.build_dir, args.output)
    if not all(required):
        raise BenchmarkError("--source, --source-revision, --case, --build-dir, and --output are required")
    if args.case not in registry["cases"]:
        raise BenchmarkError(f"unknown case: {args.case}")
    if args.repetitions < 1 or args.jobs < 1 or args.ranks < 1 or args.threads < 1:
        raise BenchmarkError("repetitions, jobs, ranks, and threads must be positive")
    if args.timeout_seconds <= 0 or not math.isfinite(args.timeout_seconds):
        raise BenchmarkError("timeout must be positive and finite")
    source = args.source.resolve()
    source_identity = verify_source(source, args.source_revision)
    if args.source_revision != registry["historical_source_revision"]:
        raise BenchmarkError("requested source is not the approved pre-v9 revision")
    output = args.output.resolve()
    build_dir = args.build_dir.resolve()
    if output.exists() or build_dir.exists():
        raise BenchmarkError("--output and --build-dir must both be fresh paths")
    definition = registry["cases"][args.case]
    input_root = args.input_root.resolve()
    if definition["kind"] == "controlled":
        zones = args.zones or registry["controlled_workload"]["normal_zones"]
        batch_size = args.batch_size or 1
        inputs = controlled_inputs(input_root, args.case, definition, zones, batch_size, args.self_heating)
    else:
        if args.zones is not None or args.batch_size is not None or args.self_heating:
            raise BenchmarkError("zones, batch size, and self-heating overrides apply only to controlled cases")
        inputs = regression_inputs(source, definition)
    options = parse_assignments(args.make_option)
    overrides = parse_assignments(args.environment)
    try:
        launcher = shlex.split(args.launcher)
    except ValueError as error:
        raise BenchmarkError(f"invalid --launcher: {error}") from error
    output.mkdir(parents=True)
    retain_generated_inputs(output, inputs)
    executable = build_dir / "bin/xnet"
    run_argv = [*launcher, str(executable)]
    planned_build = ["make", "-C", str(source), f"BUILD_DIR={build_dir}", f"-j{args.jobs}"]
    planned_build.extend(f"{name}={value}" for name, value in options.items())
    planned_build.append("xnet")
    record: dict[str, Any] = {
        "format": "xnet-pre-v9-benchmark-v1",
        "captured_utc": datetime.now(timezone.utc).isoformat(),
        "status": "INCOMPLETE",
        "case": args.case,
        "source": source_identity,
        "inputs": {
            "identity": inputs["identity"],
            "authoritative_network_revision": (
                registry["network_source_revision"] if definition["kind"] == "controlled" else None
            ),
            "files": inputs["manifest"],
        },
        "build": {"argv": planned_build, "selectors": options},
        "execution": {
            "argv": run_argv,
            "ranks": args.ranks,
            "threads": args.threads,
            "zones": len(inputs["zones"]),
            "batch_size": inputs.get("batch"),
            "self_heating": bool(inputs.get("self_heating", definition["kind"] == "regression" and args.case == "heat_sn160")),
        },
    }
    if definition["kind"] == "controlled":
        workload = dict(registry["controlled_workload"])
        workload["self_heating"] = args.self_heating
        record["workload"] = workload
    environment, retained_environment = relevant_environment(overrides)
    record["environment"] = retained_environment
    if args.record_unavailable:
        record.update({"status": "UNAVAILABLE", "reason": args.record_unavailable, "repetitions": []})
        write_json(output / "result.json", record)
        print(output)
        return 0
    build_argv, build_status = build_xnet(source, build_dir, output, options, args.jobs)
    record["build"].update({"argv": build_argv, "status": build_status, "log": "build.log"})
    if build_status != 0 or not executable.is_file():
        record.update({"status": "FAIL", "reason": "fresh XNet build failed or produced no executable", "repetitions": []})
        write_json(output / "result.json", record)
        print(output)
        return 1
    config = build_dir / "config.txt"
    if config.is_file():
        shutil.copy2(config, output / "build-config.txt")
    settings = config_values(config)
    record["build"].update(
        {
            "config": "build-config.txt" if config.is_file() else None,
            "resolved": settings,
            "compiler": compiler_evidence(output, settings),
            "executable_sha256": sha256(executable),
        }
    )
    ma48_dir = options.get("MA48_DIR")
    if ma48_dir and (Path(ma48_dir) / "MA48.f").is_file():
        record["build"]["ma48_source_sha256"] = sha256(Path(ma48_dir) / "MA48.f")
    repetitions = [
        capture_repetition(number, output, run_argv, environment, args.timeout_seconds, inputs)
        for number in range(1, args.repetitions + 1)
    ]
    record["repetitions"] = repetitions
    execution_passed = all(row["execution"] == "PASS" for row in repetitions)
    numerical_passed = execution_passed and all(row["numerical"] == "PASS" for row in repetitions)
    if numerical_passed:
        if args.qualification_note:
            raise BenchmarkError("--qualification-note is only valid for a completed comparison difference")
        record["status"] = "PASS"
    elif execution_passed and args.qualification_note:
        record.update({"status": "QUALIFIED / DIFFERENT-NUMERICAL-PATH", "qualification_note": args.qualification_note})
    else:
        record["status"] = "FAIL"
    write_json(output / "result.json", record)
    print(output)
    return 0 if record["status"] != "FAIL" else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BenchmarkError as error:
        print(f"benchmark error: {error}", file=sys.stderr)
        raise SystemExit(2)
