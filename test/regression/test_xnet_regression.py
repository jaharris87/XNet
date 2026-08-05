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
    ALPHA_SPECIES,
    CharacterizationReference,
    CompositionNorms,
    ComparisonFailure,
    ExecutionFailure,
    FinalState,
    ParsingFailure,
    RegressionCase,
    SN160_SPECIES,
    SetupFailure,
    Tolerance,
    ToleranceBounds,
    TORCH47_SPECIES,
    calculate_composition_norms,
    comparison_species_for_zone,
    compare_final_states,
    heat_alpha_case,
    heat_sn160_case,
    load_reference,
    parse_diagnostic,
    prepare_work_directory,
    run_xnet,
    strip_timer_sections,
    tnsn_alpha_case,
    tnsn_torch47_case,
    validate_reference_for_case,
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


def _fabricated_diagnostic_with_species(species: tuple[str, ...]) -> str:
    lines = _fabricated_final_diagnostic().splitlines()
    abundance_start = next(
        index for index, line in enumerate(lines) if line.startswith("End")
    ) + 1
    abundance_end = next(
        index for index, line in enumerate(lines) if line.startswith("Counters:")
    )
    abundance_rows = [
        " ".join(
            f"{name:>5} {1.0 / len(species):.7E}"
            for name in species[index : index + 4]
        )
        for index in range(0, len(species), 4)
    ]
    return "\n".join(
        lines[:abundance_start] + abundance_rows + lines[abundance_end:]
    )


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


def _state_from_reference(
    reference: CharacterizationReference, zone: int
) -> FinalState:
    fields = reference.fields[zone]
    return FinalState(
        zone=zone,
        step=reference.final_steps[zone],
        target_time=fields["target_time"].value,
        time=fields["target_time"].value,
        temperature_gk=fields["temperature_gk"].value,
        density=fields["density"].value,
        electron_fraction=fields["electron_fraction"].value,
        mass_fractions=reference.mass_fractions[zone],
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
    states = parse_diagnostic(
        _fabricated_final_diagnostic(), (1,), ALPHA_SPECIES
    )
    compare_final_states(states, _matching_unit_reference())


def test_mass_fraction_expectation_comes_from_complete_reference() -> None:
    states = parse_diagnostic(
        _fabricated_final_diagnostic(), (1,), ALPHA_SPECIES
    )
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
                "mass_fraction_selection": {"1": ["si28"]},
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
                "mass_fraction_selection": {
                    "1": ["c12"],
                    "2": ["c12"],
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


def test_composition_selection_rejects_missing_zone(tmp_path: Path) -> None:
    source = REPOSITORY_ROOT / "test/regression/cases/heat_alpha/reference/final_state.json"
    document = json.loads(source.read_text(encoding="utf-8"))
    document["mass_fraction_selection"].pop("6")
    reference_path = tmp_path / "missing-selection-zone.json"
    reference_path.write_text(json.dumps(document), encoding="utf-8")

    with pytest.raises(SetupFailure, match="missing \\[6\\]"):
        load_reference(reference_path)


def test_composition_selection_rejects_unknown_zone(tmp_path: Path) -> None:
    source = REPOSITORY_ROOT / "test/regression/cases/heat_alpha/reference/final_state.json"
    document = json.loads(source.read_text(encoding="utf-8"))
    document["mass_fraction_selection"]["7"] = document[
        "mass_fraction_selection"
    ]["6"]
    reference_path = tmp_path / "unknown-selection-zone.json"
    reference_path.write_text(json.dumps(document), encoding="utf-8")

    with pytest.raises(SetupFailure, match="unknown \\[7\\]"):
        load_reference(reference_path)


def test_composition_selection_rejects_duplicate_zone_key(tmp_path: Path) -> None:
    reference_path = tmp_path / "duplicate-selection-zone.json"
    reference_path.write_text(
        """{
  "expected_zones": [1],
  "mass_fraction_selection": {
    "1": ["c12"],
    "1": ["c12"]
  }
}
""",
        encoding="utf-8",
    )

    with pytest.raises(SetupFailure, match="duplicate JSON object key: 1"):
        load_reference(reference_path)


def test_composition_selection_rejects_duplicate_species(tmp_path: Path) -> None:
    case = heat_alpha_case(REPOSITORY_ROOT)
    document = json.loads(case.reference.read_text(encoding="utf-8"))
    document["mass_fraction_selection"]["4"].append("o16")
    reference_path = tmp_path / "duplicate-selection-species.json"
    reference_path.write_text(json.dumps(document), encoding="utf-8")

    with pytest.raises(SetupFailure, match="duplicate species: o16"):
        load_reference(reference_path)


def test_composition_selection_rejects_unknown_species(tmp_path: Path) -> None:
    case = heat_alpha_case(REPOSITORY_ROOT)
    document = json.loads(case.reference.read_text(encoding="utf-8"))
    document["mass_fraction_selection"]["1"].append("xe999")
    reference_path = tmp_path / "unknown-selection-species.json"
    reference_path.write_text(json.dumps(document), encoding="utf-8")

    with pytest.raises(SetupFailure, match="no matching composition value: xe999"):
        load_reference(reference_path)


def test_composition_selection_rejects_missing_policy_species(tmp_path: Path) -> None:
    case = heat_alpha_case(REPOSITORY_ROOT)
    document = json.loads(case.reference.read_text(encoding="utf-8"))
    document["mass_fraction_selection"]["4"].remove("o16")
    reference_path = tmp_path / "missing-selection-species.json"
    reference_path.write_text(json.dumps(document), encoding="utf-8")
    reference = load_reference(reference_path)

    with pytest.raises(SetupFailure, match="per-zone composition policy for zone 4"):
        validate_reference_for_case(case, reference)


def test_composition_selection_requires_selected_species_tolerance(
    tmp_path: Path,
) -> None:
    case = heat_alpha_case(REPOSITORY_ROOT)
    document = json.loads(case.reference.read_text(encoding="utf-8"))
    document["mass_fraction_tolerances"].pop("o16")
    reference_path = tmp_path / "missing-selection-tolerance.json"
    reference_path.write_text(json.dumps(document), encoding="utf-8")

    with pytest.raises(SetupFailure, match="no matching tolerance: o16"):
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
    state = parse_diagnostic(
        _fabricated_final_diagnostic(), (1,), ALPHA_SPECIES
    )[0]
    reference = _matching_unit_reference()
    policy = {1: dict(reference.fields[1])}
    policy[1]["temperature_gk"] = Tolerance(2.0, atol=0.1, rtol=0.0)
    compare_final_states(
        (replace(state, temperature_gk=2.05),), replace(reference, fields=policy)
    )


def test_value_outside_tolerance_fails() -> None:
    state = parse_diagnostic(
        _fabricated_final_diagnostic(), (1,), ALPHA_SPECIES
    )[0]
    reference = _matching_unit_reference()
    policy = {1: dict(reference.fields[1])}
    policy[1]["temperature_gk"] = Tolerance(2.0, atol=0.1, rtol=0.0)
    with pytest.raises(ComparisonFailure, match="temperature_gk"):
        compare_final_states(
            (replace(state, temperature_gk=2.2),), replace(reference, fields=policy)
        )


def test_final_step_is_diagnostic_only() -> None:
    state = parse_diagnostic(
        _fabricated_final_diagnostic(), (1,), ALPHA_SPECIES
    )[0]

    compare_final_states(
        (replace(state, step=142),), _matching_unit_reference()
    )


def test_achieved_time_must_reach_target_time() -> None:
    state = parse_diagnostic(
        _fabricated_final_diagnostic(), (1,), ALPHA_SPECIES
    )[0]
    with pytest.raises(ComparisonFailure, match="did not reach target time"):
        compare_final_states((replace(state, time=1.9),), _matching_unit_reference())


def test_composition_norms_are_diagnostic_only() -> None:
    state = parse_diagnostic(
        _fabricated_final_diagnostic(), (1,), ALPHA_SPECIES
    )[0]
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
        parse_diagnostic(
            "Timers Summary:\n        Total 1.0E-02\n", (1,), ALPHA_SPECIES
        )


def test_malformed_output_is_a_parsing_failure() -> None:
    diagnostic = _fabricated_final_diagnostic().replace(
        "End     1    42", "End     1    malformed"
    )
    with pytest.raises(ParsingFailure, match="malformed End record"):
        parse_diagnostic(diagnostic, (1,), ALPHA_SPECIES)


def test_end_and_counter_steps_must_agree() -> None:
    diagnostic = _fabricated_final_diagnostic().replace(
        "1        42        42", "1        43        42"
    )

    with pytest.raises(ParsingFailure, match="does not match its End record"):
        parse_diagnostic(diagnostic, (1,), ALPHA_SPECIES)


@pytest.mark.parametrize("token", ["NaN", "+Inf", "-Infinity"])
def test_nonfinite_output_is_rejected(token: str) -> None:
    diagnostic = _fabricated_final_diagnostic().replace("4.0000000E+06", token)
    with pytest.raises(ParsingFailure, match="non-finite"):
        parse_diagnostic(diagnostic, (1,), ALPHA_SPECIES)


def test_timer_only_variation_is_excluded() -> None:
    first = parse_diagnostic(
        _fabricated_final_diagnostic(timer_total="1.000E-02"), (1,), ALPHA_SPECIES
    )
    second = parse_diagnostic(
        _fabricated_final_diagnostic(timer_total="9.999E+02"), (1,), ALPHA_SPECIES
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


def test_torch47_definition_is_case_driven_and_stages_only_source_inputs(
    tmp_path: Path,
) -> None:
    case = tnsn_torch47_case(REPOSITORY_ROOT)
    work_directory = prepare_work_directory(case, tmp_path / "work")
    local_network = work_directory / "Data_torch47"

    sunet_species = tuple(
        line.strip().lower()
        for line in (case.network_data / "sunet")
        .read_text(encoding="utf-8")
        .splitlines()
        if line.strip()
    )
    assert len(case.expected_species) == 47
    assert case.expected_species == TORCH47_SPECIES == sunet_species
    assert len(set(case.expected_species)) == len(case.expected_species)
    assert {path.name for path in local_network.iterdir()} == set(
        case.network_inputs
    )
    assert all((local_network / name).is_symlink() for name in case.network_inputs)
    reference = load_reference(case.reference)
    assert comparison_species_for_zone(
        case.expected_species, reference.mass_fractions[1]
    ) == (
        "si28",
        "s31",
        "s32",
        "ar36",
        "ca40",
        "ti44",
        "cr48",
        "fe52",
        "co55",
        "ni56",
    )
    assert case.required_outputs == (
        "net_diag01",
        "ev_tnsn_torch47_1",
        "ts_tnsn_torch47_1",
    )


def test_sn160_definition_is_complete_and_stages_only_source_inputs(
    tmp_path: Path,
) -> None:
    case = heat_sn160_case(REPOSITORY_ROOT)
    work_directory = prepare_work_directory(case, tmp_path / "work")
    local_network = work_directory / "Data_SN160"
    sunet_species = tuple(
        line.strip().lower()
        for line in (case.network_data / "sunet")
        .read_text(encoding="utf-8")
        .splitlines()
        if line.strip()
    )

    assert len(case.expected_species) == 160
    assert case.expected_species == SN160_SPECIES == sunet_species
    assert len(set(case.expected_species)) == len(case.expected_species)
    assert {path.name for path in local_network.iterdir()} == set(
        case.network_inputs
    )
    assert all((local_network / name).is_symlink() for name in case.network_inputs)
    assert case.required_outputs == (
        "net_diag01",
        "ev_heat_sn160_1",
        "ts_heat_sn160_1",
        "ev_heat_sn160_2",
        "ts_heat_sn160_2",
        "ev_heat_sn160_3",
        "ts_heat_sn160_3",
        "ev_heat_sn160_4",
        "ts_heat_sn160_4",
        "ev_heat_sn160_5",
        "ts_heat_sn160_5",
        "ev_heat_sn160_6",
        "ts_heat_sn160_6",
    )


def test_case_rejects_sunet_species_mismatch(tmp_path: Path) -> None:
    case = tnsn_alpha_case(REPOSITORY_ROOT)
    network_data = tmp_path / "Data_alpha"
    network_data.mkdir()
    for filename in case.network_inputs:
        source = case.network_data / filename
        destination = network_data / filename
        if filename == "sunet":
            destination.write_text("p\nhe4\n", encoding="utf-8")
        else:
            destination.symlink_to(source.resolve())

    with pytest.raises(SetupFailure, match="network species input does not match"):
        prepare_work_directory(
            replace(case, network_data=network_data), tmp_path / "work"
        )


def test_case_rejects_duplicate_sunet_species(tmp_path: Path) -> None:
    case = tnsn_alpha_case(REPOSITORY_ROOT)
    network_data = tmp_path / "Data_alpha"
    network_data.mkdir()
    for filename in case.network_inputs:
        source = case.network_data / filename
        destination = network_data / filename
        if filename == "sunet":
            destination.write_text("he4\nhe4\n", encoding="utf-8")
        else:
            destination.symlink_to(source.resolve())

    with pytest.raises(SetupFailure, match="empty or contains duplicates"):
        prepare_work_directory(
            replace(case, network_data=network_data), tmp_path / "work"
        )


def test_sn160_parser_rejects_incomplete_and_duplicate_species() -> None:
    incomplete = _fabricated_diagnostic_with_species(SN160_SPECIES[:-1])
    with pytest.raises(ParsingFailure, match="incomplete abundance record"):
        parse_diagnostic(incomplete, (1,), SN160_SPECIES)

    duplicated_species = (SN160_SPECIES[0], *SN160_SPECIES[:-1])
    duplicated = _fabricated_diagnostic_with_species(duplicated_species)
    with pytest.raises(ParsingFailure, match="duplicate abundance"):
        parse_diagnostic(duplicated, (1,), SN160_SPECIES)


def test_torch47_parser_rejects_wrong_species_order() -> None:
    diagnostic = _fabricated_diagnostic_with_species(TORCH47_SPECIES)
    states = parse_diagnostic(diagnostic, (1,), TORCH47_SPECIES)
    assert tuple(states[0].mass_fractions) == TORCH47_SPECIES

    swapped_species = list(TORCH47_SPECIES)
    swapped_species[0], swapped_species[1] = swapped_species[1], swapped_species[0]
    swapped_diagnostic = _fabricated_diagnostic_with_species(tuple(swapped_species))
    with pytest.raises(ParsingFailure, match="unexpected species structure"):
        parse_diagnostic(swapped_diagnostic, (1,), TORCH47_SPECIES)


def test_torch47_reference_rejects_wrong_species_order(tmp_path: Path) -> None:
    case = tnsn_torch47_case(REPOSITORY_ROOT)
    document = json.loads(case.reference.read_text(encoding="utf-8"))
    composition_items = list(document["mass_fractions"].items())
    composition_items[0], composition_items[1] = (
        composition_items[1],
        composition_items[0],
    )
    document["mass_fractions"] = dict(composition_items)
    reference_path = tmp_path / "reordered-reference.json"
    reference_path.write_text(json.dumps(document), encoding="utf-8")

    reference = load_reference(reference_path)
    with pytest.raises(SetupFailure, match="composition reference does not match"):
        validate_reference_for_case(case, reference)


def test_reference_rejects_duplicate_tolerance_species(tmp_path: Path) -> None:
    case = tnsn_torch47_case(REPOSITORY_ROOT)
    source = case.reference.read_text(encoding="utf-8")
    co55_policy = """    "co55": {
      "atol": 5e-12,
      "rtol": 5e-8
    }
"""
    duplicate = (
        co55_policy.rstrip()
        + ',\n    "co55": {"atol": 1.0, "rtol": 1.0}\n'
    )
    assert source.count(co55_policy) == 1
    reference_path = tmp_path / "duplicate-tolerance-reference.json"
    reference_path.write_text(
        source.replace(co55_policy, duplicate), encoding="utf-8"
    )

    with pytest.raises(SetupFailure, match="duplicate JSON object key: co55"):
        load_reference(reference_path)


def test_all_migrated_references_use_per_zone_comparison_species_policy() -> None:
    for case in (
        tnsn_alpha_case(REPOSITORY_ROOT),
        heat_alpha_case(REPOSITORY_ROOT),
        tnsn_torch47_case(REPOSITORY_ROOT),
        heat_sn160_case(REPOSITORY_ROOT),
    ):
        reference = load_reference(case.reference)
        for zone in case.expected_zones:
            expected_selection = comparison_species_for_zone(
                case.expected_species, reference.mass_fractions[zone]
            )
            assert (
                tuple(reference.mass_fraction_tolerances[zone])
                == expected_selection
            )


def test_material_species_policy_does_not_require_silicon_products() -> None:
    cno_species = ("p", "he4", "c12", "n14", "o16", "ne20")
    mass_fractions = {
        "p": 1.0e-6,
        "he4": 5.0e-5,
        "c12": 0.2,
        "n14": 0.3,
        "o16": 0.4,
        "ne20": 0.099949,
    }

    assert comparison_species_for_zone(cno_species, mass_fractions) == (
        "c12",
        "n14",
        "o16",
        "ne20",
    )


def test_per_zone_material_threshold_is_inclusive_and_ordered() -> None:
    species = ("he4", "si28", "c12", "o16")

    assert comparison_species_for_zone(
        species,
        {"he4": 0.2, "si28": 0.0, "c12": 1.0e-4, "o16": 0.7999},
    ) == ("he4", "si28", "c12", "o16")


def test_comparison_anchors_are_retained_per_zone_when_present() -> None:
    assert comparison_species_for_zone(
        ("p", "si28"), {"p": 9.0e-5, "si28": 0.0}
    ) == ("si28",)


def test_heat_alpha_selected_zone_species_perturbation_fails() -> None:
    case = heat_alpha_case(REPOSITORY_ROOT)
    reference = load_reference(case.reference)
    state = _state_from_reference(reference, 4)
    mass_fractions = dict(state.mass_fractions)
    mass_fractions["o16"] += 1.0e-6
    mass_fractions["c12"] -= 1.0e-6

    zone_reference = replace(reference, expected_zones=(4,))
    with pytest.raises(ComparisonFailure, match="zone 4 o16 mass fraction"):
        compare_final_states(
            (replace(state, mass_fractions=mass_fractions),), zone_reference
        )


def test_heat_alpha_same_perturbation_is_diagnostic_only_in_unselected_zone() -> None:
    case = heat_alpha_case(REPOSITORY_ROOT)
    reference = load_reference(case.reference)
    state = _state_from_reference(reference, 3)
    mass_fractions = dict(state.mass_fractions)
    mass_fractions["o16"] += 1.0e-6
    mass_fractions["c12"] -= 1.0e-6
    perturbed = replace(state, mass_fractions=mass_fractions)

    assert "o16" not in reference.mass_fraction_tolerances[3]
    assert "o16" in reference.mass_fraction_tolerances[4]
    assert min(mass_fractions.values()) >= 0.0
    assert sum(mass_fractions.values()) == pytest.approx(
        sum(state.mass_fractions.values()), abs=1.0e-15
    )
    assert calculate_composition_norms((perturbed,), reference)[0].linf == pytest.approx(
        1.0e-6
    )
    compare_final_states((perturbed,), replace(reference, expected_zones=(3,)))


def test_diagnostic_only_species_still_receive_negative_fraction_check() -> None:
    reference = load_reference(heat_alpha_case(REPOSITORY_ROOT).reference)
    state = _state_from_reference(reference, 3)
    mass_fractions = dict(state.mass_fractions)
    transfer = mass_fractions["c12"] + 1.0e-6
    mass_fractions["c12"] -= transfer
    mass_fractions["o16"] += transfer

    zone_reference = replace(reference, expected_zones=(3,))
    with pytest.raises(ComparisonFailure, match="negative mass fractions: c12"):
        compare_final_states(
            (replace(state, mass_fractions=mass_fractions),), zone_reference
        )


def test_diagnostic_only_species_still_receive_composition_sum_check() -> None:
    reference = load_reference(heat_alpha_case(REPOSITORY_ROOT).reference)
    state = _state_from_reference(reference, 3)
    mass_fractions = dict(state.mass_fractions)
    mass_fractions["c12"] += 1.0e-6

    zone_reference = replace(reference, expected_zones=(3,))
    with pytest.raises(ComparisonFailure, match="mass-fraction sum"):
        compare_final_states(
            (replace(state, mass_fractions=mass_fractions),), zone_reference
        )


def test_torch47_network_specific_products_gate_comparison() -> None:
    case = tnsn_torch47_case(REPOSITORY_ROOT)
    reference = load_reference(case.reference)
    fields = reference.fields[1]
    mass_fractions = dict(reference.mass_fractions[1])
    mass_fractions["co55"] += 1.0e-4
    mass_fractions["s31"] -= 1.0e-4
    state = FinalState(
        zone=1,
        step=reference.final_steps[1],
        target_time=fields["target_time"].value,
        time=fields["target_time"].value,
        temperature_gk=fields["temperature_gk"].value,
        density=fields["density"].value,
        electron_fraction=fields["electron_fraction"].value,
        mass_fractions=mass_fractions,
    )

    with pytest.raises(ComparisonFailure, match="co55 mass fraction"):
        compare_final_states((state,), reference)


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
