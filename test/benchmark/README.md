# Pre-v9 benchmark records

This directory is the deliberately small capture contract for issue #127.  It
does not select a performance winner, qualify a platform, or replace the
regression suite.  It records the minimum evidence needed to compare later
work with the immutable staging source `86e867c2a64267a674ce4fbf6a3064af39e2f4e0`.

`cases.tsv` is the finite network-size matrix.  `batch_alpha` and
`heat_sn160` are the initial ready standalone cases.  The CCSN52, CCSN179,
and ECSN350 rows intentionally remain candidates until an exact historical
standalone control, trajectory, and abundance input are available.  In
particular, `Data_CCSN179` alone is not a runnable workload, and private
ECSN350 material must never be copied into Git or represented as a measured
record.

## Capture

Use a clean checkout at the exact staging SHA and an executable built from
that checkout.  The script rejects every other source SHA.  Run it from
outside the test input directories so it can preserve one new record
directory per point:

```sh
git worktree add /scratch/xnet-v9-staging 86e867c2a64267a674ce4fbf6a3064af39e2f4e0
make -C /scratch/xnet-v9-staging BUILD_DIR=/scratch/xnet-v9-build -j xnet
sh test/benchmark/capture.sh \
  --repository /scratch/xnet-v9-staging \
  --executable /scratch/xnet-v9-build/bin/xnet \
  --case batch_alpha --placement 'serial; one process; one hardware thread' \
  --repetitions 5 --records /scratch/xnet-v9-records
```

Capture one record per exact build, placement, and case. The required
`--placement` text names the launcher, process/thread count, CPU or GPU
binding, and allocated node/device shape. Do not mix serial,
OpenMP, MPI, GPU, dense, MA48, or partial-batch runs in one record.  Copy the
facility launcher, affinity, module list, compiler version, and scheduler
allocation details into an adjacent operator note before interpreting runs.
MA48 is a candidate only where the maintainer-held licensed source is already
available; its absence is a limitation, not permission to substitute another
sparse solver.

Each run starts a fresh standalone process.  `Setup` is the XNet internal
setup timer (input, initialization, and per-batch preparation); `Total` is
the timed evolution cost.  Thus the record keeps initialization distinct from
repeated burn work without claiming to measure persistent coupled-call setup.
The raw values, rather than an average, are stored in `repetitions.tsv`.

`sh test/benchmark/validate.sh RECORD_DIRECTORY` checks the source binding,
input manifest, a zero direct status, the expected final diagnostic count, and
a positive XNet `Total` timer for every repetition. This is a structural
success gate. Each successful row records `numerical_success=structural-pass`:
direct process success plus complete final diagnostics, not agreement with a
reference. The immutable staging source does not contain the later maintained
regression reference/comparator, so a current checkout's comparison must not
be represented as a same-input historical comparison. A future reference
comparison needs a reference explicitly bound to this record's `input.sha256`
manifest; retain its command, result, and artifacts beside the record.

## Record layout

`metadata.tsv` is a two-column source/build/executable/environment/command
record. The adjacent `build-config.txt` preserves the resolved compiler and
build selection when the build produced one; the operator note retains the
module list and environment not represented there. `input.sha256` lists SHA-256 hashes and absolute source paths for the
tracked control, network inputs, trajectories, and Helmholtz table. The network
tree is copied into each temporary run directory because historical runtime
preprocessing writes derived files; that prevents a measurement from mutating
its source input checkout. `repetitions.tsv`
contains the raw process status, final-record count, setup timer, evolution
timer, and structural gate for each repetition.  `repetitions/N/` retains the
diagnostic and captured standard streams.  Records are generated evidence and
belong outside Git.

## Facility and coupled future capture

The initial facility matrix is finite: serial dense for both ready cases;
useful site-approved OpenMP points for both; and, only when a supplied input
is runnable, one dense and one licensed-MA48 CCSN/SN160-sized point.  GPU or
partial-batch points retain `batch_alpha` and `heat_sn160`; Frontier and
Perlmutter material must be a finite smoke/setup job before an allocation
measurement.  This repository supplies no job submission script here because
account, queue, launcher, placement, and module choices are facility-specific.

A future authentic CHIMERA or Flash-X capture uses the same source,
executable, build, topology, raw-repetition, input-identity, and numerical
result fields, plus: `integration=CHIMERA|Flash-X`, `caller_revision`,
`call_site`, `call_sequence`, `call_kind=initialization|burn`, `zones`,
`network_id`, `thermodynamic_state_identity`, `caller_result_identity`, and
`coupled_numerical_success`.  It must contain an actual caller trace; this
schema does not authorize an invented standalone proxy.
