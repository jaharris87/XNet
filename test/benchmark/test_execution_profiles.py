#!/usr/bin/env python3
"""Synthetic false-pass probes for capture-owned execution evidence."""

from __future__ import annotations

from copy import deepcopy
from pathlib import Path
from typing import Any, Callable

from benchmark import BenchmarkError, read_registry
from validate import validate_runtime_evidence

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
    return {
        "launcher_argv": ["mpiexec", "-n", "2"],
        "requested_ranks": 2,
        "requested_threads": 1,
        "launcher_probe": {
            "allocation": {
                "kind": "scheduler",
                "environment": slurm_environment(2, 1),
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
                {"rank": "0", "thread": 0, "team": 2, "place": 0, "binding": 3},
                {"rank": "0", "thread": 1, "team": 2, "place": 1, "binding": 3},
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


def main() -> None:
    _, profiles = read_registry(Path(__file__).parent)

    mpi = mpi_runtime()
    validate(profiles["mpi-dense"], mpi, {})
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
            "Slurm task count",
        ),
    )
    for name, change, message in mpi_mutations:
        reject(name, profiles["mpi-dense"], mutated(mpi, change), {}, message)

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
    reject(
        "insufficient OpenMP affinity",
        profiles["openmp-dense"],
        mutated(
            threaded,
            lambda value: value["launcher_probe"]["observations"][0].update(
                affinity=[0]
            ),
        ),
        {"OMP_NUM_THREADS": "2"},
        "affinity cannot cover",
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
        requested_ranks_per_gpu=2,
        gpu_backend="CUDA",
        accelerator_mode="openacc",
        accelerator_evidence={"backend": "CUDA", "commands": [{}]},
        offload_probe={
            "observations": [device_observation(0), device_observation(1)]
        },
    )
    scheduler = shared_gpu["launcher_probe"]["allocation"]["environment"]
    scheduler["SLURM_GPUS_PER_NODE"] = "1"
    for observation in shared_gpu["launcher_probe"]["observations"]:
        observation["cuda_visible"] = "GPU-a"
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
    print("execution-profile synthetic probes: passed")


if __name__ == "__main__":
    main()
