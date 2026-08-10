# Independent unscreened NSE validation

This directory implements issue #41.  The validation problem is deliberately
narrow: compare XNet's existing, unscreened ideal-gas NSE calculation with
three compositions computed independently from published equilibrium
equations, using the same finite species set and explicitly reconciled nuclear
inputs.  It is not a general NSE package and it does not change XNet physics.

## Verification record (before reference generation)

The statements below were checked at base commit
`65271bcbeea430534c1adc92748ef13bea10c228`.  This record was written before
freezing expected compositions or running XNet against them.

### XNet software facts

- The issue #40 unit-test seam directly calls the public `nse_initialize` and
  `nse_solve` procedures from the production `source/xnet_nse.F90`, then reads
  public `xnse`, `ynse`, `unse`, and `knrtot`.  The test build copies that
  production source into an isolated test-drive build and supplies only the
  surrounding XNet module interfaces.  Issue #41 preserves this architecture.
- The issue #40 direct fixture has eight deliberately synthetic species with
  unit spins and partition functions and rounded binding energies.  It is a
  software-test fixture, not an independent scientific reference, and is not
  used to define issue #41 expected values.
- XNet represents the NSE result as mass fractions `X_i`; it also sets
  `Y_i = X_i / (m_i N_A)`.  With the active translational-mass convention
  `m_i = A_i/N_A`, this is `Y_i = X_i/A_i`.
- `rho` is in g cm^-3, `T9` is temperature in GK, and
  `Ye = sum_i (Z_i/A_i) X_i`.  Free neutrons and protons are ordinary entries
  in the finite network and their stored mass excesses define every binding
  energy through `B_i = N_i MEn + Z_i MEp - ME_i`.
- The active NSE translational mass is `A_i/N_A`; commented alternatives based
  on actual nuclear masses are not active.  The selected `netwinv` file
  supplies ground-state spin, mass excess, and 24 normalized partition-factor
  values.  XNet multiplies the normalized factor by `2J_i+1` and interpolates
  linearly in `ln(G)` versus `T9`.
- The constants that enter the NSE abundance equation are the binary64 values
  compiled from `pi`, `hbar` (MeV s), `avn` (mol^-1), `bok` (MeV GK^-1), and
  `epmev` (erg MeV^-1) in `source/xnet_constants.F90`.  Tracked GNU, Intel,
  NVHPC, Cray, and AMD compiler configurations use 64-bit default real values;
  therefore unsuffixed decimal constants and the encoded partition-temperature
  grid are binary64 in supported builds.
- For `iscrn = 0`, XNet sets every Coulomb correction `h_i` to zero.  The final
  abundance equation then contains no EOS call or other nonideal correction.
- `nse_solve` exposes the two chemical-potential-like roots, iteration and
  evaluation counters, and the final mass fractions.  Its local `info` status
  and residual vector are written only through optional diagnostics and are
  not public module state.  The residuals are `sum(X)-1` and
  `sum((Z/A-Ye)X)`.  The configured function tolerance is `1e-8`; a separate
  `1e-14` step-size exit can return `info = 2`, so the scientific test must
  calculate and gate the physical residuals itself instead of treating either
  positive status as sufficient.
- Exponentials are protected by `safe_exp`, and each resulting mass fraction
  is then clipped to `[0,1]`.  Issue #41 therefore compares the complete
  vector, including stored tiny values, and preflights the reference states so
  no scientifically material species relies on either clipping boundary.
- The current test-drive dependency is version 0.5.0.  Its Makefile builds
  separate test executables, copies production Fortran into the isolated build
  to select the stub module files, and treats `build/` plus generated module,
  object, and executable files as untracked test artifacts.

### Network candidates recorded before the freeze

No network was selected merely because the planning report proposed SN160.
All tracked `test/Data_*` directories with both `sunet` and `netwinv` were
surveyed.  The bounded candidates are:

| Network | Species | Useful property | Material concern |
| --- | ---: | --- | --- |
| `Data_SN160` | 160 | Smallest tracked dense iron-group network with n and p | Must show negligible boundary sensitivity against a larger network |
| `Data_SN231` | 231 | Broader isotopic coverage with the same input-data format | A larger committed vector and slower test |
| `Data_torch47` | 47 | Small and includes n and p | Sparse off the alpha chain; may truncate neutron- or proton-rich equilibrium |
| `Data_Nova` | 169 | Broad `Z/A` range | Light-network emphasis and maximum A = 54 |
| `test/build_net/sunet.torch489` | 489 | Strictly contains SN160 and SN231; broad light and iron-group coverage | Requires a reproducible `netwinv` build |
| `Data_Reaclib20180621` | 7852 | Full tracked comparison set | Too large for the smallest routine validation fixture |

`Data_alpha` cannot represent `Ye != 0.5` and omits free nucleons;
`Data_CNO` is too light; and the 304--7852-species networks are not the
smallest credible first choice.  The choice was made from high-precision,
XNet-free preflight calculations.  In particular, SN160 was acceptable only
if SN231 showed that mass in additional species and changes to shared species
were immaterial at all three states.  The disposition appears below.

### Candidate state design recorded before the freeze

Exactly three states were to be retained.  Before selection, the independent
calculator examined the report's `(T9,rho,Ye)` values
`(7,1e9,0.50)`, `(7,1e9,0.45)`, and `(9,1e7,0.50)` together with bounded
stress candidates at lower NSE-domain temperature/density, proton-rich
`Ye`, and more neutron-rich `Ye`.  Selection criteria are:

1. the state remains in a regime where NSE is a physically meaningful target,
2. the chosen finite network represents the result without material boundary
   mass,
3. two independent numerical solution routes and multiple starts converge,
4. no material abundance is controlled by XNet's exponential/clipping guards,
5. the three states are scientifically nonredundant and numerically durable.

A `Ye` below the minimum bound-nucleus `Z/A` is not intrinsically
unrepresentable because free neutrons have `Z/A = 0`; it is nevertheless a
network-boundary stress test and will only be retained if expanded-network
preflight supports it.  Similarly, a proton-rich state may be more demanding
but will not be chosen solely because it makes the solver fail.

### Independent scientific authority and implementation independence

The reference equations are the Maxwell-Boltzmann chemical-equilibrium and
mass/charge constraints in Seitenzahl et al. (2009), equations (2)--(10),
with the constraint notation corroborated by Hix & Meyer (2006) and the
high-precision verification method in Lippuner & Roberts (2017), Appendix B.
The retained equations are implemented in `reference_solver.py` with Python's
`Decimal` arithmetic.  That code imports no XNet routine, does not execute
XNet, and is organized around log-sum-exp constrained equilibrium rather than
the implementation structure of `source/xnet_nse.F90`.

The supplied paper files used in this verification have these SHA-256 hashes:

| Paper | SHA-256 |
| --- | --- |
| Seitenzahl et al. (2009) | `5d1c684abf36463dc88e0f3e6aedf0234f95af2b0e85acfe01621b4e7beb86f4` |
| Hix & Meyer (2006) | `59da109818ec8e053af07f9eae7a4d0bfa326c0a969613e5e4889cf80bd9bd95` |
| Lippuner & Roberts (2017) | `246c62865d292df60046572084c9f543d7d575efbc4af65099ec2d50a926140e` |
| Reichert et al. (2023) | `8e20bf9bf43e38c26dfe7416129d6f22f0ef576061866e68663960dcff01510d` |

External-code roles are intentionally qualified:

The source survey was rechecked on 2026-08-10 at pynucastro commit
`a7268f86f42c556172578ca53293cf00b6c539ab`, Microphysics commit
`6fb41b5f7475b42a06eb5b09ff0520c9f08aa7f0`, WinNet commit
`de0c9c852907a8714444287f3ebe0bdedf328397`, `wneq` commit
`d0bede932936d5b30a0d73e7a435f1c3d3f33ca4`, and `wnnet` commit
`4aef8352373f144bb8c58516a7067fc656991315`.  SkyNet is pinned through its
published v1.0 archive, DOI `10.5281/zenodo.1008754`.  These versions record
what was evaluated; only the sources identified below as scientific authority
or numerical corroboration support the retained result.

- Frank Timmes's public `nse` code is useful historical and methodological
  evidence, but XNet documents historical inspiration from that implementation;
  it is not a fully independent numerical authority for this test.  The
  official page describes a 47-isotope illustrative solver; its linked archive
  returned HTTP 403 during this verification, so no unaudited copy was used.
- No XNet--pynucastro developer overlap was found.  Austin Harris made one
  2017 Microphysics commit (`9c08513b`) that declared an EOS name public in
  seven EOS files; it did not touch NSE, nuclear data, or a solver.  No
  XNet--Microphysics NSE source lineage was found.  Pynucastro and Microphysics
  do share developers, network-generation machinery, and nuclear-data paths
  with each other, so agreement from both would be one family of secondary
  corroboration, not two independent results.
- SkyNet and WinNet provide relevant published verification methods.  Their
  default nuclear data, species sets, mass conventions, partition functions,
  and nonideal corrections are not automatically compatible with this finite
  XNet problem.  They may corroborate a reconciled state, but they do not
  replace the primary, explicit-input calculation.

After the expected data and tolerances were frozen, pynucastro commit
`a7268f86f42c556172578ca53293cf00b6c539ab` supplied a secondary numerical
check.  Its default problem was not compared directly: `ar45` lacks a default
spin, and its mass, translational-mass, partition, and constant choices differ.
The optional `corroborate_pynucastro.py` adapter instead supplies the exact
retained inputs to pynucastro's independently maintained NSE equation and
SciPy solver.  It obtains complete-vector L1 differences of `5.29e-14`,
`8.74e-14`, and `3.63e-13` for the three states.  This result corroborates the
primary calculation but is neither the expected-data generator nor a gating
test.  Microphysics was not counted as another numerical corroboration because
it belongs to the same developer and nuclear-data family as pynucastro.

### Input-data reconciliation

`extract_inputs.py` is data tooling, not an NSE solver.  It checks exact
`sunet`/`netwinv` identity and order, records both source decimals and the
binary64 values consumed by tracked builds, and recomputes the active XNet
binding and translational-mass inputs.  Every selected spin and normalized
partition factor is checked against
`test/build_net/partf_data/winvne_JINAv22`.  Every mass excess is checked
against the mass source selected by that file after the network builder's
eight-decimal MeV storage rounding.  This establishes JINA REACLIB v2.2 input
provenance for the tracked network data; it does not claim that those nuclear
inputs are exact measurements.

The proton record uses the neutral-hydrogen atomic mass excess.  Because the
same atomic-mass convention appears with the same `Z` in both sides of the
binding-energy difference, electron rest masses cancel in `B_i`.  The
published equation is reconciled to XNet's explicitly approximate
translational mass `A_i/N_A`, rather than silently substituting actual nuclear
masses.

### Material corrections to the planning report

- SN160 is a candidate, not a requirement.  It must pass an expanded-network
  boundary comparison; SN231 will be used if it does not.
- The report's three nominal states are candidates, not fixed answers.  The
  final set will consider proton-rich and harder thermodynamic conditions as
  suggested during maintainer review, while retaining exactly three robust
  states.
- Pynucastro/Microphysics overlap is primarily within that software family.
  The one identified XNet-author contribution to historical Microphysics EOS
  declarations is unrelated to NSE.  Scientific implementation lineage and a
  literal contributor-list intersection are recorded separately.
- Repository review policy requires fresh-context role reviews after a pushed
  draft PR exists.  The implementation follows that sequencing rather than
  the report's earlier review-freeze suggestion.

No expected composition, validation tolerance, or observed XNet discrepancy
was used in the network/state decision recorded above.

## Final design after independent preflight

### Network selection and boundary evidence

The validation uses the tracked `test/build_net/sunet.torch489` selection,
built to the retained `network/sunet` and `network/netwinv` files.  It contains
489 unique ordered species: n, p, d, t, and bound nuclei through `tc91`
(`Z <= 43`, `A <= 91`).  It strictly contains every SN160 and SN231 species.
The retained file hashes are:

- `sunet`: `930fcd3e43b9fbbac1ce2441b69368b341baf488e29edff53935d9f3cbf05d1f`;
- `netwinv`: `efd4551e7597c732a49931e699453cf469e9fd9f9296bc1b3e841bd21ed42379`;
- ordered species: `8620804c59002cad785f539d1beeddcc13e4ec5aa3b77fb7fd0d223120795038`.

This choice follows quantitative preflight, not network size alone:

| Comparison using identical common nuclear inputs | State | Mass outside smaller set | Shared L1 | Shared L-infinity |
| --- | --- | ---: | ---: | ---: |
| SN160 versus SN231 | `(7,1e9,0.50)` | `1.20e-3` in SN231-only species | `1.44e-3` | `4.25e-4` |
| SN160 versus SN231 | `(7,1e9,0.45)` | `1.41e-1` in SN231-only species | `1.76e-1` | `4.68e-2` |
| torch489 versus full 7852 | `(7,1e9,0.50)` | `2.254e-6` | `2.276e-6` | `5.504e-7` |
| torch489 versus full 7852 | `(7,1e9,0.45)` | `1.911e-6` | `5.856e-6` | `8.657e-7` |
| torch489 versus full 7852 | `(6.5,1e7,0.55)` | `7.241e-6` | `7.241e-6` | `5.636e-6` |

SN160 therefore fails the bounded-network requirement, especially at the
report's neutron-rich point.  SN231 improves the result but still leaves about
one percent of the full-network mass outside its set at that point.  Torch489
reduces every retained-state boundary mass below `1e-5`; the symmetric and
proton-rich differences are dominated by the transient `be8` entry in the
full REACLIB set.  A `Ye=0.40` dense trial was rejected because about 70% of
the full-network mass lies outside torch489.  The Seitenzahl 443-species list
was not available as a retained list in the supplied article, and its actual
masses and Rauscher--Thielemann partition inputs would not define XNet's
finite-data problem.  It remains equation and methodology evidence, not a
substitute network.

The build exposed one necessary tooling defect: the mass reader stopped on
the documented `#` unavailable-value rows even when those rows were not
selected.  `test/build_net/partf_module.f90` now skips those rows while
retaining the existing later error if a requested species has no mass.  The
unit fixture includes an unselected missing row.  `network/build_input.namelist`
retains the exact torch489, REACLIB, partition, mass, and disabled weak/neutrino
settings used for the snapshot.

### Exact states

| ID | `T9` [GK] | `rho` [g cm^-3] | `Ye` | Role | Jacobian infinity condition estimate |
| --- | ---: | ---: | ---: | --- | ---: |
| `symmetric` | 7.0 | `1e9` | 0.50 | dense, approximately symmetric iron-group equilibrium | `3.159e3` |
| `neutron_rich` | 7.0 | `1e9` | 0.45 | dense neutron-rich iron-group equilibrium | `8.321e3` |
| `proton_rich_low_density` | 6.5 | `1e7` | 0.55 | proton-rich, 100-times lower density, lower temperature, and partition-function interpolation | `9.353e1` |

The third state replaces the report's hot symmetric point.  It supplies a
proton-rich regime, a material thermodynamic change, and a non-grid-node
partition-function interpolation while remaining above the approximately
5 GK NSE applicability threshold.  All three states converged from four
starting offsets using both analytic- and numerical-Jacobian Newton routes.
XNet is also run at every retained state from its default guess and from a
supplied root offset by `(+2,-2)`; both results must independently pass the
reference gates.  This is numerical-robustness evidence, not scientific
authority.
The more extreme neutron-rich trials were useful preflight but were rejected
for finite-network boundary sensitivity, not because XNet was consulted.

### Reference quality, stored data, and tolerances

`generate_reference.py` uses the standard library only and calls
`reference_solver.py`; neither imports or executes XNet.  The solver uses
50 requested decimal digits with 20--30 working guard digits.  Checks at 35
and 65 requested digits produce
identical stored binary64 mass fractions, so the report's proposed
80/120/180-digit ladder was unnecessary.  The largest retained reference
mass or charge residual is `2.25e-28`; the largest analytic/numerical-route
L1 disagreement is `2.85e-49`.  The smallest retained mass fraction is
`5.25e-44`, far above XNet's protected-exponential floor, and the largest is
`8.80e-1`, below its upper clip.

The scientific dataset SHA-256 is
`a48033b186c175848d9b604c0d0806412aa1ae499250884fcbb9281a686df7f0`.
The Fortran-facing `reference.dat` SHA-256 is
`b3aacc793bd6c091038a71e9d2a3a9b4820d1da3b8910d42a0bd41c35f7564d7`.
`reference.json` records the generator/source hashes, exact binary64 state
inputs and constants, residuals, starts, precision checks, complete vectors,
and derivation details.

The residual gate starts from XNet's configured `1e-8` function tolerance.
An inspected upper bound of 32 correctly-rounded binary64 operation
equivalents per species plus complete serial accumulation gives
`gamma_16136 = 1.792e-12`, rounded upward to a `2e-12` arithmetic budget.
For each state the generator independently solves all eight corners and edges
of the resulting mass/XNet-charge residual box.  The composition gate is the
maximum displacement at that boundary plus numerical-route, stored-binary64,
and arithmetic budgets, rounded upward to four significant digits.

| Gating quantity (dimensionless absolute error) | symmetric | neutron rich | proton-rich low density |
| --- | ---: | ---: | ---: |
| `abs(sum(X)-1)` | `1.0002e-8` | `1.0002e-8` | `1.0002e-8` |
| `abs(sum((Z/A-Ye)X))` | `1.0002e-8` | `1.0002e-8` | `1.0002e-8` |
| reconstructed `abs(sum((Z/A)X)-Ye)` | `1.5005e-8` | `1.4505e-8` | `1.5506e-8` |
| complete-vector L1 | `4.192e-7` | `9.608e-7` | `4.689e-8` |
| complete-vector L-infinity | `9.529e-8` | `1.050e-7` | `2.057e-8` |

Finiteness, nonnegativity, unique identity, completeness, and exact order have
no fallback tolerance.  The dominant species are reported by name and their
errors are checked through the complete-vector L-infinity gate; no looser
dominant-only gate exists.  Candidate XNet output is never renormalized.

### Reproduction and ordinary test separation

Reference generation is a manual, reviewable operation:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 test/nse_validation/generate_reference.py \
  test/nse_validation/network /tmp/reference.json /tmp/reference.dat
shasum -a 256 /tmp/reference.json /tmp/reference.dat
cmp /tmp/reference.json test/nse_validation/reference.json
cmp /tmp/reference.dat test/nse_validation/reference.dat
```

The ordinary test target only verifies the retained hashes/data and runs the
XNet comparator.  It has no rule that invokes `generate_reference.py`, no
update mode, and no candidate-output input to the generator.

The optional secondary check requires pynucastro installed from the pinned
checkout and verifies both that checkout's commit and the imported material
source files before using it:

```bash
python3 test/nse_validation/corroborate_pynucastro.py \
  /path/to/pynucastro-checkout-at-a7268f86
```

It is deliberately absent from the ordinary test target and never writes the
retained expected data.

### Effectiveness coverage and supported claim

Focused tests reject controlled changes to a dominant expected species, the
complete vector, reconstructed `Ye`, XNet's charge residual, normalization,
species order, duplicate identity, missing identity, NaN, negativity, and a
10 keV `co55` binding-energy input.  They also set each numeric metric to the
next representable binary64 value above its gate.  The independent Python
test changes the same binding input in the generator path and requires both
composition norms to move beyond their gates.  These mutations operate on
parsed, identity-valid data or in-memory scientific inputs; none depends on a
metadata parse failure.

The strongest supported claim is limited to the complete, unscreened static
ideal-NSE composition for this exact 489-species set and these three states,
using the retained XNet mass, partition, constant, and translational-mass
conventions.  It does not validate screening, reaction or weak rates, the
timescale for reaching NSE, other networks/states, or the absolute accuracy of
the underlying nuclear data.
