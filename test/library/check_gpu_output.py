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
    calls["borrowed_producer_sync"] = (4, "TTTT")
    calls["borrowed_producer_queued"] = (4, "TTTT")
    return calls


def close(actual: float, expected: float, relative: float, absolute: float = 0.0) -> bool:
    return abs(actual - expected) <= absolute + relative * max(abs(actual), abs(expected))


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
    teams = [words for words in lines if words[0] == "GPU_HOST_TEAM"]
    if threads:
        checksum = 128 * 129 * 257 // 6
        require(len(teams) == 37 and all(tuple(map(int, row[-3:])) == (threads, threads, checksum)
                                       for row in teams), "missing/mismatched actual host teams")
    else:
        require(not teams, "unexpected host-team request")
    result = states(text)
    calls = expected_calls()
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
    densities = {words[1]: tuple(map(float, words[2:])) for words in lines if words[0] == "DENSITY"}
    steps = {words[1]: int(words[2]) for words in lines if words[0] == "STEPS"}
    require(set(densities) == set(calls) and set(steps) == set(calls), "missing call density/step record")
    active_calls = [(label, shape) for label, shape in calls.items() if "T" in shape[1]]
    markers = [words for words in lines if words[0] == "GPU_OUTPUT_CALL"]
    require(len(markers) == len(active_calls) == 26, "wrong successful output call count")
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
            require(trace["controls"][-2:] == (heat, solver) and
                    b"XNet API input arrays" in trace["headers"][2] and
                    b"Mass fractions in XNet species order" in trace["headers"][2] and
                    b"Constant conditions; local time 0..dt seconds" in trace["headers"][3],
                    f"controls/input metadata mismatch: {filename}")
            first, last = trace["steps"][0], trace["steps"][-1]
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
    require(lane_files == 92 and {path.name for path in directory.glob("ts*")} == expected_inventory,
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
