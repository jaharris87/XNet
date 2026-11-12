Module sparse_component_fixture
#ifdef XNET_OMP
  Use omp_lib, Only: omp_get_max_threads, omp_get_thread_num
#endif
  Use nuclear_data, Only: mex, nname, ny
  Use reaction_data, Only: a1, a2, a3, a4, b1, b2, b3, b4, dcsect1dt9, dcsect2dt9, &
    & dcsect3dt9, dcsect4dt9, la, le, mu1, mu2, mu3, mu4, n10, n11, n20, n21, &
    & n22, n30, n31, n32, n33, n40, n41, n42, n43, n44, nan
  Use xnet_abundances, Only: yt
  Use xnet_conditions, Only: cv
  Use xnet_controls, Only: idiag, iheat, kitmx, kmon, ktot, lzactive, lun_diag, nzbatch, nzbatchmx, szbatch, tid
#if defined(TEST_DENSE)
  Use xnet_jacobian, Only: msize, read_jacobian_data, jacobian_finalize
#else
  Use xnet_jacobian, Only: cidx, msize, nnz, ns11, pb, read_jacobian_data, jacobian_finalize
#endif
  Use xnet_types, Only: dp
  Implicit None
  Private

  Logical :: heat_mode = .False.
  Logical :: tracked_controls = .False.
  Logical, Public :: workers_mode = .false.
  Character(256) :: component_data_dir

  Public :: expected_matrix
  Public :: heat_mode
  Public :: initialize_component
  Public :: tracked_controls
  Public :: component_data_dir

Contains

  Subroutine initialize_component(mode,data_dir)
    Implicit None

    Character(*), Intent(in) :: mode, data_dir

    Call jacobian_finalize
    component_data_dir = data_dir
    heat_mode = trim(mode) == 'heat' .or. trim(mode) == 'workers-heat'
#ifdef XNET_OMP
    workers_mode = trim(mode) == 'workers' .or. trim(mode) == 'workers-heat'
#endif
    If ( trim(mode) /= 'base' .and. trim(mode) /= 'failure' .and. .not. heat_mode .and. .not. workers_mode ) Then
      Write(*,*) 'mode must be base, heat, or failure'
      Stop 1
    EndIf

    ny = 3
    nzbatchmx = 2
    nzbatch = 2
    szbatch = 1
#ifdef XNET_OMP
    !$omp parallel default(shared)
    tid = omp_get_thread_num()+1
    szbatch = 1
    !$omp end parallel
#endif
    idiag = 5
    lun_diag = 77
    Open(unit=lun_diag,status='scratch',action='write')
    iheat = 0
    If ( heat_mode ) iheat = 1
    kitmx = 5

    Allocate (mex(ny),nname(ny))
    mex = (/ 1.0_dp, 2.0_dp, 3.0_dp /)
    nname = (/ '   n1', '   n2', '   n3' /)
    Allocate (lzactive(nzbatchmx),kmon(2,nzbatchmx),ktot(3,nzbatchmx))
    lzactive = .True.
    kmon = 0
    ktot = 0
    Allocate (yt(ny,nzbatchmx),cv(nzbatchmx))
    yt = 1.0_dp
    cv = 1.0_dp

    Allocate (nan(4))
    nan = (/ 3, 2, 1, 1 /)
    Allocate (la(4,ny),le(4,ny))
    la = 1
    le = 0
    la(1,:) = (/ 1, 2, 3 /)
    le(1,:) = (/ 1, 2, 3 /)
    la(2,:) = (/ 1, 2, 3 /)
    le(2,:) = (/ 1, 2, 2 /)
    la(3,:) = (/ 1, 1, 1 /)
    le(3,:) = (/ 0, 0, 1 /)
    la(4,:) = (/ 1, 1, 2 /)
    le(4,:) = (/ 0, 1, 1 /)

    Allocate (n10(3),n11(3),mu1(3),a1(3),b1(3,nzbatchmx),dcsect1dt9(3,nzbatchmx))
    n10 = (/ 1, 2, 3 /)
    n11 = (/ 2, 3, 2 /)
    Allocate (n20(2),n21(2),n22(2),mu2(2),a2(2),b2(2,nzbatchmx),dcsect2dt9(2,nzbatchmx))
    n20 = (/ 1, 2 /)
    n21 = (/ 1, 1 /)
    n22 = (/ 2, 3 /)
    Allocate (n30(1),n31(1),n32(1),n33(1),mu3(1),a3(1),b3(1,nzbatchmx), &
      & dcsect3dt9(1,nzbatchmx))
    n30 = 3
    n31 = 2
    n32 = 3
    n33 = 2
    Allocate (n40(1),n41(1),n42(1),n43(1),n44(1),mu4(1),a4(1),b4(1,nzbatchmx), &
      & dcsect4dt9(1,nzbatchmx))
    n40 = 2
    n41 = 1
    n42 = 2
    n43 = 3
    n44 = 1
    mu1 = (/ 1, 2, 3 /)
    mu2 = (/ 1, 2 /)
    mu3 = 1
    mu4 = 1
    a1 = 1.0_dp
    a2 = 1.0_dp
    a3 = 1.0_dp
    a4 = 1.0_dp
    b1 = 0.0_dp
    b2 = 0.0_dp
    b3 = 0.0_dp
    b4 = 0.0_dp
    dcsect1dt9 = 0.0_dp
    dcsect2dt9 = 0.0_dp
    dcsect3dt9 = 0.0_dp
    dcsect4dt9 = 0.0_dp

#if !defined(TEST_DENSE)
    Call write_sparse_file(data_dir)
    Call write_sparse_controls
#endif
#ifdef XNET_OMP
    !$omp parallel default(shared) copyin(lzactive,kmon,ktot,yt,cv,b1,b2,b3,b4) &
    !$omp   copyin(dcsect1dt9,dcsect2dt9,dcsect3dt9,dcsect4dt9)
    !$omp end parallel
#endif
    Call read_jacobian_data(data_dir)
#if !defined(TEST_DENSE)
    Call apply_effectiveness_mutation
#endif

    Return
  End Subroutine initialize_component

#if !defined(TEST_DENSE)
  Subroutine write_sparse_file(data_dir)
    Implicit None

    Character(*), Intent(in) :: data_dir

    Character(32) :: input_mutation
    Integer, Parameter :: lval_fixture = 7
    Integer :: cidx_fixture(lval_fixture), length, lun_sparse, pb_fixture(4)
    Integer :: ridx_fixture(lval_fixture), variable_status
    Integer :: ns11_fixture(3), ns21_fixture(2), ns22_fixture(2)
    Integer :: ns31_fixture(1), ns32_fixture(1), ns33_fixture(1)
    Integer :: ns41_fixture(1), ns42_fixture(1), ns43_fixture(1), ns44_fixture(1)

    ridx_fixture = (/ 1, 1, 2, 2, 2, 3, 3 /)
    cidx_fixture = (/ 1, 2, 1, 2, 3, 2, 3 /)
    pb_fixture = (/ 1, 3, 6, 8 /)
    ns11_fixture = (/ 2, 5, 6 /)
    ns21_fixture = (/ 1, 3 /)
    ns22_fixture = (/ 2, 5 /)
    ns31_fixture = 6
    ns32_fixture = 7
    ns33_fixture = 6
    ns41_fixture = 3
    ns42_fixture = 4
    ns43_fixture = 5
    ns44_fixture = 3

    input_mutation = ''
    Call get_environment_variable('XNET_SPARSE_INPUT_MUTATION',input_mutation, &
      & length=length,status=variable_status)
    If ( variable_status == 0 ) Then
      If ( input_mutation(1:length) == 'missing-file' ) Return
    EndIf

    Open(newunit=lun_sparse,file=trim(data_dir)//'/sparse_ind',status='replace',form='unformatted')
    If ( variable_status == 0 ) Then
      If ( input_mutation(1:length) == 'truncated-header' ) Then
        Close(lun_sparse)
        Return
      EndIf
    EndIf
    Write(lun_sparse) lval_fixture
    Write(lun_sparse) ridx_fixture, cidx_fixture, pb_fixture
    Write(lun_sparse) 3, 2, 1, 1
    Write(lun_sparse) ns11_fixture, ns21_fixture, ns22_fixture
    Write(lun_sparse) ns31_fixture
    Write(lun_sparse) ns32_fixture
    Write(lun_sparse) ns33_fixture
    Write(lun_sparse) ns41_fixture
    Write(lun_sparse) ns42_fixture
    Write(lun_sparse) ns43_fixture
    Write(lun_sparse) ns44_fixture
    Close(lun_sparse)

    Return
  End Subroutine write_sparse_file

  Subroutine write_sparse_controls
    Implicit None

    Character(8) :: use_existing
    Integer :: length, lun_solver, status

    use_existing = ''
    Call get_environment_variable('XNET_USE_EXISTING_CONTROLS',use_existing, &
      & length=length,status=status)
    tracked_controls = status == 0
    If ( tracked_controls ) Return

    Open(newunit=lun_solver,file='sparse_controls.nml',status='replace',action='write')
#if defined(TEST_MA48)
    Write(lun_solver,'(a)') '&ma48_controls'
    Write(lun_solver,'(a)') '  icntl(2) = 44'
    Write(lun_solver,'(a)') '  cntl(2) = 0.25'
    Write(lun_solver,'(a)') '  maxerr = 1.0e-9'
#elif defined(TEST_PARDISO)
    Write(lun_solver,'(a)') '&pardiso_controls'
    Write(lun_solver,'(a)') '  iparm(5) = 1, iparm(6) = 1, iparm(12) = 1'
    Write(lun_solver,'(a)') '  iparm(31) = 1, iparm(35) = 1'
    Write(lun_solver,'(a)') '  iparm(7) = 77'
    Write(lun_solver,'(a)') '  dparm(8) = 8.5'
#else
    Write(lun_solver,'(a)') '&pardiso_controls'
    Write(lun_solver,'(a)') '  iparm(3) = 1, iparm(5) = 1, iparm(6) = 1, iparm(12) = 1'
    Write(lun_solver,'(a)') '  iparm(31) = 1, iparm(35) = 1, iparm(36) = 1'
    Write(lun_solver,'(a)') '  iparm(8) = 3'
#endif
    Write(lun_solver,'(a)') '/'
    Close(lun_solver)

    Return
  End Subroutine write_sparse_controls

  Subroutine apply_effectiveness_mutation
    Implicit None

    Character(80) :: mutation
    Integer :: length, status

    mutation = ''
    Call get_environment_variable('XNET_SPARSE_MUTATION',mutation,length=length,status=status)
    If ( status /= 0 ) Return
    Select Case (mutation(1:length))
    Case ('shifted_row_pointer')
      pb(2) = pb(2) + 1
    Case ('wrong_index_base')
      pb = pb - 1
      cidx = cidx - 1
    Case ('missing_self_heating_entry')
      If ( heat_mode ) cidx(nnz) = 1
    Case ('wrong_reaction_map')
      ns11(1) = ns11(1) + 1
    End Select

    Return
  End Subroutine apply_effectiveness_mutation
#endif

  Subroutine expected_matrix(matrix)
    Implicit None

    Real(dp), Intent(out) :: matrix(:,:)

    matrix = 0.0_dp
    matrix(1,1:2) = (/ 4.0_dp, -1.0_dp /)
    matrix(2,1:3) = (/ 2.0_dp, 5.0_dp, 1.0_dp /)
    matrix(3,2:3) = (/ -2.0_dp, 3.0_dp /)
    If ( size(matrix,1) == 4 ) Then
      matrix(1:3,4) = (/ 0.5_dp, -1.0_dp, 2.0_dp /)
      matrix(4,1:3) = (/ -0.25_dp, 0.75_dp, 1.25_dp /)
      matrix(4,4) = 6.0_dp
    EndIf

    Return
  End Subroutine expected_matrix

End Module sparse_component_fixture

Module test_sparse_solvers
  Use sparse_component_fixture, Only: expected_matrix, heat_mode, tracked_controls, component_data_dir
#ifdef XNET_OMP
  Use omp_lib, Only: omp_get_max_threads
#endif
  Use testdrive, Only: check, error_type, new_unittest, unittest_type
  Use xnet_controls, Only: lun_diag, nzbatchmx, tid
  Use xnet_jacobian
  Use xnet_types, Only: dp
#if !defined(TEST_DENSE) && !defined(TEST_REAL_SOLVER)
  Use solver_probe
#endif
  Implicit None
  Private

  Real(dp), Parameter :: association_tolerance = 1.0e-10_dp
  Real(dp), Parameter :: tolerance = 1.0e-12_dp

  Public :: collect_sparse_solver_tests
  Public :: run_real_failure_probe
#ifdef XNET_OMP
  Public :: test_worker_lifecycle
#endif

Contains

  Subroutine collect_sparse_solver_tests(testsuite)
    Implicit None

    Type(unittest_type), Allocatable, Intent(out) :: testsuite(:)

#if defined(TEST_DENSE)
    testsuite = [ &
      & new_unittest('dense matrix storage',test_matrix_storage), &
      & new_unittest('dense known-system solve',test_known_system_solve), &
      & new_unittest('solver result finiteness',test_solution_finiteness), &
      & new_unittest('Jacobian lifecycle',test_jacobian_lifecycle) ]
#else
    testsuite = [ &
      & new_unittest('sparse structure and maps',test_sparse_structure), &
      & new_unittest('sparse matrix storage',test_matrix_storage), &
      & new_unittest('solver controls',test_solver_controls), &
      & new_unittest('solver sequence and solve',test_known_system_solve), &
      & new_unittest('solver result finiteness',test_solution_finiteness), &
      & new_unittest('Jacobian lifecycle',test_jacobian_lifecycle) ]
#endif

    Return
  End Subroutine collect_sparse_solver_tests

#if !defined(TEST_DENSE)
  Subroutine test_sparse_structure(error)
    Implicit None

    Type(error_type), Allocatable, Intent(out) :: error
    Integer, Allocatable :: expected_cidx(:), expected_pb(:), expected_ridx(:)

    Call check(error,lval,7)
    If ( allocated(error) ) Return
    Call check(error,l1s == 3 .and. l2s == 2 .and. l3s == 1 .and. l4s == 1)
    If ( allocated(error) ) Return

    If ( .not. heat_mode ) Then
      Allocate (expected_ridx(7),expected_cidx(7),expected_pb(4))
      expected_ridx = (/ 1, 1, 2, 2, 2, 3, 3 /)
      expected_cidx = (/ 1, 2, 1, 2, 3, 2, 3 /)
      expected_pb = (/ 1, 3, 6, 8 /)
      Call check(error,msize == 3 .and. nnz == 7)
      If ( allocated(error) ) Return
      Call check(error,all(ridx == expected_ridx) .and. all(cidx == expected_cidx))
      If ( allocated(error) ) Return
      Call check(error,all(pb == expected_pb))
      If ( allocated(error) ) Return
      Call check_base_maps(error)
    Else
      Allocate (expected_ridx(14),expected_cidx(14))
#if defined(TEST_MA48)
      Allocate (expected_pb(4))
      expected_ridx = (/ 1, 1, 2, 2, 2, 3, 3, 1, 2, 3, 4, 4, 4, 4 /)
      expected_cidx = (/ 1, 2, 1, 2, 3, 2, 3, 4, 4, 4, 1, 2, 3, 4 /)
      expected_pb = (/ 1, 3, 6, 8 /)
      Call check(error,all(pb(1:4) == expected_pb))
#else
      Allocate (expected_pb(5))
      expected_ridx = (/ 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 4, 4, 4, 4 /)
      expected_cidx = (/ 1, 2, 4, 1, 2, 3, 4, 2, 3, 4, 1, 2, 3, 4 /)
      expected_pb = (/ 1, 4, 8, 11, 15 /)
      Call check(error,all(pb == expected_pb))
#endif
      If ( allocated(error) ) Return
      Call check(error,msize == 4 .and. nnz == 14)
      If ( allocated(error) ) Return
      Call check(error,all(ridx == expected_ridx) .and. all(cidx == expected_cidx))
      If ( allocated(error) ) Return
#if defined(TEST_MA48)
      Call check_base_maps(error)
#else
      Call check_heat_maps(error)
#endif
    EndIf
    If ( allocated(error) ) Return
    Call check(error,all(abs(sident-merge(1.0_dp,0.0_dp,ridx == cidx)) <= tolerance))

    Return
  End Subroutine test_sparse_structure

  Subroutine check_base_maps(error)
    Implicit None

    Type(error_type), Allocatable, Intent(out) :: error

    Call check(error,all(ns11 == (/ 2, 5, 6 /)))
    If ( allocated(error) ) Return
    Call check(error,all(ns21 == (/ 1, 3 /)) .and. all(ns22 == (/ 2, 5 /)))
    If ( allocated(error) ) Return
    Call check(error,ns31(1) == 6 .and. ns32(1) == 7 .and. ns33(1) == 6)
    If ( allocated(error) ) Return
    Call check(error,ns41(1) == 3 .and. ns42(1) == 4 .and. &
      & ns43(1) == 5 .and. ns44(1) == 3)

    Return
  End Subroutine check_base_maps

#if !defined(TEST_MA48)
  Subroutine check_heat_maps(error)
    Implicit None

    Type(error_type), Allocatable, Intent(out) :: error

    Call check(error,all(ns11 == (/ 2, 6, 8 /)))
    If ( allocated(error) ) Return
    Call check(error,all(ns21 == (/ 1, 4 /)) .and. all(ns22 == (/ 2, 6 /)))
    If ( allocated(error) ) Return
    Call check(error,ns31(1) == 8 .and. ns32(1) == 9 .and. ns33(1) == 8)
    If ( allocated(error) ) Return
    Call check(error,ns41(1) == 4 .and. ns42(1) == 5 .and. &
      & ns43(1) == 6 .and. ns44(1) == 4)

    Return
  End Subroutine check_heat_maps
#endif
#endif

  Subroutine test_matrix_storage(error)
    Implicit None

    Type(error_type), Allocatable, Intent(out) :: error
    Integer :: zone
    Real(dp) :: actual(msize,msize), diag(2), expected(msize,msize), matrix(msize,msize), mult(2)

    Call expected_matrix(matrix)
    diag = 0.25_dp
    mult = 2.0_dp
    Call install_matrix(spread(matrix,dim=3,ncopies=2),diag,mult)
    expected = 2.0_dp*matrix
    Do zone = 1, msize
      expected(zone,zone) = expected(zone,zone) + 0.25_dp
    EndDo

    Do zone = 1, 2
      Call reconstruct_matrix(zone,actual)
      Call check(error,all(abs(actual-expected) <= tolerance))
      If ( allocated(error) ) Return
    EndDo

    Return
  End Subroutine test_matrix_storage

#if !defined(TEST_DENSE)
  Subroutine test_solver_controls(error)
    Implicit None

    Type(error_type), Allocatable, Intent(out) :: error

#if defined(TEST_MA48)
#if !defined(TEST_REAL_SOLVER)
    Call check(error,init_abi == 48 .and. init_calls == 1)
    If ( allocated(error) ) Return
#endif
    Call check(error,lun_diag > 0)
    If ( allocated(error) ) Return
    If ( tracked_controls ) Then
      Call check(error,icntl(1) == 0 .and. icntl(2) == 0 .and. icntl(3) == 3)
    Else
      Call check(error,icntl(1) == 0 .and. icntl(2) == 44 .and. icntl(3) == 3)
    EndIf
    If ( allocated(error) ) Return
#if defined(TEST_REAL_SOLVER)
    Call check(error,icntl(5) == msize .and. icntl(6) == 1 .and. icntl(8) == 0)
#else
    Call check(error,icntl(5) == msize .and. icntl(6) == 2 .and. icntl(8) == 0)
#endif
    If ( allocated(error) ) Return
    If ( tracked_controls ) Then
      Call check(error,abs(cntl(2)-0.1_dp) <= tolerance .and. abs(maxerr-1.0e-11_dp) <= tolerance)
    Else
      Call check(error,abs(cntl(2)-0.25_dp) <= tolerance .and. abs(maxerr-1.0e-9_dp) <= tolerance)
    EndIf
    If ( allocated(error) ) Return
    Call check(error,all(jobA == 3) .and. all(jobB == 1) .and. all(jobC == 1))
#elif defined(TEST_PARDISO)
#if !defined(TEST_REAL_SOLVER)
    Call check(error,init_abi == 61 .and. init_calls == 1)
    If ( allocated(error) ) Return
#endif
    If ( tracked_controls ) Then
      Call check(error,iparm(3) == 1 .and. iparm(7) == 7 .and. abs(dparm(8)-0.8_dp) <= tolerance)
    Else
      Call check(error,iparm(3) == 1 .and. iparm(7) == 77 .and. abs(dparm(8)-8.5_dp) <= tolerance)
    EndIf
    If ( allocated(error) ) Return
    Call check(error,iparm(1) == 1 .and. iparm(5) == 0 .and. iparm(6) == 0)
    If ( allocated(error) ) Return
    Call check(error,iparm(12) == 0 .and. iparm(31) == 0 .and. iparm(35) == 0 .and. &
      & abs(dparm(1)-0.1_dp) <= tolerance)
    If ( allocated(error) ) Return
    Call check(error,maxfct == 2 .and. msglvl == 1 .and. all(perm == 0))
#else
#if !defined(TEST_REAL_SOLVER)
    Call check(error,init_abi == 64 .and. init_calls == 1)
    If ( allocated(error) ) Return
#endif
    If ( tracked_controls ) Then
      Call check(error,iparm(3) == 0 .and. abs(dparm(8)) <= tolerance)
    Else
      Call check(error,iparm(3) == 0 .and. iparm(8) == 3 .and. abs(dparm(8)) <= tolerance)
    EndIf
    If ( allocated(error) ) Return
    Call check(error,iparm(1) == 1 .and. iparm(5) == 0 .and. iparm(6) == 0)
    If ( allocated(error) ) Return
    Call check(error,iparm(12) == 0 .and. iparm(31) == 0 .and. iparm(35) == 0 .and. &
      & iparm(36) == 0 .and. abs(dparm(1)) <= tolerance)
    If ( allocated(error) ) Return
    Call check(error,maxfct == 1 .and. msglvl == 1 .and. all(perm == 0))
#endif

    Return
  End Subroutine test_solver_controls
#endif

  Subroutine test_known_system_solve(error)
    Implicit None

    Type(error_type), Allocatable, Intent(out) :: error
    Integer :: zone
    Real(dp) :: actual(msize,2), diag(2), dt9(2), dy(3,2), matrix(msize,msize,2), mult(2)
    Real(dp) :: rhs(msize,2), solution(msize,2), t9rhs(2), yrhs(3,2)

    Do zone = 1, 2
      Call expected_matrix(matrix(:,:,zone))
#if defined(TEST_REAL_SOLVER) && defined(TEST_PARDISO_MKL)
      ! Every slot has a distinct matrix, including the two slots owned by the same worker.
      matrix(:,:,zone) = real((tid-1)*nzbatchmx+zone,dp)*matrix(:,:,zone)
#endif
    EndDo
    diag = 0.0_dp
    mult = 1.0_dp
    Call install_matrix(matrix,diag,mult)
    Call set_solutions(solution)
#if defined(TEST_REAL_SOLVER) && defined(XNET_OMP)
    solution = solution + real(tid-1,dp)
#endif
    Do zone = 1, 2
      rhs(:,zone) = matmul(matrix(:,:,zone),solution(:,zone))
    EndDo
    yrhs = rhs(1:3,:)
    t9rhs = 0.0_dp
    If ( msize == 4 ) t9rhs = rhs(4,:)

#if !defined(TEST_DENSE) && !defined(TEST_REAL_SOLVER)
    Call reset_solver_probe
#endif
    Call jacobian_solve(1,yrhs,dy,t9rhs,dt9)
    actual(1:3,:) = dy
    If ( msize == 4 ) actual(4,:) = dt9
#if defined(TEST_REAL_SOLVER)
    Call apply_real_result_mutation(actual)
#endif
    Call check_solutions(error,matrix,rhs,solution,actual)
    If ( allocated(error) ) Return

    solution = -0.5_dp*solution
    Do zone = 1, 2
      rhs(:,zone) = matmul(matrix(:,:,zone),solution(:,zone))
    EndDo
    yrhs = rhs(1:3,:)
    If ( msize == 4 ) t9rhs = rhs(4,:)
    Call jacobian_solve(2,yrhs,dy,t9rhs,dt9)
    actual(1:3,:) = dy
    If ( msize == 4 ) actual(4,:) = dt9
    Call check_solutions(error,matrix,rhs,solution,actual)
    If ( allocated(error) ) Return

#if defined(TEST_REAL_SOLVER) && defined(TEST_PARDISO_MKL)
    ! Reuse the existing factors for a new RHS, then refactor a changed matrix through the
    ! separate decomposition/back-substitution entry points.
    solution = 2.0_dp*solution
    Do zone = 1, 2
      rhs(:,zone) = matmul(matrix(:,:,zone),solution(:,zone))
    EndDo
    yrhs = rhs(1:3,:)
    If ( msize == 4 ) t9rhs = rhs(4,:)
    Call jacobian_bksub(2,yrhs,dy,t9rhs,dt9)
    actual(1:3,:) = dy
    If ( msize == 4 ) actual(4,:) = dt9
    Call check_solutions(error,matrix,rhs,solution,actual)
    If ( allocated(error) ) Return
    matrix = 1.5_dp*matrix
    Call install_matrix(matrix,diag,mult)
    Do zone = 1, 2
      rhs(:,zone) = matmul(matrix(:,:,zone),solution(:,zone))
    EndDo
    yrhs = rhs(1:3,:)
    If ( msize == 4 ) t9rhs = rhs(4,:)
    Call jacobian_decomp(2)
    Call jacobian_bksub(2,yrhs,dy,t9rhs,dt9)
    actual(1:3,:) = dy
    If ( msize == 4 ) actual(4,:) = dt9
    Call check_solutions(error,matrix,rhs,solution,actual)
    If ( allocated(error) ) Return
#endif

#if !defined(TEST_REAL_SOLVER)
#if defined(TEST_PARDISO) || defined(TEST_PARDISO_MKL)
    Call check(error,call_count == 8)
    If ( allocated(error) ) Return
    Call check(error,all(phase_history(1:8) == (/ 12, 12, 33, 33, 22, 22, 33, 33 /)))
    If ( allocated(error) ) Return
#if defined(TEST_PARDISO_MKL)
    Call check(error,all(mnum_history(1:8) == 1))
    If ( allocated(error) ) Return
    Call check(error,all(handle_history(1:8) == (/ 0, 0, 1, 2, 3, 4, 5, 6 /)))
#else
    Call check(error,all(mnum_history(1:8) == (/ 1, 2, 1, 2, 1, 2, 1, 2 /)))
#endif
    If ( allocated(error) ) Return
    Call check(error,index_base_valid .and. options_valid)
#elif defined(TEST_MA48)
    If ( recovery_is('ma48_analysis_warning') ) Then
      Call check(error,analysis_calls == 3)
      If ( allocated(error) ) Return
      Call check(error,all(analysis_job_history(1:3) == (/ 3, 1, 3 /)))
    ElseIf ( recovery_is('ma48_storage_resize') ) Then
      Call check(error,analysis_calls == 3)
      If ( allocated(error) ) Return
      Call check(error,all(analysis_job_history(1:3) == 3))
    Else
      Call check(error,analysis_calls == 2)
      If ( allocated(error) ) Return
      Call check(error,all(analysis_job_history(1:2) == 3))
    EndIf
    If ( allocated(error) ) Return
    Call check(error,factor_calls == 4 .and. solve_calls == 4)
    If ( allocated(error) ) Return
    Call check(error,all(factor_job_history(1:4) == (/ 1, 1, 2, 2 /)))
    If ( allocated(error) ) Return
    Call check(error,all(solve_job_history(1:4) == 1))
    If ( allocated(error) ) Return
    Call check(error,coordinate_valid .and. options_valid)
#endif
#endif

    Return
  End Subroutine test_known_system_solve

  Subroutine test_jacobian_lifecycle(error)
    Implicit None

    Type(error_type), Allocatable, Intent(out) :: error

    Call jacobian_finalize
    Call check(error,jacobian_storage_released(),'all Jacobian allocations released')
    If ( allocated(error) ) Return
#if !defined(TEST_REAL_SOLVER)
#if defined(TEST_PARDISO)
    Call check(error,call_count == 9,'one release for the worker handle')
    If ( allocated(error) ) Return
    Call check(error,phase_history(9) == -1,'release all stored matrices')
    If ( allocated(error) ) Return
#elif defined(TEST_PARDISO_MKL)
    Call check(error,call_count == 10,'one release for each used batch slot')
    If ( allocated(error) ) Return
    Call check(error,all(phase_history(9:10) == -1),'release all stored matrices')
    If ( allocated(error) ) Return
    Call check(error,all(handle_history(9:10) == (/ 7, 8 /)),'release both independent handles')
    If ( allocated(error) ) Return
#endif
#endif
    Call jacobian_finalize

    ! An initialized but unused solver has no factors to release.
    Call read_jacobian_data(trim(component_data_dir))
#if !defined(TEST_DENSE) && !defined(TEST_REAL_SOLVER)
    Call reset_solver_probe
#endif
    Call jacobian_finalize
    Call check(error,jacobian_storage_released(),'unused Jacobian allocations released')
    If ( allocated(error) ) Return
#if !defined(TEST_REAL_SOLVER) && (defined(TEST_PARDISO) || defined(TEST_PARDISO_MKL))
    Call check(error,call_count == 0,'no release of unused or already released handles')
    If ( allocated(error) ) Return
#endif

    ! Reuse the numerical checks after a complete teardown and fresh initialization.
    Call read_jacobian_data(trim(component_data_dir))
    Call test_known_system_solve(error)
    If ( allocated(error) ) Return
    Call jacobian_finalize
    Call check(error,jacobian_storage_released(),'reinitialized Jacobian allocations released')

    Return
  End Subroutine test_jacobian_lifecycle

  Logical Function jacobian_storage_released()
    Implicit None

#if defined(TEST_DENSE)
    jacobian_storage_released = .not. (allocated(diag0) .or. allocated(mult1) .or. allocated(pivot) .or. &
      & allocated(dydotdy) .or. allocated(jac) .or. allocated(rhs) .or. allocated(indx) .or. allocated(info) .or. &
      & allocated(hjac) .or. allocated(hrhs) .or. allocated(hindx) .or. allocated(djac) .or. &
      & allocated(drhs) .or. allocated(dindx))
#else
    jacobian_storage_released = .not. (allocated(dydotdy) .or. allocated(tvals) .or. allocated(sident) .or. &
      & allocated(ridx) .or. allocated(cidx) .or. allocated(pb) .or. allocated(ns11) .or. allocated(ns21) .or. &
      & allocated(ns22) .or. allocated(ns31) .or. allocated(ns32) .or. allocated(ns33) .or. allocated(ns41) .or. &
      & allocated(ns42) .or. allocated(ns43) .or. allocated(ns44))
#if defined(TEST_MA48)
    jacobian_storage_released = jacobian_storage_released .and. .not. ( &
      & allocated(vals) .or. allocated(jcn) .or. allocated(irn) .or. allocated(keep) .or. allocated(wB) .or. &
      & allocated(wC) .or. allocated(iwA) .or. allocated(iwB) .or. allocated(iwC) .or. allocated(jobA) .or. &
      & allocated(jobB) .or. allocated(jobC) .or. allocated(vals0) .or. allocated(jcn0) .or. allocated(irn0))
#else
    jacobian_storage_released = jacobian_storage_released .and. .not. allocated(perm)
#if defined(TEST_PARDISO_MKL)
    jacobian_storage_released = jacobian_storage_released .and. .not. allocated(pt)
#endif
#endif
#endif

    Return
  End Function jacobian_storage_released

#ifdef XNET_OMP
  Subroutine test_worker_lifecycle(error)
    Implicit None

    Type(error_type), Allocatable, Intent(out) :: error
    Integer :: i, nworkers, nrelease
    Logical, Allocatable :: released(:)

    nworkers = omp_get_max_threads()
    Allocate (released(nworkers))
    released = .false.
#if defined(TEST_PARDISO_MKL)
    Call test_worker_solver_indices(error)
    If ( allocated(error) ) Return
#endif
#if defined(TEST_REAL_SOLVER)
    Call test_worker_known_systems(error)
    If ( allocated(error) ) Return
#else
    Call reset_solver_probe
    ! Give every worker/slot a distinct nonzero handle. The doubles record which ones are released.
    !$omp parallel default(shared) private(i)
#if defined(TEST_MA48)
    Allocate (vals0(1,1:nzbatchmx),jcn0(1,1:nzbatchmx),irn0(1,1:nzbatchmx))
#elif defined(TEST_PARDISO)
    pt = 0_i8
    pt(1) = tid
#else
    Do i = 1, nzbatchmx
      pt(1,i) = (tid-1)*nzbatchmx+i
    EndDo
#endif
    !$omp end parallel
#endif

    Call jacobian_finalize
    !$omp parallel default(shared)
    released(tid) = jacobian_storage_released()
    !$omp end parallel
    Call check(error,all(released),'every worker released its Jacobian allocations')
    If ( allocated(error) ) Return
#if !defined(TEST_MA48) && !defined(TEST_REAL_SOLVER)
    nrelease = nworkers
#if defined(TEST_PARDISO_MKL)
    nrelease = nzbatchmx*nworkers
#endif
    Call check(error,call_count == nrelease,'one release for each worker/slot handle')
    If ( allocated(error) ) Return
    Call check(error,all(phase_history(1:nrelease) == -1),'release every stored factor')
    If ( allocated(error) ) Return
    Do i = 1, nrelease
      Call check(error,count(handle_history(1:nrelease) == i) == 1,'each distinct handle released once')
      If ( allocated(error) ) Return
    EndDo
#endif
    Call jacobian_finalize
    Call read_jacobian_data(trim(component_data_dir))
#if defined(TEST_PARDISO_MKL)
    Call test_worker_solver_indices(error)
    If ( allocated(error) ) Return
#endif
#if defined(TEST_REAL_SOLVER)
    Call test_worker_known_systems(error)
    If ( allocated(error) ) Return
    Call jacobian_finalize
    Call read_jacobian_data(trim(component_data_dir))
#else
    Call reset_solver_probe
#endif
    Call jacobian_finalize
    released = .false.
    !$omp parallel default(shared)
    released(tid) = jacobian_storage_released()
    !$omp end parallel
    Call check(error,all(released),'every worker released reinitialized unused storage')
    If ( allocated(error) ) Return
#if !defined(TEST_MA48) && !defined(TEST_REAL_SOLVER)
    Call check(error,call_count == 0,'unused handles need no release')
#endif

    Deallocate (released)
    Return
  End Subroutine test_worker_lifecycle

#if defined(TEST_REAL_SOLVER)
  Subroutine test_worker_known_systems(error)
    Implicit None

    Type(error_type), Allocatable, Intent(out) :: error
    Type(error_type), Allocatable :: worker_error
    Logical, Allocatable :: valid(:)
    Character(256), Allocatable :: messages(:)
    Integer :: i, slot

    Allocate (valid(omp_get_max_threads()),messages(omp_get_max_threads()))
    valid = .false.
    messages = ''
    !$omp parallel default(shared) private(worker_error,slot)
    Call test_sparse_structure(worker_error)
    If ( .not. allocated(worker_error) ) Call test_solver_controls(worker_error)
    !$omp critical(real_pardiso_record)
    Write(*,'(a,i0,a,2(i0,1x),a,64(i0,1x))') 'real PARDISO worker=',tid,' slots=',1,nzbatchmx,' iparm=',iparm
    !$omp end critical(real_pardiso_record)
    !$omp barrier
    If ( .not. allocated(worker_error) ) Call test_known_system_solve(worker_error)
    If ( .not. allocated(worker_error) ) Call test_sparse_structure(worker_error)
    If ( .not. allocated(worker_error) ) Call check(worker_error,all(any(pt(:,1:nzbatchmx) /= 0_i8,dim=1)), &
      & 'each used real PARDISO slot has a live handle before release')
    !$omp critical(real_pardiso_record)
    Do slot = 1, nzbatchmx
      Write(*,'(a,i0,a,i0,a,64(i0,1x))') 'real PARDISO worker=',tid,' slot=',slot,' handle=',pt(:,slot)
    EndDo
    !$omp end critical(real_pardiso_record)
    valid(tid) = .not. allocated(worker_error)
    If ( allocated(worker_error) ) Then
      messages(tid) = worker_error%message
      worker_error%stat = 0
      Deallocate (worker_error)
    EndIf
    !$omp end parallel
    Do i = 1, size(valid)
      Call check(error,valid(i),'real PARDISO worker known-system check: '//trim(messages(i)))
      If ( allocated(error) ) Return
    EndDo

    Deallocate (valid,messages)
    Return
  End Subroutine test_worker_known_systems
#endif

#if defined(TEST_PARDISO_MKL)
  Subroutine test_worker_solver_indices(error)
    Use, Intrinsic :: iso_c_binding, Only: c_intptr_t
    Implicit None

    Type(error_type), Allocatable, Intent(out) :: error
    Integer :: i, j, nworkers
    Integer, Allocatable :: expected_pb(:), expected_cidx(:)
    Integer(c_intptr_t), Allocatable :: addresses(:,:)
    Logical, Allocatable :: valid(:)

    nworkers = omp_get_max_threads()
    If ( heat_mode ) Then
      expected_pb = (/ 1, 4, 8, 11, 15 /)
      expected_cidx = (/ 1, 2, 4, 1, 2, 3, 4, 2, 3, 4, 1, 2, 3, 4 /)
    Else
      expected_pb = (/ 1, 3, 6, 8 /)
      expected_cidx = (/ 1, 2, 1, 2, 3, 2, 3 /)
    EndIf
    Allocate (addresses(3,nworkers),valid(nworkers))
    valid = .false.
    !$omp parallel default(shared)
    valid(tid) = allocated(pb) .and. allocated(cidx) .and. allocated(perm)
    If ( valid(tid) ) valid(tid) = size(pb) == size(expected_pb) .and. &
      & size(cidx) == size(expected_cidx) .and. size(perm) == msize
    !$omp end parallel
    Call check(error,all(valid),'every PARDISO worker has allocated CRS and permutation arrays')
    If ( allocated(error) ) Return

    !$omp parallel default(shared)
    valid(tid) = all(pb == expected_pb) .and. all(cidx == expected_cidx) .and. all(perm == 0)
    addresses(1,tid) = integer_array_address(pb)
    addresses(2,tid) = integer_array_address(cidx)
    addresses(3,tid) = integer_array_address(perm)
    !$omp end parallel
    Call check(error,all(valid),'every PARDISO worker receives initial CRS and permutation contents')
    If ( allocated(error) ) Return
#if defined(TEST_REAL_SOLVER)
    Do i = 1, nworkers
      Write(*,'(a,i0,a,3(z16.16,1x))') 'real PARDISO worker=',i,' pb/cidx/perm addresses=',addresses(:,i)
    EndDo
#endif
    Do i = 1, nworkers
      Do j = i+1, nworkers
        Call check(error,all(addresses(:,i) /= addresses(:,j)), &
          & 'PARDISO workers own distinct CRS and permutation storage')
        If ( allocated(error) ) Return
      EndDo
    EndDo

    ! Model temporary index conversion during one worker's solver call. The other workers must
    ! keep their one-based arrays while that worker's arrays contain the converted values.
    !$omp parallel default(shared)
    If ( tid == 1 ) Then
      pb = pb - 1
      cidx = cidx - 1
      perm = 1
    EndIf
    !$omp barrier
    If ( tid == 1 ) Then
      valid(tid) = all(pb == expected_pb-1) .and. all(cidx == expected_cidx-1) .and. all(perm == 1)
    Else
      valid(tid) = all(pb == expected_pb) .and. all(cidx == expected_cidx) .and. all(perm == 0)
    EndIf
    !$omp barrier
    If ( tid == 1 ) Then
      pb = pb + 1
      cidx = cidx + 1
      perm = 0
    EndIf
    !$omp end parallel
    Call check(error,all(valid),'temporary PARDISO index changes stay within one worker')
    If ( allocated(error) ) Return

    Deallocate (addresses,valid,expected_pb,expected_cidx)
    Return
  End Subroutine test_worker_solver_indices

  Function integer_array_address(values) Result(address)
    Use, Intrinsic :: iso_c_binding, Only: c_intptr_t, c_loc
    Implicit None

    Integer, Target, Intent(in) :: values(*)
    Integer(c_intptr_t) :: address

    address = transfer(c_loc(values(1)),0_c_intptr_t)
    Return
  End Function integer_array_address
#endif
#endif

#if defined(TEST_REAL_SOLVER)
  Subroutine apply_real_result_mutation(actual)
    Use xnet_types, Only: i8
    Implicit None

    Real(dp), Intent(inout) :: actual(msize,2)

    Character(80) :: mutation
    Integer :: length, status
    Integer(i8), Parameter :: exponent_bits = int(z'7ff0000000000000',i8)

    mutation = ''
    Call get_environment_variable('XNET_SPARSE_REAL_MUTATION',mutation, &
      & length=length,status=status)
    If ( status /= 0 ) Return
    Select Case (mutation(1:length))
    Case ('excessive_residual')
      actual(1,1) = actual(1,1) + 1.0e-11_dp
    Case ('nan_result')
      actual(1,1) = transfer(ibset(exponent_bits,51),0.0_dp)
    Case ('positive_infinity_result')
      actual(1,1) = transfer(exponent_bits,0.0_dp)
    Case ('negative_infinity_result')
      actual(1,1) = transfer(ibset(exponent_bits,63),0.0_dp)
    End Select

    Return
  End Subroutine apply_real_result_mutation
#endif

  Subroutine run_real_failure_probe
    Use, Intrinsic :: iso_fortran_env, Only: error_unit
    Implicit None

    Real(dp) :: diag(2), dt9(2), dy(3,2), matrix(msize,msize), mult(2)
    Real(dp) :: t9rhs(2), yrhs(3,2)

#if defined(TEST_PARDISO_MKL)
    Call expected_matrix(matrix)
#else
    matrix = 0.0_dp
#endif
    diag = 0.0_dp
    mult = 1.0_dp
    yrhs = 1.0_dp
    t9rhs = 1.0_dp
    Call install_matrix(spread(matrix,dim=3,ncopies=2),diag,mult)
#if defined(TEST_PARDISO_MKL)
    cidx(1) = 0
    iparm(27) = 1
#endif
    Call jacobian_solve(1,yrhs,dy,t9rhs,dt9)
    Write(error_unit,'(a)') 'real sparse backend accepted controlled failure input'
    Stop 1
  End Subroutine run_real_failure_probe

  Subroutine install_matrix(matrix,diag,mult)
    Implicit None

    Real(dp), Intent(in) :: matrix(msize,msize,2), diag(1:nzbatchmx), mult(1:nzbatchmx)

    Integer :: entry, zone

#if defined(TEST_DENSE)
    Do zone = 1, nzbatchmx
      dydotdy(:,:,zone) = transpose(matrix(:,:,zone-1+1))
    EndDo
#else
    Do zone = 1, nzbatchmx
      Do entry = 1, nnz
        dydotdy(entry,zone) = matrix(ridx(entry),cidx(entry),zone-1+1)
      EndDo
    EndDo
#endif
    Call jacobian_scale(diag,mult)

    Return
  End Subroutine install_matrix

  Subroutine reconstruct_matrix(zone,matrix)
    Implicit None

    Integer, Intent(in) :: zone
    Real(dp), Intent(out) :: matrix(msize,msize)

    Integer :: entry

#if defined(TEST_DENSE)
    matrix = jac(:,:,1+zone-1)
#else
    matrix = 0.0_dp
    Do entry = 1, nnz
      matrix(ridx(entry),cidx(entry)) = tvals(entry,1+zone-1)
    EndDo
#endif

    Return
  End Subroutine reconstruct_matrix

  Subroutine set_solutions(solution)
    Implicit None

    Real(dp), Intent(out) :: solution(msize,2)

    solution = 0.0_dp
    solution(1:3,1) = (/ 1.0_dp, 2.0_dp, -1.0_dp /)
    solution(1:3,2) = (/ -2.0_dp, 1.0_dp, 3.0_dp /)
    If ( msize == 4 ) solution(4,:) = (/ 0.5_dp, -0.75_dp /)

    Return
  End Subroutine set_solutions

  Subroutine check_solutions(error,matrix,rhs,expected,actual)
    Use xnet_types, Only: i8
    Implicit None

    Type(error_type), Allocatable, Intent(out) :: error
    Real(dp), Intent(in) :: matrix(msize,msize,2), rhs(msize,2)
    Real(dp), Intent(in) :: expected(msize,2), actual(msize,2)

    Integer :: zone
    Integer(i8), Parameter :: exponent_bits = int(z'7ff0000000000000',i8)
    Real(dp) :: maximum_residual, residual

    ! Inspect binary64 exponent bits before arithmetic: -Ofast may assume that real operands
    ! are finite and remove floating-point finiteness tests or accept a NaN comparison.
    Call check(error,all(iand(transfer(matrix,(/0_i8/),size(matrix)),exponent_bits) /= exponent_bits), &
      & 'nonfinite solver matrix')
    If ( allocated(error) ) Return
    Call check(error,all(iand(transfer(rhs,(/0_i8/),size(rhs)),exponent_bits) /= exponent_bits), &
      & 'nonfinite solver RHS')
    If ( allocated(error) ) Return
    Call check(error,all(iand(transfer(expected,(/0_i8/),size(expected)),exponent_bits) /= exponent_bits), &
      & 'nonfinite expected solution')
    If ( allocated(error) ) Return
    Call check(error,all(iand(transfer(actual,(/0_i8/),size(actual)),exponent_bits) /= exponent_bits), &
      & 'nonfinite solver result')
    If ( allocated(error) ) Return

    ! Keep the copy-back association check independent of the stricter residual check.
    Call check(error,all(abs(actual-expected) <= association_tolerance),'solver solution association differs')
    If ( allocated(error) ) Return
    maximum_residual = 0.0_dp
    Do zone = 1, 2
      residual = maxval(abs(matmul(matrix(:,:,zone),actual(:,zone))-rhs(:,zone)))
      maximum_residual = max(maximum_residual,residual)
      Call check(error,residual <= tolerance*(1.0_dp+maxval(abs(rhs(:,zone)))),'solver residual exceeds limit')
      If ( allocated(error) ) Return
    EndDo
#if defined(TEST_REAL_SOLVER)
#ifdef XNET_OMP
    Write(*,'(a,i0,a,es12.5)') 'worker=',tid,' maximum real-solver residual=',maximum_residual
#else
    Write(*,'(a,es12.5)') 'maximum real-solver residual=',maximum_residual
#endif
#endif

    Return
  End Subroutine check_solutions

  Subroutine test_solution_finiteness(error)
    Use xnet_types, Only: i8
    Implicit None

    Type(error_type), Allocatable, Intent(out) :: error
    Type(error_type), Allocatable :: rejected
    Real(dp) :: matrix(msize,msize,2), rhs(msize,2), expected(msize,2), actual(msize,2)
    Integer(i8) :: bits(3)
    Integer :: kind, operand
    Character(32) :: diagnostic

    bits(1) = int(z'7ff8000000000000',i8)
    bits(2) = int(z'7ff0000000000000',i8)
    bits(3) = ibset(bits(2),63)
    Call expected_matrix(matrix(:,:,1))
    matrix(:,:,2) = matrix(:,:,1)
    Call set_solutions(expected)
    rhs = matmul(matrix(:,:,1),expected)
    actual = expected
    Call check_solutions(error,matrix,rhs,expected,actual)
    If ( allocated(error) ) Return

    Do operand = 1, 4
      Do kind = 1, size(bits)
        Call expected_matrix(matrix(:,:,1))
        matrix(:,:,2) = matrix(:,:,1)
        Call set_solutions(expected)
        rhs = matmul(matrix(:,:,1),expected)
        actual = expected
        Select Case (operand)
        Case (1)
          matrix(1,1,1) = transfer(bits(kind),0.0_dp)
          diagnostic = 'nonfinite solver matrix'
        Case (2)
          rhs(1,1) = transfer(bits(kind),0.0_dp)
          diagnostic = 'nonfinite solver RHS'
        Case (3)
          expected(1,1) = transfer(bits(kind),0.0_dp)
          diagnostic = 'nonfinite expected solution'
        Case (4)
          actual(1,1) = transfer(bits(kind),0.0_dp)
          diagnostic = 'nonfinite solver result'
        End Select
        Call check_solutions(rejected,matrix,rhs,expected,actual)
        Call check(error,allocated(rejected),'solver checker accepted a nonfinite operand')
        If ( allocated(error) ) Return
        Call check(error,rejected%message == trim(diagnostic),'nonfinite operand rejected for its intended reason')
        rejected%stat = 0
        Deallocate (rejected)
        If ( allocated(error) ) Return
      EndDo
    EndDo

    Call expected_matrix(matrix(:,:,1))
    matrix(:,:,2) = matrix(:,:,1)
    Call set_solutions(expected)
    rhs = matmul(matrix(:,:,1),expected)
    actual = expected
    actual(1,1) = actual(1,1) + 1.0e-11_dp
    Call check_solutions(rejected,matrix,rhs,expected,actual)
    Call check(error,allocated(rejected),'solver checker accepted a finite excessive residual')
    If ( allocated(error) ) Return
    Call check(error,rejected%message == 'solver residual exceeds limit','finite perturbation rejected for its residual')
    rejected%stat = 0
    Deallocate (rejected)

    Return
  End Subroutine test_solution_finiteness

End Module test_sparse_solvers

Program sparse_solver_test_runner
  Use, Intrinsic :: iso_fortran_env, Only: error_unit
  Use sparse_component_fixture, Only: initialize_component
  Use test_sparse_solvers, Only: collect_sparse_solver_tests, run_real_failure_probe
  Use testdrive, Only: new_testsuite, run_testsuite, testsuite_type
#ifdef XNET_OMP
  Use testdrive, Only: error_type
  Use test_sparse_solvers, Only: test_worker_lifecycle
#endif
  Implicit None

  Character(16) :: mode
  Character(256) :: data_dir
  Character(80) :: suite_name
  Integer :: stat
  Type(testsuite_type), Allocatable :: testsuites(:)
#ifdef XNET_OMP
  Type(error_type), Allocatable :: error
#endif

  If ( command_argument_count() /= 2 ) Then
    Write(error_unit,*) 'usage: sparse solver test MODE DATA_DIR'
    Stop 1
  EndIf
  Call get_command_argument(1,mode)
  Call get_command_argument(2,data_dir)
  Call initialize_component(trim(mode),trim(data_dir))
#ifdef XNET_OMP
  If ( trim(mode) == 'workers' .or. trim(mode) == 'workers-heat' ) Then
    ! test-drive wraps even serial suites in an OpenMP region. Exercise the production lifecycle
    ! directly here, since its callers must be outside application parallel regions.
    Call test_worker_lifecycle(error)
    If ( allocated(error) ) Then
      Write(error_unit,'(a)') error%message
      Stop 1
    EndIf
    Write(error_unit,'(a)') 'worker Jacobian lifecycle passed'
    Stop
  EndIf
#endif
#if defined(TEST_REAL_SOLVER)
  If ( trim(mode) == 'failure' ) Call run_real_failure_probe
#endif

#if defined(TEST_DENSE)
  suite_name = 'dense Jacobian '//trim(mode)
#elif defined(TEST_MA48)
  suite_name = 'MA48 solver '//trim(mode)
#elif defined(TEST_PARDISO)
  suite_name = 'standalone PARDISO solver '//trim(mode)
#else
  suite_name = 'MKL PARDISO solver '//trim(mode)
#endif
  stat = 0
  testsuites = [ new_testsuite(trim(suite_name),collect_sparse_solver_tests) ]
  Write(error_unit,'("# Testing: ",a)') testsuites(1)%name
  Call run_testsuite(testsuites(1)%collect,error_unit,stat,parallel=.False.)
  If ( stat > 0 ) Then
    Write(error_unit,'(i0,1x,a)') stat,'test(s) failed'
    Stop 1
  EndIf
End Program sparse_solver_test_runner
