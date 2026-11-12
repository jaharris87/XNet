Program worker_storage_consumer
  ! Inspect production owners independently of API result staging, including workers with no burns.
  Use, Intrinsic :: iso_c_binding, Only: c_intptr_t
  Use omp_lib, Only: omp_get_max_threads, omp_get_thread_num, omp_set_dynamic
  Use xnet_api, Only: dp, xnet_controls_t, xnet_network_t, xnet_timing_t, set_xnet_controls_defaults, &
    & xnet_initialize, xnet_burn_batch, xnet_finalize, xnet_success
  Use nuclear_data, Only: aa, gg, dlngdt9, ny
  Use reaction_data, Only: b1, csect1
  Use xnet_abundances, Only: y, yo, yt, ystart, ydot, xext
  Use xnet_conditions, Only: th, t9, tdel
  Use xnet_controls, Only: lzactive, zone_id, kmon, ktot
  Use xnet_eos, Only: eos_ye=>ye
  Use xnet_ffn, Only: qkffn, rffn, phasei
  Use xnet_flux, Only: flx
  Use xnet_jacobian, Only: jac, rhs, indx, hjac, hrhs, hindx
  Use xnet_nnu, Only: tmevnu, ltnu, rnnu
  Use xnet_nse, Only: ynse
  Use xnet_screening, Only: h1
  Use consumer_fixture, Only: check, fixture_state
  Implicit None

  Type(xnet_controls_t) :: controls
  Type(xnet_network_t) :: network
  Type(xnet_timing_t) :: timing
  Integer(c_intptr_t), Allocatable :: addresses(:,:), table_addresses(:)
  Logical, Allocatable :: valid(:)
  Real(dp), Allocatable :: x(:,:), density(:), temperature(:), ye(:), restart(:), loss(:), aux_x(:), aux_a(:), aux_z(:)
  Integer, Allocatable :: ids(:,:), counters(:,:)
  Integer :: workers, capacity, cycle, worker, lane, i, j, ierr
  Character(80) :: data_dir, arg
  Character(512) :: message
  Logical :: active(1)

  Call check(Command_Argument_Count() == 2,'usage: worker_storage_consumer data_dir capacity')
  Call get_command_argument(1,data_dir)
  Call get_command_argument(2,arg)
  Read(arg,*) capacity
  Call check(capacity >= 2,'at least two lanes for stride checks')
  Call omp_set_dynamic(.false.)
  workers = omp_get_max_threads()
  Allocate(addresses(9,workers),table_addresses(workers),valid(workers))

  Do cycle = 1, 2
    Call set_xnet_controls_defaults(controls)
    controls%data_dir = data_dir
    controls%nzone = capacity
    controls%nzbatchmx = capacity
    controls%iprocess = 0
    controls%idiag = -2
    controls%iscrn = 1
    Call xnet_initialize(controls,network,ierr,message)
    Call check(ierr == xnet_success,'storage initialization: '//Trim(message))
    valid = .false.
    !$omp parallel default(shared) private(worker,lane)
    worker = omp_get_thread_num()+1
    valid(worker) = all(shape(y) == [ny,capacity]) .and. all(shape(th) == [2,capacity]) .and. &
      & lbound(gg,1) == 0 .and. ubound(gg,1) == ny .and. size(gg,2) == capacity .and. &
      & size(lzactive) == capacity .and. size(eos_ye) == capacity .and. size(jac,3) == capacity .and. &
      & size(tmevnu,1) == 2 .and. size(tmevnu,3) == capacity
    addresses(:,worker) = [int(loc(y),c_intptr_t),int(loc(th),c_intptr_t),int(loc(gg),c_intptr_t), &
      & int(loc(jac),c_intptr_t),int(loc(indx),c_intptr_t),int(loc(lzactive),c_intptr_t), &
      & int(loc(eos_ye),c_intptr_t),int(loc(qkffn),c_intptr_t),int(loc(tmevnu),c_intptr_t)]
    table_addresses(worker) = int(loc(aa),c_intptr_t)
    valid(worker) = valid(worker) .and. loc(y(1,2))-loc(y(1,1)) == ny*storage_size(y)/8 .and. &
      & loc(jac(1,1,2))-loc(jac(1,1,1)) == ny*ny*storage_size(jac)/8 .and. &
      & loc(rhs(1,2))-loc(rhs(1,1)) == ny*storage_size(rhs)/8 .and. &
      & loc(indx(1,2))-loc(indx(1,1)) == ny*storage_size(indx)/8 .and. &
      & transfer(hjac(1),0_c_intptr_t) == loc(jac(1,1,1)) .and. &
      & transfer(hrhs(1),0_c_intptr_t) == loc(rhs(1,1)) .and. &
      & transfer(hindx(1),0_c_intptr_t) == loc(indx(1,1))
    Do lane = 1, capacity
      y(:,lane) = real(1000*worker+lane,dp)
      t9(lane) = real(100*worker+lane,dp)
      zone_id(:,lane) = worker*100+lane
    EndDo
    !$omp barrier
    Do lane = 1, capacity
      valid(worker) = valid(worker) .and. all(y(:,lane) == real(1000*worker+lane,dp)) .and. &
        & t9(lane) == real(100*worker+lane,dp) .and. all(zone_id(:,lane) == worker*100+lane)
    EndDo
    !$omp end parallel
    Call check(all(valid),'local shapes, strides, pointer addresses and worker canaries')
    Call check(all(table_addresses == table_addresses(1)),'nuclear tables remain shared')
    Do i = 1, workers
      Do j = i+1, workers
        Call check(all(addresses(:,i) /= addresses(:,j)),'workers own distinct plain allocations')
      EndDo
    EndDo

    ! One submitted batch leaves the other fixed-team workers idle; every worker must still clean up.
    Allocate(x(ny,1),density(1),temperature(1),ye(1),restart(1),loss(1),aux_x(1),aux_a(1),aux_z(1),ids(4,1),counters(5,1))
    Call fixture_state(network%names,density,temperature,ye,x,restart,aux_x,aux_a,aux_z)
    active = .true.
    ids = 7
    Call xnet_burn_batch(1.0e-7_dp,active,ids,density,temperature,ye,x,restart,loss,counters,timing,ierr,message, &
      & aux_x=aux_x,aux_a=aux_a,aux_z=aux_z)
    Call check(ierr == xnet_success,'single short batch: '//Trim(message))
    !$omp parallel default(shared) private(worker)
    worker = omp_get_thread_num()+1
    valid(worker) = addresses(1,worker) == loc(y) .and. addresses(4,worker) == loc(jac)
    !$omp end parallel
    Call check(all(valid),'logical batches do not reallocate worker storage')
    Deallocate(x,density,temperature,ye,restart,loss,aux_x,aux_a,aux_z,ids,counters)

    Call xnet_finalize(ierr,message)
    Call check(ierr == xnet_success,'storage finalization')
    !$omp parallel default(shared) private(worker)
    worker = omp_get_thread_num()+1
    valid(worker) = .not. (allocated(y) .or. allocated(yo) .or. allocated(yt) .or. allocated(ystart) .or. &
      & allocated(ydot) .or. allocated(xext) .or. allocated(th) .or. allocated(tdel) .or. allocated(lzactive) .or. &
      & allocated(zone_id) .or. allocated(kmon) .or. allocated(ktot) .or. allocated(eos_ye) .or. allocated(gg) .or. &
      & allocated(dlngdt9) .or. allocated(b1) .or. allocated(csect1) .or. allocated(jac) .or. allocated(rhs) .or. &
      & allocated(indx) .or. allocated(hjac) .or. allocated(qkffn) .or. allocated(rffn) .or. allocated(phasei) .or. &
      & allocated(flx) .or. allocated(tmevnu) .or. allocated(ltnu) .or. allocated(rnnu) .or. allocated(ynse) .or. allocated(h1))
    !$omp end parallel
    Call check(all(valid),'all workers release storage, including workers with no burn')
  EndDo
  Deallocate(addresses,table_addresses,valid)
  Write(*,'(a,2i5)') 'PASS worker storage, capacity/workers:',capacity,workers
End Program worker_storage_consumer
