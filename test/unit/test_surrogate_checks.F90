Module test_surrogate_checks
  Use testdrive, Only: check, error_type, new_unittest, unittest_type
  Use xnet_types, Only: dp
  Implicit None
  Private

  Real(dp), Parameter :: tight_tolerance = 1.0e-14_dp

  Public :: collect_surrogate_checks

Contains

  Subroutine collect_surrogate_checks(testsuite)
    Implicit None
    Type(unittest_type), Allocatable, Intent(out) :: testsuite(:)

    testsuite = [ &
      & new_unittest('surrogate finite values',test_finite_values), &
      & new_unittest('surrogate fraction bounds',test_fraction_bounds), &
      & new_unittest('surrogate mass normalization',test_mass_normalization), &
      & new_unittest('surrogate fixed electron fraction',test_electron_fraction), &
      & new_unittest('surrogate inactive identity',test_inactive_identity), &
      & new_unittest('surrogate binding energy rate',test_binding_energy_rate), &
      & new_unittest('surrogate EOS result',test_eos_result), &
      & new_unittest('surrogate coordinator basics',test_coordinator_basics), &
      & new_unittest('surrogate coordinator optional data',test_coordinator_optional_data) ]

    Return
  End Subroutine collect_surrogate_checks

  Subroutine test_finite_values(error)
    Use, Intrinsic :: ieee_arithmetic, Only: ieee_quiet_nan, ieee_value
    Use xnet_surrogate_checks, Only: bn_check_failed, bn_check_finite_values, &
      & bn_check_invalid, bn_check_passed
    Implicit None
    Type(error_type), Allocatable, Intent(out) :: error

    Integer :: bad_index, status
    Real(dp) :: empty(0), values(3)

    Call bn_check_finite_values(empty,status,bad_index)
    Call check(error,status,bn_check_invalid)
    If ( allocated(error) ) Return

    values = (/ 0.0_dp, 0.25_dp, 0.75_dp /)
    Call bn_check_finite_values(values,status,bad_index)
    Call check(error,status,bn_check_passed)
    If ( allocated(error) ) Return
    Call check(error,bad_index,0)
    If ( allocated(error) ) Return

    values(2) = ieee_value(values(2),ieee_quiet_nan)
    Call bn_check_finite_values(values,status,bad_index)
    Call check(error,status,bn_check_failed)
    If ( allocated(error) ) Return
    Call check(error,bad_index,2)

    Return
  End Subroutine test_finite_values

  Subroutine test_fraction_bounds(error)
    Use, Intrinsic :: ieee_arithmetic, Only: ieee_quiet_nan, ieee_value
    Use xnet_surrogate_checks, Only: bn_check_failed, bn_check_fraction_bounds, &
      & bn_check_invalid, bn_check_passed
    Implicit None
    Type(error_type), Allocatable, Intent(out) :: error

    Integer :: status
    Real(dp) :: maximum_fraction, minimum_fraction, xmass(3)

    xmass = (/ -1.0e-15_dp, 0.25_dp, 0.75_dp /)
    Call bn_check_fraction_bounds(xmass,1.0e-14_dp,status,minimum_fraction,maximum_fraction)
    Call check(error,status,bn_check_passed)
    If ( allocated(error) ) Return
    Call check(error,minimum_fraction,-1.0e-15_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return
    Call check(error,maximum_fraction,0.75_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return

    xmass(1) = -1.0e-4_dp
    Call bn_check_fraction_bounds(xmass,1.0e-14_dp,status,minimum_fraction,maximum_fraction)
    Call check(error,status,bn_check_failed)
    If ( allocated(error) ) Return

    Call bn_check_fraction_bounds(xmass,-1.0_dp,status,minimum_fraction,maximum_fraction)
    Call check(error,status,bn_check_invalid)
    If ( allocated(error) ) Return

    Call bn_check_fraction_bounds(xmass,ieee_value(0.0_dp,ieee_quiet_nan),status, &
      & minimum_fraction,maximum_fraction)
    Call check(error,status,bn_check_invalid)

    Return
  End Subroutine test_fraction_bounds

  Subroutine test_mass_normalization(error)
    Use xnet_surrogate_checks, Only: bn_check_failed, bn_check_invalid, &
      & bn_check_mass_normalization, bn_check_passed
    Implicit None
    Type(error_type), Allocatable, Intent(out) :: error

    Integer :: status
    Real(dp) :: residual, xmass(3)

    xmass = (/ 0.20_dp, 0.30_dp, 0.50_dp /)
    Call bn_check_mass_normalization(xmass,1.0e-14_dp,status,residual)
    Call check(error,status,bn_check_passed)
    If ( allocated(error) ) Return
    Call check(error,residual,0.0_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return

    xmass(3) = 0.49_dp
    Call bn_check_mass_normalization(xmass,1.0e-14_dp,status,residual)
    Call check(error,status,bn_check_failed)
    If ( allocated(error) ) Return
    Call check(error,residual,-1.0e-2_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return

    Call bn_check_mass_normalization(xmass,-1.0_dp,status,residual)
    Call check(error,status,bn_check_invalid)

    Return
  End Subroutine test_mass_normalization

  Subroutine test_electron_fraction(error)
    Use, Intrinsic :: ieee_arithmetic, Only: ieee_quiet_nan, ieee_value
    Use xnet_surrogate_checks, Only: bn_check_electron_fraction, bn_check_failed, &
      & bn_check_invalid, bn_check_passed
    Implicit None
    Type(error_type), Allocatable, Intent(out) :: error

    Integer :: status
    Real(dp) :: aa(3), initial_ye, residual, result_ye, x_initial(3), x_result(3), zz(3)

    aa = (/ 1.0_dp, 1.0_dp, 4.0_dp /)
    zz = (/ 0.0_dp, 1.0_dp, 2.0_dp /)
    x_initial = (/ 0.10_dp, 0.10_dp, 0.80_dp /)
    x_result = (/ 0.0_dp, 0.0_dp, 1.0_dp /)
    Call bn_check_electron_fraction(x_initial,x_result,aa,zz,tight_tolerance,status, &
      & initial_ye,result_ye,residual)
    Call check(error,status,bn_check_passed)
    If ( allocated(error) ) Return
    Call check(error,initial_ye,0.50_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return
    Call check(error,result_ye,0.50_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return
    Call check(error,residual,0.0_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return

    x_result = (/ 0.10_dp, 0.20_dp, 0.70_dp /)
    Call bn_check_electron_fraction(x_initial,x_result,aa,zz,tight_tolerance,status, &
      & initial_ye,result_ye,residual)
    Call check(error,status,bn_check_failed)
    If ( allocated(error) ) Return
    Call check(error,residual,0.05_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return

    aa(1) = 0.0_dp
    Call bn_check_electron_fraction(x_initial,x_result,aa,zz,tight_tolerance,status, &
      & initial_ye,result_ye,residual)
    Call check(error,status,bn_check_invalid)
    If ( allocated(error) ) Return

    aa(1) = ieee_value(aa(1),ieee_quiet_nan)
    Call bn_check_electron_fraction(x_initial,x_result,aa,zz,tight_tolerance,status, &
      & initial_ye,result_ye,residual)
    Call check(error,status,bn_check_invalid)

    Return
  End Subroutine test_electron_fraction

  Subroutine test_inactive_identity(error)
    Use xnet_surrogate_checks, Only: bn_check_failed, bn_check_inactive_identity, &
      & bn_check_invalid, bn_check_passed
    Implicit None
    Type(error_type), Allocatable, Intent(out) :: error

    Integer :: status
    Real(dp) :: energy_residual, fraction_residual, x_initial(3), x_result(3)

    x_initial = (/ 0.20_dp, 0.30_dp, 0.50_dp /)
    x_result = x_initial
    Call bn_check_inactive_identity(x_initial,x_result,0.0_dp,tight_tolerance, &
      & tight_tolerance,status,fraction_residual,energy_residual)
    Call check(error,status,bn_check_passed)
    If ( allocated(error) ) Return
    Call check(error,fraction_residual,0.0_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return
    Call check(error,energy_residual,0.0_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return

    x_result(2) = x_result(2) + 1.0e-4_dp
    Call bn_check_inactive_identity(x_initial,x_result,0.0_dp,tight_tolerance, &
      & tight_tolerance,status,fraction_residual,energy_residual)
    Call check(error,status,bn_check_failed)
    If ( allocated(error) ) Return
    Call check(error,fraction_residual,1.0e-4_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return

    x_result = x_initial
    Call bn_check_inactive_identity(x_initial,x_result,1.0_dp,tight_tolerance, &
      & tight_tolerance,status,fraction_residual,energy_residual)
    Call check(error,status,bn_check_failed)
    If ( allocated(error) ) Return
    Call check(error,energy_residual,1.0_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return

    Call bn_check_inactive_identity(x_initial,x_result,0.0_dp,-1.0_dp, &
      & tight_tolerance,status,fraction_residual,energy_residual)
    Call check(error,status,bn_check_invalid)

    Return
  End Subroutine test_inactive_identity

  Subroutine test_binding_energy_rate(error)
    Use, Intrinsic :: ieee_arithmetic, Only: ieee_quiet_nan, ieee_value
    Use xnet_constants, Only: avn, epmev
    Use xnet_surrogate_checks, Only: bn_check_binding_energy_rate, bn_check_failed, &
      & bn_check_invalid, bn_check_passed
    Implicit None
    Type(error_type), Allocatable, Intent(out) :: error

    Integer :: status
    Real(dp) :: aa(2), be(2), energy_rate, expected_rate, residual, x_initial(2), x_result(2)

    aa = (/ 1.0_dp, 2.0_dp /)
    be = (/ 0.0_dp, 2.0_dp /)
    x_initial = (/ 1.0_dp, 0.0_dp /)
    x_result = (/ 0.0_dp, 1.0_dp /)
    energy_rate = 0.5_dp*avn*epmev
    Call bn_check_binding_energy_rate(x_initial,x_result,aa,be,2.0_dp,energy_rate, &
      & 0.0_dp,tight_tolerance,status,expected_rate,residual)
    Call check(error,status,bn_check_passed)
    If ( allocated(error) ) Return
    Call check(error,expected_rate,energy_rate,thr=tight_tolerance*abs(energy_rate))
    If ( allocated(error) ) Return
    Call check(error,residual,0.0_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return

    Call bn_check_binding_energy_rate(x_initial,x_result,aa,be,2.0_dp, &
      & energy_rate*(1.0_dp+1.0e-4_dp),0.0_dp,1.0e-6_dp,status,expected_rate,residual)
    Call check(error,status,bn_check_failed)
    If ( allocated(error) ) Return

    Call bn_check_binding_energy_rate(x_initial,x_result,aa,be,0.0_dp,energy_rate, &
      & 0.0_dp,tight_tolerance,status,expected_rate,residual)
    Call check(error,status,bn_check_invalid)
    If ( allocated(error) ) Return

    Call bn_check_binding_energy_rate(x_initial,x_result,aa,be, &
      & ieee_value(0.0_dp,ieee_quiet_nan),energy_rate,0.0_dp,tight_tolerance,status, &
      & expected_rate,residual)
    Call check(error,status,bn_check_invalid)

    Return
  End Subroutine test_binding_energy_rate

  Subroutine test_eos_result(error)
    Use, Intrinsic :: ieee_arithmetic, Only: ieee_quiet_nan, ieee_value
    Use xnet_surrogate_checks, Only: bn_check_eos_result, bn_check_failed, &
      & bn_check_invalid, bn_check_passed
    Implicit None
    Type(error_type), Allocatable, Intent(out) :: error

    Integer :: bad_finite_index, bad_positive_index, status
    Real(dp) :: empty(0), finite_values(3), positive_values(3)

    finite_values = (/ -2.0_dp, 0.0_dp, 3.0_dp /)
    positive_values = (/ 1.0_dp, 2.0_dp, 3.0_dp /)
    Call bn_check_eos_result(finite_values,positive_values,status,bad_finite_index, &
      & bad_positive_index)
    Call check(error,status,bn_check_passed)
    If ( allocated(error) ) Return
    Call check(error,bad_finite_index,0)
    If ( allocated(error) ) Return
    Call check(error,bad_positive_index,0)
    If ( allocated(error) ) Return

    finite_values(2) = ieee_value(finite_values(2),ieee_quiet_nan)
    Call bn_check_eos_result(finite_values,positive_values,status,bad_finite_index, &
      & bad_positive_index)
    Call check(error,status,bn_check_failed)
    If ( allocated(error) ) Return
    Call check(error,bad_finite_index,2)
    If ( allocated(error) ) Return

    finite_values(2) = 0.0_dp
    positive_values(3) = 0.0_dp
    Call bn_check_eos_result(finite_values,positive_values,status,bad_finite_index, &
      & bad_positive_index)
    Call check(error,status,bn_check_failed)
    If ( allocated(error) ) Return
    Call check(error,bad_positive_index,3)
    If ( allocated(error) ) Return

    positive_values(3) = ieee_value(positive_values(3),ieee_quiet_nan)
    Call bn_check_eos_result(finite_values,positive_values,status,bad_finite_index, &
      & bad_positive_index)
    Call check(error,status,bn_check_failed)
    If ( allocated(error) ) Return
    Call check(error,bad_positive_index,3)
    If ( allocated(error) ) Return

    Call bn_check_eos_result(empty,empty,status,bad_finite_index,bad_positive_index)
    Call check(error,status,bn_check_invalid)

    Return
  End Subroutine test_eos_result

  Subroutine test_coordinator_basics(error)
    Use xnet_surrogate_checks, Only: bn_check_failed, bn_check_invalid, bn_check_passed, &
      & bn_check_skipped, bn_check_surrogate_result, bn_surrogate_check_config, &
      & bn_surrogate_check_report
    Implicit None
    Type(error_type), Allocatable, Intent(out) :: error

    Real(dp) :: aa(3), be(3), x_initial(3), x_initial_copy(3), x_result(3), x_result_copy(3), zz(3)
    Type(bn_surrogate_check_config) :: config
    Type(bn_surrogate_check_report) :: report

    aa = (/ 4.0_dp, 12.0_dp, 16.0_dp /)
    zz = (/ 2.0_dp, 6.0_dp, 8.0_dp /)
    be = (/ 28.0_dp, 92.0_dp, 128.0_dp /)
    x_initial = (/ 0.0_dp, 0.50_dp, 0.50_dp /)
    x_result = (/ 0.10_dp, 0.40_dp, 0.50_dp /)
    x_initial_copy = x_initial
    x_result_copy = x_result

    Call bn_check_surrogate_result(config,1,x_initial,x_result,aa,zz,be,1.0_dp,0.0_dp,report)
    Call check(error,report%overall_status,bn_check_skipped)
    If ( allocated(error) ) Return

    config%check_finite = 1
    config%check_fraction_bounds = 1
    config%check_mass_normalization = 1
    config%fraction_tolerance = tight_tolerance
    config%mass_tolerance = tight_tolerance
    Call bn_check_surrogate_result(config,1,x_initial,x_result,aa,zz,be,1.0_dp,0.0_dp,report)
    Call check(error,report%overall_status,bn_check_passed)
    If ( allocated(error) ) Return
    Call check(error,report%finite_status,bn_check_passed)
    If ( allocated(error) ) Return
    Call check(error,report%fraction_bounds_status,bn_check_passed)
    If ( allocated(error) ) Return
    Call check(error,report%mass_normalization_status,bn_check_passed)
    If ( allocated(error) ) Return
    Call check(error,all(x_initial == x_initial_copy),.True.)
    If ( allocated(error) ) Return
    Call check(error,all(x_result == x_result_copy),.True.)
    If ( allocated(error) ) Return

    x_result(1) = -1.0e-3_dp
    Call bn_check_surrogate_result(config,1,x_initial,x_result,aa,zz,be,1.0_dp,0.0_dp,report)
    Call check(error,report%overall_status,bn_check_failed)
    If ( allocated(error) ) Return
    Call check(error,report%fraction_bounds_status,bn_check_failed)
    If ( allocated(error) ) Return

    config%check_finite = 2
    Call bn_check_surrogate_result(config,1,x_initial,x_result,aa,zz,be,1.0_dp,0.0_dp,report)
    Call check(error,report%overall_status,bn_check_invalid)
    If ( allocated(error) ) Return
    Call check(error,report%finite_status,bn_check_invalid)

    Return
  End Subroutine test_coordinator_basics

  Subroutine test_coordinator_optional_data(error)
    Use xnet_constants, Only: avn, epmev
    Use xnet_surrogate_checks, Only: bn_check_invalid, bn_check_passed, bn_check_skipped, &
      & bn_check_surrogate_result, bn_surrogate_check_config, bn_surrogate_check_report
    Implicit None
    Type(error_type), Allocatable, Intent(out) :: error

    Real(dp) :: aa(2), be(2), energy_rate, eos_finite(2), eos_positive(2)
    Real(dp) :: x_initial(2), x_result(2), zz(2)
    Type(bn_surrogate_check_config) :: config
    Type(bn_surrogate_check_report) :: report

    aa = (/ 4.0_dp, 12.0_dp /)
    zz = (/ 2.0_dp, 6.0_dp /)
    be = (/ 28.0_dp, 92.0_dp /)
    x_initial = (/ 0.50_dp, 0.50_dp /)
    x_result = (/ 0.25_dp, 0.75_dp /)
    energy_rate = avn*epmev*sum((x_result-x_initial)*be/aa)
    eos_finite = (/ -1.0_dp, 0.0_dp /)
    eos_positive = (/ 1.0e7_dp, 1.0e17_dp /)
    config%check_fixed_ye = 1
    config%check_inactive_identity = 1
    config%check_binding_energy_rate = 1
    config%check_eos_result = 1
    config%ye_tolerance = tight_tolerance
    config%energy_relative_tolerance = tight_tolerance

    Call bn_check_surrogate_result(config,1,x_initial,x_result,aa,zz,be,1.0_dp, &
      & energy_rate,report,eos_finite,eos_positive)
    Call check(error,report%overall_status,bn_check_passed)
    If ( allocated(error) ) Return
    Call check(error,report%fixed_ye_status,bn_check_passed)
    If ( allocated(error) ) Return
    Call check(error,report%inactive_identity_status,bn_check_skipped)
    If ( allocated(error) ) Return
    Call check(error,report%binding_energy_rate_status,bn_check_passed)
    If ( allocated(error) ) Return
    Call check(error,report%eos_result_status,bn_check_passed)
    If ( allocated(error) ) Return

    Call bn_check_surrogate_result(config,1,x_initial,x_result,aa,zz,be,1.0_dp, &
      & energy_rate,report)
    Call check(error,report%overall_status,bn_check_invalid)
    If ( allocated(error) ) Return
    Call check(error,report%eos_result_status,bn_check_invalid)

    Return
  End Subroutine test_coordinator_optional_data

End Module test_surrogate_checks

Program surrogate_check_test_runner
  Use, Intrinsic :: iso_fortran_env, Only: error_unit
  Use test_surrogate_checks, Only: collect_surrogate_checks
  Use testdrive, Only: new_testsuite, run_testsuite, testsuite_type
  Implicit None

  Type(testsuite_type), Allocatable :: testsuites(:)
  Integer :: stat

  stat = 0
  testsuites = [ new_testsuite('Burn-surrogate checks',collect_surrogate_checks) ]
  Call run_testsuite(testsuites(1)%collect,error_unit,stat,parallel=.False.)
  If ( stat > 0 ) Then
    Write(error_unit,'(i0,1x,a)') stat,'surrogate check test(s) failed'
    Error Stop 1
  EndIf

End Program surrogate_check_test_runner
