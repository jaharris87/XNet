# Pre-v9 benchmark measurements

This directory contains the small benchmark runner for issue #127. It records
timings and numerical results from the historical XNet source revision
`86e867c2a64267a674ce4fbf6a3064af39e2f4e0`. It is not a general benchmark
framework, a facility interface, or a system for qualifying a platform.

Do not modify the historical source. If a compiler or runtime configuration
requires a source patch, report that measurement as `UNAVAILABLE`. Later XNet
portability fixes must not be applied while measuring the pre-v9 source.

## Files

- `cases.json` records the approved workload, matrix controls, authoritative
  network hashes, and available cases.
- `run.py` verifies, builds, runs, times, compares, and retains one requested
  case/configuration.
- `references/` contains the reference results and comparison tolerances from
  the earlier issue #127 work. They support reproducible comparisons; they are
  not independent claims of scientific truth.
- `test_run.py` covers a few direct failure paths. It is deliberately not a
  general result-validation or tampering test suite.

Numerical parsing and comparison reuse `test/regression/xnet_regression.py`.
Comparison occurs after the timed XNet process exits.

## Controlled workload

The primary controlled workload is a fixed state with `T9=1.7`, density
`1.0e8 g cm^-3`, `Ye=0.5`, and equal C12/O16 mass fractions. It runs for 10
seconds with normal weak reactions and screening enabled. Self-heating is off
for the primary scaling workload.

Ten seconds is a bounded early-burn interval. It is not equilibrium and does
not represent a coupled multiphysics timestep.

Normal comparisons use 1024 zones. The deliberate partial-batch case uses
1025. CPU OpenMP scaling uses `nzbatchmx=1`. GPU batch-size measurements use
`1,4,16,64,128`. Self-heating on is a separate sensitivity study.

Small zone counts are allowed for setup and smoke runs, but are not baseline
matrix measurements.

## Run a benchmark

Use a clean checkout at the historical revision and new build and output
directories. The result records the Make selections and launcher arguments.
No shell interprets the final application argument vector.

Serial CPU smoke test:

```bash
python3 test/benchmark/run.py \
  --source /path/to/xnet-86e867c2 \
  --source-revision 86e867c2a64267a674ce4fbf6a3064af39e2f4e0 \
  --input-root "$PWD" \
  --case alpha --zones 4 --batch-size 1 \
  --build-dir /tmp/xnet-pre-v9-serial-build \
  --output /tmp/xnet-pre-v9-serial-record \
  --make-option PE_ENV=GNU --make-option CMODE=OPT \
  --make-option MPI_MODE=OFF --make-option OPENMP_MODE=OFF \
  --make-option GPU_MODE=OFF --make-option MATRIX_SOLVER=dense \
  --ranks 1 --threads 1 --repetitions 1
```

OpenMP CPU smoke test:

```bash
python3 test/benchmark/run.py \
  --source /path/to/xnet-86e867c2 \
  --source-revision 86e867c2a64267a674ce4fbf6a3064af39e2f4e0 \
  --input-root "$PWD" \
  --case alpha --zones 4 --batch-size 1 \
  --build-dir /tmp/xnet-pre-v9-openmp-build \
  --output /tmp/xnet-pre-v9-openmp-record \
  --make-option PE_ENV=GNU --make-option CMODE=OPT \
  --make-option MPI_MODE=OFF --make-option OPENMP_MODE=ON \
  --make-option GPU_MODE=OFF --make-option MATRIX_SOLVER=dense \
  --environment OMP_NUM_THREADS=2 \
  --environment OMP_PLACES=cores --environment OMP_PROC_BIND=close \
  --ranks 1 --threads 2 --repetitions 1
```

Frontier GPU smoke test (inside a one-GPU Slurm allocation):

```bash
python3 test/benchmark/run.py \
  --source /path/to/xnet-86e867c2 \
  --source-revision 86e867c2a64267a674ce4fbf6a3064af39e2f4e0 \
  --input-root "$PWD" \
  --case alpha --zones 4 --batch-size 4 \
  --build-dir /path/to/xnet-pre-v9-frontier-gpu-build \
  --output /path/to/xnet-pre-v9-frontier-gpu-record \
  --make-option PE_ENV=CRAY --make-option CMODE=OPT \
  --make-option MPI_MODE=OFF --make-option OPENMP_MODE=OFF \
  --make-option GPU_MODE=ON --make-option GPU_BACKEND=HIP \
  --make-option GPU_LAPACK_VER=ROCM --make-option OPENACC_MODE=OFF \
  --make-option OPENMP_OL_MODE=ON --make-option MATRIX_SOLVER=dense \
  --launcher "srun --nodes=1 --ntasks=1 --cpus-per-task=7 --gpus-per-task=1 --gpu-bind=closest" \
  --environment OMP_TARGET_OFFLOAD=MANDATORY \
  --ranks 1 --threads 1 --repetitions 1
```

The runner was tested with a serial CPU build, a two-thread OpenMP CPU build,
and a single-GPU Frontier build. Each test retained the wall time, build and
input revisions, command, XNet timers and counters, raw output, and numerical
comparison. MPI scaling, MPI+GPU, ranks-per-GPU, batch and network sweeps,
MA48 scaling, and self-heating sensitivity remain to be measured for #127.

The output directory contains `result.json`, the build log/configuration,
compiler version, generated controlled inputs, and one directory per raw
repetition with stdout, stderr, process status, and XNet diagnostics. The
record includes wall times, emitted timer sections, zone counters, numerical
comparison diagnostics, source and input revisions, the executable hash,
commands, and relevant module/binding/device environment.

Required input files are hashed once and copied into the output directory.
Every repetition and the numerical comparison use that copy. The runner checks
the source checkout before and after the build. It does not hash system tools,
reconstruct old runs, independently validate Slurm output, or run separate
OpenMP or GPU probe programs. The recorded launcher command, environment, XNet
diagnostics, and raw output are available for inspection.

## Numerical status

- `PASS`: every process completed and every post-timing comparison passed the
  configured tolerances.
- `FAIL`: a build, execution, required-output, parse, or numerical comparison
  failed.
- `QUALIFIED / DIFFERENT-NUMERICAL-PATH`: execution completed but comparison
  differs through a documented numerical path that the maintainer has approved
  for interpretation. Supply `--qualification-note`; the failed comparison
  remains in the result.
- `UNAVAILABLE`: the historical source cannot build or run the configuration.
  Supply `--record-unavailable 'precise reason'`. This records the requested
  build selections and command without patching the source.

Comparison limits are maintainer decisions. Do not widen them to make a new
toolchain pass.

## Measurements to collect for issue #127

The planned measurements answer specific performance questions rather than
forming a Cartesian product:

1. network-size scaling across alpha, CCSN52, SN160, CCSN179, and ECSN350;
2. CPU OpenMP scaling on selected larger networks with batch size one;
3. dense versus MA48, including one useful OpenMP MA48 comparison where the
   licensed source is available;
4. selected CPU versus GPU comparisons;
5. GPU batch-size scaling at `1,4,16,64,128`;
6. one ranks-per-GPU comparison where the historical source and facility
   support it;
7. selected self-heating off/on sensitivity points;
8. component timings reused from those runs; and
9. historical `batch_alpha` and `heat_sn160` comparability points.

Use one setup run followed by five retained repetitions unless the observed
behavior justifies a different count. If the historical source is incompatible
with a configuration, record that measurement as unavailable and continue.

## Future coupled XNet measurements

A future CHIMERA or Flash-X measurement should record the application and XNet
revisions, network and input revisions, caller and call site, zone count, batch
size, self-heating choice, rank/thread/device placement, call count, raw call
times, XNet component timers, and numerical comparison result. This file lists
the information to record; it does not define or implement a coupled workload.

## Focused checks

```bash
python3 -m py_compile test/benchmark/run.py test/benchmark/test_run.py
python3 test/benchmark/test_run.py
python3 test/benchmark/run.py --list-cases
```
