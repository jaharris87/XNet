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
  Use, Intrinsic :: ieee_arithmetic, Only: ieee_is_finite
  Use xnet_api, Only: dp, xnet_controls_t, xnet_network_t, xnet_timing_t, xnet_gpu_resources_t, &
    & set_xnet_controls_defaults, xnet_initialize, xnet_burn_batch, xnet_finalize, xnet_success
  Use consumer_fixture, Only: fixture_state, write_state, check
#if defined(XNET_CUDA)
  Use cudaf, Only: cudaGetDeviceCount, cudaGetDevice, cudaSetDevice, cudaStreamCreate, &
    & cudaStreamDestroy, cudaStreamSynchronize
  Use cublasf, Only: cublasCreate_v2, cublasDestroy_v2, cublasGetStream_v2, cublasSetStream_v2, &
    & cublasDgemm_v2, CUBLAS_OP_N
#elif defined(XNET_HIP)
  Use hipf, Only: hipGetDeviceCount, hipGetDevice, hipSetDevice, hipStreamCreate, &
    & hipStreamDestroy, hipStreamSynchronize
  Use hipblasf, Only: hipblasCreate, hipblasDestroy, hipblasGetStream, hipblasSetStream, &
    & hipblasDgemm, HIPBLAS_OP_N
#endif
#if defined(XNET_OACC)
  Use openacc, Only: acc_set_device_num, acc_device_default, acc_on_device, acc_device_host
  Use openaccf, Only: acc_get_cuda_stream, acc_set_cuda_stream, acc_deviceptr
#elif defined(XNET_OMP_OL)
  Use omp_lib, Only: omp_set_default_device, omp_is_initial_device, omp_get_mapped_ptr
#endif
  Implicit None

  Integer, Parameter :: lanes = 4, phases = 5, host_queue = 7
  Character(8), Parameter :: phase_names(phases) = [Character(8) :: 'first','repeat','short','hole','inactive']
  Type :: result_t
    Real(dp), Allocatable :: x(:,:)
    Real(dp) :: temperature(lanes), ye(lanes), restart(lanes), loss(lanes)
    Integer :: counters(5,lanes), steps
  End Type result_t
  Type(result_t) :: expected(phases)
  Type(xnet_controls_t) :: controls
  Type(xnet_network_t) :: network
  Type(xnet_timing_t) :: timing
  Type(xnet_gpu_resources_t) :: resources
  Type(C_PTR) :: host_handle, host_stream, queried_stream
#if defined(XNET_OACC)
  Type(C_PTR) :: prior_queue_stream
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
  Real(dp), Allocatable :: before_x(:,:)
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
      Call xnet_initialize(controls,network,ierr,message)
    Else
      prefix = 'borrowed'
      Call create_host_resources()
      resources%device = device
      resources%stream = host_stream
      resources%blas_handle = host_handle
      resources%queue = host_queue
      Call xnet_initialize(controls,network,ierr,message,gpu_resources=resources)
    EndIf
    Call api_ok(Trim(prefix)//' initialize')
    Call selected_device_unchanged()
    If ( ownership == 1 ) Then
      Allocate(x(Size(network%names),lanes),before_x(Size(network%names),lanes))
      Do i = 1, phases
        Allocate(expected(i)%x(Size(network%names),lanes))
      EndDo
      Do i = 1, Size(network%names)
        Write(*,'(a,1x,a,4(1x,es26.17e3))') 'META',Trim(Adjustl(network%names(i))), &
          & Real(network%mass_number(i),dp),Real(network%charge_number(i),dp), &
          & network%binding_energy_mev(i),network%mass_excess_mev(i)
      EndDo
    EndIf
    Do path = 1, 2
      resident = path == 2
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
        If ( phase == 4 ) active = [.true.,.false.,.true.,.true.]
        If ( phase == 5 ) active = .false.
        If ( resident ) Then
          label = Trim(prefix)//'_device_'//Trim(phase_names(phase))
        Else
          label = Trim(prefix)//'_host_'//Trim(phase_names(phase))
        EndIf
        Call burn_and_check()
      EndDo
      !XDIR XEXIT_DATA XDELETE(density,temperature,ye,x,restart,loss,aux_x,aux_a,aux_z)
    EndDo
    Call xnet_finalize(ierr,message)
    Call api_ok(Trim(prefix)//' finalize')
    Call selected_device_unchanged()
    If ( ownership == 2 ) Call check_and_destroy_host_resources()
  EndDo
  Do i = 1, phases
    Deallocate(expected(i)%x)
  EndDo
  Deallocate(x,before_x)
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

  Subroutine burn_and_check()
    Implicit None
    Integer :: j

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
      & All(temperature(n+1:) == before_temperature(n+1:)),Trim(label)//' beyond short batch')
    If ( .not. Any(active(:n)) ) Call check(All(times == 0.0_dp),Trim(label)//' empty timing')
    If ( ownership == 1 .and. .not. resident ) Then
      expected(phase)%x = x
      expected(phase)%temperature = temperature
      expected(phase)%ye = ye
      expected(phase)%restart = restart
      expected(phase)%loss = loss
      expected(phase)%counters = counters
      expected(phase)%steps = steps
    Else
      ! The same archive/backend executes the same arithmetic, as in run_library_tests.py.
      Call check(All(x == expected(phase)%x) .and. All(temperature == expected(phase)%temperature) .and. &
        & All(ye == expected(phase)%ye) .and. All(restart == expected(phase)%restart),Trim(label)//' state equality')
      Call check(All(loss(:n) == expected(phase)%loss(:n)) .and. &
        & All(counters(:,:n) == expected(phase)%counters(:,:n)) .and. steps == expected(phase)%steps, &
        & Trim(label)//' diagnostic equality')
    EndIf
    If ( phase == 2 ) Call check(Any(x(:,1) /= expected(1)%x(:,1)),Trim(label)//' repeated evolution')
    Write(*,'(a,1x,a,1x,i0)') 'STEPS',Trim(label),steps
    Write(*,'(a,1x,a,6(1x,es26.17e3))') 'TIMING',Trim(label),times
    Call write_state(label,temperature(:n),ye(:n),x(:,:n),restart(:n),loss(:n),counters(:,:n))
    Return
  End Subroutine burn_and_check

  Subroutine create_host_resources()
    Implicit None
#if defined(XNET_CUDA)
    status = cudaStreamCreate(host_stream)
    Call runtime_ok('host stream creation')
    status = cublasCreate_v2(host_handle)
    Call runtime_ok('host BLAS creation')
    status = cublasSetStream_v2(host_handle,host_stream)
#elif defined(XNET_HIP)
    status = hipStreamCreate(host_stream)
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
