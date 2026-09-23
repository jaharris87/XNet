#!/usr/bin/env python3
"""Focused checks for controlled-workload input generation."""

from __future__ import annotations

from characterize import abundance_text, control_text


SPECIES = ("n", "p", "d", "t", "he4", "c12", "o16", "ne20", "mg24")


def require_line(text: str, prefix: str, description: str) -> None:
    if not any(
        line.split(maxsplit=1)[0] == prefix and description in line
        for line in text.splitlines()
        if line.split()
    ):
        raise RuntimeError(f"missing control value {prefix}: {description}")


def main() -> None:
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
    print("controlled-workload input probes: passed")


if __name__ == "__main__":
    main()
