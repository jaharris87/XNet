!***************************************************************************************************
! net.F90
! Standalone trajectory driver program for XNet.
!
! Reads runtime controls from controls.nml, optionally preprocesses nuclear and reaction data,
! initializes solver and accelerator workspaces, and evolves thermodynamic trajectories across
! zones distributed over MPI ranks and OpenMP worker batches.
!
! To embed XNet inside a hydrodynamics or multiphysics application, use the library interface in
! xnet_api.F90 (documented in docs/development/embedding.md) rather than calling full_net directly.
!***************************************************************************************************

#include "xnet_macros.fh"

Program net
  Use model_input_ascii, Only: load_initial_abundances, read_thermo_file
  Use nuclear_data, Only: ny, nname, index_from_name, read_nuclear_data
!$ Use omp_lib
  Use reaction_data, Only: read_reaction_data
  Use xnet_abundances, Only: ystart, y, xext, zext, aext, abundances_initialize, abundances_finalize
  Use xnet_conditions, Only: t, tdel, t9, rho, ye, nt, nstart, tstart, tstop, tdelstart, &
    & t9start, rhostart, yestart, nh, th, t9h, rhoh, yeh, nhmx, t9rhofind, &
    & conditions_initialize, conditions_finalize
  Use xnet_controls, Only: idiag, inucout, iprocess, isolv, itsout, nnucout, output_nuc, &
    & szone, nzone, zone_id, kstmx, ev_file_base, bin_file_base, thermo_file, inab_file, &
    & lun_diag, lun_stdout, tid, gpu_queue, nthread, nzevolve, nzbatchmx, nzbatch, szbatch, &
    & zb_offset, zb_lo, zb_hi, lzactive, myid, nproc, read_controls, write_controls
  Use xnet_eos, Only: eos_initialize
  Use xnet_evolve, Only: full_net
  Use xnet_flux, Only: flx_int, flux_init
  Use xnet_gpu, Only: gpu_init, gpu_finalize
  Use xnet_integrate_bdf, Only: bdf_init
  Use xnet_integrate_be, Only: be_init
  Use xnet_jacobian, Only: read_jacobian_data
  Use xnet_match, Only: mflx, nflx, read_match_data
  Use xnet_nnu, Only: tmevnu, fluxcms, nnu_initialize, nnu_finalize
  Use xnet_nse, Only: nse_initialize
  Use xnet_output, Only: open_ts_file, open_ev_file, close_output_files
  Use xnet_parallel, Only: parallel_finalize, parallel_initialize, parallel_myproc, &
    & parallel_nprocs, parallel_IOProcessor
  Use xnet_preprocess, Only: net_preprocess
  Use xnet_screening, Only: screening_init
  Use xnet_timers, Only: xnet_wtime, start_timer, stop_timer, timer_setup
  Use xnet_types, Only: dp
  Use xnet_util, Only: getNewUnit, name_ordered, xnet_terminate
  Implicit None

  ! Local variables
  Integer :: i, k, izone, izb, ibatch, batch_count
  Integer :: diag_ierr, ierr, inuc, kstep
  Real(dp), Allocatable :: dyf(:), flx_diff(:), denu(:)
  Character(80) :: data_desc, data_dir
  Character(80), Allocatable :: abund_desc(:), thermo_desc(:)
  Character(80) :: ev_file, bin_file, diag_file
  Character(80), Parameter :: diag_file_base = 'net_diag'

  !-------------------------------------------------------------------------------------------------
  ! 1. Initialize MPI, OpenMP thread IDs, and GPU runtime
  !-------------------------------------------------------------------------------------------------
  Call parallel_initialize()
  myid  = parallel_myproc()
  nproc = parallel_nprocs()

#ifdef XNET_OMP
  !$omp parallel default(shared)
#endif
  tid = 1
  !$ tid = omp_get_thread_num() + 1
  !$omp single
  nthread = 1
  !$ nthread = omp_get_num_threads()
  !$omp end single
#ifdef XNET_OMP
  !$omp end parallel
#endif

  Call gpu_init()

  start_timer = xnet_wtime()
  timer_setup = timer_setup - start_timer

  !-------------------------------------------------------------------------------------------------
  ! 2. Read and apply standalone controls; optionally preprocess nuclear data
  !-------------------------------------------------------------------------------------------------
  Call read_controls(data_dir)

  If ( iprocess > 0 .and. parallel_IOProcessor() ) Then
    Call net_preprocess(lun_stdout,data_dir,data_dir)
  EndIf

  !-------------------------------------------------------------------------------------------------
  ! 3. Open per-thread diagnostic output files and log resolved controls
  !-------------------------------------------------------------------------------------------------
  ! Keep the long-lived diagnostic stream on a positive logical unit; some compiler runtimes can
  ! alias negative NEWUNIT values after many short-lived per-zone files are opened and closed.
#ifdef XNET_OMP
  !$omp parallel default(shared) private(diag_file,diag_ierr)
#endif
  If ( idiag >= 0 ) Then
    diag_file = trim(diag_file_base)
    Call name_ordered(diag_file,myid,nproc)
    Call name_ordered(diag_file,tid,nthread)
    diag_ierr = 0
    !$omp critical(diag_open)
    lun_diag = getNewUnit()
    If ( lun_diag > 0 ) Open(unit=lun_diag,file=diag_file,action='write',iostat=diag_ierr)
    !$omp end critical(diag_open)
    If ( lun_diag == 0 ) Call xnet_terminate('No free logical unit for diagnostic output')
    If ( diag_ierr /= 0 ) Call xnet_terminate('Failed to open diagnostic output: '//trim(diag_file),diag_ierr)
    Write(lun_diag,"(a5,2i5)") 'MyId',myid,nproc
#ifdef XNET_OMP
    !$ Write(lun_diag,"(a,i4,a,i4)") 'Thread ',tid,' of ',nthread
#endif
  Else
    lun_diag = lun_stdout
  EndIf
  Call write_controls(lun_diag,data_dir)
#ifdef XNET_OMP
  !$omp end parallel
#endif

  !-------------------------------------------------------------------------------------------------
  ! 4. Load network data and initialize physics, solver, and zone workspaces
  !-------------------------------------------------------------------------------------------------
  Call read_nuclear_data(data_dir,data_desc)
  Call read_reaction_data(data_dir)
  If ( idiag >= 0 ) Write(lun_diag,"(a)") data_desc
  Call read_jacobian_data(data_dir)
  Call read_match_data(data_dir)

  Call screening_init
  Call flux_init
  Call eos_initialize
  If ( isolv == 1 ) Call be_init
  If ( isolv == 3 ) Call bdf_init

  ! Resolve condensed ASCII output species names to network indices
  Do i = 1, nnucout
    Call index_from_name(output_nuc(i),inuc)
    If ( inuc < 1 .or. inuc > ny ) Then
      Write(lun_stdout,*) 'Output Nuc:',i,output_nuc(i),' not found'
      inucout(i) = ny
    Else
      inucout(i) = inuc
    EndIf
  EndDo

  Call nse_initialize
  Call abundances_initialize
  Call conditions_initialize(nhmx)
  Call nnu_initialize(nhmx)

  Allocate (abund_desc(nzevolve),thermo_desc(nzevolve),denu(nzevolve))
  denu = 0.0_dp

  !XDIR XENTER_DATA XASYNC(gpu_queue) &
  !XDIR XCOPYIN(denu)
  !XDIR XWAIT(gpu_queue)

  stop_timer = xnet_wtime()
  timer_setup = timer_setup + stop_timer

  !-------------------------------------------------------------------------------------------------
  ! 5. Evolve zone batches across MPI ranks and OpenMP worker threads
  !-------------------------------------------------------------------------------------------------
  batch_count = (nzone + nzbatchmx - 1) / nzbatchmx

#ifdef XNET_OMP
  !$omp parallel default(shared) &
  !$omp   private(dyf,flx_diff,ev_file,bin_file,izone,ierr,ibatch,izb,kstep) &
  !$omp   copyin(timer_setup)
#endif

  start_timer = xnet_wtime()
  timer_setup = timer_setup - start_timer
  Allocate (dyf(0:ny),flx_diff(ny))
  stop_timer = xnet_wtime()
  timer_setup = timer_setup + stop_timer

  !$omp do
  Do ibatch = myid+1, batch_count, nproc

    start_timer = xnet_wtime()
    timer_setup = timer_setup - start_timer

    ! Determine active zones in this worker batch
    szbatch = szone + (ibatch - 1) * nzbatchmx
    nzbatch = min(nzone - szbatch + 1, nzbatchmx)
    Do izb = zb_lo, zb_hi
      lzactive(izb) = ( izb <= zb_offset + nzbatch )
    EndDo

    ! Read thermodynamic trajectories and interpolate conditions at tstart
    Call read_thermo_file(thermo_file,thermo_desc,ierr)
    Do izb = zb_lo, zb_hi
      If ( lzactive(izb) ) Then
        Call t9rhofind(0,tstart(izb),nstart(izb),t9start(izb),rhostart(izb), &
          & nh(izb),th(:,izb),t9h(:,izb),rhoh(:,izb))
      EndIf
    EndDo

    ! Load initial abundances (from file or NSE) and initialize zone state
    Call load_initial_abundances(inab_file,abund_desc,ierr)
    Do izb = zb_lo, zb_hi
      tdel(izb)      = 0.0_dp
      nt(izb)        = nstart(izb)
      t(izb)         = tstart(izb)
      t9(izb)        = t9start(izb)
      rho(izb)       = rhostart(izb)
      ye(izb)        = yestart(izb)
      y(:,izb)       = ystart(:,izb)
      zone_id(:,izb) = [izb,1,1,0]
    EndDo

    ! Open per-zone binary and ASCII time-series output files when requested
    If ( itsout > 0 ) Then
      Do izb = zb_lo, zb_hi
        If ( lzactive(izb) ) Then
          izone = izb + szbatch - zb_lo
          Write(lun_stdout,"(a,i6,a,i2,2(a,es10.3))") &
            & 'Max Step',kstmx,' IDiag=',idiag,' Start Time',tstart(izb),' Stop Time',tstop(izb)

          If ( itsout >= 1 ) Then
            bin_file = trim(bin_file_base)
            Call name_ordered(bin_file,izone,nzone)
            Call open_ts_file(izb,bin_file,data_desc,inab_file(izone),abund_desc(izb), &
              & thermo_file(izone),thermo_desc(izb),status='unknown')
          EndIf

          If ( itsout >= 2 ) Then
            ev_file = trim(ev_file_base)
            Call name_ordered(ev_file,izone,nzone)
            If ( idiag >= 0 ) Write(lun_diag,"(a,i5,7es10.3)") trim(ev_file), &
              & nh(izb),th(nh(izb),izb),t9h(nh(izb),izb),rhoh(nh(izb),izb),tstart(izb),tstop(izb)
            Call open_ev_file(izb,ev_file,status='unknown')
          EndIf
        EndIf
      EndDo
    EndIf

    !XDIR XUPDATE XASYNC(gpu_queue) &
    !XDIR XDEVICE(xext,aext,zext) &
    !XDIR XDEVICE(lzactive,tdel,t,t9,rho,ye,y,nt) &
    !XDIR XDEVICE(tstart,tstop,tdelstart,nstart,t9start,rhostart,yestart,ystart) &
    !XDIR XDEVICE(nh,th,t9h,rhoh,yeh,tmevnu,fluxcms)

    stop_timer = xnet_wtime()
    timer_setup = timer_setup + stop_timer

    ! Evolve abundances from tstart to tstop
    Call full_net(kstep,denu(zb_lo:zb_hi))

    ! Compare integrated reaction fluxes against net abundance changes when idiag >= 3
    If ( idiag >= 3 ) Then
      !XDIR XUPDATE XWAIT(gpu_queue) &
      !XDIR XHOST(y)
      Do izb = zb_lo, zb_hi
        If ( lzactive(izb) ) Then
          dyf = 0.0_dp
          Do k = 1, mflx
            dyf(nflx(1:4,k)) = dyf(nflx(1:4,k)) + flx_int(k,izb)
            dyf(nflx(5:8,k)) = dyf(nflx(5:8,k)) - flx_int(k,izb)
          EndDo
          flx_diff(:) = y(:,izb) - ystart(:,izb) + dyf(1:ny)
          Write(lun_diag,"(a,es11.3)") 'Compare Integrated flux to abundance change',dyf(0)
          Write(lun_diag,"(a)") 'Species Flux Sum + Y Final - Y Initial = Flux Diff'
          Write(lun_diag,"(a5,4es11.3)") (nname(k),dyf(k),y(k,izb),ystart(k,izb),flx_diff(k),k=1,ny)
        EndIf
      EndDo
    EndIf

    Call close_output_files
  EndDo
  !$omp end do

  Deallocate (dyf,flx_diff)
  If ( idiag >= 0 ) Close(lun_diag)
#ifdef XNET_OMP
  !$omp end parallel
#endif

  !-------------------------------------------------------------------------------------------------
  ! 6. Release workspaces, GPU handles, and MPI resources
  !-------------------------------------------------------------------------------------------------
  !XDIR XEXIT_DATA XASYNC(gpu_queue) &
  !XDIR XDELETE(denu)
  !XDIR XWAIT(gpu_queue)

  Deallocate (abund_desc,thermo_desc,denu)

  Call nnu_finalize
  Call abundances_finalize
  Call conditions_finalize
  Call gpu_finalize()
  Call parallel_finalize()

End Program net
