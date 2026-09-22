"""End-to-end regression cases for the compiled XNet executable."""

import json
import math
from pathlib import Path
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


def test_namelist_include_is_read_from_the_including_directory(
    xnet_executable: Path, xnet_timeout: float, tmp_path: Path
) -> None:
    case = tnsn_alpha_case(REPOSITORY_ROOT)
    work_directory = prepare_work_directory(case, tmp_path / "included")
    configuration = (work_directory / "xnet.nml").read_text(encoding="utf-8")
    nested = work_directory / "nested"
    nested.mkdir()
    (nested / "base.nml").write_text(configuration, encoding="utf-8")
    (work_directory / "xnet.nml").write_text(
        "&xnet_config\n include = 'nested/base.nml'\n/\n", encoding="utf-8"
    )
    result = _run_raw_configuration(xnet_executable, work_directory, xnet_timeout)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "nzone = 10" in (work_directory / "xnet.resolved.nml").read_text(encoding="utf-8")


@pytest.mark.parametrize(
    ("configuration", "expected"),
    (
        ("&xnet_config\n unknown_setting = 1\n/\n", "malformed or unknown xnet_config namelist"),
        ("&xnet_config\n include = 'child.nml'\n/\n", "xnet.nml include cycle"),
    ),
)
def test_namelist_rejects_unknown_variables_and_include_cycles(
    xnet_executable: Path, xnet_timeout: float, tmp_path: Path,
    configuration: str, expected: str,
) -> None:
    work_directory = tmp_path / "invalid"
    work_directory.mkdir()
    (work_directory / "xnet.nml").write_text(configuration, encoding="utf-8")
    if "child.nml" in configuration:
        (work_directory / "child.nml").write_text(
            "&xnet_config\n include = 'xnet.nml'\n/\n", encoding="utf-8"
        )
    result = _run_raw_configuration(xnet_executable, work_directory, xnet_timeout)
    assert result.returncode != 0
    assert expected in result.stdout + result.stderr


def test_namelist_rejects_excessive_include_depth(
    xnet_executable: Path, xnet_timeout: float, tmp_path: Path
) -> None:
    work_directory = tmp_path / "too-deep"
    work_directory.mkdir()
    filenames = ["xnet.nml", *(f"layer{index}.nml" for index in range(16))]
    for current, following in zip(filenames, filenames[1:]):
        (work_directory / current).write_text(
            f"&xnet_config\n include = '{following}'\n/\n", encoding="utf-8"
        )
    (work_directory / filenames[-1]).write_text("&xnet_config\n/\n", encoding="utf-8")
    result = _run_raw_configuration(xnet_executable, work_directory, xnet_timeout)
    assert result.returncode != 0
    assert "xnet.nml include depth limit exceeded" in result.stdout + result.stderr
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
