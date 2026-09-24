program test_parallel_integer_reductions
  use, intrinsic :: iso_fortran_env, only: output_unit
  use xnet_mpi
  use xnet_parallel, only: parallel_finalize, parallel_initialize, &
       parallel_myproc, parallel_nprocs, parallel_reduce
  use xnet_types, only: i8
  implicit none

  character(len=32) :: mode
  integer, parameter :: required_ranks = 2
  integer(i8), parameter :: large_value = 5000000000_i8
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
  if (size /= required_ranks) then
    write (output_unit,'(a,i0,a,i0)') 'ERROR requires exactly ', &
         required_ranks, ' MPI ranks; observed ', size
    flush (output_unit)
    call MPI_Abort(MPI_COMM_WORLD, 2, ierr)
  end if

  input = large_value + int(rank + 1, i8)

  call parallel_reduce(actual, input, MPI_MIN)
  call check_scalar('minimum', actual, large_value + 1_i8)

  call parallel_reduce(actual, input, MPI_MAX)
  call check_scalar('maximum', actual, large_value + int(size, i8))

  expected = int(size, i8) * large_value + int(size * (size + 1) / 2, i8)
  call parallel_reduce(actual, input, MPI_SUM)
  call check_scalar('sum', actual, expected)

  input_vector = [large_value + int(rank + 1, i8), &
       -large_value - int(rank + 1, i8)]
  expected_vector = [large_value + int(size, i8), -large_value - 1_i8]
  call parallel_reduce(actual_vector, input_vector, MPI_MAX)
  call check_vector('vector maximum', actual_vector, expected_vector)

  expected_vector = [large_value + 1_i8, -large_value - int(size, i8)]
  call parallel_reduce(actual_vector, input_vector, MPI_MIN)
  call check_vector('vector minimum', actual_vector, expected_vector)

  expected_vector = [expected, -expected]
  call parallel_reduce(actual_vector, input_vector, MPI_SUM)
  call check_vector('vector sum', actual_vector, expected_vector)

  call parallel_reduce(actual, input, MPI_SUM, proc=0)
  if (rank == 0) call check_scalar('rooted sum', actual, expected)

  call parallel_reduce(actual_vector, input_vector, MPI_MAX, proc=1)
  if (rank == 1) then
    expected_vector = [large_value + int(size, i8), -large_value - 1_i8]
    call check_vector('rooted vector maximum', actual_vector, expected_vector)
  end if

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
