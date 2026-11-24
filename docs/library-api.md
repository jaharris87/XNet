# Fortran library API

`libxnet` lets an application such as CHIMERA or Flash-X call XNet through one
module, `xnet_api`, instead of using XNet's internal modules. The application
loads a network once, evolves batches of zones at constant density as often
as it needs, optionally asks for NSE compositions, and releases XNet at the
end. The application keeps its species storage and mapping, its batch loop,
its EOS tables and energy policy, MPI, and accelerator placement.

| Step | Call | The application |
| --- | --- | --- |
| Load a network once | `xnet_initialize` | sets control defaults and overrides; configures its OpenMP team or selects the GPU first. |
| Evolve one batch | `xnet_burn_batch` | supplies mass fractions in the order of `network%names`, checks the status, applies its energy policy. |
| Query equilibrium | `xnet_nse_composition` | supplies density, temperature and Ye; entry `i` of the result is species `network%names(i)`. |
| Release XNet | `xnet_finalize` | waits for outstanding calls first; calls again if GPU cleanup reports failure. |

The library uses the dense solver and `MPI_MODE=OFF`; the application may use
MPI and OpenMP itself. CPU builds allow serial calls or one fixed application
OpenMP team. GPU builds take serialized host calls with CUDA/cuBLAS or
HIP/ROCm. One initialized network per process is supported.

**Check every returned status.** `xnet_integrator_failure` and
`xnet_step_limit` mean the batch failed after XNet's own retries: no result
from that batch is usable and the application must shut down. Some errors
still stop the process inside XNet; see [status and shutdown](#status-and-shutdown).

**Contents:** [CPU quickstart](#cpu-quickstart) ·
[Execution models](#choosing-an-execution-model) ·
[CPU OpenMP](#cpu-openmp-batches) · [Mapped GPU batch](#mapped-gpu-batch) ·
[Inputs and results](#batch-inputs-and-returned-values) ·
[Status and shutdown](#status-and-shutdown) · [Controls](#controls-in-the-library) ·
[Histories](#per-call-histories) · [GPU resources](#gpu-builds-and-resources) ·
[Application EOS](#application-eos-interface) · [NSE](#nse-composition-queries) ·
[Updating a caller](#updating-a-development-caller) ·
[CHIMERA and Flash-X](#application-notes-chimera-and-flash-x)

## CPU quickstart

Build from the repository root:

```sh
make BUILD_NAME=library-cpu MPI_MODE=OFF OPENMP_MODE=OFF GPU_MODE=OFF \
  MATRIX_SOLVER=dense EOS=STARKILLER -j libxnet
```

This creates `build/library-cpu/lib/libxnet.a`, Fortran module files under
`build/library-cpu/mod/`, and `build/library-cpu/xnet-config.mk`, which holds
the compiler, flags and libraries for [linking a caller](#compiling-and-linking-an-application).

The example preprocesses a private copy of the bundled alpha-network ASCII
inputs. From the repository root, create its working directory:

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

The Starkiller EOS reads `helm_table.dat` from the working directory. The
program sets `iprocess=1`, so initialization writes the prepared network into
`network/`; never point preprocessing at a shared or tracked directory. No
`controls.nml`, abundance or trajectory file is involved.

Save the following as `quickstart.f90` in that working directory:

```fortran
Program quickstart
  Use, Intrinsic :: iso_fortran_env, Only: error_unit, output_unit
  Use xnet_api, Only: dp, xnet_controls_t, xnet_network_t, xnet_timing_t, &
    & set_xnet_controls_defaults, xnet_initialize, xnet_burn_batch, xnet_finalize, xnet_success, &
    & xnet_count_timesteps, xnet_count_newton
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
  Write(output_unit,'(a,i0,a,i0)') 'timestep attempts: ',counters(xnet_count_timesteps,1), &
    & '; Newton iterations: ',counters(xnet_count_newton,1)
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

The run prints the preprocessor's network summary, then the burn's evolve
time, accepted step count and returned Ye.

The example shows the three rules every caller follows:

- Call `set_xnet_controls_defaults` before setting fields. A bare
  `xnet_controls_t()` holds deliberately invalid values and unallocated
  arrays. After the defaults, `data_dir` is the only required field.
- Set `nzbatchmx` to the largest number of zones (including inactive ones)
  that one call on one thread will submit.
- Find each species by name in `network%names` after initialization; do not
  assume an order.

Later runs can use `iprocess=0` to load the prepared network. Initialization
checks that `sunet`, `netwinv`, `nets3`, `nets4` and `match_data` are readable
(and, with `iprocess>0`, first `sunet`, `netwinv` and `netsu`); other files a
network uses are read later by the usual readers. XNet does not
coordinate preprocessing across MPI ranks: preprocess once before other ranks
initialize, or give each rank its own directory.

### Compiling and linking an application

`xnet-config.mk` defines:

| Variable | Use |
| --- | --- |
| `XNET_FC`, `XNET_LDR` | The compiler and linker that built XNet. Fortran module files work only with the same compiler, normally the same version. |
| `XNET_MODFLAGS` | Module search path. Required to compile any source that uses `xnet_api`. |
| `XNET_ARCHIVE`, `XNET_LIBS`, `XNET_LDFLAGS` | Link `XNET_ARCHIVE` followed by `XNET_LIBS` (numerical and vendor libraries). |
| `XNET_FFLAGS` | The flags XNet itself was compiled with, including GPU module paths. |
| `XNET_CPPFLAGS` | Header path and preprocessor definitions, needed only if the caller includes `xnet_macros.fh`. |

The quickstart compiles with `XNET_FFLAGS` because it is a known-compatible
set. An application need not adopt XNet's optimization or real-promotion
flags for its own sources: the API uses explicit `Real(dp)` (`real64`) and
default `Integer`, so the caller must keep the same default integer kind.
With a GNU serial CPU build, the quickstart also builds and runs when compiled
with only `-I` for the module directory. CPU OpenMP callers need the selected
build's OpenMP compile and runtime options. GPU callers additionally need the
same directive model (OpenACC or OpenMP offload) and the vendor module paths
in `XNET_FFLAGS`. `XNET_LDFLAGS` also contains XNet's optimization options
alongside OpenMP, accelerator and library-path options: check its contents
before substituting application link flags. With `EOS=EXTERNAL`, the supplied
`EOS_SOURCE` provider is compiled into the archive; also link the application's
underlying EOS objects and dependencies.

## Choosing an execution model

| Library build | Application calls |
| --- | --- |
| [CPU, `OPENMP_MODE=OFF`](#cpu-quickstart) | Serialize all XNet calls. The application may use OpenMP elsewhere. |
| [CPU, `OPENMP_MODE=ON`](#cpu-openmp-batches) | Each thread of one fixed application team calls XNet for its own batch. Configure the team before initialization. |
| [GPU, `OPENMP_MODE=OFF`](#mapped-gpu-batch) | Serialize host calls on the selected device. Pass host arrays, or arrays the application has already mapped to the device. |

Initialize and finalize with no calls in flight. In every model the
application owns the batch loop and the scientific arrays.

`EOS=HELMHOLTZ` uses shared COMMON-block storage and requires
`OPENMP_MODE=OFF`; Make rejects its use with XNet host OpenMP enabled.
`EOS=STARKILLER` supports XNet CPU OpenMP batches. An application-supplied
`EOS=EXTERNAL` provider must support concurrent evaluations for that mode.

## CPU OpenMP batches

Build a separate CPU library configuration:

```sh
make BUILD_NAME=library-openmp MPI_MODE=OFF OPENMP_MODE=ON GPU_MODE=OFF \
  MATRIX_SOLVER=dense EOS=STARKILLER -j libxnet
```

Each thread may call a burn or an NSE query with its own arrays, one call at
a time. Initialize and finalize on the initial thread, outside any
application parallel region.

Set the team size **before initialization**, for example with
`OMP_NUM_THREADS=4 OMP_DYNAMIC=FALSE`, or with `omp_set_dynamic(.false.)` and
`omp_set_num_threads(4)` on the initializing thread. XNet opens its own
parallel regions during initialization and finalization to allocate and free
each thread's work arrays, and records the team size. A `num_threads(4)`
clause on a later application loop does not affect those regions. XNet does
not change the application's OpenMP settings.

For Perlmutter NVIDIA/LibSci CPU OpenMP runs, also set this before starting
the application:

```sh
export OMP_STACKSIZE=16M
```

See the [stack workaround](development/build-and-test.md#perlmutter-nvidia-cpu-openmp-stack-workaround)
for the configuration it was tested with.

Each thread owns `THREADPRIVATE` work arrays for up to `nzbatchmx` zones,
allocated on every thread of the team even if it never receives a batch, and
reused across calls. Memory therefore scales with `nthread*nzbatchmx`. With
eight-byte reals, the two dense Jacobian matrices (`dydotdy` and `jac`) alone
take about `16*msize**2*nthread*nzbatchmx` bytes, where `msize` is `ny`, or
`ny+1` with self-heating. Network tables and EOS initialization are shared.

The following application routine submits prepared batches, records one
status per batch, and decides whether to stop only after the parallel loop
ends. Compile it and its caller with the OpenMP library's settings:

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

Put the routine in an application module so callers have its explicit
interface. Its arrays follow the [batch argument rules](#batch-inputs-and-returned-values),
with one `timings`, `statuses` and `messages` entry per batch. After the first
error it stops submitting new batches; calls already past the check finish.
It then terminates without using any batch result. An application may
instead correct a rejected request (statuses 1-3) and resubmit it, but
statuses 4 and 5 always require shutdown.

Keep one fixed, nonnested team for the whole lifetime, with stable affinity
and dynamic teams disabled. OpenMP keeps a thread's `threadprivate` data
between parallel regions only under the
[OpenMP 5.2 threadprivate conditions](https://www.openmp.org/spec-html/5.2/openmpse24.html);
in particular, avoid host `teams` regions, `order(concurrent)` constructs and
`omp_pause_resource` calls between XNet calls. XNet rejects dynamic, nested or
differently sized teams with `xnet_unsupported`, and a thread without work
arrays with `xnet_lifecycle_error`, but it cannot detect every violation.
Tasks, recursion, simultaneous unrelated teams and changing teams are not
supported. Calls from the initial thread between parallel regions are
allowed. An application EOS provider must allow concurrent evaluations.

With `OPENMP_MODE=OFF`, serialize all XNet calls, including NSE queries and
initialization/finalization; the application may still use OpenMP elsewhere.
XNet's host threading is selected by `XNET_OMP` (the `XOMP` sentinel in
`xnet_macros.fh`) independently of accelerator directives (`XDIR`), so it
stays off even when the compiler enables OpenMP for target offload. OpenMP
target GPU builds therefore require `OPENMP_MODE=OFF`.

## Mapped GPU batch

These two fragments replace the burn step in the CPU quickstart, using its
arrays and `check_status`. Build against a [GPU library](#gpu-builds-and-resources)
and select the device in both runtimes **before initialization**, as described
in [device and stream selection](#device-and-stream-selection). Without a
`gpu_context` argument XNet creates the handles it needs; on OpenACC it uses
the runtime's stream for queue 1.

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

An application that keeps its data on the device keeps these mappings across
burns and deletes them after the last use. Diagnostic arguments (`active`,
`zone_id`, `counters`, `timing`, status) stay on the host. See
[host and resident device arrays](#host-and-resident-device-arrays) for
ordering with other device work.

## Batch inputs and returned values

The full call is:

```fortran
Call xnet_burn_batch(dt_s=dt_s,active=active,zone_id=zone_id,density=density, &
  & temperature=temperature,ye=ye,mass_fraction=mass_fraction,restart_dt_s=restart_dt_s, &
  & neutrino_loss=neutrino_loss,counters=counters,timing=timing,ierr=ierr,message=message, &
  & aux_x=aux_x,aux_a=aux_a,aux_z=aux_z,max_steps_taken=max_steps_taken,data_on_device=.false.)
```

The last five arguments are optional; pass the three auxiliary arrays
together or not at all, and use keywords for optional arguments. All reals
are `Real(dp)`.

With `nz = size(active)` and `ny = size(network%names)`, the thermodynamic,
restart, loss and auxiliary arrays have length `nz`, `mass_fraction` has shape
`(ny,nz)`, `zone_id` `(4,nz)` and `counters` `(5,nz)`. `nz` counts inactive
entries and may be smaller than `nzbatchmx`. Column `i` of every array is the
same zone; for example, `active = [.true.,.false.,.true.]` evolves columns 1
and 3 of three-column arrays.

`zone_id(:,i)` is the application's mesh location **`[i,j,k,block]`**, used
only for diagnostics and history headers. Use `1` for unused dimensions and
`0` when there is no block: a one-dimensional zone 17 is `[17,1,1,0]`; cell
`(2,5,1)` in block 9 is `[2,5,1,9]`. Duplicates are allowed.

### Species indices and application storage

`network%names` from `xnet_initialize` defines the species order: row `i` of
`mass_fraction`, entry `i` of each `network` metadata array and entry `i` of
an NSE result all refer to `network%names(i)`. Names are XNet's
five-character fields; compare `trim(adjustl(network%names(i)))` with
application names.

The application keeps any storage order and builds its own map. Flash-X, for
example, stores species alphabetically and maps by name when packing and
unpacking; CHIMERA uses its own map. XNet promises no alphabetical,
charge/mass or cross-version order, so build or check the map after each
initialization. The order is fixed for that initialized lifetime and says
nothing about XNet's internal storage; applications need not read `sunet` or
`netwinv`.

### Units and conventions at a glance

| Quantity | Units and convention |
| --- | --- |
| `dt_s` | Burn duration in s, positive and finite. Each call integrates its own local time `0..dt_s`. |
| `density` | g/cm^3, positive and finite, constant during the burn. |
| `temperature` | K, positive and finite, in/out. Returned unchanged unless `iheat>0`, which evolves it. XNet uses T9 (GK) internally and in histories. |
| `mass_fraction(species,zone)` | Mass fractions `X`, nonnegative and finite, in/out. Not normalized or reordered. XNet evolves `Y = X/A`. |
| `ye` | Finite input in `(0,1]`, in/out. Returned from the accepted composition, including weak-reaction changes. |
| `aux_x`, `aux_a`, `aux_z` | Mass fraction, mass number and charge of a fixed auxiliary reservoir; `0<=aux_x<=1`, `0<=aux_z<=aux_a`, and `aux_a>0` when `aux_x>0`. Zero `aux_x` means no reservoir. |
| `restart_dt_s` | s, nonnegative, in/out; see [restart hints](#first-and-later-calls-restart-hints). |
| `neutrino_loss` | Out: neutrino energy loss integrated over the burn, erg/g, from FFN-format weak rates with tabulated neutrino energies read from `netweak`. REACLIB-format weak reactions contribute zero; a network without FFN entries returns zero. |
| `timing` | Out: stage durations in s; see [timings](#counters-and-timings). |
| `network` metadata | Copied names and integer A and Z; `binding_energy_mev` and `mass_excess_mev` in MeV per nucleus. |

The [weak-rate table limits](running-xnet.md#weak-rate-table-limits) describe
FFN edge holding and the actual-state phase space used for logft capture.

Each active zone must contain positive mass and positive electron content,
counting any auxiliary reservoir. At least one network species with positive
charge must have positive mass fraction, or the auxiliary reservoir must have
both positive mass fraction and positive charge. Zero-electron compositions
are rejected even when the supplied Ye is positive; there is no additional
positive cutoff. XNet does not require `sum(X) + aux_x = 1` or compare input
Ye with the composition. Returned Ye is

```text
Ye = (sum(Z*Y) + aux_x*aux_z/aux_a) / (sum(A*Y) + aux_x)
```

without the auxiliary terms when `aux_x` is zero. The reservoir enters the EOS
moments but is not evolved. Normalization, nuclear energy release and any
neutrino correction are the application's choices.

On success, inactive zones keep their temperature, Ye, X and restart hint and
return zero loss and counters; their scientific inputs are not read. An
all-inactive call does nothing and returns zero timings and step count. XNet
keeps no reference to caller arrays. The copied `network` metadata stays
valid after finalization; a failed initialization returns no usable metadata.

### First and later calls: restart hints

Pass `restart_dt_s = 0` for a fresh start with BE or BDF. Zero remains valid
on every later call. On return it holds `tdel_old`, the internal timestep
before the last one, which can be zero after a single-step burn. It is not a
recommended next timestep or a checkpoint of solver history.

A positive input follows XNet's historical CHIMERA convention. It changes
only the initial step estimate: the startup change factor becomes `0.5`
instead of `0.01`, and half the hint, limited by the burn duration, becomes a
lower bound on the adaptive first step. BDF restarts its history on every
call either way, so BDF callers should normally pass zero.

### Counters and timings

`counters(:,zone)` is reset for each call. Import these public integer row
indices from `xnet_api` to select a count in the `(5,nz)` array:

| Constant | Row | Count |
| --- | --- | --- |
| `xnet_count_timesteps` | 1 | Internal timestep attempts, including retries. |
| `xnet_count_newton` | 2 | Newton iterations, including failed attempts. |
| `xnet_count_jacobians` | 3 | Jacobian builds. |
| `xnet_count_derivatives` | 4 | Derivative evaluations. |
| `xnet_count_rates` | 5 | Rate evaluations. |

Optional `max_steps_taken` returns the largest number of accepted outer
steps in the batch (`kstep` in `full_net`). Unlike row 1 it excludes retries;
Flash-X uses it for work estimates. It is zero for an all-inactive call or a
failed one.

`xnet_timing_t` reports how much the calling thread's XNet timers advanced
during the burn, in wall-clock seconds:

| Field | Timed work |
| --- | --- |
| `evolve` | Time integration inside `full_net`, ending before `final_output`. Excludes API checks, staging and result copies. |
| `timestep` | Implicit step solves and retries in `solve_be`/`solve_bdf`; excludes the initial step estimate. |
| `newton` | Newton iterations within those solves. |
| `solve` | Linear solves, including any separately timed factorization and backsubstitution. |
| `decomposition` | LU factorization, where the solver times it separately. |
| `backsubstitution` | Solves with existing LU factors, where timed separately. |
| `jacobian` | Jacobian construction. |
| `derivative` | Right-hand-side evaluation. |
| `rates` | Reaction-rate evaluation after EOS and screening updates. |
| `screening` | Screening factors, after plasma-state preparation. |
| `prescreening` | Plasma quantities for screening (`eos_screen`). |
| `eos` | Thermodynamic updates (`update_eos`). |
| `output` | Timed parts of `ts_output` and `final_output`, including flux calculation; can be nonzero with histories off, and extends past `evolve`. Excludes opening and closing files. |

The fields overlap — Newton work includes linear solves, which include
factorization — so do not add them. Zero can mean an unused stage, an
untimed solver step, or work below timer resolution. GPU values are host wall
time around device work, not kernel timings. Initialization, NSE queries and
finalization are not included; time those calls, and the full burn call, in
the application.

## Status and shutdown

Every call returns an integer `ierr` and a `Character(*)` `message`; 512
characters holds current messages. The constants are exported by `xnet_api`.

| Status | Meaning and action |
| --- | --- |
| `xnet_success=0` | Completed. Burn results are valid for active zones. |
| `xnet_invalid=1` | Rejected request: invalid controls, extents or active-zone values; missing or unreadable network files; a history file that cannot be created; some GPU runtime checks. In/out physical arrays are unchanged for host inputs; loss, counters, timing and step count are zero. Correct the request. |
| `xnet_lifecycle_error=2` | Wrong order: initializing twice or while cleanup is pending, calling before initialization or after finalization, or calling from a thread without work arrays. |
| `xnet_unsupported=3` | Not available in this build or mode: incident-neutrino histories, GPU arguments in a CPU build, dynamic or nested OpenMP teams, or a team size different from initialization. |
| `xnet_integrator_failure=4` | BE or BDF failed after its own retries. Shut down. |
| `xnet_step_limit=5` | A zone did not reach `dt_s` within `kstmx` steps. Shut down. |

After status 4 or 5, use only `ierr`, `message`, the attempted `counters` and
`timing` for diagnosis; the message names the failing batch column and its
`[i,j,k,block]`. Physical results, loss and `max_steps_taken` are not usable.
Log the application context, leave any parallel region, then perform the
application's fatal or MPI shutdown. Do not retry the batch, keep its
successful zones or continue with the instance. XNet does not enforce this:
later calls are not blocked.

On these failures XNet closes partial history files and writes no
standalone `ab_fail_*`/`th_fail_*` files. Some errors are not returned and
still stop the process inside XNet: malformed network files, EOS errors,
allocation failures, singular linear systems, non-finite arithmetic and NSE
non-convergence.

With device-resident inputs, a rejected call may return before device outputs
are written, so rely on the status rather than an output sentinel.

Repeated `xnet_finalize` after successful cleanup returns success. If GPU
cleanup fails, during finalization or while rolling back a failed GPU
initialization, burns, NSE queries and new initializations return
`xnet_lifecycle_error` until another `xnet_finalize` succeeds; that call
retries only the GPU cleanup. This keeps resource ownership consistent; it is
not recovery from a GPU runtime fault.

## Controls in the library

`xnet_controls_t` has the same fields as the standalone `controls.nml`; the
[controls reference](running-xnet.md#controls-reference) gives each
default and meaning. `xnet_initialize` validates and copies the controls, so
later changes to the caller's value have no effect; finalize and initialize
again to change them. Every field is validated, including fields the library
or the chosen integrator does not use (for example, `tolm` must be positive
under BDF).

These fields behave differently from standalone runs:

| Field | In the library |
| --- | --- |
| `data_dir` | Required. With `iprocess>0`, preprocessing writes here; give it exclusive access. |
| `nzbatchmx` | Largest `size(active)` one call on one thread may submit. |
| `szone`, `nzone`, `inab_files`, `thermo_files` | Unused. Leave the defaults from `set_xnet_controls_defaults`. |
| `t9nse` | Unused: burns never replace the supplied composition by NSE. Call `xnet_nse_composition` instead. |
| `ineutrino` | Must be 0; otherwise `xnet_initialize` returns `xnet_unsupported`. Weak-reaction `neutrino_loss` is still returned. |
| `iheat` | `>0` evolves temperature; otherwise the caller's temperature is returned unchanged. |
| `idiag` | Diagnostics go to standard output; there is no `net_diag` file. |
| `itsout`, `bin_file_base`, `ev_file_base` | Write [per-call histories](#per-call-histories). |
| `output_nuclei` | Mapped at initialization even when `itsout=0`. A name missing from the network rejects initialization with `xnet_invalid` before evolution setup. |

## Per-call histories

With `itsout>=1`, every active zone of a call gets a new binary history;
`itsout>=2` adds an ASCII history. The names are `bin_file_base` or
`ev_file_base` followed by `_callN_zoneZ`, where `Z` is the one-based column
in the submitted batch (counting inactive entries, not a mesh ID) and `N`
numbers output calls in the process. Threads take numbers in whatever order
they arrive, so `N` does not give the application's batch order. Earlier
development versions used `_callN_laneL` for the same column.

The binary file has the usual six header records and per-step records. In the
third header record the abundance-source field reads
`XNet API zone_id [i,j,k,block]:` followed by the four integers, so both
files of a zone can be traced to the mesh. Its description field reads
`Mass fractions in XNet species order`; the fourth record describes constant
conditions over local time `0..dt_s`. Each call is a separate history; it
does not append to an earlier call.

Binary records hold step, local time (s), T9 (GK), density (g/cm^3),
weak-neutrino loss rate, timestep, energy-generation rate, `Y` and reaction
fluxes. ASCII rows hold step, local time, T9, density, energy-generation rate,
weak-neutrino loss rate, timestep, the `output_nuclei` mass fractions and the
step and Newton counters. Rates are erg/g/s. There are no Ye or zone-ID
columns.

The call counter continues across finalization and reinitialization but not
across processes, so use base names that distinguish MPI ranks and runs.
Rejected and all-inactive calls take no number and create no files. Files
are opened with `STATUS='NEW'`. If one cannot be created (for example, it
already exists), XNet closes the files it opened for that call, leaves them
for diagnosis, and returns `xnet_invalid` before evolving; the call number is
used up. Write and close errors remain fatal. With
device-resident arrays, histories are written from XNet's copies; the
caller's host mirrors are not updated.

## GPU builds and resources

GPU library builds require `MATRIX_SOLVER=dense`, `MPI_MODE=OFF`,
`OPENMP_MODE=OFF`, and either CUDA with `GPU_LAPACK_VER=CUBLAS` or HIP with
`GPU_LAPACK_VER=ROCM`, with exactly one of `OPENACC_MODE` and `OPENMP_OL_MODE`
on. Make rejects other library selections, including MAGMA. The CPU OpenMP
stack setting above does not apply to GPU builds.

On Perlmutter with the NVIDIA programming environment, an OpenACC build is:

```sh
make MACHINE=perlmutter BUILD_NAME=library-cuda PE_ENV=NVIDIA LAPACK_VER=LIBSCI \
  EOS=STARKILLER MATRIX_SOLVER=dense MPI_MODE=OFF OPENMP_MODE=OFF \
  GPU_MODE=ON GPU_BACKEND=CUDA GPU_LAPACK_VER=CUBLAS \
  OPENACC_MODE=ON OPENMP_OL_MODE=OFF CUDA_DIR=/path/to/cuda -j libxnet
```

On Frontier with CCE and ROCm/hipfort, an OpenMP target build is:

```sh
make MACHINE=frontier BUILD_NAME=library-hip PE_ENV=CRAY LAPACK_VER=LIBSCI \
  EOS=STARKILLER MATRIX_SOLVER=dense MPI_MODE=OFF OPENMP_MODE=OFF \
  GPU_MODE=ON GPU_BACKEND=HIP GPU_LAPACK_VER=ROCM \
  OPENACC_MODE=OFF OPENMP_OL_MODE=ON \
  HIPFORT_DIR=/path/to/hipfort ROCM_DIR=/path/to/rocm -j libxnet
```

Load the facility's compiler and modules first and replace the installation
paths. The site profiles select the Cray compiler wrappers; elsewhere use
`MACHINE=generic` with explicit compiler, architecture and library settings.
The [build guide](development/build-and-test.md#platform-status) lists the GPU
configurations that have been run.

### Device and stream selection

Before initialization, select the device in both the vendor runtime
(`cudaSetDevice` or `hipSetDevice`) and the directive runtime
(`acc_set_device_num` or `omp_set_default_device`), and keep it until
finalization. XNet compares the two runtimes' device numbers but does not
translate between them; make sure they name the same GPU under the
application's visibility settings.

`xnet_initialize` accepts an optional `gpu_context` of type `xnet_gpu_t` to
share the application's stream and library handles:

```fortran
Type(xnet_gpu_t) :: gpu_context

gpu_context%device = application_device
gpu_context%stream = application_stream
gpu_context%hipblas_handle = application_hipblas_handle
Call xnet_initialize(controls=controls,network=network,ierr=ierr,message=message, &
  & gpu_context=gpu_context)
```

The application creates these resources with its own vendor calls; use
`cublas_handle` for CUDA. Unset fields default to `device=-1` (the current
device; a nonnegative value must match it), `queue=1` and null handles.

| Field | Use and ownership |
| --- | --- |
| `device` | Vendor-runtime device ordinal, not an MPI rank or physical GPU ID. |
| `stream` | `C_PTR` vendor stream. XNet uses a supplied or inferred stream and destroys only a stream it created. |
| `queue` | OpenACC async ID (not a stream pointer or thread number). Ignored by OpenMP target. |
| `cublas_handle`, `cusolver_handle` | CUDA handles, each supplied or created independently. |
| `hipblas_handle`, `rocblas_handle` | HIP handles, each supplied or created independently. |
| `rocsolver_handle` | rocBLAS handle for rocSOLVER; if null, the rocBLAS handle is shared. |
| `cusparse_handle`, `rocsparse_handle`, `magma_queue` | Reserved and unused; supplying them has no effect. |

Supplied handles must already use the selected stream and BLAS host pointer
mode. XNet checks their stream association, leaves them and the
application's OpenACC queue association unchanged, and creates only what is
missing. Finalize before destroying supplied resources or EOS data.
XNet frees what it created and forgets what it borrowed; it does not reset
the device, finalize the vendor runtime or touch application MPI. Do not set
XNet's GPU module variables directly or call `gpu_initialize`/`gpu_finalize`.

For OpenACC, the supplied `queue` must use the same stream as any supplied
handles and `stream`. Usually supply only the queue and let XNet obtain its
stream. If the application also needs the stream pointer:

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

Without `gpu_context`, OpenACC uses queue 1 and its runtime-owned stream,
and XNet creates the handles on it.

OpenMP target regions do not run on the vendor stream, and `queue` has no
effect on them. An omitted stream is taken from a supplied library handle, or
created by XNet. Without `gpu_context`, XNet creates its stream and handles on
the selected device. Passing `gpu_context` to a CPU build returns
`xnet_unsupported`.

### Host and resident device arrays

With `data_on_device` absent or false, the caller's host arrays are current.
XNet copies the burn data to and from the device on each call, and host array
sections work. Any existing device mappings of those arrays are neither read
nor updated.

With `data_on_device=.true.`, the scientific arrays (density, temperature,
Ye, mass fractions, restart hints, loss, and any auxiliary arrays) must be
contiguous Fortran arrays already mapped on the selected device, with current
device values; host copies may be stale. XNet checks mapping and contiguity,
validates the active values on the device, and copies into and out of its own
work arrays there. Raw device pointers and noncontiguous sections are not
supported. The application keeps ownership of the mappings. Results are
ready on the device when the call returns; update the host copies when they
are needed. Diagnostics may copy XNet's internal state to the host to print it.

Complete or order any work that produces the inputs before the call. OpenACC
orders on the selected queue. For OpenMP target, XNet synchronizes the vendor
stream before reading resident inputs, but that does not wait for unrelated
OpenMP target tasks: finish preceding `nowait` work, for example with
`taskwait`. A failed stream synchronization returns `xnet_invalid`.

## Application EOS interface

With `EOS=STARKILLER` or `EOS=EXTERNAL`, XNet's common `source/xnet_eos.F90`
computes composition moments, screening quantities and unit conversions, and
calls a separate `xnet_eos_interface` module for thermodynamics. The bundled
`source/xnet_eos_starkiller.F90` is one such module. An application supplies
its own:

```sh
make BUILD_NAME=library-application-eos -j libxnet \
  EOS=EXTERNAL EOS_SOURCE=/path/to/xnet_eos_application.F90 \
  EOS_MODULE_DIR=/path/to/application/modules
```

`EOS_SOURCE` is one free-form source file; its name must not be
`xnet_eos.F90`. `EOS_MODULE_DIR` points to the application's module files, if
any; build them first with the same compiler, and keep them out of XNet's
module directory, which is searched first.

The module provides these procedures, using `dp` from `xnet_types`:

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

Initialization receives the network's species names and real A and Z once;
later `y` arrays follow that order. The module may copy this metadata for its
own species map but must not keep references to XNet arrays or use XNet's
mutable work arrays. The arguments are plain arrays and scalars; the
implementation may use the application's own EOS types internally.

Evaluation receives temperature in K, density in g/cm^3, Ye, the number
averages Abar and Zbar (including the auxiliary reservoir), the raw
`Y = X/A` of the network species, and the reservoir `xext`, `aext`, `zext`. A
provider that needs individual species must use `y` (reconstructing
`X = A*Y`) and must handle or reject a nonzero reservoir. It returns `cv` in
erg/g/K, `eta = mu_kinetic/(k_B*T)` without the electron rest mass, and
`detadt = d(eta)/dT` in K^-1 at fixed density and composition, following the
[Helmholtz chemical-potential convention](https://cococubed.com/code_pages/chemical_potential.shtml).
XNet converts these to its internal units. It calls the provider only when
screening or self-heating needs thermodynamics.

The application loads its EOS tables before the first burn or NSE query, and
before `xnet_initialize` if its initialize routine reads them. The provider's
initialize and finalize routines manage only storage they own; tables, MPI
and accelerator state stay with the application. Link the application's EOS
objects with `libxnet.a`. `EOS=EXTERNAL` builds `libxnet` and `net_setup`, not
standalone `xnet` or `xnse`.

For GPU burns, the evaluate routine and everything it calls must be callable
on the device, with tables present there; scalar host evaluation is still
needed for NSE. The Starkiller module shows the required device directives.
Supplying this module does not by itself validate the application's EOS,
energy treatment or device integration.

## NSE composition queries

After initialization, a scalar host query returns one composition:

```fortran
Call xnet_nse_composition(density=density_scalar,temperature=temperature_scalar, &
  & ye=ye_scalar,mass_fraction=nse_fraction,ierr=ierr,message=message)
```

The inputs are `Real(dp)` scalars: density in g/cm^3 and temperature in K,
both positive and finite, and finite Ye in `(0,1]`. Allocate `nse_fraction` to
`size(network%names)`. The network and screening controls apply. Queries
follow the same lifetime and threading rules as burns; on GPU builds they are
serialized host calls with no device option.

When reference nuclei used for an initial NSE guess are absent, XNet uses
available network species selected for the query Ye. This avoids invalid
species indices; it does not guarantee convergence for every network or state.

The result is `A*ynse` in network order, not normalized, without the
auxiliary reservoir, and its sum need not be one. Invalid values or extent
return `xnet_invalid`, lifecycle errors `xnet_lifecycle_error`, and in both
cases the result is zeroed. NSE non-convergence stops the process inside the
solver.

## Updating a development caller

These names changed during v9 development. They concern callers of earlier
prototypes; no released interface changed. Rebuild those sources against the
current module files and archive:

- Rename the initialization keyword `gpu_resources=` to `gpu_context=`.
- Supply `zone_id(4,nz)` with columns `[i,j,k,block]`. Three-component tuples
  are rejected; reorder existing four-component tuples to this convention.
  Use `1` for unused dimensions and `0` when there is no block.
- Rename `timing%seconds` to `timing%evolve`; it covers only the interval
  inside `full_net`. `xnet_timing_t` has more components, so recompile.
- For an external EOS, rename module `xnet_eos_adapter` to
  `xnet_eos_interface`, and `eos_adapter_initialize`, `eos_adapter_evaluate`
  and `eos_adapter_finalize` to `xnet_eos_interface_initialize`,
  `xnet_eos_interface_evaluate` and `xnet_eos_interface_finalize`.
- XNet's vendor and directive binding modules now have `xnet_` prefixes, for
  example `xnet_cudaf`, `xnet_cublasf`, `xnet_hipf`, `xnet_rocblasf`,
  `xnet_openaccf` and `xnet_openmpf`. Vendor C symbols are unchanged. Pass
  resources through `xnet_gpu_t` rather than setting binding variables.
- Remove dependence on `XNET_EMBEDDING_CPU`. Make selects the API source and
  rejects unsupported library configurations; `XNET_CPPFLAGS` supplies the
  current definitions if the application includes `xnet_macros.fh`.
- Calls may omit the newer optional arguments; pass `gpu_context`,
  `aux_x/aux_a/aux_z`, `max_steps_taken` and `data_on_device` by keyword.
- History filenames end in `_callN_zoneZ` instead of `_callN_laneL`; the
  record layouts are unchanged.

## Application notes: CHIMERA and Flash-X

The burn call takes ordinary arrays and a `[i,j,k,block]` location, so each
application keeps its own mesh and species types. Each integration still
owns:

- CHIMERA: mapping network metadata to its composition, initializing its
  host EOS tables, and its normalization, energy and neutrino-loss policy.
  Its historical positive restart hint is optional; zero remains the
  fresh-start choice, including for BDF.
- Flash-X: mapping all network species into its EOS representation rather
  than only Abar/Zbar. A mapping without an auxiliary species must reject or
  handle a nonzero reservoir. It can use `max_steps_taken` for accepted-step
  work estimates.
- Both: MPI shutdown, per-rank output names, accelerator placement, device
  table preparation, stream and task ordering, and validation of the
  physical and energy policy. The library tests do not establish a complete
  application integration or its performance.

The [architecture overview](development/architecture-overview.md#library-api-implementation)
describes how `xnet_api.F90` is organized for readers of the implementation.
