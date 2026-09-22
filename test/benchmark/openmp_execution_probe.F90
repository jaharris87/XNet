! Report the actual OpenMP team and placement selected by the benchmark runtime.
Program xnet_benchmark_openmp_probe
  Use omp_lib, Only: omp_get_num_threads, omp_get_place_num, omp_get_proc_bind, &
    & omp_get_thread_num
  Implicit None
  Integer :: thread
  Integer :: team
  Integer :: place
  Integer :: binding
  Character(32) :: rank_text
  Integer :: rank_length
  Integer :: rank_status

  rank_text = '-'
  Call get_environment_variable('SLURM_PROCID',rank_text,rank_length,rank_status)
  If ( rank_status /= 0 ) &
    & Call get_environment_variable('OMPI_COMM_WORLD_RANK',rank_text,rank_length,rank_status)
  If ( rank_status /= 0 ) &
    & Call get_environment_variable('PMI_RANK',rank_text,rank_length,rank_status)
  If ( rank_status /= 0 ) rank_text = '0'

  !$omp parallel private(thread,team,place,binding)
  thread = omp_get_thread_num()
  team = omp_get_num_threads()
  place = omp_get_place_num()
  binding = omp_get_proc_bind()
  !$omp critical
  Write(*,'(a,a,a,i0,a,i0,a,i0,a,i0)') &
    & 'XNET_BENCHMARK_OPENMP rank ',Trim(rank_text),' thread ',thread, &
    & ' team ',team,' place ',place,' binding ',binding
  !$omp end critical
  !$omp end parallel
End Program xnet_benchmark_openmp_probe
