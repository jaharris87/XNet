"""Bounded process contracts for the standalone NSE executable."""

from __future__ import annotations

import math
import re
import shutil
import subprocess
from pathlib import Path

import pytest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
CASE_DIRECTORY = REPOSITORY_ROOT / "test" / "regression" / "cases" / "xnse_sn160"
NETWORK_INPUTS = ("sunet", "netsu", "netweak", "netwinv")
STATE_ROW = re.compile(
    r"^\s*NSE solved\s+"
    r"([+-]?\d+\.\d+E[+-]\d+)\s+"
    r"([+-]?\d+\.\d+E[+-]\d+)\s+"
    r"([+-]?\d+\.\d+E[+-]\d+)\s+",
    re.MULTILINE,
)
COUNTER_ROW = re.compile(r"^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$", re.MULTILINE)
ABUNDANCE_ROW = re.compile(
    r"^\s*([a-z][a-z0-9]*)\s+([+-]?\d+\.\d+E[+-]\d+)\s*$", re.MULTILINE
)


def _prepare_work_directory(tmp_path: Path) -> Path:
    work_directory = tmp_path / "xnse"
    work_directory.mkdir()
    shutil.copy2(CASE_DIRECTORY / "control", work_directory / "control")
    network_directory = work_directory / "Data_SN160"
    network_directory.mkdir()
    source_directory = REPOSITORY_ROOT / "test" / "Data_SN160"
    for filename in NETWORK_INPUTS:
        shutil.copy2(source_directory / filename, network_directory / filename)
    shutil.copy2(
        REPOSITORY_ROOT / "tools" / "starkiller-helmholtz" / "helm_table.dat",
        work_directory / "helm_table.dat",
    )
    return work_directory


def _run_xnse(
    executable: Path, work_directory: Path, input_text: str, timeout: float = 15.0
) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            [str(executable.resolve())],
            cwd=work_directory,
            input=input_text,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        pytest.fail(f"xnse exceeded the {timeout:g}-second process timeout", pytrace=False)


def test_xnse_multirow_output_association(
    xnse_executable: Path, tmp_path: Path
) -> None:
    work_directory = _prepare_work_directory(tmp_path)
    input_text = (CASE_DIRECTORY / "input").read_text(encoding="utf-8")
    result = _run_xnse(xnse_executable, work_directory, input_text)

    assert result.returncode == 0, result.stdout + result.stderr
    diagnostic = (work_directory / "nse_diag01").read_text(encoding="utf-8")
    expected_states = [
        tuple(float(value) for value in line.split()[:3])
        for line in input_text.splitlines()
    ]
    state_matches = tuple(STATE_ROW.finditer(diagnostic))
    actual_states = [
        tuple(float(value) for value in match.groups()) for match in state_matches
    ]
    assert actual_states == expected_states
    expected_species = tuple(
        line.strip()
        for line in (REPOSITORY_ROOT / "test" / "Data_SN160" / "sunet")
        .read_text(encoding="utf-8")
        .splitlines()
        if line.strip()
    )
    for match in state_matches:
        block_end = diagnostic.index("NSE Counters:", match.end())
        abundances = tuple(
            (name, float(value))
            for name, value in ABUNDANCE_ROW.findall(
                diagnostic, match.end(), block_end
            )
        )
        assert tuple(name for name, _ in abundances) == expected_species
        assert all(math.isfinite(value) and value >= 0.0 for _, value in abundances)
        assert math.isclose(
            math.fsum(value for _, value in abundances),
            1.0,
            rel_tol=0.0,
            abs_tol=1.0e-6,
        )
    counters = [
        tuple(int(value) for value in match)
        for match in COUNTER_ROW.findall(diagnostic)
    ]
    assert [row[0] for row in counters] == [1, 2, 3]
    assert all(all(value >= 0 for value in row[1:]) and row[3] > 0 for row in counters)
    assert diagnostic.count("NSE Counters:") == 3
    assert diagnostic.count("Timers:") == 3


@pytest.mark.parametrize(
    ("input_text", "expected_message"),
    [
        ("1.0E+07 9.0\n", "Not enough inputs"),
        ("-1.0E+07 9.0 0.5\n", "NSE ERROR: NR Failed"),
    ],
)
def test_xnse_rejects_bad_state_rows(
    xnse_executable: Path,
    tmp_path: Path,
    input_text: str,
    expected_message: str,
) -> None:
    work_directory = _prepare_work_directory(tmp_path)
    result = _run_xnse(xnse_executable, work_directory, input_text)

    assert result.returncode != 0
    assert expected_message in result.stdout + result.stderr
    diagnostic_path = work_directory / "nse_diag01"
    if diagnostic_path.exists():
        assert not STATE_ROW.search(diagnostic_path.read_text(encoding="utf-8"))
