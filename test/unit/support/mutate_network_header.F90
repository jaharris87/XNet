Program mutate_network_header
  Use xnet_types, Only: dp
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
  Case ('nets4-count','nets4-order')
    Call mutate_nets4(trim(data_dir),trim(mode))
  Case ('match-count')
    Call mutate_match_data(trim(data_dir))
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
      saved_name = names(1)
      names(1) = names(2)
      names(2) = saved_name
    EndIf

    Open(newunit=lun,file=trim(directory)//'/nets4',form='unformatted',status='replace',action='write')
    Write(lun) ny_write
    Write(lun) names
    Write(lun) nffn, nnnu
    Write(lun) nreac
    Do i = 1, ny_file
      Write(lun) i, (la(j,i),le(j,i),j=1,4)
    EndDo
    Close(lun)

    Deallocate (names,la,le)

    Return
  End Subroutine mutate_nets4

  Subroutine mutate_match_data(directory)
    Implicit None

    Character(*), Intent(in) :: directory

    Character(4), Allocatable :: descx(:)
    Integer, Allocatable :: ifl1(:), ifl2(:), ifl3(:), ifl4(:)
    Integer, Allocatable :: iwflx(:), nflx(:,:)
    Real(dp), Allocatable :: qflx(:)
    Integer :: lun, mflx, nr(4), nr_write(4)

    Open(newunit=lun,file=trim(directory)//'/match_data',form='unformatted',status='old',action='read')
    Read(lun) mflx, nr
    Allocate (ifl1(nr(1)),ifl2(nr(2)),ifl3(nr(3)),ifl4(nr(4)))
    Allocate (nflx(8,mflx),qflx(mflx),iwflx(mflx),descx(mflx))
    Read(lun) ifl1, ifl2, ifl3, ifl4
    Read(lun) nflx, qflx, iwflx, descx
    Close(lun)

    nr_write = nr
    nr_write(1) = nr_write(1) + 1
    Open(newunit=lun,file=trim(directory)//'/match_data',form='unformatted',status='replace',action='write')
    Write(lun) mflx, nr_write
    Write(lun) ifl1, ifl2, ifl3, ifl4
    Write(lun) nflx, qflx, iwflx, descx
    Close(lun)

    Deallocate (ifl1,ifl2,ifl3,ifl4,nflx,qflx,iwflx,descx)

    Return
  End Subroutine mutate_match_data

End Program mutate_network_header
