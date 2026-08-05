"""Execution and comparison helpers for XNet regression tests."""

from __future__ import annotations

from dataclasses import dataclass
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
from typing import Mapping, Sequence


ALPHA_SPECIES = (
    "he4",
    "c12",
    "o16",
    "ne20",
    "mg24",
    "si28",
    "s32",
    "ar36",
    "ca40",
    "ti44",
    "cr48",
    "fe52",
    "ni56",
    "zn60",
)

TORCH47_SPECIES = (
    "n",
    "p",
    "d",
    "t",
    "he3",
    "he4",
    "li7",
    "be7",
    "b8",
    "c12",
    "c13",
    "n13",
    "n14",
    "n15",
    "o14",
    "o15",
    "o16",
    "o17",
    "o18",
    "f17",
    "f18",
    "f19",
    "ne18",
    "ne19",
    "ne20",
    "na23",
    "mg23",
    "mg24",
    "al27",
    "si27",
    "si28",
    "p30",
    "p31",
    "s31",
    "s32",
    "cl35",
    "ar36",
    "k39",
    "ca40",
    "sc43",
    "ti44",
    "v47",
    "cr48",
    "mn51",
    "fe52",
    "co55",
    "ni56",
)

# These established products remain comparison anchors for continuity even
# when one falls below the general material endpoint threshold.
SILICON_BURNING_COMPARISON_SPECIES = (
    "si28",
    "s32",
    "ar36",
    "ca40",
    "ti44",
    "cr48",
    "fe52",
    "ni56",
)
MATERIAL_MASS_FRACTION_THRESHOLD = 1.0e-4


def comparison_species_for_zone(
    expected_species: Sequence[str],
    mass_fractions: Mapping[str, float],
) -> tuple[str, ...]:
    """Select retained anchors plus this zone's material endpoint abundances."""

    shared_anchors = tuple(
        species
        for species in SILICON_BURNING_COMPARISON_SPECIES
        if species in expected_species
    )
    material_products = tuple(
        species
        for species in expected_species
        if mass_fractions[species] >= MATERIAL_MASS_FRACTION_THRESHOLD
        and species not in shared_anchors
    )
    return shared_anchors + material_products


FLOAT_TOKEN = r"[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[EeDd][+-]?\d+)?"
END_RECORD = re.compile(
    rf"^End\s+(\d+)\s+(\d+)\s+({FLOAT_TOKEN})\s+({FLOAT_TOKEN})\s+"
    rf"({FLOAT_TOKEN})\s+({FLOAT_TOKEN})\s+({FLOAT_TOKEN})\s*$"
)
ABUNDANCE_PAIR = re.compile(rf"([A-Za-z][A-Za-z0-9]*)\s+({FLOAT_TOKEN})")
TIMER_HEADING = re.compile(r"^Timers Summary:\s*$")
TIMER_ROW = re.compile(rf"^\s+[A-Za-z][A-Za-z0-9_/-]*\s+{FLOAT_TOKEN}\s*$")
NONFINITE_TOKEN = re.compile(
    r"(?i)(?<![A-Za-z0-9_])[+-]?(?:nan|inf(?:inity)?)(?![A-Za-z0-9_])"
)


class RegressionFailure(RuntimeError):
    """Base class for a classified regression failure."""


class SetupFailure(RegressionFailure):
    """The executable, case definition, inputs, or work directory is invalid."""


class ExecutionFailure(RegressionFailure):
    """XNet did not complete and create all required output."""


class ParsingFailure(RegressionFailure):
    """A required diagnostic record is absent or malformed."""


class ComparisonFailure(RegressionFailure):
    """Parsed output disagrees with the characterization reference."""


@dataclass(frozen=True)
class RegressionCase:
    name: str
    control: Path
    network_data: Path
    trajectories: tuple[Path, ...]
    helm_table: Path
    reference: Path
    expected_zones: tuple[int, ...]
    expected_species: tuple[str, ...]
    network_inputs: tuple[str, ...]

    @property
    def required_outputs(self) -> tuple[str, ...]:
        zone_width = len(str(max(self.expected_zones)))
        zone_outputs = tuple(
            filename
            for zone in self.expected_zones
            for filename in (
                f"ev_{self.name}_{zone:0{zone_width}d}",
                f"ts_{self.name}_{zone:0{zone_width}d}",
            )
        )
        return ("net_diag01", *zone_outputs)


@dataclass(frozen=True)
class ProcessResult:
    executable: Path
    work_directory: Path
    return_code: int
    stdout: str
    stderr: str


@dataclass(frozen=True)
class FinalState:
    zone: int
    step: int
    target_time: float
    time: float
    temperature_gk: float
    density: float
    electron_fraction: float
    mass_fractions: Mapping[str, float]


@dataclass(frozen=True)
class Tolerance:
    value: float
    atol: float
    rtol: float


@dataclass(frozen=True)
class ToleranceBounds:
    """Absolute and relative bounds without a duplicated expected value."""

    atol: float
    rtol: float


@dataclass(frozen=True)
class CharacterizationReference:
    """Complete expected final state plus selected pass/fail tolerances."""

    expected_zones: tuple[int, ...]
    final_steps: Mapping[int, int]
    fields: Mapping[int, Mapping[str, Tolerance]]
    # The complete vector supplies expected values and norm diagnostics.
    mass_fractions: Mapping[int, Mapping[str, float]]
    # This subset selects species for field-aware pass/fail comparison.
    mass_fraction_tolerances: Mapping[int, Mapping[str, ToleranceBounds]]
    mass_fraction_sum_atols: Mapping[int, float]


@dataclass(frozen=True)
class CompositionNorms:
    zone: int
    l1: float
    l2: float
    linf: float
    linf_species: str | None


def tnsn_alpha_case(repository_root: Path) -> RegressionCase:
    case_directory = repository_root / "test" / "regression" / "cases" / "tnsn_alpha"
    return RegressionCase(
        name="tnsn_alpha",
        control=case_directory / "control",
        network_data=repository_root / "test" / "Data_alpha",
        trajectories=(
            repository_root / "test" / "Test_Problems" / "th_sn1aflame",
        ),
        helm_table=(
            repository_root / "tools" / "starkiller-helmholtz" / "helm_table.dat"
        ),
        reference=case_directory / "reference" / "final_state.json",
        expected_zones=tuple(range(1, 11)),
        expected_species=ALPHA_SPECIES,
        network_inputs=("sunet", "netsu", "netweak", "netwinv", "ab_co"),
    )


def heat_alpha_case(repository_root: Path) -> RegressionCase:
    case_directory = (
        repository_root / "test" / "regression" / "cases" / "heat_alpha"
    )
    return RegressionCase(
        name="heat_alpha",
        control=case_directory / "control",
        network_data=repository_root / "test" / "Data_alpha",
        trajectories=tuple(
            repository_root / "test" / "Test_Problems" / f"th_co_burn_{zone}"
            for zone in range(1, 7)
        ),
        helm_table=(
            repository_root / "tools" / "starkiller-helmholtz" / "helm_table.dat"
        ),
        reference=case_directory / "reference" / "final_state.json",
        expected_zones=tuple(range(1, 7)),
        expected_species=ALPHA_SPECIES,
        network_inputs=("sunet", "netsu", "netweak", "netwinv", "ab_co"),
    )


def tnsn_torch47_case(repository_root: Path) -> RegressionCase:
    case_directory = (
        repository_root / "test" / "regression" / "cases" / "tnsn_torch47"
    )
    return RegressionCase(
        name="tnsn_torch47",
        control=case_directory / "control",
        network_data=repository_root / "test" / "Data_torch47",
        trajectories=(
            repository_root / "test" / "Test_Problems" / "th_sn1aflame",
        ),
        helm_table=(
            repository_root / "tools" / "starkiller-helmholtz" / "helm_table.dat"
        ),
        reference=case_directory / "reference" / "final_state.json",
        expected_zones=(1,),
        expected_species=TORCH47_SPECIES,
        network_inputs=("sunet", "netsu", "netweak", "netwinv", "ab_co"),
    )


def validate_executable(executable: Path) -> Path:
    executable = executable.expanduser().resolve()
    if not executable.exists():
        raise SetupFailure(f"XNet executable does not exist: {executable}")
    if not executable.is_file():
        raise SetupFailure(f"XNet executable is not a regular file: {executable}")
    if not os.access(executable, os.X_OK):
        raise SetupFailure(f"XNet executable is not executable: {executable}")
    return executable


def _validate_case_inputs(case: RegressionCase) -> None:
    required = {
        "complete control input": case.control,
        "network data directory": case.network_data,
        "Helmholtz EOS table": case.helm_table,
        "characterization reference": case.reference,
    }
    required.update(
        {
            f"thermodynamic trajectory {index}": path
            for index, path in enumerate(case.trajectories, start=1)
        }
    )
    missing = [
        f"{description}: {path}"
        for description, path in required.items()
        if not path.exists()
    ]
    if missing:
        raise SetupFailure("required case input is missing:\n  " + "\n  ".join(missing))
    if not case.network_data.is_dir():
        raise SetupFailure(f"network data path is not a directory: {case.network_data}")
    if not case.expected_zones or len(set(case.expected_zones)) != len(case.expected_zones):
        raise SetupFailure(f"invalid expected zone definition for {case.name}")
    if not case.expected_species or len(set(case.expected_species)) != len(
        case.expected_species
    ):
        raise SetupFailure(f"invalid expected species definition for {case.name}")
    trajectory_names = tuple(path.name for path in case.trajectories)
    if not case.trajectories or len(set(trajectory_names)) != len(trajectory_names):
        raise SetupFailure(
            f"invalid thermodynamic trajectory definition for {case.name}"
        )
    if (
        not case.network_inputs
        or len(set(case.network_inputs)) != len(case.network_inputs)
        or any(Path(filename).name != filename for filename in case.network_inputs)
    ):
        raise SetupFailure(f"invalid network input definition for {case.name}")
    missing_network_inputs = [
        case.network_data / filename
        for filename in case.network_inputs
        if not (case.network_data / filename).is_file()
    ]
    if missing_network_inputs:
        raise SetupFailure(
            "required network source input is missing:\n  "
            + "\n  ".join(str(path) for path in missing_network_inputs)
        )


def prepare_work_directory(case: RegressionCase, work_directory: Path) -> Path:
    """Create one empty isolated XNet working directory."""

    _validate_case_inputs(case)
    work_directory = work_directory.resolve()
    try:
        if work_directory.exists():
            if not work_directory.is_dir():
                raise SetupFailure(f"work path is not a directory: {work_directory}")
            if any(work_directory.iterdir()):
                raise SetupFailure(
                    f"work directory is not empty; refusing stale artifacts: {work_directory}"
                )
        else:
            work_directory.mkdir(parents=True)

        shutil.copy2(case.control, work_directory / "control")
        local_network_data = work_directory / case.network_data.name
        local_network_data.mkdir()
        for filename in case.network_inputs:
            (local_network_data / filename).symlink_to(
                (case.network_data / filename).resolve()
            )
        for trajectory in case.trajectories:
            (work_directory / trajectory.name).symlink_to(trajectory.resolve())
        (work_directory / case.helm_table.name).symlink_to(case.helm_table.resolve())
    except RegressionFailure:
        raise
    except OSError as error:
        raise SetupFailure(
            f"could not prepare work directory {work_directory}: {error}"
        ) from error
    return work_directory


def _captured_text(value: str | bytes | None) -> str:
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode(errors="replace")
    return value


def _write_process_artifacts(
    work_directory: Path, stdout: str, stderr: str, status: str
) -> None:
    try:
        (work_directory / "xnet.stdout.txt").write_text(stdout, encoding="utf-8")
        (work_directory / "xnet.stderr.txt").write_text(stderr, encoding="utf-8")
        (work_directory / "xnet.status.txt").write_text(status + "\n", encoding="utf-8")
    except OSError as error:
        raise ExecutionFailure(
            f"could not preserve process artifacts in {work_directory}: {error}"
        ) from error


def run_xnet(
    executable: Path,
    case: RegressionCase,
    work_directory: Path,
    *,
    timeout_seconds: float,
) -> ProcessResult:
    """Run XNet once and require fresh output from the isolated directory."""

    executable = validate_executable(executable)
    if timeout_seconds <= 0 or not math.isfinite(timeout_seconds):
        raise SetupFailure(f"timeout must be a positive finite value: {timeout_seconds}")

    try:
        completed = subprocess.run(
            [str(executable)],
            cwd=work_directory,
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        stdout = _captured_text(error.stdout)
        stderr = _captured_text(error.stderr)
        _write_process_artifacts(work_directory, stdout, stderr, "timeout")
        raise ExecutionFailure(
            f"XNet timed out after {timeout_seconds:g} seconds; "
            f"artifacts: {work_directory}"
        ) from error
    except OSError as error:
        _write_process_artifacts(work_directory, "", str(error), "launch-error")
        raise ExecutionFailure(
            f"could not launch XNet executable {executable}: {error}; "
            f"artifacts: {work_directory}"
        ) from error

    _write_process_artifacts(
        work_directory,
        completed.stdout,
        completed.stderr,
        f"return_code={completed.returncode}",
    )
    if completed.returncode < 0:
        raise ExecutionFailure(
            f"XNet was terminated by signal {-completed.returncode}; "
            f"artifacts: {work_directory}"
        )
    if completed.returncode != 0:
        raise ExecutionFailure(
            f"XNet returned nonzero status {completed.returncode}; "
            f"artifacts: {work_directory}"
        )

    missing = [
        filename
        for filename in case.required_outputs
        if not (work_directory / filename).is_file()
        or (work_directory / filename).stat().st_size == 0
    ]
    if missing:
        raise ExecutionFailure(
            "XNet returned zero but required fresh output is missing or empty: "
            f"{', '.join(missing)}; artifacts: {work_directory}"
        )

    return ProcessResult(
        executable=executable,
        work_directory=work_directory,
        return_code=completed.returncode,
        stdout=completed.stdout,
        stderr=completed.stderr,
    )


def strip_timer_sections(text: str) -> tuple[str, int]:
    """Remove only delimited timer headings and timer name/value rows."""

    lines = text.splitlines()
    retained: list[str] = []
    timer_count = 0
    index = 0
    while index < len(lines):
        if not TIMER_HEADING.match(lines[index]):
            retained.append(lines[index])
            index += 1
            continue

        timer_count += 1
        index += 1
        timer_rows = 0
        while index < len(lines) and TIMER_ROW.match(lines[index]):
            timer_rows += 1
            index += 1
        if timer_rows == 0:
            raise ParsingFailure(
                f"timer section {timer_count} contains no recognized timer rows"
            )
    return "\n".join(retained), timer_count


def _as_finite_float(token: str, context: str) -> float:
    try:
        value = float(token.replace("D", "E").replace("d", "e"))
    except ValueError as error:
        raise ParsingFailure(f"malformed numerical token for {context}: {token}") from error
    if not math.isfinite(value):
        raise ParsingFailure(f"non-finite numerical value for {context}: {token}")
    return value


def parse_diagnostic(
    text: str,
    expected_zones: Sequence[int],
    expected_species: Sequence[str],
) -> tuple[FinalState, ...]:
    """Parse complete final-state records while deliberately excluding timers."""

    if NONFINITE_TOKEN.search(text):
        token = NONFINITE_TOKEN.search(text)
        assert token is not None
        raise ParsingFailure(f"diagnostic contains non-finite token: {token.group(0)}")

    normalized, timer_count = strip_timer_sections(text)
    expected_zones = tuple(expected_zones)
    expected_species = tuple(expected_species)
    if not expected_species or len(set(expected_species)) != len(expected_species):
        raise ParsingFailure("expected species definition is empty or contains duplicates")
    if timer_count != len(expected_zones):
        raise ParsingFailure(
            f"expected {len(expected_zones)} timer sections, found {timer_count}"
        )

    lines = normalized.splitlines()
    states: dict[int, FinalState] = {}
    index = 0
    while index < len(lines):
        if not lines[index].startswith("End"):
            index += 1
            continue

        match = END_RECORD.match(lines[index])
        if match is None:
            raise ParsingFailure(f"malformed End record: {lines[index]}")
        zone = int(match.group(1))
        step = int(match.group(2))
        if zone in states:
            raise ParsingFailure(f"duplicate End record for zone {zone}")

        values = [
            _as_finite_float(token, f"zone {zone} End record")
            for token in match.groups()[2:]
        ]
        index += 1
        mass_fractions: dict[str, float] = {}
        while len(mass_fractions) < len(expected_species):
            if index >= len(lines) or lines[index].startswith("Counters:"):
                raise ParsingFailure(
                    f"incomplete abundance record for zone {zone}: "
                    f"found {len(mass_fractions)} of {len(expected_species)} species"
                )
            pairs = ABUNDANCE_PAIR.findall(lines[index])
            if not pairs:
                raise ParsingFailure(
                    f"malformed abundance row for zone {zone}: {lines[index]}"
                )
            if ABUNDANCE_PAIR.sub("", lines[index]).strip():
                raise ParsingFailure(
                    f"unexpected content in abundance row for zone {zone}: {lines[index]}"
                )
            for species, token in pairs:
                species = species.lower()
                if species in mass_fractions:
                    raise ParsingFailure(
                        f"duplicate abundance for species {species} in zone {zone}"
                    )
                mass_fractions[species] = _as_finite_float(
                    token, f"zone {zone} species {species}"
                )
            index += 1

        if tuple(mass_fractions) != expected_species:
            raise ParsingFailure(
                f"unexpected species structure for zone {zone}: "
                f"{', '.join(mass_fractions)}"
            )
        if index >= len(lines) or not lines[index].startswith("Counters:"):
            raise ParsingFailure(f"missing Counters record after zone {zone} final state")
        index += 1
        if index >= len(lines):
            raise ParsingFailure(f"missing counter values for zone {zone}")
        counters = lines[index].split()
        if len(counters) != 6 or not all(token.isdigit() for token in counters):
            raise ParsingFailure(f"malformed counter values for zone {zone}: {lines[index]}")
        if int(counters[0]) != zone or int(counters[1]) != step:
            raise ParsingFailure(
                f"zone {zone} counter record does not match its End record: {lines[index]}"
            )

        states[zone] = FinalState(
            zone=zone,
            step=step,
            target_time=values[0],
            time=values[1],
            temperature_gk=values[2],
            density=values[3],
            electron_fraction=values[4],
            mass_fractions=mass_fractions,
        )
        index += 1

    actual_zones = tuple(states)
    if actual_zones != expected_zones:
        raise ParsingFailure(
            f"expected ordered final records for zones {expected_zones}, found {actual_zones}"
        )
    return tuple(states[zone] for zone in expected_zones)


def _expand_zone_items(
    item: object, expected_zones: Sequence[int], context: str
) -> Mapping[int, object]:
    if not isinstance(item, dict):
        return {zone: item for zone in expected_zones}

    values: dict[int, object] = {}
    for key, value in item.items():
        if not isinstance(key, str) or not key.isdigit():
            raise SetupFailure(
                f"reference entry {context} has a non-zone key: {key!r}"
            )
        zone = int(key)
        if str(zone) != key or zone in values:
            raise SetupFailure(
                f"reference entry {context} has an invalid zone key: {key!r}"
            )
        values[zone] = value
    expected = set(expected_zones)
    if set(values) != expected:
        raise SetupFailure(
            f"reference entry {context} must define zones {sorted(expected)}; "
            f"found {sorted(values)}"
        )
    return values


def _load_zone_floats(
    item: object, expected_zones: Sequence[int], context: str
) -> Mapping[int, float]:
    values = _expand_zone_items(item, expected_zones, context)
    if not all(
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value)
        for value in values.values()
    ):
        raise SetupFailure(f"reference entry {context} contains a non-finite value")
    return {zone: float(value) for zone, value in values.items()}


def _load_zone_integers(
    item: object, expected_zones: Sequence[int], context: str
) -> Mapping[int, int]:
    values = _expand_zone_items(item, expected_zones, context)
    if not all(
        isinstance(value, int) and not isinstance(value, bool) and value >= 0
        for value in values.values()
    ):
        raise SetupFailure(
            f"reference entry {context} must contain nonnegative integers"
        )
    return {zone: int(value) for zone, value in values.items()}


def _load_tolerance(
    item: object, expected_zones: Sequence[int], context: str
) -> Mapping[int, Tolerance]:
    if not isinstance(item, dict) or set(item) != {"value", "atol", "rtol"}:
        raise SetupFailure(
            f"reference entry {context} must contain exactly value, atol, and rtol"
        )
    values = _load_zone_floats(item["value"], expected_zones, f"{context}.value")
    atols = _load_zone_floats(item["atol"], expected_zones, f"{context}.atol")
    rtols = _load_zone_floats(item["rtol"], expected_zones, f"{context}.rtol")
    if any(value < 0 for value in (*atols.values(), *rtols.values())):
        raise SetupFailure(f"reference entry {context} contains a negative tolerance")
    return {
        zone: Tolerance(values[zone], atols[zone], rtols[zone])
        for zone in expected_zones
    }


def _load_tolerance_bounds(
    item: object, expected_zones: Sequence[int], context: str
) -> Mapping[int, ToleranceBounds]:
    if not isinstance(item, dict) or set(item) != {"atol", "rtol"}:
        raise SetupFailure(
            f"reference entry {context} must contain exactly atol and rtol"
        )
    atols = _load_zone_floats(item["atol"], expected_zones, f"{context}.atol")
    rtols = _load_zone_floats(item["rtol"], expected_zones, f"{context}.rtol")
    if any(value < 0 for value in (*atols.values(), *rtols.values())):
        raise SetupFailure(f"reference entry {context} contains a negative tolerance")
    return {
        zone: ToleranceBounds(atols[zone], rtols[zone])
        for zone in expected_zones
    }


def _load_composition_selection(
    item: object, expected_zones: Sequence[int]
) -> Mapping[int, tuple[str, ...]]:
    context = "mass_fraction_selection"
    if not isinstance(item, dict):
        raise SetupFailure(f"reference entry {context} must be a zone mapping")
    zone_items: dict[int, object] = {}
    for key, value in item.items():
        if not isinstance(key, str) or not key.isdigit():
            raise SetupFailure(
                f"reference entry {context} has a non-zone key: {key!r}"
            )
        zone = int(key)
        if str(zone) != key:
            raise SetupFailure(
                f"reference entry {context} has an invalid zone key: {key!r}"
            )
        zone_items[zone] = value
    expected = set(expected_zones)
    actual = set(zone_items)
    missing_zones = sorted(expected.difference(actual))
    unknown_zones = sorted(actual.difference(expected))
    if missing_zones or unknown_zones:
        raise SetupFailure(
            f"reference entry {context} must define exactly zones {sorted(expected)}; "
            f"missing {missing_zones}; unknown {unknown_zones}"
        )
    selections: dict[int, tuple[str, ...]] = {}
    for zone, value in zone_items.items():
        if not isinstance(value, list) or not value:
            raise SetupFailure(
                f"reference entry {context}.{zone} must be a nonempty species list"
            )
        if not all(isinstance(species, str) and species for species in value):
            raise SetupFailure(
                f"reference entry {context}.{zone} contains an invalid species"
            )
        duplicates = sorted(
            species for species in set(value) if value.count(species) > 1
        )
        if duplicates:
            raise SetupFailure(
                f"reference entry {context}.{zone} contains duplicate species: "
                + ", ".join(duplicates)
            )
        selections[zone] = tuple(value)
    return selections


def _unique_json_object(pairs: Sequence[tuple[str, object]]) -> dict[str, object]:
    document: dict[str, object] = {}
    for key, value in pairs:
        if key in document:
            raise ValueError(f"duplicate JSON object key: {key}")
        document[key] = value
    return document


def load_reference(path: Path) -> CharacterizationReference:
    try:
        document = json.loads(
            path.read_text(encoding="utf-8"), object_pairs_hook=_unique_json_object
        )
    except OSError as error:
        raise SetupFailure(f"could not read characterization reference {path}: {error}") from error
    except json.JSONDecodeError as error:
        raise SetupFailure(f"malformed characterization reference {path}: {error}") from error
    except ValueError as error:
        raise SetupFailure(f"invalid characterization reference {path}: {error}") from error

    try:
        zone_items = document["expected_zones"]
        if not isinstance(zone_items, list) or not all(
            isinstance(zone, int) and not isinstance(zone, bool)
            for zone in zone_items
        ):
            raise ValueError("expected_zones must be a list of integers")
        expected_zones = tuple(zone_items)
        if not expected_zones or len(set(expected_zones)) != len(expected_zones):
            raise ValueError("expected_zones is empty or contains duplicates")
        final_steps = _load_zone_integers(
            document["final_step"], expected_zones, "final_step"
        )
        fields_by_name = {
            name: _load_tolerance(item, expected_zones, f"fields.{name}")
            for name, item in document["fields"].items()
        }
        mass_fractions_by_species = {
            name: _load_zone_floats(
                value, expected_zones, f"mass_fractions.{name}"
            )
            for name, value in document["mass_fractions"].items()
        }
        mass_fraction_selection = _load_composition_selection(
            document["mass_fraction_selection"], expected_zones
        )
        mass_fraction_tolerances_by_species = {
            name: _load_tolerance_bounds(
                item, expected_zones, f"mass_fraction_tolerances.{name}"
            )
            for name, item in document["mass_fraction_tolerances"].items()
        }
        mass_fraction_sum_atols = _load_zone_floats(
            document["mass_fraction_sum_atol"],
            expected_zones,
            "mass_fraction_sum_atol",
        )
    except (AttributeError, KeyError, TypeError, ValueError) as error:
        raise SetupFailure(f"invalid characterization reference structure in {path}: {error}") from error

    fields = {
        zone: {name: policies[zone] for name, policies in fields_by_name.items()}
        for zone in expected_zones
    }
    mass_fractions = {
        zone: {
            species: values[zone]
            for species, values in mass_fractions_by_species.items()
        }
        for zone in expected_zones
    }
    required_fields = {
        "target_time",
        "temperature_gk",
        "density",
        "electron_fraction",
    }
    if set(fields_by_name) != required_fields:
        raise SetupFailure(
            "reference fields must be exactly "
            f"{sorted(required_fields)}; found {sorted(fields_by_name)}"
        )
    if not mass_fractions_by_species or not all(
        isinstance(species, str) and species
        for species in mass_fractions_by_species
    ):
        raise SetupFailure("reference composition is empty or invalid")
    if not mass_fraction_tolerances_by_species:
        raise SetupFailure("reference mass-fraction tolerance selection is empty")
    unknown_tolerance_species = set(mass_fraction_tolerances_by_species).difference(
        mass_fractions_by_species
    )
    if unknown_tolerance_species:
        raise SetupFailure(
            "reference mass-fraction tolerances have no matching composition value: "
            + ", ".join(sorted(unknown_tolerance_species))
        )
    selected_species = {
        species
        for zone_selection in mass_fraction_selection.values()
        for species in zone_selection
    }
    unknown_selected_species = selected_species.difference(mass_fractions_by_species)
    if unknown_selected_species:
        raise SetupFailure(
            "reference mass-fraction selection has no matching composition value: "
            + ", ".join(sorted(unknown_selected_species))
        )
    missing_tolerances = selected_species.difference(
        mass_fraction_tolerances_by_species
    )
    if missing_tolerances:
        raise SetupFailure(
            "reference mass-fraction selection has no matching tolerance: "
            + ", ".join(sorted(missing_tolerances))
        )
    unused_tolerances = set(mass_fraction_tolerances_by_species).difference(
        selected_species
    )
    if unused_tolerances:
        raise SetupFailure(
            "reference mass-fraction tolerances are not selected in any zone: "
            + ", ".join(sorted(unused_tolerances))
        )
    mass_fraction_tolerances = {
        zone: {
            species: mass_fraction_tolerances_by_species[species][zone]
            for species in mass_fraction_selection[zone]
        }
        for zone in expected_zones
    }
    if any(value < 0 for value in mass_fraction_sum_atols.values()):
        raise SetupFailure("reference mass_fraction_sum_atol must be finite and nonnegative")
    return CharacterizationReference(
        expected_zones=expected_zones,
        final_steps=final_steps,
        fields=fields,
        mass_fractions=mass_fractions,
        mass_fraction_tolerances=mass_fraction_tolerances,
        mass_fraction_sum_atols=mass_fraction_sum_atols,
    )


def validate_reference_for_case(
    case: RegressionCase, reference: CharacterizationReference
) -> None:
    """Require one reference to match its case and the shared selection policy."""

    if reference.expected_zones != case.expected_zones:
        raise SetupFailure(
            "reference expected_zones does not match the case definition: "
            f"{reference.expected_zones} != {case.expected_zones}"
        )
    for zone in case.expected_zones:
        if tuple(reference.mass_fractions[zone]) != case.expected_species:
            raise SetupFailure(
                "composition reference does not match the case species for "
                f"zone {zone}: {tuple(reference.mass_fractions[zone])} "
                f"!= {case.expected_species}"
            )
    for zone in case.expected_zones:
        comparison_species = comparison_species_for_zone(
            case.expected_species, reference.mass_fractions[zone]
        )
        selected_species = tuple(reference.mass_fraction_tolerances[zone])
        if selected_species != comparison_species:
            raise SetupFailure(
                "reference pass/fail species do not match the per-zone "
                f"composition policy for zone {zone}: "
                f"{selected_species} != {comparison_species}"
            )


def _difference(actual: float, reference: Tolerance) -> tuple[bool, float, float]:
    absolute_difference = abs(actual - reference.value)
    allowed = reference.atol + reference.rtol * abs(reference.value)
    return absolute_difference <= allowed, absolute_difference, allowed


def calculate_composition_norms(
    states: Sequence[FinalState], reference: CharacterizationReference
) -> tuple[CompositionNorms, ...]:
    """Calculate diagnostic-only norms over the complete composition vector."""

    diagnostics: list[CompositionNorms] = []
    for state in states:
        expected_mass_fractions = reference.mass_fractions[state.zone]
        differences = {
            species: abs(state.mass_fractions[species] - expected)
            for species, expected in expected_mass_fractions.items()
        }
        maximum_species = max(differences, key=differences.__getitem__)
        linf = differences[maximum_species]
        diagnostics.append(
            CompositionNorms(
                zone=state.zone,
                l1=math.fsum(differences.values()),
                l2=math.sqrt(math.fsum(value * value for value in differences.values())),
                linf=linf,
                linf_species=maximum_species if linf > 0.0 else None,
            )
        )
    return tuple(diagnostics)


def _write_composition_diagnostics(
    work_directory: Path, diagnostics: Sequence[CompositionNorms]
) -> None:
    document = {
        "status": "diagnostic-only; these norms do not determine pass/fail",
        "vector": "absolute mass-fraction errors for every species in the case",
        "zones": [
            {
                "zone": item.zone,
                "l1": item.l1,
                "l2": item.l2,
                "linf": item.linf,
                "linf_species": item.linf_species,
            }
            for item in diagnostics
        ],
    }
    path = work_directory / "composition_error_norms.json"
    try:
        path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
    except OSError as error:
        raise ExecutionFailure(
            f"could not preserve composition diagnostics in {path}: {error}"
        ) from error


def compare_final_states(
    states: Sequence[FinalState], reference: CharacterizationReference
) -> None:
    failures: list[str] = []
    zones = tuple(state.zone for state in states)
    if zones != reference.expected_zones:
        failures.append(f"zone records {zones} != expected {reference.expected_zones}")

    for state in states:
        if state.zone not in reference.fields:
            failures.append(f"zone {state.zone} has no characterization reference")
            continue

        field_policies = reference.fields[state.zone]
        target_policy = field_policies["target_time"]
        completion_policy = Tolerance(
            state.target_time, target_policy.atol, target_policy.rtol
        )
        completed, difference, allowed = _difference(state.time, completion_policy)
        if not completed:
            failures.append(
                f"zone {state.zone} achieved time {state.time:.9e} did not reach "
                f"target time {state.target_time:.9e}: |difference|={difference:.3e}, "
                f"allowed={allowed:.3e}"
            )

        for field, policy in field_policies.items():
            actual = getattr(state, field)
            passed, difference, allowed = _difference(actual, policy)
            if not passed:
                failures.append(
                    f"zone {state.zone} {field}: actual={actual:.9e}, "
                    f"reference={policy.value:.9e}, |difference|={difference:.3e}, "
                    f"allowed={allowed:.3e} (atol={policy.atol:.3e}, "
                    f"rtol={policy.rtol:.3e})"
                )

        expected_mass_fractions = reference.mass_fractions[state.zone]
        for species, bounds in reference.mass_fraction_tolerances[state.zone].items():
            actual = state.mass_fractions[species]
            policy = Tolerance(
                expected_mass_fractions[species], bounds.atol, bounds.rtol
            )
            passed, difference, allowed = _difference(actual, policy)
            if not passed:
                failures.append(
                    f"zone {state.zone} {species} mass fraction: actual={actual:.9e}, "
                    f"reference={policy.value:.9e}, |difference|={difference:.3e}, "
                    f"allowed={allowed:.3e} (atol={policy.atol:.3e}, "
                    f"rtol={policy.rtol:.3e})"
                )

        negative_species = [
            species for species, value in state.mass_fractions.items() if value < 0
        ]
        if negative_species:
            failures.append(
                f"zone {state.zone} has negative mass fractions: {', '.join(negative_species)}"
            )
        mass_fraction_sum = sum(state.mass_fractions.values())
        sum_atol = reference.mass_fraction_sum_atols[state.zone]
        if abs(mass_fraction_sum - 1.0) > sum_atol:
            failures.append(
                f"zone {state.zone} mass-fraction sum={mass_fraction_sum:.12e}; "
                f"allowed |sum - 1| <= {sum_atol:.3e}"
            )

    if failures:
        raise ComparisonFailure("numerical characterization failed:\n  " + "\n  ".join(failures))


def run_and_compare(
    executable: Path,
    case: RegressionCase,
    work_directory: Path,
    *,
    timeout_seconds: float,
) -> ProcessResult:
    prepared = prepare_work_directory(case, work_directory)
    result = run_xnet(
        executable,
        case,
        prepared,
        timeout_seconds=timeout_seconds,
    )
    diagnostic_path = prepared / "net_diag01"
    try:
        diagnostic = diagnostic_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise ParsingFailure(
            f"could not read diagnostic {diagnostic_path}: {error}; artifacts: {prepared}"
        ) from error
    try:
        states = parse_diagnostic(
            diagnostic, case.expected_zones, case.expected_species
        )
        reference = load_reference(case.reference)
        validate_reference_for_case(case, reference)
        diagnostics = calculate_composition_norms(states, reference)
        _write_composition_diagnostics(prepared, diagnostics)
        compare_final_states(states, reference)
    except (ParsingFailure, ComparisonFailure) as error:
        raise type(error)(f"{error}; artifacts: {prepared}") from None
    return result
