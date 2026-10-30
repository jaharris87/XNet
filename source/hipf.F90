!***************************************************************************************************
! hipf.f90 10/18/17
! This file contains the module defining Fortran interfaces for the HIP Runtime API
!***************************************************************************************************

module xnet_hipf
  !-------------------------------------------------------------------------------------------------
  ! Interface to hip Runtime API
  !-------------------------------------------------------------------------------------------------
  use, intrinsic :: iso_c_binding
  use hipfort_check, only: &
    hipCheck, &
    hipblasCheck, &
    hipsparseCheck, &
    rocblasCheck, &
    rocsparseCheck, &
    rocsolverCheck
  use hipfort, only: &
    hipGetDeviceCount, &
    hipGetDevice, &
    hipSetDevice, &
    hipStreamCreate, &
    hipStreamCreateWithFlags, &
    hipStreamNonBlocking, &
    hipStreamDestroy, &
    hipStreamSynchronize, &
    hipDeviceSynchronize

  type(c_ptr), target :: stream = c_null_ptr
  !$omp threadprivate(stream)

end module xnet_hipf
