! Focused checks of host/device diagnostic state; the final failure is intentional.
#include "xnet_macros.fh"
Program diagnostic_checks
  Use xnet_api, Only: dp, xnet_controls_t, xnet_network_t, xnet_timing_t, &
    & set_xnet_controls_defaults, xnet_initialize, xnet_burn_batch, xnet_success, xnet_lifecycle_error, xnet_invalid
  Use xnet_controls, Only: iweak, iweak0, t9min, gpu_queue, idiag, lun_diag, zone_id
  Use xnet_conditions, Only: t, tdel, tstart, tstop, t9start, rhostart, yestart
  Use xnet_abundances, Only: yo, xext
  Use xnet_integrate, Only: update_iweak
  Use xnet_jacobian, Only: jac, info, msize, jacobian_decomp
  Use xnet_evolve_diagnostics, Only: terminate_on_zone_failure
#if defined(XNET_OACC)
  Use openacc, Only: acc_on_device, acc_device_host
#elif defined(XNET_OMP_OL)
  Use omp_lib, Only: omp_is_initial_device
#endif
  Implicit None
  Type(xnet_controls_t) :: controls
  Type(xnet_network_t) :: network
  Type(xnet_timing_t) :: timing
  Character(512) :: message
  Character(80) :: data_dir
  Integer :: ierr, k, counters(5,4), ids(4,4)
  Real(dp) :: low_t9(4), dummy(4), dummy_x(1,4), loss(4)
  Logical, Target :: mask(4)
  Logical :: offloaded

  ! A lifecycle error must not touch a resident scientific output host mirror.
  dummy = 1.0_dp
  dummy_x = 1.0_dp
  loss = -7.0_dp
  ids = 0
  mask = .false.
  Call xnet_burn_batch(1.0_dp,mask,ids,dummy,dummy,dummy,dummy_x,dummy,loss,counters, &
    & timing,ierr,message,data_on_device=.true.)
  Call check(ierr == xnet_lifecycle_error,'lifecycle status')
#ifdef XNET_GPU
  Call check(All(loss == -7.0_dp),'resident lifecycle loss mirror')
#else
  Call check(All(loss == 0.0_dp),'CPU lifecycle diagnostic clearing')
#endif

  Call get_command_argument(1,data_dir)
  Call set_xnet_controls_defaults(controls)
  controls%data_dir = data_dir
  controls%nzbatchmx = 4
  controls%idiag = -2
  Call xnet_initialize(controls,network,ierr,message)
  If ( ierr /= xnet_success ) Write(*,'(a)') Trim(message)
  Call check(ierr == xnet_success,'initialize')
  offloaded = .false.
#if defined(XNET_OACC)
  !$acc serial copyout(offloaded)
  offloaded = .not. acc_on_device(acc_device_host)
  !$acc end serial
#elif defined(XNET_OMP_OL)
  !$omp target map(from:offloaded)
  offloaded = .not. omp_is_initial_device()
  !$omp end target
#endif
#ifdef XNET_GPU
  Call check(offloaded,'real GPU execution')
  Write(*,'(a)') 'DIAGNOSTIC_GPU_EXECUTION_CONFIRMED'
  loss = -7.0_dp
  Call xnet_burn_batch(1.0_dp,mask,ids,dummy,dummy,dummy,dummy_x,dummy,loss,counters, &
    & timing,ierr,message,data_on_device=.true.)
  Call check(ierr == xnet_invalid .and. All(loss == -7.0_dp),'unmapped loss host mirror')
#endif

  ! Two low-temperature active zones warn; the masked low-temperature zone stays unchanged.
  mask = [.true.,.false.,.true.,.true.]
  low_t9 = [0.5_dp,0.5_dp,2.0_dp,0.5_dp]*t9min
  iweak = 99
  iweak0 = 2
  !XDIR XUPDATE XDEVICE(iweak)
  Call update_iweak(low_t9,mask)
  !XDIR XUPDATE XWAIT(gpu_queue) XHOST(iweak)
  Call check(All(iweak == [-2,99,2,-2]),'weak switch and mask')
  iweak0 = 0
  Call update_iweak(low_t9,mask)
  !XDIR XUPDATE XWAIT(gpu_queue) XHOST(iweak)
  Call check(All(iweak == [0,99,0,0]),'disabled weak switch has no warnings')
  Write(*,'(a)') 'WEAK_DIAGNOSTIC_CHECKS_PASSED'

  ! LU diagnostics must copy factors and device info, including a singular second matrix.
  Open(newunit=lun_diag,file='lu_diag',status='replace')
  idiag = 6
  mask = [.true.,.true.,.false.,.false.]
  jac = 0.0_dp
  Do k = 1, msize
    jac(k,k,:) = 2.0_dp
  EndDo
  jac(msize,msize,2) = 0.0_dp
  info = -99
  !XDIR XUPDATE XDEVICE(jac,info)
#ifdef XNET_GPU
  jac = -7.0_dp
#endif
  Call jacobian_decomp(1,mask)
  Call check(info(1) == 0 .and. info(2) == msize,'LU diagnostic info freshness')
  Call check(jac(1,1,1) == 2.0_dp .and. jac(msize,msize,2) == 0.0_dp,'LU diagnostic factors')
  Close(lun_diag)
  Open(newunit=lun_diag,file='failure_diag',status='replace')
  Write(*,'(a)') 'LU_DIAGNOSTIC_CHECKS_PASSED'

  ! The handler must dump yo, preserving the existing pre-step composition convention.
  idiag = -2
  yo = 0.125_dp
  xext = 0.0_dp
  t = 0.5_dp
  tdel = 0.1_dp
  tstart = 0.0_dp
  tstop = 1.0_dp
  t9start = 1.0_dp
  rhostart = 1.0e6_dp
  yestart = 0.5_dp
  zone_id(:,1) = [1,2,3,0]
  !XDIR XUPDATE XDEVICE(yo)
#ifdef XNET_GPU
  yo = -7.0_dp
#endif
  Write(*,'(a)') 'FAILURE_DUMP_EXPECTED'
  Call terminate_on_zone_failure(1)
  Stop 2
Contains
  Subroutine check(ok,label)
    Logical, Intent(in) :: ok
    Character(*), Intent(in) :: label
    If ( ok ) Return
    Write(*,'(2a)') 'FAILED: ',label
    Stop 2
  End Subroutine check
End Program diagnostic_checks
