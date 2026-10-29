# Fortran embedding

Build the archive and compiler-specific module files with:

```sh
make BUILD_NAME=embedding -j libxnet
```

The archive is `build/embedding/lib/libxnet.a`; modules are in
`build/embedding/mod`. The generated `build/embedding/xnet-config.mk`
records the compiler, module path, compile/link flags, archive, and required
external libraries. Use the same compiler and compatible precision/runtime
options for the application. The external example under `test/library/`
links through these outputs without compiling XNet sources.

The supported initial configuration is a dense serial CPU build with MPI,
OpenMP, and GPU modes off. Other builds retain their standalone programs;
the embedding procedures return `xnet_unsupported`. This does not qualify
CHIMERA/Flash-X adapters, host EOS providers, or caller-owned GPU resources.

## Application thermodynamics adapters

Applications that already initialize their own EOS may supply a small
`xnet_thermo` module when building the library. XNet keeps its composition
moments, screening, scalar/vector masks, scratch, and internal-unit
conversions in `source/xnet_eos.F90`:

```sh
make BUILD_NAME=application-eos -j libxnet \
  EOS=EXTERNAL EOS_SOURCE=/path/to/XNet_API/xnet_thermo_chimera.F90 \
  EOS_MODULE_DIR=/path/to/host/modules
```

Build the host EOS modules first, using the same compiler and compatible
precision options. `EOS_SOURCE` names one free-form Fortran source containing
the application thermodynamics adapter. `EOS_MODULE_DIR` is optional if the
adapter needs no additional module directory. Keep host modules in a separate
directory from this XNet build's modules. XNet's current module directory is
searched before the host directory, so older XNet modules in an application
build do not replace the current ones. Host `*.mod` files in that directory
are ordinary adapter prerequisites; rebuilding a host interface at the same
path recompiles the adapter.

The module supplies three procedures, using `dp` from `xnet_types`:

```fortran
Subroutine thermo_initialize(nspecies,names,a,z)
  Integer, Intent(in) :: nspecies
  Character(*), Intent(in) :: names(nspecies)
  Real(dp), Intent(in) :: a(nspecies), z(nspecies)
End Subroutine

Subroutine thermo_evaluate(nspecies,temp,rho,ye,abar,zbar,y,xext,aext,zext,cv,eta,detadt)
  Integer, Intent(in) :: nspecies
  Real(dp), Intent(in) :: temp, rho, ye, abar, zbar, y(nspecies), xext, aext, zext
  Real(dp), Intent(out) :: cv, eta, detadt
End Subroutine

Subroutine thermo_finalize
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

Return `cv` in erg/g/K, dimensionless electron degeneracy `eta`, and
`detadt` in K^-1 at fixed density and composition. XNet retains its current
conversion to MeV/nucleon/GK and GK^-1, and calls thermodynamics only when
heating or screening needs it. The adapter imports no mutable XNet working
arrays and exposes no host derived types. The bundled adapter in
`source/xnet_eos_starkiller.F90` demonstrates the procedure signatures;
an application supplies its own calls and ownership hooks.

The host initializes its EOS before `xnet_initialize`. The application's
initialization hook may prepare species mapping and its finalization hook
releases only adapter-owned storage; neither reinitializes or destroys host
tables, MPI, or accelerator state. XNet allocates and releases its own EOS
scratch. The application links its own EOS objects and dependencies alongside
`libxnet.a`. These dependencies are not bundled into the XNet archive or
discovered automatically. Module includes are recorded in `xnet-config.mk`.

`EOS=EXTERNAL` builds `libxnet` and the EOS-independent `net_setup` utility,
not standalone `xnet` or `xnse`. The initial embedding support remains dense
serial CPU only. Supplying a thermodynamics module does not by itself validate
a full CHIMERA/Flash-X adapter or enable threaded/accelerator embedding. The
default adapter retains XNet's device-routine directives. Application adapters
need their own device implementation and tests before accelerator embedding
can be claimed.

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
Call xnet_burn_batch(dt_s,active,zone_id,density,temperature,ye,mass_fraction, &
  & restart_dt_s,neutrino_loss,counters,timing,ierr,message,aux_x,aux_a,aux_z)
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

## Status and remaining limits

`xnet_success=0`, `xnet_invalid=1`, `xnet_lifecycle_error=2`, and
`xnet_unsupported=3` describe the checked public paths. Validate configuration,
dimensions, finite active inputs and lifecycle order before a burn. Calls
rejected by validation preserve in/out physical state and return zero loss/counters.
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

Finalization releases CPU allocations owned by XNet and calls the selected
thermodynamics adapter's finalizer. Built-in standalone providers release their
own EOS storage; an application-supplied adapter leaves host-owned EOS state intact.
The API never initializes/finalizes MPI or a GPU runtime.
MPI, OpenMP, and caller-owned GPU embedding remain unqualified.

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
settings apply. Calls share the same single-instance, non-reentrant CPU
lifetime as burns; no additional initialization or EOS table loading occurs.

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
