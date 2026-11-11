!***************************************************************************************************
! xnet_output.F90
! Time-series file management, evolution diagnostics, and standalone input-file writers for XNet.
!
! Provides three groups of routines:
! 1. Time-Series File Lifecycle (resolve_output_species, open_ts_file, open_ev_file, close_output_files):
!    Shared by the standalone driver (net.F90) and the library API (xnet_api.F90) to map configured
!    ASCII output species names to network indices, open per-zone unformatted binary (itsout >= 1)
!    and condensed ASCII (itsout >= 2) output files, write their header records, and close open
!    units across the batch bank of the calling worker (zb_lo:zb_hi).
! 2. Per-Timestep and Final Evolution Output (ts_output, final_output):
!    Called by full_net to evaluate reaction fluxes, record binary and ASCII time-series snapshots,
!    and write integrated flux, final abundance, work-counter, and timing summaries to lun_diag.
! 3. Standalone Reproducer Writers (write_xnet_inab, write_xnet_th):
!    Used by the standalone failure path to write ab_fail_* and th_fail_* input files.
!***************************************************************************************************

#include "xnet_macros.fh"

Module xnet_output
  Implicit None
  Private

  Interface write_xnet_th
    Module Procedure write_xnet_th_history
    Module Procedure write_xnet_th_point
  End Interface write_xnet_th

  Public :: resolve_output_species
  Public :: open_ts_file
  Public :: open_ev_file
  Public :: close_output_files
  Public :: ts_output
  Public :: final_output
  Public :: write_xnet_inab
  Public :: write_xnet_th
  Public :: write_xnet_th_history, write_xnet_th_point

Contains

  !=================================================================================================
  ! Time-Series File Lifecycle
  !=================================================================================================

  Subroutine resolve_output_species
    !-----------------------------------------------------------------------------------------------
    ! Map the configured condensed ASCII output species names (output_nuc(1:nnucout)) to active
    ! network indices in inucout(1:nnucout). Any species name not present in the loaded network
    ! logs a warning to lun_stdout and falls back to the final network species (ny).
    !-----------------------------------------------------------------------------------------------
    Use nuclear_data, Only: ny, index_from_name
    Use xnet_controls, Only: nnucout, output_nuc, inucout, lun_stdout
    Implicit None

    ! Local variables
    Integer :: i, inuc

    Do i = 1, nnucout
      Call index_from_name(output_nuc(i),inuc)
      If ( inuc < 1 .or. inuc > ny ) Then
        Write(lun_stdout,*) 'Output Nuc:',i,output_nuc(i),' not found'
        inucout(i) = ny
      Else
        inucout(i) = inuc
      EndIf
    EndDo

    Return
  End Subroutine resolve_output_species

  Subroutine open_ts_file(izb,filename,data_description,abundance_source,abundance_description, &
    & thermo_source,thermo_description,status,ierr)
    !-----------------------------------------------------------------------------------------------
    ! Open one unformatted binary time-series file for workspace slot izb and write its six
    ! header records. Metadata fields retain their 80-character widths. The caller selects the
    ! filename and OPEN status ('unknown' in standalone; 'new' in the library API). When optional
    ! ierr is supplied, open failures return a nonzero status instead of raising a runtime error.
    !-----------------------------------------------------------------------------------------------
    Use nuclear_data, Only: ny, zz, aa
    Use xnet_controls, Only: lun_ts, descript, kstmx, kitmx, iweak0, iscrn, iconvc, changemx, &
      & tolm, tolc, yacc, ymin, tdel_maxmult, iheat, isolv
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
      Open(newunit=output_unit,file=trim(filename),status=status,form='unformatted', &
        & action='write',iostat=ierr)
      If ( ierr /= 0 ) Return
    Else
      Open(newunit=output_unit,file=trim(filename),status=status,form='unformatted', &
        & action='write')
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
    ! Open one condensed ASCII evolution file for workspace slot izb and write its column header
    ! for the configured output_nuclei (1:nnucout). When optional ierr is supplied, open failures
    ! return a nonzero status.
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
      & 'k ',' Time ',' T(GK) ',' Density ',' dE/dt ',' sqnu ',' Timestep ', &
      & (nname(inucout(i)),i=1,nnucout),' It '

    Return
  End Subroutine open_ev_file

  Subroutine close_output_files
    !-----------------------------------------------------------------------------------------------
    ! Close any open binary (lun_ts) and ASCII (lun_ev) time-series units in the workspace bank
    ! of the calling worker (zb_lo:zb_hi) and reset their unit slots to zero.
    ! Zero marks an unopened slot; valid NEWUNIT numbers are negative.
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

  !=================================================================================================
  ! Per-Timestep and Final Evolution Output
  !=================================================================================================

  Subroutine ts_output(kstep,enuc,edot,sqnu,mask_in)
    !-----------------------------------------------------------------------------------------------
    ! Per-timestep output handler called by full_net at kstep = 0 and after each outer step:
    ! - Evaluates matched reaction fluxes when itsout >= 1 or idiag >= 1 (zeroing fluxes at kstep=0).
    ! - Writes per-step records controlled by itsout:
    !     itsout >= 1: Binary snapshot to lun_ts(izb)
    !     itsout >= 2: Condensed ASCII row to lun_ev(izb)
    !     itsout >= 3: Step summary to lun_stdout
    !     itsout >= 4: Full mass-fraction table to lun_diag (when idiag >= 0)
    !     itsout >= 5: Matched reaction fluxes to lun_diag (when idiag >= 0)
    ! Argument enuc is retained for call-site compatibility.
    !-----------------------------------------------------------------------------------------------
    Use nuclear_data, Only: ny, aa, nname
    Use xnet_abundances, Only: y
    Use xnet_conditions, Only: rho, t, t9, tdel
    Use xnet_controls, Only: nnucout, nnucout_string, idiag, inucout, itsout, kmon, lun_diag, &
      & lun_ev, lun_stdout, lun_ts, szbatch, zb_lo, zb_hi, lzactive, gpu_queue
    Use xnet_flux, Only: flx, flx_int, flux
    Use xnet_match, Only: iwflx, mflx, nflx
    Use xnet_timers, Only: xnet_wtime, start_timer, stop_timer, timer_output
    Use xnet_types, Only: dp
    Implicit None

    ! Input arguments
    Integer, Intent(in) :: kstep
    Real(dp), Intent(in) :: enuc(zb_lo:zb_hi), edot(zb_lo:zb_hi), sqnu(zb_lo:zb_hi)

    ! Optional arguments
    Logical, Optional, Target, Intent(in) :: mask_in(zb_lo:zb_hi)

    ! Local variables
    Character(40) :: ev_format
    Integer :: i, j, k, izb, izone
    Logical, Pointer :: mask(:)

    If ( present(mask_in) ) Then
      mask(zb_lo:) => mask_in
    Else
      mask(zb_lo:) => lzactive(zb_lo:zb_hi)
    EndIf
    If ( .not. any(mask) ) Return

    start_timer = xnet_wtime()
    timer_output = timer_output - start_timer

    ! Evaluate reaction fluxes (kstep = 0 records zero initial flux before rates are evaluated)
    If ( itsout >= 1 .or. idiag >= 1 ) Then
      If ( kstep > 0 ) Then
        Call flux(mask_in = mask_in)
      Else
        flx(:,zb_lo:zb_hi)     = 0.0_dp
        flx_int(:,zb_lo:zb_hi) = 0.0_dp
      EndIf
    EndIf

    If ( itsout >= 1 ) Then
      !XDIR XUPDATE XWAIT(gpu_queue) &
      !XDIR XHOST(t,t9,rho,tdel,edot,sqnu,y,kmon)
      ev_format = '(i4,1es15.8,2es10.3,3es10.2,2i2)'
      If ( nnucout > 0 ) ev_format = '(i4,1es15.8,2es10.3,3es10.2,'//trim(nnucout_string)//'es9.2,2i2)'

      Do izb = zb_lo, zb_hi
        If ( mask(izb) ) Then
          izone = izb + szbatch - zb_lo

          ! itsout >= 1: unformatted binary state and flux snapshot
          Write(lun_ts(izb)) kstep,t(izb),t9(izb),rho(izb),sqnu(izb),tdel(izb), &
            & edot(izb),y(:,izb),flx(:,izb)

          ! itsout >= 2: condensed ASCII evolution row
          If ( itsout >= 2 ) Write(lun_ev(izb),ev_format) &
            & kstep,t(izb),t9(izb),rho(izb),edot(izb),sqnu(izb),tdel(izb), &
            & (aa(inucout(i))*y(inucout(i),izb),i=1,nnucout),(kmon(j,izb),j=1,2)

          ! itsout >= 3: screen progress line
          If ( itsout >= 3 ) Write(lun_stdout,"(3i5,4es12.4,2i3)") &
            & izb,izone,kstep,t(izb),tdel(izb),t9(izb),rho(izb),(kmon(j,izb),j=1,2)

          ! itsout >= 4: full mass-fraction table to diagnostic log
          If ( itsout >= 4 .and. idiag >= 0 ) Write(lun_diag,"(4(a5,es14.7,1x))") &
            & (nname(i),aa(i)*y(i,izb),i=1,ny)

          ! itsout >= 5: instantaneous reaction fluxes to diagnostic log
          If ( itsout >= 5 .and. idiag >= 0 ) Write(lun_diag,"(i5,9a5,i5,es11.3)") &
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
    !-----------------------------------------------------------------------------------------------
    ! End-of-burn diagnostic output called by full_net after successful evolution:
    ! - idiag >=  1: Integrated reaction fluxes and dominant flux pair to lun_diag.
    ! - idiag >=  0: Final zone state ('End' record) and mass fractions to lun_diag.
    ! - idiag >= -1: Cumulative work counters and timer summary (on I/O rank when idiag == -1).
    !-----------------------------------------------------------------------------------------------
    Use nuclear_data, Only: ny, nname, aa
    Use xnet_abundances, Only: y
    Use xnet_conditions, Only: t, t9, rho, ye, tstop
    Use xnet_controls, Only: ktot, lun_diag, szbatch, zb_lo, zb_hi, lzactive, idiag, gpu_queue
    Use xnet_flux, Only: flx_int
    Use xnet_match, Only: iwflx, mflx, nflx
    Use xnet_parallel, Only: parallel_IOProcessor
    Use xnet_timers, Only: xnet_wtime, start_timer, stop_timer, timer_output, &
      & reset_timers, write_timers_summary
    Implicit None

    ! Input arguments
    Integer, Intent(in) :: kstep

    ! Optional arguments
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

    ! Write time-integrated reaction fluxes to diagnostic output
    If ( idiag >= 1 ) Then
      Do izb = zb_lo, zb_hi
        If ( mask(izb) ) Then
          izone = izb + szbatch - zb_lo
          iflx_mx = maxloc(abs(flx_int(:,izb)),dim=1)
          Write(lun_diag,"(2x,a8,i5,es11.3,9a5)") 'Flux Max', &
            & iflx_mx,flx_int(iflx_mx,izb),(nname(nflx(i,iflx_mx)),i=1,4),' <-> ',(nname(nflx(i,iflx_mx)),i=5,8)
          Write(lun_diag,"(i5,9a5,i5,es11.3)") &
            & (k,(nname(nflx(i,k)),i=1,4),' <-> ',(nname(nflx(i,k)),i=5,8),iwflx(k),flx_int(k,izb),k=1,mflx)
        EndIf
      EndDo
    EndIf

    ! Write final zone conditions and mass fractions to diagnostic output
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

    ! Write solver work counters and timer summary
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

    If ( itimer_reset > 0 ) Call reset_timers

    Return
  End Subroutine final_output

  !=================================================================================================
  ! Standalone Reproducer Input-File Writers
  !=================================================================================================

  Subroutine write_xnet_inab(fname,header,nname,y,ierr)
    !-----------------------------------------------------------------------------------------------
    ! Write an ASCII initial-abundance file containing a header line followed by one
    ! (species_name, molar abundance Y = X/A) entry per line.
    !-----------------------------------------------------------------------------------------------
    Use xnet_controls, Only: lun_stderr
    Use xnet_types, Only: dp
    Implicit None

    ! Input arguments
    Character(*), Intent(in) :: fname
    Character(*), Intent(in) :: header
    Character(5), Intent(in) :: nname(:)
    Real(dp), Intent(in) :: y(:)

    ! Output arguments
    Integer, Intent(out) :: ierr

    ! Local variables
    Integer :: lun_inab, i

    ierr = 0
    Open(newunit=lun_inab,file=trim(fname),iostat=ierr)
    If ( ierr /= 0 ) Then
      Write(lun_stderr,'(3a,i3,a)') '[write_xnet_inab] ERROR: Problem opening file: ',trim(fname),'(',ierr,')'
      Return
    EndIf

    Write(lun_inab,'(a)',iostat=ierr) trim(header)
    If ( ierr /= 0 ) Then
      Write(lun_stderr,'(a,i3,a)') '[write_xnet_inab] ERROR: Problem writing header (',ierr,')'
      Close(lun_inab)
      Return
    EndIf

    Write(lun_inab,'(a5,es23.15)',iostat=ierr) (adjustr(nname(i)),y(i),i=1,size(y))
    If ( ierr /= 0 ) Then
      Write(lun_stderr,'(a,i3,a)') '[write_xnet_inab] ERROR: Problem writing data (',ierr,')'
      Close(lun_inab)
      Return
    EndIf

    Close(lun_inab)

    Return
  End Subroutine write_xnet_inab

  Subroutine write_xnet_th_history(fname,header,time,t9,rho,ye,ierr)
    !-----------------------------------------------------------------------------------------------
    ! Write an ASCII thermodynamic trajectory file from history arrays.
    ! The first three entries of time(:) supply [tstart, tstop, tdelstart]; remaining entries
    ! time(4:) correspond to t9(:), rho(:), and ye(:).
    !-----------------------------------------------------------------------------------------------
    Use xnet_controls, Only: lun_stderr
    Use xnet_types, Only: dp
    Implicit None

    ! Input arguments
    Character(*), Intent(in) :: fname
    Character(*), Intent(in) :: header
    Real(dp), Intent(in) :: time(:)
    Real(dp), Intent(in) :: t9(size(time)-3)
    Real(dp), Intent(in) :: rho(size(time)-3)
    Real(dp), Intent(in) :: ye(size(time)-3)

    ! Output arguments
    Integer, Intent(out) :: ierr

    ! Local variables
    Integer :: lun_th, i
    Integer :: tmp_ierr(4)

    ierr = 0
    tmp_ierr = 0

    If ( size(time) < 5 ) Then
      Write(lun_stderr,'(a)') '[write_xnet_th] ERROR: Not enough data points'
      ierr = 1
      Return
    EndIf

    Open(newunit=lun_th,file=trim(fname),iostat=ierr)
    If ( ierr /= 0 ) Then
      Write(lun_stderr,'(3a,i3,a)') '[write_xnet_th] ERROR: Problem opening file: ',trim(fname),'(',ierr,')'
      Return
    EndIf

    Write(lun_th,'(a)',iostat=tmp_ierr(1)) trim(header)
    Write(lun_th,'(es23.15,a)',iostat=tmp_ierr(2)) time(1),' start time'
    Write(lun_th,'(es23.15,a)',iostat=tmp_ierr(3)) time(2),' stop time'
    Write(lun_th,'(es23.15,a)',iostat=tmp_ierr(4)) time(3),' initial timestep'
    If ( any(tmp_ierr /= 0) ) Then
      ierr = maxval(tmp_ierr)
      Write(lun_stderr,'(a,i3,a)') '[write_xnet_th] ERROR: Problem writing header (',ierr,')'
      Close(lun_th)
      Return
    EndIf

    Write(lun_th,'(4es23.15)',iostat=ierr) (time(i+3),t9(i),rho(i),ye(i),i=1,size(t9))
    If ( ierr /= 0 ) Then
      Write(lun_stderr,'(a,i3,a)') '[write_xnet_th] ERROR: Problem writing data (',ierr,')'
      Close(lun_th)
      Return
    EndIf

    Close(lun_th)

    Return
  End Subroutine write_xnet_th_history

  Subroutine write_xnet_th_point(fname,header,tstart,tstop,t9,rho,ye,ierr)
    !-----------------------------------------------------------------------------------------------
    ! Write a two-point constant-condition ASCII thermodynamic trajectory file for [tstart, tstop].
    !-----------------------------------------------------------------------------------------------
    Use xnet_controls, Only: lun_stderr
    Use xnet_types, Only: dp
    Implicit None

    ! Input arguments
    Character(*), Intent(in) :: fname
    Character(*), Intent(in) :: header
    Real(dp), Intent(in) :: tstart, tstop, t9, rho, ye

    ! Output arguments
    Integer, Intent(out) :: ierr

    ! Local variables
    Integer, Parameter :: npoint = 2
    Real(dp), Parameter :: initial_timestep_fraction = 1.0e-4_dp
    Integer :: lun_th, i
    Integer :: tmp_ierr(4)

    ierr = 0
    tmp_ierr = 0

    Open(newunit=lun_th,file=trim(fname),iostat=ierr)
    If ( ierr /= 0 ) Then
      Write(lun_stderr,'(3a,i3,a)') '[write_xnet_th] ERROR: Problem opening file: ',trim(fname),'(',ierr,')'
      Return
    EndIf

    Write(lun_th,'(a)',iostat=tmp_ierr(1)) trim(header)
    Write(lun_th,'(es23.15,a)',iostat=tmp_ierr(2)) tstart,' start time'
    Write(lun_th,'(es23.15,a)',iostat=tmp_ierr(3)) tstop,' stop time'
    Write(lun_th,'(es23.15,a)',iostat=tmp_ierr(4)) (tstop - tstart) * initial_timestep_fraction,' initial timestep'
    If ( any(tmp_ierr /= 0) ) Then
      ierr = maxval(tmp_ierr)
      Write(lun_stderr,'(a,i3,a)') '[write_xnet_th] ERROR: Problem writing header (',ierr,')'
      Close(lun_th)
      Return
    EndIf

    Do i = 1, npoint
      Write(lun_th,'(4es23.15)',iostat=ierr) tstop,t9,rho,ye
      If ( ierr /= 0 ) Exit
    EndDo
    If ( ierr /= 0 ) Then
      Write(lun_stderr,'(a,i3,a)') '[write_xnet_th] ERROR: Problem writing data (',ierr,')'
      Close(lun_th)
      Return
    EndIf

    Flush(lun_th)
    Close(lun_th)

    Return
  End Subroutine write_xnet_th_point

End Module xnet_output
