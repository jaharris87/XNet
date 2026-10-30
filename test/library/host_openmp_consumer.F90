Program host_openmp_consumer
  ! Application work is threaded; all calls into the single XNet instance are serialized.
  Use, Intrinsic :: ieee_arithmetic, Only: ieee_is_finite
  Use omp_lib, Only: omp_get_max_threads, omp_get_num_threads, omp_get_thread_num
  Use xnet_api, Only: dp, xnet_controls_t, xnet_network_t, xnet_timing_t, set_xnet_controls_defaults, &
    & xnet_initialize, xnet_burn_batch, xnet_nse_composition, xnet_finalize, xnet_success
  Use consumer_fixture, Only: fixture_state, check
  Implicit None

  Integer, Parameter :: lanes = 4
  Type(xnet_controls_t) :: controls
  Type(xnet_network_t) :: network
  Type(xnet_timing_t) :: timing
  Integer :: expected_threads, ierr, cycle, j, max_steps_taken
  Integer :: ids(3,lanes), counters(5,lanes), first_counters(5,lanes)
  Character(80) :: data_dir
  Character(512) :: message
  Logical :: active(lanes)
  Real(dp) :: density(lanes), temperature(lanes), ye(lanes), restart(lanes), loss(lanes)
  Real(dp) :: aux_x(lanes), aux_a(lanes), aux_z(lanes)
  Real(dp) :: saved_temperature(lanes), saved_ye(lanes), saved_restart(lanes)
  Real(dp) :: first_temperature(lanes), first_ye(lanes), first_restart(lanes), first_loss(lanes)
  Real(dp), Allocatable :: x(:,:), saved_x(:,:), first_x(:,:), nse(:), first_nse(:)

  Call get_command_argument(1,data_dir)
  Call check(Len_Trim(data_dir) > 0,'SN160 data directory argument')
  expected_threads = omp_get_max_threads()
  Call check(expected_threads > 1,'application default team has more than one thread')
  Call threaded_work('before_initialize')
  Call set_xnet_controls_defaults(controls)
  controls%data_dir = data_dir
  controls%nzone = lanes
  controls%nzbatchmx = lanes
  controls%isolv = 1
  controls%iheat = 1
  controls%t9nse = 11.0_dp
  controls%idiag = -2
  Do j = 1, lanes
    ids(:,j) = (/ j,7,11 /)
  EndDo

  Do cycle = 1, 2
    Call xnet_initialize(controls,network,ierr,message)
    Call expect_success('initialize')
    Call threaded_work('after_initialize')
    If ( cycle == 1 ) Then
      Allocate(x(Size(network%names),lanes),saved_x(Size(network%names),lanes),first_x(Size(network%names),lanes))
      Allocate(nse(Size(network%names)),first_nse(Size(network%names)))
    EndIf
    Call fixture_state(network%names,density,temperature,ye,x,restart,aux_x,aux_a,aux_z)
    active = (/ .True.,.False.,.True.,.True. /)
    Call burn('first',lanes)
    If ( cycle == 1 ) Then
      first_x = x
      first_temperature = temperature
      first_ye = ye
      first_restart = restart
      first_loss = loss
      first_counters = counters
    Else
      Call check(All(x == first_x) .and. All(temperature == first_temperature) .and. &
        & All(ye == first_ye) .and. All(restart == first_restart),'reinitialized burn state')
      Call check(All(loss == first_loss) .and. All(counters == first_counters),'reinitialized burn diagnostics')
    EndIf
    Call threaded_work('after_burn')

    Call xnet_nse_composition(1.0e6_dp,8.0e9_dp,0.45_dp,nse,ierr,message)
    Call expect_success('NSE query')
    Call check(All(ieee_is_finite(nse)) .and. All(nse >= 0.0_dp),'finite nonnegative NSE composition')
    If ( cycle == 1 ) Then
      first_nse = nse
    Else
      Call check(All(nse == first_nse),'reinitialized NSE composition')
    EndIf
    Call threaded_work('after_nse')
    Call burn('repeat',lanes)
    Call check(Any(x(:,1) /= first_x(:,1)),'successive burns evolve composition')
    active = .True.
    Call burn('short',lanes-1)
    active = .False.
    Call burn('inactive',lanes)
    Call xnet_finalize(ierr,message)
    Call expect_success('finalize')
    Call threaded_work('after_finalize')
    Call xnet_finalize(ierr,message)
    Call expect_success('repeated finalize')
  EndDo
  Deallocate(x,saved_x,first_x,nse,first_nse)
  Write(*,'(a,1x,i0)') 'HOST_OPENMP_CHECKS_PASSED',expected_threads

Contains

  Subroutine expect_success(label)
    Implicit None
    Character(*), Intent(in) :: label

    If ( ierr /= xnet_success ) Write(*,'(a,i0,2a)') 'Unexpected status ',ierr,': ',Trim(message)
    Call check(ierr == xnet_success,label)
    Call check(omp_get_max_threads() == expected_threads,label//' preserves application team setting')
    Return
  End Subroutine expect_success

  Subroutine threaded_work(label)
    ! Every team member performs integer work before the next serialized API call.
    Implicit None
    Character(*), Intent(in) :: label
    Integer, Parameter :: work_items = 128
    Integer :: i, worker, team_size, checksum
    Integer :: visits(expected_threads)

    Call check(omp_get_max_threads() == expected_threads,label//' maximum threads')
    visits = 0
    team_size = 0
    checksum = 0
    !$omp parallel do default(none) shared(visits) private(i,worker) &
    !$omp reduction(+:checksum) reduction(max:team_size)
    Do i = 1, work_items
      worker = omp_get_thread_num() + 1
      visits(worker) = visits(worker) + 1
      team_size = Max(team_size,omp_get_num_threads())
      checksum = checksum + i * i
    EndDo
    !$omp end parallel do
    Call check(team_size == expected_threads,label//' actual application team')
    Call check(All(visits > 0),label//' every application thread did work')
    Call check(checksum == work_items*(work_items+1)*(2*work_items+1)/6,label//' threaded checksum')
    Write(*,'(a,1x,a,3(1x,i0))') 'HOST_TEAM',Trim(label),omp_get_max_threads(),team_size,checksum
    Return
  End Subroutine threaded_work

  Subroutine burn(label,n)
    Implicit None
    Character(*), Intent(in) :: label
    Integer, Intent(in) :: n
    Integer :: lane

    saved_x = x
    saved_temperature = temperature
    saved_ye = ye
    saved_restart = restart
    max_steps_taken = -1
    Call xnet_burn_batch(0.1_dp,active(:n),ids(:,:n),density(:n),temperature(:n),ye(:n),x(:,:n), &
      & restart(:n),loss(:n),counters(:,:n),timing,ierr,message,aux_x(:n),aux_a(:n),aux_z(:n),max_steps_taken)
    Call expect_success(label//' burn')
    Call check(All(ieee_is_finite(x)) .and. All(x >= 0.0_dp),label//' composition')
    If ( Any(active(:n)) ) Then
      Call check(max_steps_taken > 0,label//' accepted steps')
    Else
      Call check(max_steps_taken == 0,label//' no accepted steps')
    EndIf
    Do lane = 1, lanes
      If ( lane <= n ) Then
        If ( active(lane) ) Then
          Call check(counters(1,lane) > 0,label//' active counters')
          Cycle
        EndIf
        Call check(loss(lane) == 0.0_dp .and. All(counters(:,lane) == 0),label//' inactive diagnostics')
      EndIf
      Call check(All(x(:,lane) == saved_x(:,lane)) .and. temperature(lane) == saved_temperature(lane) .and. &
        & ye(lane) == saved_ye(lane) .and. restart(lane) == saved_restart(lane),label//' inactive/unused lane')
    EndDo
    Return
  End Subroutine burn

End Program host_openmp_consumer
