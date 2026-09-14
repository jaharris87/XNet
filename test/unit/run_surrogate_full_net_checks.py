#!/usr/bin/env python3

"""Apply the Fortran surrogate checker to short production full_net results."""

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
)
PASS = 1
FAIL = 2


def fail(message: str) -> None:
    raise CheckFailure(message)


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
) -> Path:
    work_directory.mkdir(parents=True)
    staged_data = work_directory / source_data.name
    staged_data.mkdir()
    for name in ("sunet", "netwinv", "netsu", "netweak", abundance_name):
        (staged_data / name).symlink_to((source_data / name).resolve())
    (work_directory / helm_table.name).symlink_to(helm_table.resolve())
    (work_directory / "control").write_text(
        control_text(
            title=f"{title} token={run_token}",
            data_name=source_data.name,
            abundance_name=abundance_name,
            output_species=output_species,
        ),
        encoding="ascii",
    )
    (work_directory / "th_short").write_text(
        "Constant hot state for surrogate-result validation\n"
        "0.000000E+00    Start Time\n"
        "1.000000E-06    Stop Time\n"
        "1.000000E-12    Init Del t\n"
        f"0.0E+00 3.0 1.0E+08 {electron_fraction:.12g}\n"
        f"1.0E-06 3.0 1.0E+08 {electron_fraction:.12g}\n",
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


def validate_production_run(lines: list[str], run_token: str, label: str) -> int:
    if sum(run_token in line for line in lines) != 1:
        fail(f"{label} diagnostic does not contain its unique run token exactly once")
    start_lines = [line.split() for line in lines if line.startswith("Start")]
    end_lines = [line.split() for line in lines if line.startswith("End")]
    counter_headers = [i for i, line in enumerate(lines) if line.startswith("Counters:")]
    if len(start_lines) != 1 or len(end_lines) != 1 or len(counter_headers) != 1:
        fail(f"{label} diagnostic has incomplete or duplicate endpoint records")
    if len(start_lines[0]) != 7 or len(end_lines[0]) != 8:
        fail(f"{label} diagnostic endpoint header has the wrong field count")
    try:
        start_zone, start_step = (int(value) for value in start_lines[0][1:3])
        start_values = [float(value) for value in start_lines[0][3:]]
        end_zone, end_step = (int(value) for value in end_lines[0][1:3])
        end_values = [float(value) for value in end_lines[0][3:]]
        counter_values = [int(value) for value in lines[counter_headers[0] + 1].split()]
    except (IndexError, ValueError) as error:
        fail(f"{label} diagnostic endpoint/counter record is malformed: {error}")
    if any(not math.isfinite(value) for value in start_values + end_values):
        fail(f"{label} diagnostic endpoint contains a non-finite value")
    if start_zone != 1 or end_zone != 1 or start_step != 0 or end_step <= 0:
        fail(f"{label} diagnostic has unexpected zone/step identifiers")
    if start_values[0] != 0.0 or end_values[0] != 1.0e-6 or end_values[1] != 1.0e-6:
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
) -> None:
    def value_text(value: float) -> str:
        return "NaN" if math.isnan(value) else f"{value:.17e}"

    path.write_text(
        f"{len(initial)}\n"
        f"{verification_token}\n"
        + " ".join(species)
        + "\n"
        f"{fraction_tolerance:.17e} {mass_tolerance:.17e} {ye_tolerance:.17e}\n"
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
) -> dict[str, int]:
    candidate = work_directory / f"{label}.candidate"
    species = read_species(data_directory)
    verification_token = secrets.token_hex(16)
    write_candidate(candidate, initial, result, species, verification_token)
    completed = run_process(
        [str(verifier), str(data_directory), str(candidate)], work_directory, label
    )
    statuses: dict[str, int] = {}
    echoed_token = ""
    metadata_identity = 0
    for line in completed.stdout.splitlines():
        if line.startswith("verification_token "):
            echoed_token = line.split(maxsplit=1)[1]
        if line.startswith("metadata_identity "):
            metadata_identity = int(line.split(maxsplit=1)[1])
        match = re.fullmatch(r"([a-z_]+)\s+([0-9]+)", line.strip())
        if match and match.group(1) in STATUS_KEYS:
            if match.group(1) in statuses:
                fail(f"{label} verifier emitted a duplicate status key")
            statuses[match.group(1)] = int(match.group(2))
    if echoed_token != verification_token:
        fail(f"{label} verifier did not echo its unique candidate token")
    if metadata_identity != 1:
        fail(f"{label} verifier did not confirm production metadata identity")
    if tuple(statuses) != STATUS_KEYS:
        fail(f"{label} verifier output is incomplete: {completed.stdout!r}")
    return statuses


def require_only(statuses: dict[str, int], failed_key: str, label: str) -> None:
    if statuses[failed_key] != FAIL:
        fail(f"{label} did not reject {failed_key}: {statuses}")
    for key in STATUS_KEYS[1:]:
        expected = FAIL if key == failed_key else PASS
        if statuses[key] != expected:
            fail(f"{label} did not isolate {failed_key}: {statuses}")


def exercise_substitution_guards(
    work_root: Path,
    verifier: Path,
    alpha_work: Path,
    alpha_data: Path,
    data_alpha: Path,
    helm_table: Path,
    initial: list[float],
    result: list[float],
) -> None:
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
        )
    except CheckFailure as error:
        if "unique run token" not in str(error):
            fail(f"replayed XNet output failed for the wrong reason: {error}")
    else:
        fail("replayed XNet output bypassed the unique-run guard")

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
        )
    except CheckFailure as error:
        if "unique candidate token" not in str(error):
            fail(f"substituted verifier failed for the wrong reason: {error}")
    else:
        fail("substituted verifier bypassed the candidate-token guard")


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
) -> tuple[Path, Path, tuple[str, ...], list[float], list[float]]:
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
    )
    run_process([str(xnet)], work_directory, "xnet")
    diagnostic_path = work_directory / "net_diag01"
    if not diagnostic_path.is_file():
        fail(f"xnet did not emit {diagnostic_path}")
    lines = diagnostic_path.read_text(encoding="utf-8").splitlines()
    validate_production_run(lines, run_token, name)
    species = read_species(data_directory)
    initial = parse_composition(lines, "Start", species)
    result = parse_composition(lines, "End", species)
    if max(abs(after - before) for before, after in zip(initial, result)) <= 1.0e-8:
        fail(f"{name} full_net result did not materially change composition")
    statuses = verify_candidate(
        verifier, data_directory, work_directory, initial, result, "unmodified"
    )
    if any(statuses[key] != PASS for key in STATUS_KEYS):
        fail(f"{name} full_net candidate failed validation: {statuses}")
    return work_directory, data_directory, species, initial, result


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

    alpha_work, alpha_data, alpha_species, alpha_initial, alpha_result = execute_case(
        work_root,
        xnet.resolve(),
        verifier.resolve(),
        data_alpha.resolve(),
        helm_table.resolve(),
        name="alpha",
        abundance_name="ab_he",
        output_species=ALPHA_OUTPUT_SPECIES,
        electron_fraction=0.5,
    )
    sn_work, sn_data, sn_species, sn_initial, sn_result = execute_case(
        work_root,
        xnet.resolve(),
        verifier.resolve(),
        data_sn231.resolve(),
        helm_table.resolve(),
        name="sn231",
        abundance_name="ab_co",
        output_species=SN231_OUTPUT_SPECIES,
        electron_fraction=0.499545454545,
    )

    finite_mutation = alpha_result.copy()
    finite_mutation[0] = math.nan
    finite_statuses = verify_candidate(
        verifier.resolve(),
        alpha_data,
        alpha_work,
        alpha_initial,
        finite_mutation,
        "mutate_finite",
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
    )
    require_only(ye_statuses, "fixed_ye_status", "electron-fraction mutation")

    exercise_substitution_guards(
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
