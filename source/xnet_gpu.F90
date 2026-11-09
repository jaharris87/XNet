!***************************************************************************************************
! xnet_gpu.F90
! Accelerator device, stream, and vendor library handle management for XNet.
!
! Supports both standalone rank-based device initialization and application-embedded resource
! borrowing/creation with independent per-handle ownership tracking and retryable teardown.
! Public lifecycle routines come first, then directive-runtime helpers and private resource setup.
! Each host thread installs named vendor handles; ownership flags describe only resources XNet
! created. A failed destructor leaves its handle and dependent stream available for a later retry.
!***************************************************************************************************

#include "xnet_macros.fh"

Module xnet_gpu
  Use, Intrinsic :: iso_c_binding, Only: c_associated, C_INT, c_loc, C_LONG_LONG, C_NULL_PTR, &
    & C_PTR, C_SIZE_T
  Use xnet_controls, Only: gpu_queue, lun_stdout, myid, tid
  Use xnet_types, Only: dp
  Use xnet_util, Only: xnet_terminate

#if defined(XNET_CUDA)
  Use xnet_cudaf, Only: &
    & cuda_stream=>stream, &
    & cudaGetDeviceCount, &
    & cudaGetDevice, &
    & cudaSetDevice, &
    & cudaStreamCreate, &
    & cudaStreamDestroy, &
    & cudaStreamSynchronize, &
    & cudaDeviceSynchronize, &
    & cudaSuccess
  Use xnet_cublasf, Only: &
    & cublas_handle, &
    & cublasCreate_v2, &
    & cublasDestroy_v2, &
    & cublasGetStream_v2, &
    & cublasSetStream_v2, &
    & cublasSetSmCountTarget
  Use xnet_cusolverf, Only: &
    & cusolver_handle, &
    & cusolverDnCreate, &
    & cusolverDnDestroy, &
    & cusolverDnGetStream, &
    & cusolverDnSetStream
#elif defined(XNET_HIP)
  Use xnet_hipf, Only: &
    & hip_stream=>stream, &
    & hipGetDeviceCount, &
    & hipGetDevice, &
    & hipSetDevice, &
    & hipStreamCreate, &
    & hipStreamDestroy, &
    & hipStreamSynchronize, &
    & hipCheck, &
    & hipblasCheck, &
    & hipsparseCheck, &
    & rocblasCheck, &
    & rocsparseCheck, &
    & rocsolverCheck
  Use xnet_rocblasf, Only: &
    & rocblas_handle, &
    & rocblas_create_handle, &
    & rocblas_destroy_handle, &
    & rocblas_get_stream, &
    & rocblas_set_stream, &
    & rocblas_set_pointer_mode, &
    & rocblas_pointer_mode_device
  Use xnet_rocsolverf, Only: &
    & rocsolver_handle
  Use xnet_hipblasf, Only: &
    & hipblas_handle, &
    & hipblasCreate, &
    & hipblasDestroy, &
    & hipblasGetStream, &
    & hipblasSetStream
#endif

#if defined(XNET_LA_MAGMA)
  Use xnet_magmaf, Only: &
    & magma_device, &
    & magma_queue, &
    & magma_getdevice, &
    & magma_init, &
    & magma_queue_destroy, &
#if defined(XNET_CUDA)
    & magma_queue_create_from_cuda
#elif defined(XNET_HIP)
    & magma_queue_create_from_hip
#endif
#endif

#if defined(XNET_OMP_OL)
  Use xnet_openmpf, Only: &
    & omp_set_default_device, &
    & omp_get_default_device, &
    & omp_is_initial_device, &
    & omp_target_is_present
  Use omp_lib, Only: &
    & omp_get_num_devices, &
    & omp_get_mapped_ptr
#endif

#if defined(XNET_OACC)
  Use xnet_openaccf, Only: &
    & acc_set_device_num, &
    & acc_get_device_num, &
    & acc_on_device, &
    & acc_is_present, &
    & acc_get_cuda_stream, &
    & acc_set_cuda_stream, &
    & acc_get_default_async, &
    & acc_set_default_async, &
    & acc_device_host, &
    & acc_device_default, &
    & acc_async_sync, &
    & acc_async_noval, &
    & acc_queue
#endif

  Implicit None
  Private

  !-------------------------------------------------------------------------------------------------
  ! Public module state and types
  !-------------------------------------------------------------------------------------------------
  Integer(C_INT), Public :: deviceCount = 0
  Integer, Public :: mydevice = -1            ! Nonnegative while any thread still holds resources
  Type(C_PTR), Pointer, Public :: stream => null()

  ! Application-supplied GPU context for borrowing or creating streams and vendor handles.
  ! Fields unused by the active backend are ignored and never modified.
  Type, Public :: xnet_gpu_t
    Integer :: device = -1                     ! Accept the current application device by default
    Type(C_PTR) :: stream = C_NULL_PTR
    Integer :: queue = 1                        ! OpenACC async ID; unused for OpenMP target offload
    Type(C_PTR) :: cublas_handle = C_NULL_PTR
    Type(C_PTR) :: cusolver_handle = C_NULL_PTR
    Type(C_PTR) :: cusparse_handle = C_NULL_PTR ! Reserved; unused by the current implementation
    Type(C_PTR) :: hipblas_handle = C_NULL_PTR
    Type(C_PTR) :: rocblas_handle = C_NULL_PTR
    Type(C_PTR) :: rocsolver_handle = C_NULL_PTR ! Optional rocBLAS handle; shares rocblas_handle if null
    Type(C_PTR) :: rocsparse_handle = C_NULL_PTR ! Reserved; unused by the current implementation
    Type(C_PTR) :: magma_queue = C_NULL_PTR     ! Reserved; external MAGMA queues are unsupported
  End Type xnet_gpu_t

  !-------------------------------------------------------------------------------------------------
  ! Per-thread GPU lifecycle and ownership state
  !-------------------------------------------------------------------------------------------------
  Logical :: gpu_initialized = .false.
  Integer :: active_device = -1
  Logical :: owns_stream = .false.
  ! OpenACC owns queue streams; XNet must never destroy those streams.
#ifdef XNET_OMP
  !$omp threadprivate(stream,gpu_initialized,active_device,owns_stream)
#endif

#if defined(XNET_CUDA)
  Logical :: owns_cublas = .false.
  Logical :: owns_cusolver = .false.
#ifdef XNET_OMP
  !$omp threadprivate(owns_cublas,owns_cusolver)
#endif
#elif defined(XNET_HIP)
  Logical :: owns_hipblas = .false.
  Logical :: owns_rocblas = .false.
#ifdef XNET_OMP
  !$omp threadprivate(owns_hipblas,owns_rocblas)
#endif
#endif

#if defined(XNET_LA_MAGMA)
  Logical :: owns_magma_queue = .false.
#ifdef XNET_OMP
  !$omp threadprivate(owns_magma_queue)
#endif
#endif

  !-------------------------------------------------------------------------------------------------
  ! Public procedures and generic interfaces
  !-------------------------------------------------------------------------------------------------
  Interface dev_ptr
    Module Procedure dev_ptr_int
    Module Procedure dev_ptr_dp
    Module Procedure dev_ptr_cptr
  End Interface dev_ptr

  Public :: gpu_init
  Public :: gpu_finalize
  Public :: gpu_check_device
  Public :: device_is_present
  Public :: get_device_num
  Public :: on_device
  Public :: stream_sync
  Public :: dev_ptr

Contains

  !=================================================================================================
  ! Public Lifecycle and Device Verification Routines
  !=================================================================================================

  Subroutine gpu_init(gpu_context,ierr,message)
    !-----------------------------------------------------------------------------------------------
    ! Initialize GPU execution.
    ! - When gpu_context is omitted (standalone mode): selects a device per rank (myid mod count)
    !   and creates per-thread streams and vendor handles.
    ! - When gpu_context is present (embedded API mode): verifies the active application device,
    !   borrows any supplied stream/handles after checking stream consistency, and creates only the
    !   missing resources required by the active backend.
    ! CPU builds create no GPU resources, ignore gpu_context, and return success.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Optional arguments
    Type(xnet_gpu_t), Optional, Intent(in) :: gpu_context
    Integer, Optional, Intent(out) :: ierr
    Character(*), Optional, Intent(out) :: message

    ! Local variables
    Integer :: init_status
    Character(512) :: init_message
#if defined(XNET_GPU)
    Integer :: device, cleanup_status
    Character(512) :: cleanup_message
#endif

    init_status = 0
    init_message = ' '

#if defined(XNET_GPU)
    If ( gpu_initialized .or. mydevice >= 0 ) Then
      init_status = 2
      init_message = 'GPU resources are already initialized'
      Call report_gpu_status(init_status,init_message,ierr,message)
      Return
    EndIf

    If ( present(gpu_context) ) Then
      Call validate_embedded_device(gpu_context,device,init_status,init_message)
    Else
      Call select_standalone_device(device,init_status,init_message)
    EndIf

    If ( init_status /= 0 ) Then
      Call report_gpu_status(init_status,init_message,ierr,message)
      Return
    EndIf

#ifdef XNET_OMP
    !$omp parallel if(.not. present(gpu_context)) default(shared)
#endif
    Call init_thread_resources(device,gpu_context,init_status,init_message)
#ifdef XNET_OMP
    !$omp end parallel
#endif

    mydevice = device
    If ( init_status /= 0 ) Then
      ! Roll back after the team joins; failed handles retain their stream and ownership.
      Call gpu_finalize(cleanup_status,cleanup_message)
      If ( cleanup_status /= 0 ) init_message = trim(init_message)//'; '//trim(cleanup_message)
    EndIf
#else
    If ( .not. present(gpu_context) ) Then
      mydevice = -1
      deviceCount = 0
#ifdef XNET_OMP
      !$omp parallel default(shared)
#endif
      gpu_queue = tid
#ifdef XNET_OMP
      !$omp end parallel
#endif
    EndIf
#endif

    Call report_gpu_status(init_status,init_message,ierr,message)

    Return
  End Subroutine gpu_init

  Subroutine gpu_finalize(ierr,message)
    !-----------------------------------------------------------------------------------------------
    ! Synchronize the active stream and release XNet-owned GPU handles and streams.
    ! Borrowed application handles and streams are preserved untouched. If any vendor destructor
    ! fails, surviving state remains marked initialized so the caller can retry gpu_finalize.
    ! CPU builds have no GPU resources to release and return success.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Optional arguments
    Integer, Optional, Intent(out) :: ierr
    Character(*), Optional, Intent(out) :: message

    ! Local variables
    Integer :: finalize_status
    Character(512) :: finalize_message
#if defined(XNET_GPU)
    Integer :: thread_status
    Character(512) :: thread_message
    Logical :: remaining_active
#endif

    finalize_status = 0
    finalize_message = ' '

#if defined(XNET_GPU)
    remaining_active = .false.
#ifdef XNET_OMP
    !$omp parallel default(shared) private(thread_status,thread_message)
#endif
    Call finalize_thread_resources(thread_status,thread_message)

    !$omp critical(xnet_gpu_finalize_status)
    If ( thread_status /= 0 .and. finalize_status == 0 ) Then
      finalize_status = thread_status
      finalize_message = thread_message
    EndIf
    If ( gpu_initialized ) remaining_active = .true.
    !$omp end critical(xnet_gpu_finalize_status)
#ifdef XNET_OMP
    !$omp end parallel
#endif
    If ( .not. remaining_active ) mydevice = -1
#endif

    Call report_gpu_status(finalize_status,finalize_message,ierr,message)

    Return
  End Subroutine gpu_finalize

  Subroutine gpu_check_device(ierr,message)
    !-----------------------------------------------------------------------------------------------
    ! Verify that GPU resources are initialized on the calling thread and that both the vendor
    ! runtime and directive runtime still select the device recorded at initialization.
    ! CPU builds have no GPU device state to check and return success.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Output variables
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message

    ! Local variables
    Integer :: device

#if defined(XNET_GPU)
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
#else
    ierr = 0
    message = ' '
#endif

    Return
  End Subroutine gpu_check_device

  !=================================================================================================
  ! Public Device Query and Pointer Helpers
  !=================================================================================================

  Logical Function device_is_present(hostptr,device,bytes)
    !-----------------------------------------------------------------------------------------------
    ! Query the directive runtime for a mapping. OpenACC checks bytes starting at hostptr;
    ! OpenMP checks the base address only. The caller must map the full contiguous array extent.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Input variables
    Type(C_PTR), Intent(in) :: hostptr
    Integer, Intent(in) :: device
    Integer(C_SIZE_T), Intent(in) :: bytes

#if defined(XNET_OMP_OL)
    device_is_present = ( omp_target_is_present(hostptr,device) > 0 )
#elif defined(XNET_OACC)
    device_is_present = ( acc_is_present(hostptr,bytes) > 0 )
#else
    device_is_present = .false.
#endif

    Return
  End Function device_is_present

  Integer Function get_device_num()
    !-----------------------------------------------------------------------------------------------
    ! Query the active device number in the directive runtime (OpenMP offload or OpenACC).
    !-----------------------------------------------------------------------------------------------
    Implicit None

#if defined(XNET_OMP_OL)
    get_device_num = omp_get_default_device()
#elif defined(XNET_OACC)
    get_device_num = acc_get_device_num(acc_device_default)
#else
    get_device_num = -1
#endif

    Return
  End Function get_device_num

  Logical Function on_device()
    !-----------------------------------------------------------------------------------------------
    ! Return .true. when executing on the accelerator device rather than the host CPU.
    !-----------------------------------------------------------------------------------------------
    Implicit None
    !XDIR XROUTINE_SEQ

#if defined(XNET_OMP_OL)
    on_device = ( .not. omp_is_initial_device() )
#elif defined(XNET_OACC)
    on_device = ( .not. acc_on_device(acc_device_host) )
#else
    on_device = .false.
#endif

    Return
  End Function on_device

  Subroutine stream_sync(stream,ierr_out)
    !-----------------------------------------------------------------------------------------------
    ! Synchronize the specified vendor stream. When ierr_out is omitted on HIP, calls hipCheck.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Input variables
    Type(C_PTR), Intent(in) :: stream

    ! Optional output variables
    Integer, Optional, Intent(out) :: ierr_out

    ! Local variables
    Integer :: ierr

    ierr = 0
#if defined(XNET_CUDA)
    ierr = cudaStreamSynchronize(stream)
#elif defined(XNET_HIP)
    ierr = hipStreamSynchronize(stream)
    If ( .not. present(ierr_out) ) Call hipCheck(ierr)
#endif
    If ( present(ierr_out) ) ierr_out = ierr

    Return
  End Subroutine stream_sync

  Type(C_PTR) Function dev_ptr_int(a)
    !-----------------------------------------------------------------------------------------------
    ! Return the mapped device C pointer for an Integer target.
    !-----------------------------------------------------------------------------------------------
    Implicit None
    Integer, Target, Intent(in) :: a

#if defined(XNET_OMP_OL)
    dev_ptr_int = omp_get_mapped_ptr(c_loc(a),omp_get_default_device())
#else
    !XDIR XHOST_DATA &
    !XDIR XDEV_PTR(a)
    dev_ptr_int = c_loc(a)
    !XDIR XEND_HOST_DATA
#endif

    Return
  End Function dev_ptr_int

  Type(C_PTR) Function dev_ptr_dp(a)
    !-----------------------------------------------------------------------------------------------
    ! Return the mapped device C pointer for a Real(dp) target.
    !-----------------------------------------------------------------------------------------------
    Implicit None
    Real(dp), Target, Intent(in) :: a

#if defined(XNET_OMP_OL)
    dev_ptr_dp = omp_get_mapped_ptr(c_loc(a),omp_get_default_device())
#else
    !XDIR XHOST_DATA &
    !XDIR XDEV_PTR(a)
    dev_ptr_dp = c_loc(a)
    !XDIR XEND_HOST_DATA
#endif

    Return
  End Function dev_ptr_dp

  Type(C_PTR) Function dev_ptr_cptr(a)
    !-----------------------------------------------------------------------------------------------
    ! Return the mapped device C pointer for a Type(C_PTR) target.
    !-----------------------------------------------------------------------------------------------
    Implicit None
    Type(C_PTR), Target, Intent(in) :: a

#if defined(XNET_OMP_OL)
    dev_ptr_cptr = omp_get_mapped_ptr(c_loc(a),omp_get_default_device())
#else
    !XDIR XHOST_DATA &
    !XDIR XDEV_PTR(a)
    dev_ptr_cptr = c_loc(a)
    !XDIR XEND_HOST_DATA
#endif

    Return
  End Function dev_ptr_cptr

  !=================================================================================================
  ! Private Implementation Helpers
  !=================================================================================================

  Subroutine report_gpu_status(status_in,message_in,ierr,message)
    !-----------------------------------------------------------------------------------------------
    ! Populate optional status/message arguments or terminate when called without ierr.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Input variables
    Integer, Intent(in) :: status_in
    Character(*), Intent(in) :: message_in

    ! Optional output variables
    Integer, Optional, Intent(out) :: ierr
    Character(*), Optional, Intent(out) :: message

    If ( present(ierr) ) ierr = status_in
    If ( present(message) ) message = message_in
    If ( status_in /= 0 .and. .not. present(ierr) ) Call xnet_terminate(trim(message_in),status_in)

    Return
  End Subroutine report_gpu_status

  Subroutine gpu_current_device(device,ierr,message)
    !-----------------------------------------------------------------------------------------------
    ! Query the active device in the vendor runtime and verify agreement with the directive runtime.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Output variables
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

#if defined(XNET_GPU)
  Logical Function same_c_ptr(ptr_a,ptr_b)
    !-----------------------------------------------------------------------------------------------
    ! Compare two C_PTR values for equality, treating two C_NULL_PTR values as equal.
    !-----------------------------------------------------------------------------------------------
    Implicit None
    Type(C_PTR), Intent(in) :: ptr_a, ptr_b

    If ( c_associated(ptr_a) .and. c_associated(ptr_b) ) Then
      same_c_ptr = c_associated(ptr_a,ptr_b)
    Else
      same_c_ptr = ( .not. c_associated(ptr_a) .and. .not. c_associated(ptr_b) )
    EndIf

    Return
  End Function same_c_ptr

  Subroutine validate_embedded_device(gpu_context,device,ierr,message)
    !-----------------------------------------------------------------------------------------------
    ! Verify backend support and device selection for an embedded application caller.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Input variables
    Type(xnet_gpu_t), Intent(in) :: gpu_context

    ! Output variables
    Integer, Intent(out) :: device, ierr
    Character(*), Intent(out) :: message

    device = -1
    ierr = 0
    message = ' '
#if defined(XNET_LA_MAGMA)
    ierr = 3
    message = 'GPU resource values are not currently supported by the MAGMA backend'
    Return
#endif
    Call gpu_current_device(device,ierr,message)
    If ( ierr /= 0 ) Return
    If ( gpu_context%device >= 0 .and. gpu_context%device /= device ) Then
      ierr = 1
      message = 'Supplied GPU device does not match the current application device'
    EndIf

    Return
  End Subroutine validate_embedded_device

  Subroutine select_standalone_device(device,ierr,message)
    !-----------------------------------------------------------------------------------------------
    ! Query visible GPUs and bind the current rank (myid mod deviceCount) for standalone runs.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Output variables
    Integer, Intent(out) :: device, ierr
    Character(*), Intent(out) :: message

    ! Local variables
    Integer(C_INT) :: status

    device = -1
    ierr = 0
    message = ' '
#if defined(XNET_CUDA)
    status = cudaGetDeviceCount(deviceCount)
#elif defined(XNET_HIP)
    status = hipGetDeviceCount(deviceCount)
#endif
    If ( status /= 0 ) Then
      ierr = 1
      Write(message,'(A,I0)') 'Cannot query the GPU count, status ',status
      Return
    EndIf
    If ( deviceCount <= 0 ) Then
      ierr = 1
      message = 'No GPU found'
      Return
    EndIf
    device = mod(myid,deviceCount)
#if defined(XNET_CUDA)
    status = cudaSetDevice(int(device,C_INT))
#elif defined(XNET_HIP)
    status = hipSetDevice(int(device,C_INT))
#endif
    If ( status /= 0 ) Then
      ierr = 1
      Write(message,'(A,I0)') 'Cannot select the standalone GPU device, status ',status
      Return
    EndIf
#if defined(XNET_OMP_OL)
    ! Later target regions inherit the default device of the calling task.
    Call omp_set_default_device(device)
#endif
#if defined(XNET_LA_MAGMA)
    Call magma_getdevice(magma_device)
    Call magma_init()
#endif

    Return
  End Subroutine select_standalone_device

  Subroutine check_handle_stream(handle,query_status,handle_stream,label,work_stream,stream_known, &
    & thread_status,thread_message)
    !-----------------------------------------------------------------------------------------------
    ! Verify that the stream query for a borrowed handle succeeded and matches work_stream.
    ! If no stream was previously known, adopt the handle stream as work_stream.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Input variables
    Type(C_PTR), Intent(in) :: handle, handle_stream
    Integer(C_INT), Intent(in) :: query_status
    Character(*), Intent(in) :: label

    ! Input/Output variables
    Type(C_PTR), Intent(inout) :: work_stream
    Logical, Intent(inout) :: stream_known

    ! Output variables
    Integer, Intent(out) :: thread_status
    Character(*), Intent(out) :: thread_message

    thread_status = 0
    thread_message = ' '
    If ( .not. c_associated(handle) ) Return
    If ( query_status /= 0 ) Then
      thread_status = 1
      Write(thread_message,'(A,I0)') 'Cannot query the supplied '//trim(label)//' stream, status ',query_status
      Return
    EndIf
    If ( .not. stream_known ) Then
      work_stream = handle_stream
      stream_known = .true.
    EndIf
    If ( .not. same_c_ptr(handle_stream,work_stream) ) Then
      thread_status = 1
      thread_message = 'Supplied '//trim(label)//' handle and GPU stream do not match'
    EndIf

    Return
  End Subroutine check_handle_stream

  Subroutine init_thread_resources(device,gpu_context,init_status,init_message)
    !-----------------------------------------------------------------------------------------------
    ! Validate borrowed handles, allocate any missing stream/handles on the calling thread, and
    ! install their ownership state. The outer gpu_init joins the team before attempting rollback.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Input variables
    Integer, Intent(in) :: device
    Type(xnet_gpu_t), Optional, Intent(in) :: gpu_context

    ! Input/Output variables
    Integer, Intent(inout) :: init_status
    Character(*), Intent(inout) :: init_message

    ! Local variables
    Integer :: queue, thread_status
    Character(512) :: thread_message
    Integer(C_INT) :: status
    Type(C_PTR) :: work_stream, handle_stream
    Logical :: stream_known, create_stream, resources_created
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

    thread_status = 0
    thread_message = ' '
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

    ! Attempt resource validation and creation inside a single-pass block so any failure jumps
    ! cleanly to the team synchronization and rollback section below.
    setup: Do
      If ( gpu_initialized ) Then
        thread_status = 2
        thread_message = 'GPU resources are already initialized on a host thread'
        Exit setup
      EndIf

      If ( present(gpu_context) ) Then
        queue = gpu_context%queue
        work_stream = gpu_context%stream
        stream_known = c_associated(work_stream)
#if defined(XNET_CUDA)
        work_cublas = gpu_context%cublas_handle
        work_cusolver = gpu_context%cusolver_handle
#elif defined(XNET_HIP)
        work_hipblas = gpu_context%hipblas_handle
        work_rocblas = gpu_context%rocblas_handle
        work_rocsolver = gpu_context%rocsolver_handle
#endif
      Else
        ! Vendor device selection is per host thread; all standalone threads use the rank device.
#if defined(XNET_CUDA)
        status = cudaSetDevice(int(device,C_INT))
#elif defined(XNET_HIP)
        status = hipSetDevice(int(device,C_INT))
#endif
        If ( status /= 0 ) Then
          thread_status = 1
          Write(thread_message,'(A,I0)') 'Cannot select the standalone GPU device, status ',status
          Exit setup
        EndIf
#if defined(XNET_OACC)
        Call acc_set_device_num(int(device,C_INT),acc_device_default)
#elif defined(XNET_OMP_OL)
        Call omp_set_default_device(device)
#endif
      EndIf

#if defined(XNET_OACC)
      If ( queue < int(acc_async_sync) ) Then
        thread_status = 1
        thread_message = 'Invalid OpenACC queue'
        Exit setup
      EndIf
      handle_stream = acc_get_cuda_stream(int(queue,C_LONG_LONG))
      If ( stream_known ) Then
        If ( .not. same_c_ptr(handle_stream,work_stream) ) Then
          thread_status = 1
          thread_message = 'Supplied OpenACC queue and GPU stream do not match'
          Exit setup
        EndIf
      EndIf
      work_stream = handle_stream
      stream_known = .true.
#endif

      ! Validate every supplied handle before allocating any XNet resources.
      ! Without an explicit OpenMP stream, the first supplied handle supplies its stream.
#if defined(XNET_CUDA)
      If ( c_associated(work_cublas) ) Then
        status = cublasGetStream_v2(work_cublas,handle_stream)
        Call check_handle_stream(work_cublas,status,handle_stream,'cuBLAS', &
          & work_stream,stream_known,thread_status,thread_message)
        If ( thread_status /= 0 ) Exit setup
      EndIf
      If ( c_associated(work_cusolver) ) Then
        status = cusolverDnGetStream(work_cusolver,handle_stream)
        Call check_handle_stream(work_cusolver,status,handle_stream,'cuSOLVER', &
          & work_stream,stream_known,thread_status,thread_message)
        If ( thread_status /= 0 ) Exit setup
      EndIf
#elif defined(XNET_HIP)
      If ( c_associated(work_hipblas) ) Then
        status = hipblasGetStream(work_hipblas,handle_stream)
        Call check_handle_stream(work_hipblas,status,handle_stream,'hipBLAS', &
          & work_stream,stream_known,thread_status,thread_message)
        If ( thread_status /= 0 ) Exit setup
      EndIf
      If ( c_associated(work_rocblas) ) Then
        status = rocblas_get_stream(work_rocblas,handle_stream)
        Call check_handle_stream(work_rocblas,status,handle_stream,'rocBLAS', &
          & work_stream,stream_known,thread_status,thread_message)
        If ( thread_status /= 0 ) Exit setup
      EndIf
      If ( c_associated(work_rocsolver) ) Then
        status = rocblas_get_stream(work_rocsolver,handle_stream)
        Call check_handle_stream(work_rocsolver,status,handle_stream,'rocSOLVER', &
          & work_stream,stream_known,thread_status,thread_message)
        If ( thread_status /= 0 ) Exit setup
      EndIf
#endif

      ! Create an XNet-owned stream if none was supplied or inferred.
      If ( .not. stream_known ) Then
#if defined(XNET_CUDA)
        status = cudaStreamCreate(work_stream)
#elif defined(XNET_HIP)
        status = hipStreamCreate(work_stream)
#endif
        If ( status /= 0 ) Then
          thread_status = 1
          Write(thread_message,'(A,I0)') 'Cannot create the XNet GPU stream, status ',status
          Exit setup
        EndIf
        create_stream = .true.
      EndIf

      ! Create and bind any missing vendor library handles.
#if defined(XNET_CUDA)
      If ( .not. c_associated(work_cublas) ) Then
        status = cublasCreate_v2(work_cublas)
        If ( status /= 0 ) Then
          thread_status = 1
          Write(thread_message,'(A,I0)') 'Cannot create the XNet cuBLAS handle, status ',status
          Exit setup
        EndIf
        create_cublas = .true.
        status = cublasSetStream_v2(work_cublas,work_stream)
        If ( status /= 0 ) Then
          thread_status = 1
          Write(thread_message,'(A,I0)') 'Cannot associate the XNet cuBLAS stream, status ',status
          Exit setup
        EndIf
      EndIf
      If ( .not. c_associated(work_cusolver) ) Then
        status = cusolverDnCreate(work_cusolver)
        If ( status /= 0 ) Then
          thread_status = 1
          Write(thread_message,'(A,I0)') 'Cannot create the XNet cuSOLVER handle, status ',status
          Exit setup
        EndIf
        create_cusolver = .true.
        status = cusolverDnSetStream(work_cusolver,work_stream)
        If ( status /= 0 ) Then
          thread_status = 1
          Write(thread_message,'(A,I0)') 'Cannot associate the XNet cuSOLVER stream, status ',status
          Exit setup
        EndIf
      EndIf
#elif defined(XNET_HIP)
      If ( .not. c_associated(work_hipblas) ) Then
        status = hipblasCreate(work_hipblas)
        If ( status /= 0 ) Then
          thread_status = 1
          Write(thread_message,'(A,I0)') 'Cannot create the XNet hipBLAS handle, status ',status
          Exit setup
        EndIf
        create_hipblas = .true.
        status = hipblasSetStream(work_hipblas,work_stream)
        If ( status /= 0 ) Then
          thread_status = 1
          Write(thread_message,'(A,I0)') 'Cannot associate the XNet hipBLAS stream, status ',status
          Exit setup
        EndIf
      EndIf
      If ( .not. c_associated(work_rocblas) ) Then
        status = rocblas_create_handle(work_rocblas)
        If ( status /= 0 ) Then
          thread_status = 1
          Write(thread_message,'(A,I0)') 'Cannot create the XNet rocBLAS handle, status ',status
          Exit setup
        EndIf
        create_rocblas = .true.
        status = rocblas_set_stream(work_rocblas,work_stream)
        If ( status /= 0 ) Then
          thread_status = 1
          Write(thread_message,'(A,I0)') 'Cannot associate the XNet rocBLAS stream, status ',status
          Exit setup
        EndIf
      EndIf
      ! rocSOLVER accepts a rocBLAS handle; the default alias shares rocblas_handle without a separate destroy.
      If ( .not. c_associated(work_rocsolver) ) work_rocsolver = work_rocblas
#endif

#if defined(XNET_LA_MAGMA)
      Call magma_queue_create_from_cuda(int(device,C_INT),work_stream,work_cublas,C_NULL_PTR,work_magma_queue)
      If ( .not. c_associated(work_magma_queue) ) Then
        thread_status = 1
        thread_message = 'Cannot create the XNet MAGMA queue'
        Exit setup
      EndIf
      create_magma_queue = .true.
#endif
      Exit setup
    EndDo setup

    If ( thread_status /= 0 ) Then
      !$omp critical(xnet_gpu_init_status)
      If ( init_status == 0 ) Then
        init_status = thread_status
        init_message = thread_message
      EndIf
      !$omp end critical(xnet_gpu_init_status)
    EndIf
#ifdef XNET_OMP
    !$omp barrier
#endif

    ! Keep partial ownership too: the same finalizer must be able to retry failed rollback.
    resources_created = create_stream
#if defined(XNET_CUDA)
    resources_created = resources_created .or. create_cublas .or. create_cusolver
#elif defined(XNET_HIP)
    resources_created = resources_created .or. create_hipblas .or. create_rocblas
#endif
#if defined(XNET_LA_MAGMA)
    resources_created = resources_created .or. create_magma_queue
#endif
    If ( init_status == 0 .or. resources_created ) Then
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
      If ( init_status == 0 .and. .not. present(gpu_context) ) Then
        acc_queue = int(queue,C_LONG_LONG)
        Call acc_set_cuda_stream(int(acc_async_sync,C_LONG_LONG),work_stream)
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
    EndIf

    Return
  End Subroutine init_thread_resources

  Subroutine finalize_thread_resources(thread_status,thread_message)
    !-----------------------------------------------------------------------------------------------
    ! Synchronize the thread stream and destroy owned handles/streams in dependency order.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Output variables
    Integer, Intent(out) :: thread_status
    Character(*), Intent(out) :: thread_message

    ! Local variables
    Integer(C_INT) :: status
#if defined(XNET_HIP)
    Type(C_PTR) :: work_rocblas, work_rocsolver
#endif

    thread_status = 0
    thread_message = ' '
    If ( .not. gpu_initialized ) Return

    Call gpu_check_device(thread_status,thread_message)
    If ( thread_status /= 0 ) Return

#if defined(XNET_CUDA)
    status = cudaStreamSynchronize(stream)
#elif defined(XNET_HIP)
    status = hipStreamSynchronize(stream)
#endif
    If ( status /= 0 ) Then
      thread_status = 1
      Write(thread_message,'(A,I0)') 'Cannot synchronize the XNet GPU stream, status ',status
      Return
    EndIf

#if defined(XNET_LA_MAGMA)
    If ( owns_magma_queue ) Call magma_queue_destroy(magma_queue)
    magma_queue = C_NULL_PTR
    owns_magma_queue = .false.
#endif

#if defined(XNET_CUDA)
    If ( owns_cusolver ) Then
      status = cusolverDnDestroy(cusolver_handle)
      If ( status == 0 ) Then
        cusolver_handle = C_NULL_PTR
        owns_cusolver = .false.
      Else
        thread_status = 1
        Write(thread_message,'(A,I0)') 'Cannot destroy the XNet cuSOLVER handle, status ',status
      EndIf
    EndIf
    If ( owns_cublas ) Then
      status = cublasDestroy_v2(cublas_handle)
      If ( status == 0 ) Then
        cublas_handle = C_NULL_PTR
        owns_cublas = .false.
      ElseIf ( thread_status == 0 ) Then
        thread_status = 1
        Write(thread_message,'(A,I0)') 'Cannot destroy the XNet cuBLAS handle, status ',status
      EndIf
    EndIf
#elif defined(XNET_HIP)
    If ( owns_rocblas ) Then
      status = rocblas_destroy_handle(rocblas_handle)
      If ( status == 0 ) Then
        ! Compare local C pointers so CCE 20 does not reject direct comparison of imported handles.
        work_rocblas = rocblas_handle
        work_rocsolver = rocsolver_handle
        If ( c_associated(work_rocsolver,work_rocblas) ) rocsolver_handle = C_NULL_PTR
        rocblas_handle = C_NULL_PTR
        owns_rocblas = .false.
      Else
        thread_status = 1
        Write(thread_message,'(A,I0)') 'Cannot destroy the XNet rocBLAS handle, status ',status
      EndIf
    EndIf
    If ( owns_hipblas ) Then
      status = hipblasDestroy(hipblas_handle)
      If ( status == 0 ) Then
        hipblas_handle = C_NULL_PTR
        owns_hipblas = .false.
      ElseIf ( thread_status == 0 ) Then
        thread_status = 1
        Write(thread_message,'(A,I0)') 'Cannot destroy the XNet hipBLAS handle, status ',status
      EndIf
    EndIf
#endif

    ! Failed handles may still reference this stream; keep stream state intact for a cleanup retry.
    If ( thread_status /= 0 ) Return

    If ( owns_stream ) Then
#if defined(XNET_CUDA)
      status = cudaStreamDestroy(stream)
#elif defined(XNET_HIP)
      status = hipStreamDestroy(stream)
#endif
      If ( status /= 0 ) Then
        thread_status = 1
        Write(thread_message,'(A,I0)') 'Cannot destroy the XNet GPU stream, status ',status
        Return
      EndIf
    EndIf

    ! Clear borrowed and owned associations only after all owned resources are destroyed.
#if defined(XNET_CUDA)
    cusolver_handle = C_NULL_PTR
    cublas_handle = C_NULL_PTR
    cuda_stream = C_NULL_PTR
#elif defined(XNET_HIP)
    rocblas_handle = C_NULL_PTR
    rocsolver_handle = C_NULL_PTR
    hipblas_handle = C_NULL_PTR
    hip_stream = C_NULL_PTR
#endif
    Nullify(stream)
    owns_stream = .false.
    gpu_queue = 1
    active_device = -1
    gpu_initialized = .false.

    Return
  End Subroutine finalize_thread_resources
#endif

End Module xnet_gpu
