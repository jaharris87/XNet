"""End-to-end regression cases for the compiled XNet executable."""

import json
from pathlib import Path

import pytest

from xnet_regression import RegressionFailure, run_and_compare, tnsn_alpha_case


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]


def test_tnsn_alpha(
    xnet_executable: Path, xnet_timeout: float, tmp_path: Path
) -> None:
    case = tnsn_alpha_case(REPOSITORY_ROOT)
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
    assert len(diagnostics["zones"]) == 10
    assert all(
        zone["l1"] == 0.0 and zone["l2"] == 0.0 and zone["linf"] == 0.0
        for zone in diagnostics["zones"]
    )
