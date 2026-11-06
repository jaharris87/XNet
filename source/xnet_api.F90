!***************************************************************************************************
! xnet_api.F90
! Application-facing embedding API for XNet.
!
! Provides lifecycle management (xnet_initialize, xnet_finalize), constant-condition batched
! reaction-network evolution (xnet_burn_batch) on host or device arrays, and scalar Nuclear
! Statistical Equilibrium queries (xnet_nse_composition).
!
! Concurrency model:
! - CPU (OPENMP_MODE=ON): The host application owns the outer OpenMP parallel loop over batches.
!   Each fixed-team worker owns a disjoint preallocated batch bank (zb_lo:zb_hi) and threadprivate
!   NSE scratch. Initialization and finalization must occur outside OpenMP parallel regions.
! - GPU (GPU_MODE=ON, OPENMP_MODE=OFF): Host API calls are serialized; the application may supply
!   borrowed streams/handles via xnet_gpu_t and evolve device-resident arrays via data_on_device.
!
! Public entry points appear first; private setup, host staging, device staging, output and timing
! helpers follow. Application examples and the full argument reference are in
! docs/development/embedding.md. Application code needs only Use xnet_api, Only: ... .
!***************************************************************************************************

#include "xnet_macros.fh"

Module xnet_api
  Use xnet_types, Only: dp, i8
  Use xnet_controls, Only: xnet_controls_t, set_xnet_controls_defaults
  Use xnet_gpu, Only: xnet_gpu_t
#ifdef XNET_OMP
  Use omp_lib, Only: omp_get_dynamic, omp_get_level, omp_get_num_threads, omp_get_thread_num
#endif
  Implicit None
  Private

  !-------------------------------------------------------------------------------------------------
  ! Public status codes
  !-------------------------------------------------------------------------------------------------
  Integer, Parameter, Public :: xnet_success            = 0
  Integer, Parameter, Public :: xnet_invalid            = 1
  Integer, Parameter, Public :: xnet_lifecycle_error    = 2
  Integer, Parameter, Public :: xnet_unsupported        = 3
  ! These two burn failures require application shutdown; physical results are unusable.
  Integer, Parameter, Public :: xnet_integrator_failure = 4
  Integer, Parameter, Public :: xnet_step_limit         = 5

  !-------------------------------------------------------------------------------------------------
  ! Public types and procedures
  !-------------------------------------------------------------------------------------------------
  Public :: dp
  Public :: xnet_controls_t
  Public :: set_xnet_controls_defaults
  Public :: xnet_gpu_t
  Public :: xnet_initialize
  Public :: xnet_burn_batch
  Public :: xnet_nse_composition
  Public :: xnet_finalize

  Type, Public :: xnet_network_t
    ! Caller-owned copies in species order; valid after finalization of a successful initialization.
    Character(5), Allocatable :: names(:)
    Integer, Allocatable :: mass_number(:)
    Integer, Allocatable :: charge_number(:)
    Real(dp), Allocatable :: binding_energy_mev(:)
    Real(dp), Allocatable :: mass_excess_mev(:)
  End Type xnet_network_t

  Type, Public :: xnet_timing_t
    ! Seconds for this call. evolve covers full_net, excluding API staging and result extraction.
    ! Component timers can nest; they must not be summed to obtain full-call time.
    Real(dp) :: evolve     = 0.0_dp
    Real(dp) :: solve      = 0.0_dp
    Real(dp) :: jacobian   = 0.0_dp
    Real(dp) :: derivative = 0.0_dp
    Real(dp) :: rates      = 0.0_dp
    Real(dp) :: screening  = 0.0_dp
  End Type xnet_timing_t

  !-------------------------------------------------------------------------------------------------
  ! Unit conversions and benign values for inactive workspace lanes
  !-------------------------------------------------------------------------------------------------
  Real(dp), Parameter :: kelvin_to_gk = 1.0e-9_dp
  Real(dp), Parameter :: gk_to_kelvin = 1.0e9_dp
  Real(dp), Parameter :: inactive_t9  = 1.0_dp
  Real(dp), Parameter :: inactive_rho = 1.0_dp
  Real(dp), Parameter :: inactive_ye  = 0.5_dp

  !-------------------------------------------------------------------------------------------------
  ! Internal API lifecycle state
  !-------------------------------------------------------------------------------------------------
  ! Pending GPU cleanup blocks new burns/initializations while allowing xnet_finalize retries
  ! without repeating CPU workspace or EOS teardown.
  Integer, Parameter :: api_uninitialized   = 0
  Integer, Parameter :: api_ready           = 1
  Integer, Parameter :: api_cleanup_pending = 2
  Integer :: api_state = api_uninitialized

  Character(80) :: api_data_description = ' '
  ! Do not reset between lifetimes: earlier time-series files may still exist.
  Integer(i8) :: output_call = 0_i8

  ! Per-lane validation results use the same messages on host and device.
  Integer, Parameter :: lane_ok               = 0
  Integer, Parameter :: lane_not_finite       = 1
  Integer, Parameter :: lane_out_of_range     = 2
  Integer, Parameter :: lane_aux_not_finite   = 3
  Integer, Parameter :: lane_aux_out_of_range = 4
  Integer, Parameter :: lane_aux_needs_a      = 5
  Integer, Parameter :: lane_no_mass          = 6

Contains

  !=================================================================================================
  ! Public Entry Points
  !=================================================================================================

  Subroutine xnet_initialize(controls,network,ierr,message,gpu_resources)
    ! Load one network and reserve reusable workspace for subsequent burns and NSE queries.
    ! Set controls defaults before overriding data_dir, batch capacity and integration options.
    ! Controls are copied; later edits to the supplied value do not reconfigure this instance.
    ! network receives independent copies of species names, A/Z and energies in MeV per nucleus.
    !
    ! Call outside application OpenMP regions after configuring the intended fixed team.
    ! GPU resources are optional: borrow supplied handles and create only missing resources.
    ! A failed GPU rollback may require xnet_finalize before another initialization attempt.
    ! File-content, allocation, EOS and solver failures can still terminate inside XNet.
    Use xnet_controls, Only: apply_xnet_controls
#ifdef XNET_GPU
    Use xnet_gpu, Only: gpu_init, gpu_finalize, mydevice
#endif
    Implicit None
    Type(xnet_controls_t), Intent(in) :: controls
    Type(xnet_network_t), Intent(out) :: network
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message
    Type(xnet_gpu_t), Optional, Intent(in) :: gpu_resources
#ifdef XNET_GPU
    Type(xnet_gpu_t) :: gpu
    Integer :: cleanup_status
    Character(512) :: cleanup_message
#endif

    Call check_initializable(controls,Present(gpu_resources),ierr,message)
    If ( ierr /= xnet_success ) Return
    Call prepare_data_files(controls,ierr,message)
    If ( ierr /= xnet_success ) Return
    Call start_worker_team

#ifdef XNET_GPU
    ! A default resource value tells gpu_init to use the current application device;
    ! with no supplied handles, XNet creates the resources it needs on that device.
    gpu = xnet_gpu_t()
    If ( Present(gpu_resources) ) gpu = gpu_resources
    Call gpu_init(gpu,ierr,message)
    If ( ierr /= xnet_success ) Then
      ! Failed initialization may still own resources whose rollback must be retried.
      If ( mydevice >= 0 ) api_state = api_cleanup_pending
      Return
    EndIf
#endif
    Call apply_xnet_controls(controls,ierr,message)
    If ( ierr /= xnet_success ) Then
#ifdef XNET_GPU
      Call gpu_finalize(cleanup_status,cleanup_message)
      If ( cleanup_status /= xnet_success ) Then
        api_state = api_cleanup_pending
        message = Trim(message)//'; '//Trim(cleanup_message)
      EndIf
#endif
      Return
    EndIf

    Call load_network(controls)
    Call map_workspace
    Call describe_network(network)
    api_state = api_ready
    ierr = xnet_success
    Return
  End Subroutine xnet_initialize

  Subroutine xnet_burn_batch(dt_s,active,zone_id,density,temperature,ye,mass_fraction, &
    & restart_dt_s,neutrino_loss,counters,timing,ierr,message,aux_x,aux_a,aux_z, &
    & max_steps_taken,data_on_device)
    !-----------------------------------------------------------------------------------------------
    ! Evolve a batch of zones over dt_s seconds at constant density (and constant temperature
    ! unless self-heating is enabled). Supports both host-resident arrays (default) and
    ! pre-mapped contiguous device arrays (data_on_device=.true.).
    !
    ! For n = Size(active), scalar-per-zone arrays have length n and mass_fraction has shape
    ! (network species,n). zone_id is a (3,n) or (4,n) diagnostic tuple; counters has shape (5,n).
    ! Capacity nzbatchmx includes inactive holes. Only active scientific inputs are read.
    ! density is in g/cm^3, temperature in K, and mass_fraction contains raw X in network order.
    ! The optional fixed auxiliary reservoir requires aux_x, aux_a and aux_z together.
    !
    ! restart_dt_s is a nonnegative startup hint in seconds; use zero for a fresh burn.
    ! The returned hint is the preceding internal timestep, not a recommended next application dt.
    ! neutrino_loss is integrated weak-reaction energy loss in erg/g. Inactive state is preserved
    ! and its loss/counters are zero. Counters, timing and status always return on the host.
    ! Fatal burn statuses require shutdown after workers join; no physical batch result is valid.
    !-----------------------------------------------------------------------------------------------
    Use xnet_controls, Only: gpu_queue, ktot, lzactive, nzbatch, szbatch, &
      & zb_hi, zb_lo, zb_offset, zone_work=>zone_id
#ifdef XNET_GPU
    Use xnet_gpu, Only: gpu_check_device
#ifdef XNET_OMP_OL
    Use xnet_gpu, Only: stream, stream_sync
#endif
#endif
    Implicit None

    ! Required arguments
    Real(dp), Intent(in) :: dt_s
    Logical, Intent(in) :: active(:)
    Integer, Intent(in) :: zone_id(:,:)
    Real(dp), Target, Intent(in) :: density(:)
    Real(dp), Target, Intent(inout) :: temperature(:), ye(:), mass_fraction(:,:), restart_dt_s(:)
    Real(dp), Target, Intent(out) :: neutrino_loss(:)
    Integer, Intent(out) :: counters(:,:)
    Type(xnet_timing_t), Intent(out) :: timing
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message

    ! Optional arguments
    Real(dp), Optional, Target, Intent(in) :: aux_x(:), aux_a(:), aux_z(:)
    Integer, Optional, Intent(out) :: max_steps_taken
    Logical, Optional, Intent(in) :: data_on_device

    ! Local variables
    Integer :: n, lane, kstep, evolve_status, failed_zone
    Type(xnet_timing_t) :: before
    Logical :: on_device
#ifdef XNET_OMP_OL
    Integer :: stream_status
#endif

    on_device = .false.
    If ( Present(data_on_device) ) on_device = data_on_device
    If ( Present(max_steps_taken) ) max_steps_taken = 0
    timing = xnet_timing_t()
    If ( .not. on_device ) neutrino_loss = 0.0_dp
    counters = 0
    message = ' '

    ! 1. Verify API lifecycle and worker-team state
    ierr = xnet_lifecycle_error
    If ( api_state /= api_ready ) Then
      message = 'Initialize XNet before burning'
      If ( api_state == api_cleanup_pending ) message = 'Finish XNet finalization before burning'
      Return
    EndIf
    Call check_worker(ierr,message)
    If ( ierr /= xnet_success ) Return

    ! 2. Verify GPU device state and device-array mappings when requested
#ifdef XNET_GPU
    Call gpu_check_device(ierr,message)
    If ( ierr /= 0 ) Return
    If ( on_device ) Then
#ifdef XNET_OMP_OL
      ! OpenMP target work is not ordered on the vendor stream of the application.
      Call stream_sync(stream,stream_status)
      If ( stream_status /= 0 ) Then
        ierr = xnet_invalid
        Write(message,'(a,i0)') 'Cannot synchronize the application GPU stream, status ',stream_status
        Return
      EndIf
#endif
      Call check_device_batch(density,temperature,ye,mass_fraction,restart_dt_s,neutrino_loss, &
        & ierr,message,aux_x,aux_a,aux_z)
      If ( ierr /= 0 ) Return
      ! Clear the scientific output in its requested memory space, including rejected requests.
      !XDIR XLOOP_OUTER(1) XASYNC(gpu_queue) &
      !XDIR XPRESENT(neutrino_loss)
      Do lane = 1, Size(neutrino_loss)
        neutrino_loss(lane) = 0.0_dp
      EndDo
      !XDIR XWAIT(gpu_queue)
    EndIf
#else
    If ( on_device ) Then
      neutrino_loss = 0.0_dp
      ierr = xnet_unsupported
      message = 'Device-array burns require a supported GPU library build'
      Return
    EndIf
#endif

    ! 3. Validate batch extents, duration, and host-resident active inputs
    n = Size(active)
    Call validate_batch_extents(n,dt_s,zone_id,density,temperature,ye,mass_fraction, &
      & restart_dt_s,neutrino_loss,counters,ierr,message,aux_x,aux_a,aux_z)
    If ( ierr /= xnet_success ) Return

    If ( .not. on_device ) Then
      Call validate_host_inputs(n,active,density,temperature,ye,mass_fraction,restart_dt_s, &
        & ierr,message,aux_x,aux_a,aux_z)
      If ( ierr /= xnet_success ) Return
    EndIf

    If ( .not. Any(active) .and. .not. on_device ) Return

    ! 4. Configure worker-bank masks and zone identifiers
    before = current_timing()
    szbatch = 1
    nzbatch = Count(active)
    lzactive(zb_lo:zb_hi) = .false.
    lzactive(zb_lo:zb_lo+n-1) = active
    zone_work(:,zb_lo:zb_hi) = 0
    zone_work(1:Size(zone_id,1),zb_lo:zb_lo+n-1) = zone_id

    ! 5. Stage, evolve and collect in the requested memory space.
#ifdef XNET_GPU
    If ( on_device ) Then
      Call burn_device_arrays(dt_s,density,temperature,ye,mass_fraction,restart_dt_s,neutrino_loss, &
        & Size(zone_id,1),kstep,evolve_status,failed_zone,ierr,message,aux_x,aux_a,aux_z)
    Else
#endif
      Call burn_host_arrays(dt_s,active,density,temperature,ye,mass_fraction,restart_dt_s,neutrino_loss, &
        & Size(zone_id,1),aux_x,aux_a,aux_z,kstep,evolve_status,failed_zone,ierr,message)
#ifdef XNET_GPU
    EndIf
#endif
    If ( ierr /= xnet_success .or. .not. Any(active) ) Return

    ! Attempted counters remain useful even when numerical failure invalidates the physical result.
    Do lane = 1, n
      If ( active(lane) ) counters(:,lane) = ktot(:,zb_offset+lane)
    EndDo

    ! 6. Record per-call timing differences and format any numerical failure diagnostic
    If ( evolve_status == 0 .and. Present(max_steps_taken) ) max_steps_taken = kstep
    timing = elapsed_timing(before)
    If ( evolve_status /= 0 ) Then
      Call format_burn_failure(evolve_status,failed_zone-zb_offset,zone_id,ierr,message)
    EndIf

    Return
  End Subroutine xnet_burn_batch

  Subroutine xnet_nse_composition(density,temperature,ye,mass_fraction,ierr,message)
    !-----------------------------------------------------------------------------------------------
    ! Compute Nuclear Statistical Equilibrium mass fractions (A * ynse) in XNet species order for
    ! scalar density [g/cm^3], temperature [K], and electron fraction Ye.
    ! Copy without normalization or species mapping. NSE convergence failures remain fatal.
    !-----------------------------------------------------------------------------------------------
    Use, Intrinsic :: ieee_arithmetic, Only: ieee_is_finite
    Use nuclear_data, Only: aa, ny
    Use xnet_nse, Only: nse_solve, ynse
#ifdef XNET_GPU
    Use xnet_gpu, Only: gpu_check_device
#endif
    Implicit None

    ! Input/Output arguments
    Real(dp), Intent(in) :: density, temperature, ye
    Real(dp), Intent(out) :: mass_fraction(:)
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message

    mass_fraction = 0.0_dp
    message = ' '
    ierr = xnet_lifecycle_error
    If ( api_state /= api_ready ) Then
      message = 'Initialize XNet before requesting NSE composition'
      If ( api_state == api_cleanup_pending ) message = 'Finish XNet finalization before requesting NSE composition'
      Return
    EndIf
    Call check_worker(ierr,message)
    If ( ierr /= xnet_success ) Return
#ifdef XNET_GPU
    Call gpu_check_device(ierr,message)
    If ( ierr /= 0 ) Return
#endif
    ierr = xnet_invalid
    If ( Size(mass_fraction) /= ny ) Then
      message = 'NSE composition extent must match the initialized network'
      Return
    EndIf
    If ( .not. ieee_is_finite(density) .or. .not. ieee_is_finite(temperature) .or. &
      & .not. ieee_is_finite(ye) ) Then
      message = 'NSE density, temperature and Ye must be finite'
      Return
    EndIf
    If ( density <= 0.0_dp .or. temperature <= 0.0_dp .or. ye < 0.0_dp .or. ye > 1.0_dp ) Then
      message = 'NSE density and temperature must be positive and Ye must be in [0,1]'
      Return
    EndIf
    Call nse_solve(density,temperature*kelvin_to_gk,ye)
    ! Match the existing CHIMERA A*ynse convention without normalization or reordering.
    mass_fraction = aa * ynse
    ierr = xnet_success

    Return
  End Subroutine xnet_nse_composition

  Subroutine xnet_finalize(ierr,message)
    ! Release device mappings before their CPU allocations, then release owned GPU resources.
    ! Borrowed application resources and copied network metadata remain with the application.
    ! Call outside application parallel regions, with no work in flight and the initialized team.
    ! If GPU cleanup fails, repeat this call to retry only the resources that remain.
    ! After successful cleanup, repeated calls succeed without repeating teardown.
#ifdef XNET_GPU
    Use xnet_gpu, Only: gpu_check_device, gpu_finalize
#endif
    Implicit None
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message

    ierr = xnet_success
    message = ' '
    If ( api_state == api_uninitialized ) Return
#ifdef XNET_OMP
    Call check_finalize_team(ierr,message)
    If ( ierr /= xnet_success ) Return
#endif
    If ( api_state == api_ready ) Then
#ifdef XNET_GPU
      Call gpu_check_device(ierr,message)
      If ( ierr /= xnet_success ) Return
#endif
      Call unmap_workspace
      Call release_modules
      api_state = api_cleanup_pending
    EndIf
#ifdef XNET_GPU
    ! A failed cleanup can be retried without touching the released workspaces.
    Call gpu_finalize(ierr,message)
    If ( ierr /= xnet_success ) Return
#endif
    api_state = api_uninitialized
    Return
  End Subroutine xnet_finalize

  !=================================================================================================
  ! Private Initialization and Workspace Helpers
  !=================================================================================================

  Subroutine check_initializable(controls,gpu_requested,ierr,message)
    ! Reject unsupported lifecycle, controls and team settings before allocating resources.
    Use xnet_abundances, Only: y
    Use xnet_controls, Only: validate_xnet_controls
    Implicit None
    Type(xnet_controls_t), Intent(in) :: controls
    Logical, Intent(in) :: gpu_requested
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message

    ierr = xnet_invalid
    message = ' '
    If ( api_state /= api_uninitialized .or. Allocated(y) ) Then
      ierr = xnet_lifecycle_error
      message = 'XNet is already initialized'
      If ( api_state == api_cleanup_pending ) message = 'Finish XNet finalization before initialization'
      Return
    EndIf
#ifndef XNET_GPU
    If ( gpu_requested ) Then
      ierr = xnet_unsupported
      message = 'GPU resources require a supported GPU library build'
      Return
    EndIf
#endif
#ifdef XNET_OMP
    If ( omp_get_level() > 0 ) Then
      ierr = xnet_unsupported
      message = 'Initialize XNet outside application OpenMP regions'
      Return
    EndIf
    If ( omp_get_dynamic() ) Then
      ierr = xnet_unsupported
      message = 'Disable dynamic OpenMP teams before XNet initialization'
      Return
    EndIf
#endif

    Call validate_xnet_controls(controls,ierr,message)
    If ( ierr /= 0 ) Return
    ierr = xnet_invalid
    If ( Len_Trim(controls%data_dir) == 0 ) Then
      message = 'data_dir is required'
      Return
    EndIf
    If ( controls%ineutrino /= 0 ) Then
      ierr = xnet_unsupported
      message = 'Library calls do not support neutrino capture histories'
      Return
    EndIf

    ierr = xnet_success
    Return
  End Subroutine check_initializable

  Subroutine prepare_data_files(controls,ierr,message)
    ! Preprocessing writes data_dir; the host must arrange exclusive access to that directory.
    Use xnet_controls, Only: lun_stdout
    Use xnet_preprocess, Only: net_preprocess
    Implicit None
    Type(xnet_controls_t), Intent(in) :: controls
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message
    Character(10), Parameter :: ascii_files(3) = [Character(10) :: 'sunet', 'netwinv', 'netsu']
    Character(10), Parameter :: required_files(5) = &
      & [Character(10) :: 'sunet', 'netwinv', 'nets3', 'nets4', 'match_data']

    If ( controls%iprocess > 0 ) Then
      Call check_network_files(controls%data_dir,ascii_files,ierr,message)
      If ( ierr /= xnet_success ) Return
      Call net_preprocess(lun_stdout,controls%data_dir,controls%data_dir)
    EndIf
    Call check_network_files(controls%data_dir,required_files,ierr,message)
    Return
  End Subroutine prepare_data_files

  Subroutine check_network_files(data_dir,filenames,ierr,message)
    !-----------------------------------------------------------------------------------------------
    ! Verify that all required network files exist and can be opened for reading before state setup.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Input arguments
    Character(*), Intent(in) :: data_dir, filenames(:)

    ! Output arguments
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message

    ! Local variables
    Integer :: i, input_unit, input_status
    Logical :: exists

    ierr = xnet_invalid
    message = ' '
    Do i = 1, Size(filenames)
      Inquire(file=Trim(data_dir)//'/'//Trim(filenames(i)),exist=exists)
      If ( .not. exists ) Then
        message = 'Missing network file: '//Trim(filenames(i))
        Return
      EndIf
      Open(newunit=input_unit,file=Trim(data_dir)//'/'//Trim(filenames(i)), &
        & status='old',action='read',access='stream',form='unformatted',iostat=input_status)
      If ( input_status /= 0 ) Then
        message = 'Cannot read network file: '//Trim(filenames(i))
        Return
      EndIf
      Close(input_unit)
    EndDo
    ierr = xnet_success

    Return
  End Subroutine check_network_files

  Subroutine start_worker_team
    ! One XNet worker per application OpenMP thread, one process.
    Use xnet_controls, Only: myid, nproc, tid, nthread, sweep, lun_diag, lun_stdout
    Implicit None

    myid = 0
    nproc = 1
    nthread = 1
#ifdef XNET_OMP
    !$omp parallel default(shared)
#endif
    tid = 1
#ifdef XNET_OMP
    tid = omp_get_thread_num()+1
    !$omp single
    nthread = omp_get_num_threads()
    !$omp end single
#endif
    sweep = 'x'
    lun_diag = lun_stdout
#ifdef XNET_OMP
    !$omp end parallel
#endif
    Return
  End Subroutine start_worker_team

  Subroutine load_network(controls)
    ! Read the data files and bring up every module the burn depends on.
    Use nuclear_data, Only: ny, read_nuclear_data, index_from_name
    Use reaction_data, Only: read_reaction_data
    Use xnet_abundances, Only: abundances_initialize
    Use xnet_conditions, Only: conditions_initialize
    Use xnet_controls, Only: zone_id, nzevolve, lun_stdout, isolv, nnucout, output_nuc, inucout
    Use xnet_eos, Only: eos_initialize
    Use xnet_flux, Only: flux_init
    Use xnet_integrate_be, Only: be_init
    Use xnet_integrate_bdf, Only: bdf_init
    Use xnet_jacobian, Only: read_jacobian_data
    Use xnet_match, Only: read_match_data
    Use xnet_nnu, Only: tmevnu, fluxcms, nnuspec
    Use xnet_nse, Only: nse_initialize
    Use xnet_screening, Only: screening_init
    Implicit None
    Type(xnet_controls_t), Intent(in) :: controls
    Integer :: i, inuc

    ! Both real consumers carry diagnostic integer tuples, with three or four entries.
    Deallocate (zone_id)
    Allocate (zone_id(4,nzevolve))
    zone_id = 0
    Call read_nuclear_data(controls%data_dir,api_data_description)
    Call read_reaction_data(controls%data_dir)
    Call read_jacobian_data(controls%data_dir)
    Call read_match_data(controls%data_dir)
    Call screening_init
    Call flux_init
    Call eos_initialize
    If ( isolv == 1 ) Call be_init
    If ( isolv == 3 ) Call bdf_init
    ! Use the standalone species lookup and missing-name fallback for condensed output.
    If ( controls%itsout > 0 ) Then
      Do i = 1, nnucout
        Call index_from_name(output_nuc(i),inuc)
        If ( inuc < 1 .or. inuc > ny ) Then
          Write(lun_stdout,*) 'Output Nuc:',i,output_nuc(i),' not found'
          inucout(i) = ny
        Else
          inucout(i) = inuc
        EndIf
      EndDo
    EndIf
    Call nse_initialize
    Call abundances_initialize
    Call conditions_initialize(2)
    Allocate (tmevnu(2,nnuspec,nzevolve),fluxcms(2,nnuspec,nzevolve))
    tmevnu = 0.0_dp
    fluxcms = 0.0_dp
    Return
  End Subroutine load_network

  Subroutine describe_network(network)
    Use nuclear_data, Only: ny, nname, ia, iz, be, mex
    Implicit None
    Type(xnet_network_t), Intent(out) :: network

    Allocate (network%names(ny),network%mass_number(ny),network%charge_number(ny), &
      & network%binding_energy_mev(ny),network%mass_excess_mev(ny))
    network%names = nname(1:ny)
    network%mass_number = ia
    network%charge_number = iz
    network%binding_energy_mev = be
    network%mass_excess_mev = mex
    Return
  End Subroutine describe_network

  Subroutine map_workspace
    Use xnet_abundances, Only: y, yo, yt, ydot, ystart, xext, aext, zext
    Use xnet_conditions, Only: tdel, tdel_next, tdel_old, t, tt, to, t9, t9t, t9o, t9dot, &
      & rho, rhot, rhoo, ye, yet, yeo, cv, etae, detaedt9, nt, ntt, nto, ints, intso, &
      & tstart, tstop, tdelstart, nstart, t9start, rhostart, yestart, nh, th, t9h, rhoh, yeh
    Use xnet_controls, Only: gpu_queue
    Use xnet_nnu, Only: tmevnu, fluxcms
    Implicit None

    ! Keep the same reusable workspace as the standalone driver, with two history endpoints.
    !XDIR XENTER_DATA XASYNC(gpu_queue) &
    !XDIR XCOPYIN(y,yo,yt,ydot,ystart,xext,aext,zext) &
    !XDIR XCOPYIN(tdel,tdel_next,tdel_old,t,tt,to,t9,t9t,t9o,t9dot) &
    !XDIR XCOPYIN(rho,rhot,rhoo,ye,yet,yeo,cv,etae,detaedt9,nt,ntt,nto,ints,intso) &
    !XDIR XCOPYIN(tstart,tstop,tdelstart,nstart,t9start,rhostart,yestart) &
    !XDIR XCOPYIN(nh,th,t9h,rhoh,yeh,tmevnu,fluxcms)

    !XDIR XWAIT(gpu_queue)
    Return
  End Subroutine map_workspace

  Subroutine unmap_workspace
    ! Release the mappings established above before their owning CPU allocations.
    Use xnet_abundances, Only: y, yo, yt, ydot, ystart, xext, aext, zext
    Use xnet_conditions, Only: tdel, tdel_next, tdel_old, t, tt, to, t9, t9t, t9o, t9dot, &
      & rho, rhot, rhoo, ye, yet, yeo, cv, etae, detaedt9, nt, ntt, nto, ints, intso, &
      & tstart, tstop, tdelstart, nstart, t9start, rhostart, yestart, nh, th, t9h, rhoh, yeh
    Use xnet_controls, Only: gpu_queue
    Use xnet_nnu, Only: tmevnu, fluxcms
    Implicit None

    !XDIR XEXIT_DATA XASYNC(gpu_queue) &
    !XDIR XDELETE(y,yo,yt,ydot,ystart,xext,aext,zext) &
    !XDIR XDELETE(tdel,tdel_next,tdel_old,t,tt,to,t9,t9t,t9o,t9dot) &
    !XDIR XDELETE(rho,rhot,rhoo,ye,yet,yeo,cv,etae,detaedt9,nt,ntt,nto,ints,intso) &
    !XDIR XDELETE(tstart,tstop,tdelstart,nstart,t9start,rhostart,yestart) &
    !XDIR XDELETE(nh,th,t9h,rhoh,yeh,tmevnu,fluxcms)
    !XDIR XWAIT(gpu_queue)
    Return
  End Subroutine unmap_workspace

  Subroutine release_modules
    ! The reverse of load_network.
    Use nuclear_data, Only: nuclear_data_finalize
    Use reaction_data, Only: reaction_data_finalize
    Use xnet_abundances, Only: abundances_finalize
    Use xnet_conditions, Only: conditions_finalize
    Use xnet_controls, Only: controls_finalize
    Use xnet_eos, Only: eos_finalize
    Use xnet_ffn, Only: ffn_finalize
    Use xnet_flux, Only: flux_finalize
    Use xnet_integrate_be, Only: be_finalize
    Use xnet_integrate_bdf, Only: bdf_finalize
    Use xnet_jacobian, Only: jacobian_finalize
    Use xnet_match, Only: match_finalize
    Use xnet_nnu, Only: nnu_finalize
    Use xnet_nse, Only: nse_finalize
    Use xnet_screening, Only: screening_finalize
    Implicit None

    Call be_finalize
    Call bdf_finalize
    Call nse_finalize
    Call eos_finalize
    Call jacobian_finalize
    Call screening_finalize
    Call flux_finalize
    Call match_finalize
    Call ffn_finalize
    Call nnu_finalize
    Call reaction_data_finalize
    Call nuclear_data_finalize
    Call abundances_finalize
    Call conditions_finalize
    Call controls_finalize
    Return
  End Subroutine release_modules

#ifdef XNET_OMP
  Subroutine check_finalize_team(ierr,message)
    ! Finalization must use the fixed team established at initialization.
    Use xnet_controls, Only: nthread
    Implicit None
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message
    Integer :: final_threads

    ierr = xnet_success
    message = ' '
    If ( omp_get_level() > 0 .or. omp_get_dynamic() ) Then
      ierr = xnet_unsupported
      message = 'Finalize XNet outside application OpenMP regions with the initialized fixed team'
      Return
    EndIf
    !$omp parallel default(shared)
    !$omp single
    final_threads = omp_get_num_threads()
    !$omp end single
    !$omp end parallel
    If ( final_threads /= nthread ) Then
      ierr = xnet_unsupported
      message = 'Use the initialized OpenMP team size when finalizing XNet'
      Return
    EndIf
    Return
  End Subroutine check_finalize_team
#endif

  !=================================================================================================
  ! Private Worker Validation and Host Batch Execution
  !=================================================================================================

  Subroutine burn_host_arrays(dt_s,active,density,temperature,ye,mass_fraction,restart_dt_s,neutrino_loss, &
    & zone_id_components,aux_x,aux_a,aux_z,kstep,evolve_status,failed_zone,ierr,message)
    ! Copy validated host inputs into the current worker bank, evolve, and copy results back.
    Use nuclear_data, Only: aa
    Use xnet_abundances, Only: y, ystart, xext, aext, zext
    Use xnet_conditions, Only: t, t9, rho, ye_work=>ye, tdel, tdel_old, nt, nstart, &
      & tstart, tstop, tdelstart, t9start, rhostart, yestart, nh, th, t9h, rhoh, yeh
    Use xnet_controls, Only: lzactive, iheat, iaux, ktot, gpu_queue, zb_offset, zb_lo, zb_hi
    Use xnet_evolve, Only: full_net
    Implicit None
    Real(dp), Intent(in) :: dt_s, density(:)
    Logical, Intent(in) :: active(:)
    Real(dp), Intent(inout) :: temperature(:), ye(:), mass_fraction(:,:), restart_dt_s(:)
    Real(dp), Intent(inout) :: neutrino_loss(:)
    Integer, Intent(in) :: zone_id_components
    Real(dp), Optional, Intent(in) :: aux_x(:), aux_a(:), aux_z(:)
    Integer, Intent(out) :: kstep, evolve_status, failed_zone, ierr
    Character(*), Intent(out) :: message
    Real(dp), Allocatable :: loss_work(:)
    Integer :: lane, izb

    ! lane indexes caller arrays; izb = zb_offset + lane indexes this worker bank.
    ! Reset the full bank so a short or masked call cannot reuse the preceding batch state.
    ystart(:,zb_lo:zb_hi) = 0.0_dp
    xext(zb_lo:zb_hi) = 0.0_dp
    aext(zb_lo:zb_hi) = 1.0_dp
    zext(zb_lo:zb_hi) = 0.0_dp
    iaux(zb_lo:zb_hi) = 0
    ! The first endpoint is index one; zero can reach history element zero in timestep.
    nstart(zb_lo:zb_hi) = 1
    tstart(zb_lo:zb_hi) = 0.0_dp
    tstop(zb_lo:zb_hi) = dt_s
    tdelstart(zb_lo:zb_hi) = 0.0_dp
    t9start(zb_lo:zb_hi) = inactive_t9
    rhostart(zb_lo:zb_hi) = inactive_rho
    yestart(zb_lo:zb_hi) = inactive_ye
    Do lane = 1, Size(active)
      If ( .not. active(lane) ) Cycle
      izb = zb_offset+lane
      ystart(:,izb) = mass_fraction(:,lane) / aa
      t9start(izb) = temperature(lane) * kelvin_to_gk
      rhostart(izb) = density(lane)
      yestart(izb) = ye(lane)
      ! Preserve the CHIMERA startup hint convention without exposing its sign encoding.
      tdelstart(izb) = -restart_dt_s(lane)
      If ( Present(aux_x) ) Then
        If ( aux_x(lane) > 0.0_dp ) Then
          xext(izb) = aux_x(lane)
          aext(izb) = aux_a(lane)
          zext(izb) = aux_z(lane)
          iaux(izb) = 1
        EndIf
      EndIf
    EndDo
    ! Constant conditions: both history endpoints carry the start values.
    nh(zb_lo:zb_hi) = 2
    th(1,zb_lo:zb_hi) = tstart(zb_lo:zb_hi)
    th(2,zb_lo:zb_hi) = tstop(zb_lo:zb_hi)
    t9h(1,zb_lo:zb_hi) = t9start(zb_lo:zb_hi)
    t9h(2,zb_lo:zb_hi) = t9start(zb_lo:zb_hi)
    rhoh(1,zb_lo:zb_hi) = rhostart(zb_lo:zb_hi)
    rhoh(2,zb_lo:zb_hi) = rhostart(zb_lo:zb_hi)
    yeh(1,zb_lo:zb_hi) = yestart(zb_lo:zb_hi)
    yeh(2,zb_lo:zb_hi) = yestart(zb_lo:zb_hi)
    tdel(zb_lo:zb_hi) = 0.0_dp
    nt(zb_lo:zb_hi) = nstart(zb_lo:zb_hi)
    t(zb_lo:zb_hi) = tstart(zb_lo:zb_hi)
    t9(zb_lo:zb_hi) = t9start(zb_lo:zb_hi)
    rho(zb_lo:zb_hi) = rhostart(zb_lo:zb_hi)
    ye_work(zb_lo:zb_hi) = yestart(zb_lo:zb_hi)
    y(:,zb_lo:zb_hi) = ystart(:,zb_lo:zb_hi)

    kstep = 0
    evolve_status = 0
    failed_zone = 0
    Call open_burn_output(zone_id_components,ierr,message)
    If ( ierr /= xnet_success ) Return

    ! Host inputs remain authoritative even when the caller has stale device mappings.
    ! Transfer only XNet-owned workspace; arbitrary host array sections retain their existing behavior.
    !XDIR XUPDATE XASYNC(gpu_queue) &
    !XDIR XDEVICE(xext,aext,zext,lzactive,tdel,t,t9,rho,ye_work,y,nt) &
    !XDIR XDEVICE(tstart,tstop,tdelstart,nstart,t9start,rhostart,yestart,ystart) &
    !XDIR XDEVICE(nh,th,t9h,rhoh,yeh)

    Allocate (loss_work(zb_lo:zb_hi))
    Call full_net(kstep,loss_work,evolve_status,failed_zone)
    Call close_burn_output
    ! API results do not depend on diagnostic verbosity or successful final output.
    !XDIR XUPDATE XWAIT(gpu_queue) &
    !XDIR XHOST(ktot)
    If ( evolve_status == 0 ) Then
      !XDIR XUPDATE XWAIT(gpu_queue) &
      !XDIR XHOST(y,t9,ye_work,tdel_old)
      Do lane = 1, Size(active)
        If ( .not. active(lane) ) Cycle
        izb = zb_offset+lane
        mass_fraction(:,lane) = y(:,izb) * aa
        If ( iheat > 0 ) temperature(lane) = t9(izb) * gk_to_kelvin
        ye(lane) = ye_work(izb)
        restart_dt_s(lane) = tdel_old(izb)
        neutrino_loss(lane) = loss_work(izb)
      EndDo
    EndIf
    Deallocate (loss_work)
    Return
  End Subroutine burn_host_arrays

  Subroutine check_worker(ierr,message)
    !-----------------------------------------------------------------------------------------------
    ! Verify the OpenMP team topology and bind the disjoint batch bank (zb_lo:zb_hi) of the caller.
    !-----------------------------------------------------------------------------------------------
    Use xnet_controls, Only: nthread, nzbatchmx, tid, zb_hi, zb_lo, zb_offset
    Use xnet_nse, Only: ynse
    Implicit None

    ! Output arguments
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message

    ierr = xnet_success
    message = ' '
#ifdef XNET_OMP
    If ( omp_get_dynamic() .or. omp_get_level() > 1 ) Then
      ierr = xnet_unsupported
      message = 'XNet requires a fixed, nonnested OpenMP worker team'
      Return
    EndIf
    If ( omp_get_level() > 0 ) Then
      If ( omp_get_num_threads() /= nthread ) Then
        ierr = xnet_unsupported
        message = 'Use the same OpenMP team size as XNet initialization'
        Return
      EndIf
    EndIf
    tid = omp_get_thread_num()+1
#endif
    If ( tid < 1 .or. tid > nthread .or. .not. Allocated(ynse) ) Then
      ierr = xnet_lifecycle_error
      message = 'This XNet worker is not initialized; keep the initialized OpenMP team'
      Return
    EndIf
    zb_offset = (tid-1)*nzbatchmx
    zb_lo = zb_offset+1
    zb_hi = zb_offset+nzbatchmx

    Return
  End Subroutine check_worker

  Subroutine validate_batch_extents(n,dt_s,zone_id,density,temperature,ye,mass_fraction, &
    & restart_dt_s,neutrino_loss,counters,ierr,message,aux_x,aux_a,aux_z)
    !-----------------------------------------------------------------------------------------------
    ! Validate batch array shapes, auxiliary argument pairing, and burn duration.
    !-----------------------------------------------------------------------------------------------
    Use, Intrinsic :: ieee_arithmetic, Only: ieee_is_finite
    Use nuclear_data, Only: ny
    Use xnet_controls, Only: nzbatchmx
    Implicit None

    ! Input arguments
    Integer, Intent(in) :: n
    Real(dp), Intent(in) :: dt_s
    Integer, Intent(in) :: zone_id(:,:), counters(:,:)
    Real(dp), Intent(in) :: density(:), temperature(:), ye(:), mass_fraction(:,:)
    Real(dp), Intent(in) :: restart_dt_s(:), neutrino_loss(:)
    Real(dp), Optional, Intent(in) :: aux_x(:), aux_a(:), aux_z(:)

    ! Output arguments
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message

    ierr = xnet_invalid
    message = ' '
    If ( n > nzbatchmx .or. Size(density) /= n .or. Size(temperature) /= n .or. &
      & Size(ye) /= n .or. Size(restart_dt_s) /= n .or. Size(neutrino_loss) /= n .or. &
      & Size(mass_fraction,1) /= ny .or. Size(mass_fraction,2) /= n .or. &
      & Size(counters,1) /= 5 .or. Size(counters,2) /= n .or. Size(zone_id,2) /= n .or. &
      & (Size(zone_id,1) /= 3 .and. Size(zone_id,1) /= 4) ) Then
      message = 'Inconsistent batch dimensions or batch larger than nzbatchmx'
      Return
    EndIf
    If ( .not. ieee_is_finite(dt_s) ) Then
      message = 'Burn duration must be finite and positive'
      Return
    EndIf
    If ( dt_s <= 0.0_dp ) Then
      message = 'Burn duration must be finite and positive'
      Return
    EndIf
    If ( (Present(aux_x) .neqv. Present(aux_a)) .or. (Present(aux_x) .neqv. Present(aux_z)) ) Then
      message = 'Supply auxiliary mass fraction, A and Z together'
      Return
    EndIf
    If ( Present(aux_x) ) Then
      If ( Size(aux_x) /= n .or. Size(aux_a) /= n .or. Size(aux_z) /= n ) Then
        message = 'Inconsistent auxiliary dimensions'
        Return
      EndIf
    EndIf
    ierr = xnet_success

    Return
  End Subroutine validate_batch_extents

  Subroutine validate_host_inputs(n,active,density,temperature,ye,mass_fraction,restart_dt_s, &
    & ierr,message,aux_x,aux_a,aux_z)
    !-----------------------------------------------------------------------------------------------
    ! Validate finiteness and physical ranges for all active lanes in a host-resident batch.
    ! Inactive lanes are not read.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Input arguments
    Integer, Intent(in) :: n
    Logical, Intent(in) :: active(:)
    Real(dp), Intent(in) :: density(:), temperature(:), ye(:), mass_fraction(:,:), restart_dt_s(:)
    Real(dp), Optional, Intent(in) :: aux_x(:), aux_a(:), aux_z(:)

    ! Output arguments
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message

    Integer :: lane, validation_status

    ierr = xnet_invalid
    message = ' '
    Do lane = 1, n
      If ( .not. active(lane) ) Cycle
      validation_status = host_lane_status(density(lane),temperature(lane),ye(lane),mass_fraction(:,lane), &
        & restart_dt_s(lane),aux_x,aux_a,aux_z,lane)
      If ( validation_status /= lane_ok ) Then
        message = lane_error_message(validation_status)
        Return
      EndIf
    EndDo
    ierr = xnet_success

    Return
  End Subroutine validate_host_inputs

  Integer Function host_lane_status(density,temperature,ye,x,restart_dt_s,aux_x,aux_a,aux_z,lane)
    ! Check one active lane; keep the order consistent with the device validator.
    Use, Intrinsic :: ieee_arithmetic, Only: ieee_is_finite
    Implicit None
    Real(dp), Intent(in) :: density, temperature, ye, x(:), restart_dt_s
    Real(dp), Optional, Intent(in) :: aux_x(:), aux_a(:), aux_z(:)
    Integer, Intent(in) :: lane
    Real(dp) :: total_mass

    host_lane_status = lane_not_finite
    If ( .not. (ieee_is_finite(density) .and. ieee_is_finite(temperature) .and. ieee_is_finite(ye) .and. &
      & ieee_is_finite(restart_dt_s) .and. All(ieee_is_finite(x))) ) Return
    host_lane_status = lane_out_of_range
    If ( density <= 0.0_dp .or. temperature <= 0.0_dp .or. ye < 0.0_dp .or. ye > 1.0_dp .or. &
      & restart_dt_s < 0.0_dp .or. Any(x < 0.0_dp) ) Return
    total_mass = Sum(x)
    If ( Present(aux_x) ) Then
      host_lane_status = lane_aux_not_finite
      If ( .not. (ieee_is_finite(aux_x(lane)) .and. ieee_is_finite(aux_a(lane)) .and. ieee_is_finite(aux_z(lane))) ) Return
      host_lane_status = lane_aux_out_of_range
      If ( aux_x(lane) < 0.0_dp .or. aux_x(lane) > 1.0_dp .or. aux_a(lane) < 0.0_dp .or. &
        & aux_z(lane) < 0.0_dp .or. aux_z(lane) > aux_a(lane) ) Return
      host_lane_status = lane_aux_needs_a
      If ( aux_x(lane) > 0.0_dp .and. aux_a(lane) <= 0.0_dp ) Return
      total_mass = total_mass + aux_x(lane)
    EndIf
    host_lane_status = lane_no_mass
    If ( total_mass <= 0.0_dp ) Return
    host_lane_status = lane_ok
    Return
  End Function host_lane_status

  Function lane_error_message(verdict) Result(text)
    Implicit None
    Integer, Intent(in) :: verdict
    Character(80) :: text

    Select Case (verdict)
    Case (lane_not_finite)
      text = 'Active-zone inputs must be finite'
    Case (lane_out_of_range)
      text = 'Invalid active-zone density, temperature, Ye, composition or restart timestep'
    Case (lane_aux_not_finite)
      text = 'Active-zone auxiliary inputs must be finite'
    Case (lane_aux_out_of_range)
      text = 'Invalid auxiliary mass fraction, A or Z'
    Case (lane_aux_needs_a)
      text = 'Positive auxiliary mass requires positive A'
    Case (lane_no_mass)
      text = 'Active-zone composition must contain positive mass'
    Case Default
      text = ' '
    End Select
    Return
  End Function lane_error_message

  Subroutine format_burn_failure(evolve_status,failed_lane,zone_id,ierr,message)
    !-----------------------------------------------------------------------------------------------
    ! Translate an internal full_net failure status into the public status code and zone diagnostic.
    !-----------------------------------------------------------------------------------------------
    Use xnet_evolve, Only: evolve_integrator_failure, evolve_step_limit
    Implicit None

    ! Input arguments
    Integer, Intent(in) :: evolve_status, failed_lane
    Integer, Intent(in) :: zone_id(:,:)

    ! Output arguments
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message

    ! Local variables
    Integer :: id
    Character(128) :: failure_ids
    Character(32) :: id_component
    Character(512) :: failure_message
    Character(80) :: failure_reason

    failure_reason = ' '
    Select Case (evolve_status)
    Case (evolve_integrator_failure)
      ierr = xnet_integrator_failure
      failure_reason = 'integrator-reported convergence/timestep failure; host must terminate'
    Case (evolve_step_limit)
      ierr = xnet_step_limit
      failure_reason = 'maximum integration steps reached; host must terminate'
    End Select

    Write(failure_ids,'(i0)') zone_id(1,failed_lane)
    Do id = 2, Size(zone_id,1)
      Write(id_component,'(i0)') zone_id(id,failed_lane)
      failure_ids = Trim(failure_ids)//' '//Trim(id_component)
    EndDo
    Write(failure_message,'(a,i0,4a)') 'Zone ',failed_lane,', zone IDs [', &
      & Trim(failure_ids),']: ',Trim(failure_reason)
    message = failure_message

    Return
  End Subroutine format_burn_failure

  !=================================================================================================
  ! Private Device Mapping, Validation and Batch Execution
  !=================================================================================================

#ifdef XNET_GPU
  Subroutine check_device_batch(density,temperature,ye,mass_fraction,restart_dt_s,neutrino_loss, &
    & ierr,message,aux_x,aux_a,aux_z)
    !-----------------------------------------------------------------------------------------------
    ! Verify that all scientific arrays for a device-resident burn are contiguous and mapped on
    ! the active device.
    !-----------------------------------------------------------------------------------------------
    Use, Intrinsic :: iso_c_binding, Only: C_LOC, C_SIZEOF, C_SIZE_T
    Use xnet_gpu, Only: device_is_present, mydevice
    Implicit None

    ! Input/Output arguments
    Real(dp), Target, Intent(in) :: density(:), temperature(:), ye(:), mass_fraction(:,:), restart_dt_s(:)
    Real(dp), Target, Intent(out) :: neutrino_loss(:)
    Real(dp), Optional, Target, Intent(in) :: aux_x(:), aux_a(:), aux_z(:)
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message

    ! Local constants and variables
    Integer(C_SIZE_T), Parameter :: real_bytes = C_SIZEOF(0.0_dp)
    Logical :: mapped

    ierr = xnet_invalid
    message = 'Device-array burns require contiguous scientific arrays'
    If ( .not. Is_Contiguous(density) .or. .not. Is_Contiguous(temperature) .or. &
      & .not. Is_Contiguous(ye) .or. .not. Is_Contiguous(mass_fraction) .or. &
      & .not. Is_Contiguous(restart_dt_s) .or. .not. Is_Contiguous(neutrino_loss) ) Return
    If ( Present(aux_x) ) Then
      If ( .not. Is_Contiguous(aux_x) ) Return
    EndIf
    If ( Present(aux_a) ) Then
      If ( .not. Is_Contiguous(aux_a) ) Return
    EndIf
    If ( Present(aux_z) ) Then
      If ( .not. Is_Contiguous(aux_z) ) Return
    EndIf

    message = 'Device-array burns require every scientific array mapped on the selected device'
    mapped = .true.
    If ( Size(density) > 0 ) mapped = mapped .and. &
      & device_is_present(C_LOC(density(1)),mydevice,Int(Size(density),C_SIZE_T)*real_bytes)
    If ( Size(temperature) > 0 ) mapped = mapped .and. &
      & device_is_present(C_LOC(temperature(1)),mydevice,Int(Size(temperature),C_SIZE_T)*real_bytes)
    If ( Size(ye) > 0 ) mapped = mapped .and. &
      & device_is_present(C_LOC(ye(1)),mydevice,Int(Size(ye),C_SIZE_T)*real_bytes)
    If ( Size(mass_fraction) > 0 ) mapped = mapped .and. &
      & device_is_present(C_LOC(mass_fraction(1,1)),mydevice,Int(Size(mass_fraction),C_SIZE_T)*real_bytes)
    If ( Size(restart_dt_s) > 0 ) mapped = mapped .and. &
      & device_is_present(C_LOC(restart_dt_s(1)),mydevice,Int(Size(restart_dt_s),C_SIZE_T)*real_bytes)
    If ( Size(neutrino_loss) > 0 ) mapped = mapped .and. &
      & device_is_present(C_LOC(neutrino_loss(1)),mydevice,Int(Size(neutrino_loss),C_SIZE_T)*real_bytes)
    If ( Present(aux_x) ) Then
      If ( Size(aux_x) > 0 ) mapped = mapped .and. &
        & device_is_present(C_LOC(aux_x(1)),mydevice,Int(Size(aux_x),C_SIZE_T)*real_bytes)
    EndIf
    If ( Present(aux_a) ) Then
      If ( Size(aux_a) > 0 ) mapped = mapped .and. &
        & device_is_present(C_LOC(aux_a(1)),mydevice,Int(Size(aux_a),C_SIZE_T)*real_bytes)
    EndIf
    If ( Present(aux_z) ) Then
      If ( Size(aux_z) > 0 ) mapped = mapped .and. &
        & device_is_present(C_LOC(aux_z(1)),mydevice,Int(Size(aux_z),C_SIZE_T)*real_bytes)
    EndIf
    If ( .not. mapped ) Return

    ierr = xnet_success
    message = ' '

    Return
  End Subroutine check_device_batch

  Subroutine burn_device_arrays(dt_s,density,temperature,ye,mass_fraction,restart_dt_s,neutrino_loss, &
    & zone_id_components,kstep,evolve_status,failed_zone,ierr,message,aux_x,aux_a,aux_z)
    !-----------------------------------------------------------------------------------------------
    ! Validate, stage, evolve, and extract device-resident scientific arrays directly on the GPU.
    !-----------------------------------------------------------------------------------------------
    Use nuclear_data, Only: aa, ny
    Use xnet_abundances, Only: aext, xext, y, ystart, zext
    Use xnet_conditions, Only: nh, nstart, nt, rho, rhoh, rhostart, t, t9, t9h, t9start, &
      & tdel, tdel_old, tdelstart, th, tstart, tstop, ye_work=>ye, yeh, yestart
    Use xnet_controls, Only: gpu_queue, iheat, ktot, lzactive, nzevolve
    Use xnet_evolve, Only: full_net
    Implicit None

    ! Input/Output arguments
    Real(dp), Intent(in) :: dt_s, density(:)
    Real(dp), Intent(inout) :: temperature(:), ye(:), mass_fraction(:,:), restart_dt_s(:)
    Real(dp), Intent(out) :: neutrino_loss(:)
    Real(dp), Optional, Intent(in) :: aux_x(:), aux_a(:), aux_z(:)
    Integer, Intent(in) :: zone_id_components
    Integer, Intent(out) :: kstep, evolve_status, failed_zone, ierr
    Character(*), Intent(out) :: message

    ! Local variables
    Integer :: n, lane, k
    Integer, Allocatable :: validation(:)
    Real(dp), Allocatable :: mass_sum(:), loss_work(:)
    Real(dp) :: total_mass
    Logical :: finite_state, negative_mass

    n = Size(density)
    ! full_net checks the stop time on the host after updating its completion status.
    tstop = dt_s
    kstep = 0
    evolve_status = 0
    failed_zone = 0
    ierr = xnet_success
    message = ' '
    If ( n == 0 ) Return

    Allocate (validation(n),mass_sum(n),loss_work(nzevolve))
    ! Increment existing mapping references without copying stale host scientific values.
    ! Matching releases below leave every caller-owned mapping in place.
    !XDIR XENTER_DATA XASYNC(gpu_queue) &
    !XDIR XCOPYIN(density,temperature,ye,mass_fraction,restart_dt_s) &
    !XDIR XCREATE(neutrino_loss,validation,mass_sum,loss_work)
    If ( Present(aux_x) ) Then
      !XDIR XENTER_DATA XASYNC(gpu_queue) &
      !XDIR XCOPYIN(aux_x,aux_a,aux_z)
    EndIf
    !XDIR XUPDATE XASYNC(gpu_queue) &
    !XDIR XDEVICE(lzactive)

    !XDIR XLOOP_OUTER(1) XASYNC(gpu_queue) &
    !XDIR XPRESENT(lzactive,validation,mass_sum,density,temperature,ye,mass_fraction,restart_dt_s) &
    !XDIR XPRIVATE(total_mass,finite_state,negative_mass)
    Do lane = 1, n
      validation(lane) = lane_ok
      mass_sum(lane) = 0.0_dp
      If ( .not. lzactive(lane) ) Cycle
      ! NVHPC 26.5 cannot link IEEE_IS_FINITE in this OpenACC loop.
      ! Ordered comparisons also reject NaN and infinity without a device helper.
      finite_state = Abs(density(lane)) <= Huge(1.0_dp) .and. Abs(temperature(lane)) <= Huge(1.0_dp) .and. &
        & Abs(ye(lane)) <= Huge(1.0_dp) .and. Abs(restart_dt_s(lane)) <= Huge(1.0_dp)
      negative_mass = .false.
      total_mass = 0.0_dp
      !XDIR XLOOP_SERIAL(1)
      Do k = 1, ny
        finite_state = finite_state .and. Abs(mass_fraction(k,lane)) <= Huge(1.0_dp)
        negative_mass = negative_mass .or. mass_fraction(k,lane) < 0.0_dp
        total_mass = total_mass + mass_fraction(k,lane)
      EndDo
      mass_sum(lane) = total_mass
      If ( .not. finite_state ) Then
        validation(lane) = lane_not_finite
      ElseIf ( density(lane) <= 0.0_dp .or. temperature(lane) <= 0.0_dp .or. &
        & ye(lane) < 0.0_dp .or. ye(lane) > 1.0_dp .or. restart_dt_s(lane) < 0.0_dp .or. negative_mass ) Then
        validation(lane) = lane_out_of_range
      EndIf
    EndDo

    If ( Present(aux_x) ) Then
      !XDIR XLOOP_OUTER(1) XASYNC(gpu_queue) &
      !XDIR XPRESENT(lzactive,validation,mass_sum,aux_x,aux_a,aux_z) &
      !XDIR XPRIVATE(finite_state)
      Do lane = 1, n
        If ( .not. lzactive(lane) .or. validation(lane) /= lane_ok ) Cycle
        finite_state = Abs(aux_x(lane)) <= Huge(1.0_dp) .and. Abs(aux_a(lane)) <= Huge(1.0_dp) .and. &
          & Abs(aux_z(lane)) <= Huge(1.0_dp)
        If ( .not. finite_state ) Then
          validation(lane) = lane_aux_not_finite
        ElseIf ( aux_x(lane) < 0.0_dp .or. aux_x(lane) > 1.0_dp .or. aux_a(lane) < 0.0_dp .or. &
          & aux_z(lane) < 0.0_dp .or. aux_z(lane) > aux_a(lane) ) Then
          validation(lane) = lane_aux_out_of_range
        ElseIf ( aux_x(lane) > 0.0_dp .and. aux_a(lane) <= 0.0_dp ) Then
          validation(lane) = lane_aux_needs_a
        ElseIf ( mass_sum(lane) + aux_x(lane) <= 0.0_dp ) Then
          validation(lane) = lane_no_mass
        EndIf
      EndDo
    Else
      !XDIR XLOOP_OUTER(1) XASYNC(gpu_queue) &
      !XDIR XPRESENT(lzactive,validation,mass_sum)
      Do lane = 1, n
        If ( lzactive(lane) .and. validation(lane) == lane_ok .and. mass_sum(lane) <= 0.0_dp ) validation(lane) = lane_no_mass
      EndDo
    EndIf

    !XDIR XUPDATE XWAIT(gpu_queue) &
    !XDIR XHOST(validation)

    device_burn: Do
      Do lane = 1, n
        If ( validation(lane) == lane_ok ) Cycle
        ierr = xnet_invalid
        message = lane_error_message(validation(lane))
        Exit device_burn
      EndDo
      If ( .not. Any(lzactive) ) Exit device_burn

      ! Initialize inactive workspace lanes with benign values without reading their scientific inputs.
      ! Guard active-lane reads with (lane <= n) so short batches (n < nzevolve) never read past n.
      !XDIR XLOOP_OUTER(1) XASYNC(gpu_queue) &
      !XDIR XPRESENT(lzactive,aa,ystart,xext,aext,zext,nstart,tstart,tstop,tdelstart,t9start,rhostart,yestart) &
      !XDIR XPRESENT(nh,th,t9h,rhoh,yeh,tdel,nt,t,t9,rho,ye_work,y) &
      !XDIR XPRESENT(density,temperature,ye,mass_fraction,restart_dt_s)
      Do lane = 1, nzevolve
        xext(lane) = 0.0_dp
        aext(lane) = 1.0_dp
        zext(lane) = 0.0_dp
        nstart(lane) = 1
        tstart(lane) = 0.0_dp
        tstop(lane) = dt_s
        tdelstart(lane) = 0.0_dp
        t9start(lane) = inactive_t9
        rhostart(lane) = inactive_rho
        yestart(lane) = inactive_ye
        !XDIR XLOOP_SERIAL(1)
        Do k = 1, ny
          ystart(k,lane) = 0.0_dp
        EndDo
        If ( lane <= n ) Then
          If ( lzactive(lane) ) Then
            !XDIR XLOOP_SERIAL(1)
            Do k = 1, ny
              ystart(k,lane) = mass_fraction(k,lane) / aa(k)
            EndDo
            t9start(lane) = temperature(lane) * kelvin_to_gk
            rhostart(lane) = density(lane)
            yestart(lane) = ye(lane)
            tdelstart(lane) = -restart_dt_s(lane)
          EndIf
        EndIf
        nh(lane) = 2
        th(1,lane) = tstart(lane)
        th(2,lane) = tstop(lane)
        t9h(1,lane) = t9start(lane)
        t9h(2,lane) = t9start(lane)
        rhoh(1,lane) = rhostart(lane)
        rhoh(2,lane) = rhostart(lane)
        yeh(1,lane) = yestart(lane)
        yeh(2,lane) = yestart(lane)
        tdel(lane) = 0.0_dp
        nt(lane) = nstart(lane)
        t(lane) = tstart(lane)
        t9(lane) = t9start(lane)
        rho(lane) = rhostart(lane)
        ye_work(lane) = yestart(lane)
        !XDIR XLOOP_SERIAL(1)
        Do k = 1, ny
          y(k,lane) = ystart(k,lane)
        EndDo
      EndDo

      If ( Present(aux_x) ) Then
        !XDIR XLOOP_OUTER(1) XASYNC(gpu_queue) &
        !XDIR XPRESENT(lzactive,xext,aext,zext,aux_x,aux_a,aux_z)
        Do lane = 1, n
          If ( .not. lzactive(lane) ) Cycle
          If ( aux_x(lane) > 0.0_dp ) Then
            xext(lane) = aux_x(lane)
            aext(lane) = aux_a(lane)
            zext(lane) = aux_z(lane)
          EndIf
        EndDo
      EndIf

      Call open_burn_output(zone_id_components,ierr,message)
      If ( ierr /= xnet_success ) Exit device_burn

      Call full_net(kstep,loss_work,evolve_status,failed_zone)
      Call close_burn_output

      ! Attempted counters are host diagnostics even when the physical result is invalid.
      !XDIR XUPDATE XWAIT(gpu_queue) &
      !XDIR XHOST(ktot)
      If ( evolve_status == 0 ) Then
        !XDIR XLOOP_OUTER(1) XASYNC(gpu_queue) &
        !XDIR XPRESENT(lzactive,aa,y,t9,ye_work,tdel_old,loss_work) &
        !XDIR XPRESENT(temperature,ye,mass_fraction,restart_dt_s,neutrino_loss)
        Do lane = 1, n
          If ( .not. lzactive(lane) ) Cycle
          !XDIR XLOOP_SERIAL(1)
          Do k = 1, ny
            mass_fraction(k,lane) = y(k,lane) * aa(k)
          EndDo
          If ( iheat > 0 ) temperature(lane) = t9(lane) * gk_to_kelvin
          ye(lane) = ye_work(lane)
          restart_dt_s(lane) = tdel_old(lane)
          neutrino_loss(lane) = loss_work(lane)
        EndDo
      EndIf
      Exit device_burn
    EndDo device_burn

    If ( Present(aux_x) ) Then
      !XDIR XEXIT_DATA XASYNC(gpu_queue) &
      !XDIR XDELETE(aux_x,aux_a,aux_z)
    EndIf
    !XDIR XEXIT_DATA XASYNC(gpu_queue) &
    !XDIR XDELETE(density,temperature,ye,mass_fraction,restart_dt_s,neutrino_loss) &
    !XDIR XDELETE(validation,mass_sum,loss_work)
    !XDIR XWAIT(gpu_queue)
    Deallocate (validation,mass_sum,loss_work)

    Return
  End Subroutine burn_device_arrays
#endif


  !=================================================================================================
  ! Private Time-series Output and Per-call Timing
  !=================================================================================================

  Subroutine open_burn_output(zone_id_components,ierr,message)
    ! Each call has its own local 0..dt history. Lane numbers distinguish repeated diagnostic IDs.
    Use nuclear_data, Only: ny, zz, aa, nname
    Use xnet_controls, Only: itsout, lzactive, lun_ts, lun_ev, bin_file_base, ev_file_base, zone_id, &
      & zb_offset, zb_lo, zb_hi, descript, kstmx, kitmx, iweak0, iscrn, iconvc, changemx, tolm, tolc, yacc, ymin, &
      & tdel_maxmult, iheat, isolv, nnucout, nnucout_string, inucout
    Use xnet_flux, Only: flx, ifl_orig, ifl_term
    Use xnet_match, Only: mflx
    Implicit None
    Integer, Intent(in) :: zone_id_components
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message
    ! Match the standalone binary header field widths, including programmatic input descriptions.
    Character(80), Parameter :: input_name = 'XNet API input arrays'
    Character(80), Parameter :: abundance_description = 'Mass fractions in XNet species order'
    Character(80), Parameter :: thermo_description = 'Constant conditions; local time 0..dt seconds'
    Character(256) :: filename
    Character(80) :: zone_label
    Character(64) :: suffix
    Character(40) :: header_format
    Integer :: lane, i, output_status
    Integer(i8) :: call_number

    ierr = xnet_success
    message = ' '
    If ( itsout <= 0 .or. .not. Any(lzactive(zb_lo:zb_hi)) ) Return
    ierr = xnet_invalid
    ! Reserve one number for this call; do not serialize file writes or evolution.
    call_number = 0_i8
    !$omp critical(xnet_output_call)
    If ( output_call < Huge(output_call) ) Then
      output_call = output_call+1_i8
      call_number = output_call
    EndIf
    !$omp end critical(xnet_output_call)
    If ( call_number == 0_i8 ) Then
      message = 'Time-series call number exhausted'
      Return
    EndIf
    Do lane = zb_lo, zb_hi
      If ( .not. lzactive(lane) ) Cycle
      Write(suffix,'(a,i0,a,i0)') '_call',call_number,'_lane',lane-zb_offset
      filename = Trim(bin_file_base)//Trim(suffix)
      Open(newunit=lun_ts(lane),file=Trim(filename),status='new',form='unformatted', &
        & action='write',iostat=output_status)
      If ( output_status /= 0 ) Exit
      Write(lun_ts(lane)) descript,api_data_description
      Write(lun_ts(lane)) kstmx,kitmx,iweak0,iscrn,iconvc,changemx,tolm,tolc,yacc,ymin,tdel_maxmult,iheat,isolv
      ! Identify the caller zone in the existing input label; keep the record layout.
      Write(zone_label,'(a,4(1x,i0))') 'XNet API zone_id:',zone_id(1:zone_id_components,lane)
      Write(lun_ts(lane)) zone_label,abundance_description
      Write(lun_ts(lane)) input_name,thermo_description
      Write(lun_ts(lane)) ny,zz,aa
      Write(lun_ts(lane)) mflx,ifl_orig,ifl_term
      If ( itsout >= 2 ) Then
        filename = Trim(ev_file_base)//Trim(suffix)
        Open(newunit=lun_ev(lane),file=Trim(filename),status='new',action='write',iostat=output_status)
        If ( output_status /= 0 ) Exit
        header_format = '(a4,a15,5a10,a4)'
        If ( nnucout > 0 ) header_format = '(a4,a15,5a10,'//Trim(nnucout_string)//'a9,a4)'
        Write(lun_ev(lane),header_format) &
          & 'k ',' Time ',' T(GK) ',' Density ',' dE/dt ',' sqnu ',' Timestep ',(nname(inucout(i)),i=1,nnucout),' It '
      EndIf
    EndDo
    If ( output_status /= 0 ) Then
      ! A partially opened set is kept for diagnosis, with no burn performed and no units left open.
      Call close_burn_output
      message = 'Cannot create time-series file: '//Trim(filename)
      Return
    EndIf
    ! The initial snapshot has no reaction flux; do not reuse the preceding burn's final flux.
    flx(:,zb_lo:zb_hi) = 0.0_dp
    ierr = xnet_success
    Return
  End Subroutine open_burn_output

  Subroutine close_burn_output
    !-----------------------------------------------------------------------------------------------
    ! Close any open binary or ASCII time-series logical units in the current worker bank.
    !-----------------------------------------------------------------------------------------------
    Use xnet_controls, Only: lun_ev, lun_ts, zb_hi, zb_lo
    Implicit None

    ! Local variables
    Integer :: lane

    Do lane = zb_lo, zb_hi
      ! NEWUNIT may return negative units. Zero alone denotes an unopened API output slot.
      If ( lun_ts(lane) /= 0 ) Close(lun_ts(lane))
      If ( lun_ev(lane) /= 0 ) Close(lun_ev(lane))
      lun_ts(lane) = 0
      lun_ev(lane) = 0
    EndDo

    Return
  End Subroutine close_burn_output

  Function current_timing() Result(timing)
    !-----------------------------------------------------------------------------------------------
    ! Snapshot cumulative XNet timers for the calling thread.
    !-----------------------------------------------------------------------------------------------
    Use xnet_timers, Only: timer_csect, timer_deriv, timer_jacob, timer_scrn, timer_solve, timer_xnet
    Implicit None

    ! Result variable
    Type(xnet_timing_t) :: timing

    timing%evolve     = timer_xnet
    timing%solve      = timer_solve
    timing%jacobian   = timer_jacob
    timing%derivative = timer_deriv
    timing%rates      = timer_csect
    timing%screening  = timer_scrn

    Return
  End Function current_timing

  Function elapsed_timing(before) Result(delta)
    !-----------------------------------------------------------------------------------------------
    ! Compute the per-call elapsed timing difference since the before snapshot.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Input arguments
    Type(xnet_timing_t), Intent(in) :: before

    ! Result variable
    Type(xnet_timing_t) :: delta

    delta = current_timing()
    delta%evolve     = delta%evolve     - before%evolve
    delta%solve      = delta%solve      - before%solve
    delta%jacobian   = delta%jacobian   - before%jacobian
    delta%derivative = delta%derivative - before%derivative
    delta%rates      = delta%rates      - before%rates
    delta%screening  = delta%screening  - before%screening

    Return
  End Function elapsed_timing

End Module xnet_api
