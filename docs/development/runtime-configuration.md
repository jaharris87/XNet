# Runtime configuration

Standalone XNet reads `controls.nml` from the run directory. The supported
input group is `&xnet_controls ... /`; the former line-oriented `control` parser
is not part of the production path.

`xnet_controls_t` in `source/xnet_controls.F90` is the validated input value
used by both the standalone reader and programmatic callers. A caller starts
with `set_xnet_controls_defaults`, changes the needed fields, and calls
`validate_xnet_controls`. The standalone reader additionally calls
`validate_standalone_controls`, which requires the nuclear-data directory and
the abundance and ASCII thermodynamic-history inputs needed by the executable.

The compiled defaults are ordinary Fortran assignments in
`source/controls.defaults`. `set_xnet_controls_defaults` includes that file, so
those assignments are the single executable source of default values. Component
initializers in `xnet_controls_t` leave a bare object deterministic and invalid
as a whole, although flags for which zero has historical meaning retain that
meaningful value. A bare object fails validation until the defaults are applied. `data_dir` and
input-file pairs remain blank after default initialization because each
standalone problem must supply them.

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
layer has been read. Rank zero reads and validates the files, then broadcasts
the resolved value. `write_controls` emits a complete, flattened, re-readable
`&xnet_controls` block to the ordinary diagnostic stream. The block records
effective post-application values (including the BDF change-limit transformation)
and can be extracted as a new `controls.nml`. No separate resolved file is made.

After validation, `apply_xnet_controls` transfers the value into the existing
module variables used by XNet execution. That bounded migration seam preserves
the current internal interfaces and accelerator data-management directives;
this configuration change does not pass the new type throughout the network.

For migration, the historical blocks map directly: Job Controls map to
`szone` through `iprocess`; Integration Controls map to `isolv` through
`tdel_maxmult`; Self-heating, NSE, and Neutrinos map to their like-named
fields; Output Controls map to `idiag`, `itsout`, filename bases, `nnucout`,
and `output_nuclei`; Input Controls map to `data_dir`, `inab_files`, and
`thermo_files`.  Integer-valued flags retain their historical integer values.
