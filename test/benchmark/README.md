# Pre-V9 benchmark records

This directory captures reproducible baseline evidence for issue #127, not a
performance winner, platform qualification, or regression-suite replacement.
Capture permits only a clean checkout at
`86e867c2a64267a674ce4fbf6a3064af39e2f4e0`.

`cases.json` is the sole registry. It keeps case ID, scientific network and
workload identity, and execution profile separate. The sole implemented
profile is `serial-dense`; future generic identities must not encode execution
choices into case IDs.

```sh
python3 test/benchmark/capture.py --list-cases
python3 test/benchmark/capture.py --repository /scratch/xnet-v9-staging \
  --build-dir /scratch/xnet-v9-build --records /scratch/xnet-v9-records \
  --case batch_alpha --repetitions 5
```

Capture owns a fresh build directory and never accepts an arbitrary executable.
It rejects MPI, OpenMP, GPU, directive, and non-dense configurations. Each
fresh process uses the historical checkout's existing
`test/regression/xnet_regression.py` characterization for `batch_alpha` or
`heat_sn160`. XNet execution is timed separately; parsing and comparison are
afterward, outside the timing interval, but a numerical comparison pass and
its diagnostics are required and retained.

Records have no required live absolute path: source and harness identities,
copied build config/log, bundle-relative input hashes, executable hash (the
executable is not copied), raw timers/counters, standard streams, diagnostics,
comparison result, environment, and final artifact checksum inventory are kept.

```sh
python3 test/benchmark/validate.py /scratch/xnet-v9-records/batch_alpha-...
python3 test/benchmark/test_benchmark.py /scratch/xnet-v9-records/batch_alpha-...
```

`validate.py` works offline. Optional `--repository` and `--executable`
rehydrate bundle and executable identity when they are locally available.

## Frontier local-session prompt

```text
Using Frontier allocation <ACCOUNT_PROJECT> and finite slice
<NODES>/<WALLTIME>, create a clean worktree at SHA
86e867c2a64267a674ce4fbf6a3064af39e2f4e0. In this local session run the
implemented Python serial-dense capture for batch_alpha and/or heat_sn160 with
fresh build and record directories, then validate it offline. Report modules,
compiler, allocation, host/topology, command, status, and failures. This is
serial capture only, not MPI/GPU/Frontier qualification. Immediate follow-on
facility support needs a reviewed execution profile with launcher argv and
resolved placement evidence.
```

## Perlmutter local-session prompt

```text
Using Perlmutter allocation <ACCOUNT_PROJECT> and finite slice
<NODES>/<WALLTIME>, create a clean worktree at SHA
86e867c2a64267a674ce4fbf6a3064af39e2f4e0. In this local session run the
implemented Python serial-dense capture for batch_alpha and/or heat_sn160 with
fresh build and record directories, then validate it offline. Report modules,
compiler, allocation, host/topology, command, status, and failures. This is
serial capture only, not MPI/GPU/Perlmutter qualification. Immediate follow-on
facility support needs a reviewed execution profile with launcher argv and
resolved placement evidence.
```
