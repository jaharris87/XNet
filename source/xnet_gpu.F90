!***************************************************************************************************
! xnet_gpu.f90 10/18/17
! This file contains modules and subroutines to control the GPU execution of XNet.
!***************************************************************************************************

#include "xnet_macros.fh"

Module xnet_gpu
  Use, Intrinsic :: iso_c_binding
  Use xnet_controls, Only: lun_stdout, myid, tid, gpu_queue
  Use xnet_types, Only: dp
  Use xnet_util, Only: xnet_terminate

#if defined(XNET_CUDA)
  Use xnet_cudaf, Only: &
    cuda_stream=>stream, &
    cudaGetDeviceCount, &
    cudaGetDevice, &
    cudaSetDevice, &
    cudaStreamCreate, &
    cudaStreamDestroy, &
    cudaStreamSynchronize, &
    cudaDeviceSynchronize, &
    cudaSuccess
  Use xnet_cublasf, Only: &
    cublas_handle, &
    cublasCreate_v2, &
    cublasDestroy_v2, &
    cublasGetStream_v2, &
    cublasSetStream_v2, &
    cublasSetSmCountTarget
  Use xnet_cusolverf, Only: &
    cusolver_handle, &
    cusolverDnCreate, &
    cusolverDnDestroy, &
    cusolverDnGetStream, &
    cusolverDnSetStream
  !Use xnet_cusparsef, Only: &
  !  cusparse_handle, &
  !  cusparseCreate, &
  !  cusparseDestroy, &
  !  cusparseSetStream
#elif defined(XNET_HIP)
  Use xnet_hipf, Only: &
    hip_stream=>stream, &
    hipGetDeviceCount, &
    hipGetDevice, &
    hipSetDevice, &
    hipStreamCreate, &
    hipStreamDestroy, &
    hipStreamSynchronize, &
    hipCheck, &
    hipblasCheck, &
    hipsparseCheck, &
    rocblasCheck, &
    rocsparseCheck, &
    rocsolverCheck
  Use xnet_rocblasf, Only: &
    rocblas_handle, &
    rocblas_create_handle, &
    rocblas_destroy_handle, &
    rocblas_get_stream, &
    rocblas_set_stream, &
    rocblas_set_pointer_mode, &
    rocblas_pointer_mode_device
  Use xnet_rocsolverf, Only: &
    rocsolver_handle
  !Use xnet_rocsparsef, Only: &
  !  rocsparse_handle
  Use xnet_hipblasf, Only: &
    hipblas_handle, &
    hipblasCreate, &
    hipblasDestroy, &
    hipblasGetStream, &
    hipblasSetStream
  !Use hipsparsef, Only: &
  !  hipsparse_handle, &
  !  hipsparseCreate, &
  !  hipsparseSetStream
#endif

#if defined(XNET_LA_MAGMA)
  Use xnet_magmaf, Only: &
    magma_device, &
    magma_queue, &
    magma_getdevice, &
    magma_init, &
    magma_queue_destroy, &
#if defined(XNET_CUDA)
    magma_queue_create_from_cuda
#elif defined(XNET_HIP)
    magma_queue_create_from_hip
#endif
#endif

#if defined(XNET_OMP_OL)
  Use xnet_openmpf, Only: &
    omp_set_default_device, &
    omp_get_default_device, &
    omp_is_initial_device, &
    omp_target_is_present
  Use omp_lib, Only : &
    omp_get_num_devices, &
    omp_get_mapped_ptr
#endif

#if defined(XNET_OACC)
  Use xnet_openaccf, Only: &
    acc_set_device_num, &
    acc_get_device_num, &
    acc_on_device, &
    acc_is_present, &
    acc_get_cuda_stream, &
    acc_set_cuda_stream, &
    acc_get_default_async, &
    acc_set_default_async, &
    acc_device_host, &
    acc_device_default, &
    acc_async_sync, &
    acc_async_noval, &
    acc_queue
#endif

  Implicit None
  Private

  Integer(C_INT), Public :: deviceCount = 0
  Integer, Public :: mydevice = -1
  Type(C_PTR), Pointer, Public :: stream => Null()

  ! Fields unused by the selected backend are neither validated nor modified.
  Type, Public :: xnet_gpu_t
    Integer :: device = -1
    Type(C_PTR) :: stream = C_NULL_PTR
    Integer :: queue = 1 ! OpenACC async ID associated with stream; unused for OpenMP offload
    Type(C_PTR) :: cublas_handle = C_NULL_PTR
    Type(C_PTR) :: cusolver_handle = C_NULL_PTR
    Type(C_PTR) :: cusparse_handle = C_NULL_PTR ! Reserved; GPU sparse resources are not currently used.
    Type(C_PTR) :: hipblas_handle = C_NULL_PTR
    Type(C_PTR) :: rocblas_handle = C_NULL_PTR
    Type(C_PTR) :: rocsolver_handle = C_NULL_PTR ! A rocBLAS handle; absent means share rocblas_handle.
    Type(C_PTR) :: rocsparse_handle = C_NULL_PTR ! Reserved; GPU sparse resources are not currently used.
    Type(C_PTR) :: magma_queue = C_NULL_PTR ! Reserved; application MAGMA initialization is not currently supported.
  End Type xnet_gpu_t

  ! Each host thread installs one resource set; ownership follows the vendor threadprivate handles.
  Logical :: gpu_initialized = .false.       ! Reject overlapping initialization on this host thread.
  Integer :: active_device = -1              ! Keep this device selected until finalization.
  Logical :: owns_stream = .false.           ! OpenACC owns its queue streams.
  !$omp threadprivate(stream,gpu_initialized,active_device,owns_stream)
#if defined(XNET_CUDA)
  Logical :: owns_cublas = .false.           ! Destroy only a cuBLAS handle created by XNet.
  Logical :: owns_cusolver = .false.         ! Destroy only a cuSOLVER handle created by XNet.
  !$omp threadprivate(owns_cublas,owns_cusolver)
#elif defined(XNET_HIP)
  Logical :: owns_hipblas = .false.          ! Destroy only a hipBLAS handle created by XNet.
  Logical :: owns_rocblas = .false.          ! The default rocSOLVER alias shares this ownership.
  !$omp threadprivate(owns_hipblas,owns_rocblas)
#endif
#if defined(XNET_LA_MAGMA)
  Logical :: owns_magma_queue = .false.      ! Supplied MAGMA queues are not currently supported.
  !$omp threadprivate(owns_magma_queue)
#endif

  Interface dev_ptr
    Module Procedure dev_ptr_int
    Module Procedure dev_ptr_dp
    Module Procedure dev_ptr_cptr
  End Interface

  Public :: gpu_init
  Public :: gpu_finalize
  Public :: gpu_check_device
  Public :: device_is_present
  Public :: get_device_num
  Public :: on_device
  Public :: stream_sync
  Public :: dev_ptr

Contains


  Subroutine gpu_init(gpu_context,ierr,message)
    ! With no value, retain standalone rank/device and per-thread startup.
    ! With a value, use the application's current device and borrow each supplied resource unchanged.
    Implicit None
    Type(xnet_gpu_t), Optional, Intent(in) :: gpu_context
    Integer, Optional, Intent(out) :: ierr
    Character(*), Optional, Intent(out) :: message
    Integer :: init_status
    Character(512) :: init_message
#if defined(XNET_GPU)
    Integer :: device, queue, thread_status
    Integer(C_INT) :: status, cleanup_status
    Type(C_PTR) :: work_stream, handle_stream
    Logical :: stream_known, create_stream
    Character(512) :: thread_message
    Character(128) :: cleanup_message
#if defined(XNET_CUDA)
    Type(C_PTR) :: work_cublas, work_cusolver
    Logical :: create_cublas, create_cusolver
#elif defined(XNET_HIP)
    Type(C_PTR) :: work_hipblas, work_rocblas, work_rocsolver
    Logical :: create_hipblas, create_rocblas
#endif
#if defined(XNET_LA_MAGMA)
    Type(C_PTR) :: work_magma_queue
    Logical :: create_magma_queue
#endif
#endif

    init_status = 0
    init_message = ' '
#if defined(XNET_GPU)
    If ( gpu_initialized ) Then
      init_status = 2
      init_message = 'GPU resources are already initialized'
      GoTo 900
    EndIf
    If ( Present(gpu_context) ) Then
#if defined(XNET_LA_MAGMA)
      init_status = 3
      init_message = 'GPU resource values are not currently supported by the MAGMA backend'
      GoTo 900
#endif
      Call gpu_current_device(device,init_status,init_message)
      If ( init_status /= 0 ) GoTo 900
      If ( gpu_context%device >= 0 .and. gpu_context%device /= device ) Then
        init_status = 1
        init_message = 'Supplied GPU device does not match the current application device'
        GoTo 900
      EndIf
    Else
#if defined(XNET_CUDA)
      status = cudaGetDeviceCount(deviceCount)
#elif defined(XNET_HIP)
      status = hipGetDeviceCount(deviceCount)
#endif
      If ( status /= 0 ) Then
        init_status = 1
        Write(init_message,'(A,I0)') 'Cannot query the GPU count, status ',status
        GoTo 900
      EndIf
      If ( deviceCount <= 0 ) Then
        init_status = 1
        init_message = 'No GPU found'
        GoTo 900
      EndIf
      device = Mod(myid,deviceCount)
#if defined(XNET_CUDA)
      status = cudaSetDevice(Int(device,C_INT))
#elif defined(XNET_HIP)
      status = hipSetDevice(Int(device,C_INT))
#endif
      If ( status /= 0 ) Then
        init_status = 1
        Write(init_message,'(A,I0)') 'Cannot select the standalone GPU device, status ',status
        GoTo 900
      EndIf
#if defined(XNET_LA_MAGMA)
      Call magma_getdevice(magma_device)
      Call magma_init()
#endif
    EndIf

    !$omp parallel if(.not. Present(gpu_context)) default(shared) &
    !$omp private(queue,thread_status,thread_message,status,cleanup_status,cleanup_message) &
    !$omp private(work_stream,handle_stream,stream_known,create_stream) &
#if defined(XNET_CUDA)
    !$omp private(work_cublas,work_cusolver,create_cublas,create_cusolver) &
#elif defined(XNET_HIP)
    !$omp private(work_hipblas,work_rocblas,work_rocsolver,create_hipblas,create_rocblas) &
#endif
#if defined(XNET_LA_MAGMA)
    !$omp private(work_magma_queue,create_magma_queue) &
#endif
    !$omp shared(init_status,init_message)

    thread_status = 0
    thread_message = ' '
    cleanup_message = ' '
    queue = tid
    work_stream = C_NULL_PTR
    stream_known = .false.
    create_stream = .false.
#if defined(XNET_CUDA)
    work_cublas = C_NULL_PTR
    work_cusolver = C_NULL_PTR
    create_cublas = .false.
    create_cusolver = .false.
#elif defined(XNET_HIP)
    work_hipblas = C_NULL_PTR
    work_rocblas = C_NULL_PTR
    work_rocsolver = C_NULL_PTR
    create_hipblas = .false.
    create_rocblas = .false.
#endif
#if defined(XNET_LA_MAGMA)
    work_magma_queue = C_NULL_PTR
    create_magma_queue = .false.
#endif

    If ( gpu_initialized ) Then
      thread_status = 2
      thread_message = 'GPU resources are already initialized on a host thread'
      GoTo 700
    EndIf
    If ( Present(gpu_context) ) Then
      queue = gpu_context%queue
      work_stream = gpu_context%stream
      stream_known = C_Associated(work_stream)
#if defined(XNET_CUDA)
      work_cublas = gpu_context%cublas_handle
      work_cusolver = gpu_context%cusolver_handle
#elif defined(XNET_HIP)
      work_hipblas = gpu_context%hipblas_handle
      work_rocblas = gpu_context%rocblas_handle
      work_rocsolver = gpu_context%rocsolver_handle
#endif
    Else
      ! Vendor device selection is per host thread; all standalone threads use the rank's device.
#if defined(XNET_CUDA)
      status = cudaSetDevice(Int(device,C_INT))
#elif defined(XNET_HIP)
      status = hipSetDevice(Int(device,C_INT))
#endif
      If ( status /= 0 ) Then
        thread_status = 1
        Write(thread_message,'(A,I0)') 'Cannot select the standalone GPU device, status ',status
        GoTo 700
      EndIf
#if defined(XNET_OACC)
      Call acc_set_device_num(Int(device,C_INT),acc_device_default)
#elif defined(XNET_OMP_OL)
      Call omp_set_default_device(device)
#endif
    EndIf

#if defined(XNET_OACC)
    If ( queue < Int(acc_async_sync) ) Then
      thread_status = 1
      thread_message = 'Invalid OpenACC queue'
      GoTo 700
    EndIf
    handle_stream = acc_get_cuda_stream(Int(queue,C_LONG_LONG))
    If ( stream_known ) Then
      If ( .not. (C_Associated(handle_stream,work_stream) .or. &
        & (.not. C_Associated(handle_stream) .and. .not. C_Associated(work_stream))) ) Then
        thread_status = 1
        thread_message = 'Supplied OpenACC queue and GPU stream do not match'
        GoTo 700
      EndIf
    EndIf
    work_stream = handle_stream
    stream_known = .true.
#endif

    ! Validate every supplied handle before allocating any XNet resources.
    ! Without an explicit OpenMP stream, the first supplied handle supplies its stream, even if null.
#if defined(XNET_CUDA)
    If ( C_Associated(work_cublas) ) Then
      status = cublasGetStream_v2(work_cublas,handle_stream)
      If ( status /= 0 ) Then
        thread_status = 1
        Write(thread_message,'(A,I0)') 'Cannot query the supplied cuBLAS stream, status ',status
        GoTo 700
      EndIf
      If ( .not. stream_known ) Then
        work_stream = handle_stream
        stream_known = .true.
      EndIf
      If ( .not. (C_Associated(handle_stream,work_stream) .or. &
        & (.not. C_Associated(handle_stream) .and. .not. C_Associated(work_stream))) ) Then
        thread_status = 1
        thread_message = 'Supplied cuBLAS handle and GPU stream do not match'
        GoTo 700
      EndIf
    EndIf
    If ( C_Associated(work_cusolver) ) Then
      status = cusolverDnGetStream(work_cusolver,handle_stream)
      If ( status /= 0 ) Then
        thread_status = 1
        Write(thread_message,'(A,I0)') 'Cannot query the supplied cuSOLVER stream, status ',status
        GoTo 700
      EndIf
      If ( .not. stream_known ) Then
        work_stream = handle_stream
        stream_known = .true.
      EndIf
      If ( .not. (C_Associated(handle_stream,work_stream) .or. &
        & (.not. C_Associated(handle_stream) .and. .not. C_Associated(work_stream))) ) Then
        thread_status = 1
        thread_message = 'Supplied cuSOLVER handle and GPU stream do not match'
        GoTo 700
      EndIf
    EndIf
#elif defined(XNET_HIP)
    If ( C_Associated(work_hipblas) ) Then
      status = hipblasGetStream(work_hipblas,handle_stream)
      If ( status /= 0 ) Then
        thread_status = 1
        Write(thread_message,'(A,I0)') 'Cannot query the supplied hipBLAS stream, status ',status
        GoTo 700
      EndIf
      If ( .not. stream_known ) Then
        work_stream = handle_stream
        stream_known = .true.
      EndIf
      If ( .not. (C_Associated(handle_stream,work_stream) .or. &
        & (.not. C_Associated(handle_stream) .and. .not. C_Associated(work_stream))) ) Then
        thread_status = 1
        thread_message = 'Supplied hipBLAS handle and GPU stream do not match'
        GoTo 700
      EndIf
    EndIf
    If ( C_Associated(work_rocblas) ) Then
      status = rocblas_get_stream(work_rocblas,handle_stream)
      If ( status /= 0 ) Then
        thread_status = 1
        Write(thread_message,'(A,I0)') 'Cannot query the supplied rocBLAS stream, status ',status
        GoTo 700
      EndIf
      If ( .not. stream_known ) Then
        work_stream = handle_stream
        stream_known = .true.
      EndIf
      If ( .not. (C_Associated(handle_stream,work_stream) .or. &
        & (.not. C_Associated(handle_stream) .and. .not. C_Associated(work_stream))) ) Then
        thread_status = 1
        thread_message = 'Supplied rocBLAS handle and GPU stream do not match'
        GoTo 700
      EndIf
    EndIf
    If ( C_Associated(work_rocsolver) ) Then
      status = rocblas_get_stream(work_rocsolver,handle_stream)
      If ( status /= 0 ) Then
        thread_status = 1
        Write(thread_message,'(A,I0)') 'Cannot query the supplied rocSOLVER stream, status ',status
        GoTo 700
      EndIf
      If ( .not. stream_known ) Then
        work_stream = handle_stream
        stream_known = .true.
      EndIf
      If ( .not. (C_Associated(handle_stream,work_stream) .or. &
        & (.not. C_Associated(handle_stream) .and. .not. C_Associated(work_stream))) ) Then
        thread_status = 1
        thread_message = 'Supplied rocSOLVER handle and GPU stream do not match'
        GoTo 700
      EndIf
    EndIf
#endif

    If ( .not. stream_known ) Then
#if defined(XNET_CUDA)
      status = cudaStreamCreate(work_stream)
#elif defined(XNET_HIP)
      status = hipStreamCreate(work_stream)
#endif
      If ( status /= 0 ) Then
        thread_status = 1
        Write(thread_message,'(A,I0)') 'Cannot create the XNet GPU stream, status ',status
        GoTo 700
      EndIf
      create_stream = .true.
    EndIf

#if defined(XNET_CUDA)
    If ( .not. C_Associated(work_cublas) ) Then
      status = cublasCreate_v2(work_cublas)
      If ( status /= 0 ) Then
        thread_status = 1
        Write(thread_message,'(A,I0)') 'Cannot create the XNet cuBLAS handle, status ',status
        GoTo 700
      EndIf
      create_cublas = .true.
      status = cublasSetStream_v2(work_cublas,work_stream)
      If ( status /= 0 ) Then
        thread_status = 1
        Write(thread_message,'(A,I0)') 'Cannot associate the XNet cuBLAS stream, status ',status
        GoTo 700
      EndIf
    EndIf
    If ( .not. C_Associated(work_cusolver) ) Then
      status = cusolverDnCreate(work_cusolver)
      If ( status /= 0 ) Then
        thread_status = 1
        Write(thread_message,'(A,I0)') 'Cannot create the XNet cuSOLVER handle, status ',status
        GoTo 700
      EndIf
      create_cusolver = .true.
      status = cusolverDnSetStream(work_cusolver,work_stream)
      If ( status /= 0 ) Then
        thread_status = 1
        Write(thread_message,'(A,I0)') 'Cannot associate the XNet cuSOLVER stream, status ',status
        GoTo 700
      EndIf
    EndIf
#elif defined(XNET_HIP)
    If ( .not. C_Associated(work_hipblas) ) Then
      status = hipblasCreate(work_hipblas)
      If ( status /= 0 ) Then
        thread_status = 1
        Write(thread_message,'(A,I0)') 'Cannot create the XNet hipBLAS handle, status ',status
        GoTo 700
      EndIf
      create_hipblas = .true.
      status = hipblasSetStream(work_hipblas,work_stream)
      If ( status /= 0 ) Then
        thread_status = 1
        Write(thread_message,'(A,I0)') 'Cannot associate the XNet hipBLAS stream, status ',status
        GoTo 700
      EndIf
    EndIf
    If ( .not. C_Associated(work_rocblas) ) Then
      status = rocblas_create_handle(work_rocblas)
      If ( status /= 0 ) Then
        thread_status = 1
        Write(thread_message,'(A,I0)') 'Cannot create the XNet rocBLAS handle, status ',status
        GoTo 700
      EndIf
      create_rocblas = .true.
      status = rocblas_set_stream(work_rocblas,work_stream)
      If ( status /= 0 ) Then
        thread_status = 1
        Write(thread_message,'(A,I0)') 'Cannot associate the XNet rocBLAS stream, status ',status
        GoTo 700
      EndIf
    EndIf
    ! rocSOLVER accepts a rocBLAS handle; the default alias has no independent allocation or destruction.
    If ( .not. C_Associated(work_rocsolver) ) work_rocsolver = work_rocblas
#endif

#if defined(XNET_LA_MAGMA)
    Call magma_queue_create_from_cuda(Int(device,C_INT),work_stream,work_cublas,C_NULL_PTR,work_magma_queue)
    If ( .not. C_Associated(work_magma_queue) ) Then
      thread_status = 1
      thread_message = 'Cannot create the XNet MAGMA queue'
      GoTo 700
    EndIf
    create_magma_queue = .true.
#endif

700 Continue
    If ( thread_status /= 0 ) Then
      !$omp critical(xnet_gpu_init_status)
      If ( init_status == 0 ) Then
        init_status = thread_status
        init_message = thread_message
      EndIf
      !$omp end critical(xnet_gpu_init_status)
    EndIf
    !$omp barrier

    If ( init_status == 0 ) Then
#if defined(XNET_CUDA)
      cublas_handle = work_cublas
      cusolver_handle = work_cusolver
      cuda_stream = work_stream
      stream => cuda_stream
      owns_cublas = create_cublas
      owns_cusolver = create_cusolver
#elif defined(XNET_HIP)
      hipblas_handle = work_hipblas
      rocblas_handle = work_rocblas
      rocsolver_handle = work_rocsolver
      hip_stream = work_stream
      stream => hip_stream
      owns_hipblas = create_hipblas
      owns_rocblas = create_rocblas
#endif
#if defined(XNET_OACC)
      If ( .not. Present(gpu_context) ) Then
        acc_queue = Int(queue,C_LONG_LONG)
        Call acc_set_cuda_stream(Int(acc_async_sync,C_LONG_LONG),work_stream)
      EndIf
#endif
#if defined(XNET_LA_MAGMA)
      magma_queue = work_magma_queue
      owns_magma_queue = create_magma_queue
#endif
      gpu_queue = queue
      active_device = device
      owns_stream = create_stream
      gpu_initialized = .true.
    Else
      ! Release only allocations made by this attempt. Caller resources were never rebound.
#if defined(XNET_LA_MAGMA)
      If ( create_magma_queue ) Call magma_queue_destroy(work_magma_queue)
#endif
#if defined(XNET_CUDA)
      If ( create_cusolver ) Then
        cleanup_status = cusolverDnDestroy(work_cusolver)
        If ( cleanup_status /= 0 ) Write(cleanup_message,'(A,I0)') 'cuSOLVER cleanup status ',cleanup_status
      EndIf
      If ( create_cublas ) Then
        cleanup_status = cublasDestroy_v2(work_cublas)
        If ( cleanup_status /= 0 .and. Len_Trim(cleanup_message) == 0 ) &
          & Write(cleanup_message,'(A,I0)') 'cuBLAS cleanup status ',cleanup_status
      EndIf
#elif defined(XNET_HIP)
      If ( create_rocblas ) Then
        cleanup_status = rocblas_destroy_handle(work_rocblas)
        If ( cleanup_status /= 0 ) Write(cleanup_message,'(A,I0)') 'rocBLAS cleanup status ',cleanup_status
      EndIf
      If ( create_hipblas ) Then
        cleanup_status = hipblasDestroy(work_hipblas)
        If ( cleanup_status /= 0 .and. Len_Trim(cleanup_message) == 0 ) &
          & Write(cleanup_message,'(A,I0)') 'hipBLAS cleanup status ',cleanup_status
      EndIf
#endif
      If ( create_stream ) Then
#if defined(XNET_CUDA)
        cleanup_status = cudaStreamDestroy(work_stream)
#elif defined(XNET_HIP)
        cleanup_status = hipStreamDestroy(work_stream)
#endif
        If ( cleanup_status /= 0 .and. Len_Trim(cleanup_message) == 0 ) &
          & Write(cleanup_message,'(A,I0)') 'GPU stream cleanup status ',cleanup_status
      EndIf
      If ( Len_Trim(cleanup_message) > 0 ) Then
        !$omp critical(xnet_gpu_init_status)
        init_message = Trim(init_message)//'; '//Trim(cleanup_message)
        !$omp end critical(xnet_gpu_init_status)
      EndIf
    EndIf
    !$omp end parallel
    If ( init_status == 0 ) mydevice = device
#else
    If ( Present(gpu_context) ) Then
      init_status = 3
      init_message = 'GPU resources require a GPU-enabled build'
    Else
      mydevice = -1
      deviceCount = 0
      !$omp parallel default(shared)
      gpu_queue = tid
      !$omp end parallel
    EndIf
#endif

900 Continue
    If ( Present(ierr) ) ierr = init_status
    If ( Present(message) ) message = init_message
    If ( init_status /= 0 .and. .not. Present(ierr) ) Call xnet_terminate(Trim(init_message),init_status)
    Return
  End Subroutine gpu_init


  Subroutine gpu_current_device(device,ierr,message)
    ! Check both runtimes without selecting a device in either runtime.
    Implicit None
    Integer, Intent(out) :: device, ierr
    Character(*), Intent(out) :: message
#if defined(XNET_CUDA) || defined(XNET_HIP)
    Integer(C_INT) :: current_device, status
#endif

    device = -1
    ierr = 1
    message = ' '
#if defined(XNET_CUDA)
    status = cudaGetDevice(current_device)
#elif defined(XNET_HIP)
    status = hipGetDevice(current_device)
#else
    ierr = 3
    message = 'GPU calls require a CUDA or HIP runtime'
    Return
#endif
#if defined(XNET_CUDA) || defined(XNET_HIP)
    If ( status /= 0 ) Then
      Write(message,'(A,I0)') 'Cannot query the current GPU device, status ',status
      Return
    EndIf
    device = current_device
#if defined(XNET_OACC) || defined(XNET_OMP_OL)
    If ( get_device_num() /= device ) Then
      message = 'GPU runtime and directive runtime select different devices'
      Return
    EndIf
#endif
    ierr = 0
#endif
    Return
  End Subroutine gpu_current_device


  Subroutine gpu_check_device(ierr,message)
    Implicit None
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message
    Integer :: device

    ierr = 2
    message = ' '
    If ( .not. gpu_initialized ) Then
      message = 'Initialize GPU resources before using them'
      Return
    EndIf
    Call gpu_current_device(device,ierr,message)
    If ( ierr /= 0 ) Return
    If ( device /= active_device ) Then
      ierr = 1
      message = 'The GPU device changed while XNet was initialized'
    EndIf
    Return
  End Subroutine gpu_check_device


  Subroutine gpu_finalize(ierr,message)
    ! Module mappings and arrays must be released before this resource cleanup.
    Implicit None
    Integer, Optional, Intent(out) :: ierr
    Character(*), Optional, Intent(out) :: message
    Integer :: finalize_status
    Character(512) :: finalize_message
#if defined(XNET_GPU)
    Integer :: thread_status
    Integer(C_INT) :: status
    Character(512) :: thread_message
    Logical :: remaining_active
#endif

    finalize_status = 0
    finalize_message = ' '
#if defined(XNET_GPU)
    remaining_active = .false.
    !$omp parallel default(shared) private(thread_status,status,thread_message)
    thread_status = 0
    thread_message = ' '
    If ( .not. gpu_initialized ) GoTo 800
    Call gpu_check_device(thread_status,thread_message)
    If ( thread_status /= 0 ) GoTo 800
#if defined(XNET_CUDA)
    status = cudaStreamSynchronize(stream)
#elif defined(XNET_HIP)
    status = hipStreamSynchronize(stream)
#endif
    If ( status /= 0 ) Then
      thread_status = 1
      Write(thread_message,'(A,I0)') 'Cannot synchronize the XNet GPU stream, status ',status
      GoTo 800
    EndIf
#if defined(XNET_LA_MAGMA)
    If ( owns_magma_queue ) Call magma_queue_destroy(magma_queue)
    magma_queue = C_NULL_PTR
    owns_magma_queue = .false.
#endif
#if defined(XNET_CUDA)
    If ( owns_cusolver ) Then
      status = cusolverDnDestroy(cusolver_handle)
      If ( status /= 0 ) Then
        thread_status = 1
        Write(thread_message,'(A,I0)') 'Cannot destroy the XNet cuSOLVER handle, status ',status
      EndIf
    EndIf
    If ( owns_cublas ) Then
      status = cublasDestroy_v2(cublas_handle)
      If ( status /= 0 .and. thread_status == 0 ) Then
        thread_status = 1
        Write(thread_message,'(A,I0)') 'Cannot destroy the XNet cuBLAS handle, status ',status
      EndIf
    EndIf
    cusolver_handle = C_NULL_PTR
    cublas_handle = C_NULL_PTR
    owns_cusolver = .false.
    owns_cublas = .false.
#elif defined(XNET_HIP)
    If ( owns_rocblas ) Then
      status = rocblas_destroy_handle(rocblas_handle)
      If ( status /= 0 ) Then
        thread_status = 1
        Write(thread_message,'(A,I0)') 'Cannot destroy the XNet rocBLAS handle, status ',status
      EndIf
    EndIf
    If ( owns_hipblas ) Then
      status = hipblasDestroy(hipblas_handle)
      If ( status /= 0 .and. thread_status == 0 ) Then
        thread_status = 1
        Write(thread_message,'(A,I0)') 'Cannot destroy the XNet hipBLAS handle, status ',status
      EndIf
    EndIf
    rocblas_handle = C_NULL_PTR
    rocsolver_handle = C_NULL_PTR
    hipblas_handle = C_NULL_PTR
    owns_rocblas = .false.
    owns_hipblas = .false.
#endif
    If ( owns_stream ) Then
#if defined(XNET_CUDA)
      status = cudaStreamDestroy(stream)
#elif defined(XNET_HIP)
      status = hipStreamDestroy(stream)
#endif
      If ( status /= 0 .and. thread_status == 0 ) Then
        thread_status = 1
        Write(thread_message,'(A,I0)') 'Cannot destroy the XNet GPU stream, status ',status
      EndIf
    EndIf
#if defined(XNET_CUDA)
    cuda_stream = C_NULL_PTR
#elif defined(XNET_HIP)
    hip_stream = C_NULL_PTR
#endif
    Nullify(stream)
    owns_stream = .false.
    gpu_queue = 1
    active_device = -1
    gpu_initialized = .false.

800 Continue
    !$omp critical(xnet_gpu_finalize_status)
    If ( thread_status /= 0 .and. finalize_status == 0 ) Then
      finalize_status = thread_status
      finalize_message = thread_message
    EndIf
    If ( gpu_initialized ) remaining_active = .true.
    !$omp end critical(xnet_gpu_finalize_status)
    !$omp end parallel
    If ( .not. remaining_active ) mydevice = -1
#endif
    If ( Present(ierr) ) ierr = finalize_status
    If ( Present(message) ) message = finalize_message
    If ( finalize_status /= 0 .and. .not. Present(ierr) ) Call xnet_terminate(Trim(finalize_message),finalize_status)
    Return
  End Subroutine gpu_finalize


  Logical Function device_is_present( hostptr, device, bytes )
    Type(C_PTR), Intent(in) :: hostptr
    Integer, Intent(in) :: device
    Integer(C_SIZE_T), Intent(in) :: bytes
#if defined(XNET_OMP_OL)
    device_is_present = ( omp_target_is_present( hostptr, device ) > 0 )
#elif defined(XNET_OACC)
    device_is_present = ( acc_is_present( hostptr, bytes ) > 0 )
#else
    device_is_present = .false.
#endif
    Return
  End Function device_is_present


  Integer Function get_device_num()
#if defined(XNET_OMP_OL)
    get_device_num = omp_get_default_device()
#elif defined(XNET_OACC)
    get_device_num = acc_get_device_num( acc_device_default )
#else
    get_device_num = -1
#endif
    Return
  End Function get_device_num


  Logical Function on_device()
    !XDIR XROUTINE_SEQ
#if defined(XNET_OMP_OL)
    on_device = ( .not. omp_is_initial_device() )
#elif defined(XNET_OACC)
    on_device = ( .not. acc_on_device( acc_device_host ) )
#else
    on_device = .false.
#endif
    Return
  End Function on_device


  Subroutine stream_sync( stream, ierr_out )
    Type(C_PTR), Intent(in) :: stream
    Integer, Optional, Intent(out) :: ierr_out
    Integer :: ierr
    ierr = 0
#if defined(XNET_CUDA)
    ierr = cudaStreamSynchronize( stream )
#elif defined(XNET_HIP)
    ierr = hipStreamSynchronize( stream )
    If ( .not. Present(ierr_out) ) Call hipCheck( ierr )
#endif
    If ( Present(ierr_out) ) ierr_out = ierr
    Return
  End Subroutine stream_sync


  Type(C_PTR) Function dev_ptr_int( a )
    Integer, Target, Intent(in) :: a
#if defined(XNET_OMP_OL)
    dev_ptr_int = omp_get_mapped_ptr( C_LOC( a ), omp_get_default_device() )
#else
    !XDIR XHOST_DATA &
    !XDIR XDEV_PTR(a)
    dev_ptr_int = C_LOC( a )
    !XDIR XEND_HOST_DATA
#endif
  End Function dev_ptr_int

  Type(C_PTR) Function dev_ptr_dp( a )
    Real(dp), Target, Intent(in) :: a
#if defined(XNET_OMP_OL)
    dev_ptr_dp = omp_get_mapped_ptr( C_LOC( a ), omp_get_default_device() )
#else
    !XDIR XHOST_DATA &
    !XDIR XDEV_PTR(a)
    dev_ptr_dp = C_LOC( a )
    !XDIR XEND_HOST_DATA
#endif
  End Function dev_ptr_dp

  Type(C_PTR) Function dev_ptr_cptr( a )
    Type(C_PTR), Target, Intent(in) :: a
#if defined(XNET_OMP_OL)
    dev_ptr_cptr = omp_get_mapped_ptr( C_LOC( a ), omp_get_default_device() )
#else
    !XDIR XHOST_DATA &
    !XDIR XDEV_PTR(a)
    dev_ptr_cptr = C_LOC( a )
    !XDIR XEND_HOST_DATA
#endif
  End Function dev_ptr_cptr

End Module xnet_gpu
