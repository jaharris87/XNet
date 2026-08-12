Program mutate_network_header
  Implicit None

  Character(32) :: mode
  Character(512) :: data_dir

  If ( command_argument_count() /= 2 ) Then
    Write(*,*) 'usage: mutate_network_header MODE DATA_DIR'
    Stop 2
  EndIf
  Call get_command_argument(1,mode)
  Call get_command_argument(2,data_dir)

  Select Case (trim(mode))
  Case ('nets4-count','nets4-order-head','nets4-order-tail')
    Call mutate_nets4(trim(data_dir),trim(mode))
  Case ('match-count-1')
    Call mutate_match_data(trim(data_dir),1)
  Case ('match-count-2')
    Call mutate_match_data(trim(data_dir),2)
  Case ('match-count-3')
    Call mutate_match_data(trim(data_dir),3)
  Case ('match-count-4')
    Call mutate_match_data(trim(data_dir),4)
  Case Default
    Write(*,*) 'unsupported network-header mutation: ',trim(mode)
    Stop 2
  End Select

Contains

  Subroutine mutate_nets4(directory,mutation)
    Implicit None

    Character(*), Intent(in) :: directory, mutation

    Character(5), Allocatable :: names(:)
    Character(5) :: saved_name
    Integer, Allocatable :: la(:,:), le(:,:)
    Integer :: i, j, lun, nffn, nnnu, ny_file, ny_write
    Integer :: nreac(4)

    Open(newunit=lun,file=trim(directory)//'/nets4',form='unformatted',status='old',action='read')
    Read(lun) ny_file
    Allocate (names(ny_file),la(4,ny_file),le(4,ny_file))
    Read(lun) names
    Read(lun) nffn, nnnu
    Read(lun) nreac
    Do i = 1, ny_file
      Read(lun) j, la(:,i), le(:,i)
      If ( j /= i ) Then
        Write(*,*) 'unexpected nets4 row index',i,j
        Stop 2
      EndIf
    EndDo
    Close(lun)

    ny_write = ny_file
    If ( mutation == 'nets4-count' ) Then
      ny_write = ny_file + 1
    Else
      If ( ny_file < 2 ) Then
        Write(*,*) 'nets4 order mutation requires at least two species'
        Stop 2
      EndIf
      If ( mutation == 'nets4-order-tail' ) Then
        saved_name = names(ny_file-1)
        names(ny_file-1) = names(ny_file)
        names(ny_file) = saved_name
      Else
        saved_name = names(1)
        names(1) = names(2)
        names(2) = saved_name
      EndIf
    EndIf

    Open(newunit=lun,file=trim(directory)//'/nets4',form='unformatted',status='replace',action='write')
    Write(lun) ny_write
    If ( mutation == 'nets4-count' ) Then
      Close(lun)
      Deallocate (names,la,le)
      Return
    EndIf
    Write(lun) names
    Close(lun)

    Deallocate (names,la,le)

    Return
  End Subroutine mutate_nets4

  Subroutine mutate_match_data(directory,group)
    Implicit None

    Character(*), Intent(in) :: directory
    Integer, Intent(in) :: group

    Integer :: lun, mflx, nr(4), nr_write(4)

    Open(newunit=lun,file=trim(directory)//'/match_data',form='unformatted',status='old',action='read')
    Read(lun) mflx, nr
    Close(lun)

    nr_write = nr
    nr_write(group) = nr_write(group) + 1
    Open(newunit=lun,file=trim(directory)//'/match_data',form='unformatted',status='replace',action='write')
    Write(lun) mflx, nr_write
    Close(lun)

    Return
  End Subroutine mutate_match_data

End Program mutate_network_header
