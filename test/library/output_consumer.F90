Program output_consumer
  ! Real API caller and independent full_net state/output reference for constant-condition burns.
  Use xnet_api, Only: dp, xnet_controls_t, xnet_network_t, xnet_timing_t, &
    & set_xnet_controls_defaults, xnet_initialize, xnet_burn_batch, xnet_finalize, &
    & xnet_success, xnet_invalid, xnet_step_limit, xnet_integrator_failure
  Use consumer_fixture, Only: fixture_state, write_state, check
  Implicit None
  Integer, Parameter :: lanes = 4
  Type(xnet_controls_t) :: controls
  Type(xnet_network_t) :: network
  Type(xnet_timing_t) :: timing
  Integer :: ierr, solver, heat, level, ids(4,lanes), counters(5,lanes), steps, i, unit
  Integer :: output_call = 0
  Character(80) :: data_dir, argument, mode
  Character(512) :: message
  Character(80) :: filename
  Logical :: active(lanes), opened, direct
  Real(dp) :: density(lanes), temperature(lanes), ye(lanes), restart(lanes), loss(lanes)
  Real(dp) :: aux_x(lanes), aux_a(lanes), aux_z(lanes), saved_temperature(lanes)
  Real(dp), Allocatable :: x(:,:), saved_x(:,:)

  Call check(Command_Argument_Count() == 5,'expected data_dir, solver, heat, itsout, mode')
  Call Get_Command_Argument(1,data_dir)
  Call Get_Command_Argument(2,argument)
  Read(argument,*) solver
  Call Get_Command_Argument(3,argument)
  Read(argument,*) heat
  Call Get_Command_Argument(4,argument)
  Read(argument,*) level
  Call Get_Command_Argument(5,mode)
  direct = Trim(mode) == 'reference'
  Call set_xnet_controls_defaults(controls)
  controls%data_dir = data_dir
  controls%nzbatchmx = lanes
  controls%isolv = solver
  controls%iheat = heat
  controls%idiag = -2
  controls%itsout = level
  controls%bin_file_base = 'ts'
  controls%ev_file_base = 'ev'
  controls%description = [Character(80) :: 'API output regression', 'constant conditions', 'public C/O fixture']
  If ( mode == 'species0' ) Then
    Call check(controls%nnucout == 0 .and. Size(controls%output_nuclei) == 0,'default output species selection')
  ElseIf ( mode == 'species1' ) Then
    controls%nnucout = 1
    controls%output_nuclei = [Character(5) :: 'c12']
  Else
    controls%nnucout = 3
    controls%output_nuclei = [Character(5) :: 'c12', 'o16', 'badxx']
  EndIf
  controls%t9nse = 11.0_dp
  If ( solver == 3 ) Then
    controls%kitmx = 10
    controls%iconvc = 3
    controls%ymin = 1.0e-99_dp
  EndIf
  If ( mode == 'step_limit' ) controls%kstmx = 1
  If ( mode == 'integrator' ) Then
    controls%tolc = 1.0e-30_dp
    If ( solver == 1 ) Then
      controls%kitmx = 1
      controls%iconvc = 1
    Else
      controls%tolc = 1.0e-100_dp
      controls%yacc = 1.0e-100_dp
    EndIf
  EndIf
  Call initialize
  Allocate(x(Size(network%names),lanes),saved_x(Size(network%names),lanes))
  Do i = 1, Size(network%names)
    Write(*,'(a,1x,a,2(1x,i0),2(1x,es26.17e3))') 'META',Trim(Adjustl(network%names(i))), &
      & network%mass_number(i),network%charge_number(i),network%binding_energy_mev(i),network%mass_excess_mev(i)
  EndDo
  Call reset_fixture
  ids(:,1) = [-huge(1),-7,9001,42]
  ids(:,2) = ids(:,1)
  ids(:,3) = [101,0,-3,0]
  ids(:,4) = ids(:,1)

  If ( mode == 'step_limit' .or. mode == 'integrator' ) Then
    active = [.false.,.true.,.false.,.false.]
    Call burn('failed',lanes,4,0.1_dp)
    If ( mode == 'step_limit' ) Call check(ierr == xnet_step_limit,'reported step-limit failure')
    If ( mode == 'integrator' ) Call check(ierr == xnet_integrator_failure,'reported integrator failure')
    Call check(Index(message,'Zone 2, zone IDs [') == 1,'failure preserves original lane/IDs')
    Call check(Index(message,'host must terminate') > 0,'failure requires host termination')
    Call check(steps == 0,'failed burn does not report successful completion')
    Call assert_closed('ts_call1_lane2')
    Call assert_closed('ev_call1_lane2')
    Write(*,'(a)') 'OUTPUT_FATAL_CHECKS_PASSED'
    ! The failed instance is not reused, and its physical outputs are not consumed.
    Stop
  EndIf

  If ( mode == 'open_failure' .or. mode == 'collision' ) Then
    filename = 'ts_call1_lane3'
    If ( mode == 'collision' ) filename = 'ts_call1_lane1'
    Open(newunit=unit,file=Trim(filename),status='new',action='write')
    Write(unit,'(a)') 'DO NOT CLOBBER'
    Close(unit)
    active = [.true.,.false.,.true.,.false.]
    saved_x = x
    saved_temperature = temperature
    Call burn('rejected_open',lanes,3,0.1_dp)
    Call check(ierr == xnet_invalid,'existing output path is a checked error')
    Call check(Index(message,Trim(filename)) > 0,'open error identifies concrete filename')
    Call check(All(x == saved_x) .and. All(temperature == saved_temperature),'open error preserves caller state')
    Call assert_closed('ts_call1_lane1')
    Call assert_closed('ev_call1_lane1')
    Call assert_closed(Trim(filename))
    Call burn('after_open_error',lanes,4,0.02_dp)
    Call check(ierr == xnet_success,'valid burn after checked open failure')
    Call finish
    Write(*,'(a)') 'OUTPUT_OPEN_CHECKS_PASSED'
    Stop
  EndIf

  active = [.true.,.false.,.true.,.true.]
  Call burn('first',lanes,3,0.1_dp)
  Call check(ierr == xnet_success,'first output burn')
  active = .true.
  ! Repeated duplicate identifiers do not imply persistent host-zone identity or absolute time.
  density = density*1.25_dp
  temperature = temperature + 1.0e7_dp
  restart = 0.0_dp
  Call burn('repeat',lanes,4,0.025_dp)
  Call check(ierr == xnet_success,'repeat output burn')
  ids = ids(:,[4,3,1,2])
  active = [.true.,.false.,.true.,.false.]
  Call burn('short',3,4,0.01_dp)
  Call check(ierr == xnet_success,'short batch with active lane beyond Count(active)')
  active = .false.
  density(2) = -1.0_dp
  Call burn('inactive',lanes,3,0.1_dp)
  Call check(ierr == xnet_success .and. steps == 0,'all-inactive call ignores inactive scientific values')
  Call burn('empty',0,3,0.1_dp)
  Call check(ierr == xnet_success .and. steps == 0,'empty call')
  If ( .not. direct ) Then
    active(2) = .true.
    Call burn('invalid',lanes,4,0.1_dp)
    Call check(ierr == xnet_invalid .and. steps == 0,'active invalid density is rejected before output')
  EndIf
  density(2) = 1.25e7_dp
  active = [.false.,.false.,.false.,.true.]
  Call burn('after_invalid',lanes,3,0.005_dp)
  Call check(ierr == xnet_success,'tail-only burn after rejected/inactive calls')
  Call finish
  Call initialize
  Call reset_fixture
  Call burn('reinitialize',lanes,4,0.01_dp)
  Call check(ierr == xnet_success,'output burn after finalize/reinitialize')
  Call finish
  Write(*,'(a)') 'OUTPUT_CHECKS_PASSED'

Contains

  Subroutine initialize
    Implicit None
    Call xnet_initialize(controls,network,ierr,message)
    If ( ierr /= xnet_success ) Write(*,'(a)') Trim(message)
    Call check(ierr == xnet_success,'output initialization')
    Return
  End Subroutine initialize

  Subroutine reset_fixture
    Implicit None
    Call fixture_state(network%names,density,temperature,ye,x,restart,aux_x,aux_a,aux_z)
    Return
  End Subroutine reset_fixture

  Subroutine finish
    Implicit None
    Call xnet_finalize(ierr,message)
    Call check(ierr == xnet_success,'output finalize')
    Call xnet_finalize(ierr,message)
    Call check(ierr == xnet_success,'output finalize twice')
    Return
  End Subroutine finish

  Subroutine assert_closed(path)
    Implicit None
    Character(*), Intent(in) :: path
    Inquire(file=path,opened=opened)
    Call check(.not. opened,'output unit closed: '//path)
    Return
  End Subroutine assert_closed

  Subroutine burn(label,n,nids,duration)
    Implicit None
    Character(*), Intent(in) :: label
    Integer, Intent(in) :: n, nids
    Real(dp), Intent(in) :: duration
    Integer :: j
    loss = 0.0_dp
    counters = 0
    Write(*,'(a,1x,a,1x,es26.17e3,1x,*(l1))') 'CALL',label,duration,active(:n)
    Call write_state('input_'//label,temperature(:n),ye(:n),x(:,:n),restart(:n), &
      & 0.0_dp*loss(:n),0*counters(:,:n))
    Write(*,'(a,1x,a,*(1x,es26.17e3))') 'DENSITY',label,density(:n)
    steps = -1
    If ( direct ) Then
      Call reference_burn(n,duration)
    Else
      Call xnet_burn_batch(duration,active(:n),ids(:nids,:n),density(:n),temperature(:n),ye(:n),x(:,:n), &
        & restart(:n),loss(:n),counters(:,:n),timing,ierr,message,aux_x(:n),aux_a(:n),aux_z(:n),steps)
    EndIf
    Write(*,'(a,1x,a,1x,i0)') 'STATUS',label,ierr
    Write(*,'(a,1x,a,1x,i0)') 'STEPS',label,steps
    If ( ierr == xnet_success ) Call write_state(label,temperature(:n),ye(:n),x(:,:n),restart(:n), &
      & loss(:n),counters(:,:n))
    If ( ierr /= xnet_success ) Write(*,'(a)') Trim(message)
    If ( level > 0 .and. Any(active(:n)) .and. ierr == xnet_success ) Then
      output_call = output_call + 1
      Do j = 1, n
        If ( .not. active(j) ) Cycle
        Write(filename,'(a,i0,a,i0)') 'ts_call',output_call,'_lane',j
        ! Failed open attempts consume an output-call number; that mode checks paths separately.
        If ( mode /= 'open_failure' .and. mode /= 'collision' ) Then
          Call assert_closed(Trim(filename))
          If ( level >= 2 .and. .not. direct ) Then
            Write(filename,'(a,i0,a,i0)') 'ev_call',output_call,'_lane',j
            Call assert_closed(Trim(filename))
          EndIf
        EndIf
      EndDo
    EndIf
    Return
  End Subroutine burn

  Subroutine reference_burn(n,duration)
    ! Construct the legacy constant-condition workspace directly, bypassing xnet_burn_batch.
    ! Headers and ts_output use the standalone layout. API input metadata is checked separately.
    Use nuclear_data, Only: ny, aa, zz
    Use xnet_abundances, Only: y, ystart, xext, aext, zext
    Use xnet_conditions, Only: t, t9, rho, ye_work=>ye, tdel, tdel_old, nt, nstart, tstart, tstop, &
      & tdelstart, t9start, rhostart, yestart, nh, th, t9h, rhoh, yeh
    Use xnet_controls, Only: lzactive, szbatch, nzbatch, iaux, ktot, lun_ts, lun_ev, nzevolve, &
      & descript, kstmx, kitmx, iweak0, iscrn, iconvc, changemx, tolm, tolc, yacc, ymin, tdel_maxmult, &
      & iheat, isolv
    Use xnet_evolve, Only: full_net
    Use xnet_flux, Only: flx, ifl_orig, ifl_term
    Use xnet_match, Only: mflx
    Implicit None
    Integer, Intent(in) :: n
    Real(dp), Intent(in) :: duration
    Real(dp) :: denu(nzevolve)
    Integer :: j, status, failed_zone, sequence
    Character(80) :: input_description(2), reference_description

    ierr = xnet_success
    steps = 0
    loss = 0.0_dp
    counters = 0
    If ( .not. Any(active(:n)) ) Return
    szbatch = 1
    nzbatch = Count(active(:n))
    lzactive = .false.
    lzactive(:n) = active(:n)
    ystart = 0.0_dp
    xext = 0.0_dp
    aext = 1.0_dp
    zext = 0.0_dp
    iaux = 0
    nstart = 1
    tstart = 0.0_dp
    tstop = duration
    tdelstart = 0.0_dp
    t9start = 1.0_dp
    rhostart = 1.0_dp
    yestart = 0.5_dp
    Do j = 1, n
      If ( .not. active(j) ) Cycle
      ystart(:,j) = x(:,j)/aa
      xext(j) = aux_x(j)
      aext(j) = aux_a(j)
      zext(j) = aux_z(j)
      iaux(j) = 1
      t9start(j) = temperature(j)*1.0e-9_dp
      rhostart(j) = density(j)
      yestart(j) = ye(j)
      tdelstart(j) = -restart(j)
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
    flx = 0.0_dp
    sequence = output_call + 1
    input_description = 'independent full_net reference'
    reference_description = data_dir
    Do j = 1, n
      If ( .not. active(j) ) Cycle
      Write(filename,'(a,i0,a,i0)') 'ts_call',sequence,'_lane',j
      Open(newunit=lun_ts(j),file=Trim(filename),status='new',form='unformatted',action='write')
      Write(lun_ts(j)) descript,reference_description
      Write(lun_ts(j)) kstmx,kitmx,iweak0,iscrn,iconvc,changemx,tolm,tolc,yacc,ymin,tdel_maxmult,iheat,isolv
      Write(lun_ts(j)) input_description
      Write(lun_ts(j)) input_description
      Write(lun_ts(j)) ny,zz,aa
      Write(lun_ts(j)) mflx,ifl_orig,ifl_term
      ! ASCII is tested against the binary API records; this reference needs binary output only.
      Open(newunit=lun_ev(j),status='scratch',action='write')
    EndDo
    Call full_net(steps,denu,status,failed_zone)
    Call check(status == 0,'independent full_net completed')
    Do j = 1, n
      If ( .not. active(j) ) Cycle
      Close(lun_ts(j))
      Close(lun_ev(j))
      lun_ts(j) = 0
      lun_ev(j) = 0
      x(:,j) = aa*y(:,j)
      If ( iheat > 0 ) temperature(j) = t9(j)*1.0e9_dp
      ye(j) = ye_work(j)
      restart(j) = tdel_old(j)
      loss(j) = denu(j)
      counters(:,j) = ktot(:,j)
    EndDo
    Return
  End Subroutine reference_burn
End Program output_consumer
