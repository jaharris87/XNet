!***************************************************************************************************
! xnet_controls.F90
! Configuration types, namelist I/O, validation, and runtime execution state for XNet.
!
! Two configuration paths share this module:
! - Library API (xnet_api): Call set_xnet_controls_defaults, override fields on xnet_controls_t,
!   and pass the structure to xnet_initialize, which validates and applies it via
!   apply_xnet_controls.
! - Standalone Driver (net): Call read_controls, which reads controls.nml (and any layered
!   include_files), normalizes per-zone input filenames, validates standalone requirements,
!   broadcasts the resolved structure across MPI ranks, and applies it via
!   apply_standalone_controls.
!
! Core lifecycle and validation routines appear first, followed by standalone namelist I/O and
! MPI broadcast routines, and finally parsing and array-sizing helpers.
!***************************************************************************************************

#include "xnet_macros.fh"

Module xnet_controls
  Use, Intrinsic :: iso_fortran_env, Only: lun_stderr=>error_unit, lun_stdin=>input_unit, &
    & lun_stdout=>output_unit
  Use xnet_types, Only: dp
  Use xnet_util, Only: last_nonblank_index
  Implicit None

  !-------------------------------------------------------------------------------------------------
  ! Namelist reader limits and default filename
  !-------------------------------------------------------------------------------------------------
  Real(dp), Parameter, Private :: bdf_change_limit = 1.0e10_dp ! Disable BE change limits under BDF
  Character(*), Parameter :: standalone_controls_file = 'controls.nml'
  Integer, Parameter :: max_includes_per_file = 16   ! Maximum direct include_files per file
  Integer, Parameter :: max_include_depth     = 16   ! Maximum recursive include nesting depth
  Integer, Parameter :: controls_path_length  = 1024 ! Maximum character length for controls paths

  !-------------------------------------------------------------------------------------------------
  ! Caller-facing configuration structure
  !-------------------------------------------------------------------------------------------------
  ! Component initializers are intentionally invalid sentinels so an uninitialized structure
  ! cannot silently pass validation. Always call set_xnet_controls_defaults(controls) first.
  Type :: xnet_controls_t
    ! Output levels (cumulative; each level includes the ones below it):
    !   idiag  <= -2: suppress normal diagnostics
    !          == -1: final counters and timers only
    !          >=  0: initial and final abundances, counters and timers
    !          >=  1: one line per timestep and integrated reaction fluxes
    !          >=  3: abundance change (delta Y) tables for each timestep
    !          Standalone XNet writes these to the diagnostic file net_diag; the library API
    !          writes them to standard output.
    !   itsout >=  1: binary time-series file for each zone
    !          >=  2: ASCII evolution file for each zone, with the nnucout species in output_nuclei
    !          >=  3: one line per timestep on standard output
    !          >=  4: mass fractions at each timestep in the diagnostic output
    !          >=  5: reaction fluxes at each timestep in the diagnostic output
    !          Levels 4 and 5 also require idiag >= 0. Higher idiag levels enable solver details.

    ! Problem description (written to binary time-series headers)
    Character(80) :: description(3) = ' '

    ! Job and physics controls
    Integer :: szone     = 0          ! Standalone starting zone index (1 <= szone <= nzone)
    Integer :: nzone     = 0          ! Standalone total number of zones (>= 1)
    Integer :: iweak0    = 0          ! Weak rates: >0 strong+weak, =0 strong only, <0 weak only
    Integer :: iscrn     = 0          ! Plasma screening: >0 enabled, <=0 disabled
    Integer :: iprocess  = 0          ! Network preprocessing: >0 run net_preprocess on data_dir

    ! Zone batching controls
    Integer :: nzbatchmx = 0          ! Maximum zones per worker batch (>= 1)

    ! Integration controls
    Integer :: isolv         = 0       ! Integrator selection: 1 = Backward Euler (BE), 3 = Gear BDF
    Integer :: kstmx         = 0       ! Maximum outer integration steps per burn (>= 1)
    Integer :: kitmx         = 0       ! Maximum Newton iterations per step attempt (>= 1)
    Integer :: ijac          = 0       ! BE Jacobian rebuild interval after the first iteration (>= 1)
    Integer :: iconvc        = 0       ! Convergence norm (BE: 0=mass, /=0=rel Y; BDF: 0=inf, 1=L1, 2=L2, 3=RMS)
    Real(dp) :: changemx     = -1.0_dp ! BE relative abundance change target for timestep selection (> 0)
    Real(dp) :: yacc         = -1.0_dp ! Abundance floor Y=X/A for timestep/BDF error weighting (>= 0)
    Real(dp) :: tolm         = -1.0_dp ! BE mass-conservation convergence tolerance (> 0)
    Real(dp) :: tolc         = -1.0_dp ! Iterative relative abundance convergence tolerance (> 0)
    Real(dp) :: ymin         = -1.0_dp ! Abundance cutoff Y=X/A below which species are zeroed (>= 0)
    Real(dp) :: tdel_maxmult = -1.0_dp ! BE maximum timestep growth / retry reduction factor (> 0)

    ! Self-heating controls
    Integer :: iheat     = 0          ! Self-heating: >0 couples temperature implicitly to network
    Real(dp) :: changemxt = -1.0_dp   ! BE relative temperature change target for timestep selection (> 0)
    Real(dp) :: tolt9     = -1.0_dp   ! Iterative relative temperature convergence tolerance (> 0)

    ! NSE initial condition controls (standalone driver only)
    Real(dp) :: t9nse = -1.0_dp       ! Temperature threshold [GK] above which standalone uses NSE (>= 0)

    ! Neutrino controls (standalone driver only; unsupported in library API)
    Integer :: ineutrino = 0          ! Neutrino capture reactions: >0 enabled, =0 disabled

    ! Diagnostic and time-series output controls
    Integer :: idiag            = 0   ! Diagnostic verbosity (see the output-level table above)
    Integer :: itsout           = 0   ! Cumulative per-step output level (see above)
    Character(80) :: ev_file_base  = ' ' ! ASCII evolution filename prefix
    Character(80) :: bin_file_base = ' ' ! Binary time-series filename prefix
    Integer :: nnucout          = -1  ! Number of species in condensed ASCII output (>= 0)
    Character(5), Allocatable :: output_nuclei(:) ! Species names (1:nnucout) for condensed ASCII output

    ! Network data directory and standalone input file lists
    Character(80) :: data_dir = ' '               ! Directory containing prepared/raw network files
    Character(80), Allocatable :: inab_files(:)   ! Standalone initial-abundance filenames
    Character(80), Allocatable :: thermo_files(:) ! Standalone thermodynamic-trajectory filenames
  End Type xnet_controls_t

  ! When adding a control, update controls.defaults, validation, runtime application,
  ! namelist reading/writing, and broadcast_xnet_controls. Extend test_xnet_controls accordingly.

  !-------------------------------------------------------------------------------------------------
  ! Runtime Control State and Worker Workspace Bookkeeping
  !-------------------------------------------------------------------------------------------------
  ! Populated by apply_xnet_controls / apply_standalone_controls and released by controls_finalize.
  ! Each OpenMP worker owns a disjoint workspace slice zb_lo:zb_hi within 1:nzevolve.
  ! For a workspace slot izb in zb_lo:zb_hi, the corresponding input-zone ordinal is
  ! izone = izb + szbatch - zb_lo.

  ! Problem description
  Character(80) :: descript(3)

  ! Job and physics controls
  Integer              :: szone        ! Standalone starting zone index
  Integer              :: nzone        ! Standalone total number of zones
  Integer              :: iweak0       ! Baseline weak-reaction control flag
  Integer, Allocatable :: iweak(:)     ! Per-zone active weak-reaction flag (1:nzevolve)
  Integer              :: iscrn        ! Plasma screening control flag
  Integer              :: iprocess     ! Runtime network preprocessing flag
  Real(dp)             :: t9min = 0.01_dp ! Temperature [GK] below which strong reactions are disabled

  ! Worker batch indexing and zone state
  Integer :: nzevolve                  ! Total zone workspace capacity across all workers (nzbatchmx * nthread)
  Integer :: nzbatchmx                 ! Maximum zones per worker batch
  Integer :: nzbatch                   ! Number of active zones in the current worker batch
  Integer :: szbatch                   ! Starting zone ordinal corresponding to workspace slot zb_lo
  Integer :: zb_offset                 ! Zero-based workspace offset for the calling worker (zb_lo - 1)
  Integer :: zb_lo                     ! First workspace slot owned by the calling worker
  Integer :: zb_hi                     ! Last workspace slot owned by the calling worker
  Logical, Allocatable, Target :: lzactive(:) ! Active-zone mask indexed by workspace slot (1:nzevolve)
  Integer, Allocatable :: zone_id(:,:) ! Mesh location tuple [i,j,k,block] per workspace slot (4,nzevolve)
#ifdef XNET_OMP
  !$omp threadprivate(nzbatch,szbatch,zb_offset,zb_lo,zb_hi)
#endif

  ! Integration controls and work counters
  Integer  :: isolv                    ! Integration method (1 = BE, 3 = BDF)
  Integer  :: kstmx                    ! Maximum outer integration steps
  Integer  :: kitmx                    ! Maximum Newton iterations per step attempt
  Integer  :: ijac                     ! BE Jacobian rebuild interval
  Integer  :: iconvc                   ! Convergence condition selector
  Real(dp) :: changemx                 ! Relative abundance change limit for timestep selection
  Real(dp) :: yacc                     ! Abundance floor for timestep and BDF error weighting
  Real(dp) :: tolc                     ! Relative abundance convergence tolerance
  Real(dp) :: tolm                     ! Mass-conservation tolerance
  Real(dp) :: ymin                     ! Minimum abundance cutoff
  Real(dp) :: tdel_maxmult             ! Maximum timestep growth factor
  Integer, Allocatable :: kmon(:,:)    ! Per-step solver counters [TS, NR, Jac, Deriv, CSect] (5,nzevolve)
  Integer, Allocatable :: ktot(:,:)    ! Cumulative solver counters over the burn (5,nzevolve)

  ! Self-heating, NSE, and neutrino controls
  Integer  :: iheat                    ! Implicit temperature coupling flag
  Real(dp) :: changemxt                ! Relative temperature change limit for timestep selection
  Real(dp) :: tolt9                    ! Relative temperature convergence tolerance
  Real(dp) :: t9nse                    ! Standalone NSE initial-condition threshold [GK]
  Integer  :: ineutrino                ! Standalone neutrino-capture reaction flag

  ! Output and diagnostic controls
  Integer :: idiag                     ! Diagnostic output verbosity level
  Integer :: itsout                    ! Per-timestep output level
  Integer :: nnucout                   ! Number of species in condensed ASCII output
  Character(4) :: nnucout_string       ! Formatted nnucout width string for ASCII format statements
  Character(5), Allocatable :: output_nuc(:) ! Condensed-output species names (1:nnucout)
  Integer, Allocatable :: inucout(:)   ! Condensed-output species indices (1:nnucout)
  Character(80) :: ev_file_base        ! ASCII evolution filename prefix
  Character(80) :: bin_file_base       ! Binary time-series filename prefix
  Integer, Allocatable :: lun_ts(:)    ! Open binary time-series logical units (1:nzevolve; 0 = closed)
  Integer, Allocatable :: lun_ev(:)    ! Open ASCII evolution logical units (1:nzevolve; 0 = closed)
  Integer :: lun_diag                  ! Per-thread diagnostic logical unit
#ifdef XNET_OMP
  !$omp threadprivate(lun_diag)
#endif

  ! Standalone input file controls
  Character(80) :: inab_file_base      ! Legacy initial-abundance filename prefix
  Character(80) :: thermo_file_base    ! Legacy thermodynamic-trajectory filename prefix
  Character(80), Allocatable :: inab_file(:)   ! Per-zone initial-abundance filenames (1:nzone)
  Character(80), Allocatable :: thermo_file(:) ! Per-zone thermodynamic-trajectory filenames (1:nzone)
  Integer, Allocatable :: iaux(:)      ! Per-zone auxiliary-nucleus retention flag (1:nzevolve)
  Integer :: lun_th, lun_ab            ! Per-thread temporary input logical units
#ifdef XNET_OMP
  !$omp threadprivate(lun_th,lun_ab)
#endif

  ! Parallel and accelerator execution state
  Integer :: myid                      ! MPI rank index (0-based)
  Integer :: nproc                     ! Total MPI ranks
  Integer :: tid                       ! OpenMP worker thread index (1-based)
  Integer :: nthread                   ! Total OpenMP worker threads in the fixed team
  Integer :: gpu_queue = 1             ! Directive async queue ID (OpenACC async queue or thread ID)
  Character(1) :: sweep                ! Legacy hydrodynamic sweep label
#ifdef XNET_OMP
  !$omp threadprivate(tid,sweep,gpu_queue)
#endif

  ! Accelerator kernels read these scalar controls directly on the device.
  !XDIR XDECLARE_VAR(iheat,iscrn,iconvc,ymin)

Contains

  !=================================================================================================
  ! Control Defaults, Validation, and Runtime Application
  !=================================================================================================

  Subroutine set_xnet_controls_defaults(controls)
    !-----------------------------------------------------------------------------------------------
    ! Initialize an xnet_controls_t instance with the compiled defaults from controls.defaults
    ! and empty allocated array components. Call before overriding fields for xnet_initialize.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Output arguments
    Type(xnet_controls_t), Intent(out) :: controls

    controls = xnet_controls_t()
    Allocate (controls%output_nuclei(0),controls%inab_files(0),controls%thermo_files(0))
    Include 'controls.defaults'

    Return
  End Subroutine set_xnet_controls_defaults

  Subroutine validate_xnet_controls(controls,ierr,message)
    !-----------------------------------------------------------------------------------------------
    ! Check supported solver choices, array sizes, and required control values.
    ! Returns ierr = 0 on success or ierr = 1 with a diagnostic message on the first invalid field.
    !-----------------------------------------------------------------------------------------------
    Use, Intrinsic :: ieee_arithmetic, Only: ieee_is_finite
    Implicit None

    ! Input arguments
    Type(xnet_controls_t), Intent(in) :: controls

    ! Output arguments
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message

    ierr = 1
    message = ' '

    If ( .not. allocated(controls%inab_files) .or. .not. allocated(controls%thermo_files) .or. &
      & .not. allocated(controls%output_nuclei) ) Then
      message = 'XNet control arrays must be allocated'
    ElseIf ( .not. ieee_is_finite(controls%changemx) .or. &
      & .not. ieee_is_finite(controls%yacc) .or. &
      & .not. ieee_is_finite(controls%tolm) .or. &
      & .not. ieee_is_finite(controls%tolc) .or. &
      & .not. ieee_is_finite(controls%ymin) .or. &
      & .not. ieee_is_finite(controls%tdel_maxmult) .or. &
      & .not. ieee_is_finite(controls%changemxt) .or. &
      & .not. ieee_is_finite(controls%tolt9) .or. &
      & .not. ieee_is_finite(controls%t9nse) ) Then
      message = 'XNet real-valued controls must be finite'
    ElseIf ( controls%nzone < 1 ) Then
      message = 'nzone must be positive'
    ElseIf ( controls%nnucout < 0 ) Then
      message = 'nnucout must be nonnegative'
    ElseIf ( controls%nnucout > size(controls%output_nuclei) ) Then
      message = 'nnucout exceeds the number of supplied output_nuclei'
    ElseIf ( controls%nnucout > 0 .and. &
      & any(len_trim(controls%output_nuclei(:controls%nnucout)) == 0) ) Then
      message = 'one output_nuclei entry is required for each requested output species'
    ElseIf ( controls%szone < 1 .or. controls%szone > controls%nzone ) Then
      message = 'szone must select an existing zone'
    ElseIf ( controls%isolv /= 1 .and. controls%isolv /= 3 ) Then
      message = 'isolv must be 1 (BE) or 3 (BDF)'
    ElseIf ( controls%ijac < 1 ) Then
      message = 'ijac must be positive'
    ElseIf ( controls%nzbatchmx < 1 .or. controls%kitmx < 1 .or. controls%kstmx < 1 ) Then
      message = 'batch, iteration, and step limits must be positive'
    ElseIf ( controls%tdel_maxmult <= 0.0_dp ) Then
      message = 'tdel_maxmult must be positive'
    ElseIf ( controls%changemx <= 0.0_dp .or. controls%yacc < 0.0_dp ) Then
      message = 'changemx must be positive and yacc nonnegative'
    ElseIf ( controls%changemxt <= 0.0_dp .or. controls%tolt9 <= 0.0_dp ) Then
      message = 'self-heating change and convergence limits must be positive'
    ElseIf ( controls%t9nse < 0.0_dp ) Then
      message = 't9nse must be nonnegative'
    ElseIf ( controls%tolc <= 0.0_dp .or. controls%tolm <= 0.0_dp .or. controls%ymin < 0.0_dp ) Then
      message = 'integration tolerances must be positive and ymin nonnegative'
    Else
      ierr = 0
    EndIf

    Return
  End Subroutine validate_xnet_controls

  Subroutine validate_standalone_controls(controls,ierr,message)
    !-----------------------------------------------------------------------------------------------
    ! Validate common controls plus the nuclear data directory and per-zone abundance/trajectory
    ! input file pairs required by the standalone XNet driver.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Input arguments
    Type(xnet_controls_t), Intent(in) :: controls

    ! Output arguments
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message

    ! Local variables
    Integer :: input_count

    Call validate_xnet_controls(controls,ierr,message)
    If ( ierr /= 0 ) Return

    ierr = 1
    If ( len_trim(controls%data_dir) == 0 ) Then
      message = 'data_dir is required for the standalone driver'
    ElseIf ( size(controls%inab_files) == 0 .or. size(controls%thermo_files) == 0 ) Then
      message = 'inab_files and thermo_files are required for the standalone driver'
    ElseIf ( max(last_nonblank_index(controls%inab_files), &
      & last_nonblank_index(controls%thermo_files)) > controls%nzone ) Then
      message = 'the number of input file pairs cannot exceed nzone'
    ElseIf ( is_hdf_thermo_file(controls%thermo_files(1)) ) Then
      ! HDF5 input files may contain multiple zones per file; require contiguous pairs without holes.
      input_count = max(last_nonblank_index(controls%inab_files), &
        & last_nonblank_index(controls%thermo_files))
      If ( any(len_trim(controls%inab_files(:input_count)) == 0) .or. &
        & any(len_trim(controls%thermo_files(:input_count)) == 0) ) Then
        message = 'each HDF5 input entry needs both inab_files and thermo_files'
      Else
        ierr = 0
      EndIf
    ElseIf ( size(controls%inab_files) < controls%nzone .or. &
      & size(controls%thermo_files) < controls%nzone ) Then
      message = 'one inab_files and thermo_files entry is required per zone'
    ElseIf ( any(len_trim(controls%inab_files(:controls%nzone)) == 0) .or. &
      & any(len_trim(controls%thermo_files(:controls%nzone)) == 0) ) Then
      message = 'one inab_files and thermo_files entry is required per zone'
    Else
      ierr = 0
    EndIf

    Return
  End Subroutine validate_standalone_controls

  Subroutine apply_xnet_controls(controls,ierr,message)
    !-----------------------------------------------------------------------------------------------
    ! Validate controls, copy them into the module runtime state, allocate per-zone bookkeeping
    ! for nzevolve = nzbatchmx * nthread workspace slots, assign each OpenMP worker its disjoint
    ! zb_lo:zb_hi bank, and map device-resident control arrays.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Input arguments
    Type(xnet_controls_t), Intent(in) :: controls

    ! Output arguments
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message

    Call validate_xnet_controls(controls,ierr,message)
    If ( ierr /= 0 ) Return
    If ( allocated(zone_id) ) Then
      ierr = 1
      message = 'XNet execution controls are already allocated'
      Return
    EndIf

    descript      = controls%description
    szone         = controls%szone
    nzone         = controls%nzone
    iweak0        = controls%iweak0
    iscrn         = controls%iscrn
    iprocess      = controls%iprocess
    nzbatchmx     = controls%nzbatchmx
    isolv         = controls%isolv
    kstmx         = controls%kstmx
    kitmx         = controls%kitmx
    ijac          = controls%ijac
    iconvc        = controls%iconvc
    changemx      = controls%changemx
    yacc          = controls%yacc
    tolm          = controls%tolm
    tolc          = controls%tolc
    ymin          = controls%ymin
    tdel_maxmult  = controls%tdel_maxmult
    iheat         = controls%iheat
    changemxt     = controls%changemxt
    tolt9         = controls%tolt9
    t9nse         = controls%t9nse
    ineutrino     = controls%ineutrino
    idiag         = controls%idiag
    itsout        = controls%itsout
    ev_file_base  = controls%ev_file_base
    bin_file_base = controls%bin_file_base
    nnucout       = controls%nnucout

    ! Gear BDF regulates its own steps and does not use the Backward-Euler change limits.
    If ( isolv == 3 ) Then
      changemx  = bdf_change_limit
      changemxt = bdf_change_limit
    EndIf

    nzevolve = nzbatchmx * nthread
    Allocate (zone_id(4,nzevolve),lzactive(nzevolve),iweak(nzevolve), &
      & lun_ev(nzevolve),lun_ts(nzevolve),iaux(nzevolve), &
      & kmon(5,nzevolve),ktot(5,nzevolve),output_nuc(nnucout),inucout(nnucout))
    zone_id  = 0
    lzactive = .false.
    iweak    = iweak0
    iaux     = 0
    lun_ev   = 0
    lun_ts   = 0
    kmon     = 0
    ktot     = 0
    inucout  = 0
    If ( nnucout > 0 ) output_nuc = controls%output_nuclei(:nnucout)
    Write(nnucout_string,'(i4)') nnucout
    nnucout_string = adjustl(nnucout_string)

#ifdef XNET_OMP
    !$omp parallel default(shared)
#endif
    zb_offset = (tid - 1) * nzbatchmx
    zb_lo     = zb_offset + 1
    zb_hi     = zb_offset + nzbatchmx
#ifdef XNET_OMP
    !$omp end parallel
#endif

    !XDIR XUPDATE XASYNC(gpu_queue) &
    !XDIR XDEVICE(iheat,iscrn,iconvc,ymin)
    !XDIR XENTER_DATA XASYNC(gpu_queue) &
    !XDIR XCREATE(lzactive,iweak,kmon,ktot)

    Return
  End Subroutine apply_xnet_controls

  Subroutine apply_standalone_controls(controls,data_dir)
    !-----------------------------------------------------------------------------------------------
    ! Validate and apply controls for the standalone driver, including per-zone input filenames.
    ! Terminates on invalid configuration.
    !-----------------------------------------------------------------------------------------------
    Use xnet_util, Only: xnet_terminate
    Implicit None

    ! Input arguments
    Type(xnet_controls_t), Intent(in) :: controls

    ! Output arguments
    Character(*), Intent(out) :: data_dir

    ! Local variables
    Character(256) :: message
    Integer :: ierr

    Call validate_standalone_controls(controls,ierr,message)
    If ( ierr /= 0 ) Call xnet_terminate(trim(message))

    Call apply_xnet_controls(controls,ierr,message)
    If ( ierr /= 0 ) Call xnet_terminate(trim(message))

    data_dir = controls%data_dir
    Allocate (inab_file(nzone),thermo_file(nzone))
    inab_file   = controls%inab_files(:nzone)
    thermo_file = controls%thermo_files(:nzone)

    Return
  End Subroutine apply_standalone_controls

  Subroutine controls_finalize
    !-----------------------------------------------------------------------------------------------
    ! Release XNet-owned device mappings before deallocating CPU control and bookkeeping arrays.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    If ( allocated(lzactive) ) Then
      !XDIR XEXIT_DATA XASYNC(gpu_queue) &
      !XDIR XDELETE(lzactive,iweak,kmon,ktot)
      !XDIR XWAIT(gpu_queue)
    EndIf
    If ( allocated(zone_id) )     Deallocate (zone_id)
    If ( allocated(iweak) )       Deallocate (iweak)
    If ( allocated(lzactive) )    Deallocate (lzactive)
    If ( allocated(kmon) )        Deallocate (kmon)
    If ( allocated(ktot) )        Deallocate (ktot)
    If ( allocated(inucout) )     Deallocate (inucout)
    If ( allocated(lun_ts) )      Deallocate (lun_ts)
    If ( allocated(lun_ev) )      Deallocate (lun_ev)
    If ( allocated(output_nuc) )  Deallocate (output_nuc)
    If ( allocated(inab_file) )   Deallocate (inab_file)
    If ( allocated(thermo_file) ) Deallocate (thermo_file)
    If ( allocated(iaux) )        Deallocate (iaux)

    Return
  End Subroutine controls_finalize

  !=================================================================================================
  ! Standalone Namelist I/O and MPI Broadcast
  !=================================================================================================

  Subroutine read_controls(data_dir)
    !-----------------------------------------------------------------------------------------------
    ! Read, validate, broadcast, and apply standalone controls from controls.nml.
    !-----------------------------------------------------------------------------------------------
    Use xnet_util, Only: xnet_terminate
    Implicit None

    ! Output arguments
    Character(80), Intent(out) :: data_dir

    ! Local variables
    Type(xnet_controls_t) :: controls
    Character(256) :: message
    Integer :: ierr

    Call read_xnet_controls(controls,standalone_controls_file,ierr,message)
    If ( ierr /= 0 ) Call xnet_terminate(trim(message))
    Call apply_standalone_controls(controls,data_dir)

    Return
  End Subroutine read_controls

  Subroutine read_xnet_controls(controls,filename,ierr,message)
    !-----------------------------------------------------------------------------------------------
    ! Initialize default controls on the I/O rank, read the root namelist and any layered
    ! include_files, normalize standalone filename arrays, validate standalone requirements, and
    ! broadcast the resolved controls and status across all MPI ranks.
    !-----------------------------------------------------------------------------------------------
    Use xnet_parallel, Only: parallel_bcast, parallel_IOProcessor
    Use xnet_util, Only: normalize_path
    Implicit None

    ! Input arguments
    Character(*), Intent(in) :: filename

    ! Output arguments
    Type(xnet_controls_t), Intent(out) :: controls
    Integer, Intent(out) :: ierr
    Character(*), Intent(out) :: message

    ! Local variables
    Character(controls_path_length) :: normalized_filename
    Character(controls_path_length) :: ancestor_paths(max_include_depth)

    Call set_xnet_controls_defaults(controls)
    ierr = 0
    message = ' '
    ancestor_paths = ' '

    If ( parallel_IOProcessor() ) Then
      Call normalize_path(filename,normalized_filename,message)
      If ( len_trim(message) == 0 ) Then
        Call read_controls_file(controls,normalized_filename,1,ancestor_paths,message)
      EndIf
      If ( len_trim(message) == 0 ) Call normalize_xnet_controls(controls,message)
      If ( len_trim(message) == 0 ) Call validate_standalone_controls(controls,ierr,message)
      If ( len_trim(message) /= 0 ) ierr = 1
    EndIf

    Call broadcast_xnet_controls(controls)
    Call parallel_bcast(ierr)
    Call parallel_bcast(message)

    Return
  End Subroutine read_xnet_controls

  Subroutine write_controls(lun_out,data_dir)
    !-----------------------------------------------------------------------------------------------
    ! Write the resolved, effective runtime controls as a self-contained &xnet_controls namelist.
    !-----------------------------------------------------------------------------------------------
    Use xnet_parallel, Only: parallel_IOProcessor
    Implicit None

    ! Input arguments
    Integer, Intent(in) :: lun_out
    Character(*), Intent(in) :: data_dir

    ! Local variables
    Integer :: i, izone

    If ( idiag >= 0 .or. ( idiag >= -1 .and. parallel_IOProcessor() ) ) Then
      Write(lun_out,'(a)') '! Resolved/effective XNet controls for this run'
      Write(lun_out,'(a)') '&xnet_controls'
      Do i = 1, 3
        Write(lun_out,'(a,i0,a,a,a)') '  description(',i,") = '", &
          & trim(escape_namelist_string(descript(i))),"',"
      EndDo
      Write(lun_out,'(a,i0,a)')      '  szone = ',szone,','
      Write(lun_out,'(a,i0,a)')      '  nzone = ',nzone,','
      Write(lun_out,'(a,i0,a)')      '  iweak0 = ',iweak0,','
      Write(lun_out,'(a,i0,a)')      '  iscrn = ',iscrn,','
      Write(lun_out,'(a,i0,a)')      '  iprocess = ',iprocess,','
      Write(lun_out,'(a,i0,a)')      '  nzbatchmx = ',nzbatchmx,','
      Write(lun_out,'(a,i0,a)')      '  isolv = ',isolv,','
      Write(lun_out,'(a,i0,a)')      '  kstmx = ',kstmx,','
      Write(lun_out,'(a,i0,a)')      '  kitmx = ',kitmx,','
      Write(lun_out,'(a,i0,a)')      '  ijac = ',ijac,','
      Write(lun_out,'(a,i0,a)')      '  iconvc = ',iconvc,','
      Write(lun_out,'(a,es24.16,a)') '  changemx = ',changemx,','
      Write(lun_out,'(a,es24.16,a)') '  yacc = ',yacc,','
      Write(lun_out,'(a,es24.16,a)') '  tolm = ',tolm,','
      Write(lun_out,'(a,es24.16,a)') '  tolc = ',tolc,','
      Write(lun_out,'(a,es24.16,a)') '  ymin = ',ymin,','
      Write(lun_out,'(a,es24.16,a)') '  tdel_maxmult = ',tdel_maxmult,','
      Write(lun_out,'(a,i0,a)')      '  iheat = ',iheat,','
      Write(lun_out,'(a,es24.16,a)') '  changemxt = ',changemxt,','
      Write(lun_out,'(a,es24.16,a)') '  tolt9 = ',tolt9,','
      Write(lun_out,'(a,es24.16,a)') '  t9nse = ',t9nse,','
      Write(lun_out,'(a,i0,a)')      '  ineutrino = ',ineutrino,','
      Write(lun_out,'(a,i0,a)')      '  idiag = ',idiag,','
      Write(lun_out,'(a,i0,a)')      '  itsout = ',itsout,','
      Write(lun_out,'(3a)')          "  ev_file_base = '",trim(escape_namelist_string(ev_file_base)),"',"
      Write(lun_out,'(3a)')          "  bin_file_base = '",trim(escape_namelist_string(bin_file_base)),"',"
      Write(lun_out,'(a,i0,a)')      '  nnucout = ',nnucout,','
      Do i = 1, nnucout
        Write(lun_out,'(a,i0,a,a,a)') '  output_nuclei(',i,") = '", &
          & trim(escape_namelist_string(output_nuc(i))),"',"
      EndDo
      Write(lun_out,'(3a)')          "  data_dir = '",trim(escape_namelist_string(data_dir)),"',"
      Do izone = 1, nzone
        Write(lun_out,'(a,i0,a,a,a)') '  inab_files(',izone,") = '", &
          & trim(escape_namelist_string(inab_file(izone))),"',"
        Write(lun_out,'(a,i0,a,a,a)') '  thermo_files(',izone,") = '", &
          & trim(escape_namelist_string(thermo_file(izone))),"',"
      EndDo
      Write(lun_out,'(a)') '/'
    EndIf

    Return
  End Subroutine write_controls

  Subroutine broadcast_xnet_controls(controls)
    !-----------------------------------------------------------------------------------------------
    ! Broadcast the resolved xnet_controls_t structure from the I/O rank to all MPI ranks.
    !-----------------------------------------------------------------------------------------------
    Use xnet_parallel, Only: parallel_bcast, parallel_IOProcessor
    Implicit None

    ! Input/Output arguments
    Type(xnet_controls_t), Intent(inout) :: controls

    ! Local variables
    Integer :: input_count, output_count

    If ( parallel_IOProcessor() ) Then
      input_count  = size(controls%inab_files)
      output_count = size(controls%output_nuclei)
    Else
      input_count  = 0
      output_count = 0
    EndIf

    Call parallel_bcast(input_count)
    Call parallel_bcast(output_count)

    If ( .not. parallel_IOProcessor() ) Then
      If ( allocated(controls%inab_files) )    Deallocate (controls%inab_files)
      If ( allocated(controls%thermo_files) )  Deallocate (controls%thermo_files)
      If ( allocated(controls%output_nuclei) ) Deallocate (controls%output_nuclei)
      Allocate (controls%inab_files(input_count),controls%thermo_files(input_count))
      Allocate (controls%output_nuclei(output_count))
    EndIf

    Call parallel_bcast(controls%description)
    Call parallel_bcast(controls%szone)
    Call parallel_bcast(controls%nzone)
    Call parallel_bcast(controls%iweak0)
    Call parallel_bcast(controls%iscrn)
    Call parallel_bcast(controls%iprocess)
    Call parallel_bcast(controls%nzbatchmx)
    Call parallel_bcast(controls%isolv)
    Call parallel_bcast(controls%kstmx)
    Call parallel_bcast(controls%kitmx)
    Call parallel_bcast(controls%ijac)
    Call parallel_bcast(controls%iconvc)
    Call parallel_bcast(controls%changemx)
    Call parallel_bcast(controls%yacc)
    Call parallel_bcast(controls%tolm)
    Call parallel_bcast(controls%tolc)
    Call parallel_bcast(controls%ymin)
    Call parallel_bcast(controls%tdel_maxmult)
    Call parallel_bcast(controls%iheat)
    Call parallel_bcast(controls%changemxt)
    Call parallel_bcast(controls%tolt9)
    Call parallel_bcast(controls%t9nse)
    Call parallel_bcast(controls%ineutrino)
    Call parallel_bcast(controls%idiag)
    Call parallel_bcast(controls%itsout)
    Call parallel_bcast(controls%ev_file_base)
    Call parallel_bcast(controls%bin_file_base)
    Call parallel_bcast(controls%data_dir)
    Call parallel_bcast(controls%nnucout)
    If ( output_count > 0 ) Call parallel_bcast(controls%output_nuclei)
    If ( input_count > 0 ) Then
      Call parallel_bcast(controls%inab_files)
      Call parallel_bcast(controls%thermo_files)
    EndIf

    Return
  End Subroutine broadcast_xnet_controls

  !=================================================================================================
  ! Namelist Layering, Normalization, and Parsing Helpers
  !=================================================================================================

  Recursive Subroutine read_controls_file(controls,filename,depth,ancestor_paths,message)
    !-----------------------------------------------------------------------------------------------
    ! Read one &xnet_controls namelist file and then recursively apply any include_files in order.
    ! Dynamically sized array controls (inab_files, thermo_files, output_nuclei, include_files)
    ! require explicit positive element indices so staging arrays can be sized before the read.
    !-----------------------------------------------------------------------------------------------
    Use xnet_util, Only: normalize_path, string_lc
    Implicit None

    ! Input arguments
    Character(*), Intent(in) :: filename
    Integer, Intent(in) :: depth

    ! Input/Output arguments
    Type(xnet_controls_t), Intent(inout) :: controls
    Character(controls_path_length), Intent(inout) :: ancestor_paths(:)

    ! Output arguments
    Character(*), Intent(out) :: message

    ! Namelist staging variables
    Character(controls_path_length) :: include_files(max_includes_per_file+1)
    Character(80) :: description(3), ev_file_base, bin_file_base, data_dir
    Character(80), Allocatable :: inab_files(:), thermo_files(:)
    Character(5), Allocatable :: output_nuclei(:)
    Integer :: szone, nzone, iweak0, iscrn, iprocess, nzbatchmx
    Integer :: isolv, kstmx, kitmx, ijac, iconvc
    Integer :: iheat, ineutrino, idiag, itsout, nnucout
    Real(dp) :: changemx, yacc, tolm, tolc, ymin, tdel_maxmult
    Real(dp) :: changemxt, tolt9, t9nse
    Namelist /xnet_controls/ description, szone, nzone, iweak0, iscrn, iprocess, nzbatchmx, isolv, &
      & kstmx, kitmx, ijac, iconvc, changemx, yacc, tolm, tolc, ymin, tdel_maxmult, iheat, &
      & changemxt, tolt9, t9nse, ineutrino, idiag, itsout, ev_file_base, bin_file_base, data_dir, &
      & nnucout, output_nuclei, inab_files, thermo_files, include_files

    ! Local variables
    Character(controls_path_length) :: include_path, normalized_filename
    Character(:), Allocatable :: line
    Integer :: lun, ierr, i, staging_size, input_count, output_count, file_size
    Integer :: largest_inab_index, largest_thermo_index, largest_output_index, largest_include_index

    ! 1. Normalize path and verify include nesting depth and cycle freedom
    message = ' '
    Call normalize_path(filename,normalized_filename,message)
    If ( len_trim(message) /= 0 ) Return

    If ( depth > max_include_depth ) Then
      message = 'Controls include depth limit exceeded: '//trim(normalized_filename)
      Return
    ElseIf ( depth > 1 ) Then
      If ( any(ancestor_paths(:depth-1) == normalized_filename) ) Then
        message = 'Controls include cycle: '//trim(normalized_filename)
        Return
      EndIf
    EndIf
    ancestor_paths(depth) = normalized_filename

    ! 2. Open the controls file and pre-scan lines for maximum explicit array indices
    Open(newunit=lun,file=trim(normalized_filename),status='old',action='read',iostat=ierr)
    If ( ierr /= 0 ) Then
      message = 'Failed to open controls file: '//trim(normalized_filename)
      Return
    EndIf

    Inquire(unit=lun,size=file_size,iostat=ierr)
    If ( ierr /= 0 ) Then
      message = 'Failed to inspect controls file: '//trim(normalized_filename)
      Close(lun)
      Return
    EndIf
    ! Size the line buffer to the file byte count so long records are never truncated during scanning.
    Allocate (Character(max(1,file_size)) :: line,stat=ierr)
    If ( ierr /= 0 ) Then
      message = 'Failed to allocate controls input buffer'
      Close(lun)
      Return
    EndIf

    largest_inab_index    = 0
    largest_thermo_index  = 0
    largest_output_index  = 0
    largest_include_index = 0
    Do
      Read(lun,'(a)',iostat=ierr) line
      If ( ierr < 0 ) Exit
      If ( ierr > 0 ) Then
        message = 'Failed to inspect controls file: '//trim(normalized_filename)
        Close(lun)
        Deallocate (line)
        Return
      EndIf
      Call string_lc(line)
      Call inspect_array_control(line,'inab_files',largest_inab_index,ierr)
      If ( ierr == 0 ) Call inspect_array_control(line,'thermo_files',largest_thermo_index,ierr)
      If ( ierr == 0 ) Call inspect_array_control(line,'output_nuclei',largest_output_index,ierr)
      If ( ierr == 0 ) Call inspect_array_control(line,'include_files',largest_include_index,ierr)
      If ( ierr /= 0 ) Then
        message = 'Dynamically sized controls require explicit positive indices in '// &
          & trim(normalized_filename)
        Close(lun)
        Deallocate (line)
        Return
      ElseIf ( largest_include_index > max_includes_per_file+1 ) Then
        Write(message,'(a,i0,a)') 'Controls file has more than ',max_includes_per_file, &
          & ' direct includes: '//trim(normalized_filename)
        Close(lun)
        Deallocate (line)
        Return
      EndIf
    EndDo
    Deallocate (line)
    Rewind(lun)

    ! 3. Allocate namelist staging arrays and seed with values from earlier layers
    staging_size = max(1,size(controls%inab_files),size(controls%thermo_files), &
      & size(controls%output_nuclei),largest_inab_index,largest_thermo_index,largest_output_index)
    Allocate (inab_files(staging_size),thermo_files(staging_size), &
      & output_nuclei(staging_size),stat=ierr)
    If ( ierr /= 0 ) Then
      message = 'Failed to allocate controls arrays'
      Close(lun)
      Return
    EndIf

    include_files = ' '
    description   = controls%description
    szone         = controls%szone
    nzone         = controls%nzone
    iweak0        = controls%iweak0
    iscrn         = controls%iscrn
    iprocess      = controls%iprocess
    nzbatchmx     = controls%nzbatchmx
    isolv         = controls%isolv
    kstmx         = controls%kstmx
    kitmx         = controls%kitmx
    ijac          = controls%ijac
    iconvc        = controls%iconvc
    changemx      = controls%changemx
    yacc          = controls%yacc
    tolm          = controls%tolm
    tolc          = controls%tolc
    ymin          = controls%ymin
    tdel_maxmult  = controls%tdel_maxmult
    iheat         = controls%iheat
    changemxt     = controls%changemxt
    tolt9         = controls%tolt9
    t9nse         = controls%t9nse
    ineutrino     = controls%ineutrino
    idiag         = controls%idiag
    itsout        = controls%itsout
    ev_file_base  = controls%ev_file_base
    bin_file_base = controls%bin_file_base
    data_dir      = controls%data_dir
    nnucout       = controls%nnucout
    inab_files    = ' '
    thermo_files  = ' '
    output_nuclei = ' '
    If ( size(controls%inab_files) > 0 ) Then
      inab_files(:size(controls%inab_files)) = controls%inab_files
    EndIf
    If ( size(controls%thermo_files) > 0 ) Then
      thermo_files(:size(controls%thermo_files)) = controls%thermo_files
    EndIf
    If ( size(controls%output_nuclei) > 0 ) Then
      output_nuclei(:size(controls%output_nuclei)) = controls%output_nuclei
    EndIf

    ! 4. Read the namelist and copy updated fields back into controls
    Read(lun,nml=xnet_controls,iostat=ierr)
    Close(lun)
    If ( ierr /= 0 ) Then
      Write(message,'(a,i0,a)') 'Malformed or unknown xnet_controls namelist, iostat=',ierr, &
        & ' in '//trim(normalized_filename)
      Deallocate (inab_files,thermo_files,output_nuclei)
      Return
    ElseIf ( len_trim(include_files(max_includes_per_file+1)) /= 0 ) Then
      Write(message,'(a,i0,a)') 'Controls file has more than ',max_includes_per_file, &
        & ' direct includes: '//trim(normalized_filename)
      Deallocate (inab_files,thermo_files,output_nuclei)
      Return
    EndIf

    controls%description   = description
    controls%szone         = szone
    controls%nzone         = nzone
    controls%iweak0        = iweak0
    controls%iscrn         = iscrn
    controls%iprocess      = iprocess
    controls%nzbatchmx     = nzbatchmx
    controls%isolv         = isolv
    controls%kstmx         = kstmx
    controls%kitmx         = kitmx
    controls%ijac          = ijac
    controls%iconvc        = iconvc
    controls%changemx      = changemx
    controls%yacc          = yacc
    controls%tolm          = tolm
    controls%tolc          = tolc
    controls%ymin          = ymin
    controls%tdel_maxmult  = tdel_maxmult
    controls%iheat         = iheat
    controls%changemxt     = changemxt
    controls%tolt9         = tolt9
    controls%t9nse         = t9nse
    controls%ineutrino     = ineutrino
    controls%idiag         = idiag
    controls%itsout        = itsout
    controls%ev_file_base  = ev_file_base
    controls%bin_file_base = bin_file_base
    controls%data_dir      = data_dir
    controls%nnucout       = nnucout

    input_count  = max(last_nonblank_index(inab_files),last_nonblank_index(thermo_files))
    output_count = last_nonblank_index(output_nuclei)
    Call resize_input_controls(controls,input_count,message)
    If ( len_trim(message) /= 0 ) Then
      Deallocate (inab_files,thermo_files,output_nuclei)
      Return
    EndIf
    Call resize_output_controls(controls,output_count,message)
    If ( len_trim(message) /= 0 ) Then
      Deallocate (inab_files,thermo_files,output_nuclei)
      Return
    EndIf
    If ( input_count > 0 ) Then
      controls%inab_files   = inab_files(:input_count)
      controls%thermo_files = thermo_files(:input_count)
    EndIf
    If ( output_count > 0 ) controls%output_nuclei = output_nuclei(:output_count)
    Deallocate (inab_files,thermo_files,output_nuclei)

    ! 5. Apply any included control files in order (later includes override earlier values)
    Do i = 1, max_includes_per_file
      If ( len_trim(include_files(i)) == 0 ) Cycle
      Call resolve_include(normalized_filename,include_files(i),include_path,message)
      If ( len_trim(message) /= 0 ) Return
      Call read_controls_file(controls,include_path,depth+1,ancestor_paths,message)
      If ( len_trim(message) /= 0 ) Return
    EndDo
    ancestor_paths(depth) = ' '

    Return
  End Subroutine read_controls_file

  Subroutine normalize_xnet_controls(controls,message)
    !-----------------------------------------------------------------------------------------------
    ! Resize standalone input filename arrays to nzone, verify paired entries, and expand a single
    ! ASCII input-file pair to one numbered pair per zone when nzone > 1.
    !-----------------------------------------------------------------------------------------------
    Use xnet_util, Only: name_ordered
    Implicit None

    ! Input/Output arguments
    Type(xnet_controls_t), Intent(inout) :: controls

    ! Output arguments
    Character(*), Intent(out) :: message

    ! Local variables
    Character(80) :: inab_base, thermo_base
    Integer :: izone, last_inab_index, last_input_index, last_thermo_index

    message = ' '
    If ( controls%nzone < 1 ) Return

    ! Reject an input-file list longer than nzone before resizing.
    last_inab_index   = last_nonblank_index(controls%inab_files)
    last_thermo_index = last_nonblank_index(controls%thermo_files)
    If ( max(last_inab_index,last_thermo_index) > controls%nzone ) Then
      message = 'the number of input file pairs cannot exceed nzone'
      Return
    EndIf

    Call resize_input_controls(controls,controls%nzone,message)
    If ( len_trim(message) /= 0 ) Return

    ! Verify that every populated slot supplies both an abundance file and a thermo file.
    last_input_index = 0
    Do izone = 1, controls%nzone
      If ( (len_trim(controls%inab_files(izone)) == 0) .neqv. &
        & (len_trim(controls%thermo_files(izone)) == 0) ) Then
        message = 'each input file entry needs both inab_files and thermo_files'
        Return
      EndIf
      If ( len_trim(controls%inab_files(izone)) /= 0 ) last_input_index = izone
    EndDo

    ! HDF5 files may store multiple zones per file; keep their filenames without zone suffixes.
    If ( is_hdf_thermo_file(controls%thermo_files(1)) ) Return

    If ( last_input_index == 1 .and. controls%nzone > 1 ) Then
      ! Expand a single ASCII file pair to one zero-padded pair per zone.
      inab_base   = controls%inab_files(1)
      thermo_base = controls%thermo_files(1)
      Do izone = 1, controls%nzone
        controls%inab_files(izone)   = trim(inab_base)
        controls%thermo_files(izone) = trim(thermo_base)
        Call name_ordered(controls%inab_files(izone),izone,controls%nzone)
        Call name_ordered(controls%thermo_files(izone),izone,controls%nzone)
      EndDo
    ElseIf ( last_input_index /= controls%nzone ) Then
      message = 'one input file pair or one pair per zone is required'
    EndIf

    Return
  End Subroutine normalize_xnet_controls

  Subroutine inspect_array_control(line,name,largest_index,ierr)
    !-----------------------------------------------------------------------------------------------
    ! Scan a lowercase namelist line (ignoring comments and quoted strings) for occurrences of an
    ! array control name, verify that each uses an explicit positive scalar index name(index),
    ! and update largest_index.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Input arguments
    Character(*), Intent(in) :: line, name

    ! Input/Output arguments
    Integer, Intent(inout) :: largest_index

    ! Output arguments
    Integer, Intent(out) :: ierr

    ! Local constants and variables
    Character(*), Parameter :: identifier_chars = 'abcdefghijklmnopqrstuvwxyz0123456789_'
    Character :: quote, ch
    Integer :: close_paren, name_end, name_pos, offset, search_from, index_value
    Integer :: first_nonblank, line_length, pos
    Logical :: skip_next

    ierr = 0
    search_from = 1
    line_length = len_trim(line)

    Do
      name_pos  = 0
      quote     = ' '
      skip_next = .false.

      ! Find the next identifier token matching name outside quotes and comments.
      Do pos = search_from, line_length
        ch = line(pos:pos)
        If ( skip_next ) Then
          skip_next = .false.
          Cycle
        ElseIf ( quote /= ' ' ) Then
          If ( ch == quote ) Then
            If ( pos < line_length ) Then
              If ( line(pos+1:pos+1) == quote ) Then
                skip_next = .true.
              Else
                quote = ' '
              EndIf
            Else
              quote = ' '
            EndIf
          EndIf
          Cycle
        ElseIf ( ch == "'" .or. ch == '"' ) Then
          quote = ch
          Cycle
        ElseIf ( ch == '!' ) Then
          Return
        EndIf

        name_end = pos + len_trim(name) - 1
        If ( name_end > line_length ) Cycle
        If ( line(pos:name_end) /= trim(name) ) Cycle
        If ( pos > 1 ) Then
          If ( index(identifier_chars,line(pos-1:pos-1)) /= 0 ) Cycle
        EndIf
        If ( name_end < line_length ) Then
          If ( index(identifier_chars,line(name_end+1:name_end+1)) /= 0 ) Cycle
        EndIf
        name_pos = pos
        Exit
      EndDo
      If ( name_pos == 0 ) Return

      ! Require an opening parenthesis immediately after any whitespace.
      first_nonblank = name_pos + len_trim(name)
      Do offset = first_nonblank, line_length
        first_nonblank = offset
        If ( line(offset:offset) /= ' ' ) Exit
      EndDo
      If ( first_nonblank >= line_length ) Then
        ierr = 1
        Return
      ElseIf ( line(first_nonblank:first_nonblank) /= '(' ) Then
        ierr = 1
        Return
      EndIf

      ! Parse the explicit positive integer subscript inside parentheses.
      close_paren = index(line(first_nonblank+1:line_length),')')
      If ( close_paren == 0 ) Then
        ierr = 1
        Return
      EndIf
      close_paren = first_nonblank + close_paren
      Read(line(first_nonblank+1:close_paren-1),*,iostat=ierr) index_value
      If ( ierr /= 0 .or. index_value < 1 ) Then
        ierr = 1
        Return
      EndIf

      largest_index = max(largest_index,index_value)
      search_from = close_paren + 1
      If ( search_from > line_length ) Return
    EndDo

    Return
  End Subroutine inspect_array_control

  Subroutine resolve_include(parent,child,path,message)
    !-----------------------------------------------------------------------------------------------
    ! Resolve an included controls path relative to the directory of its parent controls file.
    !-----------------------------------------------------------------------------------------------
    Use xnet_util, Only: normalize_path
    Implicit None

    ! Input arguments
    Character(*), Intent(in) :: parent, child

    ! Output arguments
    Character(controls_path_length), Intent(out) :: path
    Character(*), Intent(out) :: message

    ! Local variables
    Character(2*controls_path_length+1) :: combined_path
    Integer :: slash

    combined_path = ' '
    If ( len_trim(child) == 0 ) Then
      message = 'Controls include path is empty'
      Return
    ElseIf ( child(1:1) == '/' ) Then
      combined_path = trim(child)
    Else
      slash = scan(trim(parent),'/',back=.true.)
      If ( slash > 0 ) Then
        combined_path = parent(:slash)//trim(child)
      Else
        combined_path = trim(child)
      EndIf
    EndIf

    Call normalize_path(trim(combined_path),path,message)

    Return
  End Subroutine resolve_include

  Logical Function is_hdf_thermo_file(filename)
    !-----------------------------------------------------------------------------------------------
    ! Return .true. when a thermodynamic trajectory filename has a case-insensitive HDF5 extension
    ! (.h5, .hdf, or .hdf5).
    !-----------------------------------------------------------------------------------------------
    Use xnet_util, Only: string_lc
    Implicit None

    ! Input arguments
    Character(*), Intent(in) :: filename

    ! Local variables
    Character(len(filename)) :: lowercase_filename
    Integer :: filename_length

    lowercase_filename = filename
    Call string_lc(lowercase_filename)
    filename_length = len_trim(lowercase_filename)

    is_hdf_thermo_file = .false.
    If ( filename_length >= 3 ) is_hdf_thermo_file = ( lowercase_filename(filename_length-2:filename_length) == '.h5' )
    If ( .not. is_hdf_thermo_file .and. filename_length >= 4 ) Then
      is_hdf_thermo_file = ( lowercase_filename(filename_length-3:filename_length) == '.hdf' )
    EndIf
    If ( .not. is_hdf_thermo_file .and. filename_length >= 5 ) Then
      is_hdf_thermo_file = ( lowercase_filename(filename_length-4:filename_length) == '.hdf5' )
    EndIf

    Return
  End Function is_hdf_thermo_file

  Subroutine resize_input_controls(controls,new_size,message)
    !-----------------------------------------------------------------------------------------------
    ! Resize controls%inab_files and controls%thermo_files to new_size while preserving existing
    ! entries up to min(old_size, new_size).
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Input arguments
    Integer, Intent(in) :: new_size

    ! Input/Output arguments
    Type(xnet_controls_t), Intent(inout) :: controls

    ! Output arguments
    Character(*), Intent(out) :: message

    ! Local variables
    Character(80), Allocatable :: new_inab_files(:), new_thermo_files(:)
    Integer :: copy_size, ierr

    message = ' '
    If ( new_size < 0 ) Then
      message = 'Controls input-array size must be nonnegative'
      Return
    ElseIf ( size(controls%inab_files) == new_size .and. &
      & size(controls%thermo_files) == new_size ) Then
      Return
    EndIf

    Allocate (new_inab_files(new_size),new_thermo_files(new_size),stat=ierr)
    If ( ierr /= 0 ) Then
      message = 'Failed to allocate standalone input filenames'
      Return
    EndIf
    new_inab_files   = ' '
    new_thermo_files = ' '
    copy_size = min(new_size,size(controls%inab_files),size(controls%thermo_files))
    If ( copy_size > 0 ) Then
      new_inab_files(:copy_size)   = controls%inab_files(:copy_size)
      new_thermo_files(:copy_size) = controls%thermo_files(:copy_size)
    EndIf
    Call move_alloc(new_inab_files,controls%inab_files)
    Call move_alloc(new_thermo_files,controls%thermo_files)

    Return
  End Subroutine resize_input_controls

  Subroutine resize_output_controls(controls,new_size,message)
    !-----------------------------------------------------------------------------------------------
    ! Resize controls%output_nuclei to new_size while preserving existing entries.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Input arguments
    Integer, Intent(in) :: new_size

    ! Input/Output arguments
    Type(xnet_controls_t), Intent(inout) :: controls

    ! Output arguments
    Character(*), Intent(out) :: message

    ! Local variables
    Character(5), Allocatable :: new_output_nuclei(:)
    Integer :: copy_size, ierr

    message = ' '
    If ( new_size < 0 ) Then
      message = 'Controls output-array size must be nonnegative'
      Return
    ElseIf ( size(controls%output_nuclei) == new_size ) Then
      Return
    EndIf

    Allocate (new_output_nuclei(new_size),stat=ierr)
    If ( ierr /= 0 ) Then
      message = 'Failed to allocate output_nuclei'
      Return
    EndIf
    new_output_nuclei = ' '
    copy_size = min(new_size,size(controls%output_nuclei))
    If ( copy_size > 0 ) new_output_nuclei(:copy_size) = controls%output_nuclei(:copy_size)
    Call move_alloc(new_output_nuclei,controls%output_nuclei)

    Return
  End Subroutine resize_output_controls

  Character(160) Function escape_namelist_string(value)
    !-----------------------------------------------------------------------------------------------
    ! Double any single-quote characters in value for safe single-quoted namelist output.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Input arguments
    Character(*), Intent(in) :: value

    ! Local variables
    Integer :: i, output_pos

    escape_namelist_string = ' '
    output_pos = 1
    Do i = 1, len_trim(value)
      If ( value(i:i) == "'" ) Then
        escape_namelist_string(output_pos:output_pos+1) = "''"
        output_pos = output_pos + 2
      Else
        escape_namelist_string(output_pos:output_pos) = value(i:i)
        output_pos = output_pos + 1
      EndIf
    EndDo

    Return
  End Function escape_namelist_string

End Module xnet_controls
