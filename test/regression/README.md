# XNet pytest regression cases

This directory is a bounded replacement path for XNet regression testing. It
exercises the compiled XNet program as an external process; it is not a Python
binding, a scientific-validation suite, or a replacement for all legacy cases.
The migrated cases are the serial, CPU-only `tnsn_alpha` trajectory calculation
and the `heat_alpha` self-heating calculation.

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

The suite enforces a 30-second per-case process timeout. Use
`--xnet-timeout=SECONDS` to change it deliberately.

## Isolated execution and artifacts

pytest supplies a new empty temporary directory for each case. The runner
copies the complete `control` input into it, creates a local writable
`Data_alpha` directory containing absolute symlinks to only the five tracked
source inputs (`sunet`, `netsu`, `netweak`, `netwinv`, and `ab_co`), and
symlinks every trajectory required by the case plus the Helmholtz EOS table.
Trajectory basenames must be unique so staging cannot silently replace an
input. XNet runs with that directory as its current directory.
Network-preprocessing products therefore stay inside the temporary directory
rather than mutating `test/Data_alpha`. A nonempty work directory is a setup
failure, so old diagnostics cannot satisfy a new run.

Every invocation records `xnet.stdout.txt`, `xnet.stderr.txt`,
`xnet.status.txt`, and `composition_error_norms.json` beside the XNet outputs.
Failure messages give the work directory path. pytest retains recent temporary
directories. To choose a stable diagnostic location for a run, use its
standard option, for example:

```bash
python3 -m pytest test/regression \
    --xnet-executable="$PWD/source/xnet" \
    --basetemp=/tmp/xnet-regression-artifacts
```

The runner classifies invalid definitions, paths, and preparation as setup
failures; timeouts, signals, nonzero status, and missing/empty required output
as execution failures; missing or malformed diagnostic structure as parsing
failures; and out-of-policy values or invariants as comparison failures.

## Case inputs and legacy provenance

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

The Starkiller EOS initializes even though `tnsn_alpha` disables self-heating,
so `tools/starkiller-helmholtz/helm_table.dat` is also an explicit required
input. Investigation found that a missing table can produce a fatal message,
a partial `net_diag01`, and process status zero. The runner therefore requires
all expected output and complete final records instead of relying on status or
stderr keyword heuristics alone.

Legacy ID 51 in `test/test_xnet.sh` names `heat_alpha` and calls
`do_test_heat`, which historically concatenates `test/test_settings_heat` and
`test/Test_Problems/setup_heat_alpha` into `test/control`. It enables screening
and self-heating for six zones initialized from `Data_alpha/ab_co`. The zones
use `th_co_burn_1` through `th_co_burn_6`, covering densities from
`1.0e7` through `3.16227766e9 g/cm^3` and target times from 10 seconds through
`1.0e-5` seconds. The legacy run expects `net_diag01`, six
`ev_heat_alpha_1` through `ev_heat_alpha_6` ASCII histories, and six matching
`ts_heat_alpha_1` through `ts_heat_alpha_6` binary histories. It moves only
`net_diag01` for its warning-only comparison. No tracked historical
`net_diag_heat_alpha` reference is present in a clean checkout.

The committed `cases/heat_alpha/control` is the one-time concatenated input.
Trailing whitespace was removed, the `Test_Results/` prefixes were removed
from both output roots, and the six `Test_Problems/` prefixes were removed from
the trajectory paths. All numerical controls, zone ordering, `Data_alpha`
path, and abundance paths are unchanged. The runner stages the six adjusted
trajectory paths in the isolated directory. XNet uses the number of digits in
the largest zone number for output suffixes, so this six-zone case uses `_1`
through `_6`, while the ten-zone `tnsn_alpha` case uses `_01` through `_10`.

## Comparison policy and reference status

The historical script deletes the `Timers Summary:` heading plus the next 14
lines, performs an exact whole-file diff, warns on differences, and normally
returns success. A clean checkout has no tracked
`test/Test_Problems/Results/net_diag_tnsn_alpha`, so no historical numerical
reference with compiler or platform provenance is available here.

Each case has a `reference/final_state.json` characterization baseline
generated from the tracked default serial build at its recorded revision.
These are not independently validated scientific results. Each JSON file
records the known compiler, platform, build selections, and input paths.
Normal tests only read these files and never create or replace them.

The parser requires ordered final records and matching counters for every case
zone, the complete 14-species structure, one delimited timer section per zone,
and finite values. It rejects negative mass fractions and applies a coarse
structural `|sum(X)-1|` check. The `tnsn_alpha` bound is `2.1e-8`.
`heat_alpha` records a zone-specific bound from `7.60556005e-9` through
`1.81105e-8`. Each bound is the sum of the half-last-place rounding bounds for
that zone's 14 printed baseline values. These bounds are not derived from
XNet's per-step Newton mass-convergence control and are not claimed as
scientific-validation thresholds.

The numerical comparison records the characterized final step count and
permits a difference of up to two steps. `tnsn_alpha` records 2841 for every
zone. `heat_alpha` records zone-specific counts of 654, 600, 553, 534, 532,
and 540. Step count remains a useful solver diagnostic, but a one- or two-step
shift does not fail a case when the required final time, structure, and
numerical fields still agree. A larger shift fails and reports the actual,
reference, difference, and allowed count. The parser independently requires
each zone's `End` and `Counters` records to agree on the actual step count.

The first two values in an `End` record are distinct: the first is the
requested target time (`tstop` in XNet), and the second is the achieved
integration time (`t`). The target time is compared with the reference, and
the achieved time must reach that zone's target within the same printed-time
tolerance. This makes completion explicit without maintaining two redundant
comparisons to the same reference value.

The comparison also checks temperature, density, electron fraction, and the
eight non-trace final products `si28`, `s32`, `ar36`, `ca40`, `ti44`, `cr48`,
`fe52`, and `ni56`. Every field has an explicit absolute tolerance grounded in
its printed resolution and a relative tolerance of `5e-8`, reflecting half a
unit at the diagnostic's eight-significant-digit precision. The new
`heat_alpha` absolute tolerances use half of each value's last printed place.
Where a quantity's printed scale differs among its zones, the JSON records the
absolute tolerances by zone. Reference values, absolute tolerances, and
relative tolerances may each be either one scalar applied to every zone or a
mapping with exactly one value for every expected zone. This preserves the
compact existing `tnsn_alpha` reference while representing all six distinct
`heat_alpha` endpoints explicitly. The policy remains a deliberately narrow
same-configuration characterization; cross-compiler evidence is not yet
available. The numerical-field criterion is

```text
abs(actual - reference) <= atol + rtol * abs(reference)
```

Each reference contains the final mass fraction for every alpha-network
species and every zone. A separate `mass_fraction_tolerances` mapping
identifies the eight species that currently have field-aware pass/fail
policies. This keeps complete reference states for diagnostic norms without
inventing strict tolerances for trace species.

For diagnosis, `composition_error_norms.json` reports raw `L1`, `L2`, and
`L-infinity` norms of the absolute mass-fraction error over all 14 species for
each zone, plus the species responsible for `L-infinity`. The complete
composition reference and selected tolerance mapping are stored separately in
`final_state.json`, so each species value has a single source. These norms have
no acceptance threshold and do not affect pass/fail. Raw
norms can be dominated by abundant species or conceal the identity of other
changes, so the selected field-aware comparisons remain the regression
criteria.

Timer exclusion is structural rather than line-count based: only a
`Timers Summary:` heading and immediately following timer-name/numeric-value
rows are removed. The first non-timer row ends the exclusion, so unrelated
diagnostic content is not hidden.

## Current limits and next cases

These cases establish runtime and software-behavior checks plus narrow
numerical characterization. It does not establish broad scientific validity,
portability, performance, CI suitability, or support for MPI, threading,
accelerators, BDF, NSE, log-ft rates, batching, or large networks.

The `heat_alpha` comparison covers final `net_diag01` endpoints only. It does
not inspect the evolution history in `ev_*` or binary `ts_*` output. Issue #12
owns the investigation needed before binary time-series data can affect
regression pass/fail. `tnsn_torch47` remains the next useful generality check
because it preserves the trajectory model while adding a small non-alpha
network.
