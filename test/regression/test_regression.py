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


def _minimal_standalone_configuration(include: str = "") -> str:
    lines = ["&xnet_config"]
    if include:
        lines.append(f" include = {include},")
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
    resolved = (work_directory / "controls.resolved.nml").read_text(encoding="utf-8")
    assert "nzone = 1" in resolved
    assert "isolv = 1" in resolved
    assert "kstmx = 9999" in resolved
    assert "nzbatchmx = 1" in resolved


def test_default_template_matches_compiled_defaults(
    xnet_executable: Path, xnet_timeout: float, tmp_path: Path
) -> None:
    compiled_directory = _prepared_configuration_work_directory(
        tmp_path, "compiled-defaults"
    )
    (compiled_directory / "controls.nml").write_text(
        _minimal_standalone_configuration(), encoding="utf-8"
    )
    compiled_result = _run_raw_configuration(
        xnet_executable, compiled_directory, xnet_timeout
    )
    assert compiled_result.returncode == 0, compiled_result.stdout + compiled_result.stderr

    work_directory = _prepared_configuration_work_directory(tmp_path, "default-template")
    shutil.copy2(
        REPOSITORY_ROOT / "controls.defaults.nml",
        work_directory / "defaults.nml",
    )
    (work_directory / "problem.nml").write_text(
        _minimal_standalone_configuration(), encoding="utf-8"
    )
    (work_directory / "controls.nml").write_text(
        "&xnet_config\n"
        "  include(1) = 'defaults.nml',\n"
        "  include(2) = 'problem.nml',\n"
        "/\n",
        encoding="utf-8",
    )
    result = _run_raw_configuration(xnet_executable, work_directory, xnet_timeout)
    assert result.returncode == 0, result.stdout + result.stderr
    compiled_resolved = (compiled_directory / "controls.resolved.nml").read_text(
        encoding="utf-8"
    )
    template_resolved = (work_directory / "controls.resolved.nml").read_text(
        encoding="utf-8"
    )
    assert template_resolved == compiled_resolved


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
        "&xnet_config\n include = 'deeper/base.nml', isolv = 3\n/\n",
        encoding="utf-8",
    )
    (nested / "second.nml").write_text(
        "&xnet_config\n isolv = 1\n/\n", encoding="utf-8"
    )
    (work_directory / "controls.nml").write_text(
        "&xnet_config\n include = 'nested/first.nml', 'nested/second.nml'\n/\n",
        encoding="utf-8",
    )
    result = _run_raw_configuration(xnet_executable, work_directory, xnet_timeout)
    assert result.returncode == 0, result.stdout + result.stderr
    resolved = (work_directory / "controls.resolved.nml").read_text(encoding="utf-8")
    assert "nzone = 1" in resolved
    assert "isolv = 1" in resolved


@pytest.mark.parametrize(
    ("configuration", "expected"),
    (
        ("&xnet_config\n nzone = 'invalid'\n/\n", "malformed or unknown xnet_config namelist"),
        ("&xnet_config\n unknown_setting = 1\n/\n", "malformed or unknown xnet_config namelist"),
        ("&xnet_config\n include = 'child.nml'\n/\n", "configuration include cycle"),
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
            "&xnet_config\n include = 'controls.nml'\n/\n", encoding="utf-8"
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
        f"&xnet_config\n include = {root_include}\n/\n", encoding="utf-8"
    )
    if child_include is not None:
        nested = work_directory / "nested"
        nested.mkdir()
        (nested / "child.nml").write_text(
            f"&xnet_config\n include = {child_include}\n/\n", encoding="utf-8"
        )
    result = _run_raw_configuration(xnet_executable, work_directory, xnet_timeout)
    assert result.returncode != 0
    assert "configuration include cycle" in result.stdout + result.stderr


@pytest.mark.parametrize(
    ("configuration", "expected"),
    (
        (None, "failed to open configuration file: controls.nml"),
        (
            "&xnet_config\n include = 'missing.nml'\n/\n",
            "failed to open configuration file: missing.nml",
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
        "&xnet_config\n nzone = 0\n/\n", encoding="utf-8"
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
        "&xnet_config\n nzone = 1\n/\n", encoding="utf-8"
    )
    (work_directory / "controls.nml").write_text(
        "&xnet_config\n"
        " include = 'repair.nml', nzone = 0, data_dir = 'Data_alpha', iprocess = 1,\n"
        " inab_files(1) = 'Data_alpha/ab_co', thermo_files(1) = 'th_sn1aflame'\n"
        "/\n",
        encoding="utf-8",
    )
    result = _run_raw_configuration(xnet_executable, work_directory, xnet_timeout)
    assert result.returncode == 0, result.stdout + result.stderr
    resolved = (work_directory / "controls.resolved.nml").read_text(encoding="utf-8")
    assert "nzone = 1" in resolved


def test_namelist_rejects_excessive_include_depth(
    xnet_executable: Path, xnet_timeout: float, tmp_path: Path
) -> None:
    work_directory = tmp_path / "too-deep"
    work_directory.mkdir()
    filenames = ["controls.nml", *(f"layer{index}.nml" for index in range(16))]
    for current, following in zip(filenames, filenames[1:]):
        (work_directory / current).write_text(
            f"&xnet_config\n include = '{following}'\n/\n", encoding="utf-8"
        )
    (work_directory / filenames[-1]).write_text("&xnet_config\n/\n", encoding="utf-8")
    result = _run_raw_configuration(xnet_executable, work_directory, xnet_timeout)
    assert result.returncode != 0
    assert "configuration include depth limit exceeded" in result.stdout + result.stderr


def test_namelist_rejects_excessive_direct_includes(
    xnet_executable: Path, xnet_timeout: float, tmp_path: Path
) -> None:
    work_directory = tmp_path / "too-many-includes"
    work_directory.mkdir()
    includes = ", ".join(f"'layer{index}.nml'" for index in range(17))
    (work_directory / "controls.nml").write_text(
        f"&xnet_config\n include = {includes}\n/\n", encoding="utf-8"
    )
    for index in range(17):
        (work_directory / f"layer{index}.nml").write_text(
            "&xnet_config\n/\n", encoding="utf-8"
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
    assert "malformed or unknown xnet_config" not in output


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
    assert "malformed or unknown xnet_config" not in output


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
