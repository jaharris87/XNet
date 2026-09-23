"""End-to-end regression cases for the compiled XNet executable."""

import json
import math
from pathlib import Path
import shutil
import subprocess

import pytest

from xnet_regression import (
    batch_alpha_case,
    bdf_sn160_case,
    RegressionCase,
    RegressionFailure,
    heat_alpha_case,
    heat_sn160_case,
    nse_sn160_case,
    prepare_work_directory,
    run_and_compare,
    tnsn_alpha_case,
    tnsn_torch47_case,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]


def _run_case(
    xnet_executable: Path,
    xnet_timeout: float,
    tmp_path: Path,
    case: RegressionCase,
) -> None:
    work_directory = tmp_path / case.name
    try:
        run_and_compare(
            xnet_executable,
            case,
            work_directory,
            timeout_seconds=xnet_timeout,
        )
    except RegressionFailure as error:
        category = error.__class__.__name__.removesuffix("Failure").lower()
        pytest.fail(f"{category} failure: {error}", pytrace=False)

    diagnostics = json.loads(
        (work_directory / "composition_error_norms.json").read_text(encoding="utf-8")
    )
    assert diagnostics["status"] == (
        "L2 is diagnostic-only; L1 and L-infinity are pass/fail gates "
        "only when this reference supplies limits"
    )
    assert diagnostics["vector"] == (
        "absolute mass-fraction errors for every species in the case"
    )
    assert [zone["zone"] for zone in diagnostics["zones"]] == list(
        case.expected_zones
    )
    for zone in diagnostics["zones"]:
        assert set(zone) == {
            "zone",
            "l1",
            "l2",
            "linf",
            "linf_species",
            "l1_limit",
            "linf_limit",
        }
        assert all(math.isfinite(zone[name]) for name in ("l1", "l2", "linf"))
        assert zone["l1"] >= zone["l2"] >= zone["linf"] >= 0.0
        assert zone["linf_species"] is None or isinstance(zone["linf_species"], str)


def _run_raw_configuration(
    xnet_executable: Path, work_directory: Path, timeout: float
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(xnet_executable)], cwd=work_directory, capture_output=True,
        text=True, timeout=timeout, check=False,
    )


def _resolved_controls(work_directory: Path) -> str:
    diagnostics = sorted(work_directory.glob("net_diag[0-9]*"))
    assert len(diagnostics) == 1
    text = diagnostics[0].read_text(encoding="utf-8")
    start = text.index("&xnet_controls")
    end = text.index("\n/", start) + 2
    return text[start:end] + "\n"


def _minimal_standalone_configuration(include: str = "") -> str:
    lines = ["&xnet_controls"]
    if include:
        lines.append(f" include_files(1) = {include},")
    lines.extend(
        (
            " data_dir = 'Data_alpha',",
            " iprocess = 1,",
            " inab_files(1) = 'Data_alpha/ab_co',",
            " thermo_files(1) = 'th_sn1aflame',",
            "/",
            "",
        )
    )
    return "\n".join(lines)


def _prepared_configuration_work_directory(tmp_path: Path, name: str) -> Path:
    return prepare_work_directory(tnsn_alpha_case(REPOSITORY_ROOT), tmp_path / name)


def test_namelist_uses_compiled_defaults(
    xnet_executable: Path, xnet_timeout: float, tmp_path: Path
) -> None:
    work_directory = _prepared_configuration_work_directory(tmp_path, "defaults")
    (work_directory / "controls.nml").write_text(
        _minimal_standalone_configuration(), encoding="utf-8"
    )
    result = _run_raw_configuration(xnet_executable, work_directory, xnet_timeout)
    assert result.returncode == 0, result.stdout + result.stderr
    resolved = _resolved_controls(work_directory)
    assert "nzone = 1" in resolved
    assert "isolv = 1" in resolved
    assert "kstmx = 9999" in resolved
    assert "nzbatchmx = 1" in resolved
    assert not (work_directory / "controls.resolved.nml").exists()


def test_bdf_resolved_namelist_records_effective_change_limits(
    xnet_executable: Path, xnet_timeout: float, tmp_path: Path
) -> None:
    work_directory = _prepared_configuration_work_directory(tmp_path, "bdf-effective")
    configuration = _minimal_standalone_configuration().replace(
        "&xnet_controls",
        "&xnet_controls\n isolv = 3,\n changemx = 1.25e-1,\n changemxt = 2.5e-2,",
    )
    (work_directory / "controls.nml").write_text(configuration, encoding="utf-8")
    result = _run_raw_configuration(xnet_executable, work_directory, xnet_timeout)
    assert (work_directory / "net_diag01").exists(), result.stdout + result.stderr
    resolved = _resolved_controls(work_directory)
    assert "changemx =   1.0000000000000000E+10" in resolved
    assert "changemxt =   1.0000000000000000E+10" in resolved


def test_resolved_namelist_escapes_and_round_trips_character_values(
    xnet_executable: Path, xnet_timeout: float, tmp_path: Path
) -> None:
    first_directory = _prepared_configuration_work_directory(tmp_path, "quoted-input")
    quoted_configuration = _minimal_standalone_configuration().replace(
        "&xnet_controls",
        "&xnet_controls\n description(1) = 'O''Brien test',\n"
        " ev_file_base = 'O''Brien_',",
    )
    (first_directory / "controls.nml").write_text(
        quoted_configuration, encoding="utf-8"
    )
    first_result = _run_raw_configuration(
        xnet_executable, first_directory, xnet_timeout
    )
    assert first_result.returncode == 0, first_result.stdout + first_result.stderr
    first_resolved = _resolved_controls(first_directory)
    assert "description(1) = 'O''Brien test'" in first_resolved
    assert "ev_file_base = 'O''Brien_'" in first_resolved

    second_directory = _prepared_configuration_work_directory(tmp_path, "quoted-resolved")
    (second_directory / "controls.nml").write_text(
        first_resolved, encoding="utf-8"
    )
    second_result = _run_raw_configuration(
        xnet_executable, second_directory, xnet_timeout
    )
    assert second_result.returncode == 0, second_result.stdout + second_result.stderr
    second_resolved = _resolved_controls(second_directory)
    assert second_resolved == first_resolved


@pytest.mark.parametrize(
    ("setting", "expected"),
    (
        ("ijac = 0,", "ijac must be positive"),
        ("tdel_maxmult = 0.0,", "tdel_maxmult must be positive"),
        ("changemx = -1.0,", "changemx must be positive"),
        ("yacc = -1.0,", "yacc nonnegative"),
        ("changemxt = -1.0,", "self-heating change and convergence limits"),
        ("tolt9 = -1.0,", "self-heating change and convergence limits"),
        ("t9nse = -1.0,", "t9nse must be nonnegative"),
    ),
)
def test_namelist_rejects_controls_used_as_divisors(
    xnet_executable: Path,
    xnet_timeout: float,
    tmp_path: Path,
    setting: str,
    expected: str,
) -> None:
    work_directory = _prepared_configuration_work_directory(
        tmp_path, setting.split()[0]
    )
    configuration = _minimal_standalone_configuration().replace(
        "&xnet_controls", f"&xnet_controls\n {setting}"
    )
    (work_directory / "controls.nml").write_text(configuration, encoding="utf-8")
    result = _run_raw_configuration(xnet_executable, work_directory, xnet_timeout)
    assert result.returncode != 0
    assert expected in result.stdout + result.stderr


@pytest.mark.parametrize("name", ("output_nuclei", "inab_files", "thermo_files", "include_files"))
def test_namelist_requires_explicit_array_indices(
    xnet_executable: Path, xnet_timeout: float, tmp_path: Path, name: str
) -> None:
    work_directory = _prepared_configuration_work_directory(tmp_path, f"unindexed-{name}")
    configuration = _minimal_standalone_configuration().replace(
        "&xnet_controls", f"&xnet_controls\n nzone = 1, {name} = 'unsupported',"
    )
    (work_directory / "controls.nml").write_text(configuration, encoding="utf-8")
    result = _run_raw_configuration(xnet_executable, work_directory, xnet_timeout)
    assert result.returncode != 0
    assert "Dynamically sized controls require explicit positive indices" in (
        result.stdout + result.stderr
    )


def test_namelist_include_precedence_and_nested_relative_paths(
    xnet_executable: Path, xnet_timeout: float, tmp_path: Path
) -> None:
    work_directory = _prepared_configuration_work_directory(tmp_path, "included")
    nested = work_directory / "nested"
    deeper = nested / "deeper"
    deeper.mkdir(parents=True)
    (deeper / "base.nml").write_text(
        _minimal_standalone_configuration(), encoding="utf-8"
    )
    (nested / "first.nml").write_text(
        "&xnet_controls\n include_files(1) = 'deeper/base.nml',\n isolv = 3\n/\n",
        encoding="utf-8",
    )
    (nested / "second.nml").write_text(
        "&xnet_controls\n isolv = 1\n/\n", encoding="utf-8"
    )
    (work_directory / "controls.nml").write_text(
        "&xnet_controls\n include_files(1) = 'nested/first.nml',\n"
        " include_files(2) = 'nested/second.nml'\n/\n",
        encoding="utf-8",
    )
    result = _run_raw_configuration(xnet_executable, work_directory, xnet_timeout)
    assert result.returncode == 0, result.stdout + result.stderr
    resolved = _resolved_controls(work_directory)
    assert "nzone = 1" in resolved
    assert "isolv = 1" in resolved


@pytest.mark.parametrize(
    ("configuration", "expected"),
    (
        ("&xnet_controls\n nzone = 'invalid'\n/\n", "Malformed or unknown xnet_controls namelist"),
        ("&xnet_controls\n unknown_setting = 1\n/\n", "Malformed or unknown xnet_controls namelist"),
        ("&xnet_controls\n include_files(1) = 'child.nml'\n/\n", "Controls include cycle"),
    ),
)
def test_namelist_rejects_malformed_unknown_and_include_cycle_input(
    xnet_executable: Path, xnet_timeout: float, tmp_path: Path,
    configuration: str, expected: str,
) -> None:
    work_directory = tmp_path / "invalid"
    work_directory.mkdir()
    (work_directory / "controls.nml").write_text(configuration, encoding="utf-8")
    if "child.nml" in configuration:
        (work_directory / "child.nml").write_text(
            "&xnet_controls\n include_files(1) = 'controls.nml'\n/\n", encoding="utf-8"
        )
    result = _run_raw_configuration(xnet_executable, work_directory, xnet_timeout)
    assert result.returncode != 0
    assert expected in result.stdout + result.stderr


@pytest.mark.parametrize(
    ("root_include", "child_include"),
    (
        ("'./controls.nml'", None),
        ("'nested/../nested/child.nml'", "'../controls.nml'"),
    ),
)
def test_namelist_rejects_lexical_alias_include_cycles(
    xnet_executable: Path, xnet_timeout: float, tmp_path: Path,
    root_include: str, child_include: str | None,
) -> None:
    work_directory = tmp_path / "alias-cycle"
    work_directory.mkdir()
    (work_directory / "controls.nml").write_text(
        f"&xnet_controls\n include_files(1) = {root_include}\n/\n", encoding="utf-8"
    )
    if child_include is not None:
        nested = work_directory / "nested"
        nested.mkdir()
        (nested / "child.nml").write_text(
            f"&xnet_controls\n include_files(1) = {child_include}\n/\n", encoding="utf-8"
        )
    result = _run_raw_configuration(xnet_executable, work_directory, xnet_timeout)
    assert result.returncode != 0
    assert "Controls include cycle" in result.stdout + result.stderr


@pytest.mark.parametrize(
    ("configuration", "expected"),
    (
        (None, "Failed to open controls file: controls.nml"),
        (
            "&xnet_controls\n include_files(1) = 'missing.nml'\n/\n",
            "Failed to open controls file: missing.nml",
        ),
    ),
)
def test_namelist_rejects_missing_root_and_include(
    xnet_executable: Path, xnet_timeout: float, tmp_path: Path,
    configuration: str | None, expected: str,
) -> None:
    work_directory = tmp_path / "missing"
    work_directory.mkdir()
    if configuration is not None:
        (work_directory / "controls.nml").write_text(configuration, encoding="utf-8")
    result = _run_raw_configuration(xnet_executable, work_directory, xnet_timeout)
    assert result.returncode != 0
    assert expected in result.stdout + result.stderr


def test_namelist_validates_only_after_all_layers(
    xnet_executable: Path, xnet_timeout: float, tmp_path: Path
) -> None:
    work_directory = _prepared_configuration_work_directory(tmp_path, "late-validation")
    (work_directory / "invalid.nml").write_text(
        "&xnet_controls\n nzone = 0\n/\n", encoding="utf-8"
    )
    (work_directory / "controls.nml").write_text(
        _minimal_standalone_configuration("'invalid.nml'"), encoding="utf-8"
    )
    result = _run_raw_configuration(xnet_executable, work_directory, xnet_timeout)
    assert result.returncode != 0
    assert "nzone must be positive" in result.stdout + result.stderr


def test_namelist_allows_a_later_layer_to_repair_root_validation(
    xnet_executable: Path, xnet_timeout: float, tmp_path: Path
) -> None:
    work_directory = _prepared_configuration_work_directory(tmp_path, "repaired-validation")
    (work_directory / "repair.nml").write_text(
        "&xnet_controls\n nzone = 1\n/\n", encoding="utf-8"
    )
    (work_directory / "controls.nml").write_text(
        "&xnet_controls\n"
        " include_files(1) = 'repair.nml',\n nzone = 0,\n data_dir = 'Data_alpha',\n"
        " iprocess = 1,\n inab_files(1) = 'Data_alpha/ab_co',\n"
        " thermo_files(1) = 'th_sn1aflame'\n"
        "/\n",
        encoding="utf-8",
    )
    result = _run_raw_configuration(xnet_executable, work_directory, xnet_timeout)
    assert result.returncode == 0, result.stdout + result.stderr
    resolved = _resolved_controls(work_directory)
    assert "nzone = 1" in resolved


def test_namelist_rejects_excessive_include_depth(
    xnet_executable: Path, xnet_timeout: float, tmp_path: Path
) -> None:
    work_directory = tmp_path / "too-deep"
    work_directory.mkdir()
    filenames = ["controls.nml", *(f"layer{index}.nml" for index in range(16))]
    for current, following in zip(filenames, filenames[1:]):
        (work_directory / current).write_text(
            f"&xnet_controls\n include_files(1) = '{following}'\n/\n", encoding="utf-8"
        )
    (work_directory / filenames[-1]).write_text("&xnet_controls\n/\n", encoding="utf-8")
    result = _run_raw_configuration(xnet_executable, work_directory, xnet_timeout)
    assert result.returncode != 0
    assert "Controls include depth limit exceeded" in result.stdout + result.stderr


def test_namelist_rejects_excessive_direct_includes(
    xnet_executable: Path, xnet_timeout: float, tmp_path: Path
) -> None:
    work_directory = tmp_path / "too-many-includes"
    work_directory.mkdir()
    includes = "\n".join(
        f" include_files({index + 1}) = 'layer{index}.nml'," for index in range(17)
    )
    (work_directory / "controls.nml").write_text(
        f"&xnet_controls\n{includes}\n/\n", encoding="utf-8"
    )
    for index in range(17):
        (work_directory / f"layer{index}.nml").write_text(
            "&xnet_controls\n/\n", encoding="utf-8"
        )
    result = _run_raw_configuration(xnet_executable, work_directory, xnet_timeout)
    assert result.returncode != 0
    assert "more than 16 direct includes" in result.stdout + result.stderr


def test_namelist_has_no_zone_staging_limit(
    xnet_executable: Path, xnet_timeout: float, tmp_path: Path
) -> None:
    work_directory = _prepared_configuration_work_directory(tmp_path, "many-zones")
    (work_directory / "controls.nml").write_text(
        _minimal_standalone_configuration().replace(
            " iprocess = 1,", " nzone = 4097,\n iprocess = 0,"
        ),
        encoding="utf-8",
    )
    result = _run_raw_configuration(xnet_executable, work_directory, xnet_timeout)
    output = result.stdout + result.stderr
    assert result.returncode != 0
    assert "nzone must" not in output
    assert "Malformed or unknown xnet_controls" not in output


def test_namelist_has_no_output_species_staging_limit(
    xnet_executable: Path, xnet_timeout: float, tmp_path: Path
) -> None:
    work_directory = _prepared_configuration_work_directory(tmp_path, "many-output-species")
    configuration = _minimal_standalone_configuration().replace(
        " iprocess = 1,",
        " iprocess = 0,\n"
        " nnucout = 257,\n"
        " output_nuclei(1) = 'he4',\n"
        " OUTPUT_NUCLEI(257) = 'he4',",
    )
    (work_directory / "controls.nml").write_text(configuration, encoding="utf-8")
    result = _run_raw_configuration(xnet_executable, work_directory, xnet_timeout)
    output = result.stdout + result.stderr
    assert result.returncode != 0
    assert "nnucout exceeds" not in output
    assert "Malformed or unknown xnet_controls" not in output


def test_tnsn_alpha(
    xnet_executable: Path, xnet_timeout: float, tmp_path: Path
) -> None:
    _run_case(
        xnet_executable,
        xnet_timeout,
        tmp_path,
        tnsn_alpha_case(REPOSITORY_ROOT),
    )


def test_heat_alpha(
    xnet_executable: Path, xnet_timeout: float, tmp_path: Path
) -> None:
    _run_case(
        xnet_executable,
        xnet_timeout,
        tmp_path,
        heat_alpha_case(REPOSITORY_ROOT),
    )


def test_heat_sn160(
    xnet_executable: Path, xnet_timeout: float, tmp_path: Path
) -> None:
    _run_case(
        xnet_executable,
        xnet_timeout,
        tmp_path,
        heat_sn160_case(REPOSITORY_ROOT),
    )


def test_bdf_sn160(
    xnet_executable: Path, xnet_timeout: float, tmp_path: Path
) -> None:
    _run_case(
        xnet_executable,
        xnet_timeout,
        tmp_path,
        bdf_sn160_case(REPOSITORY_ROOT),
    )


def test_nse_sn160(
    xnet_executable: Path, xnet_timeout: float, tmp_path: Path
) -> None:
    _run_case(
        xnet_executable,
        xnet_timeout,
        tmp_path,
        nse_sn160_case(REPOSITORY_ROOT),
    )


def test_batch_alpha(
    xnet_executable: Path, xnet_timeout: float, tmp_path: Path
) -> None:
    _run_case(
        xnet_executable,
        xnet_timeout,
        tmp_path,
        batch_alpha_case(REPOSITORY_ROOT),
    )


def test_missing_required_abundance_terminates_at_caller(
    xnet_executable: Path, xnet_timeout: float, tmp_path: Path
) -> None:
    case = batch_alpha_case(REPOSITORY_ROOT)
    work_directory = prepare_work_directory(case, tmp_path / "missing-abundance")
    missing_abundance = work_directory / "Data_alpha" / "ab_batch" / "ab_batch_01"
    missing_abundance.unlink()

    completed = subprocess.run(
        [str(xnet_executable)],
        cwd=work_directory,
        capture_output=True,
        text=True,
        timeout=xnet_timeout,
        check=False,
    )

    combined_output = completed.stdout + completed.stderr
    assert completed.returncode != 0
    assert (
        "Failed to open initial abundance file: Data_alpha/ab_batch/ab_batch_01"
        in combined_output
    )
    diagnostic = (work_directory / "net_diag01").read_text(encoding="utf-8")
    assert "Normalizing initial abundances" not in diagnostic
    assert "Zone     1 Initial abundances" not in diagnostic


def test_tnsn_torch47(
    xnet_executable: Path, xnet_timeout: float, tmp_path: Path
) -> None:
    _run_case(
        xnet_executable,
        xnet_timeout,
        tmp_path,
        tnsn_torch47_case(REPOSITORY_ROOT),
    )
