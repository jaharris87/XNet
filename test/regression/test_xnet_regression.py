"""Focused tests for the XNet regression runner and comparator."""

from dataclasses import replace
import json
import os
from pathlib import Path
import signal
import subprocess
import sys

import pytest

from xnet_regression import (
    CharacterizationReference,
    CompositionNorms,
    ComparisonFailure,
    ExecutionFailure,
    ParsingFailure,
    RegressionCase,
    SetupFailure,
    Tolerance,
    ToleranceBounds,
    calculate_composition_norms,
    compare_final_states,
    heat_alpha_case,
    load_reference,
    parse_diagnostic,
    prepare_work_directory,
    run_xnet,
    strip_timer_sections,
    tnsn_alpha_case,
    validate_executable,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]


def _fabricated_final_diagnostic(*, timer_total: str = "1.000E-02") -> str:
    """Return invented parser input with no physical or tnsn_alpha meaning."""

    return f"""MyId    0    1
End     1    42 2.0000000E+00 2.0000000E+00 2.0000000E+00 4.0000000E+06 5.0000000E-01
  he4 1.0000000E-01   c12 2.0000000E-01   o16 3.0000000E-01  ne20 0.0000000E+00
 mg24 0.0000000E+00  si28 1.5000000E-01   s32 2.5000000E-01  ar36 0.0000000E+00
 ca40 0.0000000E+00  ti44 0.0000000E+00  cr48 0.0000000E+00  fe52 0.0000000E+00
 ni56 0.0000000E+00  zn60 0.0000000E+00
Counters:  Zone        TS        NR  Jacobian     Deriv CrossSect
              1        42        42        42        43        43
Timers Summary:
        Total      {timer_total}
        Solver     2.000E-03
"""


def _matching_unit_reference() -> CharacterizationReference:
    """Return expectations independently matching the fabricated parser input."""

    fields = {
        name: Tolerance(value, atol=1e-6, rtol=1e-6)
        for name, value in {
            "target_time": 2.0,
            "temperature_gk": 2.0,
            "density": 4.0e6,
            "electron_fraction": 0.5,
        }.items()
    }
    mass_fractions = {
        species: {
            "he4": 0.1,
            "c12": 0.2,
            "o16": 0.3,
            "si28": 0.15,
            "s32": 0.25,
        }.get(species, 0.0)
        for species in (
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
    }
    return CharacterizationReference(
        expected_zones=(1,),
        final_steps={1: 42},
        final_step_atols={1: 2},
        fields={1: fields},
        mass_fractions={1: mass_fractions},
        mass_fraction_tolerances={
            1: {
                "si28": ToleranceBounds(atol=1e-8, rtol=1e-8),
                "s32": ToleranceBounds(atol=1e-8, rtol=1e-8),
            }
        },
        mass_fraction_sum_atols={1: 1e-8},
    )


def _fake_case(tmp_path: Path) -> RegressionCase:
    return RegressionCase(
        name="fake",
        control=tmp_path / "unused-control",
        network_data=tmp_path / "unused-data",
        trajectories=(tmp_path / "unused-trajectory",),
        helm_table=tmp_path / "unused-table",
        reference=tmp_path / "unused-reference",
        expected_zones=(1,),
        expected_species=("he4",),
        network_inputs=("sunet",),
    )


def _make_executable(tmp_path: Path, body: str) -> Path:
    executable = tmp_path / "fake_xnet.py"
    executable.write_text(f"#!{sys.executable}\n{body}\n", encoding="utf-8")
    executable.chmod(0o755)
    return executable


def test_known_good_comparison_passes() -> None:
    states = parse_diagnostic(_fabricated_final_diagnostic(), (1,))
    compare_final_states(states, _matching_unit_reference())


def test_mass_fraction_expectation_comes_from_complete_reference() -> None:
    states = parse_diagnostic(_fabricated_final_diagnostic(), (1,))
    reference = _matching_unit_reference()
    changed_composition = {1: dict(reference.mass_fractions[1])}
    changed_composition[1]["si28"] = 0.16

    with pytest.raises(ComparisonFailure, match="si28 mass fraction"):
        compare_final_states(
            states, replace(reference, mass_fractions=changed_composition)
        )


def test_mass_fraction_tolerance_requires_composition_value(tmp_path: Path) -> None:
    reference_path = tmp_path / "inconsistent-reference.json"
    reference_path.write_text(
        json.dumps(
            {
                "expected_zones": [1],
                "final_step": 42,
                "final_step_atol": 2,
                "fields": {
                    name: {"value": value, "atol": 1e-6, "rtol": 1e-6}
                    for name, value in {
                        "target_time": 2.0,
                        "temperature_gk": 2.0,
                        "density": 4.0e6,
                        "electron_fraction": 0.5,
                    }.items()
                },
                "mass_fractions": {"c12": 1.0},
                "mass_fraction_tolerances": {
                    "si28": {"atol": 1e-8, "rtol": 1e-8}
                },
                "mass_fraction_sum_atol": 1e-8,
            }
        ),
        encoding="utf-8",
    )

    with pytest.raises(SetupFailure, match="no matching composition value: si28"):
        load_reference(reference_path)


def test_zone_specific_reference_values_are_expanded(tmp_path: Path) -> None:
    reference_path = tmp_path / "zone-specific-reference.json"
    reference_path.write_text(
        json.dumps(
            {
                "expected_zones": [1, 2],
                "final_step": {"1": 42, "2": 43},
                "final_step_atol": 2,
                "fields": {
                    name: {
                        "value": {"1": first, "2": second},
                        "atol": 1e-6,
                        "rtol": 1e-6,
                    }
                    for name, (first, second) in {
                        "target_time": (2.0, 1.0),
                        "temperature_gk": (2.0, 3.0),
                        "density": (4.0e6, 8.0e6),
                        "electron_fraction": (0.5, 0.5),
                    }.items()
                },
                "mass_fractions": {
                    "c12": {"1": 0.4, "2": 0.3},
                    "o16": {"1": 0.6, "2": 0.7},
                },
                "mass_fraction_tolerances": {
                    "c12": {
                        "atol": {"1": 1e-8, "2": 2e-8},
                        "rtol": 1e-8,
                    }
                },
                "mass_fraction_sum_atol": {"1": 1e-8, "2": 2e-8},
            }
        ),
        encoding="utf-8",
    )

    reference = load_reference(reference_path)

    assert reference.final_steps == {1: 42, 2: 43}
    assert reference.final_step_atols == {1: 2, 2: 2}
    assert reference.fields[2]["temperature_gk"].value == 3.0
    assert reference.mass_fractions[2]["o16"] == 0.7
    assert reference.mass_fraction_tolerances[2]["c12"].atol == 2e-8
    assert reference.mass_fraction_sum_atols == {1: 1e-8, 2: 2e-8}


def test_zone_specific_reference_requires_every_zone(tmp_path: Path) -> None:
    source = REPOSITORY_ROOT / "test/regression/cases/tnsn_alpha/reference/final_state.json"
    document = json.loads(source.read_text(encoding="utf-8"))
    document["final_step"] = {"1": 2841}
    reference_path = tmp_path / "incomplete-zone-reference.json"
    reference_path.write_text(json.dumps(document), encoding="utf-8")

    with pytest.raises(SetupFailure, match="must define zones"):
        load_reference(reference_path)


@pytest.mark.parametrize("zone", [6.9, "6", True])
def test_reference_rejects_noninteger_zone_identifiers(
    tmp_path: Path, zone: object
) -> None:
    source = REPOSITORY_ROOT / "test/regression/cases/heat_alpha/reference/final_state.json"
    document = json.loads(source.read_text(encoding="utf-8"))
    document["expected_zones"][-1] = zone
    reference_path = tmp_path / "malformed-zone-reference.json"
    reference_path.write_text(json.dumps(document), encoding="utf-8")

    with pytest.raises(SetupFailure, match="must be a list of integers"):
        load_reference(reference_path)


def test_value_within_tolerance_passes() -> None:
    state = parse_diagnostic(_fabricated_final_diagnostic(), (1,))[0]
    reference = _matching_unit_reference()
    policy = {1: dict(reference.fields[1])}
    policy[1]["temperature_gk"] = Tolerance(2.0, atol=0.1, rtol=0.0)
    compare_final_states(
        (replace(state, temperature_gk=2.05),), replace(reference, fields=policy)
    )


def test_value_outside_tolerance_fails() -> None:
    state = parse_diagnostic(_fabricated_final_diagnostic(), (1,))[0]
    reference = _matching_unit_reference()
    policy = {1: dict(reference.fields[1])}
    policy[1]["temperature_gk"] = Tolerance(2.0, atol=0.1, rtol=0.0)
    with pytest.raises(ComparisonFailure, match="temperature_gk"):
        compare_final_states(
            (replace(state, temperature_gk=2.2),), replace(reference, fields=policy)
        )


def test_final_step_within_tolerance_passes() -> None:
    state = parse_diagnostic(_fabricated_final_diagnostic(), (1,))[0]
    compare_final_states((replace(state, step=44),), _matching_unit_reference())


def test_final_step_outside_tolerance_fails() -> None:
    state = parse_diagnostic(_fabricated_final_diagnostic(), (1,))[0]
    with pytest.raises(ComparisonFailure, match="final step 45"):
        compare_final_states((replace(state, step=45),), _matching_unit_reference())


def test_achieved_time_must_reach_target_time() -> None:
    state = parse_diagnostic(_fabricated_final_diagnostic(), (1,))[0]
    with pytest.raises(ComparisonFailure, match="did not reach target time"):
        compare_final_states((replace(state, time=1.9),), _matching_unit_reference())


def test_composition_norms_are_diagnostic_only() -> None:
    state = parse_diagnostic(_fabricated_final_diagnostic(), (1,))[0]
    perturbed_mass_fractions = dict(state.mass_fractions)
    perturbed_mass_fractions["c12"] += 1e-4
    perturbed_mass_fractions["o16"] -= 1e-4
    perturbed = replace(state, mass_fractions=perturbed_mass_fractions)
    reference = _matching_unit_reference()

    diagnostics = calculate_composition_norms((perturbed,), reference)
    assert diagnostics == (
        CompositionNorms(
            zone=1,
            l1=pytest.approx(2e-4),
            l2=pytest.approx(2**0.5 * 1e-4),
            linf=pytest.approx(1e-4),
            linf_species="c12",
        ),
    )
    compare_final_states((perturbed,), reference)


def test_missing_final_output_is_a_parsing_failure() -> None:
    with pytest.raises(ParsingFailure, match="final records"):
        parse_diagnostic("Timers Summary:\n        Total 1.0E-02\n", (1,))


def test_malformed_output_is_a_parsing_failure() -> None:
    diagnostic = _fabricated_final_diagnostic().replace(
        "End     1    42", "End     1    malformed"
    )
    with pytest.raises(ParsingFailure, match="malformed End record"):
        parse_diagnostic(diagnostic, (1,))


@pytest.mark.parametrize("token", ["NaN", "+Inf", "-Infinity"])
def test_nonfinite_output_is_rejected(token: str) -> None:
    diagnostic = _fabricated_final_diagnostic().replace("4.0000000E+06", token)
    with pytest.raises(ParsingFailure, match="non-finite"):
        parse_diagnostic(diagnostic, (1,))


def test_timer_only_variation_is_excluded() -> None:
    first = parse_diagnostic(
        _fabricated_final_diagnostic(timer_total="1.000E-02"), (1,)
    )
    second = parse_diagnostic(
        _fabricated_final_diagnostic(timer_total="9.999E+02"), (1,)
    )
    assert first == second


def test_timer_exclusion_stops_before_unrecognized_content() -> None:
    normalized, count = strip_timer_sections(
        "Timers Summary:\n        Total 1.0E-02\nUnexpected diagnostic row\n"
    )
    assert count == 1
    assert normalized == "Unexpected diagnostic row"


def test_missing_executable_is_a_setup_failure(tmp_path: Path) -> None:
    with pytest.raises(SetupFailure, match="does not exist"):
        validate_executable(tmp_path / "missing-xnet")


def test_nonzero_process_exit_is_an_execution_failure(tmp_path: Path) -> None:
    executable = _make_executable(
        tmp_path,
        "import sys\nprint('captured stdout')\n"
        "print('captured stderr', file=sys.stderr)\nraise SystemExit(7)",
    )
    work_directory = tmp_path / "work"
    work_directory.mkdir()
    with pytest.raises(ExecutionFailure, match="nonzero status 7"):
        run_xnet(
            executable,
            _fake_case(tmp_path),
            work_directory,
            timeout_seconds=2.0,
        )
    assert (work_directory / "xnet.status.txt").read_text() == "return_code=7\n"
    assert (work_directory / "xnet.stdout.txt").read_text() == "captured stdout\n"
    assert (work_directory / "xnet.stderr.txt").read_text() == "captured stderr\n"


def test_signal_termination_is_an_execution_failure(tmp_path: Path) -> None:
    executable = _make_executable(
        tmp_path,
        "import os, signal\nos.kill(os.getpid(), signal.SIGTERM)",
    )
    work_directory = tmp_path / "work"
    work_directory.mkdir()
    with pytest.raises(ExecutionFailure, match=f"signal {signal.SIGTERM}"):
        run_xnet(
            executable,
            _fake_case(tmp_path),
            work_directory,
            timeout_seconds=2.0,
        )


def test_timeout_is_an_execution_failure(tmp_path: Path) -> None:
    executable = _make_executable(tmp_path, "import time\ntime.sleep(2)")
    work_directory = tmp_path / "work"
    work_directory.mkdir()
    with pytest.raises(ExecutionFailure, match="timed out"):
        run_xnet(
            executable,
            _fake_case(tmp_path),
            work_directory,
            timeout_seconds=0.05,
        )
    assert (work_directory / "xnet.status.txt").read_text() == "timeout\n"


def test_zero_exit_without_required_output_is_an_execution_failure(
    tmp_path: Path,
) -> None:
    executable = _make_executable(tmp_path, "raise SystemExit(0)")
    work_directory = tmp_path / "work"
    work_directory.mkdir()
    with pytest.raises(ExecutionFailure, match="required fresh output"):
        run_xnet(
            executable,
            _fake_case(tmp_path),
            work_directory,
            timeout_seconds=2.0,
        )


def test_nonempty_work_directory_is_a_setup_failure(tmp_path: Path) -> None:
    work_directory = tmp_path / "work"
    work_directory.mkdir()
    (work_directory / "net_diag01").write_text("stale", encoding="utf-8")
    with pytest.raises(SetupFailure, match="refusing stale artifacts"):
        prepare_work_directory(tnsn_alpha_case(REPOSITORY_ROOT), work_directory)


def test_network_preprocessing_outputs_stay_in_work_directory(tmp_path: Path) -> None:
    case = tnsn_alpha_case(REPOSITORY_ROOT)
    work_directory = prepare_work_directory(case, tmp_path / "work")
    local_network = work_directory / "Data_alpha"
    assert local_network.is_dir()
    assert not local_network.is_symlink()
    assert {path.name for path in local_network.iterdir()} == set(case.network_inputs)
    assert all((local_network / name).is_symlink() for name in case.network_inputs)

    generated = local_network / "nets3"
    generated.write_bytes(b"generated locally")
    assert generated.is_file()


def test_heat_alpha_stages_all_trajectories_and_expected_outputs(
    tmp_path: Path,
) -> None:
    case = heat_alpha_case(REPOSITORY_ROOT)
    work_directory = prepare_work_directory(case, tmp_path / "work")

    assert len(case.trajectories) == 6
    assert all(
        (work_directory / trajectory.name).is_symlink()
        for trajectory in case.trajectories
    )
    assert case.required_outputs == (
        "net_diag01",
        "ev_heat_alpha_1",
        "ts_heat_alpha_1",
        "ev_heat_alpha_2",
        "ts_heat_alpha_2",
        "ev_heat_alpha_3",
        "ts_heat_alpha_3",
        "ev_heat_alpha_4",
        "ts_heat_alpha_4",
        "ev_heat_alpha_5",
        "ts_heat_alpha_5",
        "ev_heat_alpha_6",
        "ts_heat_alpha_6",
    )


def test_duplicate_trajectory_basenames_are_a_setup_failure(tmp_path: Path) -> None:
    case = tnsn_alpha_case(REPOSITORY_ROOT)
    duplicated = replace(case, trajectories=(case.trajectories[0],) * 2)

    with pytest.raises(SetupFailure, match="trajectory definition"):
        prepare_work_directory(duplicated, tmp_path / "work")


def test_missing_case_input_is_a_setup_failure(tmp_path: Path) -> None:
    case = replace(tnsn_alpha_case(REPOSITORY_ROOT), control=tmp_path / "missing-control")
    with pytest.raises(SetupFailure, match="complete control input"):
        prepare_work_directory(case, tmp_path / "work")


def test_failing_regression_makes_pytest_return_nonzero(tmp_path: Path) -> None:
    executable = _make_executable(tmp_path, "raise SystemExit(9)")
    environment = os.environ.copy()
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    completed = subprocess.run(
        [
            sys.executable,
            "-m",
            "pytest",
            "-q",
            "test/regression/test_regression.py",
            f"--xnet-executable={executable}",
        ],
        cwd=REPOSITORY_ROOT,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
        env=environment,
    )
    assert completed.returncode != 0
    assert "execution failure" in completed.stdout + completed.stderr
