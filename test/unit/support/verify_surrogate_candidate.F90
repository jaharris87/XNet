Program verify_surrogate_candidate
  !-----------------------------------------------------------------------------------------------
  ! Load production nuclear metadata and apply the surrogate-result checks to a candidate written
  ! by the process-level full_net tests. This is a test adapter, not a user-facing file format.
  !-----------------------------------------------------------------------------------------------
  Use nuclear_data, Only: aa, be, nname, ny, read_nuclear_data, zz
  Use xnet_controls, Only: iheat, nzevolve, tid
  Use xnet_surrogate_checks, Only: bn_check_surrogate_result, bn_surrogate_check_config, &
    & bn_surrogate_check_report
  Use xnet_types, Only: dp
  Implicit None

  Character(5), Allocatable :: candidate_names(:)
  Character(64) :: verification_token
  Character(80) :: data_desc
  Character(256) :: candidate_file, data_dir
  Integer :: candidate_ny, ierr, lun_candidate
  Real(dp), Allocatable :: x_initial(:), x_result(:)
  Type(bn_surrogate_check_config) :: config
  Type(bn_surrogate_check_report) :: report

  If ( command_argument_count() /= 2 ) Then
    Write(*,*) 'usage: verify_surrogate_candidate DATA_DIR CANDIDATE_FILE'
    Stop 1
  EndIf
  Call get_command_argument(1,data_dir)
  Call get_command_argument(2,candidate_file)

  iheat = 0
  nzevolve = 1
  tid = 1
  Call read_nuclear_data(trim(data_dir),data_desc)

  Open(newunit=lun_candidate,file=trim(candidate_file),status='old',action='read',iostat=ierr)
  Call require(ierr == 0,'failed to open candidate file')
  Read(lun_candidate,*,iostat=ierr) candidate_ny
  Call require(ierr == 0 .and. candidate_ny == ny,'candidate species count mismatch')
  Read(lun_candidate,'(a)',iostat=ierr) verification_token
  Call require(ierr == 0 .and. len_trim(verification_token) > 0,'missing verification token')
  Allocate(candidate_names(ny))
  Read(lun_candidate,*,iostat=ierr) candidate_names
  Call require(ierr == 0,'failed to read candidate species identity')
  Call require(all(adjustl(candidate_names) == adjustl(nname(1:ny))), &
    & 'candidate species identity does not match production metadata')
  Read(lun_candidate,*,iostat=ierr) config%fraction_tolerance,config%mass_tolerance, &
    & config%ye_tolerance
  Call require(ierr == 0,'failed to read candidate tolerances')
  Allocate(x_initial(ny),x_result(ny))
  Read(lun_candidate,*,iostat=ierr) x_initial
  Call require(ierr == 0,'failed to read initial composition')
  Read(lun_candidate,*,iostat=ierr) x_result
  Call require(ierr == 0,'failed to read result composition')
  Close(lun_candidate)

  config%check_finite = 1
  config%check_fraction_bounds = 1
  config%check_mass_normalization = 1
  config%check_fixed_ye = 1
  Call bn_check_surrogate_result(config,1,x_initial,x_result,aa,zz,be,1.0_dp,0.0_dp,report)

  Write(*,'(a,1x,a)') 'verification_token',trim(verification_token)
  Write(*,'(a,1x,i0)') 'metadata_identity',1
  Write(*,'(a,1x,i0)') 'overall_status',report%overall_status
  Write(*,'(a,1x,i0)') 'finite_status',report%finite_status
  Write(*,'(a,1x,i0)') 'fraction_bounds_status',report%fraction_bounds_status
  Write(*,'(a,1x,i0)') 'mass_normalization_status',report%mass_normalization_status
  Write(*,'(a,1x,i0)') 'fixed_ye_status',report%fixed_ye_status
  Write(*,'(a,1x,es24.16)') 'mass_residual',report%mass_residual
  Write(*,'(a,1x,es24.16)') 'ye_residual',report%ye_residual

Contains

  Subroutine require(condition,message)
    Implicit None
    Logical, Intent(in) :: condition
    Character(*), Intent(in) :: message

    If ( .not. condition ) Then
      Write(*,*) trim(message)
      Stop 1
    EndIf

    Return
  End Subroutine require

End Program verify_surrogate_candidate
