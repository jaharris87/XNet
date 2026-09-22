#!/usr/bin/env python3
"""Capture one immutable-source, direct-serial XNet benchmark record."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Any

from benchmark import (
    BenchmarkError,
    HISTORICAL_SHA,
    case_inputs,
    input_manifest,
    inventory,
    load_regression,
    manifest_digest,
    parse_diagnostic_metrics,
    read_registry,
    require_clean_historical_repository,
    run_timed_and_compare,
    sha256,
    write_json,
)

HARNESS_FILES = (
    "benchmark.py",
    "capture.py",
    "validate.py",
    "test_benchmark.py",
    "cases.json",
)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path)
    parser.add_argument(
        "--input-bundle",
        type=Path,
        help="versioned input tree; defaults to the frozen source checkout",
    )
    parser.add_argument(
        "--input-bundle-revision",
        help="exact bundle revision; defaults to the frozen source SHA",
    )
    parser.add_argument("--build-dir", type=Path)
    parser.add_argument("--records", type=Path)
    parser.add_argument("--case")
    parser.add_argument("--repetitions", type=int, default=5)
    parser.add_argument("--timeout-seconds", type=float, default=1800.0)
    parser.add_argument("--list-cases", action="store_true")
    return parser.parse_args()


def config_values(path: Path) -> dict[str, str]:
    """Read XNet's simple ``config.txt`` assignments."""
    return {
        key: value
        for line in path.read_text(encoding="utf-8").splitlines()
        if "=" in line
        for key, value in [line.split("=", 1)]
    }


def harness_identity() -> dict[str, object]:
    """Bind a record to this committed, complete benchmark harness."""
    root = Path(__file__).resolve().parents[2]
    try:
        revision = subprocess.check_output(
            ["git", "-C", str(root), "rev-parse", "HEAD"],
            text=True,
        ).strip()
        dirty = bool(
            subprocess.check_output(
                [
                    "git",
                    "-C",
                    str(root),
                    "status",
                    "--porcelain",
                    "--",
                    "test/benchmark",
                ],
                text=True,
            ).strip()
        )
    except (OSError, subprocess.CalledProcessError):
        revision, dirty = None, None

    return {
        "repository_revision": revision,
        "dirty": dirty,
        "files": {
            name: sha256(Path(__file__).parent / name)
            for name in HARNESS_FILES
        },
    }


def list_cases(cases: dict[str, Any]) -> None:
    for case in cases.values():
        network = case.network.get("id", "")
        description = case.workload.get("description", "")
        print(f"{case.case_id}\t{case.status}\t{network}\t{description}")


def require_capture_arguments(args: argparse.Namespace) -> None:
    required = (args.repository, args.build_dir, args.records, args.case)
    if not all(required) or args.repetitions < 1:
        raise BenchmarkError(
            "--repository, --build-dir, --records, --case, and positive "
            "--repetitions are required"
        )


def verify_input_bundle_revision(bundle: Path, revision: str) -> None:
    """Verify Git revisions when the declared bundle identity is a commit SHA."""
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        return
    try:
        actual = subprocess.check_output(
            ["git", "-C", str(bundle), "rev-parse", "HEAD"],
            text=True,
        ).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise BenchmarkError(
            "a Git-SHA input bundle revision requires a Git checkout"
        ) from error
    if actual != revision:
        raise BenchmarkError("input bundle checkout does not match its revision")


def build_historical_xnet(
    repository: Path,
    build_dir: Path,
    record: Path,
    profile: dict[str, Any],
) -> tuple[Path, Path, list[str], dict[str, str]]:
    """Build the source checkout owned by the capture, then prove its profile."""
    if build_dir.exists():
        raise BenchmarkError("capture owns a fresh, nonexistent --build-dir")

    build_log = record / "build.log"
    command = ["make", "-C", str(repository), f"BUILD_DIR={build_dir}", "xnet"]
    with build_log.open("w", encoding="utf-8") as log:
        build = subprocess.run(
            command,
            stdout=log,
            stderr=subprocess.STDOUT,
            text=True,
        )
    if build.returncode:
        raise BenchmarkError(f"fresh build failed; see {build_log}")

    executable = build_dir / "bin/xnet"
    config = build_dir / "config.txt"
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise BenchmarkError("fresh build did not produce an executable")
    if not config.is_file():
        raise BenchmarkError("fresh build did not produce config.txt")

    settings = config_values(config)
    if settings.get("SOURCE_ROOT") != str(repository):
        raise BenchmarkError("fresh build does not bind the historical source")
    if settings.get("MATRIX_SOLVER") != profile["dimensions"]["solver"]:
        raise BenchmarkError("fresh build is not the requested dense solver build")
    for key in (
        "MPI_MODE",
        "OPENMP_MODE",
        "GPU_MODE",
        "OPENACC_MODE",
        "OPENMP_OL_MODE",
    ):
        if settings.get(key) != "OFF":
            value = settings.get(key)
            raise BenchmarkError(f"serial-dense profile rejects {key}={value!r}")

    shutil.copy2(config, record / "build-config.txt")
    return executable, build_log, command, settings


def capture_repetition(
    number: int,
    record: Path,
    regression: Any,
    executable: Path,
    regression_case: Any,
    timeout_seconds: float,
    expected_zones: list[int],
) -> dict[str, object]:
    """Run one timed XNet invocation and retain its post-timing comparison."""
    artifact = record / "repetitions" / str(number)
    artifact.parent.mkdir(exist_ok=True)
    process_wall_seconds: float | None = None
    comparison_error: str | None = None

    with tempfile.TemporaryDirectory(prefix="xnet-v9-benchmark-") as temporary:
        work = Path(temporary) / "work"
        try:
            process_wall_seconds, _ = run_timed_and_compare(
                regression,
                executable,
                regression_case,
                work,
                timeout_seconds,
            )
            numerical = "pass"
        except Exception as error:
            numerical = "fail"
            comparison_error = f"{type(error).__name__}: {error}"

        artifact.mkdir()
        retained_names = (
            "net_diag01",
            "xnet.stdout.txt",
            "xnet.stderr.txt",
            "xnet.status.txt",
            "composition_error_norms.json",
        )
        for name in retained_names:
            source = work / name
            if source.is_file():
                shutil.copy2(source, artifact / name)

    diagnostic = artifact / "net_diag01"
    if diagnostic.is_file():
        timers, counters, timer_sections = parse_diagnostic_metrics(diagnostic)
    else:
        timers, counters, timer_sections = {}, {}, []

    structural = (
        numerical == "pass"
        and counters.get("end_records") == len(expected_zones)
        and timers.get("Total", 0.0) > 0.0
    )
    write_json(
        artifact / "comparison.json",
        {
            "result": numerical,
            "diagnostic": comparison_error,
            "timing_excluded": True,
        },
    )
    composition = artifact / "composition_error_norms.json"
    artifacts = {
        "composition_error_norms": {
            "path": composition.relative_to(record).as_posix(),
            "sha256": sha256(composition) if composition.is_file() else None,
        }
    }
    return {
        "number": number,
        "numerical_result": numerical,
        "structural_result": "pass" if structural else "fail",
        "process_wall_seconds": process_wall_seconds,
        "timers_seconds": timers,
        "timer_sections_seconds": timer_sections,
        "counters": counters,
        "artifacts": artifacts,
    }


def environment_identity() -> dict[str, str]:
    """Record portable text facts useful when a facility record is transferred."""
    interesting = {
        "LOADEDMODULES",
        "MODULEPATH",
        "SLURM_JOB_ID",
        "SLURM_NODELIST",
        "PBS_JOBID",
        "LSB_JOBID",
        "OMP_NUM_THREADS",
        "CUDA_VISIBLE_DEVICES",
        "ROCR_VISIBLE_DEVICES",
    }
    environment = {
        key: value for key, value in os.environ.items() if key in interesting
    }
    environment.update(
        {
            "platform": platform.platform(),
            "python": sys.version,
            "processor": platform.processor(),
            "host": platform.node(),
            "uname": " ".join(platform.uname()),
        }
    )
    return environment


def retain_command_output(
    record: Path,
    name: str,
    command: list[str],
) -> dict[str, object]:
    """Run an optional host-inspection command and retain its complete output."""
    path = record / f"{name}.txt"
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        output = result.stdout + result.stderr
        status: int | str = result.returncode
    except OSError as error:
        output = f"unavailable: {error}\n"
        status = "unavailable"
    path.write_text(output, encoding="utf-8")
    return {
        "path": path.name,
        "sha256": sha256(path),
        "argv": command,
        "status": status,
    }


def compiler_evidence(record: Path, settings: dict[str, str]) -> dict[str, object]:
    """Resolve the configured compiler and retain a version transcript."""
    candidate = settings.get("FC") or settings.get("F90") or os.environ.get("FC")
    compiler = shutil.which(candidate or "gfortran")
    if compiler is None:
        return {"path": None, "sha256": None, "version": "unavailable"}
    version = retain_command_output(record, "compiler-version", [compiler, "--version"])
    return {
        "path": compiler,
        "sha256": sha256(Path(compiler)),
        "version": version,
    }


def command_evidence(
    record: Path,
    executable: Path,
    settings: dict[str, str],
) -> dict[str, object]:
    """Retain safe, portable compiler, runtime, and topology facts."""
    if sys.platform == "darwin":
        runtime_command = ["otool", "-L", str(executable)]
    elif shutil.which("ldd"):
        runtime_command = ["ldd", str(executable)]
    else:
        runtime_command = ["sh", "-c", "printf 'unavailable\\n'"]

    lscpu = shutil.which("lscpu")
    system_profiler = shutil.which("system_profiler")
    if lscpu:
        topology_command = [lscpu]
    elif sys.platform == "darwin" and system_profiler:
        topology_command = [
            system_profiler,
            "SPHardwareDataType",
            "-detailLevel",
            "mini",
        ]
    else:
        topology_command = ["uname", "-a"]

    try:
        affinity: list[int] | str = sorted(os.sched_getaffinity(0))
    except (AttributeError, OSError):
        affinity = "unavailable"
    return {
        "cpu_count": os.cpu_count(),
        "affinity": affinity,
        "compiler": compiler_evidence(record, settings),
        "runtime": retain_command_output(record, "runtime-libraries", runtime_command),
        "topology": retain_command_output(record, "topology", topology_command),
    }


def make_record_document(
    case_id: str,
    case: Any,
    profile: dict[str, Any],
    harness: dict[str, object],
    manifest: list[dict[str, str]],
    repetitions: list[dict[str, object]],
    repetitions_requested: int,
    timeout_seconds: float,
    record: Path,
    executable: Path,
    build_log: Path,
    input_bundle_revision: str,
    operational: dict[str, object],
    build_argv: list[str],
    comparison: dict[str, object],
) -> dict[str, object]:
    """Assemble only portable values and retained-artifact identities."""
    return {
        "schema": "xnet-v9-benchmark-record-v3",
        "historical_source_sha": HISTORICAL_SHA,
        "source_sha": HISTORICAL_SHA,
        "case": {
            "case_id": case_id,
            "network": case.network,
            "workload": case.workload,
            "input_identity": case.input_identity,
        },
        "execution": {"profile": "serial-dense", **profile},
        "capture": {
            "captured_utc": datetime.now(timezone.utc).isoformat(),
            "repetitions_requested": repetitions_requested,
            "timeout_seconds": timeout_seconds,
            "harness": harness,
            "build": {
                "config_path": "build-config.txt",
                "config_sha256": sha256(record / "build-config.txt"),
                "log_path": "build.log",
                "log_sha256": sha256(build_log),
            },
            "executable": {"sha256": sha256(executable), "copied": False},
            "environment": environment_identity(),
            "build_argv": build_argv,
            "run_argv": [str(executable)],
            "operational": operational,
        },
        "input_bundle": {
            "type": "versioned-relative-path-manifest",
            "revision": input_bundle_revision,
            "entries": manifest,
            "manifest_sha256": manifest_digest(manifest),
        },
        "expected": case.expected,
        "comparison": comparison,
        "repetitions": repetitions,
    }


def retain_comparison_inputs(
    record: Path,
    bundle_root: Path,
    identity: dict[str, Any],
) -> dict[str, object]:
    """Copy the small comparator/reference pair required for offline checking."""
    comparison_dir = record / "comparison"
    comparison_dir.mkdir()
    retained: dict[str, dict[str, str]] = {}
    for name in ("comparator", "reference"):
        source_relative = identity[name]
        source = bundle_root / source_relative
        destination = comparison_dir / source.name
        shutil.copy2(source, destination)
        retained[name] = {
            "source_path": source_relative,
            "path": destination.relative_to(record).as_posix(),
            "sha256": sha256(destination),
        }
    return retained


def main() -> int:
    args = arguments()
    cases, profiles = read_registry(Path(__file__).parent)
    if args.list_cases:
        list_cases(cases)
        return 0

    require_capture_arguments(args)
    if args.case not in cases or cases[args.case].status != "ready":
        raise BenchmarkError(f"case is not ready for capture: {args.case}")

    harness = harness_identity()
    if harness["dirty"] is not False or not isinstance(
        harness["repository_revision"],
        str,
    ):
        raise BenchmarkError("capture requires a clean committed benchmark harness")

    repository = require_clean_historical_repository(args.repository)
    input_bundle = (args.input_bundle or repository).resolve()
    if not input_bundle.is_dir():
        raise BenchmarkError("--input-bundle must name a readable directory")
    input_bundle_revision = args.input_bundle_revision or HISTORICAL_SHA
    build_dir = args.build_dir.resolve()
    case = cases[args.case]
    identity = case.input_identity
    expected_bundle_revision = identity.get("bundle_revision")
    if input_bundle_revision != expected_bundle_revision:
        raise BenchmarkError("input bundle revision does not match the case registry")
    verify_input_bundle_revision(input_bundle, input_bundle_revision)
    comparator = input_bundle / identity["comparator"]
    regression = load_regression(comparator)
    regression_case = getattr(regression, case.workload["regression_factory"])(input_bundle)

    args.records.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    record = args.records.resolve() / f"{args.case}-{stamp}-{os.getpid()}"
    record.mkdir()
    profile = profiles["serial-dense"]
    executable, build_log, build_argv, settings = build_historical_xnet(
        repository,
        build_dir,
        record,
        profile,
    )
    bundle_inputs = case_inputs(input_bundle, regression_case, comparator)
    if any(not path.is_file() for path in bundle_inputs):
        raise BenchmarkError("input bundle lacks a required case-relative input")
    manifest = input_manifest(input_bundle, bundle_inputs)
    if manifest_digest(manifest) != identity.get("manifest_sha256"):
        raise BenchmarkError("case registry input-manifest binding mismatch")
    comparison = retain_comparison_inputs(record, input_bundle, identity)
    operational = command_evidence(record, executable, settings)

    repetitions = [
        capture_repetition(
            number,
            record,
            regression,
            executable,
            regression_case,
            args.timeout_seconds,
            case.expected["zones"],
        )
        for number in range(1, args.repetitions + 1)
    ]
    document = make_record_document(
        args.case,
        case,
        profile,
        harness,
        manifest,
        repetitions,
        args.repetitions,
        args.timeout_seconds,
        record,
        executable,
        build_log,
        input_bundle_revision,
        operational,
        build_argv,
        comparison,
    )
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
