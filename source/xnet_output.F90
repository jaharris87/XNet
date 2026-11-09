!***************************************************************************************************
! xnet_output.f90 10/18/17
! Shared output-file setup and teardown, per-timestep and final diagnostics, and input-file writers.
!***************************************************************************************************

#include "xnet_macros.fh"

Module xnet_output
  !-------------------------------------------------------------------------------------------------
  ! This module contains data and routines used for output.
  !-------------------------------------------------------------------------------------------------
  Implicit None

  interface write_xnet_th
    module procedure write_xnet_th_history
    module procedure write_xnet_th_point
  end interface write_xnet_th

Contains

  Subroutine open_ts_file(izb,filename,data_description,abundance_source,abundance_description, &
    & thermo_source,thermo_description,status,ierr)
    !-----------------------------------------------------------------------------------------------
    ! Open one binary time-series file and write its six header records.
    ! Metadata fields retain their existing 80-character widths. The caller chooses the filename
    ! and OPEN status. Optional ierr reports open failures; without it, runtime error handling applies.
    !-----------------------------------------------------------------------------------------------
    Use nuclear_data, Only: ny, zz, aa
    Use xnet_controls, Only: lun_ts, descript, kstmx, kitmx, iweak0, iscrn, iconvc, changemx, tolm, tolc, &
      & yacc, ymin, tdel_maxmult, iheat, isolv
    Use xnet_flux, Only: ifl_orig, ifl_term
    Use xnet_match, Only: mflx
    Implicit None

    ! Input arguments
    Integer, Intent(in) :: izb
    Character(*), Intent(in) :: filename, status
    Character(80), Intent(in) :: data_description, abundance_source, abundance_description
    Character(80), Intent(in) :: thermo_source, thermo_description

    ! Optional output argument
    Integer, Optional, Intent(out) :: ierr

    ! Local variables
    Integer :: output_unit

    If ( present(ierr) ) Then
      Open(newunit=output_unit,file=trim(filename),status=status,form='unformatted',action='write',iostat=ierr)
      If ( ierr /= 0 ) Return
    Else
      Open(newunit=output_unit,file=trim(filename),status=status,form='unformatted',action='write')
    EndIf
    lun_ts(izb) = output_unit

    Write(output_unit) descript,data_description
    Write(output_unit) kstmx,kitmx,iweak0,iscrn,iconvc,changemx,tolm,tolc,yacc,ymin,tdel_maxmult,iheat,isolv
    Write(output_unit) abundance_source,abundance_description
    Write(output_unit) thermo_source,thermo_description
    Write(output_unit) ny,zz,aa
    Write(output_unit) mflx,ifl_orig,ifl_term

    Return
  End Subroutine open_ts_file

  Subroutine open_ev_file(izb,filename,status,ierr)
    !-----------------------------------------------------------------------------------------------
    ! Open one ASCII evolution file and write its column header using the selected output nuclei.
    ! The caller chooses the filename and OPEN status. Optional ierr reports open failures.
    !-----------------------------------------------------------------------------------------------
    Use nuclear_data, Only: nname
    Use xnet_controls, Only: lun_ev, nnucout, nnucout_string, inucout
    Implicit None

    ! Input arguments
    Integer, Intent(in) :: izb
    Character(*), Intent(in) :: filename, status

    ! Optional output argument
    Integer, Optional, Intent(out) :: ierr

    ! Local variables
    Character(40) :: header_format
    Integer :: output_unit, i

    If ( present(ierr) ) Then
      Open(newunit=output_unit,file=trim(filename),status=status,action='write',iostat=ierr)
      If ( ierr /= 0 ) Return
    Else
      Open(newunit=output_unit,file=trim(filename),status=status,action='write')
    EndIf
    lun_ev(izb) = output_unit

    header_format = '(a4,a15,5a10,a4)'
    If ( nnucout > 0 ) header_format = '(a4,a15,5a10,'//trim(nnucout_string)//'a9,a4)'
    Write(output_unit,header_format) &
      & 'k ',' Time ',' T(GK) ',' Density ',' dE/dt ',' sqnu ',' Timestep ',(nname(inucout(i)),i=1,nnucout),' It '

    Return
  End Subroutine open_ev_file

  Subroutine close_output_files
    !-----------------------------------------------------------------------------------------------
    ! Close binary and ASCII time-series units in the current worker bank, including partial setup.
    ! Zero marks an unopened slot; valid NEWUNIT values may be negative. Clear slots after closing.
    !-----------------------------------------------------------------------------------------------
    Use xnet_controls, Only: lun_ts, lun_ev, zb_lo, zb_hi
    Implicit None

    ! Local variables
    Integer :: izb

    Do izb = zb_lo, zb_hi
      If ( lun_ts(izb) /= 0 ) Close(lun_ts(izb))
      If ( lun_ev(izb) /= 0 ) Close(lun_ev(izb))
      lun_ts(izb) = 0
      lun_ev(izb) = 0
    EndDo

    Return
  End Subroutine close_output_files

  Subroutine ts_output(kstep,enuc,edot,sqnu,mask_in)
    !-----------------------------------------------------------------------------------------------
    ! The per timestep output routine. If the flag itsout > 0, full_net calls this routine to handle
    ! stepwise output.
    !-----------------------------------------------------------------------------------------------
    Use nuclear_data, Only: ny, aa, nname
    Use xnet_abundances, Only: y
    Use xnet_conditions, Only: rho, t, t9, tdel
    Use xnet_controls, Only: nnucout, nnucout_string, idiag, inucout, itsout, kmon, lun_diag, &
      & lun_ev, lun_stdout, lun_ts, szbatch, zb_lo, zb_hi, lzactive, tid, gpu_queue
    Use xnet_flux, Only: flx, flx_int, flux
    Use xnet_match, Only: iwflx, mflx, nflx
    Use xnet_timers, Only: xnet_wtime, start_timer, stop_timer, timer_output
    Use xnet_types, Only: dp
    Implicit None

    ! Input variables
    Integer, Intent(in) :: kstep
    Real(dp), Intent(in) :: enuc(zb_lo:zb_hi), edot(zb_lo:zb_hi), sqnu(zb_lo:zb_hi)

    ! Optional variables
    Logical, Optional, Target, Intent(in) :: mask_in(zb_lo:zb_hi)

    ! Local variables
    Character(40) :: ev_format
    Integer :: i, j, k, izb, izone
    Logical, Pointer :: mask(:)

    start_timer = xnet_wtime()
    timer_output = timer_output - start_timer

    If ( present(mask_in) ) Then
      mask(zb_lo:) => mask_in
    Else
      mask(zb_lo:) => lzactive(zb_lo:zb_hi)
    EndIf
    If ( .not. any(mask) ) Return

    ! Calculate reaction fluxes
    If ( itsout >= 1 .or. idiag >= 1 ) Then
      If ( kstep > 0 ) Then
        Call flux(mask_in = mask_in)
      Else
        ! Initial records use zero flux for every batch, before rates are evaluated.
        flx(:,zb_lo:zb_hi) = 0.0_dp
        flx_int(:,zb_lo:zb_hi) = 0.0_dp
      EndIf
    EndIf

    If ( itsout >= 1 ) Then
      !XDIR XUPDATE XWAIT(gpu_queue) &
      !XDIR XHOST(t,t9,rho,tdel,edot,sqnu,y,kmon)
      ev_format = '(i4,1es15.8,2es10.3,3es10.2,2i2)'
      If ( nnucout > 0 ) ev_format = '(i4,1es15.8,2es10.3,3es10.2,'//Trim(nnucout_string)//'es9.2,2i2)'
      Do izb = zb_lo, zb_hi
        If ( mask(izb) ) Then
          izone = izb + szbatch - zb_lo

          ! An abundance snapshot is written to the binary file
          Write(lun_ts(izb)) kstep,t(izb),t9(izb),rho(izb),sqnu(izb),tdel(izb), &
            & edot(izb),y(:,izb),flx(:,izb)

          ! For itsout>=2, output important mass fractions to the ASCII file
          If ( itsout >= 2 ) Write(lun_ev(izb),ev_format) &
            & kstep,t(izb),t9(izb),rho(izb),edot(izb),sqnu(izb),tdel(izb), &
            & (aa(inucout(i))*y(inucout(i),izb),i=1,nnucout),(kmon(j,izb),j=1,2)

          ! For itsout>=3, output time and thermo evolution to the screen
          If ( itsout >= 3 ) Write(lun_stdout,"(3i5,4es12.4,2i3)") &
            & izb, izone, kstep,t(izb),tdel(izb),t9(izb),rho(izb),(kmon(j,izb),j=1,2)

          ! For itsout>=4, output abundances for each timestep to the diagnostic file
          If ( itsout >= 4 .and. idiag >= 0 ) Write(lun_diag,"(4(a5,es14.7,1x))") &
            & (nname(i),aa(i)*y(i,izb),i=1,ny)

          ! For itsout>=5, output fluxes for each timestep to the diagnostic file
          If ( itsout >= 5 .and. idiag >= 0 ) Write(lun_diag,"(i5,10a5,i5,es11.3)") &
            & (k,(nname(nflx(j,k)),j=1,4),' <-> ',(nname(nflx(j,k)),j=5,8),iwflx(k),flx(k,izb),k=1,mflx)
        EndIf
      EndDo
    EndIf
    If ( idiag >= 0 ) Flush(lun_diag)

    stop_timer = xnet_wtime()
    timer_output = timer_output + stop_timer

    Return
  End Subroutine ts_output

  Subroutine final_output(kstep,mask_in)
    !-------------------------------------------------------------------------------------------------
    ! full_net calls this routine to handle output at the end of its execution.
    !-------------------------------------------------------------------------------------------------
    Use nuclear_data, Only: ny, nname, aa
    Use xnet_abundances, Only: y
    Use xnet_conditions, Only: t, t9, rho, ye, tstop
    Use xnet_controls, Only: changemx, iconvc, isolv, kitmx, kstmx, ktot, lun_diag, tolc, tolm, yacc, &
      & szbatch, zb_lo, zb_hi, lzactive, idiag, tid, gpu_queue
    Use xnet_flux, Only: flx_int
    Use xnet_match, Only: iwflx, mflx, nflx
    Use xnet_parallel, Only: parallel_IOProcessor
    Use xnet_timers
    Implicit None

    ! Input variables
    Integer, Intent(in) :: kstep

    ! Optional variables
    Logical, Optional, Target, Intent(in) :: mask_in(zb_lo:zb_hi)

    ! Local variables
    Integer, Parameter :: itimer_reset = 0
    Integer :: iflx_mx
    Integer :: i, k, izb, izone
    Logical, Pointer :: mask(:)

    If ( present(mask_in) ) Then
      mask(zb_lo:) => mask_in
    Else
      mask(zb_lo:) => lzactive(zb_lo:zb_hi)
    EndIf

    start_timer = xnet_wtime()
    timer_output = timer_output - start_timer

    ! Write integrated fluxes to diagnotic output
    If ( idiag >= 1 ) Then
      Do izb = zb_lo, zb_hi
        If ( mask(izb) ) Then
          izone = izb + szbatch - zb_lo
          iflx_mx = maxloc(abs(flx_int(:,izb)),dim=1)
          Write(lun_diag,"(2x,a8,i5,es11.3,9a5)") 'Flux Max',&
            & iflx_mx,flx_int(iflx_mx,izb),(nname(nflx(i,iflx_mx)),i=1,4),' <-> ',(nname(nflx(i,iflx_mx)),i=5,8)
          Write(lun_diag,"(i5,9a5,i5,es11.3)") &
            & (k,(nname(nflx(i,k)),i=1,4),' <-> ',(nname(nflx(i,k)),i=5,8),iwflx(k),flx_int(k,izb),k=1,mflx)
        EndIf
      EndDo
    EndIf

    ! Write final abundances to diagnostic output (in ASCII)
    If ( idiag >= 0 ) Then
      !XDIR XUPDATE XWAIT(gpu_queue) &
      !XDIR XHOST(t,t9,rho,ye,y)
      Do izb = zb_lo, zb_hi
        If ( mask(izb) ) Then
          izone = izb + szbatch - zb_lo
          Write(lun_diag,"(a,2i6,5es14.7)") &
            & 'End',izone,kstep,tstop(izb),t(izb),t9(izb),rho(izb),ye(izb)
          Write(lun_diag,"(4(a5,es14.7,1x))") (nname(i),aa(i)*y(i,izb),i=1,ny)
        EndIf
      EndDo
    EndIf

    stop_timer = xnet_wtime()
    timer_output = timer_output + stop_timer

    ! Write performance counters and timers to diagnostic output (or to stdout if idiag = -1)
    If ( idiag >= 0 .or. ( idiag >= -1 .and. parallel_IOProcessor() ) ) Then
      !XDIR XUPDATE XWAIT(gpu_queue) &
      !XDIR XHOST(ktot)
      Write(lun_diag,"(a10,a5,5a10)") 'Counters: ','Zone','TS','NR','Jacobian','Deriv','CrossSect'
      Do izb = zb_lo, zb_hi
        If ( mask(izb) ) Then
          izone = izb + szbatch - zb_lo
          Write(lun_diag,"(10x,i5,5i10)") izone,(ktot(i,izb),i=1,5)
        EndIf
      EndDo
      Call write_timers_summary(lun_diag)
    EndIf
    If ( idiag >= 0 ) Flush(lun_diag)

    ! Use the following line to restart the timers
    If ( itimer_reset > 0 ) Call reset_timers

    Return
  End Subroutine final_output

  Subroutine write_xnet_inab( fname, header, nname, y, ierr )
    Use xnet_controls, Only: lun_stderr
    Use xnet_types, Only: dp
    Implicit None

    ! Input variables
    Character(*), Intent(in) :: fname
    Character(*), Intent(in) :: header
    Character(5), Intent(in) :: nname(:)
    real(dp), Intent(in) :: y(:)

    ! Output variables
    Integer, Intent(out) :: ierr

    ! Local variables
    Integer :: lun_inab
    Integer :: i

    ierr = 0

    ! open file
    open (newunit=lun_inab,file=trim(fname),iostat=ierr)
    if ( ierr /= 0 ) then
      write (lun_stderr,'(3a,i3,a)') '[write_xnet_inab] ERROR: Problem opening file: ',trim(fname),'(',ierr,')'
      return
    end if

    ! write header
    write (lun_inab,'(a)',iostat=ierr) trim(header)
    if ( ierr /= 0 ) then
      write (lun_stderr,'(a,i3,a)') '[write_xnet_inab] ERROR: Problem writing header (',ierr,')'
      close (lun_inab)
      return
    end if

    ! write abundances
    write (lun_inab,'(a5,es23.15)',iostat=ierr) (adjustr(nname(i)), y(i), i=1,size(y))
    if ( ierr /= 0 ) then
      write (lun_stderr,'(a,i3,a)') '[write_xnet_inab] ERROR: Problem writing data (',ierr,')'
      close (lun_inab)
      return
    end if

    ! close file
    close (lun_inab)

    return
  End Subroutine write_xnet_inab

  Subroutine write_xnet_th_history( fname, header, time, t9, rho, ye, ierr )
    Use xnet_controls, Only: lun_stderr
    Use xnet_types, Only: dp
    Implicit None

    ! Input variables
    Character(*), Intent(in) :: fname
    Character(*), Intent(in) :: header
    Real(dp), Intent(in) :: time(:) ! First three values are for header
    Real(dp), Intent(in) :: t9(size(time)-3)
    Real(dp), Intent(in) :: rho(size(time)-3)
    Real(dp), Intent(in) :: ye(size(time)-3)

    ! Output variables
    Integer, Intent(out) :: ierr

    ! Local variables
    Integer :: lun_th
    Integer :: tmp_ierr(4)
    Integer :: i

    ierr = 0
    tmp_ierr = 0

    if ( size(time) < 5 ) then
      write (lun_stderr,'(a)') '[write_xnet_th] ERROR: Not enough data points'
      ierr = 1
      return
    end if

    ! open file
    open (newunit=lun_th,file=trim(fname),iostat=ierr)
    if ( ierr /= 0 ) then
      write (lun_stderr,'(3a,i3,a)') '[write_xnet_th] ERROR: Problem opening file: ',trim(fname),'(',ierr,')'
      return
    end if

    ! write header
    write (lun_th,'(a)',iostat=tmp_ierr(1)) trim(header)
    write (lun_th,'(es23.15,a)',iostat=tmp_ierr(2)) time(1),' start time'
    write (lun_th,'(es23.15,a)',iostat=tmp_ierr(3)) time(2),' stop time'
    write (lun_th,'(es23.15,a)',iostat=tmp_ierr(4)) time(3),' initial timestep'
    if ( any( tmp_ierr /= 0 ) ) then
      ierr = maxval(tmp_ierr)
      write (lun_stderr,'(a,i3,a)') '[write_xnet_th] ERROR: Problem writing header (',ierr,')'
      close (lun_th)
      return
    end if

    write (lun_th,'(4es23.15)',iostat=ierr) (time(i+3),t9(i),rho(i),ye(i),i=1,size(t9))
    if ( ierr /= 0 ) then
      write (lun_stderr,'(a,i3,a)') '[write_xnet_th] ERROR: Problem writing data (',ierr,')'
      close (lun_th)
      return
    end if

    close (lun_th)

    return
  End Subroutine write_xnet_th_history

  Subroutine write_xnet_th_point( fname, header, tstart, tstop, t9, rho, ye, ierr )
    Use xnet_controls, Only: lun_stderr
    Use xnet_types, Only: dp
    Implicit None

    ! Input variables
    Character(*), Intent(in) :: fname
    Character(*), Intent(in) :: header
    Real(dp), Intent(in) :: tstart
    Real(dp), Intent(in) :: tstop
    Real(dp), Intent(in) :: t9
    Real(dp), Intent(in) :: rho
    Real(dp), Intent(in) :: ye

    ! Output variables
    Integer, Intent(out) :: ierr

    ! Local variables
    Integer :: lun_th
    Integer :: tmp_ierr(4)
    Integer :: i

    ierr = 0
    tmp_ierr = 0

    ! open file
    open (newunit=lun_th,file=trim(fname),iostat=ierr)
    if ( ierr /= 0 ) then
      write (lun_stderr,'(3a,i3,a)') '[write_xnet_th] ERROR: Problem opening file: ',trim(fname),'(',ierr,')'
      return
    end if

    ! write header
    write (lun_th,'(a)',iostat=tmp_ierr(1)) trim(header)
    write (lun_th,'(es23.15,a)',iostat=tmp_ierr(2)) tstart,' start time'
    write (lun_th,'(es23.15,a)',iostat=tmp_ierr(3)) tstop,' stop time'
    write (lun_th,'(es23.15,a)',iostat=tmp_ierr(4)) (tstop-tstart)*1.0e-4_dp,' initial timestep'
    if ( any( tmp_ierr /= 0 ) ) then
      ierr = maxval(tmp_ierr)
      write (lun_stderr,'(a,i3,a)') '[write_xnet_th] ERROR: Problem writing header (',ierr,')'
      close (lun_th)
      return
    end if

    write (lun_th,'(4es23.15)',iostat=ierr) tstop, t9, rho, ye
    write (lun_th,'(4es23.15)',iostat=ierr) tstop, t9, rho, ye
    if ( ierr /= 0 ) then
      write (lun_stderr,'(a,i3,a)') '[write_xnet_th] ERROR: Problem writing data (',ierr,')'
      close (lun_th)
      return
    end if

    flush (lun_th)
    close (lun_th)

    return
  End Subroutine write_xnet_th_point

End Module xnet_output
