# XNet pytest regression cases

This directory is a bounded replacement path for XNet regression testing. It
exercises the compiled XNet program as an external process; it is not a Python
binding, a scientific-validation suite, or a replacement for all legacy cases.
The migrated cases are the serial, CPU-only `tnsn_alpha` and `tnsn_torch47`
trajectory calculations and the `heat_alpha` and `heat_sn160` self-heating
calculations.

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
copies the complete `control` input into it, creates a local writable network
directory containing absolute symlinks to only the case's five tracked source
inputs (`sunet`, `netsu`, `netweak`, `netwinv`, and `ab_co`), and
symlinks every trajectory required by the case plus the Helmholtz EOS table.
Trajectory basenames must be unique so staging cannot silently replace an
input. XNet runs with that directory as its current directory.
Network-preprocessing products therefore stay inside the temporary directory
rather than mutating `test/Data_alpha`, `test/Data_torch47`, or
`test/Data_SN160`. The runner also reads each staged network's `sunet` and
requires its ordered, unique species list to match the case declaration before
execution. A nonempty work directory is a setup failure, so old diagnostics
cannot satisfy a new run.

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

Issue #21 deliberately divides the paired SN160 study into two ordered PRs.
This first increment migrates only Backward Euler legacy ID 53,
`heat_sn160`; legacy ID 54, `bdf_sn160`, remains deferred until the Backward
Euler increment is accepted on `development`. Both are members of aggregate
self-heating ID 50. The split is retained because BDF needs its own reference
and a general parser representation for the valid difference between its
`End` step and TS attempt counter. That work can therefore be reviewed without
conflating it with basic SN160 staging and complete-composition support.

Legacy ID 53 calls `do_test_heat`, which concatenates
`test/test_settings_heat` and `test/Test_Problems/setup_heat_sn160`. It runs
six serial zones with weak reactions, screening, self-heating, runtime nuclear
data processing, no neutrino reactions, `Data_SN160/ab_co`, and ordered
trajectories `th_co_burn_1` through `th_co_burn_6`. The required fresh output
is `net_diag01`, six `ev_heat_sn160_1` through `_6` ASCII histories, and six
matching `ts_heat_sn160_1` through `_6` binary histories. The 14 species in the
ASCII-output control do not limit the diagnostic: `net_diag01` records all 160
species in the exact order of `test/Data_SN160/sunet`.

The committed `cases/heat_sn160/control` is that one-time concatenation with
trailing whitespace removed. Its only semantic-preserving path edits remove
the `Test_Results/` prefixes from both output roots and the `Test_Problems/`
prefixes from all six trajectories. Numerical controls, zone block size 1,
zone order, `Data_SN160`, abundance paths, and requested ASCII species are
unchanged. The case stages only `sunet`, `netsu`, `netweak`, `netwinv`, and
`ab_co` into a writable temporary `Data_SN160`; generated preprocessing files
never enter the tracked source directory. Screening and self-heating require
the tracked `tools/starkiller-helmholtz/helm_table.dat`.

For the ordered second increment, the complete legacy control differences are:

| Control | Backward Euler ID 53 | BDF ID 54 |
| --- | ---: | ---: |
| Integration choice | `1` | `3` |
| Maximum iterations per step | `5` | `10` |
| Convergence-condition flag | `0` | `3` |
| Lower abundance cutoff | `1e-30` | `1e-99` |
| Legacy zone block size | `1` | `4` |
| ASCII/binary root | `heat_sn160` | `bdf_sn160` |

The BDF iteration, convergence, and abundance-floor values are solver-specific
comparable controls, not unrelated physical changes. The second increment
must intentionally change its legacy block size from 4 to 1 to hold shared
blocking behavior equal; batching with `szbatch > 1` remains separate work.
Current `xnet_evolve.F90` dispatches `isolv == 3` to `solve_bdf` and all other
values, including 1, to `solve_be`. Current `xnet_controls.F90` also replaces
both abundance- and temperature-change timestep limits with `1e10` for
`isolv == 3`; the nearby input comment naming option 2 as Bader-Deufelhard is
stale for legacy ID 54. These effective BDF semantics are not active in this
first PR.

Legacy ID 2 names `tnsn_torch47` and calls `do_test`, which concatenates
`test/test_settings` and `test/Test_Problems/setup_tnsn_torch47`. The settings
activate only zone 1, serial runtime network processing, Backward Euler, no
screening, and no self-heating. The setup nevertheless retains ten identical
`Data_torch47/ab_co` and `Test_Problems/th_sn1aflame` input pairs; the complete
standalone control preserves all ten records while XNet consumes the first
pair for the one active zone. Its ASCII history requests 14 selected species,
but `net_diag01` records the complete ordered 47-species network from
`test/Data_torch47/sunet`.

The committed `cases/tnsn_torch47/control` changes only the two output roots
by removing `Test_Results/` and the ten trajectory records by removing
`Test_Problems/`. Numerical and physical controls, `Data_torch47`, abundance
paths, repeated records, and the 14-species ASCII-history selection are
unchanged. The case stages `sunet`, `netsu`, `netweak`, `netwinv`, and `ab_co`
in a writable temporary `Data_torch47`. Runtime preprocessing generated
`ab_blank`, `match_data`, `match_read`, `matr_shape`, `net_desc`, `net_diag`,
`nets3`, `nets4`, `nuc_data`, and `sparse_ind` there without changing the
tracked inputs. The required fresh outputs are `net_diag01`,
`ev_tnsn_torch47_1`, and `ts_tnsn_torch47_1`.

No tracked `test/Test_Problems/Results/net_diag_tnsn_torch47` exists in a
clean checkout. The committed endpoint is therefore a characterization of the
recorded build and inputs, not historical or independent scientific truth.

## Comparison policy and reference status

The historical script deletes the `Timers Summary:` heading plus the next 14
lines, performs an exact whole-file diff, warns on differences, and normally
returns success. A clean checkout has no tracked
`test/Test_Problems/Results/net_diag_tnsn_alpha`, so no historical numerical
reference with compiler or platform provenance is available for either
trajectory case here.

Each case has a `reference/final_state.json` characterization baseline
generated from the tracked default serial build at its recorded revision.
These are not independently validated scientific results. Each JSON file
records the known compiler, platform, build selections, and input paths.
Normal tests only read these files and never create or replace them.

The parser requires ordered final records and matching counters for every case
zone, the case-declared complete 14-, 47-, or 160-species structure, one
delimited timer section per zone, and finite values. It has no default network
species list. Case setup independently requires the same ordered species in
`sunet`, so the network input, parsed diagnostic, and reference must agree. It
rejects negative mass fractions and applies a coarse
structural `|sum(X)-1|` check. The `tnsn_alpha` bound is `2.1e-8`.
`heat_alpha` records a zone-specific bound from `7.60556005e-9` through
`1.81105e-8`, and `tnsn_torch47` uses `1.656158052105501e-8`. Each bound is
the sum of the half-last-place rounding bounds for that zone's printed
baseline values. These bounds are not derived from
XNet's per-step Newton mass-convergence control and are not claimed as
scientific-validation thresholds.

For `heat_sn160`, the printed composition itself differs from unity by more
than its aggregate formatting uncertainty in zones 2-5. Its zone-specific
bound is therefore the absolute baseline printed-sum residual plus the sum of
the half-last-place bounds of all 160 printed values. This accepts the recorded
characterization and one complete-vector printing uncertainty without
silently treating the `1e-6` solver mass-conservation control as an endpoint
comparison tolerance.

Each reference records characterized final step counts for diagnosis:
`tnsn_alpha` records 2841 for every zone, `heat_alpha` records 654, 600, 553,
534, 532, and 540, and `tnsn_torch47` records 2928. Step count is
diagnostic-only for every case and has
no cross-run pass/fail tolerance. Accepted-step count can vary when compiler,
library, architecture, optimization, or floating-point rounding changes which
tolerance-dependent convergence path is taken. Repeated results on one
configuration cannot justify either exact equality or a portable nonzero
bound. The parser still requires each zone's `End` and `Counters` records to
agree on the actual step count, while completion and selected endpoint values
remain required.

The first two values in an `End` record are distinct: the first is the
requested target time (`tstop` in XNet), and the second is the achieved
integration time (`t`). The target time is compared with the reference, and
the achieved time must reach that zone's target within the same printed-time
tolerance. This makes completion explicit without maintaining two redundant
comparisons to the same reference value.

The comparison also checks temperature, density, electron fraction, and an
independent composition selection for every zone. The established
silicon-burning anchors `si28`, `s32`, `ar36`, `ca40`, `ti44`, `cr48`, `fe52`,
and `ni56` are retained in each zone when they exist in the case network, even
when an anchor is below the general importance threshold. Every other species
gates comparison in a zone exactly when that zone's characterized endpoint
mass fraction satisfies `X >= 1e-4`. The inclusive boundary identifies species
that carry at least 0.01% of that zone's endpoint mass while leaving smaller
trace and intermediate abundances diagnostic-only there. Anchors are not
required: a CNO or nova network with none of them selects its own material
endpoint species by the same threshold.

Selection is deterministic. A single pass over the complete network vector
reported by XNet retains each anchor or above-threshold species in that vector's
order; anchor status changes membership, not position. The reference's
`mass_fraction_selection` object lists that exact ordered selection for every
expected zone. The loader rejects
missing or unknown zones, empty selections, invalid or duplicate species,
species absent from the complete composition vector, selected species without
tolerances, and tolerance entries unused by every zone. Case validation then
requires each committed list to equal the selection derived from that zone's
complete reference vector. Duplicate JSON object keys are rejected before
schema validation so a later zone, value, or tolerance cannot silently replace
an earlier one.

The per-zone change has the following effect. The table spells out ordering as
well as membership so reviewers can audit each list directly.

| Case | Zone | Previous case-wide selection | Per-zone selection |
| --- | --- | --- | --- |
| `tnsn_alpha` | 1-10 | `si28, s32, ar36, ca40, ti44, cr48, fe52, ni56` | unchanged |
| `tnsn_torch47` | 1 | `si28, s32, ar36, ca40, ti44, cr48, fe52, ni56, s31, co55` | `si28, s31, s32, ar36, ca40, ti44, cr48, fe52, co55, ni56` |
| `heat_alpha` | 1 | `si28, s32, ar36, ca40, ti44, cr48, fe52, ni56, he4, c12, o16, mg24, zn60` | `he4, si28, s32, ar36, ca40, ti44, cr48, fe52, ni56` |
| `heat_alpha` | 2 | same case-wide list | `he4, si28, s32, ar36, ca40, ti44, cr48, fe52, ni56, zn60` |
| `heat_alpha` | 3 | same case-wide list | `he4, mg24, si28, s32, ar36, ca40, ti44, cr48, fe52, ni56, zn60` |
| `heat_alpha` | 4 | same case-wide list | `he4, o16, mg24, si28, s32, ar36, ca40, ti44, cr48, fe52, ni56, zn60` |
| `heat_alpha` | 5-6 | same case-wide list | `he4, c12, o16, mg24, si28, s32, ar36, ca40, ti44, cr48, fe52, ni56, zn60` |

Thus the single-zone Torch47 case and all identical `tnsn_alpha` zones retain
the same pass/fail coverage. In `heat_alpha`, for example, `o16` gates zones
4-6 but remains diagnostic-only in zones 1-3. The focused tests apply the same
sum-preserving `o16`/`c12` perturbation to zones 4 and 3 to check both outcomes;
negative-fraction and composition-sum checks still cover the full vector.

Every field has an explicit absolute tolerance grounded in its printed
resolution and a relative tolerance of `5e-8`, reflecting half a unit at the
diagnostic's eight-significant-digit precision. The `heat_alpha` absolute
tolerances use half of each value's last printed place.
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

Each reference contains the final mass fraction for every case-network species
and every zone. The separate `mass_fraction_selection` and
`mass_fraction_tolerances` mappings identify which species have field-aware
pass/fail policies in each zone without repeating any composition value. A
tolerance scalar applies wherever that species is selected; a zone mapping can
provide distinct bounds and must define every expected zone. This keeps
complete reference states for structural checks and diagnostic norms without
inventing pass/fail tolerances for trace species.

For diagnosis, `composition_error_norms.json` reports raw `L1`, `L2`, and
`L-infinity` norms of the absolute mass-fraction error over all case species for
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

## SN160 Backward Euler characterization evidence

No tracked `test/Test_Problems/Results/net_diag_heat_sn160` exists, and the
investigation for issue #21 found no historical endpoint with usable compiler,
platform, input, or scientific provenance. The committed result is therefore
a new characterization, not historical truth. Issue #12 does not block this
increment: `net_diag01` retains enough printed precision for the selected
endpoint policy, while each `ts_*` file remains a required fresh artifact and
is neither decoded nor compared.

The reference was generated on 2026-08-05 from production and input revision
`01dd4963e9b9677f64711c90e08f50d468bc99a4` on macOS 26.6 arm64 with GNU
Fortran 16.1.0. The clean tracked-default build commands were:

```bash
make -C source clean
make -C source -j
```

Resolved selections were `EXE=xnet`, `CMODE=OPT`, `PE_ENV=GNU`,
`MPI_MODE=OFF`, `OPENMP_MODE=OFF`, `GPU_MODE=OFF`, `EOS=STARKILLER`,
`MATRIX_SOLVER=dense`, and `LAPACK_VER=NETLIB`. The known nominal-serial Make
dependency also compiled `xnet_parallel.F90` with `mpifort` and emitted its
existing argument and rank mismatch warnings; the linked executable used
`xnet_parallel_stubs.o`. MPI, OpenMP, accelerators, other matrix solvers,
other libraries, other compilers, and other platforms were not validated.

Three isolated optimized runs returned direct process status 0 and produced
identical parsed endpoints, all 160 mass fractions, and step counts. Pytest
call times were 1.85, 2.17, and 1.89 seconds, well inside the unchanged
30-second timeout. Step is diagnostic-only and is not compared. Requested and
achieved times were identical at printed precision in every zone:

| Zone | `End` step | Time (s) | Final T (GK) | Density (g/cm3) | Ye | Printed sum(X) | Sum bound | Compared species |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 668 | 10 | 4.5362097 | 1.0000000e7 | 0.49886745 | 0.999999989648 | 2.7904e-8 | 26 |
| 2 | 602 | 1 | 5.4842926 | 3.1622777e7 | 0.49912204 | 1.000000021899 | 4.2621e-8 | 38 |
| 3 | 548 | 0.1 | 6.3425061 | 1.0000000e8 | 0.49928188 | 1.000000113104 | 1.3592e-7 | 52 |
| 4 | 531 | 0.001 | 7.1755363 | 3.1622777e8 | 0.49953200 | 1.000000033670 | 5.2818e-8 | 65 |
| 5 | 548 | 0.0001 | 8.1086726 | 1.0000000e9 | 0.49953803 | 1.000000031608 | 5.0945e-8 | 76 |
| 6 | 564 | 0.00001 | 9.2354937 | 3.1622777e9 | 0.49953848 | 1.000000007620 | 2.7537e-8 | 84 |

The parser preserves the source-labeled counter values separately from the
`End` step. `xnet_output.F90` writes `End` from `kstep` and writes the five
counter columns from `ktot(1:5)`. For Backward Euler, `TS` accumulates trial
timestep attempts, `NR` accumulates Newton-Raphson iterations, and `Jacobian`,
`Deriv`, and `CrossSect` count the corresponding builds or evaluations. These
are solver diagnostics rather than pass/fail values. All three optimized runs
produced the same records:

| Zone | `End` | TS | NR | Jacobian | Deriv | CrossSect |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 668 | 668 | 1238 | 1238 | 1239 | 1239 |
| 2 | 602 | 602 | 1103 | 1103 | 1104 | 1104 |
| 3 | 548 | 548 | 1050 | 1050 | 1051 | 1051 |
| 4 | 531 | 531 | 1013 | 1013 | 1014 | 1014 |
| 5 | 548 | 548 | 1048 | 1048 | 1049 | 1049 |
| 6 | 564 | 564 | 1084 | 1084 | 1085 | 1085 |

Every zone stores all 160 values, including every trace abundance printed by
this baseline. This particular reference contains no printed zeros and does
not exercise values near the Backward Euler `1e-30` molar-abundance cutoff;
the smallest printed mass fraction is zone 1 `ca48 = 1.9843634e-25`.
Pass/fail species are the established silicon-burning anchors when present
plus every species whose zone-specific baseline has `X >= 1e-4`; the reference
records the exact ordered lists summarized by the final column. Each selected
value and scalar field uses half its baseline's last printed place as `atol`
and `5e-8` as `rtol`, matching the diagnostic's eight-significant-digit
representation. Complete vectors still receive exact identity/order,
uniqueness, finite, nonnegative, normalization, and diagnostic norm checks.
Cross-integrator agreement is not evaluated in this increment.

The required outputs totaled 30,663,926 bytes: 47,898 bytes for `net_diag01`,
694,600 bytes for six ASCII histories, and 29,921,428 bytes for six binary
histories. Isolated preprocessing created `ab_blank`, `match_data`,
`match_read`, `matr_shape`, `net_desc`, `net_diag`, `nets3`, `nets4`,
`nuc_data`, and `sparse_ind`, totaling 847,933 bytes. The committed complete
JSON reference is 52,447 bytes. Hashes for the control, five network sources,
six trajectories, and EOS table are recorded in the reference; the tracked
inputs remained unchanged after the runs.

An alternate clean GNU `CMODE=DEBUG` build was also exercised. It exceeded the
normal timeout, then completed directly with status 0 in a 120-second pytest
run whose case call took 37.19 seconds. It retained the optimized run's step
counts but failed the narrow endpoint characterization; the largest complete
composition difference was `6.33e-7` for zone 3 `ni56`. Its zone 3 L1, L2,
and L-infinity differences were `3.733e-6`, `1.058e-6`, and `6.33e-7`.
These observations do not establish a scientifically acceptable cross-mode
tolerance, so the reference was not widened merely to make the debug build
pass. Portability beyond the optimized configuration is not established.

As a controlled end-to-end effectiveness check, a temporary reference changed
zone 3 `ni56` from `0.065404983` to `0.07`. The real pytest case returned
status 1 and reported a `4.595e-3` difference against an allowed `4.000e-9`.
The reference value was then restored. Normal execution has no reference
creation or update path. After restoration and review fixes, the focused
helpers passed 70 tests and the complete optimized suite passed 74 tests in
4.94 seconds.

## Torch47 characterization evidence

The issue #16 reference was generated on 2026-08-05 from revision
`5e7e1543d432f3c2792e40e271816ecaf8184fad` on macOS 26.6 arm64 with GNU
Fortran 16.1.0. The clean build commands were:

```bash
make -C source clean
make -C source -j
```

Resolved selections were `CMODE=OPT`, `PE_ENV=GNU`, `MPI_MODE=OFF`,
`OPENMP_MODE=OFF`, `GPU_MODE=OFF`, `EOS=STARKILLER`,
`MATRIX_SOLVER=dense`, and `LAPACK_VER=NETLIB`. The known Make dependency
limitation also compiled `xnet_parallel.F90` with `mpifort` and emitted its
existing argument-mismatch warnings; the linked executable used
`xnet_parallel_stubs.o`.

An isolated direct Torch47 process returned status 0 in 0.37 seconds. Three
subsequent pytest runs each completed in 0.40 seconds including test overhead
and produced identical parsed 47-species endpoints. This repeated result only
characterizes one compiler, build, and machine. The required outputs totaled
5,877,984 bytes: 5,176 for `net_diag01`, 586,000 for the ASCII history, and
5,286,808 for the binary history. The committed JSON reference is 4,098 bytes.
For comparison on the same configuration, the pytest case times were 0.52
seconds for `tnsn_alpha` and 0.37 seconds for `heat_alpha`; their required
outputs totaled 14,470,756 and 1,757,702 bytes respectively. Torch47 remains
well inside the unchanged 30-second timeout and is suitable for the fast local
suite on this configuration.

The focused helper command passed 39 tests, and the complete suite passed 42:

```bash
python -m pytest -q test/regression/test_xnet_regression.py
python -m pytest -q test/regression \
    --xnet-executable="$PWD/source/xnet"
```

A temporary copy of the Torch47 reference changed the network-specific
selected product `co55` from `0.00076324081` to `0.001`. The real end-to-end
runner then failed with pytest status 1 and reported an absolute difference of
`2.368e-4` against an allowed `5.500e-11`. Normal execution has no
reference-writing path.

The third explicit Python registration remains a short `RegressionCase`
declaration and shares the existing loader-free validation path. A TOML
manifest would duplicate these values while adding schema and loading code, so
issue #16 retains explicit Python registration for all three cases.

## Current limits and next cases

These cases establish runtime and software-behavior checks plus narrow
numerical characterization. They do not establish broad scientific validity,
portability, performance benchmarking, CI suitability, or support for MPI,
threading, accelerators, BDF, NSE, log-ft rates, batching, or networks larger
than SN160.

The self-heating comparisons cover final `net_diag01` endpoints only. They do
not inspect the evolution history in `ev_*` or binary `ts_*` output. Issue #12
owns the investigation needed before binary time-series data can affect
regression pass/fail. The Torch47 and SN160 migrations change endpoint
coverage only; their larger `ev_*` and `ts_*` artifacts remain required for
freshness but are not parsed or compared.

Per-zone importance selection changes only regression classification. It does
not change XNet calculations, establish scientific validity, or extend the
single-compiler and single-platform characterization evidence described above.
