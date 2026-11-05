! Test-only replacement for the bundled EOS interface. Link before libxnet.a.
Module xnet_eos_interface
  Use xnet_types, Only: dp
  Use omp_lib, Only: omp_get_max_threads, omp_get_num_threads, omp_get_thread_num, omp_get_wtime
  Implicit None
  Private
  Public :: xnet_eos_interface_initialize, xnet_eos_interface_evaluate, xnet_eos_interface_finalize

  Logical, Allocatable :: seen(:)
  Logical :: timed_out = .false.
  Integer :: expected = 0, arrivals = 0, active = 0, max_active = 0

Contains

  Subroutine xnet_eos_interface_initialize(nspecies,names,a,z)
    Use actual_eos_module, Only: actual_eos_init
    Implicit None
    Integer, Intent(in) :: nspecies
    Character(*), Intent(in) :: names(nspecies)
    Real(dp), Intent(in) :: a(nspecies), z(nspecies)

    Call actual_eos_init()
    Allocate(seen(0:omp_get_max_threads()-1))
    seen = .false.
    timed_out = .false.
    expected = 0
    arrivals = 0
    active = 0
    max_active = 0
  End Subroutine xnet_eos_interface_initialize

  Subroutine xnet_eos_interface_evaluate(nspecies,temp,rho,ye,abar,zbar,y,xext,aext,zext,cv,eta,detadt)
    Use actual_eos_module, Only: xnet_actual_eos
    Use eos_type_module, Only: eos_input_rt, eos_t
    Implicit None
    Integer, Intent(in) :: nspecies
    Real(dp), Intent(in) :: temp, rho, ye, abar, zbar, y(nspecies)
    Real(dp), Intent(in) :: xext, aext, zext
    Real(dp), Intent(out) :: cv, eta, detadt
    Type(eos_t) :: eos_state
    Integer :: worker, team
    Logical :: first_entry, released
    Real(dp) :: started, elapsed

    ! This test runs alpha BDF self-heating only: no parallel NSE queries or
    ! EOS evaluations precede full_net. The mandatory serialized-full_net
    ! mutation checks that this observation still distinguishes evolution.
    first_entry = .false.
    team = omp_get_num_threads()
    If ( team > 1 ) Then
      worker = omp_get_thread_num()
      !$omp critical(xnet_test_overlap)
      If ( worker > Ubound(seen,1) ) Error Stop 'overlap probe: invalid worker'
      If ( expected == 0 ) expected = team
      If ( team /= expected ) Error Stop 'overlap probe: changed team'
      first_entry = .not. seen(worker)
      If ( first_entry ) Then
        seen(worker) = .true.
        arrivals = arrivals + 1
        active = active + 1
        max_active = Max(max_active,active)
      EndIf
      !$omp end critical(xnet_test_overlap)
      If ( first_entry ) Then
        ! A barrier would deadlock the deliberately serialized mutation.
        ! The watchdog bounds failure; passing requires live concurrent calls,
        ! not a speedup or a duration threshold. Each worker uses its own clock.
        started = omp_get_wtime()
        Do
          elapsed = omp_get_wtime() - started
          !$omp critical(xnet_test_overlap)
          If ( arrivals < expected .and. elapsed > 10.0_dp ) timed_out = .true.
          released = arrivals == expected .or. timed_out
          !$omp end critical(xnet_test_overlap)
          If ( released ) Exit
        EndDo
      EndIf
    EndIf

    ! Same inputs and calculation as source/xnet_eos_starkiller.F90.
    eos_state%rho = rho
    eos_state%T = temp
    eos_state%y_e = ye
    eos_state%abar = abar
    eos_state%zbar = zbar
    Call xnet_actual_eos(eos_input_rt,eos_state)
    cv = eos_state%cv
    eta = eos_state%eta
    detadt = eos_state%detadt

    If ( first_entry ) Then
      !$omp critical(xnet_test_overlap)
      active = active - 1
      !$omp end critical(xnet_test_overlap)
    EndIf
  End Subroutine xnet_eos_interface_evaluate

  Subroutine xnet_eos_interface_finalize
    Use actual_eos_module, Only: actual_eos_finalize
    Use iso_fortran_env, Only: output_unit
    Implicit None

    ! The consumer calls finalization after its application team has joined.
    Call actual_eos_finalize
    Write(output_unit,'(a,3(1x,i0),1x,l1)') 'XNET_OVERLAP_RESULT',expected,arrivals,max_active,timed_out
    Deallocate(seen)
    If ( timed_out .or. active /= 0 .or. arrivals /= expected .or. max_active /= expected ) Then
      Write(output_unit,'(a)') 'XNET_OVERLAP_FAILED: workers did not overlap inside full_net'
      Flush(output_unit)
      Error Stop 1
    EndIf
  End Subroutine xnet_eos_interface_finalize

End Module xnet_eos_interface
