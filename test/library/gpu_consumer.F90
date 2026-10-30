! Hardware-only external caller for the dense CUDA/cuBLAS and HIP/hipBLAS archive.
#include "xnet_macros.fh"
#if !defined(XNET_GPU) || !(defined(XNET_LA_CUBLAS) || defined(XNET_LA_ROCM))
#error gpu_consumer requires a CUDA/cuBLAS or HIP/hipBLAS build
#endif
#if !defined(XNET_OACC) && !defined(XNET_OMP_OL)
#error gpu_consumer requires OpenACC or OpenMP target offload
#endif

Program gpu_consumer
  Use, Intrinsic :: iso_c_binding, Only: C_PTR, C_NULL_PTR, C_INT, C_LONG_LONG, C_LOC, C_Associated
  Use, Intrinsic :: ieee_arithmetic, Only: ieee_is_finite, ieee_value, ieee_quiet_nan, ieee_positive_inf
  Use xnet_api, Only: dp, xnet_controls_t, xnet_network_t, xnet_timing_t, xnet_gpu_t, &
    & set_xnet_controls_defaults, xnet_initialize, xnet_burn_batch, xnet_finalize, xnet_success, xnet_invalid
  Use consumer_fixture, Only: fixture_state, write_state, check
#if defined(XNET_CUDA)
  Use xnet_cudaf, Only: cudaGetDeviceCount, cudaGetDevice, cudaSetDevice, cudaStreamCreateWithFlags, &
    & cudaStreamNonBlocking, cudaStreamDestroy, cudaStreamSynchronize
  Use xnet_cublasf, Only: cublasCreate_v2, cublasDestroy_v2, cublasGetStream_v2, cublasSetStream_v2, &
    & cublasDgemm_v2, CUBLAS_OP_N
  Use xnet_cusolverf, Only: cusolverDnCreate, cusolverDnDestroy, cusolverDnGetStream, cusolverDnSetStream
#elif defined(XNET_HIP)
  Use xnet_hipf, Only: hipGetDeviceCount, hipGetDevice, hipSetDevice, hipStreamCreateWithFlags, &
    & hipStreamNonBlocking, hipStreamDestroy, hipStreamSynchronize
  Use xnet_hipblasf, Only: hipblasCreate, hipblasDestroy, hipblasGetStream, hipblasSetStream, &
    & hipblasDgemm, HIPBLAS_OP_N
  Use xnet_rocblasf, Only: rocblas_create_handle, rocblas_destroy_handle, rocblas_get_stream, rocblas_set_stream
#endif
#if defined(XNET_OACC)
  Use openacc, Only: acc_set_device_num, acc_device_default, acc_on_device, acc_device_host
  Use xnet_openaccf, Only: acc_get_cuda_stream, acc_set_cuda_stream, acc_deviceptr
#elif defined(XNET_OMP_OL)
  Use omp_lib, Only: omp_set_default_device, omp_is_initial_device, omp_get_mapped_ptr
#endif
  Implicit None

  Integer, Parameter :: lanes = 4, phases = 5, host_queue = 7
  Real(dp), Parameter :: gpu_rtol = 1.0e-7_dp, mass_fraction_atol = 1.0e-12_dp
  Real(dp), Parameter :: loss_rtol = 1.0e-6_dp
  Character(8), Parameter :: phase_names(phases) = [Character(8) :: 'first','repeat','short','hole','inactive']
  Type :: result_t
    Real(dp), Allocatable :: x(:,:)
    Real(dp) :: temperature(lanes), ye(lanes), loss(lanes)
  End Type result_t
  Type(result_t) :: expected(phases)
  Type(xnet_controls_t) :: controls
  Type(xnet_network_t) :: network
  Type(xnet_timing_t) :: timing
  Type(xnet_gpu_t) :: resources
  Type(C_PTR) :: host_handle, host_stream, queried_stream
#if defined(XNET_OACC)
  Type(C_PTR) :: prior_queue_stream, owned_queue_stream
#endif
  Integer(C_INT) :: status, device_count, current_device
  Integer :: ierr, device, isolv, iheat, i, ownership, path, phase, n, steps
  Integer :: ids(3,lanes), counters(5,lanes)
  Character(1024) :: data_dir
  Character(80) :: argument, label, prefix
  Character(512) :: message
  Logical :: active(lanes), resident, offloaded
  Real(dp), Target :: density(lanes), temperature(lanes), ye(lanes), restart(lanes), loss(lanes)
  Real(dp), Target :: aux_x(lanes), aux_a(lanes), aux_z(lanes)
  Real(dp), Allocatable, Target :: x(:,:)
  Real(dp), Allocatable :: before_x(:,:), input_x(:,:,:)
  Real(dp) :: input_density(lanes,phases), input_temperature(lanes,phases), input_ye(lanes,phases)
  Real(dp) :: input_restart(lanes,phases), input_aux_x(lanes,phases), input_aux_a(lanes,phases), input_aux_z(lanes,phases)
  Real(dp) :: before_temperature(lanes), before_ye(lanes), before_restart(lanes), times(6)

  Call check(Command_Argument_Count() >= 3,'expected data_dir, isolv, iheat, and optional device arguments')
  Call Get_Command_Argument(1,data_dir)
  Call Get_Command_Argument(2,argument)
  Read(argument,*,iostat=ierr) isolv
  Call check(ierr == 0,'invalid integrator argument')
  Call check(isolv == 1 .or. isolv == 3,'integrator must be BE or BDF')
  Call Get_Command_Argument(3,argument)
  Read(argument,*,iostat=ierr) iheat
  Call check(ierr == 0,'invalid self-heating argument')
  Call check(iheat == 0 .or. iheat == 1,'self-heating must be off or on')
  device = 0
  If ( Command_Argument_Count() >= 4 ) Then
    Call Get_Command_Argument(4,argument)
    Read(argument,*,iostat=ierr) device
    Call check(ierr == 0,'invalid device argument')
  EndIf

  ! The host chooses its device before calling the public initialization procedure.
#if defined(XNET_CUDA)
  status = cudaGetDeviceCount(device_count)
  Call runtime_ok('cudaGetDeviceCount')
#elif defined(XNET_HIP)
  status = hipGetDeviceCount(device_count)
  Call runtime_ok('hipGetDeviceCount')
#endif
  Call check(device >= 0 .and. device < device_count,'requested GPU is present')
#if defined(XNET_CUDA)
  status = cudaSetDevice(Int(device,C_INT))
#elif defined(XNET_HIP)
  status = hipSetDevice(Int(device,C_INT))
#endif
  Call runtime_ok('host device selection')
#if defined(XNET_OACC)
  Call acc_set_device_num(device,acc_device_default)
  offloaded = .false.
  !$acc serial copy(offloaded)
  offloaded = .not. acc_on_device(acc_device_host)
  !$acc end serial
#elif defined(XNET_OMP_OL)
  Call omp_set_default_device(device)
  offloaded = .false.
  !$omp target map(from:offloaded)
  offloaded = .not. omp_is_initial_device()
  !$omp end target
#endif
  Call check(offloaded,'directive region must execute on a GPU')
  Call selected_device_unchanged()

  Call set_xnet_controls_defaults(controls)
  controls%data_dir = data_dir
  controls%nzone = lanes
  controls%nzbatchmx = lanes
  controls%isolv = isolv
  controls%iheat = iheat
  controls%t9nse = 11.0_dp
  controls%idiag = -2
  If ( isolv == 3 ) Then
    controls%kitmx = 10
    controls%iconvc = 3
    controls%ymin = 1.0e-99_dp
  EndIf
  Do i = 1, lanes
    ids(:,i) = [i,7,11]
  EndDo

  Do ownership = 1, 2
    If ( ownership == 1 ) Then
      prefix = 'owned'
#if defined(XNET_OACC)
      owned_queue_stream = acc_get_cuda_stream(1_C_LONG_LONG)
#endif
      Call xnet_initialize(controls,network,ierr,message)
    Else
      prefix = 'borrowed'
      Call create_host_resources()
      resources%device = device
      resources%stream = host_stream
#if defined(XNET_CUDA)
      resources%cublas_handle = host_handle
#elif defined(XNET_HIP)
      resources%hipblas_handle = host_handle
#endif
      resources%queue = host_queue
      Call xnet_initialize(controls,network,ierr,message,gpu_resources=resources)
    EndIf
    Call api_ok(Trim(prefix)//' initialize')
    Call selected_device_unchanged()
    If ( ownership == 1 ) Then
      Allocate(x(Size(network%names),lanes),before_x(Size(network%names),lanes), &
        & input_x(Size(network%names),lanes,phases))
      Do i = 1, phases
        Allocate(expected(i)%x(Size(network%names),lanes))
      EndDo
      Do i = 1, Size(network%names)
        Write(*,'(a,1x,a,4(1x,es26.17e3))') 'META',Trim(Adjustl(network%names(i))), &
          & Real(network%mass_number(i),dp),Real(network%charge_number(i),dp), &
          & network%binding_energy_mev(i),network%mass_excess_mev(i)
      EndDo
    EndIf
    Do path = 1, 3
      resident = path /= 1
      Call fixture_state(network%names,density,temperature,ye,x,restart,aux_x,aux_a,aux_z)
      loss = -1.0_dp
      ! Mapped host calls start with deliberately wrong device mirrors.
      If ( .not. resident ) Call poison_host_reals()
      !XDIR XENTER_DATA XCOPYIN(density,temperature,ye,x,restart,loss,aux_x,aux_a,aux_z)
      If ( .not. resident ) Call fixture_state(network%names,density,temperature,ye,x,restart,aux_x,aux_a,aux_z)
      Do phase = 1, phases
        n = lanes
        active = .true.
        If ( phase == 3 ) n = lanes - 1
        If ( phase == 4 ) active(2) = .false.
        If ( phase == 5 ) active = .false.
        If ( path == 3 ) Then
          label = Trim(prefix)//'_device_chain_'//Trim(phase_names(phase))
        ElseIf ( resident ) Then
          label = Trim(prefix)//'_device_'//Trim(phase_names(phase))
        Else
          label = Trim(prefix)//'_host_'//Trim(phase_names(phase))
        EndIf
        If ( ownership == 1 .and. path == 1 ) Then
          ! Save the complete input to each canonical phase before its host burn.
          input_density(:,phase) = density
          input_temperature(:,phase) = temperature
          input_ye(:,phase) = ye
          input_x(:,:,phase) = x
          input_restart(:,phase) = restart
          input_aux_x(:,phase) = aux_x
          input_aux_a(:,phase) = aux_a
          input_aux_z(:,phase) = aux_z
        ElseIf ( path /= 3 ) Then
          ! Compared calls consume identical inputs, including the restart hint.
          density = input_density(:,phase)
          temperature = input_temperature(:,phase)
          ye = input_ye(:,phase)
          x = input_x(:,:,phase)
          restart = input_restart(:,phase)
          aux_x = input_aux_x(:,phase)
          aux_a = input_aux_a(:,phase)
          aux_z = input_aux_z(:,phase)
          If ( resident ) Then
            !XDIR XUPDATE XDEVICE(density,temperature,ye,x,restart,aux_x,aux_a,aux_z)
          EndIf
        EndIf
        ! The separate resident chain uploads no arrays or hints between burns.
        Call burn_and_check(compare_outputs=path /= 3)
      EndDo
      !XDIR XEXIT_DATA XDELETE(density,temperature,ye,x,restart,loss,aux_x,aux_a,aux_z)
    EndDo
    If ( ownership == 2 ) Then
      Call producer_burn(.true.)
      Call producer_burn(.false.)
    EndIf
    Call invalid_device_density()
    Call xnet_finalize(ierr,message)
    Call api_ok(Trim(prefix)//' finalize')
    Call selected_device_unchanged()
#if defined(XNET_OACC)
    If ( ownership == 1 ) Then
      queried_stream = acc_get_cuda_stream(1_C_LONG_LONG)
      Call check(C_Associated(queried_stream,owned_queue_stream),'OpenACC queue-one stream association survived')
      status = cudaStreamSynchronize(owned_queue_stream)
      Call runtime_ok('OpenACC runtime stream after finalize')
    EndIf
#endif
    If ( ownership == 2 ) Call check_and_destroy_host_resources()
  EndDo
  Call solver_only_resources()
  Do i = 1, phases
    Deallocate(expected(i)%x)
  EndDo
  Deallocate(x,before_x,input_x)
  Write(*,'(a)') 'GPU_CONSUMER_CHECKS_COMPLETED'

Contains

  Subroutine runtime_ok(operation)
    Implicit None
    Character(*), Intent(in) :: operation

    If ( status /= 0 ) Write(*,'(a,1x,a,1x,i0)') 'GPU_RUNTIME_ERROR',Trim(operation),status
    Call check(status == 0,operation)
    Return
  End Subroutine runtime_ok

  Subroutine api_ok(operation)
    Implicit None
    Character(*), Intent(in) :: operation

    If ( ierr /= xnet_success ) Write(*,'(a,i0,2a)') 'Unexpected status ',ierr,': ',Trim(message)
    Call check(ierr == xnet_success,operation)
    Return
  End Subroutine api_ok

  Subroutine selected_device_unchanged()
    Implicit None
#if defined(XNET_CUDA)
    status = cudaGetDevice(current_device)
#elif defined(XNET_HIP)
    status = hipGetDevice(current_device)
#endif
    Call runtime_ok('query host device')
    Call check(current_device == device,'XNet must preserve the selected host device')
    Return
  End Subroutine selected_device_unchanged

  Subroutine poison_host_reals()
    ! Do not transfer these values: host and device mirrors must disagree.
    Implicit None

    density = -1.0_dp
    temperature = -1.0_dp
    ye = -1.0_dp
    x = -1.0_dp
    restart = -1.0_dp
    aux_x = -1.0_dp
    aux_a = -1.0_dp
    aux_z = -1.0_dp
    Return
  End Subroutine poison_host_reals

  Subroutine burn_and_check(compare_outputs)
    Implicit None
    Logical, Intent(in) :: compare_outputs
    Integer :: j
    Logical :: submitted_active(lanes)

    submitted_active = active
    If ( phase == 4 ) Call check(active(1) .and. .not. active(2) .and. active(3) .and. active(4) .and. &
      & Count(active) == 3,Trim(label)//' submitted hole mask')
    before_x = x
    before_temperature = temperature
    before_ye = ye
    before_restart = restart
    loss = -1.0_dp
    counters = -1
    steps = -1
    If ( resident ) Then
      Call poison_host_reals()
      Call xnet_burn_batch(0.1_dp,active(:n),ids(:,:n),density(:n),temperature(:n),ye(:n),x(:,:n), &
        & restart(:n),loss(:n),counters(:,:n),timing,ierr,message,aux_x(:n),aux_a(:n),aux_z(:n), &
        & max_steps_taken=steps,data_on_device=.true.)
      ! No stream wait here: the API must finish its device outputs before returning.
      !XDIR XUPDATE XHOST(density,temperature,ye,x,restart,loss,aux_x,aux_a,aux_z)
    ElseIf ( phase == 1 ) Then
      ! Keep an existing host-array source call, with the residency option omitted.
      Call xnet_burn_batch(0.1_dp,active(:n),ids(:,:n),density(:n),temperature(:n),ye(:n),x(:,:n), &
        & restart(:n),loss(:n),counters(:,:n),timing,ierr,message,aux_x(:n),aux_a(:n),aux_z(:n), &
        & max_steps_taken=steps)
    Else
      Call xnet_burn_batch(0.1_dp,active(:n),ids(:,:n),density(:n),temperature(:n),ye(:n),x(:,:n), &
        & restart(:n),loss(:n),counters(:,:n),timing,ierr,message,aux_x(:n),aux_a(:n),aux_z(:n), &
        & max_steps_taken=steps,data_on_device=.false.)
    EndIf
    Call api_ok(Trim(label)//' burn')
    If ( .not. resident ) Call check_host_device_poison()
    Call check(All(active .eqv. submitted_active),Trim(label)//' unchanged active mask')
    Call selected_device_unchanged()
    times = [timing%seconds,timing%solve,timing%jacobian,timing%derivative,timing%rates,timing%screening]
    Call check(All(ieee_is_finite(times)) .and. All(times >= 0.0_dp),Trim(label)//' timing')
    Call check((Any(active(:n)) .and. steps > 0) .or. (.not. Any(active(:n)) .and. steps == 0), &
      & Trim(label)//' accepted step count')
    Do j = 1, n
      If ( active(j) ) Then
        Call check(All(ieee_is_finite(x(:,j))) .and. All(x(:,j) >= 0.0_dp),Trim(label)//' composition')
        Call check(ieee_is_finite(temperature(j)) .and. temperature(j) > 0.0_dp,Trim(label)//' temperature')
        Call check(ieee_is_finite(ye(j)) .and. ye(j) >= 0.0_dp .and. ye(j) <= 1.0_dp,Trim(label)//' Ye')
        Call check(ieee_is_finite(restart(j)) .and. restart(j) >= 0.0_dp,Trim(label)//' restart')
        Call check(ieee_is_finite(loss(j)) .and. loss(j) >= 0.0_dp,Trim(label)//' neutrino loss')
        Call check(counters(1,j) > 0 .and. All(counters(:,j) >= 0),Trim(label)//' counters')
        If ( iheat == 0 ) Call check(Abs(temperature(j)-before_temperature(j)) <= &
          & 2.0_dp*Epsilon(1.0_dp)*before_temperature(j),Trim(label)//' fixed temperature')
      Else
        Call check(All(x(:,j) == before_x(:,j)) .and. temperature(j) == before_temperature(j) .and. &
          & ye(j) == before_ye(j) .and. restart(j) == before_restart(j),Trim(label)//' inactive state')
        Call check(loss(j) == 0.0_dp .and. All(counters(:,j) == 0),Trim(label)//' inactive outputs')
      EndIf
    EndDo
    If ( n < lanes ) Call check(All(x(:,n+1:) == before_x(:,n+1:)) .and. &
      & All(temperature(n+1:) == before_temperature(n+1:)) .and. All(ye(n+1:) == before_ye(n+1:)) .and. &
      & All(restart(n+1:) == before_restart(n+1:)),Trim(label)//' beyond short batch')
    If ( .not. Any(active(:n)) ) Call check(All(times == 0.0_dp),Trim(label)//' empty timing')
    ! Print valid results before comparison so a failed comparison can be diagnosed.
    Write(*,'(a,1x,a,1x,i0)') 'STEPS',Trim(label),steps
    Write(*,'(a,1x,a,6(1x,es26.17e3))') 'TIMING',Trim(label),times
    Call write_state(label,temperature(:n),ye(:n),x(:,:n),restart(:n),loss(:n),counters(:,:n))
    If ( .not. compare_outputs ) Then
      ! Observe evolution from the consumed state, not agreement across different histories.
      Write(*,'(a,1x,a,4(1x,es26.17e3))') 'CONTINUATION_DELTA',Trim(label), &
        & Maxval(Abs(x(:,:n)-before_x(:,:n))),Maxval(Abs(temperature(:n)-before_temperature(:n))), &
        & Maxval(Abs(ye(:n)-before_ye(:n))),Maxval(Abs(restart(:n)-before_restart(:n)))
    ElseIf ( ownership == 1 .and. .not. resident ) Then
      expected(phase)%x = x
      expected(phase)%temperature = temperature
      expected(phase)%ye = ye
      expected(phase)%loss = loss
    Else
      ! GPU atomic updates and reductions may change floating-point ordering between calls.
      Call check(All(Abs(x(:,:n)-expected(phase)%x(:,:n)) <= &
        & mass_fraction_atol + gpu_rtol*Max(Abs(x(:,:n)),Abs(expected(phase)%x(:,:n)))), &
        & Trim(label)//' mass-fraction comparison')
      Call check(All(Abs(temperature(:n)-expected(phase)%temperature(:n)) <= &
        & gpu_rtol*Max(Abs(temperature(:n)),Abs(expected(phase)%temperature(:n)))), &
        & Trim(label)//' temperature comparison')
      Call check(All(Abs(ye(:n)-expected(phase)%ye(:n)) <= &
        & gpu_rtol*Max(Abs(ye(:n)),Abs(expected(phase)%ye(:n)))),Trim(label)//' Ye comparison')
      Call check(All(Abs(loss(:n)-expected(phase)%loss(:n)) <= &
        & loss_rtol*Max(Abs(loss(:n)),Abs(expected(phase)%loss(:n)))),Trim(label)//' neutrino-loss comparison')
    EndIf
    If ( phase == 2 ) Call check(Any(x(:,1) /= before_x(:,1)),Trim(label)//' repeated evolution')
    Return
  End Subroutine burn_and_check

  Subroutine check_host_device_poison()
    ! Return only the assertion result; preserve the scientific host outputs.
    Implicit None
    Logical :: mirrors_poisoned

#if defined(XNET_OACC)
    !$acc serial present(density,temperature,ye,x,restart,loss,aux_x,aux_a,aux_z) copyout(mirrors_poisoned)
#elif defined(XNET_OMP_OL)
    !$omp target map(alloc:density,temperature,ye,x,restart,loss,aux_x,aux_a,aux_z) map(from:mirrors_poisoned)
#endif
    mirrors_poisoned = All(density == -1.0_dp) .and. All(temperature == -1.0_dp) .and. &
      & All(ye == -1.0_dp) .and. All(x == -1.0_dp) .and. All(restart == -1.0_dp) .and. &
      & All(loss == -1.0_dp) .and. All(aux_x == -1.0_dp) .and. All(aux_a == -1.0_dp) .and. All(aux_z == -1.0_dp)
#if defined(XNET_OACC)
    !$acc end serial
#elif defined(XNET_OMP_OL)
    !$omp end target
#endif
    Call check(mirrors_poisoned,Trim(label)//' unchanged scientific device mirrors')
    Return
  End Subroutine check_host_device_poison

  Subroutine invalid_device_density()
    ! Reject nonfinite resident input before integration; inspect only host diagnostics.
    Implicit None
    Real(dp) :: invalid_density(2)
    Integer :: invalid_case

    invalid_density = [ieee_value(0.0_dp,ieee_quiet_nan),ieee_value(0.0_dp,ieee_positive_inf)]
    Do invalid_case = 1, Size(invalid_density)
      Call fixture_state(network%names,density,temperature,ye,x,restart,aux_x,aux_a,aux_z)
      density(1) = invalid_density(invalid_case)
      active = .true.
      loss = -1.0_dp
      counters = -1
      steps = -1
      timing = xnet_timing_t(seconds=-1.0_dp,solve=-1.0_dp,jacobian=-1.0_dp, &
        & derivative=-1.0_dp,rates=-1.0_dp,screening=-1.0_dp)
      !XDIR XENTER_DATA XCOPYIN(density,temperature,ye,x,restart,loss,aux_x,aux_a,aux_z)
      ! Keep the host mirror finite so the required rejection must read device data.
      density(1) = density(2)
      Call xnet_burn_batch(0.1_dp,active,ids,density,temperature,ye,x,restart,loss,counters, &
        & timing,ierr,message,aux_x,aux_a,aux_z,max_steps_taken=steps,data_on_device=.true.)
      ! Release the mappings without copying or inspecting rejected scientific results.
      !XDIR XEXIT_DATA XDELETE(density,temperature,ye,x,restart,loss,aux_x,aux_a,aux_z)
      If ( invalid_case == 1 ) Then
        label = Trim(prefix)//'_device_nan'
      Else
        label = Trim(prefix)//'_device_inf'
      EndIf
      If ( ierr /= xnet_invalid ) Write(*,'(a,i0,2a)') 'Unexpected status ',ierr,': ',Trim(message)
      Call check(ierr == xnet_invalid,Trim(label)//' invalid status')
      Call check(Trim(message) == 'Active-zone inputs must be finite',Trim(label)//' finite-input diagnostic')
      Call check(All(counters == 0) .and. steps == 0,Trim(label)//' zero counters and accepted steps')
      times = [timing%seconds,timing%solve,timing%jacobian,timing%derivative,timing%rates,timing%screening]
      Call check(All(times == 0.0_dp),Trim(label)//' zero timing')
      Call selected_device_unchanged()
      Write(*,'(a,1x,a)') 'INVALID_DEVICE_INPUT_REJECTED',Trim(label)
    EndDo
    Return
  End Subroutine invalid_device_density

  Subroutine producer_burn(synchronize)
    ! Keep the queued GEMM inputs mapped through the subsequent resident burn.
    Implicit None
    Logical, Intent(in) :: synchronize
    Integer, Parameter :: order = 256, queued_gemms = 4
    Real(dp), Target :: a(order,order), b(order,order), c(order,order), source_density(lanes), unit_matrix(1)
    Real(dp) :: one, zero
    Type(C_PTR) :: da, db, dc, dsource, dunit, ddensity
    Integer :: queued

    Call fixture_state(network%names,density,temperature,ye,x,restart,aux_x,aux_a,aux_z)
    source_density = density
    density = -1.0_dp
    loss = -1.0_dp
    a = 1.0_dp
    b = 1.0_dp
    c = 0.0_dp
    unit_matrix = 1.0_dp
    one = 1.0_dp
    zero = 0.0_dp
    ! All mappings and pointer queries precede submission to the nonblocking stream.
    !XDIR XENTER_DATA XCOPYIN(density,temperature,ye,x,restart,loss,aux_x,aux_a,aux_z)
    !XDIR XENTER_DATA XCOPYIN(a,b,c,source_density,unit_matrix)
    density = source_density
    da = mapped_pointer(C_LOC(a(1,1)))
    db = mapped_pointer(C_LOC(b(1,1)))
    dc = mapped_pointer(C_LOC(c(1,1)))
    dsource = mapped_pointer(C_LOC(source_density(1)))
    dunit = mapped_pointer(C_LOC(unit_matrix(1)))
    ddensity = mapped_pointer(C_LOC(density(1)))
    Do queued = 1, queued_gemms
#if defined(XNET_CUDA)
      status = cublasDgemm_v2(host_handle,CUBLAS_OP_N,CUBLAS_OP_N,order,order,order,one,da,order, &
        & db,order,zero,dc,order)
#elif defined(XNET_HIP)
      status = hipblasDgemm(host_handle,HIPBLAS_OP_N,HIPBLAS_OP_N,order,order,order,one,da,order, &
        & db,order,zero,dc,order)
#endif
      Call runtime_ok('queued host GEMM')
    EndDo
#if defined(XNET_CUDA)
    status = cublasDgemm_v2(host_handle,CUBLAS_OP_N,CUBLAS_OP_N,lanes,1,1,one,dsource,lanes,dunit,1,zero,ddensity,lanes)
#elif defined(XNET_HIP)
    status = hipblasDgemm(host_handle,HIPBLAS_OP_N,HIPBLAS_OP_N,lanes,1,1,one,dsource,lanes,dunit,1,zero,ddensity,lanes)
#endif
    Call runtime_ok('queued density producer')
    If ( synchronize ) Then
#if defined(XNET_CUDA)
      status = cudaStreamSynchronize(host_stream)
#elif defined(XNET_HIP)
      status = hipStreamSynchronize(host_stream)
#endif
      Call runtime_ok('explicit producer synchronization')
      label = 'borrowed_producer_sync'
    Else
      label = 'borrowed_producer_queued'
    EndIf
    resident = .true.
    phase = 1
    n = lanes
    active = .true.
    ! The queued case has no host stream wait or additional mapping before API entry.
    Call burn_and_check(compare_outputs=.true.)
    Call check(All(density == source_density),Trim(label)//' produced density')
    !XDIR XEXIT_DATA XDELETE(a,b,c,source_density,unit_matrix)
    !XDIR XEXIT_DATA XDELETE(density,temperature,ye,x,restart,loss,aux_x,aux_a,aux_z)
    Return
  End Subroutine producer_burn

  Function mapped_pointer(hostptr) Result(deviceptr)
    Implicit None
    Type(C_PTR), Intent(in) :: hostptr
    Type(C_PTR) :: deviceptr

#if defined(XNET_OACC)
    deviceptr = acc_deviceptr(hostptr)
#elif defined(XNET_OMP_OL)
    deviceptr = omp_get_mapped_ptr(hostptr,device)
#endif
    Call check(C_Associated(deviceptr),'producer device mapping')
    Return
  End Function mapped_pointer

  Subroutine create_host_resources()
    Implicit None
#if defined(XNET_CUDA)
    status = cudaStreamCreateWithFlags(host_stream,cudaStreamNonBlocking)
    Call runtime_ok('host stream creation')
    status = cublasCreate_v2(host_handle)
    Call runtime_ok('host BLAS creation')
    status = cublasSetStream_v2(host_handle,host_stream)
#elif defined(XNET_HIP)
    status = hipStreamCreateWithFlags(host_stream,hipStreamNonBlocking)
    Call runtime_ok('host stream creation')
    status = hipblasCreate(host_handle)
    Call runtime_ok('host BLAS creation')
    status = hipblasSetStream(host_handle,host_stream)
#endif
    Call runtime_ok('host BLAS stream selection')
#if defined(XNET_OACC)
    prior_queue_stream = acc_get_cuda_stream(Int(host_queue,C_LONG_LONG))
    Call acc_set_cuda_stream(Int(host_queue,C_LONG_LONG),host_stream)
#endif
    Return
  End Subroutine create_host_resources

  Subroutine solver_only_resources()
    ! Borrow a solver handle but let XNet create its missing BLAS handles.
    Implicit None
    Type(C_PTR) :: solver_handle

    Call create_host_resources()
    resources = xnet_gpu_t()
    resources%device = device
    resources%stream = host_stream
    resources%queue = host_queue
#if defined(XNET_CUDA)
    status = cusolverDnCreate(solver_handle)
    Call runtime_ok('host solver creation')
    status = cusolverDnSetStream(solver_handle,host_stream)
    resources%cusolver_handle = solver_handle
#elif defined(XNET_HIP)
    status = rocblas_create_handle(solver_handle)
    Call runtime_ok('host solver creation')
    status = rocblas_set_stream(solver_handle,host_stream)
    resources%rocsolver_handle = solver_handle
#endif
    Call runtime_ok('host solver stream selection')
    Call xnet_initialize(controls,network,ierr,message,gpu_resources=resources)
    Call api_ok('solver-only borrowing initialize')
    Call xnet_finalize(ierr,message)
    Call api_ok('solver-only borrowing finalize')
#if defined(XNET_CUDA)
    status = cusolverDnGetStream(solver_handle,queried_stream)
#elif defined(XNET_HIP)
    status = rocblas_get_stream(solver_handle,queried_stream)
#endif
    Call runtime_ok('borrowed solver after finalize')
    Call check(C_Associated(queried_stream,host_stream),'borrowed solver stream association survived')
#if defined(XNET_CUDA)
    status = cusolverDnDestroy(solver_handle)
#elif defined(XNET_HIP)
    status = rocblas_destroy_handle(solver_handle)
#endif
    Call runtime_ok('host solver destruction')
    Call check_and_destroy_host_resources()
    Write(*,'(a)') 'GPU_SOLVER_ONLY_BORROWING_COMPLETED'
    Return
  End Subroutine solver_only_resources

  Subroutine check_and_destroy_host_resources()
    ! A genuine vendor GEMM after finalization proves that the borrowed handle and stream survived.
    Implicit None
    Real(dp), Target :: a(1), b(1), c(1)
    Real(dp) :: one, zero
    Type(C_PTR) :: da, db, dc

#if defined(XNET_CUDA)
    status = cublasGetStream_v2(host_handle,queried_stream)
#elif defined(XNET_HIP)
    status = hipblasGetStream(host_handle,queried_stream)
#endif
    Call runtime_ok('borrowed BLAS stream after finalize')
    Call check(C_Associated(queried_stream,host_stream),'borrowed BLAS stream association survived')
#if defined(XNET_OACC)
    queried_stream = acc_get_cuda_stream(Int(host_queue,C_LONG_LONG))
    Call check(C_Associated(queried_stream,host_stream),'borrowed OpenACC queue association survived')
#endif
    a = 2.0_dp
    b = 3.0_dp
    c = 0.0_dp
    one = 1.0_dp
    zero = 0.0_dp
    !XDIR XENTER_DATA XCOPYIN(a,b,c)
#if defined(XNET_OACC)
    da = acc_deviceptr(C_LOC(a(1)))
    db = acc_deviceptr(C_LOC(b(1)))
    dc = acc_deviceptr(C_LOC(c(1)))
#elif defined(XNET_OMP_OL)
    da = omp_get_mapped_ptr(C_LOC(a(1)),device)
    db = omp_get_mapped_ptr(C_LOC(b(1)),device)
    dc = omp_get_mapped_ptr(C_LOC(c(1)),device)
#endif
    Call check(C_Associated(da) .and. C_Associated(db) .and. C_Associated(dc),'host probe device mappings')
#if defined(XNET_CUDA)
    status = cublasDgemm_v2(host_handle,CUBLAS_OP_N,CUBLAS_OP_N,1,1,1,one,da,1,db,1,zero,dc,1)
#elif defined(XNET_HIP)
    status = hipblasDgemm(host_handle,HIPBLAS_OP_N,HIPBLAS_OP_N,1,1,1,one,da,1,db,1,zero,dc,1)
#endif
    Call runtime_ok('host GEMM after finalize')
#if defined(XNET_CUDA)
    status = cudaStreamSynchronize(host_stream)
#elif defined(XNET_HIP)
    status = hipStreamSynchronize(host_stream)
#endif
    Call runtime_ok('host stream synchronization after finalize')
    !XDIR XUPDATE XHOST(c)
    !XDIR XEXIT_DATA XDELETE(a,b,c)
    Call check(c(1) == 6.0_dp,'host BLAS result after finalize')
#if defined(XNET_OACC)
    Call acc_set_cuda_stream(Int(host_queue,C_LONG_LONG),prior_queue_stream)
#endif
#if defined(XNET_CUDA)
    status = cublasDestroy_v2(host_handle)
    Call runtime_ok('host BLAS destruction')
    status = cudaStreamDestroy(host_stream)
#elif defined(XNET_HIP)
    status = hipblasDestroy(host_handle)
    Call runtime_ok('host BLAS destruction')
    status = hipStreamDestroy(host_stream)
#endif
    Call runtime_ok('host stream destruction')
    host_handle = C_NULL_PTR
    host_stream = C_NULL_PTR
    Return
  End Subroutine check_and_destroy_host_resources

End Program gpu_consumer
