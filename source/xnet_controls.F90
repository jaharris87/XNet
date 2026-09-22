#include "xnet_macros.fh"

! Standalone runtime configuration.  RuntimeConfig is also usable by a future
! embedding interface because its defaults and validation do not perform I/O.
Module xnet_controls
  Use, Intrinsic :: iso_fortran_env, Only: lun_stderr=>error_unit, lun_stdin=>input_unit, &
    & lun_stdout=>output_unit
  Use xnet_types, Only: dp
  Implicit None

  Integer, Parameter :: max_config_zones = 4096
  Integer, Parameter :: max_config_output_nuclei = 256
  Integer, Parameter :: max_config_includes = 16
  Integer, Parameter :: max_config_include_depth = 16

  Type :: RuntimeConfig
    Character(80) :: description(3) = ''
    Integer :: szone = 1, nzone = 1, iweak0 = 1, iscrn = 1, iprocess = 0
    Integer :: nzbatchmx = 1, isolv = 1, kstmx = 9999, kitmx = 5, ijac = 1, iconvc = 0
    Real(dp) :: changemx = 1.0e-1_dp, yacc = 1.0e-7_dp, tolm = 1.0e-6_dp
    Real(dp) :: tolc = 1.0e-4_dp, ymin = 1.0e-30_dp, tdel_maxmult = 2.0_dp
    Integer :: iheat = 0, ineutrino = 0, idiag = 0, itsout = 0
    Real(dp) :: changemxt = 1.0e-2_dp, tolt9 = 1.0e-4_dp, t9nse = 8.0_dp
    Character(80) :: ev_file_base = 'ev_', bin_file_base = 'ts_', data_dir = ''
    Integer :: nnucout = 0
    Character(5), Allocatable :: output_nuclei(:)
    Character(80), Allocatable :: inab_files(:), thermo_files(:)
  End Type RuntimeConfig

  Character(80) :: descript(3)
  Integer :: szone, nzone, iweak0, iscrn, iprocess, nzevolve, nzbatchmx, nzbatch, szbatch
  Integer :: zb_offset, zb_lo, zb_hi, isolv, kstmx, kitmx, ijac, iconvc, iheat, ineutrino
  Integer :: nnucout, idiag, itsout, lun_diag, lun_th, lun_ab, myid, nproc, tid, nthread
  Integer, Allocatable :: zone_id(:,:), iweak(:), kmon(:,:), ktot(:,:), inucout(:), lun_ts(:), lun_ev(:), iaux(:)
  Logical, Allocatable, Target :: lzactive(:)
  Real(dp) :: changemx, yacc, tolc, tolm, ymin, tdel_maxmult, changemxt, tolt9, t9nse = 8.0_dp
  Real(dp) :: t9min = 0.01_dp
  Character(4) :: nnucout_string
  Character(80) :: ev_file_base, bin_file_base, inab_file_base, thermo_file_base
  Character(80), Allocatable :: inab_file(:), thermo_file(:)
  Character(5), Allocatable :: output_nuc(:)
  Character(LEN=1) :: sweep
  !$omp threadprivate(nzbatch,szbatch,zb_offset,zb_lo,zb_hi,lun_diag,lun_th,lun_ab,tid,sweep)

  Interface write_controls_line
    Module Procedure write_controls_line_i
    Module Procedure write_controls_line_r
  End Interface write_controls_line

Contains

  Subroutine SetRuntimeConfigDefaults(config)
    Type(RuntimeConfig), Intent(out) :: config
    config = RuntimeConfig()
    Allocate(config%output_nuclei(max_config_output_nuclei), &
      & config%inab_files(max_config_zones),config%thermo_files(max_config_zones))
    config%output_nuclei = ''
    config%inab_files = ''
    config%thermo_files = ''
  End Subroutine SetRuntimeConfigDefaults

  Subroutine ValidateRuntimeConfig(config, message)
    Type(RuntimeConfig), Intent(in) :: config
    Character(*), Intent(out) :: message
    message = ''
    If ( config%nzone < 1 .or. config%nzone > max_config_zones ) Then
      message = 'nzone must be between 1 and max_config_zones'
    ElseIf ( config%nnucout < 0 .or. config%nnucout > max_config_output_nuclei ) Then
      message = 'nnucout must be between 0 and max_config_output_nuclei'
    ElseIf ( config%szone < 1 .or. config%szone > config%nzone ) Then
      message = 'szone must select an existing zone'
    ElseIf ( config%isolv /= 1 .and. config%isolv /= 3 ) Then
      message = 'isolv must be 1 (BE) or 3 (BDF)'
    ElseIf ( config%nzbatchmx < 1 .or. config%kitmx < 1 .or. config%kstmx < 1 ) Then
      message = 'batch, iteration, and step limits must be positive'
    ElseIf ( config%tolc <= 0.0_dp .or. config%tolm <= 0.0_dp .or. config%ymin < 0.0_dp ) Then
      message = 'integration tolerances must be positive and ymin nonnegative'
    ElseIf ( .not. Allocated(config%inab_files) .or. .not. Allocated(config%thermo_files) .or. &
      & .not. Allocated(config%output_nuclei) ) Then
      message = 'runtime configuration arrays must be initialized with SetRuntimeConfigDefaults'
    EndIf
  End Subroutine ValidateRuntimeConfig

  Subroutine ValidateStandaloneRuntimeConfig(config,message)
    Type(RuntimeConfig), Intent(in) :: config
    Character(*), Intent(out) :: message
    Call ValidateRuntimeConfig(config,message)
    If ( Len_Trim(message) /= 0 ) Return
    If ( Len_Trim(config%data_dir) == 0 ) Then
      message = 'data_dir is required for the standalone driver'
    ElseIf ( Any(Len_Trim(config%inab_files(1:config%nzone)) == 0) .or. &
      & Any(Len_Trim(config%thermo_files(1:config%nzone)) == 0) ) Then
      message = 'one inab_files and thermo_files entry is required per zone'
    EndIf
  End Subroutine ValidateStandaloneRuntimeConfig

  Subroutine ReadRuntimeConfig(config, filename, message)
    Use xnet_parallel, Only: parallel_bcast, parallel_IOProcessor
    Type(RuntimeConfig), Intent(out) :: config
    Character(*), Intent(in) :: filename
    Character(*), Intent(out) :: message
    Call SetRuntimeConfigDefaults(config)
    message = ''
    If ( parallel_IOProcessor() ) Call read_config_file(config,canonicalize_path(filename),0,'',message)
    If ( parallel_IOProcessor() .and. Len_Trim(message) == 0 ) Then
      Call NormalizeRuntimeConfig(config,message)
      If ( Len_Trim(message) == 0 ) Call ValidateStandaloneRuntimeConfig(config,message)
    EndIf
    Call broadcast_config(config)
    Call parallel_bcast(message)
  End Subroutine ReadRuntimeConfig

  Recursive Subroutine read_config_file(config, filename, depth, ancestry, message)
    Type(RuntimeConfig), Intent(inout) :: config
    Character(*), Intent(in) :: filename, ancestry
    Integer, Intent(in) :: depth
    Character(*), Intent(out) :: message
    Character(256) :: include(max_config_includes), include_path, next_ancestry, canonical_filename
    Character(80) :: description(3), ev_file_base, bin_file_base, data_dir
    Character(80), Allocatable :: inab_files(:), thermo_files(:)
    Character(5), Allocatable :: output_nuclei(:)
    Integer :: szone, nzone, iweak0, iscrn, iprocess, nzbatchmx, isolv, kstmx, kitmx, ijac, iconvc
    Integer :: iheat, ineutrino, idiag, itsout, nnucout
    Real(dp) :: changemx, yacc, tolm, tolc, ymin, tdel_maxmult, changemxt, tolt9, t9nse
    Integer :: lun, ierr, i
    Namelist /xnet_config/ description, szone, nzone, iweak0, iscrn, iprocess, nzbatchmx, isolv, &
      & kstmx, kitmx, ijac, iconvc, changemx, yacc, tolm, tolc, ymin, tdel_maxmult, iheat, &
      & changemxt, tolt9, t9nse, ineutrino, idiag, itsout, ev_file_base, bin_file_base, data_dir, &
      & nnucout, output_nuclei, inab_files, thermo_files, include
    message = ''
    canonical_filename = canonicalize_path(filename)
    If ( depth >= max_config_include_depth ) Then
      message = 'xnet.nml include depth limit exceeded'
      Return
    EndIf
    If ( Index('|'//Trim(ancestry)//'|','|'//Trim(canonical_filename)//'|') > 0 ) Then
      message = 'xnet.nml include cycle: '//Trim(canonical_filename)
      Return
    EndIf
    include = ''
    Allocate(inab_files(max_config_zones),thermo_files(max_config_zones),output_nuclei(max_config_output_nuclei))
    description = config%description
    szone = config%szone; nzone = config%nzone; iweak0 = config%iweak0; iscrn = config%iscrn
    iprocess = config%iprocess; nzbatchmx = config%nzbatchmx; isolv = config%isolv; kstmx = config%kstmx
    kitmx = config%kitmx; ijac = config%ijac; iconvc = config%iconvc; changemx = config%changemx
    yacc = config%yacc; tolm = config%tolm; tolc = config%tolc; ymin = config%ymin
    tdel_maxmult = config%tdel_maxmult; iheat = config%iheat; changemxt = config%changemxt
    tolt9 = config%tolt9; t9nse = config%t9nse; ineutrino = config%ineutrino; idiag = config%idiag
    itsout = config%itsout; ev_file_base = config%ev_file_base; bin_file_base = config%bin_file_base
    data_dir = config%data_dir; nnucout = config%nnucout; output_nuclei = config%output_nuclei
    inab_files = config%inab_files; thermo_files = config%thermo_files
    Open(newunit=lun,file=Trim(canonical_filename),status='old',action='read',iostat=ierr)
    If ( ierr /= 0 ) Then
      message = 'failed to open xnet.nml: '//Trim(canonical_filename)
      Return
    EndIf
    Read(lun,nml=xnet_config,iostat=ierr)
    Close(lun)
    If ( ierr /= 0 ) Then
      Write(message,'(a,i0,a)') 'malformed or unknown xnet_config namelist, iostat=',ierr,' in '//Trim(canonical_filename)
      Return
    EndIf
    config%description = description
    config%szone = szone; config%nzone = nzone; config%iweak0 = iweak0; config%iscrn = iscrn
    config%iprocess = iprocess; config%nzbatchmx = nzbatchmx; config%isolv = isolv; config%kstmx = kstmx
    config%kitmx = kitmx; config%ijac = ijac; config%iconvc = iconvc; config%changemx = changemx
    config%yacc = yacc; config%tolm = tolm; config%tolc = tolc; config%ymin = ymin
    config%tdel_maxmult = tdel_maxmult; config%iheat = iheat; config%changemxt = changemxt
    config%tolt9 = tolt9; config%t9nse = t9nse; config%ineutrino = ineutrino; config%idiag = idiag
    config%itsout = itsout; config%ev_file_base = ev_file_base; config%bin_file_base = bin_file_base
    config%data_dir = data_dir; config%nnucout = nnucout; config%output_nuclei = output_nuclei
    config%inab_files = inab_files; config%thermo_files = thermo_files
    next_ancestry = Trim(ancestry)//'|'//Trim(canonical_filename)
    Do i = 1, max_config_includes
      If ( Len_Trim(include(i)) == 0 ) Cycle
      include_path = resolve_include(canonical_filename,include(i))
      Call read_config_file(config,Trim(include_path),depth+1,Trim(next_ancestry),message)
      If ( Len_Trim(message) /= 0 ) Return
    EndDo
  End Subroutine read_config_file

  Subroutine NormalizeRuntimeConfig(config,message)
    Use xnet_util, Only: name_ordered
    Type(RuntimeConfig), Intent(inout) :: config
    Character(*), Intent(out) :: message
    Integer :: izone, nfiles
    Character(80) :: inab_file_base, thermo_file_base
    message = ''
    If ( config%nzone < 1 .or. config%nzone > max_config_zones ) Return
    nfiles = 0
    Do izone = 1, config%nzone
      If ( Len_Trim(config%inab_files(izone)) == 0 .neqv. Len_Trim(config%thermo_files(izone)) == 0 ) Then
        message = 'each input file entry needs both inab_files and thermo_files'
        Return
      EndIf
      If ( Len_Trim(config%inab_files(izone)) /= 0 ) nfiles = izone
    EndDo
    If ( nfiles == 1 .and. config%nzone > 1 .and. Index(config%thermo_files(1),'.h5') == 0 .and. &
      & Index(config%thermo_files(1),'.hdf') == 0 ) Then
      inab_file_base = config%inab_files(1)
      thermo_file_base = config%thermo_files(1)
      Do izone = 1, config%nzone
        config%inab_files(izone) = Trim(inab_file_base)
        config%thermo_files(izone) = Trim(thermo_file_base)
        Call name_ordered(config%inab_files(izone),izone,config%nzone)
        Call name_ordered(config%thermo_files(izone),izone,config%nzone)
      EndDo
    ElseIf ( nfiles /= config%nzone ) Then
      message = 'one input file pair or one pair per zone is required'
    EndIf
  End Subroutine NormalizeRuntimeConfig

  Function resolve_include(parent, child) Result(path)
    Character(*), Intent(in) :: parent, child
    Character(256) :: path
    Integer :: slash
    If ( child(1:1) == '/' ) Then
      path = canonicalize_path(child)
      Return
    EndIf
    slash = Scan(Trim(parent),'/',back=.True.)
    If ( slash > 0 ) Then
      path = canonicalize_path(parent(:slash)//Trim(child))
    Else
      path = canonicalize_path(child)
    EndIf
  End Function resolve_include

  Function canonicalize_path(input_path) Result(path)
    Character(*), Intent(in) :: input_path
    Character(256) :: path, text, part(128)
    Integer :: first, last, length, nparts
    Logical :: absolute
    text = Trim(input_path)
    path = ''
    If ( Len_Trim(text) == 0 ) Return
    absolute = text(1:1) == '/'
    length = Len_Trim(text)
    nparts = 0
    first = 1
    Do While ( first <= length )
      Do While ( first <= length .and. text(first:first) == '/' )
        first = first + 1
      EndDo
      If ( first > length ) Exit
      last = first
      Do While ( last <= length .and. text(last:last) /= '/' )
        last = last + 1
      EndDo
      If ( text(first:last-1) == '.' ) Then
        Continue
      ElseIf ( text(first:last-1) == '..' ) Then
        If ( nparts > 0 .and. Trim(part(nparts)) /= '..' ) Then
          nparts = nparts - 1
        ElseIf ( .not. absolute ) Then
          nparts = nparts + 1
          part(nparts) = '..'
        EndIf
      Else
        nparts = nparts + 1
        part(nparts) = text(first:last-1)
      EndIf
      first = last + 1
    EndDo
    If ( absolute ) path = '/'
    Do first = 1, nparts
      If ( Len_Trim(path) > 0 .and. Trim(path) /= '/' ) path = Trim(path)//'/'
      path = Trim(path)//Trim(part(first))
    EndDo
    If ( Len_Trim(path) == 0 ) Then
      If ( absolute ) Then
        path = '/'
      Else
        path = '.'
      EndIf
    EndIf
  End Function canonicalize_path

  Subroutine ApplyRuntimeConfig(config, data_dir)
    Type(RuntimeConfig), Intent(in) :: config
    Character(*), Intent(out) :: data_dir
    Character(256) :: message
    Call ValidateStandaloneRuntimeConfig(config,message)
    If ( Len_Trim(message) /= 0 ) Error Stop Trim(message)
    descript = config%description
    szone = config%szone; nzone = config%nzone; iweak0 = config%iweak0; iscrn = config%iscrn
    iprocess = config%iprocess; nzbatchmx = config%nzbatchmx; isolv = config%isolv; kstmx = config%kstmx
    kitmx = config%kitmx; ijac = config%ijac; iconvc = config%iconvc; changemx = config%changemx
    yacc = config%yacc; tolm = config%tolm; tolc = config%tolc; ymin = config%ymin
    tdel_maxmult = config%tdel_maxmult; iheat = config%iheat; changemxt = config%changemxt
    tolt9 = config%tolt9; t9nse = config%t9nse; ineutrino = config%ineutrino; idiag = config%idiag
    itsout = config%itsout; ev_file_base = config%ev_file_base; bin_file_base = config%bin_file_base
    nnucout = config%nnucout; data_dir = config%data_dir
    If ( isolv == 3 ) Then
      changemx = 1.0e10_dp
      changemxt = 1.0e10_dp
    EndIf
    nzevolve = nzbatchmx*nthread
    Allocate(zone_id(3,nzevolve),lzactive(nzevolve),iweak(nzevolve),lun_ev(nzevolve),lun_ts(nzevolve))
    Allocate(kmon(5,nzevolve),ktot(5,nzevolve),inab_file(nzone),thermo_file(nzone))
    Allocate(output_nuc(nnucout),inucout(nnucout))
    inab_file = config%inab_files(:nzone)
    thermo_file = config%thermo_files(:nzone)
    If ( nnucout > 0 ) output_nuc = config%output_nuclei(:nnucout)
    Write(nnucout_string,'(i4)') nnucout
    nnucout_string = Adjustl(nnucout_string)
    !$omp parallel default(shared)
    zb_offset = (tid-1)*nzbatchmx
    zb_lo = zb_offset+1
    zb_hi = zb_offset+nzbatchmx
    !$omp end parallel
  End Subroutine ApplyRuntimeConfig

  Subroutine read_controls(data_dir)
    Use xnet_parallel, Only: parallel_IOProcessor
    Use xnet_util, Only: xnet_terminate
    Character(80), Intent(out) :: data_dir
    Type(RuntimeConfig) :: config
    Character(256) :: message
    Call ReadRuntimeConfig(config,'xnet.nml',message)
    If ( Len_Trim(message) /= 0 ) Call xnet_terminate(Trim(message))
    Call ValidateStandaloneRuntimeConfig(config,message)
    If ( Len_Trim(message) /= 0 ) Call xnet_terminate(Trim(message))
    Call ApplyRuntimeConfig(config,data_dir)
    If ( parallel_IOProcessor() ) Call WriteResolvedRuntimeConfig(config,'xnet.resolved.nml')
  End Subroutine read_controls

  Subroutine WriteResolvedRuntimeConfig(config, filename)
    Type(RuntimeConfig), Intent(in) :: config
    Character(*), Intent(in) :: filename
    Integer :: lun, i, ierr
    Open(newunit=lun,file=filename,status='replace',action='write',iostat=ierr)
    If ( ierr /= 0 ) Return
    Write(lun,'(a)') '! Resolved defaults and layered overrides used for this run.'
    Write(lun,'(a)') '&xnet_config'
    Write(lun,'(12a)') ' description = ',"'",Trim(config%description(1)),"'", &
      & ',',"'",Trim(config%description(2)),"'",',',"'",Trim(config%description(3)),"',"
    Write(lun,'(a,5(i0,a))') ' szone = ',config%szone,', nzone = ',config%nzone,', iweak0 = ',config%iweak0, &
      & ', iscrn = ',config%iscrn,', iprocess = ',config%iprocess,','
    Write(lun,'(a,6(i0,a))') ' nzbatchmx = ',config%nzbatchmx,', isolv = ',config%isolv,', kstmx = ',config%kstmx, &
      & ', kitmx = ',config%kitmx,', ijac = ',config%ijac,', iconvc = ',config%iconvc,','
    Write(lun,'(a,6(es24.16,a))') ' changemx = ',config%changemx,', yacc = ',config%yacc,', tolm = ',config%tolm, &
      & ', tolc = ',config%tolc,', ymin = ',config%ymin,', tdel_maxmult = ',config%tdel_maxmult,','
    Write(lun,'(a,i0,a,3(es24.16,a))') ' iheat = ',config%iheat,', changemxt = ',config%changemxt, &
      & ', tolt9 = ',config%tolt9,', t9nse = ',config%t9nse,','
    Write(lun,'(a,3(i0,a))') ' ineutrino = ',config%ineutrino,', idiag = ',config%idiag,', itsout = ',config%itsout,','
    Write(lun,'(a,a,a,a,a,a)') " ev_file_base = '",Trim(config%ev_file_base),"', bin_file_base = '", &
      & Trim(config%bin_file_base),"',"
    Write(lun,'(a,i0,a)') ' nnucout = ',config%nnucout,','
    Do i = 1, config%nnucout
      Write(lun,'(a,i0,a,a,a)') ' output_nuclei(',i,") = '",Trim(config%output_nuclei(i)),"',"
    EndDo
    Write(lun,'(a,a,a)') " data_dir = '",Trim(config%data_dir),"',"
    Do i = 1, config%nzone
      Write(lun,'(a,i0,a,a,a)') ' inab_files(',i,") = '",Trim(config%inab_files(i)),"',"
      Write(lun,'(a,i0,a,a,a)') ' thermo_files(',i,") = '",Trim(config%thermo_files(i)),"',"
    EndDo
    Write(lun,'(a)') '/'
    Close(lun)
  End Subroutine WriteResolvedRuntimeConfig

  Subroutine write_controls(lun_out,data_dir)
    Use xnet_parallel, Only: parallel_IOProcessor
    Integer, Intent(in) :: lun_out
    Character(*), Intent(in) :: data_dir
    Integer :: i, izone
    If ( idiag >= 0 .or. ( idiag >= -1 .and. parallel_IOProcessor() ) ) Then
      Write(lun_out,'(a)') '## Problem Description'
      Write(lun_out,'(a)') (descript(i), i=1,3)
      Write(lun_out,'(a)') '## Job Controls'
      Call write_controls_line(lun_out,szone,'Initial Zone')
      Call write_controls_line(lun_out,nzone,'# of Zones')
      Call write_controls_line(lun_out,iweak0,'Include Weak Reactions (yes=1,no=0,only=-1)')
      Call write_controls_line(lun_out,iscrn,'Include Screening (yes=1)')
      Call write_controls_line(lun_out,iprocess,'Process Nuclear Data at Run Time (yes=1,no=0)')
      Write(lun_out,'(a)') '## Neutrinos'
      Call write_controls_line(lun_out,ineutrino,'Include Neutrino Reactions (yes=1, no=0)')
      Write(lun_out,'(a)') '## NSE Initial Conditions'
      Call write_controls_line(lun_out,t9nse,'Temperature in GK to use NSE initial conditions instead of file')
      Write(lun_out,'(a)') '## Integration Controls'
      Call write_controls_line(lun_out,isolv,'Choice of integration Scheme (1=Backward Euler, 3=Backward Differentiation'// &
        & ' Formula, 2=obsolete Bader-Deuflhard)')
      Call write_controls_line(lun_out,kstmx,'Max. number of timesteps before quit')
      Call write_controls_line(lun_out,kitmx,'Max. iterations per step')
      Call write_controls_line(lun_out,ijac,'Rebuild the jacobian every ijac iterations after the first')
      Call write_controls_line(lun_out,iconvc,'Convergence Condition (Mass Cons.=0, (dY/Y small)=1)')
      Call write_controls_line(lun_out,changemx,'Max. Abundance Change per timestep')
      Call write_controls_line(lun_out,yacc,'Smallest Abundance used in timestep calculation')
      Call write_controls_line(lun_out,tolm,'Mass Conservation Limit')
      Call write_controls_line(lun_out,tolc,'Convergence Criterion')
      Call write_controls_line(lun_out,ymin,'Lower Abundance limit, smaller abundances = 0')
      Call write_controls_line(lun_out,tdel_maxmult,'Max. Factor to change dt in a timestep')
      Write(lun_out,'(a)') '## Self-heating Controls'
      Call write_controls_line(lun_out,iheat,'Include self-heating (yes=1,no=0)')
      Call write_controls_line(lun_out,changemxt,'Max. Temperature Change per timestep')
      Call write_controls_line(lun_out,tolt9,'Temperature Convergence Criterion')
      Write(lun_out,'(a)') '## Zone Batching Controls'
      Call write_controls_line(lun_out,nzbatchmx,'Blocking size for zone loop')
      Write(lun_out,*); Write(lun_out,'(a)') '## Output Controls'
      Call write_controls_line(lun_out,idiag,'Diagnostic Output Level')
      Call write_controls_line(lun_out,itsout,'Per Timestep Output Level')
      Write(lun_out,'(a)') '# ASCII output filename root, network will append zone number'
      Write(lun_out,'(a)') Trim(Adjustl(ev_file_base))
      Write(lun_out,'(a)') '# Binary output filename root, network will append zone number'
      Write(lun_out,'(a)') Trim(Adjustl(bin_file_base))
      Write(lun_out,'(a)') '# Species to output in ASCII output (format 14a5): 14'
      Write(lun_out,'(14a5)') output_nuc
      Write(lun_out,'(a)') '## Input Controls'
      Write(lun_out,'(a)') '# Nuclear Data Directory'
      Write(lun_out,'(a)') Trim(Adjustl(data_dir))
      Write(lun_out,'(a)') '# Initial Abundance and Thermodynamic Trajectory Files'
      Do izone = 1, nzone
        Write(lun_out,'(a)') inab_file(izone)
        Write(lun_out,'(a)') thermo_file(izone)
      EndDo
    EndIf
  End Subroutine write_controls

  Subroutine write_controls_line_i(lun_out,inum,desc)
    Integer, Intent(in) :: lun_out, inum
    Character(*), Intent(in) :: desc
    Character(9) :: str_num
    Character(Len=Len_Trim(Adjustl(desc))+10) :: line
    Write(str_num,'(i9)') inum
    Write(line,'(a9,1x,a)') Adjustl(str_num), Trim(Adjustl(desc))
    Write(lun_out,'(a)') Adjustl(line)
  End Subroutine write_controls_line_i

  Subroutine write_controls_line_r(lun_out,rnum,desc)
    Integer, Intent(in) :: lun_out
    Real(dp), Intent(in) :: rnum
    Character(*), Intent(in) :: desc
    Character(9) :: str_num
    Character(Len=Len_Trim(Adjustl(desc))+10) :: line
    Write(str_num,'(ES9.2)') rnum
    Write(line,'(a9,1x,a)') Adjustl(str_num), Trim(Adjustl(desc))
    Write(lun_out,'(a)') Adjustl(line)
  End Subroutine write_controls_line_r

  Subroutine broadcast_config(config)
    Use xnet_parallel, Only: parallel_bcast
    Type(RuntimeConfig), Intent(inout) :: config
    Call parallel_bcast(config%description)
    Call parallel_bcast(config%szone); Call parallel_bcast(config%nzone); Call parallel_bcast(config%iweak0)
    Call parallel_bcast(config%iscrn); Call parallel_bcast(config%iprocess); Call parallel_bcast(config%nzbatchmx)
    Call parallel_bcast(config%isolv); Call parallel_bcast(config%kstmx); Call parallel_bcast(config%kitmx)
    Call parallel_bcast(config%ijac); Call parallel_bcast(config%iconvc); Call parallel_bcast(config%changemx)
    Call parallel_bcast(config%yacc); Call parallel_bcast(config%tolm); Call parallel_bcast(config%tolc)
    Call parallel_bcast(config%ymin); Call parallel_bcast(config%tdel_maxmult); Call parallel_bcast(config%iheat)
    Call parallel_bcast(config%changemxt); Call parallel_bcast(config%tolt9); Call parallel_bcast(config%t9nse)
    Call parallel_bcast(config%ineutrino); Call parallel_bcast(config%idiag); Call parallel_bcast(config%itsout)
    Call parallel_bcast(config%ev_file_base); Call parallel_bcast(config%bin_file_base); Call parallel_bcast(config%data_dir)
    Call parallel_bcast(config%nnucout); Call parallel_bcast(config%output_nuclei)
    Call parallel_bcast(config%inab_files); Call parallel_bcast(config%thermo_files)
  End Subroutine broadcast_config
End Module xnet_controls
