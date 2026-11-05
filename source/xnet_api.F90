!***************************************************************************************************
! xnet_api.F90
! Application interface for network initialization, batch evolution, NSE and finalization.
!***************************************************************************************************

#include "xnet_macros.fh"

Module xnet_api
  !-------------------------------------------------------------------------------------------------
  ! One initialized network is shared by the application. Each OpenMP worker uses its own batch
  ! workspace and NSE scratch; initialization and finalization run outside application teams.
  ! See docs/development/embedding.md for the calling sequence and supported execution modes.
  !-------------------------------------------------------------------------------------------------
  Use xnet_types, Only: dp, i8
  Use xnet_controls, Only: xnet_controls_t, set_xnet_controls_defaults
  Use xnet_gpu, Only: xnet_gpu_t
#ifdef XNET_OMP
  Use omp_lib, Only: omp_get_thread_num, omp_get_num_threads, omp_get_dynamic, omp_get_level
#endif
  Implicit None
  Private

  Integer, Parameter, Public :: xnet_success = 0, xnet_invalid = 1
  Integer, Parameter, Public :: xnet_lifecycle_error = 2, xnet_unsupported = 3
  Integer, Parameter, Public :: xnet_integrator_failure = 4, xnet_step_limit = 5
  Public :: dp, xnet_controls_t, set_xnet_controls_defaults, xnet_gpu_t
  Public :: xnet_initialize, xnet_burn_batch, xnet_nse_composition, xnet_finalize

  ! Species metadata uses the same ordering as the first dimension of mass_fraction.
  Type, Public :: xnet_network_t
    Character(5), Allocatable :: names(:)
    Integer, Allocatable :: mass_number(:), charge_number(:)
    Real(dp), Allocatable :: binding_energy_mev(:), mass_excess_mev(:)
  End Type xnet_network_t

  Type, Public :: xnet_timing_t
    ! Stage durations in seconds; evolve covers the interval inside full_net.
    Real(dp) :: evolve = 0.0_dp, solve = 0.0_dp, jacobian = 0.0_dp
    Real(dp) :: derivative = 0.0_dp, rates = 0.0_dp, screening = 0.0_dp
  End Type xnet_timing_t

  ! A failed GPU teardown leaves cleanup pending. Burns remain disabled, but finalization can
  ! retry resource release without repeating the array teardown.
  Integer, Parameter :: api_uninitialized = 0, api_ready = 1, api_cleanup_pending = 2
  Integer :: api_state = api_uninitialized
  Character(80) :: api_data_description

  ! Keep separate output segments across burns and initialization lifetimes.
  Integer(i8) :: output_call = 0_i8

Contains

  Subroutine check_worker(ierr,message)
    !-----------------------------------------------------------------------------------------------
    ! Select this worker's preallocated batch bank and check that its NSE scratch is available.
    !-----------------------------------------------------------------------------------------------
    Use xnet_controls, Only: tid, nthread, nzbatchmx, zb_offset, zb_lo, zb_hi
    Use xnet_nse, Only: ynse
    Implicit None

    ! Output variables
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

    ! Application lanes start at one; solver arrays span every worker's reserved bank.
    zb_offset = (tid-1)*nzbatchmx
    zb_lo = zb_offset+1
    zb_hi = zb_offset+nzbatchmx
    Return
  End Subroutine check_worker

  Subroutine xnet_initialize(controls,network,ierr,message,gpu_resources)
    !-----------------------------------------------------------------------------------------------
    ! Load one network and allocate reusable solver workspaces. Reader, EOS and solver errors
    ! may still terminate the application rather than return through ierr.
    !-----------------------------------------------------------------------------------------------
    Use nuclear_data, Only: ny, nname, ia, iz, be, mex, read_nuclear_data, index_from_name
    Use reaction_data, Only: read_reaction_data
    Use xnet_abundances, Only: abundances_initialize, y, yo, yt, ydot, ystart, xext, aext, zext
    Use xnet_conditions, Only: conditions_initialize, tdel, tdel_next, tdel_old, t, tt, to, t9, t9t, t9o, t9dot, &
      & rho, rhot, rhoo, ye, yet, yeo, cv, etae, detaedt9, nt, ntt, nto, ints, intso, &
      & tstart, tstop, tdelstart, nstart, t9start, rhostart, yestart, nh, th, t9h, rhoh, yeh
    Use xnet_controls, Only: validate_xnet_controls, apply_xnet_controls, zone_id, nzevolve, &
      & myid, nproc, tid, nthread, lun_diag, lun_stdout, isolv, sweep, gpu_queue, &
      & nnucout, output_nuc, inucout
    Use xnet_eos, Only: eos_initialize
    Use xnet_flux, Only: flux_init
    Use xnet_integrate_be, Only: be_init
    Use xnet_integrate_bdf, Only: bdf_init
    Use xnet_jacobian, Only: read_jacobian_data
    Use xnet_match, Only: read_match_data
    Use xnet_nnu, Only: tmevnu, fluxcms, nnuspec
    Use xnet_nse, Only: nse_initialize
    Use xnet_screening, Only: screening_init
    Use xnet_preprocess, Only: net_preprocess
#ifdef XNET_GPU
    Use xnet_gpu, Only: gpu_init, gpu_finalize, mydevice
#endif
    Implicit None

    ! Input/Output variables
    Type(xnet_controls_t), Intent(in) :: controls
    Type(xnet_network_t), Intent(out) :: network
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message

    ! Optional variables
    Type(xnet_gpu_t), Optional, Intent(in) :: gpu_resources

    ! Local variables
    Character(10), Parameter :: ascii_files(3) = [Character(10) :: 'sunet', 'netwinv', 'netsu']
    Character(10), Parameter :: required_files(5) = &
      & [Character(10) :: 'sunet', 'netwinv', 'nets3', 'nets4', 'match_data']
    Integer :: i, inuc
#ifdef XNET_GPU
    Type(xnet_gpu_t) :: gpu
    Integer :: cleanup_status
    Character(512) :: cleanup_message
#endif

    ierr = xnet_invalid
    message = ' '
    If ( api_state /= api_uninitialized .or. Allocated(y) ) Then
      ierr = xnet_lifecycle_error
      message = 'XNet is already initialized'
      If ( api_state == api_cleanup_pending ) message = 'Finish XNet finalization before initialization'
      Return
    EndIf
#ifndef XNET_GPU
    If ( Present(gpu_resources) ) Then
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

    ! Preprocessing writes data_dir; the host must arrange exclusive access to that directory.
    If ( controls%iprocess > 0 ) Then
      Call check_network_files(controls%data_dir,ascii_files,ierr,message)
      If ( ierr /= xnet_success ) Return
      Call net_preprocess(lun_stdout,controls%data_dir,controls%data_dir)
    EndIf
    Call check_network_files(controls%data_dir,required_files,ierr,message)
    If ( ierr /= xnet_success ) Return
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
#ifdef XNET_GPU
    ! A resource value tells gpu_init to use the application's current device.
    ! With no supplied handles, XNet creates the resources it needs on that device.
    gpu = xnet_gpu_t()
    If ( Present(gpu_resources) ) gpu = gpu_resources
    Call gpu_init(gpu,ierr,message)
    If ( ierr /= 0 ) Then
      ! Failed initialization may still own resources whose rollback must be retried.
      If ( mydevice >= 0 ) api_state = api_cleanup_pending
      Return
    EndIf
#endif
    Call apply_xnet_controls(controls,ierr,message)
    If ( ierr /= 0 ) Then
#ifdef XNET_GPU
      Call gpu_finalize(cleanup_status,cleanup_message)
      If ( cleanup_status /= 0 ) Then
        api_state = api_cleanup_pending
        message = Trim(message)//'; '//Trim(cleanup_message)
      EndIf
#endif
      Return
    EndIf

    ! Reserve room for either supported zone-ID tuple (three or four integer components).
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
          Write (lun_stdout,*) 'Output Nuc:',i,output_nuc(i),' not found'
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

    ! Keep the same reusable workspace as the standalone driver, with two history endpoints.
    !XDIR XENTER_DATA XASYNC(gpu_queue) &
    !XDIR XCOPYIN(y,yo,yt,ydot,ystart,xext,aext,zext) &
    !XDIR XCOPYIN(tdel,tdel_next,tdel_old,t,tt,to,t9,t9t,t9o,t9dot) &
    !XDIR XCOPYIN(rho,rhot,rhoo,ye,yet,yeo,cv,etae,detaedt9,nt,ntt,nto,ints,intso) &
    !XDIR XCOPYIN(tstart,tstop,tdelstart,nstart,t9start,rhostart,yestart) &
    !XDIR XCOPYIN(nh,th,t9h,rhoh,yeh,tmevnu,fluxcms)

    !XDIR XWAIT(gpu_queue)

    Allocate (network%names(ny),network%mass_number(ny),network%charge_number(ny), &
      & network%binding_energy_mev(ny),network%mass_excess_mev(ny))
    network%names = nname(1:ny)
    network%mass_number = ia
    network%charge_number = iz
    network%binding_energy_mev = be
    network%mass_excess_mev = mex
    api_state = api_ready
    ierr = xnet_success
    Return
  End Subroutine xnet_initialize

  Subroutine xnet_burn_batch(dt_s,active,zone_id,density,temperature,ye,mass_fraction, &
    & restart_dt_s,neutrino_loss,counters,timing,ierr,message,aux_x,aux_a,aux_z,max_steps_taken,data_on_device)
    !-----------------------------------------------------------------------------------------------
    ! Evolve active zones for dt_s seconds at constant density, with constant temperature unless
    ! self-heating is selected. Scientific arrays use (species,lane) or (lane) ordering; zone IDs
    ! and counters remain on the host even when the scientific arrays are on the device.
    !-----------------------------------------------------------------------------------------------
    Use, Intrinsic :: ieee_arithmetic, Only: ieee_is_finite
    Use nuclear_data, Only: ny, aa
    Use xnet_abundances, Only: y, ystart, xext, aext, zext
    Use xnet_conditions, Only: t, t9, rho, ye_work=>ye, tdel, tdel_old, nt, nstart, &
      & tstart, tstop, tdelstart, t9start, rhostart, yestart, nh, th, t9h, rhoh, yeh
    Use xnet_controls, Only: nzbatchmx, nzevolve, szbatch, nzbatch, lzactive, iheat, &
      & zone_work=>zone_id, iaux, ktot, gpu_queue, zb_offset, zb_lo, zb_hi
    Use xnet_evolve, Only: full_net, evolve_integrator_failure, evolve_step_limit
#ifdef XNET_GPU
    Use xnet_gpu, Only: gpu_check_device
#ifdef XNET_OMP_OL
    Use xnet_gpu, Only: stream, stream_sync
#endif
#endif
    Implicit None

    ! Input variables
    Real(dp), Intent(in) :: dt_s                         ! Burn duration (s)
    Real(dp), Target, Intent(in) :: density(:)           ! Density (g/cm^3)
    Logical, Intent(in) :: active(:)
    Integer, Intent(in) :: zone_id(:,:)

    ! Input/Output variables: temperature in K, restart_dt_s in s (zero for fresh startup).
    Real(dp), Target, Intent(inout) :: temperature(:), ye(:), mass_fraction(:,:), restart_dt_s(:)

    ! Output variables
    Real(dp), Target, Intent(out) :: neutrino_loss(:)     ! Integrated weak-reaction loss (erg/g)
    Integer, Intent(out) :: counters(:,:)
    Type(xnet_timing_t), Intent(out) :: timing
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message

    ! Optional variables
    Real(dp), Optional, Target, Intent(in) :: aux_x(:), aux_a(:), aux_z(:)
    Integer, Optional, Intent(out) :: max_steps_taken
    Logical, Optional, Intent(in) :: data_on_device      ! Scientific arrays already mapped on the device

    ! Local variables
    Integer :: n, lane, izb, kstep, evolve_status, failed_zone, id
    Real(dp), Allocatable :: loss_work(:)
    Real(dp) :: total_mass
    Type(xnet_timing_t) :: before
    Character(128) :: failure_ids
    Character(32) :: id_component
    Character(512) :: failure_message
    Character(80) :: failure_reason
    Logical :: on_device
#ifdef XNET_OMP_OL
    Integer :: stream_status
#endif

    ! Establish failure outputs before checking lifecycle, mappings and input values.
    on_device = .false.
    If ( Present(data_on_device) ) on_device = data_on_device
    If ( Present(max_steps_taken) ) max_steps_taken = 0
    timing = xnet_timing_t()
    If ( .not. on_device ) neutrino_loss = 0.0_dp
    counters = 0
    message = ' '
    ierr = xnet_lifecycle_error
    If ( api_state /= api_ready ) Then
      message = 'Initialize XNet before burning'
      If ( api_state == api_cleanup_pending ) message = 'Finish XNet finalization before burning'
      Return
    EndIf
    Call check_worker(ierr,message)
    If ( ierr /= xnet_success ) Return
#ifdef XNET_GPU
    Call gpu_check_device(ierr,message)
    If ( ierr /= 0 ) Return
    If ( on_device ) Then
#ifdef XNET_OMP_OL
      ! OpenMP target work is not ordered on the application's vendor stream.
      Call stream_sync(stream,stream_status)
      If ( stream_status /= 0 ) Then
        ierr = xnet_invalid
        Write (message,'(a,i0)') 'Cannot synchronize the application GPU stream, status ',stream_status
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
    ! Check shapes before indexing arrays, and values only in active lanes.
    ierr = xnet_invalid
    n = Size(active)
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
    If ( .not. on_device ) Then
      Do lane = 1, n
        If ( .not. active(lane) ) Cycle
        If ( .not. ieee_is_finite(density(lane)) .or. .not. ieee_is_finite(temperature(lane)) .or. &
          & .not. ieee_is_finite(ye(lane)) .or. .not. ieee_is_finite(restart_dt_s(lane)) .or. &
          & .not. All(ieee_is_finite(mass_fraction(:,lane))) ) Then
          message = 'Active-zone inputs must be finite'
          Return
        EndIf
        If ( density(lane) <= 0.0_dp .or. temperature(lane) <= 0.0_dp .or. &
          & ye(lane) < 0.0_dp .or. ye(lane) > 1.0_dp .or. restart_dt_s(lane) < 0.0_dp .or. &
          & Any(mass_fraction(:,lane) < 0.0_dp) ) Then
          message = 'Invalid active-zone density, temperature, Ye, composition or restart timestep'
          Return
        EndIf
        total_mass = Sum(mass_fraction(:,lane))
        If ( Present(aux_x) ) Then
          If ( .not. ieee_is_finite(aux_x(lane)) .or. .not. ieee_is_finite(aux_a(lane)) .or. &
            & .not. ieee_is_finite(aux_z(lane)) ) Then
            message = 'Active-zone auxiliary inputs must be finite'
            Return
          EndIf
          If ( aux_x(lane) < 0.0_dp .or. aux_x(lane) > 1.0_dp .or. aux_a(lane) < 0.0_dp .or. &
            & aux_z(lane) < 0.0_dp .or. aux_z(lane) > aux_a(lane) ) Then
            message = 'Invalid auxiliary mass fraction, A or Z'
            Return
          EndIf
          If ( aux_x(lane) > 0.0_dp .and. aux_a(lane) <= 0.0_dp ) Then
            message = 'Positive auxiliary mass requires positive A'
            Return
          EndIf
          total_mass = total_mass + aux_x(lane)
        EndIf
        If ( total_mass <= 0.0_dp ) Then
          message = 'Active-zone composition must contain positive mass'
          Return
        EndIf
      EndDo
    EndIf
    ierr = xnet_success
    If ( .not. Any(active) .and. .not. on_device ) Return

    ! Validation is complete. Select this batch within the current worker's workspace.
    before = current_timing()
    szbatch = 1
    nzbatch = Count(active)
    lzactive(zb_lo:zb_hi) = .false.
    lzactive(zb_lo:zb_lo+n-1) = active
    zone_work(:,zb_lo:zb_hi) = 0
    zone_work(1:Size(zone_id,1),zb_lo:zb_lo+n-1) = zone_id
#ifdef XNET_GPU
    If ( on_device ) Then
      Call burn_device_arrays(dt_s,density,temperature,ye,mass_fraction,restart_dt_s,neutrino_loss, &
        & Size(zone_id,1),kstep,evolve_status,failed_zone,ierr,message,aux_x,aux_a,aux_z)
      If ( ierr /= xnet_success ) Return
      If ( .not. Any(active) ) Return
      Do lane = 1, n
        If ( active(lane) ) counters(:,lane) = ktot(:,zb_offset+lane)
      EndDo
    Else
#endif
    ! Give unused lanes benign values without reading inactive caller storage.
    ystart(:,zb_lo:zb_hi) = 0.0_dp
    xext(zb_lo:zb_hi) = 0.0_dp
    aext(zb_lo:zb_hi) = 1.0_dp
    zext(zb_lo:zb_hi) = 0.0_dp
    iaux(zb_lo:zb_hi) = 0

    ! History indices start at one; timestep uses nstart to locate the first interval.
    nstart(zb_lo:zb_hi) = 1
    tstart(zb_lo:zb_hi) = 0.0_dp
    tstop(zb_lo:zb_hi) = dt_s
    tdelstart(zb_lo:zb_hi) = 0.0_dp
    t9start(zb_lo:zb_hi) = 1.0_dp
    rhostart(zb_lo:zb_hi) = 1.0_dp
    yestart(zb_lo:zb_hi) = 0.5_dp
    Do lane = 1, n
      If ( .not. active(lane) ) Cycle
      izb = zb_offset+lane
      ystart(:,izb) = mass_fraction(:,lane) / aa
      t9start(izb) = temperature(lane)*1.0e-9_dp
      rhostart(izb) = density(lane)
      yestart(izb) = ye(lane)

      ! timestep interprets a negative tdelstart as a supplied step in seconds; the public
      ! argument stays nonnegative. Zero requests the usual fresh-start estimate.
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

    ! The integrator consumes histories. Two identical endpoints represent constant conditions;
    ! self-heating, when enabled, evolves temperature from this initial value.
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
    Call open_burn_output(Size(zone_id,1),ierr,message)
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
    EndIf
    Do lane = 1, n
      If ( .not. active(lane) ) Cycle
      izb = zb_offset+lane
      counters(:,lane) = ktot(:,izb)

      ! Numerical failure requires host shutdown; no physical result or subsequent burn is supported.
      If ( evolve_status /= 0 ) Cycle
      mass_fraction(:,lane) = y(:,izb)*aa
      If ( iheat > 0 ) temperature(lane) = t9(izb)*1.0e9_dp
      ye(lane) = ye_work(izb)
      restart_dt_s(lane) = tdel_old(izb)
      neutrino_loss(lane) = loss_work(izb)
    EndDo
    Deallocate (loss_work)
#ifdef XNET_GPU
    EndIf
#endif
    ! Return per-call diagnostics, including attempted work when integration fails.
    If ( evolve_status == 0 .and. Present(max_steps_taken) ) max_steps_taken = kstep
    timing = current_timing()
    timing%evolve = timing%evolve - before%evolve
    timing%solve = timing%solve - before%solve
    timing%jacobian = timing%jacobian - before%jacobian
    timing%derivative = timing%derivative - before%derivative
    timing%rates = timing%rates - before%rates
    timing%screening = timing%screening - before%screening
    Select Case (evolve_status)
    Case (evolve_integrator_failure)
      ierr = xnet_integrator_failure
      failure_reason = 'integrator-reported convergence/timestep failure; host must terminate'
    Case (evolve_step_limit)
      ierr = xnet_step_limit
      failure_reason = 'maximum integration steps reached; host must terminate'
    End Select
    If ( evolve_status /= 0 ) Then
      ! Convert the solver's bank index back to the application's local lane.
      failed_zone = failed_zone-zb_offset
      Write (failure_ids,'(i0)') zone_id(1,failed_zone)
      Do id = 2, Size(zone_id,1)
        Write (id_component,'(i0)') zone_id(id,failed_zone)
        failure_ids = Trim(failure_ids)//' '//Trim(id_component)
      EndDo
      Write (failure_message,'(a,i0,4a)') 'Zone ',failed_zone,', zone IDs [', &
        & Trim(failure_ids),']: ',Trim(failure_reason)
      message = failure_message
    EndIf
    Return
  End Subroutine xnet_burn_batch

#ifdef XNET_GPU
  Subroutine check_device_batch(density,temperature,ye,mass_fraction,restart_dt_s,neutrino_loss, &
    & ierr,message,aux_x,aux_a,aux_z)
    !-----------------------------------------------------------------------------------------------
    ! Check that scientific arrays are contiguous and mapped on the selected device. Ordinary
    ! Fortran descriptors identify the mappings; this routine does not transfer their values.
    !-----------------------------------------------------------------------------------------------
    Use, Intrinsic :: iso_c_binding, Only: C_LOC, C_SIZE_T, C_SIZEOF
    Use xnet_gpu, Only: device_is_present, mydevice
    Implicit None

    ! Input/Output variables
    Real(dp), Target, Intent(in) :: density(:), temperature(:), ye(:), mass_fraction(:,:), restart_dt_s(:)
    Real(dp), Target, Intent(out) :: neutrino_loss(:)     ! Integrated weak-reaction loss (erg/g)

    ! Optional variables
    Real(dp), Optional, Target, Intent(in) :: aux_x(:), aux_a(:), aux_z(:)
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message

    ! Local variables
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
    ! Validate and evolve scientific arrays on the device. Status and attempted counters return
    ! on the host; physical results are exported only after successful integration.
    !-----------------------------------------------------------------------------------------------
    Use nuclear_data, Only: ny, aa
    Use xnet_abundances, Only: y, ystart, xext, aext, zext
    Use xnet_conditions, Only: t, t9, rho, ye_work=>ye, tdel, tdel_old, nt, nstart, &
      & tstart, tstop, tdelstart, t9start, rhostart, yestart, nh, th, t9h, rhoh, yeh
    Use xnet_controls, Only: nzevolve, lzactive, iheat, ktot, gpu_queue
    Use xnet_evolve, Only: full_net
    Implicit None

    ! Input/Output variables
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
      validation(lane) = 0
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
        validation(lane) = 1
      ElseIf ( density(lane) <= 0.0_dp .or. temperature(lane) <= 0.0_dp .or. &
        & ye(lane) < 0.0_dp .or. ye(lane) > 1.0_dp .or. restart_dt_s(lane) < 0.0_dp .or. negative_mass ) Then
        validation(lane) = 2
      EndIf
    EndDo
    If ( Present(aux_x) ) Then
      !XDIR XLOOP_OUTER(1) XASYNC(gpu_queue) &
      !XDIR XPRESENT(lzactive,validation,mass_sum,aux_x,aux_a,aux_z) &
      !XDIR XPRIVATE(finite_state)
      Do lane = 1, n
        If ( .not. lzactive(lane) .or. validation(lane) /= 0 ) Cycle
        finite_state = Abs(aux_x(lane)) <= Huge(1.0_dp) .and. Abs(aux_a(lane)) <= Huge(1.0_dp) .and. &
          & Abs(aux_z(lane)) <= Huge(1.0_dp)
        If ( .not. finite_state ) Then
          validation(lane) = 3
        ElseIf ( aux_x(lane) < 0.0_dp .or. aux_x(lane) > 1.0_dp .or. aux_a(lane) < 0.0_dp .or. &
          & aux_z(lane) < 0.0_dp .or. aux_z(lane) > aux_a(lane) ) Then
          validation(lane) = 4
        ElseIf ( aux_x(lane) > 0.0_dp .and. aux_a(lane) <= 0.0_dp ) Then
          validation(lane) = 5
        ElseIf ( mass_sum(lane) + aux_x(lane) <= 0.0_dp ) Then
          validation(lane) = 6
        EndIf
      EndDo
    Else
      !XDIR XLOOP_OUTER(1) XASYNC(gpu_queue) &
      !XDIR XPRESENT(lzactive,validation,mass_sum)
      Do lane = 1, n
        If ( lzactive(lane) .and. validation(lane) == 0 .and. mass_sum(lane) <= 0.0_dp ) validation(lane) = 6
      EndDo
    EndIf
    !XDIR XUPDATE XWAIT(gpu_queue) &
    !XDIR XHOST(validation)
    Do lane = 1, n
      If ( validation(lane) == 0 ) Cycle
      ierr = xnet_invalid
      Select Case (validation(lane))
      Case (1)
        message = 'Active-zone inputs must be finite'
      Case (2)
        message = 'Invalid active-zone density, temperature, Ye, composition or restart timestep'
      Case (3)
        message = 'Active-zone auxiliary inputs must be finite'
      Case (4)
        message = 'Invalid auxiliary mass fraction, A or Z'
      Case (5)
        message = 'Positive auxiliary mass requires positive A'
      Case (6)
        message = 'Active-zone composition must contain positive mass'
      End Select
      GoTo 900
    EndDo
    If ( .not. Any(lzactive) ) GoTo 900

    ! Initialize inactive workspace lanes with benign values without reading their scientific inputs.
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
      t9start(lane) = 1.0_dp
      rhostart(lane) = 1.0_dp
      yestart(lane) = 0.5_dp
      !XDIR XLOOP_SERIAL(1)
      Do k = 1, ny
        ystart(k,lane) = 0.0_dp
      EndDo
      If ( lzactive(lane) ) Then
        !XDIR XLOOP_SERIAL(1)
        Do k = 1, ny
          ystart(k,lane) = mass_fraction(k,lane) / aa(k)
        EndDo
        t9start(lane) = temperature(lane)*1.0e-9_dp
        rhostart(lane) = density(lane)
        yestart(lane) = ye(lane)
        tdelstart(lane) = -restart_dt_s(lane)
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
    If ( ierr /= xnet_success ) GoTo 900
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
          mass_fraction(k,lane) = y(k,lane)*aa(k)
        EndDo
        If ( iheat > 0 ) temperature(lane) = t9(lane)*1.0e9_dp
        ye(lane) = ye_work(lane)
        restart_dt_s(lane) = tdel_old(lane)
        neutrino_loss(lane) = loss_work(lane)
      EndDo
    EndIf

900 Continue
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

  Subroutine check_network_files(data_dir,filenames,ierr,message)
    !-----------------------------------------------------------------------------------------------
    ! Check access before installing network state. Contents still use the existing fatal readers.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Input/Output variables
    Character(*), Intent(in) :: data_dir, filenames(:)
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message

    ! Local variables
    Integer :: i, input_unit, input_status
    Logical :: exists

    ierr = xnet_invalid
    message = ' '
    Do i = 1, Size(filenames)
      Inquire (file=Trim(data_dir)//'/'//Trim(filenames(i)),exist=exists)
      If ( .not. exists ) Then
        message = 'Missing network file: '//Trim(filenames(i))
        Return
      EndIf
      Open (newunit=input_unit,file=Trim(data_dir)//'/'//Trim(filenames(i)), &
        & status='old',action='read',access='stream',form='unformatted',iostat=input_status)
      If ( input_status /= 0 ) Then
        message = 'Cannot read network file: '//Trim(filenames(i))
        Return
      EndIf
      Close (input_unit)
    EndDo
    ierr = xnet_success
    Return
  End Subroutine check_network_files

  Subroutine open_burn_output(zone_id_components,ierr,message)
    !-----------------------------------------------------------------------------------------------
    ! Open a separate output segment for this call's local 0..dt history. Call and lane numbers
    ! distinguish repeated diagnostic zone IDs without changing the standalone record layout.
    !-----------------------------------------------------------------------------------------------
    Use nuclear_data, Only: ny, zz, aa, nname
    Use xnet_controls, Only: itsout, lzactive, lun_ts, lun_ev, bin_file_base, ev_file_base, zone_id, &
      & zb_offset, zb_lo, zb_hi, descript, kstmx, kitmx, iweak0, iscrn, iconvc, changemx, tolm, tolc, yacc, ymin, &
      & tdel_maxmult, iheat, isolv, nnucout, nnucout_string, inucout
    Use xnet_flux, Only: flx, ifl_orig, ifl_term
    Use xnet_match, Only: mflx
    Implicit None

    ! Input/Output variables
    Integer, Intent(in) :: zone_id_components
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message

    ! Local variables
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
      Write (suffix,'(a,i0,a,i0)') '_call',call_number,'_lane',lane-zb_offset
      filename = Trim(bin_file_base)//Trim(suffix)
      Open (newunit=lun_ts(lane),file=Trim(filename),status='new',form='unformatted', &
        & action='write',iostat=output_status)
      If ( output_status /= 0 ) Exit
      Write (lun_ts(lane)) descript,api_data_description
      Write (lun_ts(lane)) kstmx,kitmx,iweak0,iscrn,iconvc,changemx,tolm,tolc,yacc,ymin,tdel_maxmult,iheat,isolv

      ! Identify the caller zone in the existing input label; keep the record layout.
      Write (zone_label,'(a,4(1x,i0))') 'XNet API zone_id:',zone_id(1:zone_id_components,lane)
      Write (lun_ts(lane)) zone_label,abundance_description
      Write (lun_ts(lane)) input_name,thermo_description
      Write (lun_ts(lane)) ny,zz,aa
      Write (lun_ts(lane)) mflx,ifl_orig,ifl_term
      If ( itsout >= 2 ) Then
        filename = Trim(ev_file_base)//Trim(suffix)
        Open (newunit=lun_ev(lane),file=Trim(filename),status='new',action='write',iostat=output_status)
        If ( output_status /= 0 ) Exit
        header_format = '(a4,a15,5a10,a4)'
        If ( nnucout > 0 ) header_format = '(a4,a15,5a10,'//Trim(nnucout_string)//'a9,a4)'
        Write (lun_ev(lane),header_format) &
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
    ! Close the current worker's output files, including any partial set opened before a failure.
    !-----------------------------------------------------------------------------------------------
    Use xnet_controls, Only: lun_ts, lun_ev, zb_lo, zb_hi
    Implicit None

    ! Local variables
    Integer :: lane

    Do lane = zb_lo, zb_hi
      ! NEWUNIT may return negative units. Zero alone denotes an unopened API output slot.
      If ( lun_ts(lane) /= 0 ) Close (lun_ts(lane))
      If ( lun_ev(lane) /= 0 ) Close (lun_ev(lane))
      lun_ts(lane) = 0
      lun_ev(lane) = 0
    EndDo
    Return
  End Subroutine close_burn_output

  Subroutine xnet_nse_composition(density,temperature,ye,mass_fraction,ierr,message)
    !-----------------------------------------------------------------------------------------------
    ! Return mass fractions in network order for density in g/cm^3 and temperature in K.
    ! Existing NSE solver failures may still terminate the application.
    !-----------------------------------------------------------------------------------------------
    Use, Intrinsic :: ieee_arithmetic, Only: ieee_is_finite
    Use nuclear_data, Only: ny, aa
    Use xnet_nse, Only: nse_solve, ynse
#ifdef XNET_GPU
    Use xnet_gpu, Only: gpu_check_device
#endif
    Implicit None

    ! Input/Output variables
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
    Call nse_solve(density,temperature*1.0e-9_dp,ye)

    ! Match the existing CHIMERA A*ynse convention without normalization or reordering.
    mass_fraction = aa*ynse
    ierr = xnet_success
    Return
  End Subroutine xnet_nse_composition

  Subroutine xnet_finalize(ierr,message)
    !-----------------------------------------------------------------------------------------------
    ! Release XNet workspaces and owned resources. Caller-owned GPU resources remain intact;
    ! a failed GPU cleanup can be retried by calling this routine again.
    !-----------------------------------------------------------------------------------------------
    Use nuclear_data, Only: nuclear_data_finalize
    Use reaction_data, Only: reaction_data_finalize
    Use xnet_abundances, Only: abundances_finalize, y, yo, yt, ydot, ystart, xext, aext, zext
    Use xnet_conditions, Only: conditions_finalize, tdel, tdel_next, tdel_old, t, tt, to, t9, t9t, t9o, t9dot, &
      & rho, rhot, rhoo, ye, yet, yeo, cv, etae, detaedt9, nt, ntt, nto, ints, intso, &
      & tstart, tstop, tdelstart, nstart, t9start, rhostart, yestart, nh, th, t9h, rhoh, yeh
    Use xnet_controls, Only: controls_finalize, gpu_queue
#ifdef XNET_OMP
    Use xnet_controls, Only: nthread
#endif
    Use xnet_eos, Only: eos_finalize
    Use xnet_ffn, Only: ffn_finalize
    Use xnet_flux, Only: flux_finalize
    Use xnet_integrate_be, Only: be_finalize
    Use xnet_integrate_bdf, Only: bdf_finalize
    Use xnet_jacobian, Only: jacobian_finalize
    Use xnet_match, Only: match_finalize
    Use xnet_nnu, Only: nnu_finalize, tmevnu, fluxcms
    Use xnet_nse, Only: nse_finalize
    Use xnet_screening, Only: screening_finalize
#ifdef XNET_GPU
    Use xnet_gpu, Only: gpu_check_device, gpu_finalize
#endif
    Implicit None

    ! Output variables
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message

    ! Local variables
#ifdef XNET_OMP
    Integer :: final_threads
#endif

    ierr = xnet_success
    message = ' '
    If ( api_state == api_uninitialized ) Return
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
    If ( api_state == api_ready ) Then
#ifdef XNET_GPU
      Call gpu_check_device(ierr,message)
      If ( ierr /= 0 ) Return
#endif
      ! Release the mappings established here before their owning CPU allocations.
      !XDIR XEXIT_DATA XASYNC(gpu_queue) &
      !XDIR XDELETE(y,yo,yt,ydot,ystart,xext,aext,zext) &
      !XDIR XDELETE(tdel,tdel_next,tdel_old,t,tt,to,t9,t9t,t9o,t9dot) &
      !XDIR XDELETE(rho,rhot,rhoo,ye,yet,yeo,cv,etae,detaedt9,nt,ntt,nto,ints,intso) &
      !XDIR XDELETE(tstart,tstop,tdelstart,nstart,t9start,rhostart,yestart) &
      !XDIR XDELETE(nh,th,t9h,rhoh,yeh,tmevnu,fluxcms)
      !XDIR XWAIT(gpu_queue)
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

  Function current_timing() Result(timing)
    !-----------------------------------------------------------------------------------------------
    ! Snapshot the current worker's cumulative timers. Differences give per-call seconds.
    !-----------------------------------------------------------------------------------------------
    Use xnet_timers, Only: timer_xnet, timer_solve, timer_jacob, timer_deriv, timer_csect, timer_scrn
    Implicit None

    ! Result variable
    Type(xnet_timing_t) :: timing

    timing%evolve = timer_xnet
    timing%solve = timer_solve
    timing%jacobian = timer_jacob
    timing%derivative = timer_deriv
    timing%rates = timer_csect
    timing%screening = timer_scrn
    Return
  End Function current_timing

End Module xnet_api
