! Minimal host-only hipfort declarations for the cleanup bookkeeping test.
! XNet's production HIP binding modules are compiled unchanged against these
! declarations. Numerical routines are declared only to satisfy their imports;
! this test never calls them and supplies no numerical implementation.
Module hipfort_check
  Implicit None
  Interface hipblasCheck
    Module Procedure hipCheck
  End Interface
  Interface hipsparseCheck
    Module Procedure hipCheck
  End Interface
  Interface rocblasCheck
    Module Procedure hipCheck
  End Interface
  Interface rocsparseCheck
    Module Procedure hipCheck
  End Interface
  Interface rocsolverCheck
    Module Procedure hipCheck
  End Interface
Contains
  Subroutine hipCheck(status)
    Implicit None
    Integer, Intent(in) :: status
    If ( status /= 0 ) Then
      Print '(A)', 'Unexpected hipCheck failure in host-only cleanup test'
      Stop 1
    EndIf
    Return
  End Subroutine hipCheck
End Module hipfort_check

Module hipfort
  Use, Intrinsic :: iso_c_binding, Only: C_INT, C_PTR
  Implicit None
  Integer, Parameter :: hipStreamNonBlocking = 1
  External :: hipStreamCreateWithFlags
  Interface
    Integer(C_INT) Function hipGetDeviceCount(count) Bind(C,name="hipGetDeviceCount")
      Import C_INT
      Integer(C_INT), Intent(out) :: count
    End Function
    Integer(C_INT) Function hipGetDevice(device) Bind(C,name="hipGetDevice")
      Import C_INT
      Integer(C_INT), Intent(out) :: device
    End Function
    Integer(C_INT) Function hipSetDevice(device) Bind(C,name="hipSetDevice")
      Import C_INT
      Integer(C_INT), Value :: device
    End Function
    Integer(C_INT) Function hipStreamCreate(stream) Bind(C,name="hipStreamCreate")
      Import C_INT, C_PTR
      Type(C_PTR), Intent(out) :: stream
    End Function
    Integer(C_INT) Function hipStreamDestroy(stream) Bind(C,name="hipStreamDestroy")
      Import C_INT, C_PTR
      Type(C_PTR), Value :: stream
    End Function
    Integer(C_INT) Function hipStreamSynchronize(stream) Bind(C,name="hipStreamSynchronize")
      Import C_INT, C_PTR
      Type(C_PTR), Value :: stream
    End Function
    Integer(C_INT) Function hipDeviceSynchronize() Bind(C,name="hipDeviceSynchronize")
      Import C_INT
    End Function
  End Interface
End Module hipfort

Module hipfort_hipblas_enums
  Implicit None
  Integer, Parameter :: HIPBLAS_OP_N = 0, HIPBLAS_OP_T = 1, HIPBLAS_SIDE_LEFT = 0
  Integer, Parameter :: HIPBLAS_FILL_MODE_UPPER = 0, HIPBLAS_DIAG_NON_UNIT = 0
End Module hipfort_hipblas_enums

Module hipfort_hipblas
  Use, Intrinsic :: iso_c_binding, Only: C_INT, C_PTR
  Implicit None
  External :: hipblasDnrm2, hipblasDaxpy, hipblasDgemm, hipblasDgemmStridedBatched, &
    & hipblasDgetrf, hipblasDgetrfBatched, hipblasDgetrfStridedBatched, hipblasDgetrs, &
    & hipblasDgetrsBatched, hipblasDgetrsStridedBatched, hipblasDgemv, hipblasDtrsv, &
    & hipblasDtrsm, hipblasDgeam, hipblasDdgmm
  Interface
    Integer(C_INT) Function hipblasCreate(handle) Bind(C,name="hipblasCreate")
      Import C_INT, C_PTR
      Type(C_PTR), Intent(out) :: handle
    End Function
    Integer(C_INT) Function hipblasDestroy(handle) Bind(C,name="hipblasDestroy")
      Import C_INT, C_PTR
      Type(C_PTR), Value :: handle
    End Function
    Integer(C_INT) Function hipblasGetStream(handle,stream) Bind(C,name="hipblasGetStream")
      Import C_INT, C_PTR
      Type(C_PTR), Value :: handle
      Type(C_PTR), Intent(out) :: stream
    End Function
    Integer(C_INT) Function hipblasSetStream(handle,stream) Bind(C,name="hipblasSetStream")
      Import C_INT, C_PTR
      Type(C_PTR), Value :: handle, stream
    End Function
  End Interface
End Module hipfort_hipblas

Module hipfort_rocblas_enums
  Implicit None
  Integer, Parameter :: rocblas_operation_none = 0, rocblas_operation_transpose = 1
  Integer, Parameter :: rocblas_side_left = 0, rocblas_fill_upper = 0
  Integer, Parameter :: rocblas_diagonal_non_unit = 0, rocblas_pointer_mode_device = 1
End Module hipfort_rocblas_enums

Module hipfort_rocblas
  Use, Intrinsic :: iso_c_binding, Only: C_INT, C_PTR
  Implicit None
  External :: rocblas_dnrm2, rocblas_daxpy, rocblas_dgemm, rocblas_dgemm_strided_batched, &
    & rocblas_dgemv, rocblas_dtrsv, rocblas_dtrsm, rocblas_dgeam, rocblas_ddgmm, rocblas_ddot_strided_batched
  Interface
    Integer(C_INT) Function rocblas_create_handle(handle) Bind(C)
      Import C_INT, C_PTR
      Type(C_PTR), Intent(out) :: handle
    End Function
    Integer(C_INT) Function rocblas_destroy_handle(handle) Bind(C)
      Import C_INT, C_PTR
      Type(C_PTR), Value :: handle
    End Function
    Integer(C_INT) Function rocblas_get_stream(handle,stream) Bind(C)
      Import C_INT, C_PTR
      Type(C_PTR), Value :: handle
      Type(C_PTR), Intent(out) :: stream
    End Function
    Integer(C_INT) Function rocblas_set_stream(handle,stream) Bind(C)
      Import C_INT, C_PTR
      Type(C_PTR), Value :: handle, stream
    End Function
    Integer(C_INT) Function rocblas_set_pointer_mode(handle,mode) Bind(C)
      Import C_INT, C_PTR
      Type(C_PTR), Value :: handle
      Integer(C_INT), Value :: mode
    End Function
  End Interface
End Module hipfort_rocblas

Module hipfort_rocsolver
  Implicit None
  External :: rocsolver_dgeqrf, rocsolver_dormqr, rocsolver_dgetrf_batched, rocsolver_dgetrs_batched
End Module hipfort_rocsolver
