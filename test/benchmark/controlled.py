"""Controlled-scaling input construction for the XNet benchmark harness.

The controlled family deliberately generates only the small run-control files.
Network payloads, the EOS table, and the numerical comparator remain supplied
by the separately identified input bundle.  Every generated file is retained
in the portable benchmark record.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
import math
from pathlib import Path
import shutil
from typing import Any

from benchmark import BenchmarkError


NETWORK_INPUTS = ("sunet", "netsu", "netweak", "netwinv")


@dataclass(frozen=True)
class ControlledRun:
    """Explicit workload dimensions that may vary independently of a case."""

    zones: int
    batch_size: int
    self_heating: bool

    def as_record(self) -> dict[str, object]:
        return {
            "zones": self.zones,
            "batch_size": self.batch_size,
            "partial_final_batch": self.zones % self.batch_size != 0,
            "self_heating": self.self_heating,
            "weak_reactions": True,
            "screening": True,
            "integrator": "backward-euler",
            "end_time_seconds": 10.0,
        }


def is_controlled(case: Any) -> bool:
    return case.workload.get("family") == "controlled-scaling"


def validate_dimensions(
    zones: int | None,
    batch_size: int | None,
    self_heating: bool,
) -> ControlledRun:
    if not isinstance(zones, int) or zones < 1:
        raise BenchmarkError("controlled cases require positive --zones")
    if not isinstance(batch_size, int) or batch_size < 1:
        raise BenchmarkError("controlled cases require positive --batch-size")
    if batch_size > zones:
        raise BenchmarkError("--batch-size cannot exceed --zones")
    return ControlledRun(zones, batch_size, self_heating)


def validate_case_dimensions(
    case: Any,
    zones: int | None,
    batch_size: int | None,
    self_heating: bool,
) -> ControlledRun:
    run = validate_dimensions(zones, batch_size, self_heating)
    if self_heating:
        allowed = (
            case.workload.get("specification_definition", {})
            .get("matrix_dimensions", {})
            .get("self_heating_networks", [])
        )
        if case.network.get("id") not in allowed:
            raise BenchmarkError(
                "self-heating sensitivity is limited to the selected larger networks"
            )
    return run


def run_from_record(value: object, case: Any | None = None) -> ControlledRun:
    if not isinstance(value, dict):
        raise BenchmarkError("controlled record lacks workload configuration")
    zones = value.get("zones")
    batch_size = value.get("batch_size")
    self_heating = value.get("self_heating")
    if not isinstance(self_heating, bool):
        raise BenchmarkError("controlled record has invalid self-heating selection")
    run = (
        validate_dimensions(zones, batch_size, self_heating)
        if case is None
        else validate_case_dimensions(case, zones, batch_size, self_heating)
    )
    if value != run.as_record():
        raise BenchmarkError("controlled workload configuration is inconsistent")
    return run


def reference_relative_path(case: Any, run: ControlledRun) -> str:
    key = "self_heating_reference" if run.self_heating else "reference"
    value = case.input_identity.get(key)
    if not isinstance(value, str) or not value:
        raise BenchmarkError("controlled case lacks a reference for this workload")
    return value


def read_species(sunet: Path) -> tuple[str, ...]:
    species = tuple(
        line.split()[0].lower()
        for line in sunet.read_text(encoding="utf-8").splitlines()
        if line.strip()
    )
    if not species or len(species) != len(set(species)):
        raise BenchmarkError(f"invalid controlled network species list: {sunet}")
    return species


def abundance_text(species: tuple[str, ...]) -> str:
    required = {"c12", "o16"}
    if not required <= set(species):
        raise BenchmarkError("controlled network lacks C12 or O16")
    rows = ["controlled mass fractions expressed as molar abundances Y=X/A"]
    values = [
        (name, 0.5 / 12.0 if name == "c12" else 0.5 / 16.0 if name == "o16" else 0.0)
        for name in species
    ]
    for start in range(0, len(values), 4):
        rows.append(
            "".join(
                f"{name:>5s} {value:14.7E}"
                for name, value in values[start : start + 4]
            )
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


def control_text(
    case_name: str,
    network_directory: str,
    species: tuple[str, ...],
    run: ControlledRun,
) -> str:
    output_species = species[: min(14, len(species))]
    species_heading = (
        f"{'# Species to output in ASCII output (format 14a5):':<50}"
        f"{len(output_species):4d}"
    )
    species_row = "".join(f"{name:>5s}" for name in output_species)
    return f"""## Problem Description
controlled-scaling fixed C/O workload
10-second approved early plateau; not an equilibrium claim
generated by test/benchmark/controlled.py
## Job Controls
1         Initial Zone
{run.zones}         # of Zones
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
{1 if run.self_heating else 0}         Include self-heating (yes=1,no=0)
1.00E-02  Max. Temperature Change per timestep
1.00E-04  Temperature Convergence Criterion
## Zone Batching Controls
{run.batch_size}         Blocking size for zone loop

## Output Controls
0         Diagnostic Output Level
0         Per Timestep Output Level
# ASCII output filename root, network will append zone number
ev_{case_name}_
# Binary output filename root, network will append zone number
ts_{case_name}_
{species_heading}
{species_row}
## Input Controls
# Nuclear Data Directory
{network_directory}
# Initial Abundance and Thermodynamic Trajectory Files
controlled_abundance_
controlled_trajectory_
"""


def materialize_inputs(
    directory: Path,
    case: Any,
    bundle_root: Path,
    run: ControlledRun,
) -> tuple[Any, dict[str, object]]:
    """Create retained controls and return a comparator-compatible case."""
    network_data = bundle_root / case.network["path"]
    species = read_species(network_data / "sunet")
    if len(species) != case.network["species_count"]:
        raise BenchmarkError("controlled network species count disagrees with registry")

    directory.mkdir()
    control = directory / "control"
    abundance = directory / "controlled_abundance"
    trajectory = directory / "controlled_trajectory"
    control.write_text(
        control_text(case.case_id, network_data.name, species, run),
        encoding="utf-8",
    )
    abundance.write_text(abundance_text(species), encoding="utf-8")
    trajectory.write_text(trajectory_text(), encoding="utf-8")

    width = len(str(run.zones))
    groups = tuple(
        tuple(range(start, min(start + run.batch_size, run.zones + 1)))
        for start in range(1, run.zones + 1, run.batch_size)
    )
    staged = tuple(
        item
        for zone in range(1, run.zones + 1)
        for item in (
            (abundance, Path(f"controlled_abundance_{zone:0{width}d}")),
            (trajectory, Path(f"controlled_trajectory_{zone:0{width}d}")),
        )
    )
    return species, {
        "control": control,
        "abundance": abundance,
        "trajectory": trajectory,
        "network_data": network_data,
        "helm_table": bundle_root / "tools/starkiller-helmholtz/helm_table.dat",
        "species": species,
        "zones": tuple(range(1, run.zones + 1)),
        "groups": groups,
        "staged": staged,
    }


def make_regression_case(
    regression: Any,
    case: Any,
    inputs: dict[str, object],
    reference: Path,
) -> Any:
    class ControlledRegressionCase(regression.RegressionCase):
        @property
        def required_outputs(self) -> tuple[str, ...]:
            # Per-zone ASCII/binary output is intentionally disabled.  The
            # complete final composition and counters come from diagnostics.
            return ("net_diag01",)

    staged = tuple(
        regression.StagedInput(source, destination)
        for source, destination in inputs["staged"]
    )
    return ControlledRegressionCase(
        name=case.case_id,
        control=inputs["control"],
        network_data=inputs["network_data"],
        trajectories=(),
        helm_table=inputs["helm_table"],
        reference=reference,
        expected_zones=inputs["zones"],
        expected_species=tuple(inputs["species"]),
        network_inputs=NETWORK_INPUTS,
        comparison_schema=regression.COMPARISON_SCHEMA,
        staged_inputs=staged,
        diagnostic_groups=inputs["groups"],
    )


def make_replay_case(
    regression: Any,
    case: Any,
    run: ControlledRun,
    species: tuple[str, ...],
    root: Path,
    reference: Path,
) -> Any:
    width = len(str(run.zones))
    inputs = {
        "control": root / "control",
        "network_data": root / case.network["path"],
        "helm_table": root / "helm_table.dat",
        "zones": tuple(range(1, run.zones + 1)),
        "groups": tuple(
            tuple(range(start, min(start + run.batch_size, run.zones + 1)))
            for start in range(1, run.zones + 1, run.batch_size)
        ),
        "species": species,
        "staged": tuple(
            item
            for zone in range(1, run.zones + 1)
            for item in (
                (
                    root / "controlled_abundance",
                    Path(f"controlled_abundance_{zone:0{width}d}"),
                ),
                (
                    root / "controlled_trajectory",
                    Path(f"controlled_trajectory_{zone:0{width}d}"),
                ),
            )
        ),
    }
    return make_regression_case(regression, case, inputs, reference)


def prepare_work_directory(case: Any, work_directory: Path) -> Path:
    """Stage a legacy ``control`` run without relying on a newer driver helper."""
    work_directory = work_directory.resolve()
    if work_directory.exists() and any(work_directory.iterdir()):
        raise BenchmarkError("controlled work directory is not empty")
    work_directory.mkdir(parents=True, exist_ok=True)
    shutil.copy2(case.control, work_directory / "control")

    staged = [
        regression_input
        for regression_input in case.staged_inputs
    ]
    staged.extend(
        type(case.staged_inputs[0])(
            case.network_data / name,
            Path(case.network_data.name) / name,
        )
        for name in NETWORK_INPUTS
    )
    staged.append(
        type(case.staged_inputs[0])(case.helm_table, Path(case.helm_table.name))
    )
    destinations: set[Path] = set()
    for item in staged:
        destination = item.destination
        if (
            destination.is_absolute()
            or not destination.parts
            or any(part in ("", ".", "..") for part in destination.parts)
            or destination in destinations
        ):
            raise BenchmarkError("invalid controlled staged-input destination")
        destinations.add(destination)
        target = work_directory / destination
        target.parent.mkdir(parents=True, exist_ok=True)
        target.symlink_to(item.source.resolve())
    return work_directory


def validate_retained_inputs(
    directory: Path,
    case: Any,
    run: ControlledRun,
    species: tuple[str, ...],
) -> None:
    expected = {
        "control": control_text(case.case_id, case.network["path"].split("/")[-1], species, run),
        "controlled_abundance": abundance_text(species),
        "controlled_trajectory": trajectory_text(),
    }
    for name, text in expected.items():
        path = directory / name
        try:
            actual = path.read_text(encoding="utf-8")
        except OSError as error:
            raise BenchmarkError(f"missing retained controlled input: {name}") from error
        if actual != text:
            raise BenchmarkError(f"retained controlled input mismatch: {name}")


def expand_uniform_reference(regression: Any, reference: Any, case: Any) -> Any:
    """Expand one retained canonical zone without duplicating its full vector."""
    if reference.expected_zones != (1,):
        raise BenchmarkError("controlled reference must contain one canonical zone")
    zones = tuple(case.expected_zones)

    def repeated(mapping: Any) -> dict[int, Any]:
        return {zone: mapping[1] for zone in zones}

    return replace(
        reference,
        case_name=case.name,
        expected_zones=zones,
        final_steps=repeated(reference.final_steps),
        fields=repeated(reference.fields),
        mass_fractions=repeated(reference.mass_fractions),
        mass_fraction_tolerances=repeated(reference.mass_fraction_tolerances),
        mass_fraction_sum_atols=repeated(reference.mass_fraction_sum_atols),
        mass_fraction_printed_sum_tolerances=(
            None
            if reference.mass_fraction_printed_sum_tolerances is None
            else repeated(reference.mass_fraction_printed_sum_tolerances)
        ),
        composition_norm_limits=(
            None
            if reference.composition_norm_limits is None
            else repeated(reference.composition_norm_limits)
        ),
        solver_counters=(
            None
            if reference.solver_counters is None
            else repeated(reference.solver_counters)
        ),
    )


def expected_record(run: ControlledRun) -> dict[str, object]:
    return {
        "zones": list(range(1, run.zones + 1)),
        "outputs": ["net_diag*"],
        "timer_sections": math.ceil(run.zones / run.batch_size),
    }
