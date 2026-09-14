Program verify_surrogate_candidate
  !-----------------------------------------------------------------------------------------------
  ! Load production nuclear metadata and apply the surrogate-result checks to a candidate written
  ! by the process-level full_net tests. This is a test adapter, not a user-facing file format.
  !-----------------------------------------------------------------------------------------------
  Use actual_eos_module, Only: actual_eos, actual_eos_finalize, actual_eos_init
  Use eos_type_module, Only: eos_input_rt, eos_t
  Use nuclear_data, Only: aa, be, nname, ny, read_nuclear_data, zz
  Use xnet_constants, Only: avn, epmev
  Use xnet_controls, Only: iheat, nzevolve, tid
  Use xnet_surrogate_checks, Only: bn_check_surrogate_result, bn_surrogate_check_config, &
    & bn_surrogate_check_report
  Use xnet_types, Only: dp
  Implicit None

  Character(5), Allocatable :: candidate_names(:)
  Character(64) :: verification_token
  Character(80) :: data_desc
  Character(256) :: candidate_file, data_dir
  Integer :: candidate_ny, ierr, lun_candidate, step_checks_enabled
  Real(dp) :: electron_fraction, energy_rate, energy_rate_scale, initial_specific_internal_energy
  Real(dp) :: rho, t9, tstep, total_molar_abundance
  Real(dp), Allocatable :: x_initial(:), x_result(:)
  Type(eos_t) :: eos_state
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
  Read(lun_candidate,*,iostat=ierr) step_checks_enabled,config%fraction_change_limit, &
    & config%energy_change_fraction_limit,energy_rate_scale,tstep,t9,rho
  Call require(ierr == 0,'failed to read candidate step-check metadata')
  Call require(step_checks_enabled == 0 .or. step_checks_enabled == 1, &
    & 'invalid step-check selection')
  Allocate(x_initial(ny),x_result(ny))
  Read(lun_candidate,*,iostat=ierr) x_initial
  Call require(ierr == 0,'failed to read initial composition')
  Read(lun_candidate,*,iostat=ierr) x_result
  Call require(ierr == 0,'failed to read result composition')
  Close(lun_candidate)

  total_molar_abundance = sum(x_initial/aa)
  electron_fraction = sum(x_initial*zz/aa)
  Call require(total_molar_abundance > 0.0_dp,'invalid initial molar abundance')
  eos_state%rho = rho
  eos_state%T = t9*1.0e9_dp
  eos_state%y_e = electron_fraction
  eos_state%abar = 1.0_dp/total_molar_abundance
  eos_state%zbar = electron_fraction/total_molar_abundance
  Call actual_eos_init()
  Call actual_eos(eos_input_rt,eos_state)
  Call actual_eos_finalize()
  initial_specific_internal_energy = eos_state%e
  energy_rate = energy_rate_scale*avn*epmev*sum((x_result-x_initial)*be/aa)/tstep

  config%check_finite = 1
  config%check_fraction_bounds = 1
  config%check_mass_normalization = 1
  config%check_fixed_ye = 1
  config%check_binding_energy_rate = 1
  config%check_fraction_change = step_checks_enabled
  config%check_energy_change_fraction = step_checks_enabled
  config%energy_absolute_tolerance = 0.0_dp
  config%energy_relative_tolerance = 1.0e-12_dp
  Call bn_check_surrogate_result(config,1,x_initial,x_result,aa,zz,be,tstep,energy_rate, &
    & report,initial_specific_internal_energy=initial_specific_internal_energy)

  Write(*,'(a,1x,a)') 'verification_token',trim(verification_token)
  Write(*,'(a,1x,i0)') 'metadata_identity',1
  Write(*,'(a,1x,i0)') 'overall_status',report%overall_status
  Write(*,'(a,1x,i0)') 'finite_status',report%finite_status
  Write(*,'(a,1x,i0)') 'fraction_bounds_status',report%fraction_bounds_status
  Write(*,'(a,1x,i0)') 'mass_normalization_status',report%mass_normalization_status
  Write(*,'(a,1x,i0)') 'fixed_ye_status',report%fixed_ye_status
  Write(*,'(a,1x,i0)') 'binding_energy_rate_status',report%binding_energy_rate_status
  Write(*,'(a,1x,i0)') 'fraction_change_status',report%fraction_change_status
  Write(*,'(a,1x,i0)') 'energy_change_fraction_status',report%energy_change_fraction_status
  Write(*,'(a,1x,es24.16)') 'mass_residual',report%mass_residual
  Write(*,'(a,1x,es24.16)') 'ye_residual',report%ye_residual
  Write(*,'(a,1x,es24.16)') 'maximum_fraction_change',report%maximum_fraction_change
  Write(*,'(a,1x,i0)') 'maximum_fraction_change_index',report%maximum_fraction_change_index
  Write(*,'(a,1x,es24.16)') 'energy_change_fraction',report%energy_change_fraction
  Write(*,'(a,1x,es24.16)') 'initial_specific_internal_energy', &
    & initial_specific_internal_energy
  Write(*,'(a,1x,es24.16)') 'energy_rate',energy_rate
  Write(*,'(a,1x,es24.16)') 'expected_energy_rate',report%expected_energy_rate

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
