# XNet v9 release notes

XNet v9 adds a Fortran library, `libxnet`, through which applications such as
CHIMERA and Flash-X call XNet without using its internal modules. Standalone
runs now read a validated namelist, `controls.nml`, instead of the positional
`control` file, and the build moved to the repository root. Backward Euler
and BDF integration, CPU OpenMP batches, CUDA/OpenACC and HIP/OpenMP-target
execution remain available within the limits below.

The release candidate and its outstanding decisions are tracked in
[issue #132](https://github.com/jaharris87/XNet/issues/132).

## Upgrading standalone runs

- **Build from the repository root.** `source/Makefile` is gone. `make -j`
  builds `build/GNU-OPT/bin/xnet`; other configurations get their own
  directory, for example `make CMODE=DEBUG -j` builds in `build/GNU-DEBUG/`.
  The solver is chosen with `MATRIX_SOLVER` (for example
  `make MATRIX_SOLVER=MA48 MA48_DIR=...`) rather than `xnet_MA48`-style
  targets, and the old `test_*` Make targets are replaced by the
  [pytest regression suite](../test/regression/README.md). See the
  [build guide](development/build-and-test.md).
- **Convert `control` to `controls.nml`.** XNet no longer reads `control`.
  `python3 tools/convert_control.py control -o controls.nml` converts an
  assembled v8 file. Array controls (`inab_files`, `thermo_files`,
  `output_nuclei`) need one explicit index per entry. Controls files can
  include other controls files to layer local changes over a base. See
  [running standalone XNet](running-xnet.md).
- **Update scripts that read `net_diag`.** The controls echoed at the top of
  each `net_diag` file are now a complete, re-readable `&xnet_controls`
  block instead of v8's `control` layout.

## Coupling an application

Build the library with `make -j libxnet` and compile and link against the
exported `xnet-config.mk`. The [library API guide](library-api.md)
starts with a complete CPU example.

| Operation | Procedure |
| --- | --- |
| Load one network and prepare reusable workspace | `xnet_initialize` |
| Evolve a batch of zones at constant density | `xnet_burn_batch` |
| Compute an NSE composition | `xnet_nse_composition` |
| Release XNet storage | `xnet_finalize` |

The application keeps its species mapping, batch loop, MPI, EOS tables and
energy policy. Burns take mass fractions in the order returned in
`network%names` and temperature in K. In CPU OpenMP builds each thread of one
fixed application team may call XNet for its own batch; GPU calls are
serialized on the selected device and may use arrays the application has
already mapped. Applications may supply their own stream and library handles,
and their own EOS through `EOS=EXTERNAL`.

Every call returns a status. Integrator failure and the step limit
(statuses 4 and 5) require the application to shut down. Some errors still
stop the process inside XNet; see
[status and shutdown](library-api.md#status-and-shutdown).

Callers of the v9 development prototypes must rebuild; the
[development-caller list](library-api.md#updating-a-development-caller)
covers `gpu_context`, four-component zone IDs, `timing%evolve`, EOS procedure
names and prefixed vendor modules.

## Changes that affect results

- Three-reactant strong screening now includes the free-energy contribution
  of the middle reactant, within the existing screening model
  ([#175](https://github.com/jaharris87/XNet/pull/175)).
- Reported and returned Ye is computed from the accepted composition,
  including weak-reaction changes, instead of from an earlier Newton iterate
  ([#182](https://github.com/jaharris87/XNet/pull/182)). Ye values in older
  reference outputs can differ even where compositions agree.
- A timestep chosen to land on the requested stop time keeps that endpoint
  exactly; reduced or rejected retries recompute their endpoints. Previously
  the selected endpoint could be reconstructed one rounding step short
  ([#209](https://github.com/jaharris87/XNet/pull/209)).
- CPU threads now have separate work arrays indexed by local batch position.
  This changes floating-point details in some comparisons; see
  [#204](https://github.com/jaharris87/XNet/pull/204).
- The reaction flux in the first (time zero) record of a standalone history
  is now zero; previously it could hold the final flux of an earlier batch.
- FFN interpolation now holds table values at both temperature and density
  edges instead of extrapolating or reading past the tables. Logft capture
  phase space still uses the actual thermodynamic state; see
  [weak-rate table limits](running-xnet.md#weak-rate-table-limits)
  ([#225](https://github.com/jaharris87/XNet/pull/225)).
- NSE initial guesses use available species selected for the query Ye when
  reference nuclei are absent, avoiding invalid species indices
  ([#228](https://github.com/jaharris87/XNet/pull/228)).
- Library burns and NSE queries reject supplied Ye outside `(0,1]`. Burns
  also require positive electron content in the composition, including any
  auxiliary reservoir. Standalone abundance input rejects zero-electron
  compositions before normalization
  ([#231](https://github.com/jaharris87/XNet/pull/231)).
- GPU diagnostics now perform low-temperature warning I/O on the host and
  refresh host copies for failure dumps and dense-factorization diagnostics.
  Device-resident loss output no longer writes the caller's host mirror
  ([#227](https://github.com/jaharris87/XNet/pull/227)).

## Checked configurations

| Configuration | Checked with |
| --- | --- |
| Serial, MPI and CPU OpenMP | GNU Fortran 16.2.0 on macOS arm64, Open MPI 5.0.10 |
| CUDA/OpenACC | NVHPC 26.5, CUDA 13.2, one A100 (Perlmutter) |
| HIP/OpenMP target | CCE 20.0.0, ROCm 6.4.2, hipfort 6.4.2, one MI250X (Frontier) |
| CPU OpenMP on Perlmutter | NVHPC 26.5 with LibSci, using `OMP_STACKSIZE=16M` ([workaround](development/build-and-test.md#perlmutter-nvidia-cpu-openmp-stack-workaround)) |

These checks apply to the listed configurations and source versions. See the
build guide for separate optional sparse-backend records. The checks ran at
the source versions named in the
[build guide](development/build-and-test.md#platform-status) and the
[component record](https://github.com/jaharris87/XNet/pull/204#issuecomment-7017135890),
which also give the inputs and results. CHIMERA and Flash-X results,
including native EOS and energy handling, are in
[#130](https://github.com/jaharris87/XNet/issues/130); CHIMERA uses its SFHo
tabulated EOS; its deprecated non-tabular EOS integration is outside v9
scope. Public library GPU checks do not establish application GPU
execution. The original CHIMERA Frontier CPU FFN failure remains unresolved;
the related public FFN repair in [#164](https://github.com/jaharris87/XNet/issues/164)
does not establish its cause. Cost measurements are in
[#131](https://github.com/jaharris87/XNet/issues/131); v9 sets no speedup
requirement.

## Known limits

- The library supports the dense solver only, `MPI_MODE=OFF`, and one
  initialized network per process. It does not support incident-neutrino
  histories. Concurrent GPU host calls and general multi-GPU use are
  neither supported nor checked.
- OpenMP-target GPU builds require `OPENMP_MODE=OFF`, also for standalone
  programs.
- The shared COMMON-block `EOS=HELMHOLTZ` provider requires
  `OPENMP_MODE=OFF`; Make rejects it with host OpenMP enabled
  ([#229](https://github.com/jaharris87/XNet/pull/229)).
- Open questions: instantaneous energy-generation output
  ([#62](https://github.com/jaharris87/XNet/issues/62)), a check of finite,
  nonnegative per-call timings that failed once in a CPU OpenMP run
  ([#178](https://github.com/jaharris87/XNet/issues/178)), a four-thread
  NVIDIA CPU timeout and LibSci fault
  ([#192](https://github.com/jaharris87/XNet/issues/192)), and oneMKL PARDISO
  failures with several OpenMP threads
  ([#193](https://github.com/jaharris87/XNet/issues/193)).
- Planned after v9.0: arbitrary `sunet` species ordering
  ([#186](https://github.com/jaharris87/XNet/issues/186)), GPU sparse solvers
  and fTimer timers; see the [development plan](development/v9-plan.md).

The experimental surrogate checks in `source/xnet_surrogate_checks.F90` are
exercised by component tests but are not built into the programs or library.
