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
sh test/benchmark/capture.sh \
  --repository /scratch/xnet-v9-staging \
  --build-dir /scratch/xnet-v9-build \
  --case batch_alpha \
  --repetitions 5 --records /scratch/xnet-v9-records
```

Capture owns a fresh, previously nonexistent build directory and rejects an
operator-supplied executable. This v2 contract is intentionally limited to a
direct, one-process serial dense execution: it builds and checks every MPI,
OpenMP, GPU, and directive selector as `OFF`, and records `launcher=none`.
It cannot represent launcher, placement, MPI, GPU, MA48, or facility claims.
Those require a later reviewed capture extension with launcher argv and
topology evidence; do not label a v2 record as such a run.

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

`metadata.tsv` has an exact v2 key set; `build.log`, the build configuration,
and the executable are retained and hash-verified. `input.sha256` has an exact
header and SHA-256/absolute-path rows which the validator recomputes. It lists
tracked control, network inputs, trajectories, and Helmholtz table. The network
tree is copied into each temporary run directory because historical runtime
preprocessing writes derived files; that prevents a measurement from mutating
its source input checkout. `repetitions.tsv`
contains the raw process status, final-record count, setup timer, evolution
timer, and structural gate for each repetition.  `repetitions/N/` retains the
diagnostic and captured standard streams.  Records are generated evidence and
belong outside Git.

## Facility and coupled future capture

The v2 matrix is only serial dense for both ready cases. Facility, OpenMP,
MPI, MA48, GPU, and partial-batch measurements are deferred until a reviewed
extension can bind actual launcher and topology evidence.

A future authentic CHIMERA or Flash-X capture uses the same source,
executable, build, topology, raw-repetition, input-identity, and numerical
result fields, plus: `integration=CHIMERA|Flash-X`, `caller_revision`,
`call_site`, `call_sequence`, `call_kind=initialization|burn`, `zones`,
`network_id`, `thermodynamic_state_identity`, `caller_result_identity`, and
`coupled_numerical_success`.  It must contain an actual caller trace; this
schema does not authorize an invented standalone proxy.
