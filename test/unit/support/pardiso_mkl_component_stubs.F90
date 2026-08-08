Module solver_probe
  Use xnet_types, Only: dp
  Implicit None

  Integer, Parameter :: max_calls = 32
  Integer :: call_count = 0
  Integer :: init_abi = 0
  Integer :: init_calls = 0
  Integer :: mnum_history(max_calls) = 0
  Integer :: phase_history(max_calls) = 0
  Logical :: index_base_valid = .True.
  Logical :: options_valid = .True.

Contains

  Subroutine reset_solver_probe
    Implicit None

    call_count = 0
    mnum_history = 0
    phase_history = 0
    index_base_valid = .True.
    options_valid = .True.

    Return
  End Subroutine reset_solver_probe

  Logical Function failure_is(expected)
    Implicit None

    Character(*), Intent(in) :: expected
    Character(80) :: requested
    Integer :: length, status

    requested = ''
    Call get_environment_variable('XNET_SPARSE_FAIL',requested,length=length,status=status)
    failure_is = status == 0 .and. requested(1:length) == expected

    Return
  End Function failure_is

  Subroutine solve_crs(n,a,ia,ja,b,x,error)
    Implicit None

    Integer, Intent(in) :: n, ia(n+1), ja(*)
    Real(dp), Intent(in) :: a(*), b(n)
    Real(dp), Intent(out) :: x(n)
    Integer, Intent(out) :: error

    Integer :: i, k, pivot_row
    Real(dp) :: factor, matrix(n,n), pivot_value, rhs(n), row_buffer(n), rhs_buffer

    matrix = 0.0_dp
    Do i = 1, n
      Do k = ia(i), ia(i+1)-1
        matrix(i,ja(k)) = a(k)
      EndDo
    EndDo
    rhs = b

    Do k = 1, n-1
      pivot_row = k - 1 + maxloc(abs(matrix(k:n,k)),dim=1)
      pivot_value = matrix(pivot_row,k)
      If ( abs(pivot_value) <= tiny(1.0_dp) ) Then
        error = -4
        x = 0.0_dp
        Return
      EndIf
      If ( pivot_row /= k ) Then
        row_buffer = matrix(k,:)
        matrix(k,:) = matrix(pivot_row,:)
        matrix(pivot_row,:) = row_buffer
        rhs_buffer = rhs(k)
        rhs(k) = rhs(pivot_row)
        rhs(pivot_row) = rhs_buffer
      EndIf
      Do i = k+1, n
        factor = matrix(i,k)/matrix(k,k)
        matrix(i,k:n) = matrix(i,k:n) - factor*matrix(k,k:n)
        rhs(i) = rhs(i) - factor*rhs(k)
      EndDo
    EndDo

    If ( abs(matrix(n,n)) <= tiny(1.0_dp) ) Then
      error = -4
      x = 0.0_dp
      Return
    EndIf
    x = 0.0_dp
    Do i = n, 1, -1
      x(i) = (rhs(i)-sum(matrix(i,i+1:n)*x(i+1:n)))/matrix(i,i)
    EndDo
    error = 0

    Return
  End Subroutine solve_crs

End Module solver_probe

Subroutine pardisoinit(pt,mtype,iparm)
  Use solver_probe, Only: init_abi, init_calls
  Use xnet_types, Only: i8
  Implicit None

  Integer(i8), Intent(inout) :: pt(*)
  Integer, Intent(in) :: mtype
  Integer, Intent(inout) :: iparm(*)

  init_calls = init_calls + 1
  init_abi = 64
  pt(1:64) = 0_i8
  iparm(1:64) = 0
  iparm(1) = 1
  iparm(7) = 7
  If ( mtype /= 11 ) iparm(1) = -100

  Return
End Subroutine pardisoinit

Subroutine pardiso(pt,maxfct,mnum,mtype,phase,n,a,ia,ja,perm,nrhs,iparm,msglvl,b,x,error)
  Use solver_probe, Only: call_count, failure_is, index_base_valid, max_calls, mnum_history, &
    & options_valid, phase_history, solve_crs
  Use xnet_types, Only: dp, i8
  Implicit None

  Integer(i8), Intent(inout) :: pt(*)
  Integer, Intent(in) :: maxfct, mnum, mtype, phase, n, ia(*), ja(*), nrhs, msglvl
  Integer, Intent(inout) :: iparm(*), perm(*)
  Real(dp), Intent(in) :: a(*)
  Real(dp), Intent(inout) :: b(*)
  Real(dp), Intent(out) :: x(*)
  Integer, Intent(out) :: error

  call_count = call_count + 1
  If ( call_count <= max_calls ) Then
    phase_history(call_count) = phase
    mnum_history(call_count) = mnum
  EndIf
  index_base_valid = index_base_valid .and. ia(1) == 1 .and. ia(n+1) > ia(1)
  options_valid = options_valid .and. maxfct == 2 .and. mnum >= 1 .and. mnum <= 2 .and. &
    & mtype == 11 .and. nrhs == 1 .and. iparm(3) == 0 .and. &
    & iparm(5) == 0 .and. iparm(6) == 0 .and. iparm(12) == 0 .and. &
    & iparm(31) == 0 .and. iparm(35) == 0 .and. iparm(36) == 0 .and. &
    & (iparm(7) == 77 .or. iparm(7) == 7) .and. &
    & msglvl == 1 .and. all(perm(1:n) == 0)

  If ( .not. index_base_valid ) Then
    error = -201
  ElseIf ( failure_is('pardiso_factor') .and. (phase == 12 .or. phase == 22) ) Then
    error = -4
  ElseIf ( failure_is('pardiso_solve') .and. phase == 33 ) Then
    error = -7
  ElseIf ( phase == 33 ) Then
    Call solve_crs(n,a,ia,ja,b(1:n),x(1:n),error)
  Else
    x(1:n) = 0.0_dp
    error = 0
  EndIf

  Return
End Subroutine pardiso
