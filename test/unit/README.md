# Focused deterministic contract tests

From the repository root, the fast offline suite is built and run with:

```bash
make -C test/unit
```

The default uses the tracked GNU `CMODE=OPT` configuration. A bounds-checking
run uses the same target with `CMODE=DEBUG`:

```bash
make -C test/unit clean test CMODE=DEBUG
```

The Makefile puts all generated files under the ignored `test/unit/build/`
directory. It includes the production GNU configuration and compiles the
actual `xnet_util.F90`, `xnet_conditions.F90`, `xnet_abundances.F90`, and
`xnet_nnu.F90`, `xnet_timers.F90`, and `xnet_nse.F90` sources, plus the
vendored NETLIB routines required by the NSE solver. It neither builds nor
changes the default `source/xnet` target.

## Bounded support and coverage

`support/xnet_test_stubs.F90` supplies only the controls, zone mask, tiny
`nuclear_data` arrays, diagnostic units, serial abort service, and deterministic
EOS behavior needed to link the selected production modules. Most tests
initialize two nuclei and three zones directly. The NSE tests use a compact
eight-species fixture with physical mass and binding inputs; they do not copy
a production algorithm or provide a generic mock framework. The runner explicitly disables `test-drive` test-level
parallelism because the component fixtures intentionally share this small
module state; production code still compiles with the selected OpenMP flags.

The suite checks:

- ordinary, vector, and upper/lower-clamped `safe_exp` results;
- exact mass normalization and exact mass/charge normalization;
- one- and two-digit output suffixes, including zero padding;
- scalar trajectory interpolation at the lower bound, an exact knot, an
  interior point, the upper bound, and beyond the history;
- scalar/vector trajectory equivalence and inactive-lane preservation;
- scalar/vector abundance moments, including an auxiliary contribution, and
  inactive-lane preservation;
- constant neutrino histories, zero/zero, zero/nonzero, and logarithmic
  positive-flux interpolation, exact knots, endpoints, and both sides of the
  supplied time range;
- unscreened NSE states across three density, temperature, and electron-fraction
  combinations, including finite/nonnegative composition, mass and charge
  reconstruction, and solver counters;
- repeatability between the default NSE roots and a materially different
  supplied initial guess; and
- screened NSE execution through a deterministic software-only EOS seam.

## Vendored test-drive dependency

The suite vendors the single-file upstream `test-drive` v0.5.0 release at
commit `fd66b4bca683c5fa5d92536075734f0792824d37`:

- `vendor/test-drive/testdrive.F90`, SHA-256
  `e8765129ba304f28c4bcfc20860cb49e0046e76527e4c240eeb54a5fea22837d`;
- `vendor/test-drive/LICENSE-MIT`, SHA-256
  `d34e0235cb56e251ea1c23f9c803857267d083459aeedcd06b538c0335d69e46`.

Upstream explicitly permits redistribution of `src/testdrive.F90` and offers
Apache-2.0 or MIT terms. This repository uses the MIT option and retains that
license beside the vendored source. Version 0.5.0 supplies the small
procedural API needed here. Version 0.6.0 was also evaluated, but test-suite
construction aborted with `SIGABRT` under both tracked GNU configurations
with GNU Fortran 16.1.0; no root cause is claimed here.

Normal build and test execution makes no network request. To update the
dependency, select and review an upstream release, verify its tag commit,
replace `src/testdrive.F90` and the selected license in `vendor/test-drive/`,
update the version, commit, and SHA-256 values above, and rerun both GNU
configurations plus the controlled effectiveness checks below.

## Issue 37 effectiveness record

On 2026-08-07, GNU Fortran 16.1.0 and GNU Make 3.81 on macOS were used for the
following checks. One production correction restricts calculation of the
neutrino interpolation ratio to an interior or exact-upper-knot interval.
Before that correction, the DEBUG suite stopped in `nnu_flux` with status 2:

```text
Fortran runtime error: Index '0' of dimension 1 of array 'ts' below lower bound of 1
Fortran runtime error: Index '4' of dimension 1 of array 'ts' above upper bound of 3
```

The other production correction changes the masked vector `y_moment` result
arrays from `Intent(out)` to `Intent(inout)`. With `Intent(out)`, Fortran made
every result undefined on entry, so skipping an inactive lane could not
contractually preserve its incoming value. The corrected interface matches
the masked implementation and the sentinel checks. Its accelerator data entry
also copies incoming result values to the device before active lanes are
updated, so the whole-array copyout preserves inactive lanes.

After the corrections, both tracked configurations passed all nine tests. The
clean build-and-run wall times measured with `/usr/bin/time -p` were 1.27
seconds for the final DEBUG run and 2.08 seconds for the final OPT run. The
existing helper-only suite also passed unchanged:

```text
.venv/bin/python -m pytest -q test/regression/test_xnet_regression.py
166 passed in 12.83s
```

The serial-runner review fix was checked with a clean
`CMODE=DEBUG OPENMP_MODE=ON` build. After that build passed 9/9, the test
executable passed 500 consecutive runs with `OMP_NUM_THREADS=9`. The runner
therefore remains serial even when the production modules are compiled with
OpenMP enabled. `make -C source -j` also recompiled the changed production
modules and linked the tracked default `source/xnet` target successfully.
Preprocessor inspection showed the masked `y_moment` entry/exit mapping as
OpenACC `copyin`/`copyout` and OpenMP offload `map(to:)`/`map(from:)` for all
six result arrays. A GNU OpenACC host-fallback build of that expanded
production routine passed 9/9, including the inactive sentinels. No
accelerator-device runtime was available.

Six additional controlled source mutations were applied only in temporary
copies and each made the named test fail:

| Controlled mutation | Detecting test |
| --- | --- |
| Swap the old/new weights in neutrino temperature interpolation | `neutrino interpolation` |
| Omit the abundance rescaling in `norm` | `mass normalization` |
| Remove the integer-format precision used for zero padding | `ordered output suffix` |
| Pass density history as the vector temperature history | `trajectory vector mask` |
| Execute the trajectory vector body for an inactive lane | `trajectory vector mask` |
| Return zero instead of the lower `safe_exp` clamp | `safe exponential` |

The pre-fix range failure was reproduced separately by restoring the original
unconditional ratio calculation in a temporary copy. These mutations and the
pre-fix reproduction all returned nonzero status under `CMODE=DEBUG`; the
repository sources were restored before the final verification runs.

## Issue 40 effectiveness record

The NSE additions exercise the production `nse_solve` calculation directly.
They use the same finite-state, mass-normalization, reconstructed-charge, and
counter checks for screened and unscreened calls. A separate bounded process
test drives `xnse` with three ordered SN160 rows and rejects malformed input,
invalid solver states, incomplete output, and row/counter misassociation.

That process coverage exposed an existing serial termination defect: both
malformed `xnse` input and NSE nonconvergence printed fatal diagnostics but
returned process status 0. `xnet_parallel_stubs.F90` now uses `stop 1` in its
two serial abort paths. The MPI implementation is unchanged.
