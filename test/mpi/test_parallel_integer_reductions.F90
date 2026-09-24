program test_parallel_integer_reductions
  use xnet_mpi
  use xnet_parallel, only: parallel_finalize, parallel_initialize, &
       parallel_myproc, parallel_nprocs, parallel_reduce
  use xnet_types, only: i8
  implicit none

  character(len=32) :: mode
  integer :: caller_comm, ierr, rank, size
  integer(i8) :: actual, expected, input
  integer(i8) :: actual_vector(2), expected_vector(2), input_vector(2)
  logical :: caller_owned

  call get_command_argument(1, mode)
  caller_owned = trim(mode) == 'caller-owned'

  if (caller_owned) then
    call MPI_Init(ierr)
    call MPI_Comm_dup(MPI_COMM_WORLD, caller_comm, ierr)
    call parallel_initialize(comm=caller_comm)
  else
    call parallel_initialize()
  end if

  rank = parallel_myproc()
  size = parallel_nprocs()
  input = int(rank + 1, i8)

  call parallel_reduce(actual, input, MPI_MIN)
  call check_scalar('minimum', actual, 1_i8)

  call parallel_reduce(actual, input, MPI_MAX)
  call check_scalar('maximum', actual, int(size, i8))

  expected = int(size * (size + 1) / 2, i8)
  call parallel_reduce(actual, input, MPI_SUM)
  call check_scalar('sum', actual, expected)

  input_vector = [int(rank + 1, i8), int(10 - rank, i8)]
  expected_vector = [int(size, i8), 10_i8]
  call parallel_reduce(actual_vector, input_vector, MPI_MAX)
  call check_vector('vector maximum', actual_vector, expected_vector)

  expected_vector = [1_i8, int(10 - (size - 1), i8)]
  call parallel_reduce(actual_vector, input_vector, MPI_MIN)
  call check_vector('vector minimum', actual_vector, expected_vector)

  expected_vector = [int(size * (size + 1) / 2, i8), &
       int(10 * size - size * (size - 1) / 2, i8)]
  call parallel_reduce(actual_vector, input_vector, MPI_SUM)
  call check_vector('vector sum', actual_vector, expected_vector)

  call parallel_finalize(do_finalize_MPI=.not. caller_owned)
  if (caller_owned) then
    call MPI_Comm_free(caller_comm, ierr)
    call MPI_Finalize(ierr)
  end if

  if (rank == 0) write (*,'(a,1x,a)') 'PASS', trim(mode)

contains

  subroutine check_scalar(label, value, wanted)
    character(len=*), intent(in) :: label
    integer(i8), intent(in) :: value, wanted

    if (value /= wanted) then
      write (*,*) 'rank', rank, trim(label), 'got', value, 'expected', wanted
      call MPI_Abort(MPI_COMM_WORLD, 1, ierr)
    end if
  end subroutine check_scalar

  subroutine check_vector(label, value, wanted)
    character(len=*), intent(in) :: label
    integer(i8), intent(in) :: value(:), wanted(:)

    if (any(value /= wanted)) then
      write (*,*) 'rank', rank, trim(label), 'got', value, 'expected', wanted
      call MPI_Abort(MPI_COMM_WORLD, 1, ierr)
    end if
  end subroutine check_vector
end program test_parallel_integer_reductions
