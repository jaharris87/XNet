Program cleanup_consumer
  Use xnet_api, Only: dp, xnet_controls_t, xnet_network_t, xnet_timing_t, &
    & set_xnet_controls_defaults, xnet_initialize, xnet_burn_batch, xnet_nse_composition, &
    & xnet_finalize, xnet_success, xnet_invalid, xnet_lifecycle_error
  Use xnet_gpu, Only: init_calls, finalize_calls, failures_left, active_gpu=>active
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
  Print '(a)', 'GPU_CLEANUP_RETRY_CHECKS_PASSED'
Contains
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
