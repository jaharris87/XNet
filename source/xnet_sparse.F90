!***************************************************************************************************
! Persisted sparse_ind data and CRS storage operations shared by sparse Jacobian providers.
!***************************************************************************************************

Module xnet_sparse
  Use, Intrinsic :: iso_fortran_env, Only: iostat_end, iostat_eor
  Implicit None
  Private

  Integer, Parameter, Public :: sparse_ind_ok = 0
  Integer, Parameter, Public :: sparse_ind_open_error = 1
  Integer, Parameter, Public :: sparse_ind_read_error = 2
  Integer, Parameter, Public :: sparse_ind_invalid = 3
  Integer, Parameter :: count_kind = selected_int_kind(18)

  Type, Public :: sparse_data
    Integer :: lval = 0
    Integer :: l1s = 0
    Integer :: l2s = 0
    Integer :: l3s = 0
    Integer :: l4s = 0
    Integer, Allocatable :: ridx(:), cidx(:), pb(:)
    Integer, Allocatable :: ns11(:), ns21(:), ns22(:)
    Integer, Allocatable :: ns31(:), ns32(:), ns33(:)
    Integer, Allocatable :: ns41(:), ns42(:), ns43(:), ns44(:)
  End Type sparse_data

  Public :: augment_crs_heat
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
    Type(sparse_data), Intent(out) :: data
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

    Call validate_record_sizes(file_name,data,status,io_status,message)
    If ( status /= sparse_ind_ok ) Return

    Call validate_sparse_ind(data,ny,n10,n11,n20,n21,n22,n30,n31,n32,n33, &
      & n40,n41,n42,n43,n44,status,message)

    Return
  End Subroutine read_sparse_ind

  Subroutine augment_crs_heat(sparse_ind,ny,sparse_ind_heat,status,message)
    !-----------------------------------------------------------------------------------------------
    ! Insert one self-heating column entry in every species row, append the complete temperature
    ! row, and remap persisted reaction locations without changing persisted-entry ordering.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    Type(sparse_data), Intent(in) :: sparse_ind
    Integer, Intent(in) :: ny
    Type(sparse_data), Intent(out) :: sparse_ind_heat
    Integer, Intent(out) :: status
    Character(*), Intent(out) :: message

    Integer :: new_end, new_start, nnz, old_end, old_start, row

    status = sparse_ind_ok
    message = ''
    Call validate_crs_topology(sparse_ind,ny,status,message)
    If ( status /= sparse_ind_ok ) Return
    Call validate_map_indices(sparse_ind,status,message)
    If ( status /= sparse_ind_ok ) Return

    nnz = sparse_ind%lval + 2*ny + 1
    sparse_ind_heat%lval = nnz
    sparse_ind_heat%l1s = sparse_ind%l1s
    sparse_ind_heat%l2s = sparse_ind%l2s
    sparse_ind_heat%l3s = sparse_ind%l3s
    sparse_ind_heat%l4s = sparse_ind%l4s
    Allocate (sparse_ind_heat%ridx(nnz),sparse_ind_heat%cidx(nnz),sparse_ind_heat%pb(ny+2))
    sparse_ind_heat%pb(1) = sparse_ind%pb(1)
    Do row = 1, ny
      old_start = sparse_ind%pb(row)
      old_end = sparse_ind%pb(row+1) - 1
      new_start = sparse_ind_heat%pb(row)
      new_end = new_start + old_end - old_start
      sparse_ind_heat%ridx(new_start:new_end) = sparse_ind%ridx(old_start:old_end)
      sparse_ind_heat%cidx(new_start:new_end) = sparse_ind%cidx(old_start:old_end)
      sparse_ind_heat%ridx(new_end+1) = row
      sparse_ind_heat%cidx(new_end+1) = ny + 1
      sparse_ind_heat%pb(row+1) = new_end + 2
    EndDo
    sparse_ind_heat%pb(ny+2) = nnz + 1
    new_start = sparse_ind_heat%pb(ny+1)
    Do row = 1, ny+1
      sparse_ind_heat%ridx(new_start+row-1) = ny + 1
      sparse_ind_heat%cidx(new_start+row-1) = row
    EndDo

    Call remap_indices(sparse_ind%ns11,sparse_ind%ridx,sparse_ind_heat%ns11)
    Call remap_indices(sparse_ind%ns21,sparse_ind%ridx,sparse_ind_heat%ns21)
    Call remap_indices(sparse_ind%ns22,sparse_ind%ridx,sparse_ind_heat%ns22)
    Call remap_indices(sparse_ind%ns31,sparse_ind%ridx,sparse_ind_heat%ns31)
    Call remap_indices(sparse_ind%ns32,sparse_ind%ridx,sparse_ind_heat%ns32)
    Call remap_indices(sparse_ind%ns33,sparse_ind%ridx,sparse_ind_heat%ns33)
    Call remap_indices(sparse_ind%ns41,sparse_ind%ridx,sparse_ind_heat%ns41)
    Call remap_indices(sparse_ind%ns42,sparse_ind%ridx,sparse_ind_heat%ns42)
    Call remap_indices(sparse_ind%ns43,sparse_ind%ridx,sparse_ind_heat%ns43)
    Call remap_indices(sparse_ind%ns44,sparse_ind%ridx,sparse_ind_heat%ns44)

    Call validate_crs_heat(sparse_ind,sparse_ind_heat,ny,status,message)

    Return
  End Subroutine augment_crs_heat

  Subroutine validate_sparse_ind(data,ny,n10,n11,n20,n21,n22,n30,n31,n32,n33, &
    & n40,n41,n42,n43,n44,status,message)
    Implicit None

    Type(sparse_data), Intent(in) :: data
    Integer, Intent(in) :: ny
    Integer, Intent(in) :: n10(:), n11(:), n20(:), n21(:), n22(:)
    Integer, Intent(in) :: n30(:), n31(:), n32(:), n33(:)
    Integer, Intent(in) :: n40(:), n41(:), n42(:), n43(:), n44(:)
    Integer, Intent(out) :: status
    Character(*), Intent(out) :: message

    status = sparse_ind_ok
    message = ''
    Call validate_crs_topology(data,ny,status,message)
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
  End Subroutine validate_sparse_ind

  Subroutine validate_crs_topology(data,ny,status,message)
    Implicit None

    Type(sparse_data), Intent(in) :: data
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
  End Subroutine validate_crs_topology

  Subroutine validate_map_indices(data,status,message)
    Implicit None

    Type(sparse_data), Intent(in) :: data
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
  End Subroutine validate_map_indices

  Subroutine validate_map(map,row_index,column_index,data,label,status,message)
    Implicit None

    Integer, Intent(in) :: map(:), row_index(:), column_index(:)
    Type(sparse_data), Intent(in) :: data
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

  Subroutine validate_crs_heat(sparse_ind,sparse_ind_heat,ny,status,message)
    Implicit None

    Type(sparse_data), Intent(in) :: sparse_ind
    Type(sparse_data), Intent(in) :: sparse_ind_heat
    Integer, Intent(in) :: ny
    Integer, Intent(out) :: status
    Character(*), Intent(out) :: message

    Integer :: entry, nnz, row

    status = sparse_ind_ok
    message = ''
    nnz = sparse_ind%lval + 2*ny + 1
    If ( sparse_ind_heat%lval /= nnz .or. sparse_ind_heat%l1s /= sparse_ind%l1s .or. &
      & sparse_ind_heat%l2s /= sparse_ind%l2s .or. sparse_ind_heat%l3s /= sparse_ind%l3s .or. &
      & sparse_ind_heat%l4s /= sparse_ind%l4s ) Then
      Call invalidate(status,message,'self-heating CRS metadata are incompatible')
      Return
    EndIf
    If ( size(sparse_ind_heat%ridx) /= nnz .or. size(sparse_ind_heat%cidx) /= nnz .or. &
      & size(sparse_ind_heat%pb) /= ny+2 ) Then
      Call invalidate(status,message,'self-heating CRS dimensions are incompatible')
      Return
    EndIf
    If ( sparse_ind_heat%pb(1) /= 1 .or. sparse_ind_heat%pb(ny+2) /= nnz+1 ) Then
      Call invalidate(status,message,'self-heating CRS has wrong terminal pointer')
      Return
    EndIf
    Do row = 1, ny+1
      If ( sparse_ind_heat%pb(row+1) <= sparse_ind_heat%pb(row) ) Then
        Call invalidate(status,message,'self-heating CRS row pointers are not strictly ordered')
        Return
      EndIf
      Do entry = sparse_ind_heat%pb(row), sparse_ind_heat%pb(row+1)-1
        If ( sparse_ind_heat%ridx(entry) /= row .or. sparse_ind_heat%cidx(entry) < 1 .or. &
          & sparse_ind_heat%cidx(entry) > ny+1 ) Then
          Call invalidate(status,message,'self-heating CRS coordinate is outside its declared row')
          Return
        EndIf
        If ( entry > sparse_ind_heat%pb(row) ) Then
          If ( sparse_ind_heat%cidx(entry) <= sparse_ind_heat%cidx(entry-1) ) Then
            Call invalidate(status,message,'self-heating CRS columns are not strictly ordered')
            Return
          EndIf
        EndIf
      EndDo
      If ( count(sparse_ind_heat%cidx(sparse_ind_heat%pb(row): &
        & sparse_ind_heat%pb(row+1)-1) == row) /= 1 ) Then
        Call invalidate(status,message,'self-heating CRS row does not contain exactly one diagonal')
        Return
      EndIf
    EndDo
    Do row = 1, ny
      entry = sparse_ind_heat%pb(row+1) - 1
      If ( sparse_ind_heat%ridx(entry) /= row .or. sparse_ind_heat%cidx(entry) /= ny+1 ) Then
        Call invalidate(status,message, &
          & 'self-heating CRS is missing an ordered temperature column entry')
        Return
      EndIf
    EndDo
    If ( any(sparse_ind_heat%cidx(sparse_ind_heat%pb(ny+1):sparse_ind_heat%pb(ny+2)-1) /= &
      & (/ (row,row=1,ny+1) /)) ) Then
      Call invalidate(status,message,'self-heating CRS temperature row is incomplete')
      Return
    EndIf

    Call validate_remapped_indices(sparse_ind%ns11,sparse_ind_heat%ns11,sparse_ind, &
      & sparse_ind_heat,'ns11',status,message)
    If ( status /= sparse_ind_ok ) Return
    Call validate_remapped_indices(sparse_ind%ns21,sparse_ind_heat%ns21,sparse_ind, &
      & sparse_ind_heat,'ns21',status,message)
    If ( status /= sparse_ind_ok ) Return
    Call validate_remapped_indices(sparse_ind%ns22,sparse_ind_heat%ns22,sparse_ind, &
      & sparse_ind_heat,'ns22',status,message)
    If ( status /= sparse_ind_ok ) Return
    Call validate_remapped_indices(sparse_ind%ns31,sparse_ind_heat%ns31,sparse_ind, &
      & sparse_ind_heat,'ns31',status,message)
    If ( status /= sparse_ind_ok ) Return
    Call validate_remapped_indices(sparse_ind%ns32,sparse_ind_heat%ns32,sparse_ind, &
      & sparse_ind_heat,'ns32',status,message)
    If ( status /= sparse_ind_ok ) Return
    Call validate_remapped_indices(sparse_ind%ns33,sparse_ind_heat%ns33,sparse_ind, &
      & sparse_ind_heat,'ns33',status,message)
    If ( status /= sparse_ind_ok ) Return
    Call validate_remapped_indices(sparse_ind%ns41,sparse_ind_heat%ns41,sparse_ind, &
      & sparse_ind_heat,'ns41',status,message)
    If ( status /= sparse_ind_ok ) Return
    Call validate_remapped_indices(sparse_ind%ns42,sparse_ind_heat%ns42,sparse_ind, &
      & sparse_ind_heat,'ns42',status,message)
    If ( status /= sparse_ind_ok ) Return
    Call validate_remapped_indices(sparse_ind%ns43,sparse_ind_heat%ns43,sparse_ind, &
      & sparse_ind_heat,'ns43',status,message)
    If ( status /= sparse_ind_ok ) Return
    Call validate_remapped_indices(sparse_ind%ns44,sparse_ind_heat%ns44,sparse_ind, &
      & sparse_ind_heat,'ns44',status,message)

    Return
  End Subroutine validate_crs_heat

  Subroutine validate_remapped_indices(sparse_ind_map,sparse_ind_heat_map,sparse_ind, &
    & sparse_ind_heat,label,status,message)
    Implicit None

    Integer, Intent(in) :: sparse_ind_map(:), sparse_ind_heat_map(:)
    Type(sparse_data), Intent(in) :: sparse_ind
    Type(sparse_data), Intent(in) :: sparse_ind_heat
    Character(*), Intent(in) :: label
    Integer, Intent(out) :: status
    Character(*), Intent(out) :: message

    Integer :: reaction

    status = sparse_ind_ok
    message = ''
    If ( size(sparse_ind_map) /= size(sparse_ind_heat_map) ) Then
      Call invalidate(status,message,trim(label)//' self-heating size changed')
      Return
    EndIf
    Do reaction = 1, size(sparse_ind_map)
      If ( sparse_ind_heat_map(reaction) < 1 .or. &
        & sparse_ind_heat_map(reaction) > size(sparse_ind_heat%ridx) ) Then
        Call invalidate(status,message,trim(label)//' self-heating index is out of range')
        Return
      EndIf
      If ( sparse_ind_heat%ridx(sparse_ind_heat_map(reaction)) /= &
        & sparse_ind%ridx(sparse_ind_map(reaction)) .or. &
        & sparse_ind_heat%cidx(sparse_ind_heat_map(reaction)) /= &
        & sparse_ind%cidx(sparse_ind_map(reaction)) ) Then
        Call invalidate(status,message,trim(label)//' self-heating coordinate changed')
        Return
      EndIf
    EndDo

    Return
  End Subroutine validate_remapped_indices

  Subroutine remap_indices(sparse_ind_map,sparse_ind_rows,sparse_ind_heat_map)
    Implicit None

    Integer, Intent(in) :: sparse_ind_map(:), sparse_ind_rows(:)
    Integer, Allocatable, Intent(out) :: sparse_ind_heat_map(:)

    Integer :: reaction

    Allocate (sparse_ind_heat_map(size(sparse_ind_map)))
    Do reaction = 1, size(sparse_ind_map)
      sparse_ind_heat_map(reaction) = sparse_ind_map(reaction) + &
        & sparse_ind_rows(sparse_ind_map(reaction)) - 1
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

  Subroutine validate_record_sizes(file_name,data,status,io_status,message)
    !-----------------------------------------------------------------------------------------------
    ! The ordinary pass has already shown that every required field is present. Probe each record on
    ! a fresh unit with one extra character, then close that unit immediately after the target read.
    ! Thus an exact record fails only the probe read, while the successful data-read unit is never
    ! used after an error and any unexpected file-storage unit is detected.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    Character(*), Intent(in) :: file_name
    Type(sparse_data), Intent(in) :: data
    Integer, Intent(out) :: status, io_status
    Character(*), Intent(out) :: message

    Character(1) :: record_probe
    Integer :: lun_probe
    Type(sparse_data) :: probe_data

    status = sparse_ind_ok
    io_status = 0
    message = ''
    Allocate (probe_data%ridx(size(data%ridx)),probe_data%cidx(size(data%cidx)), &
      & probe_data%pb(size(data%pb)))
    Allocate (probe_data%ns11(size(data%ns11)))
    Allocate (probe_data%ns21(size(data%ns21)),probe_data%ns22(size(data%ns22)))
    Allocate (probe_data%ns31(size(data%ns31)),probe_data%ns32(size(data%ns32)), &
      & probe_data%ns33(size(data%ns33)))
    Allocate (probe_data%ns41(size(data%ns41)),probe_data%ns42(size(data%ns42)), &
      & probe_data%ns43(size(data%ns43)),probe_data%ns44(size(data%ns44)))

    Call start_record_probe(file_name,1,'header record',lun_probe,status,io_status,message)
    If ( status /= sparse_ind_ok ) Return
    Read(lun_probe,iostat=io_status) probe_data%lval, record_probe
    Call finish_record_probe(lun_probe,'header record',status,io_status,message)
    If ( status /= sparse_ind_ok ) Return

    Call start_record_probe(file_name,2,'topology record',lun_probe,status,io_status,message)
    If ( status /= sparse_ind_ok ) Return
    Read(lun_probe,iostat=io_status) probe_data%ridx, probe_data%cidx, probe_data%pb, record_probe
    Call finish_record_probe(lun_probe,'topology record',status,io_status,message)
    If ( status /= sparse_ind_ok ) Return

    Call start_record_probe(file_name,3,'reaction-map dimension record',lun_probe,status, &
      & io_status,message)
    If ( status /= sparse_ind_ok ) Return
    Read(lun_probe,iostat=io_status) probe_data%l1s, probe_data%l2s, probe_data%l3s, &
      & probe_data%l4s, record_probe
    Call finish_record_probe(lun_probe,'reaction-map dimension record',status,io_status,message)
    If ( status /= sparse_ind_ok ) Return

    Call start_record_probe(file_name,4,'one/two-reactant map record',lun_probe,status, &
      & io_status,message)
    If ( status /= sparse_ind_ok ) Return
    Read(lun_probe,iostat=io_status) probe_data%ns11, probe_data%ns21, probe_data%ns22, &
      & record_probe
    Call finish_record_probe(lun_probe,'one/two-reactant map record',status,io_status,message)
    If ( status /= sparse_ind_ok ) Return

    Call start_record_probe(file_name,5,'ns31 map record',lun_probe,status,io_status,message)
    If ( status /= sparse_ind_ok ) Return
    Read(lun_probe,iostat=io_status) probe_data%ns31, record_probe
    Call finish_record_probe(lun_probe,'ns31 map record',status,io_status,message)
    If ( status /= sparse_ind_ok ) Return

    Call start_record_probe(file_name,6,'ns32 map record',lun_probe,status,io_status,message)
    If ( status /= sparse_ind_ok ) Return
    Read(lun_probe,iostat=io_status) probe_data%ns32, record_probe
    Call finish_record_probe(lun_probe,'ns32 map record',status,io_status,message)
    If ( status /= sparse_ind_ok ) Return

    Call start_record_probe(file_name,7,'ns33 map record',lun_probe,status,io_status,message)
    If ( status /= sparse_ind_ok ) Return
    Read(lun_probe,iostat=io_status) probe_data%ns33, record_probe
    Call finish_record_probe(lun_probe,'ns33 map record',status,io_status,message)
    If ( status /= sparse_ind_ok ) Return

    Call start_record_probe(file_name,8,'ns41 map record',lun_probe,status,io_status,message)
    If ( status /= sparse_ind_ok ) Return
    Read(lun_probe,iostat=io_status) probe_data%ns41, record_probe
    Call finish_record_probe(lun_probe,'ns41 map record',status,io_status,message)
    If ( status /= sparse_ind_ok ) Return

    Call start_record_probe(file_name,9,'ns42 map record',lun_probe,status,io_status,message)
    If ( status /= sparse_ind_ok ) Return
    Read(lun_probe,iostat=io_status) probe_data%ns42, record_probe
    Call finish_record_probe(lun_probe,'ns42 map record',status,io_status,message)
    If ( status /= sparse_ind_ok ) Return

    Call start_record_probe(file_name,10,'ns43 map record',lun_probe,status,io_status,message)
    If ( status /= sparse_ind_ok ) Return
    Read(lun_probe,iostat=io_status) probe_data%ns43, record_probe
    Call finish_record_probe(lun_probe,'ns43 map record',status,io_status,message)
    If ( status /= sparse_ind_ok ) Return

    Call start_record_probe(file_name,11,'ns44 map record',lun_probe,status,io_status,message)
    If ( status /= sparse_ind_ok ) Return
    Read(lun_probe,iostat=io_status) probe_data%ns44, record_probe
    Call finish_record_probe(lun_probe,'ns44 map record',status,io_status,message)

    Return
  End Subroutine validate_record_sizes

  Subroutine start_record_probe(file_name,record_number,record_name,lun,status,io_status,message)
    Implicit None

    Character(*), Intent(in) :: file_name
    Integer, Intent(in) :: record_number
    Character(*), Intent(in) :: record_name
    Integer, Intent(out) :: lun
    Integer, Intent(out) :: status, io_status
    Character(*), Intent(out) :: message

    Character(256) :: io_message
    Integer :: record

    status = sparse_ind_ok
    io_status = 0
    message = ''
    Open(newunit=lun,file=trim(file_name),status='old',action='read',form='unformatted', &
      & iostat=io_status,iomsg=io_message)
    If ( io_status /= 0 ) Then
      status = sparse_ind_open_error
      message = trim(io_message)
      Return
    EndIf
    Do record = 1, record_number-1
      Read(lun,iostat=io_status,iomsg=io_message)
      If ( io_status /= 0 ) Then
        Call read_failure(status,message,trim(record_name)//' probe setup',io_message)
        Close(lun)
        Return
      EndIf
    EndDo

    Return
  End Subroutine start_record_probe

  Subroutine finish_record_probe(lun,record_name,status,io_status,message)
    Implicit None

    Integer, Intent(in) :: lun
    Character(*), Intent(in) :: record_name
    Integer, Intent(out) :: status
    Integer, Intent(inout) :: io_status
    Character(*), Intent(out) :: message

    Character(256) :: io_message
    Integer :: close_status

    status = sparse_ind_ok
    message = ''
    Close(lun,iostat=close_status,iomsg=io_message)
    If ( close_status /= 0 ) Then
      Call read_failure(status,message,trim(record_name)//' probe close',io_message)
      io_status = close_status
      Return
    EndIf
    If ( io_status == 0 ) Then
      Call invalidate(status,message,trim(record_name)//' contains unexpected data')
    ElseIf ( io_status == iostat_end .or. io_status == iostat_eor ) Then
      Call read_failure(status,message,trim(record_name)//' size probe', &
        & 'unexpected end condition while checking record size')
    ElseIf ( io_status < 0 ) Then
      Call read_failure(status,message,trim(record_name)//' size probe', &
        & 'unexpected input condition while checking record size')
    Else
      ! Sequential-unformatted input past a record is an error, not the named nonadvancing EOR
      ! condition. The positive status is consumed only on this fresh unit, which is now closed.
      io_status = 0
    EndIf

    Return
  End Subroutine finish_record_probe

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

End Module xnet_sparse
