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
               "launcher_probe": {"scheduler": {"SLURM_JOB_ID": "1"}, "observations": [{"rank": "0", "host": "node0", "affinity": [0]}, {"rank": "1", "host": "node0", "affinity": [1]}]},
               "xnet_topology": [{"rank": 0, "size": 2}, {"rank": 1, "size": 2}]}
    validate_runtime_evidence(profile, runtime, [*runtime["launcher_argv"], "/build/bin/xnet"], "/build/bin/xnet", {})
    for name, mutate, text in (
        ("fabricated placement", lambda x: x["launcher_probe"].update(observations=[]), "rank IDs"),
        ("wrong launcher ranks", lambda x: x.update(requested_ranks=1), "multiple ranks"),
        ("wrong XNet ranks", lambda x: x["xnet_topology"].pop(), "rank topology"),
        ("missing scheduler", lambda x: x["launcher_probe"].update(scheduler={}), "scheduler"),
    ):
        bad = deepcopy(runtime); mutate(bad); reject(name, profile, bad, {}, text)
    openmp = profiles["openmp-dense"]
    threaded = {"launcher_argv": [], "requested_ranks": 1, "requested_threads": 2,
                "launcher_probe": {"scheduler": {}, "observations": [{"rank": None, "host": "node", "affinity": [0]}]},
                "xnet_topology": [{"rank": 0, "size": 1}, {"thread": 1, "team": 2}, {"thread": 2, "team": 2}]}
    validate_runtime_evidence(openmp, threaded, ["/build/bin/xnet"], "/build/bin/xnet", {"OMP_NUM_THREADS": "2"})
    reject("wrong threads", openmp, threaded, {"OMP_NUM_THREADS": "1"}, "thread evidence")
    reject("wrong OpenMP team", openmp, {**threaded, "xnet_topology": threaded["xnet_topology"][:-1]}, {"OMP_NUM_THREADS": "2"}, "OpenMP topology")
    reject("false GPU/offload", profiles["accelerator-dense"], {**threaded, "requested_threads": 1}, {}, "offload probe")
    print("execution-profile synthetic probes: passed")


if __name__ == "__main__":
    main()
