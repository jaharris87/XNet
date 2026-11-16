# Historical recipe availability

`test/test_xnet.sh` and `test/test_xnet.csh` assemble historical positional
`control` inputs. They are recipe records, not current namelist launchers.
The [offline converter](runtime-configuration.md#converting-v8-ascii-controls)
covers the 26 tracked `test/Test_Problems/setup_*` recipes and eight retained
`test/regression/cases/*/control` fixtures without evolving networks.

Seven recipes have same-named maintained namelists: `tnsn_alpha`,
`tnsn_torch47`, `heat_alpha`, `heat_sn160`, `bdf_sn160`, `batch_alpha`, and
`xnse_sn160`. The eighth maintained case, `nse_sn160`, is a separate
characterization from historical `nse_ccsn_nup`.

The remaining 19 recipes are listed below. Settings are `test/test_settings`
plus the suffix shown; setup files are `test/Test_Problems/setup_<recipe>`.
IDs follow the implementation of the shell driver. All use `szone=1`,
`iprocess=1`, and `ineutrino=0`. Paths are relative to `test/` as the historical
working directory.

| ID | Recipe | Settings suffix | nzone | Network | Public input status |
| --- | --- | --- | --- | --- | --- |
| 3 | tnsn_sn160 | (none) | 1 | Data_SN160 | Present; execution untested |
| 4 | tisn_alpha | _small | 10 | Data_alpha | Present; execution untested |
| 5 | tisn_sn160 | (none) | 1 | Data_SN160 | Present; execution untested |
| 7 | nova_cno | _small | 10 | Data_CNO | Present; execution untested |
| 8 | nova_Iliadis | (none) | 1 | Data_Nova | Present; execution untested |
| 9 | xrb_cno | _small | 10 | Data_CNO | Present; execution untested |
| 10 | xrb_fisker | (none) | 1 | Data_XRB304 | Missing netneutr (392 captures) |
| 11 | ccsn_alpha | _small | 10 | Data_alpha | Present; first 10 of 11 pairs consumed; execution untested |
| 12 | ccsn_sn160 | (none) | 1 | Data_SN160 | Present; execution untested |
| 13 | ccsn_nup | (none) | 1 | Data_nup | Missing netneutr (1557 captures) |
| 15 | nuwind_alpha | _small | 10 | Data_alpha | Present; execution untested |
| 16 | nuwind_rprocess | (none) | 1 | Data_Reaclib20180621 | Missing netneutr (3307 captures) |
| 52 | heat_torch47 | _heat | 6 | Data_torch47 | Present; execution untested |
| 55 | logft_sn231 | _logft | 3 | Data_SN231_logft | Present, including netweak; execution untested |
| 62 | batch_torch47 | _batch | 16 | Data_torch47 | Present, numbered pairs 01..16; execution untested |
| 31 | parallel_sn160 | _parallel | 4 | Data_SN160 | Present, numbered pairs 1..4; MPI recipe; execution untested |
| 32 | parallel_alpha | _parallel | 4 | Data_alpha | Present, numbered pairs 1..4; MPI recipe; execution untested |
| 41 | nse_ccsn_nup | _nse | 1 | Data_nup | Missing netneutr (1557 captures) |
| 82 | xnse_sn231 | _xnse | 1 | Data_SN231 | Present, including input_xnse_test; execution untested |

This is a static tracked-input inventory at `d2dacf73` (2026-11-11): fifteen
recipes have the identified public files, while four lack required capture
tables. Presence is not a preprocessing, execution, or physical-equivalence
check. Every consumed abundance/trajectory path after suffix expansion, the
network's `sunet`, `netwinv`, `netsu`, and `netweak`, and the common Helmholtz
table are tracked. Prepared ASCII networks require preprocessing; generated
binary network files are not supplied by these recipes.

The `netsu` header stores `nffn` and `nnnu` in `(i5,i6)` fields;
`source/xnet_preprocess.F90` carries the counts to the generated network.
`source/xnet_data.F90` calls `read_nnu_data` whenever `nnnu>0`, and
`source/xnet_nnu.F90` opens `<data_dir>/netneutr` regardless of `ineutrino`.
The four missing-table recipes therefore remain unavailable from public
inputs even with their existing `ineutrino=0`. Conversion does not remove
that requirement. No substitute tables or changed flags are supplied.

Later v8/current physical comparisons need a separate bounded run plan and
maintainer interpretation. This inventory changes no scientific references,
tolerances, or historical files.
