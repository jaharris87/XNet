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
`mpi-accelerator-dense`, and opt-in `serial-ma48` and `openmp-ma48`; workload
dimensions never become profile or case identities.

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
conclusions. The controlled-scaling family uses the reviewed common fixed C/O
state, identity composition projection, and approved 10-second early-plateau
duration across network sizes; it is the appropriate basis for bounded scaling
conclusions, not an equilibrium claim. The registry records that workload,
zone counts, and separate CPU/GPU batching dimensions explicitly. Controlled
cases remain candidates until accepted numerical references and applicable
execution-profile qualification are complete.

MPI captures require `--launcher 'mpiexec -n N'`, `--ranks N`, and the actual
thread count. The harness runs its own probe through that exact launcher and
checks the observed rank IDs, hosts, CPU affinity, allocation context, and
XNet's own `MyId` records. MPI ranks on the same host must have disjoint CPU
affinity. OpenMP captures additionally require the requested
`OMP_NUM_THREADS`; XNet's per-thread diagnostic headers prove the actual team,
and every requested thread must occupy a distinct bound place.
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
counts must match the requested bounded ranks-per-GPU slice;
site launch options remain explicit argv rather than site-specific harness
forks.

The MA48 profiles are available only with `--ma48-dir` naming a licensed
external `MA48.f`. Its hash and the resulting build/executable identities are
retained, but neither the licensed source nor its contents are copied into the
record.

## Controlled workload definitions

The authoritative network payloads for controlled scaling are the committed
`test/Data_alpha`, `test/Data_CCSN52`, `test/Data_SN160`,
`test/Data_CCSN179`, and `test/Data_ECSN350` trees from upstream revision
`a958556833eaddcf956e8e17c27219818035fae1`. Their exact files and hashes are
recorded in `network-bundle-a9585568.json`. They are benchmark inputs in their
own right; byte-for-byte regeneration with `build_net` is not required.

The primary controlled state has `T9=1.7`, `rho=1.0e8 g cm^-3`, `Ye=0.5`,
`X(C12)=0.5`, and `X(O16)=0.5`, with all other species initially zero. It uses
fixed thermodynamics and self-heating off. Weak-off BDF characterization found
an apparent common early plateau around 1--10 seconds, followed by substantial
later composition evolution whose cause is not yet established. The maintainer
selected 10 seconds, the end of that apparent plateau, as the bounded workload
duration. This is a benchmark-workload definition, not a claim that any network
has reached equilibrium. Performance runs use the same 10-second physical
duration with normal weak reactions restored; their endpoints need not match
the weak-off characterization.

Endpoint characterization uses the maintained BDF controls rather than merely
changing the BE selector: `isolv=3`, ten nonlinear iterations, convergence
selector 3, and `ymin=1e-99`. XNet then disables the BE step-change caps and
uses `yacc` and `tolc` as BDF absolute and relative error tolerances. The tool
records both tolerances and supports deliberate tolerance-sensitivity runs.
Screening is an explicit `--screening on|off` choice; weak reactions and
self-heating remain off for this calibration regardless.

`cases.json` encodes the approved 10-second early-plateau duration explicitly.
`characterize.py` does not infer or authorize that choice merely because a
command finishes. Its report gives successive-composition norms, distance from
the latest successful sample, solver counters, and sensitivity to candidate
composition criteria and BDF tolerances. A failed late-time integration is
retained as a numerical limit, not reclassified as equilibrium. Issue #127
records the evidence and maintainer decision; issue #138 tracks the unresolved
late evolution separately for scientific diagnosis.

Characterization owns a fresh serial-dense build from the requested clean
source revision; it does not accept a caller-supplied executable. Its report
binds the build command, retained build log/configuration, executable hash,
network manifest, generated inputs, raw results, and final artifact inventory.
Timeouts, nonzero exits, and malformed diagnostics remain explicit failed
samples while independent network/time points continue. Any failed requested
sample suppresses an endpoint recommendation.

Normal fixed-work comparisons use 1024 zones; the partial-final-batch point
uses 1025. CPU OpenMP scaling uses `nzbatchmx=1`. GPU batch-size scaling uses
`1,4,16,64,128`. Rank-sharing work is defined per GPU: one GPU receives 1024
zones, so batch 128 supplies eight independent batches for a bounded maximum
of eight ranks sharing that GPU. Multi-GPU runs scale total zones to preserve
1024 zones per GPU.

Primary cross-network scaling keeps self-heating off. A separate sensitivity
slice compares self-heating off/on on SN160, CCSN179, and ECSN350 without
interpreting the result as pure network-size scaling. The secondary O/Ne/Mg
state (`X(O16)=0.6`, `X(Ne20)=0.3`, `X(Mg24)=0.1`) is first characterized at
`T9=2.0,2.2,2.5` on SN160 and CCSN179. It remains a bounded regime check, not a
duplicate of the full matrix.
