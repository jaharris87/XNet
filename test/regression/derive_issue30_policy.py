#!/usr/bin/env python3
"""Deterministically derive the Issue #30 policy or its audit report.

This developer-facing tool accepts the three retained parsed endpoint records
as inputs and only writes JSON to standard output.  It cannot create or
replace a characterization reference or policy file.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import sys


CONFIGURATIONS = ("mac-gnu16", "mac-llvm", "etacar-gnu16")
CASES = (
    "tnsn_alpha",
    "heat_alpha",
    "tnsn_torch47",
    "heat_sn160",
    "bdf_sn160",
)
SCALARS = (
    "target_time",
    "achieved_time",
    "temperature_gk",
    "density",
    "electron_fraction",
)
OUTCOMES = {
    "tnsn_alpha": "configuration-stable",
    "heat_alpha": "configuration-stable",
    "tnsn_torch47": "configuration-stable",
    "heat_sn160": "wider-empirical",
    "bdf_sn160": "wider-empirical",
}
DERIVATION_REPORT_SHA256 = "424b7bb022308e30c12aef814b5e1bed9acbaecca2289766c7892400ae88eee0"


def printed_decimal_unit(value: float) -> float:
    """Return the final `E`-format decimal unit used by Issue #30 output."""

    if value == 0.0:
        return 1.0e-15
    return 10.0 ** (math.floor(math.log10(abs(value))) - 7)


def limit(canonical: float, observations: list[float]) -> tuple[str, float, float, float]:
    maximum = max(abs(value - canonical) for value in observations)
    unit = printed_decimal_unit(canonical)
    if maximum == 0.0:
        return "exact", 0.0, maximum, unit
    return "absolute", 1.5 * maximum + 0.5 * unit, maximum, unit


def l1_linf(canonical: dict[str, float], observed: dict[str, float]) -> tuple[float, float]:
    errors = [abs(observed[name] - value) for name, value in canonical.items()]
    return sum(errors), max(errors)


def selected_species(repository: Path, case_name: str, zone: int) -> tuple[str, ...]:
    sys.path.insert(0, str(repository / "test" / "regression"))
    from xnet_regression import (  # pylint: disable=import-outside-toplevel
        bdf_sn160_case,
        comparison_species_for_zone,
        heat_alpha_case,
        heat_sn160_case,
        load_reference,
        tnsn_alpha_case,
        tnsn_torch47_case,
    )

    factories = {
        "tnsn_alpha": tnsn_alpha_case,
        "heat_alpha": heat_alpha_case,
        "tnsn_torch47": tnsn_torch47_case,
        "heat_sn160": heat_sn160_case,
        "bdf_sn160": bdf_sn160_case,
    }
    case = factories[case_name](repository)
    reference = load_reference(case.reference)
    return comparison_species_for_zone(case.expected_species, reference.mass_fractions[zone])


def representative(records: list[dict[str, object]], case: str) -> dict[str, object]:
    return next(record for record in records if record["case"] == case and record["run"] == "complete-1")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("repository", type=Path)
    parser.add_argument("mac_gnu16", type=Path)
    parser.add_argument("mac_llvm", type=Path)
    parser.add_argument("etacar_gnu16", type=Path)
    parser.add_argument("--report", action="store_true")
    args = parser.parse_args()
    paths = dict(zip(CONFIGURATIONS, (args.mac_gnu16, args.mac_llvm, args.etacar_gnu16), strict=True))
    records = {
        name: json.loads(path.read_text(encoding="utf-8"))["records"]
        for name, path in paths.items()
    }
    policy_cases: dict[str, object] = {}
    report_cases: dict[str, object] = {}
    for case_name in CASES:
        for configuration in CONFIGURATIONS:
            repetitions = [
                record for record in records[configuration] if record["case"] == case_name
            ]
            if len(repetitions) != 3 or any(
                record["states"] != repetitions[0]["states"]
                for record in repetitions[1:]
            ):
                raise RuntimeError(
                    f"Issue #30 records are not repeatable at parsed precision: "
                    f"{configuration} {case_name}"
                )
        canonical_record = representative(records["mac-gnu16"], case_name)
        canonical_states = {state["zone"]: state for state in canonical_record["states"]}
        case_observations = [
            record for configuration in CONFIGURATIONS for record in records[configuration]
            if record["case"] == case_name
        ]
        policy_zones: dict[str, object] = {}
        report_zones: dict[str, object] = {}
        for zone, canonical in canonical_states.items():
            observations = [
                state for record in case_observations for state in record["states"]
                if state["zone"] == zone
            ]
            row_observations = [
                next(
                    state
                    for state in representative(records[configuration], case_name)["states"]
                    if state["zone"] == zone
                )
                for configuration in CONFIGURATIONS
            ]
            scalar_limits = {}
            scalar_report = {}
            for field in SCALARS:
                mode, allowed, maximum, unit = limit(
                    canonical[field], [state[field] for state in row_observations]
                )
                scalar_limits[field] = {"comparison": mode, "allowed_difference": allowed}
                scalar_report[field] = {
                    "canonical": canonical[field],
                    "observations": [state[field] for state in row_observations],
                    "maximum_absolute_deviation": maximum,
                    "printed_decimal_unit": unit,
                    "candidate_limit": allowed,
                }
            selected = selected_species(args.repository, case_name, int(zone))
            species_limits = {}
            species_report = {}
            for species in selected:
                mode, allowed, maximum, unit = limit(
                    canonical["mass_fractions"][species],
                    [state["mass_fractions"][species] for state in row_observations],
                )
                species_limits[species] = {"comparison": mode, "allowed_difference": allowed}
                species_report[species] = {
                    "canonical": canonical["mass_fractions"][species],
                    "observations": [state["mass_fractions"][species] for state in row_observations],
                    "maximum_absolute_deviation": maximum,
                    "printed_decimal_unit": unit,
                    "candidate_limit": allowed,
                }
            norm_observations = [l1_linf(canonical["mass_fractions"], state["mass_fractions"]) for state in row_observations]
            l1_maximum = max(item[0] for item in norm_observations)
            linf_maximum = max(item[1] for item in norm_observations)
            sum_units = sum(printed_decimal_unit(value) for value in canonical["mass_fractions"].values())
            max_unit = max(printed_decimal_unit(value) for value in canonical["mass_fractions"].values())
            l1_mode = "exact" if l1_maximum == 0.0 else "absolute"
            linf_mode = "exact" if linf_maximum == 0.0 else "absolute"
            l1_limit = 0.0 if l1_mode == "exact" else 1.5 * l1_maximum + 0.5 * sum_units
            linf_limit = 0.0 if linf_mode == "exact" else 1.5 * linf_maximum + 0.5 * max_unit
            sums = [sum(state["mass_fractions"].values()) for state in row_observations]
            sum_mode, sum_limit, sum_maximum, sum_unit = limit(
                sum(canonical["mass_fractions"].values()), sums
            )
            policy_zones[str(zone)] = {
                "scalar_limits": scalar_limits,
                "selected_species_limits": species_limits,
                "l1_limit": {"comparison": l1_mode, "allowed_difference": l1_limit},
                "linf_limit": {"comparison": linf_mode, "allowed_difference": linf_limit},
                "printed_sum_limit": {"comparison": sum_mode, "allowed_difference": sum_limit},
            }
            report_zones[str(zone)] = {
                "scalar_limits": scalar_report,
                "selected_species_limits": species_report,
                "l1": {
                    "observations": [item[0] for item in norm_observations],
                    "maximum_absolute_deviation": l1_maximum,
                    "printed_unit_allowance": 0.5 * sum_units,
                    "candidate_limit": l1_limit,
                },
                "linf": {
                    "observations": [item[1] for item in norm_observations],
                    "maximum_absolute_deviation": linf_maximum,
                    "printed_unit_allowance": 0.5 * max_unit,
                    "candidate_limit": linf_limit,
                },
                "printed_composition_sum": {
                    "canonical": sum(canonical["mass_fractions"].values()),
                    "observations": sums,
                    "maximum_absolute_deviation": sum_maximum,
                    "printed_decimal_unit": sum_unit,
                    "candidate_limit": sum_limit,
                },
            }
        policy_cases[case_name] = {
            "case": case_name,
            "classification": OUTCOMES[case_name],
            "zones": policy_zones,
        }
        report_cases[case_name] = {"observation_count": len(case_observations), "zones": report_zones}
    hashes = {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in paths.items()}
    output = {
        "policy_schema": "xnet-empirical-portability-v1",
        "characterization_status": "characterization-only; empirical software-regression envelope, not scientific validation",
        "canonical_configuration": "mac-gnu16",
        "supported_empirical_configurations": list(CONFIGURATIONS),
        "issue30_source_revision": "96277db1cd466015f4f510628b23c312f5b985df",
        "derivation": {
            "formula": "limit = 1.5 * maximum absolute deviation from mac-gnu16 + 0.5 * final printed decimal unit",
            "safety_multiplier": 1.5,
            "printed_unit_allowance": "one half of the final printed decimal unit; complete-vector L1 uses half the sum and L-infinity half the maximum of species units",
            **({} if args.report else {"report_sha256": DERIVATION_REPORT_SHA256}),
        },
        "study_inputs": {"observation_count": 45, "endpoint_sha256": hashes},
        "cases": report_cases if args.report else policy_cases,
    }
    json.dump(output, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
