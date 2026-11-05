Program cleanup_consumer
  Use xnet_api, Only: dp, xnet_controls_t, xnet_network_t, xnet_timing_t, &
    & set_xnet_controls_defaults, xnet_initialize, xnet_burn_batch, xnet_nse_composition, &
    & xnet_finalize, xnet_success, xnet_invalid, xnet_lifecycle_error
  Use xnet_gpu, Only: init_calls, finalize_calls, failures_left, active_gpu=>active, &
    & init_failures_left, pending_on_init_failure, mydevice
  Use xnet_abundances, Only: y
  Implicit None
  Type(xnet_controls_t) :: controls
  Type(xnet_network_t) :: network, rejected_network
  Type(xnet_timing_t) :: timing
  Integer :: ierr, ids(3,1), counters(5,1), calls
  Character(512) :: message
  Logical :: active(1)
  Real(dp) :: density(1), temperature(1), ye(1), restart(1), loss(1)
  Real(dp), Allocatable :: x(:,:), nse(:)

  Call set_xnet_controls_defaults(controls)
  controls%data_dir = 'Data_alpha'
  controls%nzone = 1
  controls%nzbatchmx = 1
  controls%iheat = 0
  controls%idiag = -2
  Call xnet_finalize(ierr,message)
  Call expect(xnet_success,'finalize before initialize')
  Call check(finalize_calls == 0,'no resource cleanup before initialization')
  Call xnet_initialize(controls,network,ierr,message)
  Call expect(xnet_success,'initialize')
  Call check(Allocated(y),'real XNet workspace allocated')
  Call check(init_calls == 1,'one GPU initialization')
  Allocate(x(Size(network%names),1),nse(Size(network%names)))
  x = 0.0_dp
  density = 1.0e7_dp
  temperature = 1.7e9_dp
  ye = 0.5_dp
  restart = 0.0_dp
  active = .true.
  ids = 1
  failures_left = 2

  Call xnet_finalize(ierr,message)
  Call expect(xnet_invalid,'first cleanup failure')
  Call check(finalize_calls == 1 .and. active_gpu,'GPU cleanup remains pending')
  Call check(.not. Allocated(y),'real XNet workspace released before GPU cleanup')
  ! If a retry repeats workspace teardown, this temporary allocation will disappear.
  Allocate(y(1,1))
  y = 42.0_dp
  Call xnet_finalize(ierr,message)
  Call expect(xnet_invalid,'second cleanup attempt must reach the GPU finalizer')
  Call check(finalize_calls == 2 .and. active_gpu,'second failure remains pending')
  Call check(Allocated(y),'retry must not repeat workspace teardown')
  Call check(All(y == 42.0_dp),'retry preserved workspace sentinel')
  Deallocate(y)

  Call xnet_initialize(controls,rejected_network,ierr,message)
  Call expect(xnet_lifecycle_error,'initialize during pending cleanup')
  Call check(init_calls == 1,'rejected initialization did not enter resource setup')
  Call xnet_burn_batch(0.1_dp,active,ids,density,temperature,ye,x,restart,loss,counters,timing,ierr,message)
  Call expect(xnet_lifecycle_error,'burn during pending cleanup')
  Call check(All(loss == 0.0_dp) .and. All(counters == 0),'rejected burn clears outputs')
  Call xnet_nse_composition(1.0e7_dp,1.0e10_dp,0.5_dp,nse,ierr,message)
  Call expect(xnet_lifecycle_error,'NSE during pending cleanup')
  Call check(All(nse == 0.0_dp),'rejected NSE clears output')
  Call xnet_finalize(ierr,message)
  Call expect(xnet_success,'successful cleanup retry')
  Call check(finalize_calls == 3 .and. .not. active_gpu,'GPU cleanup completed')
  Call xnet_finalize(ierr,message)
  Call expect(xnet_success,'repeat finalize after cleanup')
  Call check(finalize_calls == 3,'repeat finalize does not enter resource cleanup')
  Call xnet_initialize(controls,network,ierr,message)
  Call expect(xnet_success,'reinitialize after successful cleanup')
  Call check(Allocated(y) .and. init_calls == 2,'new real workspace and resources')
  Call xnet_finalize(ierr,message)
  Call expect(xnet_success,'ordinary finalize')
  Call check(finalize_calls == 4 .and. .not. active_gpu,'ordinary resource cleanup completed')
  calls = finalize_calls
  Call xnet_finalize(ierr,message)
  Call expect(xnet_success,'ordinary repeated finalize')
  Call check(finalize_calls == calls .and. .not. Allocated(y),'ordinary cleanup runs once')
  Call failed_initialization_checks()
  Print '(a)', 'GPU_CLEANUP_RETRY_CHECKS_PASSED'
Contains
  Subroutine failed_initialization_checks()
    Integer :: saved_init_calls, saved_finalize_calls, attempt
    saved_init_calls = init_calls
    saved_finalize_calls = finalize_calls
    ! Validation fails before gpu_init and before any owned allocation.
    controls%nzone = 0
    Call xnet_initialize(controls,network,ierr,message)
    Call expect(xnet_invalid,'malformed initialization controls')
    Call check(init_calls == saved_init_calls,'invalid controls did not initialize GPU resources')
    Call check(.not. Allocated(y) .and. .not. active_gpu,'invalid controls allocated no workspaces or resources')
    controls%nzone = 1

    ! A failed initialization whose own rollback succeeded needs no API cleanup.
    init_failures_left = 1
    pending_on_init_failure = .false.
    Call xnet_initialize(controls,network,ierr,message)
    Call expect(xnet_invalid,'initialization failure with completed rollback')
    Call check(Index(message,'Injected GPU initialization failure') > 0,'initialization failure diagnostic')
    Call check(.not. Allocated(y) .and. mydevice == -1,'clean rollback precedes workspace creation')
    Call xnet_finalize(ierr,message)
    Call expect(xnet_success,'finalize after completed initialization rollback')
    Call check(finalize_calls == saved_finalize_calls,'completed rollback does not finalize inactive resources')
    Call xnet_initialize(controls,network,ierr,message)
    Call expect(xnet_success,'reinitialize after completed initialization rollback')
    Call xnet_finalize(ierr,message)
    Call expect(xnet_success,'finalize reinitialized lifetime')

    ! gpu_init has already attempted rollback; the stub represents resources
    ! whose destructor keeps failing until the test clears the failure.
    init_failures_left = 1
    pending_on_init_failure = .true.
    failures_left = -1
    saved_init_calls = init_calls
    Call xnet_initialize(controls,network,ierr,message)
    Call expect(xnet_invalid,'initialization failure with pending GPU cleanup')
    Call check(Index(message,'Injected GPU initialization failure') > 0,'pending cleanup preserves initialization diagnostic')
    Call check(init_calls == saved_init_calls+1 .and. active_gpu .and. mydevice == 0,'failed rollback retains resources')
    Call check(.not. Allocated(y),'failed resource initialization never allocated CPU workspaces')
    Call xnet_initialize(controls,rejected_network,ierr,message)
    Call expect(xnet_lifecycle_error,'reinitialize during failed initialization cleanup')
    Call check(init_calls == saved_init_calls+1,'pending rollback blocks resource initialization')
    Call xnet_burn_batch(0.1_dp,active,ids,density,temperature,ye,x,restart,loss,counters,timing,ierr,message)
    Call expect(xnet_lifecycle_error,'burn during failed initialization cleanup')
    Call check(All(loss == 0.0_dp) .and. All(counters == 0),'pending rollback burn clears outputs')
    Call xnet_nse_composition(1.0e7_dp,1.0e10_dp,0.5_dp,nse,ierr,message)
    Call expect(xnet_lifecycle_error,'NSE during failed initialization cleanup')
    Call check(All(nse == 0.0_dp),'pending rollback NSE clears output')

    ! The API never created its workspaces, so cleanup must not tear them down.
    Allocate(y(1,1))
    y = 43.0_dp
    saved_finalize_calls = finalize_calls
    Do attempt = 1, 3
      Call xnet_finalize(ierr,message)
      Call expect(xnet_invalid,'persistent initialization rollback cleanup failure')
      Call check(finalize_calls == saved_finalize_calls+attempt .and. active_gpu,'every finalize retries pending resources')
      Call check(Allocated(y),'failed initialization cleanup skips workspace teardown')
      Call check(All(y == 43.0_dp),'failed initialization cleanup preserves workspace sentinel')
    EndDo
    failures_left = 0
    Call xnet_finalize(ierr,message)
    Call expect(xnet_success,'complete failed initialization cleanup')
    Call check(.not. active_gpu .and. mydevice == -1,'failed initialization resources released')
    Call check(Allocated(y),'successful rollback cleanup also skips workspace teardown')
    Call check(All(y == 43.0_dp),'successful rollback cleanup preserves workspace sentinel')
    saved_finalize_calls = finalize_calls
    Call xnet_finalize(ierr,message)
    Call expect(xnet_success,'repeat finalize after failed initialization cleanup')
    Call check(finalize_calls == saved_finalize_calls,'completed failed initialization cleanup is a no-op')
    Deallocate(y)
    Call xnet_initialize(controls,network,ierr,message)
    Call expect(xnet_success,'reinitialize after pending initialization cleanup completes')
    Call check(Allocated(y),'reinitialization creates real workspaces')
    Call xnet_finalize(ierr,message)
    Call expect(xnet_success,'finalize after recovered initialization')
  End Subroutine

  Subroutine check(condition,label)
    Logical, Intent(in) :: condition
    Character(*), Intent(in) :: label
    If ( .not. condition ) Then
      Print '(a)', 'FAILED: '//label
      Stop 1
    EndIf
  End Subroutine
  Subroutine expect(expected,label)
    Integer, Intent(in) :: expected
    Character(*), Intent(in) :: label
    If ( ierr /= expected ) Then
      Print '(a,2(1x,i0))', 'FAILED: '//label//' expected/observed:',expected,ierr
      Print '(a)', Trim(message)
      Stop 1
    EndIf
  End Subroutine
End Program
