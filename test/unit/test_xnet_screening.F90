Module test_xnet_screening
  Use testdrive, Only: check, error_type, new_unittest, unittest_type
  Use xnet_types, Only: dp
  Implicit None
  Private
  Real(dp), Parameter :: value_tolerance = 128.0_dp*epsilon(1.0_dp)
  Real(dp), Parameter :: derivative_tolerance = 5.0e-9_dp
  Public :: collect_screening_tests
Contains
  Subroutine collect_screening_tests(testsuite)
    Implicit None
    Type(unittest_type), Allocatable, Intent(out) :: testsuite(:)
    testsuite = [ &
      & new_unittest('three-reactant strong value',test_strong), &
      & new_unittest('three-reactant strong temperature derivative',test_derivative), &
      & new_unittest('three-reactant permutation invariance',test_permutations), &
      & new_unittest('three-reactant blend transitions',test_blends) ]
    Return
  End Subroutine collect_screening_tests

  Subroutine strong_pairs(h,dh)
    Use xnet_conditions, Only: t9t
    Use xnet_eos, Only: lambda_at_one, intermediate_moment
    Use xnet_screening, Only: screening, h2, dh2dt9
    Implicit None
    Real(dp), Intent(out) :: h(3), dh(3)

    t9t = 1.0_dp
    lambda_at_one = 10.0_dp
    intermediate_moment = 1.0_dp
    Call screening
    ! Sequential fusion cancels the intermediate Coulomb free energy (issue #171).
    ! These two-body production paths contain no three-reactant expression.
    h = (/ h2(1,1)+h2(2,1), h2(3,1)+h2(4,1), h2(3,1) /)
    dh = (/ dh2dt9(1,1)+dh2dt9(2,1), dh2dt9(3,1)+dh2dt9(4,1), dh2dt9(3,1) /)
    Return
  End Subroutine strong_pairs

  Subroutine test_strong(error)
    Use xnet_screening, Only: h3, dh3dt9
    Implicit None
    Type(error_type), Allocatable, Intent(out) :: error
    Integer, Parameter :: reactions(3) = (/ 1,2,5 /)
    Real(dp) :: h(3), dh(3)
    Integer :: i, mu

    Call strong_pairs(h,dh)
    Do i = 1, size(reactions)
      mu = reactions(i)
      Call check(error,abs(h3(mu,1)-h(i)) <= value_tolerance*max(1.0_dp,abs(h(i))), &
        & 'strong value must equal sequential two-reactant screening')
      If ( allocated(error) ) Return
      Call check(error,abs(dh3dt9(mu,1)-dh(i)) <= value_tolerance*max(1.0_dp,abs(dh(i))), &
        & 'strong derivative must equal sequential two-reactant derivatives')
      If ( allocated(error) ) Return
    EndDo
    Return
  End Subroutine test_strong

  Subroutine test_derivative(error)
    Use xnet_conditions, Only: t9t
    Use xnet_screening, Only: screening, h3, dh3dt9
    Implicit None
    Type(error_type), Allocatable, Intent(out) :: error
    Integer, Parameter :: reactions(3) = (/ 1,2,5 /)
    Real(dp), Parameter :: step = epsilon(1.0_dp)**(1.0_dp/3.0_dp)
    Real(dp) :: h(3), dh(3), returned(3), plus(3), minus(3), difference(3)
    Integer :: i

    Call strong_pairs(h,dh)
    returned = dh3dt9(reactions,1)
    t9t = 1.0_dp+step
    Call screening
    plus = h3(reactions,1)
    t9t = 1.0_dp-step
    Call screening
    minus = h3(reactions,1)
    difference = (plus-minus)/(2.0_dp*step)
    Do i = 1, size(reactions)
      Call check(error,abs(returned(i)-difference(i)) <= derivative_tolerance*max(1.0_dp,abs(returned(i))), &
        & 'strong derivative must agree with temperature finite differences')
      If ( allocated(error) ) Return
    EndDo
    t9t = 1.0_dp
    Return
  End Subroutine test_derivative

  Subroutine test_permutations(error)
    Use xnet_screening, Only: h3, dh3dt9
    Implicit None
    Type(error_type), Allocatable, Intent(out) :: error
    Real(dp) :: h(3), dh(3)
    Integer :: mu

    Call strong_pairs(h,dh)
    ! The middle slot must not select which charged ion contributes to screening.
    Do mu = 3, 4
      Call check(error,abs(h3(mu,1)-h3(2,1)) <= value_tolerance*max(1.0_dp,abs(h3(2,1))), &
        & 'p+alpha+alpha value must be independent of reactant order')
      If ( allocated(error) ) Return
      Call check(error,abs(dh3dt9(mu,1)-dh3dt9(2,1)) <= value_tolerance*max(1.0_dp,abs(dh3dt9(2,1))))
      If ( allocated(error) ) Return
    EndDo
    Call check(error,abs(h3(5,1)-h3(6,1)) <= value_tolerance*max(1.0_dp,abs(h3(5,1))), &
      & 'moving a neutral reactant into the middle slot must preserve the value')
    Return
  End Subroutine test_permutations

  Subroutine test_blends(error)
    Use xnet_constants, Only: bi, kbi
    Use xnet_eos, Only: lambda_at_one, intermediate_moment
    Use xnet_screening, Only: screening, h3, dh3dt9, zeta3w, zeta3i
    Implicit None
    Type(error_type), Allocatable, Intent(out) :: error
    Real(dp), Parameter :: offset = 1.0e-7_dp
    Real(dp), Parameter :: lambdas(14) = (/ 2.0_dp-offset,2.0_dp,2.0_dp+offset,2.075_dp, &
      & 2.15_dp-offset,2.15_dp,2.15_dp+offset,4.85_dp-offset,4.85_dp,4.85_dp+offset, &
      & 4.925_dp,5.0_dp-offset,5.0_dp,5.0_dp+offset /)
    Real(dp), Parameter :: ratios(2) = (/ 0.5_dp,1.5_dp /)
    Integer, Parameter :: reactions(3) = (/ 1,2,5 /)
    Real(dp) :: h(3), dh(3), hi, dhi, weight, expected, expected_derivative, lambda
    Integer :: i, j, k, mu

    Call strong_pairs(h,dh)
    Do i = 1, size(reactions)
      mu = reactions(i)
      Do j = 1, size(ratios)
        hi = ratios(j)*h(i)
        dhi = -1.5_dp*bi*hi
        Do k = 1, size(lambdas)
          lambda = lambdas(k)
          lambda_at_one = lambda/zeta3w(mu)
          intermediate_moment = hi/(kbi*lambda_at_one**bi*zeta3i(mu))
          Call screening
          ! Independently set the strong weight on the two existing transition intervals.
          If ( j == 2 ) Then
            weight = max(0.0_dp,min(1.0_dp,(lambda-2.0_dp)/0.15_dp))
          Else
            weight = max(0.0_dp,min(1.0_dp,(lambda-4.85_dp)/0.15_dp))
          EndIf
          expected = (1.0_dp-weight)*hi+weight*h(i)
          expected_derivative = (1.0_dp-weight)*dhi+weight*dh(i)
          Call check(error,abs(h3(mu,1)-expected) <= value_tolerance*max(1.0_dp,abs(expected)), &
            & 'blend value must use all reactants through both strong transitions')
          If ( allocated(error) ) Return
          ! Preserve the existing weighted branch derivatives; the blend omits d(weight)/dT9.
          Call check(error,abs(dh3dt9(mu,1)-expected_derivative) <= &
            & value_tolerance*max(1.0_dp,abs(expected_derivative)), 'blend derivative routing')
          If ( allocated(error) ) Return
        EndDo
      EndDo
    EndDo
    Return
  End Subroutine test_blends
End Module test_xnet_screening

Program screening_test_runner
  Use, Intrinsic :: iso_fortran_env, Only: error_unit
  Use nuclear_data, Only: izmax, zseq, zseq53, zseqi
  Use xnet_constants, Only: five3rd, thbim1
  Use xnet_screening, Only: screening_init, screening_finalize
  Use xnet_types, Only: dp
  Use test_xnet_screening, Only: collect_screening_tests
  Use testdrive, Only: run_testsuite
  Implicit None
  Integer :: j, stat

  Do j = 1, izmax+2
    zseq(j) = real(j,dp)
  EndDo
  zseq53 = zseq**five3rd
  zseqi = zseq**thbim1
  Call screening_init
  stat = 0
  Call run_testsuite(collect_screening_tests,error_unit,stat,parallel=.False.)
  Call screening_finalize
  If ( stat > 0 ) Stop 1
End Program screening_test_runner
