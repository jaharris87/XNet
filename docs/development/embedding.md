# Fortran library API

The `xnet_api` module initializes one reaction network, evolves batches at
constant density, returns scalar NSE compositions, and releases XNet-owned
storage. The application owns its species mapping, batch loop, physical
arrays, EOS and energy policy, MPI lifetime, and accelerator placement.

The library uses the dense matrix solver with `MPI_MODE=OFF`. CPU builds
allow serial calls or a fixed application OpenMP team. GPU builds use
serialized host calls, CUDA/cuBLAS or HIP/ROCm, and one accelerator directive
model. See [build and test](build-and-test.md) for configuration rules and
[library tests](../../test/library/README.md) for reproducible checks.

**Check every returned status.** Burn statuses `xnet_integrator_failure` and
`xnet_step_limit` require application shutdown after any worker team joins;
no physical result from that batch is valid. Some failures, including EOS,
allocation, malformed-data, singular-solve and NSE convergence failures,
still terminate inside XNet. The [status reference](#status-and-shutdown)
describes the limits of checked errors.

| Application operation | Public entry point | Caller responsibility |
| --- | --- | --- |
| Load a network once | `xnet_initialize` | Set control defaults and overrides; configure the CPU team or select the GPU before calling. |
| Evolve one batch | `xnet_burn_batch` | Supply mass-fraction rows matching `network%names`, check status, and apply the application's energy policy. |
| Query equilibrium | `xnet_nse_composition` | Supply density, temperature and Ye; returned entry `i` corresponds to `network%names(i)`. |
| Release the instance | `xnet_finalize` | Join outstanding calls first; retry if GPU cleanup reports failure. |

## CPU quickstart

Build from the repository root:

```sh
make BUILD_NAME=library-cpu MPI_MODE=OFF OPENMP_MODE=OFF GPU_MODE=OFF \
  MATRIX_SOLVER=dense EOS=STARKILLER -j libxnet
```

This creates `build/library-cpu/lib/libxnet.a`, compiler-specific module files
under `build/library-cpu/mod/`, and `build/library-cpu/xnet-config.mk`.
Use the exported compiler, flags and libraries for the caller. Fortran module
files require the same compiler and compatible precision and runtime options.

The example below preprocesses a private copy of the bundled alpha-network
ASCII inputs. From the same repository root, create its working directory:

```sh
xnet_root=$PWD
run_dir=$(mktemp -d "${TMPDIR:-/tmp}/xnet-library-cpu.XXXXXX")
mkdir "$run_dir/network"
for input in sunet netwinv netsu netweak; do
  cp "$xnet_root/test/Data_alpha/$input" "$run_dir/network/$input"
done
ln -s "$xnet_root/tools/starkiller-helmholtz/helm_table.dat" "$run_dir/helm_table.dat"
cd "$run_dir"
```

The Starkiller EOS reads `helm_table.dat` from the process working directory.
The program sets `iprocess=1`, which writes generated network files into its
owned `network/` directory. Do not point runtime preprocessing at a shared or
tracked input directory. This example neither reads `controls.nml` nor needs
standalone abundance or trajectory files.

Save the following as `quickstart.f90` in that new working directory:

```fortran
Program quickstart
  Use, Intrinsic :: iso_fortran_env, Only: error_unit, output_unit
  Use xnet_api, Only: dp, xnet_controls_t, xnet_network_t, xnet_timing_t, &
    & set_xnet_controls_defaults, xnet_initialize, xnet_burn_batch, xnet_finalize, xnet_success
  Implicit None

  Integer, Parameter :: nzones = 1, message_length = 512
  Type(xnet_controls_t) :: controls
  Type(xnet_network_t) :: network
  Type(xnet_timing_t) :: timing
  Logical :: active(nzones)
  Integer :: zone_id(4,nzones), counters(5,nzones)
  Integer :: ierr, max_steps_taken, nspecies, i, ic12, io16
  Character(message_length) :: message
  Real(dp) :: density(nzones), temperature(nzones), ye(nzones)
  Real(dp) :: restart_dt_s(nzones), neutrino_loss(nzones)
  Real(dp), Allocatable :: mass_fraction(:,:)

  Call set_xnet_controls_defaults(controls=controls)
  controls%data_dir = 'network'
  controls%iprocess = 1
  controls%nzbatchmx = nzones
  controls%idiag = -2
  Call xnet_initialize(controls=controls,network=network,ierr=ierr,message=message)
  Call check_status(operation='initialize',status=ierr,detail=message)

  nspecies = size(network%names)
  Allocate(mass_fraction(nspecies,nzones))
  ic12 = 0
  io16 = 0
  Do i = 1, nspecies
    If ( trim(adjustl(network%names(i))) == 'c12' ) ic12 = i
    If ( trim(adjustl(network%names(i))) == 'o16' ) io16 = i
  EndDo
  If ( ic12 == 0 .or. io16 == 0 ) Then
    Write(error_unit,'(a)') 'Example requires c12 and o16'
    Stop 1
  EndIf

  active = .true.
  zone_id(:,1) = [1,1,1,0]
  density = 1.0e7_dp
  temperature = 1.7e9_dp
  ye = 0.5_dp
  mass_fraction = 0.0_dp
  mass_fraction(ic12,:) = 0.5_dp
  mass_fraction(io16,:) = 0.5_dp
  restart_dt_s = 0.0_dp

  Call xnet_burn_batch(dt_s=0.1_dp,active=active,zone_id=zone_id,density=density, &
    & temperature=temperature,ye=ye,mass_fraction=mass_fraction,restart_dt_s=restart_dt_s, &
    & neutrino_loss=neutrino_loss,counters=counters,timing=timing,ierr=ierr,message=message, &
    & max_steps_taken=max_steps_taken)
  Call check_status(operation='burn',status=ierr,detail=message)
  Write(output_unit,'(a,es13.5,a,i0)') 'evolve seconds: ',timing%evolve, &
    & '; accepted outer steps: ',max_steps_taken
  Write(output_unit,'(a,es13.5)') 'returned Ye: ',ye(1)

  Call xnet_finalize(ierr=ierr,message=message)
  Call check_status(operation='finalize',status=ierr,detail=message)
  Deallocate(mass_fraction)

Contains

  Subroutine check_status(operation,status,detail)
    Implicit None
    Character(*), Intent(in) :: operation, detail
    Integer, Intent(in) :: status

    If ( status /= xnet_success ) Then
      Write(error_unit,'(a,a,a,i0,2a)') 'XNet ',operation,': status ',status,': ',trim(detail)
      Stop 1
    EndIf
    Return
  End Subroutine check_status

End Program quickstart
```

Save this `Makefile` beside it. Recipe lines begin with a tab:

```make
XNET_CONFIG ?= /path/to/XNet/build/library-cpu/xnet-config.mk
include $(XNET_CONFIG)

quickstart: quickstart.o $(XNET_ARCHIVE)
	$(XNET_LDR) $(XNET_LDFLAGS) -o $@ quickstart.o $(XNET_ARCHIVE) $(XNET_LIBS)

quickstart.o: quickstart.f90 $(XNET_CONFIG)
	$(XNET_FC) $(XNET_FFLAGS) $(XNET_MODFLAGS) -c $< -o $@
```

Build and run in the staged working directory:

```sh
make XNET_CONFIG="$xnet_root/build/library-cpu/xnet-config.mk"
./quickstart
```

`set_xnet_controls_defaults` must precede overrides: the bare
`xnet_controls_t()` constructor contains intentionally invalid values and
unallocated arrays. After setting defaults, a nonblank `data_dir` is the only
additional control required for initialization. Choose `nzbatchmx` to hold
the largest submitted zone count per worker, including inactive holes. Leave
`szone=nzone=1` for this use: their common validation still requires
`nzone>=1` and `1<=szone<=nzone`, but they do not select API zones or zone IDs.

For later runs, `iprocess=0` loads the prepared network. Initialization checks
for readable `sunet`, `netwinv`, `nets3`, `nets4` and `match_data`; the
network's rate selection may require further data read by existing readers.
With `iprocess>0`, it first checks `sunet`, `netwinv` and `netsu`, then runs
the existing preprocessor. In a multi-rank application, preprocess once
before other ranks load it, or give each rank an owned directory. The library
does not coordinate preprocessing through MPI.

## Choosing an execution model

| Library build | Application calls |
| --- | --- |
| [CPU, `OPENMP_MODE=OFF`](#cpu-quickstart) | Serialize all XNet calls. The application may use OpenMP elsewhere. |
| [CPU, `OPENMP_MODE=ON`](#cpu-openmp-batches) | Each worker in one fixed application team calls XNet for its own batch. Configure the team before initialization, as below. |
| [GPU, `OPENMP_MODE=OFF`](#mapped-gpu-batch) | Serialize host calls and keep the selected device. Choose host or mapped scientific arrays per call. Application OpenMP remains independent. |

Initialize and finalize with no calls in flight. The following examples keep
the application batch loop and scientific-array storage in the application.
Detailed argument, controls, status and ownership rules follow as reference.

## CPU OpenMP batches

Build a separate CPU library configuration:

```sh
make BUILD_NAME=library-openmp MPI_MODE=OFF OPENMP_MODE=ON GPU_MODE=OFF \
  MATRIX_SOLVER=dense EOS=STARKILLER -j libxnet
```

The application keeps the batch loop. Each worker may call a burn or an NSE
query with its own input/output storage, one call at a time. Initialize and
finalize on the initial thread outside application parallel regions.

Set the intended default team size **before initialization**, for example
with `OMP_NUM_THREADS=4 OMP_DYNAMIC=FALSE`, or with
`omp_set_dynamic(.false.)` and `omp_set_num_threads(4)` on the initializing
thread. XNet enters its own parallel regions during initialization and records
the actual team size. A `num_threads(4)` clause on a later application loop
alone does not configure those initialization regions. Preserve those default
settings through finalization, which also enters internal parallel regions.
XNet does not change the application's OpenMP settings.

For Perlmutter NVIDIA/LibSci CPU OpenMP runs, also set this before starting
the application:

```sh
export OMP_STACKSIZE=16M
```

See the [tested stack workaround](build-and-test.md#perlmutter-nvidia-cpu-openmp-stack-workaround)
for its compiler/library configuration, separate process-stack limit and
current-candidate validation limits.

Each fixed-team worker allocates its own plain workspace arrays with local
lanes `1:nzbatchmx`, using conditional OpenMP `THREADPRIVATE` ownership. Each
existing owner allocates and frees its worker scratch inside internal parallel
regions, including workers that receive no application batch. Shared network
tables and external EOS initialization remain once per rank. Memory follows
`nthread*nzbatchmx` total lane capacity even when calls are short or masked;
storage is reused across logical application batches. With eight-byte `dp`,
the two dense matrices alone occupy
approximately `16*msize**2*nthread*nzbatchmx` bytes, where `msize` is `ny` or
`ny+1` with self-heating, before other solver and physics arrays.

The following application routine submits already prepared batches and stores
one status per batch. It joins the parallel loop before deciding whether to
terminate. Compile it and its caller using the OpenMP library's exported
settings, and configure the team before `xnet_initialize` as above:

```fortran
Subroutine burn_application_batches(dt_s,active,zone_id,density,temperature,ye, &
  & mass_fraction,restart_dt_s,neutrino_loss,counters,timings,statuses,messages)
  Use, Intrinsic :: iso_fortran_env, Only: error_unit
  Use xnet_api, Only: dp, xnet_timing_t, xnet_burn_batch, xnet_success
  Implicit None
  Real(dp), Intent(in) :: dt_s, density(:,:)
  Logical, Intent(in) :: active(:,:)
  Integer, Intent(in) :: zone_id(:,:,:)
  Real(dp), Intent(inout) :: temperature(:,:), ye(:,:), mass_fraction(:,:,:), restart_dt_s(:,:)
  Real(dp), Intent(out) :: neutrino_loss(:,:)
  Integer, Intent(out) :: counters(:,:,:), statuses(:)
  Type(xnet_timing_t), Intent(out) :: timings(:)
  Character(*), Intent(out) :: messages(:)
  Integer, Parameter :: not_submitted = -1
  Integer :: ibatch, failed, stop_requested

  failed = 0
  statuses = not_submitted
  messages = 'Not submitted after an earlier batch error'
  ! Last dimension identifies a batch; each iteration owns its output slices.
  !$omp parallel do default(shared) private(ibatch,stop_requested) schedule(static)
  Do ibatch = 1, size(active,2)
    !$omp atomic read
    stop_requested = failed
    If ( stop_requested /= 0 ) Cycle
    Call xnet_burn_batch(dt_s=dt_s,active=active(:,ibatch),zone_id=zone_id(:,:,ibatch), &
      & density=density(:,ibatch),temperature=temperature(:,ibatch),ye=ye(:,ibatch), &
      & mass_fraction=mass_fraction(:,:,ibatch),restart_dt_s=restart_dt_s(:,ibatch), &
      & neutrino_loss=neutrino_loss(:,ibatch),counters=counters(:,:,ibatch), &
      & timing=timings(ibatch),ierr=statuses(ibatch),message=messages(ibatch))
    If ( statuses(ibatch) /= xnet_success ) Then
      !$omp atomic write
      failed = 1
    EndIf
  EndDo
  !$omp end parallel do

  If ( failed /= 0 ) Then
    Do ibatch = 1, size(statuses)
      If ( statuses(ibatch) /= xnet_success ) Then
        Write(error_unit,'(a,i0,a,i0,2a)') 'Batch ',ibatch,': XNet status ', &
          & statuses(ibatch),': ',trim(messages(ibatch))
      EndIf
    EndDo
    ! A multiphysics application invokes its fatal/MPI shutdown here.
    Stop 1
  EndIf
  Return
End Subroutine burn_application_batches
```

The routine needs an explicit interface in its caller, normally by placing it
in an application module. Its array extents must follow the batch argument
rules, with one `timings`, `statuses` and `messages` entry per batch. This
example stops submitting batches after an observed error; calls already past
the flag check may finish. Unsubmitted entries retain the application-local
`not_submitted=-1`, rather than an XNet result. After any error the example
terminates and consumes none of the batch results. An application may correct
a checked input error before evolution, but statuses 4 and 5 always require
shutdown.

Use one fixed, nonnested worker team throughout the lifetime. Keep affinity
settings stable and dynamic teams disabled. OpenMP's guarantee that a
noninitial worker keeps its `threadprivate` allocation between active regions
also requires no intervening host `teams` region, no `order(concurrent)`
construct, and no `omp_pause_resource`/`omp_pause_resource_all` call. The
[OpenMP 5.2 threadprivate rules](https://www.openmp.org/spec-html/5.2/openmpse24.html)
give the full conditions. XNet checks only part of this: dynamic/nested or
wrong-sized teams return `xnet_unsupported`, and absent worker scratch returns
`xnet_lifecycle_error`. Equal thread counts alone do not establish persistence.
Tasks, recursive calls, simultaneous unrelated teams and arbitrary team
changes are unsupported. Calls on the initial thread between supported
regions are allowed. A supplied EOS provider must also permit concurrent
evaluations.

With `OPENMP_MODE=OFF`, serialize all XNet calls, including NSE and lifecycle
operations. The application may use OpenMP elsewhere. This choice suppresses
XNet's host teams and threadprivate state even when target-offload compilation
enables OpenMP directives. For v9, OpenMP target GPU builds require this XNet
setting for both standalone programs and the library. GPU host calls remain
serialized.

## Mapped GPU batch

These two fragments replace the burn step in the CPU quickstart, using its
already-declared arrays and `check_status`. Build/link with the selected GPU
library and select the device in both runtimes **before initialization**, as
described in [device and stream selection](#device-and-stream-selection). Keep the
quickstart's network preparation, initialization and finalization. Omit
`gpu_context` for XNet-owned handles; the directive runtime owns the default
OpenACC stream. [GPU builds and resources](#gpu-builds-and-resources) gives the
build recipes and borrowing rules.

### CUDA/OpenACC

```fortran
! Map complete scientific arrays on the device selected before initialization.
! Queue 1 matches the library's default OpenACC queue.
!$acc enter data copyin(density,temperature,ye,mass_fraction,restart_dt_s) create(neutrino_loss) async(1)
!$acc wait(1)
Call xnet_burn_batch(dt_s=0.1_dp,active=active,zone_id=zone_id,density=density, &
  & temperature=temperature,ye=ye,mass_fraction=mass_fraction,restart_dt_s=restart_dt_s, &
  & neutrino_loss=neutrino_loss,counters=counters,timing=timing,ierr=ierr,message=message, &
  & max_steps_taken=max_steps_taken,data_on_device=.true.)
Call check_status(operation='burn',status=ierr,detail=message)
! Transfer results only when the application needs their host values.
!$acc update self(temperature,ye,mass_fraction,restart_dt_s,neutrino_loss) async(1)
!$acc wait(1)
! Delete these application mappings after the last call that uses them.
!$acc exit data delete(density,temperature,ye,mass_fraction,restart_dt_s,neutrino_loss) async(1)
!$acc wait(1)
```

### HIP/OpenMP target

```fortran
! Map complete arrays on the device selected before initialization.
! This nowait enter-data operation creates a target task in the current task.
!$omp target enter data map(to:density,temperature,ye,mass_fraction,restart_dt_s) map(alloc:neutrino_loss) nowait
!$omp taskwait
Call xnet_burn_batch(dt_s=0.1_dp,active=active,zone_id=zone_id,density=density, &
  & temperature=temperature,ye=ye,mass_fraction=mass_fraction,restart_dt_s=restart_dt_s, &
  & neutrino_loss=neutrino_loss,counters=counters,timing=timing,ierr=ierr,message=message, &
  & max_steps_taken=max_steps_taken,data_on_device=.true.)
Call check_status(operation='burn',status=ierr,detail=message)
! These directives complete before the application reads or deallocates arrays.
!$omp target update from(temperature,ye,mass_fraction,restart_dt_s,neutrino_loss)
!$omp target exit data map(delete:density,temperature,ye,mass_fraction,restart_dt_s,neutrino_loss)
```

In either case, retain mappings across later burns when the application keeps
its data on the device; delete them only after the final use. The fragments
show the initial transfer and eventual host update explicitly. Host diagnostic
arguments remain on the host. For other producer tasks/streams, use the
application's dependency and synchronization rules described in
[host and resident device arrays](#host-and-resident-device-arrays).

## Batch inputs and returned values

The public call is:

```fortran
Call xnet_burn_batch(dt_s=dt_s,active=active,zone_id=zone_id,density=density, &
  & temperature=temperature,ye=ye,mass_fraction=mass_fraction,restart_dt_s=restart_dt_s, &
  & neutrino_loss=neutrino_loss,counters=counters,timing=timing,ierr=ierr,message=message, &
  & aux_x=aux_x,aux_a=aux_a,aux_z=aux_z,max_steps_taken=max_steps_taken,data_on_device=.false.)
```

The final five arguments are optional; supply all three auxiliary arguments
together or omit all three. Use keywords for optional arguments, particularly
when omitting auxiliaries. All real arguments use `Real(dp)`.

Let `nz=size(active)` and `ny=size(network%names)`. The thermodynamic, restart,
loss and optional auxiliary arrays have length `nz`; `mass_fraction` has shape
`(ny,nz)`, `zone_id` has shape `(4,nz)`, and integer `counters` has shape `(5,nz)`.
`nz` may be smaller than `nzbatchmx`.

Each `zone_id(:,izone)` is the application mesh location **`[i,j,k,block]`**,
in that order. Use `1` for unused spatial dimensions and `0` when the
application has no block identifier. For example, a one-dimensional zone 17
is `[17,1,1,0]`; cell `(2,5,1)` in block 9 is `[2,5,1,9]`.
XNet records the application's mesh indices verbatim for diagnostics and
output; it does not interpret their indexing convention or use them to
select array columns. The submitted batch position selects the scientific
arrays. Duplicate locations are allowed, including across repeated calls.
Three-component arrays are rejected.

### Species indices and application storage

The list returned in `network%names` defines the API species indices for the
initialized network. Entry `i` in each metadata array describes `network%names(i)`;
row `i` of every burn composition and entry `i` of every NSE result refer to
that same species. Names retain XNet's five-character fields; use
`trim(adjustl(network%names(i)))` when matching them to application names.

The application may use any storage order. For example, Flash-X's alphabetical
species storage needs a name-based map when packing composition into XNet's
arrays and unpacking results. CHIMERA should likewise use its own species map.
XNet does not infer that map or reorder the application arrays automatically.

No alphabetical, charge/mass, or cross-version ordering is promised. Build or
validate the map after each successful initialization. API species indices stay
fixed during that initialized lifetime; this does not constrain future internal
solver storage or require applications to inspect `sunet` or `netwinv`.

### Units and conventions at a glance

| Quantity | Units and convention |
| --- | --- |
| `dt_s` | Positive finite duration in seconds; each call has local time `0..dt_s`. |
| `density` | Positive finite g/cm^3; held constant during the burn. |
| `temperature` | Positive finite K, in/out. With `iheat<=0`, its caller value is preserved on successful return; with `iheat>0`, temperature is coupled implicitly. Internal/output `T9` uses GK. |
| `mass_fraction(species,zone)` | Nonnegative finite raw `X`; row `i` corresponds to `network%names(i)`. No normalization or automatic application-species mapping. Internal abundances are `Y=X/A`. |
| `ye` | Finite input in `[0,1]`, in/out. Composition moments recompute it during evolution, including with fixed temperature. |
| `aux_x`, `aux_a`, `aux_z` | Fixed reservoir mass fraction, mass number and charge. `0<=aux_x<=1`, `0<=aux_z<=aux_a`; positive mass requires positive A. Zero auxiliary mass means no reservoir. |
| `restart_dt_s` | Nonnegative seconds, in/out; a startup hint and historical timestep result, as described below. |
| `neutrino_loss` | Integrated weak-reaction neutrino energy loss in erg/g; separate from unsupported incident-neutrino histories. |
| `timing` | Stage durations in seconds; see below. |
| Network metadata | Copied names and integer A/Z. `binding_energy_mev` is binding energy in MeV per nucleus; `mass_excess_mev` is mass-excess energy in MeV per nucleus. |

The active composition must contain positive total mass, including any
auxiliary reservoir. The API does not enforce `sum(X)+aux_x=1` or check input
Ye against X. The composition-based value is

```text
Ye = (sum(Z*Y) + aux_x*aux_z/aux_a) / (sum(A*Y) + aux_x)
```

with the auxiliary terms absent when its mass is zero. The reservoir
contributes to EOS moments without becoming an evolved species. Species
mapping, normalization policy, nuclear energy release and any application
neutrino correction remain application responsibilities.

On success, inactive zones preserve temperature, Ye, X and restart hints,
and return zero loss and counters. Their scientific values are not read.
An all-inactive call performs no burn and returns zero timing and step count.
The library keeps no association with caller arrays. Copied `network`
metadata remains usable after finalization; failed initialization does not
produce usable metadata.

### First and later calls: restart hints

Use `restart_dt_s=0` for a fresh startup with either BE or BDF. On later calls,
keeping zero is also valid. An application that already uses XNet's historical
positive-hint convention may pass a nonnegative saved result, but it is not a
recommended next timestep or a checkpoint of solver history.

Positive input changes the initial timestep estimate: it uses the existing
startup change factor `0.5` instead of `0.01`, and uses half the hint, limited
by the remaining interval, as a floor combined with the adaptive estimate.
It does not fix the timestep. Output is `tdel_old`, the preceding
internal timestep, which can be zero after a single-step burn. BDF starts its
history again for each burn; passing a positive hint does not restore that
history. Use zero on every BDF call unless preserving an established hint
policy deliberately.

### Counters and timings

`counters(:,zone)` is reset for each call and contains:

| Row | Count |
| --- | --- |
| 1 | Internal timestep attempts, including retries. |
| 2 | Newton iteration/attempt accounting, including failed work. |
| 3 | Jacobian builds. |
| 4 | Derivative evaluations. |
| 5 | Rate evaluations. |

Optional `max_steps_taken` returns the maximum accepted outer integration
step count in the batch (`full_net`'s `kstep`). It differs from row 1, and is
zero for an all-inactive call or any non-success return.

`xnet_timing_t` reports changes in the calling worker's existing timers over
this burn, in wall-clock seconds:

| Field | Timed work |
| --- | --- |
| `evolve` | The evolution interval inside `full_net`, ending before `final_output`. |
| `timestep` | Implicit timestep solves and retries in `solve_be` or `solve_bdf`. The initial timestep estimate outside these routines is excluded. |
| `newton` | Newton iteration work within those implicit solves. |
| `solve` | Linear solves, including any separately timed decomposition and backsubstitution. |
| `decomposition` | LU factorization, where measured separately by the solver backend. |
| `backsubstitution` | Solution using existing LU factors, where measured separately by the backend. |
| `jacobian` | Jacobian construction. |
| `derivative` | ODE right-hand side evaluation. |
| `rates` | Reaction-rate evaluation after EOS and screening updates. |
| `screening` | Screening-factor calculation after plasma-state preparation. |
| `prescreening` | Plasma quantities computed through `eos_screen` for screening. |
| `eos` | Thermodynamic updates through `update_eos`; screening's plasma preparation is counted in `prescreening`. |
| `output` | Timed sections of `ts_output` and `final_output`, including flux calculation and transfers within those sections. |

These are overlapping measurements, not a partition of the burn. For example,
Newton work includes linear solves, and the linear-solve timer includes any
separately measured factorization and backsubstitution. Do not sum the fields.
An unused or unmeasured stage returns zero, as can work below the timer's
resolution. A combined solver operation need not populate the separate
decomposition and backsubstitution timers.

`evolve` excludes API validation, staging and result extraction. `output`
includes work in `final_output` after `evolve` stops, and can be nonzero even
when history files are disabled. It excludes opening files, writing their
headers, closing files and diagnostic writes outside the timed sections.
GPU values measure host wall time around these operations, including any
waits within them; they are not individual GPU kernel timings.

Applications accumulate their own totals for each field and measure around
`xnet_burn_batch` for full-call elapsed time. Initialization, scalar NSE queries
and finalization are separate operations and are excluded from these burn
timings. Measure those calls separately in the application. The standalone
`timer_setup` and the internal NSE timers are not burn-stage measurements.

## Status and shutdown

Initialization, burns, NSE queries and finalization return an integer `ierr`
and an assumed-length `Character(*)` `message`. The caller chooses the buffer length; 512 characters
accommodates current diagnostics. Status constants are exported by `xnet_api`.

| Status | Meaning and action |
| --- | --- |
| `xnet_success=0` | The requested operation completed. Burn physical results are valid for active zones. |
| `xnet_invalid=1` | Invalid controls, extents or active values; missing/unreadable required files; output-open failure; or some GPU runtime checks. Correct the rejected request. Host-input validation preserves in/out physical arrays and clears loss, counters, timing and step count. |
| `xnet_lifecycle_error=2` | Initialization while already initialized or cleanup is pending; work before initialization/after finalization; or missing worker scratch. Correct the lifecycle or worker use. |
| `xnet_unsupported=3` | Unsupported feature or checked execution mode, including incident-neutrino histories, GPU arguments in a CPU build, dynamic/nested host OpenMP teams, or a worker-team size mismatch. |
| `xnet_integrator_failure=4` | BE/BDF reports failure after its internal retry logic. The application must terminate. BDF does not retain a detailed failure reason, so this status does not assert that every failure exhausted the same number of attempts. |
| `xnet_step_limit=5` | An active zone has not reached the stop time after `kstmx` outer integration steps. The application must terminate. |

For statuses 4 and 5, use only `ierr`, `message`, attempted `counters` and
per-call `timing` for diagnosis. No physical result from the batch is valid;
loss and `max_steps_taken` remain zero. The message identifies the one-based
submitted zone and its `[i,j,k,block]` location. Log the application's
context, join any worker team, then perform its fatal/MPI shutdown. Do not
retry, use successful zones from the failed batch, or reuse the instance.
This is a caller obligation: XNet does not latch a failed state that rejects
every subsequent call. Other calls already in flight may finish; this is not
cancellation or permission to continue the simulation after a failure.

These reported failures close the elapsed timer, close partial histories,
and skip successful final output and standalone failure-file writes. They
do not provide general error recovery. Malformed-network readers, EOS/provider
failures, allocation failures, singular linear solves, arbitrary nonfinite
arithmetic and fatal NSE convergence can still terminate inside the code.

For resident device inputs, validation can fail before device scientific outputs
are initialized. On a rejection, rely on host status and diagnostics rather than
a scientific output sentinel. Active scientific values are validated on the
device before integration.

Initialize and finalize with no calls in flight. Repeated finalization after
completion returns success. Failed GPU initialization rolls back resources it
created; if that cleanup also fails, call finalization to retry it before
initializing again. Burns and NSE queries remain blocked, and no network arrays
were created on that path. If GPU cleanup fails after arrays are released,
new initialization, burns and NSE queries are blocked; another finalization
retries GPU cleanup without repeating array/EOS teardown. This preserves
cleanup bookkeeping and does not promise recovery from a GPU runtime fault.

## Controls reference

The following are all 32 fields of `xnet_controls_t`, after
`set_xnet_controls_defaults`. Integers use default Fortran `Integer`, real
controls use `Real(dp)`, and numerical ratios/tolerances are dimensionless
unless stated. Initialization copies the controls into XNet; changing the
caller's value afterward does not reconfigure the initialized network. Finalize
and initialize again to apply different controls.

Common validation still checks controls that are ignored by
the API or selected solver; for example, BDF does not permit a nonpositive
`tolm` merely because it does not use that tolerance.

| Field | Type and default | Effect in the library API |
| --- | --- | --- |
| `description` | `Character(80)(3)`, blank | Three description strings in the binary header. |
| `szone` | Integer, `1` | Common validation requires `1<=szone<=nzone`; does not select API zones. |
| `nzone` | Integer, `1` | Must be positive; does not set submitted batch size or diagnostic IDs. |
| `iweak0` | Integer, `1` | `>0`: strong and weak reactions; `0`: no weak; `<0`: weak only. Existing low-temperature logic can change the effective per-zone weak flag. |
| `iscrn` | Integer, `1` | `>0` enables screening; `<=0` disables ordinary screening. NSE uses the same setting. |
| `iprocess` | Integer, `0` | `>0` preprocesses ASCII network inputs, writing `data_dir`; `<=0` loads prepared data. The application provides exclusive access. |
| `nzbatchmx` | Integer, `1` | Positive maximum submitted zone count per call and worker, including inactive holes. |
| `isolv` | Integer, `1` | Exactly `1` for Backward Euler or `3` for BDF; other values rejected. |
| `kstmx` | Integer, `9999` | Positive maximum outer integration steps; reaching it short of the stop time returns status 5. |
| `kitmx` | Integer, `5` | Positive BE Newton iteration limit; BDF uses `max(kitmx,3)` per Newton solve attempt. |
| `ijac` | Integer, `1` | Positive BE Jacobian rebuild interval; BDF has its own rebuild logic and ignores this interval. |
| `iconvc` | Integer, `0` | BE: `0` tests change in total network-plus-auxiliary mass from the start of the step; nonzero tests the sum of relative abundance corrections. BDF: `0` infinity, `1` L1, `2` L2, `3` RMS weighted norm. Use those defined BDF values; the validator does not restrict the integer. |
| `changemx` | Real, `1e-1` | Positive BE relative-abundance timestep control. BDF replaces it internally with `1e10`. |
| `yacc` | Real, `1e-7` | Nonnegative abundance threshold in `Y=X/A` units for timestep selection. BDF species absolute-tolerance value, with weighting described below. |
| `tolm` | Real, `1e-6` | Positive BE absolute mass-fraction-change convergence limit when `iconvc=0`; does not demand final `sum(X)=1`. Ignored by BDF. |
| `tolc` | Real, `1e-4` | Positive BE relative-abundance-correction convergence limit when `iconvc/=0`; BDF species relative tolerance. |
| `ymin` | Real, `1e-30` | Nonnegative `Y=X/A` cutoff: the integrator sets lower abundances to zero. Also enters BDF weighting. |
| `tdel_maxmult` | Real, `2` | Positive BE timestep growth/failed-trial reduction factor. BDF uses its own factor logic. Validation requires only `>0`. |
| `iheat` | Integer, `0` | `>0` couples temperature implicitly; otherwise successful return preserves caller temperature. |
| `changemxt` | Real, `1e-2` | Positive BE relative-temperature timestep control; BDF replaces it internally with `1e10`. |
| `tolt9` | Real, `1e-4` | Positive relative-temperature convergence/error tolerance, dimensionless despite the internal `T9` name. BDF temperature relative tolerance. |
| `t9nse` | Real, `8` | Nonnegative GK threshold used by the standalone initial-composition reader. Ignored by API burns: supplied X is not replaced automatically. An NSE query runs only when called. |
| `ineutrino` | Integer, `0` | Any nonzero value rejected as unsupported: the API provides no incident-neutrino histories. Weak-reaction neutrino loss remains available. |
| `idiag` | Integer, `0` | `>=0` prints initial/final composition and counters/timers, with more internal detail at higher levels. `-1` prints final counters/timers; `<=-2` suppresses normal guarded diagnostics. API diagnostics use standard output, not a standalone diagnostic file. |
| `itsout` | Integer, `0` | `>=1` binary histories; `>=2` condensed ASCII; `>=3` screen evolution; `>=4` composition diagnostics; `>=5` flux diagnostics. Independent of `idiag` where not separately guarded. |
| `ev_file_base` | `Character(80)`, `'ev_'` | ASCII output filename base; choose a distinct binary base and rank/run prefix. |
| `bin_file_base` | `Character(80)`, `'ts_'` | Binary output filename base. Existing output files cause a checked open failure. |
| `nnucout` | Integer, `0` | Nonnegative number of selected ASCII species, no greater than `size(output_nuclei)`. |
| `output_nuclei` | Allocatable `Character(5)(:)`, length zero | Must be allocated; selected names must be nonblank. Names are mapped during initialization regardless of `itsout`; a missing name prints a warning and selects the final network species rather than rejecting initialization. |
| `data_dir` | `Character(80)`, blank | Required network directory; keep paths within the field length. Preprocessing writes here when requested. |
| `inab_files` | Allocatable `Character(80)(:)`, length zero | Must remain allocated for common validation; contents ignored by API burns. |
| `thermo_files` | Allocatable `Character(80)(:)`, length zero | Must remain allocated for common validation; contents ignored by API burns. |

For BDF `iconvc=0` or `1`, species below `ymin` get zero weight; otherwise
the weight is `1/(tolc*max(abs(Y),yacc))` for nonnegative abundances. For
`iconvc=2` or `3`, it is `1/(tolc*max(abs(Y),ymin)+yacc)`. Thus `yacc` does
not have the same effective absolute-error interpretation for every BDF
norm. BE and BDF `iconvc=0` select different tests; do not interpret BDF's
default as a mass-conservation test.

Neither `idiag<=-2` nor `itsout=0` suppresses every warning or fatal print from
readers or EOS providers. Output controls do not change failure obligations.

## Per-call histories

With `itsout>=1`, an active zone gets a new sequential-unformatted binary
file; `itsout>=2` adds a condensed ASCII companion. Names append
`_callN_laneL` to `bin_file_base` and `ev_file_base`. `L` is the original
one-based local zone, including holes. `N` is reserved once per active output
attempt; concurrent callers may reserve numbers in either order. Do not use
it to infer application batch order.

The binary file's third header record starts with an 80-character label
`XNet API zone_id [i,j,k,block]:` followed by the four supplied integers
separated by spaces. Its second 80-character field remains
`Mass fractions in XNet species order`. The ASCII companion shares the same
suffix, so the binary label also identifies its application zone. Duplicate
ID tuples are allowed; the filename still distinguishes calls and zones.

The six binary header records, snapshot record layout and ASCII columns
retain their existing layouts. The API substitutes labels for standalone
input filenames; the fourth record still describes constant conditions and
the local `0..dt_s` seconds interval. Each call is a separate segment and
does not append to a preceding call's history.

Binary snapshots contain the step, local time in seconds, T9 in GK, density
in g/cm^3, weak-neutrino loss rate, timestep, energy-generation rate,
`Y=X/A` and fluxes. ASCII rows contain step, local time, T9, density,
energy-generation rate, weak-neutrino loss rate, timestep, selected mass
fractions and the timestep/Newton counters. Rates use erg/g/s. There is no
ASCII Ye or zone-ID column, and the full five-counter vector is not written
there. `nnucout=0` leaves the ASCII species columns empty.

The process-local call counter continues across finalization and
reinitialization. Separate process starts do not share it; choose prefixes
that distinguish MPI ranks and runs. Requests rejected before opening output
and all-inactive batches reserve no number and create no files. `STATUS='NEW'` prevents replacement of existing
files. An open failure closes already opened files, preserves that partial
set for diagnosis, consumes its number and returns `xnet_invalid` before
evolution. Reported numerical failure closes partial histories and still
requires shutdown. Existing fatal behavior for write/close errors remains.
Device-array output reads XNet-owned state without refreshing caller host
mirrors.

## GPU builds and resources

GPU library builds require `MATRIX_SOLVER=dense`, `MPI_MODE=OFF`,
`OPENMP_MODE=OFF`, and either CUDA with `GPU_LAPACK_VER=CUBLAS` or HIP with
`GPU_LAPACK_VER=ROCM`. Exactly one of `OPENACC_MODE` and `OPENMP_OL_MODE`
must be `ON`. Make rejects other library selections, including MAGMA.
The CPU OpenMP stack workaround above does not configure GPU device stacks;
these GPU recipes disable XNet host OpenMP teams with `OPENMP_MODE=OFF`.

For Perlmutter with its NVIDIA programming environment and CUDA selected,
an OpenACC build is:

```sh
make MACHINE=perlmutter BUILD_NAME=library-cuda PE_ENV=NVIDIA LAPACK_VER=LIBSCI \
  EOS=STARKILLER MATRIX_SOLVER=dense MPI_MODE=OFF OPENMP_MODE=OFF \
  GPU_MODE=ON GPU_BACKEND=CUDA GPU_LAPACK_VER=CUBLAS \
  OPENACC_MODE=ON OPENMP_OL_MODE=OFF CUDA_DIR=/path/to/cuda -j libxnet
```

For Frontier with CCE and ROCm/hipfort selected, an OpenMP target build is:

```sh
make MACHINE=frontier BUILD_NAME=library-hip PE_ENV=CRAY LAPACK_VER=LIBSCI \
  EOS=STARKILLER MATRIX_SOLVER=dense MPI_MODE=OFF OPENMP_MODE=OFF \
  GPU_MODE=ON GPU_BACKEND=HIP GPU_LAPACK_VER=ROCM \
  OPENACC_MODE=OFF OPENMP_OL_MODE=ON \
  HIPFORT_DIR=/path/to/hipfort ROCM_DIR=/path/to/rocm -j libxnet
```

Replace installation paths and load the facility's compiler, modules and
device-architecture settings first. The site profiles select the Cray compiler
wrappers. Other installations can select `MACHINE=generic` with their compiler,
architecture and numerical-library settings. These recipes specify build selections; they
do not establish numerical validity or portability of every combination.
Use the resulting `xnet-config.mk` to compile and link the application.
`XNET_CPPFLAGS` exports the source-header path and selected preprocessor
definitions when a caller uses `xnet_macros.fh`.

### Device and stream selection

Before initialization, the application selects a device in both the vendor
runtime (`cudaSetDevice` or `hipSetDevice`) and the selected directive runtime
(`acc_set_device_num` or `omp_set_default_device`). XNet compares their
reported integer device numbers; it does not translate between their device
enumerations. Confirm their correspondence under the application's visibility
and placement settings. Keep that selection unchanged through finalization.
The `device` field below uses the current vendor-runtime ordinal, not an
application rank or physical GPU identifier.

`xnet_initialize` accepts optional `gpu_context` of type `xnet_gpu_t`:

```fortran
Type(xnet_gpu_t) :: gpu_context

gpu_context%device = application_device
gpu_context%stream = application_stream
gpu_context%hipblas_handle = application_hipblas_handle
Call xnet_initialize(controls=controls,network=network,ierr=ierr,message=message, &
  & gpu_context=gpu_context)
```

This fragment assumes the application has declared and created the shown
resources with its vendor interfaces. Use `cublas_handle` for CUDA. Fields
default to `device=-1`, `queue=1` and `C_NULL_PTR` handles. `device=-1` uses
the current device; a nonnegative value must match it.

| Fields | Use and ownership |
| --- | --- |
| `stream` | `C_PTR` vendor stream. XNet borrows a supplied or inferred stream; it destroys only a stream it creates. |
| `queue` | Integer OpenACC async ID. It is neither a stream pointer nor an OpenMP thread number. Ignored by OpenMP target. |
| `cublas_handle`, `cusolver_handle` | CUDA handles, each borrowed or created independently. |
| `hipblas_handle`, `rocblas_handle` | HIP handles, each borrowed or created independently. |
| `rocsolver_handle` | Optional rocBLAS handle used by rocSOLVER. If absent, it shares the selected rocBLAS handle without another allocation. |
| `cusparse_handle`, `rocsparse_handle` | Reserved and unused. XNet neither validates nor modifies them; supplying them does not enable GPU sparse solves. |
| `magma_queue` | Reserved; application MAGMA initialization is unsupported by the library. |

Supplied handles must already use the selected stream and BLAS host pointer
mode. XNet checks stream associations, leaves borrowed resources unchanged,
and creates only missing required resources. It does not change the
application's OpenACC queue association.

For OpenACC, `queue` must refer to the same stream as supplied handles and
`stream`. Usually supply just the queue and let XNet obtain its runtime stream.
When the application also needs the pointer, the existing interoperability
binding provides this pattern:

```fortran
Use, Intrinsic :: iso_c_binding, Only: c_long_long
Use xnet_api, Only: xnet_gpu_t
Use xnet_openaccf, Only: acc_get_cuda_stream
Type(xnet_gpu_t) :: gpu_context

gpu_context%queue = 7
gpu_context%stream = acc_get_cuda_stream(int(gpu_context%queue,c_long_long))
! Create or associate application handles with that stream before passing them.
Call xnet_initialize(controls=controls,network=network,ierr=ierr,message=message, &
  & gpu_context=gpu_context)
```

The queue is an application-selected async ID. With no `gpu_context` argument,
OpenACC uses queue 1 and its runtime-owned stream; XNet creates required
handles on it. The runtime retains ownership of that stream.

OpenMP target regions do not execute on the supplied vendor stream, and
`queue` has no effect on their ordering. An omitted stream is inferred from
a supplied library handle, or created by XNet if none is supplied. With no
`gpu_context` argument, XNet creates its stream and required handles on the
application's selected device. Supplying `gpu_context` to a CPU build
returns `xnet_unsupported`.

### Host and resident device arrays

By default, `data_on_device` is absent or false: caller host values are current.
XNet prepares its workspace from those values and returns host results,
transferring its burn data to/from the device each call. Host array sections
remain supported. Existing caller device mappings are neither input sources
nor refreshed output mirrors in this mode.

With `data_on_device=.true.`, the scientific arrays are ordinary contiguous
Fortran arrays already mapped on the selected device: density, temperature,
Ye, mass fractions, restart hints, loss and any auxiliary arrays. Their device
values are current and host mirrors may be stale. XNet checks mapping and
contiguity, validates active values there, and prepares/extracts physical
state there without a scientific-array round trip through the host. It
still copies into its own solver workspace. Raw device pointers and
noncontiguous device sections are unsupported. The caller owns and preserves
the lifetime of its mappings; XNet does not delete them.

See [mapped GPU batch](#mapped-gpu-batch) for transfer and synchronization examples.

`dt_s`, `active`, `zone_id`, `counters`, `timing`, `ierr`, `message` and
`max_steps_taken` remain host arguments in both modes. Calls complete their
own work before returning. Resident scientific results are ready on the
device; the caller explicitly updates its host mirrors when needed.
Diagnostics can transfer internal state for printing.

The application must complete prior producers or order them correctly before
the call. OpenACC uses the selected queue's stream ordering. For resident
inputs, the OpenMP path synchronizes the selected vendor stream before
reading scientific values, but that does not join unrelated OpenMP target
tasks. Complete preceding `nowait` target work using the application's
dependency/task synchronization, such as the appropriate `taskwait`, before
calling XNet. A vendor-stream synchronization error returns `xnet_invalid`.

Finalize before destroying borrowed GPU resources or EOS data. XNet releases
its own mappings and CPU allocations, destroys resources it created, and
clears borrowed references. It does not reset the device, finalize the vendor
runtime, or initialize/finalize application MPI. Do not mix this lifetime
with direct assignments to XNet GPU globals or calls to internal
`gpu_init`/`gpu_finalize`. There is one non-reentrant library instance;
host calls remain serialized.

## Application EOS interface

For `EOS=STARKILLER` and `EOS=EXTERNAL`, the common `source/xnet_eos.F90`
keeps XNet's composition moments, screening, masks, scratch and internal-unit
conversions. A selected `xnet_eos_interface` module supplies thermodynamics.
Applications with their own EOS provide that module:

```sh
make BUILD_NAME=library-application-eos -j libxnet \
  EOS=EXTERNAL EOS_SOURCE=/path/to/xnet_eos_application.F90 \
  EOS_MODULE_DIR=/path/to/application/modules
```

Build the application's EOS modules first with the same compiler and
compatible options. `EOS_SOURCE` is one free-form source whose filename stem
must differ from `xnet_eos`, reserved for XNet's common module.
`EOS_MODULE_DIR` is optional when no additional module directory is needed.
Keep application modules separate from this XNet build's module directory.
The latter is searched first; application module files are prerequisites of
the supplied interface source.

The module exports these procedures with `dp` from `xnet_types`:

```fortran
Subroutine xnet_eos_interface_initialize(nspecies,names,a,z)
  Integer, Intent(in) :: nspecies
  Character(*), Intent(in) :: names(nspecies)
  Real(dp), Intent(in) :: a(nspecies), z(nspecies)
End Subroutine xnet_eos_interface_initialize

Subroutine xnet_eos_interface_evaluate(nspecies,temp,rho,ye,abar,zbar,y,xext,aext,zext,cv,eta,detadt)
  Integer, Intent(in) :: nspecies
  Real(dp), Intent(in) :: temp, rho, ye, abar, zbar, y(nspecies), xext, aext, zext
  Real(dp), Intent(out) :: cv, eta, detadt
End Subroutine xnet_eos_interface_evaluate

Subroutine xnet_eos_interface_finalize
End Subroutine xnet_eos_interface_finalize
```

EOS initialization receives a species list and real-valued A/Z once. Subsequent
evaluation arrays follow that supplied list. The interface may copy metadata
for application species mapping, without keeping associations to XNet arrays.
Evaluation receives temperature in K,
density in g/cm^3, dimensionless Ye, number averages Abar/Zbar and raw
`Y=X/A`. A provider that requires individual species must map the full
composition and reconstruct `X=A*Y`; moments alone do not replace it.
The supplied moments include `xext,aext,zext`. A provider using individual
species must deliberately handle or reject that auxiliary reservoir.

Return `cv` in erg/g/K, `eta=mu_kinetic/(k_B*T)` with electron rest mass
excluded, and `detadt=d(eta)/dT` in K^-1 at fixed density and composition,
using the same convention. This follows the
[Helmholtz chemical-potential convention](https://cococubed.com/code_pages/chemical_potential.shtml).
XNet converts to its internal MeV/nucleon/GK and GK^-1 units. It calls the
provider when heating or screening requires thermodynamics. The bundled
`source/xnet_eos_starkiller.F90` shows the signatures and device directives.

The application prepares its EOS tables before their first use. If the
initialization hook reads those tables, prepare them before
`xnet_initialize`; if it only builds species mapping, tables may be loaded
afterward but before a burn or NSE query. The hooks manage only storage they
own. They must leave application-owned tables, MPI and accelerator state to
the application. The provider must not import mutable XNet working arrays.
Its public arguments expose no application derived types; its implementation
may use the application's EOS types internally.

The application links its EOS objects and dependencies alongside `libxnet.a`;
they are not bundled or discovered automatically. `EOS=EXTERNAL` supports
`libxnet` and EOS-independent `net_setup`, not standalone `xnet` or `xnse`.
For GPU burns, the evaluation procedure and every procedure it calls must be
callable on the selected device, with tables ready there. Scalar host
evaluation must remain available for NSE. Providing this module alone does
not validate the application's EOS, energy treatment or device integration.

## NSE composition queries

After initialization, a scalar host query returns one copied composition:

```fortran
Call xnet_nse_composition(density=density_scalar,temperature=temperature_scalar, &
  & ye=ye_scalar,mass_fraction=nse_fraction,ierr=ierr,message=message)
```

Import `xnet_nse_composition` from `xnet_api`. Declare the three scalar inputs
and `nse_fraction(:)` as `Real(dp)` and
allocate the result to `size(network%names)`. Density is finite positive
g/cm^3, temperature finite positive K, and Ye finite in `[0,1]`. The current
network and screening controls apply. Queries obey the same lifetime and CPU
worker rules as burns; GPU-library queries are serialized host calls with
no device-residency flag. They do not load EOS tables again.

The result is `A*ynse`, not the solver's nuclear-mass-weighted `xnse`.
Its sum need not equal one. XNet does not normalize/reorder it, add the
auxiliary reservoir, or calculate application energy changes. A later query
does not change an earlier copy or the caller's burn arrays. Invalid values
or result extent return `xnet_invalid`; lifecycle violations return
`xnet_lifecycle_error`; checked rejections zero the submitted result vector.
NSE convergence failure remains fatal inside the existing solver and has no
recoverable NSE status.

## Updating a development caller

The following names changed during v9 development. They are notes for callers
of earlier prototypes, rather than a released-interface compatibility promise.
Rebuild those application sources against the current module files and archive:

- Rename the initialization keyword `gpu_resources=` to `gpu_context=`.
- Supply `zone_id(4,nz)` with columns `[i,j,k,block]`. Earlier three-component
  tuples are no longer accepted; reorder existing four-component tuples to
  this convention. Use `1` for unused dimensions and `0` when there is no block.
- Rename `timing%seconds` to `timing%evolve`; all timing fields still use
  seconds, and `evolve` covers only the interval inside `full_net`. Recompile
  callers because `xnet_timing_t` now contains additional burn-stage components.
- For an external EOS provider, rename module `xnet_eos_adapter` to
  `xnet_eos_interface`, and rename `eos_adapter_initialize`,
  `eos_adapter_evaluate` and `eos_adapter_finalize` to
  `xnet_eos_interface_initialize`, `xnet_eos_interface_evaluate` and
  `xnet_eos_interface_finalize`. XNet's common module remains `xnet_eos`.
- XNet's Fortran vendor/directive binding modules now have `xnet_` prefixes,
  for example `xnet_cudaf`, `xnet_cublasf`, `xnet_hipf`, `xnet_rocblasf`,
  `xnet_openaccf` and `xnet_openmpf`. Vendor C symbols are unchanged. Pass
  resources through `xnet_gpu_t` rather than setting binding globals.
- Remove caller dependence on `XNET_EMBEDDING_CPU`. Supported API source is
  selected by Make; unsupported library configurations fail at build time.
  `XNET_CPPFLAGS` supplies the current definitions if the application uses
  `xnet_macros.fh`.
- Prefer keywords for optional `gpu_context`, `aux_x/aux_a/aux_z`,
  `max_steps_taken` and `data_on_device`. Existing calls may omit the added
  optional arguments.

## Application notes: CHIMERA and Flash-X

The public burn signature uses ordinary arrays and fixed `[i,j,k,block]`
diagnostic locations so applications can keep their own mesh and species types.
These responsibilities remain with the application integration:

- CHIMERA maps network metadata to its composition, controls host EOS table
  initialization, and applies its normalization, energy and neutrino-loss
  policy. Its historical positive restart hint is optional; zero remains
  the fresh-start choice, including for BDF.
- Flash-X maps full network species into its EOS representation rather than
  substituting only Abar/Zbar. A mapping without an auxiliary species must
  reject or explicitly handle a nonzero reservoir. Its accepted-step work
  estimates can use `max_steps_taken`, rather than the retry-inclusive
  timestep counter.
- Each application owns MPI shutdown, rank/run output prefixes, accelerator
  placement, device table preparation, stream/task ordering, and validation
  of its physical/energy policy. The library test suite does not establish
  a complete application integration or its performance.

## Reading the implementation

Application code imports [`xnet_api`](../../source/xnet_api.F90). Its four
public procedures appear first, in lifecycle order. The private routines below
them follow the same sequence:

| Part of a call | Where to read |
| --- | --- |
| Initialization | `check_initializable`, `prepare_data_files` and `initialize_thread_state` prepare the call. `initialize_network_data` in `reaction_data` loads species and reactions. `initialize_evolve` in `xnet_evolve` prepares the engine and reusable zone storage with two history endpoints, mapping any requested output species regardless of the output level. `copy_network_data` returns copied metadata. |
| Worker checks | `check_worker` checks the fixed team and initialized worker scratch. `apply_xnet_controls` allocates each worker's flags, counters and file-unit arrays during initialization. Workspace loops use local lanes `izb=1:nzbatchmx`; the API indexes caller arrays with the same lane. Standalone translates to the input ordinal `izone=szbatch+izb-1`. Mesh IDs remain independent of either index. |
| Batch evolution | `xnet_burn_batch` checks lifecycle, mappings, dimensions and scientific values before workspace setup. `evolve_batch` then prepares the workspace, calls `full_net` and extracts results; conditional offload selects current host or device values. |
| Validation and failures | One `validate_inputs` shares range and mass checks between host and device execution. Its temporary verdict buffer carries the host active mask, independently of the worker workspace. Host IEEE classification stays outside device loops. `zone_error_message` translates verdicts; `format_burn_failure` translates numerical failures and the caller's diagnostic tuple. |
| Histories and timing | `open_burn_output` reserves API filenames; shared `open_ts_file`, `open_ev_file` and `close_output_files` in `xnet_output` handle files and headers for both drivers. `get_timing`/`get_timing_since` report differences in the worker timers. |
| Finalization | `finalize_evolve` releases integrator, NSE/EOS, Jacobian, rate-evaluation and zone/history workspace. `finalize_network_data` releases loaded tables, then `controls_finalize` releases bookkeeping before GPU cleanup. Pending GPU cleanup skips all completed data teardown on retry. |

Abundance, condition and neutrino-history storage is allocated and mapped by
its own module initializer, then unmapped and deallocated by its finalizer.
The standalone and library drivers call the same routines; neither repeats
those modules' mapping lists.
The standalone driver and API share data reads in `reaction_data`, setup/cleanup
in `xnet_evolve`, and output-name mapping in `xnet_output`. The
[architecture overview](architecture-overview.md#program-setup) gives their order
and the differences between the two frontends. The API keeps validation,
borrowed resources and status codes.

`validate_inputs` uses per-call verdict and mass-sum buffers in either memory
space. For resident inputs, the verdict buffer carries the host active mask
to the device and returns validation results; scientific inputs stay in their
caller-owned mappings. Invalid or all-inactive calls return before evolution
workspace setup. All-inactive calls skip these temporary buffers and checks
of scientific values; resident calls only clear device loss after the earlier
mapping and extent checks.

`evolve_batch` opens output files before staging workspace, so an open failure
returns without allocating or mapping scratch. Resident scientific arrays
remain in their caller-owned mappings. The separate `loss_work` mapping stays
alive across `full_net` and result collection, then is released before return.

[`xnet_gpu`](../../source/xnet_gpu.F90) manages device selection and resources
for both the standalone driver and the API. Its public lifecycle routines
precede directive-runtime helpers and private setup/teardown routines.
The API calls `gpu_init`, `gpu_check_device` and `gpu_finalize` in CPU builds
too; they return success without GPU work. The public initializer still
rejects a caller-supplied `gpu_context` when GPU support is disabled, and
`check_device_batch` rejects device-array burns before inspecting their arrays.
`init_thread_resources` validates borrowed handles before creating missing
resources, then installs the named vendor handles and their ownership flags.
After the team joins, `gpu_init` uses the ordinary `gpu_finalize` path for a
failed setup. `finalize_thread_resources` releases handles before their stream
and preserves failed resources for the next cleanup attempt.
