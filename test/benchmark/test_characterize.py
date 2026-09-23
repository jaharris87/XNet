#!/usr/bin/env python3
"""Focused checks for controlled-workload input generation."""

from __future__ import annotations

import json
from pathlib import Path
import tempfile

from benchmark import BenchmarkError
from characterize import (
    abundance_text,
    add_convergence_history,
    build_characterization_executable,
    control_text,
    run_one,
)


SPECIES = ("n", "p", "d", "t", "he4", "c12", "o16", "ne20", "mg24")


def require_line(text: str, prefix: str, description: str) -> None:
    if not any(
        line.split(maxsplit=1)[0] == prefix and description in line
        for line in text.splitlines()
        if line.split()
    ):
        raise RuntimeError(f"missing control value {prefix}: {description}")


def main() -> None:
    registry = json.loads(
        Path(__file__).with_name("cases.json").read_text(encoding="utf-8")
    )
    controlled = registry["workload_specifications"]["controlled-scaling"]
    history = controlled["thermodynamic_history"]
    if controlled["status"] != "approved-early-plateau-workload":
        raise RuntimeError("controlled workload does not record maintainer approval")
    if history["end_time_seconds"] != 10.0:
        raise RuntimeError("controlled workload duration is not the approved 10 seconds")
    if "not an equilibrium claim" not in history["end_time_policy"]:
        raise RuntimeError("controlled workload misstates the early plateau as equilibrium")

    bdf = control_text("Data_test", SPECIES, True, "bdf", 1.0e-6, 1.0e-10)
    require_line(bdf, "0", "Include Weak Reactions")
    require_line(bdf, "1", "Include Screening")
    require_line(bdf, "3", "Choice of integration Scheme")
    require_line(bdf, "10", "Max. iterations per step")
    require_line(bdf, "3", "Convergence Condition")
    require_line(bdf, "1.00000000E-10", "BDF absolute tolerance")
    require_line(bdf, "1.00000000E-06", "Convergence Criterion")
    require_line(bdf, "1.00000000E-99", "Lower Abundance limit")
    require_line(bdf, "0", "Include self-heating")

    backward_euler = control_text(
        "Data_test", SPECIES, False, "backward-euler", 1.0e-4, 1.0e-7
    )
    require_line(backward_euler, "0", "Include Screening")
    require_line(backward_euler, "1", "Choice of integration Scheme")
    require_line(backward_euler, "5", "Max. iterations per step")
    require_line(backward_euler, "0", "Convergence Condition")
    require_line(backward_euler, "1.00000000E-30", "Lower Abundance limit")

    abundance = abundance_text(SPECIES, {"c12": 0.5, "o16": 0.5})
    if (
        "c12  4.1666667E-02" not in abundance
        or "o16  3.1250000E-02" not in abundance
    ):
        raise RuntimeError("controlled C/O mass fractions were not converted to Y=X/A")

    with tempfile.TemporaryDirectory(prefix="xnet-characterize-test-") as temporary:
        root = Path(temporary)
        substituted = root / "substituted-build"
        (substituted / "bin").mkdir(parents=True)
        (substituted / "bin/xnet").write_text("not XNet\n", encoding="utf-8")
        (substituted / "config.txt").write_text(
            "SOURCE_ROOT=/claimed/source\n", encoding="utf-8"
        )
        try:
            build_characterization_executable(
                root / "source", substituted, root / "build.log"
            )
        except BenchmarkError as error:
            if "fresh, nonexistent --build-dir" not in str(error):
                raise RuntimeError("unexpected substituted-build rejection") from error
        else:
            raise RuntimeError("false pass: substituted characterization executable")

        nonzero = root / "nonzero"
        nonzero.write_text(
            "#!/bin/sh\necho partial-output\necho failed >&2\nexit 7\n",
            encoding="utf-8",
        )
        nonzero.chmod(0o755)
        nonzero_run = root / "nonzero-run"
        nonzero_run.mkdir()
        result = run_one(None, nonzero, nonzero_run, SPECIES, 1.0)
        if result.get("status") != "nonzero-exit" or result.get("return_code") != 7:
            raise RuntimeError("nonzero characterization result was not retained")
        if not all(
            (nonzero_run / name).is_file()
            for name in ("xnet.stdout.txt", "xnet.stderr.txt", "xnet.status.txt")
        ):
            raise RuntimeError("nonzero characterization streams were not retained")

        timeout = root / "timeout"
        timeout.write_text("#!/bin/sh\nsleep 2\n", encoding="utf-8")
        timeout.chmod(0o755)
        timeout_run = root / "timeout-run"
        timeout_run.mkdir()
        result = run_one(None, timeout, timeout_run, SPECIES, 0.01)
        if result.get("status") != "timeout":
            raise RuntimeError("timeout characterization result was not retained")

    convergence = add_convergence_history(
        [
            {
                "status": "success",
                "requested_end_time_seconds": 1.0,
                "mass_fractions": {"c12": 0.5, "o16": 0.5},
            },
            {
                "status": "nonzero-exit",
                "requested_end_time_seconds": 10.0,
                "diagnostic": "intentional failure",
            },
            {
                "status": "success",
                "requested_end_time_seconds": 100.0,
                "mass_fractions": {"c12": 0.5, "o16": 0.5},
            },
        ]
    )
    if not convergence["failed_samples"] or any(
        item["earliest_candidate_seconds"] is not None
        for item in convergence["threshold_sensitivity"]
    ):
        raise RuntimeError("failed sample did not suppress endpoint recommendation")
    print("controlled-workload input probes: passed")


if __name__ == "__main__":
    main()
