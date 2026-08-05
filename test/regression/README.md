# XNet regression pilot

This directory is the first bounded replacement path for XNet regression
testing. It exercises the compiled XNet program as an external process; it is
not a Python binding, a scientific-validation suite, or a replacement for all
legacy cases. The only migrated case is the serial, CPU-only `tnsn_alpha`
trajectory calculation.

## Prerequisites and command

Use Python 3.11 or newer and install the single test dependency:

```bash
python3 -m pip install -r test/regression/requirements.txt
```

Build XNet separately, then select the executable explicitly:

```bash
python3 -m pytest test/regression \
    --xnet-executable="$PWD/source/xnet"
```

There is no default executable name and no `XNET_EXECUTABLE` fallback. The
helper tests, which do not run XNet, can be selected independently:

```bash
python3 -m pytest test/regression/test_xnet_regression.py
```

The pilot enforces a 30-second process timeout. Use
`--xnet-timeout=SECONDS` to change it deliberately.

## Isolated execution and artifacts

pytest supplies a new empty temporary directory. The runner copies the
complete `control` input into it, creates a local writable `Data_alpha`
directory containing absolute symlinks to only the five tracked source inputs
(`sunet`, `netsu`, `netweak`, `netwinv`, and `ab_co`), and symlinks the
trajectory and Helmholtz EOS table. XNet runs with that directory as its
current directory. Network-preprocessing products therefore stay inside the
temporary directory rather than mutating `test/Data_alpha`. A nonempty work
directory is a setup failure, so old diagnostics cannot satisfy a new run.

Every invocation records `xnet.stdout.txt`, `xnet.stderr.txt`, and
`xnet.status.txt` beside the XNet outputs. Failure messages give the work
directory path. pytest retains recent temporary directories. To choose a
stable diagnostic location for a run, use its standard option, for example:

```bash
python3 -m pytest test/regression \
    --xnet-executable="$PWD/source/xnet" \
    --basetemp=/tmp/xnet-regression-artifacts
```

The runner classifies invalid definitions, paths, and preparation as setup
failures; timeouts, signals, nonzero status, and missing/empty required output
as execution failures; missing or malformed diagnostic structure as parsing
failures; and out-of-policy values or invariants as comparison failures.

## Pilot input and legacy provenance

Legacy ID 1 in `test/test_xnet.sh` names `tnsn_alpha` and calls
`do_test_small`, which historically concatenates `test/test_settings_small`
and `test/Test_Problems/setup_tnsn_alpha` into `test/control`. It assumes the
script is run from `test/`, defaults silently to `../source/xnetp` if no
executable file argument is recognized, runs ten identical zones, reads
`Data_alpha/ab_co` and `Test_Problems/th_sn1aflame`, and expects
`net_diag01`, ten `ev_tnsn_alpha_*` ASCII histories, and ten
`ts_tnsn_alpha_*` binary histories. The legacy driver moves only
`net_diag01` into `Test_Results` for comparison.

The committed `cases/tnsn_alpha/control` is the one-time concatenated input.
Trailing whitespace was removed, and two deliberate path changes support
isolated execution: the `Test_Results/` prefixes were removed from the ASCII
and binary output roots, and each `Test_Problems/th_sn1aflame` path became
`th_sn1aflame`. All numerical controls, ten zone inputs, the `Data_alpha`
path, and the `Data_alpha/ab_co` paths are unchanged. The runner provides the
adjusted paths in the isolated directory. Normal execution does no fragment
concatenation.

The Starkiller EOS initializes even though this case disables self-heating,
so `tools/starkiller-helmholtz/helm_table.dat` is also an explicit required
input. Investigation found that a missing table can produce a fatal message,
a partial `net_diag01`, and process status zero. The pilot therefore requires
all expected output and complete final records instead of relying on status or
stderr keyword heuristics alone.

## Comparison policy and reference status

The historical script deletes the `Timers Summary:` heading plus the next 14
lines, performs an exact whole-file diff, warns on differences, and normally
returns success. A clean checkout has no tracked
`test/Test_Problems/Results/net_diag_tnsn_alpha`, so no historical numerical
reference with compiler or platform provenance is available here.

`cases/tnsn_alpha/reference/final_state.json` is instead a new
characterization baseline generated from the tracked default serial build at
the recorded revision. It is not an independently validated scientific
result. The JSON records the known compiler, platform, build selections, and
input paths. Normal tests only read this file and never create or replace it.

The parser requires ordered final records and matching counters for zones
1--10, the complete 14-species structure, one delimited timer section per
zone, and finite values. It rejects negative mass fractions and uses
`|sum(X)-1| <= 2.1e-8` as a coarse structural normalization check. That bound
is the sum of the half-last-place rounding bounds for the 14 printed baseline
values. It is not derived from XNet's per-step Newton mass-convergence control
and is not claimed as a scientific-validation threshold.

The numerical comparison records the characterized final step count of 2841
and permits a difference of up to two steps. Step count remains a useful
solver diagnostic, but a one- or two-step shift does not fail the pilot when
the required final time, structure, and numerical fields still agree. A
larger shift fails and reports the actual, reference, difference, and allowed
count. The parser independently requires each zone's `End` and `Counters`
records to agree on the actual step count.

The comparison also checks final time, trajectory time, temperature, density,
electron fraction, and the eight non-trace final products `si28`, `s32`,
`ar36`, `ca40`, `ti44`, `cr48`, `fe52`, and `ni56`. Every field has an
explicit absolute tolerance reflecting half of its last printed decimal place
and a relative tolerance of `5e-8`, reflecting half a unit at the diagnostic's
eight-significant-digit precision. This is a deliberately narrow
same-configuration characterization policy; cross-compiler evidence is not
yet available. The numerical-field criterion is

```text
abs(actual - reference) <= atol + rtol * abs(reference)
```

Timer exclusion is structural rather than line-count based: only a
`Timers Summary:` heading and immediately following timer-name/numeric-value
rows are removed. The first non-timer row ends the exclusion, so unrelated
diagnostic content is not hidden.

## Current limits and next cases

This pilot establishes runtime and software-behavior checks plus a narrow
numerical characterization. It does not establish broad scientific validity,
portability, performance, CI suitability, or support for MPI, threading,
accelerators, BDF, NSE, log-ft rates, batching, or large networks.

If the pilot remains maintainable after review, `heat_alpha` is the preferred
next case because it adds self-heating and thermodynamic feedback using the
same small network. `tnsn_torch47` is the next useful generality check because
it preserves the trajectory model while adding a small non-alpha network.
