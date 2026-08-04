# Build and test guidance

> Read this document when changing build logic, selecting a configuration,
> running legacy problems, adding tests, comparing numerical results, or
> measuring performance.

This document describes current repository behavior. Verify task-relevant
details in the Makefiles, test drivers, and source before relying on them.

## Build entry point

The production build uses GNU Make and writes its results into `source/`.
From the repository root, build the tracked default with:

```bash
make -C source -j
```

The Makefile fragments have distinct roles:

- `source/Makefile` defines production targets, selects driver and EOS
  objects, and records the object dependency graph.
- `source/Makefile.opt` defines tracked user-selectable defaults.
- `source/Makefile.internal` maps configuration choices to compilers, flags,
  libraries, source files, and solver objects.
- `source/Makefile.dev` adds accelerator libraries, flags, objects, and
  development targets. The main Makefile includes it when present.

Inspect the conditional path through these files for any configuration being
changed. Variable names and commented examples provide orientation; the
selected Make logic determines the build.

## Tracked defaults

The tracked defaults currently resolve to:

| Setting | Value | Meaning |
| --- | --- | --- |
| `EXE` | `xnet` | Main executable name |
| `CMODE` | `OPT` | Optimized build |
| `PE_ENV` | `GNU` | GNU compiler configuration |
| `MPI_MODE` | `OFF` | Serial driver with parallel stubs |
| `OPENMP_MODE` | `OFF` | OpenMP host threading disabled |
| `GPU_MODE` | `OFF` | Accelerator runtime and libraries disabled |
| `GPU_BACKEND` | `CUDA` | Accelerator vendor selection when GPU mode is enabled |
| `EOS` | `STARKILLER` | Starkiller Helmholtz EOS interface |
| `MATRIX_SOLVER` | `dense` | Dense Jacobian and linear solve |
| `LAPACK_VER` | `NETLIB` | Default on ordinary non-Cray systems |

These values describe configuration selection. Record actual validation in the
governing issue or PR with the compiler version, command, machine, relevant
environment, result, and date.

Make can display resolved values through the existing `print-%` target. For
example:

```bash
make -C source --no-print-directory print-CMODE
make -C source --no-print-directory print-MATRIX_SOLVER
```

## Configuration changes and clean builds

Production builds are in-place. Objects, module files, and executables from
different configurations share filenames. Make does not track build-variable
changes as prerequisites.

Use a clean rebuild after changing any choice that can affect compiled code or
linked libraries:

```bash
make -C source clean
make -C source -j CMODE=DEBUG
```

This includes changes to compiler, compile mode, numerical flags, MPI,
threading, accelerator mode, EOS, matrix solver, or CPU/GPU linear algebra.
The clean target removes objects and module files while leaving some
executables. Confirm the requested target was linked in the new build output.

Pass local configuration choices on the Make command line and leave tracked
defaults unchanged. The main selection variables include:

- `CMODE` and `PE_ENV` for optimization/debug mode and compiler family;
- `MPI_MODE` and `OPENMP_MODE` for distributed and host-threaded execution;
- `GPU_MODE`, `GPU_BACKEND`, `OPENACC_MODE`, and `OPENMP_OL_MODE` for
  accelerator execution and directive model;
- `LAPACK_VER` and `GPU_LAPACK_VER` for CPU and accelerator numerical
  libraries;
- `MATRIX_SOLVER` for the Jacobian and linear solver implementation;
- `EOS` for the equation-of-state implementation.

Each selected path requires its compiler, headers, libraries, and runtime.
Validate support and numerical behavior for the exact combination used.

## Production and utility targets

The default target builds `source/xnet`. Common utility builds are:

```bash
make -C source -j net_setup
make -C source -j xnse
```

- `net_setup` preprocesses network data.
- `xnse` is the stand-alone NSE state calculator.

The Makefile also contains solver-named `xnet_*` targets, the `all` target,
accelerator development targets, test targets, and `xinab`. Read their recipes
and prerequisites before use. Their presence records an available recipe and
selection path. Current support depends on the requested platform and the
evidence collected for the task.

## Runtime inputs

The stand-alone driver reads a file named `control` from its working directory.
`source/xnet_controls.F90` locates labeled blocks and reads the values within
each block in a specific order. Ordering and format changes can affect existing
inputs.

Legacy problems assemble a control file by joining a `test/test_settings*`
file with a matching `test/Test_Problems/setup_*` file. The setup file refers
to thermodynamic trajectories, initial abundances, and nuclear data under
`test/Data_*`. Source code remains authoritative for the values read and their
meaning.

`test/Data_*` directories contain pre-built nuclear networks. Network
preprocessing work should identify whether these tracked files are inputs,
generated results, or comparison data before changing them.

## Legacy test behavior

The current test infrastructure supports investigation and historical problem
runs. It has unreliable pass/fail reporting.

`test/test_xnet.sh`:

- selects problems by numeric ID;
- combines settings and setup files into `test/control`;
- runs a supplied executable or a historical default;
- moves diagnostics into `test/Test_Results/`;
- removes timer sections before comparison;
- prints a warning and writes `diff_*` when results differ.

A numerical mismatch in `test_diff` can still leave the script with a zero
exit status. Treat command completion, output production, and numerical
agreement as separate observations.

The `source/Makefile` includes `test`, `test_serial`, `test_heat`,
`test_simple`, `test_batch`, `test_setup`, and `test_nse` targets. Inspect the
target recipe and corresponding problem IDs before running one. Some targets
create a Helmholtz-table symlink, write `control`, create result directories,
move diagnostic files, create comparison files, or run preprocessing inside a
tracked data directory.

`test/test_xnet.csh` is an older driver. Use it as historical information and
verify every command needed for a current task.

After any legacy run:

1. inspect program diagnostics and exit status;
2. inspect generated `diff_*` files and both compared results;
3. state the quantities and tolerances used for the conclusion;
4. inspect `git status` for generated or modified files;
5. preserve tracked reference data unless the issue explicitly changes it.

## Evidence for new work

For a defect fix, identify or add evidence that distinguishes the faulty
behavior from the corrected behavior. Prefer demonstrating that the check
fails before the fix when practical.

Choose the smallest check that exercises the requirement. Record:

- the exact command and working directory;
- compiler version and relevant build variables;
- input problem and data source;
- expected and observed behavior;
- comparison method and tolerances;
- generated files or reference results;
- checks that remain for other compilers, parallel modes, accelerators, or
  facilities.

Use `docs/development/scientific-validation.md` for changes that affect
physics, numerical behavior, tolerances, convergence, or performance.

## Generated and machine-specific files

Keep build objects, module files, executables, diagnostic outputs, comparison
files, temporary control files, local installation paths, and machine-specific
settings out of commits. Review the worktree after builds and runs because the
legacy recipes write into `source/` and `test/`.
