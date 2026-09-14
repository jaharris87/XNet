Module xnet_surrogate_checks
  !-----------------------------------------------------------------------------------------------
  ! This module inspects a candidate burn-surrogate result without changing it. Callers select
  ! checks and tolerances, then decide whether a failed result should be rejected or retried with
  ! the reaction network. Passing these checks establishes admissibility and internal consistency,
  ! not agreement with XNet or scientific accuracy.
  !-----------------------------------------------------------------------------------------------
  Use xnet_constants, Only: avn, epmev
  Use xnet_types, Only: dp, i8
  Implicit None
  Private

  ! A skipped check was disabled or not applicable. A failed check rejected candidate data. An
  ! invalid check had unusable configuration or metadata and therefore could not assess the data.
  Integer, Parameter, Public :: bn_check_skipped = 0
  Integer, Parameter, Public :: bn_check_passed  = 1
  Integer, Parameter, Public :: bn_check_failed  = 2
  Integer, Parameter, Public :: bn_check_invalid = 3

  Type, Public :: bn_surrogate_check_config
    Integer :: check_finite = 0
    Integer :: check_fraction_bounds = 0
    Integer :: check_mass_normalization = 0
    Integer :: check_fixed_ye = 0
    Integer :: check_inactive_identity = 0
    Integer :: check_binding_energy_rate = 0
    Integer :: check_eos_result = 0
    Real(dp) :: fraction_tolerance = 0.0_dp
    Real(dp) :: mass_tolerance = 0.0_dp
    Real(dp) :: ye_tolerance = 0.0_dp
    Real(dp) :: inactive_fraction_tolerance = 0.0_dp
    Real(dp) :: inactive_energy_tolerance = 0.0_dp
    Real(dp) :: energy_absolute_tolerance = 0.0_dp
    Real(dp) :: energy_relative_tolerance = 0.0_dp
  End Type bn_surrogate_check_config

  Type, Public :: bn_surrogate_check_report
    Integer :: overall_status = bn_check_skipped
    Integer :: finite_status = bn_check_skipped
    Integer :: fraction_bounds_status = bn_check_skipped
    Integer :: mass_normalization_status = bn_check_skipped
    Integer :: fixed_ye_status = bn_check_skipped
    Integer :: inactive_identity_status = bn_check_skipped
    Integer :: binding_energy_rate_status = bn_check_skipped
    Integer :: eos_result_status = bn_check_skipped
    Integer :: finite_bad_index = 0
    Integer :: eos_bad_finite_index = 0
    Integer :: eos_bad_positive_index = 0
    Real(dp) :: minimum_fraction = 0.0_dp
    Real(dp) :: maximum_fraction = 0.0_dp
    Real(dp) :: mass_residual = 0.0_dp
    Real(dp) :: initial_ye = 0.0_dp
    Real(dp) :: result_ye = 0.0_dp
    Real(dp) :: ye_residual = 0.0_dp
    Real(dp) :: inactive_fraction_residual = 0.0_dp
    Real(dp) :: inactive_energy_residual = 0.0_dp
    Real(dp) :: expected_energy_rate = 0.0_dp
    Real(dp) :: energy_rate_residual = 0.0_dp
  End Type bn_surrogate_check_report

  Public :: bn_check_binding_energy_rate
  Public :: bn_check_electron_fraction
  Public :: bn_check_eos_result
  Public :: bn_check_finite_values
  Public :: bn_check_fraction_bounds
  Public :: bn_check_inactive_identity
  Public :: bn_check_mass_normalization
  Public :: bn_check_surrogate_result

Contains

  Subroutine bn_check_surrogate_result(config,active,x_initial,x_result,aa,zz,binding_energy, &
    & tstep,energy_rate,report,eos_finite_values,eos_positive_values)
    !---------------------------------------------------------------------------------------------
    ! Coordinate independently selectable checks for one candidate burn result. All candidate
    ! arguments are read-only. Active must be zero or one when the inactive-identity check is
    ! enabled. Energy_rate is in erg g^-1 s^-1, tstep is in seconds, and binding energies are in
    ! MeV per nucleus. EOS arrays are required only when the EOS-result check is enabled.
    !---------------------------------------------------------------------------------------------
    Implicit None

    ! Input variables
    Type(bn_surrogate_check_config), Intent(in) :: config
    Integer, Intent(in) :: active
    Real(dp), Intent(in) :: x_initial(:), x_result(:), aa(:), zz(:), binding_energy(:)
    Real(dp), Intent(in) :: tstep, energy_rate

    ! Output variables
    Type(bn_surrogate_check_report), Intent(out) :: report

    ! Optional variables
    Real(dp), Optional, Intent(in) :: eos_finite_values(:), eos_positive_values(:)

    Call reset_report(report)

    If ( valid_flag(config%check_finite) ) Then
      If ( config%check_finite == 1 ) Then
        Call bn_check_finite_values(x_result,report%finite_status,report%finite_bad_index)
      EndIf
    Else
      report%finite_status = bn_check_invalid
    EndIf

    If ( valid_flag(config%check_fraction_bounds) ) Then
      If ( config%check_fraction_bounds == 1 ) Then
        Call bn_check_fraction_bounds(x_result,config%fraction_tolerance, &
          & report%fraction_bounds_status,report%minimum_fraction,report%maximum_fraction)
      EndIf
    Else
      report%fraction_bounds_status = bn_check_invalid
    EndIf

    If ( valid_flag(config%check_mass_normalization) ) Then
      If ( config%check_mass_normalization == 1 ) Then
        Call bn_check_mass_normalization(x_result,config%mass_tolerance, &
          & report%mass_normalization_status,report%mass_residual)
      EndIf
    Else
      report%mass_normalization_status = bn_check_invalid
    EndIf

    If ( valid_flag(config%check_fixed_ye) ) Then
      If ( config%check_fixed_ye == 1 ) Then
        Call bn_check_electron_fraction(x_initial,x_result,aa,zz,config%ye_tolerance, &
          & report%fixed_ye_status,report%initial_ye,report%result_ye,report%ye_residual)
      EndIf
    Else
      report%fixed_ye_status = bn_check_invalid
    EndIf

    If ( valid_flag(config%check_inactive_identity) ) Then
      If ( config%check_inactive_identity == 1 ) Then
        If ( active == 0 ) Then
          Call bn_check_inactive_identity(x_initial,x_result,energy_rate, &
            & config%inactive_fraction_tolerance,config%inactive_energy_tolerance, &
            & report%inactive_identity_status,report%inactive_fraction_residual, &
            & report%inactive_energy_residual)
        ElseIf ( active /= 1 ) Then
          report%inactive_identity_status = bn_check_invalid
        EndIf
      EndIf
    Else
      report%inactive_identity_status = bn_check_invalid
    EndIf

    If ( valid_flag(config%check_binding_energy_rate) ) Then
      If ( config%check_binding_energy_rate == 1 ) Then
        Call bn_check_binding_energy_rate(x_initial,x_result,aa,binding_energy,tstep, &
          & energy_rate,config%energy_absolute_tolerance,config%energy_relative_tolerance, &
          & report%binding_energy_rate_status,report%expected_energy_rate, &
          & report%energy_rate_residual)
      EndIf
    Else
      report%binding_energy_rate_status = bn_check_invalid
    EndIf

    If ( valid_flag(config%check_eos_result) ) Then
      If ( config%check_eos_result == 1 ) Then
        If ( present(eos_finite_values) .and. present(eos_positive_values) ) Then
          Call bn_check_eos_result(eos_finite_values,eos_positive_values, &
            & report%eos_result_status,report%eos_bad_finite_index, &
            & report%eos_bad_positive_index)
        Else
          report%eos_result_status = bn_check_invalid
        EndIf
      EndIf
    Else
      report%eos_result_status = bn_check_invalid
    EndIf

    Call update_overall_status(report)

    Return
  End Subroutine bn_check_surrogate_result

  Subroutine bn_check_finite_values(values,status,bad_index)
    Implicit None
    Real(dp), Intent(in) :: values(:)
    Integer, Intent(out) :: status, bad_index

    Integer :: i
    status = bn_check_invalid
    bad_index = 0
    If ( size(values) < 1 ) Return

    status = bn_check_passed
    Do i = 1, size(values)
      If ( .not. finite_value(values(i)) ) Then
        status = bn_check_failed
        bad_index = i
        Exit
      EndIf
    EndDo

    Return
  End Subroutine bn_check_finite_values

  Subroutine bn_check_fraction_bounds(xmass,tolerance,status,minimum_fraction,maximum_fraction)
    Implicit None
    Real(dp), Intent(in) :: xmass(:), tolerance
    Integer, Intent(out) :: status
    Real(dp), Intent(out) :: minimum_fraction, maximum_fraction

    Integer :: bad_index, finite_status

    status = bn_check_invalid
    minimum_fraction = 0.0_dp
    maximum_fraction = 0.0_dp
    If ( size(xmass) < 1 ) Return
    If ( .not. finite_value(tolerance) ) Return
    If ( tolerance < 0.0_dp ) Return

    Call bn_check_finite_values(xmass,finite_status,bad_index)
    If ( finite_status /= bn_check_passed ) Then
      status = bn_check_failed
      Return
    EndIf

    minimum_fraction = minval(xmass)
    maximum_fraction = maxval(xmass)
    If ( minimum_fraction >= -tolerance .and. maximum_fraction <= 1.0_dp+tolerance ) Then
      status = bn_check_passed
    Else
      status = bn_check_failed
    EndIf

    Return
  End Subroutine bn_check_fraction_bounds

  Subroutine bn_check_mass_normalization(xmass,tolerance,status,residual)
    Implicit None
    Real(dp), Intent(in) :: xmass(:), tolerance
    Integer, Intent(out) :: status
    Real(dp), Intent(out) :: residual

    Integer :: bad_index, finite_status

    status = bn_check_invalid
    residual = 0.0_dp
    If ( size(xmass) < 1 ) Return
    If ( .not. finite_value(tolerance) ) Return
    If ( tolerance < 0.0_dp ) Return

    Call bn_check_finite_values(xmass,finite_status,bad_index)
    If ( finite_status /= bn_check_passed ) Then
      status = bn_check_failed
      residual = huge(residual)
      Return
    EndIf

    residual = sum(xmass) - 1.0_dp
    If ( .not. finite_value(residual) ) Then
      status = bn_check_failed
      residual = huge(residual)
      Return
    EndIf
    If ( abs(residual) <= tolerance ) Then
      status = bn_check_passed
    Else
      status = bn_check_failed
    EndIf

    Return
  End Subroutine bn_check_mass_normalization

  Subroutine bn_check_electron_fraction(x_initial,x_result,aa,zz,tolerance,status, &
    & initial_ye,result_ye,residual)
    Implicit None
    Real(dp), Intent(in) :: x_initial(:), x_result(:), aa(:), zz(:), tolerance
    Integer, Intent(out) :: status
    Real(dp), Intent(out) :: initial_ye, result_ye, residual
    Integer :: bad_index, finite_status

    status = bn_check_invalid
    initial_ye = 0.0_dp
    result_ye = 0.0_dp
    residual = 0.0_dp
    If ( size(x_initial) < 1 .or. size(x_result) /= size(x_initial) .or. &
      & size(aa) /= size(x_initial) .or. size(zz) /= size(x_initial) ) Return
    If ( .not. finite_value(tolerance) ) Return
    If ( tolerance < 0.0_dp ) Return

    Call bn_check_finite_values(aa,finite_status,bad_index)
    If ( finite_status /= bn_check_passed ) Return
    Call bn_check_finite_values(zz,finite_status,bad_index)
    If ( finite_status /= bn_check_passed ) Return
    If ( any(aa <= 0.0_dp) ) Return
    Call bn_check_finite_values(x_initial,finite_status,bad_index)
    If ( finite_status /= bn_check_passed ) Then
      status = bn_check_failed
      residual = huge(residual)
      Return
    EndIf
    Call bn_check_finite_values(x_result,finite_status,bad_index)
    If ( finite_status /= bn_check_passed ) Then
      status = bn_check_failed
      residual = huge(residual)
      Return
    EndIf
    initial_ye = sum(zz*x_initial/aa)
    result_ye = sum(zz*x_result/aa)
    residual = result_ye - initial_ye
    If ( .not. finite_value(initial_ye) .or. .not. finite_value(result_ye) .or. &
      & .not. finite_value(residual) ) Then
      status = bn_check_failed
      initial_ye = 0.0_dp
      result_ye = 0.0_dp
      residual = huge(residual)
      Return
    EndIf
    If ( abs(residual) <= tolerance ) Then
      status = bn_check_passed
    Else
      status = bn_check_failed
    EndIf

    Return
  End Subroutine bn_check_electron_fraction

  Subroutine bn_check_inactive_identity(x_initial,x_result,energy_rate,fraction_tolerance, &
    & energy_tolerance,status,fraction_residual,energy_residual)
    Implicit None
    Real(dp), Intent(in) :: x_initial(:), x_result(:), energy_rate
    Real(dp), Intent(in) :: fraction_tolerance, energy_tolerance
    Integer, Intent(out) :: status
    Real(dp), Intent(out) :: fraction_residual, energy_residual
    Integer :: bad_index, finite_status

    status = bn_check_invalid
    fraction_residual = 0.0_dp
    energy_residual = 0.0_dp
    If ( size(x_initial) < 1 .or. size(x_result) /= size(x_initial) ) Return
    If ( .not. finite_value(fraction_tolerance) ) Return
    If ( fraction_tolerance < 0.0_dp ) Return
    If ( .not. finite_value(energy_tolerance) ) Return
    If ( energy_tolerance < 0.0_dp ) Return

    Call bn_check_finite_values(x_initial,finite_status,bad_index)
    If ( finite_status /= bn_check_passed ) Then
      status = bn_check_failed
      fraction_residual = huge(fraction_residual)
      Return
    EndIf
    Call bn_check_finite_values(x_result,finite_status,bad_index)
    If ( finite_status /= bn_check_passed .or. .not. finite_value(energy_rate) ) Then
      status = bn_check_failed
      fraction_residual = huge(fraction_residual)
      energy_residual = huge(energy_residual)
      Return
    EndIf

    fraction_residual = maxval(abs(x_result-x_initial))
    energy_residual = abs(energy_rate)
    If ( .not. finite_value(fraction_residual) .or. .not. finite_value(energy_residual) ) Then
      status = bn_check_failed
      fraction_residual = huge(fraction_residual)
      energy_residual = huge(energy_residual)
      Return
    EndIf
    If ( fraction_residual <= fraction_tolerance .and. energy_residual <= energy_tolerance ) Then
      status = bn_check_passed
    Else
      status = bn_check_failed
    EndIf

    Return
  End Subroutine bn_check_inactive_identity

  Subroutine bn_check_binding_energy_rate(x_initial,x_result,aa,binding_energy,tstep, &
    & energy_rate,absolute_tolerance,relative_tolerance,status,expected_rate,residual)
    !---------------------------------------------------------------------------------------------
    ! Check the XNet/Flash-X binding-energy convention
    !   edot = N_A (MeV to erg) sum_i[(X_i'-X_i) B_i/A_i] / dt.
    ! This is a complete source consistency check only when weak-interaction and neutrino-energy
    ! terms are excluded from the caller's reported energy rate.
    !---------------------------------------------------------------------------------------------
    Implicit None
    Real(dp), Intent(in) :: x_initial(:), x_result(:), aa(:), binding_energy(:)
    Real(dp), Intent(in) :: tstep, energy_rate, absolute_tolerance, relative_tolerance
    Integer, Intent(out) :: status
    Real(dp), Intent(out) :: expected_rate, residual

    Integer :: bad_index, finite_status
    Real(dp) :: allowed_error

    status = bn_check_invalid
    expected_rate = 0.0_dp
    residual = 0.0_dp
    If ( size(x_initial) < 1 .or. size(x_result) /= size(x_initial) .or. &
      & size(aa) /= size(x_initial) .or. size(binding_energy) /= size(x_initial) ) Return
    If ( .not. finite_value(tstep) ) Return
    If ( tstep <= 0.0_dp ) Return
    If ( .not. finite_value(absolute_tolerance) ) Return
    If ( absolute_tolerance < 0.0_dp ) Return
    If ( .not. finite_value(relative_tolerance) ) Return
    If ( relative_tolerance < 0.0_dp ) Return

    Call bn_check_finite_values(aa,finite_status,bad_index)
    If ( finite_status /= bn_check_passed ) Return
    Call bn_check_finite_values(binding_energy,finite_status,bad_index)
    If ( finite_status /= bn_check_passed ) Return
    If ( any(aa <= 0.0_dp) ) Return
    Call bn_check_finite_values(x_initial,finite_status,bad_index)
    If ( finite_status /= bn_check_passed ) Then
      status = bn_check_failed
      residual = huge(residual)
      Return
    EndIf
    Call bn_check_finite_values(x_result,finite_status,bad_index)
    If ( finite_status /= bn_check_passed .or. .not. finite_value(energy_rate) ) Then
      status = bn_check_failed
      residual = huge(residual)
      Return
    EndIf

    expected_rate = avn*epmev*sum((x_result-x_initial)*binding_energy/aa)/tstep
    If ( .not. finite_value(expected_rate) ) Then
      status = bn_check_failed
      residual = huge(residual)
      Return
    EndIf
    residual = energy_rate - expected_rate
    If ( .not. finite_value(residual) ) Then
      status = bn_check_failed
      residual = huge(residual)
      Return
    EndIf

    allowed_error = absolute_tolerance + &
      & relative_tolerance*max(abs(expected_rate),abs(energy_rate))
    If ( .not. finite_value(allowed_error) ) Then
      status = bn_check_invalid
      Return
    EndIf
    If ( abs(residual) <= allowed_error ) Then
      status = bn_check_passed
    Else
      status = bn_check_failed
    EndIf

    Return
  End Subroutine bn_check_binding_energy_rate

  Subroutine bn_check_eos_result(finite_values,positive_values,status,bad_finite_index, &
    & bad_positive_index)
    !---------------------------------------------------------------------------------------------
    ! Check caller-selected post-burn EOS outputs without depending on a particular EOS interface.
    ! Values in finite_values need only be finite; values in positive_values must be finite and
    ! strictly greater than zero. The caller defines the order represented by the reported index.
    !---------------------------------------------------------------------------------------------
    Implicit None
    Real(dp), Intent(in) :: finite_values(:), positive_values(:)
    Integer, Intent(out) :: status, bad_finite_index, bad_positive_index

    Integer :: i

    status = bn_check_invalid
    bad_finite_index = 0
    bad_positive_index = 0
    If ( size(finite_values)+size(positive_values) < 1 ) Return

    status = bn_check_passed
    Do i = 1, size(finite_values)
      If ( .not. finite_value(finite_values(i)) ) Then
        status = bn_check_failed
        bad_finite_index = i
        Return
      EndIf
    EndDo
    Do i = 1, size(positive_values)
      If ( .not. finite_value(positive_values(i)) ) Then
        status = bn_check_failed
        bad_positive_index = i
        Return
      EndIf
      If ( positive_values(i) <= 0.0_dp ) Then
        status = bn_check_failed
        bad_positive_index = i
        Return
      EndIf
    EndDo

    Return
  End Subroutine bn_check_eos_result

  Subroutine reset_report(report)
    Implicit None
    Type(bn_surrogate_check_report), Intent(out) :: report

    report%overall_status = bn_check_skipped
    report%finite_status = bn_check_skipped
    report%fraction_bounds_status = bn_check_skipped
    report%mass_normalization_status = bn_check_skipped
    report%fixed_ye_status = bn_check_skipped
    report%inactive_identity_status = bn_check_skipped
    report%binding_energy_rate_status = bn_check_skipped
    report%eos_result_status = bn_check_skipped
    report%finite_bad_index = 0
    report%eos_bad_finite_index = 0
    report%eos_bad_positive_index = 0
    report%minimum_fraction = 0.0_dp
    report%maximum_fraction = 0.0_dp
    report%mass_residual = 0.0_dp
    report%initial_ye = 0.0_dp
    report%result_ye = 0.0_dp
    report%ye_residual = 0.0_dp
    report%inactive_fraction_residual = 0.0_dp
    report%inactive_energy_residual = 0.0_dp
    report%expected_energy_rate = 0.0_dp
    report%energy_rate_residual = 0.0_dp

    Return
  End Subroutine reset_report

  Subroutine update_overall_status(report)
    Implicit None
    Type(bn_surrogate_check_report), Intent(inout) :: report

    Integer :: statuses(7)

    statuses = (/ report%finite_status, report%fraction_bounds_status, &
      & report%mass_normalization_status, report%fixed_ye_status, &
      & report%inactive_identity_status, report%binding_energy_rate_status, &
      & report%eos_result_status /)
    If ( any(statuses == bn_check_invalid) ) Then
      report%overall_status = bn_check_invalid
    ElseIf ( any(statuses == bn_check_failed) ) Then
      report%overall_status = bn_check_failed
    ElseIf ( any(statuses == bn_check_passed) ) Then
      report%overall_status = bn_check_passed
    Else
      report%overall_status = bn_check_skipped
    EndIf

    Return
  End Subroutine update_overall_status

  Logical Function valid_flag(flag)
    Implicit None
    Integer, Intent(in) :: flag

    valid_flag = flag == 0 .or. flag == 1

    Return
  End Function valid_flag

  Logical Function finite_value(value)
    !---------------------------------------------------------------------------------------------
    ! Inspect the IEEE binary64 exponent bits directly. The tracked optimized build enables finite
    ! math assumptions under which comparison-based IEEE inquiry functions can accept NaNs.
    ! xnet_types fixes dp to real64, and XNet's supported numerical targets use IEEE binary64.
    !---------------------------------------------------------------------------------------------
    Implicit None
    Real(dp), Intent(in) :: value

    Integer(i8), Parameter :: exponent_mask = int(z'7ff0000000000000',i8)
    Integer(i8) :: bits

    bits = transfer(value,bits)
    finite_value = iand(bits,exponent_mask) /= exponent_mask

    Return
  End Function finite_value

End Module xnet_surrogate_checks
