!***************************************************************************************************
! xnet_conditions.F90
! Thermodynamic state, timestep bookkeeping, trajectory history storage, and interpolation.
!
! Manages per-zone time, timestep, temperature (T9 [GK]), density (rho [g/cm^3]), electron
! fraction (Ye), EOS derivatives, and thermodynamic trajectory histories across the active worker
! banks (1:nzevolve). The standalone driver allocates full trajectories (history_capacity = nhmx),
! whereas constant-condition library burns allocate two-point endpoint histories (history_capacity = 2).
!***************************************************************************************************

#include "xnet_macros.fh"

Module xnet_conditions
  Use xnet_types, Only: dp
  Implicit None

  !-------------------------------------------------------------------------------------------------
  ! Current, trial, and previous time and thermodynamic state (1:nzevolve)
  !-------------------------------------------------------------------------------------------------
  Real(dp), Allocatable :: t(:)        ! Time at the beginning of the current timestep [s]
  Real(dp), Allocatable :: tt(:)       ! Trial time at the end of the current timestep [s]
  Real(dp), Allocatable :: to(:)       ! Time at the beginning of the previous timestep [s]
  Real(dp), Allocatable :: tdel(:)     ! Trial duration of the current timestep [s]
  Real(dp), Allocatable :: tdel_next(:) ! Integrator estimate of the next timestep duration [s]
  Real(dp), Allocatable :: tdel_old(:) ! Accepted duration of the previous timestep [s]

  Real(dp), Allocatable :: t9t(:), rhot(:), yet(:) ! Trial temperature [GK], density [g/cm^3], and Ye
  Real(dp), Allocatable :: t9(:),  rho(:),  ye(:)  ! Current temperature [GK], density [g/cm^3], and Ye
  Real(dp), Allocatable :: t9o(:), rhoo(:), yeo(:) ! Previous temperature [GK], density [g/cm^3], and Ye
  Real(dp), Allocatable :: t9dot(:)    ! Trial time derivative of temperature dT9/dt [GK/s]

  Real(dp), Allocatable :: cv(:)       ! Specific heat at constant volume [MeV/nucleon/GK]
  Real(dp), Allocatable :: etae(:)     ! Degeneracy parameter: electron chemical potential / k_B T
  Real(dp), Allocatable :: detaedt9(:) ! Temperature derivative d(etae)/dT9 [GK^-1]

  Integer, Allocatable :: nt(:)        ! Trajectory history index at current time
  Integer, Allocatable :: ntt(:)       ! Trajectory history index at trial time
  Integer, Allocatable :: nto(:)       ! Trajectory history index at previous time
  Integer, Allocatable :: ints(:)      ! Species index governing the current timestep
  Integer, Allocatable :: intso(:)     ! Species index governing the previous timestep

  !-------------------------------------------------------------------------------------------------
  ! Thermodynamic trajectory histories (history_capacity, nzevolve)
  !-------------------------------------------------------------------------------------------------
  Integer, Parameter    :: nhmx = 50000 ! Maximum trajectory history points for standalone runs
  Integer, Allocatable  :: nh(:)        ! Number of populated trajectory points per zone
  Integer, Allocatable  :: nstart(:)    ! Starting trajectory index at tstart
  Real(dp), Allocatable :: tstart(:), tstop(:), tdelstart(:)
  Real(dp), Allocatable :: t9start(:), rhostart(:), yestart(:)
  Real(dp), Allocatable :: th(:,:), t9h(:,:), rhoh(:,:), yeh(:,:)

  Interface t9rhofind
    Module Procedure t9rhofind_scalar
    Module Procedure t9rhofind_vector
  End Interface t9rhofind

Contains

  !=================================================================================================
  ! Workspace Lifecycle
  !=================================================================================================

  Subroutine conditions_initialize(history_capacity)
    !-----------------------------------------------------------------------------------------------
    ! Allocate and zero thermodynamic state and trajectory history arrays for 1:nzevolve zones,
    ! then establish persistent device mappings.
    !-----------------------------------------------------------------------------------------------
    Use xnet_controls, Only: nzevolve, gpu_queue
    Implicit None

    ! Input arguments
    Integer, Intent(in) :: history_capacity

    Allocate (tdel(nzevolve),tdel_next(nzevolve),tdel_old(nzevolve), &
      & t(nzevolve),tt(nzevolve),to(nzevolve), &
      & t9(nzevolve),t9t(nzevolve),t9o(nzevolve),t9dot(nzevolve), &
      & rho(nzevolve),rhot(nzevolve),rhoo(nzevolve), &
      & ye(nzevolve),yet(nzevolve),yeo(nzevolve), &
      & cv(nzevolve),etae(nzevolve),detaedt9(nzevolve), &
      & nt(nzevolve),ntt(nzevolve),nto(nzevolve),ints(nzevolve),intso(nzevolve))
    tdel      = 0.0_dp
    tdel_next = 0.0_dp
    tdel_old  = 0.0_dp
    t         = 0.0_dp
    tt        = 0.0_dp
    to        = 0.0_dp
    t9        = 0.0_dp
    t9t       = 0.0_dp
    t9o       = 0.0_dp
    t9dot     = 0.0_dp
    rho       = 0.0_dp
    rhot      = 0.0_dp
    rhoo      = 0.0_dp
    ye        = 0.0_dp
    yet       = 0.0_dp
    yeo       = 0.0_dp
    cv        = 0.0_dp
    etae      = 0.0_dp
    detaedt9  = 0.0_dp
    nt        = 0
    ntt       = 0
    nto       = 0
    ints      = 0
    intso     = 0

    Allocate (nstart(nzevolve),tstart(nzevolve),tstop(nzevolve),tdelstart(nzevolve), &
      & t9start(nzevolve),rhostart(nzevolve),yestart(nzevolve),nh(nzevolve), &
      & th(history_capacity,nzevolve),t9h(history_capacity,nzevolve), &
      & rhoh(history_capacity,nzevolve),yeh(history_capacity,nzevolve))
    nstart    = 0
    tstart    = 0.0_dp
    tstop     = 0.0_dp
    tdelstart = 0.0_dp
    t9start   = 0.0_dp
    rhostart  = 0.0_dp
    yestart   = 0.0_dp
    nh        = 0
    th        = 0.0_dp
    t9h       = 0.0_dp
    rhoh      = 0.0_dp
    yeh       = 0.0_dp

    !XDIR XENTER_DATA XASYNC(gpu_queue) &
    !XDIR XCOPYIN(tdel,tdel_next,tdel_old,t,tt,to,t9,t9t,t9o,t9dot) &
    !XDIR XCOPYIN(rho,rhot,rhoo,ye,yet,yeo,cv,etae,detaedt9,nt,ntt,nto,ints,intso) &
    !XDIR XCOPYIN(tstart,tstop,tdelstart,nstart,t9start,rhostart,yestart) &
    !XDIR XCOPYIN(nh,th,t9h,rhoh,yeh)
    !XDIR XWAIT(gpu_queue)

    Return
  End Subroutine conditions_initialize

  Subroutine conditions_finalize
    !-----------------------------------------------------------------------------------------------
    ! Release persistent device mappings before deallocating CPU condition and history arrays.
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
    If ( allocated(t) )         Deallocate (t)
    If ( allocated(tt) )        Deallocate (tt)
    If ( allocated(to) )        Deallocate (to)
    If ( allocated(tdel) )      Deallocate (tdel)
    If ( allocated(tdel_next) ) Deallocate (tdel_next)
    If ( allocated(tdel_old) )  Deallocate (tdel_old)
    If ( allocated(t9t) )       Deallocate (t9t)
    If ( allocated(rhot) )      Deallocate (rhot)
    If ( allocated(yet) )       Deallocate (yet)
    If ( allocated(t9) )        Deallocate (t9)
    If ( allocated(rho) )       Deallocate (rho)
    If ( allocated(ye) )        Deallocate (ye)
    If ( allocated(t9o) )       Deallocate (t9o)
    If ( allocated(rhoo) )      Deallocate (rhoo)
    If ( allocated(yeo) )       Deallocate (yeo)
    If ( allocated(t9dot) )     Deallocate (t9dot)
    If ( allocated(cv) )        Deallocate (cv)
    If ( allocated(etae) )      Deallocate (etae)
    If ( allocated(detaedt9) )  Deallocate (detaedt9)
    If ( allocated(nt) )        Deallocate (nt)
    If ( allocated(ntt) )       Deallocate (ntt)
    If ( allocated(nto) )       Deallocate (nto)
    If ( allocated(ints) )      Deallocate (ints)
    If ( allocated(intso) )     Deallocate (intso)
    If ( allocated(nh) )        Deallocate (nh)
    If ( allocated(nstart) )    Deallocate (nstart)
    If ( allocated(tstart) )    Deallocate (tstart)
    If ( allocated(tstop) )     Deallocate (tstop)
    If ( allocated(tdelstart) ) Deallocate (tdelstart)
    If ( allocated(t9start) )   Deallocate (t9start)
    If ( allocated(rhostart) )  Deallocate (rhostart)
    If ( allocated(yestart) )   Deallocate (yestart)
    If ( allocated(th) )        Deallocate (th)
    If ( allocated(t9h) )       Deallocate (t9h)
    If ( allocated(rhoh) )      Deallocate (rhoh)
    If ( allocated(yeh) )       Deallocate (yeh)

    Return
  End Subroutine conditions_finalize

  !=================================================================================================
  ! Trajectory Interpolation
  !=================================================================================================

  Subroutine t9rhofind_scalar(kstep,tf,nf,t9f,rhof,ns,ts,t9s,rhos)
    !-----------------------------------------------------------------------------------------------
    ! Interpolate temperature t9f [GK] and density rhof [g/cm^3] at target time tf [s] from the
    ! trajectory history (ts, t9s, rhos) of length ns for a single zone, returning the bracketing
    ! upper trajectory index nf.
    !-----------------------------------------------------------------------------------------------
    Use, Intrinsic :: iso_fortran_env, Only: lun_stdout=>output_unit
    Use xnet_types, Only: dp
    Implicit None
    !XDIR XROUTINE_SEQ

    ! Input arguments
    Integer, Intent(in) :: kstep, ns
    Real(dp), Intent(in) :: tf, ts(ns), t9s(ns), rhos(ns)

    ! Output arguments
    Integer, Intent(out) :: nf
    Real(dp), Intent(out) :: t9f, rhof

    ! Local variables
    Real(dp) :: dt, rdt, dt9, drho
    Integer :: n

    If ( ns == 1 ) Then
      t9f  = t9s(1)
      rhof = rhos(1)
      nf   = 1
    Else
      Do n = 1, ns
        If ( tf <= ts(n) ) Exit
      EndDo
      nf = n
      If ( n > 1 .and. n <= ns ) Then
        rdt  = 1.0_dp / (ts(n) - ts(n-1))
        dt   = tf - ts(n-1)
        dt9  = t9s(n) - t9s(n-1)
        drho = rhos(n) - rhos(n-1)
        t9f  = dt * rdt * dt9 + t9s(n-1)
        rhof = dt * rdt * drho + rhos(n-1)
      ElseIf ( n == 1 ) Then
        t9f  = t9s(1)
        rhof = rhos(1)
      Else
        t9f  = t9s(ns)
        rhof = rhos(ns)
        Write(lun_stdout,*) 'Time beyond thermodynamic range',tf,' >',ts(ns)
      EndIf
    EndIf

    Return
  End Subroutine t9rhofind_scalar

  Subroutine t9rhofind_vector(kstep,tf,nf,t9f,rhof,mask_in)
    !-----------------------------------------------------------------------------------------------
    ! Batched trajectory interpolation across the zone bank of the calling worker (zb_lo:zb_hi).
    !-----------------------------------------------------------------------------------------------
    Use xnet_controls, Only: zb_lo, zb_hi, lzactive, gpu_queue
    Use xnet_types, Only: dp
    Implicit None

    ! Input arguments
    Integer, Intent(in) :: kstep
    Real(dp), Intent(in) :: tf(zb_lo:zb_hi)

    ! Input/Output arguments
    Integer, Intent(inout) :: nf(zb_lo:zb_hi)
    Real(dp), Intent(inout) :: t9f(zb_lo:zb_hi), rhof(zb_lo:zb_hi)

    ! Optional arguments
    Logical, Optional, Target, Intent(in) :: mask_in(zb_lo:zb_hi)

    ! Local variables
    Integer :: izb
    Logical, Pointer :: mask(:)

    If ( present(mask_in) ) Then
      mask(zb_lo:) => mask_in
    Else
      mask(zb_lo:) => lzactive(zb_lo:zb_hi)
    EndIf
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

End Module xnet_conditions
