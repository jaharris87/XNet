# XNet

XNet is a thermonuclear reaction network for astrophysical nucleosynthesis,
written in portable Fortran. It evolves nuclear abundances for an arbitrary
species set using implicit Backward Euler or Gear BDF integration and
selectable dense or sparse linear-algebra backends, across laptops, multicore
CPUs (MPI and OpenMP), and GPUs (CUDA/OpenACC and HIP/OpenMP target).

XNet supports two primary workflows:

- **Standalone post-processing** with `xnet`, driven by `controls.nml` for
  thermodynamic trajectories such as Lagrangian tracer-particle histories.
  The build also provides `xnse` for NSE calculations and `net_setup` for
  preparing networks.
- **Embedded library integration** (`libxnet` and the `xnet_api` Fortran
  module), for multiphysics codes such as CHIMERA and Flash-X.

See the [v9 release notes and migration guide](docs/v9-release-notes.md) for
what changed since v8.0, migration steps, and checked platform limits.

## Building XNet

Run GNU Make from the repository root. The default GNU optimized build places
programs under `build/GNU-OPT/bin/`:

```bash
make -j
```

Major build choices automatically select a distinct, readable build directory.
For example, this command builds under `build/GNU-DEBUG/bin/`:

```bash
make CMODE=DEBUG -j xnet
```

The automatic directory name reflects the compiler family, build mode,
MPI/OpenMP, accelerator, non-default EOS, and non-default matrix-solver
choices. Each build directory's `config.txt` rejects reuse if other settings
change; use `BUILD_NAME` or `BUILD_DIR` to choose a custom location. See
`Makefile.opt` for the main build options and
[build and test guidance](docs/development/build-and-test.md) for platform
recipes and test targets.

## Standalone Quickstart

Standalone runs read `controls.nml` (`&xnet_controls`) from the working
directory; the v8 positional `control` file is no longer supported. The
default Starkiller Helmholtz EOS also reads `helm_table.dat` from the working
directory.

To run the bundled alpha-network example in a clean temporary directory
without modifying tracked `test/Data_*` files:

```bash
xnet_root=$PWD
run_dir=$(mktemp -d "${TMPDIR:-/tmp}/xnet-standalone.XXXXXX")
cp -R test/Data_alpha "$run_dir/Data_alpha"
cp test/Test_Problems/th_sn1aflame "$run_dir/th_sn1aflame"
cp test/regression/cases/tnsn_alpha/controls.nml "$run_dir/controls.nml"
ln -s "$xnet_root/tools/starkiller-helmholtz/helm_table.dat" "$run_dir/helm_table.dat"
(cd "$run_dir" && "$xnet_root/build/GNU-OPT/bin/xnet")
```

For input fields, layered `include_files`, and migrating v8 `control` files
with `tools/convert_control.py`, see
[runtime configuration](docs/running-xnet.md) and the
[annotated alpha-network example](test/regression/cases/tnsn_alpha/controls.nml).

## Embedding XNet as a Fortran Library

Build the static archive, compiler-specific module files, and exported build
configuration (`xnet-config.mk`):

```bash
make -j libxnet
```

Application code imports `xnet_api` and links using `xnet-config.mk`. See the
[Fortran library API guide](docs/library-api.md) for a complete CPU
quickstart, OpenMP batch threading, GPU device-array burns, custom EOS
integration, NSE queries, and error-handling rules.

## Documentation Map

- **Standalone users:** [runtime configuration](docs/running-xnet.md),
  [v9 release notes](docs/v9-release-notes.md),
  [annotated `controls.nml`](test/regression/cases/tnsn_alpha/controls.nml)
- **Application developers:** [Fortran library API guide](docs/library-api.md),
  [v9 release notes](docs/v9-release-notes.md)
- **Building and testing:** `Makefile.opt`,
  [build and test guidance](docs/development/build-and-test.md)
- **Contributors and maintainers:**
  [architecture overview](docs/development/architecture-overview.md),
  [Fortran formatting guidelines](doc/XNet_Formatting_Guidelines.md),
  [v9 development plan](docs/development/v9-plan.md)

## Scientific Background

Before diving into the source code, we recommend the following introductions
to thermonuclear reaction networks (see [doc/references.md](doc/references.md)
for scientific and solver references):

- W. R. Hix, *"Thermonuclear Reaction Networks for Astrophysics"*,
  http://astro.phys.utk.edu/_media/gallery:networks.pdf
- F. X. Timmes, *"Tools and Toys for Nuclear Astrophysics: Nuclear Reaction
  Network Techniques"*, http://cococubed.asu.edu/talk_pages/jina.shtml
- W. R. Hix & B. S. Meyer (2006), *"Thermonuclear Kinetics in Astrophysics"*,
  http://dx.doi.org/10.1016/j.nuclphysa.2004.10.009
- D. Arnett (1996), *Supernovae and Nucleosynthesis: An Investigation of the
  History of Matter, from the Big Bang to the Present*,
  http://press.princeton.edu/titles/5859.html
