#!/usr/bin/env python3
"""Explore network/state suitability without executing XNet.

This program intentionally emits diagnostic JSON only.  It never creates or
updates the committed reference dataset.  Its candidate list documents the
ex-ante state search performed for issue #41.
"""

from __future__ import annotations

import argparse
import json
from decimal import Decimal, localcontext
from pathlib import Path
from typing import Any

from reference_solver import (
    ReferenceSolveError,
    State,
    build_species,
    composition_norms,
    evaluate,
    solve,
)


CANDIDATE_STATES = (
    ("symmetric_baseline", "1e9", "7", "0.50"),
    ("report_neutron_rich", "1e9", "7", "0.45"),
    ("moderate_neutron_rich", "1e9", "7", "0.48"),
    ("strong_neutron_rich", "1e9", "7", "0.40"),
    ("extreme_neutron_rich", "1e9", "7", "0.35"),
    ("report_hot_low_density", "1e7", "9", "0.50"),
    ("hot_low_density_neutron_rich", "1e7", "9", "0.45"),
    ("hot_low_density_proton_rich", "1e7", "9", "0.55"),
    ("hot_low_density_strong_proton_rich", "1e7", "9", "0.60"),
    ("intermediate_density_proton_rich", "1e8", "7", "0.55"),
    ("proton_rich_low_density", "1e7", "6.5", "0.55"),
    ("cool_low_density_proton_rich", "1e7", "6", "0.55"),
)


def decimal_text(value: Decimal) -> str:
    return format(value, ".12E")


def condition_number(manifest: dict[str, Any], state: State, solution: Any) -> Decimal:
    species = build_species(manifest, state, 50)
    jacobian = evaluate(species, solution.eta_n, solution.eta_p, state.ye).jacobian
    a, b = jacobian[0]
    c, d = jacobian[1]
    determinant = a * d - b * c
    inverse = ((d / determinant, -b / determinant), (-c / determinant, a / determinant))
    norm = max(abs(a) + abs(b), abs(c) + abs(d))
    inverse_norm = max(
        abs(inverse[0][0]) + abs(inverse[0][1]),
        abs(inverse[1][0]) + abs(inverse[1][1]),
    )
    return norm * inverse_norm


def isotope_edge_mass(manifest: dict[str, Any], composition: tuple[Decimal, ...]) -> Decimal:
    neutron_bounds: dict[int, tuple[int, int]] = {}
    for item in manifest["species"]:
        if item["z"] == 0:
            continue
        low, high = neutron_bounds.get(item["z"], (item["n"], item["n"]))
        neutron_bounds[item["z"]] = (min(low, item["n"]), max(high, item["n"]))
    return sum(
        (
            value
            for item, value in zip(manifest["species"], composition, strict=True)
            if item["z"] > 1
            and item["n"] in neutron_bounds[item["z"]]
        ),
        Decimal(0),
    )


def solve_attempts(
    manifest: dict[str, Any], state: State, precision: int, route: str
) -> tuple[Any, list[dict[str, Any]]]:
    offsets = (("0", "0"), ("0.1", "-0.1"), ("2", "-2"), ("-2", "2"))
    attempts = []
    solutions = []
    for offset in offsets:
        try:
            solution = solve(
                manifest, state, precision, route=route, offset=offset
            )
            solutions.append(solution)
            attempts.append(
                {
                    "offset": list(offset),
                    "converged": True,
                    "iterations": solution.iterations,
                }
            )
        except ReferenceSolveError as error:
            attempts.append(
                {"offset": list(offset), "converged": False, "reason": str(error)}
            )
    if not solutions:
        raise ReferenceSolveError(
            f"all {route} preflight starts failed for {state.state_id}"
        )
    return solutions[0], attempts


def analyze(manifest_path: Path, precision: int) -> dict[str, Any]:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    states = []
    for state_id, rho, t9, ye in CANDIDATE_STATES:
        state = State.from_strings(state_id, rho, t9, ye)
        analytic, analytic_attempts = solve_attempts(
            manifest, state, precision, "analytic-newton"
        )
        numeric, numeric_attempts = solve_attempts(
            manifest, state, precision, "numeric-newton"
        )
        route_l1, route_linf = composition_norms(
            analytic.composition, numeric.composition
        )
        dominant = sorted(
            (
                (value, item["name"])
                for item, value in zip(
                    manifest["species"], analytic.composition, strict=True
                )
            ),
            reverse=True,
        )[:8]
        states.append(
            {
                "id": state_id,
                "rho_g_cm3": rho,
                "t9_gk": t9,
                "ye": ye,
                "starting_point_attempts": {
                    "analytic": analytic_attempts,
                    "numeric": numeric_attempts,
                },
                "residuals": {
                    "mass": decimal_text(analytic.mass_residual),
                    "charge": decimal_text(analytic.charge_residual),
                    "xnet_basis_charge": decimal_text(
                        analytic.xnet_charge_residual
                    ),
                },
                "route_difference": {
                    "l1": decimal_text(route_l1),
                    "linf": decimal_text(route_linf),
                },
                "jacobian_condition_inf": decimal_text(
                    condition_number(manifest, state, analytic)
                ),
                "isotope_edge_mass": decimal_text(
                    isotope_edge_mass(manifest, analytic.composition)
                ),
                "smallest_mass_fraction": decimal_text(
                    min(analytic.composition)
                ),
                "dominant": [
                    {"name": name, "mass_fraction": decimal_text(value)}
                    for value, name in dominant
                ],
                "composition": [decimal_text(value) for value in analytic.composition],
            }
        )
    return {
        "manifest": str(manifest_path),
        "network": manifest["network"],
        "precision_decimal_digits": precision,
        "states": states,
    }


def compare_pair(left: dict[str, Any], right: dict[str, Any]) -> dict[str, Any]:
    left_names = json.loads(Path(left["manifest"]).read_text())["species"]
    right_names = json.loads(Path(right["manifest"]).read_text())["species"]
    left_index = {item["name"]: index for index, item in enumerate(left_names)}
    right_index = {item["name"]: index for index, item in enumerate(right_names)}
    comparisons = []
    for left_state, right_state in zip(left["states"], right["states"], strict=True):
        if left_state["id"] != right_state["id"]:
            raise RuntimeError("preflight states differ between network results")
        left_x = [Decimal(value) for value in left_state["composition"]]
        right_x = [Decimal(value) for value in right_state["composition"]]
        shared_difference = [
            abs(left_x[index] - right_x[right_index[name]])
            for name, index in left_index.items()
            if name in right_index
        ]
        right_only_mass = sum(
            (
                right_x[index]
                for name, index in right_index.items()
                if name not in left_index
            ),
            Decimal(0),
        )
        left_only_mass = sum(
            (
                left_x[index]
                for name, index in left_index.items()
                if name not in right_index
            ),
            Decimal(0),
        )
        comparisons.append(
            {
                "id": left_state["id"],
                "shared_species_count": len(set(left_index) & set(right_index)),
                "left_only_mass": decimal_text(left_only_mass),
                "right_only_mass": decimal_text(right_only_mass),
                "shared_l1": decimal_text(sum(shared_difference, Decimal(0))),
                "shared_linf": decimal_text(
                    max(shared_difference, default=Decimal(0))
                ),
            }
        )
    return {
        "left": left["network"]["directory"],
        "right": right["network"]["directory"],
        "states": comparisons,
    }


def compare_networks(results: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        compare_pair(left, right)
        for left_index, left in enumerate(results)
        for right in results[left_index + 1 :]
    ]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifests", type=Path, nargs="+")
    parser.add_argument("--precision", type=int, default=50)
    args = parser.parse_args()
    if args.precision < 35:
        parser.error("preflight precision must be at least 35 decimal digits")
    with localcontext() as context:
        context.prec = args.precision + 30
        results = [analyze(path, args.precision) for path in args.manifests]
    payload = {
        "schema": "xnet-independent-nse-preflight-v1",
        "xnet_executed": False,
        "results": results,
        "pairwise_network_comparisons": compare_networks(results),
    }
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
