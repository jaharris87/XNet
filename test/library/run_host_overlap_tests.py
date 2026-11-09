#!/usr/bin/env python3
"""Optional CPU OpenMP overlap regression and its serialized-evolution control."""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

# Reuse the ordinary caller's complete physical comparison and worker checks.
from run_host_batch_openmp_tests import comparable, check_owners, differences, digest, load, parse, require


def serialize_api(source: Path, destination: Path) -> None:
    text = source.read_text()
    calls = [line for line in text.splitlines()
             if line.strip() == "Call full_net(kstep,loss_work,evolve_status,failed_zone)"]
    require(len(calls) == 1,
            "serialization control requires exactly one preprocessed CPU full_net call")
    call = calls[0]
    indent = call[:len(call) - len(call.lstrip())]
    destination.write_text(text.replace(call, indent + "!$omp critical(xnet_test_serialize_evolution)\n" + call +
                                       "\n" + indent + "!$omp end critical(xnet_test_serialize_evolution)"))


def run_logged(argv: list[str], cwd: Path, log: Path, commands: list[dict], *, threads: int,
               stdin: str | None = None, timeout: float = 60) -> tuple[str, int]:
    environment = dict(os.environ, OMP_NUM_THREADS=str(threads), OMP_DYNAMIC="FALSE", OMP_MAX_ACTIVE_LEVELS="1")
    record = {"argv": argv, "cwd": str(cwd), "OMP_NUM_THREADS": threads, "OMP_DYNAMIC": "FALSE",
              "OMP_MAX_ACTIVE_LEVELS": "1", "timeout_seconds": timeout, "log": str(log)}
    try:
        completed = subprocess.run(argv, cwd=cwd, env=environment, input=stdin, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True, timeout=timeout, check=False)
        output, status = completed.stdout, completed.returncode
        record["returncode"] = status
        log.write_text(output + f"\nPROCESS_EXIT_STATUS {status}\n")
    except subprocess.TimeoutExpired as error:
        output = error.stdout or ""
        if isinstance(output, bytes):
            output = output.decode(errors="replace")
        log.write_text(output + f"\nPROCESS_TIMEOUT after {timeout} seconds\n")
        record["timeout"] = True
        raise RuntimeError(f"process timed out; partial output: {log}") from error
    except OSError as error:
        log.write_text(f"PROCESS_LAUNCH_ERROR {error}\n")
        record["launch_error"] = str(error)
        raise
    finally:
        record["log_sha256"] = digest(log)
        commands.append(record)
        (log.parent.parent / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
    return output, status


def overlap_result(output: str) -> tuple[int, int, int, str]:
    rows = re.findall(r"^XNET_OVERLAP_RESULT\s+(\d+)\s+(\d+)\s+(\d+)\s+([TF])$", output, re.MULTILINE)
    require(len(rows) == 1, f"expected one overlap observation, got {rows}")
    expected, arrivals, maximum, timed_out = rows[0]
    return int(expected), int(arrivals), int(maximum), timed_out


def run_tests(args) -> None:
    root = Path(__file__).resolve().parents[2]
    config = args.library_config.resolve()
    settings = dict(line.split(":=", 1) for line in config.read_text().splitlines() if ":=" in line)
    settings = {key.strip(): value.strip() for key, value in settings.items()}
    build_record = config.parent / "config.txt"
    required = {"OPENMP_MODE=ON", "GPU_MODE=OFF", "EOS=STARKILLER", "MATRIX_SOLVER=dense"}
    require(required <= set(build_record.read_text().splitlines()),
            "overlap test requires CPU OpenMP dense bundled-EOS library")
    executables = {name: getattr(args, name).resolve() for name in ("consumer", "probe", "serialized", "net_setup")}
    args.work_dir.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="overlap-", dir=args.work_dir.resolve()))
    print(f"CPU OpenMP overlap work: {work}", flush=True)
    sources = [root / "source" / name for name in ("xnet_api.F90", "xnet_eos.F90", "xnet_eos_starkiller.F90")]
    sources += [Path(__file__).with_name(name) for name in ("run_host_overlap_tests.py", "host_overlap_eos.F90",
                "host_batch_openmp_consumer.F90", "consumer_fixture.F90", "run_host_batch_openmp_tests.py",
                "run_library_tests.py", "run_output_tests.py", "Makefile")]
    table = root / "tools/starkiller-helmholtz/helm_table.dat"
    inputs = sources + list(executables.values()) + [config, build_record, Path(settings["XNET_ARCHIVE"]), table]
    (work / "inputs.json").write_text(json.dumps({"configuration": settings, "build_record": build_record.read_text(),
        "sha256": {str(path): digest(path) for path in inputs}}, indent=2) + "\n")
    library_parser = load("overlap_library_parser", root / "test/library/run_library_tests.py")
    output_parser = load("overlap_output_parser", root / "test/library/run_output_tests.py")
    network = work / "Data_alpha"
    output_parser.ascii_copy(root / "test/Data_alpha", network)
    commands: list[dict] = []
    output, status = run_logged([str(executables["net_setup"])], network, network / "setup.log", commands,
                                threads=1, stdin="Data_alpha\n")
    require(status == 0, f"network preprocessor failed: {network / 'setup.log'}")
    require(all((network / name).is_file() for name in ("sunet", "netwinv", "nets3", "nets4", "match_data")),
            "network preprocessor outputs missing")
    reference = None
    results = {}
    # Serial calls remain outside a team even though initialization reserves
    # four workers. The negative controls use the very same physical fixture.
    cases = [("consumer", "serial", 4), ("probe", "serial", 4), ("probe", "parallel", 2),
             ("probe", "parallel", 4), ("serialized", "parallel", 2), ("serialized", "parallel", 4)]
    for executable, mode, threads in cases:
        label = f"{executable}-{mode}-{threads}"
        case = work / label
        case.mkdir()
        (case / network.name).symlink_to(network, target_is_directory=True)
        (case / table.name).symlink_to(table)
        output, status = run_logged([str(executables[executable]), "Data_alpha", "3", "1", "0", mode],
                                    case, case / "consumer.log", commands, threads=threads)
        negative = executable == "serialized"
        require(status != 0 if negative else status == 0, f"unexpected direct status {status}: {case}")
        if executable == "consumer":
            require("XNET_OVERLAP_RESULT" not in output, "ordinary consumer unexpectedly contains probe")
        else:
            observed = overlap_result(output)
            expected = (threads, threads, 1, "T") if negative else ((0, 0, 0, "F") if mode == "serial"
                                                                     else (threads, threads, threads, "F"))
            require(observed == expected, f"wrong overlap observation {observed}, expected {expected}: {case}")
            require(("XNET_OVERLAP_FAILED: workers did not overlap inside full_net" in output) == negative,
                    f"wrong overlap failure reason: {case}")
        require(("HOST_BATCH_OPENMP_CHECKS_PASSED" in output) == (not negative), f"wrong completion marker: {case}")
        parsed = parse(output, library_parser)
        require(len(parsed["calls"]) == 48 and len(parsed["states"]) == 96, f"incomplete physical output: {case}")
        if mode == "parallel":
            check_owners(parsed, threads)
        else:
            require(all(call["owner"] == 0 and call["team"] == 1 for call in parsed["calls"].values()),
                    "ordinary serial calls entered a team")
        if reference is None:
            reference = comparable(parsed)
        difference = differences(reference, comparable(parsed))
        if difference:
            (case / "differences.json").write_text(json.dumps(difference, indent=2) + "\n")
            raise RuntimeError(f"complete physical comparison differs: {case / 'differences.json'}")
        results[label] = {"returncode": status, "overlap": None if executable == "consumer" else observed,
                          "complete_physical_comparison": "equal"}
        print(f"PASS {label}: " + ("serialized full_net rejected for missing overlap" if negative else
                                  "complete physical state agrees"), flush=True)
    (work / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    (work / "outputs.json").write_text(json.dumps({str(path.relative_to(work)): digest(path)
        for path in sorted(work.rglob("*")) if path.is_file() and not path.is_symlink()}, indent=2) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    mutation = sub.add_parser("serialize-api", help="generate the test-only whole-evolution control")
    mutation.add_argument("source", type=Path)
    mutation.add_argument("destination", type=Path)
    run = sub.add_parser("run")
    for option in ("consumer", "probe", "serialized", "net-setup", "library-config", "work-dir"):
        run.add_argument("--" + option, type=Path, required=True)
    args = parser.parse_args()
    if args.action == "serialize-api":
        serialize_api(args.source, args.destination)
    else:
        run_tests(args)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError) as error:
        sys.exit(f"FAIL: {error}")
