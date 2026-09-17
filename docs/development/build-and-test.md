# Build and test guidance

> Read this document when changing build logic, selecting a configuration,
> running legacy problems, adding tests, comparing numerical results, or
> measuring performance.

This document describes current repository behavior. Verify task-relevant
details in the Makefiles, test drivers, and source before relying on them.

## Build entry point

The production build uses GNU Make and writes its results below a
caller-selected build directory. From the repository root, build the tracked
default with:

```bash
make -C source -j
```

The default executable is `build/default/bin/xnet`. Set a readable `BUILD_NAME`
for a directory below `build/`, or set `BUILD_DIR` directly. Relative paths
are interpreted from the repository root:

```bash
make -C source BUILD_NAME=gnu-debug CMODE=DEBUG -j xnet
make -C source BUILD_DIR=/scratch/$USER/xnet-frontier -j xnet
```

The Makefile fragments have distinct roles:

- `source/Makefile` is the small public entry point. Its included
  `source/make/build.mk` defines the production build and its output layout.
- `source/make/configuration.mk` validates compiler/platform selectors.
- `source/make/providers.mk` selects the MPI, EOS, solver, accelerator, and
  numerical-library providers.
- `source/make/sources.mk` lists sources and output files and records
  configuration reuse.
- `source/make/dependencies.mk` records explicit Fortran module prerequisites.
- `source/make/rules.mk` contains preprocessing, compilation, link, and public
  target rules.
- `source/Makefile.opt` defines tracked user-selectable defaults.
- `source/Makefile.internal` maps configuration choices to compilers, flags,
  libraries, source files, and solver objects.
- `source/make/machines.mk` detects the current host and explicitly selects
  the tracked generic or Cray Programming Environment defaults. Compiler
  defaults remain in `Makefile.internal`; add a machine fragment and one
  visible mapping entry only when a real repository-supported machine needs
  concrete overrides. Perlmutter is the current NERSC production system, and
  Frontier is the retained OLCF accelerator qualification system. Summit and
  Cori names remain only in retired-host compatibility lists. The maintainer
  currently uses no IBM system; `summit`, `summitdev`, and `mira` remain only
  as retired compatibility settings.

Inspect the conditional path through these files for any configuration being
changed. Variable names and commented examples provide orientation; the
selected Make logic determines the build.

Each build directory contains a fixed-order `config.txt` record. Reusing it
with different selectors, providers, compiler commands, or effective flags
fails; clean that directory or choose another one. The conventional POSIX
record supports ordinary flag text but rejects effective flags containing a
single quote or line break. Do not run two top-level Make processes in one
build directory, and do not clean a directory while another invocation uses
it. Different build directories may build concurrently.

## Tracked defaults

The tracked defaults currently resolve to:

| Setting | Value | Meaning |
| --- | --- | --- |
| `EXE` | `xnet` | Main executable name |
| `CMODE` | `OPT` | Optimized build |
| `PE_ENV` | `GNU` | GNU compiler configuration |
| `MPI_MODE` | `OFF` | Selects the serial parallel-interface stubs |
| `OPENMP_MODE` | `OFF` | OpenMP host threading disabled |
| `GPU_MODE` | `OFF` | Accelerator runtime and libraries disabled |
| `GPU_BACKEND` | `CUDA` | Accelerator vendor selection when GPU mode is enabled |
| `EOS` | `STARKILLER` | Starkiller Helmholtz EOS interface |
| `MATRIX_SOLVER` | `dense` | Dense Jacobian and linear solve |
| `LAPACK_VER` | `NETLIB` | Default on ordinary non-Cray systems |

These values describe configuration selection. Record actual validation in the
governing issue or PR with the compiler version, command, machine, relevant
environment, result, and date.

## Optional sparse-backend status

A named Make target records a build recipe, not a support claim. The current
serial CPU support dispositions are:

| Provider | Selection | Status and limit |
| --- | --- | --- |
| HSL MA48 2.2.0 | `MATRIX_SOLVER=MA48` with external `MA48.f` | Qualified on macOS arm64 with GNU Fortran 16.2.0 using the production build. The maintainer-supplied source is used under a maintainer-held non-redistributable HSL licence and must remain outside the repository. Other HSL versions, compilers, and platforms are unqualified. |
| Standalone PARDISO | `MATRIX_SOLVER=PARDISO` with `LAPACK_VER` other than `MKL` | Unsupported and unqualified. No approved compatible standalone dependency is maintained, and the legacy `/usr/local/pardiso` library-name defaults are not evidence of support. |
| Intel oneMKL PARDISO | `MATRIX_SOLVER=PARDISO LAPACK_VER=MKL` | Previously qualified on the `etacar` Linux x86_64 host with GNU Fortran 11.4.0 and oneMKL 2026.1. The current production build has not been checked there because the host is unreachable, so this revision remains unverified for oneMKL. Other oneMKL versions, compilers, platforms, and parallel modes are unqualified. |

MA48 source must not be copied, committed, archived, or attached to an issue or
pull request. HSL describes MA48 2.2.0 and its licensing restrictions in the
[official catalogue](https://www.hsl.rl.ac.uk/catalogue/ma48.html) and
[licensing overview](https://www.hsl.rl.ac.uk/). oneMKL is distributed under
Intel's [Simplified Software License](https://www.intel.com/content/www/us/en/developer/articles/tool/onemkl-license-faq.html).
The exact opt-in component and same-source dense comparison commands are in
[`test/qualification/sparse_backends/README.md`](../../test/qualification/sparse_backends/README.md).

## Platform status

| Configuration | Current status |
| --- | --- |
| GNU serial OPT and DEBUG | Built and tested on macOS arm64 with GNU Fortran 16.2.0; the hosted GNU serial jobs provide the Linux check. |
| GNU MPI and OpenMP | Serial, two-rank MPI, and two-thread OpenMP results agreed on the ten-zone qualification problem on macOS arm64 with GNU Fortran 16.2.0 and Open MPI 5.0.10. |
| Frontier HIP/ROCm OpenMP offload | Earlier fork qualification applies to source `97174bc0b382ed2c580eb517b05479e0ee63b184`, CCE 20.0.2, ROCm 6.4.2, hipfort 6.4.2, and MI250X. The current build-directory implementation has not been rerun on Frontier and is unverified there. |
| Perlmutter | Current NERSC host selection is maintained, but no Perlmutter qualification is recorded for this revision. |
| Summit and Cori host names | Retired compatibility settings only. |
| Retired IBM host names | No current IBM system or qualification. `summit`, `summitdev`, and `mira` remain as compatibility settings only. |

The exact commands, source revision, and any launcher-specific options belong
in the issue or pull-request evidence for each run. A successful build alone
does not establish runtime or numerical agreement.

Make can display resolved values through the existing `print-%` target. For
example:

```bash
make -C source --no-print-directory print-CMODE
make -C source --no-print-directory print-MATRIX_SOLVER
```

## Configuration changes and clean builds

Each build directory contains predictable `obj/`, `mod/`, `pp/`, and
`bin/` subdirectories plus `config.txt`. The configuration record preserves
the exact effective selectors, commands, flags, provider paths, and
external source paths. Reusing the directory with different material settings fails
before preprocessing or compilation and directs the user to clean or choose
another directory.

The line-oriented record accepts ordinary single-line Make values. Embedded
single quotes and line breaks in recorded commands, flags, providers, or paths
are rejected with a clear diagnostic; select an equivalent spelling or another
build directory.

Use a different readable directory for a different configuration:

```bash
make -C source BUILD_NAME=gnu-opt -j xnet
make -C source BUILD_NAME=gnu-debug CMODE=DEBUG -j xnet
```

`clean` removes only the selected marked build directory and does not require
the old configuration to be restated. `clean-all` removes only marked direct
children of `BUILD_BASE` and requires `CONFIRM_CLEAN_ALL=yes`. Do not clean
while a build uses that directory; run cleaning and building as separate
commands. Mixed cleaning/product goals are rejected.

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

The default target builds `build/default/bin/xnet`. Common utility builds are:

```bash
make -C source -j net_setup
make -C source -j xnse
```

- `net_setup` preprocesses network data.
- `xnse` is the stand-alone NSE state calculator.

`all` builds the three canonical programs together. Solver-named `xnet_*`
aliases select that solver directly and reject conflicting selectors.
`xinab` and `xnet_gpu` are unsupported and fail early; accelerator builds use
`xnet` with explicit supported selectors. Target presence records a build
recipe, not a support claim.

## Focused component and executable tests

The Fortran component suite includes a complete serial XNet executable
smoke:

```bash
make -C test/unit
```

It uses the tracked GNU optimized configuration by default, compiles selected
production sources into the ignored `test/unit/build/` directory, and performs
no network access. Its build-net interoperability check always cleans and
builds the requested tracked configuration before resolving and running the
canonical XNet path, so an incompatible configuration cannot be reused. Run
the bounds-checking configuration with:

```bash
make -C test/unit clean test CMODE=DEBUG
```

See `test/unit/README.md` for the tested behavior, narrow test-only
state and stubs, vendored `test-drive` revision and license, update procedure,
and issue-specific effectiveness evidence.

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
- runs a supplied executable or `build/default/bin/xnet`;
- looks for an MPI build at `build/mpi/bin/xnet`; set `XNET_MPI` to use
  another predictable build directory;
- moves diagnostics into `test/Test_Results/`;
- removes timer sections before comparison;
- prints a warning and writes `diff_*` when results differ.

The wrapper invokes the selected executable without capturing or propagating
its exit status. Its final commands normally leave a zero wrapper status even
when the executable or intermediate file operations fail, and a request with
no recognized problem ID can run no problem. Treat the wrapper status as
uninformative. Confirm program invocation, direct program status, expected
diagnostics, output production, and numerical agreement separately.

A clean checkout currently supplies no tracked comparison files under
`test/Test_Problems/Results/`. The script creates that directory. Ordinary
problem paths then attempt comparison against absent results. The `xnse` path
copies the current result into the reference location when the expected file
is absent, and those diagnostic files are ignored by `.gitignore`. Establish
an independent comparison result with recorded provenance before claiming
numerical agreement.

Legacy problem drivers remain under `test/`; the production Makefile does not
duplicate them as recursive build targets. Some legacy drivers create a
Helmholtz-table symlink, write `control`, create result directories, move
diagnostic files, create comparison files, or run preprocessing inside a
tracked data directory.

`test/test_xnet.csh` is an older driver. Use it as historical information and
verify every command needed for a current task.

After any legacy run:

1. capture direct program status or state why the wrapper obscures it;
2. confirm that the requested problem ran and produced expected diagnostics;
3. inspect generated `diff_*` files and identify whether an independent
   comparison result exists;
4. record the comparison result's provenance;
5. state the quantities and tolerances used for the conclusion;
6. inspect ignored files as well as `git status` for generated or modified
   files;
7. preserve established reference data unless the issue explicitly changes
   it.

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
settings out of commits. Production objects, module files, preprocessing
output, `config.txt`, and executables remain below `BUILD_DIR`, but legacy
problem drivers can still write into `test/`; review ignored files as well as
`git status` after runs.
