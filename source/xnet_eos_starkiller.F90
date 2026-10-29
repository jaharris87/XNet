! Thermodynamics adapter for the bundled Starkiller Helmholtz EOS.
#include "xnet_macros.fh"

Module xnet_eos_adapter
  Use xnet_types, Only: dp
  Implicit None
  Private
  Public :: eos_adapter_initialize, eos_adapter_evaluate, eos_adapter_finalize

Contains

  Subroutine eos_adapter_initialize(nspecies,names,a,z)
    ! The standalone provider owns its EOS tables. Composition metadata is
    ! supplied once for adapters that map individual network species.
    Use actual_eos_module, Only: actual_eos_init
    Implicit None

    Integer, Intent(in) :: nspecies
    Character(*), Intent(in) :: names(nspecies)
    Real(dp), Intent(in) :: a(nspecies), z(nspecies)

    Call actual_eos_init()
    Return
  End Subroutine eos_adapter_initialize

  Subroutine eos_adapter_evaluate(nspecies,temp,rho,ye,abar,zbar,y,xext,aext,zext,cv,eta,detadt)
    ! Native outputs are cv [erg/g/K], eta [dimensionless], and detadt [1/K].
    ! XNet supplies raw Y=X/A and an auxiliary mass reservoir; this EOS uses
    ! their moments (Ye, Abar, Zbar), already calculated by XNet.
    Use actual_eos_module, Only: xnet_actual_eos
    Use eos_type_module, Only: eos_input_rt, eos_t
    Implicit None
    !XDIR XROUTINE_SEQ

    Integer, Intent(in) :: nspecies
    Real(dp), Intent(in) :: temp, rho, ye, abar, zbar, y(nspecies)
    Real(dp), Intent(in) :: xext, aext, zext
    Real(dp), Intent(out) :: cv, eta, detadt

    Type(eos_t) :: eos_state

    eos_state%rho = rho
    eos_state%T = temp
    eos_state%y_e = ye
    eos_state%abar = abar
    eos_state%zbar = zbar
    Call xnet_actual_eos(eos_input_rt,eos_state)
    cv = eos_state%cv
    eta = eos_state%eta
    detadt = eos_state%detadt
    Return
  End Subroutine eos_adapter_evaluate

  Subroutine eos_adapter_finalize
    Use actual_eos_module, Only: actual_eos_finalize
    Implicit None

    Call actual_eos_finalize
    Return
  End Subroutine eos_adapter_finalize

End Module xnet_eos_adapter
