#!/usr/bin/env python3
"""Check API preprocessing and per-burn output with real serial CPU library consumers.

Binary records are compared exactly with the same-build direct full_net caller.
ASCII tolerances are one half of the writer's last printed digit, with a small
roundoff allowance. These are format/software checks, not a new physics reference.
"""
from __future__ import annotations

import argparse
import hashlib
import math
import re
import shutil
import struct
import subprocess
import tempfile
from pathlib import Path

GENERATED = ("nets3", "nets4", "match_data", "match_read", "matr_shape", "sparse_ind", "net_desc", "net_diag", "ab_blank")
CALLS = {1: ("first", (1, 3, 4)), 2: ("repeat", (1, 2, 3, 4)),
         3: ("short", (1, 3)), 4: ("after_invalid", (4,)), 5: ("reinitialize", (4,))}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def run(command: list[str], cwd: Path, log: Path, stdin: str | None = None) -> str:
    result = subprocess.run(command, cwd=cwd, input=stdin, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=180, check=False)
    log.write_text(result.stdout + f"\nPROCESS_EXIT_STATUS {result.returncode}\n")
    require(result.returncode == 0, f"exit {result.returncode}: see {log}")
    return result.stdout


def ascii_copy(source: Path, destination: Path, omit: str = "") -> None:
    destination.mkdir()
    for name in ("sunet", "netwinv", "netsu", "netweak"):
        if name != omit and (source / name).is_file():
            shutil.copyfile(source / name, destination / name)
    require(not list(destination.glob("nets[34]")), f"generated data copied into {destination}")
    require(not any(p.is_symlink() for p in destination.iterdir()), f"shared ASCII inputs in {destination}")


def records(path: Path) -> tuple[str, list[bytes]]:
    data = path.read_bytes()
    require(len(data) >= 8, f"empty/truncated binary file: {path}")
    endian = "<" if struct.unpack_from("<i", data)[0] == 320 else ">"
    result = []
    offset = 0
    while offset < len(data):
        require(offset + 8 <= len(data), f"truncated record marker: {path}")
        length = struct.unpack_from(endian + "i", data, offset)[0]
        require(length >= 0 and offset + length + 8 <= len(data), f"truncated record payload: {path}")
        end = offset + 4 + length
        require(struct.unpack_from(endian + "i", data, end)[0] == length, f"record marker mismatch: {path}")
        result.append(data[offset + 4:end])
        offset = end + 4
    return endian, result


def binary(path: Path, *, allow_header_only: bool = False) -> dict:
    endian, rows = records(path)
    require(len(rows) >= (6 if allow_header_only else 7), f"missing binary headers/initial state: {path}")
    require(len(rows[0]) == 320 and len(rows[1]) == 76 and len(rows[2]) == 160 and len(rows[3]) == 160,
            f"six-header layout/Character(80) widths changed: {path}")
    controls = struct.unpack(endian + "5i6d2i", rows[1])
    ny = struct.unpack_from(endian + "i", rows[4])[0]
    require(ny > 0 and len(rows[4]) == 4 + 16 * ny, f"invalid nuclear header: {path}")
    z = struct.unpack_from(endian + f"{ny}d", rows[4], 4)
    a = struct.unpack_from(endian + f"{ny}d", rows[4], 4 + 8 * ny)
    mflx = struct.unpack_from(endian + "i", rows[5])[0]
    require(mflx > 0 and len(rows[5]) == 4 + 8 * mflx, f"invalid flux header: {path}")
    endpoints = struct.unpack_from(endian + f"{2*mflx}i", rows[5], 4)
    require(all(0 <= index <= ny for index in endpoints), f"invalid flux endpoints: {path}")
    steps = []
    for row in rows[6:]:
        require(len(row) == 4 + 8 * (6 + ny + mflx), f"incomplete timestep vector: {path}")
        values = struct.unpack(endian + f"i{6+ny+mflx}d", row)
        require(all(math.isfinite(v) for v in values[1:]), f"nonfinite timestep field: {path}")
        steps.append({"k": values[0], "time": values[1], "t9": values[2], "rho": values[3],
                      "sqnu": values[4], "dt": values[5], "edot": values[6],
                      "y": values[7:7+ny], "flux": values[7+ny:]})
    if steps:
        require(steps[0]["k"] == 0 and steps[0]["time"] == 0, f"missing local initial state: {path}")
        require(all(v == 0 for v in steps[0]["flux"]), f"stale initial flux in a repeated burn: {path}")
        require(all(right["k"] > left["k"] and right["time"] > left["time"]
                    for left, right in zip(steps, steps[1:])), f"nonincreasing accepted times/steps: {path}")
    return {"headers": rows[:6], "raw_steps": rows[6:], "steps": steps,
            "ny": ny, "z": z, "a": a, "mflx": mflx, "controls": controls}


def parsed_log(text: str) -> dict:
    states, calls, densities, metadata = {}, {}, {}, []
    current = None
    for line in text.splitlines():
        words = line.split()
        if not words:
            continue
        if words[0] == "META":
            metadata.append((words[1], int(words[2]), int(words[3]), float(words[4]), float(words[5])))
        elif words[0] == "CALL":
            calls[words[1]] = (float(words[2]), words[3] if len(words) == 4 else "")
        elif words[0] == "DENSITY":
            densities[words[1]] = list(map(float, words[2:]))
        elif words[0] == "STATE":
            current = words[1]
            states[current] = {"ny": int(words[2]), "n": int(words[3]), "zones": {}, "x": {}}
        elif words[0] == "ZONE":
            states[current]["zones"][int(words[1])] = tuple(map(float, words[2:6])) + tuple(map(int, words[6:]))
        elif words[0] == "X":
            states[current]["x"][int(words[1])] = tuple(map(float, words[2:]))
    return {"states": states, "calls": calls, "densities": densities, "metadata": metadata}


def number(text: str) -> float:
    # Fortran ES with a three-digit exponent omits E when its field is narrow.
    return float(re.sub(r"(?<=\d)([+-]\d{3})$", r"E\1", text.strip()))


def printed_close(actual: float, expected: float, digits: int) -> bool:
    if expected == 0:
        return actual == 0
    quantum = 10.0 ** (math.floor(math.log10(abs(expected))) - digits + 1)
    return abs(actual - expected) <= 0.501 * quantum + 2e-15 * abs(expected)


def check_ascii(path: Path, trace: dict, names: list[str]) -> None:
    lines = path.read_text().splitlines()
    require(len(lines) == len(trace["steps"]) + 1, f"ASCII/binary row count mismatch: {path}")
    selected = [names.index("c12"), names.index("o16"), len(names)-1]
    # The missing-name fallback is the standalone final-species rule.
    require([lines[0][69+9*i:78+9*i].strip() for i in range(3)] == [names[i] for i in selected],
            f"ASCII selected-species header/fallback mismatch: {path}")
    widths = (4, 15, 10, 10, 10, 10, 10, 9, 9, 9, 2, 2)
    for line, step in zip(lines[1:], trace["steps"]):
        require(len(line) == sum(widths), f"malformed ASCII row width: {path}")
        fields, offset = [], 0
        for width in widths:
            fields.append(line[offset:offset+width])
            offset += width
        require(int(fields[0]) == step["k"], f"ASCII timestep mismatch: {path}")
        values = list(map(number, fields[1:10]))
        expected = [step[k] for k in ("time", "t9", "rho", "edot", "sqnu", "dt")]
        expected += [trace["a"][i] * step["y"][i] for i in selected]
        require(all(math.isfinite(value) and printed_close(value, target, digits)
                    for value, target, digits in zip(values, expected, (9, 4, 4, 3, 3, 3, 3, 3, 3))),
                f"ASCII time/thermo/energy/loss/timestep/selected abundances differ: {path}")
        require(all(int(field) >= 0 for field in fields[10:]), f"invalid ASCII iteration fields: {path}")


def check_case(case: Path, log: dict, level: int, solver: int, heat: int) -> dict:
    inventory = {f"ts_call{sequence}_lane{lane}" for sequence, (_, lanes) in CALLS.items() for lane in lanes}
    require({p.name for p in case.glob("ts*")} == (inventory if level else set()), f"wrong binary lane/call inventory: {case}")
    ascii_inventory = {name.replace("ts_", "ev_", 1) for name in inventory}
    require({p.name for p in case.glob("ev*")} == (ascii_inventory if level >= 2 else set()), f"wrong ASCII inventory: {case}")
    require(not list(case.glob("fort.*")), f"implicit unit output created in {case}")
    traces = {}
    for name in sorted(inventory if level else ()):
        trace = binary(case / name)
        sequence, lane = map(int, re.fullmatch(r"ts_call(\d+)_lane(\d+)", name).groups())
        label = CALLS[sequence][0]
        initial, final = log["states"]["input_"+label], log["states"][label]
        duration = log["calls"][label][0]
        names = [row[0] for row in log["metadata"]]
        require(trace["ny"] == len(names), f"species count mismatch: {name}")
        require(trace["a"] == tuple(float(row[1]) for row in log["metadata"]) and
                trace["z"] == tuple(float(row[2]) for row in log["metadata"]), f"nuclear A/Z mismatch: {name}")
        require(trace["headers"][0][240:320].decode().strip() == "Data_"+case.name.split("-")[0],
                f"network description lost: {name}")
        require(trace["controls"][-2:] == (heat, solver) and trace["controls"][0] == 9999,
                f"integration controls/header order mismatch: {name}")
        require(b"XNet API input arrays" in trace["headers"][2] and
                b"Mass fractions in XNet species order" in trace["headers"][2] and
                b"Constant conditions; local time 0..dt seconds" in trace["headers"][3],
                f"API input metadata is missing/misleading: {name}")
        first, last = trace["steps"][0], trace["steps"][-1]
        require(first["y"] == tuple(x/a for x, a in zip(initial["x"][lane], trace["a"])), f"initial abundance lane mismatch: {name}")
        require(first["t9"] == initial["zones"][lane][0] * 1e-9 and
                all(step["rho"] == log["densities"][label][lane-1] for step in trace["steps"]),
                f"temperature/density lane mismatch: {name}")
        require(math.isclose(last["time"], duration, rel_tol=1e-12, abs_tol=1e-18), f"burn did not end at local dt: {name}")
        require(tuple(a*y for a, y in zip(trace["a"], last["y"])) == final["x"][lane], f"final complete abundance vector mismatch: {name}")
        if heat:
            require(last["t9"]*1e9 == final["zones"][lane][0], f"final self-heating temperature mismatch: {name}")
        require(any(any(value != 0 for value in step["flux"]) for step in trace["steps"][1:]), f"nonzero accepted reaction flux unexercised: {name}")
        if level >= 2:
            check_ascii(case / name.replace("ts_", "ev_", 1), trace, names)
        traces[name] = trace
    return traces


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--consumer", type=Path, required=True)
    parser.add_argument("--preprocess", type=Path, required=True)
    parser.add_argument("--net-setup", type=Path, required=True)
    parser.add_argument("--work-dir", type=Path, default=Path("build/output-runs"))
    args = parser.parse_args()
    consumer, preprocessor, setup = [str(path.resolve(strict=True)) for path in (args.consumer, args.preprocess, args.net_setup)]
    root = Path(__file__).resolve().parents[2]
    table = root / "tools/starkiller-helmholtz/helm_table.dat"
    require(table.is_file(), f"missing EOS table: {table}")
    args.work_dir.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="output-", dir=args.work_dir.resolve()))
    print(f"API output/preprocessing work: {work}", flush=True)
    prepared = {}
    for network in ("alpha", "SN160"):
        directory = work / f"Data_{network}"
        ascii_copy(root / "test" / directory.name, directory)
        run([setup], directory, work / f"setup-{network}.log", stdin=f"Data_{network}\n")
        prepared[network] = directory

    preprocessing = work / "preprocessing"
    preprocessing.mkdir()
    (preprocessing / table.name).symlink_to(table)
    for network in ("alpha", "SN160"):
        ascii_copy(root / "test" / f"Data_{network}", preprocessing / f"Data_{network}")
    for missing in ("sunet", "netwinv", "netsu"):
        ascii_copy(root / "test/Data_alpha", preprocessing / f"missing_{missing}", omit=missing)
    output = run([preprocessor, "Data_alpha", "Data_SN160", "missing_sunet", "missing_netwinv", "missing_netsu"],
                 preprocessing, preprocessing / "api.log")
    require("PREPROCESS_CHECKS_PASSED" in output, "preprocessing consumer did not finish")
    preprocess_metadata = {iteration: [] for iteration in (1, 2, 3)}
    for line in output.splitlines():
        words = line.split()
        if words and words[0] == "PREPROCESS_META":
            preprocess_metadata[int(words[1])].append(
                (words[2], int(words[3]), int(words[4]), float(words[5]), float(words[6])))
    for network in ("alpha", "SN160"):
        actual = preprocessing / f"Data_{network}"
        # Matching descriptions make all generated binary and text products comparable.
        for name in GENERATED:
            require((actual / name).read_bytes() == (prepared[network] / name).read_bytes(),
                    f"runtime preprocessing differs from standalone net_setup: {network}/{name}")
        before = {name: (digest(actual / name), (actual / name).stat().st_mtime_ns) for name in GENERATED}
        run([preprocessor, f"Data_{network}", "load_only"], preprocessing, preprocessing / f"load-{network}.log")
        after = {name: (digest(actual / name), (actual / name).stat().st_mtime_ns) for name in GENERATED}
        require(before == after, f"iprocess=0 rewrote generated network data: {network}")
    require(not list(preprocessing.glob("fort.*")), "implicit preprocessing output")
    print("PASS runtime preprocessing: missing-file recovery; duplicate init; repeated/different networks; net_setup equivalence", flush=True)

    def new_case(name: str, network: str) -> Path:
        case = work / name
        case.mkdir()
        (case / f"Data_{network}").symlink_to(prepared[network], target_is_directory=True)
        (case / table.name).symlink_to(table)
        return case

    for network, solver, heat in (("alpha", 1, 0), ("alpha", 3, 1), ("SN160", 1, 1), ("SN160", 3, 1)):
        baseline, enabled, reference = None, {}, None
        for level, mode in ((0, "normal"), (1, "normal"), (2, "normal"), (3, "normal"), (2, "reference")):
            label = f"{network}-{solver}-{heat}-{level}-{mode}"
            case = new_case(label, network)
            text = run([consumer, f"Data_{network}", str(solver), str(heat), str(level), mode], case, case / "consumer.log")
            require("OUTPUT_CHECKS_PASSED" in text, f"consumer did not finish: {case}")
            log = parsed_log(text)
            iterations = (1, 2) if network == "alpha" else (3,)
            require(all(preprocess_metadata[i] == log["metadata"] for i in iterations),
                    f"runtime-preprocessed nuclear metadata differs from prepared network: {network}")
            # Same-source diagnostics must not change scientific results, accepted step counts,
            # restart hints, weak loss, or any of the five integrator counters.
            result_lines = [line for line in text.splitlines() if line.startswith(("STATE ", "ZONE ", "X ", "STEPS "))]
            if mode == "reference":
                reference = {p.name: binary(p) for p in case.glob("ts_call*")}
                for _, (call, _) in CALLS.items():
                    require(log["states"][call] == baseline["states"][call], f"direct full_net final results differ: {label}/{call}")
            else:
                if level == 0:
                    baseline = log
                    baseline_lines = result_lines
                else:
                    require(result_lines == baseline_lines, f"itsout changed physical results/counters/steps: {label}")
                enabled[level] = check_case(case, log, level, solver, heat)
        require(set(reference) == set(enabled[1]), f"reference output inventory differs: {network}")
        for name, trace in enabled[1].items():
            for level in (2, 3):
                require(trace["headers"] == enabled[level][name]["headers"] and
                        trace["raw_steps"] == enabled[level][name]["raw_steps"], f"binary output differs by itsout: {name}")
            require(trace["headers"][0:2] == reference[name]["headers"][0:2] and
                    trace["headers"][4:6] == reference[name]["headers"][4:6] and
                    trace["raw_steps"] == reference[name]["raw_steps"],
                    f"complete time/thermo/loss/energy/abundance/flux records differ from direct full_net: {name}")
        if network == "SN160":
            require(any(step["sqnu"] != 0 for trace in enabled[1].values() for step in trace["steps"]), "SN160 loss output unexercised")
        print(f"PASS {network} solver={solver} heat={heat}: itsout=0/1/2/3 physical equality; full records equal direct full_net; ASCII/masks/retention", flush=True)

    for mode in ("open_failure", "collision"):
        case = new_case(f"alpha-{mode}", "alpha")
        text = run([consumer, "Data_alpha", "1", "0", "2", mode], case, case / "consumer.log")
        require("OUTPUT_OPEN_CHECKS_PASSED" in text, f"open-failure checks incomplete: {case}")
        sentinel = case / ("ts_call1_lane3" if mode == "open_failure" else "ts_call1_lane1")
        require(sentinel.read_bytes() == b"DO NOT CLOBBER\n", f"existing output clobbered: {sentinel}")
        if mode == "open_failure":
            partial = binary(case / "ts_call1_lane1", allow_header_only=True)
            require(not partial["steps"], f"rejected open wrote evolution records: {case}")
        expected_binary = {sentinel.name, "ts_call2_lane1", "ts_call2_lane3"}
        expected_ascii = {"ev_call2_lane1", "ev_call2_lane3"}
        if mode == "open_failure":
            expected_binary.add("ts_call1_lane1")
            expected_ascii.add("ev_call1_lane1")
        require({p.name for p in case.glob("ts*")} == expected_binary and
                {p.name for p in case.glob("ev*")} == expected_ascii, f"wrong partial-open inventory: {case}")
        for lane in (1, 3):
            binary(case / f"ts_call2_lane{lane}")
        require(not list(case.glob("fort.*")), f"implicit output on open failure: {case}")
    print("PASS checked partial-open failure/collision: existing files preserved; units closed; next burn uses next sequence", flush=True)

    for solver in (1, 3):
        for mode in ("step_limit", "integrator"):
            case = new_case(f"alpha-{solver}-{mode}", "alpha")
            text = run([consumer, "Data_alpha", str(solver), "0", "2", mode], case, case / "consumer.log")
            require("OUTPUT_FATAL_CHECKS_PASSED" in text, f"fatal output checks incomplete: {case}")
            partial = binary(case / "ts_call1_lane2")
            check_ascii(case / "ev_call1_lane2", partial, [row[0] for row in parsed_log(text)["metadata"]])
            require({p.name for p in case.glob("ts*")} == {"ts_call1_lane2"} and
                    {p.name for p in case.glob("ev*")} == {"ev_call1_lane2"}, f"wrong failed-call inventory: {case}")
            require(partial["steps"][-1]["time"] < 0.1, f"failure unexpectedly wrote completed burn: {case}")
            require(not any(line.startswith("End") for line in text.splitlines()), f"failure wrote successful final output: {case}")
            require(not list(case.glob("fort.*")) and not list(case.glob("ab_fail_*")) and not list(case.glob("th_fail_*")),
                    f"implicit/standalone failure files: {case}")
    print("PASS BE/BDF numerical failures: partial binary prefixes parse; output units closed; host receives fatal status", flush=True)
    print("Real serial CPU API output and preprocessing checks passed", flush=True)


if __name__ == "__main__":
    main()
