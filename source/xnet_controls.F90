!***************************************************************************************************
! xnet_controls.f90
! This file contains modules and subroutines to control the execution of XNet.
!***************************************************************************************************

#include "xnet_macros.fh"

Module xnet_controls
  !-------------------------------------------------------------------------------------------------
  ! This module contains the flags and limits which control the behavior of the network.  Standalone
  ! XNet reads these values from a namelist into xnet_controls_t, validates the complete layered
  ! value, and then applies it to the established module execution state.  Programmatic callers can
  ! construct and validate xnet_controls_t without using the standalone file input.
  !-------------------------------------------------------------------------------------------------
  Use, Intrinsic :: iso_fortran_env, Only: lun_stderr=>error_unit, lun_stdin=>input_unit, &
    & lun_stdout=>output_unit
  Use xnet_types, Only: dp
  Implicit None

  Character(*), Parameter :: standalone_controls_file = 'controls.nml'
  Character(*), Parameter :: resolved_controls_file = 'controls.resolved.nml'
  Integer, Parameter :: max_includes_per_file = 16 ! Prevent accidental unbounded include fan-out
  Integer, Parameter :: max_include_depth = 16     ! Bound recursive input and detect runaway nesting
  Integer, Parameter :: config_path_length = 1024  ! Explicit configuration-path storage length

  Type :: xnet_controls_t
    ! Problem Description
    Character(80) :: description(3) = ' '

    ! Job Controls
    Integer :: szone = 1      ! Starting zone
    Integer :: nzone = 1      ! Number of zones
    Integer :: iweak0 = 1     ! >0: strong and weak; =0: no weak; <0: weak only
    Integer :: iscrn = 1      ! If =0, screening is ignored
    Integer :: iprocess = 0   ! If >0, process nuclear data at run time

    ! Zone Batching Controls
    Integer :: nzbatchmx = 1  ! Maximum number of zones in a batch

    ! Integration Controls
    Integer :: isolv = 1                ! Integration method (1=BE, 3=BDF)
    Integer :: kstmx = 9999             ! Maximum number of timesteps before exit
    Integer :: kitmx = 5                ! Maximum iterations within a timestep
    Integer :: ijac = 1                 ! Jacobian rebuild interval after the first iteration
    Integer :: iconvc = 0               ! Convergence condition (0=mass conservation)
    Real(dp) :: changemx = 1.0e-1_dp    ! Relative abundance change used to choose the timestep
    Real(dp) :: yacc = 1.0e-7_dp        ! Minimum abundance used in timestep determination
    Real(dp) :: tolm = 1.0e-6_dp        ! Maximum network mass error
    Real(dp) :: tolc = 1.0e-4_dp        ! Iterative convergence limit
    Real(dp) :: ymin = 1.0e-30_dp       ! Abundances below this value are set to zero
    Real(dp) :: tdel_maxmult = 2.0_dp   ! Maximum timestep growth factor

    ! Self-heating Controls
    Integer :: iheat = 0                ! If >0, couple the network implicitly to temperature
    Real(dp) :: changemxt = 1.0e-2_dp   ! Relative temperature change used to choose the timestep
    Real(dp) :: tolt9 = 1.0e-4_dp       ! Iterative temperature convergence limit

    ! NSE Initial Conditions Controls
    Real(dp) :: t9nse = 8.0_dp          ! Temperature in GK above which NSE initial conditions are used

    ! Neutrino Controls
    Integer :: ineutrino = 0            ! If >0, include neutrino capture reactions

    ! Output Controls
    Integer :: idiag = 0                ! Diagnostic output level
    Integer :: itsout = 0               ! Per-timestep output level
    Character(80) :: ev_file_base = 'ev_'  ! ASCII output filename base
    Character(80) :: bin_file_base = 'ts_' ! Binary output filename base
    Integer :: nnucout = 0              ! Number of species in condensed output
    Character(5), Allocatable :: output_nuclei(:)

    ! Input Controls used by the standalone driver
    Character(80) :: data_dir = ' '
    Character(80), Allocatable :: inab_files(:)
    Character(80), Allocatable :: thermo_files(:)
  End Type xnet_controls_t

  ! Problem Description
  Character(80) :: descript(3)

  ! Job Controls
  Integer              :: szone        ! Starting zone
  Integer              :: nzone        ! Number of zones
  Integer, Allocatable :: zone_id(:,:) ! Current zone index map (index, batch)
  Integer, Allocatable :: iweak(:)     ! Per-zone weak-reaction flag
  Integer              :: iweak0       ! Input weak-reaction flag
  Integer              :: iscrn        ! If =0, screening is ignored
  Integer              :: iprocess     ! If >0, process nuclear data at run time

  ! Zone Batching Controls
  Integer :: nzevolve                 ! Number of zones evolved concurrently
  Integer :: nzbatchmx                ! Maximum number of zones in a batch
  Integer :: nzbatch                  ! Active number of zones in a batch
  Integer :: szbatch                  ! Starting zone for a batch
  Integer :: zb_offset                ! Zone-batch offset in nzevolve
  Integer :: zb_lo                    ! Lower zone-batch extent in nzevolve
  Integer :: zb_hi                    ! Upper zone-batch extent in nzevolve
  Logical, Allocatable, Target :: lzactive(:) ! Active-zone mask
  !$omp threadprivate(nzbatch,szbatch,zb_offset,zb_lo,zb_hi)

  ! Integration Controls
  Integer :: isolv                   ! Integration method (1=BE, 3=BDF)
  Integer :: kstmx                   ! Maximum number of timesteps before exit
  Integer :: kitmx                   ! Maximum iterations within a timestep
  Integer :: ijac                    ! Jacobian rebuild interval after the first iteration
  Integer :: iconvc                  ! Convergence condition (0=mass conservation)
  Real(dp) :: changemx               ! Relative abundance change used to choose the timestep
  Real(dp) :: yacc                   ! Minimum abundance used in timestep determination
  Real(dp) :: tolc                   ! Iterative convergence limit
  Real(dp) :: tolm                   ! Maximum network mass error
  Real(dp) :: ymin                   ! Abundances below this value are set to zero
  Real(dp) :: tdel_maxmult           ! Maximum timestep growth factor
  Integer, Allocatable :: kmon(:,:)  ! Solver behavior monitors
  Integer, Allocatable :: ktot(:,:)  ! Cumulative solver behavior monitors
  Real(dp) :: t9min = 0.01_dp        ! Temperature minimum for strong reactions

  ! Self-heating Controls
  Integer :: iheat                   ! If >0, couple the network implicitly to temperature
  Real(dp) :: changemxt              ! Relative temperature change used to choose the timestep
  Real(dp) :: tolt9                  ! Iterative temperature convergence limit

  ! NSE Initial Conditions Controls
  Real(dp) :: t9nse = 8.0_dp         ! Temperature in GK above which NSE is used initially

  ! Neutrino Controls
  Integer :: ineutrino               ! If >0, include neutrino capture reactions

  ! Output Controls
  Integer :: nnucout                 ! Number of species in condensed output
  Integer :: idiag                   ! Diagnostic output level
  Integer :: itsout                  ! Per-timestep output level
  Character(4) :: nnucout_string     ! Condensed-output format field
  Integer, Allocatable :: inucout(:) ! Condensed-output species indices
  Integer, Allocatable :: lun_ts(:)  ! Per-zone time-series logical units
  Integer, Allocatable :: lun_ev(:)  ! Per-zone ASCII-output logical units
  Character(5), Allocatable :: output_nuc(:) ! Condensed-output species names
  Character(80) :: ev_file_base, bin_file_base ! Output filename bases
  Integer :: lun_diag                ! Per-thread diagnostic logical unit
  !$omp threadprivate(lun_diag)

  ! Input Controls
  Character(80) :: inab_file_base, thermo_file_base ! Input filename bases
  Character(80), Allocatable :: inab_file(:)        ! Per-zone initial-abundance files
  Character(80), Allocatable :: thermo_file(:)      ! Per-zone thermodynamic histories
  Integer :: lun_th, lun_ab                         ! Input logical units
  Integer, Allocatable :: iaux(:)                   ! Auxiliary-nucleus logical units
  !$omp threadprivate(lun_th,lun_ab)

  ! Execution and runtime bookkeeping
  Integer :: myid, nproc, tid, nthread ! Task and thread identifiers and counts
  Character(Len=1) :: sweep            ! Current hydrodynamic sweep: x, y, or z
  !$omp threadprivate(tid,sweep)

  Interface write_controls_line
    Module Procedure write_controls_line_i
    Module Procedure write_controls_line_r
  End Interface write_controls_line

  ! These execution controls are read by accelerator kernels and remain resident after input is
  ! applied.  Configuration parsing must not remove their established device declarations.
  !XDIR XDECLARE_VAR(iheat,iscrn,iconvc,ymin)

Contains

  Subroutine set_xnet_controls_defaults(controls)
    !-----------------------------------------------------------------------------------------------
    ! This routine constructs the compiled XNet controls without reading standalone input files.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Output variables
    Type(xnet_controls_t), Intent(out) :: controls

    controls = xnet_controls_t()
    Allocate(controls%output_nuclei(0),controls%inab_files(0),controls%thermo_files(0))

    Return
  End Subroutine set_xnet_controls_defaults

  Subroutine validate_xnet_controls(controls,message)
    !-----------------------------------------------------------------------------------------------
    ! This routine validates controls shared by standalone and programmatic XNet callers.  It does
    ! not require standalone nuclear-data, abundance, or thermodynamic-history filenames.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Input variables
    Type(xnet_controls_t), Intent(in) :: controls

    ! Output variables
    Character(*), Intent(out) :: message

    message = ' '

    If ( .not. Allocated(controls%inab_files) .or. .not. Allocated(controls%thermo_files) .or. &
      & .not. Allocated(controls%output_nuclei) ) Then
      message = 'XNet control arrays must be allocated'
    ElseIf ( controls%nzone < 1 ) Then
      message = 'nzone must be positive'
    ElseIf ( controls%nnucout < 0 ) Then
      message = 'nnucout must be nonnegative'
    ElseIf ( controls%nnucout > Size(controls%output_nuclei) ) Then
      message = 'nnucout exceeds the number of supplied output_nuclei'
    ElseIf ( controls%szone < 1 .or. controls%szone > controls%nzone ) Then
      message = 'szone must select an existing zone'
    ElseIf ( controls%isolv /= 1 .and. controls%isolv /= 3 ) Then
      message = 'isolv must be 1 (BE) or 3 (BDF)'
    ElseIf ( controls%nzbatchmx < 1 .or. controls%kitmx < 1 .or. controls%kstmx < 1 ) Then
      message = 'batch, iteration, and step limits must be positive'
    ElseIf ( controls%tolc <= 0.0_dp .or. controls%tolm <= 0.0_dp .or. controls%ymin < 0.0_dp ) Then
      message = 'integration tolerances must be positive and ymin nonnegative'
    EndIf

    Return
  End Subroutine validate_xnet_controls

  Subroutine validate_standalone_controls(controls,message)
    !-----------------------------------------------------------------------------------------------
    ! This routine adds the file-input requirements of the standalone XNet driver to the validation
    ! shared with programmatic callers.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Input variables
    Type(xnet_controls_t), Intent(in) :: controls

    ! Output variables
    Character(*), Intent(out) :: message

    Call validate_xnet_controls(controls,message)
    If ( Len_Trim(message) /= 0 ) Return

    If ( Len_Trim(controls%data_dir) == 0 ) Then
      message = 'data_dir is required for the standalone driver'
    ElseIf ( Size(controls%inab_files) < controls%nzone .or. &
      & Size(controls%thermo_files) < controls%nzone ) Then
      message = 'one inab_files and thermo_files entry is required per zone'
    ElseIf ( Any(Len_Trim(controls%inab_files(:controls%nzone)) == 0) .or. &
      & Any(Len_Trim(controls%thermo_files(:controls%nzone)) == 0) ) Then
      message = 'one inab_files and thermo_files entry is required per zone'
    EndIf

    Return
  End Subroutine validate_standalone_controls

  Subroutine read_xnet_controls(controls,filename,message)
    !-----------------------------------------------------------------------------------------------
    ! This routine reads the complete layered namelist on the XNet I/O rank, normalizes and validates
    ! the result, and broadcasts the same value to every rank.  Files named in include are applied in
    ! listed order after their including file, so the last included value has highest precedence.
    !-----------------------------------------------------------------------------------------------
    Use xnet_parallel, Only: parallel_bcast, parallel_IOProcessor
    Implicit None

    ! Input variables
    Character(*), Intent(in) :: filename

    ! Output variables
    Type(xnet_controls_t), Intent(out) :: controls
    Character(*), Intent(out) :: message

    ! Local variables
    Character(config_path_length) :: normalized_filename
    Character(config_path_length) :: ancestor_paths(max_include_depth)

    Call set_xnet_controls_defaults(controls)
    message = ' '
    ancestor_paths = ' '

    If ( parallel_IOProcessor() ) Then
      Call normalize_config_path(filename,normalized_filename,message)
      If ( Len_Trim(message) == 0 ) Then
        Call read_controls_file(controls,normalized_filename,1,ancestor_paths,message)
      EndIf
      If ( Len_Trim(message) == 0 ) Call normalize_xnet_controls(controls,message)
      If ( Len_Trim(message) == 0 ) Call validate_standalone_controls(controls,message)
    EndIf

    Call broadcast_xnet_controls(controls)
    Call parallel_bcast(message)

    Return
  End Subroutine read_xnet_controls

  Recursive Subroutine read_controls_file(controls,filename,depth,ancestor_paths,message)
    !-----------------------------------------------------------------------------------------------
    ! This routine applies one xnet_config namelist and then each of its includes in order.  A stack
    ! of lexically normalized paths detects direct and indirect cycles without delimiter parsing.
    ! Symbolic links are deliberately not resolved.
    !-----------------------------------------------------------------------------------------------
    Use xnet_util, Only: string_lc
    Implicit None

    ! Input variables
    Character(*), Intent(in) :: filename
    Integer, Intent(in) :: depth

    ! Input/Output variables
    Type(xnet_controls_t), Intent(inout) :: controls
    Character(config_path_length), Intent(inout) :: ancestor_paths(:)

    ! Output variables
    Character(*), Intent(out) :: message

    ! Namelist staging variables
    Character(config_path_length) :: include(max_includes_per_file+1)
    Character(80) :: description(3), ev_file_base, bin_file_base, data_dir
    Character(80), Allocatable :: inab_files(:), thermo_files(:)
    Character(5), Allocatable :: output_nuclei(:)
    Integer :: szone, nzone, iweak0, iscrn, iprocess, nzbatchmx
    Integer :: isolv, kstmx, kitmx, ijac, iconvc
    Integer :: iheat, ineutrino, idiag, itsout, nnucout
    Real(dp) :: changemx, yacc, tolm, tolc, ymin, tdel_maxmult
    Real(dp) :: changemxt, tolt9, t9nse
    Namelist /xnet_config/ description, szone, nzone, iweak0, iscrn, iprocess, nzbatchmx, isolv, &
      & kstmx, kitmx, ijac, iconvc, changemx, yacc, tolm, tolc, ymin, tdel_maxmult, iheat, &
      & changemxt, tolt9, t9nse, ineutrino, idiag, itsout, ev_file_base, bin_file_base, data_dir, &
      & nnucout, output_nuclei, inab_files, thermo_files, include

    ! Local variables
    Character(config_path_length) :: include_path, normalized_filename
    Character(:), Allocatable :: line
    Integer :: lun, ierr, i, array_capacity, input_count, output_count, file_size

    message = ' '
    Call normalize_config_path(filename,normalized_filename,message)
    If ( Len_Trim(message) /= 0 ) Return

    If ( depth > max_include_depth ) Then
      message = 'configuration include depth limit exceeded: '//Trim(normalized_filename)
      Return
    ElseIf ( depth > 1 ) Then
      If ( Any(ancestor_paths(:depth-1) == normalized_filename) ) Then
        message = 'configuration include cycle: '//Trim(normalized_filename)
        Return
      EndIf
    EndIf
    ancestor_paths(depth) = normalized_filename

    Open(newunit=lun,file=Trim(normalized_filename),status='old',action='read',iostat=ierr)
    If ( ierr /= 0 ) Then
      message = 'failed to open configuration file: '//Trim(normalized_filename)
      Return
    EndIf

    Inquire(unit=lun,size=file_size,iostat=ierr)
    If ( ierr /= 0 ) Then
      message = 'failed to inspect configuration file: '//Trim(normalized_filename)
      Close(lun)
      Return
    EndIf
    Allocate(Character(Max(1,file_size)) :: line,stat=ierr)
    If ( ierr /= 0 ) Then
      message = 'unable to allocate configuration input record'
      Close(lun)
      Return
    EndIf

    ! Count separators and records, and inspect explicit subscripts, to obtain a file-derived upper
    ! bound for local namelist arrays.  This avoids imposing an XNet zone or output-species limit
    ! merely for namelist staging.
    array_capacity = Max(1,Size(controls%inab_files),Size(controls%thermo_files), &
      & Size(controls%output_nuclei))
    Do
      Read(lun,'(a)',iostat=ierr) line
      If ( ierr < 0 ) Exit
      If ( ierr > 0 ) Then
        message = 'failed to inspect configuration file: '//Trim(normalized_filename)
        Close(lun)
        Return
      EndIf
      array_capacity = array_capacity + 1
      Do i = 1, Len_Trim(line)
        If ( line(i:i) == ',' ) array_capacity = array_capacity + 1
      EndDo
      Call string_lc(line)
      array_capacity = Max(array_capacity,max_namelist_index(line,'inab_files'), &
        & max_namelist_index(line,'thermo_files'),max_namelist_index(line,'output_nuclei'))
    EndDo
    Rewind(lun)

    Allocate(inab_files(array_capacity),thermo_files(array_capacity), &
      & output_nuclei(array_capacity),stat=ierr)
    If ( ierr /= 0 ) Then
      message = 'unable to allocate configuration staging arrays'
      Close(lun)
      Return
    EndIf

    ! Begin with the value assembled by earlier layers.  Namelist input changes only named fields.
    include = ' '
    description = controls%description
    szone = controls%szone
    nzone = controls%nzone
    iweak0 = controls%iweak0
    iscrn = controls%iscrn
    iprocess = controls%iprocess
    nzbatchmx = controls%nzbatchmx
    isolv = controls%isolv
    kstmx = controls%kstmx
    kitmx = controls%kitmx
    ijac = controls%ijac
    iconvc = controls%iconvc
    changemx = controls%changemx
    yacc = controls%yacc
    tolm = controls%tolm
    tolc = controls%tolc
    ymin = controls%ymin
    tdel_maxmult = controls%tdel_maxmult
    iheat = controls%iheat
    changemxt = controls%changemxt
    tolt9 = controls%tolt9
    t9nse = controls%t9nse
    ineutrino = controls%ineutrino
    idiag = controls%idiag
    itsout = controls%itsout
    ev_file_base = controls%ev_file_base
    bin_file_base = controls%bin_file_base
    data_dir = controls%data_dir
    nnucout = controls%nnucout
    inab_files = ' '
    thermo_files = ' '
    output_nuclei = ' '
    If ( Size(controls%inab_files) > 0 ) Then
      inab_files(:Size(controls%inab_files)) = controls%inab_files
    EndIf
    If ( Size(controls%thermo_files) > 0 ) Then
      thermo_files(:Size(controls%thermo_files)) = controls%thermo_files
    EndIf
    If ( Size(controls%output_nuclei) > 0 ) Then
      output_nuclei(:Size(controls%output_nuclei)) = controls%output_nuclei
    EndIf

    Read(lun,nml=xnet_config,iostat=ierr)
    Close(lun)
    If ( ierr /= 0 ) Then
      Write(message,'(a,i0,a)') 'malformed or unknown xnet_config namelist, iostat=',ierr, &
        & ' in '//Trim(normalized_filename)
      Return
    ElseIf ( Len_Trim(include(max_includes_per_file+1)) /= 0 ) Then
      Write(message,'(a,i0,a)') 'configuration file has more than ',max_includes_per_file, &
        & ' direct includes: '//Trim(normalized_filename)
      Return
    EndIf

    ! Transfer the local namelist staging value to the single validated controls representation.
    controls%description = description
    controls%szone = szone
    controls%nzone = nzone
    controls%iweak0 = iweak0
    controls%iscrn = iscrn
    controls%iprocess = iprocess
    controls%nzbatchmx = nzbatchmx
    controls%isolv = isolv
    controls%kstmx = kstmx
    controls%kitmx = kitmx
    controls%ijac = ijac
    controls%iconvc = iconvc
    controls%changemx = changemx
    controls%yacc = yacc
    controls%tolm = tolm
    controls%tolc = tolc
    controls%ymin = ymin
    controls%tdel_maxmult = tdel_maxmult
    controls%iheat = iheat
    controls%changemxt = changemxt
    controls%tolt9 = tolt9
    controls%t9nse = t9nse
    controls%ineutrino = ineutrino
    controls%idiag = idiag
    controls%itsout = itsout
    controls%ev_file_base = ev_file_base
    controls%bin_file_base = bin_file_base
    controls%data_dir = data_dir
    controls%nnucout = nnucout

    input_count = Max(last_nonblank(inab_files),last_nonblank(thermo_files))
    output_count = last_nonblank(output_nuclei)
    Call resize_input_controls(controls,input_count,message)
    If ( Len_Trim(message) /= 0 ) Return
    Call resize_output_controls(controls,output_count,message)
    If ( Len_Trim(message) /= 0 ) Return
    If ( input_count > 0 ) Then
      controls%inab_files = inab_files(:input_count)
      controls%thermo_files = thermo_files(:input_count)
    EndIf
    If ( output_count > 0 ) controls%output_nuclei = output_nuclei(:output_count)

    ! Apply includes after this file.  Later entries therefore have higher precedence, matching the
    ! established Model Generator input layering convention.
    Do i = 1, max_includes_per_file
      If ( Len_Trim(include(i)) == 0 ) Cycle
      Call resolve_include(normalized_filename,include(i),include_path,message)
      If ( Len_Trim(message) /= 0 ) Return
      Call read_controls_file(controls,include_path,depth+1,ancestor_paths,message)
      If ( Len_Trim(message) /= 0 ) Return
    EndDo
    ancestor_paths(depth) = ' '

    Return
  End Subroutine read_controls_file

  Integer Function max_namelist_index(line,name)
    !-----------------------------------------------------------------------------------------------
    ! This function returns the largest explicit positive subscript used for one namelist array on
    ! a line.  Malformed subscripts are left for the Fortran namelist reader to diagnose.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Input variables
    Character(*), Intent(in) :: line, name

    ! Local variables
    Integer :: close_parenthesis, ierr, offset, search_from, subscript

    max_namelist_index = 0
    search_from = 1
    Do
      offset = Index(line(search_from:),Trim(name)//'(')
      If ( offset == 0 ) Exit
      offset = search_from+offset+Len_Trim(name)-1
      close_parenthesis = Index(line(offset+1:),')')
      If ( close_parenthesis == 0 ) Exit
      close_parenthesis = offset+close_parenthesis
      Read(line(offset+1:close_parenthesis-1),*,iostat=ierr) subscript
      If ( ierr == 0 .and. subscript > 0 ) max_namelist_index = Max(max_namelist_index,subscript)
      search_from = close_parenthesis+1
      If ( search_from > Len_Trim(line) ) Exit
    EndDo

    Return
  End Function max_namelist_index

  Subroutine normalize_xnet_controls(controls,message)
    !-----------------------------------------------------------------------------------------------
    ! This routine expands the historical one-file-pair input convention after all namelist layers
    ! have been applied.  It does not change numerical controls.
    !-----------------------------------------------------------------------------------------------
    Use xnet_util, Only: name_ordered
    Implicit None

    ! Input/Output variables
    Type(xnet_controls_t), Intent(inout) :: controls

    ! Output variables
    Character(*), Intent(out) :: message

    ! Local variables
    Character(80) :: inab_file_base, thermo_file_base
    Integer :: izone, nfiles

    message = ' '
    If ( controls%nzone < 1 ) Return

    Call resize_input_controls(controls,controls%nzone,message)
    If ( Len_Trim(message) /= 0 ) Return

    nfiles = 0
    Do izone = 1, controls%nzone
      If ( Len_Trim(controls%inab_files(izone)) == 0 .neqv. &
        & Len_Trim(controls%thermo_files(izone)) == 0 ) Then
        message = 'each input file entry needs both inab_files and thermo_files'
        Return
      EndIf
      If ( Len_Trim(controls%inab_files(izone)) /= 0 ) nfiles = izone
    EndDo

    If ( nfiles == 1 .and. controls%nzone > 1 .and. &
      & Index(controls%thermo_files(1),'.h5') == 0 .and. &
      & Index(controls%thermo_files(1),'.hdf') == 0 ) Then
      inab_file_base = controls%inab_files(1)
      thermo_file_base = controls%thermo_files(1)
      Do izone = 1, controls%nzone
        controls%inab_files(izone) = Trim(inab_file_base)
        controls%thermo_files(izone) = Trim(thermo_file_base)
        Call name_ordered(controls%inab_files(izone),izone,controls%nzone)
        Call name_ordered(controls%thermo_files(izone),izone,controls%nzone)
      EndDo
    ElseIf ( nfiles /= controls%nzone ) Then
      message = 'one input file pair or one pair per zone is required'
    EndIf

    Return
  End Subroutine normalize_xnet_controls

  Subroutine normalize_config_path(input_path,path,message)
    !-----------------------------------------------------------------------------------------------
    ! This routine lexically removes repeated separators and . or .. components.  It intentionally
    ! does not resolve symbolic links or query the filesystem for a canonical path.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Input variables
    Character(*), Intent(in) :: input_path

    ! Output variables
    Character(config_path_length), Intent(out) :: path
    Character(*), Intent(out) :: message

    ! Local variables
    Character(config_path_length), Allocatable :: part(:)
    Integer :: first, last, input_length, nparts, i
    Logical :: absolute

    path = ' '
    message = ' '
    input_length = Len_Trim(input_path)
    If ( input_length == 0 ) Return
    If ( input_length > config_path_length ) Then
      message = 'configuration path exceeds supported length'
      Return
    EndIf

    Allocate(part(Max(1,input_length)))
    part = ' '
    absolute = input_path(1:1) == '/'
    nparts = 0
    first = 1

    Do While ( first <= input_length )
      Do While ( first <= input_length )
        If ( input_path(first:first) /= '/' ) Exit
        first = first + 1
      EndDo
      If ( first > input_length ) Exit
      last = first
      Do While ( last <= input_length )
        If ( input_path(last:last) == '/' ) Exit
        last = last + 1
      EndDo

      If ( input_path(first:last-1) == '.' ) Then
        Continue
      ElseIf ( input_path(first:last-1) == '..' ) Then
        If ( nparts > 0 .and. Trim(part(nparts)) /= '..' ) Then
          nparts = nparts - 1
        ElseIf ( .not. absolute ) Then
          nparts = nparts + 1
          part(nparts) = '..'
        EndIf
      Else
        nparts = nparts + 1
        part(nparts) = input_path(first:last-1)
      EndIf
      first = last + 1
    EndDo

    If ( absolute ) path = '/'
    Do i = 1, nparts
      If ( Len_Trim(path) > 0 .and. Trim(path) /= '/' ) path = Trim(path)//'/'
      path = Trim(path)//Trim(part(i))
    EndDo
    If ( Len_Trim(path) == 0 ) Then
      If ( absolute ) Then
        path = '/'
      Else
        path = '.'
      EndIf
    EndIf

    Deallocate(part)
    Return
  End Subroutine normalize_config_path

  Subroutine resolve_include(parent,child,path,message)
    !-----------------------------------------------------------------------------------------------
    ! This routine resolves a configuration include relative to the directory of its including file.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Input variables
    Character(*), Intent(in) :: parent, child

    ! Output variables
    Character(config_path_length), Intent(out) :: path
    Character(*), Intent(out) :: message

    ! Local variables
    Character(2*config_path_length+1) :: combined_path
    Integer :: slash

    combined_path = ' '
    If ( Len_Trim(child) == 0 ) Then
      message = 'configuration include path is empty'
      Return
    ElseIf ( child(1:1) == '/' ) Then
      combined_path = Trim(child)
    Else
      slash = Scan(Trim(parent),'/',back=.True.)
      If ( slash > 0 ) Then
        combined_path = parent(:slash)//Trim(child)
      Else
        combined_path = Trim(child)
      EndIf
    EndIf

    Call normalize_config_path(Trim(combined_path),path,message)

    Return
  End Subroutine resolve_include

  Subroutine resize_input_controls(controls,new_size,message)
    !-----------------------------------------------------------------------------------------------
    ! This routine resizes the standalone filename arrays while preserving assembled layered values.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Input variables
    Integer, Intent(in) :: new_size

    ! Input/Output variables
    Type(xnet_controls_t), Intent(inout) :: controls

    ! Output variables
    Character(*), Intent(out) :: message

    ! Local variables
    Character(80), Allocatable :: new_inab_files(:), new_thermo_files(:)
    Integer :: copy_size, ierr

    message = ' '
    If ( new_size < 0 ) Then
      message = 'configuration input-array size must be nonnegative'
      Return
    ElseIf ( Size(controls%inab_files) == new_size .and. &
      & Size(controls%thermo_files) == new_size ) Then
      Return
    EndIf

    Allocate(new_inab_files(new_size),new_thermo_files(new_size),stat=ierr)
    If ( ierr /= 0 ) Then
      message = 'unable to allocate standalone input filenames'
      Return
    EndIf
    new_inab_files = ' '
    new_thermo_files = ' '
    copy_size = Min(new_size,Size(controls%inab_files),Size(controls%thermo_files))
    If ( copy_size > 0 ) Then
      new_inab_files(:copy_size) = controls%inab_files(:copy_size)
      new_thermo_files(:copy_size) = controls%thermo_files(:copy_size)
    EndIf
    Call Move_Alloc(new_inab_files,controls%inab_files)
    Call Move_Alloc(new_thermo_files,controls%thermo_files)

    Return
  End Subroutine resize_input_controls

  Subroutine resize_output_controls(controls,new_size,message)
    !-----------------------------------------------------------------------------------------------
    ! This routine resizes the condensed-output species array while preserving layered values.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Input variables
    Integer, Intent(in) :: new_size

    ! Input/Output variables
    Type(xnet_controls_t), Intent(inout) :: controls

    ! Output variables
    Character(*), Intent(out) :: message

    ! Local variables
    Character(5), Allocatable :: new_output_nuclei(:)
    Integer :: copy_size, ierr

    message = ' '
    If ( new_size < 0 ) Then
      message = 'configuration output-array size must be nonnegative'
      Return
    ElseIf ( Size(controls%output_nuclei) == new_size ) Then
      Return
    EndIf

    Allocate(new_output_nuclei(new_size),stat=ierr)
    If ( ierr /= 0 ) Then
      message = 'unable to allocate output_nuclei'
      Return
    EndIf
    new_output_nuclei = ' '
    copy_size = Min(new_size,Size(controls%output_nuclei))
    If ( copy_size > 0 ) new_output_nuclei(:copy_size) = controls%output_nuclei(:copy_size)
    Call Move_Alloc(new_output_nuclei,controls%output_nuclei)

    Return
  End Subroutine resize_output_controls

  Integer Function last_nonblank(strings)
    !-----------------------------------------------------------------------------------------------
    ! This function returns the final nonblank element of a namelist character array.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Input variables
    Character(*), Intent(in) :: strings(:)

    ! Local variables
    Integer :: i

    last_nonblank = 0
    Do i = Size(strings), 1, -1
      If ( Len_Trim(strings(i)) /= 0 ) Then
        last_nonblank = i
        Exit
      EndIf
    EndDo

    Return
  End Function last_nonblank

  Subroutine apply_xnet_controls(controls,data_dir)
    !-----------------------------------------------------------------------------------------------
    ! This routine transfers one validated input value to the established XNet module execution state.
    ! Keeping this boundary local avoids a global-state refactor in the configuration migration.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Input variables
    Type(xnet_controls_t), Intent(in) :: controls

    ! Output variables
    Character(*), Intent(out) :: data_dir

    ! Local variables
    Character(256) :: message

    Call validate_standalone_controls(controls,message)
    If ( Len_Trim(message) /= 0 ) Error Stop Trim(message)

    descript = controls%description
    szone = controls%szone
    nzone = controls%nzone
    iweak0 = controls%iweak0
    iscrn = controls%iscrn
    iprocess = controls%iprocess
    nzbatchmx = controls%nzbatchmx
    isolv = controls%isolv
    kstmx = controls%kstmx
    kitmx = controls%kitmx
    ijac = controls%ijac
    iconvc = controls%iconvc
    changemx = controls%changemx
    yacc = controls%yacc
    tolm = controls%tolm
    tolc = controls%tolc
    ymin = controls%ymin
    tdel_maxmult = controls%tdel_maxmult
    iheat = controls%iheat
    changemxt = controls%changemxt
    tolt9 = controls%tolt9
    t9nse = controls%t9nse
    ineutrino = controls%ineutrino
    idiag = controls%idiag
    itsout = controls%itsout
    ev_file_base = controls%ev_file_base
    bin_file_base = controls%bin_file_base
    nnucout = controls%nnucout
    data_dir = controls%data_dir

    ! The BDF integrator does not need the additional Backward-Euler change limits.
    If ( isolv == 3 ) Then
      changemx = 1.0e10_dp
      changemxt = 1.0e10_dp
    EndIf

    nzevolve = nzbatchmx*nthread
    Allocate(zone_id(3,nzevolve),lzactive(nzevolve),iweak(nzevolve),lun_ev(nzevolve),lun_ts(nzevolve))
    Allocate(kmon(5,nzevolve),ktot(5,nzevolve),inab_file(nzone),thermo_file(nzone))
    Allocate(output_nuc(nnucout),inucout(nnucout))
    inab_file = controls%inab_files(:nzone)
    thermo_file = controls%thermo_files(:nzone)
    If ( nnucout > 0 ) output_nuc = controls%output_nuclei(:nnucout)
    Write(nnucout_string,'(i4)') nnucout
    nnucout_string = Adjustl(nnucout_string)

    !$omp parallel default(shared)
    zb_offset = (tid-1)*nzbatchmx
    zb_lo = zb_offset+1
    zb_hi = zb_offset+nzbatchmx
    !$omp end parallel

    ! Update scalar controls and create per-zone arrays on the selected device after the validated
    ! controls have been applied.  These directives preserve the pre-namelist accelerator behavior.
    !XDIR XUPDATE XASYNC(tid) &
    !XDIR XDEVICE(iheat,iscrn,iconvc,ymin)

    !XDIR XENTER_DATA XASYNC(tid) &
    !XDIR XCREATE(lzactive,iweak,kmon,ktot)

    Return
  End Subroutine apply_xnet_controls

  Subroutine read_controls(data_dir)
    !-----------------------------------------------------------------------------------------------
    ! This routine reads, validates, applies, and records the standalone XNet controls.
    !-----------------------------------------------------------------------------------------------
    Use xnet_parallel, Only: parallel_IOProcessor
    Use xnet_util, Only: xnet_terminate
    Implicit None

    ! Output variables
    Character(80), Intent(out) :: data_dir

    ! Local variables
    Type(xnet_controls_t) :: controls
    Character(256) :: message

    Call read_xnet_controls(controls,standalone_controls_file,message)
    If ( Len_Trim(message) /= 0 ) Call xnet_terminate(Trim(message))
    Call apply_xnet_controls(controls,data_dir)
    If ( parallel_IOProcessor() ) Call write_resolved_controls(controls,resolved_controls_file)

    Return
  End Subroutine read_controls

  Subroutine write_resolved_controls(controls,filename)
    !-----------------------------------------------------------------------------------------------
    ! This routine writes the fully resolved controls as a human-readable reproducibility artifact.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Input variables
    Type(xnet_controls_t), Intent(in) :: controls
    Character(*), Intent(in) :: filename

    ! Local variables
    Integer :: lun, i, ierr

    Open(newunit=lun,file=filename,status='replace',action='write',iostat=ierr)
    If ( ierr /= 0 ) Return

    Write(lun,'(a)') '! Resolved defaults and layered overrides used for this run.'
    Write(lun,'(a)') '&xnet_config'
    Do i = 1, 3
      Write(lun,'(a,i0,a,a,a)') '  description(',i,") = '",Trim(controls%description(i)),"',"
    EndDo
    Write(lun,'(a,i0,a)') '  szone = ',controls%szone,','
    Write(lun,'(a,i0,a)') '  nzone = ',controls%nzone,','
    Write(lun,'(a,i0,a)') '  iweak0 = ',controls%iweak0,','
    Write(lun,'(a,i0,a)') '  iscrn = ',controls%iscrn,','
    Write(lun,'(a,i0,a)') '  iprocess = ',controls%iprocess,','
    Write(lun,'(a,i0,a)') '  nzbatchmx = ',controls%nzbatchmx,','
    Write(lun,'(a,i0,a)') '  isolv = ',controls%isolv,','
    Write(lun,'(a,i0,a)') '  kstmx = ',controls%kstmx,','
    Write(lun,'(a,i0,a)') '  kitmx = ',controls%kitmx,','
    Write(lun,'(a,i0,a)') '  ijac = ',controls%ijac,','
    Write(lun,'(a,i0,a)') '  iconvc = ',controls%iconvc,','
    Write(lun,'(a,es24.16,a)') '  changemx = ',controls%changemx,','
    Write(lun,'(a,es24.16,a)') '  yacc = ',controls%yacc,','
    Write(lun,'(a,es24.16,a)') '  tolm = ',controls%tolm,','
    Write(lun,'(a,es24.16,a)') '  tolc = ',controls%tolc,','
    Write(lun,'(a,es24.16,a)') '  ymin = ',controls%ymin,','
    Write(lun,'(a,es24.16,a)') '  tdel_maxmult = ',controls%tdel_maxmult,','
    Write(lun,'(a,i0,a)') '  iheat = ',controls%iheat,','
    Write(lun,'(a,es24.16,a)') '  changemxt = ',controls%changemxt,','
    Write(lun,'(a,es24.16,a)') '  tolt9 = ',controls%tolt9,','
    Write(lun,'(a,es24.16,a)') '  t9nse = ',controls%t9nse,','
    Write(lun,'(a,i0,a)') '  ineutrino = ',controls%ineutrino,','
    Write(lun,'(a,i0,a)') '  idiag = ',controls%idiag,','
    Write(lun,'(a,i0,a)') '  itsout = ',controls%itsout,','
    Write(lun,'(3a)') "  ev_file_base = '",Trim(controls%ev_file_base),"',"
    Write(lun,'(3a)') "  bin_file_base = '",Trim(controls%bin_file_base),"',"
    Write(lun,'(a,i0,a)') '  nnucout = ',controls%nnucout,','
    Do i = 1, controls%nnucout
      Write(lun,'(a,i0,a,a,a)') '  output_nuclei(',i,") = '",Trim(controls%output_nuclei(i)),"',"
    EndDo
    Write(lun,'(3a)') "  data_dir = '",Trim(controls%data_dir),"',"
    Do i = 1, controls%nzone
      Write(lun,'(a,i0,a,a,a)') '  inab_files(',i,") = '",Trim(controls%inab_files(i)),"',"
      Write(lun,'(a,i0,a,a,a)') '  thermo_files(',i,") = '",Trim(controls%thermo_files(i)),"',"
    EndDo
    Write(lun,'(a)') '/'
    Close(lun)

    Return
  End Subroutine write_resolved_controls

  Subroutine write_controls(lun_out,data_dir)
    !-----------------------------------------------------------------------------------------------
    ! This routine writes the active XNet controls to diagnostic output in the historical format.
    !-----------------------------------------------------------------------------------------------
    Use xnet_parallel, Only: parallel_IOProcessor
    Implicit None

    ! Input variables
    Integer, Intent(in) :: lun_out
    Character(*), Intent(in) :: data_dir

    ! Local variables
    Integer :: i, izone

    If ( idiag >= 0 .or. ( idiag >= -1 .and. parallel_IOProcessor() ) ) Then
      Write(lun_out,'(a)') '## Problem Description'
      Write(lun_out,'(a)') (descript(i), i=1,3)
      Write(lun_out,'(a)') '## Job Controls'
      Call write_controls_line(lun_out,szone,'Initial Zone')
      Call write_controls_line(lun_out,nzone,'# of Zones')
      Call write_controls_line(lun_out,iweak0,'Include Weak Reactions (yes=1,no=0,only=-1)')
      Call write_controls_line(lun_out,iscrn,'Include Screening (yes=1)')
      Call write_controls_line(lun_out,iprocess,'Process Nuclear Data at Run Time (yes=1,no=0)')
      Write(lun_out,'(a)') '## Neutrinos'
      Call write_controls_line(lun_out,ineutrino,'Include Neutrino Reactions (yes=1, no=0)')
      Write(lun_out,'(a)') '## NSE Initial Conditions'
      Call write_controls_line(lun_out,t9nse,'Temperature in GK to use NSE initial conditions instead of file')
      Write(lun_out,'(a)') '## Integration Controls'
      Call write_controls_line(lun_out,isolv,'Choice of integration Scheme (1=Backward Euler, 3=Backward Differentiation'// &
        & ' Formula, 2=obsolete Bader-Deuflhard)')
      Call write_controls_line(lun_out,kstmx,'Max. number of timesteps before quit')
      Call write_controls_line(lun_out,kitmx,'Max. iterations per step')
      Call write_controls_line(lun_out,ijac,'Rebuild the jacobian every ijac iterations after the first')
      Call write_controls_line(lun_out,iconvc,'Convergence Condition (Mass Cons.=0, (dY/Y small)=1)')
      Call write_controls_line(lun_out,changemx,'Max. Abundance Change per timestep')
      Call write_controls_line(lun_out,yacc,'Smallest Abundance used in timestep calculation')
      Call write_controls_line(lun_out,tolm,'Mass Conservation Limit')
      Call write_controls_line(lun_out,tolc,'Convergence Criterion')
      Call write_controls_line(lun_out,ymin,'Lower Abundance limit, smaller abundances = 0')
      Call write_controls_line(lun_out,tdel_maxmult,'Max. Factor to change dt in a timestep')
      Write(lun_out,'(a)') '## Self-heating Controls'
      Call write_controls_line(lun_out,iheat,'Include self-heating (yes=1,no=0)')
      Call write_controls_line(lun_out,changemxt,'Max. Temperature Change per timestep')
      Call write_controls_line(lun_out,tolt9,'Temperature Convergence Criterion')
      Write(lun_out,'(a)') '## Zone Batching Controls'
      Call write_controls_line(lun_out,nzbatchmx,'Blocking size for zone loop')
      Write(lun_out,*); Write(lun_out,'(a)') '## Output Controls'
      Call write_controls_line(lun_out,idiag,'Diagnostic Output Level')
      Call write_controls_line(lun_out,itsout,'Per Timestep Output Level')
      Write(lun_out,'(a)') '# ASCII output filename root, network will append zone number'
      Write(lun_out,'(a)') Trim(Adjustl(ev_file_base))
      Write(lun_out,'(a)') '# Binary output filename root, network will append zone number'
      Write(lun_out,'(a)') Trim(Adjustl(bin_file_base))
      Write(lun_out,'(a)') '# Species to output in ASCII output (format 14a5): 14'
      Write(lun_out,'(14a5)') output_nuc
      Write(lun_out,'(a)') '## Input Controls'
      Write(lun_out,'(a)') '# Nuclear Data Directory'
      Write(lun_out,'(a)') Trim(Adjustl(data_dir))
      Write(lun_out,'(a)') '# Initial Abundance and Thermodynamic Trajectory Files'
      Do izone = 1, nzone
        Write(lun_out,'(a)') inab_file(izone)
        Write(lun_out,'(a)') thermo_file(izone)
      EndDo
    EndIf

    Return
  End Subroutine write_controls

  Subroutine write_controls_line_i(lun_out,inum,desc)
    !-----------------------------------------------------------------------------------------------
    ! This routine writes a left-aligned integer control and its description to diagnostic output.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Input variables
    Integer, Intent(in) :: lun_out, inum
    Character(*), Intent(in) :: desc

    ! Local variables
    Character(9) :: str_num
    Character(Len=Len_Trim(Adjustl(desc))+10) :: line

    Write(str_num,'(i9)') inum
    Write(line,'(a9,1x,a)') Adjustl(str_num), Trim(Adjustl(desc))
    Write(lun_out,'(a)') Adjustl(line)

    Return
  End Subroutine write_controls_line_i

  Subroutine write_controls_line_r(lun_out,rnum,desc)
    !-----------------------------------------------------------------------------------------------
    ! This routine writes a left-aligned real control and its description to diagnostic output.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Input variables
    Integer, Intent(in) :: lun_out
    Real(dp), Intent(in) :: rnum
    Character(*), Intent(in) :: desc

    ! Local variables
    Character(9) :: str_num
    Character(Len=Len_Trim(Adjustl(desc))+10) :: line

    Write(str_num,'(ES9.2)') rnum
    Write(line,'(a9,1x,a)') Adjustl(str_num), Trim(Adjustl(desc))
    Write(lun_out,'(a)') Adjustl(line)

    Return
  End Subroutine write_controls_line_r

  Subroutine broadcast_xnet_controls(controls)
    !-----------------------------------------------------------------------------------------------
    ! This routine broadcasts one assembled XNet-control value.  Array extents are sent first so
    ! ranks other than the I/O rank can allocate the exact storage required by the input.
    !-----------------------------------------------------------------------------------------------
    Use xnet_parallel, Only: parallel_bcast, parallel_IOProcessor
    Implicit None

    ! Input/Output variables
    Type(xnet_controls_t), Intent(inout) :: controls

    ! Local variables
    Integer :: input_count, output_count

    If ( parallel_IOProcessor() ) Then
      input_count = Size(controls%inab_files)
      output_count = Size(controls%output_nuclei)
    Else
      input_count = 0
      output_count = 0
    EndIf

    Call parallel_bcast(input_count)
    Call parallel_bcast(output_count)

    If ( .not. parallel_IOProcessor() ) Then
      If ( Allocated(controls%inab_files) ) Deallocate(controls%inab_files)
      If ( Allocated(controls%thermo_files) ) Deallocate(controls%thermo_files)
      If ( Allocated(controls%output_nuclei) ) Deallocate(controls%output_nuclei)
      Allocate(controls%inab_files(input_count),controls%thermo_files(input_count))
      Allocate(controls%output_nuclei(output_count))
    EndIf

    Call parallel_bcast(controls%description)
    Call parallel_bcast(controls%szone)
    Call parallel_bcast(controls%nzone)
    Call parallel_bcast(controls%iweak0)
    Call parallel_bcast(controls%iscrn)
    Call parallel_bcast(controls%iprocess)
    Call parallel_bcast(controls%nzbatchmx)
    Call parallel_bcast(controls%isolv)
    Call parallel_bcast(controls%kstmx)
    Call parallel_bcast(controls%kitmx)
    Call parallel_bcast(controls%ijac)
    Call parallel_bcast(controls%iconvc)
    Call parallel_bcast(controls%changemx)
    Call parallel_bcast(controls%yacc)
    Call parallel_bcast(controls%tolm)
    Call parallel_bcast(controls%tolc)
    Call parallel_bcast(controls%ymin)
    Call parallel_bcast(controls%tdel_maxmult)
    Call parallel_bcast(controls%iheat)
    Call parallel_bcast(controls%changemxt)
    Call parallel_bcast(controls%tolt9)
    Call parallel_bcast(controls%t9nse)
    Call parallel_bcast(controls%ineutrino)
    Call parallel_bcast(controls%idiag)
    Call parallel_bcast(controls%itsout)
    Call parallel_bcast(controls%ev_file_base)
    Call parallel_bcast(controls%bin_file_base)
    Call parallel_bcast(controls%data_dir)
    Call parallel_bcast(controls%nnucout)
    If ( output_count > 0 ) Call parallel_bcast(controls%output_nuclei)
    If ( input_count > 0 ) Then
      Call parallel_bcast(controls%inab_files)
      Call parallel_bcast(controls%thermo_files)
    EndIf

    Return
  End Subroutine broadcast_xnet_controls
End Module xnet_controls
