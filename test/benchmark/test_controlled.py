#!/usr/bin/env python3
"""Focused positive and false-pass checks for controlled benchmark cases."""

from __future__ import annotations

from pathlib import Path
import tempfile

from benchmark import BenchmarkError, load_regression, read_cases
from controlled import (
    ControlledRun,
    expand_uniform_reference,
    make_regression_case,
    materialize_inputs,
    prepare_work_directory,
    reference_relative_path,
    validate_case_dimensions,
    validate_retained_inputs,
)


def require_rejection(callable_object, text: str) -> None:
    try:
        callable_object()
    except BenchmarkError as error:
        if text not in str(error):
            raise RuntimeError(f"unexpected rejection: {error}") from error
    else:
        raise RuntimeError(f"false pass: expected rejection containing {text!r}")


def main() -> None:
    benchmark_directory = Path(__file__).parent
    repository = benchmark_directory.parents[1]
    cases = read_cases(benchmark_directory)
    regression = load_regression(repository / "test/regression/xnet_regression.py")

    alpha = cases["alpha_controlled_scaling"]
    sn160 = cases["sn160_controlled_scaling"]
    require_rejection(
        lambda: validate_case_dimensions(alpha, 1024, 1, True),
        "selected larger networks",
    )
    require_rejection(
        lambda: validate_case_dimensions(alpha, 0, 1, False),
        "positive --zones",
    )
    require_rejection(
        lambda: validate_case_dimensions(alpha, 16, 17, False),
        "cannot exceed",
    )

    run = validate_case_dimensions(sn160, 5, 4, False)
    if run.as_record()["partial_final_batch"] is not True:
        raise RuntimeError("controlled partial-final-batch identity is missing")
    if reference_relative_path(sn160, run).endswith("self-heating.json"):
        raise RuntimeError("self-heating-off run selected the wrong reference")
    heated = validate_case_dimensions(sn160, 4, 4, True)
    if not reference_relative_path(sn160, heated).endswith("self-heating.json"):
        raise RuntimeError("self-heating run did not select its distinct reference")

    with tempfile.TemporaryDirectory(prefix="xnet-controlled-test-") as temporary:
        root = Path(temporary)
        _, inputs = materialize_inputs(root / "inputs", sn160, repository, run)
        reference = benchmark_directory / reference_relative_path(sn160, run)
        regression_case = make_regression_case(
            regression,
            sn160,
            inputs,
            reference,
        )
        compact = regression.load_reference(reference)
        expanded = expand_uniform_reference(regression, compact, regression_case)
        regression.validate_reference_for_case(regression_case, expanded)
        if expanded.expected_zones != (1, 2, 3, 4, 5):
            raise RuntimeError("compact reference did not expand to every zone")

        retained = root / "inputs"
        validate_retained_inputs(
            retained,
            sn160,
            run,
            tuple(compact.mass_fractions[1]),
        )
        control = (retained / "control").read_text(encoding="utf-8")
        required_lines = (
            "5         # of Zones",
            "1         Include Weak Reactions",
            "0         Include self-heating",
            "4         Blocking size for zone loop",
        )
        if any(line not in control for line in required_lines):
            raise RuntimeError("controlled runtime settings are not explicit")

        work = prepare_work_directory(regression_case, root / "work")
        if not (work / "control").is_file() or (work / "controls.nml").exists():
            raise RuntimeError("frozen-source controlled input used the wrong format")
        if not all(
            (work / f"controlled_abundance_{zone}").is_symlink()
            for zone in range(1, 6)
        ):
            raise RuntimeError("controlled repeated-zone inputs were not staged")

        (retained / "control").write_text(
            control.replace(
                "1         Include Weak Reactions",
                "0         Include Weak Reactions",
            ),
            encoding="utf-8",
        )
        require_rejection(
            lambda: validate_retained_inputs(
                retained,
                sn160,
                run,
                tuple(compact.mass_fractions[1]),
            ),
            "retained controlled input mismatch",
        )

    print("controlled benchmark case probes: passed")


if __name__ == "__main__":
    main()
