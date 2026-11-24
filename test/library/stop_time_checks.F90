Program stop_time_checks
  ! Exercise production timestep/BE/BDF routines with the real alpha network.
  Use xnet_api, Only: dp, xnet_controls_t, xnet_network_t, set_xnet_controls_defaults, &
    & xnet_initialize, xnet_finalize, xnet_success
  Use nuclear_data, Only: ny, nname
  Use xnet_abundances, Only: y, yo, yt, ydot, xext, aext, zext
  Use xnet_conditions, Only: t, tt, to, tstop, tdel, tdel_old, tdel_next, tdelstart, &
    & t9, t9o, t9t, t9dot, rho, rhoo, rhot, ye, yeo, yet, nt, nto, ntt, ints, intso, &
    & nh, th, t9h, rhoh, yeh, cv, etae, detaedt9
  Use xnet_controls, Only: szbatch, lzactive, iheat, kitmx, iconvc, &
    & changemx, changemxt, kmon, ktot
  Use xnet_integrate, Only: timestep
  Use xnet_integrate_be, Only: solve_be, be_initialize, be_finalize
  Use xnet_integrate_bdf, Only: solve_bdf, bdf_reset, bdf_adjust, bdf_check, q, z, z0, dt_scale, hvec, eta, &
    & ierr_ts, ierr_nr, bdf_active, nit_nr, nit_nrslv, tq, acnrm, retry_ts
  Implicit None

  Real(dp), Parameter :: saved_time = 2.029598476679883e-5_dp, saved_stop = 1.0e-4_dp
  Real(dp), Parameter :: saved_dt = 1.3969927838009003e-5_dp
  Type(xnet_controls_t) :: controls
  Type(xnet_network_t) :: network
  Character(512) :: message
  Character(80) :: data_dir
  Integer :: ierr, failures, carbon, k, attempt, its(3)
  Logical :: mask(3)
  Real(dp) :: remaining, ratio, target(2), scale(2)
  Real(dp), Volatile :: replay_time, replay_remaining, replay_stop

  failures = 0
  Call get_command_argument(1,data_dir)
  Call set_xnet_controls_defaults(controls)
  controls%data_dir = data_dir
  controls%nzbatchmx = 3
  controls%isolv = 3
  controls%idiag = -2
  controls%kitmx = 10
  controls%iconvc = 3
  controls%ymin = 1.0e-99_dp
  Call xnet_initialize(controls,network,ierr,message)
  If ( ierr /= xnet_success ) Write(*,'(a)') Trim(message)
  Call check(ierr == xnet_success,'initialize real alpha network')
  If ( ierr /= xnet_success ) Stop 1
  Call be_initialize
  carbon = 0
  Do k = 1, ny
    If ( Trim(Adjustl(nname(k))) == 'c12' ) carbon = k
  EndDo
  Call check(carbon > 0,'alpha network contains carbon')
  Deallocate(th,t9h,rhoh,yeh)
  Allocate(th(4,3),t9h(4,3),rhoh(4,3),yeh(4,3))

  Call reset_state
  remaining = saved_stop-saved_time
  replay_time = saved_time
  replay_stop = saved_stop
  replay_remaining = replay_stop-replay_time
  Call check(replay_time+replay_remaining < replay_stop,'saved binary64 counterexample undershoots')
  mask = [.true.,.false.,.true.]
  tdel_next(3) = Nearest(remaining,-1.0_dp)
  tt(2) = -7.0_dp
  Call timestep(2,mask)
  Call check(tt(1) == saved_stop .and. tdel(1) == remaining,'selected final interval reaches stop')
  Call check(tdel(3) == Nearest(remaining,-1.0_dp) .and. tt(3) < saved_stop, &
    & 'one-ulp shorter interval stays nonterminal')
  Call check(tt(2) == -7.0_dp .and. tdel(2) == saved_dt,'masked zone is unchanged')

  Call reset_state
  tdel = 0.0_dp
  Call timestep(1,mask)
  Call check(tt(1) == tstop(1),'initial selected final interval reaches stop')
  its = [0,1,1]
  Call solve_bdf(1,its)
  Call check(its(1) == 0 .and. t(1) == saved_stop,'successful initial BDF trial accepts selected stop')

  Call reset_state
  iheat = 0
  tdel = 0.0_dp
  kitmx = 5
  iconvc = 0
  Call timestep(1,mask)
  its = [0,1,1]
  Call solve_be(1,its)
  Call check(its(1) == 0 .and. t(1) == saved_stop,'successful initial BE trial accepts selected stop')

  Call reset_state
  lzactive = .false.
  tt = -7.0_dp
  Call timestep(2)
  Call check(All(tt == -7.0_dp) .and. All(tdel == saved_dt),'empty default mask leaves all zones unchanged')
  lzactive = mask
  Call timestep(2)
  Call check(tt(1) == saved_stop .and. tt(2) == -7.0_dp,'default active mask selects only active zones')

  Call reset_state
  t = 0.0_dp
  tstop = 1.0_dp
  tdel_next = 1.0_dp
  Call timestep(2,mask)
  Call check(tt(1) == 1.0_dp,'exact arithmetic target is unchanged')

  Call reset_state
  tdel = -remaining
  tdel_next = remaining/4.0_dp
  Call timestep(2,mask)
  Call check(tt(1) == saved_stop,'constant-step override selects stop after other limits')
  Call reset_state
  tdel = -0.5_dp*remaining
  Call timestep(2,mask)
  Call check(tt(1) < saved_stop,'short constant-step override does not inherit stop')

  ! A small interior peak triggers feature capture without triggering the variation limit.
  Call reset_state
  iheat = 0
  nh = 4
  Do k = 1, 3
    th(:,k) = [saved_time,saved_time+remaining/4.0_dp,saved_time+remaining/2.0_dp,saved_stop]
    t9h(:,k) = [0.1_dp,0.1001_dp,0.1_dp,0.1_dp]
  EndDo
  Call timestep(2,mask)
  Call check(tdel(1) == th(2,1)-t(1) .and. tt(1) < saved_stop,'thermo feature discards selected stop')

  Call reset_state
  iheat = 0
  nh = 2
  t9h(2,:) = 0.12_dp
  Call timestep(2,mask)
  Call check(tdel(1) < remaining .and. tt(1) == t(1)+tdel(1),'thermo variation discards selected stop')

  ! Exercise the branch that revisits the endpoint without finding an interior extremum.
  Call reset_state
  iheat = 0
  nh = 4
  Do k = 1, 3
    th(:,k) = [saved_time,saved_time+remaining/4.0_dp,saved_time+remaining/2.0_dp,saved_stop]
  EndDo
  Call timestep(2,mask)
  Call check(tt(1) == saved_stop,'flat multi-knot history keeps selected stop')

  Call reset_state
  retry_ts = .true.
  Call bdf_reset
  Call check(All(.not. retry_ts),'BDF reset clears preceding retry state')
  q = 2
  z(:,1,:) = 2.0_dp
  z(:,2,:) = 3.0_dp
  tdel_old = saved_dt
  dt_scale = saved_dt
  tdel = remaining
  tt = saved_stop
  ierr_ts = [0,1,0]
  tdel(3) = remaining/2.0_dp
  tt(3) = t(3)+tdel(3)
  Call bdf_adjust(2)
  ratio = remaining/saved_dt
  Call check(tt(1) == saved_stop,'BDF initial adjustment preserves selected stop')
  Call check(tdel(1) == ratio*saved_dt .and. hvec(0,1) == tdel(1) .and. dt_scale(1) == tdel(1), &
    & 'BDF timestep scaling arithmetic is unchanged')
  Call check(z(1,1,1) == 2.0_dp*ratio .and. z(1,2,1) == 3.0_dp*ratio**2, &
    & 'BDF Nordsieck orders scale with eta powers')
  Call check(z(1,1,2) == 2.0_dp .and. tdel(2) == remaining,'BDF masked adjustment is unchanged')
  Call check(tt(3) == t(3)+tdel(3) .and. tt(3) < saved_stop,'BDF ordinary adjustment stays nonterminal')

  ! Both directions of the existing divide/multiply rounding retain a selected stop.
  target = [1.0421234021352775e-5_dp,4.5508984935988477e-4_dp]
  scale = [1.8299466772705972e-5_dp,1.8648934833354478e-4_dp]
  Do attempt = 1, 2
    Call reset_state
    t = 0.0_dp
    tstop = target(attempt)
    tt = tstop
    tdel = tstop
    Call bdf_reset
    tdel_old = scale(attempt)
    dt_scale = tdel_old
    Call bdf_adjust(2)
    Call check(tt(1) == tstop(1),'BDF selected stop survives ratio/product rounding')
    If ( attempt == 1 ) Call check(tdel(1) > tstop(1),'BDF upward dt roundtrip remains unchanged')
    If ( attempt == 2 ) Call check(tdel(1) < tstop(1),'BDF downward dt roundtrip remains unchanged')
    Call check(hvec(0,1) == tdel(1) .and. dt_scale(1) == tdel(1),'BDF rounded dt matches scaling history')
  EndDo

  ! Rejected NR and error-test trials run the production restore/reduce/rescale path.
  Do attempt = 1, 2
    Call reset_state
    tdel = remaining
    tt = saved_stop
    Call bdf_reset
    bdf_active = [.true.,.false.,.false.]
    nit_nr = 0
    nit_nrslv = 1
    tq(0,:) = 1.0_dp
    acnrm = 0.0_dp
    If ( attempt == 1 ) nit_nr(1) = 4
    If ( attempt == 2 ) acnrm(1) = 4.0_dp
    q = 2
    z0 = 0.0_dp
    z0(:,1,:) = 2.0_dp
    z0(:,2,:) = 3.0_dp
    z = 99.0_dp
    Call bdf_check(2)
    Call check(retry_ts(1) .and. tdel(1) < remaining,'BDF rejected trial requests smaller retry')
    Call check(t(1) == saved_time .and. tt(1) == t(1)+tdel(1) .and. tt(1) < saved_stop, &
      & 'BDF retry replaces discarded stop without advancing time')
    Call check(z(1,1,1) == 2.0_dp*eta(1) .and. z(1,2,1) == 3.0_dp*eta(1)**2, &
      & 'BDF retry restores and scales Nordsieck history')
    Call check(tt(2) == saved_stop .and. tdel(2) == remaining,'BDF retry leaves masked zone unchanged')

    ! Successful completion clears the retry fact before the next initial adjustment.
    nit_nr(1) = 1
    acnrm(1) = 0.0_dp
    Call bdf_check(2)
    Call check(ierr_nr(1) == 0 .and. .not. retry_ts(1),'BDF success clears preceding rejected trial')
    tdel_old(1) = tdel(1)
    tdel(1) = remaining
    tt(1) = saved_stop
    ierr_ts(2:3) = 1
    Call bdf_adjust(3)
    Call check(tt(1) == saved_stop,'BDF next final adjustment follows successful retry')
  EndDo

  Call reset_state
  tdel = Spacing(t)
  tstop = t+tdel
  tt = tstop
  Call bdf_reset
  bdf_active = [.true.,.false.,.false.]
  nit_nr(1) = 4
  Call bdf_check(2)
  Call check(ierr_ts(1) == 1 .and. ierr_nr(1) == -1 .and. .not. retry_ts(1), &
    & 'BDF minimum-step failure reports failure without a retry')
  Call check(t(1) == saved_time,'BDF failed terminal attempt never advances time')

  ! Real BE solve with an oversized final interval must accept a shorter retry.
  Call reset_state
  iheat = 0
  t = 0.0_dp
  tstop = 100.0_dp
  tt = tstop
  tdel = tstop
  th(1,:) = 0.0_dp
  th(2:4,:) = 100.0_dp
  t9 = 1.75_dp
  t9t = t9
  t9o = t9
  t9h = 1.75_dp
  kitmx = 5
  iconvc = 0
  its = [0,1,1]
  Call solve_be(2,its)
  Call check(its(1) == 0 .and. kmon(1,1) > 1,'BE oversized final interval exercises successful retry')
  Call check(t(1) == tt(1) .and. t(1) < tstop(1),'BE successful retry accepts reduced endpoint')

  ! Zero NR iterations forces all BE attempts, including its last derivative-based fallback.
  Call reset_state
  tt = saved_stop
  tdel = remaining
  kitmx = 0
  its = [0,1,1]
  Call solve_be(2,its)
  Call check(its(1) == 1 .and. kmon(1,1) == 11,'BE exhausted retries report failure')
  Call check(tdel_old(1) == 0.0_dp,'BE last attempt re-enters derivative-based timestep')
  Call check(t(1) == saved_time .and. tt(1) < saved_stop,'BE failure never accepts discarded stop')

  Call be_finalize
  Call xnet_finalize(ierr,message)
  Call check(ierr == xnet_success,'finalize')
  If ( failures /= 0 ) Then
    Write(*,'(a,i0)') 'STOP_TIME_FAILED ',failures
    Stop 1
  EndIf
  Write(*,'(a)') 'STOP_TIME_CHECKS_PASSED'

Contains

  Subroutine check(condition,label)
    Implicit None
    Logical, Intent(in) :: condition
    Character(*), Intent(in) :: label
    If ( condition ) Then
      Write(*,'(2a)') 'PASS ',label
    Else
      failures = failures+1
      Write(*,'(2a)') 'FAIL ',label
    EndIf
  End Subroutine check

  Subroutine reset_state
    Implicit None
    szbatch = 1
    lzactive = .true.
    iheat = 0
    changemx = 0.1_dp
    changemxt = 0.01_dp
    y = 0.0_dp
    y(carbon,:) = 1.0_dp/12.0_dp
    yo = y
    yt = y
    ydot = 0.0_dp
    xext = 0.0_dp
    aext = 1.0_dp
    zext = 0.0_dp
    t = saved_time
    to = t
    tt = t
    tstop = saved_stop
    tdel = saved_dt
    tdel_next = 2.0_dp*(saved_stop-saved_time)
    tdel_old = saved_dt
    tdelstart = 0.0_dp
    t9 = 0.1_dp
    t9o = t9
    t9t = t9
    t9dot = 0.0_dp
    cv = 1.0_dp
    etae = 0.0_dp
    detaedt9 = 0.0_dp
    rho = 1.0e7_dp
    rhoo = rho
    rhot = rho
    ye = 0.5_dp
    yeo = ye
    yet = ye
    nt = 1
    nto = 1
    ntt = 1
    ints = 1
    intso = 1
    nh = 2
    th(1,:) = saved_time
    th(2:4,:) = saved_stop
    t9h = 0.1_dp
    rhoh = 1.0e7_dp
    yeh = 0.5_dp
    kmon = 0
    ktot = 0
  End Subroutine reset_state
End Program stop_time_checks
