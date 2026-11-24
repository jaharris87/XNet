Program test_xnet_ffn
  Use xnet_types, Only: dp
  Use xnet_constants, Only: ln_2, ln_10, bok, m_e
  Use xnet_controls, Only: nzbatchmx, idiag, lzactive
  Use xnet_conditions, Only: etae
  Use xnet_ffn, Only: nt9grid, nenegrid, ngrid, t9grid, enegrid, ffn_ec, ffn_beta, ffnsum, ffnenu, &
    & ffn_qval, has_logft, qkffn, rfmin, ffn_rate, effphase, ffn_workspace_initialize, ffn_finalize
  Implicit None
  Integer, Parameter :: nr = 6
  Real(dp), Parameter :: tol = 512.0_dp*epsilon(1.0_dp)
  Real(dp) :: t9(3), ene(3), rate(nr,3), deriv(nr,3), tval, eval
  Real(dp) :: points_t(3*nt9grid+3), points_e(3*nenegrid+3)
  Logical, Target :: mask(3)
  Integer :: i, j, k, n, checks, samples
  Character(32) :: mode

  nzbatchmx = 3
  idiag = 0
  Allocate (etae(3),lzactive(3))
  Allocate (ffn_ec(nr,ngrid),ffn_beta(nr,ngrid),ffnsum(nr,ngrid),ffnenu(nr,ngrid))
  Allocate (ffn_qval(nr),has_logft(nr))
  Call ffn_workspace_initialize(nr)
  has_logft = (/ 0,1,2,1,0,1 /)
  ffn_qval = 0.0_dp
  Do j = 1, nenegrid
    Do i = 1, nt9grid
      n = nt9grid*(j-1) + i
      Do k = 1, nr
        ffnsum(k,n) = table(t9grid(i),enegrid(j),1)
        ffn_beta(k,n) = table(t9grid(i),enegrid(j),2)
        ffn_ec(k,n) = table(t9grid(i),enegrid(j),3)
        ffnenu(k,n) = table(t9grid(i),enegrid(j),4)
      EndDo
    EndDo
  EndDo
  ! Exercise beta-only logft and both rate/loss cutoffs as well as captures.
  ffn_ec(4,:) = 99.0_dp
  ffnsum(5,:) = -99.0_dp
  ffnenu(5,:) = -99.0_dp
  ffn_ec(6,:) = 99.0_dp
  ffn_beta(6,:) = -99.0_dp
  mask = (/ .true.,.false.,.true. /)
  lzactive = mask
  checks = 0
  samples = 0
  Call get_command_argument(1,mode)
  ! Separate probes demonstrate both original upper-bound failures before the fix.
  If ( mode == 'bounds-density' ) Then
    Call sample(3.0_dp,11.0_dp)
  ElseIf ( mode == 'bounds-temperature' ) Then
    Call sample(101.0_dp,5.0_dp)
  Else
    points_t(1:3) = (/ 0.009_dp,101.0_dp,3.7_dp /)
    points_e(1:3) = (/ -2.0_dp,12.0_dp,5.3_dp /)
    Do i = 1, nt9grid
      points_t(3*i+1:3*i+3) = (/ t9grid(i)*(1.0_dp-1.e-7_dp),t9grid(i),t9grid(i)*(1.0_dp+1.e-7_dp) /)
    EndDo
    Do i = 1, nenegrid
      points_e(3*i+1:3*i+3) = (/ enegrid(i)-1.e-7_dp,enegrid(i),enegrid(i)+1.e-7_dp /)
    EndDo
    Do j = 1, size(points_e)
      Do i = 1, size(points_t)
        Call sample(points_t(i),points_e(j))
      EndDo
    EndDo
    ! Check analytic table derivatives by finite differences away from the knots.
    Call difference(0.009_dp,5.3_dp)
    Call difference(3.7_dp,5.3_dp)
    Call difference(101.0_dp,5.3_dp)
    Call difference(3.7_dp,-2.0_dp)
    Call difference(3.7_dp,12.0_dp)
  EndIf
  Write(*,'(a,i0,a)') 'FFN table checks: ',checks,' passed'
  Call ffn_finalize
  Deallocate (etae,lzactive)
Contains
  Function table(temp,density,which) Result(value)
    Implicit None
    Real(dp), Intent(in) :: temp, density
    Integer, Intent(in) :: which
    Real(dp) :: value
    ! A mixed term makes the temperature slope depend on density.
    value = -4.0_dp + which + 0.01_dp*temp + 0.03_dp*density + 0.001_dp*temp*density
    Return
  End Function table

  Subroutine sample(temp,density)
    Implicit None
    Real(dp), Intent(in) :: temp, density
    Real(dp) :: tc, ec, slope, beta, capture, phase, dphase, chem, want, dwant
    Integer :: reaction, lane
    t9 = (/ temp,1.0_dp,3.7_dp /)
    ene = (/ 10.0_dp**density,1.0_dp,10.0_dp**5.3_dp /)
    ! Keep the existing phase-space exponential finite at the cold table edge.
    etae = -m_e/(bok*t9)
    samples = samples + 1
    If ( mod(samples,2) == 0 ) Then
      Call ffn_rate(nr,t9,ene,rate,deriv,mask)
    Else
      Call ffn_rate(nr,t9,ene,rate,deriv)
    EndIf
    Do lane = 1, 3, 2
      tval = t9(lane)
      eval = log10(ene(lane))
      tc = min(max(tval,t9grid(1)),t9grid(nt9grid))
      ec = min(max(eval,enegrid(1)),enegrid(nenegrid))
      slope = 0.01_dp + 0.001_dp*ec
      If ( tval < t9grid(1) .or. tval > t9grid(nt9grid) ) slope = 0.0_dp
      Do reaction = 1, nr
        If ( reaction == 1 ) Then
          want = 10.0_dp**table(tc,ec,1)
          dwant = ln_10*slope
        ElseIf ( reaction == 5 .or. reaction == 6 ) Then
          want = 0.0_dp
          dwant = 0.0_dp
        Else
          chem = etae(lane)*bok*tval + m_e
          chem = sign(chem,-real(has_logft(reaction),dp)-1.5_dp)
          Call effphase(tval,chem,ffn_qval(reaction),phase,dphase)
          capture = ln_2*phase/10.0_dp**table(tc,ec,3)
          If ( phase <= rfmin .or. reaction == 4 ) capture = 0.0_dp
          beta = 10.0_dp**table(tc,ec,2)
          want = beta + capture
          dwant = beta*ln_10*slope
          If ( capture >= rfmin ) dwant = dwant + capture*(-ln_10*slope+dphase/phase)
          dwant = dwant/want
        EndIf
        Call near('rate',rate(reaction,lane),want,tol*max(abs(want),rfmin))
        Call near('derivative',deriv(reaction,lane),dwant,tol*max(1.0_dp,abs(dwant)))
        want = 10.0_dp**table(tc,ec,4)
        If ( reaction == 5 ) want = 0.0_dp
        Call near('neutrino loss',qkffn(reaction,lane),want,tol*max(abs(want),rfmin))
      EndDo
    EndDo
    Return
  End Subroutine sample

  Subroutine difference(temp,density)
    Implicit None
    Real(dp), Intent(in) :: temp, density
    Real(dp) :: plus, minus, analytic, step
    step = epsilon(1.0_dp)**(1.0_dp/3.0_dp)*temp
    Call sample(temp,density)
    analytic = deriv(1,1)
    Call sample(temp+step,density)
    plus = log(rate(1,1))
    Call sample(temp-step,density)
    minus = log(rate(1,1))
    Call near('finite difference',analytic,(plus-minus)/(2.0_dp*step),1.e-7_dp)
    Return
  End Subroutine difference

  Subroutine near(label,actual,expected,bound)
    Use, Intrinsic :: ieee_arithmetic, Only: ieee_is_finite
    Implicit None
    Character(*), Intent(in) :: label
    Real(dp), Intent(in) :: actual, expected, bound
    checks = checks + 1
    If ( .not. ieee_is_finite(actual) .or. abs(actual-expected) > bound ) Then
      Write(*,*) label, ' at T9, log10(rho*Ye): ',tval,eval
      Write(*,*) 'actual, expected, bound: ',actual,expected,bound
      Stop 1
    EndIf
    Return
  End Subroutine near
End Program test_xnet_ffn
