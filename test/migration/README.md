# Offline control conversion checks

Run the Python standard-library checks from the repository root:

```bash
python3 -m unittest discover -s test/migration -v
XNET_TEST_FORTRAN=1 python3 -m unittest discover -s test/migration -v
```

The second command uses `gfortran` (or `FC`) to compile the existing current
controls reader, its serial support modules, and `controls_probe.F90` in a
temporary directory, using the tracked GNU kind flags
`-fdefault-real-8 -fdefault-double-8`. It reads and applies all 34 converted inputs
and compares every consumed field with v8 results. No nuclear data are opened, preprocessed,
or evolved. It also checks absent optional defaults and quoted descriptions.
The first command needs only Python; the three Fortran checks are skipped.

`v8_values.json` records consumed fields from the unmodified v8.0 reader at
`b017bd657bb38105b9a61908aa51adb1361e5ba5`, compiled with GNU Fortran 16.2.0,
`-fdefault-real-8 -fdefault-double-8 -O0 -fcheck=all`, and the serial parallel stubs.
These kind flags match the pinned `source/Makefile.internal` GNU F90FLAGS and
current `Makefile.internal`; both default real and double precision use real64.
Input recipes/fixtures were read at `d2dacf73dc1306102e10e053aa5e624a7ab35da1`.
Each recipe's settings path is recorded; concatenate it with
`test/Test_Problems/setup_<name>` without other transformations. Historical
fixtures are read as committed. The final case removes the four optional
blocks from `test/regression/cases/tnsn_torch47/control` to characterize v8 defaults.

To independently reproduce old-reader observations, extract these files from
the pinned revision into an owned directory: `source/xnet_types.F90`,
`xnet_constants.F90`, `xnet_parallel_stubs.F90`, `xnet_util.F90`,
`xnet_controls.F90`, and `xnet_macros.fh`. Compile the five Fortran files in that
order, followed by this directory's `controls_probe.F90`, with `-cpp
-DV8_READER -fdefault-real-8 -fdefault-double-8 -O0 -fcheck=all` and the extracted
directory on the include path.
Run the resulting executable beside each assembled `control`. Lines after
`BEGIN VALUES` follow the JSON's `fields` order, then `nnucout` A5 species,
then `nzone` alternating A80 abundance/trajectory paths. Trailing string padding
is omitted in JSON. Numeric comparisons require equal parsed double values;
both readers apply their existing BDF change-limit transformation. These are
parser observations, not scientific reference results.

Focused checks cover optional defaults, fixed count/species columns and format
reversion, A80 truncation, leading spaces and quoting, E/D numeric spelling,
integer flags, nondefault `szone`, suffix expansion, surplus pairs, missing and
ambiguous blocks, malformed/null/repetition scalars, partial pairs, unsupported
HDF/non-ASCII input, stdout, and exclusive output creation. Scan-limit checks
cover absent optional titles at 999 records (EOF defaults) versus 1000/1001
records (unsupported v8 fall-through, rejected before creating output), a title
at record 1000, and longer files containing all optional titles. The converter
deliberately rejects several v8-accepted or undefined forms; the supported
subset is described in the [migration guide](../../docs/development/runtime-configuration.md#converting-v8-ascii-controls).
