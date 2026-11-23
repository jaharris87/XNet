# Running standalone XNet

The `xnet` program evolves one or more thermodynamic trajectories. Each zone
reads an initial-abundance file and a trajectory file; all zones share one
network. The run is configured by `controls.nml` in the working directory,
using the `&xnet_controls` namelist group. The v8 line-oriented `control` file
is no longer read; [convert it](#converting-v8-ascii-controls) once.

## Running a trajectory

Build the default configuration from the repository root with `make -j`. The
example below runs the annotated
[`tnsn_alpha` controls](../test/regression/cases/tnsn_alpha/controls.nml):
ten zones of the 14-species alpha network along an SN Ia flame trajectory.

```bash
xnet_root=$PWD
run_dir=$(mktemp -d "${TMPDIR:-/tmp}/xnet-tnsn-alpha.XXXXXX")
cd "$run_dir"
cp "$xnet_root/test/regression/cases/tnsn_alpha/controls.nml" .
cp -R "$xnet_root/test/Data_alpha" .
cp "$xnet_root/test/Test_Problems/th_sn1aflame" .
ln -s "$xnet_root/tools/starkiller-helmholtz/helm_table.dat" .
"$xnet_root/build/GNU-OPT/bin/xnet"
```

Paths in `controls.nml` are relative to the working directory. This example
sets `iprocess=1`, so XNet first preprocesses the ASCII network in
`data_dir` and writes the prepared files there; that is why the run uses its
own copy of `Data_alpha` rather than the tracked directory. With an already
prepared network, use `iprocess=0` and point `data_dir` at it. The default
Starkiller EOS reads `helm_table.dat` from the working directory.

A run writes:

| File | When | Contents |
| --- | --- | --- |
| `net_diag*` | `idiag >= 0` | One file per MPI rank and thread: the resolved controls, network description, initial and final composition, counters and timers for each zone. |
| `<bin_file_base>NN` | `itsout >= 1` | Binary history per zone: header records, then step, time, T9, density, neutrino loss rate, timestep, energy-generation rate, `Y` and reaction fluxes for every step. |
| `<ev_file_base>NN` | `itsout >= 2` | ASCII history per zone with the `output_nuclei` mass fractions. |
| `ab_fail_*`, `th_fail_*` | integration failure | Inputs for rerunning a failed zone: abundances at its last accepted step and a constant-condition trajectory at its starting temperature, density and Ye. XNet then stops. |

`NN` is the zone number, zero-padded to the width of `nzone`. `itsout >= 3`
also prints one line per step on standard output. Each `net_diag` file starts
with a complete `&xnet_controls` block holding the values actually used,
including defaults and BDF adjustments; it can be copied out as a new
`controls.nml`.

The [regression README](../test/regression/README.md) lists the other
maintained cases. Their `controls.nml` files and the
[historical recipes](development/legacy-recipes.md) show inputs for further networks.

## The controls file

Assign only the controls that differ from the [defaults](#controls-reference).
Array controls take one explicit, positive index per assignment:

```fortran
&xnet_controls
  nzone = 2,
  data_dir = 'Data_alpha',
  inab_files(1) = 'Data_alpha/ab_co',
  thermo_files(1) = 'th_sn1aflame',
  inab_files(2) = 'Data_alpha/ab_co',
  thermo_files(2) = 'th_sn1aflame',
/
```

The list forms `inab_files = 'a', 'b'` and `inab_files = 2*'a'` are rejected:
XNet sizes these arrays from the largest index before reading the namelist.
This applies to `inab_files`, `thermo_files`, `output_nuclei` and
`include_files`. Every `output_nuclei` entry from 1 through `nnucout` must be
set.

Supply one abundance/trajectory pair per zone. As in v8, a single pair with
`nzone > 1` is instead expanded to numbered files: `inab_files(1) = 'ab'`
with `nzone = 10` reads `ab01` through `ab10`. To use one file for every
zone, list it once per zone, as the `tnsn_alpha` example does.

The defaults are compiled from [`source/controls.defaults`](../source/controls.defaults),
the only place they are set.

### Layered controls

`include_files(i)` names further controls files that are read after the
current file, in index order. A later file overrides earlier values, so a
shared base can be followed by local changes. Relative include paths are
interpreted relative to the file that names them; paths in ordinary controls
such as `data_dir` remain relative to the working directory.

A file may name up to 16 includes, nesting is limited to 16 levels, and cycles
are rejected. Cycle detection normalizes `.`, `..` and repeated separators but
does not resolve symbolic links, so a cycle formed only through a link reaches
the depth limit instead. Controls-file paths are limited to 1024 characters.

Validation and the single-pair expansion happen after every layer has been
read. In MPI runs the I/O rank reads and validates the files and broadcasts the
result.

## Controls reference

Integers are default `Integer`; reals are `Real(dp)`. Ratios and tolerances
are dimensionless unless stated. "BE" is Backward Euler (`isolv=1`), "BDF" is
the variable-order Gear method (`isolv=3`). Library callers set the same
fields in `xnet_controls_t`; the
[library API guide](library-api.md#controls-in-the-library) lists the fields that
behave differently there.

**Problem and network**

| Control | Default | Meaning |
| --- | --- | --- |
| `description(1:3)` | blank | Three 80-character descriptions copied into each binary history header. |
| `data_dir` | none (required) | Network directory. Preprocessing writes here when requested. Limited to 80 characters. |
| `iprocess` | `0` | `>0` preprocesses the ASCII network (`sunet`, `netwinv`, `netsu`, ...) in `data_dir` before loading; `<=0` loads prepared files. |
| `iweak0` | `1` | `>0` strong and weak reactions; `0` strong only; `<0` weak only. Below T9 = 0.01, a zone with `iweak0 /= 0` uses weak reactions only. |
| `iscrn` | `1` | `>0` applies plasma screening, also in NSE; `<=0` disables it. |
| `ineutrino` | `0` | Nonzero includes neutrino-capture reactions, using the neutrino flux and temperature columns of each trajectory file. Not supported by the library. |

**Zones and input files**

| Control | Default | Meaning |
| --- | --- | --- |
| `szone`, `nzone` | `1`, `1` | First zone and total zone extent; evolve zones `szone` through `nzone`, with `1 <= szone <= nzone`. |
| `nzbatchmx` | `1` | Maximum zones evolved together in one batch (per thread). |
| `inab_files(i)` | none (required) | Initial-abundance file for zone `i`. |
| `thermo_files(i)` | none (required) | Thermodynamic trajectory for zone `i`. Names ending in `.h5`, `.hdf` or `.hdf5` are kept as one contiguous list without numbered expansion, for HDF5 readers that hold several zones per file ([#139](https://github.com/jaharris87/XNet/issues/139)); the maintained build reads ASCII only. |
| `t9nse` | `8.0` | Initial temperature in GK above which a zone starts from the NSE composition at its initial density and Ye instead of its abundance file. |

**Integration**

| Control | Default | Meaning |
| --- | --- | --- |
| `isolv` | `1` | `1` BE, `3` BDF. Other values are rejected. |
| `kstmx` | `9999` | Maximum outer integration steps per zone. |
| `kitmx` | `5` | BE Newton iterations per step attempt. BDF uses `max(kitmx,3)` per Newton solve attempt. |
| `ijac` | `1` | BE Jacobian rebuild interval, in Newton iterations. BDF ignores it. |
| `iconvc` | `0` | BE: `0` tests the change in total mass (network plus auxiliary) since the start of the step against `tolm`; nonzero tests relative abundance corrections against `tolc`. BDF error norm: `0` infinity, `1` L1, `2` L2, `3` RMS; other values are not rejected, so use only these. |
| `changemx` | `0.1` | BE target relative abundance change per step. BDF replaces it with `1e10`. |
| `yacc` | `1e-7` | Abundance floor (`Y = X/A`) in the BE step-size estimate: changes of species below `yacc` are measured relative to `yacc`. BDF absolute tolerance (see below). |
| `tolm` | `1e-6` | BE mass-change limit when `iconvc=0`. It is not a final `sum(X)=1` requirement. |
| `tolc` | `1e-4` | BE relative-correction limit when `iconvc/=0`; BDF relative tolerance. |
| `ymin` | `1e-30` | Abundances (`Y`) below this are set to zero. |
| `tdel_maxmult` | `2.0` | BE maximum step growth factor and step reduction after a failed attempt. BDF uses its own factors. |

For BDF with `iconvc = 0` or `1`, species below `ymin` have zero weight and
the error weight is otherwise `1/(tolc*max(|Y|,yacc))`. For `iconvc = 2` or `3`
it is `1/(tolc*max(|Y|,ymin) + yacc)`. BE and BDF therefore read `iconvc=0`
differently; for BDF it is not a mass-conservation test.

**Self-heating**

| Control | Default | Meaning |
| --- | --- | --- |
| `iheat` | `0` | `>0` evolves temperature implicitly with the network; otherwise temperature follows the trajectory (standalone) or stays fixed (library). |
| `changemxt` | `0.01` | BE target relative temperature change per step. BDF replaces it with `1e10`. |
| `tolt9` | `1e-4` | Relative (dimensionless, despite the name) temperature convergence limit for BE, or tolerance for BDF. |

**Output**

| Control | Default | Meaning |
| --- | --- | --- |
| `idiag` | `0` | `<=-2` no routine diagnostics; `-1` final counters and timers; `>=0` adds initial and final compositions; `>=1` one line per step and integrated fluxes; `>=3` per-step abundance-change tables. Higher levels add solver detail. |
| `itsout` | `0` | `>=1` binary history per zone; `>=2` adds the ASCII history; `>=3` one line per step on standard output; `>=4` mass fractions and `>=5` reaction fluxes each step in the diagnostic output (both need `idiag >= 0`). |
| `bin_file_base` | `'ts_'` | Binary history filename prefix. |
| `ev_file_base` | `'ev_'` | ASCII history filename prefix. |
| `nnucout` | `0` | Number of species in the ASCII history. |
| `output_nuclei(i)` | none | Species names for the ASCII history. A name not in the network prints a warning and selects the last network species. |

Neither `idiag <= -2` nor `itsout = 0` silences every message: the network
reader, preprocessor and EOS still print warnings and fatal errors.

## Weak-rate table limits

FFN table interpolation holds the nearest edge value outside
`T9 = 0.01..100` (GK) and `log10(rho*Ye) = 1..11` (`rho*Ye` in g/cm^3),
independently on each axis. Table-derived temperature slopes are zero strictly
outside the temperature grid; endpoints use the adjacent interior slope.
For logft data, only the tabulated factors are held: capture phase space and
its temperature derivative continue to use the actual thermodynamic state,
so the total logft capture rate can still vary beyond a table edge.

## Converting v8 ASCII controls

[`tools/convert_control.py`](../tools/convert_control.py) converts an
assembled v8.0 `control` file to `controls.nml`. It uses only the Python
standard library and does not read the named inputs or run XNet. The legacy
shell drivers built `control` by concatenating a settings file and a setup
file; do the same, then convert:

```bash
cat test/test_settings_small test/Test_Problems/setup_ccsn_alpha > /tmp/ccsn.control
python3 tools/convert_control.py /tmp/ccsn.control -o /tmp/ccsn.controls.nml
```

Without `-o` the namelist goes to standard output. `-o` refuses to overwrite
an existing file, and a failed conversion creates no file. Read the warnings
and the generated namelist before using it.

The converter writes every control the v8 reader consumed, using explicit
array indices. Values keep their original spelling. Missing optional v8 blocks
take the v8 defaults shown below, which can differ from the current compiled
defaults:

| v8 block | Controls | If the block is absent |
| --- | --- | --- |
| Problem Description | `description(1:3)` | Error |
| Job Controls | `szone`, `nzone`, `iweak0`, `iscrn`, `iprocess` | Error |
| Zone Batching Controls | `nzbatchmx` | `1` |
| Integration Controls | `isolv`, `kstmx`, `kitmx`, `ijac`, `iconvc`, `changemx`, `yacc`, `tolm`, `tolc`, `ymin`, `tdel_maxmult` | Error |
| Self-heating Controls | `iheat`, `changemxt`, `tolt9` | `0`, `1.0e-2`, `1.0e-4` |
| NSE Initial Conditions | `t9nse` | `8.0` |
| Neutrinos | `ineutrino` | `0` |
| Output Controls | `idiag`, `itsout`, `ev_file_base`, `bin_file_base`, `nnucout`, `output_nuclei` | Error |
| Input Controls | `data_dir`, alternating `inab_files`/`thermo_files` | Error |

Paths are not rebased: they remain relative to XNet's working directory, so
converted historical recipes still refer to `Test_Results/` and
`Test_Problems/`. Converting establishes the same input values, not the
availability of the named files or a physically checked run.

### Converter limits

The converter follows the v8.0 reader (`b017bd6`) and rejects forms that v8
accepted ambiguously or left undefined; those need manual migration:

- HDF5 inputs, non-ASCII text, tabs in strings, and list-directed null,
  repetition or non-decimal numeric forms;
- duplicate or overlapping block titles, missing records, blank required
  paths or species, and partial file lists;
- a missing optional block in a file of 1000 or more records. v8 searched
  only the first 1000 records and then read from record 1001 instead of
  using the default.

Block markers are `##` in columns 1-2 with case-sensitive titles in columns
3-82. `nnucout` is read from columns 51-54, species from 5-character fields,
14 per record; strings are A80. At most `nzone` file pairs are consumed and
surplus pairs produce a warning (one in `ccsn_alpha`, nine in
`tnsn_torch47`). The v8 defaults above assume the tracked GNU build's
`-fdefault-real-8 -fdefault-double-8`; for a historical build without those
flags, set them explicitly. The [conversion checks](../test/migration/README.md)
compare converted values with the v8 reader for every tracked recipe.
