!***************************************************************************************************
! xnet_conditions.f90 10/18/17
! This file contains modules and subroutines associated with the thermodynamic conditions in the
! matter undergoing nucleosynthesis.
!***************************************************************************************************

#include "xnet_macros.fh"

Module xnet_conditions
  !-------------------------------------------------------------------------------------------------
  ! This module contains data on the current time and thermodynamic conditions.
  !-------------------------------------------------------------------------------------------------
  Use xnet_types, Only: dp
  Implicit None
  Real(dp), Allocatable :: t(:)                  ! Time at the beginning of the current timestep
  Real(dp), Allocatable :: tt(:)                 ! Trial time for end of current timestep
  Real(dp), Allocatable :: to(:)                 ! Time at the beginning of the previous timestep
  Real(dp), Allocatable :: tdel(:)               ! Trial duration of timestep
  Real(dp), Allocatable :: tdel_next(:)          ! Integrator estimate of duration for next timestep
  Real(dp), Allocatable :: tdel_old(:)           ! Duration of the previous timestep
  Real(dp), Allocatable :: t9t(:),rhot(:),yet(:) ! Temperature, density, and electron fraction at trial time
  Real(dp), Allocatable :: t9(:),rho(:),ye(:)    ! Temperature, density, and electron fraction at current time
  Real(dp), Allocatable :: t9o(:),rhoo(:),yeo(:) ! Temperature, density, and electron fraction at previous time
  Real(dp), Allocatable :: t9dot(:)              ! Time derivative of temperature at trial time

  Real(dp), Allocatable :: cv(:)                 ! Specific heat at constant volume
  Real(dp), Allocatable :: etae(:)               ! Ratio of electron chemical potential to kT
  Real(dp), Allocatable :: detaedt9(:)           ! d(etae)/dT9

  Integer, Allocatable :: nt(:)    ! Point in thermo trajectory for current time
  Integer, Allocatable :: ntt(:)   ! Point in thermo trajectory for trial time
  Integer, Allocatable :: nto(:)   ! Point in thermo trajectory for previous time
  Integer, Allocatable :: ints(:)  ! Nucleus governing timestep
  Integer, Allocatable :: intso(:) ! Nucleus governing last timestep

  ! Arrays for thermodynamic trajectory that the network follows
  Integer, Parameter    :: nhmx = 50000 ! The max number of thermo points
  Integer, Allocatable  :: nh(:)        ! The actual number of points
  Integer, Allocatable  :: nstart(:)
  Real(dp), Allocatable :: tstart(:),tstop(:),tdelstart(:),t9start(:),rhostart(:),yestart(:)
  Real(dp), Allocatable :: th(:,:),t9h(:,:),rhoh(:,:),yeh(:,:)

  Interface t9rhofind
    Module Procedure t9rhofind_scalar
    Module Procedure t9rhofind_vector
  End Interface t9rhofind

Contains

  Subroutine conditions_initialize(history_capacity)
    !-----------------------------------------------------------------------------------------------
    ! The standalone driver needs full histories; constant-condition callers need two endpoints.
    ! Allocate and initialize condition storage, then establish its persistent device mappings.
    !-----------------------------------------------------------------------------------------------
    Use xnet_controls, Only: nzevolve, gpu_queue
    Implicit None
    Integer, Intent(in) :: history_capacity
    Allocate (tdel(nzevolve),tdel_next(nzevolve),tdel_old(nzevolve), &
      & t(nzevolve),tt(nzevolve),to(nzevolve), &
      & t9(nzevolve),t9t(nzevolve),t9o(nzevolve),t9dot(nzevolve), &
      & rho(nzevolve),rhot(nzevolve),rhoo(nzevolve), &
      & ye(nzevolve),yet(nzevolve),yeo(nzevolve), &
      & cv(nzevolve),etae(nzevolve),detaedt9(nzevolve), &
      & nt(nzevolve),ntt(nzevolve),nto(nzevolve),ints(nzevolve),intso(nzevolve))
    tdel = 0.0 ; tdel_next = 0.0 ; tdel_old = 0.0
    t = 0.0 ; tt = 0.0 ; to = 0.0
    t9 = 0.0 ; t9t = 0.0 ; t9o = 0.0 ; t9dot = 0.0
    rho = 0.0 ; rhot = 0.0 ; rhoo = 0.0
    ye = 0.0 ; yet = 0.0 ; yeo = 0.0
    cv = 0.0 ; etae = 0.0 ; detaedt9 = 0.0
    nt = 0 ; ntt = 0 ; nto = 0 ; ints = 0 ; intso = 0
    Allocate (nstart(nzevolve),tstart(nzevolve),tstop(nzevolve),tdelstart(nzevolve), &
      & t9start(nzevolve),rhostart(nzevolve),yestart(nzevolve),nh(nzevolve), &
      & th(history_capacity,nzevolve),t9h(history_capacity,nzevolve), &
      & rhoh(history_capacity,nzevolve),yeh(history_capacity,nzevolve))
    nstart = 0 ; tstart = 0.0 ; tstop = 0.0 ; tdelstart = 0.0
    t9start = 0.0 ; rhostart = 0.0 ; yestart = 0.0 ; nh = 0
    th = 0.0 ; t9h = 0.0 ; rhoh = 0.0 ; yeh = 0.0

    !XDIR XENTER_DATA XASYNC(gpu_queue) &
    !XDIR XCOPYIN(tdel,tdel_next,tdel_old,t,tt,to,t9,t9t,t9o,t9dot) &
    !XDIR XCOPYIN(rho,rhot,rhoo,ye,yet,yeo,cv,etae,detaedt9,nt,ntt,nto,ints,intso) &
    !XDIR XCOPYIN(tstart,tstop,tdelstart,nstart,t9start,rhostart,yestart) &
    !XDIR XCOPYIN(nh,th,t9h,rhoh,yeh)
    !XDIR XWAIT(gpu_queue)
    Return
  End Subroutine conditions_initialize

  Subroutine t9rhofind_scalar(kstep,tf,nf,t9f,rhof,ns,ts,t9s,rhos)
    !-----------------------------------------------------------------------------------------------
    ! This routine calculates t9 and rho as a function of time, either via interpolation or from an
    ! analytic expression. (scalar interface)
    !-----------------------------------------------------------------------------------------------
    Use, Intrinsic :: iso_fortran_env, Only: lun_stdout=>output_unit
    Use xnet_types, Only: dp
    Implicit None
    !XDIR XROUTINE_SEQ

    ! Input variables
    Integer, Intent(in) :: kstep, ns
    Real(dp), Intent(in) :: tf, ts(ns), t9s(ns), rhos(ns)

    ! Output variables
    Integer, Intent(out) :: nf
    Real(dp), Intent(out) :: t9f, rhof

    ! Local variables
    Real(dp) :: dt, rdt, dt9, drho
    Integer :: n

    ! For constant conditions (ns = 1), set temperature and density
    If ( ns == 1 ) Then
      t9f = t9s(1)
      rhof = rhos(1)
      nf = 1

    ! Otherwise, calculate T9 and rho by interpolation
    Else
      Do n = 1, ns
        If ( tf <= ts(n) ) Exit
      EndDo
      nf = n
      If ( n > 1 .and. n <= ns ) Then
        rdt = 1.0 / (ts(n)-ts(n-1))
        dt = tf - ts(n-1)
        dt9 = t9s(n) - t9s(n-1)
        drho = rhos(n) - rhos(n-1)
        t9f = dt*rdt*dt9 + t9s(n-1)
        rhof = dt*rdt*drho + rhos(n-1)
      ElseIf ( n == 1 ) Then
        t9f = t9s(1)
        rhof = rhos(1)
      Else
        t9f = t9s(ns)
        rhof = rhos(ns)
        Write(lun_stdout,*) 'Time beyond thermodynamic range',tf,' >',ts(ns)
      EndIf
    EndIf

    Return
  End Subroutine t9rhofind_scalar

  Subroutine t9rhofind_vector(kstep,tf,nf,t9f,rhof,mask_in)
    !-----------------------------------------------------------------------------------------------
    ! This routine calculates t9 and rho as a function of time, either via interpolation or from an
    ! analytic expression. (vector interface)
    !-----------------------------------------------------------------------------------------------
    Use xnet_controls, Only: lun_diag, lun_stdout, zb_lo, zb_hi, lzactive, tid, gpu_queue
    Use xnet_types, Only: dp
    Implicit None

    ! Input variables
    Integer, Intent(in) :: kstep
    Real(dp), Intent(in) :: tf(zb_lo:zb_hi)

    ! Input/Output variables
    Integer, Intent(inout) :: nf(zb_lo:zb_hi)
    Real(dp), Intent(inout) :: t9f(zb_lo:zb_hi), rhof(zb_lo:zb_hi)

    ! Optional variables
    Logical, Optional, Target, Intent(in) :: mask_in(zb_lo:zb_hi)

    ! Local variables
    Real(dp) :: dt, rdt, dt9, drho
    Integer :: n, izb
    Logical, Pointer :: mask(:)

    If ( present(mask_in) ) Then
      mask(zb_lo:) => mask_in
    Else
      mask(zb_lo:) => lzactive(zb_lo:zb_hi)
    End If
    If ( .not. any(mask) ) Return

    !XDIR XENTER_DATA XASYNC(gpu_queue) &
    !XDIR XCOPYIN(mask,tf,nf,t9f,rhof,nh,th,t9h,rhoh)

    !XDIR XLOOP_OUTER(1) XASYNC(gpu_queue) &
    !XDIR XPRESENT(mask,tf,nf,t9f,rhof,th,nh,t9h,rhoh)
    Do izb = zb_lo, zb_hi
      If ( mask(izb) ) Then
        Call t9rhofind_scalar(kstep,tf(izb),nf(izb),t9f(izb),rhof(izb), &
          & nh(izb),th(:,izb),t9h(:,izb),rhoh(:,izb))
      EndIf
    EndDo

    !XDIR XEXIT_DATA XASYNC(gpu_queue) &
    !XDIR XCOPYOUT(nf,t9f,rhof) &
    !XDIR XDELETE(mask,tf,nh,th,t9h,rhoh)

    Return
  End Subroutine t9rhofind_vector

  Subroutine conditions_finalize
    !-----------------------------------------------------------------------------------------------
    ! Release persistent device mappings before their owning CPU allocations.
    !-----------------------------------------------------------------------------------------------
    Use xnet_controls, Only: gpu_queue
    Implicit None
    If ( allocated(t) ) Then
      !XDIR XEXIT_DATA XASYNC(gpu_queue) &
      !XDIR XDELETE(tdel,tdel_next,tdel_old,t,tt,to,t9,t9t,t9o,t9dot) &
      !XDIR XDELETE(rho,rhot,rhoo,ye,yet,yeo,cv,etae,detaedt9,nt,ntt,nto,ints,intso) &
      !XDIR XDELETE(tstart,tstop,tdelstart,nstart,t9start,rhostart,yestart) &
      !XDIR XDELETE(nh,th,t9h,rhoh,yeh)
      !XDIR XWAIT(gpu_queue)
    EndIf
    If ( allocated(t) ) Deallocate (t)
    If ( allocated(tt) ) Deallocate (tt)
    If ( allocated(to) ) Deallocate (to)
    If ( allocated(tdel) ) Deallocate (tdel)
    If ( allocated(tdel_next) ) Deallocate (tdel_next)
    If ( allocated(tdel_old) ) Deallocate (tdel_old)
    If ( allocated(t9t) ) Deallocate (t9t)
    If ( allocated(rhot) ) Deallocate (rhot)
    If ( allocated(yet) ) Deallocate (yet)
    If ( allocated(t9) ) Deallocate (t9)
    If ( allocated(rho) ) Deallocate (rho)
    If ( allocated(ye) ) Deallocate (ye)
    If ( allocated(t9o) ) Deallocate (t9o)
    If ( allocated(rhoo) ) Deallocate (rhoo)
    If ( allocated(yeo) ) Deallocate (yeo)
    If ( allocated(t9dot) ) Deallocate (t9dot)
    If ( allocated(cv) ) Deallocate (cv)
    If ( allocated(etae) ) Deallocate (etae)
    If ( allocated(detaedt9) ) Deallocate (detaedt9)
    If ( allocated(nt) ) Deallocate (nt)
    If ( allocated(ntt) ) Deallocate (ntt)
    If ( allocated(nto) ) Deallocate (nto)
    If ( allocated(ints) ) Deallocate (ints)
    If ( allocated(intso) ) Deallocate (intso)
    If ( allocated(nh) ) Deallocate (nh)
    If ( allocated(nstart) ) Deallocate (nstart)
    If ( allocated(tstart) ) Deallocate (tstart)
    If ( allocated(tstop) ) Deallocate (tstop)
    If ( allocated(tdelstart) ) Deallocate (tdelstart)
    If ( allocated(t9start) ) Deallocate (t9start)
    If ( allocated(rhostart) ) Deallocate (rhostart)
    If ( allocated(yestart) ) Deallocate (yestart)
    If ( allocated(th) ) Deallocate (th)
    If ( allocated(t9h) ) Deallocate (t9h)
    If ( allocated(rhoh) ) Deallocate (rhoh)
    If ( allocated(yeh) ) Deallocate (yeh)
    Return
  End Subroutine conditions_finalize

End Module xnet_conditions
