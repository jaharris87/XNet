!***************************************************************************************************
! xnet_match.f90 10/18/17
! This file containes the data structures and input routines for matching reactions which involve
! the same nuclei (forward and reverse reactions as well as reactions with multiple components).
!***************************************************************************************************

Module xnet_match
  !-------------------------------------------------------------------------------------------------
  ! This module contains the data necessary to match up reactions.
  !-------------------------------------------------------------------------------------------------
  Use xnet_types, Only: dp
  Implicit None
  Integer                   :: mflx                               ! Number of unique reaction pairs
  Integer, Allocatable      :: nflx(:,:)                          ! The nuclei in each unique reaction
  Integer, Allocatable      :: iwflx(:)                           ! Reaction pair weak flag
  Integer, Allocatable      :: ifl1(:), ifl2(:), ifl3(:), ifl4(:) ! Maps reaction rate arrays to reaction pair arrays
  Real(dp), Allocatable     :: qflx(:)                            ! Reaction pair Q values
  Character(4), Allocatable :: descx(:)                           ! Descriptor for the reaction pair

  Integer, Parameter, Private :: match_ok = 0
  Integer, Parameter, Private :: match_open_error = 1
  Integer, Parameter, Private :: match_read_error = 2
  Integer, Parameter, Private :: match_count_mismatch = 3
  Integer, Parameter, Private :: match_invalid_dimension = 4
  Private :: read_match_header

Contains

  Subroutine read_match_header(data_dir,lun_match,mflx_file,status,mismatch_index,io_status)
    Use reaction_data, Only: nreac
    Implicit None

    ! Input variables
    Character(*), Intent(in) :: data_dir

    ! Output variables
    Integer, Intent(out) :: lun_match, mflx_file, status, mismatch_index, io_status

    ! Local variables
    Integer :: i, nr(4)

    status = match_ok
    mismatch_index = 0
    io_status = 0
    Open(newunit=lun_match, file=trim(data_dir)//"/match_data", form="unformatted", &
      & status="old", action='read', iostat=io_status)
    If ( io_status /= 0 ) Then
      status = match_open_error
      Return
    EndIf
    Read(lun_match,iostat=io_status) mflx_file, nr
    If ( io_status /= 0 ) Then
      status = match_read_error
      Close(lun_match)
      Return
    EndIf
    If ( mflx_file < 0 ) Then
      status = match_invalid_dimension
      Close(lun_match)
      Return
    EndIf
    Do i = 1, 4
      If ( nr(i) /= nreac(i) ) Then
        status = match_count_mismatch
        mismatch_index = i
        Close(lun_match)
        Return
      EndIf
    EndDo

    Return
  End Subroutine read_match_header

  Subroutine read_match_data(data_dir)
    !-----------------------------------------------------------------------------------------------
    ! This routine reads in the reaction matching data and allocates the necessary arrays.
    !-----------------------------------------------------------------------------------------------
    Use reaction_data, Only: nreac
    Use xnet_controls, Only: idiag, lun_diag
    Use xnet_parallel, Only: parallel_bcast, parallel_IOProcessor
    Use xnet_util, Only: xnet_terminate
    Implicit None

    ! Input variables
    Character(*), Intent(in) :: data_dir

    ! Local variables
    Integer :: io_status, lun_match, mflx_file, mismatch_index, status

    ! Open and read the matching data arrays
    If ( parallel_IOProcessor() ) Then
      Call read_match_header(data_dir,lun_match,mflx_file,status,mismatch_index,io_status)
      Select Case (status)
      Case (match_open_error)
        Call xnet_terminate('Failed to open match_data file',io_status)
      Case (match_read_error)
        Call xnet_terminate('Error reading match_data file',io_status)
      Case (match_count_mismatch)
        Call xnet_terminate('match_data reaction count does not match reaction_data for group=',mismatch_index)
      Case (match_invalid_dimension)
        Call xnet_terminate('Invalid dimension in match_data')
      End Select
      mflx = mflx_file
    EndIf
    Call parallel_bcast(mflx)

    Allocate (ifl1(nreac(1)),ifl2(nreac(2)),ifl3(nreac(3)),ifl4(nreac(4)))
    Allocate (nflx(8,mflx),qflx(mflx),iwflx(mflx),descx(mflx))
    If ( parallel_IOProcessor() ) Then
      Read(lun_match) ifl1, ifl2, ifl3, ifl4
      Read(lun_match) nflx,qflx,iwflx,descx
      Close(lun_match)
    EndIf
    Call parallel_bcast(ifl1)
    Call parallel_bcast(ifl2)
    Call parallel_bcast(ifl3)
    Call parallel_bcast(ifl4)
    Call parallel_bcast(nflx)
    Call parallel_bcast(qflx)
    Call parallel_bcast(iwflx)
    Call parallel_bcast(descx)

    !$omp parallel default(shared)
    If ( idiag >= 0 ) Write(lun_diag,*) 'Match',mflx
    !$omp end parallel

    Return
  End Subroutine read_match_data

End Module xnet_match
