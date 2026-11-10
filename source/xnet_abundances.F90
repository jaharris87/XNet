!***************************************************************************************************
! xnet_abundances.F90
! Nuclear species abundance state, persistent device mappings, and composition-moment routines.
!
! Manages per-zone molar abundances Y = X / A across the active worker banks (1:nzevolve) at the
! start (ystart), previous (yo), current (y), and trial (yt) times, along with trial time
! derivatives (ydot) and optional fixed auxiliary-reservoir parameters (xext, aext, zext).
!***************************************************************************************************

#include "xnet_macros.fh"

Module xnet_abundances
  Use xnet_types, Only: dp
  Implicit None

  !-------------------------------------------------------------------------------------------------
  ! Per-zone abundance workspace (ny, nzevolve) and auxiliary reservoir parameters (nzevolve)
  !-------------------------------------------------------------------------------------------------
  Real(dp), Allocatable :: ystart(:,:) ! Molar abundances at burn start time
  Real(dp), Allocatable :: yo(:,:)     ! Molar abundances at previous timestep
  Real(dp), Allocatable :: y(:,:)      ! Molar abundances at current timestep
  Real(dp), Allocatable :: yt(:,:)     ! Molar abundances at trial timestep
  Real(dp), Allocatable :: ydot(:,:)   ! Molar abundance time derivatives at trial time
  Real(dp), Allocatable :: xext(:)     ! Auxiliary-reservoir mass fraction
  Real(dp), Allocatable :: aext(:)     ! Auxiliary-reservoir mass number
  Real(dp), Allocatable :: zext(:)     ! Auxiliary-reservoir charge number

  Interface y_moment
    Module Procedure y_moment_scalar
    Module Procedure y_moment_vector
  End Interface y_moment

  Private :: y_moment_internal

Contains

  !=================================================================================================
  ! Workspace Lifecycle
  !=================================================================================================

  Subroutine abundances_initialize
    !-----------------------------------------------------------------------------------------------
    ! Allocate and zero the reusable abundance workspace, then establish persistent device mappings.
    !-----------------------------------------------------------------------------------------------
    Use nuclear_data, Only: ny
    Use xnet_controls, Only: nzevolve, gpu_queue
    Implicit None

    Allocate (y(ny,nzevolve),yo(ny,nzevolve),yt(ny,nzevolve),ydot(ny,nzevolve),ystart(ny,nzevolve))
    Allocate (xext(nzevolve),aext(nzevolve),zext(nzevolve))
    y      = 0.0_dp
    yo     = 0.0_dp
    yt     = 0.0_dp
    ydot   = 0.0_dp
    ystart = 0.0_dp
    xext   = 0.0_dp
    aext   = 0.0_dp
    zext   = 0.0_dp

    !XDIR XENTER_DATA XASYNC(gpu_queue) &
    !XDIR XCOPYIN(y,yo,yt,ydot,ystart,xext,aext,zext)
    !XDIR XWAIT(gpu_queue)

    Return
  End Subroutine abundances_initialize

  Subroutine abundances_finalize
    !-----------------------------------------------------------------------------------------------
    ! Release persistent device mappings before deallocating CPU abundance arrays.
    !-----------------------------------------------------------------------------------------------
    Use xnet_controls, Only: gpu_queue
    Implicit None

    If ( allocated(y) ) Then
      !XDIR XEXIT_DATA XASYNC(gpu_queue) &
      !XDIR XDELETE(y,yo,yt,ydot,ystart,xext,aext,zext)
      !XDIR XWAIT(gpu_queue)
    EndIf
    If ( allocated(ystart) ) Deallocate (ystart)
    If ( allocated(yo) )     Deallocate (yo)
    If ( allocated(y) )      Deallocate (y)
    If ( allocated(yt) )     Deallocate (yt)
    If ( allocated(ydot) )   Deallocate (ydot)
    If ( allocated(xext) )   Deallocate (xext)
    If ( allocated(aext) )   Deallocate (aext)
    If ( allocated(zext) )   Deallocate (zext)

    Return
  End Subroutine abundances_finalize

  !=================================================================================================
  ! Composition Moments for EOS and Screening
  !=================================================================================================

  Subroutine y_moment_internal(y,ye,ytot,abar,zbar,z2bar,zibar,xext,yext,zext)
    !-----------------------------------------------------------------------------------------------
    ! Compute scalar composition moments (Ye, Ytot, Abar, Zbar, Z2bar, Zibar) including any
    ! auxiliary reservoir (xext, yext = xext/aext, zext).
    !-----------------------------------------------------------------------------------------------
    Use nuclear_data, Only: ny, aa, zz, zz2, zzi
    Use xnet_constants, Only: thbim1
    Use xnet_types, Only: dp
    Implicit None

    ! Input arguments
    Real(dp), Intent(in) :: y(ny)
    Real(dp), Intent(in) :: xext, yext, zext

    ! Output arguments
    Real(dp), Intent(out) :: ye, ytot, abar, zbar, z2bar, zibar

    ! Local variables
    Real(dp) :: atot, ztot

    ytot  = sum(y) + yext
    atot  = sum(y * aa) + xext
    ztot  = sum(y * zz) + yext * zext
    abar  = atot / ytot
    zbar  = ztot / ytot
    z2bar = (sum(y * zz2) + yext * zext * zext) / ytot
    zibar = (sum(y * zzi) + yext * zext**thbim1) / ytot
    ye    = ztot / atot

    Return
  End Subroutine y_moment_internal

  Subroutine y_moment_scalar(y,ye,ytot,abar,zbar,z2bar,zibar,xext,aext,zext)
    !-----------------------------------------------------------------------------------------------
    ! Scalar interface for evaluating composition moments of a single zone.
    !-----------------------------------------------------------------------------------------------
    Use nuclear_data, Only: ny
    Use xnet_controls, Only: idiag, lun_diag
    Use xnet_types, Only: dp
    Implicit None

    ! Input arguments
    Real(dp), Intent(in) :: y(ny)
    Real(dp), Intent(in) :: xext, aext, zext

    ! Output arguments
    Real(dp), Intent(out) :: ye, ytot, abar, zbar, z2bar, zibar

    ! Local variables
    Real(dp) :: yext

    yext = xext / aext
    Call y_moment_internal(y,ye,ytot,abar,zbar,z2bar,zibar,xext,yext,zext)
    If ( idiag >= 3 ) Write(lun_diag,"(a4,6es23.15)") 'YMom',ytot,abar,zbar,z2bar,zibar,ye

    Return
  End Subroutine y_moment_scalar

  Subroutine y_moment_vector(y,ye,ytot,abar,zbar,z2bar,zibar,xext,aext,zext,mask_in)
    !-----------------------------------------------------------------------------------------------
    ! Batched interface for evaluating composition moments across the zone bank of the calling worker.
    !-----------------------------------------------------------------------------------------------
    Use nuclear_data, Only: ny, aa, zz, zz2, zzi
    Use xnet_constants, Only: thbim1
    Use xnet_controls, Only: idiag, lun_diag, zb_lo, zb_hi, lzactive, gpu_queue
    Use xnet_types, Only: dp
    Implicit None

    ! Input arguments
    Real(dp), Intent(in) :: y(ny,zb_lo:zb_hi)
    Real(dp), Intent(in) :: xext(zb_lo:zb_hi), aext(zb_lo:zb_hi), zext(zb_lo:zb_hi)

    ! Input/Output arguments
    Real(dp), Intent(inout) :: ye(zb_lo:zb_hi), ytot(zb_lo:zb_hi), abar(zb_lo:zb_hi)
    Real(dp), Intent(inout) :: zbar(zb_lo:zb_hi), z2bar(zb_lo:zb_hi), zibar(zb_lo:zb_hi)

    ! Optional arguments
    Logical, Optional, Target, Intent(in) :: mask_in(zb_lo:zb_hi)

    ! Local variables
    Integer :: izb, k
    Real(dp) :: yext, ntot, atot, ztot, z2tot, zitot
    Logical, Pointer :: mask(:)

    If ( present(mask_in) ) Then
      mask(zb_lo:) => mask_in
    Else
      mask(zb_lo:) => lzactive(zb_lo:zb_hi)
    EndIf
    If ( .not. any(mask) ) Return

    !XDIR XENTER_DATA XASYNC(gpu_queue) &
    !XDIR XCOPYIN(ye,ytot,abar,zbar,z2bar,zibar) &
    !XDIR XCOPYIN(mask,y,xext,aext,zext)

    !XDIR XLOOP_OUTER(1) XASYNC(gpu_queue) &
    !XDIR XPRESENT(ye,ytot,abar,zbar,z2bar,zibar) &
    !XDIR XPRESENT(aa,zz,zz2,zzi) &
    !XDIR XPRESENT(mask,y,xext,aext,zext) &
    !XDIR XPRIVATE(yext,ntot,atot,ztot,z2tot,zitot)
    Do izb = zb_lo, zb_hi
      If ( mask(izb) ) Then
        yext = xext(izb) / aext(izb)

        ntot  = 0.0_dp
        atot  = 0.0_dp
        ztot  = 0.0_dp
        z2tot = 0.0_dp
        zitot = 0.0_dp
        !XDIR XLOOP_INNER(1) &
        !XDIR XREDUCTION(+,ntot,atot,ztot,z2tot,zitot)
        Do k = 1, ny
          ntot  = ntot  + y(k,izb)
          atot  = atot  + y(k,izb) * aa(k)
          ztot  = ztot  + y(k,izb) * zz(k)
          z2tot = z2tot + y(k,izb) * zz2(k)
          zitot = zitot + y(k,izb) * zzi(k)
        EndDo
        ntot  = ntot  + yext
        atot  = atot  + xext(izb)
        ztot  = ztot  + yext * zext(izb)
        z2tot = z2tot + yext * zext(izb) * zext(izb)
        zitot = zitot + yext * zext(izb)**thbim1

        ye(izb)    = ztot  / atot
        ytot(izb)  = ntot
        abar(izb)  = atot  / ntot
        zbar(izb)  = ztot  / ntot
        z2bar(izb) = z2tot / ntot
        zibar(izb) = zitot / ntot
      EndIf
    EndDo

    If ( idiag >= 3 ) Then
      !XDIR XUPDATE XWAIT(gpu_queue) &
      !XDIR XHOST(ye,ytot,abar,zbar,z2bar,zibar)
      Do izb = zb_lo, zb_hi
        If ( mask(izb) ) Then
          Write(lun_diag,"(a4,6es23.15)") 'YMom', &
            & ytot(izb),abar(izb),zbar(izb),z2bar(izb),zibar(izb),ye(izb)
        EndIf
      EndDo
    EndIf

    !XDIR XEXIT_DATA XASYNC(gpu_queue) &
    !XDIR XCOPYOUT(ye,ytot,abar,zbar,z2bar,zibar) &
    !XDIR XDELETE(mask,y,xext,aext,zext)

    Return
  End Subroutine y_moment_vector

End Module xnet_abundances
