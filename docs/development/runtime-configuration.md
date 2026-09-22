# Runtime configuration

XNet v9 reads `xnet.nml` from the run directory.  The only supported input
group is `&xnet_config ... /`; the former line-oriented `control` parser is
not part of the production path.

`RuntimeConfig` in `source/xnet_controls.F90` is the single configuration
value used by both the standalone reader and programmatic callers.  A caller
starts with `SetRuntimeConfigDefaults`, changes the needed fields, and calls
`ValidateRuntimeConfig` before passing the value to its integration boundary.
The compiled defaults are the component initializers in `RuntimeConfig`:
one zone; BE (`isolv=1`); one-zone batching; no self heating or neutrinos;
`kstmx=9999`, `kitmx=5`, `ijac=1`, `iconvc=0`; and the legacy timestep and
convergence defaults shown in that type.  `data_dir` and input-file pairs are
intentionally not defaulted because the standalone driver requires them.

The supported namelist names match the fields: `description`, `szone`,
`nzone`, `iweak0`, `iscrn`, `iprocess`, `nzbatchmx`, `isolv`, `kstmx`,
`kitmx`, `ijac`, `iconvc`, `changemx`, `yacc`, `tolm`, `tolc`, `ymin`,
`tdel_maxmult`, `iheat`, `changemxt`, `tolt9`, `t9nse`, `ineutrino`,
`idiag`, `itsout`, `ev_file_base`, `bin_file_base`, `nnucout`,
`output_nuclei`, `data_dir`, `inab_files`, and `thermo_files`.

An input can name up to 16 `include` files.  XNet reads the including file,
then reads listed includes in their listed order; a later include overrides an
earlier value.  Relative paths are interpreted relative to the file that names
them.  Includes are limited to 16 nesting levels and cycles are rejected.
Validation and legacy single-pair filename expansion occur only after every
layer has been read.  Rank zero reads and validates the files, then broadcasts
the resolved value; rank zero writes `xnet.resolved.nml` for reproducibility.

For migration, the historical blocks map directly: Job Controls map to
`szone` through `iprocess`; Integration Controls map to `isolv` through
`tdel_maxmult`; Self-heating, NSE, and Neutrinos map to their like-named
fields; Output Controls map to `idiag`, `itsout`, filename bases, `nnucout`,
and `output_nuclei`; Input Controls map to `data_dir`, `inab_files`, and
`thermo_files`.  Integer-valued flags retain their historical integer values.
