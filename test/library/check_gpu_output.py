#!/usr/bin/env python3
"""Check a completed gpu_consumer itsout=2 run; this does not launch a program.

Read every per-call binary/ASCII record with the existing format checks. Compare
snapshots with inputs/results from the same call, using the GPU consumer's
existing mass-fraction, thermodynamic and weak-loss limits. Separate adaptive
GPU histories are not required to have identical timesteps or counters.
"""
from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

from run_library_tests import states
from run_output_tests import binary, check_ascii, require


def expected_calls() -> dict[str, tuple[int, str]]:
    calls = {}
    for owner in ("owned", "borrowed"):
        for path in ("host", "device", "device_chain"):
            for phase in ("first", "repeat", "short", "hole", "inactive"):
                calls[f"{owner}_{path}_{phase}"] = {
                    "short": (3, "TTT"), "hole": (4, "TFTT"),
                    "inactive": (4, "FFFF"),
                }.get(phase, (4, "TTTT"))
        calls[f"{owner}_short_allocation"] = (1, "T")
    calls["borrowed_producer_sync"] = (4, "TTTT")
    calls["borrowed_producer_queued"] = (4, "TTTT")
    return calls


def close(actual: float, expected: float, relative: float, absolute: float = 0.0) -> bool:
    return (math.isfinite(actual) and math.isfinite(expected) and
            abs(actual - expected) <= absolute + relative * max(abs(actual), abs(expected)))


def check_run(directory: Path, text: str, threads: int = 0) -> dict[str, int]:
    # These are the existing gpu_consumer limits, not new physics acceptance.
    gpu_rtol, mass_atol, loss_rtol = 1e-7, 1e-12, 1e-6
    lines = [line.split() for line in text.splitlines() if line.strip()]
    require(sum(words == ["PROCESS_EXIT_STATUS", "0"] for words in lines) == 1 and
            sum(words[0] == "PROCESS_EXIT_STATUS" for words in lines) == 1, "missing/nonzero direct process status")
    require(sum(words == ["GPU_CONSUMER_CHECKS_COMPLETED"] for words in lines) == 1,
            "GPU consumer did not complete exactly once")
    require(sum(words[0] == "GPU_DEVICE_EXECUTION_CONFIRMED" for words in lines) == 1,
            "missing device-execution assertion")
    cases = [words for words in lines if words[0] == "GPU_OUTPUT_CASE"]
    require(len(cases) == 1 and len(cases[0]) == 4 and cases[0][1] == "2",
            "expected one itsout=2 GPU case")
    solver, heat = map(int, cases[0][2:])
    require(solver in (1, 3) and heat in (0, 1), "invalid GPU case controls")
    result = states(text)
    calls = expected_calls()
    short_allocations = [words for words in lines if words[0] == "GPU_SHORT_ALLOCATION"]
    require(short_allocations == [["GPU_SHORT_ALLOCATION", owner + "_short_allocation", "1", "4"]
                                  for owner in ("owned", "borrowed")],
            "missing/mismatched short scientific allocation and workspace capacity")
    teams = [words for words in lines if words[0] == "GPU_HOST_TEAM"]
    if threads:
        checksum = 128 * 129 * 257 // 6
        expected_teams = ["before_initialize"]
        for owner in ("owned", "borrowed"):
            expected_teams += [owner + "_after_initialize"]
            expected_teams += [label + "_after_burn" for label in calls if label.startswith(owner + "_")]
            expected_teams += [owner + "_after_finalize"]
        require(len(teams) == len(expected_teams) and all(len(row) == 5 for row in teams) and
                [row[1] for row in teams] == expected_teams and
                all(tuple(map(int, row[2:])) == (threads, threads, checksum) for row in teams),
                "missing/mismatched actual host team stages")
    else:
        require(not teams, "unexpected host-team request")
    require(set(result) == set(calls) | {"input_" + label for label in calls},
            "missing, duplicate or unexpected GPU input/result states")
    metadata = [words[1:] for words in lines if words[0] == "META"]
    names = [row[0] for row in metadata]
    require(names and len(names) == len(set(names)) and all(len(row) == 5 for row in metadata),
            "missing or malformed species metadata")
    values = [tuple(map(float, row[1:])) for row in metadata]
    require(all(all(math.isfinite(value) for value in row) and row[0] > 0 and
                row[0].is_integer() and row[1].is_integer() and 0 <= row[1] <= row[0]
                for row in values), "invalid species metadata")
    a, z = tuple(row[0] for row in values), tuple(row[1] for row in values)
    selected = [names.index("c12"), names.index("o16"), len(names)-1]
    density_rows = [words for words in lines if words[0] == "DENSITY"]
    step_rows = [words for words in lines if words[0] == "STEPS"]
    require(len(density_rows) == len(step_rows) == len(calls) and
            all(len(row) >= 3 for row in density_rows) and all(len(row) == 3 for row in step_rows) and
            {row[1] for row in density_rows} == {row[1] for row in step_rows} == set(calls),
            "missing/duplicate call density/step record")
    densities = {words[1]: tuple(map(float, words[2:])) for words in density_rows}
    steps = {words[1]: int(words[2]) for words in step_rows}
    for label, (n, mask) in calls.items():
        require(len(result["input_"+label]) == len(result[label]) == len(densities[label]) == n and
                all(len(row) == len(names)+9 for row in result["input_"+label]+result[label]),
                f"wrong state dimensions: {label}")
        require(all(math.isfinite(value) and value > 0 for value in densities[label]),
                f"invalid input density: {label}")
        require(steps[label] > 0 if "T" in mask else steps[label] == 0,
                f"invalid active/inactive accepted steps: {label}")
    active_calls = [(label, shape) for label, shape in calls.items() if "T" in shape[1]]
    markers = [words for words in lines if words[0] == "GPU_OUTPUT_CALL"]
    require(len(markers) == len(active_calls) == 28, "wrong successful output call count")
    expected_inventory = set()
    lane_files = 0
    for sequence, ((label, (n, mask)), marker) in enumerate(zip(active_calls, markers), 1):
        require(marker == ["GPU_OUTPUT_CALL", str(sequence), label, str(n), mask],
                f"wrong call/lane/sequence mapping: {marker}")
        initial, final = result["input_"+label], result[label]
        require(len(initial) == len(final) == len(densities[label]) == n and
                all(len(row) == len(names)+9 for row in initial+final), f"wrong state dimensions: {label}")
        require(steps[label] > 0, f"missing accepted steps: {label}")
        last_steps = []
        for lane, enabled in enumerate(mask, 1):
            if enabled != "T":
                continue
            filename = f"ts_call{sequence}_lane{lane}"
            expected_inventory.add(filename)
            trace = binary(directory / filename)
            require(trace["a"] == a and trace["z"] == z and trace["ny"] == len(names),
                    f"nuclear metadata mismatch: {filename}")
            zone_id = (101, 7, 11) if label.endswith("_short_allocation") else (lane, 7, 11)
            require(trace.get("zone_id") == zone_id, f"zone ID/lane mismatch: {filename}")
            require(trace["controls"][-2:] == (heat, solver) and
                    b"Mass fractions in XNet species order" in trace["headers"][2] and
                    b"Constant conditions; local time 0..dt seconds" in trace["headers"][3],
                    f"controls/input metadata mismatch: {filename}")
            first, last = trace["steps"][0], trace["steps"][-1]
            require([step["k"] for step in trace["steps"]] == list(range(len(trace["steps"]))) and
                    first["dt"] >= 0 and all(step["dt"] > 0 for step in trace["steps"][1:]),
                    f"missing/invalid accepted timestep: {filename}")
            require(all(step["t9"] > 0 and step["rho"] > 0 for step in trace["steps"]),
                    f"nonpositive thermodynamics: {filename}")
            # Reconstruct t(new)=t(old)+dt, allowing only addition/subtraction
            # roundoff at the recorded binary64 time scale, not an integration tolerance.
            require(all(abs((new["time"]-old["time"])-new["dt"]) <=
                        4*sys.float_info.epsilon*max(abs(old["time"]), abs(new["time"]), abs(new["dt"]))
                        for old, new in zip(trace["steps"], trace["steps"][1:])),
                    f"time/timestep inconsistency: {filename}")
            left, right = initial[lane-1], final[lane-1]
            require(all(close(mass*y, x, gpu_rtol, mass_atol)
                        for mass, y, x in zip(a, first["y"], left[9:])),
                    f"initial complete abundance vector mismatch: {filename}")
            require(all(close(mass*y, x, gpu_rtol, mass_atol)
                        for mass, y, x in zip(a, last["y"], right[9:])),
                    f"final complete abundance vector mismatch: {filename}")
            require(close(first["t9"]*1e9, left[0], gpu_rtol) and
                    all(close(step["rho"], densities[label][lane-1], gpu_rtol) for step in trace["steps"]),
                    f"initial temperature/constant density mismatch: {filename}")
            if heat:
                require(close(last["t9"]*1e9, right[0], gpu_rtol),
                        f"final self-heating temperature mismatch: {filename}")
            else:
                require(all(close(step["t9"]*1e9, left[0], gpu_rtol) for step in trace["steps"]),
                        f"fixed-temperature history mismatch: {filename}")
            require(math.isclose(last["time"], 0.1, rel_tol=1e-12, abs_tol=1e-18),
                    f"wrong local end time: {filename}")
            require(len(trace["steps"]) >= 2 and trace["steps"][-2]["dt"] == right[2],
                    f"penultimate-timestep return mismatch: {filename}")
            loss = sum(step["sqnu"] * step["dt"] for step in trace["steps"][1:])
            require(close(loss, right[3], loss_rtol), f"integrated weak-loss return mismatch: {filename}")
            require(any(any(value != 0 for value in step["flux"]) for step in trace["steps"][1:]),
                    f"nonzero reaction flux unexercised: {filename}")
            check_ascii(directory / filename.replace("ts_", "ev_", 1), trace, names, selected)
            last_steps.append(last["k"])
            lane_files += 1
        require(max(last_steps) == steps[label], f"accepted-step maximum mismatch: {label}")
    require(lane_files == 94 and {path.name for path in directory.glob("ts*")} == expected_inventory,
            "wrong binary file inventory (including invalid/inactive calls)")
    require({path.name for path in directory.glob("ev*")} ==
            {name.replace("ts_", "ev_", 1) for name in expected_inventory}, "wrong ASCII file inventory")
    require(not list(directory.glob("fort.*")), "implicit-unit output created")
    return {"active_calls": len(markers), "binary_files": lane_files, "ascii_files": lane_files,
            "requested_host_threads": threads}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--threads", type=int, default=0)
    args = parser.parse_args()
    require(args.threads >= 0, "negative host-team request")
    result = check_run(args.run_dir, args.log.read_text(), args.threads)
    print("GPU per-call binary/ASCII checks passed:", result)


if __name__ == "__main__":
    main()
