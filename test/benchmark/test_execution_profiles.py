#!/usr/bin/env python3
"""Synthetic false-pass probes for capture-owned execution evidence."""

from __future__ import annotations

from copy import deepcopy
from pathlib import Path
import tempfile
from typing import Any, Callable

from benchmark import (
    BenchmarkError,
    parse_device_probe,
    parse_openmp_probe,
    parse_slurm_job,
    read_registry,
)
from capture import compiler_evidence, shared_run_directory
from validate import (
    require_transcript_summary,
    validate_accelerator_identity_entry,
    validate_runtime_evidence,
    validate_slurm_query_command,
)

EXECUTABLE = "/build/bin/xnet"


def slurm_environment(ranks: int, threads: int, *, gpu: bool = False) -> dict[str, str]:
    environment = {
        "SLURM_JOB_ID": "1",
        "SLURM_NTASKS": str(ranks),
        "SLURM_CPUS_PER_TASK": str(threads),
    }
    if gpu:
        environment["SLURM_GPUS_PER_NODE"] = "1"
    return environment


def rank_observation(rank: int, cpu: int) -> dict[str, Any]:
    return {"rank": str(rank), "host": "node0", "affinity": [cpu]}


def add_slurm_step(
    observation: dict[str, Any], ranks: int, threads: int = 1
) -> dict[str, Any]:
    observation["slurm_step"] = {
        "SLURM_STEP_ID": "7",
        "SLURM_STEP_NUM_TASKS": str(ranks),
        "SLURM_NTASKS": str(ranks),
        "SLURM_CPUS_PER_TASK": str(threads),
    }
    return observation


def xnet_topology(ranks: int, threads: int = 1) -> dict[str, Any]:
    thread_rows = []
    if threads > 1:
        thread_rows = [
            {"rank": rank, "thread": thread, "team": threads}
            for rank in range(ranks)
            for thread in range(1, threads + 1)
        ]
    return {
        "ranks": [{"rank": rank, "size": ranks} for rank in range(ranks)],
        "threads": thread_rows,
    }


def mpi_runtime() -> dict[str, Any]:
    scheduler = slurm_environment(2, 1)
    return {
        "launcher_argv": ["mpiexec", "-n", "2"],
        "requested_ranks": 2,
        "requested_threads": 1,
        "launcher_probe": {
            "allocation": {
                "kind": "scheduler",
                "scope": "allocation",
                "environment": scheduler,
                "scheduler_probe": {
                    "fields": {
                        "JobId": scheduler["SLURM_JOB_ID"],
                        "NumTasks": scheduler["SLURM_NTASKS"],
                        "CPUs/Task": scheduler["SLURM_CPUS_PER_TASK"],
                        "AllocTRES": "cpu=2",
                    }
                },
            },
            "observations": [rank_observation(0, 0), rank_observation(1, 1)],
        },
        "xnet_topology": xnet_topology(2),
    }


def openmp_runtime() -> dict[str, Any]:
    return {
        "launcher_argv": [],
        "requested_ranks": 1,
        "requested_threads": 2,
        "launcher_probe": {
            "allocation": {
                "kind": "unscheduled-local",
                "host": "node0",
                "affinity": [0, 1],
            },
            "observations": [
                {"rank": None, "host": "node0", "affinity": [0, 1]}
            ],
        },
        "xnet_topology": xnet_topology(1, 2),
        "openmp_probe": {
            "observations": [
                {"rank": "0", "thread": 0, "team": 2, "place": 0, "binding": 3, "affinity": [0]},
                {"rank": "0", "thread": 1, "team": 2, "place": 1, "binding": 3, "affinity": [1]},
            ]
        },
    }


def device_observation(rank: int, device: int = 0) -> dict[str, Any]:
    return {
        "rank": str(rank),
        "device": device,
        "device_count": 1,
        "offloaded": True,
        "data_present": True,
        "info": 0,
        "residual": 0.0,
    }


def accelerator_runtime() -> dict[str, Any]:
    runtime = openmp_runtime()
    runtime.update(
        requested_threads=1,
        gpu_backend="CUDA",
        accelerator_mode="openacc",
        accelerator_evidence={"backend": "CUDA", "commands": [{}]},
        offload_probe={"observations": [device_observation(0)]},
    )
    runtime["xnet_topology"] = xnet_topology(1)
    runtime.pop("openmp_probe")
    return runtime


def validate(profile: dict[str, Any], runtime: dict[str, Any], environment: dict[str, str]) -> None:
    run_argv = [*runtime["launcher_argv"], EXECUTABLE]
    validate_runtime_evidence(profile, runtime, run_argv, EXECUTABLE, environment)


def reject(
    name: str,
    profile: dict[str, Any],
    runtime: dict[str, Any],
    environment: dict[str, str],
    expected_message: str,
) -> None:
    try:
        validate(profile, runtime, environment)
    except BenchmarkError as error:
        if expected_message not in str(error):
            raise RuntimeError(f"{name}: unexpected rejection {error}") from error
    else:
        raise RuntimeError(f"false pass: {name}")


def mutated(runtime: dict[str, Any], change: Callable[[dict[str, Any]], None]) -> dict[str, Any]:
    result = deepcopy(runtime)
    change(result)
    return result


def check_transcript_boundaries() -> None:
    """Exercise raw-to-summary checks for evidence unavailable on this host."""
    samples = (
        (
            "openmp",
            "XNET_BENCHMARK_OPENMP rank 0 thread 0 team 1 place 0 binding 3 cpus 0,128\n",
            parse_openmp_probe,
        ),
        (
            "offload",
            "XNET_BENCHMARK_DEVICE rank 0 device 0 count 1 offloaded T "
            "data_present T info 0 residual 0.0\n",
            parse_device_probe,
        ),
        (
            "slurm",
            "JobId=1 NumTasks=2 CPUs/Task=1 AllocTRES=cpu=2,gres/gpu=1\n",
            parse_slurm_job,
        ),
    )
    with tempfile.TemporaryDirectory(prefix="xnet-benchmark-evidence-test-") as temporary:
        for name, text, parser in samples:
            transcript = Path(temporary) / f"{name}.txt"
            transcript.write_text(text, encoding="utf-8")
            summary = parser(transcript)
            require_transcript_summary(parser, transcript, summary, "summary mismatch")
            try:
                require_transcript_summary(
                    parser,
                    transcript,
                    {"fabricated": True},
                    "summary mismatch",
                )
            except BenchmarkError as error:
                if str(error) != "summary mismatch":
                    raise RuntimeError(f"{name}: unexpected transcript rejection") from error
            else:
                raise RuntimeError(f"false pass: {name} transcript summary")

        malformed_samples = (
            (
                "openmp labels",
                "XNET_BENCHMARK_OPENMP rank 0 banana 0 team 1 place 0 binding 3 cpus 0\n",
                parse_openmp_probe,
            ),
            (
                "offload labels",
                "XNET_BENCHMARK_DEVICE rank 0 device 0 nonsense 1 offloaded T "
                "data_present T info 0 residual 0.0\n",
                parse_device_probe,
            ),
        )
        for name, text, parser in malformed_samples:
            transcript = Path(temporary) / f"malformed-{name}.txt"
            transcript.write_text(text, encoding="utf-8")
            try:
                parser(transcript)
            except BenchmarkError:
                pass
            else:
                raise RuntimeError(f"false pass: malformed {name}")

        slurm_entry = {
            "argv": ["/usr/bin/scontrol", "show", "job", "1", "--oneliner"],
            "tool_sha256": "0" * 64,
        }
        validate_slurm_query_command(slurm_entry, {"SLURM_JOB_ID": "1"})
        substituted_slurm = deepcopy(slurm_entry)
        substituted_slurm["argv"] = ["/bin/echo", "fake allocation"]
        try:
            validate_slurm_query_command(
                substituted_slurm,
                {"SLURM_JOB_ID": "1"},
            )
        except BenchmarkError:
            pass
        else:
            raise RuntimeError("false pass: substituted Slurm query")

        nvidia = Path(temporary) / "nvidia-smi.txt"
        nvidia.write_text("GPU 0: A100 (UUID: GPU-a)\n", encoding="utf-8")
        nvidia_entry = {
            "argv": ["/usr/bin/nvidia-smi", "-L"],
            "tool_sha256": "0" * 64,
        }
        validate_accelerator_identity_entry("CUDA", 1, nvidia_entry, nvidia)
        substituted_nvidia = deepcopy(nvidia_entry)
        substituted_nvidia["argv"] = ["/bin/true"]
        try:
            validate_accelerator_identity_entry(
                "CUDA",
                1,
                substituted_nvidia,
                nvidia,
            )
        except BenchmarkError:
            pass
        else:
            raise RuntimeError("false pass: substituted accelerator identity command")


def main() -> None:
    _, profiles = read_registry(Path(__file__).parent)
    check_transcript_boundaries()

    mpi = mpi_runtime()
    validate(profiles["mpi-dense"], mpi, {})

    # One allocation may legitimately host several sequential, smaller srun
    # steps. Allocation evidence proves capacity; launcher, step, probe, and
    # XNet evidence continue to prove the exact two-rank execution geometry.
    oversized_allocation = deepcopy(mpi)
    oversized_environment = oversized_allocation["launcher_probe"]["allocation"][
        "environment"
    ]
    oversized_environment["SLURM_NTASKS"] = "8"
    oversized_environment["SLURM_CPUS_PER_TASK"] = "4"
    oversized_fields = oversized_allocation["launcher_probe"]["allocation"][
        "scheduler_probe"
    ]["fields"]
    oversized_fields["NumTasks"] = "8"
    oversized_fields["CPUs/Task"] = "4"
    oversized_fields["AllocTRES"] = "cpu=32,gres/gpu=4"
    oversized_allocation["launcher_probe"]["observations"] = [
        add_slurm_step(rank_observation(0, 0), 2),
        add_slurm_step(rank_observation(1, 1), 2),
    ]
    validate(profiles["mpi-dense"], oversized_allocation, {})
    mpi_mutations = (
        (
            "fabricated placement",
            lambda value: value["launcher_probe"].update(observations=[]),
            "host or binding evidence",
        ),
        (
            "wrong launcher ranks",
            lambda value: value["launcher_argv"].__setitem__(2, "1"),
            "launcher rank count",
        ),
        (
            "wrong XNet ranks",
            lambda value: value["xnet_topology"]["ranks"].pop(),
            "rank topology",
        ),
        (
            "wrong scheduler ranks",
            lambda value: value["launcher_probe"]["allocation"]["environment"].update(
                SLURM_NTASKS="1"
            ),
            "Slurm allocation lacks sufficient task capacity",
        ),
        (
            "wrong scheduler query ranks",
            lambda value: value["launcher_probe"]["allocation"][
                "scheduler_probe"
            ]["fields"].update(NumTasks="1"),
            "Slurm allocation query lacks sufficient task capacity",
        ),
    )
    for name, change, message in mpi_mutations:
        reject(name, profiles["mpi-dense"], mutated(mpi, change), {}, message)
    reject(
        "allocation and query task disagreement",
        profiles["mpi-dense"],
        mutated(
            oversized_allocation,
            lambda value: value["launcher_probe"]["allocation"][
                "scheduler_probe"
            ]["fields"].update(NumTasks="4"),
        ),
        {},
        "task count disagrees with the allocation",
    )
    reject(
        "wrong Slurm step ranks",
        profiles["mpi-dense"],
        mutated(
            oversized_allocation,
            lambda value: value["launcher_probe"]["observations"][1][
                "slurm_step"
            ].update(SLURM_STEP_NUM_TASKS="1"),
        ),
        {},
        "step task count",
    )

    threaded = openmp_runtime()
    validate(profiles["openmp-dense"], threaded, {"OMP_NUM_THREADS": "2"})
    reject(
        "wrong threads",
        profiles["openmp-dense"],
        threaded,
        {"OMP_NUM_THREADS": "1"},
        "thread evidence",
    )
    reject(
        "wrong OpenMP team",
        profiles["openmp-dense"],
        mutated(threaded, lambda value: value["xnet_topology"]["threads"].pop()),
        {"OMP_NUM_THREADS": "2"},
        "OpenMP topology",
    )
    reject(
        "duplicate OpenMP placement",
        profiles["openmp-dense"],
        mutated(
            threaded,
            lambda value: value["openmp_probe"]["observations"][1].update(place=0),
        ),
        {"OMP_NUM_THREADS": "2"},
        "distinct bound places",
    )
    perlmutter_threaded = deepcopy(threaded)
    perlmutter_threaded["launcher_argv"] = [
        "srun", "-n", "1", "-c", "8", "--cpu-bind=cores"
    ]
    perlmutter_threaded["requested_threads"] = 4
    perlmutter_threaded["xnet_topology"] = xnet_topology(1, 4)
    scheduler = slurm_environment(2, 8)
    perlmutter_threaded["launcher_probe"] = {
        "allocation": {
            "kind": "scheduler",
            "scope": "allocation",
            "environment": scheduler,
            "scheduler_probe": {
                "fields": {
                    "JobId": scheduler["SLURM_JOB_ID"],
                    "NumTasks": scheduler["SLURM_NTASKS"],
                    "CPUs/Task": scheduler["SLURM_CPUS_PER_TASK"],
                    "AllocTRES": "cpu=16",
                }
            },
        },
        "observations": [
            add_slurm_step(rank_observation(0, 0), 1, 8)
        ],
    }
    perlmutter_threaded["launcher_probe"]["observations"][0]["affinity"] = [
        0, 128
    ]
    perlmutter_threaded["openmp_probe"]["observations"] = [
        {"rank": "0", "thread": thread, "team": 4, "place": thread,
         "binding": 4, "affinity": [thread, thread + 128]}
        for thread in range(4)
    ]
    validate(
        profiles["openmp-dense"],
        perlmutter_threaded,
        {"OMP_NUM_THREADS": "4"},
    )
    reject(
        "overlapping OpenMP CPU sets",
        profiles["openmp-dense"],
        mutated(
            threaded,
            lambda value: value["openmp_probe"]["observations"][1].update(
                affinity=[0]
            ),
        ),
        {"OMP_NUM_THREADS": "2"},
        "disjoint bound CPU sets",
    )

    with tempfile.TemporaryDirectory(prefix="xnet-compiler-evidence-test-") as temporary:
        temporary_path = Path(temporary)
        compiler = temporary_path / "linking-wrapper"
        compiler.write_text(
            "#!/bin/sh\n"
            "if [ \"$#\" -eq 1 ]; then\n"
            "  echo 'simulated link failure' >&2\n"
            "  exit 2\n"
            "fi\n"
            "echo 'wrapped compiler 1.0'\n",
            encoding="utf-8",
        )
        compiler.chmod(0o755)
        evidence = compiler_evidence(temporary_path, {"FC": str(compiler)})
        attempts = evidence.get("version_attempts")
        if (
            not isinstance(attempts, list)
            or [attempt.get("status") for attempt in attempts] != [2, 0]
            or attempts[-1].get("argv") != [str(compiler), "--version", "-c"]
            or evidence.get("version") != attempts[-1]
        ):
            raise RuntimeError("compiler-version fallback evidence is incomplete")
        record = temporary_path / "record"
        record.mkdir()
        with shared_run_directory(record) as work:
            if work.parent.parent != record or not work.parent.is_dir():
                raise RuntimeError("launcher work directory is not record-local")

    # OpenMP+MA48 uses the same observed thread/placement evidence as the
    # dense OpenMP path, but its registry identity and build selectors must
    # remain unambiguously MA48 and require the licensed external source.
    openmp_ma48 = profiles["openmp-ma48"]
    validate(openmp_ma48, threaded, {"OMP_NUM_THREADS": "2"})
    if (
        openmp_ma48["dimensions"]["solver"] != "MA48"
        or openmp_ma48["build_selectors"]["MATRIX_SOLVER"] != "MA48"
        or openmp_ma48.get("external_source") != "MA48.f"
        or openmp_ma48 == profiles["openmp-dense"]
    ):
        raise RuntimeError("openmp-ma48 is not distinct from openmp-dense")
    reject(
        "wrong OpenMP+MA48 thread count",
        openmp_ma48,
        threaded,
        {"OMP_NUM_THREADS": "1"},
        "thread evidence",
    )

    accelerator = accelerator_runtime()
    missing_offload = deepcopy(accelerator)
    missing_offload.pop("offload_probe")
    reject(
        "false GPU/offload",
        profiles["accelerator-dense"],
        missing_offload,
        {},
        "offload probe",
    )
    validate(profiles["accelerator-dense"], accelerator, {})
    reject(
        "wrong rank/device placement",
        profiles["accelerator-dense"],
        mutated(
            accelerator,
            lambda value: value["offload_probe"]["observations"][0].update(rank="1"),
        ),
        {},
        "rank-to-device",
    )
    reject(
        "out-of-range device",
        profiles["accelerator-dense"],
        mutated(
            accelerator,
            lambda value: value["offload_probe"]["observations"][0].update(device=99),
        ),
        {},
        "device execution",
    )
    reject(
        "GPU host fallback",
        profiles["accelerator-dense"],
        mutated(
            accelerator,
            lambda value: value["offload_probe"]["observations"][0].update(
                offloaded=False
            ),
        ),
        {},
        "device execution",
    )

    shared_gpu = mpi_runtime()
    shared_gpu.update(
        launcher_argv=["srun", "-n", "2", "-c", "4"],
        requested_ranks_per_gpu=2,
        gpu_backend="CUDA",
        accelerator_mode="openacc",
        accelerator_evidence={"backend": "CUDA", "commands": [{}]},
        offload_probe={
            "observations": [device_observation(0), device_observation(1)]
        },
    )
    scheduler = shared_gpu["launcher_probe"]["allocation"]["environment"]
    scheduler.update(
        SLURM_NTASKS="8",
        SLURM_CPUS_PER_TASK="4",
        SLURM_GPUS_PER_NODE="4",
    )
    scheduler_fields = shared_gpu["launcher_probe"]["allocation"][
        "scheduler_probe"
    ]["fields"]
    scheduler_fields.update(
        NumTasks="8",
        **{"CPUs/Task": "4", "AllocTRES": "cpu=32,gres/gpu=4"},
    )
    for rank, observation in enumerate(
        shared_gpu["launcher_probe"]["observations"]
    ):
        observation["cuda_visible"] = "GPU-a"
        add_slurm_step(observation, 2, 4)
    validate(profiles["mpi-accelerator-dense"], shared_gpu, {})
    reject(
        "incorrect ranks-per-GPU placement",
        profiles["mpi-accelerator-dense"],
        mutated(
            shared_gpu,
            lambda value: value["launcher_probe"]["observations"][1].update(
                cuda_visible="GPU-b"
            ),
        ),
        {},
        "ranks per GPU",
    )
    duplicate_device_row = deepcopy(shared_gpu)
    duplicate_device_row["offload_probe"]["observations"].insert(
        1,
        device_observation(0),
    )
    reject(
        "duplicate device observation",
        profiles["mpi-accelerator-dense"],
        duplicate_device_row,
        {},
        "rank-to-device",
    )
    reject(
        "malformed scheduler GPU allocation",
        profiles["mpi-accelerator-dense"],
        mutated(
            shared_gpu,
            lambda value: value["launcher_probe"]["allocation"][
                "environment"
            ].update(SLURM_GPUS_PER_NODE="nonsense"),
        ),
        {},
        "malformed GPU allocation",
    )
    reject(
        "malformed scheduler GPU query",
        profiles["mpi-accelerator-dense"],
        mutated(
            shared_gpu,
            lambda value: value["launcher_probe"]["allocation"][
                "scheduler_probe"
            ]["fields"].update(AllocTRES="cpu=2,gres/gpu=nonsense"),
        ),
        {},
        "sufficient GPU allocation",
    )
    reject(
        "insufficient scheduler GPU query",
        profiles["mpi-accelerator-dense"],
        mutated(
            shared_gpu,
            lambda value: value["launcher_probe"]["allocation"][
                "scheduler_probe"
            ]["fields"].update(AllocTRES="cpu=2"),
        ),
        {},
        "sufficient GPU allocation",
    )
    print("execution-profile synthetic probes: passed")


if __name__ == "__main__":
    main()
