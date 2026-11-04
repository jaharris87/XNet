! Controlled plasma inputs for the production screening component test.
Module xnet_controls
  Use, Intrinsic :: iso_fortran_env, Only: error_unit
  Implicit None
  Integer :: idiag = 0, iheat = 1, iscrn = 1, lun_diag = error_unit
  Integer :: nzevolve = 1, szbatch = 1, tid = 1, zb_lo = 1, zb_hi = 1
  Logical, Target :: lzactive(1) = .True.
End Module xnet_controls

Module nuclear_data
  Use xnet_types, Only: dp
  Implicit None
  Integer, Parameter :: izmax = 6
  Character(5) :: nname(7) = [ Character(5) :: 'n','p','he4','li6','be8','b8','c12' ]
  Real(dp) :: zz(7) = (/ 0.0_dp,1.0_dp,2.0_dp,3.0_dp,4.0_dp,5.0_dp,6.0_dp /)
  Real(dp) :: zseq(izmax+2), zseq53(izmax+2), zseqi(izmax+2)
End Module nuclear_data

Module reaction_data
  Implicit None
  Integer :: nreac(4) = (/ 0,4,6,0 /)
  ! Sequential pairs for 3 alpha and p+alpha+alpha; n+p+alpha reduces to pair 3.
  Integer :: n2i(2,4) = reshape((/ 3,3, 5,3, 2,3, 4,3 /),(/ 2,4 /))
  Integer :: n3i(3,6) = reshape((/ 3,3,3, 2,3,3, 3,2,3, 3,3,2, 1,2,3, 2,1,3 /),(/ 3,6 /))
  Integer :: n4i(4,0)
End Module reaction_data

Module xnet_abundances
  Use xnet_types, Only: dp
  Implicit None
  Real(dp) :: yt(7,1) = 0.0_dp, xext(1) = 0.0_dp, aext(1) = 1.0_dp, zext(1) = 0.0_dp
End Module xnet_abundances

Module xnet_conditions
  Use xnet_types, Only: dp
  Implicit None
  Real(dp) :: t9t(1) = 1.0_dp, rhot(1) = 1.0_dp, etae(1) = 0.0_dp, detaedt9(1) = 0.0_dp
End Module xnet_conditions

Module xnet_eos
  Use xnet_types, Only: dp
  Implicit None
  Real(dp) :: lambda_at_one = 10.0_dp, intermediate_moment = 1.0_dp
Contains
  Subroutine eos_screen(t9,rho,y,etae,detaedt9,ztilde,zinter,lambda0,gammae,dztildedt9, &
    & xext,aext,zext,mask_in)
    Implicit None
    Real(dp), Intent(in) :: t9(:), rho(:), y(:,:), etae(:), detaedt9(:), xext(:), aext(:), zext(:)
    Logical, Optional, Intent(in) :: mask_in(:)
    Real(dp), Intent(out) :: ztilde(:), zinter(:), lambda0(:), gammae(:), dztildedt9(:)

    ! Fixed composition/electron background: gamma_e varies as T9^-1 and lambda0 as T9^-3/2.
    ztilde = 1.0_dp
    zinter = intermediate_moment
    lambda0 = lambda_at_one/t9**1.5_dp
    gammae = 0.5_dp/t9
    dztildedt9 = 0.0_dp
    Return
  End Subroutine eos_screen
End Module xnet_eos
