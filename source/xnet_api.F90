! Supported single-instance embedding procedures.
#include "xnet_macros.fh"

Module xnet_api
  Use xnet_types, Only: dp
  Use xnet_controls, Only: xnet_controls_t, set_xnet_controls_defaults
  Use xnet_gpu, Only: xnet_gpu_resources_t
  Implicit None
  Private

  Integer, Parameter, Public :: xnet_success = 0, xnet_invalid = 1
  Integer, Parameter, Public :: xnet_lifecycle_error = 2, xnet_unsupported = 3
  Integer, Parameter, Public :: xnet_integrator_failure = 4, xnet_step_limit = 5
  Public :: dp, xnet_controls_t, set_xnet_controls_defaults, xnet_gpu_resources_t
  Public :: xnet_initialize, xnet_burn_batch, xnet_nse_composition, xnet_finalize

  Type, Public :: xnet_network_t
    Character(5), Allocatable :: names(:)
    Integer, Allocatable :: mass_number(:), charge_number(:)
    Real(dp), Allocatable :: binding_energy_mev(:), mass_excess_mev(:)
  End Type xnet_network_t

  Type, Public :: xnet_timing_t
    Real(dp) :: seconds = 0.0_dp, solve = 0.0_dp, jacobian = 0.0_dp
    Real(dp) :: derivative = 0.0_dp, rates = 0.0_dp, screening = 0.0_dp
  End Type xnet_timing_t

  ! Distinguish this lifecycle from applications using the private module state directly.
  Logical :: api_initialized = .false.

Contains

  Subroutine xnet_initialize(controls,network,ierr,message,gpu_resources)
    ! Load a preprocessed network once. Reader, EOS and solver failures may still terminate.
    !$ Use omp_lib, Only: omp_get_max_threads
#ifdef XNET_EMBEDDING
    Use nuclear_data, Only: ny, nname, ia, iz, be, mex, read_nuclear_data
    Use reaction_data, Only: read_reaction_data
    Use xnet_abundances, Only: abundances_initialize, y, yo, yt, ydot, ystart, xext, aext, zext
    Use xnet_conditions, Only: conditions_initialize, tdel, tdel_next, tdel_old, t, tt, to, t9, t9t, t9o, t9dot, &
      & rho, rhot, rhoo, ye, yet, yeo, cv, etae, detaedt9, nt, ntt, nto, ints, intso, &
      & tstart, tstop, tdelstart, nstart, t9start, rhostart, yestart, nh, th, t9h, rhoh, yeh
    Use xnet_controls, Only: validate_xnet_controls, apply_xnet_controls, zone_id, nzevolve, &
      & myid, nproc, tid, nthread, lun_diag, lun_stdout, isolv, sweep, gpu_queue
    Use xnet_eos, Only: eos_initialize
    Use xnet_flux, Only: flux_init
    Use xnet_integrate_be, Only: be_init
    Use xnet_integrate_bdf, Only: bdf_init
    Use xnet_jacobian, Only: read_jacobian_data
    Use xnet_match, Only: read_match_data
    Use xnet_nnu, Only: tmevnu, fluxcms, nnuspec
    Use xnet_nse, Only: nse_initialize
    Use xnet_screening, Only: screening_init
#ifdef XNET_GPU
    Use xnet_gpu, Only: gpu_initialize_embedded, gpu_finalize_embedded
#endif
#endif
    Implicit None
    Type(xnet_controls_t), Intent(in) :: controls
    Type(xnet_network_t), Intent(out) :: network
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message
    Type(xnet_gpu_resources_t), Optional, Intent(in) :: gpu_resources
#ifdef XNET_EMBEDDING
    Character(80) :: data_description
    Character(10), Parameter :: required_files(5) = &
      & [Character(10) :: 'sunet', 'netwinv', 'nets3', 'nets4', 'match_data']
    Integer :: i, input_unit, input_status
    Logical :: exists
#ifdef XNET_GPU
    Integer :: cleanup_status
    Character(512) :: cleanup_message
#endif

    ierr = xnet_invalid
    message = ' '
    If ( api_initialized .or. Allocated(y) ) Then
      ierr = xnet_lifecycle_error
      message = 'XNet is already initialized'
      Return
    EndIf
    !$ If ( omp_get_max_threads() /= 1 ) Then
    !$   ierr = xnet_unsupported
    !$   message = 'Embedded calls require one host OpenMP thread'
    !$   Return
    !$ EndIf
#ifndef XNET_GPU
    If ( Present(gpu_resources) ) Then
      ierr = xnet_unsupported
      message = 'GPU resources require a supported GPU library build'
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
    If ( controls%iprocess /= 0 .or. controls%ineutrino /= 0 .or. controls%itsout > 0 ) Then
      ierr = xnet_unsupported
      message = 'Embedded calls require preprocessed data, no neutrino capture histories, and no time-series files'
      Return
    EndIf
    ! Check file access before installing state. File contents still use the existing fatal readers.
    Do i = 1, Size(required_files)
      Inquire(file=Trim(controls%data_dir)//'/'//Trim(required_files(i)),exist=exists)
      If ( .not. exists ) Then
        message = 'Missing network file: '//Trim(required_files(i))
        Return
      EndIf
      Open(newunit=input_unit,file=Trim(controls%data_dir)//'/'//Trim(required_files(i)), &
        & status='old',action='read',access='stream',form='unformatted',iostat=input_status)
      If ( input_status /= 0 ) Then
        message = 'Cannot read network file: '//Trim(required_files(i))
        Return
      EndIf
      Close(input_unit)
    EndDo
    myid = 0
    nproc = 1
    tid = 1
    nthread = 1
    sweep = 'x'
    lun_diag = lun_stdout
#ifdef XNET_GPU
    ! Attach before any initializer creates device mappings or records device pointers.
    Call gpu_initialize_embedded(gpu_resources,ierr,message)
    If ( ierr /= 0 ) Return
#endif
    Call apply_xnet_controls(controls,ierr,message)
    If ( ierr /= 0 ) Then
#ifdef XNET_GPU
      Call gpu_finalize_embedded(cleanup_status,cleanup_message)
#endif
      Return
    EndIf
    ! Both real consumers carry diagnostic integer tuples, with three or four entries.
    Deallocate (zone_id)
    Allocate (zone_id(4,nzevolve))
    zone_id = 0
    Call read_nuclear_data(controls%data_dir,data_description)
    Call read_reaction_data(controls%data_dir)
    Call read_jacobian_data(controls%data_dir)
    Call read_match_data(controls%data_dir)
    Call screening_init
    Call flux_init
    Call eos_initialize
    If ( isolv == 1 ) Call be_init
    If ( isolv == 3 ) Call bdf_init
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
    api_initialized = .true.
    ierr = xnet_success
#else
    ierr = xnet_unsupported
    message = 'Embedding requires a dense single-thread serial CPU or supported GPU build'
#endif
    Return
  End Subroutine xnet_initialize

  Subroutine xnet_burn_batch(dt_s,active,zone_id,density,temperature,ye,mass_fraction, &
    & restart_dt_s,neutrino_loss,counters,timing,ierr,message,aux_x,aux_a,aux_z,max_steps_taken,data_on_device)
    ! Constant density, with constant temperature unless self-heating is selected.
#ifdef XNET_EMBEDDING
    Use, Intrinsic :: ieee_arithmetic, Only: ieee_is_finite
    Use nuclear_data, Only: ny, aa
    Use xnet_abundances, Only: y, ystart, xext, aext, zext
    Use xnet_conditions, Only: t, t9, rho, ye_work=>ye, tdel, tdel_old, nt, nstart, &
      & tstart, tstop, tdelstart, t9start, rhostart, yestart, nh, th, t9h, rhoh, yeh
    Use xnet_controls, Only: nzbatchmx, nzevolve, szbatch, nzbatch, lzactive, iheat, &
      & zone_work=>zone_id, iaux, ktot, gpu_queue
    Use xnet_evolve, Only: full_net, evolve_integrator_failure, evolve_step_limit
#ifdef XNET_GPU
    Use xnet_gpu, Only: gpu_check_embedded_device
#endif
#endif
    Implicit None
    Real(dp), Intent(in) :: dt_s
    Real(dp), Target, Intent(in) :: density(:)
    Logical, Intent(in) :: active(:)
    Integer, Intent(in) :: zone_id(:,:)
    Real(dp), Target, Intent(inout) :: temperature(:), ye(:), mass_fraction(:,:), restart_dt_s(:)
    Real(dp), Target, Intent(out) :: neutrino_loss(:)
    Integer, Intent(out) :: counters(:,:)
    Type(xnet_timing_t), Intent(out) :: timing
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message
    Real(dp), Optional, Target, Intent(in) :: aux_x(:), aux_a(:), aux_z(:)
    Integer, Optional, Intent(out) :: max_steps_taken
    Logical, Optional, Intent(in) :: data_on_device
#ifdef XNET_EMBEDDING
    Integer :: n, lane, kstep, evolve_status, failed_zone, id
    Real(dp), Allocatable :: loss_work(:)
    Real(dp) :: total_mass
    Type(xnet_timing_t) :: before
    Character(128) :: failure_ids
    Character(32) :: id_component
    Character(512) :: failure_message
    Character(80) :: failure_reason
    Logical :: on_device

    on_device = .false.
    If ( Present(data_on_device) ) on_device = data_on_device
    If ( Present(max_steps_taken) ) max_steps_taken = 0
    timing = xnet_timing_t()
    If ( .not. on_device ) neutrino_loss = 0.0_dp
    counters = 0
    message = ' '
    ierr = xnet_lifecycle_error
    If ( .not. api_initialized ) Then
      message = 'Initialize XNet before burning'
      Return
    EndIf
#ifdef XNET_GPU
    Call gpu_check_embedded_device(ierr,message)
    If ( ierr /= 0 ) Return
    If ( on_device ) Then
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

    before = current_timing()
    szbatch = 1
    nzbatch = Count(active)
    lzactive = .false.
    lzactive(1:n) = active
    zone_work = 0
    zone_work(1:Size(zone_id,1),1:n) = zone_id
#ifdef XNET_GPU
    If ( on_device ) Then
      Call burn_device_arrays(dt_s,density,temperature,ye,mass_fraction,restart_dt_s,neutrino_loss, &
        & kstep,evolve_status,failed_zone,ierr,message,aux_x,aux_a,aux_z)
      If ( ierr /= xnet_success ) Return
      If ( .not. Any(active) ) Return
      Do lane = 1, n
        If ( active(lane) ) counters(:,lane) = ktot(:,lane)
      EndDo
    Else
#endif
    ystart = 0.0_dp
    xext = 0.0_dp
    aext = 1.0_dp
    zext = 0.0_dp
    iaux = 0
    ! The first endpoint is index one; zero can reach history element zero in timestep.
    nstart = 1
    tstart = 0.0_dp
    tstop = dt_s
    tdelstart = 0.0_dp
    t9start = 1.0_dp
    rhostart = 1.0_dp
    yestart = 0.5_dp
    Do lane = 1, n
      If ( .not. active(lane) ) Cycle
      ystart(:,lane) = mass_fraction(:,lane) / aa
      t9start(lane) = temperature(lane)*1.0e-9_dp
      rhostart(lane) = density(lane)
      yestart(lane) = ye(lane)
      ! Preserve the CHIMERA startup hint convention without exposing its sign encoding.
      tdelstart(lane) = -restart_dt_s(lane)
      If ( Present(aux_x) ) Then
        If ( aux_x(lane) > 0.0_dp ) Then
          xext(lane) = aux_x(lane)
          aext(lane) = aux_a(lane)
          zext(lane) = aux_z(lane)
          iaux(lane) = 1
        EndIf
      EndIf
    EndDo
    nh = 2
    th(1,:) = tstart
    th(2,:) = tstop
    t9h(1,:) = t9start
    t9h(2,:) = t9start
    rhoh(1,:) = rhostart
    rhoh(2,:) = rhostart
    yeh(1,:) = yestart
    yeh(2,:) = yestart
    tdel = 0.0_dp
    nt = nstart
    t = tstart
    t9 = t9start
    rho = rhostart
    ye_work = yestart
    y = ystart
    ! Host inputs remain authoritative even when the caller has stale device mappings.
    ! Transfer only XNet-owned workspace; arbitrary host array sections retain their existing behavior.
    !XDIR XUPDATE XASYNC(gpu_queue) &
    !XDIR XDEVICE(xext,aext,zext,lzactive,tdel,t,t9,rho,ye_work,y,nt) &
    !XDIR XDEVICE(tstart,tstop,tdelstart,nstart,t9start,rhostart,yestart,ystart) &
    !XDIR XDEVICE(nh,th,t9h,rhoh,yeh)

    Allocate (loss_work(nzevolve))
    Call full_net(kstep,loss_work,evolve_status,failed_zone)
    ! API results do not depend on diagnostic verbosity or successful final output.
    !XDIR XUPDATE XWAIT(gpu_queue) &
    !XDIR XHOST(ktot)
    If ( evolve_status == 0 ) Then
      !XDIR XUPDATE XWAIT(gpu_queue) &
      !XDIR XHOST(y,t9,ye_work,tdel_old)
    EndIf
    Do lane = 1, n
      If ( .not. active(lane) ) Cycle
      counters(:,lane) = ktot(:,lane)
      ! Numerical failure requires host shutdown; no physical result or subsequent burn is supported.
      If ( evolve_status /= 0 ) Cycle
      mass_fraction(:,lane) = y(:,lane)*aa
      If ( iheat > 0 ) temperature(lane) = t9(lane)*1.0e9_dp
      ye(lane) = ye_work(lane)
      restart_dt_s(lane) = tdel_old(lane)
      neutrino_loss(lane) = loss_work(lane)
    EndDo
    Deallocate (loss_work)
#ifdef XNET_GPU
    EndIf
#endif
    If ( evolve_status == 0 .and. Present(max_steps_taken) ) max_steps_taken = kstep
    timing = current_timing()
    timing%seconds = timing%seconds - before%seconds
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
      Write(failure_ids,'(i0)') zone_id(1,failed_zone)
      Do id = 2, Size(zone_id,1)
        Write(id_component,'(i0)') zone_id(id,failed_zone)
        failure_ids = Trim(failure_ids)//' '//Trim(id_component)
      EndDo
      Write(failure_message,'(a,i0,4a)') 'Zone ',failed_zone,', zone IDs [', &
        & Trim(failure_ids),']: ',Trim(failure_reason)
      message = failure_message
    EndIf
#else
    If ( Present(max_steps_taken) ) max_steps_taken = 0
    timing = xnet_timing_t()
    neutrino_loss = 0.0_dp
    counters = 0
    ierr = xnet_unsupported
    message = 'Embedding requires a dense single-thread serial CPU or supported GPU build'
#endif
    Return
  End Subroutine xnet_burn_batch

#if defined(XNET_EMBEDDING) && defined(XNET_GPU)
  Subroutine check_device_batch(density,temperature,ye,mass_fraction,restart_dt_s,neutrino_loss, &
    & ierr,message,aux_x,aux_a,aux_z)
    ! Ordinary array descriptors identify mappings on the device already selected by the host.
    Use, Intrinsic :: iso_c_binding, Only: C_LOC, C_SIZE_T, C_SIZEOF
    Use xnet_gpu, Only: device_is_present, mydevice
    Implicit None
    Real(dp), Target, Intent(in) :: density(:), temperature(:), ye(:), mass_fraction(:,:), restart_dt_s(:)
    Real(dp), Target, Intent(out) :: neutrino_loss(:)
    Real(dp), Optional, Target, Intent(in) :: aux_x(:), aux_a(:), aux_z(:)
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message
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
    & kstep,evolve_status,failed_zone,ierr,message,aux_x,aux_a,aux_z)
    ! Validate, prepare and extract scientific arrays on the device; status and counters return on host.
    Use, Intrinsic :: ieee_arithmetic, Only: ieee_is_finite
    Use nuclear_data, Only: ny, aa
    Use xnet_abundances, Only: y, ystart, xext, aext, zext
    Use xnet_conditions, Only: t, t9, rho, ye_work=>ye, tdel, tdel_old, nt, nstart, &
      & tstart, tstop, tdelstart, t9start, rhostart, yestart, nh, th, t9h, rhoh, yeh
    Use xnet_controls, Only: nzevolve, lzactive, iheat, ktot, gpu_queue
    Use xnet_evolve, Only: full_net
    Implicit None
    Real(dp), Intent(in) :: dt_s, density(:)
    Real(dp), Intent(inout) :: temperature(:), ye(:), mass_fraction(:,:), restart_dt_s(:)
    Real(dp), Intent(out) :: neutrino_loss(:)
    Real(dp), Optional, Intent(in) :: aux_x(:), aux_a(:), aux_z(:)
    Integer, Intent(out) :: kstep, evolve_status, failed_zone, ierr
    Character(*), Intent(out) :: message
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
      finite_state = ieee_is_finite(density(lane)) .and. ieee_is_finite(temperature(lane)) .and. &
        & ieee_is_finite(ye(lane)) .and. ieee_is_finite(restart_dt_s(lane))
      negative_mass = .false.
      total_mass = 0.0_dp
      !XDIR XLOOP_SERIAL(1)
      Do k = 1, ny
        finite_state = finite_state .and. ieee_is_finite(mass_fraction(k,lane))
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
      !XDIR XPRESENT(lzactive,validation,mass_sum,aux_x,aux_a,aux_z)
      Do lane = 1, n
        If ( .not. lzactive(lane) .or. validation(lane) /= 0 ) Cycle
        If ( .not. ieee_is_finite(aux_x(lane)) .or. .not. ieee_is_finite(aux_a(lane)) .or. &
          & .not. ieee_is_finite(aux_z(lane)) ) Then
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
    Call full_net(kstep,loss_work,evolve_status,failed_zone)
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

  Subroutine xnet_nse_composition(density,temperature,ye,mass_fraction,ierr,message)
    ! Return a copy of A*ynse in network order for density in g/cm^3 and temperature in K.
    ! Existing NSE solver failures may still terminate the host application.
#ifdef XNET_EMBEDDING
    Use, Intrinsic :: ieee_arithmetic, Only: ieee_is_finite
    Use nuclear_data, Only: ny, aa
    Use xnet_nse, Only: nse_solve, ynse
#ifdef XNET_GPU
    Use xnet_gpu, Only: gpu_check_embedded_device
#endif
#endif
    Implicit None
    Real(dp), Intent(in) :: density, temperature, ye
    Real(dp), Intent(out) :: mass_fraction(:)
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message

    mass_fraction = 0.0_dp
    message = ' '
#ifdef XNET_EMBEDDING
    ierr = xnet_lifecycle_error
    If ( .not. api_initialized ) Then
      message = 'Initialize XNet before requesting NSE composition'
      Return
    EndIf
#ifdef XNET_GPU
    Call gpu_check_embedded_device(ierr,message)
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
#else
    ierr = xnet_unsupported
    message = 'Embedding requires a dense single-thread serial CPU or supported GPU build'
#endif
    Return
  End Subroutine xnet_nse_composition

  Subroutine xnet_finalize(ierr,message)
    ! Release XNet workspaces and restore borrowed resources without destroying host state.
#ifdef XNET_EMBEDDING
    Use nuclear_data, Only: nuclear_data_finalize
    Use reaction_data, Only: reaction_data_finalize
    Use xnet_abundances, Only: abundances_finalize, y, yo, yt, ydot, ystart, xext, aext, zext
    Use xnet_conditions, Only: conditions_finalize, tdel, tdel_next, tdel_old, t, tt, to, t9, t9t, t9o, t9dot, &
      & rho, rhot, rhoo, ye, yet, yeo, cv, etae, detaedt9, nt, ntt, nto, ints, intso, &
      & tstart, tstop, tdelstart, nstart, t9start, rhostart, yestart, nh, th, t9h, rhoh, yeh
    Use xnet_controls, Only: controls_finalize, gpu_queue
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
    Use xnet_gpu, Only: gpu_check_embedded_device, gpu_finalize_embedded
#endif
#endif
    Implicit None
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message
    ierr = xnet_success
    message = ' '
#ifdef XNET_EMBEDDING
    If ( .not. api_initialized ) Return
#ifdef XNET_GPU
    Call gpu_check_embedded_device(ierr,message)
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
    api_initialized = .false.
#ifdef XNET_GPU
    Call gpu_finalize_embedded(ierr,message)
#endif
#else
    ierr = xnet_unsupported
    message = 'Embedding requires a dense single-thread serial CPU or supported GPU build'
#endif
    Return
  End Subroutine xnet_finalize

#ifdef XNET_EMBEDDING
  Function current_timing() Result(timing)
    Use xnet_timers, Only: timer_xnet, timer_solve, timer_jacob, timer_deriv, timer_csect, timer_scrn
    Implicit None
    Type(xnet_timing_t) :: timing
    timing%seconds = timer_xnet
    timing%solve = timer_solve
    timing%jacobian = timer_jacob
    timing%derivative = timer_deriv
    timing%rates = timer_csect
    timing%screening = timer_scrn
    Return
  End Function current_timing
#endif

End Module xnet_api
