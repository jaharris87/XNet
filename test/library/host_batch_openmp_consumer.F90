Program host_batch_openmp_consumer
  ! Only public XNet API declarations are imported by this application caller.
  Use, Intrinsic :: ieee_arithmetic, Only: ieee_is_finite
  Use omp_lib, Only: omp_get_num_threads, omp_get_thread_num, omp_get_max_threads, omp_get_level, &
    & omp_set_dynamic, omp_set_num_threads, omp_set_max_active_levels, omp_get_max_active_levels
  Use xnet_api, Only: dp, xnet_controls_t, xnet_network_t, xnet_timing_t, set_xnet_controls_defaults, &
    & xnet_initialize, xnet_burn_batch, xnet_nse_composition, xnet_finalize, xnet_success, &
    & xnet_step_limit, xnet_integrator_failure, xnet_unsupported
  Use consumer_fixture, Only: fixture_state, write_state, check
  Implicit None

  Integer, Parameter :: lanes = 4, batches = 8, calls = 6
  Type :: result_t
    Integer :: owner = -1, team = 0, n = lanes, nids = 4, status = -1, steps = -1
    Integer :: ids(4,lanes), counters(5,lanes)
    Logical :: active(lanes)
    Real(dp) :: dt, density(lanes), temperature(lanes), ye(lanes), restart(lanes), loss(lanes)
    Real(dp) :: input_temperature(lanes), input_ye(lanes), input_restart(lanes)
    Real(dp), Allocatable :: x(:,:), input_x(:,:)
    Type(xnet_timing_t) :: timing
    Character(512) :: message
  End Type result_t
  Type :: nse_result_t
    Integer :: owner = -1, team = 0, status = -1
    Real(dp), Allocatable :: x(:)
    Character(512) :: message
  End Type nse_result_t
  Type :: rejected_result_t
    Integer :: owner = -1, team = 0, level = -1, burn_status = -1, nse_status = -1
    Logical :: unchanged = .false., cleared = .false.
    Character(512) :: burn_message, nse_message
  End Type rejected_result_t
  Type(xnet_controls_t) :: controls
  Type(xnet_network_t) :: network
  Type(result_t) :: results(calls,batches)
  Type(nse_result_t) :: nse_results(2,batches)
  Integer :: solver, heat, level, ierr, b, c, p, expected_threads, first_batch, last_batch
  Character(80) :: data_dir, arg, mode
  Character(512) :: message
  Character(32) :: label
  Logical :: parallel_calls, failure, test_nse

  Call check(Command_Argument_Count() >= 5,'data_dir solver heat itsout mode [failure logical batch]')
  Call get_command_argument(1,data_dir)
  Call get_command_argument(2,arg)
  Read(arg,*) solver
  Call get_command_argument(3,arg)
  Read(arg,*) heat
  Call get_command_argument(4,arg)
  Read(arg,*) level
  Call get_command_argument(5,mode)
  Call check(Trim(mode) == 'serial' .or. Trim(mode) == 'parallel' .or. &
    & Trim(mode) == 'serial-step' .or. Trim(mode) == 'parallel-step' .or. &
    & Trim(mode) == 'serial-integrator' .or. Trim(mode) == 'parallel-integrator' .or. Trim(mode) == 'topology','known run mode')
  parallel_calls = Index(Trim(mode),'parallel') == 1
  failure = Index(Trim(mode),'step') > 0 .or. Index(Trim(mode),'integrator') > 0
  test_nse = Trim(data_dir) == 'Data_SN160' .and. .not. failure
  Call omp_set_dynamic(.false.)
  expected_threads = omp_get_max_threads()
  If ( parallel_calls ) Call check(expected_threads == 2 .or. expected_threads == 4,'requested two/four workers')
  first_batch = 1
  last_batch = batches
  If ( failure ) Then
    last_batch = expected_threads
    If ( .not. parallel_calls ) Then
      Call get_command_argument(6,arg)
      Read(arg,*) first_batch
      last_batch = first_batch
    EndIf
  EndIf
  Call set_xnet_controls_defaults(controls)
  controls%data_dir = data_dir
  controls%nzone = lanes
  controls%nzbatchmx = lanes
  controls%isolv = solver
  controls%iheat = heat
  controls%idiag = -2
  controls%itsout = level
  controls%bin_file_base = 'ts'
  controls%ev_file_base = 'ev'
  controls%description = [Character(80) :: 'Application outer OpenMP batch test', 'constant conditions', 'public C/O fixture']
  controls%nnucout = 2
  controls%output_nuclei = [Character(5) :: 'c12', 'o16']
  controls%t9nse = 11.0_dp
  If ( Trim(data_dir) == 'Data_SN160' ) controls%iscrn = 1
  If ( solver == 3 ) Then
    controls%kitmx = 10
    controls%iconvc = 3
    controls%ymin = 1.0e-99_dp
  EndIf
  If ( Index(mode,'step') > 0 ) controls%kstmx = 1
  If ( Index(mode,'integrator') > 0 ) Then
    controls%tolc = 1.0e-30_dp
    If ( solver == 1 ) Then
      controls%kitmx = 1
      controls%iconvc = 1
    Else
      controls%tolc = 1.0e-100_dp
      controls%yacc = 1.0e-100_dp
    EndIf
  EndIf
  If ( Trim(mode) == 'topology' ) Then
    Call topology_checks()
    Stop
  EndIf
  Call xnet_initialize(controls,network,ierr,message)
  If ( ierr /= xnet_success ) Write(*,'(a)') Trim(message)
  Call check(ierr == xnet_success,'initialization')
  Call check(omp_get_max_threads() == expected_threads,'initialization preserves application team setting')
  Do b = first_batch, last_batch
    Do c = 1, calls
      Allocate(results(c,b)%x(Size(network%names),lanes),results(c,b)%input_x(Size(network%names),lanes))
    EndDo
    Do p = 1, 2
      Allocate(nse_results(p,b)%x(Size(network%names)))
    EndDo
  EndDo
  Do b = 1, Size(network%names)
    Write(*,'(a,1x,a,2(1x,i0),2(1x,es26.17e3))') 'META',Trim(Adjustl(network%names(b))), &
      & network%mass_number(b),network%charge_number(b),network%binding_energy_mev(b),network%mass_excess_mev(b)
  EndDo

  If ( test_nse ) Call nse_phase(1)
  If ( parallel_calls ) Then
    ! Application parallelism owns logical batches. There is no critical or single around the API calls.
    !$omp parallel do default(none) schedule(static,1) shared(first_batch,last_batch,results,network,mode,failure)
    Do b = first_batch, last_batch
      Call execute_batch(b)
    EndDo
    !$omp end parallel do
  Else
    Do b = first_batch, last_batch
      Call execute_batch(b)
    EndDo
  EndIf
  If ( test_nse ) Call nse_phase(2)

  Do b = first_batch, last_batch
    Do c = 1, Merge(1,calls,failure)
      Write(label,'(a,i2.2,a,i2.2)') 'b',b,'_c',c
      Call validate_result(results(c,b),b,c)
      Write(*,'(a,1x,a,6(1x,i0),1x,es26.17e3,1x,4l1)') 'CALL',Trim(label), &
        & b,c,results(c,b)%owner,results(c,b)%team,results(c,b)%n,results(c,b)%nids,results(c,b)%dt,results(c,b)%active
      Write(*,'(a,1x,a,1x,i0)') 'STATUS',Trim(label),results(c,b)%status
      Write(*,'(a,1x,a,1x,i0)') 'STEPS',Trim(label),results(c,b)%steps
      Write(*,'(a,1x,a,6(1x,es26.17e3))') 'TIMING',Trim(label),results(c,b)%timing%evolve, &
        & results(c,b)%timing%solve,results(c,b)%timing%jacobian,results(c,b)%timing%derivative, &
        & results(c,b)%timing%rates,results(c,b)%timing%screening
      Write(*,'(a,1x,a,1x,a)') 'MESSAGE',Trim(label),Trim(results(c,b)%message)
      Write(*,'(a,1x,a,*(1x,es26.17e3))') 'DENSITY',Trim(label),results(c,b)%density
      Call write_state('input_'//Trim(label),results(c,b)%input_temperature,results(c,b)%input_ye, &
        & results(c,b)%input_x,results(c,b)%input_restart,Spread(0.0_dp,1,lanes),0*results(c,b)%counters)
      If ( .not. failure ) Then
        Call write_state(Trim(label),results(c,b)%temperature,results(c,b)%ye,results(c,b)%x, &
          & results(c,b)%restart,results(c,b)%loss,results(c,b)%counters)
      Else
        ! Failed physical outputs have no supported meaning and are deliberately not read.
        Write(*,'(a,1x,a,20(1x,i0))') 'ATTEMPTS',Trim(label),results(c,b)%counters
      EndIf
    EndDo
    If ( test_nse ) Then
      Do p = 1, 2
        Call check(nse_results(p,b)%status == xnet_success,'NSE status: '//Trim(nse_results(p,b)%message))
        Call check(All(ieee_is_finite(nse_results(p,b)%x)) .and. All(nse_results(p,b)%x >= 0.0_dp),'NSE composition')
        Write(*,'(a,4(1x,i0),*(1x,es26.17e3))') 'HOST_NSE',b,p,nse_results(p,b)%owner,nse_results(p,b)%team, &
          & nse_results(p,b)%x
      EndDo
    EndIf
  EndDo
  If ( failure ) Then
    Write(*,'(a,1x,a,1x,i0)') 'HOST_RECEIVED_CONCURRENT_FATAL_BURNS',Trim(mode),expected_threads
    ! Each worker made exactly one call; never retry or finalize a failed simulation instance.
    Stop
  EndIf
  Call xnet_finalize(ierr,message)
  Call check(ierr == xnet_success,'finalization')
  Call check(omp_get_max_threads() == expected_threads,'finalization preserves application team setting')
  Write(*,'(a,1x,a,1x,i0)') 'HOST_BATCH_OPENMP_CHECKS_PASSED',Trim(mode),expected_threads

Contains

  Subroutine topology_checks()
    ! Rejected calls must leave the initialized fixed-team instance usable.
    Implicit None
    Type(xnet_network_t) :: rejected_network
    Type(rejected_result_t) :: dynamic_result, changed(4), nested(2)
    Type(result_t) :: baseline(calls)
    Real(dp), Allocatable :: first_nse(:,:)
    Integer :: other_threads, saved_levels, worker, call_number, lifetime
    Call check(expected_threads == 2 .or. expected_threads == 4,'topology initialized team size')
    other_threads = Merge(4,2,expected_threads == 2)
    saved_levels = omp_get_max_active_levels()

    Call omp_set_dynamic(.true.)
    Call xnet_initialize(controls,rejected_network,ierr,message)
    Call check(ierr == xnet_unsupported .and. Index(message,'dynamic OpenMP') > 0,'dynamic initialization rejected')
    Call check(.not. Allocated(rejected_network%names),'rejected initialization returns no network')
    Call omp_set_dynamic(.false.)
    ! A one-member region is still an OpenMP region (level one), despite omp_in_parallel() being false.
    !$omp parallel num_threads(1) default(none) shared(controls,rejected_network,ierr,message)
    !$omp single
    Call xnet_initialize(controls,rejected_network,ierr,message)
    !$omp end single
    !$omp end parallel
    Call check(ierr == xnet_unsupported .and. Index(message,'Initialize XNet outside') == 1,'serialized-region initialization rejected')

    Do lifetime = 1, 2
      Call xnet_initialize(controls,network,ierr,message)
      Call check(ierr == xnet_success,'topology valid initialization/reinitialization')
      If ( lifetime == 1 ) Then
        Do call_number = 1, calls
          Allocate(results(call_number,1)%x(Size(network%names),lanes), &
            & results(call_number,1)%input_x(Size(network%names),lanes))
        EndDo
        Do worker = 1, expected_threads
          Allocate(nse_results(1,worker)%x(Size(network%names)))
        EndDo
        Allocate(first_nse(Size(network%names),expected_threads))
      EndIf
      Call execute_batch(1)
      !$omp parallel do default(none) schedule(static,1) shared(expected_threads,nse_results)
      Do worker = 1, expected_threads
        Call query_nse(worker,1)
      EndDo
      !$omp end parallel do
      Do worker = 1, expected_threads
        Call check(nse_results(1,worker)%status == xnet_success,'topology valid screened NSE')
        Call check(nse_results(1,worker)%owner == worker-1 .and. nse_results(1,worker)%team == expected_threads, &
          & 'actual screened NSE worker after initialization/reinitialization')
        Write(*,'(a,4(1x,i0))') 'LIFETIME_NSE',lifetime,worker,nse_results(1,worker)%owner,nse_results(1,worker)%team
      EndDo
      If ( lifetime == 1 ) Then
        baseline = results(:,1)
        Do worker = 1, expected_threads
          first_nse(:,worker) = nse_results(1,worker)%x
        EndDo
        Call omp_set_dynamic(.true.)
        Call rejected_calls(dynamic_result)
        Call check_rejected(dynamic_result,'dynamic-enabled',1,0,'fixed, nonnested')
        Call xnet_finalize(ierr,message)
        Call check(ierr == xnet_unsupported .and. Index(message,'Finalize XNet outside') == 1,'dynamic finalization rejected')
        Call omp_set_dynamic(.false.)

        !$omp parallel num_threads(other_threads) default(none) shared(changed)
        Call rejected_calls(changed(omp_get_thread_num()+1))
        !$omp end parallel
        Do worker = 1, other_threads
          Call check_rejected(changed(worker),'changed-size',other_threads,1,'same OpenMP team size')
        EndDo
        Call omp_set_max_active_levels(2)
        !$omp parallel num_threads(1) default(none) shared(nested)
        !$omp parallel num_threads(2) default(none) shared(nested)
        Call rejected_calls(nested(omp_get_thread_num()+1))
        !$omp end parallel
        !$omp end parallel
        Do worker = 1, 2
          Call check_rejected(nested(worker),'nested',2,2,'fixed, nonnested')
        EndDo
        Call omp_set_max_active_levels(saved_levels)
        !$omp parallel num_threads(1) default(none) shared(ierr,message)
        !$omp single
        Call xnet_finalize(ierr,message)
        !$omp end single
        !$omp end parallel
        Call check(ierr == xnet_unsupported .and. Index(message,'Finalize XNet outside') == 1,'serialized-region finalization rejected')
        Call omp_set_num_threads(other_threads)
        Call xnet_finalize(ierr,message)
        Call check(ierr == xnet_unsupported .and. Index(message,'team') > 0,'changed-size finalization rejected')
        Call omp_set_num_threads(expected_threads)
        Call execute_batch(1)
        Call query_nse(1,1)
        Call check(nse_results(1,1)%status == xnet_success,'NSE after rejected calls')
      EndIf
      Do call_number = 1, calls
        Call validate_result(results(call_number,1),1,call_number)
        Call check(All(results(call_number,1)%x == baseline(call_number)%x) .and. &
          & All(results(call_number,1)%temperature == baseline(call_number)%temperature) .and. &
          & All(results(call_number,1)%ye == baseline(call_number)%ye) .and. &
          & All(results(call_number,1)%restart == baseline(call_number)%restart) .and. &
          & All(results(call_number,1)%loss == baseline(call_number)%loss) .and. &
          & All(results(call_number,1)%counters == baseline(call_number)%counters) .and. &
          & results(call_number,1)%steps == baseline(call_number)%steps,'successful state/counters/steps after rejection/reinitialize')
      EndDo
      Do worker = 1, expected_threads
        Call check(All(nse_results(1,worker)%x == first_nse(:,worker)),'screened worker NSE composition after reinitialize')
      EndDo
      Call xnet_finalize(ierr,message)
      Call check(ierr == xnet_success,'topology valid finalization')
    EndDo
    Call check(omp_get_max_threads() == expected_threads .and. omp_get_max_active_levels() == saved_levels,'restored application settings')
    Write(*,'(a,1x,i0)') 'HOST_BATCH_TOPOLOGY_CHECKS_PASSED',expected_threads
  End Subroutine topology_checks

  Subroutine rejected_calls(r)
    Implicit None
    Type(rejected_result_t), Intent(out) :: r
    Type(xnet_timing_t) :: probe_timing
    Logical :: active(lanes)
    Integer :: ids(4,lanes), counts(5,lanes), steps
    Real(dp) :: d(lanes), temp(lanes), ey(lanes), hint(lanes), loss(lanes), ax(lanes), aa(lanes), az(lanes)
    Real(dp), Allocatable :: x(:,:), saved_x(:,:), nse(:)
    Real(dp) :: saved_temperature(lanes), saved_ye(lanes), saved_restart(lanes), times(6)
    Allocate(x(Size(network%names),lanes),saved_x(Size(network%names),lanes),nse(Size(network%names)))
    Call fixture_state(network%names,d,temp,ey,x,hint,ax,aa,az)
    saved_x = x
    saved_temperature = temp
    saved_ye = ey
    saved_restart = hint
    active = .false.
    ids = 1
    counts = -777
    loss = -777.0_dp
    steps = -777
    r%owner = omp_get_thread_num()
    r%team = omp_get_num_threads()
    r%level = omp_get_level()
    Call xnet_burn_batch(0.001_dp,active,ids,d,temp,ey,x,hint,loss,counts,probe_timing, &
      & r%burn_status,r%burn_message,ax,aa,az,steps)
    times = [probe_timing%evolve,probe_timing%solve,probe_timing%jacobian,probe_timing%derivative,probe_timing%rates,probe_timing%screening]
    r%unchanged = All(x == saved_x) .and. All(temp == saved_temperature) .and. All(ey == saved_ye) .and. All(hint == saved_restart)
    r%cleared = All(loss == 0.0_dp) .and. All(counts == 0) .and. steps == 0 .and. All(times == 0.0_dp)
    nse = -777.0_dp
    Call xnet_nse_composition(1.0e6_dp,8.0e9_dp,0.45_dp,nse,r%nse_status,r%nse_message)
    r%cleared = r%cleared .and. All(nse == 0.0_dp)
  End Subroutine rejected_calls

  Subroutine check_rejected(r,label,team,level,reason)
    Implicit None
    Type(rejected_result_t), Intent(in) :: r
    Character(*), Intent(in) :: label, reason
    Integer, Intent(in) :: team, level
    Call check(r%team == team .and. r%level == level,label//' actual topology')
    Call check(r%burn_status == xnet_unsupported .and. r%nse_status == xnet_unsupported,label//' unsupported status')
    Call check(Index(r%burn_message,reason) > 0 .and. Index(r%nse_message,reason) > 0,label//' intended diagnostic')
    Call check(r%unchanged .and. r%cleared,label//' physical caller state unchanged and diagnostic outputs cleared')
    Write(*,'(a,1x,a,3(1x,i0),2(1x,a))') 'REJECTED_TEAM',label,r%owner,r%team,r%level,Trim(r%burn_message),Trim(r%nse_message)
  End Subroutine check_rejected

  Subroutine nse_phase(phase)
    Implicit None
    Integer, Intent(in) :: phase
    Integer :: batch
    If ( parallel_calls ) Then
      !$omp parallel do default(none) schedule(static,1) shared(first_batch,last_batch,phase,nse_results)
      Do batch = first_batch, last_batch
        Call query_nse(batch,phase)
      EndDo
      !$omp end parallel do
    Else
      Do batch = first_batch, last_batch
        Call query_nse(batch,phase)
      EndDo
    EndIf
  End Subroutine nse_phase

  Subroutine query_nse(batch,phase)
    Implicit None
    Integer, Intent(in) :: batch, phase
    Real(dp) :: d, temp, ey
    d = 10.0_dp**(5+phase)*(1.0_dp+0.1_dp*Real(batch,dp))
    temp = (7.0_dp+Real(phase,dp)+0.01_dp*Real(batch,dp))*1.0e9_dp
    ey = 0.44_dp+0.01_dp*Real(phase,dp)+0.001_dp*Real(batch,dp)
    nse_results(phase,batch)%owner = omp_get_thread_num()
    nse_results(phase,batch)%team = omp_get_num_threads()
    Call xnet_nse_composition(d,temp,ey,nse_results(phase,batch)%x, &
      & nse_results(phase,batch)%status,nse_results(phase,batch)%message)
  End Subroutine query_nse

  Subroutine execute_batch(batch)
    Implicit None
    Integer, Intent(in) :: batch
    Integer :: call_number, lane, n, nids
    Integer :: ids(4,lanes)
    Logical :: active(lanes)
    Real(dp) :: d(lanes), temp(lanes), ey(lanes), hint(lanes), loss(lanes), ax(lanes), aa(lanes), az(lanes)
    Real(dp), Allocatable :: x(:,:)
    Allocate(x(Size(network%names),lanes))
    Call fixture_state(network%names,d,temp,ey,x,hint,ax,aa,az)
    Do lane = 1, lanes
      ! Scientific inputs and diagnostic tuples depend on logical work, never on worker assignment.
      d(lane) = d(lane)*(1.0_dp+0.0125_dp*Real(batch,dp)+0.0025_dp*Real(lane,dp))
      temp(lane) = temp(lane)+5.0e6_dp*Real(batch,dp)
      ids(:,lane) = [100*batch+lane,-7-batch,9000+batch,40+lane]
    EndDo
    Do call_number = 1, Merge(1,calls,failure)
      n = lanes
      nids = Merge(3,4,Mod(batch+call_number,2) == 0)
      active = .true.
      Select Case (call_number)
      Case (2)
        active = [.true.,.false.,.true.,.true.]
      Case (3)
        n = lanes-1
        active = [.true.,.false.,.true.,.false.]
      Case (4)
        active = .false.
      Case (5)
        active = [.false.,.false.,.false.,.true.]
      End Select
      If ( failure ) active = [.false.,.true.,.false.,.false.]
      Associate(r=>results(call_number,batch))
      r%owner = omp_get_thread_num()
      r%team = omp_get_num_threads()
      r%n = n
      r%nids = nids
      r%ids = ids
      r%active = active
      r%dt = 0.02_dp*(1.0_dp+0.01_dp*Real(batch,dp))/Real(call_number,dp)
      If ( failure ) r%dt = 0.1_dp
      r%density = d
      ! Inactive scientific inputs may be invalid; they must be ignored and remain unchanged.
      If ( call_number == 4 ) r%density = -1.0_dp
      r%input_temperature = temp
      r%input_ye = ey
      r%input_restart = hint
      r%input_x = x
      r%loss = -777.0_dp
      r%counters = -777
      Call xnet_burn_batch(r%dt,active(:n),ids(:nids,:n),r%density(:n),temp(:n),ey(:n),x(:,:n), &
        & hint(:n),r%loss(:n),r%counters(:,:n),r%timing,r%status,r%message,ax(:n),aa(:n),az(:n),r%steps)
      If ( .not. failure ) Then
        r%temperature = temp
        r%ye = ey
        r%restart = hint
        r%x = x
      EndIf
      End Associate
    EndDo
    Deallocate(x)
  End Subroutine execute_batch

  Subroutine validate_result(r,batch,call_number)
    Implicit None
    Type(result_t), Intent(in) :: r
    Integer, Intent(in) :: batch, call_number
    Integer :: lane, expected
    Real(dp) :: times(6)
    Character(160) :: prefix
    Character(32) :: component
    If ( parallel_calls ) Then
      Call check(r%team == expected_threads,'actual burn team size')
    Else
      Call check(r%owner == 0 .and. r%team == 1,'serial call executes outside an application parallel region')
    EndIf
    times = [r%timing%evolve,r%timing%solve,r%timing%jacobian,r%timing%derivative,r%timing%rates,r%timing%screening]
    Call check(All(ieee_is_finite(times)) .and. All(times >= 0.0_dp),'finite nonnegative per-call timings')
    If ( failure ) Then
      expected = Merge(xnet_step_limit,xnet_integrator_failure,Index(mode,'step') > 0)
      Call check(r%status == expected,'returned worker failure: '//Trim(r%message))
      prefix = 'Zone 2, zone IDs ['
      Do lane = 1, r%nids
        Write(component,'(i0)') r%ids(lane,2)
        ! Concatenation must retain the separating space before the next integer.
        If ( lane == 1 ) Then
          prefix = Trim(prefix)//Trim(component)
        Else
          prefix = Trim(prefix)//' '//Trim(component)
        EndIf
      EndDo
      prefix = Trim(prefix)//']:'
      Call check(Index(r%message,Trim(prefix)) == 1,'failure lane/IDs belong to this logical batch')
      Call check(Index(r%message,'host must terminate') > 0,'fatal host policy')
      Call check(r%steps == 0,'failed call has no successful accepted-step result')
      Call check(All(r%counters(:,2) > 0),'failed active attempted counters')
      Call check(All(r%counters(:,[1,3,4]) == 0),'failed inactive attempted counters')
      Return
    EndIf
    If ( r%status /= xnet_success ) Write(*,'(a)') Trim(r%message)
    Call check(r%status == xnet_success,'successful logical batch/call')
    Call check(All(ieee_is_finite(r%x)) .and. All(r%x >= 0.0_dp),'finite nonnegative complete composition')
    Call check(All(ieee_is_finite(r%temperature)) .and. All(ieee_is_finite(r%ye)) &
      & .and. All(ieee_is_finite(r%restart)) .and. All(ieee_is_finite(r%loss)),'finite complete returned scalar arrays')
    If ( Any(r%active(:r%n)) ) Then
      Call check(r%steps > 0,'successful accepted steps')
    Else
      Call check(r%steps == 0,'all-inactive accepted steps')
    EndIf
    Do lane = 1, lanes
      If ( lane <= r%n ) Then
        If ( r%active(lane) ) Then
          Call check(r%counters(1,lane) > 0,'active attempted counters')
          Call check(ieee_is_finite(r%restart(lane)) .and. r%restart(lane) >= 0.0_dp,'nonnegative restart timestep')
          Cycle
        EndIf
        Call check(r%loss(lane) == 0.0_dp .and. All(r%counters(:,lane) == 0),'inactive diagnostics')
      Else
        Call check(r%loss(lane) == -777.0_dp .and. All(r%counters(:,lane) == -777),'unsubmitted diagnostics')
      EndIf
      Call check(All(r%x(:,lane) == r%input_x(:,lane)) .and. r%temperature(lane) == r%input_temperature(lane) &
        & .and. r%ye(lane) == r%input_ye(lane) .and. r%restart(lane) == r%input_restart(lane),'inactive/unsubmitted state')
    EndDo
    If ( call_number == calls ) Call check(Any(r%x /= results(1,batch)%x),'repeated calls evolve composition')
  End Subroutine validate_result
End Program host_batch_openmp_consumer
