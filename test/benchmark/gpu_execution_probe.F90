! Capture-owned proof that the selected XNet accelerator backend executes a
! mapped dense solve on a device.  This is deliberately small and is linked
! against the same configured objects as the benchmark executable.
Program xnet_benchmark_gpu_probe
  Use, Intrinsic :: iso_c_binding, Only: C_LOC, C_SIZEOF
  Use, Intrinsic :: iso_fortran_env, Only: output_unit
  Use xnet_controls, Only: myid, nproc, tid, nthread
  Use xnet_gpu, Only: &
    & device_is_present, deviceCount, gpu_finalize, gpu_init, mydevice, on_device
  Use xnet_linalg, Only: LinearSolveBatched
  Use xnet_types, Only: dp
  Implicit None

  Integer, Parameter :: matrix_size = 2
  Integer, Parameter :: batch_count = 1
  Integer, Target :: info(batch_count)
  Integer, Target :: ipiv(matrix_size,batch_count)
  Real(dp), Target :: matrix(matrix_size,matrix_size)
  Real(dp), Target :: rhs(matrix_size,batch_count)
  Real(dp) :: residual(matrix_size)
  Logical :: offloaded
  Logical :: data_present
  Character(32) :: rank_text
  Integer :: rank_length
  Integer :: rank_status

  myid = 0
  nproc = 1
  tid = 1
  nthread = 1
  matrix = Reshape([4.0_dp, 1.0_dp, 1.0_dp, 3.0_dp], Shape(matrix))
  rhs(:,1) = [6.0_dp, 7.0_dp]
  info = -1
  ipiv = 0
  rank_text = '-'
  Call get_environment_variable('SLURM_PROCID',rank_text,rank_length,rank_status)
  If ( rank_status /= 0 ) &
    & Call get_environment_variable('OMPI_COMM_WORLD_RANK',rank_text,rank_length,rank_status)
  If ( rank_status /= 0 ) &
    & Call get_environment_variable('PMI_RANK',rank_text,rank_length,rank_status)
  If ( rank_status /= 0 ) rank_text = '0'

  Call gpu_init()
  offloaded = .false.
#if defined(XNET_OMP_OL)
  !$omp target map(from:offloaded)
  offloaded = on_device()
  !$omp end target
#elif defined(XNET_OACC)
  !$acc parallel copyout(offloaded)
  offloaded = on_device()
  !$acc end parallel
#endif

#if defined(XNET_OMP_OL)
  !$omp target enter data map(to:matrix,rhs) map(alloc:ipiv,info)
#elif defined(XNET_OACC)
  !$acc enter data copyin(matrix,rhs) create(ipiv,info)
#endif
  data_present = &
    & device_is_present(C_LOC(matrix),mydevice,Size(matrix)*C_SIZEOF(matrix(1,1))) &
    & .And. device_is_present(C_LOC(rhs),mydevice,Size(rhs)*C_SIZEOF(rhs(1,1)))
  If ( data_present ) &
    & Call LinearSolveBatched('N',matrix_size,1,matrix,matrix_size,ipiv(1,1), &
    & rhs,matrix_size,info(1),batch_count)
#if defined(XNET_OMP_OL)
  !$omp target update from(rhs,info)
  !$omp target exit data map(release:matrix,rhs,ipiv,info)
#elif defined(XNET_OACC)
  !$acc update self(rhs,info)
  !$acc exit data delete(matrix,rhs,ipiv,info)
#endif
  residual = Matmul(Reshape([4.0_dp,1.0_dp,1.0_dp,3.0_dp],Shape(matrix)),rhs(:,1)) &
    & - [6.0_dp,7.0_dp]

  Write(output_unit,'(a,a,a,i0,a,i0,a,l1,a,l1,a,i0,a,es16.8)') &
    & 'XNET_BENCHMARK_DEVICE rank ',Trim(rank_text),' device ',mydevice, &
    & ' count ',deviceCount,' offloaded ',offloaded,' data_present ',data_present, &
    & ' info ',info(1),' residual ',Maxval(Abs(residual))
  Call gpu_finalize()
  If ( deviceCount < 1 .or. .not. offloaded .or. .not. data_present &
      & .or. info(1) /= 0 .or. Maxval(Abs(residual)) > 1.0e-12_dp ) Stop 1
End Program xnet_benchmark_gpu_probe
