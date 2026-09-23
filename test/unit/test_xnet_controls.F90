Program test_xnet_controls
  Use xnet_controls, Only: normalize_xnet_controls, set_xnet_controls_defaults, &
    & validate_standalone_controls, validate_xnet_controls, xnet_controls_t
  Use xnet_types, Only: dp
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
  If ( ierr /= 0 ) Error Stop 'compiled XNet controls defaults failed validation: '//Trim(message)
  If ( controls%nzone /= 1 .or. controls%isolv /= 1 .or. controls%kstmx /= 9999 ) Then
    Error Stop 'compiled XNet controls defaults have unexpected values'
  EndIf
  If ( Abs(controls%changemx-1.0e-1_dp) > Epsilon(controls%changemx) ) Then
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

  ! Standalone execution additionally requires problem-specific files and nuclear data.
  Call validate_standalone_controls(controls,ierr,message)
  If ( ierr == 0 ) Error Stop 'standalone controls unexpectedly accepted blank problem inputs'
  If ( Index(message,'data_dir') == 0 ) Error Stop 'standalone controls returned an unexpected error'

  ! HDF5 post-processing files contain many zones and must not receive per-zone filename suffixes.
  Call set_xnet_controls_defaults(controls)
  controls%nzone = 8
  controls%data_dir = 'Data_HDF'
  Deallocate(controls%inab_files,controls%thermo_files)
  Allocate(controls%inab_files(1),controls%thermo_files(1))
  controls%inab_files(1) = 'abundance.h5'
  controls%thermo_files(1) = 'particles.HDF5'
  Call normalize_xnet_controls(controls,message)
  If ( Len_Trim(message) /= 0 ) Error Stop 'HDF5 controls normalization failed: '//Trim(message)
  If ( Size(controls%inab_files) /= controls%nzone .or. &
    & Size(controls%thermo_files) /= controls%nzone ) Then
    Error Stop 'HDF5 controls arrays were not prepared for the execution-state transfer'
  EndIf
  If ( Trim(controls%inab_files(1)) /= 'abundance.h5' .or. &
    & Trim(controls%thermo_files(1)) /= 'particles.HDF5' .or. &
    & Len_Trim(controls%inab_files(2)) /= 0 .or. &
    & Len_Trim(controls%thermo_files(2)) /= 0 ) Then
    Error Stop 'HDF5 input filenames were expanded as per-zone ASCII inputs'
  EndIf
  Call validate_standalone_controls(controls,ierr,message)
  If ( ierr /= 0 ) Error Stop 'HDF5 controls failed standalone validation: '//Trim(message)

  Write(*,'(a)') 'xnet_controls defaults and validation checks passed'
End Program test_xnet_controls
