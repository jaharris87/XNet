#!/usr/bin/env python3
"""Characterize fixed-state controlled workloads and long-time evolution.

This utility is deliberately separate from timed benchmark capture. It runs
one-zone, weak-off, self-heating-off integrations against the authoritative
network bundle and retains every generated input and raw XNet artifact. Its
JSON report exposes convergence histories at several candidate tolerances;
it does not declare a scientific endpoint.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import shutil
import subprocess
import sys
from typing import Any

from benchmark import (
    BenchmarkError,
    inventory,
    load_regression,
    require_clean_repository,
    sha256,
    write_json,
)


NETWORKS = {
    "alpha": "Data_alpha",
    "CCSN52": "Data_CCSN52",
    "SN160": "Data_SN160",
    "CCSN179": "Data_CCSN179",
    "ECSN350": "Data_ECSN350",
}
PRIMARY_COMPOSITION = {"c12": 0.5, "o16": 0.5}
SECONDARY_COMPOSITION = {"o16": 0.6, "ne20": 0.3, "mg24": 0.1}
DEFAULT_END_TIMES = (
    1.0e-6,
    1.0e-5,
    1.0e-4,
    1.0e-3,
    1.0e-2,
    1.0e-1,
    1.0,
    10.0,
)
DIAGNOSTIC_THRESHOLDS = (1.0e-5, 1.0e-6, 1.0e-7)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, required=True)
    parser.add_argument("--source-repository", type=Path, required=True)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--build-dir", type=Path, required=True)
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--workload",
        choices=("primary-co", "secondary-one-mg"),
        default="primary-co",
    )
    parser.add_argument(
        "--network",
        action="append",
        choices=tuple(NETWORKS),
        help="network to run; repeat as needed (defaults depend on workload)",
    )
    parser.add_argument(
        "--temperature-gk",
        action="append",
        type=float,
        help="temperature to run; repeat as needed (defaults depend on workload)",
    )
    parser.add_argument(
        "--end-time",
        action="append",
        type=float,
        help="candidate end time in seconds; repeat as needed",
    )
    parser.add_argument("--timeout-seconds", type=float, default=600.0)
    parser.add_argument(
        "--screening",
        choices=("on", "off"),
        default="on",
        help="strong-reaction screening policy to characterize (default: on)",
    )
    parser.add_argument(
        "--integrator",
        choices=("bdf", "backward-euler"),
        default="bdf",
        help="integration method used for the characterization (default: bdf)",
    )
    parser.add_argument(
        "--solver-tolerance",
        type=float,
        default=1.0e-4,
        help="XNet iterative/BDF relative tolerance (default: maintained 1e-4)",
    )
    parser.add_argument(
        "--absolute-abundance-tolerance",
        type=float,
        default=1.0e-7,
        help="XNet yacc and BDF abundance absolute tolerance (default: maintained 1e-7)",
    )
    return parser.parse_args()


def read_species(path: Path) -> tuple[str, ...]:
    species = tuple(
        line.strip().lower()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    )
    if not species or len(set(species)) != len(species):
        raise BenchmarkError(f"invalid species list: {path}")
    return species


def read_build_config(path: Path) -> dict[str, str]:
    settings: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" in line:
            name, value = line.split("=", 1)
            settings[name.strip()] = value.strip()
    return settings


def build_characterization_executable(
    source_repository: Path,
    build_directory: Path,
    build_log: Path,
) -> tuple[Path, Path, list[str], dict[str, str]]:
    """Own a fresh serial-dense build and bind it to the clean source tree."""
    if build_directory.exists():
        raise BenchmarkError("characterization owns a fresh, nonexistent --build-dir")
    command = [
        "make",
        "-C",
        str(source_repository),
        f"BUILD_DIR={build_directory}",
        "MPI_MODE=OFF",
        "OPENMP_MODE=OFF",
        "GPU_MODE=OFF",
        "OPENACC_MODE=OFF",
        "OPENMP_OL_MODE=OFF",
        "MATRIX_SOLVER=dense",
        "xnet",
    ]
    with build_log.open("w", encoding="utf-8") as log:
        completed = subprocess.run(
            command,
            stdout=log,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
    if completed.returncode:
        raise BenchmarkError(f"characterization build failed; see {build_log}")

    executable = build_directory / "bin/xnet"
    config = build_directory / "config.txt"
    if not executable.is_file() or not config.is_file():
        raise BenchmarkError("characterization build lacks executable or config.txt")
    settings = read_build_config(config)
    expected = {
        "SOURCE_ROOT": str(source_repository),
        "MPI_MODE": "OFF",
        "OPENMP_MODE": "OFF",
        "GPU_MODE": "OFF",
        "OPENACC_MODE": "OFF",
        "OPENMP_OL_MODE": "OFF",
        "MATRIX_SOLVER": "dense",
    }
    if any(settings.get(name) != value for name, value in expected.items()):
        raise BenchmarkError("characterization build config does not match request")
    return executable, config, command, settings


def require_bundle(repository: Path) -> tuple[str, list[dict[str, str]]]:
    manifest_path = Path(__file__).with_name("network-bundle-a9585568.json")
    document = json.loads(manifest_path.read_text(encoding="utf-8"))
    revision = document.get("source_revision")
    entries = document.get("files")
    if not isinstance(revision, str) or not isinstance(entries, list):
        raise BenchmarkError("invalid authoritative network-bundle manifest")
    for entry in entries:
        path = repository / entry["path"]
        if not path.is_file() or sha256(path) != entry["sha256"]:
            raise BenchmarkError(f"authoritative network file mismatch: {entry['path']}")
        try:
            committed = subprocess.check_output(
                ["git", "-C", str(repository), "show", f"{revision}:{entry['path']}"]
            )
        except subprocess.CalledProcessError as error:
            raise BenchmarkError(
                f"network file is unavailable at authoritative revision: {entry['path']}"
            ) from error
        if hashlib.sha256(committed).hexdigest() != entry["sha256"]:
            raise BenchmarkError(
                f"network manifest does not match authoritative revision: {entry['path']}"
            )
    return revision, entries


def abundance_text(species: tuple[str, ...], mass_fractions: dict[str, float]) -> str:
    missing = sorted(set(mass_fractions) - set(species))
    if missing:
        raise BenchmarkError(f"network lacks controlled species: {', '.join(missing)}")
    values = []
    for name in species:
        digits = "".join(character for character in name if character.isdigit())
        if name in {"n", "p"}:
            mass_number = 1
        elif name == "d":
            mass_number = 2
        elif name == "t":
            mass_number = 3
        elif digits:
            mass_number = int(digits)
        else:
            raise BenchmarkError(f"cannot determine mass number for {name}")
        values.append((name, mass_fractions.get(name, 0.0) / mass_number))
    rows = ["controlled mass fractions expressed as molar abundances Y=X/A"]
    for start in range(0, len(values), 4):
        rows.append(
            "".join(f"{name:>5s} {value:14.7E}" for name, value in values[start : start + 4])
        )
    return "\n".join(rows) + "\n"


def trajectory_text(end_time: float, temperature: float) -> str:
    return (
        "fixed thermodynamic state for controlled-workload characterization\n"
        "0.000000E+00    Start Time\n"
        f"{end_time:.12E}    Stop Time\n"
        "1.000000E-12    Init Del t\n"
        f"0.000000E+00 {temperature:.12E} 1.000000E+08 5.000000E-01\n"
        f"{end_time:.12E} {temperature:.12E} 1.000000E+08 5.000000E-01\n"
    )


def control_text(
    network_directory: str,
    species: tuple[str, ...],
    screening: bool,
    integrator: str,
    solver_tolerance: float,
    absolute_abundance_tolerance: float,
) -> str:
    output_species = species[: min(14, len(species))]
    heading = "# Species to output in ASCII output (format 14a5):"
    species_heading = f"{heading:<50}{len(output_species):4d}"
    species_row = "".join(f"{name:>5s}" for name in output_species)
    integration_scheme = 3 if integrator == "bdf" else 1
    maximum_iterations = 10 if integrator == "bdf" else 5
    convergence_condition = 3 if integrator == "bdf" else 0
    lower_abundance = 1.0e-99 if integrator == "bdf" else 1.0e-30
    return f"""## Problem Description
controlled fixed-state characterization
diagnostic level 1
generated by test/benchmark/characterize.py
## Job Controls
1         Initial Zone
1         # of Zones
0         Include Weak Reactions (yes=1,no=0,only=-1)
{1 if screening else 0}         Include Screening (yes=1)
1         Process Nuclear Data at Run Time (yes=1,no=0)
## Neutrinos
0         Include Neutrino Reactions (yes=1, no=0)
## NSE Initial Conditions
11.0      Temperature in GK to use NSE initial conditions instead of file
## Integration Controls
{integration_scheme}         Choice of integration Scheme
100000    Max. number of timesteps before quit
{maximum_iterations}         Max. iterations per step
1         Rebuild the jacobian every ijac iterations after the first
{convergence_condition}         Convergence Condition
1.00E-01  Max. Abundance Change per timestep
{absolute_abundance_tolerance:.8E}  Smallest Abundance used in timestep calculation / BDF absolute tolerance
1.00E-06  Mass Conservation Limit
{solver_tolerance:.8E}  Convergence Criterion
{lower_abundance:.8E}  Lower Abundance limit
2.00E+00  Max. Factor to change dt in a timestep
## Self-heating Controls
0         Include self-heating (yes=1,no=0)
1.00E-02  Max. Temperature Change per timestep
1.00E-04  Temperature Convergence Criterion
## Zone Batching Controls
1         Blocking size for zone loop

## Output Controls
0         Diagnostic Output Level
0         Per Timestep Output Level
# ASCII output filename root, network will append zone number
ev_controlled_
# Binary output filename root, network will append zone number
ts_controlled_
{species_heading}
{species_row}
## Input Controls
# Nuclear Data Directory
{network_directory}
# Initial Abundance and Thermodynamic Trajectory Files
controlled_abundance
controlled_trajectory
"""


def prepare_run(
    run_directory: Path,
    network_path: Path,
    species: tuple[str, ...],
    composition: dict[str, float],
    temperature: float,
    end_time: float,
    helm_table: Path,
    screening: bool,
    integrator: str,
    solver_tolerance: float,
    absolute_abundance_tolerance: float,
) -> None:
    run_directory.mkdir(parents=True)
    staged_network = run_directory / network_path.name
    staged_network.mkdir()
    for name in ("sunet", "netsu", "netweak", "netwinv"):
        (staged_network / name).symlink_to((network_path / name).resolve())
    (run_directory / "helm_table.dat").symlink_to(helm_table.resolve())
    (run_directory / "controlled_abundance").write_text(
        abundance_text(species, composition), encoding="utf-8"
    )
    (run_directory / "controlled_trajectory").write_text(
        trajectory_text(end_time, temperature), encoding="utf-8"
    )
    (run_directory / "control").write_text(
        control_text(
            network_path.name,
            species,
            screening,
            integrator,
            solver_tolerance,
            absolute_abundance_tolerance,
        ),
        encoding="utf-8",
    )


def run_one(
    regression: Any,
    executable: Path,
    run_directory: Path,
    species: tuple[str, ...],
    timeout: float,
) -> dict[str, Any]:
    try:
        completed = subprocess.run(
            [str(executable)],
            cwd=run_directory,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        stdout = error.stdout.decode(errors="replace") if isinstance(error.stdout, bytes) else (error.stdout or "")
        stderr = error.stderr.decode(errors="replace") if isinstance(error.stderr, bytes) else (error.stderr or "")
        (run_directory / "xnet.stdout.txt").write_text(stdout, encoding="utf-8")
        (run_directory / "xnet.stderr.txt").write_text(stderr, encoding="utf-8")
        (run_directory / "xnet.status.txt").write_text("timeout\n", encoding="utf-8")
        return {
            "status": "timeout",
            "diagnostic": f"XNet timed out after {timeout:g} seconds",
        }
    (run_directory / "xnet.stdout.txt").write_text(completed.stdout, encoding="utf-8")
    (run_directory / "xnet.stderr.txt").write_text(completed.stderr, encoding="utf-8")
    (run_directory / "xnet.status.txt").write_text(
        f"return_code={completed.returncode}\n", encoding="utf-8"
    )
    if completed.returncode:
        result: dict[str, Any] = {
            "status": "nonzero-exit",
            "return_code": completed.returncode,
            "diagnostic": f"XNet returned {completed.returncode}",
        }
        diagnostic = run_directory / "net_diag01"
        if diagnostic.is_file():
            result["diagnostic_sha256"] = sha256(diagnostic)
        return result
    diagnostic = run_directory / "net_diag01"
    if not diagnostic.is_file():
        return {
            "status": "missing-diagnostic",
            "diagnostic": "XNet returned zero but produced no net_diag01",
        }
    try:
        state = regression.parse_diagnostic(
            diagnostic.read_text(encoding="utf-8", errors="replace"),
            (1,),
            species,
            ((1,),),
        )[0]
    except regression.RegressionFailure as error:
        return {
            "status": "invalid-diagnostic",
            "diagnostic": f"{type(error).__name__}: {error}",
            "diagnostic_sha256": sha256(diagnostic),
        }
    return {
        "status": "success",
        "step": state.step,
        "target_time_seconds": state.target_time,
        "time_seconds": state.time,
        "temperature_gk": state.temperature_gk,
        "density_g_cm3": state.density,
        "electron_fraction": state.electron_fraction,
        "counters": {
            "timesteps": state.counters.ts,
            "newton_iterations": state.counters.nr,
            "jacobian_builds": state.counters.jacobian,
            "derivative_evaluations": state.counters.derivative,
            "cross_section_evaluations": state.counters.cross_section,
        },
        "mass_fractions": state.mass_fractions,
        "diagnostic_sha256": sha256(diagnostic),
    }


def norm_difference(
    left: dict[str, float], right: dict[str, float]
) -> tuple[float, float, str]:
    differences = {name: abs(left[name] - right[name]) for name in left}
    species = max(differences, key=differences.get)
    return math.fsum(differences.values()), differences[species], species


def add_convergence_history(runs: list[dict[str, Any]]) -> dict[str, Any]:
    successful = [run for run in runs if run.get("status") == "success"]
    failed = [
        {
            "requested_end_time_seconds": run["requested_end_time_seconds"],
            "status": run.get("status"),
            "diagnostic": run.get("diagnostic"),
        }
        for run in runs
        if run.get("status") != "success"
    ]
    if not successful:
        return {
            "diagnostic_note": "No successful samples were available for convergence diagnostics.",
            "failed_samples": failed,
            "threshold_sensitivity": [],
        }

    latest = successful[-1]["mass_fractions"]
    for index, run in enumerate(successful):
        current = run["mass_fractions"]
        if index:
            l1, linf, species = norm_difference(
                current, successful[index - 1]["mass_fractions"]
            )
            run["change_from_previous"] = {
                "l1_mass_fraction": l1,
                "linf_mass_fraction": linf,
                "linf_species": species,
            }
        l1, linf, species = norm_difference(current, latest)
        run["distance_from_latest_sample"] = {
            "l1_mass_fraction": l1,
            "linf_mass_fraction": linf,
            "linf_species": species,
        }

    sensitivity = []
    for threshold in DIAGNOSTIC_THRESHOLDS:
        earliest = None
        for index, run in enumerate(successful[1:], start=1):
            later = successful[index:]
            if not failed and all(
                item["change_from_previous"]["linf_mass_fraction"] <= threshold
                and item["distance_from_latest_sample"]["linf_mass_fraction"] <= threshold
                for item in later
            ):
                earliest = run["requested_end_time_seconds"]
                break
        sensitivity.append(
            {
                "linf_mass_fraction_threshold": threshold,
                "earliest_candidate_seconds": earliest,
            }
        )
    return {
        "diagnostic_note": (
            "Criteria are sensitivity diagnostics, not accepted scientific tolerances. "
            "They use printed final mass fractions and require every later sampled interval "
            "to satisfy both successive-change and latest-sample L-infinity bounds. "
            "Any failed requested sample suppresses an endpoint recommendation."
        ),
        "failed_samples": failed,
        "threshold_sensitivity": sensitivity,
    }


def main() -> int:
    args = parse_arguments()
    repository = args.repository.resolve()
    source_repository = require_clean_repository(
        args.source_repository, args.source_revision
    )
    if args.artifacts.exists():
        raise BenchmarkError("--artifacts must name a nonexistent directory")
    if args.output.exists():
        raise BenchmarkError("--output must not already exist")
    if args.timeout_seconds <= 0 or not math.isfinite(args.timeout_seconds):
        raise BenchmarkError("--timeout-seconds must be positive and finite")
    if args.solver_tolerance <= 0 or not math.isfinite(args.solver_tolerance):
        raise BenchmarkError("--solver-tolerance must be positive and finite")
    if (
        args.absolute_abundance_tolerance <= 0
        or not math.isfinite(args.absolute_abundance_tolerance)
    ):
        raise BenchmarkError("--absolute-abundance-tolerance must be positive and finite")

    revision, manifest = require_bundle(repository)
    regression = load_regression(repository / "test/regression/xnet_regression.py")
    networks = args.network or (
        list(NETWORKS) if args.workload == "primary-co" else ["SN160", "CCSN179"]
    )
    temperatures = args.temperature_gk or (
        [1.7] if args.workload == "primary-co" else [2.0, 2.2, 2.5]
    )
    end_times = sorted(set(args.end_time or DEFAULT_END_TIMES))
    if any(
        value <= 0 or not math.isfinite(value)
        for value in (*temperatures, *end_times)
    ):
        raise BenchmarkError("temperatures and end times must be positive and finite")
    composition = (
        PRIMARY_COMPOSITION if args.workload == "primary-co" else SECONDARY_COMPOSITION
    )
    screening = args.screening == "on"
    args.artifacts.mkdir(parents=True)
    executable, build_config, build_command, settings = (
        build_characterization_executable(
            source_repository,
            args.build_dir.resolve(),
            args.artifacts / "build.log",
        )
    )
    retained_build_config = args.artifacts / "build-config.txt"
    shutil.copy2(build_config, retained_build_config)
    helm_table = repository / "tools/starkiller-helmholtz/helm_table.dat"
    results = []
    for network in networks:
        network_path = repository / "test" / NETWORKS[network]
        species = read_species(network_path / "sunet")
        for temperature in temperatures:
            runs = []
            for end_time in end_times:
                time_label = f"{end_time:.6e}".replace("+", "p").replace("-", "m")
                temperature_label = f"{temperature:.3f}".replace(".", "p")
                run_directory = (
                    args.artifacts
                    / args.workload
                    / network
                    / temperature_label
                    / time_label
                )
                prepare_run(
                    run_directory,
                    network_path,
                    species,
                    composition,
                    temperature,
                    end_time,
                    helm_table,
                    screening,
                    args.integrator,
                    args.solver_tolerance,
                    args.absolute_abundance_tolerance,
                )
                result = run_one(
                    regression, executable, run_directory, species, args.timeout_seconds
                )
                result["requested_end_time_seconds"] = end_time
                result["artifact_directory"] = str(
                    run_directory.relative_to(args.artifacts)
                )
                runs.append(result)
            results.append(
                {
                    "network": network,
                    "species_count": len(species),
                    "temperature_gk": temperature,
                    "runs": runs,
                    "convergence": add_convergence_history(runs),
                }
            )

    report = {
        "kind": "xnet-controlled-workload-characterization",
        "workload": args.workload,
        "weak_reactions": False,
        "screening": screening,
        "integrator": args.integrator,
        "solver_tolerance": args.solver_tolerance,
        "absolute_abundance_tolerance": args.absolute_abundance_tolerance,
        "integration_controls": {
            "isolv": 3 if args.integrator == "bdf" else 1,
            "maximum_iterations": 10 if args.integrator == "bdf" else 5,
            "convergence_condition": 3 if args.integrator == "bdf" else 0,
            "absolute_abundance_tolerance": args.absolute_abundance_tolerance,
            "relative_or_iterative_tolerance": args.solver_tolerance,
            "mass_conservation_tolerance": 1.0e-6,
            "lower_abundance_cutoff": (
                1.0e-99 if args.integrator == "bdf" else 1.0e-30
            ),
            "note": (
                "BDF reproduces the maintained bdf_sn160 integration-control "
                "choices; XNet internally disables changemx/changemxt timestep "
                "limits for isolv=3 and uses yacc/tolc as BDF absolute/relative tolerances."
            ),
        },
        "self_heating": False,
        "density_g_cm3": 1.0e8,
        "electron_fraction": 0.5,
        "composition_mass_fractions": composition,
        "authoritative_network_revision": revision,
        "network_manifest_sha256": sha256(
            Path(__file__).with_name("network-bundle-a9585568.json")
        ),
        "network_files": manifest,
        "executable_path": str(executable),
        "executable_sha256": sha256(executable),
        "source_revision": args.source_revision,
        "source_repository": str(source_repository),
        "build_config_path": "build-config.txt",
        "build_config_sha256": sha256(retained_build_config),
        "build_log_path": "build.log",
        "build_log_sha256": sha256(args.artifacts / "build.log"),
        "build_argv": build_command,
        "build_settings": settings,
        "results": results,
    }
    artifact_inventory = inventory(args.artifacts)
    report["artifact_inventory"] = artifact_inventory
    write_json(args.artifacts / "inventory.json", artifact_inventory)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(args.output)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BenchmarkError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
