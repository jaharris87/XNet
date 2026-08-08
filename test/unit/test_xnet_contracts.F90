Module test_xnet_contracts
  Use testdrive, Only: check, error_type, new_unittest, unittest_type
  Use xnet_types, Only: dp
  Implicit None
  Private

  Real(dp), Parameter :: tolerance = 1.0e-13_dp

  Public :: collect_xnet_contracts

Contains

  Subroutine collect_xnet_contracts(testsuite)
    Implicit None

    Type(unittest_type), Allocatable, Intent(out) :: testsuite(:)

    testsuite = [ &
      & new_unittest('safe exponential', test_safe_exp), &
      & new_unittest('mass normalization', test_norm), &
      & new_unittest('mass and charge normalization', test_ye_norm), &
      & new_unittest('ordered output suffix', test_name_ordered), &
      & new_unittest('trajectory scalar boundaries', test_t9rhofind_scalar), &
      & new_unittest('trajectory vector mask', test_t9rhofind_vector), &
      & new_unittest('abundance scalar moment', test_y_moment_scalar), &
      & new_unittest('abundance vector mask', test_y_moment_vector), &
      & new_unittest('neutrino interpolation', test_nnu_flux) ]

    Return
  End Subroutine collect_xnet_contracts

  Subroutine test_safe_exp(error)
    Use xnet_util, Only: safe_exp
    Implicit None

    Type(error_type), Allocatable, Intent(out) :: error

    Real(dp) :: expected_max, expected_min
    Real(dp) :: input(3), output(3)

    expected_max = exp(real(maxexponent(1.0_dp),dp)*log(2.0_dp)*0.9_dp)
    expected_min = exp(real(minexponent(1.0_dp),dp)*log(2.0_dp)*0.9_dp)

    Call check(error,safe_exp(0.0_dp),1.0_dp,thr=tolerance)
    If ( allocated(error) ) Return
    Call check(error,safe_exp(1.25_dp),exp(1.25_dp),thr=tolerance)
    If ( allocated(error) ) Return
    Call check(error,safe_exp(huge(1.0_dp)),expected_max,thr=tolerance)
    If ( allocated(error) ) Return
    Call check(error,safe_exp(-huge(1.0_dp)),expected_min,thr=tolerance)
    If ( allocated(error) ) Return

    input = (/ 0.0_dp, huge(1.0_dp), -huge(1.0_dp) /)
    output = safe_exp(input)
    Call check(error,output(1),1.0_dp,thr=tolerance)
    If ( allocated(error) ) Return
    Call check(error,output(2),expected_max,thr=tolerance)
    If ( allocated(error) ) Return
    Call check(error,output(3),expected_min,thr=tolerance)

    Return
  End Subroutine test_safe_exp

  Subroutine test_norm(error)
    Use xnet_util, Only: norm
    Implicit None

    Type(error_type), Allocatable, Intent(out) :: error

    Real(dp) :: aa(3), yy(3)

    aa = (/ 1.0_dp, 4.0_dp, 12.0_dp /)
    yy = (/ 0.20_dp, 0.05_dp, 0.01_dp /)

    Call norm(yy,aa)
    Call check(error,sum(aa*yy),1.0_dp,thr=tolerance)

    Return
  End Subroutine test_norm

  Subroutine test_ye_norm(error)
    Use xnet_util, Only: ye_norm
    Implicit None

    Type(error_type), Allocatable, Intent(out) :: error

    Real(dp), Parameter :: target_ye = 0.45_dp
    Real(dp) :: aa(3), nn(3), yy(3), zz(3)

    aa = (/ 1.0_dp, 1.0_dp, 4.0_dp /)
    nn = (/ 1.0_dp, 0.0_dp, 2.0_dp /)
    zz = (/ 0.0_dp, 1.0_dp, 2.0_dp /)
    yy = (/ 0.20_dp, 0.30_dp, 0.10_dp /)

    Call ye_norm(yy,target_ye,zz,nn,aa)
    Call check(error,sum(aa*yy),1.0_dp,thr=tolerance)
    If ( allocated(error) ) Return
    Call check(error,sum(zz*yy),target_ye,thr=tolerance)

    Return
  End Subroutine test_ye_norm

  Subroutine test_name_ordered(error)
    Use xnet_util, Only: name_ordered
    Implicit None

    Type(error_type), Allocatable, Intent(out) :: error

    Character(20) :: name

    name = 'ev_zone_'
    Call name_ordered(name,1,9)
    Call check(error,trim(name),'ev_zone_1')
    If ( allocated(error) ) Return

    name = 'ev_zone_'
    Call name_ordered(name,1,12)
    Call check(error,trim(name),'ev_zone_01')
    If ( allocated(error) ) Return

    name = 'ev_zone_'
    Call name_ordered(name,12,12)
    Call check(error,trim(name),'ev_zone_12')

    Return
  End Subroutine test_name_ordered

  Subroutine test_t9rhofind_scalar(error)
    Use xnet_conditions, Only: t9rhofind
    Implicit None

    Type(error_type), Allocatable, Intent(out) :: error

    Integer :: nf
    Real(dp) :: rho, t9
    Real(dp) :: rho_history(3), t9_history(3), time_history(3)

    time_history = (/ 1.0_dp, 2.0_dp, 4.0_dp /)
    t9_history = (/ 10.0_dp, 20.0_dp, 40.0_dp /)
    rho_history = (/ 100.0_dp, 400.0_dp, 1600.0_dp /)

    Call t9rhofind(0,1.0_dp,nf,t9,rho,3,time_history,t9_history,rho_history)
    Call check_trajectory(error,nf,t9,rho,1,10.0_dp,100.0_dp)
    If ( allocated(error) ) Return

    Call t9rhofind(0,2.0_dp,nf,t9,rho,3,time_history,t9_history,rho_history)
    Call check_trajectory(error,nf,t9,rho,2,20.0_dp,400.0_dp)
    If ( allocated(error) ) Return

    Call t9rhofind(0,3.0_dp,nf,t9,rho,3,time_history,t9_history,rho_history)
    Call check_trajectory(error,nf,t9,rho,3,30.0_dp,1000.0_dp)
    If ( allocated(error) ) Return

    Call t9rhofind(0,4.0_dp,nf,t9,rho,3,time_history,t9_history,rho_history)
    Call check_trajectory(error,nf,t9,rho,3,40.0_dp,1600.0_dp)
    If ( allocated(error) ) Return

    Call t9rhofind(0,5.0_dp,nf,t9,rho,3,time_history,t9_history,rho_history)
    Call check_trajectory(error,nf,t9,rho,4,40.0_dp,1600.0_dp)

    Return
  End Subroutine test_t9rhofind_scalar

  Subroutine test_t9rhofind_vector(error)
    Use xnet_conditions, Only: nh, rhoh, t9h, th, t9rhofind
    Implicit None

    Type(error_type), Allocatable, Intent(out) :: error

    Integer :: nf(3), scalar_nf
    Logical :: mask(3)
    Real(dp) :: rho(3), scalar_rho, scalar_t9, t9(3), tf(3)

    Call initialize_zone_fixture
    mask = (/ .True., .False., .True. /)
    tf = (/ 3.0_dp, 3.0_dp, 2.0_dp /)
    nf = (/ -1, -99, -1 /)
    t9 = (/ -1.0_dp, -99.0_dp, -1.0_dp /)
    rho = (/ -1.0_dp, -99.0_dp, -1.0_dp /)

    Call t9rhofind(0,tf,nf,t9,rho,mask)

    Call t9rhofind(0,tf(1),scalar_nf,scalar_t9,scalar_rho,nh(1), &
      & th(:,1),t9h(:,1),rhoh(:,1))
    Call check_trajectory(error,nf(1),t9(1),rho(1),scalar_nf,scalar_t9,scalar_rho)
    If ( allocated(error) ) Return

    Call t9rhofind(0,tf(3),scalar_nf,scalar_t9,scalar_rho,nh(3), &
      & th(:,3),t9h(:,3),rhoh(:,3))
    Call check_trajectory(error,nf(3),t9(3),rho(3),scalar_nf,scalar_t9,scalar_rho)
    If ( allocated(error) ) Return

    Call check(error,nf(2),-99)
    If ( allocated(error) ) Return
    Call check(error,t9(2),-99.0_dp,thr=tolerance)
    If ( allocated(error) ) Return
    Call check(error,rho(2),-99.0_dp,thr=tolerance)

    Return
  End Subroutine test_t9rhofind_vector

  Subroutine test_y_moment_scalar(error)
    Use xnet_abundances, Only: y_moment
    Implicit None

    Type(error_type), Allocatable, Intent(out) :: error

    Real(dp) :: abar, ye, ytot, z2bar, zbar, zibar
    Real(dp) :: y(2)

    Call initialize_nuclear_fixture
    y = (/ 0.20_dp, 0.10_dp /)
    Call y_moment(y,ye,ytot,abar,zbar,z2bar,zibar,0.30_dp,3.0_dp,1.0_dp)

    Call check_moments(error,ye,ytot,abar,zbar,z2bar,zibar, &
      & 0.5555555555555556_dp,0.40_dp,2.25_dp,1.25_dp,1.75_dp, &
      & 1.4974246243174694_dp)

    Return
  End Subroutine test_y_moment_scalar

  Subroutine test_y_moment_vector(error)
    Use xnet_abundances, Only: y_moment
    Implicit None

    Type(error_type), Allocatable, Intent(out) :: error

    Integer :: zone
    Logical :: mask(3)
    Real(dp) :: abar(3), aext(3), scalar_abar, scalar_ye, scalar_ytot
    Real(dp) :: scalar_z2bar, scalar_zbar, scalar_zibar
    Real(dp) :: xext(3), y(2,3), ye(3), ytot(3), z2bar(3), zbar(3), zext(3), zibar(3)

    Call initialize_zone_fixture
    Call initialize_nuclear_fixture
    mask = (/ .True., .False., .True. /)
    y(:,1) = (/ 0.20_dp, 0.10_dp /)
    y(:,2) = (/ 9.0_dp, 9.0_dp /)
    y(:,3) = (/ 0.30_dp, 0.05_dp /)
    xext = (/ 0.30_dp, 9.0_dp, 0.0_dp /)
    aext = (/ 3.0_dp, 9.0_dp, 1.0_dp /)
    zext = (/ 1.0_dp, 9.0_dp, 0.0_dp /)
    ye = -99.0_dp
    ytot = -99.0_dp
    abar = -99.0_dp
    zbar = -99.0_dp
    z2bar = -99.0_dp
    zibar = -99.0_dp

    Call y_moment(y,ye,ytot,abar,zbar,z2bar,zibar,xext,aext,zext,mask)

    Do zone = 1, 3, 2
      Call y_moment(y(:,zone),scalar_ye,scalar_ytot,scalar_abar,scalar_zbar, &
        & scalar_z2bar,scalar_zibar,xext(zone),aext(zone),zext(zone))
      Call check_moments(error,ye(zone),ytot(zone),abar(zone),zbar(zone), &
        & z2bar(zone),zibar(zone),scalar_ye,scalar_ytot,scalar_abar, &
        & scalar_zbar,scalar_z2bar,scalar_zibar)
      If ( allocated(error) ) Return
    EndDo

    Call check_moments(error,ye(2),ytot(2),abar(2),zbar(2),z2bar(2),zibar(2), &
      & -99.0_dp,-99.0_dp,-99.0_dp,-99.0_dp,-99.0_dp,-99.0_dp)

    Return
  End Subroutine test_y_moment_vector

  Subroutine test_nnu_flux(error)
    Use xnet_nnu, Only: nnuspec, nnu_flux
    Implicit None

    Type(error_type), Allocatable, Intent(out) :: error

    Integer :: nf
    Real(dp) :: flux(4), flux_history(3,4), ltnu(4), temperature_history(3,4)
    Real(dp) :: time_history(3)

    time_history = (/ 0.0_dp, 1.0_dp, 2.0_dp /)
    temperature_history(1,:) = (/ 2.0_dp, 4.0_dp, 8.0_dp, 16.0_dp /)
    temperature_history(2,:) = (/ 8.0_dp, 16.0_dp, 32.0_dp, 64.0_dp /)
    temperature_history(3,:) = (/ 18.0_dp, 36.0_dp, 72.0_dp, 144.0_dp /)
    flux_history(1,:) = (/ 0.0_dp, 0.0_dp, 10.0_dp, 4.0_dp /)
    flux_history(2,:) = (/ 0.0_dp, 20.0_dp, 40.0_dp, 16.0_dp /)
    flux_history(3,:) = (/ 5.0_dp, 30.0_dp, 90.0_dp, 25.0_dp /)

    Call nnu_flux(10.0_dp,nf,ltnu,flux,time_history,1,temperature_history,flux_history)
    Call check_nnu(error,nf,ltnu,flux,1,temperature_history(1,:),flux_history(1,:))
    If ( allocated(error) ) Return

    Call nnu_flux(0.0_dp,nf,ltnu,flux,time_history,3,temperature_history,flux_history)
    Call check_nnu(error,nf,ltnu,flux,1,temperature_history(1,:),flux_history(1,:))
    If ( allocated(error) ) Return

    Call nnu_flux(0.5_dp,nf,ltnu,flux,time_history,3,temperature_history,flux_history)
    Call check_nnu(error,nf,ltnu,flux,2, &
      & (/ 4.0_dp, 8.0_dp, 16.0_dp, 32.0_dp /), &
      & (/ 0.0_dp, 10.0_dp, 20.0_dp, 8.0_dp /))
    If ( allocated(error) ) Return

    Call nnu_flux(1.0_dp,nf,ltnu,flux,time_history,3,temperature_history,flux_history)
    Call check_nnu(error,nf,ltnu,flux,2,temperature_history(2,:),flux_history(2,:))
    If ( allocated(error) ) Return

    Call nnu_flux(2.0_dp,nf,ltnu,flux,time_history,3,temperature_history,flux_history)
    Call check_nnu(error,nf,ltnu,flux,3,temperature_history(3,:),flux_history(3,:))
    If ( allocated(error) ) Return

    Call nnu_flux(3.0_dp,nf,ltnu,flux,time_history,3,temperature_history,flux_history)
    Call check_nnu(error,nf,ltnu,flux,4,temperature_history(3,:),flux_history(3,:))
    If ( allocated(error) ) Return

    Call nnu_flux(-0.5_dp,nf,ltnu,flux,time_history,3,temperature_history,flux_history)
    Call check_nnu(error,nf,ltnu,flux,1,temperature_history(1,:),flux_history(1,:))

    Return
  End Subroutine test_nnu_flux

  Subroutine initialize_zone_fixture
    Use xnet_conditions, Only: nh, rhoh, t9h, th
    Use xnet_controls, Only: lzactive, nzevolve, zb_hi, zb_lo
    Implicit None

    Integer :: zone

    zb_lo = 1
    zb_hi = 3
    nzevolve = 3
    If ( allocated(lzactive) ) Deallocate(lzactive)
    Allocate(lzactive(3))
    lzactive = .True.

    If ( allocated(nh) ) Deallocate(nh)
    If ( allocated(th) ) Deallocate(th)
    If ( allocated(t9h) ) Deallocate(t9h)
    If ( allocated(rhoh) ) Deallocate(rhoh)
    Allocate(nh(3),th(3,3),t9h(3,3),rhoh(3,3))
    nh = 3
    Do zone = 1, 3
      th(:,zone) = (/ 1.0_dp, 2.0_dp, 4.0_dp /)
      t9h(:,zone) = (/ 10.0_dp, 20.0_dp, 40.0_dp /) + real(zone-1,dp)
      rhoh(:,zone) = (/ 100.0_dp, 400.0_dp, 1600.0_dp /) + real(zone-1,dp)
    EndDo

    Return
  End Subroutine initialize_zone_fixture

  Subroutine initialize_nuclear_fixture
    Use nuclear_data, Only: aa, ny, zz, zz2, zzi
    Implicit None

    ny = 2
    If ( allocated(aa) ) Deallocate(aa)
    If ( allocated(zz) ) Deallocate(zz)
    If ( allocated(zz2) ) Deallocate(zz2)
    If ( allocated(zzi) ) Deallocate(zzi)
    Allocate(aa(2),zz(2),zz2(2),zzi(2))
    aa = (/ 1.0_dp, 4.0_dp /)
    zz = (/ 1.0_dp, 2.0_dp /)
    zz2 = (/ 1.0_dp, 4.0_dp /)
    zzi = (/ 1.0_dp, 2.989698497269877_dp /)

    Return
  End Subroutine initialize_nuclear_fixture

  Subroutine check_trajectory(error,nf,t9,rho,expected_nf,expected_t9,expected_rho)
    Implicit None

    Type(error_type), Allocatable, Intent(out) :: error
    Integer, Intent(in) :: expected_nf, nf
    Real(dp), Intent(in) :: expected_rho, expected_t9, rho, t9

    Call check(error,nf,expected_nf)
    If ( allocated(error) ) Return
    Call check(error,t9,expected_t9,thr=tolerance)
    If ( allocated(error) ) Return
    Call check(error,rho,expected_rho,thr=tolerance)

    Return
  End Subroutine check_trajectory

  Subroutine check_moments(error,ye,ytot,abar,zbar,z2bar,zibar, &
    & expected_ye,expected_ytot,expected_abar,expected_zbar,expected_z2bar,expected_zibar)
    Implicit None

    Type(error_type), Allocatable, Intent(out) :: error
    Real(dp), Intent(in) :: abar, expected_abar, expected_ye, expected_ytot
    Real(dp), Intent(in) :: expected_z2bar, expected_zbar, expected_zibar
    Real(dp), Intent(in) :: ye, ytot, z2bar, zbar, zibar

    Call check(error,ye,expected_ye,thr=tolerance)
    If ( allocated(error) ) Return
    Call check(error,ytot,expected_ytot,thr=tolerance)
    If ( allocated(error) ) Return
    Call check(error,abar,expected_abar,thr=tolerance)
    If ( allocated(error) ) Return
    Call check(error,zbar,expected_zbar,thr=tolerance)
    If ( allocated(error) ) Return
    Call check(error,z2bar,expected_z2bar,thr=tolerance)
    If ( allocated(error) ) Return
    Call check(error,zibar,expected_zibar,thr=tolerance)

    Return
  End Subroutine check_moments

  Subroutine check_nnu(error,nf,ltnu,flux,expected_nf,expected_temperature,expected_flux)
    Use xnet_nnu, Only: nnuspec
    Implicit None

    Type(error_type), Allocatable, Intent(out) :: error
    Integer, Intent(in) :: expected_nf, nf
    Real(dp), Intent(in) :: expected_flux(nnuspec), expected_temperature(nnuspec)
    Real(dp), Intent(in) :: flux(nnuspec), ltnu(nnuspec)

    Call check(error,nf,expected_nf)
    If ( allocated(error) ) Return
    Call check(error,all(abs(ltnu-log(expected_temperature)) <= tolerance))
    If ( allocated(error) ) Return
    Call check(error,all(abs(flux-expected_flux) <= tolerance))

    Return
  End Subroutine check_nnu

End Module test_xnet_contracts

Program xnet_contract_test_runner
  Use, Intrinsic :: iso_fortran_env, Only: error_unit
  Use test_xnet_contracts, Only: collect_xnet_contracts
  Use testdrive, Only: new_testsuite, run_testsuite, testsuite_type
  Implicit None

  Integer :: stat
  Type(testsuite_type), Allocatable :: testsuites(:)

  stat = 0
  testsuites = [ new_testsuite('XNet deterministic contracts',collect_xnet_contracts) ]
  Write(error_unit,'("# Testing: ",a)') testsuites(1)%name
  Call run_testsuite(testsuites(1)%collect,error_unit,stat)

  If ( stat > 0 ) Then
    Write(error_unit,'(i0,1x,a)') stat,'test(s) failed'
    Stop 1
  EndIf
End Program xnet_contract_test_runner
