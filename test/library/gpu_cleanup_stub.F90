! Only the resource calls are replaced; initialization and teardown use real XNet modules.
Module xnet_gpu
  Use, Intrinsic :: iso_c_binding, Only: C_PTR, C_SIZE_T, C_LOC
  Use, Intrinsic :: iso_fortran_env, Only: real64
  Implicit None
  Type :: xnet_gpu_t
    Integer :: device = -1
  End Type
  Integer :: mydevice = 0, init_calls = 0, finalize_calls = 0, failures_left = 0
  Logical :: active = .false.
Contains
  Type(C_PTR) Function dev_ptr_int(a)
    Integer, Target, Intent(in) :: a
    dev_ptr_int = C_LOC(a)
  End Function
  Type(C_PTR) Function dev_ptr_dp(a)
    Real(real64), Target, Intent(in) :: a
    dev_ptr_dp = C_LOC(a)
  End Function
  Subroutine gpu_init(resources,ierr,message)
    Type(xnet_gpu_t), Intent(in) :: resources
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message
    If ( active ) Error Stop 'GPU initialized twice'
    init_calls = init_calls + 1
    active = .true.
    ierr = 0
    message = ' '
  End Subroutine
  Subroutine gpu_finalize(ierr,message)
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message
    If ( .not. active ) Error Stop 'GPU finalized while inactive'
    finalize_calls = finalize_calls + 1
    ierr = 0
    message = ' '
    If ( failures_left > 0 ) Then
      failures_left = failures_left - 1
      ierr = 1
      message = 'Injected stream synchronization failure'
      Return
    EndIf
    active = .false.
  End Subroutine
  Subroutine gpu_check_device(ierr,message)
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message
    If ( .not. active ) Error Stop 'GPU checked while inactive'
    ierr = 0
    message = ' '
  End Subroutine
  Logical Function device_is_present(address,device,bytes)
    Type(C_PTR), Intent(in) :: address
    Integer, Intent(in) :: device
    Integer(C_SIZE_T), Intent(in) :: bytes
    Error Stop 'Device-array validation is not part of this host cleanup test'
    device_is_present = .false.
  End Function
End Module
