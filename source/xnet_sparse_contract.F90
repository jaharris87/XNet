!***************************************************************************************************
! Dependency-light contracts for the persisted sparse_ind schema and PARDISO-family self-heating
! augmentation.
!***************************************************************************************************

Module xnet_sparse_contract
  Use, Intrinsic :: iso_fortran_env, Only: iostat_end
  Implicit None
  Private

  Integer, Parameter, Public :: sparse_ind_ok = 0
  Integer, Parameter, Public :: sparse_ind_open_error = 1
  Integer, Parameter, Public :: sparse_ind_read_error = 2
  Integer, Parameter, Public :: sparse_ind_invalid = 3
  Integer, Parameter :: count_kind = selected_int_kind(18)

  Type, Public :: raw_sparse_ind_data
    Integer :: lval = 0
    Integer :: l1s = 0
    Integer :: l2s = 0
    Integer :: l3s = 0
    Integer :: l4s = 0
    Integer, Allocatable :: ridx(:), cidx(:), pb(:)
    Integer, Allocatable :: ns11(:), ns21(:), ns22(:)
    Integer, Allocatable :: ns31(:), ns32(:), ns33(:)
    Integer, Allocatable :: ns41(:), ns42(:), ns43(:), ns44(:)
  End Type raw_sparse_ind_data

  Type, Public :: pardiso_heat_data
    Integer, Allocatable :: ridx(:), cidx(:), pb(:)
    Integer, Allocatable :: ns11(:), ns21(:), ns22(:)
    Integer, Allocatable :: ns31(:), ns32(:), ns33(:)
    Integer, Allocatable :: ns41(:), ns42(:), ns43(:), ns44(:)
  End Type pardiso_heat_data

  Public :: augment_pardiso_crs
  Public :: read_sparse_ind

Contains

  Subroutine read_sparse_ind(file_name,ny,map_sizes,n10,n11,n20,n21,n22,n30,n31,n32,n33, &
    & n40,n41,n42,n43,n44,data,status,io_status,message)
    !-----------------------------------------------------------------------------------------------
    ! Read and validate the existing sequential-unformatted sparse_ind schema. Reaction-coordinate
    ! arguments describe the already-installed reaction data that every persisted map must match.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    Character(*), Intent(in) :: file_name
    Integer, Intent(in) :: ny, map_sizes(4)
    Integer, Intent(in) :: n10(:), n11(:), n20(:), n21(:), n22(:)
    Integer, Intent(in) :: n30(:), n31(:), n32(:), n33(:)
    Integer, Intent(in) :: n40(:), n41(:), n42(:), n43(:), n44(:)
    Type(raw_sparse_ind_data), Intent(out) :: data
    Integer, Intent(out) :: status, io_status
    Character(*), Intent(out) :: message

    Character(256) :: io_message
    Integer :: lun_sparse, trailing_value

    status = sparse_ind_ok
    io_status = 0
    message = ''
    If ( ny < 1 ) Then
      Call invalidate(status,message,'network dimension must be positive')
      Return
    EndIf
    If ( any(map_sizes < 0) .or. .not. target_dimensions_match(map_sizes,n10,n11,n20,n21,n22, &
      & n30,n31,n32,n33,n40,n41,n42,n43,n44) ) Then
      Call invalidate(status,message,'reaction-map dimensions are incompatible')
      Return
    EndIf

    Open(newunit=lun_sparse,file=trim(file_name),status='old',action='read',form='unformatted', &
      & iostat=io_status,iomsg=io_message)
    If ( io_status /= 0 ) Then
      status = sparse_ind_open_error
      message = trim(io_message)
      Return
    EndIf

    Read(lun_sparse,iostat=io_status,iomsg=io_message) data%lval
    If ( io_status /= 0 ) Then
      Call read_failure(status,message,'header record',io_message)
      Close(lun_sparse)
      Return
    EndIf
    If ( data%lval < ny .or. int(data%lval,count_kind) > &
      & int(ny,count_kind)*int(ny,count_kind) ) Then
      Call invalidate(status,message,'nonzero count is incompatible with network dimension')
      Close(lun_sparse)
      Return
    EndIf

    Allocate (data%ridx(data%lval),data%cidx(data%lval),data%pb(ny+1))
    Read(lun_sparse,iostat=io_status,iomsg=io_message) data%ridx, data%cidx, data%pb
    If ( io_status /= 0 ) Then
      Call read_failure(status,message,'topology record',io_message)
      Close(lun_sparse)
      Return
    EndIf

    Read(lun_sparse,iostat=io_status,iomsg=io_message) data%l1s, data%l2s, data%l3s, data%l4s
    If ( io_status /= 0 ) Then
      Call read_failure(status,message,'reaction-map dimension record',io_message)
      Close(lun_sparse)
      Return
    EndIf
    If ( any((/ data%l1s, data%l2s, data%l3s, data%l4s /) /= map_sizes) ) Then
      Call invalidate(status,message,'reaction-map sizes disagree with reaction data')
      Close(lun_sparse)
      Return
    EndIf

    Allocate (data%ns11(data%l1s))
    Allocate (data%ns21(data%l2s),data%ns22(data%l2s))
    Allocate (data%ns31(data%l3s),data%ns32(data%l3s),data%ns33(data%l3s))
    Allocate (data%ns41(data%l4s),data%ns42(data%l4s),data%ns43(data%l4s),data%ns44(data%l4s))
    Read(lun_sparse,iostat=io_status,iomsg=io_message) data%ns11, data%ns21, data%ns22
    If ( io_status /= 0 ) Then
      Call read_failure(status,message,'one/two-reactant map record',io_message)
      Close(lun_sparse)
      Return
    EndIf
    Read(lun_sparse,iostat=io_status,iomsg=io_message) data%ns31
    If ( io_status /= 0 ) Then
      Call read_failure(status,message,'ns31 map record',io_message)
      Close(lun_sparse)
      Return
    EndIf
    Read(lun_sparse,iostat=io_status,iomsg=io_message) data%ns32
    If ( io_status /= 0 ) Then
      Call read_failure(status,message,'ns32 map record',io_message)
      Close(lun_sparse)
      Return
    EndIf
    Read(lun_sparse,iostat=io_status,iomsg=io_message) data%ns33
    If ( io_status /= 0 ) Then
      Call read_failure(status,message,'ns33 map record',io_message)
      Close(lun_sparse)
      Return
    EndIf
    Read(lun_sparse,iostat=io_status,iomsg=io_message) data%ns41
    If ( io_status /= 0 ) Then
      Call read_failure(status,message,'ns41 map record',io_message)
      Close(lun_sparse)
      Return
    EndIf
    Read(lun_sparse,iostat=io_status,iomsg=io_message) data%ns42
    If ( io_status /= 0 ) Then
      Call read_failure(status,message,'ns42 map record',io_message)
      Close(lun_sparse)
      Return
    EndIf
    Read(lun_sparse,iostat=io_status,iomsg=io_message) data%ns43
    If ( io_status /= 0 ) Then
      Call read_failure(status,message,'ns43 map record',io_message)
      Close(lun_sparse)
      Return
    EndIf
    Read(lun_sparse,iostat=io_status,iomsg=io_message) data%ns44
    If ( io_status /= 0 ) Then
      Call read_failure(status,message,'ns44 map record',io_message)
      Close(lun_sparse)
      Return
    EndIf

    Read(lun_sparse,iostat=io_status,iomsg=io_message) trailing_value
    If ( io_status == 0 ) Then
      Call invalidate(status,message,'unexpected trailing record')
      Close(lun_sparse)
      Return
    ElseIf ( io_status /= iostat_end ) Then
      Call read_failure(status,message,'end of file',io_message)
      Close(lun_sparse)
      Return
    EndIf
    io_status = 0
    Close(lun_sparse)

    Call validate_raw_sparse_ind(data,ny,n10,n11,n20,n21,n22,n30,n31,n32,n33, &
      & n40,n41,n42,n43,n44,status,message)

    Return
  End Subroutine read_sparse_ind

  Subroutine augment_pardiso_crs(raw,ny,heated,status,message)
    !-----------------------------------------------------------------------------------------------
    ! Insert one self-heating column entry in every species row, append the complete temperature
    ! row, and remap persisted reaction locations without changing base-entry ordering.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    Type(raw_sparse_ind_data), Intent(in) :: raw
    Integer, Intent(in) :: ny
    Type(pardiso_heat_data), Intent(out) :: heated
    Integer, Intent(out) :: status
    Character(*), Intent(out) :: message

    Integer :: new_end, new_start, nnz, old_end, old_start, row

    status = sparse_ind_ok
    message = ''
    Call validate_raw_topology(raw,ny,status,message)
    If ( status /= sparse_ind_ok ) Return
    Call validate_raw_map_indices(raw,status,message)
    If ( status /= sparse_ind_ok ) Return

    nnz = raw%lval + 2*ny + 1
    Allocate (heated%ridx(nnz),heated%cidx(nnz),heated%pb(ny+2))
    heated%pb(1) = raw%pb(1)
    Do row = 1, ny
      old_start = raw%pb(row)
      old_end = raw%pb(row+1) - 1
      new_start = heated%pb(row)
      new_end = new_start + old_end - old_start
      heated%ridx(new_start:new_end) = raw%ridx(old_start:old_end)
      heated%cidx(new_start:new_end) = raw%cidx(old_start:old_end)
      heated%ridx(new_end+1) = row
      heated%cidx(new_end+1) = ny + 1
      heated%pb(row+1) = new_end + 2
    EndDo
    heated%pb(ny+2) = nnz + 1
    new_start = heated%pb(ny+1)
    Do row = 1, ny+1
      heated%ridx(new_start+row-1) = ny + 1
      heated%cidx(new_start+row-1) = row
    EndDo

    Call remap_indices(raw%ns11,raw%ridx,heated%ns11)
    Call remap_indices(raw%ns21,raw%ridx,heated%ns21)
    Call remap_indices(raw%ns22,raw%ridx,heated%ns22)
    Call remap_indices(raw%ns31,raw%ridx,heated%ns31)
    Call remap_indices(raw%ns32,raw%ridx,heated%ns32)
    Call remap_indices(raw%ns33,raw%ridx,heated%ns33)
    Call remap_indices(raw%ns41,raw%ridx,heated%ns41)
    Call remap_indices(raw%ns42,raw%ridx,heated%ns42)
    Call remap_indices(raw%ns43,raw%ridx,heated%ns43)
    Call remap_indices(raw%ns44,raw%ridx,heated%ns44)

    Call validate_pardiso_heat(raw,heated,ny,status,message)

    Return
  End Subroutine augment_pardiso_crs

  Subroutine validate_raw_sparse_ind(data,ny,n10,n11,n20,n21,n22,n30,n31,n32,n33, &
    & n40,n41,n42,n43,n44,status,message)
    Implicit None

    Type(raw_sparse_ind_data), Intent(in) :: data
    Integer, Intent(in) :: ny
    Integer, Intent(in) :: n10(:), n11(:), n20(:), n21(:), n22(:)
    Integer, Intent(in) :: n30(:), n31(:), n32(:), n33(:)
    Integer, Intent(in) :: n40(:), n41(:), n42(:), n43(:), n44(:)
    Integer, Intent(out) :: status
    Character(*), Intent(out) :: message

    status = sparse_ind_ok
    message = ''
    Call validate_raw_topology(data,ny,status,message)
    If ( status /= sparse_ind_ok ) Return
    Call validate_map(data%ns11,n10,n11,data,'ns11',status,message)
    If ( status /= sparse_ind_ok ) Return
    Call validate_map(data%ns21,n20,n21,data,'ns21',status,message)
    If ( status /= sparse_ind_ok ) Return
    Call validate_map(data%ns22,n20,n22,data,'ns22',status,message)
    If ( status /= sparse_ind_ok ) Return
    Call validate_map(data%ns31,n30,n31,data,'ns31',status,message)
    If ( status /= sparse_ind_ok ) Return
    Call validate_map(data%ns32,n30,n32,data,'ns32',status,message)
    If ( status /= sparse_ind_ok ) Return
    Call validate_map(data%ns33,n30,n33,data,'ns33',status,message)
    If ( status /= sparse_ind_ok ) Return
    Call validate_map(data%ns41,n40,n41,data,'ns41',status,message)
    If ( status /= sparse_ind_ok ) Return
    Call validate_map(data%ns42,n40,n42,data,'ns42',status,message)
    If ( status /= sparse_ind_ok ) Return
    Call validate_map(data%ns43,n40,n43,data,'ns43',status,message)
    If ( status /= sparse_ind_ok ) Return
    Call validate_map(data%ns44,n40,n44,data,'ns44',status,message)

    Return
  End Subroutine validate_raw_sparse_ind

  Subroutine validate_raw_topology(data,ny,status,message)
    Implicit None

    Type(raw_sparse_ind_data), Intent(in) :: data
    Integer, Intent(in) :: ny
    Integer, Intent(out) :: status
    Character(*), Intent(out) :: message

    Integer :: entry, row

    status = sparse_ind_ok
    message = ''
    If ( ny < 1 .or. data%lval < ny ) Then
      Call invalidate(status,message,'topology dimensions are incompatible')
      Return
    EndIf
    If ( .not. allocated(data%ridx) .or. .not. allocated(data%cidx) .or. &
      & .not. allocated(data%pb) ) Then
      Call invalidate(status,message,'topology arrays are incomplete')
      Return
    EndIf
    If ( size(data%ridx) /= data%lval .or. size(data%cidx) /= data%lval .or. &
      & size(data%pb) /= ny+1 ) Then
      Call invalidate(status,message,'topology dimensions are incompatible')
      Return
    EndIf
    If ( data%pb(1) /= 1 .or. data%pb(ny+1) /= data%lval+1 ) Then
      Call invalidate(status,message,'row pointer has wrong initial or terminal value')
      Return
    EndIf
    Do row = 1, ny
      If ( data%pb(row+1) <= data%pb(row) ) Then
        Call invalidate(status,message,'row pointers are not strictly ordered')
        Return
      EndIf
      Do entry = data%pb(row), data%pb(row+1)-1
        If ( data%ridx(entry) /= row .or. data%cidx(entry) < 1 .or. data%cidx(entry) > ny ) Then
          Call invalidate(status,message,'coordinate is outside its declared row')
          Return
        EndIf
        If ( entry > data%pb(row) ) Then
          If ( data%cidx(entry) <= data%cidx(entry-1) ) Then
            Call invalidate(status,message,'columns are not strictly ordered within a row')
            Return
          EndIf
        EndIf
      EndDo
      If ( count(data%cidx(data%pb(row):data%pb(row+1)-1) == row) /= 1 ) Then
        Call invalidate(status,message,'row does not contain exactly one diagonal')
        Return
      EndIf
    EndDo

    Return
  End Subroutine validate_raw_topology

  Subroutine validate_raw_map_indices(data,status,message)
    Implicit None

    Type(raw_sparse_ind_data), Intent(in) :: data
    Integer, Intent(out) :: status
    Character(*), Intent(out) :: message

    status = sparse_ind_ok
    message = ''
    If ( .not. allocated(data%ns11) .or. .not. allocated(data%ns21) .or. &
      & .not. allocated(data%ns22) .or. .not. allocated(data%ns31) .or. &
      & .not. allocated(data%ns32) .or. .not. allocated(data%ns33) .or. &
      & .not. allocated(data%ns41) .or. .not. allocated(data%ns42) .or. &
      & .not. allocated(data%ns43) .or. .not. allocated(data%ns44) ) Then
      Call invalidate(status,message,'reaction-map arrays are incomplete')
      Return
    EndIf
    If ( size(data%ns11) /= data%l1s .or. size(data%ns21) /= data%l2s .or. &
      & size(data%ns22) /= data%l2s .or. size(data%ns31) /= data%l3s .or. &
      & size(data%ns32) /= data%l3s .or. size(data%ns33) /= data%l3s .or. &
      & size(data%ns41) /= data%l4s .or. size(data%ns42) /= data%l4s .or. &
      & size(data%ns43) /= data%l4s .or. size(data%ns44) /= data%l4s ) Then
      Call invalidate(status,message,'reaction-map dimensions are incompatible')
      Return
    EndIf
    If ( .not. indices_in_range(data%ns11,data%lval) .or. &
      & .not. indices_in_range(data%ns21,data%lval) .or. &
      & .not. indices_in_range(data%ns22,data%lval) .or. &
      & .not. indices_in_range(data%ns31,data%lval) .or. &
      & .not. indices_in_range(data%ns32,data%lval) .or. &
      & .not. indices_in_range(data%ns33,data%lval) .or. &
      & .not. indices_in_range(data%ns41,data%lval) .or. &
      & .not. indices_in_range(data%ns42,data%lval) .or. &
      & .not. indices_in_range(data%ns43,data%lval) .or. &
      & .not. indices_in_range(data%ns44,data%lval) ) Then
      Call invalidate(status,message,'reaction-map index is out of range')
      Return
    EndIf

    Return
  End Subroutine validate_raw_map_indices

  Subroutine validate_map(map,row_index,column_index,data,label,status,message)
    Implicit None

    Integer, Intent(in) :: map(:), row_index(:), column_index(:)
    Type(raw_sparse_ind_data), Intent(in) :: data
    Character(*), Intent(in) :: label
    Integer, Intent(out) :: status
    Character(*), Intent(out) :: message

    Integer :: entry, reaction

    status = sparse_ind_ok
    message = ''
    Do reaction = 1, size(map)
      entry = map(reaction)
      If ( entry < 1 .or. entry > data%lval ) Then
        Call invalidate(status,message,trim(label)//' index is out of range')
        Return
      EndIf
      If ( data%ridx(entry) /= row_index(reaction) .or. &
        & data%cidx(entry) /= column_index(reaction) ) Then
        Call invalidate(status,message,trim(label)//' does not resolve to its reaction coordinate')
        Return
      EndIf
    EndDo

    Return
  End Subroutine validate_map

  Subroutine validate_pardiso_heat(raw,heated,ny,status,message)
    Implicit None

    Type(raw_sparse_ind_data), Intent(in) :: raw
    Type(pardiso_heat_data), Intent(in) :: heated
    Integer, Intent(in) :: ny
    Integer, Intent(out) :: status
    Character(*), Intent(out) :: message

    Integer :: entry, nnz, row

    status = sparse_ind_ok
    message = ''
    nnz = raw%lval + 2*ny + 1
    If ( size(heated%ridx) /= nnz .or. size(heated%cidx) /= nnz .or. &
      & size(heated%pb) /= ny+2 ) Then
      Call invalidate(status,message,'heated CRS dimensions are incompatible')
      Return
    EndIf
    If ( heated%pb(1) /= 1 .or. heated%pb(ny+2) /= nnz+1 ) Then
      Call invalidate(status,message,'heated CRS has wrong terminal pointer')
      Return
    EndIf
    Do row = 1, ny+1
      If ( heated%pb(row+1) <= heated%pb(row) ) Then
        Call invalidate(status,message,'heated CRS row pointers are not strictly ordered')
        Return
      EndIf
      Do entry = heated%pb(row), heated%pb(row+1)-1
        If ( heated%ridx(entry) /= row .or. heated%cidx(entry) < 1 .or. &
          & heated%cidx(entry) > ny+1 ) Then
          Call invalidate(status,message,'heated CRS coordinate is outside its declared row')
          Return
        EndIf
        If ( entry > heated%pb(row) ) Then
          If ( heated%cidx(entry) <= heated%cidx(entry-1) ) Then
            Call invalidate(status,message,'heated CRS columns are not strictly ordered')
            Return
          EndIf
        EndIf
      EndDo
      If ( count(heated%cidx(heated%pb(row):heated%pb(row+1)-1) == row) /= 1 ) Then
        Call invalidate(status,message,'heated CRS row does not contain exactly one diagonal')
        Return
      EndIf
    EndDo
    Do row = 1, ny
      entry = heated%pb(row+1) - 1
      If ( heated%ridx(entry) /= row .or. heated%cidx(entry) /= ny+1 ) Then
        Call invalidate(status,message,'heated CRS is missing an ordered temperature column entry')
        Return
      EndIf
    EndDo
    If ( any(heated%cidx(heated%pb(ny+1):heated%pb(ny+2)-1) /= (/ (row,row=1,ny+1) /)) ) Then
      Call invalidate(status,message,'heated CRS temperature row is incomplete')
      Return
    EndIf

    Call validate_remapped_indices(raw%ns11,heated%ns11,raw,heated,'ns11',status,message)
    If ( status /= sparse_ind_ok ) Return
    Call validate_remapped_indices(raw%ns21,heated%ns21,raw,heated,'ns21',status,message)
    If ( status /= sparse_ind_ok ) Return
    Call validate_remapped_indices(raw%ns22,heated%ns22,raw,heated,'ns22',status,message)
    If ( status /= sparse_ind_ok ) Return
    Call validate_remapped_indices(raw%ns31,heated%ns31,raw,heated,'ns31',status,message)
    If ( status /= sparse_ind_ok ) Return
    Call validate_remapped_indices(raw%ns32,heated%ns32,raw,heated,'ns32',status,message)
    If ( status /= sparse_ind_ok ) Return
    Call validate_remapped_indices(raw%ns33,heated%ns33,raw,heated,'ns33',status,message)
    If ( status /= sparse_ind_ok ) Return
    Call validate_remapped_indices(raw%ns41,heated%ns41,raw,heated,'ns41',status,message)
    If ( status /= sparse_ind_ok ) Return
    Call validate_remapped_indices(raw%ns42,heated%ns42,raw,heated,'ns42',status,message)
    If ( status /= sparse_ind_ok ) Return
    Call validate_remapped_indices(raw%ns43,heated%ns43,raw,heated,'ns43',status,message)
    If ( status /= sparse_ind_ok ) Return
    Call validate_remapped_indices(raw%ns44,heated%ns44,raw,heated,'ns44',status,message)

    Return
  End Subroutine validate_pardiso_heat

  Subroutine validate_remapped_indices(raw_map,heated_map,raw,heated,label,status,message)
    Implicit None

    Integer, Intent(in) :: raw_map(:), heated_map(:)
    Type(raw_sparse_ind_data), Intent(in) :: raw
    Type(pardiso_heat_data), Intent(in) :: heated
    Character(*), Intent(in) :: label
    Integer, Intent(out) :: status
    Character(*), Intent(out) :: message

    Integer :: reaction

    status = sparse_ind_ok
    message = ''
    If ( size(raw_map) /= size(heated_map) ) Then
      Call invalidate(status,message,trim(label)//' transformed size changed')
      Return
    EndIf
    Do reaction = 1, size(raw_map)
      If ( heated_map(reaction) < 1 .or. heated_map(reaction) > size(heated%ridx) ) Then
        Call invalidate(status,message,trim(label)//' transformed index is out of range')
        Return
      EndIf
      If ( heated%ridx(heated_map(reaction)) /= raw%ridx(raw_map(reaction)) .or. &
        & heated%cidx(heated_map(reaction)) /= raw%cidx(raw_map(reaction)) ) Then
        Call invalidate(status,message,trim(label)//' transformed coordinate changed')
        Return
      EndIf
    EndDo

    Return
  End Subroutine validate_remapped_indices

  Subroutine remap_indices(raw_map,raw_rows,heated_map)
    Implicit None

    Integer, Intent(in) :: raw_map(:), raw_rows(:)
    Integer, Allocatable, Intent(out) :: heated_map(:)

    Integer :: reaction

    Allocate (heated_map(size(raw_map)))
    Do reaction = 1, size(raw_map)
      heated_map(reaction) = raw_map(reaction) + raw_rows(raw_map(reaction)) - 1
    EndDo

    Return
  End Subroutine remap_indices

  Logical Function indices_in_range(indices,upper_bound)
    Implicit None

    Integer, Intent(in) :: indices(:), upper_bound

    indices_in_range = all(indices >= 1 .and. indices <= upper_bound)

    Return
  End Function indices_in_range

  Logical Function target_dimensions_match(map_sizes,n10,n11,n20,n21,n22,n30,n31,n32,n33, &
    & n40,n41,n42,n43,n44)
    Implicit None

    Integer, Intent(in) :: map_sizes(4)
    Integer, Intent(in) :: n10(:), n11(:), n20(:), n21(:), n22(:)
    Integer, Intent(in) :: n30(:), n31(:), n32(:), n33(:)
    Integer, Intent(in) :: n40(:), n41(:), n42(:), n43(:), n44(:)

    target_dimensions_match = size(n10) == map_sizes(1) .and. size(n11) == map_sizes(1) .and. &
      & size(n20) == map_sizes(2) .and. size(n21) == map_sizes(2) .and. &
      & size(n22) == map_sizes(2) .and. size(n30) == map_sizes(3) .and. &
      & size(n31) == map_sizes(3) .and. size(n32) == map_sizes(3) .and. &
      & size(n33) == map_sizes(3) .and. size(n40) == map_sizes(4) .and. &
      & size(n41) == map_sizes(4) .and. size(n42) == map_sizes(4) .and. &
      & size(n43) == map_sizes(4) .and. size(n44) == map_sizes(4)

    Return
  End Function target_dimensions_match

  Subroutine read_failure(status,message,record_name,io_message)
    Implicit None

    Integer, Intent(out) :: status
    Character(*), Intent(out) :: message
    Character(*), Intent(in) :: record_name, io_message

    status = sparse_ind_read_error
    message = trim(record_name)//': '//trim(io_message)

    Return
  End Subroutine read_failure

  Subroutine invalidate(status,message,reason)
    Implicit None

    Integer, Intent(out) :: status
    Character(*), Intent(out) :: message
    Character(*), Intent(in) :: reason

    status = sparse_ind_invalid
    message = trim(reason)

    Return
  End Subroutine invalidate

End Module xnet_sparse_contract
