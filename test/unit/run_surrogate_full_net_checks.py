#!/usr/bin/env python3

"""Apply the Fortran surrogate checker to fixed-state production full_net results."""

from __future__ import annotations

import math
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys


class CheckFailure(RuntimeError):
    pass


ALPHA_OUTPUT_SPECIES = (
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
SN231_OUTPUT_SPECIES = (
    "n",
    "p",
    "he4",
    "c12",
    "o16",
    "ne20",
    "ne22",
    "mg24",
    "si28",
    "ca40",
    "fe52",
    "fe54",
    "ni56",
    "zn60",
)
STATUS_KEYS = (
    "overall_status",
    "finite_status",
    "fraction_bounds_status",
    "mass_normalization_status",
    "fixed_ye_status",
    "binding_energy_rate_status",
    "fraction_change_status",
    "energy_change_fraction_status",
)
BASE_STATUS_KEYS = (
    "finite_status",
    "fraction_bounds_status",
    "mass_normalization_status",
    "fixed_ye_status",
    "binding_energy_rate_status",
)
METRIC_KEYS = (
    "maximum_fraction_change",
    "maximum_fraction_change_index",
    "energy_change_fraction",
    "initial_specific_internal_energy",
    "energy_rate",
    "expected_energy_rate",
)
SKIP = 0
PASS = 1
FAIL = 2


def fail(message: str) -> None:
    raise CheckFailure(message)


def mass_number(species_name: str) -> int:
    light_species = {"n": 1, "p": 1, "d": 2, "t": 3}
    if species_name in light_species:
        return light_species[species_name]
    match = re.search(r"([0-9]+)$", species_name)
    if match is None:
        fail(f"cannot determine mass number for {species_name!r}")
    return int(match.group(1))


def write_abundance_file(
    path: Path, species: tuple[str, ...], mass_fractions: list[float], title: str
) -> None:
    if len(species) != len(mass_fractions):
        fail(f"restart abundance length mismatch for {path}")
    entries = [
        f"{name:>5} {mass_fraction / mass_number(name):.17E}"
        for name, mass_fraction in zip(species, mass_fractions)
    ]
    lines = [" ".join(entries[index : index + 4]) for index in range(0, len(entries), 4)]
    path.write_text(title + "\n" + "\n".join(lines) + "\n", encoding="ascii")


def control_text(
    *,
    title: str,
    data_name: str,
    abundance_name: str,
    output_species: tuple[str, ...],
) -> str:
    species_line = "".join(f"{name:>5}" for name in output_species)
    return f"""## Problem Description
{title}
One fixed-thermodynamic-condition zone
Strong reactions only for fixed-Ye validation
## Job Controls
1         Initial Zone
1         # of Zones
0         Include Weak Reactions (yes=1,no=0,only=-1)
0         Include Screening (yes=1)
1         Process Nuclear Data at Run Time (yes=1,no=0)
## Neutrinos
0         Include Neutrino Reactions (yes=1, no=0)
## NSE Initial Conditions
11.0      Temperature in GK to use NSE initial conditions instead of file
## Integration Controls
1         Choice of integration Scheme
6000      Max. number of timesteps before quit
5         Max. iterations per step
4         Rebuild the jacobian every ijac iterations after the first
0         Convergence Condition
1.00E-01  Max. Abundance Change per timestep
1.00E-07  Smallest Abundance used in timestep calculation
1.00E-06  Mass Conservation Limit
1.00E-04  Convergence Criterion
1.00E-30  Lower Abundance limit, smaller abundances = 0
2.00E+00  Max. Factor to change dt in a timestep
## Self-heating Controls
0         Include self-heating
1.00E-02  Max. Temperature Change per timestep
1.00E-04  Temperature Convergence Criterion
## Zone Batching Controls
1         Blocking size for zone loop
## Output Controls
0         Diagnostic Output Level
0         Per Timestep Output Level
# ASCII output filename root
ev_surrogate_check_
# Binary output filename root
ts_surrogate_check_
# Species to output in ASCII output (format 14a5): 14
{species_line}
## Input Controls
# Nuclear Data Directory
{data_name}
# Initial Abundance and Thermodynamic Trajectory Files
{data_name}/{abundance_name}
th_short
"""


def prepare_case(
    work_directory: Path,
    source_data: Path,
    helm_table: Path,
    *,
    abundance_name: str,
    output_species: tuple[str, ...],
    title: str,
    run_token: str,
    electron_fraction: float,
    stop_time: float,
    t9: float,
    rho: float,
    initial_composition: list[float] | None = None,
) -> Path:
    work_directory.mkdir(parents=True)
    staged_data = work_directory / source_data.name
    staged_data.mkdir()
    for name in ("sunet", "netwinv", "netsu", "netweak"):
        (staged_data / name).symlink_to((source_data / name).resolve())
    if initial_composition is None:
        (staged_data / abundance_name).symlink_to((source_data / abundance_name).resolve())
    else:
        write_abundance_file(
            staged_data / abundance_name,
            read_species(staged_data),
            initial_composition,
            "Composition evolved by a preceding fixed-state full_net call",
        )
    (work_directory / helm_table.name).symlink_to(helm_table.resolve())
    (work_directory / "control").write_text(
        control_text(
            title=f"token={run_token} {title}",
            data_name=source_data.name,
            abundance_name=abundance_name,
            output_species=output_species,
        ),
        encoding="ascii",
    )
    (work_directory / "th_short").write_text(
        "Constant state for surrogate-result validation\n"
        "0.000000E+00    Start Time\n"
        f"{stop_time:.12E}    Stop Time\n"
        "1.000000E-12    Init Del t\n"
        f"0.0E+00 {t9:.12E} {rho:.12E} {electron_fraction:.12g}\n"
        f"{stop_time:.12E} {t9:.12E} {rho:.12E} {electron_fraction:.12g}\n",
        encoding="ascii",
    )
    return staged_data


def run_process(
    command: list[str], directory: Path, label: str
) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            command,
            cwd=directory,
            capture_output=True,
            text=True,
            timeout=60.0,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        fail(f"{label} could not complete: {error}; artifacts: {directory}")
    (directory / f"{label}.stdout.txt").write_text(result.stdout, encoding="utf-8")
    (directory / f"{label}.stderr.txt").write_text(result.stderr, encoding="utf-8")
    if result.returncode != 0:
        fail(
            f"{label} returned {result.returncode}:\n{result.stdout}\n{result.stderr}"
            f"\nartifacts: {directory}"
        )
    return result


def read_species(data_directory: Path) -> tuple[str, ...]:
    lines = (data_directory / "sunet").read_text(encoding="ascii").splitlines()
    species = tuple(line[:5].strip() for line in lines)
    if not species or any(not name for name in species):
        fail(f"invalid sunet species list: {data_directory / 'sunet'}")
    return species


def parse_composition(lines: list[str], marker: str, species: tuple[str, ...]) -> list[float]:
    try:
        index = next(i for i, line in enumerate(lines) if line.startswith(marker)) + 1
    except StopIteration:
        fail(f"diagnostic is missing {marker.strip()} composition")
    names: list[str] = []
    values: list[float] = []
    while len(values) < len(species) and index < len(lines):
        line = lines[index]
        index += 1
        for offset in range(0, len(line), 20):
            field = line[offset : offset + 20]
            if not field.strip():
                continue
            name = field[:5].strip()
            token = field[5:19].strip()
            try:
                value = float(token.replace("D", "E").replace("d", "e"))
            except ValueError:
                fail(f"malformed {marker.strip()} composition field: {field!r}")
            names.append(name)
            values.append(value)
    if tuple(names) != species:
        fail(f"{marker.strip()} species order does not match sunet")
    if any(not math.isfinite(value) for value in values):
        fail(f"{marker.strip()} composition contains a non-finite value")
    return values


def validate_production_run(
    lines: list[str],
    run_token: str,
    label: str,
    *,
    stop_time: float,
    t9: float,
    rho: float,
) -> int:
    if sum(run_token in line for line in lines) != 1:
        fail(f"{label} diagnostic does not contain its unique run token exactly once")
    start_lines = [line.split() for line in lines if line.startswith("Start")]
    end_lines = [line.split() for line in lines if line.startswith("End")]
    counter_headers = [i for i, line in enumerate(lines) if line.startswith("Counters:")]
    if len(start_lines) != 1 or len(end_lines) != 1 or len(counter_headers) != 1:
        fail(f"{label} diagnostic has incomplete or duplicate endpoint records")
    counter_index = counter_headers[0]
    if counter_index + 2 >= len(lines) or lines[counter_index + 2].strip() != "Timers Summary:":
        fail(f"{label} diagnostic does not contain exactly one one-zone counter row")
    if len(start_lines[0]) != 7 or len(end_lines[0]) != 8:
        fail(f"{label} diagnostic endpoint header has the wrong field count")
    try:
        start_zone, start_step = (int(value) for value in start_lines[0][1:3])
        start_values = [float(value) for value in start_lines[0][3:]]
        end_zone, end_step = (int(value) for value in end_lines[0][1:3])
        end_values = [float(value) for value in end_lines[0][3:]]
        counter_values = [int(value) for value in lines[counter_index + 1].split()]
    except (IndexError, ValueError) as error:
        fail(f"{label} diagnostic endpoint/counter record is malformed: {error}")
    if any(not math.isfinite(value) for value in start_values + end_values):
        fail(f"{label} diagnostic endpoint contains a non-finite value")
    if start_zone != 1 or end_zone != 1 or start_step != 0 or end_step <= 0:
        fail(f"{label} diagnostic has unexpected zone/step identifiers")
    if (
        start_values[0] != 0.0
        or not math.isclose(end_values[0], stop_time, rel_tol=1.0e-7)
        or not math.isclose(end_values[1], stop_time, rel_tol=1.0e-7)
        or not math.isclose(start_values[1], t9, rel_tol=1.0e-7)
        or not math.isclose(end_values[2], t9, rel_tol=1.0e-7)
        or not math.isclose(start_values[2], rho, rel_tol=1.0e-7)
        or not math.isclose(end_values[3], rho, rel_tol=1.0e-7)
    ):
        fail(f"{label} diagnostic did not cover the requested time interval")
    if len(counter_values) != 6 or counter_values[0] != 1:
        fail(f"{label} diagnostic counter record is malformed")
    if counter_values[1] != end_step or any(value <= 0 for value in counter_values[1:]):
        fail(f"{label} diagnostic counters do not confirm completed evolution")
    return end_step


def write_candidate(
    path: Path,
    initial: list[float],
    result: list[float],
    species: tuple[str, ...],
    verification_token: str,
    *,
    fraction_tolerance: float = 1.0e-12,
    mass_tolerance: float = 2.0e-6,
    ye_tolerance: float = 2.0e-6,
    step_checks_enabled: bool = True,
    fraction_change_limit: float = 0.1,
    energy_change_fraction_limit: float = 0.1,
    energy_rate_scale: float = 1.0,
    tstep: float,
    t9: float,
    rho: float,
) -> None:
    def value_text(value: float) -> str:
        return "NaN" if math.isnan(value) else f"{value:.17e}"

    path.write_text(
        f"{len(initial)}\n"
        f"{verification_token}\n"
        + " ".join(species)
        + "\n"
        f"{fraction_tolerance:.17e} {mass_tolerance:.17e} {ye_tolerance:.17e}\n"
        f"{int(step_checks_enabled)} {fraction_change_limit:.17e} "
        f"{energy_change_fraction_limit:.17e} {energy_rate_scale:.17e} "
        f"{tstep:.17e} {t9:.17e} {rho:.17e}\n"
        + " ".join(value_text(value) for value in initial)
        + "\n"
        + " ".join(value_text(value) for value in result)
        + "\n",
        encoding="ascii",
    )


def verify_candidate(
    verifier: Path,
    data_directory: Path,
    work_directory: Path,
    initial: list[float],
    result: list[float],
    label: str,
    *,
    tstep: float,
    t9: float,
    rho: float,
    step_checks_enabled: bool = True,
    fraction_change_limit: float = 0.1,
    energy_change_fraction_limit: float = 0.1,
    energy_rate_scale: float = 1.0,
) -> dict[str, int | float]:
    candidate = work_directory / f"{label}.candidate"
    species = read_species(data_directory)
    verification_token = secrets.token_hex(16)
    write_candidate(
        candidate,
        initial,
        result,
        species,
        verification_token,
        step_checks_enabled=step_checks_enabled,
        fraction_change_limit=fraction_change_limit,
        energy_change_fraction_limit=energy_change_fraction_limit,
        energy_rate_scale=energy_rate_scale,
        tstep=tstep,
        t9=t9,
        rho=rho,
    )
    completed = run_process(
        [str(verifier), str(data_directory), str(candidate)], work_directory, label
    )
    values: dict[str, int | float] = {}
    echoed_token = ""
    metadata_identity = 0
    for line in completed.stdout.splitlines():
        if line.startswith("verification_token "):
            echoed_token = line.split(maxsplit=1)[1]
        if line.startswith("metadata_identity "):
            metadata_identity = int(line.split(maxsplit=1)[1])
        match = re.fullmatch(r"([a-z_]+)\s+([0-9]+)", line.strip())
        if match and match.group(1) in STATUS_KEYS:
            if match.group(1) in values:
                fail(f"{label} verifier emitted a duplicate status key")
            values[match.group(1)] = int(match.group(2))
        metric_match = re.fullmatch(r"([a-z_]+)\s+(\S+)", line.strip())
        if metric_match and metric_match.group(1) in METRIC_KEYS:
            key = metric_match.group(1)
            if key in values:
                fail(f"{label} verifier emitted a duplicate metric key")
            if key == "maximum_fraction_change_index":
                values[key] = int(metric_match.group(2))
            else:
                values[key] = float(metric_match.group(2))
    if echoed_token != verification_token:
        fail(f"{label} verifier did not echo its unique candidate token")
    if metadata_identity != 1:
        fail(f"{label} verifier did not confirm production metadata identity")
    if tuple(key for key in values if key in STATUS_KEYS) != STATUS_KEYS:
        fail(f"{label} verifier output is incomplete: {completed.stdout!r}")
    if any(key not in values for key in METRIC_KEYS):
        fail(f"{label} verifier metrics are incomplete: {completed.stdout!r}")
    if step_checks_enabled:
        energy_rate = float(values["energy_rate"])
        initial_energy = float(values["initial_specific_internal_energy"])
        expected_fraction = abs(energy_rate * tstep) / initial_energy
        if not math.isclose(
            float(values["energy_change_fraction"]),
            expected_fraction,
            rel_tol=1.0e-13,
            abs_tol=1.0e-15,
        ):
            fail(
                f"{label} energy-change metric disagrees with independently calculated ratio"
            )
    return values


def require_only(statuses: dict[str, int | float], failed_key: str, label: str) -> None:
    if statuses[failed_key] != FAIL:
        fail(f"{label} did not reject {failed_key}: {statuses}")
    for key in STATUS_KEYS[1:]:
        if key in ("fraction_change_status", "energy_change_fraction_status"):
            expected = SKIP
        else:
            expected = FAIL if key == failed_key else PASS
        if statuses[key] != expected:
            fail(f"{label} did not isolate {failed_key}: {statuses}")


def require_all_pass(outcomes: list[int], expected_count: int, label: str) -> None:
    if len(outcomes) != expected_count or any(outcome != PASS for outcome in outcomes):
        fail(f"{label} did not all pass: {outcomes}")


def exercise_freshness_guards(
    work_root: Path,
    verifier: Path,
    alpha_work: Path,
    alpha_data: Path,
    data_alpha: Path,
    helm_table: Path,
    initial: list[float],
    result: list[float],
) -> None:
    try:
        require_all_pass([PASS, FAIL], 2, "controlled evolved-state outcomes")
    except CheckFailure as error:
        if "did not all pass" not in str(error):
            fail(f"evolved-outcome challenge failed for the wrong reason: {error}")
    else:
        fail("one failed evolved-state sample bypassed the all-pass guard")

    diagnostic_lines = (alpha_work / "net_diag01").read_text(encoding="utf-8").splitlines()
    token_match = next(
        (re.search(r"token=([0-9a-f]{32})", line) for line in diagnostic_lines if "token=" in line),
        None,
    )
    if token_match is None:
        fail("genuine alpha diagnostic is missing its run token")
    counter_index = next(
        i for i, line in enumerate(diagnostic_lines) if line.startswith("Counters:")
    )
    duplicate_counter_lines = diagnostic_lines.copy()
    duplicate_counter_lines.insert(counter_index + 2, diagnostic_lines[counter_index + 1])
    try:
        validate_production_run(
            duplicate_counter_lines,
            token_match.group(1),
            "duplicate counter",
            stop_time=1.0e-6,
            t9=3.0,
            rho=1.0e8,
        )
    except CheckFailure as error:
        if "exactly one one-zone counter row" not in str(error):
            fail(f"duplicate counter row failed for the wrong reason: {error}")
    else:
        fail("duplicate one-zone counter row bypassed the cardinality guard")

    replay_xnet = work_root / "replay_xnet.py"
    replay_source = alpha_work / "net_diag01"
    replay_xnet.write_text(
        "#!/usr/bin/env python3\n"
        "from pathlib import Path\n"
        f"Path('net_diag01').write_bytes(Path({str(replay_source)!r}).read_bytes())\n",
        encoding="ascii",
    )
    replay_xnet.chmod(0o755)
    try:
        execute_case(
            work_root,
            replay_xnet,
            verifier,
            data_alpha,
            helm_table,
            name="negative_replay",
            abundance_name="ab_he",
            output_species=ALPHA_OUTPUT_SPECIES,
            electron_fraction=0.5,
            stop_time=1.0e-6,
            t9=3.0,
            rho=1.0e8,
            step_checks_enabled=False,
        )
    except CheckFailure as error:
        if "unique run token" not in str(error):
            fail(f"replayed XNet output failed for the wrong reason: {error}")
    else:
        fail("static replayed XNet output bypassed the unique-run guard")

    fake_verifier = work_root / "fake_verifier.py"
    fake_verifier.write_text(
        "#!/usr/bin/env python3\n"
        "print('overall_status 1')\n"
        "print('finite_status 1')\n"
        "print('fraction_bounds_status 1')\n"
        "print('mass_normalization_status 1')\n"
        "print('fixed_ye_status 1')\n",
        encoding="ascii",
    )
    fake_verifier.chmod(0o755)
    try:
        verify_candidate(
            fake_verifier,
            alpha_data,
            alpha_work,
            initial,
            result,
            "negative_fake_verifier",
            tstep=1.0e-6,
            t9=3.0,
            rho=1.0e8,
            step_checks_enabled=False,
        )
    except CheckFailure as error:
        if "unique candidate token" not in str(error):
            fail(f"substituted verifier failed for the wrong reason: {error}")
    else:
        fail("non-reading verifier stub bypassed the candidate-token guard")

    perturbed_metric_verifier = work_root / "perturbed_metric_verifier.py"
    perturbed_metric_verifier.write_text(
        "#!/usr/bin/env python3\n"
        "import subprocess\n"
        "import sys\n"
        f"result = subprocess.run([{str(verifier.resolve())!r}, *sys.argv[1:]], "
        "capture_output=True, text=True, check=False)\n"
        "for line in result.stdout.splitlines():\n"
        "    if line.startswith('energy_change_fraction '):\n"
        "        value = float(line.split()[1])\n"
        "        print(f'energy_change_fraction {0.5 * value:.16e}')\n"
        "    else:\n"
        "        print(line)\n"
        "sys.stderr.write(result.stderr)\n"
        "raise SystemExit(result.returncode)\n",
        encoding="ascii",
    )
    perturbed_metric_verifier.chmod(0o755)
    try:
        verify_candidate(
            perturbed_metric_verifier,
            alpha_data,
            alpha_work,
            initial,
            result,
            "negative_perturbed_energy_metric",
            tstep=1.0e-6,
            t9=3.0,
            rho=1.0e8,
        )
    except CheckFailure as error:
        if "energy-change metric disagrees" not in str(error):
            fail(f"perturbed energy metric failed for the wrong reason: {error}")
    else:
        fail("perturbed energy metric bypassed the independent ratio guard")


def execute_case(
    root: Path,
    xnet: Path,
    verifier: Path,
    source_data: Path,
    helm_table: Path,
    *,
    name: str,
    abundance_name: str,
    output_species: tuple[str, ...],
    electron_fraction: float,
    stop_time: float,
    t9: float,
    rho: float,
    step_checks_enabled: bool = True,
    require_material_change: bool = True,
    initial_composition: list[float] | None = None,
) -> tuple[
    Path,
    Path,
    tuple[str, ...],
    list[float],
    list[float],
    dict[str, int | float],
]:
    work_directory = root / name
    run_token = secrets.token_hex(16)
    data_directory = prepare_case(
        work_directory,
        source_data,
        helm_table,
        abundance_name=abundance_name,
        output_species=output_species,
        title=f"{name} full_net surrogate-result candidate",
        run_token=run_token,
        electron_fraction=electron_fraction,
        stop_time=stop_time,
        t9=t9,
        rho=rho,
        initial_composition=initial_composition,
    )
    run_process([str(xnet)], work_directory, "xnet")
    diagnostic_path = work_directory / "net_diag01"
    if not diagnostic_path.is_file():
        fail(f"xnet did not emit {diagnostic_path}")
    lines = diagnostic_path.read_text(encoding="utf-8").splitlines()
    validate_production_run(
        lines,
        run_token,
        name,
        stop_time=stop_time,
        t9=t9,
        rho=rho,
    )
    species = read_species(data_directory)
    initial = parse_composition(lines, "Start", species)
    result = parse_composition(lines, "End", species)
    if require_material_change and max(
        abs(after - before) for before, after in zip(initial, result)
    ) <= 1.0e-8:
        fail(f"{name} full_net result did not materially change composition")
    statuses = verify_candidate(
        verifier,
        data_directory,
        work_directory,
        initial,
        result,
        "unmodified",
        tstep=stop_time,
        t9=t9,
        rho=rho,
        step_checks_enabled=step_checks_enabled,
    )
    if any(statuses[key] != PASS for key in BASE_STATUS_KEYS):
        fail(f"{name} full_net candidate failed base validation: {statuses}")
    if step_checks_enabled:
        expected_fraction = (
            PASS if statuses["maximum_fraction_change"] <= 0.1 else FAIL
        )
        expected_energy = PASS if statuses["energy_change_fraction"] <= 0.1 else FAIL
        if statuses["fraction_change_status"] != expected_fraction:
            fail(f"{name} fraction-change status disagrees with its metric: {statuses}")
        if statuses["energy_change_fraction_status"] != expected_energy:
            fail(f"{name} energy-change status disagrees with its metric: {statuses}")
        expected_overall = (
            PASS if expected_fraction == PASS and expected_energy == PASS else FAIL
        )
    else:
        if statuses["fraction_change_status"] != SKIP:
            fail(f"{name} disabled fraction-change check did not skip: {statuses}")
        if statuses["energy_change_fraction_status"] != SKIP:
            fail(f"{name} disabled energy-change check did not skip: {statuses}")
        expected_overall = PASS
    if statuses["overall_status"] != expected_overall:
        fail(f"{name} overall status disagrees with selected checks: {statuses}")
    return work_directory, data_directory, species, initial, result, statuses


def characterize_evolved_increment(
    root: Path,
    xnet: Path,
    verifier: Path,
    source_data: Path,
    helm_table: Path,
    *,
    network_label: str,
    sample_label: str,
    abundance_name: str,
    output_species: tuple[str, ...],
    electron_fraction: float,
    anchor_time: float,
    tstep: float,
    t9: float,
    rho: float,
    anchor_case: tuple | None = None,
) -> dict[str, int | float]:
    if anchor_case is None:
        anchor_case = execute_case(
            root,
            xnet,
            verifier,
            source_data,
            helm_table,
            name=f"{sample_label}_anchor",
            abundance_name=abundance_name,
            output_species=output_species,
            electron_fraction=electron_fraction,
            stop_time=anchor_time,
            t9=t9,
            rho=rho,
            step_checks_enabled=False,
            require_material_change=False,
        )
    _, _, species, artificial_initial, evolved_initial = anchor_case[:5]
    burn_in_change = max(
        abs(after - before)
        for before, after in zip(artificial_initial, evolved_initial)
    )
    if burn_in_change <= 1.0e-8:
        fail(f"{sample_label} burn-in did not produce an evolved starting composition")

    restart = execute_case(
        root,
        xnet,
        verifier,
        source_data,
        helm_table,
        name=f"{sample_label}_restart",
        abundance_name=abundance_name,
        output_species=output_species,
        electron_fraction=electron_fraction,
        stop_time=tstep,
        t9=t9,
        rho=rho,
        step_checks_enabled=True,
        require_material_change=False,
        initial_composition=evolved_initial,
    )
    _, _, restart_species, restarted_initial, evolved_result, metrics = restart
    if species != restart_species:
        fail(f"{sample_label} restarted full_net call changed species identity")
    restart_initial_error = max(
        abs(expected - actual)
        for expected, actual in zip(evolved_initial, restarted_initial)
    )
    if restart_initial_error > 2.0e-6:
        fail(f"{sample_label} restarted call did not consume its evolved composition")
    if any(metrics[key] != PASS for key in BASE_STATUS_KEYS):
        fail(f"{sample_label} evolved increment failed base validation: {metrics}")
    expected_fraction = PASS if metrics["maximum_fraction_change"] <= 0.1 else FAIL
    expected_energy = PASS if metrics["energy_change_fraction"] <= 0.1 else FAIL
    if metrics["fraction_change_status"] != expected_fraction:
        fail(f"{sample_label} component status disagrees with metric: {metrics}")
    if metrics["energy_change_fraction_status"] != expected_energy:
        fail(f"{sample_label} energy status disagrees with metric: {metrics}")
    expected_overall = PASS if expected_fraction == PASS and expected_energy == PASS else FAIL
    if metrics["overall_status"] != expected_overall:
        fail(f"{sample_label} overall status disagrees with metrics: {metrics}")

    component_changes = [
        abs(after - before) for before, after in zip(restarted_initial, evolved_result)
    ]
    maximum_index = max(range(len(component_changes)), key=component_changes.__getitem__)
    total_variation = 0.5 * sum(component_changes)
    if metrics["maximum_fraction_change_index"] != maximum_index + 1:
        fail(f"{sample_label} maximum-change index disagrees with direct calculation")
    if not math.isclose(
        float(metrics["maximum_fraction_change"]),
        component_changes[maximum_index],
        rel_tol=1.0e-12,
        abs_tol=1.0e-15,
    ):
        fail(f"{sample_label} maximum-change metric disagrees with direct calculation")
    outcome = "PASS" if expected_overall == PASS else "FAIL"
    print(
        "evolved_reference "
        f"network={network_label} sample={sample_label} T9={t9:.6g} rho={rho:.6e} "
        f"anchor={anchor_time:.6e} dt={tstep:.6e} "
        f"burn_in_max_dX={burn_in_change:.8e} "
        f"restart_initial_max_dX={restart_initial_error:.8e} "
        f"max_dX={component_changes[maximum_index]:.8e} "
        f"species={species[maximum_index]} total_variation={total_variation:.8e} "
        f"energy_fraction={float(metrics['energy_change_fraction']):.8e} "
        f"illustrative_0.1={outcome} restarted_full_net=true"
    )
    return metrics


def main(arguments: list[str]) -> int:
    if len(arguments) != 6:
        fail(
            "usage: run_surrogate_full_net_checks.py WORK_DIR XNET VERIFIER "
            "DATA_ALPHA DATA_SN231 HELM_TABLE"
        )
    work_root, xnet, verifier, data_alpha, data_sn231, helm_table = (
        Path(argument).resolve() for argument in arguments
    )
    if "/build/" not in str(work_root) or work_root.name != "surrogate-full-net-work":
        fail(f"refusing unexpected surrogate-check work directory: {work_root}")
    for executable in (xnet, verifier):
        if not executable.is_file():
            fail(f"missing executable: {executable}")
    for path in (data_alpha, data_sn231, helm_table):
        if not path.exists():
            fail(f"missing test input: {path}")
    if work_root.exists() and not work_root.is_dir():
        fail(f"work path is not a directory: {work_root}")
    shutil.rmtree(work_root, ignore_errors=True)
    work_root.mkdir(parents=True)

    (
        alpha_work,
        alpha_data,
        alpha_species,
        alpha_initial,
        alpha_result,
        alpha_metrics,
    ) = execute_case(
        work_root,
        xnet.resolve(),
        verifier.resolve(),
        data_alpha.resolve(),
        helm_table.resolve(),
        name="alpha",
        abundance_name="ab_he",
        output_species=ALPHA_OUTPUT_SPECIES,
        electron_fraction=0.5,
        stop_time=1.0e-6,
        t9=3.0,
        rho=1.0e8,
    )
    sn_work, sn_data, sn_species, sn_initial, sn_result, sn_metrics = execute_case(
        work_root,
        xnet.resolve(),
        verifier.resolve(),
        data_sn231.resolve(),
        helm_table.resolve(),
        name="sn231",
        abundance_name="ab_co",
        output_species=SN231_OUTPUT_SPECIES,
        electron_fraction=0.499545454545,
        stop_time=1.0e-6,
        t9=3.0,
        rho=1.0e8,
    )

    for label, metrics in (("alpha ignition", alpha_metrics), ("SN231 ignition", sn_metrics)):
        if metrics["fraction_change_status"] != FAIL:
            fail(f"{label} fixture did not cross the illustrative component limit: {metrics}")
        if metrics["energy_change_fraction_status"] != FAIL:
            fail(f"{label} fixture did not cross the illustrative energy limit: {metrics}")
    for network_label, species, initial, result, metrics in (
        ("alpha", alpha_species, alpha_initial, alpha_result, alpha_metrics),
        ("SN231", sn_species, sn_initial, sn_result, sn_metrics),
    ):
        component_changes = [
            abs(after - before) for before, after in zip(initial, result)
        ]
        maximum_index = max(range(len(component_changes)), key=component_changes.__getitem__)
        print(
            "ignition_reference "
            f"network={network_label} T9=3 rho={1.0e8:.6e} anchor={0.0:.6e} "
            f"dt={1.0e-6:.6e} max_dX={component_changes[maximum_index]:.8e} "
            f"species={species[maximum_index]} "
            f"total_variation={0.5 * sum(component_changes):.8e} "
            f"energy_fraction={float(metrics['energy_change_fraction']):.8e} "
            "illustrative_0.1=FAIL artificial_initial=true"
        )

    scaled_rate_metrics = verify_candidate(
        verifier.resolve(),
        alpha_data,
        alpha_work,
        alpha_initial,
        alpha_result,
        "mutate_energy_rate_scale",
        tstep=1.0e-6,
        t9=3.0,
        rho=1.0e8,
        energy_rate_scale=0.5,
    )
    if scaled_rate_metrics["binding_energy_rate_status"] != FAIL:
        fail(f"scaled energy rate bypassed binding-energy validation: {scaled_rate_metrics}")
    if math.isclose(
        float(scaled_rate_metrics["energy_rate"]),
        float(scaled_rate_metrics["expected_energy_rate"]),
        rel_tol=1.0e-12,
        abs_tol=0.0,
    ):
        fail("scaled energy-rate challenge did not produce the intended mismatch")

    evolved_samples = (
        ("lowT_lowRho", 2.0, 1.0e7, 1.0e-2, 1.0e-3),
        ("lowT_highRho", 2.0, 1.0e9, 1.0e-4, 1.0e-5),
        ("midT_midRho", 3.0, 1.0e8, 1.0e-6, 1.0e-8),
        ("highT_lowRho", 5.0, 1.0e7, 1.0e-6, 1.0e-8),
        ("highT_highRho", 5.0, 1.0e9, 1.0e-8, 1.0e-8),
    )
    evolved_outcomes: dict[str, list[int]] = {"alpha": [], "SN231": []}
    for network_label, source_data, abundance_name, output_species, electron_fraction in (
        ("alpha", data_alpha, "ab_he", ALPHA_OUTPUT_SPECIES, 0.5),
        ("SN231", data_sn231, "ab_co", SN231_OUTPUT_SPECIES, 0.499545454545),
    ):
        for sample_name, sample_t9, sample_rho, anchor_time, sample_tstep in evolved_samples:
            metrics = characterize_evolved_increment(
                work_root,
                xnet.resolve(),
                verifier.resolve(),
                source_data.resolve(),
                helm_table.resolve(),
                network_label=network_label,
                sample_label=f"{network_label}_{sample_name}",
                abundance_name=abundance_name,
                output_species=output_species,
                electron_fraction=electron_fraction,
                anchor_time=anchor_time,
                tstep=sample_tstep,
                t9=sample_t9,
                rho=sample_rho,
            )
            evolved_outcomes[network_label].append(int(metrics["overall_status"]))
    for network_label, outcomes in evolved_outcomes.items():
        require_all_pass(outcomes, len(evolved_samples), f"{network_label} evolved-state samples")

    duration_samples = (
        ("dt_min", 1.0e-8),
        ("dt_mid", 1.0e-5),
        ("dt_max", 1.0e-3),
    )
    for network_label, source_data, abundance_name, output_species, electron_fraction in (
        ("alpha", data_alpha, "ab_he", ALPHA_OUTPUT_SPECIES, 0.5),
        ("SN231", data_sn231, "ab_co", SN231_OUTPUT_SPECIES, 0.499545454545),
    ):
        anchor_time = 1.0e-2
        t9 = 2.0
        rho = 1.0e7
        duration_anchor = execute_case(
            work_root,
            xnet.resolve(),
            verifier.resolve(),
            source_data.resolve(),
            helm_table.resolve(),
            name=f"{network_label}_duration_anchor",
            abundance_name=abundance_name,
            output_species=output_species,
            electron_fraction=electron_fraction,
            stop_time=anchor_time,
            t9=t9,
            rho=rho,
            step_checks_enabled=False,
            require_material_change=False,
        )
        duration_metrics = []
        for duration_label, duration in duration_samples:
            metrics = characterize_evolved_increment(
                work_root,
                xnet.resolve(),
                verifier.resolve(),
                source_data.resolve(),
                helm_table.resolve(),
                network_label=network_label,
                sample_label=f"{network_label}_duration_{duration_label}",
                abundance_name=abundance_name,
                output_species=output_species,
                electron_fraction=electron_fraction,
                anchor_time=anchor_time,
                tstep=duration,
                t9=t9,
                rho=rho,
                anchor_case=duration_anchor,
            )
            if metrics["overall_status"] != PASS:
                fail(
                    f"{network_label} duration sample {duration_label} did not pass: {metrics}"
                )
            duration_metrics.append(
                (
                    float(metrics["maximum_fraction_change"]),
                    float(metrics["energy_change_fraction"]),
                )
            )
        if any(
            later[metric_index] < earlier[metric_index]
            for earlier, later in zip(duration_metrics, duration_metrics[1:])
            for metric_index in range(2)
        ):
            fail(f"{network_label} fixed-anchor metrics are not monotone with duration")
        if any(
            duration_metrics[-1][metric_index] <= duration_metrics[0][metric_index]
            for metric_index in range(2)
        ):
            fail(f"{network_label} fixed-anchor metrics did not each depend on duration")

    finite_mutation = alpha_result.copy()
    finite_mutation[0] = math.nan
    finite_statuses = verify_candidate(
        verifier.resolve(),
        alpha_data,
        alpha_work,
        alpha_initial,
        finite_mutation,
        "mutate_finite",
        tstep=1.0e-6,
        t9=3.0,
        rho=1.0e8,
        step_checks_enabled=False,
    )
    if finite_statuses["finite_status"] != FAIL:
        fail(f"non-finite mutation was accepted: {finite_statuses}")

    bounds_mutation = alpha_result.copy()
    bounds_index = min(range(len(bounds_mutation)), key=bounds_mutation.__getitem__)
    donor_index = max(range(len(bounds_mutation)), key=bounds_mutation.__getitem__)
    transfer = bounds_mutation[bounds_index] + 1.0e-4
    bounds_mutation[bounds_index] = -1.0e-4
    bounds_mutation[donor_index] += transfer
    bounds_statuses = verify_candidate(
        verifier.resolve(),
        alpha_data,
        alpha_work,
        alpha_initial,
        bounds_mutation,
        "mutate_bounds",
        tstep=1.0e-6,
        t9=3.0,
        rho=1.0e8,
        step_checks_enabled=False,
    )
    require_only(bounds_statuses, "fraction_bounds_status", "bounds mutation")

    try:
        neutron_index = sn_species.index("n")
    except ValueError:
        fail("SN231 network does not contain a neutron species")
    normalization_mutation = sn_result.copy()
    normalization_mutation[neutron_index] += 1.0e-3
    normalization_statuses = verify_candidate(
        verifier.resolve(),
        sn_data,
        sn_work,
        sn_initial,
        normalization_mutation,
        "mutate_normalization",
        tstep=1.0e-6,
        t9=3.0,
        rho=1.0e8,
        step_checks_enabled=False,
    )
    require_only(
        normalization_statuses,
        "mass_normalization_status",
        "normalization mutation",
    )

    ye_mutation = sn_result.copy()
    donor_index = max(range(len(ye_mutation)), key=ye_mutation.__getitem__)
    ye_mutation[donor_index] -= 1.0e-3
    ye_mutation[neutron_index] += 1.0e-3
    ye_statuses = verify_candidate(
        verifier.resolve(),
        sn_data,
        sn_work,
        sn_initial,
        ye_mutation,
        "mutate_ye",
        tstep=1.0e-6,
        t9=3.0,
        rho=1.0e8,
        step_checks_enabled=False,
    )
    require_only(ye_statuses, "fixed_ye_status", "electron-fraction mutation")

    exercise_freshness_guards(
        work_root,
        verifier.resolve(),
        alpha_work,
        alpha_data,
        data_alpha.resolve(),
        helm_table.resolve(),
        alpha_initial,
        alpha_result,
    )

    print("Data_alpha and Data_SN231 full_net surrogate-result checks passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except CheckFailure as error:
        print(f"surrogate full_net check failed: {error}", file=sys.stderr)
        raise SystemExit(1)
