#!/usr/bin/env python3
"""Run and validate the manual Frontier GPU correctness qualification."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
from typing import Mapping, Sequence


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPOSITORY_ROOT / "test" / "qualification"))
sys.path.insert(0, str(REPOSITORY_ROOT / "test" / "regression"))

from parallel_zones import (  # noqa: E402
    AsciiEndpoint,
    EXPECTED_ZONES,
    QualificationFailure as ParallelQualificationFailure,
    run_configuration,
)
from xnet_regression import (  # noqa: E402
    FinalState,
    RegressionFailure,
    heat_sn160_case,
    parse_diagnostic,
    prepare_work_directory as prepare_regression_work_directory,
    run_xnet,
)


MANIFEST_SCHEMA = "xnet-frontier-qualification-v1"
POLICY_SCHEMA = "xnet-frontier-comparison-v1"
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
SOURCE_SHA_PATTERN = re.compile(r"^[0-9a-f]{40}$")
LINALG_BATCH_PATTERN = re.compile(
    r"^XNET_GPU_LINALG batch\s+(\d+)\s+info\s+(-?\d+)\s+"
    r"relative_residual\s+([^\s]+)$"
)
REQUIRED_MODULE_MARKERS = (
    "PrgEnv-cray",
    "rocm",
    "craype-accel-amd-gfx90a",
    "hipfort",
)
CPU_BUILD_VARIABLES = {
    "CMODE": "OPT",
    "PE_ENV": "CRAY",
    "MPI_MODE": "OFF",
    "OPENMP_MODE": "OFF",
    "GPU_MODE": "OFF",
    "OPENACC_MODE": "OFF",
    "OPENMP_OL_MODE": "OFF",
    "EOS": "STARKILLER",
    "MATRIX_SOLVER": "dense",
    "LAPACK_VER": "LIBSCI",
}
GPU_BUILD_VARIABLES = {
    "CMODE": "OPT",
    "PE_ENV": "CRAY",
    "MPI_MODE": "OFF",
    "OPENMP_MODE": "OFF",
    "GPU_MODE": "ON",
    "GPU_BACKEND": "HIP",
    "OPENACC_MODE": "OFF",
    "OPENMP_OL_MODE": "ON",
    "GPU_LAPACK_VER": "ROCM",
    "EOS": "STARKILLER",
    "MATRIX_SOLVER": "dense",
    "LAPACK_VER": "LIBSCI",
}


class FrontierFailure(RuntimeError):
    """A classified source, environment, build, execution, or comparison failure."""

    def __init__(self, category: str, phase: str, message: str):
        super().__init__(message)
        self.category = category
        self.phase = phase


@dataclass(frozen=True)
class Bounds:
    atol: float
    rtol: float


@dataclass(frozen=True)
class NumericalPolicy:
    status: str
    target_time_exact: bool
    scalar_fields: Mapping[str, Bounds]
    ascii_fields: Mapping[str, Bounds]
    reported_ascii_fields: tuple[str, ...]
    material_threshold: float
    anchors: tuple[str, ...]
    selected: Bounds
    complete_vector_l1_limit: float
    complete_vector_linf_limit: float
    normalization_atol: float


def _finite_nonnegative(value: object, context: str) -> float:
    if not isinstance(value, (int, float)):
        raise FrontierFailure("source", "comparison-policy", f"{context} is not numeric")
    normalized = float(value)
    if not math.isfinite(normalized) or normalized < 0.0:
        raise FrontierFailure(
            "source", "comparison-policy", f"{context} must be finite and nonnegative"
        )
    return normalized


def _load_bounds(document: object, context: str) -> Bounds:
    if not isinstance(document, dict) or set(document) != {"atol", "rtol"}:
        raise FrontierFailure(
            "source", "comparison-policy", f"{context} must contain only atol and rtol"
        )
    return Bounds(
        _finite_nonnegative(document["atol"], f"{context}.atol"),
        _finite_nonnegative(document["rtol"], f"{context}.rtol"),
    )


def load_policy(path: Path) -> NumericalPolicy:
    """Load the reviewed, bounded CPU/GPU endpoint policy."""

    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise FrontierFailure(
            "source", "comparison-policy", f"could not read policy {path}: {error}"
        ) from error
    required = {
        "schema",
        "status",
        "target_time_exact",
        "scalar_fields",
        "ascii_fields",
        "reported_ascii_fields",
        "mass_fractions",
    }
    if not isinstance(document, dict) or set(document) != required:
        raise FrontierFailure(
            "source", "comparison-policy", "comparison policy has unexpected fields"
        )
    if document["schema"] != POLICY_SCHEMA:
        raise FrontierFailure("source", "comparison-policy", "comparison policy schema differs")
    scalar_names = {
        "achieved_time",
        "temperature_gk",
        "density",
        "electron_fraction",
    }
    ascii_names = {"neutrino_loss_rate", "timestep"}
    reported_ascii_names = ["energy_generation_rate"]
    scalar_document = document["scalar_fields"]
    ascii_document = document["ascii_fields"]
    if not isinstance(scalar_document, dict) or set(scalar_document) != scalar_names:
        raise FrontierFailure("source", "comparison-policy", "scalar field policy is incomplete")
    if not isinstance(ascii_document, dict) or set(ascii_document) != ascii_names:
        raise FrontierFailure("source", "comparison-policy", "ASCII field policy is incomplete")
    reported_ascii_fields = document["reported_ascii_fields"]
    if (
        not isinstance(reported_ascii_fields, list)
        or reported_ascii_fields != reported_ascii_names
    ):
        raise FrontierFailure(
            "source", "comparison-policy", "reported ASCII field policy is incomplete"
        )
    mass = document["mass_fractions"]
    mass_names = {
        "material_threshold",
        "anchors",
        "selected",
        "complete_vector_l1_limit",
        "complete_vector_linf_limit",
        "normalization_atol",
    }
    if not isinstance(mass, dict) or set(mass) != mass_names:
        raise FrontierFailure("source", "comparison-policy", "mass-fraction policy is incomplete")
    anchors = mass["anchors"]
    if (
        not isinstance(anchors, list)
        or not anchors
        or any(not isinstance(item, str) or not item for item in anchors)
        or len(set(anchors)) != len(anchors)
    ):
        raise FrontierFailure("source", "comparison-policy", "anchors are invalid")
    if not isinstance(document["status"], str) or not document["status"].strip():
        raise FrontierFailure("source", "comparison-policy", "policy status is empty")
    if document["target_time_exact"] is not True:
        raise FrontierFailure("source", "comparison-policy", "target time must remain exact")
    return NumericalPolicy(
        status=document["status"],
        target_time_exact=True,
        scalar_fields={
            name: _load_bounds(scalar_document[name], f"scalar_fields.{name}")
            for name in sorted(scalar_names)
        },
        ascii_fields={
            name: _load_bounds(ascii_document[name], f"ascii_fields.{name}")
            for name in sorted(ascii_names)
        },
        reported_ascii_fields=tuple(reported_ascii_fields),
        material_threshold=_finite_nonnegative(
            mass["material_threshold"], "mass_fractions.material_threshold"
        ),
        anchors=tuple(anchors),
        selected=_load_bounds(mass["selected"], "mass_fractions.selected"),
        complete_vector_l1_limit=_finite_nonnegative(
            mass["complete_vector_l1_limit"],
            "mass_fractions.complete_vector_l1_limit",
        ),
        complete_vector_linf_limit=_finite_nonnegative(
            mass["complete_vector_linf_limit"],
            "mass_fractions.complete_vector_linf_limit",
        ),
        normalization_atol=_finite_nonnegative(
            mass["normalization_atol"], "mass_fractions.normalization_atol"
        ),
    )


def _difference(actual: float, reference: float, bounds: Bounds) -> tuple[bool, float, float]:
    difference = abs(actual - reference)
    allowed = bounds.atol + bounds.rtol * abs(reference)
    return difference <= allowed, difference, allowed


def compare_endpoint_states(
    actual: Sequence[FinalState],
    reference: Sequence[FinalState],
    policy: NumericalPolicy,
    label: str,
) -> dict[str, object]:
    """Compare normalized per-zone endpoints and return observed-difference evidence."""

    actual_by_zone = {state.zone: state for state in actual}
    reference_by_zone = {state.zone: state for state in reference}
    if len(actual_by_zone) != len(actual) or len(reference_by_zone) != len(reference):
        raise FrontierFailure("test", label, "duplicate endpoint zone")
    if set(actual_by_zone) != set(reference_by_zone):
        raise FrontierFailure(
            "test", label, "CPU/GPU endpoint zone inventory differs"
        )

    failures: list[str] = []
    observations: list[dict[str, object]] = []
    maximum_selected_ratio = 0.0
    for zone in sorted(reference_by_zone):
        candidate = actual_by_zone[zone]
        baseline = reference_by_zone[zone]
        if tuple(candidate.mass_fractions) != tuple(baseline.mass_fractions):
            failures.append(f"zone {zone} species identity/order differs")
            continue
        if candidate.target_time != baseline.target_time:
            failures.append(f"zone {zone} target_time is not exact")

        scalar_differences: dict[str, dict[str, float]] = {}
        for policy_name, attribute in (
            ("achieved_time", "time"),
            ("temperature_gk", "temperature_gk"),
            ("density", "density"),
            ("electron_fraction", "electron_fraction"),
        ):
            observed = getattr(candidate, attribute)
            expected = getattr(baseline, attribute)
            passed, difference, allowed = _difference(
                observed, expected, policy.scalar_fields[policy_name]
            )
            scalar_differences[policy_name] = {
                "absolute": difference,
                "allowed": allowed,
            }
            if not passed:
                failures.append(
                    f"zone {zone} {policy_name} difference {difference:.3e} "
                    f"exceeds {allowed:.3e}"
                )

        selected = tuple(
            species
            for species, value in baseline.mass_fractions.items()
            if species in policy.anchors or value >= policy.material_threshold
        )
        if not selected:
            failures.append(f"zone {zone} selects no material species")
        vector_differences = {
            species: abs(candidate.mass_fractions[species] - expected)
            for species, expected in baseline.mass_fractions.items()
        }
        linf_species = max(vector_differences, key=vector_differences.__getitem__)
        linf = vector_differences[linf_species]
        l1 = math.fsum(vector_differences.values())
        if l1 > policy.complete_vector_l1_limit:
            failures.append(
                f"zone {zone} composition L1 {l1:.3e} exceeds "
                f"{policy.complete_vector_l1_limit:.3e}"
            )
        if linf > policy.complete_vector_linf_limit:
            failures.append(
                f"zone {zone} composition Linf {linf:.3e} at {linf_species} exceeds "
                f"{policy.complete_vector_linf_limit:.3e}"
            )
        for species in selected:
            passed, difference, allowed = _difference(
                candidate.mass_fractions[species],
                baseline.mass_fractions[species],
                policy.selected,
            )
            ratio = difference / allowed if allowed > 0.0 else math.inf
            maximum_selected_ratio = max(maximum_selected_ratio, ratio)
            if not passed:
                failures.append(
                    f"zone {zone} {species} difference {difference:.3e} exceeds "
                    f"{allowed:.3e}"
                )
        for state_name, state in (("CPU", baseline), ("GPU", candidate)):
            values = tuple(state.mass_fractions.values())
            if any(not math.isfinite(value) or value < 0.0 for value in values):
                failures.append(f"zone {zone} {state_name} composition is non-finite or negative")
            normalization_error = abs(math.fsum(values) - 1.0)
            if normalization_error > policy.normalization_atol:
                failures.append(
                    f"zone {zone} {state_name} normalization error "
                    f"{normalization_error:.3e} exceeds {policy.normalization_atol:.3e}"
                )
        observations.append(
            {
                "zone": zone,
                "scalar_differences": scalar_differences,
                "selected_species": list(selected),
                "composition_l1": l1,
                "composition_linf": linf,
                "composition_linf_species": linf_species,
            }
        )
    if failures:
        raise FrontierFailure(
            "comparison", label, "CPU/GPU endpoint comparison failed:\n  " + "\n  ".join(failures)
        )
    return {
        "status": "passed",
        "policy_status": policy.status,
        "maximum_selected_fraction_of_allowed": maximum_selected_ratio,
        "zones": observations,
    }


def compare_ascii_endpoints(
    actual: Sequence[AsciiEndpoint],
    reference: Sequence[AsciiEndpoint],
    policy: NumericalPolicy,
    label: str,
) -> dict[str, object]:
    actual_by_zone = {item.zone: item for item in actual}
    reference_by_zone = {item.zone: item for item in reference}
    if set(actual_by_zone) != set(reference_by_zone):
        raise FrontierFailure("test", label, "ASCII endpoint zone inventory differs")
    failures: list[str] = []
    maximum_ratio = 0.0
    observations: list[dict[str, object]] = []
    for zone in sorted(reference_by_zone):
        field_differences: dict[str, dict[str, object]] = {}
        for field in policy.ascii_fields:
            observed = getattr(actual_by_zone[zone], field)
            expected = getattr(reference_by_zone[zone], field)
            passed, difference, allowed = _difference(
                observed, expected, policy.ascii_fields[field]
            )
            field_differences[field] = {
                "comparison": "bounded",
                "observed": observed,
                "expected": expected,
                "difference": difference,
                "allowed": allowed,
            }
            maximum_ratio = max(
                maximum_ratio, difference / allowed if allowed > 0.0 else math.inf
            )
            if not passed:
                failures.append(
                    f"zone {zone} {field}: observed {observed:.8e}, "
                    f"expected {expected:.8e}, difference {difference:.3e} "
                    f"exceeds {allowed:.3e}"
                )
        for field in policy.reported_ascii_fields:
            observed = getattr(actual_by_zone[zone], field)
            expected = getattr(reference_by_zone[zone], field)
            field_differences[field] = {
                "comparison": "reported_only",
                "observed": observed,
                "expected": expected,
                "difference": abs(observed - expected),
            }
        observations.append({"zone": zone, "field_differences": field_differences})
    if failures:
        raise FrontierFailure(
            "comparison", label, "CPU/GPU ASCII comparison failed:\n  " + "\n  ".join(failures)
        )
    return {
        "status": "passed",
        "maximum_fraction_of_allowed": maximum_ratio,
        "reported_only_fields": list(policy.reported_ascii_fields),
        "zones": observations,
    }


def parse_linalg_probe(text: str, residual_limit: float = 1.0e-12) -> dict[str, object]:
    """Require real device execution, two successful factors, and small residuals."""

    device_count: int | None = None
    offloaded: bool | None = None
    data_present: bool | None = None
    status: str | None = None
    batches: list[dict[str, object]] = []
    for line in text.splitlines():
        fields = line.split()
        if line.startswith("XNET_GPU_LINALG device_count ") and len(fields) == 3:
            device_count = int(fields[2])
        elif line.startswith("XNET_GPU_LINALG offloaded ") and len(fields) == 3:
            offloaded = fields[2].upper() == "T"
        elif line.startswith("XNET_GPU_LINALG data_present ") and len(fields) == 3:
            data_present = fields[2].upper() == "T"
        elif line.startswith("XNET_GPU_LINALG status ") and len(fields) >= 3:
            status = fields[2]
        else:
            match = LINALG_BATCH_PATTERN.match(line)
            if match:
                residual = float(match.group(3).replace("D", "E"))
                batches.append(
                    {
                        "batch": int(match.group(1)),
                        "info": int(match.group(2)),
                        "relative_residual": residual,
                    }
                )
    if device_count is None or device_count < 1:
        raise FrontierFailure("allocation", "gpu-linalg", "probe did not find a GPU")
    if offloaded is not True:
        raise FrontierFailure("allocation", "gpu-linalg", "OpenMP target stayed on the host")
    if data_present is not True:
        raise FrontierFailure("test", "gpu-linalg", "mapped solve data is not present")
    if status != "passed" or [item["batch"] for item in batches] != [1, 2]:
        raise FrontierFailure("test", "gpu-linalg", "probe report is incomplete or failed")
    for item in batches:
        residual = item["relative_residual"]
        if (
            item["info"] != 0
            or not isinstance(residual, float)
            or not math.isfinite(residual)
            or residual > residual_limit
        ):
            raise FrontierFailure(
                "test", "gpu-linalg", f"factor/solve failure in batch {item['batch']}"
            )
    return {
        "status": "passed",
        "device_count": device_count,
        "offloaded": True,
        "data_present": True,
        "residual_limit": residual_limit,
        "batches": batches,
    }


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def inventory_regular_files(
    directory: Path,
    *,
    exclude: Sequence[Path] = (),
    exclude_trees: Sequence[Path] = (),
) -> list[dict[str, object]]:
    """Inventory every regular non-symlink file below a directory."""

    excluded = {path.as_posix() for path in exclude}
    excluded_trees = tuple(path.as_posix() for path in exclude_trees)
    inventory: list[dict[str, object]] = []
    for path in sorted(directory.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        relative = path.relative_to(directory).as_posix()
        if relative in excluded or any(
            relative == tree or relative.startswith(tree + "/")
            for tree in excluded_trees
        ):
            continue
        inventory.append(
            {"path": relative, "size": path.stat().st_size, "sha256": _sha256(path)}
        )
    return inventory


def _record_command(
    command: Sequence[str],
    directory: Path,
    artifact_directory: Path,
    label: str,
    *,
    timeout_seconds: float,
    environment: Mapping[str, str] | None = None,
) -> tuple[subprocess.CompletedProcess[str], float]:
    artifact_directory.mkdir(parents=True, exist_ok=True)
    (artifact_directory / f"{label}.command.json").write_text(
        json.dumps(list(command), indent=2) + "\n", encoding="utf-8"
    )
    started = time.monotonic()
    try:
        completed = subprocess.run(
            command,
            cwd=directory,
            env=None if environment is None else dict(environment),
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
            check=False,
        )
        elapsed = time.monotonic() - started
        status = f"return_code={completed.returncode}"
    except subprocess.TimeoutExpired as error:
        elapsed = time.monotonic() - started
        completed = subprocess.CompletedProcess(
            command,
            124,
            "" if error.stdout is None else str(error.stdout),
            "" if error.stderr is None else str(error.stderr),
        )
        status = "timeout"
    (artifact_directory / f"{label}.stdout.txt").write_text(
        completed.stdout, encoding="utf-8"
    )
    (artifact_directory / f"{label}.stderr.txt").write_text(
        completed.stderr, encoding="utf-8"
    )
    (artifact_directory / f"{label}.status.json").write_text(
        json.dumps({"status": status, "runtime_seconds": elapsed}, indent=2) + "\n",
        encoding="utf-8",
    )
    return completed, elapsed


def _make_command(
    source_root: Path,
    variables: Mapping[str, str],
    jobs: int,
    *targets: str,
) -> list[str]:
    return [
        "make",
        "-C",
        str(source_root / "source"),
        f"-j{jobs}",
        *(f"{name}={value}" for name, value in variables.items()),
        *targets,
    ]


def _build_configuration(
    source_root: Path,
    artifact_root: Path,
    label: str,
    variables: Mapping[str, str],
    jobs: int,
    targets: Sequence[str],
) -> dict[str, object]:
    build_directory = artifact_root / "build" / label
    source_directory = source_root / "source"
    for executable in (source_directory / "xnet", source_directory / "frontier_gpu_linalg_probe"):
        executable.unlink(missing_ok=True)
    clean, _ = _record_command(
        ["make", "-C", str(source_directory), "clean"],
        source_root,
        build_directory,
        "clean",
        timeout_seconds=300.0,
    )
    if clean.returncode != 0:
        raise FrontierFailure("build", f"{label}-clean", "make clean failed")
    completed, runtime = _record_command(
        _make_command(source_root, variables, jobs, *targets),
        source_root,
        build_directory,
        "build",
        timeout_seconds=1800.0,
    )
    if completed.returncode != 0:
        raise FrontierFailure("build", f"{label}-build", "configuration build failed")
    print_targets = [f"print-{name}" for name in variables]
    resolved, _ = _record_command(
        _make_command(source_root, variables, 1, *print_targets),
        source_root,
        build_directory,
        "resolved-variables",
        timeout_seconds=120.0,
    )
    if resolved.returncode != 0:
        raise FrontierFailure("build", f"{label}-manifest", "could not resolve build variables")

    binary_directory = artifact_root / "bin"
    binary_directory.mkdir(exist_ok=True)
    executables: dict[str, dict[str, object]] = {}
    for target in targets:
        source = source_directory / target
        if not source.is_file() or not os.access(source, os.X_OK):
            raise FrontierFailure("build", f"{label}-build", f"missing executable {target}")
        destination_name = f"{target}-{label}"
        destination = binary_directory / destination_name
        shutil.copy2(source, destination)
        link, _ = _record_command(
            ["ldd", str(destination)],
            source_root,
            build_directory,
            f"{target}-link",
            timeout_seconds=120.0,
        )
        if link.returncode != 0:
            raise FrontierFailure("build", f"{label}-link", f"ldd failed for {target}")
        executables[target] = {
            "artifact": f"bin/{destination_name}",
            "size": destination.stat().st_size,
            "sha256": _sha256(destination),
            "link_evidence": f"build/{label}/{target}-link.stdout.txt",
        }
    return {
        "status": "passed",
        "variables": dict(variables),
        "resolved_variables": f"build/{label}/resolved-variables.stdout.txt",
        "timeout_seconds": 1800.0,
        "runtime_seconds": runtime,
        "executables": executables,
    }


def _capture_environment(artifact_root: Path) -> dict[str, object]:
    environment_directory = artifact_root / "environment"
    environment_directory.mkdir(parents=True, exist_ok=True)
    modules = tuple(filter(None, os.environ.get("LOADEDMODULES", "").split(":")))
    missing = [
        marker for marker in REQUIRED_MODULE_MARKERS if not any(marker in item for item in modules)
    ]
    if missing:
        raise FrontierFailure(
            "environment", "modules", "required modules are missing: " + ", ".join(missing)
        )
    required_environment = ("ROCM_PATH", "OLCF_HIPFORT_ROOT")
    missing_environment = [name for name in required_environment if not os.environ.get(name)]
    if missing_environment:
        raise FrontierFailure(
            "environment",
            "modules",
            "required module variables are missing: " + ", ".join(missing_environment),
        )
    commands = {
        "compiler": ["ftn", "--version"],
        "preprocessor": ["cpp", "--version"],
        "rocm": ["rocminfo"],
        "gpu": ["rocm-smi", "--showproductname"],
    }
    command_summaries: dict[str, dict[str, object]] = {}
    for label, command in commands.items():
        completed, runtime = _record_command(
            command,
            REPOSITORY_ROOT,
            environment_directory,
            label,
            timeout_seconds=120.0,
        )
        if completed.returncode != 0:
            category = "allocation" if label in ("rocm", "gpu") else "environment"
            raise FrontierFailure(category, f"environment-{label}", f"{label} probe failed")
        command_summaries[label] = {
            "artifact": f"environment/{label}.stdout.txt",
            "sha256": _sha256(environment_directory / f"{label}.stdout.txt"),
            "runtime_seconds": runtime,
        }
    gpu_text = (environment_directory / "gpu.stdout.txt").read_text(encoding="utf-8")
    gpu_model = next(
        (line.strip() for line in gpu_text.splitlines() if "MI250" in line.upper()),
        "",
    )
    if not gpu_model:
        raise FrontierFailure("allocation", "environment-gpu", "MI250X GPU was not reported")
    return {
        "modules": list(modules),
        "compiler": command_summaries["compiler"],
        "preprocessor": command_summaries["preprocessor"],
        "rocm": command_summaries["rocm"],
        "gpu": command_summaries["gpu"],
        "gpu_model": gpu_model,
        "rocm_version": Path(os.environ["ROCM_PATH"]).name,
        "hipfort_module": next(item for item in modules if "hipfort" in item),
    }


def _input_inventory(source_root: Path) -> list[dict[str, object]]:
    partial = source_root / "test" / "qualification" / "parallel_zones"
    paths = [partial / "control"]
    for zone in EXPECTED_ZONES:
        paths.extend((partial / f"abundance_{zone:02d}", partial / f"thermo_{zone:02d}"))
    paths.extend(
        source_root / "test" / "Data_alpha" / name
        for name in ("sunet", "netsu", "netweak", "netwinv")
    )
    heat = heat_sn160_case(source_root)
    paths.extend((heat.control, heat.helm_table, *heat.trajectories))
    paths.extend(heat.network_data / name for name in heat.network_inputs)
    unique = sorted(set(path.resolve() for path in paths))
    missing = [path for path in unique if not path.is_file()]
    if missing:
        raise FrontierFailure("source", "input-inventory", f"missing input {missing[0]}")
    return [
        {
            "path": path.relative_to(source_root.resolve()).as_posix(),
            "size": path.stat().st_size,
            "sha256": _sha256(path),
        }
        for path in unique
    ]


def _run_linalg_probe(executable: Path, artifact_root: Path) -> dict[str, object]:
    directory = artifact_root / "runs" / "gpu-linalg"
    timeout_seconds = 60.0
    environment = os.environ.copy()
    environment.update({"OMP_NUM_THREADS": "1", "OMP_TARGET_OFFLOAD": "MANDATORY"})
    completed, runtime = _record_command(
        [str(executable)],
        directory,
        directory,
        "probe",
        timeout_seconds=timeout_seconds,
        environment=environment,
    )
    if completed.returncode != 0:
        raise FrontierFailure(
            "test", "gpu-linalg", f"GPU linear-algebra probe returned {completed.returncode}"
        )
    result = parse_linalg_probe(completed.stdout)
    result["timeout_seconds"] = timeout_seconds
    result["runtime_seconds"] = runtime
    result["output_inventory"] = inventory_regular_files(directory)
    return result


def _run_partial_batch(
    cpu_executable: Path,
    gpu_executable: Path,
    artifact_root: Path,
    policy: NumericalPolicy,
) -> dict[str, object]:
    root = artifact_root / "runs" / "partial-batch"
    timeout_seconds = 180.0
    try:
        cpu_started = time.monotonic()
        cpu = run_configuration(
            "Frontier CPU",
            (cpu_executable,),
            root / "cpu",
            timeout_seconds,
        )
        cpu_runtime = time.monotonic() - cpu_started
        gpu_environment = os.environ.copy()
        gpu_environment.update({"OMP_NUM_THREADS": "1", "OMP_TARGET_OFFLOAD": "MANDATORY"})
        gpu_started = time.monotonic()
        gpu = run_configuration(
            "Frontier GPU",
            (gpu_executable,),
            root / "gpu",
            timeout_seconds,
            gpu_environment,
        )
        gpu_runtime = time.monotonic() - gpu_started
    except ParallelQualificationFailure as error:
        raise FrontierFailure("test", "partial-batch", str(error)) from error
    endpoint = compare_endpoint_states(gpu.states, cpu.states, policy, "partial-batch")
    ascii_result = compare_ascii_endpoints(
        gpu.ascii_endpoints, cpu.ascii_endpoints, policy, "partial-batch-ascii"
    )
    return {
        "status": "passed",
        "fixture": "ten distinguishable zones, nzbatchmx=4",
        "zones": list(EXPECTED_ZONES),
        "inactive_final_batch_lanes": 2,
        "timeout_seconds": timeout_seconds,
        "cpu_runtime_seconds": cpu_runtime,
        "gpu_runtime_seconds": gpu_runtime,
        "endpoint_comparison": endpoint,
        "ascii_comparison": ascii_result,
        "cpu_output_inventory": inventory_regular_files(
            root / "cpu", exclude=(Path("control"),)
        ),
        "gpu_output_inventory": inventory_regular_files(
            root / "gpu", exclude=(Path("control"),)
        ),
    }


def _run_heat_configuration(
    executable: Path,
    source_root: Path,
    directory: Path,
    timeout_seconds: float,
    environment: Mapping[str, str] | None = None,
) -> tuple[tuple[FinalState, ...], float]:
    case = heat_sn160_case(source_root)
    try:
        prepared = prepare_regression_work_directory(case, directory)
        started = time.monotonic()
        run_xnet(
            executable,
            case,
            prepared,
            timeout_seconds=timeout_seconds,
            environment=environment,
        )
        runtime = time.monotonic() - started
        diagnostic_path = prepared / "net_diag01"
        diagnostic = diagnostic_path.read_text(encoding="utf-8")
        return (
            parse_diagnostic(
                diagnostic,
                case.expected_zones,
                case.expected_species,
                case.expected_diagnostic_groups,
            ),
            runtime,
        )
    except (OSError, UnicodeError, RegressionFailure) as error:
        raise FrontierFailure("test", "heat-sn160", str(error)) from error


def _run_heat_sn160(
    cpu_executable: Path,
    gpu_executable: Path,
    source_root: Path,
    artifact_root: Path,
    policy: NumericalPolicy,
) -> dict[str, object]:
    root = artifact_root / "runs" / "heat-sn160"
    timeout_seconds = 600.0
    cpu, cpu_runtime = _run_heat_configuration(
        cpu_executable, source_root, root / "cpu", timeout_seconds
    )
    gpu_environment = os.environ.copy()
    gpu_environment.update({"OMP_NUM_THREADS": "1", "OMP_TARGET_OFFLOAD": "MANDATORY"})
    gpu, gpu_runtime = _run_heat_configuration(
        gpu_executable,
        source_root,
        root / "gpu",
        timeout_seconds,
        gpu_environment,
    )
    endpoint = compare_endpoint_states(gpu, cpu, policy, "heat-sn160")
    return {
        "status": "passed",
        "case": "heat_sn160",
        "zones": [state.zone for state in cpu],
        "timeout_seconds": timeout_seconds,
        "cpu_runtime_seconds": cpu_runtime,
        "gpu_runtime_seconds": gpu_runtime,
        "endpoint_comparison": endpoint,
        "cpu_output_inventory": inventory_regular_files(
            root / "cpu", exclude=(Path("control"),)
        ),
        "gpu_output_inventory": inventory_regular_files(
            root / "gpu", exclude=(Path("control"),)
        ),
    }


def _slurm_manifest() -> dict[str, object]:
    return {
        "job_id": os.environ.get("SLURM_JOB_ID", "unknown"),
        "partition": os.environ.get("SLURM_JOB_PARTITION", "unknown"),
        "nodes": int(os.environ.get("SLURM_JOB_NUM_NODES", "1")),
        "tasks": int(os.environ.get("SLURM_NTASKS", "1")),
        "cpus_per_task": int(os.environ.get("SLURM_CPUS_PER_TASK", "1")),
        "gpus_per_task": 1,
        "time_limit": os.environ.get("SLURM_TIMELIMIT", "unknown"),
    }


def run_qualification(arguments: argparse.Namespace) -> Path:
    source_root = arguments.source_root.resolve()
    artifact_root = arguments.artifact_root.resolve()
    artifact_root.mkdir(parents=True, exist_ok=True)
    report_path = artifact_root / "qualification_manifest.json"
    started = datetime.now(timezone.utc)
    report: dict[str, object] = {
        "schema": MANIFEST_SCHEMA,
        "status": "failed",
        "failure": None,
        "source": {
            "sha": arguments.source_sha,
            "worktree_clean": True,
            "archive_sha256": arguments.archive_sha256,
        },
        "environment": {},
        "slurm": _slurm_manifest(),
        "builds": {},
        "inputs": [],
        "checks": {},
        "artifact_inventory": [],
        "started_at_utc": started.isoformat(),
        "finished_at_utc": None,
        "runtime_seconds": None,
    }
    monotonic_start = time.monotonic()
    try:
        if not SOURCE_SHA_PATTERN.fullmatch(arguments.source_sha):
            raise FrontierFailure("source", "source-sha", "source SHA is not a full commit")
        if not SHA256_PATTERN.fullmatch(arguments.archive_sha256):
            raise FrontierFailure("source", "source-archive", "archive SHA-256 is invalid")
        policy = load_policy(
            source_root
            / "test"
            / "qualification"
            / "frontier"
            / "comparison_policy.json"
        )
        report["environment"] = _capture_environment(artifact_root)
        report["inputs"] = _input_inventory(source_root)
        builds = report["builds"]
        assert isinstance(builds, dict)
        builds["cpu"] = _build_configuration(
            source_root,
            artifact_root,
            "cpu",
            CPU_BUILD_VARIABLES,
            arguments.build_jobs,
            ("xnet",),
        )
        builds["gpu"] = _build_configuration(
            source_root,
            artifact_root,
            "gpu",
            GPU_BUILD_VARIABLES,
            arguments.build_jobs,
            ("xnet", "frontier_gpu_linalg_probe"),
        )
        cpu_executable = artifact_root / "bin" / "xnet-cpu"
        gpu_executable = artifact_root / "bin" / "xnet-gpu"
        probe_executable = artifact_root / "bin" / "frontier_gpu_linalg_probe-gpu"
        checks = report["checks"]
        assert isinstance(checks, dict)
        checks["gpu_linalg"] = _run_linalg_probe(probe_executable, artifact_root)
        checks["partial_batch"] = _run_partial_batch(
            cpu_executable, gpu_executable, artifact_root, policy
        )
        checks["heat_sn160"] = _run_heat_sn160(
            cpu_executable, gpu_executable, source_root, artifact_root, policy
        )
        report["status"] = "passed"
    except FrontierFailure as error:
        report["failure"] = {
            "category": error.category,
            "phase": error.phase,
            "message": str(error),
        }
    except (OSError, ValueError) as error:
        report["failure"] = {
            "category": "test",
            "phase": "qualification-runner",
            "message": str(error),
        }
    finally:
        report["artifact_inventory"] = inventory_regular_files(
            artifact_root,
            exclude=(Path("qualification_manifest.json"), Path("source.tar")),
            exclude_trees=(Path("source"),),
        )
        report["finished_at_utc"] = datetime.now(timezone.utc).isoformat()
        report["runtime_seconds"] = time.monotonic() - monotonic_start
        report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return report_path


def write_failure_manifest(arguments: argparse.Namespace) -> Path:
    """Write classified evidence when Slurm cannot start the qualification step."""

    artifact_root = arguments.artifact_root.resolve()
    artifact_root.mkdir(parents=True, exist_ok=True)
    now = datetime.now(timezone.utc).isoformat()
    report = {
        "schema": MANIFEST_SCHEMA,
        "status": "failed",
        "failure": {
            "category": arguments.category,
            "phase": arguments.phase,
            "message": arguments.message,
        },
        "source": {
            "sha": arguments.source_sha,
            "worktree_clean": True,
            "archive_sha256": arguments.archive_sha256,
        },
        "environment": {},
        "slurm": _slurm_manifest(),
        "builds": {},
        "inputs": [],
        "checks": {},
        "artifact_inventory": inventory_regular_files(
            artifact_root,
            exclude=(Path("qualification_manifest.json"), Path("source.tar")),
            exclude_trees=(Path("source"),),
        ),
        "started_at_utc": now,
        "finished_at_utc": now,
        "runtime_seconds": 0.0,
    }
    report_path = artifact_root / "qualification_manifest.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return report_path


def validate_manifest(document: object, *, require_pass: bool = True) -> None:
    """Validate the evidence fields required by issue #46."""

    required = {
        "schema",
        "status",
        "failure",
        "source",
        "environment",
        "slurm",
        "builds",
        "inputs",
        "checks",
        "artifact_inventory",
        "started_at_utc",
        "finished_at_utc",
        "runtime_seconds",
    }
    if not isinstance(document, dict) or set(document) != required:
        raise FrontierFailure("source", "manifest", "manifest fields differ from schema")
    if document["schema"] != MANIFEST_SCHEMA:
        raise FrontierFailure("source", "manifest", "manifest schema differs")
    if require_pass and document["status"] != "passed":
        raise FrontierFailure("test", "manifest", "qualification status is not passed")
    source = document["source"]
    if (
        not isinstance(source, dict)
        or not SOURCE_SHA_PATTERN.fullmatch(str(source.get("sha", "")))
        or source.get("worktree_clean") is not True
        or not SHA256_PATTERN.fullmatch(str(source.get("archive_sha256", "")))
    ):
        raise FrontierFailure("source", "manifest", "source evidence is incomplete")
    if document["status"] != "passed":
        failure = document["failure"]
        if (
            not isinstance(failure, dict)
            or set(failure) != {"category", "phase", "message"}
            or not all(isinstance(failure[name], str) and failure[name] for name in failure)
        ):
            raise FrontierFailure("test", "manifest", "failure classification is incomplete")
        return
    environment = document["environment"]
    if not isinstance(environment, dict) or not environment.get("gpu_model"):
        raise FrontierFailure("environment", "manifest", "environment evidence is incomplete")
    modules = environment.get("modules", [])
    if any(not any(marker in item for item in modules) for marker in REQUIRED_MODULE_MARKERS):
        raise FrontierFailure("environment", "manifest", "module evidence is incomplete")
    slurm = document["slurm"]
    if not isinstance(slurm, dict) or str(slurm.get("job_id", "unknown")) == "unknown":
        raise FrontierFailure("allocation", "manifest", "Slurm evidence is incomplete")
    builds = document["builds"]
    if not isinstance(builds, dict) or set(builds) != {"cpu", "gpu"}:
        raise FrontierFailure("build", "manifest", "build evidence is incomplete")
    for label, expected in (("cpu", CPU_BUILD_VARIABLES), ("gpu", GPU_BUILD_VARIABLES)):
        build = builds[label]
        if build.get("status") != "passed" or build.get("variables") != expected:
            raise FrontierFailure("build", "manifest", f"{label} build variables differ")
        for executable in build.get("executables", {}).values():
            if not SHA256_PATTERN.fullmatch(str(executable.get("sha256", ""))):
                raise FrontierFailure("build", "manifest", "executable hash is missing")
    checks = document["checks"]
    if not isinstance(checks, dict) or set(checks) != {
        "gpu_linalg",
        "partial_batch",
        "heat_sn160",
    }:
        raise FrontierFailure("test", "manifest", "check evidence is incomplete")
    if (
        checks["gpu_linalg"].get("status") != "passed"
        or not checks["gpu_linalg"].get("offloaded")
        or not checks["gpu_linalg"].get("data_present")
    ):
        raise FrontierFailure("test", "manifest", "GPU linear-algebra evidence failed")
    if checks["partial_batch"].get("zones") != list(EXPECTED_ZONES):
        raise FrontierFailure("test", "manifest", "partial-batch zones are incomplete")
    if checks["heat_sn160"].get("zones") != list(range(1, 7)):
        raise FrontierFailure("test", "manifest", "heat_sn160 zones are incomplete")
    for inventory_name in ("inputs", "artifact_inventory"):
        inventory = document[inventory_name]
        if not isinstance(inventory, list) or not inventory:
            raise FrontierFailure("test", "manifest", f"{inventory_name} is empty")
        for item in inventory:
            if (
                not isinstance(item, dict)
                or not isinstance(item.get("path"), str)
                or not isinstance(item.get("size"), int)
                or not SHA256_PATTERN.fullmatch(str(item.get("sha256", "")))
            ):
                raise FrontierFailure("test", "manifest", f"invalid {inventory_name} item")


def parse_arguments(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    run = subparsers.add_parser("run", help="build and run inside the Frontier allocation")
    run.add_argument("--source-root", type=Path, required=True)
    run.add_argument("--artifact-root", type=Path, required=True)
    run.add_argument("--source-sha", required=True)
    run.add_argument("--archive-sha256", required=True)
    run.add_argument("--build-jobs", type=int, default=8)
    validate = subparsers.add_parser("validate", help="validate a retained manifest")
    validate.add_argument("manifest", type=Path)
    validate.add_argument("--allow-failure", action="store_true")
    failure = subparsers.add_parser("failure", help="record a pre-run allocation failure")
    failure.add_argument("--artifact-root", type=Path, required=True)
    failure.add_argument("--source-sha", required=True)
    failure.add_argument("--archive-sha256", required=True)
    failure.add_argument("--category", required=True)
    failure.add_argument("--phase", required=True)
    failure.add_argument("--message", required=True)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    try:
        if arguments.command == "run":
            report_path = run_qualification(arguments)
            report = json.loads(report_path.read_text(encoding="utf-8"))
            validate_manifest(report, require_pass=False)
            if report["status"] != "passed":
                failure = report["failure"]
                print(
                    f"Frontier qualification failed [{failure['category']}/"
                    f"{failure['phase']}]: {failure['message']}; manifest: {report_path}",
                    file=sys.stderr,
                )
                return 1
            validate_manifest(report)
            print(f"Frontier qualification passed; manifest: {report_path}")
            return 0
        if arguments.command == "failure":
            report_path = write_failure_manifest(arguments)
            report = json.loads(report_path.read_text(encoding="utf-8"))
            validate_manifest(report, require_pass=False)
            print(f"Frontier qualification failure manifest: {report_path}")
            return 0
        report = json.loads(arguments.manifest.read_text(encoding="utf-8"))
        validate_manifest(report, require_pass=not arguments.allow_failure)
    except (FrontierFailure, OSError, UnicodeError, json.JSONDecodeError) as error:
        print(f"Frontier qualification validation failed: {error}", file=sys.stderr)
        return 1
    print("Frontier qualification manifest is valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
