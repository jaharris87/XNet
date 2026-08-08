Program verify_build_net_readers
  Use nuclear_data, Only: nname, ny, read_nuclear_data
  Use reaction_data, Only: nreac, read_reaction_data
  Use xnet_controls, Only: idiag, iheat, iscrn, iweak0, nzevolve, nzbatchmx, szbatch, tid, &
    & zb_hi, zb_lo
  Use xnet_jacobian, Only: cidx, pb, read_jacobian_data
  Use xnet_match, Only: mflx, nflx, read_match_data
  Implicit None

  Character(80) :: data_desc
  Character(256) :: data_dir
  Integer :: diagonal, i, row

  If ( command_argument_count() /= 1 ) Then
    Write(*,*) 'usage: verify_build_net_readers DATA_DIR'
    Stop 1
  EndIf
  Call get_command_argument(1,data_dir)

  idiag = -1
  iheat = 0
  iscrn = 0
  iweak0 = 1
  nzbatchmx = 1
  nzevolve = 1
  szbatch = 1
  tid = 1
  zb_lo = 1
  zb_hi = 1

  Call read_nuclear_data(trim(data_dir),data_desc)
  Call read_reaction_data(trim(data_dir))
  Call read_match_data(trim(data_dir))
  Call read_jacobian_data(trim(data_dir))

  Call require(ny == 5,'production nuclear reader returned the wrong species count')
  Call require(all(nname(1:ny) == (/ '    n', '    p', '  he4', '  c12', '  o16' /)), &
    & 'production nuclear reader returned the wrong species order')
  Call require(all(nreac == (/ 3, 1, 0, 0 /)),'production reaction reader returned the wrong counts')
  Call require(mflx == 3,'production match reader returned the wrong rate-match count')
  Call require(all(nflx >= 0) .and. all(nflx <= ny), &
    & 'production match reader returned an out-of-range species')

  Call require(size(pb) == ny+1,'production sparse reader returned the wrong row-pointer size')
  Call require(pb(1) == 1 .and. pb(ny+1) == size(cidx)+1, &
    & 'production sparse reader returned inconsistent terminal pointers')
  Call require(all(pb(2:) >= pb(:ny)),'production sparse reader returned nonmonotone row pointers')
  Call require(all(cidx >= 1) .and. all(cidx <= ny), &
    & 'production sparse reader returned an out-of-range column')
  Do row = 1, ny
    diagonal = 0
    Do i = pb(row), pb(row+1)-1
      If ( cidx(i) == row ) diagonal = diagonal + 1
    EndDo
    Call require(diagonal == 1,'production sparse reader row lacks exactly one diagonal')
  EndDo

  Write(*,*) 'build_net production readers passed'

Contains

  Subroutine require(condition,message)
    Implicit None

    Logical, Intent(in) :: condition
    Character(*), Intent(in) :: message

    If ( .not. condition ) Then
      Write(*,*) trim(message)
      Stop 1
    EndIf

    Return
  End Subroutine require

End Program verify_build_net_readers
