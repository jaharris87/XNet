# Runtime configuration

Standalone XNet reads `controls.nml` from the run directory. The supported
input group is `&xnet_controls ... /`; the former line-oriented `control` parser
is not part of the production path.

`xnet_controls_t` in `source/xnet_controls.F90` is the validated input value
used by both the standalone reader and programmatic callers. A caller starts
with `set_xnet_controls_defaults`, changes the needed fields, and calls
`validate_xnet_controls`. The standalone reader additionally calls
`validate_standalone_controls`, which requires the nuclear-data directory and
the abundance and thermodynamic-history inputs needed by the executable.

The compiled defaults are ordinary Fortran assignments in
`source/controls.defaults`. `set_xnet_controls_defaults` includes that file, so
those assignments are the single executable source of default values. Component
initializers in `xnet_controls_t` leave a bare object deterministic and invalid
as a whole, although flags for which zero has historical meaning retain that
meaningful value. A bare object fails validation until the defaults are applied.
`data_dir` and input-file pairs remain blank after default initialization because
each standalone problem must supply them.

The supported namelist names match the fields: `description`, `szone`,
`nzone`, `iweak0`, `iscrn`, `iprocess`, `nzbatchmx`, `isolv`, `kstmx`,
`kitmx`, `ijac`, `iconvc`, `changemx`, `yacc`, `tolm`, `tolc`, `ymin`,
`tdel_maxmult`, `iheat`, `changemxt`, `tolt9`, `t9nse`, `ineutrino`,
`idiag`, `itsout`, `ev_file_base`, `bin_file_base`, `nnucout`,
`output_nuclei`, `data_dir`, `inab_files`, and `thermo_files`. The additional
`include_files` key names ordered configuration layers; it is not an execution
control.

Dynamically sized array controls `output_nuclei`, `inab_files`, `thermo_files`,
and `include_files` use explicit positive scalar indices, one assignment at a
time. XNet sizes their namelist staging arrays from the largest explicit index
and the values already assembled by earlier layers. This deliberate restriction
avoids implementing a second general Fortran namelist parser. Unindexed
array-list syntax, including repetition syntax, is rejected.
Every `output_nuclei` entry from 1 through `nnucout` must be nonblank.

The maintained [`tnsn_alpha` controls input](../../test/regression/cases/tnsn_alpha/controls.nml)
is a fully annotated example of the supported standalone input format.

An input can name up to 16 direct `include_files` entries. XNet reads the
including file, then reads listed includes in their listed order; a later
include overrides an earlier value. This lets a base file be followed by local
overrides. Relative paths are interpreted relative to the file that names them.
The direct-include limit bounds fan-out; the separate 16-level nesting limit
bounds recursion. Cycles are rejected.

Cycle identity lexically normalizes repeated separators and `.` and `..`
components, so equivalent spelling aliases are rejected. XNet deliberately
does not resolve symbolic links or claim filesystem canonicalization; a cycle
that exists only through symbolic-link aliases can reach the depth limit.
Controls-file paths have a 1024-character storage bound. This bounds stack and
namelist storage for filenames; it is not a zone, species, or scientific limit.

Validation and legacy single-pair filename expansion occur only after every
layer has been read. The XNet I/O rank reads and validates the files, then
broadcasts the resolved value. `write_controls` emits a complete, flattened, re-readable
`&xnet_controls` block to the ordinary diagnostic stream. The block records
effective post-application values (including the BDF change-limit transformation)
and can be extracted as a new `controls.nml`. No separate resolved file is made.

The maintained standalone build currently selects the ASCII model-input reader.
XNet post-processing drivers also use HDF5 inputs that contain many zones per
file. Controls ending in `.h5`, `.hdf`, or `.hdf5` therefore retain their supplied,
contiguous file-pair list rather than receiving per-zone filename suffixes. As in
the established execution state, the list may contain at most `nzone` pairs. The
HDF5 reader, mode-selection policy, and build integration are tracked in issue
[#139](https://github.com/jaharris87/XNet/issues/139).

`xnet_controls_t` is the shared configuration value for standalone and
programmatic callers. `apply_standalone_controls` adds the standalone file-input
requirements and transfers the value into the existing module variables used by
the executable. That compatibility transfer preserves the current internal
interfaces and accelerator data-management directives. A generic embedded apply
operation is outside this change and belongs to the supported lifecycle work in
issue [#129](https://github.com/jaharris87/XNet/issues/129).

## Converting v8 ASCII controls

The offline standard-library command
[`tools/convert_control.py`](../../tools/convert_control.py) converts an assembled
v8.0 ASCII `control` file. It does not read the named scientific inputs or run
XNet. From the repository root:

```bash
cat test/test_settings_small test/Test_Problems/setup_ccsn_alpha > /tmp/ccsn.control
python3 tools/convert_control.py /tmp/ccsn.control -o /tmp/ccsn.controls.nml
```

Omit `-o` to write the namelist to standard output. An explicit output path must
not exist; conversion errors leave it uncreated. Inspect warnings and the
generated namelist before placing it at `controls.nml` in a prepared run
directory. Shell redirection follows the shell's overwrite rules, so use `-o`
when an existing file must be protected.

The mapping follows `source/xnet_controls.F90` at v8.0 commit
`b017bd657bb38105b9a61908aa51adb1361e5ba5`, rather than current compiled defaults.
Every consumed field is emitted, with explicit indices for array entries.

| Historical block | Emitted fields, in record order | If absent |
| --- | --- | --- |
| Problem Description | `description(1:3)` | Error |
| Job Controls | `szone`, `nzone`, `iweak0`, `iscrn`, `iprocess` | Error |
| Zone Batching Controls | `nzbatchmx` | `1` |
| Integration Controls | `isolv`, `kstmx`, `kitmx`, `ijac`, `iconvc`, `changemx`, `yacc`, `tolm`, `tolc`, `ymin`, `tdel_maxmult` | Error |
| Self-heating Controls | `iheat`, `changemxt`, `tolt9` | `0`, default-real32 `1.0e-2` and `1.0e-4`, promoted to double precision |
| NSE Initial Conditions | `t9nse` | `8.0` |
| Neutrinos | `ineutrino` | `0` |
| Output Controls | `idiag`, `itsout`, `ev_file_base`, `bin_file_base`, `nnucout`, `output_nuclei` | Error |
| Input Controls | `data_dir`, alternating `inab_files`/`thermo_files` | Error |

The two old self-heating defaults are emitted as `9.9999997764825821e-3` and
`9.9999997473787516e-5`. These preserve the old default-real32 assignment;
builds using nonstandard default-real compiler flags are outside this converter's
scope. Supplied numeric tokens, including E/D exponents and integer flags, retain
their spelling. Supplied BDF change limits remain in the file; XNet's existing
application step replaces them with its BDF limits.

Block markers must occupy columns 1-2 (`##`). Titles are case-sensitive
substrings in columns 3-82, searched within the first 1000 records. Blocks may
appear in any order. A scalar READ takes one decimal integer or real value
from each record; trailing labels are discarded. Strings are A80 (the first 80
characters), preserving leading spaces and literal quotes. Namelist quoting
escapes apostrophes. Output and input labels occupy records even though their text is
ignored. `nnucout` comes from columns 51-54 of its record; species names occupy
five-character fields, fourteen per record, continuing on further records.

Absent optional blocks use the table's defaults only when the file has fewer
than 1000 physical records. With 1000 or more records, a missing optional title
within the scan is rejected and requires manual migration. The v8 reader did
not reach EOF in this case: its search left a success flag set and attempted
to read controls from record 1001 instead of selecting defaults. The converter
does not reproduce that fall-through behavior. A title found at record 1000
remains supported, as do longer files with all optional titles inside the scan.

`nzone` and `szone` are preserved. At most `nzone` file pairs are consumed. One
pair at end of file expands to `1..nzone`, padded to the decimal width of
`nzone`, independent of `szone`; the expanded A80 paths retain v8 truncation.
Otherwise all `nzone` pairs must be supplied. Surplus nonblank records produce
a warning, including the extra pair in `ccsn_alpha` and nine extra pairs in
`tnsn_torch47`. No directory or filename is rebased: relative input and output
paths refer to XNet's working directory, not the location of either controls
file. The converter preserves `Test_Results/` and `Test_Problems/` prefixes.

The supported subset rejects HDF input, duplicate or overlapping block titles,
missing records, partial file lists, blank required paths/species, non-ASCII
text, tabs in strings, and list-directed null/repetition or nondecimal numeric
forms. Some of these forms were accepted or left values undefined by v8;
they require manual migration. Blank scalar records and a following block in
place of a required value are errors. Conversion establishes input translation,
not physical equivalence or availability of the named files. See the
[historical recipe inventory](legacy-recipes.md) and
[conversion checks](../../test/migration/README.md).
