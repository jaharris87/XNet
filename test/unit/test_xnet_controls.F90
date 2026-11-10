Program test_xnet_controls
  Use xnet_controls, Only: apply_standalone_controls, controls_finalize, nthread, normalize_xnet_controls, &
    & read_xnet_controls, set_xnet_controls_defaults, tid, validate_standalone_controls, &
    & validate_xnet_controls, write_controls, xnet_controls_t
  Use xnet_types, Only: dp
  Use, Intrinsic :: ieee_arithmetic, Only: ieee_negative_inf, ieee_positive_inf, &
    & ieee_quiet_nan, ieee_value
  Implicit None

  Type(xnet_controls_t) :: controls
  Character(256) :: message
  Integer :: ierr

  ! A bare object has deterministic sentinels and must not silently act like configured XNet.
  Call validate_xnet_controls(controls,ierr,message)
  If ( ierr == 0 ) Error Stop 'raw xnet_controls_t unexpectedly passed validation'

  ! The source include supplies the actual compiled defaults used by programmatic callers.
  Call set_xnet_controls_defaults(controls)
  Call validate_xnet_controls(controls,ierr,message)
  If ( ierr /= 0 ) Error Stop 'compiled XNet controls defaults failed validation: '//trim(message)
  If ( controls%nzone /= 1 .or. controls%isolv /= 1 .or. controls%kstmx /= 9999 ) Then
    Error Stop 'compiled XNet controls defaults have unexpected values'
  EndIf
  If ( abs(controls%changemx-1.0e-1_dp) > epsilon(controls%changemx) ) Then
    Error Stop 'compiled XNet changemx default has an unexpected value'
  EndIf

  controls%changemx = -1.0_dp
  Call validate_xnet_controls(controls,ierr,message)
  If ( ierr == 0 ) Error Stop 'invalid changemx sentinel passed validation'
  Call set_xnet_controls_defaults(controls)
  controls%yacc = -1.0_dp
  Call validate_xnet_controls(controls,ierr,message)
  If ( ierr == 0 ) Error Stop 'invalid yacc sentinel passed validation'
  Call set_xnet_controls_defaults(controls)
  controls%changemxt = -1.0_dp
  Call validate_xnet_controls(controls,ierr,message)
  If ( ierr == 0 ) Error Stop 'invalid changemxt sentinel passed validation'
  Call set_xnet_controls_defaults(controls)
  controls%tolt9 = -1.0_dp
  Call validate_xnet_controls(controls,ierr,message)
  If ( ierr == 0 ) Error Stop 'invalid tolt9 sentinel passed validation'
  Call set_xnet_controls_defaults(controls)
  controls%t9nse = -1.0_dp
  Call validate_xnet_controls(controls,ierr,message)
  If ( ierr == 0 ) Error Stop 'invalid t9nse sentinel passed validation'
  Call set_xnet_controls_defaults(controls)

  ! Programmatic callers can construct IEEE values even when a namelist runtime rejects their text.
  controls%changemx = ieee_value(0.0_dp,ieee_quiet_nan)
  Call validate_xnet_controls(controls,ierr,message)
  If ( ierr == 0 .or. Index(message,'must be finite') == 0 ) Then
    Error Stop 'generic controls validation accepted a quiet NaN'
  EndIf
  Call set_xnet_controls_defaults(controls)
  controls%yacc = ieee_value(0.0_dp,ieee_positive_inf)
  Call validate_xnet_controls(controls,ierr,message)
  If ( ierr == 0 .or. Index(message,'must be finite') == 0 ) Then
    Error Stop 'generic controls validation accepted positive infinity'
  EndIf
  Call set_xnet_controls_defaults(controls)
  controls%t9nse = ieee_value(0.0_dp,ieee_negative_inf)
  Call validate_xnet_controls(controls,ierr,message)
  If ( ierr == 0 .or. Index(message,'must be finite') == 0 ) Then
    Error Stop 'generic controls validation accepted negative infinity'
  EndIf
  Call set_xnet_controls_defaults(controls)

  ! Every requested condensed-output species must have a nonblank name.
  controls%nnucout = 3
  Deallocate(controls%output_nuclei)
  Allocate(controls%output_nuclei(3))
  controls%output_nuclei = ' '
  controls%output_nuclei(3) = 'he4'
  Call validate_xnet_controls(controls,ierr,message)
  If ( ierr == 0 .or. Index(message,'output_nuclei') == 0 ) Then
    Error Stop 'generic controls validation accepted blank output_nuclei entries'
  EndIf
  Call set_xnet_controls_defaults(controls)

  ! Standalone execution additionally requires problem-specific files and nuclear data.
  Call validate_standalone_controls(controls,ierr,message)
  If ( ierr == 0 ) Error Stop 'standalone controls unexpectedly accepted blank problem inputs'
  If ( Index(message,'data_dir') == 0 ) Error Stop 'standalone controls returned an unexpected error'

  ! HDF5 post-processing files contain many zones and must not receive per-zone filename suffixes.
  Call set_xnet_controls_defaults(controls)
  controls%nzone = 8
  controls%data_dir = 'Data_HDF'
  Deallocate(controls%inab_files,controls%thermo_files)
  Allocate(controls%inab_files(2),controls%thermo_files(2))
  controls%inab_files(1) = 'abundance.h5'
  controls%thermo_files(1) = 'particles.HDF5'
  controls%inab_files(2) = 'abundance-2.hdf'
  controls%thermo_files(2) = 'particles-2.h5'
  Call normalize_xnet_controls(controls,message)
  If ( Len_Trim(message) /= 0 ) Error Stop 'HDF5 controls normalization failed: '//trim(message)
  If ( size(controls%inab_files) /= controls%nzone .or. &
    & size(controls%thermo_files) /= controls%nzone ) Then
    Error Stop 'HDF5 controls arrays were not prepared for the execution-state transfer'
  EndIf
  If ( trim(controls%inab_files(1)) /= 'abundance.h5' .or. &
    & trim(controls%thermo_files(1)) /= 'particles.HDF5' .or. &
    & trim(controls%inab_files(2)) /= 'abundance-2.hdf' .or. &
    & trim(controls%thermo_files(2)) /= 'particles-2.h5' .or. &
    & Len_Trim(controls%inab_files(3)) /= 0 .or. &
    & Len_Trim(controls%thermo_files(3)) /= 0 ) Then
    Error Stop 'HDF5 input filenames were expanded as per-zone ASCII inputs'
  EndIf
  Call validate_standalone_controls(controls,ierr,message)
  If ( ierr /= 0 ) Error Stop 'HDF5 controls failed standalone validation: '//trim(message)

  controls%inab_files(2) = ' '
  controls%thermo_files(2) = ' '
  controls%inab_files(3) = 'abundance-3.h5'
  controls%thermo_files(3) = 'particles-3.h5'
  Call validate_standalone_controls(controls,ierr,message)
  If ( ierr == 0 ) Error Stop 'HDF5 controls unexpectedly accepted a hole in the file list'

  controls%nzone = 1
  controls%inab_files(2) = 'abundance-2.h5'
  controls%thermo_files(2) = 'particles-2.h5'
  Call normalize_xnet_controls(controls,message)
  If ( Index(message,'cannot exceed nzone') == 0 ) Then
    Error Stop 'HDF5 controls silently truncated an overlong file list'
  EndIf
  Call validate_standalone_controls(controls,ierr,message)
  If ( Index(message,'cannot exceed nzone') == 0 ) Then
    Error Stop 'HDF5 controls validation accepted an overlong file list'
  EndIf

  Call check_controls_round_trip(1)
  Call check_controls_round_trip(3)
  Write(*,'(a)') 'xnet_controls defaults, validation and round-trip checks passed'

Contains

  Subroutine check_controls_round_trip(solver)
    Implicit None

    ! write_controls must emit, and read_xnet_controls must restore, every control.  Give each
    ! field a non-default value in at least one solver case to detect missing copy-list entries.
    ! Add new controls here (and to controls.defaults) when they are added to xnet_controls_t.
    Integer, Intent(in) :: solver
    Type(xnet_controls_t) :: original, restored
    Character(80) :: data_dir
    Character(*), Parameter :: filename = 'xnet_controls_round_trip.nml'
    Integer :: lun

    Call set_xnet_controls_defaults(original)
    original%description = [Character(80) :: 'first line',"it's quoted",'third line']
    original%szone = 2
    original%nzone = 3
    original%iweak0 = -1
    original%iscrn = 0
    original%iprocess = 1
    original%nzbatchmx = 2
    original%isolv = solver
    original%kstmx = 123
    original%kitmx = 7
    original%ijac = 3
    original%iconvc = 1
    original%changemx = 0.25_dp
    original%yacc = 2.0e-8_dp
    original%tolm = 3.0e-7_dp
    original%tolc = 4.0e-5_dp
    original%ymin = 5.0e-29_dp
    original%tdel_maxmult = 1.5_dp
    original%iheat = 1
    original%changemxt = 0.02_dp
    original%tolt9 = 6.0e-5_dp
    original%t9nse = 7.5_dp
    original%ineutrino = 1
    original%idiag = 2
    original%itsout = 2
    original%ev_file_base = 'my_ev_'
    original%bin_file_base = 'my_ts_'
    original%nnucout = 2
    Deallocate(original%output_nuclei,original%inab_files,original%thermo_files)
    Allocate(original%output_nuclei(2),original%inab_files(3),original%thermo_files(3))
    original%output_nuclei = [Character(5) :: 'he4','c12']
    original%data_dir = 'Data_round_trip'
    original%inab_files = [Character(80) :: 'ab_1','ab_2','ab_3']
    original%thermo_files = [Character(80) :: 'th_1','th_2','th_3']

    ! Apply the controls the way the standalone driver does, then write the resolved controls.
    nthread = 1
    tid = 1
    Call apply_standalone_controls(original,data_dir)
    ! The resolved namelist records runtime values; BDF disables the BE change limits.
    If ( solver == 3 ) Then
      original%changemx = 1.0e10_dp
      original%changemxt = 1.0e10_dp
    EndIf
    Open(newunit=lun,file=filename,status='replace',action='write')
    Call write_controls(lun,data_dir)
    Close(lun)
    Call controls_finalize

    Call read_xnet_controls(restored,filename,ierr,message)
    Open(newunit=lun,file=filename,status='old')
    Close(lun,status='delete')
    If ( ierr /= 0 ) Error Stop 'round-trip controls could not be read: '//trim(message)

    If ( any(restored%description /= original%description) ) Error Stop 'round trip lost description'
    If ( restored%szone /= original%szone .or. restored%nzone /= original%nzone ) Then
      Error Stop 'round trip lost szone or nzone'
    EndIf
    If ( restored%iweak0 /= original%iweak0 .or. restored%iscrn /= original%iscrn .or. &
      & restored%iprocess /= original%iprocess .or. restored%nzbatchmx /= original%nzbatchmx ) Then
      Error Stop 'round trip lost a job control'
    EndIf
    If ( restored%isolv /= original%isolv .or. restored%kstmx /= original%kstmx .or. &
      & restored%kitmx /= original%kitmx .or. restored%ijac /= original%ijac .or. &
      & restored%iconvc /= original%iconvc ) Then
      Error Stop 'round trip lost an integer integration control'
    EndIf
    If ( restored%changemx /= original%changemx .or. restored%yacc /= original%yacc .or. &
      & restored%tolm /= original%tolm .or. restored%tolc /= original%tolc .or. &
      & restored%ymin /= original%ymin .or. restored%tdel_maxmult /= original%tdel_maxmult ) Then
      Error Stop 'round trip lost a real integration control'
    EndIf
    If ( restored%iheat /= original%iheat .or. restored%changemxt /= original%changemxt .or. &
      & restored%tolt9 /= original%tolt9 .or. restored%t9nse /= original%t9nse .or. &
      & restored%ineutrino /= original%ineutrino ) Then
      Error Stop 'round trip lost a self-heating, NSE or neutrino control'
    EndIf
    If ( restored%idiag /= original%idiag .or. restored%itsout /= original%itsout .or. &
      & restored%ev_file_base /= original%ev_file_base .or. restored%bin_file_base /= original%bin_file_base .or. &
      & restored%nnucout /= original%nnucout ) Then
      Error Stop 'round trip lost an output control'
    EndIf
    If ( size(restored%output_nuclei) /= 2 ) Error Stop 'round trip changed the size of output_nuclei'
    If ( any(restored%output_nuclei /= original%output_nuclei) ) Error Stop 'round trip lost output_nuclei'
    If ( restored%data_dir /= original%data_dir ) Error Stop 'round trip lost data_dir'
    If ( size(restored%inab_files) /= 3 .or. size(restored%thermo_files) /= 3 ) Then
      Error Stop 'round trip changed the number of input files'
    EndIf
    If ( any(restored%inab_files /= original%inab_files) .or. &
      & any(restored%thermo_files /= original%thermo_files) ) Error Stop 'round trip lost input files'

    Return
  End Subroutine check_controls_round_trip

End Program test_xnet_controls
