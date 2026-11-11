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
! Public entry points appear first; private setup, batch execution, validation, output and timing
! helpers follow. Application examples and the full argument reference are in
! docs/development/embedding.md. Application code needs only Use xnet_api, Only: ... .
!***************************************************************************************************

#include "xnet_macros.fh"

Module xnet_api
  Use xnet_types, Only: dp, i8
  Use xnet_controls, Only: xnet_controls_t, set_xnet_controls_defaults
  Use xnet_gpu, Only: xnet_gpu_t
!$ Use omp_lib, Only: omp_get_dynamic, omp_get_level, omp_get_num_threads, omp_get_thread_num
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
    ! Caller-owned metadata; entry i describes names(i). This list defines API species indices
    ! for this initialization. The copies remain valid after finalization.
    Character(5), Allocatable :: names(:)
    Integer, Allocatable :: mass_number(:)
    Integer, Allocatable :: charge_number(:)
    Real(dp), Allocatable :: binding_energy_mev(:)
    Real(dp), Allocatable :: mass_excess_mev(:)
  End Type xnet_network_t

  Type, Public :: xnet_timing_t
    ! Per-burn wall times in seconds for the calling worker. Timers overlap; do not sum them.
    ! evolve excludes API staging, result extraction and final_output. output can extend beyond evolve.
    ! Zero can mean an unused stage, missing instrumentation or insufficient timer resolution.
    ! GPU values are host wall times, not individual kernel timings.
    Real(dp) :: evolve           = 0.0_dp ! Timed interval inside full_net.
    Real(dp) :: solve            = 0.0_dp ! Linear solves, including decomposition and backsubstitution.
    Real(dp) :: jacobian         = 0.0_dp ! Jacobian construction.
    Real(dp) :: derivative       = 0.0_dp ! ODE right-hand side evaluation.
    Real(dp) :: rates            = 0.0_dp ! Rate evaluation after EOS and screening updates.
    Real(dp) :: screening        = 0.0_dp ! Screening factors, excluding plasma-state preparation.
    Real(dp) :: timestep         = 0.0_dp ! Implicit timestep solves and retries in solve_be/solve_bdf.
    Real(dp) :: newton           = 0.0_dp ! Newton iterations within the implicit solves.
    Real(dp) :: decomposition    = 0.0_dp ! LU factorization where measured separately.
    Real(dp) :: backsubstitution = 0.0_dp ! Solution using LU factors where measured separately.
    Real(dp) :: prescreening     = 0.0_dp ! Plasma-state preparation through eos_screen.
    Real(dp) :: eos              = 0.0_dp ! Thermodynamic updates through update_eos.
    Real(dp) :: output           = 0.0_dp ! Timed sections of ts_output and final_output, including flux work.
  End Type xnet_timing_t

  !-------------------------------------------------------------------------------------------------
  ! Unit conversions and benign values for inactive workspace zones
  !-------------------------------------------------------------------------------------------------
  Real(dp), Parameter :: kelvin_to_gk = 1.0e-9_dp
  Real(dp), Parameter :: gk_to_kelvin = 1.0e9_dp
  Real(dp), Parameter :: inactive_t9  = 1.0_dp
  Real(dp), Parameter :: inactive_rho = 1.0_dp
  Real(dp), Parameter :: inactive_ye  = 0.5_dp

  ! Constant-condition histories contain a start point and an end point.
  Integer, Parameter :: api_history_points = 2

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

  ! Shared sequence for per-call history filenames; each output attempt reserves the next number.
  ! Keep counting across initialization lifetimes because earlier history files may still exist.
  Integer(i8) :: output_call = 0_i8

  ! Per-zone validation results use the same messages on host and device.
  Integer, Parameter :: zone_inactive         = -1
  Integer, Parameter :: zone_ok               = 0
  Integer, Parameter :: zone_not_finite       = 1
  Integer, Parameter :: zone_out_of_range     = 2
  Integer, Parameter :: zone_aux_not_finite   = 3
  Integer, Parameter :: zone_aux_out_of_range = 4
  Integer, Parameter :: zone_aux_needs_a      = 5
  Integer, Parameter :: zone_no_mass          = 6

Contains

  !=================================================================================================
  ! Public Entry Points
  !=================================================================================================

  Subroutine xnet_initialize(controls,network,ierr,message,gpu_context)
    !-----------------------------------------------------------------------------------------------
    ! Validate controls, optionally preprocess nuclear data, initialize GPU resources and solver
    ! workspaces once, map persistent device arrays, and return copied network metadata.
    !
    ! Set control defaults before overrides and configure the fixed team before initialization.
    ! Call outside application OpenMP regions. Controls are copied; later edits do not reconfigure XNet.
    ! A failed GPU rollback may require xnet_finalize before another initialization attempt.
    ! Supplied GPU handles remain caller-owned.
    ! Reader, allocation, EOS and solver failures can still terminate.
    !-----------------------------------------------------------------------------------------------
    Use reaction_data, Only: read_network_data
    Use xnet_controls, Only: apply_xnet_controls
    Use xnet_evolve, Only: initialize_evolve
    Use xnet_gpu, Only: gpu_init, gpu_finalize, mydevice
    Implicit None

    ! Required arguments
    Type(xnet_controls_t), Intent(in) :: controls
    Type(xnet_network_t), Intent(out) :: network
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message

    ! Optional arguments
    Type(xnet_gpu_t), Optional, Intent(in) :: gpu_context

    ! Local variables
    Type(xnet_gpu_t) :: gpu
    Integer :: cleanup_status
    Character(512) :: cleanup_message

    ! Initialize outputs and check lifecycle state
    Call check_initializable(controls,present(gpu_context),ierr,message)
    If ( ierr /= xnet_success ) Return

    ! Prepare data files before allocating resources; preprocessing may write data_dir.
    Call prepare_data_files(controls,ierr,message)
    If ( ierr /= xnet_success ) Return

    ! Initialize thread IDs and diagnostic units; record the actual OpenMP team size.
    Call initialize_thread_state

    ! A default GPU context tells gpu_init to use the current application device;
    ! with no supplied handles, XNet creates the resources it needs on that device.
    ! CPU builds return success without creating GPU resources.
    gpu = xnet_gpu_t()
    If ( present(gpu_context) ) gpu = gpu_context
    Call gpu_init(gpu,ierr,message)
    If ( ierr /= xnet_success ) Then
      ! Failed initialization may still own resources whose rollback must be retried.
      If ( mydevice >= 0 ) api_state = api_cleanup_pending
      Return
    EndIf

    ! Validate controls and copy them into the XNet runtime state;
    ! allocate and initialize internal bookkeeping.
    Call apply_xnet_controls(controls,ierr,message)
    If ( ierr /= xnet_success ) Then
      Call gpu_finalize(cleanup_status,cleanup_message)
      If ( cleanup_status /= xnet_success ) Then
        api_state = api_cleanup_pending
        message = trim(message)//'; '//trim(cleanup_message)
      EndIf
      Return
    EndIf

    ! Load nuclear/reaction tables and initialize the evolution engine with persistent
    ! zone workspace and two history endpoints (tstart and tstop).
    Call read_network_data(controls%data_dir,api_data_description)
    Call initialize_evolve(controls%data_dir,api_history_points,map_output=controls%itsout>0)
    Call copy_network_data(network)

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
    ! Batch arrays (nz = size(active); ny = number of network species):
    !   active(nz)              Input mask selecting zones to evolve.
    !   zone_id(4,nz)           Input location [i,j,k,block]; unused dimensions are 1, no block is 0.
    !   density(nz)             Input density in g/cm^3; held constant during the burn.
    !   temperature(nz)         In/out temperature in K; updated when self-heating is enabled.
    !   ye(nz)                  In/out electron fraction.
    !   mass_fraction(ny,nz)    In/out raw mass fractions; row i corresponds to network%names(i).
    !   restart_dt_s(nz)        In/out startup hint in seconds; nonnegative, with 0 for a fresh burn.
    !   neutrino_loss(nz)       Output integrated weak-reaction neutrino energy loss in erg/g.
    !   counters(5,nz)          Output integration-work counters, returned on the host.
    !   aux_x(nz)               Optional fixed auxiliary reservoir mass fraction.
    !   aux_a(nz)               Optional auxiliary mass number.
    !   aux_z(nz)               Optional auxiliary charge number.
    !
    ! Batch capacity includes inactive zones. Only active scientific inputs are read.
    ! Inactive zones preserve their input state and return zero neutrino loss and work counters.
    ! Supply all three auxiliary arrays together, or omit all three.
    ! The returned restart hint is the preceding internal timestep, not a recommended application dt.
    ! Timing and status always return on the host.
    ! Fatal burn statuses require shutdown after workers join; no physical batch result is valid.
    !-----------------------------------------------------------------------------------------------
    Use xnet_controls, Only: ktot, lzactive, nzbatch, szbatch, &
      & zb_hi, zb_lo, zone_work=>zone_id
    Use xnet_gpu, Only: gpu_check_device, stream, stream_sync
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
    Integer :: nz, izone, izb, kstep, evolve_status, failed_zone
    Type(xnet_timing_t) :: before
    Logical :: on_device
    Integer :: stream_status

    on_device = .false.
    If ( present(data_on_device) ) on_device = data_on_device

    ! Initialize host outputs
    If ( present(max_steps_taken) ) max_steps_taken = 0
    timing = xnet_timing_t()
    neutrino_loss = 0.0_dp
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
    EndIf

    ! 3. Validate batch extents, duration, and active scientific inputs
    nz = size(active)  ! Includes inactive zones.
    Call validate_batch_extents(nz,dt_s,zone_id,density,temperature,ye,mass_fraction, &
      & restart_dt_s,neutrino_loss,counters,ierr,message,aux_x,aux_a,aux_z)
    If ( ierr /= xnet_success ) Return

    Call validate_inputs(on_device,active,density,temperature,ye,mass_fraction,restart_dt_s,neutrino_loss, &
      & ierr,message,aux_x,aux_a,aux_z)
    If ( ierr /= xnet_success ) Return

    If ( .not. any(active) ) Return

    ! 4. Configure active zone masks and identifiers
    before = get_timing()
    szbatch = 1
    nzbatch = count(active)
    lzactive(zb_lo:zb_hi) = .false.
    lzactive(zb_lo:zb_lo+nz-1) = active
    zone_work(:,zb_lo:zb_hi) = 0
    zone_work(:,zb_lo:zb_lo+nz-1) = zone_id

    ! 5. Stage, evolve and collect in the requested memory space
    Call evolve_batch(dt_s,on_device,active,density,temperature,ye,mass_fraction,restart_dt_s,neutrino_loss, &
      & aux_x,aux_a,aux_z,kstep,evolve_status,failed_zone,ierr,message)
    If ( ierr /= xnet_success ) Return

    ! Record XNet counters for active zones.
    Do izb = zb_lo, zb_lo+nz-1
      izone = izb + szbatch - zb_lo
      If ( active(izone) ) counters(:,izone) = ktot(:,izb)
    EndDo

    ! 6. Record per-call timing differences and format any numerical failure diagnostic
    If ( evolve_status == 0 .and. present(max_steps_taken) ) max_steps_taken = kstep
    timing = get_timing_since(before)
    If ( evolve_status /= 0 ) Then
      Call format_burn_failure(evolve_status,failed_zone+szbatch-zb_lo,zone_id,ierr,message)
    EndIf

    Return
  End Subroutine xnet_burn_batch

  Subroutine xnet_nse_composition(density,temperature,ye,mass_fraction,ierr,message)
    !-----------------------------------------------------------------------------------------------
    ! Compute Nuclear Statistical Equilibrium mass fractions (A * ynse) for scalar density [g/cm^3],
    ! temperature [K], and electron fraction Ye. Entry i corresponds to network%names(i) returned
    ! by xnet_initialize.
    ! Copy without normalization or species mapping. NSE convergence failures remain fatal.
    !-----------------------------------------------------------------------------------------------
    Use, Intrinsic :: ieee_arithmetic, Only: ieee_is_finite
    Use nuclear_data, Only: aa, ny
    Use xnet_nse, Only: nse_solve, ynse
    Use xnet_gpu, Only: gpu_check_device
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

    Call gpu_check_device(ierr,message)
    If ( ierr /= 0 ) Return

    ierr = xnet_invalid
    If ( size(mass_fraction) /= ny ) Then
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
    !-----------------------------------------------------------------------------------------------
    ! Release XNet-owned device mappings, CPU workspaces, and GPU handles without destroying
    ! host-owned resources. If GPU cleanup fails, preserve api_cleanup_pending so a subsequent
    ! xnet_finalize call retries only GPU handle/stream teardown.
    !
    ! Release mappings before CPU allocations. Copied network metadata remains with the application.
    ! Call outside application parallel regions, with no work in flight and the initialized team.
    ! After successful cleanup, repeated calls succeed without repeating teardown.
    !-----------------------------------------------------------------------------------------------
    Use reaction_data, Only: finalize_network_data
    Use xnet_controls, Only: controls_finalize
    Use xnet_evolve, Only: finalize_evolve
    Use xnet_gpu, Only: gpu_check_device, gpu_finalize
    Implicit None

    ! Output arguments
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message

    ierr = xnet_success
    message = ' '
    If ( api_state == api_uninitialized ) Return

    Call check_finalize_team(ierr,message)
    If ( ierr /= xnet_success ) Return

    If ( api_state == api_ready ) Then
      Call gpu_check_device(ierr,message)
      If ( ierr /= xnet_success ) Return
      Call finalize_evolve
      Call finalize_network_data
      Call controls_finalize
      api_state = api_cleanup_pending
    EndIf

    ! A failed GPU handle/stream cleanup can be retried without touching the released workspaces.
    Call gpu_finalize(ierr,message)
    If ( ierr /= xnet_success ) Return
    api_state = api_uninitialized

    Return
  End Subroutine xnet_finalize

  !=================================================================================================
  ! Private Initialization and Lifecycle Helpers
  !=================================================================================================

  Subroutine check_initializable(controls,gpu_requested,ierr,message)
    !-----------------------------------------------------------------------------------------------
    ! Reject unsupported lifecycle, controls and team settings before allocating resources.
    !-----------------------------------------------------------------------------------------------
    Use xnet_abundances, Only: y
    Use xnet_controls, Only: validate_xnet_controls
    Implicit None
    Type(xnet_controls_t), Intent(in) :: controls
    Logical, Intent(in) :: gpu_requested
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message

    ierr = xnet_invalid
    message = ' '
    If ( api_state /= api_uninitialized .or. allocated(y) ) Then
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
    If ( len_trim(controls%data_dir) == 0 ) Then
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
    !-----------------------------------------------------------------------------------------------
    ! Optionally preprocess nuclear data, then check the files needed for network initialization.
    ! Preprocessing writes data_dir; the host must arrange exclusive access to that directory.
    !-----------------------------------------------------------------------------------------------
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
    Do i = 1, size(filenames)
      Inquire(file=trim(data_dir)//'/'//trim(filenames(i)),exist=exists)
      If ( .not. exists ) Then
        message = 'Missing network file: '//trim(filenames(i))
        Return
      EndIf
      Open(newunit=input_unit,file=trim(data_dir)//'/'//trim(filenames(i)), &
        & status='old',action='read',access='stream',form='unformatted',iostat=input_status)
      If ( input_status /= 0 ) Then
        message = 'Cannot read network file: '//trim(filenames(i))
        Return
      EndIf
      Close(input_unit)
    EndDo
    ierr = xnet_success

    Return
  End Subroutine check_network_files

  Subroutine initialize_thread_state
    !-----------------------------------------------------------------------------------------------
    ! Initialize XNet thread IDs and diagnostic units; record the actual OpenMP team size.
    ! The application controls OpenMP settings. Serial builds use one thread.
    !-----------------------------------------------------------------------------------------------
    Use xnet_controls, Only: tid, nthread, lun_diag, lun_stdout
    Implicit None

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
    lun_diag = lun_stdout
#ifdef XNET_OMP
    !$omp end parallel
#endif
    Return
  End Subroutine initialize_thread_state

  Subroutine copy_network_data(network)
    !-----------------------------------------------------------------------------------------------
    ! Copy species names, A/Z and nuclear energies into independent, caller-owned metadata arrays.
    !-----------------------------------------------------------------------------------------------
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
  End Subroutine copy_network_data

  Subroutine check_finalize_team(ierr,message)
    !-----------------------------------------------------------------------------------------------
    ! Finalization must use the fixed team established at initialization.
    ! Builds without XNet host threading return success.
    !-----------------------------------------------------------------------------------------------
    Use xnet_controls, Only: nthread
    Implicit None
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message
    Integer :: final_threads

    ierr = xnet_success
    message = ' '
#ifdef XNET_OMP
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
#endif
    Return
  End Subroutine check_finalize_team

  !=================================================================================================
  ! Private Batch Execution and Worker Validation
  !=================================================================================================

  Subroutine evolve_batch(dt_s,on_device,active,density,temperature,electron_fraction,mass_fraction,restart_dt_s,neutrino_loss, &
    & aux_x,aux_a,aux_z,kstep,evolve_status,failed_zone,ierr,message)
    !-----------------------------------------------------------------------------------------------
    ! Prepare the current worker bank, evolve once, and return results in the requested memory space.
    ! The caller has validated inputs and selected at least one active zone.
    ! Conditional offload keeps host values authoritative even when stale device mappings exist.
    !-----------------------------------------------------------------------------------------------
    Use nuclear_data, Only: aa, ny
    Use xnet_abundances, Only: y, ystart, xext, aext, zext
    Use xnet_conditions, Only: t, t9, rho, ye, tdel, tdel_old, nt, nstart, &
      & tstart, tstop, tdelstart, t9start, rhostart, yestart, nh, th, t9h, rhoh, yeh
    Use xnet_controls, Only: lzactive, iheat, ktot, gpu_queue, szbatch, zb_lo, zb_hi
    Use xnet_evolve, Only: full_net
    Use xnet_output, Only: close_output_files
    Implicit None

    ! Input/Output arguments
    Real(dp), Intent(in) :: dt_s, density(:)
    Logical, Intent(in) :: on_device, active(:)
    Real(dp), Intent(inout) :: temperature(:), electron_fraction(:), mass_fraction(:,:), restart_dt_s(:), neutrino_loss(:)
    Real(dp), Optional, Intent(in) :: aux_x(:), aux_a(:), aux_z(:)
    Integer, Intent(out) :: kstep, evolve_status, failed_zone, ierr
    Character(*), Intent(out) :: message

    ! Local variables
    Real(dp), Allocatable :: loss_work(:)
    Integer :: nz, izone, izb, k

    nz = size(active)
    kstep = 0
    evolve_status = 0
    failed_zone = 0
    ierr = xnet_success
    message = ' '

    ! Open histories before allocating or staging burn workspace.
    Call open_burn_output(ierr,message)
    If ( ierr /= xnet_success ) Return

    ! full_net also checks the stop time on the host.
    tstop(zb_lo:zb_hi) = dt_s
    Allocate (loss_work(zb_lo:zb_hi))

    If ( on_device ) Then
      ! Keep loss_work mapped across full_net (including denu cleanup) and result collection.
      ! Caller scientific arrays are already mapped and remain caller-owned.
      !XDIR XENTER_DATA XASYNC(gpu_queue) &
      !XDIR XCREATE(loss_work)
      !XDIR XUPDATE XASYNC(gpu_queue) &
      !XDIR XDEVICE(lzactive)
    EndIf

    ! Follow the standalone convention: izb indexes workspace, izone indexes input arrays.
    ! The API sets szbatch = 1, so izone is the caller-array column within this batch.
    ! Reset inactive and unused zones without reading their scientific inputs.
    ! XIF(on_device) selects the device or host copy of every array in these loops.
    !XDIR XLOOP_OUTER(1) XIF(on_device) XASYNC(gpu_queue) &
    !XDIR XPRIVATE(izone) &
    !XDIR XPRESENT(lzactive,aa,ystart,xext,aext,zext,nstart,tstart,tstop,tdelstart,t9start,rhostart,yestart) &
    !XDIR XPRESENT(nh,th,t9h,rhoh,yeh,tdel,nt,t,t9,rho,ye,y) &
    !XDIR XPRESENT(density,temperature,electron_fraction,mass_fraction,restart_dt_s)
    Do izb = zb_lo, zb_hi
      izone = izb + szbatch - zb_lo
      xext(izb) = 0.0_dp
      aext(izb) = 1.0_dp
      zext(izb) = 0.0_dp
      ! The first endpoint is one; zero can reach history element zero in timestep.
      nstart(izb) = 1
      tstart(izb) = 0.0_dp
      tstop(izb) = dt_s
      tdelstart(izb) = 0.0_dp
      t9start(izb) = inactive_t9
      rhostart(izb) = inactive_rho
      yestart(izb) = inactive_ye
      !XDIR XLOOP_SERIAL(1)
      Do k = 1, ny
        ystart(k,izb) = 0.0_dp
      EndDo
      If ( izone <= nz ) Then
        If ( lzactive(izb) ) Then
          !XDIR XLOOP_SERIAL(1)
          Do k = 1, ny
            ystart(k,izb) = mass_fraction(k,izone) / aa(k)
          EndDo
          t9start(izb) = temperature(izone) * kelvin_to_gk
          rhostart(izb) = density(izone)
          yestart(izb) = electron_fraction(izone)
          ! Preserve the CHIMERA startup hint convention without exposing its sign encoding.
          tdelstart(izb) = -restart_dt_s(izone)
        EndIf
      EndIf
      ! Constant conditions: both history endpoints carry the start values.
      nh(izb) = 2
      th(1,izb) = tstart(izb)
      th(2,izb) = tstop(izb)
      t9h(1,izb) = t9start(izb)
      t9h(2,izb) = t9start(izb)
      rhoh(1,izb) = rhostart(izb)
      rhoh(2,izb) = rhostart(izb)
      yeh(1,izb) = yestart(izb)
      yeh(2,izb) = yestart(izb)
      tdel(izb) = 0.0_dp
      nt(izb) = nstart(izb)
      t(izb) = tstart(izb)
      t9(izb) = t9start(izb)
      rho(izb) = rhostart(izb)
      ye(izb) = yestart(izb)
      !XDIR XLOOP_SERIAL(1)
      Do k = 1, ny
        y(k,izb) = ystart(k,izb)
      EndDo
    EndDo

    If ( present(aux_x) ) Then
      !XDIR XLOOP_OUTER(1) XIF(on_device) XASYNC(gpu_queue) &
      !XDIR XPRIVATE(izone) &
      !XDIR XPRESENT(lzactive,xext,aext,zext,aux_x,aux_a,aux_z)
      Do izb = zb_lo, zb_lo+nz-1
        izone = izb + szbatch - zb_lo
        If ( .not. lzactive(izb) ) Cycle
        If ( aux_x(izone) > 0.0_dp ) Then
          xext(izb) = aux_x(izone)
          aext(izb) = aux_a(izone)
          zext(izb) = aux_z(izone)
        EndIf
      EndDo
    EndIf

    If ( .not. on_device ) Then
      ! Transfer only XNet-owned workspace; host array sections need no caller mappings.
      !XDIR XUPDATE XASYNC(gpu_queue) &
      !XDIR XDEVICE(xext,aext,zext,lzactive,tdel,t,t9,rho,ye,y,nt) &
      !XDIR XDEVICE(tstart,tstop,tdelstart,nstart,t9start,rhostart,yestart,ystart) &
      !XDIR XDEVICE(nh,th,t9h,rhoh,yeh)
    EndIf

    Call full_net(kstep,loss_work,evolve_status,failed_zone)
    Call close_output_files

    ! Attempted counters remain useful when numerical failure invalidates physical results.
    !XDIR XUPDATE XWAIT(gpu_queue) &
    !XDIR XHOST(ktot)
    If ( evolve_status == 0 ) Then
      If ( .not. on_device ) Then
        !XDIR XUPDATE XWAIT(gpu_queue) &
        !XDIR XHOST(y,t9,ye,tdel_old)
      EndIf
      !XDIR XLOOP_OUTER(1) XIF(on_device) XASYNC(gpu_queue) &
      !XDIR XPRIVATE(izone) &
      !XDIR XPRESENT(lzactive,aa,y,t9,ye,tdel_old,loss_work) &
      !XDIR XPRESENT(temperature,electron_fraction,mass_fraction,restart_dt_s,neutrino_loss)
      Do izb = zb_lo, zb_lo+nz-1
        izone = izb + szbatch - zb_lo
        If ( .not. lzactive(izb) ) Cycle
        !XDIR XLOOP_SERIAL(1)
        Do k = 1, ny
          mass_fraction(k,izone) = y(k,izb) * aa(k)
        EndDo
        If ( iheat > 0 ) temperature(izone) = t9(izb) * gk_to_kelvin
        electron_fraction(izone) = ye(izb)
        restart_dt_s(izone) = tdel_old(izb)
        neutrino_loss(izone) = loss_work(izb)
      EndDo
    EndIf

    If ( on_device ) Then
      !XDIR XEXIT_DATA XASYNC(gpu_queue) &
      !XDIR XDELETE(loss_work)
      !XDIR XWAIT(gpu_queue)
    EndIf
    Deallocate (loss_work)
    Return
  End Subroutine evolve_batch

  Subroutine check_worker(ierr,message)
    !-----------------------------------------------------------------------------------------------
    ! Verify the OpenMP team topology and initialized scratch for the calling worker.
    !-----------------------------------------------------------------------------------------------
    Use xnet_controls, Only: nthread, tid
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

    If ( tid < 1 .or. tid > nthread .or. .not. allocated(ynse) ) Then
      ierr = xnet_lifecycle_error
      message = 'This XNet worker is not initialized; keep the initialized OpenMP team'
      Return
    EndIf

    Return
  End Subroutine check_worker

  Subroutine validate_batch_extents(nz,dt_s,zone_id,density,temperature,ye,mass_fraction, &
    & restart_dt_s,neutrino_loss,counters,ierr,message,aux_x,aux_a,aux_z)
    !-----------------------------------------------------------------------------------------------
    ! Validate batch array shapes, auxiliary argument pairing, and burn duration.
    !-----------------------------------------------------------------------------------------------
    Use, Intrinsic :: ieee_arithmetic, Only: ieee_is_finite
    Use nuclear_data, Only: ny
    Use xnet_controls, Only: nzbatchmx
    Implicit None

    ! Input arguments
    Integer, Intent(in) :: nz
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
    If ( size(zone_id,1) /= 4 .or. size(zone_id,2) /= nz ) Then
      message = 'zone_id must have shape (4,nz): [i,j,k,block]'
      Return
    EndIf
    If ( nz > nzbatchmx .or. size(density) /= nz .or. size(temperature) /= nz .or. &
      & size(ye) /= nz .or. size(restart_dt_s) /= nz .or. size(neutrino_loss) /= nz .or. &
      & size(mass_fraction,1) /= ny .or. size(mass_fraction,2) /= nz .or. &
      & size(counters,1) /= 5 .or. size(counters,2) /= nz ) Then
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
    If ( (present(aux_x) .neqv. present(aux_a)) .or. (present(aux_x) .neqv. present(aux_z)) ) Then
      message = 'Supply auxiliary mass fraction, A and Z together'
      Return
    EndIf
    If ( present(aux_x) ) Then
      If ( size(aux_x) /= nz .or. size(aux_a) /= nz .or. size(aux_z) /= nz ) Then
        message = 'Inconsistent auxiliary dimensions'
        Return
      EndIf
    EndIf
    ierr = xnet_success

    Return
  End Subroutine validate_batch_extents

  Subroutine validate_inputs(on_device,active,density,temperature,ye,mass_fraction,restart_dt_s,neutrino_loss, &
    & ierr,message,aux_x,aux_a,aux_z)
    !-----------------------------------------------------------------------------------------------
    ! Validate active scientific inputs after checking extents and any required device mappings.
    ! A temporary verdict array also carries the host active mask; no worker workspace is needed.
    ! Clear device loss here; the public entry point has already cleared the host output.
    !-----------------------------------------------------------------------------------------------
    Use, Intrinsic :: ieee_arithmetic, Only: ieee_is_finite
    Use nuclear_data, Only: ny
    Use xnet_controls, Only: gpu_queue
    Implicit None

    ! Input arguments
    Logical, Intent(in) :: on_device, active(:)
    Real(dp), Intent(in) :: density(:), temperature(:), ye(:), mass_fraction(:,:), restart_dt_s(:)
    Real(dp), Optional, Intent(in) :: aux_x(:), aux_a(:), aux_z(:)

    ! Input/Output arguments
    Real(dp), Intent(inout) :: neutrino_loss(:)

    ! Output arguments
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message

    ! Local variables
    Integer :: nz, izone, k
    Integer, Allocatable :: validation(:)
    Real(dp), Allocatable :: mass_sum(:)
    Real(dp) :: total_mass
    Logical :: finite_state, negative_mass

    nz = size(active)
    ierr = xnet_success
    message = ' '
    If ( nz == 0 ) Return

    If ( .not. any(active) ) Then
      If ( on_device ) Then
        ! Clear only the mapped output; inactive scientific inputs are not read.
        !XDIR XLOOP_OUTER(1) XASYNC(gpu_queue) &
        !XDIR XPRESENT(neutrino_loss)
        Do izone = 1, nz
          neutrino_loss(izone) = 0.0_dp
        EndDo
        !XDIR XWAIT(gpu_queue)
      EndIf
      Return
    EndIf

    Allocate (validation(nz),mass_sum(nz))
    validation = zone_inactive
    Where ( active ) validation = zone_ok

    If ( .not. on_device ) Then
      ! Classify host values without raising invalid-operation traps for quiet NaNs.
      ! NVHPC 26.5 cannot link IEEE_IS_FINITE inside device loops.
      Do izone = 1, nz
        If ( .not. active(izone) ) Cycle
        If ( .not. (ieee_is_finite(density(izone)) .and. ieee_is_finite(temperature(izone)) .and. &
          & ieee_is_finite(ye(izone)) .and. ieee_is_finite(restart_dt_s(izone)) .and. &
          & all(ieee_is_finite(mass_fraction(:,izone)))) ) Then
          validation(izone) = zone_not_finite
        ElseIf ( present(aux_x) ) Then
          If ( .not. (ieee_is_finite(aux_x(izone)) .and. ieee_is_finite(aux_a(izone)) .and. &
            & ieee_is_finite(aux_z(izone))) ) validation(izone) = zone_aux_not_finite
        EndIf
      EndDo
    Else
      ! Scientific arrays are caller-mapped. Only the temporary validation storage is owned here.
      !XDIR XENTER_DATA XASYNC(gpu_queue) &
      !XDIR XCOPYIN(validation) XCREATE(mass_sum)
    EndIf

    ! Check the primary state in either memory space, without reading inactive zones.
    !XDIR XLOOP_OUTER(1) XIF(on_device) XASYNC(gpu_queue) &
    !XDIR XPRIVATE(total_mass,finite_state,negative_mass) &
    !XDIR XPRESENT(validation,mass_sum,density,temperature,ye,mass_fraction,restart_dt_s,neutrino_loss)
    Do izone = 1, nz
      If ( on_device ) neutrino_loss(izone) = 0.0_dp
      mass_sum(izone) = 0.0_dp
      If ( validation(izone) == zone_inactive .or. validation(izone) == zone_not_finite ) Cycle
      finite_state = .true.
      If ( on_device ) Then
        ! Ordered device comparisons reject NaNs and infinities without a device helper.
        finite_state = abs(density(izone)) <= huge(1.0_dp) .and. abs(temperature(izone)) <= huge(1.0_dp) .and. &
          & abs(ye(izone)) <= huge(1.0_dp) .and. abs(restart_dt_s(izone)) <= huge(1.0_dp)
      EndIf
      negative_mass = .false.
      !XDIR XLOOP_SERIAL(1)
      Do k = 1, ny
        If ( on_device ) finite_state = finite_state .and. abs(mass_fraction(k,izone)) <= huge(1.0_dp)
        negative_mass = negative_mass .or. mass_fraction(k,izone) < 0.0_dp
      EndDo
      If ( .not. finite_state ) Then
        validation(izone) = zone_not_finite
      ElseIf ( density(izone) <= 0.0_dp .or. temperature(izone) <= 0.0_dp .or. &
        & ye(izone) < 0.0_dp .or. ye(izone) > 1.0_dp .or. restart_dt_s(izone) < 0.0_dp .or. negative_mass ) Then
        ! Primary-state errors take precedence over any auxiliary nonfinite values.
        validation(izone) = zone_out_of_range
      Else
        ! Sum only after rejecting invalid primary values.
        total_mass = 0.0_dp
        !XDIR XLOOP_SERIAL(1)
        Do k = 1, ny
          total_mass = total_mass + mass_fraction(k,izone)
        EndDo
        mass_sum(izone) = total_mass
      EndIf
    EndDo

    If ( present(aux_x) ) Then
      !XDIR XLOOP_OUTER(1) XIF(on_device) XASYNC(gpu_queue) &
      !XDIR XPRIVATE(finite_state) &
      !XDIR XPRESENT(validation,mass_sum,aux_x,aux_a,aux_z)
      Do izone = 1, nz
        If ( validation(izone) /= zone_ok ) Cycle
        finite_state = .true.
        If ( on_device ) finite_state = abs(aux_x(izone)) <= huge(1.0_dp) .and. &
          & abs(aux_a(izone)) <= huge(1.0_dp) .and. abs(aux_z(izone)) <= huge(1.0_dp)
        If ( .not. finite_state ) Then
          validation(izone) = zone_aux_not_finite
        ElseIf ( aux_x(izone) < 0.0_dp .or. aux_x(izone) > 1.0_dp .or. aux_a(izone) < 0.0_dp .or. &
          & aux_z(izone) < 0.0_dp .or. aux_z(izone) > aux_a(izone) ) Then
          validation(izone) = zone_aux_out_of_range
        ElseIf ( aux_x(izone) > 0.0_dp .and. aux_a(izone) <= 0.0_dp ) Then
          validation(izone) = zone_aux_needs_a
        ElseIf ( mass_sum(izone) + aux_x(izone) <= 0.0_dp ) Then
          validation(izone) = zone_no_mass
        EndIf
      EndDo
    Else
      !XDIR XLOOP_OUTER(1) XIF(on_device) XASYNC(gpu_queue) &
      !XDIR XPRESENT(validation,mass_sum)
      Do izone = 1, nz
        If ( validation(izone) == zone_ok .and. mass_sum(izone) <= 0.0_dp ) validation(izone) = zone_no_mass
      EndDo
    EndIf

    If ( on_device ) Then
      !XDIR XUPDATE XWAIT(gpu_queue) &
      !XDIR XHOST(validation)
      !XDIR XEXIT_DATA XASYNC(gpu_queue) &
      !XDIR XDELETE(validation,mass_sum)
      !XDIR XWAIT(gpu_queue)
    EndIf

    Do izone = 1, nz
      If ( validation(izone) == zone_ok .or. validation(izone) == zone_inactive ) Cycle
      ierr = xnet_invalid
      message = zone_error_message(validation(izone))
      Exit
    EndDo
    Deallocate (validation,mass_sum)

    Return
  End Subroutine validate_inputs

  Function zone_error_message(verdict) Result(text)
    !-----------------------------------------------------------------------------------------------
    ! Translate host and device zone-validation results into the same public diagnostic text.
    !-----------------------------------------------------------------------------------------------
    Implicit None
    Integer, Intent(in) :: verdict
    Character(80) :: text

    Select Case (verdict)
    Case (zone_not_finite)
      text = 'Active-zone inputs must be finite'
    Case (zone_out_of_range)
      text = 'Invalid active-zone density, temperature, Ye, composition or restart timestep'
    Case (zone_aux_not_finite)
      text = 'Active-zone auxiliary inputs must be finite'
    Case (zone_aux_out_of_range)
      text = 'Invalid auxiliary mass fraction, A or Z'
    Case (zone_aux_needs_a)
      text = 'Positive auxiliary mass requires positive A'
    Case (zone_no_mass)
      text = 'Active-zone composition must contain positive mass'
    Case Default
      text = ' '
    End Select
    Return
  End Function zone_error_message

  Subroutine format_burn_failure(evolve_status,failed_zone,zone_id,ierr,message)
    !-----------------------------------------------------------------------------------------------
    ! Translate an internal full_net failure status into the public status code and zone diagnostic.
    !-----------------------------------------------------------------------------------------------
    Use xnet_evolve, Only: evolve_integrator_failure, evolve_step_limit
    Implicit None

    ! Input arguments
    Integer, Intent(in) :: evolve_status, failed_zone
    Integer, Intent(in) :: zone_id(:,:)

    ! Output arguments
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message

    ! Local variables
    Character(128) :: failure_ids
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

    Write(failure_ids,'(4(i0,1x))') zone_id(:,failed_zone)
    Write(failure_message,'(a,i0,4a)') 'Zone ',failed_zone,', zone_id [i,j,k,block] = [', &
      & trim(failure_ids),']: ',trim(failure_reason)
    message = failure_message

    Return
  End Subroutine format_burn_failure

  !=================================================================================================
  ! Private Device Mapping and Input Validation
  !=================================================================================================

  Subroutine check_device_batch(density,temperature,ye,mass_fraction,restart_dt_s,neutrino_loss, &
    & ierr,message,aux_x,aux_a,aux_z)
    !-----------------------------------------------------------------------------------------------
    ! Verify that all scientific arrays for a device-resident burn are contiguous and mapped on
    ! the active device. CPU builds reject device-array requests before inspecting the arrays.
    !-----------------------------------------------------------------------------------------------
    Use, Intrinsic :: iso_c_binding, Only: c_loc, c_sizeof, C_SIZE_T
    Use xnet_gpu, Only: device_is_present, mydevice
    Implicit None

    ! Input/Output arguments
    Real(dp), Target, Intent(in) :: density(:), temperature(:), ye(:), mass_fraction(:,:), restart_dt_s(:)
    Real(dp), Target, Intent(in) :: neutrino_loss(:)
    Real(dp), Optional, Target, Intent(in) :: aux_x(:), aux_a(:), aux_z(:)
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message

    ! Local constants and variables
    Integer(C_SIZE_T), Parameter :: real_bytes = c_sizeof(0.0_dp)
    Logical :: mapped

#ifndef XNET_GPU
    ierr = xnet_unsupported
    message = 'Device-array burns require a supported GPU library build'
    Return
#endif
    ierr = xnet_invalid
    message = 'Device-array burns require contiguous scientific arrays'
    If ( .not. is_contiguous(density) .or. .not. is_contiguous(temperature) .or. &
      & .not. is_contiguous(ye) .or. .not. is_contiguous(mass_fraction) .or. &
      & .not. is_contiguous(restart_dt_s) .or. .not. is_contiguous(neutrino_loss) ) Return
    If ( present(aux_x) ) Then
      If ( .not. is_contiguous(aux_x) ) Return
    EndIf
    If ( present(aux_a) ) Then
      If ( .not. is_contiguous(aux_a) ) Return
    EndIf
    If ( present(aux_z) ) Then
      If ( .not. is_contiguous(aux_z) ) Return
    EndIf

    message = 'Device-array burns require every scientific array mapped on the selected device'
    mapped = .true.
    If ( size(density) > 0 ) mapped = mapped .and. &
      & device_is_present(c_loc(density(1)),mydevice,int(size(density),C_SIZE_T)*real_bytes)
    If ( size(temperature) > 0 ) mapped = mapped .and. &
      & device_is_present(c_loc(temperature(1)),mydevice,int(size(temperature),C_SIZE_T)*real_bytes)
    If ( size(ye) > 0 ) mapped = mapped .and. &
      & device_is_present(c_loc(ye(1)),mydevice,int(size(ye),C_SIZE_T)*real_bytes)
    If ( size(mass_fraction) > 0 ) mapped = mapped .and. &
      & device_is_present(c_loc(mass_fraction(1,1)),mydevice,int(size(mass_fraction),C_SIZE_T)*real_bytes)
    If ( size(restart_dt_s) > 0 ) mapped = mapped .and. &
      & device_is_present(c_loc(restart_dt_s(1)),mydevice,int(size(restart_dt_s),C_SIZE_T)*real_bytes)
    If ( size(neutrino_loss) > 0 ) mapped = mapped .and. &
      & device_is_present(c_loc(neutrino_loss(1)),mydevice,int(size(neutrino_loss),C_SIZE_T)*real_bytes)
    If ( present(aux_x) ) Then
      If ( size(aux_x) > 0 ) mapped = mapped .and. &
        & device_is_present(c_loc(aux_x(1)),mydevice,int(size(aux_x),C_SIZE_T)*real_bytes)
    EndIf
    If ( present(aux_a) ) Then
      If ( size(aux_a) > 0 ) mapped = mapped .and. &
        & device_is_present(c_loc(aux_a(1)),mydevice,int(size(aux_a),C_SIZE_T)*real_bytes)
    EndIf
    If ( present(aux_z) ) Then
      If ( size(aux_z) > 0 ) mapped = mapped .and. &
        & device_is_present(c_loc(aux_z(1)),mydevice,int(size(aux_z),C_SIZE_T)*real_bytes)
    EndIf
    If ( .not. mapped ) Return

    ierr = xnet_success
    message = ' '

    Return
  End Subroutine check_device_batch

  !=================================================================================================
  ! Private Time-series Output and Per-call Timing
  !=================================================================================================

  Subroutine open_burn_output(ierr,message)
    !-----------------------------------------------------------------------------------------------
    ! Open per-call binary (itsout>=1) and ASCII (itsout>=2) time-series files for active zones
    ! in the current worker bank. Reserve a unique process-wide call number under a short
    ! critical region while keeping file writes and evolution outside the critical region.
    ! Each call has its own local 0..dt_s history. Zone numbers distinguish repeated diagnostic IDs.
    !-----------------------------------------------------------------------------------------------
    Use xnet_controls, Only: itsout, lzactive, bin_file_base, ev_file_base, zone_id, szbatch, zb_lo, zb_hi
    Use xnet_flux, Only: flx
    Use xnet_output, Only: open_ts_file, open_ev_file, close_output_files
    Implicit None
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message
    ! Match the standalone binary header field widths, including programmatic input descriptions.
    Character(80), Parameter :: input_name            = 'XNet API input arrays'
    Character(80), Parameter :: abundance_description = 'Mass fractions in XNet species order'
    Character(80), Parameter :: thermo_description    = 'Constant conditions; local time 0..dt seconds'
    Character(256) :: filename
    Character(80) :: zone_label
    Character(64) :: suffix
    Integer :: izb, output_status
    Integer(i8) :: call_number

    ierr = xnet_success
    message = ' '
    If ( itsout <= 0 .or. .not. any(lzactive(zb_lo:zb_hi)) ) Return
    ierr = xnet_invalid

    ! Reserve one number for this call; do not serialize file writes or evolution.
    call_number = 0_i8
    !$omp critical(xnet_output_call)
    If ( output_call < huge(output_call) ) Then
      output_call = output_call+1_i8
      call_number = output_call
    EndIf
    !$omp end critical(xnet_output_call)
    If ( call_number == 0_i8 ) Then
      message = 'Time-series call number exhausted'
      Return
    EndIf

    ! Open ts/ev files for each active zone.
    Do izb = zb_lo, zb_hi
      If ( .not. lzactive(izb) ) Cycle
      Write(suffix,'(a,i0,a,i0)') '_call',call_number,'_lane',izb+szbatch-zb_lo
      filename = trim(bin_file_base)//trim(suffix)

      ! Identify the caller zone in the existing input label; keep the record layout.
      Write(zone_label,'(a,4(1x,i0))') 'XNet API zone_id [i,j,k,block]:',zone_id(:,izb)
      Call open_ts_file(izb,filename,api_data_description,zone_label,abundance_description, &
        & input_name,thermo_description,status='new',ierr=output_status)
      If ( output_status /= 0 ) Exit

      If ( itsout >= 2 ) Then
        filename = trim(ev_file_base)//trim(suffix)
        Call open_ev_file(izb,filename,status='new',ierr=output_status)
        If ( output_status /= 0 ) Exit
      EndIf
    EndDo

    ! If any file failed to open, close all files and return an error.
    If ( output_status /= 0 ) Then
      Call close_output_files
      message = 'Cannot create time-series file: '//trim(filename)
      Return
    EndIf

    ! The initial snapshot has no reaction flux; do not reuse final flux from the preceding burn.
    flx(:,zb_lo:zb_hi) = 0.0_dp
    ierr = xnet_success

    Return
  End Subroutine open_burn_output

  Function get_timing() Result(timing)
    !-----------------------------------------------------------------------------------------------
    ! Snapshot cumulative XNet timers for the calling thread.
    !-----------------------------------------------------------------------------------------------
    Use xnet_timers, Only: timer_xnet, timer_solve, timer_jacob, timer_deriv, timer_csect, timer_scrn, &
      & timer_tstep, timer_nraph, timer_decmp, timer_bksub, timer_prescrn, timer_eos, timer_output
    Implicit None

    ! Result variable
    Type(xnet_timing_t) :: timing

    timing%evolve           = timer_xnet
    timing%solve            = timer_solve
    timing%jacobian         = timer_jacob
    timing%derivative       = timer_deriv
    timing%rates            = timer_csect
    timing%screening        = timer_scrn
    timing%timestep         = timer_tstep
    timing%newton           = timer_nraph
    timing%decomposition    = timer_decmp
    timing%backsubstitution = timer_bksub
    timing%prescreening     = timer_prescrn
    timing%eos              = timer_eos
    timing%output           = timer_output

    Return
  End Function get_timing

  Function get_timing_since(before) Result(delta)
    !-----------------------------------------------------------------------------------------------
    ! Compute the per-call elapsed timing difference since the before snapshot.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Input arguments
    Type(xnet_timing_t), Intent(in) :: before

    ! Result variable
    Type(xnet_timing_t) :: delta

    delta = get_timing()
    delta%evolve           = delta%evolve           - before%evolve
    delta%solve            = delta%solve            - before%solve
    delta%jacobian         = delta%jacobian         - before%jacobian
    delta%derivative       = delta%derivative       - before%derivative
    delta%rates            = delta%rates            - before%rates
    delta%screening        = delta%screening        - before%screening
    delta%timestep         = delta%timestep         - before%timestep
    delta%newton           = delta%newton           - before%newton
    delta%decomposition    = delta%decomposition    - before%decomposition
    delta%backsubstitution = delta%backsubstitution - before%backsubstitution
    delta%prescreening     = delta%prescreening     - before%prescreening
    delta%eos              = delta%eos              - before%eos
    delta%output           = delta%output           - before%output

    Return
  End Function get_timing_since

End Module xnet_api
