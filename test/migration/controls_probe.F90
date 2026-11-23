! Test-only reader probe; reads and applies controls without loading or evolving a network.
Program controls_probe
  Use xnet_controls, Only: szone, nzone, iweak0, iscrn, iprocess, nzbatchmx, isolv, kstmx, &
    & kitmx, ijac, iconvc, iheat, ineutrino, idiag, itsout, nnucout, changemx, yacc, tolm, &
    & tolc, ymin, tdel_maxmult, changemxt, tolt9, t9nse, ev_file_base, bin_file_base, &
    & output_nuc, inab_file, thermo_file, nthread, tid
#ifdef V8_READER
  Use xnet_controls, Only: descript, read_controls
#else
  Use xnet_controls, Only: xnet_controls_t, read_xnet_controls, apply_standalone_controls
#endif
  Implicit None

  Character(80) :: data_dir
  Integer :: i
#ifndef V8_READER
  Type(xnet_controls_t) :: controls
  Character(256) :: message
  Integer :: ierr
#endif

  nthread = 1
  tid = 1
#ifdef V8_READER
  Call read_controls(data_dir)
#else
  Call read_xnet_controls(controls,'controls.nml',ierr,message)
  If ( ierr /= 0 ) Then
    Write(*,'(a)') trim(message)
    Stop 1
  EndIf
  Call apply_standalone_controls(controls,data_dir)
#endif
  Write(*,'(a)') 'BEGIN VALUES'
  Do i = 1, 3
#ifdef V8_READER
    Write(*,'(a)') descript(i)
#else
    Write(*,'(a)') controls%description(i)
#endif
  EndDo
  Write(*,'(i0)') szone
  Write(*,'(i0)') nzone
  Write(*,'(i0)') iweak0
  Write(*,'(i0)') iscrn
  Write(*,'(i0)') iprocess
  Write(*,'(i0)') nzbatchmx
  Write(*,'(i0)') isolv
  Write(*,'(i0)') kstmx
  Write(*,'(i0)') kitmx
  Write(*,'(i0)') ijac
  Write(*,'(i0)') iconvc
  Write(*,'(i0)') iheat
  Write(*,'(i0)') ineutrino
  Write(*,'(i0)') idiag
  Write(*,'(i0)') itsout
  Write(*,'(i0)') nnucout
  Write(*,'(es26.17e3)') changemx
  Write(*,'(es26.17e3)') yacc
  Write(*,'(es26.17e3)') tolm
  Write(*,'(es26.17e3)') tolc
  Write(*,'(es26.17e3)') ymin
  Write(*,'(es26.17e3)') tdel_maxmult
  Write(*,'(es26.17e3)') changemxt
  Write(*,'(es26.17e3)') tolt9
  Write(*,'(es26.17e3)') t9nse
  Write(*,'(a)') ev_file_base
  Write(*,'(a)') bin_file_base
  Write(*,'(a)') data_dir
  Do i = 1, nnucout
    Write(*,'(a)') output_nuc(i)
  EndDo
  Do i = 1, nzone
    Write(*,'(a)') inab_file(i)
    Write(*,'(a)') thermo_file(i)
  EndDo
End Program controls_probe
