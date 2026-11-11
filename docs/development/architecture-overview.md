# Current architecture overview

> Read this document when work spans modules, changes subsystem interaction,
> alters data flow, or requires architectural reasoning.

This document describes the current repository. Verify the relevant source
before making a change, and update this overview when verified implementation
details change. Proposed designs belong in their governing issue or a
dedicated design document.

## Repository areas

- `source/` contains production Fortran, the stand-alone driver, and utility
  programs. The production GNU Make entry point and configuration files are at
  the repository root, with included rules under `make/`.
- `tools/LAPACK/` contains the vendored NETLIB subset used by the tracked
  baseline configuration.
- `tools/starkiller-helmholtz/` supplies the tracked default EOS
  implementation and table.
- `test/` contains legacy problem inputs, network data, settings, and shell
  drivers.
- `tools/` also contains network-building, thermodynamic, analysis, and Python
  utilities.
- `doc/` contains formatting guidance and scientific or solver references.
- `docs/development/` contains task-oriented development guidance.

Production builds place objects, module files, retained preprocessing, and
executables under a readable build directory such as `build/GNU-OPT`, or one
selected explicitly with `BUILD_NAME` or `BUILD_DIR`.
The build compiles selected dependencies from `tools/` without generating
source-tree products.

## Production areas

| Area | Principal files | Current role |
| --- | --- | --- |
| Foundation | `xnet_types`, `xnet_constants`, `xnet_util`, `xnet_timers`, `xnet_fd` | Kinds, constants, utilities, timing, and Fermi-Dirac functions |
| Configuration and state | `xnet_controls`, `xnet_conditions`, `xnet_abundances`, `xnet_data` | Runtime controls, thermodynamic state, abundances, species data, and reaction data |
| Physics | `xnet_ffn`, `xnet_nnu`, `xnet_screening`, `xnet_flux`, `xnet_match`, `xnet_nse`, `xnet_eos_*` | Weak and neutrino rates, screening, fluxes, reaction matching, NSE, and EOS selection |
| Linear algebra | `xnet_linalg`, `xnet_jacobian_*` | BLAS/LAPACK dispatch and solver-specific Jacobian storage and solves |
| Integration | `xnet_integrate`, `xnet_integrate_be`, `xnet_integrate_bdf` | Rate updates, derivatives, timestep logic, and implicit integration |
| Driver and output | `net`, `model_input_ascii`, `xnet_evolve`, `xnet_output` | Initialization, zone input, evolution, diagnostics, and the `xnet` program |
| Utilities | `net_setup`, `nse_slice` | Network preprocessing and the `xnse` program |
| Portability | `xnet_parallel*`, `xnet_gpu`, `xnet_macros.fh`, vendor binding modules | Serial/MPI selection and accelerator interfaces |

This table is a navigation aid. Module dependencies and side effects cross
these areas, especially through shared module state.

## Program setup

`net.F90` is the stand-alone production program. Its setup path currently:

1. initializes serial or MPI execution, determines the OpenMP thread count,
   initializes GPU execution when selected, and starts setup timing;
2. reads and validates `controls.nml` through `xnet_controls`;
3. preprocesses the requested network when needed, then reads nuclear,
   reaction, Jacobian, and match data;
4. initializes screening, flux evaluation, the selected EOS and integrator,
   NSE support, and shared run arrays;
5. reads thermodynamic histories and initial abundances through
   `model_input_ascii`;
6. evolves assigned zones and writes diagnostic or timestep output;
7. releases non-Jacobian module storage, then accelerator and parallel resources.

The exact order and conditional calls live in `source/net.F90`.
`xnet_controls_t` is the validated configuration value shared with programmatic
callers. The current executable uses `apply_standalone_controls` to enforce its
file-input requirements and copy the value into the existing module execution
state. The `xnet_api` lifecycle provides initialization, constant-condition
batched burns, scalar NSE composition queries, and cleanup for a dense
instance. A CPU OpenMP build assigns disjoint batch banks and NSE scratch to
application workers; the application owns the batch loop. Initialization and
finalization stay outside the fixed worker team. GPU host calls remain
serialized. CPU and GPU paths share control application,
network preprocessing and abundance/condition allocation with the standalone
driver. API burns can write separate per-call timestep histories through the
existing output routines. Both drivers use `xnet_output` to open binary and ASCII
files, write their headers, and close the current worker's files. Each driver
chooses its filenames and file-creation policy; the standalone driver retains
its general input histories. See
[the Fortran library API guide](embedding.md) for status and ownership limits.

Both frontends call the same setup and cleanup routines in `xnet_evolve`; the
comment above `read_network_data` shows the order. Setup reads the species and
reaction data (`read_network_data`), reads the Jacobian and matching data and
initializes screening, fluxes, the EOS and the integrator
(`initialize_solver_and_physics`), and allocates the per-zone abundance,
condition and neutrino storage (`initialize_zone_workspace`). Standalone XNet
stores whole trajectories (`nhmx` history points per zone); the API stores the
start and end points of a constant-condition burn. Condensed ASCII output
species are looked up by `resolve_output_species` in `xnet_output`, which
standalone always calls and the API calls only when `itsout > 0`.

Cleanup runs `finalize_evolution_workspace` (integrators, NSE, EOS), then the
Jacobian release, then `finalize_network_workspace` (everything else, with the
controls last). Every owner unmaps its accelerator arrays before it frees the
CPU arrays, and GPU resources outlive all of these calls. The API releases the
Jacobian between the two cleanup calls. Standalone XNet does not release it,
because some sparse providers have no finalizer; the storage lasts until the
program exits. The API's checked lifecycle and retryable GPU cleanup stay in
`xnet_api`. MPI, trajectory input, batch scheduling, file names and device
selection by rank stay in `net.F90`.

## Reading the driver and library source

For an application integration, start with [embedding.md](embedding.md) and
`source/xnet_api.F90`. For a trajectory calculation, start with the six stages
in `source/net.F90`. The following files explain the state shared by both paths:

| Question | Where to look |
| --- | --- |
| Which controls can I set, and in what units? | `xnet_controls_t` and its output-level table in `source/xnet_controls.F90`; call `set_xnet_controls_defaults` before overriding fields |
| How do controls reach the runtime arrays? | `validate_xnet_controls`, `apply_xnet_controls`, and `controls_finalize` in the same module; standalone namelist reading follows them |
| What happens during a burn? | The six stages in `full_net` in `source/xnet_evolve.F90`, including solve/output masks and the separate caller-handled and standalone failure paths |
| Who owns composition and trajectory storage? | Initialization/finalization routines at the top of `source/xnet_abundances.F90` and `source/xnet_conditions.F90`, including their persistent device mappings |
| What is in the input/output files? | Reader headers in `source/model_input_ascii.F90` and file lifecycle, timestep output, and reproducer sections in `source/xnet_output.F90` |
| What do the timers measure? | Accumulator comments in `source/xnet_timers.F90` and the scope of `xnet_timing_t` in `source/xnet_api.F90`; nested timings are not additive |

Keep the two composition conventions distinct: standalone abundance files and
internal arrays use molar abundances `Y = X/A`; `xnet_burn_batch` accepts mass
fractions `X`. Workspace index `izb` selects a slot in the current worker bank
`zb_lo:zb_hi`. The corresponding input-zone ordinal is
`izone = izb + szbatch - zb_lo`; diagnostic mesh labels are the separate
`zone_id(:,izb)` tuple.

## Per-timestep flow

`full_net()` in `xnet_evolve.F90` coordinates a zone batch through the time
integration loop. The selected runtime integration method calls the shared
integration support and a build-selected Jacobian module.

The main numerical flow is:

```text
full_net()
  -> timestep()
       -> retain the prior timestep state and identify zones needing an initial estimate
       -> cross_sect() and yderiv() for zones needing an initial estimate
       -> timestep selection and trial-state preparation
  -> selected BE or BDF implicit solve
       -> Newton iterations
       -> cross_sect()
            -> EOS-dependent quantities
            -> screening and partition functions
            -> weak and neutrino rates
            -> velocity-integrated reaction-rate arrays
       -> yderiv()
            -> abundance derivatives
       -> jacobian_build()
       -> jacobian factorization/solve
       -> abundance and optional temperature update
  -> accept/retry logic and output
```

Inspect `xnet_evolve.F90`, `xnet_integrate.F90`, the selected integrator, and
the selected Jacobian file together when changing this path.

## Build-time selection

`Makefile.opt` exposes compiler environment, compile mode, MPI,
threading, accelerator mode, EOS, matrix solver, and CPU/GPU linear-algebra
choices. `Makefile.internal` maps those choices to compilers, flags,
sources, and libraries. The conventional fragments under `make/`
separate implementation selection, source lists, explicit module
prerequisites, and build rules. In particular, `providers.mk` selects the
source or library that supplies the requested MPI, EOS, Jacobian,
numerical-library, and accelerator implementation.
`machines.mk` retains hostname/LMOD detection and explicitly selects the
tracked generic or Cray Programming Environment defaults; compiler-family
flags remain in `Makefile.internal`.

Important selections change which file is intended to supply a common module
name:

- `xnet_parallel.F90` or `xnet_parallel_stubs.F90` supplies
  `xnet_parallel`.
- `xnet_eos.F90`, `xnet_eos_helm.F90`, or
  `xnet_eos_bahcall.F90` supplies `xnet_eos`. STARKILLER and EXTERNAL use
  `xnet_eos.F90` for XNet's composition moments, screening, scratch,
  masks, and unit conversions. The build selects a small `xnet_eos_interface` module
  for the underlying thermodynamics: the bundled `xnet_eos_starkiller.F90`
  provider or an application source supplied with `EOS=EXTERNAL`. An
  application provider leaves host-owned EOS initialization and cleanup to the host.
- one `xnet_jacobian_*.F90` file supplies `xnet_jacobian`.

Source inspection and tests must follow the configuration named by the task.

`xnet_linalg.F90` exposes one batched GPU LU/solve routine family:

```text
LinearSolveBatched_GPU
  -> LUDecompBatched_GPU
  -> LUBksubBatched_GPU
```

The vendor calling convention remains inside those routines. cuBLAS and MAGMA
use pointer-array batched calls; hipBLAS and oneMKL use strided-batched calls.
`xnet_jacobian_dense.F90` does not select between those representations.
cuBLAS retains XNet's implemented no-pivot path. XNet currently rejects a
no-pivot request for the hipBLAS, oneMKL, and MAGMA implementations rather
than silently changing the requested solve.

## Shared state and interfaces

Many modules own allocatable arrays and control values shared through `Use`
associations. Zone batching, thread ranges, and active-zone masks organize
work across these arrays. Changes to allocation, dimensions, initialization,
or batch indexing can affect distant routines.

`xnet_data.F90` currently defines both `nuclear_data` and `reaction_data`.
The selected EOS and Jacobian implementations use common module names, which
makes their interfaces compile-time requirements across implementations.

The stand-alone runtime interface includes:

- the layered `xnet_controls` namelist in `controls.nml`;
- nuclear data and pre-built network files under `Data_*` directories;
- thermodynamic histories and abundance inputs;
- fixed-format diagnostic and timestep outputs.

Treat ordering, units, dimensions, naming conventions, and output formats as
compatibility-sensitive behavior. Trace reads and writes in source when
changing any of them.

## Architectural investigation

For a change spanning modules:

1. identify the build-time implementations involved;
2. trace module variables, allocation, and initialization from the driver;
3. trace the active scalar, vector, batch, thread, MPI, and accelerator paths;
4. identify runtime and output interfaces affected;
5. characterize current behavior before structural edits;
6. state proposed structural changes separately from the current-state report.

Document uncertainty when the current implementation or supported
configurations have limited evidence.
