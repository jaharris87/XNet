"""End-to-end regression cases for the compiled XNet executable."""

import json
import math
from pathlib import Path

import pytest

from xnet_regression import (
    RegressionCase,
    RegressionFailure,
    heat_alpha_case,
    heat_sn160_case,
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
        "diagnostic-only; these norms do not determine pass/fail"
    )
    assert diagnostics["vector"] == (
        "absolute mass-fraction errors for every species in the case"
    )
    assert [zone["zone"] for zone in diagnostics["zones"]] == list(
        case.expected_zones
    )
    for zone in diagnostics["zones"]:
        assert set(zone) == {"zone", "l1", "l2", "linf", "linf_species"}
        assert all(math.isfinite(zone[name]) for name in ("l1", "l2", "linf"))
        assert zone["l1"] >= zone["l2"] >= zone["linf"] >= 0.0
        assert zone["linf_species"] is None or isinstance(
            zone["linf_species"], str
        )

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


def test_tnsn_torch47(
    xnet_executable: Path, xnet_timeout: float, tmp_path: Path
) -> None:
    _run_case(
        xnet_executable,
        xnet_timeout,
        tmp_path,
        tnsn_torch47_case(REPOSITORY_ROOT),
    )
