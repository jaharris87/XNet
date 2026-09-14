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
    ! Flags must be zero (disabled) or one (enabled); any other value is invalid. Tolerances and
    ! limits use -1 as an unset sentinel so enabling a threshold-bearing check requires explicit
    ! caller policy. Explicit zero is valid and requests an inclusive exact comparison.
    Integer :: check_finite = 0
    Integer :: check_fraction_bounds = 0
    Integer :: check_mass_normalization = 0
    Integer :: check_fixed_ye = 0
    Integer :: check_inactive_identity = 0
    Integer :: check_binding_energy_rate = 0
    Integer :: check_eos_result = 0
    ! Absolute dimensionless slack in -tol <= X_i <= 1+tol.
    Real(dp) :: fraction_tolerance = -1.0_dp
    ! Absolute dimensionless limit on |sum_i X_i - 1|.
    Real(dp) :: mass_tolerance = -1.0_dp
    ! Absolute dimensionless limit on |Ye_result-Ye_initial|.
    Real(dp) :: ye_tolerance = -1.0_dp
    ! Absolute dimensionless limit on max_i |X_result_i-X_initial_i| when inactive.
    Real(dp) :: inactive_fraction_tolerance = -1.0_dp
    ! Absolute limit in erg g^-1 s^-1 on |energy_rate| when inactive.
    Real(dp) :: inactive_energy_tolerance = -1.0_dp
    ! Absolute term in erg g^-1 s^-1 in the binding-energy-rate comparison.
    Real(dp) :: energy_absolute_tolerance = -1.0_dp
    ! Dimensionless relative term scaled by max(|expected_rate|,|energy_rate|).
    Real(dp) :: energy_relative_tolerance = -1.0_dp
    ! New components are appended to preserve legacy positional structure constructors.
    Integer :: check_fraction_change = 0
    Integer :: check_energy_change_fraction = 0
    ! Absolute dimensionless limit on max_i |X_result_i-X_initial_i| for an active burn step.
    Real(dp) :: fraction_change_limit = -1.0_dp
    ! Dimensionless limit on |energy_rate*tstep|/initial_specific_internal_energy.
    Real(dp) :: energy_change_fraction_limit = -1.0_dp
  End Type bn_surrogate_check_config

  Type, Public :: bn_surrogate_check_report
    ! Overall is INVALID before FAILED before PASSED before SKIPPED; individual status fields use
    ! the public bn_check_* values. Bad-value indices are one-based first failures, or zero when
    ! none; EOS indices refer to the caller-defined ordering of the corresponding EOS array. The
    ! maximum-change index is the first maximum and can therefore be nonzero on PASSED results.
    !
    ! A check's numerical diagnostics have their stated mathematical meaning only when safely
    ! representable. SKIPPED leaves them at zero. INVALID may leave zero or the last safely computed
    ! partial value; callers must not interpret either. On FAILED candidate arithmetic that is
    ! non-finite or cannot be represented, the applicable residual is huge() as an explicit
    ! "unrepresentable" sentinel; related derived values remain zero or the last safely computed
    ! partial value. Ordinary finite FAILED and PASSED paths return the mathematical diagnostics
    ! described below. Status, rather than a diagnostic sentinel, controls acceptance/fallback.
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
    Real(dp) :: minimum_fraction = 0.0_dp ! safely represented min_i X_result_i; dimensionless
    Real(dp) :: maximum_fraction = 0.0_dp ! safely represented max_i X_result_i; dimensionless
    Real(dp) :: mass_residual = 0.0_dp ! safe signed sum_i X_result_i - 1; dimensionless
    Real(dp) :: initial_ye = 0.0_dp ! safe sum_i Z_i X_initial_i/A_i; dimensionless
    Real(dp) :: result_ye = 0.0_dp ! safe sum_i Z_i X_result_i/A_i; dimensionless
    Real(dp) :: ye_residual = 0.0_dp ! safe signed Ye_result-Ye_initial; dimensionless
    Real(dp) :: inactive_fraction_residual = 0.0_dp ! safe max component change; dimensionless
    Real(dp) :: inactive_energy_residual = 0.0_dp ! safely represented |rate|; erg g^-1 s^-1
    Real(dp) :: expected_energy_rate = 0.0_dp ! safe binding-only rate; erg g^-1 s^-1
    Real(dp) :: energy_rate_residual = 0.0_dp ! safe signed reported-expected; erg g^-1 s^-1
    ! New components are appended to preserve legacy positional structure constructors.
    Integer :: fraction_change_status = bn_check_skipped
    Integer :: energy_change_fraction_status = bn_check_skipped
    Integer :: maximum_fraction_change_index = 0
    Real(dp) :: maximum_fraction_change = 0.0_dp ! safe max_i |X_result_i-X_initial_i|
    Real(dp) :: energy_change_fraction = 0.0_dp ! safe |energy_rate*tstep|/initial energy
  End Type bn_surrogate_check_report

  Public :: bn_check_binding_energy_rate
  Public :: bn_check_electron_fraction
  Public :: bn_check_energy_change_fraction
  Public :: bn_check_eos_result
  Public :: bn_check_finite_values
  Public :: bn_check_fraction_bounds
  Public :: bn_check_fraction_change
  Public :: bn_check_inactive_identity
  Public :: bn_check_mass_normalization
  Public :: bn_check_surrogate_result

Contains

  Subroutine bn_check_surrogate_result(config,active,x_initial,x_result,aa,zz,binding_energy, &
    & tstep,energy_rate,report,eos_finite_values,eos_positive_values, &
    & initial_specific_internal_energy)
    !---------------------------------------------------------------------------------------------
    ! Coordinate independently selectable checks for one candidate burn result. All candidate
    ! arguments are read-only. Active must be zero or one when the inactive-identity check is
    ! enabled. Energy_rate is in erg g^-1 s^-1, tstep is in seconds, and binding energies are in
    ! MeV per nucleus. EOS arrays are required only when the EOS-result check is enabled. The
    ! initial specific internal energy is in erg g^-1 and is required only when the energy-change
    ! fraction check is enabled.
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
    Real(dp), Optional, Intent(in) :: initial_specific_internal_energy

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

    If ( valid_flag(config%check_fraction_change) ) Then
      If ( config%check_fraction_change == 1 ) Then
        Call bn_check_fraction_change(x_initial,x_result,config%fraction_change_limit, &
          & report%fraction_change_status,report%maximum_fraction_change, &
          & report%maximum_fraction_change_index)
      EndIf
    Else
      report%fraction_change_status = bn_check_invalid
    EndIf

    If ( valid_flag(config%check_energy_change_fraction) ) Then
      If ( config%check_energy_change_fraction == 1 ) Then
        If ( present(initial_specific_internal_energy) ) Then
          Call bn_check_energy_change_fraction(energy_rate,tstep, &
            & initial_specific_internal_energy,config%energy_change_fraction_limit, &
            & report%energy_change_fraction_status,report%energy_change_fraction)
        Else
          report%energy_change_fraction_status = bn_check_invalid
        EndIf
      EndIf
    Else
      report%energy_change_fraction_status = bn_check_invalid
    EndIf

    Call update_overall_status(report)

    Return
  End Subroutine bn_check_surrogate_result

  Subroutine bn_check_finite_values(values,status,bad_index)
    !---------------------------------------------------------------------------------------------
    ! Require a nonempty candidate array containing only finite IEEE binary64 values. This proves
    ! numerical representability only, not physical bounds, normalization, or accuracy. A
    ! non-finite candidate is FAILED; an empty array is INVALID.
    !---------------------------------------------------------------------------------------------
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
    !---------------------------------------------------------------------------------------------
    ! Require each candidate mass fraction to satisfy -tolerance <= X_i <= 1+tolerance, inclusively.
    ! The tolerance and fractions are dimensionless. This componentwise gate does not establish
    ! normalization, conservation of charge, network agreement, or physical trajectory accuracy.
    !---------------------------------------------------------------------------------------------
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
    If ( fraction_within_lower_bound(minimum_fraction,tolerance) .and. &
      & fraction_within_upper_bound(maximum_fraction,tolerance) ) Then
      status = bn_check_passed
    Else
      status = bn_check_failed
    EndIf

    Return
  End Subroutine bn_check_fraction_bounds

  Subroutine bn_check_mass_normalization(xmass,tolerance,status,residual)
    !---------------------------------------------------------------------------------------------
    ! Require |sum_i X_i-1| <= tolerance, inclusively. Residual is the signed dimensionless
    ! quantity sum_i X_i-1. This scalar identity does not establish component bounds, species-wise
    ! conservation, network agreement, or physical trajectory accuracy.
    !---------------------------------------------------------------------------------------------
    Implicit None
    Real(dp), Intent(in) :: xmass(:), tolerance
    Integer, Intent(out) :: status
    Real(dp), Intent(out) :: residual

    Integer :: bad_index, finite_status
    Real(dp) :: mass_sum

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

    If ( .not. safe_sum(xmass,mass_sum) ) Then
      status = bn_check_failed
      residual = huge(residual)
      Return
    EndIf
    If ( .not. safe_subtract(mass_sum,1.0_dp,residual) ) Then
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
    !---------------------------------------------------------------------------------------------
    ! Require |sum_i Z_i X_result_i/A_i - sum_i Z_i X_initial_i/A_i| <= tolerance, inclusively.
    ! Values and tolerance are dimensionless. A and Z must be finite with A>0 and 0<=Z<=A;
    ! integer-valued XNet nuclear metadata is otherwise a trusted caller precondition. Non-finite
    ! initial/reference data are INVALID; non-finite or overflowing candidate evaluation is FAILED.
    ! Fixed Ye does not establish mass normalization, energy closure, or agreement with XNet.
    !---------------------------------------------------------------------------------------------
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
    If ( any(zz < 0.0_dp) .or. any(zz > aa) ) Return
    Call bn_check_finite_values(x_initial,finite_status,bad_index)
    If ( finite_status /= bn_check_passed ) Return
    Call bn_check_finite_values(x_result,finite_status,bad_index)
    If ( finite_status /= bn_check_passed ) Then
      status = bn_check_failed
      residual = huge(residual)
      Return
    EndIf
    If ( .not. safe_electron_fraction(x_initial,aa,zz,initial_ye) ) Return
    If ( .not. safe_electron_fraction(x_result,aa,zz,result_ye) ) Then
      status = bn_check_failed
      result_ye = 0.0_dp
      residual = huge(residual)
      Return
    EndIf
    If ( .not. safe_subtract(result_ye,initial_ye,residual) ) Then
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
  End Subroutine bn_check_electron_fraction

  Subroutine bn_check_inactive_identity(x_initial,x_result,energy_rate,fraction_tolerance, &
    & energy_tolerance,status,fraction_residual,energy_residual)
    !---------------------------------------------------------------------------------------------
    ! For a caller-declared inactive zone, require max_i |X_result_i-X_initial_i| <= the absolute
    ! dimensionless fraction tolerance and |energy_rate| <= the absolute energy tolerance in
    ! erg g^-1 s^-1, inclusively. This detects changes where no burn was requested; it does not
    ! decide whether a zone should be active or validate EOS, network, or trajectory accuracy.
    ! Non-finite initial/reference data are INVALID; corrupt candidate data are FAILED.
    !---------------------------------------------------------------------------------------------
    Implicit None
    Real(dp), Intent(in) :: x_initial(:), x_result(:), energy_rate
    Real(dp), Intent(in) :: fraction_tolerance, energy_tolerance
    Integer, Intent(out) :: status
    Real(dp), Intent(out) :: fraction_residual, energy_residual
    Integer :: bad_index, finite_status, i
    Real(dp) :: component_residual

    status = bn_check_invalid
    fraction_residual = 0.0_dp
    energy_residual = 0.0_dp
    If ( size(x_initial) < 1 .or. size(x_result) /= size(x_initial) ) Return
    If ( .not. finite_value(fraction_tolerance) ) Return
    If ( fraction_tolerance < 0.0_dp ) Return
    If ( .not. finite_value(energy_tolerance) ) Return
    If ( energy_tolerance < 0.0_dp ) Return

    Call bn_check_finite_values(x_initial,finite_status,bad_index)
    If ( finite_status /= bn_check_passed ) Return
    Call bn_check_finite_values(x_result,finite_status,bad_index)
    If ( finite_status /= bn_check_passed .or. .not. finite_value(energy_rate) ) Then
      status = bn_check_failed
      fraction_residual = huge(fraction_residual)
      energy_residual = huge(energy_residual)
      Return
    EndIf

    Do i = 1, size(x_result)
      If ( .not. safe_subtract(x_result(i),x_initial(i),component_residual) ) Then
        status = bn_check_failed
        fraction_residual = huge(fraction_residual)
        energy_residual = abs(energy_rate)
        Return
      EndIf
      fraction_residual = max(fraction_residual,abs(component_residual))
    EndDo
    energy_residual = abs(energy_rate)
    If ( fraction_residual <= fraction_tolerance .and. energy_residual <= energy_tolerance ) Then
      status = bn_check_passed
    Else
      status = bn_check_failed
    EndIf

    Return
  End Subroutine bn_check_inactive_identity

  Subroutine bn_check_fraction_change(x_initial,x_result,change_limit,status,maximum_change, &
    & maximum_change_index)
    !---------------------------------------------------------------------------------------------
    ! Require max_i |X_result_i-X_initial_i| <= change_limit, inclusively. The limit and result are
    ! absolute dimensionless mass-fraction changes, not changes relative to each initial X_i. This
    ! inexpensive endpoint gate can flag excessive progress during one externally selected split
    ! burn step; it does not establish surrogate accuracy or select a multiphysics timestep.
    ! Non-finite initial/reference data are INVALID; corrupt or unrepresentable candidate changes
    ! are FAILED. The reported index is the first maximum, or the first bad candidate component.
    !---------------------------------------------------------------------------------------------
    Implicit None
    Real(dp), Intent(in) :: x_initial(:), x_result(:), change_limit
    Integer, Intent(out) :: status, maximum_change_index
    Real(dp), Intent(out) :: maximum_change

    Integer :: bad_index, finite_status, i
    Real(dp) :: component_change, delta_fraction

    status = bn_check_invalid
    maximum_change = 0.0_dp
    maximum_change_index = 0
    If ( size(x_initial) < 1 .or. size(x_result) /= size(x_initial) ) Return
    If ( .not. finite_value(change_limit) ) Return
    If ( change_limit < 0.0_dp ) Return

    Call bn_check_finite_values(x_initial,finite_status,bad_index)
    If ( finite_status /= bn_check_passed ) Return
    Call bn_check_finite_values(x_result,finite_status,bad_index)
    If ( finite_status /= bn_check_passed ) Then
      status = bn_check_failed
      maximum_change = huge(maximum_change)
      maximum_change_index = bad_index
      Return
    EndIf

    Do i = 1, size(x_result)
      If ( .not. safe_subtract(x_result(i),x_initial(i),delta_fraction) ) Then
        status = bn_check_failed
        maximum_change = huge(maximum_change)
        maximum_change_index = i
        Return
      EndIf
      component_change = abs(delta_fraction)
      If ( i == 1 .or. component_change > maximum_change ) Then
        maximum_change = component_change
        maximum_change_index = i
      EndIf
    EndDo
    If ( maximum_change <= change_limit ) Then
      status = bn_check_passed
    Else
      status = bn_check_failed
    EndIf

    Return
  End Subroutine bn_check_fraction_change

  Subroutine bn_check_energy_change_fraction(energy_rate,tstep, &
    & initial_specific_internal_energy,change_limit,status,change_fraction)
    !---------------------------------------------------------------------------------------------
    ! Require |energy_rate*tstep|/initial_specific_internal_energy <= change_limit, inclusively.
    ! Energy_rate is in erg g^-1 s^-1, tstep is one externally selected split-step duration in
    ! seconds, and the positive initial specific internal energy is in erg g^-1. The result and
    ! limit are dimensionless. This endpoint gate uses no additional surrogate or network call and
    ! does not establish accuracy; a failure can indicate that the coupled timestep needs review.
    ! Invalid timestep, initial energy, or limit is INVALID. A non-finite rate or unrepresentable
    ! candidate calculation is FAILED.
    !---------------------------------------------------------------------------------------------
    Implicit None
    Real(dp), Intent(in) :: energy_rate, tstep, initial_specific_internal_energy, change_limit
    Integer, Intent(out) :: status
    Real(dp), Intent(out) :: change_fraction

    Real(dp) :: energy_change

    status = bn_check_invalid
    change_fraction = 0.0_dp
    If ( .not. finite_value(tstep) ) Return
    If ( tstep <= 0.0_dp ) Return
    If ( .not. finite_value(initial_specific_internal_energy) ) Return
    If ( initial_specific_internal_energy <= 0.0_dp ) Return
    If ( .not. finite_value(change_limit) ) Return
    If ( change_limit < 0.0_dp ) Return
    If ( .not. finite_value(energy_rate) ) Then
      status = bn_check_failed
      change_fraction = huge(change_fraction)
      Return
    EndIf

    If ( .not. safe_multiply(energy_rate,tstep,energy_change) ) Then
      status = bn_check_failed
      change_fraction = huge(change_fraction)
      Return
    EndIf
    If ( energy_rate /= 0.0_dp .and. energy_change == 0.0_dp ) Then
      status = bn_check_failed
      change_fraction = huge(change_fraction)
      Return
    EndIf
    If ( .not. safe_divide(abs(energy_change),initial_specific_internal_energy, &
      & change_fraction) ) Then
      status = bn_check_failed
      change_fraction = huge(change_fraction)
      Return
    EndIf
    If ( energy_change /= 0.0_dp .and. change_fraction == 0.0_dp ) Then
      status = bn_check_failed
      change_fraction = huge(change_fraction)
      Return
    EndIf
    If ( change_fraction <= change_limit ) Then
      status = bn_check_passed
    Else
      status = bn_check_failed
    EndIf

    Return
  End Subroutine bn_check_energy_change_fraction

  Subroutine bn_check_binding_energy_rate(x_initial,x_result,aa,binding_energy,tstep, &
    & energy_rate,absolute_tolerance,relative_tolerance,status,expected_rate,residual)
    !---------------------------------------------------------------------------------------------
    ! Check the XNet/Flash-X binding-energy convention
    !   edot = N_A (MeV to erg) sum_i[(X_i'-X_i) B_i/A_i] / dt.
    ! B_i is the positive binding energy per nucleus, so increasing total binding gives positive
    ! edot. This routine validates only that binding-energy component. Total XNet mass-excess
    ! source closure additionally requires fixed Ye to be established separately because proton
    ! and neutron mass excesses contribute when Ye changes; neutrino losses must also be excluded
    ! from energy_rate or checked separately. The inclusive acceptance rule is
    !   |energy_rate-expected_rate| <= absolute_tolerance
    !     + relative_tolerance*max(|expected_rate|,|energy_rate|).
    ! Rates and the absolute tolerance are in erg g^-1 s^-1; the relative tolerance is
    ! dimensionless, dt is in seconds, and A is dimensionless. Passing does not establish fixed Ye,
    ! EOS consistency, or agreement with a network trajectory.
    !---------------------------------------------------------------------------------------------
    Implicit None
    Real(dp), Intent(in) :: x_initial(:), x_result(:), aa(:), binding_energy(:)
    Real(dp), Intent(in) :: tstep, energy_rate, absolute_tolerance, relative_tolerance
    Integer, Intent(out) :: status
    Real(dp), Intent(out) :: expected_rate, residual

    Integer :: bad_index, finite_status, i
    Real(dp) :: binding_sum, component, delta_fraction, energy_scale, next_sum, weight

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
    If ( finite_status /= bn_check_passed ) Return
    Call bn_check_finite_values(x_result,finite_status,bad_index)
    If ( finite_status /= bn_check_passed .or. .not. finite_value(energy_rate) ) Then
      status = bn_check_failed
      residual = huge(residual)
      Return
    EndIf

    If ( .not. safe_multiply(avn,epmev,component) ) Return
    If ( .not. safe_divide(component,tstep,energy_scale) ) Return

    binding_sum = 0.0_dp
    Do i = 1, size(x_result)
      If ( .not. safe_divide(binding_energy(i),aa(i),weight) ) Return
      If ( .not. safe_subtract(x_result(i),x_initial(i),delta_fraction) ) Then
        status = bn_check_failed
        residual = huge(residual)
        Return
      EndIf
      If ( .not. safe_multiply(delta_fraction,weight,component) ) Then
        status = bn_check_failed
        residual = huge(residual)
        Return
      EndIf
      If ( .not. safe_add(binding_sum,component,next_sum) ) Then
        status = bn_check_failed
        residual = huge(residual)
        Return
      EndIf
      binding_sum = next_sum
    EndDo
    If ( .not. safe_multiply(binding_sum,energy_scale,expected_rate) ) Then
      status = bn_check_failed
      residual = huge(residual)
      Return
    EndIf
    If ( .not. safe_subtract(energy_rate,expected_rate,residual) ) Then
      status = bn_check_failed
      residual = huge(residual)
      Return
    EndIf

    If ( within_energy_tolerance(residual,energy_rate,expected_rate,absolute_tolerance, &
      & relative_tolerance) ) Then
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
    report%fraction_change_status = bn_check_skipped
    report%energy_change_fraction_status = bn_check_skipped
    report%finite_bad_index = 0
    report%eos_bad_finite_index = 0
    report%eos_bad_positive_index = 0
    report%maximum_fraction_change_index = 0
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
    report%maximum_fraction_change = 0.0_dp
    report%energy_change_fraction = 0.0_dp

    Return
  End Subroutine reset_report

  Subroutine update_overall_status(report)
    Implicit None
    Type(bn_surrogate_check_report), Intent(inout) :: report

    Integer :: statuses(9)

    statuses = (/ report%finite_status, report%fraction_bounds_status, &
      & report%mass_normalization_status, report%fixed_ye_status, &
      & report%inactive_identity_status, report%binding_energy_rate_status, &
      & report%eos_result_status, report%fraction_change_status, &
      & report%energy_change_fraction_status /)
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

  Logical Function fraction_within_lower_bound(value,tolerance)
    Implicit None
    Real(dp), Intent(in) :: value, tolerance

    If ( value >= 0.0_dp ) Then
      fraction_within_lower_bound = .True.
    Else
      fraction_within_lower_bound = -value <= tolerance
    EndIf

    Return
  End Function fraction_within_lower_bound

  Logical Function fraction_within_upper_bound(value,tolerance)
    Implicit None
    Real(dp), Intent(in) :: value, tolerance

    If ( value <= 1.0_dp ) Then
      fraction_within_upper_bound = .True.
    Else
      fraction_within_upper_bound = value-1.0_dp <= tolerance
    EndIf

    Return
  End Function fraction_within_upper_bound

  Logical Function safe_add(left,right,result)
    ! Return false rather than evaluating a binary64 addition that would overflow.
    Implicit None
    Real(dp), Intent(in) :: left, right
    Real(dp), Intent(out) :: result
    Real(dp) :: largest

    safe_add = .False.
    result = 0.0_dp
    If ( .not. finite_value(left) .or. .not. finite_value(right) ) Return
    largest = huge(result)
    If ( right > 0.0_dp ) Then
      If ( left > largest-right ) Return
    ElseIf ( right < 0.0_dp ) Then
      If ( left < -largest-right ) Return
    EndIf
    result = left+right
    safe_add = finite_value(result)

    Return
  End Function safe_add

  Logical Function safe_subtract(left,right,result)
    ! Return false rather than evaluating a binary64 subtraction that would overflow.
    Implicit None
    Real(dp), Intent(in) :: left, right
    Real(dp), Intent(out) :: result

    safe_subtract = safe_add(left,-right,result)

    Return
  End Function safe_subtract

  Logical Function safe_multiply(left,right,result)
    ! Return false rather than evaluating a binary64 multiplication that would overflow.
    Implicit None
    Real(dp), Intent(in) :: left, right
    Real(dp), Intent(out) :: result

    safe_multiply = .False.
    result = 0.0_dp
    If ( .not. finite_value(left) .or. .not. finite_value(right) ) Return
    If ( left == 0.0_dp .or. right == 0.0_dp ) Then
      safe_multiply = .True.
      Return
    EndIf
    If ( abs(right) > 1.0_dp ) Then
      If ( abs(left) > huge(result)/abs(right) ) Return
    ElseIf ( abs(left) > 1.0_dp ) Then
      If ( abs(right) > huge(result)/abs(left) ) Return
    EndIf
    result = left*right
    safe_multiply = finite_value(result)

    Return
  End Function safe_multiply

  Logical Function safe_divide(numerator,denominator,result)
    ! Return false rather than evaluating division by zero or a binary64 quotient overflow.
    Implicit None
    Real(dp), Intent(in) :: numerator, denominator
    Real(dp), Intent(out) :: result
    Real(dp) :: absolute_denominator

    safe_divide = .False.
    result = 0.0_dp
    If ( .not. finite_value(numerator) .or. .not. finite_value(denominator) ) Return
    If ( denominator == 0.0_dp ) Return
    absolute_denominator = abs(denominator)
    If ( absolute_denominator < 1.0_dp ) Then
      If ( abs(numerator) > huge(result)*absolute_denominator ) Return
    EndIf
    result = numerator/denominator
    safe_divide = finite_value(result)

    Return
  End Function safe_divide

  Logical Function safe_sum(values,result)
    Implicit None
    Real(dp), Intent(in) :: values(:)
    Real(dp), Intent(out) :: result
    Integer :: i
    Real(dp) :: next_sum

    safe_sum = .False.
    result = 0.0_dp
    Do i = 1, size(values)
      If ( .not. safe_add(result,values(i),next_sum) ) Return
      result = next_sum
    EndDo
    safe_sum = .True.

    Return
  End Function safe_sum

  Logical Function safe_electron_fraction(xmass,aa,zz,ye)
    Implicit None
    Real(dp), Intent(in) :: xmass(:), aa(:), zz(:)
    Real(dp), Intent(out) :: ye
    Integer :: i
    Real(dp) :: component, next_ye, proton_fraction

    safe_electron_fraction = .False.
    ye = 0.0_dp
    Do i = 1, size(xmass)
      If ( .not. safe_divide(zz(i),aa(i),proton_fraction) ) Return
      If ( .not. safe_multiply(xmass(i),proton_fraction,component) ) Return
      If ( .not. safe_add(ye,component,next_ye) ) Return
      ye = next_ye
    EndDo
    safe_electron_fraction = .True.

    Return
  End Function safe_electron_fraction

  Logical Function within_energy_tolerance(residual,reported_rate,expected_rate, &
    & absolute_tolerance,relative_tolerance)
    ! Compare nonnegative tolerance terms without constructing an overflowing allowed-error sum.
    Implicit None
    Real(dp), Intent(in) :: residual, reported_rate, expected_rate
    Real(dp), Intent(in) :: absolute_tolerance, relative_tolerance
    Real(dp) :: difference, relative_allowance, remaining, scale

    within_energy_tolerance = .False.
    difference = abs(residual)
    If ( difference <= absolute_tolerance ) Then
      within_energy_tolerance = .True.
      Return
    EndIf
    remaining = difference-absolute_tolerance
    scale = max(abs(expected_rate),abs(reported_rate))
    If ( scale == 0.0_dp .or. relative_tolerance == 0.0_dp ) Return
    If ( .not. safe_multiply(relative_tolerance,scale,relative_allowance) ) Then
      within_energy_tolerance = .True.
      Return
    EndIf
    within_energy_tolerance = remaining <= relative_allowance

    Return
  End Function within_energy_tolerance

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
