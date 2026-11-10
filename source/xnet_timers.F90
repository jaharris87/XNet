!***************************************************************************************************
! xnet_timers.F90
! Per-thread wall-clock accumulators and summary reporting for XNet execution stages.
!***************************************************************************************************

Module xnet_timers
  Use xnet_types, Only: dp
  Implicit None

  !-------------------------------------------------------------------------------------------------
  ! Per-thread cumulative wall-clock timers [s]
  !-------------------------------------------------------------------------------------------------
  Real(dp) :: timer_burner  = 0.0_dp ! Total burner execution time
  Real(dp) :: timer_xnet    = 0.0_dp ! Evolution interval in full_net, before final_output
  Real(dp) :: timer_setup   = 0.0_dp ! Data loading or preprocessing time
  Real(dp) :: timer_csect   = 0.0_dp ! Reaction cross-section / rate evaluation time
  Real(dp) :: timer_deriv   = 0.0_dp ! ODE right-hand side derivative evaluation time
  Real(dp) :: timer_jacob   = 0.0_dp ! Jacobian construction time
  Real(dp) :: timer_decmp   = 0.0_dp ! LU decomposition time
  Real(dp) :: timer_bksub   = 0.0_dp ! LU backsubstitution time
  Real(dp) :: timer_nraph   = 0.0_dp ! Newton-Raphson iteration work within implicit solves
  Real(dp) :: timer_tstep   = 0.0_dp ! Implicit timestep solves and retries
  Real(dp) :: timer_solve   = 0.0_dp ! Linear system solution time
  Real(dp) :: timer_scrn    = 0.0_dp ! Screening factors, after plasma-state preparation
  Real(dp) :: timer_prescrn = 0.0_dp ! Plasma-state preparation through eos_screen
  Real(dp) :: timer_eos     = 0.0_dp ! Thermodynamic updates through update_eos
  Real(dp) :: timer_nse     = 0.0_dp ! Total NSE solver time
  Real(dp) :: timer_nseinit = 0.0_dp ! NSE initialization time
  Real(dp) :: timer_nsesolv = 0.0_dp ! NSE root-finding time
  Real(dp) :: timer_nsenrap = 0.0_dp ! NSE Newton-Raphson iteration time
  Real(dp) :: timer_nsels   = 0.0_dp ! NSE line-search time
  Real(dp) :: timer_nseeval = 0.0_dp ! NSE residual evaluation time
  Real(dp) :: timer_nsescrn = 0.0_dp ! NSE screening evaluation time
  Real(dp) :: timer_output  = 0.0_dp ! Timed sections of ts_output and final_output
  Real(dp) :: start_timer   = 0.0_dp ! Scratch timestamp at the beginning of a timed interval
  Real(dp) :: stop_timer    = 0.0_dp ! Scratch timestamp at the end of a timed interval
#ifdef XNET_OMP
  !$omp threadprivate(timer_burner,timer_xnet,timer_setup,timer_csect,timer_deriv,timer_jacob,timer_decmp, &
  !$omp   timer_bksub,timer_nraph,timer_tstep,timer_solve,timer_scrn,timer_prescrn,timer_eos,timer_output, &
  !$omp   timer_nse,timer_nseinit,timer_nsesolv,timer_nsenrap,timer_nsels,timer_nseeval,timer_nsescrn, &
  !$omp   start_timer,stop_timer)
#endif

Contains

  Function xnet_wtime()
    !-----------------------------------------------------------------------------------------------
    ! Return the current wall-clock time in seconds from the intrinsic system_clock.
    !-----------------------------------------------------------------------------------------------
    Use xnet_types, Only: i8
    Implicit None

    ! Function result
    Real(dp) :: xnet_wtime

    ! Local variables
    Integer(i8) :: clock_read, clock_rate, clock_max

    Call system_clock(clock_read,clock_rate,clock_max)
    xnet_wtime = real(clock_read,dp) / real(clock_rate,dp)

    Return
  End Function xnet_wtime

  Subroutine reset_timers
    !-----------------------------------------------------------------------------------------------
    ! Reset evolution, setup and NSE timers on the calling thread.
    ! The outer burner timer and output timer retain their current totals.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    timer_xnet    = 0.0_dp
    timer_setup   = 0.0_dp
    timer_csect   = 0.0_dp
    timer_deriv   = 0.0_dp
    timer_jacob   = 0.0_dp
    timer_decmp   = 0.0_dp
    timer_bksub   = 0.0_dp
    timer_nraph   = 0.0_dp
    timer_tstep   = 0.0_dp
    timer_solve   = 0.0_dp
    timer_scrn    = 0.0_dp
    timer_prescrn = 0.0_dp
    timer_eos     = 0.0_dp
    timer_nse     = 0.0_dp
    timer_nseinit = 0.0_dp
    timer_nsesolv = 0.0_dp
    timer_nsenrap = 0.0_dp
    timer_nsels   = 0.0_dp
    timer_nseeval = 0.0_dp
    timer_nsescrn = 0.0_dp

    Return
  End Subroutine reset_timers

  Subroutine write_timers_summary(lun_out)
    !-----------------------------------------------------------------------------------------------
    ! Write a summary table of cumulative XNet timers to logical unit lun_out.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Input arguments
    Integer, Intent(in) :: lun_out

    ! Local variables
    Integer, Parameter :: ntimer_write = 14
    Character(10), Parameter :: timer_desc(ntimer_write) = [ Character(10) :: &
      & 'Total','TimeStep','NewtRaph','Solver','Decomp', &
      & 'BkSub','Jacobian','Deriv','CrossSect','Screening', &
      & 'PreScreen','EOS','Setup','Output' ]
    Real(dp) :: timer_write(ntimer_write)
    Integer :: i

    timer_write = &
      & [ timer_xnet,timer_tstep,timer_nraph,timer_solve,timer_decmp, &
      &   timer_bksub,timer_jacob,timer_deriv,timer_csect,timer_scrn, &
      &   timer_prescrn,timer_eos,timer_setup,timer_output ]

    Write(lun_out,"(a)") 'Timers Summary: '
    Write(lun_out,"(8x,a10,es10.3)") (timer_desc(i),timer_write(i),i=1,ntimer_write)

    Return
  End Subroutine write_timers_summary

End Module xnet_timers
