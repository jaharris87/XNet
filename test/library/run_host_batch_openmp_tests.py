#!/usr/bin/env python3
"""Compare fixed logical public-API batches with application OpenMP outer loops.

All physical fields, attempted counters, accepted-step maxima, and NSE species
are compared exactly with serial calls into the same archive. Differences are
reported with magnitudes; this test does not establish new numerical tolerances.
Per-call times are checked for finite nonnegative values, never speedup.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import os
import platform
import shlex
import shutil
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load(name: str, path: Path):
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def parse(text: str, library_parser) -> dict:
    result = {"states": library_parser.states(text), "calls": {}, "steps": {}, "status": {},
              "messages": {}, "attempts": {}, "nse": {}, "metadata": [], "densities": {}}
    for line in text.splitlines():
        parts = line.split()
        if not parts:
            continue
        kind = parts[0]
        if kind == "CALL":
            require(len(parts) == 10 and parts[1] not in result["calls"], f"invalid CALL: {line}")
            b, c, owner, team, n, nids = map(int, parts[2:8])
            require(nids == 4, "zone_id requires [i,j,k,block]")
            result["calls"][parts[1]] = {"batch": b, "call": c, "owner": owner, "team": team,
                                         "n": n, "nids": nids, "dt": float(parts[8]), "mask": parts[9]}
        elif kind in ("STEPS", "STATUS"):
            result[{"STEPS": "steps", "STATUS": "status"}[kind]][parts[1]] = int(parts[2])
        elif kind == "MESSAGE":
            result["messages"][parts[1]] = " ".join(parts[2:])
        elif kind == "ATTEMPTS":
            result["attempts"][parts[1]] = tuple(map(int, parts[2:]))
        elif kind == "HOST_NSE":
            b, phase, owner, team = map(int, parts[1:5])
            require((b, phase) not in result["nse"], f"duplicate NSE record: {line}")
            result["nse"][(b, phase)] = {"owner": owner, "team": team, "x": tuple(map(float, parts[5:]))}
        elif kind == "META":
            result["metadata"].append(tuple(parts[1:]))
        elif kind == "DENSITY":
            result["densities"][parts[1]] = tuple(map(float, parts[2:]))
        elif kind == "TIMING":
            require(len(parts) == 15 and all(math.isfinite(float(v)) and float(v) >= 0 for v in parts[2:]),
                    f"invalid per-call stage times: {line}")
    return result


def differences(left, right, path: str = "") -> list[dict]:
    """Report exact differences, including zeros and trace abundances, without a tolerance."""
    if type(left) is not type(right):
        return [{"field": path, "serial": left, "parallel": right}]
    if isinstance(left, dict):
        if left.keys() != right.keys():
            return [{"field": path, "serial_keys": list(left), "parallel_keys": list(right)}]
        return [d for k in left for d in differences(left[k], right[k], f"{path}/{k}")]
    if isinstance(left, (list, tuple)):
        if len(left) != len(right):
            return [{"field": path, "serial_length": len(left), "parallel_length": len(right)}]
        return [d for i, (a, b) in enumerate(zip(left, right)) for d in differences(a, b, f"{path}/{i}")]
    if left == right:
        return []
    entry = {"field": path, "serial": left, "parallel": right}
    if isinstance(left, (int, float)) and isinstance(right, (int, float)):
        entry["absolute_difference"] = abs(left - right)
        entry["relative_difference"] = abs(left - right) / max(abs(left), abs(right)) if left or right else 0
    return [entry]


def comparable(parsed: dict) -> dict:
    return {"states": parsed["states"], "steps": parsed["steps"], "status": parsed["status"], "messages": parsed["messages"],
            "metadata": parsed["metadata"], "densities": parsed["densities"],
            "calls": {key: {k: v for k, v in call.items() if k not in ("owner", "team")}
                      for key, call in parsed["calls"].items()},
            "nse": {str(key): value["x"] for key, value in parsed["nse"].items()}}


def check_owners(parsed: dict, threads: int, *, failure: bool = False) -> dict:
    visits = Counter(call["owner"] for call in parsed["calls"].values())
    require(set(visits) == set(range(threads)), f"not every actual worker called xnet_burn_batch: {visits}")
    require(all(call["team"] == threads for call in parsed["calls"].values()), "actual API caller team differs")
    require(all(count == (1 if failure else 48 // threads) for count in visits.values()),
            f"unexpected/repeated worker calls: {visits}")
    for b in {call["batch"] for call in parsed["calls"].values()}:
        calls = [call for call in parsed["calls"].values() if call["batch"] == b]
        require(len({call["owner"] for call in calls}) == 1, f"logical batch {b} migrated within its outer-loop iteration")
        require(len(calls) == (1 if failure else 6), f"logical batch {b} did not execute every call")
    nse_visits = {}
    if parsed["nse"]:
        for phase in (1, 2):
            owners = Counter(row["owner"] for (b, p), row in parsed["nse"].items() if p == phase)
            require(set(owners) == set(range(threads)) and all(n == 8 // threads for n in owners.values()),
                    f"NSE phase {phase} did not use every worker: {owners}")
            require(all(row["team"] == threads for (b, p), row in parsed["nse"].items() if p == phase),
                    "NSE actual caller team differs")
            nse_visits[phase] = dict(owners)
    return {"burn_calls_by_worker": dict(visits), "nse_calls_by_worker_and_phase": nse_visits,
            "logical_batch_owners": {b: next(call["owner"] for call in parsed["calls"].values() if call["batch"] == b)
                                     for b in sorted({call["batch"] for call in parsed["calls"].values()})}}


def histories(case: Path, parsed: dict, output_parser) -> dict:
    """Associate histories by complete initial physical state and duration, independent of file order/worker."""
    expected = {}
    for label, call in parsed["calls"].items():
        initial = parsed["states"]["input_" + label]
        for lane in range(call["n"]):
            if call["mask"][lane] != "T":
                continue
            row = initial[lane]
            key = (parsed["densities"][label][lane], row[0] * 1e-9,
                   tuple(x / float(meta[1]) for x, meta in zip(row[9:], parsed["metadata"])), call["dt"])
            require(key not in expected, f"history input signature is ambiguous: {label}, lane {lane+1}")
            expected[key] = (label, lane + 1)
    traces = {}
    binary_files = sorted(p for p in case.glob("ts*") if p.is_file())
    require(len(binary_files) == len(expected), f"wrong history count in {case}: {len(binary_files)} != {len(expected)}")
    names = [m[0] for m in parsed["metadata"]]
    selected = [names.index(name) for name in ("c12", "o16")]
    ascii_files = {p.name for p in case.glob("ev*") if p.is_file()}
    require(ascii_files == {"ev" + p.name[2:] for p in binary_files}, f"binary/ASCII inventory differs: {case}")
    for path in binary_files:
        trace = output_parser.binary(path)
        first, last = trace["steps"][0], trace["steps"][-1]
        # Existing output checks allow last-time roundoff. Identity uses the unique initial density/T/y;
        # duration then receives the same 1e-12 relative / 1e-18 second format check.
        matches = [key for key in expected if key[:3] == (first["rho"], first["t9"], first["y"])
                   and math.isclose(key[3], last["time"], rel_tol=1e-12, abs_tol=1e-18)]
        require(len(matches) == 1, f"cannot identify history by initial state/duration: {path}")
        label, lane = expected[matches[0]]
        call = parsed["calls"][label]
        batch = call["batch"]
        ids = (100*batch+lane, -7-batch, 9000+batch, 40+lane)
        require(trace["zone_id"] == ids, f"history caller zone IDs differ: {path}")
        identity = f"{label}_lane{lane}"
        require(identity not in traces, f"duplicate history for {identity}: {path}")
        final = parsed["states"][label][lane - 1]
        require(tuple(a*y for a, y in zip(trace["a"], last["y"])) == tuple(final[9:]), f"history final full X differs: {path}")
        if trace["controls"][-2]:
            require(last["t9"] * 1e9 == final[0], f"history final temperature differs: {path}")
        require(all(step["rho"] == first["rho"] for step in trace["steps"]), f"history density changed: {path}")
        output_parser.check_ascii(case / ("ev" + path.name[2:]), trace, names, selected)
        traces[identity] = {"headers": [row.hex() for row in trace["headers"]], "steps": trace["steps"],
                            "raw_steps_sha256": [hashlib.sha256(row).hexdigest() for row in trace["raw_steps"]],
                            "ascii": (case / ("ev" + path.name[2:])).read_text()}
    require(not list(case.glob("fort.*")), f"implicit Fortran output files: {case}")
    return traces


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--consumer", type=Path, required=True)
    parser.add_argument("--library-config", type=Path, required=True)
    parser.add_argument("--net-setup", type=Path, required=True)
    parser.add_argument("--work-dir", type=Path, default=Path("build/host-batch-runs"))
    parser.add_argument("--serial-only", action="store_true", help="safe fixture check with an old OPENMP_MODE=OFF archive")
    parser.add_argument("--histories", action="store_true", help="also compare complete itsout=2 SN160/BDF histories")
    args = parser.parse_args()
    root, exe, config, setup = [path.resolve(strict=True) for path in (args.root, args.consumer, args.library_config, args.net_setup)]
    args.work_dir.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="host-batch-", dir=args.work_dir.resolve()))
    print(f"Application outer-batch OpenMP work: {work}", flush=True)
    settings = dict(line.split(":=", 1) for line in config.read_text().splitlines() if ":=" in line)
    settings = {key.strip(): value.strip() for key, value in settings.items()}
    archive = Path(settings["XNET_ARCHIVE"])
    build_record = config.parent / "config.txt"
    if not args.serial_only:
        require(build_record.is_file() and "OPENMP_MODE=ON" in build_record.read_text().splitlines(),
                "parallel calls require an OPENMP_MODE=ON library record; use --serial-only for the old OFF archive")
        require("-DXNET_GPU" not in settings["XNET_CPPFLAGS"], "this runner qualifies CPU host workers only")
    commands = []
    def run(argv: list[str], cwd: Path, log: Path, *, threads: int = 1, stdin: str | None = None) -> str:
        environment = dict(os.environ, OMP_NUM_THREADS=str(threads), OMP_DYNAMIC="FALSE", OMP_MAX_ACTIVE_LEVELS="1")
        completed = subprocess.run(argv, cwd=cwd, env=environment, input=stdin, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True, timeout=240, check=False)
        log.write_text(completed.stdout + f"\nPROCESS_EXIT_STATUS {completed.returncode}\n")
        commands.append({"argv": argv, "cwd": str(cwd), "OMP_NUM_THREADS": threads, "OMP_DYNAMIC": "FALSE",
                         "OMP_MAX_ACTIVE_LEVELS": "1", "returncode": completed.returncode, "log": str(log),
                         "log_sha256": digest(log)})
        (work / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
        require(completed.returncode == 0, f"direct exit {completed.returncode}: {log}")
        return completed.stdout
    source_files = subprocess.check_output(["git", "ls-files", "-z", "source", "make", "Makefile", "Makefile.opt", "Makefile.internal",
                                            "test/library/consumer_fixture.F90", "test/library/run_library_tests.py", "test/library/run_output_tests.py",
                                            "test/Data_alpha", "test/Data_SN160"], cwd=root).decode().split("\0")
    inputs = {name: digest(root / name) for name in source_files if name and (root / name).is_file()}
    inputs.update({str(path): digest(path) for path in (exe, archive, config, setup, root / "tools/starkiller-helmholtz/helm_table.dat",
                   Path(__file__), Path(__file__).with_name("host_batch_openmp_consumer.F90"), Path(__file__).with_name("Makefile"))})
    compiler = subprocess.run(shlex.split(settings["XNET_FC"]) + ["--version"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
    (work / "inputs.json").write_text(json.dumps({"git_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root).decode().strip(),
        "platform": platform.platform(), "compiler_version": compiler.stdout, "compiler_version_status": compiler.returncode,
        "exported_configuration": settings, "build_record": build_record.read_text() if build_record.is_file() else "missing",
        "sha256": inputs}, indent=2) + "\n")
    library_parser = load("library_parser", root / "test/library/run_library_tests.py")
    output_parser = load("output_parser", root / "test/library/run_output_tests.py")
    table = root / "tools/starkiller-helmholtz/helm_table.dat"
    networks = {}
    for network in ("alpha", "SN160"):
        destination = work / ("Data_" + network)
        output_parser.ascii_copy(root / "test" / destination.name, destination)
        run([str(setup)], destination, work / f"setup-{network}.log", stdin=destination.name + "\n")
        require(all((destination / f).is_file() for f in ("sunet", "netwinv", "nets3", "nets4", "match_data")),
                f"network setup outputs missing: {destination}")
        networks[network] = destination
    def case_dir(name: str, network: str) -> Path:
        case = work / name
        case.mkdir()
        (case / networks[network].name).symlink_to(networks[network], target_is_directory=True)
        (case / table.name).symlink_to(table)
        return case
    owners = {}
    def compare(left, right, label: str) -> None:
        diff = differences(left, right)
        if diff:
            path = work / (label + "-differences.json")
            path.write_text(json.dumps(diff, indent=2) + "\n")
            numeric = [d for d in diff if "absolute_difference" in d]
            largest = max(numeric, key=lambda d: d["absolute_difference"]) if numeric else diff[0]
            raise RuntimeError(f"{label}: {len(diff)} exact differences; largest/first {largest}; see {path}")
    for network, solver, heat in (("alpha", 1, 0), ("alpha", 3, 1), ("SN160", 1, 1), ("SN160", 3, 1)):
        label = f"{network}-{'be' if solver == 1 else 'bdf'}-heat{heat}"
        level = 2 if args.histories and network == "SN160" and solver == 3 else 0
        serial_case = case_dir(label + "-serial", network)
        serial = parse(run([str(exe), "Data_"+network, str(solver), str(heat), str(level), "serial"], serial_case, serial_case / "consumer.log"), library_parser)
        require(len(serial["calls"]) == 48 and len(serial["states"]) == 96, f"missing serial calls/states: {label}")
        require(all(call["owner"] == 0 and call["team"] == 1 for call in serial["calls"].values()), "serial reference used a parallel region")
        require(all(serial["states"]["b01_c01"][j][0] > serial["states"]["input_b01_c01"][j][0] for j in range(4)) if heat else True,
                f"self-heating unexercised: {label}")
        if network == "SN160":
            require(len(serial["nse"]) == 16 and all(row[3] > 0 for row in serial["states"]["b01_c01"]), f"NSE/neutrino loss unexercised: {label}")
        serial_histories = histories(serial_case, serial, output_parser) if level else None
        if not args.serial_only:
            for threads in (2, 4):
                parallel_case = case_dir(label + f"-parallel{threads}", network)
                parallel = parse(run([str(exe), "Data_"+network, str(solver), str(heat), str(level), "parallel"],
                                     parallel_case, parallel_case / "consumer.log", threads=threads), library_parser)
                owners[label + f"-{threads}"] = check_owners(parallel, threads)
                compare(comparable(serial), comparable(parallel), label + f"-{threads}")
                if level:
                    compare(serial_histories, histories(parallel_case, parallel, output_parser), label + f"-histories-{threads}")
                print(f"PASS {label}, {threads} actual workers: 48 batch calls, complete same-archive state/counter/step/NSE agreement" +
                      (", complete binary/ASCII histories agree" if level else ""), flush=True)
        else:
            print(f"PASS serial fixture {label}: 48 successful batch calls" + (", complete histories checked" if level else ""), flush=True)
    for solver, mode in ((1, "step"), (3, "integrator")):
        references = {}
        for batch in range(1, 5):
            case = case_dir(f"failure-{solver}-{mode}-serial{batch}", "alpha")
            output = run([str(exe), "Data_alpha", str(solver), "0", "0", "serial-"+mode, str(batch)], case, case / "consumer.log")
            require("HOST_RECEIVED_CONCURRENT_FATAL_BURNS" in output, f"serial failure not returned: {case}")
            parsed = parse(output, library_parser)
            for field in ("status", "steps", "messages", "attempts"):
                references.setdefault(field, {}).update(parsed[field])
        if not args.serial_only:
            for threads in (2, 4):
                case = case_dir(f"failure-{solver}-{mode}-parallel{threads}", "alpha")
                output = run([str(exe), "Data_alpha", str(solver), "0", "0", "parallel-"+mode], case, case / "consumer.log", threads=threads)
                require("HOST_RECEIVED_CONCURRENT_FATAL_BURNS" in output, f"worker failures not returned: {case}")
                parsed = parse(output, library_parser)
                owners[f"failure-{solver}-{mode}-{threads}"] = check_owners(parsed, threads, failure=True)
                expected = {field: {key: value for key, value in rows.items() if key in parsed[field]} for field, rows in references.items()}
                compare(expected, {field: parsed[field] for field in expected}, f"failure-{solver}-{mode}-{threads}")
                require(not list(case.glob("ab_fail_*")) and not list(case.glob("th_fail_*")), f"standalone failure files created: {case}")
                print(f"PASS {mode}, solver {solver}, {threads} workers: separate local lane/zone-ID failure messages and attempted counters", flush=True)
    if not args.serial_only:
        for threads in (2, 4):
            case = case_dir(f"topology-{threads}", "SN160")
            output = run([str(exe), "Data_SN160", "1", "1", "0", "topology"], case, case / "consumer.log", threads=threads)
            require(f"HOST_BATCH_TOPOLOGY_CHECKS_PASSED {threads}" in output, f"topology checks did not complete: {case}")
            rejected = [line.split() for line in output.splitlines() if line.startswith("REJECTED_TEAM ")]
            other_threads = 4 if threads == 2 else 2
            require(Counter(row[1] for row in rejected) == {"dynamic-enabled": 1, "changed-size": other_threads, "nested": 2},
                    f"missing actual topology probes: {case}")
            lifetimes = [list(map(int, line.split()[1:])) for line in output.splitlines() if line.startswith("LIFETIME_NSE ")]
            require(len(lifetimes) == 2*threads and all(
                {row[2] for row in lifetimes if row[0] == lifetime} == set(range(threads))
                and all(row[3] == threads for row in lifetimes if row[0] == lifetime) for lifetime in (1, 2)),
                f"screened NSE did not use every initialized/reinitialized worker: {case}")
            print(f"PASS initialized team {threads}: dynamic, nested, and changed-size calls rejected; state preserved; finalize/reinitialize pass", flush=True)
    (work / "worker-owners.json").write_text(json.dumps(owners, indent=2) + "\n")
    (work / "output-sha256.json").write_text(json.dumps({str(p.relative_to(work)): digest(p) for p in sorted(work.rglob("*"))
                                                       if p.is_file() and not p.is_symlink()}, indent=2) + "\n")
    print("SERIAL_FIXTURE_CHECKS_PASSED" if args.serial_only else "APPLICATION_OUTER_OPENMP_BATCH_CHECKS_PASSED", flush=True)


if __name__ == "__main__":
    main()
