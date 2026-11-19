# XNet v9 migration and release notes

XNet v9 adds a Fortran library interface for applications and replaces the
standalone positional control file with validated namelist configuration.
Standalone evolution, Backward Euler and BDF integration, CPU batch threading,
CUDA/OpenACC and HIP/OpenMP-target execution remain available, subject to the
configuration limits below.

[Issue #132](https://github.com/jaharris87/XNet/issues/132) identifies the current
candidate, checks and remaining release decisions. These notes do not declare
a release or extend support beyond the recorded configurations.

## Standalone input migration

Standalone runs read `controls.nml` with the `&xnet_controls` group. The old
line-oriented `control` input is no longer supported. Ordered includes resolve
relative to the including file; settings are validated after overrides.
Programmatic callers can construct controls without reading a file. Follow
[runtime configuration](development/runtime-configuration.md) for field mapping,
compiled defaults, include rules and migration examples.

## Application calls

Build `libxnet` and link using the exported `xnet-config.mk` settings with a
compatible Fortran compiler. The [API guide](development/embedding.md) gives a
complete CPU example, application-threading and device-array examples, and
controls, units, status and resource references.

| Operation | Procedure |
| --- | --- |
| Load one network and prepare reusable workspace | `xnet_initialize` |
| Evolve an application-supplied constant-density batch | `xnet_burn_batch` |
| Obtain a scalar equilibrium composition | `xnet_nse_composition` |
| Release XNet-owned state | `xnet_finalize` |

The application keeps its species mapping, batch loop, MPI lifetime, EOS data
and energy policy. CPU OpenMP builds let each worker in a fixed, nonnested team
call XNet for its own batch. Configure that team before initialization; join
all calls before finalization. GPU calls are serialized on the selected device.
Applications may supply vendor resources independently; XNet creates missing
required resources and destroys only those it owns.

The library uses dense solves and `MPI_MODE=OFF`; the application may use MPI
and OpenMP elsewhere. One initialized network is supported per process. GPU
library builds use XNet `OPENMP_MODE=OFF`; OpenMP-target GPU builds also require
XNet host OpenMP off for standalone use. Concurrent GPU host entry and general
multi-GPU operation are outside the checked interface.

Callers of earlier development prototypes must rebuild against current module
files and archive. The API guide's
[development-caller migration list](development/embedding.md#updating-a-development-caller)
covers `gpu_context`, four-component zone IDs, `timing%evolve`, EOS procedure
names, prefixed vendor modules and obsolete preprocessing definitions. These
are prototype changes, not compatibility promises for a previously released API.

## Numerical and output changes

- Three-reactant strong screening includes the middle-reactant free-energy
  contribution within the existing screening model
  ([#175](https://github.com/jaharris87/XNet/pull/175)).
- Reported and returned Ye describes the accepted composition, including
  weak-rate evolution, rather than an earlier Newton iterate
  ([#182](https://github.com/jaharris87/XNet/pull/182)). Old reference Ye values
  can therefore disagree even when printed compositions agree.
- A timestep chosen to reach the requested stop retains that selected endpoint.
  Reduced or rejected retries recompute their endpoints. This avoids
  reconstructing the selected endpoint one rounding step short
  ([#209](https://github.com/jaharris87/XNet/pull/209)). It does not redefine the
  energy-rate diagnostic or use a closeness tolerance to end integration.
- CPU workers allocate separate workspace with local batch indices. Complete
  comparisons and their source-specific floating-point differences are
  recorded in [#204](https://github.com/jaharris87/XNet/pull/204). Existing
  references and limits were preserved; not every historical check passes.
- Initial standalone reaction flux is cleared at timestep zero. Library burns
  can write separate history files per call, with diagnostic zone IDs in an
  existing binary-header label. See the
  [API output reference](development/embedding.md#per-call-histories) for file
  naming, record layouts and application responsibilities.

## Checked configurations and remaining limits

The [build guidance](development/build-and-test.md) describes compiler and
provider choices. The [component handoff](https://github.com/jaharris87/XNet/pull/204#issuecomment-7017135890)
records GNU/macOS serial, MPI and CPU OpenMP checks, Perlmutter
NVIDIA/CUDA/OpenACC checks, and Frontier CCE/ROCm/OpenMP-target checks at their
named source and input configurations. Build success, execution, numerical
comparisons and maintainer decisions are recorded separately. These results
do not imply other compiler versions, GPU generations or arbitrary combinations.

Perlmutter NVIDIA/LibSci host OpenMP runs use `OMP_STACKSIZE=16M` in the tested
configuration. Record the initial process-stack limit separately; this is not
a GPU device-stack setting, a measured universal minimum or a new default.
Follow the [stack guidance](development/build-and-test.md#perlmutter-nvidia-cpu-openmp-stack-workaround).

Check every returned status. An exhausted burn requires application shutdown
after its worker team joins; its result arrays are not a recoverable checkpoint.
Some EOS, allocation, malformed-data, singular-solve and NSE convergence
failures still terminate inside XNet. Library incident-neutrino histories and
sparse solves are outside the current interface. See the
[status reference](development/embedding.md#status-and-shutdown).

[Application integration #130](https://github.com/jaharris87/XNet/issues/130)
records CHIMERA/Flash-X checks, native thermodynamics, energy policy and resource
ownership. CHIMERA targets SFHo tabulated EOS; its deprecated non-tabular EOS
integration is outside v9 scope. Public library GPU success alone does not
establish application GPU execution. Historical facility failures, compiler
warnings and numerical disagreements keep their individual records; later
success does not diagnose earlier failures or prove conservation.

The [Stage B measurements](https://github.com/jaharris87/XNet/issues/131) report
selected resulting-source and application costs without a required speedup.
Nested host timers are not additive or isolated kernel costs. Accepted Stage A
measurements remain unchanged. Species reordering, GPU sparse work and fTimer
adoption are follow-ups after v9.0, as recorded in the
[development plan](development/v9-plan.md).
