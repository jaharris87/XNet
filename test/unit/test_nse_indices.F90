#include "xnet_macros.fh"

Program nse_index_tests
  ! Exercise index safety with real network data and subsets, including n/p only.
  Use, Intrinsic :: ieee_arithmetic, Only: ieee_is_finite
  Use nuclear_data, Only: aa, angm, be, g, ia, iz, izmax, mex, mm, ng, nname, nn, ny, t9i, &
    & zz, zseq, zseq53, zseqi
  Use xnet_constants, Only: avn, bip1, five3rd
  Use xnet_controls, Only: iscrn
  Use xnet_nse, Only: i_nn, i_pp, i_he4, i_si28, i_ni56, nse_initialize, &
    & nse_finalize, nse_solve, nse_guess, xnse
  Use xnet_types, Only: dp
  Implicit None

  Character(512) :: filename, mode_argument, snapshot_argument
  Character(5) :: record_name
  Integer :: lun, i, j, cycle, mode, nfull, it9i(ng), failures, first_mode, last_mode, guess, workers, neutron_index, proton_index
  Integer, Allocatable :: afull(:), zfull(:)
  Character(5), Allocatable :: names(:)
  Real(dp), Allocatable :: masses(:), spins(:), partitions(:,:), reference(:)
  Real(dp) :: spin, ye, uvec(2)
  Logical, Allocatable :: selected(:)

  Call get_command_argument(1,filename)
  Open(newunit=lun,file=trim(filename),status='old',action='read')
  Read(lun,'(i5)') nfull
  Read(lun,'(24i3)') it9i
  Allocate(afull(nfull),zfull(nfull),names(nfull),masses(nfull), &
    & spins(nfull),partitions(ng,nfull),selected(nfull))
  Do i = 1, nfull
    Read(lun,'(a5)') names(i)
  EndDo
  Do i = 1, nfull
    Read(lun,*) record_name, spin, zfull(i), j, spins(i), masses(i)
    afull(i) = nint(spin)
    spins(i) = 2.0_dp*spins(i) + 1.0_dp
    Read(lun,*) partitions(:,i)
  EndDo
  Close(lun)
  neutron_index = minloc(zfull,1,mask=afull == 1)
  proton_index = maxloc(zfull,1,mask=afull == 1)
  If ( neutron_index == 0 .OR. proton_index == 0 ) Stop 4
  If ( zfull(neutron_index) /= 0 .OR. zfull(proton_index) /= 1 ) Stop 4

  first_mode = 1
  last_mode = 5
  Call get_command_argument(2,mode_argument)
  If ( len_trim(mode_argument) > 0 ) Then
    Read(mode_argument,*) first_mode
    last_mode = first_mode
  EndIf
  Call get_command_argument(3,snapshot_argument)
  ! 1: complete; 2: light; 3: no He4/Si28; 4: no common Fe/Ni; 5: n/p only.
  Do mode = first_mode, last_mode
    selected = .True.
    If ( mode == 2 ) selected = zfull < 20
    If ( mode == 3 ) selected = .Not. ((zfull == 2 .AND. afull == 4) .OR. &
      & (zfull == 14 .AND. afull == 28))
    If ( mode == 4 ) selected = .Not. ((zfull == 26 .OR. zfull == 28) .AND. &
      & (afull == 52 .OR. afull == 54 .OR. afull == 56 .OR. afull == 58))
    If ( mode == 5 ) selected = afull == 1
    ny = count(selected)
    If ( ny < 2 ) Cycle
    Allocate(ia(ny),iz(ny),aa(ny),zz(ny),nn(ny),mm(ny),be(ny), &
      & mex(ny),nname(ny),angm(ny),g(ng,ny),t9i(ng),reference(ny))
    ia = pack(afull,selected)
    iz = pack(zfull,selected)
    aa = real(ia,dp)
    zz = real(iz,dp)
    nn = aa - zz
    mm = aa/avn
    mex = pack(masses,selected)
    be = nn*masses(neutron_index) + zz*masses(proton_index) - mex
    nname = pack(names,selected)
    angm = pack(spins,selected)
    Do j = 1, ng
      g(j,:) = pack(partitions(j,:),selected)
    EndDo
    t9i = real(it9i,dp)
    t9i(:ng-1) = t9i(:ng-1)*0.01_dp
    t9i(ng) = t9i(ng)*0.1_dp
    izmax = maxval(iz)
    Allocate(zseq(0:izmax+2),zseq53(0:izmax+2),zseqi(0:izmax+2))
    zseq = (/ (real(j,dp),j=0,izmax+2) /)
    zseq53 = zseq**five3rd
    zseqi = zseq**bip1
    iscrn = 0
    Do cycle = 1, 2
      Call nse_initialize
      If ( any((/i_nn,i_pp,i_he4,i_si28,i_ni56/) < 1) .OR. &
        & any((/i_nn,i_pp,i_he4,i_si28,i_ni56/) > ny) ) Stop 1
      ! Different Ye values exercise each worker's own characteristic indices.
      failures = 0
      workers = 0
      !XOMP parallel default(shared) private(ye,j,guess,uvec) reduction(+:failures,workers)
      workers = workers + 1
      !XOMP do
      Do j = 1, 3
        ye = 0.45_dp + 0.05_dp*real(j-1,dp)
        Call nse_solve(1.0e6_dp,20.0_dp,ye)
        If ( .Not. all(ieee_is_finite(xnse)) ) failures = failures + 1
        If ( any(xnse < 0.0_dp) ) failures = failures + 1
        If ( abs(sum(xnse)-1.0_dp) > 1.0e-7_dp ) failures = failures + 1
        If ( abs(sum(zz*xnse/aa)-ye) > 1.0e-7_dp ) failures = failures + 1
        ! Force later heuristics even when the first solve guess converges. This
        ! checks valid finite guesses, not convergence of each individual guess.
        Do guess = 1, 6
          Call nse_guess(guess,uvec)
          If ( .Not. all(ieee_is_finite(uvec)) ) failures = failures + 1
        EndDo
      EndDo
      !XOMP end do
      !XOMP end parallel
      If ( failures /= 0 ) Stop 2
      ! Serial snapshot checks repeated lifecycle independence.
      Call nse_solve(1.0e6_dp,20.0_dp,0.5_dp)
      If ( cycle == 1 ) Then
        reference = xnse
      Else
        If ( any(xnse /= reference) ) Stop 3
      EndIf
      If ( mode == 1 .AND. cycle == 1 .AND. snapshot_argument == 'snapshot' ) Then
        Do i = 1, ny
          Write(*,'(a,1x,a5,1x,es25.17)') 'BASELINE',nname(i),xnse(i)
        EndDo
      EndIf
      Call nse_finalize
    EndDo
    Write(*,'(a,i0,a,i0,a,i0)') 'PASS NSE indices mode=',mode,' ny=',ny,' workers=',workers
    Deallocate(ia,iz,aa,zz,nn,mm,be,mex,nname,angm,g,t9i,reference,zseq,zseq53,zseqi)
  EndDo
End Program nse_index_tests
