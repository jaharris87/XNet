#!/usr/bin/env python3
"""Capture one immutable-source XNet benchmark record for a bounded profile."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from typing import Any

from benchmark import (
    BenchmarkError,
    RECORD_SCHEMA,
    TIMER_NAMES,
    case_inputs,
    input_manifest,
    inventory,
    load_regression,
    manifest_digest,
    parse_device_probe,
    parse_diagnostic_metrics,
    parse_execution_probe,
    parse_openmp_probe,
    parse_slurm_job,
    read_registry,
    require_clean_repository,
    run_timed_and_compare,
    sha256,
    worker_topology,
    write_json,
)
from validate import validate_runtime_evidence

HARNESS_FILES = (
    "benchmark.py",
    "capture.py",
    "validate.py",
    "test_benchmark.py",
    "test_characterize.py",
    "test_execution_profiles.py",
    "characterize.py",
    "cases.json",
    "network-bundle-a9585568.json",
    "gpu_execution_probe.F90",
    "openmp_execution_probe.F90",
    "gpu_probe.mk",
)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path)
    parser.add_argument(
        "--source-revision",
        help="exact full Git SHA required for the source checkout",
    )
    parser.add_argument(
        "--input-bundle",
        type=Path,
        help="versioned input tree; defaults to the source checkout",
    )
    parser.add_argument(
        "--input-bundle-revision",
        help="exact bundle revision; defaults to --source-revision",
    )
    parser.add_argument("--build-dir", type=Path)
    parser.add_argument("--records", type=Path)
    parser.add_argument("--case")
    parser.add_argument("--profile", default="serial-dense")
    parser.add_argument(
        "--launcher",
        help="shell-style complete MPI launcher prefix; the captured executable is appended",
    )
    parser.add_argument("--threads", type=int, default=1)
    parser.add_argument("--ranks", type=int, default=1)
    parser.add_argument("--ranks-per-gpu", type=int, default=1)
    parser.add_argument("--gpu-backend", choices=("CUDA", "HIP"))
    parser.add_argument("--accelerator-mode", choices=("openacc", "openmp-offload"))
    parser.add_argument("--ma48-dir", type=Path)
    parser.add_argument(
        "--build-option",
        action="append",
        default=[],
        metavar="NAME=VALUE",
        help="explicit site build selection (PE_ENV, CMODE, MACHINE, LAPACK_VER, or EOS)",
    )
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
    required = (
        args.repository,
        args.source_revision,
        args.build_dir,
        args.records,
        args.case,
    )
    if not all(required) or args.repetitions < 1:
        raise BenchmarkError(
            "--repository, --source-revision, --build-dir, --records, --case, "
            "and positive --repetitions are required"
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


def build_xnet(
    repository: Path,
    build_dir: Path,
    record: Path,
    profile: dict[str, Any],
    build_options: dict[str, str],
) -> tuple[Path, Path, list[str], dict[str, str]]:
    """Build the source checkout owned by the capture, then prove its profile."""
    if build_dir.exists():
        raise BenchmarkError("capture owns a fresh, nonexistent --build-dir")

    build_log = record / "build.log"
    selectors = profile["build_selectors"]
    command = ["make", "-C", str(repository), f"BUILD_DIR={build_dir}"]
    command.extend(f"{name}={value}" for name, value in build_options.items())
    command.extend(f"{name}={value}" for name, value in selectors.items())
    if profile.get("accelerator") or profile["dimensions"]["openmp"] == "ON":
        command.extend(
            [
                "-f",
                str(Path(__file__).parent / "gpu_probe.mk"),
                f"BENCHMARK_HARNESS_DIR={Path(__file__).parent}",
            ]
        )
    if profile.get("accelerator"):
        backend = profile.get("_gpu_backend")
        mode = profile.get("_accelerator_mode")
        if backend is None or mode is None:
            raise BenchmarkError("accelerator profile requires --gpu-backend and --accelerator-mode")
        command.extend([f"GPU_BACKEND={backend}"])
        command.append(f"GPU_LAPACK_VER={'CUBLAS' if backend == 'CUDA' else 'ROCM'}")
        command.append(f"OPENACC_MODE={'ON' if mode == 'openacc' else 'OFF'}")
        command.append(f"OPENMP_OL_MODE={'ON' if mode == 'openmp-offload' else 'OFF'}")
    if profile.get("external_source"):
        ma48_dir = profile.get("_ma48_dir")
        if not isinstance(ma48_dir, Path) or not (ma48_dir / "MA48.f").is_file():
            raise BenchmarkError("MA48 profiles require --ma48-dir containing licensed MA48.f")
        command.append(f"MA48_DIR={ma48_dir}")
    command.append("xnet")
    if profile.get("accelerator"):
        command.append("xnet_benchmark_gpu_probe")
    if profile["dimensions"]["openmp"] == "ON":
        command.append("xnet_benchmark_openmp_probe")
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
        raise BenchmarkError("fresh build does not bind the source repository")
    for key, value in selectors.items():
        if settings.get(key) != value:
            raise BenchmarkError(f"fresh build selector {key} does not match profile")
    if profile.get("accelerator"):
        if settings.get("GPU_BACKEND") != profile["_gpu_backend"] or settings.get("GPU_LAPACK_VER") not in {"CUBLAS", "ROCM"}:
            raise BenchmarkError("fresh accelerator build does not match requested backend")
        if (settings.get("OPENACC_MODE") == "ON") == (settings.get("OPENMP_OL_MODE") == "ON"):
            raise BenchmarkError("fresh accelerator build lacks exactly one directive mode")

    shutil.copy2(config, record / "build-config.txt")
    return executable, build_log, command, settings


def capture_repetition(
    number: int,
    record: Path,
    regression: Any,
    executable: Path,
    run_argv: list[str],
    regression_case: Any,
    timeout_seconds: float,
    expected_zones: list[int],
) -> dict[str, object]:
    """Run one timed XNet invocation and retain its post-timing comparison."""
    artifact = record / "repetitions" / str(number)
    artifact.parent.mkdir(exist_ok=True)
    process_wall_seconds: float | None = None
    comparison_error: str | None = None

    with tempfile.TemporaryDirectory(prefix="xnet-benchmark-") as temporary:
        work = Path(temporary) / "work"
        try:
            process_wall_seconds, _ = run_timed_and_compare(
                regression,
                executable,
                run_argv,
                regression_case,
                work,
                timeout_seconds,
            )
            numerical = "pass"
        except Exception as error:
            numerical = "fail"
            comparison_error = f"{type(error).__name__}: {error}"

        artifact.mkdir()
        retained_names = tuple(
            path.name for path in work.glob("net_diag*")
        ) + (
            "xnet.stdout.txt",
            "xnet.stderr.txt",
            "xnet.status.txt",
            "composition_error_norms.json",
        )
        for name in retained_names:
            source = work / name
            if source.is_file():
                shutil.copy2(source, artifact / name)

    diagnostics = sorted(artifact.glob("net_diag*"))
    worker_metrics = []
    all_sections: list[dict[str, float]] = []
    zone_counters: dict[str, object] = {}
    end_records = 0
    for diagnostic in diagnostics:
        worker_timers, worker_counters, worker_sections = parse_diagnostic_metrics(
            diagnostic
        )
        worker_metrics.append(
            {
                "path": diagnostic.relative_to(record).as_posix(),
                "sha256": sha256(diagnostic),
                "timers_seconds": worker_timers,
                "timer_sections_seconds": worker_sections,
                "counters": worker_counters,
            }
        )
        all_sections.extend(worker_sections)
        end_records += worker_counters.get("end_records", 0)
        for zone, values in worker_counters.get("zones", {}).items():
            if zone in zone_counters:
                raise BenchmarkError(f"duplicate counter record for zone {zone}")
            zone_counters[zone] = values

    # A parallel wall-clock run completes when its slowest worker completes.
    # Keep every worker value and expose maxima only as the compact summary.
    timers = {
        name: max(
            (worker["timers_seconds"].get(name, 0.0) for worker in worker_metrics),
            default=0.0,
        )
        for name in TIMER_NAMES
    }
    counters = {
        "end_records": end_records,
        "timer_sections": len(all_sections),
        "zones": zone_counters,
    }

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
        "timer_sections_seconds": all_sections,
        "counters": counters,
        "worker_metrics": worker_metrics,
        "artifacts": artifacts,
    }


RANK_ENVIRONMENT = (
    "OMPI_COMM_WORLD_RANK", "PMI_RANK", "PMIX_RANK", "SLURM_PROCID",
)


def observe_launcher(record: Path, launcher: list[str]) -> dict[str, object]:
    """Run a harness-owned probe through the exact launcher before XNet."""
    code = (
        "import json,os,socket; "
        "keys=('OMPI_COMM_WORLD_RANK','PMI_RANK','PMIX_RANK','SLURM_PROCID'); "
        "step_keys=('SLURM_STEP_ID','SLURM_STEP_NUM_TASKS','SLURM_NTASKS',"
        "'SLURM_CPUS_PER_TASK','SLURM_STEP_GPUS','SLURM_GPUS_ON_NODE',"
        "'SLURM_LOCALID'); "
        "rank=next((os.environ[k] for k in keys if k in os.environ),None); "
        "step=({k:os.environ[k] for k in step_keys if k in os.environ} "
        "if 'SLURM_STEP_ID' in os.environ else {}); "
        "aff=sorted(os.sched_getaffinity(0)) if hasattr(os,'sched_getaffinity') else None; "
        "print('XNET_EXECUTION_PROBE '+json.dumps({'rank':rank,'host':socket.gethostname(),"
        "'affinity':aff,'cuda_visible':os.environ.get('CUDA_VISIBLE_DEVICES'),"
        "'rocr_visible':os.environ.get('ROCR_VISIBLE_DEVICES'),'slurm_step':step},"
        "sort_keys=True))"
    )
    argv = [*launcher, sys.executable, "-c", code]
    transcript = retain_command_output(record, "execution-probe", argv)
    observations = parse_execution_probe(record / transcript["path"])
    scheduler_names = (
        "SLURM_JOB_ID", "SLURM_NODELIST", "SLURM_JOB_NUM_NODES",
        "SLURM_NTASKS", "SLURM_CPUS_PER_TASK", "SLURM_GPUS",
        "SLURM_GPUS_PER_NODE", "SLURM_GPUS_PER_TASK", "SLURM_JOB_PARTITION",
        "PBS_JOBID", "PBS_NODEFILE", "PBS_NP", "LSB_JOBID", "LSB_HOSTS",
    )
    scheduler_environment = {
        key: os.environ[key]
        for key in scheduler_names
        if key in os.environ
    }
    if scheduler_environment:
        job_id = scheduler_environment.get("SLURM_JOB_ID")
        scontrol = shutil.which("scontrol")
        if not job_id or not scontrol:
            raise BenchmarkError("Slurm allocation requires SLURM_JOB_ID and scontrol")
        scheduler_probe = retain_command_output(
            record,
            "slurm-allocation",
            [scontrol, "show", "job", job_id, "--oneliner"],
        )
        if scheduler_probe["status"] != 0:
            raise BenchmarkError("Slurm allocation query failed")
        scheduler_probe["tool_sha256"] = sha256(Path(scontrol))
        allocation = {
            "kind": "scheduler",
            "scope": "allocation",
            "environment": scheduler_environment,
            "scheduler_probe": {
                "probe": scheduler_probe,
                "fields": parse_slurm_job(record / scheduler_probe["path"]),
            },
        }
    else:
        allocation = {
            "kind": "unscheduled-local",
            "host": platform.node(),
            "affinity": sorted(os.sched_getaffinity(0))
            if hasattr(os, "sched_getaffinity")
            else None,
        }
    return {"probe": transcript, "observations": observations, "allocation": allocation}


def observe_offload(
    record: Path,
    launcher: list[str],
    probe: Path | None,
) -> dict[str, object] | None:
    """Run the capture-built device probe through the exact XNet launcher."""
    if probe is None:
        return None
    if not probe.is_file() or not os.access(probe, os.X_OK):
        raise BenchmarkError("accelerator build did not produce its device probe")
    argv = [*launcher, str(probe)]
    transcript = retain_command_output(record, "offload-probe", argv)
    observations = parse_device_probe(record / transcript["path"])
    if (
        transcript["status"] != 0
        or not observations
        or any(
            item["device_count"] < 1
            or not item["offloaded"]
            or not item["data_present"]
            or item["info"] != 0
            or item["residual"] > 1.0e-12
            for item in observations
        )
    ):
        raise BenchmarkError("offload probe did not prove actual device execution")
    return {
        "probe": transcript,
        "executable_sha256": sha256(probe),
        "observations": observations,
    }


def observe_openmp(
    record: Path,
    launcher: list[str],
    probe: Path | None,
) -> dict[str, object] | None:
    """Run the capture-built OpenMP team/placement probe."""
    if probe is None:
        return None
    if not probe.is_file() or not os.access(probe, os.X_OK):
        raise BenchmarkError("OpenMP build did not produce its placement probe")
    transcript = retain_command_output(
        record,
        "openmp-probe",
        [*launcher, str(probe)],
    )
    observations = parse_openmp_probe(record / transcript["path"])
    if transcript["status"] != 0 or not observations:
        raise BenchmarkError("OpenMP probe did not report its team placement")
    return {"probe": transcript, "observations": observations}


def environment_identity() -> dict[str, str]:
    """Record portable text facts useful when a facility record is transferred."""
    interesting = {
        "LOADEDMODULES",
        "MODULEPATH",
        "SLURM_JOB_ID",
        "SLURM_NODELIST",
        "SLURM_JOB_NUM_NODES",
        "SLURM_NTASKS",
        "SLURM_CPUS_PER_TASK",
        "SLURM_GPUS",
        "SLURM_GPUS_PER_NODE",
        "SLURM_GPUS_PER_TASK",
        "SLURM_JOB_PARTITION",
        "PBS_JOBID",
        "PBS_NODEFILE",
        "PBS_NP",
        "LSB_JOBID",
        "LSB_HOSTS",
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
    redact_labels: tuple[str, ...] = (),
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
    if redact_labels:
        output = "\n".join(
            line
            for line in output.splitlines()
            if not any(label in line.lower() for label in redact_labels)
        ) + "\n"
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
    runtime = retain_command_output(record, "runtime-libraries", runtime_command)
    topology = retain_command_output(
        record,
        "topology",
        topology_command,
        redact_labels=("serial number", "hardware uuid", "provisioning udid"),
    )
    compiler = compiler_evidence(record, settings)
    version = compiler.get("version")
    evidence = {
        "cpu_count": os.cpu_count(),
        "affinity": affinity,
        "compiler": compiler,
        "runtime": runtime,
        "topology": topology,
    }
    statuses = (
        version.get("status") if isinstance(version, dict) else None,
        runtime.get("status"),
        topology.get("status"),
    )
    if any(status != 0 for status in statuses):
        raise BenchmarkError("required operational evidence command failed")
    return evidence


def accelerator_evidence(record: Path, backend: str | None) -> dict[str, object] | None:
    """Retain vendor runtime and physical-device identities when GPU mode is used."""
    if backend is None:
        return None
    candidates = (
        (("nvidia-smi", "-L"), ("nvidia-smi", "--query-gpu=index,uuid,name,driver_version", "--format=csv,noheader"))
        if backend == "CUDA"
        else (("rocm-smi", "--showuniqueid", "--showproductname", "--showdriverversion"),)
    )
    entries = []
    for command in candidates:
        executable = shutil.which(command[0])
        if executable:
            entry = retain_command_output(
                record,
                f"accelerator-{len(entries) + 1}",
                [executable, *command[1:]],
            )
            entry["tool_sha256"] = sha256(Path(executable))
            entries.append(entry)
    if not entries or any(entry.get("status") != 0 for entry in entries):
        raise BenchmarkError("accelerator runtime/device identity command failed")
    return {"backend": backend, "commands": entries}


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
    source_revision: str,
    run_argv: list[str],
    runtime: dict[str, object],
) -> dict[str, object]:
    """Assemble only portable values and retained-artifact identities."""
    return {
        "schema": RECORD_SCHEMA,
        "source_revision": source_revision,
        "case": {
            "case_id": case_id,
            "network": case.network,
            "workload": case.workload,
            "input_identity": case.input_identity,
        },
        "execution": {"profile": profile["_name"], **{key: value for key, value in profile.items() if not key.startswith("_")}},
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
            "run_argv": run_argv,
            "operational": operational,
            "runtime": runtime,
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

    repository = require_clean_repository(args.repository, args.source_revision)
    input_bundle = (args.input_bundle or repository).resolve()
    if not input_bundle.is_dir():
        raise BenchmarkError("--input-bundle must name a readable directory")
    input_bundle_revision = args.input_bundle_revision or args.source_revision
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
    if args.profile not in profiles:
        raise BenchmarkError(f"unknown execution profile: {args.profile}")
    if args.threads < 1 or args.ranks < 1 or args.ranks_per_gpu < 1:
        raise BenchmarkError("--threads, --ranks, and --ranks-per-gpu must be positive")
    profile = {**profiles[args.profile], "_name": args.profile}
    profile["_gpu_backend"] = args.gpu_backend
    profile["_accelerator_mode"] = args.accelerator_mode
    profile["_ma48_dir"] = args.ma48_dir.resolve() if args.ma48_dir else None
    build_options: dict[str, str] = {}
    allowed_build_options = {"PE_ENV", "CMODE", "MACHINE", "LAPACK_VER", "EOS"}
    for assignment in args.build_option:
        if "=" not in assignment:
            raise BenchmarkError("--build-option must be NAME=VALUE")
        name, value = assignment.split("=", 1)
        if name not in allowed_build_options or not value or name in build_options:
            raise BenchmarkError("unsupported or duplicate --build-option")
        build_options[name] = value
    try:
        launcher = shlex.split(args.launcher) if args.launcher else []
    except ValueError as error:
        raise BenchmarkError("--launcher is not valid shell-style argv text") from error
    if profile["launcher"] == "required" and not launcher:
        raise BenchmarkError(f"{args.profile} requires --launcher")
    if profile["launcher"] == "direct" and launcher:
        raise BenchmarkError(f"{args.profile} does not accept --launcher")
    if profile["dimensions"]["mpi"] == "OFF" and args.ranks != 1:
        raise BenchmarkError("non-MPI profiles require --ranks 1")
    if profile["dimensions"]["openmp"] == "OFF" and args.threads != 1:
        raise BenchmarkError("non-OpenMP profiles require --threads 1")
    if profile["dimensions"]["gpu"] == "OFF" and args.ranks_per_gpu != 1:
        raise BenchmarkError("non-accelerator profiles require --ranks-per-gpu 1")
    if profile["dimensions"]["openmp"] == "ON" and os.environ.get("OMP_NUM_THREADS") != str(args.threads):
        raise BenchmarkError("OpenMP profile requires matching OMP_NUM_THREADS")
    run_argv = [*launcher, str((args.build_dir.resolve() / "bin/xnet"))]
    executable, build_log, build_argv, settings = build_xnet(
        repository,
        build_dir,
        record,
        profile,
        build_options,
    )
    bundle_inputs = case_inputs(input_bundle, regression_case, comparator)
    if any(not path.is_file() for path in bundle_inputs):
        raise BenchmarkError("input bundle lacks a required case-relative input")
    manifest = input_manifest(input_bundle, bundle_inputs)
    if manifest_digest(manifest) != identity.get("manifest_sha256"):
        raise BenchmarkError("case registry input-manifest binding mismatch")
    comparison = retain_comparison_inputs(record, input_bundle, identity)
    operational = command_evidence(record, executable, settings)
    accelerator = accelerator_evidence(record, args.gpu_backend)
    launcher_probe = observe_launcher(record, launcher)
    offload_probe = observe_offload(
        record,
        launcher,
        build_dir / "bin" / "xnet_benchmark_gpu_probe"
        if profile["dimensions"]["gpu"] == "ON"
        else None,
    )
    openmp_probe = observe_openmp(
        record,
        launcher,
        build_dir / "bin" / "xnet_benchmark_openmp_probe"
        if profile["dimensions"]["openmp"] == "ON"
        else None,
    )

    repetitions = [
        capture_repetition(
            number,
            record,
            regression,
            executable,
            run_argv,
            regression_case,
            args.timeout_seconds,
            case.expected["zones"],
        )
        for number in range(1, args.repetitions + 1)
    ]
    topology = worker_topology((record / "repetitions" / "1").glob("net_diag*"))
    runtime = {
        "launcher_argv": launcher,
        "requested_ranks": args.ranks,
        "requested_threads": args.threads,
        "requested_ranks_per_gpu": args.ranks_per_gpu,
        "launcher_probe": launcher_probe,
        "offload_probe": offload_probe,
        "openmp_probe": openmp_probe,
        "accelerator_evidence": accelerator,
        "xnet_topology": topology,
        "affinity": operational["affinity"],
        "gpu_backend": args.gpu_backend,
        "accelerator_mode": args.accelerator_mode,
        "ma48_source_sha256": sha256(profile["_ma48_dir"] / "MA48.f")
        if profile.get("external_source")
        else None,
    }
    # Reject an invalid profile before publishing record.json.  The offline
    # validator repeats this check from retained evidence after transfer.
    validate_runtime_evidence(
        profile,
        runtime,
        run_argv,
        str(executable),
        environment_identity(),
    )
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
        args.source_revision,
        run_argv,
        runtime,
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
