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
CPU/topology and affinity facts, raw timers/counters, standard streams,
diagnostics, captured comparator/reference, comparison result, environment,
and final artifact checksum inventory are kept. Portable validation reparses
the raw diagnostic and reruns the captured comparator after timing.

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
appropriate basis for scaling conclusions. Candidate CCSN and ECSN families
remain unavailable until their reviewed workload and provenance are defined.

Facility runs require separately reviewed launcher and execution-profile support.

MPI captures require `--launcher 'mpiexec -n N'`, rank and thread counts. The
harness runs and retains its own probe through that exact launcher, then checks
its observed rank IDs, hosts, affinity, scheduler environment, and XNet's own
`MyId` records. It does not accept caller-authored placement JSON.
Accelerator capture requires `--offload-probe`, a facility probe command run
through the same launcher. Its retained output must report the existing
`XNET_GPU_LINALG` device count, selected device, and true offload result; a
visible-device environment variable alone is not evidence.
`serial-ma48` is available only with `--ma48-dir` naming a licensed external
`MA48.f`; neither that source nor its contents are retained in the record.
