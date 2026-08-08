# EOS scientific-reference fixture

The five STARKILLER reference states were generated independently with the
Timmes EOS from the
[`jschwab/python-helmholtz` snapshot](https://github.com/jschwab/python-helmholtz/tree/8fc5f2be1c18ef8db2a9cde9f449b4e1bd139c5d)
at commit `8fc5f2be1c18ef8db2a9cde9f449b4e1bd139c5d`.
[Cococubed's stellar-EOS page](https://cococubed.com/code_pages/eos.shtml)
links that repository, and the repository states that `eosfxt.f90` has only
cosmetic changes from the Cococubed Timmes source dated 2018-12-10. The Timmes
calculation evaluates the electron-positron integrals directly and does not use
XNet's tracked Helmholtz table or adapted STARKILLER implementation.

The SHA-256 values below are for the immutable raw files, before any harness
edits:

| File | Raw source | SHA-256 |
| --- | --- | --- |
| `eosfxt.f90` | [raw](https://raw.githubusercontent.com/jschwab/python-helmholtz/8fc5f2be1c18ef8db2a9cde9f449b4e1bd139c5d/eosfxt.f90) | `4c3e45924c00cff751885377c936cdd44793838c3b38db6ba4c5fec1c58710d3` |
| `const.dek` | [raw](https://raw.githubusercontent.com/jschwab/python-helmholtz/8fc5f2be1c18ef8db2a9cde9f449b4e1bd139c5d/const.dek) | `bb6089c86b183d119a8e03ec5d893626e8a4a2f168bb201a09060a4996fc8ab1` |
| `vector_eos.dek` | [raw](https://raw.githubusercontent.com/jschwab/python-helmholtz/8fc5f2be1c18ef8db2a9cde9f449b4e1bd139c5d/vector_eos.dek) | `2310686dfd8f86990590ffd0b1b8ac2cbb793c99bf0cc3adc66b5f36155252c6` |
| `implno.dek` | [raw](https://raw.githubusercontent.com/jschwab/python-helmholtz/8fc5f2be1c18ef8db2a9cde9f449b4e1bd139c5d/implno.dek) | `e62d95098f636eb3d90871f3e1f07f462f184af4557a23cfdf3d7228a723b2ea` |

For the isolated reference run, the bundled example `program teos` was renamed
to a subroutine so that `timmes_reference_driver.F90` could provide the main
program, and `nrowmax` in `vector_eos.dek` was reduced from 1,000,000 to 16.
Neither local harness change modifies `eosfxt` calculations. GNU Fortran
16.1.0 compiled and ran the driver on 2026-08-08.

The reference can be reproduced from an XNet checkout with:

```bash
reference_dir=$(mktemp -d)
cd "$reference_dir"
timmes_commit=8fc5f2be1c18ef8db2a9cde9f449b4e1bd139c5d
for source_file in eosfxt.f90 const.dek vector_eos.dek implno.dek; do
  curl -fsSLO "https://raw.githubusercontent.com/jschwab/python-helmholtz/${timmes_commit}/${source_file}"
done
shasum -a 256 eosfxt.f90 const.dek vector_eos.dek implno.dek
perl -0pi -e 's/\A      program teos/      subroutine teos_unused/' eosfxt.f90
perl -0pi -e 's/parameter \(nrowmax = 1000000\)/parameter (nrowmax = 16)/' vector_eos.dek
cp <XNET_CHECKOUT>/test/unit/fixtures/eos/timmes_reference_driver.F90 .
gfortran -O0 -I. eosfxt.f90 timmes_reference_driver.F90 -o timmes_reference_driver
./timmes_reference_driver
```

After the two documented harness edits, the four SHA-256 values are
`72f47ce95e82330552a7b0cda3f8c9ef0ce3a876f99ca501dd31cba4260542d6`,
`bb6089c86b183d119a8e03ec5d893626e8a4a2f168bb201a09060a4996fc8ab1`,
`c64bd494886c76da2e0000b6b4ce039bdb5cbf0de235bf353369d744f3d94a7a`,
and `e62d95098f636eb3d90871f3e1f07f462f184af4557a23cfdf3d7228a723b2ea`
in the table's file order. A clean reproduction with those inputs returned the
values below exactly.

The raw independent results are:

| State | T (K) | rho (g cm^-3) | abar | zbar | cv (erg g^-1 K^-1) | eta | d eta/dT (K^-1) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 3.2e7 | 2.5e2 | 1.2958963282937364 | 1.1015118790496758 | 2.0653230156968951e8 | -1.8807503609806382 | -4.9592562974862513e-8 |
| 2 | 1.7e8 | 3.0e6 | 4 | 2 | 4.6199576060239784e7 | 18.319585249344883 | -1.0876372950003569e-7 |
| 3 | 8.0e8 | 2.0e9 | 12 | 6 | 1.8932479108972270e7 | 67.68924196485338 | -8.4721540555149227e-8 |
| 4 | 4.0e9 | 7.0e7 | 56 | 26 | 9.8736503214137957e7 | 2.8245988707608238 | -1.0485292044799550e-9 |
| 5 | 9.0e9 | 1.0e10 | 19.764705882352942 | 9.529411764705882 | 4.3195927677688472e7 | 10.296830235239677 | -1.2091574746119109e-9 |

These states cover negative-eta nondegenerate material, degenerate and strongly
degenerate material, a hot moderately degenerate state, and a hot dense state.
They exercise mixtures as well as single-species compositions.

The test maps Timmes `cv` to XNet's exposed MeV nucleon^-1 GK^-1 field with
`cv * xnet_constants::amu * 1e9`, maps `d eta/dT` to GK^-1 with a factor of
`1e9`, and compares eta directly. The relative tolerances are `1e-5` for
`cv`, `2e-5` plus `5e-6` absolute for eta, and `3e-4` plus `1e-6` absolute for
the temperature derivative. The state-by-state differences from the tracked
STARKILLER table are:

| State | cv relative | eta absolute | eta relative | d eta/dT9 relative |
| --- | ---: | ---: | ---: | ---: |
| 1 | 1.0961e-6 | 2.0118e-6 | 1.0697e-6 | 6.6475e-5 |
| 2 | 2.9728e-8 | 1.7977e-4 | 9.8127e-6 | 1.5113e-4 |
| 3 | 4.5224e-8 | 3.6200e-5 | 5.3480e-7 | 1.4077e-4 |
| 4 | 5.6173e-6 | 6.0867e-7 | 2.1549e-7 | 8.5062e-5 |
| 5 | 9.4704e-7 | 5.7354e-6 | 5.5701e-7 | 1.7546e-4 |

The limits cover the observed tabulation/interpolation differences with modest
compiler margin and remain well below the controlled one-percent reference
perturbation.

The tracked table used by STARKILLER has SHA-256
`c9a57c26c6fd2b2b378b9d5295ca1214022f6fec6289d038b47bf8c8938881a1`.
