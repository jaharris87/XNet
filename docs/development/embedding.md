# Fortran embedding

Build the archive and compiler-specific module files with:

```sh
make BUILD_NAME=embedding -j libxnet
```

The archive is `build/embedding/lib/libxnet.a`; modules are in
`build/embedding/mod`. The generated `build/embedding/xnet-config.mk`
records the compiler, module path, compile/link flags, archive, and required
external libraries. `XNET_CPPFLAGS` supplies the XNet header directory and the
selected build definitions for callers that preprocess `xnet_macros.fh`.
Use the same compiler and compatible precision/runtime options for the
application. The external example under `test/library/`
links through these outputs without compiling XNet sources.

Embedding requires `MATRIX_SOLVER=dense`, `MPI_MODE=OFF`, and
`OPENMP_MODE=OFF`. The CPU configuration has `GPU_MODE=OFF`. GPU builds may
select CUDA/cuBLAS or HIP/ROCm with exactly one of OpenACC and OpenMP target
offload enabled. Other library configurations return `xnet_unsupported`;
standalone build selections are unchanged. Calls use one host thread and one
non-reentrant library instance. When host OpenMP is enabled by the offload
compiler, `omp_get_max_threads()` must be one; set `OMP_NUM_THREADS=1` before
starting the application.

The serial CPU library tests exercise the public API. The GPU caller also
passed its five alpha/SN160 BE/BDF cases on Frontier with CCE 20.0.0,
ROCm/hipfort 6.4.2 and OpenMP target offload, and on Perlmutter with
NVFORTRAN 26.5, CUDA 13.2 and OpenACC. These checks use the bundled Starkiller
EOS, dense solves, one device and one host thread. They cover owned/borrowed
resources, host/device arrays, repeated and masked calls, and device
continuation without reloading the arrays. See the [GPU test description](../../test/library/README.md#gpu-consumer)
and [results and limitations](https://github.com/jaharris87/XNet/pull/164#issuecomment-6511841908).
They do not validate an application EOS or a complete CHIMERA/Flash-X GPU
integration, and do not establish performance or general backend support.

## Application thermodynamics adapters

Applications with their own EOS may supply a small
`xnet_eos_interface` module when building the library. XNet keeps its composition
moments, screening, scalar/vector masks, scratch, and internal-unit
conversions in `source/xnet_eos.F90`:

```sh
make BUILD_NAME=application-eos -j libxnet \
  EOS=EXTERNAL EOS_SOURCE=/path/to/XNet_API/xnet_eos_chimera.F90 \
  EOS_MODULE_DIR=/path/to/host/modules
```

Build the host EOS modules first, using the same compiler and compatible
precision options. `EOS_SOURCE` names one free-form Fortran source containing
the application thermodynamics adapter. Its filename must not use the stem
`xnet_eos`, which is reserved for XNet's common EOS module; use a name such as
`xnet_eos_chimera.F90` or `xnet_eos_interface.F90`. `EOS_MODULE_DIR` is optional
if the adapter needs no additional module directory. Keep host modules in a separate
directory from this XNet build's modules. XNet's current module directory is
searched before the host directory, so older XNet modules in an application
build do not replace the current ones. Host `*.mod` files in that directory
are ordinary adapter prerequisites; rebuilding a host interface at the same
path recompiles the adapter.

The module supplies three procedures, using `dp` from `xnet_types`:

```fortran
Subroutine xnet_eos_interface_initialize(nspecies,names,a,z)
  Integer, Intent(in) :: nspecies
  Character(*), Intent(in) :: names(nspecies)
  Real(dp), Intent(in) :: a(nspecies), z(nspecies)
End Subroutine

Subroutine xnet_eos_interface_evaluate(nspecies,temp,rho,ye,abar,zbar,y,xext,aext,zext,cv,eta,detadt)
  Integer, Intent(in) :: nspecies
  Real(dp), Intent(in) :: temp, rho, ye, abar, zbar, y(nspecies), xext, aext, zext
  Real(dp), Intent(out) :: cv, eta, detadt
End Subroutine

Subroutine xnet_eos_interface_finalize
End Subroutine
```

Initialization receives the species names and mass/charge numbers once, in
network order. The adapter may copy the metadata it needs for application
species mapping; it keeps no association with XNet arrays. Thermodynamics
receives temperature in K, density in g/cm^3, dimensionless Ye and number
averages Abar/Zbar, and raw molar abundances `Y=X/A` in network order. XNet
does not normalize this composition. An adapter such as Flash-X must map the
full species composition and form its mass fractions from `X=A*Y`, rather
than substituting only the moments.

`xext`, `aext`, and `zext` describe the auxiliary mass reservoir as for the
batch API. The supplied moments already include it. An EOS that uses moments
can use those values directly; an adapter that requires individual species
must handle the reservoir deliberately or report it as unsupported. The
current Flash-X composition mapping has no auxiliary species; this interface
does not silently add one.

Return `cv` in erg/g/K and `eta = mu_kinetic / (k_B T)`, where the electron
chemical potential excludes electron rest mass. This is the existing
[Helmholtz convention](https://cococubed.com/code_pages/chemical_potential.shtml).
Return `detadt = d(eta)/dT` in K^-1 at fixed density and composition, using
that same rest-mass-excluded convention. XNet retains its current
conversion to MeV/nucleon/GK and GK^-1, and calls thermodynamics only when
heating or screening needs it. The adapter imports no mutable XNet working
arrays and exposes no host derived types. The bundled adapter in
`source/xnet_eos_starkiller.F90` demonstrates the procedure signatures;
an application supplies its own calls and ownership hooks.

The host must prepare its EOS data before the adapter first uses them. If
`xnet_eos_interface_initialize` reads host EOS data, those data must be ready before
`xnet_initialize`. If the hook only prepares species mapping or other
table-independent storage, the host may load its tables afterward, but before
the first burn or NSE query. This permits CHIMERA's existing order: load
network metadata, initialize the host EOS, then evaluate NSE and burn.

The adapter's initialization and finalization hooks manage only adapter-owned
mapping or storage; neither reinitializes or destroys host tables, MPI, or
accelerator state. XNet allocates and releases its own EOS scratch. The
application links its own EOS objects and dependencies alongside
`libxnet.a`. These dependencies are not bundled into the XNet archive or
discovered automatically. Module includes are recorded in `xnet-config.mk`.

`EOS=EXTERNAL` builds `libxnet` and the EOS-independent `net_setup` utility,
not standalone `xnet` or `xnse`. GPU burns require
`xnet_eos_interface_evaluate` and every routine it calls to be callable on the
selected device. The bundled interface retains XNet's device-routine
directives; an application interface must provide its own device procedures
and prepare any device tables before their first use. Its scalar host
procedures must also remain available for NSE queries. Supplying this module
does not by itself validate the application integration.

## Initialize, burn and finalize

```fortran
Use xnet_api, Only: dp, xnet_controls_t, set_xnet_controls_defaults, &
  & xnet_network_t, xnet_timing_t, xnet_initialize, xnet_burn_batch, xnet_finalize

Call set_xnet_controls_defaults(controls)
controls%data_dir = 'prepared_network'
controls%nzbatchmx = 16
controls%idiag = -2
Call xnet_initialize(controls,network,ierr,message)
! Check ierr before using network or burning.
! Host scientific arrays are current; data_on_device may be omitted or false.
Call xnet_burn_batch(dt_s,active,zone_id,density,temperature,ye,mass_fraction, &
  & restart_dt_s,neutrino_loss,counters,timing,ierr,message,aux_x,aux_a,aux_z,max_steps_taken)
! Check ierr. A numerical failure requires the host's fatal/MPI shutdown, not another burn.
Call xnet_finalize(ierr,message)
```

Declare `controls`, `network`, and `timing` using the corresponding types;
the other arguments are ordinary caller-owned arrays. The library owns one
instance. Calls do not overlap or recurse. Initialize once, burn any number
of batches, and finalize once; finalization is also safe when already
finalized. The library keeps no association with caller arrays.

Use preprocessed network files (`iprocess=0`), produced separately by
`net_setup` when necessary. The constant-condition API has no incident
neutrino histories (`ineutrino=0`) or timestep output files (`itsout<=0`).
Diagnostic output, if requested, goes to the existing standard-output unit.
The compiled default controls need no standalone trajectory/abundance
filenames. The selected EOS can require additional inputs; the default
Starkiller provider reads `helm_table.dat` from the working directory.

On successful initialization, `network` contains copied names, integer A/Z,
binding energies, and mass excesses from the selected network. Both energy
arrays use the MeV values in `nuclear_data`. The caller owns this metadata;
it remains usable after finalization. Failed initialization does not produce
usable metadata.

## GPU resources and array location

The application selects its device in both the vendor runtime and the
directive runtime before initialization. XNet checks that those selections
agree and leaves the selected device unchanged. Keep that device selected
through finalization.

The optional final `gpu_resources` argument to `xnet_initialize` has type
`xnet_gpu_resources_t`, exported by `xnet_api`. Its `device` and `queue`
fields are integers; `stream` and `blas_handle` are `C_PTR` vendor resources.
For example, after the application creates and associates its stream and
cuBLAS or hipBLAS handle:

```fortran
Use xnet_api, Only: xnet_gpu_resources_t
Type(xnet_gpu_resources_t) :: gpu_resources

gpu_resources%device = host_device
gpu_resources%stream = host_stream
gpu_resources%blas_handle = host_blas_handle
gpu_resources%queue = host_queue
Call xnet_initialize(controls,network,ierr,message,gpu_resources=gpu_resources)
```

Its device must match the current application device and its BLAS handle
must already use the supplied stream. For OpenACC, `queue` must already
identify that same stream.
XNet borrows these resources, preserves their associations, and does not
replace or destroy them. It does not create or change the application's
OpenACC queue association.

When `gpu_resources` is omitted in a GPU build, XNet creates its own BLAS
handle on the current device. OpenACC uses the runtime's stream for queue
one; OpenMP offload uses a stream created by XNet. Finalization destroys only
the resources XNet created. Supplying GPU resources to a CPU build returns
`xnet_unsupported`.

The optional final logical `data_on_device` argument to `xnet_burn_batch`
selects the location of the scientific arrays. Omitted or false means their
host values are current. This mode retains host array-section support and
returns host results, including when caller device mappings contain older
values. It neither reads nor refreshes those caller device mirrors.

True means density, temperature, Ye, mass fractions, restart hints, optional
auxiliary arrays, and neutrino loss are ordinary contiguous arrays already
mapped on the selected device. XNet checks their mappings, validates active
values on the device, and prepares and extracts scientific values there.
The host copies may be stale. Raw device pointers and noncontiguous device
sections are not accepted. Existing caller mappings survive the call.

```fortran
! The application has mapped these scientific arrays and made their device values current.
Call xnet_burn_batch(dt_s,active,zone_id,density,temperature,ye,mass_fraction, &
  & restart_dt_s,neutrino_loss,counters,timing,ierr,message,aux_x,aux_a,aux_z, &
  & max_steps_taken,data_on_device=.true.)
! Scientific results are ready on the device; counters, status and timing are ready on the host.
```

`active`, `zone_id`, `counters`, `ierr`, `message`, `timing`, and
`max_steps_taken` always remain host arguments; `dt_s` is a host scalar.
Both modes complete their work before returning. Device mode does not copy
scientific results through host arrays; requested diagnostics may copy
internal state for printing. The application orders its preceding work on
the supplied stream or completes it before calling XNet. CPU builds reject
`data_on_device=.true.`.

OpenACC uses the supplied queue's stream ordering. Before a device-array burn,
the OpenMP path waits for the supplied vendor stream, since OpenMP target work
does not use that stream. A synchronization failure returns `xnet_invalid`
with the runtime status in `message`, before reading scientific inputs.

Call `xnet_finalize` before destroying the application's GPU resources or
EOS data. It releases XNet's device mappings before their CPU allocations
and restores the resource slots used by the library. It does not initialize
or finalize application MPI, reset the selected device, or finalize the GPU
runtime.

## Batch arguments

The duration `dt_s` is a positive scalar in seconds. Density is fixed in
g/cm^3. Temperature is in/out K; it evolves when `iheat>0`. `ye` is in/out,
following the existing composition/EOS calculation. This path supplies two
identical thermodynamic endpoints internally and has no absolute time origin.

`active(:)` defines the submitted lane count, at most `nzbatchmx`.
Thermodynamic, restart, and neutrino-loss arrays have that length.
`mass_fraction(species,lane)` follows XNet species order and contains
dimensionless mass fractions. The result is raw: the API does not normalize
or reorder composition or compute application nuclear-energy release.
Applications retain those operations and their EOS/energy policy.

`zone_id(:,lane)` has three or four integer components for diagnostics.
On numerical failure, `message` identifies the submitted one-based zone and
all of its supplied ID components. Standalone failure filenames still use
the first three components; embedded numerical failures do not write those files.
Short batches and inactive holes are supported. Inactive lanes preserve
temperature, Ye, composition and restart hint, and return zero loss/counters.
Scientific values in inactive lanes are not read. An all-inactive batch
performs no burn.

Optional `aux_x(:)`, `aux_a(:)`, `aux_z(:)` must be supplied together.
They describe a fixed auxiliary mass reservoir, its mass number and charge;
it contributes to existing composition/EOS moments without becoming an
evolved network species. Positive auxiliary mass requires positive A and
`0<=Z<=A`. Zero auxiliary mass is treated as no reservoir.

`restart_dt_s(:)` is nonnegative and in/out. Zero requests fresh startup.
Positive input preserves the existing CHIMERA hint convention: the current
startup uses half the hint as an initial-step floor, rather than imposing
that timestep. Output is existing `tdel_old`, the preceding/penultimate
internal timestep; it can be zero after a single step. It is not a next-step
recommendation. The CHIMERA adapter currently supplies zero for BDF.

`neutrino_loss(:)` returns the integrated XNet weak-reaction loss in erg/g.
It is distinct from incident-neutrino capture and application neutrino-loss
corrections. `counters(5,lane)` returns the existing TS, NR, Jacobian,
derivative, and rate counters. `timing` returns per-batch elapsed, solve,
Jacobian, derivative, rate, and screening seconds; applications accumulate
their own totals.

Optional integer `max_steps_taken` returns the existing `full_net` `kstep`:
the maximum accepted outer integration steps taken by an active lane in the
batch. It is zero for an all-inactive batch or any non-success return. This
differs from `counters(1,:)`, which includes internal timestep retries. Flash-X
uses the accepted step count for `MTSB_VAR` and `Grid_setWork` work estimates.
Existing calls may omit `max_steps_taken` and `data_on_device`.

## Status and remaining limits

`xnet_success=0`, `xnet_invalid=1`, `xnet_lifecycle_error=2`, and
`xnet_unsupported=3` describe the checked public paths. Validate configuration,
dimensions, finite active inputs and lifecycle order before a burn. Calls
rejected by host-input validation preserve in/out physical state and return
zero loss/counters. Device-input validation does the same in device memory
when the required contiguous mappings are present. A missing mapping,
noncontiguous device descriptor, or changed device can prevent scientific
output initialization; use only the returned host status and diagnostics for
those rejected requests.

No automatic renormalization or repair is performed.

`xnet_lifecycle_error` means that XNet is already initialized when initialization
is requested, or that a burn or NSE query is requested before initialization
or after finalization. It describes call order, not a numerical failure. Calling
`xnet_finalize` again after finalization is allowed and returns success.

Numerical burn failure is fatal to the simulation, but returns to the embedded
caller for host-controlled shutdown. `xnet_integrator_failure=4` reports a
BE/BDF convergence or timestep failure after the integrator's internal retry
logic. BDF's existing failure flag does not retain its detailed reason; this
status does not assert that every failure used the maximum number of attempts.
`xnet_step_limit=5` reports an active zone still short of the requested stop
time after `kstmx` integration steps. `message` reports the first affected
active zone and its caller-supplied IDs. Use a sufficiently long message
buffer (512 characters accommodates the current message).

After numerical failure, only `ierr`, `message`, attempted `counters` and
per-call `timing` are diagnostic results. No physical result is valid for the
batch. The host must log its context and terminate; do not retry, continue
successful lanes, or reuse the failed library instance. XNet keeps its
internal adaptive retries unchanged. The reporting path closes the elapsed
timer and skips successful final output and standalone failure-file writes.
Standalone calls keep their existing termination and failure-output behavior.

This is not general error recovery. Malformed-network readers, EOS/provider
failures, allocation failures, singular linear solves and arbitrary nonfinite
arithmetic are not covered by these numerical status values and may still
terminate execution. Future fallback to another integration method is
separate work, not a promise that a failed library instance can be reused.

Finalization releases allocations and mappings owned by XNet and calls the
selected thermodynamics interface's finalizer. Built-in standalone providers
release their own EOS storage; an application interface leaves host-owned EOS
state intact.
The API does not initialize/finalize application MPI or reset the application's
GPU runtime. MPI-enabled and host-threaded library builds remain unsupported.
The library GPU checks do not establish application MPI/GPU integration or
performance; those require their own validation.

## NSE composition

After initialization, applications may also calculate one NSE composition:

```fortran
Use xnet_api, Only: xnet_nse_composition
! Allocate nse_fraction with one entry per species in network%names.
Call xnet_nse_composition(density,temperature,ye,nse_fraction,ierr,message)
```

Density is a scalar in g/cm^3, temperature is in K, and Ye is dimensionless.
Density and temperature must be finite and positive; Ye must be finite and
between zero and one. The initialized network and its existing screening
settings apply. These scalar host calls share the same single-instance,
non-reentrant lifetime as burns, including in a GPU library build. Their
arguments and copied results are host values; they have no device-residency
flag. No additional initialization or EOS table loading occurs.

The result is a copied vector `A*ynse` in XNet species order, matching the
mass-number-weighted abundances used by CHIMERA's existing NSE wrapper. It is
not the solver's nuclear-mass-weighted `xnse`. XNet does not normalize or
reorder this vector, add an auxiliary reservoir, or compute application energy
changes. Those operations remain with the application. A later query does
not change an earlier copied result or the caller's burn arrays.

Invalid inputs or a result vector of the wrong length return `xnet_invalid`;
calls outside the initialized lifetime return `xnet_lifecycle_error`.
Rejected calls zero the result vector. The existing `nse_solve` algorithm,
screening choices and convergence tolerances are unchanged. A solver failure
still terminates through its existing fatal path; unlike the reported burn
failures above, it does not return an NSE-failure status or permit retry.
