!***************************************************************************************************
! model_input_ascii.F90
! ASCII thermodynamic-trajectory and initial-abundance readers for the standalone XNet driver.
!
! Provides three routines used by net.F90 (and unit contract tests):
! - read_thermo_file: Reads per-zone thermodynamic trajectories (tstart, tstop, tdelstart, and
!   tab/space-delimited time series of t, T9, rho, optional Ye, and optional neutrino fluxes
!   and temperatures).
! - load_initial_abundances: Interpolates initial Ye from the trajectory, reads the initial
!   abundance file when needed (t9start <= t9nse or invalid trajectory Ye), and initializes
!   ystart either from the file or from Nuclear Statistical Equilibrium (when t9start > t9nse).
! - read_inab_file: Reads named molar abundances and optional Ye, preferably one pair per line,
!   and computes auxiliary-nucleus moments (xext, aext, zext) for out-of-network species or
!   normalized in-network abundances yin(1:ny).
!***************************************************************************************************

Module model_input_ascii
  Implicit None
  Private

  Public :: read_thermo_file
  Public :: load_initial_abundances
  Public :: read_inab_file

Contains

  Subroutine read_thermo_file(thermo_file,thermo_desc,ierr,mask_in)
    !-----------------------------------------------------------------------------------------------
    ! Read ASCII thermodynamic trajectory files for active zones in the current worker bank.
    ! Each file begins with a description line and scalar records for tstart, tstop, and tdelstart,
    ! followed by up to nhmx whitespace-delimited history lines:
    !   th(n)  t9h(n)  rhoh(n)  [yeh(n)  [fluxcms(n,1:nnuspec)  [tmevnu(n,1:nnuspec)]]]
    !-----------------------------------------------------------------------------------------------
    Use, Intrinsic :: iso_fortran_env, Only: iostat_end
    Use xnet_conditions, Only: nhmx, nh, tstart, tstop, tdelstart, th, t9h, rhoh, yeh
    Use xnet_controls, Only: idiag, lun_diag, lun_th, nzone, nzevolve, szbatch, zb_lo, zb_hi, &
      & lzactive
    Use xnet_nnu, Only: nnuspec, fluxcms, tmevnu
    Use xnet_types, Only: dp
    Use xnet_util, Only: replace_tabs, readnext, xnet_terminate
    Implicit None

    ! Input arguments
    Character(*), Intent(in) :: thermo_file(nzone)

    ! Output arguments
    Character(80), Intent(out) :: thermo_desc(nzevolve)
    Integer, Intent(out) :: ierr

    ! Optional arguments
    Logical, Optional, Target, Intent(in) :: mask_in(zb_lo:zb_hi)

    ! Local variables
    Integer, Parameter :: max_line_length = 1024
    Character(max_line_length) :: line
    Integer :: pos, i, n, izb, izone
    Logical, Pointer :: mask(:)

    If ( present(mask_in) ) Then
      mask(zb_lo:) => mask_in
    Else
      mask(zb_lo:) => lzactive(zb_lo:zb_hi)
    EndIf
    If ( .not. any(mask) ) Return

    ierr = 0

    Do izb = zb_lo, zb_hi
      If ( mask(izb) ) Then
        izone = izb + szbatch - zb_lo

        !$omp critical(th_read)
        Open(newunit=lun_th,file=trim(thermo_file(izone)),action='read',status='old',iostat=ierr)
        If ( ierr /= 0 ) Then
          Call xnet_terminate('Failed to open input file: '//trim(thermo_file(izone)))
        EndIf

        ! Header: description, start time, stop time, initial timestep.
        Read(lun_th,"(a)",iostat=ierr) thermo_desc(izb)
        If ( ierr == 0 ) Read(lun_th,*,iostat=ierr) tstart(izb)
        If ( ierr == 0 ) Read(lun_th,*,iostat=ierr) tstop(izb)
        If ( ierr == 0 ) Read(lun_th,*,iostat=ierr) tdelstart(izb)
        If ( ierr /= 0 ) Then
          Call xnet_terminate('Failed to read the header of input file: '//trim(thermo_file(izone)),ierr)
        EndIf

        Do n = 1, nhmx
          line = ' '
          Read(lun_th,"(a)",iostat=ierr) line
          If ( ierr == iostat_end ) Then
            If ( idiag >= 1 ) Write(lun_diag,"(a,i6,a)") 'End of Thermo File Reached after ',n,' records'
            Exit
          ElseIf ( ierr /= 0 ) Then
            Call xnet_terminate('Failed while trying to read input file: '//trim(thermo_file(izone)),ierr)
          EndIf

          ! Parse whitespace-delimited tokens sequentially to accommodate optional trailing columns.
          Call replace_tabs(line)
          pos = 1
          Call readnext(line,pos,th(n,izb))
          Call readnext(line,pos,t9h(n,izb))
          Call readnext(line,pos,rhoh(n,izb))
          If ( pos == 0 ) Call xnet_terminate('Not enough columns in thermo file: '//trim(thermo_file(izone)))

          ! Optional column 4: electron fraction Ye
          Call readnext(line,pos,yeh(n,izb))
          If ( pos == 0 ) Cycle

          ! Optional trailing columns: neutrino fluxes and temperatures for each neutrino species
          Do i = 1, nnuspec
            Call readnext(line,pos,fluxcms(n,i,izb))
            If ( pos == 0 ) Exit
          EndDo
          If ( pos == 0 ) Cycle
          Do i = 1, nnuspec
            Call readnext(line,pos,tmevnu(n,i,izb))
            If ( pos == 0 ) Exit
          EndDo
        EndDo
        nh(izb) = n - 1
        Close(lun_th)
        !$omp end critical(th_read)
        ierr = 0

        ! Ignore positive initial-timestep hints in standalone trajectory files; negative values
        ! retain their historical startup-hint encoding in timestep().
        tdelstart(izb) = min(0.0_dp,tdelstart(izb))

        If ( idiag >= 0 ) Write(lun_diag,"(a5,i5,2a)") &
          & 'Zone ',izone,' Profile: ',thermo_desc(izb)
      EndIf
    EndDo

    Return
  End Subroutine read_thermo_file

  Subroutine load_initial_abundances(inab_file,abund_desc,ierr,mask_in)
    !-----------------------------------------------------------------------------------------------
    ! Initialize starting abundances ystart(:,izb), electron fraction yestart(izb), and auxiliary
    ! reservoir parameters (xext, aext, zext) for active zones in the current worker bank.
    ! Reads the initial abundance file for the zone unless t9start > t9nse and the trajectory
    ! already supplies a valid electron fraction in (0, 1).
    !-----------------------------------------------------------------------------------------------
    Use nuclear_data, Only: ny
    Use xnet_abundances, Only: y_moment, ystart, xext, aext, zext
    Use xnet_conditions, Only: nstart, tstart, t9start, rhostart, yestart, nh, th, yeh
    Use xnet_controls, Only: lun_diag, idiag, t9nse, nzone, nzevolve, szbatch, zb_lo, zb_hi, &
      & lzactive, iaux
    Use xnet_nse, Only: nse_solve, ynse
    Use xnet_types, Only: dp
    Use xnet_util, Only: xnet_terminate
    Implicit None

    ! Input arguments
    Character(*), Intent(in) :: inab_file(nzone)

    ! Output arguments
    Character(80), Intent(out) :: abund_desc(nzevolve)
    Integer, Intent(out) :: ierr

    ! Optional arguments
    Logical, Optional, Target, Intent(in) :: mask_in(zb_lo:zb_hi)

    ! Local variables
    Real(dp) :: yein, yin(ny)
    Real(dp) :: rdt, dt, dye
    Real(dp) :: ytot, abar, zbar, z2bar, zibar, aext_loc, zext_loc, xext_loc, xnorm
    Integer :: izb, izone
    Logical, Pointer :: mask(:)

    If ( present(mask_in) ) Then
      mask(zb_lo:) => mask_in
    Else
      mask(zb_lo:) => lzactive(zb_lo:zb_hi)
    EndIf
    If ( .not. any(mask) ) Return

    ierr = 0
    Do izb = zb_lo, zb_hi
      yestart(izb)  = 0.0_dp
      ystart(:,izb) = 0.0_dp

      ! Standalone input always retains out-of-network matter in an auxiliary nucleus.
      ! The iaux == 0 normalization branch below is kept for the existing input path.
      iaux(izb) = 1
      xext(izb) = 0.0_dp
      aext(izb) = 1.0_dp
      zext(izb) = 0.0_dp
    EndDo

    Do izb = zb_lo, zb_hi
      If ( mask(izb) ) Then
        izone = izb + szbatch - zb_lo

        ! 1. Interpolate initial electron fraction from the thermodynamic trajectory
        If ( nstart(izb) > 1 .and. nstart(izb) <= nh(izb) ) Then
          rdt = 1.0_dp / (th(nstart(izb),izb) - th(nstart(izb)-1,izb))
          dt  = tstart(izb) - th(nstart(izb)-1,izb)
          dye = yeh(nstart(izb),izb) - yeh(nstart(izb)-1,izb)
          yestart(izb) = dt * rdt * dye + yeh(nstart(izb)-1,izb)
        ElseIf ( nstart(izb) == 1 ) Then
          yestart(izb) = yeh(1,izb)
        Else
          yestart(izb) = yeh(nh(izb),izb)
        EndIf

        ! 2. Read the initial abundance file when below the NSE threshold or when the trajectory
        !    did not supply a valid electron fraction in (0, 1)
        yin = 0.0_dp
        If ( t9start(izb) <= t9nse .or. yestart(izb) <= 0.0_dp .or. yestart(izb) >= 1.0_dp ) Then
          Call read_inab_file(inab_file(izone),abund_desc(izb),yein,yin, &
            & xext_loc,aext_loc,zext_loc,xnorm,ierr)
          If ( ierr /= 0 ) Then
            Call xnet_terminate('Failed to open initial abundance file: '//trim(inab_file(izone)),ierr)
          EndIf

          If ( iaux(izb) == 0 ) Then
            yin = yin / xnorm
            Write(lun_diag,"(a)") 'Normalizing initial abundances.'
          Else
            xext(izb) = xext_loc
            aext(izb) = aext_loc
            zext(izb) = zext_loc
          EndIf

          ! Compute Ye from the composition moments if not explicitly supplied in the abundance file
          If ( yein <= 0.0_dp .or. yein >= 1.0_dp ) Then
            Call y_moment(yin,yein,ytot,abar,zbar,z2bar,zibar,xext(izb),aext(izb),zext(izb))
          EndIf
          yestart(izb) = yein

          If ( idiag >= 0 ) Then
            Write(lun_diag,"(a)") inab_file(izone)
            Write(lun_diag,"(a5,i5,2a)") 'Zone ',izone,' Initial abundances: ',abund_desc(izb)
          EndIf
        EndIf

        ! 3. Populate ystart from NSE when above t9nse, or from the file composition otherwise
        If ( t9start(izb) > t9nse ) Then
          If ( idiag >= 0 ) Write(lun_diag,"(a)") 'Initial abundances from NSE'
          Call nse_solve(rhostart(izb),t9start(izb),yestart(izb))
          ystart(:,izb) = ynse(:)
          iaux(izb)     = 0
        Else
          ystart(:,izb) = yin(:)
        EndIf
      EndIf
    EndDo

    Return
  End Subroutine load_initial_abundances

  Subroutine read_inab_file(inab_file,abund_desc,yein,yin,xext,aext,zext,xnet,ierr)
    !-----------------------------------------------------------------------------------------------
    ! Read an ASCII initial-abundance file.
    ! Note: Unlike the library API (which takes mass fractions X_i), standalone initial-abundance
    ! files store molar abundances Y_i = X_i / A_i. Use one (name, Y_i) or ('ye', Ye) pair per line,
    ! as write_xnet_inab does. Packed input is read four pairs at a time, including any 'ye' pair.
    ! A read may span lines; unused fields on the line completing the group are discarded.
    ! Species absent from the active network are accumulated into yext:
    ! - When yext > 0, xnet < 1, and znet < yein: out-of-network matter forms an auxiliary nucleus
    !   with xext = 1 - xnet, aext = xext / yext, and zext = (yein - znet) * aext / xext.
    ! - Otherwise: xext = 0 and in-network abundances yin(:) are normalized by xnet = sum(yin * aa).
    !-----------------------------------------------------------------------------------------------
    Use, Intrinsic :: iso_fortran_env, Only: iostat_end
    Use nuclear_data, Only: ny, aa, zz, index_from_name
    Use xnet_controls, Only: lun_stderr, lun_ab, lun_diag, idiag
    Use xnet_types, Only: dp
    Use xnet_util, Only: string_lc, xnet_terminate
    Implicit None

    ! Input arguments
    Character(*), Intent(in) :: inab_file

    ! Output arguments
    Character(80), Intent(out) :: abund_desc
    Real(dp), Intent(out) :: yein
    Real(dp), Intent(out) :: yin(ny)
    Real(dp), Intent(out) :: xext, aext, zext, xnet
    Integer, Intent(out) :: ierr

    ! Local variables
    Integer, Parameter :: nread_max = 4 ! Maximum (name, abundance) pairs read per statement
    Character(5) :: char_tmp(nread_max), namein
    Real(dp) :: real_tmp(nread_max), znet, yext
    Integer :: i, inuc

    ! Initialize outputs to deterministic defaults before opening the file
    abund_desc = ' '
    yein       = 0.0_dp
    yin        = 0.0_dp
    yext       = 0.0_dp
    xext       = 0.0_dp
    aext       = 1.0_dp
    zext       = 0.0_dp
    xnet       = 0.0_dp

    !$omp critical(ab_read)
    Open(newunit=lun_ab,file=trim(inab_file),action='read',status='old',iostat=ierr)
    If ( ierr /= 0 ) Then
      Write(lun_stderr,"(2a)") 'Failed to open input file: ',trim(inab_file)
    Else
      Read(lun_ab,"(a)") abund_desc

      Do
        char_tmp = '     '
        real_tmp = 0.0_dp

        ! Read up to nread_max pairs at once. When the total entry count is not a multiple of
        ! nread_max, the final read populates the remaining leading elements of char_tmp/real_tmp
        ! and returns iostat_end; process any populated entries before exiting on EOF.
        Read(lun_ab,*,iostat=ierr) (char_tmp(i),real_tmp(i),i=1,nread_max)
        If ( ierr /= 0 .and. ierr /= iostat_end ) Then
          Write(lun_stderr,"(3a,i4,a)") 'Failed while trying to read input file: ', &
            & trim(inab_file),' (',ierr,')'
          Call xnet_terminate('Failed while trying to read input file: '//trim(inab_file),ierr)
        EndIf

        Do i = 1, nread_max
          namein = adjustl(char_tmp(i))
          If ( len_trim(namein) > 0 .and. real_tmp(i) > 0.0_dp ) Then
            Call string_lc(namein)
            If ( trim(namein) == 'ye' ) Then
              yein = real_tmp(i)
            Else
              Call index_from_name(namein,inuc)
              If ( inuc < 1 .or. inuc > ny ) Then
                If ( idiag >= 0 ) Write(lun_diag,"(3a)") 'Input Nuc: ',namein,' not found'
                yext = yext + real_tmp(i)
              Else
                yin(inuc) = real_tmp(i)
              EndIf
            EndIf
          EndIf
        EndDo

        If ( ierr == iostat_end ) Exit
      EndDo

      Close(lun_ab)
      ierr = 0

      ! Compute total mass and charge fractions inside the active network
      xnet = sum(yin * aa)
      znet = sum(yin * zz)
      If ( idiag >= 1 ) Write(lun_diag,"(a,4es15.7)") 'ynet, xnet, anet, znet: ', &
        & sum(yin(:)),xnet,xnet,znet

      ! Account for out-of-network species via an auxiliary nucleus or normalize in-network mass
      If ( yext > 0.0_dp .and. xnet < 1.0_dp .and. znet < yein ) Then
        xext = 1.0_dp - xnet
        aext = xext / yext
        If ( yein <= 0.0_dp .or. yein >= 1.0_dp ) Then
          zext = 0.0_dp
          Write(lun_diag,"(a)") 'WARNING: There are nuclei outside of the network, but Ye was not provided.'
          Write(lun_diag,"(a)") 'Assuming Z=0 for external nucleus. Please provide total Ye for accurate results.'
        Else
          zext = (yein - znet) * aext / xext
        EndIf
        If ( idiag >= 1 ) Write(lun_diag,"(a,4es15.7)") 'yext, xext, aext, zext: ', &
          & yext,xext,aext,zext
      Else
        xext = 0.0_dp
        aext = 1.0_dp
        zext = 0.0_dp
        yin  = yin / xnet
      EndIf
    EndIf
    !$omp end critical(ab_read)

    Return
  End Subroutine read_inab_file

End Module model_input_ascii
