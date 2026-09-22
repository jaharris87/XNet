#!/usr/bin/env python3
"""Synthetic false-pass probes for capture-owned execution evidence."""
from __future__ import annotations
from copy import deepcopy
from pathlib import Path
from benchmark import BenchmarkError, read_registry
from validate import validate_runtime_evidence


def reject(name, profile, runtime, environment, text):
    try:
        validate_runtime_evidence(profile, runtime, [*runtime["launcher_argv"], "/build/bin/xnet"], "/build/bin/xnet", environment)
    except BenchmarkError as error:
        if text not in str(error):
            raise RuntimeError(f"{name}: unexpected rejection {error}") from error
    else:
        raise RuntimeError(f"false pass: {name}")


def main():
    _, profiles = read_registry(Path(__file__).parent)
    profile = profiles["mpi-dense"]
    runtime = {"launcher_argv": ["mpiexec", "-n", "2"], "requested_ranks": 2, "requested_threads": 1,
               "launcher_probe": {"allocation": {"kind": "scheduler", "environment": {"SLURM_JOB_ID": "1"}}, "observations": [{"rank": "0", "host": "node0", "affinity": [0]}, {"rank": "1", "host": "node0", "affinity": [1]}]},
               "xnet_topology": {"ranks": [{"rank": 0, "size": 2}, {"rank": 1, "size": 2}], "threads": []}}
    validate_runtime_evidence(profile, runtime, [*runtime["launcher_argv"], "/build/bin/xnet"], "/build/bin/xnet", {})
    for name, mutate, text in (
        ("fabricated placement", lambda x: x["launcher_probe"].update(observations=[]), "rank IDs"),
        ("wrong launcher ranks", lambda x: x["launcher_argv"].__setitem__(2, "1"), "launcher rank count"),
        ("wrong XNet ranks", lambda x: x["xnet_topology"]["ranks"].pop(), "rank topology"),
        ("missing scheduler", lambda x: x["launcher_probe"].update(allocation={"kind": "scheduler", "environment": {}}), "scheduler"),
    ):
        bad = deepcopy(runtime); mutate(bad); reject(name, profile, bad, {}, text)
    openmp = profiles["openmp-dense"]
    threaded = {"launcher_argv": [], "requested_ranks": 1, "requested_threads": 2,
                "launcher_probe": {"allocation": {"kind": "unscheduled-local", "host": "node", "affinity": [0]}, "observations": [{"rank": None, "host": "node", "affinity": [0]}]},
                "xnet_topology": {"ranks": [{"rank": 0, "size": 1}], "threads": [{"rank": 0, "thread": 1, "team": 2}, {"rank": 0, "thread": 2, "team": 2}]},
                "openmp_probe": {"observations": [{"rank": "0", "thread": 0, "team": 2, "place": 0, "binding": 3}, {"rank": "0", "thread": 1, "team": 2, "place": 1, "binding": 3}]}}
    validate_runtime_evidence(openmp, threaded, ["/build/bin/xnet"], "/build/bin/xnet", {"OMP_NUM_THREADS": "2"})
    reject("wrong threads", openmp, threaded, {"OMP_NUM_THREADS": "1"}, "thread evidence")
    wrong_team = deepcopy(threaded); wrong_team["xnet_topology"]["threads"].pop()
    reject("wrong OpenMP team", openmp, wrong_team, {"OMP_NUM_THREADS": "2"}, "OpenMP topology")
    accelerator = deepcopy(threaded)
    accelerator.update(requested_threads=1, gpu_backend="CUDA", accelerator_mode="openacc")
    accelerator["xnet_topology"]["threads"] = []
    accelerator["accelerator_evidence"] = {"backend": "CUDA", "commands": [{}]}
    reject("false GPU/offload", profiles["accelerator-dense"], accelerator, {}, "offload probe")
    accelerator["offload_probe"] = {
        "observations": [
            {"rank": "0", "device": 0, "device_count": 1, "offloaded": True,
             "data_present": True, "info": 0, "residual": 0.0}
        ]
    }
    validate_runtime_evidence(
        profiles["accelerator-dense"], accelerator,
        ["/build/bin/xnet"], "/build/bin/xnet", {},
    )
    wrong_device = deepcopy(accelerator)
    wrong_device["offload_probe"]["observations"][0]["rank"] = "1"
    reject("wrong rank/device placement", profiles["accelerator-dense"], wrong_device, {}, "rank-to-device")
    host_fallback = deepcopy(accelerator)
    host_fallback["offload_probe"]["observations"][0]["offloaded"] = False
    reject("GPU host fallback", profiles["accelerator-dense"], host_fallback, {}, "device execution")
    shared_gpu = deepcopy(runtime)
    shared_gpu.update(
        requested_ranks_per_gpu=2,
        gpu_backend="CUDA",
        accelerator_mode="openacc",
        accelerator_evidence={"backend": "CUDA", "commands": [{}]},
        offload_probe={"observations": [
            {"rank": "0", "device": 0, "device_count": 1, "offloaded": True,
             "data_present": True, "info": 0, "residual": 0.0},
            {"rank": "1", "device": 0, "device_count": 1, "offloaded": True,
             "data_present": True, "info": 0, "residual": 0.0},
        ]},
    )
    for observation in shared_gpu["launcher_probe"]["observations"]:
        observation["cuda_visible"] = "GPU-a"
    validate_runtime_evidence(
        profiles["mpi-accelerator-dense"], shared_gpu,
        [*shared_gpu["launcher_argv"], "/build/bin/xnet"],
        "/build/bin/xnet", {},
    )
    wrong_sharing = deepcopy(shared_gpu)
    wrong_sharing["launcher_probe"]["observations"][1]["cuda_visible"] = "GPU-b"
    reject(
        "incorrect ranks-per-GPU placement",
        profiles["mpi-accelerator-dense"], wrong_sharing, {}, "ranks per GPU",
    )
    print("execution-profile synthetic probes: passed")


if __name__ == "__main__":
    main()
