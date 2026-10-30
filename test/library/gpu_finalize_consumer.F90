! Host-only regression of production xnet_gpu resource bookkeeping.
! Vendor calls model live handles, ownership, dependencies, and destruction
! errors. These checks do not establish recovery from a real GPU failure.
Module gpu_finalize_vendor
  Use, Intrinsic :: iso_c_binding, Only: C_INT, C_PTR
  Implicit None
  Integer, Parameter :: resource_stream = 1, resource_blas = 2, resource_solver = 3, caller_solver = 4
  Interface
    Integer(C_INT) Function vendor_reset() Bind(C)
      Import C_INT
    End Function
    Integer(C_INT) Function vendor_live(kind) Bind(C)
      Import C_INT
      Integer(C_INT), Value :: kind
    End Function
    Integer(C_INT) Function vendor_creates(kind) Bind(C)
      Import C_INT
      Integer(C_INT), Value :: kind
    End Function
    Integer(C_INT) Function vendor_destroys(kind) Bind(C)
      Import C_INT
      Integer(C_INT), Value :: kind
    End Function
    Integer(C_INT) Function vendor_invalid() Bind(C)
      Import C_INT
    End Function
    Integer(C_INT) Function vendor_syncs() Bind(C)
      Import C_INT
    End Function
    Subroutine vendor_fail(kind,count) Bind(C)
      Import C_INT
      Integer(C_INT), Value :: kind, count
    End Subroutine
    Type(C_PTR) Function vendor_borrow(kind,stream) Bind(C)
      Import C_INT, C_PTR
      Integer(C_INT), Value :: kind
      Type(C_PTR), Value :: stream
    End Function
    Subroutine vendor_release_borrowed() Bind(C)
    End Subroutine
  End Interface
End Module gpu_finalize_vendor

Program gpu_finalize_consumer
  Use, Intrinsic :: iso_c_binding, Only: C_PTR, C_NULL_PTR, C_Associated
  Use xnet_gpu, Only: gpu_init, gpu_finalize, xnet_gpu_t, mydevice, stream
  Use xnet_controls, Only: tid, myid
  Use gpu_finalize_vendor, Only: resource_stream, resource_blas, resource_solver, caller_solver, &
    & vendor_reset, vendor_live, vendor_creates, vendor_destroys, vendor_invalid, vendor_syncs, &
    & vendor_fail, vendor_borrow, vendor_release_borrowed
  Implicit None
  Character(32) :: scenario

  tid = 1
  myid = 0
  Call Get_Command_Argument(1,scenario)
  Call require(vendor_reset() == 0,'initial vendor state')
  Select Case (Trim(scenario))
  Case ('stream')
    Call retry_one(resource_stream)
  Case ('blas')
    Call retry_one(resource_blas)
  Case ('solver')
    Call retry_one(resource_solver)
  Case ('both')
    Call retry_both()
  Case ('borrowed')
    Call borrowed_resources()
  Case ('mixed-blas')
    Call mixed_resources(resource_blas)
  Case ('mixed-solver')
    Call mixed_resources(resource_solver)
  Case Default
    Print '(A)', 'Choose stream, blas, solver, both, borrowed, mixed-blas, or mixed-solver'
    Stop 1
  End Select
  Call require(vendor_invalid() == 0,'no invalid, duplicate, or caller-owned destruction')
  Call check_live([0,0,0])
  Call require(vendor_live(caller_solver) == 0,'caller released its separate solver handle')
#if defined(XNET_CUDA)
  Print '(A)', 'PASS CUDA simulated cleanup bookkeeping: '//Trim(scenario)
#elif defined(XNET_HIP)
  Print '(A)', 'PASS HIP simulated cleanup bookkeeping: '//Trim(scenario)
#endif

Contains

  Subroutine require(condition,label)
    Implicit None
    Logical, Intent(in) :: condition
    Character(*), Intent(in) :: label
    If ( .not. condition ) Then
      Print '(A)', 'FAIL '//Trim(scenario)//': '//label
      Stop 1
    EndIf
    Return
  End Subroutine require

  Subroutine check_live(expected)
    Implicit None
    Integer, Intent(in) :: expected(3)
    Integer :: kind
    Do kind = resource_stream, resource_solver
      If ( vendor_live(kind) /= expected(kind) ) Then
        Print '(A,3I5)', 'live kind, observed, expected:', kind, vendor_live(kind), expected(kind)
        Call require(.false.,'live resources after finalize')
      EndIf
    EndDo
    Return
  End Subroutine check_live

  Subroutine check_destroys(expected)
    Implicit None
    Integer, Intent(in) :: expected(3)
    Integer :: kind
    Do kind = resource_stream, resource_solver
      If ( vendor_destroys(kind) /= expected(kind) ) Then
        Print '(A,3I5)', 'destroy kind, observed, expected:', kind, vendor_destroys(kind), expected(kind)
        Call require(.false.,'destructor call count')
      EndIf
    EndDo
    Call require(vendor_invalid() == 0,'live handle keeps its stream; successful destruction is not repeated')
    Return
  End Subroutine check_destroys

  Subroutine check_creates(expected)
    Implicit None
    Integer, Intent(in) :: expected(3)
    Integer :: kind
    Do kind = resource_stream, resource_solver
      Call require(vendor_creates(kind) == expected(kind),'resource creation count')
    EndDo
    Return
  End Subroutine check_creates

  Subroutine initialize(context)
    Implicit None
    Type(xnet_gpu_t), Intent(in) :: context
    Integer :: ierr
    Character(512) :: message
    Call gpu_init(context,ierr,message)
    If ( ierr /= 0 ) Print '(A)', Trim(message)
    Call require(ierr == 0,'initialization succeeds')
    Return
  End Subroutine initialize

  Subroutine finish(failed_kind)
    Implicit None
    Integer, Intent(in) :: failed_kind
    Integer :: ierr
    Character(512) :: message
    Call gpu_finalize(ierr,message)
    If ( failed_kind == 0 ) Then
      If ( ierr /= 0 ) Print '(A)', Trim(message)
      Call require(ierr == 0 .and. Len_Trim(message) == 0,'cleanup succeeds after vendor errors stop')
      Call require(mydevice == -1 .and. .not. Associated(stream),'complete cleanup clears device and stream')
    Else
      Call require(ierr /= 0,'vendor destruction failure is reported on every attempt')
      Select Case (failed_kind)
      Case (resource_stream)
        Call require(Index(message,'GPU stream, status 71') > 0,'stream failure diagnostic')
      Case (resource_blas)
#if defined(XNET_CUDA)
        Call require(Index(message,'cuBLAS handle, status 72') > 0,'cuBLAS failure diagnostic')
#elif defined(XNET_HIP)
        Call require(Index(message,'hipBLAS handle, status 72') > 0,'hipBLAS failure diagnostic')
#endif
      Case (resource_solver)
#if defined(XNET_CUDA)
        Call require(Index(message,'cuSOLVER handle, status 73') > 0,'cuSOLVER failure diagnostic')
#elif defined(XNET_HIP)
        Call require(Index(message,'rocBLAS handle, status 73') > 0,'rocBLAS failure diagnostic')
#endif
      End Select
      Call require(mydevice == 0 .and. Associated(stream),'failed cleanup retains device and stream')
      Call require(C_Associated(stream),'failed cleanup retains a live stream pointer')
    EndIf
    Return
  End Subroutine finish

  Subroutine reject_reinitialize(context,expected_creates)
    Implicit None
    Type(xnet_gpu_t), Intent(in) :: context
    Integer, Intent(in) :: expected_creates(3)
    Integer :: ierr
    Character(512) :: message
    Call gpu_init(context,ierr,message)
    Call require(ierr == 2 .and. Index(message,'already initialized') > 0, &
      & 'initialization is rejected while cleanup remains pending')
    Call check_creates(expected_creates)
    Return
  End Subroutine reject_reinitialize

  Subroutine retry_one(kind)
    Implicit None
    Integer, Intent(in) :: kind
    Type(xnet_gpu_t) :: context
    Integer :: counts(3), live(3), attempt, sync_count

    Call initialize(context)
    Call check_creates([1,1,1])
    Call vendor_fail(kind,2)
    counts = [0,1,1]
    live = [1,0,0]
    If ( kind == resource_stream ) counts(resource_stream) = 1
    live(kind) = 1
    Do attempt = 1, 2
      counts(kind) = attempt
      Call finish(kind)
      Call check_destroys(counts)
      Call check_live(live)
      Call reject_reinitialize(context,[1,1,1])
    EndDo
    Call finish(0)
    counts = [1,1,1]
    counts(kind) = 3
    Call check_destroys(counts)
    Call check_live([0,0,0])
    sync_count = vendor_syncs()
    Call finish(0)
    Call check_destroys(counts)
    Call require(vendor_syncs() == sync_count,'completed cleanup is a no-op')

    Call initialize(context)
    Call check_creates([2,2,2])
    Call finish(0)
    Call check_destroys(counts+1)
    Return
  End Subroutine retry_one

  Subroutine retry_both()
    Implicit None
    Type(xnet_gpu_t) :: context
    Call initialize(context)
    Call vendor_fail(resource_solver,2)
    Call vendor_fail(resource_blas,1)
    Call finish(resource_solver)
    Call check_destroys([0,1,1])
    Call check_live([1,1,1])
    Call reject_reinitialize(context,[1,1,1])
    Call finish(resource_solver)
    Call check_destroys([0,2,2])
    Call check_live([1,0,1])
    Call finish(0)
    Call check_destroys([1,2,3])
    Return
  End Subroutine retry_both

  Subroutine supply_handle(context,kind,pointer)
    Implicit None
    Type(xnet_gpu_t), Intent(inout) :: context
    Integer, Intent(in) :: kind
    Type(C_PTR), Intent(in) :: pointer
#if defined(XNET_CUDA)
    If ( kind == resource_blas ) context%cublas_handle = pointer
    If ( kind == resource_solver ) context%cusolver_handle = pointer
#elif defined(XNET_HIP)
    If ( kind == resource_blas ) context%hipblas_handle = pointer
    If ( kind == resource_solver ) context%rocblas_handle = pointer
#endif
    Return
  End Subroutine supply_handle

  Subroutine borrowed_resources()
    Implicit None
    Type(xnet_gpu_t) :: context
    Type(C_PTR) :: caller_stream
    Integer :: kind, attempt
    caller_stream = vendor_borrow(resource_stream,C_NULL_PTR)
    Do kind = resource_blas, resource_solver
      Call supply_handle(context,kind,vendor_borrow(kind,caller_stream))
    EndDo
#if defined(XNET_HIP)
    ! A separate borrowed rocSOLVER handle must not be destroyed with rocBLAS.
    context%rocsolver_handle = vendor_borrow(caller_solver,caller_stream)
#endif
    ! Infer the caller's stream from the handles instead of supplying it.
    Do attempt = 1, 2
      Call initialize(context)
      Call check_creates([0,0,0])
      Call require(C_Associated(stream,caller_stream),'inferred caller stream is unchanged')
      Call finish(0)
      Call check_destroys([0,0,0])
      Call check_live([1,1,1])
#if defined(XNET_HIP)
      Call require(vendor_live(caller_solver) == 1,'separate caller rocSOLVER handle remains live')
#endif
    EndDo
    Call vendor_release_borrowed()
    Return
  End Subroutine borrowed_resources

  Subroutine mixed_resources(owned_kind)
    Implicit None
    Integer, Intent(in) :: owned_kind
    Type(xnet_gpu_t) :: context
    Integer :: borrowed_kind, counts(3), live(3), creates(3), attempt
    borrowed_kind = resource_blas + resource_solver - owned_kind
    context%stream = vendor_borrow(resource_stream,C_NULL_PTR)
    Call supply_handle(context,borrowed_kind,vendor_borrow(borrowed_kind,context%stream))
#if defined(XNET_HIP)
    context%rocsolver_handle = vendor_borrow(caller_solver,context%stream)
#endif
    creates = 0
    creates(owned_kind) = 1
    counts = 0
    live = 1
    Call initialize(context)
    Call check_creates(creates)
    Call vendor_fail(owned_kind,2)
    Do attempt = 1, 2
      Call finish(owned_kind)
      counts(owned_kind) = attempt
      Call check_destroys(counts)
      Call check_live(live)
      Call reject_reinitialize(context,creates)
    EndDo
    Call finish(0)
    counts(owned_kind) = 3
    live(owned_kind) = 0
    Call check_destroys(counts)
    Call check_live(live)
#if defined(XNET_HIP)
    Call require(vendor_live(caller_solver) == 1,'separate caller rocSOLVER handle survives cleanup errors')
#endif
    Call vendor_release_borrowed()
    Return
  End Subroutine mixed_resources
End Program gpu_finalize_consumer
