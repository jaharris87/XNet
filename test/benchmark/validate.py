#!/usr/bin/env python3
"""Validate a portable XNet benchmark record without requiring a live checkout."""

from __future__ import annotations

import argparse
from dataclasses import replace
from datetime import datetime
import json
import math
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Any, Callable

from benchmark import (
    BenchmarkError,
    TIMER_NAMES,
    inventory,
    load_regression,
    manifest_digest,
    parse_device_probe,
    read_record,
    read_registry,
    parse_diagnostic_metrics,
    parse_execution_probe,
    parse_openmp_probe,
    parse_slurm_job,
    parse_worker_states,
    sha256,
    worker_topology,
)

HARNESS_FILES = {
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
}
COUNTER_NAMES = {"TS", "NR", "Jacobian", "Deriv", "CrossSect"}


def as_finite_nonnegative(value: object, message: str) -> float:
    """Convert a record number while reporting malformed JSON as a rejection."""
    if isinstance(value, bool):
        raise BenchmarkError(message)
    try:
        number = float(value)
    except (TypeError, ValueError) as error:
        raise BenchmarkError(message) from error
    if not math.isfinite(number) or number < 0.0:
        raise BenchmarkError(message)
    return number


def slurm_gpu_count(value: object) -> int:
    """Parse a Slurm GPU count without accepting arbitrary truthy text."""
    if not isinstance(value, str):
        raise BenchmarkError("Slurm environment has malformed GPU allocation")
    match = re.fullmatch(r"(?:gpu(?::[A-Za-z0-9_.-]+)?[:=])?(\d+)", value)
    if match is None:
        raise BenchmarkError("Slurm environment has malformed GPU allocation")
    return int(match.group(1))


def read_json(path: Path, message: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise BenchmarkError(message) from error
    if not isinstance(value, dict):
        raise BenchmarkError(message)
    return value


def require_transcript_summary(
    parser: Callable[[Path], object],
    transcript: Path,
    summary: object,
    message: str,
) -> None:
    """Reject a retained summary that is not exactly derived from its transcript."""
    if parser(transcript) != summary:
        raise BenchmarkError(message)


def validate_slurm_query_command(
    entry: object,
    scheduler_environment: dict[str, object],
) -> None:
    """Bind retained allocation output to the supported scheduler query."""
    argv = entry.get("argv") if isinstance(entry, dict) else None
    tool_digest = entry.get("tool_sha256") if isinstance(entry, dict) else None
    job_id = scheduler_environment.get("SLURM_JOB_ID")
    if (
        not isinstance(argv, list)
        or len(argv) != 5
        or Path(argv[0]).name != "scontrol"
        or argv[1:] != ["show", "job", job_id, "--oneliner"]
        or not isinstance(tool_digest, str)
        or not re.fullmatch(r"[0-9a-f]{64}", tool_digest)
    ):
        raise BenchmarkError("Slurm allocation command does not match the stored job")


def validate_accelerator_identity_entry(
    backend: str,
    index: int,
    entry: object,
    transcript: Path,
) -> None:
    """Bind one vendor identity transcript to its supported command and output."""
    expected_commands = (
        (
            ("nvidia-smi", "-L"),
            (
                "nvidia-smi",
                "--query-gpu=index,uuid,name,driver_version",
                "--format=csv,noheader",
            ),
        )
        if backend == "CUDA"
        else (
            (
                "rocm-smi",
                "--showuniqueid",
                "--showproductname",
                "--showdriverversion",
            ),
        )
    )
    if index < 1 or index > len(expected_commands):
        raise BenchmarkError("accelerator runtime evidence is incomplete")
    argv = entry.get("argv") if isinstance(entry, dict) else None
    tool_digest = entry.get("tool_sha256") if isinstance(entry, dict) else None
    expected = expected_commands[index - 1]
    if (
        not isinstance(argv, list)
        or Path(argv[0]).name != expected[0]
        or tuple(argv[1:]) != expected[1:]
        or not isinstance(tool_digest, str)
        or not re.fullmatch(r"[0-9a-f]{64}", tool_digest)
    ):
        raise BenchmarkError("accelerator identity command does not match backend")
    output = transcript.read_text(encoding="utf-8", errors="replace")
    if backend == "CUDA":
        recognizable = (
            (index == 1 and "GPU " in output and "UUID:" in output)
            or (
                index == 2
                and any(len(line.split(",")) >= 4 for line in output.splitlines())
            )
        )
    else:
        recognizable = bool(
            re.search(
                r"Unique ID|Device|GPU|Card series|Driver version",
                output,
                re.IGNORECASE,
            )
        )
    if not recognizable:
        raise BenchmarkError("accelerator identity output is not recognizable")


def read_config_values(path: Path) -> dict[str, str]:
    return {
        key: value
        for line in path.read_text(encoding="utf-8").splitlines()
        if "=" in line
        for key, value in [line.split("=", 1)]
    }


def retained_path(record: Path, value: object, message: str) -> Path:
    if not isinstance(value, str):
        raise BenchmarkError(message)
    relative = Path(value)
    if relative.is_absolute() or ".." in relative.parts:
        raise BenchmarkError(message)
    return record / relative


def validate_harness_identity(document: dict[str, object]) -> None:
    capture = document.get("capture", {})
    harness = capture.get("harness", {}) if isinstance(capture, dict) else {}
    if not isinstance(harness, dict):
        raise BenchmarkError("missing harness identity")

    revision = harness.get("repository_revision")
    files = harness.get("files")
    if harness.get("dirty") is not False:
        raise BenchmarkError("harness must be captured from a clean committed revision")
    if not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise BenchmarkError("malformed harness revision")
    if not isinstance(files, dict) or set(files) != HARNESS_FILES:
        raise BenchmarkError("harness file set mismatch")

    for name, digest in files.items():
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise BenchmarkError("malformed harness hash")
        if sha256(Path(__file__).parent / name) != digest:
            raise BenchmarkError(f"current harness hash mismatch: {name}")
    try:
        current = subprocess.check_output(
            ["git", "-C", str(Path(__file__).resolve().parents[2]), "rev-parse", "HEAD"],
            text=True,
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        current = None
    if current is not None and current != revision:
        raise BenchmarkError("harness revision is not the current checkout HEAD")


def validate_case_and_execution(
    document: dict[str, object],
    cases: dict[str, Any],
    profiles: dict[str, dict[str, Any]],
) -> tuple[Any, dict[str, object]]:
    case_document = document.get("case")
    if not isinstance(case_document, dict):
        raise BenchmarkError("missing case binding")
    case_id = case_document.get("case_id")
    if not isinstance(case_id, str) or case_id not in cases:
        raise BenchmarkError("unknown benchmark case")

    case = cases[case_id]
    if case.status != "ready":
        raise BenchmarkError("record binds a case that is not ready")
    if case_document.get("network") != case.network:
        raise BenchmarkError("case relabel or network binding mismatch")
    if case_document.get("workload") != case.workload:
        raise BenchmarkError("case relabel or workload binding mismatch")
    if case_document.get("input_identity") != case.input_identity:
        raise BenchmarkError("case relabel or input binding mismatch")

    execution = document.get("execution")
    if not isinstance(execution, dict):
        raise BenchmarkError("missing execution profile")
    profile_name = execution.get("profile")
    if not isinstance(profile_name, str) or profile_name not in profiles:
        raise BenchmarkError("unknown execution profile")
    expected_execution = {"profile": profile_name, **profiles[profile_name]}
    if execution != expected_execution:
        raise BenchmarkError("execution profile does not match the registry")

    expected = case.expected
    if document.get("expected") != expected:
        raise BenchmarkError("expected outputs or zones do not match the case registry")
    return case, expected


def validate_input_bundle(
    document: dict[str, object],
    identity: dict[str, Any],
) -> list[dict[str, str]]:
    bundle = document.get("input_bundle")
    if not isinstance(bundle, dict):
        raise BenchmarkError("missing input-bundle manifest")
    entries = bundle.get("entries")
    if not isinstance(entries, list) or not entries:
        raise BenchmarkError("missing input-bundle manifest")

    seen: set[str] = set()
    checked_entries: list[dict[str, str]] = []
    for entry in entries:
        if not isinstance(entry, dict):
            raise BenchmarkError("malformed input manifest entry")
        path = entry.get("path")
        digest = entry.get("sha256")
        if not isinstance(path, str) or not path:
            raise BenchmarkError("malformed input-bundle path")
        if path.startswith("/") or ".." in Path(path).parts or path in seen:
            raise BenchmarkError("malformed input-bundle path")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise BenchmarkError(f"malformed input hash: {path}")
        seen.add(path)
        checked_entries.append({"path": path, "sha256": digest})

    if bundle.get("type") != "versioned-relative-path-manifest":
        raise BenchmarkError("unsupported input-bundle type")
    if bundle.get("revision") != identity.get("bundle_revision"):
        raise BenchmarkError("input bundle revision does not match the case registry")
    if bundle.get("manifest_sha256") != manifest_digest(checked_entries):
        raise BenchmarkError("input manifest digest mismatch")
    if manifest_digest(checked_entries) != identity.get("manifest_sha256"):
        raise BenchmarkError("input manifest binding mismatch")

    required_paths = {
        identity.get(key)
        for key in ("control", "reference", "helm_table", "comparator")
    }
    if not required_paths <= seen:
        raise BenchmarkError("case input identity binding mismatch")
    network_root = identity.get("network_root")
    if not isinstance(network_root, str) or not any(
        path.startswith(network_root) for path in seen
    ):
        raise BenchmarkError("case network input identity binding mismatch")
    trajectory_root = identity.get("trajectory_root")
    if trajectory_root and not any(path.startswith(trajectory_root) for path in seen):
        raise BenchmarkError("case trajectory input identity binding mismatch")
    return checked_entries


def validate_timer_section(section: object) -> dict[str, float]:
    if not isinstance(section, dict) or set(section) != set(TIMER_NAMES):
        raise BenchmarkError("timer section does not contain the full timer set")
    return {
        name: as_finite_nonnegative(section[name], "invalid timer section value")
        for name in TIMER_NAMES
    }


def validate_runtime_evidence(
    profile: dict[str, Any],
    runtime: object,
    run_argv: list[str],
    expected_executable: str,
    environment: dict[str, object],
) -> None:
    """Require observed execution facts, not merely a profile label."""
    if not isinstance(runtime, dict):
        raise BenchmarkError("capture lacks runtime placement evidence")
    launcher = runtime.get("launcher_argv")
    ranks = runtime.get("requested_ranks")
    threads = runtime.get("requested_threads")
    ranks_per_gpu = runtime.get("requested_ranks_per_gpu", 1)
    if not isinstance(launcher, list) or not all(
        isinstance(item, str) and item for item in launcher
    ):
        raise BenchmarkError("malformed launcher provenance")
    if run_argv != [*launcher, expected_executable]:
        raise BenchmarkError("launcher provenance does not match run command")
    if (
        not isinstance(ranks, int) or ranks < 1
        or not isinstance(threads, int) or threads < 1
        or not isinstance(ranks_per_gpu, int) or ranks_per_gpu < 1
    ):
        raise BenchmarkError("malformed rank or thread provenance")
    dimensions = profile["dimensions"]
    if profile["launcher"] == "required" and not launcher:
        raise BenchmarkError("parallel profile lacks launcher provenance")
    if profile["launcher"] == "direct" and launcher:
        raise BenchmarkError("direct profile has unexpected launcher")
    if dimensions["mpi"] == "OFF" and ranks != 1:
        raise BenchmarkError("non-MPI profile has wrong rank count")
    if dimensions["mpi"] == "ON" and ranks < 2:
        raise BenchmarkError("MPI profile lacks multiple ranks")
    if dimensions["mpi"] == "ON":
        declared_counts: list[int] = []
        for index, argument in enumerate(launcher):
            if argument in {"-n", "-np", "--np", "--ntasks"}:
                try:
                    declared_counts.append(int(launcher[index + 1]))
                except (IndexError, ValueError) as error:
                    raise BenchmarkError("launcher has malformed rank count") from error
            elif argument.startswith("--ntasks="):
                try:
                    declared_counts.append(int(argument.split("=", 1)[1]))
                except ValueError as error:
                    raise BenchmarkError("launcher has malformed rank count") from error
        if declared_counts != [ranks]:
            raise BenchmarkError("launcher rank count does not match requested ranks")
    if dimensions["openmp"] == "OFF" and threads != 1:
        raise BenchmarkError("non-OpenMP profile has wrong thread count")
    if dimensions["gpu"] == "OFF" and ranks_per_gpu != 1:
        raise BenchmarkError("non-accelerator profile has ranks-per-GPU claim")
    if dimensions["openmp"] == "ON" and (
        threads < 2 or environment.get("OMP_NUM_THREADS") != str(threads)
    ):
        raise BenchmarkError("OpenMP thread evidence does not match profile")
    probe = runtime.get("launcher_probe")
    if not isinstance(probe, dict) or not isinstance(probe.get("observations"), list):
        raise BenchmarkError("capture lacks launcher-observed placement evidence")
    observations = probe["observations"]
    topology = runtime.get("xnet_topology")
    if not isinstance(topology, dict):
        raise BenchmarkError("capture lacks XNet topology evidence")
    rank_rows = topology.get("ranks")
    thread_rows = topology.get("threads")
    if not isinstance(rank_rows, list) or not isinstance(thread_rows, list):
        raise BenchmarkError("capture has malformed XNet topology evidence")
    rank_records = {
        (item.get("rank"), item.get("size"))
        for item in rank_rows
        if isinstance(item, dict)
    }
    expected_ranks = {(rank, ranks) for rank in range(ranks)}
    if rank_records != expected_ranks:
        raise BenchmarkError("XNet rank topology does not match requested launcher ranks")
    allocation = probe.get("allocation")
    needs_placement = any(
        dimensions[name] == "ON" for name in ("mpi", "openmp", "gpu")
    )
    placement_policy = profile.get("placement_policy")
    if placement_policy not in {
        "none",
        "distinct-thread-places",
        "disjoint-rank-affinity",
        "bound-ranks-and-device",
        "disjoint-rank-affinity-and-device",
    }:
        raise BenchmarkError("execution profile lacks a supported placement policy")
    if needs_placement and (
        len(observations) != ranks
        or any(
            not isinstance(item, dict)
            or not item.get("host")
            or not isinstance(item.get("affinity"), list)
            or not item["affinity"]
            for item in observations
        )
    ):
        raise BenchmarkError("launcher probe lacks host or binding evidence")
    if needs_placement and (
        not isinstance(allocation, dict)
        or allocation.get("kind") not in {"scheduler", "unscheduled-local"}
    ):
        raise BenchmarkError("parallel profile lacks observed allocation context")
    if needs_placement and allocation["kind"] == "scheduler":
        if allocation.get("scope") != "allocation":
            raise BenchmarkError("Slurm scheduler evidence is not allocation-scoped")
        scheduler = allocation.get("environment")
        if not isinstance(scheduler, dict) or "SLURM_JOB_ID" not in scheduler:
            raise BenchmarkError("parallel profile lacks supported Slurm allocation evidence")
        try:
            slurm_ranks = int(scheduler["SLURM_NTASKS"])
            slurm_threads = int(scheduler["SLURM_CPUS_PER_TASK"])
        except (KeyError, TypeError, ValueError) as error:
            raise BenchmarkError("Slurm allocation lacks rank or thread counts") from error
        if slurm_ranks < ranks:
            raise BenchmarkError("Slurm allocation lacks sufficient task capacity")
        if slurm_threads < threads:
            raise BenchmarkError("Slurm CPUs per task do not cover requested threads")
        scheduler_probe = allocation.get("scheduler_probe")
        fields = (
            scheduler_probe.get("fields")
            if isinstance(scheduler_probe, dict)
            else None
        )
        if not isinstance(fields, dict):
            raise BenchmarkError("Slurm allocation lacks scheduler query evidence")
        if fields.get("JobId") != scheduler["SLURM_JOB_ID"]:
            raise BenchmarkError("Slurm job identity disagrees with scheduler query")
        try:
            queried_ranks = int(fields["NumTasks"])
            queried_threads = int(fields["CPUs/Task"])
        except (KeyError, TypeError, ValueError) as error:
            raise BenchmarkError("Slurm query lacks rank or thread counts") from error
        if queried_ranks < ranks:
            raise BenchmarkError("Slurm allocation query lacks sufficient task capacity")
        if queried_ranks != slurm_ranks:
            raise BenchmarkError("Slurm query task count disagrees with the allocation")
        if queried_threads < threads or queried_threads != slurm_threads:
            raise BenchmarkError("Slurm query CPUs per task disagree with the allocation")
        step_rows = [item.get("slurm_step") for item in observations]
        if any(step_rows):
            if any(not isinstance(item, dict) or not item for item in step_rows):
                raise BenchmarkError("launcher probe has incomplete Slurm step evidence")
            step_ids = {
                item.get("SLURM_STEP_ID")
                for item in step_rows
                if item.get("SLURM_STEP_ID") is not None
            }
            if len(step_ids) > 1:
                raise BenchmarkError("launcher probe ranks disagree on Slurm step identity")
            for item in step_rows:
                step_rank_text = item.get(
                    "SLURM_STEP_NUM_TASKS", item.get("SLURM_NTASKS")
                )
                try:
                    step_ranks = int(step_rank_text)
                except (TypeError, ValueError) as error:
                    raise BenchmarkError("Slurm step lacks a valid task count") from error
                if step_ranks != ranks:
                    raise BenchmarkError("Slurm step task count does not match launcher ranks")
                try:
                    step_threads = int(item["SLURM_CPUS_PER_TASK"])
                except (KeyError, TypeError, ValueError) as error:
                    raise BenchmarkError("Slurm step lacks a valid CPUs-per-task count") from error
                if step_threads < threads:
                    raise BenchmarkError("Slurm step CPUs per task do not cover requested threads")
    if dimensions["mpi"] == "ON":
        observed_ranks = {item.get("rank") for item in observations if isinstance(item, dict)}
        if observed_ranks != {str(rank) for rank in range(ranks)}:
            raise BenchmarkError("launcher probe rank IDs do not match XNet ranks")
        affinity_by_host: dict[str, list[set[int]]] = {}
        for item in observations:
            affinity_by_host.setdefault(item["host"], []).append(set(item["affinity"]))
        for host_affinities in affinity_by_host.values():
            for index, affinity in enumerate(host_affinities):
                if any(affinity & other for other in host_affinities[index + 1 :]):
                    raise BenchmarkError("MPI ranks do not have disjoint CPU affinity")
    if dimensions["openmp"] == "ON":
        teams = {
            (item.get("rank"), item.get("thread"), item.get("team"))
            for item in thread_rows
            if isinstance(item, dict)
        }
        expected_teams = {
            (rank, thread, threads)
            for rank in range(ranks)
            for thread in range(1, threads + 1)
        }
        if teams != expected_teams:
            raise BenchmarkError("XNet OpenMP topology does not match requested thread team")
        openmp_probe = runtime.get("openmp_probe")
        if not isinstance(openmp_probe, dict) or not isinstance(openmp_probe.get("observations"), list):
            raise BenchmarkError("OpenMP profile lacks capture-owned placement probe")
        placement = openmp_probe["observations"]
        observed_team = {
            (str(item.get("rank")), item.get("thread"), item.get("team"))
            for item in placement
            if isinstance(item, dict)
        }
        expected_observed = {
            (str(rank), thread - 1, threads)
            for rank in range(ranks)
            for thread in range(1, threads + 1)
        }
        if observed_team != expected_observed:
            raise BenchmarkError("OpenMP placement probe does not match requested team")
        if any(
            not isinstance(item, dict)
            or not isinstance(item.get("place"), int)
            or item["place"] < 0
            or not isinstance(item.get("binding"), int)
            or item["binding"] == 0
            for item in placement
        ):
            raise BenchmarkError("OpenMP placement probe lacks active thread binding")
        places_by_rank: dict[str, set[int]] = {}
        for item in placement:
            places_by_rank.setdefault(str(item["rank"]), set()).add(item["place"])
        if any(len(places) != threads for places in places_by_rank.values()):
            raise BenchmarkError("OpenMP threads do not occupy distinct bound places")
        for item in observations:
            affinity = item.get("affinity") if isinstance(item, dict) else None
            if not isinstance(affinity, list) or len(set(affinity)) < threads:
                raise BenchmarkError("launcher affinity cannot cover requested OpenMP threads")
    if dimensions["gpu"] == "ON":
        accelerator_evidence = runtime.get("accelerator_evidence")
        if (
            not isinstance(accelerator_evidence, dict)
            or accelerator_evidence.get("backend") != runtime.get("gpu_backend")
            or not isinstance(accelerator_evidence.get("commands"), list)
            or not accelerator_evidence["commands"]
        ):
            raise BenchmarkError("accelerator profile lacks runtime/device identity evidence")
        offload = runtime.get("offload_probe")
        if not isinstance(offload, dict) or not isinstance(offload.get("observations"), list):
            raise BenchmarkError("accelerator profile lacks capture-owned offload probe")
        device_rows = offload["observations"]
        device_ranks = [
            str(item.get("rank")) for item in device_rows if isinstance(item, dict)
        ]
        if (
            len(device_rows) != ranks
            or len(device_ranks) != ranks
            or set(device_ranks) != {str(rank) for rank in range(ranks)}
        ):
            raise BenchmarkError("accelerator offload probe lacks rank-to-device evidence")
        if any(
            not isinstance(item, dict)
            or item.get("offloaded") is not True
            or item.get("data_present") is not True
            or not isinstance(item.get("device_count"), int)
            or item["device_count"] < 1
            or not isinstance(item.get("device"), int)
            or item["device"] < 0
            or item["device"] >= item["device_count"]
            or item.get("info") != 0
            or as_finite_nonnegative(item.get("residual"), "invalid device residual") > 1.0e-12
            for item in device_rows
        ):
            raise BenchmarkError("accelerator offload probe did not prove device execution")
        if isinstance(allocation, dict) and allocation.get("kind") == "scheduler":
            scheduler = allocation["environment"]
            scheduler_probe = allocation["scheduler_probe"]
            scheduler_fields = scheduler_probe["fields"]
            gpu_text = " ".join(
                scheduler_fields.get(name, "")
                for name in ("AllocTRES", "TresPerNode", "TresPerTask", "Gres")
            )
            gpu_counts = [
                int(value)
                for value in re.findall(
                    r"(?:gres/)?gpu(?::[A-Za-z0-9_.-]+)?[=:](\d+)",
                    gpu_text,
                )
            ]
            required_devices = (ranks + ranks_per_gpu - 1) // ranks_per_gpu
            if not gpu_counts or max(gpu_counts) < required_devices:
                raise BenchmarkError("Slurm query lacks sufficient GPU allocation")
            environment_counts = []
            if scheduler.get("SLURM_GPUS") is not None:
                environment_counts.append(slurm_gpu_count(scheduler["SLURM_GPUS"]))
            if scheduler.get("SLURM_GPUS_PER_NODE") is not None:
                try:
                    nodes = int(scheduler.get("SLURM_JOB_NUM_NODES", "1"))
                except ValueError as error:
                    raise BenchmarkError("Slurm environment has malformed node count") from error
                environment_counts.append(
                    slurm_gpu_count(scheduler["SLURM_GPUS_PER_NODE"]) * nodes
                )
            if scheduler.get("SLURM_GPUS_PER_TASK") is not None:
                environment_counts.append(
                    slurm_gpu_count(scheduler["SLURM_GPUS_PER_TASK"]) * ranks
                )
            if not environment_counts or max(environment_counts) < required_devices:
                raise BenchmarkError("Slurm environment lacks sufficient GPU allocation")
        launcher_by_rank = {
            str(item.get("rank") if item.get("rank") is not None else 0): item
            for item in observations
            if isinstance(item, dict)
        }
        device_groups: dict[tuple[object, object], int] = {}
        for item in device_rows:
            rank = str(item["rank"])
            launcher_item = launcher_by_rank.get(rank)
            if not isinstance(launcher_item, dict):
                raise BenchmarkError("accelerator rank lacks launcher placement")
            visible = launcher_item.get("cuda_visible") or launcher_item.get("rocr_visible")
            physical_identity = (visible, item["device"]) if visible else item["device"]
            group = (launcher_item.get("host"), physical_identity)
            device_groups[group] = device_groups.get(group, 0) + 1
        if set(device_groups.values()) != {ranks_per_gpu}:
            raise BenchmarkError("observed rank/device placement does not match ranks per GPU")


def validate_capture_provenance(
    document: dict[str, object],
    record: Path,
    profile: dict[str, Any],
) -> None:
    """Check retained build, executable, and safe operational evidence."""
    capture = document.get("capture")
    if not isinstance(capture, dict):
        raise BenchmarkError("missing capture provenance")
    for key in ("captured_utc", "timeout_seconds", "build_argv", "run_argv"):
        if key not in capture:
            raise BenchmarkError(f"capture lacks {key}")
    if not isinstance(capture["captured_utc"], str):
        raise BenchmarkError("capture has malformed timestamp")
    try:
        datetime.fromisoformat(capture["captured_utc"])
    except ValueError as error:
        raise BenchmarkError("capture has malformed timestamp") from error
    if as_finite_nonnegative(capture["timeout_seconds"], "invalid timeout") <= 0.0:
        raise BenchmarkError("invalid timeout")
    command_values = (capture["build_argv"], capture["run_argv"])
    if not all(
        isinstance(value, list)
        and value
        and all(isinstance(argument, str) and argument for argument in value)
        for value in command_values
    ):
        raise BenchmarkError("capture lacks command provenance")

    build = capture.get("build")
    executable = capture.get("executable")
    environment = capture.get("environment")
    if not isinstance(build, dict) or not isinstance(executable, dict):
        raise BenchmarkError("capture lacks build or executable provenance")
    environment_fields = {"platform", "python", "processor", "host", "uname"}
    if not isinstance(environment, dict) or not environment_fields <= set(environment):
        raise BenchmarkError("capture lacks environment provenance")
    for field in ("config", "log"):
        path = build.get(f"{field}_path")
        digest = build.get(f"{field}_sha256")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise BenchmarkError("malformed build provenance")
        artifact = retained_path(record, path, "malformed build provenance")
        if not artifact.is_file() or sha256(artifact) != digest:
            raise BenchmarkError("retained build artifact hash mismatch")
    executable_digest = executable.get("sha256")
    if (
        not isinstance(executable_digest, str)
        or not re.fullmatch(r"[0-9a-f]{64}", executable_digest)
        or executable.get("copied") is not False
    ):
        raise BenchmarkError("malformed executable provenance")
    settings = read_config_values(record / build["config_path"])
    if "MATRIX_SOLVER" not in settings or "SOURCE_ROOT" not in settings:
        raise BenchmarkError("retained build config is incomplete")
    build_argv = capture["build_argv"]
    try:
        source_argument = build_argv[build_argv.index("-C") + 1]
    except (ValueError, IndexError) as error:
        raise BenchmarkError("build command lacks its source checkout") from error
    if settings["SOURCE_ROOT"] != source_argument:
        raise BenchmarkError("build command and config source roots disagree")
    build_directories = [
        argument.removeprefix("BUILD_DIR=")
        for argument in build_argv
        if argument.startswith("BUILD_DIR=")
    ]
    if len(build_directories) != 1:
        raise BenchmarkError("build command lacks one capture-owned build directory")
    expected_executable = str(Path(build_directories[0]) / "bin" / "xnet")
    run_argv = capture["run_argv"]
    if not run_argv or run_argv[-1] != expected_executable:
        raise BenchmarkError("run command does not match the captured build")
    dimensions = profile["dimensions"]
    for name, value in profile["build_selectors"].items():
        if settings.get(name) != value:
            raise BenchmarkError("retained build config does not match profile")
    if profile.get("accelerator"):
        runtime_claim = capture.get("runtime")
        requested_backend = runtime_claim.get("gpu_backend") if isinstance(runtime_claim, dict) else None
        requested_mode = runtime_claim.get("accelerator_mode") if isinstance(runtime_claim, dict) else None
        if requested_backend not in {"CUDA", "HIP"} or settings.get("GPU_BACKEND") != requested_backend:
            raise BenchmarkError("accelerator build lacks a supported backend")
        expected_openacc = "ON" if requested_mode == "openacc" else "OFF"
        expected_openmp = "ON" if requested_mode == "openmp-offload" else "OFF"
        if requested_mode not in {"openacc", "openmp-offload"} or (
            settings.get("OPENACC_MODE"), settings.get("OPENMP_OL_MODE")
        ) != (expected_openacc, expected_openmp):
            raise BenchmarkError("accelerator build lacks exactly one directive mode")
    if profile.get("external_source"):
        runtime_claim = capture.get("runtime")
        source_digest = runtime_claim.get("ma48_source_sha256") if isinstance(runtime_claim, dict) else None
        if not settings.get("MA48_DIR") or not isinstance(source_digest, str) or not re.fullmatch(r"[0-9a-f]{64}", source_digest):
            raise BenchmarkError("MA48 build lacks external source provenance")

    operational = capture.get("operational")
    if not isinstance(operational, dict):
        raise BenchmarkError("capture lacks operational provenance")
    cpu_count = operational.get("cpu_count")
    affinity = operational.get("affinity")
    if not isinstance(cpu_count, int) or cpu_count < 1:
        raise BenchmarkError("capture lacks CPU-count provenance")
    if affinity != "unavailable" and not (
        isinstance(affinity, list)
        and affinity
        and all(isinstance(cpu, int) and cpu >= 0 for cpu in affinity)
    ):
        raise BenchmarkError("capture has malformed affinity provenance")

    compiler = operational.get("compiler")
    if not isinstance(compiler, dict):
        raise BenchmarkError("capture lacks compiler provenance")
    compiler_path = compiler.get("path")
    compiler_digest = compiler.get("sha256")
    if not isinstance(compiler_path, str) or not compiler_path.startswith("/"):
        raise BenchmarkError("capture lacks resolved compiler provenance")
    if not isinstance(compiler_digest, str) or not re.fullmatch(
        r"[0-9a-f]{64}",
        compiler_digest,
    ):
        raise BenchmarkError("capture has malformed compiler provenance")
    configured_compiler = settings.get("FC")
    if not isinstance(configured_compiler, str) or (
        Path(compiler_path).name != Path(configured_compiler).name
    ):
        raise BenchmarkError("compiler provenance does not match the build config")

    def validate_transcript(name: str, entry: object) -> Path:
        if not isinstance(entry, dict):
            raise BenchmarkError(f"capture lacks {name} provenance")
        path = entry.get("path")
        digest = entry.get("sha256")
        argv = entry.get("argv")
        status = entry.get("status")
        if not isinstance(digest, str):
            raise BenchmarkError(f"malformed {name} provenance")
        if not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise BenchmarkError(f"malformed {name} provenance")
        if not isinstance(argv, list) or not argv or status != 0:
            raise BenchmarkError(f"malformed {name} provenance")
        artifact = retained_path(
            record,
            path,
            f"malformed {name} provenance",
        )
        if not artifact.is_file() or sha256(artifact) != digest:
            raise BenchmarkError(f"retained {name} evidence hash mismatch")
        return artifact

    validate_transcript("compiler version", compiler.get("version"))
    compiler_version = compiler["version"]
    if compiler_version.get("argv") != [compiler_path, "--version"]:
        raise BenchmarkError("compiler version command does not match the compiler")
    for name in ("runtime", "topology"):
        validate_transcript(name, operational.get(name))
    runtime_claim = capture.get("runtime")
    if isinstance(runtime_claim, dict) and isinstance(runtime_claim.get("launcher_probe"), dict):
        probe = runtime_claim["launcher_probe"]
        transcript = validate_transcript("execution probe", probe.get("probe"))
        require_transcript_summary(
            parse_execution_probe,
            transcript,
            probe.get("observations"),
            "execution probe summary disagrees with transcript",
        )
        allocation = probe.get("allocation")
        if isinstance(allocation, dict) and allocation.get("kind") == "scheduler":
            scheduler_probe = allocation.get("scheduler_probe")
            if not isinstance(scheduler_probe, dict):
                raise BenchmarkError("capture lacks Slurm allocation provenance")
            transcript = validate_transcript(
                "Slurm allocation",
                scheduler_probe.get("probe"),
            )
            scheduler_environment = allocation.get("environment")
            if not isinstance(scheduler_environment, dict):
                raise BenchmarkError("capture lacks Slurm allocation provenance")
            validate_slurm_query_command(
                scheduler_probe.get("probe"),
                scheduler_environment,
            )
            require_transcript_summary(
                parse_slurm_job,
                transcript,
                scheduler_probe.get("fields"),
                "Slurm allocation summary disagrees with transcript",
            )
    if isinstance(runtime_claim, dict) and isinstance(runtime_claim.get("offload_probe"), dict):
        probe = runtime_claim["offload_probe"]
        transcript = validate_transcript("offload probe", probe.get("probe"))
        require_transcript_summary(
            parse_device_probe,
            transcript,
            probe.get("observations"),
            "offload probe summary disagrees with transcript",
        )
    if isinstance(runtime_claim, dict) and isinstance(runtime_claim.get("openmp_probe"), dict):
        probe = runtime_claim["openmp_probe"]
        transcript = validate_transcript("OpenMP probe", probe.get("probe"))
        require_transcript_summary(
            parse_openmp_probe,
            transcript,
            probe.get("observations"),
            "OpenMP probe summary disagrees with transcript",
        )
    if isinstance(runtime_claim, dict) and runtime_claim.get("accelerator_evidence") is not None:
        accelerator = runtime_claim["accelerator_evidence"]
        if not isinstance(accelerator, dict) or accelerator.get("backend") != runtime_claim.get("gpu_backend"):
            raise BenchmarkError("accelerator runtime evidence does not match backend")
        commands = accelerator.get("commands")
        if not isinstance(commands, list) or not commands:
            raise BenchmarkError("accelerator runtime evidence is incomplete")
        backend = accelerator["backend"]
        expected_count = 2 if backend == "CUDA" else 1
        if len(commands) != expected_count:
            raise BenchmarkError("accelerator runtime evidence is incomplete")
        for index, entry in enumerate(commands, start=1):
            transcript = validate_transcript(f"accelerator runtime {index}", entry)
            validate_accelerator_identity_entry(backend, index, entry, transcript)
    runtime_argv = operational["runtime"]["argv"]
    if (
        Path(runtime_argv[0]).name not in {"ldd", "otool"}
        or expected_executable not in runtime_argv
    ):
        raise BenchmarkError("runtime evidence does not inspect the run executable")

    runtime_evidence = runtime_claim
    if not isinstance(runtime_evidence, dict) or runtime_evidence.get("affinity") != affinity:
        raise BenchmarkError("runtime affinity evidence does not match operational evidence")
    validate_runtime_evidence(
        profile, runtime_evidence, run_argv, expected_executable, environment
    )


def validate_comparison_binding(
    document: dict[str, object],
    identity: dict[str, Any],
    record: Path,
    entries: list[dict[str, str]],
) -> dict[str, Path]:
    """Verify that the captured comparator/reference are exact bundle copies."""
    comparison = document.get("comparison")
    if not isinstance(comparison, dict):
        raise BenchmarkError("missing captured comparison inputs")
    paths: dict[str, Path] = {}
    manifest_hashes = {entry["path"]: entry["sha256"] for entry in entries}
    for name in ("comparator", "reference"):
        entry = comparison.get(name)
        if not isinstance(entry, dict):
            raise BenchmarkError("malformed captured comparison input")
        if entry.get("source_path") != identity.get(name):
            raise BenchmarkError("captured comparison source path mismatch")
        path = entry.get("path")
        digest = entry.get("sha256")
        if not isinstance(digest, str):
            raise BenchmarkError("malformed captured comparison input")
        artifact = retained_path(
            record,
            path,
            "malformed captured comparison input",
        )
        if not artifact.is_file() or sha256(artifact) != digest:
            raise BenchmarkError("captured comparison input hash mismatch")
        if digest != manifest_hashes.get(entry["source_path"]):
            raise BenchmarkError("captured comparison does not match input manifest")
        paths[name] = artifact
    return paths


def compare_retained_diagnostics(
    diagnostics: list[Path],
    composition: Path,
    comparison_paths: dict[str, Path],
    factory_name: str,
) -> None:
    """Run the captured comparator without a live source checkout."""
    try:
        regression = load_regression(comparison_paths["comparator"])
        with tempfile.TemporaryDirectory(
            prefix="xnet-benchmark-comparison-"
        ) as temporary:
            locator = Path(temporary)
            case = getattr(regression, factory_name)(locator)
            case = replace(case, reference=comparison_paths["reference"])
            reference = regression.load_reference(case.reference)
            text = "\n".join(
                diagnostic.read_text(encoding="utf-8")
                for diagnostic in diagnostics
            )
            missing = tuple(
                marker
                for marker in case.required_diagnostic_markers
                if marker not in text
            )
            if missing:
                raise BenchmarkError("retained diagnostic lacks required markers")
            states = parse_worker_states(regression, case, diagnostics)
            diagnostics = regression.calculate_composition_norms(states, reference)
            regression._write_composition_diagnostics(
                locator,
                diagnostics,
                reference,
            )
            regenerated = read_json(
                locator / "composition_error_norms.json",
                "comparator did not regenerate composition diagnostics",
            )
            retained = read_json(
                composition,
                "malformed composition diagnostics",
            )
            if regenerated != retained:
                raise BenchmarkError("composition diagnostics disagree with replay")
            regression.compare_final_states(states, reference)
            regression.compare_equivalent_zone_groups(
                states,
                case.equivalent_zone_groups,
            )
    except Exception as error:
        raise BenchmarkError(f"retained diagnostic comparison failed: {error}") from error


def validate_repetition(
    repetition: object,
    number: int,
    expected: dict[str, object],
    record: Path,
    comparison_paths: dict[str, Path],
    factory_name: str,
    expected_topology: dict[str, object],
) -> None:
    if not isinstance(repetition, dict):
        raise BenchmarkError("malformed repetition")
    if repetition.get("number") != number:
        raise BenchmarkError("repetition number mismatch")
    if repetition.get("numerical_result") != "pass":
        raise BenchmarkError("numerical comparison did not pass")
    if repetition.get("structural_result") != "pass":
        raise BenchmarkError("structural capture result did not pass")
    if as_finite_nonnegative(
        repetition.get("process_wall_seconds"),
        "repetition lacks finite positive process wall time",
    ) <= 0.0:
        raise BenchmarkError("repetition lacks finite positive process wall time")

    timers = repetition.get("timers_seconds")
    if not isinstance(timers, dict) or set(timers) != set(TIMER_NAMES):
        raise BenchmarkError("repetition lacks the full timer set")
    checked_timers = {
        name: as_finite_nonnegative(timers[name], "invalid timer value")
        for name in TIMER_NAMES
    }
    if checked_timers["Total"] <= 0.0:
        raise BenchmarkError("repetition lacks positive Total timer")

    sections = repetition.get("timer_sections_seconds")
    expected_section_count = expected.get("timer_sections")
    if not isinstance(sections, list) or len(sections) != expected_section_count:
        raise BenchmarkError("unexpected timer section count")
    checked_sections = [validate_timer_section(section) for section in sections]

    counters = repetition.get("counters")
    if not isinstance(counters, dict):
        raise BenchmarkError("missing diagnostic counters")
    if counters.get("end_records") != len(expected["zones"]):
        raise BenchmarkError("diagnostic end-record count mismatch")
    if counters.get("timer_sections") != expected_section_count:
        raise BenchmarkError("diagnostic timer-section count mismatch")

    zone_counters = counters.get("zones")
    expected_zones = {str(zone) for zone in expected["zones"]}
    if not isinstance(zone_counters, dict) or set(zone_counters) != expected_zones:
        raise BenchmarkError("per-zone counter coverage mismatch")
    for values in zone_counters.values():
        if not isinstance(values, dict) or set(values) != COUNTER_NAMES:
            raise BenchmarkError("invalid per-zone counter values")
        if any(not isinstance(value, int) or value < 0 for value in values.values()):
            raise BenchmarkError("invalid per-zone counter values")

    artifact = record / "repetitions" / str(number)
    required_artifacts = (
        "comparison.json",
        "xnet.stdout.txt",
        "xnet.stderr.txt",
        "xnet.status.txt",
    )
    if any(not (artifact / name).is_file() for name in required_artifacts):
        raise BenchmarkError("missing retained repetition artifacts")
    comparison = read_json(
        artifact / "comparison.json",
        "missing or malformed comparison result",
    )
    if comparison.get("result") != "pass":
        raise BenchmarkError("comparison did not pass")
    if comparison.get("timing_excluded") is not True:
        raise BenchmarkError("comparison was not excluded from timing")
    status = (artifact / "xnet.status.txt").read_text(encoding="utf-8").strip()
    if status != "return_code=0":
        raise BenchmarkError("XNet did not retain a zero direct status")
    worker_metrics = repetition.get("worker_metrics")
    if not isinstance(worker_metrics, list) or not worker_metrics:
        raise BenchmarkError("repetition lacks worker metrics")
    diagnostics: list[Path] = []
    parsed_sections: list[dict[str, float]] = []
    parsed_zone_counters: dict[str, object] = {}
    parsed_end_records = 0
    parsed_worker_timers: list[dict[str, float]] = []
    for worker in worker_metrics:
        if not isinstance(worker, dict):
            raise BenchmarkError("malformed worker metrics")
        diagnostic = retained_path(record, worker.get("path"), "malformed worker path")
        if diagnostic.parent != artifact or not diagnostic.name.startswith("net_diag"):
            raise BenchmarkError("malformed worker path")
        if not diagnostic.is_file() or sha256(diagnostic) != worker.get("sha256"):
            raise BenchmarkError("retained worker diagnostic hash mismatch")
        worker_timers, worker_counters, worker_sections = parse_diagnostic_metrics(diagnostic)
        if (
            worker.get("timers_seconds") != worker_timers
            or worker.get("counters") != worker_counters
            or worker.get("timer_sections_seconds") != worker_sections
        ):
            raise BenchmarkError("retained diagnostic disagrees with worker summary")
        diagnostics.append(diagnostic)
        parsed_worker_timers.append(worker_timers)
        parsed_sections.extend(worker_sections)
        parsed_end_records += worker_counters.get("end_records", 0)
        for zone, values in worker_counters.get("zones", {}).items():
            if zone in parsed_zone_counters:
                raise BenchmarkError("duplicate retained zone counter")
            parsed_zone_counters[zone] = values
    parsed_timers = {
        name: max((row.get(name, 0.0) for row in parsed_worker_timers), default=0.0)
        for name in TIMER_NAMES
    }
    parsed_counters = {
        "end_records": parsed_end_records,
        "timer_sections": len(parsed_sections),
        "zones": parsed_zone_counters,
    }
    if (
        parsed_timers != checked_timers
        or parsed_counters != counters
        or parsed_sections != checked_sections
    ):
        raise BenchmarkError("retained diagnostics disagree with repetition summary")
    if worker_topology(diagnostics) != expected_topology:
        raise BenchmarkError("retained XNet topology disagrees with runtime summary")
    composition = artifact / "composition_error_norms.json"
    artifacts = repetition.get("artifacts")
    composition_entry = (
        artifacts.get("composition_error_norms") if isinstance(artifacts, dict) else None
    )
    if not isinstance(composition_entry, dict):
        raise BenchmarkError("missing composition diagnostics binding")
    if composition_entry.get("path") != composition.relative_to(record).as_posix():
        raise BenchmarkError("composition diagnostics path mismatch")
    if not composition.is_file() or sha256(composition) != composition_entry.get("sha256"):
        raise BenchmarkError("missing composition diagnostics")
    try:
        composition_value = json.loads(composition.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise BenchmarkError("malformed composition diagnostics") from error
    if not isinstance(composition_value, dict):
        raise BenchmarkError("malformed composition diagnostics")
    compare_retained_diagnostics(
        diagnostics,
        composition,
        comparison_paths,
        factory_name,
    )


def validate_inventory(record: Path) -> None:
    try:
        recorded = json.loads((record / "inventory.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise BenchmarkError("missing or malformed inventory.json") from error
    if not isinstance(recorded, list) or recorded != inventory(record):
        raise BenchmarkError("artifact inventory is incomplete or tampered")


def rehydrate(
    repository: Path | None,
    input_bundle: Path | None,
    executable: Path | None,
    entries: list[dict[str, str]],
    document: dict[str, object],
) -> None:
    source_revision = document.get("source_revision")
    if repository:
        try:
            revision = subprocess.check_output(
                ["git", "-C", str(repository), "rev-parse", "HEAD"], text=True
            ).strip()
        except (OSError, subprocess.CalledProcessError) as error:
            raise BenchmarkError("rehydration repository is not a Git checkout") from error
        if revision != source_revision:
            raise BenchmarkError(
                "rehydration repository does not match record source revision"
            )
        dirty = subprocess.check_output(
            ["git", "-C", str(repository), "status", "--porcelain"],
            text=True,
        ).strip()
        if dirty:
            raise BenchmarkError("rehydration repository is not clean")
    if input_bundle:
        bundle = document.get("input_bundle")
        revision = bundle.get("revision") if isinstance(bundle, dict) else None
        if isinstance(revision, str) and re.fullmatch(r"[0-9a-f]{40}", revision):
            try:
                actual = subprocess.check_output(
                    ["git", "-C", str(input_bundle), "rev-parse", "HEAD"],
                    text=True,
                ).strip()
            except (OSError, subprocess.CalledProcessError) as error:
                raise BenchmarkError(
                    "rehydration input bundle is not a Git checkout"
                ) from error
            if actual != revision:
                raise BenchmarkError("rehydration input bundle revision mismatch")
        for entry in entries:
            source = input_bundle.resolve() / entry["path"]
            if not source.is_file() or sha256(source) != entry["sha256"]:
                raise BenchmarkError(f"rehydration input mismatch: {entry['path']}")
    if executable:
        capture = document.get("capture")
        if isinstance(capture, dict):
            expected = capture.get("executable", {}).get("sha256")
        else:
            expected = None
        if not executable.is_file() or sha256(executable) != expected:
            raise BenchmarkError("rehydration executable mismatch")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("record", type=Path)
    parser.add_argument(
        "--repository",
        type=Path,
        help="optional source checkout for rehydration checks",
    )
    parser.add_argument(
        "--executable",
        type=Path,
        help="optional executable whose hash is checked",
    )
    parser.add_argument(
        "--input-bundle",
        type=Path,
        help="optional versioned input bundle for manifest rehydration",
    )
    args = parser.parse_args()

    record = args.record.resolve()
    document = read_record(record)
    validate_harness_identity(document)
    source_revision = document.get("source_revision")
    if not isinstance(source_revision, str) or not re.fullmatch(
        r"[0-9a-f]{40}", source_revision
    ):
        raise BenchmarkError("record has malformed source revision")

    cases, profiles = read_registry(Path(__file__).parent)
    case, expected = validate_case_and_execution(document, cases, profiles)
    entries = validate_input_bundle(document, case.input_identity)
    profile_name = document["execution"]["profile"]
    validate_capture_provenance(document, record, profiles[profile_name])
    comparison_paths = validate_comparison_binding(
        document,
        case.input_identity,
        record,
        entries,
    )

    capture = document.get("capture")
    repetitions = document.get("repetitions")
    requested = capture.get("repetitions_requested") if isinstance(capture, dict) else None
    if not isinstance(repetitions, list) or not isinstance(requested, int):
        raise BenchmarkError("missing repetition list")
    if requested < 1 or len(repetitions) != requested:
        raise BenchmarkError("missing or short repetition list")
    runtime = capture.get("runtime") if isinstance(capture, dict) else None
    topology = runtime.get("xnet_topology") if isinstance(runtime, dict) else None
    if not isinstance(topology, dict):
        raise BenchmarkError("capture lacks XNet topology evidence")
    for number, repetition in enumerate(repetitions, start=1):
        validate_repetition(
            repetition,
            number,
            expected,
            record,
            comparison_paths,
            case.workload["regression_factory"],
            topology,
        )

    validate_inventory(record)
    rehydrate(
        args.repository,
        args.input_bundle,
        args.executable,
        entries,
        document,
    )
    print(f"valid benchmark record: {record}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BenchmarkError as error:
        print(f"validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
