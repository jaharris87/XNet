# XNet benchmark records

This directory captures reproducible XNet benchmark evidence, not a performance
winner, platform qualification, or regression-suite replacement. Capture
requires an explicit full source revision and a clean checkout at that exact
revision.

Issue #127 currently uses this tooling for the pre-v9 baseline campaign. That
campaign is pinned to source revision
`86e867c2a64267a674ce4fbf6a3064af39e2f4e0`.

`cases.json` is the sole registry. It keeps case ID, scientific network and
workload identity, and execution profile separate. The bounded profiles are
`serial-dense`, `openmp-dense`, `mpi-dense`, `accelerator-dense`,
`mpi-accelerator-dense`, and opt-in `serial-ma48`; workload dimensions never
become profile or case identities.

```sh
python3 test/benchmark/capture.py --list-cases
python3 test/benchmark/capture.py --repository /scratch/xnet-source \
  --source-revision 86e867c2a64267a674ce4fbf6a3064af39e2f4e0 \
  --input-bundle /scratch/xnet-benchmark-inputs \
  --input-bundle-revision 86e867c2a64267a674ce4fbf6a3064af39e2f4e0 \
  --build-dir /scratch/xnet-benchmark-build \
  --records /scratch/xnet-benchmark-records \
  --case batch_alpha --repetitions 5
```

Capture owns a fresh build directory and never accepts an arbitrary executable.
The frozen source checkout supplies only the executable. The separately
identified input bundle supplies the comparator, reference, network, workload,
and runtime inputs; the ready historical cases use the same checkout for both
roles, while later reviewed bundles may have a newer identity.
Each fresh process uses the registered input bundle's maintained
`test/regression/xnet_regression.py` characterization for `batch_alpha` or
`heat_sn160`. XNet execution is timed separately; parsing and comparison are
afterward, outside the timing interval, but a numerical comparison pass and
its diagnostics are required and retained.

Records have no required live absolute path: source and harness identities,
copied build config/log, bundle-relative input hashes, executable hash (the
executable is not copied), resolved compiler and linked-runtime evidence,
CPU/topology and affinity facts, per-worker raw timers/counters, standard
streams, all worker diagnostics, captured comparator/reference, comparison
result, environment, and final artifact checksum inventory are kept. Portable
validation reparses every worker diagnostic, verifies rank/team topology,
merges final states by global zone, and reruns the captured comparator after
timing.

```sh
python3 test/benchmark/validate.py /scratch/xnet-benchmark-records/batch_alpha-...
python3 test/benchmark/test_benchmark.py /scratch/xnet-benchmark-records/batch_alpha-...
```

`validate.py` works offline. Optional `--repository` and `--executable`
rehydrate source and executable identity; `--input-bundle` separately
rehydrates the versioned benchmark-input manifest when it is locally available.

`batch_alpha` and `heat_sn160` are representative application cases. They
support statements about those real standalone workloads, not general scaling
conclusions. A future controlled family will use a reviewed common
thermodynamic state and composition projection across network sizes; it is the
appropriate basis for scaling conclusions. The registry records the proposed
fixed C/O state, projection rule, zone counts, and separate CPU/GPU batching
dimensions explicitly; its status remains `proposed-awaiting-scientific-approval`.
Candidate CCSN and ECSN cases remain unavailable until that approval, their
network/input provenance, and accepted numerical references are complete.

MPI captures require `--launcher 'mpiexec -n N'`, `--ranks N`, and the actual
thread count. The harness runs its own probe through that exact launcher and
checks the observed rank IDs, hosts, CPU affinity, allocation context, and
XNet's own `MyId` records. OpenMP captures additionally require the requested
`OMP_NUM_THREADS`; XNet's per-thread diagnostic headers prove the actual team.
Caller-authored placement JSON is neither accepted nor trusted.
OpenMP and one-rank accelerator profiles accept an optional site launcher such
as `srun`; MPI profiles require one. Site compiler selections are explicit,
repeatable `--build-option NAME=VALUE` arguments limited to `PE_ENV`, `CMODE`,
`MACHINE`, `LAPACK_VER`, and `EOS`, and remain visible in the retained build
command and resolved configuration.

Accelerator profiles require `--gpu-backend CUDA|HIP` and
`--accelerator-mode openacc|openmp-offload`. The capture builds
`xnet_benchmark_gpu_probe` from the retained probe source and the same
configured XNet objects as the executable, then launches it with the exact
benchmark launcher. A passing record requires a device-resident mapped solve,
the observed rank-to-device mapping, and retained `nvidia-smi` or `rocm-smi`
physical-device/runtime output. Visible-device environment variables alone are
not evidence. `--ranks-per-gpu` is explicit and its observed host/device group
counts must match for the one- and two-ranks-per-GPU slices;
site launch options remain explicit argv rather than site-specific harness
forks.

`serial-ma48` is available only with `--ma48-dir` naming a licensed external
`MA48.f`. Its hash and the resulting build/executable identities are retained,
but neither the licensed source nor its contents are copied into the record.
