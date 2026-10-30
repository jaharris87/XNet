!***************************************************************************************************
! rocsolverf.f90 10/18/17
! This file contains the module defining Fortran interfaces for the rocSOLVER library
!***************************************************************************************************

module xnet_rocsolverf
  !-------------------------------------------------------------------------------------------------
  ! Interface to rocSOLVER routines
  !-------------------------------------------------------------------------------------------------
  use, intrinsic :: iso_c_binding
  use hipfort_rocsolver, only: &
    rocsolver_dgeqrf, &
    rocsolver_dormqr, &
    rocsolver_dgetrf_batched, &
    rocsolver_dgetrs_batched

  type(c_ptr) :: rocsolver_handle = c_null_ptr
  !$omp threadprivate(rocsolver_handle)

end module xnet_rocsolverf
