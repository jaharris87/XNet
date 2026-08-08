Module xnet_controls
  Use, Intrinsic :: iso_fortran_env, Only: error_unit, output_unit
  Implicit None

  Integer :: idiag = 0
  Integer :: ineutrino = 0
  Integer :: lun_diag = error_unit
  Integer :: lun_stdout = output_unit
  Integer :: nzevolve = 0
  Integer :: szbatch = 1
  Integer :: tid = 1
  Integer :: zb_lo = 1
  Integer :: zb_hi = 1
  Logical, Allocatable, Target :: lzactive(:)
End Module xnet_controls

Module nuclear_data
  Use xnet_types, Only: dp
  Implicit None

  Integer :: ny = 0
  Real(dp), Allocatable :: aa(:)
  Real(dp), Allocatable :: zz(:)
  Real(dp), Allocatable :: zz2(:)
  Real(dp), Allocatable :: zzi(:)
End Module nuclear_data

Module xnet_parallel
  Implicit None

Contains

  Subroutine parallel_abort(str,errorcode)
    Implicit None

    Character(*), Intent(in), Optional :: str
    Integer, Intent(in), Optional :: errorcode

    If ( present(str) ) Write(*,*) trim(str)
    If ( present(errorcode) ) Write(*,*) errorcode
    Stop 1
  End Subroutine parallel_abort

End Module xnet_parallel
