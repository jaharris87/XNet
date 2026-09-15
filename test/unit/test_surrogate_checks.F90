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
      & new_unittest('surrogate fraction change',test_fraction_change), &
      & new_unittest('surrogate energy change fraction',test_energy_change_fraction), &
      & new_unittest('surrogate binding energy rate',test_binding_energy_rate), &
      & new_unittest('surrogate EOS result',test_eos_result), &
      & new_unittest('surrogate coordinator basics',test_coordinator_basics), &
      & new_unittest('surrogate positional constructor compatibility', &
      & test_positional_constructor_compatibility), &
      & new_unittest('surrogate legacy coordinator interface', &
      & test_legacy_coordinator_interface), &
      & new_unittest('surrogate coordinator optional data',test_coordinator_optional_data), &
      & new_unittest('surrogate tolerance boundaries',test_tolerance_boundaries), &
      & new_unittest('surrogate explicit tolerance policy',test_explicit_tolerance_policy), &
      & new_unittest('surrogate coordinator selection',test_coordinator_selection), &
      & new_unittest('surrogate reference validation',test_reference_validation), &
      & new_unittest('surrogate finite extreme arithmetic',test_finite_extreme_arithmetic), &
      & new_unittest('surrogate binding and fixed Ye scope',test_binding_fixed_ye_scope) ]

    Return
  End Subroutine collect_surrogate_checks

  Subroutine test_finite_values(error)
    Use, Intrinsic :: ieee_arithmetic, Only: ieee_quiet_nan, ieee_value
    Use xnet_surrogate_checks, Only: check_failed, check_finite_values, &
      & check_invalid, check_passed
    Implicit None
    Type(error_type), Allocatable, Intent(out) :: error

    Integer :: bad_index, status
    Real(dp) :: empty(0), values(3)

    Call check_finite_values(empty,status,bad_index)
    Call check(error,status,check_invalid)
    If ( allocated(error) ) Return

    values = (/ 0.0_dp, 0.25_dp, 0.75_dp /)
    Call check_finite_values(values,status,bad_index)
    Call check(error,status,check_passed)
    If ( allocated(error) ) Return
    Call check(error,bad_index,0)
    If ( allocated(error) ) Return

    values(2) = ieee_value(values(2),ieee_quiet_nan)
    Call check_finite_values(values,status,bad_index)
    Call check(error,status,check_failed)
    If ( allocated(error) ) Return
    Call check(error,bad_index,2)

    Return
  End Subroutine test_finite_values

  Subroutine test_fraction_bounds(error)
    Use, Intrinsic :: ieee_arithmetic, Only: ieee_quiet_nan, ieee_value
    Use xnet_surrogate_checks, Only: check_failed, check_fraction_bounds, &
      & check_invalid, check_passed
    Implicit None
    Type(error_type), Allocatable, Intent(out) :: error

    Integer :: status
    Real(dp) :: maximum_fraction, minimum_fraction, xmass(3)

    xmass = (/ -1.0e-15_dp, 0.25_dp, 0.75_dp /)
    Call check_fraction_bounds(xmass,1.0e-14_dp,status,minimum_fraction,maximum_fraction)
    Call check(error,status,check_passed)
    If ( allocated(error) ) Return
    Call check(error,minimum_fraction,-1.0e-15_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return
    Call check(error,maximum_fraction,0.75_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return

    xmass(1) = -1.0e-4_dp
    Call check_fraction_bounds(xmass,1.0e-14_dp,status,minimum_fraction,maximum_fraction)
    Call check(error,status,check_failed)
    If ( allocated(error) ) Return

    Call check_fraction_bounds(xmass,-1.0_dp,status,minimum_fraction,maximum_fraction)
    Call check(error,status,check_invalid)
    If ( allocated(error) ) Return

    Call check_fraction_bounds(xmass,ieee_value(0.0_dp,ieee_quiet_nan),status, &
      & minimum_fraction,maximum_fraction)
    Call check(error,status,check_invalid)

    Return
  End Subroutine test_fraction_bounds

  Subroutine test_mass_normalization(error)
    Use xnet_surrogate_checks, Only: check_failed, check_invalid, &
      & check_mass_normalization, check_passed
    Implicit None
    Type(error_type), Allocatable, Intent(out) :: error

    Integer :: status
    Real(dp) :: residual, xmass(3)

    xmass = (/ 0.20_dp, 0.30_dp, 0.50_dp /)
    Call check_mass_normalization(xmass,1.0e-14_dp,status,residual)
    Call check(error,status,check_passed)
    If ( allocated(error) ) Return
    Call check(error,residual,0.0_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return

    xmass(3) = 0.49_dp
    Call check_mass_normalization(xmass,1.0e-14_dp,status,residual)
    Call check(error,status,check_failed)
    If ( allocated(error) ) Return
    Call check(error,residual,-1.0e-2_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return

    Call check_mass_normalization(xmass,-1.0_dp,status,residual)
    Call check(error,status,check_invalid)

    Return
  End Subroutine test_mass_normalization

  Subroutine test_electron_fraction(error)
    Use, Intrinsic :: ieee_arithmetic, Only: ieee_quiet_nan, ieee_value
    Use xnet_surrogate_checks, Only: check_electron_fraction, check_failed, &
      & check_invalid, check_passed
    Implicit None
    Type(error_type), Allocatable, Intent(out) :: error

    Integer :: status
    Real(dp) :: aa(3), initial_ye, residual, result_ye, x_initial(3), x_result(3), zz(3)

    aa = (/ 1.0_dp, 1.0_dp, 4.0_dp /)
    zz = (/ 0.0_dp, 1.0_dp, 2.0_dp /)
    x_initial = (/ 0.10_dp, 0.10_dp, 0.80_dp /)
    x_result = (/ 0.0_dp, 0.0_dp, 1.0_dp /)
    Call check_electron_fraction(x_initial,x_result,aa,zz,tight_tolerance,status, &
      & initial_ye,result_ye,residual)
    Call check(error,status,check_passed)
    If ( allocated(error) ) Return
    Call check(error,initial_ye,0.50_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return
    Call check(error,result_ye,0.50_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return
    Call check(error,residual,0.0_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return

    x_result = (/ 0.10_dp, 0.20_dp, 0.70_dp /)
    Call check_electron_fraction(x_initial,x_result,aa,zz,tight_tolerance,status, &
      & initial_ye,result_ye,residual)
    Call check(error,status,check_failed)
    If ( allocated(error) ) Return
    Call check(error,residual,0.05_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return

    aa(1) = 0.0_dp
    Call check_electron_fraction(x_initial,x_result,aa,zz,tight_tolerance,status, &
      & initial_ye,result_ye,residual)
    Call check(error,status,check_invalid)
    If ( allocated(error) ) Return

    aa(1) = ieee_value(aa(1),ieee_quiet_nan)
    Call check_electron_fraction(x_initial,x_result,aa,zz,tight_tolerance,status, &
      & initial_ye,result_ye,residual)
    Call check(error,status,check_invalid)

    Return
  End Subroutine test_electron_fraction

  Subroutine test_inactive_identity(error)
    Use xnet_surrogate_checks, Only: check_failed, check_inactive_identity, &
      & check_invalid, check_passed
    Implicit None
    Type(error_type), Allocatable, Intent(out) :: error

    Integer :: status
    Real(dp) :: energy_residual, fraction_residual, x_initial(3), x_result(3)

    x_initial = (/ 0.20_dp, 0.30_dp, 0.50_dp /)
    x_result = x_initial
    Call check_inactive_identity(x_initial,x_result,0.0_dp,tight_tolerance, &
      & tight_tolerance,status,fraction_residual,energy_residual)
    Call check(error,status,check_passed)
    If ( allocated(error) ) Return
    Call check(error,fraction_residual,0.0_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return
    Call check(error,energy_residual,0.0_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return

    x_result(2) = x_result(2) + 1.0e-4_dp
    Call check_inactive_identity(x_initial,x_result,0.0_dp,tight_tolerance, &
      & tight_tolerance,status,fraction_residual,energy_residual)
    Call check(error,status,check_failed)
    If ( allocated(error) ) Return
    Call check(error,fraction_residual,1.0e-4_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return

    x_result = x_initial
    Call check_inactive_identity(x_initial,x_result,1.0_dp,tight_tolerance, &
      & tight_tolerance,status,fraction_residual,energy_residual)
    Call check(error,status,check_failed)
    If ( allocated(error) ) Return
    Call check(error,energy_residual,1.0_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return

    Call check_inactive_identity(x_initial,x_result,0.0_dp,-1.0_dp, &
      & tight_tolerance,status,fraction_residual,energy_residual)
    Call check(error,status,check_invalid)

    Return
  End Subroutine test_inactive_identity

  Subroutine test_fraction_change(error)
    Use, Intrinsic :: ieee_arithmetic, Only: ieee_negative_inf, ieee_positive_inf, &
      & ieee_quiet_nan, ieee_value
    Use xnet_surrogate_checks, Only: check_failed, check_fraction_change, &
      & check_invalid, check_passed
    Implicit None
    Type(error_type), Allocatable, Intent(out) :: error

    Integer :: maximum_index, status
    Real(dp) :: empty(0), infinity, maximum_change, x_initial(3), x_result(3)

    x_initial = (/ 0.00_dp, 0.50_dp, 0.50_dp /)
    x_result = (/ 0.10_dp, 0.40_dp, 0.50_dp /)
    Call check_fraction_change(x_initial,x_result,0.10_dp,status,maximum_change,maximum_index)
    Call check(error,status,check_passed)
    If ( allocated(error) ) Return
    Call check(error,maximum_change,0.10_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return
    Call check(error,maximum_index,1)
    If ( allocated(error) ) Return

    Call check_fraction_change(x_initial,x_result,nearest(0.10_dp,-1.0_dp),status, &
      & maximum_change,maximum_index)
    Call check(error,status,check_failed)
    If ( allocated(error) ) Return
    Call check_fraction_change(x_initial,x_result,0.20_dp,status,maximum_change,maximum_index)
    Call check(error,status,check_passed)
    If ( allocated(error) ) Return

    x_result(2) = ieee_value(0.0_dp,ieee_quiet_nan)
    Call check_fraction_change(x_initial,x_result,0.20_dp,status,maximum_change,maximum_index)
    Call check(error,status,check_failed)
    If ( allocated(error) ) Return
    Call check(error,maximum_change,huge(maximum_change))
    If ( allocated(error) ) Return
    Call check(error,maximum_index,2)
    If ( allocated(error) ) Return

    x_initial = (/ 0.00_dp, 0.50_dp, 0.50_dp /)
    x_result = x_initial
    infinity = ieee_value(0.0_dp,ieee_positive_inf)
    x_result(2) = infinity
    Call check_fraction_change(x_initial,x_result,0.20_dp,status,maximum_change,maximum_index)
    Call check(error,status,check_failed)
    If ( allocated(error) ) Return
    Call check(error,maximum_change,huge(maximum_change))
    If ( allocated(error) ) Return
    Call check(error,maximum_index,2)
    If ( allocated(error) ) Return

    x_result = x_initial
    x_initial(1) = ieee_value(0.0_dp,ieee_negative_inf)
    Call check_fraction_change(x_initial,x_result,0.20_dp,status,maximum_change,maximum_index)
    Call check(error,status,check_invalid)
    If ( allocated(error) ) Return

    x_initial = (/ 0.00_dp, 0.50_dp, 0.50_dp /)
    Call check_fraction_change(x_initial,x_initial,infinity,status,maximum_change,maximum_index)
    Call check(error,status,check_invalid)
    If ( allocated(error) ) Return

    Call check_fraction_change(x_initial,x_initial(1:2),0.20_dp,status,maximum_change, &
      & maximum_index)
    Call check(error,status,check_invalid)
    If ( allocated(error) ) Return
    Call check_fraction_change(empty,empty,0.20_dp,status,maximum_change,maximum_index)
    Call check(error,status,check_invalid)
    If ( allocated(error) ) Return
    Call check_fraction_change(x_initial,x_initial,-1.0_dp,status,maximum_change,maximum_index)
    Call check(error,status,check_invalid)
    If ( allocated(error) ) Return
    Call check_fraction_change(x_initial,x_initial, &
      & ieee_value(0.0_dp,ieee_quiet_nan),status,maximum_change,maximum_index)
    Call check(error,status,check_invalid)
    If ( allocated(error) ) Return
    x_initial(1) = ieee_value(0.0_dp,ieee_quiet_nan)
    Call check_fraction_change(x_initial,x_result,0.20_dp,status,maximum_change,maximum_index)
    Call check(error,status,check_invalid)

    Return
  End Subroutine test_fraction_change

  Subroutine test_energy_change_fraction(error)
    Use, Intrinsic :: ieee_arithmetic, Only: ieee_negative_inf, ieee_positive_inf, &
      & ieee_quiet_nan, ieee_value
    Use xnet_surrogate_checks, Only: check_energy_change_fraction, check_failed, &
      & check_invalid, check_passed
    Implicit None
    Type(error_type), Allocatable, Intent(out) :: error

    Integer :: status
    Real(dp) :: change_fraction, negative_infinity, positive_infinity

    negative_infinity = ieee_value(0.0_dp,ieee_negative_inf)
    positive_infinity = ieee_value(0.0_dp,ieee_positive_inf)

    Call check_energy_change_fraction(2.0_dp,0.5_dp,10.0_dp,0.10_dp,status, &
      & change_fraction)
    Call check(error,status,check_passed)
    If ( allocated(error) ) Return
    Call check(error,change_fraction,0.10_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return
    Call check_energy_change_fraction(-2.0_dp,0.5_dp,10.0_dp, &
      & nearest(0.10_dp,-1.0_dp),status,change_fraction)
    Call check(error,status,check_failed)
    If ( allocated(error) ) Return
    Call check_energy_change_fraction(2.0_dp,0.5_dp,10.0_dp,0.20_dp,status, &
      & change_fraction)
    Call check(error,status,check_passed)
    If ( allocated(error) ) Return

    Call check_energy_change_fraction(1.0e16_dp,1.0e-8_dp,1.0e10_dp,0.01_dp,status, &
      & change_fraction)
    Call check(error,status,check_passed)
    If ( allocated(error) ) Return
    Call check(error,change_fraction,0.01_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return

    Call check_energy_change_fraction(2.0_dp,0.0_dp,10.0_dp,0.10_dp,status, &
      & change_fraction)
    Call check(error,status,check_invalid)
    If ( allocated(error) ) Return
    Call check_energy_change_fraction(2.0_dp,-0.5_dp,10.0_dp,0.10_dp,status, &
      & change_fraction)
    Call check(error,status,check_invalid)
    If ( allocated(error) ) Return
    Call check_energy_change_fraction(2.0_dp,positive_infinity,10.0_dp,0.10_dp,status, &
      & change_fraction)
    Call check(error,status,check_invalid)
    If ( allocated(error) ) Return
    Call check_energy_change_fraction(2.0_dp,ieee_value(0.0_dp,ieee_quiet_nan), &
      & 10.0_dp,0.10_dp,status,change_fraction)
    Call check(error,status,check_invalid)
    If ( allocated(error) ) Return
    Call check_energy_change_fraction(2.0_dp,0.5_dp,0.0_dp,0.10_dp,status, &
      & change_fraction)
    Call check(error,status,check_invalid)
    If ( allocated(error) ) Return
    Call check_energy_change_fraction(2.0_dp,0.5_dp,-10.0_dp,0.10_dp,status, &
      & change_fraction)
    Call check(error,status,check_invalid)
    If ( allocated(error) ) Return
    Call check_energy_change_fraction(2.0_dp,0.5_dp,negative_infinity,0.10_dp,status, &
      & change_fraction)
    Call check(error,status,check_invalid)
    If ( allocated(error) ) Return
    Call check_energy_change_fraction(2.0_dp,0.5_dp, &
      & ieee_value(0.0_dp,ieee_quiet_nan),0.10_dp,status,change_fraction)
    Call check(error,status,check_invalid)
    If ( allocated(error) ) Return
    Call check_energy_change_fraction(2.0_dp,0.5_dp,10.0_dp,-1.0_dp,status, &
      & change_fraction)
    Call check(error,status,check_invalid)
    If ( allocated(error) ) Return
    Call check_energy_change_fraction(2.0_dp,0.5_dp,10.0_dp, &
      & ieee_value(0.0_dp,ieee_quiet_nan),status,change_fraction)
    Call check(error,status,check_invalid)
    If ( allocated(error) ) Return
    Call check_energy_change_fraction(2.0_dp,0.5_dp,10.0_dp,positive_infinity,status, &
      & change_fraction)
    Call check(error,status,check_invalid)
    If ( allocated(error) ) Return
    Call check_energy_change_fraction(ieee_value(0.0_dp,ieee_quiet_nan),0.5_dp, &
      & 10.0_dp,0.10_dp,status,change_fraction)
    Call check(error,status,check_failed)
    If ( allocated(error) ) Return
    Call check(error,change_fraction,huge(change_fraction))
    If ( allocated(error) ) Return
    Call check_energy_change_fraction(negative_infinity,0.5_dp,10.0_dp,0.10_dp,status, &
      & change_fraction)
    Call check(error,status,check_failed)
    If ( allocated(error) ) Return
    Call check(error,change_fraction,huge(change_fraction))

    Return
  End Subroutine test_energy_change_fraction

  Subroutine test_binding_energy_rate(error)
    Use, Intrinsic :: ieee_arithmetic, Only: ieee_quiet_nan, ieee_value
    Use xnet_constants, Only: avn, epmev
    Use xnet_surrogate_checks, Only: check_binding_energy_rate, check_failed, &
      & check_invalid, check_passed
    Implicit None
    Type(error_type), Allocatable, Intent(out) :: error

    Integer :: status
    Real(dp) :: aa(2), be(2), energy_rate, expected_rate, residual, x_initial(2), x_result(2)

    aa = (/ 1.0_dp, 2.0_dp /)
    be = (/ 0.0_dp, 2.0_dp /)
    x_initial = (/ 1.0_dp, 0.0_dp /)
    x_result = (/ 0.0_dp, 1.0_dp /)
    energy_rate = 0.5_dp*avn*epmev
    Call check_binding_energy_rate(x_initial,x_result,aa,be,2.0_dp,energy_rate, &
      & 0.0_dp,tight_tolerance,status,expected_rate,residual)
    Call check(error,status,check_passed)
    If ( allocated(error) ) Return
    Call check(error,expected_rate,energy_rate,thr=tight_tolerance*abs(energy_rate))
    If ( allocated(error) ) Return
    Call check(error,residual,0.0_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return

    Call check_binding_energy_rate(x_initial,x_result,aa,be,2.0_dp, &
      & energy_rate*(1.0_dp+1.0e-4_dp),0.0_dp,1.0e-6_dp,status,expected_rate,residual)
    Call check(error,status,check_failed)
    If ( allocated(error) ) Return

    Call check_binding_energy_rate(x_initial,x_result,aa,be,0.0_dp,energy_rate, &
      & 0.0_dp,tight_tolerance,status,expected_rate,residual)
    Call check(error,status,check_invalid)
    If ( allocated(error) ) Return

    Call check_binding_energy_rate(x_initial,x_result,aa,be, &
      & ieee_value(0.0_dp,ieee_quiet_nan),energy_rate,0.0_dp,tight_tolerance,status, &
      & expected_rate,residual)
    Call check(error,status,check_invalid)

    Return
  End Subroutine test_binding_energy_rate

  Subroutine test_eos_result(error)
    Use, Intrinsic :: ieee_arithmetic, Only: ieee_quiet_nan, ieee_value
    Use xnet_surrogate_checks, Only: check_eos_result, check_failed, &
      & check_invalid, check_passed
    Implicit None
    Type(error_type), Allocatable, Intent(out) :: error

    Integer :: bad_finite_index, bad_positive_index, status
    Real(dp) :: empty(0), finite_values(3), positive_values(3)

    finite_values = (/ -2.0_dp, 0.0_dp, 3.0_dp /)
    positive_values = (/ 1.0_dp, 2.0_dp, 3.0_dp /)
    Call check_eos_result(finite_values,positive_values,status,bad_finite_index, &
      & bad_positive_index)
    Call check(error,status,check_passed)
    If ( allocated(error) ) Return
    Call check(error,bad_finite_index,0)
    If ( allocated(error) ) Return
    Call check(error,bad_positive_index,0)
    If ( allocated(error) ) Return

    finite_values(2) = ieee_value(finite_values(2),ieee_quiet_nan)
    Call check_eos_result(finite_values,positive_values,status,bad_finite_index, &
      & bad_positive_index)
    Call check(error,status,check_failed)
    If ( allocated(error) ) Return
    Call check(error,bad_finite_index,2)
    If ( allocated(error) ) Return

    finite_values(2) = 0.0_dp
    positive_values(3) = 0.0_dp
    Call check_eos_result(finite_values,positive_values,status,bad_finite_index, &
      & bad_positive_index)
    Call check(error,status,check_failed)
    If ( allocated(error) ) Return
    Call check(error,bad_positive_index,3)
    If ( allocated(error) ) Return

    positive_values(3) = ieee_value(positive_values(3),ieee_quiet_nan)
    Call check_eos_result(finite_values,positive_values,status,bad_finite_index, &
      & bad_positive_index)
    Call check(error,status,check_failed)
    If ( allocated(error) ) Return
    Call check(error,bad_positive_index,3)
    If ( allocated(error) ) Return

    Call check_eos_result(empty,empty,status,bad_finite_index,bad_positive_index)
    Call check(error,status,check_invalid)

    Return
  End Subroutine test_eos_result

  Subroutine test_coordinator_basics(error)
    Use xnet_surrogate_checks, Only: check_failed, check_invalid, check_passed, &
      & check_skipped, check_surrogate_result, check_surrogate_result_with_energy, &
      & surrogate_check_config, surrogate_check_report
    Implicit None
    Type(error_type), Allocatable, Intent(out) :: error

    Real(dp) :: aa(3), be(3), x_initial(3), x_initial_copy(3), x_result(3), x_result_copy(3), zz(3)
    Type(surrogate_check_config) :: config
    Type(surrogate_check_report) :: report

    aa = (/ 4.0_dp, 12.0_dp, 16.0_dp /)
    zz = (/ 2.0_dp, 6.0_dp, 8.0_dp /)
    be = (/ 28.0_dp, 92.0_dp, 128.0_dp /)
    x_initial = (/ 0.0_dp, 0.50_dp, 0.50_dp /)
    x_result = (/ 0.10_dp, 0.40_dp, 0.50_dp /)
    x_initial_copy = x_initial
    x_result_copy = x_result

    Call check_surrogate_result(config,1,x_initial,x_result,aa,zz,be,1.0_dp,0.0_dp,report)
    Call check(error,report%overall_status,check_skipped)
    If ( allocated(error) ) Return

    config%check_finite = 1
    config%check_fraction_bounds = 1
    config%check_mass_normalization = 1
    config%check_fraction_change = 1
    config%check_energy_change_fraction = 1
    config%fraction_tolerance = tight_tolerance
    config%mass_tolerance = tight_tolerance
    config%fraction_change_limit = 0.10_dp
    config%energy_change_fraction_limit = 0.0_dp
    Call check_surrogate_result_with_energy(config,1,x_initial,x_result,aa,zz,be,1.0_dp, &
      & 0.0_dp,report,1.0_dp)
    Call check(error,report%overall_status,check_passed)
    If ( allocated(error) ) Return
    Call check(error,report%finite_status,check_passed)
    If ( allocated(error) ) Return
    Call check(error,report%fraction_bounds_status,check_passed)
    If ( allocated(error) ) Return
    Call check(error,report%mass_normalization_status,check_passed)
    If ( allocated(error) ) Return
    Call check(error,report%fraction_change_status,check_passed)
    If ( allocated(error) ) Return
    Call check(error,report%energy_change_fraction_status,check_passed)
    If ( allocated(error) ) Return
    Call check(error,report%maximum_fraction_change,0.10_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return
    Call check(error,report%maximum_fraction_change_index,1)
    If ( allocated(error) ) Return
    Call check(error,all(x_initial == x_initial_copy),.True.)
    If ( allocated(error) ) Return
    Call check(error,all(x_result == x_result_copy),.True.)
    If ( allocated(error) ) Return

    x_result(1) = -1.0e-3_dp
    Call check_surrogate_result_with_energy(config,1,x_initial,x_result,aa,zz,be,1.0_dp, &
      & 0.0_dp,report,1.0_dp)
    Call check(error,report%overall_status,check_failed)
    If ( allocated(error) ) Return
    Call check(error,report%fraction_bounds_status,check_failed)
    If ( allocated(error) ) Return

    config%check_finite = 2
    Call check_surrogate_result_with_energy(config,1,x_initial,x_result,aa,zz,be,1.0_dp, &
      & 0.0_dp,report,1.0_dp)
    Call check(error,report%overall_status,check_invalid)
    If ( allocated(error) ) Return
    Call check(error,report%finite_status,check_invalid)

    Return
  End Subroutine test_coordinator_basics

  Subroutine test_positional_constructor_compatibility(error)
    Use xnet_surrogate_checks, Only: check_skipped, surrogate_check_config, &
      & surrogate_check_report
    Implicit None
    Type(error_type), Allocatable, Intent(out) :: error

    Integer :: config_flags(7), report_indices(3), report_statuses(8)
    Real(dp) :: config_tolerances(7), report_diagnostics(10)
    Type(surrogate_check_config) :: config
    Type(surrogate_check_report) :: report

    ! These are the complete positional constructors supported before the new step checks were
    ! appended. Distinct values make any component insertion or reordering visible.
    config = surrogate_check_config(11,12,13,14,15,16,17, &
      & 0.11_dp,0.12_dp,0.13_dp,0.14_dp,0.15_dp,0.16_dp,0.17_dp)
    config_flags = (/ config%check_finite, config%check_fraction_bounds, &
      & config%check_mass_normalization,config%check_fixed_ye, &
      & config%check_inactive_identity,config%check_binding_energy_rate, &
      & config%check_eos_result /)
    Call check(error,all(config_flags == (/ 11,12,13,14,15,16,17 /)),.True.)
    If ( allocated(error) ) Return
    config_tolerances = (/ config%fraction_tolerance,config%mass_tolerance, &
      & config%ye_tolerance,config%inactive_fraction_tolerance, &
      & config%inactive_energy_tolerance,config%energy_absolute_tolerance, &
      & config%energy_relative_tolerance /)
    Call check(error,maxval(abs(config_tolerances - &
      & (/ 0.11_dp,0.12_dp,0.13_dp,0.14_dp,0.15_dp,0.16_dp,0.17_dp /))), &
      & 0.0_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return
    Call check(error,config%check_fraction_change,0)
    If ( allocated(error) ) Return
    Call check(error,config%check_energy_change_fraction,0)
    If ( allocated(error) ) Return
    Call check(error,config%fraction_change_limit,-1.0_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return
    Call check(error,config%energy_change_fraction_limit,-1.0_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return

    report = surrogate_check_report(11,12,13,14,15,16,17,18,21,22,23, &
      & 0.31_dp,0.32_dp,0.33_dp,0.34_dp,0.35_dp,0.36_dp,0.37_dp,0.38_dp, &
      & 0.39_dp,0.40_dp)
    report_statuses = (/ report%overall_status,report%finite_status, &
      & report%fraction_bounds_status,report%mass_normalization_status, &
      & report%fixed_ye_status,report%inactive_identity_status, &
      & report%binding_energy_rate_status,report%eos_result_status /)
    Call check(error,all(report_statuses == (/ 11,12,13,14,15,16,17,18 /)),.True.)
    If ( allocated(error) ) Return
    report_indices = (/ report%finite_bad_index,report%eos_bad_finite_index, &
      & report%eos_bad_positive_index /)
    Call check(error,all(report_indices == (/ 21,22,23 /)),.True.)
    If ( allocated(error) ) Return
    report_diagnostics = (/ report%minimum_fraction,report%maximum_fraction, &
      & report%mass_residual,report%initial_ye,report%result_ye,report%ye_residual, &
      & report%inactive_fraction_residual,report%inactive_energy_residual, &
      & report%expected_energy_rate,report%energy_rate_residual /)
    Call check(error,maxval(abs(report_diagnostics - &
      & (/ 0.31_dp,0.32_dp,0.33_dp,0.34_dp,0.35_dp,0.36_dp,0.37_dp,0.38_dp, &
      & 0.39_dp,0.40_dp /))),0.0_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return
    Call check(error,report%fraction_change_status,check_skipped)
    If ( allocated(error) ) Return
    Call check(error,report%energy_change_fraction_status,check_skipped)
    If ( allocated(error) ) Return
    Call check(error,report%maximum_fraction_change_index,0)
    If ( allocated(error) ) Return
    Call check(error,report%maximum_fraction_change,0.0_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return
    Call check(error,report%energy_change_fraction,0.0_dp,thr=tight_tolerance)

    Return
  End Subroutine test_positional_constructor_compatibility

  Subroutine test_legacy_coordinator_interface(error)
    Use xnet_surrogate_checks, Only: check_skipped, check_surrogate_result, &
      & surrogate_check_config, surrogate_check_report
    Implicit None

    Abstract Interface
      Subroutine legacy_coordinator(config,active,x_initial,x_result,aa,zz,binding_energy, &
        & tstep,energy_rate,report,eos_finite_values,eos_positive_values)
        Import :: surrogate_check_config, surrogate_check_report, dp
        Type(surrogate_check_config), Intent(in) :: config
        Integer, Intent(in) :: active
        Real(dp), Intent(in) :: x_initial(:), x_result(:), aa(:), zz(:), binding_energy(:)
        Real(dp), Intent(in) :: tstep, energy_rate
        Type(surrogate_check_report), Intent(out) :: report
        Real(dp), Optional, Intent(in) :: eos_finite_values(:), eos_positive_values(:)
      End Subroutine legacy_coordinator
    End Interface

    Type(error_type), Allocatable, Intent(out) :: error
    Procedure(legacy_coordinator), Pointer :: coordinator
    Real(dp) :: aa(1), be(1), xmass(1), zz(1)
    Type(surrogate_check_config) :: config
    Type(surrogate_check_report) :: report

    aa = 1.0_dp
    be = 0.0_dp
    xmass = 1.0_dp
    zz = 0.0_dp
    coordinator => check_surrogate_result
    Call check(error,associated(coordinator),.True.)
    If ( allocated(error) ) Return
    Call coordinator(config,1,xmass,xmass,aa,zz,be,1.0_dp,0.0_dp,report)
    Call check(error,report%overall_status,check_skipped)

    Return
  End Subroutine test_legacy_coordinator_interface

  Subroutine test_coordinator_optional_data(error)
    Use xnet_constants, Only: avn, epmev
    Use xnet_surrogate_checks, Only: check_invalid, check_passed, check_skipped, &
      & check_surrogate_result, check_surrogate_result_with_energy, &
      & surrogate_check_config, surrogate_check_report
    Implicit None
    Type(error_type), Allocatable, Intent(out) :: error

    Real(dp) :: aa(2), be(2), energy_rate, eos_finite(2), eos_positive(2)
    Real(dp) :: x_initial(2), x_result(2), zz(2)
    Type(surrogate_check_config) :: config
    Type(surrogate_check_report) :: report

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
    config%check_energy_change_fraction = 1
    config%ye_tolerance = tight_tolerance
    config%inactive_fraction_tolerance = 0.0_dp
    config%inactive_energy_tolerance = 0.0_dp
    config%energy_absolute_tolerance = 0.0_dp
    config%energy_relative_tolerance = tight_tolerance
    config%energy_change_fraction_limit = 0.10_dp

    Call check_surrogate_result_with_energy(config,1,x_initial,x_result,aa,zz,be,1.0_dp, &
      & energy_rate,report,10.0_dp*abs(energy_rate),eos_finite,eos_positive)
    Call check(error,report%overall_status,check_passed)
    If ( allocated(error) ) Return
    Call check(error,report%fixed_ye_status,check_passed)
    If ( allocated(error) ) Return
    Call check(error,report%inactive_identity_status,check_skipped)
    If ( allocated(error) ) Return
    Call check(error,report%binding_energy_rate_status,check_passed)
    If ( allocated(error) ) Return
    Call check(error,report%eos_result_status,check_passed)
    If ( allocated(error) ) Return
    Call check(error,report%energy_change_fraction_status,check_passed)
    If ( allocated(error) ) Return
    Call check(error,report%energy_change_fraction,0.10_dp,thr=tight_tolerance)
    If ( allocated(error) ) Return

    Call check_surrogate_result(config,1,x_initial,x_result,aa,zz,be,1.0_dp, &
      & energy_rate,report,eos_finite,eos_positive)
    Call check(error,report%overall_status,check_invalid)
    If ( allocated(error) ) Return
    Call check(error,report%eos_result_status,check_passed)
    If ( allocated(error) ) Return
    Call check(error,report%energy_change_fraction_status,check_invalid)
    If ( allocated(error) ) Return

    Call check_surrogate_result_with_energy(config,1,x_initial,x_result,aa,zz,be,1.0_dp, &
      & energy_rate,report,10.0_dp*abs(energy_rate))
    Call check(error,report%overall_status,check_invalid)
    If ( allocated(error) ) Return
    Call check(error,report%eos_result_status,check_invalid)
    If ( allocated(error) ) Return
    Call check(error,report%energy_change_fraction_status,check_passed)

    Return
  End Subroutine test_coordinator_optional_data

  Subroutine test_tolerance_boundaries(error)
    Use xnet_constants, Only: avn, epmev
    Use xnet_surrogate_checks, Only: check_binding_energy_rate, &
      & check_electron_fraction, check_failed, check_fraction_bounds, &
      & check_inactive_identity, check_mass_normalization, check_passed
    Implicit None
    Type(error_type), Allocatable, Intent(out) :: error

    Integer :: status
    Real(dp) :: aa(2), be(2), energy_residual, expected_rate, fraction_residual
    Real(dp) :: initial_ye, maximum_fraction, minimum_fraction, residual, result_ye
    Real(dp) :: x_initial(2), x_result(2), zz(2)

    x_result = (/ -1.0e-2_dp, 0.5_dp /)
    Call check_fraction_bounds(x_result,1.1e-2_dp,status,minimum_fraction,maximum_fraction)
    Call check(error,status,check_passed)
    If ( allocated(error) ) Return
    Call check_fraction_bounds(x_result,9.0e-3_dp,status,minimum_fraction,maximum_fraction)
    Call check(error,status,check_failed)
    If ( allocated(error) ) Return

    x_result = (/ 0.50_dp, 0.51_dp /)
    Call check_mass_normalization(x_result,1.1e-2_dp,status,residual)
    Call check(error,status,check_passed)
    If ( allocated(error) ) Return
    Call check_mass_normalization(x_result,9.0e-3_dp,status,residual)
    Call check(error,status,check_failed)
    If ( allocated(error) ) Return

    aa = 1.0_dp
    zz = (/ 0.0_dp, 1.0_dp /)
    x_initial = (/ 0.50_dp, 0.50_dp /)
    x_result = (/ 0.45_dp, 0.55_dp /)
    Call check_electron_fraction(x_initial,x_result,aa,zz,5.1e-2_dp,status, &
      & initial_ye,result_ye,residual)
    Call check(error,status,check_passed)
    If ( allocated(error) ) Return
    Call check_electron_fraction(x_initial,x_result,aa,zz,4.9e-2_dp,status, &
      & initial_ye,result_ye,residual)
    Call check(error,status,check_failed)
    If ( allocated(error) ) Return

    x_result = (/ 0.51_dp, 0.49_dp /)
    Call check_inactive_identity(x_initial,x_result,2.0_dp,1.1e-2_dp,2.1_dp,status, &
      & fraction_residual,energy_residual)
    Call check(error,status,check_passed)
    If ( allocated(error) ) Return
    Call check_inactive_identity(x_initial,x_result,2.0_dp,9.0e-3_dp,2.1_dp,status, &
      & fraction_residual,energy_residual)
    Call check(error,status,check_failed)
    If ( allocated(error) ) Return
    Call check_inactive_identity(x_initial,x_result,2.0_dp,1.1e-2_dp,1.9_dp,status, &
      & fraction_residual,energy_residual)
    Call check(error,status,check_failed)
    If ( allocated(error) ) Return

    be = (/ 0.0_dp, 2.0_dp /)
    x_result = x_initial
    Call check_binding_energy_rate(x_initial,x_result,aa,be,1.0_dp,10.0_dp, &
      & 10.0_dp,0.0_dp,status,expected_rate,residual)
    Call check(error,status,check_passed)
    If ( allocated(error) ) Return
    Call check_binding_energy_rate(x_initial,x_result,aa,be,1.0_dp,10.0_dp, &
      & 9.0_dp,0.0_dp,status,expected_rate,residual)
    Call check(error,status,check_failed)
    If ( allocated(error) ) Return

    x_initial = (/ 1.0_dp, 0.0_dp /)
    x_result = (/ 0.0_dp, 1.0_dp /)
    aa = (/ 1.0_dp, 2.0_dp /)
    expected_rate = avn*epmev
    Call check_binding_energy_rate(x_initial,x_result,aa,be,1.0_dp, &
      & 1.1_dp*expected_rate,0.0_dp,9.1e-2_dp,status,energy_residual,residual)
    Call check(error,status,check_passed)
    If ( allocated(error) ) Return
    Call check_binding_energy_rate(x_initial,x_result,aa,be,1.0_dp, &
      & 1.1_dp*expected_rate,0.0_dp,9.0e-2_dp,status,energy_residual,residual)
    Call check(error,status,check_failed)

    Return
  End Subroutine test_tolerance_boundaries

  Subroutine test_explicit_tolerance_policy(error)
    Use xnet_surrogate_checks, Only: check_invalid, check_passed, &
      & check_surrogate_result, check_surrogate_result_with_energy, &
      & surrogate_check_config, surrogate_check_report
    Implicit None
    Type(error_type), Allocatable, Intent(out) :: error

    Integer :: check_index
    Real(dp) :: aa(2), be(2), xmass(2), zz(2)
    Type(surrogate_check_config) :: config
    Type(surrogate_check_report) :: report

    aa = (/ 1.0_dp, 4.0_dp /)
    zz = (/ 0.0_dp, 2.0_dp /)
    be = (/ 0.0_dp, 28.0_dp /)
    xmass = (/ 0.0_dp, 1.0_dp /)

    Do check_index = 2, 6
      config = surrogate_check_config()
      Call set_check_flag(config,check_index,1)
      Call check_surrogate_result(config,0,xmass,xmass,aa,zz,be,1.0_dp,0.0_dp,report)
      Call check(error,report%overall_status,check_invalid)
      If ( allocated(error) ) Return

      Select Case (check_index)
      Case (2)
        config%fraction_tolerance = 0.0_dp
      Case (3)
        config%mass_tolerance = 0.0_dp
      Case (4)
        config%ye_tolerance = 0.0_dp
      Case (5)
        config%inactive_fraction_tolerance = 0.0_dp
        Call check_surrogate_result(config,0,xmass,xmass,aa,zz,be,1.0_dp,0.0_dp,report)
        Call check(error,report%overall_status,check_invalid)
        If ( allocated(error) ) Return
        config = surrogate_check_config()
        config%check_inactive_identity = 1
        config%inactive_energy_tolerance = 0.0_dp
        Call check_surrogate_result(config,0,xmass,xmass,aa,zz,be,1.0_dp,0.0_dp,report)
        Call check(error,report%overall_status,check_invalid)
        If ( allocated(error) ) Return
        config%inactive_fraction_tolerance = 0.0_dp
      Case (6)
        config%energy_absolute_tolerance = 0.0_dp
        Call check_surrogate_result(config,0,xmass,xmass,aa,zz,be,1.0_dp,0.0_dp,report)
        Call check(error,report%overall_status,check_invalid)
        If ( allocated(error) ) Return
        config = surrogate_check_config()
        config%check_binding_energy_rate = 1
        config%energy_relative_tolerance = 0.0_dp
        Call check_surrogate_result(config,0,xmass,xmass,aa,zz,be,1.0_dp,0.0_dp,report)
        Call check(error,report%overall_status,check_invalid)
        If ( allocated(error) ) Return
        config%energy_absolute_tolerance = 0.0_dp
      End Select
      Call check_surrogate_result(config,0,xmass,xmass,aa,zz,be,1.0_dp,0.0_dp,report)
      Call check(error,report%overall_status,check_passed)
      If ( allocated(error) ) Return
    EndDo

    config = surrogate_check_config()
    config%check_fraction_change = 1
    Call check_surrogate_result(config,1,xmass,xmass,aa,zz,be,1.0_dp,0.0_dp,report)
    Call check(error,report%overall_status,check_invalid)
    If ( allocated(error) ) Return
    config%fraction_change_limit = 0.0_dp
    Call check_surrogate_result(config,1,xmass,xmass,aa,zz,be,1.0_dp,0.0_dp,report)
    Call check(error,report%overall_status,check_passed)
    If ( allocated(error) ) Return

    config = surrogate_check_config()
    config%check_energy_change_fraction = 1
    Call check_surrogate_result_with_energy(config,1,xmass,xmass,aa,zz,be,1.0_dp, &
      & 0.0_dp,report,1.0_dp)
    Call check(error,report%overall_status,check_invalid)
    If ( allocated(error) ) Return
    config%energy_change_fraction_limit = 0.0_dp
    Call check_surrogate_result_with_energy(config,1,xmass,xmass,aa,zz,be,1.0_dp, &
      & 0.0_dp,report,1.0_dp)
    Call check(error,report%overall_status,check_passed)

    Return
  End Subroutine test_explicit_tolerance_policy

  Subroutine test_coordinator_selection(error)
    Use, Intrinsic :: ieee_arithmetic, Only: ieee_quiet_nan, ieee_value
    Use xnet_surrogate_checks, Only: check_failed, check_invalid, check_passed, &
      & check_skipped, check_surrogate_result_with_energy, &
      & surrogate_check_config, surrogate_check_report
    Implicit None
    Type(error_type), Allocatable, Intent(out) :: error

    Integer :: check_index, invalid_index, other_index, statuses(9)
    Integer, Parameter :: invalid_values(2) = (/ -1, 2 /)
    Real(dp) :: aa(2), be(2), eos_finite(1), eos_positive(1), x_initial(2), x_result(2), zz(2)
    Type(surrogate_check_config) :: config
    Type(surrogate_check_report) :: report

    aa = (/ 1.0_dp, 4.0_dp /)
    zz = (/ 0.0_dp, 2.0_dp /)
    be = (/ 0.0_dp, 28.0_dp /)
    eos_finite = 0.0_dp

    Do check_index = 1, 9
      config = surrogate_check_config()
      Call set_check_flag(config,check_index,1)
      x_initial = (/ 0.0_dp, 1.0_dp /)
      x_result = x_initial
      eos_positive = 1.0_dp
      Select Case (check_index)
      Case (1)
        x_result(1) = ieee_value(0.0_dp,ieee_quiet_nan)
      Case (2)
        config%fraction_tolerance = 0.0_dp
        x_result = (/ -0.1_dp, 1.1_dp /)
      Case (3)
        config%mass_tolerance = 0.0_dp
        x_result(2) = 0.9_dp
      Case (4)
        config%ye_tolerance = 0.0_dp
        x_result = (/ 0.1_dp, 0.9_dp /)
      Case (5)
        config%inactive_fraction_tolerance = 0.0_dp
        config%inactive_energy_tolerance = 0.0_dp
        x_result = (/ 0.1_dp, 0.9_dp /)
      Case (6)
        config%energy_absolute_tolerance = 0.0_dp
        config%energy_relative_tolerance = 0.0_dp
      Case (7)
        eos_positive = 0.0_dp
      Case (8)
        config%fraction_change_limit = 0.0_dp
        x_result = (/ 0.1_dp, 0.9_dp /)
      Case (9)
        config%energy_change_fraction_limit = 0.0_dp
      End Select
      Call check_surrogate_result_with_energy(config,0,x_initial,x_result,aa,zz,be, &
        & 1.0_dp,1.0_dp,report,1.0_dp,eos_finite,eos_positive)
      statuses = report_statuses(report)
      Call check(error,statuses(check_index),check_failed)
      If ( allocated(error) ) Return
      Call check(error,report%overall_status,check_failed)
      If ( allocated(error) ) Return
      Do other_index = 1, 9
        If ( other_index == check_index ) Cycle
        Call check(error,statuses(other_index),check_skipped)
        If ( allocated(error) ) Return
      EndDo
    EndDo

    Do invalid_index = 1, size(invalid_values)
      Do check_index = 1, 9
        config = surrogate_check_config()
        Call set_check_flag(config,check_index,invalid_values(invalid_index))
        x_initial = (/ 0.0_dp, 1.0_dp /)
        Call check_surrogate_result_with_energy(config,1,x_initial,x_initial,aa,zz,be, &
          & 1.0_dp,0.0_dp,report,1.0_dp,eos_finite,(/ 1.0_dp /))
        statuses = report_statuses(report)
        Call check(error,statuses(check_index),check_invalid)
        If ( allocated(error) ) Return
        Call check(error,report%overall_status,check_invalid)
        If ( allocated(error) ) Return
        Do other_index = 1, 9
          If ( other_index == check_index ) Cycle
          Call check(error,statuses(other_index),check_skipped)
          If ( allocated(error) ) Return
        EndDo
      EndDo
    EndDo

    ! Exercise aggregate precedence when both new checks run but only one rejects the candidate.
    config = surrogate_check_config()
    config%check_fraction_change = 1
    config%check_energy_change_fraction = 1
    config%fraction_change_limit = 0.0_dp
    config%energy_change_fraction_limit = 1.0_dp
    x_initial = (/ 0.0_dp, 1.0_dp /)
    x_result = (/ 0.1_dp, 0.9_dp /)
    Call check_surrogate_result_with_energy(config,1,x_initial,x_result,aa,zz,be,1.0_dp, &
      & 1.0_dp,report,1.0_dp)
    Call check(error,report%fraction_change_status,check_failed)
    If ( allocated(error) ) Return
    Call check(error,report%energy_change_fraction_status,check_passed)
    If ( allocated(error) ) Return
    Call check(error,report%overall_status,check_failed)
    If ( allocated(error) ) Return

    config%fraction_change_limit = 0.1_dp
    config%energy_change_fraction_limit = 0.0_dp
    Call check_surrogate_result_with_energy(config,1,x_initial,x_result,aa,zz,be,1.0_dp, &
      & 1.0_dp,report,1.0_dp)
    Call check(error,report%fraction_change_status,check_passed)
    If ( allocated(error) ) Return
    Call check(error,report%energy_change_fraction_status,check_failed)
    If ( allocated(error) ) Return
    Call check(error,report%overall_status,check_failed)

    Return
  End Subroutine test_coordinator_selection

  Subroutine test_reference_validation(error)
    Use, Intrinsic :: ieee_arithmetic, Only: ieee_quiet_nan, ieee_value
    Use xnet_surrogate_checks, Only: check_binding_energy_rate, &
      & check_electron_fraction, check_energy_change_fraction, check_fraction_change, &
      & check_inactive_identity, check_invalid, check_surrogate_result, &
      & check_surrogate_result_with_energy, surrogate_check_config, &
      & surrogate_check_report
    Implicit None
    Type(error_type), Allocatable, Intent(out) :: error

    Integer :: maximum_index, status
    Real(dp) :: aa(2), be(2), change_fraction, energy_residual, expected_rate, fraction_residual
    Real(dp) :: initial_ye, maximum_change, residual, result_ye, x_initial(2), x_result(2), zz(2)
    Type(surrogate_check_config) :: config
    Type(surrogate_check_report) :: report

    aa = (/ 1.0_dp, 4.0_dp /)
    zz = (/ 0.0_dp, 2.0_dp /)
    be = (/ 0.0_dp, 28.0_dp /)
    x_initial = (/ 0.0_dp, 1.0_dp /)
    x_result = x_initial
    x_initial(1) = ieee_value(0.0_dp,ieee_quiet_nan)

    Call check_electron_fraction(x_initial,x_result,aa,zz,0.0_dp,status, &
      & initial_ye,result_ye,residual)
    Call check(error,status,check_invalid)
    If ( allocated(error) ) Return
    Call check_inactive_identity(x_initial,x_result,0.0_dp,0.0_dp,0.0_dp,status, &
      & fraction_residual,energy_residual)
    Call check(error,status,check_invalid)
    If ( allocated(error) ) Return
    Call check_binding_energy_rate(x_initial,x_result,aa,be,1.0_dp,0.0_dp, &
      & 0.0_dp,0.0_dp,status,expected_rate,residual)
    Call check(error,status,check_invalid)
    If ( allocated(error) ) Return
    Call check_fraction_change(x_initial,x_result,0.0_dp,status,maximum_change,maximum_index)
    Call check(error,status,check_invalid)
    If ( allocated(error) ) Return
    Call check_energy_change_fraction(0.0_dp,1.0_dp,0.0_dp,0.0_dp,status,change_fraction)
    Call check(error,status,check_invalid)
    If ( allocated(error) ) Return

    config%check_fixed_ye = 1
    config%check_inactive_identity = 1
    config%check_binding_energy_rate = 1
    config%ye_tolerance = 0.0_dp
    config%inactive_fraction_tolerance = 0.0_dp
    config%inactive_energy_tolerance = 0.0_dp
    config%energy_absolute_tolerance = 0.0_dp
    config%energy_relative_tolerance = 0.0_dp
    Call check_surrogate_result(config,0,x_initial,x_result,aa,zz,be,1.0_dp,0.0_dp,report)
    Call check(error,report%overall_status,check_invalid)
    If ( allocated(error) ) Return
    Call check(error,report%fixed_ye_status,check_invalid)
    If ( allocated(error) ) Return
    Call check(error,report%inactive_identity_status,check_invalid)
    If ( allocated(error) ) Return
    Call check(error,report%binding_energy_rate_status,check_invalid)
    If ( allocated(error) ) Return

    config = surrogate_check_config()
    config%check_energy_change_fraction = 1
    config%energy_change_fraction_limit = 0.0_dp
    x_initial = x_result
    Call check_surrogate_result(config,1,x_initial,x_result,aa,zz,be,1.0_dp,0.0_dp,report)
    Call check(error,report%energy_change_fraction_status,check_invalid)
    If ( allocated(error) ) Return
    Call check_surrogate_result_with_energy(config,1,x_initial,x_result,aa,zz,be, &
      & -1.0_dp,0.0_dp,report,1.0_dp)
    Call check(error,report%energy_change_fraction_status,check_invalid)
    If ( allocated(error) ) Return
    Call check_surrogate_result_with_energy(config,1,x_initial,x_result,aa,zz,be, &
      & 1.0_dp,0.0_dp,report,-1.0_dp)
    Call check(error,report%energy_change_fraction_status,check_invalid)
    If ( allocated(error) ) Return

    x_initial = x_result
    zz = (/ -1.0_dp, 2.0_dp /)
    Call check_electron_fraction(x_initial,x_result,aa,zz,0.0_dp,status, &
      & initial_ye,result_ye,residual)
    Call check(error,status,check_invalid)
    If ( allocated(error) ) Return
    zz = (/ 2.0_dp, 2.0_dp /)
    Call check_electron_fraction(x_initial,x_result,aa,zz,0.0_dp,status, &
      & initial_ye,result_ye,residual)
    Call check(error,status,check_invalid)
    If ( allocated(error) ) Return
    aa = (/ 2.0_dp, 6.0_dp /)
    zz = (/ 4.0_dp, 12.0_dp /)
    Call check_electron_fraction(x_initial,x_result,aa,zz,0.0_dp,status, &
      & initial_ye,result_ye,residual)
    Call check(error,status,check_invalid)

    Return
  End Subroutine test_reference_validation

  Subroutine test_finite_extreme_arithmetic(error)
    Use xnet_constants, Only: avn, epmev
    Use xnet_surrogate_checks, Only: check_binding_energy_rate, &
      & check_electron_fraction, check_energy_change_fraction, check_failed, &
      & check_fraction_change, check_inactive_identity, check_invalid, &
      & check_mass_normalization, check_passed, check_surrogate_result, &
      & check_surrogate_result_with_energy, surrogate_check_config, &
      & surrogate_check_report
    Implicit None
    Type(error_type), Allocatable, Intent(out) :: error

    Integer :: maximum_index, status
    Real(dp) :: aa(2), be(2), change_fraction, energy_residual, expected_rate, fraction_residual
    Real(dp) :: large, maximum_change
    Real(dp) :: initial_ye, residual, result_ye, x_initial(2), x_result(2), zz(2)
    Type(surrogate_check_config) :: config
    Type(surrogate_check_report) :: report

    large = huge(0.0_dp)
    aa = 1.0_dp
    zz = 1.0_dp
    be = 1.0_dp
    x_result = large
    Call check_mass_normalization(x_result,0.0_dp,status,residual)
    Call check(error,status,check_failed)
    If ( allocated(error) ) Return
    Call check_mass_normalization((/ -large /),0.0_dp,status,residual)
    Call check(error,status,check_failed)
    If ( allocated(error) ) Return

    x_initial = 0.5_dp
    Call check_electron_fraction(x_initial,x_result,aa,zz,0.0_dp,status, &
      & initial_ye,result_ye,residual)
    Call check(error,status,check_failed)
    If ( allocated(error) ) Return

    x_initial = (/ -large, 0.0_dp /)
    x_result = (/ large, 0.0_dp /)
    Call check_inactive_identity(x_initial,x_result,0.0_dp,large,0.0_dp,status, &
      & fraction_residual,energy_residual)
    Call check(error,status,check_failed)
    If ( allocated(error) ) Return
    Call check_fraction_change(x_initial,x_result,large,status,maximum_change,maximum_index)
    Call check(error,status,check_failed)
    If ( allocated(error) ) Return
    Call check(error,maximum_change,large)
    If ( allocated(error) ) Return
    Call check(error,maximum_index,1)
    If ( allocated(error) ) Return

    Call check_energy_change_fraction(large,2.0_dp,1.0_dp,large,status,change_fraction)
    Call check(error,status,check_failed)
    If ( allocated(error) ) Return
    Call check(error,change_fraction,large)
    If ( allocated(error) ) Return
    Call check_energy_change_fraction(large,1.0_dp,0.5_dp,large,status, &
      & change_fraction)
    Call check(error,status,check_failed)
    If ( allocated(error) ) Return

    Call check_energy_change_fraction(tiny(0.0_dp),tiny(0.0_dp),1.0_dp,0.0_dp, &
      & status,change_fraction)
    Call check(error,status,check_failed)
    If ( allocated(error) ) Return
    Call check(error,change_fraction,large)
    If ( allocated(error) ) Return
    ! Would-be subnormal diagnostics are conservatively rejected before arithmetic so an
    ! underflow-trapping caller still receives a report instead of a process signal.
    Call check_energy_change_fraction(tiny(0.0_dp),0.5_dp,1.0_dp,0.0_dp,status, &
      & change_fraction)
    Call check(error,status,check_failed)
    If ( allocated(error) ) Return
    Call check(error,change_fraction,large)
    If ( allocated(error) ) Return
    Call check_energy_change_fraction(tiny(0.0_dp),1.0_dp,large,0.0_dp,status, &
      & change_fraction)
    Call check(error,status,check_failed)
    If ( allocated(error) ) Return
    Call check(error,change_fraction,large)
    If ( allocated(error) ) Return
    Call check_energy_change_fraction(tiny(0.0_dp),1.0_dp,2.0_dp,0.0_dp,status, &
      & change_fraction)
    Call check(error,status,check_failed)
    If ( allocated(error) ) Return
    Call check(error,change_fraction,large)
    If ( allocated(error) ) Return

    config = surrogate_check_config()
    config%check_energy_change_fraction = 1
    config%energy_change_fraction_limit = 0.0_dp
    x_initial = (/ 0.5_dp, 0.5_dp /)
    x_result = x_initial
    Call check_surrogate_result_with_energy(config,1,x_initial,x_result,aa,zz,be, &
      & tiny(0.0_dp),tiny(0.0_dp),report,1.0_dp)
    Call check(error,report%energy_change_fraction_status,check_failed)
    If ( allocated(error) ) Return
    Call check(error,report%energy_change_fraction,large)
    If ( allocated(error) ) Return

    x_initial = 0.0_dp
    x_result = large
    Call check_binding_energy_rate(x_initial,x_result,aa,be,1.0_dp,0.0_dp, &
      & 0.0_dp,0.0_dp,status,expected_rate,residual)
    Call check(error,status,check_failed)
    If ( allocated(error) ) Return

    x_result = 0.0_dp
    x_result(1) = 0.5_dp*large/(avn*epmev)
    Call check_binding_energy_rate(x_initial,x_result,aa,be,1.0_dp,-large, &
      & 0.0_dp,0.0_dp,status,expected_rate,residual)
    Call check(error,status,check_failed)
    If ( allocated(error) ) Return
    Call check_binding_energy_rate(x_initial,x_initial,aa,be,tiny(0.0_dp),0.0_dp, &
      & 0.0_dp,0.0_dp,status,expected_rate,residual)
    Call check(error,status,check_invalid)
    If ( allocated(error) ) Return

    x_result = x_initial
    Call check_binding_energy_rate(x_initial,x_result,aa,be,1.0_dp,large, &
      & 0.0_dp,large,status,expected_rate,residual)
    Call check(error,status,check_passed)
    If ( allocated(error) ) Return

    config = surrogate_check_config()
    config%check_finite = 1
    config%check_fraction_bounds = 1
    config%check_mass_normalization = 1
    config%fraction_tolerance = 0.0_dp
    config%mass_tolerance = 0.0_dp
    x_result = large
    Call check_surrogate_result(config,1,x_initial,x_result,aa,zz,be,1.0_dp,0.0_dp,report)
    Call check(error,report%overall_status,check_failed)
    If ( allocated(error) ) Return
    Call check(error,report%finite_status,check_passed)
    If ( allocated(error) ) Return
    Call check(error,report%fraction_bounds_status,check_failed)
    If ( allocated(error) ) Return
    Call check(error,report%mass_normalization_status,check_failed)

    Return
  End Subroutine test_finite_extreme_arithmetic

  Subroutine test_binding_fixed_ye_scope(error)
    Use xnet_surrogate_checks, Only: check_binding_energy_rate, check_failed, &
      & check_passed, check_surrogate_result, surrogate_check_config, &
      & surrogate_check_report
    Implicit None
    Type(error_type), Allocatable, Intent(out) :: error

    Integer :: status
    Real(dp) :: aa(2), be(2), expected_rate, residual, x_initial(2), x_result(2), zz(2)
    Type(surrogate_check_config) :: config
    Type(surrogate_check_report) :: report

    aa = 1.0_dp
    zz = (/ 1.0_dp, 0.0_dp /)
    be = 0.0_dp
    x_initial = (/ 1.0_dp, 0.0_dp /)
    x_result = (/ 0.0_dp, 1.0_dp /)
    Call check_binding_energy_rate(x_initial,x_result,aa,be,1.0_dp,0.0_dp, &
      & 0.0_dp,0.0_dp,status,expected_rate,residual)
    Call check(error,status,check_passed)
    If ( allocated(error) ) Return

    config%check_fixed_ye = 1
    config%check_binding_energy_rate = 1
    config%ye_tolerance = 0.0_dp
    config%energy_absolute_tolerance = 0.0_dp
    config%energy_relative_tolerance = 0.0_dp
    Call check_surrogate_result(config,1,x_initial,x_result,aa,zz,be,1.0_dp,0.0_dp,report)
    Call check(error,report%overall_status,check_failed)
    If ( allocated(error) ) Return
    Call check(error,report%fixed_ye_status,check_failed)
    If ( allocated(error) ) Return
    Call check(error,report%binding_energy_rate_status,check_passed)

    Return
  End Subroutine test_binding_fixed_ye_scope

  Subroutine set_check_flag(config,index,value)
    Use xnet_surrogate_checks, Only: surrogate_check_config
    Implicit None
    Type(surrogate_check_config), Intent(inout) :: config
    Integer, Intent(in) :: index, value

    Select Case (index)
    Case (1)
      config%check_finite = value
    Case (2)
      config%check_fraction_bounds = value
    Case (3)
      config%check_mass_normalization = value
    Case (4)
      config%check_fixed_ye = value
    Case (5)
      config%check_inactive_identity = value
    Case (6)
      config%check_binding_energy_rate = value
    Case (7)
      config%check_eos_result = value
    Case (8)
      config%check_fraction_change = value
    Case (9)
      config%check_energy_change_fraction = value
    End Select

    Return
  End Subroutine set_check_flag

  Function report_statuses(report) Result(statuses)
    Use xnet_surrogate_checks, Only: surrogate_check_report
    Implicit None
    Type(surrogate_check_report), Intent(in) :: report
    Integer :: statuses(9)

    statuses = (/ report%finite_status, report%fraction_bounds_status, &
      & report%mass_normalization_status, report%fixed_ye_status, &
      & report%inactive_identity_status, report%binding_energy_rate_status, &
      & report%eos_result_status, report%fraction_change_status, &
      & report%energy_change_fraction_status /)

    Return
  End Function report_statuses

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
