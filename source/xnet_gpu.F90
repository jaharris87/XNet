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

  Type, Public :: xnet_gpu_resources_t
    Integer :: device = -1
    Type(C_PTR) :: stream = C_NULL_PTR
    Type(C_PTR) :: blas_handle = C_NULL_PTR
    Integer :: queue = 1
  End Type xnet_gpu_resources_t

  ! Embedded calls share the existing dense-solver slots for one non-reentrant instance.
  Logical :: embedded_active = .false., embedded_borrowed = .false., embedded_owns_stream = .false.
  Integer :: embedded_device = -1, saved_device = -1, saved_queue = 1
  Type(C_PTR) :: embedded_blas = C_NULL_PTR, embedded_stream = C_NULL_PTR
  Type(C_PTR) :: saved_blas = C_NULL_PTR, saved_vendor_stream = C_NULL_PTR
  Type(C_PTR), Pointer :: saved_stream => Null()

  Interface dev_ptr
    Module Procedure dev_ptr_int
    Module Procedure dev_ptr_dp
    Module Procedure dev_ptr_cptr
  End Interface

  Public :: gpu_init
  Public :: gpu_finalize
  Public :: gpu_initialize_embedded, gpu_finalize_embedded, gpu_check_embedded_device
  Public :: device_is_present
  Public :: get_device_num
  Public :: on_device
  Public :: stream_sync
  Public :: dev_ptr

Contains


  Subroutine gpu_initialize_embedded(resources,ierr,message)
    ! Use the current application device. Supplied handles and streams belong to the application.
    Implicit None
    Type(xnet_gpu_resources_t), Optional, Intent(in) :: resources
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message
#if defined(XNET_GPU) && (defined(XNET_LA_CUBLAS) || defined(XNET_LA_ROCM))
    Integer :: device, queue
    Integer(C_INT) :: status, cleanup_status
    Type(C_PTR) :: work_blas, work_stream, handle_stream
    Logical :: owns_stream
#endif

    ierr = 2
    message = ' '
    If ( embedded_active ) Then
      message = 'Embedded GPU resources are already initialized'
      Return
    EndIf
#if defined(XNET_GPU) && (defined(XNET_LA_CUBLAS) || defined(XNET_LA_ROCM))
    Call gpu_current_device(device,ierr,message)
    If ( ierr /= 0 ) Return
    ierr = 1
    queue = 1
    work_blas = C_NULL_PTR
    work_stream = C_NULL_PTR
    owns_stream = .false.
    If ( Present(resources) ) Then
      If ( resources%device /= device ) Then
        message = 'Supplied GPU device does not match the current application device'
        Return
      EndIf
      If ( .not. C_Associated(resources%blas_handle) ) Then
        message = 'Supply the dense BLAS handle with borrowed GPU resources'
        Return
      EndIf
      queue = resources%queue
      work_blas = resources%blas_handle
      work_stream = resources%stream
#if defined(XNET_CUDA)
      status = cublasGetStream_v2(work_blas,handle_stream)
#elif defined(XNET_HIP)
      status = hipblasGetStream(work_blas,handle_stream)
#endif
      If ( status /= 0 ) Then
        Write(message,'(A,I0)') 'Cannot query the supplied BLAS stream, status ',status
        Return
      EndIf
      If ( .not. (C_Associated(handle_stream,work_stream) .or. &
        & (.not. C_Associated(handle_stream) .and. .not. C_Associated(work_stream))) ) Then
        message = 'Supplied BLAS handle and GPU stream do not match'
        Return
      EndIf
    EndIf

#if defined(XNET_OACC)
    If ( queue < Int(acc_async_sync) ) Then
      message = 'Invalid OpenACC queue'
      Return
    EndIf
    handle_stream = acc_get_cuda_stream(Int(queue,C_LONG_LONG))
    If ( Present(resources) ) Then
      If ( .not. (C_Associated(handle_stream,work_stream) .or. &
        & (.not. C_Associated(handle_stream) .and. .not. C_Associated(work_stream))) ) Then
        message = 'Supplied OpenACC queue and GPU stream do not match'
        Return
      EndIf
    Else
      work_stream = handle_stream
    EndIf
#else
    If ( .not. Present(resources) ) Then
#if defined(XNET_CUDA)
      status = cudaStreamCreate(work_stream)
#elif defined(XNET_HIP)
      status = hipStreamCreate(work_stream)
#endif
      If ( status /= 0 ) Then
        Write(message,'(A,I0)') 'Cannot create the XNet GPU stream, status ',status
        Return
      EndIf
      owns_stream = .true.
    EndIf
#endif

    If ( .not. Present(resources) ) Then
#if defined(XNET_CUDA)
      status = cublasCreate_v2(work_blas)
#elif defined(XNET_HIP)
      status = hipblasCreate(work_blas)
#endif
      If ( status /= 0 ) Then
        Write(message,'(A,I0)') 'Cannot create the XNet BLAS handle, status ',status
        GoTo 900
      EndIf
#if defined(XNET_CUDA)
      status = cublasSetStream_v2(work_blas,work_stream)
#elif defined(XNET_HIP)
      status = hipblasSetStream(work_blas,work_stream)
#endif
      If ( status /= 0 ) Then
        Write(message,'(A,I0)') 'Cannot associate the XNet BLAS stream, status ',status
#if defined(XNET_CUDA)
        cleanup_status = cublasDestroy_v2(work_blas)
#elif defined(XNET_HIP)
        cleanup_status = hipblasDestroy(work_blas)
#endif
        GoTo 900
      EndIf
    EndIf

    saved_device = mydevice
    saved_queue = gpu_queue
    If ( Associated(stream) ) saved_stream => stream
#if defined(XNET_CUDA)
    saved_blas = cublas_handle
    saved_vendor_stream = cuda_stream
    cublas_handle = work_blas
    cuda_stream = work_stream
    stream => cuda_stream
#elif defined(XNET_HIP)
    saved_blas = hipblas_handle
    saved_vendor_stream = hip_stream
    hipblas_handle = work_blas
    hip_stream = work_stream
    stream => hip_stream
#endif
    mydevice = device
    gpu_queue = queue
    embedded_device = device
    embedded_stream = work_stream
    embedded_blas = work_blas
    embedded_borrowed = Present(resources)
    embedded_owns_stream = owns_stream
    embedded_active = .true.
    ierr = 0
    Return

900 Continue
    If ( owns_stream ) Then
#if defined(XNET_CUDA)
      cleanup_status = cudaStreamDestroy(work_stream)
#elif defined(XNET_HIP)
      cleanup_status = hipStreamDestroy(work_stream)
#endif
    EndIf
#else
    ierr = 3
    message = 'Embedded GPU calls require the cuBLAS or ROCm dense backend'
#endif
    Return
  End Subroutine gpu_initialize_embedded


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
    message = 'Embedded GPU calls require a CUDA or HIP runtime'
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


  Subroutine gpu_check_embedded_device(ierr,message)
    Implicit None
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message
    Integer :: device

    ierr = 2
    message = ' '
    If ( .not. embedded_active ) Then
      message = 'Initialize embedded GPU resources before using them'
      Return
    EndIf
    Call gpu_current_device(device,ierr,message)
    If ( ierr /= 0 ) Return
    If ( device /= embedded_device ) Then
      ierr = 1
      message = 'The application GPU device changed while XNet was initialized'
    EndIf
    Return
  End Subroutine gpu_check_embedded_device


  Subroutine gpu_finalize_embedded(ierr,message)
    Implicit None
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message
#if defined(XNET_GPU) && (defined(XNET_LA_CUBLAS) || defined(XNET_LA_ROCM))
    Integer(C_INT) :: status
#endif

    ierr = 0
    message = ' '
    If ( .not. embedded_active ) Return
    Call gpu_check_embedded_device(ierr,message)
    If ( ierr /= 0 ) Return
#if defined(XNET_GPU) && (defined(XNET_LA_CUBLAS) || defined(XNET_LA_ROCM))
#if defined(XNET_CUDA)
    status = cudaStreamSynchronize(embedded_stream)
#elif defined(XNET_HIP)
    status = hipStreamSynchronize(embedded_stream)
#endif
    If ( status /= 0 ) Then
      ierr = 1
      Write(message,'(A,I0)') 'Cannot synchronize the XNet GPU stream, status ',status
      Return
    EndIf
    If ( .not. embedded_borrowed ) Then
#if defined(XNET_CUDA)
      status = cublasDestroy_v2(embedded_blas)
#elif defined(XNET_HIP)
      status = hipblasDestroy(embedded_blas)
#endif
      If ( status /= 0 ) Then
        ierr = 1
        Write(message,'(A,I0)') 'Cannot destroy the XNet BLAS handle, status ',status
      EndIf
    EndIf
    If ( embedded_owns_stream ) Then
#if defined(XNET_CUDA)
      status = cudaStreamDestroy(embedded_stream)
#elif defined(XNET_HIP)
      status = hipStreamDestroy(embedded_stream)
#endif
      If ( status /= 0 .and. ierr == 0 ) Then
        ierr = 1
        Write(message,'(A,I0)') 'Cannot destroy the XNet GPU stream, status ',status
      EndIf
    EndIf
#if defined(XNET_CUDA)
    cublas_handle = saved_blas
    cuda_stream = saved_vendor_stream
#elif defined(XNET_HIP)
    hipblas_handle = saved_blas
    hip_stream = saved_vendor_stream
#endif
    stream => saved_stream
    Nullify(saved_stream)
    mydevice = saved_device
    gpu_queue = saved_queue
    embedded_active = .false.
    embedded_borrowed = .false.
    embedded_owns_stream = .false.
    embedded_device = -1
    embedded_blas = C_NULL_PTR
    embedded_stream = C_NULL_PTR
#endif
    Return
  End Subroutine gpu_finalize_embedded


  Subroutine gpu_init
    Implicit None

    ! Local variables
    Integer :: ierr

    ! Initialize GPU
#if defined(XNET_GPU)
#if defined(XNET_CUDA)
    ierr = cudaGetDeviceCount( deviceCount )
    If ( ierr /= cudaSuccess ) Write(lun_stdout,*) "cudaGetDeviceCount, ierr", ierr
#elif defined(XNET_HIP)
    Call hipCheck( hipGetDeviceCount( deviceCount ) )
#elif defined(XNET_OMP_OL)
    deviceCount = omp_get_num_devices()
#endif
    If ( deviceCount > 0 ) Then
      mydevice = mod(myid,deviceCount)
    Else
      Call xnet_terminate('No GPU found',deviceCount)
    EndIf
#if defined(XNET_CUDA)
    ierr = cudaSetDevice( mydevice )
#elif defined(XNET_HIP)
    Call hipCheck( hipSetDevice( mydevice ) )
#elif defined(XNET_OMP_OL)
    Call omp_set_default_device( mydevice )
#endif
#else
    mydevice = -1
    deviceCount = 0
#endif

    !$omp parallel default(shared) private(ierr)

    gpu_queue = tid

    ! Setup linear algebra library handles
#if defined(XNET_CUDA)
    ierr = cublasCreate_v2( cublas_handle )
    !ierr = cusparseCreate( cusparse_handle )
    ierr = cusolverDnCreate( cusolver_handle )
    stream => cuda_stream
#elif defined(XNET_HIP)
    Call hipblasCheck( hipblasCreate( hipblas_handle ) )
    !Call hipsparseCheck( hipsparseCreate( hipsparse_handle ) )
    Call rocblasCheck( rocblas_create_handle( rocblas_handle ) )
    rocsolver_handle = rocblas_handle
    !rocsparse_handle = rocblas_handle
    stream => hip_stream
#endif

    ! Create a stream and associate with linear algebra libraries
#if defined(XNET_OACC)
    !stream = acc_get_cuda_stream( INT( acc_async_noval, KIND=C_LONG_LONG ) )
    acc_queue = tid
    stream = acc_get_cuda_stream(acc_queue)
    Call acc_set_cuda_stream( INT( acc_async_sync, KIND=C_LONG_LONG ), stream )
    !ierr = acc_set_cuda_stream(acc_queue, stream)
#elif defined(XNET_CUDA)
    ierr = cudaStreamCreate( stream )
#elif defined(XNET_HIP)
    Call hipCheck( hipStreamCreate( stream ) )
#endif

#if defined(XNET_CUDA)
    ierr = cublasSetStream_v2( cublas_handle, stream )
    !ierr = cusparseSetStream( cusparse_handle, stream )
    ierr = cusolverDnSetStream( cusolver_handle, stream )
    !ierr = cublasSetSmCountTarget( cublas_handle, 54 )
#elif defined(XNET_HIP)
    Call hipblasCheck( hipblasSetStream( hipblas_handle, stream ) )
    !Call hipsparseCheck( hipsparseSetStream( hipsparse_handle, stream ) )
    Call rocblasCheck( rocblas_set_stream( rocblas_handle, stream ) )
#endif

    !$omp end parallel

#if defined(XNET_LA_MAGMA)
    Call magma_get_device( magma_device )
    Call magma_init()
    !$omp parallel default(shared) private(ierr)
#if defined(XNET_CUDA)
    Call magma_queue_create_from_cuda &
           ( magma_device, stream, cublas_handle, C_NULL_PTR, magma_queue )
#elif defined(XNET_HIP)
    Call magma_queue_create_from_hip &
           ( magma_device, stream, hipblas_handle, C_NULL_PTR, magma_queue )
#endif
    !$omp end parallel
#endif

    Return
  End Subroutine gpu_init


  Subroutine gpu_finalize
    Implicit None

    ! Local variables
    Integer :: ierr

#if defined(XNET_GPU)
    !$omp parallel default(shared) private(ierr)
#if defined(XNET_LA_MAGMA)
    Call magma_queue_destroy( magma_queue )
#endif
#if defined(XNET_CUDA)
    ierr = cudaStreamDestroy( stream )
    ierr = cublasDestroy_v2( cublas_handle )
    ierr = cusolverDnDestroy( cusolver_handle )
#elif defined(XNET_HIP)
    Call hipCheck( hipStreamDestroy( stream ) )
    Call hipblasCheck( hipblasDestroy( hipblas_handle ) )
    Call rocblasCheck( rocblas_destroy_handle( rocsolver_handle ) )
#endif
    !$omp end parallel
#endif

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
