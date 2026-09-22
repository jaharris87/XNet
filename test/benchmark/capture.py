#!/usr/bin/env python3
"""Capture one immutable-source, direct-serial XNet benchmark record."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile

from benchmark import (BenchmarkError, HISTORICAL_SHA, case_inputs, input_manifest, manifest_digest, inventory, load_regression, parse_diagnostic_metrics, read_cases, require_clean_historical_repository, run_timed_and_compare, sha256, write_json)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path)
    parser.add_argument("--build-dir", type=Path)
    parser.add_argument("--records", type=Path)
    parser.add_argument("--case")
    parser.add_argument("--repetitions", type=int, default=5)
    parser.add_argument("--timeout-seconds", type=float, default=1800.0)
    parser.add_argument("--list-cases", action="store_true")
    return parser.parse_args()


def config_values(path: Path) -> dict[str, str]:
    return dict(line.split("=", 1) for line in path.read_text(encoding="utf-8").splitlines() if "=" in line)


def harness_identity() -> dict[str, object]:
    root = Path(__file__).resolve().parents[2]
    files = ("benchmark.py", "capture.py", "validate.py", "cases.json")
    try:
        revision = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
        dirty = bool(subprocess.check_output(["git", "-C", str(root), "status", "--porcelain", "--", "test/benchmark"], text=True).strip())
    except (OSError, subprocess.CalledProcessError):
        revision, dirty = None, None
    return {"repository_revision": revision, "dirty": dirty, "files": {name: sha256(Path(__file__).parent / name) for name in files}}


def main() -> int:
    args = arguments()
    cases = read_cases(Path(__file__).parent)
    if args.list_cases:
        for case in cases.values():
            print(f"{case.case_id}\t{case.status}\t{case.network.get('id', '')}\t{case.workload.get('description', '')}")
        return 0
    if not all((args.repository, args.build_dir, args.records, args.case)) or args.repetitions < 1:
        raise BenchmarkError("--repository, --build-dir, --records, --case, and positive --repetitions are required")
    if args.case not in cases or cases[args.case].status != "ready":
        raise BenchmarkError(f"case is not ready for capture: {args.case}")
    repository = require_clean_historical_repository(args.repository)
    build_dir = args.build_dir.resolve()
    if build_dir.exists():
        raise BenchmarkError("capture owns a fresh, nonexistent --build-dir")
    regression = load_regression(repository)
    factory = cases[args.case].workload["regression_factory"]
    regression_case = getattr(regression, factory)(repository)
    args.records.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    record = args.records.resolve() / f"{args.case}-{stamp}-{os.getpid()}"
    record.mkdir()
    build_log = record / "build.log"
    with build_log.open("w", encoding="utf-8") as log:
        build = subprocess.run(["make", "-C", str(repository), f"BUILD_DIR={build_dir}", "xnet"], stdout=log, stderr=subprocess.STDOUT, text=True)
    if build.returncode:
        raise BenchmarkError(f"fresh build failed; see {build_log}")
    executable = build_dir / "bin/xnet"
    config = build_dir / "config.txt"
    if not executable.is_file() or not os.access(executable, os.X_OK) or not config.is_file():
        raise BenchmarkError("fresh build did not produce executable and config.txt")
    settings = config_values(config)
    if settings.get("SOURCE_ROOT") != str(repository) or settings.get("MATRIX_SOLVER") != "dense":
        raise BenchmarkError("fresh build is not the requested historical serial dense build")
    for key in ("MPI_MODE", "OPENMP_MODE", "GPU_MODE", "OPENACC_MODE", "OPENMP_OL_MODE"):
        if settings.get(key) != "OFF":
            raise BenchmarkError(f"serial-dense execution profile rejects {key}={settings.get(key)!r}")
    shutil.copy2(config, record / "build-config.txt")
    inputs = case_inputs(repository, regression_case)
    manifest = input_manifest(repository, inputs)
    if manifest_digest(manifest) != cases[args.case].input_identity.get("manifest_sha256"):
        raise BenchmarkError("case registry input-manifest binding mismatch")
    repetitions = []
    for number in range(1, args.repetitions + 1):
        artifact = record / "repetitions" / str(number)
        artifact.parent.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="xnet-v9-benchmark-") as temporary:
            work = Path(temporary) / "work"
            try:
                process_wall_seconds, states = run_timed_and_compare(regression, executable, regression_case, work, args.timeout_seconds)
                numerical = "pass"
                comparison_error = None
            except Exception as error:  # Preserve comparator diagnostics for failed numerical runs.
                numerical = "fail"
                comparison_error = f"{type(error).__name__}: {error}"
            artifact.mkdir()
            for name in ("net_diag01", "xnet.stdout.txt", "xnet.stderr.txt", "xnet.status.txt", "composition_error_norms.json"):
                source = work / name
                if source.is_file():
                    shutil.copy2(source, artifact / name)
        diagnostic = artifact / "net_diag01"
        timers, counters = parse_diagnostic_metrics(diagnostic) if diagnostic.is_file() else ({}, {})
        expected_zones = cases[args.case].expected["zones"]
        structural = numerical == "pass" and counters.get("end_records") == len(expected_zones) and timers.get("Total", 0.0) > 0.0
        write_json(artifact / "comparison.json", {"result": numerical, "diagnostic": comparison_error, "timing_excluded": True})
        repetitions.append({"number": number, "numerical_result": numerical, "structural_result": "pass" if structural else "fail", "process_wall_seconds": process_wall_seconds if numerical == "pass" else None, "timers_seconds": timers, "counters": counters})
    environment = {key: value for key, value in os.environ.items() if key in {"LOADEDMODULES", "MODULEPATH", "SLURM_JOB_ID", "SLURM_NODELIST", "PBS_JOBID", "LSB_JOBID", "OMP_NUM_THREADS", "CUDA_VISIBLE_DEVICES", "ROCR_VISIBLE_DEVICES"}}
    environment.update({"platform": platform.platform(), "python": sys.version, "processor": platform.processor(), "host": platform.node(), "uname": " ".join(platform.uname())})
    document = {"schema": "xnet-v9-benchmark-record-v3", "historical_source_sha": HISTORICAL_SHA, "source_sha": HISTORICAL_SHA, "case": {"case_id": args.case, "network": cases[args.case].network, "workload": cases[args.case].workload, "input_identity": cases[args.case].input_identity}, "execution": {"profile": "serial-dense", "launcher": "none", "dimensions": {"mpi": "OFF", "openmp": "OFF", "gpu": "OFF", "solver": "dense"}}, "capture": {"captured_utc": datetime.now(timezone.utc).isoformat(), "repetitions_requested": args.repetitions, "timeout_seconds": args.timeout_seconds, "harness": harness_identity(), "build": {"config_path": "build-config.txt", "config_sha256": sha256(record / "build-config.txt"), "log_path": "build.log", "log_sha256": sha256(build_log)}, "executable": {"sha256": sha256(executable), "copied": False}, "environment": environment}, "input_bundle": {"type": "historical-source-manifest", "revision": HISTORICAL_SHA, "entries": manifest, "manifest_sha256": manifest_digest(manifest)}, "expected": cases[args.case].expected, "repetitions": repetitions}
    write_json(record / "record.json", document)
    write_json(record / "inventory.json", inventory(record))
    print(record)
    return 0 if all(row["structural_result"] == "pass" for row in repetitions) else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BenchmarkError as error:
        print(f"capture rejected: {error}", file=sys.stderr)
        raise SystemExit(2)
