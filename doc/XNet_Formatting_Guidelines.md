XNet Formatting Guidelines
============

* Use lower-case except for langauge keywords, which should capitalize the first letter (e.g. `Call`, `Subroutine`, `Allocate`)
* `EndDo` and `EndIf` instead of `End Do` and `End If`
* Indents should be 2 spaces (no tabs)
* Do not exceed 132 characters per line
* Use line continuation character at both the end of the first line and beginning of the second:
  ```fortran
  Call foo(var1, &
    & var2)
  ```
* Put arithmetic operators after the line continuation
* Use `>` style for conditionals over old `.gt.`
* Align inline comments with code
* Put subroutine readers below `Subroutine` declaration:
  ```fortran
  Subroutine foo(var1,var2)
    ! Subroutine header
  ```
* Use `Implicit None` in all routines and modules, even if covered by a higher-level `Implicit None` (e.g. subroutines in module with contains)
* Prefer `Only` clause when referencing variables or routines from modules:
  ```fortran
  Use my_module, Only: var1
  ```
* Always specify `Intent` for subroutine/function arguments
* Use `iso_fortran_env` variables when appropriate (e.g. `output_unit` instead of unit number 6)
* Keep integer-valued runtime controls as `Integer` (e.g. `isolv`). Use
  `Logical` for predicates and API masks such as `active`; preserve existing
  interface types.
* Explicitly `Deallocate` local `Allocatable` variables
* Explicitly use `Return` and end of subroutine or function
* Avoid `While` loops
* Follow the existing Fortran 2008 usage, including `iso_fortran_env` and
  `Newunit`. This describes current source practice; new compiler requirements
  need separate approval.
* Avoid magic numbers (i.e. use variables for scalars):
  * Bad: 
    ```fortran
    If ( error < 1.0e-8 ) Exit
    ```
  * Good:
    ```fortran
    Real(dp), Parameter :: tolerance = 1.0e-8
    If ( error < tolerance ) Exit
    ```
* Avoid gratuitous veritcal spacing (one empty line above inline comments is usually sufficient)