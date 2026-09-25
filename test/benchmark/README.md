# Exact pre-v9 benchmark capture

This directory implements the small benchmark contract for issue #127. It
captures timing and numerical evidence from the unmodified historical XNet
source at `86e867c2a64267a674ce4fbf6a3064af39e2f4e0`. It is not a general
benchmark framework, facility abstraction, or platform-qualification system.

The historical source is immutable. A configuration that requires a source
patch is `UNAVAILABLE` for the exact baseline. Later XNet fixes, including
current-development portability fixes, must not be applied as benchmark-time
overlays.

## Files

- `cases.json` records the approved workload, matrix controls, authoritative
  network hashes, and available cases.
- `run.py` verifies, builds, runs, times, compares, and retains one requested
  case/configuration.
- `references/` contains the accepted characterization values and comparison
  limits developed during the earlier issue #127 investigation. They are
  reproducibility references, not independent claims of scientific truth.
- `test_run.py` covers a few direct failure paths. It is deliberately not a
  record-mutation or evidence-framework test suite.

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

## Capture

Use a clean checkout at the exact historical revision and fresh build/output
paths. Make selections and launcher arguments are explicit and retained. No
shell interprets the final application argv.

Serial smoke example:

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

OpenMP smoke example:

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

Frontier single-GPU smoke example (inside an approved one-GPU allocation):

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

Before this tooling is frozen, one serial CPU, one multi-thread OpenMP CPU,
and one real GPU capture must each retain raw timing, provenance, XNet
timers/counters, and a post-timing numerical comparison. MPI scaling,
MPI+GPU, ranks-per-GPU, batch/network sweeps, MA48 scaling, and self-heating
sensitivity remain later campaign work.

The output directory contains `result.json`, the build log/configuration,
compiler version, generated controlled inputs, and one directory per raw
repetition with stdout, stderr, process status, and XNet diagnostics. The
record includes wall times, emitted timer sections, zone counters, numerical
comparison diagnostics, source/input identities, the executable hash, exact
commands, and relevant module/binding/device environment.

Required input files are hashed once and copied into a verified snapshot owned
by the result record; every repetition and the numerical comparison use that
snapshot. The source checkout is checked before and after the build. The runner
does not hash system tools, rehydrate records, prove scheduler fields,
reconcile placement, or run
dedicated OpenMP/GPU probes. Actual launcher commands, environment, XNet
diagnostics, and raw output are retained for human inspection.

## Numerical status

- `PASS`: every process completed and every post-timing comparison passed the
  accepted limits.
- `FAIL`: a build, execution, required-output, parse, or numerical comparison
  failed.
- `QUALIFIED / DIFFERENT-NUMERICAL-PATH`: execution completed but comparison
  differs through an explicitly documented maintainer-qualified numerical
  path. Supply `--qualification-note`; the raw failure remains in the record.
- `UNAVAILABLE`: the exact historical source cannot supply the configuration.
  Supply `--record-unavailable 'precise reason'`. This records the planned
  build/run identity without patching or attempting to disguise the limit.

Comparison limits are maintainer decisions. Do not widen them to make a new
toolchain pass.

## Finite matrix

The campaign is question-driven, not Cartesian:

1. network-size scaling across alpha, CCSN52, SN160, CCSN179, and ECSN350;
2. CPU OpenMP scaling on selected larger networks with batch size one;
3. dense versus MA48, including one useful OpenMP MA48 comparison where the
   licensed source is available;
4. selected CPU versus GPU comparisons;
5. GPU batch-size scaling at `1,4,16,64,128`;
6. one bounded ranks-per-GPU slice where the exact source and facility allow;
7. selected self-heating off/on sensitivity points;
8. component timings reused from those runs; and
9. historical `batch_alpha` and `heat_sn160` comparability points.

Use one setup/smoke followed by five retained repetitions unless observed
behavior justifies a different count. Record an unavailable point and move on
when the exact source is incompatible.

## Future coupled-call records

An eventual authentic CHIMERA or Flash-X capture should record the application
and XNet revisions, network/input identity, caller and call site, zone/batch
shape, self-heating choice, rank/thread/device placement, call count, raw call
times, XNet component timers, and a numerical-success disposition. This file
defines those fields only; it does not invent a coupled workload or implement
coupled capture.

## Focused checks

```bash
python3 -m py_compile test/benchmark/run.py test/benchmark/test_run.py
python3 test/benchmark/test_run.py
python3 test/benchmark/run.py --list-cases
```
