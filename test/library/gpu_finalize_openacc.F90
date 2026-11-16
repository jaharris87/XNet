! Host-only declarations for the production xnet_openaccf wrapper.
! The default constants use NVIDIA's values; the second build swaps their order.
Module openacc
  Use iso_c_binding, Only: C_INT
  Implicit None
  Integer(C_INT), Parameter :: acc_device_nvidia=5, acc_device_host=2, acc_device_default=1
#ifdef TEST_SWAP_ACC_SPECIALS
  Integer(C_INT), Parameter :: acc_async_sync=-4, acc_async_noval=-1
#else
  Integer(C_INT), Parameter :: acc_async_sync=-1, acc_async_noval=-4
#endif
Contains
  Subroutine acc_init(device_type)
    Implicit None
    Integer(C_INT), Intent(in) :: device_type
    Return
  End Subroutine acc_init
  Subroutine acc_set_device_num(device,device_type)
    Implicit None
    Integer(C_INT), Intent(in) :: device, device_type
    Return
  End Subroutine acc_set_device_num
  Integer(C_INT) Function acc_get_device_num(device_type)
    Implicit None
    Integer(C_INT), Intent(in) :: device_type
    acc_get_device_num=0
    Return
  End Function acc_get_device_num
End Module openacc
