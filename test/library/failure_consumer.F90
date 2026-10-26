Program failure_consumer
  ! A fatal simulation error returns to this host, which ends without using results or burning again.
  Use, Intrinsic :: ieee_arithmetic, Only: ieee_is_finite
  Use xnet_api, Only: dp, xnet_controls_t, xnet_network_t, xnet_timing_t, &
    & set_xnet_controls_defaults, xnet_initialize, xnet_burn_batch, &
    & xnet_success, xnet_integrator_failure, xnet_step_limit
  Use consumer_fixture, Only: fixture_state, check
  Implicit None
  Integer, Parameter :: lanes = 3
  Type(xnet_controls_t) :: controls
  Type(xnet_network_t) :: network
  Type(xnet_timing_t) :: timing
  Integer :: ierr, solver, nids, expected, ids(4,lanes), counters(5,lanes)
  Character(80) :: data_dir, argument, mode
  Character(512) :: message
  Logical :: active(lanes)
  Real(dp) :: density(lanes), temperature(lanes), ye(lanes), restart(lanes), loss(lanes)
  Real(dp) :: aux_x(lanes), aux_a(lanes), aux_z(lanes), times(6)
  Real(dp), Allocatable :: x(:,:)

  Call Get_Command_Argument(1,data_dir)
  Call Get_Command_Argument(2,argument)
  Read(argument,*) solver
  Call Get_Command_Argument(3,mode)
  Call Get_Command_Argument(4,argument)
  Read(argument,*) nids
  Call check(nids == 3 .or. nids == 4,'identifier count')
  Call set_xnet_controls_defaults(controls)
  controls%data_dir = data_dir
  controls%nzbatchmx = lanes+1
  controls%isolv = solver
  controls%idiag = 0
  controls%t9nse = 11.0_dp
  If ( solver == 3 ) Then
    controls%kitmx = 10
    controls%iconvc = 3
    controls%ymin = 1.0e-99_dp
  EndIf
  Select Case (Trim(mode))
  Case ('step_limit')
    controls%kstmx = 1
    expected = xnet_step_limit
  Case ('integrator')
    controls%tolc = 1.0e-30_dp
    If ( solver == 1 ) Then
      controls%kitmx = 1
      controls%iconvc = 1
    Else
      controls%tolc = 1.0e-100_dp
      controls%yacc = 1.0e-100_dp
    EndIf
    expected = xnet_integrator_failure
  Case Default
    Call check(.false.,'unknown failure mode')
  End Select
  Call xnet_initialize(controls,network,ierr,message)
  If ( ierr /= xnet_success ) Write(*,'(a)') Trim(message)
  Call check(ierr == xnet_success,'failure-test initialization')
  Allocate (x(Size(network%names),lanes))
  Call fixture_state(network%names,density,temperature,ye,x,restart,aux_x,aux_a,aux_z)
  active = [.false.,.true.,.false.]
  ids = 0
  ids(:,2) = [101,-7,9001,42]
  Call xnet_burn_batch(0.1_dp,active,ids(:nids,:),density,temperature,ye,x,restart, &
    & loss,counters,timing,ierr,message,aux_x,aux_a,aux_z)
  Write(*,'(a,i0,2a)') 'BURN_STATUS ',ierr,' ',Trim(message)
  Call check(ierr == expected,'expected numerical failure returned to host')
  Call check(Index(message,'Lane 2, zone IDs [101 -7 9001') == 1,'submitted active lane and original IDs')
  If ( nids == 4 ) Call check(Index(message,'9001 42]') > 0,'fourth original ID')
  Call check(Index(message,'host must terminate') > 0,'fatal host policy')
  Call check(All(counters(:,2) > 0),'attempted active counters')
  Call check(All(counters(:,1) == 0) .and. All(counters(:,3) == 0),'inactive counters')
  If ( mode == 'integrator' ) Call check(counters(1,2) > 1,'internal timestep retries exercised')
  times = [timing%seconds,timing%solve,timing%jacobian,timing%derivative,timing%rates,timing%screening]
  Call check(All(ieee_is_finite(times)) .and. All(times >= 0.0_dp),'completed attempted timing')
  Call check(timing%seconds > 0.0_dp,'elapsed timer closed')
  Write(*,'(a,5(1x,i0))') 'ATTEMPTED_COUNTERS',counters(:,2)
  Write(*,'(a,6(1x,es26.17e3))') 'ATTEMPTED_TIMING',times
  ! Do not inspect physical outputs, retry, or reuse this failed library instance.
  Deallocate (x)
  Write(*,'(a)') 'HOST_RECEIVED_FATAL_BURN'
End Program failure_consumer
