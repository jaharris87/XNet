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
`xnet_nnu.F90` sources. It neither builds nor changes the default
`source/xnet` target.

## Bounded support and coverage

`support/xnet_test_stubs.F90` supplies only the controls, zone mask, tiny
`nuclear_data` arrays, diagnostic units, and serial abort service needed to
link the selected production modules. Tests initialize two nuclei and three
zones directly; they do not copy a production algorithm or provide a generic
mock framework.

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
  supplied time range.

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
following checks. The checked production correction restricts calculation of
the neutrino interpolation ratio to an interior or exact-upper-knot interval.
Before the correction, the DEBUG suite stopped in `nnu_flux` with status 2:

```text
Fortran runtime error: Index '0' of dimension 1 of array 'ts' below lower bound of 1
Fortran runtime error: Index '4' of dimension 1 of array 'ts' above upper bound of 3
```

After the correction, both tracked configurations passed all nine tests. The
clean build-and-run wall times measured with `/usr/bin/time -p` were 1.28
seconds for the final DEBUG run and 2.11 seconds for the final OPT run. The
existing helper-only suite also passed unchanged:

```text
.venv/bin/python -m pytest -q test/regression/test_xnet_regression.py
166 passed in 13.18s
```

Five additional controlled source mutations were applied only in temporary
copies and each made the named test fail:

| Controlled mutation | Detecting test |
| --- | --- |
| Swap the old/new weights in neutrino temperature interpolation | `neutrino interpolation` |
| Omit the abundance rescaling in `norm` | `mass normalization` |
| Remove the integer-format precision used for zero padding | `ordered output suffix` |
| Pass density history as the vector temperature history | `trajectory vector mask` |
| Execute the trajectory vector body for an inactive lane | `trajectory vector mask` |

The pre-fix range failure was reproduced separately by restoring the original
unconditional ratio calculation in a temporary copy. These mutations and the
pre-fix reproduction all returned nonzero status under `CMODE=DEBUG`; the
repository sources were restored before the final verification runs.
