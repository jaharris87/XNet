!***************************************************************************************************
! xnet_evolve.F90
! Shared evolution initialization, finalization, and batch reaction-network evolution for XNet.
!
! Shared by the standalone driver (net.F90) and the embedded library API (xnet_api.F90).
! Initialization and finalization appear first; full_net advances active zones from tstart to tstop using
! Backward Euler (isolv = 1) or Gear BDF (isolv = 3), tracking nuclear energy generation and
! weak-reaction neutrino losses.
!
! Per-zone integration status its(izb):
!   -1  Inactive zone, or active zone that has already reached tstop(izb).
!    0  Active zone; current integration step converged.
!    1  Integrator failed to converge on the current step after internal retries.
!    2  Active zone halted after an integrator convergence failure (standalone path).
!
! Failure handling in full_net:
! - When optional ierr_out is present (library API): reports evolve_integrator_failure or
!   evolve_step_limit (and the workspace index in failed_zone) to the caller without writing
!   failure dump files or terminating the process.
! - When ierr_out is omitted (standalone driver): writes failure diagnostics and ab_fail_*/th_fail_*
!   reproducer files before terminating via xnet_terminate.
!***************************************************************************************************

#include "xnet_macros.fh"

Module xnet_evolve
  Implicit None
  Private

  !-------------------------------------------------------------------------------------------------
  ! Public evolution completion status codes
  !-------------------------------------------------------------------------------------------------
  Integer, Parameter, Public :: evolve_success            = 0 ! All active zones reached tstop.
  Integer, Parameter, Public :: evolve_integrator_failure = 1 ! Integrator reported a convergence/timestep failure.
  Integer, Parameter, Public :: evolve_step_limit         = 2 ! Active zone exhausted kstmx steps before tstop.

  !-------------------------------------------------------------------------------------------------
  ! Private per-zone integrator status values (shared with solve_be and solve_bdf)
  !-------------------------------------------------------------------------------------------------
  Integer, Parameter :: zone_stopped     = -1 ! Inactive or at its stop time
  Integer, Parameter :: zone_converged   =  0 ! Current step succeeded
  Integer, Parameter :: zone_step_failed =  1 ! Integrator exhausted retries
  Integer, Parameter :: zone_failed      =  2 ! Failed zone removed from standalone solve

  !-------------------------------------------------------------------------------------------------
  ! Public procedures
  !-------------------------------------------------------------------------------------------------
  Public :: initialize_evolve
  Public :: finalize_evolve
  Public :: full_net

Contains

  !=================================================================================================
  ! Evolution Initialization and Finalization
  !
  ! The frontends first call read_network_data (reaction_data in xnet_data.F90). Standalone logs
  ! its data description before initialize_evolve reads Jacobian/matching data and prepares the
  ! evolution engine. These calls run once per initialized instance, not once per batch.
  !
  ! finalize_evolve releases the engine, including the selected Jacobian provider. The frontends
  ! then call finalize_network_data and controls_finalize. Network tables and controls outlive
  ! the workspaces that use them; GPU resources remain available until all mappings are removed.
  !=================================================================================================

  Subroutine initialize_evolve(data_dir,nhistory,map_output)
    !-----------------------------------------------------------------------------------------------
    ! Read Jacobian/matching data and initialize rates, EOS, integrator, NSE and reusable zone
    ! storage. Nuclear/reaction tables and controls must already be loaded. Each owner maps its
    ! own arrays. Call outside parallel regions with the worker team configured by the frontend.
    !
    ! data_dir    Directory containing the preprocessed network.
    ! nhistory    Allocated history points per zone: nhmx for standalone trajectories, or
    !             api_history_points for the library's start/end conditions.
    ! map_output  Map configured condensed-output species: always in standalone, and only when
    !             histories are enabled in the API. Lookup precedes NSE diagnostics as before.
    !-----------------------------------------------------------------------------------------------
    Use xnet_abundances, Only: abundances_initialize
    Use xnet_conditions, Only: conditions_initialize
    Use xnet_controls, Only: isolv
    Use xnet_eos, Only: eos_initialize
    Use xnet_flux, Only: flux_init
    Use xnet_integrate_be, Only: be_init
    Use xnet_integrate_bdf, Only: bdf_init
    Use xnet_jacobian, Only: read_jacobian_data
    Use xnet_match, Only: read_match_data
    Use xnet_nnu, Only: nnu_initialize
    Use xnet_nse, Only: nse_initialize
    Use xnet_output, Only: map_output_nuc
    Use xnet_screening, Only: screening_init
    Implicit None

    ! Input arguments
    Character(*), Intent(in) :: data_dir
    Integer, Intent(in) :: nhistory
    Logical, Intent(in) :: map_output

    Call read_jacobian_data(data_dir)
    Call read_match_data(data_dir)
    Call screening_init
    Call flux_init
    Call eos_initialize
    If ( isolv == 1 ) Call be_init
    If ( isolv == 3 ) Call bdf_init
    If ( map_output ) Call map_output_nuc
    Call nse_initialize
    Call abundances_initialize
    Call conditions_initialize(nhistory)
    Call nnu_initialize(nhistory)

    Return
  End Subroutine initialize_evolve

  Subroutine finalize_evolve
    !-----------------------------------------------------------------------------------------------
    ! Release the evolution engine's integrator, NSE/EOS, Jacobian, rate-evaluation and zone
    ! workspace. The selected Jacobian provider releases its own arrays and any library-owned
    ! factors. Loaded network tables remain for finalize_network_data; controls and GPU resources
    ! must remain available until both routines finish. Call outside parallel regions, after all
    ! workers finish, with the same team used during initialization.
    !-----------------------------------------------------------------------------------------------
    Use xnet_abundances, Only: abundances_finalize
    Use xnet_conditions, Only: conditions_finalize
    Use xnet_eos, Only: eos_finalize
    Use xnet_flux, Only: flux_finalize
    Use xnet_integrate_be, Only: be_finalize
    Use xnet_integrate_bdf, Only: bdf_finalize
    Use xnet_jacobian, Only: jacobian_finalize
    Use xnet_match, Only: match_finalize
    Use xnet_nnu, Only: nnu_history_finalize
    Use xnet_nse, Only: nse_finalize
    Use xnet_screening, Only: screening_finalize
    Implicit None

    Call be_finalize
    Call bdf_finalize
    Call nse_finalize
    Call eos_finalize
    Call jacobian_finalize
    Call screening_finalize
    Call flux_finalize
    Call match_finalize
    Call nnu_history_finalize
    Call abundances_finalize
    Call conditions_finalize

    Return
  End Subroutine finalize_evolve

  !=================================================================================================
  ! Batch Reaction-Network Evolution
  !=================================================================================================

  Subroutine full_net(kstep,denu,ierr_out,failed_zone)
    !-----------------------------------------------------------------------------------------------
    ! Evolve active zones in the calling worker bank (lzactive(zb_lo:zb_hi)) from tstart to tstop.
    ! The caller supplies the starting composition, thermodynamic state/history, active mask,
    ! and any output files required by itsout. On success, y, t, t9, rho and ye hold the final state.
    !
    ! kstep        Largest step count at which a zone finished (at least 1).
    ! denu         Time-integrated weak-reaction neutrino energy loss [erg/g], by workspace slot.
    ! ierr_out     Optional completion status; presence selects caller-handled failure.
    ! failed_zone  Optional workspace slot of the first reported failure, or zero.
    !
    ! Energy workspace (per zone):
    !   enm       Current nuclear mass-excess energy [erg/g].
    !   en0       Initial mass-excess energy [erg/g].
    !   enold     Mass-excess energy before the current step [erg/g].
    !   enb       Binding energy [erg/g], required by benuc but otherwise unused here.
    !   delta_en  Change in mass-excess energy since the start [erg/g].
    !   edot      Nuclear energy generation rate, -(enm-enold)/tdel [erg/g/s].
    !   sqnu      Weak-reaction neutrino energy loss rate [erg/g/s].
    ! lzsolve marks zones still integrating; lzoutput also includes zones finishing this step.
    !-----------------------------------------------------------------------------------------------
    Use nuclear_data, Only: ny, nname, aa, benuc
    Use reaction_data, Only: enudot
    Use xnet_abundances, Only: yo, y, yt, ystart, ydot
    Use xnet_conditions, Only: t, to, tt, tdel, tdel_old, tdel_next, t9, t9o, t9t, t9dot, &
      & rho, rhoo, rhot, yeo, ye, yet, nt, nto, ntt, tstart, tstop, t9start, rhostart, yestart
    Use xnet_controls, Only: idiag, iheat, isolv, kstmx, kmon, ktot, lun_diag, &
      & lzactive, szbatch, zb_lo, zb_hi, gpu_queue
    Use xnet_integrate, Only: timestep
    Use xnet_integrate_be, Only: solve_be
    Use xnet_integrate_bdf, Only: solve_bdf
    Use xnet_output, Only: final_output, ts_output
    Use xnet_timers, Only: xnet_wtime, start_timer, stop_timer, timer_xnet
    Use xnet_types, Only: dp
    Implicit None

    ! Output arguments
    Integer, Intent(out) :: kstep
    Real(dp), Intent(out) :: denu(zb_lo:zb_hi)

    ! Optional output arguments (present for embedded API calls; omitted for standalone driver)
    Integer, Optional, Intent(out) :: ierr_out, failed_zone

    ! Local variables
    Real(dp) :: enm(zb_lo:zb_hi), enb(zb_lo:zb_hi)
    Real(dp) :: enold(zb_lo:zb_hi), en0(zb_lo:zb_hi)
    Real(dp) :: delta_en(zb_lo:zb_hi), edot(zb_lo:zb_hi)
    Real(dp) :: sqnu(zb_lo:zb_hi)
    Integer :: k, izb, izone
    Integer :: its(zb_lo:zb_hi), zone_final_step(zb_lo:zb_hi)
    Integer :: failure_status, failure_zone
    Logical :: lzsolve(zb_lo:zb_hi), lzoutput(zb_lo:zb_hi)

    start_timer = xnet_wtime()
    timer_xnet = timer_xnet - start_timer

    ! 1. Initialize per-zone masks, step statuses, and device scratch
    kstep          = 0
    failure_status = evolve_success
    failure_zone   = 0
    If ( present(ierr_out) )    ierr_out    = evolve_success
    If ( present(failed_zone) ) failed_zone = 0

    zone_final_step = 0
    lzsolve         = lzactive(zb_lo:zb_hi)
    lzoutput        = lzsolve
    Do izb = zb_lo, zb_hi
      If ( lzsolve(izb) ) Then
        its(izb) = zone_converged
      Else
        its(izb) = zone_stopped
      EndIf
    EndDo

    !XDIR XENTER_DATA XASYNC(gpu_queue) &
    !XDIR XCOPYIN(its,zone_final_step,lzsolve,lzoutput) &
    !XDIR XCREATE(enm,enb,enold,en0,delta_en,edot,denu,sqnu)

    ! 2. Evaluate initial nuclear binding energy and initialize working state
    ! Pass the explicit worker slice y(:,zb_lo:zb_hi) to match the zb_lo:zb_hi dummy bounds.
    Call benuc(y(:,zb_lo:zb_hi),enb,enm)

    !XDIR XLOOP_OUTER(1) XASYNC(gpu_queue) &
    !XDIR XPRESENT(kmon,ktot,tdel,tdel_old,tdel_next,nt,nto,ntt) &
    !XDIR XPRESENT(t9,t9o,t9t,rho,rhoo,rhot,t,to,tt,ye,yeo,yet,y,yo,yt) &
    !XDIR XPRESENT(enm,enb,enold,en0,delta_en,edot,denu,sqnu)
    Do izb = zb_lo, zb_hi
      tdel_old(izb)  = tdel(izb)
      tdel_next(izb) = tdel(izb)
      nto(izb)       = nt(izb)
      ntt(izb)       = nt(izb)
      to(izb)        = t(izb)
      tt(izb)        = t(izb)
      t9o(izb)       = t9(izb)
      t9t(izb)       = t9(izb)
      rhoo(izb)      = rho(izb)
      rhot(izb)      = rho(izb)
      yeo(izb)       = ye(izb)
      yet(izb)       = ye(izb)
      !XDIR XLOOP_INNER(1)
      Do k = 1, ny
        yo(k,izb) = y(k,izb)
        yt(k,izb) = y(k,izb)
      EndDo
      !XDIR XLOOP_INNER(1)
      Do k = 1, 5
        kmon(k,izb) = 0
        ktot(k,izb) = 0
      EndDo
      enb(izb)      = 0.0_dp
      enold(izb)    = 0.0_dp
      en0(izb)      = enm(izb)
      delta_en(izb) = 0.0_dp
      edot(izb)     = 0.0_dp
      denu(izb)     = 0.0_dp
      sqnu(izb)     = 0.0_dp
    EndDo

    ! 3. Write initial time-series snapshot (kstep = 0) and diagnostic start state
    Call ts_output(0,delta_en,edot,sqnu)
    If ( idiag >= 0 ) Then
      ! Device-resident API burns populate start arrays on the accelerator; refresh host before printing.
      !XDIR XUPDATE XWAIT(gpu_queue) &
      !XDIR XHOST(tstart,t9start,rhostart,yestart,ystart)
      Do izb = zb_lo, zb_hi
        If ( lzactive(izb) ) Then
          izone = izb + szbatch - zb_lo
          Write(lun_diag,"(a,2i6,4es14.7)") &
            & 'Start',izone,kstep,tstart(izb),t9start(izb),rhostart(izb),yestart(izb)
          Write(lun_diag,"(4(a5,es14.7,1x))") (nname(k),aa(k)*ystart(k,izb),k=1,ny)
        EndIf
      EndDo
    EndIf

    ! 4. Evolve active zones over at most kstmx outer integration steps
    Do kstep = 1, kstmx

      ! Estimate trial timestep for zones still solving
      Call timestep(kstep,mask_in = lzsolve)

      ! Advance one implicit step with the selected integrator
      Select Case (isolv)
      Case (3)
        Call solve_bdf(kstep,its)
      Case Default
        Call solve_be(kstep,its)
      End Select

      ! For API callers, halt the batch immediately if any active zone reported integrator failure
      If ( present(ierr_out) ) Then
        !XDIR XUPDATE XWAIT(gpu_queue) &
        !XDIR XHOST(its)
        Do izb = zb_lo, zb_hi
          If ( lzactive(izb) .and. its(izb) > 0 ) Then
            failure_status = evolve_integrator_failure
            failure_zone   = izb
            Exit
          EndIf
        EndDo
        If ( failure_status /= evolve_success ) Exit
      EndIf

      ! Log per-step diagnostic summary when requested
      If ( idiag >= 1 ) Then
        !XDIR XUPDATE XWAIT(gpu_queue) &
        !XDIR XHOST(its,t,tdel,t9o,t9,t9dot,rho,ye,yo,y,ydot)
        Do izb = zb_lo, zb_hi
          izone = izb + szbatch - zb_lo
          If ( its(izb) == zone_converged ) Then
            Write(lun_diag,"(2(a,i5),5es14.7)") &
              & 'KStep ',kstep,' Zone ',izone,t(izb),tdel(izb),t9(izb),rho(izb),ye(izb)
            If ( idiag >= 3 ) Then
              Write(lun_diag,"(a8)") 'delta Y'
              Write(lun_diag,"(8x,a5,4es12.4)") &
                & (nname(k),y(k,izb),yo(k,izb),(y(k,izb)-yo(k,izb)),(tdel(izb)*ydot(k,izb)),k=1,ny)
              If ( iheat > 0 ) Write(lun_diag,"(8x,a5,4es12.4)") &
                & 'T9',t9(izb),t9o(izb),t9(izb)-t9o(izb),tdel(izb)*t9dot(izb)
            EndIf
          ElseIf ( its(izb) == zone_step_failed ) Then
            Write(lun_diag,"(a,2(i5,a))") 'KStep ',kstep,' Zone ',izone,' Inter!!!'
          EndIf
        EndDo
      EndIf

      ! Update per-zone solve and output masks for the completed step
      !XDIR XLOOP_OUTER(1) XASYNC(gpu_queue) &
      !XDIR XPRESENT(enm,enold) &
      !XDIR XPRESENT(its,t,tstop,zone_final_step,lzsolve,lzoutput)
      Do izb = zb_lo, zb_hi
        If ( its(izb) == zone_converged ) Then
          enold(izb) = enm(izb)
          ! Zone reached stop time: still emit ts_output for this final step, then stop solving
          If ( t(izb) >= tstop(izb) ) Then
            zone_final_step(izb) = kstep
            its(izb)             = zone_stopped
            lzsolve(izb)         = .false.
          EndIf
        ElseIf ( its(izb) == zone_step_failed ) Then
          its(izb)      = zone_failed
          lzsolve(izb)  = .false.
          lzoutput(izb) = .false.
        ElseIf ( its(izb) < 0 ) Then
          lzsolve(izb)  = .false.
          lzoutput(izb) = .false.
        EndIf
      EndDo

      ! Compute nuclear energy release and weak-reaction neutrino energy loss for converged zones
      Call benuc(yt(:,zb_lo:zb_hi),enb,enm,mask_in = lzoutput)
      Call enudot(yt(:,zb_lo:zb_hi),sqnu,mask_in = lzoutput)

      !XDIR XLOOP_OUTER(1) XASYNC(gpu_queue) &
      !XDIR XPRESENT(lzoutput,enm,enold,en0,delta_en,edot,denu,sqnu,tdel)
      Do izb = zb_lo, zb_hi
        If ( lzoutput(izb) ) Then
          delta_en(izb) = enm(izb) - en0(izb)
          edot(izb)     = -(enm(izb) - enold(izb)) / tdel(izb)
          denu(izb)     = denu(izb) + sqnu(izb) * tdel(izb)
        EndIf
      EndDo

      !XDIR XUPDATE XWAIT(gpu_queue) &
      !XDIR XHOST(lzoutput,lzsolve)
      Call ts_output(kstep,delta_en,edot,sqnu,mask_in = lzoutput)

      ! Test if all zones have stopped
      If ( .not. any(lzsolve) ) Exit
    EndDo

    ! 5. Verify that all active zones reached tstop; report or dump any failure
    !XDIR XUPDATE XWAIT(gpu_queue) &
    !XDIR XHOST(its,zone_final_step,t,tdel)
    Do izb = zb_lo, zb_hi
      If ( lzactive(izb) ) Then
        If ( t(izb) < tstop(izb) .or. its(izb) > 0 ) Then
          If ( present(ierr_out) ) Then
            If ( failure_status == evolve_success ) Then
              failure_status = evolve_step_limit
              failure_zone   = izb
            EndIf
            Exit
          EndIf
          Call terminate_on_zone_failure(izb)
        EndIf
      EndIf
    EndDo

    If ( present(ierr_out) )    ierr_out    = failure_status
    If ( present(failed_zone) ) failed_zone = failure_zone
    kstep = max(1,maxval(zone_final_step))

    ! 6. Release device scratch, stop evolution timer, and write final output
    !XDIR XEXIT_DATA XASYNC(gpu_queue) &
    !XDIR XCOPYOUT(denu) &
    !XDIR XDELETE(enm,enb,enold,en0,delta_en,edot,sqnu) &
    !XDIR XDELETE(its,zone_final_step,lzsolve,lzoutput)
    !XDIR XWAIT(gpu_queue)

    stop_timer = xnet_wtime()
    timer_xnet = timer_xnet + stop_timer

    If ( failure_status == evolve_success ) Call final_output(kstep)

    Return
  End Subroutine full_net

  Subroutine terminate_on_zone_failure(izb)
    !-----------------------------------------------------------------------------------------------
    ! Standalone failure handler: report the unreached stop time for workspace slot izb, write
    ! ab_fail_* and th_fail_* reproducer inputs, flush diagnostics, and terminate XNet.
    !-----------------------------------------------------------------------------------------------
    Use nuclear_data, Only: ny, nname
    Use xnet_abundances, Only: yo, xext
    Use xnet_conditions, Only: t, tdel, tstart, tstop, t9start, rhostart, yestart
    Use xnet_controls, Only: lun_diag, lun_stdout, szbatch, zb_lo, zone_id
    Use xnet_output, Only: write_xnet_th, write_xnet_inab
    Use xnet_types, Only: dp
    Use xnet_util, Only: xnet_terminate
    Implicit None

    ! Input arguments
    Integer, Intent(in) :: izb

    ! Local variables
    Real(dp) :: yout(ny+1)
    Character(5) :: nname_out(ny+1)
    Character(128) :: ab_fname, th_fname
    Integer :: izone, nstep_est, ierr

    izone = izb + szbatch - zb_lo
    Write(lun_stdout,"(a,i5,a,3(es12.4,a))") &
      & 'Zone ',izone,' Evolution stopped at time= ',t(izb),' with timestep= ',tdel(izb), &
      & ', stop time= ',tstop(izb),' not reached!'
    nstep_est = int(min((tstop(izb) - t(izb)) / tdel(izb), real(huge(nstep_est),dp)))
    Write(lun_stdout,"(a,i12,a)") 'Approximately ',nstep_est,' more steps needed'

    nname_out(1:ny) = nname(1:ny)
    nname_out(ny+1) = '  Aux'
    yout(1:ny)      = yo(:,izb)
    yout(ny+1)      = xext(izb)

    Write(ab_fname,"(3(a,i3.3))") 'ab_fail_',zone_id(1,izb),'_',zone_id(2,izb),'_',zone_id(3,izb)
    Call write_xnet_inab(ab_fname,ab_fname,nname_out,yout,ierr)

    Write(th_fname,"(3(a,i3.3))") 'th_fail_',zone_id(1,izb),'_',zone_id(2,izb),'_',zone_id(3,izb)
    Call write_xnet_th(th_fname,th_fname,tstart(izb),tstop(izb),t9start(izb),rhostart(izb),yestart(izb),ierr)

    Flush(lun_diag)
    Call xnet_terminate('[XNet] Evolution failed to converge')

    Return
  End Subroutine terminate_on_zone_failure

End Module xnet_evolve
