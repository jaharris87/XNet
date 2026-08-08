Module xnet_gpu
  Use, Intrinsic :: iso_c_binding, Only: c_loc, c_ptr
  Use xnet_types, Only: dp
  Implicit None

  Interface dev_ptr
    Module Procedure dev_ptr_int
    Module Procedure dev_ptr_dp
  End Interface dev_ptr

Contains

  Function dev_ptr_int(value) Result(pointer)
    Implicit None

    Integer, Intent(in), Target :: value
    Type(c_ptr) :: pointer

    pointer = c_loc(value)

    Return
  End Function dev_ptr_int

  Function dev_ptr_dp(value) Result(pointer)
    Implicit None

    Real(dp), Intent(in), Target :: value
    Type(c_ptr) :: pointer

    pointer = c_loc(value)

    Return
  End Function dev_ptr_dp

End Module xnet_gpu

Module xnet_linalg
  Use xnet_types, Only: dp
  Implicit None

Contains

  Subroutine solve_dense(n,matrix,b,x,error)
    Implicit None

    Integer, Intent(in) :: n
    Real(dp), Intent(in) :: matrix(n,n), b(n)
    Real(dp), Intent(out) :: x(n)
    Integer, Intent(out) :: error

    Integer :: i, k, pivot_row
    Real(dp) :: factor, work(n,n), pivot_value, rhs(n), row_buffer(n), rhs_buffer

    work = matrix
    rhs = b
    Do k = 1, n-1
      pivot_row = k - 1 + maxloc(abs(work(k:n,k)),dim=1)
      pivot_value = work(pivot_row,k)
      If ( abs(pivot_value) <= tiny(1.0_dp) ) Then
        error = -1
        x = 0.0_dp
        Return
      EndIf
      If ( pivot_row /= k ) Then
        row_buffer = work(k,:)
        work(k,:) = work(pivot_row,:)
        work(pivot_row,:) = row_buffer
        rhs_buffer = rhs(k)
        rhs(k) = rhs(pivot_row)
        rhs(pivot_row) = rhs_buffer
      EndIf
      Do i = k+1, n
        factor = work(i,k)/work(k,k)
        work(i,k:n) = work(i,k:n) - factor*work(k,k:n)
        rhs(i) = rhs(i) - factor*rhs(k)
      EndDo
    EndDo
    If ( abs(work(n,n)) <= tiny(1.0_dp) ) Then
      error = -1
      x = 0.0_dp
      Return
    EndIf
    x = 0.0_dp
    Do i = n, 1, -1
      x(i) = (rhs(i)-sum(work(i,i+1:n)*x(i+1:n)))/work(i,i)
    EndDo
    error = 0

    Return
  End Subroutine solve_dense

  Subroutine LinearSolve_CPU(trans,n,nrhs,a,lda,ipiv,b,ldb,info)
    Implicit None

    Character, Intent(in) :: trans
    Integer, Intent(in) :: n, nrhs, lda, ldb
    Real(dp), Intent(in) :: a(lda,*)
    Integer, Intent(inout) :: ipiv(*)
    Real(dp), Intent(inout) :: b(ldb,*)
    Integer, Intent(out) :: info

    Integer :: i
    Real(dp) :: solution(n)

    If ( trans /= 'N' .or. nrhs /= 1 ) Then
      info = -1
      Return
    EndIf
    Call solve_dense(n,a(1:n,1:n),b(1:n,1),solution,info)
    If ( info == 0 ) b(1:n,1) = solution
    ipiv(1:n) = (/ (i,i=1,n) /)
    info = 0

    Return
  End Subroutine LinearSolve_CPU

  Subroutine LUDecomp_CPU(m,n,a,lda,ipiv,info)
    Implicit None

    Integer, Intent(in) :: m, n, lda
    Real(dp), Intent(inout) :: a(lda,*)
    Integer, Intent(out) :: ipiv(*), info

    Integer :: i

    Do i = 1, min(m,n)
      ipiv(i) = i
    EndDo
    info = 0

    Return
  End Subroutine LUDecomp_CPU

  Subroutine LUBksub_CPU(trans,n,nrhs,a,lda,ipiv,b,ldb,info)
    Implicit None

    Character, Intent(in) :: trans
    Integer, Intent(in) :: n, nrhs, lda, ldb
    Real(dp), Intent(in) :: a(lda,*)
    Integer, Intent(inout) :: ipiv(*)
    Real(dp), Intent(inout) :: b(ldb,*)
    Integer, Intent(out) :: info

    Call LinearSolve_CPU(trans,n,nrhs,a,lda,ipiv,b,ldb,info)

    Return
  End Subroutine LUBksub_CPU

  Subroutine LinearSolveBatched_GPU
    Implicit None

    Return
  End Subroutine LinearSolveBatched_GPU

  Subroutine LUDecompBatched_GPU
    Implicit None

    Return
  End Subroutine LUDecompBatched_GPU

  Subroutine LUBksubBatched_GPU
    Implicit None

    Return
  End Subroutine LUBksubBatched_GPU

End Module xnet_linalg
